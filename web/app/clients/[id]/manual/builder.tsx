'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';

type Manual = { id: string; title: string; body: string; approval_status: string; s51_published: boolean; version: number; updated_at: string };

export default function Builder({ clientOrgId, framework, isAdvisor, canSignOff, manual }:
  { clientOrgId: string; framework: string; isAdvisor: boolean; canSignOff: boolean; manual: Manual | null }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});

  const isDraft = manual && (manual.approval_status === 'draft_ai' || manual.approval_status === 'draft_human');
  const isIssued = manual?.approval_status === 'issued';

  async function compile() {
    setBusy(true); setMsg({});
    const r = await fetch(`/api/clients/${clientOrgId}/manual/compile`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ framework }),
    });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'compile failed' }); return; }
    setMsg({ ok: 'Manual compiled — review the draft below, then sign off.' });
    router.refresh();
  }

  async function signOff() {
    if (!manual) return;
    setBusy(true); setMsg({});
    const r = await fetch(`/api/manuals/${manual.id}/signoff`, { method: 'POST' });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'sign-off failed' }); return; }
    setMsg({ ok: 'PIMS manual signed off, PAIA s.51 published, client advanced to Stage 5.' });
    router.refresh();
  }

  return (
    <>
      <div className="card">
        <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', flexWrap: 'wrap' }}>
          <h2 style={{ margin: 0 }}>Compiled manual</h2>
          {manual && (isIssued
            ? <span className="badge" style={{ color: 'var(--accent)' }}>✓ Issued{manual.s51_published ? ' · s.51 published' : ''}</span>
            : <span className="badge">Draft v{manual.version}</span>)}
          <span className="spacer" style={{ flex: 1 }} />
          {isAdvisor && !isIssued &&
            <button style={{ margin: 0 }} disabled={busy} onClick={compile}>{manual ? 'Re-compile' : 'Compile manual'}</button>}
          {canSignOff && isDraft &&
            <button style={{ margin: 0, background: 'var(--accent)' }} disabled={busy} onClick={signOff}>
              Sign off & publish (Gate 3)
            </button>}
        </div>
        {msg.err && <p className="err">{msg.err}</p>}
        {msg.ok && <p className="ok">{msg.ok}</p>}
        {manual
          ? <pre style={{ whiteSpace: 'pre-wrap', fontSize: '.82rem', marginTop: '.75rem',
                          borderTop: '1px solid var(--border)', paddingTop: '.75rem' }}>{manual.body}</pre>
          : <p className="muted" style={{ marginTop: '.5rem' }}>No manual compiled yet. Compile pulls the approved policies and confirmed registers into a 27701-aligned draft.</p>}
      </div>
    </>
  );
}
