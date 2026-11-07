import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'crypto';
import { serverClient } from '@/lib/supabase';
import { putObject, headObject, deleteObject } from '@/lib/storage';
import { proposeSlot } from '@/lib/classify';

const ALLOWED = new Set([
  'application/pdf', 'image/png', 'image/jpeg',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // docx
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',        // xlsx
  'text/plain', 'text/csv',
]);
const MAX = 25 * 1024 * 1024; // 25 MB
const SHA256 = /^[0-9a-f]{64}$/;

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

// shared tail: record_document RPC + optional checklist-slot proposal
async function registerDocument(supabase: Awaited<ReturnType<typeof serverClient>>, p: {
  clientOrg: string; trackId: string | null; filename: string; mime: string;
  size: number; sha256: string; storagePath: string; supersedes: string | null;
  framework: string; classify: boolean;
}) {
  // record_document re-checks allowed_client_orgs() in Postgres (defence in depth).
  const { data: docId, error } = await supabase.rpc('record_document', {
    p_client_org_id: p.clientOrg, p_track_id: p.trackId,
    p_filename: p.filename, p_mime: p.mime, p_size: p.size,
    p_sha256: p.sha256, p_storage_path: p.storagePath, p_supersedes: p.supersedes,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });

  // evidence uploads (e.g. W2-12 designation appointment letters) opt out of
  // the gap-map slot proposal — they are not policy documents
  if (!p.classify) return NextResponse.json({ id: docId, sha256: p.sha256, proposed: null });

  // auto-propose a checklist slot from the filename (advisor still confirms — never auto-fills)
  const { data: checklist } = await supabase
    .from('document_checklists').select('id, name, slot_key')
    .eq('framework_key', p.framework).eq('active', true);
  const guess = checklist ? proposeSlot(p.filename, checklist) : null;
  if (guess) {
    await supabase.rpc('set_document_link', {
      p_document_id: docId, p_checklist_id: guess.id, p_status: 'proposed', p_confidence: guess.confidence,
    });
  }
  return NextResponse.json({ id: docId, sha256: p.sha256, proposed: guess?.id ?? null });
}

// POST — two body shapes:
//   multipart (legacy/server-streamed): file + client_org_id (+ track_id, framework,
//     supersedes, classify) — bytes transit the Next server.
//   JSON (W4-09 direct-upload register): after PUT to the presigned URL from
//     POST /api/documents/presign — {client_org_id, filename, mime, size, sha256,
//     storage_path, track_id?, framework?, supersedes?, classify?}. We HEAD the
//     object to prove the upload landed and that its size/checksum match before
//     creating the row.
export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  if ((req.headers.get('content-type') ?? '').includes('application/json')) {
    return registerDirectUpload(req, supabase);
  }
  return multipartUpload(req, supabase);
}

// W4-09 — register a direct-uploaded object (NFR-02).
async function registerDirectUpload(req: NextRequest, supabase: Awaited<ReturnType<typeof serverClient>>) {
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return NextResponse.json({ error: 'JSON body required' }, { status: 400 }); }

  const clientOrg = body.client_org_id as string | undefined;
  const filename = (body.filename as string | undefined)?.slice(0, 255);
  const mime = body.mime as string | undefined;
  const sha256 = body.sha256 as string | undefined;
  const storagePath = body.storage_path as string | undefined;
  const trackId = (body.track_id as string | null | undefined) ?? null;
  const supersedes = (body.supersedes as string | null | undefined) ?? null;
  const framework = (body.framework as string | undefined) ?? 'popia';
  const classify = body.classify !== false;

  if (!clientOrg || !filename || !mime || !sha256 || !storagePath)
    return NextResponse.json({ error: 'client_org_id, filename, mime, sha256, storage_path required' }, { status: 400 });
  if (!ALLOWED.has(mime)) return NextResponse.json({ error: `Unsupported type ${mime}` }, { status: 400 });
  if (!SHA256.test(sha256)) return NextResponse.json({ error: 'sha256 must be 64 lowercase hex' }, { status: 400 });
  // tenant scope is structural, not declared: the path must be exactly the
  // content-addressed key the presign endpoint would have minted for this client
  if (storagePath !== `${clientOrg}/${sha256}`)
    return NextResponse.json({ error: 'storage_path must be <client_org_id>/<sha256>' }, { status: 400 });

  // Access check: RLS scopes client_orgs to the caller — a forged client_org_id
  // can never satisfy the path rule anyway, but fail closed on visibility too.
  const { data: allowed } = await supabase.from('client_orgs').select('id').eq('id', clientOrg).maybeSingle();
  if (!allowed) return NextResponse.json({ error: 'Access denied to client organisation' }, { status: 403 });

  // prove the bytes really landed: object exists, within the size cap, and —
  // where the store recorded the signed checksum — the bytes match the key
  const head = await headObject(storagePath);
  if (!head) return NextResponse.json({ error: 'upload not found in the store — PUT to the signed URL first' }, { status: 400 });
  if (head.size <= 0 || head.size > MAX) {
    try { await deleteObject(storagePath); } catch {}
    return NextResponse.json({ error: 'Uploaded object is empty or over 25 MB' }, { status: 400 });
  }
  const shaB64 = Buffer.from(sha256, 'hex').toString('base64');
  if (head.checksumSha256 && head.checksumSha256 !== shaB64)
    return NextResponse.json({ error: 'stored bytes do not match the claimed sha256' }, { status: 400 });

  return registerDocument(supabase, {
    clientOrg, trackId, filename, mime, size: head.size, sha256,
    storagePath, supersedes, framework, classify,
  });
}

// interim path (kept): bytes stream through the server to the same store.
async function multipartUpload(req: NextRequest, supabase: Awaited<ReturnType<typeof serverClient>>) {
  const form = await req.formData();
  const file = form.get('file') as File | null;
  const clientOrg = form.get('client_org_id') as string | null;
  const trackId = (form.get('track_id') as string | null) || null;
  const framework = (form.get('framework') as string | null) || 'popia';
  const supersedes = (form.get('supersedes') as string | null) || null;
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

  return registerDocument(supabase, {
    clientOrg, trackId, filename: file.name, mime: file.type, size: file.size, sha256,
    storagePath: key, supersedes, framework, classify: form.get('classify') !== 'false',
  });
}
