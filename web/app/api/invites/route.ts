import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { getRoleContext } from '@/lib/role-context';
import { callerBrand, envelope, esc, partnerBaseUrl, sendBrandedMail, senderName } from '@/lib/branded-mail';

export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const b = await req.json();
  if (!b.email || !b.role) return NextResponse.json({ error: 'email and role required' }, { status: 400 });

  const { data: token, error } = await supabase.rpc('create_invite', {
    p_email: b.email, p_role: b.role, p_client_org_id: b.client_org_id ?? null,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });

  // FR-ONB-04 + FR-BRN-03: the invite goes out under the partner's own brand —
  // same envelope the notification fan-out uses (W2-15). partner_brand()
  // resolves for new-model partner admins the legacy practices read cannot.
  const role = await getRoleContext(supabase);
  let brand = await callerBrand(supabase, role?.partnerIds[0]);
  if (!brand) {
    const { data: practice } = await supabase.from('practices')
      .select('name, logo_url, accent_hex, primary_hex, email_sender_name, support_contact, subdomain')
      .maybeSingle();
    brand = practice;
  }
  const name = brand?.name ?? 'a compliance workspace';
  const link = `${partnerBaseUrl(brand)}/invite/${token}`;
  await sendBrandedMail(
    b.email,
    `You've been invited to ${name}`,
    envelope(brand,
      `<p>You've been invited to join <strong>${esc(name)}</strong> as ${esc(b.role.replace('_', ' '))}.</p>
       <p><a href="${esc(link)}">Accept your invite</a> (valid 7 days)</p>`),
    senderName(brand),
  );
  return NextResponse.json({ ok: true });
}
