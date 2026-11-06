'use client';
import * as React from 'react';
import { SortableTable, type SortableRow } from '@/components/ui/SortableTable';
import { StatusPill } from '@/components/ui/StatusPill';
import { RagBadge } from '@/components/ui/RagBadge';
import { Select } from '@/components/ui/forms';
import { Icon } from '@/components/ui/Icon';
import type { ScheduleActivity, ScheduleDep, ScheduleWorkstream } from './types';

// ---------------------------------------------------------------------------
// W2-05 — FR-SCH-01 list view: same data as the Gantt as a sortable table.
// Status is inline-editable for write roles (update_activity via the board's
// requestStatusChange — which collects the FR-SCH-04 override reason and the
// Deferred rescheduled_date before calling the RPC).
// ---------------------------------------------------------------------------

export const ACTIVITY_STATUSES = [
  'Not started',
  'In progress',
  'At risk',
  'Blocked',
  'Deferred',
  'Complete',
];

export function ActivityTable({
  activities,
  workstreams,
  deps,
  leadNames,
  canWrite,
  busy,
  selectedId,
  onSelect,
  onStatus,
}: {
  activities: ScheduleActivity[];
  workstreams: ScheduleWorkstream[];
  deps: ScheduleDep[];
  leadNames: Record<string, string>;
  canWrite: boolean;
  busy: boolean;
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  onStatus: (a: ScheduleActivity, status: string) => void;
}) {
  const wsName = new Map(workstreams.map((w) => [w.id, w.name]));
  const refOf = new Map(activities.map((a) => [a.id, a.ref]));
  const predRefs = new Map<string, string[]>();
  for (const d of deps) {
    const r = refOf.get(d.depends_on_activity_id);
    if (r) (predRefs.get(d.activity_id) ?? predRefs.set(d.activity_id, []).get(d.activity_id)!).push(r);
  }
  const leadLabel = (a: ScheduleActivity) =>
    (a.leads ?? []).map((l) => leadNames[l] ?? '…').join(', ') || '—';

  const rows: SortableRow[] = activities.map((a) => {
    const depsTxt = (predRefs.get(a.id) ?? []).join(', ');
    return {
      cells: [
        <button
          key="ref"
          type="button"
          className="sp-sch-refbtn"
          onClick={() => onSelect(a.id === selectedId ? null : a.id)}
          title="Show detail"
        >
          <span className="mono">{a.ref}</span>
          {a.milestone ? <Icon name="diamond" size={12} /> : null}
        </button>,
        <span key="t" className={a.status === 'Deferred' ? 'sp-sch-deferred-text' : undefined}>
          {a.text}
          {a.status === 'Deferred' && a.rescheduled_date ? (
            <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>
              rescheduled to {a.rescheduled_date}
            </span>
          ) : null}
          {a.evidence_required ? (
            <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>
              evidence required
            </span>
          ) : null}
        </span>,
        <span key="ws">{wsName.get(a.workstream_id ?? '') ?? '—'}</span>,
        <span key="w" className="mono">
          {a.start_week}–{a.end_week}
        </span>,
        canWrite ? (
          <Select
            key="s"
            value={a.status}
            disabled={busy}
            onChange={(e) => onStatus(a, e.target.value)}
            style={{ minWidth: 130 }}
            aria-label={`status for ${a.ref}`}
          >
            {ACTIVITY_STATUSES.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </Select>
        ) : (
          <StatusPill key="s" status={a.status} />
        ),
        <span key="l">{leadLabel(a)}</span>,
        <span key="d" className="mono">
          {depsTxt || '—'}
        </span>,
        <span key="due" className="mono">
          {a.due_date ?? '—'}
        </span>,
        <RagBadge key="rag" rag={a.rag} />,
      ],
      values: [
        a.ref,
        a.text,
        wsName.get(a.workstream_id ?? '') ?? '',
        a.start_week,
        a.status,
        leadLabel(a),
        depsTxt,
        a.due_date,
        a.rag,
      ],
    };
  });

  return (
    <SortableTable
      columns={[
        { label: 'Ref' },
        { label: 'Activity' },
        { label: 'Workstream' },
        { label: 'Weeks' },
        { label: 'Status' },
        { label: 'Lead(s)' },
        { label: 'Depends on' },
        { label: 'Due' },
        { label: 'RAG' },
      ]}
      rows={rows}
      initialSort={3}
      initialDir="asc"
    />
  );
}
