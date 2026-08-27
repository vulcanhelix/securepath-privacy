import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { trackKindFor } from '@/lib/track';
import Board from './board';
import { PageHeader } from '@/components/ui/PageHeader';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';

export const dynamic = 'force-dynamic';

// Stage 5 — Implementation board. Remediation tasks from the content task library.
export default async function ClientTasks(
  { params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ framework?: string }> }) {
  const { id } = await params;
  const framework = (await searchParams).framework ?? 'popia';
  const qs = framework === 'popia' ? '' : `?framework=${framework}`;
  const supabase = await serverClient();
  const trackKind = await trackKindFor(supabase, framework);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs').select('id, name').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');

  const [{ data: membership }, { data: tasks }, { data: track }] = await Promise.all([
    supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
    supabase.from('tasks').select('id, theme, title, description, responsible, output, priority, owner, due_date, status')
      .eq('client_org_id', id).order('theme'),
    supabase.from('tracks').select('id, current_stage').eq('client_org_id', id).eq('track_kind', trackKind).maybeSingle(),
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
      <PageHeader
        title={`${client.name} — Implementation board`}
        back="Workspace"
        backHref={`/clients/${id}`}
        meta="Work the remediation plan against the Stage 1 baseline. Gate 4 opens once all critical and high items are done."
        actions={
          <>
            <Badge><span className="mono">{framework.toUpperCase()}</span></Badge>
            <Badge tone={track?.current_stage === 5 ? 'accent' : 'neutral'} dot>Stage 5</Badge>
            <Link href={`/clients/${id}/report`}><Button variant="secondary" size="sm">Stage 6 — Report</Button></Link>
          </>
        }
      />

      <Board
        clientOrgId={id} framework={framework} isAdvisor={isAdvisor} canEdit={canEdit}
        tasks={all} trackId={track?.id ?? null} trackStage={track?.current_stage ?? null}
        progress={{ done, total: all.length, critHigh: critHigh.length, critHighDone }}
        gate4Ready={gate4Ready}
      />
    </>
  );
}
