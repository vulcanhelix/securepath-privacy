'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

type Task = { id: string; theme: string; title: string; description: string | null; responsible: string | null;
  output: string | null; priority: string; owner: string | null; due_date: string | null; status: string };
type Progress = { done: number; total: number; critHigh: number; critHighDone: number };

const PRIO_COLOR: Record<string, string> = { critical: '#b23a3a', high: '#b07a1c', medium: '#5d6e66', low: '#8a978f' };
const STATUS = ['todo', 'in_progress', 'blocked', 'done'];
const themeLabel = (t: string) => t.charAt(0).toUpperCase() + t.slice(1);

export default function Board({ clientOrgId, framework, isAdvisor, canEdit, tasks, trackId, trackStage, progress, gate4Ready }:
  { clientOrgId: string; framework: string; isAdvisor: boolean; canEdit: boolean; tasks: Task[]; trackId: string | null;
    trackStage: number | null; progress: Progress; gate4Ready: boolean }) {
  const router = useRouter();
  const supabase = browserClient();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});

  async function generate() {
    setBusy(true); setMsg({});
    const { data, error } = await supabase.rpc('generate_remediation_plan', { p_client_org_id: clientOrgId, p_framework: framework });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setMsg({ ok: `Generated ${data} tasks.` }); router.refresh();
  }

  async function patch(taskId: string, fields: { status?: string; owner?: string; due?: string }) {
    const { error } = await supabase.rpc('update_task', {
      p_task_id: taskId, p_status: fields.status ?? null, p_owner: fields.owner ?? null, p_due: fields.due || null,
    });
    if (error) { setMsg({ err: error.message }); return; }
    router.refresh();
  }

  async function advanceToStage6() {
    if (!trackId) return;
    setBusy(true); setMsg({});
    const { error } = await supabase.rpc('advance_track_stage', {
      p_track_id: trackId, p_to_stage: 6, p_note: 'Gate 4: remediation substantially complete',
    });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    router.refresh();
  }

  if (tasks.length === 0) {
    return (
      <div className="card">
        <p className="muted">No remediation plan yet.</p>
        {isAdvisor && <button disabled={busy} onClick={generate}>{busy ? 'Generating…' : 'Generate remediation plan'}</button>}
        {msg.err && <p className="err">{msg.err}</p>}
      </div>
    );
  }

  const pct = progress.total ? Math.round(progress.done / progress.total * 100) : 0;
  const byTheme = tasks.reduce<Record<string, Task[]>>((acc, t) => { (acc[t.theme] ??= []).push(t); return acc; }, {});

  return (
    <>
      <div className="card">
        <div style={{ display: 'flex', alignItems: 'baseline', gap: '.75rem' }}>
          <strong>{progress.done}/{progress.total} tasks done</strong>
          <span className="muted">· critical &amp; high: {progress.critHighDone}/{progress.critHigh}</span>
        </div>
        <div style={{ height: 8, background: 'var(--border)', borderRadius: 4, overflow: 'hidden', marginTop: '.5rem' }}>
          <div style={{ width: `${pct}%`, height: '100%', background: 'var(--accent)' }} />
        </div>
        {msg.err && <p className="err">{msg.err}</p>}
        {msg.ok && <p className="ok">{msg.ok}</p>}
      </div>

      {gate4Ready && trackStage !== null && trackStage < 6 && (
        <div className="card" style={{ borderLeft: '3px solid var(--accent)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', flexWrap: 'wrap' }}>
            <strong>Gate 4 — remediation substantially complete</strong>
            <span className="muted">All critical &amp; high items are done.</span>
            <span className="spacer" style={{ flex: 1 }} />
            {isAdvisor
              ? <button style={{ margin: 0 }} disabled={busy} onClick={advanceToStage6}>Advance to Stage 6 →</button>
              : <span className="muted">An advisor advances the stage.</span>}
          </div>
        </div>
      )}

      {Object.entries(byTheme).map(([theme, list]) => (
        <div className="card" key={theme}>
          <h2>{themeLabel(theme)}</h2>
          <table>
            <thead><tr><th>Task</th><th>Priority</th><th>Owner</th><th>Due</th><th>Status</th></tr></thead>
            <tbody>
              {list.map(t => (
                <tr key={t.id} style={t.status === 'done' ? { opacity: .6 } : undefined}>
                  <td><strong>{t.title}</strong>{t.output ? <div className="muted" style={{ fontSize: '.78rem' }}>Output: {t.output}</div> : null}</td>
                  <td><span className="badge" style={{ color: PRIO_COLOR[t.priority] }}>{t.priority}</span></td>
                  <td>{canEdit
                    ? <input defaultValue={t.owner ?? ''} placeholder={t.responsible ?? ''} style={{ minWidth: 110 }}
                             onBlur={e => e.target.value !== (t.owner ?? '') && patch(t.id, { owner: e.target.value })} />
                    : (t.owner ?? t.responsible ?? '—')}</td>
                  <td>{canEdit
                    ? <input type="date" defaultValue={t.due_date ?? ''} onChange={e => patch(t.id, { due: e.target.value })} />
                    : (t.due_date ?? '—')}</td>
                  <td>{canEdit
                    ? <select value={t.status} onChange={e => patch(t.id, { status: e.target.value })}>
                        {STATUS.map(s => <option key={s} value={s}>{s.replace('_', ' ')}</option>)}
                      </select>
                    : t.status}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}
    </>
  );
}
