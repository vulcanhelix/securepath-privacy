import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'crypto';
import { serverClient } from '@/lib/supabase';
import { putObject } from '@/lib/storage';

// Issue an approved policy: render its body to an immutable evidence document that fills the
// policy's Stage-2 checklist slot. RLS returns the policy only if the caller may see it;
// issue_policy re-checks access + requires 'approved'.
export async function POST(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data: policy } = await supabase
    .from('policies').select('client_org_id, title, body, version, approval_status')
    .eq('id', id).maybeSingle();
  if (!policy) return NextResponse.json({ error: 'not found' }, { status: 404 });
  if (policy.approval_status !== 'approved')
    return NextResponse.json({ error: 'policy must be approved before issue' }, { status: 400 });

  const bytes = new TextEncoder().encode(policy.body);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const key = `${policy.client_org_id}/policy-${id}-v${policy.version}.md`;
  await putObject(key, bytes, 'text/markdown');

  const { data: docId, error } = await supabase.rpc('issue_policy', {
    p_policy_id: id, p_storage_path: key, p_sha256: sha256, p_size: bytes.length,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ document_id: docId });
}
