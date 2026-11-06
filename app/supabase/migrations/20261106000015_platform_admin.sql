-- ============================================================================
-- W2-14 — PLATFORM ADMIN RPCs (partners CRUD, partner list, platform metrics)
-- (GitHub #39 · spec SP-SPC-PLT-001 §3, §4.1, §7.5 FR-PLT-01/02/04/05/06,
--  NFR-04 · plan BUILD_PLAN_R1 W2-14)
-- ============================================================================
--
-- Consumes the W0-00 predicate catalogue (is_platform_role), the W0-01
-- practices columns (type/status/country/subdomain/…), the W1-01 §9.8
-- counter partner_licence_usage(), the legacy practice_seats_used() seat
-- counter and the original invites table + accept_invite() flow.
--
-- Every function below is SECURITY DEFINER and carries its is_platform_role
-- guard IN THE BODY (a definer owned by supabase_admin bypasses RLS).
--
-- PIECES:
--   platform_create_partner     FR-PLT-01 create (platform_admin). Optional
--                               first partner_admin invite via the EXISTING
--                               invites table — accept_invite() already maps
--                               invite role practice_owner → partner_admin.
--   platform_update_partner     FR-PLT-01 edit — allowlisted fields only.
--   platform_set_partner_status FR-PLT-01/06 suspend / reactivate / close,
--                               reason required, audited.
--   platform_list_partners      partner metadata + licence state + client /
--                               programme counts + seat usage (counts via
--                               partner_licence_usage + practice_seats_used —
--                               NOT re-implemented here).
--   platform_list_clients       client DIRECTORY (id, name, jurisdiction,
--                               programme count) — needed to address a
--                               support-access request; no client content.
--   platform_metrics            FR-PLT-05 platform totals.
--
-- DECISIONS (spec ambiguities resolved here — flagged for review):
--
-- 1. NFR-04 / §3: platform staff see partner and licence data, never tenant
--    content. These RPCs return partner metadata and COUNTS only — no
--    evidence, register text, documents, programme names or user identities
--    of tenant staff. Tenant content stays reachable only through an
--    approved support grant (allowed_client_orgs branch (e)). The client
--    directory (platform_list_clients) exposes client name + jurisdiction
--    only, because a support request must name its client (FR-PLT-04).
--
-- 2. Role split (§4.1 "Create and suspend partners; issue licences": admin
--    Full, support None). Writers are platform_admin only. Readers
--    (list_partners, list_clients, metrics) also admit `support` — the task
--    packet asks for read-only support views, and §3 says SecurePath "sees
--    partner and licence data". The per-partner usage report itself
--    (usage_report) stays platform_admin-only as W1-07 defined it.
--    content_author gets nothing here.
--
-- 3. First partner_admin invite: the invites.role CHECK did not admit
--    'practice_owner' (the original model had the owner self-sign-up via
--    create_practice). It is widened ADDITIVELY below so the platform can
--    mint the first owner invite on the same table accept_invite() already
--    redeems (practice_owner → partner/partner_admin; owner seats are not
--    capped, matching practice_seats_used). The app server sends the mail
--    exactly like /api/invites does. No second invite mechanism exists.
--
-- 4. Status machine: active → suspended | closed; suspended → active |
--    closed; closed is TERMINAL (a closed partner's data is handled under
--    the partner/client agreements — FR-PLT-06; re-opening would be a new
--    partner). The status change is RECORDED ONLY here: blocking sign-in /
--    access for a suspended or closed partner is W4-08 (issue #55). Licence
--    status is NOT cascaded — licences are managed separately via the W1-07
--    licence RPCs so that a reactivation does not silently resurrect a
--    licence.
--
-- 5. Editable fields (platform_update_partner allowlist): name, type,
--    country, subdomain, primary_contact, support_contact,
--    data_region_default. Branding (logo, colours, sign-in text, sender,
--    report templates) is partner_admin's per §4.1 ("Partner branding" —
--    platform admin Read) and stays with W2-03's update_partner_branding.
--    status has its own RPC (reason + audit).
--
-- 6. Subdomain: lower-cased, must match the existing practices CHECK
--    (RFC-1123 label), must not be a reserved platform label, and must be
--    unique (pre-checked for a readable error; the UNIQUE constraint is the
--    backstop). NULL/'' = no subdomain.
--
-- 7. platform_metrics "evidence awaiting decision" = evidence_items whose
--    review_stage is 'verification' or 'acceptance' (not yet decided or
--    returned); both stages are reported plus a total. FR-PLT-05's "monthly
--    report completion rate" is NOT computed — programme monthly reports
--    are W2-08 and not yet built (flagged gap).
-- ============================================================================

BEGIN;

-- ---------- 1. schema additions (additive) ----------
-- (decision 3) the first partner_admin is invited as invite role practice_owner
ALTER TABLE public.invites DROP CONSTRAINT invites_role_check;
ALTER TABLE public.invites ADD CONSTRAINT invites_role_check CHECK (role IN
  ('practice_owner','practice_consultant','client_admin','client_contributor','read_only'));

ALTER TABLE public.practices
  ADD COLUMN status_reason     text,
  ADD COLUMN status_changed_at timestamptz;
COMMENT ON COLUMN public.practices.status_reason IS
  'W2-14: reason recorded with the latest platform_set_partner_status call '
  '(full history lives in audit_log partner.status_changed rows).';

-- ---------- 2. helpers (internal — not granted to authenticated) ----------
CREATE FUNCTION public.platform_norm_subdomain(p_sub text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE v text := lower(btrim(COALESCE(p_sub, '')));
BEGIN
  IF v = '' THEN RETURN NULL; END IF;
  IF v !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' THEN
    RAISE EXCEPTION 'subdomain "%" is invalid: use 1-63 lower-case letters, digits or hyphens, not starting or ending with a hyphen', p_sub;
  END IF;
  IF v IN ('www','api','app','admin','auth','rest','mail','smtp','static',
           'assets','cdn','platform','support','status','securepath') THEN
    RAISE EXCEPTION 'subdomain "%" is reserved by the platform', v;
  END IF;
  RETURN v;
END $$;

-- ---------- 3. platform_create_partner (FR-PLT-01) ----------
CREATE FUNCTION public.platform_create_partner(
    p_name text, p_type text, p_country text,
    p_subdomain text DEFAULT NULL,
    p_primary_contact text DEFAULT NULL,
    p_data_region_default text DEFAULT NULL,
    p_admin_email text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_sub text; v_tok uuid; v_email text;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION 'platform_create_partner: platform_admin required';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'platform_create_partner: name is required';
  END IF;
  IF p_type IS NULL OR p_type NOT IN ('msp','reseller','securepath_direct') THEN
    RAISE EXCEPTION 'platform_create_partner: type must be msp, reseller or securepath_direct';
  END IF;
  IF p_country IS NULL OR btrim(p_country) = '' THEN
    RAISE EXCEPTION 'platform_create_partner: country is required';
  END IF;
  v_sub := public.platform_norm_subdomain(p_subdomain);
  IF v_sub IS NOT NULL AND EXISTS (SELECT 1 FROM public.practices WHERE subdomain = v_sub) THEN
    RAISE EXCEPTION 'platform_create_partner: subdomain "%" is already taken', v_sub;
  END IF;
  v_email := NULLIF(lower(btrim(COALESCE(p_admin_email, ''))), '');
  IF v_email IS NOT NULL AND v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'platform_create_partner: admin email "%" is not a valid address', p_admin_email;
  END IF;

  INSERT INTO public.practices
      (name, type, country, subdomain, primary_contact, data_region_default)
  VALUES (btrim(p_name), p_type, upper(btrim(p_country)), v_sub,
          NULLIF(btrim(COALESCE(p_primary_contact, '')), ''),
          NULLIF(upper(btrim(COALESCE(p_data_region_default, ''))), ''))
  RETURNING id INTO v_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_id, 'partner.created',
          jsonb_build_object('name', btrim(p_name), 'type', p_type,
                             'country', upper(btrim(p_country)), 'subdomain', v_sub,
                             'admin_invite', v_email IS NOT NULL));

  -- optional first partner_admin — the existing invite mechanism (decision 3)
  IF v_email IS NOT NULL THEN
    INSERT INTO public.invites (practice_id, email, role, invited_by)
    VALUES (v_id, v_email, 'practice_owner', auth.uid())
    RETURNING token INTO v_tok;
    INSERT INTO public.audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), v_id, 'invite.created',
            jsonb_build_object('email', v_email, 'role', 'practice_owner',
                               'via', 'platform_create_partner'));
  END IF;

  RETURN jsonb_build_object('partner_id', v_id, 'invite_token', v_tok);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'platform_create_partner: subdomain "%" is already taken', v_sub;
END $$;
COMMENT ON FUNCTION public.platform_create_partner(text, text, text, text, text, text, text) IS
  'W2-14 FR-PLT-01: create a partner (platform_admin only). Validates type, '
  'country and subdomain (format, reserved labels, uniqueness). Optional '
  'p_admin_email mints a practice_owner invite on the existing invites table '
  '(accept_invite → partner_admin). Returns {partner_id, invite_token}. '
  'Writes audit_log.';

-- ---------- 4. platform_update_partner (FR-PLT-01) ----------
CREATE FUNCTION public.platform_update_partner(p_partner uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old public.practices%ROWTYPE; v_key text; v_sub text;
        v_prev jsonb := '{}'::jsonb;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION 'platform_update_partner: platform_admin required';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR p_payload = '{}'::jsonb THEN
    RAISE EXCEPTION 'platform_update_partner: non-empty payload object required';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_payload) LOOP
    IF v_key NOT IN ('name','type','country','subdomain','primary_contact',
                     'support_contact','data_region_default') THEN
      RAISE EXCEPTION 'platform_update_partner: field "%" is not editable here', v_key;
    END IF;
  END LOOP;

  SELECT * INTO v_old FROM public.practices WHERE id = p_partner FOR UPDATE;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'platform_update_partner: partner % not found', p_partner;
  END IF;
  IF v_old.status = 'closed' THEN
    RAISE EXCEPTION 'platform_update_partner: partner % is closed', p_partner;
  END IF;

  IF p_payload ? 'name' AND btrim(COALESCE(p_payload->>'name', '')) = '' THEN
    RAISE EXCEPTION 'platform_update_partner: name cannot be empty';
  END IF;
  IF p_payload ? 'type'
     AND COALESCE(p_payload->>'type', '') NOT IN ('msp','reseller','securepath_direct') THEN
    RAISE EXCEPTION 'platform_update_partner: type must be msp, reseller or securepath_direct';
  END IF;
  IF p_payload ? 'country' AND btrim(COALESCE(p_payload->>'country', '')) = '' THEN
    RAISE EXCEPTION 'platform_update_partner: country cannot be empty';
  END IF;
  IF p_payload ? 'subdomain' THEN
    v_sub := public.platform_norm_subdomain(p_payload->>'subdomain');
    IF v_sub IS NOT NULL AND EXISTS (SELECT 1 FROM public.practices
                                      WHERE subdomain = v_sub AND id <> p_partner) THEN
      RAISE EXCEPTION 'platform_update_partner: subdomain "%" is already taken', v_sub;
    END IF;
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_payload) LOOP
    v_prev := v_prev || jsonb_build_object(v_key, to_jsonb(v_old) -> v_key);
  END LOOP;

  UPDATE public.practices SET
    name                = CASE WHEN p_payload ? 'name'    THEN btrim(p_payload->>'name') ELSE name END,
    type                = CASE WHEN p_payload ? 'type'    THEN p_payload->>'type' ELSE type END,
    country             = CASE WHEN p_payload ? 'country' THEN upper(btrim(p_payload->>'country')) ELSE country END,
    subdomain           = CASE WHEN p_payload ? 'subdomain' THEN v_sub ELSE subdomain END,
    primary_contact     = CASE WHEN p_payload ? 'primary_contact'
                               THEN NULLIF(btrim(COALESCE(p_payload->>'primary_contact', '')), '')
                               ELSE primary_contact END,
    support_contact     = CASE WHEN p_payload ? 'support_contact'
                               THEN NULLIF(btrim(COALESCE(p_payload->>'support_contact', '')), '')
                               ELSE support_contact END,
    data_region_default = CASE WHEN p_payload ? 'data_region_default'
                               THEN NULLIF(upper(btrim(COALESCE(p_payload->>'data_region_default', ''))), '')
                               ELSE data_region_default END
  WHERE id = p_partner;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), p_partner, 'partner.updated',
          jsonb_build_object('patch', p_payload, 'previous', v_prev));
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'platform_update_partner: subdomain "%" is already taken', v_sub;
END $$;
COMMENT ON FUNCTION public.platform_update_partner(uuid, jsonb) IS
  'W2-14 FR-PLT-01: patch partner metadata (platform_admin only). Allowlist: '
  'name, type, country, subdomain, primary_contact, support_contact, '
  'data_region_default. Branding stays partner_admin''s (W2-03); status has '
  'its own RPC. Audit row carries patch + previous values.';

-- ---------- 5. platform_set_partner_status (FR-PLT-01 / FR-PLT-06) ----------
-- RECORDS the status only. Blocking sign-in / data access for suspended or
-- closed partners is W4-08 (issue #55) — nothing here enforces it.
CREATE FUNCTION public.platform_set_partner_status(
    p_partner uuid, p_status text, p_reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old text;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION 'platform_set_partner_status: platform_admin required';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('active','suspended','closed') THEN
    RAISE EXCEPTION 'platform_set_partner_status: status must be active, suspended or closed';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'platform_set_partner_status: a reason is required';
  END IF;
  SELECT status INTO v_old FROM public.practices WHERE id = p_partner FOR UPDATE;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'platform_set_partner_status: partner % not found', p_partner;
  END IF;
  IF v_old = p_status THEN
    RAISE EXCEPTION 'platform_set_partner_status: partner is already %', p_status;
  END IF;
  IF v_old = 'closed' THEN
    RAISE EXCEPTION 'platform_set_partner_status: a closed partner cannot be reopened';
  END IF;

  UPDATE public.practices
     SET status = p_status, status_reason = btrim(p_reason), status_changed_at = now()
   WHERE id = p_partner;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), p_partner, 'partner.status_changed',
          jsonb_build_object('from', v_old, 'to', p_status,
                             'transition', CASE WHEN p_status = 'suspended' THEN 'suspend'
                                                WHEN p_status = 'closed'    THEN 'close'
                                                ELSE 'reactivate' END,
                             'reason', btrim(p_reason)));
END $$;
COMMENT ON FUNCTION public.platform_set_partner_status(uuid, text, text) IS
  'W2-14 FR-PLT-01/06: suspend / reactivate / close a partner with a '
  'mandatory reason; audited as partner.status_changed. Records status ONLY '
  '— sign-in/access blocking is W4-08 (#55). closed is terminal. Licences '
  'are not cascaded (use the W1-07 licence RPCs).';

-- ---------- 6. platform_list_partners ----------
-- p_filters keys (all optional): id, status, type, country, q (name search).
CREATE FUNCTION public.platform_list_partners(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE(partner_id uuid, name text, type text, status text,
              status_reason text, status_changed_at timestamptz,
              country text, subdomain text, primary_contact text,
              support_contact text, data_region_default text,
              created_at timestamptz,
              licence_id uuid, licence_plan text, licence_status text,
              licence_starts_on date, licence_ends_on date,
              client_limit int, programme_limit int,
              clients_total int, clients_used int,
              programmes_used int, over_client_limit boolean,
              over_programme_limit boolean,
              seats_used int, pending_invites int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin','support']) THEN
    RAISE EXCEPTION 'platform_list_partners: platform_admin or support required';
  END IF;
  IF jsonb_typeof(v_f) <> 'object' THEN
    RAISE EXCEPTION 'platform_list_partners: filters must be a jsonb object';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(v_f) LOOP
    IF v_key NOT IN ('id','status','type','country','q') THEN
      RAISE EXCEPTION 'platform_list_partners: unknown filter "%"', v_key;
    END IF;
  END LOOP;

  RETURN QUERY
    SELECT p.id, p.name, p.type, p.status, p.status_reason, p.status_changed_at,
           p.country, p.subdomain, p.primary_contact, p.support_contact,
           p.data_region_default, p.created_at,
           l.id, l.plan, l.status, l.starts_on, l.ends_on,
           u.client_limit, u.programme_limit,
           (SELECT count(*)::int FROM public.client_orgs co WHERE co.practice_id = p.id),
           u.clients_used, u.programmes_used,
           u.over_client_limit, u.over_programme_limit,
           public.practice_seats_used(p.id),
           (SELECT count(*)::int FROM public.invites i
             WHERE i.practice_id = p.id AND i.accepted_at IS NULL AND i.expires_at > now())
    FROM public.practices p
    -- §9.8 counting + active-licence caps: the W1-01 counter, not a copy
    CROSS JOIN LATERAL public.partner_licence_usage(p.id) u
    -- "current" licence for display: the active one, else the most recent
    -- non-terminated, else the most recent
    LEFT JOIN LATERAL (
      SELECT ll.* FROM public.licences ll
       WHERE ll.partner_id = p.id
       ORDER BY (ll.status = 'active') DESC, (ll.status <> 'terminated') DESC,
                ll.created_at DESC
       LIMIT 1
    ) l ON true
    WHERE (NOT v_f ? 'id'      OR p.id = (v_f->>'id')::uuid)
      AND (NOT v_f ? 'status'  OR p.status = v_f->>'status')
      AND (NOT v_f ? 'type'    OR p.type = v_f->>'type')
      AND (NOT v_f ? 'country' OR p.country = upper(v_f->>'country'))
      AND (NOT v_f ? 'q'       OR p.name ILIKE '%' || (v_f->>'q') || '%')
    ORDER BY p.name;
END $$;
COMMENT ON FUNCTION public.platform_list_partners(jsonb) IS
  'W2-14: partners with metadata, current licence, client/programme counts '
  '(partner_licence_usage §9.8) and seat usage (practice_seats_used). '
  'platform_admin + support (read-only). Counts and partner metadata ONLY — '
  'no tenant content (NFR-04). Filters: id, status, type, country, q.';

-- ---------- 7. platform_list_clients (support-request directory) ----------
CREATE FUNCTION public.platform_list_clients(p_partner uuid DEFAULT NULL)
RETURNS TABLE(client_org_id uuid, client_name text, partner_id uuid,
              partner_name text, jurisdiction text, created_at timestamptz,
              programmes_total int, programmes_open int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin','support']) THEN
    RAISE EXCEPTION 'platform_list_clients: platform_admin or support required';
  END IF;
  RETURN QUERY
    SELECT co.id, co.name, p.id, p.name, co.jurisdiction, co.created_at,
           (SELECT count(*)::int FROM public.programmes pr WHERE pr.client_org_id = co.id),
           (SELECT count(*)::int FROM public.programmes pr
             WHERE pr.client_org_id = co.id AND pr.status <> 'closed')
    FROM public.client_orgs co
    JOIN public.practices p ON p.id = co.practice_id
    WHERE p_partner IS NULL OR co.practice_id = p_partner
    ORDER BY p.name, co.name;
END $$;
COMMENT ON FUNCTION public.platform_list_clients(uuid) IS
  'W2-14: client DIRECTORY for platform staff — id, name, jurisdiction, '
  'programme counts. Exists so a support-access request (FR-PLT-04) can name '
  'its client. No client content (NFR-04): content needs a support grant.';

-- ---------- 8. platform_metrics (FR-PLT-05) ----------
CREATE FUNCTION public.platform_metrics()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin','support']) THEN
    RAISE EXCEPTION 'platform_metrics: platform_admin or support required';
  END IF;

  SELECT jsonb_build_object(
    'generated_at', now(),
    'partners', jsonb_build_object(
       'total',     (SELECT count(*) FROM public.practices),
       'active',    (SELECT count(*) FROM public.practices WHERE status = 'active'),
       'suspended', (SELECT count(*) FROM public.practices WHERE status = 'suspended'),
       'closed',    (SELECT count(*) FROM public.practices WHERE status = 'closed'),
       'by_type',   COALESCE((SELECT jsonb_object_agg(t.type, t.n) FROM
                      (SELECT type, count(*) AS n FROM public.practices GROUP BY type) t),
                      '{}'::jsonb)),
    'licences', COALESCE((SELECT jsonb_object_agg(s.status, s.n) FROM
                  (SELECT status, count(*) AS n FROM public.licences GROUP BY status) s),
                  '{}'::jsonb),
    'clients', jsonb_build_object(
       'total', (SELECT count(*) FROM public.client_orgs),
       'with_open_programme', (SELECT count(DISTINCT client_org_id) FROM public.programmes
                                WHERE status <> 'closed')),
    'programmes', jsonb_build_object(
       'total',          (SELECT count(*) FROM public.programmes),
       'implementation', (SELECT count(*) FROM public.programmes WHERE status = 'implementation'),
       'maintenance',    (SELECT count(*) FROM public.programmes WHERE status = 'maintenance'),
       'closed',         (SELECT count(*) FROM public.programmes WHERE status = 'closed'),
       'by_framework',   COALESCE((SELECT jsonb_object_agg(f.framework, f.n) FROM
                           (SELECT COALESCE(pt.framework, 'unassigned') AS framework, count(*) AS n
                              FROM public.programmes pr
                              LEFT JOIN public.programme_template_versions ptv
                                ON ptv.id = pr.template_version_id
                              LEFT JOIN public.programme_templates pt ON pt.id = ptv.template_id
                             WHERE pr.status <> 'closed'
                             GROUP BY 1) f), '{}'::jsonb)),
    -- distinct tenant users holding an ACTIVE partner/client assignment
    -- (platform staff excluded)
    'active_users', (SELECT count(DISTINCT ra.user_id) FROM public.role_assignments ra
                      WHERE ra.level IN ('partner','client')
                        AND ra.start_date <= CURRENT_DATE
                        AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)),
    'evidence_awaiting', jsonb_build_object(
       'verification', (SELECT count(*) FROM public.evidence_items WHERE review_stage = 'verification'),
       'acceptance',   (SELECT count(*) FROM public.evidence_items WHERE review_stage = 'acceptance'),
       'total',        (SELECT count(*) FROM public.evidence_items
                         WHERE review_stage IN ('verification','acceptance'))),
    'support', jsonb_build_object(
       'pending_requests', (SELECT count(*) FROM public.support_access_requests
                             WHERE status = 'pending' AND expires_at > now()),
       'active_grants',    (SELECT count(*) FROM public.support_access_grants
                             WHERE revoked_at IS NULL AND starts_at <= now()
                               AND expires_at > now()))
  ) INTO v;
  RETURN v;
END $$;
COMMENT ON FUNCTION public.platform_metrics() IS
  'W2-14 FR-PLT-05: platform totals — partners by status/type, licences by '
  'status, clients, programmes by status + framework, active tenant users, '
  'evidence awaiting decision, support requests/grants. Counts only (NFR-04). '
  'platform_admin + support. Monthly report completion rate deferred to W2-08.';

-- ---------- 9. grants ----------
REVOKE EXECUTE ON FUNCTION public.platform_norm_subdomain(text) FROM anon, public, authenticated;

REVOKE EXECUTE ON FUNCTION
  public.platform_create_partner(text, text, text, text, text, text, text),
  public.platform_update_partner(uuid, jsonb),
  public.platform_set_partner_status(uuid, text, text),
  public.platform_list_partners(jsonb),
  public.platform_list_clients(uuid),
  public.platform_metrics()
FROM anon, public;

GRANT EXECUTE ON FUNCTION
  public.platform_create_partner(text, text, text, text, text, text, text),
  public.platform_update_partner(uuid, jsonb),
  public.platform_set_partner_status(uuid, text, text),
  public.platform_list_partners(jsonb),
  public.platform_list_clients(uuid),
  public.platform_metrics()
TO authenticated;

COMMIT;
