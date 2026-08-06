'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

export default function Reset() {
  const router = useRouter();
  const [password, setPassword] = useState('');
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg({});
    const { error } = await browserClient().auth.updateUser({ password });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setMsg({ ok: 'Password updated.' });
    router.push('/dashboard');
    router.refresh();
  }

  return (
    <div className="card" style={{ maxWidth: 420, margin: '3rem auto' }}>
      <h1>Choose a new password</h1>
      <form onSubmit={submit}>
        <label>New password</label>
        <input type="password" required minLength={8} value={password} onChange={e => setPassword(e.target.value)} />
        <button disabled={busy}>{busy ? 'Saving…' : 'Set password'}</button>
      </form>
      {msg.err && <p className="err">{msg.err}</p>}
      {msg.ok && <p className="ok">{msg.ok}</p>}
    </div>
  );
}
