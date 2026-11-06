-- 20261106000010_partner_branding.sql — orchestrator fix (W1-10 schema request)
-- practices_read RLS resolves via deprecated current_practice(): NULL for pure
-- new-model users (executive, AO, PL, WL, platform_*, client-scope roles), so
-- they can't read partner branding and the shell falls back to defaults.
-- This definer returns exactly the branding slice the app needs, guarded by
-- the modern predicates — no RLS widening on practices/licences.
CREATE OR REPLACE FUNCTION public.partner_branding(p_client_org uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_practice uuid; v_row jsonb;
BEGIN
  -- caller must be able to see the client (any scope) or hold a partner role
  -- on the owning practice
  SELECT c.practice_id INTO v_practice FROM public.client_orgs c WHERE c.id = p_client_org;
  IF v_practice IS NULL THEN RETURN NULL; END IF;
  IF NOT ( p_client_org IN (SELECT public.allowed_client_orgs())
        OR public.has_partner_role(v_practice,
              ARRAY['partner_admin','partner_consultant','partner_readonly'])
        OR public.is_platform_role(ARRAY['platform_admin','support','content_author']) ) THEN
    RETURN NULL;
  END IF;
  SELECT jsonb_build_object(
      'practice_id',   p.id,
      'name',          p.name,
      'logo_url',      p.logo_url,
      'accent_hex',    p.accent_hex,
      'subdomain',     p.subdomain,
      'sign_in_text',  p.sign_in_text,
      'support_contact', p.support_contact,
      'email_sender_name', p.email_sender_name,
      'attribution_display',
        COALESCE((SELECT l.attribution_display FROM public.licences l
                   WHERE l.practice_id = p.id AND l.status = 'active'
                   LIMIT 1), true)
    ) INTO v_row
  FROM public.practices p WHERE p.id = v_practice;
  RETURN v_row;
END $$;
COMMENT ON FUNCTION public.partner_branding(uuid) IS
  'Branding slice for the shell (FR-BRN): readable by anyone who can see the '
  'client — works for new-model roles that current_practice() cannot resolve. '
  'attribution_display = per-licence FR-BRN-05 flag, default true.';
REVOKE EXECUTE ON FUNCTION public.partner_branding(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.partner_branding(uuid) TO authenticated;
