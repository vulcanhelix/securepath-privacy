-- Tenancy core: Practice (MSP) -> Client Organisation, 5 fixed roles, RLS everywhere.
-- Identity comes from GoTrue: auth.uid() = auth.users.id. App-side profile rows in
-- public.users reference auth.users 1:1.

CREATE TABLE public.practices (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    logo_url    text,
    accent_hex  text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.client_orgs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    practice_id uuid NOT NULL REFERENCES public.practices(id),
    name        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.users (
    id          uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email       text NOT NULL UNIQUE,
    full_name   text
);

-- one practice per user (MVP decision 2026-07-23); 5 fixed roles
CREATE TABLE public.memberships (
    user_id       uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    practice_id   uuid NOT NULL REFERENCES public.practices(id),
    role          text NOT NULL CHECK (role IN
                    ('practice_owner','practice_consultant','client_admin','client_contributor','read_only')),
    client_org_id uuid REFERENCES public.client_orgs(id),
    CHECK ( (role IN ('client_admin','client_contributor')) = (client_org_id IS NOT NULL) )
);

-- spec F1.2: consultant-to-client assignment matrix
CREATE TABLE public.consultant_assignments (
    user_id       uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    client_org_id uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, client_org_id)
);

-- representative domain table; every domain table follows this shape
CREATE TABLE public.assessments (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id uuid NOT NULL REFERENCES public.client_orgs(id),
    title         text NOT NULL,
    score         numeric,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- F1.5 immutable audit log
CREATE TABLE public.audit_log (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at          timestamptz NOT NULL DEFAULT now(),
    user_id     uuid,
    practice_id uuid,
    action      text NOT NULL,
    detail      jsonb
);

-- ---------- helpers (SECURITY DEFINER so RLS on memberships doesn't recurse) ----------
CREATE FUNCTION public.current_practice() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT practice_id FROM memberships WHERE user_id = auth.uid()
$$;

CREATE FUNCTION public.current_role_name() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT role FROM memberships WHERE user_id = auth.uid()
$$;

CREATE FUNCTION public.allowed_client_orgs() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT co.id
  FROM memberships m
  JOIN client_orgs co ON co.practice_id = m.practice_id
  WHERE m.user_id = auth.uid()
    AND ( m.role IN ('practice_owner','read_only')
          OR (m.role = 'practice_consultant'
              AND EXISTS (SELECT 1 FROM consultant_assignments ca
                          WHERE ca.user_id = m.user_id AND ca.client_org_id = co.id))
          OR (m.role IN ('client_admin','client_contributor') AND co.id = m.client_org_id) )
$$;

-- ---------- RLS: default-deny, forced ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['practices','client_orgs','users','memberships',
                           'consultant_assignments','assessments','audit_log'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

CREATE POLICY practices_read ON public.practices FOR SELECT TO authenticated
  USING (id = public.current_practice());
CREATE POLICY practices_update ON public.practices FOR UPDATE TO authenticated
  USING (id = public.current_practice() AND public.current_role_name() = 'practice_owner')
  WITH CHECK (id = public.current_practice());

CREATE POLICY client_orgs_read ON public.client_orgs FOR SELECT TO authenticated
  USING (id IN (SELECT public.allowed_client_orgs()));
CREATE POLICY client_orgs_write ON public.client_orgs FOR ALL TO authenticated
  USING (practice_id = public.current_practice() AND public.current_role_name() = 'practice_owner')
  WITH CHECK (practice_id = public.current_practice() AND public.current_role_name() = 'practice_owner');

CREATE POLICY users_self ON public.users FOR SELECT TO authenticated
  USING (id = auth.uid()
         OR (public.current_role_name() = 'practice_owner'
             AND EXISTS (SELECT 1 FROM public.memberships m
                         WHERE m.user_id = users.id AND m.practice_id = public.current_practice())));
CREATE POLICY users_insert_self ON public.users FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

CREATE POLICY memberships_read ON public.memberships FOR SELECT TO authenticated
  USING (user_id = auth.uid()
         OR (practice_id = public.current_practice() AND public.current_role_name() = 'practice_owner'));

CREATE POLICY assignments_read ON public.consultant_assignments FOR SELECT TO authenticated
  USING (user_id = auth.uid()
         OR (public.current_role_name() = 'practice_owner'
             AND EXISTS (SELECT 1 FROM public.client_orgs c
                         WHERE c.id = client_org_id AND c.practice_id = public.current_practice())));
CREATE POLICY assignments_write ON public.consultant_assignments FOR ALL TO authenticated
  USING (public.current_role_name() = 'practice_owner'
         AND EXISTS (SELECT 1 FROM public.client_orgs c
                     WHERE c.id = client_org_id AND c.practice_id = public.current_practice()))
  WITH CHECK (public.current_role_name() = 'practice_owner'
              AND EXISTS (SELECT 1 FROM public.client_orgs c
                          WHERE c.id = client_org_id AND c.practice_id = public.current_practice()));

CREATE POLICY assessments_read ON public.assessments FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
CREATE POLICY assessments_write ON public.assessments FOR ALL TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs())
         AND public.current_role_name() <> 'read_only')
  WITH CHECK (client_org_id IN (SELECT public.allowed_client_orgs())
              AND public.current_role_name() <> 'read_only');

-- audit: append-only
CREATE POLICY audit_insert ON public.audit_log FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY audit_read ON public.audit_log FOR SELECT TO authenticated
  USING (practice_id = public.current_practice() AND public.current_role_name() = 'practice_owner');
REVOKE UPDATE, DELETE ON public.audit_log FROM authenticated, anon;

-- lock function execution surface
REVOKE EXECUTE ON FUNCTION public.current_practice(), public.current_role_name(),
                            public.allowed_client_orgs() FROM anon;

-- ---------- onboarding RPCs (SECURITY DEFINER; the only cross-RLS write paths) ----------
-- Practice signup: caller (fresh authenticated user) becomes practice_owner.
CREATE FUNCTION public.create_practice(p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF EXISTS (SELECT 1 FROM memberships WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'user already belongs to a practice';
  END IF;
  INSERT INTO practices (name) VALUES (p_name) RETURNING id INTO pid;
  INSERT INTO users (id, email)
    SELECT id, email FROM auth.users WHERE id = auth.uid()
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO memberships (user_id, practice_id, role) VALUES (auth.uid(), pid, 'practice_owner');
  INSERT INTO audit_log (user_id, practice_id, action) VALUES (auth.uid(), pid, 'practice.created');
  RETURN pid;
END $$;

-- Owner attaches an existing auth user to their practice with a role.
CREATE FUNCTION public.add_member(p_user_id uuid, p_role text, p_client_org_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid;
BEGIN
  SELECT practice_id INTO pid FROM memberships
    WHERE user_id = auth.uid() AND role = 'practice_owner';
  IF pid IS NULL THEN RAISE EXCEPTION 'only practice owners may add members'; END IF;
  IF p_client_org_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM client_orgs WHERE id = p_client_org_id AND practice_id = pid) THEN
    RAISE EXCEPTION 'client org not in your practice';
  END IF;
  INSERT INTO users (id, email)
    SELECT id, email FROM auth.users WHERE id = p_user_id
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO memberships (user_id, practice_id, role, client_org_id)
    VALUES (p_user_id, pid, p_role, p_client_org_id);
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'member.added', jsonb_build_object('member', p_user_id, 'role', p_role));
END $$;

REVOKE EXECUTE ON FUNCTION public.create_practice(text),
  public.add_member(uuid, text, uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.create_practice(text),
  public.add_member(uuid, text, uuid) TO authenticated;
