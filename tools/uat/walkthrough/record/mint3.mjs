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
await p.locator('button:has-text("New API key")').first().click();
await p.waitForTimeout(2500);
await p.screenshot({ path: DIR + 'newkey.png' });
// label input in dialog
const label = p.locator('input[placeholder*="label" i], input[placeholder*="name" i], [role="dialog"] input').first();
console.log('label inputs:', await p.locator('input').count());
await label.fill('uat-walkthrough');
await p.waitForTimeout(500);
await p.locator('button:has-text("Create"), [role="dialog"] button:has-text("Save")').first().click();
await p.waitForTimeout(4000);
await p.screenshot({ path: DIR + 'newkey2.png' });
// key shown once — look for lin_api_ text in inputs/code/pre
const txt = await p.locator('body').innerText();
const m = txt.match(/lin_api_[A-Za-z0-9]+/);
const vals = await p.locator('input, code, pre').evaluateAll(e => e.map(x => (x.value || x.textContent || '').trim()).filter(v => v.startsWith('lin_api_')));
const key = (vals[0] || (m && m[0]) || '');
console.log('KEY:', key ? key.slice(0, 12) + '…' : 'NONE');
if (key) fs.writeFileSync(DIR + 'demo-key.txt', key);
await b.close();
