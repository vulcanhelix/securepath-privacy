import { test, expect, type Page, type APIRequestContext } from '@playwright/test';
import { P1, P1_NAME, P3, RUN, USERS, stateFile } from './fixtures';

// W4-01 — support access end to end (spec §4.1/§7.5 FR-PLT-04 + NFR-04,
// AT-03/AT-04): request → client-side approve → time-boxed visibility of
// exactly the granted client → revoke AND expiry both end it → every action
// in audit_log. Driven through the real UI everywhere a screen exists:
//   · request: /platform/support (W2-14 form)
//   · approve / decline / revoke: /programmes/[id]/access (this PR's screen)
//   · visibility: /programmes, /programmes/[id], /clients/[id]
// The only out-of-band steps are service-role REST calls (the throwaway CI
// key): backdating one grant's window to prove expiry closes access, and
// reading audit_log/notification_events — neither table has an authenticated
// write/read path by design (service is the ops view of them).

const C1 = 'cc000005-0000-0000-0000-000000000001'; // TESTFIX Client One (ZA) — Partner A
const C3 = 'cc000005-0000-0000-0000-000000000003'; // TESTFIX Client Three — Partner B

const BASE = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:8080';
const SERVICE = process.env.E2E_SERVICE_KEY ?? '';

const REASONS = {
  approve: `W4-01 approve ${RUN}`,
  expire: `W4-01 expire ${RUN}`,
  decline: `W4-01 decline ${RUN}`,
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/** Submit one access request on /platform/support through the real form. */
async function requestAccess(page: Page, reason: string) {
  await page.goto('/platform/support');
  const field = (label: string) =>
    page.locator('.sp-field', { has: page.locator('.sp-field-label', { hasText: label }) });
  await field('Client').locator('select').selectOption({ label: 'TESTFIX Client One (ZA) · TESTFIX Partner A' });
  await field('Access window').locator('select').selectOption({ label: '4 hours' });
  await field('Reason').locator('textarea').fill(reason);
  await page.getByRole('button', { name: 'Request access' }).click();
  await expect(page.getByText(/Request sent\./)).toBeVisible();
  // the new request is listed, pending
  const requests = page.locator('section.sp-card', { has: page.locator('h2', { hasText: 'Requests' }) });
  await expect(requests.locator('tr', { hasText: reason })).toContainText('pending');
}

/** Row in a card containing `text`, for table assertions. */
const rowWith = (page: Page, cardTitle: string, text: string) =>
  page
    .locator('section.sp-card', { has: page.locator('h2', { hasText: cardTitle }) })
    .locator('tr', { hasText: text });

/** Service-role REST read — audit/notification tables have no app read path. */
async function serviceGet(request: APIRequestContext, path: string) {
  const res = await request.get(`${BASE}/rest/v1/${path}`, {
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` },
  });
  expect(res.ok(), `GET ${path}: ${res.status()} ${await res.text()}`).toBeTruthy();
  return res.json();
}

async function servicePatch(request: APIRequestContext, path: string, body: unknown) {
  const res = await request.fetch(`${BASE}/rest/v1/${path}`, {
    method: 'PATCH',
    headers: {
      apikey: SERVICE,
      Authorization: `Bearer ${SERVICE}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    data: body,
  });
  expect(res.ok(), `PATCH ${path}: ${res.status()} ${await res.text()}`).toBeTruthy();
}

/** support_access_requests row ids for our RUN-tagged reasons (service view). */
async function requestIds(request: APIRequestContext): Promise<Record<string, string>> {
  const rows = (await serviceGet(
    request,
    `support_access_requests?select=id,reason,grant_id&reason=like.*${encodeURIComponent(RUN)}*`
  )) as { id: string; reason: string; grant_id: string | null }[];
  const out: Record<string, string> = {};
  for (const [k, reason] of Object.entries(REASONS)) {
    const row = rows.find((r) => r.reason === reason);
    expect(row, `request row for ${k}`).toBeTruthy();
    out[k] = row!.id;
    if (row!.grant_id) out[`${k}Grant`] = row!.grant_id;
  }
  return out;
}

// ---------------------------------------------------------------------------
// the flow — one fixture world, strict order
// ---------------------------------------------------------------------------

test.describe.configure({ mode: 'serial' });

test('AT-03: no grant, no client data — support requests a window through the UI', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('support') });
  const page = await ctx.newPage();

  // before any grant: the client's data is invisible every way in
  expect((await page.goto(`/clients/${C1}`))?.status(), 'client workspace without grant').not.toBe(200);
  expect((await page.goto(`/programmes/${P1}`))?.status(), 'programme without grant').not.toBe(200);
  expect((await page.goto('/programmes'))?.status()).toBe(200);
  await expect(page.locator(`a[href="/programmes/${P1}"]`)).toHaveCount(0);

  // request three windows through the real form: one to approve+revoke,
  // one to approve+expire, one to decline
  for (const reason of [REASONS.approve, REASONS.expire, REASONS.decline]) {
    await requestAccess(page, reason);
  }
  await ctx.close();
});

test('AO approves on the client screen — support then sees only that client', async ({ browser, request }) => {
  // 1. the accountable officer decides on the client-facing ledger screen
  const aoCtx = await browser.newContext({ storageState: stateFile('ao') });
  const ao = await aoCtx.newPage();
  expect((await ao.goto(`/programmes/${P1}/access`))?.status()).toBe(200);
  const row = rowWith(ao, 'Requests', REASONS.approve);
  await expect(row).toContainText('pending');
  await row.getByRole('button', { name: 'Approve' }).click();
  await expect(row).toContainText('approved');
  // the coupled grant is minted atomically — it appears in the ledger at once
  await expect(rowWith(ao, 'Grants', REASONS.approve)).toContainText('active');
  await aoCtx.close();

  // 2. in the window: the granted client's screens open — and only theirs
  const supCtx = await browser.newContext({ storageState: stateFile('support') });
  const page = await supCtx.newPage();
  expect((await page.goto('/programmes'))?.status()).toBe(200);
  await expect(page.locator(`a[href="/programmes/${P1}"]`).first()).toBeVisible();
  expect((await page.goto(`/programmes/${P1}`))?.status()).toBe(200);
  await expect(page.locator('h1.sp-pagehd-title')).toHaveText(P1_NAME);
  await expect(page.locator('.sp-ctx-crumb')).toContainText('TESTFIX Client One (ZA)');
  expect((await page.goto(`/clients/${C1}`))?.status()).toBe(200);
  // and ONLY that client — partner B's client stays invisible both ways
  expect((await page.goto(`/programmes/${P3}`))?.status(), 'other partner programme during grant').not.toBe(200);
  expect((await page.goto(`/clients/${C3}`))?.status(), 'other client workspace during grant').not.toBe(200);

  // 3. the grant holder sees the same client-visible ledger — the approve/
  //    decline affordance is never theirs (platform staff cannot decide)
  expect((await page.goto(`/programmes/${P1}/access`))?.status()).toBe(200);
  await expect(rowWith(page, 'Grants', REASONS.approve)).toContainText('SecurePath support (you)');
  await expect(page.getByRole('button', { name: 'Approve' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Decline' })).toHaveCount(0);
  await expect(rowWith(page, 'Grants', REASONS.approve).getByRole('button', { name: 'Revoke' })).toBeVisible();
  await supCtx.close();
});

test('revoke ends the window immediately', async ({ browser }) => {
  // 1. the AO ends the live grant early through the same screen
  const aoCtx = await browser.newContext({ storageState: stateFile('ao') });
  const ao = await aoCtx.newPage();
  await ao.goto(`/programmes/${P1}/access`);
  ao.once('dialog', (d) => void d.accept());
  await rowWith(ao, 'Grants', REASONS.approve).getByRole('button', { name: 'Revoke' }).click();
  await expect(rowWith(ao, 'Grants', REASONS.approve)).toContainText('revoked');
  await aoCtx.close();

  // 2. the support user loses it all at once — list, programme, workspace
  const supCtx = await browser.newContext({ storageState: stateFile('support') });
  const page = await supCtx.newPage();
  expect((await page.goto('/programmes'))?.status()).toBe(200);
  await expect(page.locator(`a[href="/programmes/${P1}"]`)).toHaveCount(0);
  expect((await page.goto(`/programmes/${P1}`))?.status(), 'programme after revoke').not.toBe(200);
  expect((await page.goto(`/clients/${C1}`))?.status(), 'workspace after revoke').not.toBe(200);
  // the dormant assignment is still there — it must never suffice on its own
  expect((await page.goto(`/programmes/${P1}/access`))?.status(), 'ledger after revoke').not.toBe(200);
  await supCtx.close();
});

test('expiry ends the window too — partner_admin approver leg', async ({ browser, request }) => {
  // 1. the other FR-PLT-04 approver class: the owning partner's admin
  const paCtx = await browser.newContext({ storageState: stateFile('partnerA') });
  const pa = await paCtx.newPage();
  expect((await pa.goto(`/programmes/${P1}/access`))?.status()).toBe(200);
  const row = rowWith(pa, 'Requests', REASONS.expire);
  await row.getByRole('button', { name: 'Approve' }).click();
  await expect(rowWith(pa, 'Grants', REASONS.expire)).toContainText('active');
  await paCtx.close();

  // 2. inside the window the grant works
  const supCtx = await browser.newContext({ storageState: stateFile('support') });
  const page = await supCtx.newPage();
  expect((await page.goto(`/clients/${C1}`))?.status()).toBe(200);

  // 3. the clock runs out: backdate the window through the service path
  //    (no clock injection exists — NFR-04 expiry is derived live; this is
  //    the "test-only SQL step" the issue allows, done over REST with the
  //    throwaway service key because grants have no authenticated writes)
  const ids = await requestIds(request);
  const past = (h: number) => new Date(Date.now() - h * 3600_000).toISOString();
  await servicePatch(request, `support_access_grants?id=eq.${ids.expireGrant}`, {
    starts_at: past(2),
    expires_at: past(1),
  });

  // 4. visibility is gone on the next read — nothing needs to run
  await page.goto('/programmes');
  await expect(page.locator(`a[href="/programmes/${P1}"]`)).toHaveCount(0);
  expect((await page.goto(`/clients/${C1}`))?.status(), 'workspace after expiry').not.toBe(200);
  expect((await page.goto(`/programmes/${P1}`))?.status(), 'programme after expiry').not.toBe(200);
  await supCtx.close();

  // 5. the client ledger records the end state
  const aoCtx = await browser.newContext({ storageState: stateFile('ao') });
  const ao = await aoCtx.newPage();
  await ao.goto(`/programmes/${P1}/access`);
  await expect(rowWith(ao, 'Grants', REASONS.expire)).toContainText('expired');
  await aoCtx.close();
});

test('decline is a recorded refusal — no access is ever opened', async ({ browser }) => {
  // 1. partner admin declines with a note through the real UI
  const paCtx = await browser.newContext({ storageState: stateFile('partnerA') });
  const pa = await paCtx.newPage();
  await pa.goto(`/programmes/${P1}/access`);
  pa.once('dialog', (d) => void d.accept('W4-01 no access needed'));
  await rowWith(pa, 'Requests', REASONS.decline).getByRole('button', { name: 'Decline' }).click();
  await expect(rowWith(pa, 'Requests', REASONS.decline)).toContainText('declined');
  await expect(rowWith(pa, 'Requests', REASONS.decline).getByRole('button')).toHaveCount(0);
  await paCtx.close();

  // 2. nothing opened for the requester — and the decision shows on their
  //    platform queue too
  const supCtx = await browser.newContext({ storageState: stateFile('support') });
  const page = await supCtx.newPage();
  expect((await page.goto(`/clients/${C1}`))?.status(), 'workspace after decline').not.toBe(200);
  await page.goto('/platform/support');
  await expect(rowWith(page, 'Requests', REASONS.decline)).toContainText('declined');
  await supCtx.close();
});

test('audit: every support-access action lands in audit_log + notifications', async ({ request }) => {
  const ids = await requestIds(request);

  const audit = (await serviceGet(
    request,
    'audit_log?select=action,user_id,practice_id,detail&action=like.support_access.*&order=id.asc'
  )) as { action: string; user_id: string; practice_id: string; detail: Record<string, string> }[];

  const byAction = (action: string, requestId?: string) =>
    audit.filter(
      (a) =>
        a.action === action &&
        a.practice_id === 'bb000005-0000-0000-0000-000000000001' && // Partner A
        (!requestId || a.detail?.request_id === requestId)
    );

  const supportId = USERS.support.id;
  // one 'requested' row per request, written by the support user with the reason
  for (const key of ['approve', 'expire', 'decline']) {
    const rows = byAction('support_access.requested', ids[key]);
    expect(rows, `audit requested ${key}`).toHaveLength(1);
    expect(rows[0].user_id).toBe(supportId);
    expect(rows[0].detail.reason).toContain('W4-01');
  }
  // approvals: AO wrote approveGrant, partner admin wrote expireGrant —
  // each carrying BOTH ids because the grant was minted in the same call.
  // (counts are keyed to this run's ids — earlier runs of this spec leave
  // their own rows on the same fixture partner)
  expect(byAction('support_access.approved', ids.approve)).toHaveLength(1);
  expect(byAction('support_access.approved', ids.approve)[0].user_id).toBe(USERS.ao.id);
  expect(byAction('support_access.approved', ids.approve)[0].detail.grant_id).toBe(ids.approveGrant);
  expect(byAction('support_access.approved', ids.expire)).toHaveLength(1);
  expect(byAction('support_access.approved', ids.expire)[0].user_id).toBe(USERS.partnerA.id);
  // revocation by the AO names the grant
  const revoked = audit.filter(
    (a) => a.action === 'support_access.revoked' && a.detail?.grant_id === ids.approveGrant
  );
  expect(revoked).toHaveLength(1);
  expect(revoked[0].user_id).toBe(USERS.ao.id);
  expect(revoked[0].detail.grant_id).toBe(ids.approveGrant);
  // the decline is recorded too (with the note) — refusal, not silence
  const declined = byAction('support_access.declined', ids.decline);
  expect(declined).toHaveLength(1);
  expect(declined[0].user_id).toBe(USERS.partnerA.id);
  expect(declined[0].detail.note).toBe('W4-01 no access needed');

  // each action also fanned out a notification_event for mail/in-app
  const events = (await serviceGet(
    request,
    'notification_events?select=kind&kind=like.support_access*'
  )) as { kind: string }[];
  for (const kind of [
    'support_access_requested',
    'support_access_granted',
    'support_access_revoked',
    'support_access_declined',
  ]) {
    expect(events.filter((e) => e.kind === kind).length, `notification ${kind}`).toBeGreaterThanOrEqual(1);
  }
});
