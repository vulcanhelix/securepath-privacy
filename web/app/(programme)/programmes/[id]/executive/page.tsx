import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { EmptyState } from '@/components/ui/EmptyState';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { WeekBadge } from '@/components/ui/WeekBadge';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';

export const dynamic = 'force-dynamic';

// W2-13 — executive view (spec §8.14 FR-EXE-01): the read-only rollup for
// the client's board or directors. Every figure comes from the
// programme_executive_rollup definer RPC (migration 20261106000022) — the
// §9 week/phase/RAG/overdue/acceptance rules live server-side; this page
// only formats. No write affordances exist on this surface by design.

interface Rollup {
  week: number | null;
  total_weeks: number;
  phase: string | null;
  status: string;
  rag: string | null;
  register: { open_high: number; open_medium: number; open_low: number; closed: number; overdue: number };
  activities: { total: number; complete: number; overdue: number };
  milestones: { id: string; ref: string; text: string; status: string; end_week: number; due_date: string | null }[];
  raid: { open: number; due_for_review: number };
  decisions: { outcome: string; decided_on: string; minute_ref: string | null; description: string }[];
  evidence: {
    awaiting_verification: number;
    awaiting_acceptance: number;
    accepted: number;
    returned: number;
    acceptance_rate: number | null;
  };
  maintenance: { period: string; done: number; open: number; overdue_all: number };
  latest_report: { id: string; period: string; reference: string | null; overall_rag: string | null; issued_on: string | null } | null;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function fmtDay(d?: string | null) {
  if (!d) return '—';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d);
  return m ? `${Number(m[3])} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : d;
}

function Figure({ n, label, sub, tone }: { n: React.ReactNode; label: string; sub?: string; tone?: string }) {
  return (
    <div style={{ flex: '1 1 130px' }}>
      <div className="mono" style={{ fontSize: 28, color: tone ?? 'var(--text)' }}>{n}</div>
      <div className="muted">{label}</div>
      {sub ? <div className="muted" style={{ marginTop: 2 }}>{sub}</div> : null}
    </div>
  );
}

export default async function ExecutivePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const { data, error } = await supabase.rpc('programme_executive_rollup', { p_programme: id });
  const r = (data ?? null) as Rollup | null;

  const openFindings = r ? r.register.open_high + r.register.open_medium + r.register.open_low : 0;

  return (
    <>
      <PageHeader
        title="Executive view"
        eyebrow={`${ctx.client.name} · ${ctx.programme.name}`}
        meta={
          <>
            read-only · {r?.phase ? `${r.phase} · ` : ''}figures as at today
          </>
        }
        actions={
          <>
            <StatusPill status={r?.status ?? ctx.programme.status} />
            <RagBadge rag={r?.rag ?? ctx.programme.programme_rag} />
            <WeekBadge week={r?.week} total={r?.total_weeks ?? ctx.programme.total_weeks} />
          </>
        }
      />

      {error ? <Alert tone="err">{`Could not load the executive rollup: ${error.message}`}</Alert> : null}
      {!error && !r ? <Alert tone="err">The executive rollup returned nothing for this programme.</Alert> : null}

      {r ? (
        <>
          {/* FR-EXE-01 headline row — RAG, week/phase, register progress */}
          <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', marginBottom: 20 }}>
            <Card title="Overall" pad={20} style={{ flex: '1 1 240px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
                <RagBadge rag={r.rag} />
                <WeekBadge week={r.week} total={r.total_weeks} />
              </div>
              <div className="muted" style={{ marginTop: 10 }}>
                {r.phase ?? 'No phase for this week'} · {r.status}
              </div>
            </Card>
            <Card title="Findings (remediation register)" pad={20} style={{ flex: '2 1 320px' }}>
              <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
                <Figure n={openFindings} label="Open findings" tone={openFindings ? 'var(--warn)' : 'var(--pass)'}
                  sub={`${r.register.closed} closed`} />
                <Figure n={r.register.open_high} label="High" tone={r.register.open_high ? 'var(--fail)' : undefined} />
                <Figure n={r.register.open_medium} label="Medium" />
                <Figure n={r.register.open_low} label="Low" />
                <Figure n={r.register.overdue} label="Past planned close"
                  tone={r.register.overdue ? 'var(--fail)' : undefined} />
              </div>
            </Card>
            <Card title="Latest issued report" pad={20} style={{ flex: '1 1 240px' }}>
              {r.latest_report ? (
                <>
                  <div className="mono" style={{ fontSize: 16 }}>{r.latest_report.reference ?? r.latest_report.period}</div>
                  <div className="muted" style={{ margin: '6px 0' }}>
                    {r.latest_report.period} · issued {fmtDay(r.latest_report.issued_on)}{' '}
                    {r.latest_report.overall_rag ? <>· <RagBadge rag={r.latest_report.overall_rag} /></> : null}
                  </div>
                  <Link href={`/programmes/${id}/reports/${r.latest_report.id}`}>Open report →</Link>
                </>
              ) : (
                <EmptyState icon="file-text" message="No report issued yet — the first monthly report lands after month-end close." />
              )}
            </Card>
          </div>

          <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'flex-start' }}>
            {/* activities + milestones */}
            <Card title="Delivery" pad={20} style={{ flex: '1 1 320px' }}>
              <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', marginBottom: 14 }}>
                <Figure n={`${r.activities.complete}/${r.activities.total}`} label="Activities complete" />
                <Figure n={r.activities.overdue} label="Activities overdue"
                  tone={r.activities.overdue ? 'var(--fail)' : undefined} />
              </div>
              <div className="muted" style={{ marginBottom: 8 }}>Milestones</div>
              {r.milestones.length ? (
                <table className="sp-table">
                  <tbody>
                    {r.milestones.map((m) => (
                      <tr key={m.id}>
                        <td className="mono" style={{ whiteSpace: 'nowrap' }}>{m.ref}</td>
                        <td>{m.text}</td>
                        <td><StatusPill status={m.status} /></td>
                        <td className="muted" style={{ whiteSpace: 'nowrap' }}>{fmtDay(m.due_date)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              ) : (
                <EmptyState icon="milestone" message="No open milestones." />
              )}
            </Card>

            {/* open decisions + RAID */}
            <Card title="Decisions & RAID" pad={20} style={{ flex: '1 1 320px' }}
              action={<Badge tone={r.raid.due_for_review ? 'warn' : 'neutral'}>{r.raid.open} open</Badge>}
            >
              {r.raid.due_for_review ? (
                <Alert tone="info">{`${r.raid.due_for_review} open RAID item${r.raid.due_for_review === 1 ? '' : 's'} due for review.`}</Alert>
              ) : null}
              {r.decisions.length ? (
                <>
                  <div className="muted" style={{ margin: '10px 0 8px' }}>Latest decisions</div>
                  <table className="sp-table">
                    <tbody>
                      {r.decisions.map((d, i) => (
                        <tr key={i}>
                          <td>{d.outcome}</td>
                          <td className="muted" style={{ whiteSpace: 'nowrap' }}>{fmtDay(d.decided_on)}</td>
                          <td className="mono muted" style={{ whiteSpace: 'nowrap' }}>{d.minute_ref ?? '—'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </>
              ) : (
                <EmptyState icon="scale" message="No decisions recorded yet." />
              )}
            </Card>
          </div>

          <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'flex-start', marginTop: 16 }}>
            {/* evidence acceptance */}
            <Card title="Evidence" pad={20} style={{ flex: '1 1 320px' }}>
              <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
                <Figure
                  n={r.evidence.acceptance_rate == null ? '—' : `${Math.round(r.evidence.acceptance_rate * 100)}%`}
                  label="Acceptance rate"
                  sub={`${r.evidence.accepted} accepted · ${r.evidence.returned} returned`}
                />
                <Figure n={r.evidence.awaiting_verification} label="Awaiting verification" />
                <Figure n={r.evidence.awaiting_acceptance} label="Awaiting AO decision"
                  tone={r.evidence.awaiting_acceptance ? 'var(--warn)' : undefined} />
              </div>
            </Card>

            {/* maintenance posture */}
            <Card title="Maintenance posture" pad={20} style={{ flex: '1 1 320px' }}
              action={<Badge tone="accent">{r.maintenance.period}</Badge>}
            >
              <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
                <Figure n={r.maintenance.done} label="Done this period" tone="var(--pass)" />
                <Figure n={r.maintenance.open} label="Open this period" />
                <Figure n={r.maintenance.overdue_all} label="Overdue (all periods)"
                  tone={r.maintenance.overdue_all ? 'var(--fail)' : undefined} />
              </div>
            </Card>
          </div>

          <p className="muted" style={{ marginTop: 16 }}>
            Read-only — the board sees the same engine figures the programme team works to;
            nothing on this page changes any data.
          </p>
        </>
      ) : null}
    </>
  );
}
