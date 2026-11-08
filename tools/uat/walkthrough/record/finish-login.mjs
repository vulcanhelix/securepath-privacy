import { chromium } from 'playwright';
import fs from 'fs';
const DIR = new URL('.', import.meta.url).pathname;
const link = fs.readFileSync(DIR + 'magic-link.txt', 'utf8').trim();
const b = await chromium.launch({
  headless: false,
  executablePath: '/root/.agent-browser/browsers/chrome-154.0.8037.92/chrome',
  args: ['--disable-blink-features=AutomationControlled', '--no-sandbox', '--disable-dev-shm-usage'],
});
const ctx = await b.newContext({
  viewport: { width: 1600, height: 950 },
  userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36',
});
const p = await ctx.newPage();
await p.goto(link, { waitUntil: 'domcontentloaded' }).catch(() => {});
await p.waitForTimeout(12000);
console.log('url:', p.url());
// workspace picker?
const ws = p.locator('text=/growthstrategy/i').first();
if (await ws.count()) { await ws.click(); await p.waitForTimeout(6000); }
await p.waitForLoadState('networkidle').catch(() => {});
console.log('final:', p.url());
await p.screenshot({ path: DIR + 'loggedin.png' });
await ctx.storageState({ path: DIR + 'state.json' });
console.log('STATE SAVED');
await b.close();
