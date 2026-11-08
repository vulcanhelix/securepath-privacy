import { chromium } from 'playwright';
import fs from 'fs';
const DIR = new URL('.', import.meta.url).pathname;
const b = await chromium.launch({
  headless: false,
  executablePath: '/root/.agent-browser/browsers/chrome-154.0.8037.92/chrome',
  args: ['--disable-blink-features=AutomationControlled', '--no-sandbox', '--disable-dev-shm-usage'],
});
const ctx = await b.newContext({
  storageState: DIR + 'state.json',
  viewport: { width: 1600, height: 950 },
});
const p = await ctx.newPage();
p.setDefaultTimeout(20000);
await p.goto('https://linear.app/growthstrategyhq-uat/settings/account/security', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(6000);
await p.screenshot({ path: DIR + 'api.png', fullPage: true });
const txt = await p.locator('body').innerText();
const i = txt.indexOf('API');
console.log('content:', txt.slice(txt.indexOf('Security') > -1 ? 0 : 0, 900).replace(/\n/g,' | '));
const btns = await p.locator('button, [role="button"]').evaluateAll(e => e.map(x => x.textContent.trim()).filter(Boolean).slice(0, 25));
console.log('btns:', JSON.stringify(btns));
await b.close();
