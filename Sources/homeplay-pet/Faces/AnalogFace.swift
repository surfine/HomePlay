// 錶面「Typograph」（原「指針」）：照 HomeView 的 Typograph——12／3／6／9 四個 SF Pro 一般粗細的超大數字互相疊壓、
// 幾乎撐滿整面；指針（細頸接粗桿、圓頭）帶很淡的暗影，細秒針從軸心上方一路貫穿到下緣；
// 配色照現在的 Look 四層色票：底＝background、大數字＝numerals、指針與秒針＝secondary（官方 12 種 Look 同一套）。
// 左下一行「週 日」，島（👀，純黑膠囊）在右下角；兩者都避開數字，指針從膠囊上面掃過。
// 座標照官方 tile_typograph.png 量（600² 的圖去掉 14 px 邊框，×1024/572）。

import AppKit

/// 上次畫的秒數（擴展裡不能加儲存屬性）
nonisolated(unsafe) private var analogLastSecond = -1
nonisolated(unsafe) private var analogNumeralCache: [GlyphShape]?

extension Face {
    func renderAnalogFace(_ g: CGContext, _ now: Double) {
        let look = HPLook.faceLook(.analog), ic = HPAccessibility.increaseContrast
        let material = look.numerals == 0x000000
        // 1:1：官方形象照的 Typograph＝深綠底、近黑數字、白指針。用戶主動選 Look 才換成 token。
        let factory = HPLook.usesFactoryPalette
        let bg = factory ? srgb(0x3E935C) : look.background_color
        g.setFillColor(bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        // 彩色數字版的數字是淺色（#94CFFF 這類）：增加對比時往黑壓一些
        let ink = factory ? srgb(0x050806)
            : (ic && !material ? (look.numerals_color.blended(withFraction: 0.35, of: .black) ?? look.numerals_color) : look.numerals_color)
        // 指針：官方是白；Look 版用 secondary。增加對比時材質版改黑，避免白壓黑
        let handColor = factory ? NSColor.white : (ic && material ? NSColor.black : look.secondary_color)
        // 日期：官方跟數字同色（近黑）；Look 版材質版同數字色、彩色版用 secondary
        let dateColor = factory ? ink : (material ? ink : look.secondary_color)
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
        drawLeft(g, "\(wd) \(c.day ?? 1)", font: FaceType.sf(58, .bold, mono: false), x: 47, y: 968, color: dateColor, kern: 0.3)

        // 島在右下角（稿：face('Typograph') 寬 150／600），指針從上面掃過。寬 224（稿是 256）：讓開 6 的右緣，膠囊不碰數字
        let cw: CGFloat = 224
        let corner = Screen.cornerCapsuleCenter(.bottomRight, width: cw, height: cw / 2.69)   // 右端半圓與螢幕圓角同心
        drawIsland(g, at: corner, scale: cw / 588, liveAt: CGPoint(x: 512, y: 880), now: now)

        // 指針：白色、細頸接粗桿、圓頭，柔和暗影；秒針細長白色，尾巴略過軸心
        let s = Double(c.second ?? 0), m = Double(c.minute ?? 0) + s / 60, hr = Double((c.hour ?? 0) % 12) + m / 60
        let ctr = CGPoint(x: 504, y: 510)
        func hand(_ deg: Double, _ len: CGFloat, _ w: CGFloat) {
            let a = CGFloat(deg * .pi / 180), ux = sin(a), uy = -cos(a), neck: CGFloat = 76
            let p = CGMutablePath()
            p.addPath(Self.segment(ctr, ux, uy, 0, neck + 4, 7))
            p.addPath(Self.segment(ctr, ux, uy, neck, len, w))
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -6), blur: factory ? 14 : 8, color: NSColor(white: 0, alpha: factory ? 0.38 : 0.16).cgColor)
            g.addPath(p); g.setFillColor(handColor.cgColor); g.fillPath()
            g.restoreGState()
        }
        hand(hr * 30, 275, 31)
        hand(m * 6, 460, 29)
        // 秒針：細、貫穿（尾巴 79、往前 476）
        if secondsVisible {   // 沒人在看時收起秒針（像 Apple Watch 的常亮模式）
            let sa = CGFloat(s * 6 * .pi / 180)
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: NSColor(white: 0, alpha: 0.14).cgColor)
            g.setStrokeColor(handColor.cgColor); g.setLineWidth(4.5); g.setLineCap(.butt)
            g.move(to: CGPoint(x: ctr.x - sin(sa) * 79, y: ctr.y + cos(sa) * 79))
            g.addLine(to: CGPoint(x: ctr.x + sin(sa) * 476, y: ctr.y - cos(sa) * 476)); g.strokePath()
            g.restoreGState()
        }
        // 軸心：指針色的圈、中間一點底色
        g.setFillColor(handColor.cgColor); g.fillEllipse(in: CGRect(x: ctr.x - 21, y: ctr.y - 21, width: 42, height: 42))
        g.setFillColor(bg.cgColor); g.fillEllipse(in: CGRect(x: ctr.x - 7.5, y: ctr.y - 7.5, width: 15, height: 15))
    }
    /// 秒針一秒一格
    func tickAnalogFace(_ now: Double) -> Bool {
        let s = secondsVisible ? Calendar.current.component(.second, from: Date()) : -1
        if s != analogLastSecond { analogLastSecond = s; return true }
        return false
    }
}
