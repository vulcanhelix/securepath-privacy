'use client';
import Link from 'next/link';
import * as React from 'react';
import { SortableTable } from '@/components/ui/SortableTable';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { Select } from '@/components/ui/forms';

// ---------------------------------------------------------------------------
// W2-01 — FR-PCN-01/02 partner-console portfolio table. The row set arrives
// already scoped (list_programmes → allowed_programmes()); filtering and
// sorting are client-side over that set — spec asks for filter + sort, not
// server round trips. Receives PLAIN data only (the W4-D1 lesson: no objects
// carrying functions across the server/client boundary).
// ---------------------------------------------------------------------------

export interface ConsoleRow {
  programme_id: string;
  programme_name: string;
  client_name: string;
  jurisdiction: string | null;
  framework: string | null;
  status: string;
  phase: string | null;
  current_week: number | null;
  total_weeks: number;
  rag: string | null;
  register_closed: number | null;
  register_open: number | null;
  activities_overdue: number | null;
  evidence_pending: number | null;
  maintenance_due_month: number | null;
  maintenance_overdue_month: number | null;
  report_status: string | null;
  report_due_on: string | null;
  consultants: string[];
  attention: string[];
}

const RAG_RANK: Record<string, number> = { Red: 0, Amber: 1, Green: 2 };

const fmtDate = (iso: string | null) =>
  iso
    ? new Date(`${iso}T00:00:00`).toLocaleDateString('en-GB', {
        day: 'numeric',
        month: 'short',
        year: 'numeric',
      })
    : null;

function distinct(rows: ConsoleRow[], pick: (r: ConsoleRow) => (string | null)[]): string[] {
  const set = new Set<string>();
  for (const r of rows) for (const v of pick(r)) if (v) set.add(v);
  return [...set].sort();
}

export function ConsoleTable({ rows }: { rows: ConsoleRow[] }) {
  const [fFramework, setFFramework] = React.useState('');
  const [fJur, setFJur] = React.useState('');
  const [fRag, setFRag] = React.useState('');
  const [fConsultant, setFConsultant] = React.useState('');
  const [fReport, setFReport] = React.useState('');
  const [fAttention, setFAttention] = React.useState('');

  const frameworks = React.useMemo(() => distinct(rows, (r) => [r.framework]), [rows]);
  const jurisdictions = React.useMemo(() => distinct(rows, (r) => [r.jurisdiction]), [rows]);
  const consultants = React.useMemo(() => distinct(rows, (r) => r.consultants), [rows]);
  const reportStates = React.useMemo(() => distinct(rows, (r) => [r.report_status ?? 'none']), [rows]);

  const filtered = React.useMemo(
    () =>
      rows.filter(
        (r) =>
          (!fFramework || r.framework === fFramework) &&
          (!fJur || r.jurisdiction === fJur) &&
          (!fRag || r.rag === fRag) &&
          (!fConsultant || r.consultants.includes(fConsultant)) &&
          (!fReport || (r.report_status ?? 'none') === fReport) &&
          (!fAttention || r.attention.length > 0)
      ),
    [rows, fFramework, fJur, fRag, fConsultant, fReport, fAttention]
  );

  return (
    <>
      <div
        style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center', padding: '14px 20px 0' }}
      >
        <Select value={fFramework} onChange={(e) => setFFramework(e.target.value)} aria-label="Framework">
          <option value="">Any framework</option>
          {frameworks.map((f) => (
            <option key={f} value={f}>{f}</option>
          ))}
        </Select>
        <Select value={fJur} onChange={(e) => setFJur(e.target.value)} aria-label="Jurisdiction">
          <option value="">Any jurisdiction</option>
          {jurisdictions.map((j) => (
            <option key={j} value={j}>{j}</option>
          ))}
        </Select>
        <Select value={fRag} onChange={(e) => setFRag(e.target.value)} aria-label="RAG">
          <option value="">Any RAG</option>
          <option value="Red">Red</option>
          <option value="Amber">Amber</option>
          <option value="Green">Green</option>
        </Select>
        <Select value={fConsultant} onChange={(e) => setFConsultant(e.target.value)} aria-label="Consultant">
          <option value="">Any consultant</option>
          {consultants.map((c) => (
            <option key={c} value={c}>{c}</option>
          ))}
        </Select>
        <Select value={fReport} onChange={(e) => setFReport(e.target.value)} aria-label="Report status">
          <option value="">Any report</option>
          {reportStates.map((s) => (
            <option key={s} value={s}>{s === 'none' ? 'No report' : s}</option>
          ))}
        </Select>
        <Select value={fAttention} onChange={(e) => setFAttention(e.target.value)} aria-label="Attention">
          <option value="">All programmes</option>
          <option value="attention">Needs attention</option>
        </Select>
        {filtered.length !== rows.length ? (
          <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
            {filtered.length} of {rows.length}
          </span>
        ) : null}
      </div>

      <SortableTable
        initialSort={0}
        columns={[
          { label: 'Client' },
          { label: 'Programme' },
          { label: 'Framework' },
          { label: 'Jurisdiction' },
          { label: 'Phase' },
          { label: 'Week', align: 'right' },
          { label: 'RAG' },
          { label: 'Register', align: 'right' },
          { label: 'Overdue', align: 'right' },
          { label: 'Maintenance', align: 'right' },
          { label: 'Evidence', align: 'right' },
          { label: 'Monthly report' },
          { label: 'Consultant' },
        ]}
        rows={filtered.map((p) => ({
          values: [
            p.client_name,
            p.programme_name,
            p.framework ?? '',
            p.jurisdiction ?? '',
            p.phase ?? '',
            p.current_week ?? -1,
            RAG_RANK[p.rag ?? ''] ?? 3,
            p.register_closed ?? -1,
            p.activities_overdue ?? -1,
            p.maintenance_overdue_month ?? -1,
            p.evidence_pending ?? -1,
            p.report_status ?? '',
            p.consultants.join(', '),
          ],
          cells: [
            <span key="c">{p.client_name}</span>,
            <Link
              key="p"
              href={`/programmes/${p.programme_id}`}
              style={{ fontWeight: 500, color: 'var(--text)' }}
            >
              {p.programme_name}
            </Link>,
            <span key="f" className="muted">{p.framework ?? '—'}</span>,
            <span key="j" className="muted">{p.jurisdiction ?? '—'}</span>,
            <span key="h" className="muted">{p.phase ?? '—'}</span>,
            <span key="w" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
              {p.current_week != null ? `${p.current_week} / ${p.total_weeks}` : `— / ${p.total_weeks}`}
            </span>,
            <RagBadge key="r" rag={p.rag} />,
            <span key="g" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
              {p.register_open != null
                ? `${p.register_closed ?? 0}/${(p.register_closed ?? 0) + p.register_open}`
                : '—'}
            </span>,
            <span
              key="o"
              className="mono"
              style={{
                fontSize: 'var(--fs-xs)',
                color: (p.activities_overdue ?? 0) > 0 ? 'var(--fail)' : 'var(--muted)',
              }}
            >
              {p.activities_overdue ?? '—'}
            </span>,
            <span key="m" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
              {p.maintenance_due_month != null || p.maintenance_overdue_month != null
                ? `${p.maintenance_due_month ?? 0} due` +
                  ((p.maintenance_overdue_month ?? 0) > 0
                    ? ` · ${p.maintenance_overdue_month} late`
                    : '')
                : '—'}
            </span>,
            <span
              key="e"
              className="mono"
              style={{
                fontSize: 'var(--fs-xs)',
                color: (p.evidence_pending ?? 0) > 0 ? 'var(--warn)' : 'var(--muted)',
              }}
            >
              {p.evidence_pending ?? '—'}
            </span>,
            <span key="m2">
              <StatusPill status={p.report_status} empty={<span className="muted">none</span>} />
              {p.report_due_on ? (
                <span className="muted" style={{ fontSize: 'var(--fs-xs)', marginLeft: 6 }}>
                  {fmtDate(p.report_due_on)}
                </span>
              ) : null}
            </span>,
            <span key="u" className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
              {p.consultants.length ? p.consultants.join(', ') : '—'}
            </span>,
          ],
        }))}
      />
    </>
  );
}
