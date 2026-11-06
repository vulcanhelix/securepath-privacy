import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import {
  platformGate,
  typeLabel,
  capLabel,
  dateLabel,
  type PartnerRow,
  type PlatformClientRow,
  type LicenceRow,
} from '@/lib/platform';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';
import { StatusPill } from '@/components/ui/StatusPill';
import { PartnerEditForm } from './PartnerEditForm';
import { PartnerStatusPanel } from './PartnerStatusPanel';
import { LicencePanel } from './LicencePanel';

export const dynamic = 'force-dynamic';

// W2-14 — partner detail (FR-PLT-01/02). Partner metadata + counts come from
// platform_list_partners({id}); licences are read under licences_read RLS
// (platform_admin only — support sees the summary from the list RPC); the
// client directory is platform_list_clients (names + counts only, NFR-04).
// Writes: platform_update_partner, platform_set_partner_status and the W1-07
// licence RPCs — all admin-gated here and re-checked in the RPC bodies.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function PartnerDetail({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const supabase = await serverClient();
  const gate = await platformGate(supabase);

  const [{ data: rows, error }, { data: clientRows }, { data: licRows }] = await Promise.all([
    supabase.rpc('platform_list_partners', { p_filters: { id } }),
    supabase.rpc('platform_list_clients', { p_partner: id }),
    gate.isAdmin
      ? supabase
          .from('licences')
          .select('id, partner_id, plan, client_limit, programme_limit, starts_on, ends_on, status, attribution_display, created_at, updated_at')
          .eq('partner_id', id)
          .order('created_at', { ascending: false })
      : Promise.resolve({ data: [] as LicenceRow[] }),
  ]);
  if (error) {
    return <Alert tone="err">{`Could not load partner: ${error.message}`}</Alert>;
  }
  const p = ((rows ?? []) as PartnerRow[])[0];
  if (!p) notFound();
  const clients = (clientRows ?? []) as PlatformClientRow[];
  const licences = (licRows ?? []) as LicenceRow[];

  return (
    <>
      <PageHeader
        back="Partners"
        backHref="/platform/partners"
        eyebrow={typeLabel(p.type)}
        title={p.name}
        meta={
          <>
            <StatusPill status={p.status} /> · {p.country ?? '—'}
            {p.subdomain ? <> · <span className="mono">{p.subdomain}</span></> : null} · created {dateLabel(p.created_at)}
          </>
        }
      />

      {p.status !== 'active' && p.status_reason ? (
        <Alert tone="info">
          {`${p.status === 'closed' ? 'Closed' : 'Suspended'} ${dateLabel(p.status_changed_at)}: ${p.status_reason}`}
        </Alert>
      ) : null}

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <Card pad={16} style={{ flex: '1 1 150px' }}>
          <div className="mono" style={{ fontSize: 24 }}>{capLabel(p.clients_used, p.client_limit)}</div>
          <div className="muted">Clients in use / cap ({p.clients_total} on record)</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 150px' }}>
          <div className="mono" style={{ fontSize: 24 }}>{capLabel(p.programmes_used, p.programme_limit)}</div>
          <div className="muted">Programmes / cap</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 150px' }}>
          <div className="mono" style={{ fontSize: 24 }}>{p.seats_used} / 5</div>
          <div className="muted">Team seats ({p.pending_invites} invite{p.pending_invites === 1 ? '' : 's'} pending)</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 150px' }}>
          <div style={{ fontSize: 18, marginBottom: 4 }}>
            {p.licence_id ? <StatusPill status={p.licence_status} label={`${p.licence_plan} · ${p.licence_status}`} /> : '—'}
          </div>
          <div className="muted">Current licence{p.licence_ends_on ? ` · ends ${dateLabel(p.licence_ends_on)}` : ''}</div>
        </Card>
      </div>

      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'flex-start', marginBottom: 16 }}>
        <div style={{ flex: '2 1 420px', minWidth: 0 }}>
          <Card title="Partner details">
            <PartnerEditForm partner={p} canEdit={gate.isAdmin && p.status !== 'closed'} />
          </Card>
        </div>
        <div style={{ flex: '1 1 280px', minWidth: 0 }}>
          <Card title="Status">
            <PartnerStatusPanel partnerId={p.partner_id} status={p.status} canEdit={gate.isAdmin} />
          </Card>
        </div>
      </div>

      {gate.isAdmin ? (
        <div style={{ marginBottom: 16 }}>
          <Card title="Licences" pad={0}>
            <LicencePanel partnerId={p.partner_id} licences={licences} />
          </Card>
        </div>
      ) : null}

      <Card title="Clients" pad={0}>
        {clients.length ? (
          <DataTable
            columns={[
              { label: 'Client' },
              { label: 'Jurisdiction' },
              { label: 'Programmes', align: 'right' },
              { label: 'Created' },
              { label: '' },
            ]}
            rows={clients.map((c) => [
              <span key="n" style={{ fontWeight: 500 }}>{c.client_name}</span>,
              <span key="j" className="muted">{c.jurisdiction ?? '—'}</span>,
              <span key="p" className="mono">{c.programmes_open} open / {c.programmes_total}</span>,
              <span key="d" className="muted">{dateLabel(c.created_at)}</span>,
              <Link key="s" href={`/platform/support?client=${c.client_org_id}`} className="muted">
                Request support access
              </Link>,
            ])}
          />
        ) : (
          <EmptyState icon="building" message="No clients yet. The partner onboards its own clients." />
        )}
      </Card>
      <p className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 8 }}>
        Platform staff see client names and counts only. Opening a client&apos;s programme data needs a support grant
        approved by the client (NFR-04).
      </p>
    </>
  );
}
