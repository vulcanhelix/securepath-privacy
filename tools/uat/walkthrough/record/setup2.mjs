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
p.setDefaultTimeout(20000);
await p.goto('https://linear.app/', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(5000);
const inputs = p.locator('input');
await inputs.nth(0).fill('GrowthstrategyHQ');
await inputs.nth(1).fill('growthstrategyhq-uat');
await p.waitForTimeout(1000);
await p.locator('button:has-text("Create workspace"), button[type="submit"]').first().click();
await p.waitForTimeout(8000);
console.log('after:', p.url(), '|', (await p.locator('body').innerText()).slice(0, 300).replace(/\n/g,' | '));
for (let i = 0; i < 8; i++) {
  const txt = (await p.locator('body').innerText()).slice(0, 200).replace(/\n/g, ' | ');
  const btns = await p.locator('button, [role="button"]').evaluateAll(e => e.map(x => x.textContent.trim()).filter(Boolean).slice(0, 14));
  const ins = await p.locator('input').evaluateAll(e => e.map(x => ({ph: x.placeholder, v: x.value})));
  console.log(`STEP${i}:`, txt, '| btns:', JSON.stringify(btns), '| in:', JSON.stringify(ins));
  await p.screenshot({ path: DIR + `step${i}.png` });
  const skip = p.locator('button:has-text("Skip"), a:has-text("Skip"), button:has-text("Continue"), button:has-text("Next"), button:has-text("Done"), button:has-text("Get started"), button:has-text("Finish")').first();
  if (await skip.count()) { await skip.click(); await p.waitForTimeout(3000); } else break;
}
await ctx.storageState({ path: DIR + 'state.json' });
console.log('done');
await b.close();
