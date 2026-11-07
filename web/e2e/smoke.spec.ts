import { test, expect, type Page } from '@playwright/test';
import { P1, P1_NAME, P3, EV_DECIDED, stateFile, knownDefect } from './fixtures';

// W4-00 — one smoke per merged programme screen. Each loads as a user who can
// see it and asserts TESTFIX content actually rendered (not just a 200), and
// that no error banner is showing. See KNOWN_DEFECTS in fixtures.ts for the
// tests currently expected to fail.

const pageTitle = (page: Page) => page.locator('h1.sp-pagehd-title');
const card = (page: Page, title: string) =>
  page.locator('section.sp-card', { has: page.locator('h2.sp-card-title', { hasText: title }) });
const noErrorBanner = async (page: Page) =>
  expect(page.getByText(/^Could not load/)).toHaveCount(0);

test.describe('programme screens — Partner A consultant assigned to C1', () => {
  test.use({ storageState: stateFile('consultant') });

  test('screen 01 dashboard renders the programme, register and workstreams', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    const res = await page.goto(`/programmes/${P1}`);
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText(P1_NAME);
    await expect(page.locator('.sp-ctx-crumb')).toContainText('TESTFIX Client One (ZA)');
    await expect(card(page, 'Remediation register')).toBeVisible();
    await expect(card(page, 'Workstreams').getByText('TESTFIX Governance & Accountability')).toBeVisible();
    await expect(card(page, 'Remediation register').getByText('R-01').first()).toBeVisible();
    await noErrorBanner(page);
  });

  test('screen 02 schedule renders the activity rows', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    const res = await page.goto(`/programmes/${P1}/schedule`);
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText('Activity schedule');
    await expect(page.getByText('TESTFIX Designate the accountable officer').first()).toBeVisible();
    await expect(page.getByText('TESTFIX Mock breach drill and evidence capture').first()).toBeVisible();
    await noErrorBanner(page);
  });

  test('screen 03 evidence renders the verify queue and the library', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    const res = await page.goto(`/programmes/${P1}/evidence`);
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText('Evidence');
    const verify = card(page, 'To verify');
    // EV1 (A-03 privacy-policy draft, uploaded by U10) waits in verification
    await expect(verify.getByText('A-03').first()).toBeVisible();
    await expect(verify.getByRole('button', { name: 'Approve' }).first()).toBeVisible();
    await expect(card(page, 'Library').getByText('EV-R-04-001')).toBeVisible();
    await noErrorBanner(page);
  });

  test('evidence detail renders the decided item and its review history', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    const res = await page.goto(`/programmes/${P1}/evidence/${EV_DECIDED}`);
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText('EV-R-04-001');
    await expect(card(page, 'Review history').getByText(/accept/i).first()).toBeVisible();
    await noErrorBanner(page);
  });

  test('screen KPIs renders the KPI table against target', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    const res = await page.goto(`/programmes/${P1}/kpis`);
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText('KPIs');
    await expect(page.locator('.sp-pagehd-meta')).toContainText('3 KPIs');
    await expect(page.getByRole('cell', { name: 'TESTFIX Requests actioned within period' })).toBeVisible();
    await expect(page.getByRole('cell', { name: 'TESTFIX Staff training coverage' })).toBeVisible();
    await noErrorBanner(page);
  });

  test('screen RAID renders items and the decision log', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    const res = await page.goto(`/programmes/${P1}/raid`);
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText('RAID & decisions');
    await expect(page.getByText('TESTFIX Operator contract negotiations may miss the week-7 deadline').first()).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Decision log' })).toBeVisible();
    await expect(page.getByText('TESTFIX accept phased contract rollout').first()).toBeVisible();
    await noErrorBanner(page);
  });

  // W2-07 (PR #80) is not merged — there is no weekly-session route on main
  // yet. Turn this into a real test when it lands (route name may differ).
  test.fixme('screen weekly session renders the agenda and the week log', async ({ page }) => {
    const res = await page.goto(`/programmes/${P1}/weekly`);
    expect(res?.status()).toBe(200);
    await expect(page.getByText('TESTFIX operator contract negotiations delayed')).toBeVisible();
  });
});

test.describe('client roles open their programme', () => {
  test('accountable officer: programme list shows P1 only', async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: stateFile('ao') });
    const page = await ctx.newPage();
    const res = await page.goto('/programmes');
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText('Programmes');
    // P1 is Amber → the console lists it twice (needs-attention + portfolio)
    await expect(page.getByRole('link', { name: P1_NAME }).first()).toBeVisible();
    await expect(page.locator(`a[href="/programmes/${P3}"]`)).toHaveCount(0);
    await ctx.close();
  });

  test('programme lead opens the P1 dashboard', async ({ browser }) => {
    knownDefect(test, 'W4-D2');
    const ctx = await browser.newContext({ storageState: stateFile('pl') });
    const page = await ctx.newPage();
    const res = await page.goto(`/programmes/${P1}`);
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText(P1_NAME);
    await ctx.close();
  });

  test('workstream lead opens P1 evidence (screen 08 user, spec B.13)', async ({ browser }) => {
    knownDefect(test, 'W4-D3');
    const ctx = await browser.newContext({ storageState: stateFile('wsl') });
    const page = await ctx.newPage();
    const res = await page.goto(`/programmes/${P1}/evidence`);
    expect(res?.status()).toBe(200);
    await expect(card(page, 'Submit evidence')).toBeVisible();
    await ctx.close();
  });
});

test.describe('partner console (screen 10) — Partner A admin', () => {
  test.use({ storageState: stateFile('partnerA') });

  test('portfolio lists only Partner A clients, licence at cap, attention list', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    const res = await page.goto('/programmes');
    expect(res?.status()).toBe(200);
    await expect(pageTitle(page)).toHaveText('Programmes');
    // both Partner A tenants, never Partner B's
    await expect(page.getByText('TESTFIX Client One')).toBeVisible();
    await expect(page.getByText('TESTFIX Client Two')).toBeVisible();
    await expect(page.getByText('TESTFIX Client Three')).toHaveCount(0);
    await expect(page.locator(`a[href="/programmes/${P3}"]`)).toHaveCount(0);
    // FR-PCN-03 headline tiles match the fixture world (2 running, P1 Amber+)
    await expect(page.getByText('Programmes running')).toBeVisible();
    await expect(page.getByText('Amber or Red')).toBeVisible();
    // FR-LIC-01 licence tile: TESTFIX Standard caps at 2 clients / 2 programmes
    // and the fixture world uses both fully (AT-07)
    await expect(page.getByText('Clients 2 / 2')).toBeVisible();
    await expect(page.getByText('Programmes 2 / 2')).toBeVisible();
    // P1 (fixture Amber) must land on the needs-attention worklist
    await expect(card(page, 'Needs attention').getByText(P1_NAME)).toBeVisible();
    await noErrorBanner(page);
  });
});

test.describe('cross-partner isolation — Partner B admin', () => {
  test.use({ storageState: stateFile('partnerB') });
  const paths = ['', '/schedule', '/evidence', '/kpis', '/raid', `/evidence/${EV_DECIDED}`];

  test('no Partner A programme data is rendered on any P1 screen', async ({ page }) => {
    for (const path of paths) {
      const res = await page.goto(`/programmes/${P1}${path}`);
      expect(res?.status(), `GET /programmes/P1${path}`).not.toBe(200);
      for (const leak of [P1_NAME, 'TESTFIX Client One', 'EV-R-04-001', 'TESTFIX Requests actioned']) {
        await expect(page.getByText(leak), `${leak} on /programmes/P1${path}`).toHaveCount(0);
      }
    }
  });

  test('P1 screens answer a clean 404', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    for (const path of paths) {
      const res = await page.goto(`/programmes/${P1}${path}`);
      expect(res?.status(), `GET /programmes/P1${path}`).toBe(404);
    }
  });

  test('console shows own partner clients only — Partner A invisible', async ({ page }) => {
    knownDefect(test, 'W4-D1');
    const res = await page.goto('/programmes');
    expect(res?.status()).toBe(200);
    await expect(page.locator(`a[href="/programmes/${P3}"]`)).toBeVisible();
    await expect(page.locator(`a[href="/programmes/${P1}"]`)).toHaveCount(0);
    // Partner A tenant names must never reach Partner B's console — not in the
    // portfolio table, not in needs-attention, not in support-access awareness
    await expect(page.getByText('TESTFIX Client Three')).toBeVisible();
    await expect(page.getByText('TESTFIX Client One')).toHaveCount(0);
    await expect(page.getByText('TESTFIX Client Two')).toHaveCount(0);
    // FR-LIC-01: TESTFIX Growth licence — 1 of 5 client + programme slots used
    await expect(page.getByText('Clients 1 / 5')).toBeVisible();
    await expect(page.getByText('Programmes 1 / 5')).toBeVisible();
    await noErrorBanner(page);
  });
});
