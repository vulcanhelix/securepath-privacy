import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { presignUpload } from '@/lib/storage';

// W4-09 (NFR-02) — mint a short-lived presigned PUT so the browser writes bytes
// straight to the client's evidence-store prefix; the row is then registered via
// POST /api/documents (JSON body) which verifies the object landed.
//
//   POST {client_org_id, mime, size, sha256}
//   → 200 {url, key, headers, expires_in}   (PUT url + headers verbatim)
//
// The object key is derived server-side as <client_org_id>/<sha256> — the URL
// only ever covers a prefix the caller's RLS view proves they may touch, and the
// signed checksum pins the bytes to the key (least privilege: one key, one hash,
// minutes to live). Registering still goes through record_document under the
// caller's JWT, so the upload lands at scan_status='pending' and enters the
// W4-03 malware-scan queue exactly like the old server-streamed path.

const ALLOWED = new Set([
  'application/pdf', 'image/png', 'image/jpeg',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // docx
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',        // xlsx
  'text/plain', 'text/csv',
]);
const MAX = 25 * 1024 * 1024; // 25 MB — enforced again at register time via HeadObject
const SHA256 = /^[0-9a-f]{64}$/;

export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  let body: { client_org_id?: string; mime?: string; size?: number; sha256?: string };
  try { body = await req.json(); } catch { return NextResponse.json({ error: 'JSON body required' }, { status: 400 }); }
  const { client_org_id: clientOrg, mime, size, sha256 } = body;
  if (!clientOrg) return NextResponse.json({ error: 'client_org_id required' }, { status: 400 });
  if (!mime || !ALLOWED.has(mime)) return NextResponse.json({ error: `Unsupported type ${mime}` }, { status: 400 });
  if (typeof size !== 'number' || size <= 0 || size > MAX)
    return NextResponse.json({ error: 'File must be 1 byte–25 MB' }, { status: 400 });
  if (!sha256 || !SHA256.test(sha256))
    return NextResponse.json({ error: 'sha256 (64 lowercase hex) required — it is the object key' }, { status: 400 });

  // Permission check BEFORE any signed capability exists: client_orgs RLS
  // returns the row only if the caller may see this client, so a forged
  // client_org_id can't mint a URL into another tenant's prefix.
  const { data: allowed } = await supabase.from('client_orgs').select('id').eq('id', clientOrg).maybeSingle();
  if (!allowed) return NextResponse.json({ error: 'Access denied to client organisation' }, { status: 403 });

  const key = `${clientOrg}/${sha256}`;
  const { url, headers, expires_in } = await presignUpload(key, mime, Buffer.from(sha256, 'hex').toString('base64'));
  return NextResponse.json({ url, key, headers, expires_in });
}
