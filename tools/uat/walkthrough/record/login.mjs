// Phase 1: log into Linear as bruce@growthstrategy.co.za via email code.
// Writes record/state.json (storageState) on success.
// Flow: open login -> enter email -> wait for record/code.txt to appear
// (agent fetches the code from Gmail via Composio meanwhile) -> enter code.
import { chromium } from 'playwright';
import fs from 'fs';

const DIR = new URL('.', import.meta.url).pathname;
const CODE_FILE = DIR + 'code.txt';
const STATE = DIR + 'state.json';
const EMAIL = 'bruce@growthstrategy.co.za';

fs.rmSync(CODE_FILE, { force: true });

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1600, height: 950 } });
const page = await ctx.newPage();
page.setDefaultTimeout(30000);

console.log('open login page');
await page.goto('https://linear.app/login', { waitUntil: 'networkidle' }).catch(() => {});
await page.waitForTimeout(4000);
// provider picker first — "Continue with email" reveals the email input
await page.locator('button:has-text("Continue with email")').first().click();
console.log('clicked continue-with-email');

// email field — Linear shows a single email input for "Continue with email"
const email = page.locator('input[type="email"], input[name="email"], input[autocomplete="username"]').first();
await email.waitFor({ state: 'visible' });
await email.fill(EMAIL);
console.log('entered email');
// continue / submit
const cont = page.locator('button:has-text("Continue"), button[type="submit"]').first();
await cont.click();
console.log('submitted — waiting for code in email');
await page.waitForTimeout(4000);

// Sometimes Linear asks which workspace/account — log URL for debug
console.log('after email submit:', page.url());
fs.writeFileSync(DIR + 'need-code', '1');

// wait for the agent to drop the code
const deadline = Date.now() + 180000;
while (!fs.existsSync(CODE_FILE) && Date.now() < deadline) {
  await page.waitForTimeout(1500);
}
fs.rmSync(DIR + 'need-code', { force: true });
if (!fs.existsSync(CODE_FILE)) {
  await page.screenshot({ path: DIR + 'stuck.png' });
  console.error('NO CODE — screenshot at stuck.png');
  process.exit(1);
}
const code = fs.readFileSync(CODE_FILE, 'utf8').trim();
console.log('got code, entering');

// code inputs: either one field or N single-digit boxes
const digits = code.replace(/\D/g, '');
const boxes = page.locator('input[inputmode="numeric"], input[maxlength="1"], input[name*="code" i], input[autocomplete="one-time-code"]');
const n = await boxes.count();
if (n >= digits.length) {
  for (let i = 0; i < digits.length; i++) await boxes.nth(i).fill(digits[i]);
} else {
  // single field
  await page.keyboard.type(digits);
}
console.log('code typed');
await page.waitForTimeout(5000);
console.log('after code:', page.url());

// if a workspace picker appears (multiple workspaces), click GrowthstrategyHQ
const ws = page.locator('text=/growthstrategy/i').first();
if (await ws.count()) {
  await ws.click();
  await page.waitForTimeout(4000);
}
await page.waitForLoadState('networkidle').catch(() => {});
console.log('final url:', page.url());
await page.screenshot({ path: DIR + 'loggedin.png' });
await ctx.storageState({ path: STATE });
console.log('STATE SAVED');
await browser.close();
