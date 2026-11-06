'use client';
import * as React from 'react';
import type { ScheduleActivity, ScheduleDep, SchedulePhase, ScheduleWorkstream } from './types';
import { ragTone } from '@/components/ui/RagBadge';

// ---------------------------------------------------------------------------
// W2-05 — FR-SCH-01/02 Gantt. Hand-rolled div grid (no chart dep): a sticky
// label column + fixed-width week track. Phases are group rows, workstreams
// subgroups, milestones diamonds, reduced-capacity weeks shaded behind every
// row, the §9.1 current week outlined. Dependency arrows are an SVG overlay
// for the selected activity; every bar also shows a predecessor count badge
// on hover/select (the spec's minimum).
//
// Geometry is fixed-pixel (WW per week) inside a horizontally scrolling
// track — that's what makes the arrow coordinates deterministic.
// ---------------------------------------------------------------------------

const LABEL_W = 300;
const WW = 22;
const HDR_H = 26; // week-number band
const PH_H = 32;
const WS_H = 26;
const ROW_H = 32;

type Row =
  | { kind: 'phase'; phase: SchedulePhase | null; key: string }
  | { kind: 'ws'; ws: ScheduleWorkstream | null; key: string }
  | { kind: 'act'; a: ScheduleActivity; key: string };

const RAG_BAR: Record<string, string> = {
  pass: 'var(--pass)',
  warn: 'var(--warn)',
  fail: 'var(--fail)',
  ink: 'var(--ink)',
  neutral: 'var(--faint)',
};

export function Gantt({
  activities,
  phases,
  workstreams,
  deps,
  totalWeeks,
  currentWeek,
  reducedWeeks,
  leadNames,
  selectedId,
  onSelect,
}: {
  activities: ScheduleActivity[];
  phases: SchedulePhase[];
  workstreams: ScheduleWorkstream[];
  deps: ScheduleDep[];
  totalWeeks: number;
  currentWeek: number | null;
  reducedWeeks: number[];
  leadNames: Record<string, string>;
  selectedId: string | null;
  onSelect: (id: string | null) => void;
}) {
  const [hoverId, setHoverId] = React.useState<string | null>(null);

  // ---- group rows: phase → workstream → activities -----------------------
  const { rows, yOf, totalH } = React.useMemo(() => {
    const push = (m: Map<string, ScheduleActivity[]>, k: string, a: ScheduleActivity) => {
      const l = m.get(k);
      if (l) l.push(a);
      else m.set(k, [a]);
    };
    const byPhase = new Map<string, ScheduleActivity[]>();
    for (const a of activities) push(byPhase, a.phase ?? '__none__', a);
    const ordered = [...phases].sort((x, y) => x.number - y.number);
    const out: Row[] = [];
    const emit = (phase: SchedulePhase | null, list: ScheduleActivity[]) => {
      out.push({ kind: 'phase', phase, key: `ph:${phase?.id ?? 'none'}` });
      const byWs = new Map<string, ScheduleActivity[]>();
      for (const a of list) push(byWs, a.workstream_id ?? '__none__', a);
      for (const w of workstreams) {
        const wsList = byWs.get(w.id);
        if (!wsList?.length) continue;
        out.push({ kind: 'ws', ws: w, key: `ws:${phase?.id ?? 'x'}:${w.id}` });
        for (const a of wsList) out.push({ kind: 'act', a, key: a.id });
      }
      const orphan = byWs.get('__none__') ?? [];
      if (orphan.length) {
        out.push({ kind: 'ws', ws: null, key: `ws:${phase?.id ?? 'x'}:none` });
        for (const a of orphan) out.push({ kind: 'act', a, key: a.id });
      }
    };
    const covered = new Set<string>();
    for (const ph of ordered) {
      covered.add(ph.name);
      emit(ph, byPhase.get(ph.name) ?? []); // empty phases still show — the map
    }
    const restActs = [...byPhase.keys()]
      .filter((k) => !covered.has(k))
      .flatMap((k) => byPhase.get(k) ?? []);
    if (restActs.length || ordered.length === 0) emit(null, restActs);

    const y = new Map<string, number>();
    let acc = HDR_H;
    for (const r of out) {
      const h = r.kind === 'phase' ? PH_H : r.kind === 'ws' ? WS_H : ROW_H;
      if (r.kind === 'act') y.set(r.a.id, acc + h / 2);
      acc += h;
    }
    return { rows: out, yOf: y, totalH: acc };
  }, [activities, phases, workstreams]);

  // ---- dependency edges for the selected activity -------------------------
  const preds = React.useMemo(() => {
    const m = new Map<string, ScheduleActivity[]>();
    const byId = new Map(activities.map((a) => [a.id, a]));
    for (const d of deps) {
      const p = byId.get(d.depends_on_activity_id);
      if (p) (m.get(d.activity_id) ?? m.set(d.activity_id, []).get(d.activity_id)!).push(p);
    }
    return m;
  }, [activities, deps]);

  const succs = React.useMemo(() => {
    const m = new Map<string, ScheduleActivity[]>();
    const byId = new Map(activities.map((a) => [a.id, a]));
    for (const d of deps) {
      const s = byId.get(d.activity_id);
      if (s) (m.get(d.depends_on_activity_id) ?? m.set(d.depends_on_activity_id, []).get(d.depends_on_activity_id)!).push(s);
    }
    return m;
  }, [activities, deps]);

  const selected = activities.find((a) => a.id === selectedId) ?? null;
  const arrows: { x1: number; y1: number; x2: number; y2: number; dir: 'in' | 'out' }[] = [];
  if (selected && yOf.has(selected.id)) {
    // arrow tips land on a node's anchor: bar start for normal activities,
    // the end-week diamond for milestones
    const inX = (a: ScheduleActivity) => (a.milestone ? a.end_week * WW - 6 : (a.start_week - 1) * WW);
    const yS = yOf.get(selected.id)!;
    const xE = selected.end_week * WW;
    for (const p of preds.get(selected.id) ?? []) {
      const yP = yOf.get(p.id);
      if (yP != null) arrows.push({ x1: p.end_week * WW, y1: yP, x2: inX(selected), y2: yS, dir: 'in' });
    }
    for (const s of succs.get(selected.id) ?? []) {
      const yT = yOf.get(s.id);
      if (yT != null) arrows.push({ x1: xE, y1: yS, x2: inX(s), y2: yT, dir: 'out' });
    }
  }

  const trackW = totalWeeks * WW;
  let rowTop = HDR_H;

  return (
    <div className="sp-gantt" role="region" aria-label="Activity Gantt">
      <div className="sp-gantt-inner" style={{ width: LABEL_W + trackW, height: totalH }}>
        {/* background layers: reduced-capacity shading + current-week outline */}
        {reducedWeeks.map((w) =>
          w >= 1 && w <= totalWeeks ? (
            <div
              key={`rc${w}`}
              className="sp-gantt-rc"
              style={{ left: LABEL_W + (w - 1) * WW, width: WW, top: 0, height: totalH }}
              title={`Week ${w} — reduced capacity`}
            />
          ) : null
        )}
        {currentWeek != null && currentWeek >= 1 && currentWeek <= totalWeeks ? (
          <div
            className="sp-gantt-now"
            style={{ left: LABEL_W + (currentWeek - 1) * WW, width: WW, top: 0, height: totalH }}
            title={`Current week — ${currentWeek}`}
          />
        ) : null}

        {/* week-number header */}
        <div className="sp-gantt-row" style={{ height: HDR_H, top: 0 }}>
          <div className="sp-gantt-label sp-gantt-hd-label" style={{ width: LABEL_W }}>
            Week
          </div>
          {Array.from({ length: totalWeeks }, (_, i) => i + 1).map((w) => (
            <div
              key={w}
              className={
                'sp-gantt-cell sp-gantt-hd' +
                (reducedWeeks.includes(w) ? ' is-rc' : '') +
                (w === currentWeek ? ' is-now' : '')
              }
              style={{ left: LABEL_W + (w - 1) * WW, width: WW }}
            >
              {w}
            </div>
          ))}
        </div>

        {/* dependency arrows (selected activity) */}
        {arrows.length ? (
          <svg
            className="sp-gantt-arrows"
            style={{ left: LABEL_W, top: 0 }}
            width={trackW}
            height={totalH}
            aria-hidden="true"
          >
            <defs>
              <marker id="ga-in" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                <path d="M0,0 L8,4 L0,8 z" fill="var(--accent)" />
              </marker>
              <marker id="ga-out" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                <path d="M0,0 L8,4 L0,8 z" fill="var(--warn)" />
              </marker>
            </defs>
            {arrows.map((e, i) => {
              // elbow: out of the source bar edge, vertical jog partway, into
              // the target anchor (markerEnd draws the head there)
              const jog = Math.max(6, Math.min(Math.abs(e.x2 - e.x1) / 2, 14));
              const mx = e.x2 >= e.x1 ? e.x2 - jog : e.x1 + jog;
              const d = `M ${e.x1} ${e.y1} L ${mx} ${e.y1} L ${mx} ${e.y2} L ${e.x2} ${e.y2}`;
              return (
                <path
                  key={i}
                  d={d}
                  fill="none"
                  stroke={e.dir === 'in' ? 'var(--accent)' : 'var(--warn)'}
                  strokeWidth={1.5}
                  markerEnd={`url(#ga-${e.dir})`}
                />
              );
            })}
          </svg>
        ) : null}

        {rows.map((r) => {
          const h = r.kind === 'phase' ? PH_H : r.kind === 'ws' ? WS_H : ROW_H;
          const top = rowTop;
          rowTop += h;

          if (r.kind === 'phase') {
            const ph = r.phase;
            return (
              <div key={r.key} className="sp-gantt-row sp-gantt-phase" style={{ top, height: h }}>
                <div className="sp-gantt-label sp-gantt-phase-label" style={{ width: LABEL_W }}>
                  {ph ? `Phase ${ph.number} — ${ph.name}` : 'Other'}
                </div>
                {ph ? (
                  <div
                    className="sp-gantt-phase-band"
                    style={{ left: LABEL_W + (ph.start_week - 1) * WW, width: (ph.end_week - ph.start_week + 1) * WW }}
                  >
                    <span className="sp-gantt-phase-weeks">
                      W{ph.start_week}–{ph.end_week}
                    </span>
                  </div>
                ) : null}
              </div>
            );
          }

          if (r.kind === 'ws') {
            const ws = r.ws;
            const lead = ws?.accountable_lead ? leadNames[ws.accountable_lead] ?? '—' : null;
            return (
              <div key={r.key} className="sp-gantt-row sp-gantt-ws" style={{ top, height: h }}>
                <div className="sp-gantt-label sp-gantt-ws-label" style={{ width: LABEL_W }}>
                  {ws ? ws.name : 'No workstream'}
                  {lead ? <span className="sp-gantt-ws-lead"> · {lead}</span> : null}
                </div>
              </div>
            );
          }

          const a = r.a;
          const barL = (a.start_week - 1) * WW;
          const barW = (a.end_week - a.start_week + 1) * WW;
          const isSel = a.id === selectedId;
          const isHov = a.id === hoverId;
          const nPreds = preds.get(a.id)?.length ?? 0;
          const nSuccs = succs.get(a.id)?.length ?? 0;
          const tipParts = [
            `${a.ref} — ${a.text}`,
            `W${a.start_week}–${a.end_week}${a.due_date ? ` · due ${a.due_date}` : ''}`,
            nPreds ? `depends on: ${preds.get(a.id)!.map((p) => p.ref).join(', ')}` : '',
            nSuccs ? `blocks: ${succs.get(a.id)!.map((s) => s.ref).join(', ')}` : '',
            a.status === 'Deferred' && a.rescheduled_date ? `rescheduled to ${a.rescheduled_date}` : '',
          ].filter(Boolean);

          return (
            <div
              key={r.key}
              className={'sp-gantt-row sp-gantt-act' + (a.status === 'Deferred' ? ' is-deferred' : '')}
              style={{ top, height: h }}
            >
              <button
                type="button"
                className={'sp-gantt-label sp-gantt-act-label' + (isSel ? ' is-sel' : '')}
                style={{ width: LABEL_W }}
                title={tipParts.join('\n')}
                onClick={() => onSelect(isSel ? null : a.id)}
              >
                <span className="sp-gantt-ref">{a.ref}</span>
                <span className="sp-gantt-act-text">{a.text}</span>
              </button>
              <div
                className="sp-gantt-track"
                style={{ left: LABEL_W, width: trackW }}
                onMouseEnter={() => setHoverId(a.id)}
                onMouseLeave={() => setHoverId((h2) => (h2 === a.id ? null : h2))}
              >
                {a.milestone ? (
                  // spec §8.2: milestones render as diamonds anchored on the
                  // activity's end-week boundary (a thin span bar is kept under
                  // it for multi-week milestones)
                  <>
                    <span
                      className="sp-gantt-ms-line"
                      style={{ left: barL, width: Math.max(barW - 6, 4) }}
                    />
                    <button
                      type="button"
                      className={'sp-gantt-ms' + (isSel ? ' is-sel' : '')}
                      style={{
                        left: a.end_week * WW - 11,
                        background: RAG_BAR[ragTone(a.rag)] ?? 'var(--faint)',
                      }}
                      title={tipParts.join('\n')}
                      onClick={() => onSelect(isSel ? null : a.id)}
                      aria-label={`${a.ref} milestone, week ${a.end_week}`}
                    />
                  </>
                ) : (
                  <button
                    type="button"
                    className={
                      'sp-gantt-bar rag-' + ragTone(a.rag) +
                      (isSel ? ' is-sel' : '') +
                      (a.status === 'Deferred' ? ' is-deferred' : '')
                    }
                    style={{ left: barL, width: Math.max(barW, 8) }}
                    title={tipParts.join('\n')}
                    onClick={() => onSelect(isSel ? null : a.id)}
                    aria-label={`${a.ref} weeks ${a.start_week} to ${a.end_week}`}
                  >
                    {a.pct_complete > 0 && a.pct_complete < 100 ? (
                      <span className="sp-gantt-pct" style={{ width: `${a.pct_complete}%` }} />
                    ) : null}
                  </button>
                )}
                {(isHov || isSel) && (nPreds > 0 || nSuccs > 0) ? (
                  <span className="sp-gantt-depchip" style={{ left: barL + Math.max(barW, 8) + 4 }}>
                    {nPreds ? `⇐${nPreds}` : ''}
                    {nPreds && nSuccs ? ' ' : ''}
                    {nSuccs ? `${nSuccs}⇒` : ''}
                  </span>
                ) : null}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
