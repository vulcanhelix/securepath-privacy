-- ============================================================================
-- W2-02 — CLIENT ONBOARDING WIZARD DATA PLUMBING (FR-ONB-01)
-- (GitHub #26 · spec SP-SPC-PLT-001 §5.4, §6.1, §7.3 screen 11 ·
--  plan BUILD_PLAN_R1 W2-02)
-- ============================================================================
--
-- The onboarding wizard (web/app/clients/new) drives the SAME RPCs the
-- system uses — no parallel validation in the app. One signature gap
-- remained on a main chain:
--
--   client detail fields — spec §6.1 Client: legal name, trading name,
--   registration number, jurisdiction, sector, sites, headcount in scope
--   (columns exist since W0-01 000002 but no RPC writes them).
--   create_client_org gains them as trailing optional params; the first
--   seven params are the W4-05 000020 signature VERBATIM so calls written
--   for it resolve identically, and every param is optional except p_name
--   so every pre-existing call keeps working.
--
-- Region plumbing itself is 000020's, already on main: the data_regions
-- registry, the data_region_checked resolver, the client_orgs region
-- guard trigger, create_practice +p_home_region, and the 7-param
-- create_client_org whose region resolution (explicit p_data_region →
-- partner home region, fail closed) this body keeps unchanged.
--
-- Jurisdiction is validated against jurisdiction_packs for a readable
-- error (the column FK is the backstop); timezone defaults from the
-- chosen pack. Legacy columns registration_no/industry stay synced with
-- registration_number/sector (W0-01 keeps both until web code is fully
-- repointed).
-- ============================================================================

BEGIN;

-- ---------- create_client_org — +spec §6.1 details on 000020's body --------
DROP FUNCTION IF EXISTS public.create_client_org(text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.create_client_org(text, text, text, text, text, text, text);
CREATE FUNCTION public.create_client_org(
    p_name               text,
    p_registration_no    text  DEFAULT NULL,
    p_industry           text  DEFAULT NULL,
    p_contact_name       text  DEFAULT NULL,
    p_contact_email      text  DEFAULT NULL,
    p_org_scale          text  DEFAULT 'large',
    p_data_region        text  DEFAULT NULL,
    p_jurisdiction       text  DEFAULT NULL,
    p_legal_name         text  DEFAULT NULL,
    p_trading_name       text  DEFAULT NULL,
    p_sector             text  DEFAULT NULL,
    p_headcount_in_scope int   DEFAULT NULL,
    p_sites              jsonb DEFAULT NULL,
    p_timezone           text  DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; cid uuid; v_region text; v_jur text;
BEGIN
  SELECT practice_id INTO pid FROM memberships
    WHERE user_id = auth.uid() AND role = 'practice_owner';
  IF pid IS NULL THEN RAISE EXCEPTION 'only practice owners may create client instances'; END IF;
  IF p_org_scale IS NOT NULL AND p_org_scale NOT IN ('sme', 'large') THEN
    RAISE EXCEPTION 'org_scale must be sme or large';
  END IF;
  -- NFR-11: explicit param wins; else the partner's home region. No implicit
  -- platform default — a resolved region is REQUIRED (spec §6.1 Client:
  -- data region is a key field; FR-ONB-01 makes it an onboarding step).
  v_region := public.data_region_checked(p_data_region);
  IF v_region IS NULL THEN
    SELECT data_region_default INTO v_region FROM public.practices WHERE id = pid;
  END IF;
  IF v_region IS NULL THEN
    RAISE EXCEPTION 'create_client_org: no data region resolved — pass p_data_region or set the partner home region (platform_update_partner data_region_default)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.data_regions r WHERE r.code = v_region AND r.active) THEN
    RAISE EXCEPTION 'create_client_org: partner home region "%" is not an active registry region', v_region;
  END IF;
  -- jurisdiction: registry key, NULL allowed (templates filter on it — FR-ONB-03)
  v_jur := NULLIF(upper(btrim(COALESCE(p_jurisdiction, ''))), '');
  IF v_jur IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM public.jurisdiction_packs jp WHERE jp.code = v_jur) THEN
    RAISE EXCEPTION 'unknown jurisdiction "%" — allowed values are jurisdiction_packs codes', p_jurisdiction;
  END IF;
  IF p_headcount_in_scope IS NOT NULL AND p_headcount_in_scope < 0 THEN
    RAISE EXCEPTION 'headcount_in_scope cannot be negative';
  END IF;
  IF p_sites IS NOT NULL AND jsonb_typeof(p_sites) <> 'array' THEN
    RAISE EXCEPTION 'sites must be a jsonb array of {name, address} objects';
  END IF;
  INSERT INTO client_orgs
      (practice_id, name, registration_no, industry, contact_name, contact_email,
       org_scale, data_region, jurisdiction,
       legal_name, trading_name, registration_number, sector,
       headcount_in_scope, sites, timezone)
    VALUES (pid, p_name, p_registration_no, p_industry, p_contact_name, p_contact_email,
            COALESCE(p_org_scale, 'large'), v_region, v_jur,
            NULLIF(btrim(COALESCE(p_legal_name, '')), ''),
            NULLIF(btrim(COALESCE(p_trading_name, '')), ''),
            NULLIF(btrim(COALESCE(p_registration_no, '')), ''),
            NULLIF(btrim(COALESCE(p_sector, p_industry, '')), ''),
            p_headcount_in_scope, p_sites,
            COALESCE(NULLIF(btrim(p_timezone), ''),
                     (SELECT jp.timezone FROM public.jurisdiction_packs jp WHERE jp.code = v_jur)))
    RETURNING id INTO cid;
  INSERT INTO tracks (client_org_id, track_kind)
    VALUES (cid, 'privacy'), (cid, 'cyber');
  INSERT INTO billing_events (practice_id, client_org_id, event_type, detail)
    VALUES (pid, cid, 'instance.created',
            jsonb_build_object('name', p_name, 'by', auth.uid(),
                               'data_region', v_region, 'jurisdiction', v_jur));
  INSERT INTO notifications (practice_id, kind, message)
    VALUES (pid, 'billing',
            format('Client instance "%s" created — this instance is billable.', p_name));
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'client_org.created',
            jsonb_build_object('client_org', cid, 'name', p_name,
                               'org_scale', COALESCE(p_org_scale, 'large'),
                               'data_region', v_region, 'jurisdiction', v_jur));
  RETURN cid;
END $$;
COMMENT ON FUNCTION public.create_client_org(text, text, text, text, text, text, text, text, text, text, text, integer, jsonb, text) IS
  'W2-02 FR-ONB-01: W4-05''s region resolution (p_data_region → partner home, '
  'fail closed) plus the spec §6.1 client detail fields — jurisdiction '
  '(jurisdiction_packs-validated, drives FR-ONB-03 template filtering), '
  'legal/trading name, registration number, sector, sites, headcount, '
  'timezone (defaults from the jurisdiction pack). Ledger + audit rows carry '
  'region + jurisdiction.';
REVOKE EXECUTE ON FUNCTION public.create_client_org(text, text, text, text, text, text, text, text, text, text, text, integer, jsonb, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.create_client_org(text, text, text, text, text, text, text, text, text, text, text, integer, jsonb, text) TO authenticated;

COMMIT;
