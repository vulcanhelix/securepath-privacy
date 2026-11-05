-- ============================================================================
-- W0-02 — PROGRAMME ENGINE: ~30 tenant tables for the client programme modules
-- (GitHub #11 · spec SP-SPC-PLT-001 §6.2, §8, §9, §10 · plan BUILD_PLAN_R1 W0-02)
-- ============================================================================
--
-- A programme is the engine's scope root: it belongs to a client org and owns
-- phases, workstreams, activities, the remediation register, evidence, weekly
-- logs, KPIs, RAID, maintenance, snapshots and reports. Operational registers,
-- training records, the document register and external providers belong to the
-- CLIENT (spec §6.2: "a breach or a data subject request concerns the client as
-- a whole"), shared across that client's programmes.
--
-- This migration is deliberately INDEPENDENT of 20261105000002 (W0-01). It may
-- reference public.jurisdiction_packs(code) by name only (00002 applies before
-- this file on staging). It does NOT reference the new client_orgs/practices/
-- users columns or the licences/designations/support_access_grants tables —
-- holds_designation() below probes for public.designations at run time and
-- fails closed until that table exists.
--
-- FK targets used: client_orgs.id, practices.id (via client_orgs), users.id,
-- role_assignments (via predicates). programme_template_versions lands in W0-03:
-- template_version_id is a plain uuid column pending that FK.
--
-- --------------------- POLICY TEMPLATE PER TABLE (W0-00 catalogue) ----------
--   T1 client-scope  : programmes, external_providers, operational_records,
--                      training_records, controlled_documents,
--                      controlled_document_activities
--   T2 programme-scope: phases, workstreams, register_items, register_item_
--                      activities, evidence_items, evidence_reviews,
--                      evidence_offers, weekly_logs, kpis, kpi_actuals,
--                      raid_items, decisions, maintenance_task_templates,
--                      maintenance_task_instances, checklist_instances,
--                      monthly_snapshots, programme_reports, notification_
--                      events (scope claim)
--   T3 workstream-scope: activities (falls back to T2 when workstream_id is
--                      NULL), activity_deps, activity_status_history
--   T4 item-scope    : evidence_items read+update additionally allow the
--                      uploader / item-scoped assignee ("own items", §4.2)
--   T5 designation-gated: register_items (Closed transitions) and
--                      operational_records (regulator_notification) — enforced
--                      by triggers calling is_ao_or_alternate(), because a
--                      privileged WRITE must be impossible through EVERY path
--                      (direct table write and SECURITY DEFINER RPC alike).
--   own-row (T4 variant): notification_preferences (user_id = auth.uid())
--   catalog/outbox   : scheduled_jobs, job_runs, notification_events — read
--                      for authenticated; writes by SECURITY DEFINER only.
--
-- WRITE-PROTECTED ("calc") COLUMNS — spec §6.2 marks derived fields calc:
-- enforced by COLUMN-LEVEL GRANTS. The image's default privileges grant ALL
-- on new tables, so each table first gets REVOKE ALL FROM anon, authenticated;
-- then SELECT plus INSERT/UPDATE on the editable columns only. A direct write
-- naming a calc column fails with "permission denied for column"; SECURITY
-- DEFINER engines (W1-01) run as owner and write them freely.
--   programmes: phase, status
--   activities: phase, start_date, due_date, month, rag
--   register_items: planned_close_date, days_overdue, accepted_on, accepted_by,
--                   accepted_evidence_refs
--   evidence_items: uploaded_by, uploaded_at, review_stage, outcome,
--                   evidence_ref
--   weekly_logs: counts, week_rag
--   maintenance_task_instances: due_date, task_window
--   operational_records: reported_by (default), due_date, closed_on,
--                   regulator_notification (T5)
--   kpis: target_confirmed_by, target_confirmed_on
--   programme_reports: reference, snapshot_id, signatures, due_on, issued_on
--   uploader/reporter columns use DEFAULT auth.uid() and get no INSERT grant
--   so they can never be spoofed.
--
-- APPEND-ONLY tables (REVOKE UPDATE, DELETE; INSERT is the only write):
--   activity_status_history, evidence_reviews, decisions, monthly_snapshots,
--   notification_events, job_runs. Evidence items and programme reports are
--   append-mostly: once review_stage='decided' / status='issued' a trigger
--   rejects every UPDATE and DELETE (NFR-09, spec §9.5 — an issued report
--   cannot change afterwards).
--
-- STATUS VOCABULARY: 'Deferred' is included in activities.status (spec §15-#13
-- decision — the source tracker's RAG rule references a Deferred status that
-- was not in its pick list; built here, flagged to William).
--
-- Write-role sets used below:
--   WRITE  := partner_admin, partner_consultant, programme_lead, client_admin
--   STATUS := WRITE + workstream_lead + external_provider (own scope/items,
--             §4.2 "Update activity status: Own")
--   UPLOAD := partner_admin, partner_consultant, programme_lead, client_admin
--             (+ uploader / leads[] membership for own items)
-- ============================================================================


-- ---------- 1. tables (dependency order) ----------

-- ---- programmes — spec §6.2 "Programme". The scope root. T1 client-scope.
CREATE TABLE public.programmes (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id          uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    template_version_id    uuid,          -- plain uuid; FK added by W0-03 (programme_template_versions)
    name                   text NOT NULL,
    start_date             date NOT NULL CHECK (extract(isodow from start_date) = 1),  -- Monday of week 1 (§9.1)
    total_weeks            int  NOT NULL CHECK (total_weeks > 0),
    phase                  text,          -- CALC: current phase from template boundaries (§9.1) — engine writes
    status                 text NOT NULL DEFAULT 'implementation'
                           CHECK (status IN ('implementation','maintenance','closed')),
    programme_lead         uuid REFERENCES public.users(id) ON DELETE SET NULL,
    red_days_threshold     int  NOT NULL DEFAULT 14 CHECK (red_days_threshold >= 0),  -- §9.2
    report_due_business_day int NOT NULL DEFAULT 5 CHECK (report_due_business_day > 0), -- §9.1 POPIA default BD5
    reduced_capacity_weeks int[] NOT NULL DEFAULT '{}',  -- §9.1 / FR-SCH-02 shading
    programme_rag          text CHECK (programme_rag IN ('Red','Amber','Green')),  -- set monthly by PL (§9.6)
    rag_override_reason    text,
    created_at             timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  public.programmes IS
  'Spec §6.2 Programme — scope root for the whole engine. Policy template: '
  'T1 client-scope. status/phase are engine-written (lifecycle lives in W1-05).';
COMMENT ON COLUMN public.programmes.template_version_id IS
  'FK added W0-03 — references programme_template_versions (spec §6.1).';
COMMENT ON COLUMN public.programmes.phase IS 'CALC (§9.1): engine-written, write-protected.';
COMMENT ON COLUMN public.programmes.status IS 'Engine-written via lifecycle RPCs (W1-05); write-protected.';
CREATE INDEX programmes_client_idx ON public.programmes (client_org_id);

-- ---- phases — §6.2 "Phase". T2.
CREATE TABLE public.phases (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    number       int  NOT NULL CHECK (number > 0),
    name         text NOT NULL,
    start_week   int  NOT NULL CHECK (start_week > 0),
    end_week     int  NOT NULL CHECK (end_week >= start_week),
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (programme_id, number)
);
COMMENT ON TABLE public.phases IS 'Spec §6.2 Phase. Policy template: T2 programme-scope.';
CREATE INDEX phases_programme_idx ON public.phases (programme_id);

-- ---- workstreams — §6.2 "Workstream". T2.
CREATE TABLE public.workstreams (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id        uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    name                text NOT NULL,
    accountable_lead    uuid REFERENCES public.users(id) ON DELETE SET NULL,
    deputy              uuid REFERENCES public.users(id) ON DELETE SET NULL,
    rag_override        text CHECK (rag_override IN ('Red','Amber','Green')),  -- §9.6 PL override
    rag_override_reason text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (rag_override IS NULL OR rag_override_reason IS NOT NULL)   -- §9.6: override requires a reason
);
COMMENT ON TABLE public.workstreams IS
  'Spec §6.2 Workstream (accountable lead + deputy). Policy template: T2.';
CREATE INDEX workstreams_programme_idx ON public.workstreams (programme_id);

-- ---- activities — §6.2 "Activity". T3 (workstream) with T2 fallback.
CREATE TABLE public.activities (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id    uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    workstream_id   uuid REFERENCES public.workstreams(id) ON DELETE SET NULL,
    ref             text NOT NULL,
    text            text NOT NULL,
    leads           uuid[] NOT NULL DEFAULT '{}',      -- users ids; array FK impossible by design
    start_week      int  NOT NULL CHECK (start_week > 0),
    end_week        int  NOT NULL CHECK (end_week >= start_week),
    milestone       boolean NOT NULL DEFAULT false,
    evidence_required boolean NOT NULL DEFAULT false,
    status          text NOT NULL DEFAULT 'Not started'
                    CHECK (status IN ('Not started','In progress','At risk','Blocked','Deferred','Complete')),
                    -- 'Deferred' per spec §15-#13 (source tracker pick-list gap — build it)
    pct_complete    int  NOT NULL DEFAULT 0 CHECK (pct_complete BETWEEN 0 AND 100),
    actual_completion date,
    flag            boolean NOT NULL DEFAULT false,
    comments        text,
    recovery_date   date,                              -- FR-WKS-03: required to save an Amber item in-session
    dependency_override_reason text,                   -- FR-SCH-04: PL override to start with open deps
    -- CALC columns (§6.2/§9.1/§9.2): engine-written, write-protected.
    phase           text,
    start_date      date,
    due_date        date,
    month           int,
    rag             text CHECK (rag IN ('Not due','Green','Amber','Red','Complete')),
    created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  public.activities IS
  'Spec §6.2 Activity. Policy template: T3 workstream-scope (T2 fallback when '
  'workstream_id IS NULL). Status list includes Deferred (§15-#13).';
COMMENT ON COLUMN public.activities.leads IS 'users ids — element FKs impossible; validated app-side.';
COMMENT ON COLUMN public.activities.phase IS 'CALC (§9.1) — write-protected.';
COMMENT ON COLUMN public.activities.start_date IS 'CALC (§9.1) — write-protected.';
COMMENT ON COLUMN public.activities.due_date IS 'CALC (§9.1 Friday of end week) — write-protected.';
COMMENT ON COLUMN public.activities.month IS 'CALC (§9.1 programme month) — write-protected.';
COMMENT ON COLUMN public.activities.rag IS 'CALC (§9.2 ordered rules) — write-protected.';
CREATE INDEX activities_programme_idx   ON public.activities (programme_id);
CREATE INDEX activities_workstream_idx  ON public.activities (workstream_id);
CREATE INDEX activities_status_idx      ON public.activities (programme_id, status);

-- ---- activity_deps — finish-to-start dependencies (FR-SCH-04). T3-via-activity.
CREATE TABLE public.activity_deps (
    activity_id            uuid NOT NULL REFERENCES public.activities(id) ON DELETE CASCADE,
    depends_on_activity_id uuid NOT NULL REFERENCES public.activities(id) ON DELETE CASCADE,
    PRIMARY KEY (activity_id, depends_on_activity_id),
    CHECK (activity_id <> depends_on_activity_id)
);
COMMENT ON TABLE public.activity_deps IS
  'Spec §6.2 Activity dependencies. Policy template: T3 via the activity row.';
CREATE INDEX activity_deps_on_idx ON public.activity_deps (depends_on_activity_id);

-- ---- activity_status_history — append-only (spec §6.2 audit nature). T3-via-activity.
CREATE TABLE public.activity_status_history (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    activity_id uuid NOT NULL REFERENCES public.activities(id) ON DELETE CASCADE,
    old_status  text,
    new_status  text NOT NULL,
    changed_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
    changed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.activity_status_history IS
  'Spec §6.2 Activity status history — APPEND ONLY. Policy template: T3 via activity.';
CREATE INDEX activity_status_history_idx ON public.activity_status_history (activity_id);

-- ---- register_items — §6.2 "Register item". T2 + T5 gate on Closed.
CREATE TABLE public.register_items (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id        uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    ref                 text NOT NULL,
    finding             text NOT NULL,
    priority            text NOT NULL DEFAULT 'Medium' CHECK (priority IN ('High','Medium','Low')),
    assessment_window   text,                  -- which assessment window raised the finding
    lead                uuid REFERENCES public.users(id) ON DELETE SET NULL,
    planned_close_week  int CHECK (planned_close_week > 0),
    status              text NOT NULL DEFAULT 'Not started'
                        CHECK (status IN ('Not started','In progress','At risk','Blocked','Closed')),
                        -- Closed is set ONLY by the §9.4 ritual: all linked activities Complete
                        -- AND AO/alternate evidence acceptance — trg_register_closure gates it.
    accepted_on         timestamptz,           -- §9.4 record — write-protected
    accepted_by         uuid REFERENCES public.users(id) ON DELETE SET NULL, -- write-protected
    accepted_evidence_refs text[],             -- §9.4 record — write-protected
    reopen_reason       text,                  -- §9.4: re-opening needs AO + a reason
    planned_close_date  date,                  -- CALC — write-protected
    days_overdue        int,                   -- CALC (§9.3) — write-protected
    created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  public.register_items IS
  'Spec §6.2 Register item (remediation register). Policy template: T2 + T5 '
  'trigger gate — only AO or named alternate may set/unset Closed (§9.4, FR-ACC-02).';
COMMENT ON COLUMN public.register_items.status IS 'Closed transitions gated by trg_register_closure (T5).';
COMMENT ON COLUMN public.register_items.planned_close_date IS 'CALC (§9.1) — write-protected.';
COMMENT ON COLUMN public.register_items.days_overdue IS 'CALC (§9.3) — write-protected.';
CREATE INDEX register_items_programme_idx ON public.register_items (programme_id);
CREATE INDEX register_items_status_idx    ON public.register_items (programme_id, status);

-- ---- register_item_activities — m2m (§6.2 "many-to-many with activities").
CREATE TABLE public.register_item_activities (
    register_item_id uuid NOT NULL REFERENCES public.register_items(id) ON DELETE CASCADE,
    activity_id      uuid NOT NULL REFERENCES public.activities(id) ON DELETE CASCADE,
    PRIMARY KEY (register_item_id, activity_id)
);
COMMENT ON TABLE public.register_item_activities IS
  'Spec §6.2 register↔activity m2m. Policy template: T2 via the register item.';
CREATE INDEX register_item_activities_act_idx ON public.register_item_activities (activity_id);

-- ---- evidence_items — §6.2 "Evidence and review". T2 + T4 (uploader/own items).
CREATE TABLE public.evidence_items (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id     uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    activity_id      uuid REFERENCES public.activities(id) ON DELETE SET NULL,
    register_item_id uuid REFERENCES public.register_items(id) ON DELETE SET NULL,
    site             text,                        -- FR-EVD-01 mobile capture records site
    file_key         text,                        -- storage object key (evidence store, FR-EVD-02)
    link             text,
    uploaded_by      uuid NOT NULL DEFAULT auth.uid() REFERENCES public.users(id),
    uploaded_at      timestamptz NOT NULL DEFAULT now(),
    review_stage     text NOT NULL DEFAULT 'verification'
                     CHECK (review_stage IN ('verification','acceptance','decided')),
                     -- upload → verify checklist (PL/consultant) → AO accept → decided. Forward-only.
    outcome          text CHECK (outcome IN ('closes_finding','partly_supports','kpi_evidence')),
                     -- FR-EVD-04: what the acceptance does — recorded at decision.
    evidence_ref     text,                        -- minted on accept: EV-<register ref>-<seq> (FR-EVD-06)
    created_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (file_key IS NOT NULL OR link IS NOT NULL)   -- a file or a link, §6.2
);
COMMENT ON TABLE  public.evidence_items IS
  'Spec §6.2 Evidence and review. Policy template: T2 + T4 (uploader sees own '
  'items). Immutable once review_stage=decided (NFR-09 — corrections are new versions).';
COMMENT ON COLUMN public.evidence_items.uploaded_by IS 'Defaults auth.uid(); no INSERT grant — unspoofable.';
COMMENT ON COLUMN public.evidence_items.review_stage IS 'Engine/RPC-written, forward-only — write-protected.';
COMMENT ON COLUMN public.evidence_items.outcome IS 'Set at acceptance — write-protected.';
COMMENT ON COLUMN public.evidence_items.evidence_ref IS 'Minted on accept (FR-EVD-06) — write-protected.';
CREATE INDEX evidence_items_programme_idx ON public.evidence_items (programme_id);
CREATE INDEX evidence_items_activity_idx  ON public.evidence_items (activity_id);
CREATE INDEX evidence_items_register_idx  ON public.evidence_items (register_item_id);

-- ---- evidence_reviews — verify/accept ledger. APPEND ONLY. T2-via-evidence.
CREATE TABLE public.evidence_reviews (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    evidence_item_id uuid NOT NULL REFERENCES public.evidence_items(id) ON DELETE CASCADE,
    stage            text NOT NULL CHECK (stage IN ('verify','accept')),
                     -- verify = PL/consultant checklist (FR-EVD-03); accept = AO queue (FR-EVD-04/05)
    reviewer         uuid NOT NULL DEFAULT auth.uid() REFERENCES public.users(id),
    decision         text NOT NULL CHECK (decision IN ('verified','accepted','returned')),
    reasons          text[] NOT NULL DEFAULT '{}',          -- mandatory on return (FR-EVD-05)
    decided_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (decision <> 'returned' OR array_length(reasons, 1) >= 1),
    CHECK ((stage = 'verify'  AND decision IN ('verified','returned'))
        OR (stage = 'accept'  AND decision IN ('accepted','returned')))
);
COMMENT ON TABLE  public.evidence_reviews IS
  'Spec §6.2 review ledger — APPEND ONLY. Policy template: T2 via evidence + '
  'T5: stage/self-review/role gates enforced by trg_evidence_review_gate '
  '(FR-EVD-03/05, FR-ACC-01/02).';
CREATE INDEX evidence_reviews_item_idx ON public.evidence_reviews (evidence_item_id);

-- ---- evidence_offers — cross-programme offers (§6.2 "may be offered to
-- mapped programmes"; separate acceptance per programme). T2 both ends.
CREATE TABLE public.evidence_offers (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    evidence_item_id  uuid NOT NULL REFERENCES public.evidence_items(id) ON DELETE CASCADE,
    to_programme_id   uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    mapped_requirement text,                    -- the requirement it maps to in the target programme
    offered_by        uuid NOT NULL DEFAULT auth.uid() REFERENCES public.users(id),
    offered_at        timestamptz NOT NULL DEFAULT now(),
    decided_by        uuid REFERENCES public.users(id) ON DELETE SET NULL,
    decided_at        timestamptz,
    outcome           text CHECK (outcome IN ('accepted','declined'))   -- NULL = pending
);
COMMENT ON TABLE public.evidence_offers IS
  'Spec §6.2 evidence offers to mapped programmes. Policy template: T2 — '
  'source programme writes, target programme decides. Pending→decided is '
  'one-way (trg_evidence_offer).';
CREATE INDEX evidence_offers_item_idx ON public.evidence_offers (evidence_item_id);
CREATE INDEX evidence_offers_to_idx   ON public.evidence_offers (to_programme_id);

-- ---- weekly_logs — §6.2 "Weekly log". T2.
CREATE TABLE public.weekly_logs (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    week         int  NOT NULL CHECK (week > 0),
    counts       jsonb,                               -- CALC: due/overdue/starting/awaiting/raid (FR-WKS-04)
    session_held boolean NOT NULL DEFAULT false,
    completed    jsonb NOT NULL DEFAULT '[]',
    planned_next jsonb NOT NULL DEFAULT '[]',
    blockers     text,
    decisions    text,
    week_rag     text CHECK (week_rag IN ('Green','Amber','Red')),   -- CALC
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (programme_id, week)                                    -- one per week (§6.2)
);
COMMENT ON TABLE  public.weekly_logs IS
  'Spec §6.2 Weekly log (one per week, FR-WKS-04). Policy template: T2.';
COMMENT ON COLUMN public.weekly_logs.counts IS 'CALC — write-protected.';
COMMENT ON COLUMN public.weekly_logs.week_rag IS 'CALC — write-protected.';
CREATE INDEX weekly_logs_programme_idx ON public.weekly_logs (programme_id);

-- ---- kpis — §6.2 "KPI". T2.
CREATE TABLE public.kpis (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id        uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    name                text NOT NULL,
    unit                text,
    baseline            numeric,
    target              numeric,
    calculation         text,
    auto_calc           boolean NOT NULL DEFAULT false,   -- template marks it automatic (FR-KPI-02)
    target_proposed     boolean NOT NULL DEFAULT false,   -- AO must confirm (FR-KPI-03)
    target_confirmed_by uuid REFERENCES public.users(id) ON DELETE SET NULL,  -- write-protected
    target_confirmed_on timestamptz,                      -- write-protected
    sort                int NOT NULL DEFAULT 100,
    created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  public.kpis IS
  'Spec §6.2 KPI (FR-KPI-01/02/03). Policy template: T2.';
COMMENT ON COLUMN public.kpis.target_confirmed_by IS 'Set by the AO-confirm RPC — write-protected.';
CREATE INDEX kpis_programme_idx ON public.kpis (programme_id);

-- ---- kpi_actuals — §6.2 "KPI actual". T2-via-kpi.
CREATE TABLE public.kpi_actuals (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kpi_id      uuid NOT NULL REFERENCES public.kpis(id) ON DELETE CASCADE,
    month       date NOT NULL CHECK (month = date_trunc('month', month)::date),  -- first of month
    value       numeric,
    evidence_id uuid REFERENCES public.evidence_items(id) ON DELETE SET NULL,   -- monthly entries with evidence (FR-KPI-02)
    entered_by  uuid NOT NULL DEFAULT auth.uid() REFERENCES public.users(id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (kpi_id, month)
);
COMMENT ON TABLE public.kpi_actuals IS
  'Spec §6.2 KPI actual (month, value, evidence). Policy template: T2 via kpi.';
CREATE INDEX kpi_actuals_kpi_idx ON public.kpi_actuals (kpi_id);

-- ---- raid_items — §6.2 "RAID item". T2.
CREATE TABLE public.raid_items (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    type         text NOT NULL CHECK (type IN ('risk','assumption','issue')),  -- decisions live in decisions
    description  text NOT NULL,
    impact       text,
    action       text,
    owner        uuid REFERENCES public.users(id) ON DELETE SET NULL,
    raised_on    date NOT NULL DEFAULT CURRENT_DATE,
    review_by    date,                                    -- past-date → weekly agenda (FR-RAI-02)
    status       text NOT NULL DEFAULT 'Open' CHECK (status IN ('Open','In progress','Closed')),
    source       text NOT NULL DEFAULT 'manual'
                 CHECK (source IN ('template','manual','exception','import')),
                 -- 'exception': raised by a maintenance task (FR-MNT-06); engine-written
    created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  public.raid_items IS
  'Spec §6.2 RAID item (risk/assumption/issue; decisions are a child ledger). '
  'Policy template: T2.';
COMMENT ON COLUMN public.raid_items.source IS 'Write-protected: template seeds and exception-raised rows are engine-written.';
CREATE INDEX raid_items_programme_idx ON public.raid_items (programme_id);

-- ---- decisions — §6.2 "decision". APPEND ONLY. T2-via-raid.
CREATE TABLE public.decisions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    raid_item_id uuid NOT NULL REFERENCES public.raid_items(id) ON DELETE CASCADE,
    outcome      text NOT NULL,
    decided_on   date NOT NULL DEFAULT CURRENT_DATE,
    minute_ref   text,                                  -- FR-RAI-03 minute reference
    unlocks      jsonb NOT NULL DEFAULT '[]',           -- what the decision unlocks (FR-RAI-03)
    decided_by   uuid NOT NULL DEFAULT auth.uid() REFERENCES public.users(id),
    created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.decisions IS
  'Spec §6.2 decision record (outcome, date, minute ref, unlocks). '
  'APPEND ONLY. Policy template: T2 via raid item.';
CREATE INDEX decisions_raid_idx ON public.decisions (raid_item_id);

-- ---- external_providers — client-level named providers (FR-MNT-04). T1.
CREATE TABLE public.external_providers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    name          text NOT NULL,
    kind          text,                       -- e.g. IT provider, marketing lead, finance, HR/admin (FR-MNT-04)
    contact_email text,
    channel       text,                       -- how inputs arrive (portal/email/…)
    active        boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.external_providers IS
  'Spec §8.9/FR-MNT-04 named external providers (persisted per client). '
  'Policy template: T1 client-scope.';
CREATE INDEX external_providers_client_idx ON public.external_providers (client_org_id);

-- ---- maintenance_task_templates — §6.2 "Maintenance task". T2 (programme rows).
CREATE TABLE public.maintenance_task_templates (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id          uuid REFERENCES public.programmes(id) ON DELETE CASCADE,
    template_version_id   uuid,             -- plain uuid; FK added by W0-03 (content rows)
    code                  text NOT NULL,    -- e.g. MM-01 (Annex A)
    task                  text NOT NULL,
    timing_rule           jsonb NOT NULL,   -- {"window":"before_month_end"|"month_end_close"|"report_window"|"executive_meeting", "business_day":n}
    owner_role            text NOT NULL DEFAULT 'programme_lead',
    input_from_label      text,             -- template-time label, e.g. 'Marketing lead' (Annex A)
    input_from_provider_id uuid REFERENCES public.external_providers(id) ON DELETE SET NULL,
    evidence_produced     text,
    feeds                 text,             -- report section or KPI fed, e.g. 'Report; request KPI' (Annex A)
    active_from_rule      jsonb,            -- FR-MNT-08 e.g. {"when_activity_complete":"<activity ref>"}
    active                boolean NOT NULL DEFAULT true,
    sort                  int NOT NULL DEFAULT 100,
    created_at            timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(programme_id, template_version_id) = 1)
);
COMMENT ON TABLE  public.maintenance_task_templates IS
  'Spec §6.2/§8.9 maintenance task template. Policy template: T2 for '
  'programme-scoped rows; template-version rows are content, readable by '
  'authenticated and written only via definer RPCs (W0-03/W1-03).';
COMMENT ON COLUMN public.maintenance_task_templates.template_version_id IS 'FK added W0-03.';
CREATE UNIQUE INDEX mtt_programme_code_idx ON public.maintenance_task_templates (programme_id, code)
  WHERE programme_id IS NOT NULL;
CREATE UNIQUE INDEX mtt_template_code_idx ON public.maintenance_task_templates (template_version_id, code)
  WHERE template_version_id IS NOT NULL;
CREATE INDEX mtt_programme_idx ON public.maintenance_task_templates (programme_id);

-- ---- maintenance_task_instances — §6.2 "instance". T2-via-template.
CREATE TABLE public.maintenance_task_instances (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_template_id      uuid NOT NULL REFERENCES public.maintenance_task_templates(id) ON DELETE CASCADE,
    period                text NOT NULL CHECK (period ~ '^[0-9]{4}-[0-9]{2}$'),   -- 'YYYY-MM'
    due_date              date,                 -- CALC from timing_rule (§9.1 business days) — write-protected
    task_window           text,                 -- CALC grouping (FR-MNT-03) — write-protected
    assignee              uuid REFERENCES public.users(id) ON DELETE SET NULL,
    status                text NOT NULL DEFAULT 'Pending'
                          CHECK (status IN ('Pending','In progress','Complete','Exception')),
    evidence_id           uuid REFERENCES public.evidence_items(id) ON DELETE SET NULL,
    evidence_exempt_reason text,                -- FR-MNT-05: Complete w/o evidence needs this reason
    exception_reason      text,                 -- FR-MNT-06: raises a RAID issue → weekly agenda
    exception_raid_item_id uuid REFERENCES public.raid_items(id) ON DELETE SET NULL,
    completed_on          timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    CHECK (status <> 'Complete' OR evidence_id IS NOT NULL OR evidence_exempt_reason IS NOT NULL)  -- FR-MNT-05
);
COMMENT ON TABLE  public.maintenance_task_instances IS
  'Spec §6.2 maintenance task instance (monthly generation, FR-MNT-02). '
  'Policy template: T2 via task template.';
COMMENT ON COLUMN public.maintenance_task_instances.due_date IS 'CALC (§9.7/9.1) — write-protected.';
COMMENT ON COLUMN public.maintenance_task_instances.task_window IS 'CALC (FR-MNT-03) — write-protected.';
CREATE INDEX mti_template_idx ON public.maintenance_task_instances (task_template_id);
CREATE INDEX mti_period_idx    ON public.maintenance_task_instances (task_template_id, period);

-- ---- checklist_instances — §8.11 quarterly/annual generation. T2.
CREATE TABLE public.checklist_instances (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    kind         text NOT NULL CHECK (kind IN ('quarterly','annual')),
    period       text NOT NULL,                          -- e.g. '2026-Q4' or '2026'
    items        jsonb NOT NULL DEFAULT '[]',            -- checklist slots incl. evidence refs (FR-QTR-01/02)
    generated_on date NOT NULL DEFAULT CURRENT_DATE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (programme_id, kind, period)
);
COMMENT ON TABLE public.checklist_instances IS
  'Spec §8.11 quarterly/annual checklist + annual review tasks (FR-QTR-01/02). '
  'Policy template: T2.';
CREATE INDEX checklist_instances_programme_idx ON public.checklist_instances (programme_id);

-- ---- operational_records — §6.2/§8.10 client-level registers. T1 + T5.
CREATE TABLE public.operational_records (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    type          text NOT NULL CHECK (type IN ('dsr','breach','disclosure','optout')),
                  -- data subject request / breach or incident / disclosure / opt-out or objection
    description   text,
    reported_at   timestamptz NOT NULL DEFAULT now(),
    reported_by   uuid NOT NULL DEFAULT auth.uid() REFERENCES public.users(id),
    site          text,
    channel       text,
    deadline_rule text,                        -- key into the jurisdiction pack parameters (FR-OPS-02)
    deadline_params jsonb,                     -- inputs to the deadline resolution — never hard-coded periods
    due_date      date,                        -- CALC: resolved from the jurisdiction pack (§9.7) — write-protected
    status        text NOT NULL DEFAULT 'Open'
                  CHECK (status IN ('Open','In progress','Awaiting decision','Closed')),
    outcome       text,
    regulator_notification jsonb,              -- breach notification decision record — T5, write-protected
    closed_on     timestamptz,                 -- write-protected
    created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  public.operational_records IS
  'Spec §6.2/§8.10 Operational record (DSR, breach, disclosure, opt-out) — '
  'client-level, shared across programmes. Policy template: T1 + T5 '
  '(regulator_notification write gated by trg_oprecord_regulator, FR-ACC-02).';
COMMENT ON COLUMN public.operational_records.deadline_params IS
  'Inputs to §9.7 resolution — legal periods come from jurisdiction_packs, never hard-coded.';
COMMENT ON COLUMN public.operational_records.due_date IS 'CALC (§9.7 jurisdiction pack) — write-protected.';
COMMENT ON COLUMN public.operational_records.regulator_notification IS
  'T5: only AO or named alternate may record the breach notification decision '
  '(FR-OPS-03, FR-ACC-02) — no column grant + trigger gate.';
CREATE INDEX operational_records_client_idx ON public.operational_records (client_org_id);
CREATE INDEX operational_records_type_idx   ON public.operational_records (client_org_id, type);

-- ---- training_records — §6.2 "Training record". T1.
CREATE TABLE public.training_records (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id    uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    person           text NOT NULL,          -- client staff member (not necessarily a platform user)
    site             text,
    functional_group text,
    session          text,
    date             date,
    attendance       boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.training_records IS
  'Spec §6.2/§8.12 Training record (attendance by site and functional group). '
  'Policy template: T1 client-scope.';
CREATE INDEX training_records_client_idx ON public.training_records (client_org_id);

-- ---- controlled_documents — §6.2/§8.13 "Document". T1.
CREATE TABLE public.controlled_documents (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id    uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    reference        text NOT NULL,
    title            text NOT NULL,
    version          text NOT NULL,
    owner            text,                       -- client-side owner (person, not necessarily a user)
    approval_date    date,
    next_review_date date,                       -- MM-19 flags documents reaching review date
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (client_org_id, reference, version)
);
COMMENT ON TABLE public.controlled_documents IS
  'Spec §6.2/§8.13 controlled document register (version, owner, dates). '
  'Policy template: T1 client-scope.';
CREATE INDEX controlled_documents_client_idx ON public.controlled_documents (client_org_id);

-- ---- controlled_document_activities — links docs to the activities that
-- approve or reissue them (FR-DOC-01). T1-via-doc.
CREATE TABLE public.controlled_document_activities (
    controlled_document_id uuid NOT NULL REFERENCES public.controlled_documents(id) ON DELETE CASCADE,
    activity_id            uuid NOT NULL REFERENCES public.activities(id) ON DELETE CASCADE,
    PRIMARY KEY (controlled_document_id, activity_id)
);
COMMENT ON TABLE public.controlled_document_activities IS
  'Spec FR-DOC-01 document↔activity m2m. Policy template: T1 via document.';

-- ---- monthly_snapshots — §6.2/§9.5. T2, APPEND ONLY.
CREATE TABLE public.monthly_snapshots (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    period       text NOT NULL CHECK (period ~ '^[0-9]{4}-[0-9]{2}$'),    -- 'YYYY-MM'
    snapshot     jsonb NOT NULL,
    taken_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (programme_id, period)                        -- one snapshot per month
);
COMMENT ON TABLE  public.monthly_snapshots IS
  'Spec §6.2/§9.5 Monthly snapshot — APPEND ONLY, written by the last-business-'
  'day job. Policy template: T2. JSONB CONTRACT (fixed keys): '
  '{activities_complete, activities_overdue, register_closed, register_open, '
  'high_priority_closed, evidence_pending, rag, kpi_actuals, maintenance_done, '
  'maintenance_overdue} — reports are built from it so an issued report '
  'cannot change afterwards.';
CREATE INDEX monthly_snapshots_programme_idx ON public.monthly_snapshots (programme_id);

-- ---- programme_reports — §6.2 "Monthly report". T2 + workflow gate.
CREATE TABLE public.programme_reports (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    programme_id  uuid NOT NULL REFERENCES public.programmes(id) ON DELETE CASCADE,
    period        text NOT NULL CHECK (period ~ '^[0-9]{4}-[0-9]{2}$'),   -- 'YYYY-MM'
    reference     text,                            -- minted on issue — write-protected
    snapshot_id   uuid REFERENCES public.monthly_snapshots(id) ON DELETE SET NULL,  -- write-protected
    sections      jsonb NOT NULL DEFAULT '{}',     -- report structure from the template (FR-RPT-01)
    overall_rag   text CHECK (overall_rag IN ('Red','Amber','Green')),
    trend         text,
    headline      text,
    commentary    text,
    status        text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','inputs_complete','ao_review','signed','issued')),
                  -- FR-RPT-04 workflow; legal transitions gated by trg_report_transition
    signatures    jsonb NOT NULL DEFAULT '[]',     -- [{role, user, at}] — write-protected
    gate_override_reason text,                    -- FR-MNT-07: reason that prints in the report
    due_on        date,                            -- §9.1 business-day due — write-protected
    issued_on     timestamptz,                     -- write-protected; set on issue
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (programme_id, period)                  -- one per month (§6.2)
);
COMMENT ON TABLE  public.programme_reports IS
  'Spec §6.2/§8.6 Monthly report. Policy template: T2 + workflow gate '
  '(trg_report_transition). Issued reports are immutable (§9.5).';
COMMENT ON COLUMN public.programme_reports.due_on IS 'CALC (§9.1) — write-protected; late = not issued by due_on (FR-RPT-06).';
COMMENT ON COLUMN public.programme_reports.reference IS 'Minted per partner format on issue — write-protected.';
CREATE INDEX programme_reports_programme_idx ON public.programme_reports (programme_id);

-- ---- notification_events — §10 outbox. Scope-claim read, definer writes.
CREATE TABLE public.notification_events (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind         text NOT NULL,                     -- e.g. 'activity_due','evidence_returned','breach_reported'
    scope        jsonb NOT NULL DEFAULT '{}',       -- {practice_id?, client_org_id?, programme_id?, user_id?}
    payload      jsonb NOT NULL DEFAULT '{}',       -- recipients, subject, brand/template context, entity refs
    created_at   timestamptz NOT NULL DEFAULT now(),
    dispatched_at timestamptz                       -- set by the W1-08 dispatcher (definer) — write-protected
);
COMMENT ON TABLE  public.notification_events IS
  'Spec §10 notification outbox — append + dispatch only (REVOKE UPDATE,DELETE; '
  'dispatched_at set by the definer consumer). Policy template: T2 via the '
  'scope jsonb claim.';
CREATE INDEX notification_events_created_idx ON public.notification_events (created_at)
  WHERE dispatched_at IS NULL;

-- ---- notification_preferences — §10 per-user prefs. own-row.
CREATE TABLE public.notification_preferences (
    user_id    uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    digest     boolean NOT NULL DEFAULT false,      -- daily digest opt-in (§10; breach alerts always immediate)
    kinds      jsonb NOT NULL DEFAULT '{}',         -- per-kind overrides, e.g. {"breach_reported":{"channel":"email"}}
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.notification_preferences IS
  'Spec §10 per-user notification preferences (digest opt-in; breach alerts '
  'always immediate regardless). Policy template: own-row (T4 variant).';

-- ---- scheduled_jobs — §10 job catalogue (config, definer-writer).
CREATE TABLE public.scheduled_jobs (
    key       text PRIMARY KEY,
    schedule  text NOT NULL,             -- human/cron descriptor; client-TZ resolution lives in W1-09
    target    jsonb NOT NULL DEFAULT '{}',  -- what to invoke (engine/RPC reference)
    enabled   boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.scheduled_jobs IS
  'Spec §10 scheduled-jobs catalogue — each job runs in the client''s time '
  'zone. Config rows; writes by definer/ops only.';

-- ---- job_runs — §10 execution ledger. APPEND ONLY.
CREATE TABLE public.job_runs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_key     text NOT NULL REFERENCES public.scheduled_jobs(key) ON DELETE CASCADE,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    status      text NOT NULL DEFAULT 'running' CHECK (status IN ('running','success','failed','skipped')),
    detail      jsonb NOT NULL DEFAULT '{}'        -- counts, lease/idempotency markers (W1-09)
);
COMMENT ON TABLE public.job_runs IS
  'Spec §10 job run ledger — APPEND ONLY (finish row updates finished_at via '
  'definer; REVOKE UPDATE,DELETE from authenticated).';
CREATE INDEX job_runs_job_idx ON public.job_runs (job_key, started_at DESC);

-- spec §10 job catalogue seeds — schedule descriptors; W1-09 implements the runner.
INSERT INTO public.scheduled_jobs (key, schedule, target) VALUES
  ('daily-recalc-digest',       'daily 06:00 client-tz',               '{"job":"recalc+digest"}'),
  ('monthly-bd1-gen',           'first business day of month',          '{"job":"maintenance_tasks+draft_report"}'),
  ('monthly-last-bd-snapshot',  'last business day of month 18:00',     '{"job":"monthly_snapshot"}'),
  ('monday-agenda',             'Monday 06:00 client-tz',               '{"job":"weekly_agenda"}'),
  ('quarterly-annual-checklists','quarterly/annual dates from template','{"job":"checklist_gen"}'),
  ('partner-usage-report',      'first business day of month',          '{"job":"licence_usage"}');


-- ---------- 2. predicate catalogue extensions (W0-00 model) ----------
-- All STABLE SECURITY DEFINER: usable inside RLS expressions without recursion.
-- REVOKE/GRANT EXECUTE at the end of the file.

CREATE FUNCTION public.programme_client(p_programme uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT client_org_id FROM public.programmes WHERE id = p_programme
$$;
COMMENT ON FUNCTION public.programme_client(uuid) IS
  'W0-02 predicate: the client_org_id owning a programme (NULL if none).';

-- Caller holds an active assignment with one of p_roles at programme scope,
-- the programme's client scope, or the client's partner scope (partner-level
-- roles cascade down to every client of the partner — same rule as the W0-00
-- T1 write template, extended one level).
CREATE FUNCTION public.has_programme_role(p_programme uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.programmes pr
    JOIN public.client_orgs co ON co.id = pr.client_org_id
    JOIN public.role_assignments ra ON ra.user_id = auth.uid()
    WHERE pr.id = p_programme
      AND ra.level IN ('partner','client')
      AND ra.role = ANY(p_roles)
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'programme' AND ra.scope_id = pr.id)
         OR (ra.scope_type = 'client'    AND ra.scope_id = co.id)
         OR (ra.scope_type = 'partner'   AND ra.scope_id = co.practice_id) ))
$$;
COMMENT ON FUNCTION public.has_programme_role(uuid, text[]) IS
  'W0-02 predicate: caller holds an active listed role at programme scope, '
  'the owning client scope, or the owning partner scope.';

CREATE FUNCTION public.has_client_role(p_client_org uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.client_orgs co
    JOIN public.role_assignments ra ON ra.user_id = auth.uid()
    WHERE co.id = p_client_org
      AND ra.level IN ('partner','client')
      AND ra.role = ANY(p_roles)
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'client'    AND ra.scope_id = co.id)
         OR (ra.scope_type = 'partner'   AND ra.scope_id = co.practice_id)
         OR (ra.scope_type = 'programme' AND ra.scope_id IN
              (SELECT p.id FROM public.programmes p WHERE p.client_org_id = co.id)) ))
$$;
COMMENT ON FUNCTION public.has_client_role(uuid, text[]) IS
  'W0-02 predicate: T1 write gate — caller holds an active listed role at '
  'client scope, the owning partner scope, or a programme of that client '
  '(client-level records are shared across the client''s programmes, §6.2).';

CREATE FUNCTION public.has_workstream_role(p_workstream uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.workstreams w
    JOIN public.programmes pr ON pr.id = w.programme_id
    JOIN public.client_orgs co ON co.id = pr.client_org_id
    JOIN public.role_assignments ra ON ra.user_id = auth.uid()
    WHERE w.id = p_workstream
      AND ra.level IN ('partner','client')
      AND ra.role = ANY(p_roles)
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'workstream' AND ra.scope_id = w.id)
         OR (ra.scope_type = 'programme'  AND ra.scope_id = pr.id)
         OR (ra.scope_type = 'client'     AND ra.scope_id = co.id)
         OR (ra.scope_type = 'partner'    AND ra.scope_id = co.practice_id) ))
$$;
COMMENT ON FUNCTION public.has_workstream_role(uuid, text[]) IS
  'W0-02 predicate: T3 write gate — caller holds an active listed role at '
  'workstream scope or any wider scope above it.';

-- Same cascade keyed on an activity (workstream scope only when the activity
-- is attached to one).
CREATE FUNCTION public.has_activity_role(p_activity uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.activities a
    JOIN public.programmes pr ON pr.id = a.programme_id
    JOIN public.client_orgs co ON co.id = pr.client_org_id
    JOIN public.role_assignments ra ON ra.user_id = auth.uid()
    WHERE a.id = p_activity
      AND ra.level IN ('partner','client')
      AND ra.role = ANY(p_roles)
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'workstream' AND ra.scope_id = a.workstream_id)
         OR (ra.scope_type = 'programme'  AND ra.scope_id = pr.id)
         OR (ra.scope_type = 'client'     AND ra.scope_id = co.id)
         OR (ra.scope_type = 'partner'    AND ra.scope_id = co.practice_id) ))
$$;
COMMENT ON FUNCTION public.has_activity_role(uuid, text[]) IS
  'W0-02 predicate: write gate keyed on an activity row (T3 through its '
  'workstream, falling back to programme/client/partner scope).';

-- T5 leg: does the caller hold a designation of one of p_kinds on this client
-- (the "named alternate" path, FR-ACC-02/03). public.designations lands in W0-01
-- (00002); until it exists this returns false — fail closed, never error.
-- The designation person and kind columns are probed so the function works
-- whichever names W0-01 chose (person/user_id/person_id; role/designation/kind).
CREATE FUNCTION public.holds_designation(p_client_org uuid, p_kinds text[])
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_person_col text; v_kind_col text; v_result boolean;
BEGIN
  IF to_regclass('public.designations') IS NULL THEN RETURN false; END IF;
  SELECT column_name INTO v_person_col FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'designations'
     AND column_name IN ('person','user_id','person_id','designee')
   ORDER BY CASE column_name WHEN 'person' THEN 0 WHEN 'user_id' THEN 1
                             WHEN 'person_id' THEN 2 ELSE 3 END
   LIMIT 1;
  SELECT column_name INTO v_kind_col FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'designations'
     AND column_name IN ('role','designation','designation_kind','kind')
   ORDER BY CASE column_name WHEN 'role' THEN 0 WHEN 'designation' THEN 1
                             WHEN 'designation_kind' THEN 2 ELSE 3 END
   LIMIT 1;
  IF v_person_col IS NULL OR v_kind_col IS NULL THEN RETURN false; END IF;
  EXECUTE format(
    'SELECT EXISTS (SELECT 1 FROM public.designations d
                     WHERE d.client_org_id = $1 AND d.%I = $2 AND d.%I = ANY($3))',
    v_person_col, v_kind_col)
    INTO v_result USING p_client_org, auth.uid(), p_kinds;
  RETURN COALESCE(v_result, false);
END $$;
COMMENT ON FUNCTION public.holds_designation(uuid, text[]) IS
  'W0-02 predicate: caller is a designated person (e.g. named alternate) on '
  'this client. Fails closed while public.designations is absent (W0-01).';

-- FR-ACC-02: only the accountable officer or a named alternate may close a
-- register item or record a breach notification decision. Client-scope AO,
-- programme-scope AO under this client, or a designation row.
CREATE FUNCTION public.is_ao_or_alternate(p_client_org uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.role_assignments ra
    WHERE ra.user_id = auth.uid() AND ra.level = 'client'
      AND ra.role = 'accountable_officer'
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'client' AND ra.scope_id = p_client_org)
         OR (ra.scope_type = 'programme' AND ra.scope_id IN
              (SELECT p.id FROM public.programmes p WHERE p.client_org_id = p_client_org)) ))
  OR public.holds_designation(p_client_org, ARRAY['named_alternate','alternate','Deputy Information Officer','dio'])
$$;
COMMENT ON FUNCTION public.is_ao_or_alternate(uuid) IS
  'W0-02 predicate (T5): caller is the accountable officer on this client or '
  'its named alternate (designations probe). FR-ACC-02 gate.';

-- allowed_programmes() — W0-00 shipped this as a stub returning client ids
-- ("until the programmes entity lands"). It lands here: now returns real
-- programme ids — every programme of every visible client UNION direct
-- programme-scope assignments. Workstream-scope rows deliberately excluded:
-- a workstream lead sees their own workstream via T3, not the whole programme.
CREATE OR REPLACE FUNCTION public.allowed_programmes() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id FROM public.programmes p
   WHERE p.client_org_id IN (SELECT public.allowed_client_orgs())
  UNION
  SELECT ra.scope_id
    FROM public.role_assignments ra
   WHERE ra.user_id = auth.uid()
     AND ra.scope_type = 'programme'
     AND ra.level IN ('partner','client')
     AND ra.start_date <= CURRENT_DATE
     AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
$$;
COMMENT ON FUNCTION public.allowed_programmes() IS
  'W0-02 (replaces W0-00 stub): programme ids the caller may see — programmes '
  'of all visible clients plus direct programme-scope assignments. T2 read.';


-- ---------- 3. trigger functions + triggers ----------
-- Definer bodies call the predicate catalogue per the hard rule. The AO/T5
-- triggers enforce in a JWT context (auth.uid() IS NOT NULL): NULL means a
-- direct service/migration write where RLS is not the gate (W0-00 convention).

-- auto-record completion date on Complete (FR-SCH-05)
CREATE FUNCTION public.trg_activity_completion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'Complete' AND NEW.actual_completion IS NULL THEN
    NEW.actual_completion := CURRENT_DATE;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER activity_completion
BEFORE INSERT OR UPDATE ON public.activities
FOR EACH ROW EXECUTE FUNCTION public.trg_activity_completion();

-- status transitions append to the history ledger (spec §6.2 audit)
CREATE FUNCTION public.trg_activity_status_history() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.activity_status_history (activity_id, old_status, new_status, changed_by)
    VALUES (OLD.id, OLD.status, NEW.status, auth.uid());
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER activity_status_history_trg
AFTER UPDATE ON public.activities
FOR EACH ROW EXECUTE FUNCTION public.trg_activity_status_history();

-- dependencies only inside one programme
CREATE FUNCTION public.trg_activity_dep_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF (SELECT programme_id FROM public.activities WHERE id = NEW.activity_id)
     IS DISTINCT FROM
     (SELECT programme_id FROM public.activities WHERE id = NEW.depends_on_activity_id) THEN
    RAISE EXCEPTION 'activity dependencies must stay inside one programme';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER activity_dep_scope
BEFORE INSERT OR UPDATE ON public.activity_deps
FOR EACH ROW EXECUTE FUNCTION public.trg_activity_dep_scope();

-- T5: register close / re-open gate (§9.4, FR-ACC-02). Runs on every write
-- path — direct and inside SECURITY DEFINER RPCs alike — so the gate cannot
-- be bypassed by an RPC that forgot the check.
CREATE FUNCTION public.trg_register_closure() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_client uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;  -- service/migration write
  SELECT client_org_id INTO v_client FROM public.programmes WHERE id = NEW.programme_id;

  IF NEW.status = 'Closed' AND OLD.status IS DISTINCT FROM 'Closed' THEN
    IF NOT public.is_ao_or_alternate(v_client) THEN
      RAISE EXCEPTION 'only the accountable officer or named alternate may close a register item';
    END IF;
    IF NEW.accepted_on IS NULL OR NEW.accepted_by IS NULL THEN
      RAISE EXCEPTION 'register closure requires the evidence acceptance record (§9.4)';
    END IF;
  END IF;
  IF OLD.status = 'Closed' AND NEW.status IS DISTINCT FROM 'Closed' THEN
    IF NOT public.is_ao_or_alternate(v_client) THEN
      RAISE EXCEPTION 'only the accountable officer or named alternate may re-open a register item';
    END IF;
    IF NEW.reopen_reason IS NULL OR btrim(NEW.reopen_reason) = '' THEN
      RAISE EXCEPTION 're-opening a closed finding requires a reason (§9.4)';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER register_closure_gate
BEFORE UPDATE ON public.register_items
FOR EACH ROW EXECUTE FUNCTION public.trg_register_closure();

-- evidence stays consistent: linked activity/register item must belong to the
-- same programme as the evidence row
CREATE FUNCTION public.trg_evidence_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.activity_id IS NOT NULL
     AND (SELECT programme_id FROM public.activities WHERE id = NEW.activity_id)
         IS DISTINCT FROM NEW.programme_id THEN
    RAISE EXCEPTION 'evidence activity must belong to the same programme';
  END IF;
  IF NEW.register_item_id IS NOT NULL
     AND (SELECT programme_id FROM public.register_items WHERE id = NEW.register_item_id)
         IS DISTINCT FROM NEW.programme_id THEN
    RAISE EXCEPTION 'evidence register item must belong to the same programme';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER evidence_scope_check
BEFORE INSERT OR UPDATE ON public.evidence_items
FOR EACH ROW EXECUTE FUNCTION public.trg_evidence_scope();

-- NFR-09: decided evidence is immutable — corrections are new versions.
CREATE FUNCTION public.trg_evidence_immutable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF OLD.review_stage = 'decided' THEN
    RAISE EXCEPTION 'decided evidence is immutable — record a new version instead (NFR-09)';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  -- forward-only stage flow: verification → acceptance → decided
  IF NEW.review_stage IS DISTINCT FROM OLD.review_stage THEN
    IF NOT ( (OLD.review_stage = 'verification' AND NEW.review_stage IN ('acceptance','decided'))
          OR (OLD.review_stage = 'acceptance'   AND NEW.review_stage = 'decided') ) THEN
      RAISE EXCEPTION 'evidence review_stage may only move forward';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER evidence_immutable
BEFORE UPDATE OR DELETE ON public.evidence_items
FOR EACH ROW EXECUTE FUNCTION public.trg_evidence_immutable();

-- evidence_reviews insert gate — FR-EVD-03/05, FR-ACC-01/02. Enforced on every
-- insert (direct or RPC): correct stage for the role, no self-review.
CREATE FUNCTION public.trg_evidence_review_gate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ev record; v_client uuid;
BEGIN
  SELECT e.id, e.programme_id, e.uploaded_by, e.review_stage
    INTO v_ev FROM public.evidence_items e WHERE e.id = NEW.evidence_item_id;
  IF v_ev IS NULL THEN RAISE EXCEPTION 'evidence item not found'; END IF;
  SELECT client_org_id INTO v_client FROM public.programmes WHERE id = v_ev.programme_id;

  IF auth.uid() IS NOT NULL THEN
    IF NEW.reviewer IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'reviewer must be the calling user';
    END IF;
    IF v_ev.uploaded_by = auth.uid() THEN
      RAISE EXCEPTION 'nobody may verify or accept evidence they uploaded (FR-ACC-01)';
    END IF;
    IF NEW.stage = 'verify' AND NOT public.has_programme_role(
        v_ev.programme_id, ARRAY['partner_admin','partner_consultant','programme_lead']) THEN
      RAISE EXCEPTION 'only the programme lead or partner consultant may verify evidence (FR-EVD-03)';
    END IF;
    IF NEW.stage = 'accept' AND NOT public.is_ao_or_alternate(v_client) THEN
      RAISE EXCEPTION 'only the accountable officer or named alternate may accept evidence (FR-ACC-02)';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER evidence_review_gate
BEFORE INSERT ON public.evidence_reviews
FOR EACH ROW EXECUTE FUNCTION public.trg_evidence_review_gate();

-- evidence_offers: source programme ≠ target; decision is one-way and stamps
-- decided_by/decided_at itself.
CREATE FUNCTION public.trg_evidence_offer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.to_programme_id =
       (SELECT programme_id FROM public.evidence_items WHERE id = NEW.evidence_item_id) THEN
      RAISE EXCEPTION 'an evidence offer must target a different programme';
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE
  IF OLD.outcome IS NOT NULL THEN
    RAISE EXCEPTION 'evidence offer already decided — offers are decided once';
  END IF;
  IF NEW.outcome IS NOT NULL AND NEW.outcome IS DISTINCT FROM OLD.outcome THEN
    NEW.decided_at := now();
    NEW.decided_by := auth.uid();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER evidence_offer_gate
BEFORE INSERT OR UPDATE ON public.evidence_offers
FOR EACH ROW EXECUTE FUNCTION public.trg_evidence_offer();

-- programme_reports: FR-RPT-04 ordered workflow + AO gate on signing + §9.5
-- issued-report immutability. Runs on every write path.
CREATE FUNCTION public.trg_report_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'issued' THEN
      RAISE EXCEPTION 'an issued report cannot be deleted (§9.5)';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'issued' THEN
    RAISE EXCEPTION 'an issued report cannot change afterwards (§9.5)';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT ( (OLD.status = 'draft'           AND NEW.status = 'inputs_complete')
          OR (OLD.status = 'inputs_complete' AND NEW.status IN ('ao_review','draft'))
          OR (OLD.status = 'ao_review'       AND NEW.status IN ('signed','inputs_complete'))
          OR (OLD.status = 'signed'          AND NEW.status = 'issued') ) THEN
      RAISE EXCEPTION 'illegal report transition % → % (FR-RPT-04)', OLD.status, NEW.status;
    END IF;
    IF NEW.status = 'signed' AND auth.uid() IS NOT NULL
       AND NOT public.is_ao_or_alternate(
                 (SELECT client_org_id FROM public.programmes WHERE id = NEW.programme_id)) THEN
      RAISE EXCEPTION 'only the accountable officer or named alternate may sign the monthly report';
    END IF;
    IF NEW.status = 'issued' THEN
      NEW.issued_on := now();
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER report_transition_gate
BEFORE UPDATE OR DELETE ON public.programme_reports
FOR EACH ROW EXECUTE FUNCTION public.trg_report_transition();

-- T5: the breach notification decision (regulator_notification) may only be
-- recorded by the AO or named alternate (FR-OPS-03, FR-ACC-02). Column-level
-- grants already keep it out of authenticated writes; this trigger is the
-- second line inside definer RPCs.
CREATE FUNCTION public.trg_oprecord_regulator() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF NEW.regulator_notification IS DISTINCT FROM OLD.regulator_notification THEN
    IF NOT public.is_ao_or_alternate(NEW.client_org_id) THEN
      RAISE EXCEPTION 'only the accountable officer or named alternate may record a regulator notification decision (FR-ACC-02)';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER oprecord_regulator_gate
BEFORE UPDATE ON public.operational_records
FOR EACH ROW EXECUTE FUNCTION public.trg_oprecord_regulator();

-- maintenance instances stay inside the template's programme
CREATE FUNCTION public.trg_mti_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.exception_raid_item_id IS NOT NULL
     AND (SELECT programme_id FROM public.raid_items WHERE id = NEW.exception_raid_item_id)
         IS DISTINCT FROM
         (SELECT programme_id FROM public.maintenance_task_templates WHERE id = NEW.task_template_id) THEN
    RAISE EXCEPTION 'exception RAID item must belong to the same programme as the task template';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER mti_scope_check
BEFORE INSERT OR UPDATE ON public.maintenance_task_instances
FOR EACH ROW EXECUTE FUNCTION public.trg_mti_scope();

-- kpi actual evidence must come from the same programme as the kpi
CREATE FUNCTION public.trg_kpi_actual_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.evidence_id IS NOT NULL
     AND (SELECT programme_id FROM public.evidence_items WHERE id = NEW.evidence_id)
         IS DISTINCT FROM
         (SELECT programme_id FROM public.kpis WHERE id = NEW.kpi_id) THEN
    RAISE EXCEPTION 'kpi actual evidence must belong to the same programme';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER kpi_actual_scope_check
BEFORE INSERT OR UPDATE ON public.kpi_actuals
FOR EACH ROW EXECUTE FUNCTION public.trg_kpi_actual_scope();


-- ---------- 4. RLS: enable + force, policy per template, column grants ----------
-- REVOKE ALL first everywhere (the image's default privileges grant ALL on
-- new tables to anon/authenticated/service_role — column-scoping only works
-- after the table-level grants are removed). service_role is the trusted
-- backend role and keeps its default grant, same convention as W0-00.

ALTER TABLE public.programmes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programmes FORCE ROW LEVEL SECURITY;
CREATE POLICY programmes_read ON public.programmes FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs())
         OR id IN (SELECT public.allowed_programmes()));
CREATE POLICY programmes_insert ON public.programmes FOR INSERT TO authenticated
  WITH CHECK (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY programmes_update ON public.programmes FOR UPDATE TO authenticated
  USING (public.has_programme_role(id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_programme_role(id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.programmes FROM anon, authenticated;
GRANT SELECT ON public.programmes TO authenticated;
GRANT INSERT (client_org_id, template_version_id, name, start_date, total_weeks,
              programme_lead, red_days_threshold, report_due_business_day,
              reduced_capacity_weeks, programme_rag, rag_override_reason)
  ON public.programmes TO authenticated;
GRANT UPDATE (name, start_date, total_weeks, programme_lead, red_days_threshold,
              report_due_business_day, reduced_capacity_weeks, programme_rag,
              rag_override_reason)
  ON public.programmes TO authenticated;

ALTER TABLE public.phases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.phases FORCE ROW LEVEL SECURITY;
CREATE POLICY phases_read ON public.phases FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
CREATE POLICY phases_insert ON public.phases FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY phases_update ON public.phases FOR UPDATE TO authenticated
  USING (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.phases FROM anon, authenticated;
GRANT SELECT ON public.phases TO authenticated;
GRANT INSERT (programme_id, number, name, start_week, end_week) ON public.phases TO authenticated;
GRANT UPDATE (number, name, start_week, end_week) ON public.phases TO authenticated;

ALTER TABLE public.workstreams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workstreams FORCE ROW LEVEL SECURITY;
CREATE POLICY workstreams_read ON public.workstreams FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes())
         OR EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()) a
                    WHERE a.scope_type = 'workstream' AND a.scope_id = workstreams.id));
CREATE POLICY workstreams_insert ON public.workstreams FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY workstreams_update ON public.workstreams FOR UPDATE TO authenticated
  USING (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.workstreams FROM anon, authenticated;
GRANT SELECT ON public.workstreams TO authenticated;
GRANT INSERT (programme_id, name, accountable_lead, deputy, rag_override, rag_override_reason)
  ON public.workstreams TO authenticated;
GRANT UPDATE (name, accountable_lead, deputy, rag_override, rag_override_reason)
  ON public.workstreams TO authenticated;

ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activities FORCE ROW LEVEL SECURITY;
-- T3 read: visible via the workstream's programme chain, a direct
-- workstream-scope assignment, or the programme itself (workstream_id NULL
-- rows rely on the programme leg).
CREATE POLICY activities_read ON public.activities FOR SELECT TO authenticated
USING (
  (workstream_id IS NOT NULL AND EXISTS (
     SELECT 1 FROM public.workstreams w JOIN public.programmes p ON p.id = w.programme_id
     WHERE w.id = activities.workstream_id
       AND (p.client_org_id IN (SELECT public.allowed_client_orgs())
            OR p.id IN (SELECT public.allowed_programmes()))))
  OR (workstream_id IS NOT NULL AND EXISTS (
     SELECT 1 FROM public.active_assignments(auth.uid()) a
     WHERE a.scope_type = 'workstream' AND a.scope_id = activities.workstream_id))
  OR (workstream_id IS NULL AND programme_id IN (SELECT public.allowed_programmes()))
);
CREATE POLICY activities_insert ON public.activities FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
-- T3 write: status/editing roles include workstream_lead + external_provider
-- at their own scope (§4.2 "Update activity status: Own"), plus any listed lead.
CREATE POLICY activities_update ON public.activities FOR UPDATE TO authenticated
  USING (public.has_activity_role(id,
           ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
                 'workstream_lead','external_provider'])
         OR auth.uid() = ANY(leads))
  WITH CHECK (public.has_activity_role(id,
           ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
                 'workstream_lead','external_provider'])
         OR auth.uid() = ANY(leads));
REVOKE ALL ON public.activities FROM anon, authenticated;
GRANT SELECT ON public.activities TO authenticated;
GRANT INSERT (programme_id, workstream_id, ref, text, leads, start_week, end_week,
              milestone, evidence_required, status, pct_complete, actual_completion,
              flag, comments, recovery_date, dependency_override_reason)
  ON public.activities TO authenticated;
GRANT UPDATE (workstream_id, ref, text, leads, start_week, end_week, milestone,
              evidence_required, status, pct_complete, actual_completion, flag,
              comments, recovery_date, dependency_override_reason)
  ON public.activities TO authenticated;

ALTER TABLE public.activity_deps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_deps FORCE ROW LEVEL SECURITY;
CREATE POLICY activity_deps_read ON public.activity_deps FOR SELECT TO authenticated
  USING (activity_id IN (SELECT a.id FROM public.activities a));
CREATE POLICY activity_deps_insert ON public.activity_deps FOR INSERT TO authenticated
  WITH CHECK (public.has_activity_role(activity_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY activity_deps_delete ON public.activity_deps FOR DELETE TO authenticated
  USING (public.has_activity_role(activity_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.activity_deps FROM anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.activity_deps TO authenticated;

ALTER TABLE public.activity_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_status_history FORCE ROW LEVEL SECURITY;
CREATE POLICY activity_status_history_read ON public.activity_status_history
  FOR SELECT TO authenticated
  USING (activity_id IN (SELECT a.id FROM public.activities a));
REVOKE ALL ON public.activity_status_history FROM anon, authenticated;
GRANT SELECT ON public.activity_status_history TO authenticated;
-- APPEND ONLY: rows are written by trg_activity_status_history (definer) —
-- no INSERT policy; REVOKE UPDATE/DELETE is defence in depth.
REVOKE UPDATE, DELETE ON public.activity_status_history FROM authenticated;

ALTER TABLE public.register_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.register_items FORCE ROW LEVEL SECURITY;
CREATE POLICY register_items_read ON public.register_items FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
CREATE POLICY register_items_insert ON public.register_items FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY register_items_update ON public.register_items FOR UPDATE TO authenticated
  USING (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','accountable_officer']))
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','accountable_officer']));
REVOKE ALL ON public.register_items FROM anon, authenticated;
GRANT SELECT ON public.register_items TO authenticated;
GRANT INSERT (programme_id, ref, finding, priority, assessment_window, lead,
              planned_close_week, status) ON public.register_items TO authenticated;
GRANT UPDATE (ref, finding, priority, assessment_window, lead, planned_close_week,
              status, reopen_reason) ON public.register_items TO authenticated;

ALTER TABLE public.register_item_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.register_item_activities FORCE ROW LEVEL SECURITY;
CREATE POLICY register_item_activities_read ON public.register_item_activities
  FOR SELECT TO authenticated
  USING (register_item_id IN (SELECT r.id FROM public.register_items r));
CREATE POLICY register_item_activities_insert ON public.register_item_activities
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.register_items r
                      WHERE r.id = register_item_id
                        AND public.has_programme_role(r.programme_id,
                          ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])));
CREATE POLICY register_item_activities_delete ON public.register_item_activities
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.register_items r
                 WHERE r.id = register_item_id
                   AND public.has_programme_role(r.programme_id,
                     ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])));
REVOKE ALL ON public.register_item_activities FROM anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.register_item_activities TO authenticated;

ALTER TABLE public.evidence_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evidence_items FORCE ROW LEVEL SECURITY;
-- T2 + T4: programme visibility, plus the uploader always sees own items.
CREATE POLICY evidence_items_read ON public.evidence_items FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes())
         OR uploaded_by = auth.uid());
CREATE POLICY evidence_items_insert ON public.evidence_items FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
          'workstream_lead','external_provider'])
    OR (activity_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.activities a WHERE a.id = activity_id
          AND auth.uid() = ANY(a.leads))));
CREATE POLICY evidence_items_update ON public.evidence_items FOR UPDATE TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes())
         OR uploaded_by = auth.uid())
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])
    OR uploaded_by = auth.uid());
REVOKE ALL ON public.evidence_items FROM anon, authenticated;
GRANT SELECT ON public.evidence_items TO authenticated;
GRANT INSERT (programme_id, activity_id, register_item_id, site, file_key, link)
  ON public.evidence_items TO authenticated;
GRANT UPDATE (site, link, activity_id, register_item_id)
  ON public.evidence_items TO authenticated;
-- decided rows immutable by trigger; DELETE never granted.

ALTER TABLE public.evidence_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evidence_reviews FORCE ROW LEVEL SECURITY;
CREATE POLICY evidence_reviews_read ON public.evidence_reviews FOR SELECT TO authenticated
  USING (evidence_item_id IN (SELECT e.id FROM public.evidence_items e));
CREATE POLICY evidence_reviews_insert ON public.evidence_reviews FOR INSERT TO authenticated
  WITH CHECK (evidence_item_id IN (SELECT e.id FROM public.evidence_items e)
              AND reviewer = auth.uid());
REVOKE ALL ON public.evidence_reviews FROM anon, authenticated;
GRANT SELECT ON public.evidence_reviews TO authenticated;
GRANT INSERT (evidence_item_id, stage, decision, reasons) ON public.evidence_reviews TO authenticated;
-- APPEND ONLY
REVOKE UPDATE, DELETE ON public.evidence_reviews FROM authenticated;

ALTER TABLE public.evidence_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evidence_offers FORCE ROW LEVEL SECURITY;
CREATE POLICY evidence_offers_read ON public.evidence_offers FOR SELECT TO authenticated
  USING (evidence_item_id IN (SELECT e.id FROM public.evidence_items e)
         OR to_programme_id IN (SELECT public.allowed_programmes()));
CREATE POLICY evidence_offers_insert ON public.evidence_offers FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.evidence_items e
                      WHERE e.id = evidence_item_id
                        AND public.has_programme_role(e.programme_id,
                          ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])));
CREATE POLICY evidence_offers_update ON public.evidence_offers FOR UPDATE TO authenticated
  USING (to_programme_id IN (SELECT public.allowed_programmes()))
  WITH CHECK (public.has_programme_role(to_programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','accountable_officer']));
REVOKE ALL ON public.evidence_offers FROM anon, authenticated;
GRANT SELECT ON public.evidence_offers TO authenticated;
GRANT INSERT (evidence_item_id, to_programme_id, mapped_requirement)
  ON public.evidence_offers TO authenticated;
GRANT UPDATE (outcome) ON public.evidence_offers TO authenticated;   -- trigger stamps decided_*

ALTER TABLE public.weekly_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_logs FORCE ROW LEVEL SECURITY;
CREATE POLICY weekly_logs_read ON public.weekly_logs FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
CREATE POLICY weekly_logs_insert ON public.weekly_logs FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY weekly_logs_update ON public.weekly_logs FOR UPDATE TO authenticated
  USING (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.weekly_logs FROM anon, authenticated;
GRANT SELECT ON public.weekly_logs TO authenticated;
GRANT INSERT (programme_id, week, session_held, completed, planned_next, blockers, decisions)
  ON public.weekly_logs TO authenticated;
GRANT UPDATE (session_held, completed, planned_next, blockers, decisions)
  ON public.weekly_logs TO authenticated;

ALTER TABLE public.kpis ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kpis FORCE ROW LEVEL SECURITY;
CREATE POLICY kpis_read ON public.kpis FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
CREATE POLICY kpis_insert ON public.kpis FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY kpis_update ON public.kpis FOR UPDATE TO authenticated
  USING (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.kpis FROM anon, authenticated;
GRANT SELECT ON public.kpis TO authenticated;
GRANT INSERT (programme_id, name, unit, baseline, target, calculation, auto_calc,
              target_proposed, sort) ON public.kpis TO authenticated;
GRANT UPDATE (name, unit, baseline, target, calculation, auto_calc, target_proposed, sort)
  ON public.kpis TO authenticated;

ALTER TABLE public.kpi_actuals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kpi_actuals FORCE ROW LEVEL SECURITY;
CREATE POLICY kpi_actuals_read ON public.kpi_actuals FOR SELECT TO authenticated
  USING (kpi_id IN (SELECT k.id FROM public.kpis k));
CREATE POLICY kpi_actuals_insert ON public.kpi_actuals FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.kpis k
                      WHERE k.id = kpi_id
                        AND public.has_programme_role(k.programme_id,
                          ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])));
CREATE POLICY kpi_actuals_update ON public.kpi_actuals FOR UPDATE TO authenticated
  USING (kpi_id IN (SELECT k.id FROM public.kpis k))
  WITH CHECK (EXISTS (SELECT 1 FROM public.kpis k
                      WHERE k.id = kpi_id
                        AND public.has_programme_role(k.programme_id,
                          ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])));
REVOKE ALL ON public.kpi_actuals FROM anon, authenticated;
GRANT SELECT ON public.kpi_actuals TO authenticated;
GRANT INSERT (kpi_id, month, value, evidence_id) ON public.kpi_actuals TO authenticated;
GRANT UPDATE (month, value, evidence_id) ON public.kpi_actuals TO authenticated;

ALTER TABLE public.raid_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.raid_items FORCE ROW LEVEL SECURITY;
CREATE POLICY raid_items_read ON public.raid_items FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
CREATE POLICY raid_items_insert ON public.raid_items FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','executive','accountable_officer']));
CREATE POLICY raid_items_update ON public.raid_items FOR UPDATE TO authenticated
  USING (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.raid_items FROM anon, authenticated;
GRANT SELECT ON public.raid_items TO authenticated;
GRANT INSERT (programme_id, type, description, impact, action, owner, raised_on,
              review_by, status) ON public.raid_items TO authenticated;
GRANT UPDATE (type, description, impact, action, owner, review_by, status)
  ON public.raid_items TO authenticated;

ALTER TABLE public.decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.decisions FORCE ROW LEVEL SECURITY;
CREATE POLICY decisions_read ON public.decisions FOR SELECT TO authenticated
  USING (raid_item_id IN (SELECT r.id FROM public.raid_items r));
CREATE POLICY decisions_insert ON public.decisions FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.raid_items r
                      WHERE r.id = raid_item_id
                        AND public.has_programme_role(r.programme_id,
                          ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','executive','accountable_officer'])));
REVOKE ALL ON public.decisions FROM anon, authenticated;
GRANT SELECT ON public.decisions TO authenticated;
GRANT INSERT (raid_item_id, outcome, decided_on, minute_ref, unlocks) ON public.decisions TO authenticated;
-- APPEND ONLY
REVOKE UPDATE, DELETE ON public.decisions FROM authenticated;

ALTER TABLE public.external_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.external_providers FORCE ROW LEVEL SECURITY;
CREATE POLICY external_providers_read ON public.external_providers FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
CREATE POLICY external_providers_insert ON public.external_providers FOR INSERT TO authenticated
  WITH CHECK (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY external_providers_update ON public.external_providers FOR UPDATE TO authenticated
  USING (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.external_providers FROM anon, authenticated;
GRANT SELECT ON public.external_providers TO authenticated;
GRANT INSERT (client_org_id, name, kind, contact_email, channel, active)
  ON public.external_providers TO authenticated;
GRANT UPDATE (name, kind, contact_email, channel, active)
  ON public.external_providers TO authenticated;

ALTER TABLE public.maintenance_task_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.maintenance_task_templates FORCE ROW LEVEL SECURITY;
CREATE POLICY mtt_read ON public.maintenance_task_templates FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes())
         OR programme_id IS NULL);          -- template-version rows are content (§8.9)
CREATE POLICY mtt_insert ON public.maintenance_task_templates FOR INSERT TO authenticated
  WITH CHECK (programme_id IS NOT NULL
              AND public.has_programme_role(programme_id,
                ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY mtt_update ON public.maintenance_task_templates FOR UPDATE TO authenticated
  USING (programme_id IS NOT NULL
         AND public.has_programme_role(programme_id,
           ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (programme_id IS NOT NULL
              AND public.has_programme_role(programme_id,
                ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.maintenance_task_templates FROM anon, authenticated;
GRANT SELECT ON public.maintenance_task_templates TO authenticated;
GRANT INSERT (programme_id, template_version_id, code, task, timing_rule, owner_role,
              input_from_label, input_from_provider_id, evidence_produced, feeds,
              active_from_rule, active, sort) ON public.maintenance_task_templates TO authenticated;
GRANT UPDATE (code, task, timing_rule, owner_role, input_from_label,
              input_from_provider_id, evidence_produced, feeds, active_from_rule,
              active, sort) ON public.maintenance_task_templates TO authenticated;

ALTER TABLE public.maintenance_task_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.maintenance_task_instances FORCE ROW LEVEL SECURITY;
CREATE POLICY mti_read ON public.maintenance_task_instances FOR SELECT TO authenticated
  USING (task_template_id IN (SELECT t.id FROM public.maintenance_task_templates t));
CREATE POLICY mti_insert ON public.maintenance_task_instances FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.maintenance_task_templates t
                      WHERE t.id = task_template_id AND t.programme_id IS NOT NULL
                        AND public.has_programme_role(t.programme_id,
                          ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
                                'workstream_lead','external_provider','accountable_officer'])));
CREATE POLICY mti_update ON public.maintenance_task_instances FOR UPDATE TO authenticated
  USING (task_template_id IN (SELECT t.id FROM public.maintenance_task_templates t))
  WITH CHECK (EXISTS (SELECT 1 FROM public.maintenance_task_templates t
                      WHERE t.id = task_template_id AND t.programme_id IS NOT NULL
                        AND public.has_programme_role(t.programme_id,
                          ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
                                'workstream_lead','external_provider','accountable_officer'])));
REVOKE ALL ON public.maintenance_task_instances FROM anon, authenticated;
GRANT SELECT ON public.maintenance_task_instances TO authenticated;
GRANT INSERT (task_template_id, period, assignee, status, evidence_id,
              evidence_exempt_reason, exception_reason, exception_raid_item_id,
              completed_on) ON public.maintenance_task_instances TO authenticated;
GRANT UPDATE (assignee, status, evidence_id, evidence_exempt_reason,
              exception_reason, exception_raid_item_id, completed_on)
  ON public.maintenance_task_instances TO authenticated;

ALTER TABLE public.checklist_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.checklist_instances FORCE ROW LEVEL SECURITY;
CREATE POLICY checklist_instances_read ON public.checklist_instances FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
CREATE POLICY checklist_instances_insert ON public.checklist_instances FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY checklist_instances_update ON public.checklist_instances FOR UPDATE TO authenticated
  USING (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.checklist_instances FROM anon, authenticated;
GRANT SELECT ON public.checklist_instances TO authenticated;
GRANT INSERT (programme_id, kind, period, items) ON public.checklist_instances TO authenticated;
GRANT UPDATE (items) ON public.checklist_instances TO authenticated;

ALTER TABLE public.operational_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operational_records FORCE ROW LEVEL SECURITY;
CREATE POLICY operational_records_read ON public.operational_records FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
-- FR-OPS-04: ANY authenticated user with client visibility can report (breach
-- especially) — the write gate is deliberately not role-restricted on insert.
CREATE POLICY operational_records_insert ON public.operational_records
  FOR INSERT TO authenticated
  WITH CHECK (client_org_id IN (SELECT public.allowed_client_orgs()));
CREATE POLICY operational_records_update ON public.operational_records FOR UPDATE TO authenticated
  USING (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','accountable_officer']))
  WITH CHECK (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','accountable_officer']));
REVOKE ALL ON public.operational_records FROM anon, authenticated;
GRANT SELECT ON public.operational_records TO authenticated;
GRANT INSERT (client_org_id, type, description, reported_at, site, channel,
              deadline_rule, deadline_params, status, outcome)
  ON public.operational_records TO authenticated;
GRANT UPDATE (description, site, channel, deadline_rule, deadline_params, status, outcome)
  ON public.operational_records TO authenticated;

ALTER TABLE public.training_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.training_records FORCE ROW LEVEL SECURITY;
CREATE POLICY training_records_read ON public.training_records FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
CREATE POLICY training_records_insert ON public.training_records FOR INSERT TO authenticated
  WITH CHECK (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY training_records_update ON public.training_records FOR UPDATE TO authenticated
  USING (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.training_records FROM anon, authenticated;
GRANT SELECT ON public.training_records TO authenticated;
GRANT INSERT (client_org_id, person, site, functional_group, session, date, attendance)
  ON public.training_records TO authenticated;
GRANT UPDATE (person, site, functional_group, session, date, attendance)
  ON public.training_records TO authenticated;

ALTER TABLE public.controlled_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.controlled_documents FORCE ROW LEVEL SECURITY;
CREATE POLICY controlled_documents_read ON public.controlled_documents FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
CREATE POLICY controlled_documents_insert ON public.controlled_documents FOR INSERT TO authenticated
  WITH CHECK (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY controlled_documents_update ON public.controlled_documents FOR UPDATE TO authenticated
  USING (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']))
  WITH CHECK (public.has_client_role(client_org_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
REVOKE ALL ON public.controlled_documents FROM anon, authenticated;
GRANT SELECT ON public.controlled_documents TO authenticated;
GRANT INSERT (client_org_id, reference, title, version, owner, approval_date,
              next_review_date) ON public.controlled_documents TO authenticated;
GRANT UPDATE (reference, title, version, owner, approval_date, next_review_date)
  ON public.controlled_documents TO authenticated;

ALTER TABLE public.controlled_document_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.controlled_document_activities FORCE ROW LEVEL SECURITY;
CREATE POLICY cda_read ON public.controlled_document_activities FOR SELECT TO authenticated
  USING (controlled_document_id IN (SELECT d.id FROM public.controlled_documents d));
CREATE POLICY cda_insert ON public.controlled_document_activities FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.controlled_documents d
                      WHERE d.id = controlled_document_id
                        AND public.has_client_role(d.client_org_id,
                          ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])));
CREATE POLICY cda_delete ON public.controlled_document_activities FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.controlled_documents d
                 WHERE d.id = controlled_document_id
                   AND public.has_client_role(d.client_org_id,
                     ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])));
REVOKE ALL ON public.controlled_document_activities FROM anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.controlled_document_activities TO authenticated;

ALTER TABLE public.monthly_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monthly_snapshots FORCE ROW LEVEL SECURITY;
CREATE POLICY monthly_snapshots_read ON public.monthly_snapshots FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
REVOKE ALL ON public.monthly_snapshots FROM anon, authenticated;
GRANT SELECT ON public.monthly_snapshots TO authenticated;
-- APPEND ONLY, engine-written (last-business-day job): no INSERT/UPDATE policy.
REVOKE UPDATE, DELETE ON public.monthly_snapshots FROM authenticated;

ALTER TABLE public.programme_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programme_reports FORCE ROW LEVEL SECURITY;
CREATE POLICY programme_reports_read ON public.programme_reports FOR SELECT TO authenticated
  USING (programme_id IN (SELECT public.allowed_programmes()));
CREATE POLICY programme_reports_insert ON public.programme_reports FOR INSERT TO authenticated
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']));
CREATE POLICY programme_reports_update ON public.programme_reports FOR UPDATE TO authenticated
  USING (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','accountable_officer']))
  WITH CHECK (public.has_programme_role(programme_id,
    ARRAY['partner_admin','partner_consultant','programme_lead','client_admin','accountable_officer']));
REVOKE ALL ON public.programme_reports FROM anon, authenticated;
GRANT SELECT ON public.programme_reports TO authenticated;
GRANT INSERT (programme_id, period, sections, overall_rag, trend, headline,
              commentary, gate_override_reason) ON public.programme_reports TO authenticated;
GRANT UPDATE (sections, overall_rag, trend, headline, commentary, status,
              gate_override_reason) ON public.programme_reports TO authenticated;

ALTER TABLE public.notification_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_events FORCE ROW LEVEL SECURITY;
-- read is driven by the scope claim, checked defensively (presence before cast)
CREATE POLICY notification_events_read ON public.notification_events FOR SELECT TO authenticated
USING (
   (scope ? 'client_org_id' AND (scope->>'client_org_id')::uuid IN (SELECT public.allowed_client_orgs()))
OR (scope ? 'programme_id'  AND (scope->>'programme_id')::uuid  IN (SELECT public.allowed_programmes()))
OR (scope ? 'practice_id'   AND public.has_partner_role((scope->>'practice_id')::uuid,
                                ARRAY['partner_admin','partner_consultant','read_only']))
OR (scope ? 'user_id'       AND scope->>'user_id' = auth.uid()::text)
);
REVOKE ALL ON public.notification_events FROM anon, authenticated;
GRANT SELECT ON public.notification_events TO authenticated;
-- outbox: engines emit + the dispatcher stamps dispatched_at, both definer-side.
REVOKE UPDATE, DELETE ON public.notification_events FROM authenticated;

ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_preferences FORCE ROW LEVEL SECURITY;
CREATE POLICY notification_preferences_all ON public.notification_preferences FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
REVOKE ALL ON public.notification_preferences FROM anon, authenticated;
GRANT SELECT, DELETE ON public.notification_preferences TO authenticated;
GRANT INSERT (user_id, digest, kinds) ON public.notification_preferences TO authenticated;
GRANT UPDATE (digest, kinds) ON public.notification_preferences TO authenticated;

ALTER TABLE public.scheduled_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scheduled_jobs FORCE ROW LEVEL SECURITY;
CREATE POLICY scheduled_jobs_read ON public.scheduled_jobs FOR SELECT TO authenticated
  USING (true);                                            -- catalogue, no tenant data
REVOKE ALL ON public.scheduled_jobs FROM anon, authenticated;
GRANT SELECT ON public.scheduled_jobs TO authenticated;

ALTER TABLE public.job_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_runs FORCE ROW LEVEL SECURITY;
CREATE POLICY job_runs_read ON public.job_runs FOR SELECT TO authenticated
  USING (true);                                            -- ops ledger, no tenant data
REVOKE ALL ON public.job_runs FROM anon, authenticated;
GRANT SELECT ON public.job_runs TO authenticated;
-- APPEND ONLY (runner finishes rows via definer).
REVOKE UPDATE, DELETE ON public.job_runs FROM authenticated;

-- lock function execution surface (W0-00 convention)
REVOKE EXECUTE ON FUNCTION
  public.programme_client(uuid),
  public.has_programme_role(uuid, text[]),
  public.has_client_role(uuid, text[]),
  public.has_workstream_role(uuid, text[]),
  public.has_activity_role(uuid, text[]),
  public.holds_designation(uuid, text[]),
  public.is_ao_or_alternate(uuid),
  public.trg_activity_completion(),
  public.trg_activity_status_history(),
  public.trg_activity_dep_scope(),
  public.trg_register_closure(),
  public.trg_evidence_scope(),
  public.trg_evidence_immutable(),
  public.trg_evidence_review_gate(),
  public.trg_evidence_offer(),
  public.trg_report_transition(),
  public.trg_oprecord_regulator(),
  public.trg_mti_scope(),
  public.trg_kpi_actual_scope()
FROM anon, public, authenticated;
GRANT EXECUTE ON FUNCTION
  public.programme_client(uuid),
  public.has_programme_role(uuid, text[]),
  public.has_client_role(uuid, text[]),
  public.has_workstream_role(uuid, text[]),
  public.has_activity_role(uuid, text[]),
  public.holds_designation(uuid, text[]),
  public.is_ao_or_alternate(uuid)
TO authenticated;
