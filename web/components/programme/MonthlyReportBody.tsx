import * as React from 'react';
import {
  type MonthlyReportDoc,
  type ReportFigure,
  STATUS_LABEL,
  dateLabel,
  figureLabel,
  periodLabel,
} from '@/lib/monthly-report';
import s from './MonthlyReportBody.module.css';

// W2-08 — THE monthly report body (screen 05 / FR-RPT-01..02). One server-
// rendered, print-safe component: the builder shows it, and W3-03's PDF
// export prints exactly this markup in the partner's branding (product
// decision 06/11: HTML-rendered PDF, no Word). Input is report_document()
// verbatim — every figure is the bound month-end snapshot value (§9.5), so
// nothing rendered here can drift from the snapshot.
//
// The builder passes `narrativeSlot` / `headerSlot` (editor nodes) while the
// report is draft-like; without them (print, read-only, issued) the stored
// text renders. No client code is imported here.
//
// Copy rule: the platform never asserts certification or compliance — the
// only fixed strings below are neutral labels.

function FigureValue({ value }: { value: unknown }) {
  if (value == null) return <>—</>;
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>);
    if (!entries.length) return <>—</>;
    return (
      <>
        {entries.map(([k, v]) => (
          <div key={k}>
            {k}: {v == null ? '—' : String(v)}
          </div>
        ))}
      </>
    );
  }
  return <>{String(value)}</>;
}

function Figures({ figures }: { figures: ReportFigure[] }) {
  if (!figures.length) return null;
  return (
    <table className={s.figures}>
      <tbody>
        {figures.map((f) => (
          <tr key={f.key}>
            <th scope="row">{figureLabel(f.key)}</th>
            <td>
              <FigureValue value={f.value} />
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export function MonthlyReportBody({
  doc,
  narrativeSlot,
  headerSlot,
}: {
  doc: MonthlyReportDoc;
  narrativeSlot?: Record<string, React.ReactNode>;
  headerSlot?: React.ReactNode;
}) {
  const brandName = doc.branding?.name ?? null;
  const accent = doc.branding?.accent_hex ?? undefined;

  return (
    <article
      className={s.doc}
      style={accent ? ({ ['--report-accent' as string]: accent } as React.CSSProperties) : undefined}
      aria-label={`Monthly report ${periodLabel(doc.period)}`}
    >
      <header className={s.brand}>
        <span className={s.brandName}>{brandName ?? doc.client.name}</span>
        {doc.branding?.logo_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img className={s.brandLogo} src={doc.branding.logo_url} alt={brandName ?? ''} />
        ) : null}
      </header>

      <h1 className={s.title}>Monthly report — {periodLabel(doc.period)}</h1>
      <div className={s.meta}>
        <span>{doc.client.name}</span>
        <span>{doc.programme.name}</span>
        {doc.reference ? <span>Ref {doc.reference}</span> : null}
        {doc.version > 1 ? <span>Version {doc.version} (correction)</span> : null}
        <span>Status: {STATUS_LABEL[doc.status] ?? doc.status}</span>
        <span>Due {dateLabel(doc.due_on)}</span>
        {doc.snapshot ? <span>Figures as at {dateLabel(doc.snapshot.taken_at)}</span> : null}
        {doc.overall_rag ? <span>Overall RAG: {doc.overall_rag}</span> : null}
        {doc.trend ? <span>Trend: {doc.trend}</span> : null}
      </div>

      {doc.gate_override_reason ? (
        <p className={s.banner}>
          <strong>Maintenance inputs outstanding at review:</strong> {doc.gate_override_reason}
        </p>
      ) : null}

      {headerSlot ?? (
        <>
          {doc.headline ? <p className={s.headline}>{doc.headline}</p> : null}
          {doc.commentary ? <p className={s.narrative}>{doc.commentary}</p> : null}
        </>
      )}

      {doc.sections.map((sec) => (
        <section key={sec.key} className={s.section}>
          <h2 className={s.sectionTitle}>
            {sec.title}
            {sec.figures.length ? <span className={s.lock}>snapshot-locked figures</span> : null}
          </h2>
          <Figures figures={sec.figures} />
          {sec.narrative_mode === 'none' ? null : narrativeSlot?.[sec.key] !== undefined ? (
            narrativeSlot[sec.key]
          ) : sec.narrative ? (
            <p className={s.narrative}>{sec.narrative}</p>
          ) : (
            <p className={s.empty}>No narrative recorded.</p>
          )}
        </section>
      ))}

      {doc.signatures.length || doc.issued_on ? (
        <footer className={s.signoff}>
          {doc.signatures.length ? (
            <>
              <strong>Signed</strong>
              <ul>
                {doc.signatures.map((sg, i) => (
                  <li key={i}>
                    {sg.name ?? 'Unknown user'} ({sg.role === 'alternate' ? 'named alternate' : 'accountable officer'}) ·{' '}
                    {dateLabel(sg.at)}
                    {sg.note ? ` · ${sg.note}` : ''}
                  </li>
                ))}
              </ul>
            </>
          ) : null}
          {doc.issued_on ? (
            <p style={{ margin: '8px 0 0' }}>
              <strong>Issued</strong> {dateLabel(doc.issued_on)}
              {doc.issued_by_name ? ` by ${doc.issued_by_name}` : ''}
            </p>
          ) : null}
        </footer>
      ) : null}
    </article>
  );
}
