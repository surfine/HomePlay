// 2.0 Safari 的「加入主畫面」（iOS 26 同款）：讀這一頁的 manifest 與 apple-touch-icon、名字可以改、圖示預覽、
// 「以 Web App 開啟」開關（關掉＝書籤，點了在 Safari 開），加到「現在這個人」的主畫面（SpringBoard 的 SB.addToHome），
// App 資料庫也看得到。之後的重新命名、刪除在主畫面長按選單（WebAppProvider.menuRows）。
//
// 抓 manifest 與圖示：短暫的 URLSession（不帶 cookie、不留快取；Safari 頁本來就不存 cookie），只走 http／https，大小有上限。

import AppKit
import SwiftUI
import WebKit

// MARK: - 抓檔

enum WebFetch {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 15
        c.httpCookieAcceptPolicy = .never; c.httpShouldSetCookies = false; c.urlCache = nil
        return URLSession(configuration: c)
    }()
    /// 抓一個網址（http／https、≤ limit 位元組）；在主執行緒回
    static func get(_ u: URL, limit: Int, session: URLSession = session, done: @escaping (Data?) -> Void) {
        guard WebManifestParser.allowedScheme(u) else { done(nil); return }
        var r = URLRequest(url: u); r.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: r) { d, resp, _ in
            let ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2 && (d?.count ?? 0) <= limit
            DispatchQueue.main.async { done(ok ? d : nil) }
        }.resume()
    }
    static func image(_ d: Data) -> CGImage? {
        guard let img = NSImage(data: d) else { return nil }
        var r = NSRect(x: 0, y: 0, width: 256, height: 256)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}

// MARK: - 從網頁收集

struct WebAppDraft {
    var name: String
    var manifest: WebManifest
    var icon: CGImage?          // 已經裁成 256² 方圖；nil＝字母圖示
    var theme: UInt32?
    var standalone = true
    var ready = false
    var host: String { SafariLogic.displayHost(manifest.startURL) }

    func makeApp(person: String?, now: Date = Date()) -> WebApp {
        WebApp(uuid: UUID().uuidString, manifestID: manifest.id.absoluteString, name: name, startURL: manifest.startURL.absoluteString,
               scope: manifest.scope.absoluteString, display: standalone ? "standalone" : "browser", theme: theme, background: manifest.backgroundColor,
               person: person, added: now.timeIntervalSince1970, widgets: manifest.widgets)
    }
}

enum WebAppInstaller {
    /// 網頁 <head> 裡跟「加入主畫面」有關的：manifest、apple-touch-icon、icon、theme-color、標題
    static let headJS = """
    (function(){function abs(h){try{return h?new URL(h,document.baseURI).href:null}catch(e){return null}}
    function links(sel){return [].slice.call(document.querySelectorAll(sel)).map(function(l){return {h:abs(l.getAttribute('href')),s:l.getAttribute('sizes')||''}}).filter(function(x){return x.h})}
    var m=document.querySelector('link[rel~="manifest"]'),tc=document.querySelector('meta[name="theme-color"]');
    var at=document.querySelector('meta[name="apple-mobile-web-app-title"]')||document.querySelector('meta[name="application-name"]');
    return JSON.stringify({url:location.href,manifest:m?abs(m.getAttribute('href')):null,touch:links('link[rel~="apple-touch-icon"],link[rel~="apple-touch-icon-precomposed"]'),
      icons:links('link[rel~="icon"]'),theme:tc?tc.content:null,appTitle:at?at.content:null,title:document.title||''})})()
    """

    struct Head { var url: URL; var manifest: URL?; var touch: [(URL, Int)]; var icons: [(URL, Int)]; var theme: String?; var appTitle: String?; var title: String }
    static func parseHead(_ s: String) -> Head? {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let u = (o["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        func list(_ k: String) -> [(URL, Int)] {
            ((o[k] as? [[String: Any]]) ?? []).compactMap { e in
                guard let h = (e["h"] as? String).flatMap(URL.init(string:)), WebManifestParser.allowedScheme(h) else { return nil }
                return (h, WebManifestParser.maxSize(e["s"] as? String))
            }
        }
        return Head(url: u, manifest: (o["manifest"] as? String).flatMap(URL.init(string:)), touch: list("touch"), icons: list("icons"),
                    theme: o["theme"] as? String, appTitle: o["appTitle"] as? String, title: o["title"] as? String ?? "")
    }

    /// 名字：apple-mobile-web-app-title → short_name → name → 網頁標題 → 網域（最多 32 個字）
    static func name(head: Head, manifest: WebManifest) -> String {
        let c = [head.appTitle, manifest.shortName, manifest.name, head.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return String((c ?? SafariLogic.displayHost(head.url)).prefix(32))
    }

    /// 讀 head → 抓 manifest → 挑圖示、抓圖示；每一步都更新 draft（表單先出來，資料陸續補上）
    static func prepare(_ web: WKWebView, session: URLSession = WebFetch.session, update: @escaping (WebAppDraft) -> Void) {
        web.evaluateJavaScript(headJS) { r, _ in
            guard let s = r as? String, let head = parseHead(s), WebManifestParser.allowedScheme(head.url) else { return }
            var draft = WebAppDraft(name: SafariLogic.displayHost(head.url), manifest: WebManifestParser.fallback(document: head.url), icon: nil,
                                    theme: head.theme.flatMap(CSSColor.parse))
            update(draft)
            func finishIcon(_ m: WebManifest) {
                draft.manifest = m
                draft.name = name(head: head, manifest: m)
                draft.theme = head.theme.flatMap(CSSColor.parse) ?? m.themeColor   // <meta name=theme-color> 蓋過 manifest
                update(draft)
                let touch = head.touch.sorted { $0.1 > $1.1 }.map(\.0)
                let favicons = head.icons.filter { $0.1 >= 120 }.sorted { $0.1 > $1.1 }.map(\.0)
                let candidates = [WebManifestParser.pickIcon(touchIcons: touch, icons: m.icons)].compactMap { $0 } + favicons
                func tryIcon(_ i: Int) {
                    guard i < candidates.count else { draft.ready = true; update(draft); return }
                    WebFetch.get(candidates[i], limit: 4 << 20, session: session) { d in
                        if let d, let img = WebFetch.image(d) {
                            draft.icon = WebAppIcons.square(img, background: m.backgroundColor); draft.ready = true; update(draft)
                        } else { tryIcon(i + 1) }
                    }
                }
                tryIcon(0)
            }
            if let mu = head.manifest, WebManifestParser.allowedScheme(mu) {
                WebFetch.get(mu, limit: 256 << 10, session: session) { d in
                    finishIcon(d.map { WebManifestParser.parse(json: $0, manifestURL: mu, documentURL: head.url) } ?? WebManifestParser.fallback(document: head.url))
                }
            } else { finishIcon(draft.manifest) }
        }
    }

    /// 訪客模式、遠端訪客、認不出的人不能加（主畫面是每人一份的）
    static var canAdd: Bool { (PersonHome.canEdit && !RemotePrivacy.guestActive) || SB.forcedLayout != nil }
    /// 加進去：存 Web App、放進現在這個人的主畫面（最後一頁第一個空位），回主畫面停在那一頁
    @discardableResult
    static func add(_ draft: WebAppDraft) -> WebApp? {
        guard WebAppInstaller.canAdd else { return nil }
        let app = draft.makeApp(person: PersonHome.viewerID)
        WebAppStore.shared.add(app, icon: draft.icon)
        SB.addToHome(app.appID)
        log("webapp added")
        return app
    }
}

// MARK: - 「加入主畫面」表單（畫在 Safari 上；玻璃卡、跟主畫面的表單同一種）

final class AddToHomeSheet {
    var draft: WebAppDraft
    private(set) var hits: [(CGRect, () -> Void)] = []
    var onClose: (() -> Void)?
    private let nameModel = WebAppNameModel()
    private var popover: NSPopover?

    init(draft: WebAppDraft) { self.draft = draft }

    static let card = CGRect(x: 72, y: 236, width: 880, height: 640)
    static var close: CGRect { CGRect(x: card.minX + 36, y: card.minY + 36, width: 96, height: 96) }
    static var add: CGRect { CGRect(x: card.maxX - 132, y: card.minY + 36, width: 96, height: 96) }
    static var iconRect: CGRect { CGRect(x: card.minX + 56, y: card.minY + 176, width: 180, height: 180) }
    static var nameField: CGRect { CGRect(x: iconRect.maxX + 36, y: iconRect.minY + 8, width: card.maxX - 56 - iconRect.maxX - 36, height: 100) }
    static var toggleRow: CGRect { CGRect(x: card.minX + 40, y: card.minY + 396, width: card.width - 80, height: 104) }
    var canAdd: Bool { WebAppInstaller.canAdd && !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    func draw(_ g: CGContext, _ face: Face) {
        hits = []
        let ink = HPTokens.label, sub = HPTokens.secondary, fill = HPTokens.label.withAlphaComponent(0.08)   // 玻璃卡在網頁上：字跟著淺／深色
        let card = Self.card
        g.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let radius = Screen.concentric(inset: card.minX)
        if !ShellGlass.draw(g, face: face, path: continuousRoundedRect(card, radius: radius), key: "webapp.add") {
            g.addPath(continuousRoundedRect(card, radius: radius)); g.setFillColor(HPTokens.card.withAlphaComponent(0.97).cgColor); g.fillPath()
        }
        // 頂列：✕（取消）、標題、✓（加入，藍色染色＝這一頁的主要動作）
        HPComponents.glassCircle(g, face, Self.close, symbol: "xmark", ink: ink)
        let addInk = canAdd ? NSColor.white : ink.withAlphaComponent(0.35)
        HPComponents.glassCircle(g, face, Self.add, symbol: "checkmark", ink: addInk, tint: canAdd ? HPTokens.blue : nil)
        HPAX.note(g, Self.add, .button, L("webapp.add.button", "添加"), shape: .circle)
        let tf = HPType.sf(40, .bold), title = L("webapp.add.title", "添加到主屏幕")
        HPComponents.center(g, face, title, HPType.fitted(title, size: 40, weight: .bold, maxWidth: 520), cx: card.midX, y: Self.close.midY + 14, ink)
        _ = tf
        hits.append((Self.close, { [weak self] in self?.closeName(); self?.onClose?() }))
        hits.append((Self.add, { [weak self] in
            guard let self, self.canAdd else { return }
            self.closeName()
            if WebAppInstaller.add(self.draft) != nil {
                self.onClose?()
                (NSApp.delegate as? AppDelegate)?.view?.shellNavigate(.back)   // iOS：加好就回主畫面
            }
        }))
        // 圖示預覽＋名字（點了改名）＋網域
        let ir = Self.iconRect
        if draft.ready || draft.icon != nil {
            let icon = draft.icon ?? WebAppIcons.monogram(name: draft.name, color: draft.theme ?? 0x8E8E93)
            g.saveGState(); g.addPath(continuousRoundedRect(ir, radius: ir.width * 0.2237)); g.clip(); face.drawUpright(g, icon, in: ir); g.restoreGState()
        } else {
            g.addPath(continuousRoundedRect(ir, radius: ir.width * 0.2237)); g.setFillColor(fill.cgColor); g.fillPath()
            HPComponents.spinner(g, in: ir.insetBy(dx: 60, dy: 60), ink: ink)
        }
        HPAX.note(g, ir, .text, String(format: L("webapp.a11y.icon", "%@ 的图标"), draft.name))
        let nf = Self.nameField
        g.addPath(HPComponents.capsulePath(nf)); g.setFillColor(fill.cgColor); g.fillPath()
        let f = HPType.fitted(draft.name, size: 40, weight: .semibold, maxWidth: nf.width - 120)
        face.drawLeft(g, Face.clipped(draft.name, f, nf.width - 120), font: f, x: nf.minX + 40, y: nf.midY + f.capHeight / 2, color: ink)
        face.drawSymbol(g, "pencil", in: CGRect(x: nf.maxX - 70, y: nf.midY - 18, width: 36, height: 36), color: sub)
        HPAX.note(g, nf, .button, String(format: L("webapp.a11y.name", "名称：%@"), draft.name))
        hits.append((nf, { [weak self] in self?.editName() }))
        let hf = HPType.sf(30, .regular)
        face.drawLeft(g, Face.clipped(draft.host, hf, nf.width - 40), font: hf, x: nf.minX + 40, y: nf.maxY + 56, color: sub)
        // 以 Web App 開啟
        let tr = Self.toggleRow
        g.addPath(continuousRoundedRect(tr, radius: tr.height / 2)); g.setFillColor(fill.cgColor); g.fillPath()
        let lf = HPType.sf(36, .semibold), label = L("webapp.add.openAsApp", "作为 Web App 打开")
        face.drawLeft(g, Face.clipped(label, lf, tr.width - 220), font: lf, x: tr.minX + 40, y: tr.midY + lf.capHeight / 2, color: ink)
        let sw = CGRect(x: tr.maxX - 40 - 126, y: tr.midY - 30, width: 126, height: 60)
        HPComponents.toggle(g, sw, on: draft.standalone, key: "webapp.add.standalone", label: label)
        hits.append((tr, { [weak self] in self?.draft.standalone.toggle() }))
        // 誰的主畫面（每人一份）
        let note: String
        if !WebAppInstaller.canAdd { note = L("webapp.add.guest", "访客不能添加到主屏幕。") }
        else if let p = PersonHome.viewerID.flatMap({ PeopleRegistry.shared.person($0) }), PeopleRegistry.shared.people.count > 1 {
            note = String(format: L("webapp.add.whose", "会添加到 %@ 的主屏幕；它的网站数据只留在这个 Web App 里。"), p.name)
        } else { note = L("webapp.add.note", "它的网站数据只留在这个 Web App 里，跟 Safari 分开。") }
        let bf = HPType.sf(30, .regular)
        var y = tr.maxY + 60
        for l in Face.photosWrap(note, bf, card.width - 120, maxLines: 2) { face.drawLeft(g, l, font: bf, x: card.minX + 60, y: y, color: sub); y += 40 }
    }

    func tap(_ p: CGPoint) {
        if let h = hits.first(where: { $0.0.insetBy(dx: -8, dy: -8).contains(p) }) { h.1(); return }
        if !Self.card.contains(p) { closeName(); onClose?() }
    }

    private func editName() {
        guard let v = (NSApp.delegate as? AppDelegate)?.view, popover?.isShown != true else { return }
        nameModel.text = draft.name
        nameModel.onSubmit = { [weak self] t in
            let s = String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
            if !s.isEmpty { self?.draft.name = s }
            self?.closeName()
            v.face.forceDirty = true
        }
        let p = NSPopover()
        p.behavior = .transient; p.animates = true
        p.contentViewController = NSHostingController(rootView: WebAppNameView(model: nameModel))
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        popover = p
    }
    private func closeName() {
        if popover?.isShown == true, !nameModel.text.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = String(nameModel.text.prefix(32)) }
        popover?.performClose(nil); popover = nil
    }
}

// MARK: - 改名（加入時、主畫面長按「重新命名」共用）

final class WebAppNameModel: ObservableObject {
    @Published var text = ""
    var onSubmit: ((String) -> Void)?
}

struct WebAppNameView: View {
    @ObservedObject var model: WebAppNameModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("webapp.name", "名称"), text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.onSubmit?(model.text) }
                .frame(width: 280)
            Label(L("input.noOnscreenKeyboard", "没有屏幕键盘：用键盘打字，或按两下 fn 听写"), systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

enum WebAppEditor {
    nonisolated(unsafe) private static var popover: NSPopover?
    nonisolated(unsafe) private static let model = WebAppNameModel()

    static func rename(_ a: WebApp) {
        guard let v = (NSApp.delegate as? AppDelegate)?.view else { return }
        model.text = a.name
        model.onSubmit = { t in
            let s = String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
            if !s.isEmpty { WebAppStore.shared.update(a.uuid) { $0.name = s } }
            popover?.performClose(nil); popover = nil
            Shell.homeLayer = nil; SB.pageCache.removeAll(); v.face.forceDirty = true
        }
        let p = NSPopover()
        p.behavior = .transient; p.animates = true
        p.contentViewController = NSHostingController(rootView: WebAppNameView(model: model))
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        popover = p
    }

    /// 刪除：從每個人的主畫面拿掉、刪圖示與這個 Web App 的網站資料（不能復原，先問）
    static func confirmDelete(_ a: WebApp, ask: Bool = true) {
        if ask {
            let al = NSAlert()
            al.messageText = String(format: L("webapp.delete.title", "要删除“%@”吗？"), a.name)
            al.informativeText = L("webapp.delete.body", "它的网站数据（登录、Cookie、离线内容）也会一起删除。")
            al.alertStyle = .warning
            al.addButton(withTitle: L("webapp.delete.ok", "删除"))
            al.addButton(withTitle: L("sb.cancel", "取消"))
            al.buttons.first?.hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            guard al.runModal() == .alertFirstButtonReturn else { return }
        }
        delete(a.uuid)
    }
    static func delete(_ uuid: String) {
        let id = WebApp.idPrefix + uuid
        for (person, var l) in SBStore.layouts where l.appsOnHome.contains(id) { l.removeApp(id); l.normalize(); SBStore.layouts[person] = l }
        SBStore.save()
        var cur = SB.layout
        if cur.appsOnHome.contains(id) { cur.removeApp(id); cur.normalize(); SB.layout = cur; SB.commit() }
        removeWidgets(id)
        WebAppStore.shared.remove(uuid)
        if Shell.currentApp?.id == id { _ = (NSApp.delegate as? AppDelegate)?.view?.shellNavigate(.back) }
        Shell.homeLayer = nil; SB.pageCache.removeAll()
        (NSApp.delegate as? AppDelegate)?.view?.face.forceDirty = true
        log("webapp deleted")
    }
    /// 這個 Web App 的小工具也一起拿掉（每個人的主畫面）
    private static func removeWidgets(_ id: String) {
        func strip(_ l: inout SBLayout) -> Bool {
            var changed = false
            for p in l.pages.indices {
                l.pages[p].items = l.pages[p].items.compactMap { it in
                    switch it {
                    case .widget(let w) where w.kind == .webApp && w.config["app"] == id: changed = true; return nil
                    case .stack(var s):
                        let n = s.widgets.count
                        s.widgets.removeAll { $0.kind == .webApp && $0.config["app"] == id }
                        if s.widgets.count != n { changed = true }
                        return s.widgets.isEmpty ? nil : (s.widgets.count == 1 ? .widget(s.widgets[0]) : .stack(s))
                    default: return it
                    }
                }
            }
            if changed { l.normalize() }
            return changed
        }
        for (person, var l) in SBStore.layouts where strip(&l) { SBStore.layouts[person] = l }
        SBStore.save()
        var cur = SB.layout
        if strip(&cur) { SB.layout = cur; SB.commit() }
    }
}
