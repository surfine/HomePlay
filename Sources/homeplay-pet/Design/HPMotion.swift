// HPDS v1：Motion——彈簧、打斷、跟手、投射、rubber band、凍結快照（原 Design/HPMotion.swift＋RealUI 的 Press／Anim／PageTransition／AppMotion；
// 舊名 Motion 留成 typealias）。規格與轉場參數表見 Design/README.md。
//
// 2.0 逼真化第二輪 R14：外殼所有動畫的共用彈簧（照 SwiftUI 的 Spring：damping ratio＋response）。
//
// - 一律用彈簧解析解，不用固定時長的曲線；可以中途打斷：從畫面上的當下值與速度接著走（MotionValue.retarget）。
// - 影片量到的「看起來停了」時長換成 response：臨界阻尼的彈簧走到剩 5% 要 ≈ 0.76 × response（ω·t ≈ 4.74），
//   所以 response = 量到的時長 ÷ 0.76（Spring.settling；肉眼大多在剩 5% 以內就覺得結束）。
// - 跟手：拖曳 1:1、放手把速度交給彈簧；落點的投射公式出自 WWDC18〈Designing Fluid Interfaces〉投影片上的程式碼，
//   0.998 是 UIScrollView.DecelerationRate.normal；rubber band 的常數 0.55 是業界對 UIScrollView 的逆向值（不是 Apple 公布的規格）。
// - 「減少動態效果」：位移與縮放換成 0.2 s 交叉淡化（HPMotion.reduceMotion）。
// - 驗收：HOMEPLAY_ANIM="名字:秒[,名字:秒]" 把那個動畫凍結在第 t 秒（--screen-png 出逐格），名字見各處的 MotionValue(name:)。

import AppKit

struct Spring: Equatable {
    var damping: CGFloat
    var response: CGFloat
    // Apple 的預設（MacOSX27.0.sdk SwiftUICore.swiftinterface：.smooth／.snappy／.bouncy 的 duration＝response 都是 0.5，
    // bounce＝1 − damping；interactiveSpring 預設 response 0.15、dampingFraction 0.86）
    static let smooth = Spring(damping: 1.0, response: 0.5)
    static let snappy = Spring(damping: 0.85, response: 0.5)
    static let bouncy = Spring(damping: 0.7, response: 0.5)
    static let interactive = Spring(damping: 0.86, response: 0.15)
    /// 我們自己的：按下、切換、小元件（臨界阻尼、短）
    static let quick = Spring(damping: 1.0, response: 0.2)

    /// 臨界阻尼、走到 95% 的時間＝d 秒的彈簧（把影片量到的時長換成 response）
    static func settling(_ d: CGFloat, damping: CGFloat = 1) -> Spring { Spring(damping: damping, response: d / 0.76) }

    /// 解析解：給起點、終點、初速、經過時間 → 目前值與速度
    func value(from: CGFloat, to: CGFloat, velocity: CGFloat, t: CGFloat) -> (x: CGFloat, v: CGFloat) {
        let t = max(0, t)
        let w0 = 2 * .pi / max(0.001, response), z = max(0, damping)
        let x0 = from - to, v0 = velocity
        if z >= 1 - 1e-4 && z <= 1 + 1e-4 {
            // 臨界阻尼：x(t) = (x0 + (v0 + ω x0) t) e^{-ωt}
            let b = v0 + w0 * x0, e = exp(-w0 * t)
            let x = (x0 + b * t) * e
            let v = (b - w0 * (x0 + b * t)) * e
            return (to + x, v)
        } else if z < 1 {
            let wd = w0 * sqrt(1 - z * z), e = exp(-z * w0 * t)
            let a = x0, b = (v0 + z * w0 * x0) / wd
            let c = cos(wd * t), s = sin(wd * t)
            let x = e * (a * c + b * s)
            let v = e * ((b * wd - z * w0 * a) * c - (a * wd + z * w0 * b) * s)
            return (to + x, v)
        } else {
            // 過阻尼（外殼沒用到，給完整）
            let r = w0 * sqrt(z * z - 1), r1 = -z * w0 + r, r2 = -z * w0 - r
            let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
            let e1 = exp(r1 * t), e2 = exp(r2 * t)
            return (to + c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
        }
    }

    /// 差不多停了（剩下的距離與速度都小於 eps，相對於整段距離）
    func settled(from: CGFloat, to: CGFloat, velocity: CGFloat, t: CGFloat, eps: CGFloat = 0.002) -> Bool {
        let (x, v) = value(from: from, to: to, velocity: velocity, t: t)
        let span = max(abs(from - to), 1e-6)
        return abs(x - to) / span < eps && abs(v) / span < eps * 10
    }
}

/// 一個會被打斷的動畫量：目前在 from→to 的彈簧上走；retarget 從畫面上的當下值與速度接著走
struct MotionValue {
    var name: String
    var spring: Spring
    var from: CGFloat
    var to: CGFloat
    var velocity: CGFloat = 0
    var start: Double
    /// 晚多久才開始動（秒）：例如 App 內容等放大快完才淡入
    var delay: Double = 0

    init(_ name: String, spring: Spring, from: CGFloat, to: CGFloat, velocity: CGFloat = 0, now: Double, delay: Double = 0) {
        self.name = name; self.spring = spring; self.from = from; self.to = to; self.velocity = velocity; self.start = now; self.delay = delay
    }

    /// 經過的時間（快照：HOMEPLAY_ANIM 凍結整段動畫的時鐘；delay 照樣扣）
    func elapsed(_ now: Double) -> CGFloat { CGFloat((HPMotion.frozen(name) ?? (now - start)) - delay) }
    func sample(_ now: Double) -> (x: CGFloat, v: CGFloat) {
        // 動效包：快照時 HOMEPLAY_REVERSE=秒＝凍結的時鐘走到那一刻就反向（跟真的 retarget 同一個算法：從當下值與速度回起點）
        if let r = HPMotion.reverseAt, let fz = HPMotion.frozen(name), fz > r {
            var m = self; m.start = 0
            HPMotion.withoutFreeze { m.retargetFrozen(at: r) }
            return m.spring.value(from: m.from, to: m.to, velocity: m.velocity, t: CGFloat(fz - r))
        }
        if HPMotion.reduceMotion {   // 減少動態效果：0.2 s 線性交叉，不走彈簧
            let k = max(0, min(1, elapsed(now) / 0.2))
            return (from + (to - from) * k, 0)
        }
        return spring.value(from: from, to: to, velocity: velocity, t: elapsed(now))
    }
    /// 快照的反向：在凍結時鐘第 r 秒（扣掉 delay 之前）照 retarget 換回起點
    private mutating func retargetFrozen(at r: Double) {
        let back = from
        retarget(back, now: r)   // start＝0：凍結時鐘的 r 就是 now（還在 delay 裡的就停在起點）
    }
    func value(_ now: Double) -> CGFloat { sample(now).x }
    func done(_ now: Double) -> Bool {
        if HPMotion.frozen(name) != nil { return false }
        if HPMotion.reduceMotion { return elapsed(now) >= 0.2 }
        return spring.settled(from: from, to: to, velocity: velocity, t: elapsed(now))
    }
    /// 換目標：從當下的值與速度出發（不跳回起點、不等它播完）
    mutating func retarget(_ to: CGFloat, now: Double, spring: Spring? = nil, velocity: CGFloat? = nil) {
        let s = sample(now)
        from = s.x; self.velocity = velocity ?? s.v; self.to = to; start = now; delay = 0
        if let spring { self.spring = spring }
    }
    /// 跟手：直接指定值（速度由呼叫端算），之後 retarget 會從這裡接著走
    mutating func set(_ x: CGFloat, velocity v: CGFloat, now: Double) {
        from = x; to = x; velocity = v; start = now
    }
}

typealias Motion = HPMotion

enum HPMotion {
    /// 系統「減少動態效果」
    static var reduceMotion: Bool { forceReduce ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    nonisolated(unsafe) static var forceReduce: Bool? = ProcessInfo.processInfo.environment["HOMEPLAY_REDUCE_MOTION"].map { $0 == "1" }

    /// HOMEPLAY_ANIM="appopen:0.1,cliodrop:0.2"（--frames 逐格時每格加 frameOffset）
    static var freezes: [String: Double] { frameOffset == 0 ? baseFreezes : baseFreezes.mapValues { $0 + frameOffset } }
    /// 動效包：--frames N 逐格出圖時，凍結的時鐘往後推幾秒（HPFrames 設）
    nonisolated(unsafe) static var frameOffset: Double = 0
    nonisolated(unsafe) private static var freezeOff = false
    /// HOMEPLAY_REVERSE=秒：打斷測試——凍結的動畫在這一刻反向（MotionValue.sample）
    static let reverseAt: Double? = ProcessInfo.processInfo.environment["HOMEPLAY_REVERSE"].flatMap(Double.init)
    static func withoutFreeze(_ body: () -> Void) { freezeOff = true; body(); freezeOff = false }
    static let baseFreezes: [String: Double] = {
        var out: [String: Double] = [:]
        for part in (ProcessInfo.processInfo.environment["HOMEPLAY_ANIM"] ?? "").split(separator: ",") {
            let kv = part.split(separator: ":")
            if kv.count == 2, let t = Double(kv[1]) { out[String(kv[0])] = t }
        }
        return out
    }()
    static func frozen(_ name: String) -> Double? { freezeOff ? nil : baseFreezes[name].map { $0 + frameOffset } }

    /// Apple 的投射：放手速度 v（每秒）→ 慣性還會再走多遠（UIScrollView.DecelerationRate.normal＝0.998）
    static func project(_ v: CGFloat, rate: CGFloat = 0.998) -> CGFloat { v / 1000 * rate / (1 - rate) }
    /// 拉過頭的阻力：x 超出的量、d 可拉的尺寸
    static func rubberBand(_ x: CGFloat, _ d: CGFloat, c: CGFloat = 0.55) -> CGFloat {
        guard d > 0 else { return 0 }
        return x * d * c / (d + c * abs(x))
    }
    /// 放手：有動量（> 約 300 px/s）時才允許過衝（damping 0.8，Designing Fluid Interfaces 的建議），否則臨界阻尼
    static func release(velocity pxPerSec: CGFloat) -> Spring { Spring(damping: abs(pxPerSec) > 300 ? 0.8 : 1, response: 0.5) }
    /// 減少動態效果時的交叉淡化長度（秒）
    static let reduceFade = 0.2
    /// 投射落點最近的停點
    static func nearest(_ x: CGFloat, velocity v: CGFloat, stops: [CGFloat]) -> CGFloat {
        let p = x + project(v)
        return stops.min { abs($0 - p) < abs($1 - p) } ?? x
    }
}

// MARK: - 自檢

enum MotionSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let s = Spring.smooth
        let a = s.value(from: 0, to: 1, velocity: 0, t: 0)
        check(abs(a.x) < 1e-9 && abs(a.v) < 1e-9, "彈簧：t=0 在起點、速度 0")
        let b = s.value(from: 0, to: 1, velocity: 0, t: 0.76 * s.response)
        check(abs(b.x - 0.95) < 0.01, "彈簧：臨界阻尼 0.76×response 走到 95%")
        var over = false, x: CGFloat = 0
        for i in 0...200 { x = s.value(from: 0, to: 1, velocity: 0, t: CGFloat(i) / 100).x; if x > 1.0001 { over = true } }
        check(!over && abs(x - 1) < 1e-3, "彈簧：臨界阻尼不回彈")
        var peak: CGFloat = 0
        for i in 0...200 { peak = max(peak, Spring.snappy.value(from: 0, to: 1, velocity: 0, t: CGFloat(i) / 100).x) }
        check(peak > 1.001 && peak < 1.1, "彈簧：0.85 有一點點回彈")
        // 速度＝位置的導數
        let h: CGFloat = 1e-4, t: CGFloat = 0.13
        for sp in [Spring.smooth, Spring.snappy] {
            let p0 = sp.value(from: 0.2, to: 1, velocity: 3, t: t).x, p1 = sp.value(from: 0.2, to: 1, velocity: 3, t: t + h).x
            check(abs((p1 - p0) / h - sp.value(from: 0.2, to: 1, velocity: 3, t: t).v) < 0.01, "彈簧：速度是位置的導數（damping \(sp.damping)）")
        }
        // 打斷：從當下的值與速度接著走，不跳
        var m = MotionValue("test", spring: .smooth, from: 0, to: 1, now: 10)
        let mid = m.sample(10.08)
        m.retarget(0, now: 10.08)
        check(abs(m.value(10.08) - mid.x) < 1e-9 && abs(m.velocity - mid.v) < 1e-9, "彈簧：打斷時從當下值與速度接著走")
        check(abs(HPMotion.project(1000) - 499) < 0.5, "投射：1000/s → 499")
        check(abs(HPMotion.rubberBand(100, 300) - 100 * 300 * 0.55 / (300 + 55)) < 1e-6, "rubber band 公式")
        check(HPMotion.nearest(0.3, velocity: 1, stops: [0, 1]) == 1 && HPMotion.nearest(0.3, velocity: -0.2, stops: [0, 1]) == 0, "投射：挑最近的停點")
        check(abs(Spring.settling(0.17).response - 0.2237) < 0.001, "影片時長換成 response（÷0.76）")
        MotionTableSelfTest.run(check)   // 動效包：參數表、打斷、數字、清單、滴落、分頁（Design/HPMotionTable.swift）
    }
}

// MARK: - 按下（R14 §5：mouse down 那一刻就變亮＋放大 1.08，放開才觸發）

/// 讀外殼的 ShellInput.down（按著、還沒拖走的那一點）；放開後用同一條彈簧縮回 1
enum Press {
    nonisolated(unsafe) private(set) static var point: CGPoint?
    nonisolated(unsafe) private static var downAt = 0.0
    nonisolated(unsafe) private static var upAt = -10.0
    nonisolated(unsafe) private static var last: CGPoint?
    /// 影片 v2 00:38.00 歌詞鈕、v1 00:26.73 Start Cooking：按下 1 格內（< 42 ms）就變亮 → Apple 的 interactiveSpring
    /// （damping 0.86、response 0.15：一格後 ≈ 0.6，放開帶一點回彈）
    static var spring: Spring { AppMotion.interactive }
    static let maxScale: CGFloat = 1.08

    private static var now: Double { CACurrentMediaTime() }
    private static var current: CGPoint? {
        if let v = Anim.frozen("press") { _ = v; return pressDemo }
        guard let d = ShellInput.down, d.kind == .tap, !ShellInput.claimed, let uv = d.uv else { return nil }
        return CGPoint(x: uv.x * 1024, y: uv.y * 1024)
    }
    /// 快照用：HOMEPLAY_ANIM=press:t 時假裝按在這一點（HOMEPLAY_PRESS=x,y）
    private static var pressDemo: CGPoint? {
        guard let s = ProcessInfo.processInfo.environment["HOMEPLAY_PRESS"] else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? CGPoint(x: p[0], y: p[1]) : nil
    }
    /// 有變化或還在動回 true
    @discardableResult
    static func update() -> Bool {
        let c = current
        if c != last {
            if let c { point = c; downAt = now } else { upAt = now }
            last = c
            return true
        }
        let t = now
        return t - downAt < 0.6 || t - upAt < 0.6
    }
    /// 0…1：這個框被按下的程度
    static func amount(_ r: CGRect) -> CGFloat {
        guard let p = point, r.insetBy(dx: -8, dy: -8).contains(p) else { return 0 }
        if let t = Anim.frozen("press") { return spring.value(from: 0, to: 1, velocity: 0, t: CGFloat(t)).x }
        if last != nil { return min(1, spring.value(from: 0, to: 1, velocity: 0, t: CGFloat(now - downAt)).x) }
        // 放開：從放開那一刻的值縮回 0
        let held = CGFloat(max(0, upAt - downAt))
        let at = spring.value(from: 0, to: 1, velocity: 0, t: held)
        return max(0, spring.value(from: at.x, to: 0, velocity: at.v, t: CGFloat(now - upAt)).x)
    }
    static func scale(_ r: CGRect) -> CGFloat {
        if AppMotion.reduceMotion { return 1 }
        let a = amount(r); return a < 0.001 ? 1 : 1 + (maxScale - 1) * a
    }
    /// 染色玻璃按下變亮
    static func brighten(_ c: NSColor, _ r: CGRect) -> NSColor {
        let a = amount(r); guard a > 0.001 else { return c }
        return c.blended(withFraction: 0.22 * a, of: .white) ?? c
    }
}

// MARK: - 彈簧動畫的狀態（可中途打斷）

/// 一個會動的值：retarget 時從畫面上的當下值與速度接著走（R14 §2）
struct Anim {
    var from: CGFloat
    var to: CGFloat
    var velocity: CGFloat = 0
    var start: Double
    var spring: Spring
    var name: String? = nil

    init(_ value: CGFloat, spring: Spring = AppMotion.appleSmooth, name: String? = nil) {
        from = value; to = value; start = 0; self.spring = spring; self.name = name
    }
    func elapsed(_ now: Double) -> CGFloat {
        if let name, let t = Anim.frozen(name) { return CGFloat(t) }
        return CGFloat(now - start)
    }
    func state(_ now: Double) -> (x: CGFloat, v: CGFloat) {
        if from == to && velocity == 0 { return (to, 0) }
        return spring.value(from: from, to: to, velocity: velocity, t: elapsed(now))
    }
    func value(_ now: Double) -> CGFloat { state(now).x }
    func done(_ now: Double) -> Bool {
        let s = state(now); return abs(s.x - to) < 0.0005 * max(1, abs(from - to)) && abs(s.v) < 0.01 * max(1, abs(from - to))
    }
    /// 換目標：從現在的值與速度出發
    mutating func retarget(_ target: CGFloat, now: Double, spring s: Spring? = nil, velocity v: CGFloat? = nil) {
        let st = state(now)
        from = st.x; velocity = v ?? st.v; to = target; start = now
        if let s { spring = s }
    }
    /// 直接跳到某個值（拖曳中 1:1 跟手）
    mutating func set(_ x: CGFloat, now: Double) { from = x; to = x; velocity = 0; start = now }

    // 共用的小元件動畫（分段控制、底線、開關）：以 key 記住
    nonisolated(unsafe) private static var tracks: [String: Anim] = [:]
    nonisolated(unsafe) private static var activeUntil = 0.0
    static var active: Bool { CACurrentMediaTime() < activeUntil }
    /// 小元件：值變了就用彈簧滑過去；第一次出現直接到位
    static func track(_ key: String, to target: CGFloat, spring: Spring = AppMotion.interactive) -> CGFloat {
        let now = CACurrentMediaTime()
        guard var a = tracks[key] else { tracks[key] = Anim(target, spring: spring); return target }
        if a.to != target { a.retarget(target, now: now, spring: spring); tracks[key] = a }
        if AppMotion.reduceMotion { return target }
        if !a.done(now) { activeUntil = max(activeUntil, now + 0.05) }
        return a.value(now)
    }
    /// 讓外面也能說「我還在動」
    static func keepAlive(_ seconds: Double = 0.05) { activeUntil = max(activeUntil, CACurrentMediaTime() + seconds) }

    /// HOMEPLAY_ANIM=name:t（可用逗號放好幾個）：凍結在第 t 秒
    static func frozen(_ name: String) -> Double? { HPMotion.frozen(name) }
}

/// 換頁過場（R11／R14）：開始時拿外殼上一幀畫好的整面（face.lastFrame）當「舊畫面」，App 照常畫新的一頁，
/// 再依種類把舊畫面疊上去（模糊交叉淡化）或把新的一頁平移進來（右滑入）。減少動態效果時一律 0.2 s 交叉淡化。
struct PageTransition {
    enum Kind { case blurFade, slideFromRight, slideFromLeft }
    var kind: Kind
    var start: Double
    var spring: Spring
    var old: CGImage?
    var oldBlur: CGImage?
    var name: String

    init(_ kind: Kind, face: Face, now: Double, spring: Spring, name: String) {
        self.kind = AppMotion.reduceMotion ? .blurFade : kind
        self.start = now
        self.spring = AppMotion.reduceMotion ? AppMotion.critical(settle: AppMotion.reduceFade) : spring
        self.name = name
        old = face.lastFrame
        if self.kind == .blurFade, let o = old { oldBlur = MediaUI.blurred(o, sigma: 10, side: 256) }
    }
    func elapsed(_ now: Double) -> CGFloat { CGFloat(Anim.frozen(name) ?? (now - start)) }
    /// 0→1；完成回 nil
    func progress(_ now: Double) -> CGFloat? {
        let t = elapsed(now)
        let x = spring.value(from: 0, to: 1, velocity: 0, t: t).x
        if Anim.frozen(name) == nil, x > 0.998 || t > 1.5 { return nil }
        Anim.keepAlive()
        return min(1, max(0, x))
    }
    /// 平移種類：新頁要往右（或左）偏多少
    func offset(_ now: Double) -> CGFloat {
        guard let p = progress(now) else { return 0 }
        switch kind {
        case .slideFromRight: return (1 - p) * 1024
        case .slideFromLeft: return -(1 - p) * 1024
        case .blurFade: return 0
        }
    }
    /// 畫在新頁之前：平移時舊畫面墊在底下
    func drawUnder(_ g: CGContext, _ face: Face, _ now: Double) {
        guard kind != .blurFade, progress(now) != nil, let old else { return }
        face.drawUpright(g, old, in: MediaUI.full)
    }
    /// 畫在新頁之後：模糊交叉淡化時舊畫面（越來越糊、越來越淡）疊在上面
    func drawOver(_ g: CGContext, _ face: Face, _ now: Double) {
        guard kind == .blurFade, let p = progress(now), let old else { return }
        g.saveGState()
        g.addPath(Screen.path()); g.clip()
        g.setAlpha((1 - p) * (1 - p)); face.drawUpright(g, old, in: MediaUI.full)
        if let b = oldBlur { g.setAlpha((1 - p) * p * 1.6); face.drawUpright(g, b, in: MediaUI.full) }
        g.restoreGState()
    }
}

/// App 包的彈簧表（舊名，第二輪 App 包用）：數值全部轉到 HPMotion／Spring，新程式直接用那邊
enum AppMotion {
    /// 影片量到「看起來結束」的時間 → 臨界阻尼彈簧的 response（chan-notes §3.2：到剩 5% 約 0.76 r，所以 response ≈ 時間 ÷ 0.76）
    static func critical(settle: Double) -> Spring { Spring.settling(CGFloat(settle)) }
    /// Apple 的預設（MacOSX27.0.sdk SwiftUICore.swiftinterface）：.smooth＝(1.0, 0.5)、.snappy＝(0.85, 0.5)、interactiveSpring＝(0.86, 0.15)
    static let appleSmooth = Spring.smooth
    static let appleSnappy = Spring.snappy
    static let interactive = Spring.interactive
    /// 放手：有動量（> 約 300 px/s）時才允許過衝（damping 0.8，Designing Fluid Interfaces 的建議），否則臨界阻尼
    static func release(velocity pxPerSec: CGFloat) -> Spring { HPMotion.release(velocity: pxPerSec) }
    /// 系統「減少動態效果」（App 包的版本：系統設定或 HOMEPLAY_REDUCE_MOTION=1 任一個開就算；外殼的 HPMotion.reduceMotion 讓環境變數可以強制關）
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["HOMEPLAY_REDUCE_MOTION"] == "1" }
    /// 減少動態效果時的交叉淡化長度
    static let reduceFade = HPMotion.reduceFade
    static var frozen: [String: Double] { HPMotion.freezes }
    static func project(_ velocity: CGFloat, rate: CGFloat = 0.998) -> CGFloat { HPMotion.project(velocity, rate: rate) }
    static func rubberBand(_ x: CGFloat, _ d: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        return (x * d * c) / (d + c * abs(x))
    }
}
