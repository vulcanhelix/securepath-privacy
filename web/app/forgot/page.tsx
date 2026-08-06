'use client';
import { useState } from 'react';
import { browserClient } from '@/lib/supabase-browser';

export default function Forgot() {
  const [email, setEmail] = useState('');
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg({});
    const { error } = await browserClient().auth.resetPasswordForEmail(email, {
      redirectTo: `${location.origin}/auth/confirm?next=/reset`,
    });
    setBusy(false);
    if (error) setMsg({ err: error.message });
    else setMsg({ ok: 'If that account exists, a reset link is on its way.' });
  }

  return (
    <div className="card" style={{ maxWidth: 420, margin: '3rem auto' }}>
      <h1>Reset your password</h1>
      <form onSubmit={submit}>
        <label>Email</label>
        <input type="email" required value={email} onChange={e => setEmail(e.target.value)} />
        <button disabled={busy}>{busy ? 'Sending…' : 'Send reset link'}</button>
      </form>
      {msg.err && <p className="err">{msg.err}</p>}
      {msg.ok && <p className="ok">{msg.ok}</p>}
      <p className="muted"><a href="/login">Back to sign in</a></p>
    </div>
  );
}
