import Link from 'next/link';
import { serverClient } from '@/lib/supabase';
import { platformGate, typeLabel, capLabel, type PartnerRow } from '@/lib/platform';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';
import { StatusPill } from '@/components/ui/StatusPill';
import { SortableTable } from '@/components/ui/SortableTable';
import { CreatePartnerForm } from './CreatePartnerForm';
import { PartnerFilters } from './PartnerFilters';

export const dynamic = 'force-dynamic';

// W2-14 — partners list (FR-PLT-01) over platform_list_partners(filters).
// Filters travel in the query string and are passed to the RPC verbatim
// (it rejects unknown keys). Create is platform_admin only; support sees
// routing metadata only (§4.1 licence reports: None — the RPC NULLs them).

const FILTER_KEYS = ['status', 'type', 'country', 'q'] as const;

export default async function PartnersPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const sp = await searchParams;
  const filters: Record<string, string> = {};
  for (const k of FILTER_KEYS) {
    const v = sp[k];
    if (typeof v === 'string' && v.trim()) filters[k] = v.trim();
  }

  const supabase = await serverClient();
  const [gate, { data, error }] = await Promise.all([
    platformGate(supabase),
    supabase.rpc('platform_list_partners', { p_filters: filters }),
  ]);
  const partners = (data ?? []) as PartnerRow[];

  return (
    <>
      <PageHeader
        title="Partners"
        meta={`${partners.length} partner${partners.length === 1 ? '' : 's'}${gate.isAdmin ? '' : ' · read-only'}`}
      />

      {gate.isAdmin ? (
        <div style={{ marginBottom: 16 }}>
          <CreatePartnerForm />
        </div>
      ) : null}

      <PartnerFilters initial={filters} />

      {error ? <Alert tone="err">{`Could not load partners: ${error.message}`}</Alert> : null}

      <Card pad={0}>
        {partners.length ? (
          gate.isAdmin ? (
            <SortableTable
              initialSort={0}
              columns={[
                { label: 'Partner' },
                { label: 'Type' },
                { label: 'Country' },
                { label: 'Status' },
                { label: 'Licence' },
                { label: 'Clients', align: 'right' },
                { label: 'Programmes', align: 'right' },
                { label: 'Seats', align: 'right' },
              ]}
              rows={partners.map((p) => ({
                values: [
                  p.name,
                  p.type,
                  p.country ?? '',
                  p.status,
                  p.licence_status ?? '',
                  p.clients_used ?? -1,
                  p.programmes_used ?? -1,
                  p.seats_used ?? -1,
                ],
                cells: [
                  <PartnerName key="n" p={p} />,
                  <span key="t" className="muted">{typeLabel(p.type)}</span>,
                  <span key="c" className="muted">{p.country ?? '—'}</span>,
                  <StatusPill key="s" status={p.status} />,
                  <span key="l">
                    {p.licence_id ? (
                      <>
                        <StatusPill status={p.licence_status} />{' '}
                        <span className="muted">{p.licence_plan}</span>
                      </>
                    ) : (
                      <span className="muted">none</span>
                    )}
                  </span>,
                  <span key="cu" className="mono" style={{ color: p.over_client_limit ? 'var(--fail)' : undefined }}>
                    {capLabel(p.clients_used, p.client_limit)}
                    <span className="muted"> ({p.clients_total})</span>
                  </span>,
                  <span key="pu" className="mono" style={{ color: p.over_programme_limit ? 'var(--fail)' : undefined }}>
                    {capLabel(p.programmes_used, p.programme_limit)}
                  </span>,
                  <span key="se" className="mono">{p.seats_used ?? 0} / 5</span>,
                ],
              }))}
            />
          ) : (
            // support (§4.1 licence reports: None) — the RPC returns NULL for
            // every licence/usage column; render routing metadata only
            <SortableTable
              initialSort={0}
              columns={[
                { label: 'Partner' },
                { label: 'Type' },
                { label: 'Country' },
                { label: 'Status' },
                { label: 'Clients', align: 'right' },
              ]}
              rows={partners.map((p) => ({
                values: [p.name, p.type, p.country ?? '', p.status, p.clients_total],
                cells: [
                  <PartnerName key="n" p={p} />,
                  <span key="t" className="muted">{typeLabel(p.type)}</span>,
                  <span key="c" className="muted">{p.country ?? '—'}</span>,
                  <StatusPill key="s" status={p.status} />,
                  <span key="cl" className="mono">{p.clients_total}</span>,
                ],
              }))}
            />
          )
        ) : (
          !error && <EmptyState icon="building-2" message="No partners match." />
        )}
      </Card>
      {gate.isAdmin ? (
      <p className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 8 }}>
        Clients and programmes count against the active licence (§9.8: a client counts while it has a programme that
        is not closed); the bracketed figure is every client on record. Seats are partner team members excluding the
        owner.
      </p>
      ) : null}
    </>
  );
}

function PartnerName({ p }: { p: PartnerRow }) {
  return (
    <div>
      <Link href={`/platform/partners/${p.partner_id}`} style={{ fontWeight: 500, color: 'var(--text)' }}>
        {p.name}
      </Link>
      {p.subdomain ? <div className="muted mono" style={{ fontSize: 'var(--fs-xs)' }}>{p.subdomain}</div> : null}
    </div>
  );
}
