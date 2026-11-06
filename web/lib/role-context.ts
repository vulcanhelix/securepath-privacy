import type { SupabaseClient } from '@supabase/supabase-js';
import { serverClient } from './supabase';

// ---------------------------------------------------------------------------
// W2-00 — caller role context for the programme world.
// Reads the spec §6.1 role_assignments model (migration 20261105000001) via the
// W0-00 predicate catalogue — active_assignments() is SECURITY DEFINER and
// applies the active-window rule (start_date <= today < end_date, exclusive).
// Designations come from 20261105000002 (spec §6.1, FR-ACC-02/03).
// Everything here runs under the CALLER's JWT — RLS and the definer guards do
// the authorisation; this module only interprets the result for the shell.
// ---------------------------------------------------------------------------

export type RoleLevel = 'platform' | 'partner' | 'client';
export type ScopeType = 'partner' | 'client' | 'programme' | 'workstream';
export type DesignationRole =
  | 'information_officer'
  | 'deputy_information_officer'
  | 'dpo'
  | 'named_alternate';

export interface RoleAssignment {
  id: string;
  level: RoleLevel;
  role: string;
  scope_type: ScopeType;
  scope_id: string | null; // NULL only for global platform grants
  start_date: string;
  end_date: string | null; // EXCLUSIVE — see 20261105000001 header
}

export interface Designation {
  id: string;
  client_org_id: string;
  role: DesignationRole;
  date_designated: string;
  end_date: string | null;
}

export interface RoleContext {
  userId: string;
  email: string | null;
  assignments: RoleAssignment[];
  designations: Designation[];
  /** distinct active levels, in platform→partner→client order */
  levels: RoleLevel[];
  isPlatform: boolean;
  isPartner: boolean;
  isClient: boolean;
  /** partner-scope scope_ids (practices the caller belongs to) */
  partnerIds: string[];
  /** client-scope scope_ids */
  clientOrgIds: string[];
  /** programme-scope scope_ids */
  programmeIds: string[];
  /** caller holds an active assignment at `level` whose role ∈ `roles` */
  hasRole(level: RoleLevel, ...roles: string[]): boolean;
  /** caller holds role at `level` scoped to `scopeId` (any scope type) */
  hasScopedRole(level: RoleLevel, roles: string[], scopeId: string): boolean;
  /** current designation(s) the caller holds for a client — FR-ACC-02/03 */
  holdsDesignation(clientOrgId: string, ...roles: DesignationRole[]): boolean;
  /** FR-ACC-02: accountable officer or named alternate for that client */
  isAoOrAlternate(clientOrgId: string): boolean;
}

const LEVEL_ORDER: RoleLevel[] = ['platform', 'partner', 'client'];

export async function getRoleContext(sb?: SupabaseClient): Promise<RoleContext | null> {
  const supabase = sb ?? (await serverClient());
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  // Predicate-catalogue RPC + the caller's own designation rows (designations_read
  // is T1 client-scope; the person filter keeps it to the caller).
  const today = new Date().toISOString().slice(0, 10);
  const [{ data: ra }, { data: des }] = await Promise.all([
    supabase.rpc('active_assignments', { p_user: user.id }),
    supabase
      .from('designations')
      .select('id, client_org_id, role, date_designated, end_date')
      .eq('person', user.id)
      .or(`end_date.is.null,end_date.gt.${today}`),
  ]);

  const assignments = (ra ?? []) as RoleAssignment[];
  const designations = (des ?? []) as Designation[];

  const levels = LEVEL_ORDER.filter((l) => assignments.some((a) => a.level === l));
  const scoped = (level: RoleLevel, scopeType: ScopeType) =>
    assignments
      .filter((a) => a.level === level && a.scope_type === scopeType && a.scope_id)
      .map((a) => a.scope_id as string);

  const ctx: RoleContext = {
    userId: user.id,
    email: user.email ?? null,
    assignments,
    designations,
    levels,
    isPlatform: levels.includes('platform'),
    isPartner: levels.includes('partner'),
    isClient: levels.includes('client'),
    partnerIds: scoped('partner', 'partner'),
    clientOrgIds: scoped('client', 'client'),
    programmeIds: scoped('client', 'programme'),
    hasRole: (level, ...roles) =>
      assignments.some((a) => a.level === level && roles.includes(a.role)),
    hasScopedRole: (level, roles, scopeId) =>
      assignments.some((a) => a.level === level && a.scope_id === scopeId && roles.includes(a.role)),
    holdsDesignation: (clientOrgId, ...roles) =>
      designations.some(
        (d) => d.client_org_id === clientOrgId && (roles.length === 0 || roles.includes(d.role))
      ),
    isAoOrAlternate: (clientOrgId) =>
      designations.some(
        (d) =>
          d.client_org_id === clientOrgId &&
          (d.role === 'information_officer' || d.role === 'named_alternate')
      ),
  };
  return ctx;
}
