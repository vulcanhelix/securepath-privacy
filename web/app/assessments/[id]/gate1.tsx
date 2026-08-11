'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

// Gate 1 — advisor signs off the assessment; the client's privacy track advances to Stage 2.
export default function Gate1({ sessionId, clientOrgId, approved, stage, isAdvisor }:
  { sessionId: string; clientOrgId: string; approved: boolean; stage: number | null; isAdvisor: boolean }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  async function signOff() {
    setBusy(true); setErr('');
    const { error } = await browserClient().rpc('sign_off_assessment', { p_session_id: sessionId });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    router.refresh();
  }

  return (
    <div className="card" style={{ borderLeft: '3px solid var(--accent)' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', flexWrap: 'wrap' }}>
        <strong>Gate 1 — advisor sign-off</strong>
        {approved
          ? <span className="badge" style={{ background: 'var(--accent-soft, #e3efe9)', color: 'var(--accent)' }}>✓ Signed off</span>
          : <span className="badge">Draft — awaiting sign-off</span>}
        {stage !== null && <span className="badge">Privacy track · Stage {stage}</span>}
        <span className="spacer" style={{ flex: 1 }} />
        {approved
          ? <a href={`/clients/${clientOrgId}/documents`}><button style={{ margin: 0 }}>Go to Stage 2 — Document intake →</button></a>
          : isAdvisor
            ? <button style={{ margin: 0 }} disabled={busy} onClick={signOff}>{busy ? 'Signing off…' : 'Sign off & advance to Stage 2'}</button>
            : <span className="muted">An advisor must sign this off.</span>}
      </div>
      <p className="muted" style={{ marginBottom: 0, marginTop: '.6rem' }}>
        Signing off approves the scored assessment as the baseline and moves this client into document intake. The transition is logged.
      </p>
      {err && <p className="err">{err}</p>}
    </div>
  );
}
