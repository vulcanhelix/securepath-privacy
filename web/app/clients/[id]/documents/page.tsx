import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { trackKindFor } from '@/lib/track';
import Intake from './intake';
import GapMap from './gapmap';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { StatusDot } from '@/components/ui/StatusDot';

export const dynamic = 'force-dynamic';

// Stage 2 — Document intake & gap map. Content-driven: the checklist is rendered
// from document_checklists (a content pack), not encoded here.
export default async function ClientDocuments(
  { params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ framework?: string }> }) {
  const { id } = await params;
  const framework = (await searchParams).framework ?? 'popia';
  const qs = framework === 'popia' ? '' : `?framework=${framework}`;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: client } = await supabase.from('client_orgs').select('id, name').eq('id', id).maybeSingle();
  if (!client) redirect('/dashboard');

  const trackKind = await trackKindFor(supabase, framework);
  const { data: track } = await supabase.from('tracks')
    .select('id, current_stage').eq('client_org_id', id).eq('track_kind', trackKind).maybeSingle();
  const [{ data: checklist }, { data: documents }, { data: links }] = await Promise.all([
    supabase.from('document_checklists')
      .select('id, slot_key, name, description, category, required, sort')
      .eq('framework_key', framework).eq('active', true).order('sort'),
    supabase.from('documents')
      .select('id, original_filename, mime, size, version, supersedes, created_at')
      .eq('client_org_id', id).order('created_at', { ascending: false }),
    supabase.from('document_links')
      .select('id, checklist_id, document_id, status').eq('client_org_id', id),
  ]);

  const confirmed = (links ?? []).filter(l => l.status === 'confirmed');
  const docById = new Map((documents ?? []).map(d => [d.id, d]));
  // a document another upload supersedes is history, not a current fill
  const superseded = new Set((documents ?? []).map(d => d.supersedes).filter(Boolean));
  const slots = (checklist ?? []).map(c => {
    const fills = confirmed
      .filter(l => l.checklist_id === c.id)
      .map(l => docById.get(l.document_id))
      .filter((d): d is NonNullable<typeof d> => Boolean(d) && !superseded.has(d!.id));
    return { ...c, fills };
  });
  const requiredSlots = slots.filter(s => s.required);
  const filledRequired = requiredSlots.filter(s => s.fills.length > 0).length;

  return (
    <>
      <PageHeader
        title={`${client.name} — Document intake`}
        back="Workspace"
        backHref={`/clients/${id}`}
        meta="Bring in the client's existing paperwork, map it to the expected-document checklist, and see the gaps."
        actions={
          <>
            <Badge><span className="mono">{framework.toUpperCase()}</span></Badge>
            <Badge tone={track?.current_stage === 2 ? 'accent' : 'neutral'} dot>Stage 2</Badge>
          </>
        }
      />

      {/* gap summary */}
      <Card pad={24} style={{ marginBottom: 24 }}>
        <div style={{ display: 'flex', gap: 28, alignItems: 'center', flexWrap: 'wrap' }}>
          <div>
            <div className="sp-kpi-label">Required documents in place</div>
            <div className="sp-kpi-value">{filledRequired}/{requiredSlots.length}</div>
          </div>
          <div style={{ flex: 1, minWidth: 240 }}>
            <div style={{ display: 'flex', gap: 3 }}>
              {requiredSlots.map(s => (
                <span
                  key={s.id}
                  title={s.name}
                  style={{
                    flex: 1, height: 6, borderRadius: 3,
                    background: s.fills.length > 0 ? 'var(--pass)' : 'var(--fail-border)',
                  }}
                />
              ))}
            </div>
            <div style={{ display: 'flex', gap: 16, marginTop: 10 }}>
              <StatusDot tone="pass" label="in place" />
              <StatusDot tone="fail" label="gap" />
              <StatusDot tone="neutral" label="optional" />
            </div>
          </div>
        </div>
      </Card>

      <Intake
        clientOrgId={client.id}
        trackId={track?.id ?? null}
        framework={framework}
        checklist={(checklist ?? []).map(c => ({ id: c.id, name: c.name }))}
        documents={documents ?? []}
        links={links ?? []}
      />

      <GapMap
        slots={slots.map(s => ({
          id: s.id, name: s.name, description: s.description, category: s.category, required: s.required,
          fills: s.fills.map((d: any) => ({
            id: d.id, name: d.original_filename, version: d.version,
            replaces: d.supersedes ? docById.get(d.supersedes)?.original_filename ?? null : null,
          })),
        }))}
      />

      <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 24 }}>
        <Link href={`/clients/${id}/policies${qs}`}>
          <Button cta>Continue to Stage 3 — Policies</Button>
        </Link>
      </div>
    </>
  );
}
