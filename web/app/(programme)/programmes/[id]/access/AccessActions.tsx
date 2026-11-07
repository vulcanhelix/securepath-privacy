'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';

// W4-01 — FR-PLT-04 decision + revocation buttons. Rendered only for callers
// the server component computed may act (the RPCs re-check the same guard
// in-body — these buttons are UX, not authz). Every call writes audit_log
// and notifies, per migration 20261106000009/000019.

function useRpc() {
  const router = useRouter();
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);
  const call = async (fn: string, args: Record<string, unknown>) => {
    setBusy(true);
    setErr(null);
    const { error } = await browserClient().rpc(fn, args);
    setBusy(false);
    if (error) return setErr(error.message);
    router.refresh();
  };
  return { busy, err, call };
}

export function ApproveDecline({ requestId }: { requestId: string }) {
  const { busy, err, call } = useRpc();
  return (
    <span style={{ display: 'inline-flex', gap: 8, alignItems: 'center' }}>
      <Button
        size="sm"
        disabled={busy}
        onClick={() => call('approve_support_grant', { p_request_id: requestId })}
      >
        Approve
      </Button>
      <Button
        size="sm"
        variant="ghost"
        disabled={busy}
        onClick={() => {
          const note = window.prompt('Reason for declining (shown to SecurePath, kept in the audit log):', '');
          if (note === null) return; // cancelled
          void call('decline_support_request', { p_request_id: requestId, p_note: note || null });
        }}
      >
        Decline
      </Button>
      {err ? <Alert tone="err">{err}</Alert> : null}
    </span>
  );
}

export function RevokeGrant({ grantId }: { grantId: string }) {
  const { busy, err, call } = useRpc();
  return (
    <span style={{ display: 'inline-flex', gap: 8, alignItems: 'center' }}>
      <Button
        size="sm"
        variant="danger"
        disabled={busy}
        onClick={() => {
          if (!window.confirm('End this support grant now? The window is cut short and the end is logged.')) return;
          void call('revoke_support_grant', { p_grant_id: grantId });
        }}
      >
        Revoke
      </Button>
      {err ? <Alert tone="err">{err}</Alert> : null}
    </span>
  );
}
