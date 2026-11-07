-- ============================================================================
-- W4-05 data-region plumbing — psql acceptance checks for
-- 20261106000020_data_regions.sql (NFR-11, issue #52):
--   data_regions registry (ZA→af-south-1, UK→eu-west-2) · FK'd region
--   columns · INSERT/UPDATE guard (immutable once programme data exists) ·
--   create_client_org +p_data_region / create_practice +p_home_region /
--   platform partner RPCs registry-validated · partner_branding /
--   programme_context / platform_list_clients surface the region LABEL.
--
-- Self-contained (e2e_platform_admin.sql style): builds its own @w405.test
-- users + 'W405%' partners; never touches the TESTFIX world. JWT callers
-- simulated via SET ROLE authenticated + request.jwt.claims inside
-- BEGIN … ROLLBACK blocks; assertions that need table reads switch back
-- with RESET ROLE inside the same transaction.
--
-- Scratch runs: same auth shim as e2e_template_engine.sql (newer auth.users
-- columns + coalesced auth.uid()) on a bare supabase/postgres.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_data_regions.sql
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
CREATE OR REPLACE FUNCTION pg_temp.w405_wipe() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.invites   WHERE practice_id IN (SELECT id FROM public.practices WHERE name LIKE 'W405%');
  DELETE FROM public.programmes WHERE client_org_id IN (SELECT id FROM public.client_orgs WHERE practice_id IN (SELECT id FROM public.practices WHERE name LIKE 'W405%'));
  DELETE FROM public.role_assignments WHERE user_id IN (SELECT id FROM public.users WHERE email LIKE '%@w405.test');
  DELETE FROM public.client_orgs WHERE practice_id IN (SELECT id FROM public.practices WHERE name LIKE 'W405%');
  DELETE FROM public.practices  WHERE name LIKE 'W405%';
  DELETE FROM public.users      WHERE email LIKE '%@w405.test';
  DELETE FROM auth.users        WHERE email LIKE '%@w405.test';
END $$;
SELECT pg_temp.w405_wipe();

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
  ('a4050000-0000-0000-0000-000000000001'::uuid, 'padmin@w405.test'),
  ('a4050000-0000-0000-0000-000000000002'::uuid, 'ownera@w405.test'),
  ('a4050000-0000-0000-0000-000000000003'::uuid, 'ownerb@w405.test'),
  ('a4050000-0000-0000-0000-000000000004'::uuid, 'clientu@w405.test'),
  ('a4050000-0000-0000-0000-000000000005'::uuid, 'nobody@w405.test')
) AS u(id, email);
INSERT INTO public.users (id, email)
  SELECT id, email FROM auth.users WHERE email LIKE '%@w405.test';

-- Alpha: home region ZA.  Beta: NO home region (fail-closed probe).
INSERT INTO public.practices (id, name, type, country, data_region_default) VALUES
  ('b4050000-0000-0000-0000-000000000001', 'W405 Alpha', 'msp', 'ZA', 'ZA'),
  ('b4050000-0000-0000-0000-000000000002', 'W405 Beta',  'msp', 'UK', NULL);
-- A1: shell client (no programme data — region still correctable).
-- A2: client WITH a programme (region locked).
INSERT INTO public.client_orgs (id, practice_id, name, data_region) VALUES
  ('c4050000-0000-0000-0000-000000000001', 'b4050000-0000-0000-0000-000000000001', 'W405 Client A1', 'ZA'),
  ('c4050000-0000-0000-0000-000000000002', 'b4050000-0000-0000-0000-000000000001', 'W405 Client A2', 'UK');
INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d4050000-0000-0000-0000-000000000001', 'c4050000-0000-0000-0000-000000000002',
   'W405 Programme', DATE '2026-11-02', 10);   -- Monday, per programmes CHECK

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a4050000-0000-0000-0000-000000000001','platform','platform_admin','partner',NULL),
  ('a4050000-0000-0000-0000-000000000002','partner','partner_admin','partner','b4050000-0000-0000-0000-000000000001'),
  ('a4050000-0000-0000-0000-000000000003','partner','partner_admin','partner','b4050000-0000-0000-0000-000000000002'),
  ('a4050000-0000-0000-0000-000000000004','client','client_admin','client','c4050000-0000-0000-0000-000000000001');

-- ---------- 1. registry ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
    (SELECT count(*) FROM public.data_regions
      WHERE (code, label, deployment_region, active) IN
            (('ZA','South Africa','af-south-1',true),
             ('UK','United Kingdom','eu-west-2',true))) = 2,
    '01 registry seeded: ZA→af-south-1, UK→eu-west-2, readable by any tenant user');
DO $$
DECLARE n int := 0;
BEGIN
  BEGIN INSERT INTO public.data_regions VALUES ('XX','Nowhere','xx-1',true);
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN UPDATE public.data_regions SET label = 'x' WHERE code = 'ZA';
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN DELETE FROM public.data_regions WHERE code = 'UK';
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  PERFORM pg_temp.t(n = 3, '02 tenant user cannot write the registry (labels are ops-owned)');
END $$;
RESET ROLE;
ROLLBACK;

-- ---------- 2. create_client_org: explicit / default / fail-closed ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000002","role":"authenticated"}';
CREATE TEMP TABLE w405_c1 ON COMMIT DROP AS
  SELECT public.create_client_org('W405 New Explicit', NULL, NULL, NULL, NULL, 'sme', 'uk') AS cid;
CREATE TEMP TABLE w405_c2 ON COMMIT DROP AS
  SELECT public.create_client_org('W405 New Default') AS cid;
RESET ROLE;
SELECT pg_temp.t((SELECT data_region FROM public.client_orgs WHERE id = (SELECT cid FROM w405_c1)) = 'UK',
    '03 create_client_org: explicit p_data_region honoured (case-normalised)');
SELECT pg_temp.t((SELECT data_region FROM public.client_orgs WHERE id = (SELECT cid FROM w405_c2)) = 'ZA',
    '04 create_client_org: no param → practice home region default');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.audit_log a
                          JOIN w405_c1 ON a.practice_id = 'b4050000-0000-0000-0000-000000000001'
                          WHERE a.action = 'client_org.created'
                            AND a.detail->>'data_region' = 'UK'
                            AND a.detail->>'client_org' = (SELECT cid::text FROM w405_c1)),
    '05 client_org.created audit row carries the resolved region');
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.create_client_org('W405 Bad Region', NULL, NULL, NULL, NULL, 'large', 'MARS');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%unknown data region%'; END;
  PERFORM pg_temp.t(ok, '06 create_client_org: unknown region fails closed');
END $$;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE ok_noreg boolean := false; ok_expl boolean := false; cid uuid;
BEGIN
  BEGIN PERFORM public.create_client_org('W405 No Region');
  EXCEPTION WHEN OTHERS THEN ok_noreg := SQLERRM LIKE '%no data region%'; END;
  PERFORM pg_temp.t(ok_noreg, '07 partner with no home region + no param → fails closed');
  cid := public.create_client_org('W405 Beta Explicit', NULL, NULL, NULL, NULL, 'large', 'UK');
  ok_expl := (SELECT data_region FROM public.client_orgs WHERE id = cid) = 'UK';
  PERFORM pg_temp.t(ok_expl, '08 …but explicit p_data_region still works');
END $$;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.create_client_org('W405 By Client', NULL, NULL, NULL, NULL, 'large', 'UK');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%only practice owners%'; END;
  PERFORM pg_temp.t(ok, '09 client-scope role cannot create client orgs at all');
END $$;
SET request.jwt.claims = '{}';
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.create_client_org('W405 Anon Call', NULL, NULL, NULL, NULL, 'large', 'UK');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%only practice owners%'; END;
  PERFORM pg_temp.t(ok, '10 no JWT identity → create_client_org denied');
END $$;
RESET ROLE;
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.client_orgs
                              WHERE name IN ('W405 Bad Region','W405 No Region','W405 By Client','W405 Anon Call')),
    '11 every rejected create wrote nothing');
ROLLBACK;

-- ---------- 3. immutability: shell can move; client with data is locked ----
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000002","role":"authenticated"}';
-- shell client: direct UPDATE allowed (owner write policy) — incl. NULL and back
UPDATE public.client_orgs SET data_region = 'UK'  WHERE id = 'c4050000-0000-0000-0000-000000000001';
UPDATE public.client_orgs SET data_region = NULL  WHERE id = 'c4050000-0000-0000-0000-000000000001';
UPDATE public.client_orgs SET data_region = 'ZA'  WHERE id = 'c4050000-0000-0000-0000-000000000001';
SELECT pg_temp.t((SELECT data_region FROM public.client_orgs WHERE id = 'c4050000-0000-0000-0000-000000000001') = 'ZA',
    '12 shell client (tracks only, no programme data): region still correctable');
DO $$
DECLARE n int := 0;
BEGIN
  BEGIN UPDATE public.client_orgs SET data_region = 'MARS' WHERE id = 'c4050000-0000-0000-0000-000000000001';
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN INSERT INTO public.client_orgs (practice_id, name, data_region)
        VALUES ('b4050000-0000-0000-0000-000000000001','W405 Bad Ins','XX');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  PERFORM pg_temp.t(n = 2 AND
    (SELECT data_region FROM public.client_orgs WHERE id = 'c4050000-0000-0000-0000-000000000001') = 'ZA' AND
    NOT EXISTS (SELECT 1 FROM public.client_orgs WHERE name = 'W405 Bad Ins'),
    '13 unknown region rejected on direct UPDATE and direct INSERT');
END $$;
-- locked client: every flavour of region change is refused — including the
-- tenant-owner path AND a same-as-NULL clear
DO $$
DECLARE n int := 0;
BEGIN
  BEGIN UPDATE public.client_orgs SET data_region = 'ZA' WHERE id = 'c4050000-0000-0000-0000-000000000002';
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN UPDATE public.client_orgs SET data_region = NULL WHERE id = 'c4050000-0000-0000-0000-000000000002';
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  PERFORM pg_temp.t(n = 2, '14 client with programme data: owner region change + clear both rejected');
END $$;
UPDATE public.client_orgs SET name = 'W405 Client A2 (renamed)' WHERE id = 'c4050000-0000-0000-0000-000000000002';
RESET ROLE;
SELECT pg_temp.t((SELECT data_region FROM public.client_orgs WHERE id = 'c4050000-0000-0000-0000-000000000002') = 'UK'
    AND (SELECT name FROM public.client_orgs WHERE id = 'c4050000-0000-0000-0000-000000000002') = 'W405 Client A2 (renamed)',
    '15 lock is surgical: region held, ordinary column update still allowed');
-- admin is no exception — a region move is a migration, not a flag flip
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN UPDATE public.client_orgs SET data_region = 'ZA' WHERE id = 'c4050000-0000-0000-0000-000000000002';
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%locked%'; END;
  PERFORM pg_temp.t(ok AND
    (SELECT data_region FROM public.client_orgs WHERE id = 'c4050000-0000-0000-0000-000000000002') = 'UK',
    '16 supabase_admin cannot flag-flip the region either');
END $$;
ROLLBACK;

-- ---------- 4. onboarding RPCs: platform_create_partner / update / create_practice ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.platform_create_partner('W405 BadReg', 'msp', 'ZA', NULL, NULL, 'MARS');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%unknown data region%'; END;
  PERFORM pg_temp.t(ok, '17 platform_create_partner: unknown home region fails closed');
END $$;
CREATE TEMP TABLE w405_p ON COMMIT DROP AS
  SELECT public.platform_create_partner('W405 Gamma', 'reseller', 'gb', NULL, NULL, 'uk') AS r;
RESET ROLE;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM w405_p n JOIN public.practices p
                           ON p.id = (n.r->>'partner_id')::uuid
                          WHERE p.data_region_default = 'UK' AND p.country = 'GB'),
    '18 platform_create_partner: home region normalised + stored');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM w405_p n JOIN public.audit_log a
                           ON a.practice_id = (n.r->>'partner_id')::uuid
                          WHERE a.action = 'partner.created'
                            AND a.detail->>'data_region_default' = 'UK'),
    '19 partner.created audit row carries the home region');
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.platform_update_partner('b4050000-0000-0000-0000-000000000002',
                                               '{"data_region_default":"ZZ"}');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%unknown data region%'; END;
  PERFORM pg_temp.t(ok, '20 platform_update_partner: unknown home region rejected');
END $$;
SELECT public.platform_update_partner('b4050000-0000-0000-0000-000000000002',
                                      '{"data_region_default":"uk"}');
RESET ROLE;
SELECT pg_temp.t((SELECT data_region_default FROM public.practices
                   WHERE id = 'b4050000-0000-0000-0000-000000000002') = 'UK',
    '21 platform_update_partner: valid home region set (normalised)');
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
DECLARE ok boolean := false; pid uuid;
BEGIN
  BEGIN PERFORM public.create_practice('W405 Self Bad', 'ZZ');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%unknown data region%'; END;
  pid := public.create_practice('W405 Self Serve', 'uk');
  ok := ok AND (SELECT data_region_default FROM public.practices WHERE id = pid) = 'UK';
  PERFORM pg_temp.t(ok, '22 create_practice: home region validated + stored, unknown rejected');
END $$;
RESET ROLE;
ROLLBACK;

-- ---------- 5. reads: region surfaced as a label ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t((SELECT partner_branding->>'data_region' FROM (
                    SELECT public.partner_branding('c4050000-0000-0000-0000-000000000001') AS partner_branding) s)
                 = 'ZA'
    AND (SELECT partner_branding->>'data_region_label' FROM (
                    SELECT public.partner_branding('c4050000-0000-0000-0000-000000000001') AS partner_branding) s)
                 = 'South Africa'
    AND (SELECT partner_branding->>'data_region_deployment' FROM (
                    SELECT public.partner_branding('c4050000-0000-0000-0000-000000000001') AS partner_branding) s)
                 = 'af-south-1',
    '23 partner_branding: client region code + label + deployment exposed');
SELECT pg_temp.t((SELECT pc->'client'->>'data_region' FROM (
                    SELECT public.programme_context('d4050000-0000-0000-0000-000000000001') AS pc) s) = 'UK'
    AND (SELECT pc->'client'->>'data_region_label' FROM (
                    SELECT public.programme_context('d4050000-0000-0000-0000-000000000001') AS pc) s) = 'United Kingdom',
    '24 programme_context: owning-client region label in the shell slice');
RESET ROLE;
ROLLBACK;

-- cross-region = label only: a ZA-partner caller can READ that a client lives
-- in the UK deploy, but the platform RPC surface offers no data movement.
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t((SELECT partner_branding->>'data_region' FROM (
                    SELECT public.partner_branding('c4050000-0000-0000-0000-000000000002') AS partner_branding) s) = 'UK'
    AND (SELECT label FROM public.data_regions WHERE code = 'UK') = 'United Kingdom',
    '25 cross-region value is a label: UK deploy visible as metadata only');
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                              WHERE n.nspname = 'public'
                                AND p.proname ~* 'region.*(migrat|move|transfer|copy|sync|replicat)'),
    '26 no RPC exists that moves/copies/replicates client data across regions');
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t((SELECT data_region FROM public.platform_list_clients(
                    'b4050000-0000-0000-0000-000000000001')
                   WHERE client_org_id = 'c4050000-0000-0000-0000-000000000002') = 'UK',
    '27 platform_list_clients: region label for deploy routing');
RESET ROLE;
ROLLBACK;

-- ---------- 6. foreign-tenant writes denied ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4050000-0000-0000-0000-000000000003","role":"authenticated"}';
-- ownerb is Alpha-foreign: the shell client row is invisible to him — UPDATE
-- silently hits 0 rows under RLS, and the read paths return nothing.
DO $$
DECLARE n int;
BEGIN
  UPDATE public.client_orgs SET data_region = 'UK' WHERE id = 'c4050000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.t(n = 0, '28a foreign partner UPDATE cannot reach Alpha''s client row');
END $$;
SELECT pg_temp.t(public.partner_branding('c4050000-0000-0000-0000-000000000001') IS NULL,
    '28b …and partner_branding refuses him the region label too');
RESET ROLE;
SELECT pg_temp.t((SELECT data_region FROM public.client_orgs WHERE id = 'c4050000-0000-0000-0000-000000000001') = 'ZA',
    '28c foreign-tenant write attempts left the region untouched');
ROLLBACK;

-- ---------- teardown ----------
SELECT pg_temp.w405_wipe();
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.practices WHERE name LIKE 'W405%')
    AND NOT EXISTS (SELECT 1 FROM public.users WHERE email LIKE '%@w405.test'),
    '29 W405 namespace wiped');
