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
await p.goto('https://linear.app/growthstrategyhq-uat', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(6000);
console.log('url:', p.url());
console.log('page:', (await p.locator('body').innerText()).slice(0, 300).replace(/\n/g,' | '));
await p.screenshot({ path: DIR + 'resume.png' });
await ctx.storageState({ path: DIR + 'state.json' });
await b.close();
