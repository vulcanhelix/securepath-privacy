// Propose which checklist slot an uploaded document fills, by matching the filename
// against slot names. Content-driven: it reasons over the checklist rows, encodes nothing.
// ponytail: filename/keyword heuristic — a document could be misnamed. Upgrade path: a
// Claude content-classifier that reads the document body when the extra accuracy is worth
// the API cost. Until then the advisor confirms every proposal, so a wrong guess is cheap.

// tokens that appear across many slots (category words) — shared, but not distinctive
const GENERIC = new Set(['policy', 'register', 'procedure', 'agreement', 'notice', 'document',
  'documents', 'records', 'record', 'plan', 'manual', 'schedule', 'log', 'letter', 'certificate',
  'and', 'or', 'the', 'of', 'for', 'a', 'to', 'with', 'external', 'internal', 'signed', 'published',
  'data', 'information', 'personal']);   // domain-generic: appear across most slot names

function tokens(s: string): string[] {
  return s.toLowerCase().replace(/\.[a-z0-9]+$/, '')       // drop extension
    .split(/[^a-z0-9]+/).filter(t => t.length > 1);
}

export type Slot = { id: string; name: string; slot_key: string };

// Returns the best slot + a confidence in [0,1], or null if nothing matches well enough.
export function proposeSlot(filename: string, checklist: Slot[]): { id: string; confidence: number } | null {
  const fileTok = new Set(tokens(filename));
  if (fileTok.size === 0) return null;

  let best: { id: string; distinct: number; total: number } | null = null;
  for (const slot of checklist) {
    const slotTok = new Set([...tokens(slot.name), ...slot.slot_key.split('_')]);
    let distinct = 0, total = 0;
    for (const t of slotTok) {
      if (fileTok.has(t)) { total++; if (!GENERIC.has(t)) distinct++; }
    }
    if (!best || distinct > best.distinct || (distinct === best.distinct && total > best.total)) {
      best = { id: slot.id, distinct, total };
    }
  }
  // require at least one distinctive shared word (so "policy.pdf" won't match a specific slot)
  if (!best || best.distinct < 1) return null;
  const confidence = Math.min(1, 0.5 + 0.25 * best.distinct);
  return { id: best.id, confidence };
}

// ponytail self-check: run with `node --import tsx lib/classify.ts` or via a test runner.
export function demo() {
  const cl: Slot[] = [
    { id: 'a', name: 'PAIA Manual (s.51, published)', slot_key: 'paia_manual' },
    { id: 'b', name: 'Privacy Policy (external, published)', slot_key: 'privacy_policy' },
    { id: 'c', name: 'Data Retention & Disposal Schedule', slot_key: 'retention_schedule' },
    { id: 'd', name: 'Breach notification procedure & templates', slot_key: 'breach_procedure' },
  ];
  const eq = (f: string, want: string | null) => {
    const r = proposeSlot(f, cl);
    const got = r?.id ?? null;
    if (got !== want) throw new Error(`proposeSlot(${f}) = ${got}, want ${want}`);
  };
  eq('PAIA Manual.pdf', 'a');
  eq('Privacy Policy.pdf', 'b');
  eq('Retention Schedule 2026.xlsx', 'c');
  eq('data breach response.docx', 'd');
  eq('policy.pdf', null);          // generic-only → no confident match
  eq('random invoice.pdf', null);  // nothing matches
  console.log('classify demo: PASS');
}
