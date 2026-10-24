// 錶面「模組」：照 HomeView 的 Modular——平的灰藍底，不用卡片，四格資訊直接排在底上：
// 左上「週 月」（週白、月深灰）＋超大的日；右上一隻帶 60 格刻度的指針鐘；左下正在播放（沒有就 CarPlay）；
// 右下那格住著島（👀，純黑膠囊），上面一行 HomePlay、下面一行電量（原本「島的口袋」的電量資訊收到這裡）。
// 座標照官方 tile_modular.png 量（600² 的圖去掉 14 px 邊框，×1024/572）。

import AppKit

extension Face {
    func renderModularV2(_ g: CGContext, _ now: Double) {
        g.setFillColor(srgb(0x93abb1).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let ink = srgb(0x0a0b0c), soft = srgb(0x3e4a4e), white = NSColor.white
        let date = Self.displayDate

        // ── 左上：週（白）月（深灰）＋ 日（大、黑、置中在這一行下面）
        let en = L10n.language == .en
        let wd = en ? Self.formatter("EEE", raw: true).string(from: date) : Self.formatter("EEE").string(from: date)
        let mo = en ? Self.formatter("MMM", raw: true).string(from: date) : Self.formatter("MMM").string(from: date)
        var df = FaceType.sf(86, .bold, mono: false)
        func width(_ t: String, _ f: NSFont) -> CGFloat { (t as NSString).size(withAttributes: [.font: f, .kern: -0.5]).width }
        let space = en ? " " : " "
        var lineW = width(wd + space + mo, df)
        if lineW > 470 { df = FaceType.sf(86 * 470 / lineW, .bold, mono: false); lineW = width(wd + space + mo, df) }
        let x0: CGFloat = 82
        drawLeft(g, wd + space, font: df, x: x0, y: 149, color: white, kern: -0.5)
        drawLeft(g, mo, font: df, x: x0 + width(wd + space, df), y: 149, color: soft, kern: -0.5)
        let day = String(Calendar.current.component(.day, from: date))
        let dayShape = GlyphShape(day, font: FaceType.numeric(.sf, 400, ["wght": 600, "wdth": 100]), kern: -6)
            .tall(height: 262, stretch: 1.0, at: CGPoint(x: x0 + lineW / 2, y: 193), anchorX: 0.5, maxWidth: 440)
        fillShape(g, dayShape, ink)

        // ── 右上：指針鐘
        drawModularClock(g, center: CGPoint(x: 761, y: 263), radius: 205, date: date, ink: ink)

        // ── 左下：正在播放／CarPlay
        let art = CGRect(x: 51, y: 543, width: 230, height: 230)
        if let np = nowPlaying.shown {
            artwork(g, art, seed: np.title)
            // 右邊一顆白色音符，標出這格是「音樂」
            drawLeft(g, "♫", font: FaceType.sf(64, .regular, mono: false), x: 428, y: 600, color: white)
            let tf = FaceType.sf(35, .bold, mono: false)
            drawLeft(g, Self.clipped(np.title.uppercased(), tf, 400), font: tf, x: 53, y: 823, color: ink, kern: 0.4)
            let af = FaceType.sf(35, .regular, mono: false)
            drawLeft(g, Self.clipped(np.artist, af, 400), font: af, x: 53, y: 866, color: soft)
            let pill = CGRect(x: 51, y: 892, width: 228, height: 80)
            g.setFillColor(NSColor(white: 0, alpha: 0.12).cgColor)
            g.addPath(CGPath(roundedRect: pill, cornerWidth: 40, cornerHeight: 40, transform: nil)); g.fillPath()
            let label = np.playing ? L("modular.pause", "暂停") : L("modular.play", "播放")
            let lf = FaceType.sf(38, .medium, mono: false)
            let lw = Typo.width(label, lf)
            let gx = pill.midX - (30 + 14 + lw) / 2
            drawSymbol(g, np.playing ? "pause.fill" : "play.fill", in: CGRect(x: gx, y: pill.midY - 16, width: 30, height: 32), color: ink)
            drawLeft(g, label, font: lf, x: gx + 44, y: pill.midY + 13, color: ink)
        } else if case .event(let e) = calendarTile {
            // 沒在播、但有下一個行程（設定 › 讀取行事曆）：像「行事曆」App 圖示的日期方塊＋紅色小標、行程名、時間
            g.saveGState()
            g.addPath(continuousRoundedRect(art, radius: art.width * 0.2237)); g.clip()
            g.setFillColor(NSColor.white.cgColor); g.fill(art)
            g.restoreGState()
            let wd = Self.formatter("EEE").string(from: e.start), day = Calendar.current.component(.day, from: e.start)
            let wf = FaceType.sf(30, .semibold, mono: false), df = FaceType.sfv(118, wght: 300, mono: false)
            drawLeft(g, wd, font: wf, x: art.midX - Typo.width(wd, wf) / 2, y: art.minY + 54, color: srgb(0xff3b30))
            let ds = String(day)
            drawLeft(g, ds, font: df, x: art.midX - Typo.width(ds, df) / 2, y: art.minY + 176, color: srgb(0x1c1c1e))
            drawLeft(g, L("calendar.next", "下一个行程").uppercased(), font: FaceType.sf(30, .bold, mono: false), x: 53, y: 823, color: srgb(0xc6281f), kern: 0.4)
            let tf = FaceType.sf(35, .bold, mono: false)
            drawLeft(g, Self.clipped(e.title.isEmpty ? L("calendar.untitled", "（无标题）") : e.title, tf, 420), font: tf, x: 53, y: 866, color: ink)
            let hf = FaceType.sf(35, .regular, mono: false)
            drawLeft(g, CalendarLogic.range(e), font: hf, x: 53, y: 909, color: soft)
        } else {
            // 沒在播：照官方「正在播放」小工具的空狀態——灰色封面＋音符、「未在播放」、灰掉的播放膠囊；
            // 第二行放連線狀態（例如「重按連上 iPhone」），不再畫像 App 圖示的藍色 CarPlay 方塊
            g.saveGState()
            g.addPath(CGPath(roundedRect: art, cornerWidth: 18, cornerHeight: 18, transform: nil)); g.clip()
            g.setFillColor(NSColor(white: 0, alpha: 0.10).cgColor); g.fill(art)
            g.restoreGState()
            drawSymbol(g, "music.note", in: art.insetBy(dx: 70, dy: 66), color: NSColor(white: 1, alpha: 0.75), weight: .medium)
            drawLeft(g, "♫", font: FaceType.sf(64, .regular, mono: false), x: 428, y: 600, color: white)
            let tf = FaceType.sf(35, .bold, mono: false)
            drawLeft(g, Self.clipped(L("modular.notPlaying", "未在播放").uppercased(), tf, 400), font: tf, x: 53, y: 823, color: ink, kern: 0.4)
            var hs: CGFloat = 35
            while hs > 26, Typo.width(statusParts.title, FaceType.sf(hs, .regular, mono: false)) > 420 { hs -= 1 }   // 先縮字，真的放不下才截
            let hf = FaceType.sf(hs, .regular, mono: false)
            drawLeft(g, Self.clipped(statusParts.title, hf, 420), font: hf, x: 53, y: 866, color: soft)
            let pill = CGRect(x: 51, y: 892, width: 228, height: 80)
            g.setFillColor(NSColor(white: 0, alpha: 0.07).cgColor)
            g.addPath(CGPath(roundedRect: pill, cornerWidth: 40, cornerHeight: 40, transform: nil)); g.fillPath()
            let label = L("modular.play", "播放"), lf = FaceType.sf(38, .medium, mono: false)
            let lw = Typo.width(label, lf), gx = pill.midX - (30 + 14 + lw) / 2, dim = ink.withAlphaComponent(0.4)
            drawSymbol(g, "play.fill", in: CGRect(x: gx, y: pill.midY - 16, width: 30, height: 32), color: dim)
            drawLeft(g, label, font: lf, x: gx + 44, y: pill.midY + 13, color: dim)
        }

        // ── 右下：島住的那一格——上面一行 HomePlay，中間純黑膠囊，下面一行電量
        let cx: CGFloat = 548
        drawLeft(g, "HomePlay", font: FaceType.sf(40, .semibold, mono: false), x: cx, y: 576, color: white)
        let line: String, lineColor: NSColor
        if let b = battery {
            let state = Self.batteryState(b)
            line = en ? "\(state) · \(b.percent)%" : "\(state)・\(b.percent)%"
            lineColor = b.percent <= 20 && !b.charging ? srgb(0xc6281f) : ink
        } else {
            line = L("battery.macPlugged", "这台 Mac 接着电源"); lineColor = ink
        }
        let bf = FaceType.sf(36, .medium, mono: false)
        drawLeft(g, Self.clipped(line, bf, 440), font: bf, x: cx, y: 958, color: lineColor)
        drawIsland(g, at: CGPoint(x: cx + 162, y: 762), scale: 324 / 588, liveAt: CGPoint(x: 512, y: 762), now: now)
    }

    /// Modular 的指針鐘（照官方）：60 格刻度（整點黑、其餘灰）、1–12 數字、
    /// 黑色指針（細頸接粗桿、圓頭）、細白秒針（尾巴略過軸心）、軸心黑圈白環
    private func drawModularClock(_ g: CGContext, center c: CGPoint, radius r: CGFloat, date: Date, ink: NSColor) {
        g.setLineCap(.round)
        for i in 0..<60 {
            let a = CGFloat(i) * .pi / 30, major = i % 5 == 0
            let r0 = r - (major ? 17 : 15), sx = sin(a), cy = -cos(a)
            g.setStrokeColor(major ? ink.cgColor : ink.withAlphaComponent(0.42).cgColor); g.setLineWidth(major ? 4 : 2.6)
            g.move(to: CGPoint(x: c.x + sx * r0, y: c.y + cy * r0)); g.addLine(to: CGPoint(x: c.x + sx * r, y: c.y + cy * r)); g.strokePath()
        }
        let nf = FaceType.sf(43, .semibold, mono: false)
        for h in 1...12 {
            let a = CGFloat(h) * .pi / 6, rr = r * 0.755
            let s = GlyphShape(String(h), font: nf, kern: -1).centered(at: CGPoint(x: c.x + sin(a) * rr, y: c.y - cos(a) * rr))
            fillShape(g, s, ink)
        }
        let comp = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let s = Double(comp.second ?? 0), m = Double(comp.minute ?? 0) + s / 60, h = Double((comp.hour ?? 0) % 12) + m / 60
        func hand(_ deg: Double, _ len: CGFloat, _ w: CGFloat) {
            let a = CGFloat(deg * .pi / 180), ux = sin(a), uy = -cos(a), neck: CGFloat = 28
            let p = CGMutablePath()
            p.addPath(Self.segment(c, ux, uy, 0, neck + 2, 4.6))
            p.addPath(Self.segment(c, ux, uy, neck, len, w))
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: NSColor(white: 0, alpha: 0.22).cgColor)
            g.addPath(p); g.setFillColor(ink.cgColor); g.fillPath()
            g.restoreGState()
        }
        hand(h * 30, r * 0.57, 11)
        hand(m * 6, r * 0.95, 11)
        if secondsVisible {   // 沒人在看時收起秒針
            let sa = CGFloat(s * 6 * .pi / 180)
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor(white: 0, alpha: 0.18).cgColor)
            g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(2.2); g.setLineCap(.butt)
            g.move(to: CGPoint(x: c.x - sin(sa) * 32, y: c.y + cos(sa) * 32)); g.addLine(to: CGPoint(x: c.x + sin(sa) * r, y: c.y - cos(sa) * r)); g.strokePath()
            g.restoreGState()
        }
        g.setFillColor(ink.cgColor); g.fillEllipse(in: CGRect(x: c.x - 10.5, y: c.y - 10.5, width: 21, height: 21))
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
        g.setFillColor(srgb(0x93abb1).cgColor); g.fillEllipse(in: CGRect(x: c.x - 3.2, y: c.y - 3.2, width: 6.4, height: 6.4))
    }

    /// 從軸心 c 沿 (ux, uy) 方向、r0 到 r1 的一段圓頭粗線（填色用的外框）
    static func segment(_ c: CGPoint, _ ux: CGFloat, _ uy: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x + ux * r0, y: c.y + uy * r0))
        p.addLine(to: CGPoint(x: c.x + ux * r1, y: c.y + uy * r1))
        return p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// 沒有專輯封面時：用歌名決定一組漸層色，中間一個音符（每首歌顏色固定）
    private func artwork(_ g: CGContext, _ r: CGRect, seed: String) {
        let palettes: [(UInt32, UInt32)] = [(0x5fa8ff, 0x2853c7), (0xff8a65, 0xd1426b), (0x7ad6a6, 0x2f8f74), (0xc69cff, 0x6b4bd8), (0xffcf5c, 0xf08a24)]
        var hsh: UInt32 = 5381
        for u in seed.unicodeScalars { hsh = (hsh &* 33) &+ u.value }
        let p = palettes[Int(hsh % UInt32(palettes.count))]
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor(white: 0, alpha: 0.18).cgColor)
        let path = CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil)
        g.addPath(path); g.setFillColor(srgb(p.1).cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState(); g.addPath(path); g.clip()
        let grad = CGGradient(colorsSpace: cs, colors: [srgb(p.0).cgColor, srgb(p.1).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
        drawSymbol(g, "music.note", in: r.insetBy(dx: 70, dy: 62), color: NSColor.white.withAlphaComponent(0.92))
    }
}

nonisolated(unsafe) private var modularLastSecond = -1
extension Face {
    /// 秒針每秒走一格
    func tickModularFace(_ now: Double) -> Bool {
        let s = secondsVisible ? Int(Date().timeIntervalSince1970) : -1
        if s == modularLastSecond { return false }
        modularLastSecond = s; return true
    }
}
