import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import AssessmentEditor from './AssessmentEditor';

export const dynamic = 'force-dynamic';

export default async function AssessmentDetail({ params }: { params: Promise<{ id: string }> }) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { id } = await params;

  const { data: assessment } = await supabase
    .from('assessment_sessions')
    .select('id, title, framework, status, score_pct, rating, org_name, auditor_name, audit_date, audit_ref, created_at, updated_at')
    .eq('id', id)
    .single();

  if (!assessment) {
    return <div className="card"><p>Assessment not found</p></div>;
  }

  return (
    <>
      <div style={{ display: 'flex', alignItems: 'center' }}>
        <Link href="/assessments" style={{ marginRight: '1rem'}}>← Back</Link>
        <h1 style={{ flex: 1 }}>{assessment.title}</h1>
        <Link href={`/assessments/${id}/chat`} className="button-link">Open conversation</Link>
      </div>

      <AssessmentEditor assessmentId={id} />
    </>
  );
}