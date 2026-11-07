import { test, expect } from '@playwright/test';
import { stateFile } from './fixtures';

// W2-15 — brand consumption (spec §7.4, FR-BRN-01/02/03/05; AT-05). What W2-03
// stored is now painted on every surface the spec names:
//
//   * sign-in: the host's first label resolves the partner pre-auth through
//     public_partner_brand() (anon-safe definer) — name, logo, sign-in text,
//     support contact, accent var, per-licence SecurePath attribution
//   * shell:   partner_brand() closes the practices_read gap so new-model
//     (client/programme-scope) users see their partner's brand too
//   * mail:    invites/notifications share the branded envelope + From name
//     (asserted by the unit test + W1-08's suite; Resend is absent in CI)
//   * report:  already covered by print-report.spec.ts (PR #104)
//
// TESTFIX world: Partner A = subdomain testfix-a, fully branded, licence
// attribution ON. Partner B = testfix-b, plainer brand, sign_in_text NULL —
// the "partner B unaffected" leg.

const BASE = new URL(process.env.E2E_BASE_URL ?? 'http://127.0.0.1:8080');
const LOOPBACK = BASE.hostname === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(BASE.hostname);

/** Partner sign-in origin — <sub>.localhost on loopback, <sub>.<domain> in prod. */
const partnerUrl = (sub: string, path: string) =>
  `${BASE.protocol}//${sub}.${LOOPBACK ? 'localhost' : BASE.hostname}${BASE.port ? `:${BASE.port}` : ''}${path}`;

test('partner A subdomain paints its own brand on sign-in (AT-05)', async ({ page }) => {
  const res = await page.goto(partnerUrl('testfix-a', '/login'));
  expect(res?.status()).toBe(200);
  await expect(page.getByTestId('auth-brand-name')).toHaveText('TESTFIX Partner A');
  await expect(page.locator('.sp-auth-brand img')).toHaveAttribute(
    'src', 'https://testfix.invalid/partner-a/logo.png');
  await expect(page.getByTestId('auth-signin-text'))
    .toHaveText('Sign in to TESTFIX Partner A workspace');
  await expect(page.getByTestId('auth-support-contact')).toContainText('support@testfix.test');
  // FR-BRN-05 — licence attribution_display is ON for Partner A
  await expect(page.getByTestId('auth-attribution'))
    .toContainText('Powered by SecurePath');
  await expect(page.getByTestId('auth-attribution'))
    .toContainText('delivered by TESTFIX Partner A');
  // the partner accent paints the auth surface
  const accentVar = await page.evaluate(() =>
    getComputedStyle(document.querySelector('.sp-authwrap')!).getPropertyValue('--accent').trim());
  expect(accentVar.toLowerCase()).toBe('#2255aa');
});

test('partner B sees its own plainer brand — never partner A\u2019s (AT-05)', async ({ page }) => {
  const res = await page.goto(partnerUrl('testfix-b', '/login'));
  expect(res?.status()).toBe(200);
  await expect(page.getByTestId('auth-brand-name')).toHaveText('TESTFIX Partner B');
  await expect(page.getByTestId('auth-support-contact')).toContainText('help@testfix.test');
  await expect(page.getByText('TESTFIX Partner A')).toHaveCount(0);
  // B has no sign_in_text — the line must not render at all
  await expect(page.getByTestId('auth-signin-text')).toHaveCount(0);
});

test('the apex host keeps the platform\u2019s own SecurePath chrome', async ({ page }) => {
  const res = await page.goto('/login');
  expect(res?.status()).toBe(200);
  await expect(page.getByTestId('auth-brand-name')).toHaveText('SecurePath');
  await expect(page.getByTestId('auth-signin-text')).toHaveCount(0);
  await expect(page.getByTestId('auth-support-contact')).toHaveCount(0);
});

test('an unknown subdomain falls back to the platform chrome, not a 500', async ({ page }) => {
  const res = await page.goto(partnerUrl('no-such-partner', '/login'));
  expect(res?.status()).toBe(200);
  await expect(page.getByTestId('auth-brand-name')).toHaveText('SecurePath');
});

test('unauthenticated deep links stay on the partner host (FR-BRN-02)', async ({ page }) => {
  await page.goto(partnerUrl('testfix-a', '/dashboard'));
  await expect(page).toHaveURL(/\/login/);
  expect(new URL(page.url()).hostname).toBe(
    `testfix-a.${LOOPBACK ? 'localhost' : BASE.hostname}`);
  await expect(page.getByTestId('auth-brand-name')).toHaveText('TESTFIX Partner A');
});

test('a programme-scope user gets the partner brand via partner_brand() (RLS gap closed)', async ({ browser }) => {
  // 'pl' holds only a programme-scope assignment — practices_read's
  // current_practice() shim returns NULL, the direct practices read can't see
  // Partner A at all. partner_brand() resolves it through the programme.
  const ctx = await browser.newContext({ storageState: stateFile('pl') });
  const page = await ctx.newPage();
  expect((await page.goto('/programmes'))?.status()).toBe(200);
  await expect(page.locator('.sp-side-name')).toHaveText('TESTFIX Partner A');
  // the brand paints chrome only — a client-side user never gets partner nav
  await expect(page.locator('.sp-side-item', { hasText: 'Team' })).toHaveCount(0);
  await ctx.close();
});

test('partner B admin sees partner B\u2019s brand in the shell, not A\u2019s', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerB') });
  const page = await ctx.newPage();
  expect((await page.goto('/programmes'))?.status()).toBe(200);
  await expect(page.locator('.sp-side-name')).toHaveText('TESTFIX Partner B');
  const accentVar = await page.evaluate(() =>
    getComputedStyle(document.body).getPropertyValue('--accent').trim());
  expect(accentVar.toLowerCase()).toBe('#7a3b2e');
  await ctx.close();
});

test('the programme shell renders the FR-BRN-05 attribution line per licence', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctx.newPage();
  expect((await page.goto('/programmes'))?.status()).toBe(200);
  await expect(page.locator('.sp-attr'))
    .toContainText('Powered by SecurePath');
  await ctx.close();
});

test('the branding screen shows the partner\u2019s resolvable sign-in URL', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctx.newPage();
  expect((await page.goto('/settings/branding'))?.status()).toBe(200);
  await expect(page.getByTestId('signin-url'))
    .toHaveValue(`http://testfix-a.${LOOPBACK ? 'localhost' : BASE.hostname}${BASE.port ? `:${BASE.port}` : ''}`);
  await ctx.close();
});
