import type { ReportBrand, ReportOverrides, ReportPayload, Severity } from './types';
import { STATUS_LABELS } from './spec';

// Deterministic template-literal renderer: same payload + overrides + brand in, same bytes
// out (the issued document is sha256'd — no React, no timestamps, no randomness here).
// Print-styled, fully self-contained HTML; browser print = the PDF.

const esc = (s: unknown): string =>
  String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

const SEV_COLOR: Record<Severity, string> = {
  Critical: '#b3261e', High: '#c2410c', Medium: '#a16207', Low: '#3f6212',
};
const sevChip = (s: Severity | string | null) => {
  if (!s) return '—';
  const c = SEV_COLOR[s as Severity] ?? '#555';
  return `<span class="chip" style="color:${c};border-color:${c}">${esc(s)}</span>`;
};
const statusCell = (s: string) => {
  const label = STATUS_LABELS[s] ?? s;
  const cls = s === 'fully_compliant' ? 'ok' : s === 'partial' ? 'warn' : s === 'non_compliant' ? 'bad' : 'mut';
  return `<span class="st ${cls}">${esc(label)}</span>`;
};
const para = (text: string | null) =>
  text ? text.split(/\n{2,}/).map(p => `<p>${esc(p).replace(/\n/g, '<br/>')}</p>`).join('') : '';
const table = (heads: string[], rows: string[][], cls = '') =>
  `<table class="${cls}"><thead><tr>${heads.map(h => `<th>${h}</th>`).join('')}</tr></thead>` +
  `<tbody>${rows.map(r => `<tr>${r.map(c => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
const fmtDate = (d: string | null) => (d ? String(d).slice(0, 10) : '—');

type AwarenessData = {
  coverage?: { cohorts_completed?: number; departments_planned?: number | null; departments_covered?: string[]; limitation?: boolean };
  overall?: { respondents?: number; pct?: number; rating?: string };
  domains?: { code: string; name: string; answered: number; aligned: number; pct: number | null; rating: string }[];
  high_risk_questions?: { code: string; question: string; pct: number | null; answered: number; aligned: number }[];
  cohorts?: { department: string; interviewed_on: string | null; respondents?: { respondent_no: number; answered: number; pct: number; rating: string }[] }[];
};

export function renderReportHtml(payload: ReportPayload, overrides: ReportOverrides, brand: ReportBrand): string {
  const excluded = new Set(overrides.sections_excluded ?? []);
  const narrative = (key: string) =>
    overrides.narratives?.[key] ?? payload.sections[key]?.narrative_default ?? null;
  const accent = /^#[0-9a-fA-F]{6}$/.test(brand.accentHex ?? '') ? brand.accentHex! : '#1f3a5f';
  const docRef = payload.cover.audit_ref || `${payload.meta.framework.toUpperCase()}-ASSESSMENT`;
  // Advisor A–D decisions saved after the last compile live only in overrides; merge them
  // here (same rule as compile) so preview and issued bytes always show the saved classes.
  const mergedRegister = payload.classification_register?.map(r => {
    const ov = overrides.classification?.[r.uid];
    return ov ? {
      ...r,
      cls: ov.cls ?? r.cls,
      cls_source: 'advisor' as const,
      evidence_required: ov.evidence_required ?? r.evidence_required,
      owner: ov.owner ?? r.owner,
    } : r;
  }) ?? null;
  const mergedResidual = mergedRegister?.filter(r => r.cls !== 'A') ?? null;

  // function declarations below are hoisted; keys not in this map fall back to a plain
  // narrative section (a pack can add a prose-only section with zero code change)
  const RENDERERS: Record<string, () => string | null> = {
    cover: () => coverSection(payload),
    exec_summary: () => execSummary(payload, narrative),
    company_profile: () => para(narrative('company_profile')) || null,
    scope_methodology: () => scopeSection(payload, narrative),
    alignment: () => alignmentSection(payload),
    domains: () => domainsSection(payload, narrative),
    awareness: () => awarenessSection(payload),
    risk_register: () => riskRegisterSection(payload),
    roadmap: () => roadmapSection(payload),
    documentation_issued: () => documentationSection(payload),
    classification_register: () => classificationSection(payload, narrative),
    residual_risk: () => residualSection(payload),
    delivery_options: () => deliverySection(payload),
    conclusion: () => para(narrative('conclusion')) || null,
    appendices: () => appendicesSection(payload),
  };

  const parts: string[] = [];
  for (const s of payload.section_order) {
    if (excluded.has(s.key)) continue;
    const body = (RENDERERS[s.key] ?? (() => para(narrative(s.key)) || null))();
    if (!body) continue;   // section with no data (e.g. awareness not conducted) is silently dropped
    if (s.key === 'cover') { parts.push(body); continue; }
    parts.push(`<section class="sec"><h2>${esc(s.title)}</h2>${body}</section>`);
  }

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/>
<title>${esc(payload.cover.client_name)} — ${esc(payload.meta.framework.toUpperCase())} Assessment Report v${payload.meta.version}</title>
<style>
  :root { --accent: ${accent}; }
  * { box-sizing: border-box; margin: 0; }
  body { font: 13px/1.55 Georgia, 'Times New Roman', serif; color: #1b1b1b; background: #fff;
         max-width: 860px; margin: 0 auto; padding: 24px; }
  h1 { font-size: 26px; line-height: 1.25; }
  h2 { font-size: 18px; color: var(--accent); border-bottom: 2px solid var(--accent);
       padding-bottom: 4px; margin: 0 0 12px; break-after: avoid; }
  h3 { font-size: 14px; margin: 14px 0 6px; break-after: avoid; }
  p { margin: 0 0 8px; }
  .sec { margin-top: 26px; }
  .sec.major { break-before: page; }
  table { width: 100%; border-collapse: collapse; margin: 8px 0 12px; font-family: Helvetica, Arial, sans-serif;
          font-size: 11.5px; page-break-inside: avoid; }
  th { background: var(--accent); color: #fff; text-align: left; padding: 5px 7px; font-weight: 600; }
  td { border: 1px solid #d8d8d8; padding: 5px 7px; vertical-align: top; }
  tr:nth-child(even) td { background: #f7f7f5; }
  .chip { display: inline-block; border: 1px solid; border-radius: 3px; padding: 0 5px;
          font: 600 10px/1.6 Helvetica, Arial, sans-serif; white-space: nowrap; }
  .st { font: 600 11px Helvetica, Arial, sans-serif; }
  .st.ok { color: #2f6b2f; } .st.warn { color: #a16207; } .st.bad { color: #b3261e; } .st.mut { color: #777; }
  .cover { min-height: 85vh; display: flex; flex-direction: column; justify-content: center; }
  .conf { display: inline-block; background: #b3261e; color: #fff; font: 600 11px/1 Helvetica, Arial, sans-serif;
          letter-spacing: 2px; padding: 6px 12px; border-radius: 3px; margin-bottom: 22px; align-self: flex-start; }
  .cover .sub { color: #555; font-size: 15px; margin: 8px 0 26px; }
  .cover .meta td:first-child { font-weight: 600; width: 32%; background: #f2f2ef; }
  .scorebox { display: flex; gap: 26px; align-items: center; border: 2px solid var(--accent);
              border-radius: 6px; padding: 14px 20px; margin: 10px 0 14px; }
  .scorebox .pct { font: 600 44px/1 Helvetica, Arial, sans-serif; }
  .scorebox .lab { font: 600 15px Helvetica, Arial, sans-serif; }
  .logo { max-height: 56px; max-width: 220px; margin-bottom: 18px; }
  .foot { color: #999; font: 10px Helvetica, Arial, sans-serif; text-align: right; margin-top: 30px; }
  ol.actions li { margin-bottom: 5px; }
  @page { size: A4; margin: 16mm 14mm; }
  @media print { body { padding: 0; max-width: none; } .cover { min-height: 92vh; } }
</style></head><body>
${parts.join('\n')}
<div class="foot">${esc(docRef)} · v${payload.meta.version} · CONFIDENTIAL</div>
</body></html>`;

  // ---- section renderers (closures over nothing; pure) ----
  function coverSection(p: ReportPayload): string {
    const rows = [
      ['Prepared for', esc(p.cover.org_name || p.cover.client_name)],
      ['Document reference', esc(docRef)],
      ['Version', `v${p.meta.version} — ${esc(p.meta.kind.replace(/_/g, ' '))}`],
      ['Date', esc(fmtDate(p.meta.compiled_at))],
      ['Prepared by', esc(p.cover.auditor_name || p.cover.practice_name || '—')],
    ];
    const history = p.cover.history.length
      ? `<h3>Document control</h3>` + table(
          ['Version', 'Type', 'Status', 'Issued'],
          p.cover.history.map(h => [
            `v${h.version}`, esc(h.kind.replace(/_/g, ' ')), esc(h.status), esc(fmtDate(h.issued_at)),
          ]))
      : '';
    return `<div class="cover">
      ${brand.logo ? `<img class="logo" src="${esc(brand.logo)}" alt=""/>` : ''}
      <span class="conf">CONFIDENTIAL</span>
      <h1>${esc(p.meta.framework.toUpperCase())} Compliance Assessment Report</h1>
      <div class="sub">${esc(p.cover.client_name)}${p.cover.audit_date ? ' · ' + esc(fmtDate(p.cover.audit_date)) : ''}</div>
      <table class="meta"><tbody>${rows.map(r => `<tr><td>${r[0]}</td><td>${r[1]}</td></tr>`).join('')}</tbody></table>
      ${history}
      <p style="margin-top:16px;color:#555;font-size:11.5px">This document contains information that is confidential
      and proprietary to ${esc(p.cover.org_name || p.cover.client_name)}. It shall not be disclosed, transmitted or
      duplicated without explicit written permission. This report reflects the state of the systems, documents and
      personnel assessed at the time of the assessment and does not constitute legal advice.</p>
    </div>`;
  }

  function execSummary(p: ReportPayload, n: (k: string) => string | null): string {
    const s = p.summary;
    const dash = table(
      ['Assessment domain', 'Score', 'Open critical', 'Worst open risk'],
      s.dashboard.map(d => [
        esc(d.section_name), d.pct != null ? `${d.pct}%` : '—', String(d.open_critical), sevChip(d.worst),
      ]));
    const actions = s.top_actions.length
      ? `<h3>Top priority actions</h3><ol class="actions">${s.top_actions.map(a => `<li>${esc(a)}</li>`).join('')}</ol>`
      : '';
    const baseline = s.baseline
      ? `<p>Stage 1 baseline: <b>${s.baseline.pct ?? '—'}%</b> (${esc(fmtDate(s.baseline.at))}).` +
        (s.prior ? ` Previous report (v${s.prior.version}): <b>${s.prior.overall_pct ?? '—'}%</b>.` : '') + `</p>`
      : '';
    return `${para(n('exec_summary'))}
      <div class="scorebox"><div class="pct">${s.overall_pct ?? '—'}%</div>
        <div><div class="lab">${esc(s.maturity_label)}</div>
        <div>${s.counts.non_compliant} of ${s.counts.total} controls Non-Compliant · ${s.critical_count} Critical findings · assessment ${s.completion_pct ?? '—'}% complete</div></div>
      </div>
      ${baseline}<h3>Assessment dashboard</h3>${dash}${actions}`;
  }

  function domainsSection(p: ReportPayload, n: (k: string) => string | null): string {
    return p.domains.map(d => {
      const hasIso = d.rows.some(r => r.ref_b);
      const heads = hasIso
        ? ['Ref', 'Control area', 'Reference', 'ISO 27701', 'Status', 'Risk']
        : ['Ref', 'Control area', 'Reference', 'Status', 'Risk'];
      const rows = d.rows.map(r => {
        const base = [r.ref, esc(r.control_area ?? '—') + `<br/><span style="color:#666">${esc(r.question)}</span>`, esc(r.ref_a)];
        if (hasIso) base.push(esc(r.ref_b ?? '—'));
        return [...base, statusCell(r.status), sevChip(r.risk)];
      });
      const obs = n(`domain_obs:${d.section_id}`);
      return `<h3>${esc(d.section_name)}${d.pct != null ? ` — ${d.pct}%` : ''}</h3>
        ${table(heads, rows)}${obs ? `<p><b>Key observations.</b> ${esc(obs)}</p>` : ''}`;
    }).join('');
  }

  function awarenessSection(p: ReportPayload): string | null {
    const a = p.awareness as AwarenessData | null;
    if (!a?.overall) return null;
    const cov = a.coverage;
    const lim = cov?.limitation
      ? `<p><i>Coverage limitation: ${cov.cohorts_completed ?? 0} of ${cov.departments_planned ?? 'an unconfirmed number of'} departmental cohorts have been interviewed to date. These findings should be treated as indicative of organisation-wide risk rather than conclusive.</i></p>`
      : '';
    const domains = a.domains?.length
      ? table(['Domain', 'Answered', '% aligned', 'Risk'],
          a.domains.map(d => [esc(d.name), String(d.answered), d.pct != null ? `${d.pct}%` : '—', sevChip((d.rating ?? '').replace(/^./, c => c.toUpperCase()) as Severity)]))
      : '';
    const hr = a.high_risk_questions?.length
      ? `<h3>High-risk behaviours</h3>` + table(['Code', 'Behaviour', 'Aligned'],
          a.high_risk_questions.map(q => [esc(q.code), esc(q.question), `${q.aligned}/${q.answered} (${q.pct ?? 0}%)`]))
      : '';
    const resp = (a.cohorts ?? []).map(c =>
      `<h3>Cohort: ${esc(c.department)}${c.interviewed_on ? ` (${esc(fmtDate(c.interviewed_on))})` : ''}</h3>` +
      table(['Respondent', 'Answered', '% aligned', 'Rating'],
        (c.respondents ?? []).map(r => [`Respondent ${r.respondent_no}`, String(r.answered), `${r.pct}%`, esc(r.rating)]))
    ).join('');
    return `<p>Overall alignment: <b>${a.overall.pct ?? '—'}%</b> across ${a.overall.respondents ?? '—'} respondents (${esc(a.overall.rating ?? '—')} risk).</p>
      ${lim}${domains}${hr}${resp}`;
  }

  function riskRegisterSection(p: ReportPayload): string | null {
    if (!p.risk_register.length) return null;
    return table(['#', 'Finding', 'Ref', 'Risk', 'Recommended action', 'Target'],
      p.risk_register.map((f, i) => [
        String(i + 1), esc(f.finding), f.ref, sevChip(f.severity),
        esc(f.recommended_action ?? '—'), esc(f.target_window),
      ]));
  }

  function roadmapSection(p: ReportPayload): string | null {
    if (!p.roadmap.length) return null;
    return p.roadmap.map(ph =>
      `<h3>${esc(ph.window)}</h3><ul>${ph.items.map(i =>
        `<li>${sevChip(i.severity)} <b>${i.ref}</b> — ${esc(i.action)}</li>`).join('')}</ul>`
    ).join('');
  }

  function documentationSection(p: ReportPayload): string | null {
    const d = p.documentation_issued;
    if (!d) return null;
    const rows = d.rows.length
      ? table(['Document', 'Type', 'Issued'], d.rows.map(r => [esc(r.title), esc(r.source), esc(fmtDate(r.issued_at))]))
      : '<p><i>No documents have been issued from the platform yet.</i></p>';
    return `<p>${d.slots_filled} of ${d.slots_required} required checklist slots are filled with confirmed documents.</p>${rows}`;
  }

  function classificationSection(p: ReportPayload, n: (k: string) => string | null): string | null {
    const reg = mergedRegister;
    if (!reg?.length) return null;
    const counts: Record<string, number> = { A: 0, B: 0, C: 0, D: 0 };
    reg.forEach(r => { counts[r.cls] += 1; });
    const legend = table(['Class', 'Meaning', 'Items'], [
      ['A', 'Closed by documentation — nothing further beyond formal approval.', String(counts.A)],
      ['B', 'Documented — implementation required; the control is not yet operating.', String(counts.B)],
      ['C', 'Implementation only — no document closes it.', String(counts.C)],
      ['D', 'Further documentation and implementation both required.', String(counts.D)],
    ]);
    return `${para(n('classification_register'))}${legend}` + table(
      ['Ref', 'Control area', 'Class', 'Risk', 'Evidence required to close', 'Owner'],
      reg.map(r => [
        r.ref, esc(r.control_area ?? '—'),
        `<b>${r.cls}</b>${r.cls_source === 'proposed' ? '<span style="color:#999">*</span>' : ''}`,
        sevChip(r.severity), esc(r.evidence_required ?? '—'), esc(r.owner ?? '—'),
      ])) + `<p style="color:#777;font-size:11px">* proposed classification — pending advisor confirmation.</p>`;
  }

  function residualSection(p: ReportPayload): string | null {
    const rr = mergedResidual;
    if (!rr?.length) return null;
    return `<p>Until the programme is delivered, the following exposures remain live (classes B, C and D — a written control is not an operating one).</p>` +
      table(['Ref', 'Exposure', 'Class', 'Risk', 'Closed by'],
        rr.map(r => [r.ref, esc(r.control_area ?? '—'), r.cls, sevChip(r.severity), esc(r.evidence_required ?? '—')]));
  }

  function alignmentSection(p: ReportPayload): string | null {
    const at = p.spec.alignment_table;
    if (!at?.length) return null;
    return table(['Condition', 'Reference', 'ISO/IEC 27701 clause', ''],
      at.map(r => [esc(r.condition), esc(r.reference), esc(r.iso_clause), esc(r.iso_title)]));
  }

  function deliverySection(p: ReportPayload): string | null {
    const opts = p.spec.delivery_options;
    if (!opts?.length) return null;
    return table(['Route', 'Scope it can carry', 'Strength', 'Limitation'],
      opts.map(o => [esc(o.route), esc(o.scope), esc(o.strength), esc(o.limitation)]));
  }

  function scopeSection(p: ReportPayload, n: (k: string) => string | null): string {
    const rs = p.spec.rating_scale;
    const legend = rs
      ? `<h3>Rating scale</h3>` +
        table(['Status', 'Definition'], rs.statuses.map(s => [esc(s.label), esc(s.definition)])) +
        table(['Risk priority', 'Definition'], rs.risks.map(r => [esc(r.key), esc(r.definition)]))
      : '';
    return `${para(n('scope_methodology'))}${legend}`;
  }

  function appendicesSection(p: ReportPayload): string {
    const docs = p.appendices.documents_reviewed.length
      ? `<h3>Appendix A: Documents reviewed</h3>` +
        table(['Document', 'Uploaded'], p.appendices.documents_reviewed.map(d => [esc(d.filename), esc(fmtDate(d.uploaded_at))]))
      : '';
    const legend = Array.isArray(p.appendices.framework_legend)
      ? `<h3>Appendix B: Standards referenced</h3>` +
        table(['Framework', 'Applicability', ''],
          (p.appendices.framework_legend as { framework?: string; applicability?: string; description?: string }[])
            .map(l => [esc(l.framework), esc(l.applicability), esc(l.description)]))
      : '';
    return docs + legend || '<p><i>No appendices.</i></p>';
  }
}
