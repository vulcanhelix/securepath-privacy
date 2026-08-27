'use client';
import { useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Select } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';
import { StatusDot } from '@/components/ui/StatusDot';
import { DataTable } from '@/components/ui/DataTable';
import { Icon } from '@/components/ui/Icon';
import { DocPreview } from '@/components/ui/DocPreview';
import { Badge } from '@/components/ui/Badge';

type Doc = { id: string; original_filename: string; mime: string; size: number; version: number; supersedes: string | null; created_at: string };
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

  // slot chosen BEFORE uploading — the upload lands pre-confirmed into it
  const [uploadSlot, setUploadSlot] = useState('');

  // ids of documents an existing upload already supersedes
  const supersededIds = new Set(documents.map(d => d.supersedes).filter(Boolean));
  // the current (non-superseded) confirmed document for a slot — the one a new upload replaces
  const currentDocForSlot = (slotId: string) =>
    links.find(l => l.checklist_id === slotId && l.status === 'confirmed' && !supersededIds.has(l.document_id))?.document_id ?? null;

  async function upload(e: React.ChangeEvent<HTMLInputElement>) {
    const files = e.target.files;
    if (!files?.length) return;
    // a slot holds ONE current document — with a type pre-selected, take a single file
    // so several drops can't each supersede the same predecessor (Devin review, PR #6)
    if (uploadSlot && files.length > 1) {
      setMsg({ err: 'One file at a time when a document type is selected — a slot has a single current document.' });
      e.target.value = '';
      return;
    }
    setBusy(true); setMsg({});
    for (const file of Array.from(files)) {
      const fd = new FormData();
      fd.append('file', file);
      fd.append('client_org_id', clientOrgId);
      fd.append('framework', framework);
      if (trackId) fd.append('track_id', trackId);
      if (uploadSlot) {
        // uploading into a filled slot replaces its current file: immutable history, new version
        const prev = currentDocForSlot(uploadSlot);
        if (prev) fd.append('supersedes', prev);
      }
      const r = await fetch('/api/documents', { method: 'POST', body: fd });
      if (!r.ok) { setMsg({ err: `${file.name}: ${(await r.json()).error ?? 'upload failed'}` }); setBusy(false); return; }
      if (uploadSlot) {
        const { id } = await r.json();
        const { error } = await browserClient().rpc('set_document_link', {
          p_document_id: id, p_checklist_id: uploadSlot, p_status: 'confirmed', p_confidence: null,
        });
        if (error) { setMsg({ err: `${file.name}: uploaded, but assigning the slot failed — ${error.message}` }); setBusy(false); router.refresh(); return; }
      }
    }
    setBusy(false);
    const slotName = checklist.find(c => c.id === uploadSlot)?.name;
    setMsg({ ok: uploadSlot ? `Uploaded ${files.length} file(s) into “${slotName}”.` : `Uploaded ${files.length} file(s).` });
    e.target.value = '';
    router.refresh();
  }

  // Replace: upload a new version superseding this document; if it was confirmed into a
  // slot, the new version is confirmed into the same slot. History stays immutable.
  const replaceInput = useRef<HTMLInputElement>(null);
  const [replaceTarget, setReplaceTarget] = useState<Doc | null>(null);

  async function replaceFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    const target = replaceTarget;
    e.target.value = '';
    if (!file || !target) return;
    setBusy(true); setMsg({});
    const fd = new FormData();
    fd.append('file', file);
    fd.append('client_org_id', clientOrgId);
    fd.append('framework', framework);
    if (trackId) fd.append('track_id', trackId);
    fd.append('supersedes', target.id);
    const r = await fetch('/api/documents', { method: 'POST', body: fd });
    if (!r.ok) { setMsg({ err: `${file.name}: ${(await r.json()).error ?? 'upload failed'}` }); setBusy(false); return; }
    const slot = confirmedSlot(target.id);
    if (slot) {
      const { id } = await r.json();
      const { error } = await browserClient().rpc('set_document_link', {
        p_document_id: id, p_checklist_id: slot, p_status: 'confirmed', p_confidence: null,
      });
      if (error) { setMsg({ err: `uploaded, but re-linking the slot failed — ${error.message}` }); setBusy(false); router.refresh(); return; }
    }
    setBusy(false);
    setMsg({ ok: `Replaced “${target.original_filename}” with “${file.name}”.` });
    setReplaceTarget(null);
    router.refresh();
  }

  async function remove(d: Doc) {
    if (!window.confirm(`Delete “${d.original_filename}”? Only possible because it was never confirmed as evidence.`)) return;
    setBusy(true); setMsg({});
    const r = await fetch(`/api/documents/${d.id}`, { method: 'DELETE' });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'delete failed' }); return; }
    setMsg({ ok: `Deleted “${d.original_filename}”.` });
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
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12, flexWrap: 'wrap' }}>
          <span style={{ fontSize: 'var(--fs-sm)', color: 'var(--muted)' }}>Document type</span>
          <Select value={uploadSlot} onChange={e => setUploadSlot(e.target.value)} style={{ width: 'auto', minWidth: 280 }}>
            <option value="">— select a type (or we&rsquo;ll suggest one from the filename) —</option>
            {checklist.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
          </Select>
        </div>
        <label
          style={{
            display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, cursor: 'pointer',
            padding: '28px 20px', border: '1px dashed var(--border-strong)', borderRadius: 'var(--r-ctl)',
            background: 'var(--inset)', color: 'var(--muted)', fontSize: 'var(--fs-sm)', margin: 0, fontWeight: 400,
          }}
        >
          <Icon name="upload" size={18} />
          <span>
            {busy
              ? 'Uploading…'
              : uploadSlot
                ? currentDocForSlot(uploadSlot)
                  ? `Drop files to upload into “${checklist.find(c => c.id === uploadSlot)?.name}” — replaces the current file (kept as history)`
                  : `Drop files or click to upload into “${checklist.find(c => c.id === uploadSlot)?.name}”`
                : 'Drop files or click to upload — a slot will be auto-suggested for you to confirm'}
          </span>
          <input
            type="file" multiple={!uploadSlot} onChange={upload} disabled={busy} style={{ display: 'none' }}
            accept=".pdf,.png,.jpg,.jpeg,.docx,.xlsx,.txt,.csv"
          />
        </label>
        {msg.err && <Alert tone="err">{msg.err}</Alert>}
        {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
        <input ref={replaceInput} type="file" onChange={replaceFile} style={{ display: 'none' }}
               accept=".pdf,.png,.jpg,.jpeg,.docx,.xlsx,.txt,.csv" />
      </div>

      {documents.length ? (
        <DataTable
          columns={[{ label: 'File' }, { label: 'Size', align: 'right' }, { label: 'Satisfies checklist slot' }, { label: '' }, { label: '' }]}
          rows={documents.map(d => {
            const cur = sel[d.id] ?? initial(d.id);
            const isConfirmed = cur !== '' && cur === confirmedSlot(d.id);
            const isSuggestion = cur !== '' && !isConfirmed && cur === proposedSlot(d.id);
            const isSuperseded = supersededIds.has(d.id);
            if (isSuperseded) {
              return [
                <span key="f" style={{ opacity: 0.55 }}>
                  <a href={`/api/documents/${d.id}`} style={{ color: 'var(--text)', fontWeight: 500 }}>{d.original_filename}</a>
                  {d.version > 1 ? <span className="muted"> v{d.version}</span> : null}
                </span>,
                <span key="s" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)', opacity: 0.55 }}>
                  {(d.size / 1024).toFixed(0)} KB
                </span>,
                <Badge key="b" tone="warn" dot>Superseded</Badge>,
                <DocPreview key="v" docId={d.id} filename={d.original_filename} />,
                '',
              ];
            }
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
              <span key="v" style={{ display: 'inline-flex', gap: 2, alignItems: 'center' }}>
                <DocPreview docId={d.id} filename={d.original_filename} />
                <Button size="sm" variant="ghost" icon="refresh-cw" disabled={busy}
                        onClick={() => { setReplaceTarget(d); replaceInput.current?.click(); }}>
                  Replace
                </Button>
                {!confirmedSlot(d.id) && (
                  <Button size="sm" variant="ghost" icon="trash-2" disabled={busy} onClick={() => remove(d)}>
                    Delete
                  </Button>
                )}
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
