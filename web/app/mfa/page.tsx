'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

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
    <div className="card" style={{ maxWidth: 420, margin: '3rem auto' }}>
      <h1>Two-factor authentication</h1>
      <p className="muted">Enter the 6-digit code from your authenticator app.</p>
      <form onSubmit={submit}>
        <label>Code</label>
        <input required inputMode="numeric" pattern="[0-9]{6}" maxLength={6} value={code}
               onChange={e => setCode(e.target.value)} autoFocus />
        <button disabled={busy || !factorId}>{busy ? 'Verifying…' : 'Verify'}</button>
      </form>
      {err && <p className="err">{err}</p>}
    </div>
  );
}
