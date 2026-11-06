'use client';
import * as React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Icon } from '@/components/ui/Icon';
import type { NavSlot } from '@/lib/nav';

// W2-00 — role-filtered nav strip. Server layouts pass the slots they
// resolved via visibleSlots(); this only renders them. Unimplemented slots
// (W2 mount points) render disabled — the map is visible, nothing 404s.

export function ProgrammeNav({ slots, base = '' }: { slots: NavSlot[]; base?: string }) {
  const pathname = usePathname();
  if (!slots.length) return null;
  return (
    <nav className="sp-tabs" aria-label="Programme modules">
      {slots.map((s) => {
        const href = s.scope === 'programme' ? `${base}${s.href}` : s.href;
        const active =
          s.scope === 'programme' && s.href === ''
            ? pathname === base
            : pathname === href || pathname.startsWith(href + '/');
        if (!s.implemented) {
          return (
            <span key={s.key} className="sp-tab is-disabled" title={`${s.w2} — not built yet`} aria-disabled="true">
              <Icon name={s.icon} size={14} />
              {s.label}
            </span>
          );
        }
        return (
          <Link key={s.key} href={href} className={'sp-tab' + (active ? ' is-active' : '')}>
            <Icon name={s.icon} size={14} />
            {s.label}
          </Link>
        );
      })}
    </nav>
  );
}
