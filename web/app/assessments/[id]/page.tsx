import { redirect } from 'next/navigation';
import { PageHeader } from '@/components/ui/PageHeader';
import { serverClient } from '@/lib/supabase';
import AssessmentEditor from './AssessmentEditor';
import Gate1 from './gate1';

export const dynamic = 'force-dynamic';

export default async function AssessmentDetail({ params }: { params: Promise<{ id: string }> }) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { id } = await params;

  const { data: assessment } = await supabase
    .from('assessment_sessions')
    .select('id, title, framework, status, score_pct, rating, approval_status, client_org_id, created_at, updated_at')
    .eq('id', id)
    .single();

  if (!assessment) {
    return <div className="card"><p>Assessment not found</p></div>;
  }

  const [{ data: membership }, { data: track }] = await Promise.all([
    supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
    supabase.from('tracks').select('current_stage')
      .eq('client_org_id', assessment.client_org_id).eq('track_kind', 'privacy').maybeSingle(),
  ]);
  const isAdvisor = membership?.role === 'practice_owner' || membership?.role === 'practice_consultant';

  return (
    <>
      <PageHeader title={assessment.title} back="Assessments" backHref="/assessments" />

      <Gate1
        sessionId={id}
        clientOrgId={assessment.client_org_id}
        approved={assessment.approval_status === 'approved'}
        stage={track?.current_stage ?? null}
        isAdvisor={isAdvisor}
      />

      <AssessmentEditor assessmentId={id} />
    </>
  );
}