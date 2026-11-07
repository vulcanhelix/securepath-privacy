import { type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

// ---------------------------------------------------------------------------
// W3-04 (#45) — export downloads (spec §11 "Reports and exports").
//
// GET /api/exports/<artefact>/<scope-id> → CSV stream, no new deps.
// Each artefact maps 1:1 onto an export_* RPC (20261106000027): the definer
// body re-checks the caller's visibility (allowed_programmes /
// allowed_client_orgs / partner-admin) AND writes the disclosure audit row —
// a direct PostgREST call is held to exactly the same rules, so this route
// stays a thin CSV serialiser.
//
// Not-found and not-yours are the same answer at every layer: the RPCs raise
// insufficient_privilege for absent-or-hidden scopes and this route answers
// 404 — a partner-B caller gets no data and no existence confirmation.
// ---------------------------------------------------------------------------

export const dynamic = 'force-dynamic';

interface ArtefactSpec {
  rpc: string;
  param: 'p_programme_id' | 'p_client_org_id' | 'p_practice_id';
  /** filename stem for the download */
  file: string;
  /** output column order — identical to the RPC's RETURNS TABLE names */
  cols: string[];
}

const ARTEFACTS: Record<string, ArtefactSpec> = {
  register: {
    rpc: 'export_register_items',
    param: 'p_programme_id',
    file: 'register',
    cols: [
      'ref', 'finding', 'priority', 'status', 'assessment_window', 'lead',
      'planned_close_week', 'planned_close_date', 'days_overdue',
      'linked_activities', 'accepted_on', 'accepted_by',
      'accepted_evidence_refs', 'retired', 'created_at',
    ],
  },
  activities: {
    rpc: 'export_activities',
    param: 'p_programme_id',
    file: 'schedule',
    cols: [
      'ref', 'activity', 'workstream', 'phase', 'status', 'pct_complete',
      'start_week', 'end_week', 'start_date', 'due_date', 'month',
      'milestone', 'evidence_required', 'rag', 'flag', 'leads', 'depends_on',
      'actual_completion', 'recovery_date', 'comments', 'retired', 'created_at',
    ],
  },
  'evidence-index': {
    rpc: 'export_evidence_index',
    param: 'p_programme_id',
    file: 'evidence-index',
    cols: [
      'evidence_ref', 'kind', 'file_key', 'link', 'site', 'review_stage',
      'outcome', 'uploaded_by', 'uploaded_at', 'activity_ref', 'register_ref',
      'accepted_on', 'accepted_by',
    ],
  },
  'kpi-history': {
    rpc: 'export_kpi_history',
    param: 'p_programme_id',
    file: 'kpi-history',
    cols: [
      'kpi_name', 'unit', 'baseline', 'target', 'target_confirmed',
      'auto_calc', 'month', 'value', 'evidence_ref', 'entered_by', 'entered_at',
    ],
  },
  reports: {
    rpc: 'export_report_index',
    param: 'p_programme_id',
    file: 'monthly-reports',
    cols: [
      'period', 'version', 'status', 'reference', 'due_on', 'late',
      'days_late', 'snapshot_taken_at', 'signed_at', 'signed_by',
      'issued_on', 'issued_by', 'is_latest', 'inputs_outstanding',
      'gate_override_reason',
    ],
  },
  'maintenance-history': {
    rpc: 'export_maintenance_history',
    param: 'p_programme_id',
    file: 'maintenance-history',
    cols: [
      'code', 'task', 'period', 'task_window', 'due_date', 'status',
      'assignee', 'completed_on', 'evidence_ref', 'evidence_exempt_reason',
      'exception_reason',
    ],
  },
  'client-pack': {
    rpc: 'export_client_pack',
    param: 'p_client_org_id',
    file: 'client-pack',
    cols: [
      'client', 'programme', 'programme_status', 'phase', 'programme_rag',
      'report_period', 'report_version', 'report_status', 'report_reference',
      'report_due_on', 'report_issued_on',
    ],
  },
  audit: {
    rpc: 'export_audit_extract',
    param: 'p_practice_id',
    file: 'audit-extract',
    cols: ['at', 'user_id', 'user_email', 'action', 'detail'],
  },
};

/** RFC 4180 cell: quote when needed, double the quotes inside. */
function csvCell(v: unknown): string {
  if (v === null || v === undefined) return '';
  const s =
    typeof v === 'object' ? JSON.stringify(v) : typeof v === 'boolean' ? (v ? 'true' : 'false') : String(v);
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function notFound() {
  return new Response('not found', { status: 404 });
}

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ artefact: string; id: string }> }
) {
  const { artefact, id } = await params;
  const spec = ARTEFACTS[artefact];
  if (!spec) return notFound();

  const supabase = await serverClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return new Response('unauthenticated', { status: 401 });

  const { data, error } = await supabase.rpc(spec.rpc, { [spec.param]: id });
  if (error) {
    // guard-raised denials (insufficient_privilege / not-found phrasing) →
    // 404; anything else is a server fault worth surfacing as such.
    if (error.code === '42501' || /not found or not visible/.test(error.message ?? '')) {
      return notFound();
    }
    return new Response('export failed', { status: 500 });
  }

  const rows = (data ?? []) as Record<string, unknown>[];
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      // BOM first so Excel opens the file as UTF-8 without a wizard (§11's
      // "Excel" outputs are delivered as CSV in R1).
      controller.enqueue(encoder.encode('\uFEFF' + spec.cols.join(',') + '\r\n'));
      for (const row of rows) {
        controller.enqueue(
          encoder.encode(spec.cols.map((c) => csvCell(row[c])).join(',') + '\r\n')
        );
      }
      controller.close();
    },
  });

  const day = new Date().toISOString().slice(0, 10);
  return new Response(stream, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="securepath-${spec.file}-${id.slice(0, 8)}-${day}.csv"`,
      // disclosure-sensitive — never let a shared cache hold a copy
      'Cache-Control': 'no-store',
    },
  });
}
