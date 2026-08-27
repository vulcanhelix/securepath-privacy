import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { trackKindFor } from '@/lib/track';
import Builder from './builder';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';

export const dynamic = 'force-dynamic';

// Stage 4 — PIMS manual compilation (27701-aligned). Content-driven outline.
export default async function ClientManual(
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

  const [{ data: membership }, { data: outline }, { data: manual }, { data: track }] = await Promise.all([
    supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
    supabase.from('manual_outlines').select('chapter_key, title, clause_ref').eq('framework_key', framework).eq('active', true).order('sort'),
    supabase.from('manuals').select('id, title, body, approval_status, s51_published, version, updated_at')
      .eq('client_org_id', id).order('created_at', { ascending: false }).limit(1).maybeSingle(),
    supabase.from('tracks').select('id, current_stage').eq('client_org_id', id).eq('track_kind', trackKind).maybeSingle(),
  ]);

  const role = membership?.role ?? '';
  const isAdvisor = ['practice_owner', 'practice_consultant'].includes(role);
  const canSignOff = ['practice_owner', 'practice_consultant', 'client_admin'].includes(role);

  return (
    <>
      <PageHeader
        title={`${client.name} — PIMS manual`}
        back="Workspace"
        backHref={`/clients/${id}`}
        meta="Compile the Privacy Information Management System manual from the approved policies and registers, ISO/IEC 27701-aligned, then have the Information Officer sign it off and publish the PAIA s.51 manual."
        actions={
          <>
            <Badge><span className="mono">{framework.toUpperCase()}</span></Badge>
            <Badge tone={track?.current_stage === 4 ? 'accent' : 'neutral'} dot>Stage 4</Badge>
            <Link href={`/clients/${id}/tasks${qs}`}><Button variant="secondary" size="sm">Stage 5 — Implementation</Button></Link>
          </>
        }
      />

      <div style={{ display: 'grid', gridTemplateColumns: '300px 1fr', gap: 24, alignItems: 'start' }}>
        <Card title="Outline" pad={20} style={{ position: 'sticky', top: 24 }}>
          <ol style={{ margin: 0, paddingLeft: 20, display: 'flex', flexDirection: 'column', gap: 10 }}>
            {(outline ?? []).map(ch => (
              <li key={ch.chapter_key} style={{ fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
                {ch.title}
                {ch.clause_ref ? (
                  <span className="mono" style={{ display: 'block', fontSize: 'var(--fs-label)', color: 'var(--faint)' }}>
                    {ch.clause_ref}
                  </span>
                ) : null}
              </li>
            ))}
          </ol>
        </Card>

        <Builder clientOrgId={id} framework={framework} isAdvisor={isAdvisor} canSignOff={canSignOff} manual={manual ?? null} />
      </div>
    </>
  );
}
