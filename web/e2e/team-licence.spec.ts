import { test, expect } from '@playwright/test';
import { RUN, stateFile } from './fixtures';

// W2-17 — partner team + licence usage (spec §7.5 FR-LIC-01, §7.6
// FR-TEAM-01/02): the admin's /team screen invites through the W2-14
// create_invite path (pending row appears, seat counter moves), the licence
// tile shows usage vs cap from usage_report, the /licences page surfaces the
// W1-07 licence_warning notifications, and a non-admin neither sees the
// invite affordance nor can drive it through the API.
//
// Fixture: TESTFIX Partner A (licence 2 clients / 2 programmes — fully used,
// AT-07) administered by U4 partnerA; U5 consultant holds only a client-scope
// row (AT-02) and must never reach owner-only paths.

const BASE = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:8080';
const SERVICE = process.env.E2E_SERVICE_KEY ?? '';

test.describe.configure({ mode: 'serial' });

test('partner admin: licence tile shows usage vs cap; invite creates a pending row', async ({ browser, request }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctx.newPage();

  await page.goto('/team');
  await expect(page.locator('h1.sp-pagehd-title')).toHaveText('Team & licence');

  // FR-LIC-01 tile — Partner A's TESTFIX Standard shows usage vs cap. The
  // exact numbers depend on suite order: onboarding.spec bumps the caps to
  // 10 and adds a client earlier in the run, so assert the rendered
  // usage/cap pair, not the fixture values (at-cap enforcement itself is
  // proven server-side by e2e_licences_grants.sql's capacity checks, AT-07).
  const licence = page.locator('section.sp-card', { has: page.locator('h2', { hasText: 'Licence' }) }).first();
  await expect(licence).toContainText('TESTFIX Standard');
  await expect(licence).toContainText(/Clients: \d+ \/ \d+/);
  await expect(licence).toContainText(/Programmes: \d+ \/ \d+/);
  await expect(page.locator('section.sp-card', { has: page.locator('h2', { hasText: 'Team seats' }) })).toContainText('/ 5');

  // admin sees the whole roster incl. the client-scoped consultant
  await expect(page.locator('tr', { hasText: 'partner-a-consultant@testfix.test' })).toContainText('TESTFIX Client One');

  // FR-TEAM-01 invite — through the real form, W2-14 create_invite allowlist
  const email = `w217-consultant-${RUN}@testfix.test`;
  await page.locator('section.sp-card', { has: page.locator('h2', { hasText: 'Invite a team member' }) })
    .locator('input[type="email"]').fill(email);
  await page.getByRole('button', { name: 'Send invite' }).click();
  await expect(page.getByText(`Invite sent to ${email}`)).toBeVisible();

  // the row lands in Pending invites (and the seat counter counts it)
  const pending = page.locator('section.sp-card', { has: page.locator('h2', { hasText: 'Pending invites' }) });
  await expect(pending.locator('tr', { hasText: email })).toContainText('Consultant');

  // revoke it again through the W2-17 RPC — pending row disappears
  page.once('dialog', (d) => void d.accept());
  await pending.locator('tr', { hasText: email }).getByRole('button', { name: 'Revoke' }).click();
  await expect(pending.locator('tr', { hasText: email })).toHaveCount(0);

  // FR-LIC-01 detail page — usage vs cap + the W1-07 warning surface
  await page.goto('/licences');
  await expect(page.locator('h1.sp-pagehd-title')).toHaveText('Licence & usage');
  await expect(page.locator('section.sp-card', { has: page.locator('h2', { hasText: 'Current usage' }) }))
    .toContainText('2 / 2');

  // emit the W1-07 warning through the service path (the sweep RPC), then the
  // partner-facing warnings card shows it
  const res = await request.post(`${BASE}/rest/v1/rpc/licence_warning_threshold_check`, {
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
    data: {},
  });
  expect(res.ok(), `threshold sweep: ${res.status()} ${await res.text()}`).toBeTruthy();
  await page.reload();
  await expect(
    page.locator('section.sp-card', { has: page.locator('h2', { hasText: 'Licence warnings' }) }),
  ).toContainText('limit near');

  await ctx.close();
});

test('non-admin: no invite affordance and the API refuses too', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('consultant') });
  const page = await ctx.newPage();

  await page.goto('/team');
  await expect(page.locator('h1.sp-pagehd-title')).toHaveText('Team & licence');

  // no invite form, no member-management affordances
  await expect(page.getByRole('button', { name: 'Send invite' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Remove' })).toHaveCount(0);

  // and the write path itself refuses (create_invite is owner-gated)
  const res = await page.evaluate(async () => {
    const r = await fetch('/api/invites', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: 'w217-nonadmin@testfix.test', role: 'practice_consultant' }),
    });
    return { status: r.status, body: await r.json() };
  });
  expect(res.status).toBe(400);
  expect(res.body.error).toContain('only practice owners may invite');

  // the licence detail page gives them the §4.1 non-admin answer
  await page.goto('/licences');
  await expect(page.getByText('Licence detail is limited to partner admins')).toBeVisible();

  await ctx.close();
});
