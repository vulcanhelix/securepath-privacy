'use client';
import { useState } from 'react';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

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
    <Card title="Reset your password">
      <form onSubmit={submit}>
        <Field label="Email">
          <Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </Field>
        <Button type="submit" disabled={busy}>
          {busy ? 'Sending…' : 'Send reset link'}
        </Button>
      </form>
      {msg.err && <Alert tone="err">{msg.err}</Alert>}
      {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
      <p className="muted" style={{ marginTop: 20 }}>
        <a href="/login" style={{ color: 'var(--text)' }}>Back to sign in</a>
      </p>
    </Card>
  );
}
