// 06 · 1997 → 2009 Microsoft Agent：一個原創的小機器人，加一份你能編輯的腳本。
// 「執行」照腳本一步一步演；「讓三個網頁一起呼叫它」讓三份腳本同時控制同一個角色，體會開口的時機被交給了每一頁。
// 全部自己畫，角色不是 Microsoft Agent 的任何一位；語音只在勾選「出聲朗讀」且瀏覽器支援時才用。
HX.register('agent', (api) => {
  const { el, s, fmt } = api;
  const POS = { left: 0, center: 1, right: 2 };
  const PLAYS = ['wave', 'think', 'bow'];
  let script = [{ t: 'Show' }, { t: 'MoveTo', a: 'right' }, { t: 'Play', a: 'wave' }, { t: 'Speak', a: s.hello }, { t: 'Hide' }];
  let token = 0, timers = [], running = false;
  const st = { shown: false, p: 1 };
  const label = (c) => `${c.t}(${c.a == null ? '' : `"${c.a}"`})`;
  const wait = (ms, fn) => timers.push(setTimeout(fn, api.reduced ? Math.min(ms, 350) : ms));

  // ── 舞台：機器人、天線、氣泡 ──
  const fig = '<svg viewBox="0 0 64 80" aria-hidden="true"><g class="ag-fig"><line class="ag-ant" x1="32" y1="14" x2="32" y2="4"/><circle class="ag-ball" cx="32" cy="4" r="3.5"/><rect class="ag-head" x="12" y="14" width="40" height="30" rx="14"/><circle class="ag-eye" cx="24" cy="29" r="3.5"/><circle class="ag-eye" cx="40" cy="29" r="3.5"/><path class="ag-mouth" d="M26 37q6 4 12 0"/><rect class="ag-torso" x="18" y="46" width="28" height="24" rx="10"/><g class="ag-armL"><rect class="ag-arm" x="8" y="48" width="9" height="16" rx="4.5"/></g><g class="ag-armR"><rect class="ag-arm" x="47" y="48" width="9" height="16" rx="4.5"/></g></g></svg>';
  const bubbles = [0, 1, 2, 3].map((i) => el('div', { class: `ag-bub ag-b${i}`, hidden: true, 'aria-hidden': 'true' }));
  const actor = el('div', { class: 'ag-actor', hidden: true }, [...bubbles, el('div', { class: 'ag-robot', html: fig })]);
  const cap = el('div', { class: 'ag-cap', 'aria-hidden': 'true' });
  const stage = el('div', { class: 'ag-stage', role: 'img', 'aria-label': s.stageLabel }, [actor, cap]);

  // ── 腳本與調色盤 ──
  const list = el('ol', { class: 'ag-list', 'aria-label': s.script });
  const speakIn = el('input', { class: 'ag-in', type: 'text', maxlength: '40', value: s.hello, 'aria-label': s.speakText });
  const add = (c) => { if (running) return; script.push(c); render(); api.say(fmt(s.added, { cmd: label(c), n: script.length })); };
  const pbtn = (c) => el('button', { class: 'ag-pal', type: 'button', text: label(c), 'aria-label': fmt(s.addCmd, { cmd: label(c) }), onclick: () => add({ ...c }) });
  const palette = el('div', { class: 'ag-palette', role: 'group', 'aria-label': s.palette }, [
    pbtn({ t: 'Show' }), ...Object.keys(POS).map((a) => pbtn({ t: 'MoveTo', a })), ...PLAYS.map((a) => pbtn({ t: 'Play', a })), pbtn({ t: 'Hide' }),
    el('div', { class: 'ag-speak' }, [speakIn, el('button', { class: 'ag-pal', type: 'button', text: 'Speak(…)', 'aria-label': s.addSpeak, onclick: () => add({ t: 'Speak', a: speakIn.value.trim() || '…' }) })]),
  ]);
  function render(active) {
    list.replaceChildren(...script.map((c, i) => {
      const b = (cls, txt, name, fn) => el('button', { class: `ag-mini ${cls}`, type: 'button', text: txt, 'aria-label': fmt(s[name], { cmd: label(c), n: i + 1 }), disabled: running, onclick: fn });
      return el('li', { class: `ag-item${i === active ? ' on' : ''}`, 'aria-current': i === active ? 'step' : null }, [
        el('code', { text: label(c) }),
        b('', '↑', 'up', () => { if (i > 0) { [script[i - 1], script[i]] = [script[i], script[i - 1]]; render(); list.children[i - 1].querySelector('.ag-mini').focus(); api.say(fmt(s.moved, { cmd: label(c), n: i })); } }),
        b('', '↓', 'down', () => { if (i < script.length - 1) { [script[i + 1], script[i]] = [script[i], script[i + 1]]; render(); list.children[i + 1].querySelectorAll('.ag-mini')[1].focus(); api.say(fmt(s.moved, { cmd: label(c), n: i + 2 })); } }),
        b('', '✕', 'del', () => { script.splice(i, 1); render(); (list.children[Math.min(i, script.length - 1)] || palette).querySelector('button').focus(); api.say(fmt(s.removed, { cmd: label(c), n: script.length })); }),
      ]);
    }));
  }

  // ── 控制 ──
  const runBtn = el('button', { class: 'ag-go', type: 'button', text: s.run });
  const threeBtn = el('button', { class: 'ag-go ag-three', type: 'button', text: s.three });
  const stopBtn = el('button', { class: 'ag-go', type: 'button', text: s.stop, hidden: true });
  const loud = el('input', { type: 'checkbox', id: 'ag-loud' });
  const loudL = el('label', { class: 'ag-loud', for: 'ag-loud' }, [loud, ' ' + s.aloud]);
  if (!('speechSynthesis' in window)) loudL.hidden = true;
  const ctrl = el('div', { class: 'ag-ctrl' }, [runBtn, threeBtn, stopBtn, loudL]);
  const root = el('div', { class: 'ag ag-p1' }, [stage, el('div', { class: 'ag-edit' }, [el('div', { class: 'ag-col' }, [el('div', { class: 'ag-h', text: s.palette }), palette]), el('div', { class: 'ag-col' }, [el('div', { class: 'ag-h', text: s.script }), list])]), ctrl]);
  api.stage.append(root);

  // ── 執行一個指令（who：0 是你的腳本，1～3 是三個網頁）──
  function exec(c, who) {
    cap.textContent = who ? fmt(s.capPage, { page: s['page' + who], cmd: label(c) }) : label(c);
    if (c.t === 'Show') { st.shown = true; }
    else if (c.t === 'Hide') { st.shown = false; bubbles.forEach((b) => { b.hidden = true; }); }
    else if (c.t === 'MoveTo') { st.p = POS[c.a]; }
    else if (c.t === 'Play') {
      const r = actor.querySelector('.ag-robot');
      r.classList.remove('wave', 'think', 'bow'); void r.offsetWidth;
      if (!api.reduced) { r.classList.add(c.a); wait(420, () => r.classList.remove(c.a)); }
    } else if (c.t === 'Speak') {
      const b = bubbles[who]; b.hidden = false; b.textContent = who ? `${s['page' + who]}: ${c.a}` : c.a;
      wait(who ? 2800 : Math.max(1400, c.a.length * 90), () => { b.hidden = true; }); // 網頁的氣泡留得久，才疊得起來
      if (loud.checked && window.speechSynthesis) { const u = new SpeechSynthesisUtterance(c.a); u.lang = api.lang === 'en' ? 'en-US' : api.lang === 'zh-Hans' ? 'zh-CN' : 'zh-TW'; speechSynthesis.speak(u); }
    }
    root.className = `ag ag-p${st.p}`;
    actor.hidden = !st.shown;
  }
  const stopAll = () => { token++; timers.forEach(clearTimeout); timers = []; if (window.speechSynthesis) speechSynthesis.cancel(); };
  function setRunning(v) {
    running = v; stopBtn.hidden = !v; runBtn.disabled = threeBtn.disabled = v;
    palette.querySelectorAll('button').forEach((b) => { b.disabled = v; });
    render();
    // 鍵盤使用者的焦點跟著走：開演時到「停止」，演完回到「執行」
    if (root.contains(document.activeElement) || document.activeElement === document.body) (v ? stopBtn : runBtn).focus({ preventScroll: true });
  }
  function reset() { stopAll(); st.shown = false; st.p = 1; actor.hidden = true; bubbles.forEach((b) => { b.hidden = true; }); cap.textContent = ''; root.className = 'ag ag-p1'; }
  // 一份腳本照步調一步一步演；done 在最後一步之後呼叫
  function play(steps, who, gap, done) {
    const me = token; let i = 0;
    const next = () => {
      if (me !== token) return;
      if (i >= steps.length) { done(); return; }
      if (who === 0) render(i);
      exec(steps[i], who);
      const d = who === 0 && steps[i].t === 'Speak' ? Math.max(1500, steps[i].a.length * 90) : gap;
      i++; wait(d, next);
    };
    next();
  }
  runBtn.addEventListener('click', () => {
    reset(); setRunning(true);
    api.say(fmt(s.running, { n: script.length }));
    play(script, 0, 700, () => { setRunning(false); render(); api.say(fmt(s.done, { n: script.length })); });
  });
  threeBtn.addEventListener('click', () => {
    reset(); setRunning(true); api.say(s.threeStart);
    const P = [
      [{ t: 'Show' }, { t: 'MoveTo', a: 'left' }, { t: 'Speak', a: s.line1 }, { t: 'MoveTo', a: 'right' }, { t: 'Speak', a: s.line1b }],
      [{ t: 'MoveTo', a: 'right' }, { t: 'Speak', a: s.line2 }, { t: 'Play', a: 'bow' }, { t: 'MoveTo', a: 'center' }, { t: 'Speak', a: s.line2b }],
      [{ t: 'MoveTo', a: 'center' }, { t: 'Play', a: 'wave' }, { t: 'Speak', a: s.line3 }, { t: 'MoveTo', a: 'left' }, { t: 'Speak', a: s.line3b }],
    ];
    let left = 3, moves = 0;
    P.forEach((steps, k) => wait(k * 250, () => play(steps, k + 1, 520 + k * 130, () => {
      if (--left === 0) wait(1600, () => { setRunning(false); moves = P.flat().filter((c) => c.t === 'MoveTo').length; reset(); render(); api.say(fmt(s.threeDone, { moves })); });
    })));
  });
  stopBtn.addEventListener('click', () => { stopAll(); setRunning(false); api.say(s.stopped); });
  api.whileVisible(() => {}, () => { if (running) { stopAll(); setRunning(false); } });
  api.onReset(() => { stopAll(); setRunning(false); script = [{ t: 'Show' }, { t: 'MoveTo', a: 'right' }, { t: 'Play', a: 'wave' }, { t: 'Speak', a: s.hello }, { t: 'Hide' }]; reset(); render(); });
  render();
});
