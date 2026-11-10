// 「世界」錶面（稿 scratchpad/worldclock/Face.dc.html，512 設計單位 ×2）：夜藍底上整面 1960 年代點陣世界地圖，
// 陸地點白天那半邊亮、夜裡那半邊暗（照現在的太陽直射點與季節赤緯，Shell/Apps/StationClock.swift 的 DotMap），城市是橘點；
// 上方本地時間的玻璃大數字（跟島錶面同一條路：Face.drawClockDigits → SystemGlass .portraitFrosted；減少透明度／動態效果退回實色），
// 底下一行「城市 · 日期」，最下面三座城市的玻璃膠囊（白天黃點、晚上藍點＋當地時間）。城市取世界時鐘的清單（本地之後的前三座）。
// 靜態層（底、地圖、大數字、膠囊）每分鐘畫一次；👀 膠囊每幀畫在上面（造型照規定不動）。

import AppKit

nonisolated(unsafe) private var worldStatic: (key: String, image: CGImage)?
nonisolated(unsafe) private var worldLastMinute = -1

extension Face {
    private static let worldMapOrigin = CGPoint(x: 8, y: 440)
    private static let worldMapStep: CGFloat = 14

    func renderWorldFace(_ g: CGContext, _ now: Double) {
        let date = Self.displayDate
        let cities = WorldClockApp.cities()
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let key = "world|\(Int(date.timeIntervalSince1970 / 60))|\(L10n.language.rawValue)|\(Int(renderPixelScale * 100))|\(HPAccessibility.reduceTransparency)"
            + "|\(HPAccessibility.increaseContrast)|\(HPMotion.reduceMotion)|\(Self.uses12Hour)|\(cities.map(\.0.identifier).joined(separator: ","))"
        if let c = worldStatic, c.key == key {
            drawUpright(g, c.image, in: full); Face.cacheHits += 1
        } else {
            let sc = renderPixelScale, px = Int((1024 * sc).rounded())
            let img = makeImage(px, px) { c in
                if sc != 1 { c.scaleBy(x: sc, y: sc) }
                self.drawWorldStatic(c, cities, date)
            }
            worldStatic = (key, img)
            drawUpright(g, img, in: full); Face.cacheMisses += 1
        }
        // VoiceOver：本地時間、每個膠囊「城市 時間 白天／晚上」
        HPAX.note(g, CGRect(x: 212, y: 200, width: 600, height: 180), .text, "\(WorldClockApp.name(for: .current)) \(Face.shortTime(date))", value: Self.dateLine(date), shape: .rounded(24))
        for (r, tz, name) in worldChips(cities, date) {
            HPAX.note(g, r, .text, WorldClockApp.axLabel(name, Face.shortTime(date, timeZone: tz), night: WorldClockApp.isNight(tz, date)))
        }
        // 👀 膠囊：頂端置中（稿：寬 208 設計單位、離頂 24）
        let at = CGPoint(x: 512, y: 110)
        drawIsland(g, at: at, scale: 416 / (420 * 1.4), liveAt: at, now: now)
    }

    func tickWorldFace(_ now: Double) -> Bool {
        let m = Int(Self.displayDate.timeIntervalSince1970 / 60)
        if m != worldLastMinute { worldLastMinute = m; return true }
        return false
    }

    /// 底與地圖（大數字的玻璃也拿它當背景）：放射漸層夜藍、點陣陸地、城市橘點
    private func drawWorldBackground(_ c: CGContext, _ cities: [(TimeZone, String)], _ date: Date) {
        // radial-gradient(120% 90% at 50% 40%, #1b2443 0%, #0d1124 70%)
        if let gr = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [srgb(0x1B2443).cgColor, srgb(0x0D1124).cgColor] as CFArray, locations: [0, 0.7]) {
            c.saveGState(); c.translateBy(x: 512, y: 1024 * 0.4); c.scaleBy(x: 1, y: 0.9 / 1.2)
            c.drawRadialGradient(gr, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1024 * 1.2, options: [.drawsAfterEndLocation])
            c.restoreGState()
        }
        let ic = HPAccessibility.increaseContrast
        DotMap.draw(c, origin: Self.worldMapOrigin, step: Self.worldMapStep, radius: 4.2, date: date,
                    day: NSColor(white: 1, alpha: 0.62), night: NSColor(white: 1, alpha: ic ? 0.28 : 0.16))
        for (tz, _) in cities {
            guard let co = WorldClockApp.coordinate(tz) else { continue }
            DotMap.pin(c, DotMap.point(lat: co.lat, lon: co.lon, origin: Self.worldMapOrigin, step: Self.worldMapStep), halo: 18, dot: 7.2, ring: 2.6, haloAlpha: 0.2)
        }
    }

    /// 膠囊裡的城市：本地之後最多三座；字級不低於 28，三座放不下就少放一座（不縮到桌上讀不到）
    private func worldChipCities(_ cities: [(TimeZone, String)], _ date: Date) -> [(TimeZone, String)] {
        var others = Array(cities.dropFirst().prefix(3))
        while others.count > 1, worldChipWidth(others, date, size: 28) > 1024 - 128 { others.removeLast() }
        return others
    }
    private func worldChipWidth(_ others: [(TimeZone, String)], _ date: Date, size: CGFloat) -> CGFloat {
        let nf = FaceType.sf(size, .semibold, mono: false), tf = FaceType.sf(size, .regular)
        return others.reduce(CGFloat(0)) { $0 + 112 + Typo.width($1.1, nf) + Typo.width(Face.shortTime(date, timeZone: $1.0), tf) } + CGFloat(others.count - 1) * 20
    }

    /// 底下的膠囊：寬度照字，整排置中
    private func worldChips(_ cities: [(TimeZone, String)], _ date: Date) -> [(CGRect, TimeZone, String)] {
        let others = worldChipCities(cities, date)
        guard !others.isEmpty else { return [] }
        let (nf, tf) = worldChipFonts(others, date)
        let ws = others.map { 32 + 16 + 16 + Typo.width($0.1, nf) + 16 + Typo.width(Face.shortTime(date, timeZone: $0.0), tf) + 32 }
        var x = 512 - (ws.reduce(0, +) + CGFloat(others.count - 1) * 20) / 2
        return others.enumerated().map { k, c in
            defer { x += ws[k] + 20 }
            return (CGRect(x: x, y: 1024 - 64 - 88, width: ws[k], height: 88), c.0, c.1)
        }
    }
    private func worldChipFonts(_ others: [(TimeZone, String)], _ date: Date) -> (NSFont, NSFont) {
        var size: CGFloat = 32   // 放得下就 32；最小 28（Design/README：次要字不低於 28）
        while size > 28, worldChipWidth(others, date, size: size) > 1024 - 128 { size -= 1 }
        return (FaceType.sf(size, .semibold, mono: false), FaceType.sf(size, .regular))
    }

    /// 靜態層：底＋地圖、玻璃大數字、「城市 · 日期」、三個膠囊
    private func drawWorldStatic(_ c: CGContext, _ cities: [(TimeZone, String)], _ date: Date) {
        drawWorldBackground(c, cities, date)
        let rt = HPAccessibility.reduceTransparency, ic = HPAccessibility.increaseContrast
        // 本地時間：細的大數字（稿 104 設計單位、字距 −0.04em），玻璃
        var look = ClockLook(); look.swatch = .white; look.glass = true
        // 對比照島：字重從 light 提到 regular（玻璃的面積夠才看得出材質），玻璃取樣的背景提亮一層——
        // 夜藍底直接當玻璃背景，字裡透出的也是夜藍，跟底幾乎分不開；提亮後字身像島那樣比底亮一階、亮緣清楚
        let shape = GlyphShape(Self.clock(date), font: FaceType.sf(208, .regular), kern: -8).centered(at: CGPoint(x: 512, y: 288))
        let clear = snapshotBackdrop(px: 512) { b in
            self.drawWorldBackground(b, cities, date)
            b.setFillColor(NSColor(white: 1, alpha: ic ? 0.42 : 0.32).cgColor); b.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        let small = snapshotBackdrop(px: 192) { b in self.drawWorldBackground(b, cities, date) }
        let frosted = blurredBackdrop(small, sigma: 10, key: "world|\(Int(date.timeIntervalSince1970 / 60))|\(ic)")
        drawClockDigits(c, [shape], look: look, clear: clear, frosted: frosted, alpha: 1)
        // 城市 · 日期
        drawCentered(c, "\(WorldClockApp.name(for: .current)) · \(Self.dateLine(date))", font: FaceType.sf(30, .regular, mono: false), kern: 0, y: 456,
                     color: NSColor(white: 1, alpha: ic ? 0.92 : 0.75))
        // 三座城市的玻璃膠囊
        let (nf, tf) = worldChipFonts(worldChipCities(cities, date), date)
        for (r, tz, name) in worldChips(cities, date) {
            let path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
            c.addPath(path); c.setFillColor((rt ? srgb(0x283052) : NSColor(white: 1, alpha: 0.12)).cgColor); c.fillPath()
            c.addPath(path); c.setStrokeColor(NSColor(white: 1, alpha: ic ? 0.6 : 0.28).cgColor); c.setLineWidth(2); c.strokePath()
            let night = WorldClockApp.isNight(tz, date)
            c.setFillColor((night ? srgb(0x8E9BFF) : srgb(0xFFD60A)).cgColor)
            c.fillEllipse(in: CGRect(x: r.minX + 32, y: r.midY - 8, width: 16, height: 16))
            var x = r.minX + 32 + 16 + 16
            drawLeft(c, name, font: nf, x: x, y: r.midY + nf.capHeight / 2, color: .white)
            x += Typo.width(name, nf) + 16
            drawLeft(c, Face.shortTime(date, timeZone: tz), font: tf, x: x, y: r.midY + tf.capHeight / 2, color: NSColor(white: 1, alpha: ic ? 0.92 : 0.75))
        }
    }
}
