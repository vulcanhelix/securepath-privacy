import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { WeekBadge } from '@/components/ui/WeekBadge';
import { EmptyState } from '@/components/ui/EmptyState';

export const dynamic = 'force-dynamic';

// W2-00 — minimal programme landing proving the shell context end-to-end
// (programmeContext + role-filtered tabs above). W2-04 owns the real
// programme dashboard (screen 01).

export default async function ProgrammePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  // §9.1 engine calc, caller's JWT — NULL-safe until the engine row exists
  const { data: week } = await supabase
    .rpc('programme_week', { p_programme: id, p_date: new Date().toISOString().slice(0, 10) })
    .single()
    .then((r) => r, () => ({ data: null }));

  return (
    <>
      <PageHeader
        title={ctx.programme.name}
        eyebrow={ctx.client.name}
        meta={
          <>
            {ctx.client.jurisdiction ? `${ctx.client.jurisdiction} · ` : ''}
            started {ctx.programme.start_date}
          </>
        }
        actions={<WeekBadge week={(week as number | null) ?? null} total={ctx.programme.total_weeks} />}
      />
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <Card pad={16} style={{ flex: '1 1 160px' }}>
          <div style={{ marginBottom: 6 }}><StatusPill status={ctx.programme.status} /></div>
          <div className="muted">Status</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 160px' }}>
          <div style={{ marginBottom: 6 }}><RagBadge rag={ctx.programme.programme_rag} /></div>
          <div className="muted">Programme RAG</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 160px' }}>
          <div className="mono" style={{ fontSize: 22 }}>{ctx.programme.phase ?? '—'}</div>
          <div className="muted">Phase</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 160px' }}>
          <div style={{ marginBottom: 6, fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
            {ctx.brand?.name ?? 'SecurePath'}
          </div>
          <div className="muted">Delivered by</div>
        </Card>
      </div>
      <Card>
        <EmptyState
          icon="layout-dashboard"
          message="Programme dashboard modules mount on the tabs above as W2 screens land — this shell page proves context, nav and branding resolve."
        />
      </Card>
    </>
  );
}
