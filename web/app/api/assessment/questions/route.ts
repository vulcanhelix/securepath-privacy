import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';

export async function GET(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { searchParams } = new URL(req.url);
  const framework = searchParams.get('framework') || 'popia';

  const { data, error } = await supabase
    .from('assessment_questions')
    .select('*')
    .eq('framework', framework)
    .eq('active', true)
    .order('section_id', { ascending: true })
    .order('question_number', { ascending: true });

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json(data);
}