import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'crypto';
import { serverClient } from '@/lib/supabase';
import { putObject } from '@/lib/storage';

// Gate 3: render the manual body to an immutable evidence document, then sign_off_manual
// (publishes, marks PAIA s.51 published, advances the track to Stage 5).
export async function POST(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data: manual } = await supabase
    .from('manuals').select('client_org_id, title, body, version, approval_status').eq('id', id).maybeSingle();
  if (!manual) return NextResponse.json({ error: 'not found' }, { status: 404 });

  const bytes = new TextEncoder().encode(manual.body);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const key = `${manual.client_org_id}/manual-${id}-v${manual.version}.md`;
  await putObject(key, bytes, 'text/markdown');

  const { data: docId, error } = await supabase.rpc('sign_off_manual', {
    p_manual_id: id, p_storage_path: key, p_sha256: sha256, p_size: bytes.length,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ document_id: docId });
}
