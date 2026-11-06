-- ============================================================================
-- #87 — REGISTER CLOSURE INTEGRITY + REGISTER RPCs
-- (GitHub #87 · spec SP-SPC-PLT-001 §6.2, §9.3, §9.4, FR-REG-01..04,
--  FR-TPL-04, FR-ACC-02)
-- ============================================================================
--
-- 1. CLOSURE INTEGRITY (§9.4 / FR-REG-02). Until now the closure gates only
--    checked that accepted_evidence_refs was a non-empty array, so
--    close_register_item(item, ARRAY['anything']) closed a finding on a
--    fabricated reference. Now EVERY entry of accepted_evidence_refs must
--    match an evidence_items row that
--      (a) carries that evidence_ref,
--      (b) is accepted: review_stage = 'decided' AND an evidence_reviews row
--          stage='accept' / decision='accepted' exists (the AO decision —
--          'decided' alone also covers kpi outcomes minted by the same
--          ritual, so the ledger row is what proves acceptance),
--      (c) belongs to the register item's programme,
--      (d) is linked to the item directly (register_item_id) or through one
--          of its linked activities (evidence.activity_id ∈ the item's
--          register_item_activities) — the same candidate rule
--          evidence_finalize_acceptance uses to auto-close.
--    Enforced in the closure trigger so every write path is covered:
--      * UPDATE (RPCs, direct column-granted UPDATE of status, service
--        writes): immediate check in trg_register_closure_data whenever a row
--        becomes Closed OR a Closed row's refs change.
--      * INSERT of an already-Closed row (service/migration/fixture path only
--        — the INSERT grant has no accepted_* columns): checked by a DEFERRED
--        constraint trigger at commit, because the evidence that proves the
--        closure can only be inserted after the row it points at.
--    can_close_register_item reports the first bad ref as its reason.
--    register_closure_ref_problem() is the single source of the rule.
--
-- 2. RPCs (all SECURITY DEFINER, tenant/role scope checked in the body):
--      create_register_item, update_register_item, link_register_activity,
--      unlink_register_activity, reopen_register_item, retire_register_item,
--      retire_activity.
--    WRITE set (mirrors update_activity / the table policies):
--      partner_admin, partner_consultant, programme_lead, client_admin.
--
-- DECISIONS (flagged for review):
--   D1 create_register_item takes p_assessment_window instead of a
--      "workstream": register_items has no workstream column (§6.2 Register
--      item = ref, finding, priority, assessment window, lead, planned close
--      week, …). FR-REG-04 says "with the same fields", so the assessment
--      window (which reassessment / audit raised it) is the optional extra.
--      Activities are attached afterwards with link_register_activity.
--   D2 planned_close_week has no upper bound (only > 0): findings raised by a
--      reassessment in the maintenance phase legitimately fall after the
--      implementation weeks. Activities keep their 1..total_weeks rule.
--   D3 update_register_item allowlist: ref, finding, priority,
--      assessment_window, lead, planned_close_week. A key that is present
--      with JSON null clears a nullable field (lead, assessment_window,
--      planned_close_week); ref/finding/priority can never be null/blank.
--      status, accepted_*, reopen_reason, CALC columns and retirement are
--      outside the allowlist — status moves only via the §9.4 rituals (or the
--      pre-existing column grant for open statuses, which the gates police).
--   D4 A Closed finding is accepted history: update_register_item and
--      link/unlink refuse it ("re-open it first"). The link freeze is also a
--      trigger on register_item_activities, so the direct INSERT/DELETE
--      grants cannot bypass it. This is the unlink rule asked for in #87:
--      unlinking an activity from a Closed item could orphan an accepted ref
--      whose evidence was linked through that activity, and linking one could
--      add incomplete work to a Closed finding — both are refused. Service
--      writes (auth.uid() IS NULL — fixtures, migrations) and FK cascades
--      from a deleted activity are exempt. The same trigger also enforces
--      "activity and register item in one programme" on every path (it was
--      previously unchecked).
--   D5 Re-open CLEARS the acceptance record (accepted_on/by/refs) and the
--      previous record is written to audit_log ('register_item.reopened',
--      with the reason). §9.4 makes Closed the consequence of an acceptance;
--      once the AO re-opens, that acceptance no longer stands, and keeping
--      it would let a bare status flip re-close on stale refs. The clearing
--      lives in the closure trigger so the direct-UPDATE re-open path
--      behaves the same as the RPC. reopen_reason stays on the row while it
--      is open and is cleared when it closes again, so each re-open needs a
--      fresh reason (the W0-02 gate could otherwise be satisfied by a stale
--      one). The new status after reopen_register_item is 'In progress'.
--   D6 Retirement (FR-TPL-04) is a soft flag: activities.active and
--      register_items.active (+ retired_at/by/reason), matching the
--      maintenance_task_templates.active precedent. No column grants — only
--      the retire RPCs write it. Retirement is terminal (no un-retire RPC,
--      same as a partner-retired maintenance task); apply_template_version
--      never touches the flag, so a retired row stays retired across
--      template applies (a pristine retired row removed from the template is
--      still deleted by apply, exactly as before).
--      * A Closed finding cannot be retired (it is accepted history).
--      * A retired finding cannot be closed, edited or (re)linked; the
--        evidence auto-close skips it.
--      * Retired activities are ignored by the §9.4 "every linked activity
--        Complete" leg (they are out of scope), and by the rollups below.
--      Rollups that now exclude retired rows: workstream_rag,
--      programme_rag_suggested, monthly_snapshot_figures,
--      sched_take_monthly_snapshot, annual_review_figures (register block),
--      list_programmes. Per-row functions (activity_rag, register_item_rag,
--      register_days_overdue) still answer for a retired row if asked.
--   D7 can_close_register_item becomes SECURITY DEFINER (it now has to read
--      evidence + reviews regardless of the caller's RLS view) with an
--      in-body visibility guard: an item outside allowed_programmes() reads
--      as 'register item not found'. Cross-programme refs are reported as
--      "does not match any evidence in this programme" — the message never
--      confirms that a ref exists in someone else's tenant.
-- ============================================================================

BEGIN;

-- ---------- 1. soft-retire columns (FR-TPL-04) ----------
ALTER TABLE public.activities
  ADD COLUMN active         boolean NOT NULL DEFAULT true,
  ADD COLUMN retired_at     timestamptz,
  ADD COLUMN retired_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN retired_reason text,
  ADD CONSTRAINT activities_retired_chk CHECK (active = (retired_at IS NULL));
ALTER TABLE public.register_items
  ADD COLUMN active         boolean NOT NULL DEFAULT true,
  ADD COLUMN retired_at     timestamptz,
  ADD COLUMN retired_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN retired_reason text,
  ADD CONSTRAINT register_items_retired_chk CHECK (active = (retired_at IS NULL)),
  ADD CONSTRAINT register_items_not_closed_and_retired_chk
      CHECK (active OR status <> 'Closed');
COMMENT ON COLUMN public.activities.active IS
  '#87 FR-TPL-04 soft retire — false = retired (retire_activity only; no grant). '
  'Retired rows drop out of RAG/progress rollups and the §9.4 activity leg.';
COMMENT ON COLUMN public.register_items.active IS
  '#87 FR-TPL-04 soft retire — false = retired (retire_register_item only; no '
  'grant). A Closed finding cannot be retired; a retired one cannot close.';
-- (no GRANTs: the existing column-level UPDATE grants do not include these)


-- ---------- 2. the §9.4 evidence-ref rule (single source) ----------
-- NULL = every ref is valid; otherwise the reason naming the first bad ref.
-- Private helper (no EXECUTE for clients): callers are the definer trigger
-- functions and can_close_register_item (definer, guarded).
CREATE OR REPLACE FUNCTION public.register_closure_ref_problem(
    p_item uuid, p_refs text[])
RETURNS text
-- INVOKER + no client EXECUTE: it only ever runs inside the definer trigger
-- functions / can_close_register_item, i.e. as the owner, after their guards.
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v_prog uuid;
  v_ref  text;
BEGIN
  SELECT programme_id INTO v_prog FROM public.register_items WHERE id = p_item;
  IF v_prog IS NULL THEN RETURN 'register item not found'; END IF;
  IF p_refs IS NULL OR coalesce(array_length(p_refs, 1), 0) = 0 THEN
    RETURN 'no evidence references recorded';
  END IF;
  FOREACH v_ref IN ARRAY p_refs LOOP
    IF v_ref IS NULL OR btrim(v_ref) = '' THEN
      RETURN 'blank evidence reference in the acceptance record';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.evidence_items e
                    WHERE e.programme_id = v_prog AND e.evidence_ref = v_ref) THEN
      RETURN format('evidence ref %s does not match any evidence in this programme', v_ref);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.evidence_items e
                    WHERE e.programme_id = v_prog AND e.evidence_ref = v_ref
                      AND e.review_stage = 'decided'
                      AND EXISTS (SELECT 1 FROM public.evidence_reviews er
                                   WHERE er.evidence_item_id = e.id
                                     AND er.stage = 'accept'
                                     AND er.decision = 'accepted')) THEN
      RETURN format('evidence ref %s is not accepted evidence (no accountable-officer acceptance decision)', v_ref);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.evidence_items e
                    WHERE e.programme_id = v_prog AND e.evidence_ref = v_ref
                      AND e.review_stage = 'decided'
                      AND EXISTS (SELECT 1 FROM public.evidence_reviews er
                                   WHERE er.evidence_item_id = e.id
                                     AND er.stage = 'accept'
                                     AND er.decision = 'accepted')
                      AND (e.register_item_id = p_item
                           OR e.activity_id IN (SELECT ria.activity_id
                                                  FROM public.register_item_activities ria
                                                 WHERE ria.register_item_id = p_item))) THEN
      RETURN format('evidence ref %s is not linked to this finding or its linked activities', v_ref);
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
COMMENT ON FUNCTION public.register_closure_ref_problem(uuid, text[]) IS
  '#87 §9.4: NULL when every acceptance ref matches accepted (decided + AO '
  'accept review) evidence of the same programme linked to the item or one of '
  'its linked activities; otherwise the reason naming the first bad ref. '
  'Private — used by the closure triggers and can_close_register_item.';


-- ---------- 3. can_close_register_item — now names the bad ref ----------
CREATE OR REPLACE FUNCTION public.can_close_register_item(p_item uuid)
RETURNS TABLE(can_close boolean, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v record; v_n int; v_refs text; v_problem text;
BEGIN
  SELECT r.programme_id, r.status, r.active, r.accepted_on, r.accepted_by,
         r.accepted_evidence_refs
    INTO v FROM public.register_items r WHERE r.id = p_item;
  -- in-body visibility guard (definer bypasses RLS) — D7
  IF NOT FOUND
     OR (auth.uid() IS NOT NULL
         AND v.programme_id NOT IN (SELECT public.allowed_programmes())) THEN
    RETURN QUERY SELECT false, 'register item not found'; RETURN;
  END IF;
  IF NOT v.active THEN
    RETURN QUERY SELECT false, 'register item is retired (FR-TPL-04)'; RETURN;
  END IF;

  SELECT count(*), string_agg(a.ref, ', ' ORDER BY a.ref)
    INTO v_n, v_refs
    FROM public.register_item_activities ria
    JOIN public.activities a ON a.id = ria.activity_id
   WHERE ria.register_item_id = p_item
     AND a.active
     AND a.status <> 'Complete';
  IF v_n > 0 THEN
    RETURN QUERY SELECT false,
      format('%s linked activit%s not Complete: %s',
             v_n, CASE WHEN v_n = 1 THEN 'y is' ELSE 'ies are' END, v_refs);
    RETURN;
  END IF;

  IF v.accepted_on IS NULL OR v.accepted_by IS NULL
     OR v.accepted_evidence_refs IS NULL
     OR array_length(v.accepted_evidence_refs, 1) IS NULL THEN
    RETURN QUERY SELECT false,
      'evidence acceptance record incomplete (§9.4: accepted_on/by/refs)';
    RETURN;
  END IF;

  v_problem := public.register_closure_ref_problem(p_item, v.accepted_evidence_refs);
  IF v_problem IS NOT NULL THEN
    RETURN QUERY SELECT false, v_problem; RETURN;
  END IF;

  RETURN QUERY SELECT true, 'ok';
END $$;
COMMENT ON FUNCTION public.can_close_register_item(uuid) IS
  '§9.4 data preconditions for closing a finding: not retired, every active '
  'linked activity Complete, the acceptance record present AND every ref '
  'matching accepted, linked, same-programme evidence (#87 — the reason names '
  'the bad ref). Authz (AO/alternate) is checked by trg_register_closure / '
  'close_register_item. SECURITY DEFINER with an allowed_programmes() guard.';


-- ---------- 4. the enforcement trigger (every write path) ----------
CREATE OR REPLACE FUNCTION public.trg_register_closure_data() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int; v_refs text; v_problem text; v_practice uuid;
BEGIN
  -- (a) re-open: the acceptance no longer stands — clear it, audit it (D5).
  --     The AO + reason gate itself is W0-02's trg_register_closure.
  IF TG_OP = 'UPDATE' AND OLD.status = 'Closed'
     AND NEW.status IS DISTINCT FROM 'Closed' THEN
    SELECT c.practice_id INTO v_practice
      FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
     WHERE p.id = NEW.programme_id;
    INSERT INTO public.audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), v_practice, 'register_item.reopened',
            jsonb_build_object(
              'register_item_id', NEW.id,
              'programme_id', NEW.programme_id,
              'ref', NEW.ref,
              'reason', NEW.reopen_reason,
              'new_status', NEW.status,
              'previous_acceptance', jsonb_build_object(
                  'accepted_on', OLD.accepted_on,
                  'accepted_by', OLD.accepted_by,
                  'accepted_evidence_refs', to_jsonb(OLD.accepted_evidence_refs))));
    NEW.accepted_on            := NULL;
    NEW.accepted_by            := NULL;
    NEW.accepted_evidence_refs := NULL;
    RETURN NEW;
  END IF;

  -- (b) closing, or changing the refs of a Closed row
  IF NEW.status = 'Closed'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'Closed'
          OR NEW.accepted_evidence_refs IS DISTINCT FROM OLD.accepted_evidence_refs) THEN
    IF NOT NEW.active THEN
      RAISE EXCEPTION 'cannot close register item %: it is retired (FR-TPL-04)', NEW.ref;
    END IF;
    IF TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'Closed' THEN
      SELECT count(*), string_agg(a.ref, ', ' ORDER BY a.ref)
        INTO v_n, v_refs
        FROM public.register_item_activities ria
        JOIN public.activities a ON a.id = ria.activity_id
       WHERE ria.register_item_id = NEW.id
         AND a.active
         AND a.status <> 'Complete';
      IF v_n > 0 THEN
        RAISE EXCEPTION
          'cannot close register item: % linked activit% not Complete (%) (§9.4)',
          v_n, CASE WHEN v_n = 1 THEN 'y is' ELSE 'ies are' END, v_refs;
      END IF;
      NEW.reopen_reason := NULL;   -- a later re-open needs a fresh reason (D5)
    END IF;
    IF NEW.accepted_on IS NULL OR NEW.accepted_by IS NULL
       OR NEW.accepted_evidence_refs IS NULL
       OR array_length(NEW.accepted_evidence_refs, 1) IS NULL THEN
      RAISE EXCEPTION
        'cannot close register item: evidence acceptance record incomplete (§9.4)';
    END IF;
    -- INSERT is checked at commit by register_closure_refs_on_insert
    IF TG_OP = 'UPDATE' THEN
      v_problem := public.register_closure_ref_problem(NEW.id, NEW.accepted_evidence_refs);
      IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION 'cannot close register item %: % (§9.4)', NEW.ref, v_problem;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_register_closure_data() IS
  '§9.4 data gate on every write path (#87): closing (or re-referencing a '
  'Closed row) requires every active linked activity Complete, the acceptance '
  'record, and every ref to be accepted, linked, same-programme evidence. '
  'Leaving Closed clears the acceptance record and audits it. Complements '
  'W0-02 trg_register_closure (AO/alternate authz + re-open reason).';
-- trigger register_closure_data_gate (BEFORE INSERT OR UPDATE) already
-- points at this function — CREATE OR REPLACE re-arms it.

CREATE OR REPLACE FUNCTION public.trg_register_closure_refs_deferred() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.register_items; v_problem text;
BEGIN
  SELECT * INTO v FROM public.register_items WHERE id = NEW.id;
  IF NOT FOUND OR v.status IS DISTINCT FROM 'Closed' THEN RETURN NULL; END IF;
  v_problem := public.register_closure_ref_problem(v.id, v.accepted_evidence_refs);
  IF v_problem IS NOT NULL THEN
    RAISE EXCEPTION 'cannot insert Closed register item %: % (§9.4)', v.ref, v_problem;
  END IF;
  RETURN NULL;
END $$;
COMMENT ON FUNCTION public.trg_register_closure_refs_deferred() IS
  '#87 §9.4: commit-time ref check for rows INSERTed already Closed '
  '(service/fixture path) — their proving evidence is inserted after them.';

CREATE CONSTRAINT TRIGGER register_closure_refs_on_insert
AFTER INSERT ON public.register_items
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW WHEN (NEW.status = 'Closed')
EXECUTE FUNCTION public.trg_register_closure_refs_deferred();


-- ---------- 5. register_item_activities guard: same programme + frozen
--               links on Closed findings (D4) ----------
CREATE OR REPLACE FUNCTION public.trg_register_link_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item record; v_act_prog uuid;
BEGIN
  IF TG_OP IN ('INSERT','UPDATE') THEN
    SELECT r.id, r.programme_id, r.status, r.ref INTO v_item
      FROM public.register_items r WHERE r.id = NEW.register_item_id;
    SELECT a.programme_id INTO v_act_prog
      FROM public.activities a WHERE a.id = NEW.activity_id;
    IF v_item.id IS NOT NULL AND v_act_prog IS DISTINCT FROM v_item.programme_id THEN
      RAISE EXCEPTION 'register item and activity must belong to the same programme';
    END IF;
    IF auth.uid() IS NOT NULL AND v_item.status = 'Closed' THEN
      RAISE EXCEPTION 'activity links of Closed finding % are frozen — re-open it first (§9.4)',
        v_item.ref;
    END IF;
  END IF;
  IF TG_OP IN ('DELETE','UPDATE') THEN
    SELECT r.id, r.programme_id, r.status, r.ref INTO v_item
      FROM public.register_items r WHERE r.id = OLD.register_item_id;
    IF auth.uid() IS NOT NULL AND v_item.status = 'Closed'
       -- FK cascade from a deleted activity: the parent is already gone
       AND EXISTS (SELECT 1 FROM public.activities a WHERE a.id = OLD.activity_id) THEN
      RAISE EXCEPTION 'activity links of Closed finding % are frozen — re-open it first (§9.4)',
        v_item.ref;
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
COMMENT ON FUNCTION public.trg_register_link_guard() IS
  '#87 D4: register↔activity links stay inside one programme (every path) '
  'and are frozen while the finding is Closed (JWT paths; FK cascades and '
  'service writes exempt) — unlinking could orphan an accepted ref.';

CREATE TRIGGER register_link_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.register_item_activities
FOR EACH ROW EXECUTE FUNCTION public.trg_register_link_guard();


-- ---------- 6. evidence auto-close skips retired findings / activities ----------
-- Body identical to 20261106000002 except: retired items are never closable,
-- and retired activities are out of the "all linked Complete" leg.
CREATE OR REPLACE FUNCTION public.evidence_finalize_acceptance(p_evidence_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_ev      public.evidence_items%ROWTYPE;
    v_client  uuid;
    v_outcome text;
    v_ref     text;
    v_reg     record;
    v_closable uuid[] := '{}';
    v_any_reg boolean := false;
    v_rid     uuid;
BEGIN
    SELECT * INTO v_ev FROM public.evidence_items WHERE id = p_evidence_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'evidence item not found'; END IF;

    FOR v_reg IN
        SELECT ri.id, ri.status, ri.active FROM public.register_items ri
         WHERE ri.id = v_ev.register_item_id
        UNION
        SELECT ri.id, ri.status, ri.active FROM public.register_items ri
         JOIN public.register_item_activities ria
           ON ria.register_item_id = ri.id
        WHERE ria.activity_id = v_ev.activity_id
    LOOP
        v_any_reg := true;
        IF v_reg.status <> 'Closed'
           AND v_reg.active
           AND NOT EXISTS (
               SELECT 1
                 FROM public.register_item_activities ria2
                 JOIN public.activities a ON a.id = ria2.activity_id
                WHERE ria2.register_item_id = v_reg.id
                  AND a.active
                  AND a.status <> 'Complete') THEN
            v_closable := v_closable || v_reg.id;
        END IF;
    END LOOP;

    v_outcome := CASE WHEN coalesce(array_length(v_closable, 1), 0) > 0
                      THEN 'closes_finding'
                      WHEN v_any_reg THEN 'partly_supports'
                      ELSE 'kpi_evidence' END;
    v_ref := public.evidence_next_ref(v_ev.programme_id, v_ev.register_item_id,
                                      v_outcome);

    UPDATE public.evidence_items
       SET review_stage = 'decided', outcome = v_outcome, evidence_ref = v_ref
     WHERE id = p_evidence_id;

    SELECT client_org_id INTO v_client
      FROM public.programmes WHERE id = v_ev.programme_id;

    FOREACH v_rid IN ARRAY v_closable LOOP
        UPDATE public.register_items
           SET status = 'Closed',
               accepted_on = now(),
               accepted_by = auth.uid(),
               accepted_evidence_refs =
                   coalesce(accepted_evidence_refs, '{}'::text[]) || v_ref
         WHERE id = v_rid;
        PERFORM public.evidence_notify('register_item_closed',
            jsonb_build_object('programme_id', v_ev.programme_id,
                               'client_org_id', v_client),
            jsonb_build_object('register_item_id', v_rid,
                               'evidence_id', p_evidence_id,
                               'evidence_ref', v_ref,
                               'accepted_by', auth.uid()));
    END LOOP;

    RETURN jsonb_build_object('evidence_id', p_evidence_id,
                            'evidence_ref', v_ref,
                            'outcome', v_outcome,
                            'closed_register_items', to_jsonb(v_closable));
END $$;


-- ---------- 7. rollups exclude retired rows (D6) ----------
CREATE OR REPLACE FUNCTION public.workstream_rag(p_workstream uuid, p_now timestamptz DEFAULT now())
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE WHEN w.rag_override IS NOT NULL THEN w.rag_override
         ELSE coalesce((SELECT it.rag
                          FROM public.activities a,
                               LATERAL (SELECT public.activity_rag(a.id, p_now) rag) it
                         WHERE a.workstream_id = w.id
                           AND a.active
                           AND a.status NOT IN ('Not started','Complete')
                         ORDER BY public.rag_rank(it.rag) DESC NULLS LAST
                         LIMIT 1), 'Green')
         END
    FROM public.workstreams w
   WHERE w.id = p_workstream
$$;

CREATE OR REPLACE FUNCTION public.programme_rag_suggested(
    p_programme uuid, p_now timestamptz DEFAULT now())
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT coalesce((SELECT it.rag FROM (
                       SELECT public.workstream_rag(w.id, p_now) rag
                         FROM public.workstreams w WHERE w.programme_id = p_programme
                       UNION ALL
                       SELECT public.activity_rag(a.id, p_now)
                         FROM public.activities a
                        WHERE a.programme_id = p_programme
                          AND a.workstream_id IS NULL
                          AND a.active
                          AND a.status NOT IN ('Not started','Complete')
                   ) it
                   ORDER BY public.rag_rank(it.rag) DESC NULLS LAST
                   LIMIT 1), 'Green')
$$;

CREATE OR REPLACE FUNCTION public.monthly_snapshot_figures(
    p_programme uuid, p_month date, p_now timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  WITH m AS (
    SELECT date_trunc('month', p_month)::date first,
           (date_trunc('month', p_month) + interval '1 month - 1 day')::date last
  ),
  kp AS (
    SELECT coalesce(jsonb_object_agg(k.name, ka.value), '{}'::jsonb) v
      FROM public.kpis k
      LEFT JOIN public.kpi_actuals ka ON ka.kpi_id = k.id
                                       AND ka.month = (SELECT first FROM m)
     WHERE k.programme_id = p_programme
  )
  SELECT jsonb_build_object(
    'activities_complete',
      (SELECT count(*) FROM public.activities a
        WHERE a.programme_id = p_programme AND a.active AND a.status = 'Complete'),
    'activities_overdue',
      (SELECT count(*) FROM public.activities a
        WHERE a.programme_id = p_programme AND a.active AND a.status <> 'Complete'
          AND CASE WHEN a.status = 'Deferred' AND a.rescheduled_date IS NOT NULL
                   THEN a.rescheduled_date
                   ELSE (SELECT p.start_date FROM public.programmes p
                          WHERE p.id = p_programme)
                        + (a.end_week - 1) * 7 + 4
              END < p_now::date),
    'register_closed',
      (SELECT count(*) FROM public.register_items r
        WHERE r.programme_id = p_programme AND r.active AND r.status = 'Closed'),
    'register_open',
      (SELECT count(*) FROM public.register_items r
        WHERE r.programme_id = p_programme AND r.active AND r.status <> 'Closed'),
    'high_priority_closed',
      (SELECT count(*) FROM public.register_items r
        WHERE r.programme_id = p_programme AND r.active AND r.status = 'Closed'
          AND r.priority = 'High'),
    'evidence_pending',
      (SELECT count(*) FROM public.evidence_items e
        WHERE e.programme_id = p_programme AND e.review_stage <> 'decided'),
    'rag', public.programme_rag(p_programme, p_now),
    'kpi_actuals', (SELECT v FROM kp),
    'maintenance_done',
      (SELECT count(*) FROM public.maintenance_task_instances mti
        JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
        WHERE t.programme_id = p_programme
          AND mti.period = to_char((SELECT first FROM m), 'YYYY-MM')
          AND mti.status = 'Complete'),
    'maintenance_overdue',
      (SELECT count(*) FROM public.maintenance_task_instances mti
        JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
        WHERE t.programme_id = p_programme
          AND mti.period = to_char((SELECT first FROM m), 'YYYY-MM')
          AND mti.status <> 'Complete'
          AND mti.due_date IS NOT NULL AND mti.due_date < p_now::date))
$$;

CREATE OR REPLACE FUNCTION public.sched_take_monthly_snapshot(
    p_programme uuid, p_period text, p_as_of date)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_month date := (p_period || '-01')::date;
BEGIN
  INSERT INTO public.monthly_snapshots (programme_id, period, snapshot)
  SELECT p.id, p_period,
    jsonb_build_object(
      'activities_complete',
        (SELECT count(*) FROM public.activities a
          WHERE a.programme_id = p.id AND a.active AND a.status = 'Complete'),
      'activities_overdue',
        (SELECT count(*) FROM public.activities a
          WHERE a.programme_id = p.id AND a.active AND a.due_date < p_as_of
            AND a.status NOT IN ('Complete','Deferred')),
      'register_closed',
        (SELECT count(*) FROM public.register_items r
          WHERE r.programme_id = p.id AND r.active AND r.status = 'Closed'),
      'register_open',
        (SELECT count(*) FROM public.register_items r
          WHERE r.programme_id = p.id AND r.active AND r.status <> 'Closed'),
      'high_priority_closed',
        (SELECT count(*) FROM public.register_items r
          WHERE r.programme_id = p.id AND r.active AND r.status = 'Closed'
            AND r.priority = 'High'),
      'evidence_pending',
        (SELECT count(*) FROM public.evidence_items e
          WHERE e.programme_id = p.id AND e.review_stage <> 'decided'),
      'rag', p.programme_rag,
      'kpi_actuals',
        coalesce((SELECT jsonb_object_agg(k.name, ka.value)
                    FROM public.kpis k
                    JOIN public.kpi_actuals ka
                      ON ka.kpi_id = k.id AND ka.month = v_month
                   WHERE k.programme_id = p.id), '{}'::jsonb),
      'maintenance_done',
        (SELECT count(*) FROM public.maintenance_task_instances m
                    JOIN public.maintenance_task_templates t ON t.id = m.task_template_id
          WHERE t.programme_id = p.id AND m.period = p_period
            AND m.status = 'Complete'),
      'maintenance_overdue',
        (SELECT count(*) FROM public.maintenance_task_instances m
                    JOIN public.maintenance_task_templates t ON t.id = m.task_template_id
          WHERE t.programme_id = p.id AND m.period = p_period
            AND m.status <> 'Complete' AND m.due_date < p_as_of))
    FROM public.programmes p
   WHERE p.id = p_programme
  ON CONFLICT (programme_id, period) DO NOTHING;
  RETURN FOUND;
END $$;

CREATE OR REPLACE FUNCTION public.annual_review_figures(
    p_programme uuid, p_year text, p_now timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  WITH yr AS (
    SELECT (p_year || '-01-01')::date AS first,
           (p_year || '-12-31')::date AS last
  ), prog AS (
    SELECT p.id, p.client_org_id FROM public.programmes p WHERE p.id = p_programme
  )
  SELECT jsonb_build_object(
    'year', p_year,
    'generated_at', p_now,
    'register', jsonb_build_object(
      'total', (SELECT count(*) FROM public.register_items r
                 WHERE r.programme_id = p_programme AND r.active),
      'closed', (SELECT count(*) FROM public.register_items r
                  WHERE r.programme_id = p_programme AND r.active AND r.status = 'Closed'),
      'closed_pct', (SELECT CASE WHEN count(*) = 0 THEN NULL
                            ELSE round(100.0 * count(*) FILTER (WHERE r.status = 'Closed') / count(*), 1) END
                       FROM public.register_items r
                      WHERE r.programme_id = p_programme AND r.active),
      'closed_in_year', (SELECT count(*) FROM public.register_items r, yr
                          WHERE r.programme_id = p_programme AND r.active
                            AND r.status = 'Closed'
                            AND r.accepted_on::date BETWEEN yr.first AND yr.last)),
    'evidence', jsonb_build_object(
      'uploaded_in_year', (SELECT count(*) FROM public.evidence_items e, yr
                            WHERE e.programme_id = p_programme
                              AND e.uploaded_at::date BETWEEN yr.first AND yr.last),
      'decided', (SELECT count(*) FROM public.evidence_items e
                   WHERE e.programme_id = p_programme AND e.review_stage = 'decided'),
      'pending', (SELECT count(*) FROM public.evidence_items e
                   WHERE e.programme_id = p_programme AND e.review_stage <> 'decided')),
    'training', jsonb_build_object(
      'records_in_year', (SELECT count(*) FROM public.training_records tr, yr, prog
                           WHERE tr.client_org_id = prog.client_org_id
                             AND tr.date BETWEEN yr.first AND yr.last),
      'attended_in_year', (SELECT count(*) FROM public.training_records tr, yr, prog
                            WHERE tr.client_org_id = prog.client_org_id
                              AND tr.attendance AND tr.date BETWEEN yr.first AND yr.last)),
    'operational', jsonb_build_object(
      'breaches_in_year', (SELECT count(*) FROM public.operational_records o, yr, prog
                            WHERE o.client_org_id = prog.client_org_id AND o.type = 'breach'
                              AND o.reported_at::date BETWEEN yr.first AND yr.last),
      'dsrs_in_year', (SELECT count(*) FROM public.operational_records o, yr, prog
                        WHERE o.client_org_id = prog.client_org_id AND o.type = 'dsr'
                          AND o.reported_at::date BETWEEN yr.first AND yr.last),
      'disclosures_in_year', (SELECT count(*) FROM public.operational_records o, yr, prog
                               WHERE o.client_org_id = prog.client_org_id AND o.type = 'disclosure'
                                 AND o.reported_at::date BETWEEN yr.first AND yr.last),
      'optouts_in_year', (SELECT count(*) FROM public.operational_records o, yr, prog
                           WHERE o.client_org_id = prog.client_org_id AND o.type = 'optout'
                             AND o.reported_at::date BETWEEN yr.first AND yr.last)),
    'maintenance', jsonb_build_object(
      'instances', (SELECT count(*) FROM public.maintenance_task_instances mti
                      JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
                     WHERE t.programme_id = p_programme
                       AND mti.period LIKE p_year || '-%'),
      'complete', (SELECT count(*) FROM public.maintenance_task_instances mti
                     JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
                    WHERE t.programme_id = p_programme AND mti.status = 'Complete'
                      AND mti.period LIKE p_year || '-%'),
      'exceptions', (SELECT count(*) FROM public.maintenance_task_instances mti
                      JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
                     WHERE t.programme_id = p_programme AND mti.status = 'Exception'
                       AND mti.period LIKE p_year || '-%')),
    'months', (SELECT coalesce(jsonb_object_agg(s.period,
                     jsonb_build_object('rag', s.snapshot->>'rag',
                                        'maintenance_done', s.snapshot->'maintenance_done',
                                        'maintenance_overdue', s.snapshot->'maintenance_overdue',
                                        'register_closed', s.snapshot->'register_closed',
                                        'activities_overdue', s.snapshot->'activities_overdue')
                     ORDER BY s.period), '{}'::jsonb)
                 FROM public.monthly_snapshots s
                WHERE s.programme_id = p_programme
                  AND s.period LIKE p_year || '-%'))
$$;

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
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id
            AND a.active),
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id
            AND a.active AND a.status = 'Complete'),
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id
            AND a.active AND a.status <> 'Complete' AND a.due_date IS NOT NULL
            AND a.due_date < CURRENT_DATE),
         (SELECT count(*) FROM public.register_items r WHERE r.programme_id = p.id
            AND r.active AND r.status <> 'Closed'),
         (SELECT count(*) FROM public.register_items r WHERE r.programme_id = p.id
            AND r.active AND r.status = 'Closed'),
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


-- ============================================================================
-- 8. RPCs
-- ============================================================================

-- shared lookup for the register RPCs: item + programme + client + practice.
-- Private (INVOKER, no client EXECUTE — runs as the owner inside the definer
-- RPCs); every RPC still runs its own role check on the returned row.
CREATE OR REPLACE FUNCTION public.register_item_ctx(p_item_id uuid)
RETURNS TABLE(item public.register_items, client_org_id uuid, practice_id uuid,
              programme_status text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT r, p.client_org_id, c.practice_id, p.status
    FROM public.register_items r
    JOIN public.programmes p  ON p.id = r.programme_id
    JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE r.id = p_item_id
$$;

-- ---- create_register_item — FR-REG-04 (D1, D2) ----
CREATE OR REPLACE FUNCTION public.create_register_item(
    p_programme_id       uuid,
    p_ref                text,
    p_finding            text,
    p_priority           text DEFAULT 'Medium',
    p_lead               uuid DEFAULT NULL,
    p_planned_close_week int  DEFAULT NULL,
    p_assessment_window  text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog     public.programmes;
  v_practice uuid;
  v_id       uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  -- lock: concurrent creates in one programme serialise on the ref check
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme % not found', p_programme_id; END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'adding a finding requires a programme write role (FR-REG-04)';
  END IF;
  IF v_prog.status = 'closed' THEN
    RAISE EXCEPTION 'findings cannot be added to a closed programme';
  END IF;
  IF p_ref IS NULL OR btrim(p_ref) = '' OR p_finding IS NULL OR btrim(p_finding) = '' THEN
    RAISE EXCEPTION 'finding ref and text are required';
  END IF;
  IF coalesce(p_priority, 'Medium') NOT IN ('High','Medium','Low') THEN
    RAISE EXCEPTION 'priority must be High, Medium or Low';
  END IF;
  IF p_planned_close_week IS NOT NULL AND p_planned_close_week < 1 THEN
    RAISE EXCEPTION 'planned_close_week must be >= 1';
  END IF;
  IF p_lead IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = p_lead) THEN
    RAISE EXCEPTION 'lead % is not a known user', p_lead;
  END IF;
  IF EXISTS (SELECT 1 FROM public.register_items r
              WHERE r.programme_id = p_programme_id AND r.ref = btrim(p_ref)) THEN
    RAISE EXCEPTION 'finding ref "%" already exists in this programme', btrim(p_ref);
  END IF;

  INSERT INTO public.register_items
      (programme_id, ref, finding, priority, assessment_window, lead, planned_close_week)
  VALUES (p_programme_id, btrim(p_ref), p_finding, coalesce(p_priority, 'Medium'),
          NULLIF(btrim(p_assessment_window), ''), p_lead, p_planned_close_week)
  RETURNING id INTO v_id;

  PERFORM public.recompute_programme_progress(p_programme_id);   -- planned_close_date CALC

  SELECT c.practice_id INTO v_practice FROM public.client_orgs c WHERE c.id = v_prog.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'register_item.created',
          jsonb_build_object('register_item_id', v_id, 'programme_id', p_programme_id,
                             'ref', btrim(p_ref), 'priority', coalesce(p_priority, 'Medium'),
                             'assessment_window', p_assessment_window));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.create_register_item(uuid, text, text, text, uuid, int, text) IS
  '#87 FR-REG-04: add a finding (reassessment / internal audit) with the §6.2 '
  'fields. WRITE roles; ref unique within the programme; not into a closed '
  'programme; planned_close_date computed by the engine; audited.';

-- ---- update_register_item — allowlisted edit (D3, D4) ----
CREATE OR REPLACE FUNCTION public.update_register_item(p_item_id uuid, p_payload jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ctx      record;
  v_item     public.register_items;
  v_allowed  text[] := ARRAY['ref','finding','priority','assessment_window',
                             'lead','planned_close_week'];
  v_key      text;
  v_ref      text;
  v_lead     uuid;
  v_week     int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_ctx FROM public.register_item_ctx(p_item_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'register item % not found', p_item_id;
  END IF;
  v_item := v_ctx.item;
  IF NOT public.has_programme_role(v_item.programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'editing a finding requires a programme write role (FR-TPL-04)';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'payload must be a jsonb object of editable fields';
  END IF;
  FOR v_key IN SELECT k FROM jsonb_object_keys(p_payload) k LOOP
    IF NOT (v_key = ANY(v_allowed)) THEN
      RAISE EXCEPTION 'update_register_item: field "%" is not editable', v_key;
    END IF;
  END LOOP;
  IF v_ctx.programme_status = 'closed' THEN
    RAISE EXCEPTION 'findings of a closed programme cannot be edited';
  END IF;
  IF NOT v_item.active THEN
    RAISE EXCEPTION 'register item % is retired (FR-TPL-04)', v_item.ref;
  END IF;
  IF v_item.status = 'Closed' THEN
    RAISE EXCEPTION 'register item % is Closed — re-open it before editing (§9.4)', v_item.ref;
  END IF;

  -- required fields: present ⇒ non-null, non-blank
  IF p_payload ? 'ref' THEN
    v_ref := btrim(p_payload->>'ref');
    IF v_ref IS NULL OR v_ref = '' THEN RAISE EXCEPTION 'finding ref cannot be blank'; END IF;
    IF v_ref IS DISTINCT FROM v_item.ref
       AND EXISTS (SELECT 1 FROM public.register_items r
                    WHERE r.programme_id = v_item.programme_id
                      AND r.ref = v_ref AND r.id <> v_item.id) THEN
      RAISE EXCEPTION 'finding ref "%" already exists in this programme', v_ref;
    END IF;
  END IF;
  IF p_payload ? 'finding'
     AND (p_payload->>'finding' IS NULL OR btrim(p_payload->>'finding') = '') THEN
    RAISE EXCEPTION 'finding text cannot be blank';
  END IF;
  IF p_payload ? 'priority'
     AND coalesce(p_payload->>'priority', '') NOT IN ('High','Medium','Low') THEN
    RAISE EXCEPTION 'priority must be High, Medium or Low';
  END IF;
  -- nullable fields: present-with-null clears
  IF p_payload ? 'lead' AND p_payload->>'lead' IS NOT NULL THEN
    v_lead := (p_payload->>'lead')::uuid;
    IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = v_lead) THEN
      RAISE EXCEPTION 'lead % is not a known user', v_lead;
    END IF;
  END IF;
  IF p_payload ? 'planned_close_week' AND p_payload->>'planned_close_week' IS NOT NULL THEN
    v_week := (p_payload->>'planned_close_week')::int;
    IF v_week < 1 THEN RAISE EXCEPTION 'planned_close_week must be >= 1'; END IF;
  END IF;

  UPDATE public.register_items SET
      ref      = CASE WHEN p_payload ? 'ref' THEN v_ref ELSE ref END,
      finding  = CASE WHEN p_payload ? 'finding' THEN p_payload->>'finding' ELSE finding END,
      priority = CASE WHEN p_payload ? 'priority' THEN p_payload->>'priority' ELSE priority END,
      assessment_window = CASE WHEN p_payload ? 'assessment_window'
                               THEN NULLIF(btrim(p_payload->>'assessment_window'), '')
                               ELSE assessment_window END,
      lead     = CASE WHEN p_payload ? 'lead' THEN v_lead ELSE lead END,
      planned_close_week = CASE WHEN p_payload ? 'planned_close_week' THEN v_week
                                ELSE planned_close_week END
   WHERE id = p_item_id;

  IF p_payload ? 'planned_close_week' THEN
    PERFORM public.recompute_programme_progress(v_item.programme_id);
  END IF;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_ctx.practice_id, 'register_item.updated',
          jsonb_build_object('register_item_id', p_item_id,
                             'programme_id', v_item.programme_id,
                             'fields', (SELECT jsonb_agg(k) FROM jsonb_object_keys(p_payload) k),
                             'before', jsonb_build_object(
                                 'ref', v_item.ref, 'finding', v_item.finding,
                                 'priority', v_item.priority,
                                 'assessment_window', v_item.assessment_window,
                                 'lead', v_item.lead,
                                 'planned_close_week', v_item.planned_close_week)));
  RETURN p_item_id;
END $$;
COMMENT ON FUNCTION public.update_register_item(uuid, jsonb) IS
  '#87 FR-TPL-04: edit a finding through an allowlist (ref, finding, priority, '
  'assessment_window, lead, planned_close_week). Never status, the acceptance '
  'record, reopen_reason, retirement or CALC columns. Closed/retired items '
  'and closed programmes refused. Present-with-null clears nullable fields.';

-- ---- link / unlink (D4) ----
CREATE OR REPLACE FUNCTION public.link_register_activity(p_item_id uuid, p_activity_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ctx record; v_item public.register_items; v_act public.activities; v_n int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_ctx FROM public.register_item_ctx(p_item_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'register item % not found', p_item_id;
  END IF;
  v_item := v_ctx.item;
  IF NOT public.has_programme_role(v_item.programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'linking activities requires a programme write role (FR-REG-01)';
  END IF;
  SELECT * INTO v_act FROM public.activities a WHERE a.id = p_activity_id;
  IF v_act IS NULL OR v_act.programme_id IS DISTINCT FROM v_item.programme_id THEN
    RAISE EXCEPTION 'activity % is not part of this programme', p_activity_id;
  END IF;
  IF v_ctx.programme_status = 'closed' THEN
    RAISE EXCEPTION 'links of a closed programme cannot change';
  END IF;
  IF NOT v_item.active THEN
    RAISE EXCEPTION 'register item % is retired (FR-TPL-04)', v_item.ref;
  END IF;
  IF NOT v_act.active THEN
    RAISE EXCEPTION 'activity % is retired (FR-TPL-04)', v_act.ref;
  END IF;
  IF v_item.status = 'Closed' THEN
    RAISE EXCEPTION 'activity links of Closed finding % are frozen — re-open it first (§9.4)',
      v_item.ref;
  END IF;

  INSERT INTO public.register_item_activities (register_item_id, activity_id)
  VALUES (p_item_id, p_activity_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n > 0 THEN
    INSERT INTO public.audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), v_ctx.practice_id, 'register_item.activity_linked',
            jsonb_build_object('register_item_id', p_item_id, 'activity_id', p_activity_id,
                               'programme_id', v_item.programme_id,
                               'ref', v_item.ref, 'activity_ref', v_act.ref));
  END IF;
  RETURN v_n > 0;
END $$;
COMMENT ON FUNCTION public.link_register_activity(uuid, uuid) IS
  '#87 FR-REG-01: link an activity to a finding (same programme, WRITE roles). '
  'Idempotent (false = already linked). Refused for Closed or retired '
  'findings and retired activities.';

CREATE OR REPLACE FUNCTION public.unlink_register_activity(p_item_id uuid, p_activity_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ctx record; v_item public.register_items; v_n int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_ctx FROM public.register_item_ctx(p_item_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'register item % not found', p_item_id;
  END IF;
  v_item := v_ctx.item;
  IF NOT public.has_programme_role(v_item.programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'unlinking activities requires a programme write role (FR-REG-01)';
  END IF;
  IF v_ctx.programme_status = 'closed' THEN
    RAISE EXCEPTION 'links of a closed programme cannot change';
  END IF;
  IF NOT v_item.active THEN
    RAISE EXCEPTION 'register item % is retired (FR-TPL-04)', v_item.ref;
  END IF;
  IF v_item.status = 'Closed' THEN
    RAISE EXCEPTION 'activity links of Closed finding % are frozen — re-open it first (§9.4)',
      v_item.ref;
  END IF;

  DELETE FROM public.register_item_activities
   WHERE register_item_id = p_item_id AND activity_id = p_activity_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n > 0 THEN
    INSERT INTO public.audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), v_ctx.practice_id, 'register_item.activity_unlinked',
            jsonb_build_object('register_item_id', p_item_id, 'activity_id', p_activity_id,
                               'programme_id', v_item.programme_id, 'ref', v_item.ref));
  END IF;
  RETURN v_n > 0;
END $$;
COMMENT ON FUNCTION public.unlink_register_activity(uuid, uuid) IS
  '#87 FR-REG-01: unlink an activity from a finding (WRITE roles). Refused '
  'while the finding is Closed (re-open first) — an unlink could orphan an '
  'accepted ref whose evidence was linked through that activity (D4).';

-- ---- reopen_register_item — §9.4 / FR-ACC-02 (D5) ----
CREATE OR REPLACE FUNCTION public.reopen_register_item(p_item_id uuid, p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ctx record; v_item public.register_items;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_ctx FROM public.register_item_ctx(p_item_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'register item % not found', p_item_id;
  END IF;
  v_item := v_ctx.item;
  IF NOT public.is_ao_or_alternate(v_ctx.client_org_id) THEN
    RAISE EXCEPTION
      'only the accountable officer or named alternate may re-open a register item (§9.4, FR-ACC-02)';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 're-opening a closed finding requires a reason (§9.4)';
  END IF;
  IF v_item.status <> 'Closed' THEN
    RAISE EXCEPTION 'register item % is not Closed (status %)', v_item.ref, v_item.status;
  END IF;
  IF v_ctx.programme_status = 'closed' THEN
    RAISE EXCEPTION 'findings of a closed programme cannot be re-opened';
  END IF;

  -- trg_register_closure (AO + reason) and trg_register_closure_data (clear
  -- the acceptance record + audit_log 'register_item.reopened') fire here.
  UPDATE public.register_items
     SET status = 'In progress', reopen_reason = btrim(p_reason)
   WHERE id = p_item_id;
  -- days_overdue (CALC) is refreshed by the next recompute / daily sweep —
  -- the AO holds no write role, and recompute_programme_progress demands one
  -- (same as close_register_item).
  RETURN p_item_id;
END $$;
COMMENT ON FUNCTION public.reopen_register_item(uuid, text) IS
  '#87 §9.4: AO / named alternate re-opens a Closed finding with a mandatory '
  'reason → In progress. The acceptance record is cleared and the previous '
  'record + reason are written to audit_log by the closure trigger (D5).';

-- ---- retire (FR-TPL-04, D6) ----
CREATE OR REPLACE FUNCTION public.retire_register_item(p_item_id uuid, p_reason text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ctx record; v_item public.register_items;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_ctx FROM public.register_item_ctx(p_item_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'register item % not found', p_item_id;
  END IF;
  v_item := v_ctx.item;
  IF NOT public.has_programme_role(v_item.programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'retiring a finding requires a programme write role (FR-TPL-04)';
  END IF;
  IF v_ctx.programme_status = 'closed' THEN
    RAISE EXCEPTION 'findings of a closed programme cannot be retired';
  END IF;
  IF NOT v_item.active THEN
    RAISE EXCEPTION 'register item % is already retired', v_item.ref;
  END IF;
  IF v_item.status = 'Closed' THEN
    RAISE EXCEPTION 'register item % is Closed — accepted findings are not retired', v_item.ref;
  END IF;

  UPDATE public.register_items
     SET active = false, retired_at = now(), retired_by = auth.uid(),
         retired_reason = NULLIF(btrim(p_reason), '')
   WHERE id = p_item_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_ctx.practice_id, 'register_item.retired',
          jsonb_build_object('register_item_id', p_item_id,
                             'programme_id', v_item.programme_id,
                             'ref', v_item.ref, 'status', v_item.status,
                             'reason', p_reason));
  RETURN p_item_id;
END $$;
COMMENT ON FUNCTION public.retire_register_item(uuid, text) IS
  '#87 FR-TPL-04: soft-retire a finding (active=false) — WRITE roles, not a '
  'Closed one, terminal. Retired findings drop out of rollups and cannot be '
  'closed, edited or linked.';

CREATE OR REPLACE FUNCTION public.retire_activity(p_activity_id uuid, p_reason text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_act public.activities; v_pstatus text; v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_act FROM public.activities a WHERE a.id = p_activity_id;
  IF v_act IS NULL THEN RAISE EXCEPTION 'activity % not found', p_activity_id; END IF;
  IF NOT public.has_programme_role(v_act.programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'retiring an activity requires a programme write role (FR-TPL-04)';
  END IF;
  SELECT p.status, c.practice_id INTO v_pstatus, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_act.programme_id;
  IF v_pstatus = 'closed' THEN
    RAISE EXCEPTION 'activities of a closed programme cannot be retired';
  END IF;
  IF NOT v_act.active THEN
    RAISE EXCEPTION 'activity % is already retired', v_act.ref;
  END IF;

  UPDATE public.activities
     SET active = false, retired_at = now(), retired_by = auth.uid(),
         retired_reason = NULLIF(btrim(p_reason), '')
   WHERE id = p_activity_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'activity.retired',
          jsonb_build_object('activity_id', p_activity_id,
                             'programme_id', v_act.programme_id,
                             'ref', v_act.ref, 'status', v_act.status,
                             'reason', p_reason));
  RETURN p_activity_id;
END $$;
COMMENT ON FUNCTION public.retire_activity(uuid, text) IS
  '#87 FR-TPL-04: soft-retire an activity (active=false) — WRITE roles, '
  'terminal. Retired activities drop out of RAG/progress rollups and the '
  '§9.4 "every linked activity Complete" leg; links and history are kept.';


-- ---------- 9. execution surface ----------
REVOKE EXECUTE ON FUNCTION
  public.register_closure_ref_problem(uuid, text[]),
  public.trg_register_closure_refs_deferred(),
  public.trg_register_link_guard(),
  public.register_item_ctx(uuid),
  public.create_register_item(uuid, text, text, text, uuid, int, text),
  public.update_register_item(uuid, jsonb),
  public.link_register_activity(uuid, uuid),
  public.unlink_register_activity(uuid, uuid),
  public.reopen_register_item(uuid, text),
  public.retire_register_item(uuid, text),
  public.retire_activity(uuid, text)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.create_register_item(uuid, text, text, text, uuid, int, text),
  public.update_register_item(uuid, jsonb),
  public.link_register_activity(uuid, uuid),
  public.unlink_register_activity(uuid, uuid),
  public.reopen_register_item(uuid, text),
  public.retire_register_item(uuid, text),
  public.retire_activity(uuid, text)
TO authenticated;
-- can_close_register_item / evidence_finalize_acceptance / the rollups keep
-- their existing grants (CREATE OR REPLACE preserves ACLs).

COMMIT;
