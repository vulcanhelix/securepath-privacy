'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';

export default function NewAssessment() {
  const router = useRouter();
  const [f, setF] = useState({ 
    client_org_id: '', 
    title: '', 
    framework: 'popia',
    org_name: '', 
    auditor_name: '', 
    audit_date: '', 
    audit_ref: '' 
  });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF({ ...f, [k]: e.target.type === 'checkbox' ? (e.target as HTMLInputElement).checked : e.target.value });

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); 
    setErr('');
    
    const r = await fetch('/api/assessments', {
      method: 'POST', 
      headers: { 'Content-Type': 'application/json' }, 
      body: JSON.stringify({
        ...f,
        audit_date: f.audit_date || null,
      }),
    });
    
    setBusy(false);
    if (!r.ok) { 
      setErr((await r.json()).error ?? 'Failed to create assessment'); 
      return; 
    }
    
    router.push('/assessments');
    router.refresh();
  }

  return (
    <div className="card" style={{ maxWidth: 560, margin: '2rem auto' }}>
      <h1>New Assessment</h1>
      <p className="muted">Create a new POPIA/GDPR compliance assessment for a client.</p>
      <form onSubmit={submit}>
        <label>Client *</label>
        <select required value={f.client_org_id} onChange={set('client_org_id')}>
          <option value="">Select a client...</option>
          {/* TODO: Load clients from API */}
          <option value="99a083a3-eff6-4a2c-b3fe-6a9193a2a4a1">ClientCo</option>
        </select>

        <label>Assessment Title *</label>
        <input required value={f.title} onChange={set('title')} placeholder="e.g., POPIA Compliance Assessment 2026" />

        <label>Framework</label>
        <select value={f.framework} onChange={set('framework')}>
          <option value="popia">POPIA</option>
          <option value="gdpr">GDPR</option>
          <option value="iso27701">ISO 27701</option>
        </select>

        <label>Organization Name</label>
        <input value={f.org_name} onChange={set('org_name')} placeholder="Legal organization name" />

        <label>Auditor Name</label>
        <input value={f.auditor_name} onChange={set('auditor_name')} placeholder="Lead auditor name" />

        <label>Audit Date</label>
        <input type="date" value={f.audit_date} onChange={set('audit_date')} />

        <label>Assessment Reference</label>
        <input value={f.audit_ref} onChange={set('audit_ref')} placeholder="e.g., POPIA-2026-001" />

        <button disabled={busy}>{busy ? 'Creating...' : 'Create Assessment'}</button>
      </form>
      {err && <p className="err">{err}</p>}
    </div>
  );
}