'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

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
      setBusy(false); setMsg({ err: 'Accent must be a hex color like #2b8a5f' }); return;
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
    <div className="card" style={{ maxWidth: 520 }}>
      <h1>Practice branding</h1>
      <p className="muted">Whitelabel your workspace: your name, logo and accent color are what your team and clients see.</p>
      <form onSubmit={submit}>
        <label>Display name</label>
        <input required value={f.name} onChange={e => setF({ ...f, name: e.target.value })} />
        <label>Logo URL</label>
        <input value={f.logo_url} onChange={e => setF({ ...f, logo_url: e.target.value })} placeholder="https://…/logo.png" />
        <label>Accent color (hex)</label>
        <input value={f.accent_hex} onChange={e => setF({ ...f, accent_hex: e.target.value })} placeholder="#2b8a5f" />
        <button disabled={busy}>{busy ? 'Saving…' : 'Save branding'}</button>
      </form>
      {msg.err && <p className="err">{msg.err}</p>}
      {msg.ok && <p className="ok">{msg.ok}</p>}
    </div>
  );
}
