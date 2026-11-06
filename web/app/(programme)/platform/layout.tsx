import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { platformGate } from '@/lib/platform';
import { PlatformTabs } from './PlatformTabs';

export const dynamic = 'force-dynamic';

// W2-14 — SecurePath platform admin area (spec §7.5 FR-PLT-01..06).
// Gate: platform_admin or support via the is_platform_role predicate. Anyone
// else gets a 404 — the RPCs refuse them anyway; this only hides the screens.
// support sees the read-only views; every write affordance is admin-gated.

export default async function PlatformLayout({ children }: { children: React.ReactNode }) {
  const supabase = await serverClient();
  const gate = await platformGate(supabase);
  if (!gate.any) notFound();

  const tabs = [
    { href: '/platform', label: 'Overview', icon: 'gauge' },
    { href: '/platform/partners', label: 'Partners', icon: 'building-2' },
    ...(gate.isAdmin ? [{ href: '/platform/usage', label: 'Usage', icon: 'bar-chart-3' }] : []),
    { href: '/platform/support', label: 'Support access', icon: 'key-round' },
  ];

  return (
    <>
      <PlatformTabs tabs={tabs} />
      {children}
    </>
  );
}
