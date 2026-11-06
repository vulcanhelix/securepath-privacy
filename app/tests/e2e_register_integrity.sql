-- ============================================================================
-- #87 register closure integrity + register RPCs — psql acceptance checks for
-- 20261106000013_register_integrity.sql (§9.4, FR-REG-01..04, FR-TPL-04,
-- FR-ACC-02).
--
-- SELF-CONTAINED: seeds its own @w1ri.test / 'W1RI%' namespace (two
-- partners, two clients, three programmes) and never reads or mutates the
-- shared TESTFIX world. Re-runnable: the namespace is wiped first and torn
-- down at the end (the NFR-09 evidence_immutable guard is suspended for the
-- wipe only — the suite accepts real evidence, which is then undeletable).
--
-- Evidence is accepted through the REAL chain (upload_evidence →
-- verify_evidence → accept_evidence), so every ref a closure uses was minted
-- by the platform. Only the deliberately-broken cases are staged admin-side.
--
-- JWT callers are simulated with SET ROLE authenticated + request.jwt.claims
-- inside the same transaction as the writes (e2e_role_assignments.sql
-- pattern). SET ROLE and the claims GUC outlive COMMIT, so every block ends
-- with RESET ROLE + RESET request.jwt.claims (service-path steps run
-- claim-free).
--
-- Actors (a1e70000-…-000N):
--   U1 padmin   partner_admin, partner A      — WRITE role on P1/P2
--   U2 ao       accountable_officer, client A — AO on P1/P2
--   U3 contrib  client_contributor, client A  — no write role
--   U4 pl       programme_lead on P1 and P2   — uploader / verifier
--   U5 bao      accountable_officer, client B — AO elsewhere
--   U6 badmin   partner_admin, partner B      — other tenant
--
-- NOTE for local scratch runs: same auth shim as e2e_template_engine.sql
-- (newer auth.users columns + the coalesced auth.uid() body).
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_register_integrity.sql
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
ALTER TABLE public.evidence_items DISABLE TRIGGER evidence_immutable;
DELETE FROM notification_events WHERE scope->>'programme_id' IN
  (SELECT p.id::text FROM programmes p JOIN client_orgs c ON c.id = p.client_org_id
    WHERE c.name LIKE 'W1RI%');
DELETE FROM programmes WHERE client_org_id IN
  (SELECT id FROM client_orgs WHERE name LIKE 'W1RI%');
ALTER TABLE public.evidence_items ENABLE TRIGGER evidence_immutable;
DELETE FROM audit_log WHERE practice_id IN (SELECT id FROM practices WHERE name LIKE 'W1RI%')
   OR user_id IN (SELECT id FROM users WHERE email LIKE '%@w1ri.test');
DELETE FROM client_orgs WHERE name LIKE 'W1RI%';
DELETE FROM practices WHERE name LIKE 'W1RI%';
DELETE FROM role_assignments WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w1ri.test');
DELETE FROM users WHERE email LIKE '%@w1ri.test';
DELETE FROM auth.users WHERE email LIKE '%@w1ri.test';

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
  ('a1e70000-0000-0000-0000-000000000001'::uuid, 'padmin@w1ri.test'),
  ('a1e70000-0000-0000-0000-000000000002'::uuid, 'ao@w1ri.test'),
  ('a1e70000-0000-0000-0000-000000000003'::uuid, 'contrib@w1ri.test'),
  ('a1e70000-0000-0000-0000-000000000004'::uuid, 'pl@w1ri.test'),
  ('a1e70000-0000-0000-0000-000000000005'::uuid, 'bao@w1ri.test'),
  ('a1e70000-0000-0000-0000-000000000006'::uuid, 'badmin@w1ri.test')
) AS u(id, email);
INSERT INTO users (id, email, full_name)
SELECT id, email, split_part(email, '@', 1) FROM auth.users WHERE email LIKE '%@w1ri.test';

INSERT INTO practices (id, name) VALUES
  ('b1e70000-0000-0000-0000-00000000000a', 'W1RI Partner A'),
  ('b1e70000-0000-0000-0000-00000000000b', 'W1RI Partner B');
INSERT INTO client_orgs (id, practice_id, name) VALUES
  ('c1e70000-0000-0000-0000-00000000000a', 'b1e70000-0000-0000-0000-00000000000a', 'W1RI Client A'),
  ('c1e70000-0000-0000-0000-00000000000b', 'b1e70000-0000-0000-0000-00000000000b', 'W1RI Client B');
INSERT INTO programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d1e70000-0000-0000-0000-000000000001', 'c1e70000-0000-0000-0000-00000000000a', 'W1RI P1', DATE '2026-11-02', 20),
  ('d1e70000-0000-0000-0000-000000000002', 'c1e70000-0000-0000-0000-00000000000a', 'W1RI P2', DATE '2026-11-02', 20),
  ('d1e70000-0000-0000-0000-000000000003', 'c1e70000-0000-0000-0000-00000000000b', 'W1RI P3', DATE '2026-11-02', 20);

INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id, start_date, end_date) VALUES
  ('a1e70000-0000-0000-0000-000000000001','partner','partner_admin','partner','b1e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a1e70000-0000-0000-0000-000000000002','client','accountable_officer','client','c1e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a1e70000-0000-0000-0000-000000000003','client','client_contributor','client','c1e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a1e70000-0000-0000-0000-000000000004','client','programme_lead','programme','d1e70000-0000-0000-0000-000000000001', CURRENT_DATE, NULL),
  ('a1e70000-0000-0000-0000-000000000004','client','programme_lead','programme','d1e70000-0000-0000-0000-000000000002', CURRENT_DATE, NULL),
  ('a1e70000-0000-0000-0000-000000000005','client','accountable_officer','client','c1e70000-0000-0000-0000-00000000000b', CURRENT_DATE, NULL),
  ('a1e70000-0000-0000-0000-000000000006','partner','partner_admin','partner','b1e70000-0000-0000-0000-00000000000b', CURRENT_DATE, NULL);

-- activities: A1/A3/B1 Complete, A2/A4 In progress
INSERT INTO activities (id, programme_id, ref, text, start_week, end_week, status) VALUES
  ('f1e70000-0000-0000-0000-000000000001','d1e70000-0000-0000-0000-000000000001','RI-A1','policy drafted',1,4,'Complete'),
  ('f1e70000-0000-0000-0000-000000000002','d1e70000-0000-0000-0000-000000000001','RI-A2','agreements signed',1,6,'In progress'),
  ('f1e70000-0000-0000-0000-000000000003','d1e70000-0000-0000-0000-000000000001','RI-A3','register built',1,3,'Complete'),
  ('f1e70000-0000-0000-0000-000000000004','d1e70000-0000-0000-0000-000000000001','RI-A4','drill run',2,8,'In progress'),
  ('f1e70000-0000-0000-0000-000000000005','d1e70000-0000-0000-0000-000000000002','RI-B1','P2 work',1,4,'Complete');
-- findings: R1↔A1, R2↔A2, R3 (no links), R4↔A4 in P1; Q1↔B1 in P2
INSERT INTO register_items (id, programme_id, ref, finding, priority, planned_close_week, status) VALUES
  ('91e70000-0000-0000-0000-000000000001','d1e70000-0000-0000-0000-000000000001','RI-R1','no privacy policy','High',5,'In progress'),
  ('91e70000-0000-0000-0000-000000000002','d1e70000-0000-0000-0000-000000000001','RI-R2','operator clauses','Medium',7,'In progress'),
  ('91e70000-0000-0000-0000-000000000003','d1e70000-0000-0000-0000-000000000001','RI-R3','no register','Low',9,'Not started'),
  ('91e70000-0000-0000-0000-000000000004','d1e70000-0000-0000-0000-000000000001','RI-R4','no breach drill','Medium',9,'In progress'),
  ('91e70000-0000-0000-0000-000000000005','d1e70000-0000-0000-0000-000000000002','RI-Q1','P2 finding','High',5,'In progress');
INSERT INTO register_item_activities (register_item_id, activity_id) VALUES
  ('91e70000-0000-0000-0000-000000000001','f1e70000-0000-0000-0000-000000000001'),
  ('91e70000-0000-0000-0000-000000000002','f1e70000-0000-0000-0000-000000000002'),
  ('91e70000-0000-0000-0000-000000000004','f1e70000-0000-0000-0000-000000000004'),
  ('91e70000-0000-0000-0000-000000000005','f1e70000-0000-0000-0000-000000000005');

CREATE TEMP TABLE w1ri (k text PRIMARY KEY, v text);
GRANT SELECT, INSERT, UPDATE, DELETE ON w1ri TO authenticated;

SELECT pg_temp.t(
  (SELECT count(*) FROM register_items WHERE programme_id IN
     ('d1e70000-0000-0000-0000-000000000001','d1e70000-0000-0000-0000-000000000002')) = 5
  AND (SELECT bool_and(active) FROM register_items WHERE ref LIKE 'RI-%')
  AND (SELECT bool_and(active) FROM activities WHERE ref LIKE 'RI-%'),
  '00 seed: W1RI namespace (5 findings, 5 activities, all active by default)');


-- ============================================================================
-- A. accept evidence through the REAL chain (upload → verify → accept)
-- ============================================================================
-- E1 on R2/A2 (A2 In progress → partly_supports, R2 stays open)
-- E2 on R1/A1 (A1 Complete    → closes R1: the accept_evidence auto-close)
-- E3 on Q1/B1 in P2           → closes Q1 (a ref that belongs to P2)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  INSERT INTO w1ri VALUES ('e1', public.upload_evidence('f1e70000-0000-0000-0000-000000000002',
      '91e70000-0000-0000-0000-000000000002','w1ri/r2.pdf',NULL,'W1RI e1',NULL,NULL)::text);
  INSERT INTO w1ri VALUES ('e2', public.upload_evidence('f1e70000-0000-0000-0000-000000000001',
      '91e70000-0000-0000-0000-000000000001','w1ri/r1.pdf',NULL,'W1RI e2',NULL,NULL)::text);
END $$;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.verify_evidence((SELECT v FROM w1ri WHERE k='e1')::uuid, 'approved');
  PERFORM public.verify_evidence((SELECT v FROM w1ri WHERE k='e2')::uuid, 'approved');
  INSERT INTO w1ri VALUES ('e3', public.upload_evidence('f1e70000-0000-0000-0000-000000000005',
      '91e70000-0000-0000-0000-000000000005','w1ri/q1.pdf',NULL,'W1RI e3',NULL,NULL)::text);
END $$;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.verify_evidence((SELECT v FROM w1ri WHERE k='e3')::uuid, 'approved');
END $$;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ DECLARE r jsonb; BEGIN
  r := public.accept_evidence((SELECT v FROM w1ri WHERE k='e1')::uuid);
  INSERT INTO w1ri VALUES ('ref_r2', r->>'evidence_ref'), ('out_e1', r->>'outcome');
  r := public.accept_evidence((SELECT v FROM w1ri WHERE k='e2')::uuid);
  INSERT INTO w1ri VALUES ('ref_r1', r->>'evidence_ref'), ('out_e2', r->>'outcome');
  r := public.accept_evidence((SELECT v FROM w1ri WHERE k='e3')::uuid);
  INSERT INTO w1ri VALUES ('ref_q1', r->>'evidence_ref');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  (SELECT v FROM w1ri WHERE k='out_e1') = 'partly_supports'
  AND (SELECT status FROM register_items WHERE id='91e70000-0000-0000-0000-000000000002') = 'In progress'
  AND (SELECT v FROM w1ri WHERE k='ref_r2') = 'EV-RI-R2-001',
  '01 accept with an incomplete linked activity: partly_supports, R2 stays open, ref EV-RI-R2-001 minted');
SELECT pg_temp.t(
  (SELECT v FROM w1ri WHERE k='out_e2') = 'closes_finding'
  AND (SELECT status = 'Closed' AND accepted_by = 'a1e70000-0000-0000-0000-000000000002'
              AND accepted_evidence_refs = ARRAY[(SELECT v FROM w1ri WHERE k='ref_r1')]
         FROM register_items WHERE id='91e70000-0000-0000-0000-000000000001')
  AND (SELECT status FROM register_items WHERE id='91e70000-0000-0000-0000-000000000005') = 'Closed',
  '02 accept_evidence auto-close still passes the new ref gate (R1 and Q1 Closed with minted refs)');
SELECT pg_temp.t(
  (SELECT can_close AND reason = 'ok' FROM can_close_register_item('91e70000-0000-0000-0000-000000000001')),
  '03 can_close_register_item: auto-closed R1 reads ok (refs are accepted, linked evidence)');


-- ============================================================================
-- B. closure integrity — every bad ref is refused, on every write path
-- ============================================================================
-- In each txn A2 is completed admin-side first, so the ONLY failing leg is
-- the evidence ref.
BEGIN;
UPDATE activities SET status='Complete', pct_complete=100 WHERE id='f1e70000-0000-0000-0000-000000000002';
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  -- 04 fabricated ref via the RPC
  BEGIN
    PERFORM public.close_register_item('91e70000-0000-0000-0000-000000000002', ARRAY['EV-FAKE-999']);
    PERFORM pg_temp.t(false, '04 close_register_item with a fabricated ref rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%EV-FAKE-999 does not match any evidence in this programme%',
      '04 close_register_item with a fabricated ref rejected: '||SQLERRM);
  END;
  -- 05 a real, accepted ref from ANOTHER PROGRAMME (Q1's, P2)
  BEGIN
    PERFORM public.close_register_item('91e70000-0000-0000-0000-000000000002',
              ARRAY[(SELECT v FROM w1ri WHERE k='ref_q1')]);
    PERFORM pg_temp.t(false, '05 close with a ref from another programme rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%does not match any evidence in this programme%',
      '05 close with a ref from another programme rejected: '||SQLERRM);
  END;
  -- 06 a real, accepted ref of ANOTHER ITEM in the same programme (R1's)
  BEGIN
    PERFORM public.close_register_item('91e70000-0000-0000-0000-000000000002',
              ARRAY[(SELECT v FROM w1ri WHERE k='ref_r1')]);
    PERFORM pg_temp.t(false, '06 close with another finding''s ref rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not linked to this finding or its linked activities%',
      '06 close with another finding''s ref rejected: '||SQLERRM);
  END;
  -- 07 one good + one bad ref: every entry must be valid
  BEGIN
    PERFORM public.close_register_item('91e70000-0000-0000-0000-000000000002',
              ARRAY[(SELECT v FROM w1ri WHERE k='ref_r2'), 'EV-FAKE-998']);
    PERFORM pg_temp.t(false, '07 close with one valid and one fabricated ref rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%EV-FAKE-998%',
      '07 close with one valid and one fabricated ref rejected (every entry checked): '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 08 direct UPDATE path: acceptance record staged admin-side with a
-- fabricated ref, then the AO flips status through the column grant
BEGIN;
UPDATE activities SET status='Complete', pct_complete=100 WHERE id='f1e70000-0000-0000-0000-000000000002';
UPDATE register_items SET accepted_on=now(), accepted_by='a1e70000-0000-0000-0000-000000000002',
       accepted_evidence_refs='{EV-FAKE-999}' WHERE id='91e70000-0000-0000-0000-000000000002';
SELECT pg_temp.t(
  (SELECT NOT can_close AND reason LIKE '%EV-FAKE-999%' FROM can_close_register_item('91e70000-0000-0000-0000-000000000002')),
  '08 can_close_register_item names the bad ref as its reason');
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    UPDATE public.register_items SET status='Closed' WHERE id='91e70000-0000-0000-0000-000000000002';
    PERFORM pg_temp.t(false, '09 direct UPDATE status=Closed with a fabricated ref rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%EV-FAKE-999%',
      '09 direct UPDATE status=Closed with a fabricated ref rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 10 a ref that exists in the programme but was never ACCEPTED (decided row
-- with no AO accept review — staged admin-side; the chain cannot produce it)
BEGIN;
UPDATE activities SET status='Complete', pct_complete=100 WHERE id='f1e70000-0000-0000-0000-000000000002';
INSERT INTO evidence_items (programme_id, activity_id, register_item_id, file_key,
                            uploaded_by, review_stage, outcome, evidence_ref)
VALUES ('d1e70000-0000-0000-0000-000000000001','f1e70000-0000-0000-0000-000000000002',
        '91e70000-0000-0000-0000-000000000002','w1ri/unaccepted.pdf',
        'a1e70000-0000-0000-0000-000000000004','decided','closes_finding','EV-RI-R2-777');
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.close_register_item('91e70000-0000-0000-0000-000000000002', ARRAY['EV-RI-R2-777']);
    PERFORM pg_temp.t(false, '10 close with a ref that has no AO acceptance rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%EV-RI-R2-777 is not accepted evidence%',
      '10 close with a ref that has no AO acceptance rejected: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 11 service path (no JWT, BYPASSRLS owner) re-referencing a Closed row is
-- gated too — the rule is a data invariant, not an authz check
DO $$ BEGIN
  BEGIN
    UPDATE public.register_items SET accepted_evidence_refs = '{EV-FAKE-997}'
     WHERE id = '91e70000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '11 service-path swap of a Closed row''s refs to a fabricated ref rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%EV-FAKE-997%',
      '11 service-path swap of a Closed row''s refs to a fabricated ref rejected: '||SQLERRM);
  END;
END $$;

-- 12 INSERT of an already-Closed row: refs checked at commit (deferred
-- constraint trigger) — forced here with SET CONSTRAINTS … IMMEDIATE
DO $$ BEGIN
  BEGIN
    INSERT INTO public.register_items (programme_id, ref, finding, status,
        accepted_on, accepted_by, accepted_evidence_refs)
    VALUES ('d1e70000-0000-0000-0000-000000000001','RI-INS','inserted closed','Closed',
            now(),'a1e70000-0000-0000-0000-000000000002','{EV-FAKE-996}');
    SET CONSTRAINTS public.register_closure_refs_on_insert IMMEDIATE;
    PERFORM pg_temp.t(false, '12 INSERT of a Closed row with a fabricated ref rejected at commit');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%EV-FAKE-996%',
      '12 INSERT of a Closed row with a fabricated ref rejected (deferred check): '||SQLERRM);
  END;
END $$;

-- 13 the valid path: A2 Complete, the AO closes R2 with its OWN accepted ref
-- (persisted — used by the reopen checks below)
UPDATE activities SET status='Complete', pct_complete=100 WHERE id='f1e70000-0000-0000-0000-000000000002';
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.close_register_item('91e70000-0000-0000-0000-000000000002',
            ARRAY[(SELECT v FROM w1ri WHERE k='ref_r2')]);
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT status = 'Closed' AND accepted_evidence_refs = ARRAY['EV-RI-R2-001']
          AND accepted_by = 'a1e70000-0000-0000-0000-000000000002'
     FROM register_items WHERE id='91e70000-0000-0000-0000-000000000002'),
  '13 close_register_item with a valid accepted, linked ref succeeds (record stamped)');


-- ============================================================================
-- C. create_register_item (FR-REG-04)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  INSERT INTO w1ri VALUES ('new1', public.create_register_item(
      'd1e70000-0000-0000-0000-000000000001','RI-N1','raised by internal audit','High',
      'a1e70000-0000-0000-0000-000000000004', 6, '2026 internal audit')::text);
  BEGIN
    PERFORM public.create_register_item('d1e70000-0000-0000-0000-000000000001',
              'RI-N1','duplicate','Low');
    PERFORM pg_temp.t(false, '15 duplicate finding ref in the programme rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%already exists in this programme%',
      '15 duplicate finding ref in the programme rejected: '||SQLERRM);
  END;
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT ref = 'RI-N1' AND priority = 'High' AND status = 'Not started' AND active
          AND lead = 'a1e70000-0000-0000-0000-000000000004'
          AND assessment_window = '2026 internal audit'
          AND planned_close_date = DATE '2026-12-11'        -- Friday of week 6
     FROM register_items WHERE id = (SELECT v FROM w1ri WHERE k='new1')::uuid)
  AND EXISTS (SELECT 1 FROM audit_log WHERE action = 'register_item.created'
                AND detail->>'register_item_id' = (SELECT v FROM w1ri WHERE k='new1')),
  '14 create_register_item happy path: §6.2 fields, engine planned_close_date, audited');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.create_register_item('d1e70000-0000-0000-0000-000000000001','RI-X','x');
    PERFORM pg_temp.t(false, '16 create denied for client_contributor');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%write role%', '16 create denied for client_contributor: '||SQLERRM);
  END;
END $$;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.create_register_item('d1e70000-0000-0000-0000-000000000001','RI-X','x');
    PERFORM pg_temp.t(false, '17 create denied cross-tenant (partner B admin on partner A programme)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%write role%',
      '17 create denied cross-tenant (partner B admin on partner A programme): '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ============================================================================
-- D. update_register_item (allowlist)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  PERFORM public.update_register_item((SELECT v FROM w1ri WHERE k='new1')::uuid,
    '{"finding":"raised by internal audit (rev)","priority":"Low","lead":null,"planned_close_week":8}');
  PERFORM pg_temp.t(
    (SELECT finding = 'raised by internal audit (rev)' AND priority = 'Low' AND lead IS NULL
            AND planned_close_week = 8 AND planned_close_date = DATE '2026-12-25'
       FROM public.register_items WHERE id = (SELECT v FROM w1ri WHERE k='new1')::uuid),
    '18 update_register_item happy path: allowlisted fields, null clears lead, CALC recomputed');
  BEGIN
    PERFORM public.update_register_item((SELECT v FROM w1ri WHERE k='new1')::uuid, '{"status":"Closed"}');
    PERFORM pg_temp.t(false, '19 update_register_item refuses status');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%"status" is not editable%', '19 update_register_item refuses status: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_register_item((SELECT v FROM w1ri WHERE k='new1')::uuid,
              '{"accepted_evidence_refs":["EV-RI-R2-001"]}');
    PERFORM pg_temp.t(false, '20 update_register_item refuses the acceptance record');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not editable%', '20 update_register_item refuses the acceptance record: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_register_item((SELECT v FROM w1ri WHERE k='new1')::uuid, '{"days_overdue":0}');
    PERFORM pg_temp.t(false, '21 update_register_item refuses CALC columns');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not editable%', '21 update_register_item refuses CALC columns: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_register_item('91e70000-0000-0000-0000-000000000001', '{"finding":"edit closed"}');
    PERFORM pg_temp.t(false, '22 update_register_item refuses a Closed finding');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%re-open it before editing%', '22 update_register_item refuses a Closed finding: '||SQLERRM);
  END;
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.update_register_item((SELECT v FROM w1ri WHERE k='new1')::uuid, '{"finding":"x"}');
    PERFORM pg_temp.t(false, '23 update denied for client_contributor');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%write role%', '23 update denied for client_contributor: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ============================================================================
-- E. link / unlink (frozen while Closed)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ DECLARE v_first boolean; v_again boolean; v_un boolean; BEGIN
  v_first := public.link_register_activity((SELECT v FROM w1ri WHERE k='new1')::uuid,
                                           'f1e70000-0000-0000-0000-000000000003');
  v_again := public.link_register_activity((SELECT v FROM w1ri WHERE k='new1')::uuid,
                                           'f1e70000-0000-0000-0000-000000000003');
  PERFORM pg_temp.t(v_first AND NOT v_again
    AND EXISTS (SELECT 1 FROM public.register_item_activities
                 WHERE register_item_id = (SELECT v FROM w1ri WHERE k='new1')::uuid
                   AND activity_id = 'f1e70000-0000-0000-0000-000000000003'),
    '24 link_register_activity happy path (idempotent: second call returns false)');
  BEGIN
    PERFORM public.link_register_activity((SELECT v FROM w1ri WHERE k='new1')::uuid,
                                          'f1e70000-0000-0000-0000-000000000005');
    PERFORM pg_temp.t(false, '25 link to an activity of another programme rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not part of this programme%',
      '25 link to an activity of another programme rejected: '||SQLERRM);
  END;
  -- direct-grant path cannot cross programmes either (trigger)
  BEGIN
    INSERT INTO public.register_item_activities (register_item_id, activity_id)
    VALUES ((SELECT v FROM w1ri WHERE k='new1')::uuid, 'f1e70000-0000-0000-0000-000000000005');
    PERFORM pg_temp.t(false, '26 direct cross-programme link INSERT rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%same programme%', '26 direct cross-programme link INSERT rejected: '||SQLERRM);
  END;
  -- Closed R1: links frozen through the RPCs AND the direct grants
  BEGIN
    PERFORM public.unlink_register_activity('91e70000-0000-0000-0000-000000000001',
                                            'f1e70000-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '27 unlink from a Closed finding rejected (RPC)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%frozen%', '27 unlink from a Closed finding rejected (RPC): '||SQLERRM);
  END;
  BEGIN
    DELETE FROM public.register_item_activities
     WHERE register_item_id = '91e70000-0000-0000-0000-000000000001'
       AND activity_id = 'f1e70000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '28 direct DELETE of a Closed finding''s link rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%frozen%', '28 direct DELETE of a Closed finding''s link rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.link_register_activity('91e70000-0000-0000-0000-000000000001',
                                          'f1e70000-0000-0000-0000-000000000004');
    PERFORM pg_temp.t(false, '29 link onto a Closed finding rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%frozen%', '29 link onto a Closed finding rejected: '||SQLERRM);
  END;
  v_un := public.unlink_register_activity((SELECT v FROM w1ri WHERE k='new1')::uuid,
                                          'f1e70000-0000-0000-0000-000000000003');
  PERFORM pg_temp.t(v_un AND NOT EXISTS (SELECT 1 FROM public.register_item_activities
                 WHERE register_item_id = (SELECT v FROM w1ri WHERE k='new1')::uuid),
    '30 unlink_register_activity happy path');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.link_register_activity((SELECT v FROM w1ri WHERE k='new1')::uuid,
                                          'f1e70000-0000-0000-0000-000000000003');
    PERFORM pg_temp.t(false, '31 link denied for client_contributor');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%write role%', '31 link denied for client_contributor: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.unlink_register_activity('91e70000-0000-0000-0000-000000000004',
                                            'f1e70000-0000-0000-0000-000000000004');
    PERFORM pg_temp.t(false, '32 unlink denied for client_contributor');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%write role%', '32 unlink denied for client_contributor: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ============================================================================
-- F. reopen_register_item (§9.4: AO or alternate + a reason)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.reopen_register_item('91e70000-0000-0000-0000-000000000002', 'auditor disagrees');
    PERFORM pg_temp.t(false, '33 reopen denied for partner_admin (not AO/alternate)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%accountable officer or named alternate%',
      '33 reopen denied for partner_admin (not AO/alternate): '||SQLERRM);
  END;
END $$;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.reopen_register_item('91e70000-0000-0000-0000-000000000002', 'auditor disagrees');
    PERFORM pg_temp.t(false, '34 reopen denied for another client''s AO');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%accountable officer or named alternate%',
      '34 reopen denied for another client''s AO: '||SQLERRM);
  END;
END $$;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.reopen_register_item('91e70000-0000-0000-0000-000000000002', '   ');
    PERFORM pg_temp.t(false, '35 reopen by the AO without a reason rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%requires a reason%',
      '35 reopen by the AO without a reason rejected: '||SQLERRM);
  END;
  PERFORM public.reopen_register_item('91e70000-0000-0000-0000-000000000002',
                                      'sampled operator agreement lacks clause 4');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT status = 'In progress' AND accepted_on IS NULL AND accepted_by IS NULL
          AND accepted_evidence_refs IS NULL
          AND reopen_reason = 'sampled operator agreement lacks clause 4'
     FROM register_items WHERE id='91e70000-0000-0000-0000-000000000002')
  AND EXISTS (SELECT 1 FROM audit_log
               WHERE action = 'register_item.reopened'
                 AND user_id = 'a1e70000-0000-0000-0000-000000000002'
                 AND detail->>'register_item_id' = '91e70000-0000-0000-0000-000000000002'
                 AND detail->>'reason' = 'sampled operator agreement lacks clause 4'
                 AND detail#>>'{previous_acceptance,accepted_evidence_refs,0}' = 'EV-RI-R2-001'),
  '36 AO reopen with a reason: In progress, acceptance record cleared, reason + previous record in audit_log');

-- 37 after a reopen, a bare status flip cannot re-close on the stale record
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    UPDATE public.register_items SET status='Closed' WHERE id='91e70000-0000-0000-0000-000000000002';
    PERFORM pg_temp.t(false, '37 direct re-close after reopen (no new acceptance) rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%acceptance record incomplete%',
      '37 direct re-close after reopen (no new acceptance) rejected: '||SQLERRM);
  END;
  -- 38 …but the AO can re-close with the still-valid accepted ref
  PERFORM public.close_register_item('91e70000-0000-0000-0000-000000000002', ARRAY['EV-RI-R2-001']);
  PERFORM pg_temp.t(
    (SELECT status = 'Closed' AND reopen_reason IS NULL FROM public.register_items
      WHERE id='91e70000-0000-0000-0000-000000000002'),
    '38 re-close with a valid ref after reopen succeeds; reopen_reason cleared for the next reopen');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ============================================================================
-- G. retire (FR-TPL-04) — rows drop out of rollups and the §9.4 activity leg
-- ============================================================================
SELECT set_config('e2e.snap_before',
  (monthly_snapshot_figures('d1e70000-0000-0000-0000-000000000001', DATE '2026-12-01',
                            '2026-12-15'::timestamptz))::text, false);

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ DECLARE v_tot_before bigint; v_tot_after bigint; BEGIN
  SELECT activities_total INTO v_tot_before FROM public.list_programmes()
   WHERE programme_id = 'd1e70000-0000-0000-0000-000000000001';
  -- R4 is blocked only by A4 (In progress); retiring A4 takes it out of the leg
  PERFORM pg_temp.t(
    (SELECT NOT can_close AND reason LIKE '%RI-A4%'
       FROM public.can_close_register_item('91e70000-0000-0000-0000-000000000004')),
    '39 before retire: R4 blocked by its In-progress activity RI-A4');
  PERFORM public.retire_activity('f1e70000-0000-0000-0000-000000000004', 'drill moved to cyber track');
  PERFORM public.retire_activity('f1e70000-0000-0000-0000-000000000003', 'superseded');
  PERFORM pg_temp.t(
    (SELECT NOT active AND retired_by = 'a1e70000-0000-0000-0000-000000000001'
            AND retired_reason = 'drill moved to cyber track'
       FROM public.activities WHERE id = 'f1e70000-0000-0000-0000-000000000004')
    AND (SELECT reason LIKE 'evidence acceptance record incomplete%'
           FROM public.can_close_register_item('91e70000-0000-0000-0000-000000000004')),
    '40 retire_activity happy path: retired, and the §9.4 activity leg ignores it');
  SELECT activities_total INTO v_tot_after FROM public.list_programmes()
   WHERE programme_id = 'd1e70000-0000-0000-0000-000000000001';
  PERFORM pg_temp.t(v_tot_before - v_tot_after = 2,
    '41 list_programmes activities_total drops by the two retired activities');
  -- findings: retire the new open one; a Closed one is refused
  PERFORM public.retire_register_item((SELECT v FROM w1ri WHERE k='new1')::uuid, 'duplicate of RI-R3');
  BEGIN
    PERFORM public.retire_register_item('91e70000-0000-0000-0000-000000000001', 'x');
    PERFORM pg_temp.t(false, '43 retiring a Closed finding rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%Closed%', '43 retiring a Closed finding rejected: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.update_register_item((SELECT v FROM w1ri WHERE k='new1')::uuid, '{"finding":"x"}');
    PERFORM pg_temp.t(false, '44 a retired finding cannot be edited');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%retired%', '44 a retired finding cannot be edited: '||SQLERRM);
  END;
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT NOT active AND retired_reason = 'duplicate of RI-R3'
     FROM register_items WHERE id = (SELECT v FROM w1ri WHERE k='new1')::uuid)
  AND EXISTS (SELECT 1 FROM audit_log WHERE action = 'register_item.retired'
                AND detail->>'register_item_id' = (SELECT v FROM w1ri WHERE k='new1'))
  AND EXISTS (SELECT 1 FROM audit_log WHERE action = 'activity.retired'
                AND detail->>'activity_id' = 'f1e70000-0000-0000-0000-000000000004'),
  '42 retire_register_item happy path (soft retire, audited)');
SELECT pg_temp.t(
  (current_setting('e2e.snap_before')::jsonb->>'activities_complete')::int
    - (monthly_snapshot_figures('d1e70000-0000-0000-0000-000000000001', DATE '2026-12-01',
                                '2026-12-15'::timestamptz)->>'activities_complete')::int = 1
  AND (current_setting('e2e.snap_before')::jsonb->>'register_open')::int
    - (monthly_snapshot_figures('d1e70000-0000-0000-0000-000000000001', DATE '2026-12-01',
                                '2026-12-15'::timestamptz)->>'register_open')::int = 1,
  '45 monthly snapshot figures drop the retired Complete activity and the retired open finding');

-- 46 a retired finding cannot be closed (direct, admin-staged record + AO flip)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    UPDATE public.register_items SET status='Closed'
     WHERE id = (SELECT v FROM w1ri WHERE k='new1')::uuid;
    PERFORM pg_temp.t(false, '46 a retired finding cannot be closed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%retired%', '46 a retired finding cannot be closed: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.retire_register_item('91e70000-0000-0000-0000-000000000003');
    PERFORM pg_temp.t(false, '47 retire_register_item denied for client_contributor');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%write role%', '47 retire_register_item denied for client_contributor: '||SQLERRM);
  END;
  BEGIN
    PERFORM public.retire_activity('f1e70000-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '48 retire_activity denied for client_contributor');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%write role%', '48 retire_activity denied for client_contributor: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- 49 retired columns are not client-writable through the direct grants
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a1e70000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    UPDATE public.register_items SET active = true
     WHERE id = (SELECT v FROM w1ri WHERE k='new1')::uuid;
    PERFORM pg_temp.t(false, '49 direct UPDATE of register_items.active denied (no column grant)');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, '49 direct UPDATE of register_items.active denied (no column grant)');
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;


-- ---------- teardown ----------
ALTER TABLE public.evidence_items DISABLE TRIGGER evidence_immutable;
DELETE FROM notification_events WHERE scope->>'programme_id' IN
  (SELECT p.id::text FROM programmes p JOIN client_orgs c ON c.id = p.client_org_id
    WHERE c.name LIKE 'W1RI%');
DELETE FROM programmes WHERE client_org_id IN
  (SELECT id FROM client_orgs WHERE name LIKE 'W1RI%');
ALTER TABLE public.evidence_items ENABLE TRIGGER evidence_immutable;
DELETE FROM audit_log WHERE practice_id IN (SELECT id FROM practices WHERE name LIKE 'W1RI%')
   OR user_id IN (SELECT id FROM users WHERE email LIKE '%@w1ri.test');
DELETE FROM client_orgs WHERE name LIKE 'W1RI%';
DELETE FROM practices WHERE name LIKE 'W1RI%';
DELETE FROM role_assignments WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w1ri.test');
DELETE FROM users WHERE email LIKE '%@w1ri.test';
DELETE FROM auth.users WHERE email LIKE '%@w1ri.test';
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM programmes p JOIN client_orgs c ON c.id = p.client_org_id
                              WHERE c.name LIKE 'W1RI%'),
  '50 teardown: W1RI namespace removed');
