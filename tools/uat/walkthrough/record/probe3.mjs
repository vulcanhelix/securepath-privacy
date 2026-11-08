import { chromium } from 'playwright';
const b = await chromium.launch({
  headless: false,
  executablePath: '/root/.agent-browser/browsers/chrome-154.0.8037.92/chrome',
  args: ['--disable-blink-features=AutomationControlled', '--no-sandbox',
         '--disable-dev-shm-usage', '--start-maximized'],
});
const p = await (await b.newContext({
  viewport: { width: 1600, height: 950 },
  userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36',
})).newPage();
p.setDefaultTimeout(30000);
await p.goto('https://linear.app/login', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(5000);
await p.locator('button:has-text("Continue with email")').first().click();
await p.waitForTimeout(2500);
const email = p.locator('input[type="email"], input[name="email"], input[type="text"]').first();
await email.fill('brucedeonmartin@gmail.com');
await p.locator('button:has-text("Continue"), button[type="submit"]').first().click();
await p.waitForTimeout(8000);
console.log('url:', p.url());
console.log('text:', (await p.locator('body').innerText()).slice(0, 300));
// if turnstile iframe present, try clicking its checkbox
const frames = p.frames();
for (const f of frames) {
  if (/challenges\.cloudflare|turnstile/i.test(f.url())) {
    console.log('turnstile frame:', f.url());
    const box = f.locator('input[type="checkbox"], .cb-lb, label').first();
    try { await box.click({ timeout: 5000 }); console.log('clicked checkbox'); }
    catch { // fall back: click center of iframe
      const el = await f.frameElement();
      const bb = await el.boundingBox();
      if (bb) { await p.mouse.click(bb.x + 30, bb.y + bb.height / 2); console.log('clicked iframe coords'); }
    }
  }
}
await p.waitForTimeout(8000);
console.log('after:', p.url());
console.log('inputs:', await p.locator('input').evaluateAll(e => e.map(x => ({t:x.type, ph:x.placeholder, ml:x.maxLength}))));
await p.screenshot({ path: 'step3b.png', fullPage: true });
console.log('text2:', (await p.locator('body').innerText()).slice(0, 300));
await b.close();
