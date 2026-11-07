'use client';
import { useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';

// ---------------------------------------------------------------------------
// W3-01 — findings-register CSV import (spec §13.1 FR-IMP-01/05).
// The file never leaves the browser as a file: it is parsed here into row
// objects, which the DB validates AGAIN — import_begin parks them on a
// 'received' run, import_preview is the dry run (per-row rejects with
// reasons + a create/exists diff), import_commit writes register_items with
// import_run_id provenance. Every write goes through the definer RPCs under
// the caller's JWT; errors surface verbatim.
// ---------------------------------------------------------------------------

type Row = Record<string, string>;

type Reject = { row_no: number; ref: string; reason: string };
type DiffEntry = { row_no: number; ref: string; outcome: 'create' | 'exists'; differs: boolean | null };
type Preview = {
  rows: number;
  ok: number;
  rejected: number;
  will_create: number;
  already_exists: number;
  rejects: Reject[];
  diff: DiffEntry[];
  rejects_truncated?: boolean;
  diff_truncated?: boolean;
};

/** header → canonical register column (case/space/punct-insensitive) */
const HEADER_MAP: Record<string, string> = {
  ref: 'ref',
  reference: 'ref',
  findingref: 'ref',
  'finding ref': 'ref',
  id: 'ref',
  finding: 'finding',
  description: 'finding',
  gap: 'finding',
  title: 'finding',
  priority: 'priority',
  risk: 'priority',
  rating: 'priority',
  'assessment window': 'assessment_window',
  assessment_window: 'assessment_window',
  window: 'assessment_window',
  assessment: 'assessment_window',
  'review window': 'assessment_window',
  lead: 'lead',
  'lead email': 'lead',
  lead_email: 'lead',
  owner: 'lead',
  'assigned to': 'lead',
  assignee: 'lead',
  'planned close week': 'planned_close_week',
  planned_close_week: 'planned_close_week',
  'close week': 'planned_close_week',
  'target week': 'planned_close_week',
  week: 'planned_close_week',
};

/** RFC-4180-ish parser: quoted fields, "" escapes, \r\n, tab detection. */
function parseDelimited(text: string): { headers: string[]; rows: Row[] } {
  const src = text.replace(/^﻿/, ''); // strip BOM
  const delim = src.slice(0, src.indexOf('\n') === -1 ? undefined : src.indexOf('\n')).includes('\t')
    ? '\t'
    : ',';
  const records: string[][] = [];
  let field = '';
  let record: string[] = [];
  let inQuotes = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (inQuotes) {
      if (c === '"') {
        if (src[i + 1] === '"') { field += '"'; i++; }
        else inQuotes = false;
      } else field += c;
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === delim) {
      record.push(field);
      field = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++;
      record.push(field);
      field = '';
      records.push(record);
      record = [];
    } else field += c;
  }
  if (field !== '' || record.length) { record.push(field); records.push(record); }
  const headers = (records.shift() ?? []).map((h) => h.trim());
  const canonical = headers.map((h) => HEADER_MAP[h.toLowerCase()] ?? null);
  const rows = records
    .filter((r) => r.some((v) => v.trim() !== ''))
    .map((r) => {
      const row: Row = {};
      r.forEach((v, i) => {
        const header = headers[i];
        if (header) row[header] = v;              // keep the source column for audit
        const key = canonical[i];
        if (key) row[key] = v.trim();             // canonical copy the RPC reads
      });
      return row;
    });
  return { headers, rows };
}

async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

type Phase =
  | { step: 'pick' }
  | { step: 'preview'; runId: string; fileName: string; preview: Preview }
  | { step: 'done'; created: number; already: number; skipped: number; rejected: number };

export function ImportFindings({ programmeId }: { programmeId: string }) {
  const router = useRouter();
  const fileRef = useRef<HTMLInputElement>(null);
  const [phase, setPhase] = useState<Phase>({ step: 'pick' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [localErr, setLocalErr] = useState<string | null>(null);

  async function onFile(file: File) {
    setErr(null);
    setLocalErr(null);
    setBusy(true);
    try {
      const text = await file.text();
      const { headers, rows } = parseDelimited(text);
      if (!headers.length) throw new Error('Could not find a header row — the first line must name the columns.');
      if (!rows.length) throw new Error('The file has a header row but no data rows.');
      if (!headers.some((h) => HEADER_MAP[h.toLowerCase()] === 'ref'))
        throw new Error('No "ref" column found — expected a header like ref, reference or finding ref.');
      if (!headers.some((h) => HEADER_MAP[h.toLowerCase()] === 'finding'))
        throw new Error('No "finding" column found — expected a header like finding or description.');
      const hash = await sha256Hex(text);
      const sb = browserClient();
      const begun = await sb.rpc('import_begin', {
        p_programme_id: programmeId,
        p_kind: 'findings',
        p_file_name: file.name,
        p_file_hash: hash,
        p_rows: rows,
      });
      if (begun.error) throw new Error(begun.error.message);
      const runId = (begun.data as { import_run_id: string }).import_run_id;
      const previewed = await sb.rpc('import_preview', { p_run_id: runId });
      if (previewed.error) throw new Error(previewed.error.message);
      setPhase({ step: 'preview', runId, fileName: file.name, preview: previewed.data as Preview });
    } catch (e) {
      setLocalErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  }

  async function commit(runId: string) {
    setErr(null);
    setBusy(true);
    const { data, error } = await browserClient().rpc('import_commit', { p_run_id: runId });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    const r = data as { created: number; already_imported: number; skipped: number; rejected: number };
    setPhase({ step: 'done', created: r.created, already: r.already_imported, skipped: r.skipped, rejected: r.rejected });
    router.refresh();
  }

  async function abandon(runId: string) {
    setErr(null);
    setBusy(true);
    const { error } = await browserClient().rpc('import_abandon', { p_run_id: runId });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setPhase({ step: 'pick' });
  }

  if (phase.step === 'done') {
    return (
      <div>
        <Alert tone="ok">
          {`Import committed — ${phase.created} finding${phase.created === 1 ? '' : 's'} created` +
            (phase.already ? `, ${phase.already} already existed (skipped)` : '') +
            (phase.rejected ? `, ${phase.rejected} row${phase.rejected === 1 ? '' : 's'} rejected` : '') +
            '.'}
        </Alert>
        <div style={{ display: 'flex', gap: 10, marginTop: 12 }}>
          <Button size="sm" onClick={() => setPhase({ step: 'pick' })}>Import another file</Button>
          <Button size="sm" variant="outline" onClick={() => router.push(`/programmes/${programmeId}/register`)}>
            Back to the register
          </Button>
        </div>
      </div>
    );
  }

  if (phase.step === 'preview') {
    const p = phase.preview;
    return (
      <div>
        <p className="muted" style={{ marginTop: 0 }}>
          {phase.fileName} — nothing is written until you confirm. Rows that already exist are linked, not duplicated.
        </p>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 16 }}>
          <Badge tone="pass">{p.will_create} will be created</Badge>
          <Badge tone="neutral">{p.already_exists} already exist</Badge>
          <Badge tone={p.rejected ? 'fail' : 'neutral'}>{p.rejected} rejected</Badge>
          <Badge tone="neutral">{p.rows} rows checked</Badge>
        </div>

        {p.rejects.length ? (
          <>
            <h2 style={{ fontSize: 'var(--fs-lg)' }}>Rejected rows — fix these in the file and re-upload</h2>
            <div className="sp-table-scroll" style={{ marginBottom: 16 }}>
              <table className="sp-table">
                <thead><tr><th>Row</th><th>Ref</th><th>Reason</th></tr></thead>
                <tbody>
                  {p.rejects.map((r) => (
                    <tr key={r.row_no}>
                      <td className="mono">{r.row_no}</td>
                      <td className="mono">{r.ref || '—'}</td>
                      <td>{r.reason}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {p.rejects_truncated ? <p className="muted">Only the first 200 rejections are listed.</p> : null}
          </>
        ) : null}

        <h2 style={{ fontSize: 'var(--fs-lg)' }}>What will be written</h2>
        <div className="sp-table-scroll" style={{ marginBottom: 16 }}>
          <table className="sp-table">
            <thead><tr><th>Row</th><th>Ref</th><th>Outcome</th></tr></thead>
            <tbody>
              {p.diff.map((d) => (
                <tr key={d.row_no}>
                  <td className="mono">{d.row_no}</td>
                  <td className="mono">{d.ref}</td>
                  <td>
                    {d.outcome === 'create'
                      ? <Badge tone="pass">new finding</Badge>
                      : <Badge tone="neutral">already exists{d.differs ? ' — file text differs, kept as is' : ''}</Badge>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {p.diff_truncated ? <p className="muted">Only the first 500 rows are listed.</p> : null}

        {err ? <Alert tone="err">{err}</Alert> : null}
        <div style={{ display: 'flex', gap: 10 }}>
          <Button size="sm" cta disabled={busy || p.will_create + p.already_exists === 0} onClick={() => commit(phase.runId)}>
            {busy ? 'Committing…' : `Commit import — ${p.will_create} new, ${p.already_exists} existing`}
          </Button>
          <Button size="sm" variant="outline" disabled={busy} onClick={() => abandon(phase.runId)}>
            Discard run
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div>
      <p className="muted" style={{ marginTop: 0 }}>
        Upload a CSV (or TSV) of findings — one row per finding. The file is checked against every
        row and shown as a preview before anything is written (FR-IMP-05).
      </p>
      <div className="muted" style={{ fontSize: 'var(--fs-sm)', marginBottom: 16 }}>
        Columns: <code>ref</code> and <code>finding</code> are required;{' '}
        <code>priority</code> (High / Medium / Low), <code>assessment window</code>,{' '}
        <code>lead</code> (a user&apos;s email) and <code>planned close week</code> are optional.
        A ref that already exists on the register is linked, not duplicated — re-importing the
        same file is safe.
      </div>
      {localErr ? <Alert tone="err">{localErr}</Alert> : null}
      {err ? <Alert tone="err">{err}</Alert> : null}
      <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
        <Button size="sm" icon="upload" disabled={busy} onClick={() => fileRef.current?.click()}>
          {busy ? 'Checking…' : 'Choose CSV file'}
        </Button>
        <input
          ref={fileRef}
          type="file"
          accept=".csv,.tsv,.txt,text/csv,text/tab-separated-values"
          hidden
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void onFile(f);
          }}
        />
      </div>
    </div>
  );
}
