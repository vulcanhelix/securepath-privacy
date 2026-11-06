'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Icon } from '@/components/ui/Icon';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field, Input, Select } from '@/components/ui/forms';

// W2-12 — document register. Every mutation is a W2-12 RPC under the
// caller's JWT (20261106000017_docs_training.sql):
//   register_controlled_document / update_controlled_document /
//   set_document_review_date / link_document_activity /
//   unlink_document_activity / withdraw_controlled_document — WRITE roles
//   issue_controlled_document — WRITE roles + accountable officer
// Issued, superseded and withdrawn versions render read-only (NFR-09: the DB
// trigger refuses any content change); a correction is a new version.

export interface DocActivity {
  id: string;
  ref: string;
  text: string;
  programme_id: string;
  active: boolean;
  status: string;
}
export interface DocRow {
  id: string;
  reference: string;
  title: string;
  version: string;
  owner: string | null;
  approval_date: string | null;
  next_review_date: string | null;
  status: 'draft' | 'issued' | 'superseded' | 'withdrawn';
  issued_at: string | null;
  withdrawn_at: string | null;
  withdrawn_reason: string | null;
  created_at: string;
  review_state: 'overdue' | 'due_soon' | 'ok' | 'none' | 'n/a';
  days_to_review: number | null;
  today: string;
  activities: DocActivity[];
}
export interface ActivityOption {
  id: string;
  ref: string;
  text: string;
}

const STATUS_TONE: Record<DocRow['status'], 'pass' | 'accent' | 'neutral' | 'fail'> = {
  issued: 'pass',
  draft: 'accent',
  superseded: 'neutral',
  withdrawn: 'fail',
};

function ReviewFlag({ d }: { d: DocRow }) {
  if (d.review_state === 'overdue')
    return <Badge tone="fail">overdue {Math.abs(d.days_to_review ?? 0)}d</Badge>;
  if (d.review_state === 'due_soon') return <Badge tone="warn">due in {d.days_to_review}d</Badge>;
  if (d.review_state === 'none') return <span className="muted">not set</span>;
  return null;
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

type Ctx = {
  clientOrgId: string;
  programmeId: string;
  activities: ActivityOption[];
  canWrite: boolean;
  canIssue: boolean;
};

export function DocumentRegister({
  clientOrgId,
  programmeId,
  docs,
  activities,
  canWrite,
  canIssue,
  showWithdrawn,
}: {
  clientOrgId: string;
  programmeId: string;
  docs: DocRow[];
  activities: ActivityOption[];
  canWrite: boolean;
  canIssue: boolean;
  showWithdrawn: boolean;
}) {
  const [open, setOpen] = React.useState<string | null>(null);
  const ctx: Ctx = { clientOrgId, programmeId, activities, canWrite, canIssue };

  // group versions by reference; the headline row is the issued version, else
  // the open draft, else the newest row (all history)
  const groups = React.useMemo(() => {
    const m = new Map<string, DocRow[]>();
    for (const d of docs) m.set(d.reference, [...(m.get(d.reference) ?? []), d]);
    return [...m.entries()]
      .map(([ref, rows]) => {
        const sorted = [...rows].sort((a, b) => b.created_at.localeCompare(a.created_at));
        const head =
          sorted.find((r) => r.status === 'issued') ?? sorted.find((r) => r.status === 'draft') ?? sorted[0];
        return { ref, rows: sorted, head, draft: sorted.find((r) => r.status === 'draft') ?? null };
      })
      .sort((a, b) => a.ref.localeCompare(b.ref));
  }, [docs]);

  return (
    <>
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap', marginBottom: 12 }}>
        {canWrite ? <RegisterDoc ctx={ctx} /> : null}
        <a
          href={`/programmes/${programmeId}/documents${showWithdrawn ? '' : '?withdrawn=1'}`}
          className="muted"
          style={{ fontSize: 'var(--fs-sm)', marginLeft: 'auto' }}
        >
          {showWithdrawn ? 'Hide withdrawn versions' : 'Show withdrawn versions'}
        </a>
      </div>

      <Card pad={0}>
        {groups.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th style={{ width: 28 }} />
                  <th>Reference</th>
                  <th>Title</th>
                  <th>Version</th>
                  <th>Owner</th>
                  <th>Approved</th>
                  <th>Next review</th>
                  <th>Status</th>
                  <th style={{ textAlign: 'right' }}>Activities</th>
                </tr>
              </thead>
              <tbody>
                {groups.map((g) => {
                  const d = g.head;
                  const isOpen = open === g.ref;
                  return (
                    <React.Fragment key={g.ref}>
                      <tr>
                        <td>
                          <button
                            type="button"
                            className="sp-thsort"
                            aria-expanded={isOpen}
                            aria-label={isOpen ? 'Collapse' : 'Expand'}
                            onClick={() => setOpen(isOpen ? null : g.ref)}
                          >
                            <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size={14} />
                          </button>
                        </td>
                        <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{g.ref}</td>
                        <td style={{ maxWidth: 360 }}>
                          <div style={{ fontWeight: 500 }}>{d.title}</div>
                          {g.draft && g.draft.id !== d.id ? (
                            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>draft v{g.draft.version} in progress</div>
                          ) : null}
                        </td>
                        <td className="mono">{d.version}</td>
                        <td className="muted">{d.owner ?? '—'}</td>
                        <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>{d.approval_date ?? '—'}</td>
                        <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>
                          {d.next_review_date ?? ''}
                          <div><ReviewFlag d={d} /></div>
                        </td>
                        <td><Badge tone={STATUS_TONE[d.status]}>{d.status}</Badge></td>
                        <td className="mono muted" style={{ textAlign: 'right' }}>{d.activities.length || '—'}</td>
                      </tr>
                      {isOpen ? (
                        <tr>
                          <td />
                          <td colSpan={8} style={{ background: 'var(--surface-card)' }}>
                            <DocDetail ctx={ctx} rows={g.rows} />
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
            icon="folder-open"
            message="No controlled documents yet. The framework template seeds the document set; register new ones above."
          />
        )}
      </Card>
    </>
  );
}

function RegisterDoc({ ctx, base }: { ctx: Ctx; base?: DocRow }) {
  const blank = {
    reference: base?.reference ?? '',
    title: base?.title ?? '',
    version: '',
    owner: base?.owner ?? '',
    next_review_date: '',
  };
  const [show, setShow] = React.useState(false);
  const [f, setF] = React.useState(blank);
  const { busy, msg, run } = useRpc();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setF((p) => ({ ...p, [k]: e.target.value }));

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    const ok = await run(
      'register_controlled_document',
      {
        p_client_org_id: ctx.clientOrgId,
        p_reference: f.reference.trim(),
        p_title: f.title.trim(),
        p_version: f.version.trim(),
        p_owner: f.owner.trim() || null,
        p_next_review_date: f.next_review_date || null,
      },
      base ? `Draft v${f.version.trim()} registered.` : 'Document registered as a draft.'
    );
    if (ok) {
      setF(blank);
      setShow(false);
    }
  }

  if (!show) {
    return (
      <div>
        <Button size="sm" icon="plus" variant={base ? 'outline' : 'primary'} onClick={() => setShow(true)}>
          {base ? 'New version' : 'Register document'}
        </Button>
        <Msg msg={msg} />
      </div>
    );
  }
  return (
    <Card style={{ marginBottom: 12, width: '100%' }}>
      <form onSubmit={submit} style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
        <Field label="Reference" required>
          <Input value={f.reference} onChange={set('reference')} required readOnly={!!base} />
        </Field>
        <Field label="Version" required hint={base ? `Current: v${base.version}` : undefined}>
          <Input value={f.version} onChange={set('version')} required />
        </Field>
        <Field label="Title" required>
          <Input value={f.title} onChange={set('title')} required />
        </Field>
        <Field label="Owner">
          <Input value={f.owner} onChange={set('owner')} />
        </Field>
        <Field label="Next review">
          <Input type="date" value={f.next_review_date} onChange={set('next_review_date')} />
        </Field>
        <div style={{ gridColumn: '1 / -1', display: 'flex', gap: 8, alignItems: 'center' }}>
          <Button size="sm" type="submit" disabled={busy || !f.reference.trim() || !f.title.trim() || !f.version.trim()}>
            {busy ? 'Saving…' : 'Register draft'}
          </Button>
          <Button size="sm" variant="ghost" type="button" onClick={() => setShow(false)}>Cancel</Button>
          <Msg msg={msg} />
        </div>
      </form>
    </Card>
  );
}

function DocDetail({ ctx, rows }: { ctx: Ctx; rows: DocRow[] }) {
  const issued = rows.find((r) => r.status === 'issued');
  const draft = rows.find((r) => r.status === 'draft');
  const live = [draft, issued].filter(Boolean) as DocRow[];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16, padding: '8px 0' }}>
      {live.map((d) => (
        <LiveVersion key={d.id} ctx={ctx} d={d} />
      ))}
      {ctx.canWrite && !draft && issued ? <RegisterDoc ctx={ctx} base={issued} /> : null}

      <div>
        <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginBottom: 6 }}>Version history</div>
        <table className="sp-table">
          <thead>
            <tr>
              <th>Version</th>
              <th>Title</th>
              <th>Owner</th>
              <th>Approved</th>
              <th>Issued</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td className="mono">{r.version}</td>
                <td>{r.title}</td>
                <td className="muted">{r.owner ?? '—'}</td>
                <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>{r.approval_date ?? '—'}</td>
                <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>{r.issued_at?.slice(0, 10) ?? '—'}</td>
                <td>
                  <Badge tone={STATUS_TONE[r.status]}>{r.status}</Badge>
                  {r.status === 'withdrawn' && r.withdrawn_reason ? (
                    <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{r.withdrawn_reason}</div>
                  ) : null}
                  {r.status !== 'draft' ? (
                    <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}><Icon name="lock" size={11} /> read-only</div>
                  ) : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function LiveVersion({ ctx, d }: { ctx: Ctx; d: DocRow }) {
  const { busy, msg, run } = useRpc();
  const isDraft = d.status === 'draft';
  const [edit, setEdit] = React.useState({ title: d.title, owner: d.owner ?? '', version: d.version, approval_date: d.approval_date ?? '' });
  const [review, setReview] = React.useState(d.next_review_date ?? '');
  const [link, setLink] = React.useState('');
  const [reason, setReason] = React.useState('');
  const linked = new Set(d.activities.map((a) => a.id));

  const changed = (k: keyof typeof edit, orig: string | null) =>
    edit[k] !== (orig ?? '') ? (edit[k] === '' && k === 'owner' ? '' : edit[k] || null) : null;

  return (
    <div style={{ border: '1px solid var(--border)', borderRadius: 8, padding: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <Badge tone={STATUS_TONE[d.status]}>{d.status}</Badge>
        <strong>v{d.version}</strong>
        {!isDraft ? (
          <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
            <Icon name="lock" size={11} /> content locked since issue (NFR-09) — corrections are a new version
          </span>
        ) : null}
      </div>

      {isDraft && ctx.canWrite ? (
        <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))' }}>
          <Input aria-label="Title" value={edit.title} onChange={(e) => setEdit({ ...edit, title: e.target.value })} />
          <Input aria-label="Owner" placeholder="Owner" value={edit.owner} onChange={(e) => setEdit({ ...edit, owner: e.target.value })} />
          <Input aria-label="Version" value={edit.version} onChange={(e) => setEdit({ ...edit, version: e.target.value })} />
          <Input aria-label="Approval date" type="date" value={edit.approval_date} onChange={(e) => setEdit({ ...edit, approval_date: e.target.value })} />
          <div>
            <Button size="sm" variant="outline" disabled={busy}
              onClick={() =>
                run('update_controlled_document', {
                  p_document_id: d.id,
                  p_title: changed('title', d.title),
                  p_owner: changed('owner', d.owner),
                  p_version: changed('version', d.version),
                  p_approval_date: changed('approval_date', d.approval_date),
                }, 'Draft saved.')
              }>
              Save draft
            </Button>
          </div>
        </div>
      ) : null}

      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Next review</span>
        {ctx.canWrite ? (
          <>
            <Input type="date" value={review} onChange={(e) => setReview(e.target.value)} style={{ width: 'auto' }} />
            <Button size="sm" variant="outline" disabled={busy || review === (d.next_review_date ?? '')}
              onClick={() => run('set_document_review_date', { p_document_id: d.id, p_next_review_date: review || null }, 'Review date set.')}>
              Set
            </Button>
          </>
        ) : (
          <span className="mono">{d.next_review_date ?? '—'}</span>
        )}
        <ReviewFlag d={d} />
      </div>

      <div>
        <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginBottom: 4 }}>Approving / reissuing activities</div>
        {d.activities.length ? (
          <ul style={{ margin: 0, paddingLeft: 18 }}>
            {d.activities.map((a) => (
              <li key={a.id} style={{ fontSize: 'var(--fs-sm)' }}>
                <span className="mono">{a.ref}</span> {a.text}
                {!a.active ? <Badge tone="neutral">retired</Badge> : null}
                {a.programme_id !== ctx.programmeId ? <span className="muted"> (other programme)</span> : null}
                {ctx.canWrite ? (
                  <button type="button" className="sp-thsort" aria-label={`Unlink ${a.ref}`} disabled={busy}
                    onClick={() => run('unlink_document_activity', { p_document_id: d.id, p_activity_id: a.id }, 'Unlinked.')}>
                    <Icon name="x" size={12} />
                  </button>
                ) : null}
              </li>
            ))}
          </ul>
        ) : (
          <span className="muted" style={{ fontSize: 'var(--fs-sm)' }}>None linked.</span>
        )}
        {ctx.canWrite ? (
          <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
            <Select value={link} onChange={(e) => setLink(e.target.value)} style={{ width: 'auto', maxWidth: 360 }} aria-label="Activity to link">
              <option value="">Link an activity…</option>
              {ctx.activities.filter((a) => !linked.has(a.id)).map((a) => (
                <option key={a.id} value={a.id}>{a.ref} — {a.text}</option>
              ))}
            </Select>
            <Button size="sm" variant="outline" disabled={busy || !link}
              onClick={async () => {
                if (await run('link_document_activity', { p_document_id: d.id, p_activity_id: link }, 'Linked.')) setLink('');
              }}>
              Link
            </Button>
          </div>
        ) : null}
      </div>

      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        {isDraft && ctx.canIssue ? (
          <Button size="sm" icon="stamp" disabled={busy}
            onClick={() => run('issue_controlled_document', { p_document_id: d.id, p_approval_date: d.approval_date }, `v${d.version} issued.`)}>
            Issue v{d.version}
          </Button>
        ) : null}
        {ctx.canWrite ? (
          <>
            <Input placeholder={isDraft ? 'Reason (optional)' : 'Withdrawal reason'} value={reason}
              onChange={(e) => setReason(e.target.value)} style={{ width: 'auto', minWidth: 200 }} />
            <Button size="sm" variant="ghost" disabled={busy}
              onClick={async () => {
                if (await run('withdraw_controlled_document', { p_document_id: d.id, p_reason: reason.trim() || null }, 'Withdrawn.')) setReason('');
              }}>
              Withdraw
            </Button>
          </>
        ) : null}
        <Msg msg={msg} />
      </div>
    </div>
  );
}
