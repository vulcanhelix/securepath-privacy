'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Icon } from '@/components/ui/Icon';

// W2-14 — sub-navigation inside /platform (same sp-tabs strip as the
// programme module tabs).

export function PlatformTabs({ tabs }: { tabs: { href: string; label: string; icon: string }[] }) {
  const pathname = usePathname();
  return (
    <nav className="sp-tabs" aria-label="Platform admin" style={{ marginBottom: 20 }}>
      {tabs.map((t) => {
        const active = t.href === '/platform' ? pathname === t.href : pathname.startsWith(t.href);
        return (
          <Link key={t.href} href={t.href} className={'sp-tab' + (active ? ' is-active' : '')}>
            <Icon name={t.icon} size={14} />
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}
