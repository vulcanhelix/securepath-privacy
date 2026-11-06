import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { EmptyState } from '@/components/ui/EmptyState';
import { StatusPill } from '@/components/ui/StatusPill';
import {
  REPORT_WRITE_ROLES,
  STATUS_LABEL,
  dateLabel,
  periodLabel,
  type ReportListRow,
} from '@/lib/monthly-report';
import { CreateReportForm } from './CreateReportForm';

export const dynamic = 'force-dynamic';

// W2-08 — monthly reports list (screen 05, FR-RPT-01/04/06). Rows come from
// list_reports (state, due business day, late flag, signed + issued info),
// all under the caller's JWT. The create affordance is a UI hint only —
// create_monthly_report re-checks the write role and the §9.5 snapshot day.

export default async function ReportsPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const [{ data, error }, { data: canWrite }] = await Promise.all([
    supabase.rpc('list_reports', { p_programme_id: id }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: REPORT_WRITE_ROLES }),
  ]);
  const rows = (data ?? []) as ReportListRow[];
  const base = `/programmes/${id}/reports`;
  const late = rows.filter((r) => r.late && r.status !== 'issued').length;

  return (
    <>
      <PageHeader
        title="Monthly report"
        meta={`${rows.length} report${rows.length === 1 ? '' : 's'}${late ? ` · ${late} late` : ''} · built from month-end snapshots`}
      />

      {error ? <Alert tone="err">{`Could not load reports: ${error.message}`}</Alert> : null}

      {canWrite === true ? (
        <Card title="Start a report" pad={20} style={{ marginBottom: 16 }}>
          <CreateReportForm programmeId={id} />
        </Card>
      ) : null}

      <Card pad={0}>
        {rows.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Period</th>
                  <th>Status</th>
                  <th>Due</th>
                  <th>Inputs outstanding</th>
                  <th>Signed</th>
                  <th>Issued</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id}>
                    <td style={{ fontWeight: 500 }}>
                      {periodLabel(r.period)}
                      {r.version > 1 ? (
                        <span className="muted" style={{ marginLeft: 6 }}>v{r.version}</span>
                      ) : null}
                      {!r.is_latest ? (
                        <div style={{ marginTop: 4 }}><Badge tone="neutral">superseded</Badge></div>
                      ) : null}
                    </td>
                    <td>
                      <StatusPill status={r.status} label={STATUS_LABEL[r.status] ?? r.status} />
                    </td>
                    <td>
                      <span className="muted">{dateLabel(r.due_on)}</span>
                      {r.late ? (
                        <div style={{ marginTop: 4 }}>
                          <Badge tone="fail" dot>
                            {r.status === 'issued' ? `Issued ${r.days_late}d late` : `Late ${r.days_late}d`}
                          </Badge>
                        </div>
                      ) : null}
                    </td>
                    <td className="mono">{r.status === 'issued' ? '—' : r.inputs_outstanding}</td>
                    <td className="muted">
                      {r.signed_at ? `${r.signed_by_name ?? '—'} · ${dateLabel(r.signed_at)}` : '—'}
                    </td>
                    <td className="muted">
                      {r.issued_on ? (
                        <>
                          {r.issued_by_name ?? '—'} · {dateLabel(r.issued_on)}
                          {r.reference ? (
                            <div className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{r.reference}</div>
                          ) : null}
                        </>
                      ) : (
                        '—'
                      )}
                    </td>
                    <td>
                      <Link href={`${base}/${r.id}`} style={{ whiteSpace: 'nowrap' }}>
                        {r.status === 'issued' ? 'View →' : 'Open →'}
                      </Link>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          !error && (
            <EmptyState
              icon="file-text"
              message="No monthly reports yet. A report is built from the month-end snapshot taken on the period's last business day."
            />
          )
        )}
      </Card>
      <p className="muted" style={{ marginTop: 8 }}>
        Issued reports are locked — a correction opens a new version (NFR-09).
      </p>
    </>
  );
}
