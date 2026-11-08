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
await p.goto('https://linear.app/', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(5000);
await p.screenshot({ path: DIR + 's1.png' });
console.log('page:', (await p.locator('body').innerText()).slice(0, 200).replace(/\n/g,' | '));

// "Create a workspace" form if fresh
if (await p.locator('input').count()) {
  const name = p.locator('input').first();
  await name.fill('GrowthstrategyHQ');
  await p.waitForTimeout(800);
  await p.screenshot({ path: DIR + 's2.png' });
  await p.locator('button:has-text("Create workspace"), button[type="submit"]').first().click();
  await p.waitForTimeout(6000);
}
console.log('after ws:', p.url(), (await p.locator('body').innerText()).slice(0, 250).replace(/\n/g,' | '));
await p.screenshot({ path: DIR + 's3.png' });
// onboarding steps: team name / "what do you want to track" etc — log every step's buttons
for (let i = 0; i < 6; i++) {
  const txt = (await p.locator('body').innerText()).slice(0, 180).replace(/\n/g, ' | ');
  const btns = await p.locator('button').evaluateAll(e => e.map(x => x.textContent.trim()).filter(Boolean).slice(0, 12));
  const inputs = await p.locator('input').evaluateAll(e => e.map(x => ({ph: x.placeholder, v: x.value})));
  console.log(`STEP${i}:`, txt, '| btns:', JSON.stringify(btns), '| inputs:', JSON.stringify(inputs));
  await p.screenshot({ path: DIR + `step${i}.png` });
  const skip = p.locator('button:has-text("Skip"), a:has-text("Skip"), button:has-text("Continue"), button:has-text("Next"), button:has-text("Done"), button:has-text("Get started")').first();
  if (await skip.count()) { await skip.click(); await p.waitForTimeout(3000); } else break;
}
await ctx.storageState({ path: DIR + 'state.json' });
console.log('done');
await b.close();
