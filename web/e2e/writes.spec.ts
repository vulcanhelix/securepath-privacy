import { test, expect } from '@playwright/test';
import { P1, RUN, stateFile, knownDefect } from './fixtures';

// W4-00 — write round-trips through the UI. Every write is followed by a fresh
// page load (new server render from the DB) before asserting it persisted.

test('KPIs: consultant records a monthly actual and it persists', async ({ browser }) => {
  knownDefect(test, 'W4-D1');
  const ctx = await browser.newContext({ storageState: stateFile('consultant') });
  const page = await ctx.newPage();
  const kpi = 'TESTFIX Requests actioned within period';
  // unique per run so a stale row from an earlier run can't satisfy the check
  const value = String(50 + (Number.parseInt(RUN.slice(-4), 36) % 40) + 0.25);

  expect((await page.goto(`/programmes/${P1}/kpis`))?.status()).toBe(200);
  const row = page.locator('tr', { has: page.getByRole('cell', { name: kpi, exact: true }) });
  await row.getByRole('button', { name: 'Expand history' }).click();
  const detail = page.locator('form', { hasText: 'Capture monthly actual' });
  await expect(detail).toBeVisible();
  const month = await detail.locator('input[type="month"]').inputValue();
  await detail.locator('input[type="number"]').fill(value);
  await detail.locator('input[placeholder^="Note"]').fill(`W4-00 playwright ${RUN}`);
  await detail.getByRole('button', { name: 'Record actual' }).click();
  await expect(page.locator('.sp-breach-msg.is-ok')).toContainText('Recorded');

  // persisted: reload, the KPI row's latest actual and the history show it
  await page.reload();
  const row2 = page.locator('tr', { has: page.getByRole('cell', { name: kpi, exact: true }) });
  await expect(row2).toContainText(`${value} %`);
  await row2.getByRole('button', { name: 'Expand history' }).click();
  const label = new Date(`${month}-01T00:00:00`).toLocaleDateString('en-GB', { month: 'short', year: 'numeric' });
  const hist = page.locator('tr', { hasText: label }).filter({ hasText: `${value} %` });
  await expect(hist.first()).toBeVisible();
  await ctx.close();
});

test('Evidence: AO records a link, consultant verifies it, the named alternate accepts it', async ({ browser }) => {
  knownDefect(test, 'W4-D1');
  const note = `W4-00 link evidence ${RUN}`;

  // 1. the accountable officer leads A-01, so may upload against it
  //    (upload_evidence: programme writer roles OR an activity lead)
  const up = await browser.newContext({ storageState: stateFile('ao') });
  const p1 = await up.newPage();
  expect((await p1.goto(`/programmes/${P1}/evidence`))?.status()).toBe(200);
  const form = p1.locator('section.sp-card', { has: p1.locator('h2', { hasText: 'Submit evidence' }) });
  await form.locator('.sp-field', { hasText: 'Against activity' }).locator('select')
    .selectOption({ label: 'A-01 — TESTFIX Designate the accountable officer' });
  await form.locator('.sp-field', { hasText: 'Site' }).locator('input').fill('TESTFIX Head Office');
  await form.locator('.sp-field', { hasText: 'Note' }).locator('input').fill(note);
  await form.locator('input[type="url"]').fill(`https://evidence.testfix.invalid/${RUN}`);
  await form.getByRole('button', { name: 'Record link' }).click();
  await expect(form.getByText('Link recorded — sent for verification.')).toBeVisible();
  await up.close();

  // 2. the verifier (FR-EVD-03: PL or partner consultant) sees it in
  //    "To verify" after a fresh load and approves it through the checklist
  const vr = await browser.newContext({ storageState: stateFile('consultant') });
  const p2 = await vr.newPage();
  expect((await p2.goto(`/programmes/${P1}/evidence`))?.status()).toBe(200);
  const verify = p2.locator('section.sp-card', { has: p2.locator('h2', { hasText: 'To verify' }) });
  const card = verify.locator('div', { has: p2.getByText(note, { exact: true }) })
    .filter({ has: p2.getByRole('button', { name: 'Approve' }) }).last();
  await expect(card).toBeVisible();
  const approve = card.getByRole('button', { name: 'Approve' });
  await expect(approve).toBeDisabled(); // checklist first (FR-EVD-03 UI aid)
  for (const c of ['Shows the control operating', 'Covers the required sites', 'Dated within the activity window']) {
    await card.getByLabel(c).check();
  }
  await approve.click();
  await expect(verify.getByText(note, { exact: true })).toHaveCount(0);
  await p2.reload();
  await expect(
    p2.locator('section.sp-card', { has: p2.locator('h2', { hasText: 'To verify' }) }).getByText(note, { exact: true })
  ).toHaveCount(0);
  await vr.close();

  // 3. the verify persisted: the item is in the named alternate's "To accept"
  //    queue (the AO uploaded it, so self-review keeps it out of the AO's own
  //    queue — FR-ACC-01/02). The alternate accepts it; it gets an EV ref.
  const alt = await browser.newContext({ storageState: stateFile('alternate') });
  const p3 = await alt.newPage();
  expect((await p3.goto(`/programmes/${P1}/evidence`))?.status()).toBe(200);
  const accept = p3.locator('section.sp-card', { has: p3.locator('h2', { hasText: 'To accept' }) });
  const acard = accept.locator('div', { has: p3.getByText(note, { exact: true }) })
    .filter({ has: p3.getByRole('button', { name: 'Accept' }) }).last();
  await expect(acard).toBeVisible();
  await acard.getByRole('button', { name: 'Accept' }).click();
  const ok = p3.getByText(/^Accepted — evidence ref /);
  await expect(ok).toBeVisible();
  const ref = ((await ok.textContent()) ?? '').replace('Accepted — evidence ref', '').trim();
  expect(ref).toMatch(/^EV-/);

  // 4. persisted: fresh load — gone from the queue, in the immutable library
  await p3.reload();
  await expect(
    p3.locator('section.sp-card', { has: p3.locator('h2', { hasText: 'To accept' }) }).getByText(note, { exact: true })
  ).toHaveCount(0);
  const library = p3.locator('section.sp-card', { has: p3.locator('h2', { hasText: 'Library' }) });
  await expect(library.locator('tr', { hasText: ref })).toContainText('A-01');
  await alt.close();
});
