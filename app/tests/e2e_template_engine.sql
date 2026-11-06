-- ============================================================================
-- W0-03 template engine — psql acceptance checks
-- Covers: publish transitions enforced (draft→published→retired; edit after
-- publish denied on every write path), the deferred
-- programmes.template_version_id FK, FR-IMP-05 import rows with reject
-- reasons, and the shared-library / partner-private / no-assignment read
-- gates. Self-contained fixtures (@w0te.test namespace); JWT callers
-- simulated via SET ROLE authenticated + request.jwt.claims.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_template_engine.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- Set/clear the simulated JWT for both auth.uid() variants: the older image
-- reads request.jwt.claim.sub (per-claim GUCs), newer gotrue/postgrest stacks
-- read the request.jwt.claims JSON blob. Setting both keeps this file portable.
CREATE OR REPLACE FUNCTION pg_temp.jwt(p_sub uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
        json_build_object('sub', p_sub::text, 'role', 'authenticated')::text, false);
  PERFORM set_config('request.jwt.claim.sub', p_sub::text, false);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', false);
END $$;
CREATE OR REPLACE FUNCTION pg_temp.nojwt() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', false);
  PERFORM set_config('request.jwt.claim.sub', '', false);
  PERFORM set_config('request.jwt.claim.role', '', false);
END $$;

-- ---------- fixtures ----------
-- teardown-safe cleanup: the immutability trigger blocks deletes of
-- published/retired versions, so suspend it for fixture cleanup only.
ALTER TABLE public.programme_template_versions DISABLE TRIGGER template_version_guard;
DELETE FROM import_rows WHERE import_run_id IN
  (SELECT r.id FROM import_runs r WHERE r.partner_id IN
     (SELECT p.id FROM practices p WHERE p.name LIKE 'W0TE%'));
DELETE FROM import_runs WHERE partner_id IN
  (SELECT p.id FROM practices p WHERE p.name LIKE 'W0TE%');
DELETE FROM maintenance_task_templates WHERE template_version_id IN
  (SELECT v.id FROM programme_template_versions v
   JOIN programme_templates tp ON tp.id = v.template_id
   WHERE tp.name LIKE 'W0TE%');
DELETE FROM programmes WHERE client_org_id IN
  (SELECT c.id FROM client_orgs c WHERE c.name LIKE 'W0TE%');
DELETE FROM requirement_mappings WHERE template_version_id IN
  (SELECT v.id FROM programme_template_versions v
   JOIN programme_templates tp ON tp.id = v.template_id
   WHERE tp.name LIKE 'W0TE%');
DELETE FROM programme_template_versions WHERE template_id IN
  (SELECT tp.id FROM programme_templates tp WHERE tp.name LIKE 'W0TE%');
ALTER TABLE public.programme_template_versions ENABLE TRIGGER template_version_guard;
DELETE FROM programme_templates WHERE name LIKE 'W0TE%';
DELETE FROM users WHERE email LIKE '%@w0te.test';
DELETE FROM auth.users WHERE email LIKE '%@w0te.test';
DELETE FROM client_orgs WHERE practice_id IN (SELECT p.id FROM practices p WHERE p.name LIKE 'W0TE%');
DELETE FROM practices WHERE name LIKE 'W0TE%';

-- NOTE: column set matches the auth.users schema on this stack (gotrue);
-- only the columns a test user actually needs are inserted.
INSERT INTO auth.users (id, instance_id, email, aud, role,
    confirmed_at, created_at, updated_at)
SELECT u.id, '00000000-0000-0000-0000-000000000000', u.email,
    'authenticated', 'authenticated',
    now(), now(), now()
FROM (VALUES
  ('ee000000-0000-0000-0000-000000000001'::uuid, 'author@w0te.test'),
  ('ee000000-0000-0000-0000-000000000002'::uuid, 'padmin@w0te.test'),
  ('ee000000-0000-0000-0000-000000000003'::uuid, 'ownerA@w0te.test'),
  ('ee000000-0000-0000-0000-000000000004'::uuid, 'ownerB@w0te.test'),
  ('ee000000-0000-0000-0000-000000000005'::uuid, 'nobody@w0te.test')
) AS u(id, email);
INSERT INTO users (id, email) SELECT id, email FROM auth.users WHERE email LIKE '%@w0te.test';

INSERT INTO practices (id, name) VALUES
  ('ff000000-0000-0000-0000-00000000000a', 'W0TE Alpha'),
  ('ff000000-0000-0000-0000-00000000000b', 'W0TE Beta');
INSERT INTO client_orgs (id, practice_id, name) VALUES
  ('aa000000-0000-0000-0000-0000000000a1', 'ff000000-0000-0000-0000-00000000000a', 'W0TE A1');

-- author: platform content_author · padmin: platform_admin ·
-- ownerA/ownerB: partner_admin of their own partner · nobody: no assignment
INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('ee000000-0000-0000-0000-000000000001','platform','content_author','partner',NULL),
  ('ee000000-0000-0000-0000-000000000002','platform','platform_admin','partner',NULL),
  ('ee000000-0000-0000-0000-000000000003','partner','partner_admin','partner','ff000000-0000-0000-0000-00000000000a'),
  ('ee000000-0000-0000-0000-000000000004','partner','partner_admin','partner','ff000000-0000-0000-0000-00000000000b');

-- ---------- content fixtures (admin-side seed; writes are revoked from
-- authenticated, so authoring rows are seeded here as the migration owner) --
INSERT INTO programme_templates (id, framework, edition, jurisdiction, name, source_refs, partner_id) VALUES
  ('bb000000-0000-0000-0000-0000000000a1','popia_paia','2022','ZA','W0TE POPIA+PAIA','["POPIA Act 4 of 2013","PAIA Act 2 of 2000"]',NULL),
  ('bb000000-0000-0000-0000-0000000000a2','iso27001','2022',NULL,'W0TE ISO27001','["ISO/IEC 27001:2022 clause refs"]',NULL),
  ('bb000000-0000-0000-0000-0000000000a3','cyber_essentials','v3.1','UK','W0TE CE Alpha variant','["NCSC CE requirements"]','ff000000-0000-0000-0000-00000000000a');

-- full §5.1 content (all eleven component keys; empty is fine, missing is not)
INSERT INTO programme_template_versions (id, template_id, number, status, release_notes, content) VALUES
  ('cc000000-0000-0000-0000-0000000000b1','bb000000-0000-0000-0000-0000000000a1',1,'draft','v1 first cut',
   '{"phases":[],"workstreams":[],"activity_library":[],"findings_map":{},
     "document_set":[],"kpis":[],"maintenance_set":[],"quarterly_annual_cycles":{},
     "registers":[],"report_structure":{},"role_labels":{}}'),
  ('cc000000-0000-0000-0000-0000000000b2','bb000000-0000-0000-0000-0000000000a1',2,'draft','v2 incomplete',
   '{"phases":[],"workstreams":[]}'),
  ('cc000000-0000-0000-0000-0000000000b3','bb000000-0000-0000-0000-0000000000a3',1,'draft','alpha variant',
   '{"phases":[],"workstreams":[],"activity_library":[],"findings_map":{},
     "document_set":[],"kpis":[],"maintenance_set":[],"quarterly_annual_cycles":{},
     "registers":[],"report_structure":{},"role_labels":{}}'),
  ('cc000000-0000-0000-0000-0000000000b4','bb000000-0000-0000-0000-0000000000a2',1,'draft','iso draft',
   '{"phases":[],"workstreams":[],"activity_library":[],"findings_map":{},
     "document_set":[],"kpis":[],"maintenance_set":[],"quarterly_annual_cycles":{},
     "registers":[],"report_structure":{},"role_labels":{}}');

INSERT INTO requirement_mappings (template_version_id, requirement_ref_a, requirement_ref_b, mapping_type) VALUES
  ('cc000000-0000-0000-0000-0000000000b1','popia:s.19(1)','iso27701:6.3.1','partial');

-- ---------- publish path (FR-TPL-01) ----------
-- tenant partner_admin may NOT publish
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000003');
DO $$
BEGIN
  BEGIN
    PERFORM public.publish_template_version('cc000000-0000-0000-0000-0000000000b1');
    PERFORM pg_temp.t(false,'partner_admin publish denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'partner_admin publish denied: '||SQLERRM);
  END;
END $$;
RESET ROLE;
SELECT pg_temp.nojwt();

-- incomplete content can NOT publish (missing §5.1 keys)
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000001');
DO $$
BEGIN
  BEGIN
    PERFORM public.publish_template_version('cc000000-0000-0000-0000-0000000000b2');
    PERFORM pg_temp.t(false,'publish of incomplete §5.1 content denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%missing §5.1 components%',
                      'publish of incomplete §5.1 content denied: '||SQLERRM);
  END;
END $$;

-- content_author publishes v1 — draft → published, stamps by/at
SELECT (public.publish_template_version('cc000000-0000-0000-0000-0000000000b1')).status AS v1_status;
RESET ROLE;
SELECT pg_temp.nojwt();
SELECT pg_temp.t(
  (SELECT status FROM programme_template_versions WHERE id='cc000000-0000-0000-0000-0000000000b1') = 'published'
  AND (SELECT published_by FROM programme_template_versions WHERE id='cc000000-0000-0000-0000-0000000000b1')
      = 'ee000000-0000-0000-0000-000000000001'
  AND (SELECT published_at FROM programme_template_versions WHERE id='cc000000-0000-0000-0000-0000000000b1') IS NOT NULL,
  'content_author publish: v1 published with published_by/at stamped');

-- ---------- published immutability (every write path) ----------
-- 1) direct SQL as the admin/owner — the trigger must still refuse
DO $$
BEGIN
  BEGIN
    UPDATE programme_template_versions SET content = '{"phases":[]}'
      WHERE id = 'cc000000-0000-0000-0000-0000000000b1';
    PERFORM pg_temp.t(false,'published content UPDATE denied (admin path)');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(SQLERRM LIKE '%immutable%',
                      'published content UPDATE denied (admin path): '||SQLERRM);
  END;
  BEGIN
    UPDATE programme_template_versions SET release_notes = 'rewrite history'
      WHERE id = 'cc000000-0000-0000-0000-0000000000b1';
    PERFORM pg_temp.t(false,'published release_notes UPDATE denied');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'published release_notes UPDATE denied: '||SQLERRM);
  END;
END $$;

-- 2) authenticated role has no UPDATE grant at all
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000001');
DO $$
BEGIN
  BEGIN
    UPDATE programme_template_versions SET content = '{}'
      WHERE id = 'cc000000-0000-0000-0000-0000000000b1';
    PERFORM pg_temp.t(false,'authenticated has no UPDATE on versions');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true,'authenticated has no UPDATE on versions: '||SQLERRM);
  END;
  BEGIN
    INSERT INTO programme_templates (framework, name) VALUES ('x','W0TE direct insert');
    PERFORM pg_temp.t(false,'authenticated has no INSERT on templates');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.t(true,'authenticated has no INSERT on templates: '||SQLERRM);
  END;
END $$;
RESET ROLE;
SELECT pg_temp.nojwt();

-- ---------- published → retired ----------
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000001');
SELECT (public.retire_template_version('cc000000-0000-0000-0000-0000000000b1')).status AS v1_status2;
RESET ROLE;
SELECT pg_temp.nojwt();
SELECT pg_temp.t(
  (SELECT status FROM programme_template_versions WHERE id='cc000000-0000-0000-0000-0000000000b1') = 'retired',
  'retire: published → retired via RPC');

-- retired rows reject every change and every delete
DO $$
BEGIN
  BEGIN
    UPDATE programme_template_versions SET release_notes = 'x'
      WHERE id = 'cc000000-0000-0000-0000-0000000000b1';
    PERFORM pg_temp.t(false,'retired version rejects UPDATE');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'retired version rejects UPDATE: '||SQLERRM);
  END;
  BEGIN
    DELETE FROM programme_template_versions WHERE id = 'cc000000-0000-0000-0000-0000000000b1';
    PERFORM pg_temp.t(false,'retired version rejects DELETE');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'retired version rejects DELETE: '||SQLERRM);
  END;
  -- publishing again is denied (not a draft)
  BEGIN
    UPDATE programme_template_versions SET status='published',
      published_by='ee000000-0000-0000-0000-000000000001', published_at=now()
      WHERE id = 'cc000000-0000-0000-0000-0000000000b1';
    PERFORM pg_temp.t(false,'retired version cannot be republished');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'retired version cannot be republished: '||SQLERRM);
  END;
END $$;

-- draft → retired allowed (discard); draft delete allowed
UPDATE programme_template_versions SET status='retired'
  WHERE id = 'cc000000-0000-0000-0000-0000000000b4';
SELECT pg_temp.t(
  (SELECT status FROM programme_template_versions WHERE id='cc000000-0000-0000-0000-0000000000b4') = 'retired',
  'draft → retired allowed (discard path)');

-- draft v2 stays editable while draft: fix content, then publish
UPDATE programme_template_versions
  SET content = '{"phases":[],"workstreams":[],"activity_library":[],"findings_map":{},
                  "document_set":[],"kpis":[],"maintenance_set":[],"quarterly_annual_cycles":{},
                  "registers":[],"report_structure":{},"role_labels":{}}'
  WHERE id = 'cc000000-0000-0000-0000-0000000000b2';
SELECT pg_temp.t(true,'draft content UPDATE allowed (still draft)');
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000001');
SELECT (public.publish_template_version('cc000000-0000-0000-0000-0000000000b2')).status AS v2_status;
SELECT (public.publish_template_version('cc000000-0000-0000-0000-0000000000b3')).status AS v3_status;
RESET ROLE;
SELECT pg_temp.nojwt();
SELECT pg_temp.t(
  (SELECT status FROM programme_template_versions WHERE id='cc000000-0000-0000-0000-0000000000b2') = 'published'
  AND (SELECT status FROM programme_template_versions WHERE id='cc000000-0000-0000-0000-0000000000b3') = 'published',
  'drafts v2 (fixed) + v3 (alpha variant) publish cleanly');

-- ---------- deferred FK: programmes.template_version_id ----------
INSERT INTO programmes (client_org_id, template_version_id, name, start_date, total_weeks)
VALUES ('aa000000-0000-0000-0000-0000000000a1','cc000000-0000-0000-0000-0000000000b2','W0TE prog A1',DATE '2026-11-02',10);
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM programmes p
    JOIN programme_template_versions v ON v.id = p.template_version_id
    WHERE p.name = 'W0TE prog A1' AND v.number = 2),
  'programme created from published template_version_id (FK live, joins)');
DO $$
BEGIN
  BEGIN
    INSERT INTO programmes (client_org_id, template_version_id, name, start_date, total_weeks)
    VALUES ('aa000000-0000-0000-0000-0000000000a1', gen_random_uuid(), 'W0TE prog bogus', DATE '2026-11-02', 10);
    PERFORM pg_temp.t(false,'programme FK rejects unknown template_version_id');
  EXCEPTION WHEN foreign_key_violation THEN
    PERFORM pg_temp.t(true,'programme FK rejects unknown template_version_id');
  END;
END $$;
-- second deferred FK from 00003: maintenance_task_templates.template_version_id
INSERT INTO maintenance_task_templates (template_version_id, code, task, timing_rule)
VALUES ('cc000000-0000-0000-0000-0000000000b2','MM-01','W0TE monthly check','{"window":"month_end_close","business_day":5}');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM maintenance_task_templates
    WHERE template_version_id='cc000000-0000-0000-0000-0000000000b2' AND code='MM-01'),
  'maintenance_task_templates.template_version_id FK live (content row)');

-- ---------- import_runs / import_rows (§13.1 FR-IMP-05) ----------
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000003');
INSERT INTO import_runs (partner_id, kind, file_ref, status, preview)
VALUES ('ff000000-0000-0000-0000-00000000000a',
        'findings','storage://w0te/findings.xlsx','previewed','{"rows":3,"rejected":1}');
SELECT id AS runid FROM import_runs WHERE file_ref='storage://w0te/findings.xlsx' \gset
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM import_runs WHERE id=:'runid'
    AND created_by='ee000000-0000-0000-0000-000000000003'),
  'partner_admin creates import_run; created_by stamped from JWT');
INSERT INTO import_rows (import_run_id, row_no, raw, status, reject_reason, mapped_entity) VALUES
  (:'runid',1,'{"ref":"A1"}','rejected','unparseable finding date',NULL),
  (:'runid',2,'{"ref":"A2"}','ok',NULL,'register_items:pending');
SELECT pg_temp.t((SELECT count(*) FROM import_rows
      WHERE import_run_id=:'runid'
        AND status='rejected' AND reject_reason IS NOT NULL) = 1,
  'rejected import row records reject_reason (FR-IMP-05)');
DO $$
BEGIN
  BEGIN
    INSERT INTO import_rows (import_run_id, row_no, raw, status)
    VALUES ((SELECT id FROM import_runs WHERE file_ref='storage://w0te/findings.xlsx'),3,'{"ref":"A3"}','rejected');
    PERFORM pg_temp.t(false,'rejected row without reject_reason denied');
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.t(true,'rejected row without reject_reason denied (CHECK)');
  END;
  BEGIN
    INSERT INTO import_runs (partner_id, kind)
    VALUES ('ff000000-0000-0000-0000-00000000000b','findings');
    PERFORM pg_temp.t(false,'partner_admin cannot insert run for another partner');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t(true,'partner_admin cannot insert run for another partner: '||SQLERRM);
  END;
END $$;
RESET ROLE;
SELECT pg_temp.nojwt();

-- ownerB sees nothing of Alpha's imports
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000004');
SELECT pg_temp.t((SELECT count(*) FROM import_runs) = 0,
  'import_runs partner-scope: Beta admin sees none of Alpha''s runs');
SELECT pg_temp.t((SELECT count(*) FROM import_rows) = 0,
  'import_rows partner-scope: Beta admin sees none of Alpha''s rows');
RESET ROLE;
SELECT pg_temp.nojwt();

-- ---------- shared-library read gates ----------
-- ownerA (any active assignment): sees published/retired versions incl. the
-- Alpha-private published variant; no drafts.
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000003');
SELECT pg_temp.t((SELECT count(*) FROM programme_templates WHERE name LIKE 'W0TE%') = 3,
  'ownerA sees all 3 templates (2 shared + own partner variant)');
SELECT pg_temp.t((SELECT count(*) FROM programme_template_versions v
      JOIN programme_templates tp ON tp.id=v.template_id
      WHERE tp.name LIKE 'W0TE%'
        AND v.id IN ('cc000000-0000-0000-0000-0000000000b1','cc000000-0000-0000-0000-0000000000b2',
                     'cc000000-0000-0000-0000-0000000000b3','cc000000-0000-0000-0000-0000000000b4')) = 4,
  'ownerA reads all published+retired versions (v1 retired, v2/v3 published, v4 retired)');
SELECT pg_temp.t((SELECT count(*) FROM requirement_mappings) = 1,
  'ownerA reads requirement_mappings on visible versions');
-- ownerB: shared library but NOT the Alpha-private variant
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000004');
SELECT pg_temp.t((SELECT count(*) FROM programme_templates WHERE name LIKE 'W0TE%') = 2,
  'ownerB sees only the 2 shared templates (Alpha variant hidden)');
SELECT pg_temp.t(NOT EXISTS (
      SELECT 1 FROM programme_template_versions
      WHERE id='cc000000-0000-0000-0000-0000000000b3'),
  'ownerB cannot read the Alpha-private published version');
-- nobody: authenticated but zero assignments → nothing
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000005');
SELECT pg_temp.t((SELECT count(*) FROM programme_templates) = 0
    AND (SELECT count(*) FROM programme_template_versions) = 0,
  'user with no active assignment sees no template content');
-- content_author additionally sees drafts (none left after publish; create one)
RESET ROLE;
SELECT pg_temp.nojwt();
INSERT INTO programme_template_versions (template_id, number, status, content)
VALUES ('bb000000-0000-0000-0000-0000000000a2',2,'draft','{"phases":[]}');
SET ROLE authenticated;
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000001');
SELECT pg_temp.t(EXISTS (
      SELECT 1 FROM programme_template_versions
      WHERE template_id='bb000000-0000-0000-0000-0000000000a2' AND number=2),
  'content_author sees draft versions');
SELECT pg_temp.jwt('ee000000-0000-0000-0000-000000000003');
SELECT pg_temp.t(NOT EXISTS (
      SELECT 1 FROM programme_template_versions
      WHERE template_id='bb000000-0000-0000-0000-0000000000a2' AND number=2),
  'partner_admin does NOT see draft versions');
RESET ROLE;
SELECT pg_temp.nojwt();

-- ---------- teardown ----------
ALTER TABLE public.programme_template_versions DISABLE TRIGGER template_version_guard;
DELETE FROM import_rows WHERE import_run_id IN
  (SELECT r.id FROM import_runs r WHERE r.partner_id IN
     (SELECT p.id FROM practices p WHERE p.name LIKE 'W0TE%'));
DELETE FROM import_runs WHERE partner_id IN
  (SELECT p.id FROM practices p WHERE p.name LIKE 'W0TE%');
DELETE FROM maintenance_task_templates WHERE template_version_id IN
  (SELECT v.id FROM programme_template_versions v
   JOIN programme_templates tp ON tp.id=v.template_id WHERE tp.name LIKE 'W0TE%');
DELETE FROM programmes WHERE client_org_id IN
  (SELECT c.id FROM client_orgs c WHERE c.name LIKE 'W0TE%');
DELETE FROM requirement_mappings WHERE template_version_id IN
  (SELECT v.id FROM programme_template_versions v
   JOIN programme_templates tp ON tp.id=v.template_id WHERE tp.name LIKE 'W0TE%');
DELETE FROM programme_template_versions WHERE template_id IN
  (SELECT tp.id FROM programme_templates tp WHERE tp.name LIKE 'W0TE%');
ALTER TABLE public.programme_template_versions ENABLE TRIGGER template_version_guard;
DELETE FROM programme_templates WHERE name LIKE 'W0TE%';
DELETE FROM role_assignments WHERE user_id IN
  (SELECT u.id FROM users u WHERE u.email LIKE '%@w0te.test');
DELETE FROM users WHERE email LIKE '%@w0te.test';
DELETE FROM auth.users WHERE email LIKE '%@w0te.test';
DELETE FROM client_orgs WHERE practice_id IN (SELECT p.id FROM practices p WHERE p.name LIKE 'W0TE%');
DELETE FROM practices WHERE name LIKE 'W0TE%';
\echo '=== e2e_template_engine checks done ==='
