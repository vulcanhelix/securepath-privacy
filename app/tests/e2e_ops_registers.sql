-- ============================================================================
-- W1-04 operational-registers RPCs — psql acceptance checks
-- Covers: create_operational_record (type vocabulary + gates), record_dsr
-- (pack-driven due dates — ZA 30d vs UK 28d, never hard-coded), record_breach
-- (any-user report + IMMEDIATE breach_alert outbox event + audit),
-- record_breach_decision (AO/alternate-only, append history, status move),
-- close_operational_record (transitions, breach lessons-learned, closed_on),
-- list_operational_records (filters + paging + scope), external providers
-- (list/upsert), and the write-protected columns (regulator_notification /
-- due_date / closed_on refuse direct UPDATE — RPCs are the only writers).
--
-- Runs against the W0-05 TESTFIX world — apply the fixture pack first with
--   SET securepath.test_fixtures = 'on';  -- same psql session as the file
-- and AFTER the W1-01 rules engine (its due-date trigger computes due_date).
-- JWT callers are simulated via SET ROLE authenticated + request.jwt.claims
-- inside the same transaction — the pattern from e2e_role_assignments.sql.
--
-- Fixture ids used (20261105000005_test_fixtures.sql):
--   C1 cc000005-..-0001 (ZA, Partner A) · C2 ..0002 (UK, Partner A)
--   C3 ..0003 (ZA, Partner B)
--   U4 aa000005-..-0004 partner A admin (partner scope → C1+C2 write)
--   U5 aa000005-..-0005 partner A consultant (client scope C1)
--   U6 aa000005-..-0006 partner B admin (cross-partner for C1)
--   U8 aa000005-..-0008 C1 accountable_officer · U9 ..0009 C1 programme_lead
--   U12 ..0012 C1 client_contributor · U13 ..0013 contributor + named_alternate
--   U14 ..0014 C2 accountable_officer (+dpo) · U15 ..0015 C2 programme_lead
--   providers e7000005-..-0001/-0002 on C1
--   ZA pack: dsr 30 cal · optout 5 bd · breach regulator 3 bd
--   UK pack: dsr 28 cal · breach regulator 72 h
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_ops_registers.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- gate: TESTFIX world + W1-01 rules engine must both be present
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.client_orgs
                  WHERE id = 'cc000005-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'TESTFIX world missing — apply 20261105000005_test_fixtures.sql with securepath.test_fixtures=on first';
  END IF;
  IF to_regprocedure('public.jurisdiction_deadline(text,text,timestamptz)') IS NULL
     OR to_regprocedure('public.operational_due_date_for_row(uuid,text,jsonb,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'W1-01 rules engine missing — apply 20261106000001_rules_engine.sql first';
  END IF;
  RAISE NOTICE 'PASS 00 fixture gate: TESTFIX world + rules engine present';
END $$;

-- ids captured via \gset cannot interpolate inside $$-quoted DO blocks —
-- park them here and look them up by key inside the blocks.
CREATE TEMP TABLE _ids(k text PRIMARY KEY, v uuid);
GRANT SELECT ON _ids TO authenticated;   -- DO blocks run under SET ROLE authenticated

-- ============================================================================
-- DSR — due dates from the jurisdiction pack (FR-OPS-02), never hard-coded
-- ============================================================================
-- C1 (ZA) dsr received Thu 2026-10-08 → pack response_period_days 30 calendar
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.record_dsr('cc000005-0000-0000-0000-000000000001',
        'access', DATE '2026-10-08', 'TESTFIX SAR via portal') AS dsr_za \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
INSERT INTO _ids VALUES ('dsr_za', :'dsr_za'::uuid);

SELECT pg_temp.t(
  (SELECT due_date FROM public.operational_records WHERE id = :'dsr_za'::uuid)
    = DATE '2026-10-08' + 30,
  '01 record_dsr ZA: due_date = received_on + pack 30 calendar days (2026-11-07)');
SELECT pg_temp.t(
  (SELECT type FROM public.operational_records WHERE id = :'dsr_za'::uuid) = 'dsr'
  AND (SELECT deadline_rule FROM public.operational_records WHERE id = :'dsr_za'::uuid) = 'data_subject_request'
  AND (SELECT deadline_params->>'kind' FROM public.operational_records WHERE id = :'dsr_za'::uuid) = 'access'
  AND (SELECT status FROM public.operational_records WHERE id = :'dsr_za'::uuid) = 'Open',
  '02 record_dsr: type/rule/params/status stamped (dsr, data_subject_request, Open)');

-- C2 (UK) dsr received Mon 2026-10-12 → pack 28 calendar — a DIFFERENT value,
-- which is what proves the period came from the pack and not a literal.
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000015","role":"authenticated"}';
SELECT public.record_dsr('cc000005-0000-0000-0000-000000000002',
        'erasure', DATE '2026-10-12', 'TESTFIX UK erasure request') AS dsr_uk \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
INSERT INTO _ids VALUES ('dsr_uk', :'dsr_uk'::uuid);

SELECT pg_temp.t(
  (SELECT due_date FROM public.operational_records WHERE id = :'dsr_uk'::uuid)
    = DATE '2026-10-12' + 28,
  '03 record_dsr UK: due_date = received_on + pack 28 calendar days (2026-11-09) — pack-driven, not 30');

-- denials: contributor (no write role) and cross-partner
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.record_dsr('cc000005-0000-0000-0000-000000000001',
            'access', DATE '2026-10-08', 'x');
    PERFORM pg_temp.t(false, '04 contributor dsr write denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '04 contributor dsr write denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.record_dsr('cc000005-0000-0000-0000-000000000001',
            'access', DATE '2026-10-08', 'x');
    PERFORM pg_temp.t(false, '05 cross-partner dsr write denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '05 cross-partner dsr write denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- Breach — any-user report, immediate alert, regulator deadline (FR-OPS-03/04)
-- ============================================================================
-- U12 is a plain contributor — "any user can report a suspected breach".
-- suspected Fri 2026-10-09 → ZA breach_notification 3 business days → Wed 14.
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
SELECT public.record_breach('cc000005-0000-0000-0000-000000000001',
        TIMESTAMPTZ '2026-10-09 07:30+00',
        'TESTFIX suspected breach — unencrypted laptop') AS breach1 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
INSERT INTO _ids VALUES ('breach1', :'breach1'::uuid);

SELECT pg_temp.t(
  (SELECT type FROM public.operational_records WHERE id = :'breach1'::uuid) = 'breach'
  AND (SELECT status FROM public.operational_records WHERE id = :'breach1'::uuid) = 'Awaiting decision'
  AND (SELECT reported_by FROM public.operational_records WHERE id = :'breach1'::uuid)
        = 'aa000005-0000-0000-0000-000000000012'
  AND (SELECT regulator_notification FROM public.operational_records WHERE id = :'breach1'::uuid) IS NULL,
  '06 record_breach: contributor report accepted — breach, Awaiting decision, decision still NULL');
SELECT pg_temp.t(
  (SELECT due_date FROM public.operational_records WHERE id = :'breach1'::uuid)
    = DATE '2026-10-14',
  '07 record_breach: due_date = suspected_on + pack 3 business days (2026-10-14)');

-- §10: the alert lands in the outbox in the SAME transaction (immediate —
-- never the digest), addressed to PL + AO + partner consultant.
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.notification_events
     WHERE kind = 'breach_alert'
       AND (scope->>'client_org_id')::uuid = 'cc000005-0000-0000-0000-000000000001'
       AND (payload->>'record_id')::uuid = :'breach1'::uuid
       AND payload->>'timing' = 'immediate'),
  '08 breach_alert notification_event emitted immediately with the record');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.notification_events
     WHERE kind = 'breach_alert'
       AND (payload->>'record_id')::uuid = :'breach1'::uuid
       AND payload->'recipients' ? 'aa000005-0000-0000-0000-000000000009'   -- PL
       AND payload->'recipients' ? 'aa000005-0000-0000-0000-000000000008'   -- AO
       AND payload->'recipients' ? 'aa000005-0000-0000-0000-000000000005'), -- consultant
  '09 breach_alert recipients: programme lead + accountable officer + partner consultant');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_log
     WHERE action = 'operational_record.breach_reported'
       AND (detail->>'record_id')::uuid = :'breach1'::uuid)
  AND EXISTS (
    SELECT 1 FROM public.audit_log
     WHERE action = 'operational_record.created'
       AND (detail->>'record_id')::uuid = :'breach1'::uuid),
  '10 breach report audit-logged (created + breach_reported)');

-- a second breach for the not_notified path (partner admin can report too)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT public.record_breach('cc000005-0000-0000-0000-000000000001',
        TIMESTAMPTZ '2026-10-10 09:00+00',
        'TESTFIX second breach — misdirected email') AS breach2 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT type FROM public.operational_records WHERE id = :'breach2'::uuid) = 'breach',
  '11 record_breach: partner admin report accepted (client visibility)');

-- ============================================================================
-- Breach decision — AO / named alternate only (FR-ACC-02, T5)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE v uuid;
BEGIN
  SELECT _ids.v INTO v FROM _ids WHERE k='breach1';
  BEGIN
    PERFORM public.record_breach_decision(v, 'notified', 'TESTFIX pl attempt');
    PERFORM pg_temp.t(false, '12 non-AO (programme_lead) breach decision denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '12 non-AO (programme_lead) breach decision denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000014","role":"authenticated"}';
DO $$
DECLARE v uuid;
BEGIN
  SELECT _ids.v INTO v FROM _ids WHERE k='breach1';
  BEGIN
    PERFORM public.record_breach_decision(v, 'notified', 'TESTFIX cross-client AO');
    PERFORM pg_temp.t(false, '13 C2 AO cannot decide a C1 breach');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '13 C2 AO cannot decide a C1 breach: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- even the AO cannot write the column directly — the RPC is the only writer
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE v uuid;
BEGIN
  SELECT _ids.v INTO v FROM _ids WHERE k='breach1';
  BEGIN
    UPDATE public.operational_records
       SET regulator_notification = '{"decision":"notified"}'::jsonb
     WHERE id = v;
    PERFORM pg_temp.t(false, '14 direct UPDATE of regulator_notification denied even for the AO');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '14 direct UPDATE of regulator_notification denied even for the AO: '||SQLERRM);
  END;
  BEGIN
    UPDATE public.operational_records
       SET due_date = DATE '2030-01-01', closed_on = now()
     WHERE id = v;
    PERFORM pg_temp.t(false, '15 direct UPDATE of due_date/closed_on denied (write-protected)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '15 direct UPDATE of due_date/closed_on denied (write-protected): '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE v uuid;
BEGIN
  SELECT _ids.v INTO v FROM _ids WHERE k='breach1';
  BEGIN
    PERFORM public.record_breach_decision(v, 'maybe', 'TESTFIX bad enum');
    PERFORM pg_temp.t(false, '16 invalid decision value rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '16 invalid decision value rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- AO decides 'notified' → column written, history appended, status advances
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.record_breach_decision(:'breach1'::uuid, 'notified',
        'TESTFIX laptop contained PI — regulator notified');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(
  (SELECT regulator_notification->>'decision' FROM public.operational_records
    WHERE id = :'breach1'::uuid) = 'notified'
  AND (SELECT (regulator_notification->>'decided_by')::uuid
         FROM public.operational_records WHERE id = :'breach1'::uuid)
        = 'aa000005-0000-0000-0000-000000000008'
  AND (SELECT jsonb_array_length(regulator_notification->'history')
         FROM public.operational_records WHERE id = :'breach1'::uuid) = 1
  AND (SELECT status FROM public.operational_records WHERE id = :'breach1'::uuid)
        = 'In progress',
  '17 AO decision recorded: notified, history=1, Awaiting decision → In progress');

-- named-alternate (designation leg, post-20261106000000 fix) appends 'partial'
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000013","role":"authenticated"}';
SELECT public.record_breach_decision(:'breach1'::uuid, 'partial',
        'TESTFIX alternate: subjects notified, regulator pending');
SELECT public.record_breach_decision(:'breach2'::uuid, 'not_notified',
        'TESTFIX alternate: no PI involved — documented not-notified');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(
  (SELECT regulator_notification->>'decision' FROM public.operational_records
    WHERE id = :'breach1'::uuid) = 'partial'
  AND (SELECT jsonb_array_length(regulator_notification->'history')
         FROM public.operational_records WHERE id = :'breach1'::uuid) = 2,
  '18 named alternate may decide (designation leg); history appends (now 2)');
SELECT pg_temp.t(
  (SELECT regulator_notification->>'decision' FROM public.operational_records
    WHERE id = :'breach2'::uuid) = 'not_notified',
  '19 not_notified decision recorded on second breach');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_log
     WHERE action = 'operational_record.breach_decision'
       AND (detail->>'record_id')::uuid = :'breach1'::uuid
       AND detail->>'decision' = 'partial'),
  '20 breach decisions audit-logged');

-- a decision on a non-breach record is nonsense → rejected
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE v uuid;
BEGIN
  SELECT _ids.v INTO v FROM _ids WHERE k='dsr_za';
  BEGIN
    PERFORM public.record_breach_decision(v, 'notified', 'TESTFIX wrong type');
    PERFORM pg_temp.t(false, '21 breach decision on a dsr record rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '21 breach decision on a dsr record rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- Closure — allowed transitions, breach lessons-learned, closed_on
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE v uuid;
BEGIN
  SELECT _ids.v INTO v FROM _ids WHERE k='breach1';
  BEGIN
    PERFORM public.close_operational_record(v, NULL);
    PERFORM pg_temp.t(false, '22 closing a breach without lessons learned rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '22 closing a breach without lessons learned rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.close_operational_record(:'breach1'::uuid,
        'TESTFIX lessons: enforce full-disk encryption + courier policy');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(
  (SELECT status FROM public.operational_records WHERE id = :'breach1'::uuid) = 'Closed'
  AND (SELECT closed_on FROM public.operational_records WHERE id = :'breach1'::uuid) IS NOT NULL
  AND (SELECT outcome FROM public.operational_records WHERE id = :'breach1'::uuid)
        LIKE '%full-disk encryption%',
  '23 breach closed by AO with lessons learned; closed_on stamped (write-protected col)');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE v uuid;
BEGIN
  SELECT _ids.v INTO v FROM _ids WHERE k='breach1';
  BEGIN
    PERFORM public.close_operational_record(v, 'again');
    PERFORM pg_temp.t(false, '24 re-closing a Closed record rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '24 re-closing a Closed record rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.record_breach_decision(v, 'notified', 'post-close');
    PERFORM pg_temp.t(false, '25 breach decision on a Closed record rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '25 breach decision on a Closed record rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- non-breach close: note optional; contributor cannot close
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.close_operational_record(:'dsr_za'::uuid, NULL);
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.operational_records WHERE id = :'dsr_za'::uuid) = 'Closed'
  AND (SELECT closed_on FROM public.operational_records WHERE id = :'dsr_za'::uuid) IS NOT NULL,
  '26 dsr closed without note (note optional for non-breach)');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
DECLARE v uuid;
BEGIN
  SELECT _ids.v INTO v FROM _ids WHERE k='dsr_uk';
  BEGIN
    PERFORM public.close_operational_record(v, 'x');
    PERFORM pg_temp.t(false, '27 contributor cannot close a register record');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '27 contributor cannot close a register record: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- Generic create — CHECK-faithful type vocabulary + optout pack deadline
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.create_operational_record('cc000005-0000-0000-0000-000000000001',
            'incident', '{}');
    PERFORM pg_temp.t(false, '28 ''incident'' rejected — CHECK vocabulary is dsr|breach|disclosure|optout');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '28 ''incident'' rejected — CHECK vocabulary is dsr|breach|disclosure|optout: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.create_operational_record('cc000005-0000-0000-0000-000000000001',
            'training', '{}');
    PERFORM pg_temp.t(false, '29 ''training'' rejected (training_records is the table)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '29 ''training'' rejected (training_records is the table): '||SQLERRM);
  END;
  BEGIN
    PERFORM public.create_operational_record('cc000005-0000-0000-0000-000000000001',
            'dsr', '{"status":"Closed"}');
    PERFORM pg_temp.t(false, '30 create with status Closed rejected (close RPC owns it)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '30 create with status Closed rejected (close RPC owns it): '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- optout via the generic RPC: Thu 2026-10-08 + ZA opt_out 5 business days
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT public.create_operational_record('cc000005-0000-0000-0000-000000000001',
        'optout',
        '{"description":"TESTFIX marketing opt-out",
          "deadline_params":{"received_on":"2026-10-08"},
          "channel":"email"}'::jsonb) AS optout1 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT due_date FROM public.operational_records WHERE id = :'optout1'::uuid)
    = DATE '2026-10-15',
  '31 optout: due = received + pack 5 business days (2026-10-15); consultant-scope write ok');

-- ============================================================================
-- list_operational_records — filters, paging, scope
-- ============================================================================
-- NOTE on read scope (W0-02 policy): register READS are client-scope —
-- allowed_client_orgs() has no programme-scope leg. U9 (programme-scope PL)
-- can WRITE client records (has_client_role includes programme scope) but
-- the read list, like the table policy, needs client visibility — the
-- positive checks below run as U8 (C1 accountable officer, client scope).
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{}')) >= 6,
  '32 list: C1 register rows visible to a client-scope reader (AO)');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', 'dsr', '{}')) >= 2
  AND NOT EXISTS (SELECT 1 FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', 'dsr', '{}') r
     WHERE r.type <> 'dsr'),
  '33 list: type filter returns only dsr rows');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{"status":"Closed"}')) >= 2
  AND NOT EXISTS (SELECT 1 FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{"status":"Closed"}') r
     WHERE r.status <> 'Closed'),
  '34 list: status filter (Closed — fixture optout + closed dsr + breach)');
ROLLBACK;

-- seed an overdue record (received 2020-01-01 → due 2020-01-31, Open)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.record_dsr('cc000005-0000-0000-0000-000000000001',
        'access', DATE '2020-01-01', 'TESTFIX stale request') AS dsr_old \gset
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', 'dsr', '{"overdue":true}') r
     WHERE r.id = :'dsr_old'::uuid)
  AND NOT EXISTS (
    SELECT 1 FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', 'dsr', '{"overdue":false}') r
     WHERE r.id = :'dsr_old'::uuid),
  '35 list: overdue filter finds the past-due open record only');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- paging: limit/offset pages are disjoint and ordered
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{"limit":2}')) = 2
  AND (SELECT count(*) FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{"limit":2,"offset":2}')) >= 2
  AND NOT EXISTS (
    SELECT 1 FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{"limit":2}') a
    JOIN public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{"limit":2,"offset":2}') b
      ON a.id = b.id),
  '36 list: limit/offset paging — disjoint pages');
ROLLBACK;

-- scope: partner-B admin and C2 lead see nothing of C1
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{}')) = 0,
  '37 list scope: partner B admin sees none of C1');
ROLLBACK;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_operational_records(
      'cc000005-0000-0000-0000-000000000001', NULL, '{}')) = 0,
  '38 list scope: programme-scope PL has no client read (W0-02 read policy)');
ROLLBACK;

-- ============================================================================
-- external providers (FR-MNT-03/04 contact book)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_external_providers('cc000005-0000-0000-0000-000000000001')) = 2,
  '39 list_external_providers: two fixture providers on C1');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- upsert as the programme lead (provider write set has no AO leg — it
-- matches the W0-02 provider policies; programme scope counts for writes)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.upsert_external_provider('cc000005-0000-0000-0000-000000000001',
        'TESTFIX Payroll Bureau', 'finance', 'payroll@testfix.test', 'email', true) AS prov1 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.external_providers
     WHERE id = :'prov1'::uuid AND client_org_id = 'cc000005-0000-0000-0000-000000000001'
       AND kind = 'finance' AND active),
  '40 upsert_external_provider: insert path');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.upsert_external_provider('cc000005-0000-0000-0000-000000000001',
        'TESTFIX Payroll Bureau (renamed)', 'finance', 'payroll@testfix.test',
        'portal', true, :'prov1'::uuid) AS prov1b \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  :'prov1b'::uuid = :'prov1'::uuid
  AND (SELECT name FROM public.external_providers WHERE id = :'prov1'::uuid)
        = 'TESTFIX Payroll Bureau (renamed)'
  AND (SELECT channel FROM public.external_providers WHERE id = :'prov1'::uuid) = 'portal',
  '41 upsert_external_provider: update path renames + rechannels same row');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.upsert_external_provider('cc000005-0000-0000-0000-000000000001', 'TESTFIX X');
    PERFORM pg_temp.t(false, '42 contributor provider write denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '42 contributor provider write denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.upsert_external_provider('cc000005-0000-0000-0000-000000000001', 'TESTFIX X');
    PERFORM pg_temp.t(false, '43 cross-partner provider write denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '43 cross-partner provider write denied: '||SQLERRM);
  END;
  PERFORM pg_temp.t(
    (SELECT count(*) FROM public.list_external_providers('cc000005-0000-0000-0000-000000000001')) = 0,
    '44 provider list scope: partner B sees none of C1');
END $$;
ROLLBACK;

-- provider id from another client cannot be hijacked via upsert
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000015","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.upsert_external_provider('cc000005-0000-0000-0000-000000000002',
            'TESTFIX hijack', NULL, NULL, NULL, true,
            'e7000005-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '45 upsert refuses a provider id belonging to another client');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '45 upsert refuses a provider id belonging to another client: '||SQLERRM);
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- summary
-- ============================================================================
SELECT '== e2e_ops_registers done ==' AS done;
