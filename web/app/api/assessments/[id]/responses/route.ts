import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

const validResponses = ['fully_compliant', 'partial', 'under_review', 'non_compliant', 'na'];
const validStatuses = ['not_started', 'in_progress', 'complete', 'na'];

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

  let body: any;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: 'invalid json' }, { status: 400 });
  }

  if (Array.isArray(body.responses)) {
    // Validate batch
    for (const r of body.responses) {
      if (!r.question_id) return NextResponse.json({ error: 'question_id required in batch' }, { status: 400 });
      if (r.response && !validResponses.includes(r.response)) {
        return NextResponse.json({ error: `invalid response value: ${r.response}` }, { status: 400 });
      }
    }

    const { error } = await supabase.rpc('batch_upsert_responses', {
      p_session_id: id,
      p_responses: body.responses,
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  } else {
    // Single response
    if (!body.question_id) return NextResponse.json({ error: 'question_id required' }, { status: 400 });
    if (!body.response || !validResponses.includes(body.response)) {
      return NextResponse.json({ error: `invalid response value` }, { status: 400 });
    }
    if (body.status && !validStatuses.includes(body.status)) {
      return NextResponse.json({ error: `invalid status value` }, { status: 400 });
    }

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