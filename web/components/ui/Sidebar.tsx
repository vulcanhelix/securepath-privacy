import * as React from 'react';
import Link from 'next/link';
import { Icon } from './Icon';

export type SidebarItem =
  | { heading: string }
  | { label: string; href: string; icon?: string; active?: boolean; badge?: number | null };

export function BrandMark({ size = 24 }: { size?: number }) {
  return (
    <span className="sp-side-mark" aria-hidden="true">
      <svg viewBox="0 0 256 256" width={size} height={size} style={{ color: 'var(--side-accent)' }}>
        <path
          d="M 128.005 191.173 C 128.448 156.208 156.93 128 192 128 L 192 64 L 128 64 C 128 99.346 99.346 128 64 128 L 64 192 L 128 192 Z M 192 256 L 64 256 C 28.654 256 0 227.346 0 192 L 0 64 L 64 64 L 64 0 L 192 0 C 227.346 0 256 28.654 256 64 L 256 192 L 192 192 Z"
          fill="currentColor"
        />
      </svg>
    </span>
  );
}

export function Sidebar({
  brandName = 'SecurePath',
  logoSrc,
  items = [],
  footer,
}: {
  brandName?: string;
  logoSrc?: string | null;
  items?: SidebarItem[];
  footer?: React.ReactNode;
}) {
  return (
    <aside className="sp-side">
      <div className="sp-side-brand">
        {logoSrc ? <img src={logoSrc} alt="" style={{ height: 26 }} /> : <BrandMark />}
        <span className="sp-side-name">{brandName}</span>
      </div>
      <nav className="sp-side-nav">
        {items.map((it, i) =>
          'heading' in it ? (
            <div key={i} className="sp-side-heading">
              {it.heading}
            </div>
          ) : (
            <Link key={i} href={it.href} className={'sp-side-item' + (it.active ? ' is-active' : '')}>
              {it.icon ? <Icon name={it.icon} size={16} /> : null}
              <span style={{ flex: 1 }}>{it.label}</span>
              {it.badge ? <span className="sp-side-count">{it.badge}</span> : null}
            </Link>
          )
        )}
      </nav>
      {footer ? <div className="sp-side-foot">{footer}</div> : null}
    </aside>
  );
}
