-- ============================================================================
-- W4-08 partner suspension — psql acceptance checks for
-- 20261106000021_suspension.sql (FR-PLT-06, issue #55).
--
-- Self-contained (e2e_platform_admin.sql style): builds its own @w408.test
-- users and 'W408%' partners/clients/programme; never touches the TESTFIX
-- world. JWT callers simulated via SET ROLE authenticated +
-- request.jwt.claims inside BEGIN … ROLLBACK blocks; assertion reads that
-- need to bypass RLS switch back with RESET ROLE inside the same
-- transaction.
--
-- Covers: predicate battery (every shared predicate denies a suspended
-- partner's users), RLS reads + writes denied everywhere (T1/T2 policies
-- AND the legacy current_practice()/memberships layer), client users of
-- the suspended partner's clients keep working, dual-role users fully
-- blocked, consultant-matrix + partner client-scope legs dead, platform
-- admin + client-approved support path unaffected, partner-role invite
-- refused / client invite redeems, un-suspend restores, close stays
-- blocked + terminal, audit + notification_event on every status change.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_suspension.sql
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
CREATE OR REPLACE FUNCTION pg_temp.w408_wipe() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  -- clear any stale JWT claims (SET persists across COMMIT): the
  -- consultant_assignments mirror trigger enforces in a JWT context
  PERFORM set_config('request.jwt.claims','{}',true);
  DELETE FROM public.notification_events
    WHERE scope->>'practice_id' IN
      ('b4080000-0000-0000-0000-000000000001','b4080000-0000-0000-0000-000000000002')
       OR scope->>'client_org_id' IN
      ('c4080000-0000-0000-0000-000000000001','c4080000-0000-0000-0000-000000000002',
       'c4080000-0000-0000-0000-000000000003');
  DELETE FROM public.audit_log WHERE practice_id IN
    ('b4080000-0000-0000-0000-000000000001','b4080000-0000-0000-0000-000000000002');
  DELETE FROM public.invites WHERE practice_id IN
    ('b4080000-0000-0000-0000-000000000001','b4080000-0000-0000-0000-000000000002');
  DELETE FROM public.licences WHERE partner_id IN
    ('b4080000-0000-0000-0000-000000000001','b4080000-0000-0000-0000-000000000002');
  DELETE FROM public.support_access_requests WHERE client_org_id IN
    ('c4080000-0000-0000-0000-000000000001','c4080000-0000-0000-0000-000000000002',
     'c4080000-0000-0000-0000-000000000003');
  DELETE FROM public.support_access_grants WHERE client_org_id IN
    ('c4080000-0000-0000-0000-000000000001','c4080000-0000-0000-0000-000000000002',
     'c4080000-0000-0000-0000-000000000003');
  DELETE FROM public.designations WHERE client_org_id IN
    ('c4080000-0000-0000-0000-000000000001','c4080000-0000-0000-0000-000000000002',
     'c4080000-0000-0000-0000-000000000003');
  DELETE FROM public.consultant_assignments WHERE client_org_id IN
    ('c4080000-0000-0000-0000-000000000001','c4080000-0000-0000-0000-000000000002',
     'c4080000-0000-0000-0000-000000000003');
  DELETE FROM public.register_items WHERE programme_id =
    'd4080000-0000-0000-0000-000000000001';
  DELETE FROM public.activities WHERE programme_id =
    'd4080000-0000-0000-0000-000000000001';
  DELETE FROM public.workstreams WHERE programme_id =
    'd4080000-0000-0000-0000-000000000001';
  DELETE FROM public.programmes WHERE client_org_id IN
    ('c4080000-0000-0000-0000-000000000001','c4080000-0000-0000-0000-000000000002',
     'c4080000-0000-0000-0000-000000000003');
  DELETE FROM public.role_assignments WHERE user_id IN
    (SELECT id FROM public.users WHERE email LIKE '%@w408.test');
  DELETE FROM public.client_orgs WHERE practice_id IN
    ('b4080000-0000-0000-0000-000000000001','b4080000-0000-0000-0000-000000000002');
  DELETE FROM public.practices WHERE id IN
    ('b4080000-0000-0000-0000-000000000001','b4080000-0000-0000-0000-000000000002');
  DELETE FROM public.users WHERE email LIKE '%@w408.test';
  DELETE FROM auth.users WHERE email LIKE '%@w408.test';
END $$;
SELECT pg_temp.w408_wipe();

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
  ('a4080000-0000-0000-0000-000000000001'::uuid, 'padmin@w408.test'),
  ('a4080000-0000-0000-0000-000000000002'::uuid, 'admin1@w408.test'),
  ('a4080000-0000-0000-0000-000000000003'::uuid, 'cons1@w408.test'),
  ('a4080000-0000-0000-0000-000000000004'::uuid, 'ro1@w408.test'),
  ('a4080000-0000-0000-0000-000000000005'::uuid, 'cadmin@w408.test'),
  ('a4080000-0000-0000-0000-000000000006'::uuid, 'ao1@w408.test'),
  ('a4080000-0000-0000-0000-000000000007'::uuid, 'cons2@w408.test'),
  ('a4080000-0000-0000-0000-000000000008'::uuid, 'dual@w408.test'),
  ('a4080000-0000-0000-0000-000000000009'::uuid, 'sup@w408.test'),
  ('a4080000-0000-0000-0000-00000000000a'::uuid, 'plead@w408.test'),
  ('a4080000-0000-0000-0000-00000000000b'::uuid, 'pws@w408.test'),
  ('a4080000-0000-0000-0000-00000000000c'::uuid, 'invitee-p@w408.test'),
  ('a4080000-0000-0000-0000-00000000000d'::uuid, 'invitee-c@w408.test'),
  ('a4080000-0000-0000-0000-00000000000e'::uuid, 'exec1@w408.test')
) AS u(id, email);
INSERT INTO public.users (id, email)
  SELECT id, email FROM auth.users WHERE email LIKE '%@w408.test';

INSERT INTO public.practices (id, name, type, country) VALUES
  ('b4080000-0000-0000-0000-000000000001', 'W408 Alpha', 'msp', 'ZA'),
  ('b4080000-0000-0000-0000-000000000002', 'W408 Beta',  'msp', 'ZA');
INSERT INTO public.client_orgs (id, practice_id, name) VALUES
  ('c4080000-0000-0000-0000-000000000001', 'b4080000-0000-0000-0000-000000000001', 'W408 Client A1'),
  ('c4080000-0000-0000-0000-000000000002', 'b4080000-0000-0000-0000-000000000001', 'W408 Client A2'),
  ('c4080000-0000-0000-0000-000000000003', 'b4080000-0000-0000-0000-000000000002', 'W408 Client B1');
INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d4080000-0000-0000-0000-000000000001', 'c4080000-0000-0000-0000-000000000001',
   'W408 Programme', DATE '2026-11-02', 10);
INSERT INTO public.workstreams (id, programme_id, name) VALUES
  ('e4080000-0000-0000-0000-000000000001', 'd4080000-0000-0000-0000-000000000001', 'W408 WS');
INSERT INTO public.activities (id, programme_id, workstream_id, ref, text, start_week, end_week) VALUES
  ('f4080000-0000-0000-0000-000000000001', 'd4080000-0000-0000-0000-000000000001',
   'e4080000-0000-0000-0000-000000000001', 'W408-A1', 'W408 activity', 1, 1);
INSERT INTO public.register_items (programme_id, ref, finding) VALUES
  ('d4080000-0000-0000-0000-000000000001', 'W408-R1', 'W408 register finding');
INSERT INTO public.licences (id, partner_id, plan, starts_on, status) VALUES
  ('aa080000-0000-0000-0000-000000000001', 'b4080000-0000-0000-0000-000000000001',
   'w408', DATE '2026-01-01', 'active');

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a4080000-0000-0000-0000-000000000001','platform','platform_admin','partner',NULL),
  ('a4080000-0000-0000-0000-000000000002','partner','partner_admin','partner','b4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-000000000003','partner','partner_consultant','partner','b4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-000000000004','partner','read_only','partner','b4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-000000000005','client','client_admin','client','c4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-000000000006','client','accountable_officer','client','c4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-000000000007','partner','partner_consultant','partner','b4080000-0000-0000-0000-000000000002'),
  -- dual: partner consultant of P1 who also leads the client as AO
  ('a4080000-0000-0000-0000-000000000008','partner','partner_consultant','partner','b4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-000000000008','client','accountable_officer','client','c4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-000000000009','platform','support','partner',NULL),
  -- client-level programme lead (programme scope) on P1's programme
  ('a4080000-0000-0000-0000-00000000000a','client','programme_lead','programme','d4080000-0000-0000-0000-000000000001'),
  -- defensive: partner-level row at workstream scope resolving to P1
  ('a4080000-0000-0000-0000-00000000000b','partner','partner_consultant','workstream','e4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-00000000000e','client','executive','client','c4080000-0000-0000-0000-000000000001');
-- client-scope assignment backing the support grant (end-dated so the
-- approve-RPC's own insert never collides)
INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, start_date, end_date, origin)
VALUES ('a4080000-0000-0000-0000-000000000009','platform','support','client',
        'c4080000-0000-0000-0000-000000000001', CURRENT_DATE - 1, CURRENT_DATE + 2, 'manual');

-- legacy consultant matrix legs (trigger mirrors partner client-scope rows):
-- cons1 → C1 (suspended partner), cons2 → C3 (active control partner)
INSERT INTO public.consultant_assignments (user_id, client_org_id) VALUES
  ('a4080000-0000-0000-0000-000000000003', 'c4080000-0000-0000-0000-000000000001'),
  ('a4080000-0000-0000-0000-000000000007', 'c4080000-0000-0000-0000-000000000003');

-- approved, in-window, unrevoked support grant on C1 for sup
INSERT INTO public.support_access_grants
    (client_org_id, securepath_user_id, reason, approved_by, starts_at, expires_at)
VALUES ('c4080000-0000-0000-0000-000000000001', 'a4080000-0000-0000-0000-000000000009',
        'W408 grant', 'a4080000-0000-0000-0000-000000000006',
        now() - interval '1 hour', now() + interval '24 hours');

-- dual's designation on C1 (a partner user holding a client designation)
INSERT INTO public.designations (client_org_id, role, person, date_designated)
VALUES ('c4080000-0000-0000-0000-000000000001', 'named_alternate',
        'a4080000-0000-0000-0000-000000000008', CURRENT_DATE - 1);
-- a pure client user's designation — must keep working under suspension
INSERT INTO public.designations (client_org_id, role, person, date_designated)
VALUES ('c4080000-0000-0000-0000-000000000001', 'dpo',
        'a4080000-0000-0000-0000-00000000000e', CURRENT_DATE - 1);

-- pending invites minted BEFORE suspension: one partner-role, one client-role
-- (the table CHECK wants client_org_id set on client_* roles)
INSERT INTO public.invites (practice_id, email, role, invited_by) VALUES
  ('b4080000-0000-0000-0000-000000000001', 'invitee-p@w408.test', 'practice_consultant',
   'a4080000-0000-0000-0000-000000000002');
INSERT INTO public.invites (practice_id, email, role, client_org_id, invited_by) VALUES
  ('b4080000-0000-0000-0000-000000000001', 'invitee-c@w408.test', 'client_admin',
   'c4080000-0000-0000-0000-000000000001',
   'a4080000-0000-0000-0000-000000000002');

-- helper: count how many write attempts succeed as the current JWT caller
CREATE OR REPLACE FUNCTION pg_temp.w408_write_attempts(p_client uuid) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE n int := 0;
BEGIN
  BEGIN INSERT INTO public.client_orgs (practice_id, name)
        VALUES ('b4080000-0000-0000-0000-000000000001','W408 sneaky');
        n := n + 1; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN UPDATE public.practices SET name = 'W408 renamed'
         WHERE id = 'b4080000-0000-0000-0000-000000000001';
        IF FOUND THEN n := n + 1; END IF; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM public.create_invite('w408-sneaky@x.test','read_only',NULL);
        n := n + 1; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM public.add_member('a4080000-0000-0000-0000-00000000000c','read_only',NULL);
        n := n + 1; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN INSERT INTO public.consultant_assignments (user_id, client_org_id)
        VALUES ('a4080000-0000-0000-0000-000000000003', p_client);
        n := n + 1; EXCEPTION WHEN OTHERS THEN NULL; END;
  RETURN n;
END $$;

-- ---------- 0. baseline: everyone works before suspension ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.partner_is_blocked('b4080000-0000-0000-0000-000000000001')
    AND NOT public.caller_partner_blocked()
    AND public.has_partner_role('b4080000-0000-0000-0000-000000000001', ARRAY['partner_admin'])
    AND public.current_practice() = 'b4080000-0000-0000-0000-000000000001'
    AND (SELECT count(*) FROM public.allowed_client_orgs()) = 2,
    '01 baseline: partner_admin unblocked, sees both partner clients');
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
    'c4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_client_orgs())
    AND 'd4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_programmes())
    AND (SELECT count(*) FROM public.register_items) = 1,
    '02 baseline: consultant sees assigned client + programme + register row');
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(
    'c4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_client_orgs())
    AND public.has_client_role('c4080000-0000-0000-0000-000000000001', ARRAY['client_admin']),
    '03 baseline: client_admin works');
RESET ROLE;
ROLLBACK;

-- ---------- 1. suspend P1 (platform path: audit + notification) ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.platform_set_partner_status(
    'b4080000-0000-0000-0000-000000000001', 'suspended', 'W408 test suspension');
RESET ROLE;
SELECT pg_temp.t(
    (SELECT status FROM public.practices WHERE id='b4080000-0000-0000-0000-000000000001') = 'suspended'
    AND EXISTS (SELECT 1 FROM public.audit_log
                 WHERE practice_id='b4080000-0000-0000-0000-000000000001'
                   AND action='partner.status_changed'
                   AND detail->>'to'='suspended' AND detail->>'reason' LIKE 'W408%')
    AND EXISTS (SELECT 1 FROM public.notification_events
                 WHERE kind='partner_status_changed'
                   AND scope->>'practice_id'='b4080000-0000-0000-0000-000000000001'
                   AND payload->>'to'='suspended' AND payload->>'transition'='suspend'),
    '04 suspend: status + audit row + partner_status_changed event');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ---------- 2. predicate battery: every partner-scope user denied ----------
BEGIN;
SET ROLE authenticated;

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
    public.caller_partner_blocked()
    AND NOT public.has_partner_role('b4080000-0000-0000-0000-000000000001', ARRAY['partner_admin'])
    AND NOT public.has_client_role('c4080000-0000-0000-0000-000000000001', ARRAY['partner_admin','partner_consultant','client_admin','accountable_officer'])
    AND NOT public.has_programme_role('d4080000-0000-0000-0000-000000000001', ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])
    AND NOT public.has_workstream_role('e4080000-0000-0000-0000-000000000001', ARRAY['partner_admin','partner_consultant','workstream_lead'])
    AND NOT public.has_activity_role('f4080000-0000-0000-0000-000000000001', ARRAY['partner_admin','partner_consultant','workstream_lead'])
    AND (SELECT count(*) FROM public.active_assignments(auth.uid())) = 0
    AND (SELECT count(*) FROM public.allowed_client_orgs()) = 0
    AND (SELECT count(*) FROM public.allowed_programmes()) = 0
    AND NOT public.is_ao_or_alternate('c4080000-0000-0000-0000-000000000001')
    AND NOT public.holds_designation('c4080000-0000-0000-0000-000000000001', ARRAY['named_alternate','dpo'])
    AND NOT public.can_read_client_records('c4080000-0000-0000-0000-000000000001')
    AND public.current_practice() IS NULL
    AND public.current_role_name() IS NULL
    AND (SELECT count(*) FROM public.memberships) = 0,
    '05 suspended partner_admin: every predicate denied/empty');

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
    public.caller_partner_blocked()
    AND (SELECT count(*) FROM public.allowed_client_orgs()) = 0
    AND NOT public.has_client_role('c4080000-0000-0000-0000-000000000001', ARRAY['partner_consultant','client_admin']),
    '06 suspended consultant: consultant-matrix + partner client-scope legs dead');

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.t(
    public.caller_partner_blocked()
    AND NOT public.has_partner_role('b4080000-0000-0000-0000-000000000001', ARRAY['read_only'])
    AND (SELECT count(*) FROM public.allowed_client_orgs()) = 0,
    '07 suspended read_only: denied');

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-00000000000b","role":"authenticated"}';
SELECT pg_temp.t(
    public.caller_partner_blocked()
    AND (SELECT count(*) FROM public.allowed_client_orgs()) = 0
    AND (SELECT count(*) FROM public.allowed_programmes()) = 0,
    '08 partner-level workstream-scope row on P1 programme: blocked (defensive resolution)');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ---------- 3. RLS everywhere: reads return nothing, writes fail ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
    (SELECT count(*) FROM public.client_orgs) = 0
    AND (SELECT count(*) FROM public.programmes) = 0
    AND (SELECT count(*) FROM public.register_items) = 0
    AND (SELECT count(*) FROM public.activities) = 0
    AND (SELECT count(*) FROM public.workstreams) = 0
    AND (SELECT count(*) FROM public.licences) = 0
    AND (SELECT count(*) FROM public.jurisdiction_packs) = 0
    AND (SELECT count(*) FROM public.programme_templates) = 0
    AND (SELECT count(*) FROM public.notification_events) = 0
    AND (SELECT count(*) FROM public.audit_log) = 0
    AND (SELECT count(*) FROM public.practices) = 0
    AND (SELECT count(*) FROM public.role_assignments) =
        (SELECT count(*) FROM public.role_assignments WHERE user_id = auth.uid())
    AND (SELECT count(*) FROM public.users) = 1,
    '09 suspended admin reads: every tenant surface empty (own rows only)');
SELECT pg_temp.t(pg_temp.w408_write_attempts('c4080000-0000-0000-0000-000000000001') = 0,
    '10 suspended admin writes: client_orgs INSERT / practices UPDATE / create_invite / add_member / consultant_assignments all denied');
RESET ROLE;
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.client_orgs WHERE name='W408 sneaky')
    AND (SELECT name FROM public.practices WHERE id='b4080000-0000-0000-0000-000000000001') = 'W408 Alpha'
    AND NOT EXISTS (SELECT 1 FROM public.invites WHERE email='w408-sneaky@x.test')
    AND NOT EXISTS (SELECT 1 FROM public.role_assignments
                     WHERE user_id='a4080000-0000-0000-0000-00000000000c'),
    '11 denied writes left no rows');
ROLLBACK;

-- ---------- 4. dual-role user: fully blocked (literal FR-PLT-06) ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT pg_temp.t(
    public.caller_partner_blocked()
    AND NOT public.is_ao_or_alternate('c4080000-0000-0000-0000-000000000001')
    AND NOT public.holds_designation('c4080000-0000-0000-0000-000000000001', ARRAY['named_alternate'])
    AND NOT public.has_client_role('c4080000-0000-0000-0000-000000000001', ARRAY['accountable_officer','partner_consultant'])
    AND (SELECT count(*) FROM public.allowed_client_orgs()) = 0
    AND (SELECT count(*) FROM public.client_orgs) = 0,
    '12 dual partner+client-role user: fully blocked incl. client-side legs');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ---------- 5. client users of the suspended partner keep working ----------
BEGIN;
SET ROLE authenticated;

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.caller_partner_blocked()
    AND 'c4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_client_orgs())
    AND public.has_client_role('c4080000-0000-0000-0000-000000000001', ARRAY['client_admin'])
    AND 'd4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_programmes())
    AND (SELECT count(*) FROM public.register_items) = 1
    AND public.current_practice() = 'b4080000-0000-0000-0000-000000000001',
    '13 client_admin of suspended partner''s client: unaffected');

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.caller_partner_blocked()
    AND public.is_ao_or_alternate('c4080000-0000-0000-0000-000000000001')
    AND public.has_client_role('c4080000-0000-0000-0000-000000000001', ARRAY['accountable_officer'])
    AND (SELECT count(*) FROM public.register_items) = 1,
    '14 client accountable_officer: AO gates still live');

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-00000000000e","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.caller_partner_blocked()
    AND public.holds_designation('c4080000-0000-0000-0000-000000000001', ARRAY['dpo'])
    AND 'c4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_client_orgs()),
    '15 client executive + dpo designation: designation legs unaffected');

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-00000000000a","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.caller_partner_blocked()
    AND 'd4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_programmes())
    AND public.has_programme_role('d4080000-0000-0000-0000-000000000001', ARRAY['programme_lead']),
    '16 client-level programme_lead on suspended partner''s programme: unaffected');

-- client users still cannot mint partner scope for the suspended partner
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w408_write_attempts('c4080000-0000-0000-0000-000000000001') = 0,
    '17 client_admin cannot mint partner-side rows either (all five writes denied — owner-only paths)');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ---------- 6. platform + unaffected partner + support path ----------
BEGIN;
SET ROLE authenticated;

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000007","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.caller_partner_blocked()
    AND public.has_partner_role('b4080000-0000-0000-0000-000000000002', ARRAY['partner_consultant'])
    AND 'c4080000-0000-0000-0000-000000000003' IN (SELECT public.allowed_client_orgs())
    AND (SELECT count(*) FROM public.client_orgs) = 1,
    '18 active partner''s consultant: completely unaffected');

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.caller_partner_blocked()
    AND public.is_platform_role(ARRAY['platform_admin'])
    AND (SELECT count(*) FROM public.platform_list_partners('{"q":"W408"}')) = 2
    AND public.platform_metrics() ? 'partners',
    '19 platform_admin unaffected: lists + metrics work');

SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.caller_partner_blocked()
    AND 'c4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_client_orgs()),
    '20 platform support with client-approved grant on suspended partner''s client: still works (NFR-04)');

-- the client keeps control: its AO approves a fresh support request
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000009","role":"authenticated"}';
CREATE TEMP TABLE w408_req ON COMMIT DROP AS
  SELECT public.request_support_access('c4080000-0000-0000-0000-000000000001',
                                       'W408 check', now() + interval '2 days') AS rid;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE g uuid;
BEGIN
  SELECT public.approve_support_grant((SELECT rid FROM w408_req)) INTO g;
  PERFORM pg_temp.t(g IS NOT NULL,
    '21 client AO still approves support grants while partner suspended');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(false, '21 client AO still approves support grants while partner suspended');
END $$;
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ---------- 7. invites under suspension ----------
-- (invites has no SELECT grant for authenticated and temp tables are not
--  readable under SET ROLE — fetch tokens through a temp DEFINER function)
CREATE OR REPLACE FUNCTION pg_temp.w408_tok(p_email text) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT token FROM public.invites WHERE email = p_email
$$;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-00000000000c","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  PERFORM public.accept_invite(pg_temp.w408_tok('invitee-p@w408.test'));
  PERFORM pg_temp.t(false, '22 partner-role invite on suspended partner refused');
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS e = MESSAGE_TEXT;
  PERFORM pg_temp.t(e LIKE '%suspended%',
      '22 partner-role invite on suspended partner refused: ' || e);
END $$;
RESET ROLE;
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.role_assignments
    WHERE user_id='a4080000-0000-0000-0000-00000000000c'),
    '23 refused partner invite wrote no assignment');
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-00000000000d","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  PERFORM public.accept_invite(pg_temp.w408_tok('invitee-c@w408.test'));
  PERFORM pg_temp.t(true, '24 client-role invite on suspended partner still redeems');
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS e = MESSAGE_TEXT;
  PERFORM pg_temp.t(false, '24 client-role invite on suspended partner still redeems: ' || e);
END $$;
SELECT pg_temp.t(
    'c4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_client_orgs())
    AND public.has_client_role('c4080000-0000-0000-0000-000000000001', ARRAY['client_admin']),
    '25 redeemed client_admin works immediately on the suspended partner''s client');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ---------- 8. un-suspend restores exactly ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.platform_set_partner_status(
    'b4080000-0000-0000-0000-000000000001', 'active', 'W408 reactivation');
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
    NOT public.caller_partner_blocked()
    AND public.has_partner_role('b4080000-0000-0000-0000-000000000001', ARRAY['partner_admin'])
    AND (SELECT count(*) FROM public.allowed_client_orgs()) = 2
    AND public.current_practice() = 'b4080000-0000-0000-0000-000000000001'
    AND (SELECT count(*) FROM public.register_items) = 1,
    '26 reactivate: partner_admin access restored');
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
    'c4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_client_orgs())
    AND 'd4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_programmes()),
    '27 reactivate: consultant matrix + client-scope legs restored');
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT pg_temp.t(
    public.is_ao_or_alternate('c4080000-0000-0000-0000-000000000001')
    AND public.holds_designation('c4080000-0000-0000-0000-000000000001', ARRAY['named_alternate']),
    '28 reactivate: dual-role user''s client-side legs restored too');
RESET ROLE;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
    WHERE kind='partner_status_changed'
      AND scope->>'practice_id'='b4080000-0000-0000-0000-000000000001'
      AND payload->>'to'='active' AND payload->>'transition'='reactivate'),
    '29 reactivation also notified');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ---------- 9. close: still blocked + terminal ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.platform_set_partner_status(
    'b4080000-0000-0000-0000-000000000001', 'closed', 'W408 closure');
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
    public.caller_partner_blocked()
    AND (SELECT count(*) FROM public.allowed_client_orgs()) = 0,
    '30 closed partner: users stay blocked');
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(
    'c4080000-0000-0000-0000-000000000001' IN (SELECT public.allowed_client_orgs()),
    '31 closed partner''s client_admin: still works');
SET request.jwt.claims = '{"sub":"a4080000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.platform_set_partner_status(
    'b4080000-0000-0000-0000-000000000001', 'active', 'reopen attempt');
  PERFORM pg_temp.t(false, '32 closed partner cannot be reopened');
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t(true, '32 closed partner cannot be reopened');
END $$;
RESET ROLE;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
    WHERE kind='partner_status_changed'
      AND scope->>'practice_id'='b4080000-0000-0000-0000-000000000001'
      AND payload->>'to'='closed' AND payload->>'transition'='close'),
    '33 closure notified too');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ---------- teardown ----------
SELECT pg_temp.w408_wipe();
