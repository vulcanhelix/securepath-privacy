-- ============================================================================
-- W4-05 — PER-CLIENT DATA-REGION PLUMBING (NFR-11)
-- (GitHub #52 · spec SP-SPC-PLT-001 §5.4, §6.1, §12.3 NFR-11, FR-ONB-01 ·
--  plan BUILD_PLAN_R1 W4-05)
-- ============================================================================
--
-- William's call: self-hosted, ONE DEPLOY PER REGION — af-south-1 (South
-- Africa) and eu-west-2 (United Kingdom) in release 1; HostAfrica is
-- dev/staging only. The region is chosen at client onboarding (FR-ONB-01
-- step: client details, jurisdiction AND data region).
--
-- What already exists (W0-01 20261105000002): free-text columns
-- client_orgs.data_region, practices.data_region_default and
-- jurisdiction_packs.default_data_region. This migration turns them into
-- plumbing:
--
--   (a) data_regions registry — code ('ZA'|'UK'), display label and the
--       physical deployment region. The column values stay 'ZA'/'UK' —
--       every existing writer (fixtures, web partner form, jurisdiction
--       packs) already uses those codes; the registry is where the code
--       resolves to a deploy. FK'd on all three columns: an unknown
--       region fails closed everywhere, RPCs and direct writes alike.
--
--   (b) immutability — BEFORE INSERT OR UPDATE trigger on client_orgs.
--       INSERT: any non-NULL region must be an active registry code.
--       UPDATE: a region change is allowed only while the client is a
--       shell — once ANY tenant work-product row exists the change is
--       rejected for EVERYONE including supabase_admin: a region change
--       at that point is a data migration between deploys, not a flag
--       flip. The guard enumerates EVERY first-order client_org_id-keyed
--       work-product table (see the function body): programmes, the
--       client-scope pipeline artifacts (assessment_sessions/reports,
--       documents(+links), tasks, policies, manuals, monthly_reports,
--       awareness_cohorts) AND the client-scope registers that fill up
--       before any programme can exist (designations, external_providers,
--       operational_records, training_records, controlled_documents,
--       support_access_requests/grants). Client-shell scaffolding
--       deliberately does NOT lock — tracks + billing_events are written
--       inside create_client_org itself, and memberships/invites/
--       consultant_assignments/role_assignments are onboarding+access
--       rows a shell recreation re-issues; counting any of them would
--       lock the region at birth.
--
--   (c) creation paths — create_client_org gains p_data_region (optional,
--       defaults to the practice's home region = practices.data_region_
--       default; unresolved or unknown → fail closed with a clear error).
--       create_practice gains p_home_region (optional partner self-
--       onboarding home region). platform_create_partner /
--       platform_update_partner now VALIDATE data_region_default against
--       the registry (was free text) and carry it in their audit rows.
--
--   (d) reads — partner_branding returns the client's region code + label
--       + deployment region; programme_context (defined here in full —
--       see note) carries client.data_region + label; platform_list_
--       clients gains a data_region column so ops can route by region.
--       Regions are exposed as LABELS: nothing in this schema moves data
--       between deploys.
--
-- NOTE — programme_context: the W4-D version lives in migration 000018 on
-- the in-flight claude/w4-d-fixes branch (PR #101), not yet on main. The
-- definition below is that body VERBATIM plus the region keys, applied
-- with CREATE OR REPLACE. File order guarantees the final state on every
-- migration-ordered apply (fresh CI DB: 000018 then 000020 — region wins;
-- DBs that already ran 000018 get the region version here). If 000018 is
-- ever applied AFTER this file on an existing DB, re-apply this file —
-- flagged for the reviewer.
--
-- FAIL-CLOSED RULE: every new write path validates the region against the
-- registry BEFORE writing; the FKs are the backstop for direct writes;
-- the trigger re-validates on every INSERT/UPDATE of client_orgs.
-- ============================================================================

BEGIN;

-- ---------- 1. data_regions registry ----------
-- One row per deployable region. `code` is the value stored on practices /
-- client_orgs / jurisdiction_packs; `deployment_region` is where that
-- code's stack lives (William: one self-hosted deploy per region).
CREATE TABLE public.data_regions (
    code              text PRIMARY KEY,          -- 'ZA' | 'UK' in R1
    label             text NOT NULL,             -- 'South Africa' | 'United Kingdom'
    deployment_region text NOT NULL,             -- 'af-south-1' | 'eu-west-2'
    active            boolean NOT NULL DEFAULT true,  -- new writes require active
    created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.data_regions IS
  'W4-05 NFR-11 region registry: the codes stored on client_orgs.data_region '
  'and practices.data_region_default, resolved to a deployment region '
  '(one self-hosted deploy per region — af-south-1 SA, eu-west-2 UK in R1; '
  'HostAfrica is dev/staging only). Adding a region = one row + a deploy.';
COMMENT ON COLUMN public.data_regions.deployment_region IS
  'Physical deploy holding clients of this region — informational label only; '
  'nothing replicates data between deploys (region change = migration).';

INSERT INTO public.data_regions (code, label, deployment_region) VALUES
  ('ZA', 'South Africa',    'af-south-1'),
  ('UK', 'United Kingdom',  'eu-west-2');

ALTER TABLE public.data_regions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.data_regions FORCE ROW LEVEL SECURITY;
-- labels are not tenant data: every authenticated user reads the registry
-- (frameworks_read precedent). No write policy — registry changes are ops
-- (supabase_admin) only.
CREATE POLICY data_regions_read ON public.data_regions FOR SELECT TO authenticated
  USING (true);
REVOKE ALL ON public.data_regions FROM anon;
GRANT SELECT ON public.data_regions TO authenticated;
-- the image's default privileges hand ALL on new public tables to
-- authenticated — take writes back: the registry is ops-owned (NFR-11 region
-- additions are a deploy, not a tenant action)
REVOKE INSERT, UPDATE, DELETE ON public.data_regions FROM authenticated;

-- ---------- 2. FKs — fail closed on unknown region, every write path ----------
ALTER TABLE public.client_orgs
  ADD CONSTRAINT client_orgs_data_region_fkey
  FOREIGN KEY (data_region) REFERENCES public.data_regions(code);
ALTER TABLE public.practices
  ADD CONSTRAINT practices_data_region_default_fkey
  FOREIGN KEY (data_region_default) REFERENCES public.data_regions(code);
ALTER TABLE public.jurisdiction_packs
  ADD CONSTRAINT jurisdiction_packs_default_data_region_fkey
  FOREIGN KEY (default_data_region) REFERENCES public.data_regions(code);
COMMENT ON COLUMN public.client_orgs.data_region IS
  'W4-05 NFR-11: residency code from data_regions (ZA=af-south-1, UK=eu-west-2 '
  'in R1). Set at creation via create_client_org; correctable only while the '
  'client is a shell — locked by trigger once any tenant data exists.';

-- ---------- 3. region guard — validates on INSERT, locks on UPDATE ----------
CREATE OR REPLACE FUNCTION public.trg_client_org_data_region() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- fail closed: any region written must be an ACTIVE registry code.
  -- (FK proves the code exists; this also rejects retired codes and gives
  -- a readable error on both paths.)
  IF NEW.data_region IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM public.data_regions r
       WHERE r.code = NEW.data_region AND r.active) THEN
    RAISE EXCEPTION 'client_orgs.data_region: unknown or inactive region "%" — see data_regions registry',
      NEW.data_region;
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.data_region IS DISTINCT FROM OLD.data_region THEN
    -- Locked once real work exists. A region move at that point is a data
    -- migration between deploys (export → provision → import), never a
    -- column flip.
    --
    -- The list below is the COMPLETE inventory of first-order tenant
    -- tables — every live table with a client_org_id column holding client
    -- work product (verified against the migrations 20260723→20261106).
    -- It covers programme data, the client-scope pipeline artifacts AND
    -- the client-scope registers that exist before any programme can run
    -- — a client with only designations / training / controlled docs /
    -- support rows must be just as locked as one with programmes.
    --
    -- Descendant rows are covered through NOT NULL parent FKs and are
    -- deliberately not re-listed: phases→…→programmes, assessment_
    -- responses/scores→assessment_sessions, awareness_respondents/
    -- responses→awareness_cohorts, controlled_document_activities→
    -- controlled_documents, checklist_item_completions→checklist_
    -- instances→programmes, monthly_snapshots/programme_reports/
    -- register_items/evidence_*/raid_items/decisions/maintenance_task_*/
    -- weekly_logs/kpis→programmes, stage_transitions→tracks (below).
    --
    -- Deliberately EXCLUDED — client-shell scaffolding, not work product:
    --   tracks              two rows written inside create_client_org
    --   billing_events      'instance.created' written in the same call
    --   memberships         client_admin membership lands on invite
    --   invites             accept — onboarding access, re-issued with
    --   consultant_assignments  a recreated shell; locking them would
    --   role_assignments    make the region uncorrectable in the normal
    --                       onboarding flow (client-scope role_assignments
    --                       are polymorphic scope_id rows anyway)
    --   notification_events ops outbox — client scope is a jsonb claim
    --                       (scope->>'client_org_id'), not a column
    --   assessments         retired legacy table — 20260807000004 drops it
    --                       when empty; referencing a possibly-absent
    --                       table would break every client write on
    --                       fresh DBs (its successor assessment_sessions
    --                       IS listed).
    IF EXISTS (SELECT 1 FROM public.programmes              x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.assessment_sessions  x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.assessment_reports   x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.awareness_cohorts    x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.documents            x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.document_links       x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.tasks                x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.policies             x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.manuals              x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.monthly_reports      x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.designations         x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.external_providers   x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.operational_records  x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.training_records     x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.controlled_documents x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.support_access_requests x WHERE x.client_org_id = OLD.id)
       OR EXISTS (SELECT 1 FROM public.support_access_grants   x WHERE x.client_org_id = OLD.id)
    THEN
      RAISE EXCEPTION 'client_orgs.data_region for client % is locked — tenant data exists; a region change is a data migration, not a flag flip',
        OLD.id;
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_client_org_data_region() IS
  'W4-05 NFR-11: client_orgs region guard — INSERT/UPDATE must name an '
  'active data_regions code; UPDATE may not change data_region once the '
  'client holds any tenant work-product row (every first-order '
  'client_org_id-keyed table is enumerated in the body; shell scaffolding '
  '- tracks/billing/memberships/invites/assignments - does not lock).';

DROP TRIGGER IF EXISTS client_org_data_region_guard ON public.client_orgs;
CREATE TRIGGER client_org_data_region_guard
  BEFORE INSERT OR UPDATE ON public.client_orgs
  FOR EACH ROW EXECUTE FUNCTION public.trg_client_org_data_region();

-- ---------- 4. internal resolver (not granted — RPCs call it) ----------
CREATE FUNCTION public.data_region_checked(p_code text) RETURNS text
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
  'W4-05: normalise (trim/upper) + registry-validate a region code. Returns '
  'NULL for empty input; raises on unknown/inactive — the fail-closed check '
  'shared by every region-accepting RPC.';
REVOKE EXECUTE ON FUNCTION public.data_region_checked(text) FROM anon, public, authenticated;

-- ---------- 5. create_client_org — +p_data_region (defaults to home) ----------
DROP FUNCTION IF EXISTS public.create_client_org(text, text, text, text, text, text);
CREATE FUNCTION public.create_client_org(
    p_name text, p_registration_no text DEFAULT NULL, p_industry text DEFAULT NULL,
    p_contact_name text DEFAULT NULL, p_contact_email text DEFAULT NULL,
    p_org_scale text DEFAULT 'large', p_data_region text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; cid uuid; v_region text;
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
  INSERT INTO client_orgs (practice_id, name, registration_no, industry,
                           contact_name, contact_email, org_scale, data_region)
    VALUES (pid, p_name, p_registration_no, p_industry,
            p_contact_name, p_contact_email, COALESCE(p_org_scale, 'large'), v_region)
    RETURNING id INTO cid;
  INSERT INTO tracks (client_org_id, track_kind)
    VALUES (cid, 'privacy'), (cid, 'cyber');
  INSERT INTO billing_events (practice_id, client_org_id, event_type, detail)
    VALUES (pid, cid, 'instance.created',
            jsonb_build_object('name', p_name, 'by', auth.uid(), 'data_region', v_region));
  INSERT INTO notifications (practice_id, kind, message)
    VALUES (pid, 'billing',
            format('Client instance "%s" created — this instance is billable.', p_name));
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'client_org.created',
            jsonb_build_object('client_org', cid, 'name', p_name,
                               'org_scale', COALESCE(p_org_scale, 'large'),
                               'data_region', v_region));
  RETURN cid;
END $$;
COMMENT ON FUNCTION public.create_client_org(text, text, text, text, text, text, text) IS
  'W4-05: +p_data_region (NFR-11). Region resolves param → practice home '
  'region (data_region_default); both validated against data_regions, '
  'unresolved or unknown fails closed. Region lands in billing + audit rows.';
REVOKE EXECUTE ON FUNCTION public.create_client_org(text, text, text, text, text, text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.create_client_org(text, text, text, text, text, text, text) TO authenticated;

-- ---------- 6. create_practice — +p_home_region (partner self-onboarding) --
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
  'W4-05: +p_home_region — optional partner home region (NFR-11), validated '
  'against data_regions; feeds create_client_org''s default. NULL allowed: '
  'the partner then must pass a region on each client create.';
REVOKE EXECUTE ON FUNCTION public.create_practice(text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.create_practice(text, text) TO authenticated;

-- ---------- 7. platform_create_partner — registry-validated home region ----
-- Same signature and behaviour as 000015; the free-text insert becomes a
-- validated code and the audit row records it.
CREATE OR REPLACE FUNCTION public.platform_create_partner(
    p_name text, p_type text, p_country text,
    p_subdomain text DEFAULT NULL,
    p_primary_contact text DEFAULT NULL,
    p_data_region_default text DEFAULT NULL,
    p_admin_email text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_sub text; v_tok uuid; v_email text; v_region text;
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
  v_region := public.data_region_checked(p_data_region_default);  -- W4-05: fail closed

  INSERT INTO public.practices
      (name, type, country, subdomain, primary_contact, data_region_default)
  VALUES (btrim(p_name), p_type, upper(btrim(p_country)), v_sub,
          NULLIF(btrim(COALESCE(p_primary_contact, '')), ''),
          v_region)
  RETURNING id INTO v_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_id, 'partner.created',
          jsonb_build_object('name', btrim(p_name), 'type', p_type,
                             'country', upper(btrim(p_country)), 'subdomain', v_sub,
                             'data_region_default', v_region,
                             'admin_invite', v_email IS NOT NULL));

  -- optional first partner_admin — the existing invite mechanism
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
  'W2-14 FR-PLT-01 + W4-05: p_data_region_default is the partner HOME REGION '
  '— now validated against data_regions (unknown fails closed) and recorded '
  'in the partner.created audit detail.';

-- ---------- 8. platform_update_partner — region field validated ------------
CREATE OR REPLACE FUNCTION public.platform_update_partner(p_partner uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old public.practices%ROWTYPE; v_key text; v_sub text;
        v_region text; v_region_seen boolean := false;
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
  IF p_payload ? 'data_region_default' THEN  -- W4-05: fail closed on unknown region
    v_region_seen := true;
    v_region := public.data_region_checked(p_payload->>'data_region_default');
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
    data_region_default = CASE WHEN v_region_seen THEN v_region ELSE data_region_default END
  WHERE id = p_partner;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), p_partner, 'partner.updated',
          jsonb_build_object('patch', p_payload, 'previous', v_prev));
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'platform_update_partner: subdomain "%" is already taken', v_sub;
END $$;
COMMENT ON FUNCTION public.platform_update_partner(uuid, jsonb) IS
  'W2-14 FR-PLT-01 + W4-05: data_region_default values are registry-checked '
  '(unknown/inactive rejected; NULL still clears the home region). Audit row '
  'carries patch + previous values.';

-- ---------- 9. reads — region surfaced as label (no data movement) ---------

-- 9a. partner_branding + client region slice
CREATE OR REPLACE FUNCTION public.partner_branding(p_client_org uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_practice uuid; v_row jsonb;
BEGIN
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
                   WHERE l.partner_id = p.id AND l.status = 'active'
                   LIMIT 1), true),
      -- W4-05 NFR-11: where THIS client's data lives — a label, not a route.
      'data_region',            c.data_region,
      'data_region_label',      dr.label,
      'data_region_deployment', dr.deployment_region
    ) INTO v_row
  FROM public.practices p
  JOIN public.client_orgs c ON c.id = p_client_org
  LEFT JOIN public.data_regions dr ON dr.code = c.data_region
  WHERE p.id = v_practice;
  RETURN v_row;
END $$;
COMMENT ON FUNCTION public.partner_branding(uuid) IS
  'Branding slice for the shell (FR-BRN) + W4-05 client data_region code/'
  'label/deployment (NFR-11 — label only, no data movement). Guarded by '
  'allowed_client_orgs / partner / platform roles; attribution_display = '
  'per-licence FR-BRN-05 flag, default true.';
REVOKE EXECUTE ON FUNCTION public.partner_branding(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.partner_branding(uuid) TO authenticated;

-- 9b. programme_context — the W4-D (000018) body VERBATIM + client region
-- keys; see the file-header NOTE on ordering.
CREATE OR REPLACE FUNCTION public.programme_context(p_programme uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row jsonb;
BEGIN
  -- A definer function bypasses RLS, so the scope guard lives in the body
  -- (the established hard rule). auth.uid() NULL = the service/migration
  -- path and runs free (W0-02 convention).
  IF auth.uid() IS NOT NULL
     AND p_programme NOT IN (SELECT public.allowed_programmes()) THEN
    RETURN NULL;
  END IF;
  SELECT jsonb_build_object(
      'programme', jsonb_build_object(
        'id',             p.id,
        'name',           p.name,
        'status',         p.status,
        'phase',          p.phase,
        'start_date',     p.start_date,
        'total_weeks',    p.total_weeks,
        'programme_rag',  p.programme_rag,
        'programme_lead', p.programme_lead,
        'client_org_id',  p.client_org_id),
      'client', jsonb_build_object(
        'id',           c.id,
        'name',         c.name,
        'practice_id',  c.practice_id,
        'jurisdiction', c.jurisdiction,
        'legal_name',   c.legal_name,
        'trading_name', c.trading_name,
        'data_region',        c.data_region,      -- W4-05 NFR-11
        'data_region_label',  dr.label)
    ) INTO v_row
    FROM public.programmes p
    JOIN public.client_orgs c ON c.id = p.client_org_id
    LEFT JOIN public.data_regions dr ON dr.code = c.data_region
   WHERE p.id = p_programme;
  RETURN v_row;
END $$;
COMMENT ON FUNCTION public.programme_context(uuid) IS
  'W4-D2 + W4-05: programme + owning-client slice for the app shell, now '
  'carrying client data_region + label (NFR-11). DEFINER because programme/'
  'workstream-scope callers see the programme but not client_orgs; guarded '
  'by allowed_programmes() so nothing extra leaks.';
REVOKE EXECUTE ON FUNCTION public.programme_context(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.programme_context(uuid) TO authenticated;

-- 9c. platform_list_clients + data_region — region is how ops routes a
-- support request to the right deploy; it is a LABEL in the directory.
DROP FUNCTION IF EXISTS public.platform_list_clients(uuid);
CREATE FUNCTION public.platform_list_clients(p_partner uuid DEFAULT NULL)
RETURNS TABLE(client_org_id uuid, client_name text, partner_id uuid,
              partner_name text, jurisdiction text, data_region text,
              created_at timestamptz,
              programmes_total int, programmes_open int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin','support']) THEN
    RAISE EXCEPTION 'platform_list_clients: platform_admin or support required';
  END IF;
  RETURN QUERY
    SELECT co.id, co.name, p.id, p.name, co.jurisdiction, co.data_region, co.created_at,
           (SELECT count(*)::int FROM public.programmes pr WHERE pr.client_org_id = co.id),
           (SELECT count(*)::int FROM public.programmes pr
             WHERE pr.client_org_id = co.id AND pr.status <> 'closed')
    FROM public.client_orgs co
    JOIN public.practices p ON p.id = co.practice_id
    WHERE p_partner IS NULL OR co.practice_id = p_partner
    ORDER BY p.name, co.name;
END $$;
COMMENT ON FUNCTION public.platform_list_clients(uuid) IS
  'W2-14 + W4-05: client DIRECTORY for platform staff — id, name, '
  'jurisdiction, data_region label, programme counts. No client content '
  '(NFR-04): content needs a support grant.';
REVOKE EXECUTE ON FUNCTION public.platform_list_clients(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.platform_list_clients(uuid) TO authenticated;

COMMIT;
