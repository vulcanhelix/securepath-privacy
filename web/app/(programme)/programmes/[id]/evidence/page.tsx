import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { EmptyState } from '@/components/ui/EmptyState';
import { Alert } from '@/components/ui/Alert';
import { EvidenceChip } from '@/components/ui/EvidenceChip';
import { Badge } from '@/components/ui/Badge';
import { ReviewQueue, type QueueItem } from './ReviewQueue';
import { EvidenceUpload } from './EvidenceUpload';

export const dynamic = 'force-dynamic';

// W2-06 — evidence review + capture (spec §8.4, screens 03 and 08;
// FR-EVD-01..07, FR-ACC-02). Queues come from list_pending_reviews — its own
// flags (caller_can_verify, caller_is_ao_or_alternate) gate the action UI;
// nothing here re-implements those rules.

type Pending = {
  verify: QueueItem[];
  accept: QueueItem[];
  caller_can_verify: boolean;
  caller_is_ao_or_alternate: boolean;
};

type LibraryItem = {
  id: string;
  activity_ref: string | null;
  register_ref: string | null;
  site: string | null;
  file_key: string | null;
  link: string | null;
  note: string | null;
  uploaded_by: string | null;
  uploaded_at: string;
  review_stage: string;
  outcome: string | null;
  evidence_ref: string | null;
};

export default async function EvidencePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);

  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const base = `/programmes/${id}`;

  const [{ data: pendingRaw, error: queueErr }, { data: activities }, { data: registerItems }] =
    await Promise.all([
      supabase.rpc('list_pending_reviews', { p_programme_id: id }),
      supabase
        .from('activities')
        .select('id, ref, text, status, active')
        .eq('programme_id', id)
        .order('ref'),
      supabase
        .from('register_items')
        .select('id, ref, finding, status, active')
        .eq('programme_id', id)
        .order('ref'),
    ]);

  const pending = (pendingRaw ?? { verify: [], accept: [] }) as Partial<Pending>;
  const verifyQueue = (pending.verify ?? []) as QueueItem[];
  const acceptQueue = (pending.accept ?? []) as QueueItem[];
  const canVerify = !!pending.caller_can_verify;
  const isAo = !!pending.caller_is_ao_or_alternate;

  // decided + returned rows are immutable evidence (NFR-09) — the library view
  const { data: libraryRaw } = await supabase
    .from('evidence_items')
    .select(
      'id, site, file_key, link, note, uploaded_by, uploaded_at, review_stage, outcome, evidence_ref, activity_id, register_item_id'
    )
    .eq('programme_id', id)
    .in('review_stage', ['decided', 'returned'])
    .order('uploaded_at', { ascending: false })
    .limit(100);

  // #92: the library is history, so evidence filed against a since-retired
  // activity/finding keeps its ref, marked "(retired)". The capture form
  // below only offers live (active) targets.
  const refOf = (row: { ref: unknown; active: unknown }) =>
    row.active === false ? `${row.ref as string} (retired)` : (row.ref as string);
  const actRef = new Map((activities ?? []).map((a) => [a.id as string, refOf(a)]));
  const regRef = new Map((registerItems ?? []).map((r) => [r.id as string, refOf(r)]));
  const library: LibraryItem[] = (libraryRaw ?? []).map((e) => ({
    ...(e as Record<string, unknown>),
    activity_ref: (actRef.get(e.activity_id as string) ?? null) as string | null,
    register_ref: (regRef.get(e.register_item_id as string) ?? null) as string | null,
  })) as unknown as LibraryItem[];

  // uploader display names — users_read only returns rows the caller may see;
  // anything RLS-hidden falls back to a muted dash
  const uploaderIds = [
    ...new Set(
      [...verifyQueue, ...acceptQueue, ...library]
        .map((e) => e.uploaded_by)
        .filter(Boolean) as string[]
    ),
  ];
  const { data: users } = uploaderIds.length
    ? await supabase.from('users').select('id, full_name, email').in('id', uploaderIds)
    : { data: [] as { id: string; full_name: string | null; email: string }[] };
  const names = Object.fromEntries(
    (users ?? []).map((u) => [u.id as string, (u.full_name as string) || (u.email as string)])
  );

  const awaitingCount = verifyQueue.length + (isAo ? acceptQueue.length : 0);

  return (
    <>
      <PageHeader
        title="Evidence"
        eyebrow={ctx.programme.name}
        meta={`${awaitingCount} awaiting review · ${library.length} on file`}
      />

      {queueErr ? <Alert tone="err">{`Could not load the review queues: ${queueErr.message}`}</Alert> : null}

      {/* ------- screen 03 — the review queues ------- */}
      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'flex-start' }}>
        <Card
          title="To verify"
          pad={20}
          style={{ flex: '1 1 340px', marginBottom: 0 }}
          action={<Badge tone="accent">{verifyQueue.length}</Badge>}
        >
          {verifyQueue.length ? (
            <ReviewQueue items={verifyQueue} mode="verify" canAct={canVerify} names={names} base={base} />
          ) : (
            <EmptyState
              icon="check"
              message={
                canVerify
                  ? 'Nothing waiting for verification.'
                  : 'Nothing in verification — only the programme lead or partner consultant verifies evidence (FR-EVD-03).'
              }
            />
          )}
        </Card>

        {/* FR-ACC-02 — the AO queue renders only when the RPC says the
            caller is the AO or a named alternate; never re-derived here */}
        {isAo ? (
          <Card
            title="To accept"
            pad={20}
            style={{ flex: '1 1 340px', marginBottom: 0 }}
            action={<Badge tone="warn">{acceptQueue.length}</Badge>}
          >
            {acceptQueue.length ? (
              <ReviewQueue items={acceptQueue} mode="accept" canAct names={names} base={base} />
            ) : (
              <EmptyState icon="badge-check" message="Nothing waiting for your decision." />
            )}
          </Card>
        ) : null}
      </div>

      {/* ------- screen 08 — capture ------- */}
      <Card title="Submit evidence" pad={24} style={{ marginTop: 16 }}>
        <EvidenceUpload
          programmeId={id}
          activities={(activities ?? []).filter((a) => a.active !== false).map((a) => ({
            id: a.id as string,
            ref: a.ref as string,
            label: a.text as string,
            status: (a.status as string) ?? null,
          }))}
          registerItems={(registerItems ?? []).filter((r) => r.active !== false).map((r) => ({
            id: r.id as string,
            ref: r.ref as string,
            label: r.finding as string,
            status: (r.status as string) ?? null,
          }))}
          prefill={{
            activityId: first(sp.activity),
            registerItemId: first(sp.register),
            supersedes: first(sp.supersedes),
          }}
        />
      </Card>

      {/* ------- library — decided + returned are immutable (NFR-09) ------- */}
      <Card title="Library" pad={0} style={{ marginTop: 16 }}>
        {library.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Ref</th>
                  <th>For</th>
                  <th>Site</th>
                  <th>Uploaded</th>
                  <th>Status</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {library.map((e) => (
                  <tr key={e.id}>
                    <td>
                      {e.evidence_ref ? (
                        <span className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{e.evidence_ref}</span>
                      ) : (
                        <span className="muted">—</span>
                      )}
                    </td>
                    <td>
                      {[e.activity_ref, e.register_ref].filter(Boolean).join(' · ') || (
                        <span className="muted">—</span>
                      )}
                    </td>
                    <td className="muted">{e.site ?? '—'}</td>
                    <td className="muted">
                      {names[e.uploaded_by ?? ''] ? `${names[e.uploaded_by!]} · ` : ''}
                      {new Date(e.uploaded_at).toLocaleDateString()}
                    </td>
                    <td>
                      {e.review_stage === 'returned' ? (
                        <Badge tone="fail" dot>Returned</Badge>
                      ) : (
                        <EvidenceChip stage={e.review_stage} outcome={e.outcome} />
                      )}
                    </td>
                    <td>
                      <Link href={`${base}/evidence/${e.id}`} style={{ whiteSpace: 'nowrap' }}>
                        Detail →
                      </Link>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState
            icon="file-check-2"
            message="No decided or returned evidence yet — accepted items and their EV refs land here."
          />
        )}
      </Card>
      <p className="muted" style={{ marginTop: 8 }}>
        Decided and returned evidence is immutable — corrections are new versions (NFR-09).
      </p>
    </>
  );
}
