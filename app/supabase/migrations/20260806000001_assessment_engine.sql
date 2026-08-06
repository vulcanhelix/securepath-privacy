-- Assessment Engine Database Schema
-- Migration: F2 POPIA/GDPR Assessment Engine
-- This migration creates the database schema for the multi-tenant assessment engine
-- following the existing RLS patterns and architecture

-- Assessment sessions (one per assessment instance)
CREATE TABLE IF NOT EXISTS public.assessment_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_org_id UUID NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
  framework TEXT NOT NULL DEFAULT 'popia' CHECK (framework IN ('popia', 'gdpr', 'iso27701')),
  title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'in_progress' CHECK (status IN ('draft', 'in_progress', 'complete', 'archived')),
  score_pct INTEGER CHECK (score_pct BETWEEN 0 AND 100),
  rating TEXT CHECK (rating IN ('satisfactory', 'requires_improvement', 'significant_gaps')),
  org_name TEXT,
  auditor_name TEXT,
  audit_date DATE,
  audit_ref TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Static questions (versioned content)
CREATE TABLE IF NOT EXISTS public.assessment_questions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  framework TEXT NOT NULL CHECK (framework IN ('popia', 'gdpr', 'iso27701')),
  section_id INTEGER NOT NULL,
  section_name TEXT NOT NULL,
  subsection TEXT,
  question_number INTEGER NOT NULL,
  question TEXT NOT NULL,
  why_matters TEXT,
  regulatory_ref TEXT,
  risk TEXT NOT NULL CHECK (risk IN ('Critical', 'High', 'Medium', 'Low')),
  evidence_req TEXT,
  remediation TEXT,
  uid TEXT NOT NULL UNIQUE,
  version INTEGER DEFAULT 1,
  active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- User responses per session
CREATE TABLE IF NOT EXISTS public.assessment_responses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.assessment_sessions(id) ON DELETE CASCADE,
  question_id UUID NOT NULL REFERENCES public.assessment_questions(id) ON DELETE CASCADE,
  response TEXT NOT NULL CHECK (response IN ('fully_compliant', 'partial', 'non_compliant', 'na')),
  findings TEXT,
  responsible_party TEXT,
  target_date DATE,
  status TEXT NOT NULL DEFAULT 'not_started' CHECK (status IN ('not_started', 'in_progress', 'complete', 'na')),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  UNIQUE(session_id, question_id)
);

-- Scoring cache for performance
CREATE TABLE IF NOT EXISTS public.assessment_scores (
  session_id UUID PRIMARY KEY REFERENCES public.assessment_sessions(id) ON DELETE CASCADE,
  section_scores JSONB,
  overall_score JSONB,
  completion_pct INTEGER CHECK (completion_pct BETWEEN 0 AND 100),
  risk_summary JSONB,
  critical_gaps INTEGER DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_assessment_sessions_client_org ON public.assessment_sessions(client_org_id);
CREATE INDEX IF NOT EXISTS idx_assessment_sessions_framework ON public.assessment_sessions(framework);
CREATE INDEX IF NOT EXISTS idx_assessment_sessions_status ON public.assessment_sessions(status);
CREATE INDEX IF NOT EXISTS idx_assessment_sessions_created_at ON public.assessment_sessions(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_assessment_questions_framework ON public.assessment_questions(framework);
CREATE INDEX IF NOT EXISTS idx_assessment_questions_section ON public.assessment_questions(section_id);
CREATE INDEX IF NOT EXISTS idx_assessment_questions_active ON public.assessment_questions(active) WHERE active = TRUE;
CREATE INDEX IF NOT EXISTS idx_assessment_questions_uid ON public.assessment_questions(uid);

CREATE INDEX IF NOT EXISTS idx_assessment_responses_session ON public.assessment_responses(session_id);
CREATE INDEX IF NOT EXISTS idx_assessment_responses_question ON public.assessment_responses(question_id);
CREATE INDEX IF NOT EXISTS idx_assessment_responses_response ON public.assessment_responses(response);

-- Enable RLS on all assessment tables
ALTER TABLE public.assessment_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_sessions FORCE ROW LEVEL SECURITY;

ALTER TABLE public.assessment_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_questions FORCE ROW LEVEL SECURITY;

ALTER TABLE public.assessment_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_responses FORCE ROW LEVEL SECURITY;

ALTER TABLE public.assessment_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_scores FORCE ROW LEVEL SECURITY;

-- RLS Policies for assessment_sessions (follow existing assessment table pattern)
CREATE POLICY assessment_sessions_read ON public.assessment_sessions 
  FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));

CREATE POLICY assessment_sessions_write ON public.assessment_sessions 
  FOR ALL TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs())
         AND public.current_role_name() <> 'read_only')
  WITH CHECK (client_org_id IN (SELECT public.allowed_client_orgs())
              AND public.current_role_name() <> 'read_only');

-- Questions: globally readable (static content)
CREATE POLICY assessment_questions_read ON public.assessment_questions 
  FOR SELECT TO authenticated
  USING (true);

-- Responses: inherit session access via JOIN
CREATE POLICY assessment_responses_read ON public.assessment_responses
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.assessment_sessions s 
    WHERE s.id = assessment_responses.session_id
      AND s.client_org_id IN (SELECT public.allowed_client_orgs())
  ));

CREATE POLICY assessment_responses_write ON public.assessment_responses
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.assessment_sessions s 
    WHERE s.id = assessment_responses.session_id
      AND s.client_org_id IN (SELECT public.allowed_client_orgs())
      AND public.current_role_name() <> 'read_only'
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.assessment_sessions s 
    WHERE s.id = assessment_responses.session_id
      AND s.client_org_id IN (SELECT public.allowed_client_orgs())
      AND public.current_role_name() <> 'read_only'
  ));

-- Scores: same as responses
CREATE POLICY assessment_scores_read ON public.assessment_scores
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.assessment_sessions s 
    WHERE s.id = assessment_scores.session_id
      AND s.client_org_id IN (SELECT public.allowed_client_orgs())
  ));

-- Scoring function (core business logic)
CREATE OR REPLACE FUNCTION public.calculate_assessment_score(p_session_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  result JSONB;
  completion INTEGER;
  critical_count INTEGER;
  overall_total INTEGER;
  overall_achieved INTEGER;
BEGIN
  -- Calculate completion percentage
  SELECT 
    COALESCE(COUNT(CASE WHEN response IS NOT NULL AND response <> '' THEN 1 END), 0) * 100.0 / 
    NULLIF(COUNT(*), 0) INTO completion
  FROM public.assessment_responses 
  WHERE session_id = p_session_id;
  
  -- Calculate critical gaps count
  SELECT COUNT(*) INTO critical_count
  FROM public.assessment_responses r
  JOIN public.assessment_questions q ON r.question_id = q.id
  WHERE r.session_id = p_session_id AND r.response = 'non_compliant' AND q.risk = 'Critical';
  
  -- Calculate overall score
  SELECT 
    SUM(CASE WHEN r.response = 'fully_compliant' THEN 2 WHEN r.response = 'partial' THEN 1 ELSE 0 END) INTO overall_achieved
  FROM public.assessment_responses r
  WHERE r.session_id = p_session_id AND r.response <> 'na';
  
  SELECT COUNT(*) * 2 INTO overall_total
  FROM public.assessment_responses r
  WHERE r.session_id = p_session_id AND r.response <> 'na';
  
  -- Build the result
  SELECT jsonb_build_object(
    'section_scores', '{}'::jsonb,  -- Will be expanded in Phase 5 with section-by-section scoring
    'overall', jsonb_build_object(
      'score', COALESCE(overall_achieved, 0),
      'total', COALESCE(overall_total, 0),
      'pct', CASE WHEN overall_total > 0 THEN ROUND(overall_achieved::numeric / overall_total * 100) ELSE 0 END,
      'rating', CASE WHEN overall_total > 0 AND overall_achieved::numeric / overall_total >= 0.75 THEN 'satisfactory'
        WHEN overall_total > 0 AND overall_achieved::numeric / overall_total >= 0.50 THEN 'requires_improvement'
        ELSE 'significant_gaps' END
    ),
    'completion_pct', COALESCE(ROUND(completion), 0),
    'risk_summary', '{}'::jsonb,  -- Will be expanded in Phase 5 with detailed risk breakdown
    'critical_gaps', COALESCE(critical_count, 0)
  ) INTO result;
  
  RETURN result;
END;
$$;

-- Function to recalculate and cache scores
CREATE OR REPLACE FUNCTION public.recalculate_assessment_score(p_session_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  score_result JSONB;
BEGIN
  score_result := public.calculate_assessment_score(p_session_id);
  
  INSERT INTO public.assessment_scores (session_id, section_scores, overall_score, completion_pct, risk_summary, critical_gaps)
  VALUES (
    p_session_id,
    score_result->'section_scores',
    score_result->'overall',
    (score_result->>'completion_pct')::INTEGER,
    score_result->'risk_summary',
    (score_result->>'critical_gaps')::INTEGER
  )
  ON CONFLICT (session_id) DO UPDATE
  SET
    section_scores = EXCLUDED.section_scores,
    overall_score = EXCLUDED.overall_score,
    completion_pct = EXCLUDED.completion_pct,
    risk_summary = EXCLUDED.risk_summary,
    critical_gaps = EXCLUDED.critical_gaps,
    updated_at = NOW();
    
  -- Update session with score summary
  UPDATE public.assessment_sessions
  SET
    score_pct = (score_result->'overall'->>'pct')::INTEGER,
    rating = score_result->'overall'->>'rating',
    updated_at = NOW()
  WHERE id = p_session_id;
END;
$$;

-- RPC function to create assessment session
CREATE OR REPLACE FUNCTION public.create_assessment(
    p_client_org_id UUID,
    p_framework TEXT,
    p_title TEXT,
    p_org_name TEXT,
    p_auditor_name TEXT,
    p_audit_date DATE,
    p_audit_ref TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE aid uuid;
BEGIN
  -- RLS enforces client_org_id access via allowed_client_orgs()
  INSERT INTO public.assessment_sessions 
  (client_org_id, framework, title, org_name, auditor_name, audit_date, audit_ref)
  VALUES (p_client_org_id, p_framework, p_title, p_org_name, p_auditor_name, p_audit_date, p_audit_ref)
  RETURNING id INTO aid;
  
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

-- RPC function to update assessment metadata
CREATE OR REPLACE FUNCTION public.update_assessment(
    p_id UUID,
    p_title TEXT,
    p_org_name TEXT,
    p_auditor_name TEXT,
    p_audit_date DATE,
    p_audit_ref TEXT,
    p_status TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.assessment_sessions
  SET 
    title = COALESCE(p_title, title),
    org_name = COALESCE(p_org_name, org_name),
    auditor_name = COALESCE(p_auditor_name, auditor_name),
    audit_date = COALESCE(p_audit_date, audit_date),
    audit_ref = COALESCE(p_audit_ref, audit_ref),
    status = COALESCE(p_status, status),
    updated_at = NOW()
  WHERE id = p_id;
  
  -- Audit logging
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (
    auth.uid(), 
    public.current_practice(), 
    'assessment.updated', 
    jsonb_build_object('assessment_id', p_id)
  );
END;
$$;

-- RPC function to create or update response
CREATE OR REPLACE FUNCTION public.upsert_response(
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

-- RPC function for batch response updates
CREATE OR REPLACE FUNCTION public.batch_upsert_responses(
    p_session_id UUID,
    p_responses JSONB
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE resp jsonb;
BEGIN
  FOR resp IN SELECT * FROM jsonb_array_elements(p_responses) LOOP
    PERFORM public.upsert_response(
      p_session_id,
      resp->>'question_id',
      resp->>'response',
      COALESCE(resp->>'findings', NULL),
      COALESCE(resp->>'responsible_party', NULL),
      COALESCE((resp->>'target_date')::DATE, NULL),
      COALESCE(resp->>'status', 'not_started')
    );
  END LOOP;
END;
$$;