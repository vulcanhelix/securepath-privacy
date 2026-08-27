'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

// Compulsory TOTP enrolment: first sign-in lands here until a factor is verified.
export default function MfaEnroll() {
  const router = useRouter();
  const supabase = browserClient();
  const [factorId, setFactorId] = useState('');
  const [qr, setQr] = useState('');
  const [secret, setSecret] = useState('');
  const [code, setCode] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    (async () => {
      // clean out any half-finished enrolments, then start fresh
      const { data } = await supabase.auth.mfa.listFactors();
      for (const f of data?.totp ?? []) {
        if ((f as any).status === 'verified') { router.replace('/mfa'); return; }
        await supabase.auth.mfa.unenroll({ factorId: f.id });
      }
      const { data: enr, error } = await supabase.auth.mfa.enroll({ factorType: 'totp' });
      if (error) { setErr(error.message); return; }
      setFactorId(enr.id);
      setQr(enr.totp.qr_code);
      setSecret(enr.totp.secret);
    })();
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
    <Card title="Set up two-factor authentication">
      <p className="muted" style={{ marginTop: 0 }}>
        2FA is required. Scan the QR code with Google Authenticator (or any TOTP app), then enter the 6-digit code.
      </p>
      {qr && (
        <p style={{ textAlign: 'center' }}>
          <img src={qr} alt="TOTP QR code" style={{ width: 180, borderRadius: 'var(--r-ctl)', background: '#fff', padding: 8 }} />
        </p>
      )}
      {secret && (
        <p className="muted" style={{ wordBreak: 'break-all' }}>
          Manual key: <code>{secret}</code>
        </p>
      )}
      <form onSubmit={submit}>
        <Field label="Code from your app">
          <Input required inputMode="numeric" pattern="[0-9]{6}" maxLength={6} value={code}
                 onChange={(e) => setCode(e.target.value)} className="mono" />
        </Field>
        <Button type="submit" disabled={busy || !factorId}>{busy ? 'Verifying…' : 'Activate 2FA'}</Button>
      </form>
      {err && <Alert tone="err">{err}</Alert>}
    </Card>
  );
}
