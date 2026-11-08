import { chromium } from 'playwright';
import fs from 'fs';
const DIR = new URL('.', import.meta.url).pathname;
const t0 = Date.now();
const markers = [];
const mark = (name) => { markers.push({ name, t: (Date.now() - t0) / 1000 }); console.log(`MARK ${name} ${markers[markers.length-1].t}s`); };

const b = await chromium.launch({
  headless: false,
  executablePath: '/root/.agent-browser/browsers/chrome-154.0.8037.92/chrome',
  args: ['--disable-blink-features=AutomationControlled', '--no-sandbox', '--disable-dev-shm-usage', '--window-position=0,0'],
});
const ctx = await b.newContext({
  storageState: DIR + 'state.json',
  viewport: { width: 1600, height: 950 },
  recordVideo: { dir: DIR + 'video', size: { width: 1600, height: 950 } },
});
await ctx.addInitScript(fs.readFileSync(DIR + 'cursor-init.js', 'utf8'));
const p = await ctx.newPage();
p.setDefaultTimeout(20000);

async function hover(sel, opts = {}) {
  const el = typeof sel === 'string' ? p.locator(sel).first() : sel;
  await el.waitFor({ state: 'visible' });
  const bb = await el.boundingBox();
  const cx = bb.x + (opts.x ?? bb.width / 2), cy = bb.y + (opts.y ?? bb.height / 2);
  const cur = await p.evaluate(() => window.__recCursor || { x: 800, y: 475 });
  await p.mouse.move(cur.x, cur.y);
  const steps = Math.max(12, Math.min(40, Math.hypot(cx - cur.x, cy - cur.y) / 18));
  await p.mouse.move(cx, cy, { steps: Math.round(steps) });
  await p.waitForTimeout(350);
  return el;
}
const click = async (sel, opts) => { const el = await hover(sel, opts); await el.click(); await p.waitForTimeout(700); };
const type = async (text, delay = 65) => p.keyboard.type(text, { delay });

mark('start');
await p.goto('https://linear.app/growthstrategyhq-uat/team/GRO/active', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(4500);
mark('issues');

// 1. New issue
await click('button:has-text("New issue"), a:has-text("New issue")');
await p.waitForTimeout(1200);
mark('composer');

// 2. Apply template
await click('[aria-label="Apply template"]');
await p.waitForTimeout(1000);
mark('template-picker');
await click('text=/UAT report/i');
await p.waitForTimeout(1500);
mark('template-applied');

// 3. Title
await click('[aria-label="Issue title"]');
await type('The footer shows the product name twice');
await p.waitForTimeout(600);
mark('title-done');

// 4. Answers — click after each bold prompt line and type the answer
const desc = p.locator('[aria-label="Issue description"]');
await desc.click();
const answers = [
  ['What happened:', ' The bottom of the page shows the product name two times.'],
  ['What you expected:', ' It should only show it once.'],
  ['Which page or screen:', ' The dashboard'],
];
for (const [prompt, ans] of answers) {
  // click at the end of the paragraph holding this prompt
  const para = desc.locator(`p:has-text("${prompt.replace(':', '\\:')}")`).first();
  const bb = await para.boundingBox();
  await p.mouse.move(bb.x + bb.width - 6, bb.y + bb.height / 2, { steps: 18 });
  await p.waitForTimeout(250);
  await p.mouse.click(bb.x + bb.width - 6, bb.y + bb.height / 2);
  await p.keyboard.press('End');
  await type(ans, 55);
  await p.waitForTimeout(500);
}
mark('answers-done');

// 5. Attach screenshot
try {
  const attach = p.locator('[aria-label*="Attach images"]').first();
  if (await attach.count()) {
    const [fc] = await Promise.all([
      p.waitForEvent('filechooser', { timeout: 6000 }),
      attach.click(),
    ]);
    await fc.setFiles(DIR + 'attachment.png');
    await p.waitForTimeout(1800);
    mark('attached');
  }
} catch (e) { console.log('attach skipped:', e.message.slice(0, 80)); }

// 6. Create issue
await click('button:has-text("Create issue")');
await p.waitForTimeout(2500);
mark('created');

// 7. hand off ticket-URL lookup to the helper, then open the real ticket
fs.writeFileSync(DIR + 'find-ticket', 'go');
{
  const dl = Date.now() + 30000;
  while (!fs.existsSync(DIR + 'ticket-url.txt') && Date.now() < dl) await p.waitForTimeout(500);
}
const ticketUrl = fs.readFileSync(DIR + 'ticket-url.txt', 'utf8').trim();
console.log('ticket url:', ticketUrl);
await p.goto(ticketUrl, { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(4000);
mark('on-ticket');

// 8. agent posts the fix-video comment via API meanwhile (watcher file)
fs.writeFileSync(DIR + 'post-comment', 'go');
await p.waitForTimeout(9000); // comment arrives via realtime sync
mark('comment-arrived');

// scroll the issue panel's inner scroll container to the bottom — the
// activity feed (comment + composers) is virtualized and only renders there
await p.evaluate(() => {
  document.querySelectorAll('div').forEach(e => {
    if (e.scrollHeight > e.clientHeight + 200) e.scrollTop = e.scrollHeight;
  });
});
await p.waitForTimeout(2500);

// 9. reply — the main "Leave a comment…" bar is CSS-generated text, so it
// can't be matched by text. Anchor off the LAST Submit comment button (the
// bottom composer); its 5th div ancestor is the clickable bar container.
const sendBtn0 = p.locator('button[aria-label="Submit comment"]').last();
await sendBtn0.waitFor({ state: 'visible' });
const replyBar = sendBtn0.locator('xpath=ancestor::div[5]');
await hover(replyBar);
await replyBar.click();
await p.waitForTimeout(1500);
const editor = p.locator('[contenteditable="true"]').last();
await editor.click();
await type('Yes, that\u2019s fixed — thank you!', 70);
await p.waitForTimeout(600);
mark('reply-typed');
await p.keyboard.press('Escape'); // close any popover that stole focus
await p.waitForTimeout(500);
const send = p.locator('button[aria-label="Submit comment"]').last();
try {
  await hover(send);
  await send.click({ timeout: 6000 });
} catch {
  await p.keyboard.press('Control+Enter');
}
await p.waitForTimeout(2500);
mark('done');

await ctx.close();
await b.close();
fs.writeFileSync(DIR + 'markers.json', JSON.stringify(markers, null, 1));
console.log('RECORDED');
