'use client';
import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Textarea, Checkbox, Field } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';
import { Icon } from '@/components/ui/Icon';
import { Badge } from '@/components/ui/Badge';

// W2-06 — review actions for the evidence queues (spec §8.4 screen 03).
// All decisions go through the W1-02 RPCs under the caller's JWT — the RPCs
// re-check every gate (role, self-review FR-ACC-01, AO/alternate FR-ACC-02,
// AO-led-work FR-EVD-07); this component only collects verdict + reasons.

export type QueueItem = {
  id: string;
  activity_id: string | null;
  register_item_id: string | null;
  site: string | null;
  file_key: string | null;
  link: string | null;
  note: string | null;
  uploaded_by: string | null;
  uploaded_at: string;
  activity_ref: string | null;
  register_ref: string | null;
  requires_alternate?: boolean;
};

// FR-EVD-03 — the verification checklist (UI aid; verify_evidence is the gate)
const VERIFY_CHECKS = [
  'Shows the control operating',
  'Covers the required sites',
  'Dated within the activity window',
];

const fmt = (iso: string) => new Date(iso).toLocaleString();

export function ReviewCard({
  item,
  mode,
  canAct,
  uploaderName,
  base,
}: {
  item: QueueItem;
  mode: 'verify' | 'accept';
  /** caller may act at this stage (caller_can_verify / caller_is_ao_or_alternate) */
  canAct: boolean;
  uploaderName?: string;
  /** /programmes/<id> — links to the evidence detail page */
  base: string;
}) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [checks, setChecks] = useState<boolean[]>(VERIFY_CHECKS.map(() => false));
  const [comment, setComment] = useState('');
  const [showComment, setShowComment] = useState(false);

  const allChecked = checks.every(Boolean);

  async function run(fn: () => PromiseLike<{ error: { message: string } | null; data?: unknown }>) {
    setBusy(true);
    setMsg({});
    const { error, data } = await fn();
    setBusy(false);
    if (error) {
      setMsg({ err: error.message });
      return null;
    }
    router.refresh();
    return data;
  }

  async function approve() {
    if (mode === 'verify') {
      await run(() =>
        browserClient().rpc('verify_evidence', {
          p_evidence_id: item.id,
          p_verdict: 'approved',
          p_comment: comment.trim() || null,
        })
      );
    } else {
      const res = await run(() =>
        browserClient().rpc('accept_evidence', { p_evidence_id: item.id })
      );
      if (res) {
        const r = res as { evidence_ref?: string };
        setMsg({ ok: `Accepted — evidence ref ${r?.evidence_ref ?? ''}`.trim() });
      }
    }
  }

  async function sendBack() {
    if (!comment.trim()) {
      setMsg({ err: 'Returning evidence requires a reason (FR-EVD-05).' });
      return;
    }
    if (mode === 'verify') {
      await run(() =>
        browserClient().rpc('verify_evidence', {
          p_evidence_id: item.id,
          p_verdict: 'returned',
          p_comment: comment.trim(),
        })
      );
    } else {
      await run(() =>
        browserClient().rpc('return_evidence', {
          p_evidence_id: item.id,
          p_reasons: [comment.trim()],
        })
      );
    }
  }

  return (
    <div style={{ borderTop: '1px solid var(--border)', padding: '16px 0' }}>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center' }}>
        {item.activity_ref ? <Badge tone="accent" dot>{item.activity_ref}</Badge> : null}
        {item.register_ref ? <Badge tone="warn" dot>{item.register_ref}</Badge> : null}
        {item.site ? <span className="muted">{item.site}</span> : null}
        <span style={{ flex: 1 }} />
        <span className="muted">
          {uploaderName ? `${uploaderName} · ` : ''}
          {fmt(item.uploaded_at)}
        </span>
        <Link href={`${base}/evidence/${item.id}`} className="muted" style={{ whiteSpace: 'nowrap' }}>
          Detail →
        </Link>
      </div>

      {item.note ? <p style={{ margin: '8px 0 0', fontSize: 'var(--fs-sm)' }}>{item.note}</p> : null}

      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', marginTop: 8, fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
        {item.file_key ? (
          <a href={`/api/evidence/${item.id}`} style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
            <Icon name="paperclip" size={13} /> file
          </a>
        ) : null}
        {item.link ? (
          <a href={item.link} target="_blank" rel="noreferrer" style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
            <Icon name="link" size={13} /> link
          </a>
        ) : null}
      </div>

      {mode === 'verify' && canAct ? (
        <div style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 6 }}>
          {VERIFY_CHECKS.map((c, i) => (
            <Checkbox
              key={c}
              label={c}
              checked={checks[i]}
              disabled={busy}
              onChange={(e) =>
                setChecks((prev) => prev.map((v, j) => (j === i ? e.target.checked : v)))
              }
            />
          ))}
        </div>
      ) : null}

      {mode === 'accept' && item.requires_alternate ? (
        <Alert tone="info">
          You led this work — the acceptance decision goes to a named alternate (FR-EVD-07).
        </Alert>
      ) : null}

      {canAct ? (
        <>
          {showComment ? (
            <Field label={mode === 'verify' ? 'Comment / return reason' : 'Reason (mandatory when returning)'}>
              <Textarea
                value={comment}
                onChange={(e) => setComment(e.target.value)}
                placeholder={
                  mode === 'verify'
                    ? 'Optional on approve — required to return to the uploader'
                    : 'Written to the review ledger — required when returning'
                }
                style={{ minHeight: 72 }}
              />
            </Field>
          ) : null}
          {msg.err ? <Alert tone="err">{msg.err}</Alert> : null}
          {msg.ok ? <Alert tone="ok">{msg.ok}</Alert> : null}
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', marginTop: 12 }}>
            <Button
              size="sm"
              icon={mode === 'verify' ? 'check' : 'badge-check'}
              disabled={busy || (mode === 'verify' && !allChecked) || (mode === 'accept' && !!item.requires_alternate)}
              onClick={approve}
            >
              {mode === 'verify' ? 'Approve' : 'Accept'}
            </Button>
            <Button size="sm" variant="secondary" icon="undo-2" disabled={busy} onClick={sendBack}>
              Return
            </Button>
            {!showComment ? (
              <Button size="sm" variant="ghost" icon="message-square" disabled={busy} onClick={() => setShowComment(true)}>
                {mode === 'verify' ? 'Comment' : 'Reason'}
              </Button>
            ) : null}
          </div>
        </>
      ) : (
        <p className="muted" style={{ marginTop: 10 }}>
          {mode === 'verify'
            ? 'Only the programme lead or partner consultant verifies evidence (FR-EVD-03).'
            : 'Only the accountable officer or a named alternate accepts evidence (FR-ACC-02).'}
        </p>
      )}
    </div>
  );
}

export function ReviewQueue({
  items,
  mode,
  canAct,
  names,
  base,
}: {
  items: QueueItem[];
  mode: 'verify' | 'accept';
  canAct: boolean;
  names: Record<string, string>;
  base: string;
}) {
  return (
    <div>
      {items.map((it) => (
        <ReviewCard
          key={it.id}
          item={it}
          mode={mode}
          canAct={canAct}
          uploaderName={it.uploaded_by ? names[it.uploaded_by] : undefined}
          base={base}
        />
      ))}
    </div>
  );
}
