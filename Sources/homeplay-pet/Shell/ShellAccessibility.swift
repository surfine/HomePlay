// 2.0 P05：畫出來的螢幕給 VoiceOver、語音控制、切換控制、鍵盤用。
//
// 螢幕是貼在 3D 機身上的一張 1024² 畫布，所以 PetView 自己當容器（role group），依目前的畫面輸出
// NSAccessibilityElement：主畫面的圖示與小工具、頂端藥丸（Live Activity）、換人、返回鈕、App 裡記下來的
// 按鈕／開關／分段／字（Design/HPAccessibility.swift 的 HPAX）、控制中心的磚、ClioTalk 的回答與按鈕；錶面上
// 是一顆「時間＋日期」的按鈕（按下＝進 CarPlay，跟 1.0 的 VoiceOver 按下一樣）。
//
// 框：畫布座標 → 螢幕 uv → 用跟點按同一份機身投影（PetView.screenCorners 的單應變換，反方向）換到視圖、視窗、螢幕座標，
// 機身轉了框就跟著轉。按下：跟滑鼠點同一條路（shellTap／shellActivate／ClioTalkController.tap）。
// 畫面換了（HPAX 換了一份、外殼換了畫面）就發 layoutChanged；開關、滑桿的值變了發 valueChanged。

import AppKit

/// 一個無障礙項目（畫布座標）
struct ShellAXItem: Equatable {
    enum Kind: Equatable { case homeItem, chrome, control, text }
    enum Press: Equatable { case tap(CGPoint), cc(ControlCenter.Tile), clio(ClioTalkPanel.Chip), back, carPlay, none }
    var id: String
    var kind: Kind
    var role: HPAXNote.Role
    var label: String
    var value: String? = nil
    var rect: CGRect
    var shape: HPAXNote.Shape = .capsule
    var press: Press = .none
    /// VoiceOver 念的種類（「小工具」「即時動態」）；nil＝照角色
    var roleDescription: String? = nil
    /// 2.0 SpringBoard：自訂動作（VoiceOver 轉子「動作」：搬移、移除、編輯主畫面）
    var customActions: [String] = []

    /// 鍵盤焦點能停的（字不停，跟 Full Keyboard Access 一樣只停控制）
    var focusable: Bool {
        switch role { case .text, .heading: return false; default: return press != .none }
    }
}

enum ShellAccessibility {
    /// 有輔助技術問過我們（VoiceOver、語音控制、Accessibility Inspector…）；沒人問就不每幀比對
    nonisolated(unsafe) static var clientSeen = false
    nonisolated(unsafe) static var elements: [String: ShellAXElement] = [:]
    nonisolated(unsafe) static var lastSignature = ""
    nonisolated(unsafe) static var lastValues: [String: String] = [:]

    // MARK: 依目前畫面列出項目

    static func items(face: Face, now: Double = CACurrentMediaTime()) -> [ShellAXItem] {
        // 這些卡蓋在最上面、各自有自己的點按規則：先不展開（PetView 本身的標籤照舊）
        if PermissionPrimer.visible || face.onboardingActive || face.inOverview { return [] }
        if PeopleOverlay.capturesClicks { return enrollItems() }   // 2.0 depth：录脸引导（PeopleOverlay.swift）
        let nav = Shell.nav
        if ClioTalkPanel.visible || nav.overlay == .clioTalk { return clioItems() }
        if nav.overlay == .controlCenter { return Shell.ccT > 0.95 ? ccItems(face: face) : [] }
        var out: [ShellAXItem] = []
        switch nav.screen {
        case .face:
            let d = Face.displayDate, loc = L10n.language.locale
            let t = DateFormatter(), dd = DateFormatter()
            t.locale = loc; Face.setTimeFormat(t)
            dd.locale = loc; dd.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
            out.append(ShellAXItem(id: "face", kind: .chrome, role: .button,
                                   label: String(format: L("a11y.pair", "%1$@，%2$@"), t.string(from: d), dd.string(from: d)),
                                   value: face.style.title,
                                   rect: CGRect(x: 0, y: 0, width: 1024, height: 1024).insetBy(dx: Screen.cornerRadius * 0.3, dy: Screen.cornerRadius * 0.3),
                                   shape: .rounded(Screen.cornerRadius), press: .carPlay))
            // 2.0 depth：錶面的資料也念得出來——天氣（溫度與條件，或為什麼沒有）、模組錶面的下一個行程
            if let data = faceData(face) {
                out.append(ShellAXItem(id: "face.data", kind: .text, role: .text, label: data,
                                       rect: CGRect(x: 112, y: 320, width: 800, height: 300), shape: .rounded(40)))
            }
            return out
        case .home, .library:
            if Shell.peopleSheet { return peopleSheetItems() }
            if let p = pillItem(face: face, now: now) { out.append(p); out += liveActivityItems(face: face) }
            out += SBAX.items(face: face)   // 2.0 SpringBoard：多頁、資料夾、選單、sheet、App 資料庫（Shell/SpringBoard/SBInput.swift）
        case .app(let id):
            if let p = pillItem(face: face, now: now) { out.append(p); out += liveActivityItems(face: face) }
            guard let a = AppRegistry.app(id) else { return out }
            if Shell.appMorph != nil { return out }   // 開到一半：等長好再列（App 那一格還畫在離屏畫布上）
            let locked = PersonalGate.locks(a.id)
            if a.showsCloseButton || locked {
                out.append(ShellAXItem(id: "back", kind: .chrome, role: .button,
                                       label: a.backSymbol == "xmark" ? L("a11y.close", "关闭") : L("a11y.back", "返回"),
                                       rect: HPTokens.backButton, shape: .circle, press: .back))
            }
            let notes = HPAX.notes.filter { $0.section == "base" }
            if !notes.contains(where: { $0.role == .heading }) {
                out.append(ShellAXItem(id: "app.title", kind: .text, role: .heading, label: a.title,
                                       rect: CGRect(x: HPTokens.titleX, y: HPTokens.titleBaseline - 52, width: 420, height: 66)))
            }
            for (i, n) in notes.enumerated() {
                // App 自己畫的返回鈕（showsCloseButton＝false 的頁面）走外殼的返回：先問 App 的 handleBack
                let isBack = n.rect.integral == HPTokens.backButton.integral
                let press: ShellAXItem.Press
                switch n.role {
                case .text, .heading, .slider: press = .none   // 2.0 depth：滑桿（播放進度）是唯讀的，念出來就好，按下去不要跳到中間
                default: press = isBack ? .back : .tap(center(n.rect))
                }
                // 2.0 depth：文字／標題只念 label（元素的值就是 label）；有 value 的併進去，免得被丟掉
                var label = n.label
                if let v = n.value, !v.isEmpty, n.role == .text || n.role == .heading { label = String(format: L("a11y.pair", "%1$@，%2$@"), n.label, v) }
                out.append(ShellAXItem(id: "app.\(id).\(i)", kind: n.role == .text || n.role == .heading ? .text : .control,
                                       role: n.role, label: label, value: n.value, rect: n.rect, shape: n.shape, press: press))
            }
        }
        return out
    }

    private static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    /// 2.0 depth：錶面上「不是時間日期」的資料，給 VoiceOver 念的一句
    private static func faceData(_ face: Face) -> String? {
        switch face.style {
        case .weather:
            if let d = WeatherSource.shared.data {
                return String(format: L("a11y.pair", "%1$@，%2$@"), String(format: "%d°", Int(d.temp.rounded())), Face.weatherText(d.code))
            }
            return WeatherSource.shared.statusText ?? WeatherSource.shared.statusShort   // 沒資料：念原因，不念「—」
        case .modular, .calendar:
            guard PersonalGate.allowed, case .event(let e) = face.calendarTile else { return nil }
            return String(format: L("a11y.pair", "%1$@，%2$@"), e.title, Face.shortTime(e.start))
        default: return nil
        }
    }

    private static func pillItem(face: Face, now: Double) -> ShellAXItem? {
        guard let act = face.shellActivity(now) else { return nil }
        let r = Shell.pillRect(Shell.pillT)
        let label = act.detail.isEmpty ? act.title : String(format: L("a11y.pair", "%1$@，%2$@"), act.title, act.detail)
        return ShellAXItem(id: "pill", kind: .chrome, role: .button, label: label,
                           value: act.progress.map { "\(Int(($0 * 100).rounded()))%" }, rect: r, shape: .capsule,
                           press: .tap(center(r)), roleDescription: L("a11y.liveActivity", "实时活动"))
    }

    /// 2.0 depth：Live Activity 展開後的動作鈕（計時器 +1:00／取消、音樂上一首／播放／下一首、掛斷、回覆），和分出去的第二、三顆小藥丸。
    /// 它們畫在頂端藥丸那一層（不是主畫布），所以直接拿 LiveActivityStack 這一幀記下的點擊區
    private static func liveActivityItems(face: Face) -> [ShellAXItem] {
        typealias S = LiveActivityStack
        let expanded = S.expandedApp != nil && S.expandAnim.to != 0
        var out: [ShellAXItem] = []
        for (hit, r) in S.hits {
            switch hit {
            case .button(let b) where expanded:
                let label: String
                switch b {
                case .timerAdd: label = L("a11y.la.timerAdd", "增加 1 分钟")
                case .timerStop: label = L("timer.cancel", "取消计时器")
                case .musicPrev: label = L("cc.np.previous", "上一首")
                case .musicPlay: label = (NowPlayingPage.shared.demo?.info.playing ?? face.nowPlaying.info?.playing ?? true) ? L("cc.np.pause", "暂停") : L("cc.np.play", "播放")
                case .musicNext: label = L("cc.np.next", "下一首")
                case .callEnd: label = L("call.hangUp", "挂断")
                case .messageReply: label = L("la.message.reply", "回复")
                }
                out.append(ShellAXItem(id: "la.\(b)", kind: .chrome, role: .button, label: label, rect: r, shape: .capsule, press: .tap(center(r))))
            case .minimal(let i) where !expanded && i < S.shown.count:
                let a = S.shown[i]
                out.append(ShellAXItem(id: "la.minimal.\(i)", kind: .chrome, role: .button, label: a.title.isEmpty ? a.detail : a.title,
                                       value: a.title.isEmpty || a.detail.isEmpty ? nil : a.detail, rect: r, shape: .capsule, press: .tap(center(r)),
                                       roleDescription: L("a11y.liveActivity", "实时活动")))
            default: break
            }
        }
        return out
    }

    private static func peopleSheetItems() -> [ShellAXItem] {
        Shell.peopleSheetRows.compactMap { id, r in
            guard let p = PeopleRegistry.shared.person(id) else { return nil }
            return ShellAXItem(id: "people.\(id)", kind: .control, role: .button, label: p.name, rect: r, shape: .rounded(30), press: .tap(center(r)))
        }
    }

    /// 2.0 depth：录脸引导卡（以前 VoiceOver 听不到「看着屏幕，慢慢转头」，也按不到取消）
    private static func enrollItems() -> [ShellAXItem] {
        var out: [ShellAXItem] = []
        if let t = PeopleOverlay.enrollText {
            let value = t.who.isEmpty ? t.sub : String(format: L("a11y.pair", "%1$@，%2$@"), t.sub, t.who)
            out.append(ShellAXItem(id: "enroll.text", kind: .text, role: .heading, label: t.title, value: value, rect: t.rect, shape: .rounded(24)))
        }
        let r = PeopleOverlay.cancelRect
        if r != .zero {
            out.append(ShellAXItem(id: "enroll.cancel", kind: .control, role: .button, label: L("people.enroll.cancel", "取消"),
                                   rect: r, shape: .capsule, press: .tap(center(r))))
        }
        return out
    }

    /// 2.0 cc：控制中心畫的時候記下的可點區域（模組、滑桿、播放控制、編輯模式的「−」與把手、圖庫、大卡的列）
    private static func ccItems(face: Face) -> [ShellAXItem] {
        let hits = ControlCenter.hits.isEmpty ? ControlCenter.moduleHits(face: face) : ControlCenter.hits
        return hits.enumerated().map { i, h in
            let id: String
            let press: ShellAXItem.Press
            switch h.action {
            case .module(let t): id = "cc.\(t)"; press = .cc(t)
            case .slider(let t): id = "cc.\(t)"; press = .cc(t)
            default: id = "cc.hit\(i)"; press = .tap(center(h.rect))
            }
            let role: HPAXNote.Role = h.level.map { .slider($0) } ?? h.toggle.map { .toggle($0) } ?? .button
            return ShellAXItem(id: id, kind: .control, role: role, label: h.label, value: h.value, rect: h.rect, shape: .rounded(HPTokens.Radius.tile), press: press)
        }
    }

    private static func clioItems() -> [ShellAXItem] {
        var out: [ShellAXItem] = []
        for (i, n) in HPAX.notes.enumerated() where n.section == "clio" {
            out.append(ShellAXItem(id: "clio.\(i)", kind: .text, role: n.role == .heading ? .heading : .text,
                                   label: n.label, rect: n.rect, shape: n.shape))
        }
        let labels = Dictionary(ClioTalkPanel.chips(for: ClioTalkPanel.snapshot).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        for (chip, r) in ClioTalkPanel.buttons {
            // 2.0 depth：在聽的時候整塊螢幕都是「講完了」；卡上那顆小圓鈕才是「用說的問」
            let label = chip == .listen ? (r.width > 900 ? L("a11y.clio.doneSpeaking", "说完了") : L("a11y.clio.listen", "用说的问")) : labels[chip]
            guard let label else { continue }
            out.append(ShellAXItem(id: "clio.chip.\(chip)", kind: .control, role: .button, label: label, rect: r,
                                   shape: chip == .listen ? .circle : .capsule, press: .clio(chip)))
        }
        return out
    }

    // MARK: 畫布 → 視圖（純函數；selftest 直接驗）

    /// corners：螢幕四角在視圖裡的投影（左上、右上、右下、左下）。回傳畫布框投影後的外接框（視圖座標）
    static func project(_ r: CGRect, corners c: [CGPoint]) -> CGRect? {
        let unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        guard c.count == 4, let h = homography(from: unit, to: c) else { return nil }
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            .map { applyHomography(h, CGPoint(x: $0.x / 1024, y: $0.y / 1024)) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x0.isFinite, y0.isFinite, x1.isFinite, y1.isFinite else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: 鍵盤焦點：往某個方向最近的那一個

    enum Direction { case left, right, up, down }
    /// rects 是畫布座標（y 往下）。主軸距離＋兩倍的側向偏移，挑最小的；那個方向沒有就 nil
    static func neighbor(from a: CGRect, _ d: Direction, in rects: [CGRect]) -> Int? {
        var best: (Int, CGFloat)?
        for (i, r) in rects.enumerated() where r != a {
            let dx = r.midX - a.midX, dy = r.midY - a.midY
            let main: CGFloat, side: CGFloat
            switch d {
            case .right: main = dx; side = abs(dy)
            case .left: main = -dx; side = abs(dy)
            case .down: main = dy; side = abs(dx)
            case .up: main = -dy; side = abs(dx)
            }
            guard main > 4 else { continue }
            let score = main + 2 * side
            if best == nil || score < best!.1 { best = (i, score) }
        }
        return best?.0
    }

    // MARK: 每畫完一格（HPAX.end 叫）：有人在聽才比對、發通知

    static func frameDone(_ view: PetView?) {
        guard clientSeen, let view else { return }
        let items = items(face: view.face)
        // 結構（換了畫面、多了少了項目）→ layoutChanged；同一個項目的字或值變了（倒數、開關）→ valueChanged
        let sig = "\(Shell.nav.screen)|\(Shell.nav.overlay)|" + items.map { "\($0.id)" }.joined(separator: ";")
        var values: [String: String] = [:]
        for it in items { values[it.id] = "\(it.label)|\(it.role)|\(it.value ?? "")" }
        defer { lastSignature = sig; lastValues = values }
        if sig != lastSignature {
            _ = view.syncAXElements(items)
            NSAccessibility.post(element: view, notification: .layoutChanged)
            return
        }
        for it in items where lastValues[it.id] != values[it.id] {
            if let el = elements[it.id] { el.item = it; NSAccessibility.post(element: el, notification: .valueChanged) }
        }
    }
}

// MARK: - 元素

final class ShellAXElement: NSAccessibilityElement {
    var item: ShellAXItem
    weak var view: PetView?
    init(item: ShellAXItem, view: PetView) { self.item = item; self.view = view; super.init() }

    override func accessibilityFrame() -> NSRect { view?.shellAXScreenRect(item.rect) ?? .zero }
    override func accessibilityParent() -> Any? { view }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityIdentifier() -> String { item.id }
    override func accessibilityRole() -> NSAccessibility.Role? {
        switch item.role {
        case .button: return .button
        case .toggle: return .checkBox
        case .radio: return .radioButton
        case .text, .heading: return .staticText
        case .slider: return .slider
        }
    }
    override func accessibilityRoleDescription() -> String? {
        item.roleDescription ?? accessibilityRole()?.description(with: nil)
    }
    override func accessibilityLabel() -> String? { item.role == .text || item.role == .heading ? nil : item.label }
    override func accessibilityValue() -> Any? {
        switch item.role {
        case .toggle(let on), .radio(let on): return NSNumber(value: on ? 1 : 0)
        case .slider(let v): return NSNumber(value: v)
        case .text, .heading: return item.label
        case .button: return item.value
        }
    }
    override func accessibilityValueDescription() -> String? { if case .slider = item.role { return item.value }; return nil }
    override func accessibilityMinValue() -> Any? { if case .slider = item.role { return NSNumber(value: 0) }; return nil }
    override func accessibilityMaxValue() -> Any? { if case .slider = item.role { return NSNumber(value: 1) }; return nil }
    override func accessibilityHelp() -> String? { item.id == "face" ? L("a11y.help", "重按屏幕进入 CarPlay，右键打开菜单") : nil }
    override func isAccessibilityFocused() -> Bool { ShellFocus.id == item.id }
    override func accessibilityPerformPress() -> Bool { view?.shellAXPress(item) ?? false }
    override func accessibilityPerformIncrement() -> Bool { view?.shellAXStep(item, by: 0.1) ?? false }
    override func accessibilityPerformDecrement() -> Bool { view?.shellAXStep(item, by: -0.1) ?? false }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {   // 2.0 SpringBoard
        guard !item.customActions.isEmpty else { return nil }
        let id = item.id
        return item.customActions.enumerated().map { i, name in
            NSAccessibilityCustomAction(name: name) { [weak self] in self?.view?.sbAXCustom(id, i) ?? false }
        }
    }
}

// MARK: - PetView：容器、框、按下

extension PetView {
    /// 現在的元素（同一個 id 沿用同一個物件，VoiceOver 的游標才不會跳走）
    func syncAXElements(_ items: [ShellAXItem]) -> [ShellAXElement] {
        var next: [String: ShellAXElement] = [:]
        let out = items.map { it -> ShellAXElement in
            let el = ShellAccessibility.elements[it.id] ?? ShellAXElement(item: it, view: self)
            el.item = it; next[it.id] = el
            return el
        }
        ShellAccessibility.elements = next
        return out
    }

    private var shellAXBlocked: Bool { showingVideo || carVideo.active }

    override func accessibilityChildren() -> [Any]? {
        ShellAccessibility.clientSeen = true
        guard !shellAXBlocked else { return [] }
        return syncAXElements(ShellAccessibility.items(face: face))
    }
    override func accessibilityRole() -> NSAccessibility.Role? {
        shellAXBlocked ? .button : .group   // CarPlay 畫面時照 1.0：整顆是按鈕（按下＝退出／進入）
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let kids = accessibilityChildren() as? [ShellAXElement] else { return self }
        // 疊在一起時挑最小的（藥丸在主畫面上、按鈕在卡上）
        let hits = kids.filter { NSPointInRect(point, $0.accessibilityFrame()) }
        return hits.min { $0.accessibilityFrame().width * $0.accessibilityFrame().height < $1.accessibilityFrame().width * $1.accessibilityFrame().height } ?? self
    }

    /// 畫布框 → 螢幕座標（機身背對相機時給 .zero）
    func shellAXScreenRect(_ r: CGRect) -> NSRect {
        guard let w = window, screenFacingCamera(), let v = ShellAccessibility.project(r, corners: screenCorners()) else { return .zero }
        let inView = v.intersection(bounds)
        guard !inView.isNull else { return .zero }
        return w.convertToScreen(convert(inView, to: nil))
    }

    /// 按下：跟滑鼠點同一條路
    @discardableResult
    func shellAXPress(_ item: ShellAXItem) -> Bool {
        Shell.lastActive = CACurrentMediaTime()
        switch item.press {
        case .tap(let p): if Shell.nav.overlay == .controlCenter { ccTap(p) } else { shellTap(CGPoint(x: p.x / 1024, y: p.y / 1024)) }   // 2.0 cc
        case .cc(let t):
            if t == .volume || t == .brightness { return false }   // 滑桿用加減
            shellActivate(t)
        case .clio(let c): ClioTalkController.shared.tap(c)
        case .back: shellNavigate(.back)
        case .carPlay: onForceEnter?()
        case .none: return false
        }
        face.forceDirty = true
        log("a11y press \(item.id)")
        return true
    }

    /// 滑桿加減（音量、亮度）
    @discardableResult
    func shellAXStep(_ item: ShellAXItem, by d: CGFloat) -> Bool {
        guard case .cc(let t) = item.press else { return false }
        switch t {
        case .volume:
            ControlCenter.volume = Float(max(0, min(1, CGFloat(ControlCenter.volume) + d))); SystemVolume.set(ControlCenter.volume)
        case .brightness:
            Shell.brightness = max(0.15, min(1, Shell.brightness + d))
        default: return false
        }
        face.forceDirty = true
        return true
    }

    /// 快照：--ax-dump 時把元素、框印進日誌，順便驗「主畫面項目數＝元素數、標籤不空、框都在視窗裡」
    func shellAXDumpIfAsked() {
        guard CommandLine.arguments.contains("--ax-dump"), let w = window else { return }
        ShellAccessibility.clientSeen = true
        let kids = (accessibilityChildren() as? [ShellAXElement]) ?? []
        let win = w.frame
        var inside = true, labeled = true
        for k in kids {
            let f = k.accessibilityFrame()
            let ok = f.width > 0 && win.insetBy(dx: -1, dy: -1).contains(f)
            inside = inside && ok
            let text = k.item.label
            labeled = labeled && !text.isEmpty
            log(String(format: "ax %@ %@ \"%@\" frame=(%.0f,%.0f %.0fx%.0f)%@", k.item.id, "\(k.accessibilityRole()?.rawValue ?? "?")", text,
                       f.minX, f.minY, f.width, f.height, ok ? "" : " OUTSIDE"))
        }
        let homeItems = Shell.nav.screen == .library ? Shell.libraryItems().count : Shell.homeItems().count
        let homeEls = kids.filter { $0.item.kind == .homeItem }.count
        log("ax summary screen=\(Shell.nav.screen) overlay=\(Shell.nav.overlay) children=\(kids.count) homeItems=\(homeItems) homeElements=\(homeEls) labels=\(labeled ? "ok" : "EMPTY") frames=\(inside ? "inside window" : "OUTSIDE")")
    }
}

// MARK: - 鍵盤焦點（Full Keyboard Access／設定「用鍵盤操作畫面」）

enum ShellFocus {
    /// 目前焦點停在哪個項目（ShellAXItem.id）。快照：--keyboard-focus home.app.music
    nonisolated(unsafe) static var id: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--keyboard-focus"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
}

extension PetView {
    /// 只在外殼蓋住錶面（主畫面、App、控制中心、ClioTalk）而且開了鍵盤操作時接手；邊上沒有下一個就交回原本的方向鍵
    func shellFocusKeyDown(_ e: NSEvent) -> Bool {
        guard HPAccessibilitySettings.keyboardNavigation, !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.option) else { return false }
        guard Shell.nav.screen.coversFace || Shell.nav.overlay != .none else { ShellFocus.id = nil; return false }
        let items = ShellAccessibility.items(face: face).filter(\.focusable)
        guard !items.isEmpty else { return false }
        let cur = items.firstIndex { $0.id == ShellFocus.id }
        func move(to i: Int) {
            ShellFocus.id = items[i].id
            face.forceDirty = true
            if let el = ShellAccessibility.elements[items[i].id] { NSAccessibility.post(element: el, notification: .focusedUIElementChanged) }
        }
        switch e.keyCode {
        case 48:   // Tab／⇧Tab：照順序
            let n = items.count, d = e.modifierFlags.contains(.shift) ? -1 : 1
            move(to: cur.map { ($0 + d + n) % n } ?? (d > 0 ? 0 : n - 1)); return true
        case 123, 124, 125, 126:
            guard let cur else { move(to: 0); return true }
            let it = items[cur]
            if case .slider = it.role, e.keyCode == 125 || e.keyCode == 126 {   // 滑桿：↑↓ 調值
                shellAXStep(it, by: e.keyCode == 126 ? 0.1 : -0.1); return true
            }
            let dir: ShellAccessibility.Direction = [123: .left, 124: .right, 125: .down, 126: .up][e.keyCode]!
            if let n = ShellAccessibility.neighbor(from: it.rect, dir, in: items.map(\.rect)) { move(to: n); return true }
            return false
        case 36, 76, 49:   // Return、Enter、空白鍵：打開
            guard let cur else { return false }
            shellAXPress(items[cur]); return true
        case 53:
            ShellFocus.id = nil; face.forceDirty = true; return false   // Esc 照舊回上一層
        default: return false
        }
    }
}

extension Face {
    /// 鍵盤焦點環畫在畫布上（系統的焦點色，外加一圈深色讓淺底也看得到）
    func drawShellFocusRing(_ g: CGContext) {
        guard let id = ShellFocus.id, HPAccessibilitySettings.keyboardNavigation,
              Shell.nav.screen.coversFace || Shell.nav.overlay != .none,
              let it = ShellAccessibility.items(face: self).first(where: { $0.id == id }) else { return }
        let r = it.rect.insetBy(dx: -10, dy: -10)
        let path: CGPath
        switch it.shape {
        case .capsule: path = CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil)
        case .circle: path = CGPath(ellipseIn: r, transform: nil)
        case .rounded(let k): path = continuousRoundedRect(r, radius: min(k + 10, min(r.width, r.height) / 2))
        }
        let accent = NSColor.keyboardFocusIndicatorColor.usingColorSpace(.sRGB)?.withAlphaComponent(1) ?? HPTokens.blue
        g.saveGState()
        g.addPath(path); g.setStrokeColor(NSColor(white: 0, alpha: 0.35).cgColor); g.setLineWidth(10); g.strokePath()
        g.addPath(path); g.setStrokeColor(accent.cgColor); g.setLineWidth(6); g.strokePath()
        g.restoreGState()
    }
}

// MARK: - 自檢（main.swift 的 --selftest）

extension ShellAccessibility {
    static func selftest(_ check: (Bool, String) -> Void) {
        let savedNav = Shell.nav, savedSheet = Shell.peopleSheet, savedCC = Shell.ccT, savedNotes = HPAX.notes
        defer { Shell.nav = savedNav; Shell.peopleSheet = savedSheet; Shell.ccT = savedCC; HPAX._setForTesting(savedNotes) }
        let face = Face(); face.frozen = true
        // --home：主畫面的每一項都有一個元素，標籤都不空
        Shell.nav = ShellNav(); Shell.nav.screen = .home; Shell.peopleSheet = false
        let home = items(face: face)
        let homeEls = home.filter { $0.kind == .homeItem }
        check(homeEls.count == Shell.homeItems().count, "輔助使用：--home 的元素數＝主畫面項目數（\(homeEls.count)／\(Shell.homeItems().count)）")
        check(home.allSatisfy { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }, "輔助使用：每個標籤都不是空字串")
        check(home.contains { $0.id == "home.app.music" && $0.label == AppRegistry.app("music")?.title && $0.press != .none }, "輔助使用：主畫面念得出「音樂」而且按得下")
        check(Set(home.map(\.id)).count == home.count, "輔助使用：元素 id 不重複")
        // 框：斜著看的機身（梯形投影）也都落在視圖裡
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let corners = [CGPoint(x: 40, y: 262), CGPoint(x: 252, y: 250), CGPoint(x: 258, y: 46), CGPoint(x: 36, y: 34)]
        let projected = home.compactMap { project($0.rect, corners: corners) }
        check(projected.count == home.count && projected.allSatisfy { bounds.contains($0) && $0.width > 1 }, "輔助使用：框投影到視圖裡")
        if let full = project(CGRect(x: 0, y: 0, width: 1024, height: 1024), corners: [CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 0)]) {
            check(abs(full.minX) < 1e-6 && abs(full.maxY - 100) < 1e-6 && abs(full.width - 100) < 1e-6, "輔助使用：正視時畫布剛好鋪滿螢幕四角")
        } else { check(false, "輔助使用：正視投影") }
        // 鍵盤：FaceTime 往右是家庭、往下是音樂；最右邊再往右沒有
        let rects = homeEls.map(\.rect), ids = homeEls.map(\.id)
        if let ft = ids.firstIndex(of: "home.app.facetime") {
            check(neighbor(from: rects[ft], .right, in: rects).map { ids[$0] } == "home.app.home", "輔助使用：→ 走到右邊那一格")
            check(neighbor(from: rects[ft], .down, in: rects).map { ids[$0] } == "home.app.music", "輔助使用：↓ 走到下面那一格")
            check(neighbor(from: rects[ft], .left, in: rects) == nil, "輔助使用：最左邊再往左交回原本的鍵")
        } else { check(false, "輔助使用：主畫面有 FaceTime") }
        // 控制中心：每塊磚一個元素；音量、亮度是滑桿
        Shell.nav.overlay = .controlCenter; Shell.ccT = 1
        let cc = items(face: face)
        check(cc.count >= ControlCenter.placed(page: 0).count && cc.allSatisfy { !$0.label.isEmpty }, "輔助使用：控制中心每個模組都有標籤")
        check(cc.filter { if case .slider = $0.role { return true }; return false }.count == 2, "輔助使用：音量、亮度是滑桿")
        // App：元件記下來的按鈕變成元素，按下＝點那顆的中心
        Shell.nav.overlay = .none; Shell.nav.screen = .app("alarms"); Shell.appMorph = nil   // 計時器頁的控制平常藏著（照官方），用鬧鐘頁驗返回鈕
        HPAX._setForTesting([HPAXNote(role: .button, label: "Start", rect: CGRect(x: 100, y: 800, width: 300, height: 100))])
        let app = items(face: face)
        check(app.contains { $0.id == "back" } && app.contains { $0.label == "Start" && $0.press == .tap(CGPoint(x: 250, y: 850)) }, "輔助使用：App 裡的返回鈕與按鈕（\(app.map { "\($0.id)=\($0.label)" })）")   // l10n-ignore：selftest 訊息
        // 2.0 depth：錄臉引導卡念得到說明、按得到取消（以前這層什麼都沒有）
        Shell.nav = ShellNav(); Shell.nav.screen = .home
        let savedEnroll = PeopleOverlay.enroll, savedText = PeopleOverlay.enrollText, savedCancel = PeopleOverlay.cancelRect
        PeopleOverlay.enroll = PeopleOverlay.Enroll(person: Person(id: "s", name: "Aaron", colorIndex: 0, isOwner: true))
        let enrollTitle = L("people.enroll.title", "看着屏幕，慢慢转头"), enrollWho = String(format: L("people.enroll.for", "正在录制：%@"), "Aaron")
        PeopleOverlay.enrollText = (enrollTitle, L("people.enroll.front", "先正对着屏幕"), enrollWho, CGRect(x: 104, y: 416, width: 816, height: 280))
        PeopleOverlay.cancelRect = CGRect(x: 318, y: 706, width: 388, height: 116)
        let enroll = items(face: face)
        check(enroll.contains { $0.id == "enroll.text" && $0.role == .heading && $0.label == enrollTitle }
              && enroll.contains { $0.id == "enroll.cancel" && $0.press != .none }, "輔助使用：錄臉引導念說明、按得到取消")   // l10n-ignore：selftest 訊息
        PeopleOverlay.enroll = savedEnroll; PeopleOverlay.enrollText = savedText; PeopleOverlay.cancelRect = savedCancel
        // 錶面：一顆念時間日期的按鈕（按下＝CarPlay，跟 1.0 一樣）；模組錶面有下一個行程就多念一個元素
        Shell.nav = ShellNav()
        let savedStyle = face.style, savedTile = face.calendarTile
        face.style = .island
        let f = items(face: face)
        check(f.count == 1 && f[0].press == .carPlay && !f[0].label.isEmpty, "輔助使用：錶面念時間與日期")   // l10n-ignore：selftest 訊息
        face.style = .modular
        face.calendarTile = .event(NextEvent(title: "Dentist", start: Date(timeIntervalSinceNow: 3600), end: Date(timeIntervalSinceNow: 4200)))
        let fm = items(face: face)
        check(fm.contains { $0.id == "face.data" && $0.label.hasPrefix("Dentist") }, "輔助使用：模組錶面念下一個行程")   // l10n-ignore：selftest 訊息
        face.style = savedStyle; face.calendarTile = savedTile
        // HPAX：主畫布上記的框換回 1024 座標；離屏畫布不記
        _ = makeImage(512, 512) { g in
            g.scaleBy(x: 0.5, y: 0.5)
            HPAX.begin(g)
            g.saveGState(); g.translateBy(x: 0, y: 200)
            HPAX.note(g, CGRect(x: 10, y: 20, width: 100, height: 50), .button, "A")
            g.restoreGState()
            _ = makeImage(64, 64) { c in HPAX.note(c, CGRect(x: 0, y: 0, width: 30, height: 30), .button, "B") }
            HPAX.note(g, CGRect(x: 2000, y: 0, width: 100, height: 50), .button, "C")
            HPAX.end()
        }
        let noted = HPAX.notes.map(\.label) == ["A"] && HPAX.notes.first.map { abs($0.rect.minY - 220) < 0.01 && abs($0.rect.width - 100) < 0.01 } == true
        check(noted, "輔助使用：元件記的框換回畫布座標，離屏與畫面外的不記")
        // 字級：預設照官方（膠囊列 113／135），大字放大
        check(HPAccessibilitySettings.scale(for: 0) == 1 && HPAccessibilitySettings.scale(for: 2) == 1.5 && HPType.textScale == 1, "輔助使用：畫面文字大小三級")
        let rowsSame = HPComponents.capsuleRowHeight(title: "x", subtitle: nil, trailing: nil, width: 900) == 113
            && HPComponents.capsuleRowHeight(title: "x", subtitle: "9:00", trailing: nil, width: 900) == 135
        check(rowsSame, "輔助使用：預設字級時膠囊列高度不變")
    }
}
