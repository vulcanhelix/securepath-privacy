import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { id } = await params;

  const { data, error } = await supabase
    .from('assessment_responses')
    .select(`
      id, response, findings, responsible_party, target_date, status, updated_at,
      assessment_questions (
        id, uid, section_id, section_name, subsection, question_number,
        question, why_matters, regulatory_ref, risk, evidence_req, remediation
      )
    `)
    .eq('session_id', id);

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json(data);
}

export async function PUT(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { id } = await params;
  const body = await req.json();
  
  if (Array.isArray(body.responses)) {
    // Batch update
    const { error } = await supabase.rpc('batch_upsert_responses', {
      p_session_id: id,
      p_responses: JSON.stringify(body.responses),
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  } else {
    // Single response update
    const { error } = await supabase.rpc('upsert_response', {
      p_session_id: id,
      p_question_id: body.question_id,
      p_response: body.response,
      p_findings: body.findings || null,
      p_responsible_party: body.responsible_party || null,
      p_target_date: body.target_date || null,
      p_status: body.status || 'not_started',
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ success: true });
}