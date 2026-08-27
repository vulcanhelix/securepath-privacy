import { redirect } from 'next/navigation';
import type { ComponentProps } from 'react';
import { serverClient } from '@/lib/supabase';
import CohortActions from './CohortActions';
import { PageHeader } from '@/components/ui/PageHeader';
import { Badge } from '@/components/ui/Badge';
import { Card } from '@/components/ui/Card';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';
import Link from 'next/link';

export const dynamic = 'force-dynamic';

// Awareness interview programme — people risk (advisor-conducted, per-department cohorts).
// Raw interview data is advisor-only at RLS; reports consume the anonymised aggregate.
export default async function Awareness({ params, searchParams }:
  { params: Promise<{ id: string }>; searchParams: Promise<{ framework?: string }> }) {
  const { id } = await params;
  const framework = (await searchParams).framework ?? 'popia';
  const qs = framework === 'popia' ? '' : '?framework=' + framework;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs')
    .select('id, name, awareness_departments_planned').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');

  const [{ data: membership }, { data: cohorts }, { data: respondents }] = await Promise.all([
    supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
    supabase.from('awareness_cohorts')
      .select('id, department, status, interviewed_on, score_pct, rating, created_at')
      .eq('client_org_id', id).eq('framework_key', framework).order('created_at', { ascending: false }),
    supabase.from('awareness_respondents').select('id, cohort_id'),
  ]);

  const role = membership?.role ?? '';
  const isAdvisor = ['practice_owner', 'practice_consultant'].includes(role);
  const all = cohorts ?? [];
  const completed = all.filter(c => c.status === 'complete').length;
  const planned = client.awareness_departments_planned;
  const respCount = (cid: string) => (respondents ?? []).filter(r => r.cohort_id === cid).length;
  type Tone = ComponentProps<typeof Badge>['tone'];
  const RATING_TONE: Record<string, Tone> = { high: 'warn', medium: 'neutral', low: 'accent' };

  return (
    <>
      <PageHeader
        title={client.name + ' — Awareness interviews'}
        back="Workspace"
        backHref={'/clients/' + id + qs}
        meta="Confidential per-department staff interviews measuring security and privacy behaviour. Respondents are anonymised — reports show numbers, never identities. Completed cohorts feed the assessment report's people-risk section."
        actions={<Badge><span className="mono">{framework.toUpperCase()}</span></Badge>}
      />

      {!isAdvisor ? (
        <Card pad={24}>
          <EmptyState icon="shield" message="Interview data is restricted to the advisory team. Results appear, anonymised, in your issued assessment reports." />
        </Card>
      ) : (
        <>
          <Card pad={20} style={{ marginBottom: 24 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
              <span style={{ fontWeight: 500 }}>
                {completed} of {planned ?? '?'} departments interviewed
              </span>
              {(planned == null || completed < planned) && (
                <Badge tone="warn" dot>coverage limitation — disclosed in reports</Badge>
              )}
              <span style={{ flex: 1 }} />
              <CohortActions clientOrgId={id} framework={framework} planned={planned} />
            </div>
          </Card>

          <Card title="Cohorts" pad={0}>
            {all.length === 0 ? (
              <EmptyState icon="users" message="No cohorts yet. Create one per department and key answers during the confidential interview." />
            ) : (
              <DataTable
                columns={[{ label: 'Department' }, { label: 'Respondents', align: 'right' }, { label: 'Alignment', align: 'right' }, { label: 'Status' }, { label: '' }]}
                rows={all.map(c => [
                  <span key="d" style={{ fontWeight: 500 }}>{c.department}</span>,
                  <span key="n" className="mono">{respCount(c.id)}</span>,
                  <span key="p" className="mono">{c.score_pct != null ? c.score_pct + '%' : '—'}</span>,
                  <Badge key="s" tone={c.status === 'complete' ? (RATING_TONE[c.rating ?? ''] ?? 'neutral') : 'neutral'} dot>
                    {c.status === 'complete' ? c.rating + ' risk' : c.status.replace('_', ' ')}
                  </Badge>,
                  <Link key="l" href={'/clients/' + id + '/awareness/' + c.id + qs} style={{ fontSize: 'var(--fs-xs)' }}>
                    {c.status === 'in_progress' ? 'Continue' : 'View'}
                  </Link>,
                ])}
              />
            )}
          </Card>
        </>
      )}
    </>
  );
}
