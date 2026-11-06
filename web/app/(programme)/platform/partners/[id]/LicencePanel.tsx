'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Checkbox, Field, Input, Select } from '@/components/ui/forms';
import { StatusPill } from '@/components/ui/StatusPill';
import { dateLabel, type LicenceRow } from '@/lib/platform';

// W2-14 — licence issue / change / suspend / close (FR-PLT-02), wired to the
// W1-07 RPCs issue_licence, change_licence, suspend_licence, close_licence.
// The RPCs enforce platform_admin, the one-active-licence rule and the
// draft→active→suspended↔active→terminated machine; errors are shown as-is.
// Empty limit = uncapped (jsonb null).

interface Draft {
  plan: string;
  client_limit: string;
  programme_limit: string;
  starts_on: string;
  ends_on: string;
  status: 'draft' | 'active';
  attribution_display: boolean;
}

const today = () => new Date().toISOString().slice(0, 10);
const EMPTY: Draft = {
  plan: '',
  client_limit: '',
  programme_limit: '',
  starts_on: today(),
  ends_on: '',
  status: 'active',
  attribution_display: true,
};
const num = (s: string) => (s.trim() === '' ? null : Number(s));

function LicenceFields({ d, set, issuing }: { d: Draft; set: (p: Partial<Draft>) => void; issuing: boolean }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: '0 12px' }}>
      <Field label="Plan" required>
        <Input value={d.plan} onChange={(e) => set({ plan: e.target.value })} required />
      </Field>
      <Field label="Client limit" hint="empty = uncapped">
        <Input type="number" min={0} value={d.client_limit} onChange={(e) => set({ client_limit: e.target.value })} />
      </Field>
      <Field label="Programme limit" hint="empty = uncapped">
        <Input type="number" min={0} value={d.programme_limit} onChange={(e) => set({ programme_limit: e.target.value })} />
      </Field>
      <Field label="Starts on" required>
        <Input type="date" value={d.starts_on} onChange={(e) => set({ starts_on: e.target.value })} required />
      </Field>
      <Field label="Ends on" hint="empty = open-ended">
        <Input type="date" value={d.ends_on} onChange={(e) => set({ ends_on: e.target.value })} />
      </Field>
      {issuing ? (
        <Field label="Issue as">
          <Select value={d.status} onChange={(e) => set({ status: e.target.value as Draft['status'] })}>
            <option value="active">Active</option>
            <option value="draft">Draft</option>
          </Select>
        </Field>
      ) : null}
      <Field label="Attribution">
        <Checkbox
          label="Show SecurePath attribution (FR-BRN-05)"
          checked={d.attribution_display}
          onChange={(e) => set({ attribution_display: e.target.checked })}
        />
      </Field>
    </div>
  );
}

export function LicencePanel({ partnerId, licences }: { partnerId: string; licences: LicenceRow[] }) {
  const router = useRouter();
  const [mode, setMode] = React.useState<{ kind: 'issue' } | { kind: 'edit'; id: string } | null>(null);
  const [d, setD] = React.useState<Draft>(EMPTY);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});
  const set = (p: Partial<Draft>) => setD((o) => ({ ...o, ...p }));

  async function run(label: string, call: () => PromiseLike<{ error: { message: string } | null }>) {
    setBusy(true);
    setMsg({});
    const { error } = await call();
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    setMsg({ ok: label });
    setMode(null);
    router.refresh();
  }

  const sb = () => browserClient();

  function openEdit(l: LicenceRow) {
    setD({
      plan: l.plan,
      client_limit: l.client_limit == null ? '' : String(l.client_limit),
      programme_limit: l.programme_limit == null ? '' : String(l.programme_limit),
      starts_on: l.starts_on,
      ends_on: l.ends_on ?? '',
      status: 'active',
      attribution_display: l.attribution_display,
    });
    setMsg({});
    setMode({ kind: 'edit', id: l.id });
  }

  function submit(e: React.FormEvent) {
    e.preventDefault();
    const body = {
      plan: d.plan.trim(),
      client_limit: num(d.client_limit),
      programme_limit: num(d.programme_limit),
      starts_on: d.starts_on,
      ends_on: d.ends_on || null,
      attribution_display: d.attribution_display,
    };
    if (mode?.kind === 'issue') {
      return run('Licence issued.', () =>
        sb().rpc('issue_licence', { p_partner: partnerId, p_limits: { ...body, status: d.status } })
      );
    }
    if (mode?.kind === 'edit') {
      const id = mode.id;
      return run('Licence updated.', () => sb().rpc('change_licence', { p_licence: id, p_patch: body }));
    }
  }

  const rowActions = (l: LicenceRow) => {
    if (l.status === 'terminated') return <span className="muted">terminated</span>;
    const act = (label: string, fn: () => PromiseLike<{ error: { message: string } | null }>) => (
      <Button key={label} size="sm" variant="ghost" disabled={busy} onClick={() => run(`${label}: done.`, fn)}>
        {label}
      </Button>
    );
    return (
      <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
        <Button size="sm" variant="ghost" disabled={busy} onClick={() => openEdit(l)}>Edit</Button>
        {l.status === 'draft'
          ? act('Activate', () => sb().rpc('change_licence', { p_licence: l.id, p_patch: { status: 'active' } }))
          : null}
        {l.status === 'active' ? act('Suspend', () => sb().rpc('suspend_licence', { p_licence: l.id })) : null}
        {l.status === 'suspended'
          ? act('Reactivate', () => sb().rpc('change_licence', { p_licence: l.id, p_patch: { status: 'active' } }))
          : null}
        <Button
          size="sm"
          variant="danger"
          disabled={busy}
          onClick={() => {
            if (!window.confirm('Close (terminate) this licence? A terminated licence cannot be changed again.')) return;
            run('Close: done.', () => sb().rpc('close_licence', { p_licence: l.id }));
          }}
        >
          Close
        </Button>
      </div>
    );
  };

  return (
    <div>
      <div className="sp-table-scroll">
        <table className="sp-table">
          <thead>
            <tr>
              <th>Plan</th>
              <th>Status</th>
              <th style={{ textAlign: 'right' }}>Clients</th>
              <th style={{ textAlign: 'right' }}>Programmes</th>
              <th>Term</th>
              <th>Attribution</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {licences.length ? (
              licences.map((l) => (
                <tr key={l.id}>
                  <td style={{ fontWeight: 500 }}>{l.plan}</td>
                  <td><StatusPill status={l.status} /></td>
                  <td className="mono" style={{ textAlign: 'right' }}>{l.client_limit ?? '∞'}</td>
                  <td className="mono" style={{ textAlign: 'right' }}>{l.programme_limit ?? '∞'}</td>
                  <td className="muted">{dateLabel(l.starts_on)} → {l.ends_on ? dateLabel(l.ends_on) : 'open'}</td>
                  <td className="muted">{l.attribution_display ? 'shown' : 'hidden'}</td>
                  <td>{rowActions(l)}</td>
                </tr>
              ))
            ) : (
              <tr>
                <td colSpan={7} className="muted">No licence issued yet — the partner cannot onboard clients until one is active.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <div style={{ padding: 20 }}>
        {msg.err ? <Alert tone="err">{msg.err}</Alert> : null}
        {msg.ok ? <Alert tone="ok">{msg.ok}</Alert> : null}
        {mode ? (
          <form onSubmit={submit}>
            <div className="muted" style={{ marginBottom: 8 }}>
              {mode.kind === 'issue' ? 'Issue a licence' : 'Change licence'}
            </div>
            <LicenceFields d={d} set={set} issuing={mode.kind === 'issue'} />
            <div style={{ display: 'flex', gap: 8 }}>
              <Button type="submit" size="sm" disabled={busy}>
                {busy ? 'Saving…' : mode.kind === 'issue' ? 'Issue licence' : 'Save licence'}
              </Button>
              <Button type="button" size="sm" variant="ghost" onClick={() => setMode(null)}>Cancel</Button>
            </div>
          </form>
        ) : (
          <Button
            size="sm"
            icon="plus"
            onClick={() => {
              setD({ ...EMPTY, starts_on: today() });
              setMsg({});
              setMode({ kind: 'issue' });
            }}
          >
            Issue licence
          </Button>
        )}
      </div>
    </div>
  );
}
