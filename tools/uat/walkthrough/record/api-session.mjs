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
await p.goto('https://linear.app/growthstrategyhq-uat', { waitUntil: 'domcontentloaded' }).catch(()=>{});
await p.waitForTimeout(6000);
const r = await p.evaluate(async (q) => {
  const res = await fetch('https://client-api.linear.app/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
    credentials: 'include',
  });
  return { status: res.status, body: await res.text() };
}, '{ viewer { email } teams { nodes { id name key } } }');
console.log(r.status, r.body.slice(0, 500));
fs.writeFileSync(DIR + 'api-result.json', r.body);
await b.close();
