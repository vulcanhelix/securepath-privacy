'use client';
import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { Input } from '@/components/ui/forms';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';

type Q = { id: string; domain_code: string; domain_name: string; code: string;
  question_number: number; question: string; good_answer: string; guidance: string | null };
type R = { id: string; respondent_no: number; label: string | null };
type Resp = { respondent_id: string; question_id: string; answer: string; note: string | null };

const ANSWERS = ['yes', 'no', 'unsure', 'na'] as const;
const ANSWER_LABEL: Record<string, string> = { yes: 'Yes', no: 'No', unsure: 'Unsure', na: 'N/A' };

export default function InterviewCapture({ cohortId, locked, questions, respondents, responses }:
  { cohortId: string; locked: boolean; questions: Q[]; respondents: R[]; responses: Resp[] }) {
  const router = useRouter();
  const [active, setActive] = useState(respondents[0]?.id ?? '');
  const [label, setLabel] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  // local answer state seeded from server rows; key = respondent_id + ':' + question_id
  const [answers, setAnswers] = useState<Record<string, string>>(() => {
    const m: Record<string, string> = {};
    responses.forEach(r => { m[r.respondent_id + ':' + r.question_id] = r.answer; });
    return m;
  });

  const domains = useMemo(() => {
    const seen = new Map<string, { code: string; name: string; qs: Q[] }>();
    questions.forEach(q => {
      if (!seen.has(q.domain_code)) seen.set(q.domain_code, { code: q.domain_code, name: q.domain_name, qs: [] });
      seen.get(q.domain_code)!.qs.push(q);
    });
    return [...seen.values()];
  }, [questions]);

  // live alignment from local state (matches the server maths: na excluded, unsure not aligned)
  const stats = useMemo(() => {
    const per = respondents.map(r => {
      let answered = 0, aligned = 0;
      questions.forEach(q => {
        const a = answers[r.id + ':' + q.id];
        if (a && a !== 'na') { answered += 1; if (a === q.good_answer) aligned += 1; }
      });
      return { r, answered, aligned };
    });
    const answered = per.reduce((s, p) => s + p.answered, 0);
    const aligned = per.reduce((s, p) => s + p.aligned, 0);
    return { per, answered, aligned, pct: answered ? Math.round(100 * aligned / answered) : null };
  }, [answers, questions, respondents]);

  async function addRespondent() {
    setBusy(true); setMsg({});
    const { data, error } = await browserClient().rpc('add_awareness_respondent', {
      p_cohort_id: cohortId, p_label: label || null,
    });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setLabel(''); setActive((data as { id: string })?.id ?? ''); router.refresh();
  }

  async function setAnswer(questionId: string, answer: string) {
    if (locked || !active) return;
    setAnswers(a => ({ ...a, [active + ':' + questionId]: answer }));
    const { error } = await browserClient().rpc('record_awareness_responses', {
      p_respondent_id: active, p_answers: [{ question_id: questionId, answer }],
    });
    if (error) setMsg({ err: error.message });
  }

  async function complete() {
    if (!confirm('Complete this cohort? Responses lock as immutable evidence. Respondent identities are never shown in reports.')) return;
    setBusy(true); setMsg({});
    const { error } = await browserClient().rpc('complete_awareness_cohort', { p_cohort_id: cohortId });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setMsg({ ok: 'Cohort completed and locked.' }); router.refresh();
  }

  return (
    <>
      <Card pad={20} style={{ marginBottom: 24 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          {respondents.map(r => (
            <Button key={r.id} size="sm" variant={active === r.id ? 'primary' : 'secondary'}
              onClick={() => setActive(r.id)}>
              Respondent {r.respondent_no}{r.label ? ' (' + r.label + ')' : ''}
            </Button>
          ))}
          {!locked && (
            <>
              <Input placeholder="initials (optional)" value={label} onChange={e => setLabel(e.target.value)}
                style={{ width: 140 }} />
              <Button size="sm" variant="secondary" disabled={busy} onClick={addRespondent}>+ Add respondent</Button>
            </>
          )}
          <span style={{ flex: 1 }} />
          <span className="mono" style={{ fontSize: 'var(--fs-sm)' }}>
            {stats.aligned}/{stats.answered} aligned{stats.pct != null ? ' (' + stats.pct + '%)' : ''}
          </span>
          {!locked && respondents.length > 0 && (
            <Button size="sm" disabled={busy} onClick={complete} cta>Complete cohort</Button>
          )}
        </div>
        {msg.err && <Alert tone="err">{msg.err}</Alert>}
        {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
      </Card>

      {respondents.length === 0 ? (
        <Card pad={24}><EmptyState icon="users" message="Add the first respondent to begin the interview." /></Card>
      ) : locked ? (
        <Card title="Respondent summary" pad={0}>
          <DataTable
            columns={[{ label: 'Respondent' }, { label: 'Answered', align: 'right' }, { label: 'Aligned', align: 'right' }]}
            rows={stats.per.map(p => [
              <span key="r">Respondent {p.r.respondent_no}</span>,
              <span key="a" className="mono">{p.answered}</span>,
              <span key="l" className="mono">{p.answered ? Math.round(100 * p.aligned / p.answered) + '%' : '—'}</span>,
            ])}
          />
        </Card>
      ) : (
        domains.map(d => (
          <Card key={d.code} title={d.code + ' — ' + d.name} pad={20} style={{ marginBottom: 20 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              {d.qs.map(q => (
                <div key={q.id} style={{ borderTop: '1px solid var(--border)', paddingTop: 10 }}>
                  <div style={{ display: 'flex', gap: 10, alignItems: 'baseline', flexWrap: 'wrap' }}>
                    <Badge><span className="mono">{q.code}</span></Badge>
                    <span style={{ fontWeight: 500 }}>{q.question}</span>
                  </div>
                  {q.guidance && <p style={{ color: 'var(--muted)', fontSize: 'var(--fs-xs)', margin: '6px 0' }}>{q.guidance}</p>}
                  <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
                    {ANSWERS.map(a => (
                      <Button key={a} size="sm"
                        variant={answers[active + ':' + q.id] === a ? 'primary' : 'secondary'}
                        onClick={() => setAnswer(q.id, a)}>
                        {ANSWER_LABEL[a]}
                      </Button>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          </Card>
        ))
      )}
    </>
  );
}
