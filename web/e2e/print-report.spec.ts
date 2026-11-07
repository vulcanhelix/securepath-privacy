import { test, expect } from '@playwright/test';
import { stateFile } from './fixtures';

// W3-03 — FR-RPT-05 print/PDF render of the monthly report in the issuing
// partner's brand (HTML → browser PDF; no Word). Asserts against the TESTFIX
// world: P1 (dd000005-…-0001, Partner A / Client One) has an issued '2026-09'
// report bound to a seeded snapshot and a '2026-10' draft.
//
//   issued  f1000005-…-0001  Partner A brand (logo + #2255AA accent)
//   draft   f1000005-…-0002  must render clearly marked "not issued"
const ISSUED = 'f1000005-0000-0000-0000-000000000001';
const DRAFT = 'f1000005-0000-0000-0000-000000000002';

test('issued report renders in the issuing partner’s branding', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('consultant') });
  const page = await ctx.newPage();
  expect((await page.goto(`/report/${ISSUED}/print`))?.status()).toBe(200);

  const doc = page.locator('article[aria-label="Monthly report September 2026"]');
  await expect(doc).toBeVisible();

  // Partner A brand on the document: name, logo, and the accent actually
  // applied to the brand rule (computed style, not just the CSS var).
  await expect(doc.getByText('TESTFIX Partner A')).toBeVisible();
  await expect(doc.locator('header img')).toHaveAttribute(
    'src',
    'https://testfix.invalid/partner-a/logo.png'
  );
  const ruleColour = await doc
    .locator('header')
    .evaluate((el) => getComputedStyle(el).borderBottomColor);
  expect(ruleColour).toBe('rgb(34, 85, 170)'); // #2255AA

  // Figures are the locked snapshot's, not live data: the seeded '2026-09'
  // snapshot carries register_open = 4 (listed by two template sections).
  const cells = doc.locator('tr', { hasText: 'Findings open' }).locator('td');
  await expect(cells).toHaveText(['4', '4']);

  // Issued: signed/issued footer, never a draft mark.
  await expect(doc).toContainText('Issued');
  await expect(page.getByTestId('draft-watermark')).toHaveCount(0);

  // The export path itself: print emulation + a real PDF out of the renderer.
  await page.emulateMedia({ media: 'print' });
  const pdf = await page.pdf({ format: 'A4' });
  expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
  expect(pdf.length).toBeGreaterThan(5_000);
  await ctx.close();
});

test('a non-issued report is unmistakably marked', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('consultant') });
  const page = await ctx.newPage();
  expect((await page.goto(`/report/${DRAFT}/print`))?.status()).toBe(200);

  const mark = page.getByTestId('draft-watermark');
  await expect(mark).toBeVisible();
  await expect(mark).toContainText(/not issued/i);
  await expect(page.locator('.rp-banner')).toContainText(/not been issued/i);
  await ctx.close();
});

test('Partner B gets 404 for Partner A’s report (fail closed)', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerB') });
  const page = await ctx.newPage();
  const res = await page.goto(`/report/${ISSUED}/print`);
  expect(res?.status()).toBe(404);
  await ctx.close();
});
