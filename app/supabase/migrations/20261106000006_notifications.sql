-- ============================================================================
-- W1-08 — NOTIFICATION FAN-OUT: canonical emitter, per-user recipient
-- expansion with prefs (digest / per-kind mute), worker claim lease,
-- sent/failed marking, and the daily-digest aggregator.
-- (GitHub #22 · spec SP-SPC-PLT-001 §10, §12 · plan BUILD_PLAN_R1 W1-08)
-- ============================================================================
--
-- THE MODEL
--
--   notification_events   (W0-02, exists) — one row per emitted event; an
--                         outbox. scope jsonb: {practice_id?, client_org_id?,
--                         programme_id?, user_id?}; payload jsonb: recipients +
--                         render context.
--   notification_recipients (NEW here) — one row per (event, user): the
--                         fan-out. delivery='immediate'|'digest' decides when;
--                         channel='email'|'in_platform' decides how. status:
--                         pending → claimed → sent | failed.
--   notification_preferences (W0-02, exists) — per-user: digest boolean,
--                         kinds jsonb overrides.
--
-- CONTRACTS
--
--   payload.recipients — jsonb array; each element is either
--       * a user uuid (direct person address),
--       * {"user_id": "<uuid>"} or {"role": "<role>"} object form, or
--       * a role token resolved against the event scope with the SAME cascade
--         as the W0-02 write predicates:
--           scope.programme_id  → role at programme | its client | its partner
--           scope.client_org_id → role at client | its partner | its programmes
--           scope.practice_id   → role at partner scope only
--         'accountable_officer' additionally matches current designation
--         holders on the client (information_officer / deputy_information_
--         officer / dpo / named_alternate — FR-ACC-02/03: the AO function is
--         held by designation in SA law as much as by assignment);
--         'programme_lead' additionally matches programmes.programme_lead.
--
--   TOKEN VOCABULARY (canonical — emitters MUST use these; anything else
--   resolves to role_assignments.role verbatim):
--       role tokens     'partner_admin','partner_consultant','client_admin',
--                       'programme_lead','workstream_lead','accountable_officer',
--                       'executive','external_provider','assessor','read_only',
--                       'client_contributor'
--       platform staff  'securepath' | 'platform_admin' | 'platform_support'
--                       — all three aliases resolve to active platform-level
--                         users (role_assignments level='platform', roles
--                         platform_admin/support), e.g. licence alerts
--                         ("Partner admin; SecurePath", §10)
--       direct address  any uuid string or scope.user_id
--
--   notification_preferences.kinds — {"<kind>": {...}} per-kind overrides:
--       {"mute": true}                    → no row is created for that user
--       {"delivery": "immediate"|"digest"}→ overrides the global digest flag
--       {"channel": "email"|"in_platform"}→ default 'email'
--
--   §10 HARD RULE — breach alerts are IMMEDIATE. Any kind LIKE 'breach%'
--   resolves to delivery='immediate', channel='email', and per-kind mute is
--   ignored. Tested in app/tests/e2e_notifications.sql.
--
--   KIND TAXONOMY (documentation only — kind stays free text so new emitters
--   need no schema change; §10 trigger table):
--       activity_started, activity_due, activity_rag_change,
--       evidence_returned, evidence_awaiting_decision,
--       maintenance_input_requested, report_due_late,
--       breach_reported,                          ← §10 "Immediately"
--       dsr_nearing_due, decision_nearing_due, decision_recorded (W1-06),
--       template_version_published, licence_near_limit,
--       support_access_event, weekly_agenda (FR-WKS-05)
--
--   CHANNEL 'in_platform' — the recipient row itself IS the inbox (read via
--   the own-row RLS policy); resolve marks it 'sent' on creation ("delivered"
--   = the row exists). The mail worker only ever claims channel='email'.
--
--   CLOCK — every function takes p_now DEFAULT now(); tests inject fixed
--   times. (Role-activity windows still read CURRENT_DATE inside the W0-00
--   predicates — unchanged, out of scope.)
--
--   GUARDS (hard rule — definer bodies re-check because the definer owner
--   bypasses RLS):
--     queue_notification — EMISSION REQUIRES WRITE CAPABILITY, not just
--       visibility (review fix): a read-only user could otherwise mint
--       breach% events that force UNMUTABLE immediate branded mail to the
--       AO/partner/SecurePath — an abuse path, not just a bug. Rule
--       (notification_scope_writeable):
--         * auth.uid() IS NULL → service/definer-internal, allowed;
--         * scope must be VISIBLE to the caller (can't emit into invisible
--           scopes — same disjunction as notification_events_read);
--         * AND the caller holds a WRITE role in the scope cascade:
--             programme/client scope → has_programme_role/has_client_role over
--               {partner_admin,partner_consultant,client_admin,
--                programme_lead,workstream_lead}
--             partner scope → has_partner_role over {partner_admin,
--               partner_consultant}
--           ELEVATED for 'breach%'/'alert%' kinds (client-write or
--           partner-write only — read_only/contributor/workstream_lead can
--           NEVER emit them):
--               {partner_admin,partner_consultant,client_admin,
--                programme_lead,accountable_officer}
--         * user_id-only scope (the caller's own inbox, self-addressed) needs
--           no write role — it is the caller's own row.
--       Engines emitting on behalf of non-write users (e.g. "any user may
--       report a breach", §8.10) do so inside their own definer RPC by
--       INSERTing notification_events directly — the W1-06 pattern; the
--       claim/digest sweep resolves those lazily.
--     resolve_recipients — caller must be able to SEE the event scope (the
--       same disjunction), or be a service/definer-internal caller.
--     claim / mark_* / build_digest / digest_pending_users — transport-plane
--       only: auth.uid() must be NULL AND EXECUTE is granted to service_role
--       alone (revoked from public/anon/authenticated). Under PostgREST an
--       anon or authenticated JWT can therefore never reach them.
--
--   LEASE — claim_notification_batch stamps status='claimed' + a caller-chosen
--   claim_token; mark_* only finalise rows whose claim_token matches. A batch
--   lost mid-send becomes reclaimable after p_lease_seconds. build_digest runs
--   the same lease per user, so a digest can never be mailed twice by racing
--   workers.
--
--   DISPATCH STAMP — notification_events.dispatched_at (W0-02, write-
--   protected) is set once NO recipient row remains pending or claimed —
--   i.e. the event's whole fan-out has reached a terminal state. resolved_at
--   (added here) marks expansion so the lazy sweep never re-expands.
--
--   DEVIATION NOTE — the existing emitters (e.g. W1-06 record_decision)
--   INSERT notification_events directly, bypassing queue_notification.
--   queue_notification therefore resolves eagerly AND every worker entry
--   point lazily resolves events where resolved_at IS NULL — both emitter
--   styles fan out correctly.
-- ============================================================================

BEGIN;

-- ---------- 0. additive column on the W0-02 outbox ----------
ALTER TABLE public.notification_events
  ADD COLUMN resolved_at timestamptz;          -- set by resolve_recipients (definer)

COMMENT ON COLUMN public.notification_events.resolved_at IS
  'W1-08: set once the event has been expanded into notification_recipients. '
  'NULL = awaiting expansion (the claim/digest sweep resolves lazily — covers '
  'emitters that INSERT events directly). Write-protected: definer only.';


-- ---------- 1. notification_recipients — per-user fan-out ----------
CREATE TABLE public.notification_recipients (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    uuid NOT NULL REFERENCES public.notification_events(id) ON DELETE CASCADE,
    user_id     uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    delivery    text NOT NULL CHECK (delivery IN ('immediate','digest')),
    channel     text NOT NULL DEFAULT 'email' CHECK (channel IN ('email','in_platform')),
    status      text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','claimed','sent','failed')),
    attempts    int  NOT NULL DEFAULT 0,        -- send attempts; failed marks retry until cap
    claim_token uuid,                           -- lease token held by the claiming worker
    claimed_at  timestamptz,                    -- lease start (stale after p_lease_seconds)
    last_error  text,
    sent_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, user_id)                  -- one delivery per user per event
);
COMMENT ON TABLE public.notification_recipients IS
  'W1-08 notification fan-out — one delivery row per (event,user). The row '
  'itself is the in-platform inbox (own-row RLS read); channel=email rows are '
  'leased to the mail worker via claim_notification_batch. APPEND + dispatch '
  'only: no UPDATE/DELETE for authenticated; writes are definer-only.';
CREATE INDEX notification_recipients_claim_idx
  ON public.notification_recipients (created_at)
  WHERE channel = 'email' AND status IN ('pending','claimed');
CREATE INDEX notification_recipients_user_idx
  ON public.notification_recipients (user_id, status, delivery);
CREATE INDEX notification_recipients_event_idx
  ON public.notification_recipients (event_id);


-- ---------- 2. helpers ----------

-- §10 hard rule in one place: breach-family kinds never wait for a digest.
CREATE FUNCTION public.notification_is_immediate(p_kind text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT p_kind LIKE 'breach%'
$$;
COMMENT ON FUNCTION public.notification_is_immediate(text) IS
  'W1-08 / spec §10: breach alerts always go at once — kind LIKE ''breach%'' '
  'forces immediate delivery and ignores digest opt-in and per-kind mute.';

-- Can the caller see this event scope? Same disjunction as the W0-02
-- notification_events_read policy (defensively: presence + uuid shape before
-- cast so a malformed scope fails closed instead of erroring).
CREATE FUNCTION public.notification_scope_visible(p_scope jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN true                    -- service / definer-internal (W0-00 convention)
    WHEN p_scope ? 'client_org_id'
         AND (p_scope->>'client_org_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND (p_scope->>'client_org_id')::uuid IN (SELECT public.allowed_client_orgs()) THEN true
    WHEN p_scope ? 'programme_id'
         AND (p_scope->>'programme_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND (p_scope->>'programme_id')::uuid IN (SELECT public.allowed_programmes()) THEN true
    WHEN p_scope ? 'practice_id'
         AND (p_scope->>'practice_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND public.has_partner_role((p_scope->>'practice_id')::uuid,
              ARRAY['partner_admin','partner_consultant','read_only']) THEN true
    WHEN p_scope ? 'user_id'
         AND p_scope->>'user_id' = auth.uid()::text THEN true
    ELSE false
  END
$$;
COMMENT ON FUNCTION public.notification_scope_visible(jsonb) IS
  'W1-08 definer guard: caller can see the notification scope (same rule as '
  'notification_events_read) or is a service/definer-internal caller.';

-- Emission gate (review fix): visibility is NOT enough — a read-only caller
-- could otherwise mint breach% events that force unmutable immediate branded
-- mail to the AO/partner/SecurePath. Emission needs a WRITE role in the
-- scope cascade; breach%/alert% kinds need client-write or partner-write
-- (contributor/read_only/workstream_lead can never emit them).
CREATE FUNCTION public.notification_scope_writeable(
    p_kind text, p_scope jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_client  uuid;
  v_prog    uuid;
  v_partner uuid;
  v_roles   text[];
  v_uuid_re constant text :=
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
BEGIN
  IF auth.uid() IS NULL THEN RETURN true; END IF;            -- service/definer-internal
  IF NOT public.notification_scope_visible(p_scope) THEN RETURN false; END IF;
  -- elevated set for alert families (client-write | partner-write only)
  v_roles := CASE
    WHEN public.notification_is_immediate(p_kind) OR p_kind LIKE 'alert%'
      THEN ARRAY['partner_admin','partner_consultant','client_admin',
                 'programme_lead','accountable_officer']
    ELSE ARRAY['partner_admin','partner_consultant','client_admin',
               'programme_lead','workstream_lead']
  END;
  -- scope ids (presence + shape checked before every cast)
  IF p_scope ? 'client_org_id' AND (p_scope->>'client_org_id') ~* v_uuid_re THEN
    v_client := (p_scope->>'client_org_id')::uuid;
  END IF;
  IF p_scope ? 'programme_id' AND (p_scope->>'programme_id') ~* v_uuid_re THEN
    v_prog := (p_scope->>'programme_id')::uuid;
  END IF;
  IF p_scope ? 'practice_id' AND (p_scope->>'practice_id') ~* v_uuid_re THEN
    v_partner := (p_scope->>'practice_id')::uuid;
  END IF;
  IF v_prog IS NOT NULL THEN
    SELECT client_org_id INTO v_client FROM public.programmes WHERE id = v_prog;
  END IF;
  IF v_client IS NOT NULL AND v_partner IS NULL THEN
    SELECT practice_id INTO v_partner FROM public.client_orgs WHERE id = v_client;
  END IF;

  IF v_prog IS NOT NULL THEN
    RETURN public.has_programme_role(v_prog, v_roles);
  END IF;
  IF v_client IS NOT NULL THEN
    RETURN public.has_client_role(v_client, v_roles);
  END IF;
  IF v_partner IS NOT NULL THEN
    RETURN public.has_partner_role(v_partner, v_roles);
  END IF;
  RETURN true;   -- user_id-only scope: visible check above already forces self
END $$;
COMMENT ON FUNCTION public.notification_scope_writeable(text, jsonb) IS
  'W1-08 emission gate: caller holds a WRITE role in the scope cascade '
  '(or is service/definer-internal). breach%/alert% kinds restrict to '
  'client-write/partner-write — read_only, client_contributor and '
  'workstream_lead can never emit them.';

-- Transport-plane gate: the claim/mark/digest functions are for the mail
-- worker (service_role PostgREST JWT, no sub) and psql ops only. Inside a
-- user JWT (auth.uid() set) they refuse — EXECUTE grants additionally limit
-- them to service_role at the privilege layer.
CREATE FUNCTION public.notification_require_worker() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'notification transport functions are service-role only';
  END IF;
END $$;
COMMENT ON FUNCTION public.notification_require_worker() IS
  'W1-08 guard: notification transport functions reject user-JWT callers. '
  'The grant surface (service_role only) is the privilege-layer half.';


-- ---------- 3. resolve_recipients — expand an event into per-user rows ----------
CREATE FUNCTION public.resolve_recipients(
    p_event_id uuid,
    p_now      timestamptz DEFAULT now())
RETURNS SETOF public.notification_recipients
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ev      public.notification_events%ROWTYPE;
  v_client  uuid;
  v_prog    uuid;
  v_partner uuid;
  v_breach  boolean;
  v_uuid_re constant text :=
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
BEGIN
  SELECT * INTO v_ev FROM public.notification_events WHERE id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'notification event % not found', p_event_id;
  END IF;
  IF NOT public.notification_scope_visible(v_ev.scope) THEN
    RAISE EXCEPTION 'notification event scope is not visible to the caller';
  END IF;

  v_breach := public.notification_is_immediate(v_ev.kind);

  -- scope ids (presence + shape checked before every cast)
  IF v_ev.scope ? 'client_org_id' AND (v_ev.scope->>'client_org_id') ~* v_uuid_re THEN
    v_client := (v_ev.scope->>'client_org_id')::uuid;
  END IF;
  IF v_ev.scope ? 'programme_id' AND (v_ev.scope->>'programme_id') ~* v_uuid_re THEN
    v_prog := (v_ev.scope->>'programme_id')::uuid;
  END IF;
  IF v_ev.scope ? 'practice_id' AND (v_ev.scope->>'practice_id') ~* v_uuid_re THEN
    v_partner := (v_ev.scope->>'practice_id')::uuid;
  END IF;
  -- derive the missing links programme → client → partner
  IF v_prog IS NOT NULL THEN
    SELECT client_org_id INTO v_client FROM public.programmes WHERE id = v_prog;
  END IF;
  IF v_client IS NOT NULL AND v_partner IS NULL THEN
    SELECT practice_id INTO v_partner FROM public.client_orgs WHERE id = v_client;
  END IF;

  RETURN QUERY
  WITH toks AS (                                    -- recipient tokens
    SELECT DISTINCT tok FROM (
      SELECT CASE jsonb_typeof(el)
               WHEN 'string' THEN el #>> '{}'
               WHEN 'object' THEN coalesce(el->>'user_id', el->>'role')
             END AS tok
      FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(v_ev.payload->'recipients') = 'array'
                  THEN v_ev.payload->'recipients' ELSE '[]'::jsonb END) el
      UNION
      SELECT v_ev.scope->>'user_id'
      WHERE v_ev.scope ? 'user_id'
    ) t WHERE tok IS NOT NULL
  ),
  cand AS (
    -- uuid tokens: direct person addresses (incl. scope.user_id)
    SELECT t.tok::uuid AS user_id FROM toks t WHERE t.tok ~* v_uuid_re
    UNION
    -- 'securepath'|'platform_admin'|'platform_support': platform staff
    -- (licence/platform alerts, §10 — all three are aliases)
    SELECT ra.user_id FROM toks t
      JOIN public.role_assignments ra
        ON ra.level = 'platform' AND ra.role IN ('platform_admin','support')
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
     WHERE t.tok IN ('securepath','platform_admin','platform_support')
    UNION
    -- role tokens with a programme in scope: programme | client | partner cascade
    SELECT ra.user_id FROM toks t
      JOIN public.role_assignments ra
        ON ra.level IN ('partner','client') AND ra.role = t.tok
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
       AND ( (ra.scope_type = 'programme' AND ra.scope_id = v_prog)
          OR (ra.scope_type = 'client'    AND ra.scope_id = v_client)
          OR (ra.scope_type = 'partner'   AND ra.scope_id = v_partner) )
     WHERE v_prog IS NOT NULL
    UNION
    -- role tokens with a client (no programme): client | partner | its programmes
    SELECT ra.user_id FROM toks t
      JOIN public.role_assignments ra
        ON ra.level IN ('partner','client') AND ra.role = t.tok
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
       AND ( (ra.scope_type = 'client'  AND ra.scope_id = v_client)
          OR (ra.scope_type = 'partner' AND ra.scope_id = v_partner)
          OR (ra.scope_type = 'programme' AND ra.scope_id IN
               (SELECT p.id FROM public.programmes p WHERE p.client_org_id = v_client)) )
     WHERE v_prog IS NULL AND v_client IS NOT NULL
    UNION
    -- role tokens with only a partner: partner scope
    SELECT ra.user_id FROM toks t
      JOIN public.role_assignments ra
        ON ra.level IN ('partner','client') AND ra.role = t.tok
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
       AND ra.scope_type = 'partner' AND ra.scope_id = v_partner
     WHERE v_prog IS NULL AND v_client IS NULL AND v_partner IS NOT NULL
    UNION
    -- 'accountable_officer' also catches current designation holders (FR-ACC-02/03)
    SELECT d.person FROM toks t
      JOIN public.designations d
        ON d.client_org_id = v_client AND d.end_date IS NULL
       AND d.role IN ('information_officer','deputy_information_officer',
                      'dpo','named_alternate')
     WHERE t.tok = 'accountable_officer' AND v_client IS NOT NULL
    UNION
    -- 'programme_lead' also catches the programmes.programme_lead column
    SELECT p.programme_lead FROM toks t
      JOIN public.programmes p ON p.id = v_prog
     WHERE t.tok = 'programme_lead' AND v_prog IS NOT NULL
       AND p.programme_lead IS NOT NULL
  )
  INSERT INTO public.notification_recipients
      (event_id, user_id, delivery, channel, status, sent_at, created_at)
  SELECT p_event_id, c.user_id,
         CASE                                          -- delivery
           WHEN v_breach THEN 'immediate'               -- §10 hard rule
           WHEN coalesce(np.kinds->v_ev.kind->>'delivery','')
                IN ('immediate','digest')
                THEN np.kinds->v_ev.kind->>'delivery'
           WHEN coalesce(np.digest,false) THEN 'digest'
           ELSE 'immediate'
         END,
         CASE                                          -- channel
           WHEN v_breach THEN 'email'
           WHEN coalesce(np.kinds->v_ev.kind->>'channel','')
                IN ('email','in_platform')
                THEN np.kinds->v_ev.kind->>'channel'
           ELSE 'email'
         END,
         CASE                                          -- status
           WHEN NOT v_breach
                AND np.kinds->v_ev.kind->>'channel' = 'in_platform'
                THEN 'sent'                            -- row exists = delivered
           ELSE 'pending'
         END,
         CASE WHEN NOT v_breach
                   AND np.kinds->v_ev.kind->>'channel' = 'in_platform'
                   THEN p_now END,                     -- sent_at
         p_now
    FROM (SELECT DISTINCT user_id FROM cand) c
    JOIN public.users u ON u.id = c.user_id AND u.status = 'active'
    LEFT JOIN public.notification_preferences np ON np.user_id = c.user_id
   WHERE v_breach                                      -- mute can never silence a breach
      OR coalesce(np.kinds->v_ev.kind->>'mute','false') <> 'true'
  ON CONFLICT (event_id, user_id) DO NOTHING
  RETURNING *;

  -- mark the event expanded; if the fan-out is empty (nobody to tell, or all
  -- in-platform) the event is already fully dispatched
  UPDATE public.notification_events e
     SET resolved_at   = coalesce(e.resolved_at, p_now),
         dispatched_at = CASE
           WHEN NOT EXISTS (SELECT 1 FROM public.notification_recipients r
                             WHERE r.event_id = e.id
                               AND r.status IN ('pending','claimed'))
             THEN coalesce(e.dispatched_at, p_now)
           ELSE e.dispatched_at END
   WHERE e.id = p_event_id;
END $$;
COMMENT ON FUNCTION public.resolve_recipients(uuid, timestamptz) IS
  'W1-08: expand one notification_events row into per-user '
  'notification_recipients rows, honouring notification_preferences '
  '(digest opt-in, per-kind delivery/channel/mute). Breach kinds are always '
  'immediate+email and unmutable (spec §10 hard rule). Idempotent — '
  'ON CONFLICT keeps existing rows.';


-- ---------- 4. queue_notification — the canonical emitter ----------
CREATE FUNCTION public.queue_notification(
    p_kind    text,
    p_scope   jsonb DEFAULT '{}'::jsonb,
    p_payload jsonb DEFAULT '{}'::jsonb,
    p_now     timestamptz DEFAULT now())
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF p_kind IS NULL OR btrim(p_kind) = '' THEN
    RAISE EXCEPTION 'notification kind is required';
  END IF;
  IF NOT public.notification_scope_writeable(p_kind, coalesce(p_scope,'{}'::jsonb)) THEN
    RAISE EXCEPTION 'notification emission requires write capability on the scope';
  END IF;
  INSERT INTO public.notification_events (kind, scope, payload, created_at)
  VALUES (p_kind, coalesce(p_scope,'{}'::jsonb),
          coalesce(p_payload,'{}'::jsonb), p_now)
  RETURNING id INTO v_id;
  PERFORM public.resolve_recipients(v_id, p_now);   -- eager fan-out
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.queue_notification(text, jsonb, jsonb, timestamptz) IS
  'W1-08 canonical emitter: append a notification_events row and immediately '
  'expand it into per-user deliveries. Caller must be able to SEE the scope '
  'AND hold a write role in its cascade (client/partner write for breach% '
  'and alert% kinds); service/definer-internal callers are ungated. Engines '
  'emitting on behalf of non-write users raw-INSERT the event instead.';


-- ---------- 5. claim_notification_batch — worker lease ----------
CREATE FUNCTION public.claim_notification_batch(
    p_limit         int DEFAULT 50,
    p_lease_seconds int DEFAULT 300,
    p_now           timestamptz DEFAULT now(),
    p_token         uuid DEFAULT gen_random_uuid())
RETURNS SETOF public.notification_recipients
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.notification_require_worker();
  -- lazy expansion: emitters that INSERT events directly (W1-06 style) still fan out
  PERFORM public.resolve_recipients(e.id, p_now)
    FROM public.notification_events e WHERE e.resolved_at IS NULL;

  RETURN QUERY
  UPDATE public.notification_recipients r
     SET status = 'claimed', claim_token = p_token, claimed_at = p_now
   WHERE r.id IN (
     SELECT r2.id FROM public.notification_recipients r2
      WHERE r2.channel = 'email' AND r2.delivery = 'immediate'
        AND ( r2.status = 'pending'
           OR (r2.status = 'claimed'
               AND r2.claimed_at < p_now - make_interval(secs => p_lease_seconds)) )
      ORDER BY r2.created_at
      LIMIT GREATEST(p_limit, 1)
      FOR UPDATE SKIP LOCKED)
  RETURNING r.*;
END $$;
COMMENT ON FUNCTION public.claim_notification_batch(int, int, timestamptz, uuid) IS
  'W1-08 worker lease: claim up to p_limit pending immediate email deliveries '
  '(or stale claims past p_lease_seconds) under p_token; mark_* only finalise '
  'matching tokens. Service-role only. FOR UPDATE SKIP LOCKED → workers can '
  'race safely.';


-- ---------- 6. mark sent / failed ----------
CREATE FUNCTION public.mark_notification_sent(
    p_ids   uuid[],
    p_token uuid,
    p_now   timestamptz DEFAULT now())
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  PERFORM public.notification_require_worker();
  UPDATE public.notification_recipients r
     SET status = 'sent', sent_at = p_now,
         claim_token = NULL, claimed_at = NULL
   WHERE r.id = ANY(p_ids) AND r.claim_token = p_token AND r.status = 'claimed';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- stamp events whose whole fan-out is now terminal
  UPDATE public.notification_events e
     SET dispatched_at = coalesce(e.dispatched_at, p_now)
   WHERE e.id IN (SELECT DISTINCT r.event_id FROM public.notification_recipients r
                   WHERE r.id = ANY(p_ids))
     AND NOT EXISTS (SELECT 1 FROM public.notification_recipients r
                      WHERE r.event_id = e.id AND r.status IN ('pending','claimed'));
  RETURN v_n;
END $$;
COMMENT ON FUNCTION public.mark_notification_sent(uuid[], uuid, timestamptz) IS
  'W1-08: finalise claimed deliveries as sent (claim-token checked); stamps '
  'the parent event dispatched_at once no delivery remains pending/claimed.';

CREATE FUNCTION public.mark_notification_failed(
    p_ids          uuid[],
    p_token        uuid,
    p_error        text,
    p_now          timestamptz DEFAULT now(),
    p_max_attempts int DEFAULT 5)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  PERFORM public.notification_require_worker();
  UPDATE public.notification_recipients r
     SET attempts   = r.attempts + 1,
         last_error = left(coalesce(p_error,'unknown'), 2000),
         status     = CASE WHEN r.attempts + 1 >= p_max_attempts
                           THEN 'failed' ELSE 'pending' END,
         claim_token = NULL, claimed_at = NULL         -- release the lease for retry
   WHERE r.id = ANY(p_ids) AND r.claim_token = p_token AND r.status = 'claimed';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.notification_events e
     SET dispatched_at = coalesce(e.dispatched_at, p_now)
   WHERE e.id IN (SELECT DISTINCT r.event_id FROM public.notification_recipients r
                   WHERE r.id = ANY(p_ids))
     AND NOT EXISTS (SELECT 1 FROM public.notification_recipients r
                      WHERE r.event_id = e.id AND r.status IN ('pending','claimed'));
  RETURN v_n;
END $$;
COMMENT ON FUNCTION public.mark_notification_failed(uuid[], uuid, text, timestamptz, int) IS
  'W1-08: record a failed send (attempts+1, last_error) and release the lease '
  '— the row returns to pending until p_max_attempts, then terminal failed.';


-- ---------- 7. build_digest — per-user digest aggregator + lease ----------
CREATE FUNCTION public.digest_pending_users(
    p_now           timestamptz DEFAULT now(),
    p_lease_seconds int DEFAULT 3600)
RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.notification_require_worker();
  RETURN QUERY
  SELECT DISTINCT r.user_id FROM public.notification_recipients r
   WHERE r.delivery = 'digest' AND r.channel = 'email'
     AND ( r.status = 'pending'
        OR (r.status = 'claimed'
            AND r.claimed_at < p_now - make_interval(secs => p_lease_seconds)) );
END $$;
COMMENT ON FUNCTION public.digest_pending_users(timestamptz, int) IS
  'W1-08: users with mailable digest deliveries waiting — the daily 06:00 '
  'digest job (W1-09) iterates this, then calls build_digest per user.';

CREATE FUNCTION public.build_digest(
    p_user_id       uuid,
    p_since         timestamptz DEFAULT '-infinity'::timestamptz,
    p_now           timestamptz DEFAULT now(),
    p_token         uuid DEFAULT gen_random_uuid(),
    p_lease_seconds int DEFAULT 3600)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.notification_require_worker();
  -- lazy expansion so a digest never misses an unresolved event
  PERFORM public.resolve_recipients(e.id, p_now)
    FROM public.notification_events e WHERE e.resolved_at IS NULL;

  -- lease this user's pending digest deliveries (digest rows are never in the
  -- immediate claim path; they wait for the daily 06:00 job, §10)
  UPDATE public.notification_recipients r
     SET status = 'claimed', claim_token = p_token, claimed_at = p_now
   WHERE r.user_id = p_user_id AND r.delivery = 'digest' AND r.channel = 'email'
     AND r.created_at >= p_since
     AND ( r.status = 'pending'
        OR (r.status = 'claimed'
            AND r.claimed_at < p_now - make_interval(secs => p_lease_seconds)) );

  RETURN jsonb_build_object(
    'user_id',      p_user_id,
    'email',        (SELECT u.email FROM public.users u WHERE u.id = p_user_id),
    'claim_token',  p_token,
    'generated_at', p_now,
    'since',        p_since,
    'count',        (SELECT count(*) FROM public.notification_recipients r
                      WHERE r.claim_token = p_token AND r.user_id = p_user_id),
    'groups',       (SELECT coalesce(jsonb_agg(
                        jsonb_build_object('kind', g.kind, 'count', g.n,
                                           'items', g.items)
                        ORDER BY g.kind), '[]'::jsonb)
                     FROM (
                       SELECT e.kind, count(*) AS n,
                              jsonb_agg(jsonb_build_object(
                                          'id',        r.id,
                                          'event_id',  e.id,
                                          'subject',   e.payload->>'subject',
                                          'title',     e.payload->>'title',
                                          'body',      e.payload->>'body',
                                          'payload',   e.payload,
                                          'created_at', r.created_at)
                                        ORDER BY r.created_at) AS items
                         FROM public.notification_recipients r
                         JOIN public.notification_events e ON e.id = r.event_id
                        WHERE r.claim_token = p_token AND r.user_id = p_user_id
                        GROUP BY e.kind) g));
END $$;
COMMENT ON FUNCTION public.build_digest(uuid, timestamptz, timestamptz, uuid, int) IS
  'W1-08 digest aggregator: lease one user''s pending digest deliveries under '
  'p_token and return them grouped by kind for the branded digest mail. '
  'Breach alerts can never appear here — resolve_recipients forces them '
  'immediate (spec §10). Worker then marks them via mark_notification_sent.';


-- ---------- 8. RLS + grants ----------
ALTER TABLE public.notification_recipients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_recipients FORCE ROW LEVEL SECURITY;
-- own-row read only: the row is the in-platform inbox (§10 "and in the
-- platform"). No write policies — fan-out and dispatch are definer-only.
CREATE POLICY notification_recipients_read ON public.notification_recipients
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());
REVOKE ALL ON public.notification_recipients FROM anon, authenticated;
GRANT SELECT ON public.notification_recipients TO authenticated;
-- service_role keeps the image default grant (trusted backend, W0-00 convention)

-- lock the function surface (W0-00 convention), then open only what is needed
REVOKE EXECUTE ON FUNCTION
  public.notification_is_immediate(text),
  public.notification_scope_visible(jsonb),
  public.notification_scope_writeable(text, jsonb),
  public.notification_require_worker(),
  public.resolve_recipients(uuid, timestamptz),
  public.queue_notification(text, jsonb, jsonb, timestamptz),
  public.claim_notification_batch(int, int, timestamptz, uuid),
  public.mark_notification_sent(uuid[], uuid, timestamptz),
  public.mark_notification_failed(uuid[], uuid, text, timestamptz, int),
  public.digest_pending_users(timestamptz, int),
  public.build_digest(uuid, timestamptz, timestamptz, uuid, int)
FROM anon, public, authenticated;

-- user-plane: emit + expand (emit additionally gated by write-capability in the body)
GRANT EXECUTE ON FUNCTION
  public.notification_is_immediate(text),
  public.notification_scope_visible(jsonb),
  public.notification_scope_writeable(text, jsonb),
  public.resolve_recipients(uuid, timestamptz),
  public.queue_notification(text, jsonb, jsonb, timestamptz)
TO authenticated;

-- transport-plane: the mail worker only (service JWT carries no sub; the
-- in-body auth.uid() IS NULL guard is the second half)
GRANT EXECUTE ON FUNCTION
  public.notification_is_immediate(text),
  public.notification_scope_visible(jsonb),
  public.notification_scope_writeable(text, jsonb),
  public.resolve_recipients(uuid, timestamptz),
  public.queue_notification(text, jsonb, jsonb, timestamptz),
  public.claim_notification_batch(int, int, timestamptz, uuid),
  public.mark_notification_sent(uuid[], uuid, timestamptz),
  public.mark_notification_failed(uuid[], uuid, text, timestamptz, int),
  public.digest_pending_users(timestamptz, int),
  public.build_digest(uuid, timestamptz, timestamptz, uuid, int)
TO service_role;

COMMIT;
