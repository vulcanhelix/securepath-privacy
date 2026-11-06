'use client';
import { useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Select, Input, Textarea, Field } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

// W2-06 — evidence capture (spec §8.4 screens 03/08, FR-EVD-01/02, FR-MOB-02).
// Files go through POST /api/evidence — server streams them to the shared
// evidence store (putObject, same client-scoped sha256 path the documents
// feature uses; nothing is kept on the device) then registers the row via
// upload_evidence under the caller's JWT. Links skip storage and call the RPC
// directly. The camera input uses capture='environment' (screen 08).

type Option = { id: string; ref: string; label: string; status: string | null };

export function EvidenceUpload({
  programmeId,
  activities,
  registerItems,
  prefill,
}: {
  programmeId: string;
  activities: Option[];
  registerItems: Option[];
  prefill: { activityId?: string; registerItemId?: string; supersedes?: string };
}) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [activityId, setActivityId] = useState(prefill.activityId ?? '');
  const [registerItemId, setRegisterItemId] = useState(prefill.registerItemId ?? '');
  const [site, setSite] = useState('');
  const [note, setNote] = useState('');
  const [linkUrl, setLinkUrl] = useState('');
  const [supersedes] = useState(prefill.supersedes ?? '');

  const fileInput = useRef<HTMLInputElement>(null);
  const cameraInput = useRef<HTMLInputElement>(null);

  const targetOk = !!activityId || !!registerItemId;

  async function sendFiles(files: FileList | File[]) {
    if (!targetOk) {
      setMsg({ err: 'Choose the activity or register item this evidence is for first.' });
      return;
    }
    setBusy(true);
    setMsg({});
    let n = 0;
    for (const file of Array.from(files)) {
      const fd = new FormData();
      fd.append('file', file);
      fd.append('programme_id', programmeId);
      if (activityId) fd.append('activity_id', activityId);
      if (registerItemId) fd.append('register_item_id', registerItemId);
      if (site.trim()) fd.append('site', site.trim());
      if (note.trim()) fd.append('note', note.trim());
      if (supersedes) fd.append('supersedes', supersedes);
      const r = await fetch('/api/evidence', { method: 'POST', body: fd });
      if (!r.ok) {
        const body = await r.json().catch(() => ({}));
        setMsg({ err: `${file.name}: ${body.error ?? 'upload failed'}` });
        setBusy(false);
        return;
      }
      n++;
    }
    setBusy(false);
    setMsg({ ok: `Uploaded ${n} file${n === 1 ? '' : 's'} — sent for verification.` });
    router.refresh();
  }

  async function sendLink() {
    if (!targetOk) {
      setMsg({ err: 'Choose the activity or register item this evidence is for first.' });
      return;
    }
    if (!linkUrl.trim()) {
      setMsg({ err: 'Paste the link first.' });
      return;
    }
    setBusy(true);
    setMsg({});
    const { error } = await browserClient().rpc('upload_evidence', {
      p_activity_id: activityId || null,
      p_register_item_id: registerItemId || null,
      p_link: linkUrl.trim(),
      p_note: note.trim() || null,
      p_site: site.trim() || null,
      p_supersedes: supersedes || null,
    });
    setBusy(false);
    if (error) {
      setMsg({ err: error.message });
      return;
    }
    setLinkUrl('');
    setMsg({ ok: 'Link recorded — sent for verification.' });
    router.refresh();
  }

  return (
    <div>
      {prefill.supersedes ? (
        <Alert tone="info">This upload records a new version superseding the returned item — the original stays on file unchanged (NFR-09).</Alert>
      ) : null}
      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
        <div style={{ flex: '1 1 240px' }}>
          <Field label="Against activity" hint={!targetOk ? 'An activity or register item is required (FR-EVD-01).' : undefined}>
            <Select value={activityId} onChange={(e) => setActivityId(e.target.value)}>
              <option value="">— none —</option>
              {activities.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.ref} — {a.label}
                </option>
              ))}
            </Select>
          </Field>
        </div>
        <div style={{ flex: '1 1 240px' }}>
          <Field label="…or register item">
            <Select value={registerItemId} onChange={(e) => setRegisterItemId(e.target.value)}>
              <option value="">— none —</option>
              {registerItems.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.ref} — {r.label}
                </option>
              ))}
            </Select>
          </Field>
        </div>
      </div>
      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
        <div style={{ flex: '1 1 200px' }}>
          <Field label="Site" hint="Recorded with mobile capture (FR-MOB-02).">
            <Input value={site} onChange={(e) => setSite(e.target.value)} placeholder="e.g. Head office" />
          </Field>
        </div>
        <div style={{ flex: '2 1 280px' }}>
          <Field label="Note">
            <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Context for the reviewer (optional)" />
          </Field>
        </div>
      </div>

      {msg.err ? <Alert tone="err">{msg.err}</Alert> : null}
      {msg.ok ? <Alert tone="ok">{msg.ok}</Alert> : null}

      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center' }}>
        <Button size="sm" icon="upload" disabled={busy || !targetOk} onClick={() => fileInput.current?.click()}>
          Choose files
        </Button>
        <Button size="sm" variant="secondary" icon="camera" disabled={busy || !targetOk} onClick={() => cameraInput.current?.click()}>
          Capture photo
        </Button>
        <input
          ref={fileInput}
          type="file"
          multiple
          hidden
          onChange={(e) => {
            if (e.target.files?.length) sendFiles(e.target.files);
            e.target.value = '';
          }}
        />
        {/* screen 08 — rear camera on mobile; falls back to a normal picker on desktop */}
        <input
          ref={cameraInput}
          type="file"
          accept="image/*"
          capture="environment"
          hidden
          onChange={(e) => {
            if (e.target.files?.length) sendFiles(e.target.files);
            e.target.value = '';
          }}
        />
      </div>

      <div style={{ marginTop: 18, paddingTop: 16, borderTop: '1px solid var(--border)' }}>
        <Field label="Or record a link">
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
            <div style={{ flex: '1 1 260px' }}>
              <Input
                type="url"
                value={linkUrl}
                onChange={(e) => setLinkUrl(e.target.value)}
                placeholder="https://…"
              />
            </div>
            <Button size="sm" variant="secondary" icon="link" disabled={busy || !targetOk} onClick={sendLink}>
              Record link
            </Button>
          </div>
        </Field>
      </div>
    </div>
  );
}
