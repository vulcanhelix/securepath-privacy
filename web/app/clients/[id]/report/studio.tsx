'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { Input } from '@/components/ui/forms';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';

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

  const tasksPct = draft?.tasks_total ? Math.round(((draft.tasks_done ?? 0) / draft.tasks_total) * 100) : 0;

  return (
    <>
      <Card pad={20} style={{ marginBottom: 24 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          <label style={{ margin: 0, display: 'inline-flex', alignItems: 'center', gap: 8, fontWeight: 400, color: 'var(--muted)', fontSize: 'var(--fs-sm)' }}>
            Period
            <Input type="month" value={period} onChange={e => setPeriod(e.target.value)} style={{ width: 'auto' }} />
          </label>
          <span style={{ flex: 1 }} />
          {isAdvisor && <Button size="sm" disabled={busy} onClick={compile}>Compile report</Button>}
        </div>
        {msg.err && <Alert tone="err">{msg.err}</Alert>}
        {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
      </Card>

      {draft && (
        <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 24, marginBottom: 24, alignItems: 'start' }}>
          <section className="sp-card sp-card--light" style={{ borderLeft: '3px solid var(--accent)' }}>
            <div style={{ padding: '20px 28px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                <strong style={{ fontWeight: 500 }}>Draft — {draft.period}</strong>
                <Badge tone={draft.approval_status === 'draft_ai' ? 'warn' : 'neutral'} dot>
                  {draft.approval_status === 'draft_ai' ? 'Draft (AI)' : 'Draft'}
                </Badge>
                <span style={{ flex: 1 }} />
                {canIssue && <Button size="sm" disabled={busy} onClick={() => issue(draft.id)} cta>Approve &amp; issue</Button>}
              </div>
              <pre className="mono" style={{ whiteSpace: 'pre-wrap', fontSize: 'var(--fs-xs)', lineHeight: 1.6, color: 'var(--text-2)', marginTop: 16, marginBottom: 0, borderTop: '1px solid var(--border)', paddingTop: 16 }}>
                {draft.body}
              </pre>
            </div>
          </section>

          <Card title="This period" tone="dark" pad={24}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12, fontSize: 'var(--fs-sm)' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ color: 'var(--panel-muted)' }}>Baseline</span>
                <span className="mono">{draft.baseline_pct != null ? `${draft.baseline_pct}%` : '—'}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ color: 'var(--panel-muted)' }}>Tasks complete</span>
                <span className="mono">{draft.tasks_done ?? 0}/{draft.tasks_total ?? 0}</span>
              </div>
              <div style={{ height: 8, background: 'var(--panel-line)', borderRadius: 'var(--r-pill)', overflow: 'hidden' }}>
                <div style={{ width: `${tasksPct}%`, height: '100%', background: 'var(--panel-text)', transition: 'width 600ms var(--ease)' }} />
              </div>
              <span style={{ color: 'var(--panel-muted)', fontSize: 'var(--fs-xs)' }}>
                Movement is measured against the immutable Stage 1 baseline.
              </span>
            </div>
          </Card>
        </div>
      )}

      <Card title="Archive" action={<span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--faint)' }}>immutable</span>} pad={0}>
        {issued.length === 0 ? (
          <EmptyState icon="archive" message="No reports issued yet." />
        ) : (
          <DataTable
            columns={[{ label: 'Period' }, { label: 'Baseline', align: 'right' }, { label: 'Progress', align: 'right' }, { label: 'Status' }]}
            rows={issued.map(r => [
              <span key="p" className="mono" style={{ color: 'var(--text)', fontWeight: 500 }}>{r.period}</span>,
              <span key="b" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {r.baseline_pct != null ? `${r.baseline_pct}%` : '—'}
              </span>,
              <span key="t" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {r.tasks_done}/{r.tasks_total} tasks
              </span>,
              <Badge key="s" tone="ink">Issued</Badge>,
            ])}
          />
        )}
      </Card>
    </>
  );
}
