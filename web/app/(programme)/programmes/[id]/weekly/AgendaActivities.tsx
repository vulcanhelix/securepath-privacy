'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Alert } from '@/components/ui/Alert';
import { Input, Select } from '@/components/ui/forms';
import { EmptyState } from '@/components/ui/EmptyState';
import { LocalDate } from './LocalDate';
import {
  ACTIVITY_STATUSES,
  needsRecoveryDate,
  notifyLeads,
  updateActivity,
} from './weekly-actions';

// W2-07 — one agenda section of activities with the FR-WKS-02 in-place
// actions (status, recovery date, notify lead, add to executive pack).
// FR-WKS-03: an Amber activity cannot be saved without a recovery date.

export interface AgendaActivity {
  id: string;
  ref: string;
  text: string;
  status: string;
  rag: string | null;
  start_week: number;
  end_week: number;
  due_date: string | null;
  recovery_date: string | null;
  leads: string[];
}

export function AgendaActivities({
  programmeId,
  week,
  activities,
  canWrite,
  empty,
}: {
  programmeId: string;
  week: number;
  activities: AgendaActivity[];
  canWrite: boolean;
  empty: string;
}) {
  if (!activities.length) return <EmptyState icon="check" message={empty} />;
  return (
    <div className="sp-table-scroll">
      <table className="sp-table">
        <thead>
          <tr>
            <th>Ref</th>
            <th>Activity</th>
            <th>Weeks</th>
            <th>Due</th>
            <th>Status</th>
            <th>RAG</th>
            <th>Recovery date</th>
            {canWrite ? <th>Actions</th> : null}
          </tr>
        </thead>
        <tbody>
          {activities.map((a) => (
            <ActivityRow key={a.id} a={a} programmeId={programmeId} week={week} canWrite={canWrite} />
          ))}
        </tbody>
      </table>
    </div>
  );
}

function ActivityRow({
  a,
  programmeId,
  week,
  canWrite,
}: {
  a: AgendaActivity;
  programmeId: string;
  week: number;
  canWrite: boolean;
}) {
  const router = useRouter();
  const [status, setStatus] = React.useState(a.status);
  const [recovery, setRecovery] = React.useState(a.recovery_date ?? '');
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ tone: 'ok' | 'err'; text: string } | null>(null);

  const dirty = status !== a.status || recovery !== (a.recovery_date ?? '');
  const blocked = needsRecoveryDate(a.rag, status, recovery || null);
  const amberNoDate = needsRecoveryDate(a.rag, a.status, a.recovery_date);

  async function run(fn: () => Promise<string | null>, ok: string, refresh = true) {
    setBusy(true);
    setMsg(null);
    const err = await fn();
    setBusy(false);
    setMsg(err ? { tone: 'err', text: err } : { tone: 'ok', text: ok });
    if (!err && refresh) router.refresh();
  }

  function save() {
    if (blocked) {
      setMsg({ tone: 'err', text: 'Amber activity: set a recovery date before saving (FR-WKS-03).' });
      return;
    }
    const payload: Record<string, unknown> = {};
    if (status !== a.status) payload.status = status;
    if (recovery && recovery !== a.recovery_date) payload.recovery_date = recovery;
    void run(() => updateActivity(browserClient(), a.id, payload), 'Saved');
  }

  return (
    <>
      <tr>
        <td className="mono">{a.ref}</td>
        <td>
          {a.text}
          {amberNoDate ? (
            <div style={{ marginTop: 4 }}>
              <Badge tone="warn">Needs recovery date</Badge>
            </div>
          ) : null}
        </td>
        <td className="mono">
          {a.start_week}–{a.end_week}
        </td>
        <td>
          <LocalDate value={a.due_date} />
        </td>
        <td>
          {canWrite ? (
            <Select
              value={status}
              onChange={(e) => setStatus(e.target.value)}
              disabled={busy}
              aria-label={`Status of ${a.ref}`}
            >
              {ACTIVITY_STATUSES.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </Select>
          ) : (
            <StatusPill status={a.status} />
          )}
        </td>
        <td>
          <RagBadge rag={a.rag} />
        </td>
        <td>
          {canWrite ? (
            <Input
              type="date"
              value={recovery}
              onChange={(e) => setRecovery(e.target.value)}
              disabled={busy}
              invalid={blocked}
              aria-label={`Recovery date for ${a.ref}`}
            />
          ) : (
            <LocalDate value={a.recovery_date} />
          )}
        </td>
        {canWrite ? (
          <td>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              <Button size="sm" onClick={save} disabled={busy || !dirty || blocked}>
                Save
              </Button>
              <Button
                size="sm"
                variant="ghost"
                icon="bell"
                disabled={busy}
                onClick={() =>
                  run(() => notifyLeads(browserClient(), programmeId, a, week), 'Lead notified', false)
                }
              >
                Notify lead
              </Button>
              {/* FR-WKS-02 "add to the executive pack" waits on an executive-pack
                  RPC — the executive view and pack belong to W2-13 (#38). */}
            </div>
          </td>
        ) : null}
      </tr>
      {msg ? (
        <tr>
          <td colSpan={canWrite ? 8 : 7}>
            <Alert tone={msg.tone}>{msg.text}</Alert>
          </td>
        </tr>
      ) : null}
    </>
  );
}
