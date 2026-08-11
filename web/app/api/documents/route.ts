import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'crypto';
import { serverClient } from '@/lib/supabase';
import { putObject } from '@/lib/storage';

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

  const bytes = new Uint8Array(await file.arrayBuffer());
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const key = `${clientOrg}/${sha256}`;

  // Write bytes first, then the ledger row. The RPC re-checks allowed_client_orgs()
  // in Postgres, so a forged client_org_id is rejected there even though we already wrote
  // the object under that prefix (orphan object, harmless, GC-able).
  await putObject(key, bytes, file.type);

  const { data: docId, error } = await supabase.rpc('record_document', {
    p_client_org_id: clientOrg, p_track_id: trackId,
    p_filename: file.name, p_mime: file.type, p_size: file.size,
    p_sha256: sha256, p_storage_path: key,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ id: docId, sha256 });
}
