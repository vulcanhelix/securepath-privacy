'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Field, Input, Select } from '@/components/ui/forms';
import { PARTNER_TYPES } from '@/lib/platform';

// W2-14 — create a partner (FR-PLT-01). Posts to /api/platform/partners,
// which calls platform_create_partner under the caller's JWT and, when a
// first partner-admin email is given, mails the invite link exactly like
// /api/invites. On error the RPC message is shown and nothing is written.

const EMPTY = {
  name: '',
  type: 'msp',
  country: 'ZA',
  subdomain: '',
  primary_contact: '',
  data_region_default: 'ZA',
  admin_email: '',
};

export function CreatePartnerForm() {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [f, setF] = React.useState(EMPTY);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});
  const set = (k: keyof typeof EMPTY) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF((o) => ({ ...o, [k]: e.target.value }));

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMsg({});
    const res = await fetch('/api/platform/partners', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(f),
    });
    const body = (await res.json().catch(() => ({}))) as {
      error?: string;
      partner_id?: string;
      invited?: boolean;
      mail_error?: string;
    };
    setBusy(false);
    if (!res.ok || !body.partner_id) return setMsg({ err: body.error ?? `Request failed (${res.status})` });
    setF(EMPTY);
    setMsg({
      ok:
        `Created ${f.name}.` +
        (body.invited ? ` Invite sent to ${f.admin_email}.` : '') +
        (body.mail_error ? ` Invite created but the email failed: ${body.mail_error}` : ''),
    });
    router.refresh();
  }

  if (!open) {
    return (
      <>
        {msg.ok ? <Alert tone="ok">{msg.ok}</Alert> : null}
        <Button icon="plus" onClick={() => setOpen(true)}>New partner</Button>
      </>
    );
  }

  return (
    <Card title="New partner" action={<Button size="sm" variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>}>
      <form onSubmit={submit}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: '0 16px' }}>
          <Field label="Name" required>
            <Input value={f.name} onChange={set('name')} required />
          </Field>
          <Field label="Type" required>
            <Select value={f.type} onChange={set('type')}>
              {PARTNER_TYPES.map((t) => (
                <option key={t.value} value={t.value}>{t.label}</option>
              ))}
            </Select>
          </Field>
          <Field label="Country" required hint="ISO code, e.g. ZA, UK">
            <Input value={f.country} onChange={set('country')} required maxLength={8} />
          </Field>
          <Field label="Subdomain" hint="lower-case letters, digits, hyphens">
            <Input value={f.subdomain} onChange={set('subdomain')} pattern="[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?" />
          </Field>
          <Field label="Primary contact" hint="name / email / phone">
            <Input value={f.primary_contact} onChange={set('primary_contact')} />
          </Field>
          <Field label="Default data region">
            <Select value={f.data_region_default} onChange={set('data_region_default')}>
              <option value="ZA">ZA</option>
              <option value="UK">UK</option>
              <option value="">— none —</option>
            </Select>
          </Field>
          <Field label="First partner admin (email)" hint="optional — sends a partner-admin invite">
            <Input type="email" value={f.admin_email} onChange={set('admin_email')} />
          </Field>
        </div>
        {msg.err ? <Alert tone="err">{msg.err}</Alert> : null}
        <Button type="submit" disabled={busy} cta>
          {busy ? 'Creating…' : 'Create partner'}
        </Button>
      </form>
    </Card>
  );
}
