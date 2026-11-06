import { serverClient } from '@/lib/supabase';
import type { PlatformClientRow } from '@/lib/platform';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';
import { StatusPill } from '@/components/ui/StatusPill';
import { RequestAccessForm } from './RequestAccessForm';

export const dynamic = 'force-dynamic';

// W2-14 — support-access panel (FR-PLT-04 / NFR-04). Platform support or
// admin REQUESTS time-boxed access to a client (request_support_access) and
// sees requests + grants with their state (support_access_requests under its
// RLS read policy; grants via list_support_grants, which also sweeps lapsed
// requests to expired). Approval is the CLIENT side's — the accountable
// officer or partner admin — never platform staff; the end-to-end approve /
// use / revoke flow is W4-01 (issue #48).

interface RequestRow {
  id: string;
  client_org_id: string;
  requested_by: string;
  reason: string;
  starts_at: string;
  expires_at: string;
  status: string;
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
  d ? new Date(d).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—';

export default async function SupportPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const sp = await searchParams;
  const preselect = typeof sp.client === 'string' ? sp.client : '';
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();

  // grants first: list_support_grants sweeps lapsed pending requests to expired
  const { data: grantData, error: gErr } = await supabase.rpc('list_support_grants', { p_client_org_id: null });
  const [{ data: clientData, error: cErr }, { data: reqData, error: rErr }] = await Promise.all([
    supabase.rpc('platform_list_clients', { p_partner: null }),
    supabase
      .from('support_access_requests')
      .select('id, client_org_id, requested_by, reason, starts_at, expires_at, status, decided_at, grant_id, created_at')
      .order('created_at', { ascending: false })
      .limit(200),
  ]);

  const clients = (clientData ?? []) as PlatformClientRow[];
  const grants = (grantData ?? []) as GrantRow[];
  const requests = (reqData ?? []) as RequestRow[];
  const clientName = new Map(clients.map((c) => [c.client_org_id, `${c.client_name} · ${c.partner_name}`]));
  const who = (id: string) => (id === user?.id ? 'you' : `${id.slice(0, 8)}…`);
  const err = gErr ?? cErr ?? rErr;

  return (
    <>
      <PageHeader
        title="Support access"
        meta="SecurePath has no standing access to client data — every look needs a client-approved, time-limited grant"
      />
      {err ? <Alert tone="err">{`Could not load support access: ${err.message}`}</Alert> : null}

      <div style={{ marginBottom: 16 }}>
        <Card title="Request access to a client">
          <RequestAccessForm clients={clients} preselect={preselect} />
        </Card>
      </div>

      <div style={{ marginBottom: 16 }}>
        <Card title="Requests" pad={0}>
          {requests.length ? (
            <DataTable
              columns={[
                { label: 'Client' },
                { label: 'Requested by' },
                { label: 'Reason' },
                { label: 'Window ends' },
                { label: 'State' },
                { label: 'Decided' },
              ]}
              rows={requests.map((r) => [
                <span key="c" style={{ fontWeight: 500 }}>{clientName.get(r.client_org_id) ?? r.client_org_id}</span>,
                <span key="b" className="muted">{who(r.requested_by)}</span>,
                <span key="r">{r.reason}</span>,
                <span key="e" className="muted">{when(r.expires_at)}</span>,
                <StatusPill key="s" status={r.status} map={{ approved: 'pass', declined: 'fail', expired: 'neutral' }} />,
                <span key="d" className="muted">{when(r.decided_at)}</span>,
              ])}
            />
          ) : (
            <EmptyState icon="key-round" message="No support requests yet." />
          )}
        </Card>
      </div>

      <Card title="Grants" pad={0}>
        {grants.length ? (
          <DataTable
            columns={[
              { label: 'Client' },
              { label: 'Holder' },
              { label: 'Reason' },
              { label: 'From' },
              { label: 'Until' },
              { label: 'State' },
            ]}
            rows={grants.map((g) => [
              <span key="c" style={{ fontWeight: 500 }}>{clientName.get(g.client_org_id) ?? g.client_org_id}</span>,
              <span key="h" className="muted">{who(g.securepath_user_id)}</span>,
              <span key="r">{g.reason}</span>,
              <span key="f" className="muted">{when(g.starts_at)}</span>,
              <span key="u" className="muted">{g.revoked_at ? `revoked ${when(g.revoked_at)}` : when(g.expires_at)}</span>,
              <StatusPill key="s" status={g.state} map={{ expired: 'neutral', revoked: 'fail' }} />,
            ])}
          />
        ) : (
          <EmptyState icon="shield" message="No grants yet. A grant appears once the client approves a request." />
        )}
      </Card>
      <p className="muted" style={{ fontSize: 'var(--fs-xs)', marginTop: 8 }}>
        The client&apos;s accountable officer or partner admin approves each request for a set period; access then
        works only inside that window and every action is logged and visible to the client. The approval screen,
        in-grant access and revocation land with W4-01 (#48).
      </p>
    </>
  );
}
