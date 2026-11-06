import './schedule.css';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { WeekBadge } from '@/components/ui/WeekBadge';
import { ScheduleBoard } from './ScheduleBoard';
import type {
  ScheduleActivity,
  ScheduleDep,
  SchedulePhase,
  ScheduleWorkstream,
  ScheduleEvidenceCount,
  RegisterLink,
} from './types';

export const dynamic = 'force-dynamic';

// ---------------------------------------------------------------------------
// W2-05 — spec screen 02 (§8.2, FR-SCH-01..06): activity schedule + Gantt.
// Server half: one context resolve, then the schedule's four datasets under
// the caller's JWT (RLS decides visibility). All week/date values come from
// server columns + §9.1 RPCs — nothing client-side recomputes them.
// ---------------------------------------------------------------------------

const ACTIVITY_COLS =
  'id, ref, text, workstream_id, phase, start_week, end_week, milestone, ' +
  'evidence_required, status, pct_complete, actual_completion, flag, comments, ' +
  'recovery_date, dependency_override_reason, rescheduled_date, start_date, ' +
  'due_date, month, rag, leads';

// the update_activity / reorder_activity / add_activity role list (W1-05)
const WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];

export default async function SchedulePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const today = new Date().toISOString().slice(0, 10);

  const [
    { data: currentWeek },
    { data: prog },
    { data: phases },
    { data: workstreams },
    { data: activities },
    { data: evidence },
    { data: canWrite },
  ] = await Promise.all([
    // §9.1 engine calc — the only week marker the UI is allowed to show
    supabase.rpc('programme_week', { p_programme: id, p_date: today }),
    // reduced_capacity_weeks + start_date aren't in the shared context select
    supabase
      .from('programmes')
      .select('reduced_capacity_weeks, start_date, total_weeks')
      .eq('id', id)
      .single(),
    supabase
      .from('phases')
      .select('id, number, name, start_week, end_week')
      .eq('programme_id', id)
      .order('number'),
    supabase
      .from('workstreams')
      .select('id, name, accountable_lead')
      .eq('programme_id', id)
      .order('name'),
    supabase
      .from('activities')
      .select(ACTIVITY_COLS)
      .eq('programme_id', id)
      // #92: retired activities (FR-TPL-04) are out of scope and frozen
      .eq('active', true)
      .order('start_week')
      .order('ref'),
    supabase
      .from('evidence_items')
      .select('id, activity_id, review_stage')
      .eq('programme_id', id),
    // mirror of the W1-05 write gate — hides controls it would reject anyway
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: WRITE_ROLES }),
  ]);

  const acts = (activities ?? []) as unknown as ScheduleActivity[];
  const actIds = acts.map((a) => a.id);

  // intra-programme deps only (trg_activity_dep_scope), so filtering on the
  // activity leg returns every edge of the programme DAG
  const [{ data: deps }, { data: regLinks }, { data: regItems }] = await Promise.all([
    actIds.length
      ? supabase
          .from('activity_deps')
          .select('activity_id, depends_on_activity_id')
          .in('activity_id', actIds)
      : { data: [] as ScheduleDep[] },
    actIds.length
      ? supabase
          .from('register_item_activities')
          .select('activity_id, register_item_id')
          .in('activity_id', actIds)
      : { data: [] as { activity_id: string; register_item_id: string }[] },
    supabase.from('register_items').select('id, ref, status').eq('programme_id', id).eq('active', true),
  ]);
  const actIdSet = new Set(actIds);
  const regIdSet = new Set((regItems ?? []).map((r) => r.id as string));

  // lead name resolution — users_self only exposes the caller's own row and
  // (partner_admin) their partner's users; unresolvable leads fall back to a
  // shortened id in the board.
  const leadIds = [
    ...new Set([
      ...acts.flatMap((a) => a.leads ?? []),
      ...(workstreams ?? []).map((w) => w.accountable_lead as string | null).filter(Boolean),
    ]),
  ] as string[];
  const { data: users } = leadIds.length
    ? await supabase.from('users').select('id, full_name, email').in('id', leadIds)
    : { data: [] as { id: string; full_name: string | null; email: string }[] };

  // edges to a retired predecessor/successor and links to a retired finding
  // are dropped with the retired rows themselves (#92)
  const liveDeps = ((deps ?? []) as ScheduleDep[]).filter(
    (d) => actIdSet.has(d.activity_id) && actIdSet.has(d.depends_on_activity_id)
  );
  const registerLinks: RegisterLink[] = (regLinks ?? [])
    .filter((l) => regIdSet.has(l.register_item_id as string))
    .map((l) => ({
      activityId: l.activity_id as string,
      registerItemId: l.register_item_id as string,
      ref:
        ((regItems ?? []).find((r) => r.id === l.register_item_id)?.ref as string | undefined) ??
        null,
      status:
        ((regItems ?? []).find((r) => r.id === l.register_item_id)?.status as string | undefined) ??
        null,
    }));

  const evidenceCounts: ScheduleEvidenceCount[] = Object.values(
    (evidence ?? []).reduce<Record<string, ScheduleEvidenceCount>>((acc, e) => {
      const k = e.activity_id as string | null;
      if (!k) return acc;
      const row = (acc[k] ??= { activityId: k, total: 0, decided: 0 });
      row.total += 1;
      if (e.review_stage === 'decided') row.decided += 1;
      return acc;
    }, {})
  );

  return (
    <>
      <PageHeader
        title="Activity schedule"
        eyebrow={ctx.programme.name}
        meta={
          <>
            {ctx.client.name}
            {ctx.client.jurisdiction ? ` · ${ctx.client.jurisdiction}` : ''} · started{' '}
            {ctx.programme.start_date}
          </>
        }
        actions={
          <WeekBadge
            week={(currentWeek as number | null) ?? null}
            total={ctx.programme.total_weeks}
          />
        }
      />
      <ScheduleBoard
        programmeId={id}
        canWrite={canWrite === true}
        currentWeek={(currentWeek as number | null) ?? null}
        totalWeeks={(prog?.total_weeks as number | undefined) ?? ctx.programme.total_weeks}
        startDate={(prog?.start_date as string | undefined) ?? ctx.programme.start_date}
        reducedWeeks={(prog?.reduced_capacity_weeks as number[] | undefined) ?? []}
        phases={(phases ?? []) as SchedulePhase[]}
        workstreams={(workstreams ?? []) as ScheduleWorkstream[]}
        activities={acts}
        deps={liveDeps}
        registerLinks={registerLinks}
        evidenceCounts={evidenceCounts}
        leadNames={Object.fromEntries(
          (users ?? []).map((u) => [u.id as string, (u.full_name as string) || (u.email as string)])
        )}
      />
    </>
  );
}
