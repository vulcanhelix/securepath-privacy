// Smallest runnable check for the report pipeline: fixture -> payload -> HTML.
// Run: npx tsx web/lib/report/smoke.test.mts   (no framework — plain asserts)
import assert from 'node:assert';
import { buildReportPayload } from './compile';
import { renderReportHtml } from './render';
import { DEFAULT_REPORT_SPEC, resolveSpec } from './spec';
import { validateReportOverrides } from './validate';

const q = (n: number, section: number, risk: string, extra: Partial<Record<string, unknown>> = {}) => ({
  id: `q${section}-${n}`, uid: `t.s${section}.q${String(n).padStart(2, '0')}`,
  section_id: section, section_name: `Domain ${section}`, subsection: `Area ${section}.${n}`,
  question_number: n, question: `Control question ${section}.${n}`,
  regulatory_ref: 'POPIA s.19 | ISO 27701 7.2.8', risk,
  evidence_req: 'Approved policy and access control list', remediation: `Fix control ${section}.${n}`,
  ...extra,
});

const inputs = {
  spec: resolveSpec(null),
  kind: 'post_documentation', version: 2, framework: 'popia',
  clientName: 'Acme (Pty) Ltd', practiceName: 'Test Practice',
  session: { org_name: 'Acme (Pty) Ltd', auditor_name: 'W. Despard', audit_date: '2026-08-16', audit_ref: 'ACME-001' },
  score: {
    overall: { pct: 42, rating: 'significant_gaps' }, completion_pct: 80,
    section_scores: { S1: { section_name: 'Domain 1', pct: 50 }, S2: { section_name: 'Domain 2', pct: 30 } },
  },
  questions: [
    q(1, 1, 'Critical'), q(2, 1, 'High'), q(3, 1, 'Low'),
    q(1, 2, 'Critical'), q(2, 2, 'Medium'),
  ],
  responses: [
    { question_id: 'q1-1', response: 'non_compliant', findings: 'No PIMS in place', responsible_party: 'DIO', target_date: null },
    { question_id: 'q1-2', response: 'partial', findings: null, responsible_party: null, target_date: null },
    { question_id: 'q1-3', response: 'fully_compliant', findings: null, responsible_party: null, target_date: null },
    { question_id: 'q2-1', response: 'na', findings: null, responsible_party: null, target_date: null },
    // q2-2 unanswered -> not_assessed
  ],
  track: { baseline_pct: 42, baseline_rating: 'significant_gaps', baseline_at: '2026-08-16T00:00:00Z' },
  chain: [{ version: 1, kind: 'gap_assessment', title: 'v1', approval_status: 'issued', issued_at: '2026-08-17', payload: { summary: { overall_pct: 40 } } }],
  issuedDocs: [{ original_filename: 'Privacy Policy.md', source: 'policy', created_at: '2026-08-20' }],
  checklist: [{ id: 'c1', required: true }, { id: 'c2', required: true }, { id: 'c3', required: false }],
  confirmedChecklistIds: new Set(['c1']),
  uploads: [{ original_filename: 'Employee Handbook.pdf', created_at: '2026-08-10' }],
  frameworkLegend: [{ framework: 'POPIA', applicability: 'Mandatory', description: 'SA privacy law' }],
  awareness: null,
};

const payload = buildReportPayload(inputs as never, {});

// counts: 1 nc, 1 partial, 1 fc, 1 na, 1 not_assessed
assert.deepEqual(
  { ...payload.summary.counts },
  {
    fully_compliant: 1,
    partial: 1,
    under_review: 0,
    non_compliant: 1,
    na: 1,
    not_assessed: 1,
    total: 5,
  });
// severity matrix: Critical x non_compliant = Critical finding; Critical x na = closed
assert.equal(payload.summary.critical_count, 1);
assert.equal(payload.domains.length, 2);
// maturity band for 42%
assert.equal(payload.summary.maturity_label, 'Repeatable but Reactive (Orange)');
// risk register leads with the Critical finding, carrying its findings text
assert.equal(payload.risk_register[0].severity, 'Critical');
assert.equal(payload.risk_register[0].finding, 'No PIMS in place');
assert.equal(payload.risk_register[0].target_window, '0–30 days');
// v2 sections materialise
assert.ok(payload.classification_register && payload.classification_register.length === 3); // nc, partial, not_assessed
assert.equal(payload.documentation_issued?.slots_required, 2);
assert.equal(payload.documentation_issued?.slots_filled, 1);
// prior version movement
assert.equal(payload.summary.prior?.overall_pct, 40);
// regulatory_ref split
assert.equal(payload.domains[0].rows[0].ref_a, 'POPIA s.19');
assert.equal(payload.domains[0].rows[0].ref_b, 'ISO 27701 7.2.8');

// advisor override wins over the A-D proposal and is marked as the decision
const p2 = buildReportPayload(inputs as never, {
  classification: { 't.s1.q01': { cls: 'C', owner: 'IT' } },
  narratives: { exec_summary: 'ADVISOR SUMMARY' },
  sections_excluded: ['delivery_options'],
});
const row = p2.classification_register!.find(r => r.uid === 't.s1.q01')!;
assert.equal(row.cls, 'C');
assert.equal(row.cls_source, 'advisor');
assert.equal(row.owner, 'IT');

// render: deterministic, escaped, sections present/excluded as configured
const brand = { practiceName: 'Test Practice', accentHex: '#123456', logo: null };
const html1 = renderReportHtml(p2, { narratives: { exec_summary: 'ADVISOR <b>SUMMARY</b>' } }, brand);
const html2 = renderReportHtml(p2, { narratives: { exec_summary: 'ADVISOR <b>SUMMARY</b>' } }, brand);
assert.equal(html1, html2, 'renderer must be deterministic');
assert.ok(html1.includes('ADVISOR &lt;b&gt;SUMMARY&lt;/b&gt;'), 'narrative override must render escaped');
assert.ok(html1.includes('CONFIDENTIAL'));
assert.ok(html1.includes('Consolidated Risk Register'));
assert.ok(html1.includes('What Documentation Cannot Close'));
assert.ok(html1.includes('Inherent risk across all 5 in-scope controls:'));
assert.ok(!html1.includes('id="delivery'), 'no stray markup');
assert.ok(html1.includes('--accent: #123456'));
// Declared sections remain visible even when evidence is absent.
assert.ok(html1.includes('Awareness — People Risk</h2>'));
assert.ok(html1.includes('No evidence or advisor content was recorded for this section.'));
// classification overrides saved AFTER the last compile still render (payload holds the
// proposal, overrides carry the decision — preview and issue must show the decision)
const p3 = buildReportPayload(inputs as never, {});
assert.notEqual(p3.classification_register!.find(r => r.uid === 't.s1.q01')!.cls, 'D');
const staleHtml = renderReportHtml(p3, { classification: { 't.s1.q01': { cls: 'D', owner: 'CEO' } } }, brand);
assert.ok(staleHtml.includes('<b>D</b>'), 'post-compile class override must render in the register');
assert.ok(staleHtml.includes('CEO'), 'post-compile owner override must render');
// generic spec renders for a pack with no report_spec (CE degradation path)
const ceP = buildReportPayload({ ...inputs, spec: DEFAULT_REPORT_SPEC, framework: 'cyber_essentials', kind: 'gap_assessment', version: 1 } as never, {});
const ceHtml = renderReportHtml(ceP, {}, brand);
assert.ok(ceHtml.includes('Executive Summary'));
assert.ok(!ceHtml.includes('What Documentation Cannot Close'), 'v1 must not include v2 sections');

const programmePayload = buildReportPayload({
  ...inputs,
  spec: {
    ...DEFAULT_REPORT_SPEC,
    implementation_workstreams: [{
      number: 2,
      title: 'Records foundation',
      themes: ['registers', 'records'],
      default_window: '30–90 days',
      default_owner: 'Outsourced DIO with IT',
      description: 'Build accountable records of processing and assets.',
    }],
  },
  tasks: [{
    theme: '2. Data Mapping & Asset Register',
    title: 'For each asset record, document owner, data type, location and access rights',
    description: 'Build the Information Asset Register and classify personal information.',
    responsible: 'IT',
    output: 'Completed Asset Register',
    priority: 'high',
    owner: null,
    due_date: null,
    status: 'todo',
  }],
} as never, {});
assert.deepEqual(
  programmePayload.implementation_programme?.[0].actions,
  ['For each asset record, document owner, data type, location and access rights'],
);

assert.throws(
  () => validateReportOverrides({ structured: { company_profile: { legal_name: 42 } } }),
  /company_profile\.legal_name must be a string/,
);
assert.throws(
  () => validateReportOverrides({
    risk_register: [{
      uid: 'bad',
      ref: '1.1',
      control_area: null,
      finding: 'Malformed severity',
      severity: 'Urgent',
      recommended_action: null,
      owner: null,
      target_window: '0–30 days',
      source_type: 'assessment',
    }],
  }),
  /unsupported value/,
);

console.log('report smoke: all assertions passed');
