// 錶面「模組」：照 HomeView 的 Modular——淡淡的灰藍底，不用卡片，四塊資訊直接排在底上：
// 左上「週 月」＋超大的日；右上一隻帶分鐘刻度的指針鐘；左下正在播放（沒有就 CarPlay）；
// 右下一個大數字（電量；沒電池就下一個行程）。島（👀）站在正中間的縫裡。

import AppKit

extension Face {
    func renderModularV2(_ g: CGContext, _ now: Double) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bg = CGGradient(colorsSpace: cs, colors: [srgb(0xa9bcbd).cgColor, srgb(0x93a9ab).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])
        let ink = srgb(0x121416), soft = srgb(0x121416, 0.62)
        let date = Self.displayDate

        // ── 左上：週 月 ＋ 日
        let wdMonth = L10n.language == .en ? Self.formatter("EEE MMM", raw: true).string(from: date)   // 「Thu Oct」，照 Apple 的寫法
            : Self.formatter("EEEEMMM").string(from: date)
        drawLeft(g, wdMonth, font: FaceType.sf(64, .semibold, mono: false), x: 70, y: 132, color: ink)
        let day = String(Calendar.current.component(.day, from: date))
        let dayShape = GlyphShape(day, font: FaceType.numeric(.sf, 400, ["wght": 600, "wdth": 100])).tall(height: 228, stretch: 1.0, at: CGPoint(x: 72, y: 176), anchorX: 0)
        fillShape(g, dayShape, ink)

        // ── 右上：指針鐘
        drawModularClock(g, center: CGPoint(x: 766, y: 268), radius: 206, date: date, ink: ink)

        // ── 中間：島
        drawIsland(g, at: CGPoint(x: 512, y: 548), scale: 0.4, liveAt: CGPoint(x: 512, y: 548), now: now)

        // ── 左下：正在播放／CarPlay
        let art = CGRect(x: 72, y: 616, width: 196, height: 196)
        if let np = nowPlaying.shown {
            artwork(g, art, seed: np.title)
            let tf = FaceType.sf(30, .bold, mono: false)
            drawLeft(g, Self.clipped(np.title.uppercased(), tf, 400), font: tf, x: 72, y: 862, color: ink, kern: 0.3)
            let af = FaceType.sf(29, .medium, mono: false)
            drawLeft(g, Self.clipped(np.artist, af, 400), font: af, x: 72, y: 900, color: soft)
            let pill = CGRect(x: 72, y: 924, width: 150, height: 58)
            g.setFillColor(NSColor(white: 1, alpha: 0.32).cgColor)
            g.addPath(CGPath(roundedRect: pill, cornerWidth: 29, cornerHeight: 29, transform: nil)); g.fillPath()
            drawSymbol(g, np.playing ? "pause.fill" : "play.fill", in: CGRect(x: pill.minX + 24, y: pill.midY - 12, width: 24, height: 24), color: ink)
            drawLeft(g, np.playing ? L("modular.pause", "暂停") : L("modular.play", "播放"), font: FaceType.sf(28, .semibold, mono: false),
                     x: pill.minX + 60, y: pill.midY + 10, color: ink)
        } else {
            // CarPlay：藍色方塊圖示＋狀態
            let r = CGRect(x: 72, y: 616, width: 196, height: 196)
            let grad = CGGradient(colorsSpace: cs, colors: [srgb(0x4aa3ff).cgColor, srgb(0x1f6fe0).cgColor] as CFArray, locations: [0, 1])!
            g.saveGState()
            g.addPath(CGPath(roundedRect: r, cornerWidth: 44, cornerHeight: 44, transform: nil)); g.clip()
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
            g.restoreGState()
            drawSymbol(g, "car.fill", in: r.insetBy(dx: 46, dy: 56), color: .white)
            let sp = statusParts
            // 狀態字長（英文）就折成兩行，不截斷
            let tf = FaceType.sf(32, .bold, mono: false)
            let lines = Self.wrap(sp.title, tf, 410, maxLines: 2)
            for (i, l) in lines.enumerated() { drawLeft(g, l, font: tf, x: 72, y: 862 + CGFloat(i) * 38, color: ink) }
            if lines.count == 1, let hint = sp.hint {   // 兩行就不再放提示
                let hf = FaceType.sf(29, .medium, mono: false)
                drawLeft(g, Self.clipped(hint, hf, 400), font: hf, x: 72, y: 904, color: soft)
            }
        }

        // ── 右下：一個大數字
        let x0: CGFloat = 556
        if let b = battery {
            let symbol = b.charging ? "battery.100percent.bolt" : (b.percent > 60 ? "battery.100percent" : (b.percent > 25 ? "battery.50percent" : "battery.25percent"))
            drawSymbol(g, symbol, in: CGRect(x: x0, y: 618, width: 56, height: 30), color: b.percent <= 20 && !b.charging ? srgb(0xd7352b) : ink)
            drawLeft(g, L("battery.title", "电量"), font: FaceType.sf(30, .semibold, mono: false), x: x0 + 70, y: 644, color: ink)
            let big = GlyphShape("\(b.percent)%", font: FaceType.sf(400, .semibold)).tall(height: 168, stretch: 1.0, at: CGPoint(x: x0, y: 690), anchorX: 0, maxWidth: 400)
            fillShape(g, big, ink)
            drawLeft(g, Self.batteryState(b), font: FaceType.sf(30, .semibold, mono: false), x: x0, y: 912, color: soft)
        } else {
            drawSymbol(g, "calendar", in: CGRect(x: x0, y: 616, width: 36, height: 34), color: srgb(0xd7352b))
            drawLeft(g, L("calendar.next", "下一个行程"), font: FaceType.sf(30, .semibold, mono: false), x: x0 + 50, y: 644, color: ink)
            switch calendarTile {
            case .event(let e):
                let t = e.allDay ? L("calendar.allDay", "全天") : Self.formatter("HH:mm", raw: true).string(from: e.start)
                fillShape(g, GlyphShape(t, font: FaceType.sf(400, .semibold)).tall(height: 150, stretch: 1.0, at: CGPoint(x: x0, y: 696), anchorX: 0, maxWidth: 400), ink)
                let tf = FaceType.sf(32, .semibold, mono: false)
                drawLeft(g, Self.clipped(e.title.isEmpty ? L("calendar.untitled", "（无标题）") : e.title, tf, 400), font: tf, x: x0, y: 912, color: soft)
            default:
                let msg: String
                switch calendarTile {
                case .empty: msg = L("calendar.empty", "今天没有行程")
                case .denied: msg = L("calendar.denied", "行事历未授权")
                default: msg = L("calendar.notConnected", "尚未连接行事历")
                }
                let tf = FaceType.sf(44, .bold, mono: false)
                drawLeft(g, Self.clipped(msg, tf, 410), font: tf, x: x0, y: 780, color: ink)
                if calendarTile == .notConnected {
                    drawLeft(g, L("calendar.hint", "右键 › 偏好设定"), font: FaceType.sf(29, .medium, mono: false), x: x0, y: 830, color: soft)
                }
            }
        }
    }

    /// Modular 的指針鐘：60 格刻度（整點粗長）、1–12 數字、黑色指針、細秒針
    private func drawModularClock(_ g: CGContext, center c: CGPoint, radius r: CGFloat, date: Date, ink: NSColor) {
        for i in 0..<60 {
            let a = CGFloat(i) * .pi / 30, major = i % 5 == 0
            let r0 = r - (major ? 20 : 12), sx = sin(a), cy = -cos(a)
            g.setStrokeColor(ink.withAlphaComponent(major ? 0.9 : 0.45).cgColor); g.setLineWidth(major ? 4 : 2.2); g.setLineCap(.round)
            g.move(to: CGPoint(x: c.x + sx * r0, y: c.y + cy * r0)); g.addLine(to: CGPoint(x: c.x + sx * r, y: c.y + cy * r)); g.strokePath()
        }
        let nf = FaceType.sf(40, .medium, mono: false)
        for h in 1...12 {
            let a = CGFloat(h) * .pi / 6, rr = r - 54
            let s = GlyphShape(String(h), font: nf).centered(at: CGPoint(x: c.x + sin(a) * rr, y: c.y - cos(a) * rr))
            fillShape(g, s, ink)
        }
        let comp = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let s = Double(comp.second ?? 0), m = Double(comp.minute ?? 0) + s / 60, h = Double((comp.hour ?? 0) % 12) + m / 60
        func hand(_ deg: Double, _ len: CGFloat, _ w: CGFloat) {
            let a = CGFloat(deg * .pi / 180)
            g.setStrokeColor(ink.cgColor); g.setLineWidth(w); g.setLineCap(.round)
            g.move(to: c); g.addLine(to: CGPoint(x: c.x + sin(a) * len * 0.16, y: c.y - cos(a) * len * 0.16)); g.setLineWidth(w * 0.45); g.strokePath()
            g.setLineWidth(w)
            g.move(to: CGPoint(x: c.x + sin(a) * len * 0.16, y: c.y - cos(a) * len * 0.16)); g.addLine(to: CGPoint(x: c.x + sin(a) * len, y: c.y - cos(a) * len)); g.strokePath()
        }
        hand(h * 30, r * 0.52, 12)
        hand(m * 6, r * 0.86, 9)
        let sa = CGFloat(s * 6 * .pi / 180)
        g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(3)
        g.move(to: CGPoint(x: c.x - sin(sa) * 30, y: c.y + cos(sa) * 30)); g.addLine(to: CGPoint(x: c.x + sin(sa) * r * 0.94, y: c.y - cos(sa) * r * 0.94)); g.strokePath()
        g.setFillColor(ink.cgColor); g.fillEllipse(in: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20))
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
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
        let path = CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil)
        g.addPath(path); g.setFillColor(srgb(p.1).cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState(); g.addPath(path); g.clip()
        let grad = CGGradient(colorsSpace: cs, colors: [srgb(p.0).cgColor, srgb(p.1).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
        drawSymbol(g, "music.note", in: r.insetBy(dx: 58, dy: 50), color: NSColor.white.withAlphaComponent(0.92))
    }
}
