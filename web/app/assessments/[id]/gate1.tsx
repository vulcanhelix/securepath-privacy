'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { GatePanel } from '@/components/ui/GatePanel';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';

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
    <>
      <GatePanel
        title="Gate 1 — advisor sign-off"
        passed={approved}
        badges={
          <>
            {!approved && <Badge tone="warn" dot>Awaiting sign-off</Badge>}
            {stage !== null && <Badge><span className="mono">Privacy track · Stage {stage}</span></Badge>}
          </>
        }
        action={
          approved ? (
            <a href={`/clients/${clientOrgId}/documents`}>
              <Button size="sm" cta>Go to Stage 2 — Document intake</Button>
            </a>
          ) : isAdvisor ? (
            <Button size="sm" disabled={busy} onClick={signOff}>
              {busy ? 'Signing off…' : 'Sign off & advance to Stage 2'}
            </Button>
          ) : (
            <span className="muted">An advisor must sign this off.</span>
          )
        }
      >
        Signing off approves the scored assessment as the baseline and moves this client into document intake. The transition is logged.
      </GatePanel>
      {err && <Alert tone="err">{err}</Alert>}
    </>
  );
}
