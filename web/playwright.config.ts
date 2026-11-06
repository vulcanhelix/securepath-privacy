import { defineConfig, devices } from '@playwright/test';

// W4-00 — browser harness for the programme screens (spec SP-SPC-PLT-001 §14).
// Runs against an already-running stack (CI: Next.js standalone behind Caddy on
// :8080, see .github/workflows/e2e.yml). Nothing here starts a server.
//
// Env:
//   E2E_BASE_URL       app origin (default http://127.0.0.1:8080)
//   E2E_ANON_KEY       Supabase anon JWT (CI-minted throwaway)
//   E2E_SERVICE_KEY    Supabase service_role JWT (CI-minted throwaway) — used
//                      only by e2e/auth.setup.ts to give the TESTFIX users a
//                      per-run random password and clear stale TOTP factors
//                      through the GoTrue admin API.
//
// The TESTFIX world (app/supabase/migrations/20261105000005_test_fixtures.sql)
// must be (re)seeded immediately before the run — the CI step does that.

const baseURL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:8080';

export default defineConfig({
  testDir: './e2e',
  outputDir: './test-results',
  // write tests share one fixture world — keep the run serial and deterministic
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [['list'], ['html', { outputFolder: 'playwright-report', open: 'never' }]],
  use: {
    baseURL,
    actionTimeout: 15_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'off',
  },
  projects: [
    { name: 'setup', testMatch: /auth\.setup\.ts/ },
    {
      name: 'desktop',
      testMatch: /.*\.spec\.ts/,
      testIgnore: /mobile\.spec\.ts/,
      dependencies: ['setup'],
      use: { ...devices['Desktop Chrome'] },
    },
    {
      // spec screen 08 — evidence capture on a 390px phone viewport
      name: 'mobile-390',
      testMatch: /mobile\.spec\.ts/,
      dependencies: ['setup'],
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 390, height: 844 },
        isMobile: true,
        hasTouch: true,
        deviceScaleFactor: 2,
      },
    },
  ],
});
