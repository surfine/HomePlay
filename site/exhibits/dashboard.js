// 02 · 2003 → 2005 Dashboard：一個鍵叫出一整層小工具，再按一次全部退下，底下的文件一字未動。
// 全部自己畫：錶面、計算機、天氣、便條紙都是原創造型與虛構城市；沒有原廠圖示、字型或截圖。
HX.register('dashboard', (api) => {
  const { el, s, fmt } = api;
  let up = 0, down = 0, on = false;
  const root = el('div', { class: 'db', tabindex: '0', role: 'group', 'aria-label': s.deskLabel });
  const p2 = (n) => String(n).padStart(2, '0');

  // ── 桌面：選單列＋一份文件 ──
  const count = el('span', { class: 'db-count', text: '' });
  const sumBtn = el('button', { class: 'db-sum', type: 'button', 'aria-pressed': 'false', 'aria-label': s.summonLabel, text: s.summon });
  const bar = el('div', { class: 'db-bar' }, [el('span', { class: 'db-brand', text: s.desk }), count, sumBtn]);
  const docText = el('textarea', { class: 'db-doctext', 'aria-label': s.docLabel, spellcheck: 'false' });
  docText.value = s.docText;
  const docWin = el('div', { class: 'db-doc' }, [el('div', { class: 'db-dtitle', text: s.doc }), docText]);
  const showCount = () => { count.textContent = fmt(s.counts, { a: up, b: down }); };

  // ── 那一層 ──
  const grid = el('div', { class: 'db-grid' });
  const layer = el('div', { class: 'db-layer', role: 'dialog', 'aria-label': s.layerLabel }, [grid]);
  layer.inert = true;
  const tray = el('div', { class: 'db-tray', hidden: true, role: 'group', 'aria-label': s.tray });
  const plus = el('button', { class: 'db-plus', type: 'button', 'aria-expanded': 'false', 'aria-label': s.add, text: '+' });
  const closeBtn = el('button', { class: 'db-close', type: 'button', text: s.dismiss });
  layer.append(el('div', { class: 'db-foot' }, [plus, tray, closeBtn]));

  // 選項鈕：一排互斥的按鈕，被選到的 aria-pressed=true
  function choice(label, opts, cur, pick) {
    const row = el('div', { class: 'db-opts', role: 'group', 'aria-label': label });
    const draw = (v) => [...row.children].forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.v === String(v))));
    opts.forEach(([v, t]) => row.append(el('button', { class: 'db-opt', type: 'button', 'data-v': v, text: t, onclick: () => { draw(v); pick(v); } })));
    draw(cur);
    return row;
  }
  // 一張小工具：正面、背面（i 翻過去，完成翻回來）
  function card(key, name, front, back, removable) {
    const i = el('button', { class: 'db-i', type: 'button', 'aria-label': fmt(s.flip, { name }), text: 'i' });
    const done = el('button', { class: 'db-done', type: 'button', text: s.done });
    const rm = removable ? el('button', { class: 'db-rm', type: 'button', text: s.remove, onclick: () => { w.remove(); sync(); api.say(fmt(s.removed, { name })); plus.focus({ preventScroll: true }); } }) : null;
    const fr = el('div', { class: 'db-face db-front' }, [el('div', { class: 'db-hd', text: name }), front, i]);
    const bk = el('div', { class: 'db-face db-back' }, [el('div', { class: 'db-hd', text: fmt(s.settings, { name }) }), back, rm, done]);
    const w = el('div', { class: `db-w db-${key}`, 'data-k': key }, [el('div', { class: 'db-flip' }, [fr, bk])]);
    bk.inert = true;
    const flip = (f) => { w.classList.toggle('flipped', f); fr.inert = f; bk.inert = !f; (f ? done : i).focus({ preventScroll: true }); };
    i.addEventListener('click', () => flip(true));
    done.addEventListener('click', () => flip(false));
    w.flipTo = flip;
    return w;
  }

  // 時鐘：指針用 CSS 變數轉；背面選 12 / 24 小時
  const clockBuild = () => {
    let h24 = true;
    const ticks = [...Array(12)].map((_, k) => `<line class="db-tk" x1="50" y1="7" x2="50" y2="${k % 3 ? 11 : 14}" transform="rotate(${k * 30} 50 50)"/>`).join('');
    const face = el('div', { class: 'db-clockface', 'aria-hidden': 'true', html: `<svg viewBox="0 0 100 100"><circle class="db-dial" cx="50" cy="50" r="46"/>${ticks}<g class="db-hh"><line x1="50" y1="50" x2="50" y2="28"/></g><g class="db-mh"><line x1="50" y1="50" x2="50" y2="17"/></g><g class="db-sh"><line x1="50" y1="56" x2="50" y2="14"/></g><circle class="db-pin" cx="50" cy="50" r="3"/></svg>` });
    const out = el('output', { class: 'db-digital', 'aria-live': 'off' });
    const tick = () => {
      const d = new Date(); const h = d.getHours(), m = d.getMinutes(), sec = d.getSeconds();
      face.querySelector('.db-hh').style.setProperty('--a', ((h % 12) + m / 60) * 30 + 'deg');
      face.querySelector('.db-mh').style.setProperty('--a', (m + sec / 60) * 6 + 'deg');
      face.querySelector('.db-sh').style.setProperty('--a', sec * 6 + 'deg');
      out.textContent = h24 ? `${p2(h)}:${p2(m)}` : `${h % 12 || 12}:${p2(m)} ${h < 12 ? s.am : s.pm}`;
    };
    const back = choice(s.timeFmt, [['24', s.h24], ['12', s.h12]], '24', (v) => { h24 = v === '24'; tick(); api.say(v === '24' ? s.h24on : s.h12on); });
    tick(); clockTick = tick;
    return card('clock', s.clock, el('div', { class: 'db-cbody' }, [face, out]), back, false);
  };
  let clockTick = () => {}, timer = 0;

  // 計算機
  const calcBuild = () => {
    let cur = '0', acc = null, op = null, fresh = true, r2 = false;
    const disp = el('output', { class: 'db-disp', text: '0' });
    const calc = (a, b, o) => ({ '+': a + b, '−': a - b, '×': a * b, '÷': b === 0 ? NaN : a / b })[o];
    const fn = (n) => (Number.isFinite(n) ? String(r2 ? +n.toFixed(2) : +n.toPrecision(9)) : 'Error');
    const press = (k) => {
      if (/^[0-9]$/.test(k)) { cur = fresh || cur === '0' ? k : (cur + k).slice(0, 9); fresh = false; }
      else if (k === '.') { if (fresh) { cur = '0.'; fresh = false; } else if (!cur.includes('.')) cur += '.'; }
      else if (k === 'C') { cur = '0'; acc = null; op = null; fresh = true; }
      else if (k === '=') { if (op != null && acc != null) { cur = fn(calc(acc, +cur, op)); acc = op = null; fresh = true; } }
      else { if (op != null && acc != null && !fresh) cur = fn(calc(acc, +cur, op)); acc = +cur; op = k; fresh = true; }
      disp.textContent = cur;
    };
    const keys = el('div', { class: 'db-keys' });
    ['7', '8', '9', '÷', '4', '5', '6', '×', '1', '2', '3', '−', 'C', '0', '=', '+'].forEach((k) => keys.append(el('button', { class: `db-key${/[÷×−+=]/.test(k) ? ' op' : ''}`, type: 'button', text: k, onclick: () => press(k) })));
    const back = choice(s.rounding, [['n', s.roundOff], ['y', s.roundOn]], 'n', (v) => { r2 = v === 'y'; api.say(r2 ? s.roundOnSay : s.roundOffSay); });
    return card('calc', s.calc, el('div', { class: 'db-cbody' }, [disp, keys]), back, false);
  };

  // 天氣：三個虛構的城市
  const weatherBuild = () => {
    const cities = [0, 1, 2].map((n) => ({ name: s['city' + n], t: s['temp' + n], c: ['sun', 'cloud', 'moon'][n], d: s['cond' + n] }));
    const ico = el('div', { class: 'db-ico', 'aria-hidden': 'true' });
    const nm = el('div', { class: 'db-city' }), tp = el('div', { class: 'db-temp' }), cd = el('div', { class: 'db-cond' });
    const show = (n) => { const c = cities[n]; ico.className = `db-ico ${c.c}`; nm.textContent = c.name; tp.textContent = c.t + '°'; cd.textContent = c.d; };
    show(0);
    const back = choice(s.city, cities.map((c, n) => [n, c.name]), 0, (n) => { show(+n); api.say(fmt(s.cityPicked, { city: cities[+n].name })); });
    return card('weather', s.weather, el('div', { class: 'db-wbody' }, [ico, nm, tp, cd]), back, false);
  };

  // 便條紙
  const noteBuild = () => {
    const ta = el('textarea', { class: 'db-notetext', 'aria-label': s.noteLabel, spellcheck: 'false' });
    ta.value = s.noteText;
    const w = card('note', s.note, ta, null, false);
    const back = choice(s.noteColor, [['y', s.cy], ['p', s.cp], ['g', s.cg]], 'y', (v) => { w.dataset.c = v; });
    w.querySelector('.db-back').insertBefore(back, w.querySelector('.db-done'));
    return w;
  };

  // 托盤裡的兩個額外小工具
  const diceBuild = () => {
    const face = el('output', { class: 'db-die', text: '1' });
    const roll = el('button', { class: 'db-act', type: 'button', text: s.roll, onclick: () => { const n = 1 + Math.floor(Math.random() * 6); face.textContent = n; api.say(fmt(s.rolled, { n })); } });
    return card('dice', s.dice, el('div', { class: 'db-cbody' }, [face, roll]), el('p', { class: 'db-hint', text: s.diceHint }), true);
  };
  const waterBuild = () => {
    let n = 0;
    const big = el('output', { class: 'db-die', text: '0' });
    const add = el('button', { class: 'db-act', type: 'button', text: s.glass, onclick: () => { big.textContent = ++n; api.say(fmt(s.glasses, { n })); } });
    return card('water', s.water, el('div', { class: 'db-cbody' }, [big, add]), el('p', { class: 'db-hint', text: s.waterHint }), true);
  };
  const EXTRA = { dice: diceBuild, water: waterBuild };
  Object.keys(EXTRA).forEach((k) => tray.append(el('button', { class: 'db-opt', type: 'button', 'data-k': k, text: s[k], onclick: () => addExtra(k) })));
  function addExtra(k) {
    const w = EXTRA[k](); grid.append(w); sync();
    w.querySelector('.db-i').focus({ preventScroll: true });
    api.say(fmt(s.added, { name: s[k] }));
  }
  function sync() { tray.querySelectorAll('button').forEach((b) => { b.disabled = !!grid.querySelector(`[data-k="${b.dataset.k}"]`); }); }

  [clockBuild(), calcBuild(), weatherBuild(), noteBuild()].forEach((w) => grid.append(w));

  // ── 叫出、收回 ──
  function setOn(v, quiet) {
    if (v === on) return;
    on = v; layer.inert = !v;
    layer.classList.toggle('on', v); root.classList.toggle('lit', v);
    sumBtn.setAttribute('aria-pressed', String(v));
    if (!v) { tray.hidden = true; plus.setAttribute('aria-expanded', 'false'); grid.querySelectorAll('.db-w.flipped').forEach((w) => w.flipTo(false)); }
    if (quiet) return;
    v ? up++ : down++;
    showCount();
    api.say(v ? fmt(s.summoned, { n: up }) : fmt(s.dismissed, { n: down }));
    (v ? layer.querySelector('.db-i') : docText).focus({ preventScroll: true });
  }
  const toggle = () => setOn(!on);
  sumBtn.addEventListener('click', toggle);
  closeBtn.addEventListener('click', () => setOn(false));
  plus.addEventListener('click', () => { tray.hidden = !tray.hidden; plus.setAttribute('aria-expanded', String(!tray.hidden)); if (!tray.hidden) sync(); });
  // 點到小工具以外的暗處，也算收回（Dashboard 就是這樣）
  layer.addEventListener('click', (e) => { if (e.target === layer || e.target === grid) setOn(false); });
  root.addEventListener('keydown', (e) => {
    if (e.key === 'F12') { toggle(); e.preventDefault(); }
    else if (e.key === 'Escape' && on) { setOn(false); e.preventDefault(); }
  });

  root.append(bar, docWin, layer);
  api.stage.append(root);
  showCount(); sync();
  api.whileVisible(() => { clearInterval(timer); timer = setInterval(() => clockTick(), 1000); clockTick(); }, () => clearInterval(timer));
  api.onReset(() => {
    setOn(false, true); up = down = 0; showCount(); docText.value = s.docText;
    // 四個預設小工具整組重建：便條紙的字與顏色、城市、12／24 小時、計算機都回到一開始；托盤加的也一起拿掉
    grid.replaceChildren(clockBuild(), calcBuild(), weatherBuild(), noteBuild()); sync();
  });
});
