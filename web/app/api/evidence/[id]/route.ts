import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { getObject } from '@/lib/storage';

// W2-06 — stream an evidence file through our server, only after RLS confirms
// the caller may see the row (evidence_items_read). No public bucket, no
// device copies — same serving path as /api/documents/[id] (NFR-02).

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
    .select('file_key, evidence_ref')
    .eq('id', id)
    .maybeSingle();
  if (!ev?.file_key) return NextResponse.json({ error: 'not found' }, { status: 404 });

  const obj = await getObject(ev.file_key);
  const mime = obj.contentType || 'application/octet-stream';
  const base = (ev.evidence_ref ?? `evidence-${id.slice(0, 8)}`).replace(/[^\w.\- ]/g, '_');
  const inline = req.nextUrl.searchParams.get('inline') === '1';
  return new NextResponse(obj.body, {
    headers: {
      'Content-Type': mime,
      'Content-Disposition': `${inline ? 'inline' : 'attachment'}; filename="${base}${EXT[mime] ?? ''}"`,
      'X-Content-Type-Options': 'nosniff',
      ...(inline ? { 'Content-Security-Policy': "script-src 'none'" } : {}),
    },
  });
}
