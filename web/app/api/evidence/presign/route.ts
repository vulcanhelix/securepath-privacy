import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { presignUpload } from '@/lib/storage';

// W4-09 (NFR-02, FR-EVD-02) — mint a short-lived presigned PUT so the browser
// writes evidence bytes straight to the client org's store prefix (files never
// rest on the device), then register via POST /api/evidence (JSON body) →
// upload_evidence → the W4-03 scan queue. Same tenant-scoped key convention as
// documents: <client_org_id>/<sha256>, derived server-side after an RLS
// visibility check on the programme.

const ALLOWED = new Set([
  'application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'image/heic', 'image/heif',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // docx
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',        // xlsx
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',// pptx
  'application/msword', 'application/vnd.ms-excel',
  'text/plain', 'text/csv',
]);
const MAX = 25 * 1024 * 1024; // 25 MB — enforced again at register time via HeadObject
const SHA256 = /^[0-9a-f]{64}$/;

export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  let body: { programme_id?: string; mime?: string; size?: number; sha256?: string };
  try { body = await req.json(); } catch { return NextResponse.json({ error: 'JSON body required' }, { status: 400 }); }
  const { programme_id: programmeId, mime, size, sha256 } = body;
  if (!programmeId) return NextResponse.json({ error: 'programme_id required' }, { status: 400 });
  if (!mime || !ALLOWED.has(mime)) return NextResponse.json({ error: `Unsupported type ${mime}` }, { status: 400 });
  if (typeof size !== 'number' || size <= 0 || size > MAX)
    return NextResponse.json({ error: 'File must be 1 byte–25 MB' }, { status: 400 });
  if (!sha256 || !SHA256.test(sha256))
    return NextResponse.json({ error: 'sha256 (64 lowercase hex) required — it is the object key' }, { status: 400 });

  // Permission check BEFORE minting a capability: programmes RLS returns the
  // row only if the caller may see this programme — a forged programme_id gets
  // nothing. upload_evidence re-checks write roles at register time.
  const { data: prog } = await supabase
    .from('programmes')
    .select('id, client_org_id')
    .eq('id', programmeId)
    .maybeSingle();
  if (!prog) return NextResponse.json({ error: 'Access denied to programme' }, { status: 403 });

  const key = `${prog.client_org_id}/${sha256}`;
  const { url, headers, expires_in } = await presignUpload(key, mime, Buffer.from(sha256, 'hex').toString('base64'));
  return NextResponse.json({ url, key, headers, expires_in, client_org_id: prog.client_org_id });
}
