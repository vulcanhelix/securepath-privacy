import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import Workbench from './workbench';

export const dynamic = 'force-dynamic';

// Stage 3 — Policy creation & approval. Content-driven: templates come from policy_templates.
export default async function ClientPolicies({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs').select('id, name').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');

  const framework = 'popia';
  const [{ data: membership }, { data: checklist }, { data: links }, { data: templates }, { data: policies }] =
    await Promise.all([
      supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
      supabase.from('document_checklists').select('id, slot_key, name, required').eq('framework_key', framework).eq('active', true).order('sort'),
      supabase.from('document_links').select('checklist_id, status').eq('client_org_id', id).eq('status', 'confirmed'),
      supabase.from('policy_templates').select('id, slot_key, name').eq('framework_key', framework).eq('active', true),
      supabase.from('policies').select('id, checklist_id, title, body, approval_status, updated_at').eq('client_org_id', id).order('created_at', { ascending: false }),
    ]);

  const canEdit = ['practice_owner', 'practice_consultant', 'client_admin'].includes(membership?.role ?? '');
  const filled = new Set((links ?? []).map(l => l.checklist_id));
  const hasPolicy = new Set((policies ?? []).map(p => p.checklist_id));
  const tplBySlot = new Map((templates ?? []).map(t => [t.slot_key, t]));

  // gaps a template can draft: required slot, no confirmed doc, no policy yet, template exists
  const draftable = (checklist ?? []).filter(c =>
    c.required && !filled.has(c.id) && !hasPolicy.has(c.id) && tplBySlot.has(c.slot_key))
    .map(c => ({ checklist_id: c.id, slot_key: c.slot_key, name: c.name, template_id: tplBySlot.get(c.slot_key)!.id }));

  const approved = (policies ?? []).filter(p => p.approval_status === 'approved').length;

  return (
    <>
      <p className="muted"><Link href="/dashboard">← Clients</Link> · <Link href={`/clients/${id}/documents`}>Stage 2 — Documents</Link></p>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '.75rem' }}>
        <h1 style={{ flex: 1 }}>{client.name} — Policy workbench</h1>
        <span className="badge">Stage 3</span>
      </div>
      <p className="muted">Draft the policies that close the gaps from Stage 2, then approve each one.
        <strong> {approved}/{policies?.length ?? 0} policies approved.</strong></p>

      <Workbench clientOrgId={id} canEdit={canEdit} draftable={draftable} policies={policies ?? []} />
    </>
  );
}
