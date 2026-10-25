// 2.0 Web App 的示範與快照（不連外網）：本機 127.0.0.1 起一個內建的示範 PWA「购物清单」（manifest＋service worker＋widget 範本），
// 走跟真的一模一樣的路：Safari 打開 → 讀 manifest／圖示 → 加入主畫面 → 獨立執行、小工具。
//
//   --demo-webapps sheet|home|app|prompt|settings   [--webapp-url <網址>：換成真的網頁（例如 scratchpad 的 PWA、公開的 PWA）]
//   sheet＝Safari 上的「加入主畫面」；home＝主畫面（圖示＋小工具，記得加 --home）；app＝獨立執行；prompt＝相機權限詢問；settings＝設定裡有一個（配 --open-settings permissions）。
// 快照一律只放在記憶體（WebAppStore.demoOnly），網站資料用 nonPersistent。

import AppKit
import Network
import WebKit

enum WebAppDemo {
    nonisolated(unsafe) static var mode: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-webapps") else { return nil }
        return i + 1 < a.count && !a[i + 1].hasPrefix("--") ? a[i + 1] : "home"
    }()
    /// 快照：打開 Web App 時等網頁畫好再拍
    static var waitsForPaint: Bool { mode != nil }

    static func spin(_ seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// AppDemoFlags 叫（applyShellSnapshotFlags 之後）
    static func apply(face: Face) {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--webapp-e2e"), i + 1 < a.count, let u = URL(string: a[i + 1]) { WebAppE2E.run(u) }
        guard let mode else { return }
        if mode == "settings" {   // 設定的快照：不跑網路（設定視窗的計時器會在等網頁時先拍下去），直接放一個示範的
            let img = NSImage(data: DemoPWAServer.icon()).flatMap { i -> CGImage? in var r = NSRect(x: 0, y: 0, width: 256, height: 256); return i.cgImage(forProposedRect: &r, context: nil, hints: nil) }
            WebAppStore.shared.add(WebApp(uuid: UUID().uuidString, manifestID: "http://127.0.0.1/app/", name: L("webapp.demo.name", "购物清单"), startURL: "http://127.0.0.1/app/",
                                          scope: "http://127.0.0.1/app/", display: "standalone", theme: 0x34C759, background: 0xF2F2F7, person: PersonHome.viewerID,
                                          added: Date().timeIntervalSince1970, permissions: ["camera": "allow", "notifications": "deny"]), icon: img)
            return
        }
        let custom = a.firstIndex(of: "--webapp-url").flatMap { $0 + 1 < a.count ? URL(string: a[$0 + 1]) : nil }
        if custom == nil { DemoPWAServer.shared.start() }
        guard let page = custom ?? DemoPWAServer.shared.url("/app/") else { log("webapp demo: no server"); return }
        // 1. Safari 打開那一頁
        let safari = SafariApp.shared
        safari.open(page)
        spin(20) { safari.pumpWeb(CACurrentMediaTime()); return safari.hasPage }
        // 2. 讀 manifest、圖示（表單）
        if Shell.homeHue == nil { let shot = face.render(); Shell.homeHue = Shell.hue(fromFace: shot, face: face); Shell.captureHomeBackdrop(shot) }
        if SB.forcedLayout == nil { SB.forcedLayout = .official; SB.owner = .none }
        safari.showAddToHome()
        spin(15) { safari.addSheet?.draft.ready == true }
        safari.settle(3)
        if mode == "sheet" {
            Shell.nav.screen = .app("safari"); Shell.nav.appReturn = .home
            return
        }
        // 3. 加入主畫面（每人一份：現在這個人的）
        guard let draft = safari.addSheet?.draft, let app = WebAppInstaller.add(draft) else { log("webapp demo: add failed"); return }
        safari.closeAddToHome()
        if mode == "home" || mode == "widget" {
            // 第二頁：小工具（中）＋這個 Web App＋幾個內建的
            let tag = app.widgets.first?.tag ?? WebAppWidgets.iconTag
            let w = SBWidget(id: "wa", kind: .webApp, size: .medium, config: ["app": app.appID, "tag": tag])
            var l = SBLayout.official
            l.pages.append(SBPage(items: [.widget(w), .app(app.appID), .widget(SBWidget(id: "wi", kind: .webApp, size: .wide, config: ["app": app.appID, "tag": WebAppWidgets.iconTag])),
                                          .app("safari"), .app("weather")]))
            l.normalize()
            SB.forcedLayout = l; SB.owner = .none; _ = SB.layout
            SB.page = 1
            _ = WebAppWidgets.card(app, tag: tag)
            spin(8) { !WebAppWidgets.pending && WebAppWidgets.card(app, tag: tag) != nil }
            spin(4) { !WebAppWidgets.pending }
            Shell.nav.screen = .home
            return
        }
        // 4. 獨立執行
        Shell.nav.screen = .app(app.appID); Shell.nav.appReturn = .home
        guard let pa = AppRegistry.app(app.appID) as? WebAppApp else { return }
        pa.didOpen(now: CACurrentMediaTime())
        if mode == "prompt" { pa.demoAsk(.camera) }
        if mode == "scope", let rt = pa.runtime, let u = DemoPWAServer.shared.url("/elsewhere/") { rt.load(u); rt.settle(until: Date().addingTimeInterval(8)) }
    }
}

// MARK: - 內建示範 PWA（127.0.0.1、隨機埠；只在 --demo-webapps 時開）

final class DemoPWAServer {
    static let shared = DemoPWAServer()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "homeplay.webapp.demo")

    func url(_ path: String) -> URL? { port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)\(path)") }

    func start() {
        guard listener == nil else { return }
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: p) else { return }
        let files = Self.files()
        l.newConnectionHandler = { [weak self] c in self?.serve(c, files) }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { st in if case .ready = st { ready.signal() }; if case .failed = st { ready.signal() } }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        port = l.port?.rawValue ?? 0
        listener = l
    }

    private func serve(_ c: NWConnection, _ files: [String: (String, Data)]) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { d, _, _, _ in
            let head = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = head.split(separator: " ").dropFirst().first.map(String.init)?.split(separator: "?").first.map(String.init) ?? "/"
            let key = path.hasSuffix("/") ? path + "index.html" : path
            let (type, body) = files[key] ?? ("text/plain", Data("not found".utf8))
            let status = files[key] == nil ? "404 Not Found" : "200 OK"
            var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            out.append(body)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
    static func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data() }

    /// 內容走 L()（三種語言都有），圖示當場畫
    static func files() -> [String: (String, Data)] {
        let name = L("webapp.demo.name", "购物清单")
        let items = [L("webapp.demo.i1", "牛奶"), L("webapp.demo.i2", "鸡蛋"), L("webapp.demo.i3", "南瓜"), L("webapp.demo.i4", "面包")]
        let manifest: [String: Any] = [
            "name": name, "short_name": name, "id": "/app/", "start_url": "/app/?source=homescreen", "scope": "/app/", "display": "standalone",
            "theme_color": "#34C759", "background_color": "#F2F2F7",
            "icons": [["src": "/app/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"]],
            "widgets": [["name": name, "short_name": name, "description": L("webapp.demo.widget", "看看还要买什么。"), "tag": "groceries",
                         "template": "groceries", "ms_ac_template": "/app/widget/template.json", "data": "/app/widget/data.json", "type": "application/json", "update": 900,
                         "screenshots": [["src": "/app/icon-512.png", "sizes": "512x512"]]]],
        ]
        let template: [String: Any] = ["type": "AdaptiveCard", "version": "1.5", "body": [
            ["type": "TextBlock", "text": "${title}", "size": "Medium", "weight": "Bolder"],
            ["type": "TextBlock", "text": "${subtitle}", "isSubtle": true, "spacing": "None"],
            ["type": "ColumnSet", "spacing": "Medium", "columns": [
                ["type": "Column", "width": "stretch", "items": [["type": "Container", "$data": "${left}", "items": [["type": "TextBlock", "text": "○  ${name}"]]]]],
                ["type": "Column", "width": "stretch", "items": [["type": "Container", "$data": "${right}", "items": [["type": "TextBlock", "text": "○  ${name}"]]]]],
            ]],
        ]]
        let data: [String: Any] = ["title": name, "subtitle": String(format: L("webapp.demo.left", "还要买 %d 样"), items.count),
                                   "left": items.prefix(2).map { ["name": $0] }, "right": items.suffix(2).map { ["name": $0] }]
        let css = ":root{color-scheme:light dark}body{font:17px -apple-system;margin:0;background:#F2F2F7;color:#000}"
            + "@media(prefers-color-scheme:dark){body{background:#000;color:#fff}li,form{background:#1C1C1E!important}}"
            + "h1{font-size:30px;margin:14px 18px 8px}ul{list-style:none;margin:0 14px;padding:0}li{background:#fff;margin:0 0 8px;padding:13px 16px;border-radius:14px;display:flex;gap:12px;align-items:center}"
            + "li.done span{text-decoration:line-through;opacity:.45}.c{width:22px;height:22px;border-radius:11px;border:2px solid #34C759}.done .c{background:#34C759}"
            + "form{display:flex;gap:8px;margin:12px 14px;background:#fff;border-radius:14px;padding:8px}input{flex:1;font:17px -apple-system;border:0;background:transparent;outline:0}"
            + "button{font:600 16px -apple-system;background:#34C759;color:#fff;border:0;border-radius:10px;padding:8px 14px}.s{color:#8a8a8e;font-size:13px;margin:8px 18px}"
        let js = "var K='groceries',d=JSON.parse(localStorage.getItem(K)||'null')||" + String(decoding: json(items.map { ["t": $0, "d": false] }), as: UTF8.self) + ";"
            + "function save(){localStorage.setItem(K,JSON.stringify(d))}function draw(){var u=document.getElementById('l');u.innerHTML='';d.forEach(function(x,i){var li=document.createElement('li');"
            + "if(x.d)li.className='done';li.innerHTML='<i class=c></i><span></span>';li.querySelector('span').textContent=x.t;li.onclick=function(){x.d=!x.d;save();draw()};u.appendChild(li)})}"
            + "document.getElementById('f').onsubmit=function(e){e.preventDefault();var i=document.getElementById('n');if(i.value.trim()){d.push({t:i.value.trim(),d:false});save();draw()}i.value=''};draw();"
            + "if('serviceWorker' in navigator){navigator.serviceWorker.register('/app/sw.js').then(function(){document.getElementById('sw').textContent='"
            + L("webapp.demo.offline", "可以离线使用") + "'}).catch(function(){})}"
        let html = "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width'><title>\(esc(name))</title>"
            + "<link rel=manifest href='/app/manifest.webmanifest'><meta name=theme-color content='#34C759'><style>\(css)</style></head><body>"
            + "<h1>\(esc(name))</h1><ul id=l></ul><form id=f><input id=n placeholder=\"\(esc(L("webapp.demo.add", "添加项目")))\"><button>\(esc(L("webapp.demo.addButton", "添加")))</button></form>"
            + "<div class=s id=sw></div><p class=s><a href='/elsewhere/'>\(esc(L("webapp.demo.link", "供应商网站")))</a></p><script>\(js)</script></body></html>"
        let sw = "self.addEventListener('install',e=>e.waitUntil(caches.open('v1').then(c=>c.addAll(['/app/','/app/icon-512.png']))));"
            + "self.addEventListener('fetch',e=>e.respondWith(fetch(e.request).catch(()=>caches.match(e.request))));"
        let other = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><body style='font:17px -apple-system;margin:18px'><h1>\(esc(L("webapp.demo.link", "供应商网站")))</h1></body>"
        return ["/app/index.html": ("text/html; charset=utf-8", Data(html.utf8)),
                "/app/manifest.webmanifest": ("application/manifest+json", json(manifest)),
                "/app/sw.js": ("text/javascript", Data(sw.utf8)),
                "/app/icon-512.png": ("image/png", icon()),
                "/app/widget/template.json": ("application/json", json(template)),
                "/app/widget/data.json": ("application/json", json(data)),
                "/elsewhere/index.html": ("text/html; charset=utf-8", Data(other.utf8))]
    }

    /// 示範圖示：綠底（maskable 滿版）＋白色購物車
    static func icon() -> Data {
        let img = makeImage(512, 512) { g in
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [srgb(0x5BD97A).cgColor, srgb(0x28A745).cgColor] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
            if let sym = NSImage(systemSymbolName: "cart.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 230, weight: .semibold)) {
                let tinted = NSImage(size: sym.size, flipped: false) { r in sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
                var rr = NSRect(origin: .zero, size: tinted.size)
                if let cg = tinted.cgImage(forProposedRect: &rr, context: nil, hints: nil) {
                    let w = CGFloat(cg.width) / CGFloat(cg.height) * 250
                    g.saveGState(); g.translateBy(x: 0, y: 512); g.scaleBy(x: 1, y: -1)
                    g.draw(cg, in: CGRect(x: 256 - w / 2, y: 131, width: w, height: 250)); g.restoreGState()
                }
            }
        }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - selftest：manifest、範圍、網站資料分開、門

enum WebAppSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias P = WebManifestParser
        let doc = URL(string: "https://shop.example/app/list?x=1#top")!, mu = URL(string: "https://shop.example/app/manifest.json")!
        let m = P.parse(json: Data(##"{"name":" Groceries ","short_name":"Shop","start_url":"./?src=hs#f","scope":"/app/","id":"/app/?u=1#z","display":"STANDALONE ","theme_color":"#3c7","background_color":"rgb(242, 242, 247)","icons":[{"src":"i192.png","sizes":"192x192"},{"src":"i512.png","sizes":"512x512","purpose":"maskable"},{"src":"bad.png","purpose":"nope"}],"widgets":[{"name":"List","tag":"l","ms_ac_template":"/app/t.json","data":"https://evil.example/d.json"},{"name":"x"}]}"##.utf8), manifestURL: mu, documentURL: doc)
        check(m.name == "Groceries" && m.shortName == "Shop" && m.startURL.absoluteString == "https://shop.example/app/?src=hs" && m.scope.absoluteString == "https://shop.example/app/"
              && m.id.absoluteString == "https://shop.example/app/?u=1" && m.display == "standalone", "Web App：manifest 的名字、start_url、scope、id（去 fragment）、display")   // l10n-ignore：selftest 訊息
        check(m.themeColor == 0x33CC77 && m.backgroundColor == 0xF2F2F7 && m.icons.count == 2 && m.icons[1].purpose == ["maskable"] && m.icons[0].size == 192,
              "Web App：theme／background 顏色、icons（purpose 不認得的丟掉）")   // l10n-ignore：selftest 訊息
        check(m.widgets.count == 1 && m.widgets[0].template?.absoluteString == "https://shop.example/app/t.json" && m.widgets[0].data == nil,
              "Web App：widgets 只收同源的範本與資料、沒有 tag 的不要")   // l10n-ignore：selftest 訊息
        // 規格的退路：別人的 start_url → 文件網址；scope 不含 start_url → 預設；id 不同源 → start_url；display 不認得 → browser
        let bad = P.parse(json: Data(#"{"start_url":"https://evil.example/","scope":"/other/","id":"https://evil.example/x","display":"kiosk"}"#.utf8), manifestURL: mu, documentURL: doc)
        check(bad.startURL.absoluteString == "https://shop.example/app/list?x=1" && bad.scope.absoluteString == "https://shop.example/app/" && bad.id == bad.startURL && bad.display == "browser",
              "Web App：不同源的 start_url／id、不含 start_url 的 scope、不認得的 display 照規格退回")   // l10n-ignore：selftest 訊息
        check(P.parse(json: Data("nope".utf8), manifestURL: mu, documentURL: doc).scope.absoluteString == "https://shop.example/app/"
              && P.defaultScope(URL(string: "https://a.example/x/y/index.html?q=1")!).absoluteString == "https://a.example/x/y/", "Web App：壞掉的 manifest 照沒有 manifest（這一頁的資料夾）")   // l10n-ignore：selftest 訊息
        // 範圍
        let s = URL(string: "https://shop.example/app/")!
        check(P.inScope(URL(string: "https://shop.example/app/item/3")!, scope: s) && !P.inScope(URL(string: "https://shop.example/apple")!, scope: s)
              && !P.inScope(URL(string: "http://shop.example/app/")!, scope: s) && !P.inScope(URL(string: "https://shop.example:8443/app/")!, scope: s)
              && !P.inScope(URL(string: "https://evil.example/app/")!, scope: s) && !P.inScope(URL(string: "file:///app/")!, scope: s),
              "Web App：範圍＝同源（scheme、host、port）而且路徑在 scope 底下")   // l10n-ignore：selftest 訊息
        // 圖示：apple-touch-icon 優先；再 maskable ≥192 最小的；SVG 最後
        let ic = [WebManifestIcon(src: URL(string: "https://s/a.svg")!, size: 1024, purpose: ["any"], type: "image/svg+xml"),
                  WebManifestIcon(src: URL(string: "https://s/m1024.png")!, size: 1024, purpose: ["maskable"]), WebManifestIcon(src: URL(string: "https://s/m256.png")!, size: 256, purpose: ["maskable"]),
                  WebManifestIcon(src: URL(string: "https://s/a512.png")!, size: 512, purpose: ["any"])]
        check(P.pickIcon(touchIcons: [URL(string: "https://s/t.png")!], icons: ic)?.lastPathComponent == "t.png" && P.pickIcon(touchIcons: [], icons: ic)?.lastPathComponent == "m256.png"
              && P.pickIcon(touchIcons: [], icons: [ic[0]])?.lastPathComponent == "a.svg" && P.pickIcon(touchIcons: [], icons: []) == nil, "Web App：挑圖示的順序（apple-touch-icon → maskable → any，點陣優先）")   // l10n-ignore：selftest 訊息
        check(CSSColor.parse("#FFF") == 0xFFFFFF && CSSColor.parse("#11223344") == 0x112233 && CSSColor.parse("rgba(0, 128, 255, .5)") == 0x0080FF && CSSColor.parse("Teal") == 0x008080
              && CSSColor.parse("#xyz") == nil && CSSColor.isLight(0xF2F2F7) && !CSSColor.isLight(0x34C759 & 0x1F1F1F), "Web App：CSS 顏色與黑白字")   // l10n-ignore：selftest 訊息
        // 名字：apple-mobile-web-app-title → short_name → name → 標題
        let head = WebAppInstaller.Head(url: doc, manifest: nil, touch: [], icons: [], theme: nil, appTitle: nil, title: "A long page title")
        check(WebAppInstaller.name(head: head, manifest: m) == "Shop" && WebAppInstaller.name(head: head, manifest: WebManifestParser.fallback(document: doc)) == "A long page title",
              "Web App：預設名字的順序")   // l10n-ignore：選測訊息
        // 網站資料：每個 Web App 一份、跟 Safari 分開
        let u1 = UUID().uuidString, u2 = UUID().uuidString
        let d1 = WebAppData.store(u1), d2 = WebAppData.store(u2)
        defer { for u in [u1, u2] { WKWebsiteDataStore.remove(forIdentifier: WebAppData.identifier(u)) { _ in } } }
        check(d1.isPersistent && d2.isPersistent && d1.identifier != d2.identifier && d1.identifier == UUID(uuidString: u1) && d1 !== WKWebsiteDataStore.default(),
              "Web App：每個 Web App 自己一份持久的網站資料，跟 Safari、跟別的 Web App 分開")   // l10n-ignore：selftest 訊息
        // 門：訪客、遠端訪客、別人、認不出的都不行；主人照 PersonalGate；家人要認出是他（提示不算）
        typealias G = WebAppGate
        var i = PersonalGate.Inputs()
        check(G.canOpen(i, person: "o", viewer: "o", viewerIsOwner: true) && !G.canOpen(i, person: "kid", viewer: "o", viewerIsOwner: true), "Web App 門：主人開自己的；別人的不行")   // l10n-ignore：selftest 訊息
        i.guestMode = true
        check(!G.canOpen(i, person: "o", viewer: "o", viewerIsOwner: true), "Web App 門：訪客模式一律不行")   // l10n-ignore：selftest 訊息
        i = PersonalGate.Inputs(remoteGuest: true)
        check(!G.canOpen(i, person: "o", viewer: "o", viewerIsOwner: true), "Web App 門：遠端訪客的裝置不行")   // l10n-ignore：selftest 訊息
        i = PersonalGate.Inputs(hintIsOwner: false)
        check(!G.canOpen(i, person: "kid", viewer: "kid", viewerIsOwner: false) && !G.canOpen(i, person: "o", viewer: nil, viewerIsOwner: false), "Web App 門：「換人」的提示不能替家人開門、沒人不行")   // l10n-ignore：selftest 訊息
        i = PersonalGate.Inputs(recognitionActive: true, viewer: .known("kid"))
        check(G.canOpen(i, person: "kid", viewer: "kid", viewerIsOwner: false) && !G.canOpen(PersonalGate.Inputs(recognitionActive: true, viewer: .guest), person: "kid", viewer: "kid", viewerIsOwner: false),
              "Web App 門：認出家人才開他的、認不出的不行")   // l10n-ignore：selftest 訊息
        check(G.canOpen(i, person: "o", viewer: "kid", viewerIsOwner: false, shared: true) && !G.canOpen(i, person: "o", viewer: "kid", viewerIsOwner: false, shared: false)
              && !G.canOpen(PersonalGate.Inputs(recognitionActive: true, viewer: .known("kid"), remoteGuest: true), person: "o", viewer: "kid", viewerIsOwner: false, shared: true),
              "Web App 門：家庭看板（共享）認出的家人都能開；遠端訪客照樣不行")   // l10n-ignore：selftest 訊息
        // 每人一份：只出現在加的那個人的主畫面與資料庫；不認得的 id 在存檔清理時拿掉
        let st = WebAppStore.shared
        let saved = st.useMemory([WebApp(uuid: u1, manifestID: "x", name: "Groceries", startURL: "https://shop.example/app/", scope: "https://shop.example/app/", display: "standalone",
                                         theme: nil, background: nil, person: "kid", added: 0)])
        defer { st.restore(saved) }
        check(st.apps(for: "kid").count == 1 && st.apps(for: "someone").isEmpty && AppRegistry.app("web." + u1) != nil && AppRegistry.app("web.gone") == nil,
              "Web App：每人一份、App id 認得出來")   // l10n-ignore：selftest 訊息
        var lay = SBLayout(pages: [SBPage(items: [.app("web." + u1), .app("web.gone"), .app("music")])])
        lay.sanitize()
        check(lay.pages[0].items == [.app("web." + u1), .app("music")], "Web App：主畫面存檔裡刪掉的 Web App 清掉、還在的留著")   // l10n-ignore：selftest 訊息
        check(RemotePrivacy.guestSafe(RemotePrivacy.Screen(gateOpen: true, screen: .app("web." + u1))) == false && AppProviders.isPersonal("web." + u1),
              "Web App：遠端訪客的裝置看不到開著的 Web App")   // l10n-ignore：selftest 訊息
        // 範圍外的連結交給 Safari、file: 與自訂 scheme 擋掉（決策用的純函數）
        let wa = st.apps[0]
        check(wa.inScope(URL(string: "https://shop.example/app/x")!) && !wa.inScope(URL(string: "https://login.example/")!) && !WebManifestParser.allowedScheme(URL(string: "myapp://x")!)
              && !WebManifestParser.allowedScheme(URL(string: "file:///etc/hosts")!), "Web App：範圍外與非網頁的網址分得出來")   // l10n-ignore：selftest 訊息
        check(WebAppProvider.shared.menuRows("web." + u1, canEdit: true).map(\.verb) == ["rename", "widget:_icon", "delete"] && WebAppProvider.shared.menuRows("web." + u1, canEdit: false).isEmpty,
              "Web App：長按選單有重新命名、加小工具、刪除（訪客沒有）")   // l10n-ignore：selftest 訊息
    }
}
