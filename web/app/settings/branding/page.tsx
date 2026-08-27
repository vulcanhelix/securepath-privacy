'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

const SWATCHES = ['#2b2644', '#1a5c46', '#1e3a5f', '#6f3149', '#3d3d3d', '#85681a'];

export default function Branding() {
  const router = useRouter();
  const supabase = browserClient();
  const [f, setF] = useState({ name: '', logo_url: '', accent_hex: '' });
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    supabase.from('practices').select('name, logo_url, accent_hex').maybeSingle().then(({ data }) => {
      if (data) setF({ name: data.name ?? '', logo_url: data.logo_url ?? '', accent_hex: data.accent_hex ?? '' });
    });
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg({});
    if (f.accent_hex && !/^#[0-9a-fA-F]{6}$/.test(f.accent_hex)) {
      setBusy(false); setMsg({ err: 'Accent must be a hex color like #2b2644' }); return;
    }
    const { error } = await supabase.from('practices').update({
      name: f.name, logo_url: f.logo_url || null, accent_hex: f.accent_hex || null,
    }).eq('id', (await supabase.from('practices').select('id').single()).data?.id);
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setMsg({ ok: 'Saved. Branding applies across your workspace and client-facing pages.' });
    router.refresh();
  }

  return (
    <>
      <PageHeader
        title="Practice branding"
        meta="Whitelabel your workspace: your name, logo and accent color are what your team and clients see."
      />
      <Card style={{ maxWidth: 'var(--form-max)' }}>
        <form onSubmit={submit}>
          <Field label="Display name">
            <Input required value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
          </Field>
          <Field label="Logo URL">
            <Input value={f.logo_url} onChange={(e) => setF({ ...f, logo_url: e.target.value })} placeholder="https://…/logo.png" />
          </Field>
          <Field label="Accent color" hint="Status colours (pass/warn/fail) and action buttons never change — only the accent does.">
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              {SWATCHES.map((hex) => (
                <button
                  key={hex}
                  type="button"
                  aria-label={`Accent ${hex}`}
                  onClick={() => setF({ ...f, accent_hex: hex })}
                  style={{
                    margin: 0, padding: 0, width: 28, height: 28, borderRadius: '50%', background: hex,
                    border: f.accent_hex === hex ? '2px solid var(--text)' : '2px solid transparent',
                    outlineOffset: 2, cursor: 'pointer',
                  }}
                />
              ))}
              <Input
                value={f.accent_hex}
                onChange={(e) => setF({ ...f, accent_hex: e.target.value })}
                placeholder="#2b2644"
                className="mono"
                style={{ width: 120 }}
              />
            </div>
          </Field>
          <Button type="submit" disabled={busy}>{busy ? 'Saving…' : 'Save branding'}</Button>
        </form>
        {msg.err && <Alert tone="err">{msg.err}</Alert>}
        {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
      </Card>
    </>
  );
}
