'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { Checkbox, Field, Input, Select } from '@/components/ui/forms';

// W2-12 — designations. Writes are W2-12 RPCs under the caller's JWT:
//   appoint_designation, end_designation, set_designation_evidence
// Evidence upload: the file goes through POST /api/documents (stores the
// object + record_document → an immutable documents row, classify=false so it
// never lands in the gap map), then set_designation_evidence links it. Ended
// rows are history: rendered read-only, never edited or deleted.

export interface DesignationRow {
  id: string;
  role: string;
  person: string;
  person_name: string | null;
  person_email: string | null;
  date_designated: string;
  end_date: string | null;
  is_current: boolean;
  registration_ref: string | null;
  evidence_document_id: string | null;
  evidence_filename: string | null;
  appointed_by_name: string | null;
  ended_by_name: string | null;
  end_reason: string | null;
  created_at: string;
}
export interface Candidate {
  id: string;
  name: string;
  email: string;
}

const LABEL: Record<string, string> = {
  information_officer: 'Information Officer',
  deputy_information_officer: 'Deputy Information Officer',
  dpo: 'Data Protection Officer',
  named_alternate: 'Named alternate',
};

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
  return { busy, setBusy, msg, setMsg, run };
}

function Msg({ msg }: { msg: { ok?: string; err?: string } }) {
  if (msg.err) return <p className="sp-breach-msg is-err">{msg.err}</p>;
  if (msg.ok) return <p className="sp-breach-msg is-ok">{msg.ok}</p>;
  return null;
}

/** upload one file as an immutable client document; returns its id */
async function uploadEvidence(clientOrgId: string, file: File): Promise<string> {
  const fd = new FormData();
  fd.append('file', file);
  fd.append('client_org_id', clientOrgId);
  fd.append('classify', 'false');
  const res = await fetch('/api/documents', { method: 'POST', body: fd });
  const body = (await res.json().catch(() => ({}))) as { id?: string; error?: string };
  if (!res.ok || !body.id) throw new Error(body.error ?? `Upload failed (${res.status})`);
  return body.id;
}

export function Designations({
  clientOrgId,
  rows,
  roles,
  candidates,
  canAppoint,
}: {
  clientOrgId: string;
  rows: DesignationRow[];
  roles: string[];
  candidates: Record<string, Candidate[]>;
  canAppoint: boolean;
}) {
  return (
    <>
      <div style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', marginBottom: 24 }}>
        {roles.map((role) => {
          const current = rows.filter((r) => r.role === role && r.is_current);
          return (
            <Card key={role} title={LABEL[role] ?? role} pad={16}>
              {current.length ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                  {current.map((d) => (
                    <Holder key={d.id} d={d} clientOrgId={clientOrgId} canAppoint={canAppoint} />
                  ))}
                </div>
              ) : (
                <p className="muted" style={{ margin: 0 }}>No current holder.</p>
              )}
              {canAppoint ? (
                <Appoint
                  clientOrgId={clientOrgId}
                  role={role}
                  candidates={candidates[role] ?? []}
                  needsSuccession={role === 'information_officer' && current.length > 0}
                />
              ) : null}
            </Card>
          );
        })}
      </div>

      <h2 style={{ fontSize: 'var(--fs-md, 1rem)', margin: '0 0 10px' }}>History</h2>
      <Card pad={0}>
        {rows.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Designation</th>
                  <th>Holder</th>
                  <th>Designated</th>
                  <th>Ended</th>
                  <th>Evidence</th>
                  <th>Registration ref</th>
                  <th>Appointed by</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((d) => (
                  <tr key={d.id}>
                    <td>{LABEL[d.role] ?? d.role}</td>
                    <td style={{ fontWeight: 500 }}>{d.person_name ?? d.person.slice(0, 8)}</td>
                    <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{d.date_designated}</td>
                    <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>
                      {d.end_date ?? '—'}
                      {d.end_reason ? <div className="muted">{d.end_reason}{d.ended_by_name ? ` · ${d.ended_by_name}` : ''}</div> : null}
                    </td>
                    <td><EvidenceLink d={d} /></td>
                    <td className="mono muted" style={{ fontSize: 'var(--fs-xs)' }}>{d.registration_ref ?? '—'}</td>
                    <td className="muted">{d.appointed_by_name ?? '—'}</td>
                    <td>{d.is_current ? <Badge tone="pass">current</Badge> : <Badge tone="neutral">ended</Badge>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState icon="id-card" message="No designations recorded for this client yet." />
        )}
      </Card>
    </>
  );
}

function EvidenceLink({ d }: { d: DesignationRow }) {
  if (!d.evidence_document_id) return <Badge tone="warn">missing</Badge>;
  return (
    <a href={`/api/documents/${d.evidence_document_id}`} target="_blank" rel="noreferrer" style={{ fontSize: 'var(--fs-sm)' }}>
      {d.evidence_filename ?? 'evidence'}
    </a>
  );
}

function Holder({ d, clientOrgId, canAppoint }: { d: DesignationRow; clientOrgId: string; canAppoint: boolean }) {
  const { busy, setBusy, msg, setMsg, run } = useRpc();
  const [ending, setEnding] = React.useState(false);
  const [reason, setReason] = React.useState('');
  const [ref, setRef] = React.useState('');
  const fileRef = React.useRef<HTMLInputElement>(null);

  async function attach() {
    const file = fileRef.current?.files?.[0];
    if (!file && !ref.trim()) return;
    setBusy(true);
    setMsg({});
    let docId: string | null = null;
    if (file) {
      try {
        docId = await uploadEvidence(clientOrgId, file);
      } catch (e) {
        setBusy(false);
        setMsg({ err: (e as Error).message });
        return;
      }
    }
    setBusy(false);
    if (await run('set_designation_evidence', {
      p_designation_id: d.id,
      p_evidence_document_id: docId,
      p_registration_ref: ref.trim() || null,
    }, 'Evidence recorded.')) {
      setRef('');
      if (fileRef.current) fileRef.current.value = '';
    }
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <div>
        <strong>{d.person_name ?? d.person.slice(0, 8)}</strong>
        {d.person_email ? <span className="muted"> · {d.person_email}</span> : null}
      </div>
      <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
        Since <span className="mono">{d.date_designated}</span>
        {d.appointed_by_name ? ` · appointed by ${d.appointed_by_name}` : ''}
        {d.registration_ref ? <> · ref <span className="mono">{d.registration_ref}</span></> : null}
      </div>
      <div style={{ fontSize: 'var(--fs-sm)' }}>Evidence: <EvidenceLink d={d} /></div>

      {canAppoint && (!d.evidence_document_id || !d.registration_ref) ? (
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
          {!d.evidence_document_id ? (
            <input ref={fileRef} type="file" accept=".pdf,.png,.jpg,.jpeg,.docx" aria-label="Appointment evidence" style={{ fontSize: 'var(--fs-xs)' }} />
          ) : null}
          {!d.registration_ref ? (
            <Input placeholder="Registration ref" value={ref} onChange={(e) => setRef(e.target.value)} style={{ width: 150 }} />
          ) : null}
          <Button size="sm" variant="outline" icon="upload" disabled={busy} onClick={attach}>Record</Button>
        </div>
      ) : null}

      {canAppoint ? (
        ending ? (
          <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
            <Input placeholder="Reason for ending" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: 200 }} />
            <Button size="sm" variant="outline" disabled={busy || !reason.trim()}
              onClick={async () => {
                if (await run('end_designation', { p_designation_id: d.id, p_reason: reason.trim() }, 'Designation ended.')) setEnding(false);
              }}>
              End today
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setEnding(false)}>Cancel</Button>
          </div>
        ) : (
          <div><Button size="sm" variant="ghost" onClick={() => setEnding(true)}>End designation</Button></div>
        )
      ) : null}
      <Msg msg={msg} />
    </div>
  );
}

function Appoint({
  clientOrgId,
  role,
  candidates,
  needsSuccession,
}: {
  clientOrgId: string;
  role: string;
  candidates: Candidate[];
  needsSuccession: boolean;
}) {
  const today = new Date().toISOString().slice(0, 10);
  const [show, setShow] = React.useState(false);
  const [f, setF] = React.useState({ person: '', date: today, ref: '', succession: false });
  const fileRef = React.useRef<HTMLInputElement>(null);
  const { busy, setBusy, msg, setMsg, run } = useRpc();

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setMsg({});
    let docId: string | null = null;
    const file = fileRef.current?.files?.[0];
    if (file) {
      setBusy(true);
      try {
        docId = await uploadEvidence(clientOrgId, file);
      } catch (err) {
        setBusy(false);
        setMsg({ err: (err as Error).message });
        return;
      }
      setBusy(false);
    }
    const ok = await run('appoint_designation', {
      p_client_org_id: clientOrgId,
      p_role: role,
      p_person: f.person,
      p_date_designated: f.date || null,
      p_registration_ref: f.ref.trim() || null,
      p_evidence_document_id: docId,
      p_supersede_current: f.succession,
    }, `${LABEL[role] ?? role} appointed.`);
    if (ok) {
      setF({ person: '', date: today, ref: '', succession: false });
      setShow(false);
    }
  }

  if (!show) {
    return (
      <div style={{ marginTop: 12 }}>
        <Button size="sm" variant="outline" icon="user-plus" onClick={() => setShow(true)}>
          {needsSuccession ? 'Appoint successor' : 'Appoint'}
        </Button>
        <Msg msg={msg} />
      </div>
    );
  }
  return (
    <form onSubmit={submit} style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 8 }}>
      <Field label="Person" required hint={candidates.length ? 'Eligible people for this client (jurisdiction pack rule)' : 'Nobody eligible — the designee needs a client role on this client'}>
        <Select value={f.person} onChange={(e) => setF({ ...f, person: e.target.value })} required>
          <option value="">Choose…</option>
          {candidates.map((c) => (
            <option key={c.id} value={c.id}>{c.name} ({c.email})</option>
          ))}
        </Select>
      </Field>
      <Field label="Date designated" required>
        <Input type="date" value={f.date} max={today} onChange={(e) => setF({ ...f, date: e.target.value })} required />
      </Field>
      <Field label="Registration ref">
        <Input value={f.ref} onChange={(e) => setF({ ...f, ref: e.target.value })} />
      </Field>
      <Field label="Evidence of appointment" hint="PDF, image or Word document; stored as immutable evidence">
        <input ref={fileRef} type="file" accept=".pdf,.png,.jpg,.jpeg,.docx" style={{ fontSize: 'var(--fs-xs)' }} />
      </Field>
      {needsSuccession ? (
        <Checkbox
          label="Replace the current Information Officer (their designation ends today)"
          checked={f.succession}
          onChange={(e) => setF({ ...f, succession: e.target.checked })}
        />
      ) : null}
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <Button size="sm" type="submit" disabled={busy || !f.person || (needsSuccession && !f.succession)}>
          {busy ? 'Saving…' : 'Appoint'}
        </Button>
        <Button size="sm" variant="ghost" type="button" onClick={() => setShow(false)}>Cancel</Button>
      </div>
      <Msg msg={msg} />
    </form>
  );
}
