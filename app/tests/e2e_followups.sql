-- ============================================================================
-- W1 follow-ups — psql acceptance checks for 20261106000012_followups.sql:
--   FR-WKS-03 in the database (trg_activity_session_guard), weekly-log
--   attendees, programme_people (#81), update_activity_status (#82) and
--   week_due_date (#83).
--
-- SELF-CONTAINED: seeds its own @w1fu.test / 'W1FU%' namespace (two
-- practices, two clients, two programmes, two workstreams, eight activities)
-- and never reads or mutates the shared TESTFIX world. Re-runnable: the
-- namespace is wiped first and torn down at the end.
--
-- JWT callers are simulated with SET ROLE authenticated + request.jwt.claims
-- inside the same transaction as the writes (e2e_role_assignments.sql
-- pattern). SET ROLE and the claims GUC outlive COMMIT, so every block ends
-- with RESET ROLE + RESET request.jwt.claims (service-path steps run claim-free).
-- Dates are relative to CURRENT_DATE so the RAG outcomes are deterministic:
-- programme week 1 = Monday four weeks ago, so week 4 ended last Friday
-- (1–9 days ago, inside the default 14-day red threshold → Amber) and
-- week-15 items are Green.
--
-- NOTE for local scratch runs: same auth shim as e2e_template_engine.sql
-- (newer auth.users columns + the coalesced auth.uid() body).
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_followups.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- ---------- wipe any earlier run ----------
DELETE FROM programmes WHERE client_org_id IN
  (SELECT id FROM client_orgs WHERE name LIKE 'W1FU%');
DELETE FROM client_orgs WHERE name LIKE 'W1FU%';
DELETE FROM practices WHERE name LIKE 'W1FU%';
DELETE FROM audit_log WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w1fu.test');
DELETE FROM role_assignments WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w1fu.test');
DELETE FROM users WHERE email LIKE '%@w1fu.test';
DELETE FROM auth.users WHERE email LIKE '%@w1fu.test';

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
  ('a1f00000-0000-0000-0000-000000000001'::uuid, 'padmin@w1fu.test'),
  ('a1f00000-0000-0000-0000-000000000002'::uuid, 'wslead@w1fu.test'),
  ('a1f00000-0000-0000-0000-000000000003'::uuid, 'listed@w1fu.test'),
  ('a1f00000-0000-0000-0000-000000000004'::uuid, 'contrib@w1fu.test'),
  ('a1f00000-0000-0000-0000-000000000005'::uuid, 'badmin@w1fu.test'),
  ('a1f00000-0000-0000-0000-000000000006'::uuid, 'ended@w1fu.test'),
  ('a1f00000-0000-0000-0000-000000000007'::uuid, 'proglead@w1fu.test')
) AS u(id, email);
INSERT INTO users (id, email, full_name)
SELECT id, email, CASE email WHEN 'padmin@w1fu.test' THEN 'Pat Admin'
                             WHEN 'proglead@w1fu.test' THEN '  ' END
  FROM auth.users WHERE email LIKE '%@w1fu.test';

INSERT INTO practices (id, name) VALUES
  ('b1f00000-0000-0000-0000-00000000000a', 'W1FU Alpha'),
  ('b1f00000-0000-0000-0000-00000000000b', 'W1FU Beta');
INSERT INTO client_orgs (id, practice_id, name) VALUES
  ('c1f00000-0000-0000-0000-00000000000a', 'b1f00000-0000-0000-0000-00000000000a', 'W1FU Client A'),
  ('c1f00000-0000-0000-0000-00000000000b', 'b1f00000-0000-0000-0000-00000000000b', 'W1FU Client B');
INSERT INTO programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d1f00000-0000-0000-0000-000000000001', 'c1f00000-0000-0000-0000-00000000000a',
   'W1FU P1', date_trunc('week', CURRENT_DATE)::date - 28, 20),
  ('d1f00000-0000-0000-0000-000000000002', 'c1f00000-0000-0000-0000-00000000000b',
   'W1FU P2', date_trunc('week', CURRENT_DATE)::date - 28, 20);
INSERT INTO workstreams (id, programme_id, name, accountable_lead) VALUES
  ('e1f00000-0000-0000-0000-000000000001', 'd1f00000-0000-0000-0000-000000000001', 'W1FU WS1', NULL),
  ('e1f00000-0000-0000-0000-000000000002', 'd1f00000-0000-0000-0000-000000000001', 'W1FU WS2', NULL);

-- padmin: partner_admin Alpha · wslead: workstream_lead on WS1 only ·
-- listed: no role (a lead on LST) · contrib: client_contributor on A ·
-- badmin: partner_admin Beta · ended: programme_lead on P1, ended today ·
-- proglead: programme_lead on P1 (blank full_name → local-part fallback)
INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id, start_date, end_date) VALUES
  ('a1f00000-0000-0000-0000-000000000001','partner','partner_admin','partner','b1f00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a1f00000-0000-0000-0000-000000000002','client','workstream_lead','workstream','e1f00000-0000-0000-0000-000000000001', CURRENT_DATE, NULL),
  ('a1f00000-0000-0000-0000-000000000004','client','client_contributor','client','c1f00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a1f00000-0000-0000-0000-000000000005','partner','partner_admin','partner','b1f00000-0000-0000-0000-00000000000b', CURRENT_DATE, NULL),
  ('a1f00000-0000-0000-0000-000000000006','client','programme_lead','programme','d1f00000-0000-0000-0000-000000000001', CURRENT_DATE - 30, CURRENT_DATE),
  ('a1f00000-0000-0000-0000-000000000007','client','programme_lead','programme','d1f00000-0000-0000-0000-000000000001', CURRENT_DATE, NULL);

INSERT INTO activities (id, programme_id, workstream_id, ref, text, leads, start_week, end_week, status) VALUES
  ('f1f00000-0000-0000-0000-000000000001','d1f00000-0000-0000-0000-000000000001','e1f00000-0000-0000-0000-000000000001','FU-AMB','past due (Amber)','{}',1,4,'In progress'),
  ('f1f00000-0000-0000-0000-000000000002','d1f00000-0000-0000-0000-000000000001','e1f00000-0000-0000-0000-000000000001','FU-GRN','green item','{}',1,15,'In progress'),
  ('f1f00000-0000-0000-0000-000000000003','d1f00000-0000-0000-0000-000000000001','e1f00000-0000-0000-0000-000000000001','FU-GRN2','green item 2','{}',1,15,'In progress'),
  ('f1f00000-0000-0000-0000-000000000004','d1f00000-0000-0000-0000-000000000001','e1f00000-0000-0000-0000-000000000001','FU-PRED','predecessor','{}',1,15,'Not started'),
  ('f1f00000-0000-0000-0000-000000000005','d1f00000-0000-0000-0000-000000000001','e1f00000-0000-0000-0000-000000000001','FU-SUCC','successor','{}',2,15,'Not started'),
  ('f1f00000-0000-0000-0000-000000000006','d1f00000-0000-0000-0000-000000000001','e1f00000-0000-0000-0000-000000000001','FU-DEF','to defer','{}',1,15,'In progress'),
  ('f1f00000-0000-0000-0000-000000000007','d1f00000-0000-0000-0000-000000000001','e1f00000-0000-0000-0000-000000000002','FU-OWS','other workstream','{}',1,15,'In progress'),
  ('f1f00000-0000-0000-0000-000000000008','d1f00000-0000-0000-0000-000000000001','e1f00000-0000-0000-0000-000000000002','FU-LST','listed lead item','{a1f00000-0000-0000-0000-000000000003}',1,15,'In progress');
INSERT INTO activity_deps (activity_id, depends_on_activity_id) VALUES
  ('f1f00000-0000-0000-0000-000000000005','f1f00000-0000-0000-0000-000000000004');

SELECT pg_temp.t(
  (SELECT count(*) FROM activities WHERE programme_id='d1f00000-0000-0000-0000-000000000001') = 8
  AND (SELECT count(*) FROM activities WHERE programme_id='d1f00000-0000-0000-0000-000000000001' AND rag IS NOT NULL) = 0,
  '00 seed: W1FU namespace (8 activities, rag not yet computed)');

-- ============================================================================
-- A. FR-WKS-03 — engine recompute vs user edits
-- ============================================================================
-- 01 the engine recompute under a user JWT sets FU-AMB Amber with no recovery
--    date and must still succeed (calc-only writes never trip the guard)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.recompute_programme_progress('d1f00000-0000-0000-0000-000000000001');
  PERFORM pg_temp.t(
    (SELECT rag FROM public.activities WHERE id='f1f00000-0000-0000-0000-000000000001') = 'Amber'
    AND (SELECT recovery_date FROM public.activities WHERE id='f1f00000-0000-0000-0000-000000000001') IS NULL
    AND (SELECT rag FROM public.activities WHERE id='f1f00000-0000-0000-0000-000000000002') = 'Green',
    '01 engine recompute (user JWT) sets FU-AMB Amber without a recovery date: succeeds');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '01 engine recompute (user JWT) sets Amber: raised '||SQLERRM);
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

-- 02 service-path recompute (no JWT) also passes, rows already Amber
DO $$
BEGIN
  PERFORM public.recompute_programme_progress('d1f00000-0000-0000-0000-000000000001');
  PERFORM pg_temp.t(true, '02 service-path recompute over an Amber row without recovery date succeeds');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '02 service-path recompute: raised '||SQLERRM);
END $$;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
BEGIN
  -- 03 user edit (comments) to an Amber activity with no recovery date: rejected
  BEGIN
    PERFORM public.update_activity('f1f00000-0000-0000-0000-000000000001',
                                   '{"comments":"chasing supplier"}');
    PERFORM pg_temp.t(false, '03 Amber edit without recovery date rejected (update_activity)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-WKS-03%',
      '03 Amber edit without recovery date rejected (update_activity): '||SQLERRM);
  END;
  -- 04 an edit that would MAKE the item Amber (At risk) without recovery: rejected
  BEGIN
    PERFORM public.update_activity('f1f00000-0000-0000-0000-000000000002',
                                   '{"status":"At risk"}');
    PERFORM pg_temp.t(false, '04 edit turning an activity Amber without recovery date rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%would be Amber%',
      '04 edit turning an activity Amber without recovery date rejected: '||SQLERRM);
  END;
  -- 05 the same edit with a recovery date saves; engine recompute marks Amber
  PERFORM public.update_activity('f1f00000-0000-0000-0000-000000000002',
     jsonb_build_object('status','At risk','recovery_date', (CURRENT_DATE + 7)::text));
  PERFORM pg_temp.t(
    (SELECT status||'/'||rag FROM public.activities WHERE id='f1f00000-0000-0000-0000-000000000002')
      = 'At risk/Amber',
    '05 Amber edit WITH a recovery date saves; recompute sets rag Amber');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 06 the direct-write path is guarded too (workstream lead, PostgREST-style UPDATE)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    UPDATE public.activities SET comments = 'direct'
     WHERE id = 'f1f00000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '06 direct UPDATE of an Amber activity without recovery date rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-WKS-03%',
      '06 direct UPDATE of an Amber activity without recovery date rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- B. update_activity_status (#82)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
BEGIN
  -- 07 workstream lead: status edit on Amber item w/o recovery date is rejected
  BEGIN
    PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000001',
                                          'At risk', 'slipping');
    PERFORM pg_temp.t(false, '07 status RPC enforces FR-WKS-03 (no recovery date)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-WKS-03%',
      '07 status RPC enforces FR-WKS-03 (no recovery date): '||SQLERRM);
  END;
  -- 08 workstream lead changes status (+ comment + recovery date): allowed
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000001',
            'At risk', 'supplier late', NULL, CURRENT_DATE + 10);
  -- 09 recompute ran even though the caller has no write role: Blocked → Red
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000003', 'Blocked', 'waiting on IT');
  PERFORM pg_temp.t(auth.uid() = 'a1f00000-0000-0000-0000-000000000002',
    '09a JWT claims restored after the service-path recompute');
  -- 10 workstream lead cannot use update_activity (other fields)
  BEGIN
    PERFORM public.update_activity('f1f00000-0000-0000-0000-000000000002',
                                   '{"text":"renamed by ws lead"}');
    PERFORM pg_temp.t(false, '10 workstream lead denied update_activity (non-status fields)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%write role%',
      '10 workstream lead denied update_activity (non-status fields): '||SQLERRM);
  END;
  -- 11 ... nor change other fields by a direct table UPDATE
  BEGIN
    UPDATE public.activities SET text = 'renamed directly', end_week = 16
     WHERE id = 'f1f00000-0000-0000-0000-000000000002';
    PERFORM pg_temp.t(false, '11 workstream lead direct UPDATE of non-status fields rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%only status fields%',
      '11 workstream lead direct UPDATE of non-status fields rejected: '||SQLERRM);
  END;
  -- 12 workstream lead of WS1 is denied on a WS2 activity
  BEGIN
    PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000007', 'Complete');
    PERFORM pg_temp.t(false, '12 workstream lead denied on another workstream''s activity');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%status update requires%',
      '12 workstream lead denied on another workstream''s activity');
  END;
  -- 13 FR-SCH-04: start with an incomplete predecessor needs an override
  BEGIN
    PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000005', 'In progress');
    PERFORM pg_temp.t(false, '13 FR-SCH-04: start with open predecessor rejected without override');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-SCH-04%',
      '13 FR-SCH-04: start with open predecessor rejected without override');
  END;
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000005',
            'In progress', NULL, 'PL agreed parallel start');
  -- 15 Deferred needs a rescheduled date
  BEGIN
    PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000006', 'Deferred');
    PERFORM pg_temp.t(false, '15 Deferred without rescheduled_date rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%rescheduled_date%',
      '15 Deferred without rescheduled_date rejected');
  END;
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000006',
            'Deferred', 'parked to next quarter', NULL, NULL, CURRENT_DATE + 60);
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  (SELECT status||'|'||comments||'|'||recovery_date::text
     FROM activities WHERE id='f1f00000-0000-0000-0000-000000000001')
    = 'At risk|supplier late|'||(CURRENT_DATE + 10)::text
  AND (SELECT text FROM activities WHERE id='f1f00000-0000-0000-0000-000000000001') = 'past due (Amber)',
  '08 workstream lead changed status/comment/recovery date; text untouched');
SELECT pg_temp.t(
  (SELECT status||'/'||rag FROM activities WHERE id='f1f00000-0000-0000-0000-000000000003') = 'Blocked/Red',
  '09 status RPC recomputes calc columns for a non-writer caller (Blocked → rag Red)');
SELECT pg_temp.t(
  (SELECT text||'/'||end_week FROM activities WHERE id='f1f00000-0000-0000-0000-000000000002')
    = 'green item/15',
  '11b non-status fields of FU-GRN unchanged after the denied writes');
SELECT pg_temp.t(
  (SELECT status||'|'||dependency_override_reason FROM activities
    WHERE id='f1f00000-0000-0000-0000-000000000005') = 'In progress|PL agreed parallel start',
  '14 FR-SCH-04: start with override reason recorded succeeds');
SELECT pg_temp.t(
  (SELECT status||'|'||rescheduled_date::text FROM activities
    WHERE id='f1f00000-0000-0000-0000-000000000006') = 'Deferred|'||(CURRENT_DATE + 60)::text,
  '16 Deferred with rescheduled_date succeeds');
SELECT pg_temp.t(
  (SELECT count(*) FROM activity_status_history
    WHERE changed_by='a1f00000-0000-0000-0000-000000000002'
      AND activity_id IN ('f1f00000-0000-0000-0000-000000000001','f1f00000-0000-0000-0000-000000000003',
                          'f1f00000-0000-0000-0000-000000000005','f1f00000-0000-0000-0000-000000000006')) = 4
  AND EXISTS (SELECT 1 FROM activity_status_history
               WHERE activity_id='f1f00000-0000-0000-0000-000000000001'
                 AND old_status='In progress' AND new_status='At risk'),
  '17 every status change appended to activity_status_history (changed_by = lead)');
SELECT pg_temp.t(
  (SELECT count(*) FROM audit_log WHERE action='activity.status_updated'
     AND user_id='a1f00000-0000-0000-0000-000000000002') = 4,
  '18 each status RPC call wrote an audit_log row');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
BEGIN
  -- 19 a listed lead (no role at all) may update status on their own activity
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000008',
                                        'Complete', 'done by provider');
  PERFORM pg_temp.t(true, '19 listed activity lead updates status on own activity');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '19 listed activity lead updates status: '||SQLERRM);
END $$;
DO $$
BEGIN
  -- 20 ... but not on an activity they do not lead
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000007', 'Complete');
  PERFORM pg_temp.t(false, '20 listed lead denied on an activity they do not lead');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(SQLERRM LIKE '%status update requires%',
    '20 listed lead denied on an activity they do not lead');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 21 non-lead (client_contributor on the client) is denied
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000002', 'Complete');
  PERFORM pg_temp.t(false, '21 non-lead client_contributor denied');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(SQLERRM LIKE '%status update requires%', '21 non-lead client_contributor denied');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 22 other partner's admin is denied
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000002', 'Complete');
  PERFORM pg_temp.t(false, '22 cross-partner admin denied');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(SQLERRM LIKE '%status update requires%', '22 cross-partner admin denied');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 23 a programme WRITE role may also use the status RPC; completing an Amber
--    item needs no recovery date (completion is the recovery)
UPDATE activities SET recovery_date = NULL, status = 'In progress'
 WHERE id = 'f1f00000-0000-0000-0000-000000000001';           -- service path: unguarded
SELECT public.recompute_programme_progress('d1f00000-0000-0000-0000-000000000001');
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000007","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.update_activity_status('f1f00000-0000-0000-0000-000000000001', 'Complete');
  PERFORM pg_temp.t(
    (SELECT status||'/'||rag FROM public.activities WHERE id='f1f00000-0000-0000-0000-000000000001')
      = 'Complete/Complete',
    '23 programme_lead completes an Amber item via the status RPC (no recovery date needed)');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '23 programme_lead completes an Amber item: '||SQLERRM);
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  NOT has_function_privilege('anon', 'public.update_activity_status(uuid,text,text,text,date,date)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.programme_people(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.update_activity_status(uuid,text,text,text,date,date)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.trg_activity_session_guard()', 'EXECUTE'),
  '24 function surface: anon locked out; authenticated may call the RPCs, not the trigger fn');

-- ============================================================================
-- C. programme_people (#81)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE v jsonb;
BEGIN
  SELECT jsonb_object_agg(user_id::text, jsonb_build_object('n', display_name, 'r', roles))
    INTO v FROM public.programme_people('d1f00000-0000-0000-0000-000000000001');
  PERFORM pg_temp.t(
    v ? 'a1f00000-0000-0000-0000-000000000001'        -- partner scope
    AND v ? 'a1f00000-0000-0000-0000-000000000002'    -- workstream scope
    AND v ? 'a1f00000-0000-0000-0000-000000000004'    -- client scope
    AND v ? 'a1f00000-0000-0000-0000-000000000007'    -- programme scope
    AND v ? 'a1f00000-0000-0000-0000-000000000003',   -- referenced activity lead
    '25 programme_people: partner-, client-, programme-, workstream-scope holders + listed lead');
  PERFORM pg_temp.t(
    v -> 'a1f00000-0000-0000-0000-000000000001' -> 'r' = '["partner_admin"]'
    AND v -> 'a1f00000-0000-0000-0000-000000000002' -> 'r' = '["workstream_lead"]'
    AND v -> 'a1f00000-0000-0000-0000-000000000004' -> 'r' = '["client_contributor"]'
    AND v -> 'a1f00000-0000-0000-0000-000000000003' -> 'r' = '[]',
    '26 programme_people: active roles per person (listed lead without role → {})');
  PERFORM pg_temp.t(
    NOT (v ? 'a1f00000-0000-0000-0000-000000000005')
    AND NOT (v ? 'a1f00000-0000-0000-0000-000000000006'),
    '27 programme_people: other partner''s admin and ended assignment excluded');
  PERFORM pg_temp.t(
    v -> 'a1f00000-0000-0000-0000-000000000001' ->> 'n' = 'Pat Admin'
    AND v -> 'a1f00000-0000-0000-0000-000000000002' ->> 'n' = 'wslead'
    AND v -> 'a1f00000-0000-0000-0000-000000000007' ->> 'n' = 'proglead'
    AND v::text NOT LIKE '%@%',
    '28 programme_people: full_name else email local part — no email leaks');
  BEGIN
    PERFORM * FROM public.programme_people('d1f00000-0000-0000-0000-000000000002');
    PERFORM pg_temp.t(false, '29 programme_people denies another partner''s programme');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, '29 programme_people denies another partner''s programme');
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 30 a client-scope user may call it for their client's programme, and still
--    gets no email (even for users whose rows they cannot read)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.programme_people('d1f00000-0000-0000-0000-000000000001')) = 5
  AND NOT EXISTS (SELECT 1 FROM public.programme_people('d1f00000-0000-0000-0000-000000000001')
                   WHERE display_name LIKE '%@%')
  AND (SELECT count(*) FROM public.users WHERE email LIKE '%@w1fu.test') = 1,
  '30 programme_people for a client contributor: 5 people, no emails (users RLS still self-only)');
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- D. week_due_date (#83)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  public.week_due_date('d1f00000-0000-0000-0000-000000000001', 3)
    = date_trunc('week', CURRENT_DATE)::date - 28 + 18
  AND public.week_due_date('d1f00000-0000-0000-0000-000000000001', 3)
    = public.week_end('d1f00000-0000-0000-0000-000000000001', 3)
  AND extract(isodow FROM public.week_due_date('d1f00000-0000-0000-0000-000000000001', 7)) = 5,
  '31 week_due_date = week_end (Friday of the week, start + (w-1)*7 + 4)');
SELECT pg_temp.t(
  public.week_due_date('d1f00000-0000-0000-0000-000000000002', 3) IS NULL,
  '32 week_due_date returns NULL for a programme the caller cannot see');
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- E. weekly_logs.attendees
-- ============================================================================
SELECT pg_temp.t(
  has_column_privilege('authenticated', 'public.weekly_logs', 'attendees', 'INSERT')
  AND has_column_privilege('authenticated', 'public.weekly_logs', 'attendees', 'UPDATE')
  AND has_column_privilege('authenticated', 'public.weekly_logs', 'blockers', 'UPDATE')
  AND NOT has_column_privilege('authenticated', 'public.weekly_logs', 'week_rag', 'UPDATE'),
  '33 attendees column grant matches the client-writable log fields');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE v_att jsonb := '[{"user_id":"a1f00000-0000-0000-0000-000000000002","name":"WS Lead","role":"workstream_lead"},{"name":"Guest Auditor"}]';
BEGIN
  PERFORM public.upsert_weekly_log('d1f00000-0000-0000-0000-000000000001', 5,
            jsonb_build_object('session_held', true, 'attendees', v_att));
  PERFORM pg_temp.t(
    (public.get_weekly_log('d1f00000-0000-0000-0000-000000000001', 5)).attendees = v_att,
    '34 attendees round-trip through upsert_weekly_log / get_weekly_log');
  PERFORM public.upsert_weekly_log('d1f00000-0000-0000-0000-000000000001', 5,
            '{"blockers":"none"}');
  PERFORM pg_temp.t(
    (public.get_weekly_log('d1f00000-0000-0000-0000-000000000001', 5)).attendees = v_att
    AND (public.get_weekly_log('d1f00000-0000-0000-0000-000000000001', 5)).blockers = 'none',
    '35 payload without attendees keeps the stored list (merge semantics)');
  BEGIN
    PERFORM public.upsert_weekly_log('d1f00000-0000-0000-0000-000000000001', 5,
              '{"attendees":{"name":"not an array"}}');
    PERFORM pg_temp.t(false, '36 attendees must be an array');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%array%', '36 attendees must be an array');
  END;
  BEGIN
    PERFORM public.upsert_weekly_log('d1f00000-0000-0000-0000-000000000001', 5,
              '{"attendees":[{"role":"guest"}]}');
    PERFORM pg_temp.t(false, '37 attendee without a name rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%invalid attendee%', '37 attendee without a name rejected');
  END;
  BEGIN
    PERFORM public.upsert_weekly_log('d1f00000-0000-0000-0000-000000000001', 5,
              '{"attendees":[{"name":"Ghost","user_id":"00000000-0000-0000-0000-0000000000ff"}]}');
    PERFORM pg_temp.t(false, '38 attendee with unknown user_id rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%does not exist%', '38 attendee with unknown user_id rejected');
  END;
  BEGIN
    PERFORM public.upsert_weekly_log('d1f00000-0000-0000-0000-000000000001', 5,
              '{"attendees":[{"name":"X","email":"x@example.com"}]}');
    PERFORM pg_temp.t(false, '39 attendee with an unknown key rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%invalid attendee%', '39 attendee with an unknown key rejected');
  END;
  -- 40 direct-write path: the CHECK constraint guards the shape
  BEGIN
    UPDATE public.weekly_logs SET attendees = '[{"name":""}]'
     WHERE programme_id = 'd1f00000-0000-0000-0000-000000000001' AND week = 5;
    PERFORM pg_temp.t(false, '40 direct UPDATE with a malformed attendee list rejected by CHECK');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.t(true, '40 direct UPDATE with a malformed attendee list rejected by CHECK');
  END;
  UPDATE public.weekly_logs SET attendees = '[{"name":"Direct Writer","role":null}]'
   WHERE programme_id = 'd1f00000-0000-0000-0000-000000000001' AND week = 5;
  PERFORM pg_temp.t(
    (SELECT attendees FROM public.weekly_logs
      WHERE programme_id = 'd1f00000-0000-0000-0000-000000000001' AND week = 5)
      = '[{"name":"Direct Writer","role":null}]',
    '41 direct UPDATE of attendees by a write role is allowed (column grant)');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 42 a non-writer cannot record attendees
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1f00000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.upsert_weekly_log('d1f00000-0000-0000-0000-000000000001', 5,
            '{"attendees":[{"name":"Sneaky"}]}');
  PERFORM pg_temp.t(false, '42 client_contributor cannot write a weekly log');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(SQLERRM LIKE '%write role%', '42 client_contributor cannot write a weekly log');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ---------- teardown ----------
DELETE FROM programmes WHERE client_org_id IN
  (SELECT id FROM client_orgs WHERE name LIKE 'W1FU%');
DELETE FROM client_orgs WHERE name LIKE 'W1FU%';
DELETE FROM practices WHERE name LIKE 'W1FU%';
DELETE FROM audit_log WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w1fu.test');
DELETE FROM role_assignments WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w1fu.test');
DELETE FROM users WHERE email LIKE '%@w1fu.test';
DELETE FROM auth.users WHERE email LIKE '%@w1fu.test';
\echo '=== e2e_followups checks done ==='
