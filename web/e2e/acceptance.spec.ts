import { test, expect } from '@playwright/test';
import { stateFile } from './fixtures';

// W4-07 — UI legs of the §14 acceptance scenarios that only exist in the
// browser (the SQL suite app/tests/e2e_acceptance.sql owns the DB legs and
// carries the full AT→coverage map).
//
// Order-insensitive by construction: nothing here saves — every assertion is
// on the pre-save warning/preview state, so the TESTFIX world is untouched.

test('AT-06: a sub-AA accent colour is flagged before saving', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: stateFile('partnerA') });
  const page = await ctx.newPage();
  const field = (label: string) =>
    page.locator('.sp-field', { has: page.locator('.sp-field-label', { hasText: label }) });

  expect((await page.goto('/settings/branding'))?.status()).toBe(200);

  const accent = field('Accent colour');
  await accent.locator('input').fill('#ffee00'); // ~1.2:1 vs white — far below 4.5:1

  // FR-BRN-07: the warning appears on the field BEFORE any save — and it is a
  // warning, not a block: the input stays usable and no save happened.
  await expect(accent.getByText(/Flagged: #ffee00 is .* below the 4\.5:1 WCAG 2\.1 AA minimum/i))
    .toBeVisible();
  await expect(page.locator('.sp-alert--ok')).toHaveCount(0); // nothing was saved

  // a compliant colour clears the flag — still without saving
  await accent.locator('input').fill('#0e6f5c');
  await expect(accent.getByText(/below the 4\.5:1 WCAG/)).toHaveCount(0);
  await ctx.close();
});
