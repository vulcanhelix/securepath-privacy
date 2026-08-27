'use client';
import { useEffect, useState, useCallback, useRef } from 'react';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Field, Input, Select, Textarea } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';
import { ResponseOptions } from '@/components/ui/ResponseOptions';
import { ScorePanel } from '@/components/ui/ScorePanel';
import { SectionBars } from '@/components/ui/SectionBars';

interface Question {
  id: string;
  uid: string;
  section_id: number;
  section_name: string;
  subsection: string;
  question_number: number;
  question: string;
  why_matters: string;
  regulatory_ref: string;
  risk: string;
  evidence_req: string;
  remediation: string;
}

interface Response {
  id: string;
  question_id: string;
  response: string;
  findings: string;
  responsible_party: string;
  target_date: string;
  status: string;
}

interface Assessment {
  id: string;
  framework: string;
  title: string;
  status: string;
  score_pct: number | null;
  rating: string | null;
  org_scale: string | null;
  client_orgs: { name: string } | null;
}

interface SectionScore {
  section_name: string;
  score: number;
  total: number;
  pct: number;
}

interface OverallScore {
  score: number;
  total: number;
  pct: number;
  rating: string;
}

interface Score {
  section_scores: Record<string, SectionScore>;
  overall: OverallScore;
  completion_pct: number;
  risk_summary: Record<string, number>;
  critical_gaps: number;
}

interface AssessmentEditorProps {
  assessmentId: string;
}

const RISK_TONE: Record<string, 'fail' | 'warn' | 'neutral'> = {
  critical: 'fail',
  high: 'warn',
};

export default function AssessmentEditor({ assessmentId }: AssessmentEditorProps) {
  const [assessment, setAssessment] = useState<Assessment | null>(null);
  const [questions, setQuestions] = useState<Question[]>([]);
  const [responses, setResponses] = useState<Map<string, Response>>(new Map());
  const [currentSection, setCurrentSection] = useState<number>(1);
  const [currentQuestionId, setCurrentQuestionId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [score, setScore] = useState<Score | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const findingsTimer = useRef<NodeJS.Timeout | null>(null);

  useEffect(() => {
    loadAssessmentData();
  }, [assessmentId]);

  async function loadAssessmentData() {
    setLoading(true);
    setError('');
    try {
      const [assessmentRes, responsesRes, scoreRes] = await Promise.all([
        fetch(`/api/assessments/${assessmentId}`).then(r => { if (!r.ok) throw new Error('assessment'); return r.json(); }),
        fetch(`/api/assessments/${assessmentId}/responses`).then(r => { if (!r.ok) throw new Error('responses'); return r.json(); }),
        fetch(`/api/assessments/${assessmentId}/score`).then(r => { if (!r.ok) throw new Error('score'); return r.json(); }),
      ]);

      setAssessment(assessmentRes);

      // questions come from the session's pinned content pack, not the live framework bank
      const questionsRes = await fetch(`/api/assessment/questions?session_id=${assessmentId}`)
        .then(r => { if (!r.ok) throw new Error('questions'); return r.json(); });

      setQuestions(questionsRes);
      const responseMap = new Map<string, Response>(responsesRes.map((r: Response) => [r.question_id, r]));
      setResponses(responseMap);
      setScore(scoreRes);

      if (questionsRes.length > 0) {
        const firstQuestion = questionsRes[0];
        setCurrentSection(firstQuestion.section_id);
        setCurrentQuestionId(firstQuestion.id);
      }
    } catch (error) {
      console.error('Failed to load assessment data:', error);
      setError('Failed to load assessment data. Please try again.');
    } finally {
      setLoading(false);
    }
  }

  const currentQuestion = questions.find(q => q.id === currentQuestionId);
  const currentResponse = currentQuestionId ? responses.get(currentQuestionId) : null;

  const saveResponse = useCallback(async (questionId: string, updates: Partial<Response>) => {
    if (!questionId) return;

    setSaving(true);
    try {
      const response = responses.get(questionId);
      const payload = {
        question_id: questionId,
        response: updates.response ?? response?.response ?? 'na',
        findings: updates.findings ?? response?.findings ?? '',
        responsible_party: updates.responsible_party ?? response?.responsible_party ?? '',
        target_date: updates.target_date ?? response?.target_date ?? '',
        status: updates.status ?? response?.status ?? 'not_started',
      };

      const r = await fetch(`/api/assessments/${assessmentId}/responses`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });

      if (!r.ok) {
        const err = await r.json();
        console.error('Failed to save response:', err);
      } else {
        const scoreRes = await fetch(`/api/assessments/${assessmentId}/score`).then(r => r.json());
        setScore(scoreRes);
      }
    } catch (error) {
      console.error('Failed to save response:', error);
    } finally {
      setSaving(false);
    }
  }, [assessmentId, responses]);

  const handleResponseChange = (response: string) => {
    if (!currentQuestionId) return;

    const updatedResponses = new Map(responses);
    const existing = updatedResponses.get(currentQuestionId) || {
      id: '', question_id: currentQuestionId, response: 'na', findings: '',
      responsible_party: '', target_date: '', status: 'not_started'
    };
    const status = existing.status === 'na' ? 'not_started' : existing.status;
    updatedResponses.set(currentQuestionId, { ...existing, response, status });
    setResponses(updatedResponses);

    saveResponse(currentQuestionId, { response, status });
  };

  const handleFindingsChange = (findings: string) => {
    if (!currentQuestionId) return;

    const updatedResponses = new Map(responses);
    const existing = updatedResponses.get(currentQuestionId) || {
      id: '', question_id: currentQuestionId, response: 'na', findings: '',
      responsible_party: '', target_date: '', status: 'not_started'
    };
    updatedResponses.set(currentQuestionId, { ...existing, findings });
    setResponses(updatedResponses);

    if (findingsTimer.current) clearTimeout(findingsTimer.current);
    findingsTimer.current = setTimeout(() => {
      saveResponse(currentQuestionId, { findings });
    }, 500);
  };

  const handleFieldChange = (field: keyof Response, value: string) => {
    if (!currentQuestionId) return;

    const updatedResponses = new Map(responses);
    const existing = updatedResponses.get(currentQuestionId) || {
      id: '', question_id: currentQuestionId, response: 'na', findings: '',
      responsible_party: '', target_date: '', status: 'not_started'
    };
    updatedResponses.set(currentQuestionId, { ...existing, [field]: value });
    setResponses(updatedResponses);

    saveResponse(currentQuestionId, { [field]: value } as Partial<Response>);
  };

  const sectionQuestions = questions.filter(q => q.section_id === currentSection);
  const sections = [...new Set(questions.map(q => q.section_id))].sort((a, b) => a - b);

  // Previous / Next across the whole ordered question list
  const flatIndex = questions.findIndex(q => q.id === currentQuestionId);
  function goTo(idx: number) {
    const q = questions[idx];
    if (!q) return;
    setCurrentSection(q.section_id);
    setCurrentQuestionId(q.id);
  }

  if (loading) {
    return <Card><p className="muted" style={{ margin: 0 }}>Loading assessment…</p></Card>;
  }

  if (error) {
    return <Alert tone="err">{error}</Alert>;
  }

  if (!currentQuestion) {
    return <Card><p className="muted" style={{ margin: 0 }}>No questions found for this framework.</p></Card>;
  }

  return (
    <>
      {assessment && (
        <Card style={{ marginBottom: 24 }} pad={20}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
            <strong>{assessment.client_orgs?.name ?? '—'}</strong>
            <Badge><span className="mono">{assessment.framework.toUpperCase()}</span></Badge>
            {assessment.org_scale && (
              <Badge>{assessment.org_scale === 'sme' ? 'SME' : 'Large'}</Badge>
            )}
            <Badge tone={assessment.status === 'signed_off' ? 'pass' : 'neutral'} dot>
              {assessment.status.replace(/_/g, ' ')}
            </Badge>
            <span style={{ flex: 1 }} />
            <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
              {saving ? 'Saving…' : assessment.rating || 'In Progress'}
            </span>
          </div>
        </Card>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '280px 1fr', gap: 24, alignItems: 'start' }}>
        {/* Left panel — section nav + live score */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 24, position: 'sticky', top: 24 }}>
          <Card pad={16}>
            <div className="sp-side-heading" style={{ color: 'var(--faint)', padding: '0 10px 8px' }}>Sections</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
              {sections.map(sectionId => {
                const sq = questions.filter(q => q.section_id === sectionId);
                const answeredCount = sq.filter(q => {
                  const r = responses.get(q.id);
                  return r?.response && r.response !== 'na';
                }).length;
                const isActive = currentSection === sectionId;
                return (
                  <button
                    key={sectionId}
                    onClick={() => setCurrentSection(sectionId)}
                    style={{
                      display: 'flex', alignItems: 'center', gap: 8, width: '100%', margin: 0,
                      padding: '9px 14px', borderRadius: 'var(--r-pill)', border: '1px solid transparent',
                      background: isActive ? 'var(--inset)' : 'transparent',
                      color: isActive ? 'var(--text)' : 'var(--muted)',
                      fontSize: 'var(--fs-sm)', fontWeight: 500, cursor: 'pointer', textAlign: 'left',
                    }}
                  >
                    <span style={{ flex: 1 }}>{sq[0]?.section_name ?? `Section ${sectionId}`}</span>
                    <span className="mono" style={{ fontSize: 'var(--fs-label)' }}>
                      {answeredCount}/{sq.length}
                    </span>
                  </button>
                );
              })}
            </div>

            <div className="sp-side-heading" style={{ color: 'var(--faint)', padding: '16px 10px 8px' }}>Questions</div>
            <div style={{ maxHeight: 320, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 2 }}>
              {sectionQuestions.map(q => {
                const response = responses.get(q.id);
                const isAnswered = response?.response && response.response !== 'na';
                const isCurrent = currentQuestionId === q.id;
                return (
                  <button
                    key={q.id}
                    onClick={() => setCurrentQuestionId(q.id)}
                    style={{
                      display: 'block', width: '100%', margin: 0, padding: '8px 10px',
                      background: isCurrent ? 'var(--inset)' : 'transparent',
                      border: 'none', borderLeft: `3px solid ${isAnswered ? 'var(--pass)' : 'var(--border)'}`,
                      borderRadius: 'var(--r-sm)', cursor: 'pointer', textAlign: 'left', color: 'inherit',
                    }}
                  >
                    <span className="mono" style={{ fontSize: 'var(--fs-xs)', fontWeight: 500 }}>Q{q.question_number}</span>
                    <span style={{ display: 'block', fontSize: 'var(--fs-xs)', color: 'var(--muted)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {q.question}
                    </span>
                  </button>
                );
              })}
            </div>
          </Card>

          {score && (
            <>
              <ScorePanel
                pct={score.overall?.pct || 0}
                rating={score.overall?.rating || 'In Progress'}
                completionPct={score.completion_pct || 0}
                criticalGaps={score.critical_gaps || 0}
              />
              {Object.keys(score.section_scores ?? {}).length > 0 && (
                <Card pad={20}>
                  <SectionBars
                    sections={Object.values(score.section_scores).map(s => ({ name: s.section_name, pct: s.pct }))}
                  />
                </Card>
              )}
            </>
          )}
        </div>

        {/* Right panel — question workbench */}
        <Card>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <Badge tone="ink">{currentQuestion.section_name || `Section ${currentQuestion.section_id}`}</Badge>
            <span style={{ fontWeight: 500 }}>Question {currentQuestion.question_number}</span>
            {currentQuestion.risk && (
              <Badge tone={RISK_TONE[currentQuestion.risk.toLowerCase()] ?? 'neutral'} dot>{currentQuestion.risk}</Badge>
            )}
            <span style={{ flex: 1 }} />
            {currentQuestion.regulatory_ref && (
              <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {currentQuestion.regulatory_ref}
              </span>
            )}
          </div>

          <h2 style={{ fontSize: 'var(--fs-lead)', letterSpacing: 'var(--ls-snug)', margin: '20px 0 8px' }}>
            {currentQuestion.question}
          </h2>

          {currentQuestion.why_matters && (
            <div style={{ padding: 16, background: 'var(--inset)', borderRadius: 'var(--r-ctl)', margin: '16px 0' }}>
              <strong style={{ fontSize: 'var(--fs-xs)', textTransform: 'uppercase', letterSpacing: 'var(--ls-label)', color: 'var(--faint)', fontWeight: 500 }}>
                Why this matters
              </strong>
              <p style={{ margin: '6px 0 0', fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
                {currentQuestion.why_matters}
              </p>
            </div>
          )}

          <div style={{ margin: '24px 0' }}>
            <ResponseOptions value={currentResponse?.response} onChange={handleResponseChange} />
          </div>

          {currentQuestion.evidence_req && (
            <Field label="Evidence required">
              <div style={{ padding: '12px 14px', background: 'var(--inset)', borderRadius: 'var(--r-ctl)', fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
                {currentQuestion.evidence_req}
              </div>
            </Field>
          )}

          {currentQuestion.remediation && (
            <Field label="Remediation steps">
              <div style={{ padding: '12px 14px', background: 'var(--inset)', borderRadius: 'var(--r-ctl)', fontSize: 'var(--fs-sm)', color: 'var(--text-2)' }}>
                {currentQuestion.remediation}
              </div>
            </Field>
          )}

          <Field label="Findings / notes">
            <Textarea
              value={currentResponse?.findings || ''}
              onChange={e => handleFindingsChange(e.target.value)}
              placeholder="Enter your findings and observations…"
            />
          </Field>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            <Field label="Responsible party">
              <Input
                type="text"
                value={currentResponse?.responsible_party || ''}
                onChange={e => handleFieldChange('responsible_party', e.target.value)}
                placeholder="Name or team"
              />
            </Field>
            <Field label="Target date">
              <Input
                type="date"
                value={currentResponse?.target_date || ''}
                onChange={e => handleFieldChange('target_date', e.target.value)}
              />
            </Field>
          </div>

          <Field label="Remediation status">
            <Select
              value={currentResponse?.status || 'not_started'}
              onChange={e => handleFieldChange('status', e.target.value)}
            >
              <option value="not_started">Not Started</option>
              <option value="in_progress">In Progress</option>
              <option value="complete">Complete</option>
              <option value="na">N/A</option>
            </Select>
          </Field>

          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 24 }}>
            <Button variant="secondary" size="sm" disabled={flatIndex <= 0} onClick={() => goTo(flatIndex - 1)}>
              Previous
            </Button>
            <Button variant="secondary" size="sm" disabled={flatIndex >= questions.length - 1} onClick={() => goTo(flatIndex + 1)}>
              Next
            </Button>
          </div>
        </Card>
      </div>
    </>
  );
}
