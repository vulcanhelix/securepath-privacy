import type { RoleContext } from './role-context';

// ---------------------------------------------------------------------------
// W2-00 — nav catalogue for the programme world. One slot per W2 screen
// (BUILD_PLAN_R1 §4 "W2 — Screens"); spec §4 role tables decide visibility.
//
// The catalogue is DATA, not layout: W2 sessions point their slot at the real
// route and flip `implemented`. Unimplemented slots render disabled so the
// shell shows the full map without 404s.
//
// Visibility rules (spec §4.1/§4.2 capability tables — "what they see"):
//   platform: platform_admin → admin + licences; content_author → template
//             library; support → nothing without a scoped grant (their
//             client-scope assignment surfaces the client modules instead).
//   partner:  partner_admin → everything; partner_consultant → console (own
//             clients) + programme modules on assigned scopes; read_only →
//             console + programme read surfaces.
//   client:   §4.2 column per role. external_provider/assessor/workstream_lead
//             are item/workstream-scoped — they keep dashboard + actions +
//             evidence (own items) but not the management modules. `all staff`
//             (no assignment) sees nothing — they never reach here: RLS
//             returns zero rows and the shell renders the empty state.
// ---------------------------------------------------------------------------

export type NavKey =
  | 'console' | 'onboarding' | 'branding' | 'team' | 'licences' // partner level
  | 'platform' | 'templates' | 'support' // platform level
  | 'dashboard' | 'schedule' | 'register' | 'evidence' | 'sessions' | 'reports'
  | 'registers' | 'maintenance' | 'kpis' | 'raid' | 'documents' | 'executive'
  | 'actions'; // programme level

export interface NavSlot {
  key: NavKey;
  label: string;
  icon: string; // lucide name — same vocabulary as the rest of the shell
  /** 'partner' slots live at /programmes level; 'programme' slots need a
      selected programme (href is appended to /programmes/[id]); 'platform'
      slots are SecurePath-only. */
  scope: 'partner' | 'programme' | 'platform';
  /** path appended to /programmes/[id] (or the absolute href for partner/platform slots) */
  href: string;
  /** build-plan session that owns the real screen; flips `implemented` */
  w2: string;
  implemented: boolean;
  visible(ctx: RoleContext, clientOrgId?: string): boolean;
}

// §4.2 role bundles (client level)
const CLIENT_READ = ['executive', 'accountable_officer', 'programme_lead', 'workstream_lead', 'assessor'];
const CLIENT_MANAGE = ['executive', 'accountable_officer', 'programme_lead'];
const CLIENT_ALL = [...CLIENT_READ, 'external_provider'];
const PARTNER_ANY = ['partner_admin', 'partner_consultant', 'read_only'];

const clientSees = (roles: string[]) => (ctx: RoleContext, clientOrgId?: string) =>
  ctx.assignments.some(
    (a) =>
      (a.level === 'client' && roles.includes(a.role) &&
        (a.scope_type !== 'client' || !clientOrgId || a.scope_id === clientOrgId)) ||
      // partner consultants/admins open client programmes they can see
      (a.level === 'partner' && PARTNER_ANY.includes(a.role)) ||
      // platform support reaches here only via a scoped (grant-backed) assignment
      (a.level === 'platform' && a.scope_type === 'client' && a.scope_id === clientOrgId)
  );

const partnerSees = (roles: string[] = PARTNER_ANY) => (ctx: RoleContext) =>
  ctx.assignments.some((a) => a.level === 'partner' && roles.includes(a.role));

const platformSees = (roles: string[]) => (ctx: RoleContext) =>
  ctx.assignments.some((a) => a.level === 'platform' && roles.includes(a.role));

export const NAV_SLOTS: NavSlot[] = [
  // ---- partner level (console world, /programmes and up) ----
  { key: 'console', label: 'Programmes', icon: 'layout-grid', scope: 'partner', href: '/programmes',
    w2: 'W2-01', implemented: true, visible: partnerSees() },
  { key: 'onboarding', label: 'Onboard client', icon: 'user-plus', scope: 'partner', href: '/clients/new',
    w2: 'W2-02', implemented: true, visible: partnerSees(['partner_admin', 'partner_consultant']) },
  { key: 'branding', label: 'Branding', icon: 'palette', scope: 'partner', href: '/settings/branding',
    w2: 'W2-03', implemented: true, visible: partnerSees(['partner_admin']) },
  { key: 'team', label: 'Team & licence', icon: 'users', scope: 'partner', href: '/team',
    w2: 'W2-17', implemented: true, visible: partnerSees(['partner_admin', 'partner_consultant']) },
  { key: 'licences', label: 'Licence usage', icon: 'badge-check', scope: 'partner', href: '/licences',
    w2: 'W2-17', implemented: false, visible: partnerSees(['partner_admin']) },

  // ---- platform level (SecurePath) ----
  { key: 'platform', label: 'Partners', icon: 'shield', scope: 'platform', href: '/admin/partners',
    w2: 'W2-14', implemented: false, visible: platformSees(['platform_admin']) },
  { key: 'templates', label: 'Templates', icon: 'library', scope: 'platform', href: '/admin/templates',
    w2: 'W2-14', implemented: false, visible: platformSees(['platform_admin', 'content_author']) },
  { key: 'support', label: 'Support access', icon: 'key-round', scope: 'platform', href: '/admin/support',
    w2: 'W4-01', implemented: false, visible: platformSees(['platform_admin', 'support']) },

  // ---- programme level (/programmes/[id]…) — spec §4.2 column ----
  { key: 'dashboard', label: 'Dashboard', icon: 'layout-dashboard', scope: 'programme', href: '',
    w2: 'W2-04', implemented: true, visible: clientSees(CLIENT_ALL) },
  { key: 'schedule', label: 'Schedule', icon: 'calendar-range', scope: 'programme', href: '/schedule',
    w2: 'W2-05', implemented: true, visible: clientSees(CLIENT_READ) },
  { key: 'register', label: 'Register', icon: 'list-checks', scope: 'programme', href: '/register',
    w2: 'W2-16', implemented: true, visible: clientSees(CLIENT_READ) },
  { key: 'evidence', label: 'Evidence', icon: 'file-check-2', scope: 'programme', href: '/evidence',
    w2: 'W2-06', implemented: true, visible: clientSees(CLIENT_ALL) },
  { key: 'sessions', label: 'Weekly sessions', icon: 'calendar-clock', scope: 'programme', href: '/weekly',
    w2: 'W2-07', implemented: true, visible: clientSees(CLIENT_READ) },
  { key: 'reports', label: 'Monthly report', icon: 'file-text', scope: 'programme', href: '/reports',
    w2: 'W2-08', implemented: false, visible: clientSees(CLIENT_MANAGE) },
  { key: 'registers', label: 'Operational registers', icon: 'siren', scope: 'programme', href: '/registers',
    w2: 'W2-09', implemented: false, visible: clientSees(CLIENT_MANAGE) },
  { key: 'maintenance', label: 'Maintenance', icon: 'refresh-cw', scope: 'programme', href: '/maintenance',
    w2: 'W2-10', implemented: false, visible: clientSees(CLIENT_ALL.filter((r) => r !== 'assessor')) },
  { key: 'kpis', label: 'KPIs', icon: 'gauge', scope: 'programme', href: '/kpis',
    w2: 'W2-11', implemented: true, visible: clientSees(CLIENT_READ) },
  { key: 'raid', label: 'RAID & decisions', icon: 'alert-triangle', scope: 'programme', href: '/raid',
    w2: 'W2-11', implemented: true, visible: clientSees(CLIENT_READ) },
  { key: 'documents', label: 'Documents & training', icon: 'folder-open', scope: 'programme', href: '/documents',
    w2: 'W2-12', implemented: false, visible: clientSees(CLIENT_READ) },
  { key: 'executive', label: 'Executive view', icon: 'presentation', scope: 'programme', href: '/executive',
    w2: 'W2-13', implemented: false, visible: clientSees(CLIENT_MANAGE.concat('assessor')) },
  { key: 'actions', label: 'My actions', icon: 'check-square', scope: 'programme', href: '/actions',
    w2: 'W2-13', implemented: false, visible: clientSees(CLIENT_ALL) },
];

/** Slots the caller may see, in catalogue order. */
export function visibleSlots(
  ctx: RoleContext,
  scope: NavSlot['scope'],
  clientOrgId?: string
): NavSlot[] {
  return NAV_SLOTS.filter((s) => s.scope === scope && s.visible(ctx, clientOrgId));
}
