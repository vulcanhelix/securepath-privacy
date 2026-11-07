-- ============================================================================
-- W4-01 — SUPPORT ACCESS: the missing decline leg (GitHub #48 · spec
-- SP-SPC-PLT-001 §4.1/§7.5 FR-PLT-04, NFR-04 · AT-03/04)
-- ============================================================================
--
-- W1-07 (20261106000009) shipped request → approve → revoke and reserved the
-- 'declined' status on support_access_requests — but no write path could set
-- it. A client-side approver who will NOT grant access needs the same
-- recorded, notified decision as an approval: an ignored request just lapses
-- to 'expired', which reads as inaction, not refusal.
--
-- decline_support_request mirrors approve_support_grant's approver guard
-- verbatim (owning partner's partner_admin, an active client-scope
-- accountable_officer assignment, or the client's current IO designation —
-- platform roles deliberately CANNOT decide; client approval is the
-- control). Same ledger treatment: audit_log + a notification_event back to
-- the requester (direct uuid address — the W1-08 resolver accepts uuid
-- tokens) AND the client-side approvers, so the refusal is visible where the
-- request was.
--
-- No new tables. The browser suite (web/e2e/support-access.spec.ts) covers
-- the whole flow over real HTTP; app/tests/e2e_support_access.sql covers the
-- DB logic (guard matrix, atomic grant+assignment, revoke, expiry, ledger).
-- ============================================================================

BEGIN;

CREATE FUNCTION public.decline_support_request(p_request_id uuid,
                                               p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_req record; v_practice uuid; v_can boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  SELECT * INTO v_req FROM public.support_access_requests
   WHERE id = p_request_id FOR UPDATE;
  IF v_req IS NULL THEN
    RAISE EXCEPTION 'decline_support_request: request % not found', p_request_id;
  END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'decline_support_request: request % is % — not pending',
      p_request_id, v_req.status;
  END IF;

  SELECT practice_id INTO v_practice FROM public.client_orgs
   WHERE id = v_req.client_org_id;

  -- approver guard: IDENTICAL to approve_support_grant (decision authority
  -- is symmetric — whoever may grant may refuse)
  v_can := public.has_partner_role(v_practice, ARRAY['partner_admin'])
        OR EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
                   WHERE a.level = 'client' AND a.scope_type = 'client'
                     AND a.scope_id = v_req.client_org_id
                     AND a.role = 'accountable_officer')
        OR EXISTS (SELECT 1 FROM public.designations d
                   WHERE d.client_org_id = v_req.client_org_id
                     AND d.person = auth.uid()
                     AND d.role = 'information_officer'
                     AND d.end_date IS NULL);
  IF NOT v_can THEN
    RAISE EXCEPTION 'decline_support_request: partner_admin of the owning partner '
      'or the client''s accountable officer required';
  END IF;

  UPDATE public.support_access_requests
     SET status = 'declined', decided_by = auth.uid(), decided_at = now()
   WHERE id = p_request_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'support_access.declined',
          jsonb_build_object('request_id', p_request_id,
                             'client_org_id', v_req.client_org_id,
                             'securepath_user_id', v_req.requested_by,
                             'note', p_note));
  -- the requester hears the refusal (direct address); the client-side
  -- approvers see it recorded against their scope too
  INSERT INTO public.notification_events (kind, scope, payload)
  VALUES ('support_access_declined',
          jsonb_build_object('client_org_id', v_req.client_org_id,
                             'practice_id', v_practice,
                             'user_id', v_req.requested_by),
          jsonb_build_object('request_id', p_request_id,
                             'declined_by', auth.uid(), 'note', p_note,
                             'recipients', jsonb_build_array(
                                v_req.requested_by::text,
                                'accountable_officer','partner_admin')));
END $$;
COMMENT ON FUNCTION public.decline_support_request(uuid, text) IS
  'W4-01 FR-PLT-04/NFR-04: client-side refusal of a pending support-access '
  'request — the recorded counterpart of approve_support_grant (same '
  'approver guard). Sets status ''declined'', writes audit_log and notifies '
  'the requester. Platform staff cannot decide requests.';

REVOKE EXECUTE ON FUNCTION public.decline_support_request(uuid, text)
FROM anon, public;
GRANT EXECUTE ON FUNCTION public.decline_support_request(uuid, text)
TO authenticated;

COMMIT;
