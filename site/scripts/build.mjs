import { mkdir, rm, cp, writeFile } from 'node:fs/promises';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { copy, origin, github, notice, releaseDownload, FACES, FINISHES, LANGS } from './content.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const dist = path.join(root, 'dist');
// 每種語言用自己語言的屏幕渲染（render-media.py --lang en 拍到 renders/en/）；還沒拍的語言退回中文那套。
let R = '/media/renders/';
const rendersFor = (c) => (existsSync(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public', c.renders, 'face-idle.webp')) ? c.renders : '/media/renders/');
const esc = (s) => s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
const attr = esc;
// 轉成 <script type="application/json"> 內容：避開 </script> 與 <!--
const json = (o) => JSON.stringify(o).replaceAll('<', '\\u003c').replaceAll('&', '\\u0026');

// 渲染圖的像素尺寸（寬高屬性防版面位移）。
// 圖片寬高從 WebP 檔頭讀（兩種語言各拍一套，尺寸可能差幾個像素），避免版面跳動。
function webpSize(file) {
  const b = readFileSync(file);
  const kind = b.toString('ascii', 12, 16);
  if (kind === 'VP8X') return [1 + b.readUIntLE(24, 3), 1 + b.readUIntLE(27, 3)];
  if (kind === 'VP8L') { const v = b.readUInt32LE(21); return [(v & 0x3fff) + 1, ((v >> 14) & 0x3fff) + 1]; }
  return [b.readUInt16LE(26) & 0x3fff, b.readUInt16LE(28) & 0x3fff];
}
function sizesFor(dir) {
  const at = (n) => webpSize(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public', dir, n));
  return {
    face: at('face-idle.webp'), finish: at('finish-g4.webp'),
    spin: at('spin/00.webp'), apart: at('view-apart.webp'),
    moment: Object.fromEntries(['hello.webp', 'ambient-night.webp', 'asleep-night.webp'].map((m) => [m, at(m)])),
    style: at('style-island.webp'),
  };
}
let SIZE;
// /media/* 快取一天：網址後面加內容雜湊，檔案一換網址就換，不會被邊緣快取卡住舊圖。
const mediaRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const versions = new Map();
const version = (p) => {
  if (!versions.has(p)) {
    const f = path.join(mediaRoot, p);
    versions.set(p, existsSync(f) && !p.endsWith('/') ? createHash('sha256').update(readFileSync(f)).digest('hex').slice(0, 10) : '');
  }
  return versions.get(p);
};
const bust = (html) => html.replace(/\/media\/[^"'?\s)]+/g, (m) => (version(m) ? `${m}?v=${version(m)}` : m));
const assetVersion = (name) => createHash('sha256').update(readFileSync(path.join(root, name))).digest('hex').slice(0, 10);
const CSS_V = assetVersion('style.css');
const JS_V = assetVersion('app.js');
// app.js 動態載入的渲染圖：把這一頁那套圖的版本號交給它
// 鍵是相對於這套渲染圖目錄的檔名（含 spin/NN.webp）。
const webpsIn = (dir, sub = '') => (existsSync(path.join(mediaRoot, dir, sub)) ? readdirSync(path.join(mediaRoot, dir, sub)).filter((f) => f.endsWith('.webp')).map((f) => sub + f) : []);
const rendersVersions = (dir) => JSON.stringify(Object.fromEntries([...webpsIn(dir), ...webpsIn(dir, 'spin/'), ...webpsIn(dir, 'fx/')].map((f) => [f, version(dir + f)])));
// 開機 hello 逐格（不分語言）
const HELLO = '/media/renders/hello/';
const helloVersions = () => JSON.stringify(Object.fromEntries(webpsIn(HELLO).map((f) => [f, version(HELLO + f)])));
const SPIN_FRAMES = 36;
const SW = { g4: 'sw-g4', silver: 'sw-silver', starlight: 'sw-starlight', rose: 'sw-rose', gray: 'sw-gray' };
const fill = (tpl, k, v) => tpl.replace(`{${k}}`, v);
const alternates = LANGS.map((l) => ({ hreflang: l.code, href: origin + l.path }));
const stripTags = (h) => h.replace(/<[^>]+>/g, '');
const otherLangs = (c) => LANGS.filter((l) => l.key !== c.lang);

function head(c, { title, description, canonicalPath, image, imageAlt }) {
  const url = origin + canonicalPath;
  const img = origin + image;
  const others = otherLangs(c);
  const ld = {
    '@context': 'https://schema.org',
    '@graph': [
      { '@type': 'WebSite', '@id': `${origin}/#website`, name: c.siteName, url, inLanguage: c.htmlLang },
      {
        '@type': 'SoftwareSourceCode', name: 'HomePlay', description: c.description, codeRepository: github,
        programmingLanguage: 'Swift', runtimePlatform: 'macOS 14 or later', license: 'https://spdx.org/licenses/GPL-3.0-or-later.html',
        image: img, url, inLanguage: c.htmlLang,
      },
      {
        '@type': 'FAQPage', inLanguage: c.htmlLang,
        mainEntity: c.faq.map(([q, a]) => ({ '@type': 'Question', name: stripTags(q), acceptedAnswer: { '@type': 'Answer', text: stripTags(a) } })),
      },
    ],
  };
  return `<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${attr(description)}">
<meta name="keywords" content="${attr(c.keywords)}">
<meta name="robots" content="index,follow,max-image-preview:large">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#eceef1" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0f1114" media="(prefers-color-scheme: dark)">
<link rel="canonical" href="${url}">
${alternates.map((a) => `<link rel="alternate" hreflang="${a.hreflang}" href="${a.href}">`).join('\n')}
<link rel="alternate" hreflang="x-default" href="${origin}/">
<link rel="icon" href="/media/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/media/favicon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/media/favicon-16.png">
<link rel="icon" type="image/png" sizes="192x192" href="/media/icon-192.png">
<link rel="apple-touch-icon" sizes="180x180" href="/media/apple-touch-icon.png">
<link rel="preload" as="image" href="${R}face-idle.webp" fetchpriority="high">
<meta property="og:type" content="website">
<meta property="og:site_name" content="${c.siteName}">
<meta property="og:title" content="${attr(c.ogTitle)}">
<meta property="og:description" content="${attr(description)}">
<meta property="og:url" content="${url}">
<meta property="og:locale" content="${c.locale}">
${others.map((o) => `<meta property="og:locale:alternate" content="${o.locale}">`).join('\n')}
<meta property="og:image" content="${img}">
<meta property="og:image:type" content="image/jpeg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="${attr(imageAlt)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${attr(c.ogTitle)}">
<meta name="twitter:description" content="${attr(description)}">
<meta name="twitter:image" content="${img}">
<meta name="twitter:image:alt" content="${attr(imageAlt)}">
<script type="application/ld+json">${json(ld)}</script>
<link rel="stylesheet" href="/style.css?v=${CSS_V}">`;
}

function petImg(name, prefix, size, { on = false, lazy = false, priority = false, alt = '' } = {}) {
  return `<img${on ? ' class="on"' : ''} src="${R}${prefix}${name}.webp" data-name="${name}" width="${size[0]}" height="${size[1]}" alt="${alt}" decoding="async"${priority ? ' fetchpriority="high"' : ''}${lazy ? ' loading="lazy"' : ''}>`;
}

// 品牌的眼睛：照產品的 👀 語言——白色球面眼白、琥珀虹膜、深棕瞳孔、左上大高光；
// 閉眼仍用唐老鴨式的短下彎眼瞼線。瞳孔與眼皮由 app.js 用 transform 驅動。
// 照 Apple Color Emoji 的 👀 取樣：純白眼白、沿邊一圈枕形灰；虹膜上棕下金、大瞳孔深棕、左上一顆高光
const eye = (cx, cy) => `<g class="eye" data-cx="${cx}" data-cy="${cy}"><ellipse cx="${cx}" cy="${cy}" rx="36" ry="52" fill="url(#eye-sclera)"/><g class="pupil"><circle cx="${cx}" cy="${cy}" r="19.4" fill="url(#eye-iris)" stroke="#3c1b00" stroke-width="1.1" stroke-opacity=".9"/><circle cx="${cx}" cy="${cy}" r="12.4" fill="#291201"/><circle cx="${cx - 7.3}" cy="${cy - 10.9}" r="5.8" fill="#fff"/></g><path class="lid" d="M ${cx - 24} ${cy + 10} Q ${cx} ${cy + 26} ${cx + 24} ${cy + 10}" fill="none" stroke="#15181c" stroke-width="4.6" stroke-linecap="round" opacity="0"/></g>`;

// 亮點卡上的小動畫（純 SVG＋CSS；減少動態效果時靜止）
const MOTIF = {
  cable: `<svg viewBox="0 0 120 80" aria-hidden="true" focusable="false"><rect x="14" y="10" width="30" height="56" rx="7" class="m-line"/><path d="M29 66 V74" class="m-line"/><path class="m-cable" d="M29 74 C 29 78 40 78 52 70"/><g class="m-waves"><path d="M70 30 a 18 18 0 0 1 0 22"/><path d="M80 24 a 28 28 0 0 1 0 34"/><path d="M90 18 a 38 38 0 0 1 0 46"/></g></svg>`,
  faces: `<svg viewBox="0 0 120 80" aria-hidden="true" focusable="false"><rect x="18" y="16" width="84" height="48" rx="24" class="m-pill"/><g class="m-blink"><ellipse cx="50" cy="40" rx="10" ry="14" class="m-white"/><ellipse cx="72" cy="40" rx="10" ry="14" class="m-white"/><circle cx="46" cy="42" r="5.5" class="m-iris"/><circle cx="68" cy="42" r="5.5" class="m-iris"/></g></svg>`,
  siri: `<svg viewBox="0 0 120 80" aria-hidden="true" focusable="false"><rect x="10" y="22" width="40" height="36" rx="8" class="m-key m-press"/><text x="30" y="45" class="m-cap">F5</text><g class="m-wave">${[0, 1, 2, 3, 4, 5].map((i) => `<rect x="${62 + i * 9}" y="28" width="5" height="24" rx="2.5" class="w${i}"/>`).join('')}</g></svg>`,
  tiles: `<svg viewBox="0 0 120 80" aria-hidden="true" focusable="false"><rect x="16" y="12" width="40" height="40" rx="11" class="m-line"/><rect x="64" y="12" width="40" height="18" rx="9" class="m-pill"/><rect x="64" y="36" width="40" height="16" rx="8" class="m-line"/><rect x="16" y="58" width="88" height="10" rx="5" class="m-line"/></svg>`,
  keys: `<svg viewBox="0 0 120 80" aria-hidden="true" focusable="false">${['F7', 'F8', 'F9'].map((k, i) => `<g class="${i === 1 ? 'm-press' : ''}"><rect x="${8 + i * 36}" y="22" width="32" height="36" rx="7" class="m-key"/><text x="${24 + i * 36}" y="45" class="m-cap">${k}</text></g>`).join('')}</svg>`,
};

function page(c) {
  R = rendersFor(c);
  SIZE = sizesFor(R);
  const brand = `<a class="brand" href="${c.path}"><img src="/media/icon-192.png" width="26" height="26" alt="">HomePlay</a>`;
  const langLinks = otherLangs(c).map((l) => `<a href="${l.path}" hreflang="${l.code}" lang="${l.code}">${l.label}</a>`).join('');
  const first = Object.keys(c.faceNames)[0];
  const rowFace = c.rows[0][0];
  const i18n = {
    faceNames: c.faceNames, heroLabel: c.heroLabel, facesLabel: c.facesLabel,
    apart: c.apart, together: c.together, apartAlt: c.apartAlt, spinLabel: c.spinLabel, copyCode: c.copyCode, copied: c.copied,
  };
  return `<!doctype html>
<html lang="${c.htmlLang}">
<head>
${head(c, { title: c.title, description: c.description, canonicalPath: c.path, image: c.og, imageAlt: c.ogAlt })}
</head>
<body data-renders="${R}" data-renders-v='${rendersVersions(R)}' data-hello="${HELLO}" data-hello-v='${helloVersions()}'>
<img class="share-fallback" src="/media/share-square.jpg" width="512" height="512" alt="" hidden loading="lazy">
<div class="sky" aria-hidden="true"><i class="dawn"></i><i class="day"></i><i class="dusk"></i><i class="night"></i></div>
<div class="day-rail" aria-hidden="true"><span class="t t0">07:17</span><span class="t t1">23:59</span><i class="sun orb"></i><i class="moon orb"></i></div>
<a class="skip" href="#main">${c.skip}</a>
<header><div class="wrap">
  ${brand}
  <nav aria-label="${attr(c.navLabel)}">${c.nav.map(([id, t]) => `<a href="#${id}">${t}</a>`).join('')}</nav>
  <div class="end"><nav class="langs" aria-label="${attr(c.langLabel)}">${langLinks}</nav><a class="btn btn-ghost" href="${github}">${c.githubLabel}</a></div>
</div></header>
<main id="main">

<section class="hero" id="top"><div class="wrap">
  <div class="hero-copy">
    <h1>${c.h1}</h1>
    <p class="lede">${c.lede}</p>
    <div class="ctas"><a class="btn btn-primary" href="${releaseDownload}">${c.download}</a><a class="btn btn-ghost" href="${github}">${c.viewSource}</a></div>
    <p class="hero-note">${c.heroNote}</p>
  </div>
  <div class="hero-bob">
    <div class="pet hero-pet" id="hero-pet" role="img" aria-label="${attr(fill(c.heroLabel, 'face', c.faceNames[first]))}" data-prefix="face-" data-names="${FACES.join(' ')}" data-first="idle" data-w="${SIZE.face[0]}" data-h="${SIZE.face[1]}" data-blink="auto" data-glance="auto">
      ${petImg('idle', 'face-', SIZE.face, { on: true, priority: true })}
    </div>
  </div>
</div></section>

<section class="highlights" id="highlights"><div class="wrap">
  <div class="rise">
    <h2>${c.highlightsTitle}</h2>
    <p class="lede">${c.highlightsLede}</p>
  </div>
  <div class="hl-grid rise">
    ${c.highlights.map(([k, t, sub, body]) => `<article class="hl hl-${k}"><div class="hl-motif">${MOTIF[k]}</div><h3>${t}</h3><p class="hl-sub">${sub}</p><p>${body}</p></article>`).join('\n    ')}
  </div>
</div></section>

<section class="film" id="film"><div class="wrap">
  <div class="rise">
    <h2>${c.filmTitle}</h2>
    <p class="lede">${c.filmLede}</p>
  </div>
  <video class="film-video" controls playsinline preload="none" poster="/media/film/poster.webp" width="1920" height="1080" aria-label="${attr(c.filmLabel)}"><source src="/media/film/homeplay-44s.mp4" type="video/mp4"></video>
  <p class="film-alt"><a href="https://www.bilibili.com/video/BV1rTnz6YEmM/">${c.filmBili}</a></p>
</div></section>

<section class="why" id="why"><div class="wrap why-grid">
  <div class="why-text">
    <h2 class="rise">${c.essayTitle}</h2>
    <p class="lede">${c.essayLede}</p>
    <p class="essay-close">${c.essayClose}</p>
  </div>
  <div class="why-eyes">
    <div class="eyes-card" id="eyes" role="img" aria-label="${attr(c.eyesLabel)}">
      <svg viewBox="0 0 300 300" aria-hidden="true" focusable="false"><defs><radialGradient id="eye-sclera" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#fff"/><stop offset=".8" stop-color="#fdfdfd"/><stop offset=".89" stop-color="#e6e6e6"/><stop offset=".955" stop-color="#c2c2c2"/><stop offset="1" stop-color="#949494"/></radialGradient><linearGradient id="eye-iris" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5a2a00"/><stop offset=".42" stop-color="#683900"/><stop offset=".62" stop-color="#7a4800"/><stop offset=".8" stop-color="#b78600"/><stop offset=".92" stop-color="#e2ab00"/><stop offset="1" stop-color="#d9a400"/></linearGradient></defs>${eye(98, 142)}${eye(202, 142)}</svg>
    </div>
    <p class="eyes-hint">${c.eyesHint}</p>
  </div>
</div></section>

<section class="faces" id="faces"><div class="wrap">
  <div class="stick"><div class="pet still" id="face-pet" role="img" aria-label="${attr(fill(c.facesLabel, 'face', c.faceNames[rowFace]))}" data-prefix="face-" data-names="${FACES.join(' ')}" data-first="${rowFace}" data-w="${SIZE.face[0]}" data-h="${SIZE.face[1]}" data-blink="auto" data-glance="auto">
    ${petImg(rowFace, 'face-', SIZE.face, { on: true, lazy: true })}
  </div></div>
  <div class="rise">
    <h2>${c.facesTitle}</h2>
    <p class="lede">${c.facesLede}</p>
    <div class="rows" id="rows">
${c.rows.map(([f, t, r], i) => `      <button type="button" class="row${i ? '' : ' on'}" aria-pressed="${i === 0}" data-face="${f}"><span class="t">${t}</span><span class="r">${r}</span></button>`).join('\n')}
    </div>
  </div>
</div></section>

<section class="styles" id="styles"><div class="wrap">
  <div class="rise">
    <h2>${c.stylesTitle}</h2>
    <p class="lede">${c.stylesLede}</p>
  </div>
  <div class="style-grid rise">
    ${c.styles.map(([k, name]) => `<figure class="style"><img src="${R}style-${k}.webp" width="${SIZE.style[0]}" height="${SIZE.style[1]}" alt="${attr(name)}" loading="lazy" decoding="async"><figcaption>${name}</figcaption></figure>`).join('\n    ')}
  </div>
</div></section>

<section class="carplay" id="carplay"><div class="wrap"><div class="panel">
  <h2>${c.carplayTitle}</h2>
  <p class="lede">${c.carplayLede}</p>
  <div class="path" role="group" aria-label="${attr(c.pathLabel)}">
    ${c.flow.map(([b, s], i) => `${i ? '<div class="link" aria-hidden="true"><i class="dot"></i><i class="dot d2"></i><i class="dot back"></i></div>' : ''}<div class="node"><b>${b}</b><span>${s}</span></div>`).join('\n    ')}
  </div>
  <div class="first-use">
    <h3>${c.firstStepsTitle}</h3>
    <ol>
      ${c.firstSteps.map((t) => `<li>${t}</li>`).join('\n      ')}
    </ol>
  </div>
</div></div></section>

<section class="spin" id="spin"><div class="wrap">
  <div class="spin-head rise">
    <h2>${c.spinTitle}</h2>
    <p class="lede">${c.spinLede}</p>
  </div>
  <div class="spin-stage" id="spin-stage" tabindex="0" role="img" aria-label="${attr(c.spinLabel)}" data-frames="${SPIN_FRAMES}">
    <img class="spin-still" src="${R}spin/00.webp" width="${SIZE.spin[0]}" height="${SIZE.spin[1]}" alt="" loading="lazy" decoding="async">
    <canvas class="spin-canvas" aria-hidden="true"></canvas>
    <img class="spin-apart" src="${R}view-apart.webp" width="${SIZE.apart[0]}" height="${SIZE.apart[1]}" alt="" loading="lazy" decoding="async">
  </div>
  <p class="spin-hint" id="spin-hint">${c.spinHint}</p>
  <div class="spin-actions"><button type="button" class="btn btn-ghost" id="apart-btn" aria-pressed="false">${c.apart}</button></div>
  <div class="apart-parts">
    <p class="apart-note">${c.apartNote}</p>
    <ol>${c.apartParts.map((p, i) => `<li><span>${i + 1}</span>${p}</li>`).join('')}</ol>
  </div>
</div></section>

<section class="run" id="run"><div class="wrap">
  <div class="rise">
    <h2>${c.runTitle}</h2>
    <p class="lede">${c.runLede}</p>
    <div class="dl"><a class="btn btn-primary" href="${releaseDownload}">${c.download}</a><p class="dl-note">${c.downloadNote}</p></div>
  </div>
  <details class="build">
    <summary>${c.buildTitle}</summary>
    <ul>
      ${c.runList.map((t) => `<li>${t}</li>`).join('\n      ')}
    </ul>
    <div class="code"><pre><code>${c.code.map(([k, t]) => (k ? `<span class="c">${esc(t)}</span>` : esc(t))).join('\n')}</code></pre><button type="button" class="copy" id="copy" aria-live="polite" hidden>${c.copyCode}</button></div>
  </details>
</div></section>

<section id="faq"><div class="wrap faq">
  <h2 class="rise">${c.faqTitle}</h2>
  <div class="faq-list">
    ${c.faq.map(([q, a], i) => `<details${i ? '' : ' open'}><summary>${q}</summary><p>${a}</p></details>`).join('\n    ')}
  </div>
</div></section>

<section class="dev" id="dev"><div class="wrap">
  <figure class="dev-card rise">
    <div class="dev-eyes" aria-hidden="true">👀</div>
    <h2>${c.devTitle}</h2>
    <blockquote>${c.dev.map((t) => `<p>${t}</p>`).join('')}</blockquote>
    <figcaption>${c.devSign}</figcaption>
  </figure>
</div></section>

</main>
<footer><div class="wrap"><span>${c.footer}</span><span class="links"><a href="${github}">${c.footerLinks.github}</a><a href="${notice}">${c.footerLinks.notice}</a>${langLinks}</span></div></footer>
<script type="application/json" id="i18n">${json(i18n)}</script>
<script src="/app.js?v=${JS_V}" defer></script>
</body>
</html>
`;
}

function notFound() {
  const zh = copy['zh-Hant'], hans = copy['zh-Hans'], en = copy.en;
  return `<!doctype html>
<html lang="${zh.htmlLang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(zh.notFound.title)}</title>
<meta name="robots" content="noindex">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="/media/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/media/favicon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/media/favicon-16.png">
<link rel="icon" type="image/png" sizes="192x192" href="/media/icon-192.png">
<link rel="stylesheet" href="/style.css?v=${CSS_V}">
</head>
<body class="nf">
<main class="nf-main">
<img src="/media/icon-192.png" width="72" height="72" alt="">
<h1>${zh.notFound.h1}</h1>
<p>${zh.notFound.body}</p>
<p lang="zh-Hans" class="nf-en">${hans.notFound.h1} ${hans.notFound.body}</p>
<p lang="en" class="nf-en">${en.notFound.h1} ${en.notFound.body}</p>
<p class="ctas"><a class="btn btn-primary" href="${zh.notFound.homeHref}">${zh.notFound.home}</a><a class="btn btn-ghost" lang="zh-Hans" href="${hans.notFound.homeHref}">${hans.notFound.home}</a><a class="btn btn-ghost" lang="en" href="${en.notFound.homeHref}">${en.notFound.home}</a></p>
</main>
</body>
</html>
`;
}

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
await cp(path.join(root, 'public'), dist, { recursive: true });
for (const name of ['style.css', 'app.js']) await cp(path.join(root, name), path.join(dist, name));
for (const c of Object.values(copy)) {
  const target = path.join(dist, c.path.replace(/^\/|\/$/g, ''));
  await mkdir(target, { recursive: true });
  await writeFile(path.join(target, 'index.html'), bust(page(c)));
}
await writeFile(path.join(dist, '404.html'), bust(notFound()));
await writeFile(path.join(dist, 'robots.txt'), `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap.xml\n`);
const xlinks = alternates.map((a) => `<xhtml:link rel="alternate" hreflang="${a.hreflang}" href="${a.href}"/>`).join('') + `<xhtml:link rel="alternate" hreflang="x-default" href="${origin}/"/>`;
await writeFile(path.join(dist, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">${LANGS.map((l) => `<url><loc>${origin}${l.path}</loc>${xlinks}</url>`).join('')}</urlset>\n`);
await writeFile(path.join(dist, '_headers'), `/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  X-Frame-Options: DENY
  Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'
/media/*
  Cache-Control: public, max-age=86400
`);
await writeFile(path.join(dist, '_redirects'), [
  '/', ...LANGS.map((l) => l.path).filter((p) => p !== '/'),
].map((p) => `${p}index.html ${p} 301`).concat([
  // 舊 CarPlay 圖含真實地圖與地址；舊網址永久導向已撤換的無地圖版本。
  '/media/carplay.png /media/carplay-music.png 302',
  '/media/carplay-hevc.png /media/carplay-music.png 302',
]).join('\n') + '\n');
console.log(`Built ${LANGS.map((l) => l.code).join(', ')} pages in ${dist}`);
