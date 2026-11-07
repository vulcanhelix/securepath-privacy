-- ============================================================================
-- W3-01 general import framework — psql acceptance checks
-- (migration 20261106000024_import_framework.sql · GitHub #42 · spec §13.1)
--
-- SELF-CONTAINED: seeds its own partners, users, clients and programmes in the
-- @w3i1.test / 'W3I1%' namespace (uuids all carry '301'). Never reads or
-- mutates the shared TESTFIX world. Wipes its own namespace at start AND end.
--
-- JWT callers simulated via SET ROLE authenticated + request.jwt.claims in the
-- SAME transaction as the calls (e2e_role_assignments.sql pattern). SET ROLE
-- persists past COMMIT — every block ends with RESET ROLE.
--
-- Covers: schema (new run/row/register columns, widened vocabularies);
-- import_begin guards (anon, cross-partner, read_only, client-side, closed
-- programme, payload shape, unwired kinds); consultant client-scope write;
-- preview (per-row validation, reject reasons, in-file dup, exists diff,
-- idempotent re-preview); commit (provenance import_run_id + mapped_entity,
-- normalisation, lead resolution, CALC recompute, audit, stamps); idempotent
-- re-import + re-commit no-op; immutability of committed runs/rows; abandon;
-- import_run_detail read gate; programme-scope RLS read; write-protection of
-- provenance; the redefined W0-04 findings import still green end-to-end;
-- function surface.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_import_framework.sql
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
CREATE OR REPLACE FUNCTION pg_temp.w3i1_wipe() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.client_orgs WHERE name LIKE 'W3I1%';   -- programmes, items, runs cascade
  DELETE FROM public.practices   WHERE name LIKE 'W3I1%';   -- import_runs/rows
  DELETE FROM public.users       WHERE email LIKE '%@w3i1.test';
  DELETE FROM auth.users         WHERE email LIKE '%@w3i1.test';
END $$;
SELECT pg_temp.w3i1_wipe();

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
  ('a3010000-0000-0000-0000-000000000001'::uuid, 'admin-a@w3i1.test'),
  ('a3010000-0000-0000-0000-000000000002'::uuid, 'admin-b@w3i1.test'),
  ('a3010000-0000-0000-0000-000000000003'::uuid, 'ro-a@w3i1.test'),
  ('a3010000-0000-0000-0000-000000000004'::uuid, 'ca-a1@w3i1.test'),
  ('a3010000-0000-0000-0000-000000000005'::uuid, 'cons-a@w3i1.test')
) AS u(id, email);
INSERT INTO public.users (id, email) SELECT id, email FROM auth.users WHERE email LIKE '%@w3i1.test';

INSERT INTO public.practices (id, name) VALUES
  ('b3010000-0000-0000-0000-00000000000a', 'W3I1 Partner A'),
  ('b3010000-0000-0000-0000-00000000000b', 'W3I1 Partner B');
INSERT INTO public.client_orgs (id, practice_id, name) VALUES
  ('c3010000-0000-0000-0000-000000000001', 'b3010000-0000-0000-0000-00000000000a', 'W3I1 A1'),
  ('c3010000-0000-0000-0000-000000000002', 'b3010000-0000-0000-0000-00000000000b', 'W3I1 B1');

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a3010000-0000-0000-0000-000000000001','partner','partner_admin','partner','b3010000-0000-0000-0000-00000000000a'),
  ('a3010000-0000-0000-0000-000000000002','partner','partner_admin','partner','b3010000-0000-0000-0000-00000000000b'),
  ('a3010000-0000-0000-0000-000000000003','partner','read_only',    'partner','b3010000-0000-0000-0000-00000000000a'),
  ('a3010000-0000-0000-0000-000000000004','client', 'client_admin', 'client', 'c3010000-0000-0000-0000-000000000001'),
  ('a3010000-0000-0000-0000-000000000005','partner','partner_consultant','client','c3010000-0000-0000-0000-000000000001');

INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks, status) VALUES
  ('d3010000-0000-0000-0000-000000000001','c3010000-0000-0000-0000-000000000001','W3I1 P1 A1',DATE '2026-11-02',26,'implementation'),
  ('d3010000-0000-0000-0000-000000000002','c3010000-0000-0000-0000-000000000002','W3I1 PB B1',DATE '2026-11-02',26,'implementation'),
  ('d3010000-0000-0000-0000-000000000003','c3010000-0000-0000-0000-000000000001','W3I1 PC A1 closed',DATE '2026-11-02',26,'closed');

-- an existing finding in P1 for the 'exists' diff path
INSERT INTO public.register_items (programme_id, ref, finding, priority)
VALUES ('d3010000-0000-0000-0000-000000000001','W3I-EXIST','Pre-existing manual finding','Medium');

-- ============================================================================
-- schema
-- ============================================================================
SELECT pg_temp.t(
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='public' AND table_name='import_runs'
      AND column_name IN ('programme_id','file_name','file_hash','committed_by','committed_at')) = 5
  AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='register_items'
                 AND column_name='import_run_id'),
  '01 schema: import_runs +programme_id/file_name/file_hash/committed_by/at; register_items +import_run_id');

-- widened vocabularies (kind 'documents'; row status pending|skipped)
DO $$
DECLARE v_run uuid;
BEGIN
  INSERT INTO public.import_runs (partner_id, kind, status)
  VALUES ('b3010000-0000-0000-0000-00000000000a','documents','received') RETURNING id INTO v_run;
  INSERT INTO public.import_rows (import_run_id, row_no, raw, status) VALUES
    (v_run, 1, '{}', 'pending'), (v_run, 2, '{}', 'skipped');
  DELETE FROM public.import_rows WHERE import_run_id = v_run;
  DELETE FROM public.import_runs WHERE id = v_run;
  PERFORM pg_temp.t(true, '02 widened vocabularies: kind documents; row status pending+skipped');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '02 widened vocabularies: '||SQLERRM);
END $$;

-- ============================================================================
-- import_begin — guards
-- ============================================================================
BEGIN;   -- unauthenticated (no JWT claims)
SET ROLE authenticated;
DO $$ BEGIN
  BEGIN
    PERFORM public.import_begin('d3010000-0000-0000-0000-000000000001','findings','f.csv',NULL,'[]');
    PERFORM pg_temp.t(false, '03 unauthenticated begin denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE 'not authenticated%', '03 unauthenticated begin denied: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_begin('d3010000-0000-0000-0000-000000000001','findings','f.csv',NULL,
      '[{"ref":"X","finding":"y"}]');
    PERFORM pg_temp.t(false, '04 partner-B admin cannot begin on partner-A programme');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '04 partner-B admin cannot begin on partner-A programme: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_begin('d3010000-0000-0000-0000-000000000001','findings','f.csv',NULL,
      '[{"ref":"X","finding":"y"}]');
    PERFORM pg_temp.t(false, '05 read_only cannot begin');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '05 read_only cannot begin: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_begin('d3010000-0000-0000-0000-000000000001','findings','f.csv',NULL,
      '[{"ref":"X","finding":"y"}]');
    PERFORM pg_temp.t(false, '06 client-side client_admin cannot begin (partner write roles only)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '06 client-side client_admin cannot begin: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- payload + kind + closed-programme validation, as partner-A admin
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE e1 text; e2 text; e3 text; e4 text; e5 text;
BEGIN
  BEGIN PERFORM public.import_begin('d3010000-0000-0000-0000-000000000001','findings','f.csv',NULL,'[]');
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;
  BEGIN PERFORM public.import_begin('d3010000-0000-0000-0000-000000000001','findings','f.csv',NULL,'{"ref":"X"}');
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;
  BEGIN PERFORM public.import_begin('d3010000-0000-0000-0000-000000000001','findings','f.csv',NULL,'["not an object"]');
  EXCEPTION WHEN OTHERS THEN e3 := SQLERRM; END;
  BEGIN PERFORM public.import_begin('d3010000-0000-0000-0000-000000000001','tracker','f.xlsx',NULL,'[{"ref":"X"}]');
  EXCEPTION WHEN OTHERS THEN e4 := SQLERRM; END;
  BEGIN PERFORM public.import_begin('d3010000-0000-0000-0000-000000000003','findings','f.csv',NULL,'[{"ref":"X","finding":"y"}]');
  EXCEPTION WHEN OTHERS THEN e5 := SQLERRM; END;
  PERFORM pg_temp.t(
    e1 LIKE '%non-empty jsonb array%' AND e2 LIKE '%non-empty jsonb array%'
    AND e3 LIKE '%not jsonb objects%' AND e4 LIKE '%not wired yet%'
    AND e5 LIKE '%closed programme%',
    '07 begin validates payload shape, unwired kinds and closed programmes');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- begin → preview → commit — happy path (consultant client-scope write)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
DECLARE r jsonb;
BEGIN
  r := public.import_begin('d3010000-0000-0000-0000-000000000001','findings','register.csv',
        'deadbeef',
        '[
          {"ref":"W3I-01","finding":"No information officer registered","priority":"HIGH","assessment_window":"2026 Q4","lead":"cons-a@w3i1.test","planned_close_week":"4"},
          {"ref":"W3I-02","finding":"PAIA manual not published","priority":"low"},
          {"ref":"W3I-EXIST","finding":"Changed text for existing ref","priority":"High"},
          {"ref":"","finding":"missing ref"},
          {"finding":"also missing ref"},
          {"ref":"W3I-03","priority":"Medium"},
          {"ref":"W3I-04","finding":"x","priority":"urgent"},
          {"ref":"W3I-05","finding":"x","planned_close_week":"soon"},
          {"ref":"W3I-06","finding":"x","lead":"ghost@w3i1.test"},
          {"ref":"W3I-01","finding":"dup ref in file"}
        ]');
  PERFORM set_config('e2e.run1', r->>'import_run_id', false);
  PERFORM pg_temp.t((r->>'rows')::int = 10 AND (r->>'prior_runs_same_file')::int = 0,
    '08 client-scope partner_consultant begins a run — 10 rows parked pending');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  (SELECT status FROM import_runs WHERE id = current_setting('e2e.run1')::uuid) = 'received'
  AND (SELECT partner_id FROM import_runs WHERE id = current_setting('e2e.run1')::uuid)
        = 'b3010000-0000-0000-0000-00000000000a'
  AND (SELECT programme_id FROM import_runs WHERE id = current_setting('e2e.run1')::uuid)
        = 'd3010000-0000-0000-0000-000000000001'
  AND (SELECT file_name FROM import_runs WHERE id = current_setting('e2e.run1')::uuid) = 'register.csv'
  AND (SELECT file_ref   FROM import_runs WHERE id = current_setting('e2e.run1')::uuid) = 'upload:register.csv'
  AND (SELECT count(*) FROM import_rows WHERE import_run_id = current_setting('e2e.run1')::uuid
        AND status = 'pending') = 10
  AND EXISTS (SELECT 1 FROM audit_log WHERE action='import.run_created'
               AND detail->>'import_run_id' = current_setting('e2e.run1')),
  '09 run received: partner derived server-side, file meta stored, 10 pending rows, audited');

-- preview: partner-B and read_only denied
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_preview(current_setting('e2e.run1')::uuid);
    PERFORM pg_temp.t(false, '10 partner-B cannot preview partner-A run');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '10 partner-B cannot preview partner-A run: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_preview(current_setting('e2e.run1')::uuid);
    PERFORM pg_temp.t(false, '11 read_only cannot preview');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '11 read_only cannot preview: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- preview happy path: 3 ok (2 create + 1 exists), 7 rejected
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
DECLARE p jsonb;
BEGIN
  p := public.import_preview(current_setting('e2e.run1')::uuid);
  PERFORM pg_temp.t(
    (p->>'rows')::int = 10 AND (p->>'ok')::int = 3 AND (p->>'rejected')::int = 7
    AND (p->>'will_create')::int = 2 AND (p->>'already_exists')::int = 1
    AND jsonb_array_length(p->'rejects') = 7 AND jsonb_array_length(p->'diff') = 3,
    '12 preview: 3 valid (2 create, 1 exists), 7 rejected with reasons');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  (SELECT status FROM import_runs WHERE id = current_setting('e2e.run1')::uuid) = 'previewed'
  AND (SELECT count(*) FROM import_rows WHERE import_run_id = current_setting('e2e.run1')::uuid
        AND status='ok') = 3
  AND (SELECT count(*) FROM import_rows WHERE import_run_id = current_setting('e2e.run1')::uuid
        AND status='rejected' AND reject_reason IS NOT NULL) = 7
  AND EXISTS (SELECT 1 FROM import_rows WHERE import_run_id = current_setting('e2e.run1')::uuid
               AND row_no = 10 AND status='rejected'
               AND reject_reason LIKE 'duplicate ref%first seen at row 1')
  AND (SELECT raw->>'_outcome' FROM import_rows
        WHERE import_run_id = current_setting('e2e.run1')::uuid AND row_no = 3) = 'exists'
  AND ((SELECT raw->'_parsed'->>'priority' FROM import_rows
        WHERE import_run_id = current_setting('e2e.run1')::uuid AND row_no = 1) = 'High')
  AND EXISTS (SELECT 1 FROM audit_log WHERE action='import.previewed'
               AND detail->>'import_run_id' = current_setting('e2e.run1')),
  '13 rows classified: ok/rejected+reasons, dup flagged, exists diff, priority normalised, audited');

-- the 'exists' row carries the differs flag (incoming finding text ≠ stored)
SELECT pg_temp.t(
  (SELECT (raw->>'_differs')::boolean FROM import_rows
    WHERE import_run_id = current_setting('e2e.run1')::uuid AND row_no = 3) IS NOT NULL,
  '14 exists diff flags drift between file and stored finding');

-- commit before preview is refused (fresh run)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb;
BEGIN
  r := public.import_begin('d3010000-0000-0000-0000-000000000001','findings','later.csv',NULL,
        '[{"ref":"W3I-L1","finding":"never lands"}]');
  PERFORM set_config('e2e.run_noprev', r->>'import_run_id', false);
  BEGIN
    PERFORM public.import_commit((r->>'import_run_id')::uuid);
    PERFORM pg_temp.t(false, '15 commit before preview refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%previewed before commit%', '15 commit before preview refused: '||SQLERRM);
  END;
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

-- commit guards: partner-B, read_only
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_commit(current_setting('e2e.run1')::uuid);
    PERFORM pg_temp.t(false, '16 partner-B cannot commit partner-A run');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '16 partner-B cannot commit partner-A run: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- commit happy path (admin-A this time — any partner write role may commit)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb;
BEGIN
  r := public.import_commit(current_setting('e2e.run1')::uuid);
  PERFORM pg_temp.t(
    (r->>'created')::int = 2 AND (r->>'already_imported')::int = 1
    AND (r->>'rejected')::int = 7
    AND (SELECT count(*) FROM register_items
          WHERE programme_id='d3010000-0000-0000-0000-000000000001') = 3,
    '17 commit: 2 created + 1 already_imported; register now holds 3 findings');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  (SELECT status FROM import_runs WHERE id = current_setting('e2e.run1')::uuid) = 'committed'
  AND (SELECT committed_by FROM import_runs WHERE id = current_setting('e2e.run1')::uuid)
        = 'a3010000-0000-0000-0000-000000000001'
  AND (SELECT committed_at FROM import_runs WHERE id = current_setting('e2e.run1')::uuid) IS NOT NULL
  AND EXISTS (SELECT 1 FROM audit_log WHERE action='import.committed'
               AND detail->>'import_run_id' = current_setting('e2e.run1')
               AND (detail->>'created')::int = 2),
  '18 run committed with stamps; import.committed audited');

SELECT pg_temp.t(
  (SELECT bool_and(ri.import_run_id = current_setting('e2e.run1')::uuid)
     FROM register_items ri WHERE ri.programme_id='d3010000-0000-0000-0000-000000000001'
       AND ri.ref IN ('W3I-01','W3I-02'))
  AND (SELECT count(*) FROM register_items WHERE programme_id='d3010000-0000-0000-0000-000000000001'
        AND ref IN ('W3I-01','W3I-02')) = 2
  AND (SELECT lead FROM register_items WHERE programme_id='d3010000-0000-0000-0000-000000000001'
        AND ref='W3I-01') = 'a3010000-0000-0000-0000-000000000005'
  AND (SELECT planned_close_week FROM register_items WHERE ref='W3I-01'
        AND programme_id='d3010000-0000-0000-0000-000000000001') = 4
  AND (SELECT planned_close_date FROM register_items WHERE ref='W3I-01'
        AND programme_id='d3010000-0000-0000-0000-000000000001') = DATE '2026-11-27'
  AND (SELECT priority FROM register_items WHERE ref='W3I-02'
        AND programme_id='d3010000-0000-0000-0000-000000000001') = 'Low'
  AND (SELECT assessment_window FROM register_items WHERE ref='W3I-01'
        AND programme_id='d3010000-0000-0000-0000-000000000001') = '2026 Q4',
  '19 provenance+normalisation: import_run_id lineage, lead resolved, priority/week applied, CALC planned_close_date 2026-11-27');

SELECT pg_temp.t(
  (SELECT count(*) FROM import_rows
    WHERE import_run_id = current_setting('e2e.run1')::uuid
      AND mapped_entity LIKE 'register_items:%') = 3
  AND (SELECT raw->>'_outcome' FROM import_rows
        WHERE import_run_id = current_setting('e2e.run1')::uuid AND row_no=1) = 'created'
  AND (SELECT raw->>'_outcome' FROM import_rows
        WHERE import_run_id = current_setting('e2e.run1')::uuid AND row_no=3) = 'already_imported'
  AND (SELECT mapped_entity FROM import_rows
        WHERE import_run_id = current_setting('e2e.run1')::uuid AND row_no=3)
      = 'register_items:' || (SELECT id FROM register_items WHERE ref='W3I-EXIST'
                                AND programme_id='d3010000-0000-0000-0000-000000000001'),
  '20 mapped_entity lineage on every applied row; exists row reconciled to W3I-EXIST');

-- ============================================================================
-- idempotency: re-import the same file, re-commit a committed run
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb; p jsonb; c jsonb;
BEGIN
  r := public.import_begin('d3010000-0000-0000-0000-000000000001','findings','register.csv',
        'deadbeef',
        '[
          {"ref":"W3I-01","finding":"No information officer registered","priority":"HIGH"},
          {"ref":"W3I-02","finding":"PAIA manual not published","priority":"low"},
          {"ref":"W3I-07","finding":"A genuinely new finding","priority":"Medium"}
        ]');
  PERFORM pg_temp.t((r->>'prior_runs_same_file')::int = 1,
    '21 begin reports the prior identical file hash');
  p := public.import_preview((r->>'import_run_id')::uuid);
  PERFORM pg_temp.t((p->>'will_create')::int = 1 AND (p->>'already_exists')::int = 2,
    '22 re-import preview: 2 already exist, only W3I-07 would create');
  c := public.import_commit((r->>'import_run_id')::uuid);
  PERFORM set_config('e2e.run2', c->>'import_run_id', false);
  PERFORM pg_temp.t((c->>'created')::int = 1 AND (c->>'already_imported')::int = 2
    AND (SELECT count(*) FROM register_items
          WHERE programme_id='d3010000-0000-0000-0000-000000000001') = 4,
    '23 re-import is IDEMPOTENT: one new finding, no dup rows');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb; n bigint;
BEGIN
  SELECT count(*) INTO n FROM register_items
   WHERE programme_id='d3010000-0000-0000-0000-000000000001';
  r := public.import_commit(current_setting('e2e.run2')::uuid);
  PERFORM pg_temp.t((r->>'already_committed')::boolean = true
    AND (r->>'created')::int = 1
    AND (SELECT count(*) FROM register_items
          WHERE programme_id='d3010000-0000-0000-0000-000000000001') = n,
    '24 re-commit of a committed run is a no-op returning the stored result');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- versioning: committed run + rows immutable (app path AND service path)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE e1 text; e2 text; e3 text; e4 text;
BEGIN
  BEGIN UPDATE import_runs SET status='received' WHERE id=current_setting('e2e.run1')::uuid;
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;
  BEGIN UPDATE import_runs SET preview='{}' WHERE id=current_setting('e2e.run1')::uuid;
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;
  BEGIN UPDATE import_rows SET status='rejected', reject_reason='tamper'
        WHERE import_run_id=current_setting('e2e.run1')::uuid AND row_no=1;
  EXCEPTION WHEN OTHERS THEN e3 := SQLERRM; END;
  BEGIN INSERT INTO import_rows (import_run_id,row_no,raw,status)
        VALUES (current_setting('e2e.run1')::uuid,99,'{}','pending');
  EXCEPTION WHEN OTHERS THEN e4 := SQLERRM; END;
  PERFORM pg_temp.t(
    e1 LIKE '%immutable%' AND e2 LIKE '%immutable%'
    AND e3 LIKE '%immutable%' AND e4 LIKE '%immutable%',
    '25 committed run + rows frozen on the app path (update run/row, insert row all blocked)');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- service path is bound by the same guard (unconditional trigger)
DO $$
DECLARE e1 text; e2 text;
BEGIN
  BEGIN UPDATE import_runs SET status='received' WHERE id=current_setting('e2e.run1')::uuid;
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;
  BEGIN UPDATE import_rows SET status='ok' WHERE import_run_id=current_setting('e2e.run1')::uuid AND row_no=1;
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;
  PERFORM pg_temp.t(e1 LIKE '%immutable%' AND e2 LIKE '%immutable%',
    '26 committed run + rows frozen on the service path too');
END $$;

-- direct INSERT of a committed run / previewed→committed update without
-- stamps — both refused (authenticated holds no grant on the stamp columns;
-- the trigger is the second lock)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE e1 text; e2 text;
BEGIN
  BEGIN INSERT INTO import_runs (partner_id,kind,status)
        VALUES ('b3010000-0000-0000-0000-00000000000a','findings','committed');
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;
  BEGIN UPDATE import_runs SET status='committed'
        WHERE id=current_setting('e2e.run_noprev')::uuid;
  EXCEPTION WHEN OTHERS THEN e2 := SQLERRM; END;
  PERFORM pg_temp.t(e1 IS NOT NULL AND e2 IS NOT NULL,
    '27 direct committed-state writes refused: '||COALESCE(e1,'?')||' | '||COALESCE(e2,'?'));
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  NOT has_column_privilege('authenticated','public.import_runs','committed_by','UPDATE')
  AND NOT has_column_privilege('authenticated','public.import_runs','programme_id','INSERT')
  AND NOT has_column_privilege('authenticated','public.register_items','import_run_id','UPDATE'),
  '28 provenance + commit columns are write-protected for authenticated (no grants)');

-- ============================================================================
-- abandon
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb; e1 text;
BEGIN
  r := public.import_abandon(current_setting('e2e.run_noprev')::uuid);
  PERFORM pg_temp.t(r->>'status' = 'abandoned'
    AND (SELECT status FROM import_runs WHERE id=current_setting('e2e.run_noprev')::uuid) = 'abandoned'
    AND EXISTS (SELECT 1 FROM audit_log WHERE action='import.abandoned'
                 AND detail->>'import_run_id' = current_setting('e2e.run_noprev')),
    '29 abandon flips the staged run + audits');
  BEGIN
    PERFORM public.import_preview(current_setting('e2e.run_noprev')::uuid);
  EXCEPTION WHEN OTHERS THEN e1 := SQLERRM; END;
  PERFORM pg_temp.t(e1 LIKE '%cannot be previewed%',
    '30 abandoned run cannot be previewed');
  BEGIN
    PERFORM public.import_abandon(current_setting('e2e.run1')::uuid);
    PERFORM pg_temp.t(false, '31 committed run cannot be abandoned');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%cannot be abandoned%', '31 committed run cannot be abandoned: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- import_run_detail + RLS read
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.import_run_detail(current_setting('e2e.run1')::uuid);
    PERFORM pg_temp.t(false, '32 partner-B cannot read partner-A run detail');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '32 partner-B cannot read partner-A run detail: '||SQLERRM);
  END;
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
DECLARE d jsonb;
BEGIN
  d := public.import_run_detail(current_setting('e2e.run1')::uuid);
  PERFORM pg_temp.t(d->'run'->>'status' = 'committed'
    AND jsonb_array_length(d->'rows') = 10,
    '33 consultant reads run detail: committed run + 10 rows');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE d jsonb; e1 text;
BEGIN
  d := public.import_run_detail(current_setting('e2e.run1')::uuid);
  PERFORM pg_temp.t(d->'run'->>'id' = current_setting('e2e.run1'),
    '34 partner read_only can read run detail');
END $$;
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- table-level RLS: partner-B sees nothing; consultant sees the run via the
-- programme-scope policy (no partner-scope role needed)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM import_runs WHERE id=current_setting('e2e.run1')::uuid) = 0
  AND (SELECT count(*) FROM import_rows WHERE import_run_id=current_setting('e2e.run1')::uuid) = 0,
  '35 RLS: partner-B sees no run or rows at table level');
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM import_runs WHERE id=current_setting('e2e.run1')::uuid) = 1
  AND (SELECT count(*) FROM import_rows WHERE import_run_id=current_setting('e2e.run1')::uuid) = 10,
  '36 RLS: client-scope consultant reads the run+rows via programme-scope policy');
ROLLBACK;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- redefined W0-04 findings import still works end-to-end
-- ============================================================================
INSERT INTO public.tracks (id, client_org_id, track_kind) VALUES
  ('e3010000-0000-0000-0000-000000000001','c3010000-0000-0000-0000-000000000001','privacy');
INSERT INTO public.assessment_sessions (id, client_org_id, framework, title, audit_date, track_id) VALUES
  ('f3010000-0000-0000-0000-000000000001','c3010000-0000-0000-0000-000000000001','popia','W3I1 S1',DATE '2026-11-05','e3010000-0000-0000-0000-000000000001');
DO $$
DECLARE q uuid;
BEGIN
  SELECT id INTO q FROM assessment_questions WHERE framework='popia' AND active ORDER BY uid LIMIT 1;
  IF q IS NULL THEN RAISE EXCEPTION 'popia question bank missing'; END IF;
  INSERT INTO assessment_responses (session_id, question_id, response, findings)
  VALUES ('f3010000-0000-0000-0000-000000000001', q, 'non_compliant', 'W3I1 gap');
END $$;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3010000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE r jsonb;
BEGIN
  r := public.import_assessment_findings('d3010000-0000-0000-0000-000000000001','f3010000-0000-0000-0000-000000000001');
  PERFORM set_config('e2e.run_w004', r->>'import_run_id', false);
  PERFORM pg_temp.t((r->>'created')::int = 1
    AND (SELECT status FROM import_runs WHERE id=(r->>'import_run_id')::uuid) = 'committed'
    AND (SELECT committed_by FROM import_runs WHERE id=(r->>'import_run_id')::uuid)
          = 'a3010000-0000-0000-0000-000000000001'
    AND (SELECT committed_at FROM import_runs WHERE id=(r->>'import_run_id')::uuid) IS NOT NULL
    AND (SELECT programme_id FROM import_runs WHERE id=(r->>'import_run_id')::uuid)
          = 'd3010000-0000-0000-0000-000000000001'
    AND (SELECT count(*) FROM import_rows WHERE import_run_id=(r->>'import_run_id')::uuid
          AND status='ok' AND mapped_entity LIKE 'register_items:%') = 1,
    '37 W0-04 redefined: assessment findings import still commits run+rows trail');
END $$;
COMMIT;
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- surface
-- ============================================================================
SELECT pg_temp.t(
  NOT has_function_privilege('anon', 'public.import_begin(uuid,text,text,text,jsonb)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.import_begin(uuid,text,text,text,jsonb)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.import_preview(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.import_commit(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.import_abandon(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.import_run_detail(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.import_assert_write(public.import_runs)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.import_parse_finding_row(jsonb)', 'EXECUTE'),
  '38 surface: RPCs authenticated-only; private helpers not executable by app roles');

-- ---------- teardown ----------
SELECT pg_temp.w3i1_wipe();
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM client_orgs WHERE name LIKE 'W3I1%')
             AND NOT EXISTS (SELECT 1 FROM import_runs r JOIN practices p ON p.id=r.partner_id
                              WHERE p.name LIKE 'W3I1%')
             AND NOT EXISTS (SELECT 1 FROM register_items WHERE ref LIKE 'W3I-%'),
  '39 teardown: own namespace wiped (shared TESTFIX world never touched)');
