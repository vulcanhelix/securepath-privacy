import type { SupabaseClient } from '@supabase/supabase-js';
import { REGISTER_COLS, REGISTER_COLS_LEGACY, type RegisterItemRow } from './types';

// W2-16 — read helpers for the register (server side, caller's JWT, RLS T2).
// READ-ONLY: register writes go through RPCs in the client components.

/** register_items for a programme (or one item), retrying without the bridge
    provenance columns on environments where 20261106000011 is not applied. */
export async function loadRegisterItems(
  supabase: SupabaseClient,
  programmeId: string,
  itemId?: string
): Promise<{ items: RegisterItemRow[]; error: string | null }> {
  const run = (cols: string) => {
    let q = supabase.from('register_items').select(cols).eq('programme_id', programmeId);
    if (itemId) q = q.eq('id', itemId);
    return q.order('ref');
  };
  let { data, error } = await run(REGISTER_COLS);
  if (error && /source_(assessment_session_id|question_ref)/.test(error.message ?? '')) {
    ({ data, error } = await run(REGISTER_COLS_LEGACY));
  }
  const items = ((data ?? []) as unknown as Partial<RegisterItemRow>[]).map((r) => ({
    source_assessment_session_id: null,
    source_question_ref: null,
    ...r,
  })) as RegisterItemRow[];
  return { items, error: error?.message ?? null };
}

/** §9.3 engine values per item: register_item_rag + register_days_overdue
    (W1-01 rules engine). Falls back to the stored CALC column for days
    overdue if the RPC is unavailable; RAG then renders as unknown. */
export async function loadEngineValues(
  supabase: SupabaseClient,
  items: RegisterItemRow[]
): Promise<Record<string, { rag: string | null; daysOverdue: number | null }>> {
  const rows = await Promise.all(
    items.map(async (i) => {
      const [rag, overdue] = await Promise.all([
        supabase.rpc('register_item_rag', { p_item: i.id }),
        supabase.rpc('register_days_overdue', { p_item: i.id }),
      ]);
      return [
        i.id,
        {
          rag: rag.error ? null : ((rag.data as string | null) ?? null),
          daysOverdue: overdue.error ? i.days_overdue : ((overdue.data as number | null) ?? null),
        },
      ] as const;
    })
  );
  return Object.fromEntries(rows);
}
