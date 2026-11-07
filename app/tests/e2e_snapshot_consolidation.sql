-- ============================================================================
-- #95 — snapshot-consolidation checks (migration 20261106000023).
--
-- Proves the two §9.5 snapshot call paths now write ONE calculation
-- (sched_take_monthly_snapshot delegates to write_monthly_snapshot →
-- monthly_snapshot_figures), and that consumers which used to assume one
-- programme_reports row per (programme, period) resolve the right row once
-- an NFR-09 correction opens a second version:
--   * partner_console_rag / sched_daily_sweep's monthly_report_late:
--     "late" is a period property — a period with ANY issued version is not
--     late, even while its correction draft sits open past due_on;
--   * list_programmes: report_status/due_on resolve the latest VERSION of
--     the latest period (the open correction is the live document);
--   * create_monthly_report returns the open draft version, not the
--     superseded issued row.
--
-- Self-contained: own W95 namespace (@w95.test users, 'W95 …' names, uuid
-- prefixes a95c/b95c/c95c/d95c/e95c), never touches the TESTFIX world.
-- Simulates JWT callers via SET ROLE authenticated + request.jwt.claims.
-- Re-runnable: wipes its namespace first and tears it down at the end.
--
-- Run (CI/ephemeral stack; scratch image needs the auth shim — see
-- e2e_template_engine.sql's header):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -f app/tests/e2e_snapshot_consolidation.sql
-- ============================================================================
\set QUIET on
\pset pager off
\o /dev/null

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.t(boolean, text) TO authenticated;

-- ---------- teardown of any previous run ----------
CREATE OR REPLACE FUNCTION pg_temp.w95_wipe() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  ALTER TABLE public.programme_reports DISABLE TRIGGER report_transition_gate;
  DELETE FROM public.programme_reports WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W95%');
  ALTER TABLE public.programme_reports ENABLE TRIGGER report_transition_gate;
  DELETE FROM public.monthly_snapshots WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W95%');
  DELETE FROM public.audit_log WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W95%');
  DELETE FROM public.notification_events
   WHERE (scope->>'practice_id')::uuid IN
         (SELECT id FROM public.practices WHERE name LIKE 'W95%')
      OR (scope->>'client_org_id')::uuid IN
         (SELECT c.id FROM public.client_orgs c JOIN public.practices p
            ON p.id = c.practice_id WHERE p.name LIKE 'W95%');
  DELETE FROM public.maintenance_task_instances WHERE task_template_id IN
    (SELECT id FROM public.maintenance_task_templates WHERE programme_id IN
      (SELECT id FROM public.programmes WHERE name LIKE 'W95%'));
  DELETE FROM public.maintenance_task_templates WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W95%');
  DELETE FROM public.kpi_actuals WHERE kpi_id IN
    (SELECT id FROM public.kpis WHERE programme_id IN
      (SELECT id FROM public.programmes WHERE name LIKE 'W95%'));
  DELETE FROM public.kpis WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W95%');
  DELETE FROM public.evidence_items WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W95%');
  DELETE FROM public.register_items WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W95%');
  DELETE FROM public.activities WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W95%');
  DELETE FROM public.designations WHERE client_org_id IN
    (SELECT c.id FROM public.client_orgs c JOIN public.practices p ON p.id = c.practice_id
      WHERE p.name LIKE 'W95%');
  DELETE FROM public.role_assignments WHERE user_id IN
    (SELECT id FROM public.users WHERE email LIKE '%@w95.test');
  DELETE FROM public.programmes WHERE name LIKE 'W95%';
  DELETE FROM public.programme_template_versions WHERE template_id IN
    (SELECT id FROM public.programme_templates WHERE framework = 'w95_test');
  DELETE FROM public.programme_templates WHERE framework = 'w95_test';
  DELETE FROM public.client_orgs WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W95%');
  DELETE FROM public.users WHERE email LIKE '%@w95.test';
  DELETE FROM auth.users WHERE email LIKE '%@w95.test';
  DELETE FROM public.practices WHERE name LIKE 'W95%';
END $$;
SELECT pg_temp.w95_wipe();

-- ---------- fixtures ----------
INSERT INTO auth.users (id, instance_id, email, encrypted_password, aud, role,
    email_confirmed_at, created_at, updated_at, confirmation_token,
    email_change, email_change_token_new, email_change_token_current,
    recovery_token, reauthentication_token, phone_change, phone_change_token,
    raw_app_meta_data, raw_user_meta_data)
SELECT u.id, '00000000-0000-0000-0000-000000000000', u.email,
    crypt('x', gen_salt('bf')), 'authenticated', 'authenticated',
    now(), now(), now(), '', '', '', '', '', '', '', '',
    '{"provider":"email","providers":["email"]}', '{}'
FROM (VALUES
  ('a95c0000-0000-0000-0000-000000000001'::uuid, 'pl@w95.test'),
  ('a95c0000-0000-0000-0000-000000000002'::uuid, 'ao@w95.test')
) AS u(id, email);
INSERT INTO public.users (id, email, full_name)
SELECT id, email, 'W95 ' || split_part(email, '@', 1) FROM auth.users WHERE email LIKE '%@w95.test';

INSERT INTO public.practices (id, name) VALUES
  ('b95c0000-0000-0000-0000-00000000000a', 'W95 Alpha');
INSERT INTO public.client_orgs (id, practice_id, name) VALUES   -- jurisdiction NULL → weekday calendar
  ('c95c0000-0000-0000-0000-000000000001', 'b95c0000-0000-0000-0000-00000000000a', 'W95 Client One');

INSERT INTO public.programme_templates (id, framework, edition, name)
VALUES ('e95c0000-0000-0000-0000-000000000001', 'w95_test', 'W95', 'W95 Template');
INSERT INTO public.programme_template_versions (id, template_id, number, status, content)
VALUES ('e95c0001-0000-0000-0000-000000000001', 'e95c0000-0000-0000-0000-000000000001', 1, 'draft',
  '{"report_structure": {"due_business_day": 5, "sections": [
      {"key": "executive_summary", "title": "W95 Summary"},
      {"key": "register_progress"}]}}'::jsonb);

-- P1: the consolidation subject · P2: report-path snapshot · P3: a genuinely
-- late (never issued) period. programme_rag stored 'Green' so only the
-- report-lateness leg can force the console RAG Red in the checks below.
INSERT INTO public.programmes (id, client_org_id, template_version_id, name, start_date,
                               total_weeks, report_due_business_day, programme_rag) VALUES
  ('d95c0000-0000-0000-0000-000000000001', 'c95c0000-0000-0000-0000-000000000001',
   'e95c0001-0000-0000-0000-000000000001', 'W95 Programme One', DATE '2026-09-07', 20, 5, 'Green'),
  ('d95c0000-0000-0000-0000-000000000002', 'c95c0000-0000-0000-0000-000000000001',
   'e95c0001-0000-0000-0000-000000000001', 'W95 Programme Two', DATE '2026-09-07', 20, 5, 'Green'),
  ('d95c0000-0000-0000-0000-000000000003', 'c95c0000-0000-0000-0000-000000000001',
   'e95c0001-0000-0000-0000-000000000001', 'W95 Programme Three', DATE '2026-09-07', 20, 5, 'Green');

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a95c0000-0000-0000-0000-000000000001','client','programme_lead','client','c95c0000-0000-0000-0000-000000000001'),
  ('a95c0000-0000-0000-0000-000000000002','client','accountable_officer','client','c95c0000-0000-0000-0000-000000000001');

-- non-trivial figure inputs on P1 (every canonical key exercised)
INSERT INTO public.activities (id, programme_id, ref, text, start_week, end_week, status) VALUES
  ('f95c0000-0000-0000-0000-000000000001','d95c0000-0000-0000-0000-000000000001','W95-A1','done',1,1,'Complete'),
  ('f95c0000-0000-0000-0000-000000000002','d95c0000-0000-0000-0000-000000000001','W95-A2','overdue',1,1,'In progress');
-- 'Closed' is set only by the §9.4 ritual — staged directly here as fixture
-- data (the closure gates are suspended for the insert, then re-armed)
ALTER TABLE public.register_items DISABLE TRIGGER register_closure_data_gate;
ALTER TABLE public.register_items DISABLE TRIGGER register_closure_refs_on_insert;
INSERT INTO public.register_items (id, programme_id, ref, finding, priority, status) VALUES
  ('f95c0001-0000-0000-0000-000000000001','d95c0000-0000-0000-0000-000000000001','W95-R1','closed high','High','Closed'),
  ('f95c0001-0000-0000-0000-000000000002','d95c0000-0000-0000-0000-000000000001','W95-R2','still open','Medium','In progress');
ALTER TABLE public.register_items ENABLE TRIGGER register_closure_data_gate;
ALTER TABLE public.register_items ENABLE TRIGGER register_closure_refs_on_insert;
INSERT INTO public.evidence_items (id, programme_id, link, uploaded_by, review_stage) VALUES
  ('f95c0002-0000-0000-0000-000000000001','d95c0000-0000-0000-0000-000000000001',
   'https://w95.test/e1','a95c0000-0000-0000-0000-000000000001','verification');
INSERT INTO public.kpis (id, programme_id, name) VALUES
  ('e95c0002-0000-0000-0000-000000000001','d95c0000-0000-0000-0000-000000000001','W95 availability');
INSERT INTO public.kpi_actuals (kpi_id, month, value, entered_by) VALUES
  ('e95c0002-0000-0000-0000-000000000001', DATE '2026-10-01', 99,
   'a95c0000-0000-0000-0000-000000000001');
INSERT INTO public.maintenance_task_templates (id, programme_id, code, task, timing_rule) VALUES
  ('e95c0003-0000-0000-0000-000000000001','d95c0000-0000-0000-0000-000000000001',
   'W95-M1','W95 monthly check','{"window":"before_month_end"}'),
  ('e95c0003-0000-0000-0000-000000000002','d95c0000-0000-0000-0000-000000000001',
   'W95-M2','W95 second check','{"window":"before_month_end"}');
INSERT INTO public.maintenance_task_instances (id, task_template_id, period, status, due_date, evidence_exempt_reason) VALUES
  ('e95c0004-0000-0000-0000-000000000001','e95c0003-0000-0000-0000-000000000001','2026-10','Complete',NULL,'W95 test'),
  ('e95c0004-0000-0000-0000-000000000002','e95c0003-0000-0000-0000-000000000002','2026-10','Pending',DATE '2026-10-20',NULL);
-- a light figure input on P2 so its report-path snapshot is non-trivial too
INSERT INTO public.register_items (id, programme_id, ref, finding, priority, status) VALUES
  ('f95c0001-0000-0000-0000-000000000003','d95c0000-0000-0000-0000-000000000002','W95-R3','open on P2','Medium','Not started');


-- ============================================================================
-- A. one writer: scheduler path stores the canonical calculation
-- ============================================================================
SELECT public.sched_take_monthly_snapshot('d95c0000-0000-0000-0000-000000000001',
                                          '2026-10', DATE '2026-10-30') AS wrote1 \gset
SELECT pg_temp.t(:'wrote1' = 't',
  '01 scheduler path writes the missing snapshot (returns true)');
SELECT pg_temp.t(
  (SELECT s.snapshot = public.monthly_snapshot_figures(
        'd95c0000-0000-0000-0000-000000000001', DATE '2026-10-01', '2026-10-30'::timestamptz)
      AND s.taken_at = '2026-10-30'::timestamptz
     FROM public.monthly_snapshots s
    WHERE s.programme_id = 'd95c0000-0000-0000-0000-000000000001' AND s.period = '2026-10'),
  '02 scheduler snapshot is byte-identical to the canonical calculation');
SELECT public.sched_take_monthly_snapshot('d95c0000-0000-0000-0000-000000000001',
                                          '2026-10', DATE '2026-10-30') AS wrote2 \gset
SELECT pg_temp.t(:'wrote2' = 'f'
  AND (SELECT count(*) FROM public.monthly_snapshots
        WHERE programme_id = 'd95c0000-0000-0000-0000-000000000001' AND period = '2026-10') = 1,
  '03 scheduler path stays idempotent (second call false, one row)');
-- the figures really are the non-trivial ones (regression-guard vs the old
-- inline calc, which would have disagreed on rag/overdue/kpi/taken_at)
SELECT pg_temp.t(
  (SELECT (s.snapshot ->> 'activities_complete')::int = 1
      AND (s.snapshot ->> 'register_closed')::int = 1
      AND (s.snapshot ->> 'register_open')::int = 1
      AND (s.snapshot ->> 'high_priority_closed')::int = 1
      AND (s.snapshot ->> 'evidence_pending')::int = 1
      AND (s.snapshot ->> 'maintenance_done')::int = 1
      AND (s.snapshot ->> 'maintenance_overdue')::int = 1
      AND s.snapshot -> 'kpi_actuals' = '{"W95 availability": 99}'::jsonb
     FROM public.monthly_snapshots s
    WHERE s.programme_id = 'd95c0000-0000-0000-0000-000000000001' AND s.period = '2026-10'),
  '04 scheduler snapshot carries the canonical figure values');

-- ============================================================================
-- B. one writer: report path writes the same row shape the scheduler would
-- ============================================================================
-- create_monthly_report on the service path (auth.uid() NULL honours the
-- injected clock): Oct-2026 snapshot day = Fri 2026-10-30, as_of = its 18:00
SELECT public.create_monthly_report('d95c0000-0000-0000-0000-000000000002', '2026-10',
                                    '2026-11-02 09:00+00') AS rp2 \gset
SELECT pg_temp.t(
  (SELECT s.snapshot = public.monthly_snapshot_figures(
        'd95c0000-0000-0000-0000-000000000002', DATE '2026-10-01', '2026-10-30 18:00'::timestamptz)
     FROM public.monthly_snapshots s
    WHERE s.programme_id = 'd95c0000-0000-0000-0000-000000000002' AND s.period = '2026-10'),
  '05 report path also stores the canonical calculation');
-- identical figures whoever writes first: scheduler sees the report-path row
SELECT public.sched_take_monthly_snapshot('d95c0000-0000-0000-0000-000000000002',
                                          '2026-10', DATE '2026-10-30') AS wrote3 \gset
SELECT pg_temp.t(:'wrote3' = 'f'
  AND (SELECT count(*) FROM public.monthly_snapshots
        WHERE programme_id = 'd95c0000-0000-0000-0000-000000000002' AND period = '2026-10') = 1,
  '06 cross-path idempotency: scheduler does not rewrite the report-path row');
-- and the canonical writer directly, for a second period on P1
SELECT public.write_monthly_snapshot('d95c0000-0000-0000-0000-000000000001',
                                     DATE '2026-09-01', '2026-09-30 18:00'::timestamptz) AS snap1 \gset
SELECT pg_temp.t(
  (SELECT s.snapshot = public.monthly_snapshot_figures(
        'd95c0000-0000-0000-0000-000000000001', DATE '2026-09-01', '2026-09-30 18:00'::timestamptz)
     FROM public.monthly_snapshots s WHERE s.id = :'snap1'),
  '07 canonical writer row equals monthly_snapshot_figures (both periods)');

-- ============================================================================
-- C. a correction puts TWO versions on one period, same snapshot
-- ============================================================================
-- September report on P1, driven to issued on the service/JWT paths
SELECT public.create_monthly_report('d95c0000-0000-0000-0000-000000000001', '2026-09',
                                    '2026-10-01 09:00+00') AS r1 \gset
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a95c0000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.update_report_draft(:'r1',
  '{"narrative":{"executive_summary":"W95 September.","register_progress":"W95 movement."}}');
SELECT public.transition_report(:'r1', 'inputs_complete');
SELECT public.transition_report(:'r1', 'ao_review');
SET request.jwt.claims = '{"sub":"a95c0000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT public.transition_report(:'r1', 'signed');
SET request.jwt.claims = '{"sub":"a95c0000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.transition_report(:'r1', 'issued');
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status = 'issued' AND due_on = DATE '2026-10-07' AND snapshot_id = :'snap1'
     FROM public.programme_reports WHERE id = :'r1'),
  '08 v1 issued, bound to the 2026-09 snapshot, due 2026-10-07');

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a95c0000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.create_report_correction(:'r1', 'W95 narrative typo') AS r1v2 \gset
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT count(*) = 2 AND count(DISTINCT snapshot_id) = 1
      AND max(version) = 2 AND count(*) FILTER (WHERE status <> 'issued') = 1
     FROM public.programme_reports
    WHERE programme_id = 'd95c0000-0000-0000-0000-000000000001' AND period = '2026-09'),
  '09 second version on the same period shares the one snapshot row');

-- ============================================================================
-- D. consumers resolve the right row
-- ============================================================================
-- report_status/report_due_on = latest VERSION of the latest period:
-- issued v1 + open correction v2 → 'draft' (the live document)
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a95c0000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT report_status = 'draft' AND report_due_on = DATE '2026-10-07'
     FROM public.list_programmes() WHERE programme_id = 'd95c0000-0000-0000-0000-000000000001'),
  '10 list_programmes resolves the open correction, not the superseded issue');
RESET ROLE; SET request.jwt.claims = '';

-- "late" is a period property: an issued version exists → not late, even
-- though the open correction draft sits past due_on
SELECT pg_temp.t(
  public.partner_console_rag('d95c0000-0000-0000-0000-000000000001',
                             '2026-11-09 09:00+00') = 'Green',
  '11 console RAG not forced Red by an open correction of an issued period');
-- P3's 2026-09 draft is genuinely late (no issued version) → still Red
SELECT public.create_monthly_report('d95c0000-0000-0000-0000-000000000003', '2026-09',
                                    '2026-10-01 09:00+00') AS r3 \gset
SELECT pg_temp.t(
  public.partner_console_rag('d95c0000-0000-0000-0000-000000000003',
                             '2026-11-09 09:00+00') = 'Red',
  '12 console RAG still forced Red for a never-issued past-due period');

-- sched_daily_sweep's monthly_report_late: emitted for the unissued period,
-- never for P1's issued period (v1 issued, v2 draft open — both report ids
-- must stay silent)
SELECT public.sched_daily_sweep('c95c0000-0000-0000-0000-000000000001', DATE '2026-11-09') AS sweep \gset
SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM public.notification_events ne
               WHERE ne.kind = 'monthly_report_late'
                 AND ne.payload->>'report_id' IN (:'r1', :'r1v2')),
  '13 no monthly_report_late for a period that has an issued version');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.notification_events ne
           WHERE ne.kind = 'monthly_report_late'
             AND ne.payload->>'report_id' = :'r3'
             AND ne.payload->>'period' = '2026-09'),
  '14 monthly_report_late still fires for the never-issued period');

-- create_monthly_report idempotency resolves the OPEN version, not the
-- superseded issued row
SELECT public.create_monthly_report('d95c0000-0000-0000-0000-000000000001', '2026-09',
                                    '2026-11-09 09:00+00') AS r1again \gset
SELECT pg_temp.t(:'r1again' = :'r1v2' AND :'r1again' <> :'r1',
  '15 create_monthly_report returns the open correction, not v1');

-- once the correction itself is issued, consumers flip back cleanly
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a95c0000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.transition_report(:'r1v2', 'inputs_complete');
SELECT public.transition_report(:'r1v2', 'ao_review');
SET request.jwt.claims = '{"sub":"a95c0000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT public.transition_report(:'r1v2', 'signed');
SET request.jwt.claims = '{"sub":"a95c0000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.transition_report(:'r1v2', 'issued');
SELECT pg_temp.t(
  (SELECT report_status = 'issued' AND report_due_on = DATE '2026-10-07'
     FROM public.list_programmes() WHERE programme_id = 'd95c0000-0000-0000-0000-000000000001'),
  '16 after v2 issues, list_programmes shows issued again');
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT reference = 'RPT-2026-09-v2' AND status = 'issued'
     FROM public.programme_reports WHERE id = :'r1v2'),
  '17 v2 issued under its own reference; v1 untouched');
SELECT pg_temp.t(
  (SELECT status = 'issued' AND reference = 'RPT-2026-09-v1'
     FROM public.programme_reports WHERE id = :'r1'),
  '18 superseded v1 remains an issued, immutable row');
SELECT pg_temp.t(
  (SELECT count(*) = 1 FROM public.monthly_snapshots
    WHERE programme_id = 'd95c0000-0000-0000-0000-000000000001' AND period = '2026-09'),
  '19 still exactly one snapshot for the two-version period');


-- ---------- teardown ----------
SELECT pg_temp.w95_wipe();
RESET ALL;
