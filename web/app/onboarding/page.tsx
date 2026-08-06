'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

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
    <div className="card" style={{ maxWidth: 480, margin: '3rem auto' }}>
      <h1>Set up your practice</h1>
      <p className="muted">Your MSP practice is the reseller account. You can brand it and invite up to 5 team members.</p>
      <form onSubmit={submit}>
        <label>Practice name</label>
        <input required value={name} onChange={e => setName(e.target.value)} placeholder="Acme MSP (Pty) Ltd" />
        <button disabled={busy}>{busy ? 'Creating…' : 'Create practice'}</button>
      </form>
      {err && <p className="err">{err}</p>}
    </div>
  );
}
