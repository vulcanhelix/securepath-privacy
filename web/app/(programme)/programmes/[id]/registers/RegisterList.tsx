'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Icon } from '@/components/ui/Icon';
import { EmptyState } from '@/components/ui/EmptyState';
import { StatusPill } from '@/components/ui/StatusPill';
import { Field, Input, Select, Textarea } from '@/components/ui/forms';
import { ReportBreachButton } from '@/components/programme/ReportBreachButton';

// W2-09 — one operational register (dsr | breach | disclosure | optout).
// Every mutation is a W1-04 RPC under the caller's JWT, then router.refresh():
//   record_dsr / create_operational_record — client write role
//   record_breach (via ReportBreachButton)  — anyone who can see the client
//   record_breach_decision                  — AO or named alternate only
//   close_operational_record                — client write role; breach needs lessons learned
// due_date, closed_on and regulator_notification are write-protected columns:
// rendered read-only here, never edited. If an RPC errors, its message is
// shown and nothing else is written — there is no direct-table fallback.

export interface OpRecord {
  id: string;
  client_org_id: string;
  type: 'dsr' | 'breach' | 'disclosure' | 'optout';
  description: string | null;
  reported_at: string;
  reported_by: string | null;
  site: string | null;
  channel: string | null;
  deadline_rule: string | null;
  deadline_params: Record<string, unknown> | null;
  due_date: string | null;
  status: 'Open' | 'In progress' | 'Awaiting decision' | 'Closed';
  outcome: string | null;
  regulator_notification: RegulatorNotification | null;
  closed_on: string | null;
  created_at: string;
}
interface DecisionEntry {
  decision: 'notified' | 'not_notified' | 'partial';
  rationale: string | null;
  decided_by: string | null;
  decided_at: string;
}
interface RegulatorNotification extends Partial<DecisionEntry> {
  rule?: string | null;
  history?: DecisionEntry[];
}
export interface Person {
  id: string;
  label: string;
}

const DECISION_LABEL: Record<string, string> = {
  notified: 'Regulator notified',
  not_notified: 'Not notified',
  partial: 'Partially notified',
};
const DECISION_TONE: Record<string, 'pass' | 'warn' | 'neutral'> = {
  notified: 'pass',
  partial: 'warn',
  not_notified: 'neutral',
};
const DEADLINE_LABEL: Record<OpRecord['type'], string> = {
  dsr: 'Response due',
  breach: 'Notification due',
  disclosure: 'Due',
  optout: 'Action due',
};

/** Render a stored `date` verbatim ("14 Nov 2026") — no timezone shift on a date-only value. */
function fmtDate(iso: string | null | undefined): string {
  if (!iso) return '—';
  const d = new Date(`${String(iso).slice(0, 10)}T00:00:00Z`);
  if (isNaN(d.getTime())) return String(iso);
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
}

type Ctx = {
  clientId: string;
  tz: string;
  canWrite: boolean;
  isAo: boolean;
  who: (id: string | null | undefined) => string;
  ts: (iso: string | null | undefined) => string;
};

export function RegisterList({
  clientId,
  clientName,
  type,
  records,
  overdueIds,
  people,
  tz,
  canWrite,
  isAo,
  filtered,
}: {
  clientId: string;
  clientName: string;
  type: OpRecord['type'];
  records: OpRecord[];
  overdueIds: string[];
  people: Person[];
  tz: string;
  canWrite: boolean;
  isAo: boolean;
  filtered: boolean;
}) {
  const [open, setOpen] = React.useState<string | null>(null);
  const names = React.useMemo(() => new Map(people.map((p) => [p.id, p.label])), [people]);
  const overdue = React.useMemo(() => new Set(overdueIds), [overdueIds]);
  const fmt = React.useMemo(
    () => new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: tz }),
    [tz]
  );
  const ctx: Ctx = {
    clientId,
    tz,
    canWrite,
    isAo,
    who: (id) => (id ? names.get(id) ?? `user ${id.slice(0, 8)}` : '—'),
    ts: (iso) => {
      if (!iso) return '—';
      const d = new Date(iso);
      return isNaN(d.getTime()) ? iso : fmt.format(d);
    },
  };

  return (
    <>
      {type === 'breach' ? (
        <div style={{ marginBottom: 12, display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
          <ReportBreachButton clients={[{ id: clientId, name: clientName }]} defaultClientId={clientId} />
          <span className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
            Anyone who can see this client may report. The accountable officer decides on notification.
          </span>
        </div>
      ) : canWrite ? (
        <CreateRecord ctx={ctx} type={type} />
      ) : null}

      <Card pad={0}>
        {records.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th style={{ width: 28 }} />
                  <th>Reported</th>
                  <th>Description</th>
                  {type === 'dsr' ? <th>Kind</th> : null}
                  {type === 'breach' ? <th>Decision</th> : null}
                  <th>{DEADLINE_LABEL[type]}</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {records.map((r) => {
                  const isOpen = open === r.id;
                  const late = overdue.has(r.id);
                  const kind = (r.deadline_params?.kind as string | undefined) ?? null;
                  const dec = r.regulator_notification?.decision ?? null;
                  return (
                    <React.Fragment key={r.id}>
                      <tr>
                        <td>
                          <button
                            type="button"
                            className="sp-thsort"
                            aria-expanded={isOpen}
                            aria-label={isOpen ? 'Collapse' : 'Expand'}
                            onClick={() => setOpen(isOpen ? null : r.id)}
                          >
                            <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size={14} />
                          </button>
                        </td>
                        <td className="mono muted" style={{ fontSize: 'var(--fs-xs)', whiteSpace: 'nowrap' }}>
                          {ctx.ts(r.reported_at)}
                          <div>{ctx.who(r.reported_by)}</div>
                        </td>
                        <td style={{ maxWidth: 420 }}>
                          <div style={{ fontWeight: 500 }}>{r.description || '—'}</div>
                          {r.site ? <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{r.site}</div> : null}
                        </td>
                        {type === 'dsr' ? <td className="muted">{kind ?? '—'}</td> : null}
                        {type === 'breach' ? (
                          <td>
                            {dec ? (
                              <Badge tone={DECISION_TONE[dec]}>{DECISION_LABEL[dec] ?? dec}</Badge>
                            ) : (
                              <span className="muted">Awaiting AO</span>
                            )}
                          </td>
                        ) : null}
                        <td className="mono" style={{ fontSize: 'var(--fs-xs)', color: late ? 'var(--fail)' : 'var(--muted)' }}>
                          {r.due_date ? fmtDate(r.due_date) : r.deadline_rule ? 'pending' : 'no statutory clock'}
                          {late ? <div><Badge tone="fail">overdue</Badge></div> : null}
                        </td>
                        <td><StatusPill status={r.status} /></td>
                      </tr>
                      {isOpen ? (
                        <tr>
                          <td />
                          <td colSpan={type === 'dsr' || type === 'breach' ? 5 : 4} style={{ background: 'var(--surface-card)' }}>
                            <RecordDetail ctx={ctx} record={r} />
                          </td>
                        </tr>
                      ) : null}
                    </React.Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState
            icon="inbox"
            message={filtered ? 'No records match these filters.' : 'Nothing logged in this register yet.'}
          />
        )}
      </Card>
    </>
  );
}

function useRpc() {
  const router = useRouter();
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});
  const run = async (fn: string, args: Record<string, unknown>, ok: string) => {
    setBusy(true);
    setMsg({});
    const { error } = await browserClient().rpc(fn, args);
    setBusy(false);
    if (error) {
      setMsg({ err: error.message });
      return false;
    }
    setMsg({ ok });
    router.refresh();
    return true;
  };
  return { busy, msg, run };
}

function Msg({ msg }: { msg: { ok?: string; err?: string } }) {
  if (msg.err) return <p className="sp-breach-msg is-err">{msg.err}</p>;
  if (msg.ok) return <p className="sp-breach-msg is-ok">{msg.ok}</p>;
  return null;
}

const CREATE_LABEL: Record<string, string> = {
  dsr: 'Log data subject request',
  disclosure: 'Log disclosure',
  optout: 'Log opt-out or objection',
};

function CreateRecord({ ctx, type }: { ctx: Ctx; type: OpRecord['type'] }) {
  const empty = { kind: 'access', received_on: '', details: '', description: '', site: '', channel: '' };
  const [show, setShow] = React.useState(false);
  const [f, setF] = React.useState(empty);
  const { busy, msg, run } = useRpc();
  const set = (k: keyof typeof f) => (v: string) => setF((p) => ({ ...p, [k]: v }));

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    const ok =
      type === 'dsr'
        ? await run(
            'record_dsr',
            {
              p_client_org: ctx.clientId,
              p_kind: f.kind.trim(),
              p_received_on: f.received_on,
              p_details: f.details.trim() || null,
            },
            'Request logged — the response deadline comes from the jurisdiction pack.'
          )
        : await run(
            'create_operational_record',
            {
              p_client_org: ctx.clientId,
              p_register_type: type,
              p_payload: {
                description: f.description.trim(),
                ...(f.site.trim() ? { site: f.site.trim() } : {}),
                ...(f.channel.trim() ? { channel: f.channel.trim() } : {}),
              },
            },
            'Record logged.'
          );
    if (ok) setF(empty);
  }

  if (!show) {
    return (
      <div style={{ marginBottom: 12 }}>
        <Button size="sm" icon="plus" onClick={() => setShow(true)}>{CREATE_LABEL[type]}</Button>
        <Msg msg={msg} />
      </div>
    );
  }
  const valid = type === 'dsr' ? !!f.kind.trim() && !!f.received_on : !!f.description.trim();
  return (
    <Card style={{ marginBottom: 16 }}>
      <form onSubmit={submit} style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))' }}>
        {type === 'dsr' ? (
          <>
            <Field label="Kind" required hint="Access, rectification, erasure, portability, objection…">
              <Input list="dsr-kinds" value={f.kind} onChange={(e) => set('kind')(e.target.value)} required />
              <datalist id="dsr-kinds">
                {['access', 'rectification', 'erasure', 'portability', 'objection', 'restriction'].map((k) => (
                  <option key={k} value={k} />
                ))}
              </datalist>
            </Field>
            <Field label="Received on" required hint={`The deadline anchor (client calendar, ${ctx.tz})`}>
              <Input type="date" value={f.received_on} onChange={(e) => set('received_on')(e.target.value)} required />
            </Field>
            <div style={{ gridColumn: '1 / -1' }}>
              <Field label="Details">
                <Textarea value={f.details} onChange={(e) => set('details')(e.target.value)} style={{ minHeight: 60 }} />
              </Field>
            </div>
          </>
        ) : (
          <>
            <div style={{ gridColumn: '1 / -1' }}>
              <Field label="Description" required>
                <Textarea value={f.description} onChange={(e) => set('description')(e.target.value)} required style={{ minHeight: 60 }} />
              </Field>
            </div>
            <Field label="Site">
              <Input value={f.site} onChange={(e) => set('site')(e.target.value)} />
            </Field>
            <Field label="Channel" hint="How it arrived (email, phone, portal…)">
              <Input value={f.channel} onChange={(e) => set('channel')(e.target.value)} />
            </Field>
          </>
        )}
        <div style={{ gridColumn: '1 / -1', display: 'flex', gap: 8, alignItems: 'center' }}>
          <Button size="sm" type="submit" disabled={busy || !valid}>{busy ? 'Saving…' : 'Log record'}</Button>
          <Button size="sm" variant="ghost" type="button" onClick={() => setShow(false)}>Cancel</Button>
          <Msg msg={msg} />
        </div>
      </form>
    </Card>
  );
}

function RecordDetail({ ctx, record: r }: { ctx: Ctx; record: OpRecord }) {
  const closed = r.status === 'Closed';
  const isBreach = r.type === 'breach';
  const history = [...(r.regulator_notification?.history ?? [])].reverse(); // newest first
  const params = r.deadline_params ?? {};
  const suspected = (params.suspected_on as string | undefined) ?? null;
  const received = (params.received_on as string | undefined) ?? null;

  return (
    <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', padding: '8px 0' }}>
      <div style={{ flex: '1 1 280px', display: 'flex', flexDirection: 'column', gap: 6, fontSize: 'var(--fs-sm)', minWidth: 0 }}>
        {suspected ? <div><span className="muted">Suspected on: </span>{fmtDate(suspected)}</div> : null}
        {received ? <div><span className="muted">Received on: </span>{fmtDate(received)}</div> : null}
        <div><span className="muted">Deadline rule: </span><span className="mono">{r.deadline_rule ?? '—'}</span></div>
        <div><span className="muted">Due (from jurisdiction pack): </span>{fmtDate(r.due_date)}</div>
        <div><span className="muted">Channel: </span>{r.channel ?? '—'}</div>
        {r.outcome ? (
          <div style={{ whiteSpace: 'pre-wrap' }}><span className="muted">Outcome / closure notes: </span>{r.outcome}</div>
        ) : null}
        {closed ? <div><span className="muted">Closed: </span>{ctx.ts(r.closed_on)}</div> : null}
      </div>

      {isBreach ? (
        <div style={{ flex: '1 1 320px', display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0 }}>
          <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Notification decisions (append-only)</div>
          {history.length ? (
            <ol style={{ margin: 0, paddingLeft: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
              {history.map((h, i) => (
                <li key={i} style={{ fontSize: 'var(--fs-sm)' }}>
                  <Badge tone={DECISION_TONE[h.decision] ?? 'neutral'}>{DECISION_LABEL[h.decision] ?? h.decision}</Badge>{' '}
                  <span className="muted">{ctx.ts(h.decided_at)} · {ctx.who(h.decided_by)}</span>
                  {h.rationale ? <div style={{ whiteSpace: 'pre-wrap' }}>{h.rationale}</div> : null}
                </li>
              ))}
            </ol>
          ) : (
            <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>No decision recorded yet.</div>
          )}
          {ctx.isAo && !closed ? <DecisionPanel recordId={r.id} /> : null}
        </div>
      ) : null}

      {ctx.canWrite && !closed ? (
        <div style={{ flex: '1 1 260px', minWidth: 0 }}>
          <ClosePanel recordId={r.id} isBreach={isBreach} />
        </div>
      ) : null}
    </div>
  );
}

function DecisionPanel({ recordId }: { recordId: string }) {
  const [decision, setDecision] = React.useState('');
  const [rationale, setRationale] = React.useState('');
  const { busy, msg, run } = useRpc();
  return (
    <form
      onSubmit={async (e) => {
        e.preventDefault();
        if (!decision) return;
        const ok = await run(
          'record_breach_decision',
          { p_record: recordId, p_decision: decision, p_rationale: rationale.trim() || null },
          'Decision recorded.'
        );
        if (ok) {
          setDecision('');
          setRationale('');
        }
      }}
      style={{ display: 'flex', flexDirection: 'column', gap: 8, borderTop: '1px solid var(--line, #e5e5e5)', paddingTop: 10 }}
    >
      <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
        Accountable officer decision (FR-ACC-02)
      </div>
      <Select value={decision} onChange={(e) => setDecision(e.target.value)} required aria-label="Decision">
        <option value="">Choose a decision…</option>
        <option value="notified">Regulator notified</option>
        <option value="not_notified">Not notified</option>
        <option value="partial">Partially notified</option>
      </Select>
      <Textarea
        placeholder="Rationale under the jurisdiction's rule"
        value={rationale}
        onChange={(e) => setRationale(e.target.value)}
        style={{ minHeight: 60 }}
      />
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <Button size="sm" type="submit" disabled={busy || !decision}>{busy ? 'Recording…' : 'Record decision'}</Button>
        <Msg msg={msg} />
      </div>
    </form>
  );
}

function ClosePanel({ recordId, isBreach }: { recordId: string; isBreach: boolean }) {
  const [note, setNote] = React.useState('');
  const { busy, msg, run } = useRpc();
  const needsNote = isBreach && !note.trim();
  return (
    <form
      onSubmit={async (e) => {
        e.preventDefault();
        if (needsNote) return;
        if (await run('close_operational_record', { p_record: recordId, p_closure_note: note.trim() || null }, 'Closed.')) {
          setNote('');
        }
      }}
      style={{ display: 'flex', flexDirection: 'column', gap: 8 }}
    >
      <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Close record</div>
      <Textarea
        placeholder={isBreach ? 'Lessons learned (required to close a breach)' : 'Closure note (optional)'}
        value={note}
        onChange={(e) => setNote(e.target.value)}
        required={isBreach}
        style={{ minHeight: 60 }}
      />
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <Button size="sm" variant="outline" type="submit" disabled={busy || needsNote}>
          {busy ? 'Closing…' : 'Close'}
        </Button>
        <Msg msg={msg} />
      </div>
    </form>
  );
}
