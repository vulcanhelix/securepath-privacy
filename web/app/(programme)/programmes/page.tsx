import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { getRoleContext } from '@/lib/role-context';
import { listProgrammes, type ProgrammeListRow } from '@/lib/programme';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { EmptyState } from '@/components/ui/EmptyState';
import { Alert } from '@/components/ui/Alert';
import { StatusPill } from '@/components/ui/StatusPill';
import { ConsoleTable, type ConsoleRow } from './ConsoleTable';

export const dynamic = 'force-dynamic';

// ---------------------------------------------------------------------------
// W2-01 — partner console (spec §7.2, screen 10 / Annex B.3). The MSP's home:
// every visible client programme as a rollup row (FR-PCN-01), headline tiles
// (FR-PCN-03), a needs-attention list, licence usage vs cap (FR-LIC-01, via
// the 000001/000009 §9.8 counter) and pending support-access requests for
// awareness (FR-PLT-04 — the decision happens on the programme's access
// screen; here we only link).
//
// Read-only rollup: programme rows come from list_programmes (week, RAG and
// phase are all server-computed — partner_console_rag/programme_week, never
// derived in the UI). support_access_requests reads under its own RLS SELECT
// policy (client-visible by design); licence usage via the in-body-guarded
// partner_licence_usage definer. No writes, no new RPCs.
// ---------------------------------------------------------------------------

interface LicenceUsage {
  programmes_used: number;
  clients_used: number;
  client_limit: number | null;
  programme_limit: number | null;
  over_client_limit: boolean;
  over_programme_limit: boolean;
}

interface PendingRequest {
  id: string;
  client_org_id: string;
  reason: string;
  expires_at: string;
  requested_by: string;
}

const todayIso = () => new Date().toISOString().slice(0, 10);

function Tile({ value, label, tone }: { value: number | string; label: string; tone?: string }) {
  return (
    <Card pad={16} style={{ flex: '1 1 150px' }}>
      <div className="mono" style={{ fontSize: 28, color: tone }}>{value}</div>
      <div className="muted">{label}</div>
    </Card>
  );
}

/** Why a programme lands on the needs-attention list. Mirrors the tile rules. */
function attentionReasons(p: ProgrammeListRow, today: string, weekEnd: string): string[] {
  const out: string[] = [];
  if (p.rag === 'Red' || p.rag === 'Amber') out.push(`${p.rag} RAG`);
  if ((p.activities_overdue ?? 0) > 0)
    out.push(`${p.activities_overdue} ${p.activities_overdue === 1 ? 'activity' : 'activities'} overdue`);
  if ((p.maintenance_overdue_month ?? 0) > 0)
    out.push(`${p.maintenance_overdue_month} maintenance ${p.maintenance_overdue_month === 1 ? 'task' : 'tasks'} overdue`);
  if ((p.evidence_pending ?? 0) > 0)
    out.push(`${p.evidence_pending} evidence awaiting decision`);
  if (p.report_due_on && p.report_status !== 'issued') {
    if (p.report_due_on < today) out.push('monthly report late');
    else if (p.report_due_on <= weekEnd) out.push('report due this week');
  }
  return out;
}

export default async function ProgrammesPage() {
  const supabase = await serverClient();
  const role = await getRoleContext(supabase);
  if (!role) redirect('/login');

  const today = todayIso();
  const weekEnd = new Date(Date.now() + 7 * 86400_000).toISOString().slice(0, 10);

  const [{ rows, source, error }, { data: reqRows, error: reqErr }] = await Promise.all([
    listProgrammes(),
    // FR-PLT-04 awareness: pending support-access requests on visible clients.
    // support_access_requests has its own SELECT policy (client-visible);
    // still-open windows only — a lapsed pending request is dead either way.
    supabase
      .from('support_access_requests')
      .select('id, client_org_id, reason, expires_at, requested_by')
      .eq('status', 'pending')
      .gt('expires_at', new Date().toISOString())
      .order('expires_at'),
  ]);

  const pending = (reqRows ?? []) as PendingRequest[];

  // client names + jurisdictions (T1 RLS — caller's own tenants only). Union
  // of portfolio clients and request clients so a request still names its
  // client when no programme row for it is visible.
  const clientIds = [
    ...new Set([...rows.map((r) => r.client_org_id), ...pending.map((r) => r.client_org_id)]),
  ];
  const { data: clientRows } = clientIds.length
    ? await supabase.from('client_orgs').select('id, name, jurisdiction').in('id', clientIds)
    : { data: [] as { id: string; name: string; jurisdiction: string | null }[] };

  const clientInfo = new Map(
    (clientRows ?? []).map((c) => [c.id as string, { name: c.name as string, jurisdiction: (c.jurisdiction as string) ?? null }])
  );

  // FR-LIC-01 — usage vs cap, partner-scope callers only (the in-body guard
  // rejects anyone without a partner role on that partner anyway).
  let usage: LicenceUsage | null = null;
  let usageErr: string | null = null;
  if (role.partnerIds.length) {
    const { data, error: uErr } = await supabase.rpc('partner_licence_usage', {
      p_partner: role.partnerIds[0],
    });
    if (uErr) usageErr = uErr.message;
    else usage = ((data ?? []) as LicenceUsage[])[0] ?? null;
  }

  // ---- FR-PCN-03 headline figures ------------------------------------------
  const running = rows.filter((r) => r.status !== 'closed').length;
  const amberRed = rows.filter((r) => r.rag === 'Amber' || r.rag === 'Red').length;
  const maintOverdue = rows.reduce((n, r) => n + (r.maintenance_overdue_month ?? 0), 0);
  const reportsDueWeek = rows.filter(
    (r) => r.report_due_on && r.report_status !== 'issued' && r.report_due_on >= today && r.report_due_on <= weekEnd
  ).length;
  const reportsLate = rows.filter(
    (r) => r.report_due_on && r.report_status !== 'issued' && r.report_due_on < today
  ).length;

  const attention = rows
    .map((r) => ({ row: r, reasons: attentionReasons(r, today, weekEnd) }))
    .filter((x) => x.reasons.length > 0);

  const consoleRows: ConsoleRow[] = rows.map((p) => ({
    programme_id: p.programme_id,
    programme_name: p.programme_name,
    client_name: p.client_name,
    jurisdiction: clientInfo.get(p.client_org_id)?.jurisdiction ?? null,
    framework: p.framework,
    status: p.status,
    phase: p.phase,
    current_week: p.current_week,
    total_weeks: p.total_weeks,
    rag: p.rag,
    register_closed: p.register_closed,
    register_open: p.register_open,
    activities_overdue: p.activities_overdue,
    evidence_pending: p.evidence_pending,
    maintenance_due_month: p.maintenance_due_month,
    maintenance_overdue_month: p.maintenance_overdue_month,
    report_status: p.report_status,
    report_due_on: p.report_due_on,
    consultants: p.assigned_consultants ?? [],
    attention: attentionReasons(p, today, weekEnd),
  }));

  const firstProgrammeOf = new Map<string, string>();
  for (const r of rows) if (!firstProgrammeOf.has(r.client_org_id)) firstProgrammeOf.set(r.client_org_id, r.programme_id);

  const clients = new Set(rows.map((r) => r.client_org_id)).size;

  return (
    <>
      <PageHeader
        title="Programmes"
        meta={`${rows.length} programme${rows.length === 1 ? '' : 's'} across ${clients} client${clients === 1 ? '' : 's'}${source === 'table-fallback' ? ' · interim view' : ''}`}
      />

      {/* FR-PCN-03 headline tiles */}
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <Tile value={running} label="Programmes running" />
        <Tile value={amberRed} label="Amber or Red" tone={amberRed ? 'var(--warn)' : undefined} />
        <Tile value={maintOverdue} label="Maintenance tasks overdue" tone={maintOverdue ? 'var(--fail)' : undefined} />
        <Tile value={reportsDueWeek} label="Reports due this week" tone={reportsDueWeek ? 'var(--warn)' : undefined} />
        <Tile value={reportsLate} label="Reports late" tone={reportsLate ? 'var(--fail)' : undefined} />
      </div>

      {error ? <Alert tone="err">{`Could not load programmes: ${error}`}</Alert> : null}
      {reqErr ? <Alert tone="err">{`Could not load support-access requests: ${reqErr.message}`}</Alert> : null}
      {usageErr ? <Alert tone="err">{`Could not load licence usage: ${usageErr}`}</Alert> : null}

      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', marginBottom: 16 }}>
        {/* Needs attention — the console's worklist */}
        {attention.length ? (
          <Card title="Needs attention" pad={0} style={{ flex: '2 1 420px' }}>
            <ul style={{ listStyle: 'none', margin: 0, padding: '6px 0' }}>
              {attention.map(({ row, reasons }) => (
                <li
                  key={row.programme_id}
                  style={{ display: 'flex', gap: 10, alignItems: 'baseline', padding: '8px 20px', borderTop: '1px solid var(--line)' }}
                >
                  <Link href={`/programmes/${row.programme_id}`} style={{ fontWeight: 500, color: 'var(--text)', whiteSpace: 'nowrap' }}>
                    {row.programme_name}
                  </Link>
                  <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{row.client_name}</span>
                  <span className="muted" style={{ fontSize: 'var(--fs-xs)', marginLeft: 'auto', textAlign: 'right' }}>
                    {reasons.join(' · ')}
                  </span>
                </li>
              ))}
            </ul>
          </Card>
        ) : null}

        <div style={{ flex: '1 1 280px', display: 'flex', flexDirection: 'column', gap: 16 }}>
          {/* FR-LIC-01 — licence usage vs cap (§9.8 counter) */}
          {usage ? (
            <Card title="Licence usage">
              <div className="mono" style={{ fontSize: 18, color: usage.over_client_limit ? 'var(--fail)' : 'var(--text)' }}>
                Clients {usage.clients_used} / {usage.client_limit ?? '∞'}
              </div>
              <div className="mono" style={{ fontSize: 18, marginTop: 6, color: usage.over_programme_limit ? 'var(--fail)' : 'var(--text)' }}>
                Programmes {usage.programmes_used} / {usage.programme_limit ?? '∞'}
              </div>
              {usage.over_client_limit || usage.over_programme_limit ? (
                <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 8 }}>
                  Over the active licence — new clients or programmes are blocked until the licence is raised.
                </div>
              ) : (
                <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 8 }}>
                  Onboarding is blocked at the cap.
                </div>
              )}
            </Card>
          ) : null}

          {/* FR-PLT-04 — pending support-access requests, awareness only.
              Approve/decline lives on the programme's access screen (W4-01). */}
          {pending.length ? (
            <Card title="Support access — awaiting decision" pad={0}>
              <ul style={{ listStyle: 'none', margin: 0, padding: '6px 0' }}>
                {pending.map((r) => {
                  const pid = firstProgrammeOf.get(r.client_org_id);
                  return (
                    <li key={r.id} style={{ padding: '8px 20px', borderTop: '1px solid var(--line)' }}>
                      <div style={{ display: 'flex', gap: 8, alignItems: 'baseline' }}>
                        <span style={{ fontWeight: 500 }}>
                          {clientInfo.get(r.client_org_id)?.name ?? 'Client'}
                        </span>
                        {pid ? (
                          <Link href={`/programmes/${pid}/access`} style={{ marginLeft: 'auto', fontSize: 'var(--fs-xs)' }}>
                            Review
                          </Link>
                        ) : null}
                      </div>
                      <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 2 }}>{r.reason}</div>
                      <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                        <StatusPill status="pending" />{' '}
                        window ends{' '}
                        {new Date(r.expires_at).toLocaleString('en-GB', {
                          day: 'numeric',
                          month: 'short',
                          hour: '2-digit',
                          minute: '2-digit',
                        })}
                      </div>
                    </li>
                  );
                })}
              </ul>
            </Card>
          ) : null}
        </div>
      </div>

      {/* FR-PCN-01/02 — the portfolio table */}
      <Card pad={0}>
        {consoleRows.length ? (
          <ConsoleTable rows={consoleRows} />
        ) : (
          !error && (
            <EmptyState
              icon="layout-grid"
              message="No programmes yet. Programmes are created from framework templates during client onboarding."
            />
          )
        )}
      </Card>
    </>
  );
}
