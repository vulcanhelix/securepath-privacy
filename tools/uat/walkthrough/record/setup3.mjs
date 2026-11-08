import { chromium } from 'playwright';
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
p.setDefaultTimeout(25000);
await p.goto('https://linear.app/', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(5000);
console.log('page:', (await p.locator('body').innerText()).slice(0,150).replace(/\n/g,' | '));
const inputs = p.locator('input');
if (await inputs.count() >= 2 && await p.locator('text=/create a workspace/i').count()) {
  await inputs.nth(0).fill('GrowthstrategyHQ');
  await inputs.nth(1).fill('growthstrategyhq-uat2');
  await p.waitForTimeout(1000);
  await p.locator('button:has-text("Create workspace"), button[type="submit"]').first().click();
  console.log('creating workspace...');
  await p.waitForTimeout(9000);
}
console.log('after:', p.url());
// onboarding: skip everything until the app appears
for (let i = 0; i < 10; i++) {
  const url = p.url();
  const txt = (await p.locator('body').innerText()).slice(0, 120).replace(/\n/g, ' | ');
  console.log(`STEP${i} ${url}:`, txt);
  if (/linear\.app\/growthstrategyhq/.test(url) && /Inbox|My issues/i.test(txt)) { console.log('IN APP'); break; }
  const step = p.locator('button:has-text("Skip"), button:has-text("Continue"), button:has-text("Finish"), button:has-text("Done")').first();
  if (await step.count()) { await step.click(); await p.waitForTimeout(3500); }
  else { await p.waitForTimeout(3000); }
}
await p.waitForTimeout(4000);
await p.screenshot({ path: DIR + 'inapp.png' });
console.log('final url:', p.url());
await ctx.storageState({ path: DIR + 'state.json' });
console.log('STATE SAVED');
await b.close();
