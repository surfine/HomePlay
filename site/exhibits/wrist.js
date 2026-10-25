// 03 · 2015 錶面上的一小格：自己設計的方形錶面，四個角落放複雜功能，抬手只亮 2 秒，再考你記得什麼。
// 全部自己畫（錶面、環、月相都是 SVG／CSS），資料是虛構的，沒有原廠錶面、圖示或字型。
HX.register('wrist', (api) => {
  const { el, s, fmt } = api;
  const COMPS = ['date', 'weather', 'activity', 'event', 'timer', 'moon'];
  const SLOTS = ['tl', 'tr', 'bl', 'br'];
  const GLANCE = 2000;
  const put = {};          // 格子 → 複雜功能
  let sel = null, busy = false, tries = 0, hits = 0, timer = 0;

  // 圖形：活動環與月相（月相是右側亮起的娥眉月）
  const ring = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="#3a3f4b" stroke-width="3"/><circle cx="12" cy="12" r="9" fill="none" stroke="#ff5c7a" stroke-width="3" stroke-linecap="round" stroke-dasharray="35 57" transform="rotate(-90 12 12)"/></svg>';
  const moon = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="#2b2f3a"/><path d="M12 3a9 9 0 0 1 0 18a6.5 9 0 0 0 0-18z" fill="#f2e6b8"/></svg>';
  const GFX = { activity: ring, moon, weather: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="5" fill="#f5b342"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2" stroke="#f5b342" stroke-width="2" stroke-linecap="round"/></svg>', timer: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="13" r="8" fill="none" stroke="#6ec6ff" stroke-width="2.5"/><path d="M12 13V8M9 3h6" stroke="#6ec6ff" stroke-width="2.5" stroke-linecap="round"/></svg>' };
  GFX.event = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="16" height="15" rx="3" fill="none" stroke="#ff8a5c" stroke-width="2.5"/><path d="M4 10h16M9 3v4M15 3v4" stroke="#ff8a5c" stroke-width="2.5" stroke-linecap="round"/></svg>';
  const cell = (c) => el('span', { class: `ww-c ww-c-${c}`, 'aria-hidden': 'true' }, [
    GFX[c] ? el('span', { class: 'ww-g', html: GFX[c] }) : null,
    el('span', { class: 'ww-v', text: s['v_' + c] }), el('span', { class: 'ww-l', text: s['n_' + c] })]);

  // ── 錶面 ──
  const slotBtns = Object.fromEntries(SLOTS.map((k) => [k, el('button', { class: `ww-slot ww-${k}`, type: 'button', 'aria-pressed': 'false', onclick: () => pickSlot(k) })]));
  const time = el('div', { class: 'ww-time', text: s.clock });
  const face = el('div', { class: 'ww-face', role: 'group', 'aria-label': s.faceLabel }, [...SLOTS.map((k) => slotBtns[k]), time]);
  const watch = el('div', { class: 'ww-watch' }, [face]);

  // ── 調色盤 ──
  const palBtns = Object.fromEntries(COMPS.map((c) => [c, el('button', { class: 'ww-pal', type: 'button', onclick: () => assign(c) }, [
    GFX[c] ? el('span', { class: 'ww-pg', 'aria-hidden': 'true', html: GFX[c] }) : el('span', { class: 'ww-pg ww-pd', 'aria-hidden': 'true', text: s.v_date.replace(/\D/g, '') }),
    el('span', { text: s['n_' + c] })])]));
  const clear = el('button', { class: 'ww-btn ww-ghost', type: 'button', text: s.clear, onclick: () => { SLOTS.forEach((k) => delete put[k]); sel = null; draw(); api.say(s.cleared); } });
  const raise = el('button', { class: 'ww-btn', type: 'button', text: s.raise, onclick: glance });
  const hint = el('p', { class: 'ww-hint', text: s.pickHint });
  const q = el('div', { class: 'ww-q', role: 'group', 'aria-label': s.qLabel, hidden: true });
  const tally = el('p', { class: 'ww-fact' });
  const side = el('div', { class: 'ww-side' }, [
    el('div', { class: 'ww-cap', text: s.palCap }), el('div', { class: 'ww-pals' }, COMPS.map((c) => palBtns[c])), hint,
    el('div', { class: 'ww-row' }, [raise, clear]), q, tally,
    el('p', { class: 'ww-fact', text: s.fact }),
  ]);
  api.stage.append(el('div', { class: 'ww' }, [watch, side]));

  function draw() {
    const placed = Object.values(put);
    SLOTS.forEach((k) => {
      const b = slotBtns[k]; b.replaceChildren(put[k] ? cell(put[k]) : el('span', { class: 'ww-plus', 'aria-hidden': 'true', text: '+' }));
      b.classList.toggle('on', sel === k); b.classList.toggle('empty', !put[k]);
      b.setAttribute('aria-pressed', String(sel === k));
      b.setAttribute('aria-label', put[k] ? fmt(s.slotFull, { slot: s['slot_' + k], name: s['n_' + put[k]], v: s['v_' + put[k]] }) : fmt(s.slotEmpty, { slot: s['slot_' + k] }));
    });
    COMPS.forEach((c) => {
      const at = SLOTS.find((k) => put[k] === c);
      palBtns[c].classList.toggle('used', !!at);
      palBtns[c].setAttribute('aria-label', at ? fmt(s.palUsed, { name: s['n_' + c], slot: s['slot_' + at] }) : s['n_' + c]);
    });
    hint.textContent = sel ? fmt(s.pickPal, { slot: s['slot_' + sel] }) : s.pickHint;
    tally.textContent = tries ? fmt(s.tally, { hits, tries }) : '';
  }
  function pickSlot(k) { sel = sel === k ? null : k; draw(); if (sel) api.say(fmt(s.pickPal, { slot: s['slot_' + k] })); }
  function assign(c) {
    if (!sel) { api.say(s.needSlot); return; }
    const from = SLOTS.find((k) => put[k] === c); if (from) delete put[from];
    put[sel] = c; const k = sel; sel = null; draw();
    api.say(fmt(s.assigned, { name: s['n_' + c], slot: s['slot_' + k], n: Object.keys(put).length }));
    slotBtns[k].focus({ preventScroll: true });
  }

  // 抬手：亮 2 秒（減少動態效果時不淡出，仍然 2 秒），再暗下來問一題
  function glance() {
    const placed = SLOTS.filter((k) => put[k]);
    if (!placed.length) { api.say(s.needOne); return; }
    busy = true; sel = null; draw(); q.hidden = true;
    watch.classList.add('lit'); watch.classList.remove('dim');
    [raise, clear, ...Object.values(slotBtns), ...Object.values(palBtns)].forEach((b) => { b.disabled = true; });
    api.say(s.lifted);
    timer = setTimeout(() => { watch.classList.remove('lit'); watch.classList.add('dim'); ask(placed.map((k) => put[k])); }, GLANCE);
  }
  function ask(placed) {
    const c = placed[Math.floor(Math.random() * placed.length)];
    const [right, ...wrong] = s['o_' + c].split('|');
    const opts = [right, ...wrong].sort(() => Math.random() - 0.5);
    q.replaceChildren(el('p', { class: 'ww-qp', text: s['q_' + c] }), el('div', { class: 'ww-opts' }, opts.map((o) => el('button', { class: 'ww-opt', type: 'button', text: o, onclick: () => answer(o === right, right, placed.length) }))));
    q.hidden = false; busy = false;
    api.say(s['q_' + c]);
    if (api.root.contains(document.activeElement) || document.activeElement === document.body) q.querySelector('button').focus({ preventScroll: true });
  }
  function answer(ok, right, n) {
    tries += 1; if (ok) hits += 1;
    q.hidden = true; watch.classList.remove('dim');
    [raise, clear, ...Object.values(slotBtns), ...Object.values(palBtns)].forEach((b) => { b.disabled = false; });
    draw();
    api.say((ok ? s.right : fmt(s.wrong, { a: right })) + ' ' + fmt(s.after, { n }));
    raise.focus({ preventScroll: true });
  }
  api.onReset(() => {
    clearTimeout(timer); SLOTS.forEach((k) => delete put[k]); put.tl = 'date'; sel = null; tries = hits = 0; q.hidden = true;
    watch.classList.remove('lit', 'dim');
    [raise, clear, ...Object.values(slotBtns), ...Object.values(palBtns)].forEach((b) => { b.disabled = false; });
    draw();
  });
  // 預設放一個日期，讓錶面不是空的
  put.tl = 'date'; draw();
});
