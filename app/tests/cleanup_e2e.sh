#!/usr/bin/env bash
# Automated teardown for e2e_pipeline.py / e2e_isolation.py test data on staging.
# Runs the documented cleanup (E2E_PIPELINE.md) as supabase_admin via the staging DB
# container. Deletes ONLY practices named by the test namespaces and @resend.dev users.
#
# Usage: app/tests/cleanup_e2e.sh [path-to-staging-dir]   (default: ./staging)
set -euo pipefail

STAGING_DIR="${1:-$(dirname "$0")/../../staging}"
PW=$(grep '^POSTGRES_PASSWORD=' "$STAGING_DIR/.env" | cut -d= -f2)

docker exec -i -e PGPASSWORD="$PW" securepath-staging-db-1 \
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U supabase_admin -d postgres <<'SQL'
DO $$ DECLARE junk uuid[];
BEGIN
  -- pipeline-suite namespaces + the isolation suite's fixed practice names
  SELECT array_agg(id) INTO junk FROM practices
    WHERE name ~ '^(guard-|pipe |accept |immut )' OR name IN ('MSP Alpha', 'MSP Beta');
  IF junk IS NULL THEN RAISE NOTICE 'no test practices found'; RETURN; END IF;
  DELETE FROM document_links   WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM monthly_reports  WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM manuals          WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM policies         WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM tasks            WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM documents        WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  -- break the tracks <-> assessment_sessions FK cycle before deleting either
  UPDATE assessment_sessions SET track_id = NULL WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  UPDATE tracks SET baseline_session_id = NULL WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM stage_transitions WHERE track_id IN (SELECT t.id FROM tracks t JOIN client_orgs c ON c.id=t.client_org_id WHERE c.practice_id=ANY(junk));
  DELETE FROM tracks           WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM assessment_responses WHERE session_id IN (SELECT s.id FROM assessment_sessions s JOIN client_orgs c ON c.id=s.client_org_id WHERE c.practice_id=ANY(junk));
  DELETE FROM assessment_scores    WHERE session_id IN (SELECT s.id FROM assessment_sessions s JOIN client_orgs c ON c.id=s.client_org_id WHERE c.practice_id=ANY(junk));
  DELETE FROM assessment_sessions  WHERE client_org_id IN (SELECT id FROM client_orgs WHERE practice_id=ANY(junk));
  DELETE FROM approvals        WHERE practice_id=ANY(junk);
  DELETE FROM billing_events   WHERE practice_id=ANY(junk);
  DELETE FROM notifications    WHERE practice_id=ANY(junk);
  DELETE FROM audit_log        WHERE practice_id=ANY(junk);
  DELETE FROM memberships      WHERE practice_id=ANY(junk);
  DELETE FROM client_orgs      WHERE practice_id=ANY(junk);
  DELETE FROM practices        WHERE id=ANY(junk);
END $$;
DELETE FROM public.users WHERE email ~ '@resend.dev$';
DELETE FROM auth.users   WHERE email ~ '@resend.dev$';
SQL

echo "e2e test data cleaned."
