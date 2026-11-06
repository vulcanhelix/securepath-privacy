import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { getRoleContext } from '@/lib/role-context';
import { listProgrammes } from '@/lib/programme';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { EmptyState } from '@/components/ui/EmptyState';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { SortableTable } from '@/components/ui/SortableTable';
import { Alert } from '@/components/ui/Alert';

export const dynamic = 'force-dynamic';

// W2-00 — example page proving the kit: FR-PCN-01's programme row via
// list_programmes (W1-05 RPC; table fallback until 20261106000008 lands).
// W2-01 owns the real partner console — copy this pattern.

export default async function ProgrammesPage() {
  const supabase = await serverClient();
  const role = await getRoleContext(supabase);
  if (!role) redirect('/login');

  const { rows, source, error } = await listProgrammes();

  const ragCount = (r: string) => rows.filter((p) => p.rag === r).length;
  const reportsDue = rows.filter(
    (p) => p.report_status && p.report_status !== 'issued' && p.report_due_on
  ).length;

  return (
    <>
      <PageHeader
        title="Programmes"
        meta={`${rows.length} programme${rows.length === 1 ? '' : 's'}${source === 'table-fallback' ? ' · interim view' : ''}`}
      />

      {/* headline tiles — FR-PCN-03 skeleton */}
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{rows.length}</div>
          <div className="muted">Running</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28, color: 'var(--warn)' }}>{ragCount('Amber')}</div>
          <div className="muted">Amber</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28, color: 'var(--fail)' }}>{ragCount('Red')}</div>
          <div className="muted">Red</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{reportsDue}</div>
          <div className="muted">Reports open</div>
        </Card>
      </div>

      {error ? <Alert tone="err">{`Could not load programmes: ${error}`}</Alert> : null}

      <Card pad={0}>
        {rows.length ? (
          <SortableTable
            initialSort={1}
            columns={[
              { label: 'Client' },
              { label: 'Programme' },
              { label: 'Framework' },
              { label: 'Status' },
              { label: 'Week', align: 'right' },
              { label: 'RAG' },
              { label: 'Register', align: 'right' },
              { label: 'Report' },
            ]}
            rows={rows.map((p) => ({
              values: [
                p.client_name,
                p.programme_name,
                p.framework ?? '',
                p.status,
                p.current_week ?? -1,
                p.rag ?? '',
                p.register_open ?? -1,
                p.report_status ?? '',
              ],
              cells: [
                <span key="c">{p.client_name}</span>,
                <Link
                  key="p"
                  href={`/programmes/${p.programme_id}`}
                  style={{ fontWeight: 500, color: 'var(--text)' }}
                >
                  {p.programme_name}
                </Link>,
                <span key="f" className="muted">
                  {p.framework ?? '—'}
                </span>,
                <StatusPill key="s" status={p.status} />,
                <span key="w" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                  {p.current_week != null ? `${p.current_week} / ${p.total_weeks}` : `— / ${p.total_weeks}`}
                </span>,
                <RagBadge key="r" rag={p.rag} />,
                <span key="g" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                  {p.register_open != null
                    ? `${p.register_closed ?? 0}/${(p.register_closed ?? 0) + p.register_open} closed`
                    : '—'}
                </span>,
                <StatusPill key="m" status={p.report_status} />,
              ],
            }))}
          />
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
