import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'crypto';
import { serverClient } from '@/lib/supabase';
import { putObject } from '@/lib/storage';

// W2-06 — evidence file upload (FR-EVD-01/02). Bytes go server-side to the
// same evidence store the documents feature uses (putObject, per-client
// content-addressed key — files never rest on the device), then
// upload_evidence() registers the row at 'verification' under the caller's
// JWT so RLS + the RPC's own role gate do the authorisation.

const ALLOWED = new Set([
  'application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'image/heic', 'image/heif',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // docx
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',        // xlsx
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',// pptx
  'application/msword', 'application/vnd.ms-excel',
  'text/plain', 'text/csv',
]);
const MAX = 25 * 1024 * 1024; // 25 MB — same ceiling as /api/documents

// POST multipart: file + programme_id (+ activity_id | register_item_id, site, note, supersedes)
export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

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
