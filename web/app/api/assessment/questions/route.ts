import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

export async function GET(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const sessionId = searchParams.get('session_id');
  const framework = searchParams.get('framework') || 'popia';

  if (sessionId) {
    const { data: session, error: sessionErr } = await supabase
      .from('assessment_sessions')
      .select('framework, org_scale, content_pack_id')
      .eq('id', sessionId)
      .maybeSingle();
    if (sessionErr) return NextResponse.json({ error: sessionErr.message }, { status: 400 });
    if (!session) return NextResponse.json({ error: 'assessment not found' }, { status: 404 });
    if (!session.content_pack_id) {
      return NextResponse.json({ error: 'assessment has no content pack' }, { status: 400 });
    }

    const { data, error } = await supabase
      .from('assessment_questions')
      .select('*')
      .eq('content_pack_id', session.content_pack_id)
      .neq('section_id', 11)
      .in('applies_to', ['all', session.org_scale || 'large'])
      .order('section_id', { ascending: true })
      .order('question_number', { ascending: true });
    if (error) return NextResponse.json({ error: error.message }, { status: 400 });
    return NextResponse.json(data);
  }

  const { data, error } = await supabase
    .from('assessment_questions')
    .select('*')
    .eq('framework', framework)
    .eq('active', true)
    .neq('section_id', 11)
    .order('section_id', { ascending: true })
    .order('question_number', { ascending: true });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json(data);
}
