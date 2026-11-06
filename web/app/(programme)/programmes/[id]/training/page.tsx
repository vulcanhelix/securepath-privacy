import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { EmptyState } from '@/components/ui/EmptyState';
import { TrainingRecords, type TrainingRow } from './TrainingRecords';

export const dynamic = 'force-dynamic';

// W2-12 — training and awareness (spec §8.12 FR-TRN-01/02, NFR-15).
//   Training records: per-person attendance (list_training_records, definer,
//   voided rows hidden unless asked); coverage by site / functional group
//   against the client's in-scope headcount.
//   Awareness: get_awareness_report (anonymised aggregate over completed
//   cohorts). NFR-15 — this page renders ONLY averages (overall + per
//   domain). The report's per-cohort/per-respondent arrays are deliberately
//   never read, and figures are suppressed below MIN_RESPONDENTS so a tiny
//   cohort cannot be re-identified from its average.

const WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];
const MIN_RESPONDENTS = 3;

type AwarenessAvg = { respondents: number; answered: number; aligned: number; pct: number | null; rating: string | null };
type AwarenessReport = {
  available: boolean;
  overall: AwarenessAvg;
  domains: { code: string; name: string; pct: number; rating: string }[];
  coverage: { cohorts_completed: number; departments_planned: number | null; limitation: boolean };
};

const RATING_TONE: Record<string, 'pass' | 'warn' | 'fail'> = { low: 'pass', medium: 'warn', high: 'fail' };

export default async function TrainingPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ voided?: string }>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();
  const showVoided = sp.voided === '1';

  const [recRes, awRes, hcRes, { data: canWrite }] = await Promise.all([
    supabase.rpc('list_training_records', { p_client_org_id: ctx.client.id, p_include_voided: showVoided }),
    supabase.rpc('get_awareness_report', { p_client_org_id: ctx.client.id }),
    supabase.from('client_orgs').select('headcount_in_scope').eq('id', ctx.client.id).maybeSingle(),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: WRITE_ROLES }),
  ]);

  const records = (recRes.data ?? []) as TrainingRow[];
  const live = records.filter((r) => !r.voided_at);
  const headcount = (hcRes.data?.headcount_in_scope as number | null | undefined) ?? null;
  const trainedPeople = new Set(live.filter((r) => r.attendance).map((r) => r.person.trim().toLowerCase())).size;
  const coverage = headcount ? Math.round((100 * trainedPeople) / headcount) : null;

  // attendance by site / functional group (FR-TRN-01)
  const groupBy = (key: 'site' | 'functional_group') => {
    const m = new Map<string, Set<string>>();
    for (const r of live)
      if (r.attendance) {
        const k = r[key] ?? '—';
        m.set(k, (m.get(k) ?? new Set()).add(r.person.trim().toLowerCase()));
      }
    return [...m.entries()].map(([k, s]) => ({ k, n: s.size })).sort((a, b) => b.n - a.n);
  };
  const bySite = groupBy('site');
  const byGroup = groupBy('functional_group');

  const aw = (awRes.data ?? null) as AwarenessReport | null;
  const awShown = !!aw?.available && (aw.overall?.respondents ?? 0) >= MIN_RESPONDENTS;

  return (
    <>
      <PageHeader
        title="Training & awareness"
        meta={`${live.length} record${live.length === 1 ? '' : 's'} · ${ctx.client.name}`}
      />

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{trainedPeople}</div>
          <div className="muted">People trained</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{headcount ?? '—'}</div>
          <div className="muted">In-scope headcount</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{coverage == null ? '—' : `${coverage}%`}</div>
          <div className="muted">Coverage{headcount ? '' : ' (headcount not set)'}</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 140px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{awShown && aw?.overall.pct != null ? `${aw.overall.pct}%` : '—'}</div>
          <div className="muted">Awareness average</div>
        </Card>
      </div>

      {recRes.error ? <Alert tone="err">{`Could not load training records: ${recRes.error.message}`}</Alert> : null}

      {bySite.length || byGroup.length ? (
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
          {[{ t: 'By site', rows: bySite }, { t: 'By functional group', rows: byGroup }].map((g) => (
            <Card key={g.t} title={g.t} pad={16} style={{ flex: '1 1 260px' }}>
              <table className="sp-table">
                <tbody>
                  {g.rows.map((r) => (
                    <tr key={r.k}>
                      <td>{r.k}</td>
                      <td className="mono" style={{ textAlign: 'right' }}>{r.n} trained</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Card>
          ))}
        </div>
      ) : null}

      <TrainingRecords
        clientOrgId={ctx.client.id}
        programmeId={id}
        records={records}
        canWrite={canWrite === true}
        showVoided={showVoided}
      />

      <h2 style={{ fontSize: 'var(--fs-md, 1rem)', margin: '28px 0 10px' }}>Staff awareness (anonymised averages)</h2>
      <Card>
        {awRes.error ? (
          <Alert tone="err">{`Could not load awareness results: ${awRes.error.message}`}</Alert>
        ) : !aw?.available ? (
          <EmptyState icon="users" message="No completed awareness checks yet." />
        ) : !awShown ? (
          <EmptyState
            icon="eye-off"
            message={`Fewer than ${MIN_RESPONDENTS} respondents so far — averages are withheld so no individual can be identified (NFR-15).`}
          />
        ) : (
          <>
            <p className="muted" style={{ marginTop: 0, fontSize: 'var(--fs-sm)' }}>
              Average across {aw.overall.respondents} respondents in {aw.coverage.cohorts_completed} completed
              check{aw.coverage.cohorts_completed === 1 ? '' : 's'}. No names or individual responses are shown or stored
              against people (FR-TRN-02, NFR-15).
              {aw.coverage.limitation ? ' Coverage is partial — not every planned department has been checked.' : ''}
            </p>
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Domain</th>
                  <th style={{ textAlign: 'right' }}>Average aligned</th>
                  <th>Risk</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td style={{ fontWeight: 600 }}>Overall</td>
                  <td className="mono" style={{ textAlign: 'right' }}>{aw.overall.pct ?? '—'}%</td>
                  <td>{aw.overall.rating ? <Badge tone={RATING_TONE[aw.overall.rating]}>{aw.overall.rating}</Badge> : null}</td>
                </tr>
                {aw.domains.map((d) => (
                  <tr key={d.code}>
                    <td>{d.name}</td>
                    <td className="mono" style={{ textAlign: 'right' }}>{d.pct}%</td>
                    <td><Badge tone={RATING_TONE[d.rating]}>{d.rating}</Badge></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}
      </Card>
    </>
  );
}
