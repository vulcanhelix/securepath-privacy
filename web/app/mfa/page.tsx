'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

// Verify an existing TOTP factor at sign-in (aal1 -> aal2).
export default function MfaVerify() {
  const router = useRouter();
  const supabase = browserClient();
  const [factorId, setFactorId] = useState('');
  const [code, setCode] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    supabase.auth.mfa.listFactors().then(({ data }) => {
      const f = data?.totp?.find(f => (f as any).status === 'verified') ?? data?.totp?.[0];
      if (!f) { router.replace('/mfa/enroll'); return; }
      setFactorId(f.id);
    });
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setErr('');
    const { data: ch, error: chErr } = await supabase.auth.mfa.challenge({ factorId });
    if (chErr) { setBusy(false); setErr(chErr.message); return; }
    const { error } = await supabase.auth.mfa.verify({ factorId, challengeId: ch.id, code });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    router.push('/dashboard');
    router.refresh();
  }

  return (
    <Card title="Two-factor authentication">
      <p className="muted" style={{ marginTop: 0 }}>Enter the 6-digit code from your authenticator app.</p>
      <form onSubmit={submit}>
        <Field label="Code">
          <Input required inputMode="numeric" pattern="[0-9]{6}" maxLength={6} value={code}
                 onChange={(e) => setCode(e.target.value)} autoFocus className="mono" />
        </Field>
        <Button type="submit" disabled={busy || !factorId}>{busy ? 'Verifying…' : 'Verify'}</Button>
      </form>
      {err && <Alert tone="err">{err}</Alert>}
    </Card>
  );
}
