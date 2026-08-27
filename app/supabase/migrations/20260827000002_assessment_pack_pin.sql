-- Pin every assessment session to the content pack it was started on.
--
-- 20260827000001 deactivated the live POPIA bank and scored new active
-- questions, so reopening a legacy session mixed old responses with the v2
-- editor/denominator. Stamp content_pack_id, score that pack (active or not),
-- keep legacy modules 7–8 in scope, and reject out-of-pack / out-of-scale upserts.

BEGIN;

ALTER TABLE public.assessment_sessions
  ADD COLUMN IF NOT EXISTS content_pack_id uuid REFERENCES public.content_packs(id);
COMMENT ON COLUMN public.assessment_sessions.content_pack_id IS
  'Pack this assessment was started on. Question load, scoring, and upserts use this, not the live active bank.';

CREATE INDEX IF NOT EXISTS assessment_sessions_content_pack_idx
  ON public.assessment_sessions (content_pack_id);

-- Existing sessions: majority pack among their responses, else the oldest pack
-- for that framework (POPIA v1 / the original 8-module bank).
UPDATE public.assessment_sessions s
   SET content_pack_id = (
     SELECT q.content_pack_id
       FROM public.assessment_responses r
       JOIN public.assessment_questions q ON q.id = r.question_id
      WHERE r.session_id = s.id AND q.content_pack_id IS NOT NULL
      GROUP BY q.content_pack_id
      ORDER BY COUNT(*) DESC
      LIMIT 1
   )
 WHERE s.content_pack_id IS NULL;

UPDATE public.assessment_sessions s
   SET content_pack_id = (
     SELECT cp.id
       FROM public.content_packs cp
      WHERE cp.framework_key = s.framework AND cp.practice_id IS NULL
      ORDER BY cp.version ASC
      LIMIT 1
   )
 WHERE s.content_pack_id IS NULL;

-- Staff S1A (section 11) is never in the advisor assessment. Legacy POPIA
-- modules 7–8 stay in scope so v1 sessions remain scorable.
CREATE OR REPLACE FUNCTION public.assessment_question_in_scope(
    p_framework text, p_section_id int, p_applies_to text, p_org_scale text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_framework IS DISTINCT FROM 'popia' THEN TRUE
    WHEN p_section_id = 11 THEN FALSE
    WHEN COALESCE(p_applies_to, 'all') = 'all' THEN TRUE
    WHEN COALESCE(p_org_scale, 'large') = p_applies_to THEN TRUE
    ELSE FALSE
  END
$$;

CREATE OR REPLACE FUNCTION public.assert_question_in_assessment_scope(
    p_session public.assessment_sessions,
    p_question public.assessment_questions)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = public AS $$
BEGIN
  IF p_question.framework IS DISTINCT FROM p_session.framework THEN
    RAISE EXCEPTION 'Question framework (%) does not match assessment framework (%)',
      p_question.framework, p_session.framework;
  END IF;
  IF p_session.content_pack_id IS NULL THEN
    RAISE EXCEPTION 'Assessment has no content pack';
  END IF;
  IF p_question.content_pack_id IS DISTINCT FROM p_session.content_pack_id THEN
    RAISE EXCEPTION 'Question does not belong to this assessment pack';
  END IF;
  IF NOT public.assessment_question_in_scope(
       p_question.framework, p_question.section_id, p_question.applies_to, p_session.org_scale) THEN
    RAISE EXCEPTION 'Question is out of scope for this assessment';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION public.assert_question_in_assessment_scope(public.assessment_sessions, public.assessment_questions)
  FROM anon, public;

CREATE OR REPLACE FUNCTION public.create_assessment(
    p_client_org_id UUID, p_framework TEXT, p_title TEXT, p_org_name TEXT,
    p_auditor_name TEXT, p_audit_date DATE, p_audit_ref TEXT,
    p_org_scale TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE aid uuid; v_kind text; v_track uuid; v_stage int; v_scale text; v_pack uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  IF public.current_role_name() = 'read_only' THEN
    RAISE EXCEPTION 'read_only users cannot create assessments';
  END IF;

  SELECT track_kind INTO v_kind FROM frameworks WHERE key = p_framework;
  IF v_kind IS NULL THEN RAISE EXCEPTION 'unknown framework %', p_framework; END IF;
  SELECT id, current_stage INTO v_track, v_stage
    FROM tracks WHERE client_org_id = p_client_org_id AND track_kind = v_kind;
  IF v_track IS NULL THEN
    v_track := public.create_track(p_client_org_id, v_kind);
    v_stage := 0;
  END IF;

  v_scale := p_org_scale;
  IF v_scale IS NULL THEN
    SELECT org_scale INTO v_scale FROM client_orgs WHERE id = p_client_org_id;
  END IF;
  IF v_scale IS NULL THEN v_scale := 'large'; END IF;
  IF v_scale NOT IN ('sme', 'large') THEN RAISE EXCEPTION 'org_scale must be sme or large'; END IF;

  SELECT id INTO v_pack
    FROM public.content_packs
   WHERE framework_key = p_framework AND status = 'published' AND practice_id IS NULL
   ORDER BY version DESC
   LIMIT 1;
  IF v_pack IS NULL THEN RAISE EXCEPTION 'no published content pack for framework %', p_framework; END IF;

  INSERT INTO public.assessment_sessions
    (client_org_id, framework, title, org_name, auditor_name, audit_date, audit_ref, track_id, org_scale, content_pack_id)
  VALUES (p_client_org_id, p_framework, p_title, p_org_name, p_auditor_name, p_audit_date, p_audit_ref, v_track, v_scale, v_pack)
  RETURNING id INTO aid;

  IF v_stage = 0 THEN
    PERFORM public.advance_track_stage(v_track, 1, 'Stage 1: assessment started');
  END IF;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.current_practice(), 'assessment.created',
          jsonb_build_object('assessment_id', aid, 'client_org_id', p_client_org_id, 'org_scale', v_scale, 'content_pack_id', v_pack));
  RETURN aid;
END $$;

CREATE OR REPLACE FUNCTION public.calculate_assessment_score(p_session_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  result JSONB;
  v_framework TEXT;
  v_org_scale TEXT;
  v_pack uuid;
  v_total_questions INTEGER;
  v_answered_non_na INTEGER;
  v_overall_achieved INTEGER;
  v_overall_total INTEGER;
  v_completion_pct INTEGER;
  v_section_scores JSONB;
  v_risk_summary JSONB;
  v_critical_gaps INTEGER;
BEGIN
  SELECT framework, org_scale, content_pack_id INTO v_framework, v_org_scale, v_pack
  FROM public.assessment_sessions
  WHERE id = p_session_id;

  SELECT COUNT(*) INTO v_total_questions
  FROM public.assessment_questions q
  WHERE q.content_pack_id = v_pack
    AND public.assessment_question_in_scope(q.framework, q.section_id, q.applies_to, v_org_scale);

  SELECT COUNT(*) INTO v_answered_non_na
  FROM public.assessment_responses r
  JOIN public.assessment_questions q ON r.question_id = q.id
  WHERE r.session_id = p_session_id
    AND q.content_pack_id = v_pack
    AND r.response IS NOT NULL AND r.response <> '' AND r.response <> 'na'
    AND public.assessment_question_in_scope(q.framework, q.section_id, q.applies_to, v_org_scale);

  v_completion_pct := CASE
    WHEN v_total_questions > 0
    THEN ROUND(v_answered_non_na::numeric / v_total_questions * 100)
    ELSE 0
  END;

  SELECT
    SUM(CASE WHEN r.response = 'fully_compliant' THEN 2
             WHEN r.response = 'partial' THEN 1
             ELSE 0 END) INTO v_overall_achieved
  FROM public.assessment_responses r
  JOIN public.assessment_questions q ON r.question_id = q.id
  WHERE r.session_id = p_session_id AND r.response <> 'na'
    AND q.content_pack_id = v_pack
    AND public.assessment_question_in_scope(q.framework, q.section_id, q.applies_to, v_org_scale);

  SELECT COUNT(*) * 2 INTO v_overall_total
  FROM public.assessment_responses r
  JOIN public.assessment_questions q ON r.question_id = q.id
  WHERE r.session_id = p_session_id AND r.response <> 'na'
    AND q.content_pack_id = v_pack
    AND public.assessment_question_in_scope(q.framework, q.section_id, q.applies_to, v_org_scale);

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
      AND q.content_pack_id = v_pack
      AND public.assessment_question_in_scope(q.framework, q.section_id, q.applies_to, v_org_scale)
    GROUP BY q.section_id
  ) sec;

  SELECT COALESCE(jsonb_object_agg(risk_level, cnt), '{}'::jsonb) INTO v_risk_summary
  FROM (
    SELECT q.risk as risk_level, COUNT(*) as cnt
    FROM public.assessment_responses r
    JOIN public.assessment_questions q ON r.question_id = q.id
    WHERE r.session_id = p_session_id AND r.response = 'non_compliant'
      AND q.content_pack_id = v_pack
      AND public.assessment_question_in_scope(q.framework, q.section_id, q.applies_to, v_org_scale)
    GROUP BY q.risk
  ) rs;

  SELECT COUNT(*) INTO v_critical_gaps
  FROM public.assessment_responses r
  JOIN public.assessment_questions q ON r.question_id = q.id
  WHERE r.session_id = p_session_id AND r.response = 'non_compliant' AND q.risk = 'Critical'
    AND q.content_pack_id = v_pack
    AND public.assessment_question_in_scope(q.framework, q.section_id, q.applies_to, v_org_scale);

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
  SELECT * INTO v_session FROM public.assessment_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment session not found';
  END IF;

  IF v_session.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to assessment session';
  END IF;

  IF public.current_role_name() = 'read_only' THEN
    RAISE EXCEPTION 'read_only users cannot update responses';
  END IF;

  SELECT * INTO v_question FROM public.assessment_questions WHERE id = p_question_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Question not found';
  END IF;

  PERFORM public.assert_question_in_assessment_scope(v_session, v_question);

  IF p_response NOT IN ('fully_compliant', 'partial', 'non_compliant', 'na') THEN
    RAISE EXCEPTION 'Invalid response value: %', p_response;
  END IF;

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

  PERFORM public.recalculate_assessment_score(p_session_id);

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

CREATE OR REPLACE FUNCTION public.upsert_response_no_recalc(
    p_session_id UUID, p_question_id UUID, p_response TEXT, p_findings TEXT,
    p_responsible_party TEXT, p_target_date DATE, p_status TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid uuid; v_session public.assessment_sessions%ROWTYPE; v_question public.assessment_questions%ROWTYPE;
BEGIN
  v_session := public.assert_session_writable(p_session_id);
  SELECT * INTO v_question FROM public.assessment_questions WHERE id = p_question_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Question not found'; END IF;
  PERFORM public.assert_question_in_assessment_scope(v_session, v_question);
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

REVOKE EXECUTE ON FUNCTION public.create_assessment(uuid, text, text, text, text, date, text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.create_assessment(uuid, text, text, text, text, date, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_assessment_score(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.calculate_assessment_score(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.upsert_response(uuid, uuid, text, text, text, date, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.upsert_response(uuid, uuid, text, text, text, date, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.upsert_response_no_recalc(uuid, uuid, text, text, text, date, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.upsert_response_no_recalc(uuid, uuid, text, text, text, date, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
