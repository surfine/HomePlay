// 錶面「指針」：照 HomeView 的 Typograph——12／3／6／9 四個超大數字互相疊在一起、幾乎撐滿整面，
// 白色指針帶細黑邊、細長的秒針；左下一行「週 日」、右下是島（👀）。

import AppKit

/// 上次畫的秒數（擴展裡不能加儲存屬性）
nonisolated(unsafe) private var analogLastSecond = -1
nonisolated(unsafe) private var analogNumeralCache: [GlyphShape]?

extension Face {
    func renderAnalogFace(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 底：飽和的草綠，中間微亮（像錶盤上一層漆）
        let bg = CGGradient(colorsSpace: cs, colors: [srgb(0x47a466).cgColor, srgb(0x3a9459).cgColor] as CFArray, locations: [0, 1])!
        g.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 760,
                             options: [.drawsAfterEndLocation])
        _ = full
        let ink = srgb(0x0b0f0c)
        // 四個數字：字高約 0.42 面高，故意互相壓到（Typograph 的味道）
        if analogNumeralCache == nil {
            let f = FaceType.sf(400, .regular, mono: false)
            let h: CGFloat = 430
            analogNumeralCache = [
                GlyphShape("12", font: f, kern: -14).tall(height: h, stretch: 1.0, at: CGPoint(x: 512, y: 44), anchorX: 0.5),
                GlyphShape("3", font: f).tall(height: h, stretch: 1.0, at: CGPoint(x: 990, y: 300), anchorX: 1),
                GlyphShape("6", font: f).tall(height: h, stretch: 1.0, at: CGPoint(x: 512, y: 560), anchorX: 0.5),
                GlyphShape("9", font: f).tall(height: h, stretch: 1.0, at: CGPoint(x: 34, y: 300), anchorX: 0),
            ]
        }
        for s in analogNumeralCache ?? [] { fillShape(g, s, ink) }

        // 日期：週 + 日，粗體小字
        let date = Self.displayDate
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .weekday, .day], from: date)
        let wd = Self.formatter("EEE").string(from: date).uppercased()
        drawLeft(g, "\(wd) \(c.day ?? 1)", font: FaceType.sf(38, .bold, mono: false), x: 64, y: 966, color: ink, kern: 0.5)

        // 島在右下角，和左下的日期對稱，不被指針蓋到
        drawIsland(g, at: CGPoint(x: 856, y: 950), scale: 0.4, liveAt: CGPoint(x: 512, y: 880), now: now)

        // 指針：白色、細黑邊、柔影；秒針細長白色、尾端略過軸心
        let s = Double(c.second ?? 0), m = Double(c.minute ?? 0) + s / 60, hr = Double((c.hour ?? 0) % 12) + m / 60
        let ctr = CGPoint(x: 512, y: 512)
        func handPath(_ deg: Double, from r0: CGFloat, to r1: CGFloat, width w: CGFloat) -> CGPath {
            let a = CGFloat(deg * .pi / 180), ux = sin(a), uy = -cos(a)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: ctr.x + ux * r0, y: ctr.y + uy * r0))
            p.addLine(to: CGPoint(x: ctr.x + ux * r1, y: ctr.y + uy * r1))
            return p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        func hand(_ deg: Double, _ len: CGFloat, _ w: CGFloat) {
            // 細頸：軸心到 18% 是細桿，後面才是寬的指針（Apple 錶的指針結構）
            let neck = handPath(deg, from: 0, to: len * 0.2, width: w * 0.32)
            let blade = handPath(deg, from: len * 0.2, to: len, width: w)
            for p in [neck, blade] {
                g.saveGState()
                g.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: NSColor(white: 0, alpha: 0.28).cgColor)
                g.addPath(p); g.setFillColor(NSColor.white.cgColor); g.fillPath()
                g.restoreGState()
                g.addPath(p); g.setStrokeColor(ink.withAlphaComponent(0.85).cgColor); g.setLineWidth(3); g.strokePath()
                g.addPath(p); g.setFillColor(NSColor.white.cgColor); g.fillPath()
            }
        }
        hand(hr * 30, 250, 30)
        hand(m * 6, 400, 22)
        // 秒針
        let sa = CGFloat(s * 6 * .pi / 180)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: NSColor(white: 0, alpha: 0.25).cgColor)
        g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(5); g.setLineCap(.round)
        g.move(to: CGPoint(x: ctr.x - sin(sa) * 70, y: ctr.y + cos(sa) * 70))
        g.addLine(to: CGPoint(x: ctr.x + sin(sa) * 440, y: ctr.y - cos(sa) * 440)); g.strokePath()
        g.restoreGState()
        // 軸心：白圈黑點
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: 512 - 15, y: 512 - 15, width: 30, height: 30))
        g.setStrokeColor(ink.withAlphaComponent(0.8).cgColor); g.setLineWidth(2.5)
        g.strokeEllipse(in: CGRect(x: 512 - 15, y: 512 - 15, width: 30, height: 30))
        g.setFillColor(srgb(0x3a9459).cgColor); g.fillEllipse(in: CGRect(x: 512 - 6, y: 512 - 6, width: 12, height: 12))
    }
    /// 秒針一秒一格
    func tickAnalogFace(_ now: Double) -> Bool {
        let s = Calendar.current.component(.second, from: Date())
        if s != analogLastSecond { analogLastSecond = s; return true }
        return false
    }
}
