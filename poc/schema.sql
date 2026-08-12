-- SecurePath POC: two-level tenancy (Practice -> Client Org) with RLS isolation.
-- App connects as role `app_user` (no BYPASSRLS). Tenant identity comes from
-- session settings app.user_id / app.practice_id, set per-request from the verified JWT.

CREATE ROLE app_user LOGIN PASSWORD 'poc_only' NOSUPERUSER NOCREATEDB NOCREATEROLE;

CREATE TABLE practices (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    logo_url    text,
    accent_hex  text
);

CREATE TABLE client_orgs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    practice_id uuid NOT NULL REFERENCES practices(id),
    name        text NOT NULL
);

CREATE TABLE users (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email       text NOT NULL UNIQUE
);

-- one practice per user for MVP; role is one of the 5 fixed roles
CREATE TABLE memberships (
    user_id     uuid NOT NULL REFERENCES users(id),
    practice_id uuid NOT NULL REFERENCES practices(id),
    role        text NOT NULL CHECK (role IN
                  ('practice_owner','practice_consultant','client_admin','client_contributor','read_only')),
    -- client-side roles are pinned to exactly one client org
    client_org_id uuid REFERENCES client_orgs(id),
    PRIMARY KEY (user_id),
    CHECK ( (role IN ('client_admin','client_contributor')) = (client_org_id IS NOT NULL) )
);

-- spec F1.2: consultant-to-client assignment matrix
CREATE TABLE consultant_assignments (
    user_id       uuid NOT NULL REFERENCES users(id),
    client_org_id uuid NOT NULL REFERENCES client_orgs(id),
    PRIMARY KEY (user_id, client_org_id)
);

-- representative domain table; every future domain table follows this shape
CREATE TABLE assessments (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id uuid NOT NULL REFERENCES client_orgs(id),
    title         text NOT NULL,
    score         numeric
);

-- append-only audit log (F1.5)
CREATE TABLE audit_log (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at            timestamptz NOT NULL DEFAULT now(),
    user_id       uuid,
    practice_id   uuid,
    action        text NOT NULL,
    detail        jsonb
);

-- ---------- helpers ----------
CREATE FUNCTION current_app_user() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

-- practice of the current user, derived server-side (never trusted from client)
CREATE FUNCTION current_practice() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT practice_id FROM memberships WHERE user_id = current_app_user()
$$;

CREATE FUNCTION current_role_name() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT role FROM memberships WHERE user_id = current_app_user()
$$;

-- client orgs the current user may touch
CREATE FUNCTION allowed_client_orgs() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT co.id
  FROM memberships m
  JOIN client_orgs co ON co.practice_id = m.practice_id
  WHERE m.user_id = current_app_user()
    AND ( m.role = 'practice_owner'
          OR m.role = 'read_only'
          OR (m.role = 'practice_consultant'
              AND EXISTS (SELECT 1 FROM consultant_assignments ca
                          WHERE ca.user_id = m.user_id AND ca.client_org_id = co.id))
          OR (m.role IN ('client_admin','client_contributor') AND co.id = m.client_org_id) )
$$;

-- ---------- RLS: default-deny, forced ----------
ALTER TABLE practices             ENABLE ROW LEVEL SECURITY;
ALTER TABLE practices             FORCE  ROW LEVEL SECURITY;
ALTER TABLE client_orgs           ENABLE ROW LEVEL SECURITY;
ALTER TABLE client_orgs           FORCE  ROW LEVEL SECURITY;
ALTER TABLE memberships           ENABLE ROW LEVEL SECURITY;
ALTER TABLE memberships           FORCE  ROW LEVEL SECURITY;
ALTER TABLE consultant_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE consultant_assignments FORCE  ROW LEVEL SECURITY;
ALTER TABLE assessments           ENABLE ROW LEVEL SECURITY;
ALTER TABLE assessments           FORCE  ROW LEVEL SECURITY;
ALTER TABLE audit_log             ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log             FORCE  ROW LEVEL SECURITY;

CREATE POLICY practice_read ON practices FOR SELECT TO app_user
  USING (id = current_practice());

CREATE POLICY client_orgs_read ON client_orgs FOR SELECT TO app_user
  USING (id IN (SELECT allowed_client_orgs()));

CREATE POLICY client_orgs_write ON client_orgs FOR ALL TO app_user
  USING (practice_id = current_practice() AND current_role_name() = 'practice_owner')
  WITH CHECK (practice_id = current_practice() AND current_role_name() = 'practice_owner');

CREATE POLICY memberships_self ON memberships FOR SELECT TO app_user
  USING (user_id = current_app_user() OR
         (practice_id = current_practice() AND current_role_name() = 'practice_owner'));

CREATE POLICY assignments_read ON consultant_assignments FOR SELECT TO app_user
  USING (user_id = current_app_user() OR
         EXISTS (SELECT 1 FROM memberships m WHERE m.user_id = current_app_user()
                 AND m.role = 'practice_owner'
                 AND m.practice_id = (SELECT practice_id FROM client_orgs c WHERE c.id = client_org_id)));

CREATE POLICY assessments_read ON assessments FOR SELECT TO app_user
  USING (client_org_id IN (SELECT allowed_client_orgs()));

CREATE POLICY assessments_write ON assessments FOR ALL TO app_user
  USING (client_org_id IN (SELECT allowed_client_orgs()) AND current_role_name() <> 'read_only')
  WITH CHECK (client_org_id IN (SELECT allowed_client_orgs()) AND current_role_name() <> 'read_only');

-- audit: insert-only for app; nobody updates/deletes
CREATE POLICY audit_insert ON audit_log FOR INSERT TO app_user WITH CHECK (true);
CREATE POLICY audit_read   ON audit_log FOR SELECT TO app_user
  USING (practice_id = current_practice() AND current_role_name() = 'practice_owner');

GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
REVOKE UPDATE, DELETE ON audit_log FROM app_user;  -- append-only at grant level too
