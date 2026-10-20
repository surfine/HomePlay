// 錶面「Flow」——照「HomePlay 屏幕介面稿」的 Flow.dc.html 实现。
// 深紫底上四团柔光随游标视差漂动，大时间在上、日期在下、玻璃岛居中。

import AppKit

// 上次重画的 0.1 秒刻度（扩展里不能加存储属性）
nonisolated(unsafe) private var flowFaceLastTick = -1.0

extension Face {
    /// 四团光：中心、半径、纵向压扁、颜色、起始透明度、游标视差幅度、自主漂动周期（秒）
    private static let flowBlobs: [(c: CGPoint, r: CGFloat, sy: CGFloat, rgb: (CGFloat, CGFloat, CGFloat), a: CGFloat, par: CGFloat, per: Double)] = [
        (CGPoint(x: 224, y: 288), 416, 1.0, (1.00, 0.36, 0.67), 0.95, 70, 31),
        (CGPoint(x: 800, y: 448), 384, 1.0, (0.36, 0.55, 1.00), 0.95, 46, 23),
        (CGPoint(x: 544, y: 848), 448, 0.82, (1.00, 0.73, 0.36), 0.85, 90, 37),
        (CGPoint(x: 768, y: 816), 240, 1.0, (0.47, 0.94, 0.86), 0.80, 120, 27),
    ]

    func renderFlowFace(_ g: CGContext, _ now: Double) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        g.setFillColor(NSColor(srgbRed: 0.071, green: 0.047, blue: 0.165, alpha: 1).cgColor)   // #120c2a
        g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        for (i, b) in Self.flowBlobs.enumerated() {
            let ph = Double(i) * 1.7
            let cx = b.c.x + flow.x * b.par + CGFloat(sin(now * 2 * .pi / b.per + ph)) * 34
            let cy = b.c.y + flow.y * b.par * 0.8 + CGFloat(cos(now * 2 * .pi / (b.per * 1.3) + ph)) * 28
            let col = [b.rgb.0, b.rgb.1, b.rgb.2, b.a], zero = [b.rgb.0, b.rgb.1, b.rgb.2, 0]
            guard let grad = CGGradient(colorSpace: cs, colorComponents: col + zero, locations: [0, 1], count: 2) else { continue }
            g.saveGState()
            g.translateBy(x: cx, y: cy); g.scaleBy(x: 1, y: b.sy)
            g.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: b.r * 0.96, options: [])
            g.restoreGState()
        }
        let date = Date()
        // 大时间：柔和投影
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -6), blur: 48, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        drawCentered(g, Self.clock(date), font: Self.rounded(154, weight: .semibold), kern: -3, y: 212, color: .white)
        g.restoreGState()
        drawCentered(g, Self.dateLine(date), font: Self.rounded(32, weight: .semibold), kern: 1.6, y: 930,
                     color: NSColor.white.withAlphaComponent(0.85))
        drawIsland(g, at: CGPoint(x: 512, y: 600), scale: 0.78, liveAt: CGPoint(x: 512, y: 760), now: now)
    }

    /// 光团一直在漂，限 10fps 重画
    func tickFlowFace(_ now: Double) -> Bool {
        let t = floor(now * 10)
        if t == flowFaceLastTick { return false }
        flowFaceLastTick = t
        return true
    }
}
