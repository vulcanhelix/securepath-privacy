'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

export default function Onboarding() {
  const router = useRouter();
  const [name, setName] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setErr('');
    const supabase = browserClient();
    const { error } = await supabase.rpc('create_practice', { p_name: name });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    router.push('/dashboard');
    router.refresh();
  }

  return (
    <Card title="Set up your practice">
      <p className="muted" style={{ marginTop: 0 }}>
        Your MSP practice is the reseller account. You can brand it and invite up to 5 team members.
      </p>
      <form onSubmit={submit}>
        <Field label="Practice name">
          <Input required value={name} onChange={(e) => setName(e.target.value)} placeholder="Acme MSP (Pty) Ltd" />
        </Field>
        <Button type="submit" disabled={busy} cta>{busy ? 'Creating…' : 'Create practice'}</Button>
      </form>
      {err && <Alert tone="err">{err}</Alert>}
    </Card>
  );
}
