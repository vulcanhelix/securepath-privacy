import { test, expect } from '@playwright/test';
import { P1, RUN, stateFile } from './fixtures';

// W3-01 — findings CSV import through the real UI (spec §13.1 FR-IMP-01/05):
// partner A uploads → dry-run preview (creates/exists/rejects) → commit → the
// register shows the new findings. Partner B cannot even reach the page —
// the programme is invisible to them, so the route 404s (AT-01 pattern);
// RPC-level isolation is covered by app/tests/e2e_import_framework.sql.

const csv = [
  'ref,finding,priority,assessment window,lead,planned close week',
  `PW${RUN}-1,Imported finding one ${RUN},HIGH,2026 Q4,c1-pl@testfix.test,4`,
  `PW${RUN}-2,Imported finding two ${RUN},low,,,`,
  `,Row with no ref ${RUN},Medium,,,`,
].join('\n');

test('partner A imports a findings CSV for P1: preview, rejects, commit, register shows them', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctx.newPage();

  expect((await page.goto(`/programmes/${P1}/register/import`))?.status()).toBe(200);
  await page
    .locator('input[type="file"]')
    .setInputFiles({ name: `findings-${RUN}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv) });

  // dry-run preview: 2 will be created, 1 rejected — nothing written yet
  await expect(page.getByText('2 will be created')).toBeVisible();
  await expect(page.getByText('1 rejected')).toBeVisible();
  await expect(page.getByText('missing required field "ref"')).toBeVisible();
  await expect(page.getByText(`PW${RUN}-1`)).toBeVisible();

  await page.getByRole('button', { name: /Commit import/ }).click();
  await expect(page.getByText(/Import committed — 2 findings created/)).toBeVisible();

  // persisted: fresh register load shows both imported findings
  await page.goto(`/programmes/${P1}/register`);
  await expect(page.getByRole('link', { name: `PW${RUN}-1` })).toBeVisible();
  await expect(page.getByRole('link', { name: `PW${RUN}-2` })).toBeVisible();
  await ctx.close();
});

test('re-importing the same file creates nothing new (idempotent)', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctx.newPage();
  expect((await page.goto(`/programmes/${P1}/register/import`))?.status()).toBe(200);
  await page
    .locator('input[type="file"]')
    .setInputFiles({ name: `findings-${RUN}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await expect(page.getByText('2 already exist')).toBeVisible();
  await expect(page.getByText('0 will be created')).toBeVisible();
  await page.getByRole('button', { name: 'Discard run' }).click();
  await expect(page.getByText('Choose CSV file')).toBeVisible();
  await ctx.close();
});

test('partner B cannot reach the import page or the register of partner A', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerB') });
  const page = await ctx.newPage();
  expect((await page.goto(`/programmes/${P1}/register/import`))?.status()).toBe(404);
  expect((await page.goto(`/programmes/${P1}/register`))?.status()).toBe(404);
  await ctx.close();
});
