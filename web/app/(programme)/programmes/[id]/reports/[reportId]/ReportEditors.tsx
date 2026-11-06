'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Input, Select, Textarea } from '@/components/ui/forms';

// W2-08 — narrative editors slotted into MonthlyReportBody while the report
// is draft-like. Every save is update_report_draft under the caller's JWT —
// it accepts narrative/headline fields only (snapshot figures are not
// editable anywhere). On error: show the message, write nothing else.

function useSave(reportId: string) {
  const router = useRouter();
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ ok?: string; err?: string }>({});
  async function save(payload: Record<string, unknown>) {
    setBusy(true);
    setMsg({});
    const { error } = await browserClient().rpc('update_report_draft', {
      p_report_id: reportId,
      p_sections: payload,
    });
    setBusy(false);
    if (error) return setMsg({ err: error.message });
    setMsg({ ok: 'Saved.' });
    router.refresh();
  }
  return { busy, msg, save };
}

function Msg({ msg }: { msg: { ok?: string; err?: string } }) {
  if (msg.err) return <p className="sp-breach-msg is-err">{msg.err}</p>;
  if (msg.ok) return <p className="sp-breach-msg is-ok">{msg.ok}</p>;
  return null;
}

export function NarrativeField({
  reportId,
  sectionKey,
  initial,
  required,
}: {
  reportId: string;
  sectionKey: string;
  initial: string | null;
  required: boolean;
}) {
  const [text, setText] = React.useState(initial ?? '');
  const { busy, msg, save } = useSave(reportId);
  const dirty = text !== (initial ?? '');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <Textarea
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder={required ? 'Narrative required for this section' : 'Optional narrative'}
        aria-label={`Narrative for ${sectionKey}`}
      />
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <Button
          size="sm"
          variant="outline"
          disabled={busy || !dirty}
          onClick={() => save({ narrative: { [sectionKey]: text.trim() ? text : null } })}
        >
          {busy ? 'Saving…' : 'Save narrative'}
        </Button>
        {required && !(initial ?? '').trim() ? (
          <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>Input outstanding</span>
        ) : null}
        <Msg msg={msg} />
      </div>
    </div>
  );
}

export function HeaderFields({
  reportId,
  headline,
  commentary,
  overallRag,
  trend,
}: {
  reportId: string;
  headline: string | null;
  commentary: string | null;
  overallRag: string | null;
  trend: string | null;
}) {
  const [h, setH] = React.useState(headline ?? '');
  const [c, setC] = React.useState(commentary ?? '');
  const [rag, setRag] = React.useState(overallRag ?? '');
  const [t, setT] = React.useState(trend ?? '');
  const { busy, msg, save } = useSave(reportId);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8, margin: '20px 0 4px' }}>
      <Input value={h} onChange={(e) => setH(e.target.value)} placeholder="Headline" aria-label="Headline" />
      <Textarea value={c} onChange={(e) => setC(e.target.value)} placeholder="Overall commentary" aria-label="Commentary" />
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
        <Select value={rag} onChange={(e) => setRag(e.target.value)} aria-label="Overall RAG" style={{ width: 160 }}>
          <option value="">Overall RAG —</option>
          <option value="Green">Green</option>
          <option value="Amber">Amber</option>
          <option value="Red">Red</option>
        </Select>
        <Input value={t} onChange={(e) => setT(e.target.value)} placeholder="Trend (e.g. improving)" aria-label="Trend" style={{ width: 220 }} />
        <Button
          size="sm"
          variant="outline"
          disabled={busy}
          onClick={() => save({ headline: h, commentary: c, overall_rag: rag || null, trend: t })}
        >
          {busy ? 'Saving…' : 'Save summary'}
        </Button>
        <Msg msg={msg} />
      </div>
    </div>
  );
}
