// 01 · 1984 桌面附件：一張重畫的 1 位元桌面，四個真的能用的附件。
// 全部自己畫：選單、標題欄條紋、灰階網點都是 CSS；沒有原廠圖示、字型或截圖。
// 座標以「邏輯像素」記（桌面寬 512，窄螢幕 360），寫進 CSS 變數 --x/--y，由 desk.css 乘上 --u 換成實際尺寸。
HX.register('desk', (api) => {
  const { el, s, fmt } = api;
  const NAMES = ['calc', 'clock', 'note', 'puzzle'];
  const used = new Set();
  let z = 10;
  let clockTimer = 0;
  const root = el('div', { class: 'dk' });
  const narrow = () => root.clientWidth < 480;
  const W = () => (narrow() ? 360 : 512);
  const H = () => (narrow() ? 620 : 342);

  // ── 選單列 ──
  const menuBtn = el('button', { class: 'dk-mtitle dk-mark', type: 'button', 'aria-haspopup': 'menu', 'aria-expanded': 'false', 'aria-label': s.menuLabel, text: '✦' });
  const menu = el('div', { class: 'dk-menu', role: 'menu', hidden: true });
  NAMES.forEach((n) => menu.append(el('button', { class: 'dk-mitem', type: 'button', role: 'menuitem', 'data-da': n, text: s[n] })));
  const bar = el('div', { class: 'dk-bar' }, [menuBtn, el('span', { class: 'dk-mtitle', text: s.file }), el('span', { class: 'dk-mtitle', text: s.edit }), menu]);
  const openMenu = (on) => { menu.hidden = !on; menuBtn.setAttribute('aria-expanded', String(on)); menuBtn.classList.toggle('on', on); if (on) menu.querySelector('button').focus(); };
  menuBtn.addEventListener('click', () => openMenu(menu.hidden));
  menu.addEventListener('click', (e) => { const b = e.target.closest('[data-da]'); if (b) { openMenu(false); open(b.dataset.da); } });
  menu.addEventListener('keydown', (e) => {
    const items = [...menu.querySelectorAll('button')]; const i = items.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') { items[(i + 1) % items.length].focus(); e.preventDefault(); }
    if (e.key === 'ArrowUp') { items[(i + items.length - 1) % items.length].focus(); e.preventDefault(); }
    if (e.key === 'Escape') { openMenu(false); menuBtn.focus(); e.stopPropagation(); }
  });
  root.addEventListener('pointerdown', (e) => { if (!menu.hidden && !e.target.closest('.dk-menu,.dk-mark')) openMenu(false); });

  // ── 背景那份文件：你手上的事 ──
  const docText = el('textarea', { class: 'dk-doctext', 'aria-label': s.docLabel, spellcheck: 'false' });
  docText.value = s.docText + ' ';
  const docWin = el('div', { class: 'dk-win dk-doc' }, [el('div', { class: 'dk-title' }, [el('span', { class: 'dk-tname', text: s.doc })]), docText]);

  // ── 附件視窗 ──
  const wins = {};
  const place = (w, x, y) => {
    const maxX = W() - w.offsetWidth / u(); const maxY = H() - w.offsetHeight / u();
    w.dataset.x = Math.max(0, Math.min(maxX, x)); w.dataset.y = Math.max(20, Math.min(maxY, y));
    w.style.setProperty('--x', w.dataset.x); w.style.setProperty('--y', w.dataset.y);
  };
  const u = () => root.clientWidth / W();
  const front = (w) => { w.style.setProperty('--z', ++z); Object.values(wins).forEach((o) => o.classList.toggle('front', o === w)); };
  const START = { wide: { calc: [36, 40], clock: [330, 34], note: [176, 120], puzzle: [350, 150] }, narrow: { calc: [12, 250], clock: [196, 244], note: [30, 480], puzzle: [196, 314] } };

  function make(n) {
    const closeBtn = el('button', { class: 'dk-close', type: 'button', 'aria-label': fmt(s.close, { name: s[n] }) });
    const title = el('div', { class: 'dk-title' }, [closeBtn, el('span', { class: 'dk-tname', text: s[n] })]);
    const body = el('div', { class: 'dk-body' });
    const w = el('div', { role: 'dialog', class: `dk-win dk-da dk-${n}`, 'aria-label': s[n], tabindex: '-1' }, [title, body]);
    closeBtn.addEventListener('click', () => close(n));
    w.addEventListener('pointerdown', () => front(w));
    w.addEventListener('keydown', (e) => { if (e.key === 'Escape') { close(n); e.stopPropagation(); } });
    // 拖標題欄移動（指標事件，滑鼠、觸控、筆都一樣）
    title.addEventListener('pointerdown', (e) => {
      if (e.target === closeBtn) return;
      const k = u(); const sx = e.clientX, sy = e.clientY, ox = +w.dataset.x, oy = +w.dataset.y;
      title.setPointerCapture(e.pointerId);
      const move = (m) => place(w, ox + (m.clientX - sx) / k, oy + (m.clientY - sy) / k);
      const up = () => { title.removeEventListener('pointermove', move); title.removeEventListener('pointerup', up); title.removeEventListener('pointercancel', up); };
      title.addEventListener('pointermove', move); title.addEventListener('pointerup', up); title.addEventListener('pointercancel', up);
      e.preventDefault();
    });
    ({ calc: buildCalc, clock: buildClock, note: buildNote, puzzle: buildPuzzle })[n](body);
    return w;
  }
  function open(n) {
    let w = wins[n];
    if (!w) { w = wins[n] = make(n); root.append(w); }
    w.hidden = false;
    const [x, y] = START[narrow() ? 'narrow' : 'wide'][n];
    if (w.dataset.x == null) place(w, x, y); else place(w, +w.dataset.x, +w.dataset.y);
    front(w);
    used.add(n);
    if (n === 'clock') tick();
    api.say(used.size === 4 ? s.all : fmt(s.opened, { name: s[n], n: used.size }));
    (w.querySelector('.dk-focus') || w).focus({ preventScroll: true });
  }
  function close(n) {
    const w = wins[n]; if (!w || w.hidden) return;
    w.hidden = true;
    api.say(used.size === 4 ? s.all : fmt(s.closed, { name: s[n] }));
    menuBtn.focus({ preventScroll: true });
  }

  // 計算機：四則運算，照當年的單行顯示
  function buildCalc(body) {
    let cur = '0', acc = null, op = null, fresh = true;
    const disp = el('output', { class: 'dk-disp', 'aria-live': 'off', text: '0' });
    const show = (v) => { disp.textContent = v; disp.setAttribute('aria-label', fmt(s.display, { v })); };
    const calc = (a, b, o) => ({ '+': a + b, '−': a - b, '×': a * b, '÷': b === 0 ? NaN : a / b })[o];
    const fmtN = (n) => (Number.isFinite(n) ? String(+n.toPrecision(10)) : 'Error');
    const press = (k) => {
      if (/^[0-9]$/.test(k)) { cur = fresh || cur === '0' ? k : (cur + k).slice(0, 12); fresh = false; }
      else if (k === '.') { if (fresh) { cur = '0.'; fresh = false; } else if (!cur.includes('.')) cur += '.'; }
      else if (k === 'C') { cur = '0'; acc = null; op = null; fresh = true; }
      else if (k === '=') { if (op != null && acc != null) { cur = fmtN(calc(acc, +cur, op)); acc = null; op = null; fresh = true; } }
      else { if (op != null && acc != null && !fresh) cur = fmtN(calc(acc, +cur, op)); acc = +cur; op = k; fresh = true; }
      show(cur);
    };
    const keys = el('div', { class: 'dk-keys' });
    ['C', '=', '÷', '×', '7', '8', '9', '−', '4', '5', '6', '+', '1', '2', '3', '.', '0'].forEach((k, i) => keys.append(el('button', { class: `dk-key${k === '0' ? ' wide' : ''}${i === 0 ? ' dk-focus' : ''}`, type: 'button', text: k, onclick: () => press(k) })));
    body.append(disp, keys);
    body.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return; // 系統快捷鍵（拷貝、切分頁、縮放）照常
      if (e.key === 'Enter' && e.target.tagName === 'BUTTON') return; // 焦點在按鍵上時，Enter 就是按那顆鍵
      const map = { '/': '÷', '*': '×', '-': '−', '+': '+', Enter: '=', '=': '=', Backspace: 'C', c: 'C', '.': '.' };
      const k = /^[0-9]$/.test(e.key) ? e.key : map[e.key]; if (k) { press(k); e.preventDefault(); }
    });
    api.onReset(() => press('C'));
  }
  // 鬧鐘：現在時間，只在看得到、而且開著時走
  function buildClock(body) { body.append(el('div', { class: 'dk-time', role: 'timer', 'aria-live': 'off' })); }
  function tick() {
    const t = wins.clock && wins.clock.querySelector('.dk-time'); if (!t) return;
    const d = new Date(); const p = (n) => String(n).padStart(2, '0');
    t.textContent = `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }
  api.whileVisible(() => { clearInterval(clockTimer); clockTimer = setInterval(tick, 1000); tick(); }, () => clearInterval(clockTimer));
  // 記事本：關掉再打開，字還在
  function buildNote(body) {
    const ta = el('textarea', { class: 'dk-notetext dk-focus', 'aria-label': s.noteLabel, spellcheck: 'false' });
    ta.value = s.noteText;
    body.append(ta, el('div', { class: 'dk-dog', 'aria-hidden': 'true' }));
  }
  // 拼圖：4 × 4 數字滑塊，從解好的盤面隨機走 120 步打亂（一定解得開）
  function buildPuzzle(body) {
    const grid = el('div', { class: 'dk-grid', role: 'group', 'aria-label': s.puzzle });
    let cells = [], focusAt = 0; // 一次只有一塊在 Tab 順序裡（roving tabindex），方向鍵推動拼圖
    const solvedArr = [...Array(15)].map((_, i) => i + 1).concat(0);
    const render = () => {
      grid.replaceChildren(...cells.map((n, i) => el('button', { class: `dk-tile${n ? '' : ' blank'}${i === 0 ? ' dk-focus' : ''}`, type: 'button', 'aria-label': n ? fmt(s.tile, { n }) : s.blank, text: n || '', 'data-i': i, tabindex: i === focusAt ? '0' : '-1' })));
    };
    const nb = (i) => [i - 4, i + 4, i % 4 ? i - 1 : -1, i % 4 < 3 ? i + 1 : -1].filter((j) => j >= 0 && j < 16);
    const slide = (i) => {
      const b = cells.indexOf(0); if (!nb(b).includes(i)) return false;
      [cells[b], cells[i]] = [cells[i], cells[b]]; focusAt = b; render();
      grid.querySelector(`[data-i="${b}"]`).focus({ preventScroll: true });
      if (cells.every((n, k) => n === solvedArr[k])) api.say(s.solved);
      return true;
    };
    const shuffle = () => {
      cells = solvedArr.slice(); let prev = -1;
      for (let k = 0; k < 120; k++) { const b = cells.indexOf(0); const opts = nb(b).filter((j) => j !== prev); const j = opts[Math.floor(Math.random() * opts.length)]; [cells[b], cells[j]] = [cells[j], cells[b]]; prev = b; }
      render();
    };
    grid.addEventListener('click', (e) => { const t = e.target.closest('.dk-tile'); if (t) slide(+t.dataset.i); });
    // 方向鍵：把空格旁邊的那一塊推進空格（↑ 把空格下面那塊往上推）
    grid.addEventListener('keydown', (e) => {
      const b = cells.indexOf(0); const m = { ArrowUp: b + 4, ArrowDown: b - 4, ArrowLeft: b % 4 < 3 ? b + 1 : -1, ArrowRight: b % 4 ? b - 1 : -1 }[e.key];
      if (m != null) { if (m >= 0 && m < 16) slide(m); e.preventDefault(); }
    });
    shuffle();
    body.append(grid);
    api.onReset(shuffle);
  }

  root.append(bar, docWin);
  api.stage.append(root);
  root.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    const top = Object.entries(wins).filter(([, w]) => !w.hidden).sort((a, b) => b[1].style.getPropertyValue('--z') - a[1].style.getPropertyValue('--z'))[0];
    if (top) close(top[0]);
  });
  // 視窗大小變了（轉成直式）就把附件放回範圍內
  new ResizeObserver(() => Object.values(wins).forEach((w) => !w.hidden && place(w, +w.dataset.x, +w.dataset.y))).observe(root);
  api.onReset(() => {
    Object.values(wins).forEach((w) => { w.hidden = true; delete w.dataset.x; });
    used.clear(); docText.value = s.docText + ' ';
    const note = wins.note && wins.note.querySelector('textarea'); if (note) note.value = s.noteText;
  });
});
