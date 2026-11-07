import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { BASE_URL } from '@/lib/base-url';
import { envelope, esc, sendBrandedMail } from '@/lib/branded-mail';

// W2-14 — create a partner (FR-PLT-01). The write is ONLY the
// platform_create_partner RPC under the caller's JWT (its body checks
// is_platform_role('platform_admin')). When a first partner-admin email is
// given the RPC mints a practice_owner invite on the existing invites table;
// this route mails the link the same way /api/invites does (server-side, so
// the mail credentials never reach the browser).

export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const b = (await req.json().catch(() => null)) as Record<string, string> | null;
  if (!b) return NextResponse.json({ error: 'invalid JSON body' }, { status: 400 });
  const opt = (v: unknown) => (typeof v === 'string' && v.trim() !== '' ? v.trim() : null);

  const { data, error } = await supabase.rpc('platform_create_partner', {
    p_name: b.name ?? null,
    p_type: b.type ?? null,
    p_country: b.country ?? null,
    p_subdomain: opt(b.subdomain),
    p_primary_contact: opt(b.primary_contact),
    p_data_region_default: opt(b.data_region_default),
    p_admin_email: opt(b.admin_email),
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });

  const r = data as { partner_id: string; invite_token: string | null };
  let mail_error: string | undefined;
  if (r.invite_token && opt(b.admin_email)) {
    const name = String(b.name).trim();
    const link = `${BASE_URL}/invite/${r.invite_token}`;
    try {
      // platform-sent mail → the platform's own SecurePath envelope (brand null)
      await sendBrandedMail(
        opt(b.admin_email)!,
        `You've been invited to administer ${name}`,
        envelope(null,
          `<p>SecurePath has set up <strong>${esc(name)}</strong> and invited you as its partner admin.</p>
           <p><a href="${esc(link)}">Accept your invite</a> (valid 7 days)</p>`),
        'SecurePath',
      );
    } catch (e) {
      mail_error = e instanceof Error ? e.message : String(e);
    }
  }
  return NextResponse.json({ partner_id: r.partner_id, invited: !!r.invite_token && !mail_error, mail_error });
}
