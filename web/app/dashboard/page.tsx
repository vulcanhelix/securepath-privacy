import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';

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
      <div style={{ display: 'flex', alignItems: 'center' }}>
        <h1 style={{ flex: 1 }}>Client instances</h1>
        {isOwner && <Link href="/clients/new"><button>+ New client instance</button></Link>}
      </div>
      <div className="card">
        {clients?.length ? (
          <table>
            <thead><tr><th>Name</th><th>Industry</th><th>Contact</th><th>Created</th><th></th></tr></thead>
            <tbody>
              {clients.map(c => (
                <tr key={c.id}>
                  <td><strong>{c.name}</strong></td>
                  <td>{c.industry ?? '—'}</td>
                  <td>{c.contact_name ?? '—'} <span className="muted">{c.contact_email ?? ''}</span></td>
                  <td className="muted">{new Date(c.created_at).toLocaleDateString()}</td>
                  <td><Link href={`/clients/${c.id}/documents`}>Documents →</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="muted">No client instances yet.{isOwner ? ' Create your first one — each instance is billable.' : ''}</p>
        )}
      </div>
    </>
  );
}
