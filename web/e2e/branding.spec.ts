import { test, expect, type BrowserContext, type APIRequestContext } from '@playwright/test';
import { RUN, stateFile } from './fixtures';

// W2-03 — white-label branding (spec §7.4 screen 12). The partner admin edits
// the brand through the update_practice_branding RPC and the programme shell
// repaints; non-partner_admin callers are refused by the definer's own guard.
//
// Runs serial inside the shared TESTFIX world: Partner A's accent is changed
// and then restored to whatever it was, so this spec is re-runnable whether
// or not the fixture pack was reseeded before the run.

const BASE = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:8080';
const ANON = process.env.E2E_ANON_KEY ?? '';
const SERVICE = process.env.E2E_SERVICE_KEY ?? '';
const PARTNER_A = 'bb000005-0000-0000-0000-000000000001';
const NEW_SIGNIN = `W2-03 e2e ${RUN}`;

/** accent captured before test 1 mutates it — restored by the last test;
    newAccent is chosen to differ so the patch always includes accent_hex */
let originalAccent = '';
let originalSignInText: string | null = null;
let newAccent = '';

/** The caller's access token, lifted from the @supabase/ssr auth cookie —
    needed only to fire the raw RPC as a specific user (the UI never offers a
    non-admin a write path, so the refusal check goes over PostgREST). */
async function accessToken(ctx: BrowserContext): Promise<string> {
  const cookies = await ctx.cookies();
  const chunks = cookies
    .filter((c) => c.name.includes('auth-token'))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
  expect(chunks.length, 'supabase auth cookie present').toBeGreaterThan(0);
  let raw = chunks.map((c) => decodeURIComponent(c.value)).join('');
  if (raw.startsWith('base64-')) raw = Buffer.from(raw.slice(7), 'base64').toString('utf8');
  return (JSON.parse(raw) as { access_token: string }).access_token;
}

async function serviceGet(request: APIRequestContext, path: string) {
  const res = await request.get(`${BASE}/rest/v1/${path}`, {
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` },
  });
  expect(res.ok(), `GET ${path}: ${res.status()} ${await res.text()}`).toBeTruthy();
  return res.json();
}

test.describe.configure({ mode: 'serial' });

test('partner admin edits branding; programme shell and report preview reflect it', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctx.newPage();
  const field = (label: string) =>
    page.locator('.sp-field', { has: page.locator('.sp-field-label', { hasText: label }) });

  expect((await page.goto('/settings/branding'))?.status()).toBe(200);
  // the stored brand loads into the form
  await expect(field('Display name').locator('input')).toHaveValue('TESTFIX Partner A');
  const accentInput = field('Accent colour').locator('input');
  await expect(accentInput).toHaveValue(/^#[0-9a-fA-F]{6}$/);
  originalAccent = await accentInput.inputValue();
  originalSignInText = await field('Sign-in page text').locator('textarea').inputValue();
  newAccent = originalAccent.toLowerCase() === '#0e6f5c' ? '#123a6b' : '#0e6f5c';
  // the stored brand already renders the three FR-BRN-06 previews
  await expect(page.getByTestId('preview-signin-name')).toHaveText('TESTFIX Partner A');
  await expect(page.getByTestId('preview-report-footer')).toContainText('delivered by TESTFIX Partner A');

  // edit accent + sign-in text — the preview repaints live, before saving
  await accentInput.fill(newAccent);
  await field('Sign-in page text').locator('textarea').fill(NEW_SIGNIN);
  await expect(page.getByTestId('preview-accent-button')).toHaveCSS('background-color', newAccent === '#0e6f5c' ? 'rgb(14, 111, 92)' : 'rgb(18, 58, 107)');
  await expect(page.getByTestId('preview-signin-text')).toHaveText(NEW_SIGNIN);

  await page.getByRole('button', { name: 'Save branding' }).click();
  await expect(page.locator('.sp-alert--ok')).toContainText('Saved.');

  // the programme world repaints under the new accent (root layout sets
  // --accent from practices.accent_hex on every render)
  expect((await page.goto('/programmes'))?.status()).toBe(200);
  await expect(page.locator('.sp-side-name')).toHaveText('TESTFIX Partner A');
  const accentVar = await page.evaluate(() =>
    getComputedStyle(document.body).getPropertyValue('--accent').trim()
  );
  expect(accentVar).toBe(newAccent);

  // persisted: a fresh load of the screen shows the stored values
  await page.goto('/settings/branding');
  await expect(field('Accent colour').locator('input')).toHaveValue(newAccent);
  await expect(field('Sign-in page text').locator('textarea')).toHaveValue(NEW_SIGNIN);
  await ctx.close();
});

test('the write is audited', async ({ request }) => {
  const rows = (await serviceGet(
    request,
    `audit_log?select=action,detail&action=eq.partner.branding_updated&order=at.desc&limit=10`
  )) as { detail: { patch?: Record<string, string>; previous?: Record<string, string> } }[];
  // the patch carries the RUN-tagged sign-in text — unique to this run
  const row = rows.find((r) => r.detail?.patch?.sign_in_text === NEW_SIGNIN);
  expect(row, 'audit row for the branding change').toBeTruthy();
  expect(row!.detail.patch?.accent_hex).toBe(newAccent);
  expect(row!.detail.previous?.accent_hex).toBe(originalAccent);
});

test('non-partner_admin callers are refused by the RPC guard', async ({ browser }) => {
  for (const role of ['consultant', 'partnerB'] as const) {
    const ctx = await browser.newContext({ storageState: stateFile(role) });
    const token = await accessToken(ctx);
    const res = await ctx.request.post(`${BASE}/rest/v1/rpc/update_practice_branding`, {
      headers: { apikey: ANON, Authorization: `Bearer ${token}` },
      data: { p_partner: PARTNER_A, p_payload: { accent_hex: '#000000' } },
    });
    expect(res.status(), `${role} must not write Partner A branding`).toBeGreaterThanOrEqual(400);
    expect(await res.text()).toContain('partner_admin');
    await ctx.close();
  }
});

test('partner consultant sees the read-only notice, not the form', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('consultant') });
  const page = await ctx.newPage();
  expect((await page.goto('/settings/branding'))?.status()).toBe(200);
  await expect(page.getByText('Only a partner admin can edit branding.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Save branding' })).toHaveCount(0);
  await ctx.close();
});

test('restore the original accent for the rest of the serial run', async ({ browser }) => {
  test.skip(!originalAccent, 'nothing was changed');
  const ctx = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctx.newPage();
  const field = (label: string) =>
    page.locator('.sp-field', { has: page.locator('.sp-field-label', { hasText: label }) });
  await page.goto('/settings/branding');
  await field('Accent colour').locator('input').fill(originalAccent);
  await field('Sign-in page text').locator('textarea').fill(originalSignInText ?? '');
  await page.getByRole('button', { name: 'Save branding' }).click();
  await expect(page.locator('.sp-alert--ok')).toContainText('Saved.');
  await page.goto('/programmes');
  const accentVar = await page.evaluate(() =>
    getComputedStyle(document.body).getPropertyValue('--accent').trim()
  );
  expect(accentVar).toBe(originalAccent.toLowerCase());
  await ctx.close();
});
