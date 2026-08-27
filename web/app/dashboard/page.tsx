import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';
import { Button } from '@/components/ui/Button';
import { StagePips } from '@/components/ui/StageRail';

export const dynamic = 'force-dynamic';

export default async function Dashboard() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: membership } = await supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle();
  if (!membership) redirect('/onboarding');

  const [{ data: clients }, { data: tracks }] = await Promise.all([
    supabase
      .from('client_orgs')
      .select('id, name, industry, contact_name, contact_email, org_scale, created_at')
      .order('created_at', { ascending: false }),
    supabase.from('tracks').select('client_org_id, track_kind, current_stage').eq('track_kind', 'privacy'),
  ]);
  const stageOf = (cid: string) => tracks?.find((t) => t.client_org_id === cid)?.current_stage ?? 0;
  const scaleLabel = (s: string | null) => (s === 'sme' ? 'SME' : s === 'large' ? 'Large' : '—');

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
            columns={[{ label: 'Name' }, { label: 'Pipeline' }, { label: 'Scale' }, { label: 'Industry' }, { label: 'Contact' }, { label: 'Created', align: 'right' }]}
            rows={clients.map((c) => [
              <Link key="n" href={`/clients/${c.id}`} style={{ fontWeight: 500, color: 'var(--text)' }}>
                {c.name}
              </Link>,
              <Link key="p" href={`/clients/${c.id}`} style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                <StagePips stage={stageOf(c.id)} />
                <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>S{stageOf(c.id)}</span>
              </Link>,
              scaleLabel(c.org_scale),
              c.industry ?? '—',
              <span key="c">
                {c.contact_name ?? '—'} <span className="muted">{c.contact_email ?? ''}</span>
              </span>,
              <span key="d" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {new Date(c.created_at).toLocaleDateString()}
              </span>,
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
