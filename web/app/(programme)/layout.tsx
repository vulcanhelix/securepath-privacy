import './programme.css';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { getRoleContext } from '@/lib/role-context';
import { brandContext } from '@/lib/programme-context';
import { visibleSlots } from '@/lib/nav';
import { ProgrammeShellProvider } from '@/components/programme/ShellContext';
import { ProgrammeNav } from '@/components/programme/ProgrammeNav';
import { ReportBreachButton } from '@/components/programme/ReportBreachButton';
import { Attribution } from '@/components/programme/Attribution';

export const dynamic = 'force-dynamic';

// W2-00 — route-group shell for the programme world (everything under
// /programmes). Renders inside the root .sp-main: a role-filtered
// partner/platform nav strip, the FR-OPS-04 breach mount, the shell context
// provider, and the FR-BRN-05 attribution line. Per-programme chrome (module
// tabs) is added by programmes/[id]/layout.tsx.

export default async function ProgrammeGroupLayout({ children }: { children: React.ReactNode }) {
  const supabase = await serverClient();
  const role = await getRoleContext(supabase);
  if (!role) redirect('/login');

  const [{ brand, showAttribution }, { data: clients }] = await Promise.all([
    brandContext(supabase, role),
    // visible client orgs (T1 RLS) feed the breach mount's client picker
    supabase.from('client_orgs').select('id, name').order('name'),
  ]);

  const navSlots = [...visibleSlots(role, 'partner'), ...visibleSlots(role, 'platform')];

  return (
    <ProgrammeShellProvider
      value={{
        userId: role.userId,
        levels: role.levels,
        brandName: brand?.name ?? null,
        logoUrl: brand?.logoUrl ?? null,
        accentHex: brand?.accentHex ?? brand?.primaryHex ?? null,
        programmeId: null,
        programmeName: null,
        clientOrgId: null,
        clientName: null,
        showAttribution,
      }}
    >
      <div className="sp-ctxbar">
        <ProgrammeNav slots={navSlots} />
        <ReportBreachButton clients={(clients ?? []) as { id: string; name: string }[]} />
      </div>
      {children}
      {showAttribution ? <Attribution partnerName={brand?.name} /> : null}
    </ProgrammeShellProvider>
  );
}
