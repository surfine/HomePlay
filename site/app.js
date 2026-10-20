// 桌寵互動：沒有框架、沒有行內處理器（CSP 不允許）。
// 文案（表情名稱、外觀說明）從 #i18n 的 JSON 讀，這個區塊不是可執行腳本。
(() => {
  const I18N = JSON.parse(document.getElementById('i18n').textContent);
  const R = document.body.dataset.renders || '/media/renders/';
  let V = {}; try { V = JSON.parse(document.body.dataset.rendersV || '{}'); } catch {}
  const src = (file) => R + file + (V[file] ? '?v=' + V[file] : '');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const fmt = (tpl, k, v) => tpl.replace('{' + k + '}', v);
  const hasIO = 'IntersectionObserver' in window;
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const pad = n => String(n).padStart(2, '0');
  let HV = {}; try { HV = JSON.parse(document.body.dataset.helloV || '{}'); } catch {}
  const HELLO = document.body.dataset.hello || '/media/renders/hello/';
  const helloSrc = n => HELLO + pad(n) + '.webp' + (HV[pad(n) + '.webp'] ? '?v=' + HV[pad(n) + '.webp'] : '');
  // 只在元素進入視口時跑 rAF：回傳 {visible}，進入時 start、離開時 stop，不監聽 scroll。
  function whileVisible(el, start, stop, margin = '0px') {
    if (!hasIO) { start(); return; }
    new IntersectionObserver(es => es.forEach(e => (e.isIntersecting ? start() : stop())), { rootMargin: margin }).observe(el);
  }
  const loadImg = url => new Promise(res => { const i = new Image(); i.decoding = 'async'; i.onload = () => res(i); i.onerror = () => res(null); i.src = url; });

  // 一台桌寵 = 疊在一起的幾張圖，換表情只換 .on。
  // HTML 只放第一張；其餘在 fill() 才建立（首屏之後或捲近時），避免首屏就下載二十張。
  // 還沒載入完的圖不切換，載好才換，不會閃空白。
  function mountPet(el, onChange) {
    const names = el.dataset.names.split(' ');
    const size = [el.dataset.w, el.dataset.h];
    const imgs = {};
    $$('img', el).forEach(i => { imgs[i.dataset.name] = i; });
    let cur = el.dataset.first, want = cur, filled = false;
    const fx = { blink: null, glance: null };
    let visible = false, started = false;
    let blinkT = 0, blinkOffT = 0, glanceT = 0, glanceOffT = 0;

    // 眨眼／眼神是同一格畫面的另一張渲染，只有眼睛不同；疊上去做 brief 的替換。
    // 兩張圖出自同一個 homeplay-pet 行程，機身、玻璃反射、時鐘逐像素對齊。
    const fxPath = (kind, n) => `fx/${kind}-${el.dataset.prefix}${n}.webp`;
    const wantsGlance = n => el.dataset.glance === 'always' || (el.dataset.glance === 'auto' && (n === 'idle' || n === 'curious'));

    function makeFx(kind) {
      const i = new Image();
      i.alt = ''; i.decoding = 'async'; i.className = 'fx ' + kind;
      i.width = +size[0]; i.height = +size[1];
      i.addEventListener('load', () => { i.dataset.ready = '1'; });
      i.addEventListener('error', () => { i.dataset.ready = 'no'; });
      el.append(i); fx[kind] = i;
    }
    function loadFx(kind, n) {
      if (!el.dataset[kind] || !fx[kind]) return;
      const i = fx[kind], url = src(fxPath(kind, n));
      if (i.getAttribute('src') === url) return;
      i.classList.remove('on'); i.removeAttribute('data-ready'); i.removeAttribute('src');
      i.src = url;
    }
    function fxFor(n) {
      if (!started) return;
      if (!fx.glance) makeFx('glance');
      if (!fx.blink) makeFx('blink');
      if (n !== 'asleep' && n !== 'wink') loadFx('blink', n);
      if (wantsGlance(n)) loadFx('glance', n);
    }
    function scheduleBlink(ms) {
      clearTimeout(blinkT);
      if (!visible || reduce) return;
      blinkT = setTimeout(blink, ms ?? (2200 + Math.random() * 3200));
    }
    function blink() {
      if (!visible || reduce) return;
      const b = fx.blink;
      if (!b || b.dataset.ready !== '1' || cur === 'asleep' || cur === 'wink') { scheduleBlink(1800); return; }
      if (fx.glance) fx.glance.classList.remove('on');
      b.classList.add('on');
      clearTimeout(blinkOffT);
      blinkOffT = setTimeout(() => b.classList.remove('on'), 90);
      if (Math.random() < .12) {   // 偶爾連眨兩下
        setTimeout(() => {
          if (!visible || b.dataset.ready !== '1') return;
          b.classList.add('on');
          setTimeout(() => b.classList.remove('on'), 90);
        }, 190);
      }
      scheduleBlink(2800 + Math.random() * 3600);
    }
    function scheduleGlance(ms) {
      clearTimeout(glanceT);
      if (!visible || reduce) return;
      glanceT = setTimeout(glance, ms ?? (6000 + Math.random() * 5000));
    }
    function glance() {
      if (!visible || reduce) return;
      const g = fx.glance;
      if (!g || g.dataset.ready !== '1' || !wantsGlance(cur)) { scheduleGlance(2600); return; }
      g.classList.add('on');
      clearTimeout(glanceOffT);
      glanceOffT = setTimeout(() => g.classList.remove('on'), 1500);
      scheduleGlance(7600 + Math.random() * 5200);
    }
    function startFx() {
      if (started || reduce) return;
      started = true; fxFor(cur);
      scheduleBlink(1800 + Math.random() * 1600);
      scheduleGlance(4200 + Math.random() * 2800);
    }

    whileVisible(el, () => {
      visible = true; startFx();
      scheduleBlink(1200 + Math.random() * 1800);
      scheduleGlance(3500 + Math.random() * 3000);
    }, () => {
      visible = false;
      clearTimeout(blinkT); clearTimeout(blinkOffT); clearTimeout(glanceT); clearTimeout(glanceOffT);
      if (fx.blink) fx.blink.classList.remove('on');
      if (fx.glance) fx.glance.classList.remove('on');
    });

    function fill() {
      if (filled) return;
      filled = true;
      for (const n of names) {
        if (imgs[n]) continue;
        const i = new Image();
        i.alt = ''; i.decoding = 'async'; i.width = +size[0]; i.height = +size[1];
        i.dataset.name = n;
        i.src = src(el.dataset.prefix + n + '.webp');
        el.append(i); imgs[n] = i;
      }
      fxFor(cur);
    }
    function apply(n) {
      if (n === cur) return;
      imgs[cur].classList.remove('on'); imgs[n].classList.add('on'); cur = n;
      if (onChange) onChange(n);
      if (fx.blink) fx.blink.classList.remove('on');
      if (fx.glance) fx.glance.classList.remove('on');
      if (started) {
        fxFor(n);
        scheduleBlink(1400 + Math.random() * 1800);
        scheduleGlance(4200 + Math.random() * 3000);
      }
    }
    function set(n) {
      want = n;
      const i = imgs[n];
      if (!i || n === cur) return;
      if (i.complete && i.naturalWidth) apply(n);
      else i.addEventListener('load', () => { if (want === n) apply(n); }, { once: true });
    }
    return { set, fill, get cur() { return cur; } };
  }

  // 圖放進視口附近才補齊
  function fillNear(pet, el) {
    if (!('IntersectionObserver' in window)) { pet.fill(); return; }
    const o = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { pet.fill(); o.disconnect(); } }, { rootMargin: '600px 0px' });
    o.observe(el);
  }

  // ── Hero：照 App 的行為表，縮成四條 ──
  const heroEl = $('#hero-pet');
  const hero = mountPet(heroEl, n => heroEl.setAttribute('aria-label', fmt(I18N.heroLabel, 'face', I18N.faceNames[n])));
  const warm = () => hero.fill();
  addEventListener('load', () => (window.requestIdleCallback || setTimeout)(warm, { timeout: 1500 }), { once: true });
  addEventListener('pointermove', warm, { once: true, passive: true });
  addEventListener('pointerdown', warm, { once: true, passive: true });
  addEventListener('keydown', warm, { once: true });

  let over = false, overTimer = [], locked = 0, clicks = [];
  const clearOver = () => { overTimer.forEach(clearTimeout); overTimer = []; };
  addEventListener('pointermove', e => {
    if (Date.now() < locked || over) return;
    const r = heroEl.getBoundingClientRect();
    const dx = Math.max(r.left - e.clientX, 0, e.clientX - r.right), dy = Math.max(r.top - e.clientY, 0, e.clientY - r.bottom);
    hero.set(Math.hypot(dx, dy) < 160 ? 'curious' : 'idle');
  }, { passive: true });
  heroEl.addEventListener('pointerenter', () => {
    over = true; clearOver();
    overTimer.push(setTimeout(() => Date.now() > locked && hero.set('happy'), 1500));
    overTimer.push(setTimeout(() => Date.now() > locked && hero.set('love'), 4000));
  });
  heroEl.addEventListener('pointerleave', () => {
    over = false; clearOver();
    if (Date.now() > locked) hero.set('happy');
    setTimeout(() => !over && hero.set('curious'), 600);
  });
  heroEl.addEventListener('pointerdown', () => {
    heroEl.classList.add('press');
    const now = Date.now(); clicks = clicks.filter(t => now - t < 1500); clicks.push(now);
    if (clicks.length >= 5) { hero.set('focus'); locked = now + 1600; clicks = []; }
    else { hero.set('surprised'); locked = now + 400; setTimeout(() => hero.set(over ? 'happy' : 'curious'), 420); }
  });
  addEventListener('pointerup', () => heroEl.classList.remove('press'));
  addEventListener('pointercancel', () => heroEl.classList.remove('press'));

  // ── 表情段：一行一個觸發 ──
  const faceEl = $('#face-pet');
  const facePet = mountPet(faceEl, n => faceEl.setAttribute('aria-label', fmt(I18N.facesLabel, 'face', I18N.faceNames[n])));
  fillNear(facePet, faceEl);
  const rows = $$('#rows .row');
  const pick = row => {
    facePet.fill();
    rows.forEach(r => { const on = r === row; r.classList.toggle('on', on); r.setAttribute('aria-pressed', String(on)); });
    facePet.set(row.dataset.face);
  };
  rows.forEach(r => { r.addEventListener('pointerenter', () => pick(r)); r.addEventListener('focus', () => pick(r)); r.addEventListener('click', () => pick(r)); });

  // ── 外觀 ──
  const finEl = $('#finish-pet');
  const fin = mountPet(finEl);
  fillNear(fin, finEl);
  const sws = $$('.sw');
  sws.forEach(b => b.addEventListener('click', () => {
    const f = b.dataset.finish, [name, desc] = I18N.finishes[f];
    fin.fill(); fin.set(f);
    sws.forEach(s => s.setAttribute('aria-pressed', String(s === b)));
    $('#swname').textContent = name; $('#swdesc').textContent = desc;
    finEl.setAttribute('aria-label', fmt(I18N.finishLabel, 'finish', name));
  }));

  // ── 手機頂欄的區塊膠囊：畫面走到哪一段就亮哪一個（IntersectionObserver，不聽 scroll）──
  (() => {
    const chips = $$('header nav a'); if (chips.length < 2 || !hasIO) return;
    const nav = chips[0].closest('nav');
    const byId = new Map(chips.map(a => [a.getAttribute('href').slice(1), a]));
    const io = new IntersectionObserver(es => es.forEach(e => {
      if (!e.isIntersecting) return;
      const a = byId.get(e.target.id); if (!a) return;
      chips.forEach(c => c.removeAttribute('aria-current'));
      a.setAttribute('aria-current', 'true');
    }), { rootMargin: '-35% 0px -55% 0px' });
    byId.forEach((_, id) => { const s = document.getElementById(id); if (s) io.observe(s); });
    if (!nav) return;
    // 右緣漸隱只在還沒滑到底時開（聽的是膠囊列自己的 scroll，不是頁面的）
    const fade = () => nav.classList.toggle('fade', nav.scrollLeft + nav.clientWidth < nav.scrollWidth - 4);
    nav.addEventListener('scroll', fade, { passive: true });
    fade();
  })();

  // ── 進場 ──
  const rises = $$('.rise');
  if (reduce || !('IntersectionObserver' in window)) rises.forEach(el => el.classList.add('in'));
  else {
    const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { threshold: .15 });
    rises.forEach(el => io.observe(el));
  }

  // ── 為什麼是眼睛：品牌的那雙眼睛，跟著指標看、眨眼、閒置就闔上 ──
  (() => {
    const card = $('#eyes'); if (!card) return;
    const eyes = $$('.eye', card).map(g => ({ g, pupil: $('.pupil', g), cx: +g.dataset.cx, cy: +g.dataset.cy }));
    const MX = 14, MY = 30; // 瞳孔在眼睛裡能走的距離
    const draw = (ux, uy, open, k) => {
      for (const e of eyes) {
        const lid = open * k;
        e.pupil.setAttribute('transform', `translate(${(ux * MX).toFixed(2)} ${(uy * MY).toFixed(2)})`);
        // 闭眼时只留下眼睑线；瞳孔和眼睛一起压扁会变成一道黑缝。
        const shut = lid < .4;
        e.pupil.style.opacity = shut ? '0' : '1';
        e.pupil.style.visibility = shut ? 'hidden' : 'visible';
        e.g.setAttribute('transform', `translate(${e.cx} ${e.cy}) scale(${k.toFixed(3)} ${lid.toFixed(3)}) translate(${-e.cx} ${-e.cy})`);
      }
    };
    if (reduce || !hasIO) { draw(.55, -.45, 1, 1); return; }
    let px = 0, py = 0, moved = false, lastMove = 0, sleeping = false;
    let ux = 0, uy = 0, open = 1, startle = 0, blinkT = -1, nextBlink = 0, raf = 0, prev = 0;
    const wake = () => {
      moved = true; lastMove = performance.now();
      if (sleeping || open < .8) startle = 1;
      sleeping = false;
    };
    const onPtr = e => { px = e.clientX; py = e.clientY; wake(); };
    addEventListener('pointermove', onPtr, { passive: true });
    addEventListener('pointerdown', onPtr, { passive: true });
    const tick = now => {
      raf = requestAnimationFrame(tick);
      const dt = Math.min(.05, (now - prev) / 1000 || .016); prev = now;
      const r = card.getBoundingClientRect();
      let tx, ty;
      if (moved) {
        const dx = px - (r.left + r.width / 2), dy = py - (r.top + r.height * .47);
        const l = Math.hypot(dx, dy) || 1, f = Math.min(1, l / 260) / l;
        tx = dx * f; ty = dy * f;
      } else { // 沒有指標：慢慢東張西望
        const t = now / 1000; tx = Math.sin(t * .55) * .75; ty = Math.sin(t * .37 + 1) * .4;
      }
      sleeping = moved && now - lastMove > 4000;
      const kLook = 1 - Math.exp(-dt * 10);
      ux += (tx - ux) * kLook; uy += (ty - uy) * kLook;
      open += ((sleeping ? .08 : 1) - open) * (1 - Math.exp(-dt * (sleeping ? 7 : 30)));
      if (!sleeping && blinkT < 0 && now >= nextBlink) blinkT = 0;
      let blink = 1;
      if (blinkT >= 0) {
        blinkT += dt * 1000;
        if (blinkT >= 140) { blinkT = -1; nextBlink = now + 3000 + Math.random() * 3000; }
        else blink = 1 - .92 * Math.sin(Math.PI * blinkT / 140);
      } else if (!nextBlink || nextBlink < now - 8000) nextBlink = now + 3000 + Math.random() * 3000;
      startle *= Math.exp(-dt * 7);
      draw(ux, uy, open * blink, 1 + .08 * startle);
    };
    const start = () => { if (raf) return; prev = performance.now(); nextBlink = prev + 3000 + Math.random() * 3000; raf = requestAnimationFrame(tick); };
    const stop = () => { cancelAnimationFrame(raf); raf = 0; };
    whileVisible(card, start, stop);
    addEventListener('pagehide', stop);
  })();

  // 時間線三拍：進場時一個接一個浮上來（CSS 用 nth-child 排延遲）
  (() => {
    const ol = $('#beats'); if (!ol) return;
    if (reduce || !hasIO) { ol.classList.add('in'); return; }
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { ol.classList.add('in'); io.disconnect(); } }, { threshold: .2 });
    io.observe(ol);
  })();

  // ── CarPlay：資料點只在看得到這一段時才動 ──
  (() => {
    const sec = $('#carplay'); if (!sec) return;
    if (reduce) return;
    whileVisible(sec, () => sec.classList.add('live'), () => sec.classList.remove('live'));
  })();

  // ── Hero：不在畫面上就停下輕輕的浮動 ──
  (() => {
    const sec = $('.hero'); if (!sec || reduce) return;
    whileVisible(sec, () => sec.classList.remove('off'), () => sec.classList.add('off'));
  })();

  // ── 轉一圈：36 格預載後畫在 canvas 上，拖曳、慣性、捲動、鍵盤 ──
  (() => {
    const stage = $('#spin-stage'); if (!stage) return;
    const N = +stage.dataset.frames || 36;
    const sec = $('#spin');
    const canvas = $('.spin-canvas', stage), ctx = canvas.getContext && canvas.getContext('2d');
    const still = $('.spin-still', stage);
    const btn = $('#apart-btn'), hint = $('#spin-hint');
    const frames = new Array(N);
    let pos = 0, shown = -1, vel = 0, dragging = false, touched = false, apart = false, ready = false, raf = 0, prev = 0, lx = 0, lt = 0, loading = false;

    function size() {
      const dpr = Math.min(2, devicePixelRatio || 1), w = stage.clientWidth, h = stage.clientHeight;
      const cw = Math.round(w * dpr), ch = Math.round(h * dpr);
      if (canvas.width !== cw || canvas.height !== ch) { canvas.width = cw; canvas.height = ch; shown = -1; }
    }
    function paint() {
      if (!ready || !ctx) return;
      const f = ((Math.round(pos) % N) + N) % N;
      if (f === shown || !frames[f]) return;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(frames[f], 0, 0, canvas.width, canvas.height);
      shown = f;
    }
    function preload() {
      if (loading || !ctx) return; loading = true;
      for (let i = 0; i < N; i++) loadImg(src('spin/' + pad(i) + '.webp')).then(img => {
        frames[i] = img;
        if (i === 0 && img && !ready) { ready = true; size(); paint(); stage.classList.add('live'); }
        else if (ready) paint();
      });
    }
    if (hasIO) {
      const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { preload(); io.disconnect(); } }, { rootMargin: '800px 0px' });
      io.observe(stage);
    } else preload();
    if ('ResizeObserver' in window) new ResizeObserver(() => { size(); paint(); }).observe(stage);

    const tick = now => {
      raf = requestAnimationFrame(tick);
      const dt = Math.min(.05, (now - prev) / 1000 || .016); prev = now;
      if (!dragging) {
        if (vel) { pos += vel * dt; vel *= Math.exp(-dt * 3.2); if (Math.abs(vel) < .25) vel = 0; }
        else if (!touched && !reduce) {
          const r = sec.getBoundingClientRect(), vh = innerHeight;
          const p = clamp((vh - r.top) / (vh + r.height), 0, 1);
          pos += (p * N - pos) * (1 - Math.exp(-dt * 8));
        }
      }
      paint();
    };
    whileVisible(sec, () => { if (!raf) { prev = performance.now(); raf = requestAnimationFrame(tick); } }, () => { cancelAnimationFrame(raf); raf = 0; });

    const used = () => { touched = true; hint && hint.classList.add('gone'); };
    stage.addEventListener('pointerdown', e => {
      if (apart || (e.pointerType === 'mouse' && e.button)) return;
      dragging = true; vel = 0; lx = e.clientX; lt = e.timeStamp;
      try { stage.setPointerCapture(e.pointerId); } catch {}
      stage.classList.add('grab');
    });
    stage.addEventListener('pointermove', e => {
      if (!dragging) return;
      const dx = e.clientX - lx, dt = Math.max(1, e.timeStamp - lt) / 1000;
      if (!dx) return;
      if (Math.abs(dx) > 1) used();
      pos -= dx / 8;
      vel = vel * .6 + (-dx / 8 / dt) * .4;
      lx = e.clientX; lt = e.timeStamp;
      paint();
    });
    const end = e => {
      if (!dragging) return;
      dragging = false; stage.classList.remove('grab');
      if (reduce || e.timeStamp - lt > 90) vel = 0;
      vel = clamp(vel, -40, 40);
    };
    stage.addEventListener('pointerup', end);
    stage.addEventListener('pointercancel', end);
    stage.addEventListener('keydown', e => {
      if (apart || (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight')) return;
      e.preventDefault(); used(); vel = 0;
      pos = Math.round(pos) + (e.key === 'ArrowRight' ? 1 : -1);
      paint();
    });
    btn.addEventListener('click', () => {
      apart = !apart; vel = 0; dragging = false;
      stage.classList.toggle('apart', apart);
      btn.setAttribute('aria-pressed', String(apart));
      btn.textContent = apart ? I18N.together : I18N.apart;
      stage.setAttribute('aria-label', apart ? I18N.apartAlt : I18N.spinLabel);
    });
  })();

  // ── 開機 hello：進場時逐格寫一次，之後可以再看一次 ──
  (() => {
    const cell = $('#hello-cell'); if (!cell || reduce) return;
    const canvas = $('.hello-canvas', cell), img = $('.shot img', cell), btn = $('#replay');
    const N = +cell.dataset.frames || 16, ctx = canvas.getContext && canvas.getContext('2d');
    if (!ctx) return;
    let frames = null, loading = null, playing = false, played = false, timer = 0;
    const load = () => loading || (loading = Promise.all(Array.from({ length: N }, (_, i) => loadImg(helloSrc(i)))).then(f => (frames = f)));
    const paint = i => {
      const f = frames[i]; if (!f) return;
      const box = canvas.getBoundingClientRect(), dpr = Math.min(2, devicePixelRatio || 1);
      const cw = Math.round(box.width * dpr), ch = Math.round(box.height * dpr);
      if (canvas.width !== cw || canvas.height !== ch) { canvas.width = cw; canvas.height = ch; }
      ctx.clearRect(0, 0, cw, ch);
      const s = Math.min(cw / f.naturalWidth, ch / f.naturalHeight);
      const w = f.naturalWidth * s, h = f.naturalHeight * s;
      ctx.drawImage(f, (cw - w) / 2, ch - h, w, h);
    };
    async function play() {
      if (playing) return; playing = true; btn.disabled = true;
      await load();
      if (!frames.every(Boolean)) { playing = false; btn.disabled = false; return; }
      canvas.hidden = false; cell.classList.add('playing');
      let i = 0; paint(0);
      const step = () => {
        i++; paint(i);
        if (i < N - 1) timer = setTimeout(step, 150);
        else { playing = false; played = true; btn.hidden = false; btn.disabled = false; }
      };
      timer = setTimeout(step, 150);
    }
    btn.addEventListener('click', play);
    if (!hasIO) return;
    new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) load(); }, { rootMargin: '600px 0px' }).observe(cell);
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting) && !played) { io.disconnect(); play(); } }, { threshold: .6 });
    io.observe(cell);
    addEventListener('pagehide', () => clearTimeout(timer));
  })();

  // ── 夜晚那格：同一張渲染上疊眨眼，安靜地活著 ──
  (() => {
    const cell = $('#ambient-cell'); if (!cell || reduce || !hasIO) return;
    const shot = $('.shot', cell); if (!shot) return;
    const fx = new Image();
    fx.alt = ''; fx.decoding = 'async'; fx.className = 'fx blink moment-fx';
    fx.addEventListener('load', () => { fx.dataset.ready = '1'; });
    fx.addEventListener('error', () => { fx.dataset.ready = 'no'; });
    fx.src = src('fx/blink-ambient-night.webp');
    shot.append(fx);
    let visible = false, t = 0;
    const schedule = () => { clearTimeout(t); if (visible) t = setTimeout(blink, 3000 + Math.random() * 4200); };
    const blink = () => {
      if (!visible) return;
      if (fx.dataset.ready !== '1') { schedule(); return; }
      fx.classList.add('on');
      setTimeout(() => fx.classList.remove('on'), 90);
      schedule();
    };
    whileVisible(cell, () => { visible = true; schedule(); }, () => { visible = false; clearTimeout(t); fx.classList.remove('on'); });
  })();

  // ── 複製指令 ──
  // ── 天光：整個頁面只有這一個持續動畫。滾動進度只寫一個 CSS 變數 --day。──
  (() => {
    const sky = document.querySelector('.sky');
    const rail = document.querySelector('.day-rail');
    const root = document.documentElement;
    if (reduce) { if (sky) sky.style.setProperty('--day', '0.32'); return; }
    const setRail = () => { if (rail) rail.style.setProperty('--rail-travel', rail.clientHeight + 'px'); };
    let queued = false;
    const update = () => {
      queued = false;
      const max = root.scrollHeight - innerHeight;
      const p = max > 0 ? Math.min(1, Math.max(0, scrollY / max)) : 0;
      // 只寫兩個會用到的元素，避免在 root 上改變數造成整頁樣式重算
      if (sky) sky.style.setProperty('--day', p.toFixed(4));
      if (rail) rail.style.setProperty('--day', p.toFixed(4));
    };
    const queue = () => { if (queued) return; queued = true; requestAnimationFrame(update); };
    addEventListener('scroll', queue, { passive: true });
    addEventListener('resize', () => { setRail(); queue(); }, { passive: true });
    addEventListener('load', () => { setRail(); queue(); });
    setRail();
    update();
  })();

  (() => {
    const btn = $('#copy'); if (!btn || !navigator.clipboard || !navigator.clipboard.writeText) return;
    btn.hidden = false;
    let t = 0;
    btn.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText($('pre', btn.parentElement).textContent); } catch { return; }
      btn.textContent = I18N.copied; btn.classList.add('done');
      clearTimeout(t);
      t = setTimeout(() => { btn.textContent = I18N.copyCode; btn.classList.remove('done'); }, 1500);
    });
  })();
})();
