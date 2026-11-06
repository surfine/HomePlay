// SideShow 裝置上打開的那一頁（單一 HTML，ES5：舊 iPad 的 Safari 也跑得動）。
//
// - 版面照 HPDS：-apple-system 字、系統色、深色底（裝置是淺色外觀就換淺色 token）；橫放＝左邊大時鐘、右邊一欄卡片，直放＝時鐘在上。
// - 尊重減少動態效果（進度條不滑）、減少透明度（卡片改實色）、增加對比（次要字變亮、卡片加框）、深淺色。
// - 資料：每 10 秒問一次 /api/state（帶金鑰）；最後一份存在 localStorage，Mac 睡了或斷線照樣顯示，底下標「上次更新 HH:mm」。
//   401＝這台被移除了：清掉金鑰與內容，回到配對畫面。
// - 離線打開：service worker 只在安全來源（https、localhost）註冊得了，區網的 http 頁拿不到；舊 Safari 另外有 AppCache 頂著。
// - 「加入主畫面」：iOS 主畫面上的網頁 App 跟 Safari 不共用 localStorage，所以在 Safari 掃碼打開時先不兌換配對碼，
//   教使用者先加入主畫面、從主畫面打開才兌換；也可以按「在這裡使用」直接在 Safari 用。
// - 介面文字三語一起送，網頁照裝置的系統語言挑（跟 PetLanguage.fromSystem 同一套規則）。

import AppKit

enum SideShowPage {
    /// 三語字串。closure 的參數故意叫 L：原始碼裡每一筆都是 L("鍵", "简体原文")，tooling/check-localizable.py 照樣查得到，
    /// 執行時換成「指定語言查譯文」，一次產出 en／zh-Hans／zh-Hant 三份。
    private static let table: ((String, String) -> String) -> [String: String] = { L in [
        "lang": L("sideshow.web.lang", "zh-CN"),
        "connected": L("sideshow.web.connected", "已连接"),
        "lastUpdate": L("sideshow.web.lastUpdate", "上次更新 %@"),
        "asleep": L("sideshow.web.asleep", "Mac 可能睡着了，或不在同一个 Wi‑Fi"),
        "nothing": L("sideshow.web.nothing", "现在没有要显示的内容"),
        "nowPlaying": L("sideshow.web.nowPlaying", "正在播放"),
        "paused": L("sideshow.web.paused", "已暂停"),
        "timers": L("sb.widget.timers", "计时器"),
        "next": L("sb.opt.upNext", "下一个日程"),
        "today": L("sideshow.web.today", "今天"),
        "tomorrow": L("sideshow.web.tomorrow", "明天"),
        "allDay": L("sideshow.web.allDay", "全天"),
        "weather": L("shell.weather.title", "天气"),
        "hiLo": L("weather.hiLo", "高 %d° 低 %d°"),
        "c0": L("weather.cond.clear", "晴"),
        "c1": L("weather.cond.mostlyClear", "大致晴朗"),
        "c2": L("weather.cond.partly", "晴时多云"),
        "c3": L("weather.cond.cloudy", "阴"),
        "c45": L("weather.cond.fog", "雾"),
        "c51": L("weather.cond.drizzle", "毛毛雨"),
        "c56": L("weather.cond.freezingDrizzle", "冻毛毛雨"),
        "c61": L("weather.cond.rain", "雨"),
        "c65": L("weather.cond.heavyRain", "大雨"),
        "c66": L("weather.cond.freezingRain", "冻雨"),
        "c71": L("weather.cond.snow", "雪"),
        "c75": L("weather.cond.heavySnow", "大雪"),
        "c80": L("weather.cond.showers", "阵雨"),
        "c85": L("weather.cond.snowShowers", "阵雪"),
        "c95": L("weather.cond.storm", "雷雨"),
        "c96": L("weather.cond.hail", "冰雹"),
        "a.smoke": L("home.alert.smoke", "烟雾"),
        "a.co": L("home.alert.co", "一氧化碳"),
        "a.co2": L("home.alert.co2", "二氧化碳"),
        "a.leak": L("home.alert.leak", "漏水"),
        "a.security": L("home.alert.security", "家庭安防"),
        "b.smoke": L("home.alert.smoke.body", "检测到%@有烟雾"),
        "b.co": L("home.alert.co.body", "检测到%@有一氧化碳"),
        "b.co2": L("home.alert.co2.body", "检测到%@有二氧化碳"),
        "b.leak": L("home.alert.leak.body", "检测到%@漏水"),
        "b.security": L("home.alert.security.body", "%@被打开"),
        "pairHow": L("sideshow.web.pairHow", "在 Mac 的 HomePlay 里打开“设置 › SideShow › 添加设备”，用相机扫描屏幕上的二维码。"),
        "pairManual": L("sideshow.web.pairManual", "也可以输入配对码"),
        "pairButton": L("sideshow.web.pairButton", "配对"),
        "pairing": L("sideshow.web.pairing", "正在配对…"),
        "addToHome": L("sideshow.web.addToHome", "先把这一页添加到主屏幕：轻点分享按钮，选“添加到主屏幕”，再从主屏幕打开它完成配对。这样 Mac 睡着时也能显示最后的内容。"),
        "useHere": L("sideshow.web.useHere", "在这里使用"),
        "badCode": L("sideshow.web.badCode", "配对码不对或已失效，请在 Mac 上重新添加设备"),
        "blocked": L("sideshow.web.blocked", "试错太多次了，请在 Mac 上重新添加设备"),
        "full": L("sideshow.web.full", "已配对的设备太多了，请先在 Mac 上移除不用的"),
        "unreachable": L("sideshow.web.unreachable", "连不上 Mac：它要醒着，而且在同一个 Wi‑Fi"),
        "removed": L("sideshow.web.removed", "这台设备已被移除，请重新配对"),
    ] }

    /// 三語 JSON（</script> 不可能出現，但還是把 < 轉掉）
    static var strings: String {
        var all: [String: [String: String]] = [:]
        for lang in PetLanguage.allCases { all[lang.rawValue] = table { k, s in L10n.text(k, s, in: lang) } }
        let data = (try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// 頁面內容變了 AppCache 才會重抓：版本號＝頁面的雜湊
    static let version: String = String(SideShowCrypto.hex(SideShowCrypto.sha256(html)).prefix(12))

    static let html: String = body

    static let manifest = ##"{"name":"SideShow","short_name":"SideShow","start_url":"/","display":"standalone","background_color":"#000000","theme_color":"#000000","orientation":"any","icons":[{"src":"/icon-180.png","sizes":"180x180","type":"image/png"},{"src":"/icon-512.png","sizes":"512x512","type":"image/png"}]}"##

    static let appCache: String = { "CACHE MANIFEST\n# \(version)\n/\n/icon-180.png\n\nNETWORK:\n*\n" }()

    /// 只快取頁面殼與圖示；/api/ 永遠走網路（帶金鑰、不能進快取）
    static let serviceWorker = #"""
var C='sideshow-v1';
self.addEventListener('install',function(e){e.waitUntil(caches.open(C).then(function(c){return c.addAll(['/','/icon-180.png']);}));self.skipWaiting();});
self.addEventListener('activate',function(e){e.waitUntil(self.clients.claim());});
self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(e.request.method!=='GET'||u.pathname.indexOf('/api/')===0)return;
e.respondWith(fetch(e.request).then(function(r){var k=r.clone();caches.open(C).then(function(c){c.put(e.request,k);});return r;}).catch(function(){return caches.match(e.request).then(function(m){return m||caches.match('/');});}));});
"""#

    static func icon(_ s: Int) -> Data { RemotePage.icon(s) }

    private static var body: String {
        let strings = strings
        return #"""
<!doctype html>
<html lang="en" manifest="/sideshow.appcache"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="SideShow">
<meta name="theme-color" content="#000000">
<meta name="format-detection" content="telephone=no">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon-180.png">
<title>SideShow</title>
<style>
:root{--bg:#000;--card:rgba(28,28,30,.82);--card2:#2C2C2E;--label:#fff;--sec:rgba(235,235,245,.6);--ter:rgba(235,235,245,.3);--red:#FF4245;--green:#30D158;--orange:#FF9230;--blue:#0091FF;--edge:transparent}
@media (prefers-color-scheme: light){:root{--bg:#F2F2F7;--card:rgba(255,255,255,.86);--card2:#E5E5EA;--label:#000;--sec:rgba(60,60,67,.6);--ter:rgba(60,60,67,.3);--red:#FF383C;--green:#34C759;--orange:#FF8D28;--blue:#0088FF}}
@media (prefers-reduced-transparency: reduce){:root{--card:#1C1C1E}}
@media (prefers-reduced-transparency: reduce) and (prefers-color-scheme: light){:root{--card:#fff}}
@media (prefers-contrast: more){:root{--sec:rgba(235,235,245,.85);--edge:rgba(255,255,255,.5)}}
@media (prefers-contrast: more) and (prefers-color-scheme: light){:root{--sec:rgba(60,60,67,.9);--edge:rgba(0,0,0,.5)}}
html,body{margin:0;height:100%;background:var(--bg);color:var(--label);font-family:-apple-system,system-ui,'PingFang TC','PingFang SC',sans-serif;-webkit-text-size-adjust:100%;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}
body{overflow:hidden}
#app,#pair{position:absolute;left:0;top:0;right:0;bottom:0;box-sizing:border-box;padding:max(16px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left))}
#app{display:flex;flex-direction:column}
#main{flex:1;display:flex;flex-direction:column;gap:2vmin;min-height:0}
#clock{text-align:center;padding:2vmin 0}
#time{font-size:22vmin;font-weight:300;font-variant-numeric:tabular-nums;letter-spacing:-.02em;line-height:1}
#date{font-size:3.6vmin;font-weight:600;color:var(--sec);margin-top:1.2vmin}
#cards{flex:1;display:flex;flex-wrap:wrap;gap:2vmin;align-content:flex-start;min-height:0;overflow:hidden}
.card{flex:1 1 40%;min-width:0;box-sizing:border-box;background:var(--card);border:1px solid var(--edge);border-radius:4.4vmin;padding:3vmin 3.4vmin}
.card h2{margin:0 0 1.4vmin;font-size:2.8vmin;font-weight:600;color:var(--sec);text-transform:none}
.big{font-size:8vmin;font-weight:400;font-variant-numeric:tabular-nums;line-height:1.05}
.line{font-size:3.4vmin;line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sec{color:var(--sec)}
.row{display:flex;justify-content:space-between;align-items:baseline;gap:2vmin}
.bar{height:1vmin;border-radius:1vmin;background:var(--card2);margin-top:2vmin;overflow:hidden}
.bar i{display:block;height:100%;background:var(--label);transition:width 1s linear}
#alerts .card{background:var(--red);color:#fff}
@media (orientation: portrait){#alerts .card{flex-basis:100%}}
#alerts .card h2{color:rgba(255,255,255,.85)}
#status{font-size:2.6vmin;color:var(--sec);text-align:center;padding-top:1.6vmin}
#status.stale{color:var(--orange)}
.hidden{display:none!important}
#pair{display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:3vmin;padding-left:10%;padding-right:10%}
#pair b{font-size:6vmin;font-weight:700}#pair p{margin:0;font-size:3.2vmin;color:var(--sec);line-height:1.45;max-width:36em}
#pair input{font:inherit;font-size:4vmin;text-align:center;letter-spacing:.12em;text-transform:uppercase;padding:1.6vmin 2vmin;border-radius:2.4vmin;border:1px solid var(--ter);background:var(--card);color:var(--label);width:60%;max-width:16em}
#pair button{font:inherit;font-size:3.4vmin;font-weight:600;padding:1.8vmin 5vmin;border-radius:999px;border:0;background:var(--blue);color:#fff}
#perr{color:var(--orange)!important}
@media (orientation: landscape){#main{flex-direction:row}#clock{flex:1;display:flex;flex-direction:column;justify-content:center}#time{font-size:20vmin}#cards{flex:1;flex-direction:column;flex-wrap:nowrap}.card{flex:0 0 auto}}
@media (prefers-reduced-motion: reduce){.bar i{transition:none}}
</style></head><body>
<div id="app" class="hidden"><div id="main"><div id="clock"><div id="time"></div><div id="date"></div></div><div id="cards"><div id="alerts" style="display:contents"></div>
<section class="card" id="weather"></section><section class="card" id="music"></section><section class="card" id="timers"></section><section class="card" id="next"></section><section class="card" id="empty"></section></div></div>
<div id="status"></div></div>
<div id="pair" class="hidden"><b>SideShow</b><p id="pmsg"></p><p id="perr"></p><input id="pcode" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="12" placeholder="XXXX-XXXX"><button id="pbtn"></button></div>
<script>
(function(){
var S=\#(strings);
function pick(){var ls=navigator.languages||[navigator.language||'en'];for(var i=0;i<ls.length;i++){var l=(ls[i]||'').toLowerCase();if(l.indexOf('zh')!==0){if(l.indexOf('en')===0)return 'en';continue;}
if(l.indexOf('hant')>=0||/-(tw|hk|mo)$/.test(l))return 'zh-Hant';return 'zh-Hans';}return 'en';}
var LANG=pick(),T=S[LANG]||S.en;document.documentElement.lang=T.lang;
function t(k){return T[k]||S.en[k]||k;}
function $(id){return document.getElementById(id);}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function load(k){try{return JSON.parse(localStorage.getItem(k));}catch(e){return null;}}
function save(k,v){try{localStorage.setItem(k,JSON.stringify(v));}catch(e){}}
function drop(k){try{localStorage.removeItem(k);}catch(e){}}
var AK='sideshow.auth',SK='sideshow.state',POLL=10000;
var auth=load(AK),st=load(SK),failing=false;
function pad(n){return n<10?'0'+n:''+n;}
function hm(d,h24){var h=d.getHours(),m=pad(d.getMinutes());if(h24!==false)return pad(h)+':'+m;var ap=h<12?'AM':'PM';h=h%12||12;return h+':'+m+' '+ap;}
function req(m,u,b,cb){var x=new XMLHttpRequest();x.open(m,u,true);x.timeout=8000;if(auth)x.setRequestHeader('Authorization','Bearer '+auth.id+'.'+auth.key);
if(b)x.setRequestHeader('Content-Type','application/json');x.onload=function(){cb(x.status,x.responseText);};x.onerror=x.ontimeout=function(){cb(0,'');};x.send(b?JSON.stringify(b):null);}
function now(){return Date.now();}
function macNow(){return now()+(st&&st.skew||0);}
function cond(c){var k=c===0?0:c===1?1:c===2?2:c===3?3:(c===45||c===48)?45:(c>=51&&c<=55)?51:(c===56||c===57)?56:(c===61||c===63)?61:(c===65||c===82)?65:(c===66||c===67)?66:(c===71||c===73||c===77)?71:c===75?75:(c===80||c===81)?80:(c===85||c===86)?85:c===95?95:(c===96||c===99)?96:3;return t('c'+k);}
function deg(v){return Math.round(st.fahrenheit?v*9/5+32:v);}
function clockStr(ms){var s=Math.max(0,Math.ceil(ms/1000)),h=Math.floor(s/3600),m=Math.floor(s%3600/60),x=s%60;return (h?h+':'+pad(m):m)+':'+pad(x);}
function fill(el,html){if(html){el.innerHTML=html;el.className='card';}else{el.innerHTML='';el.className='card hidden';}}
function render(){
 var d=new Date(),h24=st?st.h24:true;$('time').textContent=hm(d,h24).replace(/ [AP]M$/,'');
 try{$('date').textContent=d.toLocaleDateString(T.lang,{weekday:'long',month:'long',day:'numeric'});}catch(e){$('date').textContent=d.toDateString();}
 if(!st){fill($('weather'));fill($('music'));fill($('timers'));fill($('next'));fill($('empty'),'<div class="line sec">'+esc(t('nothing'))+'</div>');$('status').textContent='';return;}
 var any=false,stale=failing||now()-(st.recv||0)>POLL*3;
 var al='';for(var i=0;i<(st.alerts||[]).length;i++){var a=st.alerts[i];al+='<section class="card"><h2>'+esc(t('a.'+a.kind))+'</h2><div class="line">'+esc(t('b.'+a.kind).replace('%@',a.room))+'</div></section>';}
 $('alerts').innerHTML=al;any=any||!!al;
 var w=st.weather;if(w){any=true;var hl=t('hiLo').replace('%d',deg(w.hi)).replace('%d',deg(w.lo));
  fill($('weather'),'<h2>'+esc(w.city||t('weather'))+'</h2><div class="row"><div class="big">'+deg(w.temp)+'°</div><div class="line">'+esc(cond(w.code))+'</div></div><div class="line sec">'+esc(hl)+'</div>');}else fill($('weather'));
 var m=st.track;if(m){any=true;var pos=m.position+(m.playing&&!stale?(now()-st.recv)/1000:0);if(m.duration>0)pos=Math.min(pos,m.duration);
  fill($('music'),'<h2>'+esc(m.playing?t('nowPlaying'):t('paused'))+'</h2><div class="line">'+esc(m.title)+'</div><div class="line sec">'+esc(m.artist)+'</div>'+(m.duration>0?'<div class="bar"><i style="width:'+(100*pos/m.duration).toFixed(1)+'%"></i></div>':''));}else fill($('music'));
 var tm=st.timers||[],th='';for(var j=0;j<tm.length;j++){var x=tm[j],left=x.paused!=null?x.paused*1000:x.end*1000-macNow();if(left<=0&&x.paused==null)continue;
  th+='<div class="row"><div class="line">'+esc(x.label||t('timers'))+'</div><div class="big" style="font-size:6vmin">'+clockStr(left)+'</div></div>'+(x.paused!=null?'<div class="line sec">'+esc(t('paused'))+'</div>':'');}
 if(th){any=true;fill($('timers'),'<h2>'+esc(t('timers'))+'</h2>'+th);}else fill($('timers'));
 var n=st.next;if(n){any=true;var sd=new Date(n.start*1000),td=new Date(),tmr=new Date(td.getFullYear(),td.getMonth(),td.getDate()+1);
  var day=sd.toDateString()===td.toDateString()?t('today'):sd.toDateString()===tmr.toDateString()?t('tomorrow'):(sd.getMonth()+1)+'/'+sd.getDate();
  fill($('next'),'<h2>'+esc(t('next'))+'</h2><div class="line">'+esc(n.title)+'</div><div class="line sec">'+esc(day+' '+(n.allDay?t('allDay'):hm(sd,st.h24)))+'</div>');}else fill($('next'));
 fill($('empty'),any?'':'<div class="line sec">'+esc(t('nothing'))+'</div>');
 var s=$('status');if(stale){s.className='stale';s.textContent=t('lastUpdate').replace('%@',hm(new Date(st.recv||st.at*1000),st.h24))+' · '+t('asleep');}else{s.className='';s.textContent=t('connected');}
}
function poll(){if(!auth)return;req('GET','/api/state',null,function(code,txt){
 if(code===200){try{var o=JSON.parse(txt);o.recv=now();o.skew=o.at*1000-o.recv;st=o;save(SK,st);failing=false;}catch(e){failing=true;}}
 else if(code===401){auth=null;st=null;drop(AK);drop(SK);showPair(t('removed'));return;}
 else failing=true;render();});}
function showApp(){$('pair').className='hidden';$('app').className='';render();}
function showPair(err){$('app').className='hidden';$('pair').className='';$('perr').textContent=err||'';$('pmsg').textContent=t('pairHow')+' '+t('pairManual');$('pcode').className='';$('pbtn').textContent=t('pairButton');$('pbtn').onclick=function(){redeem($('pcode').value);};}
function devName(){var u=navigator.userAgent;return /iPad/.test(u)?'iPad':/iPhone/.test(u)?'iPhone':/Android/.test(u)?'Android':'Browser';}
function redeem(code){code=(code||'').replace(/\s/g,'');if(!code)return;$('perr').textContent=t('pairing');
 req('POST','/api/pair',{code:code,name:devName()},function(c,txt){
  if(c===200){try{var o=JSON.parse(txt);auth={id:o.id,key:o.key};save(AK,auth);}catch(e){}try{history.replaceState(null,'','/');}catch(e){}showApp();poll();return;}
  $('perr').textContent=c===403?t('badCode'):c===429?t('blocked'):c===409?t('full'):t('unreachable');});}
var hashCode=(location.hash.match(/[#&]pair=([0-9A-Za-z-]+)/)||[])[1];
var ios=/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
var standalone=window.navigator.standalone===true||(window.matchMedia&&matchMedia('(display-mode: standalone)').matches);
if(auth){try{if(hashCode)history.replaceState(null,'','/');}catch(e){}showApp();poll();}
else if(hashCode&&ios&&!standalone){showPair();$('pmsg').textContent=t('addToHome');$('pcode').className='hidden';$('pbtn').textContent=t('useHere');$('pbtn').onclick=function(){redeem(hashCode);};}
else if(hashCode){showPair();redeem(hashCode);}
else showPair();
setInterval(function(){if(!$('app').className)render();},1000);
setInterval(poll,POLL);
document.addEventListener('visibilitychange',function(){if(!document.hidden)poll();});
var shift=0;setInterval(function(){shift=(shift+1)%4;document.body.style.transform='translate('+(shift&1)+'px,'+(shift>>1)+'px)';},180000);
if('serviceWorker' in navigator&&window.isSecureContext){try{navigator.serviceWorker.register('/sw.js');}catch(e){}}
})();
</script></body></html>
"""#
    }
}
