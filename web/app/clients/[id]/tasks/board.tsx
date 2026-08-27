'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { GatePanel } from '@/components/ui/GatePanel';
import { RiskStrip } from '@/components/ui/RiskStrip';
import { Input, Select } from '@/components/ui/forms';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';

type Task = { id: string; theme: string; title: string; description: string | null; responsible: string | null;
  output: string | null; priority: string; owner: string | null; due_date: string | null; status: string };
type Progress = { done: number; total: number; critHigh: number; critHighDone: number };

const PRIO_TONE: Record<string, 'fail' | 'warn' | 'neutral'> = { critical: 'fail', high: 'warn' };
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
      <Card>
        <EmptyState
          icon="kanban"
          message="No remediation plan yet. Generating pulls the framework's task library and opens the board."
          action={isAdvisor ? (
            <Button disabled={busy} onClick={generate}>{busy ? 'Generating…' : 'Generate remediation plan'}</Button>
          ) : null}
        />
        {msg.err && <Alert tone="err">{msg.err}</Alert>}
      </Card>
    );
  }

  const pct = progress.total ? Math.round(progress.done / progress.total * 100) : 0;
  const byTheme = tasks.reduce<Record<string, Task[]>>((acc, t) => { (acc[t.theme] ??= []).push(t); return acc; }, {});
  const openByPrio = (p: string) => tasks.filter(t => t.priority === p && t.status !== 'done').length;

  return (
    <>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 24, marginBottom: 24 }}>
        <Card pad={24}>
          <div className="sp-kpi-label">Progress</div>
          <div className="sp-kpi-value">{progress.done}/{progress.total}</div>
          <div className="sp-kpi-sub">critical &amp; high: {progress.critHighDone}/{progress.critHigh} done</div>
          <div style={{ height: 8, background: 'var(--inset)', borderRadius: 'var(--r-pill)', overflow: 'hidden', marginTop: 12 }}>
            <div style={{ width: `${pct}%`, height: '100%', background: 'var(--accent)', transition: 'width 600ms var(--ease)' }} />
          </div>
        </Card>
        <Card pad={24}>
          <div className="sp-kpi-label" style={{ marginBottom: 14 }}>Open items by risk</div>
          <RiskStrip counts={{ critical: openByPrio('critical'), high: openByPrio('high'), medium: openByPrio('medium'), low: openByPrio('low') }} />
        </Card>
      </div>

      {msg.err && <Alert tone="err">{msg.err}</Alert>}
      {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}

      {gate4Ready && trackStage !== null && trackStage < 6 && (
        <GatePanel
          title="Gate 4 — remediation substantially complete"
          action={
            isAdvisor
              ? <Button size="sm" disabled={busy} onClick={advanceToStage6} cta>Advance to Stage 6</Button>
              : <span className="muted">An advisor advances the stage.</span>
          }
        >
          All critical &amp; high items are done. Advancing moves this client into the managed service. The transition is logged.
        </GatePanel>
      )}
      {trackStage !== null && trackStage >= 6 && (
        <GatePanel title="Gate 4 — remediation substantially complete" passed>
          Passed — this client is in the managed service (Stage 6).
        </GatePanel>
      )}

      {Object.entries(byTheme).map(([theme, list]) => (
        <Card title={themeLabel(theme)} pad={0} key={theme} style={{ marginBottom: 24 }}>
          <DataTable
            columns={[{ label: 'Task' }, { label: 'Priority' }, { label: 'Owner' }, { label: 'Due' }, { label: 'Status' }]}
            rows={list.map(t => [
              <span key="t" style={t.status === 'done' ? { opacity: 0.55 } : undefined}>
                <span style={{ color: 'var(--text)', fontWeight: 500 }}>{t.title}</span>
                {t.output ? <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>Output: {t.output}</span> : null}
                {t.responsible ? <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>Responsible: {t.responsible}</span> : null}
              </span>,
              <Badge key="p" tone={PRIO_TONE[t.priority] ?? 'neutral'} dot>{t.priority}</Badge>,
              canEdit
                ? <Input key="o" defaultValue={t.owner ?? ''} placeholder={t.responsible ?? ''} style={{ minWidth: 120 }}
                         onBlur={e => e.target.value !== (t.owner ?? '') && patch(t.id, { owner: e.target.value })} />
                : (t.owner ?? t.responsible ?? '—'),
              canEdit
                ? <Input key="d" type="date" defaultValue={t.due_date ?? ''} onChange={e => patch(t.id, { due: e.target.value })} style={{ minWidth: 140 }} />
                : (t.due_date ?? '—'),
              canEdit
                ? <Select key="s" value={t.status} onChange={e => patch(t.id, { status: e.target.value })} style={{ minWidth: 130 }}>
                    {STATUS.map(s => <option key={s} value={s}>{s.replace('_', ' ')}</option>)}
                  </Select>
                : t.status.replace('_', ' '),
            ])}
          />
        </Card>
      ))}
    </>
  );
}
