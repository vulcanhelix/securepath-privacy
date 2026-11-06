'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Alert } from '@/components/ui/Alert';
import { Button } from '@/components/ui/Button';
import { Checkbox, Field, Input, Select, Textarea } from '@/components/ui/forms';
import { recordDecision, upsertWeeklyLog } from './weekly-actions';

// W2-07 — FR-WKS-04 weekly log form. Writes ONLY via upsert_weekly_log
// (counts + week RAG are engine CALC, never sent from here). Session
// decisions go to the append-only ledger via record_decision, which is keyed
// on raid_item_id (W1-06 schema deviation) — so a decision is recorded
// against an open RAID item.

export interface WeeklyLogValues {
  session_held: boolean;
  completed: string[];
  planned_next: string[];
  blockers: string | null;
  decisions: string | null;
}

const toLines = (s: string) =>
  s
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);

const fromItems = (xs: unknown[]) =>
  xs
    .map((x) => (typeof x === 'string' ? x : x && typeof x === 'object' && 'text' in x ? String((x as { text: unknown }).text) : JSON.stringify(x)))
    .join('\n');

export function WeeklyLogForm({
  programmeId,
  week,
  initial,
}: {
  programmeId: string;
  week: number;
  initial: WeeklyLogValues | null;
}) {
  const router = useRouter();
  const [held, setHeld] = React.useState(initial?.session_held ?? false);
  const [completed, setCompleted] = React.useState(fromItems(initial?.completed ?? []));
  const [planned, setPlanned] = React.useState(fromItems(initial?.planned_next ?? []));
  const [blockers, setBlockers] = React.useState(initial?.blockers ?? '');
  const [notes, setNotes] = React.useState(initial?.decisions ?? '');
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ tone: 'ok' | 'err'; text: string } | null>(null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMsg(null);
    const err = await upsertWeeklyLog(browserClient(), programmeId, week, {
      session_held: held,
      completed: toLines(completed),
      planned_next: toLines(planned),
      blockers,
      decisions: notes,
    });
    setBusy(false);
    setMsg(err ? { tone: 'err', text: err } : { tone: 'ok', text: `Week ${week} log saved — counts recalculated.` });
    if (!err) router.refresh();
  }

  return (
    <form onSubmit={onSubmit} style={{ display: 'grid', gap: 14 }}>
      <Checkbox label="Session held" checked={held} onChange={(e) => setHeld(e.target.checked)} />
      <Field label="Completed this week" hint="One item per line.">
        <Textarea value={completed} onChange={(e) => setCompleted(e.target.value)} />
      </Field>
      <Field label="Action items / planned next week" hint="One item per line (owner and date in the text).">
        <Textarea value={planned} onChange={(e) => setPlanned(e.target.value)} />
      </Field>
      <Field label="Blockers">
        <Textarea value={blockers} onChange={(e) => setBlockers(e.target.value)} style={{ minHeight: 70 }} />
      </Field>
      <Field label="Session notes and decisions summary" hint="Formal decisions go to the ledger below.">
        <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} style={{ minHeight: 70 }} />
      </Field>
      {msg ? <Alert tone={msg.tone}>{msg.text}</Alert> : null}
      <div>
        <Button type="submit" disabled={busy} icon="save">
          {busy ? 'Saving…' : initial ? 'Update log' : 'Save log'}
        </Button>
      </div>
    </form>
  );
}

export function RecordDecisionForm({
  raidItems,
}: {
  raidItems: { id: string; type: string; description: string }[];
}) {
  const router = useRouter();
  const [raid, setRaid] = React.useState('');
  const [outcome, setOutcome] = React.useState('');
  const [minute, setMinute] = React.useState('');
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ tone: 'ok' | 'err'; text: string } | null>(null);

  if (!raidItems.length) {
    return <div className="muted">No open RAID items — raise one on the RAID log to record a decision against it.</div>;
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!raid || !outcome.trim()) {
      setMsg({ tone: 'err', text: 'Choose a RAID item and enter the outcome.' });
      return;
    }
    setBusy(true);
    setMsg(null);
    const err = await recordDecision(browserClient(), raid, outcome.trim(), minute.trim() || null);
    setBusy(false);
    setMsg(err ? { tone: 'err', text: err } : { tone: 'ok', text: 'Decision recorded.' });
    if (!err) {
      setOutcome('');
      setMinute('');
      router.refresh();
    }
  }

  return (
    <form onSubmit={onSubmit} style={{ display: 'grid', gap: 12 }}>
      <Field label="RAID item" required>
        <Select value={raid} onChange={(e) => setRaid(e.target.value)}>
          <option value="">Select…</option>
          {raidItems.map((r) => (
            <option key={r.id} value={r.id}>
              [{r.type}] {r.description.slice(0, 80)}
            </option>
          ))}
        </Select>
      </Field>
      <Field label="Outcome" required>
        <Textarea value={outcome} onChange={(e) => setOutcome(e.target.value)} style={{ minHeight: 60 }} />
      </Field>
      <Field label="Minute reference">
        <Input value={minute} onChange={(e) => setMinute(e.target.value)} placeholder="e.g. WS-12/3" />
      </Field>
      {msg ? <Alert tone={msg.tone}>{msg.text}</Alert> : null}
      <div>
        <Button type="submit" variant="secondary" disabled={busy} icon="gavel">
          {busy ? 'Recording…' : 'Record decision'}
        </Button>
      </div>
    </form>
  );
}
