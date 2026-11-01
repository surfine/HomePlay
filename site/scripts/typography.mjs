// 中文排版檢查（依 skills/chinese-web-typography 的規則，收斂成本倉庫自己的慣例）。
// 用法：node scripts/typography.mjs        # 掃 content/history/preview 的文案與 dist HTML
// 退出碼 1 = 有問題；check.mjs 會呼叫這裡，所以 npm run check 也會擋。
//
// 規則（刻意比 pangu 小的集合）：
//   1. 漢字與拉丁字母／數字相鄰要有空格（「10 款」「Mac 上」）；不採用 pangu 的引號前加空格。
//   2. 全形標點前後不加空格（「v1.0.2，macOS」不是「v1.0.2 ， macOS」）。
//   3. 中文引號內外不加空格（「他說“好”」，不是「他說 “好”」）。
//   4. 已保護的產品名要看得出來：短名用 NBSP 或 nowrap，不可讓它被拆行。
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CJK = '\\p{Script=Han}';
const HAN_PUNCT = '，。、；：！？「」『』（）《》〈〉…—';
// 收尾標點前不可有空格；開引號前可能是英文的詞間空格（as 「桌面」），不列入。
const CLOSE_PUNCT = '，。、；：！？」』）》〉…—';
const issues = [];

// 掃一個字串；name 用來指出位置。
// 行容器（<br>、.l 這種一行一個 span）視為段落分隔；其他行內標記直接移除，
// 這樣跨行內標記的真實黏字（例如 Home</b>Play）仍然會被檢查到。
const SEP = '\u0000';
function plainOf(text) {
  return text
    .replace(/<br\s*\/?>/gi, SEP)
    .replace(/<\/span>\s*<span class=\x22l[^\x22]*\x22>/g, SEP)
    .replace(/<\/?[a-z][^>]*>/gi, '');
}
function check(text, name) {
  for (const seg of plainOf(text).split(SEP)) {
    const plain = seg.trim();
    if (plain) checkSegment(plain, name);
  }
}
function checkSegment(plain, name) {
  // 規則 1：漢字 ↔ 拉丁／數字
  for (const m of plain.matchAll(new RegExp(`([${CJK}])([A-Za-z0-9])`, 'gu')))
    issues.push(`${name}: 漢字與拉丁／數字之間缺空格 → 「${ctx(plain, m.index)}」`);
  for (const m of plain.matchAll(new RegExp(`([A-Za-z0-9])([${CJK}])`, 'gu')))
    issues.push(`${name}: 拉丁／數字與漢字之間缺空格 → 「${ctx(plain, m.index)}」`);
  // 規則 2：全形標點旁的空格
  for (const m of plain.matchAll(new RegExp(`[A-Za-z0-9${CJK}]\\s+[${CLOSE_PUNCT}]`, 'gu')))
    issues.push(`${name}: 全形標點前多了空格 → 「${ctx(plain, m.index)}」`);
  for (const m of plain.matchAll(new RegExp(`[${HAN_PUNCT}]\\s+[A-Za-z0-9${CJK}]`, 'gu')))
    issues.push(`${name}: 全形標點後多了空格 → 「${ctx(plain, m.index)}」`);
  // 規則 3：引號內外
  for (const m of plain.matchAll(/[「『（“]\s+/gu)) issues.push(`${name}: 引號／括號後多了空格 → 「${ctx(plain, m.index)}」`);
  for (const m of plain.matchAll(/\s+[」』）”]/gu)) issues.push(`${name}: 引號／括號前多了空格 → 「${ctx(plain, m.index)}」`);
}
const ctx = (s, i) => s.slice(Math.max(0, i - 12), i + 16).replace(/\u0000/g, '⏎').replace(/\n/g, '⏎');

function walk(val, p, isEnglish) {
  if (typeof val === 'string') {
    if (!isEnglish && new RegExp(`[${CJK}]`, 'u').test(val)) check(val, p);
  } else if (Array.isArray(val)) val.forEach((v, i) => walk(v, `${p}[${i}]`, isEnglish));
  else if (val && typeof val === 'object') for (const [k, v] of Object.entries(val)) walk(v, `${p}.${k}`, isEnglish || k === 'en');
}

const here = path.dirname(fileURLToPath(import.meta.url));
for (const file of ['content.mjs', 'history.mjs', 'preview.mjs']) {
  const mod = await import(path.join(here, file));
  for (const [k, v] of Object.entries(mod)) if (k !== 'default') walk(v, `${file}:${k}`, false);
}

// dist HTML 也掃：抓文字節點（粗掃，抓漏用）
const dist = path.join(here, '..', 'dist');
try {
  const { readdir } = await import('node:fs/promises');
  const stack = [dist];
  while (stack.length) {
    const d = stack.pop();
    for (const e of await readdir(d, { withFileTypes: true })) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) stack.push(f);
      else if (e.name.endsWith('.html')) {
        const html = await readFile(f, 'utf8');
        // 逐文字節點檢查：不同元素之間沒有文字關係，黏在一起會產生假陽性。
        const body = html.replace(/<(script|style)[\s\S]*?<\/\1>/gi, '');
        for (const m of body.matchAll(/>([^<>]+)</g)) {
          const plain = m[1].trim();
          if (plain) checkSegment(plain, path.relative(dist, f));
        }
      }
    }
  }
} catch { /* 還沒 build 就只掃來源 */ }

if (issues.length) {
  console.error(`✗ 中文排版：${issues.length} 處`);
  for (const i of issues.slice(0, 40)) console.error('  ' + i);
  if (issues.length > 40) console.error(`  …還有 ${issues.length - 40} 處`);
  process.exit(1);
}
console.log('✓ 中文排版：空距與標點慣例一致');
