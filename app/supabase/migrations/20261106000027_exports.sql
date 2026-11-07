-- ============================================================================
-- W3-04 (#45) — programme exports (spec §11 "Reports and exports").
--
-- One SECURITY DEFINER rowset RPC per export artefact; each carries the
-- standard in-body visibility guard (a definer bypasses RLS, so the check
-- must live in the body — the predicate catalogue's allowed_programmes() /
-- allowed_client_orgs() / has_partner_role(), exactly like list_reports).
-- "Not found" and "not yours" raise the same insufficient_privilege message,
-- so the download route can answer 404 without confirming existence.
--
-- DISCLOSURE AUDIT — exports are disclosure-sensitive: every call that
-- returns rows (even zero) appends an audit_log row naming the artefact,
-- the scope and the row count. The write happens INSIDE the RPC, not in the
-- web route, so a direct PostgREST call is audited too. (The existing
-- append-only audit_log is the ledger — spec §11's "audit trail extract"
-- reads it back through export_audit_extract, admin-gated.)
--
-- Artefacts (task scope):
--   export_register_items        programme   register items + links + §9.4 record
--   export_activities            programme   the schedule (incl. deps + leads)
--   export_evidence_index        programme   evidence index (the assessor index)
--   export_kpi_history           programme   KPIs × monthly actuals
--   export_report_index          programme   monthly reports ledger (list_reports)
--   export_maintenance_history   programme   maintenance task instances
--   export_client_pack           client      every programme × report — the
--                                            client-level pack in machine form
--   export_audit_extract         partner     audit_log extract — ADMINS ONLY
--                                            (spec §11 "admins only" row)
--
-- Caller-visible only: T2 read policies already give any allowed_programmes()
-- caller the whole programme (workstream-scope callers included since the
-- W4-D3 widening), so the guarded full-programme rowset equals the RLS view.
-- ============================================================================

BEGIN;

-- ---------- private helpers (no client EXECUTE) ----------

-- programme → owning partner, or raise when absent/invisible to the caller.
CREATE FUNCTION public.export_guard_programme(p_programme_id uuid)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_practice uuid;
BEGIN
  SELECT co.practice_id INTO v_practice
    FROM public.programmes p
    JOIN public.client_orgs co ON co.id = p.client_org_id
   WHERE p.id = p_programme_id;
  IF v_practice IS NULL
     OR (auth.uid() IS NOT NULL
         AND p_programme_id NOT IN (SELECT public.allowed_programmes())) THEN
    RAISE EXCEPTION 'programme % not found or not visible to the caller', p_programme_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_practice;
END $$;
COMMENT ON FUNCTION public.export_guard_programme(uuid) IS
  'W3-04 private: visibility guard shared by the programme exports — returns '
  'the owning practice for the audit row, or raises (absent and hidden look '
  'identical).';

-- client → owning partner under the T1 rule (client pack is client-level).
CREATE FUNCTION public.export_guard_client(p_client_org_id uuid)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_practice uuid;
BEGIN
  SELECT co.practice_id INTO v_practice
    FROM public.client_orgs co
   WHERE co.id = p_client_org_id;
  IF v_practice IS NULL
     OR (auth.uid() IS NOT NULL
         AND p_client_org_id NOT IN (SELECT public.allowed_client_orgs())) THEN
    RAISE EXCEPTION 'client % not found or not visible to the caller', p_client_org_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_practice;
END $$;
COMMENT ON FUNCTION public.export_guard_client(uuid) IS
  'W3-04 private: visibility guard for the client-level pack (T1 '
  'allowed_client_orgs — a programme-scope-only caller cannot pull the pack).';

-- the disclosure audit row. action = 'export.<artefact>'; detail carries the
-- scope + the emitted row count.
CREATE FUNCTION public.export_audit_row(
    p_practice uuid, p_artefact text, p_scope jsonb, p_rows bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), p_practice, 'export.' || p_artefact,
          jsonb_build_object('export', p_artefact, 'rows', p_rows) || coalesce(p_scope, '{}'::jsonb));
END $$;
COMMENT ON FUNCTION public.export_audit_row(uuid, text, jsonb, bigint) IS
  'W3-04 private: the disclosure audit write shared by every export RPC. '
  'audit_log is append-only (REVOKEd UPDATE/DELETE).';


-- ---------- 1. register items ----------
CREATE FUNCTION public.export_register_items(p_programme_id uuid)
RETURNS TABLE(
  ref text, finding text, priority text, status text, assessment_window text,
  lead text, planned_close_week int, planned_close_date date, days_overdue int,
  linked_activities text, accepted_on timestamptz, accepted_by text,
  accepted_evidence_refs text, retired boolean, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE v_practice uuid; v_rows bigint;
BEGIN
  v_practice := public.export_guard_programme(p_programme_id);
  RETURN QUERY
  SELECT r.ref, r.finding, r.priority, r.status, r.assessment_window,
         (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
            FROM public.users u WHERE u.id = r.lead),
         r.planned_close_week, r.planned_close_date, r.days_overdue,
         (SELECT string_agg(a.ref, '; ' ORDER BY a.ref)
            FROM public.register_item_activities ria
            JOIN public.activities a ON a.id = ria.activity_id
           WHERE ria.register_item_id = r.id),
         r.accepted_on,
         (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
            FROM public.users u WHERE u.id = r.accepted_by),
         (SELECT string_agg(x.ref, '; ' ORDER BY x.ref)
            FROM unnest(r.accepted_evidence_refs) AS x(ref)),
         NOT r.active,
         r.created_at
    FROM public.register_items r
   WHERE r.programme_id = p_programme_id
   ORDER BY r.ref;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM public.export_audit_row(v_practice, 'register_items',
         jsonb_build_object('programme_id', p_programme_id), v_rows);
END $$;
COMMENT ON FUNCTION public.export_register_items(uuid) IS
  'W3-04 §11: the programme register as caller-visible rows (T2) incl. linked '
  'activity refs, the §9.4 acceptance record and the FR-TPL-04 retired flag. '
  'Definer + allowed_programmes() guard; writes the disclosure audit row.';


-- ---------- 2. activities / schedule ----------
CREATE FUNCTION public.export_activities(p_programme_id uuid)
RETURNS TABLE(
  ref text, activity text, workstream text, phase text, status text,
  pct_complete int, start_week int, end_week int, start_date date,
  due_date date, month int, milestone boolean, evidence_required boolean,
  rag text, flag boolean, leads text, depends_on text,
  actual_completion date, recovery_date date, comments text,
  retired boolean, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE v_practice uuid; v_rows bigint;
BEGIN
  v_practice := public.export_guard_programme(p_programme_id);
  RETURN QUERY
  SELECT a.ref, a.text,
         (SELECT w.name FROM public.workstreams w WHERE w.id = a.workstream_id),
         a.phase, a.status, a.pct_complete, a.start_week, a.end_week,
         a.start_date, a.due_date, a.month, a.milestone, a.evidence_required,
         a.rag, a.flag,
         (SELECT string_agg(coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1)),
                            '; ' ORDER BY u.email)
            FROM public.users u WHERE u.id = ANY(a.leads)),
         (SELECT string_agg(d.ref, '; ' ORDER BY d.ref)
            FROM public.activity_deps ad
            JOIN public.activities d ON d.id = ad.depends_on_activity_id
           WHERE ad.activity_id = a.id),
         a.actual_completion, a.recovery_date, a.comments,
         NOT a.active,
         a.created_at
    FROM public.activities a
   WHERE a.programme_id = p_programme_id
   ORDER BY a.start_week, a.ref;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM public.export_audit_row(v_practice, 'activities',
         jsonb_build_object('programme_id', p_programme_id), v_rows);
END $$;
COMMENT ON FUNCTION public.export_activities(uuid) IS
  'W3-04 §11: the activity schedule as caller-visible rows — refs, weeks and '
  'engine dates, status/RAG, lead names, finish-to-start dep refs, retire '
  'flag. Definer + allowed_programmes() guard; disclosure audit row.';


-- ---------- 3. evidence index ----------
CREATE FUNCTION public.export_evidence_index(p_programme_id uuid)
RETURNS TABLE(
  evidence_ref text, kind text, file_key text, link text, site text,
  review_stage text, outcome text,
  uploaded_by text, uploaded_at timestamptz,
  activity_ref text, register_ref text,
  accepted_on timestamptz, accepted_by text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE v_practice uuid; v_rows bigint;
BEGIN
  v_practice := public.export_guard_programme(p_programme_id);
  RETURN QUERY
  SELECT e.evidence_ref,
         CASE WHEN e.file_key IS NOT NULL THEN 'file' ELSE 'link' END,
         e.file_key, e.link, e.site, e.review_stage, e.outcome,
         (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
            FROM public.users u WHERE u.id = e.uploaded_by),
         e.uploaded_at,
         (SELECT a.ref FROM public.activities a WHERE a.id = e.activity_id),
         (SELECT r.ref FROM public.register_items r WHERE r.id = e.register_item_id),
         (SELECT er.decided_at FROM public.evidence_reviews er
           WHERE er.evidence_item_id = e.id AND er.stage = 'accept'
             AND er.decision = 'accepted'
           ORDER BY er.decided_at DESC LIMIT 1),
         (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
            FROM public.evidence_reviews er
            JOIN public.users u ON u.id = er.reviewer
           WHERE er.evidence_item_id = e.id AND er.stage = 'accept'
             AND er.decision = 'accepted'
           ORDER BY er.decided_at DESC LIMIT 1)
    FROM public.evidence_items e
   WHERE e.programme_id = p_programme_id
   ORDER BY e.evidence_ref NULLS LAST, e.uploaded_at;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM public.export_audit_row(v_practice, 'evidence_index',
         jsonb_build_object('programme_id', p_programme_id), v_rows);
END $$;
COMMENT ON FUNCTION public.export_evidence_index(uuid) IS
  'W3-04 §11 "evidence pack index": every evidence row of the programme with '
  'its FR-EVD-06 ref, storage key/link, review state, outcome and the AO '
  'acceptance that minted the ref. No file bytes — the index is the manifest. '
  'Definer + allowed_programmes() guard; disclosure audit row.';


-- ---------- 4. KPI history ----------
CREATE FUNCTION public.export_kpi_history(p_programme_id uuid)
RETURNS TABLE(
  kpi_name text, unit text, baseline numeric, target numeric,
  target_confirmed boolean, auto_calc boolean,
  month date, value numeric, evidence_ref text,
  entered_by text, entered_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE v_practice uuid; v_rows bigint;
BEGIN
  v_practice := public.export_guard_programme(p_programme_id);
  RETURN QUERY
  SELECT k.name, k.unit, k.baseline, k.target,
         (k.target_confirmed_on IS NOT NULL), k.auto_calc,
         ka.month, ka.value,
         (SELECT e.evidence_ref FROM public.evidence_items e WHERE e.id = ka.evidence_id),
         (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
            FROM public.users u WHERE u.id = ka.entered_by),
         ka.created_at
    FROM public.kpis k
    LEFT JOIN public.kpi_actuals ka ON ka.kpi_id = k.id
   WHERE k.programme_id = p_programme_id
   ORDER BY k.sort, k.name, ka.month;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM public.export_audit_row(v_practice, 'kpi_history',
         jsonb_build_object('programme_id', p_programme_id), v_rows);
END $$;
COMMENT ON FUNCTION public.export_kpi_history(uuid) IS
  'W3-04 §11: KPI history — one row per KPI × monthly actual (a KPI with no '
  'actuals still appears, month columns NULL). Definer + allowed_programmes() '
  'guard; disclosure audit row.';


-- ---------- 5. monthly-report index ----------
-- Rows come straight from list_reports (the same definer the screen uses) so
-- the export can never drift from what the reports page shows; our own guard
-- still runs first, and we write the disclosure audit row list_reports
-- doesn't have.
CREATE FUNCTION public.export_report_index(p_programme_id uuid)
RETURNS TABLE(
  period text, version int, status text, reference text, due_on date,
  late boolean, days_late int, snapshot_taken_at timestamptz,
  signed_at timestamptz, signed_by text,
  issued_on timestamptz, issued_by text,
  is_latest boolean, inputs_outstanding int, gate_override_reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE v_practice uuid; v_rows bigint;
BEGIN
  v_practice := public.export_guard_programme(p_programme_id);
  RETURN QUERY
  SELECT l.period, l.version, l.status, l.reference, l.due_on, l.late,
         l.days_late, l.snapshot_taken_at, l.signed_at, l.signed_by_name,
         l.issued_on, l.issued_by_name, l.is_latest, l.inputs_outstanding,
         l.gate_override_reason
    FROM public.list_reports(p_programme_id, now()) l;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM public.export_audit_row(v_practice, 'report_index',
         jsonb_build_object('programme_id', p_programme_id), v_rows);
END $$;
COMMENT ON FUNCTION public.export_report_index(uuid) IS
  'W3-04 §11: the monthly-report ledger (period, version, FR-RPT-04 status, '
  'reference, due/late, sign + issue) — the machine-readable index; the human '
  'document is the report print render. Definer + allowed_programmes() '
  'guard; disclosure audit row.';


-- ---------- 6. maintenance history ----------
CREATE FUNCTION public.export_maintenance_history(p_programme_id uuid)
RETURNS TABLE(
  code text, task text, period text, task_window text, due_date date,
  status text, assignee text, completed_on timestamptz,
  evidence_ref text, evidence_exempt_reason text, exception_reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE v_practice uuid; v_rows bigint;
BEGIN
  v_practice := public.export_guard_programme(p_programme_id);
  RETURN QUERY
  SELECT t.code, t.task, i.period, i.task_window, i.due_date, i.status,
         (SELECT coalesce(nullif(btrim(u.full_name), ''), split_part(u.email, '@', 1))
            FROM public.users u WHERE u.id = i.assignee),
         i.completed_on,
         (SELECT e.evidence_ref FROM public.evidence_items e WHERE e.id = i.evidence_id),
         i.evidence_exempt_reason, i.exception_reason
    FROM public.maintenance_task_instances i
    JOIN public.maintenance_task_templates t ON t.id = i.task_template_id
   WHERE t.programme_id = p_programme_id
   ORDER BY i.period, t.sort, t.code;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM public.export_audit_row(v_practice, 'maintenance_history',
         jsonb_build_object('programme_id', p_programme_id), v_rows);
END $$;
COMMENT ON FUNCTION public.export_maintenance_history(uuid) IS
  'W3-04 §11 "maintenance history": every generated maintenance task '
  'instance with period/due/status/completion and its evidence ref (or the '
  'FR-MNT-05 exemption / FR-MNT-06 exception reason). Definer + '
  'allowed_programmes() guard; disclosure audit row.';


-- ---------- 7. client-level pack ----------
-- Spec §11 "Executive pack — client level": every programme of the client
-- and, per programme, each month's LATEST report version. Programmes with
-- no reports still appear (report columns NULL) so the pack is complete.
CREATE FUNCTION public.export_client_pack(p_client_org_id uuid)
RETURNS TABLE(
  client text, programme text, programme_status text, phase text,
  programme_rag text, report_period text, report_version int,
  report_status text, report_reference text, report_due_on date,
  report_issued_on timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE v_practice uuid; v_rows bigint;
BEGIN
  v_practice := public.export_guard_client(p_client_org_id);
  RETURN QUERY
  SELECT coalesce(nullif(btrim(co.trading_name), ''), nullif(btrim(co.legal_name), ''), co.name),
         p.name, p.status, p.phase, p.programme_rag,
         r.period, r.version, r.status, r.reference, r.due_on, r.issued_on
    FROM public.programmes p
    JOIN public.client_orgs co ON co.id = p.client_org_id
    LEFT JOIN public.programme_reports r
           ON r.programme_id = p.id
          AND NOT EXISTS (SELECT 1 FROM public.programme_reports n
                           WHERE n.programme_id = r.programme_id
                             AND n.period = r.period
                             AND n.version > r.version)
   WHERE p.client_org_id = p_client_org_id
   ORDER BY p.name, r.period;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM public.export_audit_row(v_practice, 'client_pack',
         jsonb_build_object('client_org_id', p_client_org_id), v_rows);
END $$;
COMMENT ON FUNCTION public.export_client_pack(uuid) IS
  'W3-04 §11 client-level pack: one row per programme × latest-version '
  'monthly report (programmes without reports appear with NULL report '
  'columns). T1 client guard; disclosure audit row.';


-- ---------- 7b. report view — the human-format read is a disclosure too ----------
-- The /exports/report/[id] HTML render calls this once the document resolved:
-- same guard (report_for_caller inside report_document already ran — this
-- re-checks the programme cheaply), one audit row per view.
CREATE FUNCTION public.export_report_view(p_report_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_programme uuid; v_practice uuid;
BEGIN
  SELECT r.programme_id INTO v_programme
    FROM public.programme_reports r WHERE r.id = p_report_id;
  IF v_programme IS NULL THEN
    RAISE EXCEPTION 'report % not found or not visible to the caller', p_report_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_practice := public.export_guard_programme(v_programme);
  PERFORM public.export_audit_row(v_practice, 'report_view',
         jsonb_build_object('programme_id', v_programme, 'report_id', p_report_id), 1);
END $$;
COMMENT ON FUNCTION public.export_report_view(uuid) IS
  'W3-04 §11: disclosure audit for the human (HTML) export of a monthly '
  'report — the CSV routes audit inside their rowset RPC; the page render '
  'has no rowset, so the view itself is logged here.';


-- ---------- 8. audit extract — ADMINS ONLY (spec §11) ----------
-- "Audit trail extract — CSV — client, partner, platform — admins only".
-- Partner-scoped: partner_admin on the practice, or platform_admin (the
-- platform-level admin leg). Anything less reads as not-permitted — the
-- audit trail itself is disclosure-sensitive.
CREATE FUNCTION public.export_audit_extract(
    p_practice_id uuid, p_limit int DEFAULT 5000)
RETURNS TABLE(at timestamptz, user_id uuid, user_email text,
              action text, detail jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE v_rows bigint;
BEGIN
  IF p_practice_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.practices pr WHERE pr.id = p_practice_id)
     OR (auth.uid() IS NOT NULL
         AND NOT public.has_partner_role(p_practice_id, ARRAY['partner_admin'])
         AND NOT public.is_platform_role(ARRAY['platform_admin'])) THEN
    RAISE EXCEPTION 'practice % not found or not visible to the caller', p_practice_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
  SELECT a.at, a.user_id,
         (SELECT u.email FROM public.users u WHERE u.id = a.user_id),
         a.action, a.detail
    FROM public.audit_log a
   WHERE a.practice_id = p_practice_id
   ORDER BY a.at DESC, a.id DESC
   LIMIT greatest(1, least(coalesce(p_limit, 5000), 50000));
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  PERFORM public.export_audit_row(p_practice_id, 'audit_extract',
         jsonb_build_object('practice_id', p_practice_id), v_rows);
END $$;
COMMENT ON FUNCTION public.export_audit_extract(uuid, int) IS
  'W3-04 §11 "audit trail extract — admins only": the partner''s append-only '
  'audit_log (newest first, bounded by p_limit ≤ 50000). Gate: partner_admin '
  'on the practice or platform_admin. Disclosure audit row for the extract '
  'itself.';


-- ---------- grants: callers reach these through PostgREST ----------
REVOKE EXECUTE ON FUNCTION
  public.export_guard_programme(uuid),
  public.export_guard_client(uuid),
  public.export_audit_row(uuid, text, jsonb, bigint)
FROM anon, public, authenticated;
REVOKE EXECUTE ON FUNCTION
  public.export_register_items(uuid),
  public.export_activities(uuid),
  public.export_evidence_index(uuid),
  public.export_kpi_history(uuid),
  public.export_report_index(uuid),
  public.export_maintenance_history(uuid),
  public.export_client_pack(uuid),
  public.export_report_view(uuid),
  public.export_audit_extract(uuid, int)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.export_register_items(uuid),
  public.export_activities(uuid),
  public.export_evidence_index(uuid),
  public.export_kpi_history(uuid),
  public.export_report_index(uuid),
  public.export_maintenance_history(uuid),
  public.export_client_pack(uuid),
  public.export_report_view(uuid),
  public.export_audit_extract(uuid, int)
TO authenticated;

COMMIT;
