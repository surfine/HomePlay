// 用 CDP 在指定寬度截圖（Chrome CLI 的 --window-size 有最小寬度限制，手機寬度量不準）。
// 用法：node scripts/shot.mjs <url> <out.png> [width] [height]
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const [url, out, w = '375', h = '1400', at = ''] = process.argv.slice(2);
const PORT = 9402;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--remote-debugging-port=${PORT}`, '--user-data-dir=/tmp/hp-shot-cdp', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let page;
for (let i = 0; i < 40 && !page; i++) {
  await sleep(250);
  try { page = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()).find((t) => t.type === 'page'); } catch {}
}
if (!page) { console.error('Chrome 沒起來'); chrome.kill(); process.exit(1); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0; const pending = new Map();
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });

await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: +w, height: +h, deviceScaleFactor: 2, mobile: +w < 800 });
await send('Page.navigate', { url });
await sleep(1500);
await send('Runtime.evaluate', { expression: 'document.fonts.ready.then(()=>1)', awaitPromise: true });
await sleep(400);
if (at) { await send('Runtime.evaluate', { expression: `document.querySelector(${JSON.stringify(at)})?.scrollIntoView({block:'start'})` }); await sleep(1200); }
// 確認沒有橫向溢出
const ov = await send('Runtime.evaluate', { expression: 'JSON.stringify({iw:innerWidth, sw:document.documentElement.scrollWidth})', returnByValue: true });
console.log('viewport', w, ov.result?.result?.value);
// at 也可以用 "el:<選擇器>"：只拍那一個元素（產品截圖用，不受視窗高度限制）
let clip;
if (at.startsWith('el:')) {
  const sel = at.slice(3);
  // 先捲進視窗，讓 loading="lazy" 的圖真的載入，再取座標
  await send('Runtime.evaluate', { expression: `document.querySelector(${JSON.stringify(sel)})?.scrollIntoView({ block: 'center' })`, returnByValue: true });
  await sleep(1400);
  const res = await send('Runtime.evaluate', { expression: `(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return null; const b = e.getBoundingClientRect(); return { x: b.left + scrollX, y: b.top + scrollY, width: b.width, height: b.height }; })()`, returnByValue: true });
  const r = res.result?.result?.value;
  if (!r) { console.error('找不到元素', sel); chrome.kill(); process.exit(1); }
  clip = r;
}
const shot = await send('Page.captureScreenshot', clip
  ? { format: 'png', clip: { ...clip, scale: 1 }, captureBeyondViewport: true }
  : { format: 'png', captureBeyondViewport: false });
writeFileSync(out, Buffer.from(shot.result.data, 'base64'));
ws.close(); chrome.kill();
console.log('wrote', out);
