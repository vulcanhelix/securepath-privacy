'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

type Doc = { id: string; original_filename: string; mime: string; size: number; version: number; created_at: string };
type Slot = { id: string; name: string };
type LinkRow = { id: string; checklist_id: string; document_id: string; status: string };

export default function Intake({ clientOrgId, trackId, checklist, documents, links }:
  { clientOrgId: string; trackId: string | null; checklist: Slot[]; documents: Doc[]; links: LinkRow[] }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});

  const confirmedSlot = (docId: string) =>
    links.find(l => l.document_id === docId && l.status === 'confirmed')?.checklist_id ?? '';
  const proposedSlot = (docId: string) =>
    links.find(l => l.document_id === docId && l.status === 'proposed')?.checklist_id ?? '';
  // what to show selected: a confirmed slot wins, else the AI-proposed suggestion
  const initial = (docId: string) => confirmedSlot(docId) || proposedSlot(docId);

  const [sel, setSel] = useState<Record<string, string>>(
    Object.fromEntries(documents.map(d => [d.id, initial(d.id)])));

  async function upload(e: React.ChangeEvent<HTMLInputElement>) {
    const files = e.target.files;
    if (!files?.length) return;
    setBusy(true); setMsg({});
    for (const file of Array.from(files)) {
      const fd = new FormData();
      fd.append('file', file);
      fd.append('client_org_id', clientOrgId);
      if (trackId) fd.append('track_id', trackId);
      const r = await fetch('/api/documents', { method: 'POST', body: fd });
      if (!r.ok) { setMsg({ err: `${file.name}: ${(await r.json()).error ?? 'upload failed'}` }); setBusy(false); return; }
    }
    setBusy(false); setMsg({ ok: `Uploaded ${files.length} file(s).` });
    e.target.value = '';
    router.refresh();
  }

  async function confirm(documentId: string, checklistId: string) {
    if (!checklistId) return;
    const { error } = await browserClient().rpc('set_document_link', {
      p_document_id: documentId, p_checklist_id: checklistId, p_status: 'confirmed', p_confidence: null,
    });
    if (error) { setMsg({ err: error.message }); return; }
    router.refresh();
  }

  return (
    <div className="card">
      <h2>Uploaded documents</h2>
      <label style={{ fontWeight: 400 }}>
        <input type="file" multiple onChange={upload} disabled={busy}
               accept=".pdf,.png,.jpg,.jpeg,.docx,.xlsx,.txt,.csv" />
      </label>
      {busy && <p className="muted">Uploading…</p>}
      {msg.err && <p className="err">{msg.err}</p>}
      {msg.ok && <p className="ok">{msg.ok}</p>}

      {documents.length ? (
        <table style={{ marginTop: '1rem' }}>
          <thead><tr><th>File</th><th>Size</th><th>Satisfies checklist slot</th><th></th></tr></thead>
          <tbody>
            {documents.map(d => {
              const cur = sel[d.id] ?? '';
              const isConfirmed = cur !== '' && cur === confirmedSlot(d.id);
              const isSuggestion = cur !== '' && !isConfirmed && cur === proposedSlot(d.id);
              return (
                <tr key={d.id}>
                  <td><a href={`/api/documents/${d.id}`}>{d.original_filename}</a>
                    {d.version > 1 ? <span className="muted"> v{d.version}</span> : null}</td>
                  <td className="muted">{(d.size / 1024).toFixed(0)} KB</td>
                  <td>
                    <select value={cur} onChange={e => setSel({ ...sel, [d.id]: e.target.value })}>
                      <option value="">— unassigned —</option>
                      {checklist.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
                    </select>
                    {isSuggestion && <span className="muted" style={{ marginLeft: '.4rem', fontSize: '.8rem' }}>suggested</span>}
                  </td>
                  <td>
                    {isConfirmed
                      ? <span style={{ color: 'var(--accent)', fontWeight: 600 }}>✓ confirmed</span>
                      : <button style={{ margin: 0, padding: '.3rem .7rem', fontSize: '.85rem' }}
                                disabled={!cur} onClick={() => confirm(d.id, cur)}>Confirm</button>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      ) : <p className="muted" style={{ marginTop: '.5rem' }}>No documents yet. Upload the client&rsquo;s existing policies, notices and registers.</p>}
    </div>
  );
}
