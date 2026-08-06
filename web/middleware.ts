import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { BASE_URL } from '@/lib/base-url';

export async function middleware(req: NextRequest) {
  let res = NextResponse.next({ request: req });
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => req.cookies.getAll(),
        setAll: (all) => {
          all.forEach(({ name, value }) => req.cookies.set(name, value));
          res = NextResponse.next({ request: req });
          all.forEach(({ name, value, options }) => res.cookies.set(name, value, options));
        },
      },
    }
  );
  const { data: { user } } = await supabase.auth.getUser();

  const path = req.nextUrl.pathname;
  const publicPath = ['/login', '/signup', '/auth', '/invite', '/forgot', '/mail-templates'].some(p => path.startsWith(p));
  if (!user && !publicPath && path !== '/') {
    return NextResponse.redirect(new URL('/login', BASE_URL));
  }

  // Compulsory TOTP 2FA: aal1 session with a verified factor -> verify; without -> enroll.
  // ponytail: UI-level enforcement only; add aal2 checks in RLS if API-direct access must be locked too.
  const mfaExempt = publicPath || ['/mfa', '/reset'].some(p => path.startsWith(p)) || path === '/';
  if (user && !mfaExempt) {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal && aal.currentLevel !== 'aal2') {
      const dest = aal.nextLevel === 'aal2' ? '/mfa' : '/mfa/enroll';
      return NextResponse.redirect(new URL(dest, BASE_URL));
    }
  }
  return res;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|ico)$).*)'],
};
