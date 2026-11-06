-- ============================================================================
-- W0-04 tracks ⇄ programmes bridge — psql acceptance checks
-- (migration 20261106000011_tracks_programmes_bridge.sql · GitHub #13)
--
-- SELF-CONTAINED: seeds its own partners, users, clients, tracks, programmes
-- and assessment sessions in the @w004.test / 'W004%' namespace (uuids all
-- carry '0040000'). It neither reads nor mutates the shared W0-05 TESTFIX
-- world — the fixture pack may or may not be applied; this suite does not
-- care. Wipes its own namespace at the start AND the end.
--
-- JWT callers simulated via SET ROLE authenticated + request.jwt.claims in
-- the SAME transaction as the calls (e2e_role_assignments.sql pattern). SET
-- ROLE persists past COMMIT — every block ends with RESET ROLE.
--
-- Covers: stage mapping 0-5→implementation / 6→maintenance; link RPC guards
-- (read_only, cross-partner, client-side role, cross-client); idempotent
-- link + 1:1 uniqueness; track_id write-protection; Stage 6 hook moves the
-- linked programme to maintenance (audit 'programme.transitioned' via
-- track_stage); backward moves + unlinked tracks are no-ops; link-time
-- mapping; findings import (gaps only, provenance, priority map, §13
-- import_runs/import_rows trail, idempotent re-import, cross-client denied);
-- bridge_status listing; old pipeline unaffected (advance_track_stage on an
-- unlinked track, stage_transitions + approvals append-only, service-path
-- function not executable by authenticated).
--
-- NOTE for scratch runs: same auth shim as e2e_template_engine.sql (newer
-- auth.users columns + coalesced auth.uid()) on a bare supabase/postgres.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_tracks_bridge.sql
-- ============================================================================
\set QUIET on
\pset pager off
\pset tuples_only on

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- ---------- wipe own namespace (re-runnable) ----------
CREATE OR REPLACE FUNCTION pg_temp.w004_wipe() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.client_orgs WHERE name LIKE 'W004%';   -- programmes, tracks, sessions, items
  DELETE FROM public.practices   WHERE name LIKE 'W004%';   -- import_runs/rows
  DELETE FROM public.users       WHERE email LIKE '%@w004.test';
  DELETE FROM auth.users         WHERE email LIKE '%@w004.test';
END $$;
SELECT pg_temp.w004_wipe();

-- ---------- fixtures (superuser, committed) ----------
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
  ('a0040000-0000-0000-0000-000000000001'::uuid, 'admin-a@w004.test'),
  ('a0040000-0000-0000-0000-000000000002'::uuid, 'admin-b@w004.test'),
  ('a0040000-0000-0000-0000-000000000003'::uuid, 'ro-a@w004.test'),
  ('a0040000-0000-0000-0000-000000000004'::uuid, 'clientadmin-a1@w004.test')
) AS u(id, email);
INSERT INTO public.users (id, email) SELECT id, email FROM auth.users WHERE email LIKE '%@w004.test';

INSERT INTO public.practices (id, name) VALUES
  ('b0040000-0000-0000-0000-00000000000a', 'W004 Partner A'),
  ('b0040000-0000-0000-0000-00000000000b', 'W004 Partner B');
INSERT INTO public.client_orgs (id, practice_id, name) VALUES
  ('c0040000-0000-0000-0000-000000000001', 'b0040000-0000-0000-0000-00000000000a', 'W004 A1'),
  ('c0040000-0000-0000-0000-000000000002', 'b0040000-0000-0000-0000-00000000000a', 'W004 A2'),
  ('c0040000-0000-0000-0000-000000000003', 'b0040000-0000-0000-0000-00000000000b', 'W004 B1');

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a0040000-0000-0000-0000-000000000001','partner','partner_admin','partner','b0040000-0000-0000-0000-00000000000a'),
  ('a0040000-0000-0000-0000-000000000002','partner','partner_admin','partner','b0040000-0000-0000-0000-00000000000b'),
  ('a0040000-0000-0000-0000-000000000003','partner','read_only',    'partner','b0040000-0000-0000-0000-00000000000a'),
  ('a0040000-0000-0000-0000-000000000004','client', 'client_admin', 'client', 'c0040000-0000-0000-0000-000000000001');

-- tracks (Stage 0) — what create_client_org would have made
INSERT INTO public.tracks (id, client_org_id, track_kind) VALUES
  ('e0040000-0000-0000-0000-000000000001','c0040000-0000-0000-0000-000000000001','privacy'),
  ('e0040000-0000-0000-0000-000000000002','c0040000-0000-0000-0000-000000000001','cyber'),
  ('e0040000-0000-0000-0000-000000000003','c0040000-0000-0000-0000-000000000002','privacy'),
  ('e0040000-0000-0000-0000-000000000004','c0040000-0000-0000-0000-000000000002','cyber'),
  ('e0040000-0000-0000-0000-000000000005','c0040000-0000-0000-0000-000000000003','privacy');

-- programmes (no template needed for the bridge); P3 seeded in maintenance
INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks, status) VALUES
  ('d0040000-0000-0000-0000-000000000001','c0040000-0000-0000-0000-000000000001','W004 P1 A1 privacy',DATE '2026-11-02',26,'implementation'),
  ('d0040000-0000-0000-0000-000000000002','c0040000-0000-0000-0000-000000000001','W004 P2 A1 cyber',  DATE '2026-11-02',26,'implementation'),
  ('d0040000-0000-0000-0000-000000000003','c0040000-0000-0000-0000-000000000002','W004 P3 A2 maint',  DATE '2026-11-02',26,'maintenance'),
  ('d0040000-0000-0000-0000-000000000004','c0040000-0000-0000-0000-000000000003','W004 P4 B1',        DATE '2026-11-02',26,'implementation'),
  ('d0040000-0000-0000-0000-000000000005','c0040000-0000-0000-0000-000000000002','W004 P5 A2 impl',   DATE '2026-11-02',26,'implementation');

-- Stage 1 assessment sessions: S1 on A1 (the import source), S2 on A2
INSERT INTO public.assessment_sessions (id, client_org_id, framework, title, audit_date, track_id) VALUES
  ('f0040000-0000-0000-0000-000000000001','c0040000-0000-0000-0000-000000000001','popia','W004 S1 baseline',DATE '2026-11-03','e0040000-0000-0000-0000-000000000001'),
  ('f0040000-0000-0000-0000-000000000002','c0040000-0000-0000-0000-000000000002','popia','W004 S2 baseline',DATE '2026-11-03','e0040000-0000-0000-0000-000000000003');

-- S1 responses: 1 Critical non_compliant, 1 Medium partial, 1 Low non_compliant
-- (= 3 gaps), plus 1 fully_compliant and 1 na (not gaps). S2: 1 gap.
DO $$
DECLARE q uuid[];
BEGIN
  SELECT array_agg(id ORDER BY ord) INTO q FROM (
    (SELECT id, 1 AS ord FROM assessment_questions WHERE framework='popia' AND risk='Critical' AND active ORDER BY uid LIMIT 1)
    UNION ALL
    (SELECT id, 2 FROM assessment_questions WHERE framework='popia' AND risk='Medium' AND active ORDER BY uid LIMIT 1)
    UNION ALL
    (SELECT id, 3 FROM assessment_questions WHERE framework='popia' AND risk='Low' AND active ORDER BY uid LIMIT 1)
    UNION ALL
    (SELECT id, 4 FROM assessment_questions WHERE framework='popia' AND risk='High' AND active ORDER BY uid LIMIT 1)
    UNION ALL
    (SELECT id, 5 FROM assessment_questions WHERE framework='popia' AND risk='High' AND active ORDER BY uid OFFSET 1 LIMIT 1)
  ) s;
  IF array_length(q,1) IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION 'popia question bank missing — need Critical/Medium/Low/2×High active questions';
  END IF;
  INSERT INTO assessment_responses (session_id, question_id, response, findings) VALUES
    ('f0040000-0000-0000-0000-000000000001', q[1], 'non_compliant', 'No IO registered'),
    ('f0040000-0000-0000-0000-000000000001', q[2], 'partial',       NULL),
    ('f0040000-0000-0000-0000-000000000001', q[3], 'non_compliant', '  '),
    ('f0040000-0000-0000-0000-000000000001', q[4], 'fully_compliant', NULL),
    ('f0040000-0000-0000-0000-000000000001', q[5], 'na',            NULL),
    ('f0040000-0000-0000-0000-000000000002', q[1], 'non_compliant', NULL);
END $$;

-- ============================================================================
-- schema + mapping
-- ============================================================================
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM information_schema.columns
           WHERE table_schema='public' AND table_name='programmes'
             AND column_name='track_id' AND is_nullable='YES')
  AND EXISTS (SELECT 1 FROM pg_constraint c
               WHERE c.conrelid='public.programmes'::regclass AND c.contype='u'
                 AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                        WHERE attrelid='public.programmes'::regclass
                                          AND attname='track_id')]::int2[]),
  '01 programmes.track_id is nullable + UNIQUE (1:1 link column)');

SELECT pg_temp.t(
  (SELECT bool_and(public.track_stage_programme_status(s) = 'implementation')
     FROM generate_series(0,5) s)
  AND public.track_stage_programme_status(6) = 'maintenance',
  '02 stage mapping: 0-5 → implementation, 6 → maintenance');

DO $$
DECLARE ok boolean := true;
BEGIN
  BEGIN PERFORM public.track_stage_programme_status(7); ok := false;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM public.track_stage_programme_status(-1); ok := false;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM pg_temp.t(ok, '03 stage mapping rejects out-of-range stages');
END $$;

-- ============================================================================
-- link_track_to_programme — denials
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.link_track_to_programme('e0040000-0000-0000-0000-000000000001','d0040000-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '04 read_only cannot link');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.t(true, '04 read_only cannot link: '||SQLERRM); END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.link_track_to_programme('e0040000-0000-0000-0000-000000000001','d0040000-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '05 cross-partner admin cannot link');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.t(true, '05 cross-partner admin cannot link: '||SQLERRM); END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.link_track_to_programme('e0040000-0000-0000-0000-000000000001','d0040000-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '06 client-side client_admin cannot link (partner write roles only)');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.t(true, '06 client-side client_admin cannot link: '||SQLERRM); END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    -- admin A has scope on BOTH A1 and A2 — the same-client guard must still deny
    PERFORM public.link_track_to_programme('e0040000-0000-0000-0000-000000000003','d0040000-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '07 cross-client link denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE 'cross-client link denied%', '07 cross-client link denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- same-client guard holds on the service/superuser path too (trigger)
DO $$ BEGIN
  BEGIN
    UPDATE public.programmes SET track_id = 'e0040000-0000-0000-0000-000000000003'
     WHERE id = 'd0040000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '08 cross-client link denied on the direct/service path (trigger)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '08 cross-client link denied on the direct/service path: '||SQLERRM);
  END;
END $$;

-- ============================================================================
-- link_track_to_programme — success, idempotency, uniqueness, write-protection
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb; r2 jsonb; e1 text; e2 text;
BEGIN
  r  := public.link_track_to_programme('e0040000-0000-0000-0000-000000000001','d0040000-0000-0000-0000-000000000001');
  r2 := public.link_track_to_programme('e0040000-0000-0000-0000-000000000001','d0040000-0000-0000-0000-000000000001');
  PERFORM pg_temp.t(
    (r->>'changed')::boolean AND NOT (r2->>'changed')::boolean
    AND r->>'programme_status' = 'implementation'
    AND (SELECT track_id FROM programmes WHERE id='d0040000-0000-0000-0000-000000000001')
          = 'e0040000-0000-0000-0000-000000000001',
    '09 partner_admin links same-client track (stage 0 → programme stays implementation); re-link is a no-op');
  BEGIN
    PERFORM public.link_track_to_programme('e0040000-0000-0000-0000-000000000001','d0040000-0000-0000-0000-000000000002');
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;
  BEGIN
    PERFORM public.link_track_to_programme('e0040000-0000-0000-0000-000000000002','d0040000-0000-0000-0000-000000000001');
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;
  PERFORM pg_temp.t(e1 LIKE 'track is already linked%' AND e2 LIKE 'programme is already linked%',
    '10 1:1 enforced: second programme on a track and second track on a programme both rejected');
END $$;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM audit_log WHERE action='programme.track_linked'
                    AND detail->>'programme_id'='d0040000-0000-0000-0000-000000000001'),
  '11 link is audit-logged (programme.track_linked)');
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    UPDATE public.programmes SET track_id = NULL WHERE id = 'd0040000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '12 track_id is write-protected for authenticated (no column grant)');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, '12 track_id is write-protected for authenticated: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- Stage hook via the OLD pipeline RPC advance_track_stage (unchanged)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE s int;
BEGIN
  FOR s IN 1..5 LOOP
    PERFORM public.advance_track_stage('e0040000-0000-0000-0000-000000000001', s, 'W004 stage '||s);
  END LOOP;
  PERFORM pg_temp.t(
    (SELECT status FROM programmes WHERE id='d0040000-0000-0000-0000-000000000001') = 'implementation'
    AND (SELECT current_stage FROM tracks WHERE id='e0040000-0000-0000-0000-000000000001') = 5,
    '13 stages 1-5 keep the linked programme in implementation');
  PERFORM public.advance_track_stage('e0040000-0000-0000-0000-000000000001', 6, 'W004 Stage 6');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  (SELECT status FROM programmes WHERE id='d0040000-0000-0000-0000-000000000001') = 'maintenance'
  AND EXISTS (SELECT 1 FROM audit_log
               WHERE action='programme.transitioned'
                 AND detail->>'programme_id'='d0040000-0000-0000-0000-000000000001'
                 AND detail->>'from'='implementation' AND detail->>'to'='maintenance'
                 AND detail->>'via'='track_stage'
                 AND user_id='a0040000-0000-0000-0000-000000000001')
  AND (SELECT count(*) FROM stage_transitions
        WHERE track_id='e0040000-0000-0000-0000-000000000001') = 6,
  '14 STAGE 6 moves the linked programme to maintenance (W1-05 semantics, audited, stage_transitions logged)');

-- backward move: programme never goes back, pipeline never blocked
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE ok boolean := true;
BEGIN
  BEGIN
    PERFORM public.advance_track_stage('e0040000-0000-0000-0000-000000000001', 5, 'W004 back to 5');
    PERFORM public.advance_track_stage('e0040000-0000-0000-0000-000000000001', 6, 'W004 6 again');
  EXCEPTION WHEN OTHERS THEN ok := false; RAISE WARNING '%', SQLERRM; END;
  PERFORM pg_temp.t(ok
    AND (SELECT status FROM programmes WHERE id='d0040000-0000-0000-0000-000000000001') = 'maintenance'
    AND EXISTS (SELECT 1 FROM audit_log WHERE action='programme.track_sync_skipped'
                 AND detail->>'programme_id'='d0040000-0000-0000-0000-000000000001'),
    '15 6→5→6 does not error and leaves the programme in maintenance (divergence logged)');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- old pipeline unaffected: an UNLINKED track to 6 behaves exactly as before
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE n_before bigint; n_after bigint;
BEGIN
  SELECT count(*) INTO n_before FROM audit_log WHERE action LIKE 'programme.%'
    AND detail->>'track_id'='e0040000-0000-0000-0000-000000000003';
  PERFORM public.advance_track_stage('e0040000-0000-0000-0000-000000000003', 6, 'W004 unlinked to 6');
  SELECT count(*) INTO n_after FROM audit_log WHERE action LIKE 'programme.%'
    AND detail->>'track_id'='e0040000-0000-0000-0000-000000000003';
  PERFORM pg_temp.t(
    (SELECT current_stage FROM tracks WHERE id='e0040000-0000-0000-0000-000000000003') = 6
    AND EXISTS (SELECT 1 FROM stage_transitions WHERE track_id='e0040000-0000-0000-0000-000000000003'
                  AND from_stage=0 AND to_stage=6)
    AND EXISTS (SELECT 1 FROM audit_log WHERE action='track.stage_advanced'
                  AND detail->>'track_id'='e0040000-0000-0000-0000-000000000003')
    AND n_after = n_before
    AND (SELECT status FROM programmes WHERE id='d0040000-0000-0000-0000-000000000005') = 'implementation',
    '16 OLD PIPELINE unaffected: unlinked track advances to 6 as before; no programme touched');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

-- legacy client-side caller (client_admin holds no W1-05 transition role) can
-- still drive a LINKED track to 6 — the hook runs on the service path
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.link_track_to_programme('e0040000-0000-0000-0000-000000000002','d0040000-0000-0000-0000-000000000002') IS NOT NULL;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE ok boolean := true;
BEGIN
  BEGIN
    PERFORM public.advance_track_stage('e0040000-0000-0000-0000-000000000002', 6, 'W004 client_admin to 6');
  EXCEPTION WHEN OTHERS THEN ok := false; RAISE WARNING '%', SQLERRM; END;
  PERFORM pg_temp.t(ok
    AND (SELECT status FROM programmes WHERE id='d0040000-0000-0000-0000-000000000002') = 'maintenance',
    '16b legacy client_admin advancing a linked track to 6 succeeds and moves the programme (service path)');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- link-time mapping
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb; e text;
BEGIN
  -- A2 privacy track is at stage 6 (check 16) → linking P5 (implementation) moves it
  r := public.link_track_to_programme('e0040000-0000-0000-0000-000000000003','d0040000-0000-0000-0000-000000000005');
  PERFORM pg_temp.t(r->>'programme_status' = 'maintenance'
    AND (SELECT status FROM programmes WHERE id='d0040000-0000-0000-0000-000000000005') = 'maintenance'
    AND EXISTS (SELECT 1 FROM audit_log WHERE action='programme.transitioned'
                 AND detail->>'programme_id'='d0040000-0000-0000-0000-000000000005'
                 AND detail->>'via'='track_link'),
    '17 linking a stage-6 track moves an implementation programme to maintenance');
  -- A2 cyber track is at stage 0 → cannot link to P3 (already maintenance)
  BEGIN
    PERFORM public.link_track_to_programme('e0040000-0000-0000-0000-000000000004','d0040000-0000-0000-0000-000000000003');
  EXCEPTION WHEN OTHERS THEN e := SQLERRM; END;
  PERFORM pg_temp.t(e LIKE '%cannot move back%'
    AND (SELECT track_id FROM programmes WHERE id='d0040000-0000-0000-0000-000000000003') IS NULL,
    '18 stage 0-5 track cannot link to a programme already in maintenance');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- findings import
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_assessment_findings('d0040000-0000-0000-0000-000000000001','f0040000-0000-0000-0000-000000000002');
    PERFORM pg_temp.t(false, '19 cross-client findings import denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE 'cross-client import denied%', '19 cross-client findings import denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_assessment_findings('d0040000-0000-0000-0000-000000000001','f0040000-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '20 cross-partner findings import denied');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.t(true, '20 cross-partner findings import denied: '||SQLERRM); END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_assessment_findings('d0040000-0000-0000-0000-000000000001','f0040000-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '21 read_only findings import denied');
  EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.t(true, '21 read_only findings import denied: '||SQLERRM); END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb;
BEGIN
  r := public.import_assessment_findings('d0040000-0000-0000-0000-000000000001','f0040000-0000-0000-0000-000000000001');
  PERFORM set_config('e2e.run1', r->>'import_run_id', false);
  PERFORM pg_temp.t((r->>'created')::int = 3 AND (r->>'already_imported')::int = 0
    AND (SELECT count(*) FROM register_items WHERE programme_id='d0040000-0000-0000-0000-000000000001') = 3,
    '22 import turns exactly the 3 gaps (non_compliant/partial) into register items; compliant + na skipped');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  (SELECT bool_and(ri.source_assessment_session_id = 'f0040000-0000-0000-0000-000000000001'
                   AND ri.source_question_ref = q.uid
                   AND ri.ref = 'ASM-' || q.uid
                   AND ri.status = 'Not started'
                   AND ri.assessment_window LIKE 'W004 S1 baseline%')
     FROM register_items ri
     JOIN assessment_questions q ON q.uid = ri.source_question_ref
    WHERE ri.programme_id = 'd0040000-0000-0000-0000-000000000001')
  AND (SELECT array_agg(ri.priority ORDER BY q.risk) FROM register_items ri
         JOIN assessment_questions q ON q.uid = ri.source_question_ref
        WHERE ri.programme_id = 'd0040000-0000-0000-0000-000000000001')
      = ARRAY['High','Low','Medium']    -- Critical, Low, Medium (alphabetical risk)
  AND EXISTS (SELECT 1 FROM register_items WHERE programme_id='d0040000-0000-0000-0000-000000000001'
               AND finding LIKE '%No IO registered'),
  '23 provenance recorded (session + question uid, ASM- ref) and risk→priority mapped');

SELECT pg_temp.t(
  (SELECT kind='findings' AND status='committed'
          AND partner_id='b0040000-0000-0000-0000-00000000000a'
          AND file_ref='assessment_sessions:f0040000-0000-0000-0000-000000000001'
          AND (preview->>'created')::int=3 AND created_by='a0040000-0000-0000-0000-000000000001'
     FROM import_runs WHERE id = current_setting('e2e.run1')::uuid)
  AND (SELECT count(*) FROM import_rows ir
         JOIN register_items ri ON 'register_items:'||ri.id = ir.mapped_entity
        WHERE ir.import_run_id = current_setting('e2e.run1')::uuid
          AND ir.status='ok' AND ir.raw->>'outcome'='created'
          AND ir.raw->>'question_ref' = ri.source_question_ref) = 3,
  '24 §13 trail: import_runs (findings, committed) + 3 import_rows mapped to their register items');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb;
BEGIN
  r := public.import_assessment_findings('d0040000-0000-0000-0000-000000000001','f0040000-0000-0000-0000-000000000001');
  PERFORM pg_temp.t((r->>'created')::int = 0 AND (r->>'already_imported')::int = 3
    AND (SELECT count(*) FROM register_items WHERE programme_id='d0040000-0000-0000-0000-000000000001') = 3
    AND (r->>'import_run_id')::uuid <> current_setting('e2e.run1')::uuid
    AND (SELECT count(*) FROM import_rows ir
           WHERE ir.import_run_id = (r->>'import_run_id')::uuid
             AND ir.raw->>'outcome' = 'already_imported'
             AND ir.mapped_entity IN (SELECT 'register_items:'||id FROM register_items
                                       WHERE programme_id='d0040000-0000-0000-0000-000000000001')) = 3,
    '25 re-import is IDEMPOTENT: no new items; a second run reconciles 3 rows to the same items');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    UPDATE public.register_items SET source_question_ref = 'spoofed'
     WHERE programme_id = 'd0040000-0000-0000-0000-000000000001';
    PERFORM pg_temp.t(false, '26 provenance columns write-protected for authenticated');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, '26 provenance columns write-protected for authenticated: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- bridge_status + surface
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT array_agg(track_id::text ORDER BY track_id) FROM public.bridge_status())
    = ARRAY['e0040000-0000-0000-0000-000000000002','e0040000-0000-0000-0000-000000000003',
            'e0040000-0000-0000-0000-000000000004']
  AND (SELECT candidate_programme_ids FROM public.bridge_status('c0040000-0000-0000-0000-000000000001'))
    = ARRAY['d0040000-0000-0000-0000-000000000002']::uuid[]
  AND (SELECT mapped_programme_status FROM public.bridge_status()
        WHERE track_id='e0040000-0000-0000-0000-000000000003') = 'maintenance',
  '27 bridge_status lists only UNLINKED tracks in caller scope (B1 hidden) with candidate programmes');
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  (SELECT count(*) FROM public.bridge_status() WHERE client_name LIKE 'W004%') = 4
  AND (SELECT provolatile FROM pg_proc WHERE oid='public.bridge_status(uuid)'::regprocedure) = 's'
  AND NOT EXISTS (SELECT 1 FROM programmes p JOIN client_orgs c ON c.id=p.client_org_id
                   WHERE c.name LIKE 'W004%' AND p.track_id IS NULL
                     AND p.id NOT IN ('d0040000-0000-0000-0000-000000000002','d0040000-0000-0000-0000-000000000003',
                                      'd0040000-0000-0000-0000-000000000004','d0040000-0000-0000-0000-000000000005')),
  '28 bridge_status service path sees every unlinked track; STABLE (read-only); no auto-backfill');

SELECT pg_temp.t(
  NOT has_function_privilege('authenticated', 'public.programme_transition_service(uuid,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.link_track_to_programme(uuid,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.link_track_to_programme(uuid,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.import_assessment_findings(uuid,uuid)', 'EXECUTE'),
  '29 surface: service-path transition not executable by authenticated; RPCs authenticated-only');

-- ============================================================================
-- old pipeline invariants
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE e_upd text; e_del text; e_app text;
BEGIN
  BEGIN UPDATE stage_transitions SET note='x' WHERE track_id='e0040000-0000-0000-0000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN e_upd := SQLERRM; END;
  BEGIN DELETE FROM stage_transitions WHERE track_id='e0040000-0000-0000-0000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN e_del := SQLERRM; END;
  BEGIN UPDATE approvals SET note='x';
  EXCEPTION WHEN insufficient_privilege THEN e_app := SQLERRM; END;
  PERFORM pg_temp.t(e_upd IS NOT NULL AND e_del IS NOT NULL AND e_app IS NOT NULL,
    '30 stage_transitions + approvals remain append-only for authenticated');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a0040000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.advance_track_stage('e0040000-0000-0000-0000-000000000002', 1, 'W004 ro');
    PERFORM pg_temp.t(false, '31 old guard intact: read_only still cannot advance stages');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE 'read_only cannot advance%', '31 old guard intact: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ---------- teardown ----------
SELECT pg_temp.w004_wipe();
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM client_orgs WHERE name LIKE 'W004%')
             AND NOT EXISTS (SELECT 1 FROM import_runs r JOIN practices p ON p.id=r.partner_id
                              WHERE p.name LIKE 'W004%'),
  '32 teardown: own namespace wiped (shared TESTFIX world never touched)');
