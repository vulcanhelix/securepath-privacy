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
  userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36',
});
const p = await ctx.newPage();
p.setDefaultTimeout(20000);
await p.goto('https://linear.app/growthstrategyhq-uat/settings/security', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(5000);
await p.screenshot({ path: DIR + 'sec.png' });
console.log('page:', (await p.locator('body').innerText()).slice(0, 400).replace(/\n/g,' | '));
// find the create-key button
const btn = p.locator('button:has-text("New personal API key"), button:has-text("Create"), button:has-text("New key"), a:has-text("Personal API keys")').first();
console.log('btn:', await btn.count(), await btn.textContent().catch(()=>''));
if (await btn.count()) { await btn.click(); await p.waitForTimeout(3000); }
await p.screenshot({ path: DIR + 'sec2.png' });
console.log('page2:', (await p.locator('body').innerText()).slice(0, 400).replace(/\n/g,' | '));
const ins = await p.locator('input').evaluateAll(e => e.map(x => ({ph: x.placeholder, v: x.value, ro: x.readOnly})));
console.log('inputs:', JSON.stringify(ins));
// fill name if asked then submit
const nameField = p.locator('input[placeholder*="name" i], input[placeholder*="label" i]').first();
if (await nameField.count()) {
  await nameField.fill('uat-walkthrough');
  await p.locator('button:has-text("Create"), button:has-text("Save")').first().click();
  await p.waitForTimeout(3000);
}
// grab the key value — Linear shows it once in an input/code block
const all = await p.locator('input, code, [class*="key" i]').evaluateAll(e => e.map(x => x.value || x.textContent).filter(v => v && v.startsWith('lin_')));
console.log('KEY CANDIDATES:', all);
if (all.length) fs.writeFileSync(DIR + 'demo-key.txt', all[0]);
await p.screenshot({ path: DIR + 'sec3.png' });
await b.close();
