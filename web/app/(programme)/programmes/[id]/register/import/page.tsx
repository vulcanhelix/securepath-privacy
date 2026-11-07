import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { ImportFindings } from './ImportFindings';

export const dynamic = 'force-dynamic';

// ---------------------------------------------------------------------------
// W3-01 — findings import (spec §13.1 FR-IMP-01/05). Upload → dry-run preview
// (per-row rejects with reasons + create/exists diff) → commit. All writes go
// through the import_* definer RPCs under the caller's JWT — this page reads
// run history through RLS only. Partner write roles may import; the RPCs are
// the real gate (this check only decides what the page offers).
// ---------------------------------------------------------------------------

const RUN_TONE: Record<string, 'pass' | 'fail' | 'warn' | 'neutral'> = {
  received: 'neutral',
  previewed: 'warn',
  committed: 'pass',
  abandoned: 'neutral',
  failed: 'fail',
};

export default async function RegisterImportPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const canImport = ctx.role.hasRole('partner', 'partner_admin', 'partner_consultant');
  const base = `/programmes/${id}`;

  const { data: runs } = await supabase
    .from('import_runs')
    .select('id, kind, file_name, status, created_at, committed_at, preview')
    .eq('programme_id', id)
    .eq('kind', 'findings')
    .order('created_at', { ascending: false })
    .limit(10);

  return (
    <>
      <PageHeader
        title="Import findings"
        eyebrow={ctx.programme.name}
        meta="CSV upload → preview → commit"
        actions={
          <Link href={`${base}/register`} className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
            ← Back to the register
          </Link>
        }
      />

      <Card pad={20} style={{ marginBottom: 20 }}>
        {canImport ? (
          <ImportFindings programmeId={id} />
        ) : (
          <Alert tone="info">
            Importing findings requires a partner_admin or partner_consultant role on this programme.
          </Alert>
        )}
      </Card>

      <Card pad={20}>
        <h2 style={{ fontSize: 'var(--fs-lg)', marginTop: 0 }}>Recent import runs</h2>
        {(runs ?? []).length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>File</th>
                  <th>Status</th>
                  <th>Rows</th>
                  <th>Created</th>
                  <th>Rejected</th>
                  <th>Started</th>
                </tr>
              </thead>
              <tbody>
                {(runs ?? []).map((r) => {
                  const p = (r.preview ?? {}) as Record<string, unknown>;
                  const created = (p.created ?? p.will_create ?? '—') as string | number;
                  const rejected = (p.rejected ?? '—') as string | number;
                  return (
                    <tr key={r.id as string}>
                      <td className="mono" style={{ fontSize: 'var(--fs-xs)' }}>
                        {(r.file_name as string) ?? (r.kind === 'findings' ? 'assessment session' : r.kind)}
                      </td>
                      <td><Badge tone={RUN_TONE[r.status as string] ?? 'neutral'}>{r.status as string}</Badge></td>
                      <td className="mono">{(p.rows ?? '—') as string | number}</td>
                      <td className="mono">{created}</td>
                      <td className="mono">{rejected}</td>
                      <td className="mono muted" style={{ fontSize: 'var(--fs-xs)', whiteSpace: 'nowrap' }}>
                        {new Date(r.created_at as string).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' })}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="muted">No import runs yet for this programme.</p>
        )}
      </Card>
    </>
  );
}
