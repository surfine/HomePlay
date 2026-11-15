// HomePlay 2.0 Preview 頁的版面（文案在 preview.mjs）。build.mjs 把共用的 head()、跳脫函式與連結常數傳進來。
// 共用首頁與小工具往事的設計系統（style.css 的 token、preview.css 的頁首膠囊導覽與按鈕）；這一頁自己的元件用 pp- 開頭，樣式在 preview.css 最後一段。
// 順序：首屏（是什麼、下載）→ 主畫面 → 即時動態與控制中心 → 錶面 → App → ClioTalk → 家人 → 其他 → 限制與下載。
// 素材全部是 homeplay-pet 現拍（scripts/render-preview.sh），/media/2.0/<語言>/<名字>-<寬>.{avif,webp}。
import { PREVIEW_SLUG, FACES } from './preview.mjs';

const PV = '/media/2.0/';
const SCREEN = [480, 960];   // 螢幕平面圖是正方形
const PROD = [640, 1100];    // 機身產品照 1100×1280
const PROD_H = (w) => Math.round(w * 1280 / 1100);

export function previewPage(c, p, h) {
  const { head, attr, origin, github, notice, releaseDownload, betaDownload, otherLangs } = h;
  const dir = `${PV}${c.lang}/`;
  const set = (n, ws, ext) => ws.map((w) => `${dir}${n}-${w}.${ext} ${w}w`).join(', ');
  // 一張螢幕圖：AVIF 優先、WebP 退路；正方形，圓角在 CSS（螢幕圓角 138/1024）
  const screen = (n, alt, { sizes = '(max-width: 820px) 86vw, 400px', cls = 'pp-screen', extra = '' } = {}) =>
    `<picture class="${cls}"${extra}><source type="image/avif" srcset="${set(n, SCREEN, 'avif')}" sizes="${sizes}"><img src="${dir}${n}-480.webp" srcset="${set(n, SCREEN, 'webp')}" sizes="${sizes}" width="960" height="960" alt="${attr(alt)}" loading="lazy" decoding="async"></picture>`;
  const prodSizes = '(max-width: 820px) 80vw, 460px';
  const prod = (n, alt) =>
    `<picture class="pp-prod"><source type="image/avif" srcset="${set(n, PROD, 'avif')}" sizes="${prodSizes}"><img src="${dir}${n}-640.webp" srcset="${set(n, PROD, 'webp')}" sizes="${prodSizes}" width="1100" height="${PROD_H(1100)}" alt="${attr(alt)}" fetchpriority="high" decoding="async"></picture>`;
  const shots = (list, sizes, cls = '') => `<ul class="pp-shots${cls}" role="list">${list.map(([n, cap, alt]) => `<li><figure>${screen(n, alt, { sizes })}<figcaption>${cap}</figcaption></figure></li>`).join('')}</ul>`;
  const head2 = (s, id) => `<div class="pp-head"><h2 id="${id}-t">${s.title}</h2>${s.lede ? `<p>${s.lede}</p>` : ''}</div>`;
  const stable = p.stable.replace('{href}', attr(releaseDownload));

  const canonicalPath = c.path + PREVIEW_SLUG;
  const url = origin + canonicalPath;
  const ld = {
    '@context': 'https://schema.org',
    '@graph': [
      { '@type': 'WebSite', '@id': `${origin}/#website`, name: c.siteName, url: origin + c.path, inLanguage: c.htmlLang },
      {
        '@type': 'WebPage', name: p.title, description: p.description, url, inLanguage: c.htmlLang, isPartOf: { '@id': `${origin}/#website` },
        primaryImageOfPage: `${origin}/media/og-preview-${c.lang}.jpg`,
        about: { '@type': 'SoftwareSourceCode', name: 'HomePlay', version: '2.0 Preview', codeRepository: github, programmingLanguage: 'Swift', runtimePlatform: 'macOS 14 or later', license: 'https://spdx.org/licenses/GPL-3.0-or-later.html' },
      },
    ],
  };
  const brand = `<a class="brand" href="${c.path}"><img src="/media/icon-192.png" width="26" height="26" alt="">HomePlay</a>`;
  const langLinks = otherLangs(c).map((l) => `<a href="${l.path}${PREVIEW_SLUG}" hreflang="${l.code}" lang="${l.code}">${l.label}</a>`).join('');
  // 首屏機身圖預載：用 imagesrcset，瀏覽器挑跟 <picture> 一樣的那張
  const preloadHero = `<link rel="preload" as="image" type="image/avif" imagesrcset="${set('prod-island', PROD, 'avif')}" imagesizes="${prodSizes}" fetchpriority="high">`;
  const download = `<a class="btn btn-primary" href="${betaDownload}">${p.ctaBeta}</a>`;

  return `<!doctype html>
<html lang="${c.htmlLang}">
<head>
${head(c, { title: p.title, description: p.description, canonicalPath, image: `/media/og-preview-${c.lang}.jpg`, imageAlt: p.ogAlt, ld, preload: false, suffix: PREVIEW_SLUG, ogTitle: p.ogTitle, keywords: p.keywords })}
${preloadHero}
<link rel="stylesheet" href="/preview.css?v=${h.PCSS_V}">
</head>
<body class="pv pv-page">
<img class="share-fallback" src="/media/share-square.jpg" width="512" height="512" alt="" hidden loading="lazy">
<a class="skip" href="#main">${c.skip}</a>
<header class="pv-bar"><div class="wrap">
  ${brand}
  <nav class="pv-nav" aria-label="${attr(p.navLabel)}"><span class="pv-nav-eyes" aria-hidden="true">👀</span>${p.nav.map(([id, t]) => `<a href="#${id}">${t}</a>`).join('')}<a class="pv-nav-out" href="${c.path}${h.HISTORY_SLUG}">${p.navHistory}</a></nav>
  <div class="end"><nav class="langs" aria-label="${attr(c.langLabel)}">${langLinks}</nav></div>
</div></header>
<main id="main">

<section class="pp-hero" id="top" aria-labelledby="pv-h1"><div class="wrap pp-hero-grid">
  <div class="pp-hero-copy">
    <p class="pp-kicker">${p.kicker}</p>
    <h1 id="pv-h1">${p.h1}</h1>
    <p class="pp-lede">${p.lede}</p>
    <div class="pp-action">${download}<p>${stable}</p></div>
    <p class="pp-small">${p.heroNote}</p>
  </div>
  <div class="pp-hero-media">${prod('prod-island', p.heroAlt.face)}</div>
</div></section>

<section class="pp-sec" id="home" aria-labelledby="home-t"><div class="wrap">
  <div class="pp-split">
    <div>
      ${head2(p.home, 'home')}
      <div class="pp-seg" role="group" aria-label="${attr(p.home.switchLabel)}" data-seg="looks">${p.home.looks.map(([k, t], i) => `<button type="button" data-k="${k}" aria-pressed="${i === 0}">${t}</button>`).join('')}</div>
    </div>
    <div class="pp-swap" id="looks">
      ${p.home.looks.map(([k, , alt], i) => screen(`home-${k}`, alt, { cls: `pp-screen${i ? '' : ' on'}`, extra: ` data-k="${k}"`, sizes: '(max-width: 820px) 86vw, 520px' })).join('\n      ')}
    </div>
  </div>
  ${shots(p.home.shots, '(max-width: 600px) 86vw, (max-width: 1100px) 30vw, 340px')}
</div></section>

<section class="pp-sec" id="system" data-nav="home" aria-labelledby="system-t"><div class="wrap">
  ${head2(p.system, 'system')}
  ${shots(p.system.shots, '(max-width: 600px) 86vw, (max-width: 1100px) 30vw, 340px')}
</div></section>

<section class="pp-sec" id="faces" aria-labelledby="faces-t"><div class="wrap">
  ${head2(p.faces, 'faces')}
  <ul class="pp-faces" role="list">
    ${FACES.map((f) => `<li><figure>${screen(`face-${f}`, p.faces.altPrefix + p.faces.names[f], { sizes: '(max-width: 600px) 28vw, (max-width: 1100px) 22vw, 170px' })}<figcaption>${p.faces.names[f]}</figcaption></figure></li>`).join('\n    ')}
  </ul>
</div></section>

<section class="pp-sec" id="apps" aria-labelledby="apps-t"><div class="wrap">
  ${head2(p.apps, 'apps')}
  ${shots(p.apps.shots, '(max-width: 600px) 43vw, (max-width: 1100px) 30vw, 250px', ' pp-shots-4')}
</div></section>

<section class="pp-sec" id="cliotalk" aria-labelledby="cliotalk-t"><div class="wrap">
  ${head2(p.clio, 'cliotalk')}
  <ol class="pp-shots pp-steps" role="list">${p.clio.shots.map(([n, cap, alt]) => `<li><figure>${screen(n, alt, { sizes: '(max-width: 600px) 86vw, (max-width: 1100px) 30vw, 340px' })}<figcaption>${cap}</figcaption></figure></li>`).join('')}</ol>
  <ul class="pp-points" role="list">${p.clio.points.map((t) => `<li>${t}</li>`).join('')}</ul>
</div></section>

<section class="pp-sec" id="family" aria-labelledby="family-t"><div class="wrap pp-split pp-split-rev">
  <div>
    ${head2(p.family, 'family')}
    <ul class="pp-points pp-points-col" role="list">${p.family.points.map((t) => `<li>${t}</li>`).join('')}</ul>
  </div>
  <div class="pp-family-media">${screen('people-greet', p.family.alt, { sizes: '(max-width: 820px) 86vw, 520px' })}</div>
</div></section>

<section class="pp-sec" id="more" aria-labelledby="more-t"><div class="wrap">
  <div class="pp-head"><h2 id="more-t">${p.more.title}</h2></div>
  <dl class="pp-more">${p.more.items.map(([t, d]) => `<div><dt>${t}</dt><dd>${d}</dd></div>`).join('')}</dl>
  <p class="pp-history">${p.more.history} <a href="${c.path}${h.HISTORY_SLUG}">${p.more.historyLink}</a></p>
</div></section>

<section class="pp-sec pp-limits" id="preview" aria-labelledby="preview-t"><div class="wrap">
  <div class="pp-head"><h2 id="preview-t">${p.preview.title}</h2></div>
  <ul class="pp-limit-list" role="list">${p.preview.limits.map((t) => `<li>${t}</li>`).join('')}</ul>
  <div class="pp-end">
    <h3>${p.preview.ctaTitle}</h3>
    <p>${p.preview.ctaBody}</p>
    <div class="pp-action">${download}<p>${stable}</p></div>
  </div>
  <aside class="pp-fn" aria-label="${attr(p.preview.footnotesLabel)}">
    <ol>${p.preview.footnotes.map((t, i) => `<li id="fn-${i + 1}">${t}</li>`).join('')}</ol>
    <p>${p.preview.trademark}</p>
  </aside>
</div></section>

</main>
<footer><div class="wrap"><span>${c.footer}</span><span class="links"><a href="${c.path}">${p.navHome}</a><a href="${github}">${c.footerLinks.github}</a><a href="${notice}">${c.footerLinks.notice}</a>${langLinks}</span></div></footer>
<script src="/preview.js?v=${h.PJS_V}" defer></script>
</body>
</html>
`;
}
