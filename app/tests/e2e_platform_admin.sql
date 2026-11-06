-- ============================================================================
-- W2-14 platform admin — psql acceptance checks for
-- 20261106000015_platform_admin.sql (platform_create_partner,
-- platform_update_partner, platform_set_partner_status,
-- platform_list_partners, platform_list_clients, platform_metrics).
--
-- Self-contained (e2e_role_assignments.sql style): builds its own @w214.test
-- users, 'W214%' partners, clients, a programme, an evidence item and a
-- register item carrying a SECRET marker; never touches the TESTFIX world.
-- JWT callers simulated via SET ROLE authenticated + request.jwt.claims
-- inside BEGIN … ROLLBACK blocks; assertions that need table reads switch
-- back with RESET ROLE inside the same transaction.
--
-- Covers: non-platform callers denied on every RPC; support read-only;
-- subdomain format / reserved / clash rejection; allowlisted update;
-- audited status transitions (suspend / reactivate / close, closed
-- terminal, reason required); counts match the §9.8 counter; metrics
-- totals; first partner_admin invite redeemed via the existing
-- accept_invite(); NFR-04 — platform_admin gets NO tenant content
-- (evidence, register text) through these RPCs; the recreated
-- create_invite allowlist (no practice_owner co-owner escalation, every
-- legacy role + seat cap / practice scope still intact); and §4.1 — support
-- gets no licence fields from list_partners / metrics.
--
-- Scratch runs: same auth shim as e2e_template_engine.sql (newer auth.users
-- columns + coalesced auth.uid()) on a bare supabase/postgres.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_platform_admin.sql
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
CREATE OR REPLACE FUNCTION pg_temp.w214_wipe() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.invites       WHERE practice_id IN (SELECT id FROM public.practices WHERE name LIKE 'W214%');
  DELETE FROM public.role_assignments WHERE user_id IN (SELECT id FROM public.users WHERE email LIKE '%@w214.test');
  DELETE FROM public.client_orgs   WHERE practice_id IN (SELECT id FROM public.practices WHERE name LIKE 'W214%');
  DELETE FROM public.practices     WHERE name LIKE 'W214%';
  DELETE FROM public.users         WHERE email LIKE '%@w214.test';
  DELETE FROM auth.users           WHERE email LIKE '%@w214.test';
END $$;
SELECT pg_temp.w214_wipe();

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
  ('a2140000-0000-0000-0000-000000000001'::uuid, 'padmin@w214.test'),
  ('a2140000-0000-0000-0000-000000000002'::uuid, 'support@w214.test'),
  ('a2140000-0000-0000-0000-000000000003'::uuid, 'author@w214.test'),
  ('a2140000-0000-0000-0000-000000000004'::uuid, 'partneradmin@w214.test'),
  ('a2140000-0000-0000-0000-000000000005'::uuid, 'ao@w214.test'),
  ('a2140000-0000-0000-0000-000000000006'::uuid, 'newadmin@w214.test')
) AS u(id, email);
INSERT INTO public.users (id, email)
  SELECT id, email FROM auth.users WHERE email LIKE '%@w214.test';

INSERT INTO public.practices (id, name, type, country, subdomain) VALUES
  ('b2140000-0000-0000-0000-000000000001', 'W214 Alpha', 'msp', 'ZA', 'w214-alpha'),
  ('b2140000-0000-0000-0000-000000000002', 'W214 Beta',  'reseller', 'UK', NULL);
INSERT INTO public.client_orgs (id, practice_id, name) VALUES
  ('c2140000-0000-0000-0000-000000000001', 'b2140000-0000-0000-0000-000000000001', 'W214 Client A1'),
  ('c2140000-0000-0000-0000-000000000002', 'b2140000-0000-0000-0000-000000000001', 'W214 Client A2');
INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d2140000-0000-0000-0000-000000000001', 'c2140000-0000-0000-0000-000000000001',
   'W214 SECRET-PROGRAMME-NAME', DATE '2026-11-02', 10);
INSERT INTO public.register_items (programme_id, ref, finding) VALUES
  ('d2140000-0000-0000-0000-000000000001', 'W214-R1', 'W214-SECRET-REGISTER-TEXT finding');
INSERT INTO public.evidence_items (programme_id, link, uploaded_by) VALUES
  ('d2140000-0000-0000-0000-000000000001', 'https://w214-secret-evidence.example/doc',
   'a2140000-0000-0000-0000-000000000004');

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a2140000-0000-0000-0000-000000000001','platform','platform_admin','partner',NULL),
  ('a2140000-0000-0000-0000-000000000002','platform','support','partner',NULL),
  ('a2140000-0000-0000-0000-000000000003','platform','content_author','partner',NULL),
  ('a2140000-0000-0000-0000-000000000004','partner','partner_admin','partner','b2140000-0000-0000-0000-000000000001'),
  ('a2140000-0000-0000-0000-000000000005','client','accountable_officer','client','c2140000-0000-0000-0000-000000000001');

-- denial probe: run every platform RPC as the current JWT; count refusals
CREATE OR REPLACE FUNCTION pg_temp.w214_denials() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE n int := 0;
BEGIN
  BEGIN PERFORM public.platform_create_partner('W214 Probe', 'msp', 'ZA');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM public.platform_update_partner('b2140000-0000-0000-0000-000000000001', '{"name":"W214 X"}');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM public.platform_set_partner_status('b2140000-0000-0000-0000-000000000001', 'suspended', 'probe');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM * FROM public.platform_list_partners('{}');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM * FROM public.platform_list_clients(NULL);
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM public.platform_metrics();
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  RETURN n;
END $$;

-- ---------- 1. non-platform callers denied on every RPC ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w214_denials() = 6, '01 partner_admin denied on all 6 platform RPCs');
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w214_denials() = 6, '02 client accountable_officer denied on all 6 platform RPCs');
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w214_denials() = 6, '03 content_author (platform, not admin/support) denied on all 6');
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w214_denials() = 6, '04 user with no assignment denied on all 6');
RESET ROLE;
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.practices WHERE name = 'W214 Probe')
    AND (SELECT status FROM public.practices WHERE id = 'b2140000-0000-0000-0000-000000000001') = 'active'
    AND (SELECT name FROM public.practices WHERE id = 'b2140000-0000-0000-0000-000000000001') = 'W214 Alpha',
    '05 denied calls wrote nothing');
ROLLBACK;

-- anon has no EXECUTE at all
BEGIN;
SET ROLE anon;
DO $$
BEGIN
  PERFORM public.platform_metrics();
  PERFORM pg_temp.t(false, '06 anon cannot execute platform_metrics');
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM pg_temp.t(true, '06 anon cannot execute platform_metrics');
END $$;
ROLLBACK;

-- ---------- 2. support role is read-only ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
    (SELECT count(*) FROM public.platform_list_partners('{"q":"W214"}')) = 2
    AND (SELECT count(*) FROM public.platform_list_clients('b2140000-0000-0000-0000-000000000001')) = 2
    AND public.platform_metrics() ? 'partners',
    '07 support can read list_partners / list_clients / metrics');
DO $$
DECLARE n int := 0;
BEGIN
  BEGIN PERFORM public.platform_create_partner('W214 BySupport', 'msp', 'ZA');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM public.platform_update_partner('b2140000-0000-0000-0000-000000000001', '{"name":"W214 X"}');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM public.platform_set_partner_status('b2140000-0000-0000-0000-000000000001', 'suspended', 'support probe');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM public.issue_licence('b2140000-0000-0000-0000-000000000001', '{"plan":"W214"}');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  PERFORM pg_temp.t(n = 4, '08 support denied create / update / set_status / issue_licence');
END $$;
RESET ROLE;
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.practices WHERE name LIKE 'W214 BySupport%')
    AND NOT EXISTS (SELECT 1 FROM public.audit_log
                    WHERE practice_id = 'b2140000-0000-0000-0000-000000000001'
                      AND action LIKE 'partner.%'),
    '09 support writes left no rows and no audit');
ROLLBACK;

-- ---------- 3. create partner + first partner_admin invite ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000001","role":"authenticated"}';
CREATE TEMP TABLE w214_new ON COMMIT DROP AS
  SELECT public.platform_create_partner('W214 Gamma', 'securepath_direct', 'za', 'W214-Gamma',
                                        'Jane <jane@gamma.test>', 'za', 'NewAdmin@W214.test') AS r;
RESET ROLE;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM w214_new n JOIN public.practices p ON p.id = (n.r->>'partner_id')::uuid
                          WHERE p.name = 'W214 Gamma' AND p.type = 'securepath_direct'
                            AND p.country = 'ZA' AND p.subdomain = 'w214-gamma'
                            AND p.data_region_default = 'ZA' AND p.status = 'active'),
    '10 create: practice row with normalised country / subdomain / region');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM w214_new n JOIN public.invites i ON i.token = (n.r->>'invite_token')::uuid
                          WHERE i.practice_id = (n.r->>'partner_id')::uuid
                            AND i.role = 'practice_owner' AND i.email = 'newadmin@w214.test'
                            AND i.invited_by = 'a2140000-0000-0000-0000-000000000001'),
    '11 create: practice_owner invite on the existing invites table');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM w214_new n JOIN public.audit_log a
                           ON a.practice_id = (n.r->>'partner_id')::uuid
                          WHERE a.action = 'partner.created'
                            AND a.user_id = 'a2140000-0000-0000-0000-000000000001')
    AND EXISTS (SELECT 1 FROM w214_new n JOIN public.audit_log a
                  ON a.practice_id = (n.r->>'partner_id')::uuid
                 WHERE a.action = 'invite.created'),
    '12 create: partner.created + invite.created audited');
-- invitee redeems through the unchanged accept_invite → partner_admin
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT public.accept_invite((SELECT (r->>'invite_token')::uuid FROM w214_new));
SELECT pg_temp.t(public.has_partner_role((SELECT (r->>'partner_id')::uuid FROM w214_new), ARRAY['partner_admin']),
    '13 invitee accept_invite → partner_admin on the new partner');
ROLLBACK;

-- ---------- 4. validation: subdomain clash / format / reserved, type ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE ok_clash boolean := false; ok_fmt boolean := false; ok_res boolean := false;
        ok_type boolean := false; ok_upd boolean := false;
BEGIN
  BEGIN PERFORM public.platform_create_partner('W214 Clash', 'msp', 'ZA', 'W214-ALPHA');
  EXCEPTION WHEN OTHERS THEN ok_clash := SQLERRM LIKE '%already taken%'; END;
  PERFORM pg_temp.t(ok_clash, '14 subdomain clash (case-insensitive) rejected on create');
  BEGIN PERFORM public.platform_create_partner('W214 Bad', 'msp', 'ZA', '-bad_sub-');
  EXCEPTION WHEN OTHERS THEN ok_fmt := SQLERRM LIKE '%invalid%'; END;
  BEGIN PERFORM public.platform_create_partner('W214 Res', 'msp', 'ZA', 'admin');
  EXCEPTION WHEN OTHERS THEN ok_res := SQLERRM LIKE '%reserved%'; END;
  PERFORM pg_temp.t(ok_fmt AND ok_res, '15 malformed and reserved subdomains rejected');
  BEGIN PERFORM public.platform_create_partner('W214 Type', 'franchise', 'ZA');
  EXCEPTION WHEN OTHERS THEN ok_type := true; END;
  PERFORM pg_temp.t(ok_type, '16 unknown partner type rejected');
  BEGIN PERFORM public.platform_update_partner('b2140000-0000-0000-0000-000000000002',
                                               '{"subdomain":"w214-alpha"}');
  EXCEPTION WHEN OTHERS THEN ok_upd := SQLERRM LIKE '%already taken%'; END;
  PERFORM pg_temp.t(ok_upd, '17 subdomain clash rejected on update');
END $$;
RESET ROLE;
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.practices
                              WHERE name IN ('W214 Clash','W214 Bad','W214 Res','W214 Type'))
    AND (SELECT subdomain FROM public.practices WHERE id = 'b2140000-0000-0000-0000-000000000002') IS NULL,
    '18 rejected validations wrote nothing');
ROLLBACK;

-- ---------- 5. update: allowlist + audit ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.platform_update_partner('b2140000-0000-0000-0000-000000000002',
  '{"name":"W214 Beta Renamed","subdomain":"W214-Beta","support_contact":"help@beta.test","primary_contact":""}');
DO $$
DECLARE n int := 0;
BEGIN
  BEGIN PERFORM public.platform_update_partner('b2140000-0000-0000-0000-000000000002', '{"logo_url":"x"}');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM public.platform_update_partner('b2140000-0000-0000-0000-000000000002', '{"status":"closed"}');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  BEGIN PERFORM public.platform_update_partner('b2140000-0000-0000-0000-000000000002', '{}');
  EXCEPTION WHEN OTHERS THEN n := n + 1; END;
  PERFORM pg_temp.t(n = 3, '19 update rejects branding / status / empty payloads (allowlist)');
END $$;
RESET ROLE;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.practices
                          WHERE id = 'b2140000-0000-0000-0000-000000000002'
                            AND name = 'W214 Beta Renamed' AND subdomain = 'w214-beta'
                            AND support_contact = 'help@beta.test' AND primary_contact IS NULL
                            AND status = 'active' AND logo_url IS NULL),
    '20 update wrote the allowlisted fields only');
SELECT pg_temp.t((SELECT count(*) FROM public.audit_log
                   WHERE practice_id = 'b2140000-0000-0000-0000-000000000002'
                     AND action = 'partner.updated'
                     AND detail->'previous'->>'name' = 'W214 Beta') = 1,
    '21 update audited once with previous values');
ROLLBACK;

-- ---------- 6. status changes are audited; closed is terminal ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.platform_set_partner_status('b2140000-0000-0000-0000-000000000001', 'suspended', '  ');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%reason%'; END;
  PERFORM pg_temp.t(ok, '22 status change without a reason rejected');
END $$;
SELECT public.platform_set_partner_status('b2140000-0000-0000-0000-000000000001', 'suspended', 'W214 unpaid invoice');
SELECT public.platform_set_partner_status('b2140000-0000-0000-0000-000000000001', 'active', 'W214 paid');
SELECT public.platform_set_partner_status('b2140000-0000-0000-0000-000000000001', 'closed', 'W214 contract ended');
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.platform_set_partner_status('b2140000-0000-0000-0000-000000000001', 'active', 'reopen');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%cannot be reopened%'; END;
  PERFORM pg_temp.t(ok, '23 closed partner cannot be reopened');
END $$;
SELECT pg_temp.t((SELECT count(*) FROM public.platform_list_partners('{"status":"closed","q":"W214"}')) = 1
    AND (SELECT status_reason FROM public.platform_list_partners('{"id":"b2140000-0000-0000-0000-000000000001"}'))
        = 'W214 contract ended',
    '24 list_partners status filter + recorded reason');
RESET ROLE;
SELECT pg_temp.t(
    (SELECT string_agg(detail->>'transition' || ':' || (detail->>'reason'), ',' ORDER BY id)
       FROM public.audit_log
      WHERE practice_id = 'b2140000-0000-0000-0000-000000000001'
        AND action = 'partner.status_changed'
        AND user_id = 'a2140000-0000-0000-0000-000000000001')
    = 'suspend:W214 unpaid invoice,reactivate:W214 paid,close:W214 contract ended',
    '25 suspend / reactivate / close each audited with actor + reason');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.client_orgs
                          WHERE practice_id = 'b2140000-0000-0000-0000-000000000001')
    AND EXISTS (SELECT 1 FROM public.evidence_items
                 WHERE programme_id = 'd2140000-0000-0000-0000-000000000001'),
    '26 closing a partner deletes no client data (FR-PLT-06)');
ROLLBACK;

-- ---------- 7. list counts reuse the §9.8 counter; metrics totals ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.platform_list_partners('{"id":"b2140000-0000-0000-0000-000000000001"}') l,
                  public.partner_licence_usage('b2140000-0000-0000-0000-000000000001') u
     WHERE l.clients_total = 2 AND l.clients_used = u.clients_used AND l.clients_used = 1
       AND l.programmes_used = u.programmes_used AND l.programmes_used = 1
       AND l.seats_used = 0 AND l.licence_id IS NULL),
    '27 list_partners counts equal partner_licence_usage (2 clients, 1 in use, 1 programme)');
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM * FROM public.platform_list_partners('{"colour":"red"}');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%unknown filter%'; END;
  PERFORM pg_temp.t(ok, '28 list_partners rejects unknown filter keys');
END $$;
CREATE TEMP TABLE w214_m ON COMMIT DROP AS SELECT public.platform_metrics() AS m;
RESET ROLE;
SELECT pg_temp.t(
    (SELECT (m->'partners'->>'total')::int FROM w214_m) = (SELECT count(*) FROM public.practices)
    AND (SELECT (m->'clients'->>'total')::int FROM w214_m) = (SELECT count(*) FROM public.client_orgs)
    AND (SELECT (m->'programmes'->>'total')::int FROM w214_m) = (SELECT count(*) FROM public.programmes)
    AND (SELECT (m->'evidence_awaiting'->>'total')::int FROM w214_m)
        = (SELECT count(*) FROM public.evidence_items WHERE review_stage IN ('verification','acceptance'))
    AND (SELECT (m->>'active_users')::int FROM w214_m)
        = (SELECT count(DISTINCT user_id) FROM public.role_assignments
            WHERE level IN ('partner','client') AND start_date <= CURRENT_DATE
              AND (end_date IS NULL OR end_date > CURRENT_DATE)),
    '29 platform_metrics totals match the tables');
ROLLBACK;

-- ---------- 8. NFR-04: platform_admin gets no tenant content ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000001","role":"authenticated"}';
CREATE TEMP TABLE w214_dump ON COMMIT DROP AS
  SELECT (SELECT COALESCE(string_agg(to_jsonb(l)::text, ' '), '') FROM public.platform_list_partners('{}') l)
      || (SELECT COALESCE(string_agg(to_jsonb(c)::text, ' '), '') FROM public.platform_list_clients(NULL) c)
      || public.platform_metrics()::text AS blob;
SELECT pg_temp.t((SELECT blob FROM w214_dump) LIKE '%W214 Alpha%',
    '30 dump sanity: partner metadata present');
SELECT pg_temp.t((SELECT blob FROM w214_dump) NOT ILIKE '%w214-secret-evidence%'
    AND (SELECT blob FROM w214_dump) NOT ILIKE '%SECRET-REGISTER-TEXT%'
    AND (SELECT blob FROM w214_dump) NOT ILIKE '%SECRET-PROGRAMME-NAME%',
    '31 no evidence link, register text or programme name in any RPC output');
SELECT pg_temp.t((SELECT count(*) FROM public.evidence_items) = 0
    AND (SELECT count(*) FROM public.register_items) = 0
    AND (SELECT count(*) FROM public.client_orgs) = 0,
    '32 platform_admin still sees no tenant rows directly after the calls (RLS)');
ROLLBACK;

-- ---------- 9. create_invite allowlist (review fix: no owner escalation) ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM public.create_invite('coowner@w214.test', 'practice_owner');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%invalid invite role%'; END;
  PERFORM pg_temp.t(ok, '33 practice owner create_invite(..., practice_owner) rejected');
  ok := false;
  BEGIN PERFORM public.create_invite('x@w214.test', 'partner_admin');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%invalid invite role%'; END;
  PERFORM pg_temp.t(ok, '34 create_invite rejects non-allowlisted roles (partner_admin)');
END $$;
SELECT pg_temp.t(
    public.create_invite('Cons@W214.test', 'practice_consultant') IS NOT NULL
    AND public.create_invite('ro@w214.test', 'read_only') IS NOT NULL
    AND public.create_invite('cadmin@w214.test', 'client_admin', 'c2140000-0000-0000-0000-000000000001') IS NOT NULL
    AND public.create_invite('ccontrib@w214.test', 'client_contributor', 'c2140000-0000-0000-0000-000000000001') IS NOT NULL,
    '35 every role the old CHECK allowed is still invitable via create_invite');
DO $$
DECLARE ok_scope boolean := false; ok_seat boolean := false; i int;
BEGIN
  -- carried-over checks: client org must be in the caller's practice …
  BEGIN PERFORM public.create_invite('xp@w214.test', 'client_admin', 'cc000000-0000-0000-0000-00000000dead');
  EXCEPTION WHEN OTHERS THEN ok_scope := SQLERRM LIKE '%not in your practice%'; END;
  PERFORM pg_temp.t(ok_scope, '36 create_invite still rejects a client outside the practice');
  -- … and the 5-seat cap counts pending invites (2 seat invites above + 3 more = 5)
  FOR i IN 1..3 LOOP
    PERFORM public.create_invite('seat' || i || '@w214.test', 'practice_consultant');
  END LOOP;
  BEGIN PERFORM public.create_invite('seat6@w214.test', 'read_only');
  EXCEPTION WHEN OTHERS THEN ok_seat := SQLERRM LIKE '%seat limit%'; END;
  PERFORM pg_temp.t(ok_seat, '37 create_invite still enforces the 5-seat cap incl. pending invites');
END $$;
RESET ROLE;
SELECT pg_temp.t(
    NOT EXISTS (SELECT 1 FROM public.invites
                 WHERE practice_id = 'b2140000-0000-0000-0000-000000000001' AND role = 'practice_owner')
    AND EXISTS (SELECT 1 FROM public.invites
                 WHERE practice_id = 'b2140000-0000-0000-0000-000000000001'
                   AND email = 'cons@w214.test' AND role = 'practice_consultant'
                   AND expires_at > now() + interval '6 days'
                   AND invited_by = 'a2140000-0000-0000-0000-000000000004')
    AND EXISTS (SELECT 1 FROM public.audit_log
                 WHERE practice_id = 'b2140000-0000-0000-0000-000000000001'
                   AND action = 'invite.created' AND detail->>'role' = 'client_contributor'),
    '38 no owner invite written; email lower-cased, 7-day expiry, audit unchanged');
-- the platform first-admin path still mints a practice_owner invite
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000001","role":"authenticated"}';
CREATE TEMP TABLE w214_first ON COMMIT DROP AS
  SELECT public.platform_create_partner('W214 Delta', 'msp', 'ZA', NULL, NULL, NULL, 'newadmin@w214.test') AS r;
RESET ROLE;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM w214_first f JOIN public.invites i
                           ON i.token = (f.r->>'invite_token')::uuid
                          WHERE i.role = 'practice_owner'
                            AND i.practice_id = (f.r->>'partner_id')::uuid),
    '39 platform_create_partner first-admin invite still works');
ROLLBACK;

-- ---------- 10. support gets no licence fields (§4.1) ----------
BEGIN;
INSERT INTO public.licences (partner_id, plan, client_limit, programme_limit, starts_on, status)
VALUES ('b2140000-0000-0000-0000-000000000001', 'W214-PLAN', 10, 20, CURRENT_DATE, 'active');
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.platform_list_partners('{"id":"b2140000-0000-0000-0000-000000000001"}') l
     WHERE l.name = 'W214 Alpha' AND l.status = 'active' AND l.type = 'msp' AND l.country = 'ZA'
       AND l.clients_total = 2
       AND l.licence_id IS NULL AND l.licence_plan IS NULL AND l.licence_status IS NULL
       AND l.licence_starts_on IS NULL AND l.licence_ends_on IS NULL
       AND l.client_limit IS NULL AND l.programme_limit IS NULL
       AND l.clients_used IS NULL AND l.programmes_used IS NULL
       AND l.over_client_limit IS NULL AND l.over_programme_limit IS NULL
       AND l.seats_used IS NULL AND l.pending_invites IS NULL),
    '40 support: list_partners keeps routing metadata, every licence/usage column NULL');
SELECT pg_temp.t(NOT (public.platform_metrics() ? 'licences')
    AND public.platform_metrics()::text NOT LIKE '%W214-PLAN%',
    '41 support: platform_metrics has no licence breakdown');
SET request.jwt.claims = '{"sub":"a2140000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.platform_list_partners('{"id":"b2140000-0000-0000-0000-000000000001"}') l
     WHERE l.licence_id IS NOT NULL AND l.licence_plan = 'W214-PLAN' AND l.licence_status = 'active'
       AND l.client_limit = 10 AND l.programme_limit = 20
       AND l.clients_used = 1 AND l.programmes_used = 1 AND l.over_client_limit = false
       AND l.seats_used = 0 AND l.pending_invites = 0),
    '42 platform_admin: list_partners still returns the full licence payload');
SELECT pg_temp.t(public.platform_metrics() ? 'licences'
    AND (public.platform_metrics()->'licences'->>'active')::int >= 1,
    '43 platform_admin: platform_metrics still has the licence breakdown');
ROLLBACK;

-- ---------- teardown ----------
SELECT pg_temp.w214_wipe();
\echo '=== e2e_platform_admin checks done ==='
