// 計時器 App（稿：hv-design/project/Timers.dc.html；版面照官方 timer.png）：一圈 60 格刻度，亮的部分是剩下的時間；
// 多組同時跑，底下列出其他幾組，點一下換到那組。帳在 Shell.timers（ShellNav.swift 的 TimerBook）；最快到點、在跑的那組
// 鏡射到錶面的計時器，眼睛膠囊、到點橫幅、右鍵選單的計時器都照舊（見 Shell.reconcileTimers）。
//
// 2.0 時鐘（照 iOS／watchOS 27 時鐘的計時器動態）：
// - 刻度圈每幀走：正在消失的那一根照比例從橘淡成暗棕（不是一格一跳）；剛開始時刻度從 12 點順時針亮起來。
// - 剩餘時間用數字捲動（numericText、countsDown：新數字從上面落下；只動有變的位數）。
// - 控制（點一下浮出，閒置 5 秒收起）：四角同心——左上返回、右上「＋」、左下「取消」（玻璃）、右下「暫停／繼續」
//   （橘↔綠染色玻璃，彈簧換色、符號交叉縮放）。
// - 到點：如果正開著這組，畫面變成「完成」——刻度整圈橘色呼吸、0:00、左下「重複」、右下「停止」；一分鐘沒人理就收。
// - 減少動態效果：刻度不呼吸、數字交叉淡化、不做亮起動畫。幀率：只有刻度真的需要（短計時器）或在捲動時才要求 60 fps。

import AppKit

final class TimersApp: PetApp {
    static let shared = TimersApp()
    let id = "timers"
    var title: String { L("app.timers", "计时器") }
    let icon = AppIcon(color: srgb(0xff9f0a), symbol: "timer")

    /// 正在大圈裡看的那組（nil＝最快到點的）
    var selected: Int?
    /// 「＋」：顯示預設時間的選單
    var adding = false
    private var lastQuantum = -1
    static let presets: [Double] = [1, 3, 5, 10, 15, 25]
    static let accent = srgb(0xff9f0a)

    /// 牆上時間（快照逐格：HOMEPLAY_CLOCK_T 凍結，見 ClockKit.wall）
    static var wallNow: Double { ClockKit.wall }

    /// 到點那一刻正開著的那組：「完成」畫面
    private struct Done { var label: String; var total: Double; var at: Double }
    private var done: Done?
    /// 上一幀看到的各組剩餘秒數（判斷是到點還是被取消）
    private var seen: [Int: Double] = [:]
    /// 剛開始的那組：刻度從 12 點順時針亮起
    private var revealID: Int?
    private var revealAt = 0.0

    func didOpen(now: Double) {
        adding = Shell.timers.isEmpty; selected = nil; done = nil
        seen = Dictionary(uniqueKeysWithValues: Shell.timers.timers.map { ($0.id, $0.left(Self.wallNow)) })
        // R15：打開時只看到錶盤（官方 timer.png 沒有任何控制）；點一下控制才浮出
        // 快照：--timers-chrome 把控制打開來拍；--timer-paused 讓這組暫停；--timer-done 直接是「完成」畫面
        let args = CommandLine.arguments
        chrome = HPComponents.Chrome(visible: args.contains("--timers-chrome"), idle: HPTokens.TimerFace.chromeIdle, now: CACurrentMediaTime(), name: "timers.chrome")
        if args.contains("--timer-paused"), let t = current { selected = t.id; Shell.timers.pause(t.id, now: Self.wallNow) }
        if args.contains("--timer-done") {
            done = Done(label: String(format: L("timer.minutes", "%d 分钟"), 15), total: 900, at: CACurrentMediaTime()); adding = false
        }
    }

    /// R15：錶盤上的控制（✕、＋、取消、暫停、其他計時器）平常收起來
    private var chrome = HPComponents.Chrome(visible: false, idle: HPTokens.TimerFace.chromeIdle, name: "timers.chrome")
    /// 正在看錶盤（不是「新计时器」那頁）
    private var onFace: Bool { done != nil || (!adding && current != nil) }
    var showsCloseButton: Bool { !onFace || chrome.visible || done != nil }
    /// 錶盤永遠黑底：外殼的時間會跟著淺色變黑字，所以錶盤上自己畫白字
    var showsClock: Bool { !onFace }

    // 2.0 r2：「新计时器」在已經有計時器時是子頁（‹ 回到大圈）
    private var onSubpage: Bool { adding && !Shell.timers.isEmpty && done == nil }
    var backSymbol: String { onSubpage ? "chevron.left" : "xmark" }
    func handleBack(now: Double) -> Bool {
        guard onSubpage else { return false }
        adding = false; return true
    }

    func tick(_ now: Double) -> Bool {
        let wall = Self.wallNow
        var dirty = HPComponents.needsFrame(now)
        if chrome.tick(CACurrentMediaTime()) { dirty = true }
        // 到點偵測：上一幀還剩不到 1.5 秒、這一幀帳裡沒了＝到點（被取消的剩很多）
        let ids = Set(Shell.timers.timers.map(\.id))
        for (id, left) in seen where !ids.contains(id) && left < 1.5 {
            let t = current?.id == id || selected == id || selected == nil
            if t, !adding { done = Done(label: lastLabels[id] ?? "", total: lastTotals[id] ?? 0, at: now); chrome.show(now); dirty = true }
        }
        seen = Dictionary(uniqueKeysWithValues: Shell.timers.timers.map { ($0.id, $0.left(wall)) })
        lastLabels = Dictionary(uniqueKeysWithValues: Shell.timers.timers.map { ($0.id, $0.label) })
        lastTotals = Dictionary(uniqueKeysWithValues: Shell.timers.timers.map { ($0.id, $0.total) })
        if let d = done {
            if now - d.at > 60 { done = nil; adding = Shell.timers.isEmpty; dirty = true }   // 沒人理：收掉
            else { if !ClockKit.reduceMotion { ClockKit.keepLive(0.2) }; dirty = true }       // 刻度呼吸
            return dirty
        }
        guard let t = current, !adding else { return dirty }
        // 刻度要多細才看得出在動：一根刻度 = total/60 秒，分成 48 階；短計時器才需要 60 fps
        let perTick = t.total / Double(HPTokens.TimerFace.ticks)
        let q = Int((t.total - t.left(wall)) / max(0.001, perTick) * 48)
        if q != lastQuantum { lastQuantum = q; dirty = true }
        if !t.paused, perTick / 48 < 1.0 / 6, !ClockKit.reduceMotion { ClockKit.keepLive(0.2) }
        if revealID == t.id, now - revealAt < 1.2 { ClockKit.keepLive(0.1); dirty = true }
        // 秒數跳動：每秒要畫一次（數字捲動自己會要 60 fps）
        let s = Int(t.left(wall).rounded(.up))
        if s != lastShownSecond { lastShownSecond = s; dirty = true }
        return dirty
    }
    private var lastShownSecond = -1
    private var lastLabels: [Int: String] = [:]
    private var lastTotals: [Int: Double] = [:]

    private var current: ShellTimer? {
        if let s = selected, let t = Shell.timers.timer(s) { return t }
        return Shell.timers.primary ?? Shell.timers.sorted.first
    }

    // MARK: 版面（1024 畫布）
    // 四角的控制都跟螢幕圓角同心：左下取消、右下暫停／繼續是 150 px 圓鈕；右上「＋」跟左上返回鈕一樣 90 px
    private static let cancelButton: CGRect = {
        let c = Screen.cornerCapsuleCenter(.bottomLeft, width: HPComponents.actionSize, height: HPComponents.actionSize); return HPComponents.actionRect(cx: c.x, cy: c.y)
    }()
    private static let runButton: CGRect = {
        let c = Screen.cornerCapsuleCenter(.bottomRight, width: HPComponents.actionSize, height: HPComponents.actionSize); return HPComponents.actionRect(cx: c.x, cy: c.y)
    }()
    private static let addButton: CGRect = {
        let b = HPTokens.backButton; return CGRect(x: 1024 - b.maxX, y: b.minY, width: b.width, height: b.height)
    }()
    private static func presetRect(_ i: Int) -> CGRect {
        let w: CGFloat = 260, h: CGFloat = 150, gap: CGFloat = 32
        let x0 = 512 - (3 * w + 2 * gap) / 2
        return CGRect(x: x0 + CGFloat(i % 3) * (w + gap), y: 300 + CGFloat(i / 3) * (h + gap), width: w, height: h)   // 標題底下
    }
    /// 底下其他幾組的小膠囊（最多兩個）
    private func chipRects(_ face: Face, _ others: [ShellTimer], now: Double) -> [(CGRect, ShellTimer, String)] {
        let font = AppUI.font(32, .semibold)
        var items = others.prefix(2).map { t -> (ShellTimer, String, CGFloat) in
            let s = "\(Face.clipped(t.label, font, 110)) \(timerClock(t.left(now)))"
            return (t, s, Typo.width(s, font) + 52 + (t.paused ? 34 : 0))
        }
        // 2.0 depth：三組以上：第三顆是「+N」，點了換到下一組（以前第四組以後點不到，暫停的那組就找不回來）
        if others.count > 2 { let s = "+\(others.count - 2)"; items.append((others[2], s, max(96, Typo.width(s, font) + 52))) }
        let gap: CGFloat = 20
        let total = items.reduce(0) { $0 + $1.2 } + gap * CGFloat(max(0, items.count - 1))
        var x = 512 - total / 2
        return items.map { t, s, w in
            defer { x += w + gap }
            return (CGRect(x: x, y: 870, width: w, height: 96), t, s)
        }
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        let wall = Self.wallNow
        if let d = done { renderDone(g, face, d, now: now); return }
        guard !adding, let t = current else { g.setFillColor(AppUI.bg.cgColor); g.fill(rect); renderPresets(g, face); return }
        typealias T = HPTokens.TimerFace
        // R15（官方 timer.png）：黑底、60 根刻度沿螢幕同心的圓角方形、中間大字剩餘時間＋全大寫「15 MIN」；沒有標題
        g.setFillColor(NSColor.black.cgColor); g.fill(rect)
        var lit = CGFloat(t.fraction(wall)) * CGFloat(T.ticks)
        if revealID == t.id, !ClockKit.reduceMotion {   // 剛開始：從 12 點順時針亮起（Spring 0.5，跟 Apple Watch 的計時器一樣先畫滿再倒數）
            let p = Spring.smooth.value(from: 0, to: 1, velocity: 0, t: CGFloat(now - revealAt)).x
            lit = min(lit, CGFloat(T.ticks) * p)
        }
        Self.tickRing(g, lit: lit, color: T.tint)
        let left = t.left(wall)
        let big = timerClock(left)
        let tf = FaceType.sf(big.count > 5 ? T.timeSize * 0.72 : T.timeSize, .medium, mono: false)
        // 靠右對齊在「00:00」寬的置中框裡（官方的位置；秒數變了右緣不動）
        let box = Typo.width(String(big.map { $0.isNumber ? "0" : $0 }), tf)
        // 2.0 P05：剩餘時間讓 VoiceOver 念；控制收著時它是按鈕（按下＝跟點一下一樣，浮出控制）
        HPAX.note(g, CGRect(x: 512 - box / 2 - 24, y: T.timeBaseline - tf.ascender, width: box + 48, height: tf.ascender + 24),
                  chrome.value(CACurrentMediaTime()) > 0.01 ? .text : .button, String(format: L("a11y.pair", "%1$@，%2$@"), big, t.label), shape: .rounded(40))
        ClockKit.roll(g, face, key: "timers.big", text: big, font: tf, x: 512 + box / 2, baseline: T.timeBaseline, align: .right,
                      color: .white, down: true, prior: timerClock(left + 1), now: now)
        let lf = FaceType.sf(T.labelSize, .semibold, mono: false)
        let label = t.paused ? L("timer.paused", "已暂停").uppercased(with: Locale.current) : t.label.uppercased(with: Locale.current)
        let la = CGFloat(Anim.track("timers.pausedLabel", to: t.paused ? 1 : 0, spring: AppMotion.appleSmooth))
        face.drawCentered(g, Face.clipped(label, lf, 640), font: lf, y: T.labelBaseline, color: T.tint.withAlphaComponent(1 - 0.35 * la))

        // 控制：點一下才浮出
        let k = chrome.value(CACurrentMediaTime())
        guard k > 0.01 else { return }
        let others = Shell.timers.sorted.filter { $0.id != t.id }
        let chips = chipRects(face, others, now: wall)
        maskTicks(g, [HPTokens.backButton, Self.addButton, Self.cancelButton, Self.runButton], k, capsules: chips.map(\.0))
        glassCircle(g, face, Self.addButton, symbol: "plus", presence: k)
        HPComponents.actionButton(g, face, Self.cancelButton, symbol: "xmark", role: .glass, presence: k)
        HPAX.note(g, Self.cancelButton, .button, L("timer.cancel", "取消计时器"), shape: .circle)
        runButton(g, face, paused: t.paused, presence: k)
        for (r, o, s) in chips {
            // 2.0 depth：VoiceOver——點了是換到那一組；名字當標籤，剩餘時間（與暫停）當值
            let left = timerClock(o.left(wall))
            HPAX.note(g, r, .button, String(format: L("a11y.timer.switch", "切换到「%@」"), o.label.isEmpty ? left : o.label),
                      value: o.paused ? String(format: L("a11y.pair", "%1$@，%2$@"), left, L("timer.paused", "已暂停")) : left)
            HPGlass.addCapsule(r, interactive: true, presence: k) { c in
                var x = r.minX + 26
                if o.paused, !s.hasPrefix("+") {
                    face.drawSymbol(c, "pause.fill", in: CGRect(x: x, y: r.midY - 13, width: 26, height: 26), color: NSColor.white.withAlphaComponent(0.7 * k), weight: .semibold)
                    x += 34
                }
                face.drawLeft(c, s, font: AppUI.font(32, .semibold), x: x, y: r.midY + 11, color: NSColor.white.withAlphaComponent(k))
            }
        }
    }

    /// 60 根刻度（官方 timer.png）：12 點起順時針，前 lit 根橘、其餘暗棕；正在消失的那一根照小數部分淡掉（每幀都在走）
    static func tickRing(_ g: CGContext, lit: CGFloat, color: NSColor, pulse: CGFloat? = nil) {
        typealias T = HPTokens.TimerFace
        let n = T.ticks
        let full = Int(floor(lit)), frac = lit - CGFloat(full)
        let dim = color.withAlphaComponent(T.elapsedAlpha)
        g.saveGState()
        g.setLineCap(.round); g.setLineWidth(T.tickWidth)
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            let r0 = HPComponents.rayToRoundedSquare(a, inset: T.outerInset, radius: T.outerRadius)
            let r1 = HPComponents.rayToRoundedSquare(a, inset: T.innerInset, radius: T.innerRadius)
            let d = CGPoint(x: sin(a), y: -cos(a))
            var c: NSColor
            if let pulse { c = dim.blended(withFraction: pulse, of: color) ?? color }
            else if i < full { c = color }
            else if i == full && frac > 0.001 { c = dim.blended(withFraction: frac, of: color) ?? color }
            else { c = dim }
            g.setStrokeColor(c.cgColor)
            g.move(to: CGPoint(x: 512 + d.x * r0, y: 512 + d.y * r0))
            g.addLine(to: CGPoint(x: 512 + d.x * r1, y: 512 + d.y * r1))
            g.strokePath()
        }
        g.restoreGState()
    }

    /// 控制浮出時，圓鈕底下（含一圈 14 的留白）的刻度跟著淡掉，什麼都不疊在刻度上（黑底，用黑色蓋掉）
    private func maskTicks(_ g: CGContext, _ rects: [CGRect], _ k: CGFloat, capsules: [CGRect] = []) {
        g.saveGState()
        for r in rects { g.addEllipse(in: r.insetBy(dx: -14, dy: -14)) }
        for r in capsules { let e = r.insetBy(dx: -14, dy: -14); g.addPath(CGPath(roundedRect: e, cornerWidth: e.height / 2, cornerHeight: e.height / 2, transform: nil)) }
        g.setFillColor(NSColor.black.withAlphaComponent(k).cgColor); g.fillPath()
        g.restoreGState()
    }

    private func glassCircle(_ g: CGContext, _ face: Face, _ r: CGRect, symbol: String, presence k: CGFloat) {
        HPAX.note(g, r, .button, HPAX.symbolLabel(symbol, rect: r) ?? symbol, shape: .circle)
        let s = 0.96 + 0.04 * k, rr = Press.scale(r) * s == 1 ? r : HPComponents.scaled(r, Press.scale(r) * s)
        HPGlass.addCapsule(rr, interactive: true, presence: k) { [weak face] c in
            let z = r.width * 0.38
            face?.drawSymbol(c, symbol, in: CGRect(x: r.midX - z / 2, y: r.midY - z / 2, width: z, height: z), color: HPGlass.ink.withAlphaComponent(k), weight: .semibold)
        }
    }

    /// 暫停（橘）↔ 繼續（綠）：同一顆玻璃，彈簧換色；舊符號縮小淡出、新符號從 0.6 彈到 1（SF Symbols 的 replace 效果）
    private func runButton(_ g: CGContext, _ face: Face, paused: Bool, presence k: CGFloat) {
        let r = Self.runButton
        let m = CGFloat(Anim.track("timers.run", to: paused ? 1 : 0, spring: AppMotion.interactive))
        let tint = HPTokens.orange.blended(withFraction: max(0, min(1, m)), of: HPTokens.green) ?? HPTokens.orange
        HPAX.note(g, r, .button, paused ? L("timer.resume", "继续") : L("timer.pause", "暂停"), shape: .circle)
        let s = (0.96 + 0.04 * k) * Press.scale(r), rr = s == 1 ? r : HPComponents.scaled(r, s)
        HPGlass.addCapsule(rr, tint: Press.brighten(tint, r), interactive: true, presence: k) { [weak face] c in
            for (sym, w) in [("pause.fill", 1 - m), ("play.fill", m)] where w > 0.01 {
                let z = r.width * 0.36 * (0.6 + 0.4 * min(1, w * 1.1))
                face?.drawSymbol(c, sym, in: CGRect(x: r.midX - z / 2, y: r.midY - z / 2, width: z, height: z), color: NSColor.white.withAlphaComponent(k * w), weight: .semibold)
            }
        }
    }

    /// 到點：整圈刻度橘色呼吸（1 Hz）、0:00、標籤；左下「重複」、右下「停止」
    private func renderDone(_ g: CGContext, _ face: Face, _ d: Done, now: Double) {
        typealias T = HPTokens.TimerFace
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let e = now - d.at
        let pulse: CGFloat = ClockKit.reduceMotion ? 1 : CGFloat(0.55 + 0.45 * cos(e * 2 * .pi))
        Self.tickRing(g, lit: 0, color: T.tint, pulse: pulse)
        let tf = FaceType.sf(T.timeSize, .medium, mono: false), big = timerClock(0)
        face.drawCentered(g, big, font: tf, y: T.timeBaseline, color: .white)
        let lf = FaceType.sf(T.labelSize, .semibold, mono: false)
        let label = (d.label.isEmpty ? L("timer.done", "计时完成") : d.label).uppercased(with: Locale.current)
        face.drawCentered(g, Face.clipped(label, lf, 640), font: lf, y: T.labelBaseline, color: T.tint)
        HPAX.note(g, CGRect(x: 312, y: T.timeBaseline - tf.ascender, width: 400, height: tf.ascender + 24), .text, L("timer.done", "计时完成"), shape: .rounded(40))
        // 圓鈕照 materialize 長出來（到點那一刻）
        let k = CGFloat(min(1, max(0, Spring.smooth.value(from: 0, to: 1, velocity: 0, t: CGFloat(e)).x)))
        maskTicks(g, [HPTokens.backButton, Self.cancelButton, Self.runButton], k)
        HPComponents.actionButton(g, face, Self.cancelButton, symbol: "arrow.counterclockwise", role: .glass, presence: k)
        HPAX.note(g, Self.cancelButton, .button, L("timer.repeat", "重复"), shape: .circle)
        HPComponents.actionButton(g, face, Self.runButton, symbol: "xmark", role: .stop, presence: k)
        if k < 1 { ClockKit.keepLive(0.1) }
    }

    private func renderPresets(_ g: CGContext, _ face: Face) {
        AppUI.title(g, face, onSubpage ? L("timers.new", "新计时器") : title)
        for (i, m) in Self.presets.enumerated() {
            let r = Self.presetRect(i)
            let k = Press.scale(r)
            AppUI.group(g, k == 1 ? r : HPComponents.scaled(r, k), radius: 44)
            HPAX.note(g, r, .button, String(format: L("timer.minutes", "%d 分钟"), Int(m)), shape: .rounded(44))   // 2.0 depth：VoiceOver
            // 大數字＋單位（像 iOS 時鐘「最近使用」的圓：數字大、單位小）
            let n = String(Int(m)), unit = String(format: L("timer.minutes", "%d 分钟"), Int(m)).replacingOccurrences(of: n, with: "").trimmingCharacters(in: .whitespaces)
            let nf = FaceType.sf(72, .regular), uf = AppUI.font(30, .semibold)
            AppUI.center(face, g, n, nf, cx: r.midX, y: r.midY + 14, AppUI.orange)
            AppUI.center(face, g, unit, uf, cx: r.midX, y: r.midY + 56, AppUI.secondary)
        }
    }

    // MARK: 點

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        let wall = Self.wallNow
        if let d = done {
            if AppUI.hit(Self.cancelButton, p, pad: 10) {   // 重複：同樣的時間、同樣的名字再來一次
                done = nil
                selected = Shell.addTimer(minutes: max(1, d.total) / 60, label: d.label, face: face)
                revealID = selected; revealAt = now
                return true
            }
            if AppUI.hit(Self.runButton, p, pad: 10) { done = nil; adding = Shell.timers.isEmpty; selected = nil; return true }
            return false
        }
        if adding || current == nil {
            for (i, m) in Self.presets.enumerated() where Self.presetRect(i).insetBy(dx: -8, dy: -8).contains(p) {
                selected = Shell.addTimer(minutes: m, label: String(format: L("timer.minutes", "%d 分钟"), Int(m)), face: face)
                adding = false
                revealID = selected; revealAt = now
                ClockKit.forget("timers.big")
                chrome.show(CACurrentMediaTime())   // 剛開始：控制先亮著，閒置再收
                return true
            }
            return false
        }
        guard let t = current else { return false }
        // 控制收著：這一下只叫出控制
        if chrome.touch(CACurrentMediaTime()) { return true }
        if AppUI.hit(Self.addButton, p, pad: 10) { adding = true; return true }
        if AppUI.hit(Self.cancelButton, p, pad: 10) {
            Shell.removeTimer(t.id, face: face); selected = nil
            ClockKit.forget("timers.big")
            if Shell.timers.isEmpty { adding = true }
            return true
        }
        if AppUI.hit(Self.runButton, p, pad: 10) {
            // 2.0 depth：釘住這一個——沒選過時 current 是「最快到點的那個在跑的」，暫停之後會跳到別的計時器（鈕也變回橘色的暫停）
            selected = t.id
            if t.paused { Shell.timers.resume(t.id, now: wall) } else { Shell.timers.pause(t.id, now: wall) }
            Shell.reconcileTimers(face, now: CACurrentMediaTime()); face.forceDirty = true
            return true
        }
        let others = Shell.timers.sorted.filter { $0.id != t.id }
        for (r, o, _) in chipRects(face, others, now: wall) where r.insetBy(dx: -6, dy: -10).contains(p) {
            selected = o.id; ClockKit.forget("timers.big"); return true
        }
        return false
    }

    func liveActivity(face: Face, now: Double) -> LiveActivity? {
        // R15：計時器自己開著的時候，頂端不再重複一份（iOS：前景 App 的 Live Activity 不顯示）
        if Shell.currentApp === self { return nil }
        // 番茄鐘在跑：錶面計時器歸它
        if face.pomodoro.active, let end = face.timerEnd {
            let left = max(0, end - now)
            return LiveActivity(kind: .timer, title: face.timerLabel, detail: timerClock(left), accent: Self.accent,
                                progress: left / max(1, face.timerTotal), appID: id)
        }
        guard let t = Shell.timers.primary else { return nil }
        if RecipesApp.shared.hidesTimerActivity(t.id) { return nil }   // 2.0 promo：食譜的計時器正在全螢幕看，頂端不重複
        let wall = Self.wallNow
        return LiveActivity(kind: .timer, title: t.label, detail: timerClock(t.left(wall)), accent: Self.accent,
                            progress: t.fraction(wall), appID: id, link: String(t.id))   // 2.0 P03：點了開到這一組
    }
}
