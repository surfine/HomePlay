// 錶面上的圓角一律跟機身螢幕同心。
//
// 機身螢幕是 Apple 那種連續曲率的角（squircle），量自 apple-homeview.usdz 顯示面網格：45° 方向的單軸內縮＝寬度的 3.98%
// （CornerFit.bodyDiag）。iOS 連續圓角在 45° 的單軸內縮是 0.29438 r，所以 r ≈ 0.135 W＝1024 畫布上約 138 單位。
// 規則（同 iOS 小工具、HomeView 官方錶面）：
// - 靠近螢幕角的東西（卡片、磚、橫幅）：半徑 = 螢幕半徑 − 內縮，形狀用同一種連續曲率；
// - 同一組磚（Home Modular）全部用同一個半徑，間距＝外距，留出空氣；
// - 角落的膠囊：兩端半圓的圓心落在螢幕圓角的圓心上（等外距），所以弧線同心；
// - 縮圖（總覽）：照縮放比例用同一個形狀。

import AppKit

enum Screen {
    static let side: CGFloat = 1024
    /// 機身螢幕的連續圓角半徑（畫布單位）
    static let cornerRadius: CGFloat = CGFloat(CornerFit.bodyDiag) * side / 0.29438
    /// 內縮 inset 之後要跟螢幕同心的半徑
    static func concentric(inset: CGFloat, minimum: CGFloat = 12) -> CGFloat { max(minimum, cornerRadius - inset) }

    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    /// 角落膠囊（寬 w、高 h）的中心：靠角那端的半圓與螢幕圓角同圓心
    static func cornerCapsuleCenter(_ c: Corner, width w: CGFloat, height h: CGFloat) -> CGPoint {
        let R = cornerRadius, half = (w - h) / 2
        switch c {
        case .topLeft: return CGPoint(x: R + half, y: R)
        case .topRight: return CGPoint(x: side - R - half, y: R)
        case .bottomLeft: return CGPoint(x: R + half, y: side - R)
        case .bottomRight: return CGPoint(x: side - R - half, y: side - R)
        }
    }
    /// 整個螢幕的形狀（裁切、縮圖用）
    static func path(in r: CGRect = CGRect(x: 0, y: 0, width: side, height: side)) -> CGPath {
        continuousRoundedRect(r, radius: cornerRadius * r.width / side)
    }
}

/// iOS 的連續曲率圓角矩形（UIBezierPath 圓角的同一組係數）：直線進入圓弧時曲率是漸變的，不會有「接縫」。
/// 半徑太大時（> 短邊的 1/(2·1.5287)）自動收小，形狀仍連續。
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = max(0, min(radius, min(rect.width, rect.height) / 2 / 1.52866483))
    guard r > 0.5 else { return CGPath(rect: rect, transform: nil) }
    let p = CGMutablePath()
    let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + x * r, y: y0 + y * r) }
    func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x1 - x * r, y: y0 + y * r) }
    func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x1 - x * r, y: y1 - y * r) }
    func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + x * r, y: y1 - y * r) }
    typealias F = (CGFloat, CGFloat) -> CGPoint
    // 每個角：兩段三次曲線＋中間一小段，係數取自 iOS 7 起的連續圓角
    func corner(_ f: F) {
        p.addCurve(to: f(0.66993427, 0.06549600), control1: f(1.08849323, 0), control2: f(0.86840689, 0))
        p.addLine(to: f(0.63149399, 0.07491100))
        p.addCurve(to: f(0.07491176, 0.63149399), control1: f(0.39518276, 0.15435844), control2: f(0.15435743, 0.39518377))
        p.addCurve(to: f(0, 1.52866483), control1: f(0, 0.86840701), control2: f(0, 1.08849299))
    }
    // 角的函式以「離角的距離」表示，四個角各自鏡射；照順時針：上緣 → 右上 → 右緣 → 右下 …
    p.move(to: tl(1.52866483, 0))
    p.addLine(to: tr(1.52866471, 0))
    corner { a, b in tr(a, b) }
    p.addLine(to: br(0, 1.52866471))
    corner { a, b in br(b, a) }
    p.addLine(to: bl(1.52866471, 0))
    corner { a, b in bl(a, b) }
    p.addLine(to: tl(0, 1.52866483))
    corner { a, b in tl(b, a) }
    p.closeSubpath()
    return p
}

// MARK: - 換錶面：分頁滑動（2.0 R14）與材質化過場
// 換錶面照官方影片（v2「錶面之間跟手的分頁滑動」）：每頁保有自己的圓角，頁與頁之間 20 px 黑縫，臨界阻尼彈簧、不回彈；
// 方向從陣容裡的前後算（頭尾相接）。不是換頁的過場（錶面 ↔ 主畫面往上滑）照舊：舊畫面像玻璃起霧一樣化開，
// 新的從 1.03 倍輕輕收回到位。系統「減少動態效果」時只淡入淡出。快照：HOMEPLAY_ANIM=facepage:0.1

import CoreImage

extension Face {
    static let transitionDuration = 0.45
    static let pageSpring = HPMotion.T.facePage.spring   // 動效包：參數表（Design/HPMotionTable.swift）
    /// 動效包：跟手放手接過來的起點與速度（進度單位：0＝舊頁、1＝新頁到位）；nil＝從 0 靜止起跑（滾輪、方向鍵）
    nonisolated(unsafe) static var pageStart: (x: CGFloat, v: CGFloat)?
    /// 2.0 跟手換頁（Shell/FacePaging.swift）：手指還按著＝過場停在這個進度；放手後彈簧走向 pageGoal（1＝換過去、0＝退回，到了叫 pageCancel 換回原本的）
    nonisolated(unsafe) static var pageHold: CGFloat?
    nonisolated(unsafe) static var pageGoal: CGFloat = 1
    nonisolated(unsafe) static var pageCancel: (() -> Void)?
    /// 動效包：這次過場是回錶面——新錶面從約 45 px 模糊變清楚（v1 1:20.94→1:21.15），不是舊畫面起霧
    nonisolated(unsafe) static var toFaceDeblur = false
    nonisolated(unsafe) static var deblurFrom: CGImage?
    /// 換頁時「舊畫面」要用哪一幀（回歸 #15）：上一幀乾淨（沒壓暗、不在換頁中、不是 CarPlay 直播/暫停）
    /// 才用 lastFrame；否則退回最後一張穩定幀；兩張都沒有就不轉場。抽成純函式給 selftest 釘住。
    enum TransitionSource { case last, settled, none }
    static func transitionSource(dim: CGFloat, pageDir: Int, status: CarPlayStatus,
                                 hasLast: Bool, hasSettled: Bool) -> TransitionSource {
        if hasLast, dim <= 0.005, pageDir == 0, status != .live, status != .paused { return .last }
        return hasSettled ? .settled : .none
    }

    static let pageGap: CGFloat = 20
    private static let transitionCI = CIContext(options: [.cacheIntermediates: false])
    /// 上一幀畫的是哪個錶面（換頁方向用）；外殼的換頁（主畫面 ↔ 頭尾錶面）直接指定方向
    nonisolated(unsafe) static var pagePrev: FaceStyle?
    nonisolated(unsafe) static var pageDirOverride: Int?
    nonisolated(unsafe) static var pageDir = 0

    func beginFaceTransition() {
        guard !FaceOverview.active else { faceTransition = nil; return }
        var dir = 0
        let lineup = FaceStyle.lineup, n = lineup.count
        if let o = Self.pageDirOverride { dir = o.signum() }
        else if let p = Self.pagePrev, p != style.inLineup, let i = lineup.firstIndex(of: p), let j = lineup.firstIndex(of: style.inLineup), n > 1 {
            var d = j - i
            if abs(d) * 2 > n { d = d > 0 ? d - n : d + n }
            dir = d.signum()
        }
        Self.pageDirOverride = nil
        Self.pageDir = dir
        // 過場還在跑時再次換頁：沿用「最初那張」舊幀——lastFrame 是含上一層過場的合成幀，
        // 重拍會層層複合出黑影與鬼影（使用者 2026-11-08 錄影實錘：快滑 photos↔island 出現巨型黑膠囊）
        let old: CGImage
        var source = "reentry"
        if let t = faceTransition { old = t.sharp }
        else {
            switch Self.transitionSource(dim: cur.dim, pageDir: Self.pageDir, status: status,
                                         hasLast: lastFrame != nil, hasSettled: settledFrame != nil) {
            case .last: old = lastFrame!; source = "last"
            case .settled: old = settledFrame!; source = "settled"
            case .none: faceTransition = nil; return
            }
        }
        let frosted: CGImage
        if dir == 0 {
            let ci = CIImage(cgImage: old)
            let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(old.width) / 1024 * 22).cropped(to: ci.extent)
            frosted = Self.transitionCI.createCGImage(blurred, from: ci.extent) ?? old
        } else { frosted = old }
        faceTransition = (old, frosted, CACurrentMediaTime(), islandRect)   // HomeView 對齊後續 #4：記下舊膠囊位置＝Portal 的共享元素
        portalCoreFrom = capsuleCore   // 後續 #7：橫滑也要的膠囊本體（確切矩形）
        Self.deblurFrom = nil
        if dir != 0 { Self.toFaceDeblur = false }
        // 診斷（回歸 #17b／#15）：換面時記下這幀從哪來、往哪個方向、舊膠囊多大——
        // 使用者錄影裡的黑藥丸只在這條路徑出現；下次再有黑膠囊，這一行可以對出是哪個來源幀。
        let isl = islandRect.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" } ?? "nil"
        appendDiag("gesture.log", "FACETR begin ->\(style.rawValue) dir=\(dir) src=\(source) island=\(isl)")
    }
    /// 0…1；過場結束就清掉、回 nil
    func faceTransitionProgress(_ now: Double) -> CGFloat? {
        defer { if faceTransition == nil { Self.pagePrev = style.inLineup } }
        guard let t = faceTransition else { return nil }
        if Self.pageDir != 0 && !reduceMotion {
            if let h = Self.pageHold { return max(0, min(1, h)) }   // 2.0：手指還按著
            let e = CGFloat(Motion.frozen("facepage") ?? (now - t.start))
            let s0 = Self.pageStart ?? (0, 0)   // 動效包：跟手放手時從手指那一刻的位置與速度接著走
            let goal = Self.pageGoal
            if Motion.frozen("facepage") == nil, Self.pageSpring.settled(from: s0.x, to: goal, velocity: s0.v, t: e) {
                faceTransition = nil; Self.pageStart = nil
                if goal == 0 { Self.pageGoal = 1; let c = Self.pageCancel; Self.pageCancel = nil; c?() }   // 2.0：退回到底，換回原本的錶面
                return nil
            }
            return max(0, min(1, Self.pageSpring.value(from: s0.x, to: goal, velocity: s0.v, t: e).x))
        }
        // 動效包：錶面 ↔ 主畫面、回錶面也走彈簧（參數表 homeFace／toFace）；減少動態效果時 0.2 s 線性
        let tr = Self.toFaceDeblur ? HPMotion.T.toFace : HPMotion.T.homeFace
        let e = CGFloat(Motion.frozen(tr.name) ?? (now - t.start))
        if Motion.frozen(tr.name) == nil, reduceMotion ? e >= 0.2 : tr.spring.settled(from: 0, to: 1, velocity: 0, t: e - CGFloat(tr.delay), eps: 0.004) {
            faceTransition = nil; Self.toFaceDeblur = false; Self.deblurFrom = nil; return nil
        }
        return HPMotion.progress(tr, e)
    }
    private var reduceMotion: Bool { Motion.reduceMotion }
    private var sliding: Bool { Self.pageDir != 0 && !reduceMotion }
    /// 橫滑換頁的 Portal（膠囊錨在屏上）：先關（見 endFaceTransitionFrame）
    static let slidePortal = false
    private var pageShift: CGFloat { 1024 + Self.pageGap }
    /// 新錶面畫之前：滑動＝新頁從旁邊推進來（先塗黑當頁縫）；否則以中心微微放大（臨界阻尼收斂到 1）
    func beginFaceTransitionFrame(_ g: CGContext, _ x: CGFloat) {
        g.saveGState()   // endFaceTransitionFrame 還原：後面的提示卡、過場不跟著縮
        if sliding {
            let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
            g.setFillColor(NSColor.black.cgColor); g.fill(full)
            g.translateBy(x: CGFloat(Self.pageDir) * pageShift * (1 - x), y: 0)
            g.addPath(continuousRoundedRect(full, radius: Screen.cornerRadius)); g.clip()
            return
        }
        guard !reduceMotion, !Self.toFaceDeblur else { return }
        let k = 1.03 - 0.03 * x   // 從略大收回到位（x 已經是彈簧的進度）：全螢幕內容不能小於螢幕，否則四周露邊
        g.translateBy(x: 512, y: 512); g.scaleBy(x: k, y: k); g.translateBy(x: -512, y: -512)
    }
    /// 新錶面畫完：滑動＝舊頁往另一邊推出去；否則蓋上舊錶面——前 30% 從清楚過渡到霧化，之後整片淡出
    func endFaceTransitionFrame(_ g: CGContext, _ x: CGFloat) {
        g.restoreGState()   // 收掉 begin 的縮放
        guard let t = faceTransition else { return }
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        g.saveGState()
        if sliding {
            // 後續 #7（共享元素轉場）：膠囊錨在屏上，兩頁各自在自己的座標裡把膠囊補成背景，頂層畫一顆屏幕上的膠囊
            // 2026-11-06 關掉：各錶面膠囊位置與材質不同（玻璃／黑），補洞在多數組合拖出糊帶、殘影，還每幀整幀拷貝超出 16.7 ms；
            // iOS 的分頁是整頁一起走——共享元素只留在錶面↔主畫面的淡入（開門過場那條），等不必補洞的做法再開
            let from = Self.slidePortal ? portalCoreFrom.flatMap { PortalSlide.valid($0) ? $0 : nil } : nil
            let to = capsuleCoreBuilding.flatMap { PortalSlide.valid($0) ? $0 : nil }
            let newTx = PortalSlide.newShift(dir: Self.pageDir, x: x, shift: pageShift)
            let oldTx = PortalSlide.oldShift(dir: Self.pageDir, x: x, shift: pageShift)
            let handoff = from.map { PortalSlide.handoff(from: $0, to: to, x: x) } ?? 1
            // 診斷：每個過場記一次（不是每幀），對照 #17b 的黑藥丸是否來自這條橫滑路徑
            if Self.slideLogToken != t.start {
                Self.slideLogToken = t.start
                func fmt(_ r: CGRect?) -> String { r.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" } ?? "nil" }
                appendDiag("gesture.log", "FACETR slide dir=\(Self.pageDir) x=\(String(format: "%.2f", x)) from=\(fmt(from)) to=\(fmt(to))")
            }
            if from != nil, let to, handoff > 0.001, let shot = g.makeImage() {   // 新頁（在 newTx）：拿這一幀畫好的新頁補；交棒時淡掉露出新膠囊
                g.saveGState(); g.setAlpha(handoff)
                portalPatch(g, shot, hole: PortalSlide.hole(to), tx: newTx)
                g.restoreGState()
            }
            g.translateBy(x: oldTx, y: 0)
            g.addPath(continuousRoundedRect(full, radius: Screen.cornerRadius)); g.clip()
            drawUpright(g, t.sharp, in: full)
            if let from { portalPatch(g, t.sharp, hole: PortalSlide.hole(from), tx: 0) }   // 舊頁：自己座標裡的洞
            g.restoreGState()
            if let from, handoff > 0.001 {   // 頂層：舊幀的膠囊原樣（像素一致）錨在屏上；隨進度滑到新頁膠囊的位置，到位時無縫交棒
                let a = PortalSlide.anchor(from: from, to: to, x: x)
                g.saveGState(); g.setAlpha(handoff)
                g.addPath(CGPath(roundedRect: a, cornerWidth: a.height / 2, cornerHeight: a.height / 2, transform: nil)); g.clip()
                if let crop = PortalSlide.crop(t.sharp, from) { drawUpright(g, crop, in: a) }
                g.restoreGState()
            }
            return
        }
        if Self.toFaceDeblur {   // 動效包：回錶面——舊畫面一格內拿掉，新錶面的模糊版蓋在上面淡掉（＝從 45 px 模糊變清楚）
            g.restoreGState()
            if reduceMotion { g.saveGState(); g.setAlpha(1 - x); drawUpright(g, t.sharp, in: full); g.restoreGState(); return }
            if Self.deblurFrom == nil, let shot = g.makeImage() {
                let ci = CIImage(cgImage: shot)
                Self.deblurFrom = Self.transitionCI.createCGImage(ci.clampedToExtent().applyingGaussianBlur(sigma: Double(shot.width) / 1024 * 45 / 2).cropped(to: ci.extent), from: ci.extent)
            }
            if let b = Self.deblurFrom { g.saveGState(); g.setAlpha(1 - x); drawUpright(g, b, in: full); g.restoreGState() }
            return
        }
        let fade = 1 - x
        if reduceMotion {
            g.setAlpha(fade); drawUpright(g, t.sharp, in: full)
        } else {
            let fog = min(1, x / 0.3)
            g.setAlpha(fade * (1 - fog)); drawUpright(g, t.sharp, in: full)
            g.setAlpha(fade * fog); drawUpright(g, t.frosted, in: full)
        }
        // 2.0「膠囊開門」挖洞已移除（2026-11-09，回歸 #17b／#15）：
        // setBlendMode(.clear) 會把合成幀的 alpha 挖成 0，貼到 3D 螢幕（unlit）上就是黑色——
        // 膠囊多大就出現多大的黑藥丸，還會留在 lastFrame 裡變成鬼影。beta 1／1.0.x 沒有這個效果，
        // 使用者實測也只有「切換錶面」時才出現。舊畫面照一般淡出即可。
        g.restoreGState()
    }
}

extension Face {
    /// 後續 #7：把一頁上的膠囊「挖掉」——img 是這一頁（畫布座標，頁平移 tx），用洞上方與下方同一頁的兩條背景蓋在洞上。
    /// 兩條各縮成 12×1（上一列、下一列）再放大：洞裡是上下底色之間的漸層，不複製旁邊的字（beta 5 拍板：上下取樣平均，單取一條會留色斑）
    fileprivate func portalPatch(_ g: CGContext, _ img: CGImage, hole: CGRect, tx: CGFloat) {
        let src = PortalSlide.patchSources(hole)
        func strip(_ r: CGRect?) -> CGImage? {
            guard let r, let part = PortalSlide.cropPart(r.offsetBy(dx: tx, dy: 0), imageWidth: img.width, imageHeight: img.height) else { return nil }
            return img.cropping(to: part.pixels)
        }
        guard let top = strip(src.above) ?? strip(src.below), let bottom = strip(src.below) ?? strip(src.above) else { return }
        let crop = makeImage(12, 2) { c in
            self.drawUpright(c, top, in: CGRect(x: 0, y: 0, width: 12, height: 1))
            self.drawUpright(c, bottom, in: CGRect(x: 0, y: 1, width: 12, height: 1))
        }
        g.saveGState()
        let h = hole.offsetBy(dx: tx, dy: 0)
        g.addPath(CGPath(roundedRect: h, cornerWidth: h.height / 2, cornerHeight: h.height / 2, transform: nil)); g.clip()
        drawUpright(g, crop, in: h)
        g.restoreGState()
    }
}

/// 後續 #7：橫滑換頁的 Portal（共享元素＝👀 膠囊）純邏輯——頁平移、洞、錨點、裁切換算（自檢釘住）
enum PortalSlide {
    /// 膠囊夠大才做（太小＝沒畫膠囊或收起來了）
    static func valid(_ r: CGRect) -> Bool { r.width > 8 && r.height > 8 && r.width >= r.height }
    /// 新頁從旁邊推進來：x＝0 在一整頁外、x＝1 到位
    static func newShift(dir: Int, x: CGFloat, shift: CGFloat) -> CGFloat { CGFloat(dir) * shift * (1 - x) }
    /// 舊頁往另一邊推出去
    static func oldShift(dir: Int, x: CGFloat, shift: CGFloat) -> CGFloat { -CGFloat(dir) * shift * x }
    /// 洞：比膠囊本體大一圈（玻璃膠囊轉場中的外圈、陰影、描邊一起拿掉；實測 12% 會留一圈黑邊），兩端半圓
    static func hole(_ core: CGRect) -> CGRect { core.insetBy(dx: -core.height * 0.3, dy: -core.height * 0.3) }
    /// 補洞用的背景條：緊貼洞的上方、下方各一條細條（高＝洞高 8%、至少 4；取太厚會把旁邊的字平均進來成灰塊）；超出畫布的那條不取（nil）
    static func patchSources(_ hole: CGRect, side: CGFloat = 1024) -> (above: CGRect?, below: CGRect?) {
        let h = max(4, hole.height * 0.08)
        let above = CGRect(x: hole.minX, y: hole.minY - h, width: hole.width, height: h)
        let below = CGRect(x: hole.minX, y: hole.maxY, width: hole.width, height: h)
        return (above.minY >= 0 ? above : nil, below.maxY <= side ? below : nil)
    }
    /// 屏幕上的膠囊錨點：從舊位置隨進度走到新頁的膠囊（取消時 x 回 0＝自然歸位）；新頁沒有膠囊或差太遠（> 一個膠囊高）就停在舊位置
    static func anchor(from: CGRect, to: CGRect?, x: CGFloat) -> CGRect {
        guard let to, lerps(from: from, to: to) else { return from }
        let k = max(0, min(1, x))
        func l(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        return CGRect(x: l(from.minX, to.minX), y: l(from.minY, to.minY), width: l(from.width, to.width), height: l(from.height, to.height))
    }
    /// 交棒：兩顆膠囊對得上（anchor 會滑過去）＝屏上那顆一路不透明；對不上（差太遠、新頁沒膠囊）＝最後 30% 淡出、新頁的膠囊淡入，
    /// 不在轉場結束那一格瞬移
    static func lerps(from: CGRect, to: CGRect?) -> Bool { to.map { abs($0.midY - from.midY) <= from.height } ?? false }
    static func handoff(from: CGRect, to: CGRect?, x: CGFloat) -> CGFloat {
        if lerps(from: from, to: to) { return 1 }
        let t = max(0, min(1, (x - 0.7) / 0.3))
        return 1 - t * t * (3 - 2 * t)
    }
    /// 畫布矩形 → 圖上的像素矩形（圖是 1024 畫布照像素比渲染、左上原點）；超出圖的部分裁掉，canvas 回傳對應的那一塊
    static func cropPart(_ r: CGRect, imageWidth w: Int, imageHeight h: Int) -> (pixels: CGRect, canvas: CGRect)? {
        let sc = CGFloat(w) / 1024
        guard sc > 0 else { return nil }
        let px = CGRect(x: r.minX * sc, y: r.minY * sc, width: r.width * sc, height: r.height * sc).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !px.isNull, px.width >= 1, px.height >= 1 else { return nil }
        return (px, CGRect(x: px.minX / sc, y: px.minY / sc, width: px.width / sc, height: px.height / sc))
    }
    /// 整塊在圖內才裁（屏幕上的膠囊要完整）
    static func crop(_ img: CGImage, _ r: CGRect) -> CGImage? {
        guard let p = cropPart(r, imageWidth: img.width, imageHeight: img.height), abs(p.canvas.width - r.width) < 2, abs(p.canvas.height - r.height) < 2 else { return nil }
        return img.cropping(to: p.pixels)
    }
}

enum PortalSlideSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let shift: CGFloat = 1024 + Face.pageGap
        check(PortalSlide.newShift(dir: 1, x: 0, shift: shift) == shift && PortalSlide.newShift(dir: 1, x: 1, shift: shift) == 0
              && PortalSlide.oldShift(dir: 1, x: 0.5, shift: shift) == -shift / 2 && PortalSlide.oldShift(dir: -1, x: 0.5, shift: shift) == shift / 2,
              "Portal 橫滑：新頁從一整頁外推到位、舊頁往反方向推出")   // l10n-ignore
        let core = CGRect(x: 400, y: 60, width: 224, height: 80)
        let hole = PortalSlide.hole(core)
        check(hole.contains(core) && abs(hole.height - core.height * 1.6) < 1e-6 && abs(hole.midX - core.midX) < 1e-6,
              "Portal 橫滑：洞包住膠囊本體、外擴一圈 30%")   // l10n-ignore
        let ps = PortalSlide.patchSources(PortalSlide.hole(core.offsetBy(dx: 0, dy: 300)))
        let mh = PortalSlide.hole(core.offsetBy(dx: 0, dy: 300))
        check(ps.above.map { abs($0.maxY - mh.minY) < 1e-6 } == true && ps.below.map { abs($0.minY - mh.maxY) < 1e-6 } == true,
              "Portal 橫滑：補洞取樣＝緊貼洞的上方與下方兩條、不重疊")   // l10n-ignore
        check(PortalSlide.patchSources(CGRect(x: 0, y: 2, width: 100, height: 40)).above == nil
              && PortalSlide.patchSources(CGRect(x: 0, y: 982, width: 100, height: 40)).below == nil, "Portal 橫滑：超出畫布的那一條不取")   // l10n-ignore
        let to = core.offsetBy(dx: 40, dy: 10)
        check(PortalSlide.anchor(from: core, to: to, x: 0) == core && PortalSlide.anchor(from: core, to: to, x: 1) == to
              && abs(PortalSlide.anchor(from: core, to: to, x: 0.5).minX - 420) < 1e-6, "Portal 橫滑：膠囊錨在屏上，隨進度交棒到新頁的膠囊")   // l10n-ignore
        check(PortalSlide.anchor(from: core, to: core.offsetBy(dx: 0, dy: 400), x: 0.8) == core && PortalSlide.anchor(from: core, to: nil, x: 0.8) == core,
              "Portal 橫滑：新頁膠囊差太遠或沒有＝停在舊位置")   // l10n-ignore
        let p = PortalSlide.cropPart(CGRect(x: 1000, y: 10, width: 100, height: 20), imageWidth: 512, imageHeight: 512)
        check(p?.pixels == CGRect(x: 500, y: 5, width: 12, height: 10) && p.map { abs($0.canvas.width - 24) < 1e-6 } == true
              && PortalSlide.cropPart(CGRect(x: 1100, y: 0, width: 50, height: 50), imageWidth: 512, imageHeight: 512) == nil,
              "Portal 橫滑：畫布→像素換算照像素比、超出圖的部分裁掉")   // l10n-ignore
        check(!PortalSlide.valid(CGRect(x: 0, y: 0, width: 4, height: 4)) && PortalSlide.valid(core), "Portal 橫滑：沒有膠囊就不做")   // l10n-ignore
        let far = core.offsetBy(dx: 0, dy: 700)
        check(PortalSlide.handoff(from: core, to: to, x: 0.95) == 1 && PortalSlide.handoff(from: core, to: far, x: 0.5) == 1
              && PortalSlide.handoff(from: core, to: far, x: 0.85) < 1 && PortalSlide.handoff(from: core, to: far, x: 1) == 0 && PortalSlide.handoff(from: core, to: nil, x: 1) == 0,
              "Portal 橫滑：膠囊對不上時最後 30% 交叉淡化交棒、不瞬移")   // l10n-ignore
    }
}

extension Face {
    /// 秒針／跳秒只在有人靠近（或正在互動）時出現：沒人看時錶面每秒不變，閒置的海報就不必每秒重畫 3D（像 Apple Watch 的常亮模式）
    var secondsVisible: Bool { reveal > 0.25 || Face.secondsOverride }
    /// 快照、自檢用：強制顯示秒針
    nonisolated(unsafe) static var secondsOverride = false
}
