'use client';
import { useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Suspense } from 'react';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

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
    <Card title="Sign in">
      <form onSubmit={submit}>
        <Field label="Email">
          <Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </Field>
        <Field label="Password">
          <Input type="password" required value={password} onChange={(e) => setPassword(e.target.value)} />
        </Field>
        <Button type="submit" disabled={busy} cta>
          {busy ? 'Signing in…' : 'Sign in'}
        </Button>
      </form>
      {err && <Alert tone="err">{err}</Alert>}
      {sent && <Alert tone="ok">{sent}</Alert>}
      <div style={{ marginTop: 16 }}>
        <Button type="button" variant="outline" size="sm" disabled={busy} onClick={magicLink}>
          Email me a magic link instead
        </Button>
      </div>
      <p className="muted" style={{ marginTop: 20 }}>
        <a href="/forgot" style={{ color: 'var(--text)' }}>Forgot password?</a> · No account?{' '}
        <a href="/signup" style={{ color: 'var(--text)' }}>Sign up</a>
      </p>
    </Card>
  );
}

export default function Login() {
  return <Suspense><LoginForm /></Suspense>;
}
