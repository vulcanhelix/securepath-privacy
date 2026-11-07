-- ============================================================================
-- W2-17 — PARTNER TEAM RPCs (FR-TEAM-01/02: remove users, consultant↔client
-- assignment, invite revocation)
-- (GitHub #41 · spec SP-SPC-PLT-001 §4.1, §7.6 FR-TEAM-01/02 · plan
--  BUILD_PLAN_R1 W2-17)
-- ============================================================================
--
-- The partner team screen (web /team + /licences) reads through RLS
-- (role_assignments, invites, licences, notification_events) and writes
-- through RPCs only. The invite path itself is the W2-14-patched
-- create_invite (role allowlist — partner users can never mint an owner).
-- What was missing is the rest of FR-TEAM-01/02, added here:
--
--   partner_assign_consultant    attach a partner consultant to a client
--                                (client-scope role_assignment — the matrix
--                                consultant_assignments used to carry)
--   partner_unassign_consultant  end that client-scope row
--   partner_remove_member        FR-TEAM-02: end EVERY assignment the user
--                                holds under the partner — partner scope,
--                                client scope and programme/workstream scope
--                                under the partner's clients — at once, logged
--   partner_revoke_invite        delete a pending invite (FR-TEAM-01's
--                                "remove" for users who never accepted)
--
-- Every function is SECURITY DEFINER with the has_partner_role guard IN THE
-- BODY (a definer owned by supabase_admin bypasses RLS). role_assignments
-- has no authenticated write policies BY DESIGN — these are the write path.
--
-- DECISIONS (spec ambiguities resolved here — flagged for review):
--
-- 1. Consultant↔client assignment writes a client-scope role_assignment row
--    (origin 'manual'), NOT a consultant_assignments row. In the W0-00 model
--    the matrix is legacy: allowed_client_orgs branch (b) grants exactly the
--    client from the assignment row, and the mirror trigger (W0-00 §6) is
--    one-way (matrix → assignments). Target eligibility is "holds an ACTIVE
--    partner-level partner_consultant row scoped under this partner" —
--    partner scope OR client scope — because the W0-05 fixture model makes
--    client-scope-only consultant rows the narrowest correct reading (a
--    partner-scope row is NOT required). partner_admin / read_only are not
--    assignable: their partner-scope assignment already sees every client
--    (branch (a)); a client-scope row would be a no-op that clutters the
--    ledger.
--
-- 2. Removal = end-dating (end_date = CURRENT_DATE, EXCLUSIVE per W0-00) —
--    never DELETE: the assignment row is the audit record (NFR-08). Rows
--    that have not started yet get end_date = start_date (the CHECK forbids
--    end < start; a same-day start+end grants nothing). consultant_
--    assignments rows under the partner's clients are deleted outright —
--    they are a mirror of the assignment, not history (W0-00 §6 unmirror
--    rule).
--
-- 3. partner_remove_member refuses two cases: removing yourself (an admin
--    cannot lock their own access out mid-session — a second admin or
--    SecurePath does it) and removing the LAST active partner_admin of the
--    partner (the partner must never be left unmanageable; spec is silent —
--    flagged).
--
-- 4. partner_revoke_invite hard-deletes the invite row: a pending invite is
--    not evidence (nothing was accepted), and the audit_log 'invite.revoked'
--    row is the record. Accepted/expired invites are left alone — revoke is
--    only for pending rows.
--
-- 5. Nothing here touches the 5-seat counter — seats stay create_invite's /
--    accept_invite's business (partner-scope partner_consultant + read_only
--    + pending invites, cap 5). Client-scope assignment rows do NOT consume
--    a seat, matching practice_seats_used().
-- ============================================================================

BEGIN;

-- ---------- 1. helper: caller's partner-admin partner id --------------------
-- Mirrors create_invite's lookup but on role_assignments directly (the W0-00
-- model), not the deprecated memberships shim. NULL = caller holds no active
-- partner-scope partner_admin row.
CREATE FUNCTION public.caller_admin_partner() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT ra.scope_id FROM public.role_assignments ra
   WHERE ra.user_id = auth.uid() AND ra.level = 'partner'
     AND ra.scope_type = 'partner' AND ra.role = 'partner_admin'
     AND ra.start_date <= CURRENT_DATE
     AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
   ORDER BY ra.created_at LIMIT 1
$$;
COMMENT ON FUNCTION public.caller_admin_partner() IS
  'W2-17 internal: the partner id the caller actively administers '
  '(partner-scope partner_admin). NULL otherwise.';
REVOKE EXECUTE ON FUNCTION public.caller_admin_partner() FROM anon, public, authenticated;


-- ---------- 2. FR-TEAM-01: assign a consultant to a client ------------------
CREATE FUNCTION public.partner_assign_consultant(p_user_id uuid, p_client_org_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid;
BEGIN
  pid := public.caller_admin_partner();
  IF pid IS NULL THEN RAISE EXCEPTION 'partner_assign_consultant: partner_admin required'; END IF;
  IF p_client_org_id IS NULL OR NOT EXISTS
     (SELECT 1 FROM public.client_orgs WHERE id = p_client_org_id AND practice_id = pid) THEN
    RAISE EXCEPTION 'partner_assign_consultant: client org not in your practice';
  END IF;
  -- target must be an ACTIVE partner-level consultant of this partner —
  -- partner scope or client scope under it (decision 1)
  IF NOT EXISTS (SELECT 1 FROM public.role_assignments ra
                 WHERE ra.user_id = p_user_id AND ra.level = 'partner'
                   AND ra.role = 'partner_consultant'
                   AND ra.start_date <= CURRENT_DATE
                   AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
                   AND ( (ra.scope_type = 'partner' AND ra.scope_id = pid)
                      OR (ra.scope_type = 'client' AND ra.scope_id IN
                          (SELECT id FROM public.client_orgs WHERE practice_id = pid)) )) THEN
    RAISE EXCEPTION 'partner_assign_consultant: user % is not a consultant of your practice', p_user_id;
  END IF;
  IF EXISTS (SELECT 1 FROM public.role_assignments ra
             WHERE ra.user_id = p_user_id AND ra.level = 'partner'
               AND ra.role = 'partner_consultant' AND ra.scope_type = 'client'
               AND ra.scope_id = p_client_org_id
               AND ra.start_date <= CURRENT_DATE
               AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)) THEN
    RAISE EXCEPTION 'partner_assign_consultant: already assigned to that client';
  END IF;

  INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, origin)
  VALUES (p_user_id, 'partner', 'partner_consultant', 'client', p_client_org_id, 'manual');
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), pid, 'member.client_assigned',
          jsonb_build_object('member', p_user_id, 'client_org', p_client_org_id));
END $$;
COMMENT ON FUNCTION public.partner_assign_consultant(uuid, uuid) IS
  'W2-17 FR-TEAM-01: partner_admin gives a partner consultant a client-scope '
  'assignment (their client access). Audited member.client_assigned.';

-- ---------- 3. FR-TEAM-01: unassign a consultant from a client --------------
CREATE FUNCTION public.partner_unassign_consultant(p_user_id uuid, p_client_org_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; v_n int;
BEGIN
  pid := public.caller_admin_partner();
  IF pid IS NULL THEN RAISE EXCEPTION 'partner_unassign_consultant: partner_admin required'; END IF;
  IF p_client_org_id IS NULL OR NOT EXISTS
     (SELECT 1 FROM public.client_orgs WHERE id = p_client_org_id AND practice_id = pid) THEN
    RAISE EXCEPTION 'partner_unassign_consultant: client org not in your practice';
  END IF;

  -- end the active client-scope row (any partner-level consultant row —
  -- manual or legacy_sync origin both end here)
  UPDATE public.role_assignments ra
     SET end_date = CURRENT_DATE
   WHERE ra.user_id = p_user_id AND ra.level = 'partner'
     AND ra.role = 'partner_consultant' AND ra.scope_type = 'client'
     AND ra.scope_id = p_client_org_id
     AND ra.start_date <= CURRENT_DATE
     AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- the legacy matrix row, if any, goes too (it mirrors the assignment)
  DELETE FROM public.consultant_assignments
   WHERE user_id = p_user_id AND client_org_id = p_client_org_id;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'partner_unassign_consultant: no active assignment on that client';
  END IF;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), pid, 'member.client_unassigned',
          jsonb_build_object('member', p_user_id, 'client_org', p_client_org_id));
END $$;
COMMENT ON FUNCTION public.partner_unassign_consultant(uuid, uuid) IS
  'W2-17 FR-TEAM-01: end a consultant''s client-scope assignment '
  '(end_date = today, exclusive). Also removes the legacy matrix row. '
  'Audited member.client_unassigned.';

-- ---------- 4. FR-TEAM-02: remove a user — all access ends at once ----------
CREATE FUNCTION public.partner_remove_member(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; v_ended int; v_ca int;
BEGIN
  pid := public.caller_admin_partner();
  IF pid IS NULL THEN RAISE EXCEPTION 'partner_remove_member: partner_admin required'; END IF;
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'partner_remove_member: user id required'; END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'partner_remove_member: you cannot remove yourself';
  END IF;

  -- the target must actually belong to this partner (any live row under it)
  IF NOT EXISTS (
    SELECT 1 FROM public.role_assignments ra
    WHERE ra.user_id = p_user_id AND ra.level IN ('partner','client')
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'partner' AND ra.scope_id = pid)
         OR (ra.scope_type = 'client' AND ra.scope_id IN
             (SELECT id FROM public.client_orgs WHERE practice_id = pid))
         OR (ra.scope_type = 'programme' AND ra.scope_id IN
             (SELECT p.id FROM public.programmes p
               JOIN public.client_orgs c ON c.id = p.client_org_id
              WHERE c.practice_id = pid))
         OR (ra.scope_type = 'workstream' AND ra.scope_id IN
             (SELECT w.id FROM public.workstreams w
               JOIN public.programmes p ON p.id = w.programme_id
               JOIN public.client_orgs c ON c.id = p.client_org_id
              WHERE c.practice_id = pid)) )
  ) THEN
    RAISE EXCEPTION 'partner_remove_member: user % is not a member of your practice', p_user_id;
  END IF;

  -- never strand the partner without an admin (decision 3)
  IF EXISTS (SELECT 1 FROM public.role_assignments ra
             WHERE ra.user_id = p_user_id AND ra.level = 'partner'
               AND ra.scope_type = 'partner' AND ra.scope_id = pid
               AND ra.role = 'partner_admin'
               AND ra.start_date <= CURRENT_DATE
               AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE))
     AND NOT EXISTS (SELECT 1 FROM public.role_assignments ra
                     WHERE ra.user_id <> p_user_id AND ra.level = 'partner'
                       AND ra.scope_type = 'partner' AND ra.scope_id = pid
                       AND ra.role = 'partner_admin'
                       AND ra.start_date <= CURRENT_DATE
                       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)) THEN
    RAISE EXCEPTION 'partner_remove_member: cannot remove the last partner admin';
  END IF;

  -- end EVERY live row under the partner: partner scope, client scope and
  -- programme/workstream scope under the partner's clients — all at once.
  -- Unstarted rows end on their start_date (the CHECK forbids end < start).
  UPDATE public.role_assignments ra
     SET end_date = GREATEST(ra.start_date, CURRENT_DATE)
   WHERE ra.user_id = p_user_id
     AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
     AND ( (ra.scope_type = 'partner' AND ra.scope_id = pid)
        OR (ra.scope_type = 'client' AND ra.scope_id IN
            (SELECT id FROM public.client_orgs WHERE practice_id = pid))
        OR (ra.scope_type = 'programme' AND ra.scope_id IN
            (SELECT p.id FROM public.programmes p
              JOIN public.client_orgs c ON c.id = p.client_org_id
             WHERE c.practice_id = pid))
        OR (ra.scope_type = 'workstream' AND ra.scope_id IN
            (SELECT w.id FROM public.workstreams w
              JOIN public.programmes p ON p.id = w.programme_id
              JOIN public.client_orgs c ON c.id = p.client_org_id
             WHERE c.practice_id = pid)) );
  GET DIAGNOSTICS v_ended = ROW_COUNT;

  -- legacy matrix rows under this partner's clients (mirrors, not history)
  DELETE FROM public.consultant_assignments ca
   WHERE ca.user_id = p_user_id
     AND ca.client_org_id IN (SELECT id FROM public.client_orgs WHERE practice_id = pid);
  GET DIAGNOSTICS v_ca = ROW_COUNT;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), pid, 'member.removed',
          jsonb_build_object('member', p_user_id,
                             'assignments_ended', v_ended,
                             'matrix_rows_removed', v_ca));
END $$;
COMMENT ON FUNCTION public.partner_remove_member(uuid) IS
  'W2-17 FR-TEAM-02: partner_admin removes a user — end-dates EVERY live '
  'role_assignment under the partner (partner/client/programme/workstream '
  'scope) in one call and drops legacy matrix rows. Refuses self-removal and '
  'removing the last partner_admin. Audited member.removed.';

-- ---------- 5. FR-TEAM-01: revoke a pending invite ---------------------------
CREATE FUNCTION public.partner_revoke_invite(p_token uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; inv record;
BEGIN
  pid := public.caller_admin_partner();
  IF pid IS NULL THEN RAISE EXCEPTION 'partner_revoke_invite: partner_admin required'; END IF;
  SELECT * INTO inv FROM public.invites
   WHERE token = p_token AND practice_id = pid FOR UPDATE;
  IF inv IS NULL THEN
    RAISE EXCEPTION 'partner_revoke_invite: invite not found in your practice';
  END IF;
  IF inv.accepted_at IS NOT NULL THEN
    RAISE EXCEPTION 'partner_revoke_invite: invite already accepted — remove the member instead';
  END IF;

  DELETE FROM public.invites WHERE token = p_token;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), pid, 'invite.revoked',
          jsonb_build_object('email', inv.email, 'role', inv.role));
END $$;
COMMENT ON FUNCTION public.partner_revoke_invite(uuid) IS
  'W2-17 FR-TEAM-01: partner_admin deletes a pending invite (accepted or '
  'already-gone rows are refused — accepted users go through '
  'partner_remove_member). Audited invite.revoked.';

REVOKE EXECUTE ON FUNCTION
  public.partner_assign_consultant(uuid, uuid),
  public.partner_unassign_consultant(uuid, uuid),
  public.partner_remove_member(uuid),
  public.partner_revoke_invite(uuid)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.partner_assign_consultant(uuid, uuid),
  public.partner_unassign_consultant(uuid, uuid),
  public.partner_remove_member(uuid),
  public.partner_revoke_invite(uuid)
TO authenticated;

COMMIT;
