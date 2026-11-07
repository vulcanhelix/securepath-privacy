-- ============================================================================
-- W2-03 partner branding — psql acceptance checks for
-- 20261106000028_partner_branding_update.sql (update_practice_branding).
--
-- Self-contained (e2e_platform_admin.sql style): builds its own @w203.test
-- users + 'W203%' partners; never touches the TESTFIX world. JWT callers
-- simulated via SET ROLE authenticated + request.jwt.claims inside
-- BEGIN … ROLLBACK blocks.
--
-- Covers: partner_admin writes; absent-key keeps / null clears semantics;
-- partner_consultant, other-partner admin, platform_admin, unscoped and anon
-- callers all denied; validation (hex format, empty name, unknown key,
-- non-http logo URL); audit row carries patch + previous; no partial writes.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_partner_branding.sql
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

-- wipe own namespace (re-runnable)
CREATE OR REPLACE FUNCTION pg_temp.w203_wipe() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.role_assignments WHERE user_id IN (SELECT id FROM public.users WHERE email LIKE '%@w203.test');
  DELETE FROM public.client_orgs   WHERE practice_id IN (SELECT id FROM public.practices WHERE name LIKE 'W203%');
  DELETE FROM public.practices     WHERE name LIKE 'W203%';
  DELETE FROM public.users         WHERE email LIKE '%@w203.test';
  DELETE FROM auth.users           WHERE email LIKE '%@w203.test';
END $$;
SELECT pg_temp.w203_wipe();

-- ---------- fixtures ----------
INSERT INTO auth.users (id, instance_id, email, encrypted_password, aud, role,
    email_confirmed_at, created_at, updated_at, confirmation_token,
    email_change, email_change_token_new, email_change_token_current,
    recovery_token, reauthentication_token, phone_change, phone_change_token,
    raw_app_meta_data, raw_user_meta_data)
SELECT u.id, '00000000-0000-0000-0000-000000000000', u.email,
    crypt('x', gen_salt('bf')), 'authenticated', 'authenticated',
    now(), now(), now(), '',
    '', '', '',
    '', '', '', '',
    '{"provider":"email","providers":["email"]}', '{}'
FROM (VALUES
  ('a2030000-0000-0000-0000-000000000001'::uuid, 'admin@w203.test'),
  ('a2030000-0000-0000-0000-000000000002'::uuid, 'consultant@w203.test'),
  ('a2030000-0000-0000-0000-000000000003'::uuid, 'otheradmin@w203.test'),
  ('a2030000-0000-0000-0000-000000000004'::uuid, 'platadmin@w203.test'),
  ('a2030000-0000-0000-0000-000000000005'::uuid, 'stray@w203.test')
) AS u(id, email);
INSERT INTO public.users (id, email)
  SELECT id, email FROM auth.users WHERE email LIKE '%@w203.test';

INSERT INTO public.practices (id, name, type, country, accent_hex, sign_in_text) VALUES
  ('b2030000-0000-0000-0000-000000000001', 'W203 Alpha', 'msp', 'ZA', '#2255aa', 'old sign-in text'),
  ('b2030000-0000-0000-0000-000000000002', 'W203 Beta',  'msp', 'ZA', NULL, NULL);

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a2030000-0000-0000-0000-000000000001','partner','partner_admin','partner','b2030000-0000-0000-0000-000000000001'),
  ('a2030000-0000-0000-0000-000000000002','partner','partner_consultant','partner','b2030000-0000-0000-0000-000000000001'),
  ('a2030000-0000-0000-0000-000000000003','partner','partner_admin','partner','b2030000-0000-0000-0000-000000000002'),
  ('a2030000-0000-0000-0000-000000000004','platform','platform_admin','partner',NULL);

-- probe: run the write as the current JWT; returns 'OK' or the error text
CREATE OR REPLACE FUNCTION pg_temp.w203_write(p_partner uuid, p_payload jsonb)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.update_practice_branding(p_partner, p_payload);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $$;

-- ---------- 1. happy path: partner_admin writes, absent keys keep ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2030000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  pg_temp.w203_write('b2030000-0000-0000-0000-000000000001',
    '{"accent_hex":"#0E6F5C","sign_in_text":"W203 portal","logo_url":"https://w203.test/logo.png"}') = 'OK',
  '01 partner_admin write accepted');
RESET ROLE;
SELECT pg_temp.t(
  (SELECT accent_hex FROM public.practices WHERE id = 'b2030000-0000-0000-0000-000000000001') = '#0e6f5c'
  AND (SELECT sign_in_text FROM public.practices WHERE id = 'b2030000-0000-0000-0000-000000000001') = 'W203 portal'
  AND (SELECT logo_url FROM public.practices WHERE id = 'b2030000-0000-0000-0000-000000000001') = 'https://w203.test/logo.png'
  AND (SELECT name FROM public.practices WHERE id = 'b2030000-0000-0000-0000-000000000001') = 'W203 Alpha',
  '02 stored: hex normalised, absent keys kept');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_log
    WHERE practice_id = 'b2030000-0000-0000-0000-000000000001'
      AND action = 'partner.branding_updated'
      AND detail->'patch'->>'accent_hex' = '#0E6F5C'
      AND detail->'previous'->>'accent_hex' = '#2255aa'),
  '03 audit row carries patch + previous');
COMMIT;

-- ---------- 2. null clears a set field ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2030000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"sign_in_text":null,"logo_url":""}') = 'OK',
  '04 null/empty clears accepted');
RESET ROLE;
SELECT pg_temp.t(
  (SELECT sign_in_text FROM public.practices WHERE id = 'b2030000-0000-0000-0000-000000000001') IS NULL
  AND (SELECT logo_url FROM public.practices WHERE id = 'b2030000-0000-0000-0000-000000000001') IS NULL
  AND (SELECT accent_hex FROM public.practices WHERE id = 'b2030000-0000-0000-0000-000000000001') = '#0e6f5c',
  '05 cleared fields are NULL, others untouched');
COMMIT;

-- ---------- 3. non-partner_admin callers denied, nothing written ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2030000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"accent_hex":"#000000"}')
    LIKE '%partner_admin%', '06 partner_consultant denied');
SET request.jwt.claims = '{"sub":"a2030000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"accent_hex":"#000000"}')
    LIKE '%partner_admin%', '07 other partner''s admin denied (cross-tenant)');
SET request.jwt.claims = '{"sub":"a2030000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"accent_hex":"#000000"}')
    LIKE '%partner_admin%', '08 platform_admin denied (branding stays partner_admin''s)');
SET request.jwt.claims = '{"sub":"a2030000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"accent_hex":"#000000"}')
    LIKE '%partner_admin%', '09 user with no assignment denied');
RESET ROLE;
SELECT pg_temp.t(
  (SELECT accent_hex FROM public.practices WHERE id = 'b2030000-0000-0000-0000-000000000001') = '#0e6f5c',
  '10 denied writes changed nothing');
SELECT pg_temp.t(NOT EXISTS (
    SELECT 1 FROM public.audit_log
    WHERE practice_id = 'b2030000-0000-0000-0000-000000000001'
      AND action = 'partner.branding_updated'
      AND detail->'patch'->>'accent_hex' = '#000000'),
  '11 denied writes left no audit row');
ROLLBACK;

-- ---------- 4. validation ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2030000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"accent_hex":"red"}')
    LIKE '%#rrggbb%', '12 bad accent_hex rejected');
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"primary_hex":"#12345"}')
    LIKE '%#rrggbb%', '13 short primary_hex rejected');
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"name":"  "}')
    LIKE '%name cannot be empty%', '14 blank name rejected');
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"subdomain":"evil"}')
    LIKE '%not a branding field%', '15 non-allowlisted key rejected (subdomain stays platform-only)');
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"logo_url":"ftp://x/y.png"}')
    LIKE '%http(s)%', '16 non-http logo_url rejected');
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{}')
    LIKE '%empty payload%', '17 empty payload rejected');
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000009', '{"name":"Ghost"}')
    LIKE '%not found%', '18 unknown partner rejected');
RESET ROLE;
ROLLBACK;

-- ---------- 5. anon refused (default privileges grant EXECUTE to anon in this
-- image — the in-body auth.uid() check is the real gate, same as every other
-- definer here) ----------
BEGIN;
SET ROLE anon;
-- claims committed in block 1 persist for the session — clear them so this
-- really is an anonymous caller, not just an unroled admin JWT
SET request.jwt.claims = '{}';
SELECT pg_temp.t(pg_temp.w203_write('b2030000-0000-0000-0000-000000000001', '{"accent_hex":"#000000"}')
    LIKE '%not authenticated%', '19 anon refused by the auth gate');
RESET ROLE;
ROLLBACK;

-- ---------- cleanup ----------
SELECT pg_temp.w203_wipe();
DROP FUNCTION pg_temp.w203_write(uuid, jsonb);
DROP FUNCTION pg_temp.w203_wipe();
DROP FUNCTION pg_temp.t(boolean, text);
