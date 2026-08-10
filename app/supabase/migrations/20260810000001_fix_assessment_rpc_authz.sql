-- SECURITY FIX (2026-08-10): assessment RPCs are SECURITY DEFINER owned by a superuser,
-- so they BYPASS RLS. create_assessment / update_assessment / upsert_response_no_recalc /
-- batch_upsert_responses trusted a comment instead of checking access → confirmed
-- cross-tenant write on live staging (any caller, incl. anon, could overwrite any
-- assessment by id). Add the same allowed_client_orgs() guard upsert_response already has.

-- ---------- shared guard: caller may touch this session's client_org, and isn't read-only ----------
CREATE OR REPLACE FUNCTION public.assert_session_writable(p_session_id uuid)
RETURNS public.assessment_sessions LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_session public.assessment_sessions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_session FROM public.assessment_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assessment session not found'; END IF;
  IF v_session.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to assessment session';
  END IF;
  IF public.current_role_name() = 'read_only' THEN
    RAISE EXCEPTION 'read_only users cannot modify assessments';
  END IF;
  RETURN v_session;
END $$;
REVOKE EXECUTE ON FUNCTION public.assert_session_writable(uuid) FROM anon, public;

-- ---------- create_assessment: validate caller owns the target client_org ----------
CREATE OR REPLACE FUNCTION public.create_assessment(
    p_client_org_id UUID, p_framework TEXT, p_title TEXT, p_org_name TEXT,
    p_auditor_name TEXT, p_audit_date DATE, p_audit_ref TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE aid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  IF public.current_role_name() = 'read_only' THEN
    RAISE EXCEPTION 'read_only users cannot create assessments';
  END IF;
  INSERT INTO public.assessment_sessions
    (client_org_id, framework, title, org_name, auditor_name, audit_date, audit_ref)
  VALUES (p_client_org_id, p_framework, p_title, p_org_name, p_auditor_name, p_audit_date, p_audit_ref)
  RETURNING id INTO aid;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.current_practice(), 'assessment.created',
          jsonb_build_object('assessment_id', aid, 'client_org_id', p_client_org_id));
  RETURN aid;
END $$;

-- ---------- update_assessment: guard session access ----------
CREATE OR REPLACE FUNCTION public.update_assessment(
    p_id UUID, p_title TEXT, p_org_name TEXT, p_auditor_name TEXT,
    p_audit_date DATE, p_audit_ref TEXT, p_status TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.assert_session_writable(p_id);
  UPDATE public.assessment_sessions SET
    title = COALESCE(p_title, title),
    org_name = COALESCE(p_org_name, org_name),
    auditor_name = COALESCE(p_auditor_name, auditor_name),
    audit_date = COALESCE(p_audit_date, audit_date),
    audit_ref = COALESCE(p_audit_ref, audit_ref),
    status = COALESCE(p_status, status),
    updated_at = NOW()
  WHERE id = p_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.current_practice(), 'assessment.updated',
          jsonb_build_object('assessment_id', p_id));
END $$;

-- ---------- upsert_response_no_recalc: guard session access (used by batch) ----------
CREATE OR REPLACE FUNCTION public.upsert_response_no_recalc(
    p_session_id UUID, p_question_id UUID, p_response TEXT, p_findings TEXT,
    p_responsible_party TEXT, p_target_date DATE, p_status TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid uuid; v_session public.assessment_sessions%ROWTYPE; v_question public.assessment_questions%ROWTYPE;
BEGIN
  v_session := public.assert_session_writable(p_session_id);
  SELECT * INTO v_question FROM public.assessment_questions WHERE id = p_question_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Question not found'; END IF;
  IF v_question.framework <> v_session.framework THEN
    RAISE EXCEPTION 'Question framework (%) does not match assessment framework (%)',
      v_question.framework, v_session.framework;
  END IF;
  IF v_question.active = FALSE THEN RAISE EXCEPTION 'Question is not active'; END IF;
  IF p_response NOT IN ('fully_compliant','partial','non_compliant','na') THEN
    RAISE EXCEPTION 'Invalid response value: %', p_response;
  END IF;
  IF p_status NOT IN ('not_started','in_progress','complete','na') THEN
    RAISE EXCEPTION 'Invalid status value: %', p_status;
  END IF;
  INSERT INTO public.assessment_responses
    (session_id, question_id, response, findings, responsible_party, target_date, status, updated_by)
  VALUES (p_session_id, p_question_id, p_response, p_findings, p_responsible_party, p_target_date, p_status, auth.uid())
  ON CONFLICT (session_id, question_id) DO UPDATE SET
    response = EXCLUDED.response,
    findings = COALESCE(p_findings, public.assessment_responses.findings),
    responsible_party = COALESCE(p_responsible_party, public.assessment_responses.responsible_party),
    target_date = COALESCE(p_target_date, public.assessment_responses.target_date),
    status = COALESCE(p_status, public.assessment_responses.status),
    updated_at = NOW(), updated_by = auth.uid()
  RETURNING id INTO rid;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.current_practice(), 'assessment.response_updated',
          jsonb_build_object('response_id', rid, 'session_id', p_session_id, 'question_id', p_question_id));
  RETURN rid;
END $$;

-- batch_upsert_responses guards once up front (each row re-checks the same session anyway).
CREATE OR REPLACE FUNCTION public.batch_upsert_responses(p_session_id UUID, p_responses JSONB)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE resp jsonb;
BEGIN
  PERFORM public.assert_session_writable(p_session_id);
  FOR resp IN SELECT * FROM jsonb_array_elements(p_responses) LOOP
    PERFORM public.upsert_response_no_recalc(
      p_session_id, (resp->>'question_id')::uuid, resp->>'response',
      COALESCE(resp->>'findings', NULL), COALESCE(resp->>'responsible_party', NULL),
      NULLIF(resp->>'target_date','')::DATE, COALESCE(resp->>'status','not_started'));
  END LOOP;
  PERFORM public.recalculate_assessment_score(p_session_id);
END $$;

-- ---------- lock the execute + table grant surface: anon gets nothing ----------
REVOKE EXECUTE ON FUNCTION
  public.create_assessment(uuid, text, text, text, text, date, text),
  public.update_assessment(uuid, text, text, text, date, text, text),
  public.upsert_response(uuid, uuid, text, text, text, date, text),
  public.upsert_response_no_recalc(uuid, uuid, text, text, text, date, text),
  public.batch_upsert_responses(uuid, jsonb),
  public.calculate_assessment_score(uuid),
  public.recalculate_assessment_score(uuid)
FROM anon, public;

-- ponytail: revoke all from anon; re-grant nothing. Add anon SELECT on assessment_questions
-- only if/when a public lead-gen funnel needs the bank.
REVOKE ALL ON public.assessment_sessions, public.assessment_responses,
  public.assessment_scores, public.assessment_questions FROM anon;
