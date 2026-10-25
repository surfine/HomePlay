// 2.0 faceglass：2026 年代的 👀 膠囊走跟控制層同一套校準過的 iOS 系統玻璃（NativeGlass，platform .iOS）。
// 錶面的玻璃字形、水珠、磚不走這裡：用自己的厚玻璃 shader（Faces/LiquidGlass.swift，照官方錶面圖校準）。

import AppKit

extension Face {
    /// 畫一組玻璃形狀（1024 座標）：backdrop 是玻璃後面的畫面（任何解析度，對到整張 1024²）。
    /// clear：Clear（媒體上、最透）或 Regular（霜面）；Regular 的淺深照背後的亮度。系統玻璃拿不到回 false
    @discardableResult
    func faceGlass(_ g: CGContext, _ paths: [CGPath], backdrop: CGImage, clear: Bool, tint: NSColor? = nil) -> Bool {
        let shapes = paths.map(HPGlass.nativeShape)
        guard let first = shapes.first else { return false }
        let ink = shapes.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        let dark = BackdropProbe(backdrop).stats(ink).lum < 0.5
        let q = NativeGlass.Request(shapes: shapes, clear: clear, dark: dark, tint: tint, press: HPGlass.restRim, presence: 1,
                                    scale: renderPixelScale, platform: .iOS, container: shapes.count > 1)
        guard let out = NativeGlass.shared.render(q, backdrop: backdrop) else { return false }
        let all = CGMutablePath()
        for p in paths { all.addPath(p) }
        // 緣外那一圈是系統濾鏡自己畫的外陰影（Regular 才有幾 pt），跟形狀一起貼
        let outset = HPGlass.blitOutset(shapes, clear: clear, dark: dark)
        g.saveGState()
        if outset > 0.5 {
            let ring = all.copy(strokingWithWidth: outset * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
            let both = CGMutablePath(); both.addPath(all); both.addPath(ring)
            g.addPath(both); g.clip(using: .winding)
        } else { g.addPath(all); g.clip() }
        drawUpright(g, out.image, in: out.rect)
        g.restoreGState()
        return true
    }
}
