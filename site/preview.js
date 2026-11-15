// HomePlay 2.0 Preview 頁的互動：主畫面外觀的分段按鈕，以及導覽標出目前讀到的段落。
// 沒有框架、沒有行內處理器（CSP 不允許）；不監聽頁面 scroll，位置交給 IntersectionObserver。
// 換圖只換 opacity（CSS 裡 200ms，減少動態效果時直接切）。
(() => {
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  // ── 分段按鈕：按下的那一格 aria-pressed，對應的圖加 .on ──
  $$('.pp-seg').forEach((seg) => {
    const btns = $$('button', seg);
    const box = document.getElementById(seg.dataset.seg);
    const pick = (b) => {
      btns.forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
      if (box) $$(':scope > [data-k]', box).forEach((el) => el.classList.toggle('on', el.dataset.k === b.dataset.k));
    };
    btns.forEach((b, i) => {
      b.addEventListener('click', () => pick(b));
      // 左右鍵在同一組裡移動
      b.addEventListener('keydown', (e) => {
        const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
        if (!d) return;
        e.preventDefault();
        const n = btns[(i + d + btns.length) % btns.length];
        n.focus();
        pick(n);
      });
    });
  });

  // ── 導覽：段落經過視窗中間一條線時，對應的連結加 aria-current ──
  const nav = document.querySelector('.pv-nav');
  if (!nav || !('IntersectionObserver' in window)) return;
  const links = $$('a[href^="#"]', nav);
  const byId = new Map(links.map((a) => [a.getAttribute('href').slice(1), a]));
  const mark = (a) => links.forEach((l) => (l === a ? l.setAttribute('aria-current', 'true') : l.removeAttribute('aria-current')));
  const io = new IntersectionObserver((es) => es.forEach((e) => {
    if (!e.isIntersecting) return;
    const id = e.target.dataset.nav || e.target.id;
    mark(byId.get(id) || null);
  }), { rootMargin: '-45% 0px -54% 0px' });
  $$('main > section').forEach((s) => io.observe(s));

  // 窄螢幕：導覽可以橫向捲；捲到底時拿掉右邊的淡出遮罩
  const edge = () => nav.classList.toggle('end-reached', nav.scrollLeft + nav.clientWidth >= nav.scrollWidth - 4);
  nav.addEventListener('scroll', edge, { passive: true });
  edge();
})();
