import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';
import { StatusPill } from '@/components/ui/StatusPill';
import { ApproveDecline, RevokeGrant } from './AccessActions';

export const dynamic = 'force-dynamic';

// W4-01 — the client-side support-access ledger + decision surface
// (FR-PLT-04 / NFR-04, AT-04): SecurePath has no standing access; every
// request, decision, window and early end is listed here so "every action
// during the grant is logged and visible to the client". The owning
// partner's partner_admin or the client's accountable officer / IO decides
// requests and may end a live grant early; the grant holder may relinquish
// their own access. Platform staff never decide.
//
// Visibility of this SCREEN is the nav slot's clientSees(CLIENT_READ) — the
// action buttons render only for the approver/revoker sets, and the RPCs
// re-check every guard in-body regardless.

interface RequestRow {
  id: string;
  client_org_id: string;
  requested_by: string;
  reason: string;
  starts_at: string;
  expires_at: string;
  status: 'pending' | 'approved' | 'declined' | 'expired';
  decided_by: string | null;
  decided_at: string | null;
  grant_id: string | null;
  created_at: string;
}

interface GrantRow {
  id: string;
  client_org_id: string;
  securepath_user_id: string;
  reason: string;
  approved_by: string;
  starts_at: string;
  expires_at: string;
  revoked_at: string | null;
  state: 'active' | 'expired' | 'revoked';
}

const when = (d: string | null) =>
  d
    ? new Date(d).toLocaleString('en-GB', {
        day: 'numeric',
        month: 'short',
        hour: '2-digit',
        minute: '2-digit',
      })
    : '—';

export default async function SupportAccessPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();
  const client = ctx.client;

  // list_support_grants also sweeps lapsed pending requests to 'expired'
  const [{ data: grantData, error: gErr }, { data: reqData, error: rErr }] =
    await Promise.all([
      supabase.rpc('list_support_grants', { p_client_org_id: client.id }),
      supabase
        .from('support_access_requests')
        .select(
          'id, client_org_id, requested_by, reason, starts_at, expires_at, status, decided_by, decided_at, grant_id, created_at'
        )
        .eq('client_org_id', client.id)
        .order('created_at', { ascending: false })
        .limit(100),
    ]);

  const requests = (reqData ?? []) as RequestRow[];
  const grants = (grantData ?? []) as GrantRow[];
  const err = gErr ?? rErr;

  // Approver set — mirrors approve_support_grant's in-body guard exactly:
  // owning partner's partner_admin · active client-scope accountable_officer
  // · current information_officer designation holder. Decision authority is
  // symmetric for decline (decline_support_request, same guard).
  const role = ctx.role;
  const canDecide =
    role.assignments.some(
      (a) =>
        a.level === 'partner' &&
        a.role === 'partner_admin' &&
        a.scope_type === 'partner' &&
        a.scope_id === client.practice_id
    ) ||
    role.assignments.some(
      (a) =>
        a.level === 'client' &&
        a.role === 'accountable_officer' &&
        a.scope_type === 'client' &&
        a.scope_id === client.id
    ) ||
    role.designations.some(
      (d) => d.client_org_id === client.id && d.role === 'information_officer'
    );

  // Revoker set — revoke_support_grant: the approver set plus platform_admin
  // and the grant's own holder.
  const isPlatformAdmin = role.hasRole('platform', 'platform_admin');
  const canRevoke = (g: GrantRow) =>
    canDecide || isPlatformAdmin || g.securepath_user_id === role.userId;

  return (
    <>
      <PageHeader
        title="Support access"
        meta="SecurePath staff have no standing access to this client — every look needs your approval for a set window, and every request, grant and early end is listed here"
      />
      {err ? <Alert tone="err">{`Could not load support access: ${err.message}`}</Alert> : null}

      <div style={{ marginBottom: 16 }}>
        <Card title="Requests" pad={0}>
          {requests.length ? (
            <DataTable
              columns={[
                { label: 'Requested by' },
                { label: 'Reason' },
                { label: 'Window ends' },
                { label: 'State' },
                { label: 'Decided' },
                { label: '', align: 'right' },
              ]}
              rows={requests.map((r) => [
                <span key="b">SecurePath support</span>,
                <span key="r">{r.reason}</span>,
                <span key="e" className="muted">{when(r.expires_at)}</span>,
                <StatusPill
                  key="s"
                  status={r.status}
                  map={{ approved: 'pass', declined: 'fail', expired: 'neutral' }}
                />,
                <span key="d" className="muted">{when(r.decided_at)}</span>,
                r.status === 'pending' && canDecide ? (
                  <ApproveDecline key="a" requestId={r.id} />
                ) : (
                  <span key="a" />
                ),
              ])}
            />
          ) : (
            <EmptyState
              icon="key-round"
              message="No support requests for this client."
            />
          )}
        </Card>
      </div>

      <Card title="Grants" pad={0}>
        {grants.length ? (
          <DataTable
            columns={[
              { label: 'Holder' },
              { label: 'Reason' },
              { label: 'From' },
              { label: 'Until' },
              { label: 'State' },
              { label: '', align: 'right' },
            ]}
            rows={grants.map((g) => [
              <span key="h">
                SecurePath support
                {g.securepath_user_id === role.userId ? ' (you)' : ''}
              </span>,
              <span key="r">{g.reason}</span>,
              <span key="f" className="muted">{when(g.starts_at)}</span>,
              <span key="u" className="muted">
                {g.revoked_at ? `revoked ${when(g.revoked_at)}` : when(g.expires_at)}
              </span>,
              <StatusPill
                key="s"
                status={g.state}
                map={{ expired: 'neutral', revoked: 'fail' }}
              />,
              g.state === 'active' && canRevoke(g) ? (
                <RevokeGrant key="a" grantId={g.id} />
              ) : (
                <span key="a" />
              ),
            ])}
          />
        ) : (
          <EmptyState
            icon="shield"
            message="No grants yet. A grant appears here the moment a request is approved."
          />
        )}
      </Card>
      <p className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 8 }}>
        Approving opens read access for the stated window only — it ends at the expiry time or the moment it is
        revoked, whichever is first. Every request, approval, decline and revocation is written to the audit log.
      </p>
    </>
  );
}
