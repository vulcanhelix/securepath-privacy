'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';

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
    <form onSubmit={submit}>
      <label>Email</label>
      <input type="email" required value={email} onChange={e => setEmail(e.target.value)} />
      <label>Role</label>
      <select value={role} onChange={e => setRole(e.target.value)}>
        <option value="practice_consultant">Consultant</option>
        <option value="read_only">Read only</option>
      </select>
      <button disabled={busy}>{busy ? 'Sending…' : 'Send invite'}</button>
      {msg.err && <p className="err">{msg.err}</p>}
      {msg.ok && <p className="ok">{msg.ok}</p>}
    </form>
  );
}
