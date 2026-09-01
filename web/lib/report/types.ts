// Assessment report — shared shapes for compile (payload builder) and render (HTML).
// The payload is a frozen snapshot: everything the report says lives here, never read
// live at render time (assessment responses stay mutable after Gate 1).

export type Severity = 'Critical' | 'High' | 'Medium' | 'Low';
export type ControlStatus = 'fully_compliant' | 'partial' | 'non_compliant' | 'na' | 'not_assessed';

export interface ReportSpecSection { key: string; title: string; min_version?: number }

export interface ReportSpec {
  sections: ReportSpecSection[];
  narrative_templates: Record<string, string>;
  maturity_bands: { min: number; max: number; label: string; tone: string }[];
  severity_matrix: Record<string, Record<string, Severity>>;
  target_windows: Record<Severity, string>;
  rating_scale?: {
    statuses: { key: string; label: string; definition: string }[];
    risks: { key: string; definition: string }[];
  };
  alignment_table?: { condition: string; reference: string; iso_clause: string; iso_title: string }[];
  delivery_options?: { route: string; scope: string; strength: string; limitation: string }[];
}

export interface DomainRow {
  uid: string;
  ref: string;                 // display ref, e.g. S2.04
  control_area: string | null; // subsection
  question: string;
  ref_a: string;               // statute ref (before '|'), or whole ref
  ref_b: string | null;        // ISO ref (after '|'), when the pack uses the pipe format
  status: ControlStatus;
  risk: Severity;
  severity: Severity | null;   // answer-adjusted finding severity; null = closed/na
  findings: string | null;
  evidence_req: string | null;
  remediation: string | null;
  owner: string | null;
  target_date: string | null;
}

export interface DomainSection {
  section_id: number;
  section_name: string;
  pct: number | null;
  counts: Record<ControlStatus, number>;
  rows: DomainRow[];
}

export interface Finding {
  uid: string;
  ref: string;
  control_area: string | null;
  finding: string;
  severity: Severity;
  recommended_action: string | null;
  owner: string | null;
  target_window: string;
}

export type RegisterClass = 'A' | 'B' | 'C' | 'D';

export interface ClassRegisterRow {
  uid: string;
  ref: string;
  control_area: string | null;
  severity: Severity;
  cls: RegisterClass;
  cls_source: 'proposed' | 'advisor';
  evidence_required: string | null;
  owner: string | null;
  workstream: string;
}

export interface ReportPayload {
  meta: { framework: string; kind: string; version: number; compiled_at: string };
  cover: {
    client_name: string; org_name: string | null; auditor_name: string | null;
    audit_date: string | null; audit_ref: string | null; practice_name: string | null;
    history: { version: number; kind: string; title: string; status: string; issued_at: string | null }[];
  };
  summary: {
    overall_pct: number | null; overall_rating: string | null; completion_pct: number | null;
    maturity_label: string; maturity_tone: string;
    counts: Record<ControlStatus, number> & { total: number };
    critical_count: number;
    baseline: { pct: number | null; rating: string | null; at: string | null } | null;
    prior: { version: number; overall_pct: number | null } | null;
    dashboard: { section_id: number; section_name: string; pct: number | null; open_critical: number; worst: Severity | null }[];
    top_actions: string[];
  };
  domains: DomainSection[];
  awareness: unknown | null;               // get_awareness_report jsonb, verbatim
  risk_register: Finding[];
  roadmap: { window: string; items: { ref: string; action: string; severity: Severity }[] }[];
  documentation_issued: {
    rows: { title: string; source: string; issued_at: string | null }[];
    slots_required: number; slots_filled: number;
  } | null;
  classification_register: ClassRegisterRow[] | null;
  residual_risk: ClassRegisterRow[] | null;
  appendices: {
    documents_reviewed: { filename: string; uploaded_at: string | null }[];
    framework_legend: unknown | null;
  };
  sections: Record<string, { title: string; narrative_default: string | null }>;
  section_order: ReportSpecSection[];
  spec: Pick<ReportSpec, 'rating_scale' | 'alignment_table' | 'delivery_options'>;
}

export interface ReportOverrides {
  narratives?: Record<string, string>;       // section key (or `domain_obs:<id>`) -> advisor text
  sections_excluded?: string[];
  classification?: Record<string, { cls: RegisterClass; evidence_required?: string; owner?: string }>;
  top_actions?: string[];
}

export interface ReportBrand {
  practiceName: string;
  accentHex: string | null;
  logo: string | null;   // data URI (issue) or URL (preview); null = text-only cover
}
