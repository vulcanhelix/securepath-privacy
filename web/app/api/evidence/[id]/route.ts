import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { presignDownload, headObject } from '@/lib/storage';

// W2-06/W4-09 (NFR-02) — the permission check happens here (RLS select on
// evidence_items returns the row only for a caller who may see it), then we 302
// to a 60-second signed URL — bytes flow client ↔ store directly, never through
// this server and never to the device permanently (FR-EVD-02).
//
// W4-03 scan gate on the read path: quarantined ('infected') and scan-failed
// ('error') objects are never signed. 'pending' may be viewed — the gate
// controls verification/acceptance, which stays Postgres-enforced.

const EXT: Record<string, string> = {
  'application/pdf': '.pdf',
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/webp': '.webp',
  'image/heic': '.heic',
  'image/heif': '.heif',
  'text/plain': '.txt',
  'text/csv': '.csv',
};

export async function GET(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data: ev } = await supabase
    .from('evidence_items')
    .select('file_key, evidence_ref, scan_status')
    .eq('id', id)
    .maybeSingle();
  if (!ev?.file_key) return NextResponse.json({ error: 'not found' }, { status: 404 });
  if (ev.scan_status === 'infected')
    return NextResponse.json({ error: 'evidence is quarantined — malware detected (W4-03)' }, { status: 403 });
  if (ev.scan_status === 'error')
    return NextResponse.json({ error: 'evidence failed its malware scan and cannot be served (W4-03)' }, { status: 403 });

  // evidence_items stores no mime — HEAD the object for the stored content-type
  // (one cheap metadata call; the bytes still go direct)
  const head = await headObject(ev.file_key);
  if (!head) return NextResponse.json({ error: 'not found' }, { status: 404 });
  const mime = head.contentType || 'application/octet-stream';

  const base = (ev.evidence_ref ?? `evidence-${id.slice(0, 8)}`).replace(/[^\w.\- ]/g, '_');
  const inline = req.nextUrl.searchParams.get('inline') === '1';
  const url = await presignDownload(ev.file_key, `${base}${EXT[mime] ?? ''}`, mime, inline);
  return NextResponse.redirect(url, 302);
}
