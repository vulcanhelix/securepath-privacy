import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

export async function GET(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  // RLS filters by client_org_id automatically
  const { data, error } = await supabase
    .from('assessment_sessions')
    .select(`
      id, title, framework, status, score_pct, rating, created_at, updated_at,
      client_orgs (name),
      assessment_scores (completion_pct, overall_score, risk_summary)
    `)
    .order('created_at', { ascending: false });

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json(data);
}

export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const body = await req.json();
  if (!body.client_org_id?.trim() || !body.title?.trim()) {
    return NextResponse.json({ error: 'client_org_id and title required' }, { status: 400 });
  }

  // RPC call for business logic + RLS
  const { data, error } = await supabase.rpc('create_assessment', {
    p_client_org_id: body.client_org_id,
    p_framework: body.framework || 'popia',
    p_title: body.title,
    p_org_name: body.org_name || null,
    p_auditor_name: body.auditor_name || null,
    p_audit_date: body.audit_date || null,
    p_audit_ref: body.audit_ref || null,
  });

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json({ id: data });
}