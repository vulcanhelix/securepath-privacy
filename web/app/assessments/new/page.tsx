'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';

interface Client {
  id: string;
  name: string;
  industry: string | null;
  contact_name: string | null;
  contact_email: string | null;
}

export default function NewAssessment() {
  const router = useRouter();
  const [clients, setClients] = useState<Client[]>([]);
  const [clientsLoading, setClientsLoading] = useState(true);
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

  useEffect(() => {
    fetch('/api/clients')
      .then(r => r.json())
      .then(data => {
        if (Array.isArray(data)) {
          setClients(data);
        }
      })
      .catch(e => {
        console.error('Failed to load clients:', e);
        setErr('Failed to load clients');
      })
      .finally(() => setClientsLoading(false));
  }, []);

  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF({ ...f, [k]: e.target.type === 'checkbox' ? (e.target as HTMLInputElement).checked : e.target.value });

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); 
    setErr('');
    
    if (!f.client_org_id) {
      setErr('Please select a client');
      setBusy(false);
      return;
    }
    
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
      <p className="muted">Create a new POPIA compliance assessment for a client.</p>
      <form onSubmit={submit}>
        <label>Client *</label>
        <select required value={f.client_org_id} onChange={set('client_org_id')}>
          <option value="">{clientsLoading ? 'Loading clients...' : 'Select a client...'}</option>
          {clients.map(c => (
            <option key={c.id} value={c.id}>
              {c.name} {c.industry ? `(${c.industry})` : ''}
            </option>
          ))}
        </select>

        <label>Assessment Title *</label>
        <input required value={f.title} onChange={set('title')} placeholder="e.g., POPIA Compliance Assessment 2026" />

        <label>Framework</label>
        <select value={f.framework} onChange={set('framework')}>
          <option value="popia">POPIA</option>
          <option value="gdpr">GDPR</option>
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