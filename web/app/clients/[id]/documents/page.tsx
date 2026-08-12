import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import Intake from './intake';

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

  // framework's track (privacy -> popia/paia, cyber -> cyber_essentials/iso27701)
  const trackKind = ['cyber_essentials', 'iso27701'].includes(framework) ? 'cyber' : 'privacy';
  const { data: track } = await supabase.from('tracks')
    .select('id, current_stage').eq('client_org_id', id).eq('track_kind', trackKind).maybeSingle();
  const [{ data: checklist }, { data: documents }, { data: links }] = await Promise.all([
    supabase.from('document_checklists')
      .select('id, slot_key, name, description, category, required, sort')
      .eq('framework_key', framework).eq('active', true).order('sort'),
    supabase.from('documents')
      .select('id, original_filename, mime, size, version, created_at')
      .eq('client_org_id', id).order('created_at', { ascending: false }),
    supabase.from('document_links')
      .select('id, checklist_id, document_id, status').eq('client_org_id', id),
  ]);

  const confirmed = (links ?? []).filter(l => l.status === 'confirmed');
  const docById = new Map((documents ?? []).map(d => [d.id, d]));
  const slots = (checklist ?? []).map(c => {
    const fills = confirmed.filter(l => l.checklist_id === c.id).map(l => docById.get(l.document_id)).filter(Boolean);
    return { ...c, fills };
  });
  const requiredSlots = slots.filter(s => s.required);
  const filledRequired = requiredSlots.filter(s => s.fills.length > 0).length;

  return (
    <>
      <p className="muted"><Link href="/dashboard">← Clients</Link> · <Link href={`/clients/${id}/policies${qs}`}>Stage 3 — Policies →</Link></p>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: '.75rem' }}>
        <h1 style={{ flex: 1 }}>{client.name} — Document intake</h1>
        <span className="badge">{framework === 'popia' ? 'POPIA' : framework} · Stage 2{track ? ` · track stage ${track.current_stage}` : ''}</span>
      </div>
      <p className="muted">
        Bring in the client&rsquo;s existing paperwork, map it to the expected-document checklist, and see the gaps.
        <strong> {filledRequired}/{requiredSlots.length} required documents in place.</strong>
      </p>

      <Intake
        clientOrgId={client.id}
        trackId={track?.id ?? null}
        framework={framework}
        checklist={(checklist ?? []).map(c => ({ id: c.id, name: c.name }))}
        documents={documents ?? []}
        links={links ?? []}
      />

      <div className="card">
        <h2>Gap map</h2>
        <table>
          <thead><tr><th>Expected document</th><th>Category</th><th>Status</th><th>Satisfied by</th></tr></thead>
          <tbody>
            {slots.map(s => (
              <tr key={s.id}>
                <td><strong>{s.name}</strong>{s.required ? '' : <span className="muted"> (optional)</span>}
                  {s.description ? <div className="muted" style={{ fontSize: '.8rem' }}>{s.description}</div> : null}</td>
                <td><span className="badge">{s.category}</span></td>
                <td>{s.fills.length > 0
                  ? <span style={{ color: 'var(--accent)', fontWeight: 600 }}>✓ In place</span>
                  : <span style={{ color: s.required ? '#b23a3a' : 'var(--muted)', fontWeight: 600 }}>{s.required ? 'Gap' : '—'}</span>}</td>
                <td>{s.fills.map((d: any) => (
                  <a key={d.id} href={`/api/documents/${d.id}`} style={{ display: 'block' }}>{d.original_filename}</a>
                ))}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
