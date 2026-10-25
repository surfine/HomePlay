// 04 · 1997 Active Desktop：桌布是一頁網頁。股票、天氣圖、頻道列都會自己動，右邊的帳單即時累加。
// 全部自己畫（CSS 斜面、內嵌 SVG）；股票代號、頻道、城市都是虛構的。流量是模擬的 56k 撥接，不是真的下載。
HX.register('active', (api) => {
  const { el, s, fmt } = api;
  const TICKERS = s.tickers.split(',');
  const CHANNELS = s.channels.split('|');
  const KB_TICK = 1.1, KB_WEATHER = 6, KB_CHANNEL = 9, MODEM = 5; // 每秒約 5 KB 是 56k 數據機的實際上限
  let on = true, kb = 0, busy = 0, secs = 0, sinceW = 0, timer = 0;
  const subs = new Set();
  const price = TICKERS.map((_, i) => 20 + i * 13.37);
  const prev = price.slice();
  const f1 = (n) => n.toFixed(1);

  // ── 控制列：Active Desktop 開關 ──
  const sw = el('button', { class: 'ad-switch', type: 'button', role: 'switch', 'aria-checked': 'true', 'aria-label': s.toggle });
  const swText = el('span', { class: 'ad-swtext' });
  sw.append(el('span', { class: 'ad-knob', 'aria-hidden': 'true' }), swText);
  const bar = el('div', { class: 'ad-bar' }, [el('span', { class: 'ad-bartitle', text: s.display }), sw]);

  // ── 桌面：股票、天氣圖、頻道列 ──
  const rows = TICKERS.map((t) => el('li', { class: 'ad-row' }, [el('b', { text: t }), el('span', { class: 'ad-px' }), el('span', { class: 'ad-chg' })]));
  const ticker = el('div', { class: 'ad-item ad-ticker', role: 'group', 'aria-label': s.stocks }, [el('div', { class: 'ad-itemtitle', text: s.stocks }), el('ul', { class: 'ad-list' }, rows)]);
  const cloud = '<g class="ad-cloud"><ellipse cx="38" cy="22" rx="20" ry="9"/><ellipse cx="52" cy="17" rx="14" ry="9"/></g>';
  const map = el('div', { class: 'ad-item ad-weather', role: 'group', 'aria-label': s.weather }, [
    el('div', { class: 'ad-itemtitle', text: s.weather }),
    el('div', { class: 'ad-mapwrap', html: `<svg viewBox="0 0 160 90" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><rect class="ad-sea" width="160" height="90"/><path class="ad-land" d="M0 90V52Q22 36 46 46T92 40Q124 30 160 50V90Z"/><path class="ad-front" d="M20 8Q60 30 40 60T70 90" fill="none"/>${cloud}<text class="ad-city" x="60" y="60">${s.city}</text></svg>` }),
    el('div', { class: 'ad-temp', 'aria-hidden': 'true' }),
  ]);
  const cloudEl = map.querySelector('.ad-cloud');
  const temp = map.querySelector('.ad-temp');
  const chBtns = CHANNELS.map((c, i) => {
    const b = el('button', { class: 'ad-ch', type: 'button', 'aria-pressed': 'false' }, [el('span', { class: 'ad-chdot', 'aria-hidden': 'true' }), el('span', { text: c })]);
    b.addEventListener('click', () => toggleCh(i));
    return b;
  });
  const chbar = el('div', { class: 'ad-item ad-chbar', role: 'group', 'aria-label': s.channelBar }, [el('div', { class: 'ad-itemtitle', text: s.channelBar }), el('div', { class: 'ad-chlist', tabindex: '0', role: 'group', 'aria-label': s.channelList }, chBtns)]);
  const picture = el('div', { class: 'ad-picture', 'aria-hidden': 'true', html: '<svg viewBox="0 0 160 90" preserveAspectRatio="xMidYMid slice"><circle cx="118" cy="26" r="11"/><path d="M0 90V58Q30 40 60 56T120 52Q145 46 160 56V90Z"/></svg>' });
  const desk = el('div', { class: 'ad-desk' }, [ticker, map, chbar, picture]);

  // ── 帳單 ──
  const cost = (k) => el('div', { class: 'ad-cost' }, [el('output', { class: 'ad-val', 'aria-label': s[k], 'aria-live': 'off' }), el('span', { class: 'ad-lab', text: s[k] })]);
  const cKb = cost('kb'), cBusy = cost('busy'), cMove = cost('moving');
  const bill = el('div', { class: 'ad-bill', role: 'group', 'aria-label': s.bill }, [cKb, cBusy, cMove]);
  const meter = el('div', { class: 'ad-meter', 'aria-hidden': 'true' }, [el('i', { class: 'ad-fill' })]);
  const root = el('div', { class: 'ad ad-on' }, [bar, desk, bill, meter]);
  api.stage.append(root);

  const moving = () => (on ? TICKERS.length + 1 + subs.size : 0);
  function paint() {
    cKb.firstChild.textContent = fmt(s.kbVal, { n: f1(kb) });
    cBusy.firstChild.textContent = fmt(s.busyVal, { n: Math.round(busy) });
    cMove.firstChild.textContent = String(moving());
    meter.querySelector('.ad-fill').style.setProperty('--p', Math.min(1, secs ? busy / secs : 0).toFixed(2));
    swText.textContent = on ? s.on : s.off;
    sw.setAttribute('aria-checked', String(on));
    root.classList.toggle('ad-on', on);
  }
  function drawTickers(flash) {
    rows.forEach((r, i) => {
      const d = price[i] - prev[i];
      r.querySelector('.ad-px').textContent = price[i].toFixed(2);
      const c = r.querySelector('.ad-chg');
      c.textContent = (d >= 0 ? '▲ ' : '▼ ') + Math.abs(d).toFixed(2);
      c.className = `ad-chg ${d >= 0 ? 'up' : 'dn'}`;
      if (flash && !api.reduced) { r.classList.remove('ad-flash'); void r.offsetWidth; r.classList.add('ad-flash'); }
    });
  }
  function tick() {
    if (!on) return;
    secs++;
    let add = KB_TICK;
    price.forEach((p, i) => { prev[i] = p; price[i] = Math.max(1, p + (Math.random() - 0.5) * 2.4); });
    drawTickers(true);
    if (++sinceW >= 5) {
      sinceW = 0; add += KB_WEATHER;
      cloudEl.style.setProperty('--wx', String(Math.round(Math.random() * 70 - 20)));
      temp.textContent = fmt(s.temp, { n: 18 + Math.floor(Math.random() * 6) });
    }
    if (secs % 3 === 0) add += KB_CHANNEL * subs.size;
    kb += add;
    busy += Math.min(1, add / MODEM);
    paint();
  }
  function toggleCh(i) {
    if (subs.has(i)) subs.delete(i); else subs.add(i);
    chBtns[i].setAttribute('aria-pressed', String(subs.has(i)));
    api.say(fmt(subs.has(i) ? s.subbed : s.unsubbed, { name: CHANNELS[i], n: subs.size }));
    paint();
  }
  function setOn(v) {
    on = v;
    paint();
    api.say(fmt(on ? s.sayOn : s.sayOff, { kb: f1(kb), busy: Math.round(busy), n: subs.size }));
  }
  sw.addEventListener('click', () => setOn(!on));
  api.whileVisible(() => { clearInterval(timer); timer = setInterval(tick, 1000); }, () => clearInterval(timer));
  function reset() {
    on = true; kb = 0; busy = 0; secs = 0; sinceW = 0; subs.clear();
    chBtns.forEach((b) => b.setAttribute('aria-pressed', 'false'));
    price.forEach((_, i) => { price[i] = 20 + i * 13.37; prev[i] = price[i]; });
    drawTickers(false); temp.textContent = fmt(s.temp, { n: 21 }); paint();
  }
  api.onReset(reset);
  reset();
});
