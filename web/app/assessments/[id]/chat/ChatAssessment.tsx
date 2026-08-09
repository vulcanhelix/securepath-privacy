'use client';

import { useEffect, useRef, useState } from 'react';
import { browserVoice } from '@/lib/ai/voice';

type Turn = { id?: string; role: string; kind: string; content: string; question_id?: string; evidence_req?: string | null };
type Phase = 'answer' | 'gap_details' | 'owner' | 'target_date' | 'evidence';
type Next = { id: string; section_id: number; section_name: string; question: string; why_matters?: string; evidence_req?: string; risk: string; prompt?: string; phase?: Phase };

const placeholders: Record<Phase, string> = {
  answer: 'Type an answer or ask a question…',
  gap_details: 'Describe what is in place and what is missing…',
  owner: 'Name the person, role, or team that owns this control…',
  target_date: 'Target date, e.g. 2026-09-30…',
  evidence: 'Upload a file below, or say “no” to move on…',
};

export default function ChatAssessment({ assessmentId }: { assessmentId: string }) {
  const [turns, setTurns] = useState<Turn[]>([]);
  const [next, setNext] = useState<Next | null>(null);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [voice, setVoice] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [canWrite, setCanWrite] = useState(true);
  const [documents, setDocuments] = useState<Array<{ id: string; original_filename: string; size: number; question_id: string | null; question?: string }>>([]);
  const [progress, setProgress] = useState({ question_number: 0, question_total: 0, module_number: 0, module_total: 0 });
  const fileRef = useRef<HTMLInputElement>(null);
  const endRef = useRef<HTMLDivElement>(null);

  async function load() {
    const r = await fetch(`/api/assessments/${assessmentId}/chat`);
    const data = await r.json().catch(() => null);
    if (r.ok && data) {
      setTurns(data.turns);
      setNext(data.next);
      setDocuments(data.documents ?? []);
      setProgress(data.progress ?? progress);
      setCanWrite(data.can_write !== false);
      setError(null);
    } else {
      setError(data?.error ?? 'Could not load this conversation.');
    }
    setLoading(false);
  }
  useEffect(() => { load(); }, [assessmentId]);
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [turns]);

  async function send(content: string, extra: Record<string, string> = {}) {
    if (!content.trim() || sending) return;
    setSending(true);
    setInput('');
    setError(null);
    const r = await fetch(`/api/assessments/${assessmentId}/chat`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ content, question_id: next?.id, ...extra }) });
    const data = await r.json().catch(() => null);
    if (r.ok && data) {
      setTurns(old => [...old, { role: 'user', kind: 'answer', content }, ...data.turns]);
      setNext(data.next);
      setDocuments(data.documents ?? documents);
      setProgress(data.progress ?? progress);
      if (voice && data.turns[0]?.content) browserVoice.speak(data.turns[0].content);
    } else {
      if (r.status === 403) setCanWrite(false);
      setError(data?.error ?? 'Your message could not be sent. Please try again.');
    }
    setSending(false);
  }
  async function upload(file: File) {
    setUploading(true);
    setError(null);
    const form = new FormData();
    form.set('file', file);
    if (next?.id) form.set('question_id', next.id);
    const r = await fetch(`/api/assessments/${assessmentId}/documents`, { method: 'POST', body: form });
    if (r.ok) await load();
    else setError((await r.json().catch(() => null))?.error ?? 'That file could not be uploaded.');
    setUploading(false);
  }
  const sections = next ? `Module ${next.section_id} · ${next.section_name}` : 'Assessment wrap-up';
  const phase: Phase = next?.phase ?? 'answer';
  const disabled = sending || !canWrite;
  if (loading) return <div className="card"><p>Opening your assessment conversation…</p></div>;
  return (
    <div className="chat-shell">
      <header className="chat-progress"><div><strong>Question {progress.question_number} of {progress.question_total} · Module {progress.module_number} of {progress.module_total}</strong><span className="muted">{sections} · Answer at your own pace. Ask “explain” at any time.</span></div><button className="secondary-button" onClick={() => setVoice(v => !v)}>{voice ? 'Voice on' : 'Voice off'}</button></header>
      <div className="chat-transcript">
        {turns.map((turn, i) => <div className={`chat-turn ${turn.role}`} key={turn.id ?? `${turn.content}-${i}`}><div className="chat-avatar">{turn.role === 'assistant' ? 'S' : 'You'}</div><div><div className="chat-bubble">{turn.content}</div>{turn.kind === 'proposal' && i === turns.length - 1 && <div className="quick-replies proposal-replies"><button onClick={() => send("Yes, that's right")} disabled={disabled}>Yes, that’s right</button><button className="secondary-button" onClick={() => send('No, let me rephrase')} disabled={disabled}>No, let me rephrase</button></div>}{turn.kind === 'question' && turn.evidence_req && <small className="muted">Evidence can help: {turn.evidence_req}</small>}</div></div>)}
        <div ref={endRef} />
      </div>
      {!canWrite && <p className="chat-notice">You have read-only access to this assessment. You can follow the conversation, but not add to it.</p>}
      {error && <p className="chat-error" role="alert">{error}</p>}
      {next ? <><div className="quick-replies">{phase === 'answer' ? <><button onClick={() => send('fully_compliant')} disabled={disabled}>Fully compliant</button><button onClick={() => send('partial')} disabled={disabled}>Partially compliant</button><button onClick={() => send('non_compliant')} disabled={disabled}>Not compliant</button><button onClick={() => send('na')} disabled={disabled}>Not applicable</button></> : phase === 'evidence' ? <button className="secondary-button" onClick={() => send('No, not right now')} disabled={disabled}>No evidence right now</button> : <button className="secondary-button" onClick={() => send('skip')} disabled={disabled}>Skip this step</button>}<button className="secondary-button" onClick={() => send('Explain that')} disabled={disabled}>Explain</button><button className="secondary-button" onClick={() => send('Give me an example')} disabled={disabled}>Example</button></div><div className="chat-composer"><textarea value={input} onChange={e => setInput(e.target.value)} onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(input); } }} placeholder={canWrite ? placeholders[phase] : 'Read-only access'} disabled={disabled} /><button onClick={() => send(input)} disabled={disabled || !input.trim()}>Send</button></div><div className="upload-strip" onDragOver={e => e.preventDefault()} onDrop={e => { e.preventDefault(); if (!canWrite) return; const file = e.dataTransfer.files[0]; if (file) upload(file); }}><span>{uploading ? 'Uploading…' : 'Drop supporting evidence here, or'}</span><button className="secondary-button" onClick={() => fileRef.current?.click()} disabled={uploading || !canWrite}>Choose a file</button><input ref={fileRef} type="file" hidden onChange={e => { const file = e.target.files?.[0]; if (file) upload(file); }} /></div></> : <div className="chat-complete"><h2>Assessment complete</h2><p>Your deterministic score and full remediation list are available in the <a href={`/assessments/${assessmentId}`}>grid editor</a>.</p></div>}
      {!!documents.length && <aside className="chat-documents"><strong>Evidence attached</strong>{documents.map(document => <a key={document.id} href={`/api/assessments/${assessmentId}/documents/${document.id}`} target="_blank" rel="noreferrer">{document.original_filename} <span className="muted">({Math.ceil(document.size / 1024)} KB){document.question ? ` · ${document.question}` : ''}</span></a>)}</aside>}
    </div>
  );
}
