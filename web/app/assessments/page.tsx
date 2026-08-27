import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { DataTable } from '@/components/ui/DataTable';
import { Badge } from '@/components/ui/Badge';
import { EmptyState } from '@/components/ui/EmptyState';
import { Button } from '@/components/ui/Button';
import { scoreTone } from '@/components/ui/ScoreRing';

export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'neutral' | 'accent' | 'pass' | 'warn'> = {
  draft: 'neutral',
  in_progress: 'accent',
  completed: 'warn',
  signed_off: 'pass',
};

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
      <PageHeader
        title="Assessments"
        actions={isOwner ? <Link href="/assessments/new"><Button cta>New assessment</Button></Link> : null}
      />
      <Card pad={0}>
        {assessments?.length ? (
          <DataTable
            columns={[
              { label: 'Title' }, { label: 'Client' }, { label: 'Framework' },
              { label: 'Status' }, { label: 'Score', align: 'right' }, { label: 'Created', align: 'right' },
            ]}
            rows={assessments.map((a: any) => [
              <Link key="t" href={`/assessments/${a.id}`} style={{ fontWeight: 500, color: 'var(--text)' }}>
                {a.title}
              </Link>,
              a.client_orgs?.name ?? '—',
              <span key="f" className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{a.framework.toUpperCase()}</span>,
              <Badge key="s" tone={STATUS_TONE[a.status] ?? 'neutral'} dot>{a.status.replace(/_/g, ' ')}</Badge>,
              a.score_pct !== null ? (
                // numerals stay in --text; the dot carries the RAG colour
                <span key="p" style={{ display: 'inline-flex', alignItems: 'center', gap: 7, justifyContent: 'flex-end' }}>
                  <span className={`sp-dot sp-dot--${scoreTone(a.score_pct)}`}><span className="sp-dot-i" /></span>
                  <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--text)' }}>{a.score_pct}%</span>
                </span>
              ) : '—',
              <span key="c" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {new Date(a.created_at).toLocaleDateString()}
              </span>,
            ])}
          />
        ) : (
          <EmptyState
            icon="clipboard-check"
            message={`No assessments yet.${isOwner ? ' Create your first assessment to get started.' : ''}`}
            action={isOwner ? <Link href="/assessments/new"><Button>New assessment</Button></Link> : null}
          />
        )}
      </Card>
    </>
  );
}
