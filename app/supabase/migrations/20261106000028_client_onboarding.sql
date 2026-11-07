-- ============================================================================
-- W2-02 — CLIENT ONBOARDING WIZARD DATA PLUMBING (FR-ONB-01, NFR-11)
-- (GitHub #26 · spec SP-SPC-PLT-001 §5.4, §6.1, §7.3 screen 11 ·
--  plan BUILD_PLAN_R1 W2-02)
-- ============================================================================
--
-- The onboarding wizard (web/app/clients/new) drives the SAME RPCs the
-- system uses — no parallel validation in the app. Two signature gaps
-- existed for that on a main-only chain:
--
--   (a) data-region plumbing — W4-05's 000020 (data_regions registry,
--       region resolver, create_client_org +p_data_region defaulting to
--       the partner's home region, create_practice +p_home_region) is
--       in-flight on int/wave2, not on main. The wizard needs it now:
--       FR-ONB-01 step 2 picks jurisdiction AND data region, NFR-11 makes
--       residency a creation-time decision. The 000020 objects are
--       reproduced here IDENTICALLY (same names, same bodies, same
--       resolution semantics) and written defensively (IF NOT EXISTS /
--       CREATE OR REPLACE / pg_constraint probe), so:
--         • main-only chain: everything works standalone;
--         • 000020 merged before this file (normal order — 20 < 28):
--           its objects win first, this file's identical re-assertions
--           no-op, and the extended create_client_org below cleanly
--           replaces the 7-param version (defaults keep every existing
--           call working).
--       NOT ported: the region-guard trigger + partner_branding /
--       programme_context / platform_* slices — 000020 owns them and
--       the wizard needs none of them (authenticated holds no direct
--       UPDATE on client_orgs, so the write surface stays RPC-only).
--
--   (b) client detail fields — spec §6.1 Client: legal name, trading
--       name, registration number, jurisdiction, sector, sites,
--       headcount in scope (columns exist since W0-01 000002 but no RPC
--       writes them). create_client_org gains them as trailing optional
--       params; the first seven params are the 000020 signature VERBATIM
--       so calls written for W4-05 resolve identically.
--
-- Region resolution (W4-05 semantics, unchanged): explicit p_data_region
-- wins, else the practice home region (data_region_default); unresolved
-- or unknown → fail closed. Jurisdiction is validated against
-- jurisdiction_packs for a readable error (the column FK is the
-- backstop); timezone defaults from the chosen pack. Legacy columns
-- registration_no/industry stay synced with registration_number/sector
-- (W0-01 keeps both until web code is fully repointed).
-- ============================================================================

BEGIN;

-- ---------- 1. data_regions registry (W4-05 000020 verbatim, IF NOT EXISTS) --
CREATE TABLE IF NOT EXISTS public.data_regions (
    code              text PRIMARY KEY,
    label             text NOT NULL,
    deployment_region text NOT NULL,
    active            boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.data_regions IS
  'NFR-11 region registry: codes stored on client_orgs.data_region and '
  'practices.data_region_default, resolved to a deployment region (one '
  'self-hosted deploy per region — af-south-1 SA, eu-west-2 UK in R1). '
  'Adding a region = one row + a deploy. (W2-02: identical object to '
  'in-flight W4-05 000020 — whichever migration applies first wins.)';

INSERT INTO public.data_regions (code, label, deployment_region) VALUES
  ('ZA', 'South Africa',    'af-south-1'),
  ('UK', 'United Kingdom',  'eu-west-2')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE public.data_regions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.data_regions FORCE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'data_regions'
                    AND policyname = 'data_regions_read') THEN
    CREATE POLICY data_regions_read ON public.data_regions FOR SELECT TO authenticated
      USING (true);
  END IF;
END $$;
REVOKE ALL ON public.data_regions FROM anon;
GRANT SELECT ON public.data_regions TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.data_regions FROM authenticated;

-- ---------- 2. FK — fail closed on unknown region on direct writes too ------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'client_orgs_data_region_fkey') THEN
    ALTER TABLE public.client_orgs
      ADD CONSTRAINT client_orgs_data_region_fkey
      FOREIGN KEY (data_region) REFERENCES public.data_regions(code);
  END IF;
END $$;
COMMENT ON COLUMN public.client_orgs.data_region IS
  'NFR-11: residency code from data_regions (ZA=af-south-1, UK=eu-west-2 '
  'in R1). Set at creation via create_client_org. (W4-05 000020 adds the '
  'post-creation immutability trigger when it lands.)';

-- ---------- 3. region resolver (W4-05 000020 verbatim) -----------------------
CREATE OR REPLACE FUNCTION public.data_region_checked(p_code text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v text := NULLIF(upper(btrim(COALESCE(p_code, ''))), '');
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.data_regions r
                  WHERE r.code = v AND r.active) THEN
    RAISE EXCEPTION 'unknown data region "%" — allowed values are the active data_regions codes', p_code;
  END IF;
  RETURN v;
END $$;
COMMENT ON FUNCTION public.data_region_checked(text) IS
  'NFR-11: normalise (trim/upper) + registry-validate a region code. Returns '
  'NULL for empty input; raises on unknown/inactive — the fail-closed check '
  'shared by every region-accepting RPC.';
REVOKE EXECUTE ON FUNCTION public.data_region_checked(text) FROM anon, public, authenticated;

-- ---------- 4. create_practice — +p_home_region (W4-05 000020 verbatim) ------
DROP FUNCTION IF EXISTS public.create_practice(text);
CREATE FUNCTION public.create_practice(p_name text, p_home_region text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; v_region text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF EXISTS (SELECT 1 FROM public.role_assignments
             WHERE user_id = auth.uid() AND level IN ('partner','client')
               AND start_date <= CURRENT_DATE
               AND (end_date IS NULL OR end_date > CURRENT_DATE)) THEN
    RAISE EXCEPTION 'user already belongs to a practice';
  END IF;
  v_region := public.data_region_checked(p_home_region);
  INSERT INTO practices (name, data_region_default) VALUES (p_name, v_region) RETURNING id INTO pid;
  INSERT INTO users (id, email)
    SELECT id, email FROM auth.users WHERE id = auth.uid()
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id)
    VALUES (auth.uid(), 'partner', 'partner_admin', 'partner', pid);
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'practice.created',
            jsonb_build_object('data_region_default', v_region));
  RETURN pid;
END $$;
COMMENT ON FUNCTION public.create_practice(text, text) IS
  '+p_home_region — optional partner home region (NFR-11), validated '
  'against data_regions; feeds create_client_org''s default. NULL allowed: '
  'the partner then must pass a region on each client create.';
REVOKE EXECUTE ON FUNCTION public.create_practice(text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.create_practice(text, text) TO authenticated;

-- ---------- 5. create_client_org — +p_data_region + spec §6.1 details --------
-- First seven params = W4-05 000020 signature verbatim; the remaining are
-- the §6.1 Client fields the onboarding wizard collects. All named params,
-- all optional except p_name — every pre-existing call keeps working.
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
