import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import MarkRead from './mark-read';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { DataTable } from '@/components/ui/DataTable';
import { Badge } from '@/components/ui/Badge';
import { EmptyState } from '@/components/ui/EmptyState';

export const dynamic = 'force-dynamic';

export default async function Notifications() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: items } = await supabase
    .from('notifications').select('id, at, kind, message, read')
    .order('at', { ascending: false }).limit(100);

  const hasUnread = items?.some((n) => !n.read);

  return (
    <>
      <PageHeader title="Notifications" actions={hasUnread ? <MarkRead /> : null} />
      <Card pad={0}>
        {items?.length ? (
          <DataTable
            columns={[{ label: '' }, { label: 'Kind' }, { label: 'Message' }, { label: 'When', align: 'right' }]}
            rows={items.map((n) => [
              n.read ? '' : <span key="u" className="sp-dot sp-dot--fail"><span className="sp-dot-i" /></span>,
              <Badge key="k" tone={n.read ? 'neutral' : 'accent'}>{n.kind}</Badge>,
              <span key="m" style={n.read ? { opacity: 0.55 } : undefined}>{n.message}</span>,
              <span key="t" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {new Date(n.at).toLocaleString()}
              </span>,
            ])}
          />
        ) : (
          <EmptyState icon="bell" message="Nothing yet." />
        )}
      </Card>
    </>
  );
}
