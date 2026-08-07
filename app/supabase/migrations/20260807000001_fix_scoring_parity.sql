-- Fix assessment scoring parity and response pre-population
-- This migration corrects the scoring logic to match the desktop app methodology

-- Drop and recreate create_assessment with response pre-population
DROP FUNCTION IF EXISTS public.create_assessment CASCADE;

CREATE OR REPLACE FUNCTION public.create_assessment(
    p_client_org_id UUID,
    p_framework TEXT,
    p_title TEXT,
    p_org_name TEXT,
    p_auditor_name TEXT,
    p_audit_date DATE,
    p_audit_ref TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE 
  aid uuid;
  q RECORD;
BEGIN
  -- RLS enforces client_org_id access via allowed_client_orgs()
  INSERT INTO public.assessment_sessions 
  (client_org_id, framework, title, org_name, auditor_name, audit_date, audit_ref)
  VALUES (p_client_org_id, p_framework, p_title, p_org_name, p_auditor_name, p_audit_date, p_audit_ref)
  RETURNING id INTO aid;
  
  -- Pre-populate response rows for all active questions in this framework
  -- This is required for accurate completion percentage and scoring
  FOR q IN 
    SELECT id FROM public.assessment_questions 
    WHERE framework = p_framework AND active = TRUE
    ORDER BY section_id, question_number
  LOOP
    INSERT INTO public.assessment_responses 
    (session_id, question_id, response, status, updated_by)
    VALUES (aid, q.id, 'na', 'na', auth.uid())
    ON CONFLICT (session_id, question_id) DO NOTHING;
  END LOOP;
  
  -- Initialize score cache
  PERFORM public.recalculate_assessment_score(aid);
  
  -- Audit logging
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (
    auth.uid(), 
    public.current_practice(), 
    'assessment.created', 
    jsonb_build_object('assessment_id', aid, 'client_org_id', p_client_org_id)
  );
  
  RETURN aid;
END;
$$;

-- Rewrite calculate_assessment_score for exact parity
drop function if exists public.calculate_assessment_score CASCADE;

CREATE OR REPLACE FUNCTION public.calculate_assessment_score(p_session_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  result JSONB;
  v_session TEXT;
  v_total_questions INTEGER;
  v_answered_non_na INTEGER;
  v_overall_achieved INTEGER;
  v_overall_total INTEGER;
  v_completion_pct INTEGER;
  v_section_scores JSONB;
  v_risk_summary JSONB;
  v_critical_gaps INTEGER;
BEGIN
  -- Get the session framework
  SELECT framework INTO v_session
  FROM public.assessment_sessions
  WHERE id = p_session_id;
  
  -- Total questions for this framework (to match desktop app: completion = answered / total questions)
  SELECT COUNT(*) INTO v_total_questions
  FROM public.assessment_questions
  WHERE framework = v_session AND active = TRUE;
  
  -- Count answered non-NA responses
  SELECT COUNT(*) INTO v_answered_non_na
  FROM public.assessment_responses r
  WHERE r.session_id = p_session_id
    AND r.response IS NOT NULL
    AND r.response <> ''
    AND r.response <> 'na';
  
  -- Completion percentage: answered (non-NA) / total questions in framework
  v_completion_pct := CASE 
    WHEN v_total_questions > 0 
    THEN ROUND(v_answered_non_na::numeric / v_total_questions * 100)
    ELSE 0 
  END;
  
  -- Calculate overall score (only non-NA answers contribute)
  SELECT 
    SUM(CASE WHEN r.response = 'fully_compliant' THEN 2 
             WHEN r.response = 'partial' THEN 1 
             ELSE 0 END) INTO v_overall_achieved
  FROM public.assessment_responses r
  WHERE r.session_id = p_session_id AND r.response <> 'na';
  
  SELECT COUNT(*) * 2 INTO v_overall_total
  FROM public.assessment_responses r
  WHERE r.session_id = p_session_id AND r.response <> 'na';
  
  -- Calculate section scores
  SELECT COALESCE(jsonb_object_agg(
    'S' || sec.section_id,
    jsonb_build_object(
      'section_name', sec.section_name,
      'score', sec.achieved_points,
      'total', sec.total_points,
      'pct', CASE WHEN sec.total_points > 0 
                  THEN ROUND(sec.achieved_points::numeric / sec.total_points * 100) 
                  ELSE 0 END
    )
  ), '{}'::jsonb) INTO v_section_scores
  FROM (
    SELECT 
      q.section_id,
      MAX(q.section_name) as section_name,
      SUM(CASE WHEN r.response = 'fully_compliant' THEN 2 
               WHEN r.response = 'partial' THEN 1 
               ELSE 0 END) as achieved_points,
      COUNT(CASE WHEN r.response <> 'na' THEN 1 END) * 2 as total_points
    FROM public.assessment_responses r
    JOIN public.assessment_questions q ON r.question_id = q.id
    WHERE r.session_id = p_session_id
    GROUP BY q.section_id
  ) sec;
  
  -- Calculate risk summary: non-compliant counts by risk level
  SELECT COALESCE(jsonb_object_agg(risk_level, cnt), '{}'::jsonb) INTO v_risk_summary
  FROM (
    SELECT q.risk as risk_level, COUNT(*) as cnt
    FROM public.assessment_responses r
    JOIN public.assessment_questions q ON r.question_id = q.id
    WHERE r.session_id = p_session_id AND r.response = 'non_compliant'
    GROUP BY q.risk
  ) rs;
  
  -- Count critical gaps (non-compliant + Critical risk)
  SELECT COUNT(*) INTO v_critical_gaps
  FROM public.assessment_responses r
  JOIN public.assessment_questions q ON r.question_id = q.id
  WHERE r.session_id = p_session_id AND r.response = 'non_compliant' AND q.risk = 'Critical';
  
  -- Build final result
  result := jsonb_build_object(
    'section_scores', v_section_scores,
    'overall', jsonb_build_object(
      'score', COALESCE(v_overall_achieved, 0),
      'total', COALESCE(v_overall_total, 0),
      'pct', CASE WHEN v_overall_total > 0 
                  THEN ROUND(v_overall_achieved::numeric / v_overall_total * 100) 
                  ELSE 0 END,
      'rating', CASE 
        WHEN v_overall_total = 0 THEN 'significant_gaps'
        WHEN v_overall_achieved::numeric / v_overall_total >= 0.75 THEN 'satisfactory'
        WHEN v_overall_achieved::numeric / v_overall_total >= 0.50 THEN 'requires_improvement'
        ELSE 'significant_gaps'
      END
    ),
    'completion_pct', v_completion_pct,
    'risk_summary', v_risk_summary,
    'critical_gaps', v_critical_gaps
  );
  
  RETURN result;
END;
$$;

-- Keep recalculate_assessment_score as-is (it calls calculate)
-- It will now use the corrected logic.