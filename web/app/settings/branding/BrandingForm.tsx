'use client';
import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Field, Input, Textarea } from '@/components/ui/forms';
import { Alert } from '@/components/ui/Alert';

// W2-03 — white-label branding form (spec §7.4 screen 12). Writes go through
// the update_practice_branding RPC only (partner_admin-guarded, audited) —
// never a direct practices update. The FR-BRN-06 preview below renders the
// three surfaces the brand actually paints BEFORE saving: the sign-in page,
// the programme shell, and the report print layout (the "report template" is
// the brand applied to that HTML layout — product decision, no stored file).
// FR-BRN-07: colour choices below WCAG 2.1 AA against white are flagged
// (warning, not a block — a flag is what the spec asks for).

export interface BrandValues {
  name: string;
  logo_url: string;
  accent_hex: string;
  primary_hex: string;
  sign_in_text: string;
  support_contact: string;
  email_sender_name: string;
}

const SWATCHES = ['#2b2644', '#1a5c46', '#1e3a5f', '#6f3149', '#3d3d3d', '#85681a'];
const HEX_RE = /^#[0-9a-fA-F]{6}$/;
const DEFAULT_ACCENT = '#2b2644';

// WCAG 2.1 relative luminance + contrast ratio
function luminance(hex: string): number {
  const c = [0, 2, 4].map((i) => parseInt(hex.slice(1 + i, 3 + i), 16) / 255);
  const [r, g, b] = c.map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

function ColourField({
  label, hint, value, onChange,
}: {
  label: string; hint?: string; value: string; onChange: (v: string) => void;
}) {
  const bad = value !== '' && !HEX_RE.test(value);
  const weak = !bad && HEX_RE.test(value) && contrast(value, '#ffffff') < 4.5;
  return (
    <Field
      label={label}
      hint={hint}
      error={
        bad
          ? 'Use #rrggbb, e.g. #2b2644 — or leave blank to clear.'
          : weak
            ? `Flagged: ${value} is ${contrast(value, '#ffffff').toFixed(1)}:1 against white — ` +
              'below the 4.5:1 WCAG 2.1 AA minimum. It may be hard to read on buttons and the report header.'
            : undefined
      }
    >
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        {SWATCHES.map((hex) => (
          <button
            key={hex}
            type="button"
            aria-label={`${label} ${hex}`}
            onClick={() => onChange(hex)}
            style={{
              margin: 0, padding: 0, width: 28, height: 28, borderRadius: '50%', background: hex,
              border: value.toLowerCase() === hex ? '2px solid var(--text)' : '2px solid transparent',
              outlineOffset: 2, cursor: 'pointer', flex: 'none',
            }}
          />
        ))}
        <Input
          value={value}
          onChange={(e) => onChange(e.target.value.trim())}
          placeholder={DEFAULT_ACCENT}
          className="mono"
          invalid={bad}
          style={{ width: 120 }}
        />
      </div>
    </Field>
  );
}

// ---- FR-BRN-06 live preview mocks ----------------------------------------

function PreviewCard({ title, caption, children }: { title: string; caption: string; children: React.ReactNode }) {
  return (
    <div data-testid={`preview-${title.toLowerCase().replace(/[^a-z]+/g, '-')}`}
      style={{ border: '1px solid var(--border)', borderRadius: 10, overflow: 'hidden', background: 'var(--surface)' }}>
      <div style={{ padding: '8px 12px', borderBottom: '1px solid var(--border)', fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
        <strong style={{ color: 'var(--text-2)' }}>{title}</strong> · {caption}
      </div>
      <div style={{ padding: 14 }}>{children}</div>
    </div>
  );
}

function BrandMark({ name, accent, logoUrl }: { name: string; accent: string; logoUrl: string }) {
  if (logoUrl) {
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={logoUrl} alt="" style={{ maxHeight: 26, maxWidth: 110, objectFit: 'contain' }} />;
  }
  return (
    <span
      aria-hidden="true"
      style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        width: 24, height: 24, borderRadius: 6, background: accent, color: '#fff',
        fontSize: 12, fontWeight: 700, flex: 'none',
      }}
    >
      {(name.trim()[0] ?? 'S').toUpperCase()}
    </span>
  );
}

function SignInPreview({ v, accent }: { v: BrandValues; accent: string }) {
  return (
    <div style={{ background: '#f4f3f0', borderRadius: 8, padding: '18px 12px', display: 'flex', justifyContent: 'center' }}>
      <div style={{ background: '#fff', border: '1px solid #e3e1dc', borderRadius: 10, padding: 18, width: 240, textAlign: 'center' }}>
        <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 8 }}>
          <BrandMark name={v.name} accent={accent} logoUrl={v.logo_url} />
        </div>
        <div data-testid="preview-signin-name" style={{ fontWeight: 600, fontSize: 14, color: '#1a1a1a' }}>
          {v.name || 'Your brand'}
        </div>
        {v.sign_in_text ? (
          <div data-testid="preview-signin-text" style={{ fontSize: 11, color: '#666', marginTop: 4 }}>{v.sign_in_text}</div>
        ) : null}
        <div style={{ height: 8 }} />
        <div style={{ height: 22, border: '1px solid #ddd', borderRadius: 6, margin: '6px 0', background: '#fafafa' }} />
        <div style={{ height: 22, border: '1px solid #ddd', borderRadius: 6, margin: '6px 0 10px', background: '#fafafa' }} />
        <div data-testid="preview-accent-button" style={{ background: accent, color: '#fff', borderRadius: 6, padding: '6px 0', fontSize: 12, fontWeight: 600 }}>
          Sign in
        </div>
        {v.support_contact ? (
          <div style={{ fontSize: 10, color: '#888', marginTop: 10 }}>Support: {v.support_contact}</div>
        ) : null}
      </div>
    </div>
  );
}

function ShellPreview({ v, accent }: { v: BrandValues; accent: string }) {
  return (
    <div>
      {/* mini sidebar + context bar as the programme shell renders them */}
      <div style={{ display: 'flex', border: '1px solid var(--border)', borderRadius: 8, overflow: 'hidden', minHeight: 96 }}>
        <div style={{ width: 132, background: 'var(--side-bg)', padding: '10px 8px', display: 'flex', gap: 6, alignItems: 'flex-start' }}>
          <BrandMark name={v.name} accent={accent} logoUrl={v.logo_url} />
          <span data-testid="preview-shell-name" style={{ color: 'var(--side-text)', fontSize: 11, fontWeight: 600, lineHeight: '24px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {v.name || 'Your brand'}
          </span>
        </div>
        <div style={{ flex: 1, padding: 10 }}>
          <div style={{ display: 'flex', gap: 14, fontSize: 11, color: 'var(--muted)', borderBottom: '1px solid var(--border)', paddingBottom: 8 }}>
            <span data-testid="preview-shell-tab" style={{ color: 'var(--text)', fontWeight: 600, borderBottom: `2px solid ${accent}`, paddingBottom: 7, marginBottom: -9 }}>
              Dashboard
            </span>
            <span>Schedule</span>
            <span>Register</span>
          </div>
          <div style={{ display: 'flex', gap: 6, marginTop: 14 }}>
            <span style={{ background: accent, color: '#fff', borderRadius: 5, padding: '3px 8px', fontSize: 10, fontWeight: 600 }}>Primary action</span>
            <span style={{ border: `1px solid ${accent}`, color: accent, borderRadius: 5, padding: '3px 8px', fontSize: 10, fontWeight: 600 }}>Secondary</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function ReportPreview({ v, accent, showAttribution }: { v: BrandValues; accent: string; showAttribution: boolean }) {
  return (
    /* mirrors components/programme/MonthlyReportBody: brand header with the
       3px accent rule, title + meta, then the FR-BRN-05 attribution footer */
    <div style={{ background: '#fff', border: '1px solid #ddd', borderRadius: 4, padding: 16, color: '#111' }}>
      <div data-testid="preview-report-header" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16, paddingBottom: 10, marginBottom: 12, borderBottom: `3px solid ${accent}` }}>
        <span style={{ fontWeight: 600, fontSize: 13 }}>{v.name || 'Your brand'}</span>
        {v.logo_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={v.logo_url} alt="" style={{ maxHeight: 28, maxWidth: 120, objectFit: 'contain' }} />
        ) : null}
      </div>
      <div style={{ fontWeight: 600, fontSize: 13 }}>Monthly report — November 2026</div>
      <div style={{ fontSize: 10, color: '#555', marginTop: 4, display: 'flex', gap: 10, flexWrap: 'wrap' }}>
        <span>Client name</span><span>Programme name</span><span>Status: Issued</span>
      </div>
      <div style={{ marginTop: 10, fontSize: 10, color: '#333' }}>
        <div style={{ fontWeight: 600, fontSize: 11, marginBottom: 4 }}>Headline figures</div>
        <div style={{ display: 'flex', gap: 6 }}>
          {[46, 30, 18].map((w, i) => (
            <div key={i} style={{ height: 8, width: w, background: '#eee', borderRadius: 3 }} />
          ))}
        </div>
      </div>
      <div data-testid="preview-report-footer" style={{ marginTop: 12, fontSize: 9, color: '#666' }}>
        {showAttribution ? (
          <>Powered by <strong>SecurePath</strong> · delivered by {v.name || 'your brand'}</>
        ) : (
          <>Delivered by {v.name || 'your brand'}</>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------

export function BrandingForm({
  partnerId, initial, showAttribution,
}: {
  partnerId: string; initial: BrandValues; showAttribution: boolean;
}) {
  const router = useRouter();
  const supabase = browserClient();
  const [f, setF] = useState<BrandValues>(initial);
  const [saved, setSaved] = useState<BrandValues>(initial);
  const [msg, setMsg] = useState<{ ok?: string; err?: string }>({});
  const [busy, setBusy] = useState(false);

  const accent = HEX_RE.test(f.accent_hex) ? f.accent_hex : DEFAULT_ACCENT;
  const dirty = useMemo(
    () => (Object.keys(f) as (keyof BrandValues)[]).some((k) => f[k] !== saved[k]),
    [f, saved]
  );

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg({});
    const payload: Record<string, string | null> = {};
    for (const k of Object.keys(f) as (keyof BrandValues)[]) {
      if (f[k] !== saved[k]) payload[k] = f[k] === '' ? null : f[k];
    }
    if (payload.name === null) {
      setBusy(false); setMsg({ err: 'Display name cannot be empty.' }); return;
    }
    for (const k of ['accent_hex', 'primary_hex'] as const) {
      if (k in payload && payload[k] !== null && !HEX_RE.test(payload[k] as string)) {
        setBusy(false); setMsg({ err: `${k === 'accent_hex' ? 'Accent' : 'Primary'} colour must be #rrggbb.` }); return;
      }
    }
    if (payload.logo_url && !/^https?:\/\//.test(payload.logo_url)) {
      setBusy(false); setMsg({ err: 'Logo URL must start with http:// or https://' }); return;
    }
    const { error } = await supabase.rpc('update_practice_branding', {
      p_partner: partnerId,
      p_payload: payload,
    });
    setBusy(false);
    if (error) { setMsg({ err: error.message }); return; }
    setSaved(f);
    setMsg({ ok: 'Saved. Your brand applies across the workspace, programme shell, emails and the report print layout.' });
    router.refresh();
  }

  return (
    <>
      <PageHeader
        title="Branding"
        meta="White-label settings: your name, logo and colours are what your team and clients see on the workspace, emails and client reports."
      />
      <div style={{ display: 'grid', gap: 'var(--gap, 16px)', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', alignItems: 'start' }}>
        <Card>
          <form onSubmit={submit}>
            <Field label="Display name" required hint="Shown in the sidebar, on the sign-in page, in emails and on report headers.">
              <Input required value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
            </Field>
            <Field label="Logo URL" hint="An https image URL — shown in the sidebar and on report headers. Blank falls back to a monogram.">
              <Input value={f.logo_url} onChange={(e) => setF({ ...f, logo_url: e.target.value.trim() })} placeholder="https://…/logo.png" />
            </Field>
            <ColourField
              label="Accent colour"
              hint="Status colours (pass/warn/fail) never change — the accent paints actions, active tabs and the report header rule."
              value={f.accent_hex}
              onChange={(v) => setF({ ...f, accent_hex: v })}
            />
            <ColourField
              label="Primary colour"
              hint="Used where the brand needs a second, deeper tone (e.g. branded email headers)."
              value={f.primary_hex}
              onChange={(v) => setF({ ...f, primary_hex: v })}
            />
            <Field label="Sign-in page text" hint="A line shown under your name on the sign-in card.">
              <Textarea
                value={f.sign_in_text}
                onChange={(e) => setF({ ...f, sign_in_text: e.target.value })}
                style={{ minHeight: 60 }}
                placeholder="Compliance, managed for you."
              />
            </Field>
            <Field label="Support contact" hint="Shown in branded emails and on the sign-in card — an email address or phone number.">
              <Input value={f.support_contact} onChange={(e) => setF({ ...f, support_contact: e.target.value })} placeholder="support@yourfirm.example" />
            </Field>
            <Field label="Email sender name" hint="The From name on platform emails. Blank falls back to your display name.">
              <Input value={f.email_sender_name} onChange={(e) => setF({ ...f, email_sender_name: e.target.value })} placeholder={f.name || 'Your brand'} />
            </Field>
            <Button type="submit" disabled={busy || !dirty}>
              {busy ? 'Saving…' : dirty ? 'Save branding' : 'Saved'}
            </Button>
            {msg.err && <Alert tone="err">{msg.err}</Alert>}
            {msg.ok && <Alert tone="ok">{msg.ok}</Alert>}
          </form>
        </Card>
        <div style={{ display: 'grid', gap: 'var(--gap, 16px)' }}>
          <PreviewCard title="Sign-in page" caption="what clients and staff see when they log in">
            <SignInPreview v={f} accent={accent} />
          </PreviewCard>
          <PreviewCard title="Programme shell" caption="sidebar, active tab and action buttons">
            <ShellPreview v={f} accent={accent} />
          </PreviewCard>
          <PreviewCard title="Report print layout" caption="brand header and footer on the PDF/print render">
            <ReportPreview v={f} accent={accent} showAttribution={showAttribution} />
          </PreviewCard>
        </div>
      </div>
    </>
  );
}
