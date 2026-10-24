// 浮雕指針（照 HomeView 的粉色類比錶面）：數字刻進同色的底、沿圓周轉向，6 點由膠囊（👀）取代；
// 酒紅色 Apple 式指針（細頸＋粗圓桿）、桃紅細秒針。表盤是靜態層（快取），每秒只重畫指針。

import AppKit

nonisolated(unsafe) private var embossedDialCache: (key: String, image: CGImage)?
nonisolated(unsafe) private var embossedLastSecond = -1

extension Face {
    private static let embBg0: UInt32 = 0xe4bfbd, embBg1: UInt32 = 0xc89b9b

    private func drawEmbossedDial(_ g: CGContext) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bg = CGGradient(colorsSpace: cs, colors: [srgb(Self.embBg0).cgColor, srgb(Self.embBg1).cgColor] as CFArray, locations: [0, 1])!
        g.drawRadialGradient(bg, startCenter: CGPoint(x: 375, y: 273), startRadius: 68, endCenter: CGPoint(x: 512, y: 512), endRadius: 887,
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let k = 1024 / 600.0
        let font = FaceType.sf(92 * k, .regular, mono: false)
        let dark = srgb(0x7a3a40), light = srgb(0xfff2f0)
        for (n, d) in [(12, 0), (1, 30), (2, 60), (3, 90), (4, 120), (5, 150), (7, 210), (8, 240), (9, 270), (10, 300), (11, 330)] {
            let a = CGFloat(d) * .pi / 180
            let shape = GlyphShape("\(n)", font: font).centered(at: .zero)
            let t = CGAffineTransform(translationX: 512 + sin(a) * 248 * k, y: 512 - cos(a) * 248 * k).rotated(by: a)
            let p = shape.transformed(t).path
            let b = p.boundingBoxOfPath.insetBy(dx: -30, dy: -30)
            // 刻痕：光從左上來。字內左上的壁在陰影裡（暗），右下的壁受光（亮）。
            g.saveGState()
            g.addPath(p); g.clip()
            for (off, col, blur) in [(CGSize(width: 3.6, height: -3.6), dark.withAlphaComponent(0.8), CGFloat(1.8)),
                                     (CGSize(width: -2.4, height: 2.4), light.withAlphaComponent(0.95), CGFloat(1.4))] {
                g.saveGState()
                g.setShadow(offset: off, blur: blur, color: col.cgColor)
                g.beginTransparencyLayer(auxiliaryInfo: nil)
                g.setFillColor(NSColor.black.cgColor); g.fill(b)
                g.setBlendMode(.clear); g.addPath(p); g.fillPath()
                g.endTransparencyLayer()
                g.restoreGState()
            }
            g.restoreGState()
            // 刻痕外緣：右下一圈極細亮邊（凹槽邊緣擋住的光）
            g.saveGState()
            g.addRect(b); g.addPath(p); g.clip(using: .evenOdd)
            g.setShadow(offset: CGSize(width: -1.6, height: 1.6), blur: 1.2, color: light.withAlphaComponent(0.55).cgColor)
            g.addPath(p); g.setFillColor(srgb(Self.embBg1).cgColor); g.fillPath()
            g.restoreGState()
        }
    }

    func renderEmbossedFace(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let sc = renderPixelScale, px = Int((1024 * sc).rounded())
        let key = "\(px)"
        if let c = embossedDialCache, c.key == key { drawUpright(g, c.image, in: full) }
        else {
            let img = makeImage(px, px) { c in
                if sc != 1 { c.scaleBy(x: sc, y: sc) }
                self.drawEmbossedDial(c)
            }
            embossedDialCache = (key, img)
            drawUpright(g, img, in: full)
        }
        drawIsland(g, at: CGPoint(x: 512, y: 884), scale: 240 / (420 * 1.4), liveAt: CGPoint(x: 512, y: 884), now: now)

        // 指針
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Self.displayDate)
        let s = Double(c.second ?? 0), m = Double(c.minute ?? 0) + s / 60, hr = Double((c.hour ?? 0) % 12) + m / 60
        let ctr = CGPoint(x: 512, y: 512), k = 1024 / 600.0
        let maroon = srgb(0x6c2a2e), pink = srgb(0xff47a0)
        func seg(_ deg: Double, _ r0: CGFloat, _ r1: CGFloat, _ w: CGFloat) -> CGPath {
            let a = CGFloat(deg * .pi / 180), ux = sin(a), uy = -cos(a)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: ctr.x + ux * r0, y: ctr.y + uy * r0)); p.addLine(to: CGPoint(x: ctr.x + ux * r1, y: ctr.y + uy * r1))
            return p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        func hand(_ deg: Double, _ len: CGFloat, _ w: CGFloat) {
            let p = CGMutablePath()
            p.addPath(seg(deg, 0, 34 * k, 5 * k)); p.addPath(seg(deg, 34 * k, len * k, w * k))
            g.saveGState()
            g.setShadow(offset: CGSize(width: 6, height: -12), blur: 16, color: srgb(0x461419, 0.5).cgColor)
            g.addPath(p); g.setFillColor(maroon.cgColor); g.fillPath()
            g.restoreGState()
        }
        hand(hr * 30, 158, 17)
        hand(m * 6, 238, 14)
        if secondsVisible {   // 沒人在看時收起秒針
            let sa = CGFloat(s * 6 * .pi / 180)
            g.saveGState()
            g.setShadow(offset: CGSize(width: 4, height: -7), blur: 10, color: srgb(0x461419, 0.3).cgColor)
            g.setStrokeColor(pink.cgColor); g.setLineWidth(2.6 * k); g.setLineCap(.round)
            g.move(to: ctr); g.addLine(to: CGPoint(x: ctr.x + sin(sa) * 268 * k, y: ctr.y - cos(sa) * 268 * k)); g.strokePath()
            g.restoreGState()
        }
        g.setFillColor(pink.cgColor); g.fillEllipse(in: CGRect(x: 512 - 8 * k, y: 512 - 8 * k, width: 16 * k, height: 16 * k))
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: 512 - 3 * k, y: 512 - 3 * k, width: 6 * k, height: 6 * k))
    }

    /// 秒針一秒一格
    func tickEmbossedFace(_ now: Double) -> Bool {
        let s = secondsVisible ? Calendar.current.component(.second, from: Date()) : -1
        if s != embossedLastSecond { embossedLastSecond = s; return true }
        return false
    }
}
