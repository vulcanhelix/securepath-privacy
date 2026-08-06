import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';

export const dynamic = 'force-dynamic';

export default async function Assessments() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: membership } = await supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle();
  if (!membership) redirect('/onboarding');

  const { data: assessments } = await supabase
    .from('assessment_sessions')
    .select(`
      id, title, framework, status, score_pct, rating, created_at,
      client_orgs (name),
      assessment_scores (completion_pct, overall_score)
    `)
    .order('created_at', { ascending: false });

  const isOwner = membership.role === 'practice_owner';

  return (
    <>
      <div style={{ display: 'flex', alignItems: 'center' }}>
        <h1 style={{ flex: 1 }}>Assessments</h1>
        {isOwner && <Link href="/assessments/new"><button>+ New Assessment</button></Link>}
      </div>
      <div className="card">
        {assessments?.length ? (
          <table>
            <thead>
              <tr>
                <th>Title</th>
                <th>Client</th>
                <th>Framework</th>
                <th>Status</th>
                <th>Score</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody>
              {assessments.map((a: any) => (
                <tr key={a.id}>
                  <td>
                    <Link href={`/assessments/${a.id}`} style={{ fontWeight: 600 }}>
                      {a.title}
                    </Link>
                  </td>
                  <td>{a.client_orgs?.name ?? '—'}</td>
                  <td><span className="badge">{a.framework.toUpperCase()}</span></td>
                  <td><span className="badge">{a.status}</span></td>
                  <td>
                    {a.score_pct !== null ? (
                      <span style={{ color: getScoreColor(a.score_pct) }}>
                        {a.score_pct}%
                      </span>
                    ) : '—'}
                  </td>
                  <td className="muted">{new Date(a.created_at).toLocaleDateString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="muted">
            No assessments yet.{isOwner ? ' Create your first assessment to get started.' : ''}
          </p>
        )}
      </div>
    </>
  );
}

function getScoreColor(score: number): string {
  if (score >= 75) return 'var(--accent)';
  if (score >= 50) return '#d97706';
  return '#dc2626';
}