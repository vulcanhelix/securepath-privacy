import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { BASE_URL } from '@/lib/base-url';
import { brandAwareOrigin } from '@/lib/brand-host';

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
  // W2-15 FR-BRN-02: a request on <partner>.<domain> keeps its origin through
  // redirects, so an unauthenticated deep link lands on the partner-branded
  // sign-in — every other host still takes the canonical BASE_URL (the
  // Caddy localhost:3200 redirect rule).
  const origin = brandAwareOrigin(req.nextUrl.host, req.nextUrl.origin);
  const publicPath = ['/login', '/signup', '/auth', '/invite', '/forgot', '/mail-templates'].some(p => path.startsWith(p));
  if (!user && !publicPath && path !== '/') {
    return NextResponse.redirect(new URL('/login', origin));
  }

  // Compulsory TOTP 2FA: aal1 session with a verified factor -> verify; without -> enroll.
  // ponytail: UI-level enforcement only; add aal2 checks in RLS if API-direct access must be locked too.
  const mfaExempt = publicPath || ['/mfa', '/reset'].some(p => path.startsWith(p)) || path === '/';
  if (user && !mfaExempt) {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal && aal.currentLevel !== 'aal2') {
      const dest = aal.nextLevel === 'aal2' ? '/mfa' : '/mfa/enroll';
      return NextResponse.redirect(new URL(dest, origin));
    }
  }
  return res;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|ico)$).*)'],
};
