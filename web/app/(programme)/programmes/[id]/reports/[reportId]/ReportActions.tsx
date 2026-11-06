'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Textarea } from '@/components/ui/forms';
import type { ReportStatus } from '@/lib/monthly-report';

// W2-08 — FR-RPT-04 state actions. Which buttons render is decided by the
// server-side predicates the page resolved (has_programme_role,
// is_ao_or_alternate); transition_report / create_report_correction re-check
// everything, and the existing triggers (legal edge, AO-sign, FR-MNT-07
// maintenance gate) refuse with their own reason — shown verbatim here.

export function ReportActions({
  programmeId,
  reportId,
  status,
  isLatest,
  canWrite,
  isAoOrAlternate,
  isAccountableOfficer,
  maintenanceOpen,
}: {
  programmeId: string;
  reportId: string;
  status: ReportStatus;
  isLatest: boolean;
  canWrite: boolean;
  isAoOrAlternate: boolean;
  isAccountableOfficer: boolean;
  maintenanceOpen: number;
}) {
  const router = useRouter();
  const [busy, setBusy] = React.useState(false);
  const [note, setNote] = React.useState('');
  const [reason, setReason] = React.useState('');
  const [err, setErr] = React.useState<string | null>(null);

  async function go(to: ReportStatus, opts: { note?: string; reason?: string } = {}) {
    setBusy(true);
    setErr(null);
    const { error } = await browserClient().rpc('transition_report', {
      p_report_id: reportId,
      p_to_state: to,
      p_note: opts.note?.trim() || null,
      p_gate_override_reason: opts.reason?.trim() || null,
    });
    setBusy(false);
    if (error) return setErr(error.message);
    setNote('');
    setReason('');
    router.refresh();
  }

  async function correct() {
    setBusy(true);
    setErr(null);
    const { data, error } = await browserClient().rpc('create_report_correction', {
      p_report_id: reportId,
      p_reason: note.trim(),
    });
    setBusy(false);
    if (error) return setErr(error.message);
    router.push(`/programmes/${programmeId}/reports/${data as string}`);
    router.refresh();
  }

  const canSubmit = canWrite || isAccountableOfficer;
  const canReturn = canWrite || isAoOrAlternate;
  const canIssue = canWrite || isAoOrAlternate;

  let body: React.ReactNode = null;
  if (status === 'draft') {
    body = canWrite ? (
      <Button size="sm" icon="check" disabled={busy} onClick={() => go('inputs_complete')}>
        Mark inputs complete
      </Button>
    ) : null;
  } else if (status === 'inputs_complete') {
    body = (
      <>
        {canSubmit && maintenanceOpen > 0 && canWrite ? (
          <label className="sp-breach-field">
            Maintenance gate reason ({maintenanceOpen} feeding task{maintenanceOpen === 1 ? '' : 's'} open — prints in the report)
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} style={{ minHeight: 60 }} />
          </label>
        ) : null}
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {canSubmit ? (
            <Button size="sm" icon="send" disabled={busy} onClick={() => go('ao_review', { reason })}>
              Submit for AO review
            </Button>
          ) : null}
          {canWrite ? (
            <Button size="sm" variant="outline" disabled={busy} onClick={() => go('draft')}>
              Back to draft
            </Button>
          ) : null}
        </div>
      </>
    );
  } else if (status === 'ao_review') {
    body = (
      <>
        {canReturn ? (
          <label className="sp-breach-field">
            Note (required to return; optional on signing)
            <Textarea value={note} onChange={(e) => setNote(e.target.value)} style={{ minHeight: 60 }} />
          </label>
        ) : null}
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {isAoOrAlternate ? (
            <Button size="sm" icon="pen-line" disabled={busy} onClick={() => go('signed', { note })}>
              Sign report
            </Button>
          ) : null}
          {canReturn ? (
            <Button size="sm" variant="outline" disabled={busy} onClick={() => go('inputs_complete', { note })}>
              Return for changes
            </Button>
          ) : null}
        </div>
      </>
    );
  } else if (status === 'signed') {
    body = canIssue ? (
      <Button size="sm" icon="send" disabled={busy} onClick={() => go('issued')}>
        Issue report
      </Button>
    ) : null;
  } else if (status === 'issued') {
    body =
      canWrite && isLatest ? (
        <>
          <label className="sp-breach-field">
            Correction reason — opens a new version; this issued report stays unchanged
            <Textarea value={note} onChange={(e) => setNote(e.target.value)} style={{ minHeight: 60 }} />
          </label>
          <div>
            <Button size="sm" variant="outline" icon="file-plus" disabled={busy || !note.trim()} onClick={correct}>
              Open correction
            </Button>
          </div>
        </>
      ) : null;
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      {body ?? (
        <p className="muted" style={{ margin: 0, fontSize: 'var(--fs-sm)' }}>
          {status === 'issued'
            ? 'Issued — read-only.'
            : 'No action available to your role at this stage.'}
        </p>
      )}
      {err ? <p className="sp-breach-msg is-err">{err}</p> : null}
    </div>
  );
}
