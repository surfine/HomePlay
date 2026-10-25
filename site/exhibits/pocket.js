// 02 · 2009 → 2023 口袋裡的小工具：左邊是一直醒著的 2007 小工具，右邊是 2020 的時間軸小工具。
// 同一條「一天」的時間軸同時推動兩邊：左邊的 CPU 一直爬，右邊只在系統重新載入時醒一下。
// 數字全是示意（預算 50 次、每次立即重載算 3 次），不是實測。天氣、地名都是虛構的。
HX.register('pocket', (api) => {
  const { el, s, fmt } = api;
  const BUDGET = 50, COST = 3, EVERY = 60, DAYMIN = 1440, DRAIN = 18;
  // [小時, 天氣種類, 氣溫]
  const ENT = [[0, 'moon', 14], [6, 'dawn', 15], [9, 'sun', 19], [12, 'sun', 23], [15, 'cloud', 21], [18, 'rain', 18], [21, 'moon', 15]];
  const G = {
    sun: '<circle cx="12" cy="12" r="5" fill="#f5b342"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2" stroke="#f5b342" stroke-width="2" stroke-linecap="round"/>',
    cloud: '<path d="M7 18a4 4 0 0 1-.5-8 5.5 5.5 0 0 1 10.6 1.2A3.4 3.4 0 0 1 17 18z" fill="#cfd6e0"/>',
    rain: '<path d="M7 15a4 4 0 0 1-.5-8 5.5 5.5 0 0 1 10.6 1.2A3.4 3.4 0 0 1 17 15z" fill="#aab4c2"/><path d="M8 18l-1 3M12 18l-1 3M16 18l-1 3" stroke="#5b8ff5" stroke-width="2" stroke-linecap="round"/>',
    moon: '<path d="M16 3a9 9 0 1 0 5 15A8 8 0 0 1 16 3z" fill="#c9d3ff"/>',
    dawn: '<path d="M5 17a7 7 0 0 1 14 0z" fill="#f2a65a"/><path d="M2 20h20" stroke="#8a93a0" stroke-width="2" stroke-linecap="round"/><path d="M12 5v3M4.5 9l2 2M19.5 9l-2 2" stroke="#f2a65a" stroke-width="2" stroke-linecap="round"/>',
  };
  const icon = (k) => el('span', { class: 'pk-ico', 'aria-hidden': 'true', html: `<svg viewBox="0 0 24 24">${G[k]}</svg>` });
  const p2 = (n) => String(n).padStart(2, '0');
  const hm = (m) => `${Math.floor(m / 60)}:${p2(m % 60)}`;
  let t = 0, manual = 0, manualT = -1, playing = false, timer = 0, lastIdx = 0;

  const sched = () => Math.floor(t / EVERY);
  const want = () => sched() + manual * COST;
  const used = () => Math.min(BUDGET, want());
  const idx = () => ENT.reduce((a, e, i) => (e[0] * 60 <= t ? i : a), 0);

  // ── 左：一直醒著的小工具 ──
  const gClock = el('output', { class: 'pk-gclock', 'aria-live': 'off' });
  const gTemp = el('span', { class: 'pk-gtemp' });
  const gIcon = el('span', { class: 'pk-gicon' });
  const gad = el('div', { class: 'pk-gad' }, [
    el('div', { class: 'pk-gtitle' }, [el('span', { text: s.gadgetName }), el('span', { class: 'pk-gdot', 'aria-hidden': 'true' })]),
    el('div', { class: 'pk-grow' }, [gIcon, gTemp, gClock]),
  ]);
  const meter = (label) => {
    const val = el('span', { class: 'pk-mval' });
    const fill = el('span', { class: 'pk-mfill' });
    return { val, fill, node: el('div', { class: 'pk-meter' }, [el('div', { class: 'pk-mlabel' }, [el('span', { text: label }), val]), el('div', { class: 'pk-mbar', 'aria-hidden': 'true' }, [fill])]) };
  };
  const gAwake = meter(s.awake), gBat = meter(s.battery);
  const left = el('div', { class: 'pk-card' }, [
    el('h4', { class: 'pk-h', text: s.gadgetTitle }), el('p', { class: 'pk-sub', text: s.gadgetNote }),
    gad, gAwake.node, gBat.node,
  ]);

  // ── 右：手機主畫面上的天氣小工具，由時間軸餵 ──
  const wIcon = el('span', { class: 'pk-wicon' });
  const wTemp = el('span', { class: 'pk-wtemp' });
  const wName = el('span', { class: 'pk-wname' });
  const wLast = el('span', { class: 'pk-wlast' });
  const wStale = el('span', { class: 'pk-wstale', hidden: true, text: s.staleTag });
  const widget = el('div', { class: 'pk-widget' }, [
    el('div', { class: 'pk-wtop' }, [el('span', { class: 'pk-wplace', text: s.place }), wStale]),
    el('div', { class: 'pk-wmid' }, [wTemp, wIcon]), wName, wLast,
  ]);
  const apps = el('div', { class: 'pk-apps', 'aria-hidden': 'true' }, [...Array(8)].map((_, i) => el('i', { class: `pk-app a${i}` })));
  const phone = el('div', { class: 'pk-phone', role: 'img', 'aria-label': s.phoneLabel }, [el('span', { class: 'pk-island', 'aria-hidden': 'true' }), widget, apps]);
  const wAwake = meter(s.awake), wBat = meter(s.battery);
  const right = el('div', { class: 'pk-card' }, [
    el('h4', { class: 'pk-h', text: s.widgetTitle }), el('p', { class: 'pk-sub', text: s.widgetNote }),
    phone, wAwake.node, wBat.node,
  ]);

  // ── 控制：時間、播放、時間軸、預算 ──
  const clockOut = el('output', { class: 'pk-time', 'aria-live': 'off' });
  const range = el('input', { class: 'pk-range', type: 'range', min: 0, max: DAYMIN, step: 5, value: 0, 'aria-label': s.scrub });
  const playBtn = el('button', { class: 'pk-btn', type: 'button', text: s.play });
  const cards = ENT.map(([h, k, d]) => el('li', { class: 'pk-ent', 'aria-label': fmt(s.entryLabel, { t: hm(h * 60), w: s['w_' + k], d }) }, [el('span', { class: 'pk-et', text: hm(h * 60) }), icon(k), el('span', { class: 'pk-ed', text: `${d}°` })]));
  const strip = el('ul', { class: 'pk-strip' }, cards);
  const bFill = el('span', { class: 'pk-mfill' });
  const bText = el('span', { class: 'pk-btext' });
  const bar = el('div', { class: 'pk-budget', role: 'meter', 'aria-valuemin': 0, 'aria-valuemax': BUDGET, 'aria-label': s.budgetLabel }, [el('div', { class: 'pk-mbar', 'aria-hidden': 'true' }, [bFill])]);
  const ask = el('button', { class: 'pk-btn pk-ask', type: 'button', text: fmt(s.ask, { n: COST }) });
  const cmp = el('p', { class: 'pk-cmp' });
  const ctl = el('div', { class: 'pk-ctl' }, [
    el('div', { class: 'pk-scrub' }, [playBtn, range, clockOut]),
    el('div', { class: 'pk-cap', text: s.stripCap }), strip,
    el('div', { class: 'pk-brow' }, [el('span', { class: 'pk-cap', text: s.budgetCap }), bText]), bar, ask,
    cmp, el('p', { class: 'pk-fact', text: fmt(s.budgetFact, { n: BUDGET }) }),
    el('p', { class: 'pk-fact', text: s.illus }),
  ]);
  api.stage.append(el('div', { class: 'pk' }, [el('div', { class: 'pk-cols' }, [left, right]), ctl]));

  function render(announce) {
    const i = idx(), [, k, d] = ENT[i], u = used();
    range.value = t; range.setAttribute('aria-valuetext', hm(t));
    clockOut.textContent = hm(t);
    // 左：每一分鐘都醒著
    gClock.textContent = hm(t);
    gTemp.textContent = `${d}°`;
    gIcon.replaceChildren(icon(k));
    const gMin = t, wMin = Math.round(u * 0.5);
    gAwake.val.textContent = fmt(s.min, { n: gMin }); gAwake.fill.style.setProperty('--v', gMin / DAYMIN);
    wAwake.val.textContent = fmt(s.min, { n: wMin }); wAwake.fill.style.setProperty('--v', wMin / DAYMIN);
    const gB = (gMin / DAYMIN) * DRAIN, wB = (wMin / DAYMIN) * DRAIN;
    gBat.val.textContent = gB > 0 ? `-${gB.toFixed(1)}%` : "0%"; gBat.fill.style.setProperty('--v', gB / DRAIN);
    wBat.val.textContent = wB > 0 ? `-${wB.toFixed(1)}%` : "0%"; wBat.fill.style.setProperty('--v', wB / DRAIN);
    cmp.textContent = fmt(s.cmp, { g: gMin, gb: gB.toFixed(1), w: wMin, wb: wB.toFixed(1) });
    // 右：目前這一格
    wIcon.replaceChildren(icon(k)); wTemp.textContent = `${d}°`; wName.textContent = s['w_' + k];
    widget.className = `pk-widget pk-k-${k}`;
    const last = Math.max(sched() * EVERY, manualT >= 0 && manualT <= t ? manualT : 0);
    wLast.textContent = fmt(s.last, { t: hm(last) });
    wStale.hidden = want() <= BUDGET;
    cards.forEach((c, n) => { c.classList.toggle('on', n === i); n === i ? c.setAttribute('aria-current', 'true') : c.removeAttribute('aria-current'); });
    bFill.style.setProperty('--v', u / BUDGET);
    bar.setAttribute('aria-valuenow', u); bar.classList.toggle('out', want() >= BUDGET);
    bText.textContent = fmt(s.used, { used: u, total: BUDGET }) + (want() >= BUDGET ? ' · ' + s.out : '');
    if (announce && i !== lastIdx) api.say(fmt(s.swap, { t: hm(ENT[i][0] * 60), w: s['w_' + k], d }));
    lastIdx = i;
  }
  function setT(v, announce) { t = Math.max(0, Math.min(DAYMIN, v)); render(announce); }
  const stop = () => { playing = false; clearInterval(timer); playBtn.textContent = s.play; };
  function go() {
    if (playing) return;
    if (t >= DAYMIN) setT(0, false);
    playing = true; playBtn.textContent = s.pause;
    // 一天約 10 秒；減少動態效果時改成每小時跳一格
    const step = api.reduced ? 60 : 15;
    timer = setInterval(() => { setT(t + step, true); if (t >= DAYMIN) { stop(); api.say(s.dayEnd); } }, api.reduced ? 500 : 100);
  }
  playBtn.addEventListener('click', () => (playing ? (stop(), api.say(s.paused)) : go()));
  range.addEventListener('input', () => { stop(); setT(+range.value, true); });
  ask.addEventListener('click', () => {
    if (want() + COST > BUDGET) { api.say(fmt(s.refused, { used: used(), total: BUDGET })); return; }
    manual += 1; manualT = t; render(false);
    api.say(fmt(s.spent, { n: COST, used: used(), total: BUDGET }));
  });
  api.whileVisible(() => {}, stop);
  api.onReset(() => { stop(); manual = 0; manualT = -1; lastIdx = 0; setT(0, false); });
  render(false);
});
