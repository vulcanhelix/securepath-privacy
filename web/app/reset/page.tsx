'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

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
    <Card title="Choose a new password">
      <form onSubmit={submit}>
        <Field label="New password" hint="At least 8 characters.">
          <Input type="password" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} />
        </Field>
        <Button type="submit" disabled={busy}>
          {busy ? 'Saving…' : 'Set password'}
        </Button>
      </form>
      {msg.err && <Alert tone="err">{msg.err}</Alert>}
      {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
    </Card>
  );
}
