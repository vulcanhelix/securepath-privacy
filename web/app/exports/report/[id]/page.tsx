import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { MonthlyReportBody } from '@/components/programme/MonthlyReportBody';
import { STATUS_LABEL, type MonthlyReportDoc } from '@/lib/monthly-report';

export const dynamic = 'force-dynamic';

// W3-04 (#45) — the human-readable export of a monthly report (spec §11).
// PLAIN render: the same stored-document markup the builder shows
// (MonthlyReportBody — every figure resolves from the bound §9.5 snapshot)
// without partner-brand chrome; #104's /report/[id]/print supersedes this
// with the branded render once that PR merges. The browser's Save-as-PDF
// is the PDF route in R1.
//
// Fail closed twice, same gates as the builder screen:
//   1. report_document → report_for_caller raises for a programme outside
//      the caller's allowed_programmes() (absent and hidden look identical);
//   2. programmeContext — a caller who cannot resolve the programme world
//      gets the same 404 every programme screen gives.
// Reading this page is a disclosure — export_report_view() writes the same
// audit_log row the CSV exports write (action export.report_view).

export default async function ReportExportPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await serverClient();

  const { data, error } = await supabase.rpc('report_document', {
    p_report_id: id,
  });
  const doc = data as MonthlyReportDoc | null;
  if (error || !doc) notFound();

  const ctx = await programmeContext(doc.programme.id, supabase);
  if (!ctx) notFound();

  // disclosure audit — the render is an export too (best-effort: both
  // visibility gates already passed, so a failure here is infra, not authz)
  await supabase.rpc('export_report_view', { p_report_id: id });

  const issued = doc.status === 'issued';
  const statusLabel = STATUS_LABEL[doc.status] ?? doc.status;

  return (
    <div
      style={{
        maxWidth: 860,
        margin: '0 auto',
        padding: '24px 20px 48px',
        background: 'var(--surface, #fff)',
      }}
    >
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 16,
          marginBottom: 16,
          fontSize: 14,
        }}
      >
        <Link href={`/programmes/${doc.programme.id}/exports`}>← Exports</Link>
        <span className="muted">
          {issued ? 'Issued report' : `${statusLabel} — not issued · working copy only`}
        </span>
      </div>

      {!issued ? (
        <p
          style={{
            border: '1px solid var(--line, #ddd)',
            borderRadius: 8,
            padding: '10px 14px',
            fontSize: 14,
          }}
        >
          {statusLabel} — this report has not been issued. Working copy only.
        </p>
      ) : null}

      <MonthlyReportBody doc={doc} />
    </div>
  );
}
