'use client';
import { use, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

export default function AcceptInvite({ params }: { params: Promise<{ token: string }> }) {
  const { token } = use(params);
  const router = useRouter();
  const supabase = browserClient();
  const [mode, setMode] = useState<'signup' | 'login'>('signup');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  async function accept() {
    const { error } = await supabase.rpc('accept_invite', { p_token: token });
    if (error) { setMsg({ err: error.message }); return false; }
    return true;
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg({});
    if (mode === 'signup') {
      const { error } = await supabase.auth.signUp({
        email, password,
        options: { emailRedirectTo: `${location.origin}/invite/${token}` },
      });
      setBusy(false);
      if (error) { setMsg({ err: error.message }); return; }
      setMsg({ ok: 'Check your email to confirm, then return to this page and sign in to accept.' });
      setMode('login');
      return;
    }
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) { setBusy(false); setMsg({ err: error.message }); return; }
    const ok = await accept();
    setBusy(false);
    if (ok) { router.push('/dashboard'); router.refresh(); }
  }

  return (
    <Card title="Accept your invite">
      <p className="muted" style={{ marginTop: 0 }}>
        {mode === 'signup' ? 'Create an account with the email the invite was sent to.' : 'Sign in with the invited email to join.'}
      </p>
      <form onSubmit={submit}>
        <Field label="Email">
          <Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </Field>
        <Field label="Password">
          <Input type="password" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} />
        </Field>
        <Button type="submit" disabled={busy}>
          {busy ? 'Working…' : mode === 'signup' ? 'Sign up & accept' : 'Sign in & accept'}
        </Button>
      </form>
      <p className="muted" style={{ marginTop: 16 }}>
        {mode === 'signup'
          ? <>Already have an account? <a onClick={() => setMode('login')} style={{ cursor: 'pointer', color: 'var(--text)' }}>Sign in instead</a></>
          : <>New here? <a onClick={() => setMode('signup')} style={{ cursor: 'pointer', color: 'var(--text)' }}>Sign up instead</a></>}
      </p>
      {msg.err && <Alert tone="err">{msg.err}</Alert>}
      {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
    </Card>
  );
}
