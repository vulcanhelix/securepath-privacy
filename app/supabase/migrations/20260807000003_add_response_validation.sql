-- Add validation to upsert_response function
DROP FUNCTION IF EXISTS public.upsert_response CASCADE;

CREATE OR REPLACE FUNCTION public.upsert_response(
    p_session_id UUID,
    p_question_id UUID,
    p_response TEXT,
    p_findings TEXT,
    p_responsible_party TEXT,
    p_target_date DATE,
    p_status TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE 
  rid uuid;
  v_session public.assessment_sessions%ROWTYPE;
  v_question public.assessment_questions%ROWTYPE;
BEGIN
  -- Get and validate session exists and is accessible
  SELECT * INTO v_session FROM public.assessment_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment session not found';
  END IF;
  
  -- RLS should enforce client_org access; this is defense in depth
  IF v_session.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to assessment session';
  END IF;
  
  IF public.current_role_name() = 'read_only' THEN
    RAISE EXCEPTION 'read_only users cannot update responses';
  END IF;

  -- Get and validate question
  SELECT * INTO v_question FROM public.assessment_questions WHERE id = p_question_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Question not found';
  END IF;
  
  IF v_question.framework <> v_session.framework THEN
    RAISE EXCEPTION 'Question framework (%) does not match assessment framework (%)', v_question.framework, v_session.framework;
  END IF;
  
  IF v_question.active = FALSE THEN
    RAISE EXCEPTION 'Question is not active';
  END IF;

  -- Validate response value
  IF p_response NOT IN ('fully_compliant', 'partial', 'non_compliant', 'na') THEN
    RAISE EXCEPTION 'Invalid response value: %', p_response;
  END IF;

  -- Validate status value
  IF p_status NOT IN ('not_started', 'in_progress', 'complete', 'na') THEN
    RAISE EXCEPTION 'Invalid status value: %', p_status;
  END IF;

  INSERT INTO public.assessment_responses 
  (session_id, question_id, response, findings, responsible_party, target_date, status, updated_by)
  VALUES (p_session_id, p_question_id, p_response, p_findings, p_responsible_party, p_target_date, p_status, auth.uid())
  ON CONFLICT (session_id, question_id) DO UPDATE
  SET
    response = EXCLUDED.response,
    findings = COALESCE(p_findings, public.assessment_responses.findings),
    responsible_party = COALESCE(p_responsible_party, public.assessment_responses.responsible_party),
    target_date = COALESCE(p_target_date, public.assessment_responses.target_date),
    status = COALESCE(p_status, public.assessment_responses.status),
    updated_at = NOW(),
    updated_by = auth.uid()
  RETURNING id INTO rid;
  
  -- Trigger score recalculation
  PERFORM public.recalculate_assessment_score(p_session_id);
  
  -- Audit logging
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (
    auth.uid(), 
    public.current_practice(), 
    'assessment.response_updated', 
    jsonb_build_object('response_id', rid, 'session_id', p_session_id, 'question_id', p_question_id)
  );
  
  RETURN rid;
END;
$$;

-- Update batch function to validate JSON array
DROP FUNCTION IF EXISTS public.batch_upsert_responses CASCADE;

CREATE OR REPLACE FUNCTION public.batch_upsert_responses(
    p_session_id UUID,
    p_responses JSONB
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE resp jsonb;
BEGIN
  IF jsonb_typeof(p_responses) <> 'array' THEN
    RAISE EXCEPTION 'p_responses must be a JSON array';
  END IF;

  FOR resp IN SELECT * FROM jsonb_array_elements(p_responses) LOOP
    PERFORM public.upsert_response_no_recalc(
      p_session_id,
      resp->>'question_id',
      resp->>'response',
      COALESCE(resp->>'findings', NULL),
      COALESCE(resp->>'responsible_party', NULL),
      NULLIF(resp->>'target_date', '')::DATE,
      COALESCE(resp->>'status', 'not_started')
    );
  END LOOP;
  
  -- Recalculate score once after all responses are processed
  PERFORM public.recalculate_assessment_score(p_session_id);
END;
$$;