'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';

// W2-17 — FR-TEAM-01/02 write buttons for the partner team screen. All call
// the 20261106000028 RPCs under the caller's JWT; the in-body partner_admin
// guard is the real gate — these render only where the server component
// already decided the caller may act (UX, not authz).

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

/** FR-TEAM-02 — end every assignment the user holds under this partner. */
export function RemoveMember({ userId, name }: { userId: string; name: string }) {
  const { busy, err, call } = useRpc();
  return (
    <span style={{ display: 'inline-flex', gap: 8, alignItems: 'center' }}>
      <Button
        size="sm"
        variant="danger"
        disabled={busy}
        onClick={() => {
          if (!window.confirm(`Remove ${name}? All their access — partner and every client — ends at once and is logged.`)) return;
          void call('partner_remove_member', { p_user_id: userId });
        }}
      >
        Remove
      </Button>
      {err ? <Alert tone="err">{err}</Alert> : null}
    </span>
  );
}

/** FR-TEAM-01 — delete a pending invite. */
export function RevokeInvite({ token }: { token: string }) {
  const { busy, err, call } = useRpc();
  return (
    <span style={{ display: 'inline-flex', gap: 8, alignItems: 'center' }}>
      <Button
        size="sm"
        variant="ghost"
        disabled={busy}
        onClick={() => {
          if (!window.confirm('Revoke this invite? The link stops working.')) return;
          void call('partner_revoke_invite', { p_token: token });
        }}
      >
        Revoke
      </Button>
      {err ? <Alert tone="err">{err}</Alert> : null}
    </span>
  );
}

/** FR-TEAM-01 — attach a consultant to one of the partner's clients. */
export function AssignClient({
  userId,
  clients,
}: {
  userId: string;
  clients: { id: string; name: string }[];
}) {
  const { busy, err, call } = useRpc();
  const [client, setClient] = React.useState('');
  if (!clients.length) return null;
  return (
    <span style={{ display: 'inline-flex', gap: 6, alignItems: 'center' }}>
      <select
        className="sp-input"
        style={{ width: 'auto', padding: '4px 8px', fontSize: 'var(--fs-xs)' }}
        value={client}
        onChange={(e) => setClient(e.target.value)}
        aria-label="Client to assign"
      >
        <option value="">Client…</option>
        {clients.map((c) => (
          <option key={c.id} value={c.id}>{c.name}</option>
        ))}
      </select>
      <Button
        size="sm"
        variant="outline"
        disabled={busy || !client}
        onClick={() => void call('partner_assign_consultant', { p_user_id: userId, p_client_org_id: client })}
      >
        Assign
      </Button>
      {err ? <Alert tone="err">{err}</Alert> : null}
    </span>
  );
}

/** FR-TEAM-01 — end one client-scope consultant row (the × on a scope chip). */
export function UnassignClient({ userId, clientOrgId }: { userId: string; clientOrgId: string }) {
  const { busy, err, call } = useRpc();
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center' }}>
      <button
        type="button"
        className="sp-btn sp-btn--ghost sp-btn--sm"
        style={{ padding: '0 4px', margin: 0 }}
        disabled={busy}
        title="Remove this client assignment"
        onClick={() => void call('partner_unassign_consultant', { p_user_id: userId, p_client_org_id: clientOrgId })}
      >
        ×
      </button>
      {err ? <Alert tone="err">{err}</Alert> : null}
    </span>
  );
}
