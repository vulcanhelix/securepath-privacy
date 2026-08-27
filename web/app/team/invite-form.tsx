'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

export default function InviteForm() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [role, setRole] = useState('practice_consultant');
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg({});
    const r = await fetch('/api/invites', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, role }),
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
        <Select value={role} onChange={(e) => setRole(e.target.value)}>
          <option value="practice_consultant">Consultant</option>
          <option value="read_only">Read only</option>
        </Select>
      </Field>
      <Button type="submit" disabled={busy}>{busy ? 'Sending…' : 'Send invite'}</Button>
      {msg.err && <Alert tone="err">{msg.err}</Alert>}
      {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
    </form>
  );
}
