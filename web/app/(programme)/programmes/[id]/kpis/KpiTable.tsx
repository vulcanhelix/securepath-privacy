'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { RagBadge } from '@/components/ui/RagBadge';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Icon } from '@/components/ui/Icon';
import { Input } from '@/components/ui/forms';

// W2-11 — KPI table with per-row expand: period history (FR-KPI-04) and,
// for write roles on non-auto KPIs, the monthly capture form (FR-KPI-02).
// Every write is an RPC under the caller's JWT; the gating props only decide
// what is rendered — the server rejects anything the caller may not do.

export interface KpiRow {
  kpi_id: string;
  name: string;
  unit: string | null;
  baseline: number | null;
  target: number | null;
  target_proposed: boolean;
  target_confirmed: boolean;
  auto_calc: boolean;
  latest_month: string | null;
  latest_value: number | null;
  rag: string | null;
}

export interface KpiActual {
  id: string;
  kpi_id: string;
  month: string;
  value: number | null;
  evidence_id: string | null;
  created_at: string;
}

const fmt = (v: number | null | undefined, unit?: string | null) =>
  v == null ? '—' : `${v}${unit ? ` ${unit}` : ''}`;
const monthLabel = (m: string | null) =>
  m ? new Date(m + 'T00:00:00').toLocaleDateString('en-GB', { month: 'short', year: 'numeric' }) : '—';
const thisMonth = () => new Date().toISOString().slice(0, 7); // yyyy-mm for <input type=month>

export function KpiTable({
  kpis,
  history,
  canWrite,
  canConfirm,
}: {
  kpis: KpiRow[];
  history: KpiActual[];
  canWrite: boolean;
  canConfirm: boolean;
}) {
  const [open, setOpen] = React.useState<string | null>(null);
  const byKpi = React.useMemo(() => {
    const m = new Map<string, KpiActual[]>();
    for (const a of history) m.set(a.kpi_id, [...(m.get(a.kpi_id) ?? []), a]);
    return m;
  }, [history]);

  return (
    <div className="sp-table-scroll">
      <table className="sp-table">
        <thead>
          <tr>
            <th style={{ width: 28 }} />
            <th>KPI</th>
            <th style={{ textAlign: 'right' }}>Baseline</th>
            <th style={{ textAlign: 'right' }}>Target</th>
            <th style={{ textAlign: 'right' }}>Actual</th>
            <th>Period</th>
            <th>RAG</th>
            <th>Source</th>
          </tr>
        </thead>
        <tbody>
          {kpis.map((k) => {
            const isOpen = open === k.kpi_id;
            return (
              <React.Fragment key={k.kpi_id}>
                <tr>
                  <td>
                    <button
                      type="button"
                      className="sp-thsort"
                      aria-expanded={isOpen}
                      aria-label={isOpen ? 'Collapse history' : 'Expand history'}
                      onClick={() => setOpen(isOpen ? null : k.kpi_id)}
                    >
                      <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size={14} />
                    </button>
                  </td>
                  <td style={{ fontWeight: 500 }}>{k.name}</td>
                  <td className="mono" style={{ textAlign: 'right' }}>{fmt(k.baseline, k.unit)}</td>
                  <td className="mono" style={{ textAlign: 'right' }}>
                    {fmt(k.target, k.unit)}
                    {k.target_proposed && !k.target_confirmed ? (
                      <div style={{ marginTop: 4 }}><Badge tone="warn">proposed</Badge></div>
                    ) : null}
                  </td>
                  <td className="mono" style={{ textAlign: 'right' }}>{fmt(k.latest_value, k.unit)}</td>
                  <td className="muted">{monthLabel(k.latest_month)}</td>
                  <td><RagBadge rag={k.rag} /></td>
                  <td>
                    {k.auto_calc ? <Badge tone="ink">auto</Badge> : <Badge tone="neutral">monthly entry</Badge>}
                  </td>
                </tr>
                {isOpen ? (
                  <tr>
                    <td />
                    <td colSpan={7} style={{ background: 'var(--surface-card)' }}>
                      <KpiDetail
                        kpi={k}
                        rows={byKpi.get(k.kpi_id) ?? []}
                        canWrite={canWrite}
                        canConfirm={canConfirm}
                      />
                    </td>
                  </tr>
                ) : null}
              </React.Fragment>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function KpiDetail({
  kpi,
  rows,
  canWrite,
  canConfirm,
}: {
  kpi: KpiRow;
  rows: KpiActual[];
  canWrite: boolean;
  canConfirm: boolean;
}) {
  const router = useRouter();
  const [month, setMonth] = React.useState(thisMonth());
  const [value, setValue] = React.useState('');
  const [note, setNote] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});

  async function capture(e: React.FormEvent) {
    e.preventDefault();
    const n = Number(value);
    if (value.trim() === '' || Number.isNaN(n)) {
      setMsg({ err: 'Enter a numeric value.' });
      return;
    }
    setBusy(true);
    setMsg({});
    const { error } = await browserClient().rpc('record_kpi_actual', {
      p_kpi_id: kpi.kpi_id,
      p_month: `${month}-01`,
      p_value: n,
      p_note: note.trim() || null,
    });
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    setValue('');
    setNote('');
    setMsg({ ok: `Recorded ${monthLabel(`${month}-01`)}.` });
    router.refresh();
  }

  async function confirmTarget() {
    setBusy(true);
    setMsg({});
    const { error } = await browserClient().rpc('confirm_kpi_target', { p_kpi_id: kpi.kpi_id });
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    setMsg({ ok: 'Target confirmed.' });
    router.refresh();
  }

  return (
    <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', padding: '8px 0' }}>
      <div style={{ flex: '1 1 280px', minWidth: 0 }}>
        <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginBottom: 6 }}>
          Period history (read-only)
        </div>
        {rows.length ? (
          <table className="sp-table">
            <thead>
              <tr>
                <th>Month</th>
                <th style={{ textAlign: 'right' }}>Actual</th>
                <th style={{ textAlign: 'right' }}>Target</th>
                <th>Evidence</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((a) => (
                <tr key={a.id}>
                  <td>{monthLabel(a.month)}</td>
                  <td className="mono" style={{ textAlign: 'right' }}>{fmt(a.value, kpi.unit)}</td>
                  <td className="mono muted" style={{ textAlign: 'right' }}>{fmt(kpi.target, kpi.unit)}</td>
                  <td className="muted">{a.evidence_id ? <Icon name="paperclip" size={13} /> : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>No actuals recorded yet.</div>
        )}
      </div>

      <div style={{ flex: '1 1 240px', display: 'flex', flexDirection: 'column', gap: 10 }}>
        {kpi.target_proposed && !kpi.target_confirmed && canConfirm ? (
          <div>
            <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginBottom: 6 }}>
              Target {fmt(kpi.target, kpi.unit)} is proposed — accountable officer confirmation required.
            </div>
            <Button size="sm" variant="outline" icon="check" disabled={busy} onClick={confirmTarget}>
              Confirm target
            </Button>
          </div>
        ) : null}

        {kpi.auto_calc ? (
          <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
            Auto-calculated by the programme engine — manual actuals are not accepted.
          </div>
        ) : canWrite ? (
          <form onSubmit={capture} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Capture monthly actual</div>
            <div style={{ display: 'flex', gap: 8 }}>
              <Input type="month" value={month} max={thisMonth()} onChange={(e) => setMonth(e.target.value)} required />
              <Input
                type="number"
                step="any"
                inputMode="decimal"
                placeholder={kpi.unit ?? 'value'}
                value={value}
                onChange={(e) => setValue(e.target.value)}
                required
                style={{ width: 120 }}
              />
            </div>
            <Input placeholder="Note (kept in the audit trail)" value={note} onChange={(e) => setNote(e.target.value)} />
            <div>
              <Button size="sm" type="submit" disabled={busy}>
                {busy ? 'Saving…' : 'Record actual'}
              </Button>
            </div>
            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
              Re-recording a month replaces that month&apos;s value; every entry is audited.
            </div>
          </form>
        ) : null}

        {msg.err ? <p className="sp-breach-msg is-err">{msg.err}</p> : null}
        {msg.ok ? <p className="sp-breach-msg is-ok">{msg.ok}</p> : null}
      </div>
    </div>
  );
}
