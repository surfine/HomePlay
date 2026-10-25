// 2.0 閒置裝置·網頁串流：裝置上打開的那一頁（單一 HTML，ES5，iOS 9 以上的 Safari 都跑得動）。
//
// 版面照 IdleLayouts：直放＝正方形貼頂端、下面一條大時鐘＋「跟 Mac 連上沒有」；橫放＝正方形在左、右邊一欄大時鐘；
// 正方形螢幕圓角跟 HomeView 一樣（138/1024）。沒人碰 10 分鐘疊黑色遮罩 10 秒淡入（不鎖亮度），每 3 分鐘整頁位移 1–2 px 防烙印。
// 防睡眠：Wake Lock（只有安全來源才有，純 http 的區網頁沒有）＋靜音循環小影片的老方法；配對頁照 IdlePairing 教「加入主畫面」
// 「自動鎖定：永不」「引導使用模式」（這些只有使用者自己能設）。
// 介面文字一律從 Localizable.xcstrings 來（L()），在送出頁面時填進去；頁面本身的程式碼只有英文註解。

import AppKit

enum RemotePage {
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 頁面上 JavaScript 用的字串（JSON）
    static var strings: String {
        let d: [String: String] = [
            "lang": L("remote.web.lang", "zh-CN"),
            "connecting": L("remote.web.connecting", "正在连接 Mac…"),
            "connected": L("remote.web.connected", "已连接 %@"),
            "reconnecting": L("remote.web.reconnecting", "正在重新连接…"),
            "unreachable": L("remote.web.unreachable", "连不上 Mac：它要醒着，而且在同一个 Wi‑Fi"),
            "notPaired": L("remote.web.notPaired", "还没配对"),
            "badCode": L("remote.web.badCode", "配对码不对或已失效，请在 Mac 上产生新的码"),
            "removed": L("remote.web.removed", "这台设备已被移除，请重新配对"),
            "badFormat": L("remote.web.badFormat", "配对码是 16 个字，例如 ABCD-EFGH-JKMN-PQRS"),
            "handoffExpired": L("remote.web.handoffExpired", "这个图标里的一次性交接码已经失效（只有 60 秒），请输入 Mac 上的配对码"),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data("{}".utf8)
        // </script> 不可能出現在這些字串裡，但還是把 < 轉掉
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func html(host: String) -> String {
        let strings = strings
        return #"""
<!doctype html>
<html lang="\#(L("remote.web.lang", "zh-CN"))"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="HomePlay">
<meta name="theme-color" content="#000000">
<meta name="format-detection" content="telephone=no">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon-180.png">
<title>HomePlay</title>
<style>
html,body{margin:0;height:100%;background:#000;color:#fff;overflow:hidden;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent;font-family:-apple-system,system-ui,'PingFang TC','PingFang SC',sans-serif;-webkit-text-size-adjust:100%}
body{position:fixed;inset:0;left:0;top:0;right:0;bottom:0;touch-action:none}
#stage{position:absolute;left:0;top:0;right:0;bottom:0;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
#screen{position:absolute;overflow:hidden;background:#000;touch-action:none}
#c{width:100%;height:100%;display:block}
#cover{position:absolute;left:0;top:0;right:0;bottom:0;display:none;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:12%;background:#000;gap:2.4vmin}
#cover b{font-size:5.4vmin;font-weight:700}#cover span{font-size:3vmin;color:rgba(255,255,255,.62);line-height:1.45}
#side{position:absolute;display:flex;flex-direction:column;justify-content:center;align-items:center;gap:1.2vmin;pointer-events:none}
#side.right{align-items:flex-start;padding-left:2vmin}
#clock{font-size:15vmin;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums;line-height:1}
#date{font-size:3.6vmin;color:rgba(255,255,255,.7);font-weight:600}
#conn{font-size:2.4vmin;color:rgba(255,255,255,.5);display:flex;align-items:center;gap:1vmin;margin-top:2vmin}
#dot{width:1.4vmin;height:1.4vmin;border-radius:50%;background:#ff9f0a}#dot.ok{background:#30d158}
#dim{position:fixed;left:0;top:0;right:0;bottom:0;background:#000;opacity:0;pointer-events:none;transition:opacity 10s ease}#dim.on{opacity:.62}
#pair{position:fixed;left:0;top:0;right:0;bottom:0;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.86);z-index:5;overflow:auto;-webkit-overflow-scrolling:touch;touch-action:auto}
#pair .card{width:min(560px,92vw);background:#1c1c1e;border-radius:28px;padding:28px 26px 22px;box-sizing:border-box}
#pair h1{margin:0 0 6px;font-size:26px}#pair p{margin:0 0 16px;color:rgba(255,255,255,.66);font-size:16px;line-height:1.45}
#pcode{width:100%;box-sizing:border-box;font:600 22px ui-monospace,Menlo,monospace;letter-spacing:.08em;text-transform:uppercase;padding:14px 16px;border-radius:14px;border:0;background:#2c2c2e;color:#fff;-webkit-user-select:text;user-select:text;outline:none}
#pgo{margin-top:12px;width:100%;min-height:50px;border:0;border-radius:25px;background:#0a84ff;color:#fff;font-size:18px;font-weight:600}
#perr{min-height:20px;margin-top:10px;color:#ff6961;font-size:15px}
#pair ol{margin:14px 0 0;padding:0;list-style:none;display:flex;flex-direction:column;gap:10px}
#pair li{background:#2c2c2e;border-radius:16px;padding:12px 14px;font-size:14px;color:rgba(255,255,255,.66);line-height:1.4}#pair li b{display:block;color:#fff;font-size:16px;margin-bottom:2px}
#pair small{display:block;margin-top:12px;color:rgba(255,255,255,.45);font-size:13px;line-height:1.4}
#tip{position:fixed;left:50%;bottom:calc(env(safe-area-inset-bottom) + 16px);transform:translateX(-50%);width:min(520px,90vw);display:none;background:rgba(44,44,46,.96);border-radius:18px;padding:12px 16px;font-size:15px;line-height:1.4;z-index:4}
#ka{position:fixed;width:1px;height:1px;opacity:.01;pointer-events:none;left:0;top:0}
</style></head><body>
<div id="stage">
<div id="screen"><canvas id="c" width="1024" height="1024"></canvas><div id="cover"><b>\#(esc(L("remote.web.coverTitle", "需要主人")))</b><span>\#(esc(L("remote.web.coverBody", "这台设备是访客：信息、照片、日历这些个人内容只在 Mac 上显示。")))</span></div></div>
<div id="side"><div id="clock"></div><div id="date"></div><div id="conn"><i id="dot"></i><span id="status"></span></div></div>
</div>
<div id="dim"></div>
<div id="tip">\#(esc(L("remote.step.home.body", "分享 › 添加到主屏幕，之后从那个图标打开就是全屏，没有地址栏。")))</div>
<div id="pair"><div class="card">
<h1>\#(esc(L("remote.web.pairTitle", "连接到 HomePlay")))</h1>
<p>\#(esc(L("remote.web.pairBody", "在 Mac 上打开 HomePlay 设置 › iPhone 与 iPad，输入那里的配对码。")))</p>
<input id="pcode" placeholder="XXXX-XXXX-XXXX-XXXX" autocomplete="off" autocorrect="off" autocapitalize="characters" spellcheck="false" maxlength="24" inputmode="text">
<button id="pgo">\#(esc(L("remote.web.pairButton", "配对")))</button>
<div id="perr"></div>
<ol>
<li><b>\#(esc(L("remote.step.home.title", "添加到主屏幕")))</b>\#(esc(L("remote.step.home.body", "分享 › 添加到主屏幕，之后从那个图标打开就是全屏，没有地址栏。")))</li>
<li><b>\#(esc(L("remote.step.lock.title", "自动锁定：永不")))</b>\#(esc(L("remote.step.lock.body", "设置 › 显示与亮度 › 自动锁定 › 永不。HomePlay 没人时自己会调暗，不怕整晚亮着。")))</li>
<li><b>\#(esc(L("remote.step.guided.title", "引导式访问（可选）")))</b>\#(esc(L("remote.step.guided.body", "设置 › 辅助功能 › 引导式访问，连按三下侧边按钮把它锁在 HomePlay 里，小孩乱点也跳不出去。")))</li>
</ol>
<small>\#(esc(L("remote.step.battery", "常年插电的旧电池会膨胀：新机型在「电池健康」设 80% 上限；旧机型接一个能排程断电的智能插座。")))</small>
</div></div>
<video id="ka" playsinline webkit-playsinline muted loop autoplay src="data:video/mp4;base64,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bWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTQgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjIwAIAAAAAPZYiEBfOf//8PRQABV5+AARggBwEYIAcBGCAHARggBwEYIAcBGCAHARggBwEYIAcAAAAHQZo4C+c6gAEYIAcBGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAH"></video>
<script>var S = \#(strings);</script>
<script>
\#(cryptoJS)
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var cv = $('c'), g = cv.getContext('2d'), screenEl = $('screen'), stage = $('stage');
  var standalone = !!(window.navigator.standalone || (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches));
  var creds = null, ws = null, key = null, rx = 0, tx = 0, phase = 'idle', kind = 0, nonceC = null, handoff = null, handoffTimer = null;
  var earlyCloses = 0, retry = 0, pairCode = null, lastTouch = Date.now(), dimmed = false;
  var inputN = 0, pending = null, guest = true;

  // ---------- small helpers (ES5, no TextEncoder on iOS < 10.3) ----------
  function utf8(s) { var b = unescape(encodeURIComponent(s)), a = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) a[i] = b.charCodeAt(i); return a; }
  function unutf8(a) { var s = ''; for (var i = 0; i < a.length; i += 4096) s += String.fromCharCode.apply(null, a.subarray(i, Math.min(a.length, i + 4096))); return decodeURIComponent(escape(s)); }
  function rand(n) { var a = new Uint8Array(n); if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(a); else for (var i = 0; i < n; i++) a[i] = Math.floor(Math.random() * 256); return a; }
  function b64d(s) { var b = atob(s), a = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) a[i] = b.charCodeAt(i); return a; }
  function hexd(s) { var a = new Uint8Array(s.length / 2); for (var i = 0; i < a.length; i++) a[i] = parseInt(s.substr(2 * i, 2), 16); return a; }
  var ALPHA = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  function codeBytes(s) {
    var out = [], acc = 0, bits = 0; s = s.toUpperCase();
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i); if (ch === '-' || ch === ' ') continue;
      if (ch === 'O') ch = '0'; if (ch === 'I' || ch === 'L') ch = '1';
      var v = ALPHA.indexOf(ch); if (v < 0) return null;
      acc = (acc << 5) | v; bits += 5;
      if (bits >= 8) { bits -= 8; out.push((acc >> bits) & 255); }
      acc &= (1 << bits) - 1;
    }
    return out.length === 10 ? out : null;
  }
  // handoff token: 24 bytes = 8-byte lookup id + 16-byte secret, base32 (39 chars)
  function tokenBytes(s) {
    var out = [], acc = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
      var v = ALPHA.indexOf(s.charAt(i)); if (v < 0) return null;
      acc = (acc << 5) | v; bits += 5;
      if (bits >= 8) { bits -= 8; out.push((acc >> bits) & 255); }
      acc &= (1 << bits) - 1;
    }
    return out.length === 24 ? out : null;
  }
  function nonce(dir, n) { var a = new Uint8Array(12); a[0] = dir; for (var i = 0; i < 6; i++) { a[4 + i] = n % 256; n = Math.floor(n / 256); } return a; }
  function store(k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} }
  function load(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }

  // ---------- credentials: localStorage only. The long-term key never goes into the URL or history.
  // Add to Home Screen keeps the address, so while open in Safari the page puts a one-time handoff token (#t=, 60 s,
  // issued by the Mac) there; the home-screen copy trades it for the key once, then forgets it. ----------
  function clearHash() { if (window.history && history.replaceState) history.replaceState(null, '', location.pathname + location.search); }
  function readCreds() {
    var h = location.hash || '';
    try { creds = JSON.parse(load('hp.dev') || 'null'); } catch (e) { creds = null; }
    var p = h.match(/[#&]p=([0-9A-Za-z\-]+)/), t = h.match(/[#&]t=([0-9A-Z]{39})/);
    if (p && !creds) pairCode = p[1];
    if (t && !creds && tokenBytes(t[1])) handoff = t[1];
    if (h.length > 1) clearHash();   // codes, tokens (and old #d= links) never stay in the address bar
  }
  function saveCreds(c) {
    creds = c; store('hp.dev', c ? JSON.stringify(c) : null);
  }
  // in Safari (not the home-screen copy): keep a fresh handoff token in the address for Add to Home Screen
  function askHandoff() { if (!standalone && creds && key && kind === 0x44) sendJSON({ t: 'h' }); }

  // ---------- layout (IdleLayouts: square on top / on the left, the rest is a big clock) ----------
  function layout() {
    var W = window.innerWidth, H = window.innerHeight, side = $('side'), s, x, y;
    side.className = '';
    if (H > W * 1.15) { s = Math.min(W - 24, H * 0.7); x = (W - s) / 2; y = Math.max(12, Math.min((W - s) / 2, 40));
      side.style.cssText = 'left:0;right:0;top:' + (y + s + 16) + 'px;bottom:0'; side.className = 'below'; }
    else if (W > H * 1.15) { s = Math.min(H - 24, W * 0.64); y = (H - s) / 2; x = Math.max(12, y);
      side.style.cssText = 'top:0;bottom:0;left:' + (x + s + 16) + 'px;right:0'; side.className = 'right'; }
    else { s = Math.min(W, H) - 24; x = (W - s) / 2; y = (H - s) / 2; side.style.cssText = 'display:none'; }
    screenEl.style.cssText = 'left:' + x + 'px;top:' + y + 'px;width:' + s + 'px;height:' + s + 'px;border-radius:' + (s * 138 / 1024) + 'px';
  }
  window.addEventListener('resize', layout); window.addEventListener('orientationchange', function () { setTimeout(layout, 300); });

  // ---------- clock, burn-in shift, dimming ----------
  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function clock() {
    var d = new Date();
    $('clock').textContent = d.getHours() + ':' + pad(d.getMinutes());
    try { $('date').textContent = d.toLocaleDateString(S.lang, { weekday: 'long', month: 'long', day: 'numeric' }); } catch (e) { $('date').textContent = d.toDateString(); }
    if (!dimmed && Date.now() - lastTouch > 10 * 60 * 1000) { dimmed = true; $('dim').className = 'on'; }
  }
  setInterval(clock, 5000);
  setInterval(function () { stage.style.transform = 'translate(' + (Math.round(Math.random() * 4) - 2) + 'px,' + (Math.round(Math.random() * 4) - 2) + 'px)'; }, 180000);

  function status(text, ok) { $('status').textContent = text; $('dot').className = ok ? 'ok' : ''; }

  // ---------- keep the screen awake: Wake Lock where it works, a muted looping video everywhere else ----------
  var lock = null;
  function keepAwake() {
    try { if (navigator.wakeLock && window.isSecureContext && !lock) navigator.wakeLock.request('screen').then(function (l) { lock = l; l.addEventListener('release', function () { lock = null; }); }, function () {}); } catch (e) {}
    var v = $('ka'); try { var p = v.play(); if (p && p.catch) p.catch(function () {}); } catch (e) {}
  }
  document.addEventListener('visibilitychange', function () { if (!document.hidden) { keepAwake(); if (ws) { try { ws.close(); } catch (e) {} } else connect(); } });  // after sleep the old socket may be a zombie: always resync

  // ---------- socket ----------
  function sendRaw(bytes) { if (ws && ws.readyState === 1) ws.send(bytes.buffer ? bytes.buffer : bytes); }
  function sendJSON(o) { if (!key) return; sendRaw(HPC.seal(key, nonce(0, tx++), utf8(JSON.stringify(o)))); }

  function connect() {
    if (ws) return;
    if (!creds && !pairCode && !handoff) { showPair(); return; }
    kind = creds ? 0x44 : (handoff ? 0x54 : 0x50); key = null; rx = 0; tx = 0; phase = 'open';
    try { ws = new WebSocket('ws://' + location.host + '/ws'); } catch (e) { ws = null; return later(); }
    ws.binaryType = 'arraybuffer';
    var opened = false, gotOk = false;
    ws.onopen = function () {
      opened = true; nonceC = rand(6);
      var h = new Uint8Array(17); h[0] = 0x48; h[1] = 1; h[2] = kind;
      if (creds) h.set(hexd(creds.id), 3);
      else if (kind === 0x54) h.set(tokenBytes(handoff).slice(0, 8), 3);
      h.set(nonceC, 11); sendRaw(h); phase = 'hello';
    };
    ws.onmessage = function (ev) {
      var b = new Uint8Array(ev.data);
      if (phase === 'hello') {
        if (b.length !== 8 || b[0] !== 0x48) { ws.close(); return; }
        var n = new Uint8Array(12); n.set(nonceC, 0); n.set(b.subarray(2, 8), 6);
        var lk;
        if (kind === 0x50) { var cb = codeBytes(pairCode || ''); if (!cb) { ws.close(); return; } lk = new Uint8Array(32); lk.set(cb, 0); }
        else if (kind === 0x54) { var tb = tokenBytes(handoff || ''); if (!tb) { ws.close(); return; } lk = new Uint8Array(32); lk.set(tb.slice(8, 24), 0); }
        else lk = b64d(creds.key);
        key = HPC.derive(lk, n);
        phase = 'live';
        if (kind === 0x50) sendJSON({ t: 'pair', name: deviceName() });
        else if (kind === 0x54) sendJSON({ t: 'claim' });
        else sendJSON({ t: 'hi', v: 1, w: screen.width, h: screen.height, st: standalone });
        return;
      }
      var p = HPC.open(key, nonce(1, rx++), b);
      if (!p) { ws.close(); return; }
      if (p[0] === 0x7b) {
        var o = JSON.parse(unutf8(p));
        if (o.t === 'paired') { var wasPairing = kind === 0x50; pairCode = null; handoff = null; saveCreds({ id: o.id, key: o.key }); hidePair(); if (!standalone && wasPairing) showTip(); }
        else if (o.t === 'ok') {
          gotOk = true; earlyCloses = 0; retry = 0; guest = o.guest; status(S.connected.replace('%@', o.mac), true); hidePair();
          askHandoff(); if (!standalone && !handoffTimer) handoffTimer = setInterval(askHandoff, 45000);
        }
        else if (o.t === 'handoff') { if (!standalone && window.history && history.replaceState && /^[0-9A-Z]{39}$/.test(o.tok)) history.replaceState(null, '', '#t=' + o.tok); }
        else if (o.t === 'cover') { $('cover').style.display = o.on ? 'flex' : 'none'; if (o.on) { g.fillStyle = '#000'; g.fillRect(0, 0, 1024, 1024); } }
      } else if (p[0] === 0x46) frame(p);
    };
    ws.onclose = function () {
      var wasPair = kind === 0x50;
      ws = null; key = null;
      if (kind === 0x54 && handoff) { handoff = null; if (!creds) { showPair(S.handoffExpired); return; } }
      if (wasPair && pairCode) {
        // the code was wrong, used or expired
        if (opened) { pairCode = null; showPair(S.badCode); return; }
      }
      if (!wasPair && opened && !gotOk && ++earlyCloses >= 2) { saveCreds(null); showPair(S.removed); return; }
      status(opened ? S.reconnecting : S.unreachable, false);
      later();
    };
  }
  function later() { retry = Math.min(retry + 1, 6); setTimeout(connect, [500, 1000, 2000, 4000, 6000, 8000, 10000][retry]); }

  // ---------- frames: patches of JPEG, drawn together, then ack ----------
  function frame(p) {
    var dv = new DataView(p.buffer, p.byteOffset, p.byteLength), seq = dv.getUint32(1, true), inAck = dv.getUint32(5, true), n = dv.getUint16(9, true);
    var off = 11, parts = [], left = n, t0 = Date.now();
    function done() {
      for (var i = 0; i < parts.length; i++) if (parts[i].img) g.drawImage(parts[i].img, parts[i].x, parts[i].y, parts[i].w, parts[i].h);
      sendJSON({ t: 'a', s: seq, d: Date.now() - t0 });   // the Mac only counts an ack for the frame it just sent
      if (pending && inAck >= pending.n) { sendJSON({ t: 'l', v: Date.now() - pending.t }); pending = null; }
    }
    if (!n) { done(); return; }
    for (var i = 0; i < n; i++) {
      var part = { x: dv.getUint16(off, true), y: dv.getUint16(off + 2, true), w: dv.getUint16(off + 4, true), h: dv.getUint16(off + 6, true) };
      var len = dv.getUint32(off + 8, true); off += 12;
      var url = URL.createObjectURL(new Blob([p.subarray(off, off + len)], { type: 'image/jpeg' })); off += len;
      var img = new Image();
      img.onload = img.onerror = (function (part, img, url) { return function (e) { URL.revokeObjectURL(url); if (e.type === 'load') part.img = img; if (--left === 0) done(); }; })(part, img, url);
      parts.push(part); img.src = url;
    }
  }

  // ---------- touch → Mac (0–1024 canvas points) ----------
  var active = null, lastMove = 0;
  function pt(x, y) { var r = cv.getBoundingClientRect(); return { x: Math.round((x - r.left) / r.width * 1024), y: Math.round((y - r.top) / r.height * 1024) }; }
  function wake() { lastTouch = Date.now(); keepAwake(); if (dimmed) { dimmed = false; $('dim').className = ''; return true; } return false; }
  function input(k, q) { inputN++; if (k !== 'm') pending = { n: inputN, t: Date.now() }; sendJSON({ t: 'i', k: k, x: q.x, y: q.y, n: inputN }); }
  function down(x, y, id) { if (active !== null) return; if (wake()) { active = -1; return; } active = id; input('d', pt(x, y)); }
  function move(x, y, id) { if (active !== id) return; var now = Date.now(); if (now - lastMove < 16) return; lastMove = now; input('m', pt(x, y)); }
  function up(x, y, id) { if (active !== id && active !== -1) return; var a = active; active = null; if (a !== -1) input('u', pt(x, y)); }
  function first(e) { return e.changedTouches[0]; }
  screenEl.addEventListener('touchstart', function (e) { e.preventDefault(); var t = first(e); down(t.clientX, t.clientY, t.identifier); }, false);
  screenEl.addEventListener('touchmove', function (e) { e.preventDefault(); for (var i = 0; i < e.changedTouches.length; i++) { var t = e.changedTouches[i]; move(t.clientX, t.clientY, t.identifier); } }, false);
  function end(e) { e.preventDefault(); for (var i = 0; i < e.changedTouches.length; i++) { var t = e.changedTouches[i]; if (t.identifier === active || active === -1) up(t.clientX, t.clientY, active); } }
  screenEl.addEventListener('touchend', end, false); screenEl.addEventListener('touchcancel', end, false);
  var mouseDown = false;
  screenEl.addEventListener('mousedown', function (e) { mouseDown = true; down(e.clientX, e.clientY, 'm'); });
  window.addEventListener('mousemove', function (e) { if (mouseDown) move(e.clientX, e.clientY, 'm'); });
  window.addEventListener('mouseup', function (e) { if (mouseDown) { mouseDown = false; up(e.clientX, e.clientY, 'm'); } });
  var nopass = false;
  try { window.addEventListener('test', null, Object.defineProperty({}, 'passive', { get: function () { nopass = { passive: false }; return true; } })); } catch (e) {}
  document.addEventListener('touchmove', function (e) { if (e.target.tagName !== 'INPUT') e.preventDefault(); }, nopass);
  document.addEventListener('touchstart', function () { if (wake()) {} }, false);

  // ---------- pairing sheet ----------
  function deviceName() {
    var ua = navigator.userAgent, m, v = '';
    var pad2 = /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
    if ((m = ua.match(/OS (\d+)_(\d+)/)) && !/Mac OS X/.test(ua)) v = m[1] + '.' + m[2]; else if ((m = ua.match(/Version\/(\d+(\.\d+)?)/))) v = m[1];
    if (pad2) return 'iPad · iPadOS ' + v;
    if (/iPhone|iPod/.test(ua)) return 'iPhone · iOS ' + v;
    return 'Safari ' + v;
  }
  function showPair(msg) {
    $('pair').style.display = 'flex'; $('perr').textContent = msg || ''; status(S.notPaired, false);
  }
  function hidePair() { $('pair').style.display = 'none'; }
  function showTip() { var t = $('tip'); t.style.display = 'block'; setTimeout(function () { t.style.display = 'none'; }, 15000); }
  $('pgo').addEventListener('click', function () {
    var v = $('pcode').value;
    if (!codeBytes(v)) { $('perr').textContent = S.badFormat; return; }
    pairCode = v; $('perr').textContent = ''; keepAwake(); connect();
  });
  $('pcode').addEventListener('keydown', function (e) { if (e.keyCode === 13) $('pgo').click(); });
  $('tip').addEventListener('click', function () { $('tip').style.display = 'none'; });

  readCreds(); layout(); clock();
  status(S.connecting, false);
  connect();
})();

</script>
</body></html>
"""#
    }

    /// ChaCha20-Poly1305 的 JavaScript（--selftest 在 JavaScriptCore 裡跑，跟 CryptoKit 逐位元組比）
    static let cryptoJS = #"""
var HPC = (function () {
  // ChaCha20-Poly1305 (RFC 8439), ES5 only, so iOS 9+ Safari can run it without WebCrypto (plain-http pages have no crypto.subtle).
  var SIGMA = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574];
  function words(b, off, n) { var w = new Array(n); for (var i = 0; i < n; i++) { var o = off + 4 * i; w[i] = (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) | 0; } return w; }
  function block(kw, ctr, nw, out) {
    var j = [SIGMA[0], SIGMA[1], SIGMA[2], SIGMA[3], kw[0], kw[1], kw[2], kw[3], kw[4], kw[5], kw[6], kw[7], ctr | 0, nw[0], nw[1], nw[2]];
    var x = j.slice(0);
    function q(a, b, c, d) {
      var t;
      x[a] = (x[a] + x[b]) | 0; t = x[d] ^ x[a]; x[d] = (t << 16) | (t >>> 16);
      x[c] = (x[c] + x[d]) | 0; t = x[b] ^ x[c]; x[b] = (t << 12) | (t >>> 20);
      x[a] = (x[a] + x[b]) | 0; t = x[d] ^ x[a]; x[d] = (t << 8) | (t >>> 24);
      x[c] = (x[c] + x[d]) | 0; t = x[b] ^ x[c]; x[b] = (t << 7) | (t >>> 25);
    }
    for (var i = 0; i < 10; i++) {
      q(0, 4, 8, 12); q(1, 5, 9, 13); q(2, 6, 10, 14); q(3, 7, 11, 15);
      q(0, 5, 10, 15); q(1, 6, 11, 12); q(2, 7, 8, 13); q(3, 4, 9, 14);
    }
    for (var k = 0; k < 16; k++) {
      var v = (x[k] + j[k]) | 0;
      out[4 * k] = v & 255; out[4 * k + 1] = (v >>> 8) & 255; out[4 * k + 2] = (v >>> 16) & 255; out[4 * k + 3] = (v >>> 24) & 255;
    }
  }
  function xorStream(key, nonce, ctr, src, dst) {
    var kw = words(key, 0, 8), nw = words(nonce, 0, 3), ks = new Uint8Array(64);
    for (var off = 0; off < src.length; off += 64, ctr++) {
      block(kw, ctr, nw, ks);
      var n = Math.min(64, src.length - off);
      for (var i = 0; i < n; i++) dst[off + i] = src[off + i] ^ ks[i];
    }
  }
  function add1305(h, c) { var u = 0; for (var j = 0; j < 17; j++) { u += h[j] + c[j]; h[j] = u & 255; u >>>= 8; } }
  var MINUSP = [5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 252];
  function poly1305(m, k) {
    var r = new Array(17), h = new Array(17), c = new Array(17), x = new Array(17), g = new Array(17), i, j, u, s;
    for (j = 0; j < 17; j++) { r[j] = 0; h[j] = 0; }
    for (j = 0; j < 16; j++) r[j] = k[j];
    r[3] &= 15; r[4] &= 252; r[7] &= 15; r[8] &= 252; r[11] &= 15; r[12] &= 252; r[15] &= 15;
    var p = 0, n = m.length;
    while (n > 0) {
      for (j = 0; j < 17; j++) c[j] = 0;
      for (j = 0; j < 16 && j < n; j++) c[j] = m[p + j];
      c[j] = 1; p += j; n -= j;
      add1305(h, c);
      for (i = 0; i < 17; i++) {
        var acc = 0;
        for (j = 0; j < 17; j++) acc += h[j] * (j <= i ? r[i - j] : 320 * r[i + 17 - j]);
        x[i] = acc;
      }
      for (i = 0; i < 17; i++) h[i] = x[i];
      u = 0;
      for (j = 0; j < 16; j++) { u += h[j]; h[j] = u & 255; u = Math.floor(u / 256); }
      u += h[16]; h[16] = u & 3;
      u = 5 * Math.floor(u / 4);
      for (j = 0; j < 16; j++) { u += h[j]; h[j] = u & 255; u = Math.floor(u / 256); }
      u += h[16]; h[16] = u;
    }
    for (j = 0; j < 17; j++) g[j] = h[j];
    add1305(h, MINUSP);
    s = -(h[16] >>> 7);
    for (j = 0; j < 17; j++) h[j] ^= s & (g[j] ^ h[j]);
    for (j = 0; j < 16; j++) c[j] = k[j + 16];
    c[16] = 0;
    add1305(h, c);
    var out = new Uint8Array(16);
    for (j = 0; j < 16; j++) out[j] = h[j];
    return out;
  }
  function tag(otk, ct, len) {
    var padded = (len + 15) & ~15, mac = new Uint8Array(padded + 16);
    for (var i = 0; i < len; i++) mac[i] = ct[i];
    var l = len;
    for (var b = 0; b < 4; b++) { mac[padded + 8 + b] = l & 255; l = l >>> 8; }
    return poly1305(mac, otk);
  }
  function otkey(key, nonce) { var o = new Uint8Array(64); block(words(key, 0, 8), 0, words(nonce, 0, 3), o); return o.subarray(0, 32); }
  return {
    seal: function (key, nonce, pt) {
      var out = new Uint8Array(pt.length + 16);
      xorStream(key, nonce, 1, pt, out);
      out.set(tag(otkey(key, nonce), out, pt.length), pt.length);
      return out;
    },
    open: function (key, nonce, data) {
      if (data.length < 16) return null;
      var len = data.length - 16, t = tag(otkey(key, nonce), data, len), d = 0;
      for (var i = 0; i < 16; i++) d |= t[i] ^ data[len + i];
      if (d !== 0) return null;
      var pt = new Uint8Array(len);
      xorStream(key, nonce, 1, data.subarray(0, len), pt);
      return pt;
    },
    // session key = first 32 bytes of ChaCha20 keystream block 1 (same as CryptoKit sealing 32 zero bytes)
    derive: function (key, nonce) { var o = new Uint8Array(64); block(words(key, 0, 8), 1, words(nonce, 0, 3), o); return o.subarray(0, 32); }
  };
})();
"""#

    static let manifest = ##"{"name":"HomePlay","short_name":"HomePlay","display":"standalone","background_color":"#000000","theme_color":"#000000","orientation":"any","icons":[{"src":"/icon-180.png","sizes":"180x180","type":"image/png"},{"src":"/icon-512.png","sizes":"512x512","type":"image/png"}]}"##

    /// 主畫面圖示：黑底上的 👀（我們的眼睛，不換樣子）。主執行緒先畫好（prepareIcons），伺服器佇列只讀
    nonisolated(unsafe) private static var icons: [Int: Data] = [:]

    static func prepareIcons() {
        for s in [180, 512] where icons[s] == nil {
            let img = makeImage(s, s) { g in
                g.setFillColor(CGColor(gray: 0, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: s, height: s))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
                let str = NSAttributedString(string: "👀", attributes: [.font: NSFont.systemFont(ofSize: CGFloat(s) * 0.46)])
                let sz = str.size()
                str.draw(at: NSPoint(x: (CGFloat(s) - sz.width) / 2, y: (CGFloat(s) - sz.height) / 2))
                NSGraphicsContext.restoreGraphicsState()
            }
            icons[s] = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        }
    }

    static func icon(_ s: Int) -> Data { icons[s] ?? Data() }
}
