// ---------------------------------------------------------------------------
// W2-17 — partner licence usage shapes + the W1-07 warning-threshold display
// rules (spec §7.5 FR-LIC-01, §10; migration 20261106000009).
// Reads: usage_report (partner_admin on own partner), partner_licence_usage
// (any partner-scope role) and the licences table (partner_admin only) — all
// under the caller's JWT.
// ---------------------------------------------------------------------------

/** Row of public.usage_report(p_partner) for the caller's own partner. */
export interface OwnUsageRow {
  partner_id: string;
  partner_name: string;
  partner_type: string;
  licence_id: string | null;
  plan: string | null;
  licence_status: string | null;
  clients_used: number;
  client_limit: number | null;
  programmes_used: number;
  programme_limit: number | null;
  active_users: number;
  programmes_by_framework: Record<string, number>;
}

/** Row of public.partner_licence_usage(p_partner) — the §9.8 counter. */
export interface LicenceUsageRow {
  programmes_used: number;
  clients_used: number;
  client_limit: number | null;
  programme_limit: number | null;
  over_client_limit: boolean;
  over_programme_limit: boolean;
}

/** licences table row (partner_admin read policy only). */
export interface OwnLicenceRow {
  id: string;
  plan: string;
  status: string;
  client_limit: number | null;
  programme_limit: number | null;
  starts_on: string;
  ends_on: string | null;
  attribution_display: boolean;
}

/** A licence_warning notification_event row the caller can see. */
export interface LicenceWarningEvent {
  created_at: string;
  payload: {
    trigger?: 'client_limit' | 'programme_limit' | 'end_date';
    used?: number;
    limit?: number;
    ends_on?: string;
    days_to_end?: number;
  } | null;
}

export const SEAT_CAP = 5;
/** W1-07 packet threshold — licence_warning fires at/above this fraction of a cap. */
export const WARN_PCT = 80;

export const pct = (used: number, limit: number | null | undefined) =>
  limit ? Math.round((used / limit) * 100) : null;

/** 'fail' over/at cap, 'warn' at/above the W1-07 threshold, undefined otherwise. */
export function usageTone(used: number, limit: number | null | undefined, over?: boolean) {
  if (over || (limit != null && used >= limit)) return 'var(--fail)';
  const p = pct(used, limit);
  return p != null && p >= WARN_PCT ? 'var(--warn)' : undefined;
}

export function usageBadgeTone(used: number, limit: number | null | undefined, over?: boolean) {
  if (over || (limit != null && used >= limit)) return 'fail' as const;
  const p = pct(used, limit);
  if (p != null && p >= WARN_PCT) return 'warn' as const;
  return 'pass' as const;
}

/** Human sentence for one licence_warning event payload. */
export function licenceWarningText(w: LicenceWarningEvent): string {
  const p = w.payload ?? {};
  if (p.trigger === 'client_limit')
    return `Client limit near: ${p.used} of ${p.limit} in use`;
  if (p.trigger === 'programme_limit')
    return `Programme limit near: ${p.used} of ${p.limit} in use`;
  if (p.trigger === 'end_date')
    return `Licence term ends ${p.ends_on ?? 'soon'}${p.days_to_end != null ? ` (${p.days_to_end} days)` : ''}`;
  return 'Licence warning';
}
