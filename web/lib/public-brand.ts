import { headers } from 'next/headers';
import { serverClient } from './supabase';
import { partnerSubdomainFromHost } from './brand-host';

// ---------------------------------------------------------------------------
// W2-15 — FR-BRN-01/02/05: the brand the SIGN-IN surface paints. Before there
// is a session the host's first label resolves the partner through the
// public_partner_brand definer (20261106000034 — anon-safe, active partners
// only, the narrow public slice). No subdomain or no match → null → the
// platform's own SecurePath chrome, which is also what a partner never sees
// of another partner's brand (AT-05).
// ---------------------------------------------------------------------------

export interface PublicBrand {
  partnerId: string;
  name: string;
  logoUrl: string | null;
  accentHex: string | null;
  primaryHex: string | null;
  signInText: string | null;
  supportContact: string | null;
  /** FR-BRN-05 — the partner's active licence carries attribution_display */
  showAttribution: boolean;
}

interface PublicBrandRow {
  practice_id: string;
  name: string;
  logo_url: string | null;
  accent_hex: string | null;
  primary_hex: string | null;
  sign_in_text: string | null;
  support_contact: string | null;
  attribution_display: boolean | null;
}

export async function publicBrandForRequest(): Promise<PublicBrand | null> {
  const sub = partnerSubdomainFromHost((await headers()).get('host'));
  if (!sub) return null;
  const supabase = await serverClient();
  const { data, error } = await supabase.rpc('public_partner_brand', {
    p_subdomain: sub,
  });
  if (error || !data) return null; // migration not applied / no match → default brand
  const p = data as PublicBrandRow;
  return {
    partnerId: p.practice_id,
    name: p.name,
    logoUrl: p.logo_url,
    accentHex: p.accent_hex,
    primaryHex: p.primary_hex,
    signInText: p.sign_in_text,
    supportContact: p.support_contact,
    showAttribution: p.attribution_display !== false,
  };
}
