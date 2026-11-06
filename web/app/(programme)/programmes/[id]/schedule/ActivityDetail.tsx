'use client';
import * as React from 'react';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { StatusPill } from '@/components/ui/StatusPill';
import { RagBadge } from '@/components/ui/RagBadge';
import { Field, Select } from '@/components/ui/forms';
import type {
  RegisterLink,
  ScheduleActivity,
  ScheduleDep,
  ScheduleEvidenceCount,
  ScheduleWorkstream,
} from './types';

// ---------------------------------------------------------------------------
// W2-05 — selected-activity record (FR-SCH-03 subset: register links, evidence
// required + counts, comments, append-only status history) plus the
// reposition control (FR-SCH-06 surface: reorder_activity changes weeks and
// the engine recalculates every derived date).
// ---------------------------------------------------------------------------

interface HistRow {
  old_status: string | null;
  new_status: string;
  changed_at: string;
}

export function ActivityDetail({
  activity: a,
  workstreams,
  deps,
  activities,
  registerLinks,
  evidenceCounts,
  leadNames,
  totalWeeks,
  canWrite,
  busy,
  onReorder,
  onClose,
}: {
  activity: ScheduleActivity;
  workstreams: ScheduleWorkstream[];
  deps: ScheduleDep[];
  activities: ScheduleActivity[];
  registerLinks: RegisterLink[];
  evidenceCounts: ScheduleEvidenceCount[];
  leadNames: Record<string, string>;
  totalWeeks: number;
  canWrite: boolean;
  busy: boolean;
  onReorder: (a: ScheduleActivity, start: number, end: number, ws: string | null) => void;
  onClose: () => void;
}) {
  const supabase = browserClient();
  const byId = new Map(activities.map((x) => [x.id, x]));
  const preds = deps.filter((d) => d.activity_id === a.id).map((d) => byId.get(d.depends_on_activity_id)).filter(Boolean) as ScheduleActivity[];
  const succs = deps.filter((d) => d.depends_on_activity_id === a.id).map((d) => byId.get(d.activity_id)).filter(Boolean) as ScheduleActivity[];
  const links = registerLinks.filter((l) => l.activityId === a.id);
  const ev = evidenceCounts.find((e) => e.activityId === a.id);

  const [hist, setHist] = React.useState<HistRow[] | null>(null);
  React.useEffect(() => {
    let live = true;
    setHist(null);
    supabase
      .from('activity_status_history')
      .select('old_status, new_status, changed_at')
      .eq('activity_id', a.id)
      .order('changed_at', { ascending: false })
      .limit(12)
      .then(({ data }) => {
        if (live) setHist((data ?? []) as HistRow[]);
      });
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [a.id]);

  const [start, setStart] = React.useState(a.start_week);
  const [end, setEnd] = React.useState(a.end_week);
  const [ws, setWs] = React.useState<string>(a.workstream_id ?? '');
  React.useEffect(() => {
    setStart(a.start_week);
    setEnd(a.end_week);
    setWs(a.workstream_id ?? '');
  }, [a.id, a.start_week, a.end_week, a.workstream_id]);

  const weekOpts = Array.from({ length: totalWeeks }, (_, i) => i + 1);
  const kv = (k: string, v: React.ReactNode) => (
    <div className="sp-sch-kv">
      <span className="muted">{k}</span>
      <span>{v}</span>
    </div>
  );

  return (
    <Card
      title={
        <>
          <span className="mono">{a.ref}</span> {a.milestone ? '· milestone' : ''}
        </>
      }
      action={
        <Button variant="ghost" size="sm" icon="x" onClick={onClose}>
          Close
        </Button>
      }
      pad={24}
      style={{ marginTop: 24 }}
    >
      <p style={{ marginTop: 0 }}>{a.text}</p>

      <div className="sp-sch-grid">
        {kv('Status', <StatusPill status={a.status} />)}
        {kv('RAG', <RagBadge rag={a.rag} />)}
        {kv('Weeks', <span className="mono">{a.start_week}–{a.end_week}</span>)}
        {kv('Start date', <span className="mono">{a.start_date ?? '—'}</span>)}
        {kv('Due', <span className="mono">{a.due_date ?? '—'}</span>)}
        {a.status === 'Deferred'
          ? kv('Rescheduled', <span className="mono">{a.rescheduled_date ?? '—'}</span>)
          : null}
        {a.status === 'Complete'
          ? kv('Completed', <span className="mono">{a.actual_completion ?? '—'}</span>)
          : null}
        {kv('Phase', a.phase ?? '—')}
        {kv('Workstream', workstreams.find((w) => w.id === a.workstream_id)?.name ?? '—')}
        {kv(
          'Lead(s)',
          (a.leads ?? []).map((l) => leadNames[l] ?? '—').join(', ') || '—'
        )}
        {kv('Progress', `${a.pct_complete}%`)}
        {kv(
          'Evidence',
          a.evidence_required
            ? `${ev?.total ?? 0} uploaded${ev ? `, ${ev.decided} decided` : ''} (required)`
            : `${ev?.total ?? 0} uploaded`
        )}
        {links.length
          ? kv(
              'Register links',
              links.map((l) => `${l.ref ?? '?'} (${l.status ?? '?'})`).join(', ')
            )
          : null}
      </div>

      {preds.length || succs.length ? (
        <div className="sp-sch-deps">
          {preds.length ? (
            <div>
              <div className="sp-kpi-label" style={{ marginBottom: 6 }}>Depends on</div>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {preds.map((p) => (
                  <Badge key={p.id} tone={p.status === 'Complete' ? 'pass' : 'warn'} dot>
                    {p.ref} · {p.status}
                  </Badge>
                ))}
              </div>
            </div>
          ) : null}
          {succs.length ? (
            <div>
              <div className="sp-kpi-label" style={{ marginBottom: 6 }}>Blocks</div>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {succs.map((s) => (
                  <Badge key={s.id} tone="neutral" dot>
                    {s.ref} · {s.status}
                  </Badge>
                ))}
              </div>
            </div>
          ) : null}
        </div>
      ) : null}

      {a.dependency_override_reason ? (
        <p className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
          FR-SCH-04 override: {a.dependency_override_reason}
        </p>
      ) : null}
      {a.comments ? <p className="muted">{a.comments}</p> : null}
      {a.recovery_date ? (
        <p className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
          Recovery date: {a.recovery_date}
        </p>
      ) : null}

      {canWrite ? (
        <div className="sp-sch-reorder">
          <div className="sp-kpi-label" style={{ marginBottom: 8 }}>Reposition (reorder_activity)</div>
          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'flex-end' }}>
            <Field label="Start week">
              <Select value={start} onChange={(e) => setStart(Number(e.target.value))} style={{ width: 90 }}>
                {weekOpts.map((w) => (
                  <option key={w} value={w}>{w}</option>
                ))}
              </Select>
            </Field>
            <Field label="End week">
              <Select value={end} onChange={(e) => setEnd(Number(e.target.value))} style={{ width: 90 }}>
                {weekOpts.map((w) => (
                  <option key={w} value={w}>{w}</option>
                ))}
              </Select>
            </Field>
            <Field label="Workstream">
              <Select value={ws} onChange={(e) => setWs(e.target.value)} style={{ minWidth: 180 }}>
                <option value="">— unchanged —</option>
                {workstreams.map((w) => (
                  <option key={w.id} value={w.id}>{w.name}</option>
                ))}
              </Select>
            </Field>
            <Button
              size="sm"
              disabled={busy || end < start}
              onClick={() => onReorder(a, start, end, ws || null)}
            >
              Apply
            </Button>
          </div>
          <div className="sp-field-hint" style={{ marginTop: 6 }}>
            Start/end stay inside 1..{totalWeeks}; the engine recalculates all dates.
          </div>
        </div>
      ) : null}

      <div className="sp-sch-hist">
        <div className="sp-kpi-label" style={{ marginBottom: 6 }}>Status history</div>
        {hist === null ? (
          <span className="muted">Loading…</span>
        ) : hist.length === 0 ? (
          <span className="muted">No recorded changes.</span>
        ) : (
          <ul className="sp-sch-hist-list">
            {hist.map((h, i) => (
              <li key={i}>
                <span className="mono muted">{new Date(h.changed_at).toLocaleString()}</span>{' '}
                {h.old_status ?? '—'} → <strong>{h.new_status}</strong>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Card>
  );
}
