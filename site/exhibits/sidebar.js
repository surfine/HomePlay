// 03 · 2007 Windows Vista：側邊欄（電腦醒著才有）加 SideShow（筆電外蓋上的小螢幕）。
// 左邊是原創的玻璃側邊欄；右邊是 CSS 畫的筆電，蓋子上有一塊 220 × 176 比例的小螢幕和四顆按鍵。
// 能耗只是示意：小螢幕約 4 mW、整台電腦約 75 W（MSDN 原型的數字），每次同步當作電腦醒 30 秒。
HX.register('sidebar', (api) => {
  const { el, s, fmt } = api;
  const p2 = (n) => String(n).padStart(2, '0');
  const hm = (t) => `${p2(Math.floor(t / 60) % 24)}:${p2(t % 60)}`;
  const START = 540;                      // 世界從 09:00 開始
  let now = START, synced = START, snap = null, awake = false, wakes = 0, wh = 0;
  let view = 'list', sel = 0, slide = 0, timer = 0;
  const root = el('div', { class: 'sb' });

  // ── 世界：虛構的行事曆、信件、音樂，隨時間變 ──
  const APPTS = [[630, 'a0'], [780, 'a1'], [930, 'a2'], [1080, 'a3']];
  const world = (t) => {
    const next = APPTS.find((a) => a[0] > t) || APPTS[0];
    return { appt: next, mail: 2 + Math.floor((t - START) / 25), track: Math.floor(t / 4) % 3 };
  };
  snap = world(now);
  const PAGES = ['appt', 'mail', 'play'];

  // ── 左：PC 與側邊欄 ──
  const gad = { clock: true, show: true, feed: true };
  const sideEl = el('div', { class: 'sb-side', role: 'group', 'aria-label': s.sidebarLabel });
  const addRow = el('div', { class: 'sb-adds', role: 'group', 'aria-label': s.addLabel });
  const clockOut = el('output', { class: 'sb-clk' });
  const tile = el('div', { class: 'sb-tile', 'aria-hidden': 'true' });
  const nextBtn = el('button', { class: 'sb-next', type: 'button', 'aria-label': s.nextTile, text: '›' });
  const feed = el('ul', { class: 'sb-feed' }, [0, 1, 2].map((n) => el('li', { text: s['h' + n] })));
  const BODY = { clock: clockOut, show: el('div', { class: 'sb-showwrap' }, [tile, nextBtn]), feed };
  const boxes = {};
  Object.keys(BODY).forEach((k) => {
    const rm = el('button', { class: 'sb-x', type: 'button', 'aria-label': fmt(s.removeG, { name: s[k] }), text: '×', onclick: () => toggleG(k, false) });
    boxes[k] = el('div', { class: `sb-g sb-g-${k}` }, [el('div', { class: 'sb-gh' }, [el('span', { text: s[k] }), rm]), BODY[k]]);
    sideEl.append(boxes[k]);
    addRow.append(el('button', { class: 'sb-add', type: 'button', 'data-g': k, text: '+ ' + s[k], onclick: () => toggleG(k, true) }));
  });
  function toggleG(k, v) {
    gad[k] = v; boxes[k].hidden = !v; addRow.querySelector(`[data-g=${k}]`).hidden = v;
    api.say(fmt(v ? s.gAdded : s.gRemoved, { name: s[k] }));
    (v ? boxes[k].querySelector('.sb-x') : addRow.querySelector(`[data-g=${k}]`)).focus({ preventScroll: true });
  }
  addRow.querySelectorAll('.sb-add').forEach((b) => { b.hidden = true; });
  const wall = el('div', { class: 'sb-wall' }, [el('div', { class: 'sb-win', 'aria-hidden': 'true' }), sideEl, el('div', { class: 'sb-zzz', 'aria-hidden': 'true', text: s.zzz })]);
  const shades = ['a', 'b', 'c'];
  const drawTile = () => { tile.className = `sb-tile sb-t-${shades[slide]}`; };
  nextBtn.addEventListener('click', () => { slide = (slide + 1) % 3; drawTile(); });

  // ── 右：筆電與小螢幕 ──
  const scr = el('div', { class: 'sb-scr', role: 'status', 'aria-live': 'off', 'aria-label': s.screenLabel });
  const dev = el('div', { class: 'sb-dev', role: 'group', 'aria-label': s.deviceLabel });
  const DBTN = [['up', '▲'], ['down', '▼'], ['ok', 'OK'], ['back', '◀']];
  DBTN.forEach(([k, t]) => dev.append(el('button', { class: 'sb-btn', type: 'button', 'data-k': k, 'aria-label': s['b_' + k], text: t, onclick: () => press(k) })));
  dev.addEventListener('keydown', (e) => { const m = { ArrowUp: 'up', ArrowDown: 'down', Escape: 'back' }[e.key]; if (m) { press(m); e.preventDefault(); } });
  const lid = el('div', { class: 'sb-lid' }, [scr, dev]);
  const laptop = el('div', { class: 'sb-lap' }, [lid, el('div', { class: 'sb-hinge', 'aria-hidden': 'true' })]);

  const content = (p) => {
    if (p === 'appt') return [s.pAppt, fmt(s.apptLine, { t: hm(snap.appt[0]), what: s[snap.appt[1]] })];
    if (p === 'mail') return [s.pMail, fmt(s.mailLine, { n: snap.mail })];
    return [s.pPlay, s['trk' + snap.track]];
  };
  const stale = () => now - synced;
  function draw(speak) {
    scr.replaceChildren();
    const head = el('div', { class: 'sb-sh', text: view === 'list' ? s.menu : content(PAGES[sel])[0] });
    let body;
    if (view === 'list') body = el('ul', { class: 'sb-menu' }, PAGES.map((p, i) => el('li', { class: i === sel ? 'on' : '', text: content(p)[0] })));
    else body = el('div', { class: 'sb-sbody', text: content(PAGES[sel])[1] });
    const foot = el('div', { class: `sb-sf${stale() >= 30 ? ' old' : ''}`, text: fmt(s.lastSynced, { t: hm(synced) }) + (stale() >= 30 ? ' · ' + s.stale : '') });
    scr.append(head, body, foot);
    if (speak) api.say(`${view === 'list' ? s.menu + ': ' + content(PAGES[sel])[0] : content(PAGES[sel]).join('. ')}. ${foot.textContent}.`);
    stats();
  }
  function press(k) {
    if (k === 'up' || k === 'down') { sel = (sel + (k === 'down' ? 1 : 2)) % 3; }
    else if (k === 'ok') view = 'page';
    else if (k === 'back') view = 'list';
    draw(true);
  }

  // ── 控制與數字 ──
  const sleepBtn = el('button', { class: 'sb-ctl', type: 'button' });
  const hourBtn = el('button', { class: 'sb-ctl', type: 'button', text: s.hour });
  const wakeBtn = el('button', { class: 'sb-ctl sb-wake', type: 'button', text: s.wakeSync });
  const out = el('div', { class: 'sb-stats', 'aria-live': 'off' });
  const chips = el('div', { class: 'sb-chips', role: 'list', 'aria-label': s.chipsLabel });
  const note = el('p', { class: 'sb-note', text: s.illus });
  const whTxt = (v) => (v < 1 ? v.toFixed(3) : v.toFixed(1)) + ' Wh';
  function stats() {
    sleepBtn.textContent = awake ? s.pcAwake : s.pcAsleep; // 文字本身就說出狀態，不再加 aria-pressed
    wakeBtn.disabled = awake;
    wall.classList.toggle('asleep', !awake);
    clockOut.textContent = hm(now);
    out.textContent = fmt(s.stats, { time: hm(now), w: wakes, e: whTxt(wh) });
    const ok = [[s.cNear, true], [fmt(s.cFresh, { m: stale() }), stale() < 30], [s.cNoWake, wakes === 0]];
    chips.replaceChildren(...ok.map(([t, v]) => el('span', { class: `sb-chip ${v ? 'yes' : 'no'}`, role: 'listitem', text: (v ? '✓ ' : '✗ ') + t })));
  }
  const doSync = () => { synced = now; snap = world(now); };
  function advance(min) {
    now += min;
    wh += awake ? 75 * (min / 60) : 0.004 * (min / 60);   // 小時 × 瓦
    if (awake) doSync();
  }
  sleepBtn.addEventListener('click', () => {
    awake = !awake;
    if (awake) { wakes++; wh += 75 * (30 / 3600); doSync(); api.say(fmt(s.woke, { n: wakes })); } else api.say(s.slept);
    draw(false);
  });
  hourBtn.addEventListener('click', () => { advance(60); draw(false); api.say(fmt(awake ? s.hourAwake : s.hourAsleep, { t: hm(now), s: hm(synced) })); });
  wakeBtn.addEventListener('click', () => { wakes++; wh += 75 * (30 / 3600); doSync(); draw(false); api.say(fmt(s.syncDone, { n: wakes, e: whTxt(wh) })); });

  const ctl = el('div', { class: 'sb-ctls' }, [sleepBtn, hourBtn, wakeBtn]);
  const right = el('div', { class: 'sb-right' }, [laptop, ctl, chips, out, note]);
  const left = el('div', { class: 'sb-left' }, [el('div', { class: 'sb-cap', text: s.pcCap }), wall, addRow]);
  root.append(left, right);
  api.stage.append(root);
  drawTile(); draw(false);
  api.whileVisible(() => { clearInterval(timer); timer = setInterval(() => { if (awake && gad.show && !api.reduced) { slide = (slide + 1) % 3; drawTile(); } }, 3000); }, () => clearInterval(timer));
  api.onReset(() => {
    now = synced = START; snap = world(now); awake = false; wakes = 0; wh = 0; view = 'list'; sel = 0;
    Object.keys(gad).forEach((k) => { gad[k] = true; boxes[k].hidden = false; addRow.querySelector(`[data-g=${k}]`).hidden = true; });
    draw(false);
  });
});
