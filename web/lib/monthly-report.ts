// W2-08 — monthly report (screen 05) shared types + display helpers.
// The shape mirrors public.report_document(uuid) (migration
// 20261106000014_report_builder.sql) — the one composed body that both the
// builder screen and the W3-03 PDF render. Figures always come from the
// bound §9.5 snapshot; nothing here computes or edits them.

export type ReportStatus = 'draft' | 'inputs_complete' | 'ao_review' | 'signed' | 'issued';

export interface ReportFigure {
  key: string;
  value: unknown;
}

export interface ReportSection {
  key: string;
  title: string;
  narrative_mode: 'required' | 'optional' | 'none';
  narrative: string | null;
  figures: ReportFigure[];
}

export interface ReportSignature {
  role: string;
  user: string | null;
  name: string | null;
  at: string;
  note?: string | null;
}

export interface MonthlyReportDoc {
  id: string;
  period: string;
  version: number;
  status: ReportStatus;
  reference: string | null;
  supersedes_id: string | null;
  programme: { id: string; name: string };
  client: { id: string; name: string };
  branding: { name?: string | null; logo_url?: string | null; accent_hex?: string | null } | null;
  headline: string | null;
  commentary: string | null;
  overall_rag: 'Red' | 'Amber' | 'Green' | null;
  trend: string | null;
  gate_override_reason: string | null;
  due_on: string | null;
  late: boolean | null;
  days_late: number | null;
  snapshot: { id: string; period: string; taken_at: string } | null;
  sections: ReportSection[];
  signatures: ReportSignature[];
  issued_on: string | null;
  issued_by_name: string | null;
  created_at: string;
}

export interface ReportListRow {
  id: string;
  period: string;
  version: number;
  status: ReportStatus;
  reference: string | null;
  due_on: string | null;
  late: boolean;
  days_late: number;
  snapshot_id: string | null;
  snapshot_taken_at: string | null;
  signed_at: string | null;
  signed_by: string | null;
  signed_by_name: string | null;
  issued_on: string | null;
  issued_by: string | null;
  issued_by_name: string | null;
  supersedes_id: string | null;
  is_latest: boolean;
  inputs_outstanding: number;
  gate_override_reason: string | null;
}

export interface InputOutstanding {
  kind: 'maintenance_task' | 'narrative';
  ref: string;
  label: string;
  status: string;
  due_date: string | null;
}

export const REPORT_WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];

export const STATUS_LABEL: Record<ReportStatus, string> = {
  draft: 'Draft',
  inputs_complete: 'Inputs complete',
  ao_review: 'AO review',
  signed: 'Signed',
  issued: 'Issued',
};

// Labels for the fixed §9.5 snapshot keys (W0-02 monthly_snapshots contract).
const FIGURE_LABEL: Record<string, string> = {
  rag: 'Programme RAG',
  activities_complete: 'Activities complete',
  activities_overdue: 'Activities overdue',
  register_closed: 'Findings closed',
  register_open: 'Findings open',
  high_priority_closed: 'High-priority findings closed',
  evidence_pending: 'Evidence awaiting decision',
  kpi_actuals: 'KPI actuals',
  maintenance_done: 'Maintenance tasks done',
  maintenance_overdue: 'Maintenance tasks overdue',
};

export const figureLabel = (key: string) =>
  FIGURE_LABEL[key] ?? key.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase());

export const periodLabel = (period: string) =>
  new Date(`${period}-01T00:00:00Z`).toLocaleDateString('en-GB', {
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  });

export const dateLabel = (d: string | null | undefined) =>
  d
    ? new Date(d.length === 10 ? `${d}T00:00:00Z` : d).toLocaleDateString('en-GB', {
        day: 'numeric',
        month: 'short',
        year: 'numeric',
        timeZone: 'UTC',
      })
    : '—';
