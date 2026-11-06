'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Input } from '@/components/ui/forms';

// W2-08 — start (or open) the report for a month. create_monthly_report is
// idempotent per programme + period: an existing report is simply returned.
// It refuses before the period's §9.5 snapshot day; the message is shown and
// nothing is written.

const lastMonth = () => {
  const d = new Date();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() - 1);
  return d.toISOString().slice(0, 7);
};

export function CreateReportForm({ programmeId }: { programmeId: string }) {
  const router = useRouter();
  const [period, setPeriod] = React.useState(lastMonth());
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    const { data, error } = await browserClient().rpc('create_monthly_report', {
      p_programme_id: programmeId,
      p_period: period,
    });
    setBusy(false);
    if (error) return setErr(error.message);
    router.push(`/programmes/${programmeId}/reports/${data as string}`);
    router.refresh();
  }

  return (
    <form onSubmit={submit} style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
      <Input
        type="month"
        value={period}
        onChange={(e) => setPeriod(e.target.value)}
        required
        aria-label="Report period"
        style={{ width: 180 }}
      />
      <Button type="submit" size="sm" icon="file-plus" disabled={busy || !period}>
        {busy ? 'Opening…' : 'Create or open report'}
      </Button>
      <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
        Figures are locked to the month-end snapshot.
      </span>
      {err ? <p className="sp-breach-msg is-err" style={{ flexBasis: '100%' }}>{err}</p> : null}
    </form>
  );
}
