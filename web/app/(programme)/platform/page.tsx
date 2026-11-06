import { serverClient } from '@/lib/supabase';
import type { PlatformMetrics } from '@/lib/platform';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { DataTable } from '@/components/ui/DataTable';

export const dynamic = 'force-dynamic';

// W2-14 — platform metrics dashboard (FR-PLT-05) over platform_metrics().
// Counts only — NFR-04: no tenant content reaches platform staff here.
// Monthly-report completion rate waits for the programme reports (W2-08).

function Tile({ value, label, tone }: { value: number | string; label: string; tone?: string }) {
  return (
    <Card pad={16} style={{ flex: '1 1 150px' }}>
      <div className="mono" style={{ fontSize: 28, color: tone }}>{value}</div>
      <div className="muted">{label}</div>
    </Card>
  );
}

const rows = (o: Record<string, number> | null | undefined) =>
  Object.entries(o ?? {}).sort((a, b) => b[1] - a[1]);

export default async function PlatformOverview() {
  const supabase = await serverClient();
  const { data, error } = await supabase.rpc('platform_metrics');
  const m = data as PlatformMetrics | null;

  return (
    <>
      <PageHeader
        title="Platform overview"
        meta={m ? `As at ${new Date(m.generated_at).toLocaleString('en-GB')}` : undefined}
      />
      {error ? <Alert tone="err">{`Could not load metrics: ${error.message}`}</Alert> : null}
      {m ? (
        <>
          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 12 }}>
            <Tile value={m.partners.active} label="Active partners" tone="var(--pass)" />
            <Tile value={m.partners.suspended} label="Suspended partners" tone="var(--warn)" />
            <Tile value={m.partners.closed} label="Closed partners" />
            <Tile value={m.clients.total} label="Clients" />
            <Tile value={m.clients.with_open_programme} label="Clients with a live programme" />
          </div>
          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
            <Tile value={m.programmes.implementation} label="Programmes in implementation" />
            <Tile value={m.programmes.maintenance} label="Programmes in maintenance" />
            <Tile value={m.active_users} label="Active tenant users" />
            <Tile value={m.evidence_awaiting.total} label="Evidence awaiting decision" tone="var(--warn)" />
            <Tile value={m.support.pending_requests} label="Support requests pending" />
          </div>

          <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
            <Card title="Live programmes by framework" pad={0} style={{ flex: '1 1 320px' }}>
              <DataTable
                columns={[{ label: 'Framework' }, { label: 'Programmes', align: 'right' }]}
                rows={rows(m.programmes.by_framework).map(([k, v]) => [k, <span key="v" className="mono">{v}</span>])}
              />
            </Card>
            <Card title="Partners by type" pad={0} style={{ flex: '1 1 240px' }}>
              <DataTable
                columns={[{ label: 'Type' }, { label: 'Partners', align: 'right' }]}
                rows={rows(m.partners.by_type).map(([k, v]) => [k, <span key="v" className="mono">{v}</span>])}
              />
            </Card>
            {m.licences ? (
              // platform_admin only — the RPC omits this key for support (§4.1)
              <Card title="Licences by status" pad={0} style={{ flex: '1 1 240px' }}>
                <DataTable
                  columns={[{ label: 'Status' }, { label: 'Licences', align: 'right' }]}
                  rows={rows(m.licences).map(([k, v]) => [k, <span key="v" className="mono">{v}</span>])}
                />
              </Card>
            ) : null}
            <Card title="Evidence review queue" pad={0} style={{ flex: '1 1 240px' }}>
              <DataTable
                columns={[{ label: 'Stage' }, { label: 'Items', align: 'right' }]}
                rows={[
                  ['Awaiting verification', <span key="v" className="mono">{m.evidence_awaiting.verification}</span>],
                  ['Awaiting acceptance', <span key="a" className="mono">{m.evidence_awaiting.acceptance}</span>],
                ]}
              />
            </Card>
          </div>
        </>
      ) : null}
    </>
  );
}
