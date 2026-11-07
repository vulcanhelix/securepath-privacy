// W4-09 (NFR-02, FR-EVD-02) — browser-side direct upload: SHA-256 the file,
// fetch a short-lived presigned PUT (permission-checked by the API), send the
// bytes straight to the evidence store, then register the row. The signed PUT
// pins Content-Type + x-amz-checksum-sha256, so the store itself guarantees the
// content-addressed key — and the file never transits the app server or rests
// on the device beyond the picker.

export async function sha256Hex(file: Blob): Promise<string> {
  const buf = await file.arrayBuffer();
  const digest = await crypto.subtle.digest('SHA-256', buf);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

type Presign = { url: string; key: string; headers: Record<string, string>; expires_in: number };

async function presignAndPut(presignPath: string, payload: Record<string, unknown>, file: File): Promise<Presign> {
  const ps = await fetch(presignPath, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const psBody = (await ps.json().catch(() => ({}))) as Partial<Presign> & { error?: string };
  if (!ps.ok || !psBody.url || !psBody.key || !psBody.headers)
    throw new Error(psBody.error ?? `Could not get an upload URL (${ps.status})`);

  const put = await fetch(psBody.url, { method: 'PUT', headers: psBody.headers, body: file });
  if (!put.ok) throw new Error(`Store rejected the upload (${put.status})`);
  return { url: psBody.url, key: psBody.key, headers: psBody.headers, expires_in: psBody.expires_in ?? 0 };
}

async function register(registerPath: string, payload: Record<string, unknown>): Promise<{ id?: string; proposed?: string | null }> {
  const r = await fetch(registerPath, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const body = (await r.json().catch(() => ({}))) as { id?: string; proposed?: string | null; error?: string };
  if (!r.ok || !body.id) throw new Error(body.error ?? `Registration failed (${r.status})`);
  return body;
}

/** Document intake (Stage 2): presign → PUT → register via record_document. */
export async function uploadDocumentDirect(
  file: File,
  fields: { clientOrgId: string; trackId?: string | null; framework?: string; supersedes?: string; classify?: boolean },
): Promise<{ id?: string; proposed?: string | null }> {
  const sha256 = await sha256Hex(file);
  const { key } = await presignAndPut('/api/documents/presign',
    { client_org_id: fields.clientOrgId, mime: file.type, size: file.size, sha256 }, file);
  return register('/api/documents', {
    client_org_id: fields.clientOrgId,
    filename: file.name,
    mime: file.type,
    sha256,
    storage_path: key,
    track_id: fields.trackId ?? null,
    framework: fields.framework,
    supersedes: fields.supersedes ?? null,
    classify: fields.classify ?? true,
  });
}

/** Evidence capture (screens 03/08): presign → PUT → register via upload_evidence. */
export async function uploadEvidenceDirect(
  file: File,
  fields: {
    programmeId: string; activityId?: string; registerItemId?: string;
    site?: string; note?: string; supersedes?: string;
  },
): Promise<{ id?: string }> {
  const sha256 = await sha256Hex(file);
  const { key } = await presignAndPut('/api/evidence/presign',
    { programme_id: fields.programmeId, mime: file.type, size: file.size, sha256 }, file);
  return register('/api/evidence', {
    programme_id: fields.programmeId,
    file_key: key,
    activity_id: fields.activityId || null,
    register_item_id: fields.registerItemId || null,
    site: fields.site || null,
    note: fields.note || null,
    supersedes: fields.supersedes || null,
  });
}
