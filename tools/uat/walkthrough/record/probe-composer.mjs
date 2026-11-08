import { chromium } from 'playwright';
const DIR = new URL('.', import.meta.url).pathname;
const b = await chromium.launch({
  headless: false,
  executablePath: '/root/.agent-browser/browsers/chrome-154.0.8037.92/chrome',
  args: ['--disable-blink-features=AutomationControlled', '--no-sandbox', '--disable-dev-shm-usage'],
});
const ctx = await b.newContext({ storageState: DIR + 'state.json', viewport: { width: 1600, height: 950 } });
const p = await ctx.newPage();
p.setDefaultTimeout(20000);
await p.goto('https://linear.app/growthstrategyhq-uat/team/GRO/active', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(7000);
await p.screenshot({ path: DIR + 'issues.png' });
// open composer — "New issue" button or C key
const btn = p.locator('button:has-text("New issue"), a:has-text("New issue"), [aria-label*="New issue" i]').first();
console.log('new-issue btn:', await btn.count());
if (await btn.count()) await btn.click(); else await p.keyboard.press('c');
await p.waitForTimeout(3000);
await p.screenshot({ path: DIR + 'composer.png' });
const d = p.locator('[role="dialog"], [class*="modal" i], [class*="Modal"]').last();
console.log('dialog text:', (await d.innerText().catch(()=>'')).slice(0, 500).replace(/\n/g,' | '));
const inputs = await d.locator('input, [contenteditable], button').evaluateAll(e => e.map(x => ({
  tag: x.tagName, ph: x.placeholder || '', label: x.getAttribute('aria-label') || '',
  txt: (x.textContent || '').trim().slice(0, 40) })).slice(0, 40));
console.log(JSON.stringify(inputs, null, 0).slice(0, 4000));
await b.close();
