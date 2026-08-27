'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';

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
    <Card
      title="Compiled manual"
      pad={0}
      action={
        <span style={{ display: 'inline-flex', gap: 10, alignItems: 'center' }}>
          {isAdvisor && !isIssued && (
            <Button size="sm" variant="secondary" disabled={busy} onClick={compile}>
              {manual ? 'Re-compile' : 'Compile manual'}
            </Button>
          )}
          {canSignOff && isDraft && (
            <Button size="sm" disabled={busy} onClick={signOff} cta>
              Sign off &amp; publish (Gate 3)
            </Button>
          )}
        </span>
      }
    >
      <div style={{ padding: '16px 28px', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', borderBottom: manual ? '1px solid var(--border)' : 'none' }}>
        {manual ? (
          <>
            {isIssued ? <Badge tone="ink">Issued</Badge> : <Badge tone={manual.approval_status === 'draft_ai' ? 'warn' : 'neutral'} dot>{manual.approval_status === 'draft_ai' ? 'Draft (AI)' : 'Draft'}</Badge>}
            {manual.s51_published && <Badge tone="pass" dot>s.51 published</Badge>}
            <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>v{manual.version}</span>
            <span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--faint)' }}>
              updated {new Date(manual.updated_at).toLocaleString()}
            </span>
          </>
        ) : null}
      </div>
      <div style={{ padding: manual ? '0 28px 24px' : 0 }}>
        {msg.err && <Alert tone="err">{msg.err}</Alert>}
        {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
        {manual ? (
          <pre className="mono" style={{ whiteSpace: 'pre-wrap', fontSize: 'var(--fs-xs)', lineHeight: 1.6, color: 'var(--text-2)', marginTop: 16 }}>
            {manual.body}
          </pre>
        ) : (
          <EmptyState
            icon="book-open"
            message="No manual compiled yet. Compile pulls the approved policies and confirmed registers into a 27701-aligned draft."
          />
        )}
      </div>
    </Card>
  );
}
