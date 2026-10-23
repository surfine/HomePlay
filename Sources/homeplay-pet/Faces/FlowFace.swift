// 錶面「Flow」：照 HomeView／watchOS 的 Flow——上時下分兩行「吹出來」的玻璃泡泡字，
// 底下是會流動的色彩（洋紅、電光藍、青、紫），字裡透出被折射、放大過的同一片色彩；游標（人）靠近時色彩跟著漂。
// 島（👀）夾在兩行數字之間，像泡泡中間的一顆小石頭。

import AppKit

// 上次重畫的 0.1 秒刻度（擴展裡不能加儲存屬性）
nonisolated(unsafe) private var flowFaceLastTick = -1.0
/// 色彩流動用的時鐘：只在有人靠近時往前走（沒人看就停住、3D 可以卸下省電；回來時接著流，不會跳）
nonisolated(unsafe) private var flowAnimT = 0.0, flowAnimLast = -1.0, flowLastMinute = -1
nonisolated(unsafe) private var flowDigitCache: (key: String, top: GlyphShape, bottom: GlyphShape)?

extension Face {
    /// 色團：中心、半徑、縱向壓扁、顏色、透明度、游標視差、自主漂動週期（秒）
    private static let flowBlobs: [(c: CGPoint, r: CGFloat, sy: CGFloat, rgb: UInt32, a: CGFloat, par: CGFloat, per: Double)] = [
        (CGPoint(x: 250, y: 300), 430, 1.0, 0xff3fb8, 0.95, 70, 31),    // 洋紅
        (CGPoint(x: 780, y: 420), 420, 0.9, 0x3d4dff, 0.95, 52, 23),    // 電光藍
        (CGPoint(x: 520, y: 820), 470, 0.8, 0x9a5cff, 0.85, 90, 37),    // 紫
        (CGPoint(x: 820, y: 860), 260, 1.0, 0x7fdcff, 0.80, 120, 27),   // 青
        (CGPoint(x: 160, y: 760), 240, 1.0, 0xff8fd6, 0.70, 60, 41),    // 粉
    ]

    private func drawFlowField(_ g: CGContext, _ now0: Double) {
        let now = flowAnimT
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 底：淡紫到粉的漸層（亮底，不是深夜）
        let base = CGGradient(colorsSpace: cs, colors: [srgb(0xb9a2f2).cgColor, srgb(0xd7a6e6).cgColor, srgb(0xf1b3d9).cgColor] as CFArray,
                              locations: [0, 0.55, 1])!
        g.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])
        for (i, b) in Self.flowBlobs.enumerated() {
            let ph = Double(i) * 1.7
            let cx = b.c.x + flow.x * b.par + CGFloat(sin(now * 2 * .pi / b.per + ph)) * 40
            let cy = b.c.y + flow.y * b.par * 0.8 + CGFloat(cos(now * 2 * .pi / (b.per * 1.3) + ph)) * 34
            let col = srgb(b.rgb)
            let grad = CGGradient(colorsSpace: cs, colors: [col.withAlphaComponent(b.a).cgColor, col.withAlphaComponent(b.a * 0.5).cgColor,
                                                            col.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
            g.saveGState()
            g.translateBy(x: cx, y: cy); g.scaleBy(x: 1, y: b.sy)
            g.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: b.r, options: [])
            g.restoreGState()
        }
    }

    func renderFlowFace(_ g: CGContext, _ now: Double) {
        drawFlowField(g, now)
        // 四周一圈很淡的白霧，讓畫面像隔著一層玻璃
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let vig = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 0.22).cgColor] as CFArray,
                             locations: [0.55, 1])!
        g.drawRadialGradient(vig, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 760, options: [])

        let date = Self.displayDate
        let (hh, mm) = Self.hourMinute(date)
        let hh2 = hh.count == 1 ? "0" + hh : hh   // 泡泡字兩行對齊：小時補零
        let key = "\(hh2)\(mm)"
        let shapes: (GlyphShape, GlyphShape)
        if let c = flowDigitCache, c.key == key { shapes = (c.top, c.bottom) } else {
            // SF 圓體最粗，再沿外框鼓起一圈（圓角描邊與原形聯集）＝吹脹的泡泡
            // 系統錶面數字的 Soft 款：最粗、轉角最圓（SOFT 100），再沿外框鼓起一圈
            let f = FaceType.numeric(.soft, 400, ["wght": 1000, "wdth": 110, "SOFT": 100])
            func bubble(_ s: String, top: CGFloat) -> GlyphShape {
                let raw = GlyphShape(s, font: f, kern: 6).tall(height: 360, stretch: 1.0, at: CGPoint(x: 512, y: top), anchorX: 0.5, maxWidth: 780)
                let puffed = raw.path.copy(strokingWithWidth: 18, lineCap: .round, lineJoin: .round, miterLimit: 1)
                return GlyphShape(path: raw.path.union(puffed))
            }
            shapes = (bubble(hh2, top: 80), bubble(mm, top: 560))
            flowDigitCache = (key, shapes.0, shapes.1)
        }
        // 折射用的背景：同一片色彩畫到小圖再模糊（色團在漂，所以每次都取）
        let small = snapshotBackdrop(px: 192) { c in self.drawFlowField(c, now) }
        let backdrop = blurredBackdrop(small, sigma: 10, key: "flowface|\(Int(flowAnimT * 10))")
        let clear = snapshotBackdrop(px: 384) { c in self.drawFlowField(c, now) }
        // 亮邊跟著人轉：人在左邊，光就從左邊打過來（像斜著看 iPhone 鎖定畫面的玻璃時間）
        let pt = Self.pointerOverride ?? pointer ?? .zero
        let turn = max(-0.9, min(0.9, -pt.x * 0.7 + pt.y * 0.35))
        drawLiquidGlass(g, [shapes.0, shapes.1], key: "flow|\(key)", clear: clear, frosted: backdrop, params: .bubble, system: .bubble,
                        lightTurn: turn, fallback: .bubble)

        drawIsland(g, at: CGPoint(x: 512, y: 500), scale: 0.62, liveAt: CGPoint(x: 512, y: 500), now: now)
        // 日期：靠近才浮出（右下一行小字，不搶泡泡）
        if reveal > 0.02 {
            g.saveGState(); g.setAlpha(reveal)
            drawCentered(g, Self.dateLine(date), font: FaceType.sf(32, .semibold, mono: false), kern: 0.4, y: 990,
                         color: NSColor.white.withAlphaComponent(0.92))
            g.restoreGState()
        }
    }

    /// 有人靠近時色團在漂（10fps）；沒人時停住，只在換分鐘時重畫
    func tickFlowFace(_ now: Double) -> Bool {
        let active = flowActive || reveal > 0.05
        if flowAnimLast >= 0, active { flowAnimT += min(0.25, now - flowAnimLast) }
        flowAnimLast = now
        let minute = Int(Self.displayDate.timeIntervalSince1970 / 60)
        if minute != flowLastMinute { flowLastMinute = minute; return true }
        guard active else { return false }
        let t = floor(now * 10)
        if t == flowFaceLastTick { return false }
        flowFaceLastTick = t
        return true
    }
}
