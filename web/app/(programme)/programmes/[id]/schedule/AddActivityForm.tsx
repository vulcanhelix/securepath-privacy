'use client';
import * as React from 'react';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Field, Input, Select, Checkbox } from '@/components/ui/forms';
import type { ScheduleActivity, ScheduleWorkstream } from './types';
import type { NewActivity } from './schedule-actions';

// ---------------------------------------------------------------------------
// W2-05 — FR-TPL-04 add-activity form (add_activity RPC, partner write roles).
// Predecessors render as a scrollable checkbox list — same-programme
// validation + cycle guard live in the RPC (trg_activity_dep_cycle).
// ---------------------------------------------------------------------------

export function AddActivityForm({
  workstreams,
  leadNames,
  activities,
  totalWeeks,
  busy,
  error,
  onSubmit,
  onCancel,
}: {
  workstreams: ScheduleWorkstream[];
  /** users the caller can resolve (users RLS) — the only selectable leads */
  leadNames: Record<string, string>;
  activities: ScheduleActivity[];
  totalWeeks: number;
  busy: boolean;
  error: string | null;
  onSubmit: (a: NewActivity) => void;
  onCancel: () => void;
}) {
  const [ref, setRef] = React.useState('');
  const [text, setText] = React.useState('');
  const [ws, setWs] = React.useState('');
  const [start, setStart] = React.useState(1);
  const [end, setEnd] = React.useState(1);
  const [milestone, setMilestone] = React.useState(false);
  const [evReq, setEvReq] = React.useState(false);
  const [preds, setPreds] = React.useState<string[]>([]);
  const [leads, setLeads] = React.useState<string[]>([]);
  const weekOpts = Array.from({ length: totalWeeks }, (_, i) => i + 1);
  const leadOpts = Object.entries(leadNames).sort(([, x], [, y]) => x.localeCompare(y));

  const togglePred = (id: string) =>
    setPreds((p) => (p.includes(id) ? p.filter((x) => x !== id) : [...p, id]));
  const toggleLead = (id: string) =>
    setLeads((l) => (l.includes(id) ? l.filter((x) => x !== id) : [...l, id]));

  return (
    <Card title="Add activity" pad={24} style={{ marginBottom: 24 }}>
      {error ? <Alert tone="err">{error}</Alert> : null}
      <div style={{ display: 'grid', gridTemplateColumns: '120px 1fr', gap: 12 }}>
        <Field label="Ref" required>
          <Input value={ref} onChange={(e) => setRef(e.target.value)} placeholder="A10" />
        </Field>
        <Field label="Activity" required>
          <Input value={text} onChange={(e) => setText(e.target.value)} placeholder="Description" />
        </Field>
      </div>
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
        <Field label="Workstream">
          <Select value={ws} onChange={(e) => setWs(e.target.value)} style={{ minWidth: 180 }}>
            <option value="">— none —</option>
            {workstreams.map((w) => (
              <option key={w.id} value={w.id}>{w.name}</option>
            ))}
          </Select>
        </Field>
        <Field label="Start week" required>
          <Select value={start} onChange={(e) => setStart(Number(e.target.value))} style={{ width: 90 }}>
            {weekOpts.map((w) => (
              <option key={w} value={w}>{w}</option>
            ))}
          </Select>
        </Field>
        <Field label="End week" required>
          <Select value={end} onChange={(e) => setEnd(Number(e.target.value))} style={{ width: 90 }}>
            {weekOpts.map((w) => (
              <option key={w} value={w}>{w}</option>
            ))}
          </Select>
        </Field>
      </div>
      <div style={{ display: 'flex', gap: 20, margin: '8px 0 12px' }}>
        <Checkbox label="Milestone" checked={milestone} onChange={(e) => setMilestone(e.target.checked)} />
        <Checkbox label="Evidence required" checked={evReq} onChange={(e) => setEvReq(e.target.checked)} />
      </div>
      <Field label="Lead(s)" hint="Only users visible to you are listed; leads can be added later.">
        <div className="sp-sch-predlist">
          {leadOpts.length === 0 ? (
            <span className="muted">No selectable users.</span>
          ) : (
            leadOpts.map(([id, name]) => (
              <Checkbox
                key={id}
                label={name}
                checked={leads.includes(id)}
                onChange={() => toggleLead(id)}
              />
            ))
          )}
        </div>
      </Field>
      <Field label="Predecessors (finish-to-start)" hint="FR-SCH-04: this activity can't start until these complete.">
        <div className="sp-sch-predlist">
          {activities.length === 0 ? (
            <span className="muted">No existing activities.</span>
          ) : (
            activities.map((a) => (
              <Checkbox
                key={a.id}
                label={`${a.ref} — ${a.text}`}
                checked={preds.includes(a.id)}
                onChange={() => togglePred(a.id)}
              />
            ))
          )}
        </div>
      </Field>
      <div style={{ display: 'flex', gap: 10, marginTop: 12 }}>
        <Button
          cta
          disabled={busy || !ref.trim() || !text.trim() || end < start}
          onClick={() =>
            onSubmit({
              ref: ref.trim(),
              text: text.trim(),
              workstreamId: ws || null,
              startWeek: start,
              endWeek: end,
              milestone,
              evidenceRequired: evReq,
              predecessorIds: preds,
              leads,
            })
          }
        >
          Add activity
        </Button>
        <Button variant="outline" onClick={onCancel} disabled={busy}>
          Cancel
        </Button>
      </div>
    </Card>
  );
}
