'use client';
import { useEffect, useState } from 'react';

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

interface Score {
  section_scores: any;
  overall_score: {
    score: number;
    total: number;
    pct: number;
    rating: string;
  };
  completion_pct: number;
  risk_summary: any;
  critical_gaps: number;
}

interface AssessmentEditorProps {
  assessmentId: string;
}

export default function AssessmentEditor({ assessmentId }: AssessmentEditorProps) {
  const [questions, setQuestions] = useState<Question[]>([]);
  const [responses, setResponses] = useState<Map<string, Response>>(new Map());
  const [currentSection, setCurrentSection] = useState<number>(1);
  const [currentQuestionId, setCurrentQuestionId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [score, setScore] = useState<Score | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadAssessmentData();
  }, [assessmentId]);

  async function loadAssessmentData() {
    setLoading(true);
    try {
      const [questionsRes, responsesRes, scoreRes] = await Promise.all([
        fetch('/api/assessment/questions').then(r => r.json()),
        fetch(`/api/assessments/${assessmentId}/responses`).then(r => r.json()),
        fetch(`/api/assessments/${assessmentId}/score`).then(r => r.json()),
      ]);

      setQuestions(questionsRes);
      const responseMap = new Map<string, Response>(responsesRes.map((r: Response) => [r.question_id, r]));
      setResponses(responseMap);
      setScore(scoreRes);
      
      if (questionsRes.length > 0) {
        setCurrentQuestionId(questionsRes[0].id);
      }
    } catch (error) {
      console.error('Failed to load assessment data:', error);
    } finally {
      setLoading(false);
    }
  }

  const currentQuestion = questions.find(q => q.id === currentQuestionId);
  const currentResponse = currentQuestionId ? responses.get(currentQuestionId) : null;

  const handleResponseChange = async (response: string) => {
    if (!currentQuestionId) return;
    
    setSaving(true);
    const updatedResponses = new Map(responses);
    updatedResponses.set(currentQuestionId, {
      ...updatedResponses.get(currentQuestionId)!,
      response,
    });
    setResponses(updatedResponses);

    try {
      await fetch(`/api/assessments/${assessmentId}/responses`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          question_id: currentQuestionId,
          response,
          findings: currentResponse?.findings || '',
          status: 'in_progress',
        }),
      });

      // Refresh score
      const scoreRes = await fetch(`/api/assessments/${assessmentId}/score`).then(r => r.json());
      setScore(scoreRes);
    } catch (error) {
      console.error('Failed to save response:', error);
    } finally {
      setSaving(false);
    }
  };

  const handleFindingsChange = async (findings: string) => {
    if (!currentQuestionId) return;
    
    const updatedResponses = new Map(responses);
    updatedResponses.set(currentQuestionId, {
      ...updatedResponses.get(currentQuestionId)!,
      findings,
    });
    setResponses(updatedResponses);

    try {
      await fetch(`/api/assessments/${assessmentId}/responses`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          question_id: currentQuestionId,
          response: currentResponse?.response || 'na',
          findings,
          status: currentResponse?.status || 'not_started',
        }),
      });
    } catch (error) {
      console.error('Failed to save findings:', error);
    }
  };

  const sectionQuestions = questions.filter(q => q.section_id === currentSection);

  if (loading) {
    return <div className="card"><p>Loading assessment...</p></div>;
  }

  if (!currentQuestion) {
    return <div className="card"><p>No questions found</p></div>;
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '280px 1fr', gap: '1rem' }}>
      {/* Left Panel - Navigation */}
      <div className="card" style={{ padding: '1rem' }}>
        <h3>Sections</h3>
        {[1, 2, 3, 4, 5, 6].map(sectionId => (
          <button
            key={sectionId}
            onClick={() => setCurrentSection(sectionId)}
            style={{
              display: 'block',
              width: '100%',
              padding: '0.5rem',
              margin: '0.25rem 0',
              background: currentSection === sectionId ? 'var(--accent)' : 'transparent',
              color: currentSection === sectionId ? 'white' : 'var(--text)',
              border: '1px solid var(--border)',
              borderRadius: '4px',
              cursor: 'pointer',
            }}
          >
            Section {sectionId}
          </button>
        ))}
        
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
            <div style={{ fontSize: '2rem', fontWeight: 700, color: 'var(--accent)' }}>
              {score.overall_score?.pct || 0}%
            </div>
            <div style={{ fontSize: '0.75rem', color: 'var(--muted)' }}>
              {score.overall_score?.rating || 'In Progress'}
            </div>
            <div style={{ fontSize: '0.7rem', marginTop: '0.5rem' }}>
              {score.completion_pct || 0}% complete
            </div>
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
              {['fully_compliant', 'partial', 'non_compliant', 'na'].map(response => (
                <button
                  key={response}
                  onClick={() => handleResponseChange(response)}
                  style={{
                    padding: '0.75rem 1rem',
                    border: '2px solid',
                    borderRadius: '6px',
                    background: currentResponse?.response === response ? 'var(--accent)' : 'white',
                    color: currentResponse?.response === response ? 'white' : 'var(--text)',
                    borderColor: currentResponse?.response === response ? 'var(--accent)' : 'var(--border)',
                    cursor: 'pointer',
                    fontWeight: 600,
                    fontSize: '0.9rem',
                  }}
                >
                  {response === 'fully_compliant' && '✓ Fully Compliant'}
                  {response === 'partial' && '◑ Partially Compliant'}
                  {response === 'non_compliant' && '✗ Non-Compliant'}
                  {response === 'na' && 'N/A'}
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
        </div>
      </div>
    </div>
  );
}