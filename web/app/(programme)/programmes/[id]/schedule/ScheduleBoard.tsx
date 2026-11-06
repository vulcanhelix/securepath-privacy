'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field, Input, Select } from '@/components/ui/forms';
import { Gantt } from './Gantt';
import { ActivityTable, ACTIVITY_STATUSES } from './ActivityTable';
import { ActivityDetail } from './ActivityDetail';
import { AddActivityForm } from './AddActivityForm';
import { updateActivity, reorderActivity, addActivity, type NewActivity } from './schedule-actions';
import type {
  RegisterLink,
  ScheduleActivity,
  ScheduleDep,
  ScheduleEvidenceCount,
  SchedulePhase,
  ScheduleWorkstream,
} from './types';

// ---------------------------------------------------------------------------
// W2-05 — schedule board: FR-SCH-01 view switch (Gantt / list / by-lead) +
// filters (workstream, lead, status, week window), FR-SCH-04 override capture,
// FR-SCH-05 complete → evidence prompt, deferred rescheduled_date capture,
// FR-TPL-04 add/reposition writes through the W1-05 lifecycle RPCs under the
// caller's JWT.
// ---------------------------------------------------------------------------

type View = 'gantt' | 'table' | 'lead';

interface PendingChange {
  activity: ScheduleActivity;
  targetStatus: string;
}

export function ScheduleBoard({
  programmeId,
  canWrite,
  currentWeek,
  totalWeeks,
  startDate,
  reducedWeeks,
  phases,
  workstreams,
  activities,
  deps,
  registerLinks,
  evidenceCounts,
  leadNames,
}: {
  programmeId: string;
  canWrite: boolean;
  currentWeek: number | null;
  totalWeeks: number;
  startDate: string;
  reducedWeeks: number[];
  phases: SchedulePhase[];
  workstreams: ScheduleWorkstream[];
  activities: ScheduleActivity[];
  deps: ScheduleDep[];
  registerLinks: RegisterLink[];
  evidenceCounts: ScheduleEvidenceCount[];
  leadNames: Record<string, string>;
}) {
  const router = useRouter();
  const supabase = browserClient();
  const [view, setView] = React.useState<View>('gantt');
  const [fWs, setFWs] = React.useState('');
  const [fLead, setFLead] = React.useState('');
  const [fStatus, setFStatus] = React.useState('');
  const [fFrom, setFFrom] = React.useState<number | ''>('');
  const [fTo, setFTo] = React.useState<number | ''>('');
  const [selectedId, setSelectedId] = React.useState<string | null>(null);
  const [pending, setPending] = React.useState<PendingChange | null>(null);
  const [overrideReason, setOverrideReason] = React.useState('');
  const [rescheduled, setRescheduled] = React.useState('');
  const [showAdd, setShowAdd] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string; info?: string }>({});

  // ---- FR-SCH-01 filters ---------------------------------------------------
  const filtered = React.useMemo(
    () =>
      activities.filter((a) => {
        if (fWs === '__none__' ? a.workstream_id != null : fWs && a.workstream_id !== fWs)
          return false;
        if (fLead && !(a.leads ?? []).includes(fLead)) return false;
        if (fStatus && a.status !== fStatus) return false;
        if (fFrom !== '' && a.end_week < fFrom) return false;
        if (fTo !== '' && a.start_week > fTo) return false;
        return true;
      }),
    [activities, fWs, fLead, fStatus, fFrom, fTo]
  );

  const leadOptions = React.useMemo(() => {
    const ids = new Set<string>();
    for (const a of activities) for (const l of a.leads ?? []) ids.add(l);
    return [...ids].map((id) => ({ id, name: leadNames[id] ?? 'Unresolvable lead' }));
  }, [activities, leadNames]);

  // ---- write actions -------------------------------------------------------
  const predsOf = React.useCallback(
    (a: ScheduleActivity) =>
      deps
        .filter((d) => d.activity_id === a.id)
        .map((d) => activities.find((x) => x.id === d.depends_on_activity_id))
        .filter(Boolean) as ScheduleActivity[],
    [deps, activities]
  );
  const openPreds = (a: ScheduleActivity) =>
    predsOf(a).filter((p) => p.status !== 'Complete').length;

  /** status select → maybe collect extras first (FR-SCH-04 / Deferred date) */
  function requestStatus(a: ScheduleActivity, target: string) {
    if (target === a.status) return;
    setOverrideReason('');
    setRescheduled('');
    setMsg({});
    const needsReason = a.status === 'Not started' && target !== 'Not started' && openPreds(a) > 0;
    const needsDate = target === 'Deferred' && !a.rescheduled_date;
    if (needsReason || needsDate) {
      setPending({ activity: a, targetStatus: target });
    } else {
      void commitStatus(a, target, {});
    }
  }

  async function commitStatus(
    a: ScheduleActivity,
    target: string,
    extra: { dependency_override_reason?: string; rescheduled_date?: string }
  ) {
    setBusy(true);
    setMsg({});
    const payload: Record<string, unknown> = { status: target };
    if (extra.dependency_override_reason) payload.dependency_override_reason = extra.dependency_override_reason;
    if (extra.rescheduled_date) payload.rescheduled_date = extra.rescheduled_date;
    const err = await updateActivity(supabase, a.id, payload);
    setBusy(false);
    setPending(null);
    if (err) {
      setMsg({ err });
      return;
    }
    // FR-SCH-05: complete + evidence required + none uploaded → prompt
    const ev = evidenceCounts.find((e) => e.activityId === a.id);
    if (target === 'Complete' && a.evidence_required && !(ev && ev.total > 0)) {
      setMsg({
        info: `${a.ref} marked Complete — this activity requires evidence and none is uploaded yet. Attach it under Evidence.`,
      });
    } else {
      setMsg({ ok: `${a.ref} → ${target}.` });
    }
    router.refresh();
  }

  function confirmPending() {
    if (!pending) return;
    const a = pending.activity;
    const needsReason = a.status === 'Not started' && pending.targetStatus !== 'Not started' && openPreds(a) > 0;
    const needsDate = pending.targetStatus === 'Deferred' && !a.rescheduled_date;
    if (needsReason && !overrideReason.trim()) {
      setMsg({ err: 'FR-SCH-04: a dependency override reason is required to start with incomplete predecessors.' });
      return;
    }
    if (needsDate && !rescheduled) {
      setMsg({ err: 'A rescheduled date is required for a deferred activity.' });
      return;
    }
    void commitStatus(a, pending.targetStatus, {
      dependency_override_reason: overrideReason.trim() || undefined,
      rescheduled_date: rescheduled || undefined,
    });
  }

  async function onReorder(a: ScheduleActivity, start: number, end: number, ws: string | null) {
    setBusy(true);
    setMsg({});
    const err = await reorderActivity(supabase, a.id, start, end, ws);
    setBusy(false);
    if (err) {
      setMsg({ err });
      return;
    }
    setMsg({ ok: `${a.ref} moved to weeks ${start}–${end}; dates recalculated.` });
    router.refresh();
  }

  const [addErr, setAddErr] = React.useState<string | null>(null);
  async function onAdd(a: NewActivity) {
    setBusy(true);
    setAddErr(null);
    const err = await addActivity(supabase, programmeId, a);
    setBusy(false);
    if (err) {
      setAddErr(err);
      return;
    }
    setShowAdd(false);
    setMsg({ ok: `Activity ${a.ref} added.` });
    router.refresh();
  }

  // ---- by-lead grouping (each lead gets its bucket; unassigned last) -------
  const byLead = React.useMemo(() => {
    const m = new Map<string, ScheduleActivity[]>();
    for (const a of filtered) {
      const ls = a.leads?.length ? a.leads : ['__none__'];
      for (const l of ls) {
        const arr = m.get(l);
        if (arr) arr.push(a);
        else m.set(l, [a]);
      }
    }
    return [...m.entries()].sort(([x], [y]) =>
      (leadNames[x] ?? 'zzz').localeCompare(leadNames[y] ?? 'zzz')
    );
  }, [filtered, leadNames]);

  const selected = activities.find((a) => a.id === selectedId) ?? null;
  const filteredIds = new Set(filtered.map((a) => a.id));

  return (
    <>
      {/* view switch + filters */}
      <div className="sp-sch-toolbar">
        <div className="sp-sch-views" role="tablist" aria-label="Schedule view">
          {(
            [
              ['gantt', 'Gantt'],
              ['table', 'List'],
              ['lead', 'By lead'],
            ] as [View, string][]
          ).map(([v, label]) => (
            <button
              key={v}
              type="button"
              role="tab"
              aria-selected={view === v}
              className={'sp-sch-viewbtn' + (view === v ? ' is-active' : '')}
              onClick={() => setView(v)}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="sp-sch-filters">
          <Select value={fWs} onChange={(e) => setFWs(e.target.value)} aria-label="filter by workstream">
            <option value="">All workstreams</option>
            <option value="__none__">No workstream</option>
            {workstreams.map((w) => (
              <option key={w.id} value={w.id}>{w.name}</option>
            ))}
          </Select>
          <Select value={fLead} onChange={(e) => setFLead(e.target.value)} aria-label="filter by lead">
            <option value="">All leads</option>
            {leadOptions.map((l) => (
              <option key={l.id} value={l.id}>{l.name}</option>
            ))}
          </Select>
          <Select value={fStatus} onChange={(e) => setFStatus(e.target.value)} aria-label="filter by status">
            <option value="">All statuses</option>
            {ACTIVITY_STATUSES.map((s) => (
              <option key={s} value={s}>{s}</option>
            ))}
          </Select>
          <span className="sp-sch-win">
            weeks
            <Input
              type="number" min={1} max={totalWeeks} value={fFrom}
              onChange={(e) => setFFrom(e.target.value === '' ? '' : Number(e.target.value))}
              placeholder="from" aria-label="from week"
            />
            –
            <Input
              type="number" min={1} max={totalWeeks} value={fTo}
              onChange={(e) => setFTo(e.target.value === '' ? '' : Number(e.target.value))}
              placeholder="to" aria-label="to week"
            />
          </span>
          {canWrite ? (
            <Button size="sm" variant="outline" icon="plus" onClick={() => setShowAdd((s) => !s)}>
              Add activity
            </Button>
          ) : null}
        </div>
      </div>

      {msg.err ? <Alert tone="err">{msg.err}</Alert> : null}
      {msg.ok ? <Alert tone="ok">{msg.ok}</Alert> : null}
      {msg.info ? (
        <Alert tone="info">
          {msg.info}{' '}
          <a href={`/programmes/${programmeId}/evidence`}>Open evidence →</a>
        </Alert>
      ) : null}

      {/* pending status change — FR-SCH-04 reason / Deferred date capture */}
      {pending ? (
        <Card pad={20} style={{ marginBottom: 20 }}>
          <div className="sp-kpi-label" style={{ marginBottom: 10 }}>
            Set {pending.activity.ref} → {pending.targetStatus}
          </div>
          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'flex-end' }}>
            {pending.activity.status === 'Not started' &&
            pending.targetStatus !== 'Not started' &&
            openPreds(pending.activity) > 0 ? (
              <Field
                label="Dependency override reason"
                required
                hint={`${openPreds(pending.activity)} predecessor(s) incomplete — FR-SCH-04 requires a recorded reason.`}
              >
                <Input
                  value={overrideReason}
                  onChange={(e) => setOverrideReason(e.target.value)}
                  placeholder="Why this may start now"
                  style={{ minWidth: 280 }}
                />
              </Field>
            ) : null}
            {pending.targetStatus === 'Deferred' && !pending.activity.rescheduled_date ? (
              <Field label="Rescheduled date" required hint="Deferred activities carry the new due date.">
                <Input type="date" value={rescheduled} onChange={(e) => setRescheduled(e.target.value)} />
              </Field>
            ) : null}
            <Button size="sm" disabled={busy} onClick={confirmPending} cta>
              Confirm
            </Button>
            <Button size="sm" variant="ghost" disabled={busy} onClick={() => setPending(null)}>
              Cancel
            </Button>
          </div>
        </Card>
      ) : null}

      {showAdd && canWrite ? (
        <AddActivityForm
          workstreams={workstreams}
          leadNames={leadNames}
          activities={activities}
          totalWeeks={totalWeeks}
          busy={busy}
          error={addErr}
          onSubmit={onAdd}
          onCancel={() => {
            setShowAdd(false);
            setAddErr(null);
          }}
        />
      ) : null}

      {filtered.length === 0 ? (
        <Card>
          <EmptyState
            icon="calendar-range"
            message={
              activities.length === 0
                ? 'No activities on this programme yet.'
                : 'No activities match the current filters.'
            }
          />
        </Card>
      ) : view === 'gantt' ? (
        <Card pad={0} style={{ overflow: 'hidden' }}>
          <Gantt
            activities={filtered}
            phases={phases}
            workstreams={workstreams}
            deps={deps}
            totalWeeks={totalWeeks}
            currentWeek={currentWeek}
            reducedWeeks={reducedWeeks}
            leadNames={leadNames}
            selectedId={selectedId}
            onSelect={setSelectedId}
          />
          <div className="sp-gantt-legend">
            <span><i className="sp-gantt-lg" style={{ background: 'var(--pass)' }} /> on track / complete</span>
            <span><i className="sp-gantt-lg" style={{ background: 'var(--warn)' }} /> at risk / amber</span>
            <span><i className="sp-gantt-lg" style={{ background: 'var(--fail)' }} /> overdue / red</span>
            <span><i className="sp-gantt-lg sp-gantt-lg-ms" /> milestone</span>
            <span><i className="sp-gantt-lg sp-gantt-lg-rc" /> reduced-capacity week</span>
            <span><i className="sp-gantt-lg sp-gantt-lg-now" /> current week</span>
            <span className="muted">⇐n / n⇒ hover chip: predecessors / dependents · click a bar for arrows</span>
          </div>
        </Card>
      ) : view === 'table' ? (
        <Card pad={0}>
          <ActivityTable
            activities={filtered}
            workstreams={workstreams}
            deps={deps}
            leadNames={leadNames}
            canWrite={canWrite}
            busy={busy}
            selectedId={selectedId}
            onSelect={setSelectedId}
            onStatus={requestStatus}
          />
        </Card>
      ) : (
        byLead.map(([lead, list]) => (
          <Card
            key={lead}
            title={lead === '__none__' ? 'Unassigned' : leadNames[lead] ?? 'Lead'}
            pad={0}
            style={{ marginBottom: 20 }}
          >
            <ActivityTable
              activities={list}
              workstreams={workstreams}
              deps={deps}
              leadNames={leadNames}
              canWrite={canWrite}
              busy={busy}
              selectedId={selectedId}
              onSelect={setSelectedId}
              onStatus={requestStatus}
            />
          </Card>
        ))
      )}

      {/* selected record — only when it survives the filter (or always; keep always so a Gantt select on a filtered-out item still shows) */}
      {selected && filteredIds.has(selected.id) ? (
        <ActivityDetail
          activity={selected}
          workstreams={workstreams}
          deps={deps}
          activities={activities}
          registerLinks={registerLinks}
          evidenceCounts={evidenceCounts}
          leadNames={leadNames}
          totalWeeks={totalWeeks}
          canWrite={canWrite}
          busy={busy}
          onReorder={onReorder}
          onClose={() => setSelectedId(null)}
        />
      ) : null}

      <p className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 20 }}>
        Week 1 began {startDate}. All dates, weeks and RAG values are engine-calculated server-side
        (§9.1/§9.2) — the schedule only renders them.
      </p>
    </>
  );
}
