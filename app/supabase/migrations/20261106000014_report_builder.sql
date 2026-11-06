-- ============================================================================
-- W2-08 — MONTHLY REPORT BUILDER RPCs (GitHub #33 · spec SP-SPC-PLT-001 §8.6
-- FR-RPT-01..04/06, §9.5 snapshots, NFR-09, AT-17 · screen 05)
-- ============================================================================
--
-- The W0-02 schema (programme_reports, monthly_snapshots, trg_report_transition)
-- and W1-03's FR-MNT-07 gate (trg_report_maintenance_gate) already exist; this
-- file adds the write surface the screen uses. Every RPC is SECURITY DEFINER
-- and checks tenant + role scope in its own body (a superuser-owned definer
-- bypasses RLS, so the guard must be explicit). auth.uid() IS NULL is the
-- service/scheduler path (W0-02 convention) and runs unguarded.
--
-- SURFACE
--   create_monthly_report(programme, period, p_now)   idempotent per period
--   update_report_draft(report, sections jsonb)       narrative only, draft-like
--   report_inputs_outstanding(report)                 FR-RPT-03 blockers
--   transition_report(report, to_state, note, gate_override_reason)
--   create_report_correction(report, reason)          NFR-09 new version row
--   list_reports(programme, p_now)                    state/due/late/signed/issued
--   report_document(report)                           the composed, print-safe
--                                                     body (screen + W3-03 PDF)
--
-- STATE NAMES (exactly what trg_report_transition enforces, FR-RPT-04):
--   draft → inputs_complete → ao_review → signed → issued
--   back-edges: inputs_complete → draft, ao_review → inputs_complete.
--
-- trg_report_transition is REPLACED here (§3b): authenticated write roles
-- hold a direct UPDATE(status) grant on programme_reports, so every rule of
-- the workflow — FR-RPT-03 narrative completeness, AO-signing, issue-time
-- reference/issued_by minting and the report.transition audit row — lives in
-- the trigger, not only in the RPC. A direct UPDATE is held to exactly the
-- same contract as transition_report.
--
-- DECISIONS (flagged for review):
--   1. SNAPSHOT LOCK (FR-RPT-02, §9.5). Figures are NEVER copied into the
--      editable sections jsonb. The report row binds snapshot_id (write-
--      protected column, and a new trigger refuses re-binding) and
--      report_document() resolves every figure from that append-only
--      monthly_snapshots row at read time. sections only carries the frozen
--      STRUCTURE plus the narrative text, so there is nothing figure-shaped to
--      edit. update_report_draft rejects any key other than the narrative/
--      headline fields.
--   2. MISSING SNAPSHOT. create_monthly_report writes it through the existing
--      service path public.write_monthly_snapshot(programme, month, as_of) —
--      the W1-01 canonical writer (same fixed-key contract; append-only, one
--      per period). It refuses while the period's last business day (§9.5
--      snapshot day, programme jurisdiction calendar) has not been reached,
--      so a report can never lock mid-month figures. as_of = min(p_now,
--      snapshot day 18:00) so date-based rules (overdue counts, RAG) evaluate
--      as at the snapshot day; status counts are necessarily those at the
--      catch-up moment (the W1-09 month-end job normally writes it on time —
--      the catch-up path only runs when that job missed the period).
--   3. STRUCTURE comes from the programme's template version
--      content.report_structure.sections ([{key,title?,figures?,narrative?}],
--      FR-RPT-01) and is frozen onto the report at creation, so a later
--      template version never reshapes an existing report. `figures` lists
--      snapshot keys; when a template entry omits it, a fallback map by
--      section key applies (report_default_figures — the known POPIA section
--      keys; unknown keys get none). `narrative` is required|optional|none
--      (default required). A template without report_structure gets a two-
--      section fallback (all figures + a required commentary). No legal text
--      or periods are encoded here — titles default to the humanised key.
--   4. CORRECTIONS (NFR-09: "later changes create new versions"). Added
--      version / supersedes_id / issued_by columns. The W0-02 UNIQUE
--      (programme_id, period) becomes UNIQUE (programme_id, period, version)
--      plus a partial unique index allowing at most ONE unissued row per
--      period. create_report_correction(issued report) opens version n+1 as a
--      draft bound to the SAME snapshot (figures cannot change, §9.5) with the
--      narrative copied; the issued row is never touched.
--   5. LATE (FR-RPT-06): due = coalesce(due_on, report_due_date(period)).
--      late = (first issue of the period, else p_now)::date > due — issuing
--      ON the due business day is on time. A correction inherits the period's
--      first-issue date, so correcting an on-time report never makes it late.
--   6. CONTENT LOCK (NFR-09 "signed reports are locked"): new trigger
--      report_content_lock refuses content edits (sections, headline,
--      commentary, overall_rag, trend, gate_override_reason) whenever the row
--      ENDS in ao_review/signed after starting there — to amend, return it to
--      inputs_complete. Issued rows stay with trg_report_transition.
--   7. ROLES. WRITE := partner_admin, partner_consultant, programme_lead,
--      client_admin (the W0-02 write set and the exact set
--      trg_report_maintenance_gate allows to record gate_override_reason).
--      Draft edits, create, draft↔inputs_complete: WRITE. Submit to AO review:
--      WRITE or the accountable_officer; the override reason only for WRITE
--      (the gate's set — checked here AND by the trigger). Return from review:
--      WRITE or AO/alternate, note required. Sign: is_ao_or_alternate only
--      (also enforced by trg_report_transition). Issue: WRITE or AO/alternate.
--   8. REFERENCE minted on issue as RPT-<period>-v<version> (no partner report
--      reference format column exists yet — FR-BRN-04 follow-up).
--   9. The generated report text never asserts certification or compliance:
--      the only platform-authored strings are section titles from the template
--      / humanised keys and the fallback titles below.
-- ============================================================================

BEGIN;

-- ---------- 0. additive schema ----------
ALTER TABLE public.programme_reports
  ADD COLUMN IF NOT EXISTS version       int  NOT NULL DEFAULT 1 CHECK (version > 0),
  ADD COLUMN IF NOT EXISTS supersedes_id uuid REFERENCES public.programme_reports(id),
  ADD COLUMN IF NOT EXISTS issued_by     uuid REFERENCES public.users(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.programme_reports.version IS
  'W2-08 NFR-09: 1 = original; a correction of an issued report is a new row with version n+1 — write-protected.';
COMMENT ON COLUMN public.programme_reports.supersedes_id IS
  'W2-08 NFR-09: the issued version this correction supersedes — write-protected.';
COMMENT ON COLUMN public.programme_reports.issued_by IS
  'W2-08: who issued the report (issued_on is the when) — write-protected.';
-- no INSERT/UPDATE grants on the new columns: definer-written only. (SELECT is
-- table-level on programme_reports, so the columns are readable under RLS.)

ALTER TABLE public.programme_reports
  DROP CONSTRAINT IF EXISTS programme_reports_programme_id_period_key;
ALTER TABLE public.programme_reports
  DROP CONSTRAINT IF EXISTS programme_reports_programme_period_version_key;
ALTER TABLE public.programme_reports
  ADD CONSTRAINT programme_reports_programme_period_version_key
  UNIQUE (programme_id, period, version);
CREATE UNIQUE INDEX IF NOT EXISTS programme_reports_one_open_per_period
  ON public.programme_reports (programme_id, period) WHERE status <> 'issued';


-- ---------- 1. structure helpers (pure) ----------

-- The ten fixed snapshot keys (W0-02 monthly_snapshots contract).
CREATE OR REPLACE FUNCTION public.report_snapshot_keys()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT ARRAY['rag','activities_complete','activities_overdue','register_closed',
               'register_open','high_priority_closed','evidence_pending',
               'kpi_actuals','maintenance_done','maintenance_overdue']
$$;

-- Fallback figure list for a section whose template entry omits `figures`.
CREATE OR REPLACE FUNCTION public.report_default_figures(p_key text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE p_key
    WHEN 'executive_summary'  THEN ARRAY['rag','activities_complete','activities_overdue',
                                         'register_closed','register_open']
    WHEN 'register_progress'  THEN ARRAY['register_closed','register_open','high_priority_closed']
    WHEN 'activity_schedule'  THEN ARRAY['activities_complete','activities_overdue']
    WHEN 'evidence_status'    THEN ARRAY['evidence_pending']
    WHEN 'kpi_summary'        THEN ARRAY['kpi_actuals']
    WHEN 'maintenance_status' THEN ARRAY['maintenance_done','maintenance_overdue']
    ELSE ARRAY[]::text[]
  END
$$;

-- Normalise a template report_structure.sections array (or a legacy sections
-- object) into [{key,title,figures[],narrative}].
CREATE OR REPLACE FUNCTION public.report_normalise_structure(p_sections jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  WITH els AS (
    SELECT ord,
           CASE jsonb_typeof(s) WHEN 'string' THEN s #>> '{}' ELSE s ->> 'key' END AS key,
           CASE jsonb_typeof(s) WHEN 'object' THEN s ELSE '{}'::jsonb END AS o
      FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(p_sections) = 'array' THEN p_sections
                  ELSE '[]'::jsonb END) WITH ORDINALITY u(s, ord)
  ), ok AS (
    SELECT DISTINCT ON (key) ord, key, o FROM els
     WHERE coalesce(key, '') ~ '^[a-z0-9_]{1,64}$'
     ORDER BY key, ord
  )
  SELECT CASE WHEN EXISTS (SELECT 1 FROM ok) THEN
    (SELECT jsonb_agg(jsonb_build_object(
        'key', key,
        'title', coalesce(nullif(btrim(o ->> 'title'), ''),
                          initcap(replace(key, '_', ' '))),
        'figures', CASE WHEN jsonb_typeof(o -> 'figures') = 'array'
                        THEN coalesce((SELECT jsonb_agg(f) FROM jsonb_array_elements_text(o -> 'figures') f
                                        WHERE f ~ '^[a-z0-9_]{1,64}$'), '[]'::jsonb)
                        ELSE to_jsonb(public.report_default_figures(key)) END,
        'narrative', CASE WHEN o ->> 'narrative' IN ('required','optional','none')
                          THEN o ->> 'narrative' ELSE 'required' END)
       ORDER BY ord) FROM ok)
  ELSE jsonb_build_array(
         jsonb_build_object('key','monthly_figures','title','Monthly figures',
                            'figures', to_jsonb(public.report_snapshot_keys()),
                            'narrative','optional'),
         jsonb_build_object('key','commentary','title','Commentary',
                            'figures','[]'::jsonb,'narrative','required'))
  END
$$;
COMMENT ON FUNCTION public.report_normalise_structure(jsonb) IS
  'W2-08 FR-RPT-01: template report_structure.sections → [{key,title,figures,narrative}] '
  '(decision 3). Fallback when empty: all figures + a required commentary.';

-- The (structure, narrative) view of any stored sections value — new-shape
-- {"structure":[…],"narrative":{…}} or the W0-05 legacy {key: text|object}.
CREATE OR REPLACE FUNCTION public.report_sections_view(p_sections jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE
    WHEN jsonb_typeof(p_sections -> 'structure') = 'array' THEN
      jsonb_build_object('structure', p_sections -> 'structure',
                         'narrative', coalesce(p_sections -> 'narrative', '{}'::jsonb))
    ELSE
      jsonb_build_object(
        'structure', public.report_normalise_structure(
            (SELECT jsonb_agg(k ORDER BY k) FROM jsonb_object_keys(
               CASE WHEN jsonb_typeof(p_sections) = 'object' THEN p_sections
                    ELSE '{}'::jsonb END) k)),
        -- legacy non-text values were figure copies, never narrative: dropped
        'narrative', coalesce((SELECT jsonb_object_agg(k, v)
                       FROM jsonb_each(CASE WHEN jsonb_typeof(p_sections) = 'object'
                                            THEN p_sections ELSE '{}'::jsonb END) e(k, v)
                      WHERE jsonb_typeof(v) = 'string'),
                     '{}'::jsonb))
  END
$$;


-- ---------- 2. scope helpers ----------
CREATE OR REPLACE FUNCTION public.report_write_roles()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']
$$;

-- Load a report the caller can see, or raise (same answer for absent/hidden).
CREATE OR REPLACE FUNCTION public.report_for_caller(p_report uuid)
RETURNS public.programme_reports
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.programme_reports;
BEGIN
  SELECT * INTO r FROM public.programme_reports WHERE id = p_report;
  IF NOT FOUND
     OR (auth.uid() IS NOT NULL
         AND r.programme_id NOT IN (SELECT public.allowed_programmes())) THEN
    RAISE EXCEPTION 'report % not found or not visible to the caller', p_report
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN r;
END $$;


-- ---------- 3. content + snapshot lock trigger (decisions 1, 6) ----------
CREATE OR REPLACE FUNCTION public.trg_report_content_lock() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF OLD.status = 'issued' THEN
    RETURN NEW;                      -- report_transition_gate refuses (§9.5)
  END IF;
  IF NEW.programme_id IS DISTINCT FROM OLD.programme_id
     OR NEW.period IS DISTINCT FROM OLD.period
     OR NEW.version IS DISTINCT FROM OLD.version
     OR NEW.supersedes_id IS DISTINCT FROM OLD.supersedes_id THEN
    RAISE EXCEPTION 'a report''s programme, period and version cannot change (NFR-09)';
  END IF;
  -- snapshot binding is permanent; the only way to NULL is the FK's ON DELETE
  -- SET NULL after the snapshot row itself is gone (service teardown).
  IF OLD.snapshot_id IS NOT NULL AND NEW.snapshot_id IS DISTINCT FROM OLD.snapshot_id
     AND NOT (NEW.snapshot_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.monthly_snapshots s
                               WHERE s.id = OLD.snapshot_id)) THEN
    RAISE EXCEPTION 'report % is bound to its month-end snapshot — snapshot figures cannot be changed (§9.5)',
      OLD.period;
  END IF;
  IF OLD.status IN ('ao_review','signed')
     AND NEW.status NOT IN ('draft','inputs_complete')
     AND (NEW.sections IS DISTINCT FROM OLD.sections
          OR NEW.headline IS DISTINCT FROM OLD.headline
          OR NEW.commentary IS DISTINCT FROM OLD.commentary
          OR NEW.overall_rag IS DISTINCT FROM OLD.overall_rag
          OR NEW.trend IS DISTINCT FROM OLD.trend
          OR NEW.gate_override_reason IS DISTINCT FROM OLD.gate_override_reason) THEN
    RAISE EXCEPTION 'report content is locked while %: return it to inputs_complete to amend (NFR-09)',
      OLD.status;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_report_content_lock() IS
  'W2-08 §9.5/NFR-09: snapshot binding permanent; identity columns fixed; '
  'content frozen in ao_review/signed. Issued rows: report_transition_gate.';

DROP TRIGGER IF EXISTS report_content_lock ON public.programme_reports;
CREATE TRIGGER report_content_lock
BEFORE UPDATE ON public.programme_reports
FOR EACH ROW EXECUTE FUNCTION public.trg_report_content_lock();


-- ---------- 3b. transition gate — completeness + issue stamping ----------
-- W0-02's trg_report_transition enforced the legal FR-RPT-04 edges and the
-- AO-signing check, but the rest of the contract lived only inside
-- transition_report — and authenticated write roles hold a direct
-- UPDATE(status) grant on programme_reports. Replaced here (CREATE OR
-- REPLACE; the report_transition_gate trigger name is unchanged) so EVERY
-- write path enforces the whole contract:
--   · draft→inputs_complete requires every required-structure narrative
--     filled (FR-RPT-03) — previously RPC-only, so a direct UPDATE could
--     push an incomplete report forward;
--   · →issued stamps issued_on/issued_by and mints the reference when the
--     row lands without one — a direct signed→issued can no longer produce
--     a reference-less issued report;
--   · EVERY status transition writes the 'report.transition' audit_log row
--     here (trg_raid_status_history precedent), so a direct write cannot
--     change state silently. transition_report passes the caller's note
--     through the securepath.report_transition_note GUC and no longer
--     inserts its own row — one audit row per transition on every path.
CREATE OR REPLACE FUNCTION public.trg_report_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_view jsonb; v_missing text; v_practice uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'issued' THEN
      RAISE EXCEPTION 'an issued report cannot be deleted (§9.5)';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'issued' THEN
    RAISE EXCEPTION 'an issued report cannot change afterwards (§9.5)';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT ( (OLD.status = 'draft'           AND NEW.status = 'inputs_complete')
          OR (OLD.status = 'inputs_complete' AND NEW.status IN ('ao_review','draft'))
          OR (OLD.status = 'ao_review'       AND NEW.status IN ('signed','inputs_complete'))
          OR (OLD.status = 'signed'          AND NEW.status = 'issued') ) THEN
      RAISE EXCEPTION 'illegal report transition % → % (FR-RPT-04)', OLD.status, NEW.status;
    END IF;
    -- FR-RPT-03 on every write path: a required narrative cannot be blank
    -- when the draft's inputs are declared complete.
    IF OLD.status = 'draft' AND NEW.status = 'inputs_complete' THEN
      v_view := public.report_sections_view(NEW.sections);
      SELECT string_agg(s ->> 'title', ', ' ORDER BY ord) INTO v_missing
        FROM jsonb_array_elements(v_view -> 'structure') WITH ORDINALITY u(s, ord)
       WHERE s ->> 'narrative' = 'required'
         AND coalesce(btrim(v_view -> 'narrative' ->> (s ->> 'key')), '') = '';
      IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'inputs are not complete — narrative still missing for: % (FR-RPT-03)', v_missing;
      END IF;
    END IF;
    IF NEW.status = 'signed' AND auth.uid() IS NOT NULL
       AND NOT public.is_ao_or_alternate(
                 (SELECT client_org_id FROM public.programmes WHERE id = NEW.programme_id)) THEN
      RAISE EXCEPTION 'only the accountable officer or named alternate may sign the monthly report';
    END IF;
    IF NEW.status = 'issued' THEN
      NEW.issued_on := now();
      NEW.issued_by := coalesce(NEW.issued_by, auth.uid());
      NEW.reference := coalesce(nullif(btrim(NEW.reference), ''),
                                'RPT-' || NEW.period || '-v' || NEW.version);
    END IF;
    SELECT c.practice_id INTO v_practice
      FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
     WHERE p.id = NEW.programme_id;
    INSERT INTO public.audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), v_practice, 'report.transition',
            jsonb_build_object('report_id', NEW.id, 'programme_id', NEW.programme_id,
                               'period', NEW.period, 'version', NEW.version,
                               'from', OLD.status, 'to', NEW.status,
                               'note', nullif(current_setting('securepath.report_transition_note', true), ''),
                               'gate_override_reason', NEW.gate_override_reason));
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_report_transition() IS
  'W0-02 FR-RPT-04 edges + AO-signing + §9.5 issued immutability; W2-08 adds '
  'the FR-RPT-03 narrative-completeness check, issue-time stamping '
  '(issued_on/issued_by/reference) and the report.transition audit row — all '
  'enforced on every write path, not just transition_report.';


-- ---------- 4. create_monthly_report ----------
CREATE OR REPLACE FUNCTION public.create_monthly_report(
    p_programme_id uuid, p_period text, p_now timestamptz DEFAULT now())
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog public.programmes%ROWTYPE;
  v_month date; v_snap uuid; v_id uuid; v_snapday date; v_asof timestamptz;
  v_structure jsonb; v_practice uuid; v_wrote_snapshot boolean := false;
  -- the injectable clock is for the service/scheduler path only: a JWT caller
  -- always runs at now(), so it cannot fake the snapshot day (decision 2)
  v_now timestamptz := CASE WHEN auth.uid() IS NULL THEN coalesce(p_now, now()) ELSE now() END;
BEGIN
  IF coalesce(p_period, '') !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' THEN
    RAISE EXCEPTION 'period % must look like YYYY-MM', p_period;
  END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id;
  IF NOT FOUND
     OR (auth.uid() IS NOT NULL
         AND p_programme_id NOT IN (SELECT public.allowed_programmes())) THEN
    RAISE EXCEPTION 'programme % not found or not visible to the caller', p_programme_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF auth.uid() IS NOT NULL
     AND NOT public.has_programme_role(p_programme_id, public.report_write_roles()) THEN
    RAISE EXCEPTION 'create_monthly_report: no write role on programme %', p_programme_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_month := (p_period || '-01')::date;

  -- idempotent: an existing report for the period (latest version) is returned
  SELECT id INTO v_id FROM public.programme_reports
   WHERE programme_id = p_programme_id AND period = p_period
   ORDER BY version DESC LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- bind the period's snapshot; write it via the service path if missing
  SELECT id INTO v_snap FROM public.monthly_snapshots
   WHERE programme_id = p_programme_id AND period = p_period;
  IF v_snap IS NULL THEN
    v_snapday := public.last_business_day(public.programme_jurisdiction(p_programme_id), v_month);
    IF v_now::date < v_snapday THEN
      RAISE EXCEPTION 'the % snapshot is taken on the period''s last business day (%) — a report cannot be built from mid-month figures (§9.5)',
        p_period, v_snapday;
    END IF;
    v_asof := least(v_now, (v_snapday::timestamp + time '18:00')::timestamptz);
    v_snap := public.write_monthly_snapshot(p_programme_id, v_month, v_asof);
    v_wrote_snapshot := true;
  END IF;

  SELECT public.report_normalise_structure(v.content -> 'report_structure' -> 'sections')
    INTO v_structure
    FROM public.programme_template_versions v WHERE v.id = v_prog.template_version_id;
  v_structure := coalesce(v_structure, public.report_normalise_structure(NULL));

  INSERT INTO public.programme_reports
      (programme_id, period, version, snapshot_id, sections, status, due_on)
  VALUES (p_programme_id, p_period, 1, v_snap,
          jsonb_build_object('structure', v_structure, 'narrative', '{}'::jsonb),
          'draft', public.report_due_date(p_programme_id, v_month))
  ON CONFLICT (programme_id, period, version) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN                      -- lost a race: return the winner
    SELECT id INTO v_id FROM public.programme_reports
     WHERE programme_id = p_programme_id AND period = p_period
     ORDER BY version DESC LIMIT 1;
    RETURN v_id;
  END IF;

  SELECT c.practice_id INTO v_practice FROM public.client_orgs c WHERE c.id = v_prog.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'report.created',
          jsonb_build_object('programme_id', p_programme_id, 'period', p_period,
                             'report_id', v_id, 'snapshot_id', v_snap,
                             'snapshot_written', v_wrote_snapshot));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.create_monthly_report(uuid, text, timestamptz) IS
  'W2-08 FR-RPT-01/02: draft report for a programme month, bound to that '
  'month''s §9.5 snapshot (written via write_monthly_snapshot if missing, '
  'never before the snapshot day). Idempotent: returns the existing latest '
  'version for the period. p_now is honoured on the service path only.';


-- ---------- 5. update_report_draft ----------
-- p_sections = {"narrative": {section_key: text|null, …},
--               "headline": text, "commentary": text,
--               "overall_rag": "Red"|"Amber"|"Green"|null, "trend": text}
-- Every key optional; only supplied keys change. Anything else is refused.
CREATE OR REPLACE FUNCTION public.update_report_draft(p_report_id uuid, p_sections jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.programme_reports; v_view jsonb; v_narr jsonb; v_bad text;
  k text; v jsonb; v_mode text;
BEGIN
  r := public.report_for_caller(p_report_id);
  IF auth.uid() IS NOT NULL
     AND NOT public.has_programme_role(r.programme_id, public.report_write_roles()) THEN
    RAISE EXCEPTION 'update_report_draft: no write role on this programme'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF r.status NOT IN ('draft','inputs_complete') THEN
    RAISE EXCEPTION 'report is % — only draft or inputs_complete reports can be edited (NFR-09)', r.status;
  END IF;
  IF p_sections IS NULL OR jsonb_typeof(p_sections) <> 'object' THEN
    RAISE EXCEPTION 'sections must be a JSON object';
  END IF;
  SELECT string_agg(key, ', ') INTO v_bad FROM jsonb_object_keys(p_sections) key
   WHERE key NOT IN ('narrative','headline','commentary','overall_rag','trend');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'only narrative fields are editable — snapshot figures and report structure are locked (§9.5); refused keys: %', v_bad;
  END IF;

  v_view := public.report_sections_view(r.sections);
  v_narr := v_view -> 'narrative';
  IF p_sections ? 'narrative' THEN
    IF jsonb_typeof(p_sections -> 'narrative') <> 'object' THEN
      RAISE EXCEPTION 'narrative must be an object of section key → text';
    END IF;
    FOR k, v IN SELECT * FROM jsonb_each(p_sections -> 'narrative') LOOP
      SELECT s ->> 'narrative' INTO v_mode
        FROM jsonb_array_elements(v_view -> 'structure') s WHERE s ->> 'key' = k;
      IF v_mode IS NULL THEN
        RAISE EXCEPTION 'section % is not in this report''s structure', k;
      END IF;
      IF v_mode = 'none' THEN
        RAISE EXCEPTION 'section % is figures-only — it takes no narrative (snapshot-locked)', k;
      END IF;
      IF jsonb_typeof(v) NOT IN ('string','null') THEN
        RAISE EXCEPTION 'narrative for section % must be text — figures cannot be supplied (§9.5)', k;
      END IF;
      v_narr := CASE WHEN jsonb_typeof(v) = 'null' OR btrim(v #>> '{}') = ''
                     THEN v_narr - k ELSE jsonb_set(v_narr, ARRAY[k], v) END;
    END LOOP;
  END IF;
  IF p_sections ? 'overall_rag'
     AND coalesce(p_sections ->> 'overall_rag', 'Red') NOT IN ('Red','Amber','Green') THEN
    RAISE EXCEPTION 'overall_rag must be Red, Amber or Green';
  END IF;

  UPDATE public.programme_reports SET
    sections    = jsonb_build_object('structure', v_view -> 'structure', 'narrative', v_narr),
    headline    = CASE WHEN p_sections ? 'headline'    THEN nullif(btrim(p_sections ->> 'headline'), '')    ELSE headline END,
    commentary  = CASE WHEN p_sections ? 'commentary'  THEN nullif(btrim(p_sections ->> 'commentary'), '')  ELSE commentary END,
    overall_rag = CASE WHEN p_sections ? 'overall_rag' THEN p_sections ->> 'overall_rag'                    ELSE overall_rag END,
    trend       = CASE WHEN p_sections ? 'trend'       THEN nullif(btrim(p_sections ->> 'trend'), '')       ELSE trend END
  WHERE id = r.id;
END $$;
COMMENT ON FUNCTION public.update_report_draft(uuid, jsonb) IS
  'W2-08: narrative/headline edits on a draft-like report (write roles). '
  'Snapshot figures are not stored in sections and cannot be supplied.';


-- ---------- 6. report_inputs_outstanding (FR-RPT-03) ----------
CREATE OR REPLACE FUNCTION public.report_inputs_outstanding(p_report_id uuid)
RETURNS TABLE(kind text, ref text, label text, status text, due_date date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE r public.programme_reports; v_view jsonb;
BEGIN
  r := public.report_for_caller(p_report_id);
  v_view := public.report_sections_view(r.sections);
  RETURN QUERY
    SELECT 'maintenance_task'::text, f.code, f.task, f.status, f.due_date
      FROM public.report_open_feeding_tasks(r.programme_id, r.period) f
    UNION ALL
    SELECT 'narrative'::text, s ->> 'key', s ->> 'title', 'missing'::text, NULL::date
      FROM jsonb_array_elements(v_view -> 'structure') WITH ORDINALITY u(s, ord)
     WHERE s ->> 'narrative' = 'required'
       AND coalesce(btrim(v_view -> 'narrative' ->> (s ->> 'key')), '') = '';
END $$;
COMMENT ON FUNCTION public.report_inputs_outstanding(uuid) IS
  'W2-08 FR-RPT-03: open report-feeding maintenance tasks for the period '
  '(FR-MNT-07 gate list) + required sections with no narrative yet.';


-- ---------- 7. transition_report (FR-RPT-04) ----------
CREATE OR REPLACE FUNCTION public.transition_report(
    p_report_id uuid, p_to_state text, p_note text DEFAULT NULL,
    p_gate_override_reason text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.programme_reports; v_client uuid;
  v_write boolean; v_ao boolean; v_missing text; v_role text;
  v_reason text := nullif(btrim(coalesce(p_gate_override_reason, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
BEGIN
  r := public.report_for_caller(p_report_id);
  SELECT p.client_org_id INTO v_client
    FROM public.programmes p WHERE p.id = r.programme_id;
  v_write := auth.uid() IS NULL
             OR public.has_programme_role(r.programme_id, public.report_write_roles());
  v_ao    := auth.uid() IS NOT NULL AND public.is_ao_or_alternate(v_client);

  IF r.status = 'issued' THEN
    RAISE EXCEPTION 'an issued report cannot change afterwards (§9.5) — open a correction instead';
  END IF;
  IF p_to_state IS NULL OR p_to_state NOT IN ('draft','inputs_complete','ao_review','signed','issued') THEN
    RAISE EXCEPTION 'unknown report state % (draft|inputs_complete|ao_review|signed|issued)', p_to_state;
  END IF;
  IF v_reason IS NOT NULL AND p_to_state <> 'ao_review' THEN
    RAISE EXCEPTION 'a gate override reason only applies when submitting to AO review';
  END IF;

  IF p_to_state = 'inputs_complete' AND r.status = 'draft' THEN
    IF NOT v_write THEN
      RAISE EXCEPTION 'only the programme lead or a partner delegate may mark inputs complete'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT string_agg(o.label, ', ') INTO v_missing
      FROM public.report_inputs_outstanding(r.id) o WHERE o.kind = 'narrative';
    IF v_missing IS NOT NULL THEN
      RAISE EXCEPTION 'inputs are not complete — narrative still missing for: % (FR-RPT-03)', v_missing;
    END IF;
  ELSIF p_to_state = 'inputs_complete' AND r.status = 'ao_review' THEN
    IF NOT (v_write OR v_ao) THEN
      RAISE EXCEPTION 'only the accountable officer, alternate or programme lead may return a report from review'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF v_note IS NULL THEN
      RAISE EXCEPTION 'returning a report from AO review needs a note saying what to change';
    END IF;
  ELSIF p_to_state = 'draft' THEN
    IF NOT v_write THEN
      RAISE EXCEPTION 'only the programme lead or a partner delegate may reopen a draft'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF p_to_state = 'ao_review' THEN
    IF NOT (v_write OR (auth.uid() IS NOT NULL
                        AND public.has_programme_role(r.programme_id, ARRAY['accountable_officer']))) THEN
      RAISE EXCEPTION 'only the programme lead, a partner delegate or the accountable officer may submit for AO review'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF v_reason IS NOT NULL AND NOT v_write THEN
      -- same rule trg_report_maintenance_gate enforces (FR-MNT-07, decision 7)
      RAISE EXCEPTION 'only the programme lead or a partner delegate may record the maintenance gate reason (FR-MNT-07)'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF p_to_state = 'signed' THEN
    IF auth.uid() IS NOT NULL AND NOT v_ao THEN
      RAISE EXCEPTION 'only the accountable officer or named alternate may sign the monthly report'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF p_to_state = 'issued' THEN
    IF NOT (v_write OR v_ao) THEN
      RAISE EXCEPTION 'only the programme lead, a partner delegate or the accountable officer may issue the report'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- the legal edge itself, the FR-RPT-03 completeness check, the FR-MNT-07
  -- gate, the AO-sign check, issue-time stamping (issued_on/issued_by/
  -- reference) and the 'report.transition' audit row are ALL enforced by
  -- trg_report_transition on this UPDATE, so the direct-UPDATE grant path is
  -- held to exactly the same contract; trigger messages surface unchanged.
  -- The caller's note reaches the trigger-written audit row through the GUC
  -- (securepath.report_transition_note — the raid_status_history pattern).
  PERFORM set_config('securepath.report_transition_note', coalesce(v_note, ''), true);
  IF p_to_state = 'signed' THEN
    v_role := CASE WHEN EXISTS (
                SELECT 1 FROM public.role_assignments ra
                 WHERE ra.user_id = auth.uid() AND ra.level = 'client'
                   AND ra.role = 'accountable_officer'
                   AND ra.start_date <= CURRENT_DATE
                   AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
                   AND ( (ra.scope_type = 'client' AND ra.scope_id = v_client)
                      OR (ra.scope_type = 'programme' AND ra.scope_id IN
                           (SELECT p.id FROM public.programmes p WHERE p.client_org_id = v_client)) ))
              THEN 'accountable_officer' ELSE 'alternate' END;
    UPDATE public.programme_reports
       SET status = 'signed',
           signatures = signatures || jsonb_build_array(jsonb_build_object(
             'role', v_role, 'user', auth.uid(), 'at', now(), 'note', v_note))
     WHERE id = r.id;
  ELSIF p_to_state = 'issued' THEN
    UPDATE public.programme_reports SET status = 'issued' WHERE id = r.id;
  ELSIF p_to_state = 'ao_review' THEN
    UPDATE public.programme_reports
       SET status = 'ao_review',
           gate_override_reason = coalesce(v_reason, gate_override_reason)
     WHERE id = r.id;
  ELSE
    UPDATE public.programme_reports SET status = p_to_state WHERE id = r.id;
  END IF;
  PERFORM set_config('securepath.report_transition_note', '', true);

  RETURN p_to_state;
END $$;
COMMENT ON FUNCTION public.transition_report(uuid, text, text, text) IS
  'W2-08 FR-RPT-04: draft→inputs_complete→ao_review→signed→issued (+ the two '
  'back-edges). Role per edge in body (decision 7); legal edges, FR-RPT-03 '
  'completeness, AO-sign, the FR-MNT-07 gate, issue stamping and the '
  'report.transition audit row all enforced by trg_report_transition so the '
  'direct UPDATE grant path is held to the same contract.';


-- ---------- 8. create_report_correction (NFR-09) ----------
CREATE OR REPLACE FUNCTION public.create_report_correction(
    p_report_id uuid, p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.programme_reports; v_latest int; v_id uuid; v_practice uuid; v_view jsonb;
BEGIN
  r := public.report_for_caller(p_report_id);
  IF auth.uid() IS NOT NULL
     AND NOT public.has_programme_role(r.programme_id, public.report_write_roles()) THEN
    RAISE EXCEPTION 'create_report_correction: no write role on this programme'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF r.status <> 'issued' THEN
    RAISE EXCEPTION 'only an issued report is corrected by a new version — this one is % and can still be edited', r.status;
  END IF;
  IF nullif(btrim(coalesce(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'a correction needs a reason';
  END IF;
  SELECT max(version) INTO v_latest FROM public.programme_reports
   WHERE programme_id = r.programme_id AND period = r.period;
  IF v_latest <> r.version THEN
    RAISE EXCEPTION 'version % is already superseded — correct the latest version (%)', r.version, v_latest;
  END IF;
  v_view := public.report_sections_view(r.sections);
  INSERT INTO public.programme_reports
      (programme_id, period, version, supersedes_id, snapshot_id, sections,
       overall_rag, trend, headline, commentary, status, due_on)
  VALUES (r.programme_id, r.period, r.version + 1, r.id, r.snapshot_id,
          v_view, r.overall_rag, r.trend, r.headline, r.commentary, 'draft', r.due_on)
  RETURNING id INTO v_id;

  SELECT c.practice_id INTO v_practice FROM public.programmes p
    JOIN public.client_orgs c ON c.id = p.client_org_id WHERE p.id = r.programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'report.correction_opened',
          jsonb_build_object('report_id', v_id, 'supersedes_id', r.id,
                             'period', r.period, 'version', r.version + 1,
                             'reason', btrim(p_reason)));
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'a correction for % is already open', r.period;
END $$;
COMMENT ON FUNCTION public.create_report_correction(uuid, text) IS
  'W2-08 NFR-09: new draft version of an issued report, bound to the same '
  'snapshot; the issued row is never modified.';


-- ---------- 9. list_reports ----------
CREATE OR REPLACE FUNCTION public.list_reports(
    p_programme_id uuid, p_now timestamptz DEFAULT now())
RETURNS TABLE(
  id uuid, period text, version int, status text, reference text,
  due_on date, late boolean, days_late int,
  snapshot_id uuid, snapshot_taken_at timestamptz,
  signed_at timestamptz, signed_by uuid, signed_by_name text,
  issued_on timestamptz, issued_by uuid, issued_by_name text,
  supersedes_id uuid, is_latest boolean, inputs_outstanding int,
  gate_override_reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
BEGIN
  IF p_programme_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.programmes WHERE programmes.id = p_programme_id)
     OR (auth.uid() IS NOT NULL
         AND p_programme_id NOT IN (SELECT public.allowed_programmes())) THEN
    RAISE EXCEPTION 'programme % not found or not visible to the caller', p_programme_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
  WITH base AS (
    SELECT r.*,
           coalesce(r.due_on, public.report_due_date(r.programme_id, (r.period || '-01')::date)) AS due,
           (SELECT min(x.issued_on) FROM public.programme_reports x
             WHERE x.programme_id = r.programme_id AND x.period = r.period
               AND x.status = 'issued') AS first_issue,
           (r.signatures -> -1) AS sig
      FROM public.programme_reports r
     WHERE r.programme_id = p_programme_id
  )
  SELECT b.id, b.period, b.version, b.status, b.reference,
         b.due,
         (b.due IS NOT NULL AND coalesce(b.first_issue::date, p_now::date) > b.due),
         CASE WHEN b.due IS NOT NULL AND coalesce(b.first_issue::date, p_now::date) > b.due
              THEN (coalesce(b.first_issue::date, p_now::date) - b.due) ELSE 0 END,
         b.snapshot_id, s.taken_at,
         (b.sig ->> 'at')::timestamptz, (b.sig ->> 'user')::uuid,
         (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
            FROM public.users u WHERE u.id = (b.sig ->> 'user')::uuid),
         b.issued_on, b.issued_by,
         (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
            FROM public.users u WHERE u.id = b.issued_by),
         b.supersedes_id,
         NOT EXISTS (SELECT 1 FROM public.programme_reports n
                      WHERE n.programme_id = b.programme_id AND n.period = b.period
                        AND n.version > b.version),
         CASE WHEN b.status = 'issued' THEN 0
              ELSE (SELECT count(*)::int FROM public.report_inputs_outstanding(b.id)) END,
         b.gate_override_reason
    FROM base b
    LEFT JOIN public.monthly_snapshots s ON s.id = b.snapshot_id
   ORDER BY b.period DESC, b.version DESC;
END $$;
COMMENT ON FUNCTION public.list_reports(uuid, timestamptz) IS
  'W2-08 FR-RPT-06: the programme''s reports with state, due date, late flag '
  '(not issued by the due business day — decision 5), signed + issued info.';


-- ---------- 10. report_document — the one composed body ----------
-- Everything the screen and W3-03's PDF print need, figures resolved from the
-- bound snapshot (never from editable data).
CREATE OR REPLACE FUNCTION public.report_document(p_report_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.programme_reports; v_view jsonb; v_snap public.monthly_snapshots;
        v_prog public.programmes; v_client public.client_orgs; v_list record;
BEGIN
  r := public.report_for_caller(p_report_id);
  v_view := public.report_sections_view(r.sections);
  SELECT * INTO v_snap FROM public.monthly_snapshots WHERE id = r.snapshot_id;
  SELECT * INTO v_prog FROM public.programmes WHERE id = r.programme_id;
  SELECT * INTO v_client FROM public.client_orgs WHERE id = v_prog.client_org_id;
  SELECT * INTO v_list FROM public.list_reports(r.programme_id) l WHERE l.id = r.id;
  RETURN jsonb_build_object(
    'id', r.id, 'period', r.period, 'version', r.version, 'status', r.status,
    'reference', r.reference, 'supersedes_id', r.supersedes_id,
    'programme', jsonb_build_object('id', v_prog.id, 'name', v_prog.name),
    'client', jsonb_build_object('id', v_client.id,
                                 'name', coalesce(v_client.trading_name, v_client.legal_name, v_client.name)),
    'branding', public.partner_branding(v_client.id),
    'headline', r.headline, 'commentary', r.commentary,
    'overall_rag', r.overall_rag, 'trend', r.trend,
    'gate_override_reason', r.gate_override_reason,
    'due_on', v_list.due_on, 'late', v_list.late, 'days_late', v_list.days_late,
    'snapshot', CASE WHEN v_snap.id IS NULL THEN NULL ELSE
                  jsonb_build_object('id', v_snap.id, 'period', v_snap.period,
                                     'taken_at', v_snap.taken_at) END,
    'sections', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'key', s ->> 'key', 'title', s ->> 'title',
               'narrative_mode', s ->> 'narrative',
               'narrative', v_view -> 'narrative' -> (s ->> 'key'),
               'figures', coalesce((
                  SELECT jsonb_agg(jsonb_build_object('key', f,
                           'value', v_snap.snapshot -> f) ORDER BY fo)
                    FROM jsonb_array_elements_text(s -> 'figures') WITH ORDINALITY g(f, fo)),
                  '[]'::jsonb))
             ORDER BY ord)
        FROM jsonb_array_elements(v_view -> 'structure') WITH ORDINALITY u(s, ord)),
      '[]'::jsonb),
    'signatures', (SELECT coalesce(jsonb_agg(sg || jsonb_build_object('name',
                      (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
                         FROM public.users u WHERE u.id = (sg ->> 'user')::uuid))), '[]'::jsonb)
                     FROM jsonb_array_elements(r.signatures) sg),
    'issued_on', r.issued_on, 'issued_by_name', v_list.issued_by_name,
    'created_at', r.created_at);
END $$;
COMMENT ON FUNCTION public.report_document(uuid) IS
  'W2-08: the composed report body (structure, narrative, snapshot-resolved '
  'figures, signatures, branding, due/late) — the single source both the '
  'builder screen and the W3-03 PDF render.';


-- ---------- 11. grants ----------
REVOKE EXECUTE ON FUNCTION
  public.report_snapshot_keys(),
  public.report_default_figures(text),
  public.report_normalise_structure(jsonb),
  public.report_sections_view(jsonb),
  public.report_write_roles(),
  public.report_for_caller(uuid),
  public.trg_report_content_lock(),
  public.trg_report_transition(),
  public.create_monthly_report(uuid, text, timestamptz),
  public.update_report_draft(uuid, jsonb),
  public.report_inputs_outstanding(uuid),
  public.transition_report(uuid, text, text, text),
  public.create_report_correction(uuid, text),
  public.list_reports(uuid, timestamptz),
  public.report_document(uuid)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.report_snapshot_keys(),
  public.report_default_figures(text),
  public.report_normalise_structure(jsonb),
  public.report_sections_view(jsonb),
  public.create_monthly_report(uuid, text, timestamptz),
  public.update_report_draft(uuid, jsonb),
  public.report_inputs_outstanding(uuid),
  public.transition_report(uuid, text, text, text),
  public.create_report_correction(uuid, text),
  public.list_reports(uuid, timestamptz),
  public.report_document(uuid)
TO authenticated;

COMMIT;
