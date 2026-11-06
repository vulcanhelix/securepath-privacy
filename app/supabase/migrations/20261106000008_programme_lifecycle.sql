-- ============================================================================
-- W1-05 — PROGRAMME LIFECYCLE RPCs: create-from-template-version, apply a new
-- template version (FR-TPL-03/AT-08), in-programme add/edit/move of activities
-- (FR-TPL-04), register closure (§9.4), status transitions, programme
-- settings (FR-SCH-06), and the partner-console programme list (FR-PCN-01)
-- (GitHub #19 · spec SP-SPC-PLT-001 §5.3, §6.2, §8, §9 · plan BUILD_PLAN_R1 W1-05)
-- ============================================================================
--
-- Built ON the spine: W0-02 tables + column grants, W0-03 template versions
-- (content jsonb), W1-01 rules engine (recompute_*, can_close_register_item,
-- week/phase/RAG functions). Calc columns are written ONLY through the
-- recompute functions — no RPC below writes activities.start_date/due_date/
-- month/phase/rag, register_items.planned_close_date/days_overdue or
-- programmes.phase directly.
--
-- HARD RULE (unchanged): every SECURITY DEFINER guards its predicate in the
-- body (allowed_programmes / has_client_role / has_programme_role /
-- is_ao_or_alternate) — a definer owned by supabase_admin bypasses RLS.
-- Every mutation appends an audit_log row (W1-06 convention).
-- Instantiation is ONE function = ONE transaction: all-or-nothing.
--
-- WRITE-role sets (matching the W0-02 table policies):
--   WRITE   := partner_admin, partner_consultant, programme_lead, client_admin
--   PARTNER := partner_admin, partner_consultant   (template/lifecycle acts)
--
-- MERGE RULE for apply_template_version (the documented FR-TPL-03 contract —
-- "adds and updates items without losing client data, progress or evidence"):
--   * Rows map to content by STABLE KEYS: activity ref, finding ref, workstream
--     name, KPI name, maintenance code, document reference, phase number.
--   * Provenance = the OLD version's content: a row whose key was in old
--     content is template-originated; a row whose key is in neither old nor
--     new content is partner-added and is NEVER touched by apply.
--   * Matched template rows get their template-owned fields re-synced —
--     EXCEPT progress/evidence fields, which are never touched:
--     activities keep status, pct_complete, actual_completion, leads, flag,
--     comments, recovery_date, rescheduled_date, dependency_override_reason;
--     started activities (In progress / At risk / Blocked / Deferred) also
--     keep their schedule (start_week, end_week, workstream, deps, links) —
--     only the descriptive text + milestone/evidence flags sync;
--     register items keep status + the §9.4 acceptance record (Closed items
--     are skipped entirely);
--     KPIs keep baseline/target/target_proposed once the AO has confirmed
--     (target_confirmed_on IS NOT NULL) and always keep their actuals;
--     a maintenance task the partner retired (active=false) is NEVER
--     re-activated.
--   * Template rows REMOVED in the new version: a pristine row (Not started,
--     no linked evidence, no actuals) is deleted; anything carrying progress
--     or evidence is RETAINED untouched and reported as 'retained'.
--     Maintenance tasks are never deleted — they retire (active=false) so
--     instance history survives. Controlled documents are client-level and
--     shared across programmes — never removed by apply.
--   * New keys in the new content are inserted exactly as at creation.
--   * The merge is idempotent: re-applying the same version is a no-op diff.
--
-- DECISIONS (ambiguities resolved here — flagged for review):
--   1. The §5.1 components 'registers', 'quarterly_annual_cycles',
--      'report_structure' (beyond due_business_day) and 'role_labels' produce
--      NO rows at instantiation: registers configure client-level behaviour
--      (no table), checklists/reports are generated per period by W1-03's
--      jobs, role labels are display content. report_structure
--      .due_business_day DOES seed programmes.report_due_business_day.
--   2. maintenance_set entries instantiate as programme-scoped
--      maintenance_task_templates rows (programme_id set, template_version_id
--      NULL — the mtt CHECK is a one-of). This is what FR-TPL-04 partner
--      edits and FR-TPL-03 apply both operate on.
--   3. content 'kpis[].source' has no column on kpis (W0-02) — it is not
--      persisted (schema request noted; the value stays in version content).
--      document_set review_cycle likewise has no column — kept in content.
--   4. activities.ref carries no (programme_id, ref) UNIQUE constraint — the
--      RPCs enforce ref uniqueness inside a programme so apply's stable-key
--      matching can never be ambiguous (schema request: add the constraint).
--   5. transition_programme allows implementation→maintenance,
--      implementation→closed and maintenance→closed; everything else
--      (including any move OUT of closed) is rejected. Transitions are
--      logged to audit_log — there is no programme status-history table.
--   6. reorder_activity has no display-order column to move — "reorder" is
--      the schedule edit: start_week/end_week (+ optional workstream move).
--      Week bounds must stay inside 1..total_weeks.
--   7. update_activity enforces FR-SCH-04 (cannot leave 'Not started' while
--      a predecessor is incomplete) unless a dependency_override_reason is
--      present — spec names the programme lead; any WRITE role may override
--      (they are partner/consultant-level or the lead itself).
--   8. update_programme_settings treats NULL as "keep current" for every
--      field (programme_lead cannot be cleared through it — a schema/
--      API decision for a later wave; clearing is a direct grant-free op).
--      start_date / reduced_capacity_weeks are accepted here because
--      FR-SCH-06's "change start date → all dates recalculate" is a settings
--      edit: a changed start_date triggers recompute_programme_progress.
-- ============================================================================

BEGIN;


-- ============================================================================
-- 1. create_programme — FR-ONB-01/FR-TPL-02: instantiate a published version
-- ============================================================================
-- One transaction: programme row + phases + workstreams + activities + deps +
-- register items + links + controlled documents + KPIs + maintenance task
-- templates, then a full recompute. Any error aborts the whole instantiation.
CREATE OR REPLACE FUNCTION public.create_programme(
    p_client_org_id       uuid,
    p_template_version_id uuid,
    p_name                text,
    p_start_date          date)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_client   public.client_orgs;
  v_version  public.programme_template_versions;
  v_template public.programme_templates;
  v_content  jsonb;
  v_prog     uuid;
  v_ws_map   jsonb := '{}'::jsonb;      -- content workstream key → workstream id
  v_act_map  jsonb := '{}'::jsonb;      -- content activity ref → activity id
  v_reg_map  jsonb := '{}'::jsonb;      -- content finding ref → register item id
  v_total    int;
  v_el       jsonb;
  v_row      record;
  v_dep      text;
  v_row_id   uuid;
  v_act_id   uuid;
  v_ws_id    uuid;
  v_doc_id   uuid;
  v_practice uuid;
  v_counts   jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  -- definer guard: partner admin/consultant on the client's partner (or
  -- platform admin for the admin path).
  SELECT * INTO v_client FROM public.client_orgs WHERE id = p_client_org_id;
  IF v_client IS NULL THEN RAISE EXCEPTION 'client % not found', p_client_org_id; END IF;
  v_practice := v_client.practice_id;
  IF NOT public.has_client_role(p_client_org_id,
        ARRAY['partner_admin','partner_consultant'])
     AND NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION
      'programme creation requires a partner_admin or partner_consultant role on this client (FR-ONB-01)';
  END IF;

  -- template version must exist and be PUBLISHED (FR-TPL-02), and its
  -- jurisdiction must match the client (FR-ONB-03; NULL jurisdiction = any).
  SELECT * INTO v_version FROM public.programme_template_versions
   WHERE id = p_template_version_id;
  IF v_version IS NULL THEN
    RAISE EXCEPTION 'template version % not found', p_template_version_id;
  END IF;
  IF v_version.status <> 'published' THEN
    RAISE EXCEPTION
      'a programme can only be created from a PUBLISHED template version (current status: %)',
      v_version.status;
  END IF;
  SELECT * INTO v_template FROM public.programme_templates
   WHERE id = v_version.template_id;
  IF v_template.jurisdiction IS NOT NULL
     AND v_template.jurisdiction IS DISTINCT FROM v_client.jurisdiction THEN
    RAISE EXCEPTION
      'template "%" is for jurisdiction % — client "%" is % (FR-ONB-03)',
      v_template.name, v_template.jurisdiction, v_client.name, v_client.jurisdiction;
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'programme name is required';
  END IF;
  IF p_start_date IS NULL OR extract(isodow FROM p_start_date) <> 1 THEN
    RAISE EXCEPTION 'programme start date must be a Monday (§9.1)';
  END IF;

  v_content := v_version.content;
  PERFORM public.assert_template_content(v_content);   -- belt: published rows already passed the guard

  SELECT max((ph->>'end_week')::int) INTO v_total
    FROM jsonb_array_elements(v_content->'phases') ph;
  IF v_total IS NULL OR v_total < 1 THEN
    RAISE EXCEPTION 'template version % carries no usable phases', p_template_version_id;
  END IF;

  INSERT INTO public.programmes
      (client_org_id, template_version_id, name, start_date, total_weeks,
       status, report_due_business_day)
  VALUES (p_client_org_id, p_template_version_id, btrim(p_name), p_start_date,
          v_total, 'implementation',
          coalesce((v_content->'report_structure'->>'due_business_day')::int, 5))
  RETURNING id INTO v_prog;

  -- phases
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_content->'phases') LOOP
    INSERT INTO public.phases (programme_id, number, name, start_week, end_week)
    VALUES (v_prog,
            (v_el->>'number')::int, v_el->>'name',
            (v_el->>'start_week')::int, (v_el->>'end_week')::int);
  END LOOP;

  -- workstreams (key → id map for activity attachment)
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_content->'workstreams') LOOP
    INSERT INTO public.workstreams (programme_id, name)
    VALUES (v_prog, v_el->>'name')
    RETURNING id INTO v_ws_id;
    v_ws_map := v_ws_map || jsonb_build_object(coalesce(v_el->>'key', v_el->>'name'),
                                               v_ws_id::text);
  END LOOP;

  -- activities (first pass: rows + ref map)
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_content->'activity_library') LOOP
    v_ws_id := (v_ws_map ->> coalesce(v_el->>'workstream', ''))::uuid;
    INSERT INTO public.activities
        (programme_id, workstream_id, ref, text, leads, start_week, end_week,
         milestone, evidence_required)
    VALUES (v_prog, v_ws_id, v_el->>'ref', v_el->>'text', '{}',
            (v_el->>'start_week')::int, (v_el->>'end_week')::int,
            coalesce((v_el->>'milestone')::boolean, false),
            coalesce((v_el->>'evidence_required')::boolean, false))
    RETURNING id INTO v_act_id;
    v_act_map := v_act_map || jsonb_build_object(v_el->>'ref', v_act_id::text);
  END LOOP;

  -- dependencies (second pass — every ref resolves or the txn aborts)
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_content->'activity_library') LOOP
    v_act_id := (v_act_map ->> (v_el->>'ref'))::uuid;
    FOR v_dep IN SELECT * FROM jsonb_array_elements_text(
                    coalesce(v_el->'dependencies', '[]'::jsonb)) LOOP
      IF (v_act_map ->> v_dep) IS NULL THEN
        RAISE EXCEPTION 'template activity % depends on unknown ref %', v_el->>'ref', v_dep;
      END IF;
      INSERT INTO public.activity_deps (activity_id, depends_on_activity_id)
      VALUES (v_act_id, (v_act_map ->> v_dep)::uuid);
    END LOOP;
  END LOOP;

  -- remediation register + both link directions
  -- (findings_map.linked_activities ∪ activity_library.linked_findings)
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_content->'findings_map') LOOP
    INSERT INTO public.register_items
        (programme_id, ref, finding, priority, assessment_window,
         planned_close_week)
    VALUES (v_prog, v_el->>'ref', v_el->>'finding',
            coalesce(v_el->>'priority', 'Medium'), v_el->>'assessment_window',
            (v_el->>'planned_close_week')::int)
    RETURNING id INTO v_row_id;                         -- the new finding's row id
    v_reg_map := v_reg_map || jsonb_build_object(v_el->>'ref', v_row_id::text);
    FOR v_dep IN SELECT * FROM jsonb_array_elements_text(
                    coalesce(v_el->'linked_activities', '[]'::jsonb)) LOOP
      IF (v_act_map ->> v_dep) IS NULL THEN
        RAISE EXCEPTION 'template finding % links unknown activity ref %', v_el->>'ref', v_dep;
      END IF;
      INSERT INTO public.register_item_activities (register_item_id, activity_id)
      VALUES (v_row_id, (v_act_map ->> v_dep)::uuid)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_content->'activity_library') LOOP
    v_act_id := (v_act_map ->> (v_el->>'ref'))::uuid;
    FOR v_dep IN SELECT * FROM jsonb_array_elements_text(
                    coalesce(v_el->'linked_findings', '[]'::jsonb)) LOOP
      IF (v_reg_map ->> v_dep) IS NULL THEN
        RAISE EXCEPTION 'template activity % links unknown finding ref %', v_el->>'ref', v_dep;
      END IF;
      INSERT INTO public.register_item_activities (register_item_id, activity_id)
      VALUES ((v_reg_map ->> v_dep)::uuid, v_act_id)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;

  -- controlled documents (client-level — shared across the client's
  -- programmes, §6.2; duplicates on ref+version are skipped not duplicated)
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_content->'document_set') LOOP
    INSERT INTO public.controlled_documents
        (client_org_id, reference, title, version, owner)
    VALUES (p_client_org_id, v_el->>'reference', v_el->>'title',
            coalesce(v_el->>'version', '1'), v_el->>'owner')
    ON CONFLICT (client_org_id, reference, version) DO NOTHING
    RETURNING id INTO v_doc_id;
    -- optional activity links (FR-DOC-01) when the content names them
    IF v_doc_id IS NULL THEN
      SELECT id INTO v_doc_id FROM public.controlled_documents
       WHERE client_org_id = p_client_org_id
         AND reference = v_el->>'reference'
         AND version = coalesce(v_el->>'version', '1');
    END IF;
    IF v_doc_id IS NOT NULL THEN
      FOR v_dep IN SELECT * FROM jsonb_array_elements_text(
                      coalesce(v_el->'linked_activities', '[]'::jsonb)) LOOP
        IF (v_act_map ->> v_dep) IS NOT NULL THEN
          INSERT INTO public.controlled_document_activities
              (controlled_document_id, activity_id)
          VALUES (v_doc_id, (v_act_map ->> v_dep)::uuid)
          ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  -- KPIs (content order → sort)
  FOR v_row IN SELECT el, n FROM jsonb_array_elements(v_content->'kpis')
              WITH ORDINALITY AS k(el, n) LOOP
    INSERT INTO public.kpis
        (programme_id, name, unit, baseline, target, calculation,
         auto_calc, target_proposed, sort)
    VALUES (v_prog, v_row.el->>'name', v_row.el->>'unit',
            (v_row.el->>'baseline')::numeric,
            coalesce((v_row.el->>'default_target')::numeric,
                     (v_row.el->>'target')::numeric),
            v_row.el->>'calculation',
            coalesce((v_row.el->>'auto_calc')::boolean, false),
            coalesce((v_row.el->>'target_proposed')::boolean, false),
            v_row.n::int);
  END LOOP;

  -- maintenance task templates (decision 2: programme-scoped copies)
  FOR v_row IN SELECT el, n FROM jsonb_array_elements(v_content->'maintenance_set')
              WITH ORDINALITY AS m(el, n) LOOP
    INSERT INTO public.maintenance_task_templates
        (programme_id, code, task, timing_rule, owner_role, input_from_label,
         evidence_produced, feeds, active_from_rule, sort)
    VALUES (v_prog, v_row.el->>'code', v_row.el->>'task',
            coalesce(v_row.el->'timing_rule', '{}'::jsonb),
            coalesce(v_row.el->>'owner_role', 'programme_lead'),
            v_row.el->>'input_from',
            v_row.el->>'evidence_produced', v_row.el->>'feeds',
            v_row.el->'active_from_rule', v_row.n::int);
  END LOOP;

  -- CALC columns via the rules engine only (hard rule): activity dates/RAG,
  -- register planned_close_date/days_overdue, programmes.phase.
  PERFORM public.recompute_programme_progress(v_prog);

  v_counts := jsonb_build_object(
    'phases',      (SELECT count(*) FROM public.phases       WHERE programme_id = v_prog),
    'workstreams', (SELECT count(*) FROM public.workstreams  WHERE programme_id = v_prog),
    'activities',  (SELECT count(*) FROM public.activities   WHERE programme_id = v_prog),
    'dependencies',(SELECT count(*) FROM public.activity_deps d
                      JOIN public.activities a ON a.id = d.activity_id
                     WHERE a.programme_id = v_prog),
    'register_items', (SELECT count(*) FROM public.register_items WHERE programme_id = v_prog),
    'kpis',        (SELECT count(*) FROM public.kpis         WHERE programme_id = v_prog),
    'maintenance_task_templates',
      (SELECT count(*) FROM public.maintenance_task_templates WHERE programme_id = v_prog));

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'programme.created',
          jsonb_build_object('programme_id', v_prog, 'client_org_id', p_client_org_id,
                             'template_version_id', p_template_version_id,
                             'start_date', p_start_date, 'total_weeks', v_total)
                  || v_counts);
  RETURN v_prog;
END $$;
COMMENT ON FUNCTION public.create_programme(uuid, uuid, text, date) IS
  'W1-05 FR-ONB-01/FR-TPL-02: create a programme from a PUBLISHED template '
  'version — instantiates phases, workstreams, activities (+deps), register '
  'items (+links), controlled documents, KPIs and maintenance task templates '
  'in ONE transaction, pins template_version_id, then recompute_programme_'
  'progress writes every CALC column. Gate: partner_admin/partner_consultant '
  '(or platform_admin).';


-- ============================================================================
-- 2. apply_template_version — FR-TPL-03/AT-08: move a programme to a new
--    published version. The merge rule is documented in the file header.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.apply_template_version(
    p_programme_id   uuid,
    p_new_version_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog     public.programmes;
  v_new      public.programme_template_versions;
  v_old      public.programme_template_versions;
  v_newc     jsonb;
  v_oldc     jsonb;
  v_ws_map   jsonb := '{}'::jsonb;
  v_act_map  jsonb := '{}'::jsonb;   -- existing activity ref → id
  v_reg_map  jsonb := '{}'::jsonb;   -- existing finding ref → id
  v_old_keys jsonb := '{}'::jsonb;   -- provenance: keys present in OLD content
  v_el       jsonb;
  v_row      record;
  v_id       uuid;
  v_ws_id    uuid;
  v_dep      text;
  v_diff     jsonb := jsonb_build_object(
               'phases',     jsonb_build_object('added',0,'updated',0,'removed',0,'retained',0),
               'workstreams',jsonb_build_object('added',0,'kept',0),
               'activities', jsonb_build_object('added',0,'updated',0,'rescheduled',0,
                                                'removed',0,'retained',0,'kept_custom',0),
               'register_items', jsonb_build_object('added',0,'updated',0,
                                                    'removed',0,'retained',0,'kept_custom',0),
               'kpis',       jsonb_build_object('added',0,'updated',0,'removed',0,
                                                'retained',0,'kept_custom',0),
               'maintenance_tasks', jsonb_build_object('added',0,'updated',0,
                                                       'retired',0,'kept_custom',0),
               'documents',  jsonb_build_object('added',0,'kept',0));
  v_bump     int;
  v_status   text;
  v_has_ev   boolean;
  v_started  boolean;
  v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme % not found', p_programme_id; END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant'])
     AND NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION
      'applying a template version requires a partner_admin or partner_consultant role (FR-TPL-03)';
  END IF;
  IF v_prog.status = 'closed' THEN
    RAISE EXCEPTION 'cannot apply a template version to a closed programme';
  END IF;

  SELECT * INTO v_new FROM public.programme_template_versions
   WHERE id = p_new_version_id;
  IF v_new IS NULL THEN RAISE EXCEPTION 'template version % not found', p_new_version_id; END IF;
  IF v_new.status <> 'published' THEN
    RAISE EXCEPTION 'only a PUBLISHED template version can be applied (current status: %)',
      v_new.status;
  END IF;
  IF v_prog.template_version_id IS NOT NULL THEN
    SELECT * INTO v_old FROM public.programme_template_versions
     WHERE id = v_prog.template_version_id;
    IF v_old.template_id IS DISTINCT FROM v_new.template_id THEN
      RAISE EXCEPTION
        'version % belongs to a different template — cannot apply across templates',
        p_new_version_id;
    END IF;
  END IF;

  v_newc := v_new.content;
  v_oldc := coalesce(v_old.content, '{}'::jsonb);

  -- provenance key sets from OLD content (decision: old content is the record
  -- of what the template contributed; anything else existing is partner-added)
  SELECT coalesce(jsonb_object_agg(k, true), '{}'::jsonb) INTO v_old_keys
    FROM (
      SELECT (el->>'ref') k FROM jsonb_array_elements(coalesce(v_oldc->'activity_library','[]'::jsonb)) el
      UNION ALL SELECT (el->>'ref') FROM jsonb_array_elements(coalesce(v_oldc->'findings_map','[]'::jsonb)) el
      UNION ALL SELECT (el->>'name') FROM jsonb_array_elements(coalesce(v_oldc->'kpis','[]'::jsonb)) el
      UNION ALL SELECT (el->>'code') FROM jsonb_array_elements(coalesce(v_oldc->'maintenance_set','[]'::jsonb)) el
      UNION ALL SELECT (el->>'name') FROM jsonb_array_elements(coalesce(v_oldc->'workstreams','[]'::jsonb)) el
      UNION ALL SELECT (el->>'number') FROM jsonb_array_elements(coalesce(v_oldc->'phases','[]'::jsonb)) el
    ) keys
   WHERE k IS NOT NULL;

  -- existing row maps (stable keys)
  SELECT coalesce(jsonb_object_agg(a.ref, a.id::text), '{}'::jsonb)
    INTO v_act_map FROM public.activities a WHERE a.programme_id = p_programme_id;
  SELECT coalesce(jsonb_object_agg(r.ref, r.id::text), '{}'::jsonb)
    INTO v_reg_map FROM public.register_items r WHERE r.programme_id = p_programme_id;

  -- ---------- phases (key: number) ----------
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_newc->'phases') LOOP
    IF EXISTS (SELECT 1 FROM public.phases ph
                WHERE ph.programme_id = p_programme_id
                  AND ph.number = (v_el->>'number')::int) THEN
      UPDATE public.phases
         SET name = v_el->>'name', start_week = (v_el->>'start_week')::int,
             end_week = (v_el->>'end_week')::int
       WHERE programme_id = p_programme_id AND number = (v_el->>'number')::int;
      v_diff := jsonb_set(v_diff, '{phases,updated}',
                          to_jsonb((v_diff#>>'{phases,updated}')::int + 1));
    ELSE
      INSERT INTO public.phases (programme_id, number, name, start_week, end_week)
      VALUES (p_programme_id, (v_el->>'number')::int, v_el->>'name',
              (v_el->>'start_week')::int, (v_el->>'end_week')::int);
      v_diff := jsonb_set(v_diff, '{phases,added}',
                          to_jsonb((v_diff#>>'{phases,added}')::int + 1));
    END IF;
  END LOOP;
  -- remove template-originated phase numbers the new version dropped
  FOR v_el IN SELECT * FROM jsonb_array_elements(coalesce(v_oldc->'phases','[]'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'phases') n
                    WHERE (n->>'number')::int = (v_el->>'number')::int)
       AND NOT EXISTS (SELECT 1 FROM public.activities a
                        WHERE a.programme_id = p_programme_id
                          AND a.phase = (v_el->>'name')) THEN
      DELETE FROM public.phases
       WHERE programme_id = p_programme_id AND number = (v_el->>'number')::int;
      GET DIAGNOSTICS v_bump = ROW_COUNT;
      IF v_bump > 0 THEN
        v_diff := jsonb_set(v_diff, '{phases,removed}',
                            to_jsonb((v_diff#>>'{phases,removed}')::int + 1));
      END IF;
    END IF;
  END LOOP;

  -- ---------- workstreams (key: name — rows carry no 'key' column) ----------
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_newc->'workstreams') LOOP
    SELECT w.id INTO v_ws_id FROM public.workstreams w
     WHERE w.programme_id = p_programme_id AND w.name = (v_el->>'name')
     LIMIT 1;
    IF v_ws_id IS NULL THEN
      INSERT INTO public.workstreams (programme_id, name)
      VALUES (p_programme_id, v_el->>'name')
      RETURNING id INTO v_ws_id;
      v_diff := jsonb_set(v_diff, '{workstreams,added}',
                          to_jsonb((v_diff#>>'{workstreams,added}')::int + 1));
    ELSE
      v_diff := jsonb_set(v_diff, '{workstreams,kept}',
                          to_jsonb((v_diff#>>'{workstreams,kept}')::int + 1));
    END IF;
    v_ws_map := v_ws_map || jsonb_build_object(coalesce(v_el->>'key', v_el->>'name'),
                                               v_ws_id::text);
  END LOOP;

  -- ---------- activities (key: ref) ----------
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_newc->'activity_library') LOOP
    v_ws_id := (v_ws_map ->> coalesce(v_el->>'workstream', ''))::uuid;
    v_id := (v_act_map ->> (v_el->>'ref'))::uuid;
    IF v_id IS NULL THEN
      -- NEW activity
      INSERT INTO public.activities
          (programme_id, workstream_id, ref, text, leads, start_week, end_week,
           milestone, evidence_required)
      VALUES (p_programme_id, v_ws_id, v_el->>'ref', v_el->>'text', '{}',
              (v_el->>'start_week')::int, (v_el->>'end_week')::int,
              coalesce((v_el->>'milestone')::boolean, false),
              coalesce((v_el->>'evidence_required')::boolean, false))
      RETURNING id INTO v_id;
      v_act_map := v_act_map || jsonb_build_object(v_el->>'ref', v_id::text);
      v_diff := jsonb_set(v_diff, '{activities,added}',
                          to_jsonb((v_diff#>>'{activities,added}')::int + 1));
    ELSE
      SELECT a.status INTO v_status FROM public.activities a WHERE a.id = v_id;
      v_started := v_status <> 'Not started';
      IF v_status = 'Complete' THEN
        -- completed work is frozen: descriptive label only, everything else kept
        UPDATE public.activities SET text = v_el->>'text' WHERE id = v_id;
        v_diff := jsonb_set(v_diff, '{activities,retained}',
                            to_jsonb((v_diff#>>'{activities,retained}')::int + 1));
      ELSIF v_started THEN
        -- started: descriptive fields sync, schedule pinned
        UPDATE public.activities
           SET text = v_el->>'text',
               milestone = coalesce((v_el->>'milestone')::boolean, milestone),
               evidence_required = coalesce((v_el->>'evidence_required')::boolean,
                                            evidence_required)
         WHERE id = v_id;
        v_diff := jsonb_set(v_diff, '{activities,updated}',
                            to_jsonb((v_diff#>>'{activities,updated}')::int + 1));
      ELSE
        -- Not started: full structure re-sync incl. workstream + weeks + deps
        UPDATE public.activities
           SET text = v_el->>'text', workstream_id = v_ws_id,
               start_week = (v_el->>'start_week')::int,
               end_week   = (v_el->>'end_week')::int,
               milestone = coalesce((v_el->>'milestone')::boolean, false),
               evidence_required = coalesce((v_el->>'evidence_required')::boolean, false)
         WHERE id = v_id;
        DELETE FROM public.activity_deps WHERE activity_id = v_id;
        FOR v_dep IN SELECT * FROM jsonb_array_elements_text(
                        coalesce(v_el->'dependencies', '[]'::jsonb)) LOOP
          IF (v_act_map ->> v_dep) IS NULL THEN
            RAISE EXCEPTION 'template activity % depends on unknown ref %',
              v_el->>'ref', v_dep;
          END IF;
          INSERT INTO public.activity_deps (activity_id, depends_on_activity_id)
          VALUES (v_id, (v_act_map ->> v_dep)::uuid)
          ON CONFLICT DO NOTHING;
        END LOOP;
        v_diff := jsonb_set(v_diff, '{activities,rescheduled}',
                            to_jsonb((v_diff#>>'{activities,rescheduled}')::int + 1));
      END IF;
    END IF;
  END LOOP;
  -- deps for NEW + Not-started activities (started items keep their dep set —
  -- schedule pinned per the merge rule)
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_newc->'activity_library') LOOP
    v_id := (v_act_map ->> (v_el->>'ref'))::uuid;
    SELECT a.status INTO v_status FROM public.activities a WHERE a.id = v_id;
    IF v_status = 'Not started' THEN
      FOR v_dep IN SELECT * FROM jsonb_array_elements_text(
                      coalesce(v_el->'dependencies', '[]'::jsonb)) LOOP
        IF (v_act_map ->> v_dep) IS NULL THEN
          RAISE EXCEPTION 'template activity % depends on unknown ref %', v_el->>'ref', v_dep;
        END IF;
        INSERT INTO public.activity_deps (activity_id, depends_on_activity_id)
        VALUES (v_id, (v_act_map ->> v_dep)::uuid)
        ON CONFLICT DO NOTHING;
      END LOOP;
    END IF;
  END LOOP;

  -- template-removed activities (in OLD content, absent in NEW)
  FOR v_el IN SELECT * FROM jsonb_array_elements(coalesce(v_oldc->'activity_library','[]'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'activity_library') n
                    WHERE n->>'ref' = v_el->>'ref')
       AND (v_act_map ->> (v_el->>'ref')) IS NOT NULL THEN
      v_id := (v_act_map ->> (v_el->>'ref'))::uuid;
      SELECT a.status INTO v_status FROM public.activities a WHERE a.id = v_id;
      SELECT EXISTS (SELECT 1 FROM public.evidence_items e WHERE e.activity_id = v_id)
        INTO v_has_ev;
      IF v_status = 'Not started' AND NOT v_has_ev THEN
        DELETE FROM public.activities WHERE id = v_id;
        v_diff := jsonb_set(v_diff, '{activities,removed}',
                            to_jsonb((v_diff#>>'{activities,removed}')::int + 1));
      ELSE
        v_diff := jsonb_set(v_diff, '{activities,retained}',
                            to_jsonb((v_diff#>>'{activities,retained}')::int + 1));
      END IF;
    END IF;
  END LOOP;
  -- partner-added count (present in neither old nor new)
  v_diff := jsonb_set(v_diff, '{activities,kept_custom}', to_jsonb(
    (SELECT count(*) FROM public.activities a
      WHERE a.programme_id = p_programme_id
        AND NOT (v_old_keys ? a.ref)
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'activity_library') n
                         WHERE n->>'ref' = a.ref))));

  -- ---------- register items (key: ref) ----------
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_newc->'findings_map') LOOP
    v_id := (v_reg_map ->> (v_el->>'ref'))::uuid;
    IF v_id IS NULL THEN
      INSERT INTO public.register_items
          (programme_id, ref, finding, priority, assessment_window,
           planned_close_week)
      VALUES (p_programme_id, v_el->>'ref', v_el->>'finding',
              coalesce(v_el->>'priority','Medium'), v_el->>'assessment_window',
              (v_el->>'planned_close_week')::int)
      RETURNING id INTO v_id;
      v_reg_map := v_reg_map || jsonb_build_object(v_el->>'ref', v_id::text);
      v_diff := jsonb_set(v_diff, '{register_items,added}',
                          to_jsonb((v_diff#>>'{register_items,added}')::int + 1));
    ELSE
      SELECT r.status INTO v_status FROM public.register_items r WHERE r.id = v_id;
      IF v_status <> 'Closed' THEN
        UPDATE public.register_items
           SET finding = v_el->>'finding',
               priority = coalesce(v_el->>'priority', priority),
               assessment_window = v_el->>'assessment_window',
               planned_close_week = coalesce((v_el->>'planned_close_week')::int,
                                             planned_close_week)
         WHERE id = v_id;
        v_diff := jsonb_set(v_diff, '{register_items,updated}',
                            to_jsonb((v_diff#>>'{register_items,updated}')::int + 1));
      ELSE
        v_diff := jsonb_set(v_diff, '{register_items,retained}',
                            to_jsonb((v_diff#>>'{register_items,retained}')::int + 1));
      END IF;
    END IF;
    -- rebuild links for non-Closed items from both content directions
    SELECT r.status INTO v_status FROM public.register_items r WHERE r.id = v_id;
    IF v_status <> 'Closed' THEN
      DELETE FROM public.register_item_activities WHERE register_item_id = v_id;
      FOR v_dep IN SELECT * FROM jsonb_array_elements_text(
                      coalesce(v_el->'linked_activities','[]'::jsonb)) LOOP
        IF (v_act_map ->> v_dep) IS NOT NULL THEN
          INSERT INTO public.register_item_activities (register_item_id, activity_id)
          VALUES (v_id, (v_act_map ->> v_dep)::uuid) ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;
      FOR v_dep IN SELECT a.el->>'ref'
                     FROM jsonb_array_elements(v_newc->'activity_library') a(el)
                    WHERE a.el->'linked_findings' @> to_jsonb(v_el->>'ref'::text) LOOP
        IF (v_act_map ->> v_dep) IS NOT NULL THEN
          INSERT INTO public.register_item_activities (register_item_id, activity_id)
          VALUES (v_id, (v_act_map ->> v_dep)::uuid) ON CONFLICT DO NOTHING;
        END IF;
      END LOOP;
    END IF;
  END LOOP;
  -- template-removed findings
  FOR v_el IN SELECT * FROM jsonb_array_elements(coalesce(v_oldc->'findings_map','[]'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'findings_map') n
                    WHERE n->>'ref' = v_el->>'ref')
       AND (v_reg_map ->> (v_el->>'ref')) IS NOT NULL THEN
      v_id := (v_reg_map ->> (v_el->>'ref'))::uuid;
      SELECT r.status INTO v_status FROM public.register_items r WHERE r.id = v_id;
      SELECT EXISTS (SELECT 1 FROM public.evidence_items e WHERE e.register_item_id = v_id)
        INTO v_has_ev;
      IF v_status = 'Not started' AND NOT v_has_ev THEN
        DELETE FROM public.register_items WHERE id = v_id;
        v_diff := jsonb_set(v_diff, '{register_items,removed}',
                            to_jsonb((v_diff#>>'{register_items,removed}')::int + 1));
      ELSE
        v_diff := jsonb_set(v_diff, '{register_items,retained}',
                            to_jsonb((v_diff#>>'{register_items,retained}')::int + 1));
      END IF;
    END IF;
  END LOOP;
  v_diff := jsonb_set(v_diff, '{register_items,kept_custom}', to_jsonb(
    (SELECT count(*) FROM public.register_items r
      WHERE r.programme_id = p_programme_id
        AND NOT (v_old_keys ? r.ref)
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'findings_map') n
                         WHERE n->>'ref' = r.ref))));

  -- ---------- KPIs (key: name) ----------
  FOR v_row IN SELECT el, n FROM jsonb_array_elements(v_newc->'kpis')
              WITH ORDINALITY AS k(el, n) LOOP
    SELECT k.id INTO v_id FROM public.kpis k
     WHERE k.programme_id = p_programme_id AND k.name = (v_row.el->>'name')
     LIMIT 1;
    IF v_id IS NULL THEN
      INSERT INTO public.kpis
          (programme_id, name, unit, baseline, target, calculation,
           auto_calc, target_proposed, sort)
      VALUES (p_programme_id, v_row.el->>'name', v_row.el->>'unit',
              (v_row.el->>'baseline')::numeric,
              coalesce((v_row.el->>'default_target')::numeric,
                       (v_row.el->>'target')::numeric),
              v_row.el->>'calculation',
              coalesce((v_row.el->>'auto_calc')::boolean, false),
              coalesce((v_row.el->>'target_proposed')::boolean, false),
              v_row.n::int);
      v_diff := jsonb_set(v_diff, '{kpis,added}',
                          to_jsonb((v_diff#>>'{kpis,added}')::int + 1));
    ELSE
      -- sync definition; baseline/target/target_proposed only while the AO
      -- has not confirmed (confirmation is client data — the merge keeps it)
      UPDATE public.kpis k
         SET unit = coalesce(v_row.el->>'unit', k.unit),
             calculation = coalesce(v_row.el->>'calculation', k.calculation),
             auto_calc = coalesce((v_row.el->>'auto_calc')::boolean, k.auto_calc),
             baseline = CASE WHEN k.target_confirmed_on IS NULL
                             THEN coalesce((v_row.el->>'baseline')::numeric, k.baseline)
                             ELSE k.baseline END,
             target   = CASE WHEN k.target_confirmed_on IS NULL
                             THEN coalesce((v_row.el->>'default_target')::numeric,
                                           (v_row.el->>'target')::numeric, k.target)
                             ELSE k.target END,
             target_proposed = CASE WHEN k.target_confirmed_on IS NULL
                             THEN coalesce((v_row.el->>'target_proposed')::boolean,
                                           k.target_proposed)
                             ELSE k.target_proposed END,
             sort = v_row.n::int
       WHERE k.id = v_id;
      v_diff := jsonb_set(v_diff, '{kpis,updated}',
                          to_jsonb((v_diff#>>'{kpis,updated}')::int + 1));
    END IF;
  END LOOP;
  -- template-removed KPIs: only drop those with no recorded actuals
  FOR v_el IN SELECT * FROM jsonb_array_elements(coalesce(v_oldc->'kpis','[]'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'kpis') n
                    WHERE n->>'name' = v_el->>'name') THEN
      SELECT k.id INTO v_id FROM public.kpis k
       WHERE k.programme_id = p_programme_id AND k.name = (v_el->>'name')
       LIMIT 1;
      IF v_id IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM public.kpi_actuals ka WHERE ka.kpi_id = v_id) THEN
          v_diff := jsonb_set(v_diff, '{kpis,retained}',
                              to_jsonb((v_diff#>>'{kpis,retained}')::int + 1));
        ELSE
          DELETE FROM public.kpis WHERE id = v_id;
          v_diff := jsonb_set(v_diff, '{kpis,removed}',
                              to_jsonb((v_diff#>>'{kpis,removed}')::int + 1));
        END IF;
      END IF;
    END IF;
  END LOOP;
  v_diff := jsonb_set(v_diff, '{kpis,kept_custom}', to_jsonb(
    (SELECT count(*) FROM public.kpis k
      WHERE k.programme_id = p_programme_id
        AND NOT (v_old_keys ? k.name)
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'kpis') n
                         WHERE n->>'name' = k.name))));

  -- ---------- maintenance task templates (key: code; retire, never delete) --
  FOR v_row IN SELECT el, n FROM jsonb_array_elements(v_newc->'maintenance_set')
              WITH ORDINALITY AS m(el, n) LOOP
    SELECT t.id INTO v_id FROM public.maintenance_task_templates t
     WHERE t.programme_id = p_programme_id AND t.code = (v_row.el->>'code')
     LIMIT 1;
    IF v_id IS NULL THEN
      INSERT INTO public.maintenance_task_templates
          (programme_id, code, task, timing_rule, owner_role, input_from_label,
           evidence_produced, feeds, active_from_rule, sort)
      VALUES (p_programme_id, v_row.el->>'code', v_row.el->>'task',
              coalesce(v_row.el->'timing_rule','{}'::jsonb),
              coalesce(v_row.el->>'owner_role','programme_lead'),
              v_row.el->>'input_from', v_row.el->>'evidence_produced',
              v_row.el->>'feeds', v_row.el->'active_from_rule', v_row.n::int);
      v_diff := jsonb_set(v_diff, '{maintenance_tasks,added}',
                          to_jsonb((v_diff#>>'{maintenance_tasks,added}')::int + 1));
    ELSE
      UPDATE public.maintenance_task_templates t
         SET task = v_row.el->>'task',
             timing_rule = coalesce(v_row.el->'timing_rule', t.timing_rule),
             owner_role = coalesce(v_row.el->>'owner_role', t.owner_role),
             input_from_label = v_row.el->>'input_from',
             evidence_produced = v_row.el->>'evidence_produced',
             feeds = v_row.el->>'feeds',
             active_from_rule = v_row.el->'active_from_rule',
             sort = v_row.n::int
             -- active deliberately untouched: a partner-retired task is never
             -- resurrected by a version bump (merge rule)
       WHERE t.id = v_id;
      v_diff := jsonb_set(v_diff, '{maintenance_tasks,updated}',
                          to_jsonb((v_diff#>>'{maintenance_tasks,updated}')::int + 1));
    END IF;
  END LOOP;
  -- template-removed tasks retire (instance history survives)
  UPDATE public.maintenance_task_templates t
     SET active = false
   WHERE t.programme_id = p_programme_id AND t.active
     AND (v_old_keys ? t.code)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'maintenance_set') n
                      WHERE n->>'code' = t.code);
  GET DIAGNOSTICS v_bump = ROW_COUNT;
  v_diff := jsonb_set(v_diff, '{maintenance_tasks,retired}', to_jsonb(v_bump::int));
  v_diff := jsonb_set(v_diff, '{maintenance_tasks,kept_custom}', to_jsonb(
    (SELECT count(*) FROM public.maintenance_task_templates t
      WHERE t.programme_id = p_programme_id AND t.active
        AND NOT (v_old_keys ? t.code)
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_newc->'maintenance_set') n
                         WHERE n->>'code' = t.code))));

  -- ---------- controlled documents (client-level: add/update, never remove) -
  FOR v_el IN SELECT * FROM jsonb_array_elements(v_newc->'document_set') LOOP
    INSERT INTO public.controlled_documents
        (client_org_id, reference, title, version, owner)
    VALUES (v_prog.client_org_id, v_el->>'reference', v_el->>'title',
            coalesce(v_el->>'version','1'), v_el->>'owner')
    ON CONFLICT (client_org_id, reference, version) DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NOT NULL THEN
      v_diff := jsonb_set(v_diff, '{documents,added}',
                          to_jsonb((v_diff#>>'{documents,added}')::int + 1));
    ELSE
      v_diff := jsonb_set(v_diff, '{documents,kept}',
                          to_jsonb((v_diff#>>'{documents,kept}')::int + 1));
    END IF;
  END LOOP;

  -- pin the new version + recompute every CALC column (hard rule)
  UPDATE public.programmes SET template_version_id = p_new_version_id
   WHERE id = p_programme_id;
  PERFORM public.recompute_programme_progress(p_programme_id);

  SELECT c.practice_id INTO v_practice FROM public.client_orgs c
   WHERE c.id = v_prog.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'programme.template_version_applied',
          jsonb_build_object('programme_id', p_programme_id,
                             'from_version_id', v_prog.template_version_id,
                             'to_version_id', p_new_version_id,
                             'diff', v_diff));
  RETURN v_diff;
END $$;
COMMENT ON FUNCTION public.apply_template_version(uuid, uuid) IS
  'W1-05 FR-TPL-03/AT-08: apply a newer PUBLISHED version of the programme''s '
  'own template. Stable-key merge (see file header for the full merge rule): '
  'progress/evidence/confirmation preserved, pristine template rows updated or '
  'removed, partner-added rows untouched, maintenance tasks retired not '
  'deleted. Returns the diff summary jsonb. Gate: partner_admin/consultant.';


-- ============================================================================
-- 3. update_activity / reorder_activity / add_activity — FR-TPL-04 partner
--    edits inside a programme. Status changes ride the existing
--    trg_activity_status_history trigger (append-only ledger); CALC columns
--    go through recompute_programme_progress only.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_activity(
    p_activity_id uuid,
    p_payload     jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_act      public.activities;
  v_allowed  text[] := ARRAY['ref','text','workstream_id','leads','start_week',
                             'end_week','milestone','evidence_required','status',
                             'pct_complete','actual_completion','flag','comments',
                             'recovery_date','dependency_override_reason',
                             'rescheduled_date'];
  v_key      text;
  v_new_status text;
  v_open_deps int;
  v_override  text;
  v_total    int;
  v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_act FROM public.activities a WHERE a.id = p_activity_id;
  IF v_act IS NULL THEN RAISE EXCEPTION 'activity % not found', p_activity_id; END IF;
  IF NOT public.has_programme_role(v_act.programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'activity update requires a programme write role (FR-TPL-04)';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'payload must be a jsonb object of editable fields';
  END IF;
  FOR v_key IN SELECT k FROM jsonb_object_keys(p_payload) k LOOP
    IF NOT (v_key = ANY(v_allowed)) THEN
      RAISE EXCEPTION 'update_activity: field "%" is not editable', v_key;
    END IF;
  END LOOP;

  SELECT p.total_weeks INTO v_total FROM public.programmes p
   WHERE p.id = v_act.programme_id;

  -- week bounds stay inside the programme and ordered
  IF coalesce((p_payload->>'end_week')::int, v_act.end_week)
     < coalesce((p_payload->>'start_week')::int, v_act.start_week) THEN
    RAISE EXCEPTION 'end_week must be >= start_week';
  END IF;
  IF coalesce((p_payload->>'end_week')::int, v_act.end_week) > v_total
     OR coalesce((p_payload->>'start_week')::int, v_act.start_week) < 1 THEN
    RAISE EXCEPTION 'week bounds must stay inside 1..% (programme length)', v_total;
  END IF;

  -- ref uniqueness inside the programme (decision 4 — no DB constraint)
  IF (p_payload->>'ref') IS NOT NULL
     AND p_payload->>'ref' IS DISTINCT FROM v_act.ref
     AND EXISTS (SELECT 1 FROM public.activities a
                  WHERE a.programme_id = v_act.programme_id
                    AND a.ref = p_payload->>'ref' AND a.id <> v_act.id) THEN
    RAISE EXCEPTION 'activity ref "%" already exists in this programme', p_payload->>'ref';
  END IF;

  -- workstream must belong to the same programme
  IF (p_payload->>'workstream_id') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.workstreams w
                      WHERE w.id = (p_payload->>'workstream_id')::uuid
                        AND w.programme_id = v_act.programme_id) THEN
    RAISE EXCEPTION 'workstream % is not part of this programme', p_payload->>'workstream_id';
  END IF;

  -- FR-SCH-04: leaving 'Not started' with incomplete predecessors requires a
  -- dependency override reason (decision 7)
  v_new_status := coalesce(p_payload->>'status', v_act.status);
  IF v_act.status = 'Not started' AND v_new_status <> 'Not started' THEN
    SELECT count(*) INTO v_open_deps
      FROM public.activity_deps d
      JOIN public.activities a ON a.id = d.depends_on_activity_id
     WHERE d.activity_id = v_act.id AND a.status <> 'Complete';
    v_override := coalesce(p_payload->>'dependency_override_reason',
                           v_act.dependency_override_reason);
    IF v_open_deps > 0 AND (v_override IS NULL OR btrim(v_override) = '') THEN
      RAISE EXCEPTION
        'cannot start activity: % predecessor(s) incomplete — record a dependency_override_reason (FR-SCH-04)',
        v_open_deps;
    END IF;
  END IF;

  UPDATE public.activities SET
      ref            = coalesce(p_payload->>'ref', ref),
      text           = coalesce(p_payload->>'text', text),
      workstream_id  = coalesce((p_payload->>'workstream_id')::uuid, workstream_id),
      leads          = coalesce((SELECT array_agg(x::uuid)
                                   FROM jsonb_array_elements_text(p_payload->'leads') x),
                                leads),
      start_week     = coalesce((p_payload->>'start_week')::int, start_week),
      end_week       = coalesce((p_payload->>'end_week')::int, end_week),
      milestone      = coalesce((p_payload->>'milestone')::boolean, milestone),
      evidence_required = coalesce((p_payload->>'evidence_required')::boolean,
                                   evidence_required),
      status         = v_new_status,
      pct_complete   = coalesce((p_payload->>'pct_complete')::int, pct_complete),
      actual_completion = coalesce((p_payload->>'actual_completion')::date,
                                   actual_completion),
      flag           = coalesce((p_payload->>'flag')::boolean, flag),
      comments       = coalesce(p_payload->>'comments', comments),
      recovery_date  = coalesce((p_payload->>'recovery_date')::date, recovery_date),
      dependency_override_reason = coalesce(p_payload->>'dependency_override_reason',
                                            dependency_override_reason),
      rescheduled_date = coalesce((p_payload->>'rescheduled_date')::date,
                                  rescheduled_date)
   WHERE id = p_activity_id;
  -- status change → trg_activity_status_history appends the ledger row itself

  PERFORM public.recompute_programme_progress(v_act.programme_id);

  SELECT c.practice_id INTO v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_act.programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'activity.updated',
          jsonb_build_object('activity_id', p_activity_id,
                             'programme_id', v_act.programme_id,
                             'fields', (SELECT jsonb_agg(k) FROM jsonb_object_keys(p_payload) k)));
  RETURN p_activity_id;
END $$;
COMMENT ON FUNCTION public.update_activity(uuid, jsonb) IS
  'W1-05 FR-TPL-04: partner edits of an activity via a jsonb payload '
  '(merge semantics — absent keys keep stored values). Status changes append '
  'to activity_status_history via the existing trigger; FR-SCH-04 predecessor '
  'gate enforced; calc columns recomputed by the engine.';


CREATE OR REPLACE FUNCTION public.reorder_activity(
    p_activity_id   uuid,
    p_start_week    int,
    p_end_week      int,
    p_workstream_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- "reorder" on this schema = reposition on the schedule (decision 6):
  -- the same validated write path as update_activity.
  IF p_start_week IS NULL AND p_end_week IS NULL AND p_workstream_id IS NULL THEN
    RAISE EXCEPTION 'reorder_activity needs at least one of start_week, end_week, workstream_id';
  END IF;
  RETURN public.update_activity(p_activity_id,
    jsonb_strip_nulls(jsonb_build_object(
      'start_week', p_start_week, 'end_week', p_end_week,
      'workstream_id', p_workstream_id)));
END $$;
COMMENT ON FUNCTION public.reorder_activity(uuid, int, int, uuid) IS
  'W1-05 FR-TPL-04: reposition an activity on the schedule (start/end week, '
  'optional workstream move). Thin wrapper over update_activity — the engine '
  'recomputes the derived dates.';


CREATE OR REPLACE FUNCTION public.add_activity(
    p_programme_id      uuid,
    p_ref               text,
    p_text              text,
    p_workstream_id     uuid    DEFAULT NULL,
    p_start_week        int     DEFAULT 1,
    p_end_week          int     DEFAULT 1,
    p_milestone         boolean DEFAULT false,
    p_evidence_required boolean DEFAULT false,
    p_dependencies      uuid[]  DEFAULT '{}',
    p_leads             uuid[]  DEFAULT '{}')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id       uuid;
  v_total    int;
  v_dep_id   uuid;
  v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT p.total_weeks, c.practice_id INTO v_total, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = p_programme_id;
  IF v_total IS NULL THEN RAISE EXCEPTION 'programme % not found', p_programme_id; END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'adding an activity requires a programme write role (FR-TPL-04)';
  END IF;
  IF p_ref IS NULL OR btrim(p_ref) = '' OR p_text IS NULL OR btrim(p_text) = '' THEN
    RAISE EXCEPTION 'activity ref and text are required';
  END IF;
  IF EXISTS (SELECT 1 FROM public.activities a
              WHERE a.programme_id = p_programme_id AND a.ref = p_ref) THEN
    RAISE EXCEPTION 'activity ref "%" already exists in this programme', p_ref;
  END IF;
  IF p_workstream_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.workstreams w
                      WHERE w.id = p_workstream_id AND w.programme_id = p_programme_id) THEN
    RAISE EXCEPTION 'workstream % is not part of this programme', p_workstream_id;
  END IF;
  IF p_start_week < 1 OR p_end_week < p_start_week OR p_end_week > v_total THEN
    RAISE EXCEPTION 'week bounds must be inside 1..% (programme length)', v_total;
  END IF;

  INSERT INTO public.activities
      (programme_id, workstream_id, ref, text, leads, start_week, end_week,
       milestone, evidence_required)
  VALUES (p_programme_id, p_workstream_id, p_ref, p_text,
          coalesce(p_leads, '{}'), p_start_week, p_end_week,
          coalesce(p_milestone, false), coalesce(p_evidence_required, false))
  RETURNING id INTO v_id;

  -- initial ledger row (the history trigger fires on UPDATE, not INSERT)
  INSERT INTO public.activity_status_history (activity_id, old_status, new_status, changed_by)
  VALUES (v_id, NULL, 'Not started', auth.uid());

  FOREACH v_dep_id IN ARRAY coalesce(p_dependencies, '{}') LOOP
    IF v_dep_id = v_id THEN
      RAISE EXCEPTION 'an activity cannot depend on itself';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.activities a
                    WHERE a.id = v_dep_id AND a.programme_id = p_programme_id) THEN
      RAISE EXCEPTION 'dependency % is not an activity of this programme', v_dep_id;
    END IF;
    INSERT INTO public.activity_deps (activity_id, depends_on_activity_id)
    VALUES (v_id, v_dep_id);
  END LOOP;

  PERFORM public.recompute_programme_progress(p_programme_id);

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'activity.added',
          jsonb_build_object('activity_id', v_id, 'programme_id', p_programme_id,
                             'ref', p_ref, 'start_week', p_start_week,
                             'end_week', p_end_week));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.add_activity(uuid, text, text, uuid, int, int, boolean, boolean, uuid[], uuid[]) IS
  'W1-05 FR-TPL-04: add a partner-defined activity inside a programme '
  '(same-programme workstream + dependency validation, ref uniqueness, first '
  'status-history row, engine recompute).';


-- ============================================================================
-- 4. close_register_item — §9.4 closure ritual. AO / named alternate only;
--    can_close_register_item (W1-01) is the data precondition; the W0-02/W1-01
--    triggers re-verify on the write path. Optional p_evidence_refs stamps
--    the acceptance record in the same atomic write (acceptance + closure is
--    one act for the AO).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.close_register_item(
    p_item_id       uuid,
    p_evidence_refs text[] DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_item    public.register_items;
  v_client  uuid;
  v_practice uuid;
  v_check   record;
  v_open    int;
  v_refs    text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_item FROM public.register_items r WHERE r.id = p_item_id;
  IF v_item IS NULL THEN RAISE EXCEPTION 'register item % not found', p_item_id; END IF;
  SELECT p.client_org_id, c.practice_id INTO v_client, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_item.programme_id;

  -- AO / named-alternate gate (mirrors trg_register_closure — checked here for
  -- a precise error before any write).
  IF NOT public.is_ao_or_alternate(v_client) THEN
    RAISE EXCEPTION
      'only the accountable officer or named alternate may close a register item (§9.4, FR-ACC-02)';
  END IF;
  IF v_item.status = 'Closed' THEN
    RAISE EXCEPTION 'register item % is already Closed', v_item.ref;
  END IF;

  -- data precondition: W1-01's can_close_register_item is authoritative when
  -- no new acceptance record is being supplied; when refs arrive, the
  -- acceptance leg is being written now and only the activity leg pre-checks.
  SELECT * INTO v_check FROM public.can_close_register_item(p_item_id);
  IF NOT v_check.can_close THEN
    IF p_evidence_refs IS NULL OR array_length(p_evidence_refs, 1) IS NULL THEN
      RAISE EXCEPTION 'cannot close register item %: %', v_item.ref, v_check.reason;
    END IF;
    -- refs supplied: the only acceptable remaining gap is the acceptance record
    SELECT count(*), string_agg(a.ref, ', ' ORDER BY a.ref) INTO v_open, v_refs
      FROM public.register_item_activities ria
      JOIN public.activities a ON a.id = ria.activity_id
     WHERE ria.register_item_id = p_item_id AND a.status <> 'Complete';
    IF v_open > 0 THEN
      RAISE EXCEPTION 'cannot close register item %: %', v_item.ref, v_check.reason;
    END IF;
  END IF;

  UPDATE public.register_items
     SET status = 'Closed',
         accepted_on   = coalesce(accepted_on, now()),
         accepted_by   = coalesce(accepted_by, auth.uid()),
         accepted_evidence_refs = coalesce(accepted_evidence_refs, p_evidence_refs)
   WHERE id = p_item_id;
  -- register_closure_gate (AO) + register_closure_data_gate (§9.4 data)
  -- re-verify on this write — defence in depth.

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'register_item.closed',
          jsonb_build_object('register_item_id', p_item_id,
                             'programme_id', v_item.programme_id,
                             'ref', v_item.ref,
                             'evidence_refs', p_evidence_refs));
  RETURN p_item_id;
END $$;
COMMENT ON FUNCTION public.close_register_item(uuid, text[]) IS
  'W1-05 §9.4: AO/named-alternate closes a finding. Requires every linked '
  'activity Complete + an acceptance record (accepted_on/by/refs) — existing '
  '(evidence acceptance path) or supplied now via p_evidence_refs, stamped '
  'atomically with the close. can_close_register_item is the pre-flight.';


-- ============================================================================
-- 5. transition_programme — explicit, logged status transitions only
-- ============================================================================
CREATE OR REPLACE FUNCTION public.transition_programme(
    p_programme_id uuid,
    p_to_status    text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog public.programmes;
  v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme % not found', p_programme_id; END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'programme transition requires a programme write role';
  END IF;
  IF p_to_status NOT IN ('implementation','maintenance','closed') THEN
    RAISE EXCEPTION 'invalid programme status "%"', p_to_status;
  END IF;
  IF p_to_status = v_prog.status THEN
    RAISE EXCEPTION 'programme is already %', p_to_status;
  END IF;
  -- decision 5: the legal moves only (closed is terminal)
  IF NOT ( (v_prog.status = 'implementation' AND p_to_status IN ('maintenance','closed'))
        OR (v_prog.status = 'maintenance'    AND p_to_status = 'closed') ) THEN
    RAISE EXCEPTION 'invalid transition % → % (allowed: implementation→maintenance|closed, maintenance→closed)',
      v_prog.status, p_to_status;
  END IF;

  UPDATE public.programmes SET status = p_to_status WHERE id = p_programme_id;

  SELECT c.practice_id INTO v_practice FROM public.client_orgs c
   WHERE c.id = v_prog.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'programme.transitioned',
          jsonb_build_object('programme_id', p_programme_id,
                             'from', v_prog.status, 'to', p_to_status));

  -- W1-03 HOOK: entering 'maintenance' starts the recurring monthly cycle
  -- (§8.9 "continues with no end date once implementation closes"). W1-03's
  -- monthly-bd1-gen job owns the first maintenance task instance + draft
  -- report generation for the current programme month — call it here (or seed
  -- via scheduled_jobs) once that job lands. Deliberately not written inline:
  -- generation is the scheduler's responsibility, not the transition's.
END $$;
COMMENT ON FUNCTION public.transition_programme(uuid, text) IS
  'W1-05: explicit programme status moves — implementation→maintenance|closed, '
  'maintenance→closed only, logged to audit_log. Closed is terminal. '
  'Maintenance entry carries a W1-03 generate-job hook (see body comment).';


-- ============================================================================
-- 6. update_programme_settings — programme thresholds + FR-SCH-06 start-date
--    change (all dates recalculate). NULL = keep current (decision 8).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_programme_settings(
    p_programme_id            uuid,
    p_red_days_threshold      int   DEFAULT NULL,
    p_report_due_business_day int   DEFAULT NULL,
    p_programme_lead          uuid  DEFAULT NULL,
    p_start_date              date  DEFAULT NULL,
    p_reduced_capacity_weeks  int[] DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog public.programmes;
  v_practice uuid;
  v_changed jsonb := '{}'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme % not found', p_programme_id; END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'programme settings require a programme write role';
  END IF;

  -- validation mirroring the CHECKs (clear errors before the CHECK fires)
  IF p_red_days_threshold IS NOT NULL AND p_red_days_threshold < 0 THEN
    RAISE EXCEPTION 'red_days_threshold must be >= 0';
  END IF;
  IF p_report_due_business_day IS NOT NULL AND p_report_due_business_day < 1 THEN
    RAISE EXCEPTION 'report_due_business_day must be > 0';
  END IF;
  IF p_start_date IS NOT NULL AND extract(isodow FROM p_start_date) <> 1 THEN
    RAISE EXCEPTION 'programme start date must be a Monday (§9.1)';
  END IF;
  IF p_reduced_capacity_weeks IS NOT NULL
     AND EXISTS (SELECT 1 FROM unnest(p_reduced_capacity_weeks) w
                  WHERE w < 1 OR w > v_prog.total_weeks) THEN
    RAISE EXCEPTION 'reduced_capacity_weeks must lie inside 1..% (programme length)',
      v_prog.total_weeks;
  END IF;

  v_changed := jsonb_build_object(
    'red_days_threshold',
      CASE WHEN p_red_days_threshold IS NOT NULL
            AND p_red_days_threshold IS DISTINCT FROM v_prog.red_days_threshold
           THEN p_red_days_threshold END,
    'report_due_business_day',
      CASE WHEN p_report_due_business_day IS NOT NULL
            AND p_report_due_business_day IS DISTINCT FROM v_prog.report_due_business_day
           THEN p_report_due_business_day END,
    'programme_lead',
      CASE WHEN p_programme_lead IS NOT NULL
            AND p_programme_lead IS DISTINCT FROM v_prog.programme_lead
           THEN p_programme_lead END,
    'start_date',
      CASE WHEN p_start_date IS NOT NULL
            AND p_start_date IS DISTINCT FROM v_prog.start_date
           THEN p_start_date END,
    'reduced_capacity_weeks',
      CASE WHEN p_reduced_capacity_weeks IS NOT NULL
            AND p_reduced_capacity_weeks IS DISTINCT FROM v_prog.reduced_capacity_weeks
           THEN to_jsonb(p_reduced_capacity_weeks) END);

  UPDATE public.programmes SET
      red_days_threshold = coalesce(p_red_days_threshold, red_days_threshold),
      report_due_business_day = coalesce(p_report_due_business_day,
                                         report_due_business_day),
      programme_lead = coalesce(p_programme_lead, programme_lead),
      start_date = coalesce(p_start_date, start_date),
      reduced_capacity_weeks = coalesce(p_reduced_capacity_weeks,
                                        reduced_capacity_weeks)
   WHERE id = p_programme_id;

  -- FR-SCH-06: a start-date change recalculates EVERY derived date
  IF p_start_date IS NOT NULL AND p_start_date IS DISTINCT FROM v_prog.start_date THEN
    PERFORM public.recompute_programme_progress(p_programme_id);
  END IF;

  SELECT c.practice_id INTO v_practice FROM public.client_orgs c
   WHERE c.id = v_prog.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'programme.settings_updated',
          jsonb_build_object('programme_id', p_programme_id, 'changed', v_changed));
END $$;
COMMENT ON FUNCTION public.update_programme_settings(uuid, int, int, uuid, date, int[]) IS
  'W1-05: programme settings — red_days_threshold, report_due_business_day, '
  'programme_lead, and FR-SCH-06 start_date + reduced_capacity_weeks. NULL '
  'keeps the current value; a start-date change recomputes every CALC date '
  'through the engine.';


-- ============================================================================
-- 7. list_programmes — partner console programme list (FR-PCN-01 rollup row)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.list_programmes(p_client_org_id uuid DEFAULT NULL)
RETURNS TABLE(
    programme_id            uuid,
    programme_name          text,
    client_org_id           uuid,
    client_name             text,
    framework               text,
    template_version_number int,
    status                  text,
    phase                   text,
    current_week            int,
    total_weeks             int,
    rag                     text,
    activities_total        bigint,
    activities_complete     bigint,
    activities_overdue      bigint,
    register_open           bigint,
    register_closed         bigint,
    evidence_pending        bigint,
    maintenance_due_month   bigint,
    maintenance_overdue_month bigint,
    report_status           text,
    report_due_on           date,
    programme_lead          uuid,
    assigned_consultants    text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.name, p.client_org_id, co.name,
         t.framework, v.number, p.status, p.phase,
         public.programme_week(p.id, CURRENT_DATE), p.total_weeks,
         public.partner_console_rag(p.id),
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id),
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id
            AND a.status = 'Complete'),
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id
            AND a.status <> 'Complete' AND a.due_date IS NOT NULL
            AND a.due_date < CURRENT_DATE),
         (SELECT count(*) FROM public.register_items r WHERE r.programme_id = p.id
            AND r.status <> 'Closed'),
         (SELECT count(*) FROM public.register_items r WHERE r.programme_id = p.id
            AND r.status = 'Closed'),
         (SELECT count(*) FROM public.evidence_items e WHERE e.programme_id = p.id
            AND e.review_stage <> 'decided'),
         (SELECT count(*) FROM public.maintenance_task_instances mti
            JOIN public.maintenance_task_templates mt ON mt.id = mti.task_template_id
           WHERE mt.programme_id = p.id AND mti.status <> 'Complete'
             AND mti.due_date IS NOT NULL
             AND date_trunc('month', mti.due_date) = date_trunc('month', CURRENT_DATE)),
         (SELECT count(*) FROM public.maintenance_task_instances mti
            JOIN public.maintenance_task_templates mt ON mt.id = mti.task_template_id
           WHERE mt.programme_id = p.id AND mti.status <> 'Complete'
             AND mti.due_date IS NOT NULL AND mti.due_date < CURRENT_DATE),
         (SELECT r.status FROM public.programme_reports r
           WHERE r.programme_id = p.id
           ORDER BY r.period DESC LIMIT 1),
         (SELECT coalesce(r.due_on, public.report_due_date(p.id, (r.period || '-01')::date))
            FROM public.programme_reports r
           WHERE r.programme_id = p.id
           ORDER BY r.period DESC LIMIT 1),
         p.programme_lead,
         (SELECT array_agg(u.full_name)
            FROM public.role_assignments ra
            JOIN public.users u ON u.id = ra.user_id
           WHERE ra.level = 'partner' AND ra.role = 'partner_consultant'
             AND ra.start_date <= CURRENT_DATE
             AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
             AND ((ra.scope_type = 'client' AND ra.scope_id = co.id)
               OR (ra.scope_type = 'partner' AND ra.scope_id = co.practice_id)
               OR (ra.scope_type = 'programme' AND ra.scope_id = p.id)))
    FROM public.programmes p
    JOIN public.client_orgs co ON co.id = p.client_org_id
    LEFT JOIN public.programme_template_versions v ON v.id = p.template_version_id
    LEFT JOIN public.programme_templates t ON t.id = v.template_id
   WHERE p.id IN (SELECT public.allowed_programmes())
     AND (p_client_org_id IS NULL OR p.client_org_id = p_client_org_id)
   ORDER BY co.name, p.name
$$;
COMMENT ON FUNCTION public.list_programmes(uuid) IS
  'W1-05 FR-PCN-01: partner-console programme rows — client, framework, '
  'phase, week, console RAG (forced Red on late report/overdue report-fed '
  'task), register/activity/evidence/maintenance rollups, latest report '
  'status + due date, lead and assigned consultants. Scope: one client or '
  'all visible programmes (NULL).';


-- ---------- grants (W0-00 convention: lock the surface) ----------
REVOKE EXECUTE ON FUNCTION
  public.create_programme(uuid, uuid, text, date),
  public.apply_template_version(uuid, uuid),
  public.update_activity(uuid, jsonb),
  public.reorder_activity(uuid, int, int, uuid),
  public.add_activity(uuid, text, text, uuid, int, int, boolean, boolean, uuid[], uuid[]),
  public.close_register_item(uuid, text[]),
  public.transition_programme(uuid, text),
  public.update_programme_settings(uuid, int, int, uuid, date, int[]),
  public.list_programmes(uuid)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.create_programme(uuid, uuid, text, date),
  public.apply_template_version(uuid, uuid),
  public.update_activity(uuid, jsonb),
  public.reorder_activity(uuid, int, int, uuid),
  public.add_activity(uuid, text, text, uuid, int, int, boolean, boolean, uuid[], uuid[]),
  public.close_register_item(uuid, text[]),
  public.transition_programme(uuid, text),
  public.update_programme_settings(uuid, int, int, uuid, date, int[]),
  public.list_programmes(uuid)
TO authenticated;

COMMIT;
