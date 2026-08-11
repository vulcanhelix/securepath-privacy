import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import Builder from './builder';

export const dynamic = 'force-dynamic';

// Stage 4 — PIMS manual compilation (27701-aligned). Content-driven outline.
export default async function ClientManual({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs').select('id, name').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');

  const [{ data: membership }, { data: outline }, { data: manual }, { data: track }] = await Promise.all([
    supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
    supabase.from('manual_outlines').select('chapter_key, title, clause_ref').eq('framework_key', 'popia').eq('active', true).order('sort'),
    supabase.from('manuals').select('id, title, body, approval_status, s51_published, version, updated_at')
      .eq('client_org_id', id).order('created_at', { ascending: false }).limit(1).maybeSingle(),
    supabase.from('tracks').select('id, current_stage').eq('client_org_id', id).eq('track_kind', 'privacy').maybeSingle(),
  ]);

  const role = membership?.role ?? '';
  const isAdvisor = ['practice_owner', 'practice_consultant'].includes(role);
  const canSignOff = ['practice_owner', 'practice_consultant', 'client_admin'].includes(role);

  return (
    <>
      <p className="muted"><Link href="/dashboard">← Clients</Link> · <Link href={`/clients/${id}/policies`}>Stage 3 — Policies</Link></p>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '.75rem' }}>
        <h1 style={{ flex: 1 }}>{client.name} — PIMS manual</h1>
        <span className="badge">Stage 4{track ? ` · track stage ${track.current_stage}` : ''}</span>
      </div>
      <p className="muted">Compile the Privacy Information Management System manual from the approved policies and registers, ISO/IEC 27701-aligned, then have the Information Officer sign it off and publish the PAIA s.51 manual.</p>

      <div className="card">
        <h2>Manual outline</h2>
        <ol style={{ margin: 0 }}>
          {(outline ?? []).map(ch => (
            <li key={ch.chapter_key}>{ch.title} {ch.clause_ref ? <span className="muted">· {ch.clause_ref}</span> : null}</li>
          ))}
        </ol>
      </div>

      <Builder clientOrgId={id} isAdvisor={isAdvisor} canSignOff={canSignOff} manual={manual ?? null} />
    </>
  );
}
