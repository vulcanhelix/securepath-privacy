-- ============================================================================
-- W1 FOLLOW-UPS: FR-WKS-03 in the database, weekly-log attendees, and the
-- screen RPCs programme_people (#81), update_activity_status (#82) and
-- week_due_date (#83). Spec SP-SPC-PLT-001 §4.2, §6.2, §8.5, §9.1, §9.2.
-- ============================================================================
--
-- Additive only: old migration files are untouched. upsert_weekly_log is
-- recreated with CREATE OR REPLACE and the same signature.
--
-- HARD RULE (unchanged): every SECURITY DEFINER below checks tenant + role
-- scope in its own body, because a definer owned by supabase_admin bypasses RLS.
--
-- ---------------------------------------------------------------------------
-- 1. FR-WKS-03: "An Amber activity cannot be saved from the session without a
--    recovery date"
-- ---------------------------------------------------------------------------
-- WHY A TRIGGER (not RPC-only enforcement): the W0-02 column grants let
-- authenticated users UPDATE activities directly (status, recovery_date,
-- comments, ...). The activities_update RLS policy admits WRITE roles,
-- workstream_lead, external_provider and listed leads. So update_activity
-- is not the only user write path, and an RPC-only check could be bypassed
-- through PostgREST. The rule therefore lives in an AFTER UPDATE row trigger,
-- trg_activity_session_guard, which fires on every path.
--
-- HOW THE TRIGGER TELLS USER EDITS FROM ENGINE RECOMPUTES: activities.rag is
-- a CALC column. recompute_activity_due writes it under the caller's JWT,
-- often in the same transaction as the edit. The guard only acts when
--   (a) auth.uid() IS NOT NULL (a JWT caller; NULL is the service, scheduler
--       or migration path, W0-02 convention), AND
--   (b) a SESSION column actually changed (OLD vs NEW, not just named in the
--       SET list): status, pct_complete, actual_completion, flag, comments,
--       recovery_date, rescheduled_date, dependency_override_reason.
-- Recompute writes touch only phase/start_date/due_date/month/rag, so (b) is
-- false for them and they always pass, whatever rag they set.
-- When it acts, it rejects the row if recovery_date ends up NULL and the rag
-- is Amber BEFORE (OLD.rag, the stored value) or AFTER the edit.
-- "After" is public.activity_rag(NEW.id), the engine's own §9.2 function.
-- An AFTER trigger sees the updated row, so no RAG formula is duplicated here.
-- One exemption: an edit whose post-edit rag is 'Complete' passes even if the
-- item was Amber before. Completing the work is the recovery, and the W1-05
-- suite (and real usage) completes overdue items without a recovery date.
--
-- Session columns, not every editable column: apply_template_version
-- (FR-TPL-03) re-syncs text/milestone/evidence_required and, on Not-started
-- rows, workstream/weeks under the partner's JWT. Those are template/schedule
-- edits (FR-TPL-04), not session saves. Including them would make a template
-- apply fail on any Amber row that has no recovery date. A schedule move
-- (end_week) is also the usual remedy for Amber. INSERTs are not guarded:
-- create_programme/add_activity insert rows whose rag the engine has not
-- computed yet. A programme created with a past start date would otherwise
-- be rejected.
--
-- The same trigger also enforces #82's "status only" rule on direct writes.
-- A JWT caller without a WRITE role on the activity (a workstream_lead,
-- external_provider or listed lead admitted by the RLS policy) may change
-- only the status fields: status, comments, recovery_date,
-- dependency_override_reason, rescheduled_date (+ actual_completion, which
-- trg_activity_completion stamps). Any other column change is rejected, so the
-- narrow RPC cannot be sidestepped through a direct UPDATE. New columns added
-- later are protected by default (the comparison is "everything except").
--
-- ---------------------------------------------------------------------------
-- 2. weekly_logs.attendees: jsonb array of {user_id?, name, role?}
-- ---------------------------------------------------------------------------
-- Column grant matches the other client-writable log fields (INSERT + UPDATE
-- like session_held/completed/planned_next/blockers/decisions). A CHECK via
-- the IMMUTABLE validator weekly_log_attendees_valid() protects the direct-write
-- path. upsert_weekly_log validates again with friendly errors, and checks
-- that any user_id is a real user.
--
-- ---------------------------------------------------------------------------
-- 3. programme_people(p_programme_id): #81
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER, guarded by allowed_programmes(). People = holders of an
-- ACTIVE role assignment that reaches the programme (programme scope, a
-- workstream of it, its client, or its client's partner; platform roles
-- excluded), plus users referenced by the programme (programme_lead,
-- workstream accountable_lead/deputy, activity leads) so screens can name them
-- even without an assignment (roles = '{}'). display_name = full_name, falling
-- back to the email LOCAL PART. The full email is never returned. Callers who
-- may read a users row can already select it through users RLS.
--
-- ---------------------------------------------------------------------------
-- 4. update_activity_status(...): #82
-- ---------------------------------------------------------------------------
-- Allowed for: the roles update_activity allows (WRITE on the programme), the
-- activity's listed leads, and the workstream lead of its workstream (an active
-- workstream_lead assignment at that workstream's scope, OR
-- workstreams.accountable_lead). Writes status-related fields only. Reuses:
--   * FR-SCH-04: leaving 'Not started' with incomplete predecessors needs a
--     dependency_override_reason (same rule as update_activity)
--   * Deferred needs a rescheduled_date (rules-engine invariant). The RPC
--     takes an optional p_rescheduled_date, because without it a lead could
--     never defer.
--   * status history: the existing trg_activity_status_history (changed_by =
--     the caller)
--   * recompute: recompute_programme_progress. That function demands a WRITE
--     role from JWT callers, and a lead has none. So after its own authz
--     check this RPC runs the recompute on the service path: the JWT claim
--     GUCs are blanked transaction-locally and restored straight after. GUC
--     changes roll back with the (sub)transaction on error. The recompute
--     touches calc columns only, and the caller never chooses what runs.
--
-- ---------------------------------------------------------------------------
-- 5. week_due_date: #83
-- ---------------------------------------------------------------------------
-- The rules engine (20261106000001) already ships
--   public.week_due_date(p_programme uuid, p_week int) STABLE INVOKER
--     = week_end(p_programme, p_week)
-- and grants it to authenticated. That is exactly the thin wrapper #83 asks
-- for. Renaming the parameter to p_programme_id would need DROP FUNCTION
-- (CREATE OR REPLACE cannot rename input parameters), which is not additive.
-- So the function is kept as is, only re-commented here, and covered by the
-- follow-up suite. PostgREST callers pass {p_programme, p_week}. INVOKER:
-- programmes RLS hides other tenants' programmes, so the result is NULL.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. FR-WKS-03 + status-only guard on activities
-- ============================================================================
CREATE OR REPLACE FUNCTION public.trg_activity_session_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  -- session fields saved from the weekly session (FR-WKS-03 trigger set)
  c_session text[] := ARRAY['status','pct_complete','actual_completion','flag',
                            'comments','recovery_date','rescheduled_date',
                            'dependency_override_reason'];
  -- what a non-WRITE caller (lead / workstream lead / provider) may change
  c_status_only text[] := ARRAY['status','comments','recovery_date',
                                'dependency_override_reason','rescheduled_date',
                                'actual_completion',
                                -- calc columns (engine-written; grants already
                                -- block direct writes of these)
                                'phase','start_date','due_date','month','rag'];
  v_old jsonb;
  v_new jsonb;
  v_rag_after text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NULL;                       -- service / scheduler / migration path
  END IF;
  v_old := to_jsonb(OLD);
  v_new := to_jsonb(NEW);

  -- #82: non-writers may change status fields only (direct-write path too)
  IF (v_new - c_status_only) IS DISTINCT FROM (v_old - c_status_only)
     AND NOT public.has_activity_role(NEW.id,
           ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION
      'only status fields (status, comments, recovery_date, dependency_override_reason, rescheduled_date) may be changed without a programme write role'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- FR-WKS-03: only when a session field really changed (recomputes don't)
  IF (SELECT bool_or(v_new -> k IS DISTINCT FROM v_old -> k) FROM unnest(c_session) k)
     AND NEW.recovery_date IS NULL THEN
    v_rag_after := public.activity_rag(NEW.id);   -- engine §9.2 on the new row
    -- completing the work IS the recovery: an edit that lands on Complete
    -- needs no recovery date even when the item was Amber before
    IF OLD.rag = 'Amber' AND v_rag_after IS DISTINCT FROM 'Complete' THEN
      RAISE EXCEPTION
        'activity % is Amber: a recovery_date is required to save it (FR-WKS-03)', NEW.ref
        USING ERRCODE = 'check_violation';
    END IF;
    IF v_rag_after = 'Amber' THEN
      RAISE EXCEPTION
        'activity % would be Amber after this edit: a recovery_date is required (FR-WKS-03)', NEW.ref
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NULL;
END $$;
COMMENT ON FUNCTION public.trg_activity_session_guard() IS
  'FR-WKS-03 + #82: for JWT callers, (1) non-WRITE callers may change status '
  'fields only; (2) a session-field change on an activity whose rag is Amber '
  'before (stored) or after (activity_rag on the new row) must leave '
  'recovery_date set. Calc-only recompute writes never trip it.';

DROP TRIGGER IF EXISTS activity_session_guard ON public.activities;
CREATE TRIGGER activity_session_guard
AFTER UPDATE ON public.activities
FOR EACH ROW EXECUTE FUNCTION public.trg_activity_session_guard();


-- ============================================================================
-- 2. weekly_logs.attendees
-- ============================================================================
CREATE OR REPLACE FUNCTION public.weekly_log_attendees_valid(p jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT p IS NOT NULL
     AND jsonb_typeof(p) = 'array'
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(p) e
        WHERE jsonb_typeof(e) <> 'object'
           OR jsonb_typeof(e -> 'name') IS DISTINCT FROM 'string'
           OR btrim(e ->> 'name') = ''
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k
                       WHERE k NOT IN ('user_id','name','role'))
           OR (e ? 'user_id' AND jsonb_typeof(e -> 'user_id') <> 'null'
               AND (jsonb_typeof(e -> 'user_id') <> 'string'
                    OR (e ->> 'user_id') !~*
                       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
           OR (e ? 'role' AND jsonb_typeof(e -> 'role') NOT IN ('string','null')))
$$;
COMMENT ON FUNCTION public.weekly_log_attendees_valid(jsonb) IS
  'Shape check for weekly_logs.attendees: array of {name (non-empty string), '
  'user_id? (uuid string|null), role? (string|null)}, no other keys.';

ALTER TABLE public.weekly_logs
  ADD COLUMN IF NOT EXISTS attendees jsonb NOT NULL DEFAULT '[]';
ALTER TABLE public.weekly_logs
  DROP CONSTRAINT IF EXISTS weekly_logs_attendees_chk;
ALTER TABLE public.weekly_logs
  ADD CONSTRAINT weekly_logs_attendees_chk
  CHECK (public.weekly_log_attendees_valid(attendees));
COMMENT ON COLUMN public.weekly_logs.attendees IS
  'FR-WKS-04 session attendees: jsonb array of {user_id?, name, role?}. '
  'Client-writable (same grant as the other log fields).';
GRANT INSERT (attendees) ON public.weekly_logs TO authenticated;
GRANT UPDATE (attendees) ON public.weekly_logs TO authenticated;

-- upsert_weekly_log: same signature; body = W1-06 + attendees merge/validate
CREATE OR REPLACE FUNCTION public.upsert_weekly_log(
    p_programme_id uuid, p_week_no int, p_payload jsonb DEFAULT '{}')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_total int; v_existing public.weekly_logs; v_id uuid; v_practice uuid;
  v_counts jsonb; v_rag text;
  v_session_held boolean; v_completed jsonb; v_planned jsonb;
  v_blockers text; v_decisions text; v_dec jsonb; v_attendees jsonb; v_att jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT public.has_programme_role(p_programme_id,
       ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'weekly log write requires a programme write role';
  END IF;
  SELECT total_weeks INTO v_total FROM public.programmes WHERE id = p_programme_id;
  IF v_total IS NULL THEN RAISE EXCEPTION 'programme not found'; END IF;
  IF p_week_no IS NULL OR p_week_no < 1 OR p_week_no > v_total THEN
    RAISE EXCEPTION 'week % is outside the programme length (1..%)', p_week_no, v_total;
  END IF;

  -- attendees (validated before any write)
  IF p_payload ? 'attendees' THEN
    v_attendees := p_payload -> 'attendees';
    IF jsonb_typeof(v_attendees) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'attendees must be a jsonb array of {user_id?, name, role?}';
    END IF;
    FOR v_att IN SELECT * FROM jsonb_array_elements(v_attendees) LOOP
      IF NOT public.weekly_log_attendees_valid(jsonb_build_array(v_att)) THEN
        RAISE EXCEPTION 'invalid attendee %: expected {user_id?: uuid, name: non-empty text, role?: text}', v_att;
      END IF;
      IF v_att ? 'user_id' AND jsonb_typeof(v_att -> 'user_id') = 'string'
         AND NOT EXISTS (SELECT 1 FROM public.users u
                          WHERE u.id = (v_att ->> 'user_id')::uuid) THEN
        RAISE EXCEPTION 'attendee user % does not exist', v_att ->> 'user_id';
      END IF;
    END LOOP;
  END IF;

  SELECT * INTO v_existing FROM public.weekly_logs
   WHERE programme_id = p_programme_id AND week = p_week_no;

  -- FR-WKS-04: calculated counts (unchanged from W1-06)
  SELECT jsonb_build_object(
      'due',      count(*) FILTER (WHERE a.end_week = p_week_no AND a.status <> 'Complete'),
      'overdue',  count(*) FILTER (WHERE a.status <> 'Complete'
                                   AND a.due_date IS NOT NULL AND a.due_date < CURRENT_DATE),
      'starting', count(*) FILTER (WHERE a.start_week = p_week_no),
      'blocked',  count(*) FILTER (WHERE a.status = 'Blocked'))
    INTO v_counts
    FROM public.activities a WHERE a.programme_id = p_programme_id;
  SELECT v_counts || jsonb_build_object(
      'awaiting_decision',
        (SELECT count(*) FROM public.evidence_items e
          WHERE e.programme_id = p_programme_id AND e.review_stage = 'acceptance'),
      'raid_open',
        (SELECT count(*) FROM public.raid_items r
          WHERE r.programme_id = p_programme_id AND r.status <> 'Closed'),
      'raid_due_review',
        (SELECT count(*) FROM public.raid_items r
          WHERE r.programme_id = p_programme_id AND r.status <> 'Closed'
            AND r.review_by IS NOT NULL AND r.review_by <= CURRENT_DATE),
      'reduced_capacity',
        (SELECT p_week_no = ANY(p.reduced_capacity_weeks)
           FROM public.programmes p WHERE p.id = p_programme_id))
    INTO v_counts;

  v_rag := CASE
    WHEN (v_counts->>'overdue')::int > 0
      OR EXISTS (SELECT 1 FROM public.activities a
                  WHERE a.programme_id = p_programme_id
                    AND (a.rag = 'Red' OR a.status = 'Blocked')) THEN 'Red'
    WHEN (v_counts->>'awaiting_decision')::int > 0
      OR (v_counts->>'raid_due_review')::int > 0
      OR EXISTS (SELECT 1 FROM public.activities a
                  WHERE a.programme_id = p_programme_id
                    AND (a.rag = 'Amber' OR a.status = 'At risk')) THEN 'Amber'
    ELSE 'Green' END;

  v_session_held := COALESCE((p_payload->>'session_held')::boolean,
                             v_existing.session_held, false);
  v_completed    := COALESCE(p_payload->'completed',   v_existing.completed,   '[]'::jsonb);
  v_planned      := COALESCE(p_payload->'planned_next', v_existing.planned_next, '[]'::jsonb);
  v_blockers     := COALESCE(p_payload->>'blockers',    v_existing.blockers);
  v_decisions    := COALESCE(p_payload->>'decisions',   v_existing.decisions);
  v_attendees    := COALESCE(v_attendees, v_existing.attendees, '[]'::jsonb);

  INSERT INTO public.weekly_logs
      (programme_id, week, counts, session_held, completed, planned_next,
       blockers, decisions, week_rag, attendees)
  VALUES (p_programme_id, p_week_no, v_counts, v_session_held, v_completed,
          v_planned, v_blockers, v_decisions, v_rag, v_attendees)
  ON CONFLICT (programme_id, week) DO UPDATE SET
      counts       = EXCLUDED.counts,
      session_held = EXCLUDED.session_held,
      completed    = EXCLUDED.completed,
      planned_next = EXCLUDED.planned_next,
      blockers     = EXCLUDED.blockers,
      decisions    = EXCLUDED.decisions,
      week_rag     = EXCLUDED.week_rag,
      attendees    = EXCLUDED.attendees
  RETURNING id INTO v_id;

  FOR v_dec IN
    SELECT * FROM jsonb_array_elements(
                    COALESCE(p_payload->'decisions_taken', '[]'::jsonb))
  LOOP
    PERFORM public.record_decision(
        (v_dec->>'raid_item_id')::uuid,
        v_dec->>'outcome',
        v_dec->>'minute_ref',
        COALESCE(v_dec->'unlocks', '[]'::jsonb),
        NULL);
  END LOOP;

  SELECT c.practice_id INTO v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = p_programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'weekly_log.upserted',
          jsonb_build_object('programme_id', p_programme_id, 'week', p_week_no,
                             'weekly_log_id', v_id,
                             'attendees', jsonb_array_length(v_attendees)));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.upsert_weekly_log(uuid, int, jsonb) IS
  'W1-06 FR-WKS-04 (+ follow-up attendees): one weekly-log row per '
  '(programme, week); payload merges {session_held, completed, planned_next, '
  'blockers, decisions, attendees[{user_id?, name, role?}], decisions_taken[]}; '
  'counts + week_rag are engine-computed.';


-- ============================================================================
-- 3. programme_people (#81)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.programme_people(p_programme_id uuid)
RETURNS TABLE (user_id uuid, display_name text, roles text[])
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_programme_id IS NULL
     OR p_programme_id NOT IN (SELECT public.allowed_programmes()) THEN
    RAISE EXCEPTION 'programme % is not visible to the caller', p_programme_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH prog AS (
    SELECT pr.id, pr.client_org_id, co.practice_id, pr.programme_lead
      FROM public.programmes pr
      JOIN public.client_orgs co ON co.id = pr.client_org_id
     WHERE pr.id = p_programme_id
  ),
  assigned AS (
    SELECT ra.user_id AS uid, ra.role
      FROM public.role_assignments ra, prog
     WHERE ra.level IN ('partner','client')
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
       AND ( (ra.scope_type = 'programme'  AND ra.scope_id = prog.id)
          OR (ra.scope_type = 'client'     AND ra.scope_id = prog.client_org_id)
          OR (ra.scope_type = 'partner'    AND ra.scope_id = prog.practice_id)
          OR (ra.scope_type = 'workstream' AND ra.scope_id IN
                (SELECT w.id FROM public.workstreams w WHERE w.programme_id = prog.id)) )
  ),
  referenced AS (
    SELECT prog.programme_lead AS uid FROM prog
    UNION SELECT w.accountable_lead FROM public.workstreams w WHERE w.programme_id = p_programme_id
    UNION SELECT w.deputy           FROM public.workstreams w WHERE w.programme_id = p_programme_id
    UNION SELECT unnest(a.leads)    FROM public.activities  a WHERE a.programme_id = p_programme_id
  ),
  people AS (
    SELECT uid FROM assigned UNION SELECT uid FROM referenced
  )
  SELECT u.id,
         coalesce(nullif(btrim(u.full_name), ''),
                  nullif(split_part(u.email, '@', 1), ''),
                  'Unknown user')::text,
         coalesce((SELECT array_agg(DISTINCT a.role ORDER BY a.role)
                     FROM assigned a WHERE a.uid = u.id), '{}'::text[])
    FROM people p
    JOIN public.users u ON u.id = p.uid
   ORDER BY 2, 1;
END $$;
COMMENT ON FUNCTION public.programme_people(uuid) IS
  '#81: people on a visible programme: active role holders reaching it '
  '(programme/workstream/client/partner scope) plus referenced leads. Returns '
  'id, display name (full_name, else email local part; never the full email) '
  'and active role names. Guarded by allowed_programmes().';


-- ============================================================================
-- 4. update_activity_status (#82)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_activity_status(
    p_activity_id      uuid,
    p_status           text,
    p_comment          text DEFAULT NULL,
    p_override_reason  text DEFAULT NULL,
    p_recovery_date    date DEFAULT NULL,
    p_rescheduled_date date DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_act        public.activities;
  v_uid        uuid := auth.uid();
  v_new_status text;
  v_open_deps  int;
  v_override   text;
  v_practice   uuid;
  v_claims     text;
  v_claim_sub  text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_act FROM public.activities a WHERE a.id = p_activity_id;
  IF v_act IS NULL THEN RAISE EXCEPTION 'activity % not found', p_activity_id; END IF;

  -- authz: WRITE role (as update_activity) OR listed lead OR workstream lead
  IF NOT (
       public.has_programme_role(v_act.programme_id,
         ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])
    OR v_uid = ANY(v_act.leads)
    OR (v_act.workstream_id IS NOT NULL AND (
          EXISTS (SELECT 1 FROM public.role_assignments ra
                   WHERE ra.user_id = v_uid
                     AND ra.role = 'workstream_lead'
                     AND ra.scope_type = 'workstream'
                     AND ra.scope_id = v_act.workstream_id
                     AND ra.start_date <= CURRENT_DATE
                     AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE))
       OR EXISTS (SELECT 1 FROM public.workstreams w
                   WHERE w.id = v_act.workstream_id
                     AND w.accountable_lead = v_uid)))
  ) THEN
    RAISE EXCEPTION 'status update requires being a lead of this activity, its workstream lead, or a programme write role (§4.2)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_new_status := coalesce(p_status, v_act.status);
  IF v_new_status NOT IN ('Not started','In progress','At risk','Blocked','Deferred','Complete') THEN
    RAISE EXCEPTION 'unknown activity status "%"', v_new_status;
  END IF;

  -- FR-SCH-04 (same rule as update_activity)
  IF v_act.status = 'Not started' AND v_new_status <> 'Not started' THEN
    SELECT count(*) INTO v_open_deps
      FROM public.activity_deps d
      JOIN public.activities a ON a.id = d.depends_on_activity_id
     WHERE d.activity_id = v_act.id AND a.status <> 'Complete';
    v_override := coalesce(p_override_reason, v_act.dependency_override_reason);
    IF v_open_deps > 0 AND (v_override IS NULL OR btrim(v_override) = '') THEN
      RAISE EXCEPTION
        'cannot start activity: % predecessor(s) incomplete — record a dependency_override_reason (FR-SCH-04)',
        v_open_deps;
    END IF;
  END IF;

  -- Deferred needs a rescheduled date (rules-engine decision 3)
  IF v_new_status = 'Deferred'
     AND coalesce(p_rescheduled_date, v_act.rescheduled_date) IS NULL THEN
    RAISE EXCEPTION 'a Deferred activity needs a rescheduled_date (§9.2 / §15-#13)';
  END IF;

  -- status fields only; FR-WKS-03 is enforced by trg_activity_session_guard
  UPDATE public.activities SET
      status                     = v_new_status,
      comments                   = coalesce(p_comment, comments),
      dependency_override_reason = coalesce(p_override_reason, dependency_override_reason),
      recovery_date              = coalesce(p_recovery_date, recovery_date),
      rescheduled_date           = coalesce(p_rescheduled_date, rescheduled_date)
   WHERE id = p_activity_id;
  -- status change → trg_activity_status_history appends the ledger row

  -- recompute on the service path (see header §4): blank the claim GUCs
  -- transaction-locally, recompute, restore
  v_claims    := current_setting('request.jwt.claims', true);
  v_claim_sub := current_setting('request.jwt.claim.sub', true);
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM public.recompute_programme_progress(v_act.programme_id);
  PERFORM set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_claim_sub, ''), true);

  SELECT c.practice_id INTO v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_act.programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (v_uid, v_practice, 'activity.status_updated',
          jsonb_build_object('activity_id', p_activity_id,
                             'programme_id', v_act.programme_id,
                             'old_status', v_act.status,
                             'new_status', v_new_status,
                             'comment', p_comment,
                             'override_reason', p_override_reason,
                             'recovery_date', p_recovery_date,
                             'rescheduled_date', p_rescheduled_date));
  RETURN p_activity_id;
END $$;
COMMENT ON FUNCTION public.update_activity_status(uuid, text, text, text, date, date) IS
  '#82 (§4.2 "Update activity status: Own"): status-only update for listed '
  'leads, the workstream lead, or programme WRITE roles. FR-SCH-04 override, '
  'Deferred→rescheduled_date, FR-WKS-03 (trigger), status history (trigger) '
  'and engine recompute all apply.';


-- ============================================================================
-- 5. week_due_date (#83): existing rules-engine function, documented
-- ============================================================================
COMMENT ON FUNCTION public.week_due_date(uuid, int) IS
  '§9.1 / #83: Friday of programme week p_week (= week_end; start + '
  '(week−1)×7 + 4). Server-owned week maths for screens: call this instead '
  'of re-deriving it client-side. STABLE INVOKER: NULL for programmes the '
  'caller cannot see.';


-- ============================================================================
-- 6. function surface
-- ============================================================================
REVOKE EXECUTE ON FUNCTION
  public.trg_activity_session_guard(),
  public.programme_people(uuid),
  public.update_activity_status(uuid, text, text, text, date, date)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.programme_people(uuid),
  public.update_activity_status(uuid, text, text, text, date, date)
TO authenticated;
-- weekly_log_attendees_valid stays executable (pure shape check used by the
-- CHECK constraint on direct writes).

COMMIT;
