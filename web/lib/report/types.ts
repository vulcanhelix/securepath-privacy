// Assessment report — shared shapes for compile (payload builder) and render (HTML).
// The payload is a frozen snapshot: everything the report says lives here, never read
// live at render time (assessment responses stay mutable after Gate 1).

export type Severity = 'Critical' | 'High' | 'Medium' | 'Low';
export type ControlStatus =
  | 'fully_compliant'
  | 'partial'
  | 'under_review'
  | 'non_compliant'
  | 'na'
  | 'not_assessed';

export interface ReportSpecSection { key: string; title: string; min_version?: number }

export interface ImplementationWorkstreamSpec {
  number: number;
  title: string;
  themes: string[];
  default_window: string;
  default_owner: string;
  description?: string;
}

export interface ReportSpec {
  sections: ReportSpecSection[];
  narrative_templates: Record<string, string>;
  maturity_bands: { min: number; max: number; label: string; tone: string }[];
  severity_matrix: Record<string, Record<string, Severity>>;
  target_windows: Record<Severity, string>;
  assessment_scope?: {
    section_ids: number[];
    limitations?: string[];
    out_of_scope_domains?: string[];
  };
  risk_register_limit?: number;
  rating_scale?: {
    statuses: { key: string; label: string; definition: string }[];
    risks: { key: string; definition: string }[];
  };
  alignment_table?: { condition: string; reference: string; iso_clause: string; iso_title: string }[];
  delivery_options?: { route: string; scope: string; strength: string; limitation: string }[];
  implementation_workstreams?: ImplementationWorkstreamSpec[];
  delivery_cadence?: { cycle: string; activity: string; evidence: string }[];
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
  source_type: 'assessment' | 'awareness' | 'advisor';
}

export type RegisterClass = 'A' | 'B' | 'C' | 'D';

export interface ClassRegisterRow {
  uid: string;
  ref: string;
  item: string;
  control_area: string | null;
  severity: Severity;
  cls: RegisterClass;
  cls_source: 'proposed' | 'advisor';
  documents_covering: string[];
  evidence_required: string | null;
  owner: string | null;
  workstream: string;
}

export interface DocumentSuite {
  suite: string;
  documents: string;
  governing_document: string;
}

export interface OutstandingDocument {
  document: string;
  position: string;
  ref: string;
}

export interface ImplementationWorkstream {
  number: number;
  title: string;
  item_refs: string[];
  window: string;
  owner: string;
  actions: string[];
  dependencies: string | null;
}

export interface ResidualExposure {
  exposure: string;
  why_it_matters: string;
  closed_by: string;
}

export interface StructuredReportData {
  cover: {
    prepared_by: string | null;
    attention: string | null;
    scope_of_version: string | null;
    confidentiality_statement: string | null;
  };
  company_profile: {
    legal_name: string;
    registration_number: string | null;
    location: string | null;
    industry: string | null;
    activities: string | null;
    personal_information_categories: string[];
  };
  scope: {
    objectives: string[];
    methodology: string[];
    limitations: string[];
    out_of_scope_domains: string[];
  };
  documentation_suites: DocumentSuite[];
  remediation_register: ClassRegisterRow[];
  outstanding_documents: OutstandingDocument[];
  implementation_programme: ImplementationWorkstream[];
  delivery_options: { route: string; scope: string; strength: string; limitation: string }[];
  delivery_cadence: { cycle: string; activity: string; evidence: string }[];
  residual_exposures: ResidualExposure[];
  reviewed_documents: { document: string; version_date: string | null }[];
  awareness_respondents: {
    respondent: string;
    questions_answered: number;
    pct_aligned: number;
    rating: string;
  }[];
}

export interface ReportPayload {
  meta: { framework: string; kind: string; version: number; compiled_at: string };
  cover: {
    client_name: string; org_name: string | null; auditor_name: string | null;
    audit_date: string | null; audit_ref: string | null; practice_name: string | null;
    history: { version: number; kind: string; title: string; status: string; issued_at: string | null }[];
  };
  structured: StructuredReportData;
  summary: {
    overall_pct: number | null; overall_rating: string | null; completion_pct: number | null;
    maturity_label: string; maturity_tone: string;
    counts: Record<ControlStatus, number> & { total: number };
    risk_counts: Record<Severity, number>;
    critical_count: number;
    baseline: { pct: number | null; rating: string | null; at: string | null } | null;
    prior: { version: number; overall_pct: number | null } | null;
    dashboard: {
      section_id: number;
      section_name: string;
      pct: number | null;
      counts: Record<ControlStatus, number>;
      worst: Severity | null;
    }[];
    top_actions: string[];
  };
  domains: DomainSection[];
  awareness: unknown | null;               // get_awareness_report jsonb, verbatim
  risk_register: Finding[];
  roadmap: { window: string; items: { ref: string; action: string; severity: Severity }[] }[];
  documentation_issued: {
    rows: { title: string; source: string; issued_at: string | null }[];
    slots_required: number; slots_filled: number;
    suites: DocumentSuite[];
    total_documents: number;
    open_remediation_items: number;
  } | null;
  classification_register: ClassRegisterRow[] | null;
  implementation_programme: ImplementationWorkstream[] | null;
  outstanding_documents: OutstandingDocument[] | null;
  residual_risk: ResidualExposure[] | null;
  appendices: {
    documents_reviewed: { document: string; version_date: string | null }[];
    awareness_respondents: StructuredReportData['awareness_respondents'];
    framework_legend: unknown | null;
  };
  quality: {
    accuracy_confirmed: boolean;
    proposed_classifications: number;
    issues: string[];
    ready: boolean;
  };
  sections: Record<string, { title: string; narrative_default: string | null }>;
  section_order: ReportSpecSection[];
  spec: Pick<ReportSpec, 'rating_scale' | 'alignment_table'>;
}

export interface ReportOverrides {
  narratives?: Record<string, string>;       // section key (or `domain_obs:<id>`) -> advisor text
  sections_excluded?: string[];
  classification?: Record<string, {
    cls: RegisterClass;
    item?: string;
    documents_covering?: string[];
    evidence_required?: string;
    owner?: string;
    workstream?: string;
  }>;
  top_actions?: string[];
  structured?: Partial<StructuredReportData>;
  risk_register?: Finding[];
  accuracy_confirmed?: boolean;
}

export interface ReportBrand {
  practiceName: string;
  accentHex: string | null;
  logo: string | null;   // data URI (issue) or URL (preview); null = text-only cover
}
