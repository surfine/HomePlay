// 小工具往事：頁面本身的小事，加上展品的共用執行環境（HX）。沒有框架、沒有行內處理器（CSP 不允許）。
// 每件展品是 exhibits/<id>.js，建置時接在這個檔案後面；它們只呼叫 HX.register(id, init)。
// 展品在載入後依序初始化；離開畫面時，用 api.whileVisible 停掉動畫與計時器。
(() => {
  const doc = document;
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  const I = (() => { try { return JSON.parse(doc.getElementById('hx-i18n').textContent); } catch { return { ex: {}, ui: {} }; } })();
  const hasIO = 'IntersectionObserver' in window;

  // ── 展品執行環境 ──
  const inits = new Map();
  const HX = {
    lang: I.lang || doc.documentElement.lang,
    get reduced() { return motion.matches; },
    register(id, init) { inits.set(id, init); },
    // 共用小工具：建元素（不碰 style 屬性：CSP 不允許行內樣式，位置一律用 CSS 變數或 class）
    el(tag, props = {}, kids = []) {
      const e = doc.createElement(tag);
      for (const [k, v] of Object.entries(props)) {
        if (v == null || v === false) continue;
        if (k === 'class') e.className = v;
        else if (k === 'text') e.textContent = v;
        else if (k === 'html') e.innerHTML = v;
        else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
        else if (k === 'vars') for (const [n, x] of Object.entries(v)) e.style.setProperty(n, x);
        else e.setAttribute(k, v === true ? '' : v);
      }
      for (const c of [].concat(kids)) if (c != null) e.append(c);
      return e;
    },
    fmt: (s, vars = {}) => String(s).replace(/\{(\w+)\}/g, (m, k) => (k in vars ? vars[k] : m)),
  };
  window.HX = HX;

  function mount(fig) {
    const id = fig.dataset.ex;
    const init = inits.get(id);
    if (!init || fig.dataset.ready) return;
    fig.dataset.ready = '1';
    const stage = fig.querySelector('.ex-stage');
    const status = fig.querySelector('.ex-status');
    const resetBtn = fig.querySelector('.ex-reset');
    stage.replaceChildren();
    const resets = [];
    let visible = false;
    const watchers = [];
    const api = {
      id, root: fig, stage, s: I.ex[id] || {}, lang: HX.lang,
      get reduced() { return motion.matches; },
      say(text) { status.textContent = text; },
      onReset(fn) { resets.push(fn); resetBtn.hidden = false; },
      // 只在展品看得到時跑：start() 進畫面時呼叫，stop() 離開時呼叫
      whileVisible(start, stop) { watchers.push([start, stop]); if (visible) start(); },
      el: HX.el, fmt: HX.fmt,
    };
    resetBtn.addEventListener('click', () => { resets.forEach((f) => f()); if (api.s.idle) api.say(api.s.idle); });
    if (hasIO) new IntersectionObserver((es) => es.forEach((e) => {
      if (e.isIntersecting === visible) return;
      visible = e.isIntersecting;
      watchers.forEach(([a, b]) => (visible ? a() : b && b()));
    }), { threshold: 0.05 }).observe(fig);
    else { visible = true; }
    try { init(api); } catch (err) { console.error(`exhibit ${id}`, err); stage.append(HX.el('p', { class: 'ex-noscript', text: api.s.sr || '' })); }
    if (!hasIO) watchers.forEach(([a]) => a());
  }
  const figs = [...doc.querySelectorAll('.ex[data-ex]')];
  // 全部在載入後依序掛上（空閒時一件一件來）：展品長出高度不會在讀者捲動或點目錄時把頁面推走。
  // 動畫與計時器仍只在看得到時跑（whileVisible）。
  const idle = window.requestIdleCallback || ((f) => setTimeout(f, 16));
  const start = () => { let i = 0; const next = () => { if (i < figs.length) { mount(figs[i++]); idle(next); } }; next(); };
  // exhibits/*.js 接在本檔之後執行；等它們都註冊完再掛上
  if (doc.readyState === 'loading') doc.addEventListener('DOMContentLoaded', start); else setTimeout(start, 0);

  // ── 章節進場（減少動態效果時直接顯示）──
  const chapters = [...doc.querySelectorAll('.ch')];
  if (motion.matches || !hasIO) chapters.forEach((el) => el.classList.add('in'));
  else {
    const io = new IntersectionObserver((es) => es.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }), { rootMargin: '0px 0px -8% 0px' });
    chapters.forEach((el) => io.observe(el));
  }

  // ── 閱讀進度：只寫一個 CSS 變數，rAF 合併 ──
  const bar = doc.querySelector('.read-bar');
  if (bar && !motion.matches) {
    const root = doc.documentElement;
    let queued = false;
    const update = () => {
      queued = false;
      const max = root.scrollHeight - innerHeight;
      bar.style.setProperty('--read', (max > 0 ? Math.min(1, Math.max(0, scrollY / max)) : 0).toFixed(4));
    };
    const queue = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
    addEventListener('scroll', queue, { passive: true });
    addEventListener('resize', queue, { passive: true });
    update();
  }

  // ── 頁首目錄膠囊：走到哪一段亮哪一個 ──
  // 和 2.0 頁同一條膠囊：亮片（.pv-nav-thumb）滑到目前那一格；出站連結（另一頁）不參加
  const chips = [...doc.querySelectorAll('header nav:not(.langs) a[href^="#"]')];
  const thumb = doc.querySelector('.pv-nav-thumb');
  const place = (a) => { if (!thumb) return; if (!a) { thumb.style.setProperty('--o', '0'); return; } thumb.style.setProperty('--x', a.offsetLeft + 'px'); thumb.style.setProperty('--w', a.offsetWidth + 'px'); thumb.style.setProperty('--o', '1'); };
  if (chips.length && hasIO) {
    const byId = new Map(chips.map((a) => [a.getAttribute('href').slice(1), a]));
    let cur = null;
    addEventListener('resize', () => place(cur), { passive: true });
    const io = new IntersectionObserver((es) => es.forEach((e) => {
      if (!e.isIntersecting) return;
      chips.forEach((c) => c.removeAttribute('aria-current'));
      const a = byId.get(e.target.id); if (a) a.setAttribute('aria-current', 'true');
      cur = a || null; place(cur);
    }), { rootMargin: '-35% 0px -55% 0px' });
    byId.forEach((_, id) => { const s = doc.getElementById(id); if (s) io.observe(s); });
  }
})();
