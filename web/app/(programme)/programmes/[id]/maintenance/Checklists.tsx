'use client';
import * as React from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Icon } from '@/components/ui/Icon';
import { Input, Select } from '@/components/ui/forms';

// W2-10 — FR-QTR-01/02 quarterly + annual checklists. Generation goes only
// through generate_checklist (idempotent per programme/kind/period; returns
// the row id). The annual summary (the engine's frozen year pull) is
// read-only.
// #90 — each open item can be completed, ONLY through complete_checklist_item
// (no direct-table write exists: the client grants on checklist_instances
// are revoked). An evidence-slot item needs accepted evidence; any other item
// takes accepted evidence or a note. Completion is final. The RPC re-checks
// role, tenant and the accepted-evidence rule, and its error is shown as-is.

export interface ChecklistItem {
  ref?: string | null;
  label?: string | null;
  evidence_required?: boolean;
  evidence_id?: string | null;
  done?: boolean;
  note?: string | null;
  completed_at?: string | null;
}

/** accepted (decided + AO-accepted) evidence of this programme — the picker
    list; the RPC re-validates whatever is sent */
export interface ChecklistEvidence {
  id: string;
  evidence_ref: string | null;
  uploaded_at: string;
}

export interface ChecklistRow {
  id: string;
  kind: 'quarterly' | 'annual' | string;
  period: string;
  items: ChecklistItem[] | null;
  summary: Record<string, unknown> | null;
  generated_on: string;
}

export function Checklists({
  programmeId,
  rows,
  canRun,
  defaultQuarter,
  defaultYear,
  evidenceRefs,
  accepted,
  base,
}: {
  programmeId: string;
  rows: ChecklistRow[];
  canRun: boolean;
  defaultQuarter: string;
  defaultYear: string;
  evidenceRefs: Record<string, string | null>;
  accepted: ChecklistEvidence[];
  base: string;
}) {
  const router = useRouter();
  const [kind, setKind] = React.useState<'quarterly' | 'annual'>('quarterly');
  const [period, setPeriod] = React.useState(defaultQuarter);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});
  const [open, setOpen] = React.useState<string | null>(rows[0]?.id ?? null);

  function pickKind(k: 'quarterly' | 'annual') {
    setKind(k);
    setPeriod(k === 'quarterly' ? defaultQuarter : defaultYear);
  }

  async function generate(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMsg({});
    const existed = rows.some((r) => r.kind === kind && r.period === period.trim());
    const { data, error } = await browserClient().rpc('generate_checklist', {
      p_programme: programmeId,
      p_kind: kind,
      p_period: period.trim(),
    });
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    setMsg({
      ok: existed
        ? `The ${kind} checklist for ${period.trim()} already exists — kept unchanged.`
        : `${kind === 'annual' ? 'Annual' : 'Quarterly'} checklist for ${period.trim()} generated.`,
    });
    if (typeof data === 'string') setOpen(data);
    router.refresh();
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      {canRun ? (
        <form onSubmit={generate} style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <Select value={kind} onChange={(e) => pickKind(e.target.value as 'quarterly' | 'annual')} style={{ width: 160 }}>
            <option value="quarterly">Quarterly</option>
            <option value="annual">Annual review</option>
          </Select>
          <Input
            value={period}
            onChange={(e) => setPeriod(e.target.value)}
            placeholder={kind === 'quarterly' ? 'YYYY-Qn' : 'YYYY'}
            pattern={kind === 'quarterly' ? '\\d{4}-Q[1-4]' : '\\d{4}'}
            aria-label="Period"
            style={{ width: 120 }}
            required
          />
          <Button size="sm" type="submit" icon="list-checks" disabled={busy}>
            {busy ? 'Generating…' : 'Generate checklist'}
          </Button>
          <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Idempotent — re-running returns the existing checklist.</span>
        </form>
      ) : null}
      {msg.err ? <p className="sp-breach-msg is-err">{msg.err}</p> : null}
      {msg.ok ? <p className="sp-breach-msg is-ok">{msg.ok}</p> : null}

      {rows.length ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {rows.map((r) => {
            const items = r.items ?? [];
            const isOpen = open === r.id;
            const done = items.filter((i) => i.done).length;
            return (
              <div key={r.id} style={{ border: '1px solid var(--border, rgba(0,0,0,.1))', borderRadius: 8, padding: 12 }}>
                <button
                  type="button"
                  className="sp-thsort"
                  aria-expanded={isOpen}
                  onClick={() => setOpen(isOpen ? null : r.id)}
                  style={{ display: 'flex', gap: 8, alignItems: 'center', width: '100%', textAlign: 'left' }}
                >
                  <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size={14} />
                  <strong className="mono">{r.period}</strong>
                  <Badge tone={r.kind === 'annual' ? 'ink' : 'accent'}>{r.kind}</Badge>
                  <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                    {done}/{items.length} done · generated {r.generated_on}
                  </span>
                </button>
                {isOpen ? (
                  <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 12 }}>
                    <table className="sp-table">
                      <thead>
                        <tr>
                          <th>Ref</th>
                          <th>Item</th>
                          <th>Evidence</th>
                          <th>Done</th>
                          {canRun ? <th aria-label="Action" /> : null}
                        </tr>
                      </thead>
                      <tbody>
                        {items.map((it, idx) => (
                          <tr key={it.ref ?? idx}>
                            <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{it.ref ?? '—'}</td>
                            <td>{it.label ?? '—'}</td>
                            <td>
                              {it.evidence_id ? (
                                <Link href={`${base}/evidence/${it.evidence_id}`}>
                                  {evidenceRefs[it.evidence_id] ?? 'Evidence'} →
                                </Link>
                              ) : it.evidence_required ? (
                                <Badge tone="warn">slot open</Badge>
                              ) : (
                                <span className="muted">optional</span>
                              )}
                            </td>
                            <td>
                              {it.done ? (
                                <span title={it.note ?? undefined}>
                                  <Badge tone="pass" dot>done</Badge>
                                  {it.completed_at ? (
                                    <span className="muted mono" style={{ fontSize: 'var(--fs-xs)', marginLeft: 6 }}>
                                      {String(it.completed_at).slice(0, 10)}
                                    </span>
                                  ) : null}
                                </span>
                              ) : (
                                <span className="muted">—</span>
                              )}
                            </td>
                            {canRun ? (
                              <td>
                                {!it.done && it.ref ? (
                                  <CompleteItem
                                    checklistId={r.id}
                                    item={it}
                                    accepted={accepted}
                                    onDone={() => router.refresh()}
                                  />
                                ) : null}
                              </td>
                            ) : null}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                    {r.kind === 'annual' && r.summary ? <AnnualSummary summary={r.summary} /> : null}
                  </div>
                ) : null}
              </div>
            );
          })}
        </div>
      ) : (
        <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
          No quarterly or annual checklists yet.
        </div>
      )}
    </div>
  );
}

// #90 — one item's completion form. Writes ONLY via complete_checklist_item;
// on failure the RPC's message is shown and nothing else is attempted.
function CompleteItem({
  checklistId,
  item,
  accepted,
  onDone,
}: {
  checklistId: string;
  item: ChecklistItem;
  accepted: ChecklistEvidence[];
  onDone: () => void;
}) {
  const [open, setOpen] = React.useState(false);
  const [evidenceId, setEvidenceId] = React.useState('');
  const [note, setNote] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);
  const slot = !!item.evidence_required;

  if (!open) {
    return (
      <Button size="sm" variant="outline" icon="check" onClick={() => setOpen(true)}>
        Complete
      </Button>
    );
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    if (slot && !evidenceId) return setErr('This item has an evidence slot: pick accepted evidence.');
    if (!slot && !evidenceId && !note.trim()) return setErr('Pick accepted evidence or record a note of what was done.');
    setBusy(true);
    const { error } = await browserClient().rpc('complete_checklist_item', {
      p_checklist_id: checklistId,
      p_item_key: item.ref,
      p_evidence_id: evidenceId || null,
      p_note: note.trim() || null,
    });
    setBusy(false);
    if (error) return setErr(error.message);
    setOpen(false);
    onDone();
  }

  return (
    <form onSubmit={submit} style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 220 }}>
      <Select value={evidenceId} onChange={(e) => setEvidenceId(e.target.value)} aria-label="Accepted evidence">
        <option value="">{slot ? 'Choose accepted evidence…' : 'No evidence (note only)'}</option>
        {accepted.map((ev) => (
          <option key={ev.id} value={ev.id}>
            {ev.evidence_ref ?? ev.id.slice(0, 8)} · {ev.uploaded_at.slice(0, 10)}
          </option>
        ))}
      </Select>
      <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder={slot ? 'Note (optional)' : 'Note'} aria-label="Note" />
      {slot && !accepted.length ? (
        <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>No accepted evidence in this programme yet.</span>
      ) : null}
      <div style={{ display: 'flex', gap: 6 }}>
        <Button size="sm" type="submit" disabled={busy}>{busy ? 'Saving…' : 'Mark done'}</Button>
        <Button size="sm" variant="ghost" type="button" onClick={() => { setOpen(false); setErr(null); }} disabled={busy}>
          Cancel
        </Button>
      </div>
      <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Completion is final.</span>
      {err ? <p className="sp-breach-msg is-err" role="alert">{err}</p> : null}
    </form>
  );
}

// FR-QTR-02 — the annual data pull frozen at generation; read-only.
function AnnualSummary({ summary }: { summary: Record<string, unknown> }) {
  const g = (path: string): unknown =>
    path.split('.').reduce<unknown>((o, k) => (o && typeof o === 'object' ? (o as Record<string, unknown>)[k] : undefined), summary);
  const v = (path: string, suffix = '') => {
    const x = g(path);
    return x == null ? '—' : `${x}${suffix}`;
  };
  const figures: [string, string][] = [
    ['Findings closed', `${v('register.closed')} / ${v('register.total')} (${v('register.closed_pct', '%')})`],
    ['Findings closed in year', v('register.closed_in_year')],
    ['Evidence uploaded in year', v('evidence.uploaded_in_year')],
    ['Evidence decided / pending', `${v('evidence.decided')} / ${v('evidence.pending')}`],
    ['Training records (attended)', `${v('training.records_in_year')} (${v('training.attended_in_year')})`],
    ['Breaches', v('operational.breaches_in_year')],
    ['DSRs', v('operational.dsrs_in_year')],
    ['Disclosures', v('operational.disclosures_in_year')],
    ['Opt-outs', v('operational.optouts_in_year')],
    ['Maintenance complete / total', `${v('maintenance.complete')} / ${v('maintenance.instances')}`],
    ['Maintenance exceptions', v('maintenance.exceptions')],
  ];
  const months = (g('months') ?? {}) as Record<string, Record<string, unknown>>;
  const monthKeys = Object.keys(months).sort();

  return (
    <div>
      <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginBottom: 6 }}>
        Annual review figures (frozen {String(g('generated_at') ?? '').slice(0, 10) || 'at generation'}; read-only)
      </div>
      <table className="sp-table">
        <tbody>
          {figures.map(([label, value]) => (
            <tr key={label}>
              <td className="muted">{label}</td>
              <td className="mono" style={{ textAlign: 'right' }}>{value}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {monthKeys.length ? (
        <table className="sp-table" style={{ marginTop: 10 }}>
          <thead>
            <tr>
              <th>Month</th>
              <th>RAG</th>
              <th style={{ textAlign: 'right' }}>Maint. done</th>
              <th style={{ textAlign: 'right' }}>Maint. overdue</th>
              <th style={{ textAlign: 'right' }}>Findings closed</th>
              <th style={{ textAlign: 'right' }}>Activities overdue</th>
            </tr>
          </thead>
          <tbody>
            {monthKeys.map((m) => {
              const s = months[m] ?? {};
              const c = (k: string) => (s[k] == null ? '—' : String(s[k]));
              return (
                <tr key={m}>
                  <td className="mono">{m}</td>
                  <td>{c('rag')}</td>
                  <td className="mono" style={{ textAlign: 'right' }}>{c('maintenance_done')}</td>
                  <td className="mono" style={{ textAlign: 'right' }}>{c('maintenance_overdue')}</td>
                  <td className="mono" style={{ textAlign: 'right' }}>{c('register_closed')}</td>
                  <td className="mono" style={{ textAlign: 'right' }}>{c('activities_overdue')}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      ) : null}
    </div>
  );
}
