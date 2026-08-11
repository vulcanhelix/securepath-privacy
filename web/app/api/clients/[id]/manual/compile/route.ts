import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

// Compile the PIMS manual from the client's approved policies + confirmed documents, structured
// by the 27701-aligned outline. Content-driven: the chapter structure comes from manual_outlines.
export async function POST(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data: client } = await supabase.from('client_orgs').select('name').eq('id', id).maybeSingle();
  if (!client) return NextResponse.json({ error: 'not found' }, { status: 404 });

  const framework = 'popia';
  const [{ data: outline }, { data: checklist }, { data: policies }, { data: links }, { data: docs }] =
    await Promise.all([
      supabase.from('manual_outlines').select('chapter_key, title, clause_ref, narrative, source_slots')
        .eq('framework_key', framework).eq('active', true).order('sort'),
      supabase.from('document_checklists').select('id, slot_key, name').eq('framework_key', framework),
      supabase.from('policies').select('checklist_id, title, body, approval_status').eq('client_org_id', id),
      supabase.from('document_links').select('checklist_id, document_id, status').eq('client_org_id', id).eq('status', 'confirmed'),
      supabase.from('documents').select('id, original_filename').eq('client_org_id', id),
    ]);

  const slotById = new Map((checklist ?? []).map(c => [c.id, c]));           // checklist id -> {slot_key,name}
  const idBySlot = new Map((checklist ?? []).map(c => [c.slot_key, c.id]));  // slot_key -> checklist id
  const docName = new Map((docs ?? []).map(d => [d.id, d.original_filename]));
  const confirmedDocsFor = (checklistId: string) =>
    (links ?? []).filter(l => l.checklist_id === checklistId).map(l => docName.get(l.document_id)).filter(Boolean);
  const approvedPolicyFor = (checklistId: string) =>
    (policies ?? []).find(p => p.checklist_id === checklistId && ['approved', 'issued'].includes(p.approval_status));

  const lines: string[] = [
    `# ${client.name} — Privacy Information Management System (PIMS)`,
    `_Compiled ${new Date().toISOString().slice(0, 10)} · ISO/IEC 27701-aligned · Draft for IO sign-off_`,
    '',
  ];
  (outline ?? []).forEach((ch, i) => {
    lines.push(`## ${i + 1}. ${ch.title}`);
    if (ch.clause_ref) lines.push(`_ISO/IEC ${ch.clause_ref}_`);
    if (ch.narrative) lines.push('', ch.narrative);
    for (const slot of (ch.source_slots ?? []) as string[]) {
      const cid = idBySlot.get(slot);
      if (!cid) continue;
      const label = slotById.get(cid)?.name ?? slot;
      const policy = approvedPolicyFor(cid);
      const found = confirmedDocsFor(cid);
      if (policy) {
        lines.push('', `### ${label}`, policy.body);
      } else if (found.length) {
        lines.push('', `**${label}:** ${found.join(', ')}`);
      } else {
        lines.push('', `**${label}:** _— not yet provided_`);
      }
    }
    lines.push('');
  });

  const body = lines.join('\n');
  const { data: manualId, error } = await supabase.rpc('record_manual', {
    p_client_org_id: id, p_title: `${client.name} PIMS Manual`, p_body: body,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ id: manualId });
}
