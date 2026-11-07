-- 20261106000034_brand_consumption.sql — W2-15 brand consumption (spec §7.4,
-- FR-BRN-01/02/03/05, AT-05). Two definers that make the partner's brand
-- reachable on every surface the spec paints:
--
--   partner_brand(partner)        authenticated callers — closes the
--                                 practices_read RLS gap for pure new-model
--                                 roles (programme-/workstream-scope users
--                                 cannot read practices via the deprecated
--                                 current_practice() shim, so the shell fell
--                                 back to SecurePath defaults)
--   public_partner_brand(host)    anon + authenticated — the sign-in surface
--                                 resolves the partner by subdomain BEFORE
--                                 there is a session (FR-BRN-02); anon cannot
--                                 read practices at all, so a narrowly-scoped
--                                 public slice is the only path
--
-- Both return a single jsonb row shaped like partner_branding(client_org)
-- (20261106000010) so web/lib/programme-context.ts maps all three through the
-- same BrandInfo type. SECURITY DEFINER bypasses RLS — the scope guard is in
-- each body, never in a policy.

-- ---------- 1. partner_brand — the caller's partner's brand ----------
CREATE OR REPLACE FUNCTION public.partner_brand(p_partner uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  -- the caller must belong to the partner, see one of its clients or
  -- programmes, or hold a platform role — same bar as partner_branding(),
  -- generalised from "this client" to "this partner" so partner-scope users
  -- with no clients yet (and client-scope-only consultants) both resolve.
  IF NOT (
       public.has_partner_role(p_partner,
         ARRAY['partner_admin','partner_consultant','partner_readonly','read_only'])
    OR public.is_platform_role(ARRAY['platform_admin','support','content_author'])
    OR EXISTS (SELECT 1 FROM public.client_orgs c
                WHERE c.practice_id = p_partner
                  AND c.id IN (SELECT public.allowed_client_orgs()))
    OR EXISTS (SELECT 1 FROM public.programmes pr
                JOIN public.client_orgs c ON c.id = pr.client_org_id
                WHERE c.practice_id = p_partner
                  AND pr.id IN (SELECT public.allowed_programmes()))
  ) THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
      'practice_id',        p.id,
      'name',               p.name,
      'type',               p.type,
      'logo_url',           p.logo_url,
      'accent_hex',         p.accent_hex,
      'primary_hex',        p.primary_hex,
      'subdomain',          p.subdomain,
      'sign_in_text',       p.sign_in_text,
      'support_contact',    p.support_contact,
      'email_sender_name',  p.email_sender_name,
      'attribution_display',
        COALESCE((SELECT l.attribution_display FROM public.licences l
                   WHERE l.partner_id = p.id AND l.status = 'active'
                   LIMIT 1), true)
    ) INTO v_row
  FROM public.practices p WHERE p.id = p_partner;
  RETURN v_row;
END $$;
COMMENT ON FUNCTION public.partner_brand(uuid) IS
  'W2-15 FR-BRN: the partner branding slice for any caller who legitimately '
  'sees the partner — partner-scope roles, any allowed client/programme under '
  'it, or platform roles. Closes the practices_read current_practice() gap '
  '(new-model roles got SecurePath defaults). NULL otherwise — same scope bar '
  'as partner_branding(client_org), no status filter (suspended partners '
  'still render for the platform/support callers who can see them). '
  'attribution_display = per-licence FR-BRN-05 flag, default true.';
REVOKE EXECUTE ON FUNCTION public.partner_brand(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.partner_brand(uuid) TO authenticated;

-- ---------- 2. public_partner_brand — the pre-auth sign-in slice ----------
CREATE OR REPLACE FUNCTION public.public_partner_brand(p_subdomain text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_sub text; v_row jsonb;
BEGIN
  -- normalise inline (platform_norm_subdomain raises on junk input — a bad
  -- Host label must degrade to the default brand, not a 500)
  v_sub := lower(btrim(COALESCE(p_subdomain, '')));
  IF v_sub = '' OR v_sub !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' THEN
    RETURN NULL;
  END IF;

  -- the sign-in page paints only what a visitor sees anyway: name, logo,
  -- colours, the partner's sign-in line and support contact, and the
  -- per-licence FR-BRN-05 attribution flag. email_sender_name/domains and
  -- report_template_refs stay out of the public slice.
  SELECT jsonb_build_object(
      'practice_id',        p.id,
      'name',               p.name,
      'type',               p.type,
      'logo_url',           p.logo_url,
      'accent_hex',         p.accent_hex,
      'primary_hex',        p.primary_hex,
      'subdomain',          p.subdomain,
      'sign_in_text',       p.sign_in_text,
      'support_contact',    p.support_contact,
      'attribution_display',
        COALESCE((SELECT l.attribution_display FROM public.licences l
                   WHERE l.partner_id = p.id AND l.status = 'active'
                   LIMIT 1), true)
    ) INTO v_row
  FROM public.practices p
  WHERE p.subdomain = v_sub AND p.status = 'active';
  RETURN v_row;
END $$;
COMMENT ON FUNCTION public.public_partner_brand(text) IS
  'W2-15 FR-BRN-02: sign-in resolves the partner by host subdomain — the '
  'public brand slice (name/logo/colours/sign-in text/support contact/'
  'attribution flag) for an ACTIVE partner, NULL otherwise. Callable by anon: '
  'there is no session yet on the sign-in page. Custom domains stay manual '
  '(plan §6); this resolves <subdomain>.<platform-domain> only.';
REVOKE EXECUTE ON FUNCTION public.public_partner_brand(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_partner_brand(text) TO anon, authenticated;
