import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { DataTable } from '@/components/ui/DataTable';
import { SortableTable } from '@/components/ui/SortableTable';
import { EmptyState } from '@/components/ui/EmptyState';
import { WeeklyWeekPicker } from './WeeklyWeekPicker';
import { AgendaActivities, type AgendaActivity } from './AgendaActivities';
import { RecordDecisionForm, WeeklyLogForm, type WeeklyLogValues } from './WeeklyLogForm';
import { LocalDate } from './LocalDate';

export const dynamic = 'force-dynamic';

// ---------------------------------------------------------------------------
// W2-07 — weekly working session (spec §8.5, screen 04, FR-WKS-01..04).
//
//   Agenda (FR-WKS-01): composed for the selected week (default = the §9.1
//     programme_week of today) from RLS-filtered selects under the caller's
//     JWT — due, overdue, starting, evidence awaiting decision, decisions for
//     the executive, RAID due for review, KPIs due, reduced-capacity notice.
//   In-place actions (FR-WKS-02/03): AgendaActivities → update_activity /
//     queue_notification; Amber needs a recovery date before it saves.
//   Log (FR-WKS-04): get_weekly_log / list_weekly_logs / upsert_weekly_log;
//     decisions via record_decision (keyed on raid_item_id).
//
// Write UI is gated by has_programme_role with the SAME role lists the RPCs
// enforce — the server stays the authority; this only hides controls it
// would reject. Never re-derived from the role context.
// ---------------------------------------------------------------------------

// upsert_weekly_log / update_activity gate (W1-05/W1-06)
const WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];
// record_decision gate (W1-06 RAID+ set)
const DECISION_ROLES = [...WRITE_ROLES, 'executive', 'accountable_officer'];

const ACTIVITY_COLS =
  'id, ref, text, status, rag, start_week, end_week, due_date, recovery_date, leads';

const DAY = 86_400_000;
const isoDate = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (iso: string, n: number) => isoDate(new Date(Date.parse(`${iso}T00:00:00Z`) + n * DAY));

interface WeeklyLogRow extends WeeklyLogValues {
  id: string | null;
  week: number;
  counts: Record<string, number | boolean> | null;
  week_rag: string | null;
  created_at: string | null;
}

export default async function WeeklySessionPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ week?: string }>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const total = ctx.programme.total_weeks;
  const today = isoDate(new Date());

  const [{ data: cw }, { data: canWrite }, { data: canDecide }, { data: progExtra }] = await Promise.all([
    supabase.rpc('programme_week', { p_programme: id, p_date: today }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: WRITE_ROLES }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: DECISION_ROLES }),
    supabase.from('programmes').select('reduced_capacity_weeks').eq('id', id).maybeSingle(),
  ]);
  const currentWeek = (cw as number | null) ?? null;
  const asked = parseInt(sp.week ?? '', 10);
  const week = Math.min(Math.max(1, Number.isNaN(asked) ? currentWeek ?? 1 : asked), total);

  // §9.1: week n runs Monday start_date + 7(n-1) .. Sunday
  const weekStart = addDays(ctx.programme.start_date, (week - 1) * 7);
  const weekEnd = addDays(weekStart, 6);
  const isCurrent = week === currentWeek;
  // overdue reference: today in the live week, the week's Monday otherwise
  const overdueRef = isCurrent ? today : weekStart;
  const horizon = addDays(weekEnd, 14); // "decisions near their needed-by date"
  const kpiMonth = `${weekEnd.slice(0, 7)}-01`;
  const reduced = ((progExtra?.reduced_capacity_weeks as number[] | null) ?? []).includes(week);

  const [
    actsRes,
    evRes,
    raidRes,
    kpiRes,
    logRes,
    logsRes,
    decRes,
  ] = await Promise.all([
    supabase
      .from('activities')
      .select(ACTIVITY_COLS)
      .eq('programme_id', id)
      // #92: retired activities (FR-TPL-04) are out of scope and frozen
      .eq('active', true)
      .neq('status', 'Complete')
      .order('end_week')
      .order('ref'),
    supabase
      .from('evidence_items')
      .select('id, review_stage')
      .eq('programme_id', id)
      .in('review_stage', ['verification', 'acceptance']),
    supabase
      .from('raid_items')
      .select('id, type, description, status, review_by, owner')
      .eq('programme_id', id)
      .neq('status', 'Closed')
      .order('review_by', { ascending: true, nullsFirst: false }),
    supabase.from('kpis').select('id, name, unit, target, auto_calc, kpi_actuals(month)').eq('programme_id', id).order('sort'),
    supabase.rpc('get_weekly_log', { p_programme_id: id, p_week_no: week }).maybeSingle(),
    supabase.rpc('list_weekly_logs', { p_programme_id: id }),
    supabase.rpc('list_decisions', { p_programme_id: id }),
  ]);

  const loadErrors = [
    actsRes.error && `activities: ${actsRes.error.message}`,
    evRes.error && `evidence: ${evRes.error.message}`,
    raidRes.error && `RAID: ${raidRes.error.message}`,
    kpiRes.error && `KPIs: ${kpiRes.error.message}`,
    logRes.error && `weekly log: ${logRes.error.message}`,
    logsRes.error && `weekly logs: ${logsRes.error.message}`,
    decRes.error && `decisions: ${decRes.error.message}`,
  ].filter(Boolean) as string[];

  // ---- agenda composition (FR-WKS-01) ----
  const acts = ((actsRes.data ?? []) as unknown as AgendaActivity[]).map((a) => ({ ...a, leads: a.leads ?? [] }));
  const overdue = acts.filter((a) => a.due_date && a.due_date < overdueRef);
  const overdueIds = new Set(overdue.map((a) => a.id));
  const due = acts.filter((a) => a.end_week === week && !overdueIds.has(a.id));
  const starting = acts.filter((a) => a.start_week === week && a.status === 'Not started' && !overdueIds.has(a.id));
  const amberNoDate = acts.filter((a) => a.rag === 'Amber' && !a.recovery_date);

  const ev = evRes.data ?? [];
  const awaitingReview = ev.filter((e) => e.review_stage === 'verification').length;
  const awaitingAcceptance = ev.filter((e) => e.review_stage === 'acceptance').length;

  type Raid = { id: string; type: string; description: string; status: string; review_by: string | null };
  const raid = (raidRes.data ?? []) as Raid[];
  const raidDueReview = raid.filter((r) => r.review_by && r.review_by <= weekEnd);
  const raidNearDecision = raid.filter((r) => r.review_by && r.review_by > weekEnd && r.review_by <= horizon);

  type Kpi = { id: string; name: string; unit: string | null; target: number | null; auto_calc: boolean; kpi_actuals: { month: string }[] | null };
  const kpisDue = ((kpiRes.data ?? []) as Kpi[]).filter(
    (k) => !k.auto_calc && !(k.kpi_actuals ?? []).some((x) => x.month === kpiMonth)
  );

  // get_weekly_log returns a composite — a row of NULLs when none is held
  const logRaw = logRes.data as WeeklyLogRow | null;
  const log = logRaw?.id ? logRaw : null;
  const logs = ((logsRes.data ?? []) as WeeklyLogRow[]).slice().reverse();
  type Decision = { id: string; raid_item_id: string; outcome: string; decided_on: string; minute_ref: string | null };
  const weekDecisions = ((decRes.data ?? []) as Decision[]).filter(
    (d) => d.decided_on >= weekStart && d.decided_on <= weekEnd
  );
  const raidLabel = new Map(raid.map((r) => [r.id, `[${r.type}] ${r.description}`]));

  const tile = (n: number | string, label: string, tone?: string) => (
    <Card pad={16} style={{ flex: '1 1 130px' }}>
      <div className="mono" style={{ fontSize: 26, color: tone }}>{n}</div>
      <div className="muted">{label}</div>
    </Card>
  );

  return (
    <>
      <PageHeader
        title="Weekly working session"
        eyebrow={ctx.client.name}
        meta={
          <>
            Week {week} of {total} · <LocalDate value={weekStart} /> – <LocalDate value={weekEnd} />
            {isCurrent ? ' · this week' : ''}
            {canWrite ? '' : ' · read-only'}
          </>
        }
        actions={<WeeklyWeekPicker week={week} totalWeeks={total} currentWeek={currentWeek} />}
      />

      {loadErrors.length ? <Alert tone="err">{`Some agenda data could not load — ${loadErrors.join('; ')}`}</Alert> : null}
      {reduced ? (
        <div style={{ marginBottom: 16 }}>
          <Alert tone="info">Reduced-capacity week — the plan expects less delivery this week (§9.1).</Alert>
        </div>
      ) : null}

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        {tile(overdue.length, 'Overdue', overdue.length ? 'var(--fail)' : undefined)}
        {tile(due.length, 'Due this week')}
        {tile(starting.length, 'Starting')}
        {tile(awaitingReview, 'Evidence awaiting review')}
        {tile(awaitingAcceptance, 'Evidence awaiting acceptance', awaitingAcceptance ? 'var(--warn)' : undefined)}
        {tile(raid.length, 'Open RAID items')}
        {tile(kpisDue.length, 'KPIs due')}
      </div>

      <h2 className="sp-card-title" style={{ margin: '8px 0 12px' }}>Agenda</h2>
      <div style={{ display: 'grid', gap: 16, marginBottom: 28 }}>
        <Card title={`1. Overdue (${overdue.length})`} pad={0}>
          <AgendaActivities programmeId={id} week={week} activities={overdue} canWrite={!!canWrite} empty="Nothing overdue." />
        </Card>
        <Card title={`2. Due this week (${due.length})`} pad={0}>
          <AgendaActivities programmeId={id} week={week} activities={due} canWrite={!!canWrite} empty="Nothing due this week." />
        </Card>
        <Card title={`3. Starting this week (${starting.length})`} pad={0}>
          <AgendaActivities programmeId={id} week={week} activities={starting} canWrite={!!canWrite} empty="Nothing starting this week." />
        </Card>
        {amberNoDate.length ? (
          <Card title={`Amber without a recovery date (${amberNoDate.length})`} pad={0}>
            <div style={{ padding: '0 28px 12px' }} className="muted">
              FR-WKS-03: these cannot be saved from the session until a recovery date is set.
            </div>
            <AgendaActivities programmeId={id} week={week} activities={amberNoDate} canWrite={!!canWrite} empty="" />
          </Card>
        ) : null}
        <Card title="4. Evidence awaiting decision">
          <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'center' }}>
            <div><span className="mono" style={{ fontSize: 20 }}>{awaitingReview}</span> <span className="muted">awaiting verification</span></div>
            <div><span className="mono" style={{ fontSize: 20 }}>{awaitingAcceptance}</span> <span className="muted">awaiting acceptance</span></div>
            <Link href={`/programmes/${id}/evidence`} className="sp-btn sp-btn--ghost sp-btn--sm"><span>Open evidence review</span></Link>
          </div>
        </Card>
        <Card title={`5. Decisions for the executive (${raidNearDecision.length})`} pad={0}>
          {raidNearDecision.length ? (
            <DataTable
              columns={[{ label: 'Type' }, { label: 'Item' }, { label: 'Needed by' }, { label: 'Status' }]}
              rows={raidNearDecision.map((r) => [r.type, r.description, <LocalDate key="d" value={r.review_by} />, <StatusPill key="s" status={r.status} />])}
            />
          ) : (
            <EmptyState icon="gavel" message="No decisions needed within two weeks of this session." />
          )}
        </Card>
        <Card title={`6. RAID items due for review (${raidDueReview.length} of ${raid.length} open)`} pad={0}>
          {raidDueReview.length ? (
            <DataTable
              columns={[{ label: 'Type' }, { label: 'Item' }, { label: 'Review by' }, { label: 'Status' }]}
              rows={raidDueReview.map((r) => [r.type, r.description, <LocalDate key="d" value={r.review_by} />, <StatusPill key="s" status={r.status} />])}
            />
          ) : (
            <EmptyState icon="alert-triangle" message="No RAID items due for review this week." />
          )}
        </Card>
        <Card title={`7. KPIs due (${kpisDue.length})`} pad={0}>
          {kpisDue.length ? (
            <>
              <div style={{ padding: '0 28px 8px' }} className="muted">
                Manual KPIs with no actual yet for <LocalDate value={kpiMonth} />.
              </div>
              <DataTable
                columns={[{ label: 'KPI' }, { label: 'Unit' }, { label: 'Target', align: 'right' }]}
                rows={kpisDue.map((k) => [k.name, k.unit ?? '—', k.target ?? '—'])}
              />
            </>
          ) : (
            <EmptyState icon="gauge" message="No KPI actuals outstanding for this month." />
          )}
        </Card>
      </div>

      <h2 className="sp-card-title" style={{ margin: '8px 0 12px' }}>Week {week} log</h2>
      <div style={{ display: 'grid', gap: 16, gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))', marginBottom: 28 }}>
        <Card
          title={log ? 'Session log' : 'No log yet for this week'}
          action={log ? <RagBadge rag={log.week_rag} /> : null}
        >
          {log?.counts ? <LogCounts counts={log.counts} /> : null}
          {canWrite ? (
            <WeeklyLogForm key={week} programmeId={id} week={week} initial={log} />
          ) : log ? (
            <LogReadOnly log={log} />
          ) : (
            <EmptyState icon="calendar-clock" message="No session has been logged for this week." />
          )}
        </Card>
        <Card title={`Decisions recorded this week (${weekDecisions.length})`}>
          {weekDecisions.length ? (
            <ul style={{ margin: '0 0 16px', paddingLeft: 18, display: 'grid', gap: 8 }}>
              {weekDecisions.map((d) => (
                <li key={d.id}>
                  <div>{d.outcome}</div>
                  <div className="muted">
                    <LocalDate value={d.decided_on} />
                    {d.minute_ref ? ` · ${d.minute_ref}` : ''}
                    {raidLabel.get(d.raid_item_id) ? ` · ${raidLabel.get(d.raid_item_id)}` : ''}
                  </div>
                </li>
              ))}
            </ul>
          ) : (
            <div className="muted" style={{ marginBottom: 16 }}>None recorded in this week.</div>
          )}
          {canDecide ? <RecordDecisionForm key={week} raidItems={raid} /> : null}
        </Card>
      </div>

      <Card title={`Session history (${logs.length})`} pad={0}>
        {logs.length ? (
          <SortableTable
            initialSort={0}
            initialDir="desc"
            columns={[
              { label: 'Week', sortable: true },
              { label: 'Held', sortable: true },
              { label: 'Week RAG', sortable: true },
              { label: 'Overdue', align: 'right', sortable: true },
              { label: 'Due', align: 'right', sortable: true },
              { label: 'Awaiting decision', align: 'right', sortable: true },
              { label: 'RAID open', align: 'right', sortable: true },
            ]}
            rows={logs.map((l) => ({
              values: [
                l.week,
                l.session_held ? 1 : 0,
                l.week_rag,
                Number(l.counts?.overdue ?? 0),
                Number(l.counts?.due ?? 0),
                Number(l.counts?.awaiting_decision ?? 0),
                Number(l.counts?.raid_open ?? 0),
              ],
              cells: [
                <Link key="w" href={`/programmes/${id}/weekly?week=${l.week}`}>
                  Week {l.week}
                </Link>,
                l.session_held ? 'Yes' : 'No',
                <RagBadge key="r" rag={l.week_rag} />,
                String(l.counts?.overdue ?? '—'),
                String(l.counts?.due ?? '—'),
                String(l.counts?.awaiting_decision ?? '—'),
                String(l.counts?.raid_open ?? '—'),
              ],
            }))}
          />
        ) : (
          <EmptyState icon="calendar-clock" message="No weekly sessions logged yet." />
        )}
      </Card>
    </>
  );
}

const COUNT_LABELS: [string, string][] = [
  ['due', 'Due'],
  ['overdue', 'Overdue'],
  ['starting', 'Starting'],
  ['blocked', 'Blocked'],
  ['awaiting_decision', 'Awaiting decision'],
  ['raid_open', 'RAID open'],
  ['raid_due_review', 'RAID due review'],
];

// FR-WKS-04 calculated counts — engine-written on every save, display only
function LogCounts({ counts }: { counts: Record<string, number | boolean> }) {
  return (
    <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', marginBottom: 16 }}>
      {COUNT_LABELS.map(([k, label]) => (
        <div key={k}>
          <div className="mono" style={{ fontSize: 18 }}>{String(counts[k] ?? '—')}</div>
          <div className="muted">{label}</div>
        </div>
      ))}
      {counts.reduced_capacity ? <div className="muted">Reduced-capacity week</div> : null}
    </div>
  );
}

function LogReadOnly({ log }: { log: WeeklyLogRow }) {
  const list = (xs: unknown[]) =>
    xs.length ? (
      <ul style={{ margin: 0, paddingLeft: 18 }}>
        {xs.map((x, i) => (
          <li key={i}>{typeof x === 'string' ? x : JSON.stringify(x)}</li>
        ))}
      </ul>
    ) : (
      <span className="muted">—</span>
    );
  const block = (label: string, body: React.ReactNode) => (
    <div>
      <div className="sp-field-label">{label}</div>
      <div>{body}</div>
    </div>
  );
  return (
    <div style={{ display: 'grid', gap: 12 }}>
      {block('Session held', log.session_held ? 'Yes' : 'No')}
      {block('Completed this week', list(log.completed ?? []))}
      {block('Action items / planned next week', list(log.planned_next ?? []))}
      {block('Blockers', log.blockers || <span className="muted">—</span>)}
      {block('Session notes and decisions summary', log.decisions || <span className="muted">—</span>)}
    </div>
  );
}
