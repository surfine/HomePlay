// HomePlay 2.0 Preview 頁的版面（文案在 preview.mjs）。build.mjs 把共用的 head()、跳脫函式與連結常數傳進來，
// 這樣首頁與「小工具往事」的模板不必為這一頁改動。
// 節奏參考 Apple 發表新系統時的總覽頁：一句話的首屏 → 一排自動播放的亮點大卡 → 每個主題一段（小標、大標、導言、主視覺、卡片）→「還有更多」→ 界線與註腳。
// 素材全部是 homeplay-pet 現拍（scripts/render-preview.sh），/media/2.0/<語言>/<名字>-<寬>.{avif,webp}。
import { PREVIEW_SLUG } from './preview.mjs';

const PV = '/media/2.0/';
const SCREEN = [480, 960];   // 螢幕平面圖是正方形
const PROD = [640, 1100];    // 機身產品照 1100×1280
const PROD_H = (w) => Math.round(w * 1280 / 1100);
// App 卡片裡的三個重點（送出前先問你、開始烹飪、家庭）放寬一格，其餘一格；四排正好排滿
const WIDE = new Set(['app-messages-confirm', 'app-recipe-step', 'app-home']);
const FACE_ORDER = ['photos', 'modular', 'analog', 'flow', 'weather', 'calendar', 'growth', 'black', 'island', 'system6'];

export function previewPage(c, p, h) {
  const { head, attr, json, origin, github, notice, releaseDownload, betaDownload, LANGS, otherLangs } = h;
  const dir = `${PV}${c.lang}/`;
  const set = (n, ws, ext) => ws.map((w) => `${dir}${n}-${w}.${ext} ${w}w`).join(', ');
  // 一張螢幕圖：AVIF 優先、WebP 退路；正方形，圓角在 CSS（螢幕圓角 138/1024）
  const screen = (n, alt, { sizes = '(max-width: 820px) 86vw, 460px', lazy = true, cls = 'pv-screen', extra = '' } = {}) =>
    `<picture class="${cls}"${extra}><source type="image/avif" srcset="${set(n, SCREEN, 'avif')}" sizes="${sizes}"><img src="${dir}${n}-480.webp" srcset="${set(n, SCREEN, 'webp')}" sizes="${sizes}" width="960" height="960" alt="${attr(alt)}"${lazy ? ' loading="lazy"' : ''} decoding="async"></picture>`;
  const prod = (n, alt, { lazy = false, priority = false, cls = '' } = {}) =>
    `<picture class="pv-prod ${cls}"><source type="image/avif" srcset="${set(n, PROD, 'avif')}" sizes="(max-width: 820px) 88vw, 560px"><img src="${dir}${n}-640.webp" srcset="${set(n, PROD, 'webp')}" sizes="(max-width: 820px) 88vw, 560px" width="1100" height="${PROD_H(1100)}" alt="${attr(alt)}"${lazy ? ' loading="lazy"' : ''}${priority ? ' fetchpriority="high"' : ''} decoding="async"></picture>`;
  const seg = (label, items, key, cur) => `<div class="pv-seg" role="group" aria-label="${attr(label)}" data-seg="${key}"><i class="pv-seg-thumb" aria-hidden="true"></i>${items.map(([k, t]) => `<button type="button" data-k="${k}" aria-pressed="${k === cur}">${t}</button>`).join('')}</div>`;
  const head2 = (s, id) => `<div class="pv-head rv">${s.eyebrow ? `<p class="pv-eyebrow">${s.eyebrow}</p>` : ''}<h2 id="${id}-t">${s.title}</h2>${s.lede ? `<p class="pv-lede">${s.lede}</p>` : ''}</div>`;

  const suffix = PREVIEW_SLUG;
  const canonicalPath = c.path + suffix;
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
  const langLinks = otherLangs(c).map((l) => `<a href="${l.path}${suffix}" hreflang="${l.code}" lang="${l.code}">${l.label}</a>`).join('');
  const T = p.gallery.length;
  // 首屏機身圖預載：用 imagesrcset，瀏覽器挑跟 <picture> 一樣的那張
  const preloadHero = `<link rel="preload" as="image" type="image/avif" imagesrcset="${set('prod-island', PROD, 'avif')}" imagesizes="(max-width: 820px) 88vw, 560px" fetchpriority="high">`;

  return `<!doctype html>
<html lang="${c.htmlLang}">
<head>
${head(c, { title: p.title, description: p.description, canonicalPath, image: `/media/og-preview-${c.lang}.jpg`, imageAlt: p.ogAlt, ld, preload: false, suffix, ogTitle: p.ogTitle, keywords: p.keywords })}
${preloadHero}
<link rel="stylesheet" href="/preview.css?v=${h.PCSS_V}">
</head>
<body class="pv">
<img class="share-fallback" src="/media/share-square.jpg" width="512" height="512" alt="" hidden loading="lazy">
<a class="skip" href="#main">${c.skip}</a>
<header class="pv-bar"><div class="wrap">
  ${brand}
  <nav class="pv-nav" aria-label="${attr(p.navLabel)}"><span class="pv-nav-eyes" aria-hidden="true">👀</span><i class="pv-nav-thumb" aria-hidden="true"></i>${p.nav.map(([id, t]) => `<a href="#${id}">${t}</a>`).join('')}<a class="pv-nav-out" href="${c.path}${h.HISTORY_SLUG}">${p.navHistory}</a></nav>
  <div class="end"><nav class="langs" aria-label="${attr(c.langLabel)}">${langLinks}</nav></div>
</div></header>
<main id="main">

<section class="pv-hero" id="top" aria-labelledby="pv-h1">
  <div class="pv-hero-track">
    <div class="pv-hero-sticky">
      <div class="wrap pv-hero-copy">
        <p class="pv-kicker"><span class="pv-badge">Preview</span>${p.kicker.replace('Preview', '').trim()}</p>
        <h1 id="pv-h1">${p.h1}</h1>
        <p class="pv-hero-lede">${p.lede}</p>
        <div class="pv-ctas"><a class="btn btn-primary" href="${betaDownload}">${p.ctaBeta}</a><a class="btn btn-ghost" href="${releaseDownload}">${p.ctaDownload}</a></div>
      </div>
      <div class="pv-stage" id="pv-stage" data-state="face">
        ${prod('prod-island', p.heroAlt.face, { priority: true, cls: 'is-face' })}
        ${prod('prod-home', p.heroAlt.home, { lazy: true, cls: 'is-home' })}
      </div>
      <div class="pv-hero-foot">${seg(p.heroSwitchLabel, p.heroStates, 'hero', 'face')}<p class="pv-hero-note">${p.heroNote}</p></div>
    </div>
    <i class="pv-hero-flip" aria-hidden="true"></i>
  </div>
</section>

<section class="pv-sec pv-dark pv-overview" id="overview" aria-labelledby="overview-t">
  <div class="wrap"><h2 class="pv-h2-solo rv" id="overview-t">${p.galleryTitle}</h2></div>
  <div class="pv-gal" data-gal aria-roledescription="carousel" aria-label="${attr(p.galleryLabel)}">
    <ul class="pv-gal-track" role="list">
      ${p.gallery.map(([n, cap, alt], i) => `<li class="pv-tile pv-tile-${n}" id="pv-g${i + 1}" aria-roledescription="slide" aria-label="${attr(h.fill(p.galleryGo, i + 1, T))}"><div class="pv-tile-in"><p class="pv-tile-cap">${cap}</p><div class="pv-tile-media">${screen(n, alt, { sizes: '(max-width: 820px) 74vw, 520px' })}</div></div></li>`).join('\n      ')}
    </ul>
    <div class="wrap pv-gal-ctl">
      <div class="pv-dots" role="group" aria-label="${attr(p.galleryLabel)}">${p.gallery.map((_, i) => `<button type="button" data-i="${i}" aria-label="${attr(h.fill(p.galleryGo, i + 1, T))}"${i ? '' : ' aria-current="true"'}><i></i></button>`).join('')}</div>
      <button type="button" class="pv-round pv-play" data-play aria-label="${attr(p.galleryPause)}" data-pause-label="${attr(p.galleryPause)}" data-play-label="${attr(p.galleryPlay)}"><svg viewBox="0 0 20 20" aria-hidden="true" focusable="false"><path class="i-pause" d="M6 4h3v12H6zM11 4h3v12h-3z"/><path class="i-play" d="M6 4l10 6-10 6z"/></svg></button>
      <div class="pv-arrows"><button type="button" class="pv-round" data-step="-1" aria-label="${attr(p.galleryPrev)}"><svg viewBox="0 0 20 20" aria-hidden="true" focusable="false"><path d="M12.5 4 6.5 10l6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button><button type="button" class="pv-round" data-step="1" aria-label="${attr(p.galleryNext)}"><svg viewBox="0 0 20 20" aria-hidden="true" focusable="false"><path d="m7.5 4 6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div>
    </div>
  </div>
</section>

<section class="pv-sec pv-home" id="home" aria-labelledby="home-t"><div class="wrap">
  ${head2(p.home, 'home')}
  <div class="pv-feature pv-looks rv" data-swap="looks">
    <div class="pv-feature-media pv-swap">
      ${p.home.looks.map(([k, , alt], i) => screen(`home-${k}`, alt, { cls: `pv-screen${i ? '' : ' on'}`, extra: ` data-k="${k}"`, sizes: '(max-width: 820px) 80vw, 520px' })).join('\n      ')}
    </div>
    <div class="pv-feature-ctl">${seg(p.home.switchLabel, p.home.looks.map(([k, t]) => [k, t]), 'looks', 'light')}<p class="pv-note">${p.home.looksNote}</p></div>
  </div>
  <ul class="pv-cards pv-cards-3" role="list">
    ${p.home.cards.map(([n, t, alt]) => `<li class="pv-card rv"><div class="pv-card-media">${screen(n, alt, { sizes: '(max-width: 820px) 70vw, 300px' })}</div><p>${t}</p></li>`).join('\n    ')}
  </ul>
</div></section>

<section class="pv-sec pv-system" id="system" data-nav="home" aria-labelledby="system-t"><div class="wrap">
  ${head2(p.system, 'system')}
  <div class="pv-duo">
    <article class="pv-panel pv-la rv" data-swap="la">
      <div class="pv-panel-media pv-swap">
        ${screen('la-compact', p.system.laAlt.compact, { cls: 'pv-screen on', extra: ' data-k="compact"', sizes: '(max-width: 820px) 76vw, 400px' })}
        ${screen('la-expanded', p.system.laAlt.expanded, { extra: ' data-k="expanded"', sizes: '(max-width: 820px) 76vw, 400px' })}
      </div>
      <div class="pv-panel-text"><h3>${p.system.laTitle}</h3><p>${p.system.laBody}</p>
      <button type="button" class="pv-pill" data-toggle="la" aria-pressed="false" data-on="${attr(p.system.laToggle[1])}" data-off="${attr(p.system.laToggle[0])}">${p.system.laToggle[0]}</button></div>
    </article>
    <article class="pv-panel pv-cc rv">
      <div class="pv-panel-media">${screen('cc', p.system.ccAlt, { sizes: '(max-width: 820px) 76vw, 400px' })}</div>
      <div class="pv-panel-text"><h3>${p.system.ccTitle}</h3><p>${p.system.ccBody}</p></div>
    </article>
  </div>
</div></section>

<section class="pv-sec pv-dark pv-faces" id="faces" aria-labelledby="faces-t"><div class="wrap">
  ${head2(p.faces, 'faces')}
  <ul class="pv-wall" role="list">
    ${FACE_ORDER.map((f) => `<li class="pv-face rv">${screen(`face-${f}`, p.faces.altPrefix + p.faces.names[f], { sizes: '(max-width: 600px) 42vw, (max-width: 1100px) 30vw, 210px' })}<span>${p.faces.names[f]}</span></li>`).join('\n    ')}
  </ul>
  <div class="pv-era rv" data-swap="era">
    <div class="pv-era-text"><h3>${p.faces.eraTitle}</h3><p>${p.faces.eraBody}</p>${seg(p.faces.eraLabel, p.faces.eras.map(([k, t]) => [k, t]), 'era', '2026')}</div>
    <div class="pv-era-media pv-swap">
      ${p.faces.eras.map(([k, , alt]) => screen(`era-${k}`, alt, { cls: `pv-screen${k === '2026' ? ' on' : ''}`, extra: ` data-k="${k}"`, sizes: '(max-width: 820px) 80vw, 440px' })).join('\n      ')}
    </div>
  </div>
</div></section>

<section class="pv-sec pv-apps" id="apps" aria-labelledby="apps-t"><div class="wrap">
  ${head2(p.apps, 'apps')}
  <figure class="pv-weather rv">
    <div class="pv-weather-media">
      <video class="pv-screen" data-loop muted loop playsinline preload="none" poster="${dir}app-weather-rain-960.webp" width="960" height="960" aria-label="${attr(p.apps.weatherAlt)}"><source src="${dir}weather-rain.mp4" type="video/mp4"></video>
      <button type="button" class="pv-round pv-vid" data-vid aria-label="${attr(p.apps.pause)}" data-pause-label="${attr(p.apps.pause)}" data-play-label="${attr(p.apps.play)}"><svg viewBox="0 0 20 20" aria-hidden="true" focusable="false"><path class="i-pause" d="M6 4h3v12H6zM11 4h3v12h-3z"/><path class="i-play" d="M6 4l10 6-10 6z"/></svg></button>
    </div>
    <figcaption>${p.apps.weather}</figcaption>
  </figure>
  <ul class="pv-cards pv-cards-grid" role="list">
    ${p.apps.cards.map(([n, t, alt]) => `<li class="pv-card pv-c-${n} rv${WIDE.has(n) ? ' wide' : ''}"><div class="pv-card-media">${screen(n, alt, { sizes: '(max-width: 600px) 80vw, (max-width: 1100px) 40vw, 300px' })}</div><p>${t}</p></li>`).join('\n    ')}
  </ul>
</div></section>

<section class="pv-sec pv-dark pv-clio" id="cliotalk" aria-labelledby="cliotalk-t"><div class="wrap">
  ${head2(p.clio, 'cliotalk')}
  <div class="pv-steps rv" data-steps>
    <ol class="pv-steps-list" aria-label="${attr(p.clio.stepsLabel)}">
      ${p.clio.steps.map(([k, t, b], i) => `<li><button type="button" data-k="${k}" aria-pressed="${i === 0}"><span class="pv-step-n">${i + 1}</span><span class="pv-step-t">${t}</span><span class="pv-step-b">${b}</span><i class="pv-step-bar" aria-hidden="true"></i></button></li>`).join('\n      ')}
    </ol>
    <div class="pv-steps-media pv-swap">
      ${p.clio.steps.map(([k, , , alt], i) => screen(k, alt, { cls: `pv-screen${i ? '' : ' on'}`, extra: ` data-k="${k}"`, sizes: '(max-width: 820px) 80vw, 460px' })).join('\n      ')}
    </div>
  </div>
  <ul class="pv-points" role="list">${p.clio.cards.map((t) => `<li class="rv"><p>${t}</p></li>`).join('')}</ul>
</div></section>

<section class="pv-sec pv-family" id="family" aria-labelledby="family-t"><div class="wrap pv-family-grid">
  <div class="pv-family-media rv">${screen('people-greet', p.family.alt, { sizes: '(max-width: 820px) 86vw, 520px' })}</div>
  <div class="pv-family-text">
    ${head2(p.family, 'family')}
    <ul class="pv-points pv-points-col" role="list">${p.family.cards.map((t) => `<li class="rv"><p>${t}</p></li>`).join('')}</ul>
  </div>
</div></section>

<section class="pv-sec pv-more" id="more" aria-labelledby="more-t"><div class="wrap">
  <h2 class="pv-h2-solo rv" id="more-t">${p.more.title}</h2>
  <ul class="pv-bento" role="list">
    <li class="pv-b pv-b-devices rv"><div class="pv-devices" role="img" aria-label="${attr(p.more.devicesAlt)}"><div class="pv-ipad">${screen('home-light', '', { sizes: '(max-width: 820px) 50vw, 300px' })}</div><div class="pv-iphone">${screen('home-dark', '', { sizes: '(max-width: 820px) 28vw, 150px' })}</div></div><p>${p.more.devices}</p></li>
    <li class="pv-b pv-b-carplay rv"><svg class="pv-motif" viewBox="0 0 160 96" role="img" aria-label="${attr(p.more.carplayAlt)}"><rect x="18" y="14" width="40" height="68" rx="9" class="m-body"/><path d="M38 82 V90" class="m-body"/><path class="m-cable" d="M38 90 C 38 96 56 96 70 86"/><g class="m-waves"><path d="M92 36 a 20 20 0 0 1 0 26"/><path d="M104 28 a 32 32 0 0 1 0 42"/><path d="M116 20 a 44 44 0 0 1 0 58"/></g></svg><p>${p.more.carplay}</p></li>
    <li class="pv-b pv-b-glass rv"><div class="pv-glass-demo" aria-hidden="true"><span class="pv-glass-pill">👀</span></div><p>${p.more.glass}</p></li>
    <li class="pv-b pv-b-langs rv"><p class="pv-big" aria-hidden="true"><span lang="zh-Hant">繁</span><span lang="zh-Hans">简</span><span lang="en">En</span></p><p>${p.more.langs}</p></li>
    <li class="pv-b pv-b-open rv"><p class="pv-big" aria-hidden="true">GPL&#8209;3.0</p><p>${p.more.open}</p></li>
    <li class="pv-b pv-b-history rv"><ol class="pv-years" aria-hidden="true">${['1984', '1997', '2003', '2007', '2012', '2015', '2022', '2026'].map((y) => `<li>${y}</li>`).join('')}</ol><div class="pv-b-row"><p>${p.more.history}</p><a class="btn btn-ghost" href="${c.path}${h.HISTORY_SLUG}">${p.more.historyLink}</a></div></li>
  </ul>
</div></section>

<section class="pv-sec pv-limits" id="preview" aria-labelledby="preview-t"><div class="wrap">
  ${head2(p.preview, 'preview')}
  <ol class="pv-limit-list" role="list">${p.preview.limits.map((t) => `<li class="rv">${t}</li>`).join('')}</ol>
  <div class="pv-cta rv">
    <div><h3>${p.preview.ctaTitle}</h3><p>${p.preview.ctaBody}</p></div>
    <div class="pv-ctas"><a class="btn btn-primary" href="${betaDownload}">${p.ctaBeta}</a><a class="btn btn-ghost" href="${releaseDownload}">${p.ctaDownload}</a></div>
  </div>
  <aside class="pv-fn" aria-label="${attr(p.preview.footnotesLabel)}">
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
