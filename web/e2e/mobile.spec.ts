import { test, expect } from '@playwright/test';
import { P1, P1_NAME, RUN, stateFile, type Role } from './fixtures';

// W4-00 — spec screen 08 (evidence capture) on a 390 px phone viewport
// (project "mobile-390" in playwright.config.ts). The uploader takes a "photo"
// through the camera input and it lands in the verifier's queue.
// Spec B.13 names the workstream lead as this screen's user; the accountable
// officer — who leads A-01 and so may upload — runs the same path.
// (C1 "All staff" may not upload evidence, spec §4.2.)

// 1x1 transparent PNG
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  'base64'
);

const cases: { role: Role; activity: string }[] = [
  { role: 'ao', activity: 'A-01 — TESTFIX Designate the accountable officer' },
  { role: 'wsl', activity: 'A-06 — TESTFIX Staff awareness training rollout' },
];

for (const c of cases) {
  test(`screen 08 at 390px as ${c.role}: fits the phone, camera upload persists`, async ({ browser }) => {
    const ctx = await browser.newContext({
      storageState: stateFile(c.role),
      viewport: { width: 390, height: 844 },
      isMobile: true,
      hasTouch: true,
    });
    const page = await ctx.newPage();
    const res = await page.goto(`/programmes/${P1}/evidence`);
    expect(res?.status()).toBe(200);

    const form = page.locator('section.sp-card', { has: page.locator('h2', { hasText: 'Submit evidence' }) });
    await expect(form).toBeVisible();
    await form.scrollIntoViewIfNeeded();

    // the page must fit the phone width — no horizontal scrolling
    const scrollW = await page.evaluate(() => document.documentElement.scrollWidth);
    expect.soft(scrollW, 'document scrollWidth at 390px').toBeLessThanOrEqual(390);

    // capture controls are visible and inside the viewport width
    const capture = form.getByRole('button', { name: 'Capture photo' });
    const choose = form.getByRole('button', { name: 'Choose files' });
    for (const b of [capture, choose]) {
      await expect(b).toBeVisible();
      const box = await b.boundingBox();
      expect(box, 'button box').not.toBeNull();
      expect(box!.x).toBeGreaterThanOrEqual(0);
      expect(box!.x + box!.width).toBeLessThanOrEqual(390);
    }
    // FR-MOB-02: rear camera on mobile
    const cam = form.locator('input[type="file"][capture="environment"]');
    await expect(cam).toHaveAttribute('accept', 'image/*');

    const note = `W4-00 mobile photo ${c.role} ${RUN}`;
    await form.locator('.sp-field', { hasText: 'Against activity' }).locator('select').selectOption({ label: c.activity });
    await form.locator('.sp-field', { hasText: 'Site' }).locator('input').fill('TESTFIX Branch');
    await form.locator('.sp-field', { hasText: 'Note' }).locator('input').fill(note);
    await expect(capture).toBeEnabled();
    await cam.setInputFiles({ name: `site-photo-${RUN}.png`, mimeType: 'image/png', buffer: PNG });
    await expect(form.getByText('Uploaded 1 file — sent for verification.')).toBeVisible();
    await page.screenshot({ path: test.info().outputPath(`screen08-390-${c.role}.png`), fullPage: true });
    await ctx.close();

    // persisted: the verifier sees the photo in the queue on a fresh load
    const rv = await browser.newContext({ storageState: stateFile('consultant') });
    const p2 = await rv.newPage();
    await p2.goto(`/programmes/${P1}/evidence`);
    const verify = p2.locator('section.sp-card', { has: p2.locator('h2', { hasText: 'To verify' }) });
    await expect(verify.getByText(note, { exact: true })).toBeVisible();
    await rv.close();
  });
}

// ---------------------------------------------------------------------------
// W2-13 — FR-MOB-01 "My actions" on the same 390 px viewport. The accountable
// officer (C1) leads A-01 (already Complete, so nothing due) but has a real
// accept-queue item — EV2 (operator-agreement-signed.pdf, uploaded by the
// workstream lead against R-02/A-05) — and may complete the seeded Q4
// checklist items (can_run_cadence covers the AO).
// ---------------------------------------------------------------------------

test('my-actions at 390px as ao: shows their own open actions', async ({ browser }) => {
  const ctx = await browser.newContext({
    storageState: stateFile('ao'),
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true,
  });
  const page = await ctx.newPage();
  const res = await page.goto(`/programmes/${P1}/actions`);
  expect(res?.status()).toBe(200);

  await expect(page.getByRole('heading', { name: 'My actions' })).toBeVisible();

  // the AO's own queue: EV2 sits in 'acceptance', uploaded by someone else
  await expect(page.getByText('operator-agreement-signed.pdf')).toBeVisible();
  await expect(page.getByText('A-05 · R-02')).toBeVisible();

  // checklist items the AO may complete
  await expect(page.getByText('TESTFIX Review operator register completeness')).toBeVisible();
  await expect(page.getByText('TESTFIX Access-rights spot check')).toBeVisible();

  // the AO leads only A-01, which is Complete — the led-activities section
  // must NOT list it (and shows the empty state instead)
  await expect(page.getByText('TESTFIX Designate the accountable officer')).not.toBeVisible();

  // FR-MOB-01: the list fits the phone — no sideways scrolling
  const scrollW = await page.evaluate(() => document.documentElement.scrollWidth);
  expect.soft(scrollW, 'document scrollWidth at 390px').toBeLessThanOrEqual(390);
  await page.screenshot({ path: test.info().outputPath('my-actions-390-ao.png'), fullPage: true });
  await ctx.close();
});

test('my-actions isolation: partner-B sees nothing of P1', async ({ browser }) => {
  // partnerB is a partner_admin on a different practice: the programme shell
  // 404s (programmeContext → null → notFound) and no P1 content renders.
  // W4-D1 still blocks the path TODAY: the (programme) group layout's nav
  // strip throws before the 404 boundary renders, so the route answers 500 —
  // the mark flips this test green the moment the nav serialization is fixed.
  const ctx = await browser.newContext({
    storageState: stateFile('partnerB'),
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true,
  });
  const page = await ctx.newPage();
  const res = await page.goto(`/programmes/${P1}/actions`);
  expect(res?.status()).toBe(404);
  await expect(page.getByText('My actions')).not.toBeVisible();
  await expect(page.getByText(P1_NAME)).not.toBeVisible();
  // no P1 content leaks — partnerB's own sidebar branding is 'TESTFIX Partner
  // B', so assert on P1-specific strings only
  await expect(page.getByText('operator-agreement-signed.pdf')).not.toBeVisible();
  await ctx.close();
});
