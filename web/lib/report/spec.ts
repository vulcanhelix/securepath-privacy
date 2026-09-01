import type { ReportSpec, Severity } from './types';

// Generic fallback spec — any framework whose content pack carries no report_spec renders
// with these sections (the acceptance test: a new framework needs zero code change).
export const DEFAULT_REPORT_SPEC: ReportSpec = {
  sections: [
    { key: 'cover', title: 'Cover & Document Control' },
    { key: 'exec_summary', title: 'Executive Summary' },
    { key: 'company_profile', title: 'Company Profile' },
    { key: 'scope_methodology', title: 'Scope, Objectives & Methodology' },
    { key: 'domains', title: 'Control Assessment by Domain' },
    { key: 'awareness', title: 'Security & Privacy Awareness — People Risk' },
    { key: 'risk_register', title: 'Consolidated Risk Register' },
    { key: 'roadmap', title: 'Remediation Roadmap' },
    { key: 'documentation_issued', title: 'Post-Assessment Position: Documentation Issued', min_version: 2 },
    { key: 'classification_register', title: 'What Documentation Cannot Close', min_version: 2 },
    { key: 'implementation_programme', title: 'Implementation Programme', min_version: 2 },
    { key: 'delivery_options', title: 'Delivery Options & Standing Cadence', min_version: 2 },
    { key: 'residual_risk', title: 'Residual Risk Pending Implementation', min_version: 2 },
    { key: 'conclusion', title: 'Conclusion' },
    { key: 'appendices', title: 'Appendices' },
  ],
  narrative_templates: {
    exec_summary:
      '{{org_name}} was assessed across {{question_total}} controls: {{non_compliant_count}} Non-Compliant, ' +
      '{{under_review_count}} Under Review, {{partial_count}} Partially Compliant, ' +
      '{{fully_compliant_count}} Compliant and {{not_assessed_count}} not assessed. ' +
      '{{critical_count}} findings carry Critical risk. Overall maturity: {{maturity_label}} ({{overall_pct}}%).',
    scope_methodology:
      'A structured control questionnaire was assessed against the framework, each control rated ' +
      'Compliant, Partially Compliant, Under Review, Non-Compliant or Not Assessed with an inherent risk priority.',
    conclusion:
      "{{org_name}}'s overall maturity is assessed at {{maturity_label}} ({{overall_pct}}%). " +
      'This report was prepared by {{auditor_name}}.',
  },
  maturity_bands: [
    { min: 0, max: 24, label: 'Initial / Ad Hoc (Red)', tone: 'fail' },
    { min: 25, max: 49, label: 'Repeatable but Reactive (Orange)', tone: 'warn' },
    { min: 50, max: 74, label: 'Defined (Amber)', tone: 'warn' },
    { min: 75, max: 89, label: 'Managed (Green)', tone: 'pass' },
    { min: 90, max: 100, label: 'Optimised (Blue)', tone: 'ink' },
  ],
  severity_matrix: {
    Critical: { non_compliant: 'Critical', partial: 'High', under_review: 'Critical', not_assessed: 'High' },
    High: { non_compliant: 'High', partial: 'Medium', under_review: 'High', not_assessed: 'Medium' },
    Medium: { non_compliant: 'Medium', partial: 'Low', under_review: 'Medium', not_assessed: 'Low' },
    Low: { non_compliant: 'Low', partial: 'Low', under_review: 'Low', not_assessed: 'Low' },
  },
  target_windows: { Critical: '0–30 days', High: '31–90 days', Medium: '91–180 days', Low: '91–180 days' },
};

// Pack report_spec wins key-by-key over the default (shallow merge is enough: each key is
// a complete unit — a pack overriding maturity_bands supplies the whole band table).
export function resolveSpec(packMetadata: unknown): ReportSpec {
  const rs = (packMetadata as { report_spec?: Partial<ReportSpec> } | null)?.report_spec;
  if (!rs) return DEFAULT_REPORT_SPEC;
  return { ...DEFAULT_REPORT_SPEC, ...rs } as ReportSpec;
}

export function maturityFor(spec: ReportSpec, pct: number | null): { label: string; tone: string } {
  if (pct == null) return { label: 'Not yet scored', tone: 'neutral' };
  const band = spec.maturity_bands.find(b => pct >= b.min && pct <= b.max);
  return band ? { label: band.label, tone: band.tone } : { label: 'Not yet scored', tone: 'neutral' };
}

// Answer-adjusted finding severity. null = no open finding (closed or n/a).
export function severityFor(spec: ReportSpec, risk: string, status: string): Severity | null {
  if (status === 'fully_compliant' || status === 'na') return null;
  return spec.severity_matrix[risk]?.[status] ?? 'Low';
}

export const SEVERITY_ORDER: Severity[] = ['Critical', 'High', 'Medium', 'Low'];

export const STATUS_LABELS: Record<string, string> = {
  fully_compliant: 'Compliant',
  partial: 'Partially Compliant',
  under_review: 'Under Review',
  non_compliant: 'Non-Compliant',
  na: 'N/A',
  not_assessed: 'Not Assessed',
};
