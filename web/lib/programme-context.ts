import type { SupabaseClient } from '@supabase/supabase-js';
import { serverClient } from './supabase';
import { getRoleContext, type RoleContext } from './role-context';

// ---------------------------------------------------------------------------
// W2-00 — programme + branding context for the programme world (FR-BRN).
//
// RLS GAP (flagged for the orchestrator): practices_read still resolves
// through the DEPRECATED current_practice() shim, which returns NULL for
// pure new-role users (executive, programme_lead, workstream_lead,
// external_provider, assessor, platform_*, client-scope partner_consultant).
// For those callers the `practices` row is unreadable — brand falls back to
// SecurePath defaults (brand == null). licences_read is partner_admin /
// platform_admin only, so for most callers the attribution flag is
// unreadable too — showAttribution therefore defaults TRUE unless a readable
// active licence explicitly sets it false (the flag's column default is
// also true; only SecurePath may unset it). A definer-side
// partner_branding(client_org)/licence_flag RPC would close this gap.
// ---------------------------------------------------------------------------

export interface BrandInfo {
  partnerId: string;
  name: string;
  logoUrl: string | null;
  accentHex: string | null;
  primaryHex: string | null;
  supportContact: string | null;
  signInText: string | null;
  type: 'msp' | 'reseller' | 'securepath_direct' | null;
}

export interface BrandContext {
  /** null when the caller has no resolvable partner OR the practices row is RLS-hidden */
  brand: BrandInfo | null;
  /** FR-BRN-05 — render the SecurePath attribution line */
  showAttribution: boolean;
  /** the partner id resolved from the caller's scopes, even if unreadable */
  partnerId: string | null;
}

export interface ProgrammeSummary {
  id: string;
  name: string;
  status: 'implementation' | 'maintenance' | 'closed' | string;
  phase: string | null;
  start_date: string;
  total_weeks: number;
  programme_rag: 'Red' | 'Amber' | 'Green' | null;
  programme_lead: string | null;
}

export interface ProgrammeContext extends BrandContext {
  role: RoleContext;
  programme: ProgrammeSummary;
  client: {
    id: string;
    name: string;
    practice_id: string;
    jurisdiction: string | null;
    legal_name: string | null;
    trading_name: string | null;
  };
}

const PRACTICE_COLS =
  'id, name, logo_url, accent_hex, primary_hex, support_contact, sign_in_text, type';
// pre-W0-01 column set — retried if the environment's DB lacks the new columns
const PRACTICE_COLS_LEGACY = 'id, name, logo_url, accent_hex';
const CLIENT_COLS = 'id, name, practice_id, jurisdiction, legal_name, trading_name';
const CLIENT_COLS_LEGACY = 'id, name, practice_id';

/**
 * Resolve the caller's partner id: first partner-scope assignment wins;
 * otherwise derive it from any visible client (client_orgs is T1 —
 * readable by every level that can see a programme).
 */
async function resolvePartnerId(
  supabase: SupabaseClient,
  role: RoleContext | null,
  clientOrgId?: string
): Promise<string | null> {
  if (role?.partnerIds.length) return role.partnerIds[0];
  if (clientOrgId) {
    const { data } = await supabase
      .from('client_orgs')
      .select('practice_id')
      .eq('id', clientOrgId)
      .maybeSingle();
    if (data?.practice_id) return data.practice_id as string;
  }
  if (role?.clientOrgIds.length) {
    const { data } = await supabase
      .from('client_orgs')
      .select('practice_id')
      .eq('id', role.clientOrgIds[0])
      .maybeSingle();
    if (data?.practice_id) return data.practice_id as string;
  }
  // last resort: any visible client at all (programme-scope-only callers)
  const { data: anyClient } = await supabase
    .from('client_orgs')
    .select('practice_id')
    .limit(1)
    .maybeSingle();
  return (anyClient?.practice_id as string) ?? null;
}

async function fetchBrand(
  supabase: SupabaseClient,
  partnerId: string | null
): Promise<{ brand: BrandInfo | null; showAttribution: boolean }> {
  if (!partnerId) return { brand: null, showAttribution: true };
  const [{ data: pFull }, { data: lic }] = await Promise.all([
    supabase.from('practices').select(PRACTICE_COLS).eq('id', partnerId).maybeSingle(),
    supabase
      .from('licences')
      .select('id, plan, status, attribution_display')
      .eq('partner_id', partnerId)
      .eq('status', 'active')
      .maybeSingle(),
  ]);
  // schema may lag the migrations — retry with the pre-W0-01 columns
  const p: Record<string, unknown> | null =
    pFull ??
    (
      await supabase
        .from('practices')
        .select(PRACTICE_COLS_LEGACY)
        .eq('id', partnerId)
        .maybeSingle()
    ).data;
  const brand: BrandInfo | null = p
    ? {
        partnerId,
        name: p.name as string,
        logoUrl: (p.logo_url as string) ?? null,
        accentHex: (p.accent_hex as string) ?? null,
        primaryHex: (p.primary_hex as string) ?? null,
        supportContact: (p.support_contact as string) ?? null,
        signInText: (p.sign_in_text as string) ?? null,
        type: (p.type as BrandInfo['type']) ?? null,
      }
    : null;
  // FR-BRN-05: show unless a readable active licence says otherwise (see header note).
  return { brand, showAttribution: lic?.attribution_display !== false };
}

/** Partner-level brand context (no programme in scope) — used by the group shell. */
export async function brandContext(
  sb?: SupabaseClient,
  role?: RoleContext | null
): Promise<BrandContext> {
  const supabase = sb ?? (await serverClient());
  const roleCtx = role === undefined ? await getRoleContext(supabase) : role;
  const partnerId = await resolvePartnerId(supabase, roleCtx);
  const { brand, showAttribution } = await fetchBrand(supabase, partnerId);
  return { brand, showAttribution, partnerId };
}

/**
 * Full context for one programme: programme row + owning client + partner
 * branding + licence flag + the caller's role context. Returns null when the
 * programme does not exist or is not visible to the caller (programmes_read
 * is T1/T2 — allowed_client_orgs() ∪ allowed_programmes()).
 *
 * The programme + client pair comes from the programme_context() RPC
 * (20261106000012): programme/workstream-scope callers can read the
 * programmes row but not client_orgs, so an invoker join would 404 them —
 * the definer RPC returns just this slice, guarded by allowed_programmes().
 * Falls back to direct table reads where the migration isn't applied yet.
 */
export async function programmeContext(
  programmeId: string,
  sb?: SupabaseClient
): Promise<ProgrammeContext | null> {
  const supabase = sb ?? (await serverClient());
  const role = await getRoleContext(supabase);
  if (!role) return null;

  type Packed = { programme: Record<string, unknown>; client: Record<string, unknown> };
  let prog: Record<string, unknown> | null;
  let client: Record<string, unknown> | null;

  const { data: packed, error: rpcErr } = await supabase.rpc('programme_context', {
    p_programme: programmeId,
  });
  if (rpcErr) {
    // RPC not deployed yet — legacy path (fails closed for scoped callers)
    const { data: progRow } = await supabase
      .from('programmes')
      .select(
        'id, name, status, phase, start_date, total_weeks, programme_rag, programme_lead, client_org_id'
      )
      .eq('id', programmeId)
      .maybeSingle();
    if (!progRow) return null;
    prog = progRow as Record<string, unknown>;
    const { data: clientFull } = await supabase
      .from('client_orgs')
      .select(CLIENT_COLS)
      .eq('id', progRow.client_org_id)
      .maybeSingle();
    client =
      clientFull ??
      (
        await supabase
          .from('client_orgs')
          .select(CLIENT_COLS_LEGACY)
          .eq('id', progRow.client_org_id)
          .maybeSingle()
      ).data;
  } else {
    // RPC ran: NULL = programme absent or not visible to the caller
    if (!packed) return null;
    prog = (packed as Packed).programme;
    client = (packed as Packed).client;
  }
  if (!prog || !client) return null;

  const partnerId =
    (client.practice_id as string) ??
    (await resolvePartnerId(supabase, role, client.id as string));
  const { brand, showAttribution } = await fetchBrand(supabase, partnerId);

  return {
    role,
    programme: prog as unknown as ProgrammeSummary,
    client: client as ProgrammeContext['client'],
    brand,
    showAttribution,
    partnerId,
  };
}
