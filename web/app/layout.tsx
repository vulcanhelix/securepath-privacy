import './globals.css';
import Link from 'next/link';
import { serverClient } from '@/lib/supabase';

export const metadata = { title: 'SecurePath', description: 'POPIA/GDPR compliance for MSPs' };
export const dynamic = 'force-dynamic';

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();

  let practice: { name: string; logo_url: string | null; accent_hex: string | null } | null = null;
  let unread = 0;
  if (user) {
    const { data } = await supabase.from('practices').select('name, logo_url, accent_hex').maybeSingle();
    practice = data;
    const { count } = await supabase.from('notifications')
      .select('*', { count: 'exact', head: true }).eq('read', false);
    unread = count ?? 0;
  }
  const accent = practice?.accent_hex?.match(/^#[0-9a-fA-F]{6}$/) ? practice.accent_hex : null;

  return (
    <html lang="en">
      <body style={accent ? ({ ['--accent' as string]: accent } as React.CSSProperties) : undefined}>
        <nav>
          <Link href="/dashboard" className="brand">
            {practice?.logo_url ? <img src={practice.logo_url} alt="" /> : null}
            {practice?.name ?? 'SecurePath'}
          </Link>
          {user && practice && (<>
            <Link href="/dashboard">Clients</Link>
            <Link href="/assessments">Assessments</Link>
            <Link href="/team">Team</Link>
            <Link href="/settings/branding">Branding</Link>
            <Link href="/notifications">Notifications{unread ? ` (${unread})` : ''}</Link>
          </>)}
          <span className="spacer" />
          {user
            ? <form action="/auth/signout" method="post"><button style={{ margin: 0, background: 'var(--muted)' }}>Sign out</button></form>
            : <Link href="/login">Sign in</Link>}
        </nav>
        <main>{children}</main>
      </body>
    </html>
  );
}
