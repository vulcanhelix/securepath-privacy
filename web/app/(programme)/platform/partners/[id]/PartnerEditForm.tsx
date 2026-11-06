'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Field, Input, Select } from '@/components/ui/forms';
import { PARTNER_TYPES, type PartnerRow } from '@/lib/platform';

// W2-14 — edit partner metadata via platform_update_partner. Only changed
// fields are sent (the RPC allowlists them and audits patch + previous).
// Branding is the partner admin's own screen (W2-03), not editable here.

const FIELDS = ['name', 'type', 'country', 'subdomain', 'primary_contact', 'support_contact', 'data_region_default'] as const;
type Key = (typeof FIELDS)[number];

const LABELS: Record<Key, string> = {
  name: 'Name',
  type: 'Type',
  country: 'Country',
  subdomain: 'Subdomain',
  primary_contact: 'Primary contact',
  support_contact: 'Support contact',
  data_region_default: 'Default data region',
};

export function PartnerEditForm({ partner, canEdit }: { partner: PartnerRow; canEdit: boolean }) {
  const router = useRouter();
  const initial = React.useMemo(
    () => Object.fromEntries(FIELDS.map((k) => [k, (partner[k] as string | null) ?? ''])) as Record<Key, string>,
    [partner]
  );
  const [f, setF] = React.useState(initial);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});
  React.useEffect(() => setF(initial), [initial]);

  const set = (k: Key) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF((o) => ({ ...o, [k]: e.target.value }));
  const changed = FIELDS.filter((k) => f[k] !== initial[k]);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!changed.length) return;
    setBusy(true);
    setMsg({});
    const payload = Object.fromEntries(changed.map((k) => [k, f[k].trim() === '' ? null : f[k].trim()]));
    const { error } = await browserClient().rpc('platform_update_partner', {
      p_partner: partner.partner_id,
      p_payload: payload,
    });
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    setMsg({ ok: `Saved ${changed.map((k) => LABELS[k].toLowerCase()).join(', ')}.` });
    router.refresh();
  }

  return (
    <form onSubmit={save}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '0 16px' }}>
        <Field label={LABELS.name} required>
          <Input value={f.name} onChange={set('name')} disabled={!canEdit} required />
        </Field>
        <Field label={LABELS.type} required>
          <Select value={f.type} onChange={set('type')} disabled={!canEdit}>
            {PARTNER_TYPES.map((t) => (
              <option key={t.value} value={t.value}>{t.label}</option>
            ))}
          </Select>
        </Field>
        <Field label={LABELS.country} required>
          <Input value={f.country} onChange={set('country')} disabled={!canEdit} required maxLength={8} />
        </Field>
        <Field label={LABELS.subdomain} hint="empty = none">
          <Input value={f.subdomain} onChange={set('subdomain')} disabled={!canEdit} />
        </Field>
        <Field label={LABELS.primary_contact}>
          <Input value={f.primary_contact} onChange={set('primary_contact')} disabled={!canEdit} />
        </Field>
        <Field label={LABELS.support_contact}>
          <Input value={f.support_contact} onChange={set('support_contact')} disabled={!canEdit} />
        </Field>
        <Field label={LABELS.data_region_default}>
          <Select value={f.data_region_default} onChange={set('data_region_default')} disabled={!canEdit}>
            <option value="">— none —</option>
            <option value="ZA">ZA</option>
            <option value="UK">UK</option>
          </Select>
        </Field>
      </div>
      {msg.err ? <Alert tone="err">{msg.err}</Alert> : null}
      {msg.ok ? <Alert tone="ok">{msg.ok}</Alert> : null}
      {canEdit ? (
        <Button type="submit" size="sm" disabled={busy || !changed.length}>
          {busy ? 'Saving…' : 'Save changes'}
        </Button>
      ) : null}
    </form>
  );
}
