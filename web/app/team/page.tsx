import Link from 'next/link';
import type { ReactNode } from 'react';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { getRoleContext } from '@/lib/role-context';
import InviteForm from './invite-form';
import { RemoveMember, RevokeInvite, AssignClient, UnassignClient } from './member-actions';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { DataTable } from '@/components/ui/DataTable';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';
import {
  SEAT_CAP, pct, usageBadgeTone, licenceWarningText,
  type OwnUsageRow, type LicenceUsageRow, type LicenceWarningEvent,
} from '@/lib/licence';

export const dynamic = 'force-dynamic';

// ---------------------------------------------------------------------------
// W2-17 — partner team management (spec §7.6 FR-TEAM-01/02) + the compact
// FR-LIC-01 licence tile. All reads run under the caller's JWT: the
// role_assignments / invites / licences / notification_events RLS policies and
// the usage RPCs decide what each role sees. All writes are the
// 20261106000028 RPCs + W2-14's create_invite (never owner/admin roles).
//
// partner_admin  → full screen: members, pending invites, invite form,
//                  seat usage, licence usage.
// partner_consultant (partner-scope) → read-only team list + usage tile.
// client-scope-only partner rows     → own row only (RLS decides).
// ---------------------------------------------------------------------------

const ROLE_LABEL: Record<string, string> = {
  partner_admin: 'Partner admin',
  partner_consultant: 'Consultant',
  read_only: 'Read only',
  client_admin: 'Client admin',
  client_contributor: 'Client contributor',
  executive: 'Executive',
  accountable_officer: 'Accountable officer',
  programme_lead: 'Programme lead',
  workstream_lead: 'Workstream lead',
  external_provider: 'External provider',
  assessor: 'Assessor',
};
const INVITE_ROLE_LABEL: Record<string, string> = {
  practice_consultant: 'Consultant',
  read_only: 'Read only',
  client_admin: 'Client admin',
  client_contributor: 'Client contributor',
};
const SEAT_ROLES = ['partner_consultant', 'read_only'];
const SEAT_INVITE_ROLES = ['practice_consultant', 'read_only'];

interface AssignmentRow {
  user_id: string;
  level: string;
  role: string;
  scope_type: string;
  scope_id: string | null;
  start_date: string;
  end_date: string | null;
}

export default async function Team() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');
  const role = await getRoleContext(supabase);
  if (!role) redirect('/login');

  const isAdmin = role.hasRole('partner', 'partner_admin');
  const today = new Date().toISOString().slice(0, 10);

  // the partner this page manages: caller's partner scope, else the practice
  // behind their visible clients (client-scope-only consultants)
  const [{ data: clients }, { data: assignments }, { data: users }, { data: invites },
         { data: programmes }, { data: workstreams }, { data: warnings }] = await Promise.all([
    supabase.from('client_orgs').select('id, name, practice_id').order('name'),
    supabase
      .from('role_assignments')
      .select('user_id, level, role, scope_type, scope_id, start_date, end_date')
      .in('level', ['partner', 'client'])
      .or(`end_date.is.null,end_date.gt.${today}`)
      .order('user_id'),
    supabase.from('users').select('id, email, full_name'),
    supabase
      .from('invites').select('token, email, role, client_org_id, created_at, expires_at')
      .is('accepted_at', null).gt('expires_at', new Date().toISOString()),
    supabase.from('programmes').select('id, name'),
    supabase.from('workstreams').select('id, name'),
    supabase
      .from('notification_events').select('created_at, payload')
      .eq('kind', 'licence_warning')
      .order('created_at', { ascending: false }).limit(5),
  ]);

  const clientList = (clients ?? []) as { id: string; name: string; practice_id: string }[];
  const partnerId = role.partnerIds[0] ?? clientList[0]?.practice_id ?? null;
  const clientName = new Map(clientList.map((c) => [c.id, c.name]));
  const programmeName = new Map((programmes ?? []).map((p: any) => [p.id, p.name]));
  const workstreamName = new Map((workstreams ?? []).map((w: any) => [w.id, w.name]));
  const userInfo = new Map((users ?? []).map((u: any) => [u.id, { email: u.email, name: u.full_name }]));

  // licence usage: admins get the full FR-LIC-01 row; other partner roles get
  // the §9.8 counters (the RPC refuses client-scope-only callers — then the
  // tile simply doesn't render)
  let usage: OwnUsageRow | null = null;
  let lu: LicenceUsageRow | null = null;
  if (partnerId) {
    if (isAdmin) {
      const { data } = await supabase.rpc('usage_report', { p_partner: partnerId });
      usage = (data?.[0] ?? null) as OwnUsageRow | null;
    }
    if (!usage) {
      const { data } = await supabase.rpc('partner_licence_usage', { p_partner: partnerId });
      lu = (data?.[0] ?? null) as LicenceUsageRow | null;
    }
  }
  const clientsUsed = usage?.clients_used ?? lu?.clients_used ?? null;
  const clientLimit = usage?.client_limit ?? lu?.client_limit ?? null;
  const programmesUsed = usage?.programmes_used ?? lu?.programmes_used ?? null;
  const programmeLimit = usage?.programme_limit ?? lu?.programme_limit ?? null;
  const overClient = lu?.over_client_limit ?? false;
  const overProg = lu?.over_programme_limit ?? false;
  const licenceWarns = (warnings ?? []) as LicenceWarningEvent[];

  // group the live assignment rows per member
  const members = new Map<string, AssignmentRow[]>();
  for (const a of (assignments ?? []) as AssignmentRow[]) {
    const rows = members.get(a.user_id) ?? [];
    rows.push(a);
    members.set(a.user_id, rows);
  }

  const scopeLabel = (a: AssignmentRow) =>
    a.scope_type === 'partner' ? 'Partner-wide'
    : a.scope_type === 'client' ? clientName.get(a.scope_id ?? '') ?? 'Client'
    : a.scope_type === 'programme' ? programmeName.get(a.scope_id ?? '') ?? 'Programme'
    : workstreamName.get(a.scope_id ?? '') ?? 'Workstream';

  // the 5-seat rule: partner-scope consultants + read_only + pending seat invites
  const seatUsers = new Set(
    ((assignments ?? []) as AssignmentRow[])
      .filter((a) => a.level === 'partner' && a.scope_type === 'partner' && SEAT_ROLES.includes(a.role))
      .map((a) => a.user_id),
  );
  const pendingInvites = (invites ?? []) as {
    token: string; email: string; role: string; client_org_id: string | null;
    created_at: string; expires_at: string;
  }[];
  const seatsUsed = seatUsers.size + pendingInvites.filter((i) => SEAT_INVITE_ROLES.includes(i.role)).length;

  const memberRows = [...members.entries()]
    .sort(([a], [b]) => {
      const ea = userInfo.get(a)?.email ?? a;
      const eb = userInfo.get(b)?.email ?? b;
      return ea.localeCompare(eb);
    });

  const capCell = (used: number | null, limit: number | null, over: boolean) => (
    <span className="mono" style={{ color: usageBadgeTone(used ?? 0, limit, over) === 'pass' ? undefined : `var(--${usageBadgeTone(used ?? 0, limit, over)})` }}>
      {used ?? 0} / {limit == null ? '∞' : limit}
      {pct(used ?? 0, limit) != null ? ` · ${pct(used ?? 0, limit)}%` : ''}
    </span>
  );

  return (
    <>
      <PageHeader
        title="Team & licence"
        meta="Your people, their access, and how much of the licence you're using."
      />

      {!partnerId ? (
        <Alert tone="info">Team management is a partner screen — no partner workspace is visible to your account.</Alert>
      ) : null}

      {/* ---- licence + seats headline tiles ---- */}
      {partnerId && (usage || lu) ? (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 16, marginBottom: 24 }}>
          <Card title="Licence">
            <div style={{ display: 'grid', gap: 6 }}>
              {usage ? (
                <div>
                  <Badge tone={usage.licence_status === 'active' ? 'pass' : 'warn'}>{usage.licence_status ?? 'none'}</Badge>{' '}
                  <strong>{usage.plan ?? 'No active licence'}</strong>
                </div>
              ) : null}
              <div>Clients: {capCell(clientsUsed, clientLimit, overClient)}</div>
              <div>Programmes: {capCell(programmesUsed, programmeLimit, overProg)}</div>
              {usage ? <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Active users: {usage.active_users}</div> : null}
              {licenceWarns.length ? (
                <Alert tone="info"><Badge tone="warn">licence warning</Badge> {licenceWarningText(licenceWarns[0])} — SecurePath has been notified.</Alert>
              ) : null}
              {isAdmin ? (
                <Link href="/licences" style={{ fontSize: 'var(--fs-xs)' }}>Licence detail →</Link>
              ) : null}
            </div>
          </Card>
          {isAdmin ? (
            <Card title="Team seats">
              <div style={{ fontSize: 'var(--fs-2xl, 28px)', fontWeight: 600 }} className="mono">
                {seatsUsed} / {SEAT_CAP}
              </div>
              <p className="muted" style={{ margin: '6px 0 0', fontSize: 'var(--fs-xs)' }}>
                Consultants, read-only members and their pending invites count. Admins and client-side users don't.
              </p>
              {seatsUsed >= 4 ? (
                <Alert tone={seatsUsed >= SEAT_CAP ? 'err' : 'info'}>
                  {seatsUsed >= SEAT_CAP ? 'Seat limit reached — remove someone or an invite before inviting again.' : 'Nearly at the seat limit.'}
                </Alert>
              ) : null}
            </Card>
          ) : null}
        </div>
      ) : null}

      {/* ---- members ---- */}
      <Card title="Members" pad={0}>
        {memberRows.length ? (
          <DataTable
            columns={[
              { label: 'Member' },
              { label: 'Roles & scope' },
              { label: 'Status' },
              ...(isAdmin ? [{ label: '' }] : []),
            ]}
            rows={memberRows.map(([uid, rows]) => {
              const info = userInfo.get(uid);
              const isConsultant = rows.some((r) => r.level === 'partner' && r.role === 'partner_consultant');
              const cells: ReactNode[] = [
                <div key="m">
                  <div style={{ fontWeight: 500 }}>{info?.name ?? '—'}{uid === user.id ? ' (you)' : ''}</div>
                  <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{info?.email ?? uid.slice(0, 8)}</div>
                </div>,
                <div key="r" style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                  {rows.map((a, i) => (
                    <Badge key={i} tone={a.role === 'partner_admin' ? 'ink' : 'neutral'}>
                      {ROLE_LABEL[a.role] ?? a.role} · {scopeLabel(a)}
                      {isAdmin && a.level === 'partner' && a.role === 'partner_consultant' && a.scope_type === 'client' && a.scope_id ? (
                        <UnassignClient userId={uid} clientOrgId={a.scope_id} />
                      ) : null}
                    </Badge>
                  ))}
                </div>,
                <span key="s">
                  {rows.some((a) => a.end_date) ? (
                    <Badge tone="warn">ends {new Date(rows.find((a) => a.end_date)!.end_date!).toLocaleDateString()}</Badge>
                  ) : (
                    <Badge tone="pass">Active</Badge>
                  )}
                </span>,
              ];
              if (isAdmin) {
                cells.push(
                  <span key="a" style={{ display: 'inline-flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                    {isConsultant ? (
                      <AssignClient
                        userId={uid}
                        clients={clientList.filter(
                          (c) => !rows.some((a) => a.scope_type === 'client' && a.scope_id === c.id),
                        )}
                      />
                    ) : null}
                    {uid !== user.id ? <RemoveMember userId={uid} name={info?.email ?? 'this user'} /> : null}
                  </span>,
                );
              }
              return cells;
            })}
          />
        ) : (
          <EmptyState icon="users" message="No team members visible." />
        )}
      </Card>

      {/* ---- pending invites ---- */}
      <Card title="Pending invites" pad={pendingInvites.length ? 0 : 28} style={{ marginTop: 24 }}>
        {pendingInvites.length ? (
          <DataTable
            columns={[
              { label: 'Email' },
              { label: 'Role' },
              { label: 'Client' },
              { label: 'Expires' },
              ...(isAdmin ? [{ label: '' }] : []),
            ]}
            rows={pendingInvites.map((i) => {
              const cells: ReactNode[] = [
                i.email,
                <Badge key="r">{INVITE_ROLE_LABEL[i.role] ?? i.role}</Badge>,
                <span key="c" className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                  {i.client_org_id ? clientName.get(i.client_org_id) ?? 'client' : '—'}
                </span>,
                <span key="e" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                  {new Date(i.expires_at).toLocaleDateString()}
                </span>,
              ];
              if (isAdmin) cells.push(<RevokeInvite key="x" token={i.token} />);
              return cells;
            })}
          />
        ) : (
          <p className="muted" style={{ margin: 0 }}>None.</p>
        )}
      </Card>

      {/* ---- invite (partner_admin only; create_invite is the real gate) ---- */}
      {isAdmin ? (
        <Card title="Invite a team member" style={{ marginTop: 24 }}>
          <InviteForm clients={clientList} />
        </Card>
      ) : null}
    </>
  );
}
