// W1-08 — notification send side. LIBRARY ONLY: the scheduler session (W1-09)
// owns triggering; this file is what it calls. No routes, no cron.
//
//   sendNotificationBatch(limit)  → claim_notification_batch → render+send
//                                   each row → mark sent/failed (lease token)
//   sendPendingDigests()          → digest_pending_users → sendDigestForUser
//   sendDigestForUser(user,since) → build_digest (leases + groups) → one
//                                   branded digest mail → mark sent/failed
//
// DB side: app/supabase/migrations/20261106000006_notifications.sql.
// Transport is the same Resend POST as lib/mail.ts (invites/billing) — no new
// deps. Branded envelope from the practice's FR-BRN columns (name, logo_url,
// accent_hex/primary_hex, email_sender_name, support_contact); the From
// display name is the partner's (FR-BRN-03) while the address stays MAIL_FROM
// — the partner's own sender domain needs Resend verification (Should, def.).
//
// Env: NEXT_PUBLIC_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (service JWT —
// the claim/mark/build_digest RPCs are service-role only), RESEND_API_KEY,
// MAIL_FROM, APP_URL. Missing service key or Resend key degrades to a logged
// no-op, same posture as mail.ts.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { BASE_URL } from './base-url';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const RESEND_KEY = process.env.RESEND_API_KEY;
const MAIL_FROM = process.env.MAIL_FROM ?? 'SecurePath <noreply@securepathconsulting.co.za>';

export interface NotificationRecipient {
  id: string;
  event_id: string;
  user_id: string;
  delivery: 'immediate' | 'digest';
  channel: 'email' | 'in_platform';
  status: 'pending' | 'claimed' | 'sent' | 'failed';
  claim_token: string | null;
}

interface NotificationEvent {
  id: string;
  kind: string;
  scope: Record<string, string>;
  payload: Record<string, unknown>;
  created_at: string;
}

interface Brand {
  name: string | null;
  logo_url: string | null;
  accent_hex: string | null;
  primary_hex: string | null;
  email_sender_name: string | null;
  support_contact: string | null;
}

export interface BatchResult {
  claimed: number;
  sent: number;
  failed: number;
}

function workerClient(): SupabaseClient | null {
  if (!SERVICE_KEY) {
    console.warn('SUPABASE_SERVICE_ROLE_KEY unset; notification send skipped');
    return null;
  }
  return createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Same transport as lib/mail.ts sendMail, with a per-mail From display name
// (FR-BRN-03 "emails sent under the partner's display name"). Returns ok.
async function sendBrandedMail(to: string, subject: string, html: string, fromName?: string) {
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

const esc = (s: unknown) =>
  String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

const title = (kind: string) =>
  kind.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());

// The practice behind an event scope — for the branded envelope. scope wins:
// practice_id → client_org_id → programme_id; users.service lookups fall back
// to the user's own practice via the memberships compat view.
async function brandForScope(
  sb: SupabaseClient,
  scope: Record<string, string>,
  userId?: string,
): Promise<Brand | null> {
  let practiceId: string | undefined = scope.practice_id;
  if (!practiceId && scope.client_org_id) {
    const { data } = await sb.from('client_orgs').select('practice_id')
      .eq('id', scope.client_org_id).maybeSingle();
    practiceId = data?.practice_id;
  }
  if (!practiceId && scope.programme_id) {
    const { data } = await sb.from('programmes').select('client_org_id')
      .eq('id', scope.programme_id).maybeSingle();
    if (data?.client_org_id) {
      const { data: co } = await sb.from('client_orgs').select('practice_id')
        .eq('id', data.client_org_id).maybeSingle();
      practiceId = co?.practice_id;
    }
  }
  if (!practiceId && userId) {
    const { data } = await sb.from('memberships').select('practice_id')
      .eq('user_id', userId).maybeSingle();
    practiceId = data?.practice_id;
  }
  if (!practiceId) return null;
  const { data } = await sb.from('practices')
    .select('name, logo_url, accent_hex, primary_hex, email_sender_name, support_contact')
    .eq('id', practiceId).maybeSingle();
  return data as Brand | null;
}

// Branded envelope — display name, accent bar, optional logo, support contact
// footer. Every client-facing output carries the partner's brand (spec §11).
function envelope(brand: Brand | null, inner: string) {
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

function renderNotification(kind: string, payload: Record<string, unknown>, brand: Brand | null) {
  const subject = (payload.subject as string) ?? `${brand?.name ?? 'SecurePath'}: ${title(kind)}`;
  const body =
    (payload.body as string) ??
    `<p>${esc((payload.title as string) ?? title(kind))}</p>` +
      (payload.summary ? `<p>${esc(payload.summary)}</p>` : '') +
      (payload.action_url
        ? `<p><a href="${esc(payload.action_url)}">Open in SecurePath</a></p>` : '');
  return { subject, html: envelope(brand, body) };
}

/**
 * Claim up to `limit` pending immediate deliveries, render and mail each,
 * then finalise the lease. Safe for concurrent callers: the DB lease
 * (claim_notification_batch) gives each worker a distinct token and only that
 * token can mark its rows.
 */
export async function sendNotificationBatch(limit = 50): Promise<BatchResult> {
  const sb = workerClient();
  if (!sb) return { claimed: 0, sent: 0, failed: 0 };
  const token = crypto.randomUUID();
  const { data: rows, error } = await sb.rpc('claim_notification_batch', {
    p_limit: limit,
    p_token: token,
  });
  if (error) { console.error('claim_notification_batch failed', error); return { claimed: 0, sent: 0, failed: 0 }; }
  const claimed = (rows ?? []) as NotificationRecipient[];
  if (!claimed.length) return { claimed: 0, sent: 0, failed: 0 };

  const eventIds = [...new Set(claimed.map(r => r.event_id))];
  const userIds = [...new Set(claimed.map(r => r.user_id))];
  const [{ data: events }, { data: users }] = await Promise.all([
    sb.from('notification_events').select('id, kind, scope, payload, created_at').in('id', eventIds),
    sb.from('users').select('id, email, full_name').in('id', userIds),
  ]);
  const evById = new Map((events ?? []).map((e: NotificationEvent) => [e.id, e]));
  const mailById = new Map((users ?? []).map((u: { id: string; email: string }) => [u.id, u.email]));
  const brandByEvent = new Map<string, Brand | null>();
  for (const e of events ?? []) {
    brandByEvent.set(e.id, await brandForScope(sb, e.scope ?? {}));
  }

  const sentIds: string[] = [];
  const failedIds: string[] = [];
  for (const r of claimed) {
    const ev = evById.get(r.event_id);
    const to = mailById.get(r.user_id);
    if (!ev || !to) { failedIds.push(r.id); continue; }
    const { subject, html } = renderNotification(ev.kind, ev.payload ?? {}, brandByEvent.get(ev.id) ?? null);
    const ok = await sendBrandedMail(to, subject, html,
      brandByEvent.get(ev.id)?.email_sender_name ?? brandByEvent.get(ev.id)?.name ?? undefined);
    (ok ? sentIds : failedIds).push(r.id);
  }
  if (sentIds.length)
    await sb.rpc('mark_notification_sent', { p_ids: sentIds, p_token: token });
  if (failedIds.length)
    await sb.rpc('mark_notification_failed', { p_ids: failedIds, p_token: token, p_error: 'resend send failed or recipient unresolvable' });
  return { claimed: claimed.length, sent: sentIds.length, failed: failedIds.length };
}

interface DigestPayload {
  user_id: string;
  email: string;
  claim_token: string;
  count: number;
  groups: { kind: string; count: number; items: { id: string; subject?: string; title?: string; body?: string }[] }[];
}

/**
 * Lease + mail one user's daily digest (spec §10: digests go out in the daily
 * 06:00 job). build_digest both groups the pending rows and leases them, so a
 * racing second worker sees none.
 */
export async function sendDigestForUser(
  userId: string,
  since?: string,
): Promise<'sent' | 'failed' | 'empty' | 'skipped'> {
  const sb = workerClient();
  if (!sb) return 'skipped';
  const { data: digest, error } = await sb.rpc('build_digest', {
    p_user_id: userId,
    ...(since ? { p_since: since } : {}),
  });
  if (error) { console.error('build_digest failed', error); return 'skipped'; }
  const d = digest as DigestPayload;
  if (!d?.count) return 'empty';

  const { data: u } = await sb.from('users').select('id, email').eq('id', userId).maybeSingle();
  const to = d.email ?? u?.email;
  const ids = d.groups.flatMap(g => g.items.map(i => i.id));
  if (!to) {
    await sb.rpc('mark_notification_failed', { p_ids: ids, p_token: d.claim_token, p_error: 'no recipient address' });
    return 'failed';
  }

  // brand from the first event's scope — a user's digest is overwhelmingly
  // one partner's world in practice
  const { data: firstRow } = await sb.from('notification_recipients')
    .select('event_id').eq('id', ids[0]).maybeSingle();
  let brand: Brand | null = null;
  if (firstRow?.event_id) {
    const { data: ev } = await sb.from('notification_events').select('scope')
      .eq('id', firstRow.event_id).maybeSingle();
    brand = await brandForScope(sb, (ev?.scope as Record<string, string>) ?? {}, userId);
  }
  const name = brand?.name ?? 'SecurePath';
  const sections = d.groups.map(g =>
    `<h3 style="margin:16px 0 6px">${esc(title(g.kind))} (${g.count})</h3><ul>` +
    g.items.map(i => `<li>${esc(i.title ?? i.subject ?? i.body ?? g.kind)}</li>`).join('') +
    '</ul>').join('');
  const ok = await sendBrandedMail(
    to,
    `${name}: your daily SecurePath digest (${d.count})`,
    envelope(brand, `<p>Your daily digest:</p>${sections}`),
    brand?.email_sender_name ?? brand?.name ?? undefined);
  await sb.rpc(ok ? 'mark_notification_sent' : 'mark_notification_failed',
    ok ? { p_ids: ids, p_token: d.claim_token }
       : { p_ids: ids, p_token: d.claim_token, p_error: 'resend send failed' });
  return ok ? 'sent' : 'failed';
}

/** Digest pass for everyone with digest mail waiting — the 06:00 job body. */
export async function sendPendingDigests(): Promise<{ users: number; sent: number; failed: number }> {
  const sb = workerClient();
  if (!sb) return { users: 0, sent: 0, failed: 0 };
  const { data: users, error } = await sb.rpc('digest_pending_users');
  if (error) { console.error('digest_pending_users failed', error); return { users: 0, sent: 0, failed: 0 }; }
  let sent = 0, failed = 0;
  for (const u of (users ?? []) as { digest_pending_users: string }[] | string[]) {
    const uid = typeof u === 'string' ? u : u.digest_pending_users;
    const r = await sendDigestForUser(uid);
    if (r === 'sent') sent++;
    else if (r === 'failed') failed++;
  }
  return { users: (users ?? []).length, sent, failed };
}
