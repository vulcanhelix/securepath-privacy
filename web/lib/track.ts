import type { SupabaseClient } from '@supabase/supabase-js';

// track_kind comes from the frameworks registry — single source of truth,
// so a new framework needs zero code change here.
export async function trackKindFor(supabase: SupabaseClient, framework: string): Promise<'privacy' | 'cyber'> {
  const { data } = await supabase.from('frameworks').select('track_kind').eq('key', framework).maybeSingle();
  return (data?.track_kind as 'privacy' | 'cyber') ?? 'privacy';
}
