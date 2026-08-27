import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';
import { Button } from '@/components/ui/Button';

export const dynamic = 'force-dynamic';

export default async function Dashboard() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: membership } = await supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle();
  if (!membership) redirect('/onboarding');

  const { data: clients } = await supabase
    .from('client_orgs')
    .select('id, name, industry, contact_name, contact_email, created_at')
    .order('created_at', { ascending: false });

  const isOwner = membership.role === 'practice_owner';

  return (
    <>
      <PageHeader
        title="Clients"
        meta={`${clients?.length ?? 0} client instance${clients?.length === 1 ? '' : 's'}`}
        actions={
          isOwner ? (
            <Link href="/clients/new">
              <Button cta>New client instance</Button>
            </Link>
          ) : null
        }
      />
      <Card pad={0}>
        {clients?.length ? (
          <DataTable
            columns={[{ label: 'Name' }, { label: 'Industry' }, { label: 'Contact' }, { label: 'Created' }, { label: '' }]}
            rows={clients.map((c) => [
              <Link key="n" href={`/clients/${c.id}/documents`} style={{ fontWeight: 500, color: 'var(--text)' }}>
                {c.name}
              </Link>,
              c.industry ?? '—',
              <span key="c">
                {c.contact_name ?? '—'} <span className="muted">{c.contact_email ?? ''}</span>
              </span>,
              <span key="d" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {new Date(c.created_at).toLocaleDateString()}
              </span>,
              <Link key="l" href={`/clients/${c.id}/documents`} style={{ color: 'var(--muted)' }}>
                Documents &rarr;
              </Link>,
            ])}
          />
        ) : (
          <EmptyState
            icon="building-2"
            message={`No client instances yet.${isOwner ? ' Create your first one — each instance is billable.' : ''}`}
            action={
              isOwner ? (
                <Link href="/clients/new">
                  <Button>New client instance</Button>
                </Link>
              ) : null
            }
          />
        )}
      </Card>
    </>
  );
}
