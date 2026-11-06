-- ============================================================================
-- W1-07 — LICENCES + SUPPORT-ACCESS GRANT RPCs
-- (GitHub #21 · spec SP-SPC-PLT-001 §4.1, §7.5 FR-LIC-01/02, FR-PLT-02/04,
--  FR-ONB-02, NFR-04 · plan BUILD_PLAN_R1 W1-07)
-- ============================================================================
--
-- Consumes the W0-01 platform tier (licences, support_access_grants, the
-- allowed_client_orgs() branch-(e) support leg) and W1-01's §9.8 counter
-- (partner_licence_usage). Everything below is a SECURITY DEFINER — the
-- tables keep NO authenticated write grants, so these functions are the only
-- write paths and every one carries its predicate guard IN THE BODY (a
-- definer owned by supabase_admin bypasses RLS).
--
-- PIECES:
--   licences        — issue / change / suspend / close (platform_admin only;
--                     the licences_one_active partial index enforces the
--                     "one active licence per partner" rule — violations are
--                     caught and re-raised readably). Every mutation writes
--                     audit_log.
--   capacity        — assert_licence_capacity(partner, kind): the FR-ONB-02
--                     onboarding block. "At OR over" — the §9.8 counters only
--                     flag STRICTLY-over, so the >= check is done here.
--                     licence_warning_threshold_check: passive sweep that
--                     emits a licence_warning notification_event at 80% of a
--                     cap (or 30 days before term end) to the partner admin
--                     (+ SecurePath), deduped per trigger per 30 days.
--   support grants  — request → approve → revoke over a NEW additive table
--                     support_access_requests (W0-01 reserved grants for
--                     approved-only rows; the pending-request record was the
--                     declared schema addition). approve creates BOTH the
--                     support_access_grants row AND the platform-level
--                     client-scope role_assignments row in the same function
--                     call — branch (e) requires both legs; a failure anywhere
--                     rolls back the whole transaction, so a grant can never
--                     exist without its assignment (or vice versa).
--   usage_report    — the FR-LIC-02 / FR-PLT-05 platform usage view: clients,
--                     programmes (with by-framework split), active users vs
--                     licence caps per partner. Powers the W2-17 page.
--
-- DECISIONS (spec ambiguities resolved here — flagged for review):
--
-- 1. request_support_access scope. The packet wrote "partner_id|client_org_id".
--    The access mechanism (grants + branch (e)) is CLIENT-scoped — a
--    partner-scope request cannot be expressed as a single grant without
--    minting N rows under clients the requester may not need. Requests are
--    therefore per client_org (FR-PLT-04's "a client's programme" reads
--    client-scope in R1: grants open the whole client, consistent with
--    W0-01's branch-(e) granularity).
--
-- 2. Requests carry requested_by + a requested expiry; approval stamps
--    approved_by=auth.uid() and the grant window [now(), requested expiry].
--    Approvers (FR-PLT-04): the owning partner's partner_admin, OR a caller
--    with an ACTIVE client-scope accountable_officer assignment, OR the
--    client's current information_officer designation holder. Platform
--    roles deliberately CANNOT approve — client approval is the control.
--
-- 3. The grant's role_assignment is bounded: start_date = grant start,
--    end_date = grant expiry date + 1 (end_date is EXCLUSIVE in W0-00 — the
--    assignment stays live through the last grant day; the grant's
--    timestamptz window remains the precise gate). Rows are always inserted
--    end-dated, so they never collide with the one-active unique index nor
--    with pre-existing dormant assignments (the W0-05 model: a dormant
--    assignment alone grants nothing — the grant is required too).
--
-- 4. revoke_support_grant sets revoked_at only — it does NOT touch the
--    role_assignment. Branch (e) requires a live grant, so a revoked/expired
--    grant leaves the assignment dormant (the fixture model); ending the
--    assignment here could silently kill a DIFFERENT concurrent grant's
--    access for the same user+client. Grant rows are never deleted (NFR-08:
--    the row is the audit record). Revocable by platform_admin, the owning
--    partner's partner_admin, the client AO, or the grant's own holder.
--
-- 5. list_support_grants' "expiry sweep": expires stale pending REQUESTS
--    (status → 'expired' when their window has passed) — the only lazy
--    state the model needs; grant expiry is derived live by the branch-(e)
--    predicate and needs no stored flag. Returns each grant with a computed
--    state: revoked | expired | active.
--
-- 6. assert_licence_capacity raises when the partner has NO active in-term
--    licence — the licence is the precondition for client/programme
--    creation (suspended/terminated partners cannot grow usage). It is an
--    exposed RPC (called by W1-05 creation paths and web), NOT a trigger —
--    nothing fires it implicitly.
--
-- 7. Warning threshold is 80% per the session packet (spec §10's notification
--    table says 90%; the packet governs this deliverable — flagged).
-- ============================================================================

BEGIN;

-- ---------- 1. support_access_requests (W4-01-style pending-request record) --
CREATE TABLE public.support_access_requests (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id  uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    requested_by   uuid NOT NULL REFERENCES public.users(id),
    reason         text NOT NULL,
    starts_at      timestamptz NOT NULL DEFAULT now(),  -- earliest the grant may start
    expires_at     timestamptz NOT NULL,                 -- requested window end (the "set period")
    status         text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','approved','declined','expired')),
    decided_by     uuid REFERENCES public.users(id),
    decided_at     timestamptz,
    grant_id       uuid REFERENCES public.support_access_grants(id),
    created_at     timestamptz NOT NULL DEFAULT now(),
    CHECK (expires_at > starts_at)
);
COMMENT ON TABLE public.support_access_requests IS
  'W1-07 FR-PLT-04/NFR-04: SecurePath support-access REQUESTS. support_access_'
  '_grants stays approved-only (W0-01 decision 6); a pending request ripens '
  'into a grant + platform client-scope assignment inside approve_support_'
  '_grant (one transaction — the branch-(e) coupled check). Client-visible '
  '(FR-PLT-04 audit visibility); writes via definer RPCs only.';
CREATE INDEX support_access_requests_client_idx ON public.support_access_requests (client_org_id);
CREATE INDEX support_access_requests_status_idx ON public.support_access_requests (status)
  WHERE status = 'pending';

ALTER TABLE public.support_access_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_access_requests FORCE ROW LEVEL SECURITY;
-- Read: platform staff, the requester, and everyone who can see the client
-- (client side reviews requests before approving — FR-PLT-04 visibility).
CREATE POLICY support_access_requests_read ON public.support_access_requests FOR SELECT TO authenticated
USING (
  public.is_platform_role(ARRAY['platform_admin','support'])
  OR requested_by = auth.uid()
  OR client_org_id IN (SELECT public.allowed_client_orgs())
);
REVOKE ALL ON public.support_access_requests FROM anon;
GRANT SELECT ON public.support_access_requests TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.support_access_requests FROM authenticated;


-- ---------- 2. licence writers (platform_admin only) -------------------------

-- Issue a licence. p_limits keys (all optional except plan):
--   plan (text, required), client_limit, programme_limit (int|null=uncapped),
--   starts_on (date, default today), ends_on (date|null),
--   status ('draft'|'active', default 'active'),
--   attribution_display (bool, default true — FR-BRN-05).
CREATE FUNCTION public.issue_licence(p_partner uuid, p_limits jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_status text; v_key text;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION 'issue_licence: platform_admin required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.practices WHERE id = p_partner) THEN
    RAISE EXCEPTION 'issue_licence: unknown partner %', p_partner;
  END IF;
  IF p_limits IS NULL OR jsonb_typeof(p_limits) <> 'object' THEN
    RAISE EXCEPTION 'issue_licence: limits jsonb object required';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_limits) LOOP
    IF v_key NOT IN ('plan','client_limit','programme_limit','starts_on','ends_on',
                     'status','attribution_display') THEN
      RAISE EXCEPTION 'issue_licence: unknown limits key %', v_key;
    END IF;
  END LOOP;
  IF p_limits->>'plan' IS NULL THEN
    RAISE EXCEPTION 'issue_licence: plan is required';
  END IF;
  v_status := COALESCE(p_limits->>'status', 'active');
  IF v_status NOT IN ('draft','active') THEN
    RAISE EXCEPTION 'issue_licence: status must be draft or active on issue';
  END IF;
  IF v_status = 'active'
     AND EXISTS (SELECT 1 FROM public.licences
                 WHERE partner_id = p_partner AND status = 'active') THEN
    RAISE EXCEPTION 'issue_licence: partner % already has an active licence '
      '(suspend/close it first, or issue as draft)', p_partner;
  END IF;

  INSERT INTO public.licences
      (partner_id, plan, client_limit, programme_limit,
       starts_on, ends_on, status, attribution_display)
  VALUES (p_partner, p_limits->>'plan',
          NULLIF(p_limits->>'client_limit','')::int,
          NULLIF(p_limits->>'programme_limit','')::int,
          COALESCE(NULLIF(p_limits->>'starts_on','')::date, CURRENT_DATE),
          NULLIF(p_limits->>'ends_on','')::date,
          v_status,
          COALESCE((p_limits->>'attribution_display')::boolean, true))
  RETURNING id INTO v_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), p_partner, 'licence.issued',
          jsonb_build_object('licence_id', v_id, 'limits', p_limits));
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'issue_licence: partner % already has an active licence', p_partner;
END $$;
COMMENT ON FUNCTION public.issue_licence(uuid, jsonb) IS
  'W1-07 FR-PLT-02: issue a partner licence (platform_admin only). NULL '
  'limits = uncapped. One active licence per partner is enforced up-front '
  'and by licences_one_active. Writes audit_log.';

-- Patch an existing licence. p_patch keys = same licence fields; a key that
-- is PRESENT is written (jsonb null ⇒ column NULL — this is how a limit is
-- uncapped); absent keys stay. Status transitions follow the W0-01 machine:
--   draft → active|terminated · active → suspended|terminated
--   suspended → active|terminated · terminated → (terminal)
CREATE FUNCTION public.change_licence(p_licence uuid, p_patch jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old public.licences%ROWTYPE; v_new text; v_key text;
        v_ok boolean;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION 'change_licence: platform_admin required';
  END IF;
  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' OR p_patch = '{}'::jsonb THEN
    RAISE EXCEPTION 'change_licence: non-empty patch jsonb required';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_patch) LOOP
    IF v_key NOT IN ('plan','client_limit','programme_limit','starts_on','ends_on',
                     'status','attribution_display') THEN
      RAISE EXCEPTION 'change_licence: unknown patch key %', v_key;
    END IF;
  END LOOP;

  SELECT * INTO v_old FROM public.licences WHERE id = p_licence FOR UPDATE;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'change_licence: licence % not found', p_licence;
  END IF;
  IF v_old.status = 'terminated' THEN
    RAISE EXCEPTION 'change_licence: licence % is terminated — no further changes',
      p_licence;
  END IF;

  IF p_patch ? 'status' THEN
    v_new := p_patch->>'status';
    v_ok  := (v_old.status, v_new) IN
             (('draft','active'), ('draft','terminated'),
              ('active','suspended'), ('active','terminated'),
              ('suspended','active'), ('suspended','terminated'))
             OR v_new = v_old.status;
    IF NOT v_ok THEN
      RAISE EXCEPTION 'change_licence: illegal status transition % → %',
        v_old.status, v_new;
    END IF;
  END IF;

  UPDATE public.licences SET
    plan                = CASE WHEN p_patch ? 'plan'                THEN p_patch->>'plan'                ELSE plan END,
    client_limit        = CASE WHEN p_patch ? 'client_limit'        THEN NULLIF(p_patch->>'client_limit','')::int        ELSE client_limit END,
    programme_limit     = CASE WHEN p_patch ? 'programme_limit'     THEN NULLIF(p_patch->>'programme_limit','')::int     ELSE programme_limit END,
    starts_on           = CASE WHEN p_patch ? 'starts_on'           THEN NULLIF(p_patch->>'starts_on','')::date          ELSE starts_on END,
    ends_on             = CASE WHEN p_patch ? 'ends_on'             THEN NULLIF(p_patch->>'ends_on','')::date            ELSE ends_on END,
    status              = CASE WHEN p_patch ? 'status'              THEN p_patch->>'status'              ELSE status END,
    attribution_display = CASE WHEN p_patch ? 'attribution_display' THEN (p_patch->>'attribution_display')::boolean      ELSE attribution_display END,
    updated_at          = now()
  WHERE id = p_licence;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_old.partner_id, 'licence.changed',
          jsonb_build_object('licence_id', p_licence, 'patch', p_patch,
                             'previous', to_jsonb(v_old)));
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'change_licence: partner already has an active licence';
END $$;
COMMENT ON FUNCTION public.change_licence(uuid, jsonb) IS
  'W1-07 FR-PLT-02: patch licence fields (platform_admin only). Present keys '
  'are written verbatim — jsonb null unsets a cap. Status transitions '
  'validated against the draft→active→suspended↔active→terminated machine.';

CREATE FUNCTION public.suspend_licence(p_licence uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_lic public.licences%ROWTYPE;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION 'suspend_licence: platform_admin required';
  END IF;
  SELECT * INTO v_lic FROM public.licences WHERE id = p_licence FOR UPDATE;
  IF v_lic IS NULL THEN
    RAISE EXCEPTION 'suspend_licence: licence % not found', p_licence;
  END IF;
  IF v_lic.status <> 'active' THEN
    RAISE EXCEPTION 'suspend_licence: only an active licence can be suspended (now %)',
      v_lic.status;
  END IF;
  UPDATE public.licences SET status = 'suspended', updated_at = now()
    WHERE id = p_licence;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_lic.partner_id, 'licence.suspended',
          jsonb_build_object('licence_id', p_licence));
END $$;
COMMENT ON FUNCTION public.suspend_licence(uuid) IS
  'W1-07 FR-PLT-02: active → suspended (platform_admin only). While '
  'suspended the licence is not "active" — assert_licence_capacity blocks '
  'new usage; existing visibility is unaffected.';

CREATE FUNCTION public.close_licence(p_licence uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_lic public.licences%ROWTYPE;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION 'close_licence: platform_admin required';
  END IF;
  SELECT * INTO v_lic FROM public.licences WHERE id = p_licence FOR UPDATE;
  IF v_lic IS NULL THEN
    RAISE EXCEPTION 'close_licence: licence % not found', p_licence;
  END IF;
  IF v_lic.status = 'terminated' THEN
    RETURN;                                   -- idempotent close
  END IF;
  UPDATE public.licences SET status = 'terminated', updated_at = now()
    WHERE id = p_licence;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_lic.partner_id, 'licence.closed',
          jsonb_build_object('licence_id', p_licence));
END $$;
COMMENT ON FUNCTION public.close_licence(uuid) IS
  'W1-07 FR-PLT-02: → terminated from any non-terminal status '
  '(platform_admin only). Terminal: a terminated licence takes no patches.';

-- ---------- 3. FR-ONB-02 capacity gate + near-limit warning ------------------

-- Raises when creating one more p_kind ('client'|'programme', default
-- 'programme') would take the partner AT or OVER the active licence cap.
-- NULL cap = uncapped. No active in-term licence ⇒ blocked outright.
CREATE FUNCTION public.assert_licence_capacity(
    p_partner uuid, p_kind text DEFAULT 'programme')
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE u record;
BEGIN
  -- explicit guard (the callee's guard would also fire — kept visible for
  -- the "definer guards in body" hard rule)
  IF auth.uid() IS NOT NULL
     AND NOT public.has_partner_role(p_partner,
            ARRAY['partner_admin','partner_consultant','read_only'])
     AND NOT public.is_platform_role(ARRAY['platform_admin','support']) THEN
    RAISE EXCEPTION 'assert_licence_capacity: no role on partner %', p_partner;
  END IF;
  IF p_kind NOT IN ('client','programme') THEN
    RAISE EXCEPTION 'assert_licence_capacity: kind must be client or programme';
  END IF;

  SELECT * INTO u FROM public.partner_licence_usage(p_partner);
  IF u.client_limit IS NULL AND u.programme_limit IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.licences l
                     WHERE l.partner_id = p_partner AND l.status = 'active'
                       AND l.starts_on <= CURRENT_DATE
                       AND (l.ends_on IS NULL OR l.ends_on > CURRENT_DATE)) THEN
    RAISE EXCEPTION 'assert_licence_capacity: partner % has no active in-term licence', p_partner;
  END IF;

  IF p_kind = 'client'
     AND u.client_limit IS NOT NULL AND u.clients_used >= u.client_limit THEN
    RAISE EXCEPTION 'assert_licence_capacity: client limit reached for partner % '
      '(% of % in use — FR-ONB-02)', p_partner, u.clients_used, u.client_limit;
  END IF;
  IF p_kind = 'programme'
     AND u.programme_limit IS NOT NULL AND u.programmes_used >= u.programme_limit THEN
    RAISE EXCEPTION 'assert_licence_capacity: programme limit reached for partner % '
      '(% of % in use — FR-ONB-02)', p_partner, u.programmes_used, u.programme_limit;
  END IF;
END $$;
COMMENT ON FUNCTION public.assert_licence_capacity(uuid, text) IS
  'W1-07 FR-ONB-02: raise when one more client/programme would take the '
  'partner at/over the active licence cap (§9.8 counting via '
  'partner_licence_usage). Call from client/programme creation paths BEFORE '
  'the insert.';

-- Passive sweep: emit a licence_warning notification_event for every partner
-- at/above 80% of a cap or within 30 days of term end. Deduped: one event
-- per (partner, trigger) per 30 days. Returns events emitted.
CREATE FUNCTION public.licence_warning_threshold_check(p_partner uuid DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_lic record; u record; v_emitted int := 0;
        v_trig record;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT public.is_platform_role(ARRAY['platform_admin','support'])
     AND NOT (p_partner IS NOT NULL
              AND public.has_partner_role(p_partner, ARRAY['partner_admin'])) THEN
    RAISE EXCEPTION 'licence_warning_threshold_check: platform role or '
      'partner_admin required';
  END IF;

  FOR v_lic IN
    SELECT l.* FROM public.licences l
     WHERE l.status = 'active'
       AND l.starts_on <= CURRENT_DATE
       AND (l.ends_on IS NULL OR l.ends_on > CURRENT_DATE)
       AND (p_partner IS NULL OR l.partner_id = p_partner)
  LOOP
    SELECT * INTO u FROM public.partner_licence_usage(v_lic.partner_id);

    -- trigger 1/2: at-or-above 80% of a cap
    FOR v_trig IN
      SELECT t.trigger, t.used, t.cap
        FROM (VALUES
          ('client_limit',    u.clients_used,    v_lic.client_limit),
          ('programme_limit', u.programmes_used, v_lic.programme_limit)
        ) AS t(trigger, used, cap)
       WHERE t.cap IS NOT NULL AND t.used::numeric >= 0.8 * t.cap
    LOOP
      IF NOT EXISTS (SELECT 1 FROM public.notification_events ne
                     WHERE ne.kind = 'licence_warning'
                       AND ne.scope->>'practice_id' = v_lic.partner_id::text
                       AND ne.payload->>'trigger' = v_trig.trigger
                       AND ne.created_at > now() - interval '30 days') THEN
        INSERT INTO public.notification_events (kind, scope, payload)
        VALUES ('licence_warning',
                jsonb_build_object('practice_id', v_lic.partner_id),
                jsonb_build_object('trigger', v_trig.trigger,
                                   'used', v_trig.used, 'limit', v_trig.cap,
                                   'licence_id', v_lic.id,
                                   -- 'securepath' is the W1-08 resolver's
                                   -- platform-staff token (spec §10:
                                   -- "Partner admin; SecurePath")
                                   'recipients', jsonb_build_array('partner_admin','securepath')));
        v_emitted := v_emitted + 1;
      END IF;
    END LOOP;

    -- trigger 3: term ending within 30 days
    IF v_lic.ends_on IS NOT NULL AND v_lic.ends_on <= CURRENT_DATE + 30
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                       WHERE ne.kind = 'licence_warning'
                         AND ne.scope->>'practice_id' = v_lic.partner_id::text
                         AND ne.payload->>'trigger' = 'end_date'
                         AND ne.created_at > now() - interval '30 days') THEN
      INSERT INTO public.notification_events (kind, scope, payload)
      VALUES ('licence_warning',
              jsonb_build_object('practice_id', v_lic.partner_id),
              jsonb_build_object('trigger', 'end_date',
                                 'ends_on', v_lic.ends_on,
                                 'days_to_end', v_lic.ends_on - CURRENT_DATE,
                                 'licence_id', v_lic.id,
                                 'recipients', jsonb_build_array('partner_admin','securepath')));
      v_emitted := v_emitted + 1;
    END IF;
  END LOOP;
  RETURN v_emitted;
END $$;
COMMENT ON FUNCTION public.licence_warning_threshold_check(uuid) IS
  'W1-07 passive licence-near-limit sweep (packet: 80% of cap; spec §10 '
  'trigger also covers 30-days-to-term-end). Emits licence_warning '
  'notification_events to the partner admin + SecurePath, deduped per '
  'trigger per 30 days. NULL partner sweeps all active licences.';

-- ---------- 4. FR-LIC-02 / FR-PLT-05 usage report -----------------------------
CREATE FUNCTION public.usage_report(p_partner uuid DEFAULT NULL)
RETURNS TABLE(partner_id uuid, partner_name text, partner_type text,
              licence_id uuid, plan text, licence_status text,
              clients_used int, client_limit int,
              programmes_used int, programme_limit int,
              active_users int, programmes_by_framework jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL THEN
    IF p_partner IS NULL THEN
      IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
        RAISE EXCEPTION 'usage_report: platform_admin required for the all-partner view';
      END IF;
    ELSIF NOT public.is_platform_role(ARRAY['platform_admin'])
          AND NOT public.has_partner_role(p_partner, ARRAY['partner_admin']) THEN
      RAISE EXCEPTION 'usage_report: platform_admin or own partner_admin required';
    END IF;
  END IF;

  RETURN QUERY
    SELECT p.id, p.name, p.type,
           l.id, l.plan, l.status,
           u.clients_used, l.client_limit,
           u.programmes_used, l.programme_limit,
           (SELECT count(DISTINCT ra.user_id)::int
              FROM public.role_assignments ra
              LEFT JOIN public.client_orgs sco
                ON ra.scope_type = 'client' AND sco.id = ra.scope_id
             WHERE ra.level IN ('partner','client')
               AND ra.start_date <= CURRENT_DATE
               AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
               AND ( (ra.scope_type = 'partner' AND ra.scope_id = p.id)
                  OR (ra.scope_type = 'client'  AND sco.practice_id = p.id) )),
           COALESCE((SELECT jsonb_object_agg(fw.framework, fw.cnt)
              FROM (SELECT COALESCE(pt.framework,'unassigned') AS framework,
                           count(*)::int AS cnt
                      FROM public.programmes pr
                      JOIN public.client_orgs fco ON fco.id = pr.client_org_id
                      LEFT JOIN public.programme_template_versions ptv
                        ON ptv.id = pr.template_version_id
                      LEFT JOIN public.programme_templates pt
                        ON pt.id = ptv.template_id
                     WHERE fco.practice_id = p.id AND pr.status <> 'closed'
                     GROUP BY 1) fw), '{}'::jsonb)
    FROM public.practices p
    LEFT JOIN LATERAL (
      SELECT * FROM public.partner_licence_usage(p.id)
    ) u ON true
    LEFT JOIN LATERAL (
      SELECT * FROM public.licences ll
       WHERE ll.partner_id = p.id AND ll.status = 'active'
         AND ll.starts_on <= CURRENT_DATE
         AND (ll.ends_on IS NULL OR ll.ends_on > CURRENT_DATE)
       ORDER BY ll.starts_on DESC LIMIT 1
    ) l ON true
    WHERE p_partner IS NULL OR p.id = p_partner
    ORDER BY p.name;
END $$;
COMMENT ON FUNCTION public.usage_report(uuid) IS
  'W1-07 FR-LIC-02/FR-PLT-05: per-partner usage vs licence caps — clients, '
  'non-closed programmes (with by-framework split), active tenant users. '
  'NULL = all partners (platform_admin only); a partner_admin may report '
  'on their own partner. Powers the W2-17 usage page.';

-- ---------- 5. support-access grant flow (NFR-04 / FR-PLT-04) ----------------

-- Platform support requests time-boxed read access to a client.
CREATE FUNCTION public.request_support_access(
    p_client_org_id uuid, p_reason text,
    p_expires_at timestamptz DEFAULT now() + interval '24 hours')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT public.is_platform_role(ARRAY['support','platform_admin']) THEN
    RAISE EXCEPTION 'request_support_access: platform support role required';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'request_support_access: reason is required (logged + client-visible)';
  END IF;
  SELECT practice_id INTO v_practice FROM public.client_orgs WHERE id = p_client_org_id;
  IF v_practice IS NULL THEN
    RAISE EXCEPTION 'request_support_access: unknown client %', p_client_org_id;
  END IF;
  IF p_expires_at <= now() THEN
    RAISE EXCEPTION 'request_support_access: expires_at must be in the future';
  END IF;

  INSERT INTO public.support_access_requests
      (client_org_id, requested_by, reason, expires_at)
  VALUES (p_client_org_id, auth.uid(), p_reason, p_expires_at)
  RETURNING id INTO v_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'support_access.requested',
          jsonb_build_object('request_id', v_id, 'client_org_id', p_client_org_id,
                             'expires_at', p_expires_at, 'reason', p_reason));
  -- notify the approvers: client accountable officer + partner admin (spec §10)
  INSERT INTO public.notification_events (kind, scope, payload)
  VALUES ('support_access_requested',
          jsonb_build_object('client_org_id', p_client_org_id,
                             'practice_id', v_practice),
          jsonb_build_object('request_id', v_id, 'requested_by', auth.uid(),
                             'reason', p_reason, 'expires_at', p_expires_at,
                             'recipients', jsonb_build_array('accountable_officer','partner_admin')));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.request_support_access(uuid, text, timestamptz) IS
  'W1-07 FR-PLT-04/NFR-04: a platform support user requests a time-boxed '
  'access window on a client. Creates a pending support_access_requests row '
  'only — no access is granted until a client-side approver approves.';

-- Client-side approval: creates the grant row AND the backing platform
-- client-scope role_assignment in ONE transaction (branch (e) needs both).
CREATE FUNCTION public.approve_support_grant(p_request_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_req record; v_practice uuid; v_grant uuid; v_start timestamptz;
        v_can boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  SELECT * INTO v_req FROM public.support_access_requests
   WHERE id = p_request_id FOR UPDATE;
  IF v_req IS NULL THEN
    RAISE EXCEPTION 'approve_support_grant: request % not found', p_request_id;
  END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'approve_support_grant: request % is % — not pending',
      p_request_id, v_req.status;
  END IF;

  SELECT practice_id INTO v_practice FROM public.client_orgs
   WHERE id = v_req.client_org_id;

  -- approver = owning partner's partner_admin, an active client-scope
  -- accountable_officer assignment, or the client's current IO designation
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
    RAISE EXCEPTION 'approve_support_grant: partner_admin of the owning partner '
      'or the client''s accountable officer required';
  END IF;

  -- window: starts now (or at the requested later start); ends at the
  -- approved expiry. An already-lapsed request is marked expired, never approved.
  v_start := GREATEST(v_req.starts_at, now());
  IF v_req.expires_at <= v_start THEN
    UPDATE public.support_access_requests
       SET status = 'expired', decided_by = auth.uid(), decided_at = now()
     WHERE id = p_request_id;
    RAISE EXCEPTION 'approve_support_grant: requested window has already lapsed — request expired';
  END IF;

  -- leg 1: the approved, in-window, unrevoked grant row
  INSERT INTO public.support_access_grants
      (client_org_id, securepath_user_id, reason, approved_by, starts_at, expires_at)
  VALUES (v_req.client_org_id, v_req.requested_by, v_req.reason,
          auth.uid(), v_start, v_req.expires_at)
  RETURNING id INTO v_grant;

  -- leg 2: the platform-level client-scope assignment. end_date is EXCLUSIVE
  -- (W0-00) → +1 day covers the whole expiry date; the grant's timestamptz
  -- window stays the precise gate. Always end-dated → never collides with
  -- role_assignments_one_active (which only covers open-ended rows).
  INSERT INTO public.role_assignments
      (user_id, level, role, scope_type, scope_id, start_date, end_date, origin)
  VALUES (v_req.requested_by, 'platform', 'support', 'client', v_req.client_org_id,
          v_start::date, (v_req.expires_at::date + 1), 'manual');

  UPDATE public.support_access_requests
     SET status = 'approved', decided_by = auth.uid(), decided_at = now(),
         grant_id = v_grant
   WHERE id = p_request_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'support_access.approved',
          jsonb_build_object('request_id', p_request_id, 'grant_id', v_grant,
                             'client_org_id', v_req.client_org_id,
                             'securepath_user_id', v_req.requested_by,
                             'expires_at', v_req.expires_at));
  INSERT INTO public.notification_events (kind, scope, payload)
  VALUES ('support_access_granted',
          jsonb_build_object('client_org_id', v_req.client_org_id,
                             'practice_id', v_practice,
                             'user_id', v_req.requested_by),
          jsonb_build_object('request_id', p_request_id, 'grant_id', v_grant,
                             'approved_by', auth.uid(),
                             'expires_at', v_req.expires_at,
                             'recipients', jsonb_build_array('accountable_officer','partner_admin')));
  RETURN v_grant;
END $$;
COMMENT ON FUNCTION public.approve_support_grant(uuid) IS
  'W1-07 FR-PLT-04/NFR-04: client-side approval — mints the grant row AND '
  'the platform client-scope role_assignment in one transaction (the W0-01 '
  'coupled check: branch (e) grants access only while BOTH exist). '
  'Approvers: owning partner''s partner_admin or the client AO.';

-- Early end: records revoked_at (row kept as the audit record).
CREATE FUNCTION public.revoke_support_grant(p_grant_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_g record; v_practice uuid; v_can boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_g FROM public.support_access_grants WHERE id = p_grant_id FOR UPDATE;
  IF v_g IS NULL THEN
    RAISE EXCEPTION 'revoke_support_grant: grant % not found', p_grant_id;
  END IF;
  IF v_g.revoked_at IS NOT NULL THEN
    RETURN;                                     -- already revoked — idempotent
  END IF;
  SELECT practice_id INTO v_practice FROM public.client_orgs
   WHERE id = v_g.client_org_id;

  v_can := public.is_platform_role(ARRAY['platform_admin'])
        OR public.has_partner_role(v_practice, ARRAY['partner_admin'])
        OR v_g.securepath_user_id = auth.uid()    -- holder relinquishes own access
        OR EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
                   WHERE a.level = 'client' AND a.scope_type = 'client'
                     AND a.scope_id = v_g.client_org_id
                     AND a.role = 'accountable_officer')
        OR EXISTS (SELECT 1 FROM public.designations d
                   WHERE d.client_org_id = v_g.client_org_id
                     AND d.person = auth.uid()
                     AND d.role = 'information_officer'
                     AND d.end_date IS NULL);
  IF NOT v_can THEN
    RAISE EXCEPTION 'revoke_support_grant: platform_admin, owning-partner '
      'partner_admin, client AO, or the grant holder required';
  END IF;

  UPDATE public.support_access_grants SET revoked_at = now() WHERE id = p_grant_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'support_access.revoked',
          jsonb_build_object('grant_id', p_grant_id,
                             'client_org_id', v_g.client_org_id,
                             'securepath_user_id', v_g.securepath_user_id));
  INSERT INTO public.notification_events (kind, scope, payload)
  VALUES ('support_access_revoked',
          jsonb_build_object('client_org_id', v_g.client_org_id,
                             'practice_id', v_practice,
                             'user_id', v_g.securepath_user_id),
          jsonb_build_object('grant_id', p_grant_id, 'revoked_by', auth.uid(),
                             'recipients', jsonb_build_array('accountable_officer','partner_admin')));
END $$;
COMMENT ON FUNCTION public.revoke_support_grant(uuid) IS
  'W1-07 NFR-04: revoke a support grant — sets revoked_at; the row is kept '
  'as the audit record (never deleted). The backing assignment is left '
  'dormant: branch (e) denies access the moment no live grant exists, and '
  'other concurrent grants for the same user+client keep working.';

-- Grant list with the expiry sweep: stale pending requests are flipped to
-- 'expired' first (the only lazy state needed — grant expiry itself is
-- derived live by the branch-(e) predicate).
CREATE FUNCTION public.list_support_grants(p_client_org_id uuid DEFAULT NULL)
RETURNS TABLE(id uuid, client_org_id uuid, securepath_user_id uuid,
              reason text, approved_by uuid, starts_at timestamptz,
              expires_at timestamptz, revoked_at timestamptz, state text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- sweep: pending requests whose requested window has lapsed
  UPDATE public.support_access_requests sar
     SET status = 'expired'
   WHERE sar.status = 'pending' AND sar.expires_at <= now();

  RETURN QUERY
    SELECT g.id, g.client_org_id, g.securepath_user_id, g.reason,
           g.approved_by, g.starts_at, g.expires_at, g.revoked_at,
           CASE WHEN g.revoked_at IS NOT NULL THEN 'revoked'
                WHEN g.expires_at <= now()    THEN 'expired'
                ELSE 'active' END
    FROM public.support_access_grants g
    WHERE (p_client_org_id IS NULL OR g.client_org_id = p_client_org_id)
      AND ( public.is_platform_role(ARRAY['platform_admin','support'])
         OR g.securepath_user_id = auth.uid()
         OR g.client_org_id IN (SELECT public.allowed_client_orgs()) )
    ORDER BY g.created_at DESC;
END $$;
COMMENT ON FUNCTION public.list_support_grants(uuid) IS
  'W1-07: support grants visible to the caller (platform staff all; the '
  'named holder and client-side users their own). Sweeps stale pending '
  'requests to expired first; grant state computed: revoked|expired|active.';

-- ---------- 6. grants ----------
-- Re-assert the hard rule: these rows are NEVER direct-writable — the only
-- write paths are the predicate-guarded definers above.
REVOKE INSERT, UPDATE, DELETE ON public.licences,
                                public.support_access_grants,
                                public.support_access_requests
  FROM authenticated, anon;

REVOKE EXECUTE ON FUNCTION
  public.issue_licence(uuid, jsonb),
  public.change_licence(uuid, jsonb),
  public.suspend_licence(uuid),
  public.close_licence(uuid),
  public.assert_licence_capacity(uuid, text),
  public.licence_warning_threshold_check(uuid),
  public.usage_report(uuid),
  public.request_support_access(uuid, text, timestamptz),
  public.approve_support_grant(uuid),
  public.revoke_support_grant(uuid),
  public.list_support_grants(uuid)
FROM anon, public;

GRANT EXECUTE ON FUNCTION
  public.issue_licence(uuid, jsonb),
  public.change_licence(uuid, jsonb),
  public.suspend_licence(uuid),
  public.close_licence(uuid),
  public.assert_licence_capacity(uuid, text),
  public.licence_warning_threshold_check(uuid),
  public.usage_report(uuid),
  public.request_support_access(uuid, text, timestamptz),
  public.approve_support_grant(uuid),
  public.revoke_support_grant(uuid),
  public.list_support_grants(uuid)
TO authenticated;

COMMIT;
