import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { BASE_URL } from '@/lib/base-url';

export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  await supabase.auth.signOut();
  return NextResponse.redirect(new URL('/login', BASE_URL), { status: 303 });
}
