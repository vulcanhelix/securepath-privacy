// W2-15 — the partner-branded mail envelope + sender, shared by every
// outbound mail path: notification fan-out (lib/notify.ts, W1-08), team /
// client invites (app/api/invites, app/api/clients) and platform partner
// onboarding (app/api/platform/partners). FR-BRN-03: the From display name is
// the partner's email_sender_name / display name while the address stays
// MAIL_FROM — the partner's own sender domain needs Resend verification
// (Should, deferred per the plan). FR-BRN-01 support contact rides the footer.
// Spec §11: every client-facing output carries the partner's brand.

import type { SupabaseClient } from '@supabase/supabase-js';
import { BASE_URL } from './base-url';

const RESEND_KEY = process.env.RESEND_API_KEY;
const MAIL_FROM = process.env.MAIL_FROM ?? 'SecurePath <noreply@securepathconsulting.co.za>';

export interface Brand {
  name: string | null;
  logo_url: string | null;
  accent_hex: string | null;
  primary_hex: string | null;
  email_sender_name: string | null;
  support_contact: string | null;
  subdomain: string | null;
}

export const esc = (s: unknown) =>
  String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

// Same transport as lib/mail.ts sendMail, with a per-mail From display name
// (FR-BRN-03 "emails sent under the partner's display name"). Returns ok.
export async function sendBrandedMail(
  to: string,
  subject: string,
  html: string,
  fromName?: string,
): Promise<boolean> {
  if (!RESEND_KEY) { console.warn('RESEND_API_KEY unset; mail skipped:', subject); return false; }
  const addr = MAIL_FROM.match(/<(.+?)>/)?.[1] ?? MAIL_FROM;   // keep the configured address
  const from = fromName ? `"${fromName.replace(/"/g, '')}" <${addr}>` : MAIL_FROM;
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to: [to], subject, html }),
  });
  if (!r.ok) { console.error('resend failed', r.status, await r.text()); return false; }
  return true;
}

/** The From display name a brand implies (FR-BRN-03), undefined = MAIL_FROM. */
export const senderName = (brand: Brand | null) =>
  brand?.email_sender_name ?? brand?.name ?? undefined;

/**
 * The origin an emailed link should land on (FR-BRN-02): the partner's
 * subdomain on the platform domain when one is set, else BASE_URL — so an
 * invitee's first click arrives on the partner-branded sign-in, not the apex.
 */
export function partnerBaseUrl(brand: Brand | null): string {
  if (!brand?.subdomain) return BASE_URL;
  try {
    const u = new URL(BASE_URL);
    const loopback = u.hostname === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(u.hostname);
    u.hostname = `${brand.subdomain}.${loopback ? 'localhost' : u.hostname}`;
    return u.origin;
  } catch {
    return BASE_URL;
  }
}

// Branded envelope — display name, accent bar, optional logo, support contact
// footer. Every client-facing output carries the partner's brand (spec §11).
export function envelope(brand: Brand | null, inner: string) {
  const name = brand?.name ?? 'SecurePath';
  const accent = brand?.accent_hex ?? brand?.primary_hex ?? '#1f4f8f';
  const logo = brand?.logo_url
    ? `<img src="${esc(brand.logo_url)}" alt="" height="28" style="vertical-align:middle;margin-right:8px"/>`
    : '';
  const support = brand?.support_contact
    ? ` &middot; Support: ${esc(brand.support_contact)}` : '';
  return `<div style="font-family:system-ui,Arial,sans-serif;max-width:560px;margin:0 auto;border:1px solid #e2e2e2;border-radius:8px;overflow:hidden">
  <div style="background:${esc(accent)};color:#fff;padding:12px 18px">${logo}<strong>${esc(name)}</strong></div>
  <div style="padding:18px">${inner}</div>
  <div style="padding:12px 18px;font-size:12px;color:#666;border-top:1px solid #eee">
    Sent by ${esc(name)} via SecurePath${support} &middot; <a href="${BASE_URL}">${BASE_URL}</a>
  </div>
</div>`;
}

/**
 * The calling user's partner brand for outbound mail, resolved the same way
 * the shell does: partner_brand() (20261106000034) under the caller's JWT —
 * works for new-model roles that practices_read's current_practice() shim
 * cannot see. Returns null for platform callers with no partner scope (their
 * mail goes out in the SecurePath envelope).
 */
export async function callerBrand(
  sb: SupabaseClient,
  partnerId: string | null | undefined,
): Promise<Brand | null> {
  if (!partnerId) return null;
  const { data } = await sb.rpc('partner_brand', { p_partner: partnerId });
  return (data as Brand | null) ?? null;
}
