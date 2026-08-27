'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

interface Client {
  id: string;
  name: string;
  industry: string | null;
  contact_name: string | null;
  contact_email: string | null;
}

interface Framework {
  key: string;
  name: string;
  track_kind: string;
}

export default function NewAssessment() {
  const router = useRouter();
  const [clients, setClients] = useState<Client[]>([]);
  const [clientsLoading, setClientsLoading] = useState(true);
  const [frameworks, setFrameworks] = useState<Framework[]>([]);
  const [f, setF] = useState({
    client_org_id: '',
    title: '',
    framework: 'popia',
    org_name: '',
    auditor_name: '',
    audit_date: '',
    audit_ref: '',
  });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetch('/api/clients')
      .then(r => r.json())
      .then(data => { if (Array.isArray(data)) setClients(data); })
      .catch(() => setErr('Failed to load clients'))
      .finally(() => setClientsLoading(false));
    fetch('/api/frameworks')
      .then(r => r.json())
      .then(data => { if (Array.isArray(data)) setFrameworks(data); })
      .catch(() => {});
  }, []);

  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF({ ...f, [k]: e.target.value });

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
      body: JSON.stringify({ ...f, audit_date: f.audit_date || null }),
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
    <>
      <PageHeader
        title="New assessment"
        back="Assessments"
        backHref="/assessments"
        meta="Create a compliance assessment for a client."
      />
      <Card style={{ maxWidth: 'var(--form-max)' }}>
        <form onSubmit={submit}>
          <Field label="Client" required>
            <Select required value={f.client_org_id} onChange={set('client_org_id')}>
              <option value="">{clientsLoading ? 'Loading clients…' : 'Select a client…'}</option>
              {clients.map(c => (
                <option key={c.id} value={c.id}>
                  {c.name} {c.industry ? `(${c.industry})` : ''}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="Assessment title" required>
            <Input required value={f.title} onChange={set('title')} placeholder="e.g. POPIA Compliance Assessment 2026" />
          </Field>
          <Field label="Framework">
            <Select value={f.framework} onChange={set('framework')}>
              {frameworks.length === 0 && <option value="popia">POPIA</option>}
              {frameworks.map(fw => (
                <option key={fw.key} value={fw.key}>
                  {fw.name} {fw.track_kind === 'cyber' ? '(cyber track)' : ''}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="Organization name">
            <Input value={f.org_name} onChange={set('org_name')} placeholder="Legal organization name" />
          </Field>
          <Field label="Auditor name">
            <Input value={f.auditor_name} onChange={set('auditor_name')} placeholder="Lead auditor name" />
          </Field>
          <Field label="Audit date">
            <Input type="date" value={f.audit_date} onChange={set('audit_date')} />
          </Field>
          <Field label="Assessment reference">
            <Input value={f.audit_ref} onChange={set('audit_ref')} placeholder="e.g. POPIA-2026-001" className="mono" />
          </Field>
          <Button type="submit" disabled={busy} cta>{busy ? 'Creating…' : 'Create assessment'}</Button>
        </form>
        {err && <Alert tone="err">{err}</Alert>}
      </Card>
    </>
  );
}
