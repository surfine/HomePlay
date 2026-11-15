
"use strict";
// 範例資料：各層復原品裡的行程、天氣、頻道內容、小工具名稱都是示意，不是真實讀數。
const $ = id => document.getElementById(id);
const pad = n => String(n).padStart(2, "0");
const ampm = d => (d.getHours() % 12 || 12) + ":" + pad(d.getMinutes()) + " " + (d.getHours() < 12 ? "AM" : "PM");
const WD = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MO = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

// ── 年代柱與膠囊導覽 ──
const layers = [...document.querySelectorAll(".layer")];
const col = $("col");
let lastTop = -99;
layers.forEach(sec => {
  const y = Number(sec.dataset.year), li = document.createElement("li");
  lastTop = Math.max(4 + (y - 1984) / 42 * 92, lastTop + 7);
  li.style.top = lastTop + "%";
  li.innerHTML = `<a href="#${sec.id}"><b>${y}</b><span>${2026 - y ? "距今 " + (2026 - y) + " 年" : "現在"}</span></a>`;
  col.appendChild(li);
});
$("pill").outerHTML = layers.map(sec => `<a href="#${sec.id}">${sec.dataset.year}</a>`).join("");
const links = [...document.querySelectorAll("#col a, .pill-nav a")];
const io = new IntersectionObserver(es => es.forEach(e => {
  if (e.isIntersecting) links.forEach(a => a.setAttribute("aria-current", a.hash === "#" + e.target.id ? "true" : "false"));
}), { rootMargin: "-45% 0px -50% 0px" });
layers.forEach(s => io.observe(s));
layers.forEach((sec, k) => {
  let seed = 7 + k * 13, pts = ["M0,18"];
  const rnd = () => (seed = (seed * 9301 + 49297) % 233280) / 233280;
  for (let x = 0; x <= 100; x += 2.5) pts.push(`L${x},${(4 + rnd() * 10).toFixed(1)}`);
  pts.push("L100,18 Z");
  sec.insertAdjacentHTML("afterbegin", `<svg class="edge" viewBox="0 0 100 18" preserveAspectRatio="none" aria-hidden="true"><path d="${pts.join(" ")}"/></svg>`);
});


// ── 當年的機器：把每件展品包進自己畫的外殼 ──
const RM = matchMedia("(prefers-reduced-motion: reduce)").matches;
function rig(id, kind, extra, more){
  const el = $(id), st = el.parentElement, r = document.createElement("div");
  r.className = "rig shot " + kind;
  const wr = document.createElement("div"); wr.className = "rigw " + kind; wr.appendChild(r);
  const ct = document.createElement("div"); ct.className = "scr-ct " + (kind === "m128" || kind === "crt" ? "crt-glass" : "lcd-glass");
  st.insertBefore(wr, el);
    const op = document.createElement("div"); op.className = "op"; r.appendChild(op); op.appendChild(ct);
  ct.appendChild(el);
  (more || []).forEach(m => ct.appendChild($(m)));
  if (extra) r.insertAdjacentHTML("beforeend", extra);
  if (kind === "crt" || kind === "imac" || kind === "lcd") wr.insertAdjacentHTML("beforeend", `<span class="stand ${kind}"></span>`);
}
rig("mac", "m128");
rig("w98", "crt");
rig("wd", "crt", "", ["wdTask"]);
rig("tg", "imac");
// 上蓋往後仰時，把螢幕扭到 Blender 投影出來的四個角（上蓋寬 = 100，左上、右上、右下、左下）；只放正面時為 null
const IBOOK_QUAD = null;
function warp(el, rig, quad){
  const k = rig.clientWidth / 100, w = el.offsetWidth, h = el.offsetHeight, ox = el.offsetLeft, oy = el.offsetTop;
  const [x0, y0, x1, y1, x2, y2, x3, y3] = quad.flat().map((v, i) => v * k - (i % 2 ? oy : ox));
  // homography from the unit square to the quad, then scaled to the element's own size
  const dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3, dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
  const den = dx1 * dy2 - dx2 * dy1;
  const g = (dx3 * dy2 - dx2 * dy3) / den, hh = (dx1 * dy3 - dx3 * dy1) / den;
  const a = x1 - x0 + g * x1, b = x3 - x0 + hh * x3, c = x0, d = y1 - y0 + g * y1, e = y3 - y0 + hh * y3, f = y0;
  el.style.transformOrigin = "0 0";
  el.style.transform = `matrix3d(${a / w},${d / w},0,${g / w},${b / h},${e / h},0,${hh / h},0,0,1,0,${c},${f},0,1)`;
}
if (IBOOK_QUAD){
  const rigI = document.querySelector(".rig.imac"), opI = rigI.querySelector(".op");
  new ResizeObserver(() => warp(opI, rigI, IBOOK_QUAD)).observe(rigI);
}
rig("vs", "lcd");
rig("w7", "lcd");
// 1984：按了才從 Infinite Mac 載入真的 System 1.0（做法同 WindowShade 歷史頁）
(() => {
  const go = $("emGo"), say = $("emSay"), ct = $("mac").parentElement;
  let fr = null, timer = 0, ok = false;
  new ResizeObserver(() => ct.style.setProperty("--em", String(ct.clientWidth / 512))).observe(ct);
  function stop(){
    clearTimeout(timer); fr?.remove(); fr = null; ok = false;
    ct.classList.remove("on"); go.setAttribute("aria-pressed", "false"); go.textContent = "開機，跑真的 System 1.0";
  }
  go.addEventListener("click", () => {
    if (fr){ stop(); say.textContent = "關機了，回到復原品。"; return; }
    const u = new URL("https://infinitemac.org/embed");
    u.searchParams.set("disk", "System 1.0"); u.searchParams.set("auto_pause", "true");
    u.searchParams.set("library", "false"); u.searchParams.set("date", "1984-01-24");
    fr = document.createElement("iframe");
    fr.className = "em"; fr.src = u.href; fr.title = "在 Infinite Mac 上執行的 System 1.0";
    fr.allow = "cross-origin-isolated"; fr.width = 512; fr.height = 342;
    ct.appendChild(fr); ct.classList.add("on");
    go.setAttribute("aria-pressed", "true"); go.textContent = "關機，回到復原品";
    say.textContent = "正在開機，第一次要等一會兒。";
    timer = setTimeout(() => { if (!ok) say.textContent = "還沒開起來。可以關機再試，或在 Infinite Mac 的頁面打開。"; }, 45000);
  });
  addEventListener("message", e => {
    if (e.origin !== "https://infinitemac.org" || !fr || e.source !== fr.contentWindow || e.data?.type !== "emulator_loaded") return;
    ok = true; say.textContent = "開機了。附件一樣在左上角的蘋果選單裡，日期是 1984 年 1 月 24 日。";
  });
  addEventListener("pagehide", stop);
})();
// 縮放框：從一個位置到另一個位置連畫幾個框，再打開視窗
function zoom(box, a, b, cls){
  if (RM) return Promise.resolve();
  const o = box.getBoundingClientRect(), n = 8, step = 18, sx = box.offsetWidth / o.width;
  for (let i = 1; i <= n; i++){
    const t = i / n, z = document.createElement("div");
    z.className = "zr " + cls;
    z.style.left = ((a.left + (b.left - a.left) * t) - o.left) * sx + "px";
    z.style.top = ((a.top + (b.top - a.top) * t) - o.top) * sx + "px";
    z.style.width = (a.width + (b.width - a.width) * t) * sx + "px";
    z.style.height = (a.height + (b.height - a.height) * t) * sx + "px";
    setTimeout(() => box.appendChild(z), i * step);
    setTimeout(() => z.remove(), i * step + step * 2.2);
  }
  return new Promise(r => setTimeout(r, n * step + step));
}
function openWin(box, from, win, cls){
  win.hidden = false; const b = win.getBoundingClientRect(); win.hidden = true;
  return zoom(box, from.getBoundingClientRect(), b, cls).then(() => { win.hidden = false; });
}


// 點兩下打開；觸控裝置沒有可靠的雙擊，點一下就打開
const TOUCH = matchMedia("(hover: none)").matches;
function onOpen(el, fn){ el.addEventListener("dblclick", fn); if (TOUCH) el.addEventListener("click", fn); }
// 手機上 16px 以下的輸入框會讓畫面放大：字放到 16px，再整個縮回原本的大小
function fixInputs(root){
  if (!matchMedia("(pointer: coarse)").matches) return;
  (root || document).querySelectorAll(".stage textarea").forEach(t => {
    if (t.dataset.fx) return;
    const cs = getComputedStyle(t), fs = parseFloat(cs.fontSize);
    if (fs >= 16) return;
    const k = fs / 16, w = t.offsetWidth, h = t.offsetHeight;
    if (!w || !h) return;
    t.dataset.fx = "1";
    Object.assign(t.style, { fontSize: "16px", padding: ["Top", "Right", "Bottom", "Left"].map(x => parseFloat(cs["padding" + x]) / k + "px").join(" "),
      width: w / k + "px", height: h / k + "px", transform: `scale(${k})`, transformOrigin: "0 0", marginRight: -(w / k - w) + "px", marginBottom: -(h / k - h) + "px" });
  });
}

// 拖曳：只動 transform
function draggable(handle, box){
  let sx = 0, sy = 0, ox = 0, oy = 0, on = false;
  box._dx = 0; box._dy = 0;
  handle.addEventListener("pointerdown", e => { if (e.target.closest("button")) return; on = true; sx = e.clientX; sy = e.clientY; ox = box._dx; oy = box._dy; handle.setPointerCapture(e.pointerId); });
  handle.addEventListener("pointermove", e => { if (!on) return; box._dx = ox + e.clientX - sx; box._dy = oy + e.clientY - sy; box.style.transform = `translate(${box._dx}px,${box._dy}px)`; });
  const end = () => { on = false; };
  handle.addEventListener("pointerup", end); handle.addEventListener("pointercancel", end);
}
function analogSVG(d, o){
  const h = (d.getHours() % 12 + d.getMinutes() / 60) * 30, m = d.getMinutes() * 6, s = d.getSeconds() * 6;
  const ticks = Array.from({ length: 12 }, (_, i) => `<path d="M50 ${o.r0}v${i % 3 ? o.t1 : o.t2}" transform="rotate(${i * 30} 50 50)"/>`).join("");
  return `${o.bg}<g stroke="${o.tick}" stroke-width="${o.tw}">${ticks}</g>${o.num || ""}
    <path d="M50 50V${o.hl}" stroke="${o.hand}" stroke-width="${o.hw}" stroke-linecap="round" transform="rotate(${h} 50 50)"/>
    <path d="M50 50V${o.ml}" stroke="${o.hand}" stroke-width="${o.mw}" stroke-linecap="round" transform="rotate(${m} 50 50)"/>
    ${o.sec ? `<path d="M50 58V16" stroke="${o.sec}" stroke-width="1" transform="rotate(${s} 50 50)"/>` : ""}<circle cx="50" cy="50" r="2.6" fill="${o.cap || o.hand}"/>`;
}

// ═════ 1984 ═════
(function(){
  // [字, 欄, 列, 寬幾格, 高幾格]：照原圖，欄距列距都是 22
  const keys = [["C", 0, 0], ["=", 1, 0], ["/", 2, 0], ["*", 3, 0], ["7", 0, 1], ["8", 1, 1], ["9", 2, 1], ["-", 3, 1], ["4", 0, 2], ["5", 1, 2], ["6", 2, 2], ["+", 3, 2],
    ["1", 0, 3], ["2", 1, 3], ["3", 2, 3], ["=", 3, 3, 1, 2], ["0", 0, 4, 2, 1], [".", 2, 4]];
  const kp = n => `calc(${n}*var(--p))`;
  $("macKeys").innerHTML = keys.map(([k, c, r, w = 1, h = 1]) => `<button type="button" data-k="${k}" style="left:${kp(9 + 22 * c)};top:${kp(33 + 22 * r)};width:${kp(22 * w - 4)};height:${kp(22 * h - 4)}${k === "0" ? ";text-align:left;padding-left:" + kp(6) : ""}">${k}</button>`).join("");
  let acc = 0, cur = "0", op = null, fresh = true;
  const show = v => { $("macDisp").textContent = typeof v === "string" ? v : String(Math.round(v * 1e6) / 1e6).slice(0, 11); };
  const apply = () => { const b = Number(cur); acc = op === "+" ? acc + b : op === "-" ? acc - b : op === "*" ? acc * b : op === "/" ? (b ? acc / b : 0) : b; };
  $("macKeys").addEventListener("click", e => {
    const k = e.target.closest("button")?.dataset.k; if (!k) return;
    if (/\d/.test(k)){ cur = fresh ? k : (cur + k).slice(0, 10); fresh = false; show(cur); }
    else if (k === "."){ if (fresh){ cur = "0."; fresh = false; } else if (!cur.includes(".")) cur += "."; show(cur); }
    else if (k === "C"){ acc = 0; cur = "0"; op = null; fresh = true; show(0); }
    else { if (!fresh || op === null) apply(); op = k === "=" ? null : k; cur = String(acc); fresh = true; show(acc); }
  });
  // Note Pad：8 頁，點折角翻頁
  const pages = ["明天交稿。", "", "", "", "", "", "", ""]; let pg = 0;
  const showPage = () => { $("macText").value = pages[pg]; $("macPn").textContent = pg + 1; $("macText").setAttribute("aria-label", `Note Pad 第 ${pg + 1} 頁`); };
  $("macText").addEventListener("input", e => { pages[pg] = e.target.value; });
  $("macDog").addEventListener("click", () => { pg = (pg + 1) % 8; showPage(); });
  showPage();
  // Alarm Clock
  const tick = () => { const d = new Date(); $("macTime").textContent = (d.getHours() % 12 || 12) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds()) + " " + (d.getHours() < 12 ? "AM" : "PM"); };
  tick(); setInterval(tick, 1000);
  // Puzzle：15 格，可以解
  let tiles = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0, 15];
  const drawPuz = () => { $("macGrid").innerHTML = tiles.map((t, i) => `<button type="button" data-i="${i}"${t ? "" : ' class="hole" aria-label="空格"'}>${t || ""}</button>`).join(""); };
  $("macGrid").addEventListener("click", e => {
    const i = Number(e.target.closest("button")?.dataset.i); if (Number.isNaN(i)) return;
    const h = tiles.indexOf(0), near = (Math.abs(i - h) === 1 && Math.floor(i / 4) === Math.floor(h / 4)) || Math.abs(i - h) === 4;
    if (near){ [tiles[i], tiles[h]] = [tiles[h], tiles[i]]; drawPuz(); }
  });
  drawPuz();
  const wins = { calc: $("macCalc"), note: $("macNote"), alarm: $("macAlarm"), puz: $("macPuz"), disk: $("macDisk"), trash: $("macTrash") };
  let z = 2;
  const front = w => { w.style.zIndex = ++z; };
  $("macApple").addEventListener("click", () => { const open = $("macMenu").hidden; $("macMenu").hidden = !open; $("macApple").setAttribute("aria-expanded", open ? "true" : "false"); });
  $("macMenu").addEventListener("click", e => {
    const k = e.target.closest("button")?.dataset.open; if (!k) return;
    $("macMenu").hidden = true; $("macApple").setAttribute("aria-expanded", "false");
    if (!wins[k].hidden){ front(wins[k]); return; }
    front(wins[k]); openWin($("mac"), $("macApple"), wins[k], "mac").then(() => fixInputs($("mac")));
  });
  $("mac").addEventListener("click", e => { const k = e.target.closest("button[data-close]")?.dataset.close; if (k) wins[k].hidden = true; });
  Object.values(wins).forEach(w => { draggable(w.querySelector(".tb"), w); w.addEventListener("pointerdown", () => front(w)); });
  const dsks = [...$("mac").querySelectorAll(".dsk")];
  dsks.forEach(d => {
    d.addEventListener("click", () => dsks.forEach(x => x.setAttribute("aria-pressed", x === d ? "true" : "false")));
    onOpen(d, () => { const w = wins[d.dataset.win]; if (!w.hidden){ front(w); return; } front(w); openWin($("mac"), d, w, "mac").then(() => fixInputs($("mac"))); });
    d.addEventListener("keydown", e => { if (e.key === "Enter"){ e.preventDefault(); d.dispatchEvent(new MouseEvent("dblclick")); } });
  });
})();

// ═════ 1997：Active Desktop ═════
(function(){
  const I = {
    pc: `<path d="M4 4h22v15H4z" fill="#c0c0c0" stroke="#000"/><path d="M6 6h18v11H6z" fill="#008080"/><path d="M8 21h14v4H8z" fill="#c0c0c0" stroke="#000"/><path d="M3 25h24v4H3z" fill="#c0c0c0" stroke="#000"/>`,
    doc: `<path d="M3 8h10l2 3h14v17H3z" fill="#ffd96a" stroke="#000"/><path d="M9 4h14l4 4v12H9z" fill="#fff" stroke="#000"/><path d="M12 10h10M12 13h10M12 16h7" stroke="#000080"/>`,
    ie: `<circle cx="16" cy="16" r="11" fill="#3a7bd5" stroke="#000"/><path d="M5 16h22M16 5c-5 4-5 18 0 22M16 5c5 4 5 18 0 22" stroke="#fff" fill="none" stroke-width="1.4"/><path d="M2 20c8-14 24-16 28-10" stroke="#ffd700" stroke-width="2.4" fill="none"/>`,
    net: `<path d="M3 4h12v9H3zM17 4h12v9H17z" fill="#c0c0c0" stroke="#000"/><path d="M5 6h8v5H5zM19 6h8v5h-8z" fill="#008080"/><path d="M9 13v6h14v-6M16 19v5" stroke="#000" fill="none"/><path d="M7 24h18v4H7z" fill="#808080" stroke="#000"/>`,
    bin: `<path d="M8 9h16l-2 19H10z" fill="#e0e0e0" stroke="#000"/><path d="M6 6h20v3H6z" fill="#c0c0c0" stroke="#000"/><path d="M13 12l1 13M16 12v13M19 12l-1 13" stroke="#808080"/>`,
    oe: `<path d="M3 8h26v18H3z" fill="#fff" stroke="#000"/><path d="M3 8l13 10 13-10" fill="none" stroke="#000"/><path d="M18 3l10 4-8 6z" fill="#3a7bd5" stroke="#000"/>`
  };
  const icons = [["pc", "My Computer"], ["doc", "My Documents"], ["ie", "Internet Explorer"], ["net", "Network Neighborhood"], ["bin", "Recycle Bin"], ["oe", "Outlook Express"]];
  $("w98Icons").innerHTML = icons.map(([k, n], i) => `<button type="button" class="dico" style="top:calc(${8 + i * 64}*var(--p))" aria-pressed="false"><svg viewBox="0 0 32 32" aria-hidden="true">${I[k]}</svg><span>${n}</span></button>`).join("");
  $("w98Icons").addEventListener("click", e => { const b = e.target.closest(".dico"); $("w98Icons").querySelectorAll(".dico").forEach(x => x.setAttribute("aria-pressed", x === b ? "true" : "false")); });
  const G = { guide: "M5 9a4 4 0 1 0 8 0 4 4 0 0 0-8 0M12 12l5 5", news: "M4 5h12v10H4zM7 8h6M7 11h4", sport: "M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14M3 10h14M10 3v14", biz: "M10 3v14M13 6c-1-1-5-1-5 1.5S13 9 13 12s-5 2.5-6 1", ent: "M4 6h12v9H4zM8 3l2 3 2-3", life: "M3 13l7-8 7 8M6 13v4h8v-4" };
  const ch = [["channel<br>guide", "guide", "Channel Guide", "Browse more than 250 channels"], ["news &amp;<br>technology", "news", "News & Technology", "Headlines update every hour"],
    ["sports", "sport", "Sports", "Scores update on game days"], ["business", "biz", "Business", "Quotes update after the close"], ["entertain-<br>ment", "ent", "Entertainment", "Updated daily"], ["lifestyle<br>&amp; travel", "life", "Lifestyle & Travel", "Updated weekly"]];
  $("adCh").innerHTML = ch.map((c, i) => `<button type="button" class="ch" data-i="${i}" aria-pressed="false"><span>${c[0]}</span><i><svg viewBox="0 0 20 20" aria-hidden="true"><path d="${G[c[1]]}"/></svg></i></button>`).join("")
    + ["MSN", "MSNBC", "Disney", "PointCast"].map(n => `<button type="button" class="ch pt" aria-label="${n} 頻道（標誌未重畫）">${n}</button>`).join("");
  const item = $("adItem");
  $("adCh").addEventListener("click", e => {
    const b = e.target.closest(".ch"); if (!b) return;
    $("adCh").querySelectorAll(".ch").forEach(x => x.setAttribute("aria-pressed", x === b ? "true" : "false"));
    const c = ch[b.dataset.i];
    if (c){ $("adTitle").textContent = c[2]; $("adText").textContent = c[3]; $("adSub").textContent = "Channel"; }
    else { $("adTitle").textContent = b.textContent; $("adText").textContent = "Partner channel"; $("adSub").textContent = "Channel"; }
    item.hidden = false;
  });
  const clock = () => { $("adClock").textContent = $("wdClock").textContent = ampm(new Date()); };
  clock(); setInterval(clock, 20000);
  item.addEventListener("pointermove", e => { if (e.pointerType !== "mouse") return; const r = item.getBoundingClientRect(); item.classList.toggle("hot", e.clientY - r.top < r.height * .14); });
  item.addEventListener("pointerleave", e => { if (e.pointerType === "mouse") item.classList.remove("hot"); });
  item.addEventListener("click", e => { if (!e.target.closest("button") && matchMedia("(hover:none)").matches) item.classList.toggle("hot"); });
  draggable($("adGrip"), item);
  $("adX").addEventListener("click", () => { item.hidden = true; });
  $("adBack").addEventListener("click", () => { item.hidden = false; item._dx = item._dy = 0; item.style.transform = ""; $("adTitle").textContent = "MSNBC Weather"; $("adText").textContent = "Today's highs"; $("adSub").textContent = "Updated 5:00 PM"; });
})();


// ═════ 1997：開始選單、我的電腦 ═════
(function(){
  const box = $("w98"), clip = $("w98Clip"), btn = $("w98StartBtn");
  const ic = (d, f) => `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${d}" fill="${f || "#c0c0c0"}" stroke="#000"/></svg>`;
  const items = [[ic("M4 4h16v16H4z", "#3a7bd5"), "Windows Update"], 0,
    [ic("M3 6h7l2 2h9v11H3z", "#ffd96a"), "Programs", 1], [ic("M3 6h7l2 2h9v11H3z", "#ffd96a"), "Favorites", 1], [ic("M6 3h10l3 3v15H6z", "#fff"), "Documents", 1],
    [ic("M4 5h16v12H4zM9 17v3h6v-3", "#c0c0c0"), "Settings", 1], [ic("M10 10a5 5 0 1 0 0 .1M14 14l6 6", "#fff"), "Find", 1], [ic("M5 4h12v16H5z", "#ffe680"), "Help"], [ic("M4 6h16v12H4z", "#fff"), "Run..."], 0,
    [ic("M6 4h12v16H6zM12 9v6", "#ffd96a"), "Log Off..."], [ic("M4 4h16v13H4zM8 20h8", "#008080"), "Shut Down..."]];
  $("w98Start").innerHTML = `<div class="band"><span>Windows<b>98</b></span></div><ul>${items.map(i => i ? `<li>${i[0]}<span>${i[1]}</span>${i[2] ? "<em>▶</em>" : ""}</li>` : "<hr>").join("")}</ul>`;
  const setStart = o => { clip.dataset.open = o ? "1" : "0"; btn.setAttribute("aria-expanded", o ? "true" : "false"); };
  btn.addEventListener("click", e => { e.stopPropagation(); setStart(clip.dataset.open !== "1"); });
  $("w98Start").addEventListener("click", e => { if (e.target.closest("li")) setStart(false); });
  box.addEventListener("click", e => { if (!e.target.closest("#w98Clip,#w98StartBtn")) setStart(false); });
  // 我的電腦
  const dr = (f, l) => `<span><svg viewBox="0 0 32 32" aria-hidden="true">${f}</svg>${l}</span>`;
  const drive = '<path d="M3 12h26v10H3z" fill="#c0c0c0" stroke="#000"/><path d="M5 18h8" stroke="#000"/><circle cx="25" cy="17" r="1.5" fill="#3c3"/>';
  $("w98Comp").innerHTML = `<div class="tbar" id="w98CompBar"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 2h12v8H2zM5 12h6v2H5z" fill="#c0c0c0" stroke="#000"/></svg><span>My Computer</span><span class="gap"></span><button type="button" class="cap bevel c98 mn" tabindex="-1" aria-hidden="true"></button><button type="button" class="cap bevel c98 mx" tabindex="-1" aria-hidden="true"></button><button type="button" class="cap bevel c98 x" id="w98CompX" aria-label="關閉 My Computer"></button></div>
    <div class="mrow"><span>File</span><span>Edit</span><span>View</span><span>Go</span><span>Favorites</span><span>Help</span></div>
    <div class="addr">Address<span class="sunk"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 2h12v8H2zM5 12h6v2H5z" fill="#c0c0c0" stroke="#000"/></svg>My Computer</span></div>
    <div class="ebody sunk"><div class="web"><b>My Computer</b><i></i><p>Select an item to view its description.</p></div><div class="eicons">
      ${dr('<path d="M5 6h22v20H5z" fill="#c0c0c0" stroke="#000"/><path d="M10 6h12v8H10z" fill="#fff" stroke="#000"/><path d="M18 8h2v4h-2z"/>', "3½ Floppy (A:)")}
      ${dr(drive, "(C:)")}${dr(drive + '<circle cx="16" cy="9" r="5" fill="#e8e8e8" stroke="#000"/>', "(D:)")}
      ${dr('<path d="M3 8h10l2 3h14v16H3z" fill="#ffd96a" stroke="#000"/><path d="M14 14h12v8H14z" fill="#fff" stroke="#000"/>', "Printers")}
      ${dr('<path d="M3 8h10l2 3h14v16H3z" fill="#ffd96a" stroke="#000"/><path d="M12 15l6 6M18 15l-6 6" stroke="#000080" stroke-width="2"/>', "Control Panel")}
      ${dr('<path d="M3 8h10l2 3h14v16H3z" fill="#ffd96a" stroke="#000"/><path d="M11 22c2-6 8-6 10 0" stroke="#000" fill="none"/>', "Dial-Up Networking")}
      ${dr('<path d="M3 8h10l2 3h14v16H3z" fill="#ffd96a" stroke="#000"/><circle cx="20" cy="19" r="5" fill="#fff" stroke="#000"/><path d="M20 16v3h2" stroke="#000"/>', "Scheduled Tasks")}</div></div>
    <div class="estat"><span class="sunk" style="flex:1">7 object(s)</span><span class="sunk">My Computer</span></div>`;
  const comp = $("w98Comp"), tasks = $("w98Tasks");
  draggable($("w98CompBar"), comp);
  const pc = box.querySelector(".dico");
  function openComp(){
    if (!comp.hidden) return;
    openWin(box, pc, comp, "w98").then(() => {
      tasks.innerHTML = `<button type="button" class="bevel" style="border-color:#404040 #fff #fff #404040;box-shadow:inset 1px 1px 0 #808080;background:#dfdfdf repeating-conic-gradient(#c0c0c0 0 25%,#fff 0 50%) 0 0/2px 2px"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 2h12v8H2zM5 12h6v2H5z" fill="#c0c0c0" stroke="#000"/></svg>My Computer</button>`;
    });
  }
  onOpen(pc, openComp);
  pc.addEventListener("keydown", e => { if (e.key === "Enter"){ e.preventDefault(); openComp(); } });
  $("w98CompX").addEventListener("click", () => { comp.hidden = true; tasks.innerHTML = ""; });
})();

// ═════ 1997：Word 97 與助手 ═════
(function(){
  const T = ["M3 2h8l3 3v9H3z", "M2 5h4l1-2h7v11H2z", "M3 2h10v12H3zM5 5h6M5 8h6", "", "M3 3h10v6H3zM5 11h6v3H5z", "M4 2h7l3 3v9H4zM6 7h5M6 10h5", "", "M4 3l8 10M12 3 4 13", "M5 2h7v9H5zM2 5h7v9H2z", "M3 3h6v10H3zM9 6h4v7H9z", "", "M3 8c0-4 4-6 8-4M3 4v4h4", "M13 8c0-4-4-6-8-4M13 4v4H9", "", "M2 4h12v9H2zM2 7h12M6 4v9M10 4v9", "M2 3h12v10H2zM5 6h6M5 9h4", "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2M8 5v3l2 2"];
  $("wdTools").innerHTML = T.map(d => d ? `<i class="bevel" style="border-width:1px"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="${d}" fill="#fff" stroke="#000"/></svg></i>` : `<span class="sep"></span>`).join("");
  const st = { mode: "1997", hits: 0, mark: 0, quiet: false };
  const bub = $("asBub"), blob = $("asBlob");
  const say = t => { $("asSay").textContent = t || (st.mode === "1997" ? `1997 的做法。你被打斷了 ${st.hits} 次。` : "等你問。它猜到了只亮一個點，按「問它」才開口。"); };
  function mode(m){ st.mode = m; bub.hidden = true; blob.dataset.dot = "0"; $("asM1").setAttribute("aria-pressed", m === "1997" ? "true" : "false"); $("asM2").setAttribute("aria-pressed", m === "ask" ? "true" : "false"); $("asAsk").hidden = m !== "ask"; say(); }
  $("wdText").addEventListener("input", e => {
    const t = e.target.value, looks = /(^|\n)\s*(dear\s|親愛的)/i.test(t) && t.length - st.mark >= 5;
    if (!looks || !bub.hidden) return;
    st.mark = t.length;
    if (st.mode === "1997"){ st.hits++; bub.hidden = false; } else blob.dataset.dot = "1";
    say();
  });
  $("asNo").addEventListener("click", () => { bub.hidden = true; $("wdText").focus(); say(); });
  $("asYes").addEventListener("click", () => { bub.hidden = true; say("當年按這裡會打開寫信精靈。這裡沒有做。"); });
  $("asAsk").addEventListener("click", () => { if (blob.dataset.dot === "1"){ bub.hidden = false; blob.dataset.dot = "0"; say(); } else say("它現在沒有建議。"); });
  $("asM1").addEventListener("click", () => mode("1997")); $("asM2").addEventListener("click", () => mode("ask"));
  mode("1997");
})();

// ═════ 2005：Dashboard ═════
(function(){
  const tg = $("tg"), st = { on: false, off: 8, city: "Taipei", f: true, cal: false };
  const clock = () => { const d = new Date(); $("tgClock").textContent = WD[d.getDay()].slice(0, 3) + " " + ampm(d); };
  clock(); setInterval(clock, 20000);
  // 計算機：按鍵位置量自原圖（以小工具左上角為原點，單位是 1x 像素）
  const keys = [["m+",9.5,53.5,21,17,"s"],["m-",37.5,53.5,21,17,"s"],["mc",65.5,53.5,21,17,"s"],["mr",94.5,53.5,21,17,"s"],
    ["÷",124,54,22,22,"o"],["×",124,79,22,22,"o"],["−",124,109,22,22,"o"],["+",124,138,22,22,"o"],["=",124,170,22,51,"o eq"],
    ["7",8,79],["8",46,79],["9",85,79],["4",8,116],["5",46,116],["6",85,116],["1",8,153],["2",46,153],["3",85,153],["0",8,189],[".",46,189],["c",85,189]];
  const P = n => `calc(${n}*var(--p))`;
  $("tgKeys").innerHTML = keys.map(([k, x, y, w = 32, h = 32, c = ""]) => `<button type="button" class="k ${c}" data-k="${k}" style="left:${P(x)};top:${P(y)};width:${P(w)};height:${P(h)}">${k}</button>`).join("");
  let acc = 0, cur = "0", op = null, fresh = true, mem = 0;
  const showLcd = v => { $("tgLcd").textContent = typeof v === "string" ? v : String(Math.round(v * 1e8) / 1e8).slice(0, 12); };
  const apply = () => { const b = Number(cur); acc = op === "+" ? acc + b : op === "−" ? acc - b : op === "×" ? acc * b : op === "÷" ? (b ? acc / b : 0) : b; };
  $("tgKeys").addEventListener("click", e => {
    const k = e.target.closest("button")?.dataset.k; if (!k) return;
    if (k === "m+"){ mem += Number(cur); fresh = true; }
    else if (k === "m-"){ mem -= Number(cur); fresh = true; }
    else if (k === "mc") mem = 0;
    else if (k === "mr"){ cur = String(mem); fresh = true; showLcd(mem); }
    else if (/\d/.test(k)){ cur = fresh ? k : (cur + k).slice(0, 12); fresh = false; showLcd(cur); }
    else if (k === "."){ if (fresh){ cur = "0."; fresh = false; } else if (!cur.includes(".")) cur += "."; showLcd(cur); }
    else if (k === "c"){ acc = 0; cur = "0"; op = null; fresh = true; showLcd(0); }
    else { if (!fresh || op === null) apply(); op = k === "=" ? null : k; cur = String(acc); fresh = true; showLcd(acc); }
  });
  // 世界時鐘：上半灰、下半黑的方塊，白色錶面；當地晚上換黑色錶面
  function clockHTML(city, off){
    const now = new Date(), d = new Date(now.getTime() + (now.getTimezoneOffset() + off * 60) * 60000), h = d.getHours(), day = h >= 6 && h < 18;
    const face = day ? ["#fdfdfd", "#e2e2e2"] : ["#2a2a2c", "#111"], ink = day ? "#2b2b2b" : "#eee", hand = day ? "#111" : "#f4f4f4";
    const nums = Array.from({ length: 12 }, (_, i) => { const a = (i + 1) * Math.PI / 6; return `<text x="${(50 + 35 * Math.sin(a)).toFixed(1)}" y="${(54 + 35 * -Math.cos(a)).toFixed(1)}" text-anchor="middle" font-size="11" font-family="Helvetica Neue,Helvetica" fill="${ink}">${i + 1}</text>`; }).join("");
    const rot = deg => `transform="rotate(${deg.toFixed(1)} 50 50)"`;
    const hr = (h % 12 + d.getMinutes() / 60) * 30, mn = (d.getMinutes() + d.getSeconds() / 60) * 6, sc = d.getSeconds() * 6;
    return `<span class="pm">${h < 12 ? "AM" : "PM"}</span><svg viewBox="0 0 100 100" role="img" aria-label="${city} 時間"><defs><radialGradient id="cf${off}" cx=".5" cy=".38" r=".62"><stop offset=".55" stop-color="${face[0]}"/><stop offset="1" stop-color="${face[1]}"/></radialGradient></defs>
      <circle cx="50" cy="51.5" r="49" fill="rgba(0,0,0,.55)"/><circle cx="50" cy="50" r="49" fill="url(#cf${off})" stroke="#bdbdbd" stroke-width=".8"/>${nums}
      <path d="M48.3 52 49.2 25h1.6l.9 27z" fill="${hand}" ${rot(hr)}/><path d="M48.8 52 49.5 13h1l.7 39z" fill="${hand}" ${rot(mn)}/>
      <g ${rot(sc)}><path d="M49.6 60h.8l.2-46h-1.2z" fill="#d42a1e"/></g><circle cx="50" cy="50" r="3.4" fill="#d42a1e"/><circle cx="50" cy="50" r="1.1" fill="#fff"/></svg><span class="city">${city}</span>`;
  }
  const drawClock = () => { $("tgClockF").innerHTML = clockHTML(st.city, st.off); };
  // 月曆：上面兩張翻頁卡，下面整月；底下三個鈕：上一月、今天、下一月
  let calOff = 0;
  function drawCal(){
    const now = new Date(), d = new Date(now.getFullYear(), now.getMonth() + calOff, 1), today = calOff === 0 ? now.getDate() : 0;
    const first = d.getDay(), n = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate(), rows = Math.ceil((first + n) / 7);
    let g = "SMTWTFS".split("").map(c => `<span class="h">${c}</span>`).join("");
    for (let i = 0; i < rows * 7; i++){ const v = i - first + 1; g += v >= 1 && v <= n ? (v === today ? `<span class="t"><i>${v}</i></span>` : `<span>${v}</span>`) : "<span></span>"; }
    const shown = calOff === 0 ? now : d;
    $("tgCalF").innerHTML = `<div class="cd l"><span>${WD[shown.getDay()].slice(0, 3)}</span><b>${MO[shown.getMonth()].slice(0, 3).toUpperCase()}</b></div><div class="cd r">${shown.getDate()}</div>
      <div class="gr" style="--rh:calc(${rows > 5 ? 14 : 17}*var(--p))">${g}</div>
      <div class="nav"><button type="button" data-m="-1" aria-label="上一個月">▲</button><button type="button" data-m="0" aria-label="回到今天">◆</button><button type="button" data-m="1" aria-label="下一個月">▼</button></div>`;
  }
  $("tgCalF").addEventListener("click", e => { const b = e.target.closest("button[data-m]"); if (!b) return; calOff = b.dataset.m === "0" ? 0 : calOff + Number(b.dataset.m); drawCal(); });
  // 天氣：上面是現在，下面六天預報（溫度是示範用的固定值）
  const fcIcon = { sun: '<svg viewBox="0 0 22 22"><circle cx="11" cy="11" r="6.5" fill="#ffd23f" stroke="#f2a514"/></svg>',
    cloud: '<svg viewBox="0 0 22 22"><circle cx="8" cy="9" r="4.5" fill="#ffd23f"/><ellipse cx="12" cy="13" rx="8" ry="4.5" fill="#e9eef6"/></svg>',
    rain: '<svg viewBox="0 0 22 22"><ellipse cx="11" cy="9" rx="8" ry="4.5" fill="#cfd8e6"/><path d="M7 15l-1 4M11 15l-1 4M15 15l-1 4" stroke="#bcd3ff" stroke-width="1.4"/></svg>' };
  function drawWx(){
    const base = st.city2 === "Cupertino" ? 64 : 75, show = n => (st.f ? n : Math.round((n - 32) * 5 / 9)) + "°";
    const fc = [["sun", 2], ["cloud", -1], ["rain", -4], ["cloud", 0], ["sun", 2], ["sun", 3]], d0 = new Date().getDay();
    $("tgWx").innerHTML = `<span class="hi">H: ${show(base + 3)}</span><span class="city">${st.city2 || "Taipei"}</span><span class="lo">L: ${show(base - 7)}</span><span class="haze"></span><span class="sun"></span><span class="tmp">${show(base)}</span>
      <div class="fc">${fc.map(([ic, dt], i) => `<div><b>${WD[(d0 + i + 1) % 7].slice(0, 3).toUpperCase()}</b>${fcIcon[ic]}<em>${show(base + dt)}</em></div>`).join("")}</div>`;
  }
  // 小工具列：Tiger 附的 14 個小工具，照字母排；圖示是自己畫的簡化版
  const ico = {
    "Address Book": '<rect x="5" y="5" width="65" height="65" rx="10" fill="#c9a364" stroke="#97733a"/><rect x="5" y="5" width="65" height="30" rx="10" fill="#fff" opacity=".18"/><text x="37.5" y="53" text-anchor="middle" font-size="44" font-weight="700" fill="#fff" font-family="Helvetica">@</text>',
    "Calculator": '<rect x="5" y="5" width="65" height="65" rx="10" fill="#f7931e"/><rect x="12" y="12" width="51" height="51" rx="6" fill="#cbcbcb"/><g fill="#fff" stroke="#b5b5b5"><circle cx="26" cy="26" r="10"/><circle cx="49" cy="26" r="10"/><circle cx="26" cy="49" r="10"/><circle cx="49" cy="49" r="10"/></g><g fill="#7a7a7a" font-size="15" text-anchor="middle" font-family="Helvetica"><text x="26" y="31">+</text><text x="49" y="31">−</text><text x="26" y="54">×</text><text x="49" y="54">÷</text></g>',
    "Calendar": '<rect x="6" y="6" width="63" height="63" rx="7" fill="#fff" stroke="#c43a2c" stroke-width="2"/><rect x="28" y="6" width="19" height="5" rx="2" fill="#c43a2c"/><text x="37.5" y="58" text-anchor="middle" font-size="40" font-weight="700" fill="#c9271a" font-family="Helvetica">31</text>',
    "Dictionary": '<rect x="7" y="5" width="61" height="65" rx="5" fill="#5a1410"/><rect x="12" y="8" width="54" height="59" rx="2" fill="#f4ecd8"/><circle cx="20" cy="40" r="14" fill="#d9b860"/><text x="20" y="46" text-anchor="middle" font-size="17" fill="#5a1410" font-family="Georgia">D</text><g stroke="#b9ad94"><path d="M38 20h22M38 27h22M38 34h18M38 41h22M38 48h16"/></g>',
    "Flight Tracker": '<rect x="5" y="5" width="65" height="65" rx="10" fill="#3d78c9"/><rect x="5" y="5" width="65" height="32" rx="10" fill="#8fc0f0" opacity=".55"/><text x="37.5" y="52" text-anchor="middle" font-size="38" fill="#fff">✈</text>',
    "iTunes": '<rect x="5" y="5" width="65" height="65" rx="10" fill="#eef1f6" stroke="#b9c3d0"/><circle cx="37.5" cy="37.5" r="23" fill="#fff" stroke="#9fb3cc" stroke-width="2"/><text x="37.5" y="48" text-anchor="middle" font-size="30" fill="#2a6fd6">♫</text>',
    "Phone Book": '<rect x="5" y="5" width="65" height="65" rx="8" fill="#f6c816" stroke="#c49a00"/><path d="M24 22l26 26M50 30v18H32" fill="none" stroke="#1d1d1d" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>',
    "Stickies": '<rect x="10" y="10" width="57" height="57" fill="#a59a45" opacity=".5"/><rect x="8" y="8" width="57" height="57" fill="#fdf08a"/><rect x="8" y="8" width="57" height="10" fill="#f6e46a"/>',
    "Stocks": '<rect x="5" y="5" width="65" height="65" rx="10" fill="#10264a" stroke="#4a6a9a"/><path d="M12 50l9-6 7 4 8-14 7 6 8-12 7 4 6-8" fill="none" stroke="#9fc3ff" stroke-width="2.5" stroke-linejoin="round"/><path d="M12 58h51" stroke="#4a6a9a"/>',
    "Tile Game": '<rect x="5" y="5" width="65" height="65" rx="6" fill="#4f7d24"/><g fill="#86c24a"><rect x="9" y="9" width="18" height="18"/><rect x="29" y="9" width="18" height="18" fill="#a9db6e"/><rect x="49" y="9" width="17" height="18"/><rect x="9" y="29" width="18" height="18" fill="#a9db6e"/><rect x="29" y="29" width="18" height="18"/><rect x="9" y="49" width="18" height="17"/><rect x="29" y="49" width="18" height="17" fill="#a9db6e"/><rect x="49" y="49" width="17" height="17"/></g>',
    "Translation": '<circle cx="37.5" cy="37.5" r="31" fill="#4b8fe0" stroke="#2c62aa"/><g fill="none" stroke="#fff" stroke-width="2" opacity=".85"><ellipse cx="37.5" cy="37.5" rx="13" ry="31"/><path d="M6.5 37.5h62M11 22h53M11 53h53M37.5 6.5v62"/></g>',
    "Unit Converter": '<rect x="5" y="5" width="65" height="65" rx="10" fill="#4a4f58" stroke="#2a2d33"/><path d="M20 28h33l-7-7M55 47H22l7 7" fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>',
    "Weather": '<rect x="5" y="5" width="65" height="65" rx="10" fill="#3c69ac"/><circle cx="31" cy="31" r="13" fill="#ffd23f"/><ellipse cx="44" cy="47" rx="19" ry="10" fill="#f1f4f9"/>',
    "World Clock": '<circle cx="37.5" cy="37.5" r="31" fill="#111"/><circle cx="37.5" cy="37.5" r="25" fill="#f2f2f2"/><path d="M37.5 37.5V19M37.5 37.5l11 7" stroke="#111" stroke-width="3" stroke-linecap="round"/><circle cx="37.5" cy="37.5" r="2.5" fill="#d42a1e"/>' };
  $("tgShelf").innerHTML = '<span class="arr l" aria-hidden="true">◀</span>' + Object.entries(ico).map(([n, s]) => `<button type="button" data-n="${n}"><svg viewBox="0 0 75 75" aria-hidden="true">${s}</svg>${n}</button>`).join("") + '<span class="arr r" aria-hidden="true">▶</span>';
  $("tgPlus").addEventListener("click", () => { const o = $("tgShelf").dataset.open === "1"; $("tgShelf").dataset.open = o ? "0" : "1"; $("tgDash").dataset.edit = o ? "0" : "1"; $("tgPlus").setAttribute("aria-label", o ? "打開小工具列" : "收起小工具列"); });
  const addCx = wg => { if (!wg.querySelector(".cx")) wg.insertAdjacentHTML("beforeend", '<button type="button" class="cx" aria-label="關閉這個小工具">✕</button>'); };
  $("tgDash").querySelectorAll(".wg").forEach(addCx);
  let extra = 0;
  function ripple(x, y){ const r = document.createElement("div"); r.className = "ripple"; const s = 120; Object.assign(r.style, { left: `calc(${x - s / 2}*var(--p))`, top: `calc(${y - s / 2}*var(--p))`, width: `calc(${s}*var(--p))`, height: `calc(${s}*var(--p))` }); $("tgDash").appendChild(r); setTimeout(() => r.remove(), 650); }
  $("tgShelf").addEventListener("click", e => {
    const b = e.target.closest("button[data-n]"); if (!b) return;
    const slots = [[120, 600], [300, 600], [1150, 250], [1150, 460], [900, 590], [1170, 640]], [sx, sy] = slots[extra % slots.length], k = Math.floor(extra / slots.length) * 14, n = b.dataset.n, x = sx + k, y = sy + k; extra++;
    let html;
    if (n === "Stickies") html = `<div class="wg w-sticky pop" style="left:calc(${x}*var(--p));top:calc(${y}*var(--p));width:calc(150*var(--p));height:calc(150*var(--p))"><div class="in"><div class="f"><textarea aria-label="Stickies">Call the plumber</textarea></div></div></div>`;
    else if (n === "World Clock") html = `<div class="wg w-clock pop" style="left:calc(${x}*var(--p));top:calc(${y - 30}*var(--p));width:calc(146*var(--p));height:calc(145*var(--p))"><div class="in"><div class="f">${clockHTML("Tokyo", 9)}</div></div></div>`;
    else { $("tgSay").textContent = `${n} 這一個沒有做，示範只做了 Stickies 和 World Clock。`; return; }
    $("tgSay").textContent = "";
    $("tgShelf").insertAdjacentHTML("beforebegin", html);
    const wg = $("tgShelf").previousElementSibling; addCx(wg); fixInputs(tg);
    ripple(x + 70, y + 60);
  });
  $("tgDash").addEventListener("click", e => { const c = e.target.closest(".cx"); if (c){ e.stopPropagation(); c.closest(".wg").remove(); } }, true);
  function show(on){ st.on = on; tg.dataset.on = on ? "1" : "0"; $("tgGo").setAttribute("aria-pressed", on ? "true" : "false"); $("tgGo").textContent = on ? "收回 Dashboard" : "叫出 Dashboard"; }
  $("tgGo").addEventListener("click", () => show(!st.on));
  tg.addEventListener("keydown", e => { if (e.key === "F12"){ e.preventDefault(); show(!st.on); } else if (e.key === "Escape") show(false); });
  $("tgDash").addEventListener("click", e => {
    const wg = e.target.closest(".wg");
    if (!wg && !e.target.closest(".shelf,.plus")){ show(false); return; }
    if (e.target.closest(".i")) wg.classList.add("flip");
    else if (e.target.closest(".done")){ wg.classList.remove("flip"); drawClock(); drawWx(); }
  });
  $("tgCity").addEventListener("change", e => { st.off = Number(e.target.value); st.city = e.target.selectedOptions[0].text; });
  $("tgWxC").addEventListener("change", e => { st.city2 = e.target.value; });
  $("tgF").addEventListener("change", e => { st.f = e.target.checked; });
  drawClock(); drawCal(); drawWx(); setInterval(drawClock, 1000);
})();

// ═════ 2007：Vista 側邊欄 ═════
(function(){
  const vsClock = () => {
    const d = new Date();
    $("vsClock").innerHTML = `<svg viewBox="0 0 100 100" role="img" aria-label="時鐘">${analogSVG(d, {
      bg: `<defs><linearGradient id="vsRim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fbfbfb"/><stop offset="1" stop-color="#8e969e"/></linearGradient><radialGradient id="vsFace" cx=".5" cy=".38" r=".6"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#d9dde1"/></radialGradient></defs><circle cx="50" cy="50" r="47" fill="url(#vsRim)"/><circle cx="50" cy="50" r="42" fill="url(#vsFace)" stroke="#9aa2aa" stroke-width=".6"/>`,
      r0: 11, t1: 3, t2: 6, tick: "#4a5158", tw: 1.2, hand: "#111", hw: 3.4, hl: 28, mw: 2.2, ml: 15, sec: "#c62828" })}</svg>`;
    $("vsTime").textContent = ampm(d);
  };
  vsClock(); setInterval(vsClock, 1000);
  const d = new Date();
  $("vsMo").textContent = MO[d.getMonth()].toUpperCase(); $("vsDn").textContent = d.getDate(); $("vsWd").textContent = WD[d.getDay()].toUpperCase();
  const first = new Date(d.getFullYear(), d.getMonth(), 1).getDay(), n = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
  let rows = "<tr>" + "SMTWTFS".split("").map(c => `<td><b style="color:#888">${c}</b></td>`).join("") + "</tr><tr>", k = 0;
  for (let i = 0; i < first; i++, k++) rows += "<td></td>";
  for (let i = 1; i <= n; i++, k++){ if (k && k % 7 === 0) rows += "</tr><tr>"; rows += `<td${i === d.getDate() ? ' class="now"' : ""}>${i}</td>`; }
  $("vsMonth").innerHTML = `<b>${MO[d.getMonth()]} ${d.getFullYear()}</b><table>${rows}</tr></table>`;
  const cal = $("vsCal"), toggle = () => { cal.dataset.open = cal.dataset.open === "1" ? "0" : "1"; };
  cal.addEventListener("click", toggle); cal.addEventListener("keydown", e => { if (e.key === "Enter" || e.key === " "){ e.preventDefault(); toggle(); } });
  const feed = [["Microsoft ships Windows Vista to consumers", "Microsoft News · 2 hours ago"], ["New gadgets added to the Live Gallery", "Windows Live · 5 hours ago"], ["How to keep your Sidebar tidy", "Windows Vista Team Blog · Yesterday"], ["Weekend forecast: rain moves east", "Weather · Yesterday"]];
  $("vsFeed").innerHTML = feed.map((f, i) => `<button type="button" class="it" data-i="${i}"><b>${f[0]}</b><span>${f[1]}</span></button>`).join("") + `<div class="pager"><span>◂</span><span>1-4</span><span>▸</span></div>`;
  let open = -1;
  $("vsFeed").addEventListener("click", e => {
    const b = e.target.closest(".it"); if (!b) return;
    const g = b.closest(".gad"), i = Number(b.dataset.i);
    g.querySelector(".fly")?.remove();
    if (open === i){ open = -1; return; }
    open = i;
    g.insertAdjacentHTML("beforeend", `<div class="fly"><b>${feed[i][0]}</b><small>${feed[i][1]}</small>範例內容。點標題會在這裡打開文章的摘要，再點一次收起。</div>`);
  });
})();


// ═════ 2007：側邊欄的工具列、小工具庫 ═════
(function(){
  const tool = '<div class="tool"><button type="button" class="tx" aria-label="移除這個小工具"><svg viewBox="0 0 8 8" aria-hidden="true"><path d="M1 1l6 6M7 1L1 7"/></svg></button><svg viewBox="0 0 8 8" aria-hidden="true"><path d="M6 1a2 2 0 0 0-2 3L1 7"/></svg><svg viewBox="0 0 8 8" aria-hidden="true"><path d="M2 2h.01M6 2h.01M2 6h.01M6 6h.01"/></svg></div>';
  const gads = $("vsGads");
  const arm = g => { if (!g.querySelector(".tool")) g.insertAdjacentHTML("beforeend", tool); };
  gads.querySelectorAll(".gad").forEach(arm);
  gads.addEventListener("click", e => {
    const x = e.target.closest(".tx"); if (!x) return;
    e.stopPropagation(); const g = x.closest(".gad"); g.classList.add("out"); setTimeout(() => g.remove(), RM ? 0 : 210);
  }, true);
  const cpu = `<svg viewBox="0 0 125 100" aria-hidden="true"><g fill="none" stroke-linecap="round"><path d="M18 64a32 32 0 0 1 64 0" stroke="#555" stroke-width="5"/><path d="M18 64a32 32 0 0 1 40-31" stroke="#3ccf6b" stroke-width="5"/><path d="M84 70a18 18 0 0 1 32 0" stroke="#555" stroke-width="4"/><path d="M84 70a18 18 0 0 1 20-14" stroke="#ffb21a" stroke-width="4"/></g>
    <line class="n1" x1="50" y1="64" x2="50" y2="36" stroke="#e33" stroke-width="2"/><line class="n2" x1="100" y1="70" x2="100" y2="56" stroke="#e33" stroke-width="2"/><circle cx="50" cy="64" r="3" fill="#ccc"/><circle cx="100" cy="70" r="2.4" fill="#ccc"/>
    <rect x="34" y="74" width="32" height="13" rx="6" fill="#000"/><text class="v1" x="50" y="84" text-anchor="middle" font-size="9" fill="#3ccf6b" font-family="Segoe UI,Arial">12%</text><rect x="86" y="76" width="28" height="12" rx="6" fill="#000"/><text class="v2" x="100" y="85" text-anchor="middle" font-size="8" fill="#ffb21a" font-family="Segoe UI,Arial">41%</text></svg>`;
  const avail = { "Notes": ['<rect x="8" y="8" width="48" height="48" fill="#fff8a8" stroke="#c2b44a"/><path d="M14 22h36M14 30h36M14 38h24" stroke="#999"/>', '<div class="gad g-notes"><div class="bodyg"><textarea aria-label="Notes">Pick up dry cleaning</textarea></div></div>'],
    "Slide Show": ['<rect x="6" y="12" width="52" height="40" rx="2" fill="#7ab6e8" stroke="#333" stroke-width="2"/><path d="M8 50l14-14 10 8 10-6 14 12z" fill="#3f7a3a"/>', '<div class="gad g-slide"><div class="bodyg"></div></div>'],
    "CPU Meter": ['<circle cx="32" cy="34" r="24" fill="#1b1d20" stroke="#8a9096" stroke-width="3"/><path d="M14 40a18 18 0 0 1 36 0" stroke="#3ccf6b" stroke-width="4" fill="none"/>', `<div class="gad g-cpu"><div class="bodyg">${cpu}</div></div>`] };
  $("vsGalRow").innerHTML = Object.entries(avail).map(([n, [i]]) => `<button type="button" data-n="${n}"><svg viewBox="0 0 64 64" aria-hidden="true">${i}</svg>${n}</button>`).join("");
  $("vsPlus").addEventListener("click", () => { $("vsGal").hidden = !$("vsGal").hidden; });
  $("vsGalX").addEventListener("click", () => { $("vsGal").hidden = true; });
  $("vsGalX").addEventListener("keydown", e => { if (e.key === "Enter" || e.key === " "){ e.preventDefault(); $("vsGal").hidden = true; } });
  const add = n => { gads.insertAdjacentHTML("beforeend", avail[n][1]); const g = gads.lastElementChild; g.classList.add("fadein"); arm(g); fixInputs(g); };
  onOpen($("vsGalRow"), e => { const b = e.target.closest("button[data-n]"); if (b) add(b.dataset.n); });
  $("vsGalRow").addEventListener("keydown", e => { const b = e.target.closest("button[data-n]"); if (b && e.key === "Enter"){ e.preventDefault(); add(b.dataset.n); } });
  setInterval(() => { document.querySelectorAll(".g-cpu").forEach(g => {
    const a = 8 + Math.round(Math.random() * 30), m = 38 + Math.round(Math.random() * 6);
    g.querySelector(".n1").setAttribute("transform", `rotate(${-90 + a * 1.8} 50 64)`); g.querySelector(".n2").setAttribute("transform", `rotate(${-90 + m * 1.8} 100 70)`);
    g.querySelector(".v1").textContent = a + "%"; g.querySelector(".v2").textContent = m + "%"; }); }, 1000);
})();

// ═════ 2007：SideShow 裝置（螢幕內座標照原廠程式，單位是 320×240 的像素） ═════
(function(){
  const G = { pc: `<rect x="3" y="4" width="18" height="12" rx="1.5"/><path d="M9 20h6M12 16v4"/>`, cal: `<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>`,
    mail: `<rect x="3" y="5" width="18" height="14" rx="1.5"/><path d="M3 7l9 7 9-7"/>`, wx: `<circle cx="8" cy="9" r="3.5"/><path d="M7 19h10a4 4 0 0 0 0-8 5 5 0 0 0-9 1"/>`,
    cards: `<rect x="4" y="4" width="11" height="15" rx="1.5"/><path d="M9 7h9a1.5 1.5 0 0 1 1.5 1.5V20"/>` };
  const apps = [["pc", "PC Status", [["Computer is on", "Battery: 82%, Charging", "Connected to: HomeNet"]], false],
    ["cal", "Calendar", [["Next: 7:30 PM Groceries", "Tomorrow 9:00 AM Stand-up", "Sat 2:00 PM Dentist"], ["Mon 10:00 AM Deadline", "Wed 3:30 PM School meeting"]], false],
    ["mail", "Inbox", [["3 unread messages", "Content updated at 2:05 PM"]], true], ["wx", "Weather", [["Partly cloudy, 64°", "Content updated at 2:05 PM"]], true], ["cards", "Solitaire", [["Play without your computer"]], false]];
  const s = { sel: 1, page: 0, open: false, asleep: false, mi: 0 };
  const el = $("ss"), n = apps.length, slots = n + 3;
  function draw(){
    const d = new Date(), a = apps[s.sel];
    let html = `<div class="clock">${WD[d.getDay()].slice(0, 3)} ${d.getMonth() + 1}/${d.getDate()} ${ampm(d)}</div>`;
    let y = -44, i = (s.sel - 2 + slots) % slots;
    while (y < 240){ const size = i === s.sel ? 68 : 46;
      if (i < n) html += `<div class="tile${i === s.sel ? " sel" : ""}" style="left:calc(${40 - size / 2}*var(--u));top:calc(${y}*var(--u));width:calc(${size}*var(--u));height:calc(${size}*var(--u))"><svg viewBox="0 0 24 24" aria-hidden="true">${G[apps[i][0]]}</svg></div>`;
      y += size + 2; i = (i + 1) % slots; }
    const lines = a[2][Math.min(s.page, a[2].length - 1)];
    html += `<div class="cap">${a[1]}</div><div class="gl">${lines.map(t => `<div>${t}</div>`).join("")}</div>`;
    if (a[2].length > 1) html += `<div class="pg">${s.page ? "◀" : "▶"}</div>`;
    if (s.open){ const blocked = s.asleep && a[3];
      html += `<div class="page"><div class="tb">${a[1]}</div>` + (blocked ? `<div class="msg">You must turn on your computer to run ${a[1]}.</div>`
        : ["Open", "Refresh", "Hide this gadget"].map((t, k) => `<div class="mi${k === s.mi ? " sel" : ""}">${t}</div>`).join("")) + `</div>`; }
    el.innerHTML = html;
    $("ssPc").setAttribute("aria-pressed", s.asleep ? "true" : "false"); $("ssPc").textContent = s.asleep ? "叫醒電腦" : "讓電腦睡著";
  }
  function key(k){
    if (s.open){ if (k === "back" || k === "left" || k === "ok") s.open = false; else if (k === "up") s.mi = (s.mi + 2) % 3; else if (k === "down") s.mi = (s.mi + 1) % 3; }
    else if (k === "up"){ s.sel = (s.sel - 1 + n) % n; s.page = 0; } else if (k === "down"){ s.sel = (s.sel + 1) % n; s.page = 0; }
    else if (k === "left") s.page = Math.max(0, s.page - 1); else if (k === "right") s.page = Math.min(apps[s.sel][2].length - 1, s.page + 1);
    else if (k === "ok"){ s.open = true; s.mi = 0; }
    draw();
  }
  const dev = $("ssd");
  dev.addEventListener("click", e => { const b = e.target.closest("button[data-k]"); if (b) key(b.dataset.k); });
  $("ssPc").addEventListener("click", () => { s.asleep = !s.asleep; draw(); });
  dev.tabIndex = 0; dev.setAttribute("role", "application"); dev.setAttribute("aria-label", "SideShow 裝置的復原品，可以用方向鍵、Enter 和 Esc");
  dev.addEventListener("keydown", e => { const map = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Enter: "ok", Escape: "back" }; if (map[e.key] && e.target === dev){ e.preventDefault(); key(map[e.key]); } });
  draw();
})();

// ═════ 2012：Windows 7 小工具庫 ═════
(function(){
  const t7 = () => { const d = new Date(); $("w7Clock").innerHTML = ampm(d) + "<br>" + (d.getMonth() + 1) + "/" + d.getDate() + "/" + d.getFullYear(); };
  t7(); setInterval(t7, 20000);
  const icon = {
    Calendar: `<rect x="8" y="10" width="48" height="46" rx="4" fill="#fff" stroke="#8a2a00"/><path d="M8 14a4 4 0 0 1 4-4h40a4 4 0 0 1 4 4v8H8z" fill="#e2580f"/><text x="32" y="48" text-anchor="middle" font-size="22" font-weight="700" fill="#333" font-family="Segoe UI,Arial">13</text>`,
    Clock: `<circle cx="32" cy="32" r="26" fill="#eef1f3" stroke="#7d868f" stroke-width="3"/><path d="M32 32V16M32 32l10 6" stroke="#111" stroke-width="3" stroke-linecap="round"/>`,
    "CPU Meter": `<circle cx="32" cy="34" r="24" fill="#1b1d20" stroke="#8a9096" stroke-width="3"/><path d="M14 40a18 18 0 0 1 36 0" stroke="#3ccf6b" stroke-width="4" fill="none"/><path d="M32 40 44 26" stroke="#e33" stroke-width="2.6"/>`,
    Currency: `<rect x="6" y="14" width="52" height="36" rx="6" fill="#2b8a3e" stroke="#155d27"/><text x="32" y="40" text-anchor="middle" font-size="22" font-weight="700" fill="#fff" font-family="Arial">$</text>`,
    "Feed Headlines": `<rect x="8" y="8" width="48" height="48" rx="6" fill="#ff8a1a" stroke="#a24d00"/><circle cx="20" cy="44" r="4" fill="#fff"/><path d="M18 30a16 16 0 0 1 16 16M18 18a28 28 0 0 1 28 28" stroke="#fff" stroke-width="5" fill="none"/>`,
    "Picture Puzzle": `<rect x="8" y="8" width="48" height="48" rx="3" fill="#6ab0e8" stroke="#2a5d8a"/><path d="M8 32h48M32 8v48" stroke="#fff" stroke-width="2"/><circle cx="20" cy="20" r="6" fill="#ffd34d"/>`,
    "Slide Show": `<rect x="6" y="12" width="52" height="40" rx="3" fill="#fff" stroke="#555" stroke-width="2"/><path d="M10 46l14-16 10 10 8-6 12 12z" fill="#4c9a3c"/><circle cx="44" cy="22" r="5" fill="#f5b100"/>`,
    Weather: `<circle cx="26" cy="26" r="13" fill="#ffd34d" stroke="#d99a00"/><path d="M20 50h26a9 9 0 0 0 0-18 12 12 0 0 0-23 3 8 8 0 0 0-3 15z" fill="#fff" stroke="#8aa0b6"/>`,
    "Free Puzzle Game": `<rect x="8" y="8" width="48" height="48" rx="8" fill="#b0413e" stroke="#6e1d1b"/><circle cx="22" cy="22" r="4" fill="#fff"/><circle cx="42" cy="22" r="4" fill="#fff"/><circle cx="32" cy="32" r="4" fill="#fff"/><circle cx="22" cy="42" r="4" fill="#fff"/><circle cx="42" cy="42" r="4" fill="#fff"/>`
  };
  const desc = { Calendar: "Browse dates and see today's date.", Clock: "See the time in different time zones.", "CPU Meter": "Monitor how much your computer is working.", Currency: "Convert between currencies.",
    "Feed Headlines": "Read the latest headlines from your feeds.", "Picture Puzzle": "Move the tiles to form a picture.", "Slide Show": "Show pictures from a folder.", Weather: "See the current weather for a location.",
    "Free Puzzle Game": "Downloaded from the Internet. Publisher unknown." };
  const names = Object.keys(icon);
  const st = { sel: 0, on: {}, off: false };
  const ic = (n, cls) => `<span class="gi${cls || ""}"><svg viewBox="0 0 64 64" aria-hidden="true">${icon[n]}</svg></span>`;
  function draw(){
    $("w7Tiles").innerHTML = names.map((n, i) => `<button type="button" class="tile" data-i="${i}" aria-pressed="${i === st.sel}" data-off="${st.off ? 1 : 0}">${ic(n)}${n}</button>`).join("");
    const n = names[st.sel];
    $("w7Det").innerHTML = `${ic(n)}<b>${n}</b><p>${desc[n]}</p><p style="color:#666">${st.on[st.sel] ? "Added to desktop." : n === "Free Puzzle Game" ? "Version: 1.0 · Unknown Publisher" : "Version: 1.0 · Microsoft Corporation"}</p>`;
    $("w7Off").setAttribute("aria-pressed", st.off ? "true" : "false");
    $("w7Off").textContent = st.off ? "重新打開側邊欄與小工具" : "關閉側邊欄與小工具";
    const k = Object.keys(st.on).length;
    $("w7Say").textContent = st.off ? "全部停用。這就是 2012 年官方給的解法。" : st.on[8] ? "裝好了。它現在能做的事和你一樣多：讀寫你的文件、連上網路、執行別的程式。" : k ? `已加到桌面 ${k} 個。` : "";
  }
  function add(i){
    if (st.off) return;
    if (names[i] === "Free Puzzle Game" && !st.on[i]){ $("w7Warn").hidden = false; return; }
    st.on[i] = true; draw();
  }
  $("w7Tiles").addEventListener("click", e => { const t = e.target.closest(".tile"); if (t){ st.sel = Number(t.dataset.i); draw(); } });
  onOpen($("w7Tiles"), e => { const t = e.target.closest(".tile"); if (t) add(Number(t.dataset.i)); });
  $("w7Tiles").addEventListener("keydown", e => { const t = e.target.closest(".tile"); if (t && e.key === "Enter"){ e.preventDefault(); add(Number(t.dataset.i)); } });
  $("w7Ok").addEventListener("click", () => { $("w7Warn").hidden = true; st.on[8] = true; draw(); });
  $("w7No").addEventListener("click", () => { $("w7Warn").hidden = true; $("w7Say").textContent = "沒有安裝。當年很多人在這裡按了 Install。"; });
  $("w7Off").addEventListener("click", () => { st.off = !st.off; $("w7Warn").hidden = true; draw(); });
  draw();
})();

// ═════ 2009 到 2023：兩支手機 ═════
(function(){
  const tl = [[540, "Stand-up", "9:00 – 9:15 AM"], [720, "Lunch with Mei", "12:00 – 1:00 PM"], [900, "Dentist", "3:00 – 3:45 PM"], [1170, "Groceries", "7:30 – 8:00 PM"]];
  const hm = m => (Math.floor(m / 60) % 12 || 12) + ":" + pad(m % 60);
  let left = 0, timer = 0;
  function draw(){
    const now = Number($("phR").value), d = new Date();
    $("ipClock").textContent = hm(now); $("g1Time").textContent = hm(now) + (now < 720 ? " AM" : " PM");
    const g = new Date(d.getFullYear(), d.getMonth(), d.getDate(), Math.floor(now / 60), now % 60);
    $("g1Clock").innerHTML = analogSVG(g, { bg: `<circle cx="50" cy="50" r="47" fill="#2f3236" stroke="#9aa0a6" stroke-width="2"/><circle cx="50" cy="50" r="41" fill="#e9ecef"/>`, r0: 12, t1: 3, t2: 7, tick: "#333", tw: 1.6, hand: "#222", hw: 4, hl: 30, mw: 2.6, ml: 16, cap: "#c62828" });
    $("ipWd").textContent = WD[d.getDay()]; $("ipD").textContent = d.getDate();
    const next = tl.filter(e => e[0] > now).slice(0, 3); $("ipNo").textContent = next.length ? next.length + (next.length > 1 ? " events" : " event") + " left today" : "No more events today";
    $("ipEv").innerHTML = next.map(e => `<div class="ev"><b>${e[1]}</b><span>${e[2]}</span></div>`).join("");
    $("phTl").innerHTML = "App 事先交出的時間軸：" + tl.map(e => `<div data-now="${e === next[0] ? 1 : 0}">${hm(e[0])} 以前顯示「${e[1]}」</div>`).join("");
  }
  $("phR").addEventListener("input", draw);
  $("phGo").addEventListener("click", () => {
    clearInterval(timer); left = 10; $("phLive").dataset.on = "1"; $("phLiveT").textContent = "0:10";
    $("phSay").textContent = "進行中的事出現在螢幕最上方。示範用 10 秒。";
    timer = setInterval(() => { left--; $("phLiveT").textContent = "0:" + pad(left); if (left <= 0){ clearInterval(timer); $("phLive").dataset.on = "0"; $("phSay").textContent = "結束了，它就消失。"; } }, 1000);
  });
  draw();
})();

// ═════ 2026：方形螢幕 ═════
(function(){
  const steps = [["3 公尺外", "只有時間。", 0.72], ["一公尺半", "多了日期。", 0.86], ["伸手可及", "多了下一個行程和計時。", 1]];
  function draw(){
    const d = new Date(), i = Number($("hvR").value);
    $("hvT").textContent = d.getHours() + ":" + pad(d.getMinutes());
    $("hvDt").textContent = `${d.getMonth() + 1}月${d.getDate()}日 週${"日一二三四五六"[d.getDay()]}`; $("hvDt").dataset.on = i ? "1" : "0";
    $("hvMore").innerHTML = "19:30 買菜<br>計時還有 9 分鐘"; $("hvMore").dataset.on = i === 2 ? "1" : "0";
    $("hvDev").style.transform = `scale(${steps[i][2]})`;
    $("hvSay").textContent = steps[i][0] + "：" + steps[i][1];
  }
  $("hvR").addEventListener("input", draw); draw(); setInterval(draw, 20000);
})();
fixInputs();
$("tgGo").addEventListener("click", () => setTimeout(() => fixInputs($("tg")), 260));
