import type {
  ClassRegisterRow, ControlStatus, DomainRow, DomainSection, Finding,
  ImplementationWorkstream, RegisterClass, ReportOverrides, ReportPayload,
  ReportSpec, ResidualExposure, Severity, StructuredReportData,
} from './types';
import { maturityFor, severityFor, SEVERITY_ORDER } from './spec';

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
  clientName: string; registrationNumber?: string | null; industry?: string | null;
  contactName?: string | null; practiceName: string | null;
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
  chain: {
    version: number; kind: string; title: string; approval_status: string;
    issued_at: string | null; payload?: { summary?: { overall_pct?: number | null } } | null;
  }[];
  issuedDocs: { original_filename: string; source: string; created_at: string | null }[];
  checklist: { id: string; required: boolean }[];
  confirmedChecklistIds: Set<string>;
  uploads: { original_filename: string; created_at: string | null }[];
  tasks?: {
    theme: string; title: string; description: string | null; responsible: string | null;
    output: string | null; priority: string; owner: string | null; due_date: string | null; status: string;
  }[];
  frameworkLegend: unknown | null;
  awareness: unknown | null;
}

type AwarenessData = {
  high_risk_questions?: { code: string; question: string; pct: number | null; answered: number; aligned: number }[];
  cohorts?: {
    respondents?: { respondent_no: number; answered: number; pct: number; rating: string }[];
  }[];
};

const splitRef = (ref: string | null): { a: string; b: string | null } => {
  if (!ref) return { a: '—', b: null };
  const i = ref.indexOf('|');
  if (i < 0) return { a: ref.trim(), b: null };
  return { a: ref.slice(0, i).trim(), b: ref.slice(i + 1).trim() };
};

const displayRef = (question: QuestionRow) => `${question.section_id}.${question.question_number}`;

const interpolate = (template: string, vars: Record<string, string | number | null>) =>
  template.replace(/\{\{(\w+)\}\}/g, (_, key) => String(vars[key] ?? '—'));

function proposeClass(row: DomainRow, hasIssuedDocs: boolean): RegisterClass {
  const text = `${row.evidence_req ?? ''} ${row.remediation ?? ''}`.toLowerCase();
  const operational = /\b(log|register|record|test|train|audit|review|monitor|backup|encrypt|mfa|access|patch|configur|technical)\w*/.test(text);
  const documentary = /\b(policy|policies|notice|procedure|manual|agreement|contract|clause|document)\w*/.test(text);
  if (documentary && !operational) return hasIssuedDocs ? 'A' : 'D';
  if (documentary && operational) return hasIssuedDocs ? 'B' : 'D';
  if (operational) return 'C';
  return 'D';
}

const emptyCounts = (): Record<ControlStatus, number> => ({
  fully_compliant: 0,
  partial: 0,
  under_review: 0,
  non_compliant: 0,
  na: 0,
  not_assessed: 0,
});

const countStatuses = (rows: DomainRow[]) => {
  const counts = emptyCounts();
  rows.forEach(row => { counts[row.status] += 1; });
  return counts;
};

const scoreRows = (rows: DomainRow[]): number | null => {
  const scorable = rows.filter(row => row.status !== 'na');
  if (!scorable.length) return null;
  const achieved = scorable.reduce((total, row) =>
    total + (row.status === 'fully_compliant' ? 2 : row.status === 'partial' ? 1 : 0), 0);
  return Math.round((achieved / (scorable.length * 2)) * 1000) / 10;
};

const awarenessFindings = (awareness: unknown): Finding[] => {
  const data = awareness as AwarenessData | null;
  return (data?.high_risk_questions ?? []).map(question => ({
    uid: `awareness.${question.code}`,
    ref: `Awareness ${question.code}`,
    control_area: 'Security and privacy awareness',
    finding: question.question,
    severity: question.pct === 0 ? 'Critical' : question.pct != null && question.pct <= 25 ? 'High' : 'Medium',
    recommended_action: 'Address this behaviour through targeted training, technical controls and follow-up testing.',
    owner: null,
    target_window: question.pct === 0 ? '0–30 days' : '30–90 days',
    source_type: 'awareness',
  }));
};

const defaultProgramme = (
  spec: ReportSpec,
  tasks: NonNullable<CompileInputs['tasks']>,
  register: ClassRegisterRow[],
): ImplementationWorkstream[] =>
  (spec.implementation_workstreams ?? []).map(workstream => {
    const matchingTasks = tasks.filter(task => workstream.themes.includes(task.theme));
    const matchingItems = register.filter(item =>
      workstream.themes.some(theme =>
        `${item.item} ${item.control_area ?? ''} ${item.workstream}`.toLowerCase().includes(theme.toLowerCase())));
    return {
      number: workstream.number,
      title: workstream.title,
      item_refs: matchingItems.map(item => item.ref),
      window: workstream.default_window,
      owner: workstream.default_owner,
      actions: matchingTasks.map(task => task.title),
      dependencies: workstream.description ?? null,
    };
  });

const mergeStructured = (
  base: StructuredReportData,
  override: Partial<StructuredReportData> | undefined,
): StructuredReportData => ({
  cover: override?.cover ?? base.cover,
  company_profile: override?.company_profile ?? base.company_profile,
  scope: override?.scope ?? base.scope,
  documentation_suites: override?.documentation_suites ?? base.documentation_suites,
  remediation_register: override?.remediation_register ?? base.remediation_register,
  outstanding_documents: override?.outstanding_documents ?? base.outstanding_documents,
  implementation_programme: override?.implementation_programme ?? base.implementation_programme,
  delivery_options: override?.delivery_options ?? base.delivery_options,
  delivery_cadence: override?.delivery_cadence ?? base.delivery_cadence,
  residual_exposures: override?.residual_exposures ?? base.residual_exposures,
  reviewed_documents: override?.reviewed_documents ?? base.reviewed_documents,
  awareness_respondents: override?.awareness_respondents ?? base.awareness_respondents,
});

export function buildReportPayload(inputs: CompileInputs, overrides: ReportOverrides): ReportPayload {
  const { spec } = inputs;
  const responseByQuestion = new Map(inputs.responses.map(response => [response.question_id, response]));
  const isV2 = inputs.version >= 2 || inputs.kind !== 'gap_assessment';
  const scopedSections = spec.assessment_scope?.section_ids;
  const scopedQuestions = scopedSections?.length
    ? inputs.questions.filter(question => scopedSections.includes(question.section_id))
    : inputs.questions;

  const rows: DomainRow[] = [...scopedQuestions]
    .sort((a, b) => a.section_id - b.section_id || a.question_number - b.question_number)
    .map(question => {
      const response = responseByQuestion.get(question.id);
      const status = (response?.response ?? 'not_assessed') as ControlStatus;
      const { a, b } = splitRef(question.regulatory_ref);
      return {
        uid: question.uid,
        ref: displayRef(question),
        control_area: question.subsection,
        question: question.question,
        ref_a: a,
        ref_b: b,
        status,
        risk: (question.risk as Severity) ?? 'Low',
        severity: severityFor(spec, question.risk, status),
        findings: response?.findings ?? null,
        evidence_req: question.evidence_req,
        remediation: question.remediation,
        owner: response?.responsible_party ?? null,
        target_date: response?.target_date ?? null,
      };
    });

  const sectionByUid = new Map(scopedQuestions.map(question => [question.uid, question]));
  const sectionIds = [...new Set(rows.map(row => sectionByUid.get(row.uid)!.section_id))];
  const domains: DomainSection[] = sectionIds.map(sectionId => {
    const domainRows = rows.filter(row => sectionByUid.get(row.uid)!.section_id === sectionId);
    return {
      section_id: sectionId,
      section_name: sectionByUid.get(domainRows[0].uid)!.section_name,
      pct: scoreRows(domainRows),
      counts: countStatuses(domainRows),
      rows: domainRows,
    };
  });

  const counts = countStatuses(rows);
  const open = rows.filter(row => row.severity != null);
  const overallPct = scoreRows(rows);
  const completionPct = rows.length
    ? Math.round((rows.filter(row => row.status !== 'not_assessed').length / rows.length) * 1000) / 10
    : null;
  const maturity = maturityFor(spec, overallPct);
  const priorIssued = inputs.chain
    .filter(report => ['issued', 'superseded'].includes(report.approval_status))
    .sort((a, b) => b.version - a.version)[0] ?? null;
  const riskCounts: Record<Severity, number> = { Critical: 0, High: 0, Medium: 0, Low: 0 };
  rows.forEach(row => { riskCounts[row.risk] += 1; });

  const worstFor = (sectionId: number): Severity | null => {
    const severities = domains.find(domain => domain.section_id === sectionId)?.rows
      .filter(row => row.severity)
      .map(row => row.severity!) ?? [];
    return SEVERITY_ORDER.find(severity => severities.includes(severity)) ?? null;
  };

  const topActions = overrides.top_actions ?? open
    .filter(row => row.remediation)
    .sort((a, b) => SEVERITY_ORDER.indexOf(a.severity!) - SEVERITY_ORDER.indexOf(b.severity!))
    .slice(0, 6)
    .map(row => row.remediation!);

  const toFinding = (row: DomainRow): Finding => ({
    uid: row.uid,
    ref: row.ref,
    control_area: row.control_area,
    finding: row.findings || row.question,
    severity: row.severity!,
    recommended_action: row.remediation,
    owner: row.owner,
    target_window: row.target_date || spec.target_windows[row.severity!] || '—',
    source_type: 'assessment',
  });
  const riskRegister = overrides.risk_register ?? [
    ...open.map(toFinding),
    ...awarenessFindings(inputs.awareness),
  ]
    .sort((a, b) => SEVERITY_ORDER.indexOf(a.severity) - SEVERITY_ORDER.indexOf(b.severity))
    .slice(0, spec.risk_register_limit ?? 20);

  const windows = [...new Set(SEVERITY_ORDER.map(severity => spec.target_windows[severity]))];
  const roadmap = windows.map(window => ({
    window,
    items: open
      .filter(row => spec.target_windows[row.severity!] === window && row.remediation)
      .map(row => ({ ref: row.ref, action: row.remediation!, severity: row.severity! })),
  })).filter(phase => phase.items.length);

  const hasIssuedDocs = inputs.issuedDocs.length > 0;
  let generatedRegister: ClassRegisterRow[] = open.map((row, index) => {
    const classification = overrides.classification?.[row.uid];
    return {
      uid: row.uid,
      ref: `R${String(index + 1).padStart(2, '0')}`,
      item: classification?.item ?? row.control_area ?? row.question,
      control_area: row.control_area,
      severity: row.severity!,
      cls: classification?.cls ?? proposeClass(row, hasIssuedDocs),
      cls_source: classification ? 'advisor' : 'proposed',
      documents_covering: classification?.documents_covering ?? [],
      evidence_required: classification?.evidence_required ?? row.evidence_req,
      owner: classification?.owner ?? row.owner,
      workstream: classification?.workstream ?? sectionByUid.get(row.uid)!.section_name,
    };
  });

  if (overrides.structured?.remediation_register) {
    generatedRegister = overrides.structured.remediation_register.map(row => {
      const classification = overrides.classification?.[row.uid];
      return classification ? {
        ...row,
        item: classification.item ?? row.item,
        cls: classification.cls,
        cls_source: 'advisor',
        documents_covering: classification.documents_covering ?? row.documents_covering,
        evidence_required: classification.evidence_required ?? row.evidence_required,
        owner: classification.owner ?? row.owner,
        workstream: classification.workstream ?? row.workstream,
      } : row;
    });
  }

  const awareness = inputs.awareness as AwarenessData | null;
  const defaultAwarenessRespondents = (awareness?.cohorts ?? []).flatMap(cohort =>
    (cohort.respondents ?? []).map(respondent => ({
      respondent: `Respondent ${respondent.respondent_no}`,
      questions_answered: respondent.answered,
      pct_aligned: respondent.pct,
      rating: respondent.rating,
    })));
  const defaultSuites = [...new Set(inputs.issuedDocs.map(document => document.source))].map(source => {
    const documents = inputs.issuedDocs.filter(document => document.source === source);
    return {
      suite: source === 'policy'
        ? 'Compliance policies and procedures'
        : source === 'manual' ? 'Privacy information management system' : source,
      documents: `${documents.length} controlled document${documents.length === 1 ? '' : 's'}`,
      governing_document: documents[0]?.original_filename ?? '—',
    };
  });
  const defaultResidual: ResidualExposure[] = generatedRegister
    .filter(row => row.cls !== 'A')
    .slice(0, 10)
    .map(row => ({
      exposure: row.item,
      why_it_matters: row.control_area || 'The control remains open pending implementation and evidence.',
      closed_by: row.ref,
    }));

  const structured = mergeStructured({
    cover: {
      prepared_by: inputs.session.auditor_name || inputs.practiceName,
      attention: inputs.contactName ?? null,
      scope_of_version: isV2
        ? 'Adds the post-documentation position, implementation programme, delivery options and residual risk.'
        : 'Initial gap assessment and remediation roadmap.',
      confidentiality_statement: null,
    },
    company_profile: {
      legal_name: inputs.session.org_name || inputs.clientName,
      registration_number: inputs.registrationNumber ?? null,
      location: null,
      industry: inputs.industry ?? null,
      activities: null,
      personal_information_categories: [],
    },
    scope: {
      objectives: [
        'Assess the current compliance posture against the selected framework.',
        'Identify material control gaps, required evidence and accountable owners.',
        'Provide a sequenced implementation programme and residual-risk view.',
      ],
      methodology: [
        'Structured control interviews and evidence review.',
        'Control-by-control mapping to statutory and standards references.',
        'Risk-prioritised remediation and human review before issue.',
      ],
      limitations: spec.assessment_scope?.limitations ?? [],
      out_of_scope_domains: spec.assessment_scope?.out_of_scope_domains ?? [],
    },
    documentation_suites: defaultSuites,
    remediation_register: generatedRegister,
    outstanding_documents: [],
    implementation_programme: defaultProgramme(spec, inputs.tasks ?? [], generatedRegister),
    delivery_options: spec.delivery_options ?? [],
    delivery_cadence: spec.delivery_cadence ?? [],
    residual_exposures: defaultResidual,
    reviewed_documents: inputs.uploads.map(upload => ({
      document: upload.original_filename,
      version_date: upload.created_at,
    })),
    awareness_respondents: defaultAwarenessRespondents,
  }, overrides.structured);

  const classificationRegister = isV2 ? structured.remediation_register : null;
  const proposedClassifications = classificationRegister?.filter(row => row.cls_source === 'proposed').length ?? 0;
  const issues: string[] = [];
  if (!overrides.accuracy_confirmed) issues.push('Advisor accuracy confirmation is required before approval.');
  if (proposedClassifications) {
    issues.push(`${proposedClassifications} remediation classifications still require advisor confirmation.`);
  }

  const required = inputs.checklist.filter(item => item.required);
  const documentationIssued = isV2 ? {
    rows: inputs.issuedDocs.map(document => ({
      title: document.original_filename,
      source: document.source,
      issued_at: document.created_at,
    })),
    slots_required: required.length,
    slots_filled: required.filter(item => inputs.confirmedChecklistIds.has(item.id)).length,
    suites: structured.documentation_suites,
    total_documents: inputs.issuedDocs.length,
    open_remediation_items: structured.remediation_register.filter(row => row.cls !== 'A').length,
  } : null;

  const vars = {
    org_name: inputs.session.org_name || inputs.clientName,
    auditor_name: inputs.session.auditor_name,
    audit_date: inputs.session.audit_date,
    overall_pct: overallPct,
    maturity_label: maturity.label,
    question_total: rows.length,
    fully_compliant_count: counts.fully_compliant,
    partial_count: counts.partial,
    under_review_count: counts.under_review,
    non_compliant_count: counts.non_compliant,
    not_assessed_count: counts.not_assessed,
    critical_count: open.filter(row => row.severity === 'Critical').length,
  };
  const sections: ReportPayload['sections'] = {};
  const order = spec.sections.filter(section => !section.min_version || isV2);
  order.forEach(section => {
    const template = spec.narrative_templates[section.key];
    sections[section.key] = {
      title: section.title,
      narrative_default: template ? interpolate(template, vars) : null,
    };
  });

  return {
    meta: {
      framework: inputs.framework,
      kind: inputs.kind,
      version: inputs.version,
      compiled_at: new Date().toISOString(),
    },
    cover: {
      client_name: inputs.clientName,
      org_name: inputs.session.org_name,
      auditor_name: inputs.session.auditor_name,
      audit_date: inputs.session.audit_date,
      audit_ref: inputs.session.audit_ref,
      practice_name: inputs.practiceName,
      history: [...inputs.chain]
        .sort((a, b) => a.version - b.version)
        .map(report => ({
          version: report.version,
          kind: report.kind,
          title: report.title,
          status: report.approval_status,
          issued_at: report.issued_at,
        })),
    },
    structured,
    summary: {
      overall_pct: overallPct,
      overall_rating: inputs.score?.overall?.rating ?? null,
      completion_pct: completionPct,
      maturity_label: maturity.label,
      maturity_tone: maturity.tone,
      counts: { ...counts, total: rows.length },
      risk_counts: riskCounts,
      critical_count: open.filter(row => row.severity === 'Critical').length,
      baseline: inputs.track?.baseline_at
        ? { pct: inputs.track.baseline_pct, rating: inputs.track.baseline_rating, at: inputs.track.baseline_at }
        : null,
      prior: priorIssued
        ? { version: priorIssued.version, overall_pct: priorIssued.payload?.summary?.overall_pct ?? null }
        : null,
      dashboard: domains.map(domain => ({
        section_id: domain.section_id,
        section_name: domain.section_name,
        pct: domain.pct,
        counts: domain.counts,
        worst: worstFor(domain.section_id),
      })),
      top_actions: topActions,
    },
    domains,
    awareness: inputs.awareness,
    risk_register: riskRegister,
    roadmap,
    documentation_issued: documentationIssued,
    classification_register: classificationRegister,
    implementation_programme: isV2 ? structured.implementation_programme : null,
    outstanding_documents: isV2 ? structured.outstanding_documents : null,
    residual_risk: isV2 ? structured.residual_exposures : null,
    appendices: {
      documents_reviewed: structured.reviewed_documents,
      awareness_respondents: structured.awareness_respondents,
      framework_legend: inputs.frameworkLegend,
    },
    quality: {
      accuracy_confirmed: overrides.accuracy_confirmed === true,
      proposed_classifications: proposedClassifications,
      issues,
      ready: overrides.accuracy_confirmed === true && proposedClassifications === 0,
    },
    sections,
    section_order: order,
    spec: {
      rating_scale: spec.rating_scale,
      alignment_table: spec.alignment_table,
    },
  };
}
