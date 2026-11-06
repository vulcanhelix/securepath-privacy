'use client';
import * as React from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { Field, Input, Select, Textarea } from '@/components/ui/forms';
// FR-TPL-04 add form + RPC helpers are the schedule's (W2-05) — reused, not rebuilt
import { AddActivityForm } from '../../schedule/AddActivityForm';
import { addActivity, updateActivity, type NewActivity } from '../../schedule/schedule-actions';
import type { ScheduleActivity, ScheduleWorkstream } from '../../schedule/types';

// ---------------------------------------------------------------------------
// W2-16 — linked activities + FR-TPL-04 programme item editor. Writes go ONLY
// through update_activity / add_activity (W1-05, SECURITY DEFINER, re-check
// the partner write roles, payload allowlist, FR-SCH-04 predecessor gate and
// recompute every CALC column). On error the RPC's message is shown and
// nothing is written — there is no direct-table fallback. Week/workstream
// repositioning and dependencies stay on the schedule screen.
// ---------------------------------------------------------------------------

const ACTIVITY_STATUSES = ['Not started', 'In progress', 'At risk', 'Blocked', 'Deferred', 'Complete'];

export function ItemActivities({
  programmeId,
  linked,
  allActivities,
  workstreams,
  leadNames,
  totalWeeks,
  canWrite,
}: {
  programmeId: string;
  linked: ScheduleActivity[];
  allActivities: ScheduleActivity[];
  workstreams: ScheduleWorkstream[];
  leadNames: Record<string, string>;
  totalWeeks: number;
  canWrite: boolean;
}) {
  const router = useRouter();
  const [editing, setEditing] = React.useState<string | null>(null);
  const [adding, setAdding] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);
  const [ok, setOk] = React.useState<string | null>(null);
  const wsName = new Map(workstreams.map((w) => [w.id, w.name]));
  const schedule = `/programmes/${programmeId}/schedule`;

  async function save(a: ScheduleActivity, payload: Record<string, unknown>) {
    if (!Object.keys(payload).length) {
      setEditing(null);
      return;
    }
    setBusy(true);
    setErr(null);
    setOk(null);
    const e = await updateActivity(browserClient(), a.id, payload);
    setBusy(false);
    if (e) {
      setErr(`${a.ref}: ${e}`);
      return;
    }
    setOk(`${a.ref} updated.`);
    setEditing(null);
    router.refresh();
  }

  async function add(n: NewActivity) {
    setBusy(true);
    setErr(null);
    setOk(null);
    const e = await addActivity(browserClient(), programmeId, n);
    setBusy(false);
    if (e) {
      setErr(e);
      return;
    }
    setOk(
      `Activity ${n.ref} added to the programme. Linking it to this finding needs a register-link RPC that does not exist yet.`
    );
    setAdding(false);
    router.refresh();
  }

  return (
    <Card
      title="Linked activities"
      pad={0}
      action={
        <span style={{ display: 'inline-flex', gap: 10, alignItems: 'center' }}>
          <Link href={schedule} className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
            Weeks &amp; dependencies on the schedule →
          </Link>
          {canWrite && !adding ? (
            <Button size="sm" variant="outline" icon="plus" onClick={() => setAdding(true)}>
              Add activity
            </Button>
          ) : null}
        </span>
      }
    >
      {err ? <div style={{ padding: '12px 16px 0' }}><Alert tone="err">{err}</Alert></div> : null}
      {ok ? <div style={{ padding: '12px 16px 0' }}><Alert tone="ok">{ok}</Alert></div> : null}
      {adding ? (
        <div style={{ padding: 16 }}>
          <AddActivityForm
            workstreams={workstreams}
            leadNames={leadNames}
            activities={allActivities}
            totalWeeks={totalWeeks}
            busy={busy}
            error={null}
            onSubmit={add}
            onCancel={() => setAdding(false)}
          />
        </div>
      ) : null}
      {linked.length ? (
        <div className="sp-table-scroll">
          <table className="sp-table">
            <thead>
              <tr>
                <th>Ref</th>
                <th>Activity</th>
                <th>Workstream</th>
                <th>Weeks</th>
                <th>Status</th>
                <th style={{ textAlign: 'right' }}>%</th>
                <th>RAG</th>
                <th>Due</th>
                {canWrite ? <th /> : null}
              </tr>
            </thead>
            <tbody>
              {linked.map((a) => (
                <React.Fragment key={a.id}>
                  <tr>
                    <td className="mono">{a.ref}</td>
                    <td style={{ maxWidth: 360 }}>
                      {a.text}
                      {a.comments ? (
                        <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{a.comments}</div>
                      ) : null}
                    </td>
                    <td className="muted">{a.workstream_id ? wsName.get(a.workstream_id) ?? '—' : '—'}</td>
                    <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>
                      {a.start_week}–{a.end_week}
                    </td>
                    <td><StatusPill status={a.status} /></td>
                    <td className="mono" style={{ textAlign: 'right' }}>{a.pct_complete}</td>
                    <td><RagBadge rag={a.rag} /></td>
                    <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>
                      {a.status === 'Deferred' && a.rescheduled_date ? a.rescheduled_date : a.due_date ?? '—'}
                    </td>
                    {canWrite ? (
                      <td>
                        <Button
                          size="sm"
                          variant="ghost"
                          icon="pencil"
                          onClick={() => setEditing(editing === a.id ? null : a.id)}
                        >
                          {editing === a.id ? 'Cancel' : 'Edit'}
                        </Button>
                      </td>
                    ) : null}
                  </tr>
                  {canWrite && editing === a.id ? (
                    <tr>
                      <td colSpan={9} style={{ background: 'var(--surface-card)' }}>
                        <ActivityEditForm activity={a} busy={busy} onSave={(p) => save(a, p)} />
                      </td>
                    </tr>
                  ) : null}
                </React.Fragment>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <EmptyState
          icon="calendar-range"
          message="No activities are linked to this finding. Closure needs every linked activity Complete (§9.4)."
        />
      )}
    </Card>
  );
}

/** update_activity merge payload — only changed fields are sent */
function ActivityEditForm({
  activity: a,
  busy,
  onSave,
}: {
  activity: ScheduleActivity;
  busy: boolean;
  onSave: (payload: Record<string, unknown>) => void;
}) {
  const [text, setText] = React.useState(a.text);
  const [status, setStatus] = React.useState(a.status);
  const [pct, setPct] = React.useState(String(a.pct_complete ?? 0));
  const [comments, setComments] = React.useState(a.comments ?? '');
  const [actual, setActual] = React.useState(a.actual_completion ?? '');
  const [resched, setResched] = React.useState(a.rescheduled_date ?? '');
  const [override, setOverride] = React.useState(a.dependency_override_reason ?? '');

  function submit(e: React.FormEvent) {
    e.preventDefault();
    const p: Record<string, unknown> = {};
    if (text.trim() && text !== a.text) p.text = text.trim();
    if (status !== a.status) p.status = status;
    if (pct !== String(a.pct_complete ?? 0) && pct !== '') p.pct_complete = Number(pct);
    if (comments !== (a.comments ?? '')) p.comments = comments;
    if (actual && actual !== (a.actual_completion ?? '')) p.actual_completion = actual;
    if (resched && resched !== (a.rescheduled_date ?? '')) p.rescheduled_date = resched;
    if (override.trim() && override !== (a.dependency_override_reason ?? ''))
      p.dependency_override_reason = override.trim();
    onSave(p);
  }

  return (
    <form onSubmit={submit} style={{ padding: 12, display: 'grid', gap: 10, gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' }}>
      <div style={{ gridColumn: '1 / -1' }}>
        <Field label="Activity">
          <Input value={text} onChange={(e) => setText(e.target.value)} />
        </Field>
      </div>
      <Field label="Status">
        <Select value={status} onChange={(e) => setStatus(e.target.value)}>
          {ACTIVITY_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        </Select>
      </Field>
      <Field label="% complete">
        <Input type="number" min={0} max={100} value={pct} onChange={(e) => setPct(e.target.value)} />
      </Field>
      <Field label="Actual completion">
        <Input type="date" value={actual} onChange={(e) => setActual(e.target.value)} />
      </Field>
      <Field label="Rescheduled date" hint="Required when Deferred">
        <Input type="date" value={resched} onChange={(e) => setResched(e.target.value)} />
      </Field>
      <div style={{ gridColumn: '1 / -1' }}>
        <Field label="Dependency override reason" hint="Needed to start with incomplete predecessors (FR-SCH-04)">
          <Input value={override} onChange={(e) => setOverride(e.target.value)} />
        </Field>
      </div>
      <div style={{ gridColumn: '1 / -1' }}>
        <Field label="Comments">
          <Textarea rows={2} value={comments} onChange={(e) => setComments(e.target.value)} />
        </Field>
      </div>
      <div style={{ gridColumn: '1 / -1' }}>
        <Button size="sm" type="submit" icon="check" disabled={busy}>
          {busy ? 'Saving…' : 'Save'}
        </Button>
      </div>
    </form>
  );
}
