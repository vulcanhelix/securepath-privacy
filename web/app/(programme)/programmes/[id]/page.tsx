import Link from 'next/link';
import * as React from 'react';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { listProgrammes } from '@/lib/programme';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { EmptyState } from '@/components/ui/EmptyState';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { SortableTable } from '@/components/ui/SortableTable';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { WeekBadge } from '@/components/ui/WeekBadge';
import { Icon } from '@/components/ui/Icon';

export const dynamic = 'force-dynamic';

// W2-04 — programme dashboard (spec §8.1 screen 01, FR-DSH-01..06).
// Every read runs under the caller's JWT (serverClient cookie session): RLS
// decides row visibility, and the engine RPCs used here (programme_week,
// programme_rag, workstream_rag) are SECURITY INVOKER so the same applies
// inside them. Dates are stored as UTC `date`; display renders the stored
// day verbatim — no timezone shift on a date-only value.

interface PhaseRow { number: number; name: string; start_week: number; end_week: number }
interface WsRow { id: string; name: string; accountable_lead: string | null; deputy: string | null; rag_override: string | null }
interface ActRow {
  id: string; ref: string; text: string; workstream_id: string | null;
  leads: string[] | null; start_week: number; end_week: number; milestone: boolean;
  status: string; pct_complete: number; due_date: string | null;
  rescheduled_date: string | null; rag: string | null; comments: string | null;
}
interface RegRow {
  id: string; ref: string; finding: string; priority: string; status: string;
  lead: string | null; planned_close_week: number | null;
  planned_close_date: string | null; days_overdue: number | null;
}
interface RaidRow { id: string; type: string; description: string; owner: string | null; review_by: string | null; status: string }
interface EvRow { id: string; review_stage: string }

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Render a stored UTC `date` as "14 Nov 2026" — string ops only, no tz shift. */
function fmtDay(d?: string | null) {
  if (!d) return '—';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d);
  return m ? `${Number(m[3])} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : d;
}

function addDays(iso: string, n: number) {
  const d = new Date(`${iso.slice(0, 10)}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function daysBetween(a: string, b: string) {
  return Math.round((Date.parse(b.slice(0, 10)) - Date.parse(a.slice(0, 10))) / 86400000);
}

// register-grid status → semantic tint (same vars as RagBadge, never whitelabelled)
const REG_TONE: Record<string, { bg: string; bd: string; fg: string }> = {
  Closed: { bg: 'var(--pass-soft)', bd: 'var(--pass-border)', fg: 'var(--pass)' },
  'In progress': { bg: 'var(--accent-soft)', bd: 'var(--accent-soft-border)', fg: 'var(--accent-text)' },
  'At risk': { bg: 'var(--warn-soft)', bd: 'var(--warn-border)', fg: 'var(--warn)' },
  Blocked: { bg: 'var(--fail-soft)', bd: 'var(--fail-border)', fg: 'var(--fail)' },
  'Not started': { bg: 'var(--inset)', bd: 'var(--border)', fg: 'var(--muted)' },
};

function Tile({ href, n, label, sub, tone }: {
  href: string; n: React.ReactNode; label: string; sub?: React.ReactNode; tone?: string;
}) {
  return (
    <Link href={href} style={{ flex: '1 1 140px', textDecoration: 'none', color: 'inherit' }}>
      <Card pad={16} style={{ height: '100%' }}>
        <div className="mono" style={{ fontSize: 28, color: tone ?? 'var(--text)' }}>{n}</div>
        <div className="muted">{label}</div>
        {sub ? <div className="muted" style={{ marginTop: 4 }}>{sub}</div> : null}
      </Card>
    </Link>
  );
}

export default async function ProgrammeDashboardPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const today = new Date().toISOString().slice(0, 10); // UTC — engine dates are UTC `date`
  const start = ctx.programme.start_date;

  const [weekR, ragR, list, phasesR, wsR, actsR, regR, evR, raidR, progR, isAo] = await Promise.all([
    // §9.1 engine calc + §9.6 effective RAG (stored lead value else suggestion)
    supabase.rpc('programme_week', { p_programme: id, p_date: today }),
    supabase.rpc('programme_rag', { p_programme: id }),
    listProgrammes(ctx.client.id, supabase),
    supabase.from('phases').select('number, name, start_week, end_week')
      .eq('programme_id', id).order('number'),
    supabase.from('workstreams').select('id, name, accountable_lead, deputy, rag_override')
      .eq('programme_id', id).order('name'),
    supabase.from('activities')
      .select('id, ref, text, workstream_id, leads, start_week, end_week, milestone, status, pct_complete, due_date, rescheduled_date, rag, comments')
      // #92: retired rows (FR-TPL-04) are out of scope — same as the rollups
      .eq('programme_id', id).eq('active', true).order('ref'),
    supabase.from('register_items')
      .select('id, ref, finding, priority, status, lead, planned_close_week, planned_close_date, days_overdue')
      .eq('programme_id', id).eq('active', true).order('ref'),
    supabase.from('evidence_items').select('id, review_stage').eq('programme_id', id),
    supabase.from('raid_items').select('id, type, description, owner, review_by, status')
      .eq('programme_id', id).order('raised_on', { ascending: false }),
    // template_version_id + reduced_capacity_weeks aren't on ProgrammeSummary
    supabase.from('programmes').select('template_version_id, reduced_capacity_weeks')
      .eq('id', id).maybeSingle(),
    // FR-ACC-02 — UI-gating only: relabels the evidence tile for the AO
    ctx.role.isAoOrAlternate(ctx.client.id),
  ]);

  const week = (weekR.data as number | null) ?? null;
  const rag = (ragR.data as string | null) ?? ctx.programme.programme_rag;
  const phases = (phasesR.data ?? []) as PhaseRow[];
  const workstreams = (wsR.data ?? []) as WsRow[];
  const activities = (actsR.data ?? []) as ActRow[];
  const registerItems = (regR.data ?? []) as RegRow[];
  const evidence = (evR.data ?? []) as EvRow[];
  const raidItems = (raidR.data ?? []) as RaidRow[];
  const rollup = list.rows.find((r) => r.programme_id === id) ?? null;
  const reducedWeeks = (progR.data?.reduced_capacity_weeks as number[] | null) ?? [];

  // template/edition — RLS-gated, absent scopes just render '—'
  let templateName: string | null = null;
  const tvi = progR.data?.template_version_id as string | null;
  if (tvi) {
    const { data: v } = await supabase
      .from('programme_template_versions').select('number, template_id')
      .eq('id', tvi).maybeSingle();
    if (v?.template_id) {
      const { data: t } = await supabase
        .from('programme_templates').select('name, edition, framework')
        .eq('id', v.template_id).maybeSingle();
      if (t) templateName = `${t.name}${t.edition ? ` (${t.edition})` : ''} · v${v.number}`;
    }
  }

  // ---- lead / owner display names (users_self RLS decides which resolve) ----
  const userIds = new Set<string>();
  if (ctx.programme.programme_lead) userIds.add(ctx.programme.programme_lead);
  for (const w of workstreams) if (w.accountable_lead) userIds.add(w.accountable_lead);
  for (const a of activities) for (const l of a.leads ?? []) userIds.add(l);
  for (const r of registerItems) if (r.lead) userIds.add(r.lead);
  for (const r of raidItems) if (r.owner) userIds.add(r.owner);
  const { data: userRows } = userIds.size
    ? await supabase.from('users').select('id, full_name, email').in('id', [...userIds])
    : { data: [] as { id: string; full_name: string | null; email: string }[] };
  const userName = new Map(
    (userRows ?? []).map((u) => [u.id as string, (u.full_name || u.email) as string])
  );
  const nameOf = (uid?: string | null) => (uid ? userName.get(uid) ?? '—' : '—');

  // ---- date helpers over the §9.1 week anchor (calc columns may lag) ----
  const weekDue = (w: number) => addDays(start, (w - 1) * 7 + 4); // Friday of week w
  const actDue = (a: ActRow) =>
    a.status === 'Deferred' && a.rescheduled_date
      ? a.rescheduled_date
      : a.due_date ?? weekDue(a.end_week);
  const regClose = (r: RegRow) =>
    r.planned_close_date ?? (r.planned_close_week ? weekDue(r.planned_close_week) : null);

  // ---- FR-DSH-01 headline figures: list_programmes rollup wins when the
  // W1-05 RPC answers; the same figures computed from the RLS reads fill the
  // gap while the environment runs the table fallback ----
  const regClosed = rollup?.register_closed ?? registerItems.filter((r) => r.status === 'Closed').length;
  const regOpen = rollup?.register_open ?? registerItems.filter((r) => r.status !== 'Closed').length;
  // (no high-priority rollup column — always computed from the register read)
  const highClosed = registerItems.filter((r) => r.status === 'Closed' && r.priority === 'High').length;
  const highOpen = registerItems.filter((r) => r.status !== 'Closed' && r.priority === 'High').length;
  const actTotal = rollup?.activities_total ?? activities.length;
  const actComplete = rollup?.activities_complete ?? activities.filter((a) => a.status === 'Complete').length;
  const overdueActs = activities.filter((a) => a.status !== 'Complete' && actDue(a) < today);
  const actOverdue = rollup?.activities_overdue ?? overdueActs.length;
  const evPending = rollup?.evidence_pending ?? evidence.filter((e) => e.review_stage !== 'decided').length;
  const raidOpen = raidItems.filter((r) => r.status !== 'Closed').length;

  const regOverdueItems = registerItems.filter((r) => {
    const pc = regClose(r);
    return r.status !== 'Closed' && pc !== null && pc < today;
  });
  const raidReviewDue = raidItems.filter((r) => r.status !== 'Closed' && r.review_by && r.review_by <= today);
  const decisionsDue = raidItems.filter(
    (r) => r.status !== 'Closed' && r.review_by && daysBetween(today, r.review_by) <= 14
  );

  // ---- this week ----
  const thisWeek = week == null
    ? []
    : activities
        .filter((a) => a.start_week <= week && week <= a.end_week)
        .sort((a, b) => actDue(a).localeCompare(actDue(b)) || a.ref.localeCompare(b.ref));
  const dueThisWeek = activities.filter(
    (a) => a.status !== 'Complete' && week != null && a.end_week === week
  );

  // ---- FR-DSH-03 workstream strip ----
  const wsRags = await Promise.all(
    workstreams.map((w) => supabase.rpc('workstream_rag', { p_workstream: w.id }))
  );
  const wsName = new Map(workstreams.map((w) => [w.id, w.name]));
  const wsRows = workstreams.map((w, i) => {
    const acts = activities.filter((a) => a.workstream_id === w.id);
    const closed = acts.filter((a) => a.status === 'Complete').length;
    const commentary = [...acts]
      .filter((a) => a.comments)
      .sort((a, b) => actDue(b).localeCompare(actDue(a)))[0]?.comments ?? null;
    return { w, total: acts.length, closed, rag: (wsRags[i].data as string | null) ?? w.rag_override, commentary };
  });

  // ---- FR-DSH-05 next five milestones ----
  const milestones = activities
    .filter((a) => a.milestone && a.status !== 'Complete')
    .sort((a, b) => actDue(a).localeCompare(actDue(b)))
    .slice(0, 5);

  // ---- FR-DSH-04 needs-attention list ----
  type Attention = { key: string; tone: 'fail' | 'warn' | 'accent'; kind: string; text: React.ReactNode; meta: string; href: string; sort: number };
  const attention: Attention[] = [];
  for (const a of overdueActs.slice(0, 4)) {
    attention.push({
      key: `ov-${a.id}`, tone: 'fail', kind: 'Overdue',
      text: <>{a.ref} · {a.text}</>, meta: `due ${fmtDay(actDue(a))}`,
      href: `/programmes/${id}/schedule`, sort: 0,
    });
  }
  for (const r of regOverdueItems.slice(0, 3)) {
    const over = r.days_overdue ?? daysBetween(regClose(r)!, today);
    attention.push({
      key: `ro-${r.id}`, tone: 'fail', kind: 'Overdue',
      text: <>{r.ref} · {r.finding}</>, meta: `${over}d past planned close`,
      href: `/programmes/${id}/register`, sort: 1,
    });
  }
  for (const a of dueThisWeek.filter((x) => actDue(x) >= today).slice(0, 4)) {
    attention.push({
      key: `dw-${a.id}`, tone: 'accent', kind: 'Due this week',
      text: <>{a.ref} · {a.text}</>, meta: `due ${fmtDay(actDue(a))}`,
      href: `/programmes/${id}/schedule`, sort: 2,
    });
  }
  for (const r of decisionsDue.slice(0, 3)) {
    attention.push({
      key: `dd-${r.id}`, tone: 'warn', kind: 'Decision',
      text: <>{r.type} — {r.description}</>, meta: `needed by ${fmtDay(r.review_by)}`,
      href: `/programmes/${id}/raid`, sort: 3,
    });
  }
  if (evPending > 0) {
    attention.push({
      key: 'ev', tone: 'warn', kind: 'Evidence',
      text: <>{evPending} item{evPending === 1 ? '' : 's'} awaiting {isAo ? 'your decision' : 'review or decision'}</>,
      meta: 'review queue', href: `/programmes/${id}/evidence`, sort: 4,
    });
  }
  attention.sort((a, b) => a.sort - b.sort);

  const loadErrors = [weekR, ragR, phasesR, wsR, actsR, regR, evR, raidR, progR]
    .map((r) => r.error?.message)
    .filter((m): m is string => !!m);

  const tiles = (
    <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
      <Tile href={`/programmes/${id}/register`} n={`${regClosed}/${regClosed + regOpen}`}
        label="Register items closed" sub={regOpen ? `${regOpen} open finding${regOpen === 1 ? '' : 's'}` : 'all closed'} />
      <Tile href={`/programmes/${id}/register`} n={highClosed} label="High-priority closed"
        sub={highOpen ? `${highOpen} still open` : undefined}
        tone={highOpen ? 'var(--warn)' : undefined} />
      <Tile href={`/programmes/${id}/schedule`} n={`${actComplete}/${actTotal}`} label="Activities complete" />
      <Tile href={`/programmes/${id}/schedule`} n={actOverdue} label="Activities overdue"
        tone={actOverdue ? 'var(--fail)' : undefined} />
      <Tile href={`/programmes/${id}/evidence`} n={evPending}
        label={isAo ? 'Evidence awaiting your decision' : 'Evidence awaiting decision'}
        tone={evPending ? 'var(--warn)' : undefined} />
      <Tile href={`/programmes/${id}/raid`} n={raidOpen} label="Open RAID items"
        sub={raidReviewDue.length ? `${raidReviewDue.length} due for review` : undefined}
        tone={raidReviewDue.length ? 'var(--warn)' : undefined} />
    </div>
  );

  return (
    <>
      <PageHeader
        title={ctx.programme.name}
        eyebrow={ctx.client.jurisdiction ? `${ctx.client.name} · ${ctx.client.jurisdiction}` : ctx.client.name}
        meta={
          <>
            {templateName ? `${templateName} · ` : ''}
            started {fmtDay(start)} · lead {nameOf(ctx.programme.programme_lead)}
            {ctx.programme.phase ? ` · ${ctx.programme.phase}` : ''}
          </>
        }
        actions={
          <>
            <StatusPill status={ctx.programme.status} />
            <RagBadge rag={rag} />
            <WeekBadge week={week} total={ctx.programme.total_weeks} />
          </>
        }
      />

      {/* alerts strip — things that need a person today */}
      {actOverdue || regOverdueItems.length ? (
        <Alert tone="err">
          {[
            actOverdue ? `${actOverdue} activit${actOverdue === 1 ? 'y' : 'ies'} overdue` : null,
            regOverdueItems.length ? `${regOverdueItems.length} register item${regOverdueItems.length === 1 ? '' : 's'} past planned close` : null,
          ].filter(Boolean).join(' · ')}{' '}
          — see <Link href={`/programmes/${id}/schedule`}>schedule</Link> and{' '}
          <Link href={`/programmes/${id}/register`}>register</Link>.
        </Alert>
      ) : null}
      {evPending || raidReviewDue.length ? (
        <Alert tone="info">
          {[
            evPending ? `${evPending} evidence item${evPending === 1 ? '' : 's'} awaiting ${isAo ? 'your decision' : 'review'}` : null,
            raidReviewDue.length ? `${raidReviewDue.length} open RAID item${raidReviewDue.length === 1 ? '' : 's'} due for review` : null,
          ].filter(Boolean).join(' · ')}{' '}
          — see <Link href={`/programmes/${id}/evidence`}>evidence</Link> and{' '}
          <Link href={`/programmes/${id}/raid`}>RAID log</Link>.
        </Alert>
      ) : null}
      {loadErrors.length ? (
        <Alert tone="err">Some dashboard figures could not be loaded: {loadErrors[0]}</Alert>
      ) : null}

      {/* FR-DSH-01 headline tiles — every figure links to its list (FR-DSH-06) */}
      {tiles}

      {/* FR-DSH-02 phase timeline with the current week marked */}
      <Card
        title="Phase timeline"
        action={week != null
          ? <span className="muted">Week {week} of {ctx.programme.total_weeks}{reducedWeeks.includes(week) ? ' · reduced capacity' : ''}</span>
          : undefined}
        style={{ marginBottom: 20 }}
      >
        {phases.length ? (
          <div className="sp-rail">
            {phases.map((ph, i) => {
              const state =
                week == null ? 'future'
                : week > ph.end_week ? 'done'
                : week >= ph.start_week ? 'current' : 'future';
              return (
                <React.Fragment key={ph.number}>
                  {i > 0 ? <span className="sp-rail-line" /> : null}
                  <div className={`sp-rail-node sp-rail-node--${state}`}>
                    <span className="sp-rail-dot">
                      {state === 'done' ? <Icon name="check" size={14} /> : <span className="mono">{ph.number}</span>}
                    </span>
                    <span className="sp-rail-label">{ph.name}</span>
                    <span className="sp-rail-sub">
                      W{ph.start_week}–W{ph.end_week}
                      {state === 'current' && week != null ? ` · now W${week}` : ''}
                    </span>
                  </div>
                </React.Fragment>
              );
            })}
          </div>
        ) : (
          <EmptyState icon="milestone" message="No phase rows yet — phase boundaries come from the programme template at creation." />
        )}
      </Card>

      {/* FR-DSH-03 status by workstream */}
      <Card title="Workstreams" pad={0} style={{ marginBottom: 20 }}>
        {wsRows.length ? (
          <SortableTable
            initialSort={0}
            columns={[
              { label: 'Workstream' },
              { label: 'Lead' },
              { label: 'Progress' },
              { label: 'RAG' },
              { label: 'Latest commentary', sortable: false },
            ]}
            rows={wsRows.map(({ w, total, closed, rag: wrag, commentary }) => ({
              values: [w.name, nameOf(w.accountable_lead), total ? closed / total : -1, wrag ?? '', commentary ?? ''],
              cells: [
                <span key="n" style={{ fontWeight: 500, color: 'var(--text)' }}>{w.name}</span>,
                <span key="l">{nameOf(w.accountable_lead)}</span>,
                <span key="p" style={{ display: 'inline-flex', alignItems: 'center', gap: 10, minWidth: 140 }}>
                  <span className="sp-bars-track" style={{ width: 72 }}>
                    <span className="sp-bars-fill" style={{ width: `${total ? Math.round((closed / total) * 100) : 0}%`, background: 'var(--accent)' }} />
                  </span>
                  <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                    {closed}/{total} closed
                  </span>
                </span>,
                <RagBadge key="r" rag={wrag} />,
                <span key="c" className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                  {commentary ? (commentary.length > 110 ? `${commentary.slice(0, 110)}…` : commentary) : '—'}
                </span>,
              ],
            }))}
          />
        ) : (
          <EmptyState icon="network" message="No workstreams yet — they are created from the programme template." />
        )}
      </Card>

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'stretch', marginBottom: 20 }}>
        {/* FR-DSH-04 needs attention */}
        <div style={{ flex: '1 1 420px', minWidth: 0 }}>
          <Card title="Needs attention" pad={0} style={{ height: '100%' }}>
            {attention.length ? (
              <div style={{ display: 'flex', flexDirection: 'column' }}>
                {attention.slice(0, 10).map((it) => (
                  <Link
                    key={it.key}
                    href={it.href}
                    style={{
                      display: 'flex', alignItems: 'center', gap: 12, padding: '12px 20px',
                      borderBottom: '1px solid var(--border)', textDecoration: 'none', color: 'inherit',
                    }}
                  >
                    <Badge tone={it.tone}>{it.kind}</Badge>
                    <span style={{ flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
                      {it.text}
                    </span>
                    <span className="muted" style={{ flex: 'none' }}>{it.meta}</span>
                  </Link>
                ))}
                {attention.length > 10 ? (
                  <div className="muted" style={{ padding: '10px 20px' }}>
                    +{attention.length - 10} more across schedule, register, evidence and RAID
                  </div>
                ) : null}
              </div>
            ) : (
              <EmptyState icon="check-circle-2" message="Nothing needs attention right now — no overdue work, decisions or pending evidence." />
            )}
          </Card>
        </div>

        {/* FR-DSH-05 next five milestones */}
        <div style={{ flex: '1 1 320px', minWidth: 0 }}>
          <Card title="Next milestones" pad={0} style={{ height: '100%' }}>
            {milestones.length ? (
              <div style={{ display: 'flex', flexDirection: 'column' }}>
                {milestones.map((a) => (
                  <div
                    key={a.id}
                    style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 20px', borderBottom: '1px solid var(--border)' }}
                  >
                    <span style={{ color: 'var(--accent-text)' }}><Icon name="diamond" size={13} /></span>
                    <span style={{ flex: 1, minWidth: 0, fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
                      <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>{a.ref}</span>{' '}
                      {a.text}
                    </span>
                    <span className="muted" style={{ flex: 'none' }}>W{a.end_week} · {fmtDay(actDue(a))}</span>
                  </div>
                ))}
              </div>
            ) : (
              <EmptyState icon="flag" message="No open milestones — either all are complete or the template sets none." />
            )}
          </Card>
        </div>
      </div>

      {/* this week's activities */}
      <Card
        title={week != null ? `This week — week ${week}` : 'Activities'}
        pad={0} style={{ marginBottom: 20 }}
        action={<Link href={`/programmes/${id}/schedule`} className="muted">Full schedule &rarr;</Link>}
      >
        {week != null && thisWeek.length ? (
          <SortableTable
            columns={[
              { label: 'Ref' },
              { label: 'Activity' },
              { label: 'Workstream' },
              { label: 'Leads' },
              { label: 'Status' },
              { label: 'Due' },
            ]}
            rows={thisWeek.map((a) => ({
              values: [a.ref, a.text, a.workstream_id ? wsName.get(a.workstream_id) ?? '' : '', (a.leads ?? []).map(nameOf).join(' '), a.status, actDue(a)],
              cells: [
                <span key="r" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>{a.ref}</span>,
                <span key="t" style={{ color: 'var(--text)' }}>
                  {a.milestone ? <span style={{ color: 'var(--accent-text)', marginRight: 6 }}><Icon name="diamond" size={11} /></span> : null}
                  {a.text}
                </span>,
                <span key="w" className="muted">{a.workstream_id ? wsName.get(a.workstream_id) ?? '—' : '—'}</span>,
                <span key="l" className="muted">{(a.leads ?? []).map(nameOf).join(', ') || '—'}</span>,
                <StatusPill key="s" status={a.status} />,
                <span key="d" className="mono" style={{ fontSize: 'var(--fs-xs)', color: actDue(a) < today && a.status !== 'Complete' ? 'var(--fail)' : 'var(--muted)' }}>
                  {fmtDay(actDue(a))}
                </span>,
              ],
            }))}
          />
        ) : (
          <EmptyState
            icon="calendar"
            message={week == null
              ? 'The programme clock has not started — check the start date.'
              : `Nothing is scheduled in week ${week}.`}
          />
        )}
      </Card>

      {/* FR-DSH-05 register grid coloured by status */}
      <Card
        title="Remediation register"
        pad={20}
        action={<Link href={`/programmes/${id}/register`} className="muted">{regOpen} open &rarr;</Link>}
      >
        {registerItems.length ? (
          <>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
              {registerItems.map((r) => {
                const t = REG_TONE[r.status] ?? REG_TONE['Not started'];
                return (
                  <Link
                    key={r.id}
                    href={`/programmes/${id}/register`}
                    title={`${r.ref} · ${r.finding} — ${r.status}${r.priority === 'High' ? ' (High)' : ''}`}
                    style={{
                      display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 10px',
                      borderRadius: 8, border: `1px solid ${t.bd}`, background: t.bg,
                      textDecoration: 'none', fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-xs)',
                      color: t.fg,
                    }}
                  >
                    {r.priority === 'High' ? <span style={{ width: 6, height: 6, borderRadius: '50%', background: t.fg }} /> : null}
                    {r.ref}
                  </Link>
                );
              })}
            </div>
            <div className="muted" style={{ marginTop: 14, display: 'flex', gap: 14, flexWrap: 'wrap' }}>
              {Object.entries(REG_TONE).map(([s, t]) => (
                <span key={s} style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                  <span style={{ width: 10, height: 10, borderRadius: 3, background: t.bg, border: `1px solid ${t.bd}` }} />
                  {s}
                </span>
              ))}
            </div>
          </>
        ) : (
          <EmptyState icon="list-checks" message="No findings on the register yet — findings arrive with the first assessment or audit." />
        )}
      </Card>
    </>
  );
}
