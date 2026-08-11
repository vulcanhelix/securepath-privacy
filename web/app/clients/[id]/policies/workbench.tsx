'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

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
  const statusBadge = (s: string) => s === 'issued'
    ? <span className="badge" style={{ color: 'var(--accent)' }}>✓ Issued</span>
    : s === 'approved'
      ? <span className="badge" style={{ color: 'var(--accent)' }}>✓ Approved</span>
      : <span className="badge">{s === 'draft_ai' ? 'Draft (AI)' : 'Draft'}</span>;

  return (
    <>
      {gate2Ready && trackStage !== null && trackStage < 4 && (
        <div className="card" style={{ borderLeft: '3px solid var(--accent)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '.75rem', flexWrap: 'wrap' }}>
            <strong>Gate 2 — policy suite approved</strong>
            <span className="muted">All required policies are approved. Advancing moves this client into Stage 4 (manual compile).</span>
            <span className="spacer" style={{ flex: 1 }} />
            {isAdvisor
              ? <button style={{ margin: 0 }} disabled={busy} onClick={advanceToStage4}>Advance to Stage 4 →</button>
              : <span className="muted">An advisor advances the stage.</span>}
          </div>
          {msg.err && <p className="err">{msg.err}</p>}
        </div>
      )}
      {canEdit && draftable.length > 0 && (
        <div className="card">
          <h2>Gaps needing a policy</h2>
          <table>
            <tbody>
              {draftable.map(d => (
                <tr key={d.checklist_id}>
                  <td><strong>{d.name}</strong></td>
                  <td style={{ textAlign: 'right' }}>
                    <button style={{ margin: 0, padding: '.35rem .8rem', fontSize: '.85rem' }}
                            disabled={busy} onClick={() => createFromTemplate(d)}>Draft from template</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="card">
        <h2>Policies</h2>
        {msg.err && <p className="err">{msg.err}</p>}
        {msg.ok && <p className="ok">{msg.ok}</p>}
        {policies.length === 0 && <p className="muted">No policies drafted yet.</p>}
        {policies.map(p => (
          <div key={p.id} style={{ borderTop: '1px solid var(--border)', paddingTop: '.75rem', marginTop: '.75rem' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '.6rem', flexWrap: 'wrap' }}>
              <strong>{p.title}</strong>
              {statusBadge(p.approval_status)}
              <span className="spacer" style={{ flex: 1 }} />
              {canEdit && isDraft(p.approval_status) && open !== p.id &&
                <button style={{ margin: 0, padding: '.3rem .7rem', fontSize: '.85rem' }} onClick={() => edit(p)}>Edit</button>}
              {canEdit && isDraft(p.approval_status) &&
                <button style={{ margin: 0, padding: '.3rem .7rem', fontSize: '.85rem', background: 'var(--accent)' }}
                        disabled={busy} onClick={() => approve(p.id)}>Approve</button>}
              {canEdit && p.approval_status === 'approved' &&
                <button style={{ margin: 0, padding: '.3rem .7rem', fontSize: '.85rem', background: 'var(--accent)' }}
                        disabled={busy} onClick={() => issue(p.id)}>Issue &amp; close gap</button>}
            </div>
            {open === p.id ? (
              <div style={{ marginTop: '.6rem' }}>
                <input value={draft.title} onChange={e => setDraft({ ...draft, title: e.target.value })} />
                <textarea value={draft.body} onChange={e => setDraft({ ...draft, body: e.target.value })}
                          rows={16} style={{ width: '100%', marginTop: '.5rem', fontFamily: 'ui-monospace, monospace', fontSize: '.85rem' }} />
                <div style={{ display: 'flex', gap: '.5rem' }}>
                  <button style={{ margin: '.5rem 0 0' }} disabled={busy} onClick={() => save(p.id)}>Save draft</button>
                  <button style={{ margin: '.5rem 0 0', background: 'var(--muted)' }} onClick={() => setOpen(null)}>Close</button>
                </div>
              </div>
            ) : (
              <pre style={{ whiteSpace: 'pre-wrap', fontSize: '.82rem', color: 'var(--muted)', marginTop: '.4rem',
                            maxHeight: open ? 'none' : '4.5rem', overflow: 'hidden' }}>{p.body.slice(0, 400)}{p.body.length > 400 ? '…' : ''}</pre>
            )}
          </div>
        ))}
      </div>
    </>
  );
}
