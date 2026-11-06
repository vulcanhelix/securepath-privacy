-- ============================================================================
-- W1-08 notification fan-out — psql acceptance checks
-- Covers: queue_notification emitter + scope-visibility guard, recipient
-- expansion (role cascade, uuid tokens, designations, securepath), prefs
-- (digest opt-in, per-kind delivery/channel/mute), the breach-always-
-- immediate HARD RULE (spec §10), claim lease + stale reclaim, mark
-- sent/failed, dispatched_at stamping, and the digest aggregator.
--
-- Runs against the W0-05 TESTFIX world — apply the fixture pack first with
--   ALTER DATABASE <db> SET securepath.test_fixtures = 'on';
-- (then re-run app/supabase/migrations/20261105000005_test_fixtures.sql).
--
-- Fixture ids used (see 20261105000005_test_fixtures.sql):
--   Partner A bb000005-..-0001 · C1 cc000005-..-0001 · P1 dd000005-..-0001
--   U4  aa000005-..-0004 partner_admin A (partner scope)
--   U5  aa000005-..-0005 partner_consultant A (client scope C1 only)
--   U6  aa000005-..-0006 partner_admin B (cross-partner)
--   U8  aa000005-..-0008 C1 accountable_officer (client scope)
--   U9  aa000005-..-0009 C1 programme_lead (programme scope P1)
--   U11 aa000005-..-0011 C1 executive
--   U12 aa000005-..-0012 C1 client_contributor (staff)
--   U13 aa000005-..-0013 C1 client_contributor + named_alternate designation
--   U1  aa000005-..-0001 platform_admin ('securepath' token target)
--   U3  aa000005-..-0003 platform support
-- Every event this file emits is tagged payload.suite='w1n8' for teardown.
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- gate: TESTFIX world must be seeded
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.programmes
                  WHERE id = 'dd000005-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'TESTFIX world missing — apply 20261105000005_test_fixtures.sql with securepath.test_fixtures=on first';
  END IF;
  RAISE NOTICE 'PASS 00 fixture gate: TESTFIX P1 present';
END $$;

-- clean slate: remove anything a previous run of THIS file left behind
DELETE FROM public.notification_events WHERE payload->>'suite' = 'w1n8';
DELETE FROM public.notification_preferences WHERE user_id IN
  (SELECT id FROM public.users WHERE email LIKE '%@testfix.test');

-- ============================================================================
-- 1. queue + expand: role-cascade at programme scope
-- ============================================================================
-- U9 (programme_lead P1) emits a programme-scoped event to the §10 breach
-- recipient set minus breach: programme_lead, accountable_officer,
-- partner_consultant. Expected fan-out on C1/P1:
--   U9 programme_lead (programme scope) · U8 accountable_officer (client
--   scope) · U5 partner_consultant (client scope) · U13 via named_alternate
--   designation on the accountable_officer token.
--   NOT U4 (partner_admin, not consultant) · NOT U11/U12 · NOT U6.
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.queue_notification('report_due_late',
  '{"programme_id":"dd000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","subject":"TESTFIX report due",
    "recipients":["programme_lead","accountable_officer","partner_consultant"]}'::jsonb,
  '2026-11-02 09:00+00'::timestamptz) AS ev1 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events WHERE id = :'ev1'::uuid),
  '01 queue_notification: programme-scoped event accepted + id returned');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.notification_recipients WHERE event_id = :'ev1'::uuid) = 4
  AND (SELECT count(*) FROM public.notification_recipients
        WHERE event_id = :'ev1'::uuid AND user_id IN
          ('aa000005-0000-0000-0000-000000000005',
           'aa000005-0000-0000-0000-000000000008',
           'aa000005-0000-0000-0000-000000000009',
           'aa000005-0000-0000-0000-000000000013')) = 4,
  '02 recipient expansion: PL + AO + consultant + named_alternate designation (4)');
SELECT pg_temp.t(
  (SELECT resolved_at FROM public.notification_events WHERE id = :'ev1'::uuid) IS NOT NULL,
  '03 resolved_at stamped on expansion');

-- ============================================================================
-- 2. RLS: a user reads only their own delivery rows
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.notification_recipients WHERE event_id = :'ev1'::uuid) = 1,
  '04 RLS: U9 sees only their own recipient row for the event');
ROLLBACK;

-- ============================================================================
-- 3. scope-visibility guard: cross-partner emit refused
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.queue_notification('report_due_late',
      '{"client_org_id":"cc000005-0000-0000-0000-000000000001"}'::jsonb,
      '{"suite":"w1n8","recipients":["accountable_officer"]}'::jsonb);
    PERFORM pg_temp.t(false, '05 cross-partner emit refused');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '05 cross-partner emit refused');
  END;
END $$;
ROLLBACK;

-- ============================================================================
-- 4. BREACH HARD RULE (spec §10): digest opt-in AND mute can never delay or
--    silence a breach alert
-- ============================================================================
-- give every expected recipient the most hostile prefs possible
INSERT INTO public.notification_preferences (user_id, digest, kinds)
SELECT u.id, true, '{"breach_reported":{"mute":true,"delivery":"digest","channel":"in_platform"}}'::jsonb
FROM public.users u WHERE u.id IN
  ('aa000005-0000-0000-0000-000000000005','aa000005-0000-0000-0000-000000000008',
   'aa000005-0000-0000-0000-000000000009','aa000005-0000-0000-0000-000000000013');

BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
-- programme lead escalates the breach report U12 filed (the report itself
-- lands via an ops RPC — the raw emitter requires write capability; U12's
-- contributor emit attempt is the negative check at #30 below)
SELECT public.queue_notification('breach_reported',
  '{"client_org_id":"cc000005-0000-0000-0000-000000000001",
    "programme_id":"dd000005-0000-0000-0000-000000000001",
    "user_id":"aa000005-0000-0000-0000-000000000012"}'::jsonb,
  '{"suite":"w1n8","subject":"TESTFIX breach reported",
    "recipients":["programme_lead","accountable_officer","partner_consultant"]}'::jsonb) AS evb \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(
  (SELECT count(*) FROM public.notification_recipients
    WHERE event_id = :'evb'::uuid AND delivery = 'immediate' AND channel = 'email'
      AND status = 'pending') >= 4
  AND (SELECT count(*) FROM public.notification_recipients
        WHERE event_id = :'evb'::uuid AND delivery = 'digest') = 0,
  '06 breach_reported: every row immediate+email despite digest+mute prefs (§10)');
-- the reporter themself (scope.user_id, digest pref default) is also a direct recipient
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.notification_recipients
     WHERE event_id = :'evb'::uuid AND user_id = 'aa000005-0000-0000-0000-000000000012'),
  '07 scope.user_id → the reporter is a direct recipient');

-- ============================================================================
-- 5. prefs: mute, digest opt-in, per-kind delivery + channel overrides
-- ============================================================================
INSERT INTO public.notification_preferences (user_id, digest, kinds) VALUES
  ('aa000005-0000-0000-0000-000000000012', false,
   '{"evidence_returned":{"mute":true}}'::jsonb),                       -- U12 mutes one kind
  ('aa000005-0000-0000-0000-000000000011', false, '{}'::jsonb);

SELECT public.queue_notification('evidence_returned',
  '{"client_org_id":"cc000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","recipients":["aa000005-0000-0000-0000-000000000011",
                                "aa000005-0000-0000-0000-000000000012"]}'::jsonb) AS ev_mute \gset

SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM public.notification_recipients
               WHERE event_id = :'ev_mute'::uuid
                 AND user_id = 'aa000005-0000-0000-0000-000000000012')
  AND EXISTS (SELECT 1 FROM public.notification_recipients
               WHERE event_id = :'ev_mute'::uuid
                 AND user_id = 'aa000005-0000-0000-0000-000000000011'),
  '08 per-kind mute: muted user gets no row; unmuted uuid recipient does');

-- U9 already has digest=true (set in §4); U11 has no pref → immediate
SELECT public.queue_notification('activity_due',
  '{"programme_id":"dd000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","subject":"TESTFIX activity due",
    "recipients":["programme_lead","executive"]}'::jsonb) AS ev_dig \gset

SELECT pg_temp.t(
  (SELECT delivery FROM public.notification_recipients
    WHERE event_id = :'ev_dig'::uuid AND user_id = 'aa000005-0000-0000-0000-000000000009')
    = 'digest'
  AND (SELECT delivery FROM public.notification_recipients
    WHERE event_id = :'ev_dig'::uuid AND user_id = 'aa000005-0000-0000-0000-000000000011')
    = 'immediate',
  '09 digest opt-in: U9 row folds to digest; U11 stays immediate');

-- per-kind override beats the global digest flag
UPDATE public.notification_preferences
   SET kinds = '{"activity_due":{"delivery":"immediate"}}'::jsonb
 WHERE user_id = 'aa000005-0000-0000-0000-000000000009';
SELECT public.queue_notification('activity_due',
  '{"programme_id":"dd000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","recipients":["programme_lead"]}'::jsonb) AS ev_ovr \gset
SELECT pg_temp.t(
  (SELECT delivery FROM public.notification_recipients
    WHERE event_id = :'ev_ovr'::uuid AND user_id = 'aa000005-0000-0000-0000-000000000009')
    = 'immediate',
  '10 per-kind delivery override beats digest opt-in');
UPDATE public.notification_preferences
   SET kinds = '{}'::jsonb
 WHERE user_id = 'aa000005-0000-0000-0000-000000000009';          -- restore plain digest opt-in

-- in_platform channel: the row itself is the delivery → sent at resolve
UPDATE public.notification_preferences
   SET kinds = '{"template_version_published":{"channel":"in_platform"}}'::jsonb
 WHERE user_id = 'aa000005-0000-0000-0000-000000000011';
SELECT public.queue_notification('template_version_published',
  '{"practice_id":"bb000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","recipients":["partner_admin",
                                "aa000005-0000-0000-0000-000000000011"]}'::jsonb) AS ev_inp \gset
SELECT pg_temp.t(
  (SELECT status FROM public.notification_recipients
    WHERE event_id = :'ev_inp'::uuid AND user_id = 'aa000005-0000-0000-0000-000000000011')
    = 'sent'
  AND (SELECT status FROM public.notification_recipients
    WHERE event_id = :'ev_inp'::uuid AND user_id = 'aa000005-0000-0000-0000-000000000004')
    = 'pending',
  '11 in_platform channel → sent at resolve; email partner_admin pending');
UPDATE public.notification_preferences SET kinds = '{}'::jsonb
 WHERE user_id = 'aa000005-0000-0000-0000-000000000011';

-- 'securepath' token → platform staff
SELECT public.queue_notification('licence_near_limit',
  '{"practice_id":"bb000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","recipients":["partner_admin","securepath"]}'::jsonb) AS ev_sec \gset
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.notification_recipients
           WHERE event_id = :'ev_sec'::uuid
             AND user_id = 'aa000005-0000-0000-0000-000000000004')
  AND EXISTS (SELECT 1 FROM public.notification_recipients
           WHERE event_id = :'ev_sec'::uuid
             AND user_id IN ('aa000005-0000-0000-0000-000000000001',
                             'aa000005-0000-0000-0000-000000000003')),
  '12 securepath token → platform_admin/support + partner_admin');

-- ============================================================================
-- 6. claim lease, stale reclaim, mark sent / failed, dispatched_at
-- ============================================================================
-- worker-only guard first: a user JWT can never claim
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.claim_notification_batch(50, 300, now());
    PERFORM pg_temp.t(false, '13 claim refused under a user JWT');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '13 claim refused under a user JWT');
  END;
END $$;
ROLLBACK;

-- claim as the worker (no JWT context) at a fixed clock
SELECT count(*) AS claimed_n,
      (array_agg(claim_token))[1] AS tok,
      (array_agg(id ORDER BY created_at))[1] AS first_id
  INTO TEMP w1n8_claim
  FROM public.claim_notification_batch(50, 300, '2026-11-03 06:00+00'::timestamptz,
                                       'dd111108-0000-0000-0000-000000000001'::uuid);
SELECT pg_temp.t(
  (SELECT claimed_n FROM w1n8_claim) >= 5,
  '14 claim_notification_batch: pending immediate rows leased under one token');
SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM public.notification_recipients
               WHERE delivery='immediate' AND channel='email' AND status='pending'
                 AND event_id IN (SELECT id FROM public.notification_events
                                   WHERE payload->>'suite'='w1n8')),
  '15 all pending immediate deliveries of the suite are now claimed');

-- a second claim at the same instant takes nothing (lease held)
SELECT pg_temp.t(
  (SELECT count(*) FROM public.claim_notification_batch(
       50, 300, '2026-11-03 06:00+00'::timestamptz,
       'dd111108-0000-0000-0000-000000000002'::uuid)) = 0,
  '16 live lease blocks a second claim');

-- six minutes later (>300s lease) a fresh claim re-takes the stale rows
SELECT pg_temp.t(
  (SELECT count(*) FROM public.claim_notification_batch(
       50, 300, '2026-11-03 06:06:01+00'::timestamptz,
       'dd111108-0000-0000-0000-000000000003'::uuid)) >= 5,
  '17 stale lease is reclaimable after p_lease_seconds');

-- wrong token marks nothing; right token marks the batch
SELECT pg_temp.t(
  public.mark_notification_sent(
    (SELECT array_agg(id) FROM public.notification_recipients
      WHERE claim_token = 'dd111108-0000-0000-0000-000000000003'),
    'dd111108-0000-0000-0000-000000000099'::uuid,
    '2026-11-03 06:07+00'::timestamptz) = 0,
  '18 mark_notification_sent ignores a foreign claim token');
SELECT pg_temp.t(
  public.mark_notification_sent(
    (SELECT array_agg(id) FROM public.notification_recipients
      WHERE claim_token = 'dd111108-0000-0000-0000-000000000003'),
    'dd111108-0000-0000-0000-000000000003'::uuid,
    '2026-11-03 06:07+00'::timestamptz)
  = (SELECT count(*) FROM public.notification_recipients
      WHERE claim_token = 'dd111108-0000-0000-0000-000000000003'),
  '19 mark_notification_sent finalises exactly the claimed batch');

SELECT pg_temp.t(
  (SELECT dispatched_at FROM public.notification_events WHERE id = :'ev1'::uuid) IS NOT NULL
  AND (SELECT dispatched_at FROM public.notification_events WHERE id = :'evb'::uuid) IS NOT NULL,
  '20 dispatched_at stamped once every delivery is terminal');

-- mark failed: retryable failure releases the lease back to pending
SELECT public.queue_notification('activity_due',
  '{"programme_id":"dd000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","recipients":["aa000005-0000-0000-0000-000000000011"]}'::jsonb) AS ev_fail \gset
SELECT id AS fail_rid INTO TEMP w1n8_fail
  FROM public.notification_recipients
 WHERE event_id = :'ev_fail'::uuid AND user_id = 'aa000005-0000-0000-0000-000000000011';
SELECT count(*) AS _claim4 FROM public.claim_notification_batch(50, 300,
  '2026-11-03 07:00+00'::timestamptz,
  'dd111108-0000-0000-0000-000000000004'::uuid) \gset
SELECT public.mark_notification_failed(
    (SELECT array_agg(fail_rid) FROM w1n8_fail),
    'dd111108-0000-0000-0000-000000000004'::uuid,
    'TESTFIX resend 550',
    '2026-11-03 07:01+00'::timestamptz) AS failed_n \gset
SELECT pg_temp.t(
  :'failed_n'::int = 1
  AND (SELECT status FROM public.notification_recipients WHERE id = (SELECT fail_rid FROM w1n8_fail)) = 'pending'
  AND (SELECT attempts FROM public.notification_recipients WHERE id = (SELECT fail_rid FROM w1n8_fail)) = 1
  AND (SELECT last_error FROM public.notification_recipients WHERE id = (SELECT fail_rid FROM w1n8_fail))
      = 'TESTFIX resend 550',
  '21 mark_notification_failed: attempts+1, error recorded, lease released to pending');

-- ============================================================================
-- 7. digest aggregator
-- ============================================================================
-- a second digest-eligible event for U9 so the digest has >1 group/row
SELECT public.queue_notification('evidence_awaiting_decision',
  '{"programme_id":"dd000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","subject":"TESTFIX evidence awaiting decision",
    "recipients":["programme_lead"]}'::jsonb) AS ev_dig2 \gset

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.digest_pending_users('2026-11-04 06:00+00'::timestamptz)
           WHERE digest_pending_users = 'aa000005-0000-0000-0000-000000000009'),
  '22 digest_pending_users lists U9');

SELECT public.build_digest('aa000005-0000-0000-0000-000000000009',
    '-infinity'::timestamptz, '2026-11-04 06:00+00'::timestamptz,
    'dd111108-0000-0000-0000-000000000005'::uuid) AS digest \gset
SELECT pg_temp.t(
  (:'digest'::jsonb ->> 'count')::int >= 2
  AND jsonb_typeof(:'digest'::jsonb -> 'groups') = 'array'
  AND (:'digest'::jsonb ->> 'email') = 'c1-pl@testfix.test',
  '23 build_digest: pending digest rows grouped by kind under one lease token');
-- the §10 hard rule at the digest layer: even with digest-all prefs, no
-- breach kind can appear in the grouped payload (breach row is immediate)
SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'digest'::jsonb -> 'groups') g
               WHERE g->>'kind' LIKE 'breach%'),
  '24 breach alert can never fold into a digest (§10 hard rule)');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.notification_recipients
    WHERE claim_token = 'dd111108-0000-0000-0000-000000000005' AND status = 'claimed') >= 2
  AND (SELECT count(*) FROM public.notification_recipients
        WHERE user_id = 'aa000005-0000-0000-0000-000000000009'
          AND delivery = 'digest' AND status = 'pending') = 0,
  '25 digest rows leased under the returned token (racing worker sees none)');
-- p_since bounds the window
SELECT public.build_digest('aa000005-0000-0000-0000-000000000009',
    '2026-12-01 00:00+00'::timestamptz, '2026-12-01 06:00+00'::timestamptz,
    'dd111108-0000-0000-0000-000000000006'::uuid) AS digest_empty \gset
SELECT pg_temp.t(
  (:'digest_empty'::jsonb ->> 'count')::int = 0,
  '26 build_digest honours p_since (nothing pending inside the window)');
-- close out the leased digest rows
SELECT public.mark_notification_sent(
    (SELECT array_agg(id) FROM public.notification_recipients
      WHERE claim_token IN ('dd111108-0000-0000-0000-000000000005',
                            'dd111108-0000-0000-0000-000000000006')),
    'dd111108-0000-0000-0000-000000000005'::uuid,
    '2026-11-04 06:05+00'::timestamptz) AS dig_sent \gset
SELECT pg_temp.t(
  (SELECT count(*) FROM public.notification_recipients
    WHERE claim_token IS NULL AND status = 'sent'
      AND user_id = 'aa000005-0000-0000-0000-000000000009' AND delivery = 'digest') >= 2,
  '27 digest deliveries marked sent under the lease token');

-- ============================================================================
-- 8. lazy expansion: an event INSERTed raw (W1-06 style) fans out at claim
-- ============================================================================
INSERT INTO public.notification_events (kind, scope, payload)
VALUES ('decision_recorded',
        '{"programme_id":"dd000005-0000-0000-0000-000000000001",
          "client_org_id":"cc000005-0000-0000-0000-000000000001"}'::jsonb,
        '{"suite":"w1n8","recipients":["aa000005-0000-0000-0000-000000000011"]}'::jsonb)
RETURNING id AS ev_raw \gset
SELECT pg_temp.t(
  (SELECT resolved_at FROM public.notification_events WHERE id = :'ev_raw'::uuid) IS NULL,
  '28 raw-inserted event starts unresolved');
SELECT count(*) AS _claim7 FROM public.claim_notification_batch(50, 300,
  '2026-11-05 06:00+00'::timestamptz,
  'dd111108-0000-0000-0000-000000000007'::uuid) \gset
SELECT pg_temp.t(
  (SELECT resolved_at FROM public.notification_events WHERE id = :'ev_raw'::uuid) IS NOT NULL
  AND EXISTS (SELECT 1 FROM public.notification_recipients
               WHERE event_id = :'ev_raw'::uuid
                 AND user_id = 'aa000005-0000-0000-0000-000000000011'),
  '29 claim sweep lazily resolves un-expanded events (raw emitters still fan out)');

-- ============================================================================
-- 9. emission write-gate (review fix) + platform-staff token aliases
-- ============================================================================
-- U12 (client_contributor — visible on C1 but no write role) emits breach → denied
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
BEGIN
  BEGIN
    PERFORM public.queue_notification('breach_reported',
      '{"client_org_id":"cc000005-0000-0000-0000-000000000001"}'::jsonb,
      '{"suite":"w1n8","recipients":["accountable_officer"]}'::jsonb);
    PERFORM pg_temp.t(false, '30 read-only/contributor breach emit denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '30 read-only/contributor breach emit denied');
  END;
END $$;
-- same user, ordinary kind → still denied (write-capability, not just alerts)
DO $$
BEGIN
  BEGIN
    PERFORM public.queue_notification('activity_due',
      '{"client_org_id":"cc000005-0000-0000-0000-000000000001"}'::jsonb,
      '{"suite":"w1n8","recipients":["accountable_officer"]}'::jsonb);
    PERFORM pg_temp.t(false, '31 contributor emit denied for ordinary kinds too');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true, '31 contributor emit denied for ordinary kinds too');
  END;
END $$;
ROLLBACK;

-- positive control: U4 partner_admin (partner-write) CAN emit breach on C1
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT public.queue_notification('breach_reported',
  '{"client_org_id":"cc000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","recipients":["programme_lead","accountable_officer"]}'::jsonb) AS evb2 \gset
COMMIT;
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
    WHERE id = :'evb2'::uuid AND kind = 'breach_reported'),
  '32 partner_admin (partner-write) may emit breach on an owned client');

-- 'platform_admin' / 'platform_support' tokens alias to platform staff
SELECT public.queue_notification('licence_near_limit',
  '{"practice_id":"bb000005-0000-0000-0000-000000000001"}'::jsonb,
  '{"suite":"w1n8","recipients":["platform_admin","platform_support"]}'::jsonb) AS ev_pa \gset
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.notification_recipients
           WHERE event_id = :'ev_pa'::uuid
             AND user_id = 'aa000005-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM public.notification_recipients
           WHERE event_id = :'ev_pa'::uuid
             AND user_id = 'aa000005-0000-0000-0000-000000000003'),
  '33 platform_admin/platform_support tokens resolve to platform staff');

-- ============================================================================
-- teardown (suite-scoped only — never touch other suites' rows)
-- ============================================================================
DELETE FROM public.notification_events WHERE payload->>'suite' = 'w1n8';  -- cascades recipients
DELETE FROM public.notification_preferences WHERE user_id IN
  (SELECT id FROM public.users WHERE email LIKE '%@testfix.test');
DROP TABLE IF EXISTS w1n8_claim;
DROP TABLE IF EXISTS w1n8_fail;

\echo '=== e2e_notifications checks done ==='
