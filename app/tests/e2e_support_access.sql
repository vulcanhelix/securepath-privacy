-- ============================================================================
-- W4-01 support-access e2e — psql checks (GitHub #48 · FR-PLT-04 / NFR-04,
-- AT-03/04)
--
-- Covers what the browser spec can't see and the W1-07 suite didn't have:
--   · decline_support_request (20261106000019 — the missing decision leg):
--     approver-guard matrix, pending-only, no grant/assignment side effects,
--     decided request can't later be approved, audit + notification.
--   · holder self-revoke leg of revoke_support_grant.
--   · grant expiry closing branch (e) with NO revocation (time alone).
--   · the pending-request expiry sweep inside list_support_grants.
--   · every support-access action lands in audit_log.
--
-- The W1-07 suite (e2e_licences_grants.sql) already proves: request guards,
-- approve guard matrix, the atomic grant+assignment insert, AO revoke,
-- branch-(e) live-grant invariant. This file deliberately does not re-cover.
--
-- Runs against the W0-05 TESTFIX world — apply the fixture pack first with
--   ALTER DATABASE <db> SET securepath.test_fixtures = 'on';
-- (then re-run app/supabase/migrations/20261105000005_test_fixtures.sql).
-- JWT callers simulated via SET ROLE authenticated + request.jwt.claims
-- inside the SAME transaction as the assertions.
--
-- Fixture anchors: U1 aa..-0001 platform_admin · U3 aa..-0003 support
--   (dormant client-scope assignment on C1) · U4 aa..-0004 Partner A admin ·
--   U6 aa..-0006 Partner B admin · U8 aa..-0008 C1 AO · U12 aa..-0012 C1
--   contributor · C1 cc..-001 · C3 cc..-003.
-- Own scratch: request reasons tagged 'W4-01 …' — re-runnable (each run
-- mints fresh request rows; assertions key on the ids this run created).
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.support_access_grants
                  WHERE id = 'f4000005-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'TESTFIX world missing — apply 20261105000005_test_fixtures.sql with securepath.test_fixtures=on first';
  END IF;
  RAISE NOTICE 'PASS 00 fixture gate: TESTFIX world present';
END $$;

-- ===========================================================================
-- A. decline_support_request — the W4-01 decision leg
-- ===========================================================================

-- U3 (support) files two requests: one the AO will decline, one the partner
-- admin will decline.
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.request_support_access('cc000005-0000-0000-0000-000000000001',
    'W4-01 decline-me (AO)', now() + interval '24 hours') AS req_ao \gset
SELECT public.request_support_access('cc000005-0000-0000-0000-000000000001',
    'W4-01 decline-me (partner admin)', now() + interval '24 hours') AS req_pa \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- this run's request ids for use inside DO blocks (psql vars do not expand
-- inside $$ bodies, and a reason-based invoker lookup is itself RLS-scoped —
-- a caller who may not see C1's requests must still be refused by the RPC).
-- Custom GUCs survive SET ROLE where temp-table grants would not.
SET app.w4_req_ao = :'req_ao';
SET app.w4_req_pa = :'req_pa';

-- wrong deciders — every non-approver class must be refused: the requester
-- themself (platform support cannot decide), a C1 contributor, the OTHER
-- partner's admin, and even the platform admin
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  v_req := current_setting('app.w4_req_ao')::uuid;
  BEGIN
    PERFORM public.decline_support_request(v_req, 'should refuse');
    PERFORM pg_temp.t(false, '01a decline: the requester cannot decide own request');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%partner_admin of the owning partner%',
      '01a decline: the requester cannot decide own request');
  END;
END $$;
ROLLBACK;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  v_req := current_setting('app.w4_req_ao')::uuid;
  BEGIN
    PERFORM public.decline_support_request(v_req, 'should refuse');
    PERFORM pg_temp.t(false, '01b decline: client_contributor refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%partner_admin of the owning partner%',
      '01b decline: client_contributor refused');
  END;
END $$;
ROLLBACK;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  v_req := current_setting('app.w4_req_ao')::uuid;
  BEGIN
    PERFORM public.decline_support_request(v_req, 'should refuse');
    PERFORM pg_temp.t(false, '01c decline: other partner''s admin refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%partner_admin of the owning partner%',
      '01c decline: other partner''s admin refused');
  END;
END $$;
ROLLBACK;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  v_req := current_setting('app.w4_req_ao')::uuid;
  BEGIN
    PERFORM public.decline_support_request(v_req, 'should refuse');
    PERFORM pg_temp.t(false, '01d decline: platform_admin cannot decide (client approval is the control)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%partner_admin of the owning partner%',
      '01d decline: platform_admin cannot decide (client approval is the control)');
  END;
END $$;
ROLLBACK;
SELECT pg_temp.t(
  (SELECT status FROM public.support_access_requests WHERE id = :'req_ao'::uuid) = 'pending',
  '01e all refusals left the request pending');

-- the C1 accountable officer declines with a note
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.decline_support_request(:'req_ao'::uuid, 'W4-01 no access needed this week');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.support_access_requests WHERE id = :'req_ao'::uuid) = 'declined'
  AND (SELECT decided_by FROM public.support_access_requests WHERE id = :'req_ao'::uuid)
      = 'aa000005-0000-0000-0000-000000000008'
  AND (SELECT decided_at FROM public.support_access_requests WHERE id = :'req_ao'::uuid) IS NOT NULL,
  '02 decline: AO decision recorded (status + decided_by/at)');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.audit_log
    WHERE action='support_access.declined'
      AND detail->>'request_id' = :'req_ao'
      AND detail->>'note' = 'W4-01 no access needed this week'
      AND user_id = 'aa000005-0000-0000-0000-000000000008'),
  '03 decline: audit_log row with the note');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
    WHERE kind='support_access_declined'
      AND scope->>'user_id' = 'aa000005-0000-0000-0000-000000000003'),
  '04 decline: notification fanned out to the requester');
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.support_access_grants
    WHERE id IN (SELECT grant_id FROM public.support_access_requests WHERE id = :'req_ao'::uuid))
  AND (SELECT grant_id FROM public.support_access_requests WHERE id = :'req_ao'::uuid) IS NULL,
  '05 decline: no grant and no assignment were minted');

-- the other FR-PLT-04 approver class: owning partner's partner_admin declines
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT public.decline_support_request(:'req_pa'::uuid, NULL);
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.support_access_requests WHERE id = :'req_pa'::uuid) = 'declined'
  AND (SELECT decided_by FROM public.support_access_requests WHERE id = :'req_pa'::uuid)
      = 'aa000005-0000-0000-0000-000000000004',
  '06 decline: partner_admin of the owning partner may also refuse');

-- decided requests are settled: neither a second decline nor a late approve
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  v_req := current_setting('app.w4_req_ao')::uuid;
  BEGIN
    PERFORM public.decline_support_request(v_req, 'again');
    PERFORM pg_temp.t(false, '07 decline: second decision refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not pending%', '07 decline: second decision refused');
  END;
  BEGIN
    PERFORM public.approve_support_grant(v_req);
    PERFORM pg_temp.t(false, '08 declined request can never be approved');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not pending%', '08 declined request can never be approved');
  END;
END $$;
ROLLBACK;

-- ===========================================================================
-- B. holder self-revoke — the grant holder relinquishes their own window
--    (revoke_support_grant's v_g.securepath_user_id = auth.uid() leg)
-- ===========================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.request_support_access('cc000005-0000-0000-0000-000000000001',
    'W4-01 self-revoke', now() + interval '24 hours') AS req_self \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.approve_support_grant(:'req_self'::uuid) AS grant_self \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.revoke_support_grant(:'grant_self'::uuid);
SELECT pg_temp.t(
  'cc000005-0000-0000-0000-000000000001'::uuid NOT IN (SELECT public.allowed_client_orgs()),
  '09 self-revoke: holder relinquishes → branch (e) closes at once');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.support_access_grants
    WHERE id = :'grant_self'::uuid AND revoked_at IS NOT NULL),
  '10 self-revoke: revoked_at recorded, row kept as the audit record');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.audit_log
    WHERE action='support_access.revoked' AND detail->>'grant_id' = :'grant_self'
      AND user_id = 'aa000005-0000-0000-0000-000000000003'),
  '11 self-revoke: audit_log attributes the revocation to the holder');

-- ===========================================================================
-- C. expiry ends the window with NO revocation — time alone (AT-04 tail)
-- ===========================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.request_support_access('cc000005-0000-0000-0000-000000000001',
    'W4-01 expiry', now() + interval '4 hours') AS req_exp \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT public.approve_support_grant(:'req_exp'::uuid) AS grant_exp \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
-- in-window the holder sees C1…
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
  'cc000005-0000-0000-0000-000000000001'::uuid IN (SELECT public.allowed_client_orgs()),
  '12 live grant: holder sees C1 inside the window');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
-- …the clock runs out (backdate the window — the same service-path step the
-- browser spec uses; grants have no authenticated write path by design)
UPDATE public.support_access_grants
   SET starts_at = now() - interval '2 hours', expires_at = now() - interval '1 hour'
 WHERE id = :'grant_exp'::uuid;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
  'cc000005-0000-0000-0000-000000000001'::uuid NOT IN (SELECT public.allowed_client_orgs()),
  '13 expiry: window end alone closes branch (e) — no sweep needed');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.list_support_grants('cc000005-0000-0000-0000-000000000001') g
    WHERE g.id = :'grant_exp'::uuid AND g.state = 'expired'),
  '14 list_support_grants: lapsed grant reads state=expired');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

-- ===========================================================================
-- D. the pending-request expiry sweep + audit coverage assertion
-- ===========================================================================

-- a request whose window lapses undecided is swept to 'expired' by
-- list_support_grants (the only lazy state in the model)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.request_support_access('cc000005-0000-0000-0000-000000000001',
    'W4-01 will-lapse', now() + interval '1 hour') AS req_lapse \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SET app.w4_req_lapse = :'req_lapse';
UPDATE public.support_access_requests
   SET starts_at = now() - interval '2 hours', expires_at = now() - interval '1 minute'
 WHERE id = :'req_lapse'::uuid;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT count(*) FROM public.list_support_grants(NULL);
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status FROM public.support_access_requests WHERE id = :'req_lapse'::uuid) = 'expired',
  '15 lapsed pending request swept to expired (list_support_grants)');
-- …and a lapsed request can no longer be approved
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE v_req uuid;
BEGIN
  v_req := current_setting('app.w4_req_lapse')::uuid;
  BEGIN
    PERFORM public.approve_support_grant(v_req);
    PERFORM pg_temp.t(false, '16 expired request can never be approved');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not pending%', '16 expired request can never be approved');
  END;
END $$;
ROLLBACK;

-- audit completeness for THIS run's actions: each of the four action kinds
-- is present for the requests this run created
SELECT pg_temp.t(
  (SELECT count(*) FROM public.audit_log WHERE action='support_access.requested'
     AND detail->>'request_id' IN (:'req_ao', :'req_pa', :'req_self', :'req_exp', :'req_lapse')) = 5
  AND (SELECT count(*) FROM public.audit_log WHERE action='support_access.declined'
     AND detail->>'request_id' IN (:'req_ao', :'req_pa')) = 2
  AND (SELECT count(*) FROM public.audit_log WHERE action='support_access.approved'
     AND detail->>'request_id' IN (:'req_self', :'req_exp')) = 2
  AND (SELECT count(*) FROM public.audit_log WHERE action='support_access.revoked'
     AND detail->>'grant_id' = :'grant_self') = 1,
  '17 audit_log: every action on this run''s requests is recorded (requested ×5, declined ×2, approved ×2, revoked ×1)');

-- request rows stay readable to the client side after every decision kind
-- (the "visible to the client" ledger — support_access_requests_read)
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.support_access_requests
    WHERE id IN (:'req_ao', :'req_pa', :'req_self', :'req_exp', :'req_lapse')) = 5,
  '18 client AO reads back every request + decision on their client');
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

DO $$ BEGIN RAISE NOTICE 'support-access checks done'; END $$;
