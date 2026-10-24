// 天氣錶面：照官方 HomeView 的天氣瓷磚——滿版天空照片般的底、左上狀況與高低溫、右上時間、
// 液態玻璃的大溫度、底下四格（日落／風速／濕度／AQI）；膠囊住在溫度右邊，眼睛望向天空。
// 稿：docs/design-drafts/faces-v3/artifact/engine_tail.js face('天氣')。資料見 WeatherSource.swift。

import AppKit
import CoreText

enum WeatherSky: Hashable {
    case clear, partly, cloudy, rain, snow, fog, storm

    static func of(code: Int) -> WeatherSky {
        switch code {
        case 0, 1: return .clear
        case 2: return .partly
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51...67, 80...82: return .rain
        case 71...77, 85, 86: return .snow
        case 95...99: return .storm
        default: return .partly
        }
    }
    var symbol: (day: String, night: String) {
        switch self {
        case .clear: return ("sun.max.fill", "moon.stars.fill")
        case .partly: return ("cloud.sun.fill", "cloud.moon.fill")
        case .cloudy: return ("cloud.fill", "cloud.fill")
        case .fog: return ("cloud.fog.fill", "cloud.fog.fill")
        case .rain: return ("cloud.rain.fill", "cloud.moon.rain.fill")
        case .snow: return ("cloud.snow.fill", "cloud.snow.fill")
        case .storm: return ("cloud.bolt.rain.fill", "cloud.bolt.rain.fill")
        }
    }
}

private struct WeatherCache {
    var key = ""
    var sky: CGImage?
    var clear: CGImage?
    var frosted: CGImage?
    var minute = -1
    var version = -1
}
nonisolated(unsafe) private var weatherCache = WeatherCache()

extension Face {
    private static func weatherText(_ code: Int) -> String {
        switch code {
        case 0: return L("weather.cond.clear", "晴")
        case 1: return L("weather.cond.mostlyClear", "大致晴朗")
        case 2: return L("weather.cond.partly", "晴时多云")
        case 3: return L("weather.cond.cloudy", "阴")
        case 45, 48: return L("weather.cond.fog", "雾")
        case 51...57: return L("weather.cond.drizzle", "毛毛雨")
        case 61...65, 66, 67: return L("weather.cond.rain", "雨")
        case 71...77: return L("weather.cond.snow", "雪")
        case 80...82: return L("weather.cond.showers", "阵雨")
        case 85, 86: return L("weather.cond.snowShowers", "阵雪")
        case 95...99: return L("weather.cond.storm", "雷雨")
        default: return L("weather.cond.cloudy", "阴")
        }
    }

    private static var weatherImperial: Bool { Locale.current.measurementSystem == .us }

    private static func isNight(_ d: WeatherData?, _ date: Date) -> Bool {
        if let n = d?.night { return n }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let mins = (c.hour ?? 12) * 60 + (c.minute ?? 0)
        var setMin = 18 * 60
        if let s = d?.sunset?.split(separator: ":"), s.count == 2, let h = Int(s[0]), let m = Int(s[1]) { setMin = h * 60 + m }
        return mins < 6 * 60 || mins >= setMin
    }

    func renderWeatherFace(_ g: CGContext, _ now: Double) {
        let src = WeatherSource.shared
        src.activate { [weak self] in self?.forceDirty = true }
        let d = src.data
        let date = Self.displayDate
        let night = Self.isNight(d, date)
        let sky = WeatherSky.of(code: d?.code ?? 2)
        let imperial = Self.weatherImperial

        // 天空：照狀況與日夜畫一次、快取
        let skyKey = "\(sky)|\(night)"
        if weatherCache.key != skyKey || weatherCache.sky == nil {
            let img = snapshotBackdrop(px: 1024) { c in Self.drawWeatherSky(c, sky, night: night) }
            let clear = snapshotBackdrop(px: 512) { c in Self.drawWeatherSky(c, sky, night: night) }
            let small = snapshotBackdrop(px: 192) { c in Self.drawWeatherSky(c, sky, night: night) }
            weatherCache.key = skyKey; weatherCache.sky = img; weatherCache.clear = clear
            weatherCache.frosted = blurredBackdrop(small, sigma: 10, key: "weather|\(skyKey)")
        }
        drawUpright(g, weatherCache.sky!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))

        let white = NSColor.white
        func shadowed(_ draw: () -> Void) {
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -2), blur: 14, color: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.35, alpha: 0.32).cgColor)
            draw(); g.restoreGState()
        }
        func temp(_ v: Double) -> Int { Int((imperial ? v * 9 / 5 + 32 : v).rounded()) }
        let dash = "—"

        // 左上：狀況圖示（多色）＋文字，下一行高低溫
        let symName = night ? sky.symbol.night : sky.symbol.day
        shadowed {
            drawMulticolorSymbol(g, symName, in: CGRect(x: 74, y: 62, width: 82, height: 62))
            drawLeft(g, d.map { Self.weatherText($0.code) } ?? dash, font: FaceType.sf(48, .semibold, mono: false), x: 164, y: 126, color: white)
            let hiLo = d.map { String(format: L("weather.hiLo", "高 %d° 低 %d°"), temp($0.hi), temp($0.lo)) }
                ?? String(format: L("weather.hiLo", "高 %d° 低 %d°"), 0, 0).replacingOccurrences(of: "0", with: dash)
            drawLeft(g, hiLo, font: FaceType.sf(44, .semibold, mono: false), x: 78, y: 184, color: white)
            // 右上：時間
            let (hh, mm) = Self.hourMinute(date)
            let ts = "\(hh):\(mm)", tf = FaceType.sf(100, .semibold)
            drawLeft(g, ts, font: tf, x: 945 - Self.weatherWidth(ts, tf), y: 164, color: white, kern: -0.8)
        }

        // 大溫度：液態玻璃
        let big = d.map { "\(temp($0.temp))°" } ?? dash
        let font = FaceType.sf(400, .regular, mono: false)
        var shape = GlyphShape(big, font: font)
        let ref = GlyphShape("0", font: font).ink.height
        var k = 282 / max(1, ref)
        if d == nil { k *= 0.9 }
        let b0 = shape.ink
        if b0.width * k > 590 { k = 590 / b0.width }
        shape = shape.transformed(CGAffineTransform(translationX: 84 - b0.minX * k, y: 538).scaledBy(x: k, y: k))
        drawLiquidGlass(g, [shape], key: "weather|\(skyKey)|\(big)", clear: weatherCache.clear, frosted: weatherCache.frosted,
                        system: SystemGlassParams(refractionHeight: 1.0, refractionAmount: -4.3, blurRadius: 9, highlight: 0.55, white: 1.0, black: 0.0,
                                                  saturation: 1.3, fill: night ? 0.14 : 0.36, rim: 1.0, keyAmount: 0.9, fillAmount: 0.5, ringShadow: 0.25))

        // 膠囊：在溫度右邊（寬約 256）；眼睛的朝向由表情決定，不另畫
        faceEyeLook = CGPoint(x: -5, y: -14); defer { faceEyeLook = nil }   // 望向天空
        drawIsland(g, at: CGPoint(x: 815, y: 447), scale: 256 / (420 * 1.4), liveAt: CGPoint(x: 815, y: 447), now: now)

        // 底下四格
        let aqiSym = NSImage(systemSymbolName: "aqi.medium", accessibilityDescription: nil) != nil ? "aqi.medium" : "circle.dotted"
        let wind = d.map { imperial ? String(format: "%.0f mph", $0.wind * 0.621371) : String(format: "%.0f km/h", $0.wind) } ?? dash
        let cols: [(x: CGFloat, sym: String, value: String, label: String)] = [
            (157, "sunset", d?.sunset ?? dash, L("weather.sunset", "日落")),
            (393, "wind", wind, L("weather.wind", "风速")),
            (638, "humidity", d.map { String(format: "%.0f%%", $0.humidity) } ?? dash, L("weather.humidity", "湿度")),
            (874, aqiSym, d?.aqi.map { String(format: "%.0f", $0) } ?? dash, "AQI"),
        ]
        shadowed {
            for c in cols {
                drawSymbol(g, c.sym, in: CGRect(x: c.x - 52, y: 690, width: 104, height: 82), color: white, weight: .regular)
                drawLeft(g, c.value, font: FaceType.sf(48, .semibold, mono: false), x: c.x - Self.weatherWidth(c.value, FaceType.sf(48, .semibold, mono: false)) / 2,
                         y: 858, color: white)
                drawLeft(g, c.label, font: FaceType.sf(48, .semibold, mono: false), x: c.x - Self.weatherWidth(c.label, FaceType.sf(48, .semibold, mono: false)) / 2,
                         y: 920, color: white)
            }
        }
    }

    /// 只在換分鐘或資料變了才重畫（沒有背景動畫）
    func tickWeatherFace(_ now: Double) -> Bool {
        let minute = Int(Self.displayDate.timeIntervalSince1970 / 60)
        let v = WeatherSource.shared.version
        defer { weatherCache.minute = minute; weatherCache.version = v }
        return minute != weatherCache.minute || v != weatherCache.version
    }

    private static func weatherWidth(_ s: String, _ f: NSFont) -> CGFloat {
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(f))), nil, nil, nil)
    }

    /// 多色 SF Symbol（太陽黃、雲白）
    private func drawMulticolorSymbol(_ g: CGContext, _ name: String, in r: CGRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: .semibold).applying(.preferringMulticolor())
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size, k = min(r.width / max(1, s.width), r.height / max(1, s.height))
        let dst = CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
        img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: 天空

    private struct SkyRNG {
        var s: UInt64
        mutating func next() -> CGFloat {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((s >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
    }

    /// 一團雲：很多柔邊圓疊成，先畫偏暗的底影、再畫偏亮的頂
    private static func cloud(_ c: CGContext, cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, n: Int, seed: UInt64,
                              light: NSColor, shade: NSColor, alpha: CGFloat) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func puff(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ col: NSColor, _ a: CGFloat) {
            let top = col.withAlphaComponent(a).cgColor, zero = col.withAlphaComponent(0).cgColor
            let grad = CGGradient(colorsSpace: cs, colors: [top, col.withAlphaComponent(a * 0.55).cgColor, zero] as CFArray, locations: [0, 0.5, 1])!
            c.drawRadialGradient(grad, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        for pass in 0..<2 {
            var rng = SkyRNG(s: seed)
            for _ in 0..<n {
                let x = cx + (rng.next() - 0.5) * w
                let edge = 1 - abs(x - cx) / (w / 2)                 // 兩端的團小一點、矮一點
                let y = cy + (rng.next() - 0.5) * h * (0.4 + 0.6 * edge)
                let r = (0.16 + 0.22 * rng.next()) * min(w, h * 2.4) * (0.5 + 0.5 * edge)
                if pass == 0 { puff(x, y + r * 0.25, r * 1.1, shade, alpha * 0.9) } else { puff(x, y - r * 0.3, r * 0.75, light, alpha * 0.6) }
            }
        }
    }

    static func drawWeatherSky(_ c: CGContext, _ sky: WeatherSky, night: Bool) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 底色漸層（上到下）
        let stops: [NSColor]
        if night {
            switch sky {
            case .clear, .partly: stops = [srgb(0x0a1530), srgb(0x16295a), srgb(0x2b4a86)]
            default: stops = [srgb(0x141c2e), srgb(0x232f48), srgb(0x34435f)]
            }
        } else {
            switch sky {
            case .clear: stops = [srgb(0x2468c4), srgb(0x3f86d6), srgb(0x6ea8e6)]
            case .partly: stops = [srgb(0x5d86bb), srgb(0x4a89d3), srgb(0x6aa2de)]
            case .cloudy: stops = [srgb(0x8d9bae), srgb(0x7c8fa8), srgb(0x6f86a4)]
            case .rain: stops = [srgb(0x5c6b7e), srgb(0x56677e), srgb(0x4e6079)]
            case .storm: stops = [srgb(0x3b4658), srgb(0x45536a), srgb(0x3c4b63)]
            case .snow: stops = [srgb(0xaab6c4), srgb(0x9fb0c4), srgb(0x8ea3bd)]
            case .fog: stops = [srgb(0xa3adb8), srgb(0x98a5b3), srgb(0x8997a8)]
            }
        }
        let grad = CGGradient(colorsSpace: cs, colors: stops.map(\.cgColor) as CFArray, locations: [0, 0.5, 1])!
        c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])

        let light: NSColor, shade: NSColor
        if night { light = srgb(0x6a7fae); shade = srgb(0x1b2646) }
        else {
            switch sky {
            case .rain, .storm: light = srgb(0xaab5c3); shade = srgb(0x56657a)
            case .cloudy, .fog: light = srgb(0xe4eaf1); shade = srgb(0x93a3b8)
            default: light = srgb(0xf4f8fc); shade = srgb(0x8aa0bd)
            }
        }
        let a: CGFloat = night ? 0.55 : 1
        switch sky {
        case .clear:
            cloud(c, cx: 760, cy: 180, w: 520, h: 120, n: 10, seed: 3, light: light, shade: shade, alpha: 0.55 * a)
            cloud(c, cx: 230, cy: 420, w: 420, h: 90, n: 8, seed: 5, light: light, shade: shade, alpha: 0.35 * a)
        case .partly:
            // 官方：頂上一整片大積雲、右邊再一條壓在溫度後面
            cloud(c, cx: 420, cy: 90, w: 1300, h: 330, n: 40, seed: 11, light: light, shade: shade, alpha: 0.85 * a)
            cloud(c, cx: 180, cy: 290, w: 520, h: 160, n: 18, seed: 12, light: light, shade: shade, alpha: 0.8 * a)
            cloud(c, cx: 800, cy: 330, w: 560, h: 190, n: 22, seed: 13, light: light, shade: shade, alpha: 0.85 * a)
            cloud(c, cx: 700, cy: 470, w: 520, h: 60, n: 10, seed: 14, light: light, shade: shade, alpha: 0.5 * a)
        case .cloudy, .rain, .storm, .snow, .fog:
            let n = sky == .fog ? 14 : 40
            cloud(c, cx: 512, cy: 150, w: 1400, h: 520, n: n, seed: 21, light: light, shade: shade, alpha: 0.95 * a)
            cloud(c, cx: 512, cy: 520, w: 1300, h: 420, n: n, seed: 22, light: light, shade: shade, alpha: 0.7 * a)
            cloud(c, cx: 512, cy: 860, w: 1300, h: 300, n: n / 2, seed: 23, light: light, shade: shade, alpha: 0.45 * a)
            if sky == .rain || sky == .storm {
                c.saveGState(); c.setLineCap(.round)
                var rng = SkyRNG(s: 77)
                for _ in 0..<(sky == .storm ? 130 : 90) {
                    let x = rng.next() * 1100 - 40, y = rng.next() * 1024, len = 34 + rng.next() * 40
                    c.setStrokeColor(NSColor.white.withAlphaComponent(0.10 + 0.16 * rng.next()).cgColor)
                    c.setLineWidth(2 + rng.next() * 2)
                    c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x - len * 0.22, y: y + len)); c.strokePath()
                }
                c.restoreGState()
            }
            if sky == .snow {
                var rng = SkyRNG(s: 99)
                for _ in 0..<70 {
                    let x = rng.next() * 1024, y = rng.next() * 1024, r = 3 + rng.next() * 5
                    c.setFillColor(NSColor.white.withAlphaComponent(0.35 + 0.4 * rng.next()).cgColor)
                    c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }
        }
        if night, sky == .clear || sky == .partly {   // 星星
            var rng = SkyRNG(s: 41)
            for _ in 0..<60 {
                let x = rng.next() * 1024, y = rng.next() * 640, r = 1 + rng.next() * 2.2
                c.setFillColor(NSColor.white.withAlphaComponent(0.25 + 0.6 * rng.next()).cgColor)
                c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
    }
}
