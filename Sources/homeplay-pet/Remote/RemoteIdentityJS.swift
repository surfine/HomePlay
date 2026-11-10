// 裝置端的身分程式（兩頁共用：Remote/RemotePage.swift 的鏡像頁、SideShow/SideShowPage.swift 的副屏頁）。
//
// 私鑰只活在裝置的 IndexedDB（非可匯出，Safari 也讀不出明文）；Mac 只拿得到公鑰。
// 所以「金鑰」這個東西再也沒有從 Mac 傳到裝置的一天，名冊被讀走也冒充不了。
//
// 需要 Safari 11 以上的 WebCrypto（P-256 ECDH＋ECDSA）——iOS 15 的舊 iPad 也夠。

enum RemoteIdentityJS {
    static let source = #"""
var HPI = (function () {
  var DB = 'hp-identity', ST = 'keys', mem = null;
  function open() {
    return new Promise(function (res, rej) {
      var r = indexedDB.open(DB, 1);
      r.onupgradeneeded = function () { r.result.createObjectStore(ST); };
      r.onsuccess = function () { res(r.result); };
      r.onerror = function () { rej(r.error); };
    });
  }
  function get(k) {
    return open().then(function (db) {
      return new Promise(function (res, rej) {
        var q = db.transaction(ST, 'readonly').objectStore(ST).get(k);
        q.onsuccess = function () { res(q.result); }; q.onerror = function () { rej(q.error); };
      });
    }).catch(function () { return mem ? mem[k] : null; });
  }
  function put(k, v) {
    return open().then(function (db) {
      return new Promise(function (res, rej) {
        var q = db.transaction(ST, 'readwrite').objectStore(ST).put(v, k);
        q.onsuccess = function () { res(v); }; q.onerror = function () { rej(q.error); };
      });
    }).catch(function () { mem = mem || {}; mem[k] = v; return v; });
  }
  function del(k) {
    return open().then(function (db) {
      return new Promise(function (res) { var q = db.transaction(ST, 'readwrite').objectStore(ST).delete(k); q.onsuccess = res; q.onerror = res; });
    }).catch(function () { if (mem) delete mem[k]; });
  }
  function b64(u8) { var s = ''; for (var i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]); return btoa(s); }
  function u8(b) { var s = atob(b), a = new Uint8Array(s.length); for (var i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; }
  function join(parts) {
    var n = 0, i; for (i = 0; i < parts.length; i++) n += parts[i].length + 1;
    var o = new Uint8Array(n), p = 0;
    for (i = 0; i < parts.length; i++) { o.set(parts[i], p); p += parts[i].length; o[p++] = 0; }
    return o;
  }
  function enc(s) { return new TextEncoder().encode(s); }

  var state = null;
  function load() {
    if (state) return Promise.resolve(state);
    return Promise.all([get('id'), get('agree'), get('sign')]).then(function (r) {
      if (!r[0] || !r[1] || !r[2]) return null;
      state = { id: r[0], agree: r[1], sign: r[2] };
      return state;
    });
  }

  // 第一次打開（或重新配對）：產生兩把非可匯出的 P-256 金鑰，公鑰匯出成 raw 65 bytes
  function make() {
    return Promise.all([
      crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']),
      crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
    ]).then(function (ks) {
      return Promise.all([crypto.subtle.exportKey('raw', ks[0].publicKey), crypto.subtle.exportKey('raw', ks[1].publicKey)])
        .then(function (pub) {
          state = { agree: ks[0].privateKey, sign: ks[1].privateKey, pubAgree: b64(new Uint8Array(pub[0])), pubSign: b64(new Uint8Array(pub[1])) };
          return Promise.all([put('agree', state.agree), put('sign', state.sign)]).then(function () { return state; });
        });
    });
  }

  // 配對：把公鑰交給 Mac，換回自己的 id（沒有祕密回來）
  function pair(code, mode, name) {
    return make().then(function (s) {
      return fetch('/pair', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code: code, mode: mode, name: name, agree: s.pubAgree, sign: s.pubSign })
      });
    }).then(function (r) {
      if (!r.ok) throw new Error('pair ' + r.status);
      return r.json();
    }).then(function (o) {
      state.id = o.id;
      return put('id', o.id).then(function () { return o.id; });
    });
  }

  function sign(bytes) {
    return load().then(function (s) {
      if (!s) throw new Error('no identity');
      return crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, s.sign, bytes);
    }).then(function (sig) { return new Uint8Array(sig); });
  }

  // 跟 Mac 的臨時金鑰算 ECDH：32 bytes 的秘密，兩邊再走同一條 ChaCha20 KDF
  function ecdh(peerRaw) {
    return load().then(function (s) {
      if (!s) throw new Error('no identity');
      return crypto.subtle.importKey('raw', peerRaw, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
    }).then(function (pub) {
      return crypto.subtle.deriveBits({ name: 'ECDH', public: pub }, state.agree, 256);
    }).then(function (bits) { return new Uint8Array(bits); });
  }

  function streamTranscript(kind, id, nonceC, ephS, nonceS) {
    return join([enc('HomePlay stream v2'), new Uint8Array([kind]), enc(id), nonceC, ephS, nonceS]);
  }
  function sideTranscript(id, at) {
    return join([enc('HomePlay side v2'), enc(id), enc(String(Math.round(at)))]);
  }

  function forget() { state = null; return Promise.all([del('id'), del('agree'), del('sign')]); }

  return {
    load: load, pair: pair, sign: sign, ecdh: ecdh, forget: forget,
    streamTranscript: streamTranscript, sideTranscript: sideTranscript,
    b64: b64, u8: u8, ready: function () { return typeof crypto !== 'undefined' && !!(crypto.subtle); }
  };
})();
"""#
}
