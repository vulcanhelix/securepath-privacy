import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

export async function GET(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const sessionId = searchParams.get('session_id');
  let framework = searchParams.get('framework') || 'popia';
  let orgScale: string | null = null;

  if (sessionId) {
    const { data: session, error: sessionErr } = await supabase
      .from('assessment_sessions')
      .select('framework, org_scale')
      .eq('id', sessionId)
      .maybeSingle();
    if (sessionErr) return NextResponse.json({ error: sessionErr.message }, { status: 400 });
    if (!session) return NextResponse.json({ error: 'assessment not found' }, { status: 404 });
    framework = session.framework || framework;
    orgScale = session.org_scale;
  }

  let query = supabase
    .from('assessment_questions')
    .select('*')
    .eq('framework', framework)
    .eq('active', true)
    .order('section_id', { ascending: true })
    .order('question_number', { ascending: true });

  if (framework === 'popia') {
    query = query
      .gte('section_id', 1)
      .lte('section_id', 6)
      .in('applies_to', ['all', orgScale || 'large']);
  }

  const { data, error } = await query;
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json(data);
}
