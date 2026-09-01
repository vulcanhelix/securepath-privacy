import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { buildReportPayload } from './compile';
import { renderReportHtml } from './render';
import type { CompileInputs } from './compile';
import type { RegisterClass, ReportOverrides, ReportSpec, Severity } from './types';

type Fixture = {
  inputs: Omit<CompileInputs, 'spec' | 'confirmedChecklistIds'> & { confirmedChecklistIds: string[] };
  overrides: ReportOverrides;
  report_spec: ReportSpec;
  expected: {
    control_total: number;
    status_counts: Record<string, number>;
    status_percentages: Record<string, number>;
    domain_totals: number[];
    risk_counts: Record<Severity, number>;
    risk_register_rows: number;
    awareness: {
      respondents: number;
      questions: number;
      pct: number;
      domains: number;
      high_risk_behaviours: number;
    };
    class_counts: Record<RegisterClass, number>;
    workstreams: number;
    residual_exposures: number;
    document_suites: number;
    outstanding_documents: number;
    reviewed_documents: number;
    section_keys: string[];
  };
};

const fixture = JSON.parse(
  readFileSync(new URL('./fixtures/puris-source.json', import.meta.url), 'utf8'),
) as Fixture;
const inputs: CompileInputs = {
  ...fixture.inputs,
  spec: fixture.report_spec,
  confirmedChecklistIds: new Set(fixture.inputs.confirmedChecklistIds),
};
const payload = buildReportPayload(inputs, fixture.overrides);

test('Puris source control population, status distribution and risk population are exact', () => {
  assert.equal(payload.summary.counts.total, fixture.expected.control_total);
  for (const [status, count] of Object.entries(fixture.expected.status_counts)) {
    assert.equal(payload.summary.counts[status as keyof typeof payload.summary.counts], count);
  }
  for (const [status, percentage] of Object.entries(fixture.expected.status_percentages)) {
    const count = payload.summary.counts[status as keyof typeof payload.summary.counts];
    assert.equal(Math.round((count / payload.summary.counts.total) * 1000) / 10, percentage);
  }
  assert.deepEqual(payload.domains.map(domain => domain.rows.length), fixture.expected.domain_totals);
  assert.deepEqual(payload.summary.risk_counts, fixture.expected.risk_counts);
  assert.equal(payload.summary.maturity_label, 'Initial / Ad Hoc (Red)');
});

test('Puris risk, awareness, remediation and programme registers retain source shape', () => {
  assert.equal(payload.risk_register.length, fixture.expected.risk_register_rows);
  assert.ok(payload.risk_register.some(finding => finding.source_type === 'awareness'));

  const awareness = payload.awareness as {
    overall: { respondents: number; pct: number };
    domains: { questions: number }[];
    high_risk_questions: unknown[];
  };
  assert.equal(awareness.overall.respondents, fixture.expected.awareness.respondents);
  assert.equal(awareness.overall.pct, fixture.expected.awareness.pct);
  assert.equal(awareness.domains.length, fixture.expected.awareness.domains);
  assert.equal(
    awareness.domains.reduce((total, domain) => total + domain.questions, 0),
    fixture.expected.awareness.questions,
  );
  assert.equal(awareness.high_risk_questions.length, fixture.expected.awareness.high_risk_behaviours);

  const register = payload.classification_register ?? [];
  const classCounts: Record<RegisterClass, number> = { A: 0, B: 0, C: 0, D: 0 };
  register.forEach(row => { classCounts[row.cls] += 1; });
  assert.deepEqual(classCounts, fixture.expected.class_counts);
  assert.equal(register.length, 30);
  assert.equal(register.filter(row => row.cls !== 'A').length, 29);
  assert.equal(payload.quality.proposed_classifications, 0);
  assert.equal(payload.quality.ready, true);

  assert.equal(payload.implementation_programme?.length, fixture.expected.workstreams);
  assert.ok(payload.implementation_programme?.every(workstream => workstream.actions.length > 0));
  assert.ok(payload.implementation_programme?.every(workstream => workstream.dependencies));
  assert.equal(payload.residual_risk?.length, fixture.expected.residual_exposures);
  assert.equal(payload.documentation_issued?.suites.length, fixture.expected.document_suites);
  assert.equal(payload.documentation_issued?.open_remediation_items, 29);
  assert.match(payload.documentation_issued?.suites.at(-1)?.documents ?? '', /^23 controlled documents/);
  assert.equal(payload.outstanding_documents?.length, fixture.expected.outstanding_documents);
  assert.equal(payload.appendices.documents_reviewed.length, fixture.expected.reviewed_documents);
  assert.equal(payload.appendices.awareness_respondents.length, fixture.expected.awareness.respondents);
});

test('Puris HTML is deterministic, escaped, self-contained and ordered like the source report', () => {
  const brand = { practiceName: 'Section Five (Pty) Ltd', accentHex: '#1f3a5f', logo: null };
  const html = renderReportHtml(payload, fixture.overrides, brand);
  assert.equal(renderReportHtml(payload, fixture.overrides, brand), html);

  const escaped = renderReportHtml(
    payload,
    { ...fixture.overrides, narratives: { exec_summary: '<script>alert("x")</script>' } },
    brand,
  );
  assert.ok(escaped.includes('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;'));
  assert.ok(!escaped.includes('<script>alert'));

  assert.ok(!/<(?:script|link|iframe)\b/i.test(html));
  assert.ok(!/\b(?:src|href)=["']https?:\/\//i.test(html));
  assert.ok(!/@import\s|url\(\s*["']?https?:\/\//i.test(html));
  assert.ok(html.includes('21 Non-Compliant (58.3%)'));
  assert.ok(html.includes('5 Under Review (13.9%)'));
  assert.ok(html.includes('16 Critical · 17 High'));

  assert.deepEqual(payload.section_order.map(section => section.key), fixture.expected.section_keys);
  let previous = -1;
  for (const section of payload.section_order.filter(section => section.key !== 'cover')) {
    const escapedTitle = section.title.replaceAll('&', '&amp;');
    const position = html.indexOf(`<h2>${escapedTitle}</h2>`);
    assert.ok(position > previous, `${section.title} must render in declared order`);
    previous = position;
  }
  assert.ok(html.includes('Appendix A: Documents reviewed'));
  assert.ok(html.includes('Appendix B: Awareness respondents'));
  assert.ok(html.includes('R30'));
});
