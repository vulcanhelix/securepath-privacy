-- Resolve the legacy assessments table duplication
-- The new assessment engine uses assessment_sessions, assessment_questions, 
-- assessment_responses, and assessment_scores. The legacy assessments table was 
-- an early placeholder that is now replaced by this richer schema.

-- Drop legacy table only if it exists and is empty to avoid data loss
DO $$
DECLARE
  row_count INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'assessments') THEN
    SELECT COUNT(*) INTO row_count FROM public.assessments;
    IF row_count = 0 THEN
      DROP TABLE public.assessments CASCADE;
    ELSE
      RAISE NOTICE 'Legacy assessments table has % rows and was not dropped. Manual migration required.', row_count;
    END IF;
  END IF;
END;
$$;

-- Ensure the new assessment tables follow the documented pattern
COMMENT ON TABLE public.assessment_sessions IS 'Assessment instances (replaces legacy assessments table). client_org_id + RLS via allowed_client_orgs().';
COMMENT ON TABLE public.assessment_questions IS 'Static assessment question content, versioned and framework-specific.';
COMMENT ON TABLE public.assessment_responses IS 'User responses per assessment session, with remediation tracking.';
COMMENT ON TABLE public.assessment_scores IS 'Cached score calculations for assessment sessions.';