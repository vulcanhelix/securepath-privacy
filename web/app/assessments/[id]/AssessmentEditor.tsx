'use client';
import { useEffect, useState, useCallback, useRef } from 'react';
import Link from 'next/link';

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

      // Load questions for this assessment's framework
      const framework = assessmentRes.framework || 'popia';
      const questionsRes = await fetch(`/api/assessment/questions?framework=${framework}`)
        .then(r => { if (!r.ok) throw new Error('questions'); return r.json(); });

      setQuestions(questionsRes);
      const responseMap = new Map<string, Response>(responsesRes.map((r: Response) => [r.question_id, r]));
      setResponses(responseMap);
      setScore(scoreRes);

      // Initialize current section/question
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
        // Refresh score
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

    // Debounce save
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

  // Get distinct sections from questions
  const sections = [...new Set(questions.map(q => q.section_id))].sort((a, b) => a - b);

  if (loading) {
    return <div className="card"><p>Loading assessment...</p></div>;
  }

  if (error) {
    return <div className="card"><p className="err">{error}</p></div>;
  }

  if (!currentQuestion) {
    return <div className="card"><p>No questions found for this framework.</p></div>;
  }

  return (
    <>
      {assessment && (
        <div className="card" style={{ marginBottom: '1rem' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: '1rem' }}>
            <div>
              <label>Client</label>
              <strong>{assessment.client_orgs?.name ?? '—'}</strong>
            </div>
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
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '280px 1fr', gap: '1rem' }}>
        {/* Left Panel - Navigation */}
        <div className="card" style={{ padding: '1rem' }}>
          <h3>Sections</h3>
          {sections.map(sectionId => {
            const sectionQuestions = questions.filter(q => q.section_id === sectionId);
            const answeredCount = sectionQuestions.filter(q => {
              const r = responses.get(q.id);
              return r?.response && r.response !== 'na';
            }).length;
            const isActive = currentSection === sectionId;
            return (
              <button
                key={sectionId}
                onClick={() => setCurrentSection(sectionId)}
                style={{
                  display: 'block',
                  width: '100%',
                  padding: '0.5rem',
                  margin: '0.25rem 0',
                  background: isActive ? 'var(--accent)' : 'transparent',
                  color: isActive ? 'white' : 'var(--text)',
                  border: '1px solid var(--border)',
                  borderRadius: '4px',
                  cursor: 'pointer',
                  textAlign: 'left',
                  fontSize: '0.85rem',
                }}
              >
                <div>Section {sectionId}</div>
                <div style={{ fontSize: '0.7rem', opacity: 0.8 }}>
                  {answeredCount}/{sectionQuestions.length} answered
                </div>
              </button>
            );
          })}

          <h3 style={{ marginTop: '1rem' }}>Questions</h3>
          <div style={{ maxHeight: '400px', overflowY: 'auto' }}>
            {sectionQuestions.map(q => {
              const response = responses.get(q.id);
              const isAnswered = response?.response && response.response !== 'na';
              return (
                <div
                  key={q.id}
                  onClick={() => setCurrentQuestionId(q.id)}
                  style={{
                    padding: '0.5rem',
                    margin: '0.25rem 0',
                    background: currentQuestionId === q.id ? 'var(--bg)' : 'transparent',
                    borderRadius: '4px',
                    cursor: 'pointer',
                    borderLeft: `3px solid ${isAnswered ? 'var(--accent)' : 'var(--border)'}`,
                  }}
                >
                  <div style={{ fontWeight: 600, fontSize: '0.85rem' }}>
                    Q{q.question_number}
                    {q.risk && <span style={{ marginLeft: '0.5rem', fontSize: '0.7rem', color: 'var(--muted)' }}>{q.risk}</span>}
                  </div>
                  <div style={{ fontSize: '0.75rem', color: 'var(--muted)' }}>
                    {q.question.substring(0, 50)}...
                  </div>
                </div>
              );
            })}
          </div>

          {score && (
            <div style={{ marginTop: '1rem', padding: '1rem', background: 'var(--bg)', borderRadius: '4px' }}>
              <div style={{ fontSize: '2rem', fontWeight: 700, color: getScoreColor(score.overall?.pct || 0) }}>
                {score.overall?.pct || 0}%
              </div>
              <div style={{ fontSize: '0.85rem', fontWeight: 600 }}>
                {score.overall?.rating || 'In Progress'}
              </div>
              <div style={{ fontSize: '0.75rem', color: 'var(--muted)', marginTop: '0.5rem' }}>
                {score.completion_pct || 0}% complete
              </div>
              {score.critical_gaps > 0 && (
                <div style={{ fontSize: '0.75rem', color: '#dc2626', marginTop: '0.25rem' }}>
                  {score.critical_gaps} critical gap(s)
                </div>
              )}
            </div>
          )}
        </div>

        {/* Right Panel - Question Detail */}
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div>
              <span className="badge" style={{ background: 'var(--accent)', color: 'white' }}>
                Section {currentQuestion.section_id}
              </span>
              <span style={{ marginLeft: '0.5rem', fontWeight: 600 }}>
                Question {currentQuestion.question_number}
              </span>
              {currentQuestion.risk && (
                <span className="badge" style={{ marginLeft: '0.5rem' }}>
                  {currentQuestion.risk}
                </span>
              )}
            </div>
            {saving && <span className="muted">Saving...</span>}
          </div>

          <div style={{ marginTop: '1.5rem' }}>
            <h2 style={{ fontSize: '1.1rem', marginBottom: '0.5rem' }}>
              {currentQuestion.question}
            </h2>

            {currentQuestion.why_matters && (
              <div style={{ padding: '1rem', background: 'var(--bg)', borderRadius: '4px', margin: '1rem 0' }}>
                <strong>Why This Matters:</strong>
                <p style={{ marginTop: '0.5rem', fontSize: '0.9rem' }}>
                  {currentQuestion.why_matters}
                </p>
              </div>
            )}

            {currentQuestion.regulatory_ref && (
              <div style={{ fontSize: '0.85rem', color: 'var(--muted)', margin: '0.5rem 0' }}>
                <strong>Reference:</strong> {currentQuestion.regulatory_ref}
              </div>
            )}

            <div style={{ margin: '1.5rem 0' }}>
              <label>Response</label>
              <div style={{ display: 'flex', gap: '0.5rem', flexWrap: 'wrap' }}>
                {[
                  { value: 'fully_compliant', label: 'Yes – Fully Compliant' },
                  { value: 'partial', label: 'Yes – Partially Compliant' },
                  { value: 'non_compliant', label: 'No – Non-Compliant' },
                  { value: 'na', label: 'N/A – Not Applicable' },
                ].map(({ value, label }) => (
                  <button
                    key={value}
                    onClick={() => handleResponseChange(value)}
                    style={{
                      padding: '0.75rem 1rem',
                      border: '2px solid',
                      borderRadius: '6px',
                      background: currentResponse?.response === value ? 'var(--accent)' : 'white',
                      color: currentResponse?.response === value ? 'white' : 'var(--text)',
                      borderColor: currentResponse?.response === value ? 'var(--accent)' : 'var(--border)',
                      cursor: 'pointer',
                      fontWeight: 600,
                      fontSize: '0.9rem',
                    }}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>

            {currentQuestion.evidence_req && (
              <div style={{ margin: '1rem 0' }}>
                <label>Evidence Required</label>
                <div style={{ padding: '0.75rem', background: 'var(--bg)', borderRadius: '4px', fontSize: '0.9rem' }}>
                  {currentQuestion.evidence_req}
                </div>
              </div>
            )}

            {currentQuestion.remediation && (
              <div style={{ margin: '1rem 0' }}>
                <label>Remediation Steps</label>
                <div style={{ padding: '0.75rem', background: 'var(--bg)', borderRadius: '4px', fontSize: '0.9rem' }}>
                  {currentQuestion.remediation}
                </div>
              </div>
            )}

            <div style={{ margin: '1rem 0' }}>
              <label>Findings / Notes</label>
              <textarea
                value={currentResponse?.findings || ''}
                onChange={e => handleFindingsChange(e.target.value)}
                style={{ width: '100%', minHeight: '100px', padding: '0.5rem', border: '1px solid var(--border)', borderRadius: '4px' }}
                placeholder="Enter your findings and observations..."
              />
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '1rem' }}>
              <div>
                <label>Responsible Party</label>
                <input
                  type="text"
                  value={currentResponse?.responsible_party || ''}
                  onChange={e => handleFieldChange('responsible_party', e.target.value)}
                  placeholder="Name or team"
                  style={{ width: '100%' }}
                />
              </div>
              <div>
                <label>Target Date</label>
                <input
                  type="date"
                  value={currentResponse?.target_date || ''}
                  onChange={e => handleFieldChange('target_date', e.target.value)}
                  style={{ width: '100%' }}
                />
              </div>
            </div>

            <div style={{ marginTop: '1rem' }}>
              <label>Remediation Status</label>
              <select
                value={currentResponse?.status || 'not_started'}
                onChange={e => handleFieldChange('status', e.target.value)}
                style={{ width: '100%' }}
              >
                <option value="not_started">Not Started</option>
                <option value="in_progress">In Progress</option>
                <option value="complete">Complete</option>
                <option value="na">N/A</option>
              </select>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}

function getScoreColor(score: number): string {
  if (score >= 75) return 'var(--accent)';
  if (score >= 50) return '#d97706';
  return '#dc2626';
}