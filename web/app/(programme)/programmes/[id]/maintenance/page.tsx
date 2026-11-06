import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Input } from '@/components/ui/forms';
import {
  MaintenanceBoard,
  type TaskTemplate,
  type TaskInstance,
  type AcceptedEvidence,
  type Provider,
} from './MaintenanceBoard';
import { GenerateMonth } from './GenerateMonth';
import { Checklists, type ChecklistRow } from './Checklists';

export const dynamic = 'force-dynamic';

// W2-10 — Monthly Maintenance (spec §8.9 screen 09; FR-MNT-01..10,
// FR-QTR-01/02; W1-03 cadence engine RPCs in 20261106000007_cadence_gen.sql).
// Every read runs under the caller's JWT (RLS); every write is an RPC from
// the client components. Due dates, windows and overdue counts come from the
// server (maintenance_task_due at generation, maintenance_period_status) —
// nothing date-related is computed in the browser.
//
// UI gates are hints only; the RPCs re-check their own role sets:
//   generate_maintenance_month / generate_checklist → can_run_cadence
//     (programme WRITE roles OR AO/alternate; can_run_cadence itself is not
//     granted, so the UI mirrors it with has_programme_role + is_ao_or_alternate)
//   status / complete / provider RPCs → has_mti_role (the mti_update set)

const WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];
const MTI_ROLES = [...WRITE_ROLES, 'workstream_lead', 'external_provider', 'accountable_officer'];

type PeriodStatus = {
  total: number;
  complete: number;
  exception: number;
  in_progress: number;
  pending: number;
  awaiting_provider: number;
  overdue: number;
};

type OpenFeeding = { code: string; task: string; status: string; due_date: string | null };

// month arithmetic on 'YYYY-MM' strings — period navigation only, never due dates
function shiftMonth(m: string, delta: number) {
  const [y, mo] = m.split('-').map(Number);
  const idx = y * 12 + (mo - 1) + delta;
  return `${Math.floor(idx / 12)}-${String((idx % 12) + 1).padStart(2, '0')}`;
}
const monthLabel = (m: string) =>
  new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export default async function MaintenancePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const raw = Array.isArray(sp.month) ? sp.month[0] : sp.month;

  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const nowIso = new Date().toISOString();
  const currentMonth = nowIso.slice(0, 7);
  const month = raw && /^\d{4}-(0[1-9]|1[0-2])$/.test(raw) ? raw : currentMonth;
  const year = month.slice(0, 4);
  const quarter = `${year}-Q${Math.floor((Number(month.slice(5, 7)) - 1) / 3) + 1}`;
  const base = `/programmes/${id}`;

  const [
    { data: templatesRaw, error: tplErr },
    { data: statusRaw, error: statusErr },
    { data: feedingRaw, error: feedingErr },
    { data: canWrite },
    { data: canActRaw },
    isAo,
    { data: providersRaw },
    { data: checklistsRaw, error: clErr },
    { data: evidenceRaw },
  ] = await Promise.all([
    supabase
      .from('maintenance_task_templates')
      .select('id, code, task, owner_role, input_from_label, input_from_provider_id, evidence_produced, feeds, active, sort')
      .eq('programme_id', id)
      .order('sort')
      .order('code'),
    supabase.rpc('maintenance_period_status', { p_programme: id, p_month: `${month}-01` }),
    supabase.rpc('report_open_feeding_tasks', { p_programme: id, p_period: month }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: WRITE_ROLES }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: MTI_ROLES }),
    ctx.role.isAoOrAlternate(ctx.client.id),
    supabase
      .from('external_providers')
      .select('id, name, kind, contact_email, channel, active')
      .eq('client_org_id', ctx.client.id)
      .order('name'),
    supabase
      .from('checklist_instances')
      .select('id, kind, period, items, summary, generated_on')
      .eq('programme_id', id)
      .order('period', { ascending: false }),
    supabase
      .from('evidence_items')
      .select('id, evidence_ref, link, file_key, uploaded_at, review_stage')
      .eq('programme_id', id)
      .order('uploaded_at', { ascending: false })
      .limit(500),
  ]);

  const templates = (templatesRaw ?? []) as TaskTemplate[];
  const tplIds = templates.map((t) => t.id);

  // the month's instances (RLS: mti_read)
  let instances: TaskInstance[] = [];
  let instErr: string | null = null;
  if (tplIds.length) {
    const { data, error } = await supabase
      .from('maintenance_task_instances')
      .select(
        'id, task_template_id, period, due_date, task_window, assignee, status, evidence_id, evidence_exempt_reason, exception_reason, exception_raid_item_id, completed_on, provider_id, provider_requested_at, awaiting_provider_input, provider_input_log'
      )
      .in('task_template_id', tplIds)
      .eq('period', month)
      .order('due_date', { ascending: true });
    instances = (data ?? []) as TaskInstance[];
    if (error) instErr = error.message;
  }

  // "accepted evidence" = the §8.4 acceptance record in the append-only
  // evidence_reviews ledger (same definition the completion trigger uses)
  const evidenceAll = (evidenceRaw ?? []) as (AcceptedEvidence & { review_stage: string })[];
  let accepted: AcceptedEvidence[] = [];
  if (evidenceAll.length) {
    const { data: reviews } = await supabase
      .from('evidence_reviews')
      .select('evidence_item_id')
      .in('evidence_item_id', evidenceAll.map((e) => e.id))
      .eq('stage', 'accept')
      .eq('decision', 'accepted');
    const ok = new Set((reviews ?? []).map((r) => r.evidence_item_id as string));
    accepted = evidenceAll.filter((e) => ok.has(e.id));
  }
  const evidenceRefs = Object.fromEntries(
    evidenceAll.map((e) => [e.id, e.evidence_ref ?? null] as const)
  ) as Record<string, string | null>;

  // assignee display names — RLS-hidden users fall back to a dash
  const assigneeIds = [...new Set(instances.map((i) => i.assignee).filter(Boolean) as string[])];
  const { data: users } = assigneeIds.length
    ? await supabase.from('users').select('id, full_name, email').in('id', assigneeIds)
    : { data: [] as { id: string; full_name: string | null; email: string }[] };
  const names = Object.fromEntries(
    (users ?? []).map((u) => [u.id as string, (u.full_name as string) || (u.email as string)])
  ) as Record<string, string>;

  const status = (Array.isArray(statusRaw) ? statusRaw[0] : statusRaw) as PeriodStatus | null | undefined;
  const feeding = (feedingRaw ?? []) as OpenFeeding[];
  const canRun = canWrite === true || isAo;
  const canAct = canActRaw === true || isAo;

  const tile = (n: number | undefined, label: string, color?: string) => (
    <Card pad={16} style={{ flex: '1 1 120px', marginBottom: 0 }}>
      <div className="mono" style={{ fontSize: 28, color }}>{n ?? 0}</div>
      <div className="muted">{label}</div>
    </Card>
  );

  return (
    <>
      <PageHeader
        title="Monthly maintenance"
        eyebrow={ctx.programme.name}
        meta={`${monthLabel(month)} · ${status?.total ?? instances.length} task${(status?.total ?? instances.length) === 1 ? '' : 's'} · due dates from the cadence engine`}
        actions={
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <Link
              className="sp-btn sp-btn--ghost sp-btn--sm"
              href={`${base}/maintenance?month=${shiftMonth(month, -1)}`}
              aria-label="Previous month"
            >
              <span>← Prev</span>
            </Link>
            <form method="get" style={{ display: 'flex', gap: 6 }}>
              <Input type="month" name="month" defaultValue={month} aria-label="Month" />
              <Button size="sm" variant="outline" type="submit">Go</Button>
            </form>
            <Link
              className="sp-btn sp-btn--ghost sp-btn--sm"
              href={`${base}/maintenance?month=${shiftMonth(month, 1)}`}
              aria-label="Next month"
            >
              <span>Next →</span>
            </Link>
            {month !== currentMonth ? (
              <Link className="sp-btn sp-btn--ghost sp-btn--sm" href={`${base}/maintenance`}>
                <span>This month</span>
              </Link>
            ) : null}
          </div>
        }
      />

      {/* FR-MNT-07 — report-feeding tasks still open block the monthly report */}
      {feedingErr ? (
        <Alert tone="err">{`Could not check the report gate: ${feedingErr.message}`}</Alert>
      ) : feeding.length ? (
        <Alert tone="err">
          <strong>
            {feeding.length} task{feeding.length === 1 ? '' : 's'} feeding the {monthLabel(month)} report{' '}
            {feeding.length === 1 ? 'is' : 'are'} still open
          </strong>{' '}
          — the monthly report cannot go to AO review until {feeding.length === 1 ? 'it is' : 'they are'} Complete,
          unless the programme lead records a gate reason (it prints in the report). Open:{' '}
          {feeding.map((f) => `${f.code} (${f.status})`).join(', ')}.
        </Alert>
      ) : null}

      {statusErr ? <Alert tone="err">{`Could not load the period summary: ${statusErr.message}`}</Alert> : null}
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', margin: '0 0 20px' }}>
        {tile(status?.total, 'Tasks')}
        {tile(status?.complete, 'Complete', 'var(--pass)')}
        {tile(status?.in_progress, 'In progress')}
        {tile(status?.pending, 'Pending')}
        {tile(status?.awaiting_provider, 'Awaiting provider', 'var(--warn)')}
        {tile(status?.exception, 'Exceptions', 'var(--fail)')}
        {tile(status?.overdue, 'Overdue', 'var(--fail)')}
      </div>

      {canRun ? (
        <Card title="Generate tasks" pad={20} action={<Badge tone="neutral">idempotent</Badge>}>
          <GenerateMonth programmeId={id} month={month} label={monthLabel(month)} />
        </Card>
      ) : null}

      {tplErr ? <Alert tone="err">{`Could not load maintenance templates: ${tplErr.message}`}</Alert> : null}
      {instErr ? <Alert tone="err">{`Could not load this month's tasks: ${instErr}`}</Alert> : null}

      <Card title={`Tasks — ${monthLabel(month)}`} pad={0} style={{ marginTop: 16 }}>
        {instances.length ? (
          <MaintenanceBoard
            templates={templates}
            instances={instances}
            accepted={accepted}
            evidenceRefs={evidenceRefs}
            providers={(providersRaw ?? []) as Provider[]}
            names={names}
            canAct={canAct}
            base={base}
          />
        ) : (
          !instErr && (
            <EmptyState
              icon="refresh-cw"
              message={
                templates.length
                  ? `No tasks generated for ${monthLabel(month)} yet.${canRun ? ' Use “Generate this month” above.' : ' They are generated on the first business day of the month.'}`
                  : 'This programme has no maintenance task templates yet — they are applied from the framework template.'
              }
            />
          )
        )}
      </Card>

      <Card title="Quarterly & annual checklists" pad={20} style={{ marginTop: 16 }}>
        {clErr ? <Alert tone="err">{`Could not load checklists: ${clErr.message}`}</Alert> : null}
        <Checklists
          programmeId={id}
          rows={(checklistsRaw ?? []) as ChecklistRow[]}
          canRun={canRun}
          defaultQuarter={quarter}
          defaultYear={year}
          evidenceRefs={evidenceRefs}
          base={base}
        />
      </Card>

      <p className="muted" style={{ marginTop: 8 }}>
        Completions, provider inputs and exceptions are audited. A task is Complete only with accepted
        evidence or a recorded reason none applies (FR-MNT-05); exceptions raise a RAID issue (FR-MNT-06).
      </p>
    </>
  );
}
