'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { Checkbox, Field, Input } from '@/components/ui/forms';

// W2-12 — per-person training records. Writes are W2-12 RPCs under the
// caller's JWT: record_training / void_training_record (WRITE roles). A record
// is never edited — a wrong one is voided with a reason and re-recorded
// (the DB guard trigger refuses any other UPDATE).

export interface TrainingRow {
  id: string;
  person: string;
  site: string | null;
  functional_group: string | null;
  session: string;
  date: string | null;
  attendance: boolean;
  created_at: string;
  voided_at: string | null;
  void_reason: string | null;
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

export function TrainingRecords({
  clientOrgId,
  programmeId,
  records,
  canWrite,
  showVoided,
}: {
  clientOrgId: string;
  programmeId: string;
  records: TrainingRow[];
  canWrite: boolean;
  showVoided: boolean;
}) {
  const [q, setQ] = React.useState('');
  const shown = q.trim()
    ? records.filter((r) =>
        [r.person, r.session, r.site, r.functional_group].some((v) => v?.toLowerCase().includes(q.trim().toLowerCase()))
      )
    : records;

  return (
    <>
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap', marginBottom: 12 }}>
        {canWrite ? <RecordTraining clientOrgId={clientOrgId} /> : null}
        <Input placeholder="Filter by person, course, site…" value={q} onChange={(e) => setQ(e.target.value)}
          style={{ width: 'auto', minWidth: 240 }} aria-label="Filter records" />
        <a
          href={`/programmes/${programmeId}/training${showVoided ? '' : '?voided=1'}`}
          className="muted"
          style={{ fontSize: 'var(--fs-sm)', marginLeft: 'auto' }}
        >
          {showVoided ? 'Hide voided records' : 'Show voided records'}
        </a>
      </div>
      <Card pad={0}>
        {shown.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Person</th>
                  <th>Course / session</th>
                  <th>Date</th>
                  <th>Site</th>
                  <th>Functional group</th>
                  <th>Attendance</th>
                  {canWrite ? <th /> : null}
                </tr>
              </thead>
              <tbody>
                {shown.map((r) => (
                  <Row key={r.id} r={r} canWrite={canWrite} />
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState icon="graduation-cap" message={q ? 'No records match this filter.' : 'No training recorded yet.'} />
        )}
      </Card>
    </>
  );
}

function Row({ r, canWrite }: { r: TrainingRow; canWrite: boolean }) {
  const { busy, msg, run } = useRpc();
  const [voiding, setVoiding] = React.useState(false);
  const [reason, setReason] = React.useState('');
  const voided = !!r.voided_at;
  return (
    <tr style={voided ? { opacity: 0.6 } : undefined}>
      <td style={{ fontWeight: 500 }}>{r.person}</td>
      <td>{r.session}</td>
      <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{r.date ?? '—'}</td>
      <td className="muted">{r.site ?? '—'}</td>
      <td className="muted">{r.functional_group ?? '—'}</td>
      <td>
        {voided ? (
          <>
            <Badge tone="neutral">voided</Badge>
            {r.void_reason ? <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{r.void_reason}</div> : null}
          </>
        ) : r.attendance ? (
          <Badge tone="pass">attended</Badge>
        ) : (
          <Badge tone="warn">absent</Badge>
        )}
      </td>
      {canWrite ? (
        <td style={{ whiteSpace: 'nowrap' }}>
          {!voided && !voiding ? (
            <Button size="sm" variant="ghost" onClick={() => setVoiding(true)}>Void</Button>
          ) : null}
          {voiding ? (
            <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
              <Input placeholder="Reason" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: 160 }} />
              <Button size="sm" variant="outline" disabled={busy || !reason.trim()}
                onClick={async () => {
                  if (await run('void_training_record', { p_record_id: r.id, p_reason: reason.trim() }, 'Voided.')) setVoiding(false);
                }}>
                Confirm
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setVoiding(false)}>Cancel</Button>
            </div>
          ) : null}
          <Msg msg={msg} />
        </td>
      ) : null}
    </tr>
  );
}

function RecordTraining({ clientOrgId }: { clientOrgId: string }) {
  const today = new Date().toISOString().slice(0, 10);
  const blank = { person: '', session: '', date: today, site: '', functional_group: '', attendance: true };
  const [show, setShow] = React.useState(false);
  const [f, setF] = React.useState(blank);
  const { busy, msg, run } = useRpc();
  const set = (k: 'person' | 'session' | 'date' | 'site' | 'functional_group') =>
    (e: React.ChangeEvent<HTMLInputElement>) => setF((p) => ({ ...p, [k]: e.target.value }));

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    const ok = await run(
      'record_training',
      {
        p_client_org_id: clientOrgId,
        p_person: f.person.trim(),
        p_session: f.session.trim(),
        p_date: f.date,
        p_attendance: f.attendance,
        p_site: f.site.trim() || null,
        p_functional_group: f.functional_group.trim() || null,
      },
      'Training recorded.'
    );
    // keep course/date/site for quick entry of the next attendee
    if (ok) setF((p) => ({ ...p, person: '' }));
  }

  if (!show) {
    return (
      <div>
        <Button size="sm" icon="plus" onClick={() => setShow(true)}>Record training</Button>
        <Msg msg={msg} />
      </div>
    );
  }
  return (
    <Card style={{ marginBottom: 12, width: '100%' }}>
      <form onSubmit={submit} style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
        <Field label="Person" required>
          <Input value={f.person} onChange={set('person')} required />
        </Field>
        <Field label="Course / session" required>
          <Input value={f.session} onChange={set('session')} required />
        </Field>
        <Field label="Date" required>
          <Input type="date" value={f.date} max={today} onChange={set('date')} required />
        </Field>
        <Field label="Site">
          <Input value={f.site} onChange={set('site')} />
        </Field>
        <Field label="Functional group">
          <Input value={f.functional_group} onChange={set('functional_group')} />
        </Field>
        <div style={{ display: 'flex', alignItems: 'end' }}>
          <Checkbox label="Attended" checked={f.attendance} onChange={(e) => setF((p) => ({ ...p, attendance: e.target.checked }))} />
        </div>
        <div style={{ gridColumn: '1 / -1', display: 'flex', gap: 8, alignItems: 'center' }}>
          <Button size="sm" type="submit" disabled={busy || !f.person.trim() || !f.session.trim() || !f.date}>
            {busy ? 'Saving…' : 'Record'}
          </Button>
          <Button size="sm" variant="ghost" type="button" onClick={() => setShow(false)}>Close</Button>
          <Msg msg={msg} />
        </div>
      </form>
    </Card>
  );
}
