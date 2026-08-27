import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { getObject } from '@/lib/storage';

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
