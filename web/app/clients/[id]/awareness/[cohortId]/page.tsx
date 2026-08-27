import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import InterviewCapture from './InterviewCapture';
import { PageHeader } from '@/components/ui/PageHeader';
import { Badge } from '@/components/ui/Badge';

export const dynamic = 'force-dynamic';

// One cohort: capture answers per respondent during the confidential interview,
// live scores, complete-and-lock. Advisor-only (RLS returns nothing to client roles).
export default async function Cohort({ params, searchParams }:
  { params: Promise<{ id: string; cohortId: string }>; searchParams: Promise<{ framework?: string }> }) {
  const { id, cohortId } = await params;
  const framework = (await searchParams).framework ?? 'popia';
  const qs = framework === 'popia' ? '' : '?framework=' + framework;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: cohort } = await supabase.from('awareness_cohorts')
    .select('id, client_org_id, department, status, interviewed_on, score_pct, rating, content_pack_id')
    .eq('id', cohortId).eq('client_org_id', id).maybeSingle();
  if (!cohort) redirect('/clients/' + id + '/awareness' + qs);

  const [{ data: client }, { data: questions }, { data: respondents }, { data: responses }] = await Promise.all([
    supabase.from('client_orgs').select('name').eq('id', id).maybeSingle(),
    supabase.from('awareness_questions')
      .select('id, domain_code, domain_name, code, question_number, question, good_answer, guidance')
      .eq('content_pack_id', cohort.content_pack_id).eq('active', true).order('question_number'),
    supabase.from('awareness_respondents').select('id, respondent_no, label')
      .eq('cohort_id', cohortId).order('respondent_no'),
    supabase.from('awareness_responses').select('respondent_id, question_id, answer, note'),
  ]);

  const respondentIds = new Set((respondents ?? []).map(r => r.id));

  return (
    <>
      <PageHeader
        title={(client?.name ?? '') + ' — ' + cohort.department + ' cohort'}
        back="Awareness"
        backHref={'/clients/' + id + '/awareness' + qs}
        meta="Answers are keyed by the advisor during a confidential interview. Identities are minimised: reports show respondent numbers only. Completing the cohort locks responses as immutable evidence."
        actions={
          <Badge tone={cohort.status === 'complete' ? 'ink' : 'accent'} dot>
            {cohort.status === 'complete' ? 'Complete — ' + (cohort.score_pct ?? '—') + '% aligned' : 'In progress'}
          </Badge>
        }
      />
      <InterviewCapture
        cohortId={cohortId}
        locked={cohort.status !== 'in_progress'}
        questions={questions ?? []}
        respondents={respondents ?? []}
        responses={(responses ?? []).filter(r => respondentIds.has(r.respondent_id))}
      />
    </>
  );
}
