// W4-00 — the slice of the TESTFIX world (app/supabase/migrations/
// 20261105000005_test_fixtures.sql) these browser tests rely on. Ids and labels
// are copied from that file; if the fixture pack changes, change them here.

export const P1 = 'dd000005-0000-0000-0000-000000000001'; // TESTFIX C1 POPIA Programme (Partner A / Client One)
export const P1_NAME = 'TESTFIX C1 POPIA Programme';
export const P3 = 'dd000005-0000-0000-0000-000000000003'; // Partner B / Client Three

/** EV3 — decided, closes R-04, carries evidence ref EV-R-04-001. */
export const EV_DECIDED = 'e1000005-0000-0000-0000-000000000003';

export type Role =
  | 'consultant' | 'ao' | 'alternate' | 'pl' | 'wsl' | 'partnerB'
  | 'support' | 'platformAdmin' | 'partnerA';

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
  // W4-01 support-access flow:
  // U3 — SecurePath support: dormant client-scope assignment on C1 + only an
  //      EXPIRED grant (AT-03); requests time-boxed access (AT-04)
  support: { id: 'aa000005-0000-0000-0000-000000000003', email: 'support@testfix.test', label: 'SecurePath support' },
  // U1 — SecurePath platform admin: revokes any grant
  platformAdmin: { id: 'aa000005-0000-0000-0000-000000000001', email: 'platform-admin@testfix.test', label: 'SecurePath platform admin' },
  // U4 — Partner A admin: decides C1's requests alongside the AO (FR-PLT-04)
  partnerA: { id: 'aa000005-0000-0000-0000-000000000004', email: 'partner-a-admin@testfix.test', label: 'Partner A admin' },
};

export const stateFile = (role: Role) => `e2e/.auth/${role}.json`;

/** Unique tag per test run, so assertions never match a previous run's rows. */
export const RUN = Date.now().toString(36);

