import type { SupabaseClient } from '@supabase/supabase-js';

// ---------------------------------------------------------------------------
// W2-05 — write helpers for the schedule screen. Primary path is the W1-05
// lifecycle RPCs (migration 20261106000008): they enforce the FR-SCH-04
// predecessor gate, ref uniqueness, week bounds and recompute every CALC
// column (start_date/due_date/month/phase/rag) in the same call.
//
// While that migration is unapplied on an environment the RPCs 404 — same
// situation lib/programme.ts handles for list_programmes. The fallback then
// writes the RLS-permitted columns directly (activities_insert/_update +
// column grants) and best-effort calls recompute_programme_progress so CALC
// columns refresh; a caller without the programme write role can't recompute,
// which mirrors the RPC gate anyway.
// ---------------------------------------------------------------------------

function isMissingFunction(err: { code?: string; message?: string } | null): boolean {
  if (!err) return false;
  return (
    err.code === 'PGRST202' ||
    err.code === '42883' ||
    /could not find the function|does not exist/i.test(err.message ?? '')
  );
}

/** merge-style field update — update_activity(uuid, jsonb) */
export async function updateActivity(
  supabase: SupabaseClient,
  programmeId: string,
  activityId: string,
  payload: Record<string, unknown>
): Promise<string | null> {
  const { error } = await supabase.rpc('update_activity', {
    p_activity_id: activityId,
    p_payload: payload,
  });
  if (!error) return null;
  if (!isMissingFunction(error)) return error.message;

  const { error: tErr } = await supabase
    .from('activities')
    .update(payload)
    .eq('id', activityId);
  if (tErr) return tErr.message;
  // best effort — CALC columns (rag etc.) refresh if the caller can recompute
  await supabase.rpc('recompute_programme_progress', { p_programme: programmeId });
  return null;
}

/** schedule reposition — reorder_activity(uuid, int, int, uuid) */
export async function reorderActivity(
  supabase: SupabaseClient,
  programmeId: string,
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
  if (!error) return null;
  if (!isMissingFunction(error)) return error.message;

  const patch: Record<string, unknown> = { start_week: startWeek, end_week: endWeek };
  if (workstreamId) patch.workstream_id = workstreamId; // RPC can't clear it either
  const { error: tErr } = await supabase.from('activities').update(patch).eq('id', activityId);
  if (tErr) return tErr.message;
  await supabase.rpc('recompute_programme_progress', { p_programme: programmeId });
  return null;
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
}

/** add_activity(uuid, text, text, uuid, int, int, bool, bool, uuid[], uuid[]) */
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
    p_leads: [],
  });
  if (!error) return null;
  if (!isMissingFunction(error)) return error.message;

  const { data: row, error: iErr } = await supabase
    .from('activities')
    .insert({
      programme_id: programmeId,
      workstream_id: a.workstreamId,
      ref: a.ref,
      text: a.text,
      start_week: a.startWeek,
      end_week: a.endWeek,
      milestone: a.milestone,
      evidence_required: a.evidenceRequired,
    })
    .select('id')
    .single();
  if (iErr) return iErr.message;
  if (a.predecessorIds.length) {
    const { error: dErr } = await supabase.from('activity_deps').insert(
      a.predecessorIds.map((p) => ({ activity_id: row.id, depends_on_activity_id: p }))
    );
    if (dErr) return dErr.message;
  }
  await supabase.rpc('recompute_programme_progress', { p_programme: programmeId });
  return null;
}
