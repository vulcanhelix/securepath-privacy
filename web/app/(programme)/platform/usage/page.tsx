import Link from 'next/link';
import { serverClient } from '@/lib/supabase';
import { platformGate, typeLabel, capLabel } from '@/lib/platform';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';
import { StatusPill } from '@/components/ui/StatusPill';
import { SortableTable } from '@/components/ui/SortableTable';

export const dynamic = 'force-dynamic';

// W2-14 — platform usage view (FR-LIC-02 / FR-PLT-05) over the W1-07
// usage_report(NULL) RPC: per-partner clients / programmes vs active licence
// caps, active tenant users, programmes by framework. §4.1: licence and
// usage reports are platform_admin only (the RPC refuses support).

interface UsageRow {
  partner_id: string;
  partner_name: string;
  partner_type: string;
  licence_id: string | null;
  plan: string | null;
  licence_status: string | null;
  clients_used: number;
  client_limit: number | null;
  programmes_used: number;
  programme_limit: number | null;
  active_users: number;
  programmes_by_framework: Record<string, number>;
}

const pct = (used: number, limit: number | null) => (limit ? Math.round((used / limit) * 100) : null);

export default async function UsagePage() {
  const supabase = await serverClient();
  const gate = await platformGate(supabase);
  if (!gate.isAdmin) {
    return (
      <>
        <PageHeader title="Usage" />
        <Alert tone="info">Licence and usage reports are limited to platform admins (spec §4.1).</Alert>
      </>
    );
  }
  const { data, error } = await supabase.rpc('usage_report', { p_partner: null });
  const rows = (data ?? []) as UsageRow[];

  return (
    <>
      <PageHeader title="Usage" meta="Clients and programmes against each partner's active, in-term licence" />
      {error ? <Alert tone="err">{`Could not load usage: ${error.message}`}</Alert> : null}
      <Card pad={0}>
        {rows.length ? (
          <SortableTable
            initialSort={0}
            columns={[
              { label: 'Partner' },
              { label: 'Licence' },
              { label: 'Clients', align: 'right' },
              { label: 'Programmes', align: 'right' },
              { label: 'Active users', align: 'right' },
              { label: 'By framework' },
            ]}
            rows={rows.map((r) => {
              const cp = pct(r.clients_used, r.client_limit);
              const pp = pct(r.programmes_used, r.programme_limit);
              const tone = (p: number | null) =>
                p == null ? undefined : p >= 100 ? 'var(--fail)' : p >= 80 ? 'var(--warn)' : undefined;
              return {
                values: [r.partner_name, r.licence_status ?? '', cp ?? -1, pp ?? -1, r.active_users, ''],
                cells: [
                  <div key="n">
                    <Link href={`/platform/partners/${r.partner_id}`} style={{ fontWeight: 500, color: 'var(--text)' }}>
                      {r.partner_name}
                    </Link>
                    <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{typeLabel(r.partner_type)}</div>
                  </div>,
                  r.licence_id ? (
                    <span key="l">
                      <StatusPill status={r.licence_status} /> <span className="muted">{r.plan}</span>
                    </span>
                  ) : (
                    <span key="l" className="muted">no active licence</span>
                  ),
                  <span key="c" className="mono" style={{ color: tone(cp) }}>
                    {capLabel(r.clients_used, r.client_limit)}{cp != null ? ` · ${cp}%` : ''}
                  </span>,
                  <span key="p" className="mono" style={{ color: tone(pp) }}>
                    {capLabel(r.programmes_used, r.programme_limit)}{pp != null ? ` · ${pp}%` : ''}
                  </span>,
                  <span key="u" className="mono">{r.active_users}</span>,
                  <span key="f" className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                    {Object.entries(r.programmes_by_framework ?? {})
                      .map(([k, v]) => `${k} ${v}`)
                      .join(' · ') || '—'}
                  </span>,
                ],
              };
            })}
          />
        ) : (
          !error && <EmptyState icon="bar-chart-3" message="No partners yet." />
        )}
      </Card>
    </>
  );
}
