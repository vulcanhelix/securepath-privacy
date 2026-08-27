import Link from 'next/link';
import { redirect, notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { DataTable } from '@/components/ui/DataTable';
import { StageRail, STAGES } from '@/components/ui/StageRail';
import { ScoreRing } from '@/components/ui/ScoreRing';
import { SectionBars } from '@/components/ui/SectionBars';
import { StatusDot } from '@/components/ui/StatusDot';
import { EmptyState } from '@/components/ui/EmptyState';

export const dynamic = 'force-dynamic';

const ACTION_TONE: Record<string, 'neutral' | 'pass' | 'warn' | 'fail' | 'ink'> = {
  drafted: 'neutral',
  approved: 'pass',
  issued: 'ink',
  rejected: 'fail',
  superseded: 'warn',
};

function stageHref(clientId: string, slug: string, assessmentId?: string | null) {
  if (slug === '') return `/clients/${clientId}`;
  if (slug === 'assessment') return assessmentId ? `/assessments/${assessmentId}` : '/assessments';
  return `/clients/${clientId}/${slug}`;
}

export default async function ClientWorkspace({ params }: { params: Promise<{ id: string }> }) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');
  const { id } = await params;

  const { data: client } = await supabase
    .from('client_orgs')
    .select('id, name, industry, contact_name, contact_email, created_at')
    .eq('id', id)
    .maybeSingle();
  if (!client) notFound();

  const [
    { data: tracks },
    { data: sessions },
    { count: slotCount },
    { data: links },
    { data: policies },
    { data: tasks },
    { count: docCount },
    { data: approvals },
    { data: transitions },
  ] = await Promise.all([
    supabase.from('tracks').select('id, track_kind, current_stage, baseline_pct, baseline_rating, baseline_at').eq('client_org_id', id),
    supabase.from('assessment_sessions').select('id, title, framework, status, score_pct, rating, approval_status, created_at')
      .eq('client_org_id', id).order('created_at', { ascending: false }),
    supabase.from('document_checklists').select('*', { count: 'exact', head: true }).eq('framework_key', 'popia').eq('active', true),
    supabase.from('document_links').select('id, status, checklist_id').eq('client_org_id', id),
    supabase.from('policies').select('id, approval_status').eq('client_org_id', id),
    supabase.from('tasks').select('id, status, priority').eq('client_org_id', id),
    supabase.from('documents').select('*', { count: 'exact', head: true }).eq('client_org_id', id),
    supabase.from('approvals').select('id, subject_type, subject_id, action, actor, note, at').order('at', { ascending: false }).limit(50),
    supabase.from('stage_transitions').select('id, track_id, from_stage, to_stage, actor, note, at').order('at', { ascending: false }).limit(8),
  ]);

  const privacy = tracks?.find((t) => t.track_kind === 'privacy');
  const cyber = tracks?.find((t) => t.track_kind === 'cyber');
  const stage = privacy?.current_stage ?? 0;

  const latestSession = sessions?.[0];
  const confirmedSlots = new Set((links ?? []).filter((l) => l.status === 'confirmed').map((l) => l.checklist_id)).size;
  const issuedPolicies = (policies ?? []).filter((p) => p.approval_status === 'issued' || p.approval_status === 'approved').length;
  const tasksDone = (tasks ?? []).filter((t) => t.status === 'done').length;

  // scope the ledgers to this client: transitions via its tracks, approvals via its artifact ids
  const trackIds = new Set((tracks ?? []).map((t) => t.id));
  const clientTransitions = (transitions ?? []).filter((t) => trackIds.has(t.track_id));
  const [{ data: manualIds }, { data: reportIds }] = await Promise.all([
    supabase.from('manuals').select('id').eq('client_org_id', id),
    supabase.from('monthly_reports').select('id').eq('client_org_id', id),
  ]);
  const subjectIds = new Set<string>([
    ...(sessions ?? []).map((s) => s.id),
    ...(policies ?? []).map((p) => p.id),
    ...(manualIds ?? []).map((m) => m.id),
    ...(reportIds ?? []).map((r) => r.id),
  ]);
  const clientApprovals = (approvals ?? []).filter((a) => subjectIds.has(a.subject_id)).slice(0, 8);
  const actorIds = [...new Set([...clientApprovals, ...clientTransitions].map((r) => r.actor).filter(Boolean))] as string[];
  const { data: actors } = actorIds.length
    ? await supabase.from('users').select('id, email').in('id', actorIds)
    : { data: [] as { id: string; email: string }[] };
  const emailOf = (uid: string | null) => actors?.find((a) => a.id === uid)?.email ?? '—';

  const nextGate = stage <= 1 ? 'Gate 1 — assessment sign-off' : stage <= 3 ? 'Gate 2 — policy suite approved'
    : stage === 4 ? 'Gate 3 — manual sign-off + s.51' : stage === 5 ? 'Gate 4 — remediation done' : 'All gates passed';

  const continueStage = STAGES.find((s) => s.n === stage) ?? STAGES[0];
  const ts = (v: string) => new Date(v).toLocaleString();

  return (
    <>
      <PageHeader
        title={client.name}
        back="Clients"
        backHref="/dashboard"
        meta={[client.industry, client.contact_name, client.contact_email].filter(Boolean).join(' · ') || undefined}
        actions={
          stage > 0 || latestSession ? (
            <Link href={stageHref(id, continueStage.slug, latestSession?.id)}>
              <Button cta>Continue Stage {stage} — {continueStage.label}</Button>
            </Link>
          ) : (
            <Link href="/assessments/new">
              <Button cta>Start Stage 1 — Assessment</Button>
            </Link>
          )
        }
      />

      <Card pad={24} style={{ marginBottom: 24 }}>
        <StageRail stage={stage} hrefFor={(s) => stageHref(id, s.slug, latestSession?.id)} />
      </Card>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 16, marginBottom: 24 }}>
        <Link href={stageHref(id, 'assessment', latestSession?.id)} className="sp-kpi">
          <Card pad={20}>
            <div className="sp-kpi-label">Assessment</div>
            <div className="sp-kpi-value">{privacy?.baseline_pct != null ? `${privacy.baseline_pct}%` : latestSession?.score_pct != null ? `${latestSession.score_pct}%` : '—'}</div>
            <div className="sp-kpi-sub">
              {privacy?.baseline_pct != null
                ? <><StatusDot tone="pass" /> baseline signed off</>
                : latestSession ? 'live score — not yet signed off' : 'not started'}
            </div>
          </Card>
        </Link>
        <Link href={`/clients/${id}/documents`} className="sp-kpi">
          <Card pad={20}>
            <div className="sp-kpi-label">Documents</div>
            <div className="sp-kpi-value">{confirmedSlots}/{slotCount ?? 0}</div>
            <div className="sp-kpi-sub">checklist slots filled</div>
          </Card>
        </Link>
        <Link href={`/clients/${id}/policies`} className="sp-kpi">
          <Card pad={20}>
            <div className="sp-kpi-label">Policies</div>
            <div className="sp-kpi-value">{issuedPolicies}/{policies?.length ?? 0}</div>
            <div className="sp-kpi-sub">approved or issued</div>
          </Card>
        </Link>
        <Link href={`/clients/${id}/tasks`} className="sp-kpi">
          <Card pad={20}>
            <div className="sp-kpi-label">Remediation</div>
            <div className="sp-kpi-value">{tasksDone}/{tasks?.length ?? 0}</div>
            <div className="sp-kpi-sub">tasks complete</div>
          </Card>
        </Link>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 24, alignItems: 'start' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
          <Card title="Baseline" pad={28}>
            {privacy?.baseline_pct != null ? (
              <div style={{ display: 'flex', gap: 28, alignItems: 'center', flexWrap: 'wrap' }}>
                <ScoreRing pct={privacy.baseline_pct} size={104} label={privacy.baseline_rating ?? undefined} />
                <div style={{ flex: 1, minWidth: 220 }}>
                  <p className="muted" style={{ marginTop: 0, fontSize: 'var(--fs-sm)' }}>
                    Snapshotted {privacy.baseline_at ? new Date(privacy.baseline_at).toLocaleDateString() : ''} at Gate 1 — immutable.
                    The board closes gaps against it; the monthly report shows movement against it.
                  </p>
                </div>
              </div>
            ) : latestSession?.score_pct != null ? (
              <div style={{ display: 'flex', gap: 28, alignItems: 'center', flexWrap: 'wrap' }}>
                <ScoreRing pct={latestSession.score_pct} size={104} label="live score" />
                <p className="muted" style={{ flex: 1, minWidth: 220, fontSize: 'var(--fs-sm)' }}>
                  Not yet the baseline — Gate 1 sign-off snapshots this score onto the track.
                </p>
              </div>
            ) : (
              <EmptyState icon="gauge" message="No assessment yet. The Stage 1 score becomes the baseline the whole engagement anchors on." />
            )}
          </Card>

          <Card title="Approvals" action={<span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--faint)' }}>append-only</span>} pad={0}>
            {clientApprovals.length ? (
              <DataTable
                columns={[{ label: 'Subject' }, { label: 'Action' }, { label: 'Actor' }, { label: 'At', align: 'right' }]}
                rows={clientApprovals.map((a) => [
                  <span key="s">
                    <span style={{ color: 'var(--text)' }}>{a.subject_type.replace(/_/g, ' ')}</span>
                    {a.note ? <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>{a.note}</span> : null}
                  </span>,
                  <Badge key="a" tone={ACTION_TONE[a.action] ?? 'neutral'}>{a.action}</Badge>,
                  <span key="e" className="muted">{emailOf(a.actor)}</span>,
                  <span key="t" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>{ts(a.at)}</span>,
                ])}
              />
            ) : (
              <EmptyState icon="stamp" message="No approvals recorded yet. Every gate writes a row here." />
            )}
          </Card>

          <Card title="Stage transitions" action={<span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--faint)' }}>append-only</span>} pad={0}>
            {clientTransitions.length ? (
              <DataTable
                columns={[{ label: 'Transition' }, { label: 'Track' }, { label: 'Actor' }, { label: 'At', align: 'right' }]}
                rows={clientTransitions.map((t) => [
                  <span key="s" className="mono" style={{ fontSize: 'var(--fs-sm)', color: 'var(--text)' }}>
                    Stage {t.from_stage} → {t.to_stage}
                  </span>,
                  tracks?.find((x) => x.id === t.track_id)?.track_kind ?? '—',
                  <span key="e" className="muted">{emailOf(t.actor)}</span>,
                  <span key="t" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>{ts(t.at)}</span>,
                ])}
              />
            ) : (
              <EmptyState icon="route" message="No transitions yet. Stages only move by explicit, logged sign-off." />
            )}
          </Card>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
          <Card title="Tracks" tone="dark" pad={24}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                <span>Privacy track</span>
                <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--panel-muted)' }}>
                  Stage {privacy?.current_stage ?? '—'}/6
                </span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                <span>Cyber track</span>
                <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--panel-muted)' }}>
                  {cyber ? `Stage ${cyber.current_stage}/6` : 'not started'}
                </span>
              </div>
              <div style={{ borderTop: '1px solid var(--panel-line)', paddingTop: 14, fontSize: 'var(--fs-sm)', color: 'var(--panel-muted)' }}>
                Next gate: {nextGate}
              </div>
            </div>
          </Card>

          <Card title="Evidence" pad={24}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10, fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span>Uploaded documents</span>
                <span className="mono">{docCount ?? 0}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span>Confirmed slots</span>
                <span className="mono">{confirmedSlots}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span>Policies</span>
                <span className="mono">{policies?.length ?? 0}</span>
              </div>
              <p className="muted" style={{ margin: '6px 0 0', fontSize: 'var(--fs-xs)' }}>
                Evidence is immutable — corrections are new versions, never edits.
              </p>
            </div>
          </Card>
        </div>
      </div>
    </>
  );
}
