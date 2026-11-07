-- ============================================================================
-- W0-05 — AT-SUITE FIXTURE PACK  *** TEST DATA ONLY ***
-- (GitHub #14 · spec SP-SPC-PLT-001 §5.1/§5.4/§9/§14 + Annex A ·
--  plan BUILD_PLAN_R1 W0-05)
-- ============================================================================
--
-- Everything in this file is TEST DATA for the §14 acceptance-test suite.
-- It must NEVER run against staging/production:
--
--   * It is a no-op unless the database opts in with the custom setting
--         securepath.test_fixtures = 'on'
--     Enable once per test database:
--         ALTER DATABASE <dbname> SET securepath.test_fixtures = 'on';
--     or for a single psql session before running this file:
--         SET securepath.test_fixtures = 'on';
--   * It also no-ops (with a NOTICE) when the schema it seeds is absent —
--     it applies AFTER the W0-01 platform tier (jurisdiction_packs,
--     licences, designations, support_access_grants, entity ALTERs), the
--     W0-02 programme engine (programmes et al.) and, for §5 below, the
--     W0-03 template engine (programme_templates[_versions]).
--
-- LABELLING / WIPE CONTRACT (hard rules for this file):
--   * Every seeded entity is named 'TESTFIX%'; every fixture user is
--     *@testfix.test; fixture uuids all contain '000005'.
--   * Jurisdiction-pack values carry "_fixture" markers inside their jsonb
--     and keep version = 0 (the "unverified shell" version). They are
--     structurally real but UNVERIFIED TEST VALUES — never verified law
--     (§5.4: SecurePath enters and verifies every authoritative value).
--   * WIPE: run the DELETEs in §0 below (clients → practices → auth.users;
--     cascades clear every programme/client-scope child row, role
--     assignments and designations), plus the jurisdiction-pack shell
--     reset documented at the foot of this file.
--   * EXCEPTION: the published fixture template version is an IMMUTABLE
--     RECORD (FR-TPL-02 — published versions can never be deleted, by any
--     path). It stays, clearly labelled TESTFIX and inert; the draft
--     version deletes normally. This is the spec invariant winning over
--     wipe-ability — documented, not a bug.
--
-- SIMPLEST-CORRECT-READING notes (ambiguities resolved for fixtures):
--   * "Consultant assigned to client 1 only" → a single client-scope
--     partner_consultant row (NO partner-scope row: has_programme_role
--     would then widen writes to every partner-A programme — the client-
--     scope-only assignment is the narrowest correct reading).
--   * Calc/write-protected columns (due_date, rag, days_overdue,
--     review_stage, accepted_*, due_on, snapshot contents) are seeded with
--     plausible fixture values; the engine (W1-01/W1-09) owns them at run
--     time and will recompute. operational_records.due_date is left NULL
--     because §9.7 says the engine resolves it from the jurisdiction pack —
--     that IS the AT-09 precondition.
--   * operational_records.due_date / mti.due_date etc. seeded where a
--     fixed expectation is more useful than NULL.
--   * AO-alternate probe quirk: holds_designation() looks for kind
--     'named_alternate' (its 'Deputy Information Officer'/'dio' strings do
--     not match the designations enum 'deputy_information_officer' — W0-01/
--     W0-02 mismatch, flagged). The fixture uses 'named_alternate', which
--     the probe does match.
--
-- AT-SCENARIO → FIXTURE MAPPING (what each scenario needs from this pack):
--   AT-01 cross-partner refusal   U4 (partner-A admin) vs TESTFIX Client
--                                 Three + P3 under Partner B.
--   AT-02 assigned-only console   U5 consultant row scoped to C1 only;
--                                 C2 exists under the same partner.
--   AT-03 support w/o grant       U3 'support' + dormant client-scope
--                                 assignment on C1 + only an EXPIRED grant.
--   AT-04 24h grant               same rows; test mints a fresh in-window
--                                 support_access_grants row on C1.
--   AT-05 partner branding        Partner A fully branded (logo, colours,
--                                 subdomain, senders, report refs); B plain.
--   AT-06 contrast warning        Partner A branding columns exist (W2-03
--                                 check runs app-side).
--   AT-07 licence limit           Partner A licence client_limit=2 AND
--                                 programme_limit=2, both fully used
--                                 (C1+C2 / P1+P2); Partner B under limits.
--   AT-08 publish v1.1            TESTFIX template: v1 PUBLISHED + pinned
--                                 on P1/P2/P3; v2 DRAFT (v1.1) to publish.
--   AT-09 UK pack deadlines       C2.jurisdiction='UK'; UK/ZA packs hold
--                                 DIFFERENT fixture deadline_params; C2 has
--                                 an open DSR awaiting due-date resolution.
--   AT-10 tracker reconciliation  P1 carries deterministic week/date math
--                                 (start 2026-09-07, Friday due dates).
--   AT-11 RAG amber               A-05 In progress, due 2026-10-23 — inside
--                                 the ≤14-day amber band at seed time.
--   AT-12 RAG red + notify        A-02 In progress, due 2026-10-02 — more
--                                 than the 14-day red threshold past due;
--                                 AO (U8) + consultant (U5) recipients.
--   AT-13 evidence → closed       U10 uploads / U9 verifies / U8 accepts;
--                                 R-01 open + A-03 evidence_required; a
--                                 worked example exists (EV3→R-04 Closed).
--   AT-14 self-review denied      EV1 uploaded_by U10 (and U12 rows).
--   AT-15 monthly task gen        P1 mtt MM-01/03/06/16 across all windows;
--                                 MM-08 carries an unmet active_from_rule.
--   AT-16 provider miss → RAID    mti MM-06 'Exception' → raid RI2; draft
--                                 report '2026-10' exists to block.
--   AT-17 snapshot immutability   issued report '2026-09' + snapshot row.
--   AT-18 Word in partner brand   Partner A report_template_refs + P1
--                                 report + template report_structure.
--   AT-19 breach from a phone     open 'breach' record on C1 reported_by
--                                 U12 (staff), channel 'mobile';
--                                 regulator_notification still NULL.
--   AT-20 client exit export      full TESTFIX world under C1/C3.
--   AT-21 audit immutability      audit_log rows seeded (append-only).
--   AT-22 awareness averages      completed awareness_cohort on C1 with 2
--                                 respondents + responses (labels only).
-- ============================================================================

-- ---------- gate ----------
DO $testfix_gate$
BEGIN
  CREATE OR REPLACE FUNCTION pg_temp.testfix_gate() RETURNS boolean
  LANGUAGE plpgsql AS $g$
  BEGIN
    IF coalesce(current_setting('securepath.test_fixtures', true), 'off')
       NOT IN ('on','true','1') THEN
      RETURN false;
    END IF;
    -- hard deps: W0-01 platform tier + W0-02 programme engine.
    IF to_regclass('public.jurisdiction_packs') IS NULL
       OR to_regclass('public.licences') IS NULL
       OR to_regclass('public.designations') IS NULL
       OR to_regclass('public.support_access_grants') IS NULL
       OR to_regclass('public.programmes') IS NULL
       OR to_regclass('public.activities') IS NULL THEN
      RETURN false;
    END IF;
    RETURN true;
  END $g$;

  IF NOT pg_temp.testfix_gate() THEN
    RAISE NOTICE 'W0-05 TESTFIX fixture pack SKIPPED — set securepath.test_fixtures=on '
      'in a TEST database and ensure W0-01/W0-02 schema is applied. No rows written.';
  END IF;
END $testfix_gate$;


-- ---------- 0. wipe previous fixture world (re-runnable) ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  -- Decided evidence and issued reports are immutable by trigger (NFR-09 /
  -- §9.5) — an FK cascade hitting them aborts the wipe. Suspend those two
  -- guards for the duration of the fixture wipe only (test-data teardown;
  -- the invariant itself is intentional and stays on for every other path).
  ALTER TABLE public.evidence_items    DISABLE TRIGGER evidence_immutable;
  ALTER TABLE public.programme_reports DISABLE TRIGGER report_transition_gate;
  -- W1-06 append-only ledgers (added by a LATER migration — ALTER ... IF EXISTS
  -- + DISABLE TRIGGER USER keeps this no-op when it is not applied yet).
  ALTER TABLE IF EXISTS public.decisions           DISABLE TRIGGER USER;
  ALTER TABLE IF EXISTS public.raid_status_history DISABLE TRIGGER USER;

  -- FR-MNT-05 CHECK vs cascade: mti.evidence_id is ON DELETE SET NULL, so
  -- wiping a client's evidence would leave Complete rows that violate the
  -- CHECK mid-cascade. Give any such TESTFIX row an exempt reason first.
  UPDATE public.maintenance_task_instances mti
     SET evidence_exempt_reason = 'TESTFIX wiped'
    FROM public.maintenance_task_templates t
   WHERE t.id = mti.task_template_id
     AND t.programme_id IN (SELECT p.id FROM public.programmes p
                              JOIN public.client_orgs c ON c.id = p.client_org_id
                             WHERE c.name LIKE 'TESTFIX%')
     AND mti.status = 'Complete'
     AND mti.evidence_exempt_reason IS NULL
     AND mti.evidence_id IS NOT NULL;

  -- client_orgs cascade: programmes + every programme child, plus client-level
  -- rows (operational_records, external_providers, training_records,
  -- controlled_documents(+links), designations, support_access_grants,
  -- awareness_cohorts(+respondents/responses)).
  DELETE FROM public.client_orgs WHERE name LIKE 'TESTFIX%';

  ALTER TABLE public.evidence_items    ENABLE TRIGGER evidence_immutable;
  ALTER TABLE public.programme_reports ENABLE TRIGGER report_transition_gate;
  ALTER TABLE IF EXISTS public.decisions           ENABLE TRIGGER USER;
  ALTER TABLE IF EXISTS public.raid_status_history ENABLE TRIGGER USER;
  -- practices cascade: licences, import_runs (client_orgs already gone).
  DELETE FROM public.practices   WHERE name LIKE 'TESTFIX%';
  -- auth.users cascade: public.users → role_assignments, notification_prefs,
  -- any *_by references left after tenant rows are gone. A user pinned as
  -- published_by of a surviving published/retired fixture version (immutable
  -- record — header EXCEPTION) is kept.
  DELETE FROM auth.users u
   WHERE u.email LIKE '%@testfix.test'
     AND ( to_regclass('public.programme_template_versions') IS NULL
        OR NOT EXISTS (SELECT 1 FROM public.programme_template_versions v
                        WHERE v.published_by = u.id AND v.status <> 'draft'));
  -- fixture templates: draft versions delete normally; published/retired are
  -- immutable records (see header EXCEPTION) so a template holding one stays.
  IF to_regclass('public.programme_template_versions') IS NOT NULL THEN
    DELETE FROM public.programme_template_versions v
     WHERE v.status = 'draft'
       AND v.template_id IN (SELECT id FROM public.programme_templates
                              WHERE name LIKE 'TESTFIX%');
    DELETE FROM public.programme_templates t
     WHERE t.name LIKE 'TESTFIX%'
       AND NOT EXISTS (SELECT 1 FROM public.programme_template_versions v
                        WHERE v.template_id = t.id AND v.status <> 'draft');
  END IF;
  -- audit_log fixture rows (append-only table; delete by marker for re-seed).
  DELETE FROM public.audit_log WHERE action LIKE 'testfix.%';
END $$;


-- ---------- 1. users (auth.users + public.users) ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

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
    ('aa000005-0000-0000-0000-000000000001'::uuid, 'platform-admin@testfix.test'),
    ('aa000005-0000-0000-0000-000000000002'::uuid, 'content-author@testfix.test'),
    ('aa000005-0000-0000-0000-000000000003'::uuid, 'support@testfix.test'),
    ('aa000005-0000-0000-0000-000000000004'::uuid, 'partner-a-admin@testfix.test'),
    ('aa000005-0000-0000-0000-000000000005'::uuid, 'partner-a-consultant@testfix.test'),
    ('aa000005-0000-0000-0000-000000000006'::uuid, 'partner-b-admin@testfix.test'),
    ('aa000005-0000-0000-0000-000000000007'::uuid, 'direct-admin@testfix.test'),
    ('aa000005-0000-0000-0000-000000000008'::uuid, 'c1-ao@testfix.test'),
    ('aa000005-0000-0000-0000-000000000009'::uuid, 'c1-pl@testfix.test'),
    ('aa000005-0000-0000-0000-000000000010'::uuid, 'c1-wsl@testfix.test'),
    ('aa000005-0000-0000-0000-000000000011'::uuid, 'c1-exec@testfix.test'),
    ('aa000005-0000-0000-0000-000000000012'::uuid, 'c1-staff@testfix.test'),
    ('aa000005-0000-0000-0000-000000000013'::uuid, 'c1-alternate@testfix.test'),
    ('aa000005-0000-0000-0000-000000000014'::uuid, 'c2-ao@testfix.test'),
    ('aa000005-0000-0000-0000-000000000015'::uuid, 'c2-pl@testfix.test'),
    ('aa000005-0000-0000-0000-000000000016'::uuid, 'c3-ao@testfix.test'),
    ('aa000005-0000-0000-0000-000000000017'::uuid, 'c3-pl@testfix.test')
  ) AS u(id, email)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users (id, email, full_name, organisation, status)
  SELECT u.id, u.email, u.fn, u.org, 'active'
  FROM (VALUES
    ('aa000005-0000-0000-0000-000000000001'::uuid,'platform-admin@testfix.test','TESTFIX Platform Admin','TESTFIX SecurePath'),
    ('aa000005-0000-0000-0000-000000000002'::uuid,'content-author@testfix.test','TESTFIX Content Author','TESTFIX SecurePath'),
    ('aa000005-0000-0000-0000-000000000003'::uuid,'support@testfix.test','TESTFIX Support','TESTFIX SecurePath'),
    ('aa000005-0000-0000-0000-000000000004'::uuid,'partner-a-admin@testfix.test','TESTFIX Partner A Admin','TESTFIX Partner A'),
    ('aa000005-0000-0000-0000-000000000005'::uuid,'partner-a-consultant@testfix.test','TESTFIX Partner A Consultant','TESTFIX Partner A'),
    ('aa000005-0000-0000-0000-000000000006'::uuid,'partner-b-admin@testfix.test','TESTFIX Partner B Admin','TESTFIX Partner B'),
    ('aa000005-0000-0000-0000-000000000007'::uuid,'direct-admin@testfix.test','TESTFIX Direct Admin','TESTFIX SecurePath Direct'),
    ('aa000005-0000-0000-0000-000000000008'::uuid,'c1-ao@testfix.test','TESTFIX C1 Accountable Officer','TESTFIX Client One'),
    ('aa000005-0000-0000-0000-000000000009'::uuid,'c1-pl@testfix.test','TESTFIX C1 Programme Lead','TESTFIX Client One'),
    ('aa000005-0000-0000-0000-000000000010'::uuid,'c1-wsl@testfix.test','TESTFIX C1 Workstream Lead','TESTFIX Client One'),
    ('aa000005-0000-0000-0000-000000000011'::uuid,'c1-exec@testfix.test','TESTFIX C1 Executive','TESTFIX Client One'),
    ('aa000005-0000-0000-0000-000000000012'::uuid,'c1-staff@testfix.test','TESTFIX C1 Staff Member','TESTFIX Client One'),
    ('aa000005-0000-0000-0000-000000000013'::uuid,'c1-alternate@testfix.test','TESTFIX C1 Named Alternate','TESTFIX Client One'),
    ('aa000005-0000-0000-0000-000000000014'::uuid,'c2-ao@testfix.test','TESTFIX C2 Accountable Officer','TESTFIX Client Two'),
    ('aa000005-0000-0000-0000-000000000015'::uuid,'c2-pl@testfix.test','TESTFIX C2 Programme Lead','TESTFIX Client Two'),
    ('aa000005-0000-0000-0000-000000000016'::uuid,'c3-ao@testfix.test','TESTFIX C3 Accountable Officer','TESTFIX Client Three'),
    ('aa000005-0000-0000-0000-000000000017'::uuid,'c3-pl@testfix.test','TESTFIX C3 Programme Lead','TESTFIX Client Three')
  ) AS u(id, email, fn, org)
  ON CONFLICT (id) DO NOTHING;
END $$;


-- ---------- 2. partners (branding incl.) + licences ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  INSERT INTO public.practices
      (id, name, type, country, status, logo_url, accent_hex, primary_hex,
       subdomain, email_sender_name, sign_in_text, support_contact,
       report_template_refs, data_region_default, ev_ref_format)
  VALUES
    -- Partner A: fully branded (AT-05/06)
    ('bb000005-0000-0000-0000-000000000001','TESTFIX Partner A','msp','ZA','active',
     'https://testfix.invalid/partner-a/logo.png','#2255AA','#101B33',
     'testfix-a','TESTFIX Partner A','Sign in to TESTFIX Partner A workspace',
     'support@testfix.test',
     '{"word":"testfix/partner-a/report.docx","pdf":"testfix/partner-a/report.pdf"}',
     'ZA','EV-%s-%03d'),
    -- Partner B: deliberately plainer (AT-05 "partner B unaffected")
    ('bb000005-0000-0000-0000-000000000002','TESTFIX Partner B','msp','UK','active',
     'https://testfix.invalid/partner-b/logo.png','#7A3B2E',NULL,
     'testfix-b','TESTFIX Partner B',NULL,'help@testfix.test',
     '{"word":"testfix/partner-b/report.docx"}',
     'UK','EV-%s-%03d'),
    -- SecurePath Direct is a partner row like any other (FR-PLT-01)
    ('bb000005-0000-0000-0000-000000000003','TESTFIX SecurePath Direct','securepath_direct','ZA','active',
     NULL,NULL,NULL,NULL,'TESTFIX SecurePath',NULL,NULL,NULL,'ZA','EV-%s-%03d')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.licences
      (id, partner_id, plan, client_limit, programme_limit, starts_on, status, attribution_display)
  VALUES
    -- AT the limit: 2 clients + 2 programmes below use the licence fully (AT-07)
    ('f2000005-0000-0000-0000-000000000001','bb000005-0000-0000-0000-000000000001',
     'TESTFIX Standard', 2, 2, DATE '2026-06-01', 'active', true),
    -- Under the limit
    ('f2000005-0000-0000-0000-000000000002','bb000005-0000-0000-0000-000000000002',
     'TESTFIX Growth', 5, 5, DATE '2026-06-01', 'active', true),
    -- SecurePath Direct: NULL limits = uncapped (W0-01 convention)
    ('f2000005-0000-0000-0000-000000000003','bb000005-0000-0000-0000-000000000003',
     'TESTFIX Direct', NULL, NULL, DATE '2026-06-01', 'active', false)
  ON CONFLICT (id) DO NOTHING;
END $$;


-- ---------- 3. clients + designations + support grant ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  INSERT INTO public.client_orgs
      (id, practice_id, name, legal_name, trading_name, registration_number,
       jurisdiction, sector, sites, headcount_in_scope, data_region, timezone)
  VALUES
    ('cc000005-0000-0000-0000-000000000001','bb000005-0000-0000-0000-000000000001',
     'TESTFIX Client One (ZA)','TESTFIX Client One (Pty) Ltd','TESTFIX One',
     'TESTFIX-REG-0001','ZA','TESTFIX financial services',
     '[{"name":"TESTFIX Head Office","address":"1 Fixture Way, Joburg"},
       {"name":"TESTFIX Branch","address":"2 Sample Rd, Cape Town"}]'::jsonb,
     40,'ZA','Africa/Johannesburg'),
    ('cc000005-0000-0000-0000-000000000002','bb000005-0000-0000-0000-000000000001',
     'TESTFIX Client Two (UK)','TESTFIX Client Two Ltd','TESTFIX Two',
     'TESTFIX-REG-0002','UK','TESTFIX professional services',
     '[{"name":"TESTFIX London Office","address":"3 Fixture Lane, London"}]'::jsonb,
     25,'UK','Europe/London'),
    ('cc000005-0000-0000-0000-000000000003','bb000005-0000-0000-0000-000000000002',
     'TESTFIX Client Three (ZA)','TESTFIX Client Three (Pty) Ltd','TESTFIX Three',
     'TESTFIX-REG-0003','ZA','TESTFIX retail',
     '[{"name":"TESTFIX Durban Office","address":"4 Fixture Rd, Durban"}]'::jsonb,
     15,'ZA','Africa/Johannesburg')
  ON CONFLICT (id) DO NOTHING;

  -- statutory designations (FR-ACC-03); named_alternate for FR-ACC-02 paths
  INSERT INTO public.designations
      (id, client_org_id, role, person, date_designated, registration_ref)
  VALUES
    ('f3000005-0000-0000-0000-000000000001','cc000005-0000-0000-0000-000000000001',
     'information_officer','aa000005-0000-0000-0000-000000000008',DATE '2026-09-01','TESTFIX-IO-001'),
    ('f3000005-0000-0000-0000-000000000002','cc000005-0000-0000-0000-000000000001',
     'named_alternate','aa000005-0000-0000-0000-000000000013',DATE '2026-09-01','TESTFIX-ALT-001'),
    ('f3000005-0000-0000-0000-000000000003','cc000005-0000-0000-0000-000000000002',
     'dpo','aa000005-0000-0000-0000-000000000014',DATE '2026-06-15','TESTFIX-DPO-001'),
    ('f3000005-0000-0000-0000-000000000004','cc000005-0000-0000-0000-000000000003',
     'information_officer','aa000005-0000-0000-0000-000000000016',DATE '2026-06-01','TESTFIX-IO-003')
  ON CONFLICT (id) DO NOTHING;

  -- AT-03/04: the support user holds a dormant client-scope platform
  -- assignment, but its only grant is EXPIRED → no standing access. The AT
  -- mints a fresh in-window grant to prove the approved path.
  INSERT INTO public.support_access_grants
      (id, client_org_id, securepath_user_id, reason, approved_by, starts_at, expires_at)
  VALUES
    ('f4000005-0000-0000-0000-000000000001','cc000005-0000-0000-0000-000000000001',
     'aa000005-0000-0000-0000-000000000003','TESTFIX import investigation (expired grant)',
     'aa000005-0000-0000-0000-000000000008','2026-10-19 09:00+00','2026-10-20 09:00+00')
  ON CONFLICT (id) DO NOTHING;
END $$;


-- ---------- 4. role assignments ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  -- idempotent: skip rows an earlier run already left active at same scope
  INSERT INTO public.role_assignments
      (user_id, level, role, scope_type, scope_id, origin)
  SELECT v.user_id, v.level, v.role, v.scope_type, v.scope_id, 'manual'
  FROM (VALUES
    -- platform roles — global (scope_id NULL); tenant visibility: none (AT-03)
    ('aa000005-0000-0000-0000-000000000001'::uuid,'platform','platform_admin','partner',NULL::uuid),
    ('aa000005-0000-0000-0000-000000000002'::uuid,'platform','content_author','partner',NULL::uuid),
    ('aa000005-0000-0000-0000-000000000003'::uuid,'platform','support','partner',NULL::uuid),
    -- support access leg for C1 — dormant without an in-window grant (AT-03/04)
    ('aa000005-0000-0000-0000-000000000003'::uuid,'platform','support','client','cc000005-0000-0000-0000-000000000001'::uuid),
    -- partner admins
    ('aa000005-0000-0000-0000-000000000004'::uuid,'partner','partner_admin','partner','bb000005-0000-0000-0000-000000000001'::uuid),
    ('aa000005-0000-0000-0000-000000000006'::uuid,'partner','partner_admin','partner','bb000005-0000-0000-0000-000000000002'::uuid),
    ('aa000005-0000-0000-0000-000000000007'::uuid,'partner','partner_admin','partner','bb000005-0000-0000-0000-000000000003'::uuid),
    -- AT-02: consultant scoped to C1 ONLY (see header — no partner-scope row)
    ('aa000005-0000-0000-0000-000000000005'::uuid,'partner','partner_consultant','client','cc000005-0000-0000-0000-000000000001'::uuid),
    -- client C1 roles
    ('aa000005-0000-0000-0000-000000000008'::uuid,'client','accountable_officer','client','cc000005-0000-0000-0000-000000000001'::uuid),
    ('aa000005-0000-0000-0000-000000000009'::uuid,'client','programme_lead','programme','dd000005-0000-0000-0000-000000000001'::uuid),
    ('aa000005-0000-0000-0000-000000000010'::uuid,'client','workstream_lead','workstream','d2000005-0000-0000-0000-000000000001'::uuid),
    ('aa000005-0000-0000-0000-000000000011'::uuid,'client','executive','client','cc000005-0000-0000-0000-000000000001'::uuid),
    ('aa000005-0000-0000-0000-000000000012'::uuid,'client','client_contributor','client','cc000005-0000-0000-0000-000000000001'::uuid),
    ('aa000005-0000-0000-0000-000000000013'::uuid,'client','client_contributor','client','cc000005-0000-0000-0000-000000000001'::uuid),
    -- client C2 roles
    ('aa000005-0000-0000-0000-000000000014'::uuid,'client','accountable_officer','client','cc000005-0000-0000-0000-000000000002'::uuid),
    ('aa000005-0000-0000-0000-000000000015'::uuid,'client','programme_lead','programme','dd000005-0000-0000-0000-000000000002'::uuid),
    -- client C3 roles
    ('aa000005-0000-0000-0000-000000000016'::uuid,'client','accountable_officer','client','cc000005-0000-0000-0000-000000000003'::uuid),
    ('aa000005-0000-0000-0000-000000000017'::uuid,'client','programme_lead','programme','dd000005-0000-0000-0000-000000000003'::uuid)
  ) AS v(user_id, level, role, scope_type, scope_id)
  WHERE NOT EXISTS (
      SELECT 1 FROM public.role_assignments ra
       WHERE ra.user_id = v.user_id AND ra.level = v.level AND ra.role = v.role
         AND ra.scope_type = v.scope_type
         AND ra.scope_id IS NOT DISTINCT FROM v.scope_id
         AND ra.end_date IS NULL);
END $$;


-- ---------- 5. fixture jurisdiction-pack values (UNVERIFIED — §5.4) ----------
-- Fills the W0-01 shells with STRUCTURALLY real values so ATs exercise the
-- resolution paths. version stays 0 (unverified); every jsonb carries a
-- _fixture marker and every display value is TESTFIX-prefixed so none of it
-- can masquerade as verified law.
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  UPDATE public.jurisdiction_packs SET
    version        = 0,                                   -- stays unverified
    role_labels    = '{"accountable_officer":"TESTFIX Information Officer",
                       "deputy_accountable_officer":"TESTFIX Deputy Information Officer",
                       "dpo":"TESTFIX Data Protection Officer",
                       "programme_lead":"TESTFIX Programme Lead",
                       "management_representative":"TESTFIX Management Representative"}'::jsonb,
    regulator_name = 'TESTFIX Regulator (unverified fixture value)',
    deadline_params = '{
      "_fixture": {"unverified_test_values": true,
                   "note": "TESTFIX — placeholders for the AT suite only; NOT legal values. SecurePath must enter verified values (spec §5.4)."},
      "business_day_convention": "mon_fri_excl_public_holidays",
      "data_subject_request": {"response_period_days": 30, "extension_period_days": 30,
                               "convention": "calendar_days"},
      "opt_out":              {"action_period_days": 5, "convention": "business_days"},
      "breach_notification":  {"regulator_period_days": 3, "data_subject_period_days": 7,
                               "convention": "business_days",
                               "rule": "TESTFIX rule — notify regulator without undue delay where risk of harm"}}'::jsonb,
    public_holidays = '[{"date":"2026-01-01","name":"TESTFIX New Year"},
                        {"date":"2026-03-21","name":"TESTFIX Human Rights Day"},
                        {"date":"2026-12-25","name":"TESTFIX Christmas Day"},
                        {"date":"2026-12-26","name":"TESTFIX Day of Goodwill"}]'::jsonb,
    formats         = '{"date_format":"YYYY-MM-DD","currency_code":"ZAR",
                        "number_grouping":"space","week_start":"Monday",
                        "_fixture": true}'::jsonb,
    updated_at      = now()
  WHERE code = 'ZA';

  UPDATE public.jurisdiction_packs SET
    version        = 0,
    role_labels    = '{"accountable_officer":"TESTFIX Senior Accountable Lead",
                       "deputy_accountable_officer":"TESTFIX Deputy Lead",
                       "dpo":"TESTFIX Data Protection Officer",
                       "programme_lead":"TESTFIX Programme Lead",
                       "management_representative":"TESTFIX Management Representative"}'::jsonb,
    regulator_name = 'TESTFIX UK Regulator (unverified fixture value)',
    deadline_params = '{
      "_fixture": {"unverified_test_values": true,
                   "note": "TESTFIX — placeholders for the AT suite only; NOT legal values. SecurePath must enter verified values (spec §5.4)."},
      "business_day_convention": "mon_fri_excl_public_holidays",
      "data_subject_request": {"response_period_days": 28, "extension_period_days": 60,
                               "convention": "calendar_days"},
      "opt_out":              {"action_period_days": 5, "convention": "business_days"},
      "breach_notification":  {"regulator_period_hours": 72, "data_subject_period_days": 7,
                               "convention": "hours_then_calendar_days",
                               "rule": "TESTFIX rule — notify regulator within stated hours unless unlikely to risk rights"}}'::jsonb,
    public_holidays = '[{"date":"2026-01-01","name":"TESTFIX New Year"},
                        {"date":"2026-12-25","name":"TESTFIX Christmas Day"},
                        {"date":"2026-12-28","name":"TESTFIX Boxing Day (substitute)"}]'::jsonb,
    formats         = '{"date_format":"DD/MM/YYYY","currency_code":"GBP",
                        "number_grouping":"comma","week_start":"Monday",
                        "_fixture": true}'::jsonb,
    updated_at      = now()
  WHERE code = 'UK';
END $$;


-- ---------- 6. POPIA programme template + published version (W0-03) ----------
-- Guarded separately: if the W0-03 template tables are not yet applied this
-- section skips (NOTICE) while the rest of the world still seeds. Programmes
-- reference the fixed version uuid either way — the FK resolves once the
-- version row exists.
DO $$
DECLARE
  v_content_v1  jsonb;
  v_content_v11 jsonb;
BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;
  IF to_regclass('public.programme_templates') IS NULL
     OR to_regclass('public.programme_template_versions') IS NULL THEN
    RAISE NOTICE 'W0-05 TESTFIX: programme template tables absent (W0-03 not applied) — skipping template/version seed';
    RETURN;
  END IF;

  -- §5.1 content pack — all eleven required keys present (assert_template_
  -- content contract). Marked _fixture; ~3 phases / 3 workstreams / 8
  -- activities (deps + milestones + evidence_required) / 5 findings / 3 KPIs /
  -- 5 maintenance tasks (Annex A timing rules) / quarterly+annual cycles /
  -- register types / report structure / role labels.
  v_content_v1 := '{
    "_fixture": {"unverified_test_values": true,
                 "note": "TESTFIX minimal POPIA pack for the AT suite — exercises the §5.1 shape; NOT William''s content."},
    "phases": [
      {"number": 1, "name": "TESTFIX Assess & Design",      "start_week": 1,  "end_week": 4,  "default_duration_weeks": 4},
      {"number": 2, "name": "TESTFIX Remediate & Implement","start_week": 5,  "end_week": 9,  "default_duration_weeks": 5},
      {"number": 3, "name": "TESTFIX Embed & Handover",     "start_week": 10, "end_week": 12, "default_duration_weeks": 3}],
    "workstreams": [
      {"key": "WS-GOV", "name": "TESTFIX Governance & Accountability", "default_lead_role": "accountable_officer"},
      {"key": "WS-OPS", "name": "TESTFIX Operations & Security",       "default_lead_role": "programme_lead"},
      {"key": "WS-COM", "name": "TESTFIX Communication & Training",    "default_lead_role": "workstream_lead"}],
    "activity_library": [
      {"ref": "A-01", "workstream": "WS-GOV", "text": "TESTFIX Designate the accountable officer",            "start_week": 1, "end_week": 1,  "milestone": false, "evidence_required": true,  "dependencies": [],       "linked_findings": ["R-04"]},
      {"ref": "A-02", "workstream": "WS-OPS", "text": "TESTFIX Personal information inventory",               "start_week": 1, "end_week": 4,  "milestone": false, "evidence_required": false, "dependencies": [],       "linked_findings": []},
      {"ref": "A-03", "workstream": "WS-GOV", "text": "TESTFIX Draft the privacy policy",                     "start_week": 3, "end_week": 5,  "milestone": false, "evidence_required": true,  "dependencies": ["A-02"], "linked_findings": ["R-01"]},
      {"ref": "A-04", "workstream": "WS-GOV", "text": "TESTFIX Compile the access manual",                    "start_week": 4, "end_week": 6,  "milestone": true,  "evidence_required": false, "dependencies": ["A-03"], "linked_findings": []},
      {"ref": "A-05", "workstream": "WS-OPS", "text": "TESTFIX Operator agreement remediation",               "start_week": 5, "end_week": 7,  "milestone": false, "evidence_required": true,  "dependencies": ["A-02"], "linked_findings": ["R-02"]},
      {"ref": "A-06", "workstream": "WS-COM", "text": "TESTFIX Staff awareness training rollout",             "start_week": 6, "end_week": 8,  "milestone": false, "evidence_required": false, "dependencies": ["A-05"], "linked_findings": []},
      {"ref": "A-07", "workstream": "WS-OPS", "text": "TESTFIX Implement the request-handling procedure",     "start_week": 7, "end_week": 9,  "milestone": false, "evidence_required": true,  "dependencies": [],       "linked_findings": ["R-03"]},
      {"ref": "A-08", "workstream": "WS-COM", "text": "TESTFIX Mock breach drill and evidence capture",       "start_week": 9, "end_week": 10, "milestone": true,  "evidence_required": true,  "dependencies": ["A-07"], "linked_findings": ["R-05"]}],
    "findings_map": [
      {"ref": "R-01", "finding": "TESTFIX No documented privacy policy",                 "priority": "High",   "assessment_window": "TESTFIX baseline", "planned_close_week": 5, "linked_activities": ["A-03"]},
      {"ref": "R-02", "finding": "TESTFIX Operator agreements missing required clauses", "priority": "Medium", "assessment_window": "TESTFIX baseline", "planned_close_week": 7, "linked_activities": ["A-05"]},
      {"ref": "R-03", "finding": "TESTFIX Request handling untested",                    "priority": "High",   "assessment_window": "TESTFIX baseline", "planned_close_week": 9, "linked_activities": ["A-07"]},
      {"ref": "R-04", "finding": "TESTFIX Accountable officer not designated",           "priority": "High",   "assessment_window": "TESTFIX baseline", "planned_close_week": 2, "linked_activities": ["A-01"]},
      {"ref": "R-05", "finding": "TESTFIX Breach response not evidenced",                "priority": "Low",    "assessment_window": "TESTFIX baseline", "planned_close_week": 10,"linked_activities": ["A-08"]}],
    "document_set": [
      {"reference": "TESTFIX-POL-001", "title": "TESTFIX Privacy Policy",       "review_cycle": "annual"},
      {"reference": "TESTFIX-PROC-002","title": "TESTFIX Request Procedure",    "review_cycle": "annual"},
      {"reference": "TESTFIX-FRM-003", "title": "TESTFIX Breach Report Form",   "review_cycle": "biennial"}],
    "kpis": [
      {"name": "TESTFIX Requests actioned within period", "unit": "%",     "calculation": "closed_in_period / received",        "default_target": 95, "source": "operational_records", "auto_calc": true},
      {"name": "TESTFIX Reportable breaches",             "unit": "count", "calculation": "count(breach where regulator_notified)","default_target": 0, "source": "operational_records", "auto_calc": true},
      {"name": "TESTFIX Staff training coverage",         "unit": "%",     "calculation": "trained / headcount_in_scope",       "default_target": 90, "source": "training_records",    "auto_calc": false}],
    "maintenance_set": [
      {"code": "MM-01", "task": "TESTFIX Confirm every opt-out and objection was actioned within five business days", "timing_rule": {"window": "before_month_end"},                       "owner_role": "programme_lead", "input_from": "Marketing lead",      "evidence_produced": "TESTFIX opt-out confirmation", "feeds": "Report; opt-out KPI"},
      {"code": "MM-03", "task": "TESTFIX Reconcile the request register against its due dates",                        "timing_rule": {"window": "month_end_close"},                        "owner_role": "programme_lead", "input_from": null,                  "evidence_produced": "TESTFIX reconciliation note",   "feeds": "Report; request KPI"},
      {"code": "MM-06", "task": "TESTFIX Obtain backup job status and last restoration test",                          "timing_rule": {"window": "report_window", "business_day": 2},       "owner_role": "programme_lead", "input_from": "IT provider",         "evidence_produced": "TESTFIX backup report",         "feeds": "Report"},
      {"code": "MM-08", "task": "TESTFIX Review vulnerability scan and patching results",                              "timing_rule": {"window": "report_window", "business_day": 2},       "owner_role": "programme_lead", "input_from": "IT provider",         "evidence_produced": "TESTFIX scan review",           "feeds": "Report", "active_from_rule": {"when_activity_complete": "A-08"}},
      {"code": "MM-16", "task": "TESTFIX Issue the monthly report for review and signature",                           "timing_rule": {"window": "report_window", "business_day": 5},       "owner_role": "programme_lead", "input_from": "Accountable officer", "evidence_produced": "TESTFIX issued report",         "feeds": "Report"}],
    "quarterly_annual_cycles": {
      "quarterly": {"period": "quarterly", "generate_on": "first_business_day_of_quarter",
                    "items": [{"ref": "TESTFIX-Q1", "label": "TESTFIX Review operator register completeness", "evidence_required": true},
                              {"ref": "TESTFIX-Q2", "label": "TESTFIX Access-rights spot check",              "evidence_required": true}]},
      "annual":    {"period": "annual",    "generate_on": "programme_anniversary",
                    "items": [{"ref": "TESTFIX-A1", "label": "TESTFIX Annual policy-suite review",            "evidence_required": true},
                              {"ref": "TESTFIX-A2", "label": "TESTFIX Annual report to the executive",        "evidence_required": true}]}},
    "registers": [
      {"type": "dsr",        "deadline_rule": "data_subject_request"},
      {"type": "breach",     "deadline_rule": "breach_notification"},
      {"type": "disclosure", "deadline_rule": null},
      {"type": "optout",     "deadline_rule": "opt_out"}],
    "report_structure": {
      "due_business_day": 5,
      "sections": [{"key": "executive_summary"}, {"key": "register_progress"},
                   {"key": "activity_schedule"}, {"key": "kpi_summary"},
                   {"key": "maintenance_status"}, {"key": "raid_decisions"}]},
    "role_labels": {"accountable_officer": "TESTFIX Information Officer",
                    "programme_lead":      "TESTFIX Programme Lead",
                    "regulator":           "TESTFIX Regulator"}
  }'::jsonb;

  -- v1.1 draft: v1 + one added activity + one KPI target change (AT-08 diff)
  v_content_v11 :=
      (v_content_v1 - 'activity_library' - 'kpis')
    || jsonb_build_object(
         'activity_library',
           (v_content_v1->'activity_library')
           || '[{"ref":"A-09","workstream":"WS-OPS","text":"TESTFIX New v1.1 activity — breach-drill evidence pack","start_week":10,"end_week":11,"milestone":false,"evidence_required":true,"dependencies":["A-08"],"linked_findings":[]}]'::jsonb,
         'kpis',
           jsonb_set(v_content_v1->'kpis', '{2,default_target}', '85'::jsonb));

  INSERT INTO public.programme_templates
      (id, framework, edition, jurisdiction, name, source_refs, partner_id)
  VALUES
    ('f5000005-0000-0000-0000-000000000001','popia_paia','TESTFIX-2026','ZA',
     'TESTFIX POPIA and PAIA Programme Template',
     '[{"ref":"TESTFIX — placeholder citation, not a legal reference"}]'::jsonb,
     NULL)                                   -- shared SecurePath library
  ON CONFLICT (id) DO NOTHING;

  -- v1.0 — PUBLISHED (immutable record; the AT's "running" version)
  INSERT INTO public.programme_template_versions
      (id, template_id, number, status, published_by, published_at, release_notes, content)
  VALUES
    ('f6000005-0000-0000-0000-000000000001','f5000005-0000-0000-0000-000000000001',
     1,'published','aa000005-0000-0000-0000-000000000002','2026-08-01 09:00+00',
     'TESTFIX v1.0 — fixture release for the AT suite', v_content_v1)
  ON CONFLICT (id) DO NOTHING;

  -- v1.1 — DRAFT for AT-08 to publish (deletable, unlike published rows)
  INSERT INTO public.programme_template_versions
      (id, template_id, number, status, release_notes, content)
  VALUES
    ('f6000005-0000-0000-0000-000000000002','f5000005-0000-0000-0000-000000000001',
     2,'draft',
     'TESTFIX v1.1 draft — adds A-09, lowers training target to 85 (AT-08)',
     v_content_v11)
  ON CONFLICT (id) DO NOTHING;
END $$;


-- ---------- 7. P1 — client-one programme, in implementation ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  INSERT INTO public.programmes
      (id, client_org_id, template_version_id, name, start_date, total_weeks,
       phase, status, programme_lead, red_days_threshold,
       report_due_business_day, reduced_capacity_weeks, programme_rag)
  VALUES
    ('dd000005-0000-0000-0000-000000000001','cc000005-0000-0000-0000-000000000001',
     'f6000005-0000-0000-0000-000000000001','TESTFIX C1 POPIA Programme',
     DATE '2026-09-07', 12,                       -- a Monday (isodow check)
     'TESTFIX Remediate & Implement','implementation',
     'aa000005-0000-0000-0000-000000000009', 14, 5, '{6}', 'Amber')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.phases (id, programme_id, number, name, start_week, end_week)
  VALUES
    ('d1000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001',1,'TESTFIX Assess & Design',1,4),
    ('d1000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001',2,'TESTFIX Remediate & Implement',5,9),
    ('d1000005-0000-0000-0000-000000000003','dd000005-0000-0000-0000-000000000001',3,'TESTFIX Embed & Handover',10,12)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.workstreams (id, programme_id, name, accountable_lead, deputy)
  VALUES
    ('d2000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001','TESTFIX Governance & Accountability','aa000005-0000-0000-0000-000000000010',NULL),
    ('d2000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001','TESTFIX Operations & Security','aa000005-0000-0000-0000-000000000009',NULL),
    ('d2000005-0000-0000-0000-000000000003','dd000005-0000-0000-0000-000000000001','TESTFIX Communication & Training','aa000005-0000-0000-0000-000000000009','aa000005-0000-0000-0000-000000000010')
  ON CONFLICT (id) DO NOTHING;

  -- Activities: due/start/phase/rag are fixture values for the CALC columns —
  -- deterministic so AT-10/11/12 can assert against them (engine recalcs).
  INSERT INTO public.activities
      (id, programme_id, workstream_id, ref, text, leads, start_week, end_week,
       milestone, evidence_required, status, pct_complete, actual_completion,
       recovery_date, phase, start_date, due_date, month, rag)
  VALUES
    ('d3000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001','d2000005-0000-0000-0000-000000000001',
     'A-01','TESTFIX Designate the accountable officer','{aa000005-0000-0000-0000-000000000008}',
     1,1,false,true,'Complete',100,DATE '2026-09-11',NULL,
     'TESTFIX Assess & Design',DATE '2026-09-07',DATE '2026-09-11',1,'Complete'),
    ('d3000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001','d2000005-0000-0000-0000-000000000002',
     'A-02','TESTFIX Personal information inventory','{aa000005-0000-0000-0000-000000000010}',
     1,4,false,false,'In progress',40,NULL,NULL,
     'TESTFIX Assess & Design',DATE '2026-09-07',DATE '2026-10-02',2,'Red'),
    ('d3000005-0000-0000-0000-000000000003','dd000005-0000-0000-0000-000000000001','d2000005-0000-0000-0000-000000000001',
     'A-03','TESTFIX Draft the privacy policy','{aa000005-0000-0000-0000-000000000010}',
     3,5,false,true,'In progress',25,NULL,NULL,
     'TESTFIX Remediate & Implement',DATE '2026-09-21',DATE '2026-10-09',2,'Green'),
    ('d3000005-0000-0000-0000-000000000004','dd000005-0000-0000-0000-000000000001','d2000005-0000-0000-0000-000000000001',
     'A-04','TESTFIX Compile the access manual','{aa000005-0000-0000-0000-000000000009}',
     4,6,true,false,'Not started',0,NULL,NULL,
     'TESTFIX Remediate & Implement',DATE '2026-09-28',DATE '2026-10-16',2,'Not due'),
    ('d3000005-0000-0000-0000-000000000005','dd000005-0000-0000-0000-000000000001','d2000005-0000-0000-0000-000000000002',
     'A-05','TESTFIX Operator agreement remediation','{aa000005-0000-0000-0000-000000000009}',
     5,7,false,true,'In progress',60,NULL,NULL,
     'TESTFIX Remediate & Implement',DATE '2026-10-05',DATE '2026-10-23',2,'Amber'),
    ('d3000005-0000-0000-0000-000000000006','dd000005-0000-0000-0000-000000000001','d2000005-0000-0000-0000-000000000003',
     'A-06','TESTFIX Staff awareness training rollout','{aa000005-0000-0000-0000-000000000010}',
     6,8,false,false,'At risk',30,NULL,DATE '2026-11-06',
     'TESTFIX Remediate & Implement',DATE '2026-10-12',DATE '2026-10-30',2,'Amber'),
    ('d3000005-0000-0000-0000-000000000007','dd000005-0000-0000-0000-000000000001','d2000005-0000-0000-0000-000000000002',
     'A-07','TESTFIX Implement the request-handling procedure','{aa000005-0000-0000-0000-000000000009}',
     7,9,false,true,'Not started',0,NULL,NULL,
     'TESTFIX Remediate & Implement',DATE '2026-10-19',DATE '2026-11-06',3,'Not due'),
    ('d3000005-0000-0000-0000-000000000008','dd000005-0000-0000-0000-000000000001','d2000005-0000-0000-0000-000000000003',
     'A-08','TESTFIX Mock breach drill and evidence capture','{aa000005-0000-0000-0000-000000000010}',
     9,10,true,true,'Blocked',0,NULL,NULL,
     'TESTFIX Embed & Handover',DATE '2026-11-02',DATE '2026-11-13',3,'Red')
  ON CONFLICT (id) DO NOTHING;

  -- finish-to-start dependencies matching the template's activity_library
  INSERT INTO public.activity_deps (activity_id, depends_on_activity_id) VALUES
    ('d3000005-0000-0000-0000-000000000003','d3000005-0000-0000-0000-000000000002'),
    ('d3000005-0000-0000-0000-000000000004','d3000005-0000-0000-0000-000000000003'),
    ('d3000005-0000-0000-0000-000000000005','d3000005-0000-0000-0000-000000000002'),
    ('d3000005-0000-0000-0000-000000000006','d3000005-0000-0000-0000-000000000005'),
    ('d3000005-0000-0000-0000-000000000008','d3000005-0000-0000-0000-000000000007')
  ON CONFLICT DO NOTHING;

  INSERT INTO public.activity_status_history (activity_id, old_status, new_status, changed_by, changed_at) VALUES
    ('d3000005-0000-0000-0000-000000000002','Not started','In progress','aa000005-0000-0000-0000-000000000009','2026-09-08 10:00+00'),
    ('d3000005-0000-0000-0000-000000000008','In progress','Blocked','aa000005-0000-0000-0000-000000000009','2026-11-04 15:00+00');

  -- remediation register: 4 open + 1 already-closed worked example (§9.4)
  INSERT INTO public.register_items
      (id, programme_id, ref, finding, priority, assessment_window, lead,
       planned_close_week, status, planned_close_date, days_overdue,
       accepted_on, accepted_by, accepted_evidence_refs)
  VALUES
    ('d4000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001','R-01',
     'TESTFIX No documented privacy policy','High','TESTFIX baseline',
     'aa000005-0000-0000-0000-000000000009',5,'In progress',DATE '2026-10-09',0,NULL,NULL,NULL),
    ('d4000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001','R-02',
     'TESTFIX Operator agreements missing required clauses','Medium','TESTFIX baseline',
     'aa000005-0000-0000-0000-000000000009',7,'In progress',DATE '2026-10-23',0,NULL,NULL,NULL),
    ('d4000005-0000-0000-0000-000000000003','dd000005-0000-0000-0000-000000000001','R-03',
     'TESTFIX Request handling untested','High','TESTFIX baseline',
     'aa000005-0000-0000-0000-000000000009',9,'Not started',DATE '2026-11-06',0,NULL,NULL,NULL),
    ('d4000005-0000-0000-0000-000000000004','dd000005-0000-0000-0000-000000000001','R-04',
     'TESTFIX Accountable officer not designated','High','TESTFIX baseline',
     'aa000005-0000-0000-0000-000000000008',2,'Closed',DATE '2026-09-18',NULL,   -- days_overdue blank once Closed (§9.3)
     '2026-10-02 11:00+00','aa000005-0000-0000-0000-000000000008','{EV-R-04-001}'),
    ('d4000005-0000-0000-0000-000000000005','dd000005-0000-0000-0000-000000000001','R-05',
     'TESTFIX Breach response not evidenced','Low','TESTFIX baseline',
     'aa000005-0000-0000-0000-000000000009',10,'Not started',DATE '2026-11-13',0,NULL,NULL,NULL)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.register_item_activities (register_item_id, activity_id) VALUES
    ('d4000005-0000-0000-0000-000000000001','d3000005-0000-0000-0000-000000000003'),
    ('d4000005-0000-0000-0000-000000000002','d3000005-0000-0000-0000-000000000005'),
    ('d4000005-0000-0000-0000-000000000003','d3000005-0000-0000-0000-000000000007'),
    ('d4000005-0000-0000-0000-000000000004','d3000005-0000-0000-0000-000000000001'),
    ('d4000005-0000-0000-0000-000000000005','d3000005-0000-0000-0000-000000000008')
  ON CONFLICT DO NOTHING;

  -- evidence at every review stage (file_key only — objects are not uploaded)
  -- W4-03: seeded rows model already-reviewed evidence → scan_status='clean'
  -- (the malware-scan gate covers NEW uploads; decided rows are immutable
  -- so the status can only ever be set at insert)
  INSERT INTO public.evidence_items
      (id, programme_id, activity_id, register_item_id, site, file_key,
       uploaded_by, uploaded_at, review_stage, outcome, evidence_ref, scan_status)
  VALUES
    ('e1000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001',
     'd3000005-0000-0000-0000-000000000003','d4000005-0000-0000-0000-000000000001',
     'TESTFIX Head Office','testfix/c1/evidence/privacy-policy-draft-v1.pdf',
     'aa000005-0000-0000-0000-000000000010','2026-10-06 09:00+00','verification',NULL,NULL,'clean'),
    ('e1000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001',
     'd3000005-0000-0000-0000-000000000005','d4000005-0000-0000-0000-000000000002',
     'TESTFIX Head Office','testfix/c1/evidence/operator-agreement-signed.pdf',
     'aa000005-0000-0000-0000-000000000010','2026-10-07 14:00+00','acceptance',NULL,NULL,'clean'),
    ('e1000005-0000-0000-0000-000000000003','dd000005-0000-0000-0000-000000000001',
     'd3000005-0000-0000-0000-000000000001','d4000005-0000-0000-0000-000000000004',
     'TESTFIX Head Office','testfix/c1/evidence/io-appointment-letter.pdf',
     'aa000005-0000-0000-0000-000000000009','2026-09-30 08:00+00','decided','closes_finding','EV-R-04-001','clean'),
    ('e1000005-0000-0000-0000-000000000004','dd000005-0000-0000-0000-000000000001',
     'd3000005-0000-0000-0000-000000000006',NULL,
     'TESTFIX Branch','testfix/c1/evidence/training-register-sept.xlsx',
     'aa000005-0000-0000-0000-000000000010','2026-09-29 16:00+00','decided','kpi_evidence','EV-KPI-001','clean')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.evidence_reviews
      (id, evidence_item_id, stage, reviewer, decision, reasons, decided_at)
  VALUES
    ('e2000005-0000-0000-0000-000000000001','e1000005-0000-0000-0000-000000000002',
     'verify','aa000005-0000-0000-0000-000000000009','verified','{}','2026-10-08 09:00+00'),
    ('e2000005-0000-0000-0000-000000000002','e1000005-0000-0000-0000-000000000003',
     'verify','aa000005-0000-0000-0000-000000000009','verified','{}','2026-09-30 10:00+00'),
    ('e2000005-0000-0000-0000-000000000003','e1000005-0000-0000-0000-000000000003',
     'accept','aa000005-0000-0000-0000-000000000008','accepted','{}','2026-10-02 11:00+00'),
    ('e2000005-0000-0000-0000-000000000004','e1000005-0000-0000-0000-000000000004',
     'verify','aa000005-0000-0000-0000-000000000009','verified','{}','2026-09-30 10:30+00'),
    ('e2000005-0000-0000-0000-000000000005','e1000005-0000-0000-0000-000000000004',
     'accept','aa000005-0000-0000-0000-000000000008','accepted','{}','2026-10-01 09:00+00')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.weekly_logs
      (id, programme_id, week, counts, session_held, completed, planned_next,
       blockers, decisions, week_rag)
  VALUES
    ('e3000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001',4,
     '{"due":2,"overdue":1,"starting":2,"awaiting_decision":1,"raid_open":3}',
     true,'["A-01"]','["A-02","A-03"]',
     'TESTFIX operator contract negotiations delayed',
     'TESTFIX escalate operator issue at exec meeting','Amber'),
    ('e3000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001',5,
     '{"due":1,"overdue":2,"starting":1,"awaiting_decision":2,"raid_open":3}',
     false,'[]','["A-03","A-05"]','TESTFIX awaiting IT provider input',NULL,'Amber')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.kpis
      (id, programme_id, name, unit, baseline, target, calculation, auto_calc,
       target_proposed, target_confirmed_by, target_confirmed_on, sort)
  VALUES
    ('e4000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001',
     'TESTFIX Requests actioned within period','%',70,95,'closed_in_period / received',
     false,true,NULL,NULL,10),
    ('e4000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001',
     'TESTFIX Reportable breaches','count',0,0,'count(breach where regulator_notified)',
     true,false,NULL,NULL,20),
    ('e4000005-0000-0000-0000-000000000003','dd000005-0000-0000-0000-000000000001',
     'TESTFIX Staff training coverage','%',50,90,'trained / headcount_in_scope',
     false,true,'aa000005-0000-0000-0000-000000000008','2026-09-30 12:00+00',30)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.kpi_actuals (id, kpi_id, month, value, evidence_id, entered_by)
  VALUES
    ('ee000005-0000-0000-0000-000000000001','e4000005-0000-0000-0000-000000000001',
     DATE '2026-09-01',82,NULL,'aa000005-0000-0000-0000-000000000009'),
    ('ee000005-0000-0000-0000-000000000002','e4000005-0000-0000-0000-000000000003',
     DATE '2026-09-01',64,'e1000005-0000-0000-0000-000000000004','aa000005-0000-0000-0000-000000000009')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.raid_items
      (id, programme_id, type, description, impact, action, owner, raised_on,
       review_by, status, source)
  VALUES
    ('e5000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001',
     'risk','TESTFIX Operator contract negotiations may miss the week-7 deadline',
     'TESTFIX remediation slips a phase','TESTFIX phased contract rollout',
     'aa000005-0000-0000-0000-000000000009',DATE '2026-09-20',DATE '2026-10-30',
     'Open','template'),
    ('e5000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001',
     'issue','TESTFIX IT provider missed the backup-status input (MM-06)',
     'TESTFIX report section unverified','TESTFIX escalate to provider account manager',
     'aa000005-0000-0000-0000-000000000009',DATE '2026-10-06',DATE '2026-10-12',
     'Open','exception'),                         -- AT-16: raised by the missed input
    ('e5000005-0000-0000-0000-000000000003','dd000005-0000-0000-0000-000000000001',
     'assumption','TESTFIX Headcount stays stable through implementation',
     NULL,NULL,'aa000005-0000-0000-0000-000000000009',DATE '2026-09-07',NULL,
     'Open','manual')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.decisions
      (id, raid_item_id, outcome, decided_on, minute_ref, unlocks, decided_by)
  VALUES
    ('e6000005-0000-0000-0000-000000000001','e5000005-0000-0000-0000-000000000001',
     'TESTFIX accept phased contract rollout',DATE '2026-10-02','TESTFIX-EXEC-2026-10',
     '[{"activity_ref":"A-06"}]','aa000005-0000-0000-0000-000000000008')
  ON CONFLICT (id) DO NOTHING;
END $$;


-- ---------- 8. P1 client-scope rows + maintenance cycle ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  INSERT INTO public.external_providers (id, client_org_id, name, kind, contact_email, channel, active)
  VALUES
    ('e7000005-0000-0000-0000-000000000001','cc000005-0000-0000-0000-000000000001',
     'TESTFIX IT Provider','IT provider','it-provider@testfix.test','portal',true),
    ('e7000005-0000-0000-0000-000000000002','cc000005-0000-0000-0000-000000000001',
     'TESTFIX Marketing Lead','marketing lead','marketing@testfix.test','email',true)
  ON CONFLICT (id) DO NOTHING;

  -- programme-scoped maintenance task templates (maintenance runs from month 1, §8.9)
  INSERT INTO public.maintenance_task_templates
      (id, programme_id, template_version_id, code, task, timing_rule, owner_role,
       input_from_label, input_from_provider_id, evidence_produced, feeds,
       active_from_rule, sort)
  VALUES
    ('e8000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001',NULL,
     'MM-01','TESTFIX Confirm every opt-out and objection was actioned within five business days',
     '{"window":"before_month_end"}','programme_lead','Marketing lead',
     'e7000005-0000-0000-0000-000000000002','TESTFIX opt-out confirmation','Report; opt-out KPI',NULL,10),
    ('e8000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001',NULL,
     'MM-03','TESTFIX Reconcile the request register against its due dates',
     '{"window":"month_end_close"}','programme_lead',NULL,NULL,
     'TESTFIX reconciliation note','Report; request KPI',NULL,30),
    ('e8000005-0000-0000-0000-000000000003','dd000005-0000-0000-0000-000000000001',NULL,
     'MM-06','TESTFIX Obtain backup job status and last restoration test',
     '{"window":"report_window","business_day":2}','programme_lead','IT provider',
     'e7000005-0000-0000-0000-000000000001','TESTFIX backup report','Report',NULL,60),
    ('e8000005-0000-0000-0000-000000000004','dd000005-0000-0000-0000-000000000001',NULL,
     'MM-08','TESTFIX Review vulnerability scan and patching results',
     '{"window":"report_window","business_day":2}','programme_lead','IT provider',
     'e7000005-0000-0000-0000-000000000001','TESTFIX scan review','Report',
     '{"when_activity_complete":"A-08"}',80),   -- unmet (A-08 Blocked) → absent (AT-15)
    ('e8000005-0000-0000-0000-000000000005','dd000005-0000-0000-0000-000000000001',NULL,
     'MM-16','TESTFIX Issue the monthly report for review and signature',
     '{"window":"report_window","business_day":5}','programme_lead','Accountable officer',
     NULL,'TESTFIX issued report','Report',NULL,160)
  ON CONFLICT (id) DO NOTHING;

  -- October instances incl. the AT-16 exception and a Complete-with-evidence row
  INSERT INTO public.maintenance_task_instances
      (id, task_template_id, period, due_date, task_window, assignee, status,
       evidence_id, evidence_exempt_reason, exception_reason,
       exception_raid_item_id, completed_on)
  VALUES
    ('e9000005-0000-0000-0000-000000000001','e8000005-0000-0000-0000-000000000001','2026-10',
     DATE '2026-10-30','before_month_end','aa000005-0000-0000-0000-000000000009',
     'Pending',NULL,NULL,NULL,NULL,NULL),
    ('e9000005-0000-0000-0000-000000000002','e8000005-0000-0000-0000-000000000002','2026-10',
     DATE '2026-10-30','month_end_close','aa000005-0000-0000-0000-000000000009',
     'Complete','e1000005-0000-0000-0000-000000000004',
     'TESTFIX reconciled — no exceptions found',   -- belt+braces: evidence_id FK is
     NULL,NULL,'2026-10-28 15:00+00'),             -- ON DELETE SET NULL; without this a
                                                 -- cascade wipe would violate FR-MNT-05
    ('e9000005-0000-0000-0000-000000000003','e8000005-0000-0000-0000-000000000003','2026-10',
     DATE '2026-10-06','report_window','aa000005-0000-0000-0000-000000000009',
     'Exception',NULL,NULL,'TESTFIX IT provider did not supply the backup report',
     'e5000005-0000-0000-0000-000000000002',NULL),
    ('e9000005-0000-0000-0000-000000000004','e8000005-0000-0000-0000-000000000005','2026-10',
     DATE '2026-10-09','report_window','aa000005-0000-0000-0000-000000000009',
     'Pending',NULL,NULL,NULL,NULL,NULL)
    -- no MM-08 instance: active_from_rule unmet (AT-15)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.checklist_instances (id, programme_id, kind, period, items, generated_on)
  VALUES
    ('ea000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001',
     'quarterly','2026-Q4',
     '[{"ref":"TESTFIX-Q1","label":"TESTFIX Review operator register completeness","evidence_required":true,"done":false},
       {"ref":"TESTFIX-Q2","label":"TESTFIX Access-rights spot check","evidence_required":true,"done":false}]'::jsonb,
     DATE '2026-10-01')
  ON CONFLICT (id) DO NOTHING;

  -- snapshot + issued report (AT-17) and current draft (AT-16 gate)
  INSERT INTO public.monthly_snapshots (id, programme_id, period, snapshot, taken_at)
  VALUES
    ('ef000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001','2026-09',
     '{"activities_complete":1,"activities_overdue":1,"register_closed":1,"register_open":4,
       "high_priority_closed":1,"evidence_pending":2,"rag":"Amber",
       "kpi_actuals":{"TESTFIX Requests actioned within period":82,"TESTFIX Staff training coverage":64},
       "maintenance_done":6,"maintenance_overdue":0}'::jsonb,
     '2026-09-30 18:00+00')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.programme_reports
      (id, programme_id, period, reference, snapshot_id, sections, overall_rag,
       trend, headline, commentary, status, signatures, due_on, issued_on)
  VALUES
    ('f1000005-0000-0000-0000-000000000001','dd000005-0000-0000-0000-000000000001','2026-09',
     'TESTFIX-RPT-2026-09-001','ef000005-0000-0000-0000-000000000001',
     '{"executive_summary":"TESTFIX Two findings closed; operator remediation on track.",
       "register_progress":{"closed":1,"open":4},
       "kpi_summary":{"requests_in_period":"82%","training_coverage":"64%"},
       "maintenance_status":{"done":6,"overdue":0}}'::jsonb,
     'Amber','improving','TESTFIX two findings closed this period',
     'TESTFIX commentary for the September period.',
     'issued',
     '[{"role":"programme_lead","user":"aa000005-0000-0000-0000-000000000009","at":"2026-10-02T09:00:00Z"},
       {"role":"accountable_officer","user":"aa000005-0000-0000-0000-000000000008","at":"2026-10-03T10:00:00Z"}]'::jsonb,
     DATE '2026-10-05','2026-10-05 10:00+00'),
    ('f1000005-0000-0000-0000-000000000002','dd000005-0000-0000-0000-000000000001','2026-10',
     NULL,NULL,
     '{"executive_summary":"TESTFIX draft — awaiting maintenance inputs."}'::jsonb,
     NULL,NULL,NULL,NULL,'draft','[]',NULL,NULL)
  ON CONFLICT (id) DO NOTHING;

  -- client-level operational registers (shared across programmes, §6.2)
  INSERT INTO public.operational_records
      (id, client_org_id, type, description, reported_at, reported_by, site,
       channel, deadline_rule, deadline_params, due_date, status, outcome)
  VALUES
    ('eb000005-0000-0000-0000-000000000001','cc000005-0000-0000-0000-000000000001','dsr',
     'TESTFIX access request — member of public','2026-10-08 11:00+00',
     'aa000005-0000-0000-0000-000000000012','TESTFIX Head Office','portal',
     'data_subject_request','{"received_on":"2026-10-08","channel":"portal"}',
     NULL,'Open',NULL),                       -- due_date left for engine (§9.7)
    ('eb000005-0000-0000-0000-000000000002','cc000005-0000-0000-0000-000000000001','breach',
     'TESTFIX suspected breach — unencrypted laptop lost','2026-10-09 07:30+00',
     'aa000005-0000-0000-0000-000000000012','TESTFIX Field','mobile',          -- AT-19
     'breach_notification','{"suspected_on":"2026-10-09","reported_via":"mobile"}',
     NULL,'Awaiting decision',NULL),           -- regulator_notification still NULL
    ('eb000005-0000-0000-0000-000000000003','cc000005-0000-0000-0000-000000000001','optout',
     'TESTFIX opt-out — direct marketing list','2026-09-27 10:00+00',
     'aa000005-0000-0000-0000-000000000012',NULL,'email',
     'opt_out','{"received_on":"2026-09-27"}',NULL,'Closed',
     'TESTFIX suppressed on all lists')
  ON CONFLICT (id) DO NOTHING;

  UPDATE public.operational_records
     SET closed_on = '2026-09-28 12:00+00'
   WHERE id = 'eb000005-0000-0000-0000-000000000003' AND closed_on IS NULL;

  INSERT INTO public.training_records
      (id, client_org_id, person, site, functional_group, session, date, attendance)
  VALUES
    ('ec000005-0000-0000-0000-000000000001','cc000005-0000-0000-0000-000000000001',
     'TESTFIX Staff Member One','TESTFIX Head Office','TESTFIX Finance',
     'TESTFIX POPIA induction',DATE '2026-09-15',true),
    ('ec000005-0000-0000-0000-000000000002','cc000005-0000-0000-0000-000000000001',
     'TESTFIX Staff Member Two','TESTFIX Branch','TESTFIX Operations',
     'TESTFIX POPIA induction',DATE '2026-09-15',true),
    ('ec000005-0000-0000-0000-000000000003','cc000005-0000-0000-0000-000000000001',
     'TESTFIX New Joiner','TESTFIX Head Office','TESTFIX Finance',
     'TESTFIX POPIA induction',DATE '2026-10-01',true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.controlled_documents
      (id, client_org_id, reference, title, version, owner, approval_date, next_review_date)
  VALUES
    ('ed000005-0000-0000-0000-000000000001','cc000005-0000-0000-0000-000000000001',
     'TESTFIX-POL-001','TESTFIX Privacy Policy','1.0','TESTFIX Information Officer',
     DATE '2026-09-30',DATE '2027-09-30'),
    ('ed000005-0000-0000-0000-000000000002','cc000005-0000-0000-0000-000000000001',
     'TESTFIX-PROC-002','TESTFIX Request Procedure','0.9','TESTFIX Programme Lead',
     NULL,DATE '2026-10-31')                    -- reaching review date (MM-19)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.controlled_document_activities (controlled_document_id, activity_id)
  VALUES ('ed000005-0000-0000-0000-000000000001','d3000005-0000-0000-0000-000000000003')
  ON CONFLICT DO NOTHING;

  -- audit trail rows for AT-21 (append-only ledger already exists)
  INSERT INTO public.audit_log (user_id, practice_id, action, detail) VALUES
    ('aa000005-0000-0000-0000-000000000001','bb000005-0000-0000-0000-000000000001',
     'testfix.fixture.licence_issued','{"licence":"TESTFIX Standard","client_limit":2}'),
    ('aa000005-0000-0000-0000-000000000008','bb000005-0000-0000-0000-000000000001',
     'testfix.fixture.support_grant_approved','{"grant":"f4000005-0000-0000-0000-000000000001","hours":24}');

  -- AT-22: a completed awareness cohort on C1 — report shows averages only
  INSERT INTO public.awareness_cohorts
      (id, client_org_id, framework_key, content_pack_id, department, status,
       interviewed_on, score_pct, rating, results, created_by)
  SELECT 'a1000005-0000-0000-0000-000000000001',
         'cc000005-0000-0000-0000-000000000001','popia', cp.id,
         'TESTFIX Finance','complete',DATE '2026-09-20',72,'medium',
         '{"_fixture":true,"respondents":2,"averages":{"POL":0.75,"ACC":0.66}}'::jsonb,
         'aa000005-0000-0000-0000-000000000009'
    FROM public.content_packs cp
   WHERE cp.framework_key = 'popia' AND cp.practice_id IS NULL
   ORDER BY cp.version DESC LIMIT 1
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.awareness_respondents (id, cohort_id, respondent_no, label)
  VALUES
    ('a2000005-0000-0000-0000-000000000001','a1000005-0000-0000-0000-000000000001',1,'TESTFIX-R1'),
    ('a2000005-0000-0000-0000-000000000002','a1000005-0000-0000-0000-000000000001',2,'TESTFIX-R2')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.awareness_responses (respondent_id, question_id, answer, updated_by)
  SELECT r.id, q.id, v.answer, 'aa000005-0000-0000-0000-000000000009'
    FROM (VALUES
        ('a2000005-0000-0000-0000-000000000001'::uuid,'yes'),
        ('a2000005-0000-0000-0000-000000000001'::uuid,'no'),
        ('a2000005-0000-0000-0000-000000000002'::uuid,'yes'),
        ('a2000005-0000-0000-0000-000000000002'::uuid,'no')
      ) AS v(respondent_id, answer)
    JOIN LATERAL (
        SELECT id FROM public.awareness_questions q2
         WHERE q2.framework_key = 'popia'
         ORDER BY q2.question_number
         OFFSET (v.respondent_id = 'a2000005-0000-0000-0000-000000000002'::uuid)::int * 2
                + (v.answer = 'no')::int
         LIMIT 1) q ON true
    JOIN public.awareness_respondents r ON r.id = v.respondent_id
  ON CONFLICT (respondent_id, question_id) DO NOTHING;
END $$;


-- ---------- 9. P2 — client-two (UK) programme in MAINTENANCE ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  INSERT INTO public.programmes
      (id, client_org_id, template_version_id, name, start_date, total_weeks,
       phase, status, programme_lead, programme_rag)
  VALUES
    ('dd000005-0000-0000-0000-000000000002','cc000005-0000-0000-0000-000000000002',
     'f6000005-0000-0000-0000-000000000001','TESTFIX C2 UK GDPR Programme',
     DATE '2026-06-01', 12, NULL, 'maintenance',
     'aa000005-0000-0000-0000-000000000015', 'Green')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.phases (id, programme_id, number, name, start_week, end_week)
  VALUES
    ('d1000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002',1,'TESTFIX Assess',1,4),
    ('d1000005-0000-0000-0000-000000000012','dd000005-0000-0000-0000-000000000002',2,'TESTFIX Remediate',5,12)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.workstreams (id, programme_id, name, accountable_lead)
  VALUES
    ('d2000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002','TESTFIX UK Governance','aa000005-0000-0000-0000-000000000015')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.activities
      (id, programme_id, workstream_id, ref, text, leads, start_week, end_week,
       milestone, evidence_required, status, pct_complete, actual_completion,
       phase, start_date, due_date, rag)
  VALUES
    ('d3000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002','d2000005-0000-0000-0000-000000000011',
     'A-11','TESTFIX Appoint DPO and record designation','{aa000005-0000-0000-0000-000000000014}',
     1,2,false,true,'Complete',100,DATE '2026-06-12',
     'TESTFIX Assess',DATE '2026-06-01',DATE '2026-06-12','Complete'),
    ('d3000005-0000-0000-0000-000000000012','dd000005-0000-0000-0000-000000000002','d2000005-0000-0000-0000-000000000011',
     'A-12','TESTFIX Records-of-processing baseline','{aa000005-0000-0000-0000-000000000015}',
     3,8,true,false,'Complete',100,DATE '2026-07-24',
     'TESTFIX Remediate',DATE '2026-06-15',DATE '2026-07-24','Complete')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.register_items
      (id, programme_id, ref, finding, priority, lead, planned_close_week, status,
       planned_close_date, days_overdue)
  VALUES
    ('d4000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002','R-11',
     'TESTFIX Retention schedule not published','Medium',
     'aa000005-0000-0000-0000-000000000015',12,'In progress',DATE '2026-08-21',0)
  ON CONFLICT (id) DO NOTHING;

  -- maintenance cadence on the maintenance-status programme
  INSERT INTO public.maintenance_task_templates
      (id, programme_id, template_version_id, code, task, timing_rule, owner_role,
       input_from_label, evidence_produced, feeds, sort)
  VALUES
    ('e8000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002',NULL,
     'MM-01','TESTFIX Confirm opt-outs actioned','{"window":"before_month_end"}',
     'programme_lead','Marketing lead','TESTFIX opt-out confirmation','Report',10),
    ('e8000005-0000-0000-0000-000000000012','dd000005-0000-0000-0000-000000000002',NULL,
     'MM-16','TESTFIX Issue monthly report for signature','{"window":"report_window","business_day":5}',
     'programme_lead','Accountable officer','TESTFIX issued report','Report',160)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.maintenance_task_instances
      (id, task_template_id, period, due_date, task_window, assignee, status,
       evidence_exempt_reason, completed_on)
  VALUES
    ('e9000005-0000-0000-0000-000000000011','e8000005-0000-0000-0000-000000000011','2026-10',
     DATE '2026-10-30','before_month_end','aa000005-0000-0000-0000-000000000015','Complete',
     'TESTFIX verbal confirmation recorded — none applies this period','2026-10-28 09:00+00'),
    ('e9000005-0000-0000-0000-000000000012','e8000005-0000-0000-0000-000000000012','2026-10',
     DATE '2026-10-09','report_window','aa000005-0000-0000-0000-000000000015','Pending',
     NULL,NULL)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.checklist_instances (id, programme_id, kind, period, items, generated_on)
  VALUES
    ('ea000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002',
     'quarterly','2026-Q4',
     '[{"ref":"TESTFIX-Q1","label":"TESTFIX RoPA refresh review","evidence_required":true,"done":false}]'::jsonb,
     DATE '2026-10-01'),
    ('ea000005-0000-0000-0000-000000000012','dd000005-0000-0000-0000-000000000002',
     'annual','2026',
     '[{"ref":"TESTFIX-A1","label":"TESTFIX Annual policy-suite review","evidence_required":true,"done":false},
       {"ref":"TESTFIX-A2","label":"TESTFIX Annual report to the executive","evidence_required":true,"done":false}]'::jsonb,
     DATE '2026-06-01')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.kpis
      (id, programme_id, name, unit, baseline, target, calculation, auto_calc, sort)
  VALUES
    ('e4000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002',
     'TESTFIX Requests actioned within period','%',80,95,'closed_in_period / received',true,10)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.monthly_snapshots (id, programme_id, period, snapshot, taken_at)
  VALUES
    ('ef000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002','2026-10',
     '{"activities_complete":2,"activities_overdue":0,"register_closed":0,"register_open":1,
       "high_priority_closed":0,"evidence_pending":0,"rag":"Green",
       "kpi_actuals":{},"maintenance_done":9,"maintenance_overdue":0}'::jsonb,
     '2026-10-30 18:00+00')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.programme_reports
      (id, programme_id, period, reference, snapshot_id, sections, overall_rag,
       status, signatures, due_on, issued_on)
  VALUES
    ('f1000005-0000-0000-0000-000000000011','dd000005-0000-0000-0000-000000000002','2026-10',
     'TESTFIX-RPT-2026-10-002','ef000005-0000-0000-0000-000000000011',
     '{"executive_summary":"TESTFIX steady state — maintenance routine operating."}'::jsonb,
     'Green','issued',
     '[{"role":"accountable_officer","user":"aa000005-0000-0000-0000-000000000014","at":"2026-11-03T10:00:00Z"}]'::jsonb,
     DATE '2026-11-06','2026-11-03 10:00+00')
  ON CONFLICT (id) DO NOTHING;

  -- the open UK DSR the AT-09 deadline resolution runs against
  INSERT INTO public.operational_records
      (id, client_org_id, type, description, reported_at, reported_by, site,
       channel, deadline_rule, deadline_params, due_date, status)
  VALUES
    ('eb000005-0000-0000-0000-000000000011','cc000005-0000-0000-0000-000000000002','dsr',
     'TESTFIX subject access request (UK)','2026-10-12 09:00+00',
     'aa000005-0000-0000-0000-000000000015','TESTFIX London Office','portal',
     'data_subject_request','{"received_on":"2026-10-12","channel":"portal"}',
     NULL,'Open')            -- due_date NULL: engine resolves from the UK pack
  ON CONFLICT (id) DO NOTHING;
END $$;


-- ---------- 10. P3 — partner B's client programme (cross-partner target) ----------
DO $$ BEGIN
  IF NOT pg_temp.testfix_gate() THEN RETURN; END IF;

  INSERT INTO public.programmes
      (id, client_org_id, template_version_id, name, start_date, total_weeks,
       status, programme_lead)
  VALUES
    ('dd000005-0000-0000-0000-000000000003','cc000005-0000-0000-0000-000000000003',
     'f6000005-0000-0000-0000-000000000001','TESTFIX C3 POPIA Programme',
     DATE '2026-10-05', 8, 'implementation',
     'aa000005-0000-0000-0000-000000000017')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.phases (id, programme_id, number, name, start_week, end_week)
  VALUES
    ('d1000005-0000-0000-0000-000000000021','dd000005-0000-0000-0000-000000000003',1,'TESTFIX Assess',1,4)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.workstreams (id, programme_id, name, accountable_lead)
  VALUES
    ('d2000005-0000-0000-0000-000000000021','dd000005-0000-0000-0000-000000000003','TESTFIX Governance','aa000005-0000-0000-0000-000000000017')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.activities
      (id, programme_id, workstream_id, ref, text, leads, start_week, end_week,
       milestone, evidence_required, status, pct_complete, phase, start_date, due_date, rag)
  VALUES
    ('d3000005-0000-0000-0000-000000000021','dd000005-0000-0000-0000-000000000003','d2000005-0000-0000-0000-000000000021',
     'A-21','TESTFIX Designate accountable officer','{aa000005-0000-0000-0000-000000000016}',
     1,1,false,true,'In progress',50,'TESTFIX Assess',DATE '2026-10-05',DATE '2026-10-09','Green'),
    ('d3000005-0000-0000-0000-000000000022','dd000005-0000-0000-0000-000000000003','d2000005-0000-0000-0000-000000000021',
     'A-22','TESTFIX Information inventory','{aa000005-0000-0000-0000-000000000017}',
     2,4,false,false,'Not started',0,'TESTFIX Assess',DATE '2026-10-12',DATE '2026-10-30','Not due')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.register_items
      (id, programme_id, ref, finding, priority, lead, planned_close_week, status, planned_close_date)
  VALUES
    ('d4000005-0000-0000-0000-000000000021','dd000005-0000-0000-0000-000000000003','R-21',
     'TESTFIX No privacy policy','High','aa000005-0000-0000-0000-000000000017',4,
     'Not started',DATE '2026-10-30')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.operational_records
      (id, client_org_id, type, description, reported_at, reported_by, channel,
       deadline_rule, deadline_params, status)
  VALUES
    ('eb000005-0000-0000-0000-000000000021','cc000005-0000-0000-0000-000000000003','dsr',
     'TESTFIX correction request','2026-10-20 13:00+00',
     'aa000005-0000-0000-0000-000000000017','email',
     'data_subject_request','{"received_on":"2026-10-20"}','Open')
  ON CONFLICT (id) DO NOTHING;
END $$;

-- ============================================================================
-- WIPE (documented — run ONLY in test databases):
--   ALTER TABLE evidence_items    DISABLE TRIGGER evidence_immutable;
--   ALTER TABLE programme_reports DISABLE TRIGGER report_transition_gate;
--   ALTER TABLE IF EXISTS decisions           DISABLE TRIGGER USER;  -- W1-06
--   ALTER TABLE IF EXISTS raid_status_history DISABLE TRIGGER USER;  -- W1-06
--   DELETE FROM client_orgs WHERE name LIKE 'TESTFIX%';   -- cascades all
--   ALTER TABLE evidence_items    ENABLE TRIGGER evidence_immutable;
--   ALTER TABLE programme_reports ENABLE TRIGGER report_transition_gate;
--   ALTER TABLE IF EXISTS decisions           ENABLE TRIGGER USER;   -- W1-06
--   ALTER TABLE IF EXISTS raid_status_history ENABLE TRIGGER USER;   -- W1-06
--   DELETE FROM practices  WHERE name LIKE 'TESTFIX%';    -- cascades licences
--   DELETE FROM auth.users u WHERE u.email LIKE '%@testfix.test'
--     AND NOT EXISTS (SELECT 1 FROM programme_template_versions v
--                      WHERE v.published_by = u.id AND v.status <> 'draft');
--   DELETE FROM audit_log  WHERE action LIKE 'testfix.%';
--   DELETE FROM programme_template_versions v WHERE v.status='draft'
--     AND v.template_id IN (SELECT id FROM programme_templates
--                            WHERE name LIKE 'TESTFIX%');
--   DELETE FROM programme_templates WHERE name LIKE 'TESTFIX%'
--     AND NOT EXISTS (SELECT 1 FROM programme_template_versions v
--                      WHERE v.template_id = programme_templates.id
--                        AND v.status <> 'draft');
--   -- restore jurisdiction shells (the original W0-01 INSERT values):
--   UPDATE jurisdiction_packs SET version=0, regulator_name=NULL,
--     role_labels='{"accountable_officer":null,"deputy_accountable_officer":null,"dpo":null,"programme_lead":null,"management_representative":null}',
--     deadline_params='{"data_subject_request":{"response_period_days":null,"extension_period_days":null},"breach_notification":{"regulator_period_days":null,"data_subject_period_days":null}}',
--     public_holidays='[]',
--     formats='{"date_format":null,"currency_code":null,"number_grouping":null,"week_start":null}'
--   WHERE code IN ('ZA','UK');
-- (published template versions remain — immutable records, see header)
-- ============================================================================
