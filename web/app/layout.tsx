import './globals.css';
import Link from 'next/link';
import { serverClient } from '@/lib/supabase';
import { Sidebar, BrandMark } from '@/components/ui/Sidebar';
import { ThemeToggle } from '@/components/ui/ThemeToggle';
import { Icon } from '@/components/ui/Icon';

export const metadata = { title: 'SecurePath', description: 'POPIA/GDPR compliance for MSPs' };
export const dynamic = 'force-dynamic';

// restore persisted theme before first paint
const THEME_SCRIPT = `try{var t=localStorage.getItem('sp-theme');if(t)document.documentElement.setAttribute('data-theme',t)}catch(e){}`;

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
  // sidebar shell only for a fully authenticated workspace session (aal2);
  // pre-2FA screens (/mfa, /mfa/enroll) render in the centred auth column
  let aal2 = false;
  if (user) {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    aal2 = aal?.currentLevel === 'aal2';
  }
  const shell = Boolean(user && practice && aal2);

  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body style={accent ? ({ ['--accent' as string]: accent } as React.CSSProperties) : undefined}>
        {shell ? (
          <div className="sp-shell">
            <Sidebar
              brandName={practice!.name}
              logoSrc={practice!.logo_url}
              items={[
                { heading: 'Workspace' },
                { label: 'Clients', href: '/dashboard', icon: 'building-2' },
                { label: 'Assessments', href: '/assessments', icon: 'clipboard-check' },
                { heading: 'Practice' },
                { label: 'Team', href: '/team', icon: 'users' },
                { label: 'Notifications', href: '/notifications', icon: 'bell', badge: unread },
                { label: 'Settings', href: '/settings/branding', icon: 'settings' },
              ]}
              footer={
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
                  <form action="/auth/signout" method="post" style={{ margin: 0 }}>
                    <button type="submit" className="sp-btn sp-btn--ghost sp-btn--sm" style={{ margin: 0 }}>
                      <Icon name="log-out" size={14} />
                      <span>Sign out</span>
                    </button>
                  </form>
                  <ThemeToggle />
                </div>
              }
            />
            <div className="sp-content">
              <main className="sp-main">{children}</main>
            </div>
          </div>
        ) : (
          <div className="sp-authwrap">
            <Link href="/" className="sp-auth-brand" style={{ color: 'var(--text)' }}>
              <span style={{ display: 'inline-flex', color: 'var(--text)' }}>
                <BrandMark size={28} />
              </span>
              <span className="sp-auth-name">SecurePath</span>
            </Link>
            <main className="sp-authmain">{children}</main>
          </div>
        )}
      </body>
    </html>
  );
}
