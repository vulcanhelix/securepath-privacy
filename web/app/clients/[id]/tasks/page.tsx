import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import Board from './board';

export const dynamic = 'force-dynamic';

// Stage 5 — Implementation board. Remediation tasks from the content task library.
export default async function ClientTasks({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs').select('id, name').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');

  const [{ data: membership }, { data: tasks }, { data: track }] = await Promise.all([
    supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
    supabase.from('tasks').select('id, theme, title, description, responsible, output, priority, owner, due_date, status')
      .eq('client_org_id', id).order('theme'),
    supabase.from('tracks').select('id, current_stage').eq('client_org_id', id).eq('track_kind', 'privacy').maybeSingle(),
  ]);

  const role = membership?.role ?? '';
  const isAdvisor = ['practice_owner', 'practice_consultant'].includes(role);
  const canEdit = role !== 'read_only' && role !== '';

  const all = tasks ?? [];
  const done = all.filter(t => t.status === 'done').length;
  const critHigh = all.filter(t => ['critical', 'high'].includes(t.priority));
  const critHighDone = critHigh.filter(t => t.status === 'done').length;
  const gate4Ready = all.length > 0 && critHigh.length > 0 && critHighDone === critHigh.length;

  return (
    <>
      <p className="muted"><Link href="/dashboard">← Clients</Link> · <Link href={`/clients/${id}/manual`}>Stage 4 — Manual</Link> · <Link href={`/clients/${id}/report`}>Stage 6 — Monthly report →</Link></p>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '.75rem' }}>
        <h1 style={{ flex: 1 }}>{client.name} — Implementation board</h1>
        <span className="badge">Stage 5{track ? ` · track stage ${track.current_stage}` : ''}</span>
      </div>
      <p className="muted">Work the remediation plan against the Stage 1 baseline. Gate 4 opens once all critical and high items are done.</p>

      <Board
        clientOrgId={id} isAdvisor={isAdvisor} canEdit={canEdit}
        tasks={all} trackId={track?.id ?? null} trackStage={track?.current_stage ?? null}
        progress={{ done, total: all.length, critHigh: critHigh.length, critHighDone }}
        gate4Ready={gate4Ready}
      />
    </>
  );
}
