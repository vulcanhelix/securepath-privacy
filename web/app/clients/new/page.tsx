'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';

export default function NewClient() {
  const router = useRouter();
  const [f, setF] = useState({ name: '', registration_no: '', industry: '', contact_name: '', contact_email: '', invite_admin: false });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setErr('');
    const r = await fetch('/api/clients', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(f),
    });
    setBusy(false);
    if (!r.ok) { setErr((await r.json()).error ?? 'failed'); return; }
    router.push('/dashboard');
    router.refresh();
  }

  return (
    <div className="card" style={{ maxWidth: 560, margin: '2rem auto' }}>
      <h1>Onboard a client</h1>
      <p className="muted">Creating a client instance is a <strong>billable event</strong> on your account.</p>
      <form onSubmit={submit}>
        <label>Company name *</label>
        <input required value={f.name} onChange={set('name')} />
        <label>Company registration no.</label>
        <input value={f.registration_no} onChange={set('registration_no')} />
        <label>Industry</label>
        <input value={f.industry} onChange={set('industry')} placeholder="e.g. Healthcare" />
        <label>Primary contact name</label>
        <input value={f.contact_name} onChange={set('contact_name')} />
        <label>Primary contact email</label>
        <input type="email" value={f.contact_email} onChange={set('contact_email')} />
        <label style={{ display: 'flex', gap: '.5rem', alignItems: 'center', fontWeight: 400 }}>
          <input type="checkbox" style={{ width: 'auto' }} checked={f.invite_admin} onChange={set('invite_admin')} />
          Invite the contact as client admin (they get an email invite)
        </label>
        <button disabled={busy}>{busy ? 'Creating…' : 'Create client instance'}</button>
      </form>
      {err && <p className="err">{err}</p>}
    </div>
  );
}
