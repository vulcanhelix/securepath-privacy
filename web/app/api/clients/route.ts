import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { BASE_URL } from '@/lib/base-url';
import { opsAlert, sendMail } from '@/lib/mail';

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
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });

  const { data: practice } = await supabase.from('practices').select('name').maybeSingle();

  // Ledger row is already written by the RPC (authoritative). These are alerts only.
  await opsAlert(
    `[billing] instance created: ${b.name}`,
    `Practice "${practice?.name ?? '?'}" created client instance "${b.name}" (${clientId}) — bill 1 instance.`
  );

  if (b.invite_admin && b.contact_email) {
    const { data: token, error: invErr } = await supabase.rpc('create_invite', {
      p_email: b.contact_email, p_role: 'client_admin', p_client_org_id: clientId,
    });
    if (!invErr && token) {
      const link = `${BASE_URL}/invite/${token}`;
      await sendMail(
        b.contact_email,
        `${practice?.name ?? 'Your MSP'} invited you to their compliance portal`,
        `<p>${practice?.name ?? 'Your MSP'} has set up a privacy compliance workspace for ${b.name}.</p>
         <p><a href="${link}">Accept your invite</a> (valid 7 days)</p>`
      );
    }
  }
  return NextResponse.json({ id: clientId });
}
