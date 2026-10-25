// 2.0 Web App 的「App 提供者」與獨立執行的畫面（docs/plans/webapps.md）。
//
// 畫面：沒有 Safari 的工具列；頂端那一條（👀 膠囊、左上 ✕、右上時間）用 theme color，底下整面是網頁；
// 第一次載入時是啟動畫面（background color＋圖示＋名字，iOS 的做法）。範圍外的頁（登入流程）頂端多一顆網域膠囊＋「完成」。
// 輸入：點到輸入框＝桌寵旁邊出原生小框（實體鍵盤、輸入法、聽寫），字即時同步進網頁；Return 送出。
// 權限、alert／confirm：畫在螢幕上的系統式對話框（跟主畫面「移除」同一張卡）。

import AppKit
import SwiftUI

final class WebAppProvider: AppProvider {
    static let shared = WebAppProvider()
    private var cache: [String: WebAppApp] = [:]

    func petApp(_ a: WebApp) -> WebAppApp {
        if let c = cache[a.uuid] { return c }
        let c = WebAppApp(uuid: a.uuid)
        cache[a.uuid] = c
        return c
    }
    /// 刪掉的 Web App：放掉它的畫面（連同網頁），網站資料庫才刪得掉
    func forget(_ uuid: String) { cache[uuid]?.release(); cache[uuid] = nil }
    func apps(viewer: String?) -> [PetApp] { WebAppStore.shared.apps(for: viewer).map(petApp) }
    func app(_ id: String) -> PetApp? { WebAppStore.shared.app(id: id).map(petApp) }
    func isPersonal(_ id: String) -> Bool { true }
    func locks(_ id: String) -> Bool {
        guard let a = WebAppStore.shared.app(id: id) else { return false }
        return !WebAppGate.canOpen(a)
    }
    func menuRows(_ id: String, canEdit: Bool) -> [AppMenuRow] {
        guard canEdit, let a = WebAppStore.shared.app(id: id) else { return [] }
        var rows = [AppMenuRow(verb: "rename", title: L("sb.menu.rename", "重新命名"), symbol: "pencil")]
        let defs = a.widgets.isEmpty ? [WebAppWidgetDef(tag: WebAppWidgets.iconTag, name: a.name)] : a.widgets
        for d in defs.prefix(3) {
            rows.append(AppMenuRow(verb: "widget:\(d.tag)", title: defs.count > 1 ? String(format: L("webapp.menu.addWidgetNamed", "添加「%@」小组件"), d.shortName ?? d.name) : L("sb.menu.addWidget", "添加小组件"),
                                   symbol: "plus.rectangle.on.rectangle"))
        }
        rows.append(AppMenuRow(verb: "delete", title: L("webapp.menu.delete", "删除 Web App"), symbol: "trash", destructive: true))
        return rows
    }
    func perform(_ id: String, verb: String) {
        guard let a = WebAppStore.shared.app(id: id) else { return }
        switch verb {
        case "rename": WebAppEditor.rename(a)
        case "delete": WebAppEditor.confirmDelete(a)
        default:
            if verb.hasPrefix("widget:") { WebAppWidgets.addToHome(a, tag: String(verb.dropFirst(7))) }
        }
    }
    func spokenNames(_ id: String) -> [String] {
        guard let a = WebAppStore.shared.app(id: id) else { return [] }
        return [a.host]
    }
    /// 網頁還開著的（在播的給藥丸；關掉一分鐘沒在播的在 liveActivity 裡收掉）
    func backgroundApps() -> [PetApp] { WebAppRuntimes.liveIDs.compactMap { WebAppStore.shared.app(uuid: $0) }.map(petApp) }
}

// MARK: - 一個 Web App 的畫面

final class WebAppApp: PetApp {
    let uuid: String
    init(uuid: String) { self.uuid = uuid }
    var model: WebApp? { WebAppStore.shared.app(uuid: uuid) }
    var id: String { WebApp.idPrefix + uuid }
    var title: String { model?.name ?? "" }
    var icon: AppIcon {
        var i = AppIcon(color: model?.theme.map { srgb($0) } ?? HPTokens.gray, symbol: "globe")
        i.image = WebAppStore.shared.icon(uuid) ?? WebAppIcons.monogram(model)
        return i
    }
    /// 右上時間我們自己畫（theme color 可能是深色，字要跟著換黑白）
    var showsClock: Bool { false }

    typealias T = HPTokens.Safari
    private var web: WebAppWeb?
    private var dirty = false
    private var hits: [(CGRect, () -> Void)] = []
    private weak var face: Face?
    /// 螢幕上的對話框（權限、alert、confirm）：一次一個，後來的排隊
    private struct Dialog { var title: String; var body: String?; var buttons: [(String, NSColor?)]; var done: (Int) -> Void }
    private var dialogs: [Dialog] = []
    private var notice: (title: String, body: String, at: Double)?
    private var lastSeen = CACurrentMediaTime()
    private let input = WebAppInputModel()
    private var popover: NSPopover?

    private func ensureWeb() -> WebAppWeb? {
        if let web { return web }
        guard let m = model else { return nil }
        let w = WebAppRuntimes.web(for: m)
        w.onChange = { [weak self] in self?.dirty = true }
        w.onAsk = { [weak self] p, done in
            guard let self else { done(false); return }
            self.ask(p.question(self.title), body: L("webapp.ask.body", "可以随时在「设置 › 权限 › Web App」里更改。"),
                     buttons: [(L("webapp.ask.deny", "不允许"), nil), (L("webapp.ask.allow", "允许"), HPTokens.blue)]) { done($0 == 1) }
        }
        w.onDialog = { [weak self] msg, cancel, done in
            guard let self else { done(false); return }
            let b: [(String, NSColor?)] = cancel ? [(L("sb.cancel", "取消"), nil), (L("webapp.ok", "好"), HPTokens.blue)] : [(L("webapp.ok", "好"), HPTokens.blue)]
            self.ask(self.title, body: msg, buttons: b) { done(cancel ? $0 == 1 : true) }
        }
        w.onNotification = { [weak self] t, b in self?.notice = (t, b, CACurrentMediaTime()); self?.dirty = true }
        w.onLeaveScope = { u in
            SafariApp.shared.open(u)
            (NSApp.delegate as? AppDelegate)?.view?.shellOpenApp("safari")
        }
        web = w
        return w
    }
    private func ask(_ title: String, body: String?, buttons: [(String, NSColor?)], done: @escaping (Int) -> Void) {
        dialogs.append(Dialog(title: title, body: body, buttons: buttons, done: done)); dirty = true
        face?.forceDirty = true
    }

    /// 「以 Web App 開啟」關掉的：只是書籤，在 Safari 開
    func launch(face: Face) -> Bool {
        guard let m = model, !m.standalone, let u = m.start else { return false }
        if PersonalGate.locks(id) { return false }   // 門關著照樣進來畫「需要主人」
        SafariApp.shared.open(u)
        (NSApp.delegate as? AppDelegate)?.view?.shellOpenApp("safari")
        return true
    }

    func didOpen(now: Double) {
        lastSeen = now; openedAt = now
        guard !PersonalGate.locks(id), let w = ensureWeb(), let m = model else { return }
        w.setAppearance(dark: HPTokens.dark)
        if w.url == nil, let u = m.start { w.load(u) }
        if WebAppDemo.waitsForPaint { w.settle(until: Date().addingTimeInterval(12)) }
    }

    func tick(_ now: Double) -> Bool {
        lastSeen = now
        if let w = web { w.setAppearance(dark: HPTokens.dark); w.pump(now) }
        if let n = notice, now - n.at > 6 { notice = nil; dirty = true }
        if HPComponents.needsFrame(now) { return true }
        defer { dirty = false }
        return dirty || (web?.loading ?? false)
    }

    /// 頂端藥丸：在播＝音樂；剛收到通知＝一則（門關著都不給）
    func liveActivity(face: Face, now: Double) -> LiveActivity? {
        // 關掉一分鐘、又沒在播：收掉網頁（資料都在它自己的資料庫）
        if Shell.currentApp?.id != id, let w = web, !w.media.playing, now - lastSeen > 60 { web = nil; WebAppRuntimes.closed(uuid) }
        guard let m = model, WebAppGate.canOpen(m) else { return nil }
        let accent = m.theme.map { srgb($0) } ?? HPTokens.blue
        if let n = notice { return LiveActivity(kind: .message, title: m.name, detail: n.title.isEmpty ? n.body : n.title, accent: accent, progress: nil, appID: id, symbol: "bell.fill") }
        if let w = web, w.media.playing {
            return LiveActivity(kind: .music, title: w.media.title.isEmpty ? m.name : w.media.title, detail: w.media.artist.isEmpty ? m.name : w.media.artist,
                                accent: accent, progress: nil, appID: id)
        }
        return nil
    }

    // MARK: 畫

    private var bandColor: NSColor {
        if let t = web?.pageTheme ?? model?.theme { return srgb(t) }
        return HPTokens.dark ? .black : .white
    }
    private var bandInk: NSColor {
        if let t = web?.pageTheme ?? model?.theme { return CSSColor.isLight(t) ? .black : .white }
        return HPTokens.label
    }

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        hits = []
        _ = ensureWeb()
        let web = self.web
        let bg = model?.background.map { srgb($0) } ?? (HPTokens.dark ? .black : .white)
        g.setFillColor(bg.cgColor); g.fill(rect)
        let outside = outOfScopeURL
        let inset = outside == nil ? 0 : Self.scopeBarHeight
        web?.setTopInset(inset)
        let r = CGRect(x: 0, y: T.webTop + inset, width: 1024, height: 1024 - T.webTop - inset)
        if let w = web, w.everPainted, let img = w.snapshot {
            // 照快照自己的比例畫（可視區剛改高度時，舊的那張不壓扁，下一張就對了）
            let ir = CGRect(x: 0, y: r.minY, width: 1024, height: 1024 * CGFloat(img.height) / CGFloat(max(1, img.width)))
            g.saveGState(); g.clip(to: r); face.drawUpright(g, img, in: ir); g.restoreGState()
        } else if web?.failed == true {
            HPComponents.emptyState(g, face, symbol: "wifi.exclamationmark", tint: AppUI.secondary, title: L("safari.failed", "打不开这个网页"),
                                    body: L("safari.failed.hint", "检查网址和网络后再试一次。"), top: 280)
            let b = CGRect(x: 512 - 180, y: 760, width: 360, height: 100)
            HPComponents.glassButton(g, face, b, L("webapp.retry", "再试一次"), symbol: "arrow.clockwise")
            hits.append((b, { [weak self] in self?.web?.reload() }))
        } else {
            launchScreen(g, face, bg)
        }
        // 頂端：theme color 一條（👀 膠囊、✕、時間在上面）
        g.setFillColor(bandColor.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: T.webTop + inset))
        HPComponents.topClock(g, face, size: 32, baselineDY: 11, color: bandInk)
        if let u = outside {
            scopeChip(g, face, u)
            g.setFillColor(HPTokens.separator.cgColor); g.fill(CGRect(x: 0, y: T.webTop + inset - 2, width: 1024, height: 2))   // 列與網頁之間一條線（iOS 的列底線）
        }
        if let w = web, w.loading, w.everPainted {
            g.setFillColor(HPTokens.blue.cgColor); g.fill(CGRect(x: 0, y: T.webTop + inset - 4, width: 1024 * max(0.08, w.progress), height: 4))
        }
        if let d = dialogs.first { drawDialog(g, face, d) }
    }

    /// 啟動畫面：background color＋圖示＋名字（iOS 從 manifest 自己生的那種）
    private func launchScreen(_ g: CGContext, _ face: Face, _ bg: NSColor) {
        let ir = CGRect(x: 512 - 110, y: 340, width: 220, height: 220)
        Shell.drawAppIcon(g, face: face, icon: icon, in: ir, appID: id)
        let ink: NSColor = model?.background.map { CSSColor.isLight($0) ? .black : .white } ?? HPTokens.label
        let f = HPType.fitted(title, size: 48, weight: .semibold, maxWidth: 800)
        HPComponents.center(g, face, Face.clipped(title, f, 800), f, y: 640, ink)
        // 載入超過一秒：名字底下轉一個圈（慢的網路、家裡的 NAS）
        if let w = web, w.loading, CACurrentMediaTime() - openedAt > 1 { HPComponents.spinner(g, in: CGRect(x: 512 - 28, y: 700, width: 56, height: 56), ink: ink.withAlphaComponent(0.6)) }
        HPAX.note(g, CGRect(x: 112, y: 340, width: 800, height: 400), .text, String(format: L("webapp.a11y.loading", "%@，正在打开"), title))
    }
    private var openedAt = CACurrentMediaTime()

    /// 現在的網址不在 App 的範圍裡（登入流程等）：回那個網址，否則 nil
    private var outOfScopeURL: URL? {
        guard let w = web, let u = w.url, let m = model, WebManifestParser.allowedScheme(u), !m.inScope(u) else { return nil }
        return u
    }
    /// 網域列的高：上下各 18＋膠囊 88
    private static let scopeBarHeight: CGFloat = 124
    /// 範圍外（登入流程）：網域膠囊＋「完成」回到 start_url（iOS standalone 的做法）
    private func scopeChip(_ g: CGContext, _ face: Face, _ u: URL) {
        let host = SafariLogic.displayHost(u)
        let f = HPType.sf(30, .semibold)
        let w = min(560, Typo.width(host, f) + 230)
        let r = CGRect(x: 512 - w / 2, y: T.webTop + 18, width: w, height: 88)
        HPComponents.glassCapsule(g, r) { c in
            face.drawSymbol(c, "lock.fill", in: CGRect(x: r.minX + 30, y: r.midY - 16, width: 26, height: 32), color: HPGlass.ink.withAlphaComponent(0.7))
            face.drawLeft(c, Face.clipped(host, f, w - 230), font: f, x: r.minX + 70, y: r.midY + 11, color: HPGlass.ink)
            let df = HPType.sf(30, .bold), dw = Typo.width(L("webapp.done", "完成"), df)
            face.drawLeft(c, L("webapp.done", "完成"), font: df, x: r.maxX - 34 - dw, y: r.midY + 11, color: HPTokens.blue)
        }
        HPAX.note(g, r, .button, String(format: L("webapp.a11y.outOfScope", "%@（不在这个 App 里）：完成"), host))
        hits.append((r, { [weak self] in if let u = self?.model?.start { self?.web?.load(u) } }))
    }

    private func drawDialog(_ g: CGContext, _ face: Face, _ d: Dialog) {
        let rects = WebAppUI.alert(g, face, title: d.title, body: d.body, buttons: d.buttons)
        for (i, r) in rects.enumerated() {
            hits.insert((r, { [weak self] in
                guard let self, !self.dialogs.isEmpty else { return }
                let d = self.dialogs.removeFirst(); d.done(i); self.dirty = true
            }), at: 0)
        }
    }

    // MARK: 點、滾、打字

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        self.face = face
        if !dialogs.isEmpty {   // 對話框開著：只吃它的按鈕
            if let h = hits.first(where: { $0.0.insetBy(dx: -6, dy: -6).contains(p) }) { h.1() }
            return true
        }
        if let h = hits.first(where: { $0.0.insetBy(dx: -6, dy: -6).contains(p) }) { h.1(); return true }
        let inset = outOfScopeURL == nil ? 0 : Self.scopeBarHeight
        guard let w = web, w.everPainted, p.y > T.webTop + inset else { return p.y > T.webTop }
        closeInput()
        w.tap(css: SafariLogic.cssPoint(CGPoint(x: p.x, y: p.y - inset), zoom: w.pageZoom)) { [weak self] r in
            if case .field(let type, let value, let placeholder) = r { self?.showInput(type: type, value: value, placeholder: placeholder) }
        }
        return true
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard let w = web, dialogs.isEmpty else { return true }
        w.scroll(cssDY: -dy * T.pointsPerCanvas / w.pageZoom * 1.6)
        return true
    }

    func handleBack(now: Double) -> Bool {
        if !dialogs.isEmpty { let d = dialogs.removeFirst(); d.done(0); dirty = true; return true }   // Esc＝第一顆（不允許／取消）
        closeInput()
        return false
    }

    private func showInput(type: String, value: String, placeholder: String) {
        guard let v = (NSApp.delegate as? AppDelegate)?.view else { return }
        input.text = value
        input.secure = type == "password"
        input.placeholder = placeholder.isEmpty ? L("webapp.input.placeholder", "输入") : String(placeholder.prefix(60))
        input.onChange = { [weak self] t in self?.web?.setFieldText(t) }
        input.onSubmit = { [weak self] in self?.web?.submitField(); self?.closeInput() }
        if popover?.isShown == true { return }
        let p = NSPopover()
        p.behavior = .transient; p.animates = true
        p.contentViewController = NSHostingController(rootView: WebAppInputView(model: input))
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        popover = p
    }
    private func closeInput() {
        guard popover?.isShown == true else { return }
        popover?.performClose(nil); popover = nil
        web?.blurField()
    }

    func release() { web = nil; dialogs.removeAll(); closeInput() }
    /// 快照與 selftest
    var runtime: WebAppWeb? { web }
    func demoAsk(_ p: WebAppPermission) {
        _ = ensureWeb()
        ask(p.question(title), body: L("webapp.ask.body", "可以随时在「设置 › 权限 › Web App」里更改。"),
            buttons: [(L("webapp.ask.deny", "不允许"), nil), (L("webapp.ask.allow", "允许"), HPTokens.blue)]) { _ in }
    }
}

// MARK: - 打字的原生小框（跟 Safari 網址列同一種：沒有螢幕鍵盤，用鍵盤或聽寫；不自動填密碼）

final class WebAppInputModel: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { onChange?(text) } } }
    @Published var secure = false
    @Published var placeholder = ""
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
}

struct WebAppInputView: View {
    @ObservedObject var model: WebAppInputModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if model.secure { SecureField(model.placeholder, text: $model.text) } else { TextField(model.placeholder, text: $model.text) }
            }
            .textFieldStyle(.roundedBorder)
            .textContentType(nil)
            .autocorrectionDisabled()
            .focused($focused)
            .onSubmit { model.onSubmit?() }
            .frame(width: 320)
            Label(L("input.noOnscreenKeyboard", "没有屏幕键盘：用键盘打字，或按两下 fn 听写"), systemImage: "keyboard")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

// MARK: - 螢幕上的系統式對話框（跟主畫面「移除」同一張卡：SBUI.alertCard）

enum WebAppUI {
    /// 畫一張對話框，回傳按鈕的框（照 buttons 的順序；兩顆並排、一顆滿寬）
    @discardableResult
    static func alert(_ g: CGContext, _ face: Face, title: String, body: String?, buttons: [(String, NSColor?)]) -> [CGRect] {
        g.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let bf = HPType.sf(30, .regular), tf = HPType.sf(40, .semibold)
        let titleLines = Face.photosWrap(title, tf, 600, maxLines: 3)
        let bodyLines = body.map { Face.photosWrap($0, bf, 600, maxLines: 5) } ?? []
        let h = 72 + CGFloat(titleLines.count) * 50 + CGFloat(bodyLines.count) * 40 + 40 + 100 + 36
        let card = CGRect(x: 172, y: 512 - h / 2, width: 680, height: h)
        if !ShellGlass.draw(g, face: face, path: continuousRoundedRect(card, radius: 72), key: "webalert|\(Int(h))") {
            g.addPath(continuousRoundedRect(card, radius: 72)); g.setFillColor(HPTokens.card.withAlphaComponent(0.97).cgColor); g.fillPath()
        }
        var y = card.minY + 76
        for l in titleLines { HPComponents.center(g, face, l, tf, cx: card.midX, y: y, HPTokens.label); y += 50 }
        y += 4
        for l in bodyLines { HPComponents.center(g, face, l, bf, cx: card.midX, y: y, HPTokens.secondary); y += 40 }
        let by = card.maxY - 136, n = CGFloat(max(1, buttons.count)), gap: CGFloat = 20
        let bw = (card.width - 64 - gap * (n - 1)) / n
        var out: [CGRect] = []
        for (i, b) in buttons.enumerated() {
            let r = CGRect(x: card.minX + 32 + CGFloat(i) * (bw + gap), y: by, width: bw, height: 100)
            g.addPath(HPComponents.capsulePath(r)); g.setFillColor((b.1 ?? HPTokens.label.withAlphaComponent(0.1)).cgColor); g.fillPath()
            let f = HPType.fitted(b.0, size: 36, weight: .semibold, maxWidth: r.width - 40)
            HPComponents.center(g, face, b.0, f, cx: r.midX, y: r.midY + f.capHeight / 2, b.1 == nil ? HPTokens.label : .white)
            HPAX.note(g, r, .button, b.0)
            out.append(r)
        }
        HPAX.note(g, CGRect(x: card.minX, y: card.minY, width: card.width, height: by - card.minY), .text, ([title] + (body.map { [$0] } ?? [])).joined(separator: "\n"))
        return out
    }
}

// MARK: - 圖示：抓到的圖（裝的時候就裁成方的、補底色）；沒有就字母圖示（iOS：第一個字＋網站的顏色）

enum WebAppIcons {
    nonisolated(unsafe) private static var monos: [String: CGImage] = [:]
    static func monogram(_ a: WebApp?) -> CGImage? {
        guard let a else { return nil }
        let key = "\(a.uuid)|\(a.name)|\(a.theme ?? 0)"
        if let m = monos[key] { return m }
        let img = monogram(name: a.name, color: a.theme ?? 0x8E8E93)
        monos[key] = img
        return img
    }
    static func monogram(name: String, color: UInt32) -> CGImage {
        makeImage(256, 256) { g in
            g.setFillColor(srgb(color).cgColor); g.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            let f = HPType.sf(132, .semibold)
            let ink: NSColor = CSSColor.isLight(color) ? .black : .white
            let w = Typo.width(letter, f)
            let s = NSAttributedString(string: letter, attributes: [.font: f, .foregroundColor: ink])
            let line = CTLineCreateWithAttributedString(s)
            g.saveGState(); g.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            g.textPosition = CGPoint(x: 128 - w / 2, y: 128 + f.capHeight / 2)
            CTLineDraw(line, g); g.restoreGState()
        }
    }
    /// 抓到的圖 → 256² 方圖：透明的地方補 background color（沒有就白），整張填滿（maskable 本來就是滿版）
    static func square(_ src: CGImage, background: UInt32?) -> CGImage {
        makeImage(256, 256) { g in
            g.setFillColor(srgb(background ?? 0xFFFFFF).cgColor); g.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            g.interpolationQuality = .high
            g.saveGState(); g.translateBy(x: 0, y: 256); g.scaleBy(x: 1, y: -1)
            g.draw(src, in: CGRect(x: 0, y: 0, width: 256, height: 256)); g.restoreGState()
        }
    }
}
