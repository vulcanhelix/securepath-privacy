-- Billing ledger, in-app notifications, team invites (5-seat cap), client onboarding.
-- Decisions 2026-07-29: manual billing (append-only ledger + ops alerts), open signup,
-- invite-by-email via invites table + accept_invite RPC, in-app whitelabel only.

-- ---------- client org onboarding fields ----------
ALTER TABLE public.client_orgs
  ADD COLUMN registration_no text,
  ADD COLUMN industry        text,
  ADD COLUMN contact_name    text,
  ADD COLUMN contact_email   text;

-- ---------- billing ledger (append-only, ops-read only) ----------
CREATE TABLE public.billing_events (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at            timestamptz NOT NULL DEFAULT now(),
    practice_id   uuid NOT NULL REFERENCES public.practices(id),
    client_org_id uuid REFERENCES public.client_orgs(id),
    event_type    text NOT NULL CHECK (event_type IN ('instance.created','instance.deleted')),
    detail        jsonb
);
ALTER TABLE public.billing_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_events FORCE ROW LEVEL SECURITY;
-- no policies: only service role / RPCs touch it. Owners see charges via notifications.
REVOKE ALL ON public.billing_events FROM authenticated, anon;

-- ---------- in-app notifications ----------
CREATE TABLE public.notifications (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at          timestamptz NOT NULL DEFAULT now(),
    practice_id uuid NOT NULL REFERENCES public.practices(id),
    kind        text NOT NULL,
    message     text NOT NULL,
    read        boolean NOT NULL DEFAULT false
);
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications FORCE ROW LEVEL SECURITY;
CREATE POLICY notifications_read ON public.notifications FOR SELECT TO authenticated
  USING (practice_id = public.current_practice());
CREATE POLICY notifications_mark_read ON public.notifications FOR UPDATE TO authenticated
  USING (practice_id = public.current_practice())
  WITH CHECK (practice_id = public.current_practice());

-- ---------- team invites ----------
CREATE TABLE public.invites (
    token         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    practice_id   uuid NOT NULL REFERENCES public.practices(id),
    email         text NOT NULL,
    role          text NOT NULL CHECK (role IN
                    ('practice_consultant','client_admin','client_contributor','read_only')),
    client_org_id uuid REFERENCES public.client_orgs(id),
    invited_by    uuid NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL DEFAULT now() + interval '7 days',
    accepted_at   timestamptz,
    CHECK ( (role IN ('client_admin','client_contributor')) = (client_org_id IS NOT NULL) )
);
ALTER TABLE public.invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invites FORCE ROW LEVEL SECURITY;
CREATE POLICY invites_owner ON public.invites FOR SELECT TO authenticated
  USING (practice_id = public.current_practice() AND public.current_role_name() = 'practice_owner');

-- practice-side seats = owner excluded; cap 5 (requirement 2026-07-29)
CREATE FUNCTION public.practice_seats_used(pid uuid) RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT count(*)::int FROM memberships
  WHERE practice_id = pid AND role IN ('practice_consultant','read_only')
$$;
REVOKE EXECUTE ON FUNCTION public.practice_seats_used(uuid) FROM anon, public;

-- Owner creates an invite; mail is sent by the app server. Returns token.
CREATE FUNCTION public.create_invite(p_email text, p_role text, p_client_org_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; tok uuid;
BEGIN
  SELECT practice_id INTO pid FROM memberships
    WHERE user_id = auth.uid() AND role = 'practice_owner';
  IF pid IS NULL THEN RAISE EXCEPTION 'only practice owners may invite'; END IF;
  IF p_role IN ('practice_consultant','read_only')
     AND public.practice_seats_used(pid)
         + (SELECT count(*) FROM invites WHERE practice_id = pid AND accepted_at IS NULL
            AND expires_at > now() AND role IN ('practice_consultant','read_only')) >= 5 THEN
    RAISE EXCEPTION 'seat limit reached (5 team members)';
  END IF;
  IF p_client_org_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM client_orgs WHERE id = p_client_org_id AND practice_id = pid) THEN
    RAISE EXCEPTION 'client org not in your practice';
  END IF;
  INSERT INTO invites (practice_id, email, role, client_org_id, invited_by)
    VALUES (pid, lower(p_email), p_role, p_client_org_id, auth.uid())
    RETURNING token INTO tok;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'invite.created', jsonb_build_object('email', lower(p_email), 'role', p_role));
  RETURN tok;
END $$;

-- Invitee (authenticated, email must match) redeems the token.
CREATE FUNCTION public.accept_invite(p_token uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE inv record; my_email text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT email INTO my_email FROM auth.users WHERE id = auth.uid();
  SELECT * INTO inv FROM invites
    WHERE token = p_token AND accepted_at IS NULL AND expires_at > now()
    FOR UPDATE;
  IF inv IS NULL THEN RAISE EXCEPTION 'invite invalid or expired'; END IF;
  IF lower(my_email) <> inv.email THEN RAISE EXCEPTION 'invite was sent to a different email'; END IF;
  IF EXISTS (SELECT 1 FROM memberships WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'user already belongs to a practice';
  END IF;
  IF inv.role IN ('practice_consultant','read_only')
     AND public.practice_seats_used(inv.practice_id) >= 5 THEN
    RAISE EXCEPTION 'seat limit reached (5 team members)';
  END IF;
  INSERT INTO users (id, email) VALUES (auth.uid(), lower(my_email))
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO memberships (user_id, practice_id, role, client_org_id)
    VALUES (auth.uid(), inv.practice_id, inv.role, inv.client_org_id);
  UPDATE invites SET accepted_at = now() WHERE token = p_token;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), inv.practice_id, 'invite.accepted', jsonb_build_object('role', inv.role));
END $$;

-- ---------- client instance creation (the billable event) ----------
CREATE FUNCTION public.create_client_org(
    p_name text, p_registration_no text DEFAULT NULL, p_industry text DEFAULT NULL,
    p_contact_name text DEFAULT NULL, p_contact_email text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; cid uuid;
BEGIN
  SELECT practice_id INTO pid FROM memberships
    WHERE user_id = auth.uid() AND role = 'practice_owner';
  IF pid IS NULL THEN RAISE EXCEPTION 'only practice owners may create client instances'; END IF;
  INSERT INTO client_orgs (practice_id, name, registration_no, industry, contact_name, contact_email)
    VALUES (pid, p_name, p_registration_no, p_industry, p_contact_name, p_contact_email)
    RETURNING id INTO cid;
  INSERT INTO billing_events (practice_id, client_org_id, event_type, detail)
    VALUES (pid, cid, 'instance.created', jsonb_build_object('name', p_name, 'by', auth.uid()));
  INSERT INTO notifications (practice_id, kind, message)
    VALUES (pid, 'billing',
            format('Client instance "%s" created — this instance is billable.', p_name));
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'client_org.created', jsonb_build_object('client_org', cid, 'name', p_name));
  RETURN cid;
END $$;

REVOKE EXECUTE ON FUNCTION
  public.create_invite(text, text, uuid),
  public.accept_invite(uuid),
  public.create_client_org(text, text, text, text, text)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.create_invite(text, text, uuid),
  public.accept_invite(uuid),
  public.create_client_org(text, text, text, text, text)
TO authenticated;
