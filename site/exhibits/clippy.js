// 05 · 1997 Office 小幫手：一封空白的信，一個我們自己畫的墨點助手。
// 模式 A「1997」：猜到你在寫信就跳出來蓋在字上；模式 B「等你問」：只在角落亮一個小點，按「問」才開口。
// 焦點永遠留在文字欄；只用 api.say 溫和地通知。助手是原創角色，不是任何 Microsoft 角色。
HX.register('clippy', (api) => {
  const { el, s, fmt } = api;
  const GREET = /^\s*(親愛的|亲爱的|dear\b|敬啟者|敬启者)/i;
  const AFTER = 25; // 打滿這麼多字（或開頭是稱呼）就算「猜到你在寫信」
  const stat = { A: { int: 0, right: 0 }, B: { int: 0, right: 0 } };
  let mode = 'A', typed = 0, last = '', shown = false, pending = false, greeted = false, tip = false;

  const ta = el('textarea', { class: 'cl-text', 'aria-label': s.letter, placeholder: s.placeholder, spellcheck: 'false', rows: '7' });
  const blot = '<svg viewBox="0 0 64 64" aria-hidden="true"><path class="cl-body" d="M32 6c9 0 12 8 19 12 8 5 9 14 5 22-3 7-1 14-8 17-8 4-14-1-22 1-9 2-17-3-19-12-2-9 4-13 3-22C8 14 20 6 32 6Z"/><path class="cl-sheen" d="M18 18c3-5 8-8 13-8"/><circle class="cl-eye" cx="24" cy="30" r="4"/><circle class="cl-eye" cx="40" cy="30" r="4"/><circle class="cl-glint" cx="25.2" cy="28.8" r="1.2"/><circle class="cl-glint" cx="41.2" cy="28.8" r="1.2"/><path class="cl-drip" d="M30 56c0 4 4 4 4 0v-3h-4Z"/></svg>';
  const dot = el('span', { class: 'cl-dot', 'aria-hidden': 'true', hidden: true });
  const body = el('div', { class: 'cl-blot', html: blot }, [dot]);
  const bubbleText = el('p', { class: 'cl-q' });
  const yes = el('button', { class: 'cl-btn', type: 'button', text: s.yes });
  const no = el('button', { class: 'cl-btn', type: 'button', text: s.no });
  const bubble = el('div', { class: 'cl-bubble', role: 'group', 'aria-label': s.bubble, hidden: true }, [bubbleText, el('div', { class: 'cl-acts' }, [yes, no])]);
  const ask = el('button', { class: 'cl-ask', type: 'button' });
  const mkSeg = (m) => el('button', { class: 'cl-seg', type: 'button', 'data-m': m, text: s['mode' + m], 'aria-pressed': String(m === mode) });
  const segs = [mkSeg('A'), mkSeg('B')];
  const val = (k) => el('output', { class: 'cl-n', 'aria-label': s[k] });
  const nInt = val('interrupted'), nRight = val('guessedRight');
  const counters = el('div', { class: 'cl-counts' }, [el('span', {}, [s.interrupted + ' ', nInt]), el('span', {}, [s.guessedRight + ' ', nRight])]);
  const tools = el('div', { class: 'cl-tools' }, [el('div', { class: 'cl-segs', role: 'group', 'aria-label': s.modes }, segs), counters]);
  const paper = el('div', { class: 'cl-paper' }, [ta]);
  const corner = el('div', { class: 'cl-corner' }, [el('div', { class: 'cl-hint' }), ask, body, bubble]);
  const root = el('div', { class: 'cl cl-modeA' }, [el('div', { class: 'cl-title', text: s.window }), tools, paper, corner]);
  api.stage.append(root);
  const hint = corner.querySelector('.cl-hint');

  const isLetter = () => GREET.test(ta.value);
  function paint() {
    root.classList.toggle('cl-modeA', mode === 'A'); root.classList.toggle('cl-modeB', mode === 'B');
    root.classList.toggle('cl-pop', shown && mode === 'A');
    segs.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.m === mode)));
    nInt.textContent = stat[mode].int; nRight.textContent = stat[mode].right;
    api.root.dataset.interruptions = stat.A.int; // 終章 homeplay 讀這個數字，拿來和 ClioTalk 的 0 次比
    dot.hidden = !(mode === 'B' && pending && !shown);
    ask.hidden = mode === 'A';
    ask.textContent = s.ask;
    ask.setAttribute('aria-label', pending ? fmt(s.askPending, { key: s.key }) : fmt(s.askNone, { key: s.key }));
    hint.textContent = mode === 'B' ? fmt(s.hintB, { key: s.key }) : s.hintA;
    bubble.hidden = !shown;
    const home = mode === 'A' ? paper : corner; if (bubble.parentNode !== home) home.append(bubble); hint.hidden = shown && mode === 'B';
    yes.hidden = tip; no.textContent = tip ? s.close : s.no;
    bubbleText.textContent = tip ? s.tip : s.question;
  }
  function show() {
    shown = true; tip = false; pending = false;
    if (mode === 'A') stat.A.int++; // 你自己問的不算打擾
    if (isLetter()) stat[mode].right++;
    paint();
    api.say(mode === 'A' ? fmt(s.popped, { n: stat.A.int, right: stat.A.right }) : fmt(s.asked, { right: isLetter() ? s.rightYes : s.rightNo }));
  }
  function hide(why) {
    if (!shown) return;
    shown = false; typed = 0; pending = false; paint();
    if (why) api.say(s.dismissed);
  }
  // 猜測：開頭是稱呼，或打滿 25 個字。A 直接跳出來；B 只亮點
  function guess() {
    if (shown) return;
    const hit = (!greeted && isLetter()) || typed >= AFTER;
    if (!hit) return;
    if (isLetter()) greeted = true;
    if (mode === 'A') show(); else { pending = true; paint(); }
  }
  ta.addEventListener('input', () => {
    const grow = ta.value.length - last.length; last = ta.value;
    if (grow > 0) typed += grow;
    if (!ta.value.trim()) { typed = 0; greeted = false; pending = false; hide(false); }
    guess(); if (mode === 'B') paint();
  });
  const doAsk = () => { if (mode === 'B' && !shown) show(); };
  ask.addEventListener('click', doAsk);
  ta.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && shown) { hide(true); e.stopPropagation(); }
    if (e.altKey && e.code === 'Slash') { e.preventDefault(); doAsk(); }
  });
  yes.addEventListener('click', () => { tip = true; paint(); api.say(s.tip); ta.focus({ preventScroll: true }); });
  no.addEventListener('click', () => { hide(true); ta.focus({ preventScroll: true }); });
  segs.forEach((b) => b.addEventListener('click', () => {
    mode = b.dataset.m; shown = false; pending = false; typed = 0; paint();
    api.say(fmt(mode === 'A' ? s.sayA : s.sayB, { key: s.key }));
  }));
  api.onReset(() => {
    ta.value = ''; last = ''; typed = 0; shown = false; pending = false; greeted = false; tip = false; mode = 'A';
    stat.A = { int: 0, right: 0 }; stat.B = { int: 0, right: 0 }; paint();
  });
  paint();
});
