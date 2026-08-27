import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { getObject, deleteObject } from '@/lib/storage';

// GET — stream the document through our server, only after RLS confirms the caller may
// see it (the select returns nothing otherwise). Works on MinIO (loopback) and S3 alike.
export async function GET(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data: doc } = await supabase
    .from('documents')
    .select('original_filename, mime, storage_path')
    .eq('id', id)
    .maybeSingle();
  if (!doc) return NextResponse.json({ error: 'not found' }, { status: 404 });

  const obj = await getObject(doc.storage_path);
  const safe = doc.original_filename.replace(/[^\w.\- ]/g, '_');
  // ?inline=1 renders in the browser (preview modal); default stays a download
  const inline = req.nextUrl.searchParams.get('inline') === '1';
  return new NextResponse(obj.body, {
    headers: {
      'Content-Type': doc.mime || obj.contentType,
      'Content-Disposition': `${inline ? 'inline' : 'attachment'}; filename="${safe}"`,
    },
  });
}

// DELETE — only for junk uploads. delete_document() in Postgres enforces the rules
// (never confirmed, no version history, not task evidence); on success it returns the
// storage path and we remove the object.
export async function DELETE(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data: path, error } = await supabase.rpc('delete_document', { p_document_id: id });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });

  try { if (path) await deleteObject(path); } catch { /* orphan object is harmless; DB row is gone */ }
  return NextResponse.json({ ok: true });
}
