import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { opsAlert } from '@/lib/mail';
import { getRoleContext } from '@/lib/role-context';
import { callerBrand, envelope, esc, partnerBaseUrl, sendBrandedMail, senderName } from '@/lib/branded-mail';

export async function GET() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data, error } = await supabase
    .from('client_orgs')
    .select('id, name, industry, contact_name, contact_email, org_scale, created_at')
    .order('created_at', { ascending: false });

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json(data);
}

export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const b = await req.json();
  if (!b.name?.trim()) return NextResponse.json({ error: 'name required' }, { status: 400 });

  // RPC runs under the caller's JWT: RLS + owner check enforced in Postgres.
  const { data: clientId, error } = await supabase.rpc('create_client_org', {
    p_name: b.name.trim(),
    p_registration_no: b.registration_no || null,
    p_industry: b.industry || null,
    p_contact_name: b.contact_name || null,
    p_contact_email: b.contact_email || null,
    p_org_scale: b.org_scale === 'sme' ? 'sme' : 'large',
    // W4-05 NFR-11: explicit region wins; NULL → partner home region default
    p_data_region: b.data_region || null,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });

  // The partner behind this client — partner_brand() resolves for new-model
  // partner admins too; the legacy practices read is the fallback only.
  const role = await getRoleContext(supabase);
  let brand = await callerBrand(supabase, role?.partnerIds[0]);
  if (!brand) {
    const { data: practice } = await supabase.from('practices')
      .select('name, logo_url, accent_hex, primary_hex, email_sender_name, support_contact, subdomain')
      .maybeSingle();
    brand = practice;
  }

  // Ledger row is already written by the RPC (authoritative). These are alerts only.
  await opsAlert(
    `[billing] instance created: ${b.name}`,
    `Practice "${brand?.name ?? '?'}" created client instance "${b.name}" (${clientId}) — bill 1 instance.`
  );

  if (b.invite_admin && b.contact_email) {
    const { data: token, error: invErr } = await supabase.rpc('create_invite', {
      p_email: b.contact_email, p_role: 'client_admin', p_client_org_id: clientId,
    });
    if (!invErr && token) {
      // FR-ONB-04 + FR-BRN-02/03: the invite goes out under the partner's
      // brand and lands on the partner's own sign-in host when one is set
      const link = `${partnerBaseUrl(brand)}/invite/${token}`;
      await sendBrandedMail(
        b.contact_email,
        `${brand?.name ?? 'Your MSP'} invited you to their compliance portal`,
        envelope(brand,
          `<p>${esc(brand?.name ?? 'Your MSP')} has set up a privacy compliance workspace for ${esc(b.name)}.</p>
           <p><a href="${esc(link)}">Accept your invite</a> (valid 7 days)</p>`),
        senderName(brand),
      );
    }
  }
  return NextResponse.json({ id: clientId });
}
