// 計算《小工具往事》三語可見文案長度：中文算字元數（去空白），英文算詞數。
// 範圍：history.mjs 的頁面文案（hero、章節、年表、unsure、出處註記、UI）＋頁尾 CTA 與導覽字串。
// 用同一支腳本量改版前後，基準（12 章版）為繁中 8471、簡中 8477、英文 3767，
// 與任務檔記的 8448 / 8454 / 3637 在 1% 內。用法：node scripts/count-history.mjs
import { readFileSync } from 'node:fs';
import { history } from './history.mjs';
import { preview } from './preview.mjs';
import { copy } from './content.mjs';

for (const [lang, h] of Object.entries(history)) {
  const texts = [];
  const walk = (v) => { if (typeof v === 'string') texts.push(v); else if (Array.isArray(v)) v.forEach(walk); else if (v && typeof v === 'object') Object.values(v).forEach(walk); };
  walk(h.h1);
  texts.push(h.lede, h.meta, h.kicker, h.title, h.description, h.notice || '', h.home, h.stripLabel, h.tocLabel, h.lessonLabel, h.reset, h.navLink, h.ogTitle, h.ogAlt);
  texts.push(h.timelineTitle, h.timelineLede);
  h.timelineHead.forEach((t) => texts.push(t));
  h.chapters.forEach((c) => { texts.push(c.year, c.short, c.era, c.title, c.lesson || ''); c.body.forEach((t) => texts.push(t)); });
  h.timeline.forEach((r) => r.forEach((t) => t && texts.push(t)));
  texts.push(h.unsureTitle, h.unsureLede);
  h.unsure.forEach((t) => texts.push(t));
  texts.push(h.sourcesTitle, h.sourcesLede);
  h.sources.forEach(([, , , n]) => texts.push(n));
  texts.push(h.exUi.loading, h.exUi.reduced);
  const pc = preview[lang], cc = copy[lang];
  if (pc?.historyCta) walk(pc.historyCta);
  if (pc?.homeNav) texts.push(pc.homeNav);
  if (cc?.skip) texts.push(cc.skip);
  const all = texts.join(' ');
  console.log(`${lang}: ${all.replace(/\s+/g, '').length} 字元（去空白）/ ${(all.match(/[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*/g) || []).length} 詞`);
}
