import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'crypto';
import { serverClient } from '@/lib/supabase';
import { putObject } from '@/lib/storage';
import { proposeSlot } from '@/lib/classify';

const ALLOWED = new Set([
  'application/pdf', 'image/png', 'image/jpeg',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // docx
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',        // xlsx
  'text/plain', 'text/csv',
]);
const MAX = 25 * 1024 * 1024; // 25 MB

// GET ?client_org_id= — list a client's documents (RLS scopes to allowed_client_orgs)
export async function GET(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });
  const clientOrg = req.nextUrl.searchParams.get('client_org_id');
  if (!clientOrg) return NextResponse.json({ error: 'client_org_id required' }, { status: 400 });
  const { data, error } = await supabase
    .from('documents')
    .select('id, original_filename, mime, size, version, created_at')
    .eq('client_org_id', clientOrg)
    .order('created_at', { ascending: false });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json(data);
}

// POST multipart: file + client_org_id (+ optional track_id) — server-side upload.
export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const form = await req.formData();
  const file = form.get('file') as File | null;
  const clientOrg = form.get('client_org_id') as string | null;
  const trackId = (form.get('track_id') as string | null) || null;
  if (!file || !clientOrg) return NextResponse.json({ error: 'file and client_org_id required' }, { status: 400 });
  if (!ALLOWED.has(file.type)) return NextResponse.json({ error: `Unsupported type ${file.type}` }, { status: 400 });
  if (file.size <= 0 || file.size > MAX) return NextResponse.json({ error: 'File must be 1 byte–25 MB' }, { status: 400 });

  // Access check BEFORE writing bytes: client_orgs RLS returns the row only if the caller
  // may touch this client, so a forged client_org_id can't even land an orphan object.
  const { data: allowed } = await supabase.from('client_orgs').select('id').eq('id', clientOrg).maybeSingle();
  if (!allowed) return NextResponse.json({ error: 'Access denied to client organisation' }, { status: 403 });

  const bytes = new Uint8Array(await file.arrayBuffer());
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const key = `${clientOrg}/${sha256}`;

  await putObject(key, bytes, file.type);
  // record_document re-checks allowed_client_orgs() in Postgres (defence in depth).

  const { data: docId, error } = await supabase.rpc('record_document', {
    p_client_org_id: clientOrg, p_track_id: trackId,
    p_filename: file.name, p_mime: file.type, p_size: file.size,
    p_sha256: sha256, p_storage_path: key,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });

  // auto-propose a checklist slot from the filename (advisor still confirms — never auto-fills)
  const { data: checklist } = await supabase
    .from('document_checklists').select('id, name, slot_key')
    .eq('framework_key', 'popia').eq('active', true);
  const guess = checklist ? proposeSlot(file.name, checklist) : null;
  if (guess) {
    await supabase.rpc('set_document_link', {
      p_document_id: docId, p_checklist_id: guess.id, p_status: 'proposed', p_confidence: guess.confidence,
    });
  }
  return NextResponse.json({ id: docId, sha256, proposed: guess?.id ?? null });
}
