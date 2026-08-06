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
    .select('*')
    .eq('id', id)
    .single();

  if (!assessment) {
    return <div className="card"><p>Assessment not found</p></div>;
  }

  const { data: membership } = await supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle();
  const isOwner = membership?.role === 'practice_owner';

  return (
    <>
      <div style={{ display: 'flex', alignItems: 'center' }}>
        <Link href="/assessments" style={{ marginRight: '1rem'}}>← Back</Link>
        <h1 style={{ flex: 1 }}>{assessment.title}</h1>
        {isOwner && (
          <button 
            onClick={() => {
              // TODO: Implement delete functionality
              alert('Delete functionality coming soon');
            }}
            style={{ background: '#dc2626' }}
          >
            Delete
          </button>
        )}
      </div>
      
      <div className="card" style={{ marginBottom: '1rem' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '1rem' }}>
          <div>
            <label>Framework</label>
            <span className="badge">{assessment.framework.toUpperCase()}</span>
          </div>
          <div>
            <label>Status</label>
            <span className="badge">{assessment.status}</span>
          </div>
          <div>
            <label>Score</label>
            {assessment.score_pct !== null ? (
              <span style={{ fontSize: '1.5rem', fontWeight: 700, color: getScoreColor(assessment.score_pct) }}>
                {assessment.score_pct}%
              </span>
            ) : '—'}
          </div>
          <div>
            <label>Rating</label>
            <strong>{assessment.rating || 'In Progress'}</strong>
          </div>
        </div>
      </div>

      <AssessmentEditor assessmentId={id} />
    </>
  );
}

function getScoreColor(score: number): string {
  if (score >= 75) return 'var(--accent)';
  if (score >= 50) return '#d97706';
  return '#dc2626';
}