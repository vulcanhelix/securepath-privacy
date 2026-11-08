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
await p.goto('https://linear.app/growthstrategyhq-uat/issue/GRO-10', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(6000);
await p.evaluate(() => {
  document.querySelectorAll('div').forEach(e => {
    if (e.scrollHeight > e.clientHeight + 200) e.scrollTop = e.scrollHeight;
  });
});
await p.waitForTimeout(2000);

// ancestry + attrs of the LAST Submit comment button
const info = await p.locator('button[aria-label="Submit comment"]').last().evaluate(btn => {
  const rows = [];
  let el = btn;
  for (let d = 0; el && d < 8; d++, el = el.parentElement) {
    const r = el.getBoundingClientRect();
    rows.push({ d, tag: el.tagName, role: el.getAttribute('role')||'', ce: el.getAttribute('contenteditable')||'',
      dp: el.getAttribute('data-placeholder')||'', cls: (el.className||'').slice(0,60),
      y: Math.round(r.y), h: Math.round(r.height), kids: el.children.length });
  }
  // pseudo-element / attr-driven placeholder text hunt
  const ph = [];
  document.querySelectorAll('[data-placeholder],[placeholder],[aria-placeholder]').forEach(x => {
    const r = x.getBoundingClientRect();
    ph.push({ dp: x.getAttribute('data-placeholder')||x.getAttribute('placeholder')||x.getAttribute('aria-placeholder'),
      cls:(x.className||'').slice(0,50), y: Math.round(r.y) });
  });
  return { rows, ph };
});
console.log(JSON.stringify(info, null, 1));
await b.close();
