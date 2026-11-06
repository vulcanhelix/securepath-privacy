-- ============================================================================
-- W1-09 — SCHEDULER RUNNER: job lease/claim, completion, clock-injectable
--         tick(), per-client-timezone due resolution and bounded catch-up
-- (GitHub #23 · spec SP-SPC-PLT-001 §9.3/§9.5/§10/§12 · plan BUILD_PLAN_R1 W1-09)
-- ============================================================================
--
-- WHAT THIS BUILDS
--   * scheduled_jobs registry upgrade: machine-readable schedule_rule,
--     timezone_scope, handler_fn dispatch key, next_run_at, lease_seconds.
--   * job_runs idempotency key: (job_key, scope_key, period_started_at) UNIQUE
--     plus a per-run lease (locked_until). One ledger row per job×scope×
--     period — the append-only contract stays.
--   * claim_job(job, now)     — claims every (scope, period) currently due for
--                               a job; returns the new job_runs ids ('running').
--                               Same job+period = no-op (the UNIQUE key).
--   * complete_job(run,...)   — finishes a 'running' ledger row and releases
--                               its lease. Returns false on already-finished.
--   * tick(now)               — the sweep: for every enabled job, for every
--                               scope, for every due instant inside the
--                               catch-up window: claim → dispatch → complete.
--                               Older un-run instants get a 'skipped' ledger
--                               row (bounded: one extra window, see below).
--
-- SCOPE + TIMEZONE MODEL (spec §10: "each job runs in the client's time zone")
--   timezone_scope = 'client'   → one run per client_org; tz resolution:
--                                 client_orgs.timezone → client's jurisdiction
--                                 pack timezone → 'UTC'.
--                   'partner'   → one run per practice; tz via practices.country
--                                 → jurisdiction_packs.timezone → 'UTC'.
--                   'platform'  → a single run, scope_key '', evaluated in UTC.
--   Due instants are LOCAL wall times (e.g. 06:00 Africa/Johannesburg) stored
--   as the timestamptz they map to. A client's job therefore never fires on a
--   UTC-derived clock edge: 06:00 SAST fires at 04:00Z, 06:00 BST at 05:00Z.
--   scope_key = 'client:<uuid>' | 'partner:<uuid>' | '' — the idempotency key
--   needs it: two same-tz clients share the same due instant and must each
--   get their own ledger row.
--
-- CATCH-UP + LEASE SEMANTICS (documented decisions)
--   * CATCH_UP_WINDOW = 48h — comment-anchored constant in
--     sched_catchup_window() (ops tunable by editing that one function; a
--     settings-table row can replace it later without touching callers).
--     A due instant inside (now − 48h, now] with no ledger row fires once.
--     An instant 48–96h old gets a job_runs row with status 'skipped'
--     (reason recorded). Anything older is not enumerated at all — the first
--     tick on a long-quiet database does not flood the ledger.
--   * Delivery is AT-LEAST-ONCE with idempotent handlers: a run left
--     'running' past its lease is ADOPTED (detail.adopted_at stamped) and its
--     handler re-driven on the next tick — never a second ledger row. All
--     shipped handlers are re-entrant (ON CONFLICT / IS DISTINCT FROM).
--   * tick() takes a per-job pg_try_advisory_xact_lock so overlapping tickers
--     (cron + manual) cannot double-dispatch the same job.
--   * Backfill beyond the window: call claim_job(job, p_now) with p_now inside
--     the missed period — due resolution is clock-injectable end to end.
--
-- FIRING MECHANISM — pg_cron, no compose change needed.
--   The staging image (supabase/postgres:15.8.1.049) already loads pg_cron in
--   shared_preload_libraries (verified: pg_stat_statements, pgaudit, plpgsql,
--   plpgsql_check, pg_cron, pg_net, pgsodium, timescaledb, auto_explain,
--   pg_tle, plan_filter — pg_cron 1.6). The guarded block at the foot of this
--   file does CREATE EXTENSION pg_cron + registers cron job 'securepath-tick'
--   running `SELECT public.tick()` every minute in the postgres database
--   (pg_cron's default cron.database_name). On any database where pg_cron is
--   NOT preloaded the block NOTICEs and skips — the documented fallback is
--   staging/jobs-tick.sh driven by the systemd timer units shipped alongside
--   it (staging/jobs-tick.service + staging/jobs-tick.timer), which call the
--   same tick(). tick() itself is driver-agnostic.
--
-- HANDLER DISPATCH — CASE on scheduled_jobs.handler_fn inside
-- sched_run_handler(). Implemented for real where the work is pure DB:
--   daily_recalc_digest → sched_daily_sweep: §9.3 days_overdue recompute,
--                         §9.2 activity-RAG recompute, §10 trigger events into
--                         notification_events (activity_due / activity_due_soon
--                         / activity_starting / maintenance_input_overdue /
--                         monthly_report_late, each deduped once-per-entity).
--   monthly_snapshot    → sched_take_monthly_snapshot per programme (§9.5,
--                         append-only UNIQUE(programme_id, period)).
-- Stubs (RAISE NOTICE + run detail.stub; the ledger row still records the
-- firing so owners can backfill on landing):
--   monthly_maintenance_gen → W1-03 cadence engine (task gen + draft report)
--   checklist_gen           → W1-03 quarterly/annual checklist generation
--   weekly_agenda           → W2-07 agenda build / W1-08 agenda mail (FR-WKS-05)
--   partner_usage_report    → W2-17 partner licence usage (FR-LIC-02)
--   digest send inside the daily job → W1-08 notification dispatcher
--   phase/current-week recalc inside the daily job → W1-01 §9 rules engine
--     (the activity-RAG recompute here is the same deterministic §9.2 rule;
--     when W1-01 lands its engine function this sweep should call that instead)
--
-- ============================================================================

-- ---------- 1. registry + ledger upgrades ----------

ALTER TABLE public.scheduled_jobs
  ADD COLUMN IF NOT EXISTS timezone_scope text NOT NULL DEFAULT 'client'
    CHECK (timezone_scope IN ('client','partner','platform')),
  ADD COLUMN IF NOT EXISTS schedule_rule jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS handler_fn text,
  ADD COLUMN IF NOT EXISTS next_run_at timestamptz,   -- informational: earliest due instant across scopes (UTC)
  ADD COLUMN IF NOT EXISTS last_tick_at timestamptz,
  ADD COLUMN IF NOT EXISTS lease_seconds int NOT NULL DEFAULT 600 CHECK (lease_seconds > 0);

COMMENT ON COLUMN public.scheduled_jobs.timezone_scope IS
  'W1-09: client = one run per client org evaluated in its tz; partner = one '
  'run per practice (tz via country → pack); platform = single UTC run.';
COMMENT ON COLUMN public.scheduled_jobs.schedule_rule IS
  'W1-09 machine-readable schedule: {"kind":"daily","time":"06:00"} | '
  '{"kind":"weekly","dow":1,"time":"06:00"} | {"kind":"monthly_business_day",'
  '"position":"first|last","time":"HH:MM"} | {"kind":"cycle_dates","time":"HH:MM"} '
  '(first BD of quarter + programme anniversaries).';
COMMENT ON COLUMN public.scheduled_jobs.handler_fn IS
  'W1-09 dispatch key — CASE label inside sched_run_handler().';
COMMENT ON COLUMN public.scheduled_jobs.next_run_at IS
  'W1-09 informational: earliest due instant > last tick across scopes (UTC).';

ALTER TABLE public.job_runs
  ADD COLUMN IF NOT EXISTS scope_key         text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS period_started_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS locked_until      timestamptz;      -- lease while 'running'

COMMENT ON COLUMN public.job_runs.scope_key IS
  'W1-09: execution scope — ''client:<uuid>'' | ''partner:<uuid>'' | '''' (platform).';
COMMENT ON COLUMN public.job_runs.period_started_at IS
  'W1-09: the scheduled instant (UTC instant of the local wall time, e.g. '
  '06:00 client-tz). Idempotency key with job_key + scope_key.';
COMMENT ON COLUMN public.job_runs.locked_until IS
  'W1-09 lease: while ''running'' and locked_until > now the run is in-flight; '
  'an expired lease lets a later claim adopt and re-drive the idempotent handler.';

-- idempotency: one ledger row per job × scope × scheduled instant
CREATE UNIQUE INDEX IF NOT EXISTS job_runs_idem_idx
  ON public.job_runs (job_key, scope_key, period_started_at);

-- ---------- 2. registry content: machine rules + handlers for the §10 seeds --

UPDATE public.scheduled_jobs SET
    schedule_rule  = '{"kind":"daily","time":"06:00"}'::jsonb,
    timezone_scope = 'client',
    handler_fn     = 'daily_recalc_digest'
  WHERE key = 'daily-recalc-digest';
UPDATE public.scheduled_jobs SET
    schedule_rule  = '{"kind":"monthly_business_day","position":"first","time":"06:00"}'::jsonb,
    timezone_scope = 'client',
    handler_fn     = 'monthly_maintenance_gen'
  WHERE key = 'monthly-bd1-gen';
UPDATE public.scheduled_jobs SET
    schedule_rule  = '{"kind":"monthly_business_day","position":"last","time":"18:00"}'::jsonb,
    timezone_scope = 'client',
    handler_fn     = 'monthly_snapshot'
  WHERE key = 'monthly-last-bd-snapshot';
UPDATE public.scheduled_jobs SET
    schedule_rule  = '{"kind":"weekly","dow":1,"time":"06:00"}'::jsonb,
    timezone_scope = 'client',
    handler_fn     = 'weekly_agenda'
  WHERE key = 'monday-agenda';
UPDATE public.scheduled_jobs SET
    schedule_rule  = '{"kind":"cycle_dates","time":"06:00"}'::jsonb,
    timezone_scope = 'client',
    handler_fn     = 'checklist_gen'
  WHERE key = 'quarterly-annual-checklists';
UPDATE public.scheduled_jobs SET
    schedule_rule  = '{"kind":"monthly_business_day","position":"first","time":"06:00"}'::jsonb,
    timezone_scope = 'partner',
    handler_fn     = 'partner_usage_report'
  WHERE key = 'partner-usage-report';

-- ---------- 3. helpers ----------

-- definer guard (hard rule): scheduler RPCs are service-context or
-- platform-ops only. A tenant JWT must never be able to claim/complete/tick.
CREATE FUNCTION public.sched_assert_ops() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT public.is_platform_role(ARRAY['platform_admin','support']) THEN
    RAISE EXCEPTION 'scheduler RPCs are platform-ops only';
  END IF;
END $$;
COMMENT ON FUNCTION public.sched_assert_ops() IS
  'W1-09 definer guard: auth.uid() NULL (psql/cron/service write, same '
  'convention as W0-02 triggers) or an active platform_admin/support role.';

-- CATCH-UP WINDOW CONSTANT — 48h (mission recommendation). Single point of
-- truth; ops may shorten/lengthen by editing this function, or a
-- scheduler_settings table row can replace it without touching callers.
CREATE FUNCTION public.sched_catchup_window() RETURNS interval
LANGUAGE sql IMMUTABLE AS $$ SELECT interval '48 hours' $$;
COMMENT ON FUNCTION public.sched_catchup_window() IS
  'W1-09 constant: due instants ≤48h old still fire once (catch-up); '
  '48–96h are ledger-marked skipped; older not enumerated.';

-- §9.1 business day: Mon–Fri excluding the jurisdiction pack holiday calendar.
CREATE FUNCTION public.sched_is_business_day(p_date date, p_jurisdiction text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT extract(isodow FROM p_date) <= 5
     AND NOT EXISTS (
       SELECT 1
         FROM public.jurisdiction_packs jp,
              jsonb_array_elements(jp.public_holidays) h
        WHERE jp.code = p_jurisdiction
          AND (h->>'date')::date = p_date)
$$;
COMMENT ON FUNCTION public.sched_is_business_day(date, text) IS
  'W1-09 §9.1 business day: Mon–Fri minus jurisdiction_packs.public_holidays. '
  'NULL jurisdiction / empty calendar → Mon–Fri only.';

-- nth business day of the month containing p_month ('first' | 'last').
CREATE FUNCTION public.sched_month_business_day(
    p_month date, p_pos text, p_jurisdiction text)
RETURNS date
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE d date;
BEGIN
  IF p_pos = 'last' THEN
    d := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
    WHILE NOT public.sched_is_business_day(d, p_jurisdiction) LOOP
      d := d - 1;
    END LOOP;
  ELSE
    d := date_trunc('month', p_month)::date;     -- default: 'first'
    WHILE NOT public.sched_is_business_day(d, p_jurisdiction) LOOP
      d := d + 1;
    END LOOP;
  END IF;
  RETURN d;
END $$;
COMMENT ON FUNCTION public.sched_month_business_day(date, text, text) IS
  'W1-09: first/last business day of the month containing p_month, on the '
  'jurisdiction pack calendar (§9.1).';

-- date arithmetic in business days (positive n = forward, negative = back).
CREATE FUNCTION public.sched_add_business_days(
    p_date date, p_n int, p_jurisdiction text)
RETURNS date
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE d date := p_date; step int := sign(p_n); remaining int := abs(p_n);
BEGIN
  IF p_n = 0 THEN RETURN p_date; END IF;
  WHILE remaining > 0 LOOP
    d := d + step;
    IF public.sched_is_business_day(d, p_jurisdiction) THEN
      remaining := remaining - 1;
    END IF;
  END LOOP;
  RETURN d;
END $$;
COMMENT ON FUNCTION public.sched_add_business_days(date, int, text) IS
  'W1-09: p_date ± n business days on the jurisdiction calendar (§9.1) — '
  'used for the ''5 business days before due'' trigger.';

-- scope rows a job iterates: scope_key + resolved tz + jurisdiction + client.
CREATE FUNCTION public.sched_scopes(p_job public.scheduled_jobs)
RETURNS TABLE (scope_key text, tz text, jurisdiction text, client_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_job.timezone_scope = 'client' THEN
    RETURN QUERY
      SELECT 'client:' || co.id::text,
             coalesce(co.timezone, jp.timezone, 'UTC'),
             co.jurisdiction,
             co.id
        FROM public.client_orgs co
        LEFT JOIN public.jurisdiction_packs jp ON jp.code = co.jurisdiction;
  ELSIF p_job.timezone_scope = 'partner' THEN
    RETURN QUERY
      SELECT 'partner:' || p.id::text,
             coalesce(jp.timezone, 'UTC'),
             p.country,
             NULL::uuid
        FROM public.practices p
        LEFT JOIN public.jurisdiction_packs jp ON jp.code = p.country;
  ELSE                                            -- 'platform'
    RETURN QUERY SELECT ''::text, 'UTC'::text, NULL::text, NULL::uuid;
  END IF;
END $$;
COMMENT ON FUNCTION public.sched_scopes(public.scheduled_jobs) IS
  'W1-09: the execution scopes of a job. Client tz: client_orgs.timezone → '
  'jurisdiction pack timezone → UTC. Partner tz: practices.country → pack → UTC.';

-- every due instant (UTC) of a schedule_rule inside a local-date range.
CREATE FUNCTION public.sched_local_instants(
    p_rule jsonb, p_tz text, p_jurisdiction text, p_client uuid,
    p_from date, p_to date)
RETURNS SETOF timestamptz
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  d      date;
  v_fire boolean;
  v_time time := coalesce((p_rule->>'time')::time, time '06:00');
  v_kind text := p_rule->>'kind';
BEGIN
  IF v_kind IS NULL OR p_from IS NULL OR p_to IS NULL THEN RETURN; END IF;
  FOR d IN SELECT generate_series(p_from, p_to, interval '1 day')::date LOOP
    v_fire := false;
    IF v_kind = 'daily' THEN
      v_fire := true;
    ELSIF v_kind = 'weekly' THEN
      v_fire := extract(isodow FROM d) = coalesce((p_rule->>'dow')::int, 1);
    ELSIF v_kind = 'monthly_business_day' THEN
      v_fire := d = public.sched_month_business_day(
                      date_trunc('month', d)::date, p_rule->>'position', p_jurisdiction);
    ELSIF v_kind = 'cycle_dates' THEN
      -- §8.11: first business day of each quarter, or a programme anniversary
      -- (the template's generate_on values, resolved to due dates).
      v_fire := d = public.sched_month_business_day(
                      date_trunc('quarter', d)::date, 'first', p_jurisdiction)
             OR (p_client IS NOT NULL AND EXISTS (
                   SELECT 1 FROM public.programmes pr
                    WHERE pr.client_org_id = p_client
                      AND extract(month FROM pr.start_date) = extract(month FROM d)
                      AND extract(day   FROM pr.start_date) = extract(day   FROM d)));
    END IF;
    IF v_fire THEN
      RETURN NEXT (d + v_time) AT TIME ZONE p_tz;
    END IF;
  END LOOP;
  RETURN;
END $$;
COMMENT ON FUNCTION public.sched_local_instants(jsonb, text, text, uuid, date, date) IS
  'W1-09: scheduled instants of a job rule across a local-date range, each '
  'returned as the UTC instant of the local wall time in p_tz.';

-- earliest due instant strictly after p_now across all scopes (informational).
CREATE FUNCTION public.sched_next_due(p_job public.scheduled_jobs, p_now timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_scope record;
  v_inst  timestamptz;
  v_best  timestamptz;
BEGIN
  FOR v_scope IN SELECT * FROM public.sched_scopes(p_job) LOOP
    FOR v_inst IN SELECT i FROM public.sched_local_instants(
        p_job.schedule_rule, v_scope.tz, v_scope.jurisdiction, v_scope.client_id,
        (p_now AT TIME ZONE v_scope.tz)::date,
        ((p_now AT TIME ZONE v_scope.tz)::date + 400)) i ORDER BY i LOOP
      IF v_inst > p_now THEN
        IF v_best IS NULL OR v_inst < v_best THEN v_best := v_inst; END IF;
        EXIT;                              -- instants ascend → first > now wins
      END IF;
    END LOOP;
  END LOOP;
  RETURN v_best;
END $$;
COMMENT ON FUNCTION public.sched_next_due(public.scheduled_jobs, timestamptz) IS
  'W1-09: next due instant across scopes, 400-day horizon (covers annual '
  'anniversaries). Feeds scheduled_jobs.next_run_at.';

-- claim one (scope, period): insert a 'running' ledger row under lease, or
-- adopt an expired running lease. Returns the run id, or NULL when the period
-- is already finished or running under a live lease.
CREATE FUNCTION public.sched_claim_one(
    p_job public.scheduled_jobs, p_scope_key text,
    p_period timestamptz, p_now timestamptz)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_run uuid;
BEGIN
  INSERT INTO public.job_runs
      (job_key, scope_key, period_started_at, started_at, locked_until, status, detail)
  VALUES (p_job.key, p_scope_key, p_period, p_now,
          p_now + p_job.lease_seconds * interval '1 second', 'running',
          jsonb_build_object('claimed_by', coalesce(auth.uid()::text, 'service')))
  ON CONFLICT (job_key, scope_key, period_started_at) DO NOTHING
  RETURNING id INTO v_run;
  IF v_run IS NULL THEN
    -- at-least-once adoption: lease expired mid-flight → re-drive the
    -- (idempotent) handler on the SAME ledger row; never a duplicate.
    UPDATE public.job_runs
       SET locked_until = p_now + p_job.lease_seconds * interval '1 second',
           detail = detail || jsonb_build_object('adopted_at', p_now)
     WHERE job_key = p_job.key AND scope_key = p_scope_key
       AND period_started_at = p_period
       AND status = 'running'
       AND locked_until <= p_now
    RETURNING id INTO v_run;
  END IF;
  RETURN v_run;
END $$;
COMMENT ON FUNCTION public.sched_claim_one(public.scheduled_jobs, text, timestamptz, timestamptz) IS
  'W1-09 lease primitive: job_runs row + locked_until per (job,scope,period); '
  'expired leases adopted, never duplicated (UNIQUE job_runs_idem_idx).';

-- ---------- 4. public RPCs ----------

-- claim_job(job, now): claim every (scope, period) currently due for a job.
-- Returns the ids of the newly claimed 'running' rows. Same job + same
-- period = no-op. Disabled job = empty set; unknown key = exception.
CREATE FUNCTION public.claim_job(p_job_key text, p_now timestamptz DEFAULT now())
RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job   public.scheduled_jobs;
  v_scope record;
  v_inst  timestamptz;
  v_run   uuid;
BEGIN
  PERFORM public.sched_assert_ops();
  SELECT * INTO v_job FROM public.scheduled_jobs WHERE key = p_job_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown scheduled job: %', p_job_key;
  END IF;
  IF NOT v_job.enabled THEN
    RAISE NOTICE 'claim_job: % is disabled — nothing claimed', p_job_key;
    RETURN;
  END IF;
  FOR v_scope IN SELECT * FROM public.sched_scopes(v_job) LOOP
    FOR v_inst IN SELECT i FROM public.sched_local_instants(
        v_job.schedule_rule, v_scope.tz, v_scope.jurisdiction, v_scope.client_id,
        ((p_now - public.sched_catchup_window()) AT TIME ZONE v_scope.tz)::date,
        (p_now AT TIME ZONE v_scope.tz)::date) i ORDER BY i LOOP
      IF v_inst <= p_now AND v_inst > p_now - public.sched_catchup_window() THEN
        v_run := public.sched_claim_one(v_job, v_scope.scope_key, v_inst, p_now);
        IF v_run IS NOT NULL THEN RETURN NEXT v_run; END IF;
      END IF;
    END LOOP;
  END LOOP;
  RETURN;
END $$;
COMMENT ON FUNCTION public.claim_job(text, timestamptz) IS
  'W1-09: lease+claim every (scope,period) of a job due inside the catch-up '
  'window at p_now. Idempotent — an existing ledger row for the period is a '
  'no-op. Guarded: service context or platform-ops only.';

-- complete_job(run, status, detail): finish a 'running' row and release the
-- lease. Returns false when the row is already finished.
CREATE FUNCTION public.complete_job(
    p_run_id uuid, p_status text, p_detail jsonb DEFAULT '{}'::jsonb,
    p_now timestamptz DEFAULT now())
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.sched_assert_ops();
  IF p_status NOT IN ('success','failed','skipped') THEN
    RAISE EXCEPTION 'complete_job: invalid status % (success|failed|skipped)', p_status;
  END IF;
  UPDATE public.job_runs
     SET finished_at  = p_now,
         status       = p_status,
         detail       = detail || p_detail,
         locked_until = NULL                       -- lease released
   WHERE id = p_run_id AND status = 'running';
  RETURN FOUND;
END $$;
COMMENT ON FUNCTION public.complete_job(uuid, text, jsonb, timestamptz) IS
  'W1-09: finishes a running ledger row (status + merged detail + finished_at) '
  'and releases its lease. Already-finished → false.';

-- ---------- 5. handlers (pure-DB ones implemented; others owner-stubbed) ----

-- §9.5 monthly snapshot for one programme/period — append-only, idempotent.
CREATE FUNCTION public.sched_take_monthly_snapshot(
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
          WHERE a.programme_id = p.id AND a.status = 'Complete'),
      'activities_overdue',
        (SELECT count(*) FROM public.activities a
          WHERE a.programme_id = p.id AND a.due_date < p_as_of
            AND a.status NOT IN ('Complete','Deferred')),
      'register_closed',
        (SELECT count(*) FROM public.register_items r
          WHERE r.programme_id = p.id AND r.status = 'Closed'),
      'register_open',
        (SELECT count(*) FROM public.register_items r
          WHERE r.programme_id = p.id AND r.status <> 'Closed'),
      'high_priority_closed',
        (SELECT count(*) FROM public.register_items r
          WHERE r.programme_id = p.id AND r.status = 'Closed' AND r.priority = 'High'),
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
COMMENT ON FUNCTION public.sched_take_monthly_snapshot(uuid, text, date) IS
  'W1-09 §9.5: write the monthly snapshot row (fixed jsonb contract — reports '
  'build from it, so issued reports never change). ON CONFLICT no-op.';

-- daily 06:00 client-tz recalc: §9.3 days_overdue + §9.2 activity RAG + the
-- §10 trigger events this job owns. Digest send itself is W1-08's consumer.
CREATE FUNCTION public.sched_daily_sweep(p_client uuid, p_local_date date)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_jur     text;
  v_overdue int;
  v_rag     int;
  v_events  jsonb := '{}'::jsonb;
  v_n       int;
BEGIN
  SELECT co.jurisdiction INTO v_jur FROM public.client_orgs co WHERE co.id = p_client;

  -- §9.3: days overdue = report date − planned close date, never below zero,
  -- blank once Closed. (report date = the client's local date at the due instant)
  WITH calc AS (
    SELECT r.id,
           CASE WHEN r.status = 'Closed' OR r.planned_close_date IS NULL THEN NULL
                ELSE greatest(p_local_date - r.planned_close_date, 0) END AS v
      FROM public.register_items r
      JOIN public.programmes p ON p.id = r.programme_id
     WHERE p.client_org_id = p_client)
  UPDATE public.register_items r
     SET days_overdue = c.v
    FROM calc c
   WHERE r.id = c.id AND r.days_overdue IS DISTINCT FROM c.v;
  GET DIAGNOSTICS v_overdue = ROW_COUNT;

  -- §9.2 ordered RAG rules (first match wins). Deterministic; when the W1-01
  -- rules engine lands its canonical function this call should delegate to it.
  WITH calc AS (
    SELECT a.id,
           CASE
             WHEN a.status = 'Complete' THEN 'Complete'
             WHEN a.status = 'Blocked'  THEN 'Red'
             WHEN a.due_date IS NOT NULL AND a.due_date < p_local_date
                  AND a.status <> 'Deferred'
               THEN CASE WHEN p_local_date - a.due_date > p.red_days_threshold
                         THEN 'Red' ELSE 'Amber' END
             WHEN a.status = 'At risk' THEN 'Amber'
             WHEN a.start_date IS NOT NULL AND a.start_date <= p_local_date
               THEN 'Green'
             ELSE 'Not due' END AS v
      FROM public.activities a
      JOIN public.programmes p ON p.id = a.programme_id
     WHERE p.client_org_id = p_client)
  UPDATE public.activities a
     SET rag = c.v
    FROM calc c
   WHERE a.id = c.id AND a.rag IS DISTINCT FROM c.v;
  GET DIAGNOSTICS v_rag = ROW_COUNT;

  -- §10 trigger events the daily job owns — emitted into the outbox for the
  -- W1-08 dispatcher; each deduped once-per-entity via the payload ref.
  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'activity_due',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('activity_id', a.id, 'ref', a.ref, 'due_date', a.due_date)
      FROM public.activities a
      JOIN public.programmes p ON p.id = a.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND a.due_date = p_local_date                      -- on the due date
       AND a.status NOT IN ('Complete','Deferred')
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'activity_due'
                          AND ne.payload->>'activity_id' = a.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('activity_due', v_n);

  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'activity_due_soon',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('activity_id', a.id, 'ref', a.ref, 'due_date', a.due_date,
                              'business_days_before', 5)
      FROM public.activities a
      JOIN public.programmes p ON p.id = a.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND a.due_date = public.sched_add_business_days(p_local_date, 5, v_jur)
       AND a.status NOT IN ('Complete','Deferred')
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'activity_due_soon'
                          AND ne.payload->>'activity_id' = a.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('activity_due_soon', v_n);

  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'activity_starting',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('activity_id', a.id, 'ref', a.ref, 'start_date', a.start_date)
      FROM public.activities a
      JOIN public.programmes p ON p.id = a.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND a.start_date BETWEEN p_local_date - 6 AND p_local_date  -- its start week
       AND a.status = 'Not started'
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'activity_starting'
                          AND ne.payload->>'activity_id' = a.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('activity_starting', v_n);

  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'maintenance_input_overdue',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('mti_id', m.id, 'code', t.code, 'due_date', m.due_date,
                              'period', m.period)
      FROM public.maintenance_task_instances m
      JOIN public.maintenance_task_templates t ON t.id = m.task_template_id
      JOIN public.programmes p ON p.id = t.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND m.due_date IS NOT NULL AND m.due_date < p_local_date
       AND m.status IN ('Pending','In progress')          -- "when overdue"
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'maintenance_input_overdue'
                          AND ne.payload->>'mti_id' = m.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('maintenance_input_overdue', v_n);

  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'monthly_report_late',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('report_id', r.id, 'period', r.period, 'due_on', r.due_on)
      FROM public.programme_reports r
      JOIN public.programmes p ON p.id = r.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND r.due_on IS NOT NULL AND r.due_on < p_local_date
       AND r.status <> 'issued'                           -- late = not issued by due_on
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'monthly_report_late'
                          AND ne.payload->>'report_id' = r.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('monthly_report_late', v_n);

  -- owner stubs — parts of the §10 daily job that belong to other sessions:
  RAISE NOTICE 'W1-09 STUB daily-recalc-digest scope %: digest send is owned by W1-08 (notification dispatcher); phase/current-week recalc by W1-01 (rules engine)', p_client;

  RETURN jsonb_build_object(
      'local_date', p_local_date,
      'days_overdue_updated', v_overdue,
      'rag_updated', v_rag,
      'events_emitted', v_events,
      'stub', jsonb_build_object('digest','W1-08','phase_week_recalc','W1-01'));
END $$;
COMMENT ON FUNCTION public.sched_daily_sweep(uuid, date) IS
  'W1-09 daily 06:00 client-tz sweep: §9.3 days_overdue, §9.2 activity RAG and '
  'the §10 trigger events (deduped once-per-entity in the outbox). Digest send '
  '= W1-08, phase/week recalc = W1-01 — stubbed NOTICEs.';

-- dispatch: handler_fn CASE registry. Returns the run detail jsonb.
CREATE FUNCTION public.sched_run_handler(
    p_job public.scheduled_jobs, p_run public.job_runs, p_now timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_client uuid;
  v_tz     text;
  v_local  date;
  v_period text;
  v_count  int := 0;
  v_prog   record;
BEGIN
  IF p_run.scope_key LIKE 'client:%' THEN
    v_client := substring(p_run.scope_key from 8)::uuid;
    SELECT coalesce(co.timezone, jp.timezone, 'UTC')
      INTO v_tz
      FROM public.client_orgs co
      LEFT JOIN public.jurisdiction_packs jp ON jp.code = co.jurisdiction
     WHERE co.id = v_client;
    v_tz := coalesce(v_tz, 'UTC');
    -- the client's local date AT THE DUE INSTANT — catch-up stays correct
    v_local := (p_run.period_started_at AT TIME ZONE v_tz)::date;
  END IF;

  IF p_job.handler_fn = 'daily_recalc_digest' THEN
    RETURN public.sched_daily_sweep(v_client, v_local);

  ELSIF p_job.handler_fn = 'monthly_snapshot' THEN
    v_period := to_char(v_local, 'YYYY-MM');      -- month of the due instant
    FOR v_prog IN SELECT id FROM public.programmes WHERE client_org_id = v_client LOOP
      IF public.sched_take_monthly_snapshot(v_prog.id, v_period, v_local) THEN
        v_count := v_count + 1;
      END IF;
    END LOOP;
    RETURN jsonb_build_object('period', v_period, 'snapshots_written', v_count);

  ELSIF p_job.handler_fn = 'monthly_maintenance_gen' THEN
    RAISE NOTICE 'W1-09 STUB monthly-bd1-gen scope % period %: monthly maintenance-task generation + draft monthly report is owned by W1-03 (cadence engine)',
      p_run.scope_key, v_local;
    RETURN jsonb_build_object('stub', 'W1-03', 'work', 'maintenance_tasks + draft monthly report');

  ELSIF p_job.handler_fn = 'checklist_gen' THEN
    RAISE NOTICE 'W1-09 STUB quarterly-annual-checklists scope % date %: quarterly/annual checklist + annual-review-task generation is owned by W1-03 (cadence engine)',
      p_run.scope_key, v_local;
    RETURN jsonb_build_object('stub', 'W1-03', 'work', 'checklist_instances + annual review tasks');

  ELSIF p_job.handler_fn = 'weekly_agenda' THEN
    RAISE NOTICE 'W1-09 STUB monday-agenda scope % date %: weekly session agenda build is owned by W2-07 (agenda screen) / W1-08 (agenda mail, FR-WKS-05)',
      p_run.scope_key, v_local;
    RETURN jsonb_build_object('stub', 'W2-07/W1-08', 'work', 'weekly session agenda');

  ELSIF p_job.handler_fn = 'partner_usage_report' THEN
    RAISE NOTICE 'W1-09 STUB partner-usage-report scope %: monthly partner licence-usage report is owned by W2-17 (partner team + licence usage, FR-LIC-02)',
      p_run.scope_key;
    RETURN jsonb_build_object('stub', 'W2-17', 'work', 'partner usage report');

  ELSE
    RAISE EXCEPTION 'no handler registered for scheduled job % (handler_fn %)',
      p_job.key, p_job.handler_fn;
  END IF;
END $$;
COMMENT ON FUNCTION public.sched_run_handler(public.scheduled_jobs, public.job_runs, timestamptz) IS
  'W1-09 dispatch CASE on handler_fn. Implemented: daily_recalc_digest, '
  'monthly_snapshot. Stubs (NOTICE + detail.stub): monthly_maintenance_gen '
  '(W1-03), checklist_gen (W1-03), weekly_agenda (W2-07/W1-08), '
  'partner_usage_report (W2-17).';

-- ---------- 6. tick — the clock-injectable sweep ----------

CREATE FUNCTION public.tick(p_now timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_job     public.scheduled_jobs;
  v_scope   record;
  v_inst    timestamptz;
  v_run     uuid;
  v_detail  jsonb;
  v_catchup interval := public.sched_catchup_window();
  v_from    date;
  v_to      date;
  v_claimed int := 0;
  v_ok      int := 0;
  v_fail    int := 0;
  v_fail2   int := 0;
  v_skip    int := 0;
  v_runs    jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.sched_assert_ops();

  FOR v_job IN SELECT * FROM public.scheduled_jobs WHERE enabled ORDER BY key LOOP
    -- one ticker per job at a time; a busy job is picked up on the next tick
    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_job.key, 20261106)) THEN
      v_runs := v_runs || jsonb_build_object('job', v_job.key, 'status', 'lock_busy');
      CONTINUE;
    END IF;

    FOR v_scope IN SELECT * FROM public.sched_scopes(v_job) LOOP
      v_from := ((p_now - 2 * v_catchup) AT TIME ZONE v_scope.tz)::date;
      v_to   := (p_now AT TIME ZONE v_scope.tz)::date;
      FOR v_inst IN SELECT i FROM public.sched_local_instants(
          v_job.schedule_rule, v_scope.tz, v_scope.jurisdiction, v_scope.client_id,
          v_from, v_to) i ORDER BY i LOOP
        IF v_inst > p_now THEN
          CONTINUE;                                    -- not due yet
        ELSIF v_inst > p_now - v_catchup THEN
          -- fire window: claim (or adopt an expired lease) then dispatch
          v_run := public.sched_claim_one(v_job, v_scope.scope_key, v_inst, p_now);
          IF v_run IS NULL THEN
            CONTINUE;                                  -- finished, or live lease
          END IF;
          v_claimed := v_claimed + 1;
          BEGIN
            v_detail := public.sched_run_handler(
                v_job, (SELECT r FROM public.job_runs r WHERE r.id = v_run), p_now);
            PERFORM public.complete_job(v_run, 'success', v_detail, p_now);
            v_ok := v_ok + 1;
            v_runs := v_runs || jsonb_build_object(
                'job', v_job.key, 'scope', v_scope.scope_key,
                'period', v_inst, 'run', v_run, 'status', 'success');
          EXCEPTION WHEN OTHERS THEN
            PERFORM public.complete_job(v_run, 'failed',
                jsonb_build_object('error', SQLERRM), p_now);
            v_fail := v_fail + 1;
            v_runs := v_runs || jsonb_build_object(
                'job', v_job.key, 'scope', v_scope.scope_key,
                'period', v_inst, 'run', v_run, 'status', 'failed',
                'error', SQLERRM);
          END;
        ELSIF v_inst > p_now - 2 * v_catchup THEN
          -- skip zone (48–96h old). If a stale claim sits on the instant it
          -- never dispatched — finalize it 'failed' so the ledger has no
          -- zombie 'running' rows; otherwise ledger-mark the miss 'skipped'.
          UPDATE public.job_runs
             SET status = 'failed', finished_at = p_now, locked_until = NULL,
                 detail = detail || '{"reason":"lease expired; instant aged out of the catch-up window"}'::jsonb
           WHERE job_key = v_job.key AND scope_key = v_scope.scope_key
             AND period_started_at = v_inst
             AND status = 'running' AND locked_until <= p_now;
          IF FOUND THEN
            v_fail := v_fail + 1;
          ELSE
            INSERT INTO public.job_runs
                (job_key, scope_key, period_started_at, started_at, finished_at,
                 status, detail)
            VALUES (v_job.key, v_scope.scope_key, v_inst, p_now, p_now, 'skipped',
                    '{"reason":"outside 48h catch-up window"}'::jsonb)
            ON CONFLICT (job_key, scope_key, period_started_at) DO NOTHING;
            IF FOUND THEN v_skip := v_skip + 1; END IF;
          END IF;
        END IF;
      END LOOP;
    END LOOP;

    UPDATE public.scheduled_jobs
       SET next_run_at = public.sched_next_due(v_job, p_now),
           last_tick_at = p_now
     WHERE key = v_job.key;
  END LOOP;

  -- janitor: a 'running' row whose lease expired >1 catch-up window ago can no
  -- longer be adopted (its instant is out of enumeration) — finalize it so the
  -- ledger never holds a zombie 'running' row.
  UPDATE public.job_runs
     SET status = 'failed', finished_at = p_now, locked_until = NULL,
         detail = detail || '{"reason":"lease expired unrun (janitor)"}'::jsonb
   WHERE status = 'running' AND locked_until <= p_now - v_catchup;
  GET DIAGNOSTICS v_fail2 = ROW_COUNT;

  RETURN jsonb_build_object('at', p_now, 'claimed', v_claimed,
      'succeeded', v_ok, 'failed', v_fail, 'skipped', v_skip,
      'stale_finalized', v_fail2, 'runs', v_runs);
END $$;
COMMENT ON FUNCTION public.tick(timestamptz) IS
  'W1-09 scheduler sweep — invoked by pg_cron ''securepath-tick'' (every '
  'minute) or staging/jobs-tick.timer. Clock injectable: pass p_now to test '
  'due/catch-up paths deterministically. Per-job advisory lock; per-scope '
  'per-period idempotent claim→dispatch→complete; 48h catch-up window; '
  '48–96h instants marked skipped.';

-- ---------- 7. firing mechanism: pg_cron if preloaded, else documented timer --
-- The staging image already has pg_cron in shared_preload_libraries, so this
-- arm the every-minute tick with NO compose change. On a database where
-- pg_cron cannot be created the block NOTICEs and skips — ops then installs
-- staging/jobs-tick.{service,timer} (same SELECT public.tick(now()) call).
DO $pgcron$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'W1-09: pg_cron unavailable (%) — install staging/jobs-tick.timer '
      'instead (see staging/README.md). tick() is driver-agnostic.', SQLERRM;
    RETURN;
  END;
  BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'securepath-tick') THEN
      PERFORM cron.unschedule('securepath-tick');
    END IF;
    PERFORM cron.schedule('securepath-tick', '* * * * *', 'SELECT public.tick()');
    RAISE NOTICE 'W1-09: pg_cron armed — securepath-tick runs every minute';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'W1-09: pg_cron present but scheduling failed (%) — use '
      'staging/jobs-tick.timer.', SQLERRM;
  END;
END $pgcron$;

-- ---------- 8. execution surface (W0-00 convention) ----------

REVOKE EXECUTE ON FUNCTION
  public.sched_assert_ops(),
  public.sched_catchup_window(),
  public.sched_is_business_day(date, text),
  public.sched_month_business_day(date, text, text),
  public.sched_add_business_days(date, int, text),
  public.sched_scopes(public.scheduled_jobs),
  public.sched_local_instants(jsonb, text, text, uuid, date, date),
  public.sched_next_due(public.scheduled_jobs, timestamptz),
  public.sched_claim_one(public.scheduled_jobs, text, timestamptz, timestamptz),
  public.claim_job(text, timestamptz),
  public.complete_job(uuid, text, jsonb, timestamptz),
  public.sched_take_monthly_snapshot(uuid, text, date),
  public.sched_daily_sweep(uuid, date),
  public.sched_run_handler(public.scheduled_jobs, public.job_runs, timestamptz),
  public.tick(timestamptz)
FROM anon, public, authenticated;

-- the guarded entry points are callable by authenticated (they self-guard to
-- platform-ops); read-only business-day helpers are safe to expose for the
-- coming engines (W1-01/W1-03) and PostgREST RPC use.
GRANT EXECUTE ON FUNCTION
  public.claim_job(text, timestamptz),
  public.complete_job(uuid, text, jsonb, timestamptz),
  public.tick(timestamptz),
  public.sched_is_business_day(date, text),
  public.sched_month_business_day(date, text, text)
TO authenticated;
