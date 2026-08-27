import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import InviteForm from './invite-form';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { DataTable } from '@/components/ui/DataTable';
import { Badge } from '@/components/ui/Badge';

export const dynamic = 'force-dynamic';

const ROLE_LABEL: Record<string, string> = {
  practice_owner: 'Owner',
  practice_consultant: 'Consultant',
  client_admin: 'Client admin',
  client_contributor: 'Client contributor',
  read_only: 'Read only',
};

export default async function Team() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: members } = await supabase
    .from('memberships').select('user_id, role, users(email, full_name)');
  const { data: invites } = await supabase
    .from('invites').select('email, role, created_at, accepted_at, expires_at')
    .is('accepted_at', null).gt('expires_at', new Date().toISOString());

  const seatRoles = ['practice_consultant', 'read_only'];
  const seatsUsed =
    (members?.filter(m => seatRoles.includes(m.role)).length ?? 0) +
    (invites?.filter(i => seatRoles.includes(i.role)).length ?? 0);

  return (
    <>
      <PageHeader title="Team" meta={`${seatsUsed}/5 team seats used — consultants, read-only and pending invites count; client-side users don't.`} />
      <Card title="Members" pad={0}>
        <DataTable
          columns={[{ label: 'Email' }, { label: 'Role' }]}
          rows={(members ?? []).map((m) => [
            (m.users as any)?.email ?? m.user_id,
            <Badge key="r" tone={m.role === 'practice_owner' ? 'ink' : 'neutral'}>{ROLE_LABEL[m.role] ?? m.role}</Badge>,
          ])}
        />
      </Card>
      <Card title="Pending invites" pad={invites?.length ? 0 : 28} style={{ marginTop: 24 }}>
        {invites?.length ? (
          <DataTable
            columns={[{ label: 'Email' }, { label: 'Role' }, { label: 'Expires' }]}
            rows={invites.map((i) => [
              i.email,
              <Badge key="r">{ROLE_LABEL[i.role] ?? i.role}</Badge>,
              <span key="e" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {new Date(i.expires_at).toLocaleDateString()}
              </span>,
            ])}
          />
        ) : (
          <p className="muted" style={{ margin: 0 }}>None.</p>
        )}
      </Card>
      <Card title="Invite a team member" style={{ marginTop: 24 }}>
        <InviteForm />
      </Card>
    </>
  );
}
