-- ============================================================================
-- W1-06 — OPS CRUD RPCs: weekly session log, KPI actuals + status, RAID items
-- (+ status history), decisions ledger, and the FR-MNT-06 exception→RAID rule
-- (GitHub #20 · spec SP-SPC-PLT-001 §8.5/§8.7/§8.8/§8.9, §9, §10 ·
--  plan BUILD_PLAN_R1 W1-06)
-- ============================================================================
--
-- Built ON the W0-02 spine (00003): every table already exists — this file adds
-- the RPC surface plus two small additive pieces:
--
--   * raid_status_history — append-only transition ledger for raid_items
--     (mirrors activity_status_history; W0-02 deliberately shipped none and
--     W1-06 was asked to add one if absent).
--   * trg_mti_exception_raid — a maintenance task instance that moves to
--     'Exception' auto-raises a RAID issue (source='exception') and links it
--     through exception_raid_item_id (FR-MNT-06). W0-02's trg_mti_scope already
--     validates the link's programme scope; this trigger fills it. Runs BEFORE
--     mti_scope_check (alphabetical trigger order) so the fresh id passes the
--     scope validation on the same statement.
--
-- HARD RULE (unchanged): every SECURITY DEFINER below guards
-- allowed_programmes()/has_programme_role()/is_ao_or_alternate() in its body —
-- a definer owned by supabase_admin bypasses RLS, so the check must live in
-- the function. Every mutation writes an audit_log row (W0-00 pattern:
-- user_id, practice_id via the programme's client, action, detail).
--
-- WRITE-role sets (matching the W0-02 table policies):
--   WRITE  := partner_admin, partner_consultant, programme_lead, client_admin
--   RAID+  := WRITE + executive, accountable_officer   (raid_items/decisions
--             INSERT policies already admit these — §8.8 exec sessions)
--
-- DEVIATIONS FROM THE PACKET SIGNATURES (schema-faithful):
--   * record_decision is keyed on raid_item_id, not programme_id — the W0-02
--     schema hangs decisions off raid_items (raid_item_id NOT NULL). A
--     decision recorded in a weekly session for a programme-level matter is
--     stored against a RAID item (upsert_weekly_log's decisions_taken entries
--     take raid_item_id for the same reason).
--   * record_kpi_actual's "note" has no column on kpi_actuals — the note is
--     preserved in the audit_log detail instead of being dropped.
--   * list_raid_items filters status | type | owner — the schema has no
--     risk_level column; 'type' (risk|assumption|issue) is the spec field.
--
-- KPI RAG NOTE: W1-01's shared RAG engine does not exist on this branch yet.
-- kpi_status() therefore uses a documented KPI-LOCAL rule (direction inferred
-- from baseline vs target — see the function comment). When W1-01 lands its
-- thresholds this CASE is the single place to swap.
-- ============================================================================


-- ---------- 1. raid_status_history — append-only transition ledger ----------
CREATE TABLE public.raid_status_history (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    raid_item_id uuid NOT NULL REFERENCES public.raid_items(id) ON DELETE CASCADE,
    old_status   text,
    new_status   text NOT NULL,
    changed_by   uuid REFERENCES public.users(id) ON DELETE SET NULL,
    changed_at   timestamptz NOT NULL DEFAULT now(),
    note         text
);
COMMENT ON TABLE public.raid_status_history IS
  'W1-06: RAID status transition ledger — APPEND ONLY (spec §6.2 audit nature; '
  'mirrors activity_status_history). Policy template: T2 via the raid item.';
CREATE INDEX raid_status_history_idx ON public.raid_status_history (raid_item_id);


-- ---------- 2. append-only enforcement (REVOKE below + this trigger) ----------
-- decisions was already REVOKEd UPDATE/DELETE in W0-02; the hard rule for this
-- slice asks for the trigger belt-and-braces on BOTH tables so no write path —
-- direct SQL, definer RPC, admin shell — can mutate or remove ledger rows.
-- (Fixture wipes suspend these via DISABLE TRIGGER USER, same convention as
-- evidence_immutable / report_transition_gate.)
CREATE FUNCTION public.trg_append_only() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION '% is append-only — % is not permitted', TG_TABLE_NAME, TG_OP;
END $$;
COMMENT ON FUNCTION public.trg_append_only() IS
  'W1-06 shared guard: reject every UPDATE/DELETE on append-only ledgers.';

CREATE TRIGGER decisions_append_only
BEFORE UPDATE OR DELETE ON public.decisions
FOR EACH ROW EXECUTE FUNCTION public.trg_append_only();

CREATE TRIGGER raid_status_history_append_only
BEFORE UPDATE OR DELETE ON public.raid_status_history
FOR EACH ROW EXECUTE FUNCTION public.trg_append_only();


-- ---------- 3. raid status transitions append to the ledger (any write path) --
CREATE FUNCTION public.trg_raid_status_history() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.raid_status_history
        (raid_item_id, old_status, new_status, changed_by, note)
    VALUES (OLD.id, OLD.status, NEW.status, auth.uid(),
            NULLIF(current_setting('securepath.raid_transition_note', true), ''));
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_raid_status_history() IS
  'W1-06: every raid_items.status change appends a raid_status_history row '
  '(direct writes and RPC writes alike — spec §6.2 audit nature). An optional '
  'transition note arrives via the securepath.raid_transition_note GUC so the '
  'ledger stays strictly append-only.';

CREATE TRIGGER raid_status_history_trg
AFTER UPDATE ON public.raid_items
FOR EACH ROW EXECUTE FUNCTION public.trg_raid_status_history();


-- ---------- 4. FR-MNT-06: maintenance exception auto-raises a RAID issue -----
-- On any transition INTO 'Exception' (insert or update) with no RAID item yet
-- linked, create an 'issue' row sourced 'exception' and back-link it. Runs
-- before mti_scope_check (trigger name sorts first) so the scope guard sees
-- the same-programme link. Definer + audit row per the mutation rule.
CREATE FUNCTION public.trg_mti_exception_raid() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_programme uuid; v_task text; v_raid uuid; v_client uuid; v_practice uuid;
BEGIN
  IF NEW.status <> 'Exception'
     OR (TG_OP = 'UPDATE' AND OLD.status = 'Exception')
     OR NEW.exception_raid_item_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT t.programme_id, t.task INTO v_programme, v_task
    FROM public.maintenance_task_templates t WHERE t.id = NEW.task_template_id;
  IF v_programme IS NULL THEN
    RETURN NEW;                       -- content-row template: nothing to hang the RAID on
  END IF;

  INSERT INTO public.raid_items (programme_id, type, description, action,
                                 owner, status, source)
  VALUES (v_programme, 'issue',
          'Maintenance exception '||NEW.period||' — '||
            COALESCE(NEW.exception_reason, v_task),
          NEW.exception_reason,
          COALESCE(NEW.assignee,
                   (SELECT p.programme_lead FROM public.programmes p
                     WHERE p.id = v_programme)),
          'Open', 'exception')
  RETURNING id INTO v_raid;

  NEW.exception_raid_item_id := v_raid;

  SELECT c.practice_id INTO v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_programme;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'raid.exception_raised',
          jsonb_build_object('raid_item_id', v_raid,
                             'maintenance_task_instance_id', NEW.id,
                             'period', NEW.period));
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_mti_exception_raid() IS
  'W1-06 FR-MNT-06: an instance entering Exception auto-creates a RAID issue '
  '(source=exception) and back-links exception_raid_item_id. Engine-written; '
  'idempotent per instance (skips when a link already exists).';

CREATE TRIGGER mti_exception_raid                       -- sorts before mti_scope_check
BEFORE INSERT OR UPDATE ON public.maintenance_task_instances
FOR EACH ROW EXECUTE FUNCTION public.trg_mti_exception_raid();


-- ---------- 5. RPCs ----------

-- ---- weekly session log (FR-WKS-04) ----
-- One row per (programme, week). counts + week_rag are CALC columns — computed
-- here, never taken from the payload. The payload merges over any existing
-- row (absent keys keep the stored value). Optional "decisions_taken" entries
-- record session decisions into the append-only ledger via record_decision.
CREATE FUNCTION public.upsert_weekly_log(
    p_programme_id uuid, p_week_no int, p_payload jsonb DEFAULT '{}')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_total int; v_existing public.weekly_logs; v_id uuid; v_practice uuid;
  v_counts jsonb; v_rag text;
  v_session_held boolean; v_completed jsonb; v_planned jsonb;
  v_blockers text; v_decisions text; v_dec jsonb;
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

  SELECT * INTO v_existing FROM public.weekly_logs
   WHERE programme_id = p_programme_id AND week = p_week_no;

  -- FR-WKS-04: calculated counts fill automatically (due / overdue / starting /
  -- evidence awaiting decision / RAID open + due-for-review / capacity flag).
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

  -- Week RAG (CALC): simple local rule pending W1-01's canonical thresholds —
  -- Red on overdue/red/blocked work, Amber on awaiting decisions / due RAID
  -- reviews / at-risk or amber work, else Green.
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

  INSERT INTO public.weekly_logs
      (programme_id, week, counts, session_held, completed, planned_next,
       blockers, decisions, week_rag)
  VALUES (p_programme_id, p_week_no, v_counts, v_session_held, v_completed,
          v_planned, v_blockers, v_decisions, v_rag)
  ON CONFLICT (programme_id, week) DO UPDATE SET
      counts       = EXCLUDED.counts,
      session_held = EXCLUDED.session_held,
      completed    = EXCLUDED.completed,
      planned_next = EXCLUDED.planned_next,
      blockers     = EXCLUDED.blockers,
      decisions    = EXCLUDED.decisions,
      week_rag     = EXCLUDED.week_rag
  RETURNING id INTO v_id;

  -- Session decisions are append-only ledger rows, not just log text
  -- (FR-RAI-03): each entry {raid_item_id, outcome, minute_ref?, unlocks?}
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
                             'weekly_log_id', v_id));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.upsert_weekly_log(uuid, int, jsonb) IS
  'W1-06 FR-WKS-04: one weekly-log row per (programme, week); payload merges '
  '{session_held, completed, planned_next, blockers, decisions, '
  'decisions_taken[]}; counts + week_rag are engine-computed.';

CREATE FUNCTION public.get_weekly_log(p_programme_id uuid, p_week_no int)
RETURNS public.weekly_logs
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT w.* FROM public.weekly_logs w
   WHERE w.programme_id = p_programme_id
     AND w.week = p_week_no
     AND p_programme_id IN (SELECT public.allowed_programmes())
$$;
COMMENT ON FUNCTION public.get_weekly_log(uuid, int) IS
  'W1-06: a programme''s weekly log for one week (NULL when none held).';

CREATE FUNCTION public.list_weekly_logs(p_programme_id uuid)
RETURNS SETOF public.weekly_logs
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT w.* FROM public.weekly_logs w
   WHERE w.programme_id = p_programme_id
     AND p_programme_id IN (SELECT public.allowed_programmes())
   ORDER BY w.week
$$;
COMMENT ON FUNCTION public.list_weekly_logs(uuid) IS
  'W1-06: all weekly logs for a visible programme, oldest first.';


-- ---- KPIs (FR-KPI-01/02/03/04) ----
-- FR-KPI-02: auto_calc KPIs are engine-calculated — manual entries are only
-- accepted for the rest, and monthly entries may carry evidence.
CREATE FUNCTION public.record_kpi_actual(
    p_kpi_id uuid, p_month date, p_value numeric,
    p_note text DEFAULT NULL, p_evidence_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_kpi public.kpis; v_month date; v_id uuid; v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_kpi FROM public.kpis WHERE id = p_kpi_id;
  IF v_kpi IS NULL THEN RAISE EXCEPTION 'kpi not found'; END IF;
  IF NOT public.has_programme_role(v_kpi.programme_id,
       ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'kpi actual write requires a programme write role';
  END IF;
  IF v_kpi.auto_calc THEN
    RAISE EXCEPTION 'kpi "%" is auto-calculated — manual actuals are not accepted (FR-KPI-02)', v_kpi.name;
  END IF;
  v_month := date_trunc('month', p_month)::date;      -- entries are monthly (§6.2)
  INSERT INTO public.kpi_actuals (kpi_id, month, value, evidence_id)
  VALUES (p_kpi_id, v_month, p_value, p_evidence_id)
  ON CONFLICT (kpi_id, month) DO UPDATE SET
      value       = EXCLUDED.value,
      evidence_id = EXCLUDED.evidence_id,
      entered_by  = auth.uid()
  RETURNING id INTO v_id;

  SELECT c.practice_id INTO v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_kpi.programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'kpi_actual.recorded',
          jsonb_build_object('kpi_id', p_kpi_id, 'month', v_month,
                             'value', p_value, 'note', p_note,
                             'kpi_actual_id', v_id));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.record_kpi_actual(uuid, date, numeric, text, uuid) IS
  'W1-06 FR-KPI-02: upsert a monthly KPI actual (one row per kpi+month). '
  'Rejected for auto_calc KPIs. p_note is kept in audit_log (no column on '
  'kpi_actuals).';

-- FR-KPI-03: the accountable officer (or named alternate) confirms targets the
-- template marked proposed. target_confirmed_* are write-protected columns —
-- this RPC is their only writer.
CREATE FUNCTION public.confirm_kpi_target(p_kpi_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_kpi public.kpis; v_client uuid; v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_kpi FROM public.kpis WHERE id = p_kpi_id;
  IF v_kpi IS NULL THEN RAISE EXCEPTION 'kpi not found'; END IF;
  SELECT p.client_org_id, c.practice_id INTO v_client, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_kpi.programme_id;
  IF NOT public.is_ao_or_alternate(v_client) THEN
    RAISE EXCEPTION 'only the accountable officer or named alternate may confirm a KPI target (FR-KPI-03)';
  END IF;
  IF NOT v_kpi.target_proposed THEN
    RAISE EXCEPTION 'kpi "%" target is not marked proposed', v_kpi.name;
  END IF;
  UPDATE public.kpis
     SET target_confirmed_by = auth.uid(), target_confirmed_on = now()
   WHERE id = p_kpi_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'kpi_target.confirmed',
          jsonb_build_object('kpi_id', p_kpi_id, 'target', v_kpi.target));
END $$;
COMMENT ON FUNCTION public.confirm_kpi_target(uuid) IS
  'W1-06 FR-KPI-03: AO/named-alternate confirms a proposed KPI target '
  '(sole writer of the write-protected target_confirmed_* columns).';

CREATE FUNCTION public.list_kpis(p_programme_id uuid)
RETURNS SETOF public.kpis
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT k.* FROM public.kpis k
   WHERE k.programme_id = p_programme_id
     AND p_programme_id IN (SELECT public.allowed_programmes())
   ORDER BY k.sort, k.name
$$;
COMMENT ON FUNCTION public.list_kpis(uuid) IS
  'W1-06 FR-KPI-01: the programme''s KPI set (baseline/target/unit/source).';

-- FR-KPI-04: each KPI with its latest monthly actual and a RAG vs target.
-- KPI-LOCAL RAG (swap point when W1-01 ships shared thresholds):
--   direction up   (target > baseline, or baseline unset): actual >= target →
--                  Green; actual > baseline → Amber; else Red.
--   direction down (target < baseline):                   actual <= target →
--                  Green; actual < baseline → Amber; else Red.
--   target = baseline (a ceiling metric, e.g. "reportable breaches = 0"):
--                  actual <= target → Green; else Red.
--   no target or no actual recorded → rag NULL.
CREATE FUNCTION public.kpi_status(p_programme_id uuid)
RETURNS TABLE (
    kpi_id            uuid,
    name              text,
    unit              text,
    baseline          numeric,
    target            numeric,
    target_proposed   boolean,
    target_confirmed  boolean,
    auto_calc         boolean,
    latest_month      date,
    latest_value      numeric,
    rag               text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT k.id, k.name, k.unit, k.baseline, k.target,
         k.target_proposed, (k.target_confirmed_by IS NOT NULL), k.auto_calc,
         a.month, a.value,
         CASE
           WHEN a.value IS NULL OR k.target IS NULL THEN NULL
           WHEN k.baseline IS NOT NULL AND k.target < k.baseline THEN
             CASE WHEN a.value <= k.target THEN 'Green'
                  WHEN a.value <  k.baseline THEN 'Amber'
                  ELSE 'Red' END
           WHEN k.baseline IS NOT NULL AND k.target = k.baseline THEN
             CASE WHEN a.value <= k.target THEN 'Green' ELSE 'Red' END
           ELSE
             CASE WHEN a.value >= k.target THEN 'Green'
                  WHEN k.baseline IS NOT NULL AND a.value > k.baseline THEN 'Amber'
                  ELSE 'Red' END
         END
    FROM public.kpis k
    LEFT JOIN LATERAL (
      SELECT ka.month, ka.value
        FROM public.kpi_actuals ka
       WHERE ka.kpi_id = k.id
       ORDER BY ka.month DESC
       LIMIT 1) a ON true
   WHERE k.programme_id = p_programme_id
     AND p_programme_id IN (SELECT public.allowed_programmes())
   ORDER BY k.sort, k.name
$$;
COMMENT ON FUNCTION public.kpi_status(uuid) IS
  'W1-06 FR-KPI-04: every KPI with latest monthly actual + RAG vs target '
  '(KPI-local threshold rule — swap when W1-01 ships shared RAG functions).';


-- ---- RAID items (FR-RAI-01/02) ----
CREATE FUNCTION public.create_raid_item(
    p_programme_id uuid, p_type text, p_description text,
    p_impact text DEFAULT NULL, p_action text DEFAULT NULL,
    p_owner uuid DEFAULT NULL, p_review_by date DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid; v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_type NOT IN ('risk','assumption','issue') THEN
    RAISE EXCEPTION 'invalid raid type % — expected risk|assumption|issue', p_type;
  END IF;
  IF p_description IS NULL OR btrim(p_description) = '' THEN
    RAISE EXCEPTION 'raid item requires a description';
  END IF;
  IF NOT public.has_programme_role(p_programme_id,
       ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
             'executive','accountable_officer']) THEN
    RAISE EXCEPTION 'raid write requires a programme role';
  END IF;
  INSERT INTO public.raid_items (programme_id, type, description, impact, action,
                                 owner, review_by, status, source)
  VALUES (p_programme_id, p_type, p_description, p_impact, p_action,
          p_owner, p_review_by, 'Open', 'manual')
  RETURNING id INTO v_id;

  SELECT c.practice_id INTO v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = p_programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'raid.created',
          jsonb_build_object('raid_item_id', v_id, 'programme_id', p_programme_id,
                             'type', p_type));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.create_raid_item(uuid, text, text, text, text, uuid, date) IS
  'W1-06 FR-RAI-01: raise a manual RAID item (risk|assumption|issue), Open.';

-- Patch-style update; NULL parameters leave the column unchanged. Status
-- changes flow through trg_raid_status_history automatically.
CREATE FUNCTION public.update_raid_item(
    p_raid_item_id uuid,
    p_type        text DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_impact      text DEFAULT NULL,
    p_action      text DEFAULT NULL,
    p_owner       uuid DEFAULT NULL,
    p_review_by   date DEFAULT NULL,
    p_status      text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_item public.raid_items; v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_item FROM public.raid_items WHERE id = p_raid_item_id;
  IF v_item IS NULL THEN RAISE EXCEPTION 'raid item not found'; END IF;
  IF NOT public.has_programme_role(v_item.programme_id,
       ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'raid update requires a programme write role';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('Open','In progress','Closed') THEN
    RAISE EXCEPTION 'invalid raid status %', p_status;
  END IF;
  IF p_type IS NOT NULL AND p_type NOT IN ('risk','assumption','issue') THEN
    RAISE EXCEPTION 'invalid raid type %', p_type;
  END IF;
  UPDATE public.raid_items SET
      type        = COALESCE(p_type,        type),
      description = COALESCE(p_description, description),
      impact      = COALESCE(p_impact,      impact),
      action      = COALESCE(p_action,      action),
      owner       = COALESCE(p_owner,       owner),
      review_by   = COALESCE(p_review_by,   review_by),
      status      = COALESCE(p_status,      status)
   WHERE id = p_raid_item_id;

  SELECT c.practice_id INTO v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_item.programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'raid.updated',
          jsonb_build_object('raid_item_id', p_raid_item_id,
                             'old_status', v_item.status,
                             'new_status', COALESCE(p_status, v_item.status)));
END $$;
COMMENT ON FUNCTION public.update_raid_item(uuid, text, text, text, text, uuid, date, text) IS
  'W1-06: patch a RAID item; NULL params leave columns unchanged; status '
  'transitions append to raid_status_history via trigger.';

-- Resolve = close, with an optional resolution note kept on the history row
-- and in the audit detail.
CREATE FUNCTION public.resolve_raid_item(p_raid_item_id uuid, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_item public.raid_items; v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_item FROM public.raid_items WHERE id = p_raid_item_id;
  IF v_item IS NULL THEN RAISE EXCEPTION 'raid item not found'; END IF;
  IF NOT public.has_programme_role(v_item.programme_id,
       ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'raid resolve requires a programme write role';
  END IF;
  IF v_item.status = 'Closed' THEN
    RAISE EXCEPTION 'raid item is already Closed';
  END IF;
  -- resolution note travels on the transition row via a txn-local GUC (the
  -- ledger is append-only — no UPDATE path exists, not even here)
  PERFORM set_config('securepath.raid_transition_note', COALESCE(p_note, ''), true);
  UPDATE public.raid_items SET status = 'Closed' WHERE id = p_raid_item_id;
  PERFORM set_config('securepath.raid_transition_note', '', true);

  SELECT c.practice_id INTO v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_item.programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'raid.resolved',
          jsonb_build_object('raid_item_id', p_raid_item_id,
                             'old_status', v_item.status, 'note', p_note));
END $$;
COMMENT ON FUNCTION public.resolve_raid_item(uuid, text) IS
  'W1-06: close a RAID item (status → Closed); optional resolution note is '
  'kept on the history row + audit detail.';

-- Filters mirror the list policy: status | type | owner (spec §6.2 fields;
-- there is no risk_level column — 'type' is the spec vocabulary).
CREATE FUNCTION public.list_raid_items(
    p_programme_id uuid,
    p_status text DEFAULT NULL,
    p_type   text DEFAULT NULL,
    p_owner  uuid DEFAULT NULL)
RETURNS SETOF public.raid_items
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT r.* FROM public.raid_items r
   WHERE r.programme_id = p_programme_id
     AND p_programme_id IN (SELECT public.allowed_programmes())
     AND (p_status IS NULL OR r.status = p_status)
     AND (p_type   IS NULL OR r.type   = p_type)
     AND (p_owner  IS NULL OR r.owner  = p_owner)
   ORDER BY r.raised_on DESC, r.created_at DESC
$$;
COMMENT ON FUNCTION public.list_raid_items(uuid, text, text, uuid) IS
  'W1-06 FR-RAI-01/02: RAID items for a visible programme, optionally '
  'filtered by status, type (risk|assumption|issue) and owner.';


-- ---- decisions ledger (FR-RAI-03) — append only ----
CREATE FUNCTION public.record_decision(
    p_raid_item_id uuid, p_outcome text,
    p_minute_ref text DEFAULT NULL, p_unlocks jsonb DEFAULT '[]',
    p_decided_on date DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_item public.raid_items; v_id uuid;
  v_client uuid; v_practice uuid; v_pl uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_item FROM public.raid_items WHERE id = p_raid_item_id;
  IF v_item IS NULL THEN RAISE EXCEPTION 'raid item not found'; END IF;
  IF p_outcome IS NULL OR btrim(p_outcome) = '' THEN
    RAISE EXCEPTION 'decision requires an outcome';
  END IF;
  IF NOT public.has_programme_role(v_item.programme_id,
       ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
             'executive','accountable_officer']) THEN
    RAISE EXCEPTION 'decision write requires a programme role';
  END IF;
  INSERT INTO public.decisions (raid_item_id, outcome, decided_on,
                                minute_ref, unlocks)
  VALUES (p_raid_item_id, p_outcome,
          COALESCE(p_decided_on, CURRENT_DATE), p_minute_ref,
          COALESCE(p_unlocks, '[]'::jsonb))
  RETURNING id INTO v_id;

  SELECT p.client_org_id, c.practice_id, p.programme_lead
    INTO v_client, v_practice, v_pl
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_item.programme_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'decision.recorded',
          jsonb_build_object('decision_id', v_id, 'raid_item_id', p_raid_item_id,
                             'programme_id', v_item.programme_id,
                             'minute_ref', p_minute_ref));

  -- §10 notification outbox: a recorded decision goes to the programme lead
  -- (scope carries programme + client + lead so all read paths see it).
  INSERT INTO public.notification_events (kind, scope, payload)
  VALUES ('decision_recorded',
          jsonb_build_object('programme_id', v_item.programme_id,
                             'client_org_id', v_client,
                             'user_id', v_pl),
          jsonb_build_object('decision_id', v_id,
                             'raid_item_id', p_raid_item_id,
                             'outcome', p_outcome,
                             'minute_ref', p_minute_ref,
                             'decided_by', auth.uid(),
                             'recipients', jsonb_build_array('programme_lead')));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.record_decision(uuid, text, text, jsonb, date) IS
  'W1-06 FR-RAI-03: record a decision (outcome, date, minute ref, unlocks) '
  'against its RAID item — the ledger is append-only; emits a '
  'decision_recorded notification_event for the programme lead.';

-- Decisions are child rows of RAID items; either filter is accepted (at least
-- one is required so the ledger is always read in scope).
CREATE FUNCTION public.list_decisions(
    p_programme_id uuid DEFAULT NULL,
    p_raid_item_id uuid DEFAULT NULL)
RETURNS SETOF public.decisions
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT d.* FROM public.decisions d
    JOIN public.raid_items r ON r.id = d.raid_item_id
   WHERE r.programme_id IN (SELECT public.allowed_programmes())
     AND (p_programme_id IS NULL OR r.programme_id = p_programme_id)
     AND (p_raid_item_id IS NULL OR d.raid_item_id = p_raid_item_id)
     AND (p_programme_id IS NOT NULL OR p_raid_item_id IS NOT NULL)
   ORDER BY d.decided_on DESC, d.created_at DESC
$$;
COMMENT ON FUNCTION public.list_decisions(uuid, uuid) IS
  'W1-06 FR-RAI-03: decisions ledger — by programme or by RAID item (one '
  'filter required).';


-- ---------- 6. raid_status_history RLS + grants ----------
ALTER TABLE public.raid_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.raid_status_history FORCE ROW LEVEL SECURITY;
CREATE POLICY raid_status_history_read ON public.raid_status_history
  FOR SELECT TO authenticated
  USING (raid_item_id IN (SELECT r.id FROM public.raid_items r));
REVOKE ALL ON public.raid_status_history FROM anon, authenticated;
GRANT SELECT ON public.raid_status_history TO authenticated;
-- APPEND ONLY: rows are written by trg_raid_status_history (definer) — no
-- INSERT policy; REVOKE + append-only trigger is defence in depth.
REVOKE UPDATE, DELETE ON public.raid_status_history FROM authenticated;


-- ---------- 7. lock the function surface (W0-00 convention) ----------
REVOKE EXECUTE ON FUNCTION
  public.trg_append_only(),
  public.trg_raid_status_history(),
  public.trg_mti_exception_raid(),
  public.upsert_weekly_log(uuid, int, jsonb),
  public.get_weekly_log(uuid, int),
  public.list_weekly_logs(uuid),
  public.record_kpi_actual(uuid, date, numeric, text, uuid),
  public.confirm_kpi_target(uuid),
  public.kpi_status(uuid),
  public.list_kpis(uuid),
  public.create_raid_item(uuid, text, text, text, text, uuid, date),
  public.update_raid_item(uuid, text, text, text, text, uuid, date, text),
  public.resolve_raid_item(uuid, text),
  public.list_raid_items(uuid, text, text, uuid),
  public.record_decision(uuid, text, text, jsonb, date),
  public.list_decisions(uuid, uuid)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.upsert_weekly_log(uuid, int, jsonb),
  public.get_weekly_log(uuid, int),
  public.list_weekly_logs(uuid),
  public.record_kpi_actual(uuid, date, numeric, text, uuid),
  public.confirm_kpi_target(uuid),
  public.kpi_status(uuid),
  public.list_kpis(uuid),
  public.create_raid_item(uuid, text, text, text, text, uuid, date),
  public.update_raid_item(uuid, text, text, text, text, uuid, date, text),
  public.resolve_raid_item(uuid, text),
  public.list_raid_items(uuid, text, text, uuid),
  public.record_decision(uuid, text, text, jsonb, date),
  public.list_decisions(uuid, uuid)
TO authenticated;
