-- Report spec for the POPIA 2026 pack — pure content, zero schema change.
-- The assessment-report compiler/renderer reads content_packs.metadata.report_spec;
-- packs without one fall back to the generic in-code DEFAULT_REPORT_SPEC (the acceptance
-- test: another framework renders with no code change). Authored from William's Puris
-- deliverable (docs/Puris_POPIA_ISO27701_Compliance_Assessment.docx).

BEGIN;

UPDATE public.content_packs
SET metadata = COALESCE(metadata, '{}'::jsonb) || $spec${
  "report_spec": {
    "sections": [
      {"key": "cover",                   "title": "Cover & Document Control"},
      {"key": "exec_summary",            "title": "Executive Summary"},
      {"key": "company_profile",         "title": "Company Profile"},
      {"key": "scope_methodology",       "title": "Scope, Objectives & Methodology"},
      {"key": "alignment",               "title": "Assessment Framework: POPIA & ISO/IEC 27701 Alignment"},
      {"key": "domains",                 "title": "Control Assessment by Domain"},
      {"key": "awareness",               "title": "Security & Privacy Awareness — People Risk"},
      {"key": "risk_register",           "title": "Consolidated Risk Register"},
      {"key": "roadmap",                 "title": "Remediation Roadmap"},
      {"key": "documentation_issued",    "title": "Post-Assessment Position: Documentation Issued", "min_version": 2},
      {"key": "classification_register", "title": "What Documentation Cannot Close",                "min_version": 2},
      {"key": "residual_risk",           "title": "Residual Risk Pending Implementation",           "min_version": 2},
      {"key": "delivery_options",        "title": "Delivery Options",                               "min_version": 2},
      {"key": "conclusion",              "title": "Conclusion"},
      {"key": "appendices",              "title": "Appendices"}
    ],
    "narrative_templates": {
      "exec_summary": "{{org_name}} engaged this assessment to determine the organisation's current compliance posture against the Protection of Personal Information Act 4 of 2013 (POPIA), mapped throughout to ISO/IEC 27701:2019. Across the {{question_total}} control questions assessed, {{non_compliant_count}} were rated Non-Compliant, {{partial_count}} Partially Compliant, {{fully_compliant_count}} Compliant and {{not_assessed_count}} were not assessed in this cycle. {{critical_count}} findings carry Critical risk. On this basis, the overall POPIA / ISO 27701 maturity is assessed at {{maturity_label}} with an overall score of {{overall_pct}}%.",
      "company_profile": "{{org_name}} was assessed as at {{audit_date}}. This profile should be completed by the advisor with the organisation's registration details, activities and the categories of personal information processed.",
      "scope_methodology": "The assessment combined a structured control questionnaire, mapped line-by-line to POPIA sections and ISO/IEC 27701 clauses, with a desk-based review of governance documents. Each control was rated Compliant, Partially Compliant, Non-Compliant or Not Assessed, and carries an inherent risk priority of Critical, High, Medium or Low.",
      "classification_register": "Issuing a policy is not the same as operating a control. A document records what the organisation intends to do; the obligation under POPIA section 8 is to be able to demonstrate that it is being done. Each open item below is classified: A — closed by documentation, subject to approval; B — documented, implementation required; C — implementation only, no document closes it; D — further documentation and implementation both required. The Evidence column is the operative one: it is what an auditor, an insurer or the Regulator would ask to see.",
      "conclusion": "{{org_name}}'s overall maturity is assessed at {{maturity_label}} ({{overall_pct}}%). The findings and phased roadmap in this report set out the path to a defined and evidenced posture. This report was prepared by {{auditor_name}}."
    },
    "maturity_bands": [
      {"min": 0,  "max": 24,  "label": "Initial / Ad Hoc (Red)",             "tone": "fail"},
      {"min": 25, "max": 49,  "label": "Repeatable but Reactive (Orange)",   "tone": "warn"},
      {"min": 50, "max": 74,  "label": "Defined (Amber)",                    "tone": "warn"},
      {"min": 75, "max": 89,  "label": "Managed (Green)",                    "tone": "pass"},
      {"min": 90, "max": 100, "label": "Optimised (Blue)",                   "tone": "ink"}
    ],
    "severity_matrix": {
      "Critical": {"non_compliant": "Critical", "partial": "High",   "not_assessed": "High"},
      "High":     {"non_compliant": "High",     "partial": "Medium", "not_assessed": "Medium"},
      "Medium":   {"non_compliant": "Medium",   "partial": "Low",    "not_assessed": "Low"},
      "Low":      {"non_compliant": "Low",      "partial": "Low",    "not_assessed": "Low"}
    },
    "target_windows": {"Critical": "0–30 days", "High": "31–90 days", "Medium": "91–180 days", "Low": "91–180 days"},
    "rating_scale": {
      "statuses": [
        {"key": "fully_compliant", "label": "Compliant",           "definition": "Evidence confirms the control is designed and operating as required."},
        {"key": "partial",         "label": "Partially Compliant", "definition": "The control exists in some form but is inconsistently applied or incompletely evidenced."},
        {"key": "non_compliant",   "label": "Non-Compliant",       "definition": "No evidence of the control was identified."},
        {"key": "not_assessed",    "label": "Not Assessed",        "definition": "The control was not assessed in this cycle."},
        {"key": "na",              "label": "Not Applicable",      "definition": "The control does not apply to this organisation."}
      ],
      "risks": [
        {"key": "Critical", "definition": "Immediate action required — material regulatory, financial or reputational exposure."},
        {"key": "High",     "definition": "Action required within 30 days of the applicable phase."},
        {"key": "Medium",   "definition": "Action required within 90 days."},
        {"key": "Low",      "definition": "Monitor and review at the next assessment cycle."}
      ]
    },
    "alignment_table": [
      {"condition": "1. Accountability",                "reference": "POPIA s.8",       "iso_clause": "5.2–5.4", "iso_title": "Context of the organisation; Leadership"},
      {"condition": "2. Processing Limitation",         "reference": "POPIA s.9–12",  "iso_clause": "7.2.2–7.2.6", "iso_title": "Lawful basis, consent, minimisation, further processing"},
      {"condition": "3. Purpose Specification",         "reference": "POPIA s.13–14", "iso_clause": "7.2.1, 7.3.2", "iso_title": "Records of processing; privacy notices"},
      {"condition": "4. Further Processing Limitation", "reference": "POPIA s.15",      "iso_clause": "7.2.6", "iso_title": "Processing for specified purpose only"},
      {"condition": "5. Information Quality",           "reference": "POPIA s.16",      "iso_clause": "7.4.3", "iso_title": "Accuracy and correction of PII"},
      {"condition": "6. Openness",                      "reference": "POPIA s.17–18", "iso_clause": "7.3", "iso_title": "Determining and meeting PII principals' information needs"},
      {"condition": "7. Security Safeguards",           "reference": "POPIA s.19–22", "iso_clause": "6.x; 7.4.7–7.4.8", "iso_title": "Annex A/B controls; retention & disposal"},
      {"condition": "8. Data Subject Participation",    "reference": "POPIA s.23–25", "iso_clause": "7.3.4–7.3.9", "iso_title": "Consent, access, correction and objection mechanisms"}
    ],
    "delivery_options": [
      {"route": "Outsourced Deputy Information Officer, standing engagement",
       "scope": "Governance activation, records foundation, third-party contracting, the operating cycle and assurance completion.",
       "strength": "Continuity of the monthly cycle; registers stay populated; independence from the functions being reviewed.",
       "limitation": "Cannot deliver the technical control build, which depends on internal IT or the appointed MSP."},
      {"route": "Defined project, fixed scope and end date",
       "scope": "The records foundation, contracting programme and governance activation.",
       "strength": "Concentrated effort on the foundation items; a clear completion point.",
       "limitation": "Leaves the operating cycle without an owner once the project closes — where compliance programmes usually decay."},
      {"route": "Internal IT or the appointed MSP",
       "scope": "The technical control build.",
       "strength": "The only route to closing the technical items.",
       "limitation": "Requires the IT function to be named and accountable; scope should be recorded in the service agreement."},
      {"route": "Combination — project for the build, standing engagement for the cycle",
       "scope": "All workstreams.",
       "strength": "Matches the shape of the work: the foundation is a project, the operation is a cycle.",
       "limitation": "Requires clarity at handover on which items transfer and what evidence accompanies them."}
    ]
  }
}$spec$::jsonb
WHERE framework_key = 'popia' AND practice_id IS NULL AND version = 2;

COMMIT;

NOTIFY pgrst, 'reload schema';
