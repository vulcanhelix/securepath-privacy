-- ============================================================================
-- W1-01 rules engine (spec §9) — psql acceptance checks
-- Runs AGAINST the W0-05 TESTFIX fixture world: apply
-- app/supabase/migrations/20261105000005_test_fixtures.sql first with
-- securepath.test_fixtures='on' (the CI step does both). JWT callers are
-- simulated via SET ROLE authenticated + request.jwt.claims inside the same
-- transaction as the assertions (e2e_role_assignments.sql pattern).
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_rules_engine.sql
--
-- NOTE for local scratch runs: see e2e_template_engine.sql's header — the
-- bare supabase/postgres image needs the auth shim (newer auth.users columns
-- + the coalesced auth.uid body) before the fixture/test chain.
--
-- Fixture anchors used below (W0-05): P1 dd000005-…-001 (C1/ZA, start Mon
-- 2026-09-07, 12 weeks, red_threshold 14, report BD5, reduced week 6,
-- stored programme_rag 'Amber'), P2 dd000005-…-002 (C2/UK), P3 dd…-003.
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- teardown-safe cleanup: earlier runs — or a real-clock 'securepath-tick'
-- fire between fixture-apply and this suite (pg_cron runs on now(), not the
-- suite clock) — may have left '2026-10' snapshots on TESTFIX programmes
-- outside a transaction (append-only table — delete here as the suite
-- runner, never as a tenant role). Snapshots already backing a report are
-- NOT leftovers — and deleting one would trip the issued-report guard via
-- the snapshot_id ON DELETE SET NULL — so they're excluded.
DELETE FROM monthly_snapshots s
 WHERE s.period = '2026-10'
   AND s.programme_id IN (SELECT id FROM programmes
                           WHERE client_org_id::text LIKE 'cc000005-%')
   AND NOT EXISTS (SELECT 1 FROM programme_reports r
                    WHERE r.snapshot_id = s.id);

-- ---------- §9.1 week / month / phase arithmetic ----------
SELECT pg_temp.t(programme_week('dd000005-0000-0000-0000-000000000001', DATE '2026-09-07') = 1,
  'week: start date is week 1');
SELECT pg_temp.t(programme_week('dd000005-0000-0000-0000-000000000001', DATE '2026-10-12') = 6
  AND is_reduced_capacity('dd000005-0000-0000-0000-000000000001', 6)
  AND NOT is_reduced_capacity('dd000005-0000-0000-0000-000000000001', 5),
  'week: Oct 12 is week 6 — a reduced-capacity week (weeks run on regardless)');
SELECT pg_temp.t(programme_week('dd000005-0000-0000-0000-000000000001', DATE '2026-09-01') = 1
  AND programme_week('dd000005-0000-0000-0000-000000000001', DATE '2027-01-05') = 12,
  'week: clamps to 1..total_weeks');
SELECT pg_temp.t(week_start('dd000005-0000-0000-0000-000000000001', 3) = DATE '2026-09-21'
  AND week_end('dd000005-0000-0000-0000-000000000001', 3) = DATE '2026-09-25',
  'week: start Monday / end Friday of week 3');
SELECT pg_temp.t(phase_at_week('dd000005-0000-0000-0000-000000000001', 6) = 'TESTFIX Remediate & Implement'
  AND programme_phase_at('dd000005-0000-0000-0000-000000000001', DATE '2026-10-12') = 'TESTFIX Remediate & Implement',
  'phase: week 6 → phase 2 boundary lookup');
SELECT pg_temp.t(programme_month('dd000005-0000-0000-0000-000000000001', DATE '2026-10-02') = 1
  AND programme_month('dd000005-0000-0000-0000-000000000001', DATE '2026-10-09') = 2,
  'month: month of (due-4d) counted from start month (spec-literal)');

-- ---------- §9.1 business days + report due date ----------
SELECT pg_temp.t(NOT is_business_day('ZA', DATE '2026-12-25')
  AND is_business_day('ZA', DATE '2026-12-24'),
  'bd: ZA public holiday excluded, weekday included');
SELECT pg_temp.t(add_business_days('ZA', DATE '2026-12-24', 1) = DATE '2026-12-28',
  'bd: Dec 24 + 1bd skips holiday + weekend → Dec 28');
SELECT pg_temp.t(business_days_between('ZA', DATE '2026-12-24', DATE '2026-12-29') = 2,
  'bd: Dec 24→29 counts 2 business days');
SELECT pg_temp.t(report_due_date('dd000005-0000-0000-0000-000000000001', DATE '2026-09-15')
                 = DATE '2026-10-07',
  'report due: Sep period → 5th business day of Oct = Oct 7');
SELECT pg_temp.t(report_due_date('dd000005-0000-0000-0000-000000000001', DATE '2025-12-15')
                 = DATE '2026-01-08',
  'report due: holiday-aware — Dec period → Jan 8 (Jan 1 is a ZA holiday)');
SELECT pg_temp.t(last_business_day('ZA', DATE '2026-10-15') = DATE '2026-10-30',
  'bd: last business day of Oct 2026 = Fri Oct 30 (snapshot day)');

-- ---------- §9.2 activity RAG (AT-11 / AT-12) ----------
-- U9 is programme_lead at programme scope on P1.
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000002', '2026-10-14'::timestamptz) = 'Amber',
  'AT-11: activity due Oct 2, 12 days late → Amber');
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000002', '2026-10-16'::timestamptz) = 'Amber',
  'RAG edge: exactly the 14-day threshold is still Amber ("more than" required)');
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000002', '2026-10-19'::timestamptz) = 'Red',
  'AT-12: same activity 17 days late → Red');
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000001', '2026-10-19'::timestamptz) = 'Complete'
  AND activity_rag('d3000005-0000-0000-0000-000000000008', '2026-10-19'::timestamptz) = 'Red'
  AND activity_rag('d3000005-0000-0000-0000-000000000006', '2026-10-19'::timestamptz) = 'Amber',
  'RAG ordered rules: Complete→Complete, Blocked→Red, At risk→Amber');
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000005', '2026-10-20'::timestamptz) = 'Amber'
  AND activity_rag('d3000005-0000-0000-0000-000000000005', '2026-10-15'::timestamptz) = 'Green',
  'RAG: due within ≤3 business days → Amber; beyond → Green once started');
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000004', '2026-10-20'::timestamptz) = 'Amber'
  AND activity_rag('d3000005-0000-0000-0000-000000000007', '2026-10-05'::timestamptz) = 'Not due',
  'RAG: not-started-but-past-due → Amber; future activity → Not due');
ROLLBACK;

-- ---------- Deferred (rescheduled_date) ----------
BEGIN;
-- as admin inside txn: defer A-02 to Nov 30 — rescheduled replaces due in RAG
UPDATE activities SET status='Deferred', rescheduled_date='2026-11-30'
 WHERE id='d3000005-0000-0000-0000-000000000002';
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000002', '2026-10-19'::timestamptz) = 'Green',
  'Deferred: rescheduled to Nov 30 → judged on new date, Green at Oct 19');
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000002', '2026-12-20'::timestamptz) = 'Red',
  'Deferred: >threshold past the rescheduled date → Red');
DO $$
BEGIN
  BEGIN
    INSERT INTO activities (programme_id, ref, text, start_week, end_week, status)
    VALUES ('dd000005-0000-0000-0000-000000000001','W1RE-D','deferral test',1,1,'Deferred');
    PERFORM pg_temp.t(false, 'Deferred without rescheduled_date rejected');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.t(true, 'Deferred without rescheduled_date rejected (CHECK)');
  END;
END $$;
ROLLBACK;

-- ---------- §9.3 register status + §9.6 rollups ----------
SELECT pg_temp.t(register_days_overdue('d4000005-0000-0000-0000-000000000003', '2026-11-20'::timestamptz) = 14,
  'register: R-03 (close wk9 = Nov 6) is 14 days overdue at Nov 20');
SELECT pg_temp.t(register_days_overdue('d4000005-0000-0000-0000-000000000004', '2026-11-20'::timestamptz) IS NULL,
  'register: days_overdue blank once Closed (§9.3)');
SELECT pg_temp.t(register_item_rag('d4000005-0000-0000-0000-000000000003', '2026-11-20'::timestamptz) = 'Amber'
  AND register_item_rag('d4000005-0000-0000-0000-000000000004', '2026-11-20'::timestamptz) = 'Complete',
  'register RAG: overdue-within-threshold → Amber; Closed → Complete');
SELECT pg_temp.t(workstream_rag('d2000005-0000-0000-0000-000000000002', '2026-10-19'::timestamptz) = 'Red',
  'workstream RAG: WS-OPS worst-of (A-02 Red) at Oct 19');
SELECT pg_temp.t(programme_rag('dd000005-0000-0000-0000-000000000001', '2026-10-19'::timestamptz) = 'Amber'
  AND programme_rag_suggested('dd000005-0000-0000-0000-000000000001', '2026-10-19'::timestamptz) = 'Red',
  'programme RAG: stored lead value wins; suggestion = worst workstream (Red)');
SELECT pg_temp.t(partner_console_rag('dd000005-0000-0000-0000-000000000001', '2026-10-20'::timestamptz) = 'Red',
  'console RAG: Red regardless — overdue report-feeding maintenance task (MM-06 Exception)');

-- ---------- §9.4 closure ----------
SELECT pg_temp.t((SELECT NOT can_close FROM can_close_register_item('d4000005-0000-0000-0000-000000000001')),
  'closure precheck: R-01 blocked — linked A-03 not Complete');
SELECT pg_temp.t((SELECT can_close FROM can_close_register_item('d4000005-0000-0000-0000-000000000004')),
  'closure precheck: R-04 eligible — activities Complete + acceptance recorded');

BEGIN;
SET ROLE authenticated;
-- U8 is the client-scope accountable_officer on C1 (is_ao_or_alternate passes).
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    UPDATE register_items SET status='Closed' WHERE id='d4000005-0000-0000-0000-000000000005';
    PERFORM pg_temp.t(false, 'closure rejected: no accepted evidence record');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'closure rejected: no accepted evidence record');
  END;
  -- reopening without a reason rejected (§9.4, W0-02 gate)
  BEGIN
    UPDATE register_items SET status='In progress' WHERE id='d4000005-0000-0000-0000-000000000004';
    PERFORM pg_temp.t(false, 'reopen rejected without reason');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'reopen rejected without reason (§9.4)');
  END;
END $$;
ROLLBACK;

-- allowed path: complete the linked activity + acceptance record, AO closes.
-- accepted_* columns are write-protected (only a definer RPC — W1-05 — sets
-- them), so the acceptance record is staged admin-side inside the txn; the
-- status flip itself runs under the AO's JWT exactly like production.
-- #87: the ref must be REAL accepted evidence linked to R-05 (no fabricated
-- refs), so the accepted evidence row + its AO accept review are staged too.
BEGIN;
UPDATE activities SET status='Complete', pct_complete=100 WHERE id='d3000005-0000-0000-0000-000000000008';
INSERT INTO evidence_items (id, programme_id, activity_id, register_item_id, file_key,
                            uploaded_by, review_stage, outcome, evidence_ref)
VALUES ('e1000005-0000-0000-0000-0000000000f5','dd000005-0000-0000-0000-000000000001',
        'd3000005-0000-0000-0000-000000000008','d4000005-0000-0000-0000-000000000005',
        'w1re/c1/breach-drill.pdf','aa000005-0000-0000-0000-000000000010',
        'decided','closes_finding','EV-R-05-001');
INSERT INTO evidence_reviews (evidence_item_id, stage, reviewer, decision)
VALUES ('e1000005-0000-0000-0000-0000000000f5','accept','aa000005-0000-0000-0000-000000000008','accepted');
UPDATE register_items SET accepted_on='2026-11-20 10:00+00', accepted_by='aa000005-0000-0000-0000-000000000008',
      accepted_evidence_refs='{EV-R-05-001}' WHERE id='d4000005-0000-0000-0000-000000000005';
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
UPDATE register_items SET status='Closed' WHERE id='d4000005-0000-0000-0000-000000000005';
SELECT pg_temp.t((SELECT status FROM register_items WHERE id='d4000005-0000-0000-0000-000000000005') = 'Closed',
  'closure allowed: linked activity Complete + accepted evidence + AO (§9.4)');
ROLLBACK;

-- non-AO may not close even with the data preconditions met (W0-02 authz leg)
BEGIN;
UPDATE activities SET status='Complete', pct_complete=100 WHERE id='d3000005-0000-0000-0000-000000000008';
-- #87: real accepted evidence, so the ONLY failing leg is the AO authz gate
INSERT INTO evidence_items (id, programme_id, activity_id, register_item_id, file_key,
                            uploaded_by, review_stage, outcome, evidence_ref)
VALUES ('e1000005-0000-0000-0000-0000000000f5','dd000005-0000-0000-0000-000000000001',
        'd3000005-0000-0000-0000-000000000008','d4000005-0000-0000-0000-000000000005',
        'w1re/c1/breach-drill.pdf','aa000005-0000-0000-0000-000000000010',
        'decided','closes_finding','EV-R-05-001');
INSERT INTO evidence_reviews (evidence_item_id, stage, reviewer, decision)
VALUES ('e1000005-0000-0000-0000-0000000000f5','accept','aa000005-0000-0000-0000-000000000008','accepted');
UPDATE register_items SET accepted_on=now(), accepted_by='aa000005-0000-0000-0000-000000000008',
      accepted_evidence_refs='{EV-R-05-001}' WHERE id='d4000005-0000-0000-0000-000000000005';
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    UPDATE register_items SET status='Closed' WHERE id='d4000005-0000-0000-0000-000000000005';
    PERFORM pg_temp.t(false, 'non-AO closure rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'non-AO closure rejected (programme lead ≠ AO)');
  END;
END $$;
ROLLBACK;

-- ---------- activity_deps cycle check ----------
BEGIN;
DO $$
BEGIN
  BEGIN
    -- A-08 already depends on A-07 → A-07 depending on A-08 closes a 2-cycle
    INSERT INTO activity_deps (activity_id, depends_on_activity_id)
    VALUES ('d3000005-0000-0000-0000-000000000007','d3000005-0000-0000-0000-000000000008');
    PERFORM pg_temp.t(false, 'dependency cycle rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'dependency cycle rejected (A-07↔A-08)');
  END;
  BEGIN
    -- transitive: A-04→A-03→A-02 chain exists; A-02 depending on A-04 cycles
    INSERT INTO activity_deps (activity_id, depends_on_activity_id)
    VALUES ('d3000005-0000-0000-0000-000000000002','d3000005-0000-0000-0000-000000000004');
    PERFORM pg_temp.t(false, 'transitive dependency cycle rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'transitive dependency cycle rejected (A-02→A-04→…→A-02)');
  END;
END $$;
ROLLBACK;

-- ---------- §9.7 deadline resolution (pack-driven, never hard-coded) ----------
SELECT pg_temp.t(jurisdiction_deadline('ZA','data_subject_request','2026-10-08 11:00'::timestamptz)
                 = DATE '2026-11-07',
  'deadline: ZA DSR = received + 30 calendar days');
SELECT pg_temp.t(jurisdiction_deadline('UK','data_subject_request','2026-10-12 09:00'::timestamptz)
                 = DATE '2026-11-09',
  'deadline: UK DSR = received + 28 calendar days (AT-09: UK pack, not ZA)');
SELECT pg_temp.t(jurisdiction_deadline('UK','breach_notification','2026-10-09'::timestamptz)
                 = DATE '2026-10-12',
  'deadline: UK breach = +72h regulator period');
SELECT pg_temp.t(operational_due_date('eb000005-0000-0000-0000-000000000011') = DATE '2026-11-09',
  'deadline: the open UK DSR row resolves through client jurisdiction');

BEGIN;
-- the write trigger fills the calc column on every path
UPDATE operational_records SET deadline_params='{"received_on":"2026-10-12"}'
  WHERE id='eb000005-0000-0000-0000-000000000011';
SELECT pg_temp.t((SELECT due_date FROM operational_records WHERE id='eb000005-0000-0000-0000-000000000011')
                 = DATE '2026-11-09',
  'deadline: trigger writes operational_records.due_date from the pack');
ROLLBACK;

-- ---------- recompute engine ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT recompute_programme_progress('dd000005-0000-0000-0000-000000000001', '2026-10-19'::timestamptz);
SELECT pg_temp.t((SELECT due_date FROM activities WHERE id='d3000005-0000-0000-0000-000000000002')
                 = DATE '2026-10-02'
  AND (SELECT rag FROM activities WHERE id='d3000005-0000-0000-0000-000000000002') = 'Red'
  AND (SELECT month FROM activities WHERE id='d3000005-0000-0000-0000-000000000002') = 1,
  'recompute: engine writes due_date/month/rag — caller supplies none (A-02 Red at Oct 19)');
SELECT pg_temp.t((SELECT days_overdue FROM register_items WHERE id='d4000005-0000-0000-0000-000000000001') = 10
  AND (SELECT days_overdue FROM register_items WHERE id='d4000005-0000-0000-0000-000000000004') IS NULL
  AND (SELECT phase FROM programmes WHERE id='dd000005-0000-0000-0000-000000000001') = 'TESTFIX Remediate & Implement',
  'recompute: register overdue + programme phase written (Closed stays blank)');
ROLLBACK;

-- guard: a programme_lead on a DIFFERENT programme may not recompute P1
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000017","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM recompute_activity_due('dd000005-0000-0000-0000-000000000001', '2026-10-19'::timestamptz);
    PERFORM pg_temp.t(false, 'cross-programme recompute rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'cross-programme recompute rejected (definer guard)');
  END;
END $$;
-- cross-partner read: partner-B admin sees NULL on partner-A rows
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(activity_rag('d3000005-0000-0000-0000-000000000002', '2026-10-19'::timestamptz) IS NULL,
  'cross-partner: invoker functions fail closed on invisible rows');
-- calc columns carry no client grant
DO $$
BEGIN
  BEGIN
    UPDATE activities SET rag='Green' WHERE id='d3000005-0000-0000-0000-000000000002';
    PERFORM pg_temp.t(false, 'direct write to calc column rag denied');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, 'direct write to calc column rag denied (engine-owned)');
  END;
END $$;
ROLLBACK;

-- ---------- §9.5 snapshot writer ----------
-- authenticated holds no EXECUTE grant — the writer runs on the scheduler's
-- service path (auth.uid() NULL). Denial first, then the service-path write.
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM write_monthly_snapshot('dd000005-0000-0000-0000-000000000001', DATE '2026-10-01');
    PERFORM pg_temp.t(false, 'authenticated cannot mint snapshots directly');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, 'authenticated cannot mint snapshots directly (no grant)');
  END;
END $$;
RESET ROLE;
SET request.jwt.claims = '';
-- a real-clock tick may still have slipped a '2026-10' snapshot in after the
-- suite-top cleanup — clear it again INSIDE this txn so the service-path
-- write below exercises the fresh-append path rather than dying on the
-- (programme_id, period) UNIQUE constraint (which would abort the txn).
-- Same report-backed exclusion as the suite-top cleanup.
DELETE FROM monthly_snapshots s
 WHERE s.period = '2026-10'
   AND s.programme_id IN (SELECT id FROM programmes
                           WHERE client_org_id::text LIKE 'cc000005-%')
   AND NOT EXISTS (SELECT 1 FROM programme_reports r
                    WHERE r.snapshot_id = s.id);
SELECT write_monthly_snapshot('dd000005-0000-0000-0000-000000000001', DATE '2026-10-01',
                              '2026-10-30 18:00'::timestamptz) AS snapshot_id;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM monthly_snapshots
      WHERE programme_id='dd000005-0000-0000-0000-000000000001' AND period='2026-10'
        AND snapshot ? 'activities_complete' AND snapshot ? 'activities_overdue'
        AND snapshot ? 'register_closed' AND snapshot ? 'register_open'
        AND snapshot ? 'high_priority_closed' AND snapshot ? 'evidence_pending'
        AND snapshot ? 'rag' AND snapshot ? 'kpi_actuals'
        AND snapshot ? 'maintenance_done' AND snapshot ? 'maintenance_overdue'),
  'snapshot: written with all ten contract keys');
DO $$
BEGIN
  BEGIN
    PERFORM write_monthly_snapshot('dd000005-0000-0000-0000-000000000001', DATE '2026-10-01',
                                   '2026-10-31 08:00'::timestamptz);
    PERFORM pg_temp.t(false, 'second snapshot for the same period rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'second snapshot for the same period rejected (append-only)');
  END;
END $$;
ROLLBACK;

-- ---------- AT-17: issued report + snapshot immutability ----------
DO $$
BEGIN
  BEGIN
    UPDATE programme_reports SET overall_rag='Green'
      WHERE id='f1000005-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, 'AT-17: issued report cannot change afterwards');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'AT-17: issued report cannot change afterwards (§9.5)');
  END;
END $$;
SELECT pg_temp.t((SELECT snapshot->>'rag' FROM monthly_snapshots
      WHERE id='ef000005-0000-0000-0000-000000000001') = 'Amber',
  'AT-17: stored snapshot figures unchanged regardless of later status changes');

-- ---------- §9.8 licence counting ----------
SELECT pg_temp.t((SELECT programmes_used = 2 AND clients_used = 2
                    AND client_limit = 2 AND programme_limit = 2
                    AND NOT over_client_limit AND NOT over_programme_limit
                   FROM partner_licence_usage('bb000005-0000-0000-0000-000000000001',
                                              '2026-10-20'::timestamptz)),
  'licence: partner A at full usage — 2 clients, 2 programmes, at limit not over');

BEGIN;
-- closing P1 drops partner A to 1 programme/1 client
UPDATE programmes SET status='closed' WHERE id='dd000005-0000-0000-0000-000000000001';
SELECT pg_temp.t((SELECT programmes_used = 1 AND clients_used = 1
                   FROM partner_licence_usage('bb000005-0000-0000-0000-000000000001',
                                              '2026-10-20'::timestamptz)),
  'licence: a programme counts until it is closed (§9.8)');
ROLLBACK;

\echo '=== e2e_rules_engine checks done ==='
