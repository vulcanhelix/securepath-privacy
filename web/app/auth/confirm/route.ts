import { type EmailOtpType } from '@supabase/supabase-js';
import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { BASE_URL } from '@/lib/base-url';

export async function GET(req: NextRequest) {
  const url = new URL(req.url);
  const token_hash = url.searchParams.get('token_hash');
  const type = url.searchParams.get('type') as EmailOtpType | null;
  const next = url.searchParams.get('next');
  if (token_hash && type) {
    const supabase = await serverClient();
    const { error } = await supabase.auth.verifyOtp({ type, token_hash });
    if (!error) {
      const dest = next ?? (type === 'recovery' ? '/reset' : '/dashboard');
      return NextResponse.redirect(new URL(dest, BASE_URL));
    }
  }
  return NextResponse.redirect(new URL('/login?error=confirm_failed', BASE_URL));
}
