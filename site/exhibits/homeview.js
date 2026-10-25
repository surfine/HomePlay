// 11 · 2026 HomeView：不畫 Apple 的硬體，用 HomePlay 自己的錶面渲染圖做輪播；
// 旁邊三位虛構的家人，選了誰，主畫面那排小工具就換成誰的（HIG：每位登記的家人有自己的主畫面和小工具）。
// 渲染圖路徑與寬高寫在 strings.json（每種語言一套圖，尺寸差幾個像素）。
HX.register('homeview', (api) => {
  const { el, s, fmt } = api;
  const faces = s.faces || [];
  const T = faces.length;
  const people = s.people || [];
  let i = 0, who = 0, told = false;
  const seen = new Set([0]);
  let switchedOnce = false;
  const root = el('div', { class: 'hv' });

  // ── 錶面輪播 ──
  const track = el('div', { class: 'hv-track' });
  const slides = faces.map(([id, name], k) => {
    const img = el('img', { class: 'hv-img', src: `${s.renders}style-${id}.webp`, width: s.rw, height: s.rh, alt: fmt(s.alt, { name }), loading: k < 2 ? 'eager' : 'lazy', decoding: 'async', draggable: 'false' });
    const slide = el('div', { class: 'hv-slide', role: 'group', 'aria-roledescription': 'slide', 'aria-label': fmt(s.slide, { n: k + 1, t: T, name }) }, [img]);
    track.append(slide);
    return { slide, img };
  });
  const view = el('div', { class: 'hv-view', tabindex: '0', role: 'region', 'aria-roledescription': 'carousel', 'aria-label': s.carousel }, [track]);
  const prev = el('button', { class: 'hv-arrow hv-prev', type: 'button', 'aria-label': s.prev, html: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M10 3 5 8l5 5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>' });
  const next = el('button', { class: 'hv-arrow hv-next', type: 'button', 'aria-label': s.next, html: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="m6 3 5 5-5 5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>' });
  const name = el('p', { class: 'hv-name', 'aria-hidden': 'true' });
  const dots = el('div', { class: 'hv-dots' });
  const dotBtns = faces.map(([, n], k) => {
    const b = el('button', { class: 'hv-dot', type: 'button', 'aria-label': fmt(s.dot, { n: k + 1, name: n }), onclick: () => go(k) });
    dots.append(b);
    return b;
  });
  const caption = el('p', { class: 'hv-cap', text: s.caption });
  const stage = el('div', { class: 'hv-faces' }, [el('div', { class: 'hv-frame' }, [view, prev, next]), name, dots, caption]);

  function render() {
    track.style.setProperty('--i', i);
    slides.forEach(({ slide, img }, k) => {
      const on = k === i;
      slide.setAttribute('aria-hidden', String(!on));
      slide.classList.toggle('on', on);
      // 鄰近的先載好，滑過去不會是空的
      if (Math.abs(k - i) <= 1 && img.loading === 'lazy') img.loading = 'eager';
    });
    dotBtns.forEach((b, k) => { b.classList.toggle('on', k === i); if (k === i) b.setAttribute('aria-current', 'true'); else b.removeAttribute('aria-current'); });
    name.textContent = faces[i] ? faces[i][1] : '';
  }
  function go(k, quiet) {
    i = (k + T) % T;
    seen.add(i);
    render();
    if (!quiet) report(fmt(s.seenFace, { n: i + 1, name: faces[i][1] }));
  }
  prev.addEventListener('click', () => go(i - 1));
  next.addEventListener('click', () => go(i + 1));
  view.addEventListener('keydown', (e) => {
    const m = { ArrowLeft: -1, ArrowRight: 1 }[e.key];
    if (m) { go(i + m); e.preventDefault(); }
    if (e.key === 'Home') { go(0); e.preventDefault(); }
    if (e.key === 'End') { go(T - 1); e.preventDefault(); }
  });

  // 拖曳／滑動：指標事件，跟手；放開時超過四分之一寬就換一張
  let drag = null;
  view.addEventListener('pointerdown', (e) => {
    if (e.button) return;
    drag = { x: e.clientX, y: e.clientY, w: view.clientWidth, dx: 0, on: false };
    view.setPointerCapture(e.pointerId);
  });
  view.addEventListener('pointermove', (e) => {
    if (!drag) return;
    drag.dx = e.clientX - drag.x;
    if (!drag.on && Math.abs(drag.dx) > 6 && Math.abs(drag.dx) > Math.abs(e.clientY - drag.y)) { drag.on = true; root.classList.add('hv-drag'); }
    if (drag.on) track.style.setProperty('--dx', `${drag.dx}px`);
  });
  const end = () => {
    if (!drag) return;
    const { dx, w, on } = drag; drag = null;
    root.classList.remove('hv-drag');
    track.style.setProperty('--dx', '0px');
    if (on && Math.abs(dx) > w * 0.22) go(i + (dx < 0 ? 1 : -1));
  };
  view.addEventListener('pointerup', end);
  view.addEventListener('pointercancel', end);

  // ── 家裡的人：單選，方向鍵切換 ──
  const group = el('div', { class: 'hv-people', role: 'radiogroup', 'aria-label': s.household });
  const pBtns = people.map((p, k) => {
    const b = el('button', { class: `hv-person hv-p-${p.id}`, type: 'button', role: 'radio', 'aria-label': p.name, onclick: () => pick(k) }, [
      el('span', { class: 'hv-avatar', 'aria-hidden': 'true', text: p.initial }),
      el('span', { class: 'hv-pname', 'aria-hidden': 'true', text: p.name }),
    ]);
    group.append(b);
    return b;
  });
  group.addEventListener('keydown', (e) => {
    const m = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 }[e.key];
    if (!m) return;
    pick((who + m + people.length) % people.length);
    pBtns[who].focus();
    e.preventDefault();
  });
  const homeTitle = el('p', { class: 'hv-home' });
  const chips = el('div', { class: 'hv-chips', role: 'list' });
  const lesson = el('div', { class: 'hv-lesson', hidden: true }, [el('p', { class: 'hv-label', text: s.lessonLabel }), el('p', { class: 'hv-ltext', text: s.lesson })]);
  const home = el('div', { class: 'hv-house' }, [el('p', { class: 'hv-label', text: s.household }), group, homeTitle, chips, lesson]);

  function renderPerson() {
    const p = people[who]; if (!p) return;
    pBtns.forEach((b, k) => { b.setAttribute('aria-checked', String(k === who)); b.tabIndex = k === who ? 0 : -1; });
    homeTitle.textContent = fmt(s.homeOf, { name: p.name });
    chips.className = `hv-chips hv-c-${p.id}`;
    chips.replaceChildren(...p.chips.map(([label, big, small]) => el('div', { class: 'hv-chip', role: 'listitem' }, [
      el('span', { class: 'hv-clabel', text: label }), el('span', { class: 'hv-cbig', text: big }), el('span', { class: 'hv-csmall', text: small }),
    ])));
    // 換人時小工具輕輕浮上來（減少動態效果時直接換）
    if (!api.reduced) { chips.classList.remove('hv-in'); void chips.offsetWidth; chips.classList.add('hv-in'); }
  }
  function pick(k, quiet) {
    if (k !== who) switchedOnce = true;
    who = k;
    renderPerson();
    if (!quiet) report(fmt(s.switched, { name: people[who].name }));
  }

  // 看過三款以上錶面、換過一次人，就把整篇的教訓收在這一句（唸一次，之後留在畫面上）
  const sep = api.lang.startsWith('zh') ? '' : ' ';
  function report(text) {
    if (!told && seen.size >= 3 && switchedOnce) { told = true; lesson.hidden = false; api.say(text + sep + s.lesson); return; }
    api.say(text);
  }

  root.append(stage, home);
  api.stage.append(root);
  go(0, true);
  pick(0, true);
  api.onReset(() => { seen.clear(); seen.add(0); told = false; lesson.hidden = true; go(0, true); pick(0, true); switchedOnce = false; });
});
