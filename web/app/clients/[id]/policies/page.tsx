import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { trackKindFor } from '@/lib/track';
import Workbench from './workbench';

export const dynamic = 'force-dynamic';

// Stage 3 — Policy creation & approval. Content-driven: templates come from policy_templates.
export default async function ClientPolicies(
  { params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ framework?: string }> }) {
  const { id } = await params;
  const framework = (await searchParams).framework ?? 'popia';
  const qs = framework === 'popia' ? '' : `?framework=${framework}`;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs').select('id, name').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');
  const [{ data: membership }, { data: checklist }, { data: links }, { data: templates }, { data: policies }] =
    await Promise.all([
      supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle(),
      supabase.from('document_checklists').select('id, slot_key, name, required').eq('framework_key', framework).eq('active', true).order('sort'),
      supabase.from('document_links').select('checklist_id, status').eq('client_org_id', id).eq('status', 'confirmed'),
      supabase.from('policy_templates').select('id, slot_key, name').eq('framework_key', framework).eq('active', true),
      supabase.from('policies').select('id, checklist_id, title, body, approval_status, updated_at').eq('client_org_id', id).order('created_at', { ascending: false }),
    ]);

  const role = membership?.role ?? '';
  const canEdit = ['practice_owner', 'practice_consultant', 'client_admin'].includes(role);
  const isAdvisor = ['practice_owner', 'practice_consultant'].includes(role);
  const filled = new Set((links ?? []).map(l => l.checklist_id));
  const hasPolicy = new Set((policies ?? []).map(p => p.checklist_id));
  const tplBySlot = new Map((templates ?? []).map(t => [t.slot_key, t]));

  // gaps a template can draft: required slot, no confirmed doc, no policy yet, template exists
  const draftable = (checklist ?? []).filter(c =>
    c.required && !filled.has(c.id) && !hasPolicy.has(c.id) && tplBySlot.has(c.slot_key))
    .map(c => ({ checklist_id: c.id, slot_key: c.slot_key, name: c.name, template_id: tplBySlot.get(c.slot_key)!.id }));

  const approved = (policies ?? []).filter(p => ['approved', 'issued'].includes(p.approval_status)).length;

  // Gate 2 ready: every required slot that has a policy is approved-or-issued, and no drafts remain
  const trackKind = await trackKindFor(supabase, framework);
  const { data: track } = await supabase.from('tracks').select('id, current_stage')
    .eq('client_org_id', id).eq('track_kind', trackKind).maybeSingle();
  const anyDraft = (policies ?? []).some(p => ['draft_ai', 'draft_human'].includes(p.approval_status));
  const gate2Ready = (policies?.length ?? 0) > 0 && !anyDraft && draftable.length === 0;

  return (
    <>
      <p className="muted"><Link href="/dashboard">← Clients</Link> · <Link href={`/clients/${id}/documents${qs}`}>Stage 2 — Documents</Link> · <Link href={`/clients/${id}/manual${qs}`}>Stage 4 — Manual →</Link></p>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '.75rem' }}>
        <h1 style={{ flex: 1 }}>{client.name} — Policy workbench</h1>
        <span className="badge">Stage 3</span>
      </div>
      <p className="muted">Draft the policies that close the gaps from Stage 2, then approve each one.
        <strong> {approved}/{policies?.length ?? 0} policies approved.</strong></p>

      <Workbench clientOrgId={id} canEdit={canEdit} isAdvisor={isAdvisor} draftable={draftable}
                 policies={policies ?? []} trackId={track?.id ?? null} trackStage={track?.current_stage ?? null}
                 gate2Ready={gate2Ready} />
    </>
  );
}
