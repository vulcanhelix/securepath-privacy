import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { EmptyState } from '@/components/ui/EmptyState';
import { RagBadge } from '@/components/ui/RagBadge';
import { Badge } from '@/components/ui/Badge';
import { StatusPill } from '@/components/ui/StatusPill';
import { Alert } from '@/components/ui/Alert';

export const dynamic = 'force-dynamic';

// W2-13 — "My actions" (spec §8.15 FR-MOB-01): the phone-first list of what
// the logged-in user must do on this programme. Everything comes from the
// my_actions definer RPC (migration 20261106000022) — week, queues and
// completable-item rules are decided server-side; this page renders links to
// the screens where each action happens. It writes nothing itself: any write
// goes through the existing RPCs on the target screen.

interface ActionActivity {
  id: string; ref: string; text: string; status: string; rag: string | null;
  end_week: number; due_date: string | null; overdue: boolean; due_this_week: boolean;
}
interface QueueItem {
  id: string; activity_ref: string | null; register_ref: string | null;
  site: string | null; file_key: string | null; link: string | null;
  note: string | null; uploaded_by: string | null; uploaded_at: string;
  requires_alternate?: boolean;
}
interface MaintTask {
  id: string; code: string; task: string; period: string;
  due_date: string | null; task_window: string | null; status: string; overdue: boolean;
}
interface ChecklistAction {
  checklist_id: string; kind: string; period: string;
  item_ref: string; label: string | null; evidence_required: boolean;
}
interface MyActions {
  week: number | null;
  activities: ActionActivity[];
  evidence: {
    can_verify: boolean; is_ao_or_alternate: boolean;
    verify: QueueItem[]; accept: QueueItem[];
  };
  maintenance: MaintTask[];
  can_complete_checklists: boolean;
  checklists: ChecklistAction[];
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function fmtDay(d?: string | null) {
  if (!d) return '—';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d);
  return m ? `${Number(m[3])} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : d;
}

function fileLabel(it: QueueItem) {
  const f = it.file_key?.split('/').pop();
  return f ?? it.link ?? 'evidence item';
}

function Section({
  title, n, href, children, empty,
}: {
  title: string; n: number; href: string; children: React.ReactNode; empty: string;
}) {
  return (
    <Card
      title={title}
      pad={0}
      style={{ marginBottom: 16 }}
      action={<Badge tone={n ? 'accent' : 'neutral'}>{n}</Badge>}
    >
      {n ? (
        <div>
          {children}
          <div style={{ padding: '10px 28px' }}>
            <Link href={href} className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
              open →
            </Link>
          </div>
        </div>
      ) : (
        <div style={{ padding: '4px 28px 22px' }}>
          <EmptyState icon="check" message={empty} />
        </div>
      )}
    </Card>
  );
}

function Row({ href, children }: { href: string; children: React.ReactNode }) {
  return (
    <Link
      href={href}
      style={{
        display: 'flex', gap: 10, alignItems: 'flex-start', justifyContent: 'space-between',
        padding: '12px 28px', borderTop: '1px solid var(--border)', textDecoration: 'none',
        color: 'inherit', minHeight: 44, // phone tap target
      }}
    >
      {children}
    </Link>
  );
}

export default async function MyActionsPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const { data, error } = await supabase.rpc('my_actions', { p_programme: id });
  const a = (data ?? null) as MyActions | null;
  const base = `/programmes/${id}`;

  const total =
    (a?.activities.length ?? 0) +
    (a?.evidence.verify.length ?? 0) +
    (a?.evidence.accept.length ?? 0) +
    (a?.maintenance.length ?? 0) +
    (a?.checklists.length ?? 0);

  return (
    <>
      <PageHeader
        title="My actions"
        eyebrow={`${ctx.client.name} · ${ctx.programme.name}`}
        meta={
          <>
            {a?.week != null ? `week ${a.week} · ` : ''}
            {total} open action{total === 1 ? '' : 's'} for you
          </>
        }
      />

      {error ? <Alert tone="err">{`Could not load your actions: ${error.message}`}</Alert> : null}

      {a ? (
        <>
          <Section
            title="Activities you lead"
            n={a.activities.length}
            href={`${base}/schedule`}
            empty="Nothing you lead is due this week or overdue."
          >
            {a.activities.map((t) => (
              <Row key={t.id} href={`${base}/schedule`}>
                <span>
                  <span className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{t.ref}</span>{' '}
                  {t.text}
                  <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>
                    due {fmtDay(t.due_date)} (week {t.end_week}) · {t.status}
                  </span>
                </span>
                <span style={{ display: 'inline-flex', gap: 6, flexShrink: 0 }}>
                  {t.overdue ? <Badge tone="fail" dot>Overdue</Badge> : null}
                  <RagBadge rag={t.rag} />
                </span>
              </Row>
            ))}
          </Section>

          <Section
            title="Evidence to verify"
            n={a.evidence.verify.length}
            href={`${base}/evidence`}
            empty="Nothing waiting for your verification."
          >
            {a.evidence.verify.map((e) => (
              <Row key={e.id} href={`${base}/evidence/${e.id}`}>
                <span>
                  {fileLabel(e)}
                  <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>
                    {[e.activity_ref, e.register_ref].filter(Boolean).join(' · ') || 'unlinked'}
                    {e.site ? ` · ${e.site}` : ''} · uploaded {fmtDay(e.uploaded_at)}
                  </span>
                </span>
                <Badge tone="accent" dot>Verify</Badge>
              </Row>
            ))}
          </Section>

          {a.evidence.is_ao_or_alternate ? (
            <Section
              title="Evidence awaiting your decision"
              n={a.evidence.accept.length}
              href={`${base}/evidence`}
              empty="Nothing waiting for your acceptance decision."
            >
              {a.evidence.accept.map((e) => (
                <Row key={e.id} href={`${base}/evidence/${e.id}`}>
                  <span>
                    {fileLabel(e)}
                    <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>
                      {[e.activity_ref, e.register_ref].filter(Boolean).join(' · ') || 'unlinked'}
                      {e.site ? ` · ${e.site}` : ''} · uploaded {fmtDay(e.uploaded_at)}
                      {e.requires_alternate ? ' · named alternate decides' : ''}
                    </span>
                  </span>
                  <Badge tone="warn" dot>Accept / return</Badge>
                </Row>
              ))}
            </Section>
          ) : null}

          <Section
            title="Maintenance tasks assigned to you"
            n={a.maintenance.length}
            href={`${base}/maintenance`}
            empty="No open maintenance task is assigned to you."
          >
            {a.maintenance.map((t) => (
              <Row key={t.id} href={`${base}/maintenance`}>
                <span>
                  <span className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{t.code}</span>{' '}
                  {t.task}
                  <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>
                    {t.period}
                    {t.due_date ? ` · due ${fmtDay(t.due_date)}` : ''}
                    {t.task_window ? ` · ${t.task_window.replace(/_/g, ' ')}` : ''}
                  </span>
                </span>
                <span style={{ display: 'inline-flex', gap: 6, flexShrink: 0 }}>
                  {t.overdue ? <Badge tone="fail" dot>Overdue</Badge> : null}
                  <StatusPill status={t.status} />
                </span>
              </Row>
            ))}
          </Section>

          <Section
            title="Checklist items"
            n={a.checklists.length}
            href={`${base}/maintenance`}
            empty={
              a.can_complete_checklists
                ? 'No open checklist items.'
                : 'Checklist completion needs a programme write role or the accountable officer.'
            }
          >
            {a.checklists.map((c) => (
              <Row key={`${c.checklist_id}-${c.item_ref}`} href={`${base}/maintenance`}>
                <span>
                  <span className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{c.item_ref}</span>{' '}
                  {c.label ?? c.item_ref}
                  <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>
                    {c.kind} {c.period}
                    {c.evidence_required ? ' · evidence slot' : ''}
                  </span>
                </span>
                <Badge tone="neutral" dot>Open</Badge>
              </Row>
            ))}
          </Section>
        </>
      ) : null}
    </>
  );
}
