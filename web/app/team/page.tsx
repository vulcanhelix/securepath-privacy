import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import InviteForm from './invite-form';

export const dynamic = 'force-dynamic';

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
      <h1>Team</h1>
      <div className="card">
        <h2>Members</h2>
        <table>
          <thead><tr><th>Email</th><th>Role</th></tr></thead>
          <tbody>
            {members?.map(m => (
              <tr key={m.user_id}>
                <td>{(m.users as any)?.email ?? m.user_id}</td>
                <td><span className="badge">{m.role}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="card">
        <h2>Pending invites</h2>
        {invites?.length
          ? <table><thead><tr><th>Email</th><th>Role</th><th>Expires</th></tr></thead><tbody>
              {invites.map((i, k) => (
                <tr key={k}><td>{i.email}</td><td><span className="badge">{i.role}</span></td>
                  <td className="muted">{new Date(i.expires_at).toLocaleDateString()}</td></tr>
              ))}
            </tbody></table>
          : <p className="muted">None.</p>}
      </div>
      <div className="card">
        <h2>Invite a team member</h2>
        <p className="muted">{seatsUsed}/5 team seats used (client-side users don&apos;t count).</p>
        <InviteForm />
      </div>
    </>
  );
}
