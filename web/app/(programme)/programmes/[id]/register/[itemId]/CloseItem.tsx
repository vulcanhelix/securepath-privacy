'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Checkbox } from '@/components/ui/forms';

// W2-16 — §9.4 closure ritual. Rendered only for the AO / named alternate
// (server checked is_ao_or_alternate). The ONLY write is close_register_item
// under the caller's JWT; it re-checks authz (T5) and the data preconditions
// (can_close_register_item + both closure triggers). On refusal its message —
// which carries the closure reason — is shown verbatim and nothing is written.
// Readiness is never evaluated here.

export function CloseItem({
  itemId,
  itemRef,
  hasAcceptanceRecord,
  acceptedRefs,
}: {
  itemId: string;
  itemRef: string;
  /** the item already carries accepted_evidence_refs */
  hasAcceptanceRecord: boolean;
  /** EV refs minted on accepted (decided) evidence for this finding */
  acceptedRefs: string[];
}) {
  const router = useRouter();
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);
  const [ok, setOk] = React.useState<string | null>(null);
  const [confirm, setConfirm] = React.useState(false);
  const [refs, setRefs] = React.useState<string[]>([]);

  const toggle = (r: string) => setRefs((p) => (p.includes(r) ? p.filter((x) => x !== r) : [...p, r]));

  async function close() {
    setBusy(true);
    setErr(null);
    setOk(null);
    const { error } = await browserClient().rpc('close_register_item', {
      p_item_id: itemId,
      p_evidence_refs: refs.length ? refs : null,
    });
    setBusy(false);
    if (error) {
      setErr(
        error.code === 'PGRST202' || error.code === '42883'
          ? 'close_register_item is not available on this environment (migration 20261106000008 not applied) — nothing was changed.'
          : error.message || 'close_register_item failed — nothing was changed.'
      );
      return;
    }
    setOk(`${itemRef} closed.`);
    setConfirm(false);
    router.refresh();
  }

  return (
    <div style={{ marginTop: 14, borderTop: '1px solid var(--border, #e5e5e5)', paddingTop: 14 }}>
      {err ? <Alert tone="err">{`Close refused: ${err}`}</Alert> : null}
      {ok ? <Alert tone="ok">{ok}</Alert> : null}
      {!hasAcceptanceRecord && acceptedRefs.length ? (
        <div style={{ marginBottom: 10 }}>
          <div className="muted" style={{ fontSize: 'var(--fs-xs)', marginBottom: 4 }}>
            Cite accepted evidence for the acceptance record (optional — stamped with the close):
          </div>
          {acceptedRefs.map((r) => (
            <Checkbox key={r} label={<span className="mono">{r}</span>} checked={refs.includes(r)} onChange={() => toggle(r)} />
          ))}
        </div>
      ) : null}
      {confirm ? (
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ fontSize: 'var(--fs-sm)' }}>Close {itemRef} as accountable officer?</span>
          <Button size="sm" icon="check" onClick={close} disabled={busy}>
            {busy ? 'Closing…' : 'Confirm close'}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setConfirm(false)} disabled={busy}>
            Cancel
          </Button>
        </div>
      ) : (
        <Button size="sm" variant="outline" icon="lock" onClick={() => setConfirm(true)}>
          Close finding
        </Button>
      )}
    </div>
  );
}
