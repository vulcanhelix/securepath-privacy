'use client';
import * as React from 'react';
import { Icon } from '@/components/ui/Icon';
import { browserClient } from '@/lib/supabase-browser';

// W2-00 mount point — FR-OPS-04 "report a breach from any screen". Server
// layouts mount this with the caller's visible client orgs; it calls
// record_breach (W1-04) under the caller's JWT — the RPC itself enforces
// visibility, resolves the jurisdiction deadline and fires the immediate
// breach_alert outbox event. W2-09 owns the full registers screen.

export interface BreachClient {
  id: string;
  name: string;
}

export function ReportBreachButton({
  clients,
  defaultClientId,
}: {
  clients: BreachClient[];
  defaultClientId?: string | null;
}) {
  const [open, setOpen] = React.useState(false);
  const [clientId, setClientId] = React.useState(defaultClientId ?? clients[0]?.id ?? '');
  const [summary, setSummary] = React.useState('');
  const [occurredOn, setOccurredOn] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [result, setResult] = React.useState<{ ok: boolean; msg: string } | null>(null);

  if (!clients.length) return null;

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!clientId || !summary.trim()) return;
    setBusy(true);
    setResult(null);
    const { error } = await browserClient().rpc('record_breach', {
      p_client_org: clientId,
      p_occurred_on: occurredOn ? new Date(occurredOn).toISOString() : null,
      p_summary: summary.trim(),
    });
    setBusy(false);
    if (error) setResult({ ok: false, msg: error.message });
    else {
      setResult({ ok: true, msg: 'Breach reported — the accountable officer has been alerted.' });
      setSummary('');
      setOccurredOn('');
    }
  }

  return (
    <span className="sp-breach">
      <button
        type="button"
        className="sp-btn sp-btn--danger sp-btn--sm"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
      >
        <Icon name="siren" size={14} />
        <span>Report a breach</span>
      </button>
      {open ? (
        <form className="sp-breach-pop" onSubmit={submit}>
          {clients.length > 1 || !defaultClientId ? (
            <label className="sp-breach-field">
              <span>Client</span>
              <select className="sp-select" value={clientId} onChange={(e) => setClientId(e.target.value)}>
                {clients.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
            </label>
          ) : null}
          <label className="sp-breach-field">
            <span>Suspected on</span>
            <input
              className="sp-input"
              type="datetime-local"
              value={occurredOn}
              onChange={(e) => setOccurredOn(e.target.value)}
            />
          </label>
          <label className="sp-breach-field">
            <span>What happened?</span>
            <textarea
              className="sp-textarea"
              required
              minLength={1}
              placeholder="Describe the suspected breach…"
              value={summary}
              onChange={(e) => setSummary(e.target.value)}
              style={{ minHeight: 72 }}
            />
          </label>
          <div className="sp-breach-actions">
            <button type="submit" className="sp-btn sp-btn--danger sp-btn--sm" disabled={busy || !summary.trim()}>
              {busy ? 'Reporting…' : 'Submit report'}
            </button>
            <button type="button" className="sp-btn sp-btn--ghost sp-btn--sm" onClick={() => setOpen(false)}>
              Cancel
            </button>
          </div>
          {result ? (
            <p className={'sp-breach-msg ' + (result.ok ? 'is-ok' : 'is-err')}>{result.msg}</p>
          ) : null}
        </form>
      ) : null}
    </span>
  );
}
