import type {
  ClassRegisterRow,
  Finding,
  RegisterClass,
  ReportOverrides,
  Severity,
  StructuredReportData,
} from './types';

const SEVERITIES = new Set(['Critical', 'High', 'Medium', 'Low']);
const REGISTER_CLASSES = new Set(['A', 'B', 'C', 'D']);
const CLASS_SOURCES = new Set(['proposed', 'advisor']);
const FINDING_SOURCES = new Set(['assessment', 'awareness', 'advisor']);

function asRecord(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${label} must be an object.`);
  }
  return value as Record<string, unknown>;
}

function stringField(record: Record<string, unknown>, key: string, label: string): string {
  const value = record[key];
  if (typeof value !== 'string') throw new Error(`${label}.${key} must be a string.`);
  return value;
}

function optionalStringField(record: Record<string, unknown>, key: string, label: string): string | undefined {
  const value = record[key];
  if (value === undefined) return undefined;
  if (typeof value !== 'string') throw new Error(`${label}.${key} must be a string.`);
  return value;
}

function nullableStringField(record: Record<string, unknown>, key: string, label: string): string | null {
  const value = record[key];
  if (value == null) return null;
  if (typeof value !== 'string') throw new Error(`${label}.${key} must be a string or null.`);
  return value;
}

function numberField(record: Record<string, unknown>, key: string, label: string): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error(`${label}.${key} must be a finite number.`);
  return value;
}

function stringArrayField(record: Record<string, unknown>, key: string, label: string): string[] {
  const value = record[key];
  if (!Array.isArray(value) || !value.every(item => typeof item === 'string')) {
    throw new Error(`${label}.${key} must be an array of strings.`);
  }
  return value;
}

function typedString<T extends string>(value: unknown, allowed: Set<string>, label: string): T {
  if (typeof value !== 'string' || !allowed.has(value)) throw new Error(`${label} has an unsupported value.`);
  return value as T;
}

function arrayOfRecords(value: unknown, label: string): Record<string, unknown>[] {
  if (!Array.isArray(value)) throw new Error(`${label} must be an array.`);
  return value.map((item, index) => asRecord(item, `${label}[${index}]`));
}

function validateClassRegisterRow(record: Record<string, unknown>, label: string): ClassRegisterRow {
  return {
    uid: stringField(record, 'uid', label),
    ref: stringField(record, 'ref', label),
    item: stringField(record, 'item', label),
    control_area: nullableStringField(record, 'control_area', label),
    severity: typedString<Severity>(record.severity, SEVERITIES, `${label}.severity`),
    cls: typedString<RegisterClass>(record.cls, REGISTER_CLASSES, `${label}.cls`),
    cls_source: typedString<'proposed' | 'advisor'>(record.cls_source, CLASS_SOURCES, `${label}.cls_source`),
    documents_covering: stringArrayField(record, 'documents_covering', label),
    evidence_required: nullableStringField(record, 'evidence_required', label),
    owner: nullableStringField(record, 'owner', label),
    workstream: stringField(record, 'workstream', label),
  };
}

export function validateStructuredReportData(value: unknown): Partial<StructuredReportData> {
  const record = asRecord(value, 'Structured report data');
  const structured: Partial<StructuredReportData> = {};
  if ('cover' in record) {
    const cover = asRecord(record.cover, 'cover');
    structured.cover = {
      prepared_by: nullableStringField(cover, 'prepared_by', 'cover'),
      attention: nullableStringField(cover, 'attention', 'cover'),
      scope_of_version: nullableStringField(cover, 'scope_of_version', 'cover'),
      confidentiality_statement: nullableStringField(cover, 'confidentiality_statement', 'cover'),
    };
  }
  if ('company_profile' in record) {
    const profile = asRecord(record.company_profile, 'company_profile');
    structured.company_profile = {
      legal_name: stringField(profile, 'legal_name', 'company_profile'),
      registration_number: nullableStringField(profile, 'registration_number', 'company_profile'),
      location: nullableStringField(profile, 'location', 'company_profile'),
      industry: nullableStringField(profile, 'industry', 'company_profile'),
      activities: nullableStringField(profile, 'activities', 'company_profile'),
      personal_information_categories: stringArrayField(profile, 'personal_information_categories', 'company_profile'),
    };
  }
  if ('scope' in record) {
    const scope = asRecord(record.scope, 'scope');
    structured.scope = {
      objectives: stringArrayField(scope, 'objectives', 'scope'),
      methodology: stringArrayField(scope, 'methodology', 'scope'),
      limitations: stringArrayField(scope, 'limitations', 'scope'),
      out_of_scope_domains: stringArrayField(scope, 'out_of_scope_domains', 'scope'),
    };
  }
  if ('documentation_suites' in record) {
    structured.documentation_suites = arrayOfRecords(record.documentation_suites, 'documentation_suites').map((row, index) => ({
      suite: stringField(row, 'suite', `documentation_suites[${index}]`),
      documents: stringField(row, 'documents', `documentation_suites[${index}]`),
      governing_document: stringField(row, 'governing_document', `documentation_suites[${index}]`),
    }));
  }
  if ('remediation_register' in record) {
    structured.remediation_register = arrayOfRecords(record.remediation_register, 'remediation_register')
      .map((row, index) => validateClassRegisterRow(row, `remediation_register[${index}]`));
  }
  if ('outstanding_documents' in record) {
    structured.outstanding_documents = arrayOfRecords(record.outstanding_documents, 'outstanding_documents').map((row, index) => ({
      document: stringField(row, 'document', `outstanding_documents[${index}]`),
      position: stringField(row, 'position', `outstanding_documents[${index}]`),
      ref: stringField(row, 'ref', `outstanding_documents[${index}]`),
    }));
  }
  if ('implementation_programme' in record) {
    structured.implementation_programme = arrayOfRecords(record.implementation_programme, 'implementation_programme').map((row, index) => ({
      number: numberField(row, 'number', `implementation_programme[${index}]`),
      title: stringField(row, 'title', `implementation_programme[${index}]`),
      item_refs: stringArrayField(row, 'item_refs', `implementation_programme[${index}]`),
      window: stringField(row, 'window', `implementation_programme[${index}]`),
      owner: stringField(row, 'owner', `implementation_programme[${index}]`),
      actions: stringArrayField(row, 'actions', `implementation_programme[${index}]`),
      dependencies: nullableStringField(row, 'dependencies', `implementation_programme[${index}]`),
    }));
  }
  if ('delivery_options' in record) {
    structured.delivery_options = arrayOfRecords(record.delivery_options, 'delivery_options').map((row, index) => ({
      route: stringField(row, 'route', `delivery_options[${index}]`),
      scope: stringField(row, 'scope', `delivery_options[${index}]`),
      strength: stringField(row, 'strength', `delivery_options[${index}]`),
      limitation: stringField(row, 'limitation', `delivery_options[${index}]`),
    }));
  }
  if ('delivery_cadence' in record) {
    structured.delivery_cadence = arrayOfRecords(record.delivery_cadence, 'delivery_cadence').map((row, index) => ({
      cycle: stringField(row, 'cycle', `delivery_cadence[${index}]`),
      activity: stringField(row, 'activity', `delivery_cadence[${index}]`),
      evidence: stringField(row, 'evidence', `delivery_cadence[${index}]`),
    }));
  }
  if ('residual_exposures' in record) {
    structured.residual_exposures = arrayOfRecords(record.residual_exposures, 'residual_exposures').map((row, index) => ({
      exposure: stringField(row, 'exposure', `residual_exposures[${index}]`),
      why_it_matters: stringField(row, 'why_it_matters', `residual_exposures[${index}]`),
      closed_by: stringField(row, 'closed_by', `residual_exposures[${index}]`),
    }));
  }
  if ('reviewed_documents' in record) {
    structured.reviewed_documents = arrayOfRecords(record.reviewed_documents, 'reviewed_documents').map((row, index) => ({
      document: stringField(row, 'document', `reviewed_documents[${index}]`),
      version_date: nullableStringField(row, 'version_date', `reviewed_documents[${index}]`),
    }));
  }
  if ('awareness_respondents' in record) {
    structured.awareness_respondents = arrayOfRecords(record.awareness_respondents, 'awareness_respondents').map((row, index) => ({
      respondent: stringField(row, 'respondent', `awareness_respondents[${index}]`),
      questions_answered: numberField(row, 'questions_answered', `awareness_respondents[${index}]`),
      pct_aligned: numberField(row, 'pct_aligned', `awareness_respondents[${index}]`),
      rating: stringField(row, 'rating', `awareness_respondents[${index}]`),
    }));
  }
  return structured;
}

export function validateRiskRegister(value: unknown): Finding[] {
  return arrayOfRecords(value, 'Risk register').map((record, index) => ({
    uid: stringField(record, 'uid', `Risk register[${index}]`),
    ref: stringField(record, 'ref', `Risk register[${index}]`),
    control_area: nullableStringField(record, 'control_area', `Risk register[${index}]`),
    finding: stringField(record, 'finding', `Risk register[${index}]`),
    severity: typedString<Severity>(record.severity, SEVERITIES, `Risk register[${index}].severity`),
    recommended_action: nullableStringField(record, 'recommended_action', `Risk register[${index}]`),
    owner: nullableStringField(record, 'owner', `Risk register[${index}]`),
    target_window: stringField(record, 'target_window', `Risk register[${index}]`),
    source_type: typedString<'assessment' | 'awareness' | 'advisor'>(
      record.source_type,
      FINDING_SOURCES,
      `Risk register[${index}].source_type`,
    ),
  }));
}

export function validateReportOverrides(value: unknown): ReportOverrides {
  const record = asRecord(value, 'Report overrides');
  const overrides: ReportOverrides = {};
  if ('narratives' in record) {
    const narratives = asRecord(record.narratives, 'narratives');
    overrides.narratives = Object.fromEntries(Object.entries(narratives).map(([key, narrative]) => {
      if (typeof narrative !== 'string') throw new Error(`narratives.${key} must be a string.`);
      return [key, narrative];
    }));
  }
  if ('sections_excluded' in record) {
    overrides.sections_excluded = stringArrayField(record, 'sections_excluded', 'Report overrides');
  }
  if ('classification' in record) {
    const classification = asRecord(record.classification, 'classification');
    overrides.classification = Object.fromEntries(Object.entries(classification).map(([uid, value]) => {
      const row = asRecord(value, `classification.${uid}`);
      const item = optionalStringField(row, 'item', `classification.${uid}`);
      const evidenceRequired = optionalStringField(row, 'evidence_required', `classification.${uid}`);
      const owner = optionalStringField(row, 'owner', `classification.${uid}`);
      const workstream = optionalStringField(row, 'workstream', `classification.${uid}`);
      const documentsCovering = row.documents_covering === undefined
        ? undefined
        : stringArrayField(row, 'documents_covering', `classification.${uid}`);
      return [uid, {
        cls: typedString<RegisterClass>(row.cls, REGISTER_CLASSES, `classification.${uid}.cls`),
        ...(item === undefined ? {} : { item }),
        ...(documentsCovering === undefined ? {} : { documents_covering: documentsCovering }),
        ...(evidenceRequired === undefined ? {} : { evidence_required: evidenceRequired }),
        ...(owner === undefined ? {} : { owner }),
        ...(workstream === undefined ? {} : { workstream }),
      }];
    }));
  }
  if ('top_actions' in record) {
    overrides.top_actions = stringArrayField(record, 'top_actions', 'Report overrides');
  }
  if ('structured' in record) overrides.structured = validateStructuredReportData(record.structured);
  if ('risk_register' in record) overrides.risk_register = validateRiskRegister(record.risk_register);
  if ('accuracy_confirmed' in record) {
    if (typeof record.accuracy_confirmed !== 'boolean') {
      throw new Error('Report overrides.accuracy_confirmed must be a boolean.');
    }
    overrides.accuracy_confirmed = record.accuracy_confirmed;
  }
  return overrides;
}
