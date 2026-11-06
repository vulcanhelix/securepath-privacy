-- ============================================================================
-- W1-09 scheduler runner — psql acceptance checks (>= 20)
-- Covers: registry upgrade, claim/lease idempotency, complete_job semantics,
-- per-client-timezone due resolution (no UTC-midnight firing), 48h catch-up,
-- skip-zone marking, stale-lease adoption, stub dispatch, the ops guard, and
-- the pure-DB handlers (§9.3 days_overdue, §9.2 activity RAG, §9.5 snapshot,
-- §10 trigger events).
--
-- ENVIRONMENT: expects the W0-05 TESTFIX fixture pack seeded —
--     ALTER DATABASE <db> SET securepath.test_fixtures = 'on';
--     then re-apply 20261105000005_test_fixtures.sql (re-runnable).
-- (The TESTFIX world: C1/C3 = Africa/Johannesburg, C2 = Europe/London;
--  P1 impl 2026-09-07, P2 maintenance (UK), P3 impl 2026-10-05.)
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_scheduler.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- ---------- 0. baseline + environment control ----------
-- pg_cron 'securepath-tick' is armed by the migration and ticks on the REAL
-- clock — suspend it for the duration of this clock-injected suite, re-arm in
-- teardown. Guarded: the block no-ops where pg_cron was not installable.
DO $$
BEGIN
  IF to_regnamespace('cron') IS NOT NULL
     AND EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'securepath-tick') THEN
    PERFORM cron.unschedule('securepath-tick');
    CREATE TEMP TABLE w1s_cron_was_armed (x int);
  END IF;
END $$;

-- rows present before this suite must survive teardown (real-clock runs may
-- exist on CI); everything we create is deleted by id-difference instead.
DROP TABLE IF EXISTS w1s_pre_runs;
DROP TABLE IF EXISTS w1s_pre_events;
DROP TABLE IF EXISTS w1s_pre_snaps;
CREATE TEMP TABLE w1s_pre_runs    AS SELECT id FROM public.job_runs;
CREATE TEMP TABLE w1s_pre_events  AS SELECT id FROM public.notification_events;
CREATE TEMP TABLE w1s_pre_snaps   AS SELECT id FROM public.monthly_snapshots;

-- ---------- fixtures (@w1s.test / W1S% namespace) ----------
-- wipe the TESTFIX-scope ledger outright: this suite owns every row scoped to
-- the fixture clients/practices (they only exist because the fixture pack was
-- seeded), and real-clock ticks may have pre-marked recent instants 'skipped'.
DELETE FROM job_runs
 WHERE scope_key LIKE 'client:cc000005-%' OR scope_key LIKE 'partner:bb000005-%'
    OR scope_key LIKE 'client:c4000000-%' OR scope_key LIKE 'partner:b4000000-%';
DELETE FROM role_assignments WHERE user_id IN
  (SELECT id FROM users WHERE email LIKE '%@w1s.test');
DELETE FROM users WHERE email LIKE '%@w1s.test';
DELETE FROM auth.users WHERE email LIKE '%@w1s.test';
DELETE FROM programme_reports WHERE programme_id IN
  (SELECT id FROM programmes WHERE name LIKE 'W1S%');
DELETE FROM programmes WHERE name LIKE 'W1S%';
DELETE FROM client_orgs WHERE name LIKE 'W1S%';
DELETE FROM practices WHERE name LIKE 'W1S%';

INSERT INTO auth.users (id, instance_id, email, encrypted_password, aud, role,
    email_confirmed_at, created_at, updated_at, confirmation_token,
    email_change, email_change_token_new, email_change_token_current,
    recovery_token, reauthentication_token, phone_change, phone_change_token,
    raw_app_meta_data, raw_user_meta_data)
SELECT u.id, '00000000-0000-0000-0000-000000000000', u.email,
    crypt('x', gen_salt('bf')), 'authenticated', 'authenticated',
    now(), now(), now(), '',
    '', '', '',
    '', '', '', '',
    '{"provider":"email","providers":["email"]}', '{}'
FROM (VALUES
  ('a4000000-0000-0000-0000-000000000001'::uuid, 'sched-platform@w1s.test'),
  ('a4000000-0000-0000-0000-000000000002'::uuid, 'sched-tenant@w1s.test')
) AS u(id, email);
INSERT INTO users (id, email) SELECT id, email FROM auth.users WHERE email LIKE '%@w1s.test';

-- NB: the W1S tenant entities (practice/client/programme/report) are created
-- in §12 below — a new client adds a 4th execution scope and would skew the
-- per-scope claim counts asserted in §3–§9. Users + assignments are scope-free.
INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a4000000-0000-0000-0000-000000000001','platform','platform_admin','partner',NULL),
  ('a4000000-0000-0000-0000-000000000002','client','client_admin','client','c4000000-0000-0000-0000-000000000001');

-- ---------- 1. registry upgrade ----------
SELECT pg_temp.t(
  (SELECT count(*) FROM scheduled_jobs
    WHERE handler_fn IS NOT NULL AND schedule_rule <> '{}'::jsonb) = 6,
  'registry: all 6 seeded jobs carry schedule_rule + handler_fn');
SELECT pg_temp.t(
  (SELECT timezone_scope FROM scheduled_jobs WHERE key='partner-usage-report') = 'partner'
  AND (SELECT timezone_scope FROM scheduled_jobs WHERE key='daily-recalc-digest') = 'client',
  'registry: timezone_scope set per job (partner vs client)');

-- ---------- 2. claim_job: nothing due inside the window → no-op ----------
SELECT pg_temp.t(
  (SELECT count(*) FROM public.claim_job('monday-agenda','2026-10-09 02:00+00')) = 0,
  'claim_job: no due instant in window → 0 claims (Monday job, Friday clock)');

-- ---------- 3. per-client-TZ due resolution (NO UTC-midnight firing) ----------
-- NB: claim counts are asserted on TESTFIX scope_keys only — other suites'
-- clients/practices legitimately add scopes of their own on a shared CI db.
-- 04:30Z = 06:30 SAST (C1,C3 due) but only 05:30 BST (C2 not due until 05:00Z)
SELECT public.tick('2026-10-09 04:30+00') AS t1 \gset
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs
    WHERE started_at='2026-10-09 04:30+00' AND status='success'
      AND scope_key LIKE 'client:cc000005-%') = 6,
  'tick 04:30Z: 6 TESTFIX claims — Oct-8 catch-up ×3 + Oct-9 ZA ×2 (London not yet due)');
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs
    WHERE job_key='daily-recalc-digest' AND period_started_at='2026-10-09 04:00+00'
      AND scope_key IN ('client:cc000005-0000-0000-0000-000000000001',
                        'client:cc000005-0000-0000-0000-000000000003')) = 2
  AND NOT EXISTS (SELECT 1 FROM job_runs
    WHERE job_key='daily-recalc-digest' AND scope_key='client:cc000005-0000-0000-0000-000000000002'
      AND period_started_at='2026-10-09 04:00+00'),
  'TZ: Oct-9 06:00 SAST fired for C1+C3 at 04:00Z — NOT for London C2 yet');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM job_runs
     WHERE job_key='daily-recalc-digest' AND scope_key='client:cc000005-0000-0000-0000-000000000002'
       AND period_started_at='2026-10-08 05:00+00'),
  'TZ: C2 ran Oct-8 at 05:00Z = 06:00 BST (client-local, not UTC)');

-- double-tick idempotency: identical clock → zero new claims, row count stable
SELECT count(*) AS runs_pre_double FROM job_runs \gset
SELECT (public.tick('2026-10-09 04:30+00') ->> 'claimed')::int AS c2 \gset
SELECT pg_temp.t(:c2 = 0 AND (SELECT count(*) FROM job_runs) = :runs_pre_double,
  'double-tick same clock → 0 claims (idempotency bar)');

-- 05:30Z = 06:30 BST → London's Oct-9 instant now due
SELECT (public.tick('2026-10-09 05:30+00') ->> 'claimed')::int AS c3 \gset
SELECT pg_temp.t(:c3 = 1,
  'tick 05:30Z: exactly 1 claim — C2 Oct-9 now due at 06:30 BST');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM job_runs
     WHERE job_key='daily-recalc-digest' AND scope_key='client:cc000005-0000-0000-0000-000000000002'
       AND period_started_at='2026-10-09 05:00+00' AND status='success'),
  'TZ: C2 Oct-9 fired at 05:00Z = 06:00 BST — per-client tz, not UTC');

-- next_run_at: earliest due instant > now across scopes — exact value depends
-- on the scopes present, so assert it moved forward AND prove the per-scope
-- instant directly: C1's next daily instant after the 05:30 tick is Oct-10
-- 04:00Z (06:00 SAST, not UTC-derived).
SELECT pg_temp.t(
  (SELECT next_run_at FROM scheduled_jobs WHERE key='daily-recalc-digest')
    > '2026-10-09 05:30+00',
  'next_run_at advanced past the tick clock');
SELECT pg_temp.t(
  (SELECT min(i) FROM public.sched_local_instants(
      '{"kind":"daily","time":"06:00"}'::jsonb,'Africa/Johannesburg','ZA',
      'cc000005-0000-0000-0000-000000000001',DATE '2026-10-10',DATE '2026-10-10') i)
    = '2026-10-10 04:00:00+00',
  'C1 next daily instant = Oct-10 04:00Z (06:00 SAST) — per-client resolution');

-- ---------- 4. handler effects — §9.3 days_overdue + §9.2 RAG ----------
SELECT pg_temp.t(
  (SELECT days_overdue FROM register_items WHERE ref='R-11') = 49,
  '§9.3: R-11 days_overdue = 49 (Aug-21 → Oct-9 London date)');
SELECT pg_temp.t(
  (SELECT days_overdue FROM register_items WHERE ref='R-04') IS NULL
  AND (SELECT days_overdue FROM register_items WHERE ref='R-01') = 0,
  '§9.3: days_overdue blank once Closed (R-04), 0 on the due day (R-01)');
SELECT pg_temp.t(
  (SELECT rag FROM activities WHERE ref='A-02' AND programme_id='dd000005-0000-0000-0000-000000000001') = 'Amber',
  '§9.2: A-02 recalc → Amber (7d past due ≤ 14d red threshold)');
SELECT pg_temp.t(
  (SELECT rag FROM activities WHERE ref='A-08' AND programme_id='dd000005-0000-0000-0000-000000000001') = 'Red',
  '§9.2: A-08 Blocked → Red (ordered-rule precedence)');

-- ---------- 5. §10 trigger events emitted + deduped ----------
SELECT pg_temp.t(
  (SELECT count(*) FROM notification_events WHERE kind='activity_due'
     AND payload->>'activity_id' IN ('d3000005-0000-0000-0000-000000000003','d3000005-0000-0000-0000-000000000021')) = 2,
  '§10: activity_due emitted for A-03 + A-21 (both due Oct-9)');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM notification_events
     WHERE kind='activity_due_soon' AND payload->>'activity_id'='d3000005-0000-0000-0000-000000000004'),
  '§10: activity_due_soon emitted for A-04 (Oct-16 = Oct-9 + 5 business days)');

-- ---------- 6. claim_job → running rows; complete_job semantics ----------
SELECT count(*) AS q_running_pre FROM job_runs
 WHERE job_key='quarterly-annual-checklists' AND scope_key LIKE 'client:cc000005-%' \gset
SELECT count(*) AS q_ret
  FROM public.claim_job('quarterly-annual-checklists','2026-10-01 05:30+00') \gset
SELECT pg_temp.t(:q_ret >= 3 AND
  (SELECT count(*) FROM job_runs WHERE job_key='quarterly-annual-checklists'
     AND scope_key LIKE 'client:cc000005-%' AND status='running') - :q_running_pre = 3,
  'claim_job quarterly-checklists @Oct-1 05:30Z: 3 TESTFIX claims (1st BD of Q4)');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.claim_job('quarterly-annual-checklists','2026-10-01 05:30+00')) = 0,
  'claim_job same job+period again → 0 (unique idempotency key)');
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs WHERE job_key='quarterly-annual-checklists'
     AND scope_key LIKE 'client:cc000005-%'
     AND status='running' AND locked_until > '2026-10-01 05:30+00') = 3,
  'claimed rows are running under lease (locked_until set)');

SELECT id AS q_run FROM job_runs WHERE job_key='quarterly-annual-checklists'
  AND scope_key LIKE 'client:cc000005-%' LIMIT 1 \gset
SELECT pg_temp.t(public.complete_job(:'q_run','success','{"note":"manual finish"}'),
  'complete_job: finishes a running row → true');
SELECT pg_temp.t(
  (SELECT status FROM job_runs WHERE id=:'q_run') = 'success'
  AND (SELECT locked_until FROM job_runs WHERE id=:'q_run') IS NULL
  AND (SELECT finished_at FROM job_runs WHERE id=:'q_run') IS NOT NULL,
  'complete_job: status success, lease released, finished_at stamped');
SELECT pg_temp.t(NOT public.complete_job(:'q_run','success'),
  'complete_job on finished row → false (no-op)');
DO $$
BEGIN
  BEGIN
    PERFORM public.complete_job(
      (SELECT id FROM job_runs WHERE job_key='quarterly-annual-checklists' LIMIT 1),
      'bogus');
    PERFORM pg_temp.t(false,'complete_job rejects invalid status');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'complete_job rejects invalid status: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.claim_job('no-such-job');
    PERFORM pg_temp.t(false,'claim_job rejects unknown job key');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'claim_job rejects unknown job key: '||SQLERRM);
  END;
END $$;

-- ---------- 7. catch-up: last-BD snapshot fired ~42h late, once ----------
SELECT public.tick('2026-11-01 10:00+00') AS t4 \gset
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs
    WHERE started_at='2026-11-01 10:00+00' AND status='success'
      AND scope_key LIKE 'client:cc000005-%') = 9,
  'tick Nov-1 10:00Z: 9 TESTFIX claims — daily Oct-31+Nov-1 ×3, Oct-30 snapshots ×3');
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs WHERE job_key='monthly-last-bd-snapshot'
     AND scope_key LIKE 'client:cc000005-%'
     AND status='success' AND period_started_at IN
       ('2026-10-30 16:00+00','2026-10-30 18:00+00')) = 3,
  'catch-up: snapshot job fired for all 3 clients inside 48h window');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM job_runs WHERE job_key='monthly-last-bd-snapshot'
      AND scope_key='client:cc000005-0000-0000-0000-000000000002'
      AND period_started_at='2026-10-30 18:00+00'),
  'catch-up TZ: C2 snapshot instant = Oct-30 18:00 GMT = 18:00Z (clocks back)');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM monthly_snapshots
     WHERE programme_id='dd000005-0000-0000-0000-000000000001' AND period='2026-10'),
  '§9.5: P1 2026-10 snapshot written by the catch-up run');
SELECT pg_temp.t(
  (SELECT count(*) FROM monthly_snapshots
     WHERE programme_id='dd000005-0000-0000-0000-000000000002' AND period='2026-10') = 1,
  '§9.5: P2 2026-10 snapshot NOT duplicated (UNIQUE period, re-entrant handler)');
SELECT pg_temp.t(
  (SELECT count(*) FROM monthly_snapshots s
     WHERE s.programme_id='dd000005-0000-0000-0000-000000000001' AND s.period='2026-10'
       AND s.snapshot ? 'activities_complete' AND s.snapshot ? 'register_open'
       AND s.snapshot ? 'kpi_actuals' AND s.snapshot ? 'maintenance_overdue') = 1,
  '§9.5: snapshot carries the fixed jsonb contract keys');
-- catch-up fires ONCE: re-tick → no new snapshot run, snapshot count stable
SELECT count(*) AS snaps_pre FROM monthly_snapshots \gset
SELECT (public.tick('2026-11-01 10:00+00') ->> 'claimed')::int AS c5 \gset
SELECT pg_temp.t(:c5 = 0 AND (SELECT count(*) FROM monthly_snapshots) = :snaps_pre,
  'catch-up re-tick → fires once only (no duplicate snapshot work)');

-- ---------- 8. skip-zone marking (48–96h instants → 'skipped' ledger rows) --
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM job_runs WHERE job_key='daily-recalc-digest'
      AND scope_key='client:cc000005-0000-0000-0000-000000000001'
      AND period_started_at='2026-10-30 04:00+00' AND status='skipped'),
  'skip zone: Oct-30 04:00Z daily instant marked skipped (54h old at Nov-1 tick)');

-- ---------- 9. stub dispatch + partner scope ----------
SELECT public.tick('2026-11-03 10:00+00') AS t6 \gset
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs
    WHERE started_at='2026-11-03 10:00+00' AND status='success'
      AND (scope_key LIKE 'client:cc000005-%' OR scope_key LIKE 'partner:bb000005-%')) = 15,
  'tick Nov-3 10:00Z: 15 TESTFIX claims — daily Nov-2/3 ×6, monday ×3, bd1-gen ×3, usage ×3');
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs WHERE job_key='monday-agenda' AND status='success'
     AND scope_key LIKE 'client:cc000005-%' AND detail ? 'stub') = 3,
  'stub dispatch: monday-agenda catch-up ×3 record detail.stub owner');
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs WHERE job_key='partner-usage-report'
     AND scope_key LIKE 'partner:bb000005-%' AND status='success') = 3,
  'partner-scope job: one run per TESTFIX practice (3 practices)');
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs WHERE job_key='monthly-bd1-gen'
     AND period_started_at='2026-11-02 04:00+00' AND status='success'
     AND scope_key IN ('client:cc000005-0000-0000-0000-000000000001',
                       'client:cc000005-0000-0000-0000-000000000003')) = 2,
  'bd1-gen: Nov-2 06:00 SAST fired for ZA clients (stub → W1-03)');

-- ---------- 10. overdue events at later local dates ----------
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM notification_events WHERE kind='maintenance_input_overdue'
      AND payload->>'mti_id'='e9000005-0000-0000-0000-000000000004'),
  '§10: maintenance_input_overdue emitted once for overdue MM-16 instance');
SELECT pg_temp.t(
  (SELECT count(*) FROM notification_events WHERE kind='maintenance_input_overdue'
     AND payload->>'mti_id'='e9000005-0000-0000-0000-000000000004') = 1,
  '§10 dedupe: exactly one event per overdue instance across repeated ticks');

-- ---------- 11. stale-lease adoption: same row re-driven, never duplicated --
INSERT INTO job_runs (job_key, scope_key, period_started_at, started_at,
                      locked_until, status, detail)
VALUES ('daily-recalc-digest','client:cc000005-0000-0000-0000-000000000003',
        '2026-11-04 04:00+00','2026-11-04 04:00+00','2026-11-04 04:05+00','running',
        '{"claimed_by":"zombie"}')
ON CONFLICT (job_key, scope_key, period_started_at) DO UPDATE
  SET status='running', locked_until='2026-11-04 04:05+00',
      started_at='2026-11-04 04:00+00', finished_at=NULL,
      detail='{"claimed_by":"zombie"}'::jsonb;
SELECT (public.tick('2026-11-04 10:00+00') ->> 'claimed')::int AS c7 \gset
SELECT pg_temp.t(
  (SELECT count(*) FROM job_runs WHERE job_key='daily-recalc-digest'
     AND scope_key='client:cc000005-0000-0000-0000-000000000003'
     AND period_started_at='2026-11-04 04:00+00') = 1
  AND (SELECT status FROM job_runs WHERE job_key='daily-recalc-digest'
     AND scope_key='client:cc000005-0000-0000-0000-000000000003'
     AND period_started_at='2026-11-04 04:00+00') = 'success'
  AND (SELECT detail ? 'adopted_at' FROM job_runs WHERE job_key='daily-recalc-digest'
     AND scope_key='client:cc000005-0000-0000-0000-000000000003'
     AND period_started_at='2026-11-04 04:00+00'),
  'stale lease: expired running row adopted + re-driven to success, no dup row');

-- ---------- 12. monthly_report_late trigger (W1S fixture) ----------
-- created here deliberately: a 4th client scope would skew §3–§9 claim counts
INSERT INTO practices (id, name) VALUES
  ('b4000000-0000-0000-0000-000000000001', 'W1S Ops');
INSERT INTO client_orgs (id, practice_id, name, jurisdiction, timezone) VALUES
  ('c4000000-0000-0000-0000-000000000001', 'b4000000-0000-0000-0000-000000000001',
   'W1S Late Co', 'ZA', 'Africa/Johannesburg');
INSERT INTO programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d4000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000001',
   'W1S Late Programme', DATE '2026-11-02', 4);
INSERT INTO programme_reports (id, programme_id, period, status, due_on) VALUES
  ('f4000000-0000-0000-0000-000000000001', 'd4000000-0000-0000-0000-000000000001',
   '2026-11', 'draft', DATE '2026-11-06');

SELECT (public.tick('2026-11-10 06:00+00') ->> 'claimed')::int AS c8 \gset
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM notification_events WHERE kind='monthly_report_late'
      AND payload->>'report_id'='f4000000-0000-0000-0000-000000000001'),
  '§10: monthly_report_late emitted for draft report past due_on (Nov-6 < Nov-10)');

-- ---------- 13. enabled flag gates firing ----------
UPDATE scheduled_jobs SET enabled=false WHERE key='monday-agenda';
SELECT (public.tick('2026-11-16 07:00+00') ->> 'claimed')::int AS c9 \gset
SELECT pg_temp.t(NOT EXISTS (
    SELECT 1 FROM job_runs WHERE job_key='monday-agenda'
      AND period_started_at='2026-11-16 04:00+00'),
  'disabled job: no Monday run while enabled=false');
UPDATE scheduled_jobs SET enabled=true WHERE key='monday-agenda';
SELECT (public.tick('2026-11-16 07:00+00') ->> 'claimed')::int AS c10 \gset
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM job_runs WHERE job_key='monday-agenda'
      AND period_started_at='2026-11-16 04:00+00' AND status='success'),
  're-enabled job: Monday instant fires on next tick (catch-up within window)');

-- ---------- 14. ops guard: tenant JWT cannot claim/tick ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4000000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.claim_job('daily-recalc-digest');
    PERFORM pg_temp.t(false,'tenant user denied claim_job');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'tenant user denied claim_job: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.tick();
    PERFORM pg_temp.t(false,'tenant user denied tick');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'tenant user denied tick: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- platform_admin MAY drive the runner (ops path)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4000000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.claim_job('monday-agenda','2026-10-09 02:00+00')) = 0,
  'platform_admin claim_job allowed (0 due → clean empty set)');
ROLLBACK;

-- ---------- 15. ledger write surface: no direct authenticated writes -------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4000000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t((SELECT count(*) FROM job_runs) >= 0
  AND (SELECT count(*) FROM scheduled_jobs) = 6,
  'authenticated can READ job_runs + scheduled_jobs (catalogue policies)');
DO $$
BEGIN
  BEGIN
    INSERT INTO job_runs (job_key, scope_key, period_started_at)
    VALUES ('daily-recalc-digest','client:x','2026-01-01');
    PERFORM pg_temp.t(false,'authenticated has no INSERT on job_runs');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true,'authenticated has no INSERT on job_runs (definer-only)');
  END;
END $$;
ROLLBACK;

-- ---------- 16. idempotency key is real: dup (job,scope,period) rejected ----
DO $$
BEGIN
  BEGIN
    INSERT INTO job_runs (job_key, scope_key, period_started_at)
    SELECT 'daily-recalc-digest','client:cc000005-0000-0000-0000-000000000001',
           '2026-10-09 04:00+00';
    PERFORM pg_temp.t(false,'duplicate (job,scope,period) insert rejected');
  EXCEPTION WHEN unique_violation THEN
    PERFORM pg_temp.t(true,'duplicate (job,scope,period) insert rejected (UNIQUE)');
  END;
END $$;

-- ---------- teardown ----------
DELETE FROM job_runs          WHERE id NOT IN (SELECT id FROM w1s_pre_runs);
DELETE FROM job_runs
 WHERE scope_key LIKE 'client:cc000005-%' OR scope_key LIKE 'partner:bb000005-%'
    OR scope_key LIKE 'client:c4000000-%' OR scope_key LIKE 'partner:b4000000-%';
DELETE FROM notification_events WHERE id NOT IN (SELECT id FROM w1s_pre_events);
DELETE FROM monthly_snapshots WHERE id NOT IN (SELECT id FROM w1s_pre_snaps);
DELETE FROM role_assignments WHERE user_id IN
  (SELECT id FROM users WHERE email LIKE '%@w1s.test');
DELETE FROM users WHERE email LIKE '%@w1s.test';
DELETE FROM auth.users WHERE email LIKE '%@w1s.test';
DELETE FROM programme_reports WHERE programme_id IN
  (SELECT id FROM programmes WHERE name LIKE 'W1S%');
DELETE FROM programmes WHERE name LIKE 'W1S%';
DELETE FROM client_orgs WHERE name LIKE 'W1S%';
DELETE FROM practices WHERE name LIKE 'W1S%';
-- days_overdue/rag recalcs are left in place: correct engine outputs, idempotent.

-- re-arm the real-clock tick exactly as the migration left it
DO $$
BEGIN
  IF to_regnamespace('cron') IS NOT NULL
     AND to_regclass('w1s_cron_was_armed') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='securepath-tick') THEN
    PERFORM cron.schedule('securepath-tick','* * * * *','SELECT public.tick()');
  END IF;
END $$;
DROP TABLE IF EXISTS w1s_cron_was_armed;

\echo '=== e2e_scheduler checks done ==='
