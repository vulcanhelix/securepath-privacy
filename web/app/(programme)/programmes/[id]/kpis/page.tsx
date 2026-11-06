import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';
import { KpiTable, type KpiRow, type KpiActual } from './KpiTable';

export const dynamic = 'force-dynamic';

// W2-11 — KPIs (spec §8.7 FR-KPI-01..04). Reads kpi_status (W1-06 RPC: latest
// monthly actual + RAG vs target) and the kpi_actuals history, all under the
// caller's JWT. Write affordances are UI hints only — record_kpi_actual and
// confirm_kpi_target re-check has_programme_role / is_ao_or_alternate and
// auto_calc in their bodies.

const WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];

export default async function KpisPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const [{ data: status, error }, { data: canWrite }, canConfirm] = await Promise.all([
    supabase.rpc('kpi_status', { p_programme_id: id }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: WRITE_ROLES }),
    ctx.role.isAoOrAlternate(ctx.client.id),
  ]);

  const kpis = (status ?? []) as KpiRow[];

  // period history (FR-KPI-04 trend) — kpi_actuals is T2-via-kpi under RLS
  let history: KpiActual[] = [];
  if (kpis.length) {
    const { data } = await supabase
      .from('kpi_actuals')
      .select('id, kpi_id, month, value, evidence_id, created_at')
      .in('kpi_id', kpis.map((k) => k.kpi_id))
      .order('month', { ascending: false });
    history = (data ?? []) as KpiActual[];
  }

  const rag = (r: string) => kpis.filter((k) => k.rag === r).length;
  const proposed = kpis.filter((k) => k.target_proposed && !k.target_confirmed).length;

  return (
    <>
      <PageHeader
        title="KPIs"
        meta={`${kpis.length} KPI${kpis.length === 1 ? '' : 's'} · monthly actuals against target`}
      />

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28, color: 'var(--pass)' }}>{rag('Green')}</div>
          <div className="muted">On target</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28, color: 'var(--warn)' }}>{rag('Amber')}</div>
          <div className="muted">Improving</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28, color: 'var(--fail)' }}>{rag('Red')}</div>
          <div className="muted">Off target</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{proposed}</div>
          <div className="muted">Targets awaiting AO</div>
        </Card>
      </div>

      {error ? <Alert tone="err">{`Could not load KPIs: ${error.message}`}</Alert> : null}

      <Card pad={0}>
        {kpis.length ? (
          <KpiTable
            kpis={kpis}
            history={history}
            canWrite={canWrite === true}
            canConfirm={canConfirm}
          />
        ) : (
          !error && (
            <EmptyState
              icon="gauge"
              message="No KPIs on this programme yet. KPIs are loaded from the framework template when the programme is created."
            />
          )
        )}
      </Card>
    </>
  );
}
