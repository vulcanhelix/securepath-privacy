'use client';
import { useState } from 'react';
import { browserClient } from '@/lib/supabase-browser';

export default function Signup() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg({});
    const supabase = browserClient();
    const { error } = await supabase.auth.signUp({
      email, password,
      options: { emailRedirectTo: `${location.origin}/auth/confirm` },
    });
    setBusy(false);
    if (error) setMsg({ err: error.message });
    else setMsg({ ok: 'Check your email to confirm your account, then sign in.' });
  }

  return (
    <div className="card" style={{ maxWidth: 420, margin: '3rem auto' }}>
      <h1>Create your account</h1>
      <form onSubmit={submit}>
        <label>Work email</label>
        <input type="email" required value={email} onChange={e => setEmail(e.target.value)} />
        <label>Password</label>
        <input type="password" required minLength={8} value={password} onChange={e => setPassword(e.target.value)} />
        <button disabled={busy}>{busy ? 'Creating…' : 'Sign up'}</button>
      </form>
      {msg.err && <p className="err">{msg.err}</p>}
      {msg.ok && <p className="ok">{msg.ok}</p>}
    </div>
  );
}
