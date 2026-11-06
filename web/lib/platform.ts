import type { SupabaseClient } from '@supabase/supabase-js';

// ---------------------------------------------------------------------------
// W2-14 — platform admin data shapes + role gates.
// Every read goes through the 20261106000015 RPCs (platform_list_partners,
// platform_list_clients, platform_metrics) or the W1-07 RPCs (usage_report,
// list_support_grants) under the caller's JWT. Platform staff have no RLS
// visibility into practices / client_orgs, and NFR-04 says they must not —
// so there is no table fallback anywhere in the platform screens.
// ---------------------------------------------------------------------------

export interface PartnerRow {
  partner_id: string;
  name: string;
  type: 'msp' | 'reseller' | 'securepath_direct';
  status: 'active' | 'suspended' | 'closed';
  status_reason: string | null;
  status_changed_at: string | null;
  country: string | null;
  subdomain: string | null;
  primary_contact: string | null;
  support_contact: string | null;
  data_region_default: string | null;
  created_at: string;
  licence_id: string | null;
  licence_plan: string | null;
  licence_status: string | null;
  licence_starts_on: string | null;
  licence_ends_on: string | null;
  client_limit: number | null;
  programme_limit: number | null;
  clients_total: number;
  clients_used: number;
  programmes_used: number;
  over_client_limit: boolean | null;
  over_programme_limit: boolean | null;
  seats_used: number;
  pending_invites: number;
}

export interface PlatformClientRow {
  client_org_id: string;
  client_name: string;
  partner_id: string;
  partner_name: string;
  jurisdiction: string | null;
  created_at: string;
  programmes_total: number;
  programmes_open: number;
}

export interface LicenceRow {
  id: string;
  partner_id: string;
  plan: string;
  client_limit: number | null;
  programme_limit: number | null;
  starts_on: string;
  ends_on: string | null;
  status: 'draft' | 'active' | 'suspended' | 'terminated';
  attribution_display: boolean;
  created_at: string;
  updated_at: string;
}

export interface PlatformMetrics {
  generated_at: string;
  partners: { total: number; active: number; suspended: number; closed: number; by_type: Record<string, number> };
  licences: Record<string, number>;
  clients: { total: number; with_open_programme: number };
  programmes: {
    total: number;
    implementation: number;
    maintenance: number;
    closed: number;
    by_framework: Record<string, number>;
  };
  active_users: number;
  evidence_awaiting: { verification: number; acceptance: number; total: number };
  support: { pending_requests: number; active_grants: number };
}

export const PARTNER_TYPES: { value: PartnerRow['type']; label: string }[] = [
  { value: 'msp', label: 'MSP' },
  { value: 'reseller', label: 'Reseller' },
  { value: 'securepath_direct', label: 'SecurePath Direct' },
];

export const typeLabel = (t: string | null | undefined) =>
  PARTNER_TYPES.find((p) => p.value === t)?.label ?? t ?? '—';

export const capLabel = (used: number | null | undefined, limit: number | null | undefined) =>
  `${used ?? 0} / ${limit == null ? '∞' : limit}`;

export const dateLabel = (d: string | null | undefined) =>
  d ? new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';

export interface PlatformGate {
  isAdmin: boolean;
  isSupport: boolean;
  /** platform_admin or support — may open the platform screens at all */
  any: boolean;
}

/** UI gate via the W0-00 predicate — the RPC bodies re-check every call. */
export async function platformGate(supabase: SupabaseClient): Promise<PlatformGate> {
  const [{ data: admin }, { data: support }] = await Promise.all([
    supabase.rpc('is_platform_role', { p_roles: ['platform_admin'] }),
    supabase.rpc('is_platform_role', { p_roles: ['support'] }),
  ]);
  const isAdmin = admin === true;
  const isSupport = support === true;
  return { isAdmin, isSupport, any: isAdmin || isSupport };
}
