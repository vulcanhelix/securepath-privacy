-- ============================================================================
-- W4-04 (#51) — client exit: full export + timed deletion + deletion
-- certificate. Spec NFR-14 "on client exit, a full export is provided and the
-- data is deleted within a configurable period, with a deletion certificate";
-- AT-20 "Client exits — Full export produced; data deleted after the set
-- period; deletion certificate issued".
--
-- LIFECYCLE (explicit, logged — the spine rule: a stage never advances as a
-- side effect):
--
--   requested ──► export_issued ──► deleted ──► certified      (terminal)
--        └──────────┴──► cancelled                              (terminal,
--                                                              pre-delete only)
--
--   request_client_exit          partner_admin on the owning practice, or the
--     client's own accountable_officer / client_admin at client scope (spec
--     §4 roles — exit authorisation mirrors who owns the contract chain:
--     NFR-13 partner→client). No anonymous/service caller: the certificate
--     must name WHO authorised, so auth.uid() is required on every mutating
--     RPC.
--   issue_exit_export            same authoriser; builds the NFR-14 "full
--     export" as one JSONB payload (every client-scoped row, full fidelity
--     via to_jsonb — the machine export; the W3-04 rowset exports stay the
--     human/formats surface). Re-issuable until deletion runs. Sets
--     export_manifest (sections + row counts + sha256 + byte size) — the
--     manifest, not the payload, is retained.
--   execute_client_exit          same authoriser; refuses until
--     deletion_due_on <= today — the configurable period is honoured, not
--     advisory (retention_days 0..3650, default 30, set at request). Deletes
--     every row of client data in dependency order, tombstones client_orgs
--     (exited_at), writes billing_events 'instance.deleted' + the audit row.
--   issue_deletion_certificate   same authoriser; mints the immutable
--     certificate: what was deleted (per-table counts), when, retention
--     honoured, who requested/executed/issued, what was deliberately
--     retained, and the storage-object keys released for purge (SQL cannot
--     reach object storage — the manifest is the purge list).
--   cancel_client_exit           same authoriser; requested/export_issued
--     only — once deletion has run there is nothing to cancel.
--
-- DELETION SCOPE (the whole client estate — the audit-trigger inventory is
-- the checklist): programmes and their entire engine tree (phases,
-- workstreams, activities+deps+status history, register items+links,
-- evidence items+offers+reviews, KPIs+actuals, RAID items+status history+
-- decisions, maintenance templates+instances, checklists+completions,
-- monthly snapshots, weekly logs, programme reports); the stage-0..6
-- pipeline (tracks+transitions, assessment sessions+responses+scores+
-- reports, documents+links, policies, manuals, tasks, monthly reports);
-- client registers (operational records, training records, controlled
-- documents+activity links, external providers, designations); awareness
-- cohorts+respondents+responses; support-access requests+grants;
-- consultant assignments; client-scoped role assignments; client invites;
-- client-scoped notification outbox rows; malware-scan queue entries.
--
-- IMMUTABLE-OBJECT DELETES: decided evidence, issued programme reports and
-- the append-only decisions/raid_status_history ledgers refuse every delete
-- by trigger (NFR-09 / W1-06). execute_client_exit suspends exactly those
-- NAMED guards inside its transaction (same convention as the fixture
-- wipes' DISABLE TRIGGER USER) — the audit_events triggers stay live, so
-- every deleted row is still field-level captured before it disappears.
-- checklist_item_completions needs no suspension: its guard already permits
-- the cascade delete once the parent is gone.
--
-- RETAINED BY DESIGN (the certificate says so, so "what was deleted" is
-- provable): the client_orgs tombstone row (identity anchor for billing +
-- audit + this certificate), audit_log / audit_events (NFR-08 append-only —
-- the deletion itself is audited here), billing_events incl. the new
-- 'instance.deleted' row (the partner's invoicing ledger), approvals (the
-- partner-scoped gate ledger), notifications (partner-scoped), users/auth
-- accounts (platform accounts; every client-scoped role assignment is
-- removed), import_runs (partner staging; programme links null by FK), and
-- the exit record + certificate themselves. No legal-hold concept exists in
-- the spec: the retention window + cancel path is the hold — a hold is
-- honoured simply by not executing / by cancelling before the due date.
-- storage objects: DB rows and the key manifest are deleted/issued here;
-- object purge is the storage layer's follow-up from storage_keys.
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- digest() for the certificate hash

-- ---------- tombstone marker on the org shell ----------
ALTER TABLE public.client_orgs
  ADD COLUMN IF NOT EXISTS exited_at timestamptz;
COMMENT ON COLUMN public.client_orgs.exited_at IS
  'W4-04 NFR-14: set by execute_client_exit when the timed deletion ran. The '
  'row is a retained tombstone — identity anchor for billing_events, the '
  'audit trail and the deletion certificate; all client data is gone. NULL = live.';

-- ---------- the lifecycle record ----------
CREATE TABLE public.client_exits (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    practice_id      uuid NOT NULL REFERENCES public.practices(id),
    client_org_id    uuid NOT NULL REFERENCES public.client_orgs(id),
    status           text NOT NULL DEFAULT 'requested'
                     CHECK (status IN ('requested','export_issued','deleted',
                                       'certified','cancelled')),
    reason           text,
    retention_days   int  NOT NULL DEFAULT 30
                     CHECK (retention_days BETWEEN 0 AND 3650),
    deletion_due_on  date NOT NULL,                 -- requested_at + retention
    requested_by     uuid NOT NULL,                 -- the authoriser (spec: who)
    requested_at     timestamptz NOT NULL DEFAULT now(),
    export_manifest  jsonb,                         -- sections + counts + hash
    export_issued_by uuid,
    export_issued_at timestamptz,
    deletion_summary jsonb,                         -- counts + retained + keys
    deleted_by       uuid,
    deleted_at       timestamptz,
    certificate_id   uuid,                          -- FK added below (circular)
    cancelled_by     uuid,
    cancelled_at     timestamptz,
    cancel_reason    text,
    created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.client_exits IS
  'W4-04 NFR-14/AT-20: the client-exit lifecycle — requested → export_issued '
  '→ deleted → certified (or cancelled pre-delete). RPC-written only (RLS '
  'on, no policies); reads via list_client_exits. One OPEN exit per client '
  '(partial unique index).';

-- at most one open (pre-terminal) exit per client
CREATE UNIQUE INDEX client_exits_one_open
  ON public.client_exits (client_org_id)
  WHERE status IN ('requested','export_issued');
CREATE INDEX client_exits_client_idx   ON public.client_exits (client_org_id);
CREATE INDEX client_exits_practice_idx ON public.client_exits (practice_id);

ALTER TABLE public.client_exits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_exits FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.client_exits FROM authenticated, anon;

-- ---------- the immutable certificate ----------
CREATE TABLE public.deletion_certificates (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exit_id          uuid NOT NULL UNIQUE REFERENCES public.client_exits(id),
    certificate_no   text NOT NULL UNIQUE,
    practice_id      uuid NOT NULL REFERENCES public.practices(id),
    client_org_id    uuid NOT NULL REFERENCES public.client_orgs(id),
    client_name      text NOT NULL,                 -- denormalised identity
    requested_by     uuid NOT NULL,
    requested_at     timestamptz NOT NULL,
    retention_days   int  NOT NULL,
    deletion_due_on  date NOT NULL,
    export_issued_at timestamptz NOT NULL,
    export_sha256    text NOT NULL,                 -- hash of the export issued
    deleted_at       timestamptz NOT NULL,
    deleted_by       uuid NOT NULL,
    issued_at        timestamptz NOT NULL DEFAULT now(),
    issued_by        uuid NOT NULL,
    scope_counts     jsonb NOT NULL,                -- {table: rows deleted}
    retained         jsonb NOT NULL,                -- {item: why retained}
    storage_keys     jsonb NOT NULL,                -- object keys to purge
    payload_sha256   text NOT NULL                  -- tamper-evidence over the lot
);
COMMENT ON TABLE public.deletion_certificates IS
  'W4-04 NFR-14/AT-20 issued artefact — the auditable proof that deletion '
  'happened: scope, counts, timestamps, authoriser chain, retained set and '
  'the storage purge list. IMMUTABLE once issued (trigger refuses every '
  'UPDATE/DELETE — corrections are superseding certificates, never edits).';

ALTER TABLE public.client_exits
  ADD CONSTRAINT client_exits_certificate_fkey
  FOREIGN KEY (certificate_id) REFERENCES public.deletion_certificates(id);

ALTER TABLE public.deletion_certificates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deletion_certificates FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.deletion_certificates FROM authenticated, anon;

CREATE FUNCTION public.trg_deletion_certificate_immutable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'deletion certificates are immutable — issue a superseding certificate instead (NFR-09/NFR-14)'
    USING ERRCODE = 'insufficient_privilege';
END $$;
CREATE TRIGGER deletion_certificate_immutable
BEFORE UPDATE OR DELETE ON public.deletion_certificates
FOR EACH ROW EXECUTE FUNCTION public.trg_deletion_certificate_immutable();

-- W4-06 coverage: both are tenant records — field-level audit attached.
SELECT public.attach_audit_trigger('client_exits',           '[]', 'chain');
SELECT public.attach_audit_trigger('deletion_certificates',  '[]', 'chain');


-- ============================================================================
-- private helpers (no client EXECUTE)
-- ============================================================================

-- the authorisation rule, shared by every mutating RPC: partner_admin on the
-- owning practice OR the client's own accountable_officer / client_admin at
-- client scope (spec §4 role model + NFR-13 contract chain). Requires a real
-- principal — a claims-less service call can never authorise an exit.
CREATE FUNCTION public.exit_may_manage(p_practice uuid, p_client uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NOT NULL AND (
       public.has_partner_role(p_practice, ARRAY['partner_admin'])
    OR EXISTS (SELECT 1 FROM public.role_assignments ra
                WHERE ra.user_id = auth.uid() AND ra.level = 'client'
                  AND ra.scope_type = 'client' AND ra.scope_id = p_client
                  AND ra.role IN ('accountable_officer','client_admin')
                  AND ra.start_date <= CURRENT_DATE
                  AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)))
$$;
COMMENT ON FUNCTION public.exit_may_manage(uuid, uuid) IS
  'W4-04 private: exit authorisation — partner_admin on the owning practice, '
  'or accountable_officer/client_admin scoped to that client. Always false '
  'for a claims-less caller (the certificate must name a human authoriser).';

-- fetch the exit row for a caller allowed to SEE it: the T1 rule
-- (allowed_client_orgs) — absent and hidden raise identically, so the app
-- can answer 404 without confirming existence.
CREATE FUNCTION public.exit_guard_view(p_exit_id uuid)
RETURNS public.client_exits
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_exit public.client_exits;
BEGIN
  SELECT * INTO v_exit FROM public.client_exits WHERE id = p_exit_id;
  IF v_exit.id IS NULL
     OR (auth.uid() IS NOT NULL
         AND v_exit.client_org_id NOT IN (SELECT public.allowed_client_orgs())) THEN
    RAISE EXCEPTION 'client exit % not found or not visible to the caller', p_exit_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_exit;
END $$;
COMMENT ON FUNCTION public.exit_guard_view(uuid) IS
  'W4-04 private: read guard for exit artefacts — T1 allowed_client_orgs '
  'visibility (client-scope readers keep read access while their assignments '
  'live; partner roles read across the retention window and after).';

-- every table the exit touches: label → select (parameterised on the client
-- org id). exportable=false rows are deletion-scope bookkeeping or
-- NFR-15-protected content that must not appear in the client-facing export
-- (awareness answers are reported only as averages — the cohort row IS the
-- average-level record; respondents/responses stay out of the export but ARE
-- deleted).
CREATE FUNCTION public.exit_scope_tables()
RETURNS TABLE(label text, exportable boolean, deleted boolean, q text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT * FROM (VALUES
    -- (label, in-export, deleted-on-exit, select)
    ('client_org',                    true,  false, 'SELECT * FROM public.client_orgs WHERE id = $1'),
    ('programmes',                    true,  true,  'SELECT * FROM public.programmes WHERE client_org_id = $1'),
    ('phases',                        true,  true,  'SELECT * FROM public.phases WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('workstreams',                   true,  true,  'SELECT * FROM public.workstreams WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('activities',                    true,  true,  'SELECT * FROM public.activities WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('activity_deps',                 true,  true,  'SELECT * FROM public.activity_deps WHERE activity_id IN (SELECT id FROM public.activities WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1))'),
    ('activity_status_history',       true,  true,  'SELECT * FROM public.activity_status_history WHERE activity_id IN (SELECT id FROM public.activities WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1))'),
    ('register_items',                true,  true,  'SELECT * FROM public.register_items WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('register_item_activities',      true,  true,  'SELECT * FROM public.register_item_activities WHERE register_item_id IN (SELECT id FROM public.register_items WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1))'),
    ('evidence_items',                true,  true,  'SELECT * FROM public.evidence_items WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('evidence_reviews',              true,  true,  'SELECT * FROM public.evidence_reviews WHERE evidence_item_id IN (SELECT id FROM public.evidence_items WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1))'),
    ('evidence_offers',               true,  true,  'SELECT * FROM public.evidence_offers WHERE evidence_item_id IN (SELECT id FROM public.evidence_items WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)) OR to_programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('kpis',                          true,  true,  'SELECT * FROM public.kpis WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('kpi_actuals',                   true,  true,  'SELECT * FROM public.kpi_actuals WHERE kpi_id IN (SELECT id FROM public.kpis WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1))'),
    ('raid_items',                    true,  true,  'SELECT * FROM public.raid_items WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('raid_status_history',           true,  true,  'SELECT * FROM public.raid_status_history WHERE raid_item_id IN (SELECT id FROM public.raid_items WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1))'),
    ('decisions',                     true,  true,  'SELECT * FROM public.decisions WHERE raid_item_id IN (SELECT id FROM public.raid_items WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1))'),
    ('weekly_logs',                   true,  true,  'SELECT * FROM public.weekly_logs WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('maintenance_task_templates',    true,  true,  'SELECT * FROM public.maintenance_task_templates WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('maintenance_task_instances',    true,  true,  'SELECT * FROM public.maintenance_task_instances WHERE task_template_id IN (SELECT id FROM public.maintenance_task_templates WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1))'),
    ('checklist_instances',           true,  true,  'SELECT * FROM public.checklist_instances WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('checklist_item_completions',    true,  true,  'SELECT * FROM public.checklist_item_completions WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('monthly_snapshots',             true,  true,  'SELECT * FROM public.monthly_snapshots WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('programme_reports',             true,  true,  'SELECT * FROM public.programme_reports WHERE programme_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('tracks',                        true,  true,  'SELECT * FROM public.tracks WHERE client_org_id = $1'),
    ('stage_transitions',             true,  true,  'SELECT * FROM public.stage_transitions WHERE track_id IN (SELECT id FROM public.tracks WHERE client_org_id = $1)'),
    ('assessment_sessions',           true,  true,  'SELECT * FROM public.assessment_sessions WHERE client_org_id = $1'),
    ('assessment_responses',          true,  true,  'SELECT * FROM public.assessment_responses WHERE session_id IN (SELECT id FROM public.assessment_sessions WHERE client_org_id = $1)'),
    ('assessment_scores',             true,  true,  'SELECT * FROM public.assessment_scores WHERE session_id IN (SELECT id FROM public.assessment_sessions WHERE client_org_id = $1)'),
    ('assessment_reports',            true,  true,  'SELECT * FROM public.assessment_reports WHERE client_org_id = $1'),
    ('documents',                     true,  true,  'SELECT * FROM public.documents WHERE client_org_id = $1'),
    ('document_links',                true,  true,  'SELECT * FROM public.document_links WHERE client_org_id = $1'),
    ('policies',                      true,  true,  'SELECT * FROM public.policies WHERE client_org_id = $1'),
    ('manuals',                       true,  true,  'SELECT * FROM public.manuals WHERE client_org_id = $1'),
    ('tasks',                         true,  true,  'SELECT * FROM public.tasks WHERE client_org_id = $1'),
    ('monthly_reports',               true,  true,  'SELECT * FROM public.monthly_reports WHERE client_org_id = $1'),
    ('operational_records',           true,  true,  'SELECT * FROM public.operational_records WHERE client_org_id = $1'),
    ('training_records',              true,  true,  'SELECT * FROM public.training_records WHERE client_org_id = $1'),
    ('controlled_documents',          true,  true,  'SELECT * FROM public.controlled_documents WHERE client_org_id = $1'),
    ('controlled_document_activities',true,  true,  'SELECT * FROM public.controlled_document_activities WHERE controlled_document_id IN (SELECT id FROM public.controlled_documents WHERE client_org_id = $1)'),
    ('external_providers',            true,  true,  'SELECT * FROM public.external_providers WHERE client_org_id = $1'),
    ('designations',                  true,  true,  'SELECT * FROM public.designations WHERE client_org_id = $1'),
    ('awareness_cohorts',             true,  true,  'SELECT * FROM public.awareness_cohorts WHERE client_org_id = $1'),
    ('awareness_respondents',         false, true,  'SELECT * FROM public.awareness_respondents WHERE cohort_id IN (SELECT id FROM public.awareness_cohorts WHERE client_org_id = $1)'),
    ('awareness_responses',           false, true,  'SELECT * FROM public.awareness_responses WHERE respondent_id IN (SELECT id FROM public.awareness_respondents WHERE cohort_id IN (SELECT id FROM public.awareness_cohorts WHERE client_org_id = $1))'),
    ('consultant_assignments',        true,  true,  'SELECT * FROM public.consultant_assignments WHERE client_org_id = $1'),
    ('support_access_requests',       true,  true,  'SELECT * FROM public.support_access_requests WHERE client_org_id = $1'),
    ('support_access_grants',         true,  true,  'SELECT * FROM public.support_access_grants WHERE client_org_id = $1'),
    ('role_assignments',              true,  true,  'SELECT * FROM public.role_assignments WHERE (scope_type = ''client'' AND scope_id = $1) OR (scope_type = ''programme'' AND scope_id IN (SELECT id FROM public.programmes WHERE client_org_id = $1)) OR (scope_type = ''workstream'' AND scope_id IN (SELECT w.id FROM public.workstreams w JOIN public.programmes p ON p.id = w.programme_id WHERE p.client_org_id = $1))'),
    ('invites',                       true,  true,  'SELECT * FROM public.invites WHERE client_org_id = $1'),
    ('notification_events',           true,  true,  'SELECT * FROM public.notification_events WHERE scope->>''client_org_id'' = $1::text OR (scope->>''programme_id'')::uuid IN (SELECT id FROM public.programmes WHERE client_org_id = $1)'),
    ('malware_scan_queue',            true,  true,  'SELECT * FROM public.malware_scan_queue WHERE (subject_type = ''evidence_item'' AND subject_id IN (SELECT e.id FROM public.evidence_items e JOIN public.programmes p ON p.id = e.programme_id WHERE p.client_org_id = $1)) OR (subject_type = ''document'' AND subject_id IN (SELECT id FROM public.documents WHERE client_org_id = $1))')
  ) AS s(label, exportable, deleted, q)
$$;
COMMENT ON FUNCTION public.exit_scope_tables() IS
  'W4-04 private: the client-exit scope catalogue — label, exportable flag, '
  'deleted flag and a $1-parameterised select per table. Single source of '
  'truth for the export payload AND the deletion counts so the two can never '
  'drift. client_org is exported but retained (tombstone); awareness '
  'respondents/responses are deleted but not exported (NFR-15).';

-- per-table counts over the scope catalogue. p_for_deletion=true counts the
-- deleted set (the deletion summary / certificate scope_counts); false counts
-- the exported set (the export manifest).
CREATE FUNCTION public.exit_scope_counts(p_client uuid, p_for_deletion boolean)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE rec record; v_n bigint; v_counts jsonb := '{}'::jsonb;
BEGIN
  FOR rec IN SELECT * FROM public.exit_scope_tables()
             WHERE CASE WHEN p_for_deletion THEN deleted ELSE exportable END
             ORDER BY label LOOP
    EXECUTE format('SELECT count(*) FROM (%s) s', rec.q) INTO v_n USING p_client;
    v_counts := v_counts || jsonb_build_object(rec.label, v_n);
  END LOOP;
  RETURN v_counts;
END $$;
COMMENT ON FUNCTION public.exit_scope_counts(uuid, boolean) IS
  'W4-04 private: {label: row_count} over the scope catalogue — deletion set '
  '(p_for_deletion=true) or export set (false).';

-- what stays, and why — written into deletion_summary and the certificate.
CREATE FUNCTION public.exit_retained_manifest()
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT '{
    "client_orgs":      "tombstone row (exited_at set) — identity anchor for the billing ledger, audit trail and this certificate",
    "audit_log":        "NFR-08 append-only action ledger; the exit itself is recorded here",
    "audit_events":     "NFR-08 field-level ledger; every deleted row was captured before removal",
    "billing_events":   "partner invoicing ledger incl. the instance.deleted event written at deletion",
    "approvals":        "partner-scoped gate ledger (subject references are ids, not client content)",
    "notifications":    "partner-scoped inbox rows",
    "users":            "platform accounts incl. auth.users — every client-scoped role assignment was removed; account deletion is an IdP/ops act",
    "import_runs":      "partner import staging; programme links nulled by FK",
    "client_exits":     "this lifecycle record",
    "deletion_certificates": "the issued certificate itself",
    "storage_objects":  "object bytes are the storage layer''s — storage_keys is the purge manifest"
  }'::jsonb
$$;
COMMENT ON FUNCTION public.exit_retained_manifest() IS
  'W4-04 private: the fixed retained-by-design set the deletion certificate '
  'discloses — NFR-08/NFR-14 honesty about what a client exit does NOT wipe.';


-- ============================================================================
-- 1. request_client_exit — open the lifecycle
-- ============================================================================
CREATE FUNCTION public.request_client_exit(
    p_client_org_id  uuid,
    p_reason         text DEFAULT NULL,
    p_retention_days int  DEFAULT 30)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_practice uuid; v_id uuid;
BEGIN
  SELECT co.practice_id INTO v_practice
    FROM public.client_orgs co WHERE co.id = p_client_org_id;
  IF v_practice IS NULL
     OR (auth.uid() IS NOT NULL
         AND p_client_org_id NOT IN (SELECT public.allowed_client_orgs())) THEN
    RAISE EXCEPTION 'client % not found or not visible to the caller', p_client_org_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.exit_may_manage(v_practice, p_client_org_id) THEN
    RAISE EXCEPTION 'client exit must be authorised by a partner admin or the client''s accountable officer / admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF EXISTS (SELECT 1 FROM public.client_orgs
             WHERE id = p_client_org_id AND exited_at IS NOT NULL) THEN
    RAISE EXCEPTION 'client % has already exited — the org is a tombstone', p_client_org_id;
  END IF;
  IF EXISTS (SELECT 1 FROM public.client_exits
             WHERE client_org_id = p_client_org_id
               AND status IN ('requested','export_issued')) THEN
    RAISE EXCEPTION 'an open exit already exists for client %', p_client_org_id;
  END IF;
  IF p_retention_days IS NULL OR p_retention_days NOT BETWEEN 0 AND 3650 THEN
    RAISE EXCEPTION 'retention period must be 0..3650 days (got %)', p_retention_days;
  END IF;
  INSERT INTO public.client_exits
      (practice_id, client_org_id, reason, retention_days, deletion_due_on,
       requested_by)
  VALUES (v_practice, p_client_org_id, nullif(btrim(p_reason), ''),
          p_retention_days, CURRENT_DATE + p_retention_days, auth.uid())
  RETURNING id INTO v_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'client_exit.requested',
          jsonb_build_object('exit_id', v_id, 'client_org_id', p_client_org_id,
                             'retention_days', p_retention_days,
                             'deletion_due_on', CURRENT_DATE + p_retention_days));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.request_client_exit(uuid, text, int) IS
  'W4-04 NFR-14: open a client exit — status requested, deletion due '
  'requested_at + retention_days (the spec''s configurable period, default '
  '30d, bounded 0..3650). Authorised by partner_admin or the client''s '
  'accountable_officer/client_admin. One open exit per client.';


-- ============================================================================
-- 2. issue_exit_export — the full export (the payload goes to the caller; the
--    manifest + hash stay on the exit row and inside the certificate)
-- ============================================================================
CREATE FUNCTION public.issue_exit_export(p_exit_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_exit     public.client_exits;
  rec        record;
  v_arr      jsonb;
  v_sections jsonb := '{}'::jsonb;
  v_counts   jsonb;
  v_storage  jsonb;
  v_payload  jsonb;
  v_manifest jsonb;
BEGIN
  SELECT * INTO v_exit FROM public.client_exits WHERE id = p_exit_id FOR UPDATE;
  IF v_exit.id IS NULL
     OR (auth.uid() IS NOT NULL
         AND v_exit.client_org_id NOT IN (SELECT public.allowed_client_orgs())) THEN
    RAISE EXCEPTION 'client exit % not found or not visible to the caller', p_exit_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.exit_may_manage(v_exit.practice_id, v_exit.client_org_id) THEN
    RAISE EXCEPTION 'client exit must be authorised by a partner admin or the client''s accountable officer / admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_exit.status NOT IN ('requested','export_issued') THEN
    RAISE EXCEPTION 'exit is % — the export can only be issued before deletion runs', v_exit.status;
  END IF;

  FOR rec IN SELECT * FROM public.exit_scope_tables()
             WHERE exportable ORDER BY label LOOP
    EXECUTE format(
      'SELECT coalesce(jsonb_agg(to_jsonb(s)), ''[]''::jsonb) FROM (%s) s',
      rec.q) INTO v_arr USING v_exit.client_org_id;
    v_sections := v_sections || jsonb_build_object(rec.label, v_arr);
  END LOOP;
  v_counts := public.exit_scope_counts(v_exit.client_org_id, false);

  SELECT coalesce(jsonb_agg(k), '[]'::jsonb) INTO v_storage FROM (
      SELECT file_key AS k FROM public.evidence_items
       WHERE programme_id IN (SELECT id FROM public.programmes
                              WHERE client_org_id = v_exit.client_org_id)
         AND file_key IS NOT NULL
      UNION ALL
      SELECT storage_path FROM public.documents
       WHERE client_org_id = v_exit.client_org_id) ks;

  v_payload := jsonb_build_object(
      'export',           'client_exit_full',
      'exit_id',          v_exit.id,
      'generated_at',     now(),
      'generated_by',     auth.uid(),
      'deletion_due_on',  v_exit.deletion_due_on,
      'storage_objects',  v_storage,
      'row_counts',       v_counts,
      'note',             'File bytes are not inlined — storage_objects is the key manifest for download/purge. Awareness answers are excluded per NFR-15 (averages only); cohort rows carry the aggregate results.',
      'sections',         v_sections);

  v_manifest := jsonb_build_object(
      'sections',    v_counts,
      'total_rows',  (SELECT coalesce(sum((v_counts ->> kk.k)::bigint), 0)
                      FROM jsonb_object_keys(v_counts) AS kk(k)),
      'bytes',       octet_length(v_payload::text),
      'sha256',      encode(digest(v_payload::text, 'sha256'), 'hex'),
      'issued_at',   now(),
      'excluded',    '["awareness_respondents","awareness_responses"]'::jsonb);

  UPDATE public.client_exits
     SET status = 'export_issued', export_manifest = v_manifest,
         export_issued_by = auth.uid(), export_issued_at = now()
   WHERE id = v_exit.id;

  PERFORM public.export_audit_row(v_exit.practice_id, 'client_exit_export',
         jsonb_build_object('exit_id', v_exit.id,
                            'client_org_id', v_exit.client_org_id),
         (v_manifest ->> 'total_rows')::bigint);
  RETURN v_payload;
END $$;
COMMENT ON FUNCTION public.issue_exit_export(uuid) IS
  'W4-04 NFR-14/AT-20 "full export produced": one JSONB payload of every '
  'exportable client-scoped row (full fidelity via to_jsonb) + the storage-'
  'key manifest. Re-issuable until deletion. The retained manifest holds '
  'per-section counts, byte size and the payload sha256 — the certificate '
  'carries that hash, so the export that was handed over is provable.';


-- ============================================================================
-- 3. execute_client_exit — the timed deletion (AT-20 "data deleted after the
--    set period"). Export must exist first (order is the acceptance test).
-- ============================================================================
CREATE FUNCTION public.execute_client_exit(p_exit_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_exit    public.client_exits;
  v_counts  jsonb;
  v_storage jsonb;
  v_prog    uuid[];
BEGIN
  SELECT * INTO v_exit FROM public.client_exits WHERE id = p_exit_id FOR UPDATE;
  IF v_exit.id IS NULL
     OR (auth.uid() IS NOT NULL
         AND v_exit.client_org_id NOT IN (SELECT public.allowed_client_orgs())) THEN
    RAISE EXCEPTION 'client exit % not found or not visible to the caller', p_exit_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.exit_may_manage(v_exit.practice_id, v_exit.client_org_id) THEN
    RAISE EXCEPTION 'client exit must be authorised by a partner admin or the client''s accountable officer / admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_exit.status = 'requested' THEN
    RAISE EXCEPTION 'the full export must be issued before deletion runs (AT-20 order)';
  END IF;
  IF v_exit.status <> 'export_issued' THEN
    RAISE EXCEPTION 'exit is % — nothing to delete', v_exit.status;
  END IF;
  IF v_exit.deletion_due_on > CURRENT_DATE THEN
    RAISE EXCEPTION 'retention period has not elapsed — deletion is due on %', v_exit.deletion_due_on;
  END IF;

  -- ---------- snapshot the scope BEFORE any delete ----------
  SELECT array_agg(id) INTO v_prog FROM public.programmes
   WHERE client_org_id = v_exit.client_org_id;
  v_counts := public.exit_scope_counts(v_exit.client_org_id, true);
  SELECT coalesce(jsonb_agg(k), '[]'::jsonb) INTO v_storage FROM (
      SELECT file_key AS k FROM public.evidence_items
       WHERE programme_id = ANY (v_prog) AND file_key IS NOT NULL
      UNION ALL
      SELECT storage_path FROM public.documents
       WHERE client_org_id = v_exit.client_org_id) ks;

  -- ---------- suspend ONLY the immutability/append-only guards that reject
  -- deletion outright (named triggers — the audit_events triggers stay live,
  -- so every deleted row is field-level captured on the way out). If the
  -- delete fails the whole transaction rolls back and the guards return.
  ALTER TABLE public.evidence_items      DISABLE TRIGGER evidence_immutable;
  ALTER TABLE public.programme_reports   DISABLE TRIGGER report_transition_gate;
  ALTER TABLE public.decisions           DISABLE TRIGGER decisions_append_only;
  ALTER TABLE public.raid_status_history DISABLE TRIGGER raid_status_history_append_only;

  -- ---------- the cascade (leaf-most first; engine tree rides the
  -- programme/client FK cascades, counted above) ----------
  DELETE FROM public.malware_scan_queue
   WHERE (subject_type = 'evidence_item'
          AND subject_id IN (SELECT e.id FROM public.evidence_items e
                              JOIN public.programmes p ON p.id = e.programme_id
                             WHERE p.client_org_id = v_exit.client_org_id))
      OR (subject_type = 'document'
          AND subject_id IN (SELECT id FROM public.documents
                             WHERE client_org_id = v_exit.client_org_id));
  DELETE FROM public.notification_events
   WHERE scope->>'client_org_id' = v_exit.client_org_id::text
      OR (scope->>'programme_id')::uuid = ANY (v_prog);
  DELETE FROM public.role_assignments
   WHERE (scope_type = 'client' AND scope_id = v_exit.client_org_id)
      OR (scope_type = 'programme' AND scope_id = ANY (v_prog))
      OR (scope_type = 'workstream'
          AND scope_id IN (SELECT w.id FROM public.workstreams w
                           WHERE w.programme_id = ANY (v_prog)));
  DELETE FROM public.invites                 WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.consultant_assignments  WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.support_access_requests WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.support_access_grants   WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.designations            WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.operational_records     WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.training_records        WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.external_providers      WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.controlled_documents    WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.awareness_cohorts       WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.assessment_reports      WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.assessment_sessions     WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.document_links          WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.documents               WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.policies                WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.manuals                 WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.tasks                   WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.monthly_reports         WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.programmes              WHERE client_org_id = v_exit.client_org_id;
  DELETE FROM public.tracks                  WHERE client_org_id = v_exit.client_org_id;

  -- ---------- restore the guards ----------
  ALTER TABLE public.evidence_items      ENABLE TRIGGER evidence_immutable;
  ALTER TABLE public.programme_reports   ENABLE TRIGGER report_transition_gate;
  ALTER TABLE public.decisions           ENABLE TRIGGER decisions_append_only;
  ALTER TABLE public.raid_status_history ENABLE TRIGGER raid_status_history_append_only;

  -- ---------- tombstone + ledger + lifecycle ----------
  UPDATE public.client_orgs SET exited_at = now()
   WHERE id = v_exit.client_org_id;
  INSERT INTO public.billing_events (practice_id, client_org_id, event_type, detail)
  VALUES (v_exit.practice_id, v_exit.client_org_id, 'instance.deleted',
          jsonb_build_object('exit_id', v_exit.id, 'by', auth.uid()));
  UPDATE public.client_exits
     SET status = 'deleted', deleted_by = auth.uid(), deleted_at = now(),
         deletion_summary = jsonb_build_object(
             'scope_counts',  v_counts,
             'storage_keys',  v_storage,
             'retained',      public.exit_retained_manifest())
   WHERE id = v_exit.id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_exit.practice_id, 'client_exit.deleted',
          jsonb_build_object('exit_id', v_exit.id,
                             'client_org_id', v_exit.client_org_id,
                             'scope_counts', v_counts));
END $$;
COMMENT ON FUNCTION public.execute_client_exit(uuid) IS
  'W4-04 NFR-14/AT-20: run the timed deletion once deletion_due_on has '
  'elapsed and the export is issued. Deletes the whole client estate in '
  'dependency order (immutability guards suspended for the transaction, '
  'audit triggers live), tombstones client_orgs, writes billing_events '
  '''instance.deleted'' and the audit row. Certificate follows via '
  'issue_deletion_certificate.';


-- ============================================================================
-- 4. issue_deletion_certificate — mint the immutable proof
-- ============================================================================
CREATE FUNCTION public.issue_deletion_certificate(p_exit_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_exit   public.client_exits;
  v_id     uuid;
  v_no     text;
  v_counts jsonb;
  v_store  jsonb;
  v_name   text;
  v_cert   jsonb;
BEGIN
  SELECT * INTO v_exit FROM public.client_exits WHERE id = p_exit_id FOR UPDATE;
  IF v_exit.id IS NULL
     OR (auth.uid() IS NOT NULL
         AND v_exit.client_org_id NOT IN (SELECT public.allowed_client_orgs())) THEN
    RAISE EXCEPTION 'client exit % not found or not visible to the caller', p_exit_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.exit_may_manage(v_exit.practice_id, v_exit.client_org_id) THEN
    RAISE EXCEPTION 'client exit must be authorised by a partner admin or the client''s accountable officer / admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_exit.status = 'certified' THEN
    RETURN v_exit.certificate_id;                    -- idempotent re-read
  END IF;
  IF v_exit.status <> 'deleted' THEN
    RAISE EXCEPTION 'exit is % — deletion must execute before the certificate is issued', v_exit.status;
  END IF;

  SELECT coalesce(nullif(btrim(co.trading_name), ''),
                  nullif(btrim(co.legal_name), ''), co.name)
    INTO v_name FROM public.client_orgs co WHERE co.id = v_exit.client_org_id;
  v_counts := v_exit.deletion_summary -> 'scope_counts';
  v_store  := coalesce(v_exit.deletion_summary -> 'storage_keys', '[]'::jsonb);
  v_no     := format('DEL-%s-%s', to_char(now(), 'YYYYMMDD'),
                     upper(substr(replace(v_exit.id::text, '-', ''), 1, 8)));

  v_cert := jsonb_build_object(
      'certificate_no',   v_no,
      'practice_id',      v_exit.practice_id,
      'client_org_id',    v_exit.client_org_id,
      'client_name',      v_name,
      'requested_by',     v_exit.requested_by,
      'requested_at',     v_exit.requested_at,
      'retention_days',   v_exit.retention_days,
      'deletion_due_on',  v_exit.deletion_due_on,
      'export_issued_at', v_exit.export_issued_at,
      'export_sha256',    v_exit.export_manifest ->> 'sha256',
      'deleted_at',       v_exit.deleted_at,
      'deleted_by',       v_exit.deleted_by,
      'issued_by',        auth.uid(),
      'scope_counts',     v_counts,
      'retained',         public.exit_retained_manifest(),
      'storage_keys',     v_store);

  INSERT INTO public.deletion_certificates
      (exit_id, certificate_no, practice_id, client_org_id, client_name,
       requested_by, requested_at, retention_days, deletion_due_on,
       export_issued_at, export_sha256, deleted_at, deleted_by, issued_by,
       scope_counts, retained, storage_keys, payload_sha256)
  VALUES (v_exit.id, v_no, v_exit.practice_id, v_exit.client_org_id, v_name,
          v_exit.requested_by, v_exit.requested_at, v_exit.retention_days,
          v_exit.deletion_due_on, v_exit.export_issued_at,
          coalesce(v_exit.export_manifest ->> 'sha256', ''),
          v_exit.deleted_at, v_exit.deleted_by, auth.uid(),
          v_counts, public.exit_retained_manifest(), v_store,
          encode(digest(v_cert::text, 'sha256'), 'hex'))
  RETURNING id INTO v_id;

  UPDATE public.client_exits
     SET status = 'certified', certificate_id = v_id
   WHERE id = v_exit.id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_exit.practice_id, 'client_exit.certified',
          jsonb_build_object('exit_id', v_exit.id,
                             'client_org_id', v_exit.client_org_id,
                             'certificate_id', v_id,
                             'certificate_no', v_no));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.issue_deletion_certificate(uuid) IS
  'W4-04 NFR-14/AT-20 "deletion certificate issued": the immutable, auditable '
  'record — scope counts, storage purge list, retained set, the authoriser '
  'chain (requested/deleted/issued) and a sha256 over the certifying '
  'payload. Idempotent on an already-certified exit.';


-- ============================================================================
-- 5. cancel — pre-delete only
-- ============================================================================
CREATE FUNCTION public.cancel_client_exit(p_exit_id uuid, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_exit public.client_exits;
BEGIN
  SELECT * INTO v_exit FROM public.client_exits WHERE id = p_exit_id FOR UPDATE;
  IF v_exit.id IS NULL
     OR (auth.uid() IS NOT NULL
         AND v_exit.client_org_id NOT IN (SELECT public.allowed_client_orgs())) THEN
    RAISE EXCEPTION 'client exit % not found or not visible to the caller', p_exit_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT public.exit_may_manage(v_exit.practice_id, v_exit.client_org_id) THEN
    RAISE EXCEPTION 'client exit must be authorised by a partner admin or the client''s accountable officer / admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_exit.status = 'cancelled' THEN
    RAISE EXCEPTION 'exit is already cancelled';
  END IF;
  IF v_exit.status IN ('deleted','certified') THEN
    RAISE EXCEPTION 'exit is % — deletion has already run and cannot be undone', v_exit.status;
  END IF;
  UPDATE public.client_exits
     SET status = 'cancelled', cancelled_by = auth.uid(),
         cancelled_at = now(), cancel_reason = nullif(btrim(p_reason), '')
   WHERE id = v_exit.id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_exit.practice_id, 'client_exit.cancelled',
          jsonb_build_object('exit_id', v_exit.id,
                             'client_org_id', v_exit.client_org_id,
                             'reason', nullif(btrim(p_reason), '')));
END $$;
COMMENT ON FUNCTION public.cancel_client_exit(uuid, text) IS
  'W4-04: cancel an open exit (requested/export_issued only — the legal-hold '
  'answer: hold = do not execute, or cancel before the due date).';


-- ============================================================================
-- 6. reads — T1 visibility, identical rule to the export guards
-- ============================================================================
CREATE FUNCTION public.list_client_exits(p_client_org_id uuid DEFAULT NULL)
RETURNS SETOF public.client_exits
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY
  SELECT e.* FROM public.client_exits e
   WHERE (auth.uid() IS NULL
          OR e.client_org_id IN (SELECT public.allowed_client_orgs()))
     AND (p_client_org_id IS NULL OR e.client_org_id = p_client_org_id)
   ORDER BY e.requested_at DESC, e.id;
END $$;
COMMENT ON FUNCTION public.list_client_exits(uuid) IS
  'W4-04: the caller-visible exit ledger — T1 allowed_client_orgs filter; '
  'partner roles read across the whole lifecycle, client-scope readers while '
  'their assignments live.';

CREATE FUNCTION public.get_deletion_certificate(p_exit_id uuid)
RETURNS SETOF public.deletion_certificates
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_exit public.client_exits;
BEGIN
  v_exit := public.exit_guard_view(p_exit_id);          -- raises if hidden
  RETURN QUERY
  SELECT c.* FROM public.deletion_certificates c WHERE c.exit_id = v_exit.id;
END $$;
COMMENT ON FUNCTION public.get_deletion_certificate(uuid) IS
  'W4-04: read the issued certificate for an exit (T1 visibility). Empty '
  'set before certification; invisible exits raise, never confirm.';


-- ---------- grants ----------
REVOKE EXECUTE ON FUNCTION
  public.exit_may_manage(uuid, uuid),
  public.exit_guard_view(uuid),
  public.exit_scope_tables(),
  public.exit_scope_counts(uuid, boolean),
  public.exit_retained_manifest(),
  public.trg_deletion_certificate_immutable()
FROM anon, public, authenticated;
REVOKE EXECUTE ON FUNCTION
  public.request_client_exit(uuid, text, int),
  public.issue_exit_export(uuid),
  public.execute_client_exit(uuid),
  public.issue_deletion_certificate(uuid),
  public.cancel_client_exit(uuid, text),
  public.list_client_exits(uuid),
  public.get_deletion_certificate(uuid)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.request_client_exit(uuid, text, int),
  public.issue_exit_export(uuid),
  public.execute_client_exit(uuid),
  public.issue_deletion_certificate(uuid),
  public.cancel_client_exit(uuid, text),
  public.list_client_exits(uuid),
  public.get_deletion_certificate(uuid)
TO authenticated;

COMMIT;
