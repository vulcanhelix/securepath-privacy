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
    .from('assessment_sessions')
    .select(`
      id, title, framework, status, score_pct, rating, org_name, auditor_name, audit_date, audit_ref, created_at, updated_at,
      client_orgs (name),
      assessment_scores (section_scores, overall_score, completion_pct, risk_summary, critical_gaps)
    `)
    .eq('id', id)
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  if (!data) return NextResponse.json({ error: 'assessment not found' }, { status: 404 });
  
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
  
  const { error } = await supabase.rpc('update_assessment', {
    p_id: id,
    p_title: body.title || null,
    p_org_name: body.org_name || null,
    p_auditor_name: body.auditor_name || null,
    p_audit_date: body.audit_date || null,
    p_audit_ref: body.audit_ref || null,
    p_status: body.status || null,
  });

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  
  return NextResponse.json({ success: true });
}