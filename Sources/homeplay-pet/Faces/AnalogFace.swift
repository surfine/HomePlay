// 錶面「Typograph」（原「指針」）：照 HomeView 的 Typograph——12／3／6／9 四個 SF Pro 一般粗細的超大數字互相疊壓、
// 幾乎撐滿整面；白色指針（細頸接粗桿、圓頭）帶柔和的暗影，細白秒針從軸心上方一路貫穿到下緣；
// 左下一行「週 日」，島（👀，純黑膠囊）在右下角，指針從它上面掃過。
// 座標照官方 tile_typograph.png 量（600² 的圖去掉 14 px 邊框，×1024/572）。

import AppKit

/// 上次畫的秒數（擴展裡不能加儲存屬性）
nonisolated(unsafe) private var analogLastSecond = -1
nonisolated(unsafe) private var analogNumeralCache: [GlyphShape]?

extension Face {
    func renderAnalogFace(_ g: CGContext, _ now: Double) {
        let green = srgb(0x3e935c)
        g.setFillColor(green.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let ink = srgb(0x050806)
        // 四個數字：SF Pro Regular，字高約 0.43 面高，故意互相壓到（Typograph 的味道）
        if analogNumeralCache == nil {
            let f = FaceType.sf(400, .light, mono: false)
            func digit(_ d: String, h: CGFloat, x: CGFloat, top: CGFloat, anchor: CGFloat) -> GlyphShape {
                GlyphShape(d, font: f).tall(height: h, stretch: 1.0, at: CGPoint(x: x, y: top), anchorX: anchor)
            }
            analogNumeralCache = [
                digit("1", h: 427, x: 243, top: 38, anchor: 0),     // 「12」的 1、2 分開放：兩字緊靠（官方的字距比預設緊）
                digit("2", h: 424, x: 691, top: 41, anchor: 1),
                digit("9", h: 443, x: 24, top: 293, anchor: 0),
                digit("3", h: 439, x: 986, top: 297, anchor: 1),
                digit("6", h: 443, x: 342, top: 548, anchor: 0),
            ]
        }
        for s in analogNumeralCache ?? [] { fillShape(g, s, ink) }

        // 日期：週 + 日，粗體小字（英文全大寫，照官方「WED 1」）
        let date = Self.displayDate
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .weekday, .day], from: date)
        let wd = L10n.language == .en ? Self.formatter("EEE", raw: true).string(from: date).uppercased() : Self.formatter("EEE").string(from: date)
        drawLeft(g, "\(wd) \(c.day ?? 1)", font: FaceType.sf(58, .bold, mono: false), x: 47, y: 968, color: ink, kern: 0.3)

        // 島在右下角（寬 ≈ 256，稿：face('Typograph') 寬 150／600、中心 (492, 532)／600），指針從上面掃過
        let corner = Screen.cornerCapsuleCenter(.bottomRight, width: 256, height: 256 / 2.69)   // 右端半圓與螢幕圓角同心
        drawIsland(g, at: corner, scale: 256 / 588, liveAt: CGPoint(x: 512, y: 880), now: now)

        // 指針：白色、細頸接粗桿、圓頭，柔和暗影；秒針細長白色，尾巴略過軸心
        let s = Double(c.second ?? 0), m = Double(c.minute ?? 0) + s / 60, hr = Double((c.hour ?? 0) % 12) + m / 60
        let ctr = CGPoint(x: 504, y: 510)
        func hand(_ deg: Double, _ len: CGFloat, _ w: CGFloat) {
            let a = CGFloat(deg * .pi / 180), ux = sin(a), uy = -cos(a), neck: CGFloat = 76
            let p = CGMutablePath()
            p.addPath(Self.segment(ctr, ux, uy, 0, neck + 4, 7))
            p.addPath(Self.segment(ctr, ux, uy, neck, len, w))
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor(white: 0, alpha: 0.38).cgColor)
            g.addPath(p); g.setFillColor(NSColor.white.cgColor); g.fillPath()
            g.restoreGState()
        }
        hand(hr * 30, 275, 31)
        hand(m * 6, 460, 29)
        // 秒針：細、貫穿（尾巴 79、往前 476）
        if secondsVisible {   // 沒人在看時收起秒針（像 Apple Watch 的常亮模式）
            let sa = CGFloat(s * 6 * .pi / 180)
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: NSColor(white: 0, alpha: 0.3).cgColor)
            g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(4.5); g.setLineCap(.butt)
            g.move(to: CGPoint(x: ctr.x - sin(sa) * 79, y: ctr.y + cos(sa) * 79))
            g.addLine(to: CGPoint(x: ctr.x + sin(sa) * 476, y: ctr.y - cos(sa) * 476)); g.strokePath()
            g.restoreGState()
        }
        // 軸心：白圈、中間一點綠
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: ctr.x - 21, y: ctr.y - 21, width: 42, height: 42))
        g.setFillColor(srgb(0x2f7a4a).cgColor); g.fillEllipse(in: CGRect(x: ctr.x - 10, y: ctr.y - 10, width: 20, height: 20))
        g.setFillColor(green.cgColor); g.fillEllipse(in: CGRect(x: ctr.x - 7.5, y: ctr.y - 7.5, width: 15, height: 15))
    }
    /// 秒針一秒一格
    func tickAnalogFace(_ now: Double) -> Bool {
        let s = secondsVisible ? Calendar.current.component(.second, from: Date()) : -1
        if s != analogLastSecond { analogLastSecond = s; return true }
        return false
    }
}
