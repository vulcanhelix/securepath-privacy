import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { getRoleContext } from '@/lib/role-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Alert } from '@/components/ui/Alert';
import { Wizard, type WizardData } from './Wizard';

export const dynamic = 'force-dynamic';

// W2-02 — client onboarding wizard (spec §7.3 screen 11, FR-ONB-01..04).
// Server side loads the registries the steps offer (jurisdiction packs, data
// regions, published template versions, partner team for designation picks)
// under the caller's JWT — every read is RLS-filtered. All WRITES happen in
// /api/clients/onboard through the system RPCs; nothing is validated twice.

export default async function NewClientPage() {
  const supabase = await serverClient();
  const ctx = await getRoleContext(supabase);
  if (!ctx) redirect('/login');
  if (!ctx.hasRole('partner', 'partner_admin', 'partner_consultant')) {
    return (
      <>
        <PageHeader title="Onboard a client" back="Programmes" backHref="/programmes" />
        <Alert tone="err">
          Client onboarding needs a partner admin or partner consultant role.
        </Alert>
      </>
    );
  }

  const [jurRes, regRes, verRes, tplRes, praRes, raRes] = await Promise.all([
    supabase.from('jurisdiction_packs').select('code, timezone, regulator_name, default_data_region').order('code'),
    supabase.from('data_regions').select('code, label, deployment_region').eq('active', true).order('code'),
    supabase.from('programme_template_versions')
      .select('id, template_id, number, release_notes, published_at')
      .eq('status', 'published'),
    supabase.from('programme_templates').select('id, framework, edition, jurisdiction, name'),
    supabase.from('practices').select('name, data_region_default, country').maybeSingle(),
    supabase.from('role_assignments').select('user_id, role, scope_type').eq('level', 'partner'),
  ]);

  // designation candidates: the partner's own users (minus the caller — the
  // RPC rejects self-appointment anyway). Eligibility for a specific
  // designation is the jurisdiction pack's rule; appoint_designation is the
  // only arbiter — the wizard offers people, it does not pre-judge.
  const ids = [...new Set((raRes.data ?? []).map((r) => r.user_id as string))]
    .filter((id) => id !== ctx.userId);
  const { data: users } = ids.length
    ? await supabase.from('users').select('id, email, full_name').in('id', ids)
    : { data: [] as { id: string; email: string; full_name: string | null }[] };

  const data: WizardData = {
    callerId: ctx.userId,
    practiceName: (praRes.data?.name as string) ?? null,
    homeRegion: (praRes.data?.data_region_default as string) ?? null,
    practiceCountry: (praRes.data?.country as string) ?? null,
    jurisdictions: (jurRes.data ?? []) as WizardData['jurisdictions'],
    regions: (regRes.data ?? []) as WizardData['regions'],
    regionsAvailable: !regRes.error,
    templates: ((tplRes.data ?? []) as {
      id: string; framework: string; edition: string | null;
      jurisdiction: string | null; name: string;
    }[]).map((t) => ({
      ...t,
      versions: ((verRes.data ?? []) as {
        id: string; template_id: string; number: number;
        release_notes: string | null; published_at: string;
      }[]).filter((v) => v.template_id === t.id),
    })).filter((t) => t.versions.length > 0),
    people: ((users ?? []) as { id: string; email: string; full_name: string | null }[])
      .map((u) => ({ id: u.id, name: u.full_name?.trim() || u.email.split('@')[0], email: u.email }))
      .sort((a, b) => a.name.localeCompare(b.name)),
  };

  return (
    <>
      <PageHeader
        title="Onboard a client"
        back="Programmes"
        backHref="/programmes"
        meta={<>Creating a client instance is a <strong>billable event</strong> on your account.</>}
      />
      {regRes.error ? (
        <Alert tone="err">
          The data-region registry is unavailable ({regRes.error.message}) — client creation
          will fail until migration 000028 is applied.
        </Alert>
      ) : null}
      <Wizard data={data} />
    </>
  );
}
