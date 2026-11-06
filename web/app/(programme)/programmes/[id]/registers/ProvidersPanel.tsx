'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { StatusPill } from '@/components/ui/StatusPill';
import { Checkbox, Field, Input } from '@/components/ui/forms';

// W2-09 — named external providers for the client (FR-MNT-04 contact book).
// Reads come from list_external_providers (server); the only write is
// upsert_external_provider under the caller's JWT (p_provider_id NULL →
// insert). The RPC re-checks the client write role.

export interface Provider {
  id: string;
  client_org_id: string;
  name: string;
  kind: string | null;
  contact_email: string | null;
  channel: string | null;
  active: boolean;
  created_at: string;
}

type Form = { name: string; kind: string; contact_email: string; channel: string; active: boolean };
const EMPTY: Form = { name: '', kind: '', contact_email: '', channel: '', active: true };

export function ProvidersPanel({
  clientId,
  providers,
  canWrite,
}: {
  clientId: string;
  providers: Provider[];
  canWrite: boolean;
}) {
  const [editing, setEditing] = React.useState<string | 'new' | null>(null);

  return (
    <>
      {canWrite && editing !== 'new' ? (
        <div style={{ marginBottom: 12 }}>
          <Button size="sm" icon="plus" onClick={() => setEditing('new')}>Add provider</Button>
        </div>
      ) : null}
      {canWrite && editing === 'new' ? (
        <Card style={{ marginBottom: 16 }}>
          <ProviderForm clientId={clientId} initial={EMPTY} onDone={() => setEditing(null)} />
        </Card>
      ) : null}

      <Card pad={0}>
        {providers.length ? (
          <div className="sp-table-scroll">
            <table className="sp-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Kind</th>
                  <th>Contact</th>
                  <th>Channel</th>
                  <th>Status</th>
                  {canWrite ? <th /> : null}
                </tr>
              </thead>
              <tbody>
                {providers.map((p) => (
                  <React.Fragment key={p.id}>
                    <tr>
                      <td style={{ fontWeight: 500 }}>{p.name}</td>
                      <td className="muted">{p.kind ?? '—'}</td>
                      <td className="muted">{p.contact_email ?? '—'}</td>
                      <td className="muted">{p.channel ?? '—'}</td>
                      <td><StatusPill status={p.active ? 'active' : 'inactive'} /></td>
                      {canWrite ? (
                        <td style={{ textAlign: 'right' }}>
                          <Button size="sm" variant="ghost" onClick={() => setEditing(editing === p.id ? null : p.id)}>
                            {editing === p.id ? 'Cancel' : 'Edit'}
                          </Button>
                        </td>
                      ) : null}
                    </tr>
                    {editing === p.id ? (
                      <tr>
                        <td colSpan={6} style={{ background: 'var(--surface-card)' }}>
                          <ProviderForm
                            clientId={clientId}
                            providerId={p.id}
                            initial={{
                              name: p.name,
                              kind: p.kind ?? '',
                              contact_email: p.contact_email ?? '',
                              channel: p.channel ?? '',
                              active: p.active,
                            }}
                            onDone={() => setEditing(null)}
                          />
                        </td>
                      </tr>
                    ) : null}
                  </React.Fragment>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState
            icon="building-2"
            message="No external providers recorded. Add the IT provider, marketing lead and others who supply maintenance inputs."
          />
        )}
      </Card>
    </>
  );
}

function ProviderForm({
  clientId,
  providerId,
  initial,
  onDone,
}: {
  clientId: string;
  providerId?: string;
  initial: Form;
  onDone: () => void;
}) {
  const router = useRouter();
  const [f, setF] = React.useState<Form>(initial);
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);
  const set = (k: keyof Form) => (v: string) => setF((p) => ({ ...p, [k]: v }));

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    const { error } = await browserClient().rpc('upsert_external_provider', {
      p_client_org: clientId,
      p_name: f.name.trim(),
      p_kind: f.kind.trim() || null,
      p_contact_email: f.contact_email.trim() || null,
      p_channel: f.channel.trim() || null,
      p_active: f.active,
      p_provider_id: providerId ?? null,
    });
    setBusy(false);
    if (error) {
      setErr(error.message);
      return;
    }
    router.refresh();
    onDone();
  }

  return (
    <form onSubmit={submit} style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', padding: '8px 0' }}>
      <Field label="Name" required>
        <Input value={f.name} onChange={(e) => set('name')(e.target.value)} required />
      </Field>
      <Field label="Kind" hint="IT provider, marketing lead, finance, HR/admin…">
        <Input value={f.kind} onChange={(e) => set('kind')(e.target.value)} />
      </Field>
      <Field label="Contact email">
        <Input type="email" value={f.contact_email} onChange={(e) => set('contact_email')(e.target.value)} />
      </Field>
      <Field label="Channel" hint="How inputs arrive (portal, email…)">
        <Input value={f.channel} onChange={(e) => set('channel')(e.target.value)} />
      </Field>
      <div style={{ gridColumn: '1 / -1', display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        <Checkbox label="Active" checked={f.active} onChange={(e) => setF((p) => ({ ...p, active: e.target.checked }))} />
        <Button size="sm" type="submit" disabled={busy || !f.name.trim()}>
          {busy ? 'Saving…' : providerId ? 'Save provider' : 'Add provider'}
        </Button>
        <Button size="sm" variant="ghost" type="button" onClick={onDone}>Cancel</Button>
        {err ? <p className="sp-breach-msg is-err">{err}</p> : null}
      </div>
    </form>
  );
}
