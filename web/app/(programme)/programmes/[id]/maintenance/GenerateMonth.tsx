'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';

// W2-10 — FR-MNT-02 "generate this month". generate_maintenance_month is
// idempotent (UNIQUE task_template_id+period) and returns the count of NEW
// instances; due dates/windows are resolved server-side from timing rules.
// The RPC re-checks can_run_cadence — this button is a UI hint only.

export function GenerateMonth({
  programmeId,
  month,
  label,
}: {
  programmeId: string;
  month: string; // 'YYYY-MM'
  label: string;
}) {
  const router = useRouter();
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});

  async function run() {
    setBusy(true);
    setMsg({});
    const { data, error } = await browserClient().rpc('generate_maintenance_month', {
      p_programme: programmeId,
      p_month: `${month}-01`,
    });
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    const n = typeof data === 'number' ? data : Number(data ?? 0);
    setMsg({
      ok:
        n === 0
          ? `No new tasks — ${label} was already generated (or no template is active yet).`
          : `${n} new task${n === 1 ? '' : 's'} generated for ${label}.`,
    });
    router.refresh();
  }

  return (
    <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
      <Button size="sm" icon="refresh-cw" disabled={busy} onClick={run}>
        {busy ? 'Generating…' : `Generate ${label}`}
      </Button>
      <span className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
        Safe to re-run — existing tasks are kept; only missing ones are created. Active-from rules are respected.
      </span>
      {msg.err ? <p className="sp-breach-msg is-err" style={{ width: '100%' }}>{msg.err}</p> : null}
      {msg.ok ? <p className="sp-breach-msg is-ok" style={{ width: '100%' }}>{msg.ok}</p> : null}
    </div>
  );
}
