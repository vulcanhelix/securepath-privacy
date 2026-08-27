'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { GatePanel } from '@/components/ui/GatePanel';
import { Input, Textarea } from '@/components/ui/forms';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';

type Policy = { id: string; checklist_id: string | null; title: string; body: string; approval_status: string; updated_at: string };
type Draftable = { checklist_id: string; slot_key: string; name: string; template_id: string };

export default function Workbench({ clientOrgId, canEdit, isAdvisor, draftable, policies, trackId, trackStage, gate2Ready }:
  { clientOrgId: string; canEdit: boolean; isAdvisor: boolean; draftable: Draftable[]; policies: Policy[];
    trackId: string | null; trackStage: number | null; gate2Ready: boolean }) {
  const router = useRouter();
  const supabase = browserClient();
  const [open, setOpen] = useState<string | null>(null);
  const [draft, setDraft] = useState<{ title: string; body: string }>({ title: '', body: '' });
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  async function createFromTemplate(d: Draftable) {
    setBusy(true); setMsg({});
    const { error } = await supabase.rpc('create_policy', {
      p_client_org_id: clientOrgId, p_checklist_id: d.checklist_id, p_template_id: d.template_id, p_title: d.name,
    });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    router.refresh();
  }

  function edit(p: Policy) { setOpen(p.id); setDraft({ title: p.title, body: p.body }); setMsg({}); }

  async function save(id: string) {
    setBusy(true); setMsg({});
    const { error } = await supabase.rpc('update_policy_draft', { p_policy_id: id, p_title: draft.title, p_body: draft.body });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setMsg({ ok: 'Draft saved.' }); router.refresh();
  }

  async function approve(id: string) {
    setBusy(true); setMsg({});
    const { error } = await supabase.rpc('approve_policy', { p_policy_id: id });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setOpen(null); router.refresh();
  }

  // issue an approved policy → becomes an immutable document that fills its gap
  async function issue(id: string) {
    setBusy(true); setMsg({});
    const r = await fetch(`/api/policies/${id}/issue`, { method: 'POST' });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'issue failed' }); return; }
    setMsg({ ok: 'Policy issued — the Stage 2 gap is now closed.' }); router.refresh();
  }

  async function advanceToStage4() {
    if (!trackId) return;
    setBusy(true); setMsg({});
    const { error } = await supabase.rpc('advance_track_stage', {
      p_track_id: trackId, p_to_stage: 4, p_note: 'Gate 2: policy suite approved',
    });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    router.refresh();
  }

  const isDraft = (s: string) => s === 'draft_ai' || s === 'draft_human';
  const statusBadge = (s: string) =>
    s === 'issued' ? <Badge tone="ink">Issued</Badge>
    : s === 'approved' ? <Badge tone="pass" dot>Approved</Badge>
    : s === 'draft_ai' ? <Badge tone="warn" dot>Draft (AI)</Badge>
    : <Badge tone="neutral" dot>Draft</Badge>;

  return (
    <>
      {gate2Ready && trackStage !== null && trackStage < 4 && (
        <GatePanel
          title="Gate 2 — policy suite approved"
          action={
            isAdvisor
              ? <Button size="sm" disabled={busy} onClick={advanceToStage4} cta>Advance to Stage 4</Button>
              : <span className="muted">An advisor advances the stage.</span>
          }
        >
          All required policies are approved. Advancing moves this client into Stage 4 (manual compile). The transition is logged.
        </GatePanel>
      )}
      {trackStage !== null && trackStage >= 4 && (
        <GatePanel title="Gate 2 — policy suite approved" passed>
          Passed — this client is at Stage {trackStage}.
        </GatePanel>
      )}

      {msg.err && <Alert tone="err">{msg.err}</Alert>}
      {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}

      {canEdit && draftable.length > 0 && (
        <Card title="Gaps needing a policy" pad={0} style={{ marginBottom: 24 }}>
          <DataTable
            columns={[{ label: 'Missing document' }, { label: '', align: 'right' }]}
            rows={draftable.map(d => [
              <span key="n" style={{ color: 'var(--text)', fontWeight: 500 }}>{d.name}</span>,
              <Button key="b" size="sm" variant="secondary" disabled={busy} onClick={() => createFromTemplate(d)}>
                Draft from template
              </Button>,
            ])}
          />
        </Card>
      )}

      <Card title="Policies" pad={0}>
        {policies.length === 0 && <EmptyState icon="file-text" message="No policies drafted yet." />}
        {policies.map(p => (
          <div key={p.id} style={{ borderTop: '1px solid var(--border)', padding: '20px 28px' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <strong style={{ fontWeight: 500 }}>{p.title}</strong>
              {statusBadge(p.approval_status)}
              <span style={{ flex: 1 }} />
              {canEdit && isDraft(p.approval_status) && open !== p.id && (
                <Button size="sm" variant="secondary" onClick={() => edit(p)}>Edit</Button>
              )}
              {canEdit && isDraft(p.approval_status) && (
                <Button size="sm" disabled={busy} onClick={() => approve(p.id)}>Approve</Button>
              )}
              {canEdit && p.approval_status === 'approved' && (
                <Button size="sm" disabled={busy} onClick={() => issue(p.id)}>Issue &amp; close gap</Button>
              )}
            </div>
            {open === p.id ? (
              <div style={{ marginTop: 14 }}>
                <Input value={draft.title} onChange={e => setDraft({ ...draft, title: e.target.value })} />
                <Textarea
                  value={draft.body} onChange={e => setDraft({ ...draft, body: e.target.value })}
                  rows={16} style={{ marginTop: 10, fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-xs)' }}
                />
                <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                  <Button size="sm" disabled={busy} onClick={() => save(p.id)}>Save draft</Button>
                  <Button size="sm" variant="ghost" onClick={() => setOpen(null)}>Close</Button>
                </div>
              </div>
            ) : (
              <pre
                className="mono"
                style={{
                  whiteSpace: 'pre-wrap', fontSize: 'var(--fs-xs)', color: 'var(--muted)', marginTop: 10, marginBottom: 0,
                  maxHeight: '4.5rem', overflow: 'hidden',
                }}
              >
                {p.body.slice(0, 400)}{p.body.length > 400 ? '…' : ''}
              </pre>
            )}
          </div>
        ))}
      </Card>
    </>
  );
}
