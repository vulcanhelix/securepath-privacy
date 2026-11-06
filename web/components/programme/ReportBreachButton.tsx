'use client';
import * as React from 'react';
import { useParams, useRouter } from 'next/navigation';
import { Icon } from '@/components/ui/Icon';
import { browserClient } from '@/lib/supabase-browser';

// W2-00 mount point — FR-OPS-04 "report a breach from any screen". Server
// layouts mount this with the caller's visible client orgs; it calls
// record_breach (W1-04) under the caller's JWT — the RPC itself enforces
// visibility, resolves the jurisdiction deadline and fires the immediate
// breach_alert outbox event. W2-09 owns the full registers screen.
// W2-09: inside /programmes/[id]/… the shell-level mount preselects that
// programme's client (RLS read of programmes.client_org_id) and refreshes the
// route after a report so open register lists pick the new record up.

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
  const router = useRouter();
  const params = useParams<{ id?: string }>();
  const routeProgramme = typeof params?.id === 'string' && /^[0-9a-f-]{36}$/i.test(params.id) ? params.id : null;

  // preselect the current programme's client when no explicit default is given
  React.useEffect(() => {
    if (defaultClientId || !routeProgramme) return;
    let live = true;
    browserClient()
      .from('programmes')
      .select('client_org_id')
      .eq('id', routeProgramme)
      .maybeSingle()
      .then(({ data }) => {
        const cid = (data as { client_org_id?: string } | null)?.client_org_id;
        if (live && cid && clients.some((c) => c.id === cid)) setClientId(cid);
      });
    return () => {
      live = false;
    };
  }, [routeProgramme, defaultClientId, clients]);

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
      router.refresh();
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
