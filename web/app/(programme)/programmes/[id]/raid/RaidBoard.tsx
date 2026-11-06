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

// W2-11 — RAID board. Every mutation is a W1-06 RPC under the caller's JWT:
//   create_raid_item / record_decision  — RAID+ roles (WRITE + executive, AO)
//   update_raid_item / resolve_raid_item — WRITE roles
// raid_status_history and decisions are append-only ledgers: rendered
// read-only, never edited (DB triggers reject UPDATE/DELETE regardless).

export interface RaidItem {
  id: string;
  programme_id: string;
  type: 'risk' | 'assumption' | 'issue';
  description: string;
  impact: string | null;
  action: string | null;
  owner: string | null;
  raised_on: string;
  review_by: string | null;
  status: 'Open' | 'In progress' | 'Closed';
  source: string;
  created_at: string;
}
export interface RaidHistory {
  id: string;
  raid_item_id: string;
  old_status: string | null;
  new_status: string;
  changed_by: string | null;
  changed_at: string;
  note: string | null;
}
export interface Decision {
  id: string;
  raid_item_id: string;
  outcome: string;
  decided_on: string;
  minute_ref: string | null;
  unlocks: unknown;
  decided_by: string | null;
  created_at: string;
}
export interface Person {
  id: string;
  label: string;
}

const TYPE_TONE: Record<string, 'fail' | 'warn' | 'accent'> = { risk: 'warn', issue: 'fail', assumption: 'accent' };
const STATUS_TONES = { 'in progress': 'accent', open: 'warn', closed: 'pass' } as const;
const label = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const unlockList = (u: unknown): string[] =>
  Array.isArray(u) ? u.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))) : [];

type Ctx = {
  programmeId: string;
  people: Person[];
  today: string;
  canWrite: boolean;
  canRaise: boolean;
  who: (id: string | null) => string;
};

export function RaidBoard({
  programmeId,
  items,
  history,
  decisions,
  people,
  today,
  canWrite,
  canRaise,
  filtered,
}: {
  programmeId: string;
  items: RaidItem[];
  history: RaidHistory[];
  decisions: Decision[];
  people: Person[];
  today: string;
  canWrite: boolean;
  canRaise: boolean;
  filtered: boolean;
}) {
  const [open, setOpen] = React.useState<string | null>(null);
  const names = React.useMemo(() => new Map(people.map((p) => [p.id, p.label])), [people]);
  const who = React.useCallback(
    (id: string | null) => (id ? names.get(id) ?? `user ${id.slice(0, 8)}` : '—'),
    [names]
  );
  const ctx: Ctx = { programmeId, people, today, canWrite, canRaise, who };
  const itemById = React.useMemo(() => new Map(items.map((i) => [i.id, i])), [items]);

  return (
    <>
      {canRaise ? <CreateRaid ctx={ctx} /> : null}

      <Card pad={0} style={{ marginBottom: 24 }}>
        {items.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th style={{ width: 28 }} />
                  <th>Type</th>
                  <th>Description</th>
                  <th>Owner</th>
                  <th>Raised</th>
                  <th>Review by</th>
                  <th>Status</th>
                  <th style={{ textAlign: 'right' }}>Decisions</th>
                </tr>
              </thead>
              <tbody>
                {items.map((i) => {
                  const isOpen = open === i.id;
                  const overdue = i.status !== 'Closed' && !!i.review_by && i.review_by < today;
                  const decs = decisions.filter((d) => d.raid_item_id === i.id);
                  return (
                    <React.Fragment key={i.id}>
                      <tr>
                        <td>
                          <button
                            type="button"
                            className="sp-thsort"
                            aria-expanded={isOpen}
                            aria-label={isOpen ? 'Collapse' : 'Expand'}
                            onClick={() => setOpen(isOpen ? null : i.id)}
                          >
                            <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size={14} />
                          </button>
                        </td>
                        <td>
                          <Badge tone={TYPE_TONE[i.type]}>{label(i.type)}</Badge>
                        </td>
                        <td style={{ maxWidth: 420 }}>
                          <div style={{ fontWeight: 500 }}>{i.description}</div>
                          {i.source !== 'manual' ? (
                            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>from {i.source}</div>
                          ) : null}
                        </td>
                        <td className="muted">{who(i.owner)}</td>
                        <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>{i.raised_on}</td>
                        <td className="mono" style={{ fontSize: 'var(--fs-xs)', color: overdue ? 'var(--fail)' : 'var(--muted)' }}>
                          {i.review_by ?? '—'}
                          {overdue ? <div><Badge tone="fail">past review</Badge></div> : null}
                        </td>
                        <td><StatusPill status={i.status} map={STATUS_TONES} /></td>
                        <td className="mono muted" style={{ textAlign: 'right' }}>{decs.length || '—'}</td>
                      </tr>
                      {isOpen ? (
                        <tr>
                          <td />
                          <td colSpan={7} style={{ background: 'var(--surface-card)' }}>
                            <RaidDetail
                              ctx={ctx}
                              item={i}
                              history={history.filter((h) => h.raid_item_id === i.id)}
                              decisions={decs}
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
        ) : (
          <EmptyState
            icon="alert-triangle"
            message={
              filtered
                ? 'No RAID items match these filters.'
                : 'No RAID items yet. Opening entries load from the framework template; raise new ones above.'
            }
          />
        )}
      </Card>

      <h2 style={{ fontSize: 'var(--fs-md, 1rem)', margin: '0 0 10px' }}>Decision log</h2>
      <Card pad={0}>
        {decisions.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Decided</th>
                  <th>Outcome</th>
                  <th>RAID item</th>
                  <th>Minute ref</th>
                  <th>Unlocks</th>
                  <th>By</th>
                </tr>
              </thead>
              <tbody>
                {decisions.map((d) => (
                  <tr key={d.id}>
                    <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{d.decided_on}</td>
                    <td style={{ maxWidth: 380 }}>{d.outcome}</td>
                    <td className="muted" style={{ maxWidth: 260 }}>
                      {itemById.get(d.raid_item_id)?.description ?? 'filtered out'}
                    </td>
                    <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>{d.minute_ref ?? '—'}</td>
                    <td className="muted">{unlockList(d.unlocks).join(', ') || '—'}</td>
                    <td className="muted">{who(d.decided_by)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState icon="gavel" message="No decisions recorded yet. Record one against its RAID item." />
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

function OwnerSelect({ ctx, value, onChange }: { ctx: Ctx; value: string; onChange: (v: string) => void }) {
  return (
    <Select value={value} onChange={(e) => onChange(e.target.value)}>
      <option value="">— unassigned —</option>
      {ctx.people.map((p) => (
        <option key={p.id} value={p.id}>{p.label}</option>
      ))}
    </Select>
  );
}

function CreateRaid({ ctx }: { ctx: Ctx }) {
  const [show, setShow] = React.useState(false);
  const [f, setF] = React.useState({ type: 'risk', description: '', impact: '', action: '', owner: '', review_by: '' });
  const { busy, msg, run } = useRpc();
  const set = (k: keyof typeof f) => (v: string) => setF((p) => ({ ...p, [k]: v }));

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    const ok = await run(
      'create_raid_item',
      {
        p_programme_id: ctx.programmeId,
        p_type: f.type,
        p_description: f.description.trim(),
        p_impact: f.impact.trim() || null,
        p_action: f.action.trim() || null,
        p_owner: f.owner || null,
        p_review_by: f.review_by || null,
      },
      'RAID item raised.'
    );
    if (ok) setF({ type: 'risk', description: '', impact: '', action: '', owner: '', review_by: '' });
  }

  if (!show) {
    return (
      <div style={{ marginBottom: 12 }}>
        <Button size="sm" icon="plus" onClick={() => setShow(true)}>Raise RAID item</Button>
        <Msg msg={msg} />
      </div>
    );
  }
  return (
    <Card style={{ marginBottom: 16 }}>
      <form onSubmit={submit} style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))' }}>
        <Field label="Type" required>
          <Select value={f.type} onChange={(e) => set('type')(e.target.value)}>
            <option value="risk">Risk</option>
            <option value="assumption">Assumption</option>
            <option value="issue">Issue</option>
          </Select>
        </Field>
        <Field label="Owner">
          <OwnerSelect ctx={ctx} value={f.owner} onChange={set('owner')} />
        </Field>
        <Field label="Review by" hint="Past-date items surface on the weekly agenda">
          <Input type="date" value={f.review_by} onChange={(e) => set('review_by')(e.target.value)} />
        </Field>
        <div style={{ gridColumn: '1 / -1' }}>
          <Field label="Description" required>
            <Textarea value={f.description} onChange={(e) => set('description')(e.target.value)} required style={{ minHeight: 60 }} />
          </Field>
        </div>
        <Field label="Impact">
          <Input value={f.impact} onChange={(e) => set('impact')(e.target.value)} />
        </Field>
        <Field label="Action">
          <Input value={f.action} onChange={(e) => set('action')(e.target.value)} />
        </Field>
        <div style={{ gridColumn: '1 / -1', display: 'flex', gap: 8, alignItems: 'center' }}>
          <Button size="sm" type="submit" disabled={busy || !f.description.trim()}>{busy ? 'Saving…' : 'Raise item'}</Button>
          <Button size="sm" variant="ghost" type="button" onClick={() => setShow(false)}>Cancel</Button>
          <Msg msg={msg} />
        </div>
      </form>
    </Card>
  );
}

function RaidDetail({
  ctx,
  item,
  history,
  decisions,
}: {
  ctx: Ctx;
  item: RaidItem;
  history: RaidHistory[];
  decisions: Decision[];
}) {
  const { busy, msg, run } = useRpc();
  const [note, setNote] = React.useState('');
  const [edit, setEdit] = React.useState({
    impact: item.impact ?? '',
    action: item.action ?? '',
    owner: item.owner ?? '',
    review_by: item.review_by ?? '',
  });
  const [dec, setDec] = React.useState({ outcome: '', minute_ref: '', decided_on: ctx.today, unlocks: '' });
  const closed = item.status === 'Closed';

  // update_raid_item is patch-style (NULL = unchanged), so only send changes
  const changed = (k: keyof typeof edit, orig: string | null) => (edit[k] !== (orig ?? '') && edit[k] !== '' ? edit[k] : null);

  return (
    <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', padding: '8px 0' }}>
      <div style={{ flex: '1 1 300px', display: 'flex', flexDirection: 'column', gap: 12, minWidth: 0 }}>
        <div style={{ fontSize: 'var(--fs-sm)' }}>
          <div><span className="muted">Impact: </span>{item.impact || '—'}</div>
          <div><span className="muted">Action: </span>{item.action || '—'}</div>
        </div>

        {ctx.canWrite ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Status</div>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {item.status === 'Open' ? (
                <Button size="sm" variant="outline" disabled={busy}
                  onClick={() => run('update_raid_item', { p_raid_item_id: item.id, p_status: 'In progress' }, 'Moved to In progress.')}>
                  Start
                </Button>
              ) : null}
              {item.status === 'In progress' ? (
                <Button size="sm" variant="outline" disabled={busy}
                  onClick={() => run('update_raid_item', { p_raid_item_id: item.id, p_status: 'Open' }, 'Moved back to Open.')}>
                  Back to Open
                </Button>
              ) : null}
              {closed ? (
                <Button size="sm" variant="outline" disabled={busy}
                  onClick={() => run('update_raid_item', { p_raid_item_id: item.id, p_status: 'Open' }, 'Reopened.')}>
                  Reopen
                </Button>
              ) : null}
            </div>
            {!closed ? (
              <div style={{ display: 'flex', gap: 8 }}>
                <Input placeholder="Resolution note" value={note} onChange={(e) => setNote(e.target.value)} />
                <Button size="sm" disabled={busy}
                  onClick={async () => {
                    if (await run('resolve_raid_item', { p_raid_item_id: item.id, p_note: note.trim() || null }, 'Resolved.')) setNote('');
                  }}>
                  Resolve
                </Button>
              </div>
            ) : null}

            <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 6 }}>Edit</div>
            <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))' }}>
              <Input placeholder="Impact" value={edit.impact} onChange={(e) => setEdit({ ...edit, impact: e.target.value })} />
              <Input placeholder="Action" value={edit.action} onChange={(e) => setEdit({ ...edit, action: e.target.value })} />
              <OwnerSelect ctx={ctx} value={edit.owner} onChange={(v) => setEdit({ ...edit, owner: v })} />
              <Input type="date" value={edit.review_by} onChange={(e) => setEdit({ ...edit, review_by: e.target.value })} />
            </div>
            <div>
              <Button size="sm" variant="outline" disabled={busy}
                onClick={() =>
                  run('update_raid_item', {
                    p_raid_item_id: item.id,
                    p_impact: changed('impact', item.impact),
                    p_action: changed('action', item.action),
                    p_owner: changed('owner', item.owner),
                    p_review_by: changed('review_by', item.review_by),
                  }, 'Saved.')
                }>
                Save changes
              </Button>
            </div>
          </div>
        ) : null}
        <Msg msg={msg} />

        <div>
          <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginBottom: 6 }}>Status history (append-only)</div>
          {history.length ? (
            <table className="sp-table">
              <tbody>
                {history.map((h) => (
                  <tr key={h.id}>
                    <td className="mono muted" style={{ fontSize: 'var(--fs-xs)', whiteSpace: 'nowrap' }}>
                      {new Date(h.changed_at).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' })}
                    </td>
                    <td style={{ whiteSpace: 'nowrap' }}>{h.old_status ?? '—'} → {h.new_status}</td>
                    <td className="muted">{who(ctx, h.changed_by)}</td>
                    <td className="muted">{h.note ?? ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>No transitions yet — raised {item.raised_on} as {item.status}.</div>
          )}
        </div>
      </div>

      <div style={{ flex: '1 1 280px', display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0 }}>
        <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Decisions (append-only)</div>
        {decisions.length ? (
          decisions.map((d) => (
            <div key={d.id} style={{ fontSize: 'var(--fs-sm)', borderLeft: '2px solid var(--border)', paddingLeft: 10 }}>
              <div>{d.outcome}</div>
              <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                {d.decided_on}
                {d.minute_ref ? ` · minute ${d.minute_ref}` : ''} · {who(ctx, d.decided_by)}
                {unlockList(d.unlocks).length ? ` · unlocks ${unlockList(d.unlocks).join(', ')}` : ''}
              </div>
            </div>
          ))
        ) : (
          <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>None recorded.</div>
        )}

        {ctx.canRaise ? (
          <form
            onSubmit={async (e) => {
              e.preventDefault();
              const unlocks = dec.unlocks.split(',').map((s) => s.trim()).filter(Boolean);
              const ok = await run('record_decision', {
                p_raid_item_id: item.id,
                p_outcome: dec.outcome.trim(),
                p_minute_ref: dec.minute_ref.trim() || null,
                p_unlocks: unlocks,
                p_decided_on: dec.decided_on || null,
              }, 'Decision recorded.');
              if (ok) setDec({ outcome: '', minute_ref: '', decided_on: ctx.today, unlocks: '' });
            }}
            style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 6 }}
          >
            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Record decision</div>
            <Textarea placeholder="Outcome" value={dec.outcome} required style={{ minHeight: 56 }}
              onChange={(e) => setDec({ ...dec, outcome: e.target.value })} />
            <div style={{ display: 'flex', gap: 8 }}>
              <Input type="date" value={dec.decided_on} max={ctx.today} onChange={(e) => setDec({ ...dec, decided_on: e.target.value })} />
              <Input placeholder="Minute ref" value={dec.minute_ref} onChange={(e) => setDec({ ...dec, minute_ref: e.target.value })} />
            </div>
            <Input placeholder="Unlocks (comma-separated)" value={dec.unlocks} onChange={(e) => setDec({ ...dec, unlocks: e.target.value })} />
            <div>
              <Button size="sm" type="submit" disabled={busy || !dec.outcome.trim()}>Record decision</Button>
            </div>
            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Decisions cannot be edited once recorded.</div>
          </form>
        ) : null}
      </div>
    </div>
  );
}

function who(ctx: Ctx, id: string | null) {
  return ctx.who(id);
}
