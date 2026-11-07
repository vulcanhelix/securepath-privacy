import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';
import { Icon } from '@/components/ui/Icon';

export const dynamic = 'force-dynamic';

// W3-04 (#45) — exports (spec §11). One link per artefact onto the
// /api/exports CSV routes; the monthly-report card also lists each report's
// human-readable render (/exports/report/[id] — plain HTML for now; #104's
// partner-branded print supersedes it once merged). Every download is
// audited in Postgres (export.* audit_log rows) and the RPCs re-check
// visibility themselves, so this page is only ever a directory of links.

interface Artefact {
  title: string;
  note: string;
  href: string;
}

interface ReportRow {
  id: string;
  period: string;
  status: string;
  reference: string | null;
}

export default async function ExportsPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const { data: reports, error } = await supabase.rpc('list_reports', {
    p_programme_id: id,
  });
  const reportRows = (reports ?? []) as ReportRow[];

  const artefacts: Artefact[] = [
    {
      title: 'Register items',
      note: 'Findings with priority, status, linked activities and the evidence-acceptance record',
      href: `/api/exports/register/${id}`,
    },
    {
      title: 'Activity schedule',
      note: 'Activities with weeks, dates, status, RAG, leads and dependencies',
      href: `/api/exports/activities/${id}`,
    },
    {
      title: 'Evidence index',
      note: 'Evidence manifest — refs, review state, outcomes and acceptance (the assessor-pack index)',
      href: `/api/exports/evidence-index/${id}`,
    },
    {
      title: 'KPI history',
      note: 'Every KPI with its monthly actuals and evidence refs',
      href: `/api/exports/kpi-history/${id}`,
    },
    {
      title: 'Maintenance history',
      note: 'Generated maintenance tasks by period with completion and evidence',
      href: `/api/exports/maintenance-history/${id}`,
    },
    {
      title: 'Monthly reports',
      note: 'The report ledger — period, version, status, reference, due and issue dates',
      href: `/api/exports/reports/${id}`,
    },
  ];

  const isPartnerAdmin = ctx.role.assignments.some(
    (a) =>
      a.level === 'partner' &&
      a.role === 'partner_admin' &&
      a.scope_type === 'partner' &&
      a.scope_id === ctx.client.practice_id
  );
  const isPlatformAdmin = ctx.role.hasRole('platform', 'platform_admin');

  return (
    <>
      <PageHeader
        title="Exports"
        meta={`${ctx.programme.name} — CSV downloads · every export is recorded in the audit trail`}
      />
      {error ? <Alert tone="err">{`Could not load the report list: ${error.message}`}</Alert> : null}

      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))',
          gap: 12,
          marginBottom: 20,
        }}
      >
        {artefacts.map((a) => (
          <Card key={a.title} pad={16}>
            <div style={{ fontWeight: 600, marginBottom: 4 }}>{a.title}</div>
            <div className="muted" style={{ fontSize: 13, marginBottom: 10 }}>
              {a.note}
            </div>
            <a className="sp-btn sp-btn--secondary sp-btn--sm" href={a.href} download>
              <Icon name="download" size={14} /> CSV
            </a>
          </Card>
        ))}

        <Card pad={16}>
          <div style={{ fontWeight: 600, marginBottom: 4 }}>Client pack</div>
          <div className="muted" style={{ fontSize: 13, marginBottom: 10 }}>
            Every programme of {ctx.client.name} with its latest report version per month
          </div>
          <a
            className="sp-btn sp-btn--secondary sp-btn--sm"
            href={`/api/exports/client-pack/${ctx.client.id}`}
            download
          >
            <Icon name="download" size={14} /> CSV
          </a>
        </Card>

        {isPartnerAdmin || isPlatformAdmin ? (
          <Card pad={16}>
            <div style={{ fontWeight: 600, marginBottom: 4 }}>Audit trail extract</div>
            <div className="muted" style={{ fontSize: 13, marginBottom: 10 }}>
              The partner&apos;s append-only audit log — admins only (spec §11)
            </div>
            <a
              className="sp-btn sp-btn--secondary sp-btn--sm"
              href={`/api/exports/audit/${ctx.client.practice_id}`}
              download
            >
              <Icon name="download" size={14} /> CSV
            </a>
          </Card>
        ) : null}
      </div>

      <Card title="Human-readable reports" pad={0}>
        {reportRows.length ? (
          <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
            {reportRows.map((r) => (
              <li
                key={r.id}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 12,
                  padding: '10px 20px',
                  borderBottom: '1px solid var(--line)',
                }}
              >
                <span style={{ minWidth: 90 }}>
                  <Icon name="file-text" size={14} /> {r.period}
                </span>
                <span className="muted" style={{ flex: 1 }}>
                  {r.status}
                  {r.reference ? ` · ${r.reference}` : ''}
                </span>
                <Link href={`/exports/report/${r.id}`}>Open report</Link>
              </li>
            ))}
          </ul>
        ) : (
          <EmptyState icon="file-text" message="No monthly reports yet." />
        )}
      </Card>
    </>
  );
}
