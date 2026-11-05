-- ============================================================================
-- W0-00 — AUTHZ REMODEL: role_assignments + predicate catalogue
-- (GitHub #9 · spec SP-SPC-PLT-001 §4, §6.1 · plan BUILD_PLAN_R1 §3 W0-00)
-- ============================================================================
--
-- Replaces the single-role `memberships` model with the spec role model:
--
--   role_assignments(user_id, level, role, scope_type, scope_id,
--                    start_date, end_date)
--
--   level      platform | partner | client          (spec §4)
--   scope_type partner  | client  | programme | workstream   (spec §6.1)
--   One person may hold MANY assignments at multiple levels.
--   Access is granted only while the assignment is ACTIVE:
--     start_date <= CURRENT_DATE AND (end_date IS NULL OR end_date > CURRENT_DATE)
--   end_date is EXCLUSIVE (spec ambiguity, decided here): the assignment is
--   active through end_date - 1 and denied ON end_date. FR-ACC-05 "assessor
--   access expires on a set date" reads as "no access on that date"; exclusive
--   also lets an admin revoke a same-day grant (end_date = start_date), which
--   an inclusive end cannot express without violating the
--   end_date >= start_date CHECK.
--
-- ROLE VOCABULARY (enforced by CHECK below — a role is only valid at its level):
--   platform: platform_admin, content_author, support
--   partner : partner_admin, partner_consultant, read_only          (legacy)
--   client  : executive, accountable_officer, programme_lead, workstream_lead,
--             external_provider, assessor,
--             client_admin, client_contributor                       (legacy)
--
-- scope_id is NULL only for GLOBAL platform grants (level='platform'). A
-- platform grant may also be scoped (scope_type partner|client + scope_id) —
-- that is how spec §4.1 "support: with client approval, time limited, logged"
-- is expressed (platform-level row, client scope, end_date set). The support
-- access path itself lands in W0-01; nothing in this migration grants
-- platform users tenant visibility.
--
-- MEMBERSHIPS → VIEW DECISION (mission §4): `memberships` becomes a
-- security_invoker VIEW over active role_assignments, emitting each user's
-- single "primary" legacy-mappable assignment (partner-scope first, ranked
-- partner_admin > partner_consultant > read_only > client_admin >
-- client_contributor). Chosen over dual-write because a second writable copy
-- would drift (direct SQL and later admin RPCs would have to remember to
-- write both). All legacy readers (web `.from('memberships')`,
-- practice_seats_used, create_invite, create_client_org, users_self-style
-- checks) keep working unchanged. Only the three RPCs that WROTE memberships
-- (create_practice, add_member, accept_invite) are recreated to write
-- role_assignments. New-only roles (executive, programme_lead, platform_*,
-- client-scope partner_consultant rows) intentionally emit NO view row —
-- they are invisible to legacy code paths, so they can never widen an old
-- check (a pure new-role user gets current_role_name() = NULL → legacy
-- write gates deny → read-only on legacy tables).
--
-- DEPRECATED COMPAT SHIMS — current_practice() and current_role_name()
-- keep identical signatures and identical results for backfilled users
-- (they now read the view). NEW CODE MUST USE THE PREDICATE CATALOGUE
-- below; the shims exist only so the 42 ported policies + legacy RPC
-- guards keep working unchanged.
--
-- PREDICATE CATALOGUE (call from every SECURITY DEFINER and every new
-- policy — a definer function bypasses RLS, so the check must be in the
-- function body):
--   active_assignments(p_user uuid)  → setof role_assignments  — active rows
--   has_partner_role(p_practice uuid, p_roles text[]) → boolean
--       caller holds an active partner-scope role on that partner
--   is_platform_role(p_roles text[]) → boolean
--       caller holds an active platform-level role (any scope)
--   allowed_client_orgs() → setof uuid  (v2 — UNION of)
--       a) partner-scope partner_admin|read_only → all clients of that partner
--       b) partner-level role at client scope    → that client
--       c) legacy consultant_assignments row, iff caller is an active
--          partner-scope partner_consultant (preserves old semantics: a
--          consultant_assignments row never granted anything to non-
--          consultants)
--       d) client-level role at client scope     → that client
--       Returns IDENTICAL results to the v1 function for backfilled rows.
--   allowed_programmes() → setof uuid  — STUB: the programmes entity does
--       not exist yet (lands W1+). Until then a "programme" is identified
--       with its client, so this returns allowed_client_orgs(). T2 policies
--       should be written against this name so the switch is function-only.
--
-- ----------------------------------------------------------------------------
-- POLICY TEMPLATE CATALOGUE — every new (W1+) tenant table names ONE template
-- in its migration header and instantiates it verbatim.
--
-- T1 CLIENT-SCOPE (default for all client data):
--     read :  <tbl>.client_org_id IN (SELECT public.allowed_client_orgs())
--     write:  + role gate, e.g.
--             AND EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
--                         WHERE a.level IN ('partner','client')
--                           AND a.role IN (<writing roles>)
--                           AND ((a.scope_type='client' AND a.scope_id=<tbl>.client_org_id)
--                                OR (a.scope_type='partner' AND a.scope_id=
--                                    (SELECT practice_id FROM client_orgs c
--                                     WHERE c.id=<tbl>.client_org_id))))
--
-- T2 PROGRAMME-SCOPE (row belongs to a programme under a client):
--     <tbl>.programme_id IN (SELECT public.allowed_programmes())
--     — resolves through the owning client until programmes land; then the
--     predicate joins programme→client and keeps the same call.
--
-- T3 WORKSTREAM-SCOPE (row belongs to a workstream under a programme):
--     EXISTS (SELECT 1 FROM workstreams w
--             JOIN programmes p ON p.id = w.programme_id
--             WHERE w.id = <tbl>.workstream_id
--               AND p.client_org_id IN (SELECT public.allowed_client_orgs()))
--     plus the caller's workstream-scoped assignment narrows to own
--     workstream for workstream_lead (spec §4.2 "Own workstream").
--
-- T4 ITEM-SCOPE (external_provider / assessor style — "Own items"):
--     T1/T3 visibility AND
--     EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
--             WHERE a.scope_type = '<item scope>' AND a.scope_id = <item id>)
--     or, until item scope exists, an item-assignee column checked against
--     auth.uid(). Item scope is expressed with scope_type programme/
--     workstream rows when those entities land.
--
-- T5 DESIGNATION-GATED (privileged client actions — close register item,
--     breach decision; FR-ACC-01/02/03):
--     T1 visibility AND EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
--        WHERE a.level='client' AND a.scope_type='client'
--          AND a.scope_id = <tbl>.client_org_id
--          AND a.role IN ('accountable_officer'))
--     AND EXISTS (SELECT 1 FROM designations d           -- lands with the
--                 WHERE d.client_org_id = <tbl>.client_org_id  -- designations
--                   AND d.person = auth.uid() AND d.role = <designation>) -- table
-- ============================================================================

-- ---------- 1. the table ----------
CREATE TABLE public.role_assignments (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    level      text NOT NULL CHECK (level IN ('platform','partner','client')),
    role       text NOT NULL,
    scope_type text NOT NULL CHECK (scope_type IN ('partner','client','programme','workstream')),
    scope_id   uuid,                      -- polymorphic: practices/client_orgs/(programmes)/(workstreams); NULL = global platform grant
    start_date date NOT NULL DEFAULT CURRENT_DATE,
    end_date   date,                      -- EXCLUSIVE: denied on this date; NULL = open-ended
    origin     text NOT NULL DEFAULT 'manual'
               CHECK (origin IN ('manual','backfill','legacy_sync')),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (  (level = 'platform' AND role IN ('platform_admin','content_author','support'))
          OR (level = 'partner'  AND role IN ('partner_admin','partner_consultant','read_only'))
          OR (level = 'client'   AND role IN ('executive','accountable_officer','programme_lead',
                                              'workstream_lead','external_provider','assessor',
                                              'client_admin','client_contributor')) ),
    CHECK (level = 'platform' OR scope_id IS NOT NULL),
    CHECK (level <> 'platform' OR scope_type IN ('partner','client')),
    CHECK (end_date IS NULL OR end_date >= start_date)
);
COMMENT ON TABLE public.role_assignments IS
  'Spec §6.1 role assignments. Access granted only while active '
  '(start_date <= CURRENT_DATE <= end_date-or-NULL). Append-ended: revoke by '
  'setting end_date, never by rewriting history.';
COMMENT ON COLUMN public.role_assignments.origin IS
  'manual = created by an RPC/admin path; backfill = migrated from '
  'memberships/consultant_assignments; legacy_sync = mirrored from a live '
  'consultant_assignments write by trg_consultant_assignments_mirror.';

CREATE INDEX role_assignments_user_idx  ON public.role_assignments (user_id);
CREATE INDEX role_assignments_scope_idx ON public.role_assignments (scope_type, scope_id);
-- at most one ACTIVE row per (user, level, role, scope)
CREATE UNIQUE INDEX role_assignments_one_active
  ON public.role_assignments (user_id, level, role, scope_type,
                              COALESCE(scope_id, '00000000-0000-0000-0000-000000000000'::uuid))
  WHERE end_date IS NULL;

-- ---------- 2. backfill: memberships + consultant_assignments ----------
-- practice_owner        → partner / partner_admin    / partner scope
-- practice_consultant   → partner / partner_consultant / partner scope
-- read_only             → partner / read_only        / partner scope
-- client_admin          → client / client_admin      / client scope (their org)
-- client_contributor    → client / client_contributor/ client scope (their org)
INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, origin)
SELECT m.user_id,
       CASE WHEN m.role IN ('client_admin','client_contributor') THEN 'client' ELSE 'partner' END,
       CASE m.role WHEN 'practice_owner'       THEN 'partner_admin'
                   WHEN 'practice_consultant'  THEN 'partner_consultant'
                   ELSE m.role END,
       CASE WHEN m.role IN ('client_admin','client_contributor') THEN 'client' ELSE 'partner' END,
       CASE WHEN m.role IN ('client_admin','client_contributor') THEN m.client_org_id ELSE m.practice_id END,
       'backfill'
FROM public.memberships m;

-- consultant_assignments → partner-level partner_consultant rows at client scope.
-- Only where the user is an active practice_consultant member — under the old
-- model a consultant_assignments row did nothing for any other role.
INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, origin)
SELECT ca.user_id, 'partner', 'partner_consultant', 'client', ca.client_org_id, 'backfill'
FROM public.consultant_assignments ca
WHERE EXISTS (SELECT 1 FROM public.memberships m
              WHERE m.user_id = ca.user_id AND m.role = 'practice_consultant');

-- ---------- 3. predicate catalogue ----------
-- Every SECURITY DEFINER that touches tenant data MUST call these in its body
-- (definer bypasses RLS). All are STABLE definer functions so they may run
-- inside RLS policy expressions without recursing.
CREATE FUNCTION public.active_assignments(p_user uuid)
RETURNS SETOF public.role_assignments
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.role_assignments
  WHERE user_id = p_user
    AND start_date <= CURRENT_DATE
    AND (end_date IS NULL OR end_date > CURRENT_DATE)
$$;
COMMENT ON FUNCTION public.active_assignments(uuid) IS
  'W0-00 predicate: the caller-visible active assignment rows for a user. '
  'Intended for definer bodies and policy templates T1/T4/T5.';

CREATE FUNCTION public.has_partner_role(p_practice uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.role_assignments
    WHERE user_id = auth.uid() AND level = 'partner' AND scope_type = 'partner'
      AND scope_id = p_practice AND role = ANY(p_roles)
      AND start_date <= CURRENT_DATE
      AND (end_date IS NULL OR end_date > CURRENT_DATE))
$$;
COMMENT ON FUNCTION public.has_partner_role(uuid, text[]) IS
  'W0-00 predicate: caller holds an active partner-scope role on this partner.';

CREATE FUNCTION public.is_platform_role(p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.role_assignments
    WHERE user_id = auth.uid() AND level = 'platform' AND role = ANY(p_roles)
      AND start_date <= CURRENT_DATE
      AND (end_date IS NULL OR end_date > CURRENT_DATE))
$$;
COMMENT ON FUNCTION public.is_platform_role(text[]) IS
  'W0-00 predicate: caller holds an active platform-level role. Platform '
  'roles grant NO tenant visibility here — scoped support access is W0-01.';

CREATE OR REPLACE FUNCTION public.allowed_client_orgs() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  -- a) partner-scope admin / read-only: every client of that partner
  SELECT co.id
  FROM public.role_assignments ra
  JOIN public.client_orgs co ON co.practice_id = ra.scope_id
  WHERE ra.user_id = auth.uid() AND ra.level = 'partner' AND ra.scope_type = 'partner'
    AND ra.role IN ('partner_admin','read_only')
    AND ra.start_date <= CURRENT_DATE
    AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
  UNION
  -- b) a partner-level role granted at client scope grants exactly that client
  SELECT ra.scope_id
  FROM public.role_assignments ra
  WHERE ra.user_id = auth.uid() AND ra.level = 'partner' AND ra.scope_type = 'client'
    AND ra.start_date <= CURRENT_DATE
    AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
  UNION
  -- c) legacy consultant matrix — only while the caller is an ACTIVE
  --    partner-scope partner_consultant (an expired consultant keeps no
  --    access through stale rows; a non-consultant never had any)
  SELECT ca.client_org_id
  FROM public.consultant_assignments ca
  WHERE ca.user_id = auth.uid()
    AND EXISTS (SELECT 1 FROM public.role_assignments ra
                WHERE ra.user_id = ca.user_id AND ra.level = 'partner'
                  AND ra.scope_type = 'partner' AND ra.role = 'partner_consultant'
                  AND ra.start_date <= CURRENT_DATE
                  AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE))
  UNION
  -- d) client-level roles grant their scope client
  SELECT ra.scope_id
  FROM public.role_assignments ra
  WHERE ra.user_id = auth.uid() AND ra.level = 'client' AND ra.scope_type = 'client'
    AND ra.start_date <= CURRENT_DATE
    AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
$$;
COMMENT ON FUNCTION public.allowed_client_orgs() IS
  'W0-00 v2: UNION of partner-scope, client-scope, legacy consultant matrix '
  'and client-level scopes. Identical results to the memberships-based v1 '
  'for backfilled users; platform roles intentionally excluded.';

-- Programmes do not exist yet; a programme is currently identified with its
-- client. New T2 policies call this so the switch to real programme ids is a
-- one-function change.
CREATE FUNCTION public.allowed_programmes() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.allowed_client_orgs()
$$;
COMMENT ON FUNCTION public.allowed_programmes() IS
  'W0-00 stub (spec §6.1 programme scope): returns client ids until the '
  'programmes entity lands in W1; then returns programme ids.';

REVOKE EXECUTE ON FUNCTION
  public.active_assignments(uuid),
  public.has_partner_role(uuid, text[]),
  public.is_platform_role(text[]),
  public.allowed_programmes()
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.active_assignments(uuid),
  public.has_partner_role(uuid, text[]),
  public.is_platform_role(text[]),
  public.allowed_programmes()
TO authenticated;

-- ---------- 4. memberships → view over active assignments ----------
-- users_self is the only surviving policy that referenced the TABLE directly;
-- rewrite it against role_assignments first so `memberships` can be dropped.
ALTER POLICY users_self ON public.users
USING (
  id = auth.uid()
  OR ( public.has_partner_role(public.current_practice(), ARRAY['partner_admin'])
       AND EXISTS (SELECT 1 FROM public.role_assignments ra
                   WHERE ra.user_id = users.id
                     AND ( (ra.scope_type = 'partner'
                            AND ra.scope_id = public.current_practice())
                        OR (ra.scope_type = 'client'
                            AND ra.scope_id IN (SELECT public.allowed_client_orgs())) )))
);

DROP POLICY memberships_read ON public.memberships;
DROP TABLE public.memberships;

-- One row per user = their primary legacy-mappable ACTIVE assignment
-- (partner-scope first, then client-scope legacy roles, ranked). security_invoker
-- so the invoker's RLS on role_assignments / client_orgs applies — replaces
-- the old memberships_read policy: own row always; partner_admin sees every
-- assignment scoped to their partner and its clients.
CREATE VIEW public.memberships
WITH (security_invoker = true) AS
SELECT DISTINCT ON (ra.user_id)
  ra.user_id,
  CASE WHEN ra.scope_type = 'partner' THEN ra.scope_id ELSE co.practice_id END
    AS practice_id,
  CASE ra.role WHEN 'partner_admin'      THEN 'practice_owner'
               WHEN 'partner_consultant' THEN 'practice_consultant'
               ELSE ra.role END
    AS role,
  CASE WHEN ra.scope_type = 'client' THEN ra.scope_id END
    AS client_org_id
FROM public.role_assignments ra
LEFT JOIN public.client_orgs co
       ON ra.scope_type = 'client' AND co.id = ra.scope_id
WHERE ra.start_date <= CURRENT_DATE
  AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
  AND ( (ra.level = 'partner' AND ra.scope_type = 'partner'
         AND ra.role IN ('partner_admin','partner_consultant','read_only'))
     OR (ra.level = 'client' AND ra.scope_type = 'client'
         AND ra.role IN ('client_admin','client_contributor')) )
ORDER BY ra.user_id,
  CASE WHEN ra.scope_type = 'partner' THEN 0 ELSE 1 END,
  CASE ra.role WHEN 'partner_admin'      THEN 0
               WHEN 'partner_consultant' THEN 1
               WHEN 'read_only'          THEN 2
               WHEN 'client_admin'       THEN 3
               WHEN 'client_contributor' THEN 4
               ELSE 5 END,
  ra.created_at, ra.id;
COMMENT ON VIEW public.memberships IS
  'DEPRECATED compat shim over active role_assignments (W0-00). Read-only. '
  'Emits each user''s primary legacy-role assignment; new-model-only roles '
  'produce no row. New code must use the predicate catalogue.';

GRANT SELECT ON public.memberships TO authenticated;
REVOKE ALL ON public.memberships FROM anon;

-- DEPRECATED shims — bodies unchanged (they now read the view); results are
-- identical for backfilled users. Marked so new code avoids them.
COMMENT ON FUNCTION public.current_practice() IS
  'DEPRECATED (W0-00): first partner-scope assignment (or scope client''s '
  'partner). Kept for legacy policies/RPCs — new code uses has_partner_role / '
  'active_assignments.';
COMMENT ON FUNCTION public.current_role_name() IS
  'DEPRECATED (W0-00): primary legacy-mapped role or NULL for new-role-only '
  'users. Kept for legacy policies/RPCs — new code uses active_assignments '
  'and the T1–T5 policy templates.';

-- ---------- 5. RLS on role_assignments ----------
ALTER TABLE public.role_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_assignments FORCE ROW LEVEL SECURITY;

-- Read: own rows; partner_admin sees everything scoped to their partner and
-- to their partner's clients (replaces memberships_read, strictly ≥).
CREATE POLICY role_assignments_read ON public.role_assignments FOR SELECT TO authenticated
USING (
  user_id = auth.uid()
  OR (scope_type = 'partner'
      AND public.has_partner_role(scope_id, ARRAY['partner_admin']))
  OR (scope_type = 'client'
      AND EXISTS (SELECT 1 FROM public.client_orgs co
                  WHERE co.id = role_assignments.scope_id
                    AND public.has_partner_role(co.practice_id, ARRAY['partner_admin'])))
);
-- No INSERT/UPDATE/DELETE policies: writes happen ONLY inside SECURITY
-- DEFINER RPCs that call the predicate catalogue (add_member, accept_invite,
-- create_practice, the consultant_assignments mirror trigger, and future
-- partner-admin RPCs).

GRANT SELECT ON public.role_assignments TO authenticated;
REVOKE ALL ON public.role_assignments FROM anon;

-- ---------- 6. keep consultant_assignments mirrored ----------
-- The legacy matrix stays writable via its existing RLS for compatibility;
-- every write is mirrored so role_assignments remains the single source of
-- truth. Definer trigger: the access decision was already made by the
-- consultant_assignments RLS policy on the firing statement; the has_-
-- partner_role gate below re-asserts it inside the body per the hard rule.
CREATE FUNCTION public.sync_consultant_assignment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_practice uuid;
BEGIN
  SELECT practice_id INTO v_practice FROM public.client_orgs
    WHERE id = COALESCE(NEW.client_org_id, OLD.client_org_id);
  -- enforce only in a JWT context: auth.uid() NULL means a direct/service
  -- write (migrations, backfills, service_role), where RLS is not the gate.
  IF auth.uid() IS NOT NULL AND v_practice IS NOT NULL
     AND NOT public.has_partner_role(v_practice, ARRAY['partner_admin']) THEN
    RAISE EXCEPTION 'only partner admins may change consultant assignments';
  END IF;
  IF TG_OP IN ('DELETE','UPDATE') THEN
    -- unmirroring removes the synced row outright (it is a mirror, not
    -- history): the firing DELETE/UPDATE is the event of record.
    DELETE FROM public.role_assignments
    WHERE user_id = OLD.user_id AND level = 'partner' AND scope_type = 'client'
      AND role = 'partner_consultant' AND scope_id = OLD.client_org_id
      AND origin = 'legacy_sync';
  END IF;
  IF TG_OP IN ('INSERT','UPDATE')
     AND EXISTS (SELECT 1 FROM public.role_assignments ra
                 WHERE ra.user_id = NEW.user_id AND ra.level = 'partner'
                   AND ra.scope_type = 'partner' AND ra.role = 'partner_consultant'
                   AND ra.start_date <= CURRENT_DATE
                   AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE))
     AND NOT EXISTS (SELECT 1 FROM public.role_assignments ra
                     WHERE ra.user_id = NEW.user_id AND ra.level = 'partner'
                       AND ra.scope_type = 'client' AND ra.role = 'partner_consultant'
                       AND ra.scope_id = NEW.client_org_id
                       AND ra.start_date <= CURRENT_DATE
                       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)) THEN
    INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, origin)
    VALUES (NEW.user_id, 'partner', 'partner_consultant', 'client', NEW.client_org_id, 'legacy_sync');
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
REVOKE EXECUTE ON FUNCTION public.sync_consultant_assignment() FROM anon, public, authenticated;

CREATE TRIGGER consultant_assignments_mirror
AFTER INSERT OR UPDATE OR DELETE ON public.consultant_assignments
FOR EACH ROW EXECUTE FUNCTION public.sync_consultant_assignment();

-- ---------- 7. writers: memberships writes move to role_assignments ----------
-- Signatures and error semantics unchanged.

-- Practice signup: caller becomes partner_admin at partner scope.
CREATE OR REPLACE FUNCTION public.create_practice(p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF EXISTS (SELECT 1 FROM public.role_assignments
             WHERE user_id = auth.uid() AND level IN ('partner','client')
               AND start_date <= CURRENT_DATE
               AND (end_date IS NULL OR end_date > CURRENT_DATE)) THEN
    RAISE EXCEPTION 'user already belongs to a practice';
  END IF;
  INSERT INTO practices (name) VALUES (p_name) RETURNING id INTO pid;
  INSERT INTO users (id, email)
    SELECT id, email FROM auth.users WHERE id = auth.uid()
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id)
    VALUES (auth.uid(), 'partner', 'partner_admin', 'partner', pid);
  INSERT INTO audit_log (user_id, practice_id, action) VALUES (auth.uid(), pid, 'practice.created');
  RETURN pid;
END $$;

-- partner_admin attaches an existing auth user with a legacy-role name.
CREATE OR REPLACE FUNCTION public.add_member(p_user_id uuid, p_role text, p_client_org_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; v_level text; v_role text; v_scope_type text; v_scope_id uuid;
BEGIN
  SELECT ra.scope_id INTO pid FROM public.role_assignments ra
    WHERE ra.user_id = auth.uid() AND ra.level = 'partner' AND ra.scope_type = 'partner'
      AND ra.role = 'partner_admin'
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
    LIMIT 1;
  IF pid IS NULL THEN RAISE EXCEPTION 'only practice owners may add members'; END IF;
  IF p_role NOT IN ('practice_owner','practice_consultant','client_admin','client_contributor','read_only') THEN
    RAISE EXCEPTION 'invalid role: %', p_role;
  END IF;
  v_level      := CASE WHEN p_role IN ('client_admin','client_contributor') THEN 'client' ELSE 'partner' END;
  v_role       := CASE p_role WHEN 'practice_owner'      THEN 'partner_admin'
                              WHEN 'practice_consultant' THEN 'partner_consultant'
                              ELSE p_role END;
  v_scope_type := CASE WHEN v_level = 'client' THEN 'client' ELSE 'partner' END;
  v_scope_id   := CASE WHEN v_level = 'client' THEN p_client_org_id ELSE pid END;
  IF v_level = 'client' AND p_client_org_id IS NULL THEN
    RAISE EXCEPTION 'client org required for client roles';
  END IF;
  IF p_client_org_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM client_orgs WHERE id = p_client_org_id AND practice_id = pid) THEN
    RAISE EXCEPTION 'client org not in your practice';
  END IF;
  IF EXISTS (SELECT 1 FROM public.role_assignments
             WHERE user_id = p_user_id AND level IN ('partner','client')
               AND start_date <= CURRENT_DATE
               AND (end_date IS NULL OR end_date > CURRENT_DATE)) THEN
    RAISE EXCEPTION 'user already belongs to a practice';
  END IF;
  INSERT INTO users (id, email)
    SELECT id, email FROM auth.users WHERE id = p_user_id
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id)
    VALUES (p_user_id, v_level, v_role, v_scope_type, v_scope_id);
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'member.added', jsonb_build_object('member', p_user_id, 'role', p_role));
END $$;

-- Invitee redeems the token: assignment written to role_assignments.
CREATE OR REPLACE FUNCTION public.accept_invite(p_token uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE inv record; my_email text; v_level text; v_role text; v_scope_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT email INTO my_email FROM auth.users WHERE id = auth.uid();
  SELECT * INTO inv FROM invites
    WHERE token = p_token AND accepted_at IS NULL AND expires_at > now()
    FOR UPDATE;
  IF inv IS NULL THEN RAISE EXCEPTION 'invite invalid or expired'; END IF;
  IF lower(my_email) <> inv.email THEN RAISE EXCEPTION 'invite was sent to a different email'; END IF;
  IF EXISTS (SELECT 1 FROM public.role_assignments
             WHERE user_id = auth.uid() AND level IN ('partner','client')
               AND start_date <= CURRENT_DATE
               AND (end_date IS NULL OR end_date > CURRENT_DATE)) THEN
    RAISE EXCEPTION 'user already belongs to a practice';
  END IF;
  IF inv.role IN ('practice_consultant','read_only')
     AND public.practice_seats_used(inv.practice_id) >= 5 THEN
    RAISE EXCEPTION 'seat limit reached (5 team members)';
  END IF;
  v_level    := CASE WHEN inv.role IN ('client_admin','client_contributor') THEN 'client' ELSE 'partner' END;
  v_role     := CASE inv.role WHEN 'practice_owner'      THEN 'partner_admin'
                              WHEN 'practice_consultant' THEN 'partner_consultant'
                              ELSE inv.role END;
  v_scope_id := CASE WHEN v_level = 'client' THEN inv.client_org_id ELSE inv.practice_id END;
  INSERT INTO users (id, email) VALUES (auth.uid(), lower(my_email))
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id)
    VALUES (auth.uid(), v_level, v_role,
            CASE WHEN v_level = 'client' THEN 'client' ELSE 'partner' END, v_scope_id);
  UPDATE invites SET accepted_at = now() WHERE token = p_token;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), inv.practice_id, 'invite.accepted', jsonb_build_object('role', inv.role));
END $$;

REVOKE EXECUTE ON FUNCTION public.create_practice(text),
  public.add_member(uuid, text, uuid), public.accept_invite(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.create_practice(text),
  public.add_member(uuid, text, uuid), public.accept_invite(uuid) TO authenticated;
