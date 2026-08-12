-- Isolation test suite (spec F1: "tenant isolation verified by test").
-- Seeds two practices with clients/users, then asserts every cross-tenant
-- access path returns zero rows / fails. Any leak raises an exception -> nonzero exit.

\set ON_ERROR_STOP on

-- ---------- seed (as superuser) ----------
INSERT INTO practices (id, name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'MSP Alpha'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'MSP Beta');

INSERT INTO client_orgs (id, practice_id, name) VALUES
  ('aaaaaaaa-1111-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'Alpha Client 1'),
  ('aaaaaaaa-1111-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'Alpha Client 2'),
  ('bbbbbbbb-1111-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Beta Client 1');

INSERT INTO users (id, email) VALUES
  ('aaaaaaaa-2222-0000-0000-000000000001', 'owner@alpha.test'),
  ('aaaaaaaa-2222-0000-0000-000000000002', 'consultant@alpha.test'),
  ('aaaaaaaa-2222-0000-0000-000000000003', 'admin@alphaclient1.test'),
  ('bbbbbbbb-2222-0000-0000-000000000001', 'owner@beta.test');

INSERT INTO memberships (user_id, practice_id, role, client_org_id) VALUES
  ('aaaaaaaa-2222-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'practice_owner', NULL),
  ('aaaaaaaa-2222-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'practice_consultant', NULL),
  ('aaaaaaaa-2222-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', 'client_admin', 'aaaaaaaa-1111-0000-0000-000000000001'),
  ('bbbbbbbb-2222-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'practice_owner', NULL);

-- consultant assigned ONLY to Alpha Client 1
INSERT INTO consultant_assignments VALUES
  ('aaaaaaaa-2222-0000-0000-000000000002', 'aaaaaaaa-1111-0000-0000-000000000001');

INSERT INTO assessments (id, client_org_id, title, score) VALUES
  ('aaaaaaaa-3333-0000-0000-000000000001', 'aaaaaaaa-1111-0000-0000-000000000001', 'Alpha C1 POPIA baseline', 61),
  ('aaaaaaaa-3333-0000-0000-000000000002', 'aaaaaaaa-1111-0000-0000-000000000002', 'Alpha C2 POPIA baseline', 47),
  ('bbbbbbbb-3333-0000-0000-000000000001', 'bbbbbbbb-1111-0000-0000-000000000001', 'Beta C1 POPIA baseline', 82);

-- ---------- helpers ----------
CREATE OR REPLACE FUNCTION assert_count(label text, actual bigint, expected bigint)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'FAIL %: expected %, got %', label, expected, actual;
  END IF;
  RAISE NOTICE 'PASS %', label;
END $$;

-- run the whole suite as the unprivileged app role
SET ROLE app_user;

-- ---------- Beta owner sees only Beta ----------
SET app.user_id = 'bbbbbbbb-2222-0000-0000-000000000001';
SELECT assert_count('beta owner: practices visible',   (SELECT count(*) FROM practices), 1);
SELECT assert_count('beta owner: client orgs visible', (SELECT count(*) FROM client_orgs), 1);
SELECT assert_count('beta owner: assessments visible', (SELECT count(*) FROM assessments), 1);
SELECT assert_count('beta owner: cannot see alpha assessment by id',
  (SELECT count(*) FROM assessments WHERE id = 'aaaaaaaa-3333-0000-0000-000000000001'), 0);

-- write into Alpha must fail (WITH CHECK)
DO $$
BEGIN
  BEGIN
    INSERT INTO assessments (client_org_id, title) VALUES ('aaaaaaaa-1111-0000-0000-000000000001', 'intrusion');
    RAISE EXCEPTION 'FAIL beta owner: cross-tenant INSERT was allowed';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    RAISE NOTICE 'PASS beta owner: cross-tenant INSERT blocked';
  END;
END $$;

-- cross-tenant UPDATE/DELETE silently affect 0 rows
UPDATE assessments SET score = 0 WHERE id = 'aaaaaaaa-3333-0000-0000-000000000001';
SELECT assert_count('beta owner: cross-tenant UPDATE rows', 0, 0);
DELETE FROM assessments WHERE id = 'aaaaaaaa-3333-0000-0000-000000000001';

-- ---------- Alpha consultant sees only assigned client ----------
SET app.user_id = 'aaaaaaaa-2222-0000-0000-000000000002';
SELECT assert_count('alpha consultant: client orgs visible', (SELECT count(*) FROM client_orgs), 1);
SELECT assert_count('alpha consultant: assessments visible', (SELECT count(*) FROM assessments), 1);
SELECT assert_count('alpha consultant: unassigned sibling client hidden',
  (SELECT count(*) FROM assessments WHERE client_org_id = 'aaaaaaaa-1111-0000-0000-000000000002'), 0);

-- ---------- Alpha client admin sees only own org ----------
SET app.user_id = 'aaaaaaaa-2222-0000-0000-000000000003';
SELECT assert_count('client admin: client orgs visible', (SELECT count(*) FROM client_orgs), 1);
SELECT assert_count('client admin: assessments visible', (SELECT count(*) FROM assessments), 1);
SELECT assert_count('client admin: other tenants invisible',
  (SELECT count(*) FROM assessments WHERE client_org_id <> 'aaaaaaaa-1111-0000-0000-000000000001'), 0);

-- ---------- spoofing: unknown user id sees nothing ----------
SET app.user_id = 'cccccccc-2222-0000-0000-000000000001';
SELECT assert_count('unknown user: practices', (SELECT count(*) FROM practices), 0);
SELECT assert_count('unknown user: assessments', (SELECT count(*) FROM assessments), 0);

-- ---------- no user context sees nothing ----------
RESET app.user_id;
SELECT assert_count('no context: practices', (SELECT count(*) FROM practices), 0);
SELECT assert_count('no context: assessments', (SELECT count(*) FROM assessments), 0);

-- ---------- audit log append-only ----------
SET app.user_id = 'aaaaaaaa-2222-0000-0000-000000000001';
INSERT INTO audit_log (user_id, practice_id, action) VALUES
  ('aaaaaaaa-2222-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'test.write');
DO $$
BEGIN
  BEGIN
    UPDATE audit_log SET action = 'tampered';
    RAISE EXCEPTION 'FAIL audit: UPDATE was allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS audit: UPDATE blocked';
  END;
  BEGIN
    DELETE FROM audit_log;
    RAISE EXCEPTION 'FAIL audit: DELETE was allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS audit: DELETE blocked';
  END;
END $$;

RESET ROLE;
SELECT 'ALL ISOLATION TESTS PASSED' AS result;
