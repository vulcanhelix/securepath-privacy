import './globals.css';
import Link from 'next/link';
import { serverClient } from '@/lib/supabase';
import { brandContext } from '@/lib/programme-context';
import { publicBrandForRequest } from '@/lib/public-brand';
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
  // sidebar shell only for a fully authenticated workspace session (aal2);
  // pre-2FA screens (/mfa, /mfa/enroll) render in the centred auth column
  let aal2 = false;
  if (user) {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    aal2 = aal?.currentLevel === 'aal2';
  }
  // W2-00: new-model users (role_assignments only, no legacy-mappable row) get
  // no practice via current_practice() — they still deserve the sidebar shell.
  // role_assignments own-row read is RLS-safe; zero rows ⇒ pre-onboarding user,
  // who keeps the centred auth column as before.
  let programmeAccess = false;
  // W2-15: brand fallback for users practices_read can't see — paints the
  // chrome only; `practice` itself still decides the workspace nav variant,
  // so a client/programme-scope user never gets partner nav items.
  let brandFallback: { name: string; logoUrl: string | null; accentHex: string | null } | null = null;
  if (user && !practice) {
    const { count } = await supabase
      .from('role_assignments')
      .select('*', { count: 'exact', head: true });
    programmeAccess = (count ?? 0) > 0;
    if (programmeAccess) {
      const { brand } = await brandContext(supabase);
      brandFallback = brand;
    }
  }
  const shell = Boolean(user && aal2 && (practice || programmeAccess));
  const brandName = practice?.name ?? brandFallback?.name ?? 'SecurePath';
  const logoSrc = practice?.logo_url ?? brandFallback?.logoUrl ?? null;
  const accentRaw = practice?.accent_hex ?? brandFallback?.accentHex ?? null;
  const accent = accentRaw?.match(/^#[0-9a-fA-F]{6}$/) ? accentRaw : null;

  // W2-15 FR-BRN-01/02: the pre-auth surface (sign-in, signup, forgot,
  // invite, MFA enrol) paints the partner's brand resolved from the host
  // subdomain — apex/unknown hosts get the platform's own SecurePath chrome.
  const pub = shell ? null : await publicBrandForRequest();
  const pubAccent =
    pub && (pub.accentHex ?? pub.primaryHex)?.match(/^#[0-9a-fA-F]{6}$/)
      ? ((pub.accentHex ?? pub.primaryHex) as string)
      : null;
  const navItems = practice
    ? [
        { heading: 'Workspace' },
        { label: 'Clients', href: '/dashboard', icon: 'building-2' },
        { label: 'Assessments', href: '/assessments', icon: 'clipboard-check' },
        { label: 'Programmes', href: '/programmes', icon: 'layout-grid' },
        { heading: 'Practice' },
        { label: 'Team', href: '/team', icon: 'users' },
        { label: 'Notifications', href: '/notifications', icon: 'bell', badge: unread },
        { label: 'Settings', href: '/settings/branding', icon: 'settings' },
      ]
    : [
        { heading: 'Workspace' },
        { label: 'Programmes', href: '/programmes', icon: 'layout-grid' },
        { heading: 'Account' },
        { label: 'Notifications', href: '/notifications', icon: 'bell', badge: unread },
      ];

  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body style={accent ? ({ ['--accent' as string]: accent } as React.CSSProperties) : undefined}>
        {shell ? (
          <div className="sp-shell">
            <Sidebar
              brandName={brandName}
              logoSrc={logoSrc}
              items={navItems}
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
          <div
            className="sp-authwrap"
            style={pubAccent ? ({ ['--accent' as string]: pubAccent } as React.CSSProperties) : undefined}
          >
            <Link href="/" className="sp-auth-brand" style={{ color: 'var(--text)' }}>
              {pub?.logoUrl ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={pub.logoUrl} alt="" style={{ maxHeight: 30, maxWidth: 140, objectFit: 'contain' }} />
              ) : pub ? (
                <span
                  aria-hidden="true"
                  style={{
                    display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                    width: 28, height: 28, borderRadius: 7,
                    background: pubAccent ?? 'var(--accent)', color: '#fff',
                    fontSize: 14, fontWeight: 700, flex: 'none',
                  }}
                >
                  {(pub.name.trim()[0] ?? 'S').toUpperCase()}
                </span>
              ) : (
                <span style={{ display: 'inline-flex', color: 'var(--text)' }}>
                  <BrandMark size={28} />
                </span>
              )}
              <span className="sp-auth-name" data-testid="auth-brand-name">
                {pub?.name ?? 'SecurePath'}
              </span>
            </Link>
            {pub?.signInText ? (
              <p className="muted" data-testid="auth-signin-text" style={{ margin: '-20px 0 24px', textAlign: 'center' }}>
                {pub.signInText}
              </p>
            ) : null}
            <main className="sp-authmain">{children}</main>
            <div
              className="muted"
              style={{ marginTop: 'auto', paddingTop: 24, fontSize: 'var(--fs-xs)', textAlign: 'center' }}
            >
              {pub?.supportContact ? (
                <div data-testid="auth-support-contact">Support: {pub.supportContact}</div>
              ) : null}
              {pub?.showAttribution ? (
                <div data-testid="auth-attribution" style={{ marginTop: 4 }}>
                  Powered by <strong>SecurePath</strong>
                  {pub.name ? ` · delivered by ${pub.name}` : ''}
                </div>
              ) : null}
            </div>
          </div>
        )}
      </body>
    </html>
  );
}
