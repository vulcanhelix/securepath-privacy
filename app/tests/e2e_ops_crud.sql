-- ============================================================================
-- W1-06 ops-CRUD RPCs — psql acceptance checks
-- Covers: upsert/get/list weekly log (merge + auto counts + decisions_taken
-- into the append-only ledger), record_kpi_actual (upsert, auto_calc refusal),
-- confirm_kpi_target (AO gate), kpi_status RAG, create/update/resolve/list
-- RAID items (+ status-history ledger), record/list decisions (append-only),
-- and the FR-MNT-06 exception→RAID trigger.
--
-- Runs against the W0-05 TESTFIX world — apply the fixture pack first with
--   ALTER DATABASE <db> SET securepath.test_fixtures = 'on';
-- (then re-run app/supabase/migrations/20261105000005_test_fixtures.sql).
-- JWT callers are simulated via SET ROLE authenticated + request.jwt.claims
-- inside the SAME transaction as the assertions — the pattern proven in
-- e2e_role_assignments.sql / e2e_template_engine.sql.
--
-- Fixture ids used (see 20261105000005_test_fixtures.sql):
--   P1 dd000005-..-0001 (TESTFIX Client One / Partner A), P2 dd000005-..-0002,
--   P3 dd000005-..-0003 (Partner B)
--   U9  aa000005-..-0009  C1 programme_lead (scope programme P1)
--   U8  aa000005-..-0008  C1 accountable_officer (scope client C1)
--   U11 aa000005-..-0011  C1 executive
--   U12 aa000005-..-0012  C1 client_contributor (no programme write role)
--   U15 aa000005-..-0015  C2 programme_lead (scope programme P2 — cross-programme)
--   U6  aa000005-..-0006  Partner B admin (cross-partner)
--   KPIs e4000005-..-0001 requests% (base 70 / target 95 / proposed / manual)
--        e4000005-..-0002 breaches (base 0 / target 0 / auto_calc)
--        e4000005-..-0003 training% (base 50 / target 90 / confirmed)
--   RAID e5000005-..-0001/-0002/-0003 · decision e6000005-..-0001
--   MTI  e9000005-..-0001 (MM-01, period 2026-10, Pending)
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_ops_crud.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- gate: the TESTFIX world must be seeded (fixture pack + securepath.test_fixtures)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.programmes
                  WHERE id = 'dd000005-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'TESTFIX world missing — apply 20261105000005_test_fixtures.sql with securepath.test_fixtures=on first';
  END IF;
  RAISE NOTICE 'PASS 00 fixture gate: TESTFIX P1 present';
END $$;

-- ============================================================================
-- Weekly session log
-- ============================================================================
-- PL writes week 6 incl. a session decision (persists for later checks)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.upsert_weekly_log('dd000005-0000-0000-0000-000000000001', 6,
  '{"session_held":true,"completed":["A-03"],"planned_next":["A-04"],
    "blockers":"TESTFIX wk6 blockers","decisions":"TESTFIX wk6 session note",
    "decisions_taken":[{"raid_item_id":"e5000005-0000-0000-0000-000000000003",
                        "outcome":"TESTFIX keep headcount assumption",
                        "minute_ref":"TESTFIX-MIN-W6"}]}'::jsonb) AS wl \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.weekly_logs WHERE id = :'wl'::uuid),
  '01 upsert_weekly_log: week-6 row created by programme_lead');
SELECT pg_temp.t(
  (SELECT (counts->>'due')::int FROM public.weekly_logs WHERE id = :'wl'::uuid) = 1
  AND (SELECT (counts->>'overdue')::int FROM public.weekly_logs WHERE id = :'wl'::uuid) >= 1,
  '02 upsert_weekly_log: counts auto-filled (due=1 A-04, overdue>=1)');
SELECT pg_temp.t(
  (SELECT week_rag FROM public.weekly_logs WHERE id = :'wl'::uuid) = 'Red',
  '03 upsert_weekly_log: week_rag computed Red (overdue/red activity)');

-- second upsert merges over the same (programme, week) row
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.upsert_weekly_log('dd000005-0000-0000-0000-000000000001', 6,
  '{"session_held":false,"blockers":"TESTFIX wk6 updated"}'::jsonb) AS wl2 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(
  (:'wl2'::uuid) = (:'wl'::uuid)
  AND (SELECT count(*) FROM public.weekly_logs
        WHERE programme_id='dd000005-0000-0000-0000-000000000001' AND week=6) = 1
  AND (SELECT blockers FROM public.weekly_logs WHERE id = :'wl'::uuid) = 'TESTFIX wk6 updated'
  AND (SELECT decisions FROM public.weekly_logs WHERE id = :'wl'::uuid) = 'TESTFIX wk6 session note',
  '04 upsert merge: same row updated, absent keys preserved');

-- session decision landed in the append-only ledger + notified the PL
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.decisions
     WHERE raid_item_id='e5000005-0000-0000-0000-000000000003'
       AND outcome='TESTFIX keep headcount assumption'
       AND minute_ref='TESTFIX-MIN-W6'),
  '05 decisions_taken: session decision recorded into append-only ledger');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.notification_events
     WHERE kind='decision_recorded'
       AND (scope->>'programme_id')::uuid='dd000005-0000-0000-0000-000000000001'),
  '06 decision_recorded notification_event emitted for the programme lead');

-- reads
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT w.id FROM public.get_weekly_log('dd000005-0000-0000-0000-000000000001', 6) w)
    = :'wl'::uuid,
  '07 get_weekly_log returns the week-6 row');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_weekly_logs('dd000005-0000-0000-0000-000000000001')) >= 3,
  '08 list_weekly_logs: fixture weeks 4+5 plus new week 6');
ROLLBACK;

-- denials: cross-programme, cross-partner, non-write role, out-of-range week
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000015","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.upsert_weekly_log('dd000005-0000-0000-0000-000000000001', 6, '{}');
    PERFORM pg_temp.t(false, '09 cross-programme weekly-log write denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '09 cross-programme weekly-log write denied: '||SQLERRM);
  END;
END $$;
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_weekly_logs('dd000005-0000-0000-0000-000000000001')) = 0,
  '10 cross-programme read: C2 lead sees none of P1 logs');
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.upsert_weekly_log('dd000005-0000-0000-0000-000000000001', 6, '{}');
    PERFORM pg_temp.t(false, '11 cross-partner weekly-log write denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '11 cross-partner weekly-log write denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.upsert_weekly_log('dd000005-0000-0000-0000-000000000001', 6, '{}');
    PERFORM pg_temp.t(false, '12 contributor (no programme role) write denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '12 contributor (no programme role) write denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- out-of-range week: must run as a user WITH write rights so the range guard
-- (not the role guard) is what fires
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.upsert_weekly_log('dd000005-0000-0000-0000-000000000001', 99, '{}');
    PERFORM pg_temp.t(false, '13 out-of-range week rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '13 out-of-range week rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- KPIs
-- ============================================================================
-- record a manual actual then upsert the same month (persists)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.record_kpi_actual('e4000005-0000-0000-0000-000000000001',
        DATE '2026-10-01', 80, 'TESTFIX october reading') AS ka \gset
SELECT public.record_kpi_actual('e4000005-0000-0000-0000-000000000001',
        DATE '2026-10-01', 97, 'TESTFIX october corrected') AS ka2 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(
  (SELECT count(*) FROM public.kpi_actuals
    WHERE kpi_id='e4000005-0000-0000-0000-000000000001' AND month=DATE '2026-10-01') = 1
  AND (SELECT value FROM public.kpi_actuals WHERE id = :'ka2'::uuid) = 97
  AND :'ka2'::uuid = :'ka'::uuid,
  '14 record_kpi_actual: one row per kpi+month, re-record updates value');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.record_kpi_actual('e4000005-0000-0000-0000-000000000002',
            DATE '2026-10-01', 0, 'TESTFIX manual breach count');
    PERFORM pg_temp.t(false, '15 auto_calc kpi rejects manual actual (FR-KPI-02)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '15 auto_calc kpi rejects manual actual: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000015","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.record_kpi_actual('e4000005-0000-0000-0000-000000000001',
            DATE '2026-10-01', 50, 'TESTFIX cross-programme write');
    PERFORM pg_temp.t(false, '16 cross-programme kpi actual denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '16 cross-programme kpi actual denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- status + RAG (97 >= target 95 → Green; training 64 between base 50 and target
-- 90 → Amber; breaches has no actual → rag NULL)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.kpi_status('dd000005-0000-0000-0000-000000000001')) = 3,
  '17 kpi_status returns all three P1 KPIs');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.kpi_status('dd000005-0000-0000-0000-000000000001') s
     WHERE s.kpi_id='e4000005-0000-0000-0000-000000000001'
       AND s.latest_value = 97 AND s.latest_month = DATE '2026-10-01'
       AND s.rag = 'Green'),
  '18 kpi_status: requests KPI actual 97 vs target 95 → Green');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.kpi_status('dd000005-0000-0000-0000-000000000001') s
     WHERE s.kpi_id='e4000005-0000-0000-0000-000000000003' AND s.rag = 'Amber')
  AND EXISTS (
    SELECT 1 FROM public.kpi_status('dd000005-0000-0000-0000-000000000001') s
     WHERE s.kpi_id='e4000005-0000-0000-0000-000000000002' AND s.rag IS NULL),
  '19 kpi_status: training 64 in (50,90) → Amber; no-actual breaches → NULL rag');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_kpis('dd000005-0000-0000-0000-000000000001')) = 3,
  '20 list_kpis returns the P1 KPI set');
ROLLBACK;

-- FR-KPI-03: only the AO (or alternate) confirms a proposed target
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.confirm_kpi_target('e4000005-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '21 programme_lead cannot confirm kpi target');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '21 programme_lead cannot confirm kpi target: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.confirm_kpi_target('e4000005-0000-0000-0000-000000000001');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT target_confirmed_by FROM public.kpis
    WHERE id='e4000005-0000-0000-0000-000000000001')
    = 'aa000005-0000-0000-0000-000000000008'
  AND (SELECT target_confirmed_on FROM public.kpis
    WHERE id='e4000005-0000-0000-0000-000000000001') IS NOT NULL,
  '22 confirm_kpi_target: AO confirms proposed target (write-protected cols)');

-- ============================================================================
-- RAID items + status history
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.create_raid_item('dd000005-0000-0000-0000-000000000001', 'risk',
        'TESTFIX new supplier risk', 'TESTFIX impact', 'TESTFIX action',
        'aa000005-0000-0000-0000-000000000009', NULL) AS ri \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.raid_items
     WHERE id = :'ri'::uuid AND status='Open' AND source='manual'
       AND programme_id='dd000005-0000-0000-0000-000000000001'),
  '23 create_raid_item: Open manual item created');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000011","role":"authenticated"}';
SELECT pg_temp.t(public.create_raid_item('dd000005-0000-0000-0000-000000000001',
        'issue','TESTFIX exec-raised issue',NULL,NULL,NULL,NULL) IS NOT NULL,
  '24 create_raid_item: executive role may raise items (insert role set)');
ROLLBACK;

-- update + status history + resolve
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.update_raid_item(:'ri'::uuid, NULL, NULL, NULL, NULL, NULL, NULL, 'In progress');
SELECT public.resolve_raid_item(:'ri'::uuid, 'TESTFIX risk accepted at exec');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.raid_items WHERE id = :'ri'::uuid) = 'Closed',
  '25 update+resolve: raid item Closed');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.raid_status_history WHERE raid_item_id = :'ri'::uuid) = 2
  AND EXISTS (SELECT 1 FROM public.raid_status_history
               WHERE raid_item_id = :'ri'::uuid
                 AND old_status='Open' AND new_status='In progress'
                 AND changed_by='aa000005-0000-0000-0000-000000000009')
  AND EXISTS (SELECT 1 FROM public.raid_status_history
               WHERE raid_item_id = :'ri'::uuid
                 AND old_status='In progress' AND new_status='Closed'
                 AND note='TESTFIX risk accepted at exec'),
  '26 status transitions logged to raid_status_history (incl. resolve note)');

-- update denial: cross-partner + re-resolve
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.update_raid_item('e5000005-0000-0000-0000-000000000001',
            NULL,'TESTFIX hijack',NULL,NULL,NULL,NULL,NULL);
    PERFORM pg_temp.t(false, '27 cross-partner raid update denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '27 cross-partner raid update denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE v_ri uuid;
BEGIN
  SELECT id INTO v_ri FROM public.raid_items
   WHERE description='TESTFIX new supplier risk';
  BEGIN
    PERFORM public.resolve_raid_item(v_ri, 'again');
    PERFORM pg_temp.t(false, '28 re-resolve of a Closed item rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '28 re-resolve of a Closed item rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- filters (run as the programme lead inside claims context)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_raid_items(
      'dd000005-0000-0000-0000-000000000001', 'Open', NULL, NULL)) >= 2,
  '29 list_raid_items status=Open filter');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_raid_items(
      'dd000005-0000-0000-0000-000000000001', NULL, 'issue', NULL)) >= 1
  AND (SELECT count(*) FROM public.list_raid_items(
      'dd000005-0000-0000-0000-000000000001', NULL, NULL,
      'aa000005-0000-0000-0000-000000000009')) >= 2,
  '30 list_raid_items type + owner filters');
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_raid_items(
      'dd000005-0000-0000-0000-000000000001', NULL, NULL, NULL)) = 0,
  '31 cross-partner read: Partner B sees none of P1 RAID items');
ROLLBACK;

-- ============================================================================
-- Decisions ledger (append-only)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.record_decision('e5000005-0000-0000-0000-000000000001',
        'TESTFIX exec accepts phased rollout', 'TESTFIX-EXEC-77',
        '[{"activity_ref":"A-06"}]'::jsonb) AS did \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.decisions
     WHERE id = :'did'::uuid
       AND decided_by='aa000005-0000-0000-0000-000000000008'
       AND minute_ref='TESTFIX-EXEC-77'
       AND unlocks = '[{"activity_ref":"A-06"}]'::jsonb),
  '32 record_decision: outcome, minute ref, unlocks, decided_by stored');

-- append-only: trigger refuses UPDATE/DELETE even for the admin role
DO $$
DECLARE v_did uuid; v_ri uuid;
BEGIN
  SELECT id INTO v_did FROM public.decisions WHERE minute_ref='TESTFIX-EXEC-77';
  SELECT id INTO v_ri  FROM public.raid_items WHERE description='TESTFIX new supplier risk';
  BEGIN
    UPDATE public.decisions SET outcome='rewrite' WHERE id = v_did;
    PERFORM pg_temp.t(false, '33 decisions UPDATE rejected (append-only trigger)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '33 decisions UPDATE rejected: '||SQLERRM);
  END;
  BEGIN
    DELETE FROM public.decisions WHERE id = v_did;
    PERFORM pg_temp.t(false, '34 decisions DELETE rejected (append-only trigger)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '34 decisions DELETE rejected: '||SQLERRM);
  END;
  BEGIN
    UPDATE public.raid_status_history SET note='x' WHERE raid_item_id = v_ri;
    PERFORM pg_temp.t(false, '35 raid_status_history UPDATE rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '35 raid_status_history UPDATE rejected: '||SQLERRM);
  END;
END $$;

-- list_decisions by programme and by raid item
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_decisions(
      'dd000005-0000-0000-0000-000000000001', NULL)) >= 3,
  '36 list_decisions by programme (seed + session + exec)');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_decisions(
      NULL, 'e5000005-0000-0000-0000-000000000001')) >= 2,
  '37 list_decisions by raid item');
ROLLBACK;

-- ============================================================================
-- FR-MNT-06: maintenance Exception auto-raises a RAID issue (direct write path)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
UPDATE public.maintenance_task_instances
   SET status='Exception',
       exception_reason='TESTFIX provider missed the monthly input'
 WHERE id = 'e9000005-0000-0000-0000-000000000001';
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT m.exception_raid_item_id FROM public.maintenance_task_instances m
    WHERE m.id='e9000005-0000-0000-0000-000000000001') IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.raid_items r
     WHERE r.id = (SELECT m.exception_raid_item_id FROM public.maintenance_task_instances m
                    WHERE m.id='e9000005-0000-0000-0000-000000000001')
       AND r.type='issue' AND r.source='exception' AND r.status='Open'
       AND r.programme_id='dd000005-0000-0000-0000-000000000001'),
  '38 exception→RAID: instance Exception auto-created linked issue (FR-MNT-06)');

-- ============================================================================
-- audit trail (every mutation wrote audit_log)
-- ============================================================================
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_log
           WHERE action='weekly_log.upserted'
             AND detail->>'programme_id'='dd000005-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM public.audit_log WHERE action='kpi_actual.recorded')
  AND EXISTS (SELECT 1 FROM public.audit_log WHERE action='raid.created')
  AND EXISTS (SELECT 1 FROM public.audit_log WHERE action='raid.resolved')
  AND EXISTS (SELECT 1 FROM public.audit_log WHERE action='decision.recorded')
  AND EXISTS (SELECT 1 FROM public.audit_log WHERE action='raid.exception_raised')
  AND EXISTS (SELECT 1 FROM public.audit_log WHERE action='kpi_target.confirmed'),
  '39 audit_log: every mutation wrote an audit row');

\echo '=== e2e_ops_crud checks done ==='
