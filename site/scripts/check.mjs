import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { copy, LANGS } from './content.mjs';
import { history, HISTORY_SLUG } from './history.mjs';
import { PREVIEW_SLUG } from './preview.mjs';

const root = fileURLToPath(new URL('../dist/', import.meta.url));
const origin = process.env.SITE_ORIGIN || 'https://homeplay.aaronlau.me';
const originHost = new URL(origin).host;
const okHosts = new Set([originHost, 'github.com', 'www.bilibili.com']);   // B 站只是演示影片的外連，頁面不從那裡載入任何東西
// 小工具往事的出處是外連（<a href>），不載入任何東西；只在那三頁、只對 href 放行這些主機。
const sourceHosts = new Set(Object.values(history).flatMap((h) => [...h.sources.map((s) => s[2]), ...h.chapters.flatMap((c) => c.links.map((l) => l[1]))]).map((u) => new URL(u).host));
const isHistory = (name) => name.endsWith(HISTORY_SLUG + 'index.html');
const isPreview = (name) => name.endsWith(PREVIEW_SLUG + 'index.html');   // 2.0 Preview：WebPage 而不是 FAQPage
const files = [];
async function walk(dir) {
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) await walk(p); else files.push(p);
  }
}
await walk(root);
const errors = [];
const rel = (f) => path.relative(root, f);
const exists = async (p) => { try { await stat(p); return true; } catch { return false; } };

// 把站內路徑（/x、/x/、https://origin/x）對到 dist 裡的檔案
const localTarget = (u) => {
  let p;
  if (u.startsWith('/') && !u.startsWith('//')) p = u;
  else { try { const x = new URL(u); if (x.host !== originHost) return null; p = x.pathname; } catch { return null; } }
  p = decodeURIComponent(p.split(/[?#]/)[0]);
  return path.join(root, p.endsWith('/') ? p + 'index.html' : p);
};

function jpegSize(buf) {
  if (buf[0] !== 0xff || buf[1] !== 0xd8) return null;
  let i = 2;
  while (i < buf.length) {
    if (buf[i] !== 0xff) { i++; continue; }
    const m = buf[i + 1];
    if (m >= 0xc0 && m <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(m)) return [buf.readUInt16BE(i + 7), buf.readUInt16BE(i + 5)];
    i += 2 + buf.readUInt16BE(i + 2);
  }
  return null;
}

let pages = 0;
for (const file of files) {
  const name = rel(file);
  if ((await stat(file)).size > 25 * 1024 * 1024) errors.push(`${name}: exceeds Pages asset limit`);
  if (file.endsWith('.js')) {
    const r = spawnSync(process.execPath, ['--check', file]);
    if (r.status) errors.push(`${name}: ${r.stderr}`);
  }
  if (file.endsWith('.js') || file.endsWith('.css')) {
    const t = await readFile(file, 'utf8');
    for (const m of t.matchAll(/https?:\/\/([^/\s"'`)]+)/g)) errors.push(`${name}: remote URL ${m[0]}`);
  }
  if (!file.endsWith('.html')) continue;
  pages++;
  const html = await readFile(file, 'utf8');
  const is404 = name === '404.html';

  // 1. 引用的本地資源都要存在（src / href / srcset / og:image / twitter:image）
  const refs = new Set();
  for (const m of html.matchAll(/\b(?:src|href|poster)="([^"]*)"/g)) refs.add(m[1]);
  for (const m of html.matchAll(/\bsrcset="([^"]*)"/g)) for (const part of m[1].split(',')) refs.add(part.trim().split(/\s+/)[0]);
  for (const m of html.matchAll(/<meta[^>]+(?:og:image|twitter:image)"[^>]*content="([^"]*)"/g)) refs.add(m[1]);
  for (const u of refs) {
    if (!u || u.startsWith('#') || u.startsWith('mailto:')) continue;
    // 3. 不載第三方：http(s) 只能是本站或 github.com
    if (/^(https?:)?\/\//.test(u)) {
      let host; try { host = new URL(u, origin).host; } catch { errors.push(`${name}: bad URL ${u}`); continue; }
      const outbound = isHistory(name) && sourceHosts.has(host) && !html.includes(`src="${u}"`);
      if (!okHosts.has(host) && !outbound) { errors.push(`${name}: third-party URL ${u}`); continue; }
      if (outbound) continue;
    }
    const t = localTarget(u);
    if (t && !(await exists(t))) errors.push(`${name}: missing ${u}`);
  }
  for (const m of html.matchAll(/href="#([^"]+)"/g)) if (!html.includes(`id="${m[1]}"`)) errors.push(`${name}: missing anchor #${m[1]}`);

  // 2. 必備 meta
  if (!/<title>[^<]+<\/title>/.test(html)) errors.push(`${name}: no <title>`);
  if ((html.match(/<h1[ >]/g) || []).length !== 1) errors.push(`${name}: expected exactly one h1`);
  if (!is404) {
    if (!/<meta name="description" content="[^"]+"/.test(html)) errors.push(`${name}: no meta description`);
    if (!/<link rel="canonical" href="https?:\/\/[^"]+"/.test(html)) errors.push(`${name}: no canonical`);
    if (!/<meta name="robots" content="index,follow,max-image-preview:large"/.test(html)) errors.push(`${name}: no robots meta`);
    if (!/<img class="share-fallback" src="\/media\/share-square\.jpg[^"]*" width="512" height="512"/.test(html) || !/<body[^>]*>\s*<img class="share-fallback"/.test(html)) errors.push(`${name}: share-fallback img must be the first element in <body>`);
    if (!isHistory(name) && !/<link rel="preload" as="image"[^>]*fetchpriority="high"/.test(html)) errors.push(`${name}: no hero image preload`);
    if ((html.match(/<h2[ >]/g) || []).length < 6) errors.push(`${name}: expected section h2s`);
    for (const k of ['og:title', 'og:description', 'og:image', 'og:url', 'twitter:card', 'twitter:image']) if (!html.includes(`"${k}"`)) errors.push(`${name}: no ${k}`);
    const alts = [...html.matchAll(/<link rel="alternate" hreflang="([^"]+)"/g)].map((m) => m[1]);
    for (const l of ['zh-Hant', 'zh-Hans', 'en', 'x-default']) if (!alts.includes(l)) errors.push(`${name}: no hreflang ${l}`);
    const og = html.match(/property="og:image" content="([^"]+)"/);
    if (og) {
      const t = localTarget(og[1]);
      if (!t) errors.push(`${name}: og:image is not on the site origin`);
      else if (await exists(t)) {
        const sz = jpegSize(await readFile(t));
        if (!sz) errors.push(`${name}: og:image is not a JPEG`);
        else if (sz[0] !== 1200 || sz[1] !== 630) errors.push(`${name}: og:image is ${sz[0]}x${sz[1]}, want 1200x630`);
      }
    }
    for (const m of html.matchAll(/<img\b[^>]*>/g)) if (!/\bwidth="\d+"/.test(m[0]) || !/\bheight="\d+"/.test(m[0])) errors.push(`${name}: img without width/height ${m[0].slice(0, 80)}`);
  }

  // 破折號（U+2014 / U+2013）一律不出現（含屬性與 JSON 文案）
  const noStyle = html.replace(/<!--[\s\S]*?-->/g, '');
  if (/[–—]/.test(noStyle)) errors.push(`${name}: contains an em or en dash`);

  // 4. CSP：沒有行內處理器、行內樣式、行內腳本
  if (/<[^>]+\son[a-z]+\s*=/i.test(html)) errors.push(`${name}: inline on* handler`);
  if (/<[^>]+\sstyle\s*=/i.test(html)) errors.push(`${name}: inline style attribute`);
  if (/<style[\s>]/i.test(html)) errors.push(`${name}: inline <style>`);
  for (const m of html.matchAll(/<script\b([^>]*)>/gi)) {
    const a = m[1];
    if (/\bsrc=/.test(a)) continue;
    if (!/type="application\/(ld\+)?json"/.test(a)) errors.push(`${name}: inline <script> without type="application/json" or "application/ld+json"`);
  }
  // JSON-LD 要能 parse，並含 FAQPage（題數與文案一致）
  if (!is404) {
    const lds = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
    if (!lds.length) errors.push(`${name}: no ld+json`);
    const lang = LANGS.find((l) => (l.path === '/' ? 'index.html' : l.path.slice(1) + 'index.html') === name);
    for (const m of lds) {
      let j; try { j = JSON.parse(m[1]); } catch (e) { errors.push(`${name}: ld+json does not parse (${e.message})`); continue; }
      const g = j['@graph'] || [j];
      const faq = g.find((x) => x['@type'] === 'FAQPage');
      if (isPreview(name)) {
        const pg = g.find((x) => x['@type'] === 'WebPage');
        if (!pg || !pg.name || !pg.about) errors.push(`${name}: ld+json has no WebPage with name and about`);
        if (!g.some((x) => x['@type'] === 'WebSite')) errors.push(`${name}: ld+json has no WebSite`);
        continue;
      }
      if (isHistory(name)) {
        const art = g.find((x) => x['@type'] === 'Article');
        if (!art || !art.headline || !art.citation?.length) errors.push(`${name}: ld+json has no Article with headline and citations`);
        if (!g.some((x) => x['@type'] === 'WebSite')) errors.push(`${name}: ld+json has no WebSite`);
        continue;
      }
      if (!faq) errors.push(`${name}: ld+json has no FAQPage`);
      else if (lang && faq.mainEntity.length !== copy[lang.key].faq.length) errors.push(`${name}: FAQPage has ${faq.mainEntity.length} questions, want ${copy[lang.key].faq.length}`);
      for (const t of ['WebSite', 'SoftwareSourceCode']) if (!g.some((x) => x['@type'] === t)) errors.push(`${name}: ld+json has no ${t}`);
    }
    for (const l of LANGS) if (name === l.path.slice(1) + PREVIEW_SLUG + 'index.html' && !html.includes(`<html lang="${copy[l.key].htmlLang}"`)) errors.push(`${name}: wrong html lang`);
    for (const l of LANGS) if (name === l.path.slice(1) + HISTORY_SLUG + 'index.html' && !html.includes(`<html lang="${copy[l.key].htmlLang}"`)) errors.push(`${name}: wrong html lang`);
    for (const l of LANGS) if (name === (l.path === '/' ? 'index.html' : l.path.slice(1) + 'index.html')) {
      const c = copy[l.key];
      if (!html.includes(`<html lang="${c.htmlLang}"`)) errors.push(`${name}: wrong html lang`);
      const og = html.match(/property="og:image" content="([^"]+)"/);
      if (!og || !og[1].includes(c.og)) errors.push(`${name}: og:image should be ${c.og}`);
    }
  }
  if (/javascript:/i.test(html)) errors.push(`${name}: javascript: URL`);
}
// 分享方圖、逐格素材
{
  const sq = await readFile(path.join(root, 'media/share-square.jpg')).catch(() => null);
  const sz = sq && jpegSize(sq);
  if (!sz) errors.push('media/share-square.jpg missing or not a JPEG');
  else if (sz[0] !== 512 || sz[1] !== 512) errors.push(`share-square.jpg is ${sz[0]}x${sz[1]}, want 512x512`);
  for (const l of LANGS) {
    const c = copy[l.key];
    const dir = c.renders.replace(/^\//, '');
    for (let i = 0; i < 36; i++) if (!(await exists(path.join(root, dir, 'spin', String(i).padStart(2, '0') + '.webp')))) errors.push(`${l.key}: missing ${dir}spin/${String(i).padStart(2, '0')}.webp`);
    if (!(await exists(path.join(root, dir, 'view-apart.webp')))) errors.push(`${l.key}: missing ${dir}view-apart.webp`);
    for (const f of ['fx/blink-face-idle.webp', 'fx/blink-face-thinking.webp', 'fx/glance-face-idle.webp',
                     'fx/blink-finish-g4.webp', 'fx/glance-finish-g4.webp', 'fx/blink-ambient-night.webp'])
      if (!(await exists(path.join(root, dir, f)))) errors.push(`${l.key}: missing ${dir}${f}`);
  }
  for (let i = 0; i < 16; i++) if (!(await exists(path.join(root, 'media/renders/hello', String(i).padStart(2, '0') + '.webp')))) errors.push(`missing renders/hello/${String(i).padStart(2, '0')}.webp`);
}
for (const need of ['_headers', '_redirects', 'robots.txt', 'sitemap.xml', '404.html', 'style.css', 'app.js', 'history.css', 'history.js', 'preview.css', 'preview.js', ...LANGS.map((l) => l.path.slice(1) + PREVIEW_SLUG + 'index.html'), 'index.html', 'en/index.html', 'zh-hans/index.html', ...LANGS.map((l) => l.path.slice(1) + HISTORY_SLUG + 'index.html')]) {
  if (!files.some((f) => rel(f) === need)) errors.push(`missing ${need}`);
}
const headers = await readFile(path.join(root, '_headers'), 'utf8').catch(() => '');
if (!headers.includes("default-src 'self'") || !headers.includes("frame-ancestors 'none'")) errors.push('_headers: CSP missing');

if (errors.length) { console.error(errors.join('\n')); process.exit(1); }
console.log(`OK: ${files.length} files, ${pages} HTML pages. Local references, meta, hreflang (zh-Hant, zh-Hans, en, x-default), JSON-LD with FAQPage, 1200x630 JPEG share cards, 512x512 share-square, spin, hello and blink/glance frames, no dashes, no third-party hosts, CSP-clean (no inline handlers, styles or scripts).`);
