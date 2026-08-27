'use client';
import { useState } from 'react';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

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
    <Card title="Create your account">
      <form onSubmit={submit}>
        <Field label="Work email">
          <Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </Field>
        <Field label="Password" hint="At least 8 characters.">
          <Input type="password" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} />
        </Field>
        <Button type="submit" disabled={busy} cta>
          {busy ? 'Creating…' : 'Sign up'}
        </Button>
      </form>
      {msg.err && <Alert tone="err">{msg.err}</Alert>}
      {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
    </Card>
  );
}
