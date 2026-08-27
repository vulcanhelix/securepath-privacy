'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select, Checkbox } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

export default function NewClient() {
  const router = useRouter();
  const [f, setF] = useState({ name: '', registration_no: '', industry: '', contact_name: '', contact_email: '', org_scale: 'sme', invite_admin: false });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF({ ...f, [k]: e.target.type === 'checkbox' ? (e.target as HTMLInputElement).checked : e.target.value });

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
    <>
      <PageHeader
        title="Onboard a client"
        back="Clients"
        backHref="/dashboard"
        meta={<>Creating a client instance is a <strong>billable event</strong> on your account.</>}
      />
      <Card style={{ maxWidth: 'var(--form-max)' }}>
        <form onSubmit={submit}>
          <Field label="Company name" required>
            <Input required value={f.name} onChange={set('name')} />
          </Field>
          <Field label="Company registration no.">
            <Input value={f.registration_no} onChange={set('registration_no')} />
          </Field>
          <Field label="Industry">
            <Input value={f.industry} onChange={set('industry')} placeholder="e.g. Healthcare" />
          </Field>
          <Field
            label="Organisation scale"
            required
            hint="Determines which Section 4 security questions apply. Advisor judgement — SME edition in the 2026 POPIA pack is ≤10 users."
          >
            <Select required value={f.org_scale} onChange={set('org_scale')}>
              <option value="sme">SME (source pack: ≤10 users)</option>
              <option value="large">Large corporation</option>
            </Select>
          </Field>
          <Field label="Primary contact name">
            <Input value={f.contact_name} onChange={set('contact_name')} />
          </Field>
          <Field label="Primary contact email">
            <Input type="email" value={f.contact_email} onChange={set('contact_email')} />
          </Field>
          <div style={{ margin: '4px 0 20px' }}>
            <Checkbox
              label="Invite the contact as client admin (they get an email invite)"
              checked={f.invite_admin}
              onChange={set('invite_admin')}
            />
          </div>
          <Button type="submit" disabled={busy} cta>{busy ? 'Creating…' : 'Create client instance'}</Button>
        </form>
        {err && <Alert tone="err">{err}</Alert>}
      </Card>
    </>
  );
}
