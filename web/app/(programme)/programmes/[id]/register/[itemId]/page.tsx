import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { EmptyState } from '@/components/ui/EmptyState';
import { EvidenceChip } from '@/components/ui/EvidenceChip';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { loadEngineValues, loadRegisterItems } from '../register-data';
import { PRIORITY_TONE, WRITE_ROLES, type RegisterEvidence } from '../types';
import type { ScheduleActivity, ScheduleWorkstream } from '../../schedule/types';
import { CloseItem } from './CloseItem';
import { ItemActivities } from './ItemActivities';

export const dynamic = 'force-dynamic';

// ---------------------------------------------------------------------------
// W2-16 — register item detail (FR-REG-01/02, §9.4).
//  * linked activities + their status; linked evidence + review stage
//  * closure readiness = can_close_register_item's answer, shown verbatim
//    BEFORE any close attempt (never derived in the browser)
//  * Close (close_register_item) renders only when is_ao_or_alternate is true;
//    the RPC re-checks authz + data and its refusal is surfaced as-is
//  * FR-TPL-04 activity editing (update_activity / add_activity) for partner
//    write roles; schedule-level edits link to the schedule screen
// ---------------------------------------------------------------------------

const ACTIVITY_COLS =
  'id, ref, text, workstream_id, phase, start_week, end_week, milestone, ' +
  'evidence_required, status, pct_complete, actual_completion, flag, comments, ' +
  'recovery_date, dependency_override_reason, rescheduled_date, start_date, ' +
  'due_date, month, rag, leads, active';

export default async function RegisterItemPage({
  params,
}: {
  params: Promise<{ id: string; itemId: string }>;
}) {
  const { id, itemId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(itemId)) notFound();
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();
  const base = `/programmes/${id}`;

  // #92: a retired finding stays reachable here as history (marked retired)
  const { items, error } = await loadRegisterItems(supabase, id, itemId, { includeRetired: true });
  const item = items[0];
  if (!item) {
    if (error) {
      return (
        <>
          <PageHeader title="Register item" backHref={`${base}/register`} back="Register" />
          <Alert tone="err">{`Could not load the register item: ${error}`}</Alert>
        </>
      );
    }
    notFound();
  }

  const [
    { data: links },
    readinessRes,
    { data: isAo },
    { data: canWrite },
    engine,
    { data: workstreams },
    { data: allActivities },
    { data: prog },
  ] = await Promise.all([
    supabase.from('register_item_activities').select('activity_id').eq('register_item_id', itemId),
    // §9.4 data preconditions — authoritative readiness answer
    supabase.rpc('can_close_register_item', { p_item: itemId }),
    // T5 gate mirror — decides whether Close renders at all
    supabase.rpc('is_ao_or_alternate', { p_client_org: ctx.client.id }),
    // W1-05 write gate mirror — decides whether the activity editor renders
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: WRITE_ROLES }),
    loadEngineValues(supabase, [item]),
    supabase.from('workstreams').select('id, name, accountable_lead').eq('programme_id', id).order('name'),
    supabase.from('activities').select(ACTIVITY_COLS).eq('programme_id', id).order('start_week').order('ref'),
    supabase.from('programmes').select('total_weeks').eq('id', id).single(),
  ]);

  const linkedIds = new Set((links ?? []).map((l) => l.activity_id as string));
  // #92: retired activities (FR-TPL-04) are frozen and out of the §9.4 leg, so
  // the editor/link list only gets live rows; retired links are listed as
  // history below, and evidence filed through them keeps a marked ref.
  const everyAct = (allActivities ?? []) as unknown as (ScheduleActivity & { active?: boolean })[];
  const acts = everyAct.filter((a) => a.active !== false);
  const linked = acts.filter((a) => linkedIds.has(a.id));
  const retiredLinked = everyAct.filter((a) => a.active === false && linkedIds.has(a.id));
  const retired = item.active === false;

  // evidence directly on the item + evidence on its linked activities
  const evQueries = [
    supabase
      .from('evidence_items')
      .select('id, activity_id, register_item_id, review_stage, outcome, evidence_ref, uploaded_at')
      .eq('register_item_id', itemId),
  ];
  if (linkedIds.size) {
    evQueries.push(
      supabase
        .from('evidence_items')
        .select('id, activity_id, register_item_id, review_stage, outcome, evidence_ref, uploaded_at')
        .in('activity_id', [...linkedIds])
    );
  }
  const evRes = await Promise.all(evQueries);
  const evMap = new Map<string, RegisterEvidence>();
  for (const r of evRes) for (const e of (r.data ?? []) as RegisterEvidence[]) evMap.set(e.id, e);
  const evidence = [...evMap.values()].sort((a, b) => b.uploaded_at.localeCompare(a.uploaded_at));
  const actRef = new Map(
    everyAct.map((a) => [a.id, a.active === false ? `${a.ref} (retired)` : a.ref])
  );

  const readinessRow = Array.isArray(readinessRes.data)
    ? (readinessRes.data[0] as { can_close: boolean; reason: string } | undefined)
    : (readinessRes.data as { can_close: boolean; reason: string } | null);
  const readiness = readinessRes.error
    ? { can_close: null as boolean | null, reason: `can_close_register_item unavailable: ${readinessRes.error.message}` }
    : readinessRow
      ? { can_close: readinessRow.can_close as boolean | null, reason: readinessRow.reason }
      : { can_close: null as boolean | null, reason: 'no readiness answer returned' };

  // people: lead + acceptor + activity leads the caller may resolve
  const personIds = [
    ...new Set(
      [
        item.lead,
        item.accepted_by,
        ...acts.flatMap((a) => a.leads ?? []),
        ...(workstreams ?? []).map((w) => w.accountable_lead as string | null),
      ].filter(Boolean)
    ),
  ] as string[];
  const { data: users } = personIds.length
    ? await supabase.from('users').select('id, full_name, email').in('id', personIds)
    : { data: [] as { id: string; full_name: string | null; email: string }[] };
  const leadNames = Object.fromEntries(
    (users ?? []).map((u) => [u.id as string, (u.full_name as string) || (u.email as string)])
  );
  const who = (uid: string | null) => (uid ? leadNames[uid] ?? `user ${uid.slice(0, 8)}` : '—');

  const rag = engine[item.id]?.rag ?? null;
  const daysOverdue = engine[item.id]?.daysOverdue ?? null;
  const closed = item.status === 'Closed';
  // accepted evidence the AO may cite when stamping the acceptance record
  const acceptedRefs = evidence
    .filter((e) => e.review_stage === 'decided' && e.evidence_ref)
    .map((e) => e.evidence_ref as string);

  return (
    <>
      <PageHeader
        title={
          <>
            <span className="mono">{item.ref}</span> {item.finding}
          </>
        }
        eyebrow={ctx.programme.name}
        backHref={`${base}/register`}
        back="Register"
        meta={
          <span style={{ display: 'inline-flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <Badge tone={PRIORITY_TONE[item.priority] ?? 'neutral'}>{item.priority}</Badge>
            <StatusPill status={item.status} />
            {retired ? <Badge tone="neutral">Retired</Badge> : <RagBadge rag={rag} />}
          </span>
        }
      />

      {retired ? (
        <Alert tone="info">
          {`This finding is retired (FR-TPL-04)${item.retired_reason ? `: ${item.retired_reason}` : ''}. ` +
            'It is kept as history only: it is out of the register rollups and cannot be edited, linked or closed.'}
        </Alert>
      ) : null}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 16, marginBottom: 16 }}>
        <Card title="Finding" pad={20}>
          <dl className="sp-dl" style={{ display: 'grid', gridTemplateColumns: '150px 1fr', gap: '6px 12px', margin: 0 }}>
            <dt className="muted">Lead</dt>
            <dd style={{ margin: 0 }}>{who(item.lead)}</dd>
            <dt className="muted">Planned close</dt>
            <dd style={{ margin: 0 }} className="mono">
              {item.planned_close_date ?? '—'}
              {item.planned_close_week ? <span className="muted"> (week {item.planned_close_week})</span> : null}
            </dd>
            <dt className="muted">Days overdue</dt>
            <dd style={{ margin: 0, color: (daysOverdue ?? 0) > 0 ? 'var(--fail)' : undefined }} className="mono">
              {daysOverdue == null ? '—' : daysOverdue}
            </dd>
            <dt className="muted">Assessment window</dt>
            <dd style={{ margin: 0 }}>{item.assessment_window ?? '—'}</dd>
            <dt className="muted">Provenance</dt>
            <dd style={{ margin: 0 }}>
              {item.source_assessment_session_id ? (
                <>
                  Imported from assessment · question{' '}
                  <span className="mono">{item.source_question_ref ?? '—'}</span>
                  <div className="muted mono" style={{ fontSize: 'var(--fs-xs)' }}>
                    session {item.source_assessment_session_id.slice(0, 8)}
                  </div>
                </>
              ) : (
                'Template / manual'
              )}
            </dd>
            {item.reopen_reason ? (
              <>
                <dt className="muted">Re-open reason</dt>
                <dd style={{ margin: 0 }}>{item.reopen_reason}</dd>
              </>
            ) : null}
          </dl>
        </Card>

        <Card title="Closure (§9.4)" pad={20}>
          {retired ? (
            <Alert tone="info">Retired — not closable (FR-TPL-04).</Alert>
          ) : closed ? (
            <Alert tone="ok">
              {`Closed — accepted ${item.accepted_on ? item.accepted_on.slice(0, 10) : '—'} by ${who(item.accepted_by)}.`}
            </Alert>
          ) : (
            <Alert tone={readiness.can_close ? 'ok' : readiness.can_close === false ? 'err' : 'info'}>
              {readiness.can_close ? 'Ready to close: ' : 'Not ready to close: '}
              {readiness.reason}
            </Alert>
          )}
          <div style={{ marginTop: 10, fontSize: 'var(--fs-sm)' }}>
            <span className="muted">Accepted evidence refs: </span>
            {item.accepted_evidence_refs?.length ? (
              <span className="mono">{item.accepted_evidence_refs.join(', ')}</span>
            ) : (
              <span className="muted">none recorded</span>
            )}
          </div>
          {retired ? null : !closed && isAo === true ? (
            <CloseItem
              itemId={item.id}
              itemRef={item.ref}
              hasAcceptanceRecord={!!item.accepted_evidence_refs?.length}
              acceptedRefs={acceptedRefs}
            />
          ) : !closed ? (
            <p className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 10 }}>
              Only the accountable officer or a named alternate may close a finding. Closure follows an
              accepted evidence decision.
            </p>
          ) : null}
        </Card>
      </div>

      <ItemActivities
        programmeId={id}
        linked={linked}
        allActivities={acts}
        workstreams={(workstreams ?? []) as ScheduleWorkstream[]}
        leadNames={leadNames}
        totalWeeks={(prog?.total_weeks as number | undefined) ?? ctx.programme.total_weeks}
        canWrite={canWrite === true && !retired}
      />
      {retiredLinked.length ? (
        <p className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 8 }}>
          Retired linked activities (out of scope, kept as history):{' '}
          <span className="mono">{retiredLinked.map((a) => a.ref).join(', ')}</span>
        </p>
      ) : null}

      <Card title="Evidence" pad={0} style={{ marginTop: 16 }}>
        {evidence.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Ref</th>
                  <th>Against</th>
                  <th>Review stage</th>
                  <th>Uploaded</th>
                </tr>
              </thead>
              <tbody>
                {evidence.map((e) => (
                  <tr key={e.id}>
                    <td className="mono">
                      <Link href={`${base}/evidence/${e.id}`}>{e.evidence_ref ?? e.id.slice(0, 8)}</Link>
                    </td>
                    <td className="muted">
                      {e.register_item_id === item.id ? 'this finding' : null}
                      {e.register_item_id === item.id && e.activity_id ? ' · ' : null}
                      {e.activity_id ? `activity ${actRef.get(e.activity_id) ?? '—'}` : null}
                    </td>
                    <td>
                      <EvidenceChip stage={e.review_stage} outcome={e.outcome} evidenceRef={e.evidence_ref} />
                    </td>
                    <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>{e.uploaded_at.slice(0, 10)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState
            icon="file-check-2"
            message="No evidence yet. Upload against a linked activity on the evidence screen."
            action={<Link href={`${base}/evidence`}>Go to evidence</Link>}
          />
        )}
      </Card>
    </>
  );
}
