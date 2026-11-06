-- ============================================================================
-- W1-05 programme lifecycle RPCs — psql acceptance checks
-- Covers: create_programme (full §5.1 instantiation from the TESTFIX published
-- template — counts match content; calc columns engine-written; atomicity on
-- bad content), apply_template_version (v1→v1.1 merge preserving completed
-- work), update/reorder/add_activity (FR-TPL-04 + FR-SCH-04 + status history),
-- close_register_item (AO gate + §9.4 precondition), transition_programme
-- (legal moves only), update_programme_settings (validation + FR-SCH-06
-- recalc), list_programmes (partner-console rollup).
--
-- Runs against the W0-05 TESTFIX world — apply the fixture pack first with
--   ALTER DATABASE <db> SET securepath.test_fixtures = 'on';
-- (then re-run app/supabase/migrations/20261105000005_test_fixtures.sql).
-- JWT callers simulated via SET ROLE authenticated + request.jwt.claims inside
-- the SAME transaction as the writes (e2e_role_assignments.sql pattern).
-- SET ROLE persists past COMMIT — every block ends with RESET ROLE.
-- The created programme id travels between blocks in the e2e.prog GUC because
-- psql variables do not expand inside DO $$ blocks.
--
-- Fixture anchors:
--   Template f5000005-..-0001 'TESTFIX POPIA and PAIA' (ZA, shared library)
--     v1 f6000005-..-0001 PUBLISHED · v2 f6000005-..-0002 DRAFT (v1.1: +A-09,
--     training KPI target 90→85) — published here once, persists.
--   C3 cc000005-..-0003 under Partner B (bb000005-..-0002)
--   U6 aa000005-..-0006 partner_b_admin (partner scope B) — writes for C3
--   U4 aa000005-..-0004 partner_a_admin (partner scope A — cross-partner)
--   U16 aa000005-..-0016 C3 accountable_officer (client scope C3) — AO gate
--   U17 aa000005-..-0017 C3 programme_lead (programme scope P3 — not AO, and
--     no role on the new programme)
--   U2 aa000005-..-0002 content_author (platform) — publishes v1.1
--   U12 aa000005-..-0012 C1 client_contributor — no write role anywhere on C3
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_programme_lifecycle.sql
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
                  WHERE id = 'dd000005-0000-0000-0000-000000000001')
     OR NOT EXISTS (SELECT 1 FROM public.programme_template_versions
                     WHERE id = 'f6000005-0000-0000-0000-000000000001'
                       AND status = 'published') THEN
    RAISE EXCEPTION 'TESTFIX world missing — apply 20261105000005_test_fixtures.sql with securepath.test_fixtures=on first';
  END IF;
  RAISE NOTICE 'PASS 00 fixture gate: TESTFIX world + published template v1 present';
END $$;

-- teardown-safe cleanup of earlier runs (client-level docs may persist —
-- instantiation dedupes them on ref+version)
-- (#87: the suite now stages decided evidence, which NFR-09 makes
-- undeletable — suspend that guard for this teardown only, as the fixture
-- pack does)
ALTER TABLE public.evidence_items DISABLE TRIGGER evidence_immutable;
DELETE FROM public.programmes WHERE name LIKE 'W1-05 e2e%';
ALTER TABLE public.evidence_items ENABLE TRIGGER evidence_immutable;
SELECT set_config('e2e.prog', '', false);


-- ============================================================================
-- create_programme — denial paths (draft version, wrong roles, non-Monday)
-- The draft version exists only inside this txn.
-- ============================================================================
BEGIN;
INSERT INTO public.programme_templates (id, framework, jurisdiction, name)
VALUES ('f5000005-0000-0000-0000-00000000ff98','popia_paia','ZA','TESTFIX W105 draft template');
INSERT INTO public.programme_template_versions
    (id, template_id, number, status, content)
SELECT 'f6000005-0000-0000-0000-00000000ff98',
       'f5000005-0000-0000-0000-00000000ff98', 1, 'draft', content
  FROM public.programme_template_versions
 WHERE id = 'f6000005-0000-0000-0000-000000000001';
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.create_programme('cc000005-0000-0000-0000-000000000003',
              'f6000005-0000-0000-0000-00000000ff98','W1-05 e2e draft prog',DATE '2026-11-02');
    PERFORM pg_temp.t(false, '01 create from DRAFT version rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '01 create from DRAFT version rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.create_programme('cc000005-0000-0000-0000-000000000003',
              'f6000005-0000-0000-0000-000000000001','W1-05 e2e cross prog',DATE '2026-11-02');
    PERFORM pg_temp.t(false, '02 cross-partner create rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '02 cross-partner create rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000017","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.create_programme('cc000005-0000-0000-0000-000000000003',
              'f6000005-0000-0000-0000-000000000001','W1-05 e2e pl prog',DATE '2026-11-02');
    PERFORM pg_temp.t(false, '03 client-side programme_lead create rejected (partner gate)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '03 client-side programme_lead create rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.create_programme('cc000005-0000-0000-0000-000000000003',
              'f6000005-0000-0000-0000-000000000001','W1-05 e2e tue prog',DATE '2026-11-03'); -- Tuesday
    PERFORM pg_temp.t(false, '04 non-Monday start date rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '04 non-Monday start date rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- ============================================================================
-- create_programme — happy path on C3 (partner B admin), persists
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT public.create_programme('cc000005-0000-0000-0000-000000000003',
        'f6000005-0000-0000-0000-000000000001','W1-05 e2e programme',
        DATE '2026-11-02') AS prog \gset
COMMIT;
RESET ROLE;
SELECT set_config('e2e.prog', :'prog', false) IS NOT NULL AS prog_stored \gset

SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.programmes
                          WHERE id = :'prog'::uuid
                            AND client_org_id='cc000005-0000-0000-0000-000000000003'
                            AND template_version_id='f6000005-0000-0000-0000-000000000001'
                            AND status='implementation' AND total_weeks=12
                            AND start_date=DATE '2026-11-02'),
  '05 create_programme: row persisted, version pinned, 12 weeks, implementation');

SELECT pg_temp.t(
  (SELECT count(*) FROM public.phases WHERE programme_id=:'prog'::uuid) = 3
  AND (SELECT count(*) FROM public.workstreams WHERE programme_id=:'prog'::uuid) = 3
  AND (SELECT count(*) FROM public.activities WHERE programme_id=:'prog'::uuid) = 8
  AND (SELECT count(*) FROM public.activity_deps d JOIN public.activities a ON a.id=d.activity_id
        WHERE a.programme_id=:'prog'::uuid) = 5,
  '06 instantiation: 3 phases / 3 workstreams / 8 activities / 5 deps (counts match content)');

SELECT pg_temp.t(
  (SELECT count(*) FROM public.register_items WHERE programme_id=:'prog'::uuid) = 5
  AND (SELECT count(*) FROM public.register_item_activities ria
        JOIN public.register_items r ON r.id=ria.register_item_id
        WHERE r.programme_id=:'prog'::uuid) = 5
  AND (SELECT count(*) FROM public.kpis WHERE programme_id=:'prog'::uuid) = 3
  AND (SELECT count(*) FROM public.maintenance_task_templates WHERE programme_id=:'prog'::uuid) = 5,
  '07 instantiation: 5 findings + 5 links / 3 KPIs / 5 maintenance task templates');

SELECT pg_temp.t(
  (SELECT count(*) FROM public.controlled_documents
    WHERE client_org_id='cc000005-0000-0000-0000-000000000003'
      AND reference LIKE 'TESTFIX-%') >= 3,
  '08 instantiation: 3 controlled documents at client level');

-- calc columns engine-written (recompute): A-02 = weeks 1..4 → due Friday wk4
SELECT pg_temp.t(
  (SELECT due_date FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-02')
     = DATE '2026-11-27'
  AND (SELECT phase FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-02')
     = 'TESTFIX Assess & Design'
  AND (SELECT rag FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-02')
     IS NOT NULL,
  '09 calc columns written via engine: A-02 due 2026-11-27 (Fri wk4), phase+rag set');

SELECT pg_temp.t(
  (SELECT planned_close_date FROM public.register_items
    WHERE programme_id=:'prog'::uuid AND ref='R-04') = DATE '2026-11-13',
  '10 calc: register R-04 planned_close_date = Friday of week 2');

-- ============================================================================
-- atomicity: a published version with an unresolvable dep must abort cleanly
-- (broken template lives only inside this txn — rolled back afterwards)
-- ============================================================================
BEGIN;
INSERT INTO public.programme_templates (id, framework, jurisdiction, name)
VALUES ('f5000005-0000-0000-0000-00000000ff99','popia_paia','ZA','TESTFIX W105 broken template');
INSERT INTO public.programme_template_versions
    (id, template_id, number, status, published_by, published_at, content)
SELECT 'f6000005-0000-0000-0000-00000000ff99',
       'f5000005-0000-0000-0000-00000000ff99', 1, 'published',
       'aa000005-0000-0000-0000-000000000002', now(),
       jsonb_set(content, '{activity_library,0,dependencies}', '["ZZ-99"]'::jsonb)
  FROM public.programme_template_versions
 WHERE id = 'f6000005-0000-0000-0000-000000000001';
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.create_programme('cc000005-0000-0000-0000-000000000003',
                'f6000005-0000-0000-0000-00000000ff99','W1-05 e2e broken',DATE '2026-11-02');
    PERFORM pg_temp.t(false, '11 instantiation aborts on unresolvable dep ref');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(NOT EXISTS (SELECT 1 FROM public.programmes
                                   WHERE name='W1-05 e2e broken'),
      '11 instantiation atomic — bad content left no programme row: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- ============================================================================
-- update_activity / reorder_activity / add_activity (FR-TPL-04)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
-- complete A-01 (needed later for register closure)
SELECT public.update_activity(a.id, '{"status":"Complete","pct_complete":100}')
  FROM public.activities a WHERE a.programme_id=:'prog'::uuid AND a.ref='A-01';
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (SELECT status FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-01') = 'Complete'
  AND (SELECT pct_complete FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-01') = 100,
  '12 update_activity: A-01 marked Complete at 100%');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.activity_status_history h
     JOIN public.activities a ON a.id=h.activity_id
    WHERE a.programme_id=:'prog'::uuid AND a.ref='A-01'
      AND h.old_status='Not started' AND h.new_status='Complete'
      AND h.changed_by='aa000005-0000-0000-0000-000000000006'),
  '13 status change appended to activity_status_history (existing trigger)');

-- FR-SCH-04: A-03 depends on A-02 (incomplete) — start without override denied
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.update_activity(a.id, '{"status":"In progress"}')
      FROM public.activities a WHERE a.programme_id=v_prog AND a.ref='A-03';
    PERFORM pg_temp.t(false, '14 FR-SCH-04: starting A-03 with open predecessor denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '14 FR-SCH-04: starting A-03 with open predecessor denied: '||SQLERRM);
  END;
END $$;
SELECT public.update_activity(a.id,
        '{"status":"In progress","dependency_override_reason":"W1-05 e2e override — parallel track"}') AS up
  FROM public.activities a WHERE a.programme_id=:'prog'::uuid AND a.ref='A-03' \gset
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (SELECT status FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-03') = 'In progress'
  AND (SELECT dependency_override_reason FROM public.activities
        WHERE programme_id=:'prog'::uuid AND ref='A-03')
      = 'W1-05 e2e override — parallel track',
  '15 FR-SCH-04 override: reason recorded, A-03 started');

-- reorder: move A-02 to weeks 2..5 → due Friday of week 5 = 2026-12-04
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT public.reorder_activity(a.id, 2, 5)
  FROM public.activities a WHERE a.programme_id=:'prog'::uuid AND a.ref='A-02';
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (SELECT due_date FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-02')
     = DATE '2026-12-04',
  '16 reorder_activity: A-02 moved to weeks 2–5, due recalculated to Fri wk5');

-- add_activity: partner-defined item + duplicate ref denied
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT public.add_activity(:'prog'::uuid, 'X-01', 'W1-05 e2e partner activity',
        NULL, 11, 12, false, false,
        ARRAY[(SELECT a.id FROM public.activities a
                WHERE a.programme_id=:'prog'::uuid AND a.ref='A-01')]::uuid[]) AS xa \gset
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.add_activity(v_prog, 'A-02', 'dup ref', NULL, 1, 1);
    PERFORM pg_temp.t(false, '18 add_activity: duplicate ref denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '18 add_activity: duplicate ref denied: '||SQLERRM);
  END;
END $$;
COMMIT;
RESET ROLE;
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.activities a
    WHERE a.id = :'xa'::uuid AND a.ref='X-01' AND a.status='Not started'
      AND a.programme_id=:'prog'::uuid),
  '17 add_activity: X-01 created at Not started');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.activity_status_history h
    WHERE h.activity_id=:'xa'::uuid AND h.old_status IS NULL AND h.new_status='Not started'),
  '19 add_activity: initial status-history row written');

-- non-write role denied
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.update_activity(
              (SELECT a.id FROM public.activities a
                WHERE a.programme_id=v_prog AND a.ref='A-04'),
              '{"status":"In progress"}');
    PERFORM pg_temp.t(false, '20 contributor (no write role) activity edit denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '20 contributor (no write role) activity edit denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- ============================================================================
-- publish v1.1 (content author) then apply_template_version — persists
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
BEGIN
  IF (SELECT status FROM public.programme_template_versions
       WHERE id='f6000005-0000-0000-0000-000000000002') = 'draft' THEN
    PERFORM public.publish_template_version('f6000005-0000-0000-0000-000000000002');
  END IF;
END $$;
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (SELECT status FROM public.programme_template_versions
    WHERE id='f6000005-0000-0000-0000-000000000002') = 'published',
  '21 v1.1 published by content_author (running programme still on v1)');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT public.apply_template_version(:'prog'::uuid,
        'f6000005-0000-0000-0000-000000000002') AS diff \gset
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (:'diff'::jsonb #>> '{activities,added}')::int = 1
  AND (:'diff'::jsonb #>> '{activities,retained}')::int >= 1,
  '22 apply_template_version diff: A-09 added, completed A-01 retained');

SELECT pg_temp.t(
  (SELECT status FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-01') = 'Complete'
  AND (SELECT pct_complete FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-01') = 100
  AND (SELECT actual_completion FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-01')
      IS NOT NULL
  AND EXISTS (SELECT 1 FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-09'
               AND status='Not started'),
  '23 apply preserves completed work; new activity A-09 instantiated');

SELECT pg_temp.t(
  (SELECT target FROM public.kpis WHERE programme_id=:'prog'::uuid
    AND name='TESTFIX Staff training coverage') = 85
  AND (SELECT template_version_id FROM public.programmes WHERE id=:'prog'::uuid)
      = 'f6000005-0000-0000-0000-000000000002',
  '24 apply: unconfirmed KPI target re-synced to 85; version pinned to v1.1');

-- apply denied for a non-partner role (programme lead is client-side)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000017","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.apply_template_version(v_prog,
              'f6000005-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '25 apply denied for programme_lead (partner-only gate)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '25 apply denied for programme_lead (partner-only gate): '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- ============================================================================
-- close_register_item (§9.4) — non-AO denied, AO closes with acceptance record
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.close_register_item(
              (SELECT r.id FROM public.register_items r
                WHERE r.programme_id=v_prog AND r.ref='R-04'),
              ARRAY['EV-R-04-901']);
    PERFORM pg_temp.t(false, '26 non-AO close denied (partner admin is not AO/alternate)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '26 non-AO close denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- AO closes R-04: linked activity A-01 Complete; acceptance record supplied.
-- #87: the supplied ref must be REAL accepted evidence linked to R-04 in this
-- programme, so stage it admin-side (uploader U6, AO U16 accept review).
-- Claims from an earlier COMMITted block outlive it — clear them so this
-- staging runs as a true service write.
RESET request.jwt.claims;
INSERT INTO public.evidence_items (programme_id, register_item_id, file_key,
                                   uploaded_by, review_stage, outcome, evidence_ref)
SELECT :'prog'::uuid, r.id, 'w105/r04-io-appointment.pdf',
       'aa000005-0000-0000-0000-000000000006', 'decided', 'closes_finding', 'EV-R-04-901'
  FROM public.register_items r WHERE r.programme_id = :'prog'::uuid AND r.ref = 'R-04';
INSERT INTO public.evidence_reviews (evidence_item_id, stage, reviewer, decision)
SELECT e.id, 'accept', 'aa000005-0000-0000-0000-000000000016', 'accepted'
  FROM public.evidence_items e
 WHERE e.programme_id = :'prog'::uuid AND e.evidence_ref = 'EV-R-04-901';
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000016","role":"authenticated"}';
SELECT public.close_register_item(
        (SELECT r.id FROM public.register_items r
          WHERE r.programme_id=:'prog'::uuid AND r.ref='R-04'),
        ARRAY['EV-R-04-901']) AS closed \gset
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (SELECT status FROM public.register_items WHERE id=:'closed'::uuid) = 'Closed'
  AND (SELECT accepted_by FROM public.register_items WHERE id=:'closed'::uuid)
      = 'aa000005-0000-0000-0000-000000000016'
  AND (SELECT accepted_evidence_refs FROM public.register_items WHERE id=:'closed'::uuid)
      = '{EV-R-04-901}'::text[],
  '27 AO close: Closed + acceptance record stamped atomically (§9.4)');

-- precondition: R-01's linked activity A-03 not Complete → AO close still denied
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000016","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.close_register_item(
              (SELECT r.id FROM public.register_items r
                WHERE r.programme_id=v_prog AND r.ref='R-01'),
              ARRAY['EV-R-01-901']);
    PERFORM pg_temp.t(false, '28 §9.4 precondition: close denied with incomplete activity');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '28 §9.4 precondition: close denied with incomplete activity: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- ============================================================================
-- update_programme_settings — validation + FR-SCH-06 start-date recalc
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.update_programme_settings(v_prog, p_red_days_threshold => -1);
    PERFORM pg_temp.t(false, '29 negative red_days_threshold rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '29 negative red_days_threshold rejected: '||SQLERRM);
  END;
END $$;
SELECT public.update_programme_settings(:'prog'::uuid,
        p_red_days_threshold => 21,
        p_report_due_business_day => 3,
        p_programme_lead => 'aa000005-0000-0000-0000-000000000017',
        p_start_date => DATE '2026-11-09',
        p_reduced_capacity_weeks => '{3,7}');
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (SELECT red_days_threshold FROM public.programmes WHERE id=:'prog'::uuid) = 21
  AND (SELECT report_due_business_day FROM public.programmes WHERE id=:'prog'::uuid) = 3
  AND (SELECT programme_lead FROM public.programmes WHERE id=:'prog'::uuid)
      = 'aa000005-0000-0000-0000-000000000017'
  AND (SELECT reduced_capacity_weeks FROM public.programmes WHERE id=:'prog'::uuid) = '{3,7}'::int[],
  '30 settings: thresholds + lead + reduced-capacity weeks applied');
SELECT pg_temp.t(
  (SELECT due_date FROM public.activities WHERE programme_id=:'prog'::uuid AND ref='A-02')
     = DATE '2026-12-04',
  '31 FR-SCH-06: start_date +7d → dates recalculated (apply re-synced A-02 to wk1–4; due Fri wk4 = Dec 4)');

-- ============================================================================
-- transition_programme — legal moves only, logged; destination-scoped gates
-- (closing is partner-side: client_admin + programme_lead can never close;
--  programme_lead may move implementation→maintenance)
-- ============================================================================
-- mint fixture-style assignments for the role checks (idempotent, persists)
INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, origin)
SELECT 'aa000005-0000-0000-0000-000000000012','client','client_admin','client',
       'cc000005-0000-0000-0000-000000000003','manual'
 WHERE NOT EXISTS (SELECT 1 FROM public.role_assignments
                    WHERE user_id='aa000005-0000-0000-0000-000000000012'
                      AND role='client_admin' AND scope_type='client'
                      AND scope_id='cc000005-0000-0000-0000-000000000003'
                      AND end_date IS NULL);
INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, origin)
SELECT 'aa000005-0000-0000-0000-000000000017','client','programme_lead','programme',
       p.id,'manual' FROM public.programmes p
 WHERE p.name='W1-05 e2e programme'
   AND NOT EXISTS (SELECT 1 FROM public.role_assignments
                    WHERE user_id='aa000005-0000-0000-0000-000000000017'
                      AND role='programme_lead' AND scope_type='programme'
                      AND scope_id=p.id AND end_date IS NULL);

-- client-side client_admin cannot even reach maintenance
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.transition_programme(v_prog, 'maintenance');
    PERFORM pg_temp.t(false, '32 client_admin transition to maintenance denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '32 client_admin transition to maintenance denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.transition_programme(v_prog, 'closed');
    PERFORM pg_temp.t(false, '33 client_admin close denied (partner-side act)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '33 client_admin close denied (partner-side act): '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- programme_lead cannot close either
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000017","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.transition_programme(v_prog, 'closed');
    PERFORM pg_temp.t(false, '34 programme_lead close denied (partner-side act)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '34 programme_lead close denied (partner-side act): '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- but programme_lead CAN move implementation→maintenance
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000017","role":"authenticated"}';
SELECT public.transition_programme(:'prog'::uuid, 'maintenance');
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (SELECT status FROM public.programmes WHERE id=:'prog'::uuid) = 'maintenance',
  '35 programme_lead transition implementation→maintenance applied');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.transition_programme(v_prog, 'implementation');
    PERFORM pg_temp.t(false, '36 invalid transition maintenance→implementation rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '36 invalid transition maintenance→implementation rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT public.transition_programme(:'prog'::uuid, 'closed');
COMMIT;
RESET ROLE;
SELECT pg_temp.t(
  (SELECT status FROM public.programmes WHERE id=:'prog'::uuid) = 'closed'
  AND EXISTS (SELECT 1 FROM public.audit_log
               WHERE action='programme.transitioned'
                 AND detail->>'programme_id' = :'prog'
                 AND detail->>'to' = 'closed'),
  '37 partner_admin transition maintenance→closed applied + audit_log row');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE v_prog uuid := current_setting('e2e.prog')::uuid;
BEGIN
  BEGIN
    PERFORM public.transition_programme(v_prog, 'maintenance');
    PERFORM pg_temp.t(false, '38 closed is terminal — exit transition rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '38 closed is terminal — exit transition rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

-- ============================================================================
-- list_programmes — partner-console rollup + scoping
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_programmes(NULL) lp
    JOIN public.client_orgs co ON co.id = lp.client_org_id
    WHERE co.practice_id='bb000005-0000-0000-0000-000000000002') >= 2
  AND NOT EXISTS (SELECT 1 FROM public.list_programmes(NULL) lp
                   WHERE lp.client_org_id='cc000005-0000-0000-0000-000000000001'),
  '39 list_programmes: partner B sees own clients only (P3 + e2e programme)');
SELECT pg_temp.t(
  (SELECT activities_total FROM public.list_programmes(NULL) lp WHERE lp.programme_id=:'prog'::uuid) = 10
  AND (SELECT activities_complete FROM public.list_programmes(NULL) lp WHERE lp.programme_id=:'prog'::uuid) = 1
  AND (SELECT register_closed FROM public.list_programmes(NULL) lp WHERE lp.programme_id=:'prog'::uuid) = 1
  AND (SELECT framework FROM public.list_programmes(NULL) lp WHERE lp.programme_id=:'prog'::uuid) = 'popia_paia'
  AND (SELECT template_version_number FROM public.list_programmes(NULL) lp WHERE lp.programme_id=:'prog'::uuid) = 2
  AND (SELECT rag FROM public.list_programmes(NULL) lp WHERE lp.programme_id=:'prog'::uuid) IN ('Red','Amber','Green'),
  '40 list_programmes rollup: 10 activities (8+X-01+A-09), 1 complete, 1 closed finding, framework+version, rag');
ROLLBACK;
RESET ROLE;

-- cross-partner admin sees none of partner B's programmes
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM public.list_programmes(NULL) lp
               WHERE lp.programme_id=:'prog'::uuid),
  '41 cross-partner: partner A list excludes the partner B programme');
ROLLBACK;
RESET ROLE;

-- ============================================================================
-- licence capacity on create (FR-ONB-02): Partner A's programme_limit=2 is
-- fully used by P1+P2 — a third programme on C1 must fail once W1-07's
-- assert_licence_capacity exists (probed; skips cleanly on pre-W1-07 chains)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
BEGIN
  IF to_regprocedure('public.assert_licence_capacity(uuid,text)') IS NULL THEN
    PERFORM pg_temp.t(true,
      '42 licence capacity: assert_licence_capacity absent (pre-W1-07 chain) — skipped');
    RETURN;
  END IF;
  BEGIN
    PERFORM public.create_programme('cc000005-0000-0000-0000-000000000001',
              'f6000005-0000-0000-0000-000000000001','W1-05 e2e cap prog',DATE '2026-11-02');
    PERFORM pg_temp.t(false, '42 licence capacity: at-limit partner create denied (FR-ONB-02)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM ILIKE '%limit%',
      '42 licence capacity: at-limit partner create denied (FR-ONB-02): '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
