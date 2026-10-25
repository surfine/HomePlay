// 2.0 P03：頂端 👀 膠囊＝我們的 Dynamic Island（HIG Live Activities；Chan「Design dynamic Live Activities」WWDC23 7:40 起）。
//
// 三種呈現：
//   compact：只有一個活動。👀 當成鏡頭留在正中，左邊 leading、右邊 trailing 緊貼眼睛兩側，左右同寬（取較大的、各自置中），
//            高度跟沒有活動時的膠囊一樣（62），越窄越好；也因此不會壓到主畫面左上的問候語。
//   minimal：兩到三個活動。第一個接在膠囊右側，其餘分離成圓形（內容寬就變橢圓）的小藥丸，右一個、左一個；
//            每一個仍然顯示資訊（計時器的環、音樂的音量條、通話的秒數），不退回只有 logo。
//   expanded：按住膠囊（或小藥丸）展開成大卡：眼睛留在頂端正中，leading／trailing 留在原本的左右兩側（相對位置不變），
//            下面放標題與動作（計時器 +1 分鐘／停止、音樂上一首／播放／下一首、通話掛斷、訊息回覆）；
//            高度照內容（沒有動作的 ClioTalk 比較矮），上緣就是膠囊上緣、眼睛兩側緊貼，不留「額頭」。
// 膠囊材質跟著年代（我們刻意保留的例外，HIG 的島是不透明黑）：純黑年代是黑，玻璃／黑透年代是深色玻璃；
// 外圈一道跟活動主色一致的 key line。大卡裡的按鈕用填色，不再上一層玻璃。
// 夜間（spec4 #3）：整面轉紅時只把眼睛那一段貼回原樣（主畫面 Shell.nightKeep、錶面 LiveActivityStack.faceKeep）。
// 點：compact／minimal／大卡空白處＝打開 App 到那件事（訊息到那串對話、計時器到那一組）；按住＝展開；點大卡外面或 Esc＝收回。
// 活動超過 8 小時就不再顯示；設定 › 通用 › 即時動態 可以每個 App 關掉，訊息另有「顯示預覽」。
// 快照：--live-activity timer,music,call,message,cliotalk（逗號分隔，可多個）；--live-activity-expanded <同上其一>。

import AppKit
import SwiftUI

enum LiveActivityStack {
    // MARK: 規則（純邏輯，--selftest 直接驗）

    /// HIG：島上最多三個（一個接著、其他分離）
    static let maxShown = 3
    /// HIG：Live Activity 追蹤 8 小時內的事
    static let maxAge: Double = 8 * 3600
    /// compact／minimal 的高＝沒有活動時的膠囊高（HIG 尺寸表：compact、minimal 都跟島同高）
    static let height: CGFloat = 62
    static let idleWidth: CGFloat = 208
    static let gap: CGFloat = 14             // 眼睛 ↔ 內容（緊貼，不另外加 padding）
    static let endPad: CGFloat = 18          // 內容 ↔ 膠囊兩端（落在半圓裡）
    static let detachGap: CGFloat = 12
    static let minimalPad: CGFloat = 14      // 分離小藥丸：內容 ↔ 邊
    static let expandedInset: CGFloat = 46   // 大卡左右離螢幕邊＝膠囊上緣離螢幕頂（跟螢幕圓角同心）

    /// 每個 App 的活動第一次出現的牆上時間（超過 8 小時就收）
    nonisolated(unsafe) static var firstSeen: [String: Double] = [:]

    /// 要顯示哪些：關掉的 App 拿掉、超過 8 小時的拿掉、最多三個（順序照 AppRegistry）
    static func visible(_ acts: [LiveActivity], wall: Double, seen: inout [String: Double], enabled: (String) -> Bool) -> [LiveActivity] {
        let live = Set(acts.map(\.appID))
        for k in Array(seen.keys) where !live.contains(k) { seen[k] = nil }   // 結束了：下次重新算
        var out: [LiveActivity] = []
        for a in acts {
            let t0 = seen[a.appID] ?? wall
            seen[a.appID] = t0
            guard enabled(a.appID), wall - t0 <= maxAge else { continue }
            out.append(a)
        }
        return Array(out.prefix(maxShown))
    }

    // MARK: 設定（設定 › 通用 › 即時動態）

    static func offKey(_ id: String) -> String { "liveActivity.off.\(id)" }
    static let noPreviewKey = "liveActivity.messages.noPreview"
    static let settingApps = ["timers", "music", "messages", "facetime", "cliotalk"]
    static func enabledSetting(_ id: String) -> Bool { !UserDefaults.standard.bool(forKey: offKey(id)) }
    static func setEnabled(_ on: Bool, _ id: String) { UserDefaults.standard.set(!on, forKey: offKey(id)) }
    /// 快照／示範一律全開（不照這台 Mac 的偏好）
    static func enabled(_ id: String) -> Bool { SnapshotPrivacy.active || enabledSetting(id) }
    static var showsMessagePreview: Bool { SnapshotPrivacy.active || !UserDefaults.standard.bool(forKey: noPreviewKey) }

    // MARK: 版面（純函數）

    struct Layout: Equatable {
        var pill: CGRect          // 接著眼睛的那顆
        var leading: CGRect?      // compact 才有
        var trailing: CGRect      // compact：右邊；minimal：接在膠囊上的那一格
        var detached: [CGRect]    // 分離的 minimal（右、左）
    }

    /// eh：眼睛的半寬（中心到外緣）；single：只有一個活動時 leading／trailing 內容寬；minimal：多個活動時各自的內容寬
    static func layout(eyesHalf eh: CGFloat, top: CGFloat, centerX cx: CGFloat = 512,
                       single: (lead: CGFloat, trail: CGFloat)?, minimal: [CGFloat]) -> Layout {
        if let s = single {
            let side = max(s.lead, s.trail)
            let w = max(idleWidth, 2 * (eh + gap + side + endPad))
            return Layout(pill: CGRect(x: cx - w / 2, y: top, width: w, height: height),
                          leading: CGRect(x: cx - eh - gap - side, y: top, width: side, height: height),
                          trailing: CGRect(x: cx + eh + gap, y: top, width: side, height: height), detached: [])
        }
        let m0 = minimal.first ?? 0
        let minX = cx - idleWidth / 2, maxX = max(cx + idleWidth / 2, cx + eh + gap + m0 + endPad)
        let pill = CGRect(x: minX, y: top, width: maxX - minX, height: height)
        var det: [CGRect] = []
        for (i, w) in minimal.dropFirst().enumerated() {
            let dw = max(height, w + 2 * minimalPad)   // 圓形；內容寬就變橢圓
            det.append(i == 0 ? CGRect(x: pill.maxX + detachGap, y: top, width: dw, height: height)
                              : CGRect(x: pill.minX - detachGap - dw, y: top, width: dw, height: height))
        }
        return Layout(pill: pill, leading: nil, trailing: CGRect(x: cx + eh + gap, y: top, width: m0, height: height), detached: det)
    }

    /// 大卡：上緣＝膠囊上緣，左右離螢幕邊 46；高度照內容
    static func expandedRect(height h: CGFloat, top: CGFloat) -> CGRect {
        CGRect(x: expandedInset, y: top, width: 1024 - 2 * expandedInset, height: h)
    }
    static func expandedRadius(_ r: CGRect) -> CGFloat { min(r.height / 2, Screen.concentric(inset: expandedInset)) }
    /// 有動作列的 200；音樂多一條進度 236；沒有動作的（ClioTalk）矮成膠囊型 150
    static func expandedHeight(_ k: LiveActivity.Kind) -> CGFloat {
        switch k { case .music: return 236; case .assistant: return 150; default: return 200 }
    }

    // MARK: 狀態

    /// 展開的是哪個 App 的活動
    nonisolated(unsafe) static var expandedApp: String?
    static let spring = HPMotion.T.liveActivity.spring   // 動效包：點按沒有動量 → 臨界阻尼、不回彈（Design/HPMotionTable.swift）
    nonisolated(unsafe) static var expandAnim = MotionValue("la.expand", spring: spring, from: 0, to: 0, now: 0)
    static func expandT(_ now: Double) -> CGFloat { expandedApp == nil ? 0 : max(0, min(1.06, expandAnim.value(now))) }
    static func expand(_ id: String, now: Double) { expandedApp = id; expandAnim.retarget(1, now: now) }
    /// 收回；本來有展開回 true
    @discardableResult
    static func collapse(_ now: Double) -> Bool {
        guard expandedApp != nil, expandAnim.to != 0 else { return false }
        expandAnim.retarget(0, now: now); return true
    }
    /// 主畫面的問候語：大卡蓋過來時淡出（compact／minimal 只有 62 高，碰不到）
    static func greetingAlpha(_ now: Double) -> CGFloat { 1 - max(0, min(1, expandT(now) * 1.6)) }

    /// 這一幀 compact／minimal 的版面（Shell.pillRect 照它長大）
    nonisolated(unsafe) static var compactPill = CGRect(x: 512 - idleWidth / 2, y: 46, width: idleWidth, height: height)
    /// 夜間：只貼回兩隻眼睛（nil＝照原本的作法）；錶面的大膠囊、主畫面的膠囊各一份
    nonisolated(unsafe) static var faceKeep: CGPath?
    nonisolated(unsafe) static var homeKeep: CGPath?
    /// 兩隻眼睛的外形（略放大一圈蓋住反鋸齒的邊）
    static func eyesPath(cx: CGFloat, cy: CGFloat, sep: CGFloat, rx: CGFloat, ry: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for s: CGFloat in [-1, 1] { p.addEllipse(in: CGRect(x: cx + s * sep - rx - 3, y: cy - ry - 3, width: 2 * rx + 6, height: 2 * ry + 6)) }
        return p
    }

    enum Button: Equatable { case timerAdd, timerStop, musicPrev, musicPlay, musicNext, callEnd, messageReply }
    enum Hit: Equatable { case pill, minimal(Int), button(Button), card }
    /// 這一幀畫出來的點擊區（index 對 shown）
    nonisolated(unsafe) static var hits: [(Hit, CGRect)] = []
    nonisolated(unsafe) static var shown: [LiveActivity] = []
    nonisolated(unsafe) private static var lastFrameTenth = -1

    /// 每幀（tickShell）：展開的彈簧、音量條在動就要重畫
    static func tick(_ face: Face, _ now: Double) -> Bool {
        var dirty = false
        if expandedApp != nil {
            if !expandAnim.done(now) { dirty = true }
            else if expandAnim.to == 0 { expandedApp = nil; dirty = true }
            if let id = expandedApp, !shown.contains(where: { $0.appID == id }), !shown.isEmpty || Shell.pillT < 0.02 { expandedApp = nil; dirty = true }
        }
        if shown.contains(where: { $0.kind == .music || $0.kind == .assistant }), !HPMotion.reduceMotion {
            let t = Int(now * 12)
            if t != lastFrameTenth { lastFrameTenth = t; dirty = true }
        }
        return dirty
    }

    // MARK: 點

    /// 主畫面／App 上的點按先問這裡；吃掉回 true。open：打開 App（外殼的 shellOpenApp）
    static func tap(_ p: CGPoint, long: Bool, now: Double, face: Face, open: (LiveActivity) -> Void) -> Bool {
        let hit = hits.last(where: { $0.1.contains(p) })?.0
        if let id = expandedApp, expandAnim.to != 0 {
            guard let a = shown.first(where: { $0.appID == id }) else { collapse(now); return true }
            switch hit {
            case .button(let b)?: perform(b, a, face: face, now: now)
            case .card?, .pill?: collapse(now); open(a)
            default: collapse(now)   // 點大卡外面：收回（這一下不穿過去）
            }
            return true
        }
        switch hit {
        case .pill?:
            guard let a = shown.first else { return true }
            if long { expand(a.appID, now: now) } else { open(a) }
            return true
        case .minimal(let i)?:
            guard i < shown.count else { return true }
            if long { expand(shown[i].appID, now: now) } else { open(shown[i]) }
            return true
        default:
            // 沒有活動時膠囊照舊吃掉點按（不穿到底下的圖示）
            return Shell.pillRect(Shell.pillT).insetBy(dx: -10, dy: min(0, (height - 88) / 2)).contains(p)
        }
    }

    /// 打開 App 之後再帶到那件事（深連結）
    static func follow(_ a: LiveActivity) {
        switch a.kind {
        case .message where a.appID == "messages": MessagesApp.shared.openFromActivity(a.link)   // 2.0 Web App 的通知也是 .message
        case .timer:
            if let s = a.link, let id = Int(s), Shell.timers.timer(id) != nil { TimersApp.shared.selected = id; TimersApp.shared.adding = false }
        default: break
        }
    }
    /// 外殼開 App＋深連結（selftest 用 navigate 換掉真的開 App）
    static func open(_ a: LiveActivity, navigate: (String) -> Void) {
        navigate(a.appID)
        follow(a)
    }

    private static func perform(_ b: Button, _ a: LiveActivity, face: Face, now: Double) {
        switch b {
        case .timerAdd:
            if let s = a.link, let id = Int(s) { Shell.timers.addTime(id, seconds: 60); Shell.reconcileTimers(face, now: now) }
        case .timerStop:
            if let s = a.link, let id = Int(s) { Shell.removeTimer(id, face: face) }
            collapse(now)
        case .musicPrev, .musicPlay, .musicNext:
            if b == .musicPrev { NowPlayingPoller.shared.control(.previous) }
            if b == .musicPlay { NowPlayingPoller.shared.control(.playPause) }
            if b == .musicNext { NowPlayingPoller.shared.control(.next) }
        case .callEnd: FaceTimeCall.shared.end(); collapse(now)
        case .messageReply: collapse(now); if let v = (NSApp.delegate as? AppDelegate)?.view { v.shellOpenApp(a.appID) }; follow(a); MessagesApp.shared.replyByVoice()   // 2.0 imsg：回覆＝開到對話直接聽
        }
        face.forceDirty = true
    }

    // MARK: 快照

    static let demoKinds = ["timer", "music", "call", "message", "cliotalk"]
    static func appID(forDemo k: String) -> String? {
        ["timer": "timers", "music": "music", "call": "facetime", "message": "messages", "cliotalk": "cliotalk"][k]
    }
    /// --live-activity 的音樂、通話（計時器、訊息、ClioTalk 由外殼照舊放）
    static func applyDemo(_ kinds: Set<String>, face: Face) {
        if kinds.contains("music"), let m = AppRegistry.app("music") as? MusicApp { m.applyDemo(page: nil, face: face) }
        if kinds.contains("call") {
            let c = FaceTimeCall.shared
            c.demoElapsed = 42
            c.prepare(FaceTimeApp.demoContacts[0], video: true)
            c.dial(confirmedByUser: true)   // demoElapsed 在：不會真的撥
        }
    }
    /// --live-activity-expanded <kind>：直接停在展開好的大卡
    static func applyExpandedDemo(_ kind: String) {
        guard let id = appID(forDemo: kind) else { return }
        expandedApp = id
        expandAnim = MotionValue("la.expand", spring: spring, from: HPMotion.frozen("la.expand") == nil ? 1 : 0, to: 1, now: CACurrentMediaTime())
    }
}

// MARK: - 畫

extension Face {
    /// 頂端膠囊要顯示的全部活動（已套用設定、8 小時、最多三個）
    func shellActivities(_ now: Double) -> [LiveActivity] {
        let all = (AppRegistry.all + AppProviders.activityApps).compactMap { $0.liveActivity(face: self, now: now) }   // 2.0 Web App：開著的、背景在播的也問
        return LiveActivityStack.visible(all, wall: Date().timeIntervalSince1970, seen: &LiveActivityStack.firstSeen,
                                         enabled: LiveActivityStack.enabled)
    }

    /// 眼睛的半寬（膠囊上的眼睛 k＝0.5）
    var laEyesHalf: CGFloat { (cur.sep + cur.rx) * 0.5 }

    private static let laValueFont = Face.rounded(32, weight: .bold)
    private static let laNameFont = Face.rounded(28, weight: .semibold)
    private static let laMiniFont = Face.rounded(26, weight: .bold)

    /// compact 的內容寬
    private func laWidths(_ a: LiveActivity) -> (lead: CGFloat, trail: CGFloat, mini: CGFloat) {
        switch a.kind {
        case .timer: return (40, Typo.width(a.detail, Self.laValueFont), 38)
        case .music, .assistant: return (40, 40, 34)
        case .call: return (40, min(140, Typo.width(a.detail, Self.laValueFont)), min(110, Typo.width(a.detail, Self.laMiniFont)))
        case .message: return (40, min(150, Typo.width(a.title, Self.laNameFont)), 34)
        }
    }

    /// 算好這一幀的 compact／minimal 版面（Shell.pillRect 照它長大）
    func laLayout(_ acts: [LiveActivity]) -> LiveActivityStack.Layout {
        let eh = laEyesHalf
        if acts.count == 1 {
            let w = laWidths(acts[0])
            return LiveActivityStack.layout(eyesHalf: eh, top: Shell.pillTop, single: (w.lead, w.trail), minimal: [])
        }
        return LiveActivityStack.layout(eyesHalf: eh, top: Shell.pillTop, single: nil, minimal: acts.map { laWidths($0).mini })
    }

    /// 頂端膠囊的活動層：r＝這一幀膠囊（idle → compact 的插值），t＝長大進度。畫完本體與內容，眼睛由呼叫端畫在上面
    func drawActivityStack(_ g: CGContext, _ r: CGRect, t: CGFloat, acts: [LiveActivity], now: Double) {
        typealias S = LiveActivityStack
        S.hits = []; S.shown = acts
        guard !acts.isEmpty else {   // 活動剛結束、膠囊還在縮回去
            laBody(g, r, radius: r.height / 2, key: .white, backdrop: g.makeImage()); return
        }
        let lay = laLayout(acts)
        let expandedAct = S.expandedApp.flatMap { id in acts.first { $0.appID == id } }
        let e = expandedAct == nil ? 0 : S.expandT(now)
        let main = expandedAct ?? acts[0]
        let backdrop = g.makeImage()
        // 本體：膠囊 → 大卡（同一個形狀變形，不是換圖）
        let big = S.expandedRect(height: S.expandedHeight(main.kind), top: r.minY)
        let body = Shell.lerp(r, big, min(1, e))
        let rad = r.height / 2 + (S.expandedRadius(big) - r.height / 2) * min(1, e)
        laBody(g, body, radius: rad, key: main.accent, backdrop: backdrop)
        // 分離的小藥丸：從膠囊右緣分出去；展開時收起
        let dAlpha = max(0, min(1, (t - 0.3) / 0.7)) * (1 - min(1, e * 2))
        for (i, d) in lay.detached.enumerated() where i + 1 < acts.count && dAlpha > 0.01 {
            let from = CGRect(x: r.maxX - d.width, y: d.minY, width: d.width, height: d.height)
            let dr = Shell.lerp(from, d, t)
            g.saveGState(); g.setAlpha(dAlpha)
            laBody(g, dr, radius: dr.height / 2, key: acts[i + 1].accent, backdrop: backdrop)
            laMinimal(g, acts[i + 1], in: dr.insetBy(dx: S.minimalPad, dy: 0), now: now)
            g.restoreGState()
            S.hits.append((.minimal(i + 1), dr.insetBy(dx: -4, dy: min(0, (dr.height - 88) / 2))))
        }
        // compact／minimal 內容：展開時先淡出
        let ca = max(0, min(1, (t - 0.3) / 0.7)) * max(0, 1 - e / 0.35)
        if ca > 0.01 {
            g.saveGState(); g.setAlpha(ca)
            if acts.count == 1, let lead = lay.leading {
                laLeading(g, acts[0], center: CGPoint(x: lead.midX, y: lead.midY), size: 40, now: now)
                laTrailing(g, acts[0], in: lay.trailing, now: now)
            } else {
                laMinimal(g, acts[0], in: lay.trailing, now: now)
            }
            g.restoreGState()
        }
        S.hits.insert((.pill, r.insetBy(dx: -10, dy: min(0, (r.height - 88) / 2))), at: 0)
        // 大卡內容：容器先長，內容後到
        if let a = expandedAct {
            let ea = max(0, min(1, (e - 0.55) / 0.45))
            S.hits.append((.card, body))
            if ea > 0.01 {
                g.saveGState(); g.setAlpha(ea)
                laExpanded(g, a, in: body, now: now)
                g.restoreGState()
            }
        }
    }

    /// 膠囊／大卡本體：材質跟著年代；外圈 key line 用活動主色
    private func laBody(_ g: CGContext, _ rect: CGRect, radius: CGFloat, key: NSColor, backdrop: CGImage?) {
        let path = radius >= rect.height / 2 - 0.5
            ? CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
            : continuousRoundedRect(rect, radius: radius)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 6), blur: 22, color: NSColor(white: 0, alpha: 0.28).cgColor)
        g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
        g.restoreGState()
        let look = capsuleLook()
        if look == .glass || look == .smoke, let bd = backdrop, let blur = laBlur(bd, rect) {
            // 深色玻璃：底下模糊透上來、壓暗到字看得清；頂部一道內光
            g.saveGState(); g.addPath(path); g.clip()
            drawUpright(g, blur.image, in: blur.rect)
            g.setFillColor(NSColor(white: 0.02, alpha: 0.66).cgColor); g.fill(rect)
            let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(glow, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.minY + min(40, rect.height * 0.4)), options: [])
            g.restoreGState()
        }
        g.saveGState()
        g.addPath(path); g.setStrokeColor(key.withAlphaComponent(0.3).cgColor); g.setLineWidth(2); g.strokePath()
        g.restoreGState()
    }

    /// 底下那一塊模糊（像素座標裁一塊、高斯模糊；同一塊、同一秒用快取）
    private func laBlur(_ shot: CGImage, _ rect: CGRect) -> (image: CGImage, rect: CGRect)? {
        let sc = CGFloat(shot.width) / 1024
        let r = rect.insetBy(dx: -24, dy: -24).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024)).integral
        guard r.width > 1, r.height > 1 else { return nil }
        let key = "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))|\(shot.width)|\(Int(Date().timeIntervalSince1970))"
        if let c = Self.laBlurCache, c.key == key { return (c.image, c.rect) }
        guard let crop = shot.cropping(to: CGRect(x: r.minX * sc, y: r.minY * sc, width: r.width * sc, height: r.height * sc)) else { return nil }
        let ci = CIImage(cgImage: crop)
        let out = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 16 * sc]).cropped(to: ci.extent)
        guard let img = Face.ciContext.createCGImage(out, from: ci.extent) else { return nil }
        Self.laBlurCache = (key, img, r)
        return (img, r)
    }
    nonisolated(unsafe) private static var laBlurCache: (key: String, image: CGImage, rect: CGRect)?

    // MARK: 內容

    /// leading：環、封面、符號、ClioTalk 的珠
    private func laLeading(_ g: CGContext, _ a: LiveActivity, center c: CGPoint, size s: CGFloat, now: Double) {
        let box = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
        switch a.kind {
        case .timer: laRing(g, a, center: c, radius: s / 2 - 4, width: s * 0.15)
        case .music:
            g.saveGState(); g.addPath(continuousRoundedRect(box, radius: s * 0.22)); g.clip()
            if let art = NowPlayingPage.shared.artwork(face: self) { drawUpright(g, art, in: box) }   // 2.0 v2-music：跟正在播放同一張封面
            else { g.setFillColor(a.accent.cgColor); g.fill(box); drawSymbol(g, "music.note", in: box.insetBy(dx: s * 0.24, dy: s * 0.22), color: .white) }
            g.restoreGState()
        case .call: drawSymbol(g, a.symbol ?? "phone.fill", in: box.insetBy(dx: 0, dy: s * 0.14), color: a.accent)
        case .message: drawSymbol(g, a.symbol ?? "message.fill", in: box.insetBy(dx: s * 0.04, dy: s * 0.08), color: a.accent)
        case .assistant:
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [NSColor.white.cgColor, a.accent.cgColor, a.accent.withAlphaComponent(0.6).cgColor] as CFArray,
                                  locations: [0, 0.55, 1])!
            g.saveGState(); g.addEllipse(in: box.insetBy(dx: 3, dy: 3)); g.clip()
            g.drawRadialGradient(grad, startCenter: CGPoint(x: c.x - s * 0.15, y: c.y - s * 0.15), startRadius: 0, endCenter: c, endRadius: s / 2, options: [.drawsAfterEndLocation])
            g.restoreGState()
        }
    }

    private func laRing(_ g: CGContext, _ a: LiveActivity, center c: CGPoint, radius rr: CGFloat, width w: CGFloat) {
        g.saveGState()
        g.setLineWidth(w); g.setLineCap(.round)
        g.setStrokeColor(a.accent.withAlphaComponent(0.28).cgColor)
        g.addArc(center: c, radius: rr, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
        g.setStrokeColor(a.accent.cgColor)
        g.addArc(center: c, radius: rr, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * CGFloat(a.progress ?? 1), clockwise: false); g.strokePath()
        g.restoreGState()
    }

    /// 跳動的音量條（音樂、ClioTalk 回答中）；減少動態效果時靜止
    private func laBars(_ g: CGContext, in r: CGRect, color: NSColor, now: Double) {
        let n = 4, bw = r.width / CGFloat(n * 2 - 1)
        let still: [CGFloat] = [0.45, 0.85, 0.6, 0.35]
        for i in 0..<n {
            let k = HPMotion.reduceMotion || HPMotion.frozen("la.expand") != nil ? still[i]
                : 0.3 + 0.7 * CGFloat(abs(sin(now * (2.4 + Double(i) * 0.7) + Double(i) * 1.3)))
            let h = max(bw, r.height * k)
            let bar = CGRect(x: r.minX + CGFloat(i) * bw * 2, y: r.midY - h / 2, width: bw, height: h)
            g.addPath(CGPath(roundedRect: bar, cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil))
        }
        g.setFillColor(color.cgColor); g.fillPath()
    }

    /// trailing：要看的那個值（倒數、通話秒數、寄件人）或音量條
    private func laTrailing(_ g: CGContext, _ a: LiveActivity, in slot: CGRect, now: Double) {
        switch a.kind {
        case .timer, .call:
            let s = Face.clipped(a.detail, Self.laValueFont, 140), w = Typo.width(s, Self.laValueFont)
            HPNumeric.draw(g, self, key: "la.\(a.appID)", s, font: Self.laValueFont, x: slot.midX - w / 2, y: slot.midY + 11.5, color: a.accent, now: now)   // 動效包：數字轉場（HIG-LA-105）
        case .message:
            let s = Face.clipped(a.title, Self.laNameFont, 150), w = Typo.width(s, Self.laNameFont)
            drawLeft(g, s, font: Self.laNameFont, x: slot.midX - w / 2, y: slot.midY + 10, color: .white)
        case .music, .assistant:
            laBars(g, in: CGRect(x: slot.midX - 20, y: slot.midY - 16, width: 40, height: 32), color: a.accent, now: now)
        }
    }

    /// minimal：小到只剩一格也要有資訊（環、音量條、秒數）
    private func laMinimal(_ g: CGContext, _ a: LiveActivity, in slot: CGRect, now: Double) {
        let c = CGPoint(x: slot.midX, y: slot.midY)
        switch a.kind {
        case .timer: laRing(g, a, center: c, radius: 15, width: 6)
        case .music, .assistant: laBars(g, in: CGRect(x: c.x - 17, y: c.y - 14, width: 34, height: 28), color: a.accent, now: now)
        case .message: drawSymbol(g, a.symbol ?? "message.fill", in: CGRect(x: c.x - 17, y: c.y - 15, width: 34, height: 30), color: a.accent)
        case .call:
            let s = Face.clipped(a.detail, Self.laMiniFont, 110), w = Typo.width(s, Self.laMiniFont)
            drawLeft(g, s, font: Self.laMiniFont, x: c.x - w / 2, y: c.y + 9.5, color: a.accent)
        }
    }

    /// 大卡：頂列＝compact 的放大版（左 leading＋App 名、右 trailing），下面標題與動作
    private func laExpanded(_ g: CGContext, _ a: LiveActivity, in R: CGRect, now: Double) {
        typealias S = LiveActivityStack
        let cy = R.minY + S.height / 2, side: CGFloat = 36
        let eyesL = 512 - laEyesHalf - S.gap
        // 左上：leading＋App 名（跟眼睛之間留 gap）
        let lead = CGPoint(x: R.minX + side + 26, y: cy)
        laLeading(g, a, center: lead, size: 52, now: now)
        let small = Face.rounded(28, weight: .semibold)
        if let name = AppRegistry.app(a.appID)?.title {
            let x = lead.x + 26 + 16
            drawLeft(g, Face.clipped(name, small, eyesL - x), font: small, x: x, y: cy + 10, color: NSColor.white.withAlphaComponent(0.6))
        }
        // 右上：trailing 放大
        let right = R.maxX - side
        switch a.kind {
        case .timer, .call:
            let f = Face.rounded(a.kind == .timer ? 52 : 44, weight: .bold)
            let s = Face.clipped(a.detail, f, 300), w = Typo.width(s, f)
            HPNumeric.draw(g, self, key: "la.big.\(a.appID)", s, font: f, x: right - w, y: cy + (a.kind == .timer ? 19 : 16), color: a.accent, now: now)   // 動效包
        case .message:
            let f = Face.rounded(30, weight: .semibold), s = Face.clipped(a.title, f, right - 512 - laEyesHalf - S.gap), w = Typo.width(s, f)
            drawLeft(g, s, font: f, x: right - w, y: cy + 11, color: .white)
        case .music, .assistant:
            laBars(g, in: CGRect(x: right - 52, y: cy - 20, width: 52, height: 40), color: a.accent, now: now)
        }
        // 下面：標題（左）＋動作（右，88 高、填色，不疊玻璃）
        let rowTop = R.minY + S.height + 6, rowBottom = R.maxY - (a.kind == .music ? 48 : 24)
        let rowMid = (rowTop + rowBottom) / 2
        var buttons: [(S.Button, String?, String?, NSColor, NSColor)] = []   // (動作, 符號, 字, 底色, 前景)
        let fill = NSColor(white: 1, alpha: 0.16)
        switch a.kind {
        case .timer:
            if a.link != nil {
                buttons = [(.timerAdd, nil, "+1:00", fill, .white),   // l10n-ignore：時間
                           (.timerStop, "xmark", nil, a.accent.withAlphaComponent(0.3), a.accent)]
            }
        case .music:
            let playing = NowPlayingPage.shared.demo?.info.playing ?? nowPlaying.info?.playing ?? true
            buttons = [(.musicPrev, "backward.fill", nil, fill, .white), (.musicPlay, playing ? "pause.fill" : "play.fill", nil, fill, .white),
                       (.musicNext, "forward.fill", nil, fill, .white)]
        case .call: buttons = [(.callEnd, "phone.down.fill", nil, srgb(0xff3b30), .white)]
        case .message: buttons = [(.messageReply, nil, L("la.message.reply", "回复"), fill, .white)]
        case .assistant: break
        }
        var x = right
        let bf = Face.rounded(32, weight: .semibold)
        for (b, sym, text, bg, fg) in buttons.reversed() {
            let w = text.map { max(88, Typo.width($0, bf) + 64) } ?? 88
            let br = CGRect(x: x - w, y: rowMid - 44, width: w, height: 88)
            g.addPath(CGPath(roundedRect: br, cornerWidth: 44, cornerHeight: 44, transform: nil)); g.setFillColor(bg.cgColor); g.fillPath()
            if let sym { drawSymbol(g, sym, in: br.insetBy(dx: (w - 36) / 2, dy: 26), color: fg) }
            if let text { drawLeft(g, text, font: bf, x: br.midX - Typo.width(text, bf) / 2, y: br.midY + 11.5, color: fg) }
            LiveActivityStack.hits.append((.button(b), br.insetBy(dx: -4, dy: -4)))
            x = br.minX - 16
        }
        let textW = x - (R.minX + side) - 8
        let tf = Face.rounded(34, weight: .semibold), sf = Face.rounded(30, weight: .medium)
        let (title, sub): (String, String?) = {
            switch a.kind {
            case .timer: return (a.title, nil)
            case .music: return (a.title, a.detail)
            case .call: return (a.title, nil)
            case .message: return (a.detail, nil)
            case .assistant: return (a.detail, nil)
            }
        }()
        let tx = R.minX + side
        if let sub {
            drawLeft(g, Face.clipped(title, tf, textW), font: tf, x: tx, y: rowMid - 4, color: .white)
            drawLeft(g, Face.clipped(sub, sf, textW), font: sf, x: tx, y: rowMid + 34, color: NSColor.white.withAlphaComponent(0.6))
        } else {
            drawLeft(g, Face.clipped(title, tf, textW), font: tf, x: tx, y: rowMid + 12, color: .white)
        }
        if a.kind == .music {   // 進度
            let bar = CGRect(x: tx, y: R.maxY - 36, width: R.width - 2 * side, height: 8)
            g.addPath(CGPath(roundedRect: bar, cornerWidth: 4, cornerHeight: 4, transform: nil)); g.setFillColor(NSColor(white: 1, alpha: 0.2).cgColor); g.fillPath()
            let done = CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(max(0, min(1, a.progress ?? 0))), height: bar.height)
            g.addPath(CGPath(roundedRect: done, cornerWidth: 4, cornerHeight: 4, transform: nil)); g.setFillColor(NSColor.white.cgColor); g.fillPath()
        }
    }

    // MARK: 錶面上的大膠囊（main.swift drawIsland 叫）

    /// 錶面大膠囊除了計時器與音樂，還有沒有別的活動要它長大
    func faceHasOtherActivity(_ now: Double) -> Bool {
        shellActivities(now).contains { a in a.kind == .call || a.kind == .message || a.kind == .assistant || (a.kind == .music && !musicActive(now)) }
    }

    /// 錶面的大膠囊（rect，眼睛在 ex、大小 ke）長開時：主活動不是計時器／正在播放就由這裡畫；其他活動畫成膠囊下方的 minimal；
    /// 夜間記下眼睛那一段。回 true＝主活動已經畫了（不用再畫音樂）
    @discardableResult
    func drawFaceActivities(_ g: CGContext, rect: CGRect, eyesX ex: CGFloat, eyesK ke: CGFloat, lt: CGFloat, now: Double, red: Bool) -> Bool {
        LiveActivityStack.faceKeep = lt > 0.02 ? LiveActivityStack.eyesPath(cx: ex, cy: rect.midY, sep: cur.sep * ke, rx: cur.rx * ke, ry: cur.ry * ke) : nil
        guard lt > 0.02 else { return false }
        var acts = shellActivities(now).map { a -> LiveActivity in
            var a = a   // 2.0 P07：床頭夜灯照舊暗红；自畫夜間紅的 Modular 用夜間紅；其他夜間錶面畫白（映射後＝亮紅）
            a.accent = red ? srgb(0xb3261e) : nightOwnPalette ? HPTokens.Night.primary : Shell.nightTint(a.accent, self)
            return a
        }
        // 錶面的計時器、正在播放照舊由錶面自己畫（timerEnd、nowPlaying）
        let mainIsFace: Bool
        if timerEnd != nil { acts.removeAll { $0.kind == .timer }; mainIsFace = true }
        else if musicActive(now), let i = acts.firstIndex(where: { $0.kind == .music }), i == 0 || !acts.contains(where: { $0.kind != .music }) {
            acts.remove(at: i); mainIsFace = true
        } else { mainIsFace = false }
        var drew = false
        if !mainIsFace, let a = acts.first {
            g.saveGState(); g.setAlpha(min(1, (lt - 0.3) / 0.7))
            let c = CGPoint(x: rect.midX, y: rect.midY)
            drawLeft(g, Face.clipped(a.title, Self.rounded(34, weight: .bold), rect.maxX - 260 - (rect.minX + 300)), font: Self.rounded(34, weight: .bold),
                     x: rect.minX + 300, y: c.y - 14, color: a.accent)
            drawLeft(g, Face.clipped(a.kind == .message ? a.detail : (AppRegistry.app(a.appID)?.title ?? ""), Self.rounded(30, weight: .semibold), rect.maxX - 260 - (rect.minX + 300)),
                     font: Self.rounded(30, weight: .semibold), x: rect.minX + 300, y: c.y + 36,
                     color: nightOwnPalette && !red ? HPTokens.Night.secondary : NSColor.white.withAlphaComponent(red ? 0.35 : 0.6))
            let rc = CGPoint(x: rect.maxX - 104, y: c.y)
            switch a.kind {
            case .call:
                let f = Self.rounded(64, weight: .semibold), s = a.detail, w = Typo.width(s, f)
                drawLeft(g, s, font: f, x: rc.x - 64 - 24 - w, y: c.y + 23, color: a.accent)
                drawSymbol(g, a.symbol ?? "phone.fill", in: CGRect(x: rc.x - 52, y: rc.y - 40, width: 104, height: 80), color: a.accent)
            case .music, .assistant: laBars(g, in: CGRect(x: rc.x - 52, y: rc.y - 40, width: 104, height: 80), color: a.accent, now: now)
            case .message: drawSymbol(g, a.symbol ?? "message.fill", in: CGRect(x: rc.x - 52, y: rc.y - 46, width: 104, height: 92), color: a.accent)
            case .timer: laRing(g, a, center: rc, radius: 52, width: 15)
            }
            g.restoreGState()
            acts.removeFirst(); drew = true
        }
        // 其他活動：膠囊正下方一排分離的 minimal（錶面的大膠囊幾乎滿寬，旁邊放不下）
        let d: CGFloat = 104
        let ws = acts.map { a -> CGFloat in a.kind == .call ? max(d, Typo.width(a.detail, Self.rounded(40, weight: .bold)) + 56) : d }
        var x = rect.midX - (ws.reduce(0, +) + CGFloat(max(0, ws.count - 1)) * 18) / 2
        for (a, w) in zip(acts, ws) {
            let r = CGRect(x: x, y: rect.maxY + 20, width: w, height: d)
            g.saveGState(); g.setAlpha(min(1, (lt - 0.3) / 0.7))
            g.addPath(CGPath(roundedRect: r, cornerWidth: d / 2, cornerHeight: d / 2, transform: nil))
            g.setFillColor((red ? srgb(0x140403) : nightOwnPalette ? HPTokens.Night.fill : NSColor(white: 0, alpha: 0.82)).cgColor); g.fillPath()
            g.addPath(CGPath(roundedRect: r, cornerWidth: d / 2, cornerHeight: d / 2, transform: nil))
            g.setStrokeColor(a.accent.withAlphaComponent(0.3).cgColor); g.setLineWidth(2); g.strokePath()
            let c = CGPoint(x: r.midX, y: r.midY)
            switch a.kind {
            case .timer: laRing(g, a, center: c, radius: 26, width: 9)
            case .music, .assistant: laBars(g, in: CGRect(x: c.x - 28, y: c.y - 24, width: 56, height: 48), color: a.accent, now: now)
            case .message: drawSymbol(g, a.symbol ?? "message.fill", in: CGRect(x: c.x - 28, y: c.y - 25, width: 56, height: 50), color: a.accent)
            case .call:
                let f = Self.rounded(40, weight: .bold), w2 = Typo.width(a.detail, f)
                drawLeft(g, a.detail, font: f, x: c.x - w2 / 2, y: c.y + 14, color: a.accent)
            }
            g.restoreGState()
            x += w + 18
        }
        return drew
    }
}

// MARK: - 設定 › 通用 › 即時動態（原生分組表單的一個分區）

struct LiveActivitySettingsSection: View {
    @State private var version = 0
    var body: some View {
        Section {
            ForEach(LiveActivityStack.settingApps, id: \.self) { id in
                Toggle(AppRegistry.app(id)?.title ?? id, isOn: Binding(
                    get: { _ = version; return LiveActivityStack.enabledSetting(id) },
                    set: { LiveActivityStack.setEnabled($0, id); version += 1 }))
                if id == "messages" {
                    Toggle(isOn: Binding(
                        get: { _ = version; return !UserDefaults.standard.bool(forKey: LiveActivityStack.noPreviewKey) },
                        set: { UserDefaults.standard.set(!$0, forKey: LiveActivityStack.noPreviewKey); version += 1 })) {
                        RowLabel(title: L("la.settings.preview", "显示预览"), subtitle: L("la.settings.preview.sub", "关掉时只写「新信息」，不显示名字和内容"))
                    }
                    .disabled(!LiveActivityStack.enabledSetting("messages"))
                }
            }
        } header: {
            Text(L("la.settings.header", "实时活动"))
        } footer: {
            Text(L("la.settings.footer", "正在进行的事会显示在顶端的 👀 胶囊里；按住胶囊可以展开。超过 8 小时会自动结束。"))
        }
    }
}
