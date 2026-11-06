'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Field, Textarea } from '@/components/ui/forms';
import { StatusPill } from '@/components/ui/StatusPill';

// W2-14 — suspend / reactivate / close (FR-PLT-01/06) via
// platform_set_partner_status, reason mandatory and audited. This RECORDS
// the status; blocking sign-in for a suspended partner's users is W4-08.

type Status = 'active' | 'suspended' | 'closed';

const ACTIONS: Record<Status, { to: Status; label: string; variant: 'outline' | 'danger' }[]> = {
  active: [
    { to: 'suspended', label: 'Suspend', variant: 'outline' },
    { to: 'closed', label: 'Close', variant: 'danger' },
  ],
  suspended: [
    { to: 'active', label: 'Reactivate', variant: 'outline' },
    { to: 'closed', label: 'Close', variant: 'danger' },
  ],
  closed: [],
};

export function PartnerStatusPanel({
  partnerId,
  status,
  canEdit,
}: {
  partnerId: string;
  status: Status;
  canEdit: boolean;
}) {
  const router = useRouter();
  const [target, setTarget] = React.useState<Status | null>(null);
  const [reason, setReason] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});

  async function apply(e: React.FormEvent) {
    e.preventDefault();
    if (!target) return;
    setBusy(true);
    setMsg({});
    const { error } = await browserClient().rpc('platform_set_partner_status', {
      p_partner: partnerId,
      p_status: target,
      p_reason: reason,
    });
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    setMsg({ ok: `Partner is now ${target}.` });
    setTarget(null);
    setReason('');
    router.refresh();
  }

  return (
    <div>
      <div style={{ marginBottom: 12 }}>
        <StatusPill status={status} />
      </div>
      {status === 'closed' ? (
        <p className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
          Closed is final. Client data is kept and handled under the partner and client agreements.
        </p>
      ) : null}
      {canEdit && !target ? (
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {ACTIONS[status].map((a) => (
            <Button key={a.to} size="sm" variant={a.variant} onClick={() => setTarget(a.to)}>
              {a.label}
            </Button>
          ))}
        </div>
      ) : null}
      {canEdit && target ? (
        <form onSubmit={apply}>
          <Field label={`Reason to ${target === 'active' ? 'reactivate' : target === 'closed' ? 'close' : 'suspend'}`} required hint="Kept in the audit log">
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} required style={{ minHeight: 70 }} />
          </Field>
          <div style={{ display: 'flex', gap: 8 }}>
            <Button type="submit" size="sm" variant={target === 'closed' ? 'danger' : 'primary'} disabled={busy || !reason.trim()}>
              {busy ? 'Saving…' : 'Confirm'}
            </Button>
            <Button type="button" size="sm" variant="ghost" onClick={() => setTarget(null)}>
              Cancel
            </Button>
          </div>
        </form>
      ) : null}
      {msg.err ? <Alert tone="err">{msg.err}</Alert> : null}
      {msg.ok ? <Alert tone="ok">{msg.ok}</Alert> : null}
      <p className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 12 }}>
        Recording a suspension does not yet block sign-in; that enforcement lands with W4-08.
      </p>
    </div>
  );
}
