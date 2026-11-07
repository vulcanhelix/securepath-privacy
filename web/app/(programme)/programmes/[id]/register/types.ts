// W2-16 — shared row types for the remediation register (spec §6.2 "Register
// item", FR-REG-01..04). They mirror register_items / evidence_items verbatim.
// planned_close_date, days_overdue and RAG are engine values (§9.1/§9.3) —
// the UI renders them and never recomputes them.

export interface RegisterItemRow {
  id: string;
  ref: string;
  finding: string;
  priority: 'High' | 'Medium' | 'Low' | string;
  assessment_window: string | null;
  lead: string | null;
  planned_close_week: number | null;
  status: 'Not started' | 'In progress' | 'At risk' | 'Blocked' | 'Closed' | string;
  accepted_on: string | null;
  accepted_by: string | null;
  accepted_evidence_refs: string[] | null;
  reopen_reason: string | null;
  planned_close_date: string | null; // CALC
  days_overdue: number | null; // CALC
  source_assessment_session_id: string | null; // bridge provenance (20261106000011)
  source_question_ref: string | null;
  import_run_id: string | null; // CSV import provenance (20261106000024, W3-01)
  active: boolean; // #87/#92 FR-TPL-04 soft retire (false = retired)
  retired_reason: string | null;
  created_at: string;
}

export interface RegisterActivity {
  id: string;
  ref: string;
  text: string;
  status: string;
  workstream_id: string | null;
  active?: boolean; // #92: false = retired (FR-TPL-04)
}

export interface RegisterEvidence {
  id: string;
  activity_id: string | null;
  register_item_id: string | null;
  review_stage: string;
  outcome: string | null;
  evidence_ref: string | null;
  uploaded_at: string;
}

export const REGISTER_COLS =
  'id, ref, finding, priority, assessment_window, lead, planned_close_week, status, ' +
  'accepted_on, accepted_by, accepted_evidence_refs, reopen_reason, planned_close_date, ' +
  'days_overdue, source_assessment_session_id, source_question_ref, import_run_id, active, retired_reason, ' +
  'created_at';

// pre-bridge column set — retried if 20261106000011 is not applied yet
export const REGISTER_COLS_LEGACY =
  'id, ref, finding, priority, assessment_window, lead, planned_close_week, status, ' +
  'accepted_on, accepted_by, accepted_evidence_refs, reopen_reason, planned_close_date, ' +
  'days_overdue, created_at';

export const REGISTER_STATUSES = ['Not started', 'In progress', 'At risk', 'Blocked', 'Closed'];
export const PRIORITIES = ['High', 'Medium', 'Low'];
export const RAGS = ['Red', 'Amber', 'Green', 'Not due', 'Complete'];

export const PRIORITY_TONE: Record<string, 'fail' | 'warn' | 'neutral'> = {
  High: 'fail',
  Medium: 'warn',
  Low: 'neutral',
};

// the update_activity / add_activity role list (W1-05) — UI mirror only
export const WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];
