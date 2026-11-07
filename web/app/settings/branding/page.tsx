import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { getRoleContext } from '@/lib/role-context';
import { brandContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { BrandingForm, type BrandValues } from './BrandingForm';

export const dynamic = 'force-dynamic';

// W2-03 — white-label branding (spec §7.4 screen 12). Rewired from the legacy
// direct-table write to the update_practice_branding RPC (20261106000028):
// partner_admin only, audited, allowlisted. The partner's brand controls the
// workspace shell, the programme shell, branded email and the report print
// layout — the report "template" is the brand applied to the HTML layout
// (product decision, not a stored file).
//
// Server half: resolve the caller's partner + current brand; the form is a
// client component so the FR-BRN-06 preview updates live before saving.

const BRAND_COLS =
  'id, name, logo_url, accent_hex, primary_hex, sign_in_text, support_contact, email_sender_name';

export default async function BrandingPage() {
  const supabase = await serverClient();
  const role = await getRoleContext(supabase);
  if (!role) redirect('/login');

  const { partnerId, showAttribution } = await brandContext(supabase, role);
  if (!partnerId) {
    return (
      <>
        <PageHeader title="Branding" meta="White-label settings for your partner workspace." />
        <Card style={{ maxWidth: 'var(--form-max)' }}>
          <Alert tone="info">
            Branding is a partner-level setting — your account has no partner scope, so there is
            nothing to edit here.
          </Alert>
        </Card>
      </>
    );
  }

  const isAdmin = role.hasScopedRole('partner', ['partner_admin'], partnerId);
  if (!isAdmin) {
    // checked before the practices read on purpose: practices_read resolves
    // via the deprecated current_practice() shim, which returns NULL for
    // client-scope partner_consultants — they get the same notice either way.
    return (
      <>
        <PageHeader title="Branding" meta="White-label settings for your partner workspace." />
        <Card style={{ maxWidth: 'var(--form-max)' }}>
          <Alert tone="info">
            Only a partner admin can edit branding. Branding is set once for the whole partner
            workspace — ask a partner admin to change it.
          </Alert>
        </Card>
      </>
    );
  }
  const { data: p } = await supabase.from('practices').select(BRAND_COLS).eq('id', partnerId).maybeSingle();
  if (!p) {
    return (
      <>
        <PageHeader title="Branding" meta="White-label settings for your partner workspace." />
        <Card style={{ maxWidth: 'var(--form-max)' }}>
          <Alert tone="err">Could not load your partner record. Try again in a moment.</Alert>
        </Card>
      </>
    );
  }

  const initial: BrandValues = {
    name: (p.name as string) ?? '',
    logo_url: (p.logo_url as string) ?? '',
    accent_hex: (p.accent_hex as string) ?? '',
    primary_hex: (p.primary_hex as string) ?? '',
    sign_in_text: (p.sign_in_text as string) ?? '',
    support_contact: (p.support_contact as string) ?? '',
    email_sender_name: (p.email_sender_name as string) ?? '',
  };
  return <BrandingForm partnerId={partnerId} initial={initial} showAttribution={showAttribution} />;
}
