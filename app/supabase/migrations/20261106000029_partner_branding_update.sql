-- 20261106000029_partner_branding_update.sql — W2-03 white-label branding
-- (spec §7.4 screen 12, FR-BRN-01). The branding write path for partners.
--
-- Practices carry the FR-BRN-01 columns since 20261105000002: name, logo_url,
-- accent_hex, primary_hex, sign_in_text, support_contact, email_sender_name
-- (subdomain is deliberately NOT here — it is platform_update_partner's
-- allowlist; partner branding stays partner_admin's, per that migration's
-- note). Until now the only write was the legacy practices_update RLS path —
-- a direct table UPDATE from the browser, un-audited, and keyed on the
-- deprecated current_practice()/current_role_name() shims. This definer is
-- the single write path the /settings/branding screen now calls:
--   * partner_admin guard via has_partner_role (works for legacy-mapped
--     practice_owner and new-model assignments alike)
--   * strict allowlist + validation
--   * append-only audit_log row (patch + previous values)
--   * returns the stored branding slice so callers can confirm what landed

CREATE FUNCTION public.update_practice_branding(
    p_partner uuid,
    p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_keys constant text[] := ARRAY[
    'name', 'logo_url', 'accent_hex', 'primary_hex',
    'sign_in_text', 'support_contact', 'email_sender_name'];
  v_old  public.practices%ROWTYPE;
  v_prev jsonb := '{}';
  v_key  text;
  v_hex  text;
  v_url  text;
  v_out  jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'update_practice_branding: not authenticated';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR p_payload = '{}'::jsonb THEN
    RAISE EXCEPTION 'update_practice_branding: empty payload';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_payload) LOOP
    IF NOT v_key = ANY(v_keys) THEN
      RAISE EXCEPTION 'update_practice_branding: "%" is not a branding field', v_key;
    END IF;
  END LOOP;

  SELECT * INTO v_old FROM public.practices WHERE id = p_partner FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'update_practice_branding: partner % not found', p_partner;
  END IF;
  -- SECURITY DEFINER bypasses RLS — the guard must live in the body (and it
  -- must run BEFORE any write, not just before returning data).
  IF NOT public.has_partner_role(p_partner, ARRAY['partner_admin']) THEN
    RAISE EXCEPTION 'update_practice_branding: partner_admin required';
  END IF;

  -- ---- validation (same conventions as platform_update_partner) ----
  IF p_payload ? 'name' AND btrim(COALESCE(p_payload->>'name', '')) = '' THEN
    RAISE EXCEPTION 'update_practice_branding: name cannot be empty';
  END IF;
  FOREACH v_key IN ARRAY ARRAY['accent_hex', 'primary_hex'] LOOP
    IF p_payload ? v_key THEN
      v_hex := p_payload->>v_key;   -- jsonb null clears; otherwise #rrggbb
      IF v_hex IS NOT NULL AND v_hex !~ '^#[0-9a-fA-F]{6}$' THEN
        RAISE EXCEPTION 'update_practice_branding: % must be "#rrggbb" or null', v_key;
      END IF;
    END IF;
  END LOOP;
  IF p_payload ? 'logo_url' THEN
    v_url := NULLIF(btrim(COALESCE(p_payload->>'logo_url', '')), '');
    IF v_url IS NOT NULL AND v_url !~ '^https?://' THEN
      RAISE EXCEPTION 'update_practice_branding: logo_url must be an http(s) URL';
    END IF;
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_payload) LOOP
    v_prev := v_prev || jsonb_build_object(v_key, to_jsonb(v_old) -> v_key);
  END LOOP;

  UPDATE public.practices SET
    name              = CASE WHEN p_payload ? 'name'
                             THEN btrim(p_payload->>'name') ELSE name END,
    logo_url          = CASE WHEN p_payload ? 'logo_url' THEN v_url ELSE logo_url END,
    accent_hex        = CASE WHEN p_payload ? 'accent_hex'
                             THEN lower(p_payload->>'accent_hex') ELSE accent_hex END,
    primary_hex       = CASE WHEN p_payload ? 'primary_hex'
                             THEN lower(p_payload->>'primary_hex') ELSE primary_hex END,
    sign_in_text      = CASE WHEN p_payload ? 'sign_in_text'
                             THEN NULLIF(btrim(COALESCE(p_payload->>'sign_in_text', '')), '')
                             ELSE sign_in_text END,
    support_contact   = CASE WHEN p_payload ? 'support_contact'
                             THEN NULLIF(btrim(COALESCE(p_payload->>'support_contact', '')), '')
                             ELSE support_contact END,
    email_sender_name = CASE WHEN p_payload ? 'email_sender_name'
                             THEN NULLIF(btrim(COALESCE(p_payload->>'email_sender_name', '')), '')
                             ELSE email_sender_name END
  WHERE id = p_partner;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), p_partner, 'partner.branding_updated',
          jsonb_build_object('patch', p_payload, 'previous', v_prev));

  SELECT jsonb_build_object(
      'practice_id',       p.id,
      'name',              p.name,
      'logo_url',          p.logo_url,
      'accent_hex',        p.accent_hex,
      'primary_hex',       p.primary_hex,
      'sign_in_text',      p.sign_in_text,
      'support_contact',   p.support_contact,
      'email_sender_name', p.email_sender_name)
    INTO v_out
  FROM public.practices p WHERE p.id = p_partner;
  RETURN v_out;
END $$;
COMMENT ON FUNCTION public.update_practice_branding(uuid, jsonb) IS
  'W2-03 FR-BRN-01: the partner branding write path (partner_admin only). '
  'jsonb patch, allowlist name/logo_url/accent_hex/primary_hex/sign_in_text/'
  'support_contact/email_sender_name; absent key keeps the stored value, '
  'jsonb null or empty string clears it. Audit row carries patch + previous. '
  'subdomain is platform-only (platform_update_partner); report templates are '
  'the brand applied to the HTML layout, not stored files (product decision).';
REVOKE EXECUTE ON FUNCTION public.update_practice_branding(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_practice_branding(uuid, jsonb) TO authenticated;
