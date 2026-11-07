import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'crypto';
import { serverClient } from '@/lib/supabase';
import { putObject, headObject, deleteObject } from '@/lib/storage';

// W2-06 — evidence file upload (FR-EVD-01/02). Two body shapes:
//   multipart (legacy/server-streamed): file + programme_id + links — bytes
//     transit the Next server into the same client-scoped sha256 key.
//   JSON (W4-09 direct-upload register, NFR-02): after PUT to the presigned URL
//     from POST /api/evidence/presign — {programme_id, file_key, activity_id?|
//     register_item_id?, site?, note?, supersedes?}. We HEAD the object to prove
//     the upload landed, then upload_evidence() registers the row at
//     'verification' under the caller's JWT — RLS + the RPC's own role gate do
//     the authorisation, and the W4-03 intake trigger enqueues the malware scan.

const ALLOWED = new Set([
  'application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'image/heic', 'image/heif',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // docx
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',        // xlsx
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',// pptx
  'application/msword', 'application/vnd.ms-excel',
  'text/plain', 'text/csv',
]);
const MAX = 25 * 1024 * 1024; // 25 MB — same ceiling as /api/documents
const SHA256 = /^[0-9a-f]{64}$/;

type Supabase = Awaited<ReturnType<typeof serverClient>>;

// POST multipart: file + programme_id (+ activity_id | register_item_id, site, note, supersedes)
// POST JSON:      programme_id + file_key (+ activity_id | register_item_id, site, note, supersedes)
export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  if ((req.headers.get('content-type') ?? '').includes('application/json')) {
    return registerDirectUpload(req, supabase);
  }
  return multipartUpload(req, supabase);
}

// W4-09 — register a direct-uploaded evidence object.
async function registerDirectUpload(req: NextRequest, supabase: Supabase) {
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return NextResponse.json({ error: 'JSON body required' }, { status: 400 }); }

  const programmeId = body.programme_id as string | undefined;
  const fileKey = body.file_key as string | undefined;
  const activityId = (body.activity_id as string | null | undefined) ?? null;
  const registerItemId = (body.register_item_id as string | null | undefined) ?? null;
  const site = (body.site as string | null | undefined) ?? null;
  const note = (body.note as string | null | undefined) ?? null;
  const supersedes = (body.supersedes as string | null | undefined) ?? null;

  if (!programmeId) return NextResponse.json({ error: 'programme_id required' }, { status: 400 });
  if (!fileKey) return NextResponse.json({ error: 'file_key required — record links via upload_evidence' }, { status: 400 });
  if (!activityId && !registerItemId)
    return NextResponse.json({ error: 'evidence must link to an activity or a register item' }, { status: 400 });

  // Access check: programmes RLS returns the row only if the caller may see this
  // programme — and yields the client prefix the key must live under.
  const { data: prog } = await supabase
    .from('programmes')
    .select('id, client_org_id')
    .eq('id', programmeId)
    .maybeSingle();
  if (!prog) return NextResponse.json({ error: 'Access denied to programme' }, { status: 403 });

  // tenant scope is structural: the key must be this client's content-addressed
  // prefix — nothing else can be registered through this path
  const m = fileKey.match(/^([0-9a-f-]{36})\/([0-9a-f]{64})$/);
  if (!m || m[1] !== prog.client_org_id || !SHA256.test(m[2]))
    return NextResponse.json({ error: 'file_key must be <client_org_id>/<sha256>' }, { status: 400 });

  // prove the bytes really landed and stayed under the 25 MB ceiling
  const head = await headObject(fileKey);
  if (!head) return NextResponse.json({ error: 'upload not found in the store — PUT to the signed URL first' }, { status: 400 });
  if (head.size <= 0 || head.size > MAX) {
    try { await deleteObject(fileKey); } catch {}
    return NextResponse.json({ error: 'Uploaded object is empty or over 25 MB' }, { status: 400 });
  }
  const shaB64 = Buffer.from(m[2], 'hex').toString('base64');
  if (head.checksumSha256 && head.checksumSha256 !== shaB64)
    return NextResponse.json({ error: 'stored bytes do not match the claimed sha256' }, { status: 400 });

  // upload_evidence re-checks programme visibility + write roles in Postgres
  // (defence in depth); the row lands 'pending' → scan queue (W4-03).
  const { data: evidenceId, error } = await supabase.rpc('upload_evidence', {
    p_activity_id: activityId,
    p_register_item_id: registerItemId,
    p_file_key: fileKey,
    p_note: note,
    p_site: site,
    p_supersedes: supersedes,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ id: evidenceId });
}

// interim path (kept): bytes stream through the server to the same store.
async function multipartUpload(req: NextRequest, supabase: Supabase) {
  const form = await req.formData();
  const file = form.get('file') as File | null;
  const programmeId = form.get('programme_id') as string | null;
  const activityId = (form.get('activity_id') as string | null) || null;
  const registerItemId = (form.get('register_item_id') as string | null) || null;
  const site = (form.get('site') as string | null) || null;
  const note = (form.get('note') as string | null) || null;
  const supersedes = (form.get('supersedes') as string | null) || null;
  if (!file) return NextResponse.json({ error: 'file required — record links via upload_evidence' }, { status: 400 });
  if (!programmeId) return NextResponse.json({ error: 'programme_id required' }, { status: 400 });
  if (!activityId && !registerItemId)
    return NextResponse.json({ error: 'evidence must link to an activity or a register item' }, { status: 400 });
  if (!ALLOWED.has(file.type)) return NextResponse.json({ error: `Unsupported type ${file.type}` }, { status: 400 });
  if (file.size <= 0 || file.size > MAX) return NextResponse.json({ error: 'File must be 1 byte–25 MB' }, { status: 400 });

  // Access check BEFORE writing bytes: programmes RLS returns the row only if
  // the caller may see this programme — a forged programme_id lands nothing.
  const { data: prog } = await supabase
    .from('programmes')
    .select('id, client_org_id')
    .eq('id', programmeId)
    .maybeSingle();
  if (!prog) return NextResponse.json({ error: 'Access denied to programme' }, { status: 403 });

  const bytes = new Uint8Array(await file.arrayBuffer());
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  // same storage convention as documents: <client_org>/<sha256> in the shared bucket
  const key = `${prog.client_org_id}/${sha256}`;

  await putObject(key, bytes, file.type);
  // upload_evidence re-checks programme visibility + write roles in Postgres
  // (defence in depth); if it rejects, the orphan object is harmless.
  const { data: evidenceId, error } = await supabase.rpc('upload_evidence', {
    p_activity_id: activityId,
    p_register_item_id: registerItemId,
    p_file_key: key,
    p_note: note,
    p_site: site,
    p_supersedes: supersedes,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ id: evidenceId });
}
