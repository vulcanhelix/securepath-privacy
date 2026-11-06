'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Field, Input, Select, Textarea } from '@/components/ui/forms';
import type { PlatformClientRow } from '@/lib/platform';

// W2-14 — FR-PLT-04 request: request_support_access(client, reason, expiry).
// Creates a PENDING request only; nothing is visible until the client side
// approves (W4-01 builds the approval screen).

const WINDOWS = [
  { hours: 4, label: '4 hours' },
  { hours: 24, label: '24 hours' },
  { hours: 72, label: '3 days' },
  { hours: 168, label: '7 days' },
];

export function RequestAccessForm({ clients, preselect }: { clients: PlatformClientRow[]; preselect: string }) {
  const router = useRouter();
  const [client, setClient] = React.useState(clients.some((c) => c.client_org_id === preselect) ? preselect : '');
  const [reason, setReason] = React.useState('');
  const [hours, setHours] = React.useState('24');
  const [filter, setFilter] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});

  const shown = clients.filter((c) =>
    `${c.client_name} ${c.partner_name}`.toLowerCase().includes(filter.trim().toLowerCase())
  );

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMsg({});
    const expires = new Date(Date.now() + Number(hours) * 3600_000).toISOString();
    const { error } = await browserClient().rpc('request_support_access', {
      p_client_org_id: client,
      p_reason: reason,
      p_expires_at: expires,
    });
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    setReason('');
    setMsg({ ok: 'Request sent. The client’s accountable officer or partner admin must approve it before access opens.' });
    router.refresh();
  }

  if (!clients.length) {
    return <p className="muted">No clients on the platform yet.</p>;
  }

  return (
    <form onSubmit={submit}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))', gap: '0 16px' }}>
        <Field label="Client" required>
          <Input placeholder="Filter clients…" value={filter} onChange={(e) => setFilter(e.target.value)} style={{ marginBottom: 6 }} />
          <Select value={client} onChange={(e) => setClient(e.target.value)} required>
            <option value="">— choose a client —</option>
            {shown.map((c) => (
              <option key={c.client_org_id} value={c.client_org_id}>
                {c.client_name} · {c.partner_name}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Access window" required hint="counted from now — the request lapses if not approved in time">
          <Select value={hours} onChange={(e) => setHours(e.target.value)}>
            {WINDOWS.map((w) => (
              <option key={w.hours} value={w.hours}>{w.label}</option>
            ))}
          </Select>
        </Field>
      </div>
      <Field label="Reason" required hint="Shown to the client and kept in the audit log">
        <Textarea value={reason} onChange={(e) => setReason(e.target.value)} required style={{ minHeight: 70 }} />
      </Field>
      {msg.err ? <Alert tone="err">{msg.err}</Alert> : null}
      {msg.ok ? <Alert tone="ok">{msg.ok}</Alert> : null}
      <Button type="submit" disabled={busy || !client || !reason.trim()}>
        {busy ? 'Sending…' : 'Request access'}
      </Button>
    </form>
  );
}
