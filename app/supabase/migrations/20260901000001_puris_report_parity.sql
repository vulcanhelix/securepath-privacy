-- Puris report parity: evidence-pending assessment status, accurate POPIA report
-- scope/template metadata, and a mandatory advisor accuracy confirmation before issue.

BEGIN;

ALTER TABLE public.assessment_responses
  DROP CONSTRAINT IF EXISTS assessment_responses_response_check;
ALTER TABLE public.assessment_responses
  ADD CONSTRAINT assessment_responses_response_check
  CHECK (response IN ('fully_compliant', 'partial', 'under_review', 'non_compliant', 'na'));

CREATE OR REPLACE FUNCTION public.upsert_response(
    p_session_id UUID, p_question_id UUID, p_response TEXT, p_findings TEXT,
    p_responsible_party TEXT, p_target_date DATE, p_status TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  rid uuid;
  v_session public.assessment_sessions%ROWTYPE;
  v_question public.assessment_questions%ROWTYPE;
BEGIN
  SELECT * INTO v_session FROM public.assessment_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assessment session not found'; END IF;
  IF v_session.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to assessment session';
  END IF;
  IF public.current_role_name() = 'read_only' THEN
    RAISE EXCEPTION 'read_only users cannot update responses';
  END IF;

  SELECT * INTO v_question FROM public.assessment_questions WHERE id = p_question_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Question not found'; END IF;
  PERFORM public.assert_question_in_assessment_scope(v_session, v_question);

  IF p_response NOT IN ('fully_compliant', 'partial', 'under_review', 'non_compliant', 'na') THEN
    RAISE EXCEPTION 'Invalid response value: %', p_response;
  END IF;
  IF p_status NOT IN ('not_started', 'in_progress', 'complete', 'na') THEN
    RAISE EXCEPTION 'Invalid status value: %', p_status;
  END IF;

  INSERT INTO public.assessment_responses
    (session_id, question_id, response, findings, responsible_party, target_date, status, updated_by)
  VALUES
    (p_session_id, p_question_id, p_response, p_findings, p_responsible_party,
     p_target_date, p_status, auth.uid())
  ON CONFLICT (session_id, question_id) DO UPDATE SET
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
    auth.uid(), public.current_practice(), 'assessment.response_updated',
    jsonb_build_object('response_id', rid, 'session_id', p_session_id, 'question_id', p_question_id)
  );
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION public.upsert_response_no_recalc(
    p_session_id UUID, p_question_id UUID, p_response TEXT, p_findings TEXT,
    p_responsible_party TEXT, p_target_date DATE, p_status TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  rid uuid;
  v_session public.assessment_sessions%ROWTYPE;
  v_question public.assessment_questions%ROWTYPE;
BEGIN
  v_session := public.assert_session_writable(p_session_id);
  SELECT * INTO v_question FROM public.assessment_questions WHERE id = p_question_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Question not found'; END IF;
  PERFORM public.assert_question_in_assessment_scope(v_session, v_question);
  IF p_response NOT IN ('fully_compliant', 'partial', 'under_review', 'non_compliant', 'na') THEN
    RAISE EXCEPTION 'Invalid response value: %', p_response;
  END IF;
  IF p_status NOT IN ('not_started', 'in_progress', 'complete', 'na') THEN
    RAISE EXCEPTION 'Invalid status value: %', p_status;
  END IF;

  INSERT INTO public.assessment_responses
    (session_id, question_id, response, findings, responsible_party, target_date, status, updated_by)
  VALUES
    (p_session_id, p_question_id, p_response, p_findings, p_responsible_party,
     p_target_date, p_status, auth.uid())
  ON CONFLICT (session_id, question_id) DO UPDATE SET
    response = EXCLUDED.response,
    findings = COALESCE(p_findings, public.assessment_responses.findings),
    responsible_party = COALESCE(p_responsible_party, public.assessment_responses.responsible_party),
    target_date = COALESCE(p_target_date, public.assessment_responses.target_date),
    status = COALESCE(p_status, public.assessment_responses.status),
    updated_at = NOW(),
    updated_by = auth.uid()
  RETURNING id INTO rid;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (
    auth.uid(), public.current_practice(), 'assessment.response_updated',
    jsonb_build_object('response_id', rid, 'session_id', p_session_id, 'question_id', p_question_id)
  );
  RETURN rid;
END $$;

-- Preserve the frozen aggregate implementation, then enrich each domain with its
-- instrument question count for source-faithful awareness reporting.
ALTER FUNCTION public.get_awareness_report(uuid, text)
  RENAME TO get_awareness_report_base;
REVOKE EXECUTE ON FUNCTION public.get_awareness_report_base(uuid, text)
  FROM anon, public, authenticated;

CREATE FUNCTION public.get_awareness_report(
  p_client_org_id uuid,
  p_framework text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_result jsonb;
  v_pack uuid;
  v_domains jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  v_result := public.get_awareness_report_base(p_client_org_id, p_framework);
  v_pack := NULLIF(v_result->'instrument'->>'content_pack_id', '')::uuid;

  SELECT COALESCE(
    jsonb_agg(
      d.value || jsonb_build_object(
        'questions',
        (SELECT count(*)
         FROM awareness_questions q
         WHERE q.content_pack_id = v_pack
           AND q.active
           AND q.domain_code = d.value->>'code')
      )
      ORDER BY d.ordinality
    ),
    '[]'::jsonb
  )
  INTO v_domains
  FROM jsonb_array_elements(COALESCE(v_result->'domains', '[]'::jsonb))
    WITH ORDINALITY AS d(value, ordinality);

  RETURN jsonb_set(v_result, '{domains}', v_domains, true);
END $$;

REVOKE EXECUTE ON FUNCTION public.get_awareness_report(uuid, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.get_awareness_report(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_assessment_report_overrides(
  p_report_id uuid,
  p_overrides jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v public.assessment_reports%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM public.assessment_reports WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to report';
  END IF;
  IF public.current_role_name() NOT IN ('practice_owner', 'practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may edit assessment reports';
  END IF;
  IF v.approval_status NOT IN ('draft_ai', 'draft_human') THEN
    RAISE EXCEPTION 'report is approved/issued — create the next version instead';
  END IF;

  UPDATE public.assessment_reports
     SET overrides = p_overrides,
         compiled_at = NULL,
         updated_at = now()
   WHERE id = p_report_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (
    auth.uid(), public.current_practice(), 'assessment_report.edited',
    jsonb_build_object('report_id', p_report_id, 'requires_recompile', true)
  );
END $$;

CREATE OR REPLACE FUNCTION public.approve_assessment_report(
    p_report_id uuid, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v public.assessment_reports%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM public.assessment_reports WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to report';
  END IF;
  IF public.current_role_name() NOT IN ('practice_owner', 'practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may approve assessment reports';
  END IF;
  IF v.approval_status NOT IN ('draft_ai', 'draft_human') THEN
    RAISE EXCEPTION 'report is not a draft';
  END IF;
  IF v.compiled_at IS NULL THEN RAISE EXCEPTION 'compile the report before approving'; END IF;
  IF COALESCE((v.overrides->>'accuracy_confirmed')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'advisor accuracy confirmation is required before approval';
  END IF;
  IF COALESCE((v.payload->'quality'->>'proposed_classifications')::int, 0) > 0 THEN
    RAISE EXCEPTION 'all remediation classifications must be advisor-confirmed before approval';
  END IF;
  IF COALESCE((v.payload->'quality'->>'ready')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'recompile the report after completing the accuracy review';
  END IF;

  UPDATE public.assessment_reports
     SET approval_status = 'approved', updated_at = now()
   WHERE id = p_report_id;
  PERFORM public.record_approval(
    'assessment_report', p_report_id, 'approved',
    COALESCE(p_note, 'Assessment report v' || v.version || ' approved after advisor accuracy review')
  );
END $$;

UPDATE public.content_packs
SET metadata = jsonb_set(
  COALESCE(metadata, '{}'::jsonb),
  '{report_spec}',
  COALESCE(metadata->'report_spec', '{}'::jsonb) || $spec${
    "sections": [
      {"key": "cover", "title": "Cover & Document Control"},
      {"key": "exec_summary", "title": "Executive Summary"},
      {"key": "company_profile", "title": "Company Profile"},
      {"key": "scope_methodology", "title": "Scope, Objectives & Methodology"},
      {"key": "alignment", "title": "Assessment Framework: POPIA & ISO/IEC 27701 Alignment"},
      {"key": "domains", "title": "Control Assessment by Domain"},
      {"key": "awareness", "title": "Security & Privacy Awareness — People Risk"},
      {"key": "risk_register", "title": "Consolidated Risk Register"},
      {"key": "roadmap", "title": "Remediation Roadmap"},
      {"key": "documentation_issued", "title": "Post-Assessment Position: Documentation Issued", "min_version": 2},
      {"key": "classification_register", "title": "What Documentation Cannot Close", "min_version": 2},
      {"key": "implementation_programme", "title": "Implementation Programme", "min_version": 2},
      {"key": "delivery_options", "title": "Delivery Options & Standing Cadence", "min_version": 2},
      {"key": "residual_risk", "title": "Residual Risk Pending Implementation", "min_version": 2},
      {"key": "conclusion", "title": "Conclusion"},
      {"key": "appendices", "title": "Appendices"}
    ],
    "narrative_templates": {
      "exec_summary": "{{org_name}} was assessed across {{question_total}} controls: {{non_compliant_count}} Non-Compliant, {{under_review_count}} Under Review, {{partial_count}} Partially Compliant and {{fully_compliant_count}} Compliant. The overall maturity position is {{maturity_label}} ({{overall_pct}}%).",
      "company_profile": "{{org_name}} was assessed as at {{audit_date}}. The structured profile below records the legal entity and operating context used for this report.",
      "scope_methodology": "The assessment combined structured control interviews, evidence review and line-by-line mapping to POPIA and ISO/IEC 27701. Under Review means insufficient evidence was available to confirm the control at the assessment date.",
      "classification_register": "Documentation is the precondition for implementation, not a substitute for it. Each remediation item records what now covers it, the evidence required to close it and the accountable owner.",
      "conclusion": "{{org_name}}'s overall maturity is assessed at {{maturity_label}} ({{overall_pct}}%). The findings, controlled-document position and implementation programme provide the path to a defined and evidenced posture."
    },
    "assessment_scope": {
      "section_ids": [1, 2, 3],
      "limitations": [
        "The assessment reflects evidence available at the assessment date.",
        "Under Review controls remain open until sufficient evidence is obtained."
      ],
      "out_of_scope_domains": [
        "Security of Personal Information",
        "Data Subject Rights & Requests",
        "Direct Marketing"
      ]
    },
    "risk_register_limit": 20,
    "severity_matrix": {
      "Critical": {"non_compliant": "Critical", "partial": "High", "under_review": "Critical", "not_assessed": "High"},
      "High": {"non_compliant": "High", "partial": "Medium", "under_review": "High", "not_assessed": "Medium"},
      "Medium": {"non_compliant": "Medium", "partial": "Low", "under_review": "Medium", "not_assessed": "Low"},
      "Low": {"non_compliant": "Low", "partial": "Low", "under_review": "Low", "not_assessed": "Low"}
    },
    "target_windows": {
      "Critical": "0–30 days",
      "High": "0–30 days",
      "Medium": "31–90 days",
      "Low": "Next assessment cycle"
    },
    "rating_scale": {
      "statuses": [
        {"key": "fully_compliant", "label": "Compliant", "definition": "Evidence confirms the control is designed and operating as required."},
        {"key": "partial", "label": "Partially Compliant", "definition": "The control exists in some form but is inconsistently applied or incompletely evidenced."},
        {"key": "under_review", "label": "Under Review", "definition": "Insufficient evidence was available at the time of assessment to confirm status."},
        {"key": "non_compliant", "label": "Non-Compliant", "definition": "No evidence of the control was identified."},
        {"key": "na", "label": "Not Applicable", "definition": "The control does not apply to this organisation."}
      ],
      "risks": [
        {"key": "Critical", "definition": "Immediate action required — material regulatory, financial or reputational exposure."},
        {"key": "High", "definition": "Action required within 30 days of the applicable phase."},
        {"key": "Medium", "definition": "Action required within 90 days."},
        {"key": "Low", "definition": "Monitor and review at the next assessment cycle."}
      ]
    },
    "alignment_table": [
      {"condition": "Accountability", "reference": "POPIA Condition 1", "iso_clause": "5.2–5.4", "iso_title": "Context of the organisation; Leadership"},
      {"condition": "Processing Limitation", "reference": "POPIA Condition 2", "iso_clause": "7.2.2–7.2.6", "iso_title": "Lawful basis, consent, minimisation, further processing"},
      {"condition": "Purpose Specification", "reference": "POPIA Condition 3", "iso_clause": "7.2.1, 7.3.2", "iso_title": "RoPA; privacy notices"},
      {"condition": "Further Processing Limitation", "reference": "POPIA Condition 4", "iso_clause": "7.2.6", "iso_title": "Processing for specified purpose only"},
      {"condition": "Information Quality", "reference": "POPIA Condition 5", "iso_clause": "7.4.3", "iso_title": "Accuracy and correction of PII"},
      {"condition": "Openness", "reference": "POPIA Condition 6", "iso_clause": "7.3", "iso_title": "Determining and meeting PII principals’ information needs"},
      {"condition": "Security Safeguards", "reference": "POPIA Condition 7", "iso_clause": "6-series; 7.4.7–7.4.8", "iso_title": "Annex A/B controls; retention and disposal"},
      {"condition": "Data Subject Participation", "reference": "POPIA Condition 8", "iso_clause": "7.3.4–7.3.9", "iso_title": "Consent, access, correction and objection mechanisms"}
    ],
    "implementation_workstreams": [
      {"number": 1, "title": "Governance activation", "themes": ["governance", "registrations"], "default_window": "0–30 days", "default_owner": "Outsourced DIO with executive sponsorship"},
      {"number": 2, "title": "Records foundation", "themes": ["registers", "records"], "default_window": "30–90 days", "default_owner": "Outsourced DIO with IT"},
      {"number": 3, "title": "Third-party contracting", "themes": ["operators", "contracting"], "default_window": "30–120 days", "default_owner": "Outsourced DIO with Finance and legal input"},
      {"number": 4, "title": "Technical control build", "themes": ["technical", "access", "backup"], "default_window": "30–180 days", "default_owner": "Internal IT or appointed MSP"},
      {"number": 5, "title": "Operating the cycle", "themes": ["breach", "training", "monitoring", "dsr"], "default_window": "60–180 days, then continuous", "default_owner": "Outsourced DIO with IT"},
      {"number": 6, "title": "Assurance completion", "themes": ["assurance", "audit"], "default_window": "90–180 days", "default_owner": "Outsourced DIO"}
    ],
    "delivery_options": [
      {"route": "Outsourced Deputy Information Officer, standing engagement", "scope": "Governance, records, third-party contracting, the operating cycle and assurance.", "strength": "Continuity of the monthly cycle, maintained registers and independent oversight.", "limitation": "Cannot deliver technical-control implementation without internal IT or an appointed MSP."},
      {"route": "Defined project, fixed scope and end date", "scope": "Governance activation, the records foundation and contracting programme.", "strength": "Concentrated effort on the foundation items with a clear completion point.", "limitation": "Leaves the recurring operating cycle without an owner after project close."},
      {"route": "Internal IT or appointed MSP", "scope": "Technical controls including access, backup, logging, endpoint, patching and remote access.", "strength": "The only delivery route capable of closing technical implementation items.", "limitation": "Requires named ownership, recorded scope and evidence-return obligations."},
      {"route": "Combination — project for the build, standing DIO for the cycle", "scope": "All six workstreams.", "strength": "Matches the foundation work to a project and the operating work to a continuous service.", "limitation": "Requires an explicit handover of ownership and evidence."}
    ],
    "delivery_cadence": [
      {"cycle": "Monthly", "activity": "Remediation progress, backup and restore status, data-subject requests and breaches.", "evidence": "Dated progress report to the Information Officer"},
      {"cycle": "Quarterly", "activity": "Privileged access, operator agreements, new-system ROPA entries and incident contacts.", "evidence": "Review records with exceptions and actions"},
      {"cycle": "Annually", "activity": "ROPA, policy suite, training, tabletop exercise and executive compliance review.", "evidence": "Reissued records, attendance, exercise and annual reports"},
      {"cycle": "On event", "activity": "Update the ROPA or review controls after a new system, material breach or regulatory change.", "evidence": "Updated ROPA entry or post-incident review"}
    ]
  }$spec$::jsonb,
  true
)
WHERE framework_key = 'popia' AND practice_id IS NULL AND version = 2;

REVOKE EXECUTE ON FUNCTION public.upsert_response(uuid, uuid, text, text, text, date, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.upsert_response(uuid, uuid, text, text, text, date, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.upsert_response_no_recalc(uuid, uuid, text, text, text, date, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.upsert_response_no_recalc(uuid, uuid, text, text, text, date, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.update_assessment_report_overrides(uuid, jsonb) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.update_assessment_report_overrides(uuid, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.approve_assessment_report(uuid, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.approve_assessment_report(uuid, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
