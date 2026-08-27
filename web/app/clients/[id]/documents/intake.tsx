'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Select } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';
import { StatusDot } from '@/components/ui/StatusDot';
import { DataTable } from '@/components/ui/DataTable';
import { Icon } from '@/components/ui/Icon';

type Doc = { id: string; original_filename: string; mime: string; size: number; version: number; created_at: string };
type Slot = { id: string; name: string };
type LinkRow = { id: string; checklist_id: string; document_id: string; status: string };

export default function Intake({ clientOrgId, trackId, framework, checklist, documents, links }:
  { clientOrgId: string; trackId: string | null; framework: string; checklist: Slot[]; documents: Doc[]; links: LinkRow[] }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});

  const confirmedSlot = (docId: string) =>
    links.find(l => l.document_id === docId && l.status === 'confirmed')?.checklist_id ?? '';
  const proposedSlot = (docId: string) =>
    links.find(l => l.document_id === docId && l.status === 'proposed')?.checklist_id ?? '';
  // what to show selected: a confirmed slot wins, else the AI-proposed suggestion
  const initial = (docId: string) => confirmedSlot(docId) || proposedSlot(docId);

  // sel holds only the user's explicit choices; fresh props (incl. links written
  // by the upload API after router.refresh()) fill everything else at render time
  const [sel, setSel] = useState<Record<string, string>>({});

  async function upload(e: React.ChangeEvent<HTMLInputElement>) {
    const files = e.target.files;
    if (!files?.length) return;
    setBusy(true); setMsg({});
    for (const file of Array.from(files)) {
      const fd = new FormData();
      fd.append('file', file);
      fd.append('client_org_id', clientOrgId);
      fd.append('framework', framework);
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
    <Card title="Uploaded documents" pad={0}>
      <div style={{ padding: '20px 28px' }}>
        <label
          style={{
            display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, cursor: 'pointer',
            padding: '28px 20px', border: '1px dashed var(--border-strong)', borderRadius: 'var(--r-ctl)',
            background: 'var(--inset)', color: 'var(--muted)', fontSize: 'var(--fs-sm)', margin: 0, fontWeight: 400,
          }}
        >
          <Icon name="upload" size={18} />
          <span>{busy ? 'Uploading…' : 'Drop files or click to upload — policies, notices, registers'}</span>
          <input
            type="file" multiple onChange={upload} disabled={busy} style={{ display: 'none' }}
            accept=".pdf,.png,.jpg,.jpeg,.docx,.xlsx,.txt,.csv"
          />
        </label>
        {msg.err && <Alert tone="err">{msg.err}</Alert>}
        {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
      </div>

      {documents.length ? (
        <DataTable
          columns={[{ label: 'File' }, { label: 'Size', align: 'right' }, { label: 'Satisfies checklist slot' }, { label: '' }]}
          rows={documents.map(d => {
            const cur = sel[d.id] ?? initial(d.id);
            const isConfirmed = cur !== '' && cur === confirmedSlot(d.id);
            const isSuggestion = cur !== '' && !isConfirmed && cur === proposedSlot(d.id);
            return [
              <span key="f">
                <a href={`/api/documents/${d.id}`} style={{ color: 'var(--text)', fontWeight: 500 }}>{d.original_filename}</a>
                {d.version > 1 ? <span className="muted"> v{d.version}</span> : null}
              </span>,
              <span key="s" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {(d.size / 1024).toFixed(0)} KB
              </span>,
              <span key="sel" style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                <Select value={cur} onChange={e => setSel({ ...sel, [d.id]: e.target.value })} style={{ minWidth: 220 }}>
                  <option value="">— unassigned —</option>
                  {checklist.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
                </Select>
                {isSuggestion && <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>suggested</span>}
              </span>,
              isConfirmed
                ? <StatusDot key="c" tone="pass" label="Confirmed" />
                : <Button key="c" size="sm" variant="secondary" disabled={!cur} onClick={() => confirm(d.id, cur)}>Confirm</Button>,
            ];
          })}
        />
      ) : (
        <p className="muted" style={{ padding: '0 28px 24px', margin: 0 }}>
          No documents yet. Upload the client&rsquo;s existing policies, notices and registers.
        </p>
      )}
    </Card>
  );
}
