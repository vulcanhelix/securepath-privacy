-- ============================================================================
-- #92 retired activities frozen + #90 checklist item completion — psql
-- acceptance checks for 20261106000016_retired_and_checklists.sql
-- (FR-TPL-04, FR-QTR-01/02, §9.4 accepted-evidence rule, NFR-08).
--
-- SELF-CONTAINED: seeds its own @w1rc.test / 'W1RC%' namespace (two
-- partners, two clients, three programmes) and never reads or mutates the
-- shared TESTFIX world. Re-runnable: the namespace is wiped first and torn
-- down at the end (the NFR-09 evidence_immutable guard is suspended for the
-- wipe only — the suite accepts real evidence, which is then undeletable).
--
-- Evidence is accepted through the REAL chain (upload_evidence →
-- verify_evidence → accept_evidence), so "accepted" is exactly what the
-- platform mints.
--
-- JWT callers are simulated with SET ROLE authenticated + request.jwt.claims
-- inside the same transaction as the writes (e2e_role_assignments.sql
-- pattern). Every block ends with RESET ROLE + RESET request.jwt.claims.
--
-- Actors (a1ec0000-…-000N):
--   U1 padmin   partner_admin, partner A      — WRITE role on P1/P2
--   U2 ao       accountable_officer, client A — AO on P1/P2
--   U3 contrib  client_contributor, client A  — no write role (denied)
--   U4 pl       programme_lead on P1 and P2   — uploader / listed lead
--   U6 badmin   partner_admin, partner B      — other tenant
--
-- NOTE for local scratch runs: same auth shim as e2e_template_engine.sql
-- (newer auth.users columns + the coalesced auth.uid() body).
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_retired_checklists.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- W4-03: verify/accept now refuse items whose scan_status <> 'clean'.
-- This suite is about retired checklists, not the scan gate — simulate the
-- scanner resolving uploads to 'clean' (e2e_malware_scan covers refusal).
CREATE OR REPLACE FUNCTION pg_temp.scan_clean(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.evidence_items SET scan_status = 'clean' WHERE id = p_id;
  UPDATE public.malware_scan_queue SET state = 'done', finished_at = now()
   WHERE subject_id = p_id AND state <> 'done';
END $$;

-- ---------- wipe any earlier run ----------
ALTER TABLE public.evidence_items DISABLE TRIGGER evidence_immutable;
DELETE FROM notification_events WHERE scope->>'programme_id' IN
  (SELECT p.id::text FROM programmes p JOIN client_orgs c ON c.id = p.client_org_id
    WHERE c.name LIKE 'W1RC%');
DELETE FROM programmes WHERE client_org_id IN
  (SELECT id FROM client_orgs WHERE name LIKE 'W1RC%');
ALTER TABLE public.evidence_items ENABLE TRIGGER evidence_immutable;
DELETE FROM audit_log WHERE practice_id IN (SELECT id FROM practices WHERE name LIKE 'W1RC%')
   OR user_id IN (SELECT id FROM users WHERE email LIKE '%@w1rc.test');
DELETE FROM client_orgs WHERE name LIKE 'W1RC%';
DELETE FROM practices WHERE name LIKE 'W1RC%';
DELETE FROM role_assignments WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w1rc.test');
DELETE FROM users WHERE email LIKE '%@w1rc.test';
DELETE FROM auth.users WHERE email LIKE '%@w1rc.test';

-- ---------- seed ----------
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
  ('a1ec0000-0000-0000-0000-000000000001'::uuid, 'padmin@w1rc.test'),
  ('a1ec0000-0000-0000-0000-000000000002'::uuid, 'ao@w1rc.test'),
  ('a1ec0000-0000-0000-0000-000000000003'::uuid, 'contrib@w1rc.test'),
  ('a1ec0000-0000-0000-0000-000000000004'::uuid, 'pl@w1rc.test'),
  ('a1ec0000-0000-0000-0000-000000000006'::uuid, 'badmin@w1rc.test')
) AS u(id, email);
INSERT INTO users (id, email, full_name)
SELECT id, email, split_part(email, '@', 1) FROM auth.users WHERE email LIKE '%@w1rc.test';

INSERT INTO practices (id, name) VALUES
  ('b1ec0000-0000-0000-0000-00000000000a', 'W1RC Partner A'),
  ('b1ec0000-0000-0000-0000-00000000000b', 'W1RC Partner B');
INSERT INTO client_orgs (id, practice_id, name) VALUES
  ('c1ec0000-0000-0000-0000-00000000000a', 'b1ec0000-0000-0000-0000-00000000000a', 'W1RC Client A'),
  ('c1ec0000-0000-0000-0000-00000000000b', 'b1ec0000-0000-0000-0000-00000000000b', 'W1RC Client B');
INSERT INTO programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d1ec0000-0000-0000-0000-000000000001', 'c1ec0000-0000-0000-0000-00000000000a', 'W1RC P1', DATE '2026-11-02', 20),
  ('d1ec0000-0000-0000-0000-000000000002', 'c1ec0000-0000-0000-0000-00000000000a', 'W1RC P2', DATE '2026-11-02', 20),
  ('d1ec0000-0000-0000-0000-000000000003', 'c1ec0000-0000-0000-0000-00000000000b', 'W1RC P3', DATE '2026-11-02', 20);

INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id, start_date, end_date) VALUES
  ('a1ec0000-0000-0000-0000-000000000001','partner','partner_admin','partner','b1ec0000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a1ec0000-0000-0000-0000-000000000002','client','accountable_officer','client','c1ec0000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a1ec0000-0000-0000-0000-000000000003','client','client_contributor','client','c1ec0000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a1ec0000-0000-0000-0000-000000000004','client','programme_lead','programme','d1ec0000-0000-0000-0000-000000000001', CURRENT_DATE, NULL),
  ('a1ec0000-0000-0000-0000-000000000004','client','programme_lead','programme','d1ec0000-0000-0000-0000-000000000002', CURRENT_DATE, NULL),
  ('a1ec0000-0000-0000-0000-000000000006','partner','partner_admin','partner','b1ec0000-0000-0000-0000-00000000000b', CURRENT_DATE, NULL);

INSERT INTO workstreams (id, programme_id, name) VALUES
  ('e1ec0000-0000-0000-0000-000000000001', 'd1ec0000-0000-0000-0000-000000000001', 'W1RC governance');

-- P1: X1 (to retire), X2 (live), X3 (to retire, in workstream W), Y1 in P2.
-- U4 (pl) is a listed lead on X1 so the lead path of update_activity_status
-- is exercised too.
INSERT INTO activities (id, programme_id, workstream_id, ref, text, leads, start_week, end_week, status) VALUES
  ('f1ec0000-0000-0000-0000-000000000001','d1ec0000-0000-0000-0000-000000000001',NULL,'RC-X1','privacy notice drafted',
     ARRAY['a1ec0000-0000-0000-0000-000000000004'::uuid],1,4,'In progress'),
  ('f1ec0000-0000-0000-0000-000000000002','d1ec0000-0000-0000-0000-000000000001',NULL,'RC-X2','operator agreements',
     '{}',1,6,'In progress'),
  ('f1ec0000-0000-0000-0000-000000000003','d1ec0000-0000-0000-0000-000000000001','e1ec0000-0000-0000-0000-000000000001','RC-X3','drill planned',
     '{}',2,8,'Not started'),
  ('f1ec0000-0000-0000-0000-000000000005','d1ec0000-0000-0000-0000-000000000002',NULL,'RC-Y1','P2 work',
     '{}',1,4,'In progress'),
  -- FR-SCH-04 pair: X4 waits only on X1 (to be retired, never Complete);
  -- X5 waits on the live, In-progress X2
  ('f1ec0000-0000-0000-0000-000000000006','d1ec0000-0000-0000-0000-000000000001',NULL,'RC-X4','after X1',
     '{}',1,20,'Not started'),
  ('f1ec0000-0000-0000-0000-000000000007','d1ec0000-0000-0000-0000-000000000001',NULL,'RC-X5','after X2',
     '{}',1,20,'Not started');
INSERT INTO activity_deps (activity_id, depends_on_activity_id) VALUES
  ('f1ec0000-0000-0000-0000-000000000006','f1ec0000-0000-0000-0000-000000000001'),
  ('f1ec0000-0000-0000-0000-000000000007','f1ec0000-0000-0000-0000-000000000002');
INSERT INTO register_items (id, programme_id, ref, finding, priority, planned_close_week, status) VALUES
  ('91ec0000-0000-0000-0000-000000000001','d1ec0000-0000-0000-0000-000000000001','RC-R1','no operator clauses','High',7,'In progress'),
  ('91ec0000-0000-0000-0000-000000000002','d1ec0000-0000-0000-0000-000000000001','RC-R2','no DPIA process','Medium',9,'Not started'),
  ('91ec0000-0000-0000-0000-000000000003','d1ec0000-0000-0000-0000-000000000001','RC-R3','no records schedule','Low',9,'In progress'),
  ('91ec0000-0000-0000-0000-000000000005','d1ec0000-0000-0000-0000-000000000002','RC-Q1','P2 finding','High',5,'In progress');
INSERT INTO register_item_activities (register_item_id, activity_id) VALUES
  ('91ec0000-0000-0000-0000-000000000001','f1ec0000-0000-0000-0000-000000000002'),
  ('91ec0000-0000-0000-0000-000000000005','f1ec0000-0000-0000-0000-000000000005');

-- quarterly checklist on P1 (service path, as the fixtures do): Q-1 and Q-3
-- have an evidence slot, Q-2 does not.
INSERT INTO checklist_instances (id, programme_id, kind, period, items) VALUES
  ('c7ec0000-0000-0000-0000-000000000001','d1ec0000-0000-0000-0000-000000000001','quarterly','2026-Q4',
   '[{"ref":"Q-1","label":"operator agreements reviewed","evidence_required":true,"evidence_id":null,"done":false},
     {"ref":"Q-2","label":"training refresher booked","evidence_required":false,"evidence_id":null,"done":false},
     {"ref":"Q-3","label":"breach drill evidence","evidence_required":true,"evidence_id":null,"done":false}]');

UPDATE register_items SET lead = 'a1ec0000-0000-0000-0000-000000000004'
 WHERE id = '91ec0000-0000-0000-0000-000000000002';

CREATE TEMP TABLE w1rc (k text PRIMARY KEY, v text);
GRANT SELECT, INSERT, UPDATE, DELETE ON w1rc TO authenticated;

SELECT pg_temp.t(
  (SELECT count(*) FROM activities WHERE ref LIKE 'RC-%') = 6
  AND (SELECT count(*) FROM register_items WHERE ref LIKE 'RC-%') = 4
  AND (SELECT bool_and(active) FROM activities WHERE ref LIKE 'RC-%')
  AND (SELECT jsonb_array_length(items) FROM checklist_instances
        WHERE id='c7ec0000-0000-0000-0000-000000000001') = 3,
  '00 seed: W1RC namespace (6 live activities, 4 findings, one 3-item quarterly checklist)');


-- ============================================================================
-- A. #92 — retire X1 + X3, then every edit path is refused
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.retire_activity('f1ec0000-0000-0000-0000-000000000001', 'moved to cyber track');
  PERFORM public.retire_activity('f1ec0000-0000-0000-0000-000000000003', 'superseded');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT NOT active AND retired_reason = 'moved to cyber track'
     FROM activities WHERE id='f1ec0000-0000-0000-0000-000000000001')
  AND (SELECT NOT active FROM activities WHERE id='f1ec0000-0000-0000-0000-000000000003'),
  '01 retire_activity still passes the guard (live → retired is not an edit of a retired row)');

-- 02..06 the JWT edit paths, each in its own savepoint
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.update_activity('f1ec0000-0000-0000-0000-000000000001', '{"text":"renamed"}');
    PERFORM pg_temp.t(false, '02 update_activity on a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%RC-X1 is retired%cannot be edited%',
      '02 update_activity on a retired activity rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_activity_status('f1ec0000-0000-0000-0000-000000000001', 'Complete', 'done');
    PERFORM pg_temp.t(false, '03 update_activity_status (write role) on a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%is retired%',
      '03 update_activity_status (write role) on a retired activity rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.reorder_activity('f1ec0000-0000-0000-0000-000000000001', 2, 5);
    PERFORM pg_temp.t(false, '04 reorder_activity on a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%is retired%',
      '04 reorder_activity on a retired activity rejected: '||SQLERRM);
  END;
  BEGIN
    UPDATE public.activities SET text = 'direct edit', comments = 'x'
     WHERE id = 'f1ec0000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '05 direct column-grant UPDATE of a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLSTATE = '55000' AND SQLERRM LIKE '%is retired%',
      '05 direct column-grant UPDATE of a retired activity rejected: '||SQLERRM);
  END;
  BEGIN
    UPDATE public.activities SET rescheduled_date = DATE '2027-01-01'
     WHERE id = 'f1ec0000-0000-0000-0000-000000000003';
    PERFORM pg_temp.t(false, '06 direct UPDATE of rescheduled_date (W1-01 grant) on a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%RC-X3 is retired%',
      '06 direct UPDATE of rescheduled_date (W1-01 grant) on a retired activity rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 07 the programme lead, also a listed lead on X1, via the #82 status RPC
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.update_activity_status('f1ec0000-0000-0000-0000-000000000001', 'At risk',
              p_recovery_date => DATE '2026-12-31');
    PERFORM pg_temp.t(false, '07 update_activity_status by the programme lead (also a listed lead) on a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%is retired%',
      '07 update_activity_status by the programme lead (also a listed lead) on a retired activity rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 08 the service path is frozen too (no JWT exemption)
DO $$ BEGIN
  BEGIN
    UPDATE public.activities SET status = 'Complete'
     WHERE id = 'f1ec0000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '08 service-path (no JWT) edit of a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%is retired%',
      '08 service-path (no JWT) edit of a retired activity rejected: '||SQLERRM);
  END;
END $$;

-- 09 CALC-only writes pass: blank the calc columns service-side, then the
--    engine recompute (under a WRITE JWT) refreshes them on the retired row
UPDATE public.activities SET due_date = NULL, start_date = NULL, rag = NULL, month = NULL
 WHERE id = 'f1ec0000-0000-0000-0000-000000000001';
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.recompute_programme_progress('d1ec0000-0000-0000-0000-000000000001');
  PERFORM pg_temp.t(true, '09 recompute_programme_progress over a programme with retired rows passes');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '09 recompute_programme_progress over a programme with retired rows passes: '||SQLERRM);
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT due_date = DATE '2026-11-27' AND start_date = DATE '2026-11-02' AND rag IS NOT NULL
          AND text = 'privacy notice drafted' AND status = 'In progress' AND NOT active
     FROM activities WHERE id='f1ec0000-0000-0000-0000-000000000001'),
  '10 retired row: CALC columns blanked + recomputed (due Fri wk 4), every other column unchanged');

-- 11 a live activity is unaffected
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.update_activity('f1ec0000-0000-0000-0000-000000000002', '{"comments":"on track"}');
  PERFORM pg_temp.t((SELECT comments FROM public.activities
                      WHERE id='f1ec0000-0000-0000-0000-000000000002') = 'on track',
    '11 update_activity on a LIVE activity still works');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '11 update_activity on a LIVE activity still works: '||SQLERRM);
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 12 FK ON DELETE SET NULL (workstream deleted) still runs on a retired row
BEGIN;
DO $$ BEGIN
  DELETE FROM public.workstreams WHERE id = 'e1ec0000-0000-0000-0000-000000000001';
  PERFORM pg_temp.t(
    (SELECT workstream_id IS NULL AND NOT active FROM public.activities
      WHERE id='f1ec0000-0000-0000-0000-000000000003'),
    '12 FK SET NULL action (workstream deleted) passes on a retired activity');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '12 FK SET NULL action (workstream deleted) passes on a retired activity: '||SQLERRM);
END $$;
ROLLBACK;

-- 13 apply_template_version skips a retired activity (else the whole apply
--    would now fail on the freeze). Templates live inside this txn only.
BEGIN;
INSERT INTO programme_templates (id, framework, name)
VALUES ('f5ec0000-0000-0000-0000-000000000001', 'popia_paia', 'W1RC template');
INSERT INTO programme_template_versions (id, template_id, number, status, published_by, published_at, content)
VALUES
  ('f6ec0000-0000-0000-0000-000000000001','f5ec0000-0000-0000-0000-000000000001',1,'published',
   'a1ec0000-0000-0000-0000-000000000001', now(),
   '{"phases":[],"workstreams":[],"findings_map":[],"kpis":[],"maintenance_set":[],"document_set":[],
     "activity_library":[{"ref":"RC-X1","text":"privacy notice drafted","start_week":1,"end_week":4},
                         {"ref":"RC-X2","text":"operator agreements","start_week":1,"end_week":6}]}'),
  ('f6ec0000-0000-0000-0000-000000000002','f5ec0000-0000-0000-0000-000000000001',2,'published',
   'a1ec0000-0000-0000-0000-000000000001', now(),
   '{"phases":[],"workstreams":[],"findings_map":[],"kpis":[],"maintenance_set":[],"document_set":[],
     "activity_library":[{"ref":"RC-X1","text":"privacy notice REWRITTEN","start_week":2,"end_week":5},
                         {"ref":"RC-X2","text":"operator agreements v2","start_week":1,"end_week":6}]}');
UPDATE programmes SET template_version_id = 'f6ec0000-0000-0000-0000-000000000001'
 WHERE id = 'd1ec0000-0000-0000-0000-000000000001';
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ DECLARE d jsonb; BEGIN
  d := public.apply_template_version('d1ec0000-0000-0000-0000-000000000001',
                                     'f6ec0000-0000-0000-0000-000000000002');
  PERFORM pg_temp.t(
    (SELECT text = 'privacy notice drafted' AND start_week = 1 AND NOT active
       FROM public.activities WHERE id='f1ec0000-0000-0000-0000-000000000001')
    AND (SELECT text FROM public.activities WHERE id='f1ec0000-0000-0000-0000-000000000002')
        = 'operator agreements v2'
    AND (d #>> '{activities,retained}')::int >= 1,
    '13 apply_template_version: retired RC-X1 left untouched (retained), live RC-X2 re-synced');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '13 apply_template_version skips retired activities: '||SQLERRM);
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ============================================================================
-- A2. #92 — retired register items are frozen too
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.retire_register_item('91ec0000-0000-0000-0000-000000000002', 'out of scope');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    UPDATE public.register_items SET finding = 'direct edit', priority = 'High'
     WHERE id = '91ec0000-0000-0000-0000-000000000002';
    PERFORM pg_temp.t(false, '14 direct column-grant UPDATE of a retired register item rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLSTATE = '55000' AND SQLERRM LIKE '%RC-R2 is retired%cannot be edited%',
      '14 direct column-grant UPDATE of a retired register item rejected: '||SQLERRM);
  END;
  BEGIN
    UPDATE public.register_items SET status = 'In progress'
     WHERE id = '91ec0000-0000-0000-0000-000000000002';
    PERFORM pg_temp.t(false, '15 direct status UPDATE of a retired register item rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%is retired%',
      '15 direct status UPDATE of a retired register item rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

DO $$ BEGIN
  BEGIN
    UPDATE public.register_items SET planned_close_week = 12
     WHERE id = '91ec0000-0000-0000-0000-000000000002';
    PERFORM pg_temp.t(false, '16 service-path edit of a retired register item rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%is retired%',
      '16 service-path edit of a retired register item rejected: '||SQLERRM);
  END;
END $$;

-- 17 CALC-only writes pass: blank them, then recompute refreshes them
UPDATE public.register_items SET planned_close_date = NULL, days_overdue = NULL
 WHERE id = '91ec0000-0000-0000-0000-000000000002';
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.recompute_programme_progress('d1ec0000-0000-0000-0000-000000000001');
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT planned_close_date = DATE '2027-01-01' AND finding = 'no DPIA process' AND NOT active
     FROM register_items WHERE id='91ec0000-0000-0000-0000-000000000002'),
  '17 retired finding: CALC planned_close_date recomputed (Fri wk 9), other columns unchanged');

-- 18 FK ON DELETE SET NULL (the lead's user row deleted) passes
BEGIN;
DO $$ BEGIN
  DELETE FROM public.role_assignments WHERE user_id = 'a1ec0000-0000-0000-0000-000000000004';
  DELETE FROM public.users WHERE id = 'a1ec0000-0000-0000-0000-000000000004';
  PERFORM pg_temp.t(
    (SELECT lead IS NULL AND NOT active FROM public.register_items
      WHERE id='91ec0000-0000-0000-0000-000000000002'),
    '18 FK SET NULL action (lead user deleted) passes on a retired register item');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '18 FK SET NULL action (lead user deleted) passes on a retired register item: '||SQLERRM);
END $$;
ROLLBACK;

-- 19 apply_template_version skips a retired finding (no re-sync, no relink)
BEGIN;
INSERT INTO programme_templates (id, framework, name)
VALUES ('f5ec0000-0000-0000-0000-000000000002', 'popia_paia', 'W1RC template R');
INSERT INTO programme_template_versions (id, template_id, number, status, published_by, published_at, content)
VALUES
  ('f6ec0000-0000-0000-0000-000000000011','f5ec0000-0000-0000-0000-000000000002',1,'published',
   'a1ec0000-0000-0000-0000-000000000001', now(),
   '{"phases":[],"workstreams":[],"kpis":[],"maintenance_set":[],"document_set":[],"activity_library":[],
     "findings_map":[{"ref":"RC-R2","finding":"no DPIA process","priority":"Medium","planned_close_week":9},
                     {"ref":"RC-R3","finding":"no records schedule","priority":"Low","planned_close_week":9}]}'),
  ('f6ec0000-0000-0000-0000-000000000012','f5ec0000-0000-0000-0000-000000000002',2,'published',
   'a1ec0000-0000-0000-0000-000000000001', now(),
   '{"phases":[],"workstreams":[],"kpis":[],"maintenance_set":[],"document_set":[],"activity_library":[],
     "findings_map":[{"ref":"RC-R2","finding":"DPIA process REWRITTEN","priority":"High","planned_close_week":10,
                      "linked_activities":["RC-X2"]},
                     {"ref":"RC-R3","finding":"records schedule v2","priority":"Low","planned_close_week":9}]}');
UPDATE programmes SET template_version_id = 'f6ec0000-0000-0000-0000-000000000011'
 WHERE id = 'd1ec0000-0000-0000-0000-000000000001';
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ DECLARE d jsonb; BEGIN
  d := public.apply_template_version('d1ec0000-0000-0000-0000-000000000001',
                                     'f6ec0000-0000-0000-0000-000000000012');
  PERFORM pg_temp.t(
    (SELECT finding = 'no DPIA process' AND priority = 'Medium' AND NOT active
       FROM public.register_items WHERE id='91ec0000-0000-0000-0000-000000000002')
    AND NOT EXISTS (SELECT 1 FROM public.register_item_activities
                     WHERE register_item_id='91ec0000-0000-0000-0000-000000000002')
    AND (SELECT finding FROM public.register_items WHERE id='91ec0000-0000-0000-0000-000000000003')
        = 'records schedule v2'
    AND (d #>> '{register_items,retained}')::int >= 1,
    '19 apply_template_version: retired RC-R2 untouched + not relinked (retained), live RC-R3 re-synced');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '19 apply_template_version skips retired findings: '||SQLERRM);
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ============================================================================
-- A3. #92 — FR-SCH-04 ignores retired predecessors
-- ============================================================================
SELECT pg_temp.t(
  public.activity_open_predecessors('f1ec0000-0000-0000-0000-000000000006') = 0
  AND public.activity_open_predecessors('f1ec0000-0000-0000-0000-000000000007') = 1,
  '41 activity_open_predecessors: retired In-progress X1 not counted (X4 = 0), live X2 counted (X5 = 1)');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.update_activity('f1ec0000-0000-0000-0000-000000000006', '{"status":"In progress"}');
    PERFORM pg_temp.t((SELECT status FROM public.activities
                        WHERE id='f1ec0000-0000-0000-0000-000000000006') = 'In progress',
      '42 update_activity starts X4 with no override (its only predecessor is retired)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(false, '42 update_activity starts X4 with no override: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_activity('f1ec0000-0000-0000-0000-000000000007', '{"status":"In progress"}');
    PERFORM pg_temp.t(false, '43 update_activity still gates X5 on its live incomplete predecessor');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%1 predecessor(s) incomplete%FR-SCH-04%',
      '43 update_activity still gates X5 on its live incomplete predecessor: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.update_activity_status('f1ec0000-0000-0000-0000-000000000006', 'In progress');
    PERFORM pg_temp.t((SELECT status FROM public.activities
                        WHERE id='f1ec0000-0000-0000-0000-000000000006') = 'In progress',
      '44 update_activity_status starts X4 with no override (retired predecessor ignored)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(false, '44 update_activity_status starts X4 with no override: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_activity_status('f1ec0000-0000-0000-0000-000000000007', 'In progress');
    PERFORM pg_temp.t(false, '45 update_activity_status still gates X5 on its live incomplete predecessor');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%1 predecessor(s) incomplete%FR-SCH-04%',
      '45 update_activity_status still gates X5 on its live incomplete predecessor: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ============================================================================
-- B. accept evidence through the REAL chain
-- ============================================================================
-- E1 on R1/X2 (P1)      → accepted
-- E2 on R1/X2 (P1)      → verified only, NOT accepted
-- E3 on Q1/Y1 (P2)      → accepted, but another programme
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  INSERT INTO w1rc VALUES ('e1', public.upload_evidence('f1ec0000-0000-0000-0000-000000000002',
      '91ec0000-0000-0000-0000-000000000001','w1rc/e1.pdf',NULL,'W1RC e1',NULL,NULL)::text);
  INSERT INTO w1rc VALUES ('e2', public.upload_evidence('f1ec0000-0000-0000-0000-000000000002',
      '91ec0000-0000-0000-0000-000000000001','w1rc/e2.pdf',NULL,'W1RC e2',NULL,NULL)::text);
  INSERT INTO w1rc VALUES ('e3', public.upload_evidence('f1ec0000-0000-0000-0000-000000000005',
      '91ec0000-0000-0000-0000-000000000005','w1rc/e3.pdf',NULL,'W1RC e3',NULL,NULL)::text);
  PERFORM pg_temp.scan_clean((SELECT v FROM w1rc WHERE k='e1')::uuid);
  PERFORM pg_temp.scan_clean((SELECT v FROM w1rc WHERE k='e2')::uuid);
  PERFORM pg_temp.scan_clean((SELECT v FROM w1rc WHERE k='e3')::uuid);
END $$;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.verify_evidence((SELECT v FROM w1rc WHERE k='e1')::uuid, 'approved');
  PERFORM public.verify_evidence((SELECT v FROM w1rc WHERE k='e2')::uuid, 'approved');
  PERFORM public.verify_evidence((SELECT v FROM w1rc WHERE k='e3')::uuid, 'approved');
END $$;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.accept_evidence((SELECT v FROM w1rc WHERE k='e1')::uuid);
  PERFORM public.accept_evidence((SELECT v FROM w1rc WHERE k='e3')::uuid);
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  public.evidence_item_is_accepted((SELECT v FROM w1rc WHERE k='e1')::uuid)
  AND NOT public.evidence_item_is_accepted((SELECT v FROM w1rc WHERE k='e2')::uuid)
  AND public.evidence_item_is_accepted((SELECT v FROM w1rc WHERE k='e3')::uuid)
  AND (SELECT review_stage FROM evidence_items WHERE id=(SELECT v FROM w1rc WHERE k='e2')::uuid) = 'acceptance',
  '20 evidence_item_is_accepted (the shared 000013 rule): E1/E3 accepted, E2 verified but not accepted');


-- ============================================================================
-- B2. #92 — no evidence against a retired activity / finding
-- ============================================================================
-- E4 is filed on live RC-R3 first; RC-R3 is then retired (history case)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  INSERT INTO w1rc VALUES ('e4', public.upload_evidence(NULL,
      '91ec0000-0000-0000-0000-000000000003','w1rc/e4.pdf',NULL,'W1RC e4',NULL,NULL)::text);
  PERFORM pg_temp.scan_clean((SELECT v FROM w1rc WHERE k='e4')::uuid);
END $$;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.retire_register_item('91ec0000-0000-0000-0000-000000000003', 'merged into R1');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.upload_evidence('f1ec0000-0000-0000-0000-000000000001', NULL,
              'w1rc/x1.pdf', NULL, 'on a retired activity', NULL, NULL);
    PERFORM pg_temp.t(false, '46 upload_evidence against a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%RC-X1 is retired%evidence cannot be filed%',
      '46 upload_evidence against a retired activity rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.upload_evidence('f1ec0000-0000-0000-0000-000000000002',
              '91ec0000-0000-0000-0000-000000000002', 'w1rc/r2.pdf', NULL, 'on a retired finding', NULL, NULL);
    PERFORM pg_temp.t(false, '47 upload_evidence against a retired register item rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%RC-R2 is retired%evidence cannot be filed%',
      '47 upload_evidence against a retired register item (live activity) rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

DO $$ BEGIN
  BEGIN
    INSERT INTO public.evidence_items (programme_id, activity_id, file_key, uploaded_by)
    VALUES ('d1ec0000-0000-0000-0000-000000000001','f1ec0000-0000-0000-0000-000000000003',
            'w1rc/direct.pdf','a1ec0000-0000-0000-0000-000000000004');
    PERFORM pg_temp.t(false, '48 service-path INSERT of evidence on a retired activity rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%RC-X3 is retired%',
      '48 service-path INSERT of evidence on a retired activity rejected (trigger, every path): '||SQLERRM);
  END;
END $$;

-- 49 evidence filed before retirement stays and still moves through review
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.verify_evidence((SELECT v FROM w1rc WHERE k='e4')::uuid, 'approved');
  PERFORM pg_temp.t(
    (SELECT review_stage = 'acceptance' AND register_item_id = '91ec0000-0000-0000-0000-000000000003'
       FROM public.evidence_items WHERE id = (SELECT v FROM w1rc WHERE k='e4')::uuid),
    '49 pre-retirement evidence kept and still verifiable (the guard only checks new links)');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '49 pre-retirement evidence kept and still verifiable: '||SQLERRM);
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ============================================================================
-- C. #90 — complete_checklist_item
-- ============================================================================
-- 21..25 rejections (programme lead, a WRITE role)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-1',
              (SELECT v FROM w1rc WHERE k='e2')::uuid);
    PERFORM pg_temp.t(false, '21 non-accepted evidence rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%is not accepted evidence%',
      '21 non-accepted evidence rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-1',
              (SELECT v FROM w1rc WHERE k='e3')::uuid);
    PERFORM pg_temp.t(false, '22 accepted evidence of ANOTHER programme rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%does not match any evidence in this programme%',
      '22 accepted evidence of ANOTHER programme rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-1',
              gen_random_uuid());
    PERFORM pg_temp.t(false, '23 unknown evidence id rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%does not match any evidence in this programme%',
      '23 unknown evidence id rejected (same wording, no existence leak): '||SQLERRM);
  END;
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-3',
              NULL, 'did the drill, no file');
    PERFORM pg_temp.t(false, '24 evidence-slot item without evidence rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%evidence slot%',
      '24 evidence-slot item without evidence rejected (a note is not enough): '||SQLERRM);
  END;
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-9',
              (SELECT v FROM w1rc WHERE k='e1')::uuid);
    PERFORM pg_temp.t(false, '25 unknown item key rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%Q-9 not found%', '25 unknown item key rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-2', NULL, '   ');
    PERFORM pg_temp.t(false, '26 no evidence and a blank note rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%record a note%', '26 no evidence and a blank note rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 27 denied role (client_contributor) / 28 other tenant
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-1',
              (SELECT v FROM w1rc WHERE k='e1')::uuid);
    PERFORM pg_temp.t(false, '27 client_contributor denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLSTATE = '42501' AND SQLERRM LIKE '%requires a programme write role%',
      '27 client_contributor denied: '||SQLERRM);
  END;
END $$;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-1',
              (SELECT v FROM w1rc WHERE k='e1')::uuid);
    PERFORM pg_temp.t(false, '28 other-tenant partner_admin denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%checklist % not found%',
      '28 other-tenant partner_admin sees "not found": '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 29 happy path: Q-1 with accepted E1 (programme lead) — persists
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ DECLARE it jsonb; BEGIN
  it := public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-1',
          (SELECT v FROM w1rc WHERE k='e1')::uuid, 'contracts checked');
  INSERT INTO w1rc VALUES ('it1', it::text);
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT (items->0->>'done')::boolean
          AND items->0->>'evidence_id' = (SELECT v FROM w1rc WHERE k='e1')
          AND items->0->>'completed_by' = 'a1ec0000-0000-0000-0000-000000000004'
          AND NOT (items->1->>'done')::boolean AND NOT (items->2->>'done')::boolean
     FROM checklist_instances WHERE id='c7ec0000-0000-0000-0000-000000000001')
  AND ((SELECT v FROM w1rc WHERE k='it1')::jsonb ->> 'done')::boolean
  AND (SELECT count(*) FROM checklist_item_completions
        WHERE checklist_id='c7ec0000-0000-0000-0000-000000000001' AND item_key='Q-1'
          AND evidence_id=(SELECT v FROM w1rc WHERE k='e1')::uuid
          AND completed_by='a1ec0000-0000-0000-0000-000000000004') = 1
  AND EXISTS (SELECT 1 FROM audit_log WHERE action='checklist.item_completed'
               AND detail->>'item_key'='Q-1'),
  '29 Q-1 completes with accepted same-programme evidence: item done, one history row, audit row');

-- 30 AO (no WRITE role, admitted as AO) completes the non-slot Q-2 with a note
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-2',
            NULL, 'refresher booked for 14 Jan');
  PERFORM pg_temp.t(true, '30 AO completes a non-slot item with a note');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '30 AO completes a non-slot item with a note: '||SQLERRM);
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

-- 31 re-completing is refused (completions are final)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.complete_checklist_item('c7ec0000-0000-0000-0000-000000000001', 'Q-1',
              (SELECT v FROM w1rc WHERE k='e1')::uuid);
    PERFORM pg_temp.t(false, '31 re-completing a done item rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%already complete%', '31 re-completing a done item rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 32 no direct write path: the checklist grants are gone
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    UPDATE public.checklist_instances SET items = jsonb_set(items, '{2,done}', 'true')
     WHERE id = 'c7ec0000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '32 direct UPDATE of checklist_instances.items denied');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, '32 direct UPDATE of checklist_instances.items denied (grant revoked)');
  END;
  BEGIN
    INSERT INTO public.checklist_item_completions (checklist_id, programme_id, item_key, note)
    VALUES ('c7ec0000-0000-0000-0000-000000000001','d1ec0000-0000-0000-0000-000000000001','Q-3','forged');
    PERFORM pg_temp.t(false, '33 direct INSERT into the completion ledger denied');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, '33 direct INSERT into the completion ledger denied (no grant)');
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 34 history is append-only even for the service/admin path
DO $$ BEGIN
  BEGIN
    UPDATE public.checklist_item_completions SET note = 'rewritten'
     WHERE checklist_id = 'c7ec0000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '34 UPDATE of a completion row rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%append-only%', '34 UPDATE of a completion row rejected (admin path): '||SQLERRM);
  END;
  BEGIN
    DELETE FROM public.checklist_item_completions
     WHERE checklist_id = 'c7ec0000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '35 DELETE of a completion row rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%append-only%', '35 DELETE of a completion row rejected (admin path): '||SQLERRM);
  END;
END $$;

-- 36 RLS on the ledger: own tenant reads both rows, other tenant none
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT count(*) AS own_n FROM public.checklist_item_completions \gset
SET request.jwt.claims = '{"sub":"a1ec0000-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT count(*) AS other_n FROM public.checklist_item_completions
 WHERE programme_id = 'd1ec0000-0000-0000-0000-000000000001' \gset
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(:own_n = 2 AND :other_n = 0,
  '36 completion ledger RLS: own partner reads 2 rows, other partner 0');

-- 37 the FK cascade of a deleted checklist still clears its ledger rows
BEGIN;
DO $$ BEGIN
  DELETE FROM public.checklist_instances WHERE id = 'c7ec0000-0000-0000-0000-000000000001';
  PERFORM pg_temp.t(NOT EXISTS (SELECT 1 FROM public.checklist_item_completions
                                 WHERE checklist_id = 'c7ec0000-0000-0000-0000-000000000001'),
    '37 deleting a checklist cascades through the append-only guard');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '37 deleting a checklist cascades through the append-only guard: '||SQLERRM);
END $$;
ROLLBACK;

-- 38 the register closure rule is unchanged by the refactor: E1's ref is
--    accepted + linked to R1 (via X2), E2 has no ref, a fake ref still fails
SELECT pg_temp.t(
  public.register_closure_ref_problem('91ec0000-0000-0000-0000-000000000001',
    ARRAY[(SELECT evidence_ref FROM evidence_items WHERE id=(SELECT v FROM w1rc WHERE k='e1')::uuid)]) IS NULL
  AND public.register_closure_ref_problem('91ec0000-0000-0000-0000-000000000001', ARRAY['EV-FAKE-1'])
      LIKE '%does not match any evidence in this programme%'
  AND public.register_closure_ref_problem('91ec0000-0000-0000-0000-000000000001',
    ARRAY[(SELECT evidence_ref FROM evidence_items WHERE id=(SELECT v FROM w1rc WHERE k='e3')::uuid)])
      LIKE '%does not match any evidence in this programme%',
  '38 register_closure_ref_problem (re-created on the shared predicate): same answers');

-- 39 helper surface: the predicates are not client-callable
SELECT pg_temp.t(
  NOT has_function_privilege('authenticated', 'public.evidence_item_is_accepted(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.trg_activity_retired_guard()', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.complete_checklist_item(uuid,text,uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.complete_checklist_item(uuid,text,uuid,text)', 'EXECUTE'),
  '39 execute surface: only complete_checklist_item is granted (authenticated only)');
SELECT pg_temp.t(
  NOT has_function_privilege('authenticated', 'public.activity_open_predecessors(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.trg_register_retired_guard()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.trg_evidence_retired_target()', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.update_activity(uuid,jsonb)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.update_activity_status(uuid,text,text,text,date,date)', 'EXECUTE'),
  '50 execute surface: new helpers private; re-created update RPCs keep their grants');


-- ---------- teardown ----------
ALTER TABLE public.evidence_items DISABLE TRIGGER evidence_immutable;
DELETE FROM notification_events WHERE scope->>'programme_id' IN
  (SELECT p.id::text FROM programmes p JOIN client_orgs c ON c.id = p.client_org_id
    WHERE c.name LIKE 'W1RC%');
DELETE FROM programmes WHERE client_org_id IN
  (SELECT id FROM client_orgs WHERE name LIKE 'W1RC%');
ALTER TABLE public.evidence_items ENABLE TRIGGER evidence_immutable;
DELETE FROM audit_log WHERE practice_id IN (SELECT id FROM practices WHERE name LIKE 'W1RC%')
   OR user_id IN (SELECT id FROM users WHERE email LIKE '%@w1rc.test');
DELETE FROM client_orgs WHERE name LIKE 'W1RC%';
DELETE FROM practices WHERE name LIKE 'W1RC%';
DELETE FROM role_assignments WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w1rc.test');
DELETE FROM users WHERE email LIKE '%@w1rc.test';
DELETE FROM auth.users WHERE email LIKE '%@w1rc.test';
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM programmes p JOIN client_orgs c ON c.id = p.client_org_id
                              WHERE c.name LIKE 'W1RC%')
  AND NOT EXISTS (SELECT 1 FROM checklist_item_completions
                   WHERE checklist_id = 'c7ec0000-0000-0000-0000-000000000001'),
  '51 teardown: W1RC namespace removed (ledger rows cascaded with the programme)');
