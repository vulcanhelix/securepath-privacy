import type { SupabaseClient } from '@supabase/supabase-js';
import { serverClient } from './supabase';

// ---------------------------------------------------------------------------
// W2-00 — programme-world data helpers. Thin wrappers over the W1 RPCs, always
// called under the caller's JWT (serverClient() cookie session — the same
// pattern every existing page uses: RLS/definer guards decide, never the app).
//
// list_programmes (W1-05, migration 20261106000008, FR-PCN-01) returns one
// console row per visible programme. While that migration is still on its
// branch, listProgrammes() falls back to a plain RLS-filtered programmes
// select so the shell example page works today; the rollup columns come back
// null until the RPC lands. Once 20261106000008 is applied the RPC path wins
// automatically.
// ---------------------------------------------------------------------------

export interface ProgrammeListRow {
  programme_id: string;
  programme_name: string;
  client_org_id: string;
  client_name: string;
  framework: string | null;
  template_version_number: number | null;
  status: string;
  phase: string | null;
  current_week: number | null;
  total_weeks: number;
  rag: 'Red' | 'Amber' | 'Green' | null;
  activities_total: number | null;
  activities_complete: number | null;
  activities_overdue: number | null;
  register_open: number | null;
  register_closed: number | null;
  evidence_pending: number | null;
  maintenance_due_month: number | null;
  maintenance_overdue_month: number | null;
  report_status: string | null;
  report_due_on: string | null;
  programme_lead: string | null;
  assigned_consultants: string[] | null;
}

export interface ListProgrammesResult {
  rows: ProgrammeListRow[];
  /** 'rpc' once 20261106000008 is applied, 'table-fallback' before that */
  source: 'rpc' | 'table-fallback';
  error: string | null;
}

function isMissingFunction(err: { code?: string; message?: string } | null): boolean {
  if (!err) return false;
  // PostgREST: PGRST202 "could not find the function"; Postgres: 42883
  return err.code === 'PGRST202' || err.code === '42883' || /list_programmes/.test(err.message ?? '');
}

export async function listProgrammes(
  clientOrgId?: string | null,
  sb?: SupabaseClient
): Promise<ListProgrammesResult> {
  const supabase = sb ?? (await serverClient());
  const { data, error } = await supabase.rpc('list_programmes', {
    p_client_org_id: clientOrgId ?? null,
  });
  if (!error) return { rows: (data ?? []) as ProgrammeListRow[], source: 'rpc', error: null };
  if (!isMissingFunction(error)) return { rows: [], source: 'rpc', error: error.message };

  // ---- fallback until W1-05 merges: RLS-filtered programmes + client names.
  // Rollup columns stay null; rag falls back to the stored programme_rag.
  let q = supabase
    .from('programmes')
    .select('id, name, status, phase, start_date, total_weeks, programme_rag, programme_lead, client_org_id')
    .order('name');
  if (clientOrgId) q = q.eq('client_org_id', clientOrgId);
  const { data: progs, error: pErr } = await q;
  if (pErr) return { rows: [], source: 'table-fallback', error: pErr.message };

  const clientIds = [...new Set((progs ?? []).map((p) => p.client_org_id as string))];
  const { data: clients } = clientIds.length
    ? await supabase.from('client_orgs').select('id, name').in('id', clientIds)
    : { data: [] as { id: string; name: string }[] };
  const nameOf = new Map((clients ?? []).map((c) => [c.id as string, c.name as string]));

  const rows: ProgrammeListRow[] = (progs ?? []).map((p) => ({
    programme_id: p.id as string,
    programme_name: p.name as string,
    client_org_id: p.client_org_id as string,
    client_name: nameOf.get(p.client_org_id as string) ?? '—',
    framework: null,
    template_version_number: null,
    status: p.status as string,
    phase: (p.phase as string) ?? null,
    current_week: null,
    total_weeks: p.total_weeks as number,
    rag: (p.programme_rag as ProgrammeListRow['rag']) ?? null,
    activities_total: null,
    activities_complete: null,
    activities_overdue: null,
    register_open: null,
    register_closed: null,
    evidence_pending: null,
    maintenance_due_month: null,
    maintenance_overdue_month: null,
    report_status: null,
    report_due_on: null,
    programme_lead: (p.programme_lead as string) ?? null,
    assigned_consultants: null,
  }));
  return { rows, source: 'table-fallback', error: null };
}
