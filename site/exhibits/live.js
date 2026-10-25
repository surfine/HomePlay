// 04 · 2022 → 2023 即時動態與待機模式：一個通用手機輪廓，計時器從小藥丸長成卡片，結束就退場；橫放充電變成待機畫面。
// 全部自己畫：藥丸只是一顆黑色圓角條，沒有原廠外框、圖示或字型。「動態島」「待機模式」只出現在文字裡。
HX.register('live', (api) => {
  const { el, s, fmt } = api;
  const DUR = 60000, DONE = 2500;
  let rem = DUR, state = 'idle', running = true, fast = false, side = false, doneMs = 0, timer = 0;
  const mmss = (ms) => { const t = Math.max(0, Math.ceil(ms / 1000)); return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, '0')}`; };
  const glyph = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="13" r="7.5" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M12 13V9M9.5 3.5h5" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/></svg>';
  const ico = () => el('span', { class: 'lv-ico', 'aria-hidden': 'true', html: glyph });

  // ── 藥丸（上方那一顆）：idle 只是小黑條；compact 圖示加倒數；expanded 是卡片 ──
  const cTime = el('span', { class: 'lv-ctime' });
  const cBtn = el('button', { class: 'lv-cbtn', type: 'button', 'aria-expanded': 'false', onclick: () => setExpanded(true) }, [ico(), cTime]);
  const eTime = el('div', { class: 'lv-etime' });
  const eBar = el('div', { class: 'lv-ebar', 'aria-hidden': 'true' }, [el('i')]);
  const pauseBtn = el('button', { class: 'lv-eb', type: 'button', text: s.pause, onclick: togglePause });
  const cancelBtn = el('button', { class: 'lv-eb lv-cancel', type: 'button', text: s.cancel, onclick: () => end('cancel') });
  const foldBtn = el('button', { class: 'lv-fold', type: 'button', 'aria-label': s.fold, onclick: () => setExpanded(false) }, [el('span', { 'aria-hidden': 'true', text: '⌃' })]);
  const card = el('div', { class: 'lv-card', role: 'group', 'aria-label': s.cardLabel }, [
    el('div', { class: 'lv-etop' }, [ico(), el('span', { class: 'lv-ename', text: s.name }), foldBtn]), eTime, eBar, el('div', { class: 'lv-erow' }, [pauseBtn, cancelBtn])]);
  const isl = el('div', { class: 'lv-isl', 'data-s': 'idle' }, [cBtn, card]);

  // ── 鎖定畫面與待機畫面 ──
  const lock = el('div', { class: 'lv-lock' }, [el('div', { class: 'lv-lclock', text: s.clock }), el('div', { class: 'lv-ltag', text: s.lockTag })]);
  const sbTime = el('div', { class: 'lv-sbtime' });
  const sbRing = el('div', { class: 'lv-sbring' }, [sbTime]);
  const sb = el('div', { class: 'lv-sb' }, [
    el('div', { class: 'lv-sbidle' }, [
      el('div', { class: 'lv-sbw' }, [el('b', { text: '23°' }), el('span', { text: s.place })]),
      el('div', { class: 'lv-sbclock', text: s.clock }),
      el('div', { class: 'lv-sbw' }, [el('b', { text: '14:30' }), el('span', { text: s.event })])]),
    el('div', { class: 'lv-sbact' }, [el('div', { class: 'lv-sbname', text: s.name }), sbRing, el('div', { class: 'lv-sbtag', text: s.sbTag })])]);
  const phone = el('div', { class: 'lv-phone', role: 'group', 'aria-label': s.phoneLabel, 'data-s': 'idle' }, [el('div', { class: 'lv-screen' }, [lock, sb]), isl]);

  // ── 控制 ──
  const startBtn = el('button', { class: 'lv-btn', type: 'button', text: s.start, onclick: start });
  const fastBtn = el('button', { class: 'lv-btn lv-tog', type: 'button', 'aria-pressed': 'false', text: s.fast, onclick: () => { fast = !fast; fastBtn.setAttribute('aria-pressed', String(fast)); api.say(fast ? s.fastOn : s.fastOff); } });
  const sideBtn = el('button', { class: 'lv-btn lv-tog', type: 'button', 'aria-pressed': 'false', text: s.side, onclick: () => { side = !side; sideBtn.setAttribute('aria-pressed', String(side)); phone.classList.toggle('land', side); api.say(side ? (state === 'idle' ? s.sideIdle : s.sideAct) : s.sideOff); } });
  api.stage.append(el('div', { class: 'lv' }, [
    el('div', { class: 'lv-room' }, [phone]),
    el('div', { class: 'lv-ctl' }, [startBtn, fastBtn, sideBtn]),
    el('p', { class: 'lv-fact', text: s.rules }), el('p', { class: 'lv-fact', text: s.history })]));

  function draw() {
    const t = mmss(rem), p = 1 - rem / DUR;
    cTime.textContent = state === 'done' ? s.done : t; eTime.textContent = running ? t : fmt(s.pausedAt, { t });
    sbTime.textContent = state === 'done' ? s.done : t;
    phone.style.setProperty('--p', p.toFixed(3));
    isl.dataset.s = state; phone.dataset.s = state === 'idle' ? 'idle' : 'act';
    cBtn.disabled = state === 'done'; cBtn.setAttribute('aria-expanded', String(state === 'expanded'));
    cBtn.setAttribute('aria-label', state === 'done' ? s.done : fmt(s.compactLabel, { t }));
    pauseBtn.textContent = running ? s.pause : s.resume;
    startBtn.disabled = state !== 'idle';
  }
  function start() {
    rem = DUR; running = true; state = 'compact'; draw();
    api.say(s.started); cBtn.focus({ preventScroll: true });
  }
  function setExpanded(on) {
    if (state !== 'compact' && state !== 'expanded') return;
    state = on ? 'expanded' : 'compact'; draw();
    api.say(on ? s.expanded : s.collapsed);
    (on ? pauseBtn : cBtn).focus({ preventScroll: true });
  }
  function togglePause() { running = !running; draw(); api.say(running ? s.resumed : s.paused); }
  function end(how) {
    const mine = api.root.contains(document.activeElement) || document.activeElement === document.body;
    state = 'idle'; draw(); if (mine) startBtn.focus({ preventScroll: true }); // 讀者在別處打字時不搶焦點
    api.say(how === 'cancel' ? s.cancelled : s.gone);
  }
  function tick() {
    if (state === 'done') { doneMs -= 100; if (doneMs <= 0) end('done'); return; }
    if (state === 'idle' || !running) return;
    rem -= 100 * (fast ? 10 : 1);
    if (rem <= 0) { rem = 0; state = 'done'; doneMs = DONE; draw(); api.say(s.finished); return; }
    // 每秒更新一次畫面就夠，倒數與進度條才不會每 100 毫秒重畫
    if (Math.ceil(rem / 1000) !== Math.ceil((rem + 100 * (fast ? 10 : 1)) / 1000) || fast) draw();
  }
  // Esc 收起卡片
  isl.addEventListener('keydown', (e) => { if (e.key === 'Escape' && state === 'expanded') { setExpanded(false); e.stopPropagation(); } });
  api.whileVisible(() => { clearInterval(timer); timer = setInterval(tick, 100); }, () => clearInterval(timer));
  api.onReset(() => { rem = DUR; state = 'idle'; running = true; fast = false; side = false; fastBtn.setAttribute('aria-pressed', 'false'); sideBtn.setAttribute('aria-pressed', 'false'); sideBtn.textContent = s.side; phone.classList.remove('land'); draw(); });
  draw();
});
