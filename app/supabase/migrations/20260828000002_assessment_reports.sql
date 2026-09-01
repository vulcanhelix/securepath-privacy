-- ASSESSMENT REPORT — the consultant-grade, versioned client deliverable (the "Puris report").
-- One report chain per client+framework: v1 gap assessment at Gate 1, v2 post-documentation
-- position, v3 reassessment. Each issue renders print-styled HTML to object storage as an
-- immutable evidence document; the predecessor flips to 'superseded' (never deleted).
-- payload  = compiled JSONB snapshot of live data (responses stay mutable after Gate 1, so
--            the report must carry its own copy of what it said).
-- overrides = advisor narrative edits, section include/exclude, A–D classification decisions.
--            Copied forward v(n) -> v(n+1) for continuity; frozen with the row at issue.

BEGIN;

CREATE TABLE public.assessment_reports (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id      uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    track_id           uuid REFERENCES public.tracks(id),
    framework_key      text NOT NULL REFERENCES public.frameworks(key),
    session_id         uuid REFERENCES public.assessment_sessions(id),
    content_pack_id    uuid REFERENCES public.content_packs(id),
    version            int  NOT NULL DEFAULT 1,
    supersedes         uuid REFERENCES public.assessment_reports(id),
    kind               text NOT NULL DEFAULT 'gap_assessment'
                         CHECK (kind IN ('gap_assessment','post_documentation','reassessment')),
    title              text NOT NULL,
    payload            jsonb NOT NULL DEFAULT '{}'::jsonb,
    overrides          jsonb NOT NULL DEFAULT '{}'::jsonb,
    approval_status    public.approval_status NOT NULL DEFAULT 'draft_human',
    compiled_at        timestamptz,
    issued_at          timestamptz,
    issued_document_id uuid REFERENCES public.documents(id),
    created_by         uuid,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_assessment_reports_client
  ON public.assessment_reports (client_org_id, framework_key, version DESC);
-- exactly one working (non-issued) report per client+framework
CREATE UNIQUE INDEX assessment_reports_working_uq
  ON public.assessment_reports (client_org_id, framework_key)
  WHERE approval_status IN ('draft_ai','draft_human','approved');

ALTER TABLE public.assessment_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_reports FORCE ROW LEVEL SECURITY;
-- Drafts are advisor-only even to read: this is THE client deliverable, and nothing
-- unapproved may be client-visible. Clients see issued/superseded versions only.
CREATE POLICY assessment_reports_read ON public.assessment_reports FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs())
         AND (approval_status IN ('issued','superseded')
              OR public.current_role_name() IN ('practice_owner','practice_consultant')));
REVOKE ALL ON public.assessment_reports FROM anon;
GRANT SELECT ON public.assessment_reports TO authenticated;   -- writes via RPC only

-- ---------- RPCs ----------

-- Start the next report in the chain. Requires a signed-off assessment to report on.
CREATE FUNCTION public.create_assessment_report(
    p_client_org_id uuid, p_framework text, p_kind text, p_title text,
    p_session_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_session assessment_sessions%ROWTYPE; v_head assessment_reports%ROWTYPE;
        v_track uuid; rid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to client organisation'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may create assessment reports';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM frameworks WHERE key = p_framework) THEN
    RAISE EXCEPTION 'unknown framework %', p_framework;
  END IF;
  IF p_kind NOT IN ('gap_assessment','post_documentation','reassessment') THEN
    RAISE EXCEPTION 'unknown report kind %', p_kind;
  END IF;

  IF p_session_id IS NOT NULL THEN
    SELECT * INTO v_session FROM assessment_sessions
      WHERE id = p_session_id AND client_org_id = p_client_org_id AND framework = p_framework;
    IF NOT FOUND THEN RAISE EXCEPTION 'assessment session not found for this client and framework'; END IF;
    IF v_session.approval_status <> 'approved' THEN RAISE EXCEPTION 'assessment is not signed off'; END IF;
  ELSE
    SELECT * INTO v_session FROM assessment_sessions
      WHERE client_org_id = p_client_org_id AND framework = p_framework AND approval_status = 'approved'
      ORDER BY updated_at DESC LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'no signed-off assessment to report on'; END IF;
  END IF;

  SELECT t.id INTO v_track FROM tracks t JOIN frameworks f ON f.track_kind = t.track_kind
    WHERE t.client_org_id = p_client_org_id AND f.key = p_framework;

  -- chain head = latest issued report for this client+framework
  SELECT * INTO v_head FROM assessment_reports
    WHERE client_org_id = p_client_org_id AND framework_key = p_framework AND approval_status = 'issued'
    ORDER BY version DESC LIMIT 1;

  -- lifecycle: the first report of a chain is always the gap assessment
  IF v_head.id IS NULL AND p_kind <> 'gap_assessment' THEN
    RAISE EXCEPTION 'first report must be a gap assessment — no issued report to follow';
  END IF;

  INSERT INTO assessment_reports
      (client_org_id, track_id, framework_key, session_id, content_pack_id,
       version, supersedes, kind, title, overrides, created_by)
    VALUES
      (p_client_org_id, v_track, p_framework, v_session.id, v_session.content_pack_id,
       COALESCE(v_head.version, 0) + 1, v_head.id, p_kind, p_title,
       COALESCE(v_head.overrides, '{}'::jsonb),   -- narrative continuity v(n) -> v(n+1)
       auth.uid())
    RETURNING id INTO rid;

  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'assessment_report.created',
            jsonb_build_object('report_id', rid, 'client_org_id', p_client_org_id,
                               'framework', p_framework, 'kind', p_kind,
                               'version', COALESCE(v_head.version, 0) + 1));
  RETURN rid;
END $$;

-- Store the compiled payload (compile builds it app-side). Repeatable; never deletes the
-- row, so advisor overrides survive recompiles.
CREATE FUNCTION public.set_assessment_report_payload(p_report_id uuid, p_payload jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v assessment_reports%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM assessment_reports WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to report'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may compile assessment reports';
  END IF;
  IF v.approval_status NOT IN ('draft_ai','draft_human') THEN
    RAISE EXCEPTION 'report is approved/issued — create the next version instead';
  END IF;
  UPDATE assessment_reports SET payload = p_payload, compiled_at = now(), updated_at = now()
    WHERE id = p_report_id;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'assessment_report.compiled',
            jsonb_build_object('report_id', p_report_id, 'version', v.version));
END $$;

-- Advisor edits: narratives, section include/exclude, A–D classification. Whole-blob replace.
CREATE FUNCTION public.update_assessment_report_overrides(p_report_id uuid, p_overrides jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v assessment_reports%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM assessment_reports WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to report'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may edit assessment reports';
  END IF;
  IF v.approval_status NOT IN ('draft_ai','draft_human') THEN
    RAISE EXCEPTION 'report is approved/issued — create the next version instead';
  END IF;
  UPDATE assessment_reports SET overrides = p_overrides, updated_at = now() WHERE id = p_report_id;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'assessment_report.edited',
            jsonb_build_object('report_id', p_report_id));
END $$;

-- The logged human approval that makes the report issuable (and later client-visible).
CREATE FUNCTION public.approve_assessment_report(p_report_id uuid, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v assessment_reports%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM assessment_reports WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to report'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may approve assessment reports';
  END IF;
  IF v.approval_status NOT IN ('draft_ai','draft_human') THEN RAISE EXCEPTION 'report is not a draft'; END IF;
  IF v.compiled_at IS NULL THEN RAISE EXCEPTION 'compile the report before approving'; END IF;
  UPDATE assessment_reports SET approval_status = 'approved', updated_at = now() WHERE id = p_report_id;
  PERFORM public.record_approval('assessment_report', p_report_id, 'approved',
    COALESCE(p_note, 'Assessment report v' || v.version || ' approved'));
END $$;

-- Issue: called server-side AFTER the rendered HTML is written to object storage.
-- Inserts the immutable evidence document, supersedes the predecessor, logs. One transaction.
CREATE FUNCTION public.issue_assessment_report(
    p_report_id uuid, p_storage_path text, p_sha256 text, p_size bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v assessment_reports%ROWTYPE; did uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM assessment_reports WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to report'; END IF;
  -- advisor-only: RLS hides non-issued reports from client roles, so a client_admin
  -- could never legitimately reach an approved report to issue it
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may issue the report';
  END IF;
  IF v.approval_status <> 'approved' THEN RAISE EXCEPTION 'only an approved report can be issued'; END IF;

  INSERT INTO documents (client_org_id, track_id, original_filename, mime, size, sha256, storage_path, uploaded_by, source, source_id)
    VALUES (v.client_org_id, v.track_id, v.title || ' v' || v.version || '.html', 'text/html',
            p_size, p_sha256, p_storage_path, auth.uid(), 'assessment_report', p_report_id)
    RETURNING id INTO did;

  UPDATE assessment_reports SET approval_status = 'issued', issued_at = now(),
         issued_document_id = did, updated_at = now()
    WHERE id = p_report_id;

  IF v.supersedes IS NOT NULL THEN
    UPDATE assessment_reports SET approval_status = 'superseded', updated_at = now()
      WHERE id = v.supersedes AND approval_status = 'issued';
    IF FOUND THEN
      PERFORM public.record_approval('assessment_report', v.supersedes, 'superseded',
        'Superseded by v' || v.version);
    END IF;
  END IF;

  PERFORM public.record_approval('assessment_report', p_report_id, 'issued',
    'Assessment report v' || v.version || ' issued');
  RETURN did;
END $$;

REVOKE EXECUTE ON FUNCTION
  public.create_assessment_report(uuid, text, text, text, uuid),
  public.set_assessment_report_payload(uuid, jsonb),
  public.update_assessment_report_overrides(uuid, jsonb),
  public.approve_assessment_report(uuid, text),
  public.issue_assessment_report(uuid, text, text, bigint)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.create_assessment_report(uuid, text, text, text, uuid),
  public.set_assessment_report_payload(uuid, jsonb),
  public.update_assessment_report_overrides(uuid, jsonb),
  public.approve_assessment_report(uuid, text),
  public.issue_assessment_report(uuid, text, text, bigint)
TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
