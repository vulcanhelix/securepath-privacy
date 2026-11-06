import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { EmptyState } from '@/components/ui/EmptyState';
import { EvidenceChip } from '@/components/ui/EvidenceChip';
import { Badge } from '@/components/ui/Badge';
import { Icon } from '@/components/ui/Icon';
import { ReviewCard, type QueueItem } from '../ReviewQueue';

export const dynamic = 'force-dynamic';

// W2-06 — evidence detail (spec §8.4 screen 03: submitted file, decisions and
// audit trail). Decided/returned rows are immutable (NFR-09) — this page is
// read-only for them. Pending items still render the review actions when the
// caller is eligible (the RPCs re-check every gate).

type EvidenceRow = {
  id: string;
  programme_id: string;
  activity_id: string | null;
  register_item_id: string | null;
  site: string | null;
  file_key: string | null;
  link: string | null;
  note: string | null;
  uploaded_by: string;
  uploaded_at: string;
  review_stage: string;
  outcome: string | null;
  evidence_ref: string | null;
  supersedes: string | null;
  source_evidence_id: string | null;
};

type ReviewRow = {
  id: string;
  stage: string;
  reviewer: string;
  decision: string;
  reasons: string[];
  decided_at: string;
};

export default async function EvidenceDetailPage({
  params,
}: {
  params: Promise<{ id: string; evidenceId: string }>;
}) {
  const { id, evidenceId } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();
  const base = `/programmes/${id}`;

  const { data: ev } = await supabase
    .from('evidence_items')
    .select(
      'id, programme_id, activity_id, register_item_id, site, file_key, link, note, uploaded_by, uploaded_at, review_stage, outcome, evidence_ref, supersedes, source_evidence_id'
    )
    .eq('id', evidenceId)
    .eq('programme_id', id)
    .maybeSingle();
  if (!ev) notFound(); // absent or RLS-invisible — same answer
  const item = ev as EvidenceRow;

  const [{ data: reviews }, { data: versions }, { data: pendingRaw }, { data: activity }, { data: registerItem }] =
    await Promise.all([
      supabase
        .from('evidence_reviews')
        .select('id, stage, reviewer, decision, reasons, decided_at')
        .eq('evidence_item_id', evidenceId)
        .order('decided_at'),
      // NFR-09 version chain: rows superseding this one
      supabase
        .from('evidence_items')
        .select('id, uploaded_at, review_stage, evidence_ref')
        .eq('supersedes', evidenceId),
      supabase.rpc('list_pending_reviews', { p_programme_id: id }),
      item.activity_id
        ? supabase.from('activities').select('id, ref, text').eq('id', item.activity_id).maybeSingle()
        : Promise.resolve({ data: null }),
      item.register_item_id
        ? supabase.from('register_items').select('id, ref, finding').eq('id', item.register_item_id).maybeSingle()
        : Promise.resolve({ data: null }),
    ]);

  // actor display names (users_read scopes what the caller may see)
  const actorIds = [...new Set(
    [item.uploaded_by, ...(reviews ?? []).map((r) => r.reviewer)].filter(Boolean) as string[]
  )];
  const { data: users } = actorIds.length
    ? await supabase.from('users').select('id, full_name, email').in('id', actorIds)
    : { data: [] as { id: string; full_name: string | null; email: string }[] };
  const names = Object.fromEntries(
    (users ?? []).map((u) => [u.id as string, (u.full_name as string) || (u.email as string)])
  );
  const nameOf = (uid: string | null) => (uid ? names[uid] ?? '—' : '—');

  const pending = (pendingRaw ?? {}) as {
    verify?: QueueItem[];
    accept?: QueueItem[];
    caller_can_verify?: boolean;
    caller_is_ao_or_alternate?: boolean;
  };
  const queueItem =
    pending.verify?.find((q) => q.id === evidenceId) ??
    pending.accept?.find((q) => q.id === evidenceId);
  const stage = item.review_stage;
  const decided = stage === 'decided' || stage === 'returned';
  // caller is eligible only when the RPC's own flags say so AND the item is
  // in the caller's queue (the RPC already excludes the caller's own uploads —
  // self-review is never offered, and verify/accept reject it anyway)
  const canAct =
    !decided &&
    !!queueItem &&
    (stage === 'verification' ? !!pending.caller_can_verify : !!pending.caller_is_ao_or_alternate);

  const STAGE_LABEL: Record<string, string> = { verify: 'Verification', accept: 'Acceptance' };
  const DECISION_TONE: Record<string, 'pass' | 'fail' | 'accent'> = {
    verified: 'accent',
    accepted: 'pass',
    returned: 'fail',
  };

  return (
    <>
      <PageHeader
        title={item.evidence_ref ?? 'Evidence item'}
        eyebrow={ctx.programme.name}
        back="Evidence"
        backHref={`${base}/evidence`}
        meta={`uploaded ${new Date(item.uploaded_at).toLocaleString()} by ${nameOf(item.uploaded_by)}`}
        actions={
          stage === 'returned' ? (
            <Badge tone="fail" dot>Returned</Badge>
          ) : (
            <EvidenceChip stage={stage} outcome={item.outcome} evidenceRef={null} />
          )
        }
      />

      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'flex-start' }}>
        <Card title="Item" pad={24} style={{ flex: '1 1 320px', marginBottom: 0 }}>
          <dl style={{ margin: 0, display: 'grid', gridTemplateColumns: 'auto 1fr', gap: '10px 18px', fontSize: 'var(--fs-sm)' }}>
            <dt className="muted">Status</dt>
            <dd style={{ margin: 0 }}>
              {stage === 'returned' ? (
                <Badge tone="fail" dot>Returned</Badge>
              ) : (
                <EvidenceChip stage={stage} outcome={item.outcome} />
              )}
            </dd>
            {item.evidence_ref ? (
              <>
                <dt className="muted">Evidence ref</dt>
                <dd style={{ margin: 0 }}><span className="mono">{item.evidence_ref}</span></dd>
              </>
            ) : null}
            {activity ? (
              <>
                <dt className="muted">Activity</dt>
                <dd style={{ margin: 0 }}>
                  <Badge tone="accent" dot>{activity.ref}</Badge>{' '}
                  <span className="muted">{activity.text}</span>
                </dd>
              </>
            ) : null}
            {registerItem ? (
              <>
                <dt className="muted">Register item</dt>
                <dd style={{ margin: 0 }}>
                  <Badge tone="warn" dot>{registerItem.ref}</Badge>{' '}
                  <span className="muted">{registerItem.finding}</span>
                </dd>
              </>
            ) : null}
            {item.site ? (
              <>
                <dt className="muted">Site</dt>
                <dd style={{ margin: 0 }}>{item.site}</dd>
              </>
            ) : null}
            {item.note ? (
              <>
                <dt className="muted">Note</dt>
                <dd style={{ margin: 0 }}>{item.note}</dd>
              </>
            ) : null}
            {item.file_key ? (
              <>
                <dt className="muted">File</dt>
                <dd style={{ margin: 0 }}>
                  <a href={`/api/evidence/${item.id}`} style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                    <Icon name="download" size={14} /> Download
                  </a>
                </dd>
              </>
            ) : null}
            {item.link ? (
              <>
                <dt className="muted">Link</dt>
                <dd style={{ margin: 0 }}>
                  <a href={item.link} target="_blank" rel="noreferrer" style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                    <Icon name="external-link" size={14} /> {item.link}
                  </a>
                </dd>
              </>
            ) : null}
            {item.source_evidence_id ? (
              <>
                <dt className="muted">Provenance</dt>
                <dd style={{ margin: 0 }} className="muted">
                  accepted evidence offered from another programme (FR-TPL-07)
                </dd>
              </>
            ) : null}
          </dl>
        </Card>

        <Card title="Review history" pad={24} style={{ flex: '1 1 320px', marginBottom: 0 }}>
          {reviews?.length ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              {(reviews as ReviewRow[]).map((r) => (
                <div key={r.id} style={{ borderLeft: '2px solid var(--border)', paddingLeft: 14 }}>
                  <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                    <Badge tone={DECISION_TONE[r.decision] ?? 'neutral'} dot>{r.decision}</Badge>
                    <span className="muted">{STAGE_LABEL[r.stage] ?? r.stage}</span>
                    <span className="muted">{nameOf(r.reviewer)} · {new Date(r.decided_at).toLocaleString()}</span>
                  </div>
                  {r.reasons?.length ? (
                    <ul style={{ margin: '6px 0 0', paddingLeft: 18, fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
                      {r.reasons.map((reason, i) => <li key={i}>{reason}</li>)}
                    </ul>
                  ) : null}
                </div>
              ))}
            </div>
          ) : (
            <EmptyState icon="history" message="No review decisions yet." />
          )}
        </Card>
      </div>

      {/* version chain — corrections are new rows, never edits */}
      {item.supersedes || versions?.length ? (
        <Card title="Versions" pad={20} style={{ marginTop: 16 }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, fontSize: 'var(--fs-sm)' }}>
            {item.supersedes ? (
              <div>
                Supersedes{' '}
                <Link href={`${base}/evidence/${item.supersedes}`}>an earlier version</Link>
              </div>
            ) : null}
            {(versions ?? []).map((v) => (
              <div key={v.id}>
                Superseded by{' '}
                <Link href={`${base}/evidence/${v.id}`}>
                  {v.evidence_ref ?? `version uploaded ${new Date(v.uploaded_at as string).toLocaleDateString()}`}
                </Link>{' '}
                <StatusText stage={v.review_stage as string} />
              </div>
            ))}
          </div>
        </Card>
      ) : null}

      {/* pending → the review panel; returned → path to a corrected version */}
      {!decided ? (
        <Card title="Review" pad={20} style={{ marginTop: 16 }}>
          {queueItem && canAct ? (
            <ReviewCard
              item={queueItem}
              mode={stage === 'verification' ? 'verify' : 'accept'}
              canAct
              uploaderName={nameOf(item.uploaded_by)}
              base={base}
            />
          ) : queueItem ? (
            <p className="muted" style={{ margin: 0 }}>
              {stage === 'verification'
                ? 'Awaiting verification — only the programme lead or partner consultant verifies (FR-EVD-03).'
                : 'Awaiting the accountable officer — only the AO or a named alternate accepts (FR-ACC-02).'}
            </p>
          ) : (
            <p className="muted" style={{ margin: 0 }}>
              Not in your review queue — items you uploaded yourself can never be self-reviewed (FR-ACC-01).
            </p>
          )}
        </Card>
      ) : null}

      {stage === 'returned' ? (
        <div style={{ marginTop: 16 }}>
          <Link
            href={`${base}/evidence?supersedes=${item.id}${item.activity_id ? `&activity=${item.activity_id}` : ''}${item.register_item_id ? `&register=${item.register_item_id}` : ''}`}
            className="sp-btn sp-btn--secondary sp-btn--sm"
          >
            <span>Upload a corrected version →</span>
          </Link>
        </div>
      ) : null}
    </>
  );
}

function StatusText({ stage }: { stage: string }) {
  return <span className="muted">({stage})</span>;
}
