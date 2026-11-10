// 錶面「模組」：照 HomeView 的儀表板（dashboard）——一套玻璃方塊格線，同一個圓角、同一個內距、同一套字級。
// 3×3 格（外距 24、間距 20、圓角 50，同 HPTokens.HomeModular）：
//   左上 2×2 大磚＝日期（大號日、底下兩行「星期／月」）；右上圓形玻璃鐘；右中住著膠囊（👀）；
//   底下一條寬磚＝一個小工具（計時器 → 正在播放 → 下一個行程 → 天氣 → 月相，挑第一個有內容的），右下＝電量。
// 沒在播放就不提播放：寬磚換成不需要播放的小工具，錶面上不出現「未在播放」或操作提示。
// 背景是灰藍色系的柔和抽象底（Modular 原本的平灰藍加深，讓白字與玻璃讀得出來）。
//
// 2.0 P07：夜間（房間光暗／控制中心「夜間」）不走 NightFace 的整面映射，自畫黑底：磚是不透明的深灰、
// 主要字亮紅、次要暗紅（HPTokens.Night），不用玻璃（HIG-WID-179/184/185/186）。
// 減少透明度：磚改不透明；增加對比：磚加白色細框、次要字加深。

import AppKit

nonisolated(unsafe) private var modularPlatterCache: (key: String, image: CGImage)?

/// Modular 的配色：白天＝玻璃磚上的白字；夜間＝黑底紅字（HPTokens.Night）
struct ModularPalette {
    let isNight: Bool
    let primary: NSColor
    let secondary: NSColor
    let accent: NSColor

    static let day = ModularPalette(isNight: false, primary: .white, secondary: NSColor.white.withAlphaComponent(0.62), accent: srgb(0xff9f0a))
    static let night = ModularPalette(isNight: true, primary: HPTokens.Night.primary, secondary: HPTokens.Night.secondary, accent: HPTokens.Night.primary)
}

/// 寬磚上的小工具
private struct ModularWidget {
    enum Art { case symbol(String, multicolor: Bool), artwork(String), moon(Double) }
    var art: Art
    var title: String
    var sub: String
}

extension Face {
    private static var MG: HPTokens.HomeModular.Type { HPTokens.HomeModular.self }

    func renderModularV2(_ g: CGContext, _ now: Double) {
        renderModular(g, now, nightRed ? ModularPalette.night : ModularPalette.day)
    }

    // MARK: 版面

    private static var dateTile: CGRect { MG.tile(0, 0, w: 2, h: 2) }
    private static var clockTile: CGRect { MG.tile(2, 0) }
    /// 官方 dashboard：右中那格是照片；膠囊（👀）浮在照片上，兩者共用同一格
    private static var photoTile: CGRect { MG.tile(2, 1) }
    private static var widgetTile: CGRect { MG.tile(0, 2) }
    /// 舊寬磚（drawModularWide 還在用；現在不畫，留著給函式編譯）
    private static var wideTile: CGRect { MG.tile(0, 2, w: 2) }
    private static var moonTile: CGRect { MG.tile(1, 2) }
    private static var powerTile: CGRect { MG.tile(2, 2) }

    private func renderModular(_ g: CGContext, _ now: Double, _ pal: ModularPalette) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        drawModularPlatters(g, pal, full)
        let date = Self.displayDate

        // ── 大磚：日期。大號日（同官方溫控數字的字級與基線），底下兩行：星期、月
        let big = Self.dateTile
        let day = String(Calendar.current.component(.day, from: date))
        let numShape = GlyphShape(day, font: FaceType.sfv(Self.MG.numberSize, wght: 500, mono: false), kern: -4)
        let nb = numShape.ink
        fillShape(g, numShape.moved(big.midX - nb.midX, big.minY + Self.MG.numberBaseline - nb.maxY), pal.primary)
        let wd = Self.formatter("EEEE").string(from: date), mo = Self.formatter("MMMM").string(from: date)
        modularLabel(g, wd, mo, in: big, pal)

        // ── 圓形玻璃鐘
        drawModularClock(g, pal)

        // ── 照片磚（官方 dashboard 的右中格）；沒有照片就填平灰，不寫字、不放佔位圖示
        drawModularPhoto(g, pal)

        // ── 底排三顆小磚：小工具／月相／電量
        let w = modularWidget(now)
        drawModularSmall(g, w, in: Self.widgetTile, pal)
        let moon = Self.moonPhase(date)
        // 沒有任何小工具內容時 modularWidget 會退回月相；那一格不再畫第二次月相，改填平灰
        let moonOnly = w.title == moon.name && w.sub == L("modular.moon", "月相")
        if moonOnly {
            if !pal.isNight { drawModularEmpty(g, Self.moonTile) }
        } else {
            drawModularSmall(g, ModularWidget(art: .moon(moon.fraction), title: moon.name, sub: L("modular.moon", "月相")), in: Self.moonTile, pal)
        }
        drawModularSmall(g, modularPower(), in: Self.powerTile, pal)

        // ── 膠囊浮在照片磚上（產品紅線：👀 一定看得見；官方 dashboard 沒有膠囊）
        let it = Self.photoTile, at = CGPoint(x: it.midX, y: it.midY)
        drawIsland(g, at: at, scale: 210 / 588, liveAt: at, now: now)
    }

    /// 背景＋玻璃磚（換配色、輔助使用設定、解析度才重畫）
    private func drawModularPlatters(_ g: CGContext, _ pal: ModularPalette, _ full: CGRect) {
        let rt = HPAccessibility.reduceTransparency, ic = HPAccessibility.increaseContrast
        let sc = renderPixelScale
        let key = "\(pal.isNight)|\(rt)|\(ic)|\(Int(sc * 100))"
        if let c = modularPlatterCache, c.key == key { drawUpright(g, c.image, in: full); Face.cacheHits += 1; return }
        let px = Int((1024 * sc).rounded())
        let tiles = [Self.dateTile, Self.clockTile, Self.photoTile, Self.widgetTile, Self.moonTile, Self.powerTile]
        func shapes() -> [GlyphShape] {
            tiles.map { GlyphShape(path: continuousRoundedRect($0, radius: Self.MG.radius)) }
        }
        let img = makeImage(px, px) { c in
            if sc != 1 { c.scaleBy(x: sc, y: sc) }
            if pal.isNight {
                c.setFillColor(NSColor.black.cgColor); c.fill(full)
                for s in shapes() { c.addPath(s.path); c.setFillColor(HPTokens.Night.fill.cgColor); c.fillPath() }
                return
            }
            Self.paintModularBackdrop(c)
            if rt {
                for s in shapes() { c.addPath(s.path); c.setFillColor(srgb(0x4a6168).cgColor); c.fillPath() }
            } else {
                let behind = makeImage(1024, 1024) { b in Self.paintModularBackdrop(b) }
                let frost = blurredBackdrop(behind, sigma: 1.2, key: "modular-frost|\(Int(sc * 100))")
                self.drawLiquidGlass(c, shapes(), key: "modular-platters", clear: frost, frosted: frost, params: .platter,
                                     tint: srgb(0x6f8c94).withAlphaComponent(0.5))
            }
            if ic {
                for s in shapes() { c.addPath(s.path); c.setStrokeColor(NSColor(white: 1, alpha: 0.75).cgColor); c.setLineWidth(2); c.strokePath() }
            }
        }
        modularPlatterCache = (key, img)
        drawUpright(g, img, in: full); Face.cacheMisses += 1
    }

    /// 照片磚：照片等比填滿、圓角裁切。沒有照片時沿用這一格填平灰（夜間已是不透明深灰，不再蓋一層）。
    /// 0116 的空槽是鐘下方的寬條（內容區大約 x 0.42–0.84、y 0.60–0.79）和其下兩條更矮的條，對不上 tile() 的方格，所以不新造。
    private func drawModularPhoto(_ g: CGContext, _ pal: ModularPalette) {
        let r = Self.photoTile
        g.saveGState()
        g.addPath(continuousRoundedRect(r, radius: Self.MG.radius)); g.clip()
        if let img = OfficialDemo.on ? PhotosDemoArt.image(px: 512) : photos.current {
            let s = max(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            drawUpright(g, img, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
        } else if !pal.isNight {
            g.setFillColor(Self.modularEmpty.cgColor)
            g.fill(r)
        }
        g.restoreGState()
    }

    /// 沒有內容的格：同一個圓角，填平灰，不寫字、不放圖示。
    private static let modularEmpty = srgb(0x3a3a3c)
    private func drawModularEmpty(_ g: CGContext, _ r: CGRect) {
        g.saveGState()
        g.addPath(continuousRoundedRect(r, radius: Self.MG.radius))
        g.setFillColor(Self.modularEmpty.cgColor)
        g.fillPath()
        g.restoreGState()
    }

    /// 灰藍色系的抽象底：上亮下深的漸層，加兩個大圓的明暗面——磚的斜邊折得出曲線，白字讀得清楚
    private static func paintModularBackdrop(_ c: CGContext) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: cs, colors: [srgb(0x7c979e).cgColor, srgb(0x5b757c).cgColor, srgb(0x3d545b).cgColor] as CFArray, locations: [0, 0.5, 1])!
        c.drawLinearGradient(base, start: .zero, end: CGPoint(x: 300, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        for (x, y, r, hex, a) in [(330.0, 700.0, 470.0, 0xb3c8cd as UInt32, 0.55), (860, 240, 380, 0x2f454b, 0.55), (120, 120, 300, 0xc9d8db, 0.35)] {
            let col = srgb(hex)
            c.saveGState()
            c.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)); c.clip()
            let grad = CGGradient(colorsSpace: cs, colors: [col.withAlphaComponent(a).cgColor, col.withAlphaComponent(a * 0.25).cgColor] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(grad, start: CGPoint(x: x - r, y: y - r), end: CGPoint(x: x + r, y: y + r), options: [])
            c.restoreGState()
        }
    }

    // MARK: 磚上的字

    private static let labelFont: CGFloat = 34

    /// 磚底部兩行：名稱白、狀態白 62%（同字級，照官方磚）
    private func modularLabel(_ g: CGContext, _ title: String, _ sub: String, in r: CGRect, _ pal: ModularPalette, left: CGFloat? = nil) {
        let f = FaceType.sf(Self.labelFont, .semibold, mono: false)
        let maxW = (left.map { r.maxX - $0 } ?? r.width) - 40
        let subC = HPAccessibility.increaseContrast && !pal.isNight ? NSColor.white.withAlphaComponent(0.85) : pal.secondary
        for (s, dy, col) in [(title, Self.MG.titleFromBottom, pal.primary), (sub, Self.MG.subFromBottom, subC)] where !s.isEmpty {
            let t = Self.clipped(s, f, maxW)
            let x = left ?? (r.midX - Typo.width(t, f) / 2)
            drawLeft(g, t, font: f, x: x, y: r.maxY - dy, color: col)
        }
    }

    private func drawModularSmall(_ g: CGContext, _ w: ModularWidget, in r: CGRect, _ pal: ModularPalette) {
        let h: CGFloat = 92
        let box = CGRect(x: r.midX - h / 2, y: r.minY + Self.MG.iconCenterFromTop - h / 2, width: h, height: h)
        drawModularArt(g, w.art, in: box, pal)
        modularLabel(g, w.title, w.sub, in: r, pal)
    }

    /// 寬磚：左邊圖示（或封面），右邊兩行字，跟小磚同字級
    private func drawModularWide(_ g: CGContext, _ w: ModularWidget, _ pal: ModularPalette) {
        let r = Self.wideTile
        let art = CGRect(x: r.minX + 44, y: r.midY - 80, width: 160, height: 160)
        drawModularArt(g, w.art, in: art, pal)
        let f = FaceType.sf(Self.labelFont + 6, .semibold, mono: false), x = art.maxX + 40, maxW = r.maxX - 40 - x
        drawLeft(g, Self.clipped(w.title, f, maxW), font: f, x: x, y: r.midY - 6, color: pal.primary)
        let sf = FaceType.sf(Self.labelFont, .semibold, mono: false)
        let subC = HPAccessibility.increaseContrast && !pal.isNight ? NSColor.white.withAlphaComponent(0.85) : pal.secondary
        drawLeft(g, Self.clipped(w.sub, sf, maxW), font: sf, x: x, y: r.midY + 46, color: subC)
    }

    private func drawModularArt(_ g: CGContext, _ art: ModularWidget.Art, in r: CGRect, _ pal: ModularPalette) {
        switch art {
        case .symbol(let name, let multicolor):
            if multicolor && !pal.isNight { drawMulticolorSymbol(g, name, in: r.insetBy(dx: r.width * 0.06, dy: r.height * 0.1)) }
            else { drawSymbol(g, name, in: r.insetBy(dx: r.width * 0.06, dy: r.height * 0.06), color: pal.primary, weight: .regular) }
        case .artwork(let seed):
            artwork(g, r, seed: seed, pal: pal)
        case .moon(let f):
            drawModularMoon(g, in: r.insetBy(dx: r.width * 0.08, dy: r.height * 0.08), phase: f, pal)
        }
    }

    // MARK: 小工具內容

    private func modularWidget(_ now: Double) -> ModularWidget {
        if let end = timerEnd {
            return ModularWidget(art: .symbol("timer", multicolor: false), title: timerClock(max(0, end - CACurrentMediaTime())), sub: timerLabel)
        }
        if let np = nowPlaying.shown {
            return ModularWidget(art: .artwork(np.title), title: np.title, sub: np.artist)
        }
        if case .event(let e) = calendarTile, PersonalGate.allowed {   // 行程是個人內容：沒認出主人時不出
            return ModularWidget(art: .symbol("calendar", multicolor: false),
                                 title: e.title.isEmpty ? L("calendar.untitled", "（无标题）") : e.title, sub: CalendarLogic.range(e))
        }
        if let d = WeatherSource.shared.data ?? (OfficialDemo.on ? Self.demoWeather : nil) {
            let t = Int((Self.weatherImperial ? d.temp * 9 / 5 + 32 : d.temp).rounded())
            let sky = WeatherSky.of(code: d.code)
            return ModularWidget(art: .symbol(d.night == true ? sky.symbol.night : sky.symbol.day, multicolor: true), title: "\(t)°", sub: Self.weatherText(d.code))
        }
        let m = Self.moonPhase(Self.displayDate)
        return ModularWidget(art: .moon(m.fraction), title: m.name, sub: L("modular.moon", "月相"))
    }

    private func modularPower() -> ModularWidget {
        guard let b = battery else {
            return ModularWidget(art: .symbol("powerplug.fill", multicolor: false), title: "Mac", sub: L("battery.pluggedIn", "已接电源"))   // l10n-ignore：產品名
        }
        let sym = b.charging ? "battery.100percent.bolt" : b.percent > 87 ? "battery.100percent" : b.percent > 62 ? "battery.75percent"
            : b.percent > 37 ? "battery.50percent" : b.percent > 12 ? "battery.25percent" : "battery.0percent"
        return ModularWidget(art: .symbol(sym, multicolor: false), title: "\(b.percent)%", sub: Self.batteryState(b))
    }

    /// 月相（不需要網路、定位、權限）：從 2000-01-06 18:14 UTC 的新月起算，朔望月 29.530588853 天，分成八相
    static func moonPhase(_ d: Date) -> (fraction: Double, name: String) {
        let ref = Date(timeIntervalSince1970: 947_182_440)
        let syn = 29.530588853
        var age = d.timeIntervalSince(ref) / 86400
        age = age.truncatingRemainder(dividingBy: syn); if age < 0 { age += syn }
        let f = age / syn, i = Int((f * 8).rounded()) % 8
        let name: String
        switch i {
        case 0: name = L("moon.new", "新月")
        case 1: name = L("moon.waxingCrescent", "蛾眉月")
        case 2: name = L("moon.firstQuarter", "上弦月")
        case 3: name = L("moon.waxingGibbous", "盈凸月")
        case 4: name = L("moon.full", "满月")
        case 5: name = L("moon.waningGibbous", "亏凸月")
        case 6: name = L("moon.lastQuarter", "下弦月")
        default: name = L("moon.waningCrescent", "残月")
        }
        return (f, name)
    }

    /// 月亮：暗面是淡淡的圓，亮面照月齡算明暗界線（漸盈亮右、漸虧亮左）；SF 的 moonphase 符號在這個字級會糊成一顆實心圓
    private func drawModularMoon(_ g: CGContext, in r: CGRect, phase f: Double, _ pal: ModularPalette) {
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        g.setFillColor(pal.primary.withAlphaComponent(pal.isNight ? 0.25 : 0.18).cgColor)
        g.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        let k = CGFloat(cos(2 * .pi * f)), side: CGFloat = f < 0.5 ? 1 : -1
        let lit = CGMutablePath(), n = 48
        for i in 0...n {   // 外緣：亮面那一側的半圓，上到下
            let t = -1 + 2 * CGFloat(i) / CGFloat(n), x = side * R * sqrt(max(0, 1 - t * t))
            if i == 0 { lit.move(to: CGPoint(x: c.x + x, y: c.y + t * R)) } else { lit.addLine(to: CGPoint(x: c.x + x, y: c.y + t * R)) }
        }
        for i in stride(from: n, through: 0, by: -1) {   // 明暗界線：下到上
            let t = -1 + 2 * CGFloat(i) / CGFloat(n), x = side * k * R * sqrt(max(0, 1 - t * t))
            lit.addLine(to: CGPoint(x: c.x + x, y: c.y + t * R))
        }
        lit.closeSubpath()
        g.addPath(lit); g.setFillColor(pal.primary.cgColor); g.fillPath()
    }

    // MARK: 圓形玻璃鐘（同官方 dashboard：12 根一樣長的刻度、白色圓頭指針）

    private func drawModularClock(_ g: CGContext, _ pal: ModularPalette) {
        let M = Self.MG, clock = Self.clockTile, c = CGPoint(x: clock.midX, y: clock.midY), R = clock.width / 2
        g.saveGState()
        g.setStrokeColor(pal.primary.cgColor); g.setLineWidth(R * M.tickWidth); g.setLineCap(.round)
        for i in 0..<12 {
            let a = CGFloat(i) * .pi / 6
            g.move(to: CGPoint(x: c.x + sin(a) * R * M.tickInner, y: c.y - cos(a) * R * M.tickInner))
            g.addLine(to: CGPoint(x: c.x + sin(a) * R * M.tickOuter, y: c.y - cos(a) * R * M.tickOuter)); g.strokePath()
        }
        let comp = Calendar.current.dateComponents([.hour, .minute, .second], from: Self.displayDate)
        let s = Double(comp.second ?? 0), m = Double(comp.minute ?? 0) + s / 60, h = Double((comp.hour ?? 0) % 12) + m / 60
        func hand(_ deg: Double, len: CGFloat, w: CGFloat) {
            let a = CGFloat(deg * .pi / 180), ux = sin(a), uy = -cos(a), neck: CGFloat = 0.1
            g.setLineWidth(0.03 * R); g.move(to: c); g.addLine(to: CGPoint(x: c.x + ux * neck * R, y: c.y + uy * neck * R)); g.strokePath()
            g.setLineWidth(w * R)
            g.move(to: CGPoint(x: c.x + ux * neck * R, y: c.y + uy * neck * R))
            g.addLine(to: CGPoint(x: c.x + ux * len * R, y: c.y + uy * len * R)); g.strokePath()
        }
        g.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor(white: 0, alpha: 0.25).cgColor)
        hand(h * 30, len: 0.52, w: 0.065)
        hand(m * 6, len: 0.84, w: 0.055)
        if secondsVisible {   // 沒人在看時收起秒針
            let sa = CGFloat(s * 6 * .pi / 180)
            g.setStrokeColor(pal.accent.cgColor); g.setLineWidth(0.016 * R)
            g.move(to: CGPoint(x: c.x - sin(sa) * 0.12 * R, y: c.y + cos(sa) * 0.12 * R))
            g.addLine(to: CGPoint(x: c.x + sin(sa) * 0.9 * R, y: c.y - cos(sa) * 0.9 * R)); g.strokePath()
            g.setFillColor(pal.accent.cgColor); g.fillEllipse(in: CGRect(x: c.x - 0.045 * R, y: c.y - 0.045 * R, width: 0.09 * R, height: 0.09 * R))
        }
        g.restoreGState()
    }

    /// 從軸心 c 沿 (ux, uy) 方向、r0 到 r1 的一段圓頭粗線（填色用的外框）；類比錶也用
    static func segment(_ c: CGPoint, _ ux: CGFloat, _ uy: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x + ux * r0, y: c.y + uy * r0))
        p.addLine(to: CGPoint(x: c.x + ux * r1, y: c.y + uy * r1))
        return p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// 沒有專輯封面時：用歌名決定一組漸層色，中間一個音符（每首歌顏色固定）；夜間改紅調單色（HIG-WID-184）
    private func artwork(_ g: CGContext, _ r: CGRect, seed: String, pal: ModularPalette) {
        let path = continuousRoundedRect(r, radius: r.width * 0.2)
        if pal.isNight {
            g.addPath(path); g.setFillColor(HPTokens.Night.fill.cgColor); g.fillPath()
            drawSymbol(g, "music.note", in: r.insetBy(dx: r.width * 0.3, dy: r.height * 0.27), color: HPTokens.Night.primary, weight: .medium)
            return
        }
        let palettes: [(UInt32, UInt32)] = [(0x5fa8ff, 0x2853c7), (0xff8a65, 0xd1426b), (0x7ad6a6, 0x2f8f74), (0xc69cff, 0x6b4bd8), (0xffcf5c, 0xf08a24)]
        var hsh: UInt32 = 5381
        for u in seed.unicodeScalars { hsh = (hsh &* 33) &+ u.value }
        let p = palettes[Int(hsh % UInt32(palettes.count))]
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        g.saveGState(); g.addPath(path); g.clip()
        let grad = CGGradient(colorsSpace: cs, colors: [srgb(p.0).cgColor, srgb(p.1).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
        drawSymbol(g, "music.note", in: r.insetBy(dx: r.width * 0.3, dy: r.height * 0.27), color: NSColor.white.withAlphaComponent(0.92))
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
