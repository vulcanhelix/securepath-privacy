import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { presignDownload, deleteObject } from '@/lib/storage';

// GET — W4-09 (NFR-02): the permission check happens here (RLS select returns the
// row only for a caller who may see it), then we 302 to a 60-second signed URL —
// bytes flow client ↔ store directly, never through this server. The signed URL
// carries the download filename + disposition (S3 response-content-* overrides).
//
// W4-03 scan gate on the read path: quarantined ('infected') and scan-failed
// ('error') objects are never signed — the signed path cannot bypass the
// malware gate. 'pending' objects may still be viewed (the gate controls
// acceptance/confirmation, not visibility); acceptance remains Postgres-enforced.

export async function GET(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data: doc } = await supabase
    .from('documents')
    .select('original_filename, mime, storage_path, scan_status')
    .eq('id', id)
    .maybeSingle();
  if (!doc) return NextResponse.json({ error: 'not found' }, { status: 404 });
  if (doc.scan_status === 'infected')
    return NextResponse.json({ error: 'document is quarantined — malware detected (W4-03)' }, { status: 403 });
  if (doc.scan_status === 'error')
    return NextResponse.json({ error: 'document failed its malware scan and cannot be served (W4-03)' }, { status: 403 });

  // ?inline=1 renders in the browser (preview modal); default stays a download.
  // Served from the storage origin now — stored HTML can't reach app cookies.
  const inline = req.nextUrl.searchParams.get('inline') === '1';
  const url = await presignDownload(doc.storage_path, doc.original_filename, doc.mime || 'application/octet-stream', inline);
  return NextResponse.redirect(url, 302);
}

// DELETE — only for junk uploads. delete_document() in Postgres enforces the rules
// (never confirmed, no version history, not task evidence); on success it returns the
// storage path and we remove the object.
export async function DELETE(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  // NULL path = another document row still shares this content-addressed object; keep the bytes
  const { data: path, error } = await supabase.rpc('delete_document', { p_document_id: id });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });

  try { if (path) await deleteObject(path); } catch { /* orphan object is harmless; DB row is gone */ }
  return NextResponse.json({ ok: true });
}
