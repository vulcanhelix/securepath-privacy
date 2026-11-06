'use client';
import * as React from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { StatusPill } from '@/components/ui/StatusPill';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Icon } from '@/components/ui/Icon';
import { Field, Input, Select, Textarea } from '@/components/ui/forms';

// W2-10 — the month's maintenance task instances grouped by window
// (FR-MNT-03), with per-row actions and the 12-month history (FR-MNT-10).
// Writes go ONLY through the W1-03 RPCs under the caller's JWT; on an RPC
// error the message is shown and nothing else is written. Due dates and
// windows are rendered exactly as the server stored them.

export interface TaskTemplate {
  id: string;
  code: string;
  task: string;
  owner_role: string;
  input_from_label: string | null;
  input_from_provider_id: string | null;
  evidence_produced: string | null;
  feeds: string | null;
  active: boolean;
  sort: number;
}

export interface ProviderLogEntry {
  type: 'request' | 'input' | string;
  at: string;
  note?: string | null;
  file_ref?: string | null;
  channel?: string | null;
  contact_email?: string | null;
  provider_id?: string | null;
  by?: string | null;
}

export interface TaskInstance {
  id: string;
  task_template_id: string;
  period: string;
  due_date: string | null;
  task_window: string | null;
  assignee: string | null;
  status: 'Pending' | 'In progress' | 'Complete' | 'Exception' | string;
  evidence_id: string | null;
  evidence_exempt_reason: string | null;
  exception_reason: string | null;
  exception_raid_item_id: string | null;
  completed_on: string | null;
  provider_id: string | null;
  provider_requested_at: string | null;
  awaiting_provider_input: boolean;
  provider_input_log: ProviderLogEntry[] | null;
}

export interface AcceptedEvidence {
  id: string;
  evidence_ref: string | null;
  link: string | null;
  file_key: string | null;
  uploaded_at: string;
}

export interface Provider {
  id: string;
  name: string;
  kind: string | null;
  contact_email: string | null;
  channel: string | null;
  active: boolean;
}

const WINDOWS: { key: string; label: string; hint: string }[] = [
  { key: 'before_month_end', label: 'Before month end', hint: 'due before the last business day' },
  { key: 'month_end_close', label: 'Month-end close', hint: 'last business day' },
  { key: 'report_window', label: 'Report window', hint: 'business days 1–5 of the following month' },
  { key: 'executive_meeting', label: 'Executive meeting', hint: 'presented with the issued report' },
];

const STATUS_TONES = { exception: 'fail', pending: 'neutral', 'in progress': 'accent', complete: 'pass' } as const;

// display-only formatting of server-stored dates (no date arithmetic)
const fmtDate = (d: string | null | undefined) =>
  d ? new Date(d.length === 10 ? `${d}T00:00:00Z` : d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: d.length === 10 ? 'UTC' : undefined }) : '—';
const evLabel = (e: { id: string; evidence_ref: string | null }) => e.evidence_ref ?? `Evidence ${e.id.slice(0, 8)}`;

export function MaintenanceBoard({
  templates,
  instances,
  accepted,
  evidenceRefs,
  providers,
  names,
  canAct,
  base,
}: {
  templates: TaskTemplate[];
  instances: TaskInstance[];
  accepted: AcceptedEvidence[];
  evidenceRefs: Record<string, string | null>;
  providers: Provider[];
  names: Record<string, string>;
  canAct: boolean;
  base: string;
}) {
  const [open, setOpen] = React.useState<string | null>(null);
  const tpl = React.useMemo(() => new Map(templates.map((t) => [t.id, t])), [templates]);
  const prov = React.useMemo(() => new Map(providers.map((p) => [p.id, p])), [providers]);

  const groups = React.useMemo(() => {
    const known = new Set(WINDOWS.map((w) => w.key));
    const out = WINDOWS.map((w) => ({ ...w, rows: instances.filter((i) => i.task_window === w.key) }));
    const other = instances.filter((i) => !i.task_window || !known.has(i.task_window));
    if (other.length) out.push({ key: 'other', label: 'Other', hint: 'no recognised window', rows: other });
    // keep the server ordering (due_date), tie-break on template sort/code
    for (const g of out)
      g.rows.sort(
        (a, b) =>
          (a.due_date ?? '').localeCompare(b.due_date ?? '') ||
          (tpl.get(a.task_template_id)?.sort ?? 0) - (tpl.get(b.task_template_id)?.sort ?? 0) ||
          (tpl.get(a.task_template_id)?.code ?? '').localeCompare(tpl.get(b.task_template_id)?.code ?? '')
      );
    return out.filter((g) => g.rows.length);
  }, [instances, tpl]);

  return (
    <div className="sp-table-scroll">
      <table className="sp-table">
        <thead>
          <tr>
            <th style={{ width: 28 }} />
            <th>Code</th>
            <th>Task</th>
            <th>Due</th>
            <th>Status</th>
            <th>Provider input</th>
            <th>Evidence</th>
            <th>Assignee</th>
          </tr>
        </thead>
        <tbody>
          {groups.map((g) => (
            <React.Fragment key={g.key}>
              <tr>
                <td colSpan={8} style={{ background: 'var(--surface-card)' }}>
                  <strong>{g.label}</strong>{' '}
                  <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                    · {g.hint} · {g.rows.length} task{g.rows.length === 1 ? '' : 's'}
                  </span>
                </td>
              </tr>
              {g.rows.map((i) => {
                const t = tpl.get(i.task_template_id);
                const isOpen = open === i.id;
                const p = i.provider_id ? prov.get(i.provider_id) : undefined;
                return (
                  <React.Fragment key={i.id}>
                    <tr>
                      <td>
                        <button
                          type="button"
                          className="sp-thsort"
                          aria-expanded={isOpen}
                          aria-label={isOpen ? 'Collapse task' : 'Expand task'}
                          onClick={() => setOpen(isOpen ? null : i.id)}
                        >
                          <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size={14} />
                        </button>
                      </td>
                      <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{t?.code ?? '—'}</td>
                      <td style={{ fontWeight: 500 }}>
                        {t?.task ?? '—'}
                        {t?.feeds && /report/i.test(t.feeds) ? (
                          <div style={{ marginTop: 4 }}><Badge tone="ink">feeds report</Badge></div>
                        ) : null}
                      </td>
                      <td className="mono">{fmtDate(i.due_date)}</td>
                      <td><StatusPill status={i.status} map={STATUS_TONES} /></td>
                      <td>
                        {i.awaiting_provider_input ? (
                          <Badge tone="warn" dot>Awaiting {p?.name ?? 'provider'}</Badge>
                        ) : (i.provider_input_log ?? []).some((e) => e.type === 'input') ? (
                          <Badge tone="pass" dot>Received</Badge>
                        ) : t?.input_from_label || t?.input_from_provider_id ? (
                          <span className="muted">{t?.input_from_label ?? 'Provider'} · not requested</span>
                        ) : (
                          <span className="muted">—</span>
                        )}
                      </td>
                      <td>
                        {i.evidence_id ? (
                          <Link href={`${base}/evidence/${i.evidence_id}`} style={{ whiteSpace: 'nowrap' }}>
                            {evidenceRefs[i.evidence_id] ?? 'Evidence'} →
                          </Link>
                        ) : i.evidence_exempt_reason ? (
                          <Badge tone="neutral">exempt</Badge>
                        ) : (
                          <span className="muted">—</span>
                        )}
                      </td>
                      <td className="muted">{i.assignee ? names[i.assignee] ?? '—' : t?.owner_role ?? '—'}</td>
                    </tr>
                    {isOpen ? (
                      <tr>
                        <td />
                        <td colSpan={7} style={{ background: 'var(--surface-card)' }}>
                          <TaskDetail
                            inst={i}
                            tpl={t}
                            accepted={accepted}
                            evidenceRefs={evidenceRefs}
                            providers={providers}
                            canAct={canAct}
                            base={base}
                          />
                        </td>
                      </tr>
                    ) : null}
                  </React.Fragment>
                );
              })}
            </React.Fragment>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function TaskDetail({
  inst,
  tpl,
  accepted,
  evidenceRefs,
  providers,
  canAct,
  base,
}: {
  inst: TaskInstance;
  tpl: TaskTemplate | undefined;
  accepted: AcceptedEvidence[];
  evidenceRefs: Record<string, string | null>;
  providers: Provider[];
  canAct: boolean;
  base: string;
}) {
  const router = useRouter();
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});
  const [exceptionReason, setExceptionReason] = React.useState('');
  const [completeMode, setCompleteMode] = React.useState<'evidence' | 'exempt'>(accepted.length ? 'evidence' : 'exempt');
  const [evidenceId, setEvidenceId] = React.useState('');
  const [exemptReason, setExemptReason] = React.useState('');
  const [providerId, setProviderId] = React.useState(tpl?.input_from_provider_id ?? '');
  const [inputNote, setInputNote] = React.useState('');
  const [inputFile, setInputFile] = React.useState('');

  const done = inst.status === 'Complete';
  const log = inst.provider_input_log ?? [];
  const provName = (id?: string | null) => providers.find((p) => p.id === id)?.name;

  async function call(fn: string, args: Record<string, unknown>, ok: string, reset?: () => void) {
    setBusy(true);
    setMsg({});
    const { error } = await browserClient().rpc(fn, args);
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    reset?.();
    setMsg({ ok });
    router.refresh();
  }

  const start = () =>
    call('update_maintenance_task_status', { p_instance: inst.id, p_status: 'In progress' }, 'Marked in progress.');

  function flagException(e: React.FormEvent) {
    e.preventDefault();
    if (!exceptionReason.trim()) return setMsg({ err: 'An exception needs a reason — it raises the RAID issue (FR-MNT-06).' });
    call(
      'update_maintenance_task_status',
      { p_instance: inst.id, p_status: 'Exception', p_exception_reason: exceptionReason.trim() },
      'Exception recorded — a RAID issue is raised for the weekly agenda.',
      () => setExceptionReason('')
    );
  }

  function complete(e: React.FormEvent) {
    e.preventDefault();
    if (completeMode === 'evidence') {
      if (!evidenceId) return setMsg({ err: 'Pick an accepted evidence item, or record why none applies.' });
      call('complete_maintenance_task', { p_instance: inst.id, p_evidence_id: evidenceId, p_exemption_reason: null }, 'Task completed with evidence.');
    } else {
      if (!exemptReason.trim()) return setMsg({ err: 'Record the reason no evidence applies (FR-MNT-05).' });
      call(
        'complete_maintenance_task',
        { p_instance: inst.id, p_evidence_id: null, p_exemption_reason: exemptReason.trim() },
        'Task completed — exemption reason recorded.'
      );
    }
  }

  const requestInput = () =>
    call(
      'request_provider_input',
      { p_instance: inst.id, p_provider: providerId || null },
      inst.awaiting_provider_input ? 'Reminder sent to the provider.' : 'Input requested from the provider.'
    );

  function receiveInput(e: React.FormEvent) {
    e.preventDefault();
    if (!inputNote.trim() && !inputFile.trim()) return setMsg({ err: 'A provider input needs a note or a file reference.' });
    call(
      'receive_provider_input',
      { p_instance: inst.id, p_note: inputNote.trim() || null, p_file_ref: inputFile.trim() || null },
      'Provider input recorded.',
      () => {
        setInputNote('');
        setInputFile('');
      }
    );
  }

  const activeProviders = providers.filter((p) => p.active);

  return (
    <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', padding: '8px 0' }}>
      {/* ---- read-only facts ---- */}
      <div style={{ flex: '1 1 260px', minWidth: 0, display: 'flex', flexDirection: 'column', gap: 6, fontSize: 'var(--fs-sm)' }}>
        <div><span className="muted">Evidence produced:</span> {tpl?.evidence_produced ?? '—'}</div>
        <div><span className="muted">Feeds:</span> {tpl?.feeds ?? '—'}</div>
        <div><span className="muted">Input from:</span> {tpl?.input_from_label ?? '—'}</div>
        {inst.completed_on ? <div><span className="muted">Completed:</span> {fmtDate(inst.completed_on)}</div> : null}
        {inst.evidence_exempt_reason ? (
          <div><span className="muted">No evidence because:</span> {inst.evidence_exempt_reason}</div>
        ) : null}
        {inst.exception_reason ? (
          <div>
            <span className="muted">Exception:</span> {inst.exception_reason}
            {inst.exception_raid_item_id ? (
              <> · <Link href={`${base}/raid`}>RAID issue →</Link></>
            ) : null}
          </div>
        ) : null}

        <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 8 }}>Provider log (read-only)</div>
        {log.length ? (
          <ul style={{ margin: 0, paddingLeft: 18 }}>
            {log.map((e, idx) => (
              <li key={idx}>
                <span className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{fmtDate(e.at)}</span>{' '}
                {e.type === 'request'
                  ? `requested from ${provName(e.provider_id) ?? 'provider'}${e.channel ? ` via ${e.channel}` : ''}${e.contact_email ? ` (${e.contact_email})` : ''}`
                  : `input received${e.note ? `: ${e.note}` : ''}${e.file_ref ? ` · file ${e.file_ref}` : ''}`}
              </li>
            ))}
          </ul>
        ) : (
          <div className="muted">No provider requests.</div>
        )}

        <TaskHistory templateId={inst.task_template_id} evidenceRefs={evidenceRefs} base={base} />
      </div>

      {/* ---- actions (RPC-only) ---- */}
      {canAct && !done ? (
        <div style={{ flex: '1 1 300px', display: 'flex', flexDirection: 'column', gap: 14 }}>
          {inst.status === 'Pending' || inst.status === 'Exception' ? (
            <div>
              <Button size="sm" variant="outline" icon="play" disabled={busy} onClick={start}>
                {inst.status === 'Exception' ? 'Resume (in progress)' : 'Start'}
              </Button>
            </div>
          ) : null}

          <form onSubmit={complete} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Complete (FR-MNT-05)</div>
            <Select value={completeMode} onChange={(e) => setCompleteMode(e.target.value as 'evidence' | 'exempt')}>
              <option value="evidence">Attach accepted evidence</option>
              <option value="exempt">No evidence applies — record why</option>
            </Select>
            {completeMode === 'evidence' ? (
              accepted.length ? (
                <Select value={evidenceId} onChange={(e) => setEvidenceId(e.target.value)} required>
                  <option value="">Choose accepted evidence…</option>
                  {accepted.map((ev) => (
                    <option key={ev.id} value={ev.id}>
                      {evLabel(ev)} · {fmtDate(ev.uploaded_at)}
                    </option>
                  ))}
                </Select>
              ) : (
                <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
                  No accepted evidence on this programme yet — <Link href={`${base}/evidence`}>submit evidence</Link>{' '}
                  for review, or record why none applies.
                </div>
              )
            ) : (
              <Textarea
                placeholder="Reason no evidence applies (kept in the audit trail)"
                value={exemptReason}
                onChange={(e) => setExemptReason(e.target.value)}
                style={{ minHeight: 60 }}
                required
              />
            )}
            <div>
              <Button size="sm" type="submit" icon="check" disabled={busy || (completeMode === 'evidence' && !accepted.length)}>
                Complete task
              </Button>
            </div>
          </form>

          {inst.status !== 'Exception' ? (
            <form onSubmit={flagException} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Flag exception (raises a RAID issue)</div>
              <Input placeholder="Exception reason" value={exceptionReason} onChange={(e) => setExceptionReason(e.target.value)} required />
              <div>
                <Button size="sm" variant="danger" type="submit" icon="alert-triangle" disabled={busy}>
                  Flag exception
                </Button>
              </div>
            </form>
          ) : null}

          {inst.status !== 'Exception' ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Provider input (FR-MNT-04)</div>
              <Field label="Provider" hint="Defaults to the task's named provider. Re-requesting sends a reminder.">
                <Select value={providerId} onChange={(e) => setProviderId(e.target.value)}>
                  <option value="">Task&apos;s named provider</option>
                  {activeProviders.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                      {p.kind ? ` · ${p.kind}` : ''}
                    </option>
                  ))}
                </Select>
              </Field>
              <div>
                <Button size="sm" variant="outline" icon="send" disabled={busy} onClick={requestInput}>
                  {inst.awaiting_provider_input ? 'Send reminder' : 'Request input'}
                </Button>
              </div>
            </div>
          ) : null}

          {inst.awaiting_provider_input ? (
            <form onSubmit={receiveInput} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Record provider response</div>
              <Textarea
                placeholder="What the provider sent"
                value={inputNote}
                onChange={(e) => setInputNote(e.target.value)}
                style={{ minHeight: 60 }}
              />
              <Input placeholder="File reference (optional)" value={inputFile} onChange={(e) => setInputFile(e.target.value)} />
              <div>
                <Button size="sm" variant="outline" type="submit" icon="inbox" disabled={busy}>
                  Record input
                </Button>
              </div>
            </form>
          ) : null}

          {msg.err ? <p className="sp-breach-msg is-err">{msg.err}</p> : null}
          {msg.ok ? <p className="sp-breach-msg is-ok">{msg.ok}</p> : null}
        </div>
      ) : done ? (
        <div className="muted" style={{ flex: '1 1 240px', fontSize: 'var(--fs-sm)' }}>
          Complete — this record is immutable.
        </div>
      ) : null}
    </div>
  );
}

// FR-MNT-10 — 12-month completion history per task (read-only RPC)
function TaskHistory({
  templateId,
  evidenceRefs,
  base,
}: {
  templateId: string;
  evidenceRefs: Record<string, string | null>;
  base: string;
}) {
  const [rows, setRows] = React.useState<TaskInstance[] | null>(null);
  const [err, setErr] = React.useState<string | null>(null);

  React.useEffect(() => {
    let live = true;
    browserClient()
      .rpc('maintenance_task_history', { p_template: templateId, p_months: 12 })
      .then(({ data, error }) => {
        if (!live) return;
        if (error) setErr(error.message);
        else setRows((data ?? []) as TaskInstance[]);
      });
    return () => {
      live = false;
    };
  }, [templateId]);

  return (
    <div style={{ marginTop: 8 }}>
      <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginBottom: 6 }}>12-month history (read-only)</div>
      {err ? (
        <p className="sp-breach-msg is-err">{`Could not load history: ${err}`}</p>
      ) : rows == null ? (
        <div className="muted">Loading…</div>
      ) : rows.length ? (
        <table className="sp-table">
          <thead>
            <tr>
              <th>Period</th>
              <th>Due</th>
              <th>Status</th>
              <th>Completed</th>
              <th>Evidence</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((h) => (
              <tr key={h.id}>
                <td className="mono">{h.period}</td>
                <td className="mono">{fmtDate(h.due_date)}</td>
                <td><StatusPill status={h.status} map={STATUS_TONES} /></td>
                <td className="muted">{fmtDate(h.completed_on)}</td>
                <td>
                  {h.evidence_id ? (
                    <Link href={`${base}/evidence/${h.evidence_id}`}>{evidenceRefs[h.evidence_id] ?? 'Evidence'} →</Link>
                  ) : h.evidence_exempt_reason ? (
                    <span className="muted" title={h.evidence_exempt_reason}>exempt</span>
                  ) : (
                    <span className="muted">—</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <div className="muted">No history yet.</div>
      )}
    </div>
  );
}
