import { NextResponse } from 'next/server';
import { serverClient } from '@/lib/supabase';

// Frameworks a user can actually start an assessment in (registry-driven,
// only frameworks with a question bank).
export async function GET() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data, error } = await supabase.rpc('list_assessable_frameworks');
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json(data ?? []);
}
