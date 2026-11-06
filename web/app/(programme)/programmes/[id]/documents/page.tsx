import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { DocumentRegister, type DocRow, type ActivityOption } from './DocumentRegister';

export const dynamic = 'force-dynamic';

// W2-12 — controlled document register (spec §8.13 FR-DOC-01, NFR-09).
// Reads via list_controlled_documents (definer, can_read_client_records):
// review_state is computed from the SERVER's CURRENT_DATE, never the browser
// clock. Documents are client-level (§6.2) — shared across the client's
// programmes; links point at this client's activities. Role checks here only
// decide which controls render; every write RPC re-checks in its body.

const WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];
const ISSUE_ROLES = [...WRITE_ROLES, 'accountable_officer'];

export default async function DocumentsPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ withdrawn?: string }>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();
  const showWithdrawn = sp.withdrawn === '1';

  const [docsRes, actRes, { data: canWrite }, { data: canIssue }] = await Promise.all([
    supabase.rpc('list_controlled_documents', {
      p_client_org_id: ctx.client.id,
      p_include_withdrawn: showWithdrawn,
    }),
    supabase
      .from('activities')
      .select('id, ref, text')
      .eq('programme_id', id)
      .eq('active', true)
      .order('ref'),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: WRITE_ROLES }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: ISSUE_ROLES }),
  ]);

  const docs = (docsRes.data ?? []) as DocRow[];
  const activities = (actRes.data ?? []) as ActivityOption[];
  const live = docs.filter((d) => d.status === 'draft' || d.status === 'issued');
  const overdue = live.filter((d) => d.review_state === 'overdue').length;
  const dueSoon = live.filter((d) => d.review_state === 'due_soon').length;
  const issued = docs.filter((d) => d.status === 'issued').length;
  const drafts = docs.filter((d) => d.status === 'draft').length;
  const refs = new Set(docs.map((d) => d.reference)).size;
  const today = docs[0]?.today ?? null;

  const stat = (n: number, label: string, tone?: string) => (
    <Card pad={16} style={{ flex: '1 1 120px' }}>
      <div className="mono" style={{ fontSize: 28, color: tone }}>{n}</div>
      <div className="muted">{label}</div>
    </Card>
  );

  return (
    <>
      <PageHeader
        title="Document register"
        meta={`${refs} document${refs === 1 ? '' : 's'} · ${ctx.client.name}${today ? ` · review dates as of ${today}` : ''}`}
      />

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        {stat(issued, 'Issued (in force)')}
        {stat(drafts, 'Drafts')}
        {stat(dueSoon, 'Review due ≤ 30 days', dueSoon ? 'var(--warn)' : undefined)}
        {stat(overdue, 'Review overdue', overdue ? 'var(--fail)' : undefined)}
      </div>

      {docsRes.error ? <Alert tone="err">{`Could not load the register: ${docsRes.error.message}`}</Alert> : null}

      <DocumentRegister
        clientOrgId={ctx.client.id}
        programmeId={id}
        docs={docs}
        activities={activities}
        canWrite={canWrite === true}
        canIssue={canIssue === true}
        showWithdrawn={showWithdrawn}
      />
    </>
  );
}
