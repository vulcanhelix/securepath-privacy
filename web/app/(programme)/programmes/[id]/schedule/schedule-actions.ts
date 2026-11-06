import type { SupabaseClient } from '@supabase/supabase-js';

// ---------------------------------------------------------------------------
// W2-05 — write helpers for the schedule screen. RPC-ONLY by design: the W1-05
// lifecycle RPCs (migration 20261106000008) are the sole write path because
// they enforce what no table constraint does — ref uniqueness, week bounds,
// same-programme workstream/dependency checks, the payload allowlist, the
// FR-SCH-04 predecessor-override rule, the initial status-history row,
// audit_log entries — and recompute every CALC column in the same call.
//
// There is deliberately NO direct-table fallback. If an RPC is missing or
// rejects the call, its error message is returned for the UI to surface and
// nothing is written.
// ---------------------------------------------------------------------------

function rpcError(err: { code?: string; message?: string } | null, fn: string): string | null {
  if (!err) return null;
  if (err.code === 'PGRST202' || err.code === '42883') {
    return `${fn} is not available on this environment (migration 20261106000008 not applied) — nothing was changed.`;
  }
  return err.message ?? `${fn} failed — nothing was changed.`;
}

/** merge-style field update — update_activity(uuid, jsonb) */
export async function updateActivity(
  supabase: SupabaseClient,
  activityId: string,
  payload: Record<string, unknown>
): Promise<string | null> {
  const { error } = await supabase.rpc('update_activity', {
    p_activity_id: activityId,
    p_payload: payload,
  });
  return rpcError(error, 'update_activity');
}

/** schedule reposition — reorder_activity(uuid, int, int, uuid) */
export async function reorderActivity(
  supabase: SupabaseClient,
  activityId: string,
  startWeek: number,
  endWeek: number,
  workstreamId: string | null
): Promise<string | null> {
  const { error } = await supabase.rpc('reorder_activity', {
    p_activity_id: activityId,
    p_start_week: startWeek,
    p_end_week: endWeek,
    p_workstream_id: workstreamId,
  });
  return rpcError(error, 'reorder_activity');
}

export interface NewActivity {
  ref: string;
  text: string;
  workstreamId: string | null;
  startWeek: number;
  endWeek: number;
  milestone: boolean;
  evidenceRequired: boolean;
  predecessorIds: string[];
  leads: string[];
}

/** add_activity(uuid, text, text, uuid, int, int, bool, bool, uuid[] deps, uuid[] leads) */
export async function addActivity(
  supabase: SupabaseClient,
  programmeId: string,
  a: NewActivity
): Promise<string | null> {
  const { error } = await supabase.rpc('add_activity', {
    p_programme_id: programmeId,
    p_ref: a.ref,
    p_text: a.text,
    p_workstream_id: a.workstreamId,
    p_start_week: a.startWeek,
    p_end_week: a.endWeek,
    p_milestone: a.milestone,
    p_evidence_required: a.evidenceRequired,
    p_dependencies: a.predecessorIds,
    p_leads: a.leads,
  });
  return rpcError(error, 'add_activity');
}
