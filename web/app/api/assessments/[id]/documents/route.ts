import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { serverClient } from '@/lib/supabase';

const allowed = new Set(['application/pdf', 'image/png', 'image/jpeg', 'text/plain', 'text/csv',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']);
const maxSize = 25 * 1024 * 1024;

export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });
  const form = await req.formData();
  const file = form.get('file');
  if (!(file instanceof File)) return NextResponse.json({ error: 'file is required' }, { status: 400 });
  if (!allowed.has(file.type) || file.size <= 0 || file.size > maxSize) return NextResponse.json({ error: 'Unsupported file type or size (maximum 25 MB)' }, { status: 400 });
  const { data: session } = await supabase.from('assessment_sessions').select('id, client_org_id').eq('id', id).single();
  if (!session) return NextResponse.json({ error: 'assessment not found' }, { status: 404 });
  const bytes = Buffer.from(await file.arrayBuffer());
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const storagePath = `${session.client_org_id}/${id}/${crypto.randomUUID()}`;
  const root = process.env.ASSESSMENT_EVIDENCE_DIR || '/opt/securepath/evidence';
  await mkdir(path.join(root, session.client_org_id, id), { recursive: true });
  await writeFile(path.join(root, storagePath), bytes, { flag: 'wx' });
  const { data: documentId, error } = await supabase.rpc('record_assessment_document', {
    p_client_org_id: session.client_org_id, p_session_id: id, p_question_id: form.get('question_id') || null,
    p_original_filename: file.name.slice(0, 255), p_mime: file.type, p_size: file.size, p_sha256: sha256, p_storage_path: storagePath,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  await supabase.rpc('append_assessment_chat_turn', { p_session_id: id, p_role: 'user', p_kind: 'upload', p_content: `Uploaded evidence: ${file.name}`, p_question_id: form.get('question_id') || null });
  return NextResponse.json({ id: documentId, filename: file.name, sha256 });
}
