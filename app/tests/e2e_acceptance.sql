-- ============================================================================
-- W4-07 (issue #54) — ACCEPTANCE SUITE: spec v0.2 §14 scenarios AT-01..AT-22
-- exercised against the W0-05 TESTFIX fixture world (the pack was seeded with
-- an AT-scenario → fixture mapping; every check below is labelled by its AT
-- number so a reviewer can map spec → check).
--
-- HOW TO READ THE COVERAGE TABLE: "here" = a check in this file; a path =
-- an existing suite/spec that already proves the leg (verified by reading
-- the check, not duplicated). DEVIATION = the leg cannot pass because the
-- feature is not built yet (issue referenced); nothing below fakes it.
--
--  AT  Scenario (spec §14)                          Proven where
--  --- ------------------------------------------  --------------------------------
--  01  partner A hits partner B's client id        HERE §01 (RLS read/UPDATE/INSERT
--                                                  invisible, definer-RPC refusal);
--                                                  app/tests/e2e_isolation.py (real
--                                                  HTTP, 22 checks);
--                                                  e2e_exports.sql cross-tenant leg.
--                                                  DEVIATION: "attempt logged" —
--                                                  R1 has no denied-attempt ledger
--                                                  (audit fires on writes that LAND;
--                                                  an RLS-refused call never reaches
--                                                  a trigger). Raised for spec
--                                                  sign-off; refusal is fail-closed.
--  02  consultant sees assigned client only         HERE §02 (list_programmes +
--                                                  client_orgs = C1/P1 only);
--                                                  team-licence.spec.ts (console).
--  03  support without a grant sees nothing         HERE §03 + e2e_support_access.sql
--                                                  + support-access.spec.ts test 1.
--  04  24 h grant: works, logged, client-visible,   HERE §04 end-to-end (request →
--      then ends                                    AO approve → branch-(e) access →
--                                                  client-visible grant → expire →
--                                                  closed); deep coverage:
--                                                  e2e_support_access.sql,
--                                                  e2e_licences_grants.sql,
--                                                  support-access.spec.ts.
--  05  partner A brand everywhere; B unaffected     HERE §05 (partner_branding RPC,
--                                                  subdomain, B-isolation);
--                                                  branding.spec.ts (form, live
--                                                  preview, shell repaint, audit,
--                                                  guard); print-report.spec.ts
--                                                  (report in partner brand);
--                                                  web/lib/notify.ts (branded mail
--                                                  envelope). PARTIAL: brand-by-
--                                                  host on the sign-in page is
--                                                  W2-15 (#28, open); "Word report"
--                                                  is HTML→PDF by W3-03 decision.
--  06  sub-AA text colour warns before saving       web/e2e/acceptance.spec.ts
--                                                  (the only place the warning can
--                                                  fire — BrandingForm FR-BRN-07).
--  07  programme beyond licence limit blocked       HERE §07 (create_programme on
--                                                  Partner A at 2/2 raises FR-ONB-02;
--                                                  Partner B under cap succeeds);
--                                                  e2e_licences_grants.sql;
--                                                  team-licence.spec.ts tile.
--  08  publish v1.1; running stay on v1.0;          HERE §08 (publish-if-draft by
--      apply to chosen programmes w/o loss          content author, pin check, apply
--                                                  merge keeps progress); deep:
--                                                  e2e_template_engine.sql,
--                                                  e2e_programme_lifecycle.sql.
--  09  UK pack DSR due date (28d, not ZA 30d)       HERE §09 (record_dsr on C2 + the
--                                                  seeded UK DSR row); deep:
--                                                  e2e_rules_engine.sql §9.7,
--                                                  e2e_ops_registers.sql.
--  10  tracker import reconciled at same date       PARTIAL — HERE §10 (P1's
--                                                  deterministic week/date math —
--                                                  the values a reconciliation
--                                                  recomputes); e2e_import_framework
--                                                  .sql (preview + rejects +
--                                                  provenance, FR-IMP-05).
--                                                  DEVIATION: reconciliation vs the
--                                                  real Excel tracker is W3-02 (#43)
--                                                  = BLOCKED-EXT per plan §8 (needs
--                                                  the real tracker + verified POPIA
--                                                  content).
--  11  activity 12 d late → Amber + weekly agenda   HERE §11 (activity_rag at due+12;
--                                                  weekly-log auto counts carry the
--                                                  overdue count); e2e_rules_engine.
--  12  same activity 17 d late → Red, AO notified,  HERE §12 (activity_rag Red;
--      partner console Red                          partner_console_rag forced Red);
--                                                  e2e_rules_engine. DEVIATION:
--                                                  "AO notified" — §10's
--                                                  activity-turns-Red recipient
--                                                  event has no kind in R1 (the
--                                                  daily sweep emits activity_due
--                                                  only on the due date; flagged).
--  13  upload → verify → AO accept → Closed         HERE §13 (live chain EV1 verify
--                                                  + AO accept minting the EV ref,
--                                                  plus the seeded worked example
--                                                  R-04); deep: e2e_evidence_chain
--                                                  .sql CHAIN 1/2.
--  14  uploader cannot verify/accept own evidence   HERE §14 (RPC refusal on both
--                                                  stages); deep: e2e_evidence_chain
--                                                  .sql (RPC + review-gate trigger).
--  15  first business day → maintenance tasks;      HERE §15 (generate_maintenance_
--      active-from rule absent                      month for a fresh period: count,
--                                                  window due dates, MM-08 absent);
--                                                  deep: e2e_cadence.sql 01–06 +
--                                                  e2e_scheduler.sql (bd1 claim).
--  16  missed provider input → reminder/overdue/    HERE §16 (seeded Exception→RAID
--      RAID; report blocked w/o reason              link; ao_review refused, then
--                                                  allowed with gate_override_
--                                                  reason); deep: e2e_cadence.sql
--                                                  FR-MNT-07 + exception trigger,
--                                                  e2e_scheduler.sql §10
--                                                  maintenance_input_overdue.
--  17  post-snapshot changes leave issued report +  HERE §17 (UPDATE on issued report
--      figures unchanged                            refused; snapshot JSON intact);
--                                                  deep: e2e_rules_engine AT-17,
--                                                  e2e_report_builder.sql 36–37,
--                                                  e2e_snapshot_consolidation.sql.
--  18  monthly report in the partner's template     HERE §18 (issued report, template
--                                                  report_structure, partner
--                                                  report_template_refs);
--                                                  print-report.spec.ts (rendered,
--                                                  branded). PARTIAL: "Word file" →
--                                                  HTML→PDF per W3-03 (#104).
--  19  breach from a phone: all three roles         HERE §19 (staff record_breach →
--      alerted; AO-only decision                    breach_alert fan-out; PL + staff
--                                                  decision refused, AO allowed);
--                                                  deep: e2e_ops_registers.sql 06–10,
--                                                  e2e_notifications.sql §10 hard
--                                                  rule, mobile.spec.ts.
--  20  client exit: export + timed deletion +       PARTIAL — HERE §20 (export_
--      deletion certificate                         client_pack full export + its
--                                                  disclosure audit row; cross-
--                                                  tenant refused).
--                                                  DEVIATION: timed deletion +
--                                                  certificate are W4-04 (#51,
--                                                  open) — no exit machinery yet.
--  21  audit events cannot be edited/deleted        HERE §21 (UPDATE/DELETE on
--                                                  audit_log + any audit_events
--                                                  access refused, incl. platform
--                                                  admin); deep: e2e_audit_events
--                                                  .sql 16–17 + trigger battery.
--  22  awareness report = averages only             HERE §22 (real engine round-trip
--                                                  with named respondents → report
--                                                  contains no labels, no per-person
--                                                  answers — aggregates +
--                                                  respondent_no only, NFR-15).
--
-- Runs against the W0-05 TESTFIX world — apply the fixture pack first with
--   { echo "SET securepath.test_fixtures='on';";
--     cat app/supabase/migrations/20261105000005_test_fixtures.sql \
--         app/tests/e2e_acceptance.sql; } \
--   | psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0
-- JWT callers are simulated via SET ROLE authenticated + request.jwt.claims
-- (e2e_role_assignments.sql pattern). Ids created mid-scenario are handed
-- between callers via transaction-local GUCs (set_config) — writes stay
-- inside BEGIN…ROLLBACK so the fixture world is never mutated.
-- ============================================================================
\set QUIET on
\pset pager off
\pset tuples_only on
\o /dev/null

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- pg_temp.err(sql) runs one statement in a subtransaction; returns the error
-- text (NULL on success) — the fail-closed probe used throughout.
CREATE OR REPLACE FUNCTION pg_temp.err(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE q;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $$;

-- pg_temp.run(sql) runs a single-column SELECT and returns
-- {ok:true,v:<first value as text>} or {ok:false,err:<message>} — lets a DO
-- block call mutating RPCs without aborting the surrounding transaction.
CREATE OR REPLACE FUNCTION pg_temp.run(q text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE q INTO r;
  RETURN jsonb_build_object('ok', true, 'v', r);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'err', SQLERRM);
END $$;

DO $$ BEGIN
  RAISE NOTICE '==== W4-07 acceptance suite — AT-01..AT-22 vs TESTFIX ====';
END $$;

-- ============================================================================
-- AT-01  Partner A user aims at Partner B's client (C3 cc000005-…-003 /
--        programme P3 dd000005-…-003): everything must fail closed.
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE e text; v int;
BEGIN
  PERFORM pg_temp.t(
    (SELECT count(*) FROM public.client_orgs) = 2
    AND NOT EXISTS (SELECT 1 FROM public.client_orgs
                     WHERE id = 'cc000005-0000-0000-0000-000000000003'),
    'AT-01: partner A sees its two clients only — C3 absent');
  PERFORM pg_temp.t(
    NOT EXISTS (SELECT 1 FROM public.programmes
                 WHERE id = 'dd000005-0000-0000-0000-000000000003')
    AND NOT EXISTS (SELECT 1 FROM public.register_items
                     WHERE programme_id = 'dd000005-0000-0000-0000-000000000003')
    AND NOT EXISTS (SELECT 1 FROM public.activities
                     WHERE programme_id = 'dd000005-0000-0000-0000-000000000003'),
    'AT-01: P3 + its register/activity rows invisible by exact id');
  UPDATE public.activities SET pct_complete = 99
   WHERE id = 'd3000005-0000-0000-0000-000000000021';
  GET DIAGNOSTICS v = ROW_COUNT;
  PERFORM pg_temp.t(v = 0, 'AT-01: cross-partner UPDATE silently touches 0 rows');
  e := pg_temp.err($q$SELECT public.export_register_items(
                     'dd000005-0000-0000-0000-000000000003')$q$);
  PERFORM pg_temp.t(e IS NOT NULL,
    'AT-01: cross-partner export RPC refused: ' || coalesce(e,'(none)'));
  e := pg_temp.err($q$INSERT INTO public.operational_records
                     (client_org_id, type, description)
                   VALUES ('cc000005-0000-0000-0000-000000000003','dsr','AT-01 probe')$q$);
  PERFORM pg_temp.t(e IS NOT NULL AND (e LIKE '%row-level security%' OR e LIKE '%policy%'),
    'AT-01: cross-partner INSERT fails closed: ' || coalesce(e,'(none)'));
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN
  RAISE NOTICE 'AT-01 note: "attempt logged" is not implemented in R1 — refusals are fail-closed but unrecorded (see header)';
END $$;

-- ============================================================================
-- AT-02  Consultant assigned to client 1 only: console + reads = C1/P1 only.
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
BEGIN
  PERFORM pg_temp.t(
    (SELECT count(*) FROM public.list_programmes()) = 1
    AND (SELECT programme_id FROM public.list_programmes())
          = 'dd000005-0000-0000-0000-000000000001',
    'AT-02: partner console lists only the assigned client''s programme (P1)');
  PERFORM pg_temp.t(
    (SELECT count(*) FROM public.client_orgs) = 1
    AND EXISTS (SELECT 1 FROM public.client_orgs
                 WHERE id = 'cc000005-0000-0000-0000-000000000001'),
    'AT-02: consultant sees client 1 only (C2 same-partner still hidden)');
  PERFORM pg_temp.t(
    NOT EXISTS (SELECT 1 FROM public.activities
                 WHERE programme_id = 'dd000005-0000-0000-0000-000000000002'),
    'AT-02: C2''s programme (same partner, unassigned) is invisible');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-03  SecurePath support (U3: dormant client-scope assignment, only an
--        EXPIRED grant f4000005-…-001) opens a client programme — not possible.
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  PERFORM pg_temp.t(
    (SELECT count(*) FROM public.allowed_client_orgs()) = 0,
    'AT-03: expired grant + dormant assignment → empty allowed_client_orgs');
  PERFORM pg_temp.t(
    NOT EXISTS (SELECT 1 FROM public.operational_records
                 WHERE client_org_id = 'cc000005-0000-0000-0000-000000000001')
    AND (SELECT count(*) FROM public.list_programmes()) = 0,
    'AT-03: no C1 register rows, no programmes — opening is impossible');
  e := pg_temp.err($q$SELECT public.export_client_pack(
                     'cc000005-0000-0000-0000-000000000001')$q$);
  PERFORM pg_temp.t(e IS NOT NULL,
    'AT-03: definer-RPC path refuses too: ' || coalesce(e,'(none)'));
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-04  Support access granted for 24 h: request → client-side approve →
--        branch-(e) access → client-visible grant → window ends → access dies.
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.request_support_access(
      'cc000005-0000-0000-0000-000000000001',
      'AT-04: investigation window (default = now()+24h)')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-04: support filed the access request'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM set_config('at.req', j->>'v', true);
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.approve_support_grant(
      current_setting('at.req', true)::uuid)::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-04: the client AO approved the 24 h window'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM set_config('at.grant', j->>'v', true);
  PERFORM pg_temp.t(
    EXISTS (SELECT 1 FROM public.support_access_grants
             WHERE id = (j->>'v')::uuid
               AND securepath_user_id = 'aa000005-0000-0000-0000-000000000003'
               AND starts_at <= now() AND expires_at > now()
               AND revoked_at IS NULL),
    'AT-04: approved 24 h grant row visible to the client (FR-PLT-04)');
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
BEGIN
  PERFORM pg_temp.t(
    EXISTS (SELECT 1 FROM public.operational_records
             WHERE client_org_id = 'cc000005-0000-0000-0000-000000000001'),
    'AT-04: in-window grant opens the client''s records to support');
END $$;
RESET ROLE;  -- back to admin inside the same txn to close the window
UPDATE public.support_access_grants
   SET starts_at = now() - interval '25 hours',
       expires_at = now() - interval '1 hour'   -- CHECK: expires_at > starts_at
 WHERE id = current_setting('at.grant', true)::uuid;
SET ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.t(
    NOT EXISTS (SELECT 1 FROM public.operational_records
                 WHERE client_org_id = 'cc000005-0000-0000-0000-000000000001'),
    'AT-04: once the window ends, access ends (time alone, no revocation)');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM pg_trigger tg
           JOIN pg_class c ON c.oid = tg.tgrelid
          WHERE c.relname = 'support_access_grants' AND NOT tg.tgisinternal),
  'AT-04: grant actions are ledger-captured (audit trigger on the table; per-action audit coverage in e2e_support_access.sql)');

-- ============================================================================
-- AT-05  Partner branding: A fully branded, B unaffected.
--        (Sign-in-by-host + Word/email legs: see header PARTIAL note.)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.partner_branding(
      'cc000005-0000-0000-0000-000000000001')::text$q$);
  PERFORM pg_temp.t(
    (j->>'ok')::boolean
    AND (j->>'v')::jsonb->>'name' = 'TESTFIX Partner A'
    AND (j->>'v')::jsonb->>'logo_url' = 'https://testfix.invalid/partner-a/logo.png'
    AND lower((j->>'v')::jsonb->>'accent_hex') = '#2255aa'
    AND (j->>'v')::jsonb->>'subdomain' = 'testfix-a'
    AND (j->>'v')::jsonb->>'sign_in_text' IS NOT NULL
    AND (j->>'v')::jsonb->>'email_sender_name' = 'TESTFIX Partner A',
    'AT-05: partner_branding serves A''s logo/colour/subdomain/sender end-to-end');
  j := pg_temp.run($q$SELECT public.partner_branding(
      'cc000005-0000-0000-0000-000000000003')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean AND j->>'v' IS NULL,
    'AT-05: partner A cannot read partner B''s client brand (isolation leg)');
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.partner_branding(
      'cc000005-0000-0000-0000-000000000003')::text$q$);
  PERFORM pg_temp.t(
    (j->>'ok')::boolean
    AND (j->>'v')::jsonb->>'name' = 'TESTFIX Partner B'
    AND lower((j->>'v')::jsonb->>'accent_hex') = '#7a3b2e'
    AND (j->>'v')::jsonb->>'subdomain' = 'testfix-b',
    'AT-05: partner B unaffected — own brand resolves on its own client');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;
SELECT pg_temp.t(
  (SELECT report_template_refs->>'word' FROM public.practices
    WHERE id = 'bb000005-0000-0000-0000-000000000001') IS NOT NULL,
  'AT-05: partner A report template refs seeded (render proof in print-report.spec.ts)');

-- AT-06: UI-only — the WCAG flag lives in BrandingForm (FR-BRN-07); proven in
-- web/e2e/acceptance.spec.ts ("AT-06: a sub-AA accent colour is flagged").

-- ============================================================================
-- AT-07  Programme beyond the licence limit → blocked (Partner A at 2/2).
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE e text; j jsonb;
BEGIN
  e := pg_temp.err($q$SELECT public.create_programme(
      'cc000005-0000-0000-0000-000000000001',
      'f6000005-0000-0000-0000-000000000001',
      'AT-07 over-limit programme', DATE '2026-11-02')$q$);
  PERFORM pg_temp.t(e LIKE '%limit reached%' OR e LIKE '%licence%',
    'AT-07: create_programme at the cap refused with the licence message: '
    || coalesce(e,'(none)'));
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.create_programme(
      'cc000005-0000-0000-0000-000000000003',
      'f6000005-0000-0000-0000-000000000001',
      'AT-07 under-limit programme', DATE '2026-11-02')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean,
    'AT-07: partner B under the cap creates fine (control — rolls back)'
    || coalesce(' — '||(j->>'err'),''));
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-08  Publish v1.1 → running programmes stay on v1.0 → partner applies it
--        to a chosen programme without losing progress. Order-insensitive:
--        publishes only when v1.1 is still a draft (a sibling suite may have
--        published it already); everything rolls back.
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  IF (SELECT status FROM public.programme_template_versions
       WHERE id = 'f6000005-0000-0000-0000-000000000002') = 'draft' THEN
    e := pg_temp.err($q$SELECT public.publish_template_version(
        'f6000005-0000-0000-0000-000000000002')$q$);
    PERFORM pg_temp.t(e IS NULL, 'AT-08: content author published template v1.1'
      || coalesce(' — '||e,''));
  ELSE
    PERFORM pg_temp.t(
      (SELECT status FROM public.programme_template_versions
        WHERE id = 'f6000005-0000-0000-0000-000000000002') = 'published',
      'AT-08: v1.1 already published by an earlier run — publish leg proven there');
  END IF;
END $$;
RESET ROLE;  -- world-state read: a content-author claim sees no programmes
DO $$
BEGIN
  PERFORM pg_temp.t(
    (SELECT count(*) FROM public.programmes
      WHERE id IN ('dd000005-0000-0000-0000-000000000001',
                   'dd000005-0000-0000-0000-000000000002',
                   'dd000005-0000-0000-0000-000000000003')
        AND template_version_id = 'f6000005-0000-0000-0000-000000000001') = 3,
    'AT-08: running programmes stay pinned to v1.0 after the publish');
END $$;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.t(
    EXISTS (SELECT 1 FROM public.programme_template_versions
             WHERE id = 'f6000005-0000-0000-0000-000000000002'
               AND status = 'published' AND release_notes LIKE '%v1.1%'),
    'AT-08: partner reads the published v1.1 and its change notes');
  j := pg_temp.run($q$SELECT public.apply_template_version(
      'dd000005-0000-0000-0000-000000000003',
      'f6000005-0000-0000-0000-000000000002')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean,
    'AT-08: partner applied v1.1 to the chosen programme'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM pg_temp.t(
    (SELECT template_version_id FROM public.programmes
      WHERE id = 'dd000005-0000-0000-0000-000000000003')
          = 'f6000005-0000-0000-0000-000000000002',
    'AT-08: chosen programme moved to v1.1');
  PERFORM pg_temp.t(
    (SELECT status FROM public.activities
      WHERE id = 'd3000005-0000-0000-0000-000000000021') = 'In progress'
    AND (SELECT pct_complete FROM public.activities
      WHERE id = 'd3000005-0000-0000-0000-000000000021') = 50
    AND EXISTS (SELECT 1 FROM public.activities
                 WHERE programme_id = 'dd000005-0000-0000-0000-000000000003'
                   AND ref = 'A-09'),
    'AT-08: merge preserved in-flight work and added the new v1.1 activity');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-09  UK jurisdiction pack drives the DSR due date (28d, not ZA's 30d).
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000014","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.record_dsr(
      'cc000005-0000-0000-0000-000000000002',
      'access', DATE '2026-10-12', 'AT-09 probe')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-09: UK client-side user logged the DSR'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM pg_temp.t(
    (SELECT due_date FROM public.operational_records
      WHERE id = (j->>'v')::uuid) = DATE '2026-11-09',
    'AT-09: new UK DSR due = received + 28 (the UK pack, 2026-10-12 → 11-09)');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;
SELECT pg_temp.t(
  public.operational_due_date('eb000005-0000-0000-0000-000000000011')
    = DATE '2026-11-09',
  'AT-09: the seeded open UK DSR resolves through the UK pack');
SELECT pg_temp.t(
  public.jurisdiction_deadline('ZA','data_subject_request','2026-10-12'::timestamptz)
    = DATE '2026-11-11'
  AND public.jurisdiction_deadline('UK','data_subject_request','2026-10-12'::timestamptz)
    = DATE '2026-11-09',
  'AT-09: same received date → ZA 30 cal days vs UK 28 cal days (pack-driven, never hard-coded)');

-- ============================================================================
-- AT-10  Tracker reconciliation — deterministic math the import must
--        reproduce (reconciliation itself: BLOCKED-EXT, W3-02 #43 — header).
-- ============================================================================
SELECT pg_temp.t(
  public.programme_week('dd000005-0000-0000-0000-000000000001', DATE '2026-09-07') = 1
  AND public.week_due_date('dd000005-0000-0000-0000-000000000001', 1) = DATE '2026-09-11'
  AND extract(isodow FROM public.week_due_date('dd000005-0000-0000-0000-000000000001', 1)) = 5,
  'AT-10: week 1 starts Mon 2026-09-07; due dates land on the Friday');
SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM public.activities a
               WHERE a.programme_id = 'dd000005-0000-0000-0000-000000000001'
                 AND a.due_date IS DISTINCT FROM
                     public.week_due_date(a.programme_id, a.end_week)),
  'AT-10: every seeded activity due date = week_due_date(end_week) — the math a tracker reconciliation rebuilds');

-- ============================================================================
-- AT-11  Activity due in week 4, still In progress 12 days later → Amber and
--        on the weekly agenda as overdue. (A-02: due 2026-10-02 = week 4.)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.t(
    public.activity_rag('d3000005-0000-0000-0000-000000000002',
                        DATE '2026-10-02' + 12) = 'Amber',
    'AT-11: A-02 In progress 12 days past due → Amber (≤14-day band)');
  -- the weekly agenda surface: upsert_weekly_log's auto counts carry overdue
  j := pg_temp.run($q$SELECT public.upsert_weekly_log(
      'dd000005-0000-0000-0000-000000000001', 5, '{}'::jsonb)::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-11: weekly log upsert ran'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM pg_temp.t(
    (SELECT (counts->>'overdue')::int FROM public.weekly_logs
      WHERE id = (j->>'v')::uuid)
    = (SELECT count(*) FROM public.activities
        WHERE programme_id = 'dd000005-0000-0000-0000-000000000001'
          AND status <> 'Complete' AND due_date IS NOT NULL
          AND due_date < CURRENT_DATE)
    AND (SELECT (counts->>'overdue')::int FROM public.weekly_logs
      WHERE id = (j->>'v')::uuid) > 0,
    'AT-11: weekly agenda counts carry the overdue work (past-due, not Complete)');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-12  Same activity 17 days late → Red; partner console shows Red.
--        ("AO notified" leg: no R1 event kind — see header DEVIATION.)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
BEGIN
  PERFORM pg_temp.t(
    public.activity_rag('d3000005-0000-0000-0000-000000000002',
                        DATE '2026-10-02' + 17) = 'Red',
    'AT-12: A-02 In progress 17 days past due → Red (>14-day threshold)');
  PERFORM pg_temp.t(
    public.partner_console_rag('dd000005-0000-0000-0000-000000000001',
                               '2026-11-05'::timestamptz) = 'Red',
    'AT-12: partner console shows the programme Red (report-fed task overdue → forced Red)');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN
  RAISE NOTICE 'AT-12 note: "accountable officer notified" — no R1 event kind for activity-turns-Red (see header)';
END $$;

-- ============================================================================
-- AT-13  Upload → programme-lead verify → AO accept → finding Closed with
--        date/user/evidence refs. Live chain on EV1 + the seeded worked
--        example (R-04 Closed with EV-R-04-001).
-- ============================================================================
SELECT pg_temp.t(
  (SELECT status FROM public.register_items
    WHERE id = 'd4000005-0000-0000-0000-000000000004') = 'Closed'
  AND (SELECT accepted_by FROM public.register_items
    WHERE id = 'd4000005-0000-0000-0000-000000000004')
        = 'aa000005-0000-0000-0000-000000000008'
  AND (SELECT accepted_on FROM public.register_items
    WHERE id = 'd4000005-0000-0000-0000-000000000004') IS NOT NULL
  AND (SELECT accepted_evidence_refs FROM public.register_items
    WHERE id = 'd4000005-0000-0000-0000-000000000004')
        @> '{EV-R-04-001}'::text[],
  'AT-13 (worked example): R-04 Closed with date, accepting user and EV ref');
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$SELECT public.verify_evidence(
      'e1000005-0000-0000-0000-000000000001','approved','AT-13 checklist pass')$q$);
  PERFORM pg_temp.t(e IS NULL, 'AT-13: programme lead verified the upload'
    || coalesce(' — '||e,''));
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.accept_evidence(
      'e1000005-0000-0000-0000-000000000001')->>'evidence_ref'$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-13: AO accepted the verified evidence'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM pg_temp.t(j->>'v' LIKE 'EV-R-01-%',
    'AT-13: AO accept minted the finding-scoped evidence ref ('
    || coalesce(j->>'v','none') || ')');
  PERFORM pg_temp.t(
    (SELECT review_stage FROM public.evidence_items
      WHERE id = 'e1000005-0000-0000-0000-000000000001') = 'decided'
    AND (SELECT status FROM public.register_items
      WHERE id = 'd4000005-0000-0000-0000-000000000001') = 'In progress',
    'AT-13: accepted evidence decided; R-01 stays open until linked activities complete (§9.4)');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-14  The uploader may never verify or accept their own evidence.
--        EV1 (verification) + EV2 (acceptance) were both uploaded by U10.
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000010","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$SELECT public.verify_evidence(
                     'e1000005-0000-0000-0000-000000000001','approved')$q$);
  PERFORM pg_temp.t(e LIKE '%uploaded%',
    'AT-14: uploader self-verify refused: ' || coalesce(e,'(none)'));
  e := pg_temp.err($q$SELECT public.accept_evidence(
                     'e1000005-0000-0000-0000-000000000002')$q$);
  PERFORM pg_temp.t(e LIKE '%uploaded%',
    'AT-14: uploader self-accept refused: ' || coalesce(e,'(none)'));
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-15  First business day → generate_maintenance_month: correct due dates,
--        MM-08 (unmet active_from_rule) absent. Fresh period 2026-12, rolled
--        back — the cadence suite owns 2026-10/11.
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.generate_maintenance_month(
      'dd000005-0000-0000-0000-000000000001', DATE '2026-12-02')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean AND (j->>'v')::int = 4,
    'AT-15: first-business-day generation creates the 4 due tasks (MM-08 skipped)'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM pg_temp.t(
    EXISTS (SELECT 1 FROM public.maintenance_task_instances
             WHERE task_template_id = 'e8000005-0000-0000-0000-000000000001'
               AND period = '2026-12'
               AND due_date = public.last_business_day('ZA', DATE '2026-12-01')
               AND task_window = 'before_month_end' AND status = 'Pending')
    AND EXISTS (SELECT 1 FROM public.maintenance_task_instances
             WHERE task_template_id = 'e8000005-0000-0000-0000-000000000005'
               AND period = '2026-12'
               AND due_date = public.nth_business_day('ZA', DATE '2027-01-01', 5)
               AND task_window = 'report_window'),
    'AT-15: window due dates resolved (month-end + report-window business day 5)');
  PERFORM pg_temp.t(
    NOT EXISTS (SELECT 1 FROM public.maintenance_task_instances
                 WHERE task_template_id = 'e8000005-0000-0000-0000-000000000004'
                   AND period = '2026-12'),
    'AT-15: MM-08 absent — its active_from rule (A-08 complete) is unmet');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-16  Missed provider input → reminder→overdue (scheduler), RAID issue
--        (seeded link), and the report cannot enter review without a recorded
--        reason (FR-MNT-07 gate on the seeded 2026-10 draft).
-- ============================================================================
SELECT pg_temp.t(
  (SELECT status FROM public.maintenance_task_instances
    WHERE id = 'e9000005-0000-0000-0000-000000000003') = 'Exception'
  AND (SELECT exception_raid_item_id FROM public.maintenance_task_instances
    WHERE id = 'e9000005-0000-0000-0000-000000000003')
        = 'e5000005-0000-0000-0000-000000000002'
  AND (SELECT type FROM public.raid_items
    WHERE id = 'e5000005-0000-0000-0000-000000000002') = 'issue'
  AND (SELECT status FROM public.raid_items
    WHERE id = 'e5000005-0000-0000-0000-000000000002') = 'Open',
  'AT-16: the missed MM-06 input is an Exception bound to an open RAID issue');
BEGIN;
-- normalise the 2026-10 draft to 'draft' along the two legal back-edges, so
-- the gate check holds even where an earlier run moved it forward
UPDATE public.programme_reports SET status = 'inputs_complete'
 WHERE id = 'f1000005-0000-0000-0000-000000000002' AND status = 'ao_review';
UPDATE public.programme_reports SET status = 'draft'
 WHERE id = 'f1000005-0000-0000-0000-000000000002' AND status = 'inputs_complete';
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$UPDATE public.programme_reports SET status = 'inputs_complete'
                     WHERE id = 'f1000005-0000-0000-0000-000000000002'$q$);
  PERFORM pg_temp.t(e IS NULL,
    'AT-16: draft → inputs_complete walks the legal edge' || coalesce(' — '||e,''));
  e := pg_temp.err($q$UPDATE public.programme_reports SET status = 'ao_review'
                     WHERE id = 'f1000005-0000-0000-0000-000000000002'$q$);
  PERFORM pg_temp.t(e LIKE '%cannot go to review%',
    'AT-16: report blocked from review while feeding tasks are open: ' || coalesce(e,'(none)'));
  e := pg_temp.err($q$UPDATE public.programme_reports
                     SET status = 'ao_review',
                         gate_override_reason = 'AT-16 recorded reason — provider input late'
                     WHERE id = 'f1000005-0000-0000-0000-000000000002'$q$);
  PERFORM pg_temp.t(e IS NULL,
    'AT-16: a recorded reason opens the review gate' || coalesce(' — '||e,''));
  PERFORM pg_temp.t(
    (SELECT status FROM public.programme_reports
      WHERE id = 'f1000005-0000-0000-0000-000000000002') = 'ao_review',
    'AT-16: ao_review reached with the recorded reason');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-17  After the month-end snapshot, nothing changes the issued report or
--        the stored figures.
-- ============================================================================
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$UPDATE public.programme_reports SET overall_rag = 'Green'
                     WHERE id = 'f1000005-0000-0000-0000-000000000001'$q$);
  PERFORM pg_temp.t(e IS NOT NULL,
    'AT-17: issued report row refuses edits (§9.5 gate): ' || coalesce(e,'(none)'));
END $$;
SELECT pg_temp.t(
  (SELECT snapshot->>'rag' FROM public.monthly_snapshots
    WHERE id = 'ef000005-0000-0000-0000-000000000001') = 'Amber'
  AND (SELECT sections->>'executive_summary' FROM public.programme_reports
    WHERE id = 'f1000005-0000-0000-0000-000000000001')
        LIKE 'TESTFIX Two findings closed%',
  'AT-17: snapshot + issued sections hold the month-end figures');

-- ============================================================================
-- AT-18  Monthly report = the partner's template structure. (Word → HTML/PDF
--        per W3-03; render+brand proven in print-report.spec.ts.)
-- ============================================================================
SELECT pg_temp.t(
  (SELECT status FROM public.programme_reports
    WHERE id = 'f1000005-0000-0000-0000-000000000001') = 'issued'
  AND (SELECT bool_and(r.key IN (SELECT s2->>'key'
          FROM jsonb_array_elements(
                 (SELECT content->'report_structure'->'sections'
                   FROM public.programme_template_versions
                    WHERE id = 'f6000005-0000-0000-0000-000000000001')) s2))
        FROM jsonb_object_keys(
               (SELECT sections FROM public.programme_reports
                 WHERE id = 'f1000005-0000-0000-0000-000000000001')) r(key)),
  'AT-18: issued report sections follow the template''s report_structure');
SELECT pg_temp.t(
  (SELECT report_template_refs->>'word' FROM public.practices
    WHERE id = 'bb000005-0000-0000-0000-000000000001')
        = 'testfix/partner-a/report.docx',
  'AT-18: the issuing partner''s report template is bound on the partner row');

-- ============================================================================
-- AT-19  Staff reports a suspected breach (the seeded row arrived by
--        'mobile'): PL + AO + partner consultant alerted at once; only the AO
--        may record the notification decision.
-- ============================================================================
SELECT pg_temp.t(
  (SELECT channel FROM public.operational_records
    WHERE id = 'eb000005-0000-0000-0000-000000000002') = 'mobile'
  AND (SELECT status FROM public.operational_records
    WHERE id = 'eb000005-0000-0000-0000-000000000002') = 'Awaiting decision'
  AND (SELECT regulator_notification FROM public.operational_records
    WHERE id = 'eb000005-0000-0000-0000-000000000002') IS NULL,
  'AT-19: seeded mobile-reported breach sits Awaiting decision, decision still NULL');
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000012","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.record_breach(
      'cc000005-0000-0000-0000-000000000001',
      '2026-10-09 07:30+00'::timestamptz, 'AT-19 suspected breach')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-19: staff member filed the breach report'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM set_config('at.breach', j->>'v', true);
  PERFORM pg_temp.t(
    (SELECT status FROM public.operational_records
      WHERE id = (j->>'v')::uuid) = 'Awaiting decision',
    'AT-19: report lands Awaiting decision');
END $$;
RESET ROLE;
DO $$
BEGIN
  PERFORM pg_temp.t(
    EXISTS (SELECT 1 FROM public.notification_events
             WHERE kind = 'breach_alert'
               AND (payload->>'record_id')::uuid
                     = current_setting('at.breach', true)::uuid
               AND payload->>'timing' = 'immediate'
               AND payload->'recipients' @>
                     '["aa000005-0000-0000-0000-000000000005",
                       "aa000005-0000-0000-0000-000000000008",
                       "aa000005-0000-0000-0000-000000000009"]'::jsonb),
    'AT-19: immediate breach_alert fans out to consultant + AO + programme lead');
END $$;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$SELECT public.record_breach_decision(
      current_setting('at.breach', true)::uuid, 'notified', 'nope')$q$);
  PERFORM pg_temp.t(e LIKE '%accountable officer%',
    'AT-19: programme lead cannot record the decision: ' || coalesce(e,'(none)'));
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT public.record_breach_decision(
      current_setting('at.breach', true)::uuid, 'notified', 'AT-19 IO decision')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-19: AO records the decision'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM pg_temp.t(
    (SELECT regulator_notification->>'decision' FROM public.operational_records
      WHERE id = current_setting('at.breach', true)::uuid) = 'notified'
    AND (SELECT status FROM public.operational_records
      WHERE id = current_setting('at.breach', true)::uuid) = 'In progress',
    'AT-19: the accountable officer — and only the AO — records the decision');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-20  Client exit — PARTIAL (W4-04 #51 open): the full export leg runs
--        here; timed deletion + certificate are not built (see header).
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE j jsonb;
BEGIN
  j := pg_temp.run($q$SELECT count(*)::text
      FROM public.export_client_pack('cc000005-0000-0000-0000-000000000003')$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean AND (j->>'v')::int >= 1,
    'AT-20 (partial): client pack export produces the client''s programme/report rows'
    || coalesce(' — '||(j->>'err'),''));
  PERFORM pg_temp.t(
    EXISTS (SELECT 1 FROM public.audit_log
             WHERE action = 'export.client_pack'
               AND detail->>'client_org_id' = 'cc000005-0000-0000-0000-000000000003'),
    'AT-20 (partial): the export wrote its disclosure audit row');
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$SELECT public.export_client_pack(
                     'cc000005-0000-0000-0000-000000000003')$q$);
  PERFORM pg_temp.t(e IS NOT NULL,
    'AT-20: another partner cannot pull the exiting client''s pack');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;
DO $$ BEGIN
  RAISE NOTICE 'AT-20 note: timed deletion + deletion certificate pending W4-04 (#51) — export leg proven here';
END $$;

-- ============================================================================
-- AT-21  Nobody — not even a platform admin — can edit or delete an audit
--        event. (audit_log is REVOKEd UPDATE/DELETE; audit_events grants
--        nothing at all.)
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$UPDATE public.audit_log SET detail = detail$q$);
  PERFORM pg_temp.t(e LIKE '%permission denied%',
    'AT-21: UPDATE on audit_log refused: ' || coalesce(e,'(none)'));
  e := pg_temp.err($q$DELETE FROM public.audit_log$q$);
  PERFORM pg_temp.t(e LIKE '%permission denied%',
    'AT-21: DELETE on audit_log refused: ' || coalesce(e,'(none)'));
  e := pg_temp.err($q$SELECT count(*) FROM public.audit_events$q$);
  PERFORM pg_temp.t(e LIKE '%permission denied%',
    'AT-21: tenant user cannot even SELECT audit_events');
END $$;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$SELECT count(*) FROM public.audit_events$q$);
  PERFORM pg_temp.t(e LIKE '%permission denied%',
    'AT-21: platform admin gets no audit_events access either');
  e := pg_temp.err($q$DELETE FROM public.audit_log$q$);
  PERFORM pg_temp.t(e LIKE '%permission denied%',
    'AT-21: platform admin cannot delete audit_log rows');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

-- ============================================================================
-- AT-22  Awareness check report — averages only. Full engine round-trip with
--        deliberately named respondents, then a byte-level hunt for any leak
--        of names, labels or individual answers in the report JSON.
--        Caller = U4 partner_admin (practice_owner): the client-scoped
--        consultant's compat shim leaves current_practice() NULL, which the
--        completion-time record_approval guard rejects.
-- ============================================================================
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"aa000005-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE j jsonb; cid uuid; r1 uuid; r2 uuid; rep text;
BEGIN
  j := pg_temp.run($q$SELECT public.create_awareness_cohort(
      'cc000005-0000-0000-0000-000000000001','AT-22 Engineering')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-22: advisor created the interview cohort'
    || coalesce(' — '||(j->>'err'),''));
  cid := (j->>'v')::uuid;

  j := pg_temp.run(format($q$SELECT (public.add_awareness_respondent(
      '%s'::uuid,'Alice Example'))->>'id'$q$, cid));
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-22: respondent 1 added'
    || coalesce(' — '||(j->>'err'),''));
  r1 := (j->>'v')::uuid;
  j := pg_temp.run(format($q$SELECT (public.add_awareness_respondent(
      '%s'::uuid,'Bob Sample'))->>'id'$q$, cid));
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-22: respondent 2 added'
    || coalesce(' — '||(j->>'err'),''));
  r2 := (j->>'v')::uuid;

  j := pg_temp.run(format($q$SELECT public.record_awareness_responses(
      '%s'::uuid,
      (SELECT jsonb_agg(jsonb_build_object('question_id', q.id, 'answer', 'yes'))
        FROM (SELECT id FROM public.awareness_questions
               WHERE content_pack_id = (SELECT cp.id FROM public.content_packs cp
                   WHERE cp.framework_key = 'popia' AND cp.status = 'published'
                     AND cp.practice_id IS NULL
                     AND EXISTS (SELECT 1 FROM public.awareness_questions x
                                  WHERE x.content_pack_id = cp.id AND x.active)
                   ORDER BY cp.version DESC LIMIT 1)
                 AND active ORDER BY question_number LIMIT 3) q))::text$q$,
      r1, cid));
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-22: respondent 1 answers recorded'
    || coalesce(' — '||(j->>'err'),''));
  j := pg_temp.run(format($q$SELECT public.record_awareness_responses(
      '%s'::uuid,
      (SELECT jsonb_agg(jsonb_build_object('question_id', q.id, 'answer',
                                           CASE WHEN q.rn = 1 THEN 'no' ELSE 'yes' END))
        FROM (SELECT id, row_number() OVER (ORDER BY question_number) AS rn
               FROM public.awareness_questions
               WHERE content_pack_id = (SELECT cp.id FROM public.content_packs cp
                   WHERE cp.framework_key = 'popia' AND cp.status = 'published'
                     AND cp.practice_id IS NULL
                     AND EXISTS (SELECT 1 FROM public.awareness_questions x
                                  WHERE x.content_pack_id = cp.id AND x.active)
                   ORDER BY cp.version DESC LIMIT 1)
                 AND active ORDER BY question_number LIMIT 3) q))::text$q$,
      r2, cid));
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-22: respondent 2 answers recorded'
    || coalesce(' — '||(j->>'err'),''));

  j := pg_temp.run(format($q$SELECT public.complete_awareness_cohort('%s'::uuid)::text$q$, cid));
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-22: cohort completed — results locked'
    || coalesce(' — '||(j->>'err'),''));

  j := pg_temp.run($q$SELECT public.get_awareness_report(
      'cc000005-0000-0000-0000-000000000001','popia')::text$q$);
  PERFORM pg_temp.t((j->>'ok')::boolean, 'AT-22: get_awareness_report ran'
    || coalesce(' — '||(j->>'err'),''));
  rep := j->>'v';

  PERFORM pg_temp.t(
    (rep::jsonb->>'available')::boolean
    AND (rep::jsonb->'coverage'->>'cohorts_completed')::int >= 2,
    'AT-22: report available, pooling completed cohorts');
  PERFORM pg_temp.t(
    rep NOT LIKE '%Alice%' AND rep NOT LIKE '%Bob%'
    AND rep NOT LIKE '%TESTFIX-R%' AND rep NOT LIKE '%@%',
    'AT-22: no names, labels or emails anywhere in the report JSON');
  PERFORM pg_temp.t(
    rep NOT LIKE '%"answer"%' AND rep NOT LIKE '%"note"%',
    'AT-22: no individual responses — aggregate counts/pcts only');
  PERFORM pg_temp.t(
    (rep::jsonb->'overall') ? 'pct' AND (rep::jsonb->'overall') ? 'rating',
    'AT-22: the report carries the pooled averages');
END $$;
ROLLBACK;
RESET ROLE; RESET request.jwt.claims;

DO $$ BEGIN
  RAISE NOTICE '==== W4-07 acceptance suite complete — see file header for the AT→coverage map and PARTIAL/DEVIATION notes (AT-01 logged leg, AT-05 sign-in/Word legs, AT-10 reconciliation, AT-12 AO-notify, AT-20 deletion) ====';
END $$;
