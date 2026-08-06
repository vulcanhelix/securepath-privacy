'use client';
import { useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Suspense } from 'react';
import { browserClient } from '@/lib/supabase-browser';

function LoginForm() {
  const router = useRouter();
  const params = useSearchParams();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [err, setErr] = useState('');
  const [sent, setSent] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setErr('');
    const supabase = browserClient();
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    router.push(params.get('next') ?? '/dashboard');
    router.refresh();
  }

  async function magicLink() {
    if (!email) { setErr('Enter your email first, then click the magic-link button.'); return; }
    setBusy(true); setErr(''); setSent('');
    const supabase = browserClient();
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: `${location.origin}/auth/confirm`, shouldCreateUser: false },
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setSent('Magic link sent — check your email.');
  }

  return (
    <div className="card" style={{ maxWidth: 420, margin: '3rem auto' }}>
      <h1>Sign in</h1>
      <form onSubmit={submit}>
        <label>Email</label>
        <input type="email" required value={email} onChange={e => setEmail(e.target.value)} />
        <label>Password</label>
        <input type="password" required value={password} onChange={e => setPassword(e.target.value)} />
        <button disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
      </form>
      {err && <p className="err">{err}</p>}
      {sent && <p className="ok">{sent}</p>}
      <button type="button" disabled={busy} onClick={magicLink}
              style={{ background: 'transparent', color: 'var(--accent)', border: '1px solid var(--border)' }}>
        Email me a magic link instead
      </button>
      <p className="muted"><a href="/forgot">Forgot password?</a> · No account? <a href="/signup">Sign up</a></p>
    </div>
  );
}

export default function Login() {
  return <Suspense><LoginForm /></Suspense>;
}
