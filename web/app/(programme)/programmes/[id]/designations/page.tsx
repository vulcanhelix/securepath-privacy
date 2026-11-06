import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { Designations, type DesignationRow, type Candidate } from './Designations';

export const dynamic = 'force-dynamic';

// W2-12 — statutory designations (spec FR-ACC-03, FR-ACC-02). Reads via
// list_designations (definer; holder names resolved server-side). Appoint /
// end / evidence controls render only for the APPOINT set
// (partner_admin, partner_consultant, accountable_officer) — the same set
// appoint_designation / end_designation / set_designation_evidence enforce in
// their bodies. client_admin is deliberately excluded (D3 in the migration):
// a named_alternate inherits FR-ACC-02 closure powers via is_ao_or_alternate.

const APPOINT_ROLES = ['partner_admin', 'partner_consultant', 'accountable_officer'];
const ROLES = ['information_officer', 'deputy_information_officer', 'dpo', 'named_alternate'] as const;

export default async function DesignationsPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const [desRes, { data: canAppoint }, { data: aoOrAlt }] = await Promise.all([
    supabase.rpc('list_designations', { p_client_org_id: ctx.client.id }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: APPOINT_ROLES }),
    supabase.rpc('is_ao_or_alternate', { p_client_org: ctx.client.id }),
  ]);
  const rows = (desRes.data ?? []) as DesignationRow[];

  // eligible designees per role — jurisdiction-pack rule lives in the DB
  // (designation_eligible); only fetched for appointers (RPC refuses others)
  const candidates: Record<string, Candidate[]> = {};
  if (canAppoint === true) {
    const res = await Promise.all(
      ROLES.map((r) => supabase.rpc('designation_candidates', { p_client_org_id: ctx.client.id, p_role: r }))
    );
    ROLES.forEach((r, i) => (candidates[r] = (res[i].data ?? []) as Candidate[]));
  }

  const current = rows.filter((r) => r.is_current).length;
  const jurisdiction = ctx.client.jurisdiction ?? 'not set';

  return (
    <>
      <PageHeader
        title="Statutory designations"
        meta={`${current} current · ${ctx.client.name} · jurisdiction ${jurisdiction}`}
        actions={aoOrAlt === true ? <Badge tone="accent">You are the accountable officer or a named alternate</Badge> : null}
      />
      {desRes.error ? <Alert tone="err">{`Could not load designations: ${desRes.error.message}`}</Alert> : null}
      <p className="muted" style={{ marginTop: 0, fontSize: 'var(--fs-sm)', maxWidth: 760 }}>
        Information Officer, Deputy Information Officer, DPO and named alternates are recorded against named
        individuals with the designation date and evidence of appointment. Ending a designation keeps it in the
        history; nothing is deleted. Who may hold each designation follows the client&apos;s jurisdiction pack.
      </p>
      <Designations
        clientOrgId={ctx.client.id}
        rows={rows}
        roles={[...ROLES]}
        candidates={candidates}
        canAppoint={canAppoint === true}
      />
    </>
  );
}
