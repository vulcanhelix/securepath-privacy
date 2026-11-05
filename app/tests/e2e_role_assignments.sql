-- ============================================================================
-- W0-00 authz remodel — psql acceptance checks for the role_assignments
-- predicate catalogue. Self-contained: builds its own fixtures (auth.users
-- rows inserted directly, @w0ra.test namespace), then simulates JWT callers
-- via `SET ROLE authenticated` + `request.jwt.claims` exactly as PostgREST
-- presents them.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_role_assignments.sql
--
-- Covers FR-ACC-04 (partner scoping incl. multi-role union) and FR-ACC-05
-- (end_date expiry denies) plus the compat-shim parity contract.
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- ---------- fixtures ----------
DELETE FROM consultant_assignments WHERE user_id IN
  (SELECT id FROM users WHERE email LIKE '%@w0ra.test');
DELETE FROM users WHERE email LIKE '%@w0ra.test';           -- cascades to role_assignments
DELETE FROM auth.users WHERE email LIKE '%@w0ra.test';
DELETE FROM client_orgs WHERE practice_id IN (SELECT id FROM practices WHERE name LIKE 'W0RA%');
DELETE FROM practices WHERE name LIKE 'W0RA%';

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
  ('aa000000-0000-0000-0000-000000000001'::uuid, 'owner@w0ra.test'),
  ('aa000000-0000-0000-0000-000000000002'::uuid, 'multi@w0ra.test'),
  ('aa000000-0000-0000-0000-000000000003'::uuid, 'expired@w0ra.test'),
  ('aa000000-0000-0000-0000-000000000004'::uuid, 'platform@w0ra.test'),
  ('aa000000-0000-0000-0000-000000000005'::uuid, 'ro@w0ra.test'),
  ('aa000000-0000-0000-0000-000000000006'::uuid, 'ownerB@w0ra.test')
) AS u(id, email);
INSERT INTO users (id, email) SELECT id, email FROM auth.users WHERE email LIKE '%@w0ra.test';

INSERT INTO practices (id, name) VALUES
  ('bb000000-0000-0000-0000-00000000000a', 'W0RA Alpha'),
  ('bb000000-0000-0000-0000-00000000000b', 'W0RA Beta');
INSERT INTO client_orgs (id, practice_id, name) VALUES
  ('cc000000-0000-0000-0000-00000000000a', 'bb000000-0000-0000-0000-00000000000a', 'W0RA A1'),
  ('cc000000-0000-0000-0000-00000000000b', 'bb000000-0000-0000-0000-00000000000a', 'W0RA A2'),
  ('cc000000-0000-0000-0000-00000000000c', 'bb000000-0000-0000-0000-00000000000b', 'W0RA B1');

-- owner: partner_admin over Alpha (branch a: all Alpha clients)
-- ownerB: partner_admin over Beta
-- multi: partner_consultant Alpha (partner scope) + client-scope consultant on A1
--        + client-level programme_lead on B1  → union {A1, A2(via legacy ca), B1}
-- expired: client_admin on A1 whose end_date is TODAY (exclusive → denied now)
-- platform: global platform_admin (scope_id NULL → sees no tenant data)
INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id, end_date) VALUES
  ('aa000000-0000-0000-0000-000000000001','partner','partner_admin','partner','bb000000-0000-0000-0000-00000000000a',NULL),
  ('aa000000-0000-0000-0000-000000000006','partner','partner_admin','partner','bb000000-0000-0000-0000-00000000000b',NULL),
  ('aa000000-0000-0000-0000-000000000002','partner','partner_consultant','partner','bb000000-0000-0000-0000-00000000000a',NULL),
  ('aa000000-0000-0000-0000-000000000002','partner','partner_consultant','client','cc000000-0000-0000-0000-00000000000a',NULL),
  ('aa000000-0000-0000-0000-000000000002','client','programme_lead','client','cc000000-0000-0000-0000-00000000000c',NULL),
  ('aa000000-0000-0000-0000-000000000003','client','client_admin','client','cc000000-0000-0000-0000-00000000000a',CURRENT_DATE),
  ('aa000000-0000-0000-0000-000000000004','platform','platform_admin','partner',NULL,NULL);
-- legacy matrix row grants the consultant A2 as well (old-semantics branch c)
INSERT INTO consultant_assignments (user_id, client_org_id) VALUES
  ('aa000000-0000-0000-0000-000000000002','cc000000-0000-0000-0000-00000000000b');

-- mirror trigger should have created a legacy_sync client-scope row for A2
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM role_assignments
    WHERE user_id='aa000000-0000-0000-0000-000000000002' AND level='partner'
      AND scope_type='client' AND scope_id='cc000000-0000-0000-0000-00000000000b'
      AND origin='legacy_sync' AND end_date IS NULL),
  'mirror trigger: ca INSERT synced to role_assignments');

-- ---------- multi-role union (FR-ACC-04) ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
    (SELECT count(*) FROM allowed_client_orgs()) = 3
    AND (SELECT count(*) FROM allowed_client_orgs() WHERE
         allowed_client_orgs = 'cc000000-0000-0000-0000-00000000000a'
         OR allowed_client_orgs = 'cc000000-0000-0000-0000-00000000000b'
         OR allowed_client_orgs = 'cc000000-0000-0000-0000-00000000000c') = 3,
    'multi-role user: union {client-scope A1, legacy-ca A2, programme_lead B1}');
SELECT pg_temp.t((SELECT count(*) FROM client_orgs) = 3,
    'multi-role user: client_orgs RLS shows same union');
SELECT pg_temp.t((SELECT role FROM memberships) = 'practice_consultant',
    'multi-role user: memberships view emits primary partner-scope row');
SELECT pg_temp.t(current_role_name() = 'practice_consultant'
    AND current_practice() = 'bb000000-0000-0000-0000-00000000000a',
    'multi-role user: deprecated shims map to partner scope');
SELECT pg_temp.t((SELECT count(*) FROM allowed_programmes()) = 3,
    'multi-role user: allowed_programmes stub returns client-scope union');
ROLLBACK;

-- ---------- partner admin: own partner only ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t((SELECT count(*) FROM allowed_client_orgs()) = 2,
    'partner_admin: all 2 Alpha clients, none of Beta (FR-ACC-04)');
SELECT pg_temp.t(has_partner_role('bb000000-0000-0000-0000-00000000000a', ARRAY['partner_admin']),
    'has_partner_role: true for own partner');
SELECT pg_temp.t(NOT has_partner_role('bb000000-0000-0000-0000-00000000000b', ARRAY['partner_admin']),
    'has_partner_role: false for other partner');
SELECT pg_temp.t(NOT is_platform_role(ARRAY['platform_admin']),
    'is_platform_role: false for tenant user');
-- admin sees assignment rows scoped to their partner + its clients, incl.
-- expired ones (for management) but NOT the consultant's Beta-scope row
SELECT pg_temp.t((SELECT count(*) FROM role_assignments
      WHERE user_id='aa000000-0000-0000-0000-000000000002') = 3,
    'partner_admin sees all Alpha-scoped assignments (3), not cross-partner');
SELECT pg_temp.t((SELECT count(*) FROM memberships
      WHERE role IN ('practice_owner','practice_consultant')) = 2,
    'partner_admin: memberships view = owner + consultant (expired excluded)');
ROLLBACK;

-- ---------- expired end_date denies (FR-ACC-05) ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t((SELECT count(*) FROM allowed_client_orgs()) = 0,
    'expired (end_date=today): allowed_client_orgs empty');
SELECT pg_temp.t((SELECT count(*) FROM client_orgs) = 0,
    'expired: client_orgs RLS empty');
SELECT pg_temp.t((SELECT count(*) FROM memberships) = 0,
    'expired: memberships view empty');
SELECT pg_temp.t(current_practice() IS NULL AND current_role_name() IS NULL,
    'expired: deprecated shims return NULL');
ROLLBACK;

-- ---------- platform role: no tenant visibility ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.t(is_platform_role(ARRAY['platform_admin']),
    'platform: is_platform_role true');
SELECT pg_temp.t(NOT is_platform_role(ARRAY['support','content_author']),
    'platform: is_platform_role false for unheld roles');
SELECT pg_temp.t((SELECT count(*) FROM allowed_client_orgs()) = 0,
    'platform: allowed_client_orgs empty (tenant isolation)');
SELECT pg_temp.t((SELECT count(*) FROM client_orgs) = 0
    AND (SELECT count(*) FROM practices) = 0,
    'platform: no practices/clients visible');
SELECT pg_temp.t((SELECT count(*) FROM memberships) = 0,
    'platform: memberships view empty');
ROLLBACK;

-- ---------- write paths ----------
BEGIN;
SET ROLE authenticated;
-- owner adds a read_only member via RPC → role_assignments row, viewable in memberships
SET request.jwt.claims = '{"sub":"aa000000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT add_member('aa000000-0000-0000-0000-000000000005','read_only');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM memberships
      WHERE user_id='aa000000-0000-0000-0000-000000000005' AND role='read_only'),
    'add_member(read_only): memberships view shows new member');
SELECT pg_temp.t(practice_seats_used('bb000000-0000-0000-0000-00000000000a') = 2,
    'practice_seats_used counts consultant + read_only (2)');
DO $$
BEGIN
  BEGIN
    PERFORM create_practice('W0RA dup');
    PERFORM pg_temp.t(false, 'member blocked from create_practice');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'member blocked from create_practice');
  END;
  BEGIN
    PERFORM add_member('aa000000-0000-0000-0000-000000000006','client_admin',
                       'cc000000-0000-0000-0000-00000000000c');
    PERFORM pg_temp.t(false, 'cross-partner add_member blocked');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'cross-partner add_member blocked');
  END;
END $$;
ROLLBACK;

-- member (non-admin) cannot create a second practice / add members
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM create_practice('W0RA dup2');
    PERFORM pg_temp.t(false, 'consultant blocked from create_practice');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'consultant blocked from create_practice');
  END;
  BEGIN
    PERFORM add_member('aa000000-0000-0000-0000-000000000005','practice_consultant');
    PERFORM pg_temp.t(false, 'consultant blocked from add_member');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, 'consultant blocked from add_member');
  END;
END $$;
ROLLBACK;

-- ---------- legacy ca mirror DELETE ----------
DELETE FROM consultant_assignments
WHERE user_id='aa000000-0000-0000-0000-000000000002'
  AND client_org_id='cc000000-0000-0000-0000-00000000000b';
SELECT pg_temp.t(NOT EXISTS (
    SELECT 1 FROM role_assignments
    WHERE user_id='aa000000-0000-0000-0000-000000000002'
      AND scope_id='cc000000-0000-0000-0000-00000000000b' AND origin='legacy_sync'),
  'mirror trigger: ca DELETE removes the synced row');

-- ---------- unique-active guard ----------
DO $$
BEGIN
  BEGIN
    INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id)
    VALUES ('aa000000-0000-0000-0000-000000000001','partner','partner_admin','partner',
            'bb000000-0000-0000-0000-00000000000a');
    PERFORM pg_temp.t(false, 'duplicate active assignment rejected');
  EXCEPTION WHEN unique_violation THEN
    PERFORM pg_temp.t(true, 'duplicate active assignment rejected');
  END;
END $$;

-- ---------- teardown ----------
DELETE FROM consultant_assignments WHERE user_id IN
  (SELECT id FROM users WHERE email LIKE '%@w0ra.test');
DELETE FROM role_assignments WHERE user_id IN
  (SELECT id FROM users WHERE email LIKE '%@w0ra.test');
DELETE FROM users WHERE email LIKE '%@w0ra.test';
DELETE FROM auth.users WHERE email LIKE '%@w0ra.test';
DELETE FROM client_orgs WHERE practice_id IN (SELECT id FROM practices WHERE name LIKE 'W0RA%');
DELETE FROM practices WHERE name LIKE 'W0RA%';
\echo '=== e2e_role_assignments checks done ==='
