import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import MarkRead from './mark-read';

export const dynamic = 'force-dynamic';

export default async function Notifications() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: items } = await supabase
    .from('notifications').select('id, at, kind, message, read')
    .order('at', { ascending: false }).limit(100);

  return (
    <>
      <h1>Notifications</h1>
      <div className="card">
        {items?.length ? (
          <table>
            <tbody>
              {items.map(n => (
                <tr key={n.id} style={n.read ? { opacity: .55 } : undefined}>
                  <td><span className="badge">{n.kind}</span></td>
                  <td>{n.message}</td>
                  <td className="muted">{new Date(n.at).toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <p className="muted">Nothing yet.</p>}
        {items?.some(n => !n.read) && <MarkRead />}
      </div>
    </>
  );
}
