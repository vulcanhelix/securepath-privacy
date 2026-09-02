import type {
  ClassRegisterRow, ReportBrand, ReportOverrides, ReportPayload, Severity,
} from './types';
import { STATUS_LABELS } from './spec';

const esc = (value: unknown): string =>
  String(value ?? '').replace(/[&<>"']/g, char =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]!));

const SEV_COLOR: Record<Severity, string> = {
  Critical: 'var(--fail)', High: 'var(--fail)', Medium: 'var(--warn)', Low: 'var(--pass)',
};
const sevChip = (severity: Severity | string | null) => {
  if (!severity) return '—';
  const color = SEV_COLOR[severity as Severity] ?? 'var(--muted)';
  return `<span class="chip" style="color:${color};border-color:${color}">${esc(severity)}</span>`;
};
const statusCell = (status: string) => {
  const label = STATUS_LABELS[status] ?? status;
  const cls = status === 'fully_compliant'
    ? 'ok'
    : status === 'partial' ? 'warn'
      : status === 'under_review' ? 'review'
        : status === 'non_compliant' ? 'bad' : 'mut';
  return `<span class="st ${cls}">${esc(label)}</span>`;
};
const para = (text: string | null) =>
  text ? text.split(/\n{2,}/).map(part => `<p>${esc(part).replace(/\n/g, '<br/>')}</p>`).join('') : '';
const table = (heads: string[], rows: string[][], cls = '') =>
  `<table class="${cls}"><thead><tr>${heads.map(head => `<th>${head}</th>`).join('')}</tr></thead>` +
  `<tbody>${rows.map(row => `<tr>${row.map(cell => `<td>${cell}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
const fmtDate = (date: string | null) => (date ? String(date).slice(0, 10) : '—');
const list = (items: string[]) =>
  items.length ? `<ul>${items.map(item => `<li>${esc(item)}</li>`).join('')}</ul>` : '<p><i>None recorded.</i></p>';

type AwarenessData = {
  coverage?: {
    cohorts_completed?: number; departments_planned?: number | null;
    departments_covered?: string[]; limitation?: boolean;
  };
  overall?: { respondents?: number; pct?: number; rating?: string };
  domains?: {
    code: string; name: string; questions?: number; answered: number; aligned: number;
    pct: number | null; rating: string;
  }[];
  high_risk_questions?: {
    code: string; question: string; pct: number | null; answered: number; aligned: number;
  }[];
};

export function renderReportHtml(
  payload: ReportPayload,
  overrides: ReportOverrides,
  brand: ReportBrand,
): string {
  const excluded = new Set(overrides.sections_excluded ?? []);
  const narrative = (key: string) =>
    overrides.narratives?.[key] ?? payload.sections[key]?.narrative_default ?? null;
  const accent = /^#[0-9a-fA-F]{6}$/.test(brand.accentHex ?? '') ? brand.accentHex! : '#2b2644';
  const docRef = payload.cover.audit_ref || `${payload.meta.framework.toUpperCase()}-ASSESSMENT`;
  const logo = brand.logo?.startsWith('data:image/') ? brand.logo : null;
  const mergedRegister = payload.classification_register?.map(row => {
    const override = overrides.classification?.[row.uid];
    return override ? {
      ...row,
      item: override.item ?? row.item,
      cls: override.cls,
      cls_source: 'advisor' as const,
      documents_covering: override.documents_covering ?? row.documents_covering,
      evidence_required: override.evidence_required ?? row.evidence_required,
      owner: override.owner ?? row.owner,
      workstream: override.workstream ?? row.workstream,
    } : row;
  }) ?? null;

  const renderers: Record<string, () => string | null> = {
    cover: () => coverSection(payload),
    exec_summary: () => execSummary(payload),
    company_profile: () => companyProfileSection(payload),
    scope_methodology: () => scopeSection(payload),
    alignment: () => alignmentSection(payload),
    domains: () => domainsSection(payload),
    awareness: () => awarenessSection(payload),
    risk_register: () => riskRegisterSection(payload),
    roadmap: () => roadmapSection(payload),
    documentation_issued: () => documentationSection(payload),
    classification_register: () => classificationSection(payload),
    implementation_programme: () => implementationProgrammeSection(payload),
    delivery_options: () => deliverySection(payload),
    residual_risk: () => residualSection(payload),
    conclusion: () => para(narrative('conclusion')) || null,
    appendices: () => appendicesSection(payload),
  };

  const parts: string[] = [];
  for (const section of payload.section_order) {
    if (excluded.has(section.key)) continue;
    const body = (renderers[section.key] ?? (() => para(narrative(section.key)) || null))();
    const rendered = body || '<p><i>No evidence or advisor content was recorded for this section.</i></p>';
    if (section.key === 'cover') {
      parts.push(rendered);
    } else {
      parts.push(`<section class="sec"><h2>${esc(section.title)}</h2>${rendered}</section>`);
    }
  }

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/>
<title>${esc(payload.cover.client_name)} — ${esc(payload.meta.framework.toUpperCase())} Assessment Report v${payload.meta.version}</title>
<style>
  :root {
    --accent: ${accent};
    --bg: #f5f5f5;
    --surface: #ffffff;
    --inset: #ededed;
    --border: #e4e4e4;
    --border-strong: #d2d2d2;
    --text: #000000;
    --text-2: rgba(0, 0, 0, .7);
    --muted: rgba(0, 0, 0, .6);
    --faint: rgba(0, 0, 0, .45);
    --panel: #2b2644;
    --pass: #1a5c46;
    --pass-soft: #eaf1ee;
    --pass-border: #bfd6cd;
    --warn: #85681a;
    --warn-soft: #f4eedb;
    --warn-border: #dccfa3;
    --fail: #96302c;
    --fail-soft: #f6eae9;
    --fail-border: #e2c4c1;
    --info: #2b2644;
    --info-soft: #ecebf1;
  }
  * { box-sizing: border-box; margin: 0; }
  html { background: var(--bg); -webkit-font-smoothing: antialiased; }
  body {
    color: var(--text);
    background: var(--bg);
    font: 13px/1.6 'TT Norms Pro', Inter, 'Segoe UI', Helvetica, Arial, sans-serif;
    padding: 40px 24px;
  }
  .report {
    max-width: 920px;
    margin: 0 auto;
    padding: 36px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 24px;
  }
  h1 {
    font-size: 32px;
    line-height: 1.14;
    letter-spacing: -.03em;
    font-weight: 500;
  }
  h2 {
    font-size: 22px;
    line-height: 1.25;
    letter-spacing: -.02em;
    font-weight: 500;
    margin: 0 0 18px;
    break-after: avoid;
  }
  h3 {
    font-size: 15px;
    line-height: 1.35;
    font-weight: 600;
    margin: 20px 0 8px;
    break-after: avoid;
  }
  p { color: var(--text-2); margin: 0 0 10px; }
  ul, ol { color: var(--text-2); margin: 8px 0 16px 22px; }
  li { margin-bottom: 5px; }
  .sec {
    margin-top: 24px;
    padding: 28px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 16px;
  }
  .sec > h2::before {
    content: '';
    display: inline-block;
    width: 4px;
    height: 20px;
    margin-right: 10px;
    border-radius: 999px;
    background: var(--accent);
    vertical-align: -2px;
  }
  table {
    width: 100%;
    border: 1px solid var(--border);
    border-spacing: 0;
    border-collapse: separate;
    border-radius: 12px;
    margin: 10px 0 16px;
    font-size: 11.5px;
    overflow: hidden;
  }
  thead { display: table-header-group; }
  tr { break-inside: avoid; }
  th {
    color: var(--faint);
    background: var(--bg);
    text-align: left;
    text-transform: uppercase;
    letter-spacing: .1em;
    padding: 11px 12px 9px;
    border-bottom: 1px solid var(--border);
    font-size: 9.5px;
    line-height: 1.35;
    font-weight: 600;
  }
  td {
    color: var(--text-2);
    padding: 10px 12px;
    border-bottom: 1px solid var(--border);
    vertical-align: top;
  }
  tbody tr:last-child td { border-bottom: 0; }
  .chip {
    display: inline-block;
    border: 1px solid var(--border-strong);
    border-radius: 999px;
    padding: 3px 9px;
    font-size: 10px;
    line-height: 1.35;
    font-weight: 500;
    white-space: nowrap;
  }
  .st {
    display: inline-block;
    border: 1px solid var(--border);
    border-radius: 999px;
    padding: 3px 9px;
    font-size: 10px;
    line-height: 1.35;
    font-weight: 500;
    white-space: nowrap;
  }
  .st.ok { color: var(--pass); background: var(--pass-soft); border-color: var(--pass-border); }
  .st.warn { color: var(--warn); background: var(--warn-soft); border-color: var(--warn-border); }
  .st.review { color: var(--info); background: var(--info-soft); border-color: var(--accent); }
  .st.bad { color: var(--fail); background: var(--fail-soft); border-color: var(--fail-border); }
  .st.mut { color: var(--muted); background: var(--bg); }
  .cover {
    min-height: 78vh;
    display: flex;
    flex-direction: column;
    justify-content: center;
    padding: 52px;
    color: #fff;
    background: var(--panel);
    border-top: 8px solid var(--accent);
    border-radius: 20px;
  }
  .brand-lockup {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 44px;
    color: #fff;
    font-size: 14px;
    font-weight: 500;
  }
  .conf {
    display: inline-block;
    align-self: flex-start;
    margin-bottom: 18px;
    padding: 5px 12px;
    border: 1px solid rgba(255, 255, 255, .3);
    border-radius: 999px;
    color: #fff;
    font-size: 10px;
    line-height: 1.2;
    letter-spacing: .12em;
    font-weight: 600;
  }
  .cover .sub { color: rgba(255, 255, 255, .7); font-size: 16px; margin: 10px 0 30px; }
  .cover h3 { color: #fff; }
  .cover p { color: rgba(255, 255, 255, .7) !important; }
  .cover table { background: #fff; }
  .cover .meta td:first-child { width: 32%; color: var(--faint); background: var(--bg); font-weight: 500; }
  .scorebox {
    display: flex;
    gap: 26px;
    align-items: center;
    margin: 12px 0 18px;
    padding: 18px 22px;
    border: 1px solid var(--border);
    border-left: 5px solid var(--accent);
    border-radius: 12px;
    background: var(--bg);
  }
  .scorebox .pct { font-size: 44px; line-height: 1; letter-spacing: -.04em; font-weight: 500; }
  .scorebox .lab { color: var(--muted); font-size: 14px; font-weight: 500; }
  .logo { max-height: 44px; max-width: 180px; }
  .foot { color: var(--faint); font-size: 10px; text-align: right; margin-top: 24px; }
  @page { size: A4; margin: 16mm 14mm; }
  @media print {
    html, body { background: #fff; widows: 3; orphans: 3; }
    body { padding: 0; font-size: 10.5pt; line-height: 1.45; }
    .report { max-width: none; padding: 0; border: 0; border-radius: 0; }
    .cover {
      min-height: 252mm;
      break-after: page;
      print-color-adjust: exact;
      -webkit-print-color-adjust: exact;
    }
    .sec {
      margin: 0;
      padding: 0;
      border: 0;
      border-radius: 0;
      break-before: page;
    }
    h2, h3 { break-after: avoid-page; }
    h2 + *, h3 + * { break-before: avoid-page; }
    table { overflow: visible; border-radius: 0; }
    thead { display: table-header-group; }
    tr, .scorebox, li { break-inside: avoid-page; }
    p { widows: 3; orphans: 3; }
    th, .scorebox, .st { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
  }
</style></head><body><main class="report">
${parts.join('\n')}
<div class="foot">${esc(docRef)} · v${payload.meta.version} · CONFIDENTIAL</div>
</main></body></html>`;

  function coverSection(report: ReportPayload): string {
    const structured = report.structured.cover;
    const rows = [
      ['Prepared for', esc(report.cover.org_name || report.cover.client_name)],
      ['Document reference', esc(docRef)],
      ['Version', `v${report.meta.version} — ${esc(report.meta.kind.replace(/_/g, ' '))}`],
      ['Date', esc(fmtDate(report.meta.compiled_at))],
      ['Prepared by', esc(structured.prepared_by || report.cover.auditor_name || report.cover.practice_name || '—')],
      ['For the attention of', esc(structured.attention || '—')],
      ['Scope of version', esc(structured.scope_of_version || '—')],
    ];
    const history = report.cover.history.length
      ? `<h3>Document control</h3>${table(
        ['Version', 'Type', 'Status', 'Issued'],
        report.cover.history.map(item => [
          `v${item.version}`, esc(item.kind.replace(/_/g, ' ')),
          esc(item.status), esc(fmtDate(item.issued_at)),
        ]))}`
      : '';
    const confidentiality = structured.confidentiality_statement ||
      `This document contains information that is confidential and proprietary to ` +
      `${report.cover.org_name || report.cover.client_name}. It shall not be disclosed, transmitted ` +
      `or duplicated without explicit written permission. This report reflects the evidence available ` +
      `at the assessment date and does not constitute legal advice.`;
    const frameworkTitle = report.spec.alignment_table?.length
      ? `${report.meta.framework.toUpperCase()} & ISO/IEC 27701`
      : report.meta.framework.toUpperCase();
    return `<div class="cover">
      <div class="brand-lockup">
        ${logo ? `<img class="logo" src="${esc(logo)}" alt=""/>` : ''}
        <span>${esc(report.cover.practice_name || brand.practiceName)}</span>
      </div>
      <span class="conf">CONFIDENTIAL</span>
      <h1>${esc(frameworkTitle)} Compliance Assessment Report</h1>
      <div class="sub">${esc(report.cover.client_name)}${report.cover.audit_date ? ` · ${esc(fmtDate(report.cover.audit_date))}` : ''}</div>
      <table class="meta"><tbody>${rows.map(row => `<tr><td>${row[0]}</td><td>${row[1]}</td></tr>`).join('')}</tbody></table>
      ${history}<p style="margin-top:16px;font-size:11.5px">${esc(confidentiality)}</p>
    </div>`;
  }

  function execSummary(report: ReportPayload): string {
    const summary = report.summary;
    const statusPct = (count: number) => summary.counts.total
      ? `${Math.round((count / summary.counts.total) * 1000) / 10}%`
      : '—';
    const dashboard = table(
      ['Assessment domain', 'Compliant', 'Partial', 'Under Review', 'Non-Compliant', 'Rating'],
      summary.dashboard.map(domain => [
        esc(domain.section_name),
        String(domain.counts.fully_compliant),
        String(domain.counts.partial),
        String(domain.counts.under_review),
        String(domain.counts.non_compliant),
        sevChip(domain.worst),
      ]));
    const actions = summary.top_actions.length
      ? `<h3>Top priority actions</h3><ol>${summary.top_actions.map(action => `<li>${esc(action)}</li>`).join('')}</ol>`
      : '';
    const baseline = summary.baseline
      ? `<p>Stage 1 baseline: <b>${summary.baseline.pct ?? '—'}%</b> (${esc(fmtDate(summary.baseline.at))}).` +
        (summary.prior ? ` Previous report (v${summary.prior.version}): <b>${summary.prior.overall_pct ?? '—'}%</b>.` : '') + '</p>'
      : '';
    return `${para(narrative('exec_summary'))}
      <div class="scorebox"><div class="pct">${summary.overall_pct ?? '—'}%</div>
        <div><div class="lab">${esc(summary.maturity_label)}</div>
        <div>${summary.counts.non_compliant} Non-Compliant (${statusPct(summary.counts.non_compliant)}) ·
        ${summary.counts.under_review} Under Review (${statusPct(summary.counts.under_review)}) ·
        ${summary.counts.partial} Partially Compliant (${statusPct(summary.counts.partial)}) ·
        ${summary.counts.fully_compliant} Compliant (${statusPct(summary.counts.fully_compliant)})</div></div>
      </div>
      <p><b>Inherent risk across all ${summary.counts.total} in-scope controls:</b> ${summary.risk_counts.Critical} Critical · ${summary.risk_counts.High} High ·
      ${summary.risk_counts.Medium} Medium · ${summary.risk_counts.Low} Low.</p>
      ${baseline}<h3>Assessment dashboard</h3>${dashboard}${actions}`;
  }

  function companyProfileSection(report: ReportPayload): string {
    const profile = report.structured.company_profile;
    return `${para(narrative('company_profile'))}${table(['Profile field', 'Assessment context'], [
      ['Legal entity', esc(profile.legal_name)],
      ['Registration number', esc(profile.registration_number || '—')],
      ['Location', esc(profile.location || '—')],
      ['Industry', esc(profile.industry || '—')],
      ['Principal activities', esc(profile.activities || '—')],
      ['Personal information categories', esc(profile.personal_information_categories.join(', ') || '—')],
    ])}`;
  }

  function scopeSection(report: ReportPayload): string {
    const scope = report.structured.scope;
    const scale = report.spec.rating_scale;
    const rating = scale
      ? `<h3>Rating scale</h3>${table(
        ['Status', 'Definition'], scale.statuses.map(status => [esc(status.label), esc(status.definition)]))}` +
        table(['Risk priority', 'Definition'], scale.risks.map(risk => [esc(risk.key), esc(risk.definition)]))
      : '';
    return `${para(narrative('scope_methodology'))}
      <h3>Objectives</h3>${list(scope.objectives)}
      <h3>Methodology</h3>${list(scope.methodology)}
      <h3>Scope limitations</h3>${list(scope.limitations)}
      <h3>Out-of-scope domains</h3>${list(scope.out_of_scope_domains)}
      ${rating}`;
  }

  function alignmentSection(report: ReportPayload): string | null {
    const alignment = report.spec.alignment_table;
    if (!alignment?.length) return null;
    return table(
      ['POPIA condition', 'Reference', 'ISO/IEC 27701 clause', 'ISO title'],
      alignment.map(row => [
        esc(row.condition), esc(row.reference), esc(row.iso_clause), esc(row.iso_title),
      ]));
  }

  function domainsSection(report: ReportPayload): string | null {
    if (!report.domains.length) return null;
    return report.domains.map(domain => {
      const hasIso = domain.rows.some(row => row.ref_b);
      const heads = hasIso
        ? ['Ref', 'Control area', 'POPIA reference', 'ISO 27701', 'Status', 'Risk']
        : ['Ref', 'Control area', 'Reference', 'Status', 'Risk'];
      const rows = domain.rows.map(row => {
        const base = [
          esc(row.ref),
          `${esc(row.control_area ?? '—')}<br/><span style="color:var(--muted)">${esc(row.question)}</span>`,
          esc(row.ref_a),
        ];
        if (hasIso) base.push(esc(row.ref_b ?? '—'));
        return [...base, statusCell(row.status), sevChip(row.risk)];
      });
      const observations = narrative(`domain_obs:${domain.section_id}`);
      return `<h3>${esc(domain.section_name)} — ${domain.rows.length} controls</h3>
        ${table(heads, rows)}
        ${observations ? `<p><b>Key observations.</b> ${esc(observations)}</p>` : ''}`;
    }).join('');
  }

  function awarenessSection(report: ReportPayload): string | null {
    const awareness = report.awareness as AwarenessData | null;
    if (!awareness?.overall) return null;
    const coverage = awareness.coverage;
    const limitation = coverage?.limitation
      ? `<p><i>Coverage limitation: ${coverage.cohorts_completed ?? 0} of ` +
        `${coverage.departments_planned ?? 'an unconfirmed number of'} departmental cohorts were completed. ` +
        `The findings are indicative rather than conclusive for the whole organisation.</i></p>`
      : '';
    const domains = awareness.domains?.length
      ? table(
        ['Domain', 'Questions', '% aligned', 'Rating'],
        awareness.domains.map(domain => [
          esc(domain.name), String(domain.questions ?? domain.answered),
          domain.pct != null ? `${domain.pct}%` : '—', esc(domain.rating),
        ]))
      : '';
    const highRisk = awareness.high_risk_questions?.length
      ? `<h3>High-risk behaviours</h3>${table(
        ['Code', 'Behaviour', 'Aligned'],
        awareness.high_risk_questions.map(question => [
          esc(question.code), esc(question.question),
          `${question.aligned}/${question.answered} (${question.pct ?? 0}%)`,
        ]))}`
      : '';
    return `<p>Overall alignment: <b>${awareness.overall.pct ?? '—'}%</b> across
      ${awareness.overall.respondents ?? '—'} respondents (${esc(awareness.overall.rating ?? '—')}).</p>
      ${limitation}${domains}${highRisk}`;
  }

  function riskRegisterSection(report: ReportPayload): string | null {
    if (!report.risk_register.length) return null;
    return table(
      ['#', 'Finding', 'Source ref', 'Risk', 'Recommended action / target'],
      report.risk_register.map((finding, index) => [
        String(index + 1),
        esc(finding.finding),
        esc(finding.ref),
        sevChip(finding.severity),
        `${esc(finding.recommended_action ?? '—')} (${esc(finding.target_window)})`,
      ]));
  }

  function roadmapSection(report: ReportPayload): string | null {
    if (!report.roadmap.length) return null;
    return report.roadmap.map(phase =>
      `<h3>${esc(phase.window)}</h3><ul>${phase.items.map(item =>
        `<li>${sevChip(item.severity)} <b>${esc(item.ref)}</b> — ${esc(item.action)}</li>`).join('')}</ul>`
    ).join('');
  }

  function documentationSection(report: ReportPayload): string | null {
    const documentation = report.documentation_issued;
    if (!documentation) return null;
    const suites = documentation.suites.length
      ? table(
        ['Suite', 'Documents', 'Governing document'],
        documentation.suites.map(suite => [
          esc(suite.suite), esc(suite.documents), esc(suite.governing_document),
        ]))
      : '<p><i>No document-suite summary has been recorded.</i></p>';
    const issued = documentation.rows.length
      ? `<h3>Issued document inventory</h3>${table(
        ['Document', 'Type', 'Issued'],
        documentation.rows.map(row => [
          esc(row.title), esc(row.source), esc(fmtDate(row.issued_at)),
        ]))}`
      : '';
    return `<p><b>${documentation.total_documents}</b> controlled documents are represented in this report;
      <b>${documentation.open_remediation_items}</b> remediation items remain open.</p>${suites}${issued}`;
  }

  function classificationSection(report: ReportPayload): string | null {
    if (!mergedRegister?.length) return null;
    const counts: Record<string, number> = { A: 0, B: 0, C: 0, D: 0 };
    mergedRegister.forEach(row => { counts[row.cls] += 1; });
    const legend = table(['Class', 'Meaning', 'Items'], [
      ['A', 'Closed by documentation — formal approval is the remaining evidence.', String(counts.A)],
      ['B', 'Documented — implementation required; the control is not yet operating.', String(counts.B)],
      ['C', 'Implementation only — no document closes the item.', String(counts.C)],
      ['D', 'Further documentation and implementation are both required.', String(counts.D)],
    ]);
    const register = table(
      ['Ref', 'Item', 'Class', 'Document now covering it', 'Evidence required to close', 'Owner', 'Workstream'],
      mergedRegister.map(row => [
        esc(row.ref),
        esc(row.item),
        `<b>${row.cls}</b>${row.cls_source === 'proposed' ? '<span style="color:var(--faint)">*</span>' : ''}`,
        esc(row.documents_covering.join(', ') || 'None'),
        esc(row.evidence_required ?? '—'),
        esc(row.owner ?? '—'),
        esc(row.workstream),
      ]));
    const outstanding = report.outstanding_documents?.length
      ? `<h3>Further documentation required</h3>${table(
        ['Document', 'Current position', 'Ref'],
        report.outstanding_documents.map(item => [
          esc(item.document), esc(item.position), esc(item.ref),
        ]))}`
      : '';
    return `${para(narrative('classification_register'))}${legend}${register}${outstanding}
      ${mergedRegister.some(row => row.cls_source === 'proposed')
        ? '<p style="color:var(--muted);font-size:11px">* proposed classification — approval is blocked pending advisor confirmation.</p>'
        : ''}`;
  }

  function implementationProgrammeSection(report: ReportPayload): string | null {
    const programme = report.implementation_programme;
    if (!programme?.length) return null;
    return programme.map(workstream =>
      `<h3>Workstream ${workstream.number}: ${esc(workstream.title)}</h3>
       ${table(['Items', 'Window', 'Owner'], [[
         esc(workstream.item_refs.join(', ') || 'To be assigned'),
         esc(workstream.window),
         esc(workstream.owner),
       ]])}
       <h3>Actions</h3>${list(workstream.actions)}
       ${workstream.dependencies ? `<p><b>Dependencies.</b> ${esc(workstream.dependencies)}</p>` : ''}`
    ).join('');
  }

  function deliverySection(report: ReportPayload): string | null {
    const options = report.structured.delivery_options;
    const cadence = report.structured.delivery_cadence;
    if (!options.length && !cadence.length) return null;
    const optionTable = options.length
      ? table(
        ['Route', 'Scope it can carry', 'Strength', 'Limitation'],
        options.map(option => [
          esc(option.route), esc(option.scope), esc(option.strength), esc(option.limitation),
        ]))
      : '';
    const cadenceTable = cadence.length
      ? `<h3>Standing cadence</h3>${table(
        ['Cycle', 'Activity', 'Evidence produced'],
        cadence.map(item => [esc(item.cycle), esc(item.activity), esc(item.evidence)]))}`
      : '';
    return optionTable + cadenceTable;
  }

  function residualSection(report: ReportPayload): string | null {
    const exposures = report.residual_risk;
    if (!exposures?.length) return null;
    return `<p>These exposures remain live until the identified implementation evidence is produced.</p>${table(
      ['Exposure', 'Why it matters now', 'Closed by'],
      exposures.map(exposure => [
        esc(exposure.exposure), esc(exposure.why_it_matters), esc(exposure.closed_by),
      ]))}`;
  }

  function appendicesSection(report: ReportPayload): string {
    const documents = report.appendices.documents_reviewed.length
      ? `<h3>Appendix A: Documents reviewed</h3>${table(
        ['Document', 'Version / date'],
        report.appendices.documents_reviewed.map(document => [
          esc(document.document), esc(document.version_date || '—'),
        ]))}`
      : '<h3>Appendix A: Documents reviewed</h3><p><i>No reviewed documents recorded.</i></p>';
    const respondents = report.appendices.awareness_respondents.length
      ? `<h3>Appendix B: Awareness respondents</h3>${table(
        ['Respondent', 'Questions answered', '% aligned', 'Rating'],
        report.appendices.awareness_respondents.map(respondent => [
          esc(respondent.respondent), String(respondent.questions_answered),
          `${respondent.pct_aligned}%`, esc(respondent.rating),
        ]))}`
      : '<h3>Appendix B: Awareness respondents</h3><p><i>No awareness cohort recorded.</i></p>';
    const legend = Array.isArray(report.appendices.framework_legend)
      ? `<h3>Appendix C: Standards referenced</h3>${table(
        ['Framework', 'Applicability', 'Description'],
        (report.appendices.framework_legend as {
          framework?: string; applicability?: string; description?: string;
        }[]).map(item => [
          esc(item.framework), esc(item.applicability), esc(item.description),
        ]))}`
      : '';
    return documents + respondents + legend;
  }
}

export const reportRegisterCounts = (register: ClassRegisterRow[]) =>
  register.reduce<Record<string, number>>((counts, row) => {
    counts[row.cls] = (counts[row.cls] ?? 0) + 1;
    return counts;
  }, {});
