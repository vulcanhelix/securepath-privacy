import { test, expect } from '@playwright/test';
import { RUN, stateFile } from './fixtures';

// W2-02 — client onboarding wizard (spec §7.3 screen 11, FR-ONB-01..04).
// Partner-A admin drives the real UI end to end; every write lands through
// the system RPCs (create_client_org / appoint_designation / create_invite /
// create_programme). The designation step deliberately picks an ineligible
// holder so the review also proves partial failures are reported verbatim —
// never silently dropped.

const BASE = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:8080';
const SERVICE = process.env.E2E_SERVICE_KEY ?? '';
const PARTNER_A = 'bb000005-0000-0000-0000-000000000001';
const CLIENT_NAME = `W2-02 Onboarded Client ${RUN}`;

test('onboarding wizard: partner-A creates client + programme; partner-B cannot see it', async ({ browser, request }) => {
  // Partner A's fixture licence is deliberately AT cap (2 clients / 2
  // programmes — the fixtures comment). create_programme enforces
  // assert_licence_capacity, so raise the caps through the service role —
  // same out-of-band housekeeping class as auth.setup's password/factor
  // resets; the licence row is TESTFIX data, not app state under test.
  const bump = await request.fetch(`${BASE}/rest/v1/licences?partner_id=eq.${PARTNER_A}`, {
    method: 'PATCH',
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
    data: { client_limit: 10, programme_limit: 10 },
  });
  expect(bump.ok(), `licence bump: ${bump.status()} ${await bump.text()}`).toBeTruthy();

  const ctxA = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctxA.newPage();

  expect((await page.goto('/clients/new'))?.status()).toBe(200);

  // ---- step 1: client details ----
  await page.locator('.sp-field', { hasText: 'Client name' }).locator('input').fill(CLIENT_NAME);
  await page.locator('.sp-field', { hasText: 'Legal name' }).locator('input').fill(`${CLIENT_NAME} (Pty) Ltd`);
  await page.locator('.sp-field', { hasText: 'Registration number' }).locator('input').fill(`W202-${RUN}`);
  await page.locator('.sp-field', { hasText: 'Sector' }).locator('input').fill('TESTFIX onboarding');
  await page.locator('.sp-field', { hasText: 'Headcount in scope' }).locator('input').fill('12');
  await page.locator('.sp-field', { hasText: 'Primary contact email' }).locator('input')
    .fill(`w202-contact-${RUN}@testfix.test`);
  await page.getByRole('button', { name: 'Continue' }).click();

  // ---- step 2: jurisdiction & data region (defaults come from the partner) ----
  await expect(page.locator('h2', { hasText: 'Jurisdiction & data region' })).toBeVisible();
  const jur = page.locator('.sp-field', { hasText: 'Jurisdiction' }).locator('select');
  await jur.selectOption('ZA');
  const reg = page.locator('.sp-field', { hasText: 'Data region' }).locator('select');
  await reg.selectOption('ZA');
  await page.getByRole('button', { name: 'Continue' }).click();

  // ---- step 3: statutory designations — pick an INELIGIBLE holder on purpose:
  // U5 is a partner-A consultant; the ZA pack holds designations at client
  // level, so appoint_designation must reject this and the review must SAY so.
  await expect(page.locator('h2', { hasText: 'Statutory designations' })).toBeVisible();
  const dpo = page.locator('.sp-field', { hasText: 'Data Protection Officer' }).locator('select');
  await dpo.selectOption('aa000005-0000-0000-0000-000000000005'); // U5 partner-A consultant
  await page.getByRole('button', { name: 'Continue' }).click();

  // ---- step 4: programme — published ZA template offered, Monday start ----
  await expect(page.locator('h2', { hasText: 'Framework template & programme start' })).toBeVisible();
  const tpl = page.locator('.sp-field', { hasText: 'Framework template' }).locator('select');
  await expect(tpl.locator('option')).toHaveCount(1); // only the published TESTFIX ZA template
  await expect(tpl).toContainText('TESTFIX POPIA and PAIA Programme Template');
  await expect(page.locator('.sp-field', { hasText: 'Programme name' }).locator('input'))
    .toHaveValue(new RegExp(CLIENT_NAME));
  await page.getByRole('button', { name: 'Continue' }).click();

  // ---- step 5: client users — one client_admin invite ----
  await expect(page.locator('h2', { hasText: 'Client users & roles' })).toBeVisible();
  await page.getByRole('button', { name: 'Add invite' }).click();
  await page.locator('input[type="email"]').last().fill(`w202-admin-${RUN}@testfix.test`);
  await page.getByRole('button', { name: 'Continue' }).click();

  // ---- step 6: review & create ----
  await expect(page.locator('h2', { hasText: 'Review & create' })).toBeVisible();
  await expect(page.getByRole('cell', { name: CLIENT_NAME, exact: true })).toBeVisible();
  const [resp] = await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/api/clients/onboard') && r.request().method() === 'POST'),
    page.getByRole('button', { name: 'Create client' }).click(),
  ]);
  expect(resp.status()).toBe(200);
  const body = (await resp.json()) as {
    client_id: string; programme_id: string | null;
    steps: { key: string; label: string; status: string; detail?: string }[];
  };
  const step = (k: string) => body.steps.find((s) => s.key === k);
  expect(step('client')?.status).toBe('ok');
  expect(step('programme')?.status).toBe('ok');
  expect(body.programme_id).toBeTruthy();
  // the ineligible DPO pick failed loudly — the RPC's own error, verbatim
  expect(step('designation:dpo')?.status).toBe('error');
  expect(step('designation:dpo')?.detail).toMatch(/not eligible/i);
  // and it is surfaced on screen, not just in the payload
  await expect(page.getByText(/not eligible/i)).toBeVisible();
  expect(step(`invite:w202-admin-${RUN}@testfix.test`)?.status).toBe('ok');

  // ---- created artefacts are really there: partner-A console + programme ----
  expect((await page.goto('/programmes'))?.status()).toBe(200);
  await expect(page.getByRole('cell', { name: CLIENT_NAME, exact: true })).toBeVisible();
  const progPage = await page.goto(`/programmes/${body.programme_id}`);
  expect(progPage?.status()).toBe(200);
  const clientPage = await page.goto(`/clients/${body.client_id}`);
  expect(clientPage?.status()).toBe(200);
  await expect(page.locator('h1', { hasText: CLIENT_NAME })).toBeVisible();
  await ctxA.close();

  // ---- tenant isolation: partner-B admin can see none of it ----
  const ctxB = await browser.newContext({ storageState: stateFile('partnerB') });
  const pb = await ctxB.newPage();
  expect((await pb.goto(`/clients/${body.client_id}`))?.status()).toBe(404);
  expect((await pb.goto(`/programmes/${body.programme_id}`))?.status()).toBe(404);
  expect((await pb.goto('/programmes'))?.status()).toBe(200);
  await expect(pb.getByRole('cell', { name: CLIENT_NAME })).toHaveCount(0);
  await ctxB.close();
});
