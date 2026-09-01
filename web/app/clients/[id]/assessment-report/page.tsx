import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import Workbench from './workbench';
import { PageHeader } from '@/components/ui/PageHeader';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';

export const dynamic = 'force-dynamic';

// The consultant-grade assessment report: a versioned client deliverable compiled from the
// whole pipeline (v1 gap assessment -> v2 post-documentation -> v3 reassessment). Cross-stage
// artifact — issued versions are immutable evidence; drafts are advisor-only (RLS).
export default async function AssessmentReport({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ framework?: string }> }) {
  const { id } = await params;
  const framework = (await searchParams).framework ?? 'popia';
  const qs = framework === 'popia' ? '' : `?framework=${framework}`;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs').select('id, name').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');

  const [{ data: membership }, { data: reports }, { data: sessions }] = await Promise.all([
    supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
    supabase.from('assessment_reports')
      .select('id, version, kind, title, approval_status, compiled_at, issued_at, issued_document_id, payload, overrides, updated_at')
      .eq('client_org_id', id).eq('framework_key', framework).order('version'),
    supabase.from('assessment_sessions').select('id, approval_status')
      .eq('client_org_id', id).eq('framework', framework).eq('approval_status', 'approved'),
  ]);

  const role = membership?.role ?? '';
  const isAdvisor = ['practice_owner', 'practice_consultant'].includes(role);
  // advisor-only: RLS hides non-issued reports from client roles, so a client_admin
  // can never load the approved row the issue flow needs — the RPC guard matches
  const canIssue = isAdvisor;

  const all = reports ?? [];
  // RLS already hides drafts from client roles; for advisors, split working vs archive
  const working = all.find(r => ['draft_ai', 'draft_human', 'approved'].includes(r.approval_status)) ?? null;
  const archive = all.filter(r => ['issued', 'superseded'].includes(r.approval_status)).reverse();

  return (
    <>
      <PageHeader
        title={`${client.name} — Assessment report`}
        back="Workspace"
        backHref={`/clients/${id}${qs}`}
        meta="The client deliverable: compiled from the assessment, gap map, policy suite and task board. v1 is the gap assessment at Gate 1; later versions add the post-documentation position. Issued versions are immutable evidence."
        actions={
          <>
            <Badge><span className="mono">{framework.toUpperCase()}</span></Badge>
            <Link href={`/assessments`}><Button variant="secondary" size="sm">Stage 1 — Assessments</Button></Link>
          </>
        }
      />
      <Workbench
        clientOrgId={id}
        framework={framework}
        isAdvisor={isAdvisor}
        canIssue={canIssue}
        hasSignedOffSession={(sessions ?? []).length > 0}
        working={working}
        archive={archive}
      />
    </>
  );
}
