import type {
  ClassRegisterRow, ControlStatus, DomainRow, DomainSection, Finding,
  RegisterClass, ReportOverrides, ReportPayload, ReportSpec, Severity,
} from './types';
import { maturityFor, severityFor, SEVERITY_ORDER } from './spec';

// Raw rows as the compile route selects them (flat PostgREST selects, JS joins — house style).
export interface QuestionRow {
  id: string; uid: string; section_id: number; section_name: string;
  subsection: string | null; question_number: number; question: string;
  regulatory_ref: string | null; risk: string; evidence_req: string | null;
  remediation: string | null;
}
export interface ResponseRow {
  question_id: string; response: string; findings: string | null;
  responsible_party: string | null; target_date: string | null;
}
export interface CompileInputs {
  spec: ReportSpec;
  kind: string; version: number; framework: string;
  clientName: string; practiceName: string | null;
  session: {
    org_name: string | null; auditor_name: string | null;
    audit_date: string | null; audit_ref: string | null;
  };
  score: {
    overall?: { pct?: number; rating?: string };
    completion_pct?: number;
    section_scores?: Record<string, { section_name?: string; pct?: number }>;
  } | null;
  questions: QuestionRow[];
  responses: ResponseRow[];
  track: { baseline_pct: number | null; baseline_rating: string | null; baseline_at: string | null } | null;
  chain: { version: number; kind: string; title: string; approval_status: string; issued_at: string | null; payload?: { summary?: { overall_pct?: number | null } } | null }[];
  issuedDocs: { original_filename: string; source: string; created_at: string | null }[];
  checklist: { id: string; required: boolean }[];
  confirmedChecklistIds: Set<string>;
  uploads: { original_filename: string; created_at: string | null }[];
  frameworkLegend: unknown | null;
  awareness: unknown | null;
}

const splitRef = (ref: string | null): { a: string; b: string | null } => {
  if (!ref) return { a: '—', b: null };
  const i = ref.indexOf('|');
  if (i < 0) return { a: ref.trim(), b: null };
  return { a: ref.slice(0, i).trim(), b: ref.slice(i + 1).trim() };
};

const displayRef = (q: QuestionRow) =>
  `S${q.section_id}.${String(q.question_number).padStart(2, '0')}`;

const interpolate = (tpl: string, vars: Record<string, string | number | null>) =>
  tpl.replace(/\{\{(\w+)\}\}/g, (_, k) => String(vars[k] ?? '—'));

// ponytail: keyword heuristic — the A–D class is only a proposal; the advisor's override in
// the workbench is the decision. Upgrade path: map questions to checklist slots in content.
function proposeClass(row: DomainRow, hasIssuedDocs: boolean): RegisterClass {
  const txt = `${row.evidence_req ?? ''} ${row.remediation ?? ''}`.toLowerCase();
  const operational = /\b(log|register|record|test|train|audit|review|monitor|backup|encrypt|mfa|access|patch|configur|technical)\w*/.test(txt);
  const documentary = /\b(policy|policies|notice|procedure|manual|agreement|contract|clause|document)\w*/.test(txt);
  if (documentary && !operational) return hasIssuedDocs ? 'A' : 'D';
  if (documentary && operational) return hasIssuedDocs ? 'B' : 'D';
  if (operational) return 'C';
  return 'D';
}

export function buildReportPayload(inputs: CompileInputs, overrides: ReportOverrides): ReportPayload {
  const { spec } = inputs;
  const respByQ = new Map(inputs.responses.map(r => [r.question_id, r]));
  const isV2 = inputs.version >= 2 || inputs.kind !== 'gap_assessment';

  // ---- per-question joined rows ----
  const rows: DomainRow[] = inputs.questions
    .sort((a, b) => a.section_id - b.section_id || a.question_number - b.question_number)
    .map(q => {
      const r = respByQ.get(q.id);
      const status = (r?.response ?? 'not_assessed') as ControlStatus;
      const { a, b } = splitRef(q.regulatory_ref);
      return {
        uid: q.uid, ref: displayRef(q), control_area: q.subsection, question: q.question,
        ref_a: a, ref_b: b, status, risk: (q.risk as Severity) ?? 'Low',
        severity: severityFor(spec, q.risk, status),
        findings: r?.findings ?? null, evidence_req: q.evidence_req,
        remediation: q.remediation, owner: r?.responsible_party ?? null,
        target_date: r?.target_date ?? null,
      };
    });

  const countStatuses = (rs: DomainRow[]) => {
    const c: Record<ControlStatus, number> = { fully_compliant: 0, partial: 0, non_compliant: 0, na: 0, not_assessed: 0 };
    rs.forEach(r => { c[r.status] += 1; });
    return c;
  };

  // ---- domains ----
  const sectionIds = [...new Set(rows.map(r => Number(r.ref.slice(1).split('.')[0])))];
  const byUidSection = new Map(inputs.questions.map(q => [q.uid, q]));
  const domains: DomainSection[] = sectionIds.map(sid => {
    const dRows = rows.filter(r => byUidSection.get(r.uid)!.section_id === sid);
    const name = byUidSection.get(dRows[0].uid)!.section_name;
    const pct = inputs.score?.section_scores?.[`S${sid}`]?.pct ?? null;
    return { section_id: sid, section_name: name, pct, counts: countStatuses(dRows), rows: dRows };
  });

  // ---- summary ----
  const counts = countStatuses(rows);
  const open = rows.filter(r => r.severity != null);
  const criticalFindings = open.filter(r => r.severity === 'Critical');
  const overallPct = inputs.score?.overall?.pct ?? null;
  const maturity = maturityFor(spec, overallPct);
  const priorIssued = inputs.chain.filter(c => ['issued', 'superseded'].includes(c.approval_status))
    .sort((a, b) => b.version - a.version)[0] ?? null;

  const worstFor = (sid: number): Severity | null => {
    const sev = open.filter(r => byUidSection.get(r.uid)!.section_id === sid).map(r => r.severity!);
    return SEVERITY_ORDER.find(s => sev.includes(s)) ?? null;
  };

  const topActions = overrides.top_actions ?? criticalFindings
    .filter(r => r.remediation).slice(0, 6).map(r => r.remediation!);

  // ---- risk register: all Criticals + top 10 Highs ----
  const toFinding = (r: DomainRow): Finding => ({
    uid: r.uid, ref: r.ref, control_area: r.control_area,
    finding: r.findings || r.question, severity: r.severity!,
    recommended_action: r.remediation, owner: r.owner,
    target_window: spec.target_windows[r.severity!] ?? '—',
  });
  const riskRegister = [
    ...criticalFindings.map(toFinding),
    ...open.filter(r => r.severity === 'High').slice(0, 10).map(toFinding),
  ];

  // ---- roadmap: open findings grouped by target window, window order preserved ----
  const windows = [...new Set(SEVERITY_ORDER.map(s => spec.target_windows[s]))];
  const roadmap = windows.map(w => ({
    window: w,
    items: open.filter(r => spec.target_windows[r.severity!] === w && r.remediation)
      .map(r => ({ ref: r.ref, action: r.remediation!, severity: r.severity! })),
  })).filter(p => p.items.length);

  // ---- v2 sections ----
  const hasIssuedDocs = inputs.issuedDocs.length > 0;
  let classificationRegister: ClassRegisterRow[] | null = null;
  let residualRisk: ClassRegisterRow[] | null = null;
  let documentationIssued: ReportPayload['documentation_issued'] = null;
  if (isV2) {
    classificationRegister = open.map(r => {
      const ov = overrides.classification?.[r.uid];
      return {
        uid: r.uid, ref: r.ref, control_area: r.control_area, severity: r.severity!,
        cls: ov?.cls ?? proposeClass(r, hasIssuedDocs),
        cls_source: ov ? 'advisor' : 'proposed',
        evidence_required: ov?.evidence_required ?? r.evidence_req,
        owner: ov?.owner ?? r.owner,
        workstream: byUidSection.get(r.uid)!.section_name,
      } as ClassRegisterRow;
    });
    residualRisk = classificationRegister.filter(r => r.cls !== 'A');
    const required = inputs.checklist.filter(c => c.required);
    documentationIssued = {
      rows: inputs.issuedDocs.map(d => ({ title: d.original_filename, source: d.source, issued_at: d.created_at })),
      slots_required: required.length,
      slots_filled: required.filter(c => inputs.confirmedChecklistIds.has(c.id)).length,
    };
  }

  // ---- narratives ----
  const vars = {
    org_name: inputs.session.org_name || inputs.clientName,
    auditor_name: inputs.session.auditor_name,
    audit_date: inputs.session.audit_date,
    overall_pct: overallPct, maturity_label: maturity.label,
    question_total: rows.length,
    fully_compliant_count: counts.fully_compliant, partial_count: counts.partial,
    non_compliant_count: counts.non_compliant, not_assessed_count: counts.not_assessed,
    critical_count: criticalFindings.length,
  };
  const sections: ReportPayload['sections'] = {};
  const order = spec.sections.filter(s => !s.min_version || isV2);
  order.forEach(s => {
    const tpl = spec.narrative_templates[s.key];
    sections[s.key] = { title: s.title, narrative_default: tpl ? interpolate(tpl, vars) : null };
  });

  return {
    meta: { framework: inputs.framework, kind: inputs.kind, version: inputs.version, compiled_at: new Date().toISOString() },
    cover: {
      client_name: inputs.clientName, org_name: inputs.session.org_name,
      auditor_name: inputs.session.auditor_name, audit_date: inputs.session.audit_date,
      audit_ref: inputs.session.audit_ref, practice_name: inputs.practiceName,
      history: inputs.chain
        .sort((a, b) => a.version - b.version)
        .map(c => ({ version: c.version, kind: c.kind, title: c.title, status: c.approval_status, issued_at: c.issued_at })),
    },
    summary: {
      overall_pct: overallPct, overall_rating: inputs.score?.overall?.rating ?? null,
      completion_pct: inputs.score?.completion_pct ?? null,
      maturity_label: maturity.label, maturity_tone: maturity.tone,
      counts: { ...counts, total: rows.length },
      critical_count: criticalFindings.length,
      baseline: inputs.track?.baseline_at
        ? { pct: inputs.track.baseline_pct, rating: inputs.track.baseline_rating, at: inputs.track.baseline_at }
        : null,
      prior: priorIssued ? { version: priorIssued.version, overall_pct: priorIssued.payload?.summary?.overall_pct ?? null } : null,
      dashboard: domains.map(d => ({
        section_id: d.section_id, section_name: d.section_name, pct: d.pct,
        open_critical: d.rows.filter(r => r.severity === 'Critical').length,
        worst: worstFor(d.section_id),
      })),
      top_actions: topActions,
    },
    domains,
    awareness: inputs.awareness,
    risk_register: riskRegister,
    roadmap,
    documentation_issued: documentationIssued,
    classification_register: classificationRegister,
    residual_risk: residualRisk,
    appendices: {
      documents_reviewed: inputs.uploads.map(u => ({ filename: u.original_filename, uploaded_at: u.created_at })),
      framework_legend: inputs.frameworkLegend,
    },
    sections,
    section_order: order,
    spec: {
      rating_scale: spec.rating_scale,
      alignment_table: spec.alignment_table,
      delivery_options: spec.delivery_options,
    },
  };
}
