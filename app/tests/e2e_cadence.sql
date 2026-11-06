-- ============================================================================
-- W1-03 cadence engine — psql acceptance checks
-- Covers: generate_maintenance_month (due dates per window, active-from
-- skipped, provider auto-request + notification, IDEMPOTENT re-run, service
-- path + AO path + denials), complete_maintenance_task (FR-MNT-05 evidence-
-- or-exemption), status transitions (incl. exception→RAID via the W1-06
-- trigger), request/receive provider input (FR-MNT-04), generate_checklist
-- quarterly+annual (FR-QTR-01/02, summary pull, idempotent), the FR-MNT-07
-- ao_review report gate + override, and the history/period-status reads.
--
-- Runs against the W0-05 TESTFIX world — apply the fixture pack first with
--   ALTER DATABASE <db> SET securepath.test_fixtures = 'on';
-- (then re-run app/supabase/migrations/20261105000005_test_fixtures.sql).
-- JWT callers simulated via SET ROLE authenticated + request.jwt.claims in
-- the same transaction (e2e_role_assignments pattern).
--
-- Fixture ids (see 20261105000005_test_fixtures.sql):
--   P1 dd000005-..-0001 (Client One, ZA)   P2 dd000005-..-0002 (Client Two, UK)
--   U9  PL programme-scope P1 · U8 AO client-scope C1 · U12 contributor (no
--   write role) · U15 PL programme-scope P2 · U6 partner-B admin (cross)
--   MTT e8000005-..-0001 MM-01 before_month_end (provider marketing -0002)
--       e8000005-..-0002 MM-03 month_end_close
--       e8000005-..-0003 MM-06 report_window bd2 (provider IT -0001)
--       e8000005-..-0004 MM-08 report_window bd2 (active_from A-08: Blocked)
--       e8000005-..-0005 MM-16 report_window bd5 (no provider)
--   MTI e9000005-..-0001/2/3/4 on period '2026-10' (Pending/Complete/
--       Exception/Pending)
--   EV  e1000005-..-0004 decided+accepted · e1000005-..-0001 verification
--   Report f1000005-..-0002 '2026-10' draft
--
-- Due-date expectations (ZA pack holidays: Jan 1, Mar 21, Dec 25, Dec 26 —
-- none in Nov/Dec 2026):
--   MM-01/MM-03 '2026-11' → last BD of Nov = 2026-11-30
--   MM-06 '2026-11' bd2   → 2nd BD of Dec = 2026-12-02
--   MM-16 '2026-11' bd5   → 5th BD of Dec = 2026-12-07
--
-- Run:
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -f app/tests/e2e_cadence.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- gate: the TESTFIX world must be seeded
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.programmes
                  WHERE id = 'dd000005-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'TESTFIX world missing — apply 20261105000005_test_fixtures.sql with securepath.test_fixtures=on first';
  END IF;
  RAISE NOTICE 'PASS 00 fixture gate: TESTFIX P1 present';
END $$;

-- ============================================================================
-- Monthly generation (FR-MNT-02/03/08)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.generate_maintenance_month(
        'dd000005-0000-0000-0000-000000000001', DATE '2026-11-15') AS gen \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(:gen = 4,
  '01 generate_maintenance_month 2026-11: 4 instances (MM-08 skipped)');

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.maintenance_task_instances
           WHERE task_template_id='e8000005-0000-0000-0000-000000000001'
             AND period='2026-11' AND due_date=DATE '2026-11-30'
             AND task_window='before_month_end' AND status='Pending')
  AND EXISTS (SELECT 1 FROM public.maintenance_task_instances
           WHERE task_template_id='e8000005-0000-0000-0000-000000000002'
             AND period='2026-11' AND due_date=DATE '2026-11-30'
             AND task_window='month_end_close')
  AND EXISTS (SELECT 1 FROM public.maintenance_task_instances
           WHERE task_template_id='e8000005-0000-0000-0000-000000000003'
             AND period='2026-11' AND due_date=DATE '2026-12-02'
             AND task_window='report_window')
  AND EXISTS (SELECT 1 FROM public.maintenance_task_instances
           WHERE task_template_id='e8000005-0000-0000-0000-000000000005'
             AND period='2026-11' AND due_date=DATE '2026-12-07'
             AND task_window='report_window'),
  '02 due dates: before_month_end/month_end_close=Nov 30; report_window bd2=Dec 2, bd5=Dec 7');

SELECT pg_temp.t(NOT EXISTS (
    SELECT 1 FROM public.maintenance_task_instances mti
     WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000004'
       AND mti.period='2026-11'),
  '03 FR-MNT-08: MM-08 absent (active_from activity A-08 not Complete)');

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.maintenance_task_instances
           WHERE task_template_id='e8000005-0000-0000-0000-000000000001'
             AND period='2026-11' AND awaiting_provider_input
             AND provider_id='e7000005-0000-0000-0000-000000000002'
             AND provider_requested_at IS NOT NULL)
  AND EXISTS (SELECT 1 FROM public.maintenance_task_instances
           WHERE task_template_id='e8000005-0000-0000-0000-000000000003'
             AND period='2026-11' AND awaiting_provider_input
             AND provider_id='e7000005-0000-0000-0000-000000000001'),
  '04 FR-MNT-04: provider-bound instances generated awaiting-provider');

SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.notification_events
     WHERE kind='maintenance_input_requested'
       AND payload->'provider'->>'contact_email'='it-provider@testfix.test'
       AND (scope->>'programme_id')::uuid='dd000005-0000-0000-0000-000000000001'),
  '05 maintenance_input_requested notification carries the provider channel');

-- IDEMPOTENT: second call same month = zero new rows
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.generate_maintenance_month(
        'dd000005-0000-0000-0000-000000000001', DATE '2026-11-03') AS gen2 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(:gen2 = 0
  AND (SELECT count(*) FROM public.maintenance_task_instances mti
        JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
       WHERE t.programme_id='dd000005-0000-0000-0000-000000000001'
         AND mti.period='2026-11') = 4,
  '06 idempotent: re-generate 2026-11 creates zero new rows');

-- the client's own programme lead on P2 (cross-programme scoping holds)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000015","role":"authenticated"}';
SELECT public.generate_maintenance_month(
        'dd000005-0000-0000-0000-000000000002', DATE '2026-11-10') AS gen_p2 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(:gen_p2 = 2,
  '07 P2 lead generates own programme month (2 P1-scoped tasks on P2)');

-- AO path: U8 (accountable_officer, client scope) may run the cadence
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.generate_maintenance_month(
        'dd000005-0000-0000-0000-000000000001', DATE '2027-01-01') AS gen_ao \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(:gen_ao = 4,
  '08 accountable officer may run generation (AO-or-lead guard)');

-- service path: no JWT (auth.uid() NULL) — the scheduler caller
SET request.jwt.claims = '';
SELECT public.generate_maintenance_month(
        'dd000005-0000-0000-0000-000000000001', DATE '2026-12-01') AS gen_svc \gset
SELECT pg_temp.t(:gen_svc = 4,
  '09 service path (auth.uid() NULL) generates for the scheduler');

-- denials
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.generate_maintenance_month(
      'dd000005-0000-0000-0000-000000000001', DATE '2027-02-01');
    PERFORM pg_temp.t(false, '10 contributor (no cadence role) generate denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '10 contributor (no cadence role) generate denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.generate_maintenance_month(
      'dd000005-0000-0000-0000-000000000001', DATE '2027-02-01');
    PERFORM pg_temp.t(false, '11 cross-partner generate denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '11 cross-partner generate denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- Completion (FR-MNT-05) + status transitions
-- ============================================================================
-- Nov MM-03 instance id
SELECT mti.id AS mti_mm03 FROM public.maintenance_task_instances mti
 WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000002'
   AND mti.period='2026-11' \gset
SELECT mti.id AS mti_mm16 FROM public.maintenance_task_instances mti
 WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000005'
   AND mti.period='2026-11' \gset
SELECT mti.id AS mti_mm01 FROM public.maintenance_task_instances mti
 WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000001'
   AND mti.period='2026-11' \gset
SELECT mti.id AS mti_dec16 FROM public.maintenance_task_instances mti
 WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000005'
   AND mti.period='2026-12' \gset

-- complete with an exemption reason (no evidence)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.complete_maintenance_task(:'mti_mm03'::uuid, NULL,
        'TESTFIX no DSRs received this month — none applies') \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.maintenance_task_instances WHERE id=:'mti_mm03'::uuid) = 'Complete'
  AND (SELECT evidence_exempt_reason FROM public.maintenance_task_instances
        WHERE id=:'mti_mm03'::uuid) IS NOT NULL
  AND (SELECT completed_on FROM public.maintenance_task_instances
        WHERE id=:'mti_mm03'::uuid) IS NOT NULL,
  '12 FR-MNT-05: complete with recorded exemption reason');

-- complete with ACCEPTED evidence (EV4 is decided + accepted)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.complete_maintenance_task(:'mti_mm16'::uuid,
        'e1000005-0000-0000-0000-000000000004') \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.maintenance_task_instances WHERE id=:'mti_mm16'::uuid) = 'Complete'
  AND (SELECT evidence_id FROM public.maintenance_task_instances
        WHERE id=:'mti_mm16'::uuid) = 'e1000005-0000-0000-0000-000000000004',
  '13 complete with accepted evidence attached');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.notification_events
     WHERE kind='maintenance_task_completed'
       AND (payload->>'maintenance_task_instance_id')::uuid = :'mti_mm16'::uuid),
  '14 completion writes a maintenance_task_completed notification_event');

-- FR-MNT-05 refusals (psql vars do not interpolate inside $$ bodies — the
-- Nov MM-01 id is resolved by subquery instead)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE v_i uuid;
BEGIN
  SELECT mti.id INTO v_i FROM public.maintenance_task_instances mti
   WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000001'
     AND mti.period='2026-11';
  BEGIN
    PERFORM public.complete_maintenance_task(v_i, NULL, NULL);
    PERFORM pg_temp.t(false, '15 complete with no evidence AND no reason refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '15 complete with no evidence AND no reason refused: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.complete_maintenance_task(v_i,
            'e1000005-0000-0000-0000-000000000001', NULL);   -- verification, not accepted
    PERFORM pg_temp.t(false, '16 unaccepted evidence refused (FR-MNT-05)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '16 unaccepted evidence refused: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
DECLARE v_i uuid;
BEGIN
  SELECT mti.id INTO v_i FROM public.maintenance_task_instances mti
   WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000001'
     AND mti.period='2026-11';
  BEGIN
    PERFORM public.complete_maintenance_task(v_i, NULL, 'x');
    PERFORM pg_temp.t(false, '17 contributor cannot complete a task');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '17 contributor cannot complete a task: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- status transitions on the Nov MM-01 instance (Pending)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.update_maintenance_task_status(:'mti_mm01'::uuid, 'In progress');
SELECT public.update_maintenance_task_status(:'mti_mm01'::uuid, 'Exception',
        'TESTFIX marketing lead did not confirm opt-outs');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.maintenance_task_instances
    WHERE id=:'mti_mm01'::uuid) = 'Exception',
  '18 Pending→In progress→Exception transitions');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.raid_items r
            JOIN public.maintenance_task_instances mti
              ON mti.exception_raid_item_id = r.id
           WHERE mti.id=:'mti_mm01'::uuid
             AND r.source='exception' AND r.type='issue'
             AND r.programme_id='dd000005-0000-0000-0000-000000000001'),
  '19 FR-MNT-06: exception auto-raised a linked RAID issue (W1-06 trigger)');

-- transition refusals (each inside its own claims txn)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE v_dec uuid; v_nov3 uuid;
BEGIN
  SELECT mti.id INTO v_dec FROM public.maintenance_task_instances mti
   WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000005'
     AND mti.period='2026-12';
  SELECT mti.id INTO v_nov3 FROM public.maintenance_task_instances mti
   WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000002'
     AND mti.period='2026-11';
  BEGIN
    PERFORM public.update_maintenance_task_status(v_dec, 'Exception');
    PERFORM pg_temp.t(false, '20 exception without a reason refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '20 exception without a reason refused: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_maintenance_task_status(v_dec, 'Complete');
    PERFORM pg_temp.t(false, '21 Complete via status RPC refused (FR-MNT-05 gate)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '21 Complete via status RPC refused: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_maintenance_task_status(v_nov3, 'In progress');
    PERFORM pg_temp.t(false, '22 Complete is terminal — reopening refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '22 Complete is terminal — reopening refused: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- Provider input round-trip (FR-MNT-04) on the Dec MM-16 instance (Pending)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE v_dec uuid;
BEGIN
  SELECT mti.id INTO v_dec FROM public.maintenance_task_instances mti
   WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000005'
     AND mti.period='2026-12';
  BEGIN
    PERFORM public.request_provider_input(v_dec);   -- template has no provider
    PERFORM pg_temp.t(false, '23 request without any provider refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '23 request without any provider refused: '||SQLERRM);
  END;
END $$;
SELECT public.request_provider_input(:'mti_dec16'::uuid,
        'e7000005-0000-0000-0000-000000000001');                   -- explicit IT provider
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT awaiting_provider_input FROM public.maintenance_task_instances
    WHERE id=:'mti_dec16'::uuid)
  AND (SELECT provider_id FROM public.maintenance_task_instances
    WHERE id=:'mti_dec16'::uuid) = 'e7000005-0000-0000-0000-000000000001',
  '24 request_provider_input marks awaiting + records provider on instance');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.notification_events
     WHERE kind='maintenance_input_requested'
       AND (payload->>'maintenance_task_instance_id')::uuid = :'mti_dec16'::uuid),
  '25 provider request emits maintenance_input_requested');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.receive_provider_input(:'mti_dec16'::uuid,
        'TESTFIX backup report attached', 'testfix/c1/providers/backup-nov.pdf');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  NOT (SELECT awaiting_provider_input FROM public.maintenance_task_instances
        WHERE id=:'mti_dec16'::uuid)
  AND (SELECT jsonb_array_length(provider_input_log)
         FROM public.maintenance_task_instances WHERE id=:'mti_dec16'::uuid) = 2
  AND (SELECT provider_input_log->1->>'file_ref'
         FROM public.maintenance_task_instances WHERE id=:'mti_dec16'::uuid)
      = 'testfix/c1/providers/backup-nov.pdf',
  '26 receive clears awaiting + appends the input to provider_input_log');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE v_dec uuid;
BEGIN
  SELECT mti.id INTO v_dec FROM public.maintenance_task_instances mti
   WHERE mti.task_template_id='e8000005-0000-0000-0000-000000000005'
     AND mti.period='2026-12';
  BEGIN
    PERFORM public.receive_provider_input(v_dec, '  ', NULL);
    PERFORM pg_temp.t(false, '27 empty provider input refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '27 empty provider input refused: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- Quarterly + annual checklists (FR-QTR-01/02)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.generate_checklist('dd000005-0000-0000-0000-000000000001',
        'quarterly', '2027-Q1') AS ck_q \gset
SELECT public.generate_checklist('dd000005-0000-0000-0000-000000000001',
        'annual', '2027') AS ck_a \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(
  (SELECT jsonb_array_length(items) FROM public.checklist_instances
    WHERE id=:'ck_q'::uuid) = 2
  AND (SELECT count(*) FROM public.checklist_instances c,
              jsonb_array_elements(c.items) it
        WHERE c.id=:'ck_q'::uuid
          AND it->>'ref' LIKE 'TESTFIX-Q%'
          AND (it->>'evidence_required')::boolean
          AND NOT (it->>'done')::boolean
          AND it ? 'evidence_id') = 2,
  '28 FR-QTR-01: quarterly checklist instantiated with evidence slots');

SELECT pg_temp.t(
  (SELECT jsonb_array_length(items) FROM public.checklist_instances
    WHERE id=:'ck_a'::uuid) = 2
  AND (SELECT summary ? 'register' AND summary ? 'evidence'
              AND summary ? 'training' AND summary ? 'operational'
              AND summary ? 'months'
         FROM public.checklist_instances WHERE id=:'ck_a'::uuid),
  '29 FR-QTR-02: annual checklist + year-data summary pull');
SELECT pg_temp.t(
  (SELECT (summary->'register'->>'total')::int
     FROM public.checklist_instances WHERE id=:'ck_a'::uuid) = 5,
  '30 annual summary: register total=5 (findings-closed figures present)');

-- idempotent re-run returns the same row, no new rows
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.generate_checklist('dd000005-0000-0000-0000-000000000001',
        'quarterly', '2027-Q1') AS ck_q2 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  :'ck_q2'::uuid = :'ck_q'::uuid
  AND (SELECT count(*) FROM public.checklist_instances
        WHERE programme_id='dd000005-0000-0000-0000-000000000001'
          AND kind='quarterly' AND period='2027-Q1') = 1,
  '31 checklist generation idempotent per period');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.generate_checklist('dd000005-0000-0000-0000-000000000001',
            'monthly', '2027-Q1');
    PERFORM pg_temp.t(false, '32 invalid kind refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '32 invalid kind refused: '||SQLERRM);
  END;
END $$;
DO $$
BEGIN
  BEGIN
    PERFORM public.generate_checklist('dd000005-0000-0000-0000-000000000001',
            'quarterly', '2027-Q5');
    PERFORM pg_temp.t(false, '33 malformed quarterly period refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '33 malformed quarterly period refused: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.generate_checklist('dd000005-0000-0000-0000-000000000001',
            'quarterly', '2027-Q2');
    PERFORM pg_temp.t(false, '34 cross-partner checklist generate denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '34 cross-partner checklist generate denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- FR-MNT-07 report gate (AT-16: blocked from review without a recorded reason)
-- ============================================================================
SELECT pg_temp.t(
  (SELECT count(*) FROM public.report_open_feeding_tasks(
      'dd000005-0000-0000-0000-000000000001','2026-10')) >= 2,
  '35 report_open_feeding_tasks: Oct feeding tasks still open');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
UPDATE public.programme_reports SET status='inputs_complete'
 WHERE id='f1000005-0000-0000-0000-000000000002';
DO $$
BEGIN
  BEGIN
    UPDATE public.programme_reports SET status='ao_review'
     WHERE id='f1000005-0000-0000-0000-000000000002';
    PERFORM pg_temp.t(false, '36 ao_review blocked while feeding tasks open (FR-MNT-07)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '36 ao_review blocked while feeding tasks open (FR-MNT-07): '||SQLERRM);
  END;
END $$;
-- with the programme lead's recorded reason the gate opens
UPDATE public.programme_reports
   SET status='ao_review',
       gate_override_reason='TESTFIX IT provider input late — report issued with caveat'
 WHERE id='f1000005-0000-0000-0000-000000000002';
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.programme_reports
    WHERE id='f1000005-0000-0000-0000-000000000002') = 'ao_review'
  AND (SELECT gate_override_reason FROM public.programme_reports
    WHERE id='f1000005-0000-0000-0000-000000000002') IS NOT NULL,
  '37 gate_override_reason opens ao_review (prints in the report)');

-- ============================================================================
-- Reads: 12-month history + period status
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.maintenance_task_history(
      'e8000005-0000-0000-0000-000000000001', 12)) = 4
  AND (SELECT mti.period FROM public.maintenance_task_history(
      'e8000005-0000-0000-0000-000000000001', 12) mti LIMIT 1) = '2027-01',
  '38 FR-MNT-10 history: MM-01 shows 4 periods, newest first (2027-01)');
SELECT pg_temp.t(
  (SELECT total FROM public.maintenance_period_status(
      'dd000005-0000-0000-0000-000000000001', DATE '2026-11-01')) = 4
  AND (SELECT complete FROM public.maintenance_period_status(
      'dd000005-0000-0000-0000-000000000001', DATE '2026-11-01')) = 2
  AND (SELECT exception FROM public.maintenance_period_status(
      'dd000005-0000-0000-0000-000000000001', DATE '2026-11-01')) = 1,
  '39 maintenance_period_status: 2026-11 → 4 tasks (2 complete, 1 exception)');
ROLLBACK;
