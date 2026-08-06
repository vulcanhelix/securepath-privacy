import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { BASE_URL } from '@/lib/base-url';
import { sendMail } from '@/lib/mail';

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

  const { data: practice } = await supabase.from('practices').select('name').maybeSingle();
  const link = `${BASE_URL}/invite/${token}`;
  await sendMail(
    b.email,
    `You've been invited to ${practice?.name ?? 'a compliance workspace'}`,
    `<p>You've been invited to join <strong>${practice?.name ?? 'a practice'}</strong> as ${b.role.replace('_', ' ')}.</p>
     <p><a href="${link}">Accept your invite</a> (valid 7 days)</p>`
  );
  return NextResponse.json({ ok: true });
}
