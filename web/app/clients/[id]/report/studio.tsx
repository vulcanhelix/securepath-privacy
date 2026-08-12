'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';

type Report = { id: string; period: string; title: string; body: string; approval_status: string;
  baseline_pct: number | null; tasks_done: number | null; tasks_total: number | null; updated_at: string };

const thisMonth = () => new Date().toISOString().slice(0, 7);

export default function Studio({ clientOrgId, isAdvisor, canIssue, draft, issued }:
  { clientOrgId: string; isAdvisor: boolean; canIssue: boolean; draft: Report | null; issued: Report[] }) {
  const router = useRouter();
  const [period, setPeriod] = useState(draft?.period ?? thisMonth());
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});

  async function compile() {
    setBusy(true); setMsg({});
    const r = await fetch(`/api/clients/${clientOrgId}/report/compile`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ period }),
    });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'compile failed' }); return; }
    setMsg({ ok: 'Report compiled — review the draft, then approve & issue.' }); router.refresh();
  }

  async function issue(id: string) {
    setBusy(true); setMsg({});
    const r = await fetch(`/api/reports/${id}/issue`, { method: 'POST' });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'issue failed' }); return; }
    setMsg({ ok: 'Report approved, issued and archived.' }); router.refresh();
  }

  return (
    <>
      <div className="card">
        <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', flexWrap: 'wrap' }}>
          <label style={{ margin: 0, fontWeight: 400 }}>Period&nbsp;
            <input type="month" value={period} onChange={e => setPeriod(e.target.value)} style={{ width: 'auto', display: 'inline-block' }} />
          </label>
          <span className="spacer" style={{ flex: 1 }} />
          {isAdvisor && <button style={{ margin: 0 }} disabled={busy} onClick={compile}>Compile report</button>}
        </div>
        {msg.err && <p className="err">{msg.err}</p>}
        {msg.ok && <p className="ok">{msg.ok}</p>}
      </div>

      {draft && (
        <div className="card" style={{ borderLeft: '3px solid var(--accent)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '.6rem', flexWrap: 'wrap' }}>
            <strong>Draft — {draft.period}</strong>
            <span className="badge">Draft</span>
            {draft.baseline_pct != null && <span className="muted">baseline {draft.baseline_pct}% · {draft.tasks_done}/{draft.tasks_total} tasks done</span>}
            <span className="spacer" style={{ flex: 1 }} />
            {canIssue && <button style={{ margin: 0, background: 'var(--accent)' }} disabled={busy} onClick={() => issue(draft.id)}>Approve &amp; issue</button>}
          </div>
          <pre style={{ whiteSpace: 'pre-wrap', fontSize: '.82rem', marginTop: '.75rem', borderTop: '1px solid var(--border)', paddingTop: '.75rem' }}>{draft.body}</pre>
        </div>
      )}

      <div className="card">
        <h2>Archive</h2>
        {issued.length === 0 && <p className="muted">No reports issued yet.</p>}
        {issued.length > 0 && (
          <table>
            <thead><tr><th>Period</th><th>Baseline</th><th>Progress</th><th>Status</th></tr></thead>
            <tbody>
              {issued.map(r => (
                <tr key={r.id}>
                  <td><strong>{r.period}</strong></td>
                  <td className="muted">{r.baseline_pct != null ? `${r.baseline_pct}%` : '—'}</td>
                  <td className="muted">{r.tasks_done}/{r.tasks_total} tasks</td>
                  <td><span className="badge" style={{ color: 'var(--accent)' }}>✓ Issued</span></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
