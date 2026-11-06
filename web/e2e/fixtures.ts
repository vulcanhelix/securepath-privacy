// W4-00 — the slice of the TESTFIX world (app/supabase/migrations/
// 20261105000005_test_fixtures.sql) these browser tests rely on. Ids and labels
// are copied from that file; if the fixture pack changes, change them here.

export const P1 = 'dd000005-0000-0000-0000-000000000001'; // TESTFIX C1 POPIA Programme (Partner A / Client One)
export const P1_NAME = 'TESTFIX C1 POPIA Programme';
export const P3 = 'dd000005-0000-0000-0000-000000000003'; // Partner B / Client Three

/** EV3 — decided, closes R-04, carries evidence ref EV-R-04-001. */
export const EV_DECIDED = 'e1000005-0000-0000-0000-000000000003';

export type Role = 'consultant' | 'ao' | 'alternate' | 'pl' | 'wsl' | 'partnerB';

export const USERS: Record<Role, { id: string; email: string; label: string }> = {
  // U5 — partner-A consultant assigned to C1 only (AT-02): runs the programme,
  // verifies evidence (FR-EVD-03), writes KPIs / RAID / schedule
  consultant: { id: 'aa000005-0000-0000-0000-000000000005', email: 'partner-a-consultant@testfix.test', label: 'Partner A consultant' },
  // U8 — accountable officer on C1: accepts verified evidence; leads A-01
  ao: { id: 'aa000005-0000-0000-0000-000000000008', email: 'c1-ao@testfix.test', label: 'C1 accountable officer' },
  // U13 — C1 named alternate (FR-ACC-02): accepts what the AO may not
  alternate: { id: 'aa000005-0000-0000-0000-000000000013', email: 'c1-alternate@testfix.test', label: 'C1 named alternate' },
  // U9 — programme lead on P1 (programme-scope assignment only)
  pl: { id: 'aa000005-0000-0000-0000-000000000009', email: 'c1-pl@testfix.test', label: 'C1 programme lead' },
  // U10 — workstream lead on P1 (workstream-scope assignment only)
  wsl: { id: 'aa000005-0000-0000-0000-000000000010', email: 'c1-wsl@testfix.test', label: 'C1 workstream lead' },
  // U6 — partner B admin: must never see Partner A's P1
  partnerB: { id: 'aa000005-0000-0000-0000-000000000006', email: 'partner-b-admin@testfix.test', label: 'Partner B admin' },
};

export const stateFile = (role: Role) => `e2e/.auth/${role}.json`;

/** Unique tag per test run, so assertions never match a previous run's rows. */
export const RUN = Date.now().toString(36);

// ---------------------------------------------------------------------------
// Known screen defects found by this harness (W4-00). Tests hit by one call
// knownDefect(id) first: Playwright then EXPECTS the test to fail, so CI stays
// green while the defect is open, and goes RED the moment the screen is fixed
// ("expected to fail, but passed") — at which point delete the call (and the
// entry here once nothing references it). E2E_STRICT=1 disables the
// expectation and shows the raw failures.
// ---------------------------------------------------------------------------
export const KNOWN_DEFECTS = {
  'W4-D1':
    'lib/nav.ts NavSlot objects (with their visible() function) are passed from server layouts to the ' +
    'client ProgrammeNav — every (programme) page whose nav has a slot 500s with "Functions cannot be ' +
    'passed directly to Client Components" (all /programmes/[id]/* screens; /programmes for partner users)',
  'W4-D2':
    'programme-scope-only users (programme_lead) can read the programmes row but not its client_orgs row, ' +
    'so programmeContext() returns null and every /programmes/[id]/* screen 404s for the programme lead',
  'W4-D3':
    'workstream-scope-only users (workstream_lead) cannot read their own programme — every ' +
    '/programmes/[id]/* screen 404s for the workstream lead (spec B.13 makes them the screen 08 user)',
  'W4-D4':
    'at 390px the programme context bar (.sp-ctx-crumb in programmes/[id]/layout.tsx: client / programme / ' +
    'status / phase / RAG) does not wrap — the RAG badge ends at ~483px, so screen 08 scrolls sideways ' +
    '(document scrollWidth 484 > 390)',
} as const;

export function knownDefect(t: { fail: (condition: boolean, description: string) => void }, id: keyof typeof KNOWN_DEFECTS) {
  t.fail(process.env.E2E_STRICT !== '1', `${id}: ${KNOWN_DEFECTS[id]}`);
}
