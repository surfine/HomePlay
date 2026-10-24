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

// MARK: - 換錶面：材質化過場
// 照 Liquid Glass 的進場：舊錶面不是硬切，而是像玻璃起霧一樣化開（先失焦、再淡出）；
// 新錶面從 1.03 倍輕輕收回到位，像從霧後浮上來、落定。0.45 s，臨界阻尼（不回彈）；系統「減少動態效果」時只淡入淡出。

import CoreImage

extension Face {
    static let transitionDuration = 0.45
    private static let transitionCI = CIContext(options: [.cacheIntermediates: false])

    func beginFaceTransition() {
        guard let old = lastFrame, !FaceOverview.active else { faceTransition = nil; return }
        let ci = CIImage(cgImage: old)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(old.width) / 1024 * 22).cropped(to: ci.extent)
        let frosted = Self.transitionCI.createCGImage(blurred, from: ci.extent) ?? old
        faceTransition = (old, frosted, CACurrentMediaTime())
    }
    /// 0…1；過場結束就清掉、回 nil
    func faceTransitionProgress(_ now: Double) -> CGFloat? {
        guard let t = faceTransition else { return nil }
        let x = (now - t.start) / Self.transitionDuration
        if x >= 1 { faceTransition = nil; return nil }
        return CGFloat(max(0, x))
    }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// 新錶面畫之前：以中心微微放大（臨界阻尼收斂到 1）
    func beginFaceTransitionFrame(_ g: CGContext, _ x: CGFloat) {
        g.saveGState()   // endFaceTransitionFrame 還原：後面的提示卡、過場不跟著縮
        guard !reduceMotion else { return }
        let e = 1 - pow(1 - x, 3), k = 1.03 - 0.03 * e   // 從略大收回到位：全螢幕內容不能小於螢幕，否則四周露邊
        g.translateBy(x: 512, y: 512); g.scaleBy(x: k, y: k); g.translateBy(x: -512, y: -512)
    }
    /// 新錶面畫完：蓋上舊錶面——前 30% 從清楚過渡到霧化，之後整片淡出
    func endFaceTransitionFrame(_ g: CGContext, _ x: CGFloat) {
        g.restoreGState()   // 收掉 begin 的縮放
        guard let t = faceTransition else { return }
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        g.saveGState()
        let fade = pow(1 - x, 1.6)
        if reduceMotion {
            g.setAlpha(fade); drawUpright(g, t.sharp, in: full)
        } else {
            let fog = min(1, x / 0.3)
            g.setAlpha(fade * (1 - fog)); drawUpright(g, t.sharp, in: full)
            g.setAlpha(fade * fog); drawUpright(g, t.frosted, in: full)
        }
        g.restoreGState()
    }
}

extension Face {
    /// 秒針／跳秒只在有人靠近（或正在互動）時出現：沒人看時錶面每秒不變，閒置的海報就不必每秒重畫 3D（像 Apple Watch 的常亮模式）
    var secondsVisible: Bool { reveal > 0.25 || Face.secondsOverride }
    /// 快照、自檢用：強制顯示秒針
    nonisolated(unsafe) static var secondsOverride = false
}
