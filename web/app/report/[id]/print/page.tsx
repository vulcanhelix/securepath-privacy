import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { MonthlyReportBody } from '@/components/programme/MonthlyReportBody';
import { Attribution } from '@/components/programme/Attribution';
import { STATUS_LABEL, type MonthlyReportDoc } from '@/lib/monthly-report';
import { PrintButton } from './PrintButton';
import './print.css';

export const dynamic = 'force-dynamic';

// W3-03 — the print-ready render of a monthly report (FR-RPT-05; product
// decision 06/11: HTML → PDF via the browser, no Word). It prints exactly the
// MonthlyReportBody markup the builder screen shows, inside the issuing
// partner's brand (name / logo_url / accent resolved by report_document →
// partner_branding). Every figure is the bound month-end snapshot value
// (§9.5) and issued content is trigger-locked, so the render is a pure,
// deterministic function of stored rows — nothing here re-queries live
// programme data. The PDF is the browser's Save-as-PDF of this page.
//
// Fail closed twice, the same two gates the builder screen uses:
//   1. report_document → report_for_caller raises for a programme outside
//      the caller's allowed_programmes() (absent and hidden look identical);
//   2. programmeContext — a caller who cannot resolve the programme world
//      gets the same 404 every programme screen gives.
// Both → notFound; nothing of the document is rendered for a non-visible
// caller.

export default async function ReportPrintPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();

  const { data, error } = await supabase.rpc('report_document', { p_report_id: id });
  const doc = data as MonthlyReportDoc | null;
  if (error || !doc) notFound();

  const ctx = await programmeContext(doc.programme.id, supabase);
  if (!ctx) notFound();

  const issued = doc.status === 'issued';
  const statusLabel = STATUS_LABEL[doc.status] ?? doc.status;

  return (
    <div className="rp-page">
      {/* screen-only toolbar — never printed */}
      <div className="rp-bar">
        <Link className="rp-back" href={`/programmes/${doc.programme.id}/reports/${doc.id}`}>
          ← Report
        </Link>
        <span className={`rp-status ${issued ? 'rp-status--issued' : 'rp-status--draft'}`}>
          {issued ? 'Issued' : `${statusLabel} — not issued`}
        </span>
        <PrintButton />
        <span className="rp-hint">Use “Save as PDF” in the print dialog for the PDF export.</span>
      </div>

      {/* an un-issued render is unmistakably not the issued document */}
      {!issued ? (
        <>
          <p className="rp-banner">
            {statusLabel} — this report has not been issued. Working copy only.
          </p>
          <div className="rp-draftmark" data-testid="draft-watermark" aria-hidden="true">
            <span>{statusLabel} — not issued</span>
          </div>
        </>
      ) : null}

      <div className="rp-scope">
        <MonthlyReportBody doc={doc} />
      </div>

      {ctx.showAttribution ? (
        <footer className="rp-foot">
          <Attribution partnerName={doc.branding?.name ?? ctx.brand?.name} />
        </footer>
      ) : null}
    </div>
  );
}
