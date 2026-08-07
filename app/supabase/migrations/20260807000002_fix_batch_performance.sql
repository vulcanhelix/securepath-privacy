-- Fix batch response performance: avoid N+1 score recalculation
-- Create a response upsert function that does not recalculate, then recalculate once after batch

CREATE OR REPLACE FUNCTION public.upsert_response_no_recalc(
    p_session_id UUID,
    p_question_id UUID,
    p_response TEXT,
    p_findings TEXT,
    p_responsible_party TEXT,
    p_target_date DATE,
    p_status TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid uuid;
BEGIN
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

-- Rewrite batch function to avoid repeated score recalculation
DROP FUNCTION IF EXISTS public.batch_upsert_responses CASCADE;

CREATE OR REPLACE FUNCTION public.batch_upsert_responses(
    p_session_id UUID,
    p_responses JSONB
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE resp jsonb;
BEGIN
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