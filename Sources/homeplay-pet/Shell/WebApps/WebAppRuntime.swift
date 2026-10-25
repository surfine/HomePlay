// 2.0 Web App 的網頁：跟 Safari 一樣是看不到的視窗裡的 WKWebView、拍照貼進 1024² 畫布（SafariApp.swift 的 SafariWeb），
// 不同的是：每個 Web App 有自己的網站資料（WebAppData）、可以打字（桌寵旁邊的原生小框，字同步進網頁的欄位）、
// 相機／麥克風／位置／通知照每個 Web App 各自的權限問一次。
//
// 安全閘（跟 Safari 一樣嚴，只多開「這個 Web App 自己的資料」與打字）：
// - 主框架只走 http／https；file:、自訂 scheme、mailto: 一律擋；下載一律取消；不上傳檔案（不開檔案面板）。
// - 範圍外：點連結＝交給 HomePlay 的 Safari；重新導向、表單、程式換頁（登入流程）留在這裡，但頂端顯示網域與「完成」（iOS 的做法）。
// - HTTP 認證挑戰不跳框（HomePlay 不問帳密）；不自動填密碼。網址、內容不進日誌。

import AppKit
import WebKit

/// 腳本訊息的轉手（WKUserContentController 會強引用 handler）
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

/// 不能成為主視窗的看不到的視窗
private final class OffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WebAppWeb: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let uuid: String
    private(set) var view: WKWebView!
    private var window: NSWindow!
    private(set) var snapshot: CGImage?
    private(set) var progress: CGFloat = 1
    private(set) var loading = false
    private(set) var failed = false
    /// 第一張畫好的網頁出來了沒（之前畫啟動畫面）
    private(set) var everPainted = false
    /// 網頁自己的 <meta name=theme-color>（會變：深色模式、換頁）
    private(set) var pageTheme: UInt32?
    private(set) var media: (playing: Bool, title: String, artist: String) = (false, "", "")
    var onChange: (() -> Void)?
    /// 要問使用者（相機、麥克風、位置、通知）：回 true＝允許
    var onAsk: ((WebAppPermission, @escaping (Bool) -> Void) -> Void)?
    /// alert／confirm：（訊息, 有沒有取消鈕, 回答）
    var onDialog: ((String, Bool, @escaping (Bool) -> Void) -> Void)?
    var onNotification: ((String, String) -> Void)?
    private var wantSnap = false, snapping = false, lastSnap = 0.0, lastMediaPoll = 0.0
    private var observers: [NSKeyValueObservation] = []
    private var zoom: CGFloat = HPTokens.Safari.pageZoom

    static var pointSize: NSSize { SafariWeb.pointSize }

    init(app: WebApp) {
        uuid = app.uuid
        super.init()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WebAppData.store(app.uuid)                 // 這個 Web App 自己的 cookie、localStorage、service worker
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.mediaTypesRequiringUserActionForPlayback = []                  // 裝起來的 App：點了就能播（點按本身就是使用者動作）
        cfg.preferences.isElementFullscreenEnabled = false
        cfg.userContentController.add(WeakScriptHandler(self), name: "homeplay")
        let v = WKWebView(frame: NSRect(origin: .zero, size: Self.pointSize), configuration: cfg)
        v.navigationDelegate = self; v.uiDelegate = self
        v.allowsLinkPreview = false; v.allowsMagnification = false; v.allowsBackForwardNavigationGestures = false
        v.customUserAgent = nil
        zoom = HPTokens.Safari.pageZoom * HPType.textScale
        v.pageZoom = zoom
        view = v
        installShims(app)
        let w = OffscreenWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: Self.pointSize), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.ignoresMouseEvents = true; w.hasShadow = false; w.isExcludedFromWindowsMenu = true
        w.collectionBehavior = [.transient, .ignoresCycle]
        w.contentView = v
        w.orderBack(nil)
        window = w
        observers = [
            v.observe(\.estimatedProgress) { [weak self] v, _ in self?.progress = CGFloat(v.estimatedProgress); self?.changed(snap: true) },
            v.observe(\.isLoading) { [weak self] v, _ in self?.loading = v.isLoading; self?.changed(snap: true) },
        ]
    }

    func close() {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "homeplay")
        observers = []
        window.orderOut(nil); window.contentView = nil; window.close()
        view.navigationDelegate = nil; view.uiDelegate = nil
        view = nil   // 放掉 WKWebView：它的網站資料庫才刪得掉
    }

    // MARK: 墊片：位置、通知走我們的權限（每次權限改了重裝，下一頁生效）

    func installShims(_ app: WebApp) {
        let ucc = view.configuration.userContentController
        ucc.removeAllUserScripts()
        let note: String = {
            switch app.permissions[WebAppPermission.notifications.rawValue] { case "allow": return "granted"; case "deny": return "denied"; default: return "default" }
        }()
        let js = """
        (function(){var H=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.homeplay;if(!H)return;
        var cb={},n=0;window.__hpDone=function(id,v){var f=cb[id];if(f){delete cb[id];f(v)}};
        function ask(t,extra){return new Promise(function(r){var id=++n;cb[id]=r;var m={t:t,id:id};for(var k in (extra||{}))m[k]=extra[k];H.postMessage(m)})}
        if(navigator.geolocation){var g=navigator.geolocation;
          var get=function(ok,err){ask('geo').then(function(v){if(v&&v.ok){ok&&ok({coords:{latitude:v.lat,longitude:v.lon,accuracy:v.acc,altitude:null,altitudeAccuracy:null,heading:null,speed:null},timestamp:Date.now()})}
            else{err&&err({code:v&&v.code||1,message:v&&v.msg||'',PERMISSION_DENIED:1,POSITION_UNAVAILABLE:2,TIMEOUT:3})}})};
          try{g.getCurrentPosition=get;g.watchPosition=function(a,b){get(a,b);return 1};g.clearWatch=function(){}}catch(e){}}
        function N(title,o){o=o||{};this.title=String(title);this.body=String(o.body||'');this.onclick=null;this.close=function(){};
          if(N.permission==='granted')H.postMessage({t:'note',title:this.title,body:this.body})}
        N.prototype.addEventListener=function(){};N.permission='\(note)';
        N.requestPermission=function(f){return ask('notePerm').then(function(p){N.permission=p;if(f)f(p);return p})};
        try{Object.defineProperty(window,'Notification',{value:N,configurable:true,writable:true})}catch(e){window.Notification=N}
        })();
        """
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.frameInfo.isMainFrame, let o = m.body as? [String: Any], let t = o["t"] as? String else { return }
        let id = (o["id"] as? NSNumber)?.intValue ?? 0
        func reply(_ json: String) { view.evaluateJavaScript("window.__hpDone&&window.__hpDone(\(id),\(json))", completionHandler: nil) }
        switch t {
        case "geo":
            permission(.location) { ok in
                guard ok else { reply("{ok:false,code:1}"); return }
                // 大略位置：天氣用的那一個（四捨五入到約 1 km）；沒有就說拿不到
                let d = UserDefaults.standard
                guard d.object(forKey: "HomePlayWeatherLat") != nil else { reply("{ok:false,code:2}"); return }
                let lat = (d.double(forKey: "HomePlayWeatherLat") * 100).rounded() / 100, lon = (d.double(forKey: "HomePlayWeatherLon") * 100).rounded() / 100
                reply("{ok:true,lat:\(lat),lon:\(lon),acc:1000}")
            }
        case "notePerm":
            permission(.notifications) { ok in reply(ok ? "'granted'" : "'denied'") }
        case "note":
            let title = String((o["title"] as? String ?? "").prefix(80)), body = String((o["body"] as? String ?? "").prefix(160))
            if WebAppStore.shared.app(uuid: uuid)?.permissions[WebAppPermission.notifications.rawValue] == "allow" { onNotification?(title, body) }
        default: break
        }
    }

    /// 存過就照存的；沒存過問一次、記下來
    func permission(_ p: WebAppPermission, _ done: @escaping (Bool) -> Void) {
        let store = WebAppStore.shared
        if let s = store.app(uuid: uuid)?.permissions[p.rawValue] { done(s == "allow"); return }
        guard let ask = onAsk else { done(false); return }
        ask(p) { [weak self] ok in
            guard let self else { done(false); return }
            store.update(self.uuid) { $0.permissions[p.rawValue] = ok ? "allow" : "deny" }
            if p == .notifications, let a = store.app(uuid: self.uuid) { self.installShims(a) }
            done(ok)
        }
    }

    // MARK: 載入、外觀

    func setAppearance(dark: Bool) {
        let a = NSAppearance(named: dark ? .darkAqua : .aqua)
        if view.appearance?.name != a?.name { view.appearance = a; changed(snap: true) }
        let z = HPTokens.Safari.pageZoom * HPType.textScale
        if abs(z - zoom) > 0.01 { zoom = z; view.pageZoom = z; changed(snap: true) }
    }
    var pageZoom: CGFloat { zoom }
    func load(_ u: URL) {
        guard WebManifestParser.allowedScheme(u) else { return }
        failed = false
        view.load(URLRequest(url: u))
        changed(snap: true)
    }
    func reload() { failed = false; view.reload() }
    var url: URL? { view.url }

    func scroll(cssDY: CGFloat) {
        view.evaluateJavaScript("window.scrollBy(0, \(Int(cssDY)))") { [weak self] _, _ in self?.changed(snap: true) }
    }

    /// 點到的是什麼
    enum Tap { case field(type: String, value: String, placeholder: String), other }
    /// 點網頁：輸入框＝聚焦、交給原生小框打字；其他元素送完整的 pointer／mouse 事件再 click()（很多 App 聽 pointerdown）
    func tap(css p: CGPoint, done: @escaping (Tap) -> Void) {
        let js = """
        (function(x,y){var e=document.elementFromPoint(x,y);if(!e)return '{"k":"none"}';
        var f=e.closest('input,textarea,[contenteditable=""],[contenteditable=true]');
        if(f&&!(f.tagName==='INPUT'&&/^(button|submit|reset|checkbox|radio|range|color|file|image|hidden)$/i.test(f.type))){
          f.focus();window.__hpField=f;
          return JSON.stringify({k:'field',type:(f.tagName==='INPUT'?(f.type||'text'):f.tagName).toLowerCase(),value:f.isContentEditable?f.innerText:(f.value||''),
            placeholder:f.getAttribute('placeholder')||f.getAttribute('aria-label')||''});}
        var o={bubbles:true,cancelable:true,composed:true,clientX:x,clientY:y,view:window,button:0,buttons:1,pointerId:1,pointerType:'mouse',isPrimary:true};
        try{e.dispatchEvent(new PointerEvent('pointerdown',o))}catch(_){}
        e.dispatchEvent(new MouseEvent('mousedown',o));o.buttons=0;
        try{e.dispatchEvent(new PointerEvent('pointerup',o))}catch(_){}
        e.dispatchEvent(new MouseEvent('mouseup',o));
        if(e.click)e.click();return '{"k":"click"}'})(\(Double(p.x)),\(Double(p.y)))
        """
        view.evaluateJavaScript(js) { [weak self] r, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.changed(snap: true) }
            guard let s = r as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { done(.other); return }
            if o["k"] as? String == "field" {
                done(.field(type: o["type"] as? String ?? "text", value: o["value"] as? String ?? "", placeholder: o["placeholder"] as? String ?? ""))
            } else { done(.other) }
        }
    }
    /// 原生小框的字同步進剛才聚焦的欄位（用原生的 value setter，React 之類也收得到 input 事件）
    func setFieldText(_ s: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let arr = String(data: d, encoding: .utf8) else { return }
        let js = """
        (function(v){var f=window.__hpField;if(!f)return;if(f.isContentEditable){f.innerText=v}else{var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(f),'value');
        if(d&&d.set)d.set.call(f,v);else f.value=v}f.dispatchEvent(new InputEvent('input',{bubbles:true,data:v,inputType:'insertText'}))})(\(arr)[0])
        """
        view.evaluateJavaScript(js) { [weak self] _, _ in self?.changed(snap: true) }
    }
    /// Return：Enter 的鍵盤事件；網頁沒攔就送出表單
    func submitField() {
        let js = """
        (function(){var f=window.__hpField;if(!f)return;var o={key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true};
        var ok=f.dispatchEvent(new KeyboardEvent('keydown',o));f.dispatchEvent(new KeyboardEvent('keypress',o));f.dispatchEvent(new KeyboardEvent('keyup',o));
        f.dispatchEvent(new Event('change',{bubbles:true}));
        if(ok&&f.form&&f.tagName!=='TEXTAREA'){if(f.form.requestSubmit)f.form.requestSubmit();else f.form.submit()}})()
        """
        view.evaluateJavaScript(js) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.changed(snap: true) }
        }
    }
    func blurField() { view.evaluateJavaScript("(function(){var f=window.__hpField;if(f&&f.blur)f.blur();window.__hpField=null})()") { [weak self] _, _ in self?.changed(snap: true) } }

    private func readTheme() {
        view.evaluateJavaScript("(function(){var m=document.querySelector('meta[name=\"theme-color\"]');return m?m.content:''})()") { [weak self] r, _ in
            guard let self else { return }
            let t = (r as? String).flatMap(CSSColor.parse)
            if t != self.pageTheme { self.pageTheme = t; self.onChange?() }
        }
    }

    private func changed(snap: Bool) {
        if snap { wantSnap = true }
        onChange?()
    }

    /// 每幀叫：有變化就拍（跟 Safari 一樣最多每 0.08 秒一張）；每 1.5 秒看一次有沒有在播
    func pump(_ now: Double) {
        if loading, now - lastSnap > 0.4 { wantSnap = true }
        if now - lastMediaPoll > 1.5 { lastMediaPoll = now; pollMedia() }
        guard wantSnap, !snapping, now - lastSnap > 0.08 else { return }
        wantSnap = false; snapping = true; lastSnap = now
        let c = WKSnapshotConfiguration()
        c.afterScreenUpdates = true
        view.takeSnapshot(with: c) { [weak self] img, _ in
            guard let self else { return }
            self.snapping = false
            if let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.snapshot = cg
                if !self.loading, self.view.url != nil { self.everPainted = true }
                self.onChange?()
            }
        }
    }
    var snapshotPending: Bool { wantSnap || snapping }
    /// 2.0 depth：頂端多一條列（範圍外的網域列）時，網頁的可視區矮一截——跟 iOS 一樣內容從列的下面開始，不是被列蓋住
    func setTopInset(_ canvas: CGFloat) {
        let h = Self.pointSize.height - canvas * HPTokens.Safari.pointsPerCanvas
        guard abs(view.frame.height - h) > 0.5 else { return }
        window.setContentSize(NSSize(width: Self.pointSize.width, height: h))
        view.frame = NSRect(origin: .zero, size: NSSize(width: Self.pointSize.width, height: h))
        changed(snap: true)
    }
    /// 快照：等到畫好
    func settle(until end: Date) {
        while Date() < end, loading || !everPainted { pump(CACurrentMediaTime()); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let stop = min(end, Date().addingTimeInterval(1.2))
        while Date() < stop { pump(CACurrentMediaTime()); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        changed(snap: true)
        while Date() < end, snapshotPending { pump(CACurrentMediaTime()); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func pollMedia() {
        let js = """
        (function(){var p=[].slice.call(document.querySelectorAll('audio,video')).some(function(x){return !x.paused&&!x.ended&&x.readyState>2});
        var ms=navigator.mediaSession,md=ms&&ms.metadata;if(ms&&ms.playbackState==='playing')p=true;
        return JSON.stringify({p:p,t:md&&md.title||'',a:md&&md.artist||''})})()
        """
        view.evaluateJavaScript(js) { [weak self] r, _ in
            guard let self, let s = r as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let m = (o["p"] as? Bool ?? false, String((o["t"] as? String ?? "").prefix(80)), String((o["a"] as? String ?? "").prefix(80)))
            if m != self.media { self.media = m; self.onChange?() }
        }
    }

    // MARK: 安全閘

    /// 範圍外、而且是點連結：交給 Safari（回 true＝已經處理掉了）
    var onLeaveScope: ((URL) -> Void)?
    private var app: WebApp? { WebAppStore.shared.app(uuid: uuid) }

    func webView(_ webView: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if a.shouldPerformDownload { decisionHandler(.cancel); return }
        guard let u = a.request.url else { decisionHandler(.cancel); return }
        let main = a.targetFrame?.isMainFrame ?? true
        let scheme = u.scheme?.lowercased() ?? ""
        if !main {   // iframe：網頁、about:blank、blob:、data: 可以（嵌入的影片、地圖）
            decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel); return
        }
        if u.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard WebManifestParser.allowedScheme(u) else { decisionHandler(.cancel); return }   // file:、自訂 scheme、mailto:、javascript:
        if let app, !app.inScope(u), a.navigationType == .linkActivated {
            decisionHandler(.cancel); onLeaveScope?(u); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = ((r.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("attachment")
        decisionHandler(r.canShowMIMEType && !attachment ? .allow : .cancel)   // 不下載
    }
    /// HTTP 認證：不跳帳密框；憑證照系統的檢查
    func webView(_ webView: WKWebView, didReceive c: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(c.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readTheme(); changed(snap: true)
        for d in [0.5, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.changed(snap: true) } }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { failed = true }; changed(snap: true) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }; changed(snap: true)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    /// target=_blank／window.open：範圍內在這裡開；範圍外交給 Safari
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url, WebManifestParser.allowedScheme(u) {
            // 點了 target=_blank 的範圍外連結＝Safari；程式開的彈窗（登入）＝在這裡開，頂端有網域與「完成」
            if app?.inScope(u) == true || a.navigationType != .linkActivated { webView.load(a.request) } else { onLeaveScope?(u) }
        }
        return nil
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // 只給這個 Web App 自己的網域（iframe 裡別人的網頁不行）
        guard frame.isMainFrame, let app, let s = app.scopeURL, origin.host.lowercased() == s.host?.lowercased() else { decisionHandler(.deny); return }
        switch type {
        case .camera: permission(.camera) { decisionHandler($0 ? .grant : .deny) }
        case .microphone: permission(.microphone) { decisionHandler($0 ? .grant : .deny) }
        case .cameraAndMicrophone:
            permission(.camera) { [weak self] cam in
                guard cam, let self else { decisionHandler(.deny); return }
                self.permission(.microphone) { decisionHandler($0 ? .grant : .deny) }
            }
        @unknown default: decisionHandler(.deny)
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard frame.isMainFrame, let d = onDialog else { completionHandler(); return }
        d(String(message.prefix(300)), false) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard frame.isMainFrame, let d = onDialog else { completionHandler(false); return }
        d(String(message.prefix(300)), true, completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
}

/// 開著的 Web App 網頁：關掉 App 時還在播的留著（最多 3 個，最舊的先關）
enum WebAppRuntimes {
    nonisolated(unsafe) private static var live: [String: WebAppWeb] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    static let keep = 3
    nonisolated(unsafe) private static var purged = false

    static func web(for app: WebApp) -> WebAppWeb {
        if let w = live[app.uuid] { touch(app.uuid); return w }
        if !purged, !WebAppStore.shared.demoOnly { purged = true; WebAppData.purgeOrphans(keeping: WebAppStore.shared.apps.map(\.uuid)) }
        let w = WebAppWeb(app: app)
        live[app.uuid] = w; touch(app.uuid)
        while order.count > keep, let old = order.first { drop(old) }
        return w
    }
    static func existing(_ uuid: String) -> WebAppWeb? { live[uuid] }
    private static func touch(_ uuid: String) { order.removeAll { $0 == uuid }; order.append(uuid) }
    static func drop(_ uuid: String) {
        live[uuid]?.close(); live[uuid] = nil; order.removeAll { $0 == uuid }
    }
    /// App 關掉了：沒在播就關網頁（省記憶體；資料都在它自己的資料庫裡）
    static func closed(_ uuid: String) { if live[uuid]?.media.playing != true { drop(uuid) } }
    static var playing: [String] { live.filter { $0.value.media.playing }.map(\.key) }
    static var liveIDs: [String] { order }
}
