// 04 · 2012 安全公告 2719662：小工具看起來小，跑的是完整的程式。
// 全部虛構：四個小工具、檔名與「示範」都是模擬，沒有讀取任何東西，也沒有送出任何東西。
HX.register('removed', (api) => {
  const { el, s, fmt } = api;
  const GADS = [['g0', false], ['g1', false], ['g2', true], ['g3', false]];   // 第三個是虛構的惡意小工具
  const installed = new Set();
  let phase = 'open', pending = null, timers = [], offOn = false;
  const root = el('div', { class: 'rm' });
  const later = (fn, ms) => { timers.push(setTimeout(fn, api.reduced ? 0 : ms)); };

  // ── 圖庫 ──
  const cards = {};
  const gallery = el('div', { class: 'rm-gal', role: 'group', 'aria-label': s.galLabel });
  GADS.forEach(([k]) => {
    const b = el('button', { class: 'rm-inst', type: 'button', 'aria-label': fmt(s.installLabel, { name: s[k] }), text: s.install, onclick: () => ask(k) });
    cards[k] = el('div', { class: 'rm-card' }, [el('div', { class: 'rm-ico', 'aria-hidden': 'true', 'data-k': k }), el('div', { class: 'rm-nm', text: s[k] }), el('div', { class: 'rm-ds', text: s[k + 'd'] }), b]);
    gallery.append(cards[k]);
  });
  const tray = el('div', { class: 'rm-tray', role: 'group', 'aria-label': s.trayLabel });
  const trayEmpty = () => { tray.replaceChildren(el('span', { class: 'rm-empty', text: s.trayEmpty })); };
  const drawTray = () => {
    if (!installed.size) return trayEmpty();
    tray.replaceChildren(...[...installed].map((k) => el('span', { class: `rm-run${offOn ? ' off' : ''}`, text: `${s[k]} · ${offOn ? s.stateOff : s.stateRun}` })));
  };

  // ── 權限表 ──
  const sheetTitle = el('h4', { class: 'rm-st', id: 'rm-st' });
  const sheet = el('div', { class: 'rm-sheet', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'rm-st', hidden: true }, [
    sheetTitle, el('p', { class: 'rm-lead', text: s.lead }),
    el('ul', { class: 'rm-perms' }, [
      el('li', {}, [el('b', { text: s.p1 }), el('span', { class: 'rm-files', text: s.files })]),
      el('li', {}, [el('b', { text: s.p2 })]), el('li', {}, [el('b', { text: s.p3 })])]),
    el('p', { class: 'rm-same', text: s.same }),
    el('div', { class: 'rm-act' }, [el('button', { class: 'rm-yes', type: 'button', text: s.allow, onclick: () => confirm() }), el('button', { class: 'rm-no', type: 'button', text: s.cancel, onclick: () => closeSheet(true) })])]);
  const body = el('div', { class: 'rm-body' }, [el('div', { class: 'rm-cap', text: s.galCap }), gallery]);
  function ask(k) {
    if (offOn) { api.say(s.offBlock); return; }
    pending = k; sheetTitle.textContent = fmt(s.sheetTitle, { name: s[k] });
    sheet.hidden = false; [...root.children].forEach((c) => { if (c !== sheet) c.inert = true; });
    sheet.querySelector('.rm-yes').focus({ preventScroll: true });
  }
  function closeSheet(cancel) {
    sheet.hidden = true; [...root.children].forEach((c) => { c.inert = false; });
    const k = pending; pending = null;
    if (cancel && k) { cards[k].querySelector('button').focus({ preventScroll: true }); api.say(fmt(s.cancelled, { name: s[k] })); }
    return k;
  }
  sheet.addEventListener('keydown', (e) => { if (e.key === 'Escape') { closeSheet(true); e.stopPropagation(); } });

  // ── 惡意小工具的示範（全是模擬）──
  const demo = el('div', { class: 'rm-demo', role: 'status', 'aria-live': 'polite', hidden: true });
  function runDemo() {
    demo.hidden = false; demo.replaceChildren(el('div', { class: 'rm-tag', text: s.demoTag }), el('div', { class: 'rm-dh', text: fmt(s.demoHead, { name: s.g2 }) }));
    const list = el('ul', { class: 'rm-dl' }); demo.append(list);
    ['f1', 'f2', 'f3'].forEach((f, i) => later(() => list.append(el('li', { text: fmt(s.demoRead, { f: s[f] }) })), 350 * (i + 1)));
    later(() => { demo.append(el('div', { class: 'rm-send', text: s.demoSend })); api.say(s.demoSay); }, 1500);
  }
  function confirm() {
    const k = closeSheet(false); if (!k) return;
    installed.add(k); cards[k].classList.add('done'); cards[k].querySelector('button').disabled = true;
    drawTray(); api.say(fmt(s.installed, { name: s[k] }));
    if (GADS.find((g) => g[0] === k)[1]) runDemo();
    fixBox.hidden = false;
    // 對話框關了、這張卡的按鈕也停用了：焦點交給下一個還能裝的，沒有就交給開關
    const nextBtn = [...root.querySelectorAll('.rm-card button:not([disabled])')][0];
    (nextBtn || fixBox.querySelector('button,[role="switch"]') || root).focus({ preventScroll: true });
  }

  // ── Fix it 開關與最後一步 ──
  const sw = el('button', { class: 'rm-sw', type: 'button', role: 'switch', 'aria-checked': 'false' }, [el('span', { class: 'rm-knob', 'aria-hidden': 'true' }), el('span', { class: 'rm-swl', text: s.fixLabel })]);
  const fixMsg = el('p', { class: 'rm-fixmsg', text: s.fixHint });
  const goWin8 = el('button', { class: 'rm-next', type: 'button', text: s.goWin8, hidden: true });
  const fixBox = el('div', { class: 'rm-fix' }, [el('div', { class: 'rm-cap', text: s.fixCap }), sw, fixMsg, goWin8]);
  fixBox.hidden = true;
  sw.addEventListener('click', () => {
    offOn = !offOn; sw.setAttribute('aria-checked', String(offOn)); root.classList.toggle('off', offOn);
    fixMsg.textContent = offOn ? s.fixOn : s.fixHint; goWin8.hidden = !offOn; drawTray();
    api.say(offOn ? s.fixOnSay : s.fixOffSay);
  });
  const gone = el('div', { class: 'rm-gone', role: 'status', hidden: true }, [el('div', { class: 'rm-big', text: s.goneBig }), el('p', { text: s.goneText })]);
  goWin8.addEventListener('click', () => {
    phase = 'gone'; root.classList.add('gone'); gone.hidden = false; body.hidden = fixBox.hidden = demo.hidden = true; tray.hidden = true;
    api.say(s.goneSay); gone.tabIndex = -1; gone.focus({ preventScroll: true });
  });

  const contrast = el('p', { class: 'rm-contrast', text: s.contrast });
  root.append(body, el('div', { class: 'rm-trayrow' }, [el('div', { class: 'rm-cap', text: s.trayCap }), tray]), demo, fixBox, gone, contrast, sheet);
  api.stage.append(root);
  trayEmpty();
  api.onReset(() => {
    timers.forEach(clearTimeout); timers = []; installed.clear(); offOn = false; phase = 'open'; pending = null;
    root.classList.remove('off', 'gone'); sw.setAttribute('aria-checked', 'false'); goWin8.hidden = true; fixMsg.textContent = s.fixHint;
    sheet.hidden = true; [...root.children].forEach((c) => { c.inert = false; }); body.hidden = false; tray.hidden = false; gone.hidden = true; demo.hidden = true; fixBox.hidden = true;
    Object.values(cards).forEach((c) => { c.classList.remove('done'); c.querySelector('button').disabled = false; });
    drawTray();
  });
});
