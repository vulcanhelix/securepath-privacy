-- ============================================================================
-- #92 RETIRED ACTIVITIES ARE FROZEN  +  #90 CHECKLIST ITEM COMPLETION RPC
-- (GitHub #90, #92 · follow-ups to #87 / PR #91 and W2-10 / PR #89 ·
--  spec SP-SPC-PLT-001 §6.2, §8.11, §9.4, FR-TPL-04, FR-QTR-01/02, NFR-08)
-- ============================================================================
--
-- Additive only: no earlier migration file is edited. Two existing functions
-- are re-created with CREATE OR REPLACE and their original signatures
-- (register_closure_ref_problem, apply_template_version); both are noted
-- below with the exact delta.
--
-- HARD RULE (unchanged): every SECURITY DEFINER below checks tenant + role
-- scope in its own body, because a definer owned by supabase_admin bypasses
-- RLS.
--
-- ---------------------------------------------------------------------------
-- #92 — 1. A RETIRED ACTIVITY CANNOT BE EDITED, ON ANY PATH
-- ---------------------------------------------------------------------------
-- 20261106000013 (D6) made retirement a terminal soft flag, but the user write
-- paths into activities never looked at it: update_activity,
-- update_activity_status, reorder_activity (a wrapper over update_activity)
-- and the W0-02 column grants (UPDATE of workstream_id, ref, text, leads,
-- weeks, milestone, evidence_required, status, pct_complete,
-- actual_completion, flag, comments, recovery_date,
-- dependency_override_reason, plus rescheduled_date from W1-01) all still
-- edited a retired row.
--
-- The block is a BEFORE UPDATE row trigger, trg_activity_retired_guard, so no
-- path can skip it: the three RPCs and a direct PostgREST UPDATE all end in
-- the same UPDATE statement. It acts only when OLD.active is false (a live
-- row is never affected, and retire_activity's own true→false write passes).
--
-- HOW IT TELLS AN EDIT FROM AN ENGINE RECOMPUTE: the same separation
-- trg_activity_session_guard (20261106000012) uses, i.e. compare OLD and NEW
-- column by column instead of trusting the caller. The engine's recompute
-- writes (recompute_activity_due via recompute_programme_progress, and the
-- scheduler's daily RAG refresh) touch ONLY the CALC columns phase,
-- start_date, due_date, month and rag. The guard rejects the row when any
-- column OTHER than those five differs between OLD and NEW. So a recompute
-- always passes, whatever values it writes, and a retired row still gets its
-- CALC columns refreshed. The comparison is "everything except CALC", so a
-- column added to activities later is frozen by default.
--   * Unlike the session guard, it applies to every caller, including the
--     service path (auth.uid() IS NULL). Retirement is terminal, so there is
--     no legitimate non-CALC write to a retired row.
--   * One exemption: a write issued from inside another trigger
--     (pg_trigger_depth() > 1). That is how Postgres runs the FK actions
--     ON DELETE SET NULL of activities.workstream_id and
--     activities.retired_by; without it, deleting a workstream or a user
--     would fail on a retired activity. No trigger in the schema updates
--     activities otherwise, and a client cannot run code inside a trigger.
--   * A no-op write (every value unchanged) changes nothing and passes. The
--     RPCs then still write their audit_log row; there is nothing to block.
--   * DELETE is not an edit and is not blocked: apply_template_version still
--     removes a pristine retired row that the template dropped (the 000013 D6
--     behaviour), and FK cascades still work.
--
-- apply_template_version (W1-05) is the one existing writer that re-syncs
-- non-CALC columns (text, milestone, evidence_required and, on Not-started
-- rows, workstream/weeks/deps) under the partner's JWT. Unchanged, a template
-- version that edited a retired activity would now fail the whole apply. It
-- is re-created here with ONE delta: an existing activity that is retired is
-- skipped (counted in diff.activities.retained, no column re-sync, no dep
-- rebuild), and the dependency pass for Not-started rows skips retired ones
-- too. Every other line of the body is identical to 20261106000008.
--
-- Known adjacent gap, deliberately out of scope (#92 asks for activities):
-- register_items has the same direct column grants, and the retire block for
-- a retired finding is in the register RPCs only (000013). Also, the
-- FR-SCH-04 predecessor gate in update_activity / update_activity_status still
-- counts a retired, incomplete predecessor. Both are flagged in the PR.
--
-- ---------------------------------------------------------------------------
-- #92 — 2. NO UN-RETIRE RPC (decision)
-- ---------------------------------------------------------------------------
-- None is added, for four reasons:
--   (a) 000013 D6 already defined retirement as terminal, matching the
--       maintenance_task_templates.active precedent (a partner-retired
--       maintenance task is never revived either);
--   (b) retirement removes the row from the RAG/progress rollups, the monthly
--       snapshot figures and the §9.4 "every linked activity Complete" leg.
--       Reviving it would silently rewrite those figures for months that
--       have already been reported and snapshotted (§9.5 snapshots are
--       append-only);
--   (c) a retired row keeps its history (status ledger, evidence, links), so
--       nothing needs restoring. If the work comes back into scope, the
--       auditable route is a NEW activity (add_activity) or register item
--       (create_register_item), with its own history from the day it starts;
--   (d) no FR in SP-SPC-PLT-001 asks for one.
-- With no un-retire path, the guard above makes a retired row permanently
-- read-only for every client.
--
-- ---------------------------------------------------------------------------
-- #90 — 3. complete_checklist_item(checklist_id, item_key, evidence_id?, note?)
-- ---------------------------------------------------------------------------
-- W1-03 generates quarterly/annual checklists (FR-QTR-01/02) whose items are
-- {ref, label, evidence_required, evidence_id, done}. Until now nothing could
-- tick one off except a direct UPDATE of checklist_instances.items.
--
--   * item_key = the item's `ref` (the stable template key generate_checklist
--     copies onto every item). Refs are unique within a checklist in every
--     shipped template; the RPC matches the FIRST item carrying the key.
--   * ROLE GUARD (in the body): JWT callers need can_run_cadence on the
--     checklist's programme. That is the predicate generate_checklist uses:
--     the programme WRITE roles (partner_admin, partner_consultant,
--     programme_lead, client_admin) plus the client's AO / named alternate,
--     which the maintenance RPCs (has_mti_role) also admit. The service path
--     (auth.uid() IS NULL) runs free, the same as every cadence RPC. A
--     checklist outside the caller's allowed_programmes() reads as
--     "checklist not found", so the RPC never confirms another tenant's ids.
--     A checklist of a closed programme cannot be changed.
--   * EVIDENCE RULE (reused, not copied): when an evidence_id is given it
--     must be an evidence_items row of the SAME programme as the checklist
--     AND accepted. "Accepted" is the 000013 rule: review_stage = 'decided'
--     plus a stage='accept' / decision='accepted' row in the append-only
--     evidence_reviews ledger. That leg used to live inline in
--     register_closure_ref_problem; it is now the single predicate
--     public.evidence_item_is_accepted(evidence_id), and
--     register_closure_ref_problem is re-created to call it. Same rule, same
--     messages, same results (the register suite is unchanged). The
--     cross-programme message is the 000013 wording ("does not match any
--     evidence in this programme"), so it never confirms that the id exists
--     in another tenant.
--   * SLOT RULE: an item with evidence_required = true completes ONLY with
--     accepted evidence (FR-QTR-01 "checklist with evidence slots"). Any
--     other item needs accepted evidence OR a non-blank note saying what was
--     done. This mirrors FR-MNT-05 for maintenance tasks, so a checklist
--     can't be ticked off with no record at all.
--   * HISTORY: a new append-only table, checklist_item_completions, one row
--     per completion (checklist, programme, item_key, evidence_id, note,
--     completed_by, completed_at). A table, not a jsonb array on the
--     checklist, because (i) the trg_append_only family can make a table
--     strictly append-only on every path, while a jsonb array on a row users
--     can UPDATE cannot be protected element-wise; (ii) it carries RLS and is
--     queryable for the annual review; (iii) it matches the existing ledgers
--     (activity_status_history, raid_status_history, evidence_reviews).
--     UPDATE is always rejected. DELETE is rejected unless it is the FK
--     cascade of the parent checklist / programme being deleted (the parent
--     is already gone), the same cascade exemption trg_register_link_guard
--     uses. completed_by and evidence_id are plain uuids with no FK, as on
--     audit_log.user_id, so that no ON DELETE SET NULL could ever need to
--     rewrite a ledger row.
--     The checklist row's items jsonb is the current state the screen
--     renders. The RPC sets done = true, evidence_id, completed_at,
--     completed_by and note on the item. The ledger is the record.
--   * RE-COMPLETE / UN-COMPLETE RULE (decision): a completed item is FINAL.
--     Re-completing is rejected ("already complete") and there is no
--     un-complete. Reasons:
--       - FR-QTR-01/02 produce the period's evidence record of a control
--         operating (the annual one also freezes the year's figures), the
--         same nature as a monthly maintenance task, where W1-03 decision 4
--         made 'Complete' terminal;
--       - the attached evidence is already accepted and immutable (NFR-09),
--         and §6.2/NFR-08 want corrections to be new records, not edits;
--       - a terminal rule keeps the ledger one row per item. A UNIQUE
--         (checklist_id, item_key) index enforces that in the database too,
--         so two concurrent callers cannot both complete an item (the RPC
--         also locks the checklist row FOR UPDATE).
--     If a correction is ever needed, it is a new period checklist or a
--     note on the next one. If FR-QTR is later read as needing an un-tick,
--     the change is additive: an "uncomplete" ledger row type plus dropping
--     the unique index.
--   * DIRECT WRITES CLOSED: W0-02 granted authenticated INSERT (programme_id,
--     kind, period, items) and UPDATE (items) on checklist_instances, which
--     would let a client flip done:true with no evidence or history and
--     bypass the RPC. No client code uses those grants: the screen generates
--     through generate_checklist and now completes through this RPC. Both
--     grants are REVOKED here, so the items move only through the two
--     SECURITY DEFINER RPCs. SELECT stays, and the RLS policies are left in
--     place (inert without a grant).
-- ============================================================================

BEGIN;

-- ============================================================================
-- #92 — 1. the retired-activity freeze
-- ============================================================================
CREATE OR REPLACE FUNCTION public.trg_activity_retired_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  -- engine-written CALC columns (§9.1/§9.2) — the only columns a recompute
  -- writes; the same set trg_activity_session_guard treats as calc
  c_calc text[] := ARRAY['phase','start_date','due_date','month','rag'];
BEGIN
  IF OLD.active THEN
    RETURN NEW;                       -- live row (incl. the retire write itself)
  END IF;
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;                       -- FK ON DELETE SET NULL action (see header)
  END IF;
  IF (to_jsonb(NEW) - c_calc) IS DISTINCT FROM (to_jsonb(OLD) - c_calc) THEN
    RAISE EXCEPTION
      'activity % is retired (FR-TPL-04): a retired activity cannot be edited',
      OLD.ref
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  RETURN NEW;                         -- CALC-only recompute write
END $$;
COMMENT ON FUNCTION public.trg_activity_retired_guard() IS
  '#92 FR-TPL-04: a retired activity (active=false) is frozen on every write '
  'path (update_activity, update_activity_status, reorder_activity, direct '
  'column-grant UPDATEs, service writes). Only the engine CALC columns '
  '(phase, start_date, due_date, month, rag) may still change, so recomputes '
  'pass. FK SET NULL actions (pg_trigger_depth() > 1) are exempt.';

DROP TRIGGER IF EXISTS activity_retired_guard ON public.activities;
CREATE TRIGGER activity_retired_guard
BEFORE UPDATE ON public.activities
FOR EACH ROW EXECUTE FUNCTION public.trg_activity_retired_guard();


-- ============================================================================
-- #90 — the accepted-evidence predicate (single source, reused by 000013)
-- ============================================================================
-- Private helper (no client EXECUTE): callers are definer functions, after
-- their own guards. INVOKER so it reads with the definer's rights.
CREATE OR REPLACE FUNCTION public.evidence_item_is_accepted(p_evidence uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.evidence_items e
     WHERE e.id = p_evidence
       AND e.review_stage = 'decided'
       AND EXISTS (SELECT 1 FROM public.evidence_reviews er
                    WHERE er.evidence_item_id = e.id
                      AND er.stage = 'accept'
                      AND er.decision = 'accepted'))
$$;
COMMENT ON FUNCTION public.evidence_item_is_accepted(uuid) IS
  '#87/#90: THE accepted-evidence rule — review_stage = decided AND an AO '
  'accept/accepted row in the append-only evidence_reviews ledger. Used by '
  'register_closure_ref_problem (register closure) and complete_checklist_item. '
  'Private: no client EXECUTE.';

-- Body identical to 20261106000013 except that the "accepted" leg (b) and
-- the accepted part of the linked leg (d) call evidence_item_is_accepted()
-- instead of repeating the predicate inline. Messages and results unchanged.
CREATE OR REPLACE FUNCTION public.register_closure_ref_problem(
    p_item uuid, p_refs text[])
RETURNS text
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
                      AND public.evidence_item_is_accepted(e.id)) THEN
      RETURN format('evidence ref %s is not accepted evidence (no accountable-officer acceptance decision)', v_ref);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.evidence_items e
                    WHERE e.programme_id = v_prog AND e.evidence_ref = v_ref
                      AND public.evidence_item_is_accepted(e.id)
                      AND (e.register_item_id = p_item
                           OR e.activity_id IN (SELECT ria.activity_id
                                                  FROM public.register_item_activities ria
                                                 WHERE ria.register_item_id = p_item))) THEN
      RETURN format('evidence ref %s is not linked to this finding or its linked activities', v_ref);
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
-- (COMMENT from 000013 is preserved by CREATE OR REPLACE)


-- ============================================================================
-- #90 — checklist_item_completions: append-only completion ledger
-- ============================================================================
CREATE TABLE public.checklist_item_completions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    checklist_id uuid NOT NULL REFERENCES public.checklist_instances(id) ON DELETE CASCADE,
    programme_id uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    item_key     text NOT NULL CHECK (btrim(item_key) <> ''),
    evidence_id  uuid,            -- accepted evidence_items.id (no FK: ledger never rewritten)
    note         text,
    completed_by uuid,            -- auth.uid(); NULL = service path (no FK, as audit_log.user_id)
    completed_at timestamptz NOT NULL DEFAULT now(),
    CHECK (evidence_id IS NOT NULL OR (note IS NOT NULL AND btrim(note) <> ''))
);
COMMENT ON TABLE public.checklist_item_completions IS
  '#90 FR-QTR-01/02: one row per checklist item completion — APPEND ONLY '
  '(UPDATE always rejected; DELETE only as the FK cascade of its checklist or '
  'programme). Written only by complete_checklist_item. A completed item is '
  'final, so (checklist_id, item_key) is unique.';
CREATE UNIQUE INDEX checklist_item_completions_item_uq
  ON public.checklist_item_completions (checklist_id, item_key);
CREATE INDEX checklist_item_completions_programme_idx
  ON public.checklist_item_completions (programme_id);

CREATE OR REPLACE FUNCTION public.trg_checklist_completion_append_only() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE'
     AND (NOT EXISTS (SELECT 1 FROM public.checklist_instances c WHERE c.id = OLD.checklist_id)
          OR NOT EXISTS (SELECT 1 FROM public.programmes p WHERE p.id = OLD.programme_id)) THEN
    RETURN OLD;                       -- FK cascade: the parent is already gone
  END IF;
  RAISE EXCEPTION '% is append-only — % is not permitted', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $$;
COMMENT ON FUNCTION public.trg_checklist_completion_append_only() IS
  '#90: checklist_item_completions is append-only on every path; the only '
  'DELETE allowed is the FK cascade of a deleted checklist/programme.';

CREATE TRIGGER checklist_item_completions_append_only
BEFORE UPDATE OR DELETE ON public.checklist_item_completions
FOR EACH ROW EXECUTE FUNCTION public.trg_checklist_completion_append_only();

ALTER TABLE public.checklist_item_completions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.checklist_item_completions FORCE ROW LEVEL SECURITY;
CREATE POLICY checklist_item_completions_read ON public.checklist_item_completions
  FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
REVOKE ALL ON public.checklist_item_completions FROM anon, authenticated;
GRANT SELECT ON public.checklist_item_completions TO authenticated;
-- no INSERT/UPDATE/DELETE grant: complete_checklist_item is the only writer


-- ============================================================================
-- #90 — direct checklist writes closed (header §3 "DIRECT WRITES CLOSED")
-- ============================================================================
REVOKE INSERT, UPDATE ON public.checklist_instances FROM authenticated;
-- (column-level grants are revoked by the table-level REVOKE as well)
REVOKE INSERT (programme_id, kind, period, items) ON public.checklist_instances FROM authenticated;
REVOKE UPDATE (items) ON public.checklist_instances FROM authenticated;


-- ============================================================================
-- #90 — complete_checklist_item
-- ============================================================================
CREATE OR REPLACE FUNCTION public.complete_checklist_item(
    p_checklist_id uuid,
    p_item_key     text,
    p_evidence_id  uuid DEFAULT NULL,
    p_note         text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_ck       public.checklist_instances%ROWTYPE;
  v_pstatus  text;
  v_practice uuid;
  v_idx      int;
  v_item     jsonb;
  v_ev_prog  uuid;
  v_note     text := NULLIF(btrim(p_note), '');
BEGIN
  SELECT * INTO v_ck FROM public.checklist_instances
   WHERE id = p_checklist_id FOR UPDATE;
  -- tenant scope: a checklist the caller cannot see reads as not found
  IF NOT FOUND
     OR (v_uid IS NOT NULL
         AND v_ck.programme_id NOT IN (SELECT public.allowed_programmes())) THEN
    RAISE EXCEPTION 'checklist % not found', p_checklist_id;
  END IF;
  -- role scope: the generate_checklist set (WRITE roles + AO/alternate)
  IF NOT public.can_run_cadence(v_ck.programme_id) THEN
    RAISE EXCEPTION
      'complete_checklist_item: completing a checklist item requires a programme write role or the accountable officer / named alternate (FR-QTR-01)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT p.status, c.practice_id INTO v_pstatus, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_ck.programme_id;
  IF v_pstatus = 'closed' THEN
    RAISE EXCEPTION 'checklists of a closed programme cannot be changed';
  END IF;

  IF p_item_key IS NULL OR btrim(p_item_key) = '' THEN
    RAISE EXCEPTION 'an item key (the checklist item ref) is required';
  END IF;
  SELECT (u.ord - 1)::int, u.item INTO v_idx, v_item
    FROM jsonb_array_elements(coalesce(v_ck.items, '[]'::jsonb)) WITH ORDINALITY AS u(item, ord)
   WHERE u.item ->> 'ref' = p_item_key
   ORDER BY u.ord
   LIMIT 1;
  IF v_item IS NULL THEN
    RAISE EXCEPTION 'checklist item % not found on this checklist', p_item_key;
  END IF;

  -- final once done (header §3 RE-COMPLETE / UN-COMPLETE RULE)
  IF coalesce((v_item ->> 'done')::boolean, false)
     OR EXISTS (SELECT 1 FROM public.checklist_item_completions h
                 WHERE h.checklist_id = p_checklist_id AND h.item_key = p_item_key) THEN
    RAISE EXCEPTION 'checklist item % is already complete — completions are final (FR-QTR-01)', p_item_key
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  -- slot rule
  IF p_evidence_id IS NULL THEN
    IF coalesce((v_item ->> 'evidence_required')::boolean, false) THEN
      RAISE EXCEPTION 'checklist item % has an evidence slot: attach accepted evidence to complete it (FR-QTR-01)', p_item_key;
    END IF;
    IF v_note IS NULL THEN
      RAISE EXCEPTION 'record a note of what was done, or attach accepted evidence, to complete checklist item %', p_item_key;
    END IF;
  ELSE
    -- the 000013 accepted-evidence rule, same programme (never confirms
    -- that an id exists in another tenant)
    SELECT e.programme_id INTO v_ev_prog FROM public.evidence_items e WHERE e.id = p_evidence_id;
    IF v_ev_prog IS DISTINCT FROM v_ck.programme_id THEN
      RAISE EXCEPTION 'evidence % does not match any evidence in this programme', p_evidence_id;
    END IF;
    IF NOT public.evidence_item_is_accepted(p_evidence_id) THEN
      RAISE EXCEPTION 'evidence % is not accepted evidence (no accountable-officer acceptance decision)', p_evidence_id;
    END IF;
  END IF;

  v_item := v_item || jsonb_build_object(
              'done', true,
              'evidence_id', p_evidence_id,
              'note', v_note,
              'completed_at', now(),
              'completed_by', v_uid);
  UPDATE public.checklist_instances
     SET items = jsonb_set(items, ARRAY[v_idx::text], v_item)
   WHERE id = p_checklist_id;

  INSERT INTO public.checklist_item_completions
      (checklist_id, programme_id, item_key, evidence_id, note, completed_by)
  VALUES (p_checklist_id, v_ck.programme_id, p_item_key, p_evidence_id, v_note, v_uid);

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (v_uid, v_practice, 'checklist.item_completed',
          jsonb_build_object('checklist_instance_id', p_checklist_id,
                             'programme_id', v_ck.programme_id,
                             'kind', v_ck.kind, 'period', v_ck.period,
                             'item_key', p_item_key,
                             'evidence_id', p_evidence_id,
                             'note', v_note));
  RETURN v_item;
END $$;
COMMENT ON FUNCTION public.complete_checklist_item(uuid, text, uuid, text) IS
  '#90 FR-QTR-01/02: tick one quarterly/annual checklist item done. Guard: '
  'can_run_cadence (WRITE roles + AO/alternate; service path free), tenant '
  'scope via allowed_programmes(). Evidence must be accepted evidence of the '
  'same programme (evidence_item_is_accepted — the 000013 rule); an evidence '
  'slot needs evidence, other items evidence or a note. Final once done. '
  'Appends checklist_item_completions + audit_log; returns the updated item.';


-- ============================================================================
-- #92 — apply_template_version re-created: retired activities are skipped
-- ============================================================================
-- Body = 20261106000008 verbatim except three places marked "#92": the
-- v_active declaration, the retired branch at the top of the existing-
-- activity merge (counted as retained, nothing re-synced), and "AND
-- v_active" on the Not-started dependency pass. Signature, grants and
-- comment unchanged (CREATE OR REPLACE keeps the ACL).
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
  v_active   boolean;   -- #92: retired activities are skipped
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
      SELECT a.status, a.active INTO v_status, v_active
        FROM public.activities a WHERE a.id = v_id;
      v_started := v_status <> 'Not started';
      IF NOT v_active THEN
        -- #92: a retired activity is frozen — never re-synced by a template
        v_diff := jsonb_set(v_diff, '{activities,retained}',
                            to_jsonb((v_diff#>>'{activities,retained}')::int + 1));
      ELSIF v_status = 'Complete' THEN
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
    SELECT a.status, a.active INTO v_status, v_active
      FROM public.activities a WHERE a.id = v_id;
    IF v_status = 'Not started' AND v_active THEN   -- #92: skip retired
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
-- function surface
-- ============================================================================
REVOKE EXECUTE ON FUNCTION
  public.trg_activity_retired_guard(),
  public.evidence_item_is_accepted(uuid),
  public.trg_checklist_completion_append_only(),
  public.complete_checklist_item(uuid, text, uuid, text)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.complete_checklist_item(uuid, text, uuid, text)
TO authenticated;
-- register_closure_ref_problem / apply_template_version keep their existing
-- ACLs (CREATE OR REPLACE preserves them).

COMMIT;
