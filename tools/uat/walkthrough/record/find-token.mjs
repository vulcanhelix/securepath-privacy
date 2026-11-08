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
await p.waitForTimeout(8000);
const ls = await p.evaluate(() => {
  const out = {};
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    const v = localStorage.getItem(k) || '';
    out[k] = v.length > 80 ? v.slice(0, 40) + `…len${v.length}` : v;
  }
  const ss = {};
  for (let i = 0; i < sessionStorage.length; i++) {
    const k = sessionStorage.key(i);
    ss[k] = (sessionStorage.getItem(k) || '').slice(0, 60);
  }
  return { ls: Object.keys(out), lsv: out, ss: Object.keys(ss), ssv: ss };
});
console.log('LS keys:', JSON.stringify(ls.ls, null, 1));
console.log('SS keys:', JSON.stringify(ls.ss, null, 1));
console.log('LS vals:', JSON.stringify(ls.lsv, null, 1).slice(0, 3000));
await b.close();
