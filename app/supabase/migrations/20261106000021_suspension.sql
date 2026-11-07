-- ============================================================================
-- W4-08 — PARTNER SUSPENSION ENFORCEMENT (GitHub #55 · spec SP-SPC-PLT-001
-- §7.1 FR-PLT-06 · plan BUILD_PLAN_R1 W4-08)
-- ============================================================================
--
-- W2-14 (000015) shipped platform_set_partner_status() with the status
-- machine active → suspended | closed → (terminal) and deliberately left
-- enforcement to this migration ("blocking sign-in / access for a suspended
-- or closed partner is W4-08"). This file is that enforcement.
--
-- FR-PLT-06 (Must): "suspending a partner blocks its users' sign-in without
-- deleting client data; the data is then handled under the partner and
-- client agreements."
--
-- WHAT THIS DOES: while a practice is suspended or closed, every user who
-- holds an ACTIVE partner-level role_assignment resolving to that practice
-- loses ALL effective access — reads and writes — through every shared
-- predicate and every legacy layer. Client data is untouched (no rows are
-- deleted or ended); the block is computed live from practices.status, so
-- reactivation restores access exactly as it was.
--
-- DECISIONS (spec ambiguities resolved here — flagged for review):
--
-- 1. "Blocks its users' sign-in" is enforced at the AUTHORIZATION layer,
--    not by touching auth.users — a migration cannot revoke GoTrue sessions,
--    and banning accounts would be destructive (the spec wants the data
--    handled under the agreements, recoverable). The DB denies every read
--    and write of programme/tenant data everywhere (RLS policies + definer
--    RPC guards), which is strictly stronger than a UI bounce: a live JWT
--    for a suspended partner's user returns nothing. The app/middleware
--    should ALSO bounce at sign-in — caller_partner_blocked() is the hook
--    (granted to authenticated for exactly that check); enforcement here
--    does not depend on it.
--
-- 2. USER-CENTRIC block, the literal spec reading: a blocked user is anyone
--    holding an ACTIVE partner-level assignment that resolves to a
--    suspended/closed practice (partner_user_blocked()). They lose
--    EVERYTHING — partner-scope, client-scope and programme-scope access —
--    because "blocks its users' sign-in" blocks the person, not one leg.
--    Consequence (conservative reading, chosen deliberately): a dual-role
--    user (e.g. partner_consultant who is also a client's programme lead or
--    a designation holder, §4) is a partner user and is fully blocked; pure
--    client-level users — client_admin, accountable_officer, executive,
--    programme_lead etc. who hold NO partner-level assignment — are
--    unaffected, because they answer to the client org, not the partner.
--    'closed' blocks identically to 'suspended' (000015 decision 4
--    earmarked both for this work); un-suspend restores because the check
--    reads practices.status live.
--
-- 3. SCOPE RESOLUTION for partner-level rows: the owning practice is
--    resolved through the scope entity — partner scope = scope_id; client
--    scope = that client's practice_id; programme/workstream scope = the
--    entity's owning client's practice_id. Partner-level rows can only be
--    minted for the user's own practice (add_member/accept_invite make
--    partner rows partner-scoped; client-scope partner_consultant rows come
--    only from the legacy consultant_assignments mirror, which is scoped
--    to the consultant's own partner) — but the resolution is written
--    defensively so a hypothetical cross-partner row blocks on ITS owner,
--    not the caller's.
--
-- 4. PLATFORM UNAFFECTED: level='platform' assignments never count toward
--    the block, and branch (e) of allowed_client_orgs (the NFR-04 support
--    path) is untouched — a client-approved support grant on a suspended
--    partner's client still works, and the client's AO can still approve
--    or revoke grants (the client keeps running).
--
-- ENFORCEMENT POINTS (the shared helpers — every policy template and every
-- definer-body guard resolves through these):
--
--   partner_is_blocked(p_practice)   NEW scalar: status suspended|closed.
--   partner_user_blocked(p_user)     NEW scalar: user holds an active
--                                    partner-level row resolving to a
--                                    blocked practice. The single test
--                                    everything below applies.
--   caller_partner_blocked()         NEW: blocked() for auth.uid() — the
--                                    app's sign-in bounce hook.
--   active_assignments(p_user)       a blocked user's rows report as none —
--                                    every T1/T4 policy + definer leg that
--                                    inlines active_assignments(auth.uid())
--                                    now denies them.
--   has_partner_role                 false for a blocked caller — every
--                                    partner-scope policy/RPC/licence/import
--                                    surface.
--   has_client_role / has_programme_role / has_workstream_role /
--   has_activity_role                false for a blocked caller — every
--                                    scoped write gate (and everything
--                                    downstream: has_mti_role,
--                                    can_run_cadence, can_read_client_
--                                    records, template_version_visible,
--                                    approve/revoke_support_grant …).
--   allowed_client_orgs / allowed_programmes   empty for a blocked caller —
--                                    every T1/T2 read + write policy and
--                                    every allowed_*-guarded definer RPC.
--   is_ao_or_alternate / holds_designation     false for a blocked caller —
--                                    the T5 designation legs too.
--   designation_eligible             a blocked p_person can no longer be
--                                    appointed to a designation.
--   memberships (compat view)        a blocked VIEWER sees no rows →
--                                    current_practice()/current_role_name()
--                                    return NULL → every legacy policy and
--                                    RPC guard keyed on them
--                                    (practices/client_orgs/invites/audit/
--                                    notifications/consultant_assignments/
--                                    assessments/create_client_org/
--                                    create_invite …) denies the blocked
--                                    user. Other viewers still see the
--                                    rows — the assignments exist, they
--                                    are simply ineffective.
--   add_member / accept_invite       explicit guards (add_member looks the
--                                    caller's admin row up on
--                                    role_assignments directly, and a
--                                    partner-role invite on a blocked
--                                    practice redeems into instant dead
--                                    access — refused with a clear error).
--                                    CLIENT-role invites on a blocked
--                                    partner still redeem — client users
--                                    are unaffected (decision 2).
--
-- NOTIFICATION + AUDIT: platform_set_partner_status already writes the
-- audit_log partner.status_changed row. This migration adds
-- trg_partner_status_notify AFTER UPDATE OF status — ANY status change
-- emits a partner_status_changed notification_event (partner + platform
-- recipients) so the partner's admins learn of the suspension and
-- reactivation, whatever the write path.
-- ============================================================================

BEGIN;

-- ---------- 1. the block test ----------
CREATE FUNCTION public.partner_is_blocked(p_practice uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT p.status IN ('suspended','closed')
       FROM public.practices p WHERE p.id = p_practice), false)
$$;
COMMENT ON FUNCTION public.partner_is_blocked(uuid) IS
  'W4-08 (#55 FR-PLT-06): is this partner suspended or closed? The two '
  'non-active statuses of the W2-14 status machine both lock partner users '
  'out; closed is terminal. Live read — reactivation restores access.';

-- Caller-visible test: p_user holds an ACTIVE partner-level assignment that
-- resolves to a blocked practice. level='client' and 'platform' rows never
-- count — pure client users and SecurePath staff are unaffected.
CREATE FUNCTION public.partner_user_blocked(p_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.role_assignments ra
    LEFT JOIN public.client_orgs  sco ON ra.scope_type = 'client'
                                     AND sco.id = ra.scope_id
    LEFT JOIN public.programmes   spr ON ra.scope_type = 'programme'
                                     AND spr.id = ra.scope_id
    LEFT JOIN public.client_orgs  spc ON spc.id = spr.client_org_id
    LEFT JOIN public.workstreams  sws ON ra.scope_type = 'workstream'
                                     AND sws.id = ra.scope_id
    LEFT JOIN public.programmes   swp ON swp.id = sws.programme_id
    LEFT JOIN public.client_orgs  swc ON swc.id = swp.client_org_id
    JOIN public.practices p ON p.id = CASE ra.scope_type
                                        WHEN 'partner'    THEN ra.scope_id
                                        WHEN 'client'     THEN sco.practice_id
                                        WHEN 'programme'  THEN spc.practice_id
                                        WHEN 'workstream' THEN swc.practice_id
                                      END
    WHERE ra.user_id = p_user
      AND ra.level = 'partner'
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND p.status IN ('suspended','closed'))
$$;
COMMENT ON FUNCTION public.partner_user_blocked(uuid) IS
  'W4-08 (#55 FR-PLT-06): the suspension test — does this user hold an '
  'active PARTNER-level assignment resolving to a suspended/closed '
  'practice? Partner rows resolve to their owning practice through the '
  'scope entity (partner→scope_id, client/programme/workstream→owning '
  'client''s practice). Blocked users get no effective access anywhere.';

-- The app's sign-in bounce hook (decision 1): granted to authenticated so a
-- login flow can render "partner suspended" instead of an empty tenant.
CREATE FUNCTION public.caller_partner_blocked() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.partner_user_blocked(auth.uid())
$$;
COMMENT ON FUNCTION public.caller_partner_blocked() IS
  'W4-08 (#55 FR-PLT-06): is the JWT caller a user of a suspended/closed '
  'partner? Sign-in/UI hook — the DB-level denial lives in the predicates '
  'and stands regardless.';

-- ---------- 2. predicate catalogue: blocked callers get nothing ----------

-- active_assignments: a blocked user reports NO effective assignments.
-- Every policy template leg and definer guard that inlines
-- active_assignments(auth.uid()) (T1 writes, T4 item scope, workstreams/
-- activities direct-scope legs, template-library reads, support-grant AO
-- legs, users_self) therefore denies a suspended partner's user.
CREATE OR REPLACE FUNCTION public.active_assignments(p_user uuid)
RETURNS SETOF public.role_assignments
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.role_assignments
  WHERE user_id = p_user
    AND start_date <= CURRENT_DATE
    AND (end_date IS NULL OR end_date > CURRENT_DATE)
    AND NOT public.partner_user_blocked(p_user)
$$;
COMMENT ON FUNCTION public.active_assignments(uuid) IS
  'W0-00 predicate: the caller-visible ACTIVE assignment rows for a user. '
  'W4-08: empty while the user holds a partner role on a suspended/closed '
  'practice — the rows still exist, they are ineffective.';

CREATE OR REPLACE FUNCTION public.has_partner_role(p_practice uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT public.partner_user_blocked(auth.uid())
    AND EXISTS (
    SELECT 1 FROM public.role_assignments
    WHERE user_id = auth.uid() AND level = 'partner' AND scope_type = 'partner'
      AND scope_id = p_practice AND role = ANY(p_roles)
      AND start_date <= CURRENT_DATE
      AND (end_date IS NULL OR end_date > CURRENT_DATE))
$$;
COMMENT ON FUNCTION public.has_partner_role(uuid, text[]) IS
  'W0-00 predicate: caller holds an active partner-scope role on this '
  'partner. W4-08: always false for a user of a suspended/closed partner.';

CREATE OR REPLACE FUNCTION public.has_client_role(p_client_org uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT public.partner_user_blocked(auth.uid())
    AND EXISTS (
    SELECT 1
    FROM public.client_orgs co
    JOIN public.role_assignments ra ON ra.user_id = auth.uid()
    WHERE co.id = p_client_org
      AND ra.level IN ('partner','client')
      AND ra.role = ANY(p_roles)
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'client'    AND ra.scope_id = co.id)
         OR (ra.scope_type = 'partner'   AND ra.scope_id = co.practice_id)
         OR (ra.scope_type = 'programme' AND ra.scope_id IN
              (SELECT p.id FROM public.programmes p WHERE p.client_org_id = co.id)) ))
$$;
COMMENT ON FUNCTION public.has_client_role(uuid, text[]) IS
  'W0-02 predicate: T1 write gate — caller holds an active listed role at '
  'client scope, the owning partner scope, or a programme of that client. '
  'W4-08: always false for a user of a suspended/closed partner.';

CREATE OR REPLACE FUNCTION public.has_programme_role(p_programme uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT public.partner_user_blocked(auth.uid())
    AND EXISTS (
    SELECT 1
    FROM public.programmes pr
    JOIN public.client_orgs co ON co.id = pr.client_org_id
    JOIN public.role_assignments ra ON ra.user_id = auth.uid()
    WHERE pr.id = p_programme
      AND ra.level IN ('partner','client')
      AND ra.role = ANY(p_roles)
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'programme' AND ra.scope_id = pr.id)
         OR (ra.scope_type = 'client'    AND ra.scope_id = co.id)
         OR (ra.scope_type = 'partner'   AND ra.scope_id = co.practice_id) ))
$$;
COMMENT ON FUNCTION public.has_programme_role(uuid, text[]) IS
  'W0-02 predicate: caller holds an active listed role at programme scope, '
  'the owning client scope, or the owning partner scope. W4-08: always '
  'false for a user of a suspended/closed partner.';

CREATE OR REPLACE FUNCTION public.has_workstream_role(p_workstream uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT public.partner_user_blocked(auth.uid())
    AND EXISTS (
    SELECT 1
    FROM public.workstreams w
    JOIN public.programmes pr ON pr.id = w.programme_id
    JOIN public.client_orgs co ON co.id = pr.client_org_id
    JOIN public.role_assignments ra ON ra.user_id = auth.uid()
    WHERE w.id = p_workstream
      AND ra.level IN ('partner','client')
      AND ra.role = ANY(p_roles)
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'workstream' AND ra.scope_id = w.id)
         OR (ra.scope_type = 'programme'  AND ra.scope_id = pr.id)
         OR (ra.scope_type = 'client'     AND ra.scope_id = co.id)
         OR (ra.scope_type = 'partner'    AND ra.scope_id = co.practice_id) ))
$$;
COMMENT ON FUNCTION public.has_workstream_role(uuid, text[]) IS
  'W0-02 predicate: T3 write gate — caller holds an active listed role at '
  'workstream scope or any wider scope above it. W4-08: always false for a '
  'user of a suspended/closed partner.';

CREATE OR REPLACE FUNCTION public.has_activity_role(p_activity uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT public.partner_user_blocked(auth.uid())
    AND EXISTS (
    SELECT 1
    FROM public.activities a
    JOIN public.programmes pr ON pr.id = a.programme_id
    JOIN public.client_orgs co ON co.id = pr.client_org_id
    JOIN public.role_assignments ra ON ra.user_id = auth.uid()
    WHERE a.id = p_activity
      AND ra.level IN ('partner','client')
      AND ra.role = ANY(p_roles)
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'workstream' AND ra.scope_id = a.workstream_id)
         OR (ra.scope_type = 'programme'  AND ra.scope_id = pr.id)
         OR (ra.scope_type = 'client'     AND ra.scope_id = co.id)
         OR (ra.scope_type = 'partner'    AND ra.scope_id = co.practice_id) ))
$$;
COMMENT ON FUNCTION public.has_activity_role(uuid, text[]) IS
  'W0-02 predicate: write gate keyed on an activity row (T3 through its '
  'workstream, falling back to programme/client/partner scope). W4-08: '
  'always false for a user of a suspended/closed partner.';

-- allowed_client_orgs v4: the W0-01 v3 five-branch UNION (partner scope,
-- partner-at-client scope, legacy consultant matrix, client-level scopes,
-- NFR-04 support grants) — now empty while the CALLER is a user of a
-- suspended/closed partner. Branches unchanged: pure client users and the
-- client-approved platform support path keep working on the suspended
-- partner's clients.
CREATE OR REPLACE FUNCTION public.allowed_client_orgs() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT aco.id FROM (
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
    --    partner-scope partner_consultant
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
    UNION
    -- e) NFR-04 support path: active platform client-scope assignment + an
    --    approved, in-window, unrevoked grant — unchanged (decision 4)
    SELECT ra.scope_id
    FROM public.role_assignments ra
    WHERE ra.user_id = auth.uid() AND ra.level = 'platform' AND ra.scope_type = 'client'
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND EXISTS (SELECT 1 FROM public.support_access_grants sag
                  WHERE sag.client_org_id = ra.scope_id
                    AND sag.securepath_user_id = ra.user_id
                    AND sag.starts_at <= now() AND sag.expires_at > now()
                    AND sag.revoked_at IS NULL)
  ) aco(id)
  WHERE NOT public.partner_user_blocked(auth.uid())
$$;
COMMENT ON FUNCTION public.allowed_client_orgs() IS
  'W4-08 v4 (replaces W0-01 v3): the same five-branch UNION, now EMPTY for '
  'a caller who holds a partner role on a suspended/closed partner. Client '
  'users, the platform support path and unaffected partners are unchanged.';

CREATE OR REPLACE FUNCTION public.allowed_programmes() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT ap.id FROM (
    SELECT p.id FROM public.programmes p
     WHERE p.client_org_id IN (SELECT public.allowed_client_orgs())
    UNION
    SELECT ra.scope_id
      FROM public.role_assignments ra
     WHERE ra.user_id = auth.uid()
       AND ra.scope_type = 'programme'
       AND ra.level IN ('partner','client')
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
    UNION
    -- W4-D3 (000018): a workstream-scope assignment grants the programme
    -- carrying that workstream (spec B.13 — the workstream lead is the
    -- screen-08 user). Read-only widening; write gates unchanged.
    SELECT w.programme_id
      FROM public.role_assignments ra
      JOIN public.workstreams w ON w.id = ra.scope_id
     WHERE ra.user_id = auth.uid()
       AND ra.scope_type = 'workstream'
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
  ) ap(id)
  WHERE NOT public.partner_user_blocked(auth.uid())
$$;
COMMENT ON FUNCTION public.allowed_programmes() IS
  'W4-08 (replaces W0-02): programmes of visible clients plus direct '
  'programme-scope assignments — EMPTY for a user of a suspended/closed '
  'partner. T2 read.';

-- T5 gates: a suspended partner's user holds no effective AO/alternate or
-- designation rights either (user-centric block, decision 2).
CREATE OR REPLACE FUNCTION public.is_ao_or_alternate(p_client_org uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT public.partner_user_blocked(auth.uid())
    AND ( EXISTS (
      SELECT 1 FROM public.role_assignments ra
      WHERE ra.user_id = auth.uid() AND ra.level = 'client'
        AND ra.role = 'accountable_officer'
        AND ra.start_date <= CURRENT_DATE
        AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
        AND ( (ra.scope_type = 'client' AND ra.scope_id = p_client_org)
           OR (ra.scope_type = 'programme' AND ra.scope_id IN
                (SELECT p.id FROM public.programmes p WHERE p.client_org_id = p_client_org)) ))
    OR public.holds_designation(p_client_org,
         ARRAY['named_alternate','deputy_information_officer','dpo']) )
$$;
COMMENT ON FUNCTION public.is_ao_or_alternate(uuid) IS
  'T5: AO or alternate on this client (live named_alternate / '
  'deputy_information_officer / dpo designation). W4-08: always false for '
  'a user of a suspended/closed partner.';

-- (latest shape from W2-12 — column-probe-free) + the W4-08 block
CREATE OR REPLACE FUNCTION public.holds_designation(p_client_org uuid, p_kinds text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT NOT public.partner_user_blocked(auth.uid())
    AND EXISTS (SELECT 1 FROM public.designations d
                 WHERE d.client_org_id = p_client_org
                   AND d.person = auth.uid()
                   AND d.role = ANY(p_kinds)
                   AND d.date_designated <= CURRENT_DATE
                   AND (d.end_date IS NULL OR d.end_date > CURRENT_DATE))
$$;
COMMENT ON FUNCTION public.holds_designation(uuid, text[]) IS
  'W2-12: caller holds a LIVE designation of one of p_kinds on this client '
  '(date_designated <= today < end_date-or-NULL). W4-08: always false for '
  'a user of a suspended/closed partner.';

-- A blocked person is also not ELIGIBLE for a new designation while their
-- partner is suspended — they could not exercise it anyway.
CREATE OR REPLACE FUNCTION public.designation_eligible(p_client_org uuid, p_role text, p_person uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH holders AS (
    SELECT coalesce(
      (SELECT jp.role_labels -> 'designation_holders' -> p_role
         FROM public.client_orgs c JOIN public.jurisdiction_packs jp ON jp.code = c.jurisdiction
        WHERE c.id = p_client_org
          AND jsonb_typeof(jp.role_labels -> 'designation_holders' -> p_role) = 'array'),
      '["client"]'::jsonb) AS levels)
  SELECT EXISTS (
    SELECT 1 FROM public.role_assignments ra, holders h
     WHERE ra.user_id = p_person
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
       AND h.levels ? ra.level
       AND ( (ra.level = 'client' AND (
                (ra.scope_type = 'client' AND ra.scope_id = p_client_org)
             OR (ra.scope_type = 'programme' AND ra.scope_id IN
                   (SELECT p.id FROM public.programmes p WHERE p.client_org_id = p_client_org))))
          OR (ra.level = 'partner' AND (
                (ra.scope_type = 'client' AND ra.scope_id = p_client_org)
             OR (ra.scope_type = 'partner' AND ra.scope_id = public.client_practice(p_client_org))))))
    AND NOT public.partner_user_blocked(p_person)
$$;
COMMENT ON FUNCTION public.designation_eligible(uuid, text, uuid) IS
  'W2-12 FR-ACC-03: may p_person hold p_role on p_client_org (jurisdiction '
  'pack designation_holders rule)? W4-08: never while p_person is a user '
  'of a suspended/closed partner.';

-- ---------- 3. legacy layer: memberships sees nothing for a blocked viewer ----------
-- current_practice() / current_role_name() read this view, so every legacy
-- policy and RPC guard keyed on them (practices, client_orgs, invites,
-- notifications, audit_log, consultant_assignments, assessments,
-- content_packs, approvals, create_client_org, create_invite, …) denies a
-- suspended partner's user automatically. The rows still exist for other
-- viewers — the viewer, not the row, is blocked.
CREATE OR REPLACE VIEW public.memberships
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
  AND NOT public.partner_user_blocked(auth.uid())
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
  'DEPRECATED compat shim over active role_assignments (W0-00). W4-08: a '
  'blocked VIEWER (user of a suspended/closed partner) sees no rows — '
  'current_practice()/current_role_name() therefore return NULL for them '
  'and every legacy guard denies. New code uses the predicate catalogue.';

-- ---------- 4. explicit write-path guards ----------
-- add_member looks the caller's partner_admin row up on role_assignments
-- directly (not the view/predicate) — assert the block in the body.
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
  IF public.partner_is_blocked(pid) THEN
    RAISE EXCEPTION 'partner is suspended — members cannot be added';
  END IF;
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

-- accept_invite: a PARTNER-role invite on a suspended/closed practice would
-- redeem into instantly dead access — refuse with a clear error. CLIENT-role
-- invites still redeem: the partner's clients keep running (decision 2).
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
  IF v_level = 'partner' AND public.partner_is_blocked(inv.practice_id) THEN
    RAISE EXCEPTION 'this partner is suspended — partner invites cannot be redeemed';
  END IF;
  INSERT INTO users (id, email) VALUES (auth.uid(), lower(my_email))
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id)
    VALUES (auth.uid(), v_level, v_role,
            CASE WHEN v_level = 'client' THEN 'client' ELSE 'partner' END, v_scope_id);
  UPDATE invites SET accepted_at = now() WHERE token = p_token;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), inv.practice_id, 'invite.accepted', jsonb_build_object('role', inv.role));
END $$;

-- ---------- 5. notify on every status change ----------
-- platform_set_partner_status already writes the audit row; this trigger
-- adds the §10 outbox event for ANY status transition (suspend, reactivate,
-- close), whatever the write path. Recipients: the partner's own admins
-- (they need to know why they are locked out — their own inbox rows stay
-- readable under notification_recipients_read) + platform staff.
CREATE FUNCTION public.trg_partner_status_notify() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.notification_events (kind, scope, payload)
  VALUES ('partner_status_changed',
          jsonb_build_object('practice_id', NEW.id),
          jsonb_build_object(
            'from', OLD.status, 'to', NEW.status,
            'transition', CASE WHEN NEW.status = 'suspended' THEN 'suspend'
                               WHEN NEW.status = 'closed'    THEN 'close'
                               ELSE 'reactivate' END,
            'reason',     NEW.status_reason,
            'actor',      auth.uid(),
            'recipients', jsonb_build_array('partner_admin','platform_admin'),
            'subject',    'Partner status changed to ' || NEW.status,
            'title',      'Partner status: ' || NEW.status));
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION public.trg_partner_status_notify() FROM anon, public, authenticated;

DROP TRIGGER IF EXISTS partner_status_notify ON public.practices;
CREATE TRIGGER partner_status_notify
AFTER UPDATE OF status ON public.practices
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION public.trg_partner_status_notify();

-- ---------- 6. grants (W0-00 convention: predicates → authenticated) ----------
REVOKE EXECUTE ON FUNCTION
  public.partner_is_blocked(uuid),
  public.partner_user_blocked(uuid),
  public.caller_partner_blocked()
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.partner_is_blocked(uuid),
  public.partner_user_blocked(uuid),
  public.caller_partner_blocked()
TO authenticated;

COMMENT ON FUNCTION public.platform_set_partner_status(uuid, text, text) IS
  'W2-14 FR-PLT-01/06: suspend / reactivate / close a partner with a '
  'mandatory reason; audited as partner.status_changed and notified via '
  'trg_partner_status_notify. closed is terminal. Licences are not '
  'cascaded (use the W1-07 licence RPCs). Sign-in/access blocking is '
  'enforced by W4-08 (000021): partner_user_blocked() empties every '
  'predicate for the partner''s users while client users keep working.';

COMMIT;
