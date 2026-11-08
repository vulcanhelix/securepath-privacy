import { chromium } from 'playwright';
const b = await chromium.launch({ headless: true });
const p = await (await b.newContext({ viewport: { width: 1440, height: 810 } })).newPage();
await p.goto('https://securepath.dev/login', { waitUntil: 'networkidle' }).catch(()=>{});
await p.waitForTimeout(4000);
await p.screenshot({ path: 'attachment.png' });
await b.close();
