// 排版量測：用本機 Chrome 的 headless + CDP 檢查三個寬度下的實際換行。
// 用法：node scripts/typography-probe.mjs [url] [out.json]
// 量：標題行組成、段落最後一行字數（孤字）、產品名是否被拆行、標題字距與行高。
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const url = process.argv[2] || 'http://127.0.0.1:4390/';
const out = process.argv[3] || '/tmp/typo-probe.json';
const PORT = 9401;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--remote-debugging-port=${PORT}`, '--user-data-dir=/tmp/hp-typo-probe', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let targets;
for (let i = 0; i < 40; i++) {
  await sleep(250);
  try { targets = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json(); if (targets.length) break; } catch {}
}
if (!targets?.length) { console.error('Chrome 沒起來'); chrome.kill(); process.exit(1); }
const page = targets.find((t) => t.type === 'page');

const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const pending = new Map();
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
};
const send = (method, params = {}) => new Promise((res) => {
  const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params }));
});
const evalJS = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
};

await send('Page.enable');
await send('Runtime.enable');

const PROBE = `(() => {
  const products = ['HomePlay','HomeView','ClioTalk','Smart Stack','Liquid Glass','CarPlay','System 6','Apple Vision','FaceTime','iMessage','Podcast'];
  const lineCount = (el) => el.getClientRects().length;
  // 把一段文字依 Range 實際 rect 分行，回傳每行字串
  function linesOf(el) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const chars = [];
    let n;
    while ((n = walker.nextNode())) {
      for (let i = 0; i < n.data.length; i++) chars.push([n, i]);
    }
    const lines = []; let cur = ''; let lastTop = null;
    for (const [node, i] of chars) {
      const r = document.createRange();
      r.setStart(node, i); r.setEnd(node, i + 1);
      const rect = r.getBoundingClientRect();
      if (!rect.height) continue;
      const top = Math.round(rect.top + rect.height / 2);
      if (lastTop === null || Math.abs(top - lastTop) <= 2) cur += node.data[i];
      else { lines.push(cur); cur = node.data[i]; }
      lastTop = top;
    }
    if (cur) lines.push(cur);
    return lines.map((s) => s.trim().replace(/\\s+/g, ' ')).filter(Boolean);
  }
  const out = { url: location.href, lang: document.documentElement.lang, width: innerWidth, headings: [], orphanParas: [], splitNames: [], metrics: {} };
  for (const sel of ['h1','h2','h3']) {
    for (const el of document.querySelectorAll(sel)) {
      const t = el.innerText.trim();
      if (!t) continue;
      const lines = linesOf(el);
      if (!lines.length) continue;
      const cs = getComputedStyle(el);
      out.headings.push({ tag: sel, text: t.slice(0, 60), lines, lastCount: lines[lines.length-1].length,
        fontSize: cs.fontSize, lineHeight: cs.lineHeight, letterSpacing: cs.letterSpacing, textWrap: cs.textWrap || cs.textWrapStyle || '' });
    }
  }
  for (const el of document.querySelectorAll('p, li')) {
    const t = el.innerText.trim();
    if (!t || t.length < 18) continue;
    const lines = linesOf(el);
    if (lines.length < 2) continue;
    const last = lines[lines.length - 1];
    // 純數字或符號（步驟編號、箭頭）不算孤字
    if (!/[\p{Script=Han}A-Za-z]/.test(last)) continue;
    if (last.length <= 4) out.orphanParas.push({ text: t.slice(0, 42), lastLine: last, lastCount: last.length, lines: lines.length, cls: el.className });
  }
  // 產品名是否被拆成兩行
  for (const el of document.querySelectorAll('h1,h2,h3,p,li,span,div')) {
    if (el.children.length && el.innerText.length > 200) continue;
    const t = el.textContent;
    if (!t) continue;
    for (const p of products) {
      let i = t.indexOf(p);
      while (i >= 0) {
        // 找 TEXT 節點位置
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        let n, acc = 0, pos = null;
        while ((n = walker.nextNode())) {
          if (i >= acc && i < acc + n.data.length) { pos = [n, i - acc]; break; }
          acc += n.data.length;
        }
        if (pos && pos[1] + p.length <= pos[0].data.length) {
          const r = document.createRange();
          r.setStart(pos[0], pos[1]); r.setEnd(pos[0], pos[1] + p.length);
          const rects = [...r.getClientRects()].filter((x) => x.width > 0);
          const tops = new Set(rects.map((x) => Math.round(x.top / 6)));
          if (tops.size > 1) out.splitNames.push({ name: p, text: t.slice(Math.max(0,i-10), i + p.length + 10) });
        }
        i = t.indexOf(p, i + 1);
      }
    }
  }
  const h1 = document.querySelector('h1');
  if (h1) { const cs = getComputedStyle(h1); out.metrics.h1 = { font: cs.fontFamily, fontSize: cs.fontSize, lineHeight: cs.lineHeight, letterSpacing: cs.letterSpacing }; }
  out.metrics.body = (() => { const cs = getComputedStyle(document.body); return { font: cs.fontFamily, fontSize: cs.fontSize, lineHeight: cs.lineHeight, textAutospace: cs.textAutospace || '(n/a)' }; })();
  return out;
})()`;

const results = [];
for (const width of [375, 768, 1440]) {
  await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: width < 800 });
  await send('Page.navigate', { url });
  await sleep(1200);
  await evalJS('document.fonts.ready.then(()=>1)');
  await sleep(300);
  results.push(await evalJS(PROBE));
}
ws.close();
chrome.kill();
writeFileSync(out, JSON.stringify(results, null, 2));
for (const r of results) {
  console.log(`\n=== ${r.width}px ${r.lang} ===`);
  console.log('body:', r.metrics.body.font.slice(0, 90), '| autospace:', r.metrics.body.textAutospace);
  for (const h of r.headings.slice(0, 6)) console.log(`  ${h.tag} "${h.text.slice(0,28)}" → ${h.lines.length} 行 最後${h.lastCount}字 | ${h.fontSize}/${h.lineHeight} ls=${h.letterSpacing}`);
  if (r.orphanParas.length) { console.log(`  孤字段落 ${r.orphanParas.length}:`); for (const o of r.orphanParas.slice(0, 6)) console.log(`    "${o.lastLine}" ← "${o.text}"`); }
  if (r.splitNames.length) { console.log(`  產品名被拆行 ${r.splitNames.length}:`); for (const s of r.splitNames.slice(0, 6)) console.log(`    ${s.name}: …${s.text}…`); }
}
