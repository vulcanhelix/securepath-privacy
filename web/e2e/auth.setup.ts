import { randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { test as setup, expect, type APIRequestContext } from '@playwright/test';
import { USERS, stateFile, type Role } from './fixtures';
import { totp, secondsLeftInWindow } from './totp';

// W4-00 — logs each test role in through the REAL UI: /login (password) →
// middleware sends the aal1 session to /mfa/enroll → read the manual TOTP key
// off the screen → type the code → aal2. The resulting cookies are saved as a
// storage state per role so specs never log in again.
//
// The only out-of-band step is admin housekeeping on the TESTFIX users via the
// GoTrue admin API (service_role): a fresh random password each run (the
// fixture pack seeds an unusable one) and deletion of any TOTP factor left by a
// previous run, so the compulsory enrolment path is exercised every time.
// No app code is bypassed.

const ANON = process.env.E2E_ANON_KEY ?? '';
const SERVICE = process.env.E2E_SERVICE_KEY ?? '';

async function prepareUser(request: APIRequestContext, userId: string, password: string) {
  const h = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` };
  const list = await request.get(`/auth/v1/admin/users/${userId}/factors`, { headers: h });
  expect(list.ok(), `list factors for ${userId}: ${list.status()} ${await list.text()}`).toBeTruthy();
  for (const f of (await list.json()) as { id: string }[]) {
    const del = await request.delete(`/auth/v1/admin/users/${userId}/factors/${f.id}`, { headers: h });
    expect(del.ok(), `delete factor ${f.id}: ${del.status()}`).toBeTruthy();
  }
  const upd = await request.put(`/auth/v1/admin/users/${userId}`, {
    headers: h,
    data: { password, email_confirm: true },
  });
  expect(upd.ok(), `set password for ${userId}: ${upd.status()} ${await upd.text()}`).toBeTruthy();
}

for (const role of Object.keys(USERS) as Role[]) {
  setup(`log in as ${USERS[role].label} (${role}) through the UI incl. TOTP`, async ({ page, request }) => {
    expect(SERVICE, 'E2E_SERVICE_KEY must be set').not.toBe('');
    expect(ANON, 'E2E_ANON_KEY must be set').not.toBe('');
    const u = USERS[role];
    const password = randomBytes(18).toString('base64url');
    await prepareUser(request, u.id, password);

    // 1. password sign-in on the real login form
    await page.goto('/login');
    await page.locator('input[type="email"]').fill(u.email);
    await page.locator('input[type="password"]').fill(password);
    await page.getByRole('button', { name: 'Sign in' }).click();

    // 2. middleware: aal1 without a verified factor → compulsory enrolment
    await page.waitForURL('**/mfa/enroll');
    const key = page.locator('p', { hasText: 'Manual key:' }).locator('code');
    await expect(key).toBeVisible();
    const secret = (await key.textContent())?.trim() ?? '';
    expect(secret).toMatch(/^[A-Z2-7]+=*$/);

    // avoid typing a code that rolls over mid-request
    if (secondsLeftInWindow() < 4) await page.waitForTimeout(4_500);
    await page.locator('input[inputmode="numeric"]').fill(totp(secret));
    await page.getByRole('button', { name: 'Activate 2FA' }).click();

    // 3. aal2 — the middleware gate now lets us through to an app page
    // (only the gate is asserted here; what the page renders is the specs' job)
    await page.waitForURL((url) => !url.pathname.startsWith('/mfa') && !url.pathname.startsWith('/login'));
    await page.goto('/programmes');
    await expect(page).toHaveURL(/\/programmes$/);

    mkdirSync('e2e/.auth', { recursive: true });
    await page.context().storageState({ path: stateFile(role) });
  });
}
