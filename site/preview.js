// HomePlay 2.0 Preview 頁的互動。沒有框架、沒有行內處理器（CSP 不允許）；不監聽頁面 scroll，
// 位置相關的事一律交給 IntersectionObserver。減少動態效果時：不自動播放、不自動換步驟、換圖直接切。
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const hasIO = 'IntersectionObserver' in window;
  const seen = (el, cb, opts) => { if (!hasIO) { cb(true); return; } new IntersectionObserver((es) => es.forEach((e) => cb(e.isIntersecting, e)), opts).observe(el); };

  // ── 亮片：量按鈕的位置，把 --x／--w 寫給同一層的指示片（分段按鈕與膠囊導覽共用）──
  function place(thumb, btn) {
    if (!thumb || !btn) return;
    thumb.style.setProperty('--x', btn.offsetLeft + 'px');
    thumb.style.setProperty('--w', btn.offsetWidth + 'px');
    thumb.style.setProperty('--o', '1');
  }

  // ── 換圖：同一格裡的幾張，只換 .on ──
  function swap(box, k) {
    $$(':scope > [data-k]', box).forEach((el) => el.classList.toggle('on', el.dataset.k === k));
  }

  // ── 分段按鈕：首屏的錶面／主畫面、主畫面外觀、島錶面年代 ──
  const segHandlers = {
    hero: (k) => { $('#pv-stage').dataset.state = k; },
    looks: (k) => swap($('[data-swap="looks"] .pv-swap'), k),
    era: (k) => swap($('[data-swap="era"] .pv-swap'), k),
  };
  const segs = {};
  $$('.pv-seg').forEach((seg) => {
    const key = seg.dataset.seg, thumb = $('.pv-seg-thumb', seg), btns = $$('button', seg);
    const pick = (b, fromUser) => {
      btns.forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
      place(thumb, b);
      segHandlers[key]?.(b.dataset.k, fromUser);
    };
    btns.forEach((b, i) => {
      b.addEventListener('click', () => pick(b, true));
      // 左右鍵在同一組裡移動（Tab 仍然一格一格走）
      b.addEventListener('keydown', (e) => {
        const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0; if (!d) return;
        e.preventDefault(); const n = btns[(i + d + btns.length) % btns.length]; n.focus(); pick(n, true);
      });
    });
    segs[key] = { pick, btns, reflow: () => place(thumb, btns.find((x) => x.getAttribute('aria-pressed') === 'true')) };
    segs[key].reflow();
  });
  // 字型載完、視窗變寬窄，按鈕寬度會變：重新量一次
  const reflowAll = () => { Object.values(segs).forEach((s) => s.reflow()); navReflow(); };
  addEventListener('resize', () => requestAnimationFrame(reflowAll), { passive: true });
  document.fonts?.ready.then(reflowAll);

  // ── 首屏：捲過一半，機身螢幕從錶面換成主畫面；捲回來換回去 ──
  const flip = $('.pv-hero-flip');
  // 窄螢幕沒有捲動場景（指標是 display:none），那裡只靠按鈕切換
  if (flip && segs.hero && hasIO && flip.offsetParent) {
    new IntersectionObserver((es) => es.forEach((e) => {
      // 指標（首屏軌道的後半段）碰到視窗上半部，或已經整段捲過去 → 主畫面
      const past = e.isIntersecting || e.boundingClientRect.bottom <= 0;
      const want = past ? 'home' : 'face';
      const b = segs.hero.btns.find((x) => x.dataset.k === want);
      if (b && b.getAttribute('aria-pressed') !== 'true') segs.hero.pick(b, false);
    }), { rootMargin: '0px 0px -50% 0px' }).observe(flip);
  }

  // ── 膠囊導覽：讀到哪一段就亮哪一個；眼睛朝新的那一格瞄一下 ──
  const nav = $('.pv-nav');
  const navThumb = $('.pv-nav-thumb'), eyes = $('.pv-nav-eyes');
  const links = $$('.pv-nav a');
  let curLink = null;
  function navReflow() { if (curLink) place(navThumb, curLink); }
  function setCurrent(a) {
    if (!a || a === curLink) return;
    const prev = curLink ? links.indexOf(curLink) : -1, next = links.indexOf(a);
    links.forEach((l) => l.toggleAttribute('aria-current', l === a));
    a.setAttribute('aria-current', 'true');
    curLink = a; place(navThumb, a);
    if (!reduce && eyes && prev >= 0) {
      eyes.style.setProperty('--glance', `${next > prev ? 4 : -4}px`);
      clearTimeout(setCurrent.t); setCurrent.t = setTimeout(() => { eyes.style.setProperty('--glance', '0px'); }, 650);
    }
    // 窄螢幕上膠囊會橫捲：把亮的那一格捲進來（只捲膠囊本身）
    if (nav.scrollWidth > nav.clientWidth) nav.scrollTo({ left: a.offsetLeft - nav.clientWidth / 2 + a.offsetWidth / 2, behavior: reduce ? 'auto' : 'smooth' });
  }
  if (nav && hasIO) {
    const byId = new Map(links.map((a) => [a.getAttribute('href').slice(1), a]));
    const io = new IntersectionObserver((es) => es.forEach((e) => {
      if (!e.isIntersecting) return;
      const id = e.target.dataset.nav || e.target.id;
      setCurrent(byId.get(id));
    }), { rootMargin: '-40% 0px -55% 0px' });
    $$('main section[id]').forEach((s) => { if (byId.has(s.dataset.nav || s.id)) io.observe(s); });
    const hero = $('.pv-hero');
    if (hero) new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { links.forEach((l) => l.removeAttribute('aria-current')); curLink = null; navThumb.style.setProperty('--o', '0'); } }), { rootMargin: '-40% 0px -55% 0px' }).observe(hero);
    const edge = () => nav.classList.toggle('end-reached', nav.scrollLeft + nav.clientWidth >= nav.scrollWidth - 4);
    nav.addEventListener('scroll', edge, { passive: true }); edge();
  }

  // ── 👀 跟著指標看：膠囊裡的眼睛朝游標的方向偏一點點（1.0 的核心：它會看著你）；觸控與減少動態效果時不動 ──
  if (eyes && !reduce && matchMedia('(hover: hover) and (pointer: fine)').matches) {
    let tx = 0, ty = 0, raf = 0;
    const apply = () => { raf = 0; eyes.style.setProperty('--ex', tx.toFixed(2) + 'px'); eyes.style.setProperty('--ey', ty.toFixed(2) + 'px'); };
    addEventListener('pointermove', (e) => {
      const r = eyes.getBoundingClientRect();
      const dx = e.clientX - (r.left + r.width / 2), dy = e.clientY - (r.top + r.height / 2);
      const d = Math.hypot(dx, dy) || 1, k = Math.min(1, d / 240);
      tx = (dx / d) * 3 * k; ty = (dy / d) * 1.6 * k;
      if (!raf) raf = requestAnimationFrame(apply);
    }, { passive: true });
  }
  // ── 「玻璃交給系統畫」那一格：玻璃膠囊跟著指標在彩色底上滑，看得到底下的顏色被折過來 ──
  const glass = $('.pv-glass-demo');
  if (glass && !reduce) {
    const pillEl = $('.pv-glass-pill', glass);
    glass.addEventListener('pointermove', (e) => {
      const r = glass.getBoundingClientRect();
      pillEl.style.setProperty('--gx', ((e.clientX - r.left) / r.width - 0.5) * (r.width - 140) + 'px');
      pillEl.style.setProperty('--gy', ((e.clientY - r.top) / r.height - 0.5) * (r.height - 64) + 'px');
    });
    glass.addEventListener('pointerleave', () => { pillEl.style.setProperty('--gx', '0px'); pillEl.style.setProperty('--gy', '0px'); });
  }

  // ── 亮點大卡：自動播放（進度條走完換下一張），手動捲、點、按鍵就停；有暫停鍵（WCAG 2.2.2）──
  const gal = $('[data-gal]');
  if (gal) {
    const track = $('.pv-gal-track', gal), tiles = $$('.pv-tile', gal), dots = $$('.pv-dots button', gal);
    const play = $('[data-play]', gal), prevB = $('[data-step="-1"]', gal), nextB = $('[data-step="1"]', gal);
    let cur = 0, wantAuto = !reduce, visible = false, programmatic = 0;
    const setPlayUi = () => {
      play.classList.toggle('paused', !wantAuto);
      play.setAttribute('aria-label', wantAuto ? play.dataset.pauseLabel : play.dataset.playLabel);
    };
    const running = () => wantAuto && visible && !document.hidden;
    const sync = () => { gal.classList.toggle('auto', wantAuto); gal.classList.toggle('held', !running()); };
    function mark(i) {
      cur = i;
      tiles.forEach((t, j) => { t.classList.toggle('is-cur', j === i); t.inert = false; });
      dots.forEach((d, j) => { if (j === i) d.setAttribute('aria-current', 'true'); else d.removeAttribute('aria-current'); });
      // 重新開始這一顆的進度動畫
      const bar = dots[i]?.querySelector('i'); if (bar) { bar.style.animation = 'none'; void bar.offsetWidth; bar.style.animation = ''; }
      prevB.disabled = i === 0; nextB.disabled = i === tiles.length - 1;
    }
    function go(i, smooth = true) {
      i = (i + tiles.length) % tiles.length;
      programmatic = Date.now();
      track.scrollTo({ left: tiles[i].offsetLeft - track.offsetLeft - (tiles[0].offsetLeft - track.offsetLeft), behavior: smooth && !reduce ? 'smooth' : 'auto' });
      mark(i);
    }
    const stopAuto = () => { if (wantAuto) { wantAuto = false; setPlayUi(); sync(); } };
    dots.forEach((d, i) => {
      d.addEventListener('click', () => { stopAuto(); go(i); });
      d.querySelector('i').addEventListener('animationend', () => { if (running() && d.getAttribute('aria-current')) go(cur + 1); });
    });
    prevB.addEventListener('click', () => { stopAuto(); go(cur - 1); });
    nextB.addEventListener('click', () => { stopAuto(); go(cur + 1); });
    play.addEventListener('click', () => { wantAuto = !wantAuto; setPlayUi(); sync(); if (wantAuto) mark(cur); });
    // 使用者自己滑：停自動播放，跟著目前置中的那張
    ['pointerdown', 'wheel', 'touchstart'].forEach((ev) => track.addEventListener(ev, () => stopAuto(), { passive: true }));
    if (hasIO) {
      const tio = new IntersectionObserver((es) => es.forEach((e) => {
        if (e.isIntersecting && e.intersectionRatio > 0.6 && Date.now() - programmatic > 700) mark(tiles.indexOf(e.target));
      }), { root: track, threshold: [0.6] });
      tiles.forEach((t) => tio.observe(t));
    }
    // 鍵盤焦點進到卡片裡（或滑鼠停在上面）時先暫停計時，離開再繼續
    gal.addEventListener('focusin', () => gal.classList.add('held'));
    gal.addEventListener('focusout', sync);
    gal.addEventListener('pointerenter', () => gal.classList.add('held'));
    gal.addEventListener('pointerleave', sync);
    seen(gal, (v) => { visible = v; sync(); }, { threshold: 0.35 });
    document.addEventListener('visibilitychange', sync);
    setPlayUi(); mark(0); sync();
  }

  // ── Live Activity：收起／展開 ──
  $$('[data-toggle="la"]').forEach((b) => b.addEventListener('click', () => {
    const on = b.getAttribute('aria-pressed') !== 'true';
    b.setAttribute('aria-pressed', String(on));
    b.textContent = on ? b.dataset.on : b.dataset.off;
    swap($('[data-swap="la"] .pv-swap'), on ? 'expanded' : 'compact');
  }));

  // ── ClioTalk 三步驟：看得到時自己走一輪（進度條走完換下一步），點了就交給使用者 ──
  const steps = $('[data-steps]');
  if (steps) {
    const btns = $$('.pv-steps-list button', steps), media = $('.pv-steps-media', steps);
    let auto = !reduce, i = 0;
    const pick = (n) => {
      i = n;
      btns.forEach((b, j) => b.setAttribute('aria-pressed', String(j === n)));
      swap(media, btns[n].dataset.k);
      const bar = btns[n].querySelector('.pv-step-bar'); bar.style.animation = 'none'; void bar.offsetWidth; bar.style.animation = '';
    };
    btns.forEach((b, n) => {
      b.addEventListener('click', () => { auto = false; steps.classList.remove('auto'); pick(n); });
      b.querySelector('.pv-step-bar').addEventListener('animationend', () => { if (auto) pick((i + 1) % btns.length); });
    });
    seen(steps, (v) => steps.classList.toggle('auto', auto && v), { threshold: 0.4 });
  }

  // ── 天氣影片：看得到才播，有暫停鍵；減少動態效果時停在第一格 ──
  $$('video[data-loop]').forEach((v) => {
    const btn = v.parentElement.querySelector('[data-vid]');
    let want = !reduce;
    const ui = () => { btn.classList.toggle('paused', !want); btn.setAttribute('aria-label', want ? btn.dataset.pauseLabel : btn.dataset.playLabel); };
    let vis = false;
    const apply = () => { if (want && vis && !document.hidden) { if (v.preload === 'none') v.preload = 'auto'; v.play().catch(() => {}); } else v.pause(); };
    btn.addEventListener('click', () => { want = !want; ui(); apply(); });
    seen(v, (on) => { vis = on; apply(); }, { threshold: 0.25 });
    document.addEventListener('visibilitychange', apply);
    ui();
  });

  // ── 進場：同一個容器裡的 .rv 依序晚一點 ──
  const rvs = $$('.rv');
  if (reduce || !hasIO) rvs.forEach((el) => el.classList.add('in'));
  else {
    const groups = new Map();
    rvs.forEach((el) => { const p = el.parentElement; const n = groups.get(p) || 0; el.style.setProperty('--i', String(Math.min(n, 6))); groups.set(p, n + 1); });
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { threshold: 0.12, rootMargin: '0px 0px -6% 0px' });
    rvs.forEach((el) => io.observe(el));
  }
})();
