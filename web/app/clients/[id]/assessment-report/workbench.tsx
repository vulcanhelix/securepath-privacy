'use client';
import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { Select, Textarea } from '@/components/ui/forms';
import { DataTable } from '@/components/ui/DataTable';
import { EmptyState } from '@/components/ui/EmptyState';
import type { ClassRegisterRow, RegisterClass, ReportOverrides, ReportPayload } from '@/lib/report/types';

type ReportRow = {
  id: string; version: number; kind: string; title: string; approval_status: string;
  compiled_at: string | null; issued_at: string | null; issued_document_id: string | null;
  payload: ReportPayload | null; overrides: ReportOverrides | null; updated_at: string;
};

const KIND_LABEL: Record<string, string> = {
  gap_assessment: 'Gap assessment',
  post_documentation: 'Post-documentation position',
  reassessment: 'Reassessment',
};
const STATUS_TONE: Record<string, 'warn' | 'neutral' | 'accent' | 'ink'> = {
  draft_ai: 'warn', draft_human: 'neutral', approved: 'accent', issued: 'ink', superseded: 'neutral',
};
const STATUS_LABEL: Record<string, string> = {
  draft_ai: 'Draft (AI)', draft_human: 'Draft', approved: 'Approved', issued: 'Issued', superseded: 'Superseded',
};

export default function Workbench({ clientOrgId, framework, isAdvisor, canIssue, hasSignedOffSession, working, archive }: {
  clientOrgId: string; framework: string; isAdvisor: boolean; canIssue: boolean;
  hasSignedOffSession: boolean; working: ReportRow | null; archive: ReportRow[];
}) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [overrides, setOverrides] = useState<ReportOverrides>(working?.overrides ?? {});
  const [dirty, setDirty] = useState(false);
  const payload = working?.payload ?? null;
  const isDraft = !!working && ['draft_ai', 'draft_human'].includes(working.approval_status);
  const hasIssued = archive.some(r => r.approval_status === 'issued' || r.approval_status === 'superseded');
  const [kind, setKind] = useState(hasIssued ? 'post_documentation' : 'gap_assessment');

  const excluded = useMemo(() => new Set(overrides.sections_excluded ?? []), [overrides]);

  function edit(next: ReportOverrides) { setOverrides(next); setDirty(true); }

  async function compile() {
    setBusy(true); setMsg({});
    const r = await fetch(`/api/clients/${clientOrgId}/assessment-report/compile`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ framework, kind: working ? undefined : kind }),
    });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'compile failed' }); return; }
    setMsg({ ok: 'Report compiled. Review the sections, edit the narrative, then approve.' });
    router.refresh();
  }

  async function saveOverrides() {
    if (!working) return;
    setBusy(true); setMsg({});
    const { error } = await browserClient().rpc('update_assessment_report_overrides', {
      p_report_id: working.id, p_overrides: overrides,
    });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setDirty(false); setMsg({ ok: 'Edits saved — recompile to refresh data, or approve when ready.' });
    router.refresh();
  }

  async function approve() {
    if (!working) return;
    setBusy(true); setMsg({});
    const { error } = await browserClient().rpc('approve_assessment_report', { p_report_id: working.id });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setMsg({ ok: 'Report approved — issue it to freeze the evidence document.' });
    router.refresh();
  }

  async function issue() {
    if (!working) return;
    setBusy(true); setMsg({});
    const r = await fetch(`/api/assessment-reports/${working.id}/issue`, { method: 'POST' });
    setBusy(false);
    if (!r.ok) { setMsg({ err: (await r.json()).error ?? 'issue failed' }); return; }
    setMsg({ ok: `v${working.version} issued and archived as immutable evidence.` });
    router.refresh();
  }

  if (!working && !archive.length) {
    return (
      <Card pad={24}>
        {isAdvisor ? (
          hasSignedOffSession ? (
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
              <span style={{ color: 'var(--muted)', fontSize: 'var(--fs-sm)' }}>
                No report yet. Compile v1 from the signed-off assessment.
              </span>
              <span style={{ flex: 1 }} />
              <Select value={kind} onChange={e => setKind(e.target.value)} style={{ width: 'auto' }}>
                {Object.entries(KIND_LABEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
              </Select>
              <Button size="sm" disabled={busy} onClick={compile} cta>Compile report</Button>
            </div>
          ) : (
            <EmptyState icon="file" message="A signed-off Stage 1 assessment is the precondition — complete and sign off the assessment first." />
          )
        ) : (
          <EmptyState icon="file" message="No issued assessment reports yet." />
        )}
        {msg.err && <Alert tone="err">{msg.err}</Alert>}
      </Card>
    );
  }

  return (
    <>
      {isAdvisor && working && (
        <Card pad={20} style={{ marginBottom: 24 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <strong style={{ fontWeight: 500 }}>v{working.version} — {KIND_LABEL[working.kind] ?? working.kind}</strong>
            <Badge tone={STATUS_TONE[working.approval_status] ?? 'neutral'} dot>
              {STATUS_LABEL[working.approval_status] ?? working.approval_status}
            </Badge>
            <span style={{ flex: 1 }} />
            {isDraft && <Button size="sm" variant="secondary" disabled={busy} onClick={compile}>
              {working.compiled_at ? 'Recompile data' : 'Compile'}
            </Button>}
            {isDraft && dirty && <Button size="sm" disabled={busy} onClick={saveOverrides}>Save edits</Button>}
            {working.compiled_at && (
              <a href={`/api/clients/${clientOrgId}/assessment-report/preview?report=${working.id}`} target="_blank" rel="noreferrer">
                <Button size="sm" variant="secondary">Preview / print</Button>
              </a>
            )}
            {isDraft && working.compiled_at && !dirty &&
              <Button size="sm" disabled={busy} onClick={approve}>Approve</Button>}
            {working.approval_status === 'approved' && canIssue &&
              <Button size="sm" disabled={busy} onClick={issue} cta>Issue v{working.version}</Button>}
          </div>
          {msg.err && <Alert tone="err">{msg.err}</Alert>}
          {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
        </Card>
      )}

      {isAdvisor && isDraft && payload && (
        <Card title="Sections & narrative" pad={20} style={{ marginBottom: 24 }}>
          <p style={{ color: 'var(--muted)', fontSize: 'var(--fs-xs)', marginTop: 0 }}>
            Untick a section to exclude it from the issued report. Narrative boxes override the
            templated default; leave blank to keep it. Recompiling refreshes the data and keeps these edits.
          </p>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            {payload.section_order.filter(s => s.key !== 'cover').map(s => {
              const hasNarrative = payload.sections[s.key]?.narrative_default != null || overrides.narratives?.[s.key];
              return (
                <div key={s.key} style={{ borderTop: '1px solid var(--border)', paddingTop: 12 }}>
                  <label style={{ display: 'inline-flex', gap: 8, alignItems: 'center', fontWeight: 500 }}>
                    <input
                      type="checkbox"
                      checked={!excluded.has(s.key)}
                      onChange={e => {
                        const next = new Set(excluded);
                        if (e.target.checked) next.delete(s.key); else next.add(s.key);
                        edit({ ...overrides, sections_excluded: [...next] });
                      }}
                    />
                    {s.title}
                  </label>
                  {hasNarrative != null && !excluded.has(s.key) && (
                    <Textarea
                      rows={3}
                      placeholder={payload.sections[s.key]?.narrative_default ?? 'Advisor narrative (optional)'}
                      value={overrides.narratives?.[s.key] ?? ''}
                      onChange={e => edit({
                        ...overrides,
                        narratives: { ...overrides.narratives, [s.key]: e.target.value },
                      })}
                      style={{ marginTop: 8 }}
                    />
                  )}
                </div>
              );
            })}
          </div>
        </Card>
      )}

      {isAdvisor && isDraft && payload?.classification_register?.length ? (
        <Card title="Classification register (A–D)" pad={0} style={{ marginBottom: 24 }}>
          <DataTable
            columns={[{ label: 'Ref' }, { label: 'Control area' }, { label: 'Risk' }, { label: 'Class' }, { label: 'Evidence required' }]}
            rows={payload.classification_register.map((row: ClassRegisterRow) => {
              const ov = overrides.classification?.[row.uid];
              return [
                <span key="r" className="mono" style={{ fontSize: 'var(--fs-xs)' }}>{row.ref}</span>,
                <span key="a" style={{ fontSize: 'var(--fs-xs)' }}>{row.control_area ?? '—'}</span>,
                <Badge key="s" tone={row.severity === 'Critical' ? 'warn' : 'neutral'}>{row.severity}</Badge>,
                <Select
                  key="c"
                  value={ov?.cls ?? row.cls}
                  onChange={e => edit({
                    ...overrides,
                    classification: {
                      ...overrides.classification,
                      [row.uid]: { ...ov, cls: e.target.value as RegisterClass },
                    },
                  })}
                  style={{ width: 'auto' }}
                >
                  {(['A', 'B', 'C', 'D'] as const).map(c => <option key={c} value={c}>{c}</option>)}
                </Select>,
                <span key="e" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>{row.evidence_required ?? '—'}</span>,
              ];
            })}
          />
        </Card>
      ) : null}

      <Card title="Version history" action={<span className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--faint)' }}>corrections are new versions</span>} pad={0}>
        {archive.length === 0 ? (
          <EmptyState icon="archive" message="No versions issued yet." />
        ) : (
          <DataTable
            columns={[{ label: 'Version' }, { label: 'Type' }, { label: 'Issued' }, { label: 'Status' }, { label: '', align: 'right' }]}
            rows={archive.map(r => [
              <span key="v" className="mono" style={{ fontWeight: 500 }}>v{r.version}</span>,
              <span key="k" style={{ fontSize: 'var(--fs-xs)' }}>{KIND_LABEL[r.kind] ?? r.kind}</span>,
              <span key="d" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                {r.issued_at ? r.issued_at.slice(0, 10) : '—'}
              </span>,
              <Badge key="s" tone={STATUS_TONE[r.approval_status] ?? 'neutral'}>{STATUS_LABEL[r.approval_status]}</Badge>,
              <span key="l">
                {r.issued_document_id && (
                  <a href={`/api/documents/${r.issued_document_id}?inline=1`} target="_blank" rel="noreferrer"
                     style={{ fontSize: 'var(--fs-xs)' }}>View</a>
                )}
              </span>,
            ])}
          />
        )}
      </Card>
    </>
  );
}
