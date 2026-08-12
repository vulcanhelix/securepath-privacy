import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

// Compile a monthly report: baseline (Stage 1 approved assessment) + this period's movement
// (remediation progress, documents issued). The baseline runs through everything.
export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const period = (await req.json().catch(() => ({})))?.period || new Date().toISOString().slice(0, 7);

  const { data: client } = await supabase.from('client_orgs').select('name').eq('id', id).maybeSingle();
  if (!client) return NextResponse.json({ error: 'not found' }, { status: 404 });

  const [{ data: baseline }, { data: tasks }, { data: docs }] = await Promise.all([
    supabase.from('assessment_sessions').select('score_pct, rating, audit_date')
      .eq('client_org_id', id).eq('approval_status', 'approved')
      .order('created_at', { ascending: true }).limit(1).maybeSingle(),
    supabase.from('tasks').select('priority, status').eq('client_org_id', id),
    supabase.from('documents').select('original_filename, created_at').eq('client_org_id', id)
      .order('created_at', { ascending: false }),
  ]);

  const all = tasks ?? [];
  const done = all.filter(t => t.status === 'done').length;
  const total = all.length;
  const pct = total ? Math.round(done / total * 100) : 0;
  const ch = all.filter(t => ['critical', 'high'].includes(t.priority));
  const chDone = ch.filter(t => t.status === 'done').length;
  const openCritHigh = ch.filter(t => t.status !== 'done');
  const issuedThisPeriod = (docs ?? []).filter(d => (d.created_at ?? '').slice(0, 7) === period);

  const ratingLabel = (r: string | null) =>
    ({ satisfactory: 'Satisfactory', requires_improvement: 'Requires improvement', significant_gaps: 'Significant gaps' } as Record<string, string>)[r ?? ''] ?? '—';

  const lines = [
    `# ${client.name} — Monthly Compliance Report`,
    `_Period ${period} · POPIA & PAIA privacy track_`,
    '',
    '## Baseline',
    baseline
      ? `Stage 1 assessment (month zero): **${baseline.score_pct ?? '—'}%** — ${ratingLabel(baseline.rating)}.`
      : 'No signed-off Stage 1 baseline on record.',
    '',
    '## Movement this period',
    `Remediation programme: **${done}/${total} tasks complete (${pct}%)**. Critical & high priority: **${chDone}/${ch.length}**.`,
    baseline?.score_pct != null
      ? `The programme is closing the gaps identified against the ${baseline.score_pct}% baseline; ${pct}% of remediation is complete.`
      : '',
    '',
    '## Documents issued this period',
    issuedThisPeriod.length
      ? issuedThisPeriod.map(d => `- ${d.original_filename}`).join('\n')
      : '_None issued this period._',
    '',
    '## Outstanding critical & high items',
    openCritHigh.length
      ? openCritHigh.map(t => `- ${t.priority.toUpperCase()}: task pending`).join('\n')
      : '_All critical and high items are complete._',
    '',
    '## Next period',
    'Continue the remediation programme and maintain the registers. Annual reassessment renews against the baseline.',
  ];

  const { data: reportId, error } = await supabase.rpc('record_monthly_report', {
    p_client_org_id: id, p_period: period, p_title: `${client.name} — ${period} compliance report`,
    p_body: lines.join('\n'), p_baseline_pct: baseline?.score_pct ?? null,
    p_baseline_rating: baseline?.rating ?? null, p_tasks_done: done, p_tasks_total: total,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ id: reportId });
}
