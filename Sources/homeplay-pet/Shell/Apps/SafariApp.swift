// Safari：HomeView 內建 App 之一（HV-SPECS-88）。跟官方一樣，食譜併在 Safari 裡：食譜網頁上有「開始烹飪」，
// 起始頁有「釘選的食譜」；烹飪畫面就是原本的 RecipesApp（id "recipes"，不上主畫面）。
//
// 怎麼畫：真的 WKWebView 放在一個看不到的視窗裡（不搶焦點、不收滑鼠），每次變化拍一張 takeSnapshot 貼進 1024² 畫布；
// 寬 512 pt（畫布的一半）、字放大 1.5 倍，遠看也讀得到。點＝把畫布座標換成網頁座標，用 JS 點那裡的連結或按鈕；滾輪＝scrollBy。
// 閱讀器：用 JS 抽出標題、段落、清單，我們自己用 HPDS 的大字排（不貼網頁截圖）。
//
// 安全：不存 cookie 與網站資料（nonPersistent）、不填表（點到輸入框直接不理，也沒有鍵盤進網頁，所以不會輸入密碼）、
// 不下載（不能顯示的類型與 download 一律取消）、只走 http／https、不開新視窗與彈出對話框、不上傳檔案。網址、內容都不進日誌。

import AppKit
import WebKit
import SwiftUI

// MARK: - 純邏輯（--selftest 驗）

enum SafariLogic {
    /// 網址列的字 → 要開的網址：http(s) 照用；像網域的補 https://；其他（含 file:、javascript:）當搜尋
    static func resolve(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t), let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host?.isEmpty == false { return u }
        let hostLike = t.contains(".") && !t.hasPrefix(".") && t.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d+)?(/\S*)?$"#, options: .regularExpression) != nil
        if hostLike, let u = URL(string: "https://" + t), u.host?.contains(".") == true { return u }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url
    }
    /// 只放行網頁：http、https，還有我們自己 loadHTMLString 的 about:blank
    static func allowed(_ u: URL?) -> Bool {
        guard let s = u?.scheme?.lowercased() else { return false }
        return s == "http" || s == "https" || u?.absoluteString == "about:blank"
    }
    /// 網址列顯示的字：只顯示網域（去掉 www.），跟 Safari 一樣
    static func displayHost(_ u: URL?) -> String {
        guard let h = u?.host, !h.isEmpty else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    /// 畫布座標 → 網頁的 CSS 座標（網頁從 webTop 開始；1 pt＝2 畫布單位；再除掉放大）
    static func cssPoint(_ p: CGPoint, zoom: CGFloat) -> CGPoint {
        let k = HPTokens.Safari.pointsPerCanvas / zoom
        return CGPoint(x: p.x * k, y: (p.y - HPTokens.Safari.webTop) * k)
    }
}

// MARK: - 看不到的網頁視圖

final class SafariWeb: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var view: WKWebView!
    private var window: NSWindow!
    private(set) var snapshot: CGImage?
    private(set) var topColor: NSColor?
    private(set) var progress: CGFloat = 1
    private(set) var loading = false
    private(set) var isRecipe = false
    private(set) var readable = false
    private(set) var failed = false
    var onChange: (() -> Void)?
    private var wantSnap = false
    private var snapping = false
    private var lastSnap = 0.0
    private var observers: [NSKeyValueObservation] = []
    private var zoom: CGFloat = HPTokens.Safari.pageZoom

    static var pointSize: NSSize {
        let k = HPTokens.Safari.pointsPerCanvas
        return NSSize(width: 1024 * k, height: (1024 - HPTokens.Safari.webTop) * k)
    }

    override init() {
        super.init()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()                      // 不留 cookie、快取、登入
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.preferences.isElementFullscreenEnabled = false
        let v = WKWebView(frame: NSRect(origin: .zero, size: Self.pointSize), configuration: cfg)
        v.navigationDelegate = self; v.uiDelegate = self
        v.allowsLinkPreview = false; v.allowsMagnification = false; v.allowsBackForwardNavigationGestures = false
        zoom = HPTokens.Safari.pageZoom * HPType.textScale
        v.pageZoom = zoom
        view = v
        // 看不到的視窗：放在所有螢幕外面，不收滑鼠、不當主視窗（WebKit 要在視窗裡才會排版與出圖）
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: Self.pointSize), styleMask: [.borderless], backing: .buffered, defer: false)
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

    func setAppearance(dark: Bool) {
        let a = NSAppearance(named: dark ? .darkAqua : .aqua)
        if view.appearance?.name != a?.name { view.appearance = a; changed(snap: true) }
        let z = HPTokens.Safari.pageZoom * HPType.textScale
        if abs(z - zoom) > 0.01 { zoom = z; view.pageZoom = z; changed(snap: true) }
    }
    var pageZoom: CGFloat { zoom }

    /// 最後一次要開的網址：沒開成功時 view.url 還是上一頁（或 nil），「重新載入」要重試的是這個
    private var lastRequested: URL?
    func load(_ u: URL) {
        guard SafariLogic.allowed(u) else { return }
        lastRequested = u
        failed = false; isRecipe = false; readable = false
        view.load(URLRequest(url: u))
        changed(snap: true)
    }
    /// 示範：不連網，直接給 HTML（base 只拿來當網址列的網域）
    func loadHTML(_ html: String, base: URL) {
        failed = false; isRecipe = false; readable = false
        view.loadHTMLString(html, baseURL: base)
    }
    func stop() { view.stopLoading() }
    /// 2.0 depth：「打不開這個網頁」之後按重新載入要真的重試，成功了那張卡要拿掉
    func reload() {
        if failed, let u = lastRequested { load(u); return }
        failed = false; view.reload()
    }
    func back() { if view.canGoBack { view.goBack() } }
    func forward() { if view.canGoForward { view.goForward() } }
    var url: URL? { view.url }

    func scroll(cssDY: CGFloat) {
        view.evaluateJavaScript("window.scrollBy(0, \(Int(cssDY)))") { [weak self] _, _ in self?.changed(snap: true) }
    }
    /// 點網頁：連結（http/https）直接開、其他元素 click()；輸入框不理（沒有鍵盤進網頁，也不填表）
    func tap(css p: CGPoint) {
        let js = """
        (function(x,y){var e=document.elementFromPoint(x,y);if(!e)return '';
        if(e.closest('input,textarea,select,[contenteditable],[contenteditable=true]'))return 'field';
        var a=e.closest('a[href]');if(a){var h=a.href;if(/^https?:/i.test(h)){location.href=h;return 'link'}return 'blocked'}
        e.click();return 'click'})(\(Double(p.x)),\(Double(p.y)))
        """
        view.evaluateJavaScript(js) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.changed(snap: true) }
        }
    }

    /// 這一頁的 HTML（開始烹飪：在本機拆 JSON-LD，不再抓一次）
    func html(_ done: @escaping (String?) -> Void) {
        view.evaluateJavaScript("document.documentElement.outerHTML") { r, _ in done(r as? String) }
    }

    /// 閱讀器：標題＋依序的標題／段落／清單（最多 300 段）
    struct Article: Equatable { var title: String; var blocks: [(kind: String, text: String)]
        static func == (a: Article, b: Article) -> Bool { a.title == b.title && a.blocks.map(\.text) == b.blocks.map(\.text) }
    }
    func article(_ done: @escaping (Article?) -> Void) {
        let js = """
        (function(){var root=document.querySelector('article')||document.querySelector('main')||document.body;if(!root)return null;
        var out=[];var nodes=root.querySelectorAll('h1,h2,h3,p,li');
        for(var i=0;i<nodes.length&&out.length<300;i++){var n=nodes[i];if(n.closest('nav,footer,aside,header,form,script,style'))continue;
        var t=(n.innerText||'').replace(/\\s+/g,' ').trim();if(t.length<2)continue;
        var k=n.tagName.toLowerCase();out.push([k==='li'?'li':(k[0]==='h'?'h':'p'),t]);}
        var h=document.querySelector('h1');return JSON.stringify({title:(h&&h.innerText.trim())||document.title||'',blocks:out});})()
        """
        view.evaluateJavaScript(js) { r, _ in
            guard let s = r as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { done(nil); return }
            let blocks = (o["blocks"] as? [[String]] ?? []).compactMap { $0.count == 2 ? (kind: $0[0], text: $0[1]) : nil }
            done(Article(title: o["title"] as? String ?? "", blocks: blocks))
        }
    }

    private func detect() {
        // 2.0 depth：只认拆得出来的食谱——JSON-LD 里是 Recipe、而且有食材或步骤（RecipeParser 的最低要求）。
        // 只有 @type 没有内容、或只有 microdata 标记的页面以前也会出「开始烹饪」，点了是死路；microdata 我们本来就解析不了。
        let js = """
        (function(){var r=false;var s=document.querySelectorAll('script[type="application/ld+json"]');
        for(var i=0;i<s.length;i++){var t=s[i].textContent;
        if(/"@type"\\s*:\\s*(\\[[^\\]]*)?"Recipe"/.test(t)&&/(recipeIngredient|recipeInstructions|"ingredients")/.test(t)){r=true;break}}
        var n=0,ps=document.querySelectorAll('p');for(var j=0;j<ps.length;j++){if((ps[j].innerText||'').length>80)n++}
        return JSON.stringify({recipe:r,readable:n>=2||r});})()
        """
        view.evaluateJavaScript(js) { [weak self] r, _ in
            guard let self, let s = r as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Bool] else { return }
            self.isRecipe = o["recipe"] ?? false; self.readable = o["readable"] ?? false
            self.changed(snap: false)
        }
    }

    private func changed(snap: Bool) {
        if snap { wantSnap = true }
        onChange?()
    }

    /// 每幀叫：有變化就拍（最多每 0.08 秒一張；正在載入時每 0.4 秒補一張）
    func pump(_ now: Double) {
        if loading, now - lastSnap > 0.4 { wantSnap = true }
        guard wantSnap, !snapping, now - lastSnap > 0.08 else { return }
        wantSnap = false; snapping = true; lastSnap = now
        let c = WKSnapshotConfiguration()
        c.afterScreenUpdates = true
        view.takeSnapshot(with: c) { [weak self] img, _ in
            guard let self else { return }
            self.snapping = false
            if let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.snapshot = cg
                // 網頁最上面那一條的顏色：👀 膠囊底下那一段跟著網頁的底色
                self.topColor = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: 4)).flatMap(Shell.averageColor)
                self.onChange?()
            }
        }
    }
    var snapshotPending: Bool { wantSnap || snapping }

    // MARK: WKNavigationDelegate / WKUIDelegate（安全閘）

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.cancel); return }
        decisionHandler(SafariLogic.allowed(navigationAction.request.url) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = ((navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("attachment")
        decisionHandler(navigationResponse.canShowMIMEType && !attachment ? .allow : .cancel)   // 不下載
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        detect(); changed(snap: true)
        // 排版完不一定已經畫好：半秒後、一秒半後各補拍一張（字型、圖片晚到）
        for d in [0.5, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.changed(snap: true) } }
    }
    /// 示範快照用：再拍一張，等它拍完
    func settle(until end: Date) {
        let stop = min(end, Date().addingTimeInterval(1.6))
        while Date() < stop { pump(CACurrentMediaTime()); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        changed(snap: true)
        while Date() < end, snapshotPending { pump(CACurrentMediaTime()); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { failed = true }; changed(snap: true) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }; changed(snap: true)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { failed = false; isRecipe = false; readable = false; changed(snap: true) }
    /// target=_blank／window.open：在同一頁開
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if SafariLogic.allowed(navigationAction.request.url) { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
}

// MARK: - App

final class SafariApp: PetApp {
    static let shared = SafariApp()
    let id = "safari"
    var title: String { "Safari" }   // l10n-ignore：App 名稱三種語言都叫 Safari
    /// /Applications/Safari.app 是指到 Cryptex 的捷徑（直接讀會帶捷徑箭頭）：先解開
    let icon = AppIcon(color: srgb(0x0A84FF), symbol: "safari", system: URL(fileURLWithPath: "/Applications/Safari.app").resolvingSymlinksInPath().path)
    typealias T = HPTokens.Safari

    private lazy var web: SafariWeb = { let w = SafariWeb(); w.onChange = { [weak self] in self?.dirty = true }; return w }()
    private var started = false           // 開過網頁了（不然是起始頁）
    private var reader: SafariWeb.Article?
    private var readerOn = false
    private var readerScroll = AppScroll()
    private var startScroll = AppScroll()
    private var dirty = false
    private var popover: NSPopover?
    private let input = SafariAddressModel()
    private var hits: [(CGRect, () -> Void)] = []
    private weak var face: Face?

    static let favorites: [(String, String)] = [("Apple", "https://www.apple.com"), ("Wikipedia", "https://en.m.wikipedia.org"),
                                                ("Serious Eats", "https://www.seriouseats.com"), ("BBC Good Food", "https://www.bbcgoodfood.com")]

    /// 烹飪畫面最外層按返回：回到 Safari（停在剛才那一頁）
    static func returnFromCooking() { (NSApp.delegate as? AppDelegate)?.view?.shellOpenApp("safari") }

    func didOpen(now: Double) {
        addSheet = nil   // 2.0 Web App：離開過 Safari，「加入主畫面」表單收掉（iOS 的分享表單也一樣）
        // 除錯：--safari-url <網址>＝真的開這一頁、等它畫好（驗看不到的視窗出圖）
        if let j = AppUI.args.firstIndex(of: "--safari-url"), j + 1 < AppUI.args.count, let u = URL(string: AppUI.args[j + 1]) {
            open(u)
            let end = Date().addingTimeInterval(20)
            while Date() < end, web.loading || web.snapshot == nil { web.pump(CACurrentMediaTime()); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            web.settle(until: end.addingTimeInterval(3))
            return
        }
        guard let i = AppUI.args.firstIndex(of: "--demo-safari") else { return }
        let mode = i + 1 < AppUI.args.count ? AppUI.args[i + 1] : "start"
        if mode == "start", let f = (NSApp.delegate as? AppDelegate)?.view?.face { RecipesApp.shared.applyDemo(screen: "home-recents", face: f) }   // 釘選的食譜（示範）
        guard mode == "page" || mode == "reader" || mode == "stub" else { return }
        started = true
        web.setAppearance(dark: HPTokens.dark)
        web.loadHTML(Self.demoHTML(stub: mode == "stub"), base: URL(string: "https://cooking.example.com/pumpkin-soup")!)
        // 快照：等網頁排好、拍到第一張（最多 10 秒；stub 頁偵測不到食譜，不能等 isRecipe）
        let end = Date().addingTimeInterval(10)
        while Date() < end, web.loading || web.snapshot == nil || (mode != "stub" && !web.isRecipe) {
            web.pump(CACurrentMediaTime()); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        web.settle(until: end.addingTimeInterval(3))
        if mode == "reader" {
            var done = false
            web.article { [weak self] a in self?.reader = a; self?.readerOn = a != nil; done = true }
            while !done, Date() < end.addingTimeInterval(3) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
    }

    func tick(_ now: Double) -> Bool {
        if started { web.setAppearance(dark: HPTokens.dark); web.pump(now) }
        autoCookStep(now)   // 2.0 promo
        if HPComponents.needsFrame(now) { return true }
        defer { dirty = false }
        return dirty || (started && web.loading)
    }

    var backSymbol: String { "xmark" }
    func handleBack(now: Double) -> Bool {
        if addSheet != nil { closeAddToHome(); return true }   // 2.0 Web App
        if readerOn { readerOn = false; return true }
        return false
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        hits = []
        let bg = started && !readerOn ? (web.topColor ?? pageBG) : pageBG
        g.setFillColor((started ? bg : AppUI.bg).cgColor); g.fill(rect)
        if !started { renderStart(g, face) }
        else if readerOn, let a = reader { renderReader(g, face, a) }
        else { renderPage(g, face) }
        if started, web.isRecipe { cookButton(g, face) }
        toolbar(g, face)
        addSheet?.draw(g, face)   // 2.0 Web App：「加入主畫面」（Shell/WebApps/WebAppInstaller.swift）
    }

    // MARK: 加入主畫面（2.0 Web App）

    private(set) var addSheet: AddToHomeSheet?
    /// 網址列的小框、長按網址列：讀這一頁的 manifest 與圖示，出表單
    func showAddToHome() {
        guard started, SafariLogic.allowed(web.url), web.url?.absoluteString != "about:blank" else { return }
        popover?.performClose(nil)
        let s = AddToHomeSheet(draft: WebAppDraft(name: SafariLogic.displayHost(web.url), manifest: WebManifestParser.fallback(document: web.url!), icon: nil, theme: nil))
        s.onClose = { [weak self] in self?.closeAddToHome() }
        addSheet = s; dirty = true
        WebAppInstaller.prepare(web.view) { [weak self, weak s] d in
            guard let s, self?.addSheet === s else { return }
            let keepName = s.draft.name != SafariLogic.displayHost(self?.web.url) ? s.draft.name : nil   // 使用者先改了名字：留著
            s.draft.manifest = d.manifest; s.draft.icon = d.icon; s.draft.theme = d.theme; s.draft.ready = d.ready
            s.draft.name = keepName ?? d.name
            self?.dirty = true; self?.face?.forceDirty = true
        }
    }
    /// 驗收用：現在這一頁的網頁視圖（WebAppE2E 比對 Safari 看不看得到 Web App 的資料）
    var currentWebView: WKWebView? { started ? web.view : nil }
    func closeAddToHome() { addSheet = nil; dirty = true; face?.forceDirty = true }
    /// 快照：多拍幾張等網頁畫穩
    func settle(_ seconds: Double) { web.settle(until: Date().addingTimeInterval(seconds)) }

    private var pageBG: NSColor { HPTokens.dark ? .black : .white }
    private func renderPage(_ g: CGContext, _ face: Face) {
        let r = CGRect(x: 0, y: T.webTop, width: 1024, height: 1024 - T.webTop)
        if let img = web.snapshot {
            g.saveGState(); g.clip(to: r); face.drawUpright(g, img, in: r); g.restoreGState()
        } else if web.failed {
            HPComponents.emptyState(g, face, symbol: "wifi.exclamationmark", tint: AppUI.secondary, title: L("safari.failed", "打不开这个网页"),
                                    body: L("safari.failed.hint", "检查网址和网络后再试一次。"), top: 280)
        }
        if web.failed, web.snapshot != nil {
            HPComponents.emptyState(g, face, symbol: "wifi.exclamationmark", tint: AppUI.secondary, title: L("safari.failed", "打不开这个网页"), body: nil, top: 280)
        }
        // 網頁捲到 👀 膠囊底下時的柔邊
        HPComponents.topFade(g, web.topColor ?? pageBG, solidTo: T.webTop)
    }

    private func renderStart(_ g: CGContext, _ face: Face) {
        AppUI.title(g, face, L("safari.startPage", "起始页"))
        let top = T.tileTop - startScroll.offset
        g.saveGState(); g.clip(to: CGRect(x: 0, y: 196, width: 1024, height: 828))
        HPComponents.sectionHeader(g, face, L("safari.favorites", "个人收藏"), x: AppUI.margin, baseline: top - 32)
        let n = Self.favorites.count, gap = (AppUI.contentW - CGFloat(n) * T.tile) / CGFloat(n - 1)
        for (i, f) in Self.favorites.enumerated() {
            let r = CGRect(x: AppUI.margin + CGFloat(i) * (T.tile + gap), y: top, width: T.tile, height: T.tile)
            AppUI.fillRound(g, r, radius: T.tile * 0.22, color: AppUI.grouped2)
            let lf = AppUI.font(T.tile * 0.5, .regular), letter = String(f.0.prefix(1))
            AppUI.center(face, g, letter, lf, cx: r.midX, y: r.midY + lf.capHeight / 2, AppUI.secondary)
            let nf = AppUI.font(30, .medium)
            AppUI.center(face, g, Face.clipped(f.0, nf, T.tile + gap - 8), nf, cx: r.midX, y: r.maxY + 42, AppUI.label)
            HPAX.note(g, r, .button, f.0)
            let u = f.1
            hits.append((r, { [weak self] in if let url = URL(string: u) { self?.open(url) } }))
        }
        // 釘選的食譜（食譜 App 併進來之後住在這裡）
        let pinned = RecipesApp.shared.pinned
        let hy = top + T.tile + 150
        HPComponents.sectionHeader(g, face, L("safari.pinnedRecipes", "置顶的食谱"), x: AppUI.margin, baseline: hy)
        if pinned.isEmpty {
            let s = L("safari.pinned.none", "在食谱网页上点「开始烹饪」，做过的食谱会留在这里。"), f = AppUI.font(32)
            for (i, l) in Face.wrap(s, f, AppUI.contentW, maxLines: 2).enumerated() { AppUI.left(face, g, l, f, x: AppUI.margin, y: hy + 64 + CGFloat(i) * 44, AppUI.secondary) }
        } else {
            let rowH: CGFloat = 116, cardTop = hy + 32
            AppUI.group(g, CGRect(x: AppUI.margin, y: cardTop, width: AppUI.contentW, height: CGFloat(pinned.count) * rowH))
            for (i, rec) in pinned.enumerated() {
                let r = CGRect(x: AppUI.margin, y: cardTop + CGFloat(i) * rowH, width: AppUI.contentW, height: rowH)
                let c = CGRect(x: r.minX + 28, y: r.midY - 36, width: 72, height: 72)
                AppUI.fillRound(g, c, radius: 18, color: AppUI.orange.withAlphaComponent(0.18))
                face.drawSymbol(g, "fork.knife", in: c.insetBy(dx: 18, dy: 18), color: AppUI.orange)
                let tf = AppUI.font(40, .semibold), sf = AppUI.font(30)
                let cx = AppUI.chevron(g, face, rightX: r.maxX - 36, midY: r.midY)
                AppUI.left(face, g, Face.clipped(rec.title, tf, cx - r.minX - 160), tf, x: r.minX + 124, y: r.midY - 4, AppUI.label)
                var sub: [String] = []
                if let h = rec.host { sub.append(h) }
                if let s = rec.totalSeconds { sub.append(String(format: L("safari.pinned.minutes", "%d 分钟"), s / 60)) }
                AppUI.left(face, g, Face.clipped(sub.joined(separator: " · "), sf, cx - r.minX - 160), sf, x: r.minX + 124, y: r.midY + 36, AppUI.secondary)
                if i < pinned.count - 1 { AppUI.separator(g, x: r.minX + 124, maxX: r.maxX, y: r.maxY) }
                HPAX.note(g, r, .button, rec.title)
                hits.append((r, { [weak self] in RecipesApp.shared.openPinned(rec); self?.goCooking() }))
            }
        }
        g.restoreGState()
    }

    private func readerLines(_ a: SafariWeb.Article) -> [(String, NSFont, NSColor, CGFloat)] {
        var out: [(String, NSFont, NSColor, CGFloat)] = []   // 字、字型、顏色、這行的行高
        let w = AppUI.contentW
        let tf = AppUI.font(T.readerTitle, .bold), bf = AppUI.font(T.readerBody), hf = AppUI.font(T.readerBody + 4, .semibold)
        func lh(_ f: NSFont) -> CGFloat { f.pointSize * 1.32 }
        for l in Face.wrap(a.title, tf, w, maxLines: 4) { out.append((l, tf, AppUI.label, lh(tf))) }
        let host = SafariLogic.displayHost(web.url)
        if !host.isEmpty { out.append((host, AppUI.font(30), AppUI.secondary, 60)) }
        for (i, b) in a.blocks.enumerated() {
            if i == 0, b.kind == "h", b.text == a.title { continue }   // 第一個 h1 就是標題
            out.append(("", bf, .clear, 22))
            let (f, prefix) = b.kind == "h" ? (hf, "") : (bf, b.kind == "li" ? "•  " : "")
            for (i, l) in Face.wrap(prefix + b.text, f, w, maxLines: 40).enumerated() { out.append((i == 0 ? l : (prefix.isEmpty ? l : "    " + l), f, AppUI.label, lh(f))) }
        }
        return out
    }
    private func renderReader(_ g: CGContext, _ face: Face, _ a: SafariWeb.Article) {
        let lines = readerLines(a)
        let total = lines.reduce(0) { $0 + $1.3 } + T.readerTop + 260
        readerScroll.clamp(contentHeight: total, viewport: 1024)
        g.saveGState(); g.clip(to: CGRect(x: 0, y: T.webTop, width: 1024, height: 1024 - T.webTop))
        var y = T.readerTop - readerScroll.offset
        for (s, f, c, h) in lines {
            y += h
            if y > T.webTop - 10, y - h < 1024, !s.isEmpty { AppUI.left(face, g, s, f, x: AppUI.margin, y: y, c) }
        }
        g.restoreGState()
        HPAX.note(g, CGRect(x: AppUI.margin, y: T.readerTop, width: AppUI.contentW, height: 600), .text, ([a.title] + a.blocks.prefix(6).map(\.text)).joined(separator: "\n"))
        HPComponents.topFade(g, HPTokens.dark ? .black : .white, solidTo: T.webTop)
    }

    /// 食譜網頁：浮在工具列上面的「開始烹飪」（橘色染色玻璃：這一頁的主要動作）
    private func cookButton(_ g: CGContext, _ face: Face) {
        let r = T.cook
        HPComponents.filledButton(g, face, r, L("recipe.start", "开始烹饪"), tint: AppUI.orange, symbol: "fork.knife")
        hits.append((r, { [weak self] in self?.startCooking() }))
    }

    private func toolbar(_ g: CGContext, _ face: Face) {
        let canBack = started && (web.view.canGoBack || readerOn), canFwd = started && web.view.canGoForward
        HPComponents.glassCircle(g, face, T.back, symbol: "chevron.left", ink: HPGlass.ink.withAlphaComponent(canBack ? 1 : 0.35))
        HPComponents.glassCircle(g, face, T.forward, symbol: "chevron.right", ink: HPGlass.ink.withAlphaComponent(canFwd ? 1 : 0.35))
        let host = started ? SafariLogic.displayHost(web.url) : ""
        let placeholder = !started || host.isEmpty
        let text = placeholder ? L("safari.address", "搜索或输入网站名称") : host
        let leading = !started ? "magnifyingglass" : (web.readable || readerOn ? "doc.plaintext" : nil)
        let trailing: String? = started ? (web.loading ? "xmark" : "arrow.clockwise") : nil
        HPComponents.glassField(g, face, T.field, text: text, placeholder: placeholder, leading: leading, trailing: trailing,
                                progress: started && web.loading ? max(0.08, web.progress) : nil, label: placeholder ? text : String(format: L("safari.a11y.address", "地址：%@"), host))
        hits.append((T.back, { [weak self] in guard let self else { return }; if self.readerOn { self.readerOn = false } else { self.web.back() } }))
        hits.append((T.forward, { [weak self] in self?.web.forward() }))
        let f = T.field, zone = f.height * 1.2
        if leading != nil, started { hits.append((CGRect(x: f.minX, y: f.minY, width: zone, height: f.height), { [weak self] in self?.toggleReader() })) }
        if trailing != nil { hits.append((CGRect(x: f.maxX - zone, y: f.minY, width: zone, height: f.height), { [weak self] in guard let self else { return }; if self.web.loading { self.web.stop() } else { self.web.reload() } })) }
        hits.append((f, { [weak self] in self?.showAddress() }))
    }

    // MARK: 從 iPhone 傳來（2.0 promo，Shell/Handoff/PhoneHandoff.swift）

    /// 食譜網頁：網頁出來後停 PhoneHandoff.coverDelay 秒，自動進「開始烹飪」的封面（宣傳片 1.8 → 2.3 s）
    private var autoCook: (since: Double?, deadline: Double)?
    func openHandoff(_ u: URL, demoHTML: String? = nil) {
        if let demoHTML {
            started = true; readerOn = false; reader = nil
            web.setAppearance(dark: HPTokens.dark)
            web.loadHTML(demoHTML, base: u); dirty = true
        } else { open(u) }
        autoCook = (nil, CACurrentMediaTime() + 25)
    }
    private func autoCookStep(_ now: Double) {
        guard var a = autoCook else { return }
        PhoneHandoff.pageProgress(ready: web.snapshot != nil && !web.loading, now: now)
        guard started, now < a.deadline, Shell.currentApp === self else { autoCook = nil; return }
        guard web.isRecipe, !web.loading, web.snapshot != nil else { return }
        if let t = a.since {
            if now - t >= PhoneHandoff.coverDelay { autoCook = nil; startCooking() }
        } else { a.since = now; autoCook = a }
    }
    /// 先把看不到的 WKWebView（與 WebContent 行程）開起來：Handoff 進來時少等半秒
    func prewarm() { if !started { web.loadHTML("<html></html>", base: URL(string: "about:blank")!) } }
    /// 快照與示範：網頁出圖了沒
    var hasPage: Bool { web.snapshot != nil && !web.loading }
    func pumpWeb(_ now: Double) { web.pump(now) }

    // MARK: 動作

    func open(_ u: URL) {
        guard SafariLogic.allowed(u) else { return }
        started = true; readerOn = false; reader = nil
        web.setAppearance(dark: HPTokens.dark)
        web.load(u)
        dirty = true
    }

    private func toggleReader() {
        if readerOn { readerOn = false; dirty = true; return }
        guard web.readable else { return }
        web.article { [weak self] a in
            guard let self, let a else { return }
            self.reader = a; self.readerOn = true; self.readerScroll = AppScroll(); self.dirty = true; self.face?.forceDirty = true
        }
    }

    /// 開始烹飪：把這一頁的 HTML 交給食譜的解析（在本機，不再抓一次），進烹飪畫面；拆不出來就照網址抓
    private func startCooking() {
        guard let u = web.url else { return }
        web.html { [weak self] html in
            guard let self else { return }
            if let html, let r = RecipeParser.parse(html: html, sourceURL: u.absoluteString) {
                RecipesApp.shared.show(r, base: u, remember: !SnapshotPrivacy.active)
            } else if let f = self.face {
                RecipesApp.shared.open(u, face: f)
            }
            self.goCooking()
        }
    }
    private func goCooking() { (NSApp.delegate as? AppDelegate)?.view?.shellOpenApp("recipes") }

    private func showAddress() {
        guard let v = (NSApp.delegate as? AppDelegate)?.view, popover?.isShown != true else { return }
        input.text = started ? (web.url?.absoluteString ?? "") : ""
        input.onAddToHome = started && SafariLogic.allowed(web.url) && web.url?.absoluteString != "about:blank" ? { [weak self] in self?.showAddToHome() } : nil   // 2.0 Web App
        input.onSubmit = { [weak self] t in
            self?.popover?.performClose(nil)
            if let u = SafariLogic.resolve(t) { self?.open(u) }
        }
        let p = NSPopover()
        p.behavior = .transient; p.animates = true
        p.contentViewController = NSHostingController(rootView: SafariAddressView(model: input))
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        popover = p
    }

    // MARK: 點與滾

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        self.face = face
        if let s = addSheet { s.tap(p); dirty = true; return true }   // 2.0 Web App：表單開著只給它
        // 工具列與「開始烹飪」先（浮在內容上面）；再來是起始頁的磚與釘選的食譜；其他點到網頁上
        if let h = hits.first(where: { isControl($0.0) && $0.0.insetBy(dx: -6, dy: -6).contains(p) }) { h.1(); return true }
        if let h = hits.first(where: { $0.0.contains(p) }) { h.1(); return true }
        guard started, !readerOn, p.y > T.webTop else { return false }
        web.tap(css: SafariLogic.cssPoint(p, zoom: web.pageZoom))
        return true
    }
    private func isControl(_ r: CGRect) -> Bool { r.maxY > T.field.minY - 4 || r == T.cook }
    /// 2.0 Web App：長按網址列＝加入主畫面（iOS 的分享 › 加入主畫面；原生小框裡也有一顆）
    func handleLongPress(_ p: CGPoint, face: Face, now: Double) -> Bool {
        self.face = face
        guard addSheet == nil, T.field.insetBy(dx: -6, dy: -6).contains(p), started else { return false }
        showAddToHome(); return true
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        if !started { return startScroll.scroll(dy, contentHeight: 1100 + CGFloat(RecipesApp.shared.pinned.count) * 116, viewport: 1024) }
        if readerOn, let a = reader { return readerScroll.scroll(dy, contentHeight: readerLines(a).reduce(0) { $0 + $1.3 } + T.readerTop + 260, viewport: 1024) }
        web.scroll(cssDY: -dy * T.pointsPerCanvas / web.pageZoom * 1.6)
        return true
    }

    // MARK: 示範網頁（--demo-safari page|reader|stub；不連網，內容走 L()，三種語言都有）

    /// stub＝掛了 Recipe 結構描述卻沒有食材也沒有步驟的頁（驗收「開始烹飪」只在解析得了時出現）
    static func demoHTML(stub: Bool = false) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let ld = stub
            ? "<script type=\"application/ld+json\">{\"@context\":\"https://schema.org\",\"@type\":\"Recipe\",\"name\":\"\(esc(L("recipe.demo.title", "奶油南瓜浓汤")))\"}</script></head></html>"
            : RecipesApp.demoJSONLD()
        let head = ld.replacingOccurrences(of: "</head></html>", with: "")
        let ing = [L("recipe.demo.i1", "南瓜 600 克"), L("recipe.demo.i2", "洋葱 1 颗"), L("recipe.demo.i3", "奶油 20 克"), L("recipe.demo.i4", "鸡高汤 700 毫升")]
        let steps = [L("recipe.demo.s1", "南瓜去皮切块，洋葱切丝。"), L("recipe.demo.s3", "南瓜和洋葱放进锅里，中火炒到洋葱变透明，大约 8 分钟。"),
                     L("recipe.demo.s4", "加入高汤盖过食材，煮开后转小火，盖上锅盖煮 25 分钟，直到南瓜软烂。")]
        let css = "<meta name=viewport content='width=device-width'><style>:root{color-scheme:light dark}body{font:17px -apple-system;margin:0 18px;line-height:1.45}"
            + "h1{font-size:28px;margin:18px 0 6px}.hero{height:150px;border-radius:14px;background:linear-gradient(135deg,#f6a43a,#c8551d)}"
            + ".by{color:#8a8a8e;font-size:14px}h2{font-size:21px;margin-top:22px}</style>"
        let body = "<body><article><div class=by>cooking.example.com</div><h1>\(esc(L("recipe.demo.title", "奶油南瓜浓汤")))</h1><div class=hero></div>"
            + "<p>\(esc(L("safari.demo.p1", "秋天最适合来一碗浓汤：南瓜的甜味加上一点奶油，三十五分钟就能上桌，四个人刚好。")))</p>"
            + "<p>\(esc(L("safari.demo.p2", "用调理棒直接在锅里打，少洗一个果汁机。喜欢辣的话，最后撒一点辣椒粉。")))</p>"
            + "<h2>\(esc(L("safari.demo.ingredients", "食材")))</h2><ul>" + ing.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
            + "<h2>\(esc(L("safari.demo.steps", "做法")))</h2><ol>" + steps.map { "<li>\(esc($0))</li>" }.joined() + "</ol></article></body></html>"
        return head + css + "</head>" + body
    }
}

// MARK: - 網址列（桌寵旁邊的原生小框；沒有螢幕鍵盤，用實體鍵盤或聽寫）

final class SafariAddressModel: ObservableObject {
    @Published var text = ""
    var onSubmit: ((String) -> Void)?
    var onAddToHome: (() -> Void)?   // 2.0 Web App
}

struct SafariAddressView: View {
    @ObservedObject var model: SafariAddressModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("safari.address", "搜索或输入网站名称"), text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.onSubmit?(model.text) }
                .frame(width: 320)
            Label(L("input.noOnscreenKeyboard", "没有屏幕键盘：用键盘打字，或按两下 fn 听写"), systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
            if let add = model.onAddToHome {   // 2.0 Web App：iOS 的分享 › 加入主畫面
                Divider()
                Button { add() } label: { Label(L("sb.menu.addToHome", "添加到主屏幕"), systemImage: "plus.app") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

// MARK: - 自檢

enum SafariSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(SafariLogic.resolve("apple.com")?.absoluteString == "https://apple.com"
              && SafariLogic.resolve("https://www.apple.com/homeview")?.host == "www.apple.com"
              && SafariLogic.resolve("  ")  == nil, "Safari：網域補 https、完整網址照用、空白不開")   // l10n-ignore：selftest 訊息
        let s = SafariLogic.resolve("pumpkin soup recipe")
        check(s?.host == "www.google.com" && s?.query?.contains("q=pumpkin%20soup%20recipe") == true, "Safari：其他字當搜尋")   // l10n-ignore
        check(SafariLogic.resolve("javascript:alert(1)")?.host == "www.google.com" && SafariLogic.resolve("file:///etc/passwd")?.host == "www.google.com",
              "Safari：javascript:、file: 不會被當網址開")   // l10n-ignore
        check(SafariLogic.allowed(URL(string: "https://a.com")) && !SafariLogic.allowed(URL(string: "file:///tmp/x")) && !SafariLogic.allowed(URL(string: "ftp://a.com"))
              && SafariLogic.allowed(URL(string: "about:blank")) && !SafariLogic.allowed(nil), "Safari：只放行 http／https")   // l10n-ignore
        check(SafariLogic.displayHost(URL(string: "https://www.seriouseats.com/x")) == "seriouseats.com", "Safari：網址列只顯示網域")   // l10n-ignore
        let c = SafariLogic.cssPoint(CGPoint(x: 300, y: HPTokens.Safari.webTop + 300), zoom: 1.5)
        check(abs(c.x - 100) < 0.01 && abs(c.y - 100) < 0.01, "Safari：畫布座標換成網頁座標（÷2÷放大）")   // l10n-ignore
        check(SafariApp.demoHTML().contains("application/ld+json") && RecipeParser.parse(html: SafariApp.demoHTML(), sourceURL: "https://cooking.example.com/x") != nil,
              "Safari：示範網頁拆得出食譜（開始烹飪走本機解析）")   // l10n-ignore
        check(AppRegistry.app("recipes") != nil && !AppRegistry.visible.contains { $0.id == "recipes" } && AppRegistry.visible.contains { $0.id == "safari" },
              "Safari：食譜併進 Safari（深連結還在、主畫面與資料庫沒有食譜）")   // l10n-ignore
        let f = HPTokens.Safari.self
        check(f.back.width >= 88 && f.field.height >= 88 && f.field.minX > f.back.maxX && f.forward.minX > f.field.maxX && abs(f.back.midX - (1024 - f.forward.midX)) < 0.5,
              "Safari：底部三件玻璃左右對稱、點按範圍 ≥ 88")   // l10n-ignore
    }
}
