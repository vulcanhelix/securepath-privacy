import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { trackKindFor } from '@/lib/track';
import { resolveSpec } from '@/lib/report/spec';
import { buildReportPayload, type QuestionRow, type ResponseRow } from '@/lib/report/compile';
import type { ReportOverrides } from '@/lib/report/types';

// Compile (or recompile) the working assessment report for a client+framework.
// Creates the next version in the chain if no working draft exists, gathers a full
// snapshot of the live data, and stores it as the report's JSONB payload. Repeatable —
// advisor overrides live on the row and survive recompiles.
export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const framework: string = body?.framework || 'popia';

  const { data: client } = await supabase.from('client_orgs')
    .select('name, org_scale').eq('id', id).maybeSingle();
  if (!client) return NextResponse.json({ error: 'not found' }, { status: 404 });

  // chain: every report for this client+framework (prior payload summaries feed movement)
  const { data: chain, error: chainErr } = await supabase.from('assessment_reports')
    .select('id, version, kind, title, approval_status, issued_at, overrides, session_id, content_pack_id, payload')
    .eq('client_org_id', id).eq('framework_key', framework).order('version');
  if (chainErr) return NextResponse.json({ error: chainErr.message }, { status: 500 });
  let report = (chain ?? []).find(r => ['draft_ai', 'draft_human'].includes(r.approval_status));

  if (!report) {
    const hasIssued = (chain ?? []).some(r => ['issued', 'superseded'].includes(r.approval_status));
    const kind: string = body?.kind || (hasIssued ? 'post_documentation' : 'gap_assessment');
    const title = `${client.name} — ${framework.toUpperCase()} Compliance Assessment Report`;
    const { data: rid, error } = await supabase.rpc('create_assessment_report', {
      p_client_org_id: id, p_framework: framework, p_kind: kind, p_title: title,
      p_session_id: body?.session_id ?? null,
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 403 });
    const { data: created } = await supabase.from('assessment_reports')
      .select('id, version, kind, title, approval_status, issued_at, overrides, session_id, content_pack_id, payload')
      .eq('id', rid).maybeSingle();
    if (!created) return NextResponse.json({ error: 'report not visible after create' }, { status: 500 });
    report = created;
  }

  const trackKind = await trackKindFor(supabase, framework);

  // a failed source query must fail the compile — silently-empty data would snapshot
  // an approvable report where every control reads "not assessed"
  const results = await Promise.all([
    supabase.from('assessment_sessions')
      .select('org_name, auditor_name, audit_date, audit_ref, org_scale')
      .eq('id', report.session_id).maybeSingle(),
    supabase.from('content_packs').select('metadata').eq('id', report.content_pack_id).maybeSingle(),
    supabase.from('practices').select('name').maybeSingle(),
    supabase.from('tracks').select('baseline_pct, baseline_rating, baseline_at')
      .eq('client_org_id', id).eq('track_kind', trackKind).maybeSingle(),
    supabase.from('assessment_responses')
      .select('question_id, response, findings, responsible_party, target_date')
      .eq('session_id', report.session_id),
    supabase.from('documents').select('original_filename, source, created_at')
      .eq('client_org_id', id).in('source', ['policy', 'manual']).order('created_at'),
    supabase.from('documents').select('original_filename, created_at')
      .eq('client_org_id', id).eq('source', 'upload').order('created_at'),
    supabase.from('document_checklists').select('id, required').eq('framework_key', framework),
    supabase.from('document_links').select('checklist_id, status').eq('client_org_id', id),
  ]);
  const dbErr = results.map(r => r.error).find(Boolean);
  if (dbErr) return NextResponse.json({ error: dbErr.message }, { status: 500 });
  const [
    { data: session }, { data: pack }, { data: practice }, { data: track },
    { data: responses }, { data: issuedDocs }, { data: uploads },
    { data: checklist }, { data: links },
  ] = results;

  // questions of the report's pinned pack, scoped like assessment_question_in_scope():
  // popia always excludes the staff section (11); org-scale filters the large-only extras
  let qq = supabase.from('assessment_questions')
    .select('id, uid, section_id, section_name, subsection, question_number, question, regulatory_ref, risk, evidence_req, remediation')
    .eq('content_pack_id', report.content_pack_id)
    .in('applies_to', ['all', session?.org_scale ?? client.org_scale ?? 'sme']);
  if (framework === 'popia') qq = qq.neq('section_id', 11);
  const { data: questions } = await qq;
  if (!questions?.length) return NextResponse.json({ error: 'no questions in the report pack' }, { status: 500 });

  const { data: score, error: scoreErr } = await supabase.rpc('calculate_assessment_score', { p_session_id: report.session_id });
  if (scoreErr) return NextResponse.json({ error: scoreErr.message }, { status: 500 });

  // awareness is optional machinery — any error (including function-not-yet-deployed) = no section
  let awareness: unknown = null;
  try {
    const { data } = await supabase.rpc('get_awareness_report', { p_client_org_id: id, p_framework: framework });
    if (data && (data as { available?: boolean }).available) awareness = data;
  } catch { /* not installed */ }

  const payload = buildReportPayload({
    spec: resolveSpec(pack?.metadata ?? null),
    kind: report.kind, version: report.version, framework,
    clientName: client.name, practiceName: practice?.name ?? null,
    session: {
      org_name: session?.org_name ?? null, auditor_name: session?.auditor_name ?? null,
      audit_date: session?.audit_date ?? null, audit_ref: session?.audit_ref ?? null,
    },
    score: score ?? null,
    questions: (questions ?? []) as QuestionRow[],
    responses: (responses ?? []) as ResponseRow[],
    track: track ?? null,
    chain: (chain ?? []).filter(c => c.id !== report!.id).map(c => ({
      version: c.version, kind: c.kind, title: c.title,
      approval_status: c.approval_status, issued_at: c.issued_at, payload: c.payload,
    })),
    issuedDocs: issuedDocs ?? [],
    checklist: checklist ?? [],
    confirmedChecklistIds: new Set((links ?? []).filter(l => l.status === 'confirmed').map(l => l.checklist_id)),
    uploads: uploads ?? [],
    frameworkLegend: (pack?.metadata as { framework_legend?: unknown } | null)?.framework_legend ?? null,
    awareness,
  }, (report.overrides ?? {}) as ReportOverrides);

  const { error: setErr } = await supabase.rpc('set_assessment_report_payload', {
    p_report_id: report.id, p_payload: payload,
  });
  if (setErr) return NextResponse.json({ error: setErr.message }, { status: 403 });
  return NextResponse.json({ id: report.id, version: report.version, kind: report.kind });
}
