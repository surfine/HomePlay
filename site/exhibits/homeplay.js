// 12 · 2026 HomePlay · ClioTalk：全篇的收尾。頂端膠囊裡的 👀 用首頁「為什麼是眼睛」同一套 SVG（build.mjs 的 eye()），
// 瞳孔跟著指標、停 4 秒就闔眼；下面的 ClioTalk 面板從不自己開口，按「問」或在展品裡按住 F5 才聽。
// 三句建議全是事先寫好的：回答是暫時的、以你的名義做的事先唸給你聽、訊息草稿用你自己的話。不呼叫任何模型。
HX.register('homeplay', (api) => {
  const { el, s, fmt } = api;
  const root = el('div', { class: 'hp' });

  // ── 眼睛：照抄首頁的 eye()，漸層 id 換成本展品自己的 ──
  const eye = (cx, cy) => `<g class="eye" data-cx="${cx}" data-cy="${cy}"><ellipse cx="${cx}" cy="${cy}" rx="36" ry="52" fill="url(#hp-sclera)"/><g class="pupil"><circle cx="${cx}" cy="${cy}" r="19.4" fill="url(#hp-iris)" stroke="#3c1b00" stroke-width="1.1" stroke-opacity=".9"/><circle cx="${cx}" cy="${cy}" r="12.4" fill="#291201"/><circle cx="${cx - 7.3}" cy="${cy - 10.9}" r="5.8" fill="#fff"/></g><path class="lid" d="M ${cx - 24} ${cy + 10} Q ${cx} ${cy + 26} ${cx + 24} ${cy + 10}" fill="none" stroke="#15181c" stroke-width="4.6" stroke-linecap="round" opacity="0"/></g>`;
  const svg = `<svg viewBox="50 84 200 116" aria-hidden="true" focusable="false"><defs><radialGradient id="hp-sclera" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#fff"/><stop offset=".8" stop-color="#fdfdfd"/><stop offset=".89" stop-color="#e6e6e6"/><stop offset=".955" stop-color="#c2c2c2"/><stop offset="1" stop-color="#949494"/></radialGradient><linearGradient id="hp-iris" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5a2a00"/><stop offset=".42" stop-color="#683900"/><stop offset=".62" stop-color="#7a4800"/><stop offset=".8" stop-color="#b78600"/><stop offset=".92" stop-color="#e2ab00"/><stop offset="1" stop-color="#d9a400"/></linearGradient></defs>${eye(98, 142)}${eye(202, 142)}</svg>`;
  const capsule = el('div', { class: 'hp-capsule', role: 'img', 'aria-label': s.eyesLabel, html: svg });
  const bead = el('div', { class: 'hp-bead', 'aria-hidden': 'true' });
  const time = el('p', { class: 'hp-time', 'aria-hidden': 'true' });

  // ── ClioTalk 面板 ──
  const ask = el('button', { class: 'hp-ask', type: 'button', 'aria-label': `${s.ask}: ${s.ready}` }, [
    el('span', { class: 'hp-dot', 'aria-hidden': 'true' }), el('span', { class: 'hp-hint', text: s.ready }), el('span', { class: 'hp-askl', 'aria-hidden': 'true', text: s.ask }),
  ]);
  const body = el('div', { class: 'hp-body' });
  const foot = el('p', { class: 'hp-foot', 'aria-hidden': 'true' });
  const panel = el('div', { class: 'hp-panel', role: 'group', 'aria-label': 'ClioTalk' }, [ask, body, foot]);
  const screen = el('div', { class: 'hp-screen', tabindex: '-1' }, [capsule, bead, time, panel]);

  // ── 打斷次數：ClioTalk 永遠是 0 ──
  const count = el('span', { class: 'hp-count', text: '0' });
  const compare = el('p', { class: 'hp-compare' });
  const meta = el('div', { class: 'hp-meta' }, [el('p', { class: 'hp-counter' }, [el('span', { text: s.counter }), count]), compare]);
  const readClippy = () => {
    const c = document.querySelector('#ex-clippy');
    const n = c && c.dataset.interruptions;
    compare.textContent = n != null && /^\d+$/.test(n) ? (+n === 1 ? s.clippy1 : fmt(s.clippyN, { n })) : s.clippyNone;
  };

  root.append(screen, meta);
  api.stage.append(root);

  // ── 狀態：idle 安靜、listen 在聽、answer 暫時的回答、confirm 等你說好、done 做完（或沒做） ──
  let state = 'idle', ruleTold = false;
  const setState = (st) => { state = st; root.dataset.state = st; ask.setAttribute('aria-expanded', String(st === 'listen')); };
  const you = (q) => el('p', { class: 'hp-you', text: q });
  const card = (cls, kids) => el('div', { class: `hp-card ${cls}`, role: 'group', tabindex: '-1' }, kids);
  const finish = (text) => {
    setState('done');
    foot.textContent = '';
    if (!ruleTold) { ruleTold = true; api.say(text + (api.lang.startsWith('zh') ? '' : ' ') + s.rule); } else api.say(text);
    root.classList.add('hp-tried');
  };

  function listen() {
    if (state === 'listen') return;
    setState('listen');
    wake();
    const sugs = s.q.map((q, k) => el('button', { class: 'hp-sug', type: 'button', text: q, onclick: () => choose(k) }));
    const close = el('button', { class: 'hp-x', type: 'button', 'aria-label': s.close, text: '×', onclick: () => dismiss() });
    body.replaceChildren(el('div', { class: 'hp-pickrow' }, [el('p', { class: 'hp-pick', text: s.pick }), close]), el('div', { class: 'hp-sugs', role: 'group', 'aria-label': s.pick }, sugs));
    foot.textContent = s.listening;
    api.say(s.listening);
    sugs[0].focus({ preventScroll: true });
  }
  function dismiss() {
    if (state === 'confirm') { body.querySelector('[data-cancel]').click(); return; }
    setState('idle');
    body.replaceChildren();
    foot.textContent = '';
    api.say(s.dismissed);
    ask.focus({ preventScroll: true });
  }
  function choose(k) {
    const q = s.q[k];
    if (k === 0) {
      // 回答：虛線框＝暫時的；按「留下」才變實線
      const label = el('span', { class: 'hp-tag', text: s.temporary });
      const keep = el('button', { class: 'hp-btn hp-keep', type: 'button', text: s.keep });
      const c = card('hp-temp', [el('p', { class: 'hp-ctitle', text: s.answerTitle }), el('ul', { class: 'hp-lines' }, s.answer.map((a) => el('li', { text: a }))), el('div', { class: 'hp-row' }, [label, keep])]);
      keep.addEventListener('click', () => { c.classList.replace('hp-temp', 'hp-kept'); label.textContent = s.kept; keep.remove(); c.focus({ preventScroll: true }); finish(s.saidKept); });
      body.replaceChildren(you(q), c);
      setState('answer');
      foot.textContent = '';
      api.say(fmt(s.answerSay, { list: s.answer.join(s.listSep) }) + (api.lang.startsWith('zh') ? '' : ' ') + s.saidAnswer);
      keep.focus({ preventScroll: true });
      return;
    }
    // 以你的名義做的事：先唸一遍，等「好」
    const msg = k === 1;
    const head = msg ? s.msgQ : s.doorQ;
    const detail = msg ? [el('p', { class: 'hp-to', text: s.msgTo }), el('p', { class: 'hp-draft', text: fmt(s.quote, { t: s.draft }) })] : [el('p', { class: 'hp-draft hp-door', text: s.door })];
    const cancel = el('button', { class: 'hp-btn', type: 'button', text: s.cancel, 'data-cancel': '' });
    const ok = el('button', { class: 'hp-btn hp-ok', type: 'button', text: s.ok });
    const row = el('div', { class: 'hp-row hp-end' }, [cancel, ok]);
    const c = card('hp-confirm', [el('p', { class: 'hp-ctitle', text: head }), ...detail, row]);
    c.setAttribute('aria-label', head);
    const done = (yes) => {
      const res = yes ? (msg ? s.sent : s.unlocked) : (msg ? s.notSent : s.staysLocked);
      row.replaceChildren(el('span', { class: `hp-tag ${yes ? 'hp-yes' : ''}`, text: res }));
      c.classList.add(yes ? 'hp-did' : 'hp-not');
      c.focus({ preventScroll: true });
      finish(yes ? (msg ? s.saidSent : s.saidUnlocked) : res);
    };
    cancel.addEventListener('click', () => done(false));
    ok.addEventListener('click', () => done(true));
    body.replaceChildren(you(q), c);
    setState('confirm');
    foot.textContent = s.confirm;
    api.say(fmt(s.saidConfirm, { what: msg ? fmt(s.readbackMsg, { q: fmt(s.quote, { t: s.draft }) }) : s.door }));
    c.focus({ preventScroll: true });
  }
  ask.addEventListener('click', listen);

  // 鍵盤：F5 只在焦點在展品裡時攔下；方向鍵在建議之間移動；Esc 取消
  root.addEventListener('keydown', (e) => {
    if (e.key === 'F5' && !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)) { e.preventDefault(); if (!e.repeat && state !== 'listen' && state !== 'confirm') listen(); return; }
    if (e.key === 'Escape' && state !== 'idle' && state !== 'done') { dismiss(); e.preventDefault(); return; }
    const sugs = [...body.querySelectorAll('.hp-sug')];
    const at = sugs.indexOf(document.activeElement);
    const m = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
    if (at >= 0 && m) { sugs[(at + m + sugs.length) % sugs.length].focus(); e.preventDefault(); }
  });
  // 點螢幕空白處，焦點留在展品裡，F5 才接得到
  screen.addEventListener('pointerdown', (e) => { if (!e.target.closest('button')) screen.focus({ preventScroll: true }); });

  // ── 眼睛的動作：照首頁 app.js 的那套（跟著看、眨眼、停 4 秒闔眼） ──
  const eyes = [...capsule.querySelectorAll('.eye')].map((g) => ({ g, pupil: g.querySelector('.pupil'), cx: +g.dataset.cx, cy: +g.dataset.cy }));
  const MX = 14, MY = 30;
  const draw = (ux, uy, open, k) => {
    const close = Math.min(1, Math.max(0, (0.55 - open * k) / 0.25));
    capsule.style.setProperty('--c', close.toFixed(3));
    for (const e of eyes) {
      e.pupil.setAttribute('transform', `translate(${(ux * MX).toFixed(2)} ${(uy * MY).toFixed(2)})`);
      e.g.setAttribute('transform', `translate(${e.cx} ${e.cy}) scale(${k.toFixed(3)}) translate(${-e.cx} ${-e.cy})`);
    }
  };
  let px = 0, py = 0, moved = false, lastMove = 0, sleeping = false;
  let ux = 0, uy = 0, open = 1, startle = 0, blinkT = -1, nextBlink = 0, raf = 0, prev = 0;
  function wake() { moved = true; lastMove = performance.now(); if (sleeping || open < 0.8) startle = 1; sleeping = false; }
  api.root.addEventListener('pointermove', (e) => { px = e.clientX; py = e.clientY; wake(); }, { passive: true });
  api.root.addEventListener('pointerdown', (e) => { px = e.clientX; py = e.clientY; wake(); }, { passive: true });
  const tick = (now) => {
    raf = requestAnimationFrame(tick);
    const dt = Math.min(0.05, (now - prev) / 1000 || 0.016); prev = now;
    const r = capsule.getBoundingClientRect();
    let tx, ty;
    const busy = state !== 'idle' && state !== 'done';
    if (busy && now - lastMove > 700) { tx = 0; ty = 0.75; } // ClioTalk 在聽：看著下面的面板
    else if (moved) {
      const dx = px - (r.left + r.width / 2), dy = py - (r.top + r.height / 2);
      const l = Math.hypot(dx, dy) || 1, f = Math.min(1, l / 260) / l;
      tx = dx * f; ty = dy * f;
    } else { const t = now / 1000; tx = Math.sin(t * 0.55) * 0.75; ty = Math.sin(t * 0.37 + 1) * 0.4; }
    sleeping = !busy && moved && now - lastMove > 4000;
    const kLook = 1 - Math.exp(-dt * 10);
    ux += (tx - ux) * kLook; uy += (ty - uy) * kLook;
    open += ((sleeping ? 0.08 : 1) - open) * (1 - Math.exp(-dt * (sleeping ? 7 : 30)));
    if (!sleeping && blinkT < 0 && now >= nextBlink) blinkT = 0;
    let blink = 1;
    if (blinkT >= 0) {
      blinkT += dt * 1000;
      if (blinkT >= 140) { blinkT = -1; nextBlink = now + 3000 + Math.random() * 3000; } else blink = 1 - 0.92 * Math.sin((Math.PI * blinkT) / 140);
    } else if (!nextBlink || nextBlink < now - 8000) nextBlink = now + 3000 + Math.random() * 3000;
    startle *= Math.exp(-dt * 7);
    root.classList.toggle('hp-asleep', sleeping);
    draw(ux, uy, open * blink, 1 + 0.08 * startle);
  };

  // 時鐘：只在看得到時走
  let clock = 0;
  const showTime = () => { const d = new Date(); time.textContent = `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`; };
  api.whileVisible(() => {
    readClippy(); showTime(); clearInterval(clock); clock = setInterval(showTime, 15000);
    if (api.reduced) { draw(0, 0.35, 1, 1); return; } // 減少動態效果：眼睛不動、不眨、不闔
    if (!raf) { prev = performance.now(); nextBlink = prev + 3000 + Math.random() * 3000; raf = requestAnimationFrame(tick); }
  }, () => { clearInterval(clock); cancelAnimationFrame(raf); raf = 0; });
  if (api.reduced) draw(0, 0.35, 1, 1);

  setState('idle');
  readClippy();
  showTime();
  api.onReset(() => { setState('idle'); body.replaceChildren(); foot.textContent = ''; ruleTold = false; root.classList.remove('hp-tried'); readClippy(); });
});
