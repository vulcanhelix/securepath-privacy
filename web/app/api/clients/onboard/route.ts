import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { BASE_URL } from '@/lib/base-url';
import { opsAlert, sendMail } from '@/lib/mail';

// ---------------------------------------------------------------------------
// W2-02 — client onboarding commit endpoint (FR-ONB-01, spec §7.3 screen 11).
// The wizard collects; THIS endpoint writes — exclusively through the same
// RPCs the rest of the system uses, under the caller's JWT so every definer
// guard and RLS rule applies:
//   create_client_org        client shell + §6.1 details + jurisdiction + region
//   appoint_designation      statutory designations (000017)
//   create_invite            client users & roles (branded mail follows)
//   create_programme         programme from a published template version (000008)
//
// Not a single transaction on purpose — the spec asks for partial-failure
// reporting ("atomically-ish"). Each step runs in order; a failed step is
// reported with the RPC's own error and later steps that depend on it are
// marked skipped. Client creation itself is the only fatal step (everything
// else needs a client to hang off).
// ---------------------------------------------------------------------------

interface StepResult {
  key: string;
  label: string;
  status: 'ok' | 'error' | 'skipped';
  detail?: string;
}

interface DesignationInput {
  role?: string;
  person?: string;
  date_designated?: string;
  registration_ref?: string;
}

interface InviteInput {
  email?: string;
  role?: string;
}

const DESIGNATION_ROLES = new Set([
  'information_officer', 'deputy_information_officer', 'dpo', 'named_alternate',
]);
const INVITE_ROLES = new Set(['client_admin', 'client_contributor']);

export async function POST(req: NextRequest) {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const b = await req.json().catch(() => null);
  const c = b?.client;
  if (!c || typeof c.name !== 'string' || !c.name.trim()) {
    return NextResponse.json({ error: 'client.name required' }, { status: 400 });
  }

  const steps: StepResult[] = [];

  // ---- 1. client shell (fatal on failure) ----------------------------------
  const { data: clientId, error: cErr } = await supabase.rpc('create_client_org', {
    p_name: c.name.trim(),
    p_registration_no: c.registration_number || null,
    p_industry: c.sector || null,
    p_contact_name: c.contact_name || null,
    p_contact_email: c.contact_email || null,
    p_org_scale: c.org_scale === 'sme' ? 'sme' : 'large',
    p_data_region: c.data_region || null,
    p_jurisdiction: c.jurisdiction || null,
    p_legal_name: c.legal_name || null,
    p_trading_name: c.trading_name || null,
    p_sector: c.sector || null,
    p_headcount_in_scope:
      c.headcount_in_scope === '' || c.headcount_in_scope == null
        ? null : Number(c.headcount_in_scope),
    p_sites: Array.isArray(c.sites) && c.sites.length ? c.sites : null,
    p_timezone: c.timezone || null,
  });
  if (cErr) {
    steps.push({ key: 'client', label: 'Create client', status: 'error', detail: cErr.message });
    return NextResponse.json({ error: cErr.message, steps }, { status: 400 });
  }
  steps.push({ key: 'client', label: 'Create client', status: 'ok', detail: clientId });

  // ---- 2. statutory designations (optional) ---------------------------------
  const designations: DesignationInput[] = Array.isArray(b.designations) ? b.designations : [];
  for (const d of designations) {
    if (!d.role || !d.person) continue;
    if (!DESIGNATION_ROLES.has(d.role)) {
      steps.push({ key: `designation:${d.role}`, label: `Designate ${d.role}`, status: 'error',
                   detail: `unknown designation role ${d.role}` });
      continue;
    }
    const { error } = await supabase.rpc('appoint_designation', {
      p_client_org_id: clientId,
      p_role: d.role,
      p_person: d.person,
      p_date_designated: d.date_designated || null,
      p_registration_ref: d.registration_ref || null,
    });
    steps.push({
      key: `designation:${d.role}`, label: `Designate ${d.role}`,
      status: error ? 'error' : 'ok', detail: error?.message,
    });
  }

  // ---- 3. client users (optional invites) ------------------------------------
  const { data: practice } = await supabase
    .from('practices').select('name').maybeSingle();
  const invites: InviteInput[] = Array.isArray(b.invites) ? b.invites : [];
  for (const i of invites) {
    const email = (i.email ?? '').trim().toLowerCase();
    if (!email) continue;
    if (!INVITE_ROLES.has(i.role ?? '')) {
      steps.push({ key: `invite:${email}`, label: `Invite ${email}`, status: 'error',
                   detail: `role must be ${[...INVITE_ROLES].join(' or ')}` });
      continue;
    }
    const { data: token, error } = await supabase.rpc('create_invite', {
      p_email: email, p_role: i.role, p_client_org_id: clientId,
    });
    if (error) {
      steps.push({ key: `invite:${email}`, label: `Invite ${email}`, status: 'error', detail: error.message });
      continue;
    }
    // branded invite mail is best-effort — the invite row + token exist either way
    const link = `${BASE_URL}/invite/${token}`;
    await sendMail(
      email,
      `${practice?.name ?? 'Your MSP'} invited you to their compliance portal`,
      `<p>${practice?.name ?? 'Your MSP'} has set up a compliance workspace for ${c.name}.</p>
       <p><a href="${link}">Accept your invite</a> (valid 7 days)</p>`,
    );
    steps.push({ key: `invite:${email}`, label: `Invite ${email} (${i.role})`, status: 'ok' });
  }

  // ---- 4. programme (optional) ------------------------------------------------
  let programmeId: string | null = null;
  const p = b.programme;
  if (p && p.template_version_id) {
    const { data: pid, error } = await supabase.rpc('create_programme', {
      p_client_org_id: clientId,
      p_template_version_id: p.template_version_id,
      p_name: (p.name ?? '').trim() || `${c.name.trim()} programme`,
      p_start_date: p.start_date || null,
    });
    if (error) {
      steps.push({ key: 'programme', label: 'Create programme', status: 'error', detail: error.message });
    } else {
      programmeId = pid as string;
      steps.push({ key: 'programme', label: 'Create programme', status: 'ok', detail: programmeId });
    }
  }

  // ---- alerts (best-effort; the billing_events row inside create_client_org is
  //       the authoritative ledger entry) --------------------------------------
  await opsAlert(
    `[billing] instance created: ${c.name}`,
    `Practice "${practice?.name ?? '?'}" created client instance "${c.name}" (${clientId})` +
      (programmeId ? ` + programme ${programmeId}` : '') + ' — bill 1 instance.',
  );

  return NextResponse.json({ client_id: clientId, programme_id: programmeId, steps });
}
