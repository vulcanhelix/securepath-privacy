import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { StatusPill } from '@/components/ui/StatusPill';
import { MonthlyReportBody } from '@/components/programme/MonthlyReportBody';
import {
  REPORT_WRITE_ROLES,
  STATUS_LABEL,
  dateLabel,
  periodLabel,
  type InputOutstanding,
  type MonthlyReportDoc,
  type ReportListRow,
} from '@/lib/monthly-report';
import { HeaderFields, NarrativeField } from './ReportEditors';
import { ReportActions } from './ReportActions';

export const dynamic = 'force-dynamic';

// W2-08 — monthly report builder (screen 05, FR-RPT-01..04/06). The body is
// report_document() rendered by MonthlyReportBody — the same component the
// W3-03 PDF prints. Figures are snapshot-locked (§9.5) and never editable;
// narrative editors are slotted in only while the report is draft-like and
// the caller holds a write role. After issue the page is read-only (NFR-09).

export default async function ReportBuilderPage({
  params,
}: {
  params: Promise<{ id: string; reportId: string }>;
}) {
  const { id, reportId } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const [docRes, inputsRes, listRes, writeRes, aoRoleRes, isAo] = await Promise.all([
    supabase.rpc('report_document', { p_report_id: reportId }),
    supabase.rpc('report_inputs_outstanding', { p_report_id: reportId }),
    supabase.rpc('list_reports', { p_programme_id: id }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: REPORT_WRITE_ROLES }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: ['accountable_officer'] }),
    ctx.role.isAoOrAlternate(ctx.client.id),
  ]);

  const doc = docRes.data as MonthlyReportDoc | null;
  if (docRes.error || !doc || doc.programme.id !== id) notFound();

  const inputs = (inputsRes.data ?? []) as InputOutstanding[];
  const row = ((listRes.data ?? []) as ReportListRow[]).find((r) => r.id === reportId);
  const canWrite = writeRes.data === true;
  const editable = canWrite && (doc.status === 'draft' || doc.status === 'inputs_complete');
  const maintenance = inputs.filter((i) => i.kind === 'maintenance_task');
  const narrative = inputs.filter((i) => i.kind === 'narrative');

  const narrativeSlot = editable
    ? Object.fromEntries(
        doc.sections
          .filter((s) => s.narrative_mode !== 'none')
          .map((s) => [
            s.key,
            <NarrativeField
              key={s.key}
              reportId={doc.id}
              sectionKey={s.key}
              initial={s.narrative}
              required={s.narrative_mode === 'required'}
            />,
          ])
      )
    : undefined;

  return (
    <>
      <PageHeader
        title={`Monthly report — ${periodLabel(doc.period)}`}
        back="Reports"
        backHref={`/programmes/${id}/reports`}
        meta={
          <span style={{ display: 'inline-flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <StatusPill status={doc.status} label={STATUS_LABEL[doc.status] ?? doc.status} />
            {doc.version > 1 ? <Badge tone="neutral">v{doc.version}</Badge> : null}
            <span>Due {dateLabel(doc.due_on)}</span>
            {doc.late ? (
              <Badge tone="fail" dot>
                {doc.status === 'issued' ? `Issued ${doc.days_late}d late` : `Late ${doc.days_late}d`}
              </Badge>
            ) : null}
            {row && !row.is_latest ? <Badge tone="neutral">superseded by a correction</Badge> : null}
          </span>
        }
      />

      {inputsRes.error ? (
        <Alert tone="err">{`Could not load inputs outstanding: ${inputsRes.error.message}`}</Alert>
      ) : null}
      {doc.status === 'issued' ? (
        <Alert tone="info">
          Issued {dateLabel(doc.issued_on)}
          {doc.issued_by_name ? ` by ${doc.issued_by_name}` : ''} — this report is locked and cannot change (NFR-09).
        </Alert>
      ) : doc.status === 'ao_review' || doc.status === 'signed' ? (
        <Alert tone="info">Content is locked at this stage. Return the report for changes to amend it.</Alert>
      ) : null}

      <div style={{ display: 'flex', gap: 16, alignItems: 'flex-start', flexWrap: 'wrap' }}>
        <div style={{ flex: '3 1 560px', minWidth: 0 }}>
          <MonthlyReportBody
            doc={doc}
            narrativeSlot={narrativeSlot}
            headerSlot={
              editable ? (
                <HeaderFields
                  reportId={doc.id}
                  headline={doc.headline}
                  commentary={doc.commentary}
                  overallRag={doc.overall_rag}
                  trend={doc.trend}
                />
              ) : undefined
            }
          />
        </div>

        <div style={{ flex: '1 1 280px', display: 'flex', flexDirection: 'column', gap: 16 }}>
          <Card title="Workflow" pad={20} style={{ marginBottom: 0 }}>
            <ReportActions
              programmeId={id}
              reportId={doc.id}
              status={doc.status}
              isLatest={row?.is_latest ?? true}
              canWrite={canWrite}
              isAoOrAlternate={isAo}
              isAccountableOfficer={aoRoleRes.data === true}
              maintenanceOpen={maintenance.length}
            />
          </Card>

          {doc.status !== 'issued' ? (
            <Card
              title="Inputs outstanding"
              pad={20}
              style={{ marginBottom: 0 }}
              action={<Badge tone={inputs.length ? 'warn' : 'pass'}>{inputs.length}</Badge>}
            >
              {inputs.length ? (
                <ul style={{ margin: 0, paddingLeft: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
                  {narrative.map((i) => (
                    <li key={`n-${i.ref}`}>
                      <strong>{i.label}</strong> <span className="muted">— narrative missing</span>
                    </li>
                  ))}
                  {maintenance.map((i) => (
                    <li key={`m-${i.ref}`}>
                      <span className="mono">{i.ref}</span> {i.label}{' '}
                      <span className="muted">
                        — {i.status}
                        {i.due_date ? `, due ${dateLabel(i.due_date)}` : ''}
                      </span>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="muted" style={{ margin: 0 }}>Nothing outstanding.</p>
              )}
              {maintenance.length ? (
                <p className="muted" style={{ margin: '10px 0 0', fontSize: 'var(--fs-xs)' }}>
                  Open report-feeding maintenance tasks block AO review unless the programme lead records a reason
                  (FR-MNT-07).
                </p>
              ) : null}
            </Card>
          ) : null}
        </div>
      </div>
    </>
  );
}
