-- ============================================================================
-- W1-01 — RULES ENGINE: spec SP-SPC-PLT-001 §9 (all date/week/RAG/closure
-- rules) · GitHub #15 · plan BUILD_PLAN_R1 W1-01 · deps: W0-02 programme engine
-- ============================================================================
--
-- Pure, clock-injectable functions plus the enforcement triggers. NO scheduler
-- (W1-09 owns cadence), NO screens. Every time-dependent function takes
-- p_now timestamptz DEFAULT now() so the engine can be replayed against any
-- report date (AT-10 reconciliation, snapshots, back-dated tests).
--
-- SECURITY MODEL
--   * Pure calc functions are STABLE SECURITY INVOKER — RLS decides row
--     visibility (invisible input → NULL/false), so no definer guard is
--     needed and the hard rule ("every SECURITY DEFINER guards predicates
--     in body") is honoured by not being definer at all.
--   * EXCEPTIONS — three read helpers must be SECURITY DEFINER because the
--     underlying rows are not visible to every legitimate caller:
--     jurisdiction_holidays + jurisdiction_deadline (the W0-01 pack read
--     policy covers platform roles and partner-scope partner_admins only —
--     an invoker call would see an empty calendar and silently compute
--     wrong dates; they expose only shared reference data, no tenant data),
--     and programme_jurisdiction (a programme-scope caller sees the
--     programme but not client_orgs; guarded by allowed_programmes() so
--     nothing extra leaks).
--   * Writers (recompute_*, write_monthly_snapshot, trigger functions) are
--     SECURITY DEFINER and guard in the body: a JWT caller must hold a WRITE
--     role on the scope; auth.uid() IS NULL is the service/migration/
--     scheduler path (W0-02 convention) and runs free.
--
-- DECISIONS (spec ambiguities resolved here — flagged for review):
--   1. activities.rag's CHECK is the legal RAG vocabulary (W0-02):
--      activity_rag returns 'Not due'|'Green'|'Amber'|'Red'|'Complete' —
--      the mission's "red|amber|green" is the risk subset.
--   2. §9.2 ordered rules + mission addendum: "due within ≤3 business days"
--      is an Amber rule inserted between "Status At risk" and
--      "Start date reached" (first matching rule wins). This is what the
--      W0-05 fixture already encodes (A-05 due Fri, Amber at T-3bd).
--   3. 'Deferred' handling (spec §15-#13): a deferred activity's
--      rescheduled_date REPLACES due_date for the past-due evaluation —
--      §9.2's "and not Deferred" exists because the ORIGINAL due date no
--      longer applies. Deferred is not a terminal state: a deferred
--      activity must always carry a rescheduled_date (new CHECK).
--   4. week_end() = week_start + 4 (the Friday) — the only week-ending
--      convention §9.1 names.
--   5. Reduced-capacity weeks: stored on programmes.reduced_capacity_weeks
--      int[] (W0-02 already shipped the column + grants + a '{6}' fixture).
--      is_reduced_capacity() reads it — no parallel table is created
--      (duplicated storage would drift; noted against the mission wording
--      "weeks table").
--   6. Register RAG: §9.3 defines statuses + days-overdue but no RAG value.
--      register_item_rag mirrors the §9.2 ordered rules against
--      planned_close_date (Closed→Complete, Blocked→Red, past close→
--      threshold Red/Amber, At risk→Amber, ≤3bd→Amber, started→Green,
--      else Not due).
--   7. §9.4 closure: the AO/alternate authz leg is W0-02's
--      trg_register_closure (+ W1-05's RPC). This migration adds the DATA
--      preconditions as a separate trigger on every write path (INSERT and
--      UPDATE): every linked activity Complete AND the acceptance record
--      present (accepted_on/by + non-empty accepted_evidence_refs). Data
--      invariants are not authz gates, so the service-write exemption does
--      not apply — the fixture Closed row (R-04) passes anyway.
--   8. Programme month follows §9.1 literally: calendar month of
--      (due_date − 4 days) counted from the start month as 1. (W0-05 fixture
--      A-02 seeds month=2; spec gives 1 — the engine's value wins, flagged.)
--   9. "spec §6.3" in the mission is §6.2 + §9.3 in the shipped text — the
--      status vocabularies already live in W0-02 CHECKs; this engine adds
--      the deferred→rescheduled invariant and nothing else to transitions
--      (no transition matrix exists in the spec; activity_status_history
--      already logs every change).
--  10. activity_deps cycle check: recursive walk from the new dependency
--      target, bounded at depth 100. A chain that hits the bound is
--      rejected — an unverifiable graph is not a safe graph.
--  11. §9.7 deadline resolution reads jurisdiction_packs.deadline_params
--      ONLY (FR-TPL-08): a NULL/absent period yields NULL — an unverified
--      pack produces no invented deadline. Preference order: the first
--      non-null of regulator_period_hours, response_period_hours,
--      action_period_hours, data_subject_period_hours, then
--      response_period_days, regulator_period_days, action_period_days,
--      data_subject_period_days. *_period_days honours the rule's
--      "convention" ('business_days' → pack calendar; anything else →
--      calendar days). The anchor prefers deadline_params.received_on /
--      suspected_on over reported_at.
--  12. Snapshot jsonb keys follow the W0-02 monthly_snapshots contract
--      exactly: activities_complete, activities_overdue, register_closed,
--      register_open, high_priority_closed, evidence_pending, rag,
--      kpi_actuals, maintenance_done, maintenance_overdue.
-- ============================================================================

BEGIN;

-- ---------- 0. additive schema: activities.rescheduled_date ----------
-- 'Deferred' is not a terminal state (decision 3): it must carry the date
-- the work is rescheduled to. rescheduled_date stays populated after the
-- activity leaves Deferred as an audit hint.
ALTER TABLE public.activities
  ADD COLUMN IF NOT EXISTS rescheduled_date date;
COMMENT ON COLUMN public.activities.rescheduled_date IS
  '§9.2/§15-#13: mandatory while status=Deferred — the date the work is '
  'rescheduled to. Replaces due_date in the RAG past-due evaluation.';
ALTER TABLE public.activities
  DROP CONSTRAINT IF EXISTS activities_deferred_rescheduled_chk;
ALTER TABLE public.activities
  ADD CONSTRAINT activities_deferred_rescheduled_chk
  CHECK (status <> 'Deferred' OR rescheduled_date IS NOT NULL);
GRANT INSERT (rescheduled_date) ON public.activities TO authenticated;
GRANT UPDATE (rescheduled_date) ON public.activities TO authenticated;


-- ---------- 1. §9.1 business-day primitives ----------
-- jurisdiction_packs is DEFINER-only readable for client-scope users; the
-- holiday set is shared reference data, so a small definer accessor feeds
-- the invoker arithmetic below.

CREATE OR REPLACE FUNCTION public.jurisdiction_holidays(p_jurisdiction text)
RETURNS SETOF date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (h->>'date')::date
    FROM public.jurisdiction_packs jp,
         LATERAL jsonb_array_elements(jp.public_holidays) h
   WHERE jp.code = p_jurisdiction
$$;
COMMENT ON FUNCTION public.jurisdiction_holidays(text) IS
  'W1-01: holiday dates for a jurisdiction pack. DEFINER because the W0-01 '
  'pack read policy excludes client-scope users — exposes shared reference '
  'data only (no tenant data), so no predicate guard applies.';

-- NULL/unknown jurisdiction → weekday-only rule (Mon–Fri), documented: the
-- pack supplies holidays, the Mon–Fri convention is spec-fixed.
CREATE OR REPLACE FUNCTION public.is_business_day(p_jurisdiction text, p_date date)
RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT p_date IS NOT NULL
     AND extract(isodow FROM p_date) BETWEEN 1 AND 5
     AND (p_jurisdiction IS NULL
          OR p_date NOT IN (SELECT public.jurisdiction_holidays(p_jurisdiction)))
$$;
COMMENT ON FUNCTION public.is_business_day(text, date) IS
  '§9.1: Monday–Friday excluding the jurisdiction pack''s public holidays. '
  'NULL/unknown jurisdiction → weekday-only.';

-- Signed count of business days from p_from to p_to, excluding p_from and
-- including p_to when it is a business day (negative when p_to < p_from).
CREATE OR REPLACE FUNCTION public.business_days_between(
    p_jurisdiction text, p_from date, p_to date)
RETURNS int
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE WHEN p_from IS NULL OR p_to IS NULL THEN NULL
         ELSE (SELECT (CASE WHEN p_to >= p_from THEN 1 ELSE -1 END)
                      * count(*)::int
                 FROM generate_series(
                        (LEAST(p_from, p_to) + 1)::timestamp,
                        GREATEST(p_from, p_to)::timestamp,
                        interval '1 day') d
                WHERE public.is_business_day(p_jurisdiction, d::date))
         END
$$;
COMMENT ON FUNCTION public.business_days_between(text, date, date) IS
  '§9.1: signed business-day distance (start-exclusive, end-inclusive).';

-- Add p_n business days (negative moves backwards). n=0 returns p_date.
CREATE OR REPLACE FUNCTION public.add_business_days(
    p_jurisdiction text, p_date date, p_n int)
RETURNS date
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v_d date := p_date;
  v_step int := sign(p_n)::int;
  v_left int := abs(p_n);
BEGIN
  IF p_date IS NULL OR p_n IS NULL THEN RETURN NULL; END IF;
  WHILE v_left > 0 LOOP
    v_d := v_d + v_step;
    IF public.is_business_day(p_jurisdiction, v_d) THEN
      v_left := v_left - 1;
    END IF;
  END LOOP;
  RETURN v_d;
END $$;
COMMENT ON FUNCTION public.add_business_days(text, date, int) IS
  '§9.1: p_date + p_n business days on the jurisdiction calendar (n<0 back).';

-- Nth business day of the month containing p_month (any date in it).
CREATE OR REPLACE FUNCTION public.nth_business_day(
    p_jurisdiction text, p_month date, p_n int)
RETURNS date
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT s.d::date
    FROM (SELECT generate_series(
                   date_trunc('month', p_month)::timestamp,
                   date_trunc('month', p_month)::timestamp
                     + interval '1 month - 1 day',
                   interval '1 day') d) s
   WHERE public.is_business_day(p_jurisdiction, s.d::date)
   ORDER BY s.d
  OFFSET greatest(p_n - 1, 0)
   LIMIT 1
$$;
COMMENT ON FUNCTION public.nth_business_day(text, date, int) IS
  '§9.1: the p_n-th business day of the month containing p_month.';

-- Last business day of the month containing p_month (§9.5 snapshot day).
CREATE OR REPLACE FUNCTION public.last_business_day(p_jurisdiction text, p_month date)
RETURNS date
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT max(d)::date
    FROM generate_series(date_trunc('month', p_month)::timestamp,
                         date_trunc('month', p_month)::timestamp
                           + interval '1 month - 1 day',
                         interval '1 day') d
   WHERE public.is_business_day(p_jurisdiction, d::date)
$$;
COMMENT ON FUNCTION public.last_business_day(text, date) IS
  '§9.5: last business day of the month containing p_month (snapshot day).';

-- The programme's jurisdiction (client_orgs.jurisdiction; NULL → weekday-only).
-- DEFINER + scope guard: a programme-scope caller (e.g. a workstream/
-- programme lead) can see the programmes row but NOT the client_orgs row —
-- an invoker join would silently return NULL jurisdiction. The guard returns
-- NULL unless the caller can see the programme, so nothing extra leaks.
CREATE OR REPLACE FUNCTION public.programme_jurisdiction(p_programme uuid)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL
     AND p_programme NOT IN (SELECT public.allowed_programmes()) THEN
    RETURN NULL;
  END IF;
  RETURN (SELECT co.jurisdiction
            FROM public.programmes p
            JOIN public.client_orgs co ON co.id = p.client_org_id
           WHERE p.id = p_programme);
END $$;
COMMENT ON FUNCTION public.programme_jurisdiction(uuid) IS
  'W1-01: jurisdiction pack code for a programme''s client (NULL if unset '
  'or the programme is not visible to the caller). DEFINER + scope guard — '
  'programme-scope callers cannot join client_orgs themselves.';

-- §9.1 "Report due date": the business day of the FOLLOWING month set in
-- the template — carried on programmes.report_due_business_day (POPIA: 5).
CREATE OR REPLACE FUNCTION public.report_due_date(p_programme uuid, p_month date)
RETURNS date
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT public.nth_business_day(
           public.programme_jurisdiction(p.id),
           (date_trunc('month', p_month) + interval '1 month')::date,
           p.report_due_business_day)
    FROM public.programmes p
   WHERE p.id = p_programme
$$;
COMMENT ON FUNCTION public.report_due_date(uuid, date) IS
  '§9.1: report for the period containing p_month is due on the Nth '
  'business day of the following month (programmes.report_due_business_day).';


-- ---------- 2. §9.1 week / month / phase arithmetic ----------

-- "Current programme week": whole weeks from start to report date + 1,
-- clamped into 1..total_weeks.
CREATE OR REPLACE FUNCTION public.programme_week(p_programme uuid, p_date date)
RETURNS int
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE WHEN p_date IS NULL OR p.start_date IS NULL THEN NULL
         ELSE LEAST(GREATEST(((p_date - p.start_date) / 7)::int + 1, 1),
                    p.total_weeks)
         END
    FROM public.programmes p
   WHERE p.id = p_programme
$$;
COMMENT ON FUNCTION public.programme_week(uuid, date) IS
  '§9.1: programme week containing p_date — floor((d-start)/7)+1 clamped '
  'to 1..total_weeks.';

-- Week start = programme start + (week − 1) × 7 days (Monday anchors —
-- start_date is CHECK-constrained to a Monday).
CREATE OR REPLACE FUNCTION public.week_start(p_programme uuid, p_week int)
RETURNS date
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE WHEN p_week IS NULL OR p.start_date IS NULL THEN NULL
         ELSE p.start_date + (p_week - 1) * 7
         END
    FROM public.programmes p
   WHERE p.id = p_programme
$$;
COMMENT ON FUNCTION public.week_start(uuid, int) IS
  '§9.1: Monday of programme week p_week.';

CREATE OR REPLACE FUNCTION public.week_end(p_programme uuid, p_week int)
RETURNS date
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT public.week_start(p_programme, p_week) + 4
$$;
COMMENT ON FUNCTION public.week_end(uuid, int) IS
  '§9.1: Friday of programme week p_week — the due-date anchor.';

-- The due date formula §9.1 gives both activities and findings.
CREATE OR REPLACE FUNCTION public.week_due_date(p_programme uuid, p_week int)
RETURNS date
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT public.week_end(p_programme, p_week)
$$;
COMMENT ON FUNCTION public.week_due_date(uuid, int) IS
  '§9.1: start + (week−1)×7 + 4 — Friday of the given week.';

-- §9.1 "Phase": template phase boundaries by week — materialised in the
-- W0-02 phases table. NULL when no phase row covers the week.
CREATE OR REPLACE FUNCTION public.phase_at_week(p_programme uuid, p_week int)
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT ph.name
    FROM public.phases ph
   WHERE ph.programme_id = p_programme
     AND p_week BETWEEN ph.start_week AND ph.end_week
   ORDER BY ph.number
   LIMIT 1
$$;
COMMENT ON FUNCTION public.phase_at_week(uuid, int) IS
  '§9.1: phase name covering programme week p_week (phases table).';

CREATE OR REPLACE FUNCTION public.programme_phase_at(p_programme uuid, p_date date)
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT public.phase_at_week(p_programme,
                              public.programme_week(p_programme, p_date))
$$;
COMMENT ON FUNCTION public.programme_phase_at(uuid, date) IS
  '§9.1: the programme''s phase on p_date (week → phase boundary lookup).';

-- §9.1 "Programme month of an activity": calendar month of (due − 4 days),
-- counted from the start month as 1.
CREATE OR REPLACE FUNCTION public.programme_month(p_programme uuid, p_due_date date)
RETURNS int
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE WHEN p_due_date IS NULL OR p.start_date IS NULL THEN NULL
         ELSE (extract(year FROM age(date_trunc('month', (p_due_date - 4)::date),
                                     date_trunc('month', p.start_date)))::int * 12
             + extract(month FROM age(date_trunc('month', (p_due_date - 4)::date),
                                      date_trunc('month', p.start_date)))::int
             + 1)
         END
    FROM public.programmes p
   WHERE p.id = p_programme
$$;
COMMENT ON FUNCTION public.programme_month(uuid, date) IS
  '§9.1: programme month of a due date — month of (due−4d) relative to the '
  'start month (1-based).';

CREATE OR REPLACE FUNCTION public.is_reduced_capacity(p_programme uuid, p_week int)
RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT p_week = ANY(p.reduced_capacity_weeks)
    FROM public.programmes p
   WHERE p.id = p_programme
$$;
COMMENT ON FUNCTION public.is_reduced_capacity(uuid, int) IS
  '§9.1/FR-SCH-02: is p_week a reduced-capacity week for this programme? '
  'Reads programmes.reduced_capacity_weeks (decision 5 — no parallel table).';


-- ---------- 3. §9.2 activity RAG ----------

-- Ordered rules; the first that applies sets the RAG (spec §9.2, decision 2
-- inserts the ≤3-business-day Amber rule before "start date reached").
-- Deferred evaluates against rescheduled_date (decision 3). Week-derived
-- dates are used, never the stored calc columns, so the function is correct
-- even before a recompute runs.
CREATE OR REPLACE FUNCTION public.activity_rag(p_activity uuid, p_now timestamptz DEFAULT now())
RETURNS text
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v public.activities%ROWTYPE;
  v_start date;
  v_due   date;
  v_eff_due date;
  v_red   int;
  v_jur   text;
BEGIN
  SELECT a.* INTO v FROM public.activities a WHERE a.id = p_activity;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT p.start_date, p.red_days_threshold
    INTO v_start, v_red
    FROM public.programmes p
   WHERE p.id = v.programme_id;
  v_jur := public.programme_jurisdiction(v.programme_id);

  v_due := v_start + (v.end_week - 1) * 7 + 4;              -- Friday of end week
  v_eff_due := CASE WHEN v.status = 'Deferred'
                    THEN coalesce(v.rescheduled_date, v_due)
                    ELSE v_due END;

  -- §9.2 ordered rules (first match wins)
  IF v.status = 'Complete' THEN RETURN 'Complete'; END IF;               -- 1
  IF v.status = 'Blocked'  THEN RETURN 'Red'; END IF;                    -- 2
  IF p_now::date > v_eff_due THEN                                        -- 3 past due
    RETURN CASE WHEN (p_now::date - v_eff_due) > v_red
                THEN 'Red' ELSE 'Amber' END;
  END IF;
  IF v.status = 'At risk' THEN RETURN 'Amber'; END IF;                   -- 4
  IF public.business_days_between(v_jur, p_now::date, v_eff_due) <= 3    -- 5
    THEN RETURN 'Amber'; END IF;
  IF p_now::date >= v_start + (v.start_week - 1) * 7                     -- 6
    THEN RETURN 'Green'; END IF;
  RETURN 'Not due';                                                    -- 7
END $$;
COMMENT ON FUNCTION public.activity_rag(uuid, timestamptz) IS
  '§9.2 ordered RAG. Deferred evaluates against rescheduled_date '
  '(decision 3); ≤3-business-day Amber is the mission addendum '
  '(decision 2). Returns the activities.rag CHECK vocabulary.';


-- ---------- 4. §9.3 register status + days overdue ----------

-- "report date − planned close date, never below zero, blank once Closed".
CREATE OR REPLACE FUNCTION public.register_days_overdue(
    p_item uuid, p_now timestamptz DEFAULT now())
RETURNS int
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE WHEN r.status = 'Closed' OR r.planned_close_week IS NULL THEN NULL
         ELSE greatest(0, p_now::date
                          - (p.start_date + (r.planned_close_week - 1) * 7 + 4))
         END
    FROM public.register_items r
    JOIN public.programmes p ON p.id = r.programme_id
   WHERE r.id = p_item
$$;
COMMENT ON FUNCTION public.register_days_overdue(uuid, timestamptz) IS
  '§9.3: days past planned close (Friday of planned_close_week), floored '
  'at 0, NULL once Closed.';

CREATE OR REPLACE FUNCTION public.register_item_rag(p_item uuid, p_now timestamptz DEFAULT now())
RETURNS text
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v record; v_close date;
BEGIN
  SELECT r.status, r.planned_close_week, r.programme_id, p.start_date,
         p.red_days_threshold, public.programme_jurisdiction(r.programme_id) AS jurisdiction
    INTO v
    FROM public.register_items r
    JOIN public.programmes p ON p.id = r.programme_id
   WHERE r.id = p_item;
  IF NOT FOUND THEN RETURN NULL; END IF;

  v_close := CASE WHEN v.planned_close_week IS NULL THEN NULL
                  ELSE v.start_date + (v.planned_close_week - 1) * 7 + 4 END;

  IF v.status = 'Closed'  THEN RETURN 'Complete'; END IF;
  IF v.status = 'Blocked' THEN RETURN 'Red'; END IF;
  IF v_close IS NOT NULL AND p_now::date > v_close THEN
    RETURN CASE WHEN (p_now::date - v_close) > v.red_days_threshold
                THEN 'Red' ELSE 'Amber' END;
  END IF;
  IF v.status = 'At risk' THEN RETURN 'Amber'; END IF;
  IF v_close IS NOT NULL
     AND public.business_days_between(v.jurisdiction, p_now::date, v_close) <= 3
    THEN RETURN 'Amber'; END IF;
  IF v.status IN ('In progress') THEN RETURN 'Green'; END IF;
  RETURN 'Not due';
END $$;
COMMENT ON FUNCTION public.register_item_rag(uuid, timestamptz) IS
  '§9.3/§9.2-derived register RAG (decision 6 — spec defines no register '
  'RAG; mirrors the activity ordered rules on planned_close_date).';


-- ---------- 5. §9.6 workstream / programme / partner-console RAG ----------

CREATE OR REPLACE FUNCTION public.rag_rank(p_rag text) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_rag WHEN 'Red' THEN 4 WHEN 'Amber' THEN 3 WHEN 'Green' THEN 2
                    WHEN 'Not due' THEN 1 WHEN 'Complete' THEN 0 ELSE -1 END
$$;
COMMENT ON FUNCTION public.rag_rank(text) IS
  'W1-01: severity rank for worst-of rollups (Red worst, Complete best).';

-- "the worst RAG among its started, incomplete activities; the programme
-- lead may override with a reason" (override requires rag_override_reason —
-- the W0-02 CHECK already enforces that).
CREATE OR REPLACE FUNCTION public.workstream_rag(p_workstream uuid, p_now timestamptz DEFAULT now())
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE WHEN w.rag_override IS NOT NULL THEN w.rag_override
         ELSE coalesce((SELECT it.rag
                          FROM public.activities a,
                               LATERAL (SELECT public.activity_rag(a.id, p_now) rag) it
                         WHERE a.workstream_id = w.id
                           AND a.status NOT IN ('Not started','Complete')
                         ORDER BY public.rag_rank(it.rag) DESC NULLS LAST
                         LIMIT 1), 'Green')
         END
    FROM public.workstreams w
   WHERE w.id = p_workstream
$$;
COMMENT ON FUNCTION public.workstream_rag(uuid, timestamptz) IS
  '§9.6: override wins, else worst RAG among started, incomplete '
  'activities; an all-quiet workstream is Green.';

-- "Programme RAG … the platform suggests the worst workstream RAG" — plus
-- programme-scope activities that have no workstream (they belong to no
-- workstream''s worst-of). Workstream overrides count (the override IS the
-- workstream''s RAG).
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
                          AND a.status NOT IN ('Not started','Complete')
                   ) it
                   ORDER BY public.rag_rank(it.rag) DESC NULLS LAST
                   LIMIT 1), 'Green')
$$;
COMMENT ON FUNCTION public.programme_rag_suggested(uuid, timestamptz) IS
  '§9.6: suggested programme RAG — worst workstream RAG plus unworkstreamed '
  'started, incomplete activities.';

-- The effective programme RAG: the lead''s monthly value wins (§9.6),
-- the suggestion fills the gap.
CREATE OR REPLACE FUNCTION public.programme_rag(p_programme uuid, p_now timestamptz DEFAULT now())
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT coalesce(p.programme_rag,
                  public.programme_rag_suggested(p.id, p_now))
    FROM public.programmes p
   WHERE p.id = p_programme
$$;
COMMENT ON FUNCTION public.programme_rag(uuid, timestamptz) IS
  '§9.6: stored programme_rag (set monthly by the lead) else the worst-'
  'workstream suggestion.';

-- "the programme RAG, shown Red regardless if the monthly report is late
-- or a maintenance task feeding it is overdue."
CREATE OR REPLACE FUNCTION public.partner_console_rag(
    p_programme uuid, p_now timestamptz DEFAULT now())
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE
           WHEN EXISTS (SELECT 1 FROM public.programme_reports r
                         WHERE r.programme_id = p_programme
                           AND r.status <> 'issued'
                           AND coalesce(r.due_on,
                                        public.report_due_date(p_programme,
                                          (r.period || '-01')::date))
                               < p_now::date)
             OR EXISTS (SELECT 1
                          FROM public.maintenance_task_instances mti
                          JOIN public.maintenance_task_templates t
                            ON t.id = mti.task_template_id
                         WHERE t.programme_id = p_programme
                           AND t.feeds ILIKE '%report%'
                           AND mti.due_date IS NOT NULL
                           AND mti.due_date < p_now::date
                           AND mti.status <> 'Complete')
           THEN 'Red'
           ELSE public.programme_rag(p_programme, p_now)
         END
$$;
COMMENT ON FUNCTION public.partner_console_rag(uuid, timestamptz) IS
  '§9.6: programme RAG forced Red when a monthly report is past due '
  'unissued, or a report-feeding maintenance task is overdue.';


-- ---------- 6. §9.4 register closure ----------

-- Pre-flight check used by RPCs and screens. Returns the blocking reason
-- (or 'ok'). The authz leg (AO / named alternate) is deliberately NOT here —
-- W0-02's trg_register_closure and W1-05's close RPC own it.
CREATE OR REPLACE FUNCTION public.can_close_register_item(p_item uuid)
RETURNS TABLE(can_close boolean, reason text)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v record; v_n int; v_refs text;
BEGIN
  SELECT r.status, r.accepted_on, r.accepted_by, r.accepted_evidence_refs
    INTO v FROM public.register_items r WHERE r.id = p_item;
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'register item not found'; RETURN;
  END IF;

  SELECT count(*), string_agg(a.ref, ', ' ORDER BY a.ref)
    INTO v_n, v_refs
    FROM public.register_item_activities ria
    JOIN public.activities a ON a.id = ria.activity_id
   WHERE ria.register_item_id = p_item
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

  RETURN QUERY SELECT true, 'ok';
END $$;
COMMENT ON FUNCTION public.can_close_register_item(uuid) IS
  '§9.4 data preconditions for closing a finding: every linked activity '
  'Complete AND the acceptance record present. Authz (AO/alternate) is '
  'checked separately by trg_register_closure / the W1-05 RPC.';

-- The enforcement half: fires on EVERY write path (INSERT and UPDATE) —
-- a data invariant, not an authz gate (decision 7). Uses NEW's own fields
-- for the acceptance record so a single write carrying both the record
-- and the status passes atomically.
CREATE OR REPLACE FUNCTION public.trg_register_closure_data() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int; v_refs text;
BEGIN
  IF NEW.status = 'Closed'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'Closed') THEN
    SELECT count(*), string_agg(a.ref, ', ' ORDER BY a.ref)
      INTO v_n, v_refs
      FROM public.register_item_activities ria
      JOIN public.activities a ON a.id = ria.activity_id
     WHERE ria.register_item_id = NEW.id
       AND a.status <> 'Complete';
    IF v_n > 0 THEN
      RAISE EXCEPTION
        'cannot close register item: % linked activit% not Complete (%) (§9.4)',
        v_n, CASE WHEN v_n = 1 THEN 'y is' ELSE 'ies are' END, v_refs;
    END IF;
    IF NEW.accepted_on IS NULL OR NEW.accepted_by IS NULL
       OR NEW.accepted_evidence_refs IS NULL
       OR array_length(NEW.accepted_evidence_refs, 1) IS NULL THEN
      RAISE EXCEPTION
        'cannot close register item: evidence acceptance record incomplete (§9.4)';
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_register_closure_data() IS
  '§9.4 data precondition gate — complements W0-02 trg_register_closure '
  '(AO/alternate authz). Runs on insert and update on every write path.';

DROP TRIGGER IF EXISTS register_closure_data_gate ON public.register_items;
CREATE TRIGGER register_closure_data_gate
BEFORE INSERT OR UPDATE ON public.register_items
FOR EACH ROW EXECUTE FUNCTION public.trg_register_closure_data();


-- ---------- 7. activity_deps cycle check ----------

CREATE OR REPLACE FUNCTION public.trg_activity_dep_cycle() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- does the new "depends on" target already reach the activity? Then the
  -- edge closes a cycle. Bounded recursive walk (decision 10).
  IF EXISTS (
    WITH RECURSIVE reach AS (
      SELECT d.depends_on_activity_id AS node, 1 AS depth
        FROM public.activity_deps d
       WHERE d.activity_id = NEW.depends_on_activity_id
      UNION
      SELECT d.depends_on_activity_id, r.depth + 1
        FROM public.activity_deps d
        JOIN reach r ON d.activity_id = r.node
       WHERE r.depth < 100
    )
    SELECT 1 FROM reach WHERE node = NEW.activity_id
    LIMIT 1) THEN
    RAISE EXCEPTION
      'activity dependency rejected: would create a cycle (% ↔ %)',
      NEW.activity_id, NEW.depends_on_activity_id;
  END IF;
  -- hitting the walk bound means the graph is unverifiable → not safe
  IF EXISTS (
    WITH RECURSIVE reach AS (
      SELECT d.depends_on_activity_id AS node, 1 AS depth
        FROM public.activity_deps d
       WHERE d.activity_id = NEW.depends_on_activity_id
      UNION
      SELECT d.depends_on_activity_id, r.depth + 1
        FROM public.activity_deps d
        JOIN reach r ON d.activity_id = r.node
       WHERE r.depth < 100
    )
    SELECT 1 FROM reach WHERE depth = 100
    LIMIT 1) THEN
    RAISE EXCEPTION
      'activity dependency rejected: graph deeper than 100 — cycle unverifiable';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_activity_dep_cycle() IS
  'W1-01: rejects activity_deps rows that close a dependency cycle '
  '(recursive walk bounded at depth 100 — hitting the bound rejects too).';

DROP TRIGGER IF EXISTS activity_dep_cycle_check ON public.activity_deps;
CREATE TRIGGER activity_dep_cycle_check
BEFORE INSERT OR UPDATE ON public.activity_deps
FOR EACH ROW EXECUTE FUNCTION public.trg_activity_dep_cycle();


-- ---------- 8. §9.7 jurisdiction deadline resolution ----------

-- DEFINER for the pack read (see security model). NULL period → NULL due
-- date — an unverified pack must never produce an invented deadline.
CREATE OR REPLACE FUNCTION public.jurisdiction_deadline(
    p_jurisdiction text, p_rule text, p_anchor timestamptz)
RETURNS date
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rules jsonb;
  v_hours int; v_days int; v_conv text;
BEGIN
  IF p_jurisdiction IS NULL OR p_rule IS NULL OR p_anchor IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT jp.deadline_params -> p_rule
    INTO v_rules
    FROM public.jurisdiction_packs jp
   WHERE jp.code = p_jurisdiction;
  IF v_rules IS NULL THEN RETURN NULL; END IF;

  -- first non-null *_period_hours wins (the tightest clock)
  SELECT (v_rules ->> k.key)::int INTO v_hours
    FROM (VALUES (1,'regulator_period_hours'),(2,'response_period_hours'),
                 (3,'action_period_hours'),(4,'data_subject_period_hours')) AS k(ord,key)
   WHERE (v_rules ->> k.key) IS NOT NULL
   ORDER BY k.ord
   LIMIT 1;
  IF v_hours IS NOT NULL THEN
    RETURN (p_anchor + make_interval(hours => v_hours))::date;
  END IF;

  SELECT (v_rules ->> k.key)::int INTO v_days
    FROM (VALUES (1,'response_period_days'),(2,'regulator_period_days'),
                 (3,'action_period_days'),(4,'data_subject_period_days')) AS k(ord,key)
   WHERE (v_rules ->> k.key) IS NOT NULL
   ORDER BY k.ord
   LIMIT 1;
  IF v_days IS NULL THEN RETURN NULL; END IF;

  v_conv := v_rules ->> 'convention';
  IF v_conv = 'business_days' THEN
    RETURN public.add_business_days(p_jurisdiction, p_anchor::date, v_days);
  END IF;
  RETURN (p_anchor::date + v_days);
END $$;
COMMENT ON FUNCTION public.jurisdiction_deadline(text, text, timestamptz) IS
  '§9.7/FR-TPL-08: resolve a named deadline rule from jurisdiction_packs.'
  'deadline_params — never a hard-coded period. Key preference and '
  'convention handling documented as decision 11. DEFINER for the pack '
  'read (reference data only).';

-- The due date for one operational_records row (§9.7). Anchor prefers the
-- record's own deadline_params dates over reported_at (decision 11).
CREATE OR REPLACE FUNCTION public.operational_due_date(p_record uuid)
RETURNS date
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT public.jurisdiction_deadline(
           co.jurisdiction, r.deadline_rule,
           coalesce((r.deadline_params->>'received_on')::timestamptz,
                    (r.deadline_params->>'suspected_on')::timestamptz,
                    r.reported_at))
    FROM public.operational_records r
    JOIN public.client_orgs co ON co.id = r.client_org_id
   WHERE r.id = p_record
$$;
COMMENT ON FUNCTION public.operational_due_date(uuid) IS
  '§9.7: the CALC value for operational_records.due_date — resolved from '
  'the client''s jurisdiction pack via deadline_rule + deadline_params.';

-- engine-owned calc: fill due_date on every write path (deadline_rule NULL
-- → NULL). Runs as definer so the pack read works under any caller.
CREATE OR REPLACE FUNCTION public.trg_oprecord_due_date() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.deadline_rule IS NULL THEN
    NEW.due_date := NULL;
  ELSE
    NEW.due_date := public.operational_due_date_for_row(
                      NEW.client_org_id, NEW.deadline_rule,
                      NEW.deadline_params, NEW.reported_at);
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_oprecord_due_date() IS
  '§9.7: engine writes operational_records.due_date on insert/update.';

CREATE OR REPLACE FUNCTION public.operational_due_date_for_row(
    p_client_org uuid, p_rule text, p_params jsonb, p_reported timestamptz)
RETURNS date
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT public.jurisdiction_deadline(
           co.jurisdiction, p_rule,
           coalesce((p_params->>'received_on')::timestamptz,
                    (p_params->>'suspected_on')::timestamptz,
                    p_reported))
    FROM public.client_orgs co
   WHERE co.id = p_client_org
$$;
COMMENT ON FUNCTION public.operational_due_date_for_row(uuid, text, jsonb, timestamptz) IS
  '§9.7: field-level variant of operational_due_date for the write trigger.';

DROP TRIGGER IF EXISTS oprecord_due_date_calc ON public.operational_records;
CREATE TRIGGER oprecord_due_date_calc
BEFORE INSERT OR UPDATE OF deadline_rule, deadline_params, reported_at
ON public.operational_records
FOR EACH ROW EXECUTE FUNCTION public.trg_oprecord_due_date();


-- ---------- 9. recompute engine (writes the CALC columns) ----------
-- DEFINER because the calc columns carry no client grant. Guard per the
-- hard rule: JWT callers need a WRITE role on the programme; the service/
-- scheduler path (auth.uid() NULL) runs free.

-- Recompute every activity's start_date, due_date, month, phase and rag.
-- The "dependency cascade": activities are processed in topological order
-- over activity_deps so the whole graph settles in one pass. Spec §9.1's
-- formulas derive only from the programme start + week numbers, so order
-- does not change values — auto-shifting slipped dependents is W1-05's
-- FR-SCH-06 call, not the rules engine's.
CREATE OR REPLACE FUNCTION public.recompute_activity_due(
    p_programme uuid, p_now timestamptz DEFAULT now())
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_start date; v_done int := 0; v_row record;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT public.has_programme_role(p_programme,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'recompute_activity_due: no write role on programme %', p_programme;
  END IF;
  SELECT start_date INTO v_start FROM public.programmes WHERE id = p_programme;
  IF NOT FOUND THEN RAISE EXCEPTION 'programme % not found', p_programme; END IF;

  -- topological order over the dependency DAG, bounded at 100 deep
  FOR v_row IN
    WITH RECURSIVE topo AS (
      SELECT a.id, 0 AS depth
        FROM public.activities a
       WHERE a.programme_id = p_programme
         AND NOT EXISTS (SELECT 1 FROM public.activity_deps d
                          WHERE d.activity_id = a.id)
      UNION
      SELECT d.activity_id, t.depth + 1
        FROM public.activity_deps d
        JOIN topo t ON d.depends_on_activity_id = t.id
       WHERE t.depth < 100
    )
    SELECT id, depth FROM topo ORDER BY depth, id
  LOOP
    UPDATE public.activities a
       SET start_date = v_start + (a.start_week - 1) * 7,
           due_date   = v_start + (a.end_week   - 1) * 7 + 4,
           month      = public.programme_month(a.programme_id,
                          v_start + (a.end_week - 1) * 7 + 4),
           phase      = public.phase_at_week(a.programme_id, a.end_week),
           rag        = public.activity_rag(a.id, p_now)
     WHERE a.id = v_row.id;
    v_done := v_done + 1;
  END LOOP;
  RETURN v_done;
END $$;
COMMENT ON FUNCTION public.recompute_activity_due(uuid, timestamptz) IS
  'W1-01: writes every activity''s §9.1/§9.2 CALC columns in dependency '
  '(topological) order. Caller never supplies the values — the engine '
  'computes them.';

-- Programme-level recompute: activities, then register planned_close_date
-- + days_overdue, then the programme's own phase (decision: the only CALC
-- on programmes itself).
CREATE OR REPLACE FUNCTION public.recompute_programme_progress(
    p_programme uuid, p_now timestamptz DEFAULT now())
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_start date;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT public.has_programme_role(p_programme,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'recompute_programme_progress: no write role on programme %', p_programme;
  END IF;
  SELECT start_date INTO v_start FROM public.programmes WHERE id = p_programme;
  IF NOT FOUND THEN RAISE EXCEPTION 'programme % not found', p_programme; END IF;

  PERFORM public.recompute_activity_due(p_programme, p_now);

  UPDATE public.register_items r
     SET planned_close_date = CASE WHEN r.planned_close_week IS NULL THEN NULL
              ELSE v_start + (r.planned_close_week - 1) * 7 + 4 END,
         days_overdue = CASE WHEN r.status = 'Closed' OR r.planned_close_week IS NULL
              THEN NULL
              ELSE greatest(0, p_now::date
                            - (v_start + (r.planned_close_week - 1) * 7 + 4))
              END
   WHERE r.programme_id = p_programme;

  UPDATE public.programmes
     SET phase = public.programme_phase_at(p_programme, p_now::date)
   WHERE id = p_programme;
END $$;
COMMENT ON FUNCTION public.recompute_programme_progress(uuid, timestamptz) IS
  'W1-01: recomputes the programme''s CALC columns — activity dates/RAG, '
  'register planned_close_date + days_overdue, programmes.phase.';


-- ---------- 10. §9.5 monthly snapshot writer ----------

-- The snapshot figures for one programme month (jsonb contract: decision 12).
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
        WHERE a.programme_id = p_programme AND a.status = 'Complete'),
    'activities_overdue',
      (SELECT count(*) FROM public.activities a
        WHERE a.programme_id = p_programme AND a.status <> 'Complete'
          AND CASE WHEN a.status = 'Deferred' AND a.rescheduled_date IS NOT NULL
                   THEN a.rescheduled_date
                   ELSE (SELECT p.start_date FROM public.programmes p
                          WHERE p.id = p_programme)
                        + (a.end_week - 1) * 7 + 4
              END < p_now::date),
    'register_closed',
      (SELECT count(*) FROM public.register_items r
        WHERE r.programme_id = p_programme AND r.status = 'Closed'),
    'register_open',
      (SELECT count(*) FROM public.register_items r
        WHERE r.programme_id = p_programme AND r.status <> 'Closed'),
    'high_priority_closed',
      (SELECT count(*) FROM public.register_items r
        WHERE r.programme_id = p_programme AND r.status = 'Closed'
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
COMMENT ON FUNCTION public.monthly_snapshot_figures(uuid, date, timestamptz) IS
  '§9.5: the fixed-key snapshot jsonb for one programme month. Written by '
  'write_monthly_snapshot on the last business day (W1-09''s job).';

-- Writes one snapshot row — append-only (a second call for the same period
-- is rejected; §9.5 snapshots are the frozen basis of issued reports).
CREATE OR REPLACE FUNCTION public.write_monthly_snapshot(
    p_programme uuid, p_month date, p_now timestamptz DEFAULT now())
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_period text;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT public.has_programme_role(p_programme,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'write_monthly_snapshot: no write role on programme %', p_programme;
  END IF;
  v_period := to_char(date_trunc('month', p_month), 'YYYY-MM');
  INSERT INTO public.monthly_snapshots (programme_id, period, snapshot, taken_at)
  VALUES (p_programme, v_period,
          public.monthly_snapshot_figures(p_programme, p_month, p_now), p_now)
  RETURNING id INTO v_id;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'monthly snapshot for programme % period % already exists (§9.5)',
    p_programme, v_period;
END $$;
COMMENT ON FUNCTION public.write_monthly_snapshot(uuid, date, timestamptz) IS
  '§9.5: append-only snapshot writer — one row per programme month, '
  'recomputed figures only (callers never supply values).';


-- ---------- 11. §9.8 licence counting (pure — W1-07 consumes) ----------

-- "A programme counts from creation until it is closed. A client counts
-- while it has at least one programme that is not closed."
CREATE OR REPLACE FUNCTION public.partner_licence_usage(
    p_partner uuid, p_now timestamptz DEFAULT now())
RETURNS TABLE(programmes_used int, clients_used int,
              client_limit int, programme_limit int,
              over_client_limit boolean, over_programme_limit boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_lic record;
BEGIN
  -- guard (hard rule): the caller must see this partner's data
  IF auth.uid() IS NOT NULL
     AND NOT public.has_partner_role(p_partner,
        ARRAY['partner_admin','partner_consultant','read_only'])
     AND NOT public.is_platform_role(ARRAY['platform_admin','support']) THEN
    RAISE EXCEPTION 'partner_licence_usage: no role on partner %', p_partner;
  END IF;

  SELECT l.client_limit, l.programme_limit INTO v_lic
    FROM public.licences l
   WHERE l.partner_id = p_partner AND l.status = 'active'
     AND l.starts_on <= p_now::date
     AND (l.ends_on IS NULL OR l.ends_on > p_now::date)
   ORDER BY l.starts_on DESC
   LIMIT 1;

  RETURN QUERY
    WITH prog AS (
      SELECT p.id, p.client_org_id
        FROM public.programmes p
        JOIN public.client_orgs co ON co.id = p.client_org_id
       WHERE co.practice_id = p_partner AND p.status <> 'closed'
    )
    SELECT (SELECT count(*) FROM prog)::int,
           (SELECT count(DISTINCT client_org_id) FROM prog)::int,
           v_lic.client_limit, v_lic.programme_limit,
           (v_lic.client_limit IS NOT NULL
              AND (SELECT count(DISTINCT client_org_id) FROM prog) > v_lic.client_limit),
           (v_lic.programme_limit IS NOT NULL
              AND (SELECT count(*) FROM prog) > v_lic.programme_limit);
END $$;
COMMENT ON FUNCTION public.partner_licence_usage(uuid, timestamptz) IS
  '§9.8: licence usage — non-closed programmes and clients carrying them, '
  'vs the active licence''s limits. W1-07 consumes for the onboarding '
  'block + usage reports.';


-- ---------- 12. grants ----------
REVOKE EXECUTE ON FUNCTION
  public.jurisdiction_holidays(text),
  public.is_business_day(text, date),
  public.business_days_between(text, date, date),
  public.add_business_days(text, date, int),
  public.nth_business_day(text, date, int),
  public.last_business_day(text, date),
  public.programme_jurisdiction(uuid),
  public.report_due_date(uuid, date),
  public.programme_week(uuid, date),
  public.week_start(uuid, int),
  public.week_end(uuid, int),
  public.week_due_date(uuid, int),
  public.phase_at_week(uuid, int),
  public.programme_phase_at(uuid, date),
  public.programme_month(uuid, date),
  public.is_reduced_capacity(uuid, int),
  public.activity_rag(uuid, timestamptz),
  public.register_days_overdue(uuid, timestamptz),
  public.register_item_rag(uuid, timestamptz),
  public.rag_rank(text),
  public.workstream_rag(uuid, timestamptz),
  public.programme_rag_suggested(uuid, timestamptz),
  public.programme_rag(uuid, timestamptz),
  public.partner_console_rag(uuid, timestamptz),
  public.can_close_register_item(uuid),
  public.jurisdiction_deadline(text, text, timestamptz),
  public.operational_due_date(uuid),
  public.operational_due_date_for_row(uuid, text, jsonb, timestamptz),
  public.recompute_activity_due(uuid, timestamptz),
  public.recompute_programme_progress(uuid, timestamptz),
  public.monthly_snapshot_figures(uuid, date, timestamptz),
  public.write_monthly_snapshot(uuid, date, timestamptz),
  public.partner_licence_usage(uuid, timestamptz),
  public.trg_register_closure_data(),
  public.trg_activity_dep_cycle(),
  public.trg_oprecord_due_date()
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.jurisdiction_holidays(text),
  public.is_business_day(text, date),
  public.business_days_between(text, date, date),
  public.add_business_days(text, date, int),
  public.nth_business_day(text, date, int),
  public.last_business_day(text, date),
  public.programme_jurisdiction(uuid),
  public.report_due_date(uuid, date),
  public.programme_week(uuid, date),
  public.week_start(uuid, int),
  public.week_end(uuid, int),
  public.week_due_date(uuid, int),
  public.phase_at_week(uuid, int),
  public.programme_phase_at(uuid, date),
  public.programme_month(uuid, date),
  public.is_reduced_capacity(uuid, int),
  public.activity_rag(uuid, timestamptz),
  public.register_days_overdue(uuid, timestamptz),
  public.register_item_rag(uuid, timestamptz),
  public.rag_rank(text),
  public.workstream_rag(uuid, timestamptz),
  public.programme_rag_suggested(uuid, timestamptz),
  public.programme_rag(uuid, timestamptz),
  public.partner_console_rag(uuid, timestamptz),
  public.can_close_register_item(uuid),
  public.jurisdiction_deadline(text, text, timestamptz),
  public.operational_due_date(uuid),
  public.operational_due_date_for_row(uuid, text, jsonb, timestamptz),
  public.recompute_activity_due(uuid, timestamptz),
  public.recompute_programme_progress(uuid, timestamptz),
  public.monthly_snapshot_figures(uuid, date, timestamptz),
  public.partner_licence_usage(uuid, timestamptz)
TO authenticated;
-- write_monthly_snapshot is deliberately NOT granted to authenticated —
-- only the scheduler/service path and the migration owner mint snapshots.

COMMIT;
