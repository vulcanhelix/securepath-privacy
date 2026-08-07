import { NextResponse, type NextRequest } from 'next/server';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { serverClient } from '@/lib/supabase';

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string; documentId: string }> }) {
  const { id, documentId } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });
  const { data: document } = await supabase.from('assessment_documents').select('original_filename, mime, storage_path').eq('id', documentId).eq('session_id', id).single();
  if (!document) return NextResponse.json({ error: 'document not found' }, { status: 404 });
  try {
    const root = process.env.ASSESSMENT_EVIDENCE_DIR || '/opt/securepath/evidence';
    const body = await readFile(path.join(root, document.storage_path));
    return new NextResponse(body, { headers: { 'Content-Type': document.mime, 'Content-Disposition': `attachment; filename="${document.original_filename.replace(/["\r\n]/g, '')}"` } });
  } catch {
    return NextResponse.json({ error: 'file unavailable' }, { status: 404 });
  }
}
