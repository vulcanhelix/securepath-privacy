-- ============================================================================
-- W1-02 evidence chain — psql acceptance checks
-- Covers AT-13 (upload → verify → AO accept → finding Closed with refs),
-- AT-14 (self-verify/self-accept denied at BOTH the RPC and the review-gate
-- trigger), FR-EVD-03/04/05/06/07, FR-ACC-01/02, FR-TPL-07 cross-programme
-- offers, return flows and NFR-09 immutability of decided/returned evidence.
--
-- Runs against the W0-05 TESTFIX fixture world. Apply the fixture migration
-- FIRST in the same session (the GUC is what unlocks it):
--
--   { echo "SET securepath.test_fixtures='on';";
--     cat app/supabase/migrations/20261105000005_test_fixtures.sql \
--         app/tests/e2e_evidence_chain.sql; } \
--   | psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0
--
-- (The fixture file is wipe-and-reseed idempotent, so the suite is
-- re-runnable. It is NOT included via \ir because psql resolves \ir against
-- the CWD when the script is fed on stdin — as the CI step does.)
-- Actors: U8=c1-ao · U9=c1-pl · U10=c1-wsl · U13=c1 named_alternate ·
--         U5=partner-A consultant (client scope C1) · U12=c1-staff.
--
-- JWT callers simulated via SET ROLE authenticated + request.jwt.claims
-- inside the SAME transaction as the calls (proven pattern from
-- e2e_role_assignments.sql). Read-side assertions run as the migration owner
-- (BYPASSRLS) after each COMMIT — the checks assert DB state, not row
-- visibility (that is the role_assignments suite's job).
--
-- NOTE for scratch runs: same shim as e2e_template_engine — this targets the
-- staging auth schema (email_confirmed_at column + coalesced auth.uid()).
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- ---------- suite state ----------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.practices WHERE name = 'TESTFIX Partner A') THEN
    RAISE WARNING 'TESTFIX fixture world absent — apply '
      'app/supabase/migrations/20261105000005_test_fixtures.sql with '
      'SET securepath.test_fixtures=on in this session first (see file header).';
  END IF;
END $$;
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.practices WHERE name='TESTFIX Partner A')
                 AND EXISTS (SELECT 1 FROM public.programmes
                              WHERE id='dd000005-0000-0000-0000-000000000001'),
    'TESTFIX fixture world present (fixture migration applied first)');
-- the outbox accumulates across runs (rpcs always emit); clear for determinism
DELETE FROM public.notification_events;
-- a second programme under C1 for same-client offers (wiped by the fixture
-- re-seed above, so recreate every run)
INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks)
VALUES ('dd000002-0000-0000-0000-000000000001','cc000005-0000-0000-0000-000000000001',
        'W1E2 C1 Second Programme', DATE '2026-11-02', 8)
ON CONFLICT (id) DO NOTHING;
-- restore any prior-run mutations (admin write: auth.uid() NULL → the §9.4
-- register gate is a JWT-context check, skipped for service writes)
UPDATE public.register_items
   SET status='In progress', accepted_on=NULL, accepted_by=NULL,
       accepted_evidence_refs=NULL
 WHERE id='d4000005-0000-0000-0000-000000000002' AND status='Closed';
UPDATE public.activities SET status='In progress'
 WHERE id='d3000005-0000-0000-0000-000000000005' AND status='Complete';
RESET request.jwt.claims;

CREATE TEMP TABLE w1e2 (k text PRIMARY KEY, v uuid);
-- temp objects are owner-only: the JWT-simulated role needs explicit access
GRANT SELECT, INSERT, UPDATE, DELETE ON w1e2 TO authenticated;

-- ============================================================
-- CHAIN 1 — upload → verify → accept (AT-13/14)
-- ============================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000010","role":"authenticated"}';
-- U10 (workstream lead, listed lead on A-03) uploads vs activity+register
DO $$ DECLARE v uuid; BEGIN
  v := public.upload_evidence('d3000005-0000-0000-0000-000000000003',
        'd4000005-0000-0000-0000-000000000001','w1e2/c1/policy-v1.pdf',NULL,
        'W1E2-chain1','TESTFIX Head Office',NULL);
  INSERT INTO w1e2(k,v) VALUES ('ev1',v);
END $$;
-- denial: U12 staff holds no upload role and is not a lead
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.upload_evidence('d3000005-0000-0000-0000-000000000003',NULL,
            'w1e2/c1/staff.pdf',NULL,'W1E2-deny',NULL,NULL);
    PERFORM pg_temp.t(false,'client_contributor upload denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%may not upload%','client_contributor upload denied');
  END;
END $$;
-- validation: evidence must link to an activity or a register item
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.upload_evidence(NULL,NULL,'w1e2/c1/orphan.pdf',NULL,'x',NULL,NULL);
    PERFORM pg_temp.t(false,'upload without activity/register denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'upload without activity/register denied');
  END;
END $$;
-- AT-14 layer 1: uploader self-verify via RPC
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000010","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.verify_evidence((SELECT v FROM w1e2 WHERE k='ev1'),'approved');
    PERFORM pg_temp.t(false,'self-verify denied at RPC (FR-ACC-01)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-ACC-01%','self-verify denied at RPC (FR-ACC-01)');
  END;
END $$;
-- AT-14 layer 2: uploader self-verify by direct ledger INSERT → trigger gate
DO $$ BEGIN
  BEGIN
    INSERT INTO public.evidence_reviews (evidence_item_id, stage, decision)
    VALUES ((SELECT v FROM w1e2 WHERE k='ev1'),'verify','verified');
    PERFORM pg_temp.t(false,'self-verify denied at trigger (FR-ACC-01)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-ACC-01%','self-verify denied at trigger (FR-ACC-01)');
  END;
END $$;
-- role gate: staff cannot verify
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.verify_evidence((SELECT v FROM w1e2 WHERE k='ev1'),'approved');
    PERFORM pg_temp.t(false,'non-reviewer verify denied (FR-EVD-03)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-EVD-03%','non-reviewer verify denied (FR-EVD-03)');
  END;
END $$;
-- partner consultant verifies → acceptance queue
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT public.verify_evidence((SELECT v FROM w1e2 WHERE k='ev1'),'approved','checklist ok');
-- a second verify on the moved item is refused
DO $$ BEGIN
  BEGIN
    PERFORM public.verify_evidence((SELECT v FROM w1e2 WHERE k='ev1'),'approved');
    PERFORM pg_temp.t(false,'re-verify after acceptance denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not awaiting verification%','re-verify after acceptance denied');
  END;
END $$;
-- AT-14: uploader cannot accept own upload even once verified
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000010","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.accept_evidence((SELECT v FROM w1e2 WHERE k='ev1'));
    PERFORM pg_temp.t(false,'self-accept denied (FR-ACC-01)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-ACC-01%','self-accept denied (FR-ACC-01)');
  END;
END $$;
-- non-AO cannot accept
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.accept_evidence((SELECT v FROM w1e2 WHERE k='ev1'));
    PERFORM pg_temp.t(false,'non-AO accept denied (FR-ACC-02)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-ACC-02%','non-AO accept denied (FR-ACC-02)');
  END;
END $$;
-- AO accepts: A-03 still In progress → partly_supports, R-01 stays open
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT pg_temp.t(
    (public.accept_evidence((SELECT v FROM w1e2 WHERE k='ev1'))->>'evidence_ref')
      = 'EV-R-01-001',
    'accept_evidence mints EV-R-01-001 (partner format, register token)');
-- decided items refuse further decisions
DO $$ BEGIN
  BEGIN
    PERFORM public.accept_evidence((SELECT v FROM w1e2 WHERE k='ev1'));
    PERFORM pg_temp.t(false,'re-accept on decided evidence denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'re-accept on decided evidence denied');
  END;
END $$;
COMMIT;
RESET ROLE; RESET request.jwt.claims;

-- read-side assertions (owner, BYPASSRLS)
SELECT pg_temp.t((SELECT review_stage='decided' AND outcome='partly_supports'
                    AND evidence_ref='EV-R-01-001'
                    AND uploaded_by='aa000005-0000-0000-0000-000000000010'
                    AND note='W1E2-chain1'
                  FROM public.evidence_items WHERE id=(SELECT v FROM w1e2 WHERE k='ev1')),
    'upload→accept: decided, partly_supports (A-03 incomplete), ref minted');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.evidence_reviews
      WHERE evidence_item_id=(SELECT v FROM w1e2 WHERE k='ev1')
        AND stage='verify' AND decision='verified'
        AND reviewer='aa000005-0000-0000-0000-000000000005'),
    'verify ledger row written (stage=verify, decision=verified)');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.evidence_reviews
      WHERE evidence_item_id=(SELECT v FROM w1e2 WHERE k='ev1')
        AND stage='accept' AND decision='accepted'
        AND reviewer='aa000005-0000-0000-0000-000000000008'),
    'accept ledger row written by the AO');
SELECT pg_temp.t((SELECT status FROM public.register_items
                  WHERE id='d4000005-0000-0000-0000-000000000001') = 'In progress',
    'R-01 stays open — linked activity A-03 not Complete (§9.4)');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
      WHERE kind='evidence_uploaded'
        AND payload->>'evidence_id' = (SELECT v::text FROM w1e2 WHERE k='ev1'))
    AND EXISTS (SELECT 1 FROM public.notification_events
      WHERE kind='evidence_awaiting_decision'
        AND payload->>'evidence_id' = (SELECT v::text FROM w1e2 WHERE k='ev1'))
    AND EXISTS (SELECT 1 FROM public.notification_events
      WHERE kind='evidence_accepted'
        AND payload->>'evidence_id' = (SELECT v::text FROM w1e2 WHERE k='ev1')),
    'notification_events written for upload, verify, accept (§10 outbox)');

-- ============================================================
-- CHAIN 2 — §9.4 closure (AT-13): all linked activities Complete
--           + AO acceptance → finding Closed with refs
-- ============================================================
UPDATE public.activities SET status='Complete'
 WHERE id='d3000005-0000-0000-0000-000000000005';   -- A-05, linked to R-02
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
-- fixture EV2 is already at acceptance (uploaded U10 on A-05/R-02)
SELECT pg_temp.t(
    (public.accept_evidence('e1000005-0000-0000-0000-000000000002')->>'outcome')
      = 'closes_finding',
    'accept with all linked activities Complete → outcome closes_finding');
COMMIT;
RESET ROLE; RESET request.jwt.claims;
SELECT pg_temp.t((SELECT status='Closed' AND accepted_by='aa000005-0000-0000-0000-000000000008'
                    AND accepted_on IS NOT NULL
                    AND 'EV-R-02-001' = ANY(accepted_evidence_refs)
                  FROM public.register_items
                  WHERE id='d4000005-0000-0000-0000-000000000002'),
    'AT-13: R-02 Closed with date, AO and evidence ref recorded (§9.4)');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
      WHERE kind='register_item_closed'
        AND payload->>'register_item_id' = 'd4000005-0000-0000-0000-000000000002'),
    'register closure notification written');

-- ============================================================
-- CHAIN 3 — FR-EVD-07: AO led the work → named alternate decides
-- ============================================================
BEGIN;
SET ROLE authenticated;
-- U9 uploads on A-01 (whose lead is U8, the AO)
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$ DECLARE v uuid; BEGIN
  v := public.upload_evidence('d3000005-0000-0000-0000-000000000001',
        'd4000005-0000-0000-0000-000000000004','w1e2/c1/ao-led.pdf',NULL,
        'W1E2-evd07',NULL,NULL);
  INSERT INTO w1e2(k,v) VALUES ('evd07',v);
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT public.verify_evidence((SELECT v FROM w1e2 WHERE k='evd07'),'approved',NULL);
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.accept_evidence((SELECT v FROM w1e2 WHERE k='evd07'));
    PERFORM pg_temp.t(false,'AO who led the work cannot accept (FR-EVD-07)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-EVD-07%','AO who led the work cannot accept (FR-EVD-07)');
  END;
END $$;
-- the named alternate may
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000013","role":"authenticated"}';
SELECT pg_temp.t(
    (public.accept_evidence((SELECT v FROM w1e2 WHERE k='evd07'))->>'evidence_ref')
      = 'EV-R-04-002',
    'named alternate accepts (FR-EVD-07) → EV-R-04-002 (per-register seq)');
COMMIT;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================
-- CHAIN 4 — returns: verify-stage + acceptance-stage
-- ============================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000010","role":"authenticated"}';
DO $$ DECLARE v uuid; BEGIN
  v := public.upload_evidence('d3000005-0000-0000-0000-000000000003',
        'd4000005-0000-0000-0000-000000000001','w1e2/c1/bad-scope.pdf',NULL,
        'W1E2-return',NULL,NULL);
  INSERT INTO w1e2(k,v) VALUES ('evret',v);
END $$;
-- return without reasons is refused (FR-EVD-05 mandatory reasons)
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.verify_evidence((SELECT v FROM w1e2 WHERE k='evret'),'returned',NULL);
    PERFORM pg_temp.t(false,'verify-return without reasons denied (FR-EVD-05)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'verify-return without reasons denied (FR-EVD-05)');
  END;
END $$;
SELECT public.verify_evidence((SELECT v FROM w1e2 WHERE k='evret'),'returned','site coverage missing');
-- acceptance-stage: U10 uploads another; U9 verifies; AO returns
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000010","role":"authenticated"}';
DO $$ DECLARE v uuid; BEGIN
  v := public.upload_evidence('d3000005-0000-0000-0000-000000000003',NULL,
        'w1e2/c1/ao-return.pdf',NULL,'W1E2-ao-return',NULL,NULL);
  INSERT INTO w1e2(k,v) VALUES ('evaor',v);
  v := public.upload_evidence('d3000005-0000-0000-0000-000000000003',NULL,
        'w1e2/c1/pending-acc.pdf',NULL,'W1E2-pending-acc',NULL,NULL);
  INSERT INTO w1e2(k,v) VALUES ('evpend',v);
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT public.verify_evidence((SELECT v FROM w1e2 WHERE k='evaor'),'approved',NULL);
SELECT public.verify_evidence((SELECT v FROM w1e2 WHERE k='evpend'),'approved',NULL);
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
SELECT public.return_evidence((SELECT v FROM w1e2 WHERE k='evaor'),
        ARRAY['outside the activity window']);
-- non-AO cannot return at acceptance (evpend left pending for the queue check)
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.return_evidence((SELECT v FROM w1e2 WHERE k='evpend'),ARRAY['nope']);
    PERFORM pg_temp.t(false,'non-AO return at acceptance denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%accountable officer%','non-AO return at acceptance denied');
  END;
END $$;
COMMIT;
RESET ROLE; RESET request.jwt.claims;

-- read-side assertions
SELECT pg_temp.t((SELECT review_stage FROM public.evidence_items
                  WHERE id=(SELECT v FROM w1e2 WHERE k='evret')) = 'returned',
    'verify verdict returned → review_stage returned');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.evidence_reviews
      WHERE evidence_item_id=(SELECT v FROM w1e2 WHERE k='evret')
        AND stage='verify' AND decision='returned'
        AND reasons='{site coverage missing}'),
    'return writes verify/returned ledger row with reasons');
SELECT pg_temp.t((SELECT review_stage FROM public.evidence_items
                  WHERE id=(SELECT v FROM w1e2 WHERE k='evaor')) = 'returned',
    'AO return_evidence at acceptance → returned');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.evidence_reviews
      WHERE evidence_item_id=(SELECT v FROM w1e2 WHERE k='evaor')
        AND stage='accept' AND decision='returned'
        AND reasons='{outside the activity window}'),
    'AO return writes accept/returned ledger row with reasons');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
      WHERE kind='evidence_returned'
        AND payload->>'evidence_id' = (SELECT v::text FROM w1e2 WHERE k='evret')
        AND scope->>'user_id' = 'aa000005-0000-0000-0000-000000000010')
    AND EXISTS (SELECT 1 FROM public.notification_events
      WHERE kind='evidence_returned'
        AND payload->>'evidence_id' = (SELECT v::text FROM w1e2 WHERE k='evaor')),
    'evidence_returned notifications target the uploader (§10)');

-- ============================================================
-- CHAIN 5 — cross-programme offers (FR-TPL-07 / FR-ONB-05)
-- ============================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$ DECLARE v uuid; BEGIN
  v := public.offer_evidence_to_programme('e1000005-0000-0000-0000-000000000003',
        'dd000002-0000-0000-0000-000000000001','overlapping appointment control');
  INSERT INTO w1e2(k,v) VALUES ('offer',v);
END $$;
-- pending (non-decided) evidence cannot be offered
DO $$ BEGIN
  BEGIN
    PERFORM public.offer_evidence_to_programme('e1000005-0000-0000-0000-000000000001',
            'dd000002-0000-0000-0000-000000000001');
    PERFORM pg_temp.t(false,'offer of undecided evidence denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%decided%','offer of undecided evidence denied');
  END;
END $$;
-- cross-CLIENT offer refused (FR-TPL-07: same client only)
DO $$ BEGIN
  BEGIN
    PERFORM public.offer_evidence_to_programme('e1000005-0000-0000-0000-000000000003',
            'dd000005-0000-0000-0000-000000000002');
    PERFORM pg_temp.t(false,'offer to another client denied (FR-TPL-07)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%same client%','offer to another client denied (FR-TPL-07)');
  END;
END $$;
-- non-AO cannot accept the offer
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.accept_evidence_offer((SELECT v FROM w1e2 WHERE k='offer'));
    PERFORM pg_temp.t(false,'non-AO offer acceptance denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%FR-ACC-02%','non-AO offer acceptance denied');
  END;
END $$;
-- the target programme AO accepts: new row, provenance kept, original untouched
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$ DECLARE r jsonb; BEGIN
  r := public.accept_evidence_offer((SELECT v FROM w1e2 WHERE k='offer'));
  INSERT INTO w1e2(k,v) VALUES ('new_ev',(r->>'evidence_id')::uuid);
END $$;
COMMIT;
RESET ROLE; RESET request.jwt.claims;

SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.evidence_offers
      WHERE id=(SELECT v FROM w1e2 WHERE k='offer')
        AND to_programme_id='dd000002-0000-0000-0000-000000000001'
        AND outcome='accepted' AND offered_by='aa000005-0000-0000-0000-000000000009'
        AND decided_by='aa000005-0000-0000-0000-000000000008'
        AND decided_at IS NOT NULL),
    'offer written then stamped accepted by the target AO');
SELECT pg_temp.t((SELECT programme_id='dd000002-0000-0000-0000-000000000001'
                    AND source_evidence_id='e1000005-0000-0000-0000-000000000003'
                    AND review_stage='decided' AND evidence_ref IS NOT NULL
                  FROM public.evidence_items WHERE id=(SELECT v FROM w1e2 WHERE k='new_ev')),
    'offer accept creates NEW decided row in target with source provenance');
SELECT pg_temp.t((SELECT review_stage='decided' AND evidence_ref='EV-R-04-001'
                  FROM public.evidence_items WHERE id='e1000005-0000-0000-0000-000000000003'),
    'source evidence row untouched by the share (never moved)');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.evidence_reviews
      WHERE evidence_item_id=(SELECT v FROM w1e2 WHERE k='new_ev')
        AND stage='accept' AND decision='accepted'
        AND reviewer='aa000005-0000-0000-0000-000000000008'),
    'target-programme acceptance ledger row written');
SELECT pg_temp.t(EXISTS (SELECT 1 FROM public.notification_events
      WHERE kind='evidence_offer_accepted'
        AND payload->>'offer_id' = (SELECT v::text FROM w1e2 WHERE k='offer')),
    'offer acceptance notification written');

-- ============================================================
-- CHAIN 6 — list_pending_reviews queue (W2-06 contract)
-- ============================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
SELECT pg_temp.t(
    (SELECT count(*) FROM jsonb_array_elements(
        public.list_pending_reviews('dd000005-0000-0000-0000-000000000001'::uuid)->'verify') x
     WHERE x->>'id' = 'e1000005-0000-0000-0000-000000000001') = 1,
    'queue: pending fixture EV1 in the reviewer verify set');
SELECT pg_temp.t(
    (SELECT count(*) FROM jsonb_array_elements(
        public.list_pending_reviews('dd000005-0000-0000-0000-000000000001'::uuid)->'accept') x
     WHERE x->>'id' = (SELECT v::text FROM w1e2 WHERE k='evpend')) = 1,
    'queue: verified W1E2 item in the acceptance set');
SELECT pg_temp.t(
    (public.list_pending_reviews('dd000005-0000-0000-0000-000000000001'::uuid)
        ->>'caller_can_verify')::boolean
    AND NOT (public.list_pending_reviews('dd000005-0000-0000-0000-000000000001'::uuid)
        ->>'caller_is_ao_or_alternate')::boolean,
    'queue flags: PL caller can verify, is not AO');
COMMIT;
-- own uploads never appear in your own queue
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000010","role":"authenticated"}';
SELECT pg_temp.t(
    (SELECT count(*) FROM jsonb_array_elements(
        public.list_pending_reviews('dd000005-0000-0000-0000-000000000001'::uuid)->'verify') x
     WHERE x->>'uploaded_by' = 'aa000005-0000-0000-0000-000000000010') = 0,
    'queue: uploader never sees own uploads in verify set (FR-ACC-01)');
COMMIT;
-- invisible programme refused
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$ BEGIN
  BEGIN
    PERFORM public.list_pending_reviews('dd000005-0000-0000-0000-000000000003'::uuid);
    PERFORM pg_temp.t(false,'queue on invisible programme denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%not visible%','queue on invisible programme denied');
  END;
END $$;
COMMIT;

-- ============================================================
-- NFR-09 — decided AND returned evidence is immutable on every path
-- ============================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000010","role":"authenticated"}';
-- uploader tries to rewrite their own decided item (the UPDATE grant on
-- link covers the column; the trigger is the guard)
DO $$ BEGIN
  BEGIN
    UPDATE public.evidence_items SET link='w1e2/hack'
     WHERE id=(SELECT v FROM w1e2 WHERE k='ev1');
    PERFORM pg_temp.t(false,'UPDATE on decided evidence denied (NFR-09)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%immutable%','UPDATE on decided evidence denied (NFR-09)');
  END;
END $$;
COMMIT;
RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN
  BEGIN
    DELETE FROM public.evidence_items WHERE id='e1000005-0000-0000-0000-000000000003';
    PERFORM pg_temp.t(false,'DELETE on decided evidence denied (NFR-09)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%immutable%','DELETE on decided evidence denied (NFR-09)');
  END;
  BEGIN
    UPDATE public.evidence_items SET note='reopen'
     WHERE id=(SELECT v FROM w1e2 WHERE k='evret');
    PERFORM pg_temp.t(false,'UPDATE on returned evidence denied (NFR-09)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%immutable%','UPDATE on returned evidence denied (NFR-09)');
  END;
END $$;

\echo '=== e2e_evidence_chain checks done ==='
