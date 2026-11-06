import type { SupabaseClient } from '@supabase/supabase-js';

// ---------------------------------------------------------------------------
// W2-07 — write helpers for the weekly session screen (spec §8.5, screen 04).
//
// HARD RULE: writes go ONLY through the RPCs. There is deliberately NO direct
// table fallback (unlike the W2-05 schedule helpers): the RPCs carry the
// server-side validation (role gate, week bounds, CALC counts/RAG, decision
// ledger append-only, audit rows). A missing RPC surfaces as an error.
// ---------------------------------------------------------------------------

type PgErr = { code?: string; message?: string } | null;

function isMissingFunction(err: PgErr): boolean {
  if (!err) return false;
  return (
    err.code === 'PGRST202' ||
    err.code === '42883' ||
    /could not find the function|does not exist/i.test(err.message ?? '')
  );
}

function errText(fn: string, err: PgErr): string | null {
  if (!err) return null;
  if (isMissingFunction(err)) {
    return `${fn} is not available on this environment (RPC missing) — nothing was saved.`;
  }
  return err.message ?? `${fn} failed`;
}

/** FR-WKS-04 — upsert_weekly_log(uuid, int, jsonb); counts + week_rag are engine CALC */
export async function upsertWeeklyLog(
  supabase: SupabaseClient,
  programmeId: string,
  week: number,
  payload: {
    session_held: boolean;
    completed: string[];
    planned_next: string[];
    blockers: string;
    decisions: string;
  }
): Promise<string | null> {
  const { error } = await supabase.rpc('upsert_weekly_log', {
    p_programme_id: programmeId,
    p_week_no: week,
    p_payload: payload,
  });
  return errText('upsert_weekly_log', error);
}

/** FR-RAI-03 — record_decision is keyed on raid_item_id (W1-06 schema deviation) */
export async function recordDecision(
  supabase: SupabaseClient,
  raidItemId: string,
  outcome: string,
  minuteRef: string | null
): Promise<string | null> {
  const { error } = await supabase.rpc('record_decision', {
    p_raid_item_id: raidItemId,
    p_outcome: outcome,
    p_minute_ref: minuteRef,
    p_unlocks: [],
    p_decided_on: null,
  });
  return errText('record_decision', error);
}

/** FR-WKS-02 — status / recovery date via update_activity(uuid, jsonb) (W1-05) */
export async function updateActivity(
  supabase: SupabaseClient,
  activityId: string,
  payload: Record<string, unknown>
): Promise<string | null> {
  const { error } = await supabase.rpc('update_activity', {
    p_activity_id: activityId,
    p_payload: payload,
  });
  return errText('update_activity', error);
}

/** FR-WKS-02 — notify the lead(s) via the W1-08 canonical emitter */
export async function notifyLeads(
  supabase: SupabaseClient,
  programmeId: string,
  activity: { id: string; ref: string; text: string; leads: string[] },
  week: number
): Promise<string | null> {
  if (!activity.leads.length) return 'This activity has no lead to notify.';
  const { error } = await supabase.rpc('queue_notification', {
    p_kind: 'weekly_session_followup',
    p_scope: { programme_id: programmeId },
    p_payload: {
      activity_id: activity.id,
      ref: activity.ref,
      text: activity.text,
      week,
      recipients: activity.leads,
    },
  });
  return errText('queue_notification', error);
}

// FR-WKS-02 "add to the executive pack" waits on an executive-pack RPC
// (executive view + pack belong to W2-13, #38) — no helper until it exists.

/** FR-WKS-03 — an Amber activity cannot be saved from the session without a
    recovery date. update_activity does not enforce this server-side yet, so
    the session UI is the gate (see PR notes). */
export function needsRecoveryDate(
  rag: string | null,
  newStatus: string,
  recoveryDate: string | null | undefined
): boolean {
  const amber = rag === 'Amber' || newStatus === 'At risk';
  return amber && newStatus !== 'Complete' && !recoveryDate;
}

export const ACTIVITY_STATUSES = [
  'Not started',
  'In progress',
  'At risk',
  'Blocked',
  'Deferred',
  'Complete',
] as const;
