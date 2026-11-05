-- ============================================================================
-- W0-01 — PLATFORM TIER + ENTITY ALTERs
-- (GitHub #10 · spec SP-SPC-PLT-001 §4, §5.4, §6.1 · plan BUILD_PLAN_R1 §3 W0-01)
-- ============================================================================
--
-- Builds on W0-00 (role_assignments + predicate catalogue). Creates:
--   jurisdiction_packs   §5.4 — values that change with the law (structure only;
--                        SecurePath authors + verifies content later, W5-02)
--   licences             §6.1 + FR-BRN-05 per-licence SecurePath-attribution flag
--   designations         §6.1 + FR-ACC-03 statutory designations (incl. named
--                        alternate for FR-ACC-02)
--   support_access_grants §6.1 + NFR-04 / FR-PLT-04 — the client-approved,
--                        time-boxed, logged record of SecurePath support access
-- and ALTERs client_orgs / practices / users per the §6.1 entity lists.
--
-- DECISIONS (spec ambiguities resolved here — flagged for review):
--
-- 1. SUPPORT ACCESS PATH (NFR-04). W0-00 designed the mechanism: "a platform
--    grant may also be scoped (scope_type client + scope_id) — that is how
--    spec §4.1 support is expressed; the support access path itself lands in
--    W0-01". allowed_client_orgs() v3 below adds branch (e): a client is
--    visible to a platform user only while BOTH hold —
--       i)  an active platform-level role_assignment at client scope (the
--           uniform access mechanism: role_assignments stays the single
--           source of truth for who can see what), AND
--      ii)  an approved, in-window, unrevoked support_access_grants row (the
--           client's approval + precise timestamptz window — "with client
--           approval, time limited, logged" in one auditable row).
--    Neither alone opens access: a bare assignment has no recorded approval;
--    a bare grant does not bypass the assignment catalogue. The W4-01
--    request→approve RPC must create both rows in one transaction.
--    Effect: support access is READ-level. Every existing write gate checks
--    partner/client roles (current_role_name()/T1 role gates), which a
--    platform-only user fails — the grant widens visibility, not writability.
--
-- 2. DUPLICATE-ISH COLUMNS ON client_orgs. The onboarding-era schema already
--    carries `registration_no` and `industry` (read by live web code:
--    clients/new, clients/route.ts, report compile). Spec §6.1 wants
--    "registration number" and "sector". Per the mission's explicit column
--    list and the additive-only rule, this migration ADDS spec-named
--    `registration_number` + `sector` and backfills them from the legacy
--    columns. The legacy columns stay (still read by web code); a later
--    consolidation session should repoint reads and drop them. No sync
--    trigger — deliberate: which side wins a both-columns update is
--    ambiguous, and web code migrates to the new names in W2 anyway.
--
-- 3. practices.primary_hex added beyond the mission list: FR-BRN-01 requires
--    "primary and accent colours"; only accent_hex existed.
--
-- 4. licences: NULL client_limit/programme_limit = uncapped (e.g.
--    securepath_direct); ends_on NULL = open-ended term. Partial unique index
--    enforces at most ONE active licence per partner (spec speaks of "the
--    partner's licence" singular — FR-LIC-01). Statuses: draft → active →
--    suspended ↔ active → terminated. 'expired' is NOT a status — expiry is
--    derived from ends_on, never stored (no clock dependency in data).
--
-- 5. designations.end_date: NULL = current holder. Succession closes the old
--    row (sets end_date) and inserts a new one — keeps history for the audit
--    trail without a separate table. Named alternates (FR-ACC-02) may be
--    plural; singularity per role is a business rule for the RPC layer, not
--    enforced here (DIO/deputy roles can legitimately be multiple).
--    OPEN QUESTION (spec §FR-ACC-03 note): in SA "a partner organisation is
--    recorded as providing DIO support, not as holding the designation" —
--    awaiting confirmation vs Information Regulator guidance; no org column
--    added yet (person stays NOT NULL — spec says "named individuals").
--
-- 6. support_access_grants rows are APPROVED grants only: approved_by and the
--    window are NOT NULL; a pending-request flow (if wanted) is a W4-01
--    schema addition. revoked_at added (not in §6.1 field list) — a grant the
--    client wishes to end early must be terminable; revocation is recorded,
--    not deleted (NFR-08-style: the row is the audit record).
--
-- 7. users."MFA status" maps to auth.mfa_factors (GoTrue) — NOT a new column:
--    a mirrored column would drift from the real factor state. Middleware
--    already enforces aal2; mfa status is read from GoTrue when needed.
--    users.last_sign_in is app-maintained (GoTrue keeps auth.users
--    .last_sign_in_at internally; app code stamps this column on sign-in).
--
-- 8. practices.primary_contact and practices.support_contact are free TEXT
--    (name/email/phone as entered), not user FKs — contacts may be external
--    people or mailboxes; flag if the platform-admin UI needs a user ref.
--
-- 9. RLS — every new table: ENABLE + FORCE. All policies name their W0-00
--    predicate. Writes to licences / jurisdiction_packs / support_access_
--    grants go through future SECURITY DEFINER RPCs (W1-07 licence issue,
--    W2-14 platform admin, W4-01 grant flow, W5-02 pack editor) — no
--    authenticated INSERT/UPDATE/DELETE policy or table grant exists, so the
--    only write paths are definer functions that must call the predicate
--    catalogue (hard rule). designations follows policy template T1.
--
-- LEGAL-PERIOD RULE (FR-TPL-08): no statutory value is stored anywhere in
-- this migration — deadline_params keys are seeded with NULLs; SecurePath
-- fills them via the pack editor after primary-source verification.
-- ============================================================================

BEGIN;

-- ---------- 1. jurisdiction_packs (spec §5.4) ----------
-- One row per jurisdiction; `code` is the key referenced by clients and
-- templates. `version` is bumped by the pack editor on each publication;
-- 0 = unverified structure shell (no legal content yet).
CREATE TABLE public.jurisdiction_packs (
    code                text PRIMARY KEY,              -- e.g. 'ZA','UK'
    version             int  NOT NULL DEFAULT 0,
    role_labels         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- key → display label
    regulator_name      text,
    deadline_params     jsonb NOT NULL DEFAULT '{}'::jsonb,  -- all legal periods live here (FR-TPL-08)
    public_holidays     jsonb NOT NULL DEFAULT '[]'::jsonb,  -- [{date, name}, …]
    formats             jsonb NOT NULL DEFAULT '{}'::jsonb,  -- date/number/currency conventions
    default_data_region text,                          -- NFR-11 default residency
    timezone            text,                          -- IANA zone for business-day calcs (NFR-10)
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.jurisdiction_packs IS
  'Spec §5.4 jurisdiction pack: role labels, regulator, deadline parameters, '
  'holiday calendar, formats, default data region. Structure-only shells for '
  'ZA/UK; SecurePath authors + verifies values via the editor (W5-02). '
  'FR-TPL-08: every legal period lives in deadline_params, never in code.';
COMMENT ON COLUMN public.jurisdiction_packs.deadline_params IS
  'Named legal parameters: e.g. data_subject_request.response_period_days, '
  'breach_notification.regulator_period_days. NULLs until verified content '
  'is entered; rules code reads these, never literals.';

-- SHELL rows — structure only, no verified legal values (version 0).
-- Key skeletons document the intended shape for the editor; all values NULL.
INSERT INTO public.jurisdiction_packs
    (code, version, role_labels, regulator_name, deadline_params,
     public_holidays, formats, default_data_region, timezone)
VALUES
  ('ZA', 0,
   '{"accountable_officer": null, "deputy_accountable_officer": null, "dpo": null,
     "programme_lead": null, "management_representative": null}'::jsonb,
   NULL,
   '{"data_subject_request": {"response_period_days": null, "extension_period_days": null},
     "breach_notification": {"regulator_period_days": null, "data_subject_period_days": null}}'::jsonb,
   '[]'::jsonb,
   '{"date_format": null, "currency_code": null, "number_grouping": null, "week_start": null}'::jsonb,
   'ZA', 'Africa/Johannesburg'),
  ('UK', 0,
   '{"accountable_officer": null, "deputy_accountable_officer": null, "dpo": null,
     "programme_lead": null, "management_representative": null}'::jsonb,
   NULL,
   '{"data_subject_request": {"response_period_days": null, "extension_period_days": null},
     "breach_notification": {"regulator_period_days": null, "data_subject_period_days": null}}'::jsonb,
   '[]'::jsonb,
   '{"date_format": null, "currency_code": null, "number_grouping": null, "week_start": null}'::jsonb,
   'UK', 'Europe/London');

-- ---------- 2. licences (spec §6.1, FR-PLT-02, FR-BRN-05) ----------
CREATE TABLE public.licences (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id          uuid NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
    plan                text NOT NULL,
    client_limit        int  CHECK (client_limit IS NULL OR client_limit >= 0),     -- NULL = uncapped
    programme_limit     int  CHECK (programme_limit IS NULL OR programme_limit >= 0), -- NULL = uncapped
    starts_on           date NOT NULL,
    ends_on             date,                          -- NULL = open-ended term
    status              text NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft','active','suspended','terminated')),
    attribution_display boolean NOT NULL DEFAULT true, -- FR-BRN-05: per-licence SecurePath attribution line
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (ends_on IS NULL OR ends_on >= starts_on)
);
COMMENT ON TABLE public.licences IS
  'Spec §6.1 licence: plan, client/programme caps, term, status. Issued and '
  'changed by platform_admin via RPC (W1-07/W2-14). usage is calculated, '
  'never stored. attribution_display = FR-BRN-05 per-licence SecurePath '
  'attribution flag, set by SecurePath only.';
COMMENT ON COLUMN public.licences.status IS
  'draft→active→suspended↔active→terminated. Expiry is derived from ends_on; '
  'an ''expired'' status is deliberately absent.';

CREATE INDEX licences_partner_idx ON public.licences (partner_id);
-- at most one ACTIVE licence per partner
CREATE UNIQUE INDEX licences_one_active ON public.licences (partner_id)
  WHERE status = 'active';

-- ---------- 3. designations (spec §6.1, FR-ACC-02/03) ----------
CREATE TABLE public.designations (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id        uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    role                 text NOT NULL CHECK (role IN
                           ('information_officer','deputy_information_officer',
                            'dpo','named_alternate')),
    person               uuid NOT NULL REFERENCES public.users(id),
    date_designated      date NOT NULL,
    end_date             date,                    -- NULL = current holder
    evidence_document_id uuid REFERENCES public.documents(id),  -- appointment evidence (immutable docs)
    registration_ref     text,                    -- e.g. regulator registration reference
    created_at           timestamptz NOT NULL DEFAULT now(),
    CHECK (end_date IS NULL OR end_date >= date_designated)
);
COMMENT ON TABLE public.designations IS
  'Spec §6.1 + FR-ACC-03 statutory designations: named individuals, '
  'designation date, evidence of appointment, regulator reference. '
  'named_alternate supports FR-ACC-02 (alternate may close register items / '
  'record breach decisions). end_date NULL = current; succession closes the '
  'old row and inserts a new one. Policy template T1 (+ T5 consumers read '
  'person/role/end_date).';

CREATE INDEX designations_client_idx ON public.designations (client_org_id);
CREATE INDEX designations_person_idx ON public.designations (person);

-- ---------- 4. support_access_grants (spec §6.1, NFR-04, FR-PLT-04) ----------
CREATE TABLE public.support_access_grants (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id      uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    securepath_user_id uuid NOT NULL REFERENCES public.users(id),
    reason             text NOT NULL,
    approved_by        uuid NOT NULL REFERENCES public.users(id),
    starts_at          timestamptz NOT NULL DEFAULT now(),
    expires_at         timestamptz NOT NULL,
    revoked_at         timestamptz,                -- early end by client/platform; row kept as record
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (expires_at > starts_at)
);
COMMENT ON TABLE public.support_access_grants IS
  'Spec §6.1 + NFR-04 + FR-PLT-04: SecurePath staff have no standing access to '
  'client data; access only through an approved, time-boxed grant recorded '
  'here. Rows are approved grants only (approved_by + window NOT NULL). '
  'Effective only while backed by an active platform client-scope '
  'role_assignment — see allowed_client_orgs() branch (e). Visible to the '
  'client (FR-PLT-04 audit visibility); written only by definer RPC (W4-01).';

CREATE INDEX support_access_grants_client_idx ON public.support_access_grants (client_org_id);
CREATE INDEX support_access_grants_user_idx   ON public.support_access_grants (securepath_user_id);

-- ---------- 5. allowed_client_orgs v3 — the support access path ----------
-- Identical to v2 plus branch (e). Existing users see identical results
-- (no platform user holds a client-scope assignment + grant yet).
CREATE OR REPLACE FUNCTION public.allowed_client_orgs() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  -- a) partner-scope admin / read-only: every client of that partner
  SELECT co.id
  FROM public.role_assignments ra
  JOIN public.client_orgs co ON co.practice_id = ra.scope_id
  WHERE ra.user_id = auth.uid() AND ra.level = 'partner' AND ra.scope_type = 'partner'
    AND ra.role IN ('partner_admin','read_only')
    AND ra.start_date <= CURRENT_DATE
    AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
  UNION
  -- b) a partner-level role granted at client scope grants exactly that client
  SELECT ra.scope_id
  FROM public.role_assignments ra
  WHERE ra.user_id = auth.uid() AND ra.level = 'partner' AND ra.scope_type = 'client'
    AND ra.start_date <= CURRENT_DATE
    AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
  UNION
  -- c) legacy consultant matrix — only while the caller is an ACTIVE
  --    partner-scope partner_consultant
  SELECT ca.client_org_id
  FROM public.consultant_assignments ca
  WHERE ca.user_id = auth.uid()
    AND EXISTS (SELECT 1 FROM public.role_assignments ra
                WHERE ra.user_id = ca.user_id AND ra.level = 'partner'
                  AND ra.scope_type = 'partner' AND ra.role = 'partner_consultant'
                  AND ra.start_date <= CURRENT_DATE
                  AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE))
  UNION
  -- d) client-level roles grant their scope client
  SELECT ra.scope_id
  FROM public.role_assignments ra
  WHERE ra.user_id = auth.uid() AND ra.level = 'client' AND ra.scope_type = 'client'
    AND ra.start_date <= CURRENT_DATE
    AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
  UNION
  -- e) NFR-04 support path: caller holds an ACTIVE platform-level assignment
  --    at client scope AND an approved, in-window, unrevoked grant names them
  --    for that client. Both required — assignment = access mechanism,
  --    grant = recorded client approval + precise window.
  SELECT ra.scope_id
  FROM public.role_assignments ra
  WHERE ra.user_id = auth.uid() AND ra.level = 'platform' AND ra.scope_type = 'client'
    AND ra.start_date <= CURRENT_DATE
    AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
    AND EXISTS (SELECT 1 FROM public.support_access_grants sag
                WHERE sag.client_org_id = ra.scope_id
                  AND sag.securepath_user_id = ra.user_id
                  AND sag.starts_at <= now() AND sag.expires_at > now()
                  AND sag.revoked_at IS NULL)
$$;
COMMENT ON FUNCTION public.allowed_client_orgs() IS
  'W0-01 v3: v2 + branch (e) — platform client-scope assignments backed by '
  'an approved in-window support_access_grants row (NFR-04). Identical '
  'results to v2 for all pre-existing users.';

-- ---------- 6. ALTER client_orgs (spec §6.1 Client) ----------
ALTER TABLE public.client_orgs
  ADD COLUMN legal_name          text,
  ADD COLUMN trading_name        text,
  ADD COLUMN registration_number text,
  ADD COLUMN jurisdiction        text REFERENCES public.jurisdiction_packs(code),
  ADD COLUMN sector              text,
  ADD COLUMN sites               jsonb,               -- [{name, address, …}] — structure free
  ADD COLUMN headcount_in_scope  int  CHECK (headcount_in_scope IS NULL OR headcount_in_scope >= 0),
  ADD COLUMN data_region         text,                -- NFR-11 selected residency ('ZA'/'UK' in R1)
  ADD COLUMN timezone            text;                -- IANA zone (NFR-10 display + business-day calcs)

COMMENT ON COLUMN public.client_orgs.jurisdiction IS
  'FK to jurisdiction_packs.code — drives template filtering (FR-ONB-03) and '
  'deadline/label resolution. NULL until onboarding step 1 sets it.';
COMMENT ON COLUMN public.client_orgs.registration_number IS
  'Spec §6.1 registration number. Backfilled from legacy registration_no; '
  'legacy column remains until web code is repointed (decision 2 in header).';
COMMENT ON COLUMN public.client_orgs.sector IS
  'Spec §6.1 sector. Backfilled from legacy industry; legacy column remains '
  'until web code is repointed (decision 2 in header).';

UPDATE public.client_orgs SET registration_number = registration_no
  WHERE registration_number IS NULL AND registration_no IS NOT NULL;
UPDATE public.client_orgs SET sector = industry
  WHERE sector IS NULL AND industry IS NOT NULL;

-- ---------- 7. ALTER practices (spec §6.1 Partner + Partner branding) ----------
ALTER TABLE public.practices
  ADD COLUMN type                text NOT NULL DEFAULT 'msp'
                                 CHECK (type IN ('msp','reseller','securepath_direct')),
  ADD COLUMN country             text,
  ADD COLUMN status              text NOT NULL DEFAULT 'active'
                                 CHECK (status IN ('active','suspended','closed')),
  ADD COLUMN primary_contact     text,                -- free text: name/email/phone
  ADD COLUMN subdomain           text UNIQUE
                                 CHECK (subdomain IS NULL OR subdomain ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'),
  ADD COLUMN email_sender_name   text,                -- FR-BRN-03 branded sender
  ADD COLUMN email_sender_domain text,                -- own domain once records verified
  ADD COLUMN sign_in_text        text,                -- FR-BRN-01 sign-in page text
  ADD COLUMN support_contact     text,                -- FR-BRN-01 support contact
  ADD COLUMN report_template_refs jsonb,              -- FR-BRN-04 {"word": "<ref>", "pdf": "<ref>"}
  ADD COLUMN data_region_default text,                -- §6.1 partner data region default
  ADD COLUMN ev_ref_format       text NOT NULL DEFAULT 'EV-%s-%03d', -- printf-style evidence ref mint
  ADD COLUMN primary_hex         text;                -- FR-BRN-01 primary colour (accent_hex exists)

COMMENT ON COLUMN public.practices.type IS
  'msp | reseller | securepath_direct (FR-PLT-01: SecurePath Direct is a '
  'partner row like any other).';
COMMENT ON COLUMN public.practices.status IS
  'active | suspended | closed. FR-PLT-06: suspended blocks sign-in without '
  'deleting client data (enforced in W4-08).';
COMMENT ON COLUMN public.practices.ev_ref_format IS
  'printf-style evidence-reference format, per partner (W1-02 mints EV refs): '
  '%s = client/programme token, %03d = sequence. Default EV-%s-%03d.';
COMMENT ON COLUMN public.practices.subdomain IS
  'FR-BRN-02 partner subdomain on the platform domain. Custom domain/auto-TLS '
  'deferred (plan §6 deviation).';

-- ---------- 8. ALTER users (spec §6.1 User) ----------
ALTER TABLE public.users
  ADD COLUMN status       text NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active','suspended','deactivated')),
  ADD COLUMN last_sign_in timestamptz,                -- app-stamped; GoTrue keeps its own
  ADD COLUMN organisation text;                       -- §6.1 organisation (esp. external providers/assessors)

COMMENT ON COLUMN public.users.status IS
  'active | suspended | deactivated. MFA status is NOT a column — it lives in '
  'auth.mfa_factors (GoTrue), enforced by middleware aal2.';

-- ---------- 9. RLS ----------
ALTER TABLE public.jurisdiction_packs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jurisdiction_packs    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.licences              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.licences              FORCE ROW LEVEL SECURITY;
ALTER TABLE public.designations          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.designations          FORCE ROW LEVEL SECURITY;
ALTER TABLE public.support_access_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_access_grants FORCE ROW LEVEL SECURITY;

-- jurisdiction_packs: global reference data — read by any partner_admin and
-- platform roles (mission policy); content authors write via editor RPC (W5-02).
CREATE POLICY jurisdiction_packs_read ON public.jurisdiction_packs FOR SELECT TO authenticated
USING (
  public.is_platform_role(ARRAY['platform_admin','content_author','support'])
  OR EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
             WHERE a.level = 'partner' AND a.scope_type = 'partner'
               AND a.role = 'partner_admin')
);

-- licences: §4.1 "Licence and usage reports — platform_admin Full,
-- partner_admin Own". No write policy: issue/change via platform RPCs only.
CREATE POLICY licences_read ON public.licences FOR SELECT TO authenticated
USING (
  public.has_partner_role(partner_id, ARRAY['partner_admin'])
  OR public.is_platform_role(ARRAY['platform_admin'])
);

-- designations — POLICY TEMPLATE T1 (client scope).
CREATE POLICY designations_read ON public.designations FOR SELECT TO authenticated
USING ( client_org_id IN (SELECT public.allowed_client_orgs()) );

CREATE POLICY designations_write ON public.designations FOR ALL TO authenticated
USING (
  client_org_id IN (SELECT public.allowed_client_orgs())
  AND EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
              WHERE a.level IN ('partner','client')
                AND a.role IN ('partner_admin','partner_consultant',
                               'accountable_officer','client_admin')
                AND ( (a.scope_type = 'client' AND a.scope_id = designations.client_org_id)
                   OR (a.scope_type = 'partner' AND a.scope_id =
                       (SELECT c.practice_id FROM public.client_orgs c
                        WHERE c.id = designations.client_org_id)) ))
)
WITH CHECK (
  client_org_id IN (SELECT public.allowed_client_orgs())
  AND EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
              WHERE a.level IN ('partner','client')
                AND a.role IN ('partner_admin','partner_consultant',
                               'accountable_officer','client_admin')
                AND ( (a.scope_type = 'client' AND a.scope_id = designations.client_org_id)
                   OR (a.scope_type = 'partner' AND a.scope_id =
                       (SELECT c.practice_id FROM public.client_orgs c
                        WHERE c.id = designations.client_org_id)) ))
);

-- support_access_grants: visible to the client it concerns (FR-PLT-04 "every
-- action … logged and visible to the client"), to the named SecurePath user,
-- and to platform_admin (§4.1 Full). No write policy — W4-01 RPC only.
CREATE POLICY support_access_grants_read ON public.support_access_grants FOR SELECT TO authenticated
USING (
  client_org_id IN (SELECT public.allowed_client_orgs())
  OR securepath_user_id = auth.uid()
  OR public.is_platform_role(ARRAY['platform_admin'])
);

-- ---------- 10. grants ----------
REVOKE ALL ON public.jurisdiction_packs, public.licences,
              public.designations, public.support_access_grants FROM anon;
GRANT SELECT ON public.jurisdiction_packs, public.licences,
                public.designations, public.support_access_grants TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.designations TO authenticated;  -- T1 write path
REVOKE INSERT, UPDATE, DELETE ON public.jurisdiction_packs,
                                public.licences, public.support_access_grants
  FROM authenticated;  -- writes via definer RPCs only (predicate-guarded)

COMMIT;
