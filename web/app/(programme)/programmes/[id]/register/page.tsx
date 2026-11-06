import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { Input, Select } from '@/components/ui/forms';
import { loadEngineValues, loadRegisterItems } from './register-data';
import {
  PRIORITIES,
  PRIORITY_TONE,
  RAGS,
  REGISTER_STATUSES,
  type RegisterActivity,
  type RegisterEvidence,
} from './types';

export const dynamic = 'force-dynamic';

// ---------------------------------------------------------------------------
// W2-16 — remediation register (spec §6.2 Register item, FR-REG-01..04).
// Everything is read under the caller's JWT (register_items T2, links T2-via-
// item, evidence T2+T4). RAG + days overdue come from the W1-01 engine RPCs
// (register_item_rag / register_days_overdue) — never computed here. Filters
// are GET params applied server-side to the RLS-visible set.
// ---------------------------------------------------------------------------

type SP = {
  status?: string;
  priority?: string;
  workstream?: string;
  rag?: string;
  source?: string;
  overdue?: string;
  q?: string;
};

export default async function RegisterPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<SP>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();
  const base = `/programmes/${id}`;

  const [{ items, error }, { data: workstreams }, { data: activities }, { data: evidence }] =
    await Promise.all([
      loadRegisterItems(supabase, id),
      supabase.from('workstreams').select('id, name').eq('programme_id', id).order('name'),
      supabase
        .from('activities')
        .select('id, ref, text, status, workstream_id')
        // #92: retired activities are out of the §9.4 leg — not listed as links
        .eq('programme_id', id)
        .eq('active', true),
      supabase
        .from('evidence_items')
        .select('id, activity_id, register_item_id, review_stage, outcome, evidence_ref, uploaded_at')
        .eq('programme_id', id),
    ]);

  const itemIds = items.map((i) => i.id);
  const [{ data: links }, engine] = await Promise.all([
    itemIds.length
      ? supabase
          .from('register_item_activities')
          .select('register_item_id, activity_id')
          .in('register_item_id', itemIds)
      : Promise.resolve({ data: [] as { register_item_id: string; activity_id: string }[] }),
    loadEngineValues(supabase, items),
  ]);

  const acts = new Map(((activities ?? []) as RegisterActivity[]).map((a) => [a.id, a]));
  const wsName = new Map((workstreams ?? []).map((w) => [w.id as string, w.name as string]));
  const ev = (evidence ?? []) as RegisterEvidence[];
  const linksFor = (itemId: string) =>
    (links ?? [])
      .filter((l) => l.register_item_id === itemId)
      .map((l) => acts.get(l.activity_id as string))
      .filter(Boolean) as RegisterActivity[];

  // lead names — users RLS (self / partner_admin's partner); others → short id
  const leadIds = [...new Set(items.map((i) => i.lead).filter(Boolean))] as string[];
  const { data: users } = leadIds.length
    ? await supabase.from('users').select('id, full_name, email').in('id', leadIds)
    : { data: [] as { id: string; full_name: string | null; email: string }[] };
  const names = new Map(
    (users ?? []).map((u) => [u.id as string, (u.full_name as string) || (u.email as string)])
  );
  const who = (uid: string | null) => (uid ? names.get(uid) ?? `user ${uid.slice(0, 8)}` : '—');

  const rows = items.map((i) => {
    const linked = linksFor(i.id);
    const linkedIds = new Set(linked.map((a) => a.id));
    const itemEv = ev.filter(
      (e) => e.register_item_id === i.id || (e.activity_id && linkedIds.has(e.activity_id))
    );
    const wsIds = [...new Set(linked.map((a) => a.workstream_id).filter(Boolean))] as string[];
    return {
      item: i,
      linked,
      wsIds,
      rag: engine[i.id]?.rag ?? null,
      daysOverdue: engine[i.id]?.daysOverdue ?? null,
      pendingEvidence: itemEv.filter((e) => e.review_stage !== 'decided').length,
      decidedRefs: itemEv
        .filter((e) => e.review_stage === 'decided' && e.evidence_ref)
        .map((e) => e.evidence_ref as string),
    };
  });

  // ---- filters (display only — readiness is never derived here) ----
  const pick = (v: string | undefined, allowed: string[]) => (v && allowed.includes(v) ? v : null);
  const fStatus = pick(sp.status, REGISTER_STATUSES);
  const fPriority = pick(sp.priority, PRIORITIES);
  const fRag = pick(sp.rag, RAGS);
  const fWs = sp.workstream && wsName.has(sp.workstream) ? sp.workstream : null;
  const fSource = pick(sp.source, ['imported', 'manual']);
  const fOverdue = sp.overdue === '1';
  const fQ = (sp.q ?? '').trim().toLowerCase();
  const filtered = rows.filter(
    (r) =>
      (!fStatus || r.item.status === fStatus) &&
      (!fPriority || r.item.priority === fPriority) &&
      (!fRag || r.rag === fRag) &&
      (!fWs || r.wsIds.includes(fWs)) &&
      (!fSource ||
        (fSource === 'imported') === !!r.item.source_assessment_session_id) &&
      (!fOverdue || (r.daysOverdue ?? 0) > 0) &&
      (!fQ ||
        r.item.ref.toLowerCase().includes(fQ) ||
        r.item.finding.toLowerCase().includes(fQ) ||
        (r.item.source_question_ref ?? '').toLowerCase().includes(fQ))
  );
  const anyFilter = fStatus || fPriority || fRag || fWs || fSource || fOverdue || fQ;

  const open = rows.filter((r) => r.item.status !== 'Closed');
  const overdueCount = open.filter((r) => (r.daysOverdue ?? 0) > 0).length;
  const redCount = open.filter((r) => r.rag === 'Red').length;
  const imported = rows.filter((r) => r.item.source_assessment_session_id).length;

  return (
    <>
      <PageHeader
        title="Remediation register"
        eyebrow={ctx.programme.name}
        meta={`${rows.length} finding${rows.length === 1 ? '' : 's'} · ${open.length} open · ${imported} from assessment`}
        actions={
          <Link href={`${base}/schedule`} className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
            Edit activities on the schedule →
          </Link>
        }
      />

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <Card pad={16} style={{ flex: '1 1 120px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{open.length}</div>
          <div className="muted">Open findings</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 120px' }}>
          <div className="mono" style={{ fontSize: 28, color: overdueCount ? 'var(--fail)' : undefined }}>
            {overdueCount}
          </div>
          <div className="muted">Overdue</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 120px' }}>
          <div className="mono" style={{ fontSize: 28, color: redCount ? 'var(--fail)' : undefined }}>
            {redCount}
          </div>
          <div className="muted">Red</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 120px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{rows.length - open.length}</div>
          <div className="muted">Closed</div>
        </Card>
      </div>

      {error ? <Alert tone="err">{`Could not load the register: ${error}`}</Alert> : null}

      <form
        method="get"
        style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center', marginBottom: 12 }}
      >
        <Input name="q" defaultValue={sp.q ?? ''} placeholder="Search ref, finding, question" aria-label="Search" style={{ width: 220 }} />
        <Select name="status" defaultValue={fStatus ?? ''} aria-label="Status" style={{ width: 'auto' }}>
          <option value="">All statuses</option>
          {REGISTER_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        </Select>
        <Select name="priority" defaultValue={fPriority ?? ''} aria-label="Priority" style={{ width: 'auto' }}>
          <option value="">All priorities</option>
          {PRIORITIES.map((s) => <option key={s} value={s}>{s}</option>)}
        </Select>
        <Select name="rag" defaultValue={fRag ?? ''} aria-label="RAG" style={{ width: 'auto' }}>
          <option value="">Any RAG</option>
          {RAGS.map((s) => <option key={s} value={s}>{s}</option>)}
        </Select>
        <Select name="workstream" defaultValue={fWs ?? ''} aria-label="Workstream" style={{ width: 'auto' }}>
          <option value="">All workstreams</option>
          {(workstreams ?? []).map((w) => (
            <option key={w.id as string} value={w.id as string}>{w.name as string}</option>
          ))}
        </Select>
        <Select name="source" defaultValue={fSource ?? ''} aria-label="Source" style={{ width: 'auto' }}>
          <option value="">Any source</option>
          <option value="imported">From assessment</option>
          <option value="manual">Template / manual</option>
        </Select>
        <Select name="overdue" defaultValue={fOverdue ? '1' : ''} aria-label="Overdue" style={{ width: 'auto' }}>
          <option value="">Overdue or not</option>
          <option value="1">Overdue only</option>
        </Select>
        <Button size="sm" variant="outline" type="submit" icon="filter">Filter</Button>
        {anyFilter ? (
          <a href={`${base}/register`} className="muted" style={{ fontSize: 'var(--fs-sm)' }}>Clear</a>
        ) : null}
      </form>

      <Card pad={0}>
        {filtered.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Ref</th>
                  <th>Finding</th>
                  <th>Priority</th>
                  <th>Status</th>
                  <th>RAG</th>
                  <th>Workstream</th>
                  <th>Activities</th>
                  <th>Planned close</th>
                  <th style={{ textAlign: 'right' }}>Days overdue</th>
                  <th>Evidence</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map(({ item: i, linked, wsIds, rag, daysOverdue, pendingEvidence, decidedRefs }) => {
                  const refs = i.accepted_evidence_refs?.length ? i.accepted_evidence_refs : decidedRefs;
                  return (
                    <tr key={i.id}>
                      <td className="mono" style={{ whiteSpace: 'nowrap' }}>
                        <Link href={`${base}/register/${i.id}`}>{i.ref}</Link>
                      </td>
                      <td style={{ maxWidth: 380 }}>
                        <Link href={`${base}/register/${i.id}`} style={{ color: 'inherit', fontWeight: 500 }}>
                          {i.finding}
                        </Link>
                        <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                          {i.source_assessment_session_id ? (
                            <>
                              from assessment · question{' '}
                              <span className="mono">{i.source_question_ref ?? '—'}</span>
                            </>
                          ) : i.assessment_window ? (
                            <>window {i.assessment_window}</>
                          ) : null}
                          {i.lead ? <> · lead {who(i.lead)}</> : null}
                        </div>
                      </td>
                      <td><Badge tone={PRIORITY_TONE[i.priority] ?? 'neutral'}>{i.priority}</Badge></td>
                      <td><StatusPill status={i.status} /></td>
                      <td><RagBadge rag={rag} /></td>
                      <td className="muted">
                        {wsIds.length ? wsIds.map((w) => wsName.get(w) ?? '—').join(', ') : '—'}
                      </td>
                      <td>
                        {linked.length ? (
                          <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                            {linked.map((a) => (
                              <Badge key={a.id} tone={a.status === 'Complete' ? 'pass' : 'neutral'}>
                                <span title={`${a.text} — ${a.status}`}>{a.ref}</span>
                              </Badge>
                            ))}
                          </div>
                        ) : (
                          <span className="muted">none</span>
                        )}
                      </td>
                      <td className="mono muted" style={{ fontSize: 'var(--fs-xs)', whiteSpace: 'nowrap' }}>
                        {i.planned_close_date ?? (i.planned_close_week ? `week ${i.planned_close_week}` : '—')}
                      </td>
                      <td
                        className="mono"
                        style={{ textAlign: 'right', color: (daysOverdue ?? 0) > 0 ? 'var(--fail)' : 'var(--muted)' }}
                      >
                        {daysOverdue == null ? '—' : daysOverdue}
                      </td>
                      <td style={{ fontSize: 'var(--fs-xs)' }}>
                        {refs.length ? <span className="mono">{refs.join(', ')}</span> : <span className="muted">—</span>}
                        {pendingEvidence ? (
                          <div className="muted">{pendingEvidence} in review</div>
                        ) : null}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState
            icon="list-checks"
            message={
              anyFilter
                ? 'No findings match these filters.'
                : 'No findings yet. They load from the framework template or are imported from an assessment.'
            }
          />
        )}
      </Card>
    </>
  );
}
