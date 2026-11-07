'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

// W2-17 — FR-TEAM-01 invite form. Role options are exactly the W2-14
// create_invite allowlist (consultant / read_only / client roles — never an
// owner or admin). Client roles pin the invite to one of the partner's
// clients (client_org_id), which the invites CHECK requires.

const CLIENT_ROLES = ['client_admin', 'client_contributor'];

export default function InviteForm({ clients }: { clients: { id: string; name: string }[] }) {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [role, setRole] = useState('practice_consultant');
  const [clientOrgId, setClientOrgId] = useState('');
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  const isClientRole = CLIENT_ROLES.includes(role);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (isClientRole && !clientOrgId) { setMsg({ err: 'Pick the client this user belongs to.' }); return; }
    setBusy(true); setMsg({});
    const r = await fetch('/api/invites', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, role, client_org_id: isClientRole ? clientOrgId : null }),
    });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'failed' }); return; }
    setMsg({ ok: `Invite sent to ${email}` });
    setEmail('');
    router.refresh();
  }

  return (
    <form onSubmit={submit} style={{ maxWidth: 'var(--form-max)' }}>
      <Field label="Email">
        <Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
      </Field>
      <Field label="Role">
        <Select value={role} onChange={(e) => { setRole(e.target.value); setClientOrgId(''); }}>
          <option value="practice_consultant">Consultant</option>
          <option value="read_only">Read only</option>
          <option value="client_admin">Client admin</option>
          <option value="client_contributor">Client contributor</option>
        </Select>
      </Field>
      {isClientRole ? (
        <Field label="Client" hint="Client-side users are pinned to one client org and don't take a team seat.">
          <Select value={clientOrgId} onChange={(e) => setClientOrgId(e.target.value)} required>
            <option value="">Choose a client…</option>
            {clients.map((c) => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </Select>
        </Field>
      ) : null}
      <Button type="submit" disabled={busy}>{busy ? 'Sending…' : 'Send invite'}</Button>
      {msg.err && <Alert tone="err">{msg.err}</Alert>}
      {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
    </form>
  );
}
