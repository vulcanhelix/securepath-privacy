import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import Studio from './studio';

export const dynamic = 'force-dynamic';

// Stage 6 — Monthly report studio. Movement against the Stage 1 baseline.
export default async function ClientReport({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs').select('id, name').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');

  const [{ data: membership }, { data: reports }, { data: track }] = await Promise.all([
    supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
    supabase.from('monthly_reports').select('id, period, title, body, approval_status, baseline_pct, tasks_done, tasks_total, updated_at')
      .eq('client_org_id', id).order('period', { ascending: false }),
    supabase.from('tracks').select('current_stage').eq('client_org_id', id).eq('track_kind', 'privacy').maybeSingle(),
  ]);

  const role = membership?.role ?? '';
  const isAdvisor = ['practice_owner', 'practice_consultant'].includes(role);
  const canIssue = ['practice_owner', 'practice_consultant', 'client_admin'].includes(role);

  const all = reports ?? [];
  const draft = all.find(r => r.approval_status === 'draft_ai' || r.approval_status === 'draft_human') ?? null;
  const issued = all.filter(r => r.approval_status === 'issued');

  return (
    <>
      <p className="muted"><Link href="/dashboard">← Clients</Link> · <Link href={`/clients/${id}/tasks`}>Stage 5 — Implementation</Link></p>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '.75rem' }}>
        <h1 style={{ flex: 1 }}>{client.name} — Monthly report studio</h1>
        <span className="badge">Stage 6{track ? ` · track stage ${track.current_stage}` : ''}</span>
      </div>
      <p className="muted">The managed-service steady state. Each period, compile a report showing movement against the Stage 1 baseline, then approve and issue it to an immutable archive.</p>

      <Studio clientOrgId={id} isAdvisor={isAdvisor} canIssue={canIssue} draft={draft} issued={issued} />
    </>
  );
}
