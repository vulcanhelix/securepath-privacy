-- ============================================================================
-- W1-07 licences + support-access grants — psql acceptance checks
-- Covers: licence issue/change/suspend/close (platform_admin only, one-active
-- enforcement, terminal transitions, audit_log), assert_licence_capacity
-- (FR-ONB-02 at/over limit, no-licence, uncapped), licence_warning_threshold_
-- check (80% sweep + dedup), the support grant request→approve→revoke flow
-- (branch-(e) coupled rows in ONE transaction, expiry, revocation), the
-- expiry sweep in list_support_grants, usage_report, and the hard rule that
-- licences/support_access_grants are never direct-writable.
--
-- Runs against the W0-05 TESTFIX world — apply the fixture pack first with
--   ALTER DATABASE <db> SET securepath.test_fixtures = 'on';
-- (then re-run app/supabase/migrations/20261105000005_test_fixtures.sql).
-- JWT callers are simulated via SET ROLE authenticated + request.jwt.claims
-- inside the SAME transaction as the assertions — the pattern proven in
-- e2e_role_assignments.sql / e2e_ops_crud.sql.
--
-- Fixture anchors (20261105000005_test_fixtures.sql):
--   U1 aa000005-..-0001 platform_admin · U3 aa..-0003 support (dormant
--     client-scope platform assignment on C1 + EXPIRED grant f4000005-..-0001)
--   U4 aa..-0004 Partner A admin · U5 aa..-0005 Partner A consultant (C1-scope
--     only — no partner-scope role) · U6 aa..-0006 Partner B admin
--   U8 aa..-0008 C1 accountable_officer (+ IO designation)
--   U12 aa..-0012 C1 client_contributor (no approval authority)
--   Partner A bb..-001 licence f2..-001 (2/2 — AT limit) · B bb..-002 lic
--     f2..-002 (5/5 — under) · Direct bb..-003 lic f2..-003 (uncapped)
--   C1 cc..-001 (Partner A) · P1 dd..-001, P2 dd..-002 under A
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_licences_grants.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- gate: the TESTFIX world must be seeded
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.licences
                  WHERE id = 'f2000005-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'TESTFIX world missing — apply 20261105000005_test_fixtures.sql with securepath.test_fixtures=on first';
  END IF;
  RAISE NOTICE 'PASS 00 fixture gate: TESTFIX licence world present';
END $$;

-- ============================================================================
-- A. assert_licence_capacity (FR-ONB-02) — pristine fixture state
-- ============================================================================
DO $$
BEGIN
  BEGIN
    PERFORM public.assert_licence_capacity('bb000005-0000-0000-0000-000000000001','programme');
    PERFORM pg_temp.t(false, '01 capacity: Partner A programme create blocked at 2/2');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%programme limit reached%',
      '01 capacity: Partner A programme create blocked at 2/2');
  END;
  BEGIN
    PERFORM public.assert_licence_capacity('bb000005-0000-0000-0000-000000000001','client');
    PERFORM pg_temp.t(false, '02 capacity: Partner A client create blocked at 2/2');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%client limit reached%',
      '02 capacity: Partner A client create blocked at 2/2');
  END;
END $$;

-- under-limit + uncapped partners pass (as the partner's own admin would call)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.assert_licence_capacity('bb000005-0000-0000-0000-000000000002','programme');
  PERFORM public.assert_licence_capacity('bb000005-0000-0000-0000-000000000002','client');
  PERFORM pg_temp.t(true, '03 capacity: Partner B under limits passes');
END $$;
RESET ROLE; SET request.jwt.claims = '';
COMMIT;

DO $$
BEGIN
  PERFORM public.assert_licence_capacity('bb000005-0000-0000-0000-000000000003','programme');
  PERFORM pg_temp.t(true, '04 capacity: SecurePath Direct NULL limits = uncapped, passes');
END $$;

-- U5: client-scope-only consultant has NO partner-scope role → guard rejects
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.assert_licence_capacity('bb000005-0000-0000-0000-000000000001','programme');
    PERFORM pg_temp.t(false, '05 capacity: client-scope-only consultant rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%no role on partner%',
      '05 capacity: client-scope-only consultant rejected');
  END;
END $$;
ROLLBACK;

-- suspended licence ⇒ no active in-term licence ⇒ blocked; then reactivated
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.suspend_licence('f2000005-0000-0000-0000-000000000002');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

DO $$
BEGIN
  BEGIN
    PERFORM public.assert_licence_capacity('bb000005-0000-0000-0000-000000000002','programme');
    PERFORM pg_temp.t(false, '06 capacity: suspended licence blocks creation (no active licence)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%no active in-term licence%',
      '06 capacity: suspended licence blocks creation (no active licence)');
  END;
END $$;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.change_licence('f2000005-0000-0000-0000-000000000002', '{"status":"active"}'::jsonb);
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.licences WHERE id='f2000005-0000-0000-0000-000000000002') = 'active',
  '07 change_licence: suspended → active reactivation');
DO $$
BEGIN
  PERFORM public.assert_licence_capacity('bb000005-0000-0000-0000-000000000002','programme');
  PERFORM pg_temp.t(true, '08 capacity: Partner B passes again after reactivation');
END $$;

-- ============================================================================
-- B. licence warning sweep (Partner A still at 100% of both caps here)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.licence_warning_threshold_check(NULL) AS warned \gset
RESET ROLE; SET request.jwt.claims = '';
COMMIT;
SELECT pg_temp.t((:'warned')::int >= 2,
  '09 warning sweep: Partner A at 100% emits >= 2 licence_warning events');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.notification_events
    WHERE kind='licence_warning'
      AND (scope->>'practice_id')='bb000005-0000-0000-0000-000000000001') >= 2,
  '10 warning events: client_limit + programme_limit rows for Partner A');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.licence_warning_threshold_check(NULL) AS warned2 \gset
RESET ROLE; SET request.jwt.claims = '';
COMMIT;
SELECT pg_temp.t((:'warned2')::int = 0,
  '11 warning sweep: deduped — second run emits 0');

-- other-partner admin cannot sweep partner A
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.licence_warning_threshold_check('bb000005-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '12 warning sweep: partner-B admin rejected for partner A');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '12 warning sweep: partner-B admin rejected for partner A');
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- C. licence writers — guards, one-active, transitions, audit
-- ============================================================================
-- non-platform licence writes are rejected at every layer
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    INSERT INTO public.licences (partner_id, plan, starts_on)
    VALUES ('bb000005-0000-0000-0000-000000000001','W1-07 direct','2026-01-01');
    PERFORM pg_temp.t(false, '13 direct INSERT INTO licences denied (grant revoked)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '13 direct INSERT INTO licences denied (grant revoked)');
  END;
  BEGIN
    PERFORM public.issue_licence('bb000005-0000-0000-0000-000000000001',
        '{"plan":"W1-07 rogue"}'::jsonb);
    PERFORM pg_temp.t(false, '14 issue_licence: partner_admin rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%platform_admin required%',
      '14 issue_licence: partner_admin rejected');
  END;
END $$;
ROLLBACK;

-- even a platform_admin cannot write the table directly — RPCs only
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    INSERT INTO public.licences (partner_id, plan, starts_on)
    VALUES ('bb000005-0000-0000-0000-000000000001','W1-07 direct','2026-01-01');
    PERFORM pg_temp.t(false, '15 direct INSERT denied even for platform_admin');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, '15 direct INSERT denied even for platform_admin');
  WHEN OTHERS THEN
    PERFORM pg_temp.t(false, '15 direct INSERT denied even for platform_admin (got: '||SQLERRM||')');
  END;
END $$;
ROLLBACK;

-- platform_admin: draft beside the active licence is allowed; second active is not
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.issue_licence('bb000005-0000-0000-0000-000000000001',
  '{"plan":"W1-07 Draft Plan","client_limit":3,"programme_limit":3,"status":"draft"}'::jsonb) AS lic_draft \gset
-- (psql vars are NOT interpolated inside DO $$ bodies — resolve by plan)
DO $$
DECLARE v_lic uuid;
BEGIN
  SELECT id INTO v_lic FROM public.licences WHERE plan='W1-07 Draft Plan';
  BEGIN
    PERFORM public.issue_licence('bb000005-0000-0000-0000-000000000001',
        '{"plan":"W1-07 second active"}'::jsonb);
    PERFORM pg_temp.t(false, '16 issue_licence: second ACTIVE licence rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%already has an active licence%',
      '16 issue_licence: second ACTIVE licence rejected');
  END;
  -- draft → active while another is active: one-active index must fire
  BEGIN
    PERFORM public.change_licence(v_lic, '{"status":"active"}'::jsonb);
    PERFORM pg_temp.t(false, '17 change_licence: activating a second licence rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '17 change_licence: activating a second licence rejected');
  END;
  -- suspend only applies to active licences
  BEGIN
    PERFORM public.suspend_licence(v_lic);
    PERFORM pg_temp.t(false, '18 suspend_licence: draft cannot be suspended');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%only an active licence%',
      '18 suspend_licence: draft cannot be suspended');
  END;
  -- illegal transition: draft → suspended via patch
  BEGIN
    PERFORM public.change_licence(v_lic, '{"status":"suspended"}'::jsonb);
    PERFORM pg_temp.t(false, '19 change_licence: draft → suspended rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%illegal status transition%',
      '19 change_licence: draft → suspended rejected');
  END;
END $$;
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.licences
    WHERE id = :'lic_draft'::uuid AND status='draft' AND client_limit=3),
  '20 issue_licence: draft coexists with the partner''s active licence');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.audit_log
    WHERE action='licence.issued' AND detail->>'licence_id' = :'lic_draft'),
  '21 audit_log: licence.issued row written');

-- draft → terminated is legal; a terminated licence is terminal
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.change_licence(:'lic_draft'::uuid, '{"status":"terminated"}'::jsonb);
DO $$
DECLARE v_lic uuid;
BEGIN
  SELECT id INTO v_lic FROM public.licences WHERE plan='W1-07 Draft Plan';
  BEGIN
    PERFORM public.change_licence(v_lic, '{"plan":"W1-07 resurrect"}'::jsonb);
    PERFORM pg_temp.t(false, '22 change_licence: terminated licence is terminal');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%terminated%',
      '22 change_licence: terminated licence is terminal');
  END;
END $$;
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- patch a limit + suspend/close the fixture licence
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.change_licence('f2000005-0000-0000-0000-000000000001',
  '{"client_limit":4,"programme_limit":4}'::jsonb);
SELECT public.suspend_licence('f2000005-0000-0000-0000-000000000001');
SELECT public.close_licence('f2000005-0000-0000-0000-000000000001');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.licences WHERE id='f2000005-0000-0000-0000-000000000001') = 'terminated',
  '23 close_licence: fixture licence terminated (via suspend first)');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.audit_log
    WHERE detail->>'licence_id' = 'f2000005-0000-0000-0000-000000000001'
      AND action IN ('licence.changed','licence.suspended','licence.closed')) = 3,
  '24 audit_log: change + suspend + close all recorded');

-- ============================================================================
-- D. support-access grant flow (NFR-04 / FR-PLT-04)
-- ============================================================================
-- expired grant denies: U3's dormant assignment alone opens nothing
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
  NOT ('cc000005-0000-0000-0000-000000000001'::uuid IN (SELECT public.allowed_client_orgs())),
  '25 expired grant: dormant assignment alone denies U3 access to C1');
ROLLBACK;

-- non-platform caller cannot request
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.request_support_access('cc000005-0000-0000-0000-000000000001',
        'W1-07 partner tries to self-request');
    PERFORM pg_temp.t(false, '26 request_support_access: partner_admin rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%platform support role required%',
      '26 request_support_access: partner_admin rejected');
  END;
END $$;
ROLLBACK;

-- U3 (support) requests; both denials of bad approvers; U8 (C1 AO) approves
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.request_support_access('cc000005-0000-0000-0000-000000000001',
    'W1-07 investigate TESTFIX import', now() + interval '24 hours') AS req1 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.support_access_requests
    WHERE id=:'req1'::uuid AND status='pending'
      AND requested_by='aa000005-0000-0000-0000-000000000003'),
  '27 request_support_access: pending request row created');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
    WHERE kind='support_access_requested'
      AND (scope->>'client_org_id')='cc000005-0000-0000-0000-000000000001'),
  '28 support_access_requested notification emitted to AO + partner_admin');

-- wrong approvers: client contributor and (deliberately) platform_admin
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  SELECT id INTO v_req FROM public.support_access_requests
   WHERE reason='W1-07 investigate TESTFIX import';
  BEGIN
    PERFORM public.approve_support_grant(v_req);
    PERFORM pg_temp.t(false, '29 approve: client_contributor rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '29 approve: client_contributor rejected');
  END;
END $$;
ROLLBACK;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  SELECT id INTO v_req FROM public.support_access_requests
   WHERE reason='W1-07 investigate TESTFIX import';
  BEGIN
    PERFORM public.approve_support_grant(v_req);
    PERFORM pg_temp.t(false, '30 approve: platform_admin cannot approve (client approval is the control)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '30 approve: platform_admin cannot approve (client approval is the control)');
  END;
END $$;
ROLLBACK;

-- U8 (C1 accountable_officer) approves → BOTH rows in one transaction
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.approve_support_grant(:'req1'::uuid) AS grant1 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.support_access_grants
    WHERE id=:'grant1'::uuid
      AND client_org_id='cc000005-0000-0000-0000-000000000001'
      AND securepath_user_id='aa000005-0000-0000-0000-000000000003'
      AND approved_by='aa000005-0000-0000-0000-000000000008'
      AND revoked_at IS NULL),
  '31 approve: grant row minted (approved_by = C1 AO)');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.role_assignments
    WHERE user_id='aa000005-0000-0000-0000-000000000003'
      AND level='platform' AND role='support' AND scope_type='client'
      AND scope_id='cc000005-0000-0000-0000-000000000001'
      AND start_date <= CURRENT_DATE AND end_date > CURRENT_DATE),
  '32 approve: coupled platform client-scope assignment minted (bounded end_date)');
SELECT pg_temp.t(
  (SELECT status FROM public.support_access_requests WHERE id=:'req1'::uuid) = 'approved'
  AND (SELECT grant_id FROM public.support_access_requests WHERE id=:'req1'::uuid) = :'grant1'::uuid,
  '33 approve: request marked approved + linked to grant');

-- access now flows through branch (e) — end-to-end via RLS
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
  'cc000005-0000-0000-0000-000000000001'::uuid IN (SELECT public.allowed_client_orgs())
  AND (SELECT count(*) FROM public.client_orgs
       WHERE id='cc000005-0000-0000-0000-000000000001') = 1,
  '34 live grant: U3 sees C1 end-to-end (predicate + RLS)');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.list_support_grants('cc000005-0000-0000-0000-000000000001') g
          WHERE g.id = :'grant1'::uuid AND g.state='active'),
  '35 list_support_grants: holder sees own grant state=active');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- wrong revoker denied; the client AO revokes; access dies with the grant
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE v_g uuid;
BEGIN
  SELECT id INTO v_g FROM public.support_access_grants
   WHERE reason='W1-07 investigate TESTFIX import';
  BEGIN
    PERFORM public.revoke_support_grant(v_g);
    PERFORM pg_temp.t(false, '36 revoke: partner-B admin rejected (wrong partner)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '36 revoke: partner-B admin rejected (wrong partner)');
  END;
END $$;
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.revoke_support_grant(:'grant1'::uuid);
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.support_access_grants
    WHERE id=:'grant1'::uuid AND revoked_at IS NOT NULL),
  '37 revoke: revoked_at set; row kept (never deleted)');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
  NOT ('cc000005-0000-0000-0000-000000000001'::uuid IN (SELECT public.allowed_client_orgs()))
  AND (SELECT count(*) FROM public.client_orgs
       WHERE id='cc000005-0000-0000-0000-000000000001') = 0,
  '38 revoked grant: U3 loses C1 again despite dormant assignment');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.list_support_grants('cc000005-0000-0000-0000-000000000001') g
          WHERE g.id = :'grant1'::uuid AND g.state='revoked')
  AND EXISTS (SELECT 1 FROM public.list_support_grants('cc000005-0000-0000-0000-000000000001') g
          WHERE g.id = 'f4000005-0000-0000-0000-000000000001' AND g.state='expired'),
  '39 list_support_grants: revoked + expired states computed');
ROLLBACK;

-- atomicity: force the role_assignment insert to fail → grant must not exist
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.request_support_access('cc000005-0000-0000-0000-000000000001',
    'W1-07 atomicity probe', now() + interval '24 hours') AS req2 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

CREATE OR REPLACE FUNCTION public.w107_fail_ra_insert() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'W1-07 forced role_assignments failure'; END $$;
CREATE TRIGGER w107_fail_ra BEFORE INSERT ON public.role_assignments
FOR EACH ROW EXECUTE FUNCTION public.w107_fail_ra_insert();

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  SELECT id INTO v_req FROM public.support_access_requests
   WHERE reason='W1-07 atomicity probe';
  BEGIN
    PERFORM public.approve_support_grant(v_req);
    PERFORM pg_temp.t(false, '40 atomicity: forced-failure approve must raise');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%forced role_assignments failure%',
      '40 atomicity: forced-failure approve must raise');
  END;
END $$;
ROLLBACK;

DROP TRIGGER w107_fail_ra ON public.role_assignments;
DROP FUNCTION public.w107_fail_ra_insert();
-- the first approve's bounded assignment legitimately persists (revoke does
-- not end assignments — decision 4); the probe must add NO further ones.
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.support_access_grants g
      JOIN public.support_access_requests r ON r.id = :'req2'::uuid
      WHERE g.securepath_user_id = r.requested_by
        AND g.client_org_id = r.client_org_id
        AND g.reason = 'W1-07 atomicity probe')
  AND (SELECT count(*) FROM public.role_assignments
      WHERE user_id='aa000005-0000-0000-0000-000000000003'
        AND scope_id='cc000005-0000-0000-0000-000000000001'
        AND end_date IS NOT NULL) = 1
  AND (SELECT status FROM public.support_access_requests WHERE id=:'req2'::uuid) = 'pending',
  '41 atomicity: failure created NEITHER grant NOR assignment; request still pending');

-- expiry sweep: a stale pending request flips to expired inside list_support_grants
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.request_support_access('cc000005-0000-0000-0000-000000000001',
    'W1-07 sweep probe', now() + interval '1 hour') AS req3 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
-- age the request out (admin-side time travel — starts_at must move too to
-- satisfy the CHECK expires_at > starts_at)
UPDATE public.support_access_requests
   SET starts_at = now() - interval '2 hours',
       expires_at = now() - interval '1 minute'
 WHERE id = :'req3'::uuid;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT count(*) FROM public.list_support_grants('cc000005-0000-0000-0000-000000000001');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.support_access_requests WHERE id=:'req3'::uuid) = 'expired',
  '42 list_support_grants: expiry sweep flips stale pending request to expired');

-- direct writes to support_access_grants are denied even to platform_admin
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    INSERT INTO public.support_access_grants
      (client_org_id, securepath_user_id, reason, approved_by, expires_at)
    VALUES ('cc000005-0000-0000-0000-000000000001',
            'aa000005-0000-0000-0000-000000000003','W1-07 direct grant',
            'aa000005-0000-0000-0000-000000000001', now() + interval '1 hour');
    PERFORM pg_temp.t(false, '43 direct INSERT INTO support_access_grants denied');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true, '43 direct INSERT INTO support_access_grants denied');
  WHEN OTHERS THEN
    PERFORM pg_temp.t(false, '43 direct INSERT INTO support_access_grants denied (got: '||SQLERRM||')');
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- E. usage_report (FR-LIC-02 / FR-PLT-05)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.usage_report(NULL)) >= 3
  AND EXISTS (SELECT 1 FROM public.usage_report(NULL) u
              WHERE u.partner_id='bb000005-0000-0000-0000-000000000001'
                AND u.clients_used=2 AND u.programmes_used=2
                AND u.active_users >= 1),
  '44 usage_report: platform_admin all-partner view (Partner A 2/2, users>0)');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.usage_report(NULL) u
          WHERE u.partner_id='bb000005-0000-0000-0000-000000000001'
            AND (u.programmes_by_framework ? 'popia_paia'
                 OR u.programmes_by_framework ? 'unassigned'
                 OR u.programmes_by_framework <> '{}'::jsonb)),
  '45 usage_report: programmes_by_framework populated');
ROLLBACK;

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.usage_report('bb000005-0000-0000-0000-000000000002')) = 1,
  '46 usage_report: partner_admin sees own partner row');
DO $$
BEGIN
  BEGIN
    PERFORM public.usage_report('bb000005-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false, '47 usage_report: partner_admin denied other partner');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '47 usage_report: partner_admin denied other partner');
  END;
  BEGIN
    PERFORM public.usage_report(NULL);
    PERFORM pg_temp.t(false, '48 usage_report: partner_admin denied all-partner view');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '48 usage_report: partner_admin denied all-partner view');
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- teardown: drop the pending probe requests so the world is left clean-ish
-- ============================================================================
DELETE FROM public.support_access_requests
 WHERE id IN (:'req2'::uuid, :'req3'::uuid);
