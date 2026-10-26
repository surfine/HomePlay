// 天气 App：照 iOS 27／macOS 27 系統天氣 App 的版面與動態——
// 滿版動態天空（WeatherSky：先試系統的天氣渲染器，健檢不過就用我們的 Metal 天空；依天氣代碼與日出日落換場景、交叉淡入），
// 上面是置中的城市、細體大溫度、狀況、高低溫；往上捲時收成一行（城市｜溫度｜狀況）；
// 模組：逐時 12 小時、10 天（溫度範圍條＝依溫度上色的漸層，今天有一顆目前溫度的點）、日落／空氣品質／濕度／風速四格。
// 模組底照系統天氣：跟著天色染一層很淡的藍＋一條細亮邊（實測：模組＝天色 B+8、上緣亮 6–8）；「減少透明度」時改不透明。
// 效能：天空在背景佇列畫（GPU 約 4 ms／幀，主執行緒只拿上一張）；模組與文字畫成一張快取圖，資料、分鐘、捲動、場景變了才重畫。
// 減少動態效果、過熱、低電量：天空停住（換天氣時仍淡入），外殼不為它抬幀率。不在畫面上就不排幀。
// 資料：WeatherSource（Open-Meteo）；示範：--demo-weather [rain|snow|thunder|clear-night|cloudy|fog|…]。

import AppKit

final class WeatherApp: PetApp {
    static let shared = WeatherApp()
    let id = "weather"
    var title: String { L("app.weather", "天气") }
    let icon = AppIcon(color: srgb(0x1e88f0), symbol: "cloud.sun.fill", system: "/System/Applications/Weather.app")

    private var scroll = AppScroll()
    private var lastVersion = -1
    private var lastMinute = -1
    private var lastSkySerial = -1
    private var contentHeight: CGFloat = 2400
    private var content: (key: String, image: CGImage, notes: [HPAXNote])?
    private var fallbackSky: (key: String, image: CGImage)?

    func didOpen(now: Double) {
        scroll = AppScroll()
        // 驗收：HOMEPLAY_WEATHER_SCROLL=<px> 打開就捲到那裡（看收合的標頭、模組上的水花）
        if let v = ProcessInfo.processInfo.environment["HOMEPLAY_WEATHER_SCROLL"].flatMap(Double.init) { scroll.offset = CGFloat(v) }
    }
    // 天空是照片型的深色內容——左上返回鈕（清玻璃＋白符號）與右上時間自己畫成白色
    var showsCloseButton: Bool { false }
    var showsClock: Bool { false }
    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        if HPComponents.hitBack(p) { HPComponents.navigateBack(); return true }
        return false
    }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        var dirty = false
        let v = WeatherSource.shared.version
        if v != lastVersion { lastVersion = v; dirty = true }
        let m = Int(Date().timeIntervalSince1970 / 60)
        if m != lastMinute { lastMinute = m; dirty = true }
        // 天空有新的一幀就重畫（背景佇列畫好的）
        let s = WeatherLiveSky.shared.serial
        if s != lastSkySerial { lastSkySerial = s; dirty = true }
        return dirty
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool { scroll.scroll(dy, contentHeight: contentHeight, viewport: 1024) }

    // MARK: 資料
    private var demoCache: (minute: Int, data: WeatherData)?
    private var lookCache: (scene: WeatherSkyScene, look: SkyLook)?
    private func current(_ face: Face) -> WeatherData? {
        if AppUI.demoWeather {
            // 示範資料每分鐘做一次就好（裡面有 DateFormatter，每幀做要 1–2 ms）
            let m = Int(Face.displayDate.timeIntervalSince1970 / 60)
            if demoCache?.minute != m { demoCache = (m, Self.demoData()) }
            return demoCache!.data
        }
        let src = WeatherSource.shared
        src.activate { [weak face] in face?.forceDirty = true }
        if src.data == nil, Face.demoData, src.statusText == nil { return Self.demoData() }
        return src.data
    }

    static func demoData(date: Date = Face.displayDate) -> WeatherData {
        let h0 = Calendar.current.component(.hour, from: date)
        let demo = WeatherSkyScene.demo
        let code0 = demo?.demoCode ?? 2
        let cold = demo.map { [.snow, .sleet].contains($0.kind) } ?? false
        let base: Double = cold ? -2 : 22
        let temps: [Double] = [0, 0, -1, -1, -2, -2, -3, -3, -3, -4, -4, -4].map { base + $0 }
        let codes = demo != nil ? Array(repeating: code0, count: 6) + [3, 3, 2, 2, 1, 0] : [2, 2, 3, 3, 61, 61, 3, 2, 2, 1, 0, 0]
        let nightDemo = demo.map { [.night, .dawn, .dusk].contains($0.time) }
        let hours = (0..<12).map { i -> WeatherHour in
            let h = (h0 + i) % 24
            return WeatherHour(label: String(format: "%02d", h), temp: temps[i], code: codes[i], night: nightDemo ?? (h < 6 || h >= 18))
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let cal = Calendar.current
        let days: [(Double, Double, Int)] = [(25, 19, code0), (24, 18, 61), (22, 17, 63), (23, 17, 3), (26, 19, 0),
                                             (27, 20, 1), (26, 21, 2), (24, 19, 80), (23, 18, 3), (25, 18, 0)]
        let daily = days.enumerated().map { i, d in
            WeatherDay(date: f.string(from: cal.date(byAdding: .day, value: i, to: date) ?? date),
                       hi: d.0 + (cold ? -22 : 0), lo: d.1 + (cold ? -22 : 0), code: d.2)
        }
        return WeatherData(temp: base, hi: base + 3, lo: base - 3, code: code0, wind: demo?.kind == .windy ? 46 : 11, humidity: 76, aqi: 21, sunset: "17:21",
                           city: L("city.taipeiCity", "台北市"), night: nightDemo, hourly: hours, daily: daily, sunrise: "06:02")
    }

    private static func minutes(_ s: String?) -> Int? {
        guard let p = s?.split(separator: ":"), p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    private func isNight(_ d: WeatherData?, _ date: Date) -> Bool {
        if let n = d?.night { return n }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let mins = (c.hour ?? 12) * 60 + (c.minute ?? 0)
        return mins < (Self.minutes(d?.sunrise) ?? 6 * 60) || mins >= (Self.minutes(d?.sunset) ?? 18 * 60)
    }

    /// 天氣資料 → 天空場景（示範旗標優先）
    func scene(for d: WeatherData?, date: Date) -> WeatherSkyScene {
        if let s = WeatherSkyScene.demo { var s = s; s.moonPhase = WeatherSkyScene.moonPhase(date); return s }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 12) * 60 + (c.minute ?? 0)
        var t = WeatherSkyScene.time(minutes: m, sunrise: Self.minutes(d?.sunrise) ?? 6 * 60, sunset: Self.minutes(d?.sunset) ?? 18 * 60)
        // 有 is_day 就以它為準（日出日落那 40 分鐘照樣用日出日落的天色）
        if let n = d?.night, t == .day || t == .night { t = n ? .night : .day }
        return WeatherSkyScene(kind: SkyKind.of(code: d?.code ?? 2, wind: d?.wind ?? 0), time: t, moonPhase: WeatherSkyScene.moonPhase(date))
    }

    static func aqiText(_ v: Double) -> String {
        switch v {
        case ..<51: return L("weather.aqi.good", "优")
        case ..<101: return L("weather.aqi.moderate", "良")
        case ..<151: return L("weather.aqi.sensitive", "轻度污染")
        case ..<201: return L("weather.aqi.unhealthy", "中度污染")
        case ..<301: return L("weather.aqi.veryUnhealthy", "重度污染")
        default: return L("weather.aqi.hazardous", "严重污染")
        }
    }

    private func dayName(_ s: String, index: Int) -> String {
        if index == 0 { return L("weather.today", "今天") }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: s) else { return s }
        let o = DateFormatter(); o.locale = L10n.language.locale; o.dateFormat = "EEE"
        return o.string(from: d)
    }

    /// 溫度範圍條的顏色（照系統天氣：冷藍→青→綠→黃→橘→紅；°C）
    static func tempColor(_ c: Double) -> NSColor {
        let stops: [(Double, UInt32)] = [(-10, 0x5e5ce6), (0, 0x0a84ff), (8, 0x64d2ff), (14, 0x30d158), (20, 0xffd60a), (26, 0xff9f0a), (34, 0xff453a)]
        if c <= stops[0].0 { return srgb(stops[0].1) }
        for i in 1..<stops.count where c <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            let t = CGFloat((c - a) / (b - a))
            let x = SkyRGB(ca).mix(SkyRGB(cb), Float(t))
            return NSColor(srgbRed: CGFloat(x.r), green: CGFloat(x.g), blue: CGFloat(x.b), alpha: 1)
        }
        return srgb(stops.last!.1)
    }

    // MARK: 畫
    /// 量測：HOMEPLAY_WEATHER_PROF=1 每 120 幀印一次這個 App 自己畫一幀的平均毫秒（天空貼圖＋內容快取＋控制層）
    private static let forceReduceMotion = ProcessInfo.processInfo.environment["HOMEPLAY_REDUCE_MOTION"] == "1"
    private static let prof = ProcessInfo.processInfo.environment["HOMEPLAY_WEATHER_PROF"] != nil
    private var profT = 0.0, profSky = 0.0, profContent = 0.0, profCtl = 0.0, profN = 0

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        let t0 = Self.prof ? CACurrentMediaTime() : 0
        defer {
            if Self.prof {
                profT += CACurrentMediaTime() - t0; profN += 1
                if profN % 120 == 0 {
                    let ms = WeatherLiveSky.shared.frameMs.suffix(120).sorted()
                    NSLog("weather prof: app %.2f ms/frame (sky blit %.2f, content %.2f, controls %.2f), sky GPU+readback median %.2f p95 %.2f ms, source %@",
                          profT / Double(profN) * 1000, profSky / Double(profN) * 1000, profContent / Double(profN) * 1000, profCtl / Double(profN) * 1000, ms[ms.count / 2], ms[ms.count * 95 / 100], WeatherLiveSky.shared.source.rawValue)
                }
            }
        }
        let d = current(face)
        let date = Face.displayDate
        let sc = scene(for: d, date: date)
        if lookCache?.scene != sc { lookCache = (sc, sc.look) }
        let look = lookCache!.look

        // 1) 天空
        let sky = WeatherLiveSky.shared
        sky.configure(sc)
        // 減少動態效果（系統設定，或驗收用 HOMEPLAY_REDUCE_MOTION=1）、過熱、低電量：天空停住
        let animate = !Face.ambientPaused && !Self.forceReduceMotion
        let px = max(256, g.width)     // 畫布的實際像素（視窗多大就多大，常見 864）
        var skyImage = sky.frame(now: now, animate: animate, side: px)
        if skyImage == nil || (sky.source == .ours && skyImage!.width != px) { skyImage = sky.renderSync(frames: 1) }   // 第一次打開、換尺寸（或快照）：同步畫第一張，不留空白
        if let img = skyImage {
            let tb = Self.prof ? CACurrentMediaTime() : 0
            Self.blit(g, img, rect)
            if Self.prof { profSky += CACurrentMediaTime() - tb }
        } else {
            // 兩個畫家都起不來（沒有 Metal）：退回舊的 Core Graphics 天空
            let kind = WeatherSky.of(code: d?.code ?? 2), night = isNight(d, date), key = "\(kind)|\(night)"
            if fallbackSky?.key != key { fallbackSky = (key, face.snapshotBackdrop(px: 1024) { c in Face.drawWeatherSky(c, kind, night: night) }) }
            face.drawUpright(g, fallbackSky!.image, in: rect)
        }

        // 2) 內容（快取）
        let tc = Self.prof ? CACurrentMediaTime() : 0
        scroll.clamp(contentHeight: contentHeight, viewport: 1024)
        let o = -scroll.offset
        let rt = HPAccessibility.reduceTransparency
        let key = "\(px)|\(WeatherSource.shared.version)|\(lastMinute)|\(Int(o))|\(sc.kind)|\(sc.time)|\(rt)|\(L10n.language)|\(AppUI.demoWeather)|\(d?.temp ?? -999)"
        if content?.key != key {
            var notes: [HPAXNote] = []
            let img = makeImage(px, px) { c in
                c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
                contentHeight = drawContent(c, face: face, d: d, look: look, offset: o, reduceTransparency: rt, notes: &notes)
            }
            content = (key, img, notes)
        }
        if let c = content {
            Self.blit(g, c.image, rect)
            for n in c.notes { HPAX.note(g, n.rect, n.role, n.label, value: n.value, shape: n.shape) }
        }

        let tcEnd = Self.prof ? CACurrentMediaTime() : 0
        if Self.prof { profContent += tcEnd - tc }
        // 3) 控制層：返回鈕、時間（白色，天空上加一點陰影）
        defer { if Self.prof { profCtl += CACurrentMediaTime() - tcEnd } }
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -2), blur: 14, color: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.35, alpha: 0.32).cgColor)
        HPComponents.clock(g, face, color: .white)
        g.restoreGState()
        HPComponents.backButton(g, face, symbol: backSymbol)
    }

    /// 跟畫布同尺寸的圖 1:1 貼上（不內插；尺寸不同才用高品質縮放）
    private static func blit(_ g: CGContext, _ img: CGImage, _ r: CGRect) {
        g.saveGState(); g.translateBy(x: 0, y: r.minY + r.maxY); g.scaleBy(x: 1, y: -1)
        g.interpolationQuality = img.width == g.width ? .none : .high
        g.draw(img, in: r); g.restoreGState()
    }

    /// 模組與文字（透明底）；回傳內容總高
    private func drawContent(_ g: CGContext, face: Face, d: WeatherData?, look: SkyLook, offset o: CGFloat,
                             reduceTransparency rt: Bool, notes: inout [HPAXNote]) -> CGFloat {
        let imperial = Locale.current.measurementSystem == .us
        func temp(_ v: Double) -> Int { Int((imperial ? v * 9 / 5 + 32 : v).rounded()) }
        let white = NSColor.white, dim = NSColor.white.withAlphaComponent(0.6), dash = "—"
        func note(_ r: CGRect, _ label: String, _ role: HPAXNote.Role = .text) {
            let vis = r.intersection(CGRect(x: 0, y: AppUI.topEdge, width: 1024, height: 1024 - AppUI.topEdge))
            guard !vis.isNull, vis.height >= r.height * 0.5 else { return }
            notes.append(HPAXNote(role: role, label: label, rect: r, shape: .rounded(AppUI.groupRadius)))
        }
        func shadowed(_ draw: () -> Void) {
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -2), blur: 14, color: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.35, alpha: 0.3).cgColor)
            draw(); g.restoreGState()
        }
        let cond = d.map { Face.weatherText($0.code) } ?? WeatherSource.shared.statusText ?? L("shell.weather.none", "暂无天气")   // 2.0 depth：沒資料時寫原因
        let city = d?.city ?? title
        let hiLo = d.map { String(format: L("weather.hiLo", "高 %d° 低 %d°"), temp($0.hi), temp($0.lo)) } ?? ""

        // 往上捲時：大標頭淡出、收成一行（系統天氣的收合標頭）
        let collapse = min(1, max(0, (-o - 180) / 160))
        // 標頭（跟著捲）：城市 regular、溫度 thin、狀況與高低溫 semibold——照 iOS 天氣
        g.saveGState()
        g.setAlpha(1 - collapse)
        shadowed {
            AppUI.center(face, g, city, AppUI.font(64, .medium), cx: 512, y: 262 + o, white)
            AppUI.center(face, g, d.map { "\(temp($0.temp))°" } ?? dash, FaceType.sf(240, .thin), cx: 512, y: 490 + o, white)
            AppUI.center(face, g, cond, AppUI.fitted(cond, size: 44, weight: .semibold, maxWidth: 860), cx: 512, y: 556 + o, white)
            if d != nil { AppUI.center(face, g, hiLo, AppUI.font(44, .semibold), cx: 512, y: 612 + o, white) }
        }
        g.restoreGState()
        if collapse < 0.5 {
            note(CGRect(x: 160, y: 200 + o, width: 704, height: 430), [city, d.map { "\(temp($0.temp))°" } ?? "", cond, hiLo].filter { !$0.isEmpty }.joined(separator: ", "), .heading)
        }
        // 收合後的一行：城市 + 「溫度｜狀況」
        if collapse > 0 {
            g.saveGState(); g.setAlpha(collapse)
            shadowed {
                AppUI.center(face, g, city, AppUI.font(40, .semibold), cx: 512, y: 172, white)
                if let d { AppUI.center(face, g, "\(temp(d.temp))° | \(cond)", AppUI.font(30, .semibold), cx: 512, y: 212, dim) }
            }
            g.restoreGState()
            if collapse >= 0.5, let d { notes.append(HPAXNote(role: .heading, label: "\(city), \(temp(d.temp))°, \(cond)", rect: CGRect(x: 260, y: 136, width: 504, height: 90))) }
        }
        guard let d else { return 1024 }

        // 模組底：天色染一層淡藍＋細亮邊；減少透明度時不透明
        let tint = look.middle.mix(SkyRGB(0x1e3a8a), 0.5)
        let fill = rt ? NSColor(srgbRed: CGFloat(look.top.r * 0.8), green: CGFloat(look.top.g * 0.8), blue: CGFloat(look.top.b * 0.85), alpha: 1)
                      : NSColor(srgbRed: CGFloat(tint.r), green: CGFloat(tint.g), blue: CGFloat(tint.b), alpha: 0.16)
        let clipTop: CGFloat = collapse > 0 ? 236 : AppUI.topEdge
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: clipTop, width: 1024, height: 1024 - clipTop))
        var colliders: [CGRect] = []
        func module(_ r: CGRect, symbol: String?, _ head: String) {
            if r.minY > clipTop, r.minY < 1024 { colliders.append(r) }
            let path = continuousRoundedRect(r, radius: AppUI.groupRadius)
            g.setFillColor(fill.cgColor); g.addPath(path); g.fillPath()
            if !rt {
                g.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); g.setLineWidth(2)
                g.addPath(continuousRoundedRect(r.insetBy(dx: 1, dy: 1), radius: AppUI.groupRadius - 1)); g.strokePath()
            }
            var x = r.minX + 36
            if let symbol {
                face.drawSymbol(g, symbol, in: CGRect(x: x, y: r.minY + 30, width: 30, height: 28), color: dim, weight: .semibold); x += 42
            }
            AppUI.left(face, g, head, AppUI.font(28, .semibold), x: x, y: r.minY + 56, dim)
            g.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor); g.fill(CGRect(x: r.minX + 36, y: r.minY + 78, width: r.width - 72, height: 2))
        }
        var y = 664 + o
        // 逐時：一張卡放 6 格（字要大，遠看也讀得出來）
        if let hours = d.hourly, !hours.isEmpty {
            let card = CGRect(x: AppUI.margin, y: y, width: AppUI.contentW, height: 272)
            module(card, symbol: "clock", L("weather.hourly", "逐小时预报"))
            let cols = 6, colW = (card.width - 24) / CGFloat(cols)
            for (i, h) in hours.prefix(cols).enumerated() {
                let cx = card.minX + 12 + colW * (CGFloat(i) + 0.5)
                let label = i == 0 ? L("weather.now", "现在") : Int(h.label).map(Face.hourLabel) ?? h.label   // 2.0 depth：時制照系統（「下午3時」「3 PM」「15」）
                AppUI.center(face, g, label, AppUI.font(30, i == 0 ? .bold : .semibold), cx: cx, y: card.minY + 132, white)
                let sk = WeatherSky.of(code: h.code)
                face.drawMulticolorSymbol(g, h.night ? sk.symbol.night : sk.symbol.day, in: CGRect(x: cx - 30, y: card.minY + 150, width: 60, height: 54))
                AppUI.center(face, g, "\(temp(h.temp))°", AppUI.font(38, .semibold), cx: cx + 6, y: card.minY + 248, white)
                note(CGRect(x: cx - colW / 2, y: card.minY + 96, width: colW, height: 166), "\(label), \(Face.weatherText(h.code)), \(temp(h.temp))°")
            }
            y = card.maxY + 32
        }
        // 10 天：範圍條依溫度上色，今天多一顆「目前溫度」的白點
        if let days = d.daily, !days.isEmpty {
            let rowH: CGFloat = 104, top: CGFloat = 84
            let card = CGRect(x: AppUI.margin, y: y, width: AppUI.contentW, height: top + rowH * CGFloat(days.count) + 4)
            module(card, symbol: "calendar", String(format: L("weather.daily", "%d 天预报"), days.count))
            let lo = days.map(\.lo).min() ?? 0, hi = days.map(\.hi).max() ?? 1
            for (i, day) in days.enumerated() {
                let mid = card.minY + top + CGFloat(i) * rowH + rowH / 2
                let name = dayName(day.date, index: i)
                AppUI.left(face, g, name, AppUI.font(38, .semibold), x: card.minX + 36, y: mid + 13, white)
                face.drawMulticolorSymbol(g, WeatherSky.of(code: day.code).symbol.day, in: CGRect(x: card.minX + 214, y: mid - 26, width: 60, height: 52))
                AppUI.right(face, g, "\(temp(day.lo))°", AppUI.font(38, .semibold), rightX: card.minX + 420, y: mid + 13, white.withAlphaComponent(0.5))
                let bar = CGRect(x: card.minX + 450, y: mid - 6, width: 290, height: 12)
                AppUI.fillPill(g, bar, color: NSColor(srgbRed: 0, green: 0, blue: 0.05, alpha: 0.2))
                let span = max(1, hi - lo)
                let b0 = bar.minX + bar.width * CGFloat((day.lo - lo) / span), b1 = bar.minX + bar.width * CGFloat((day.hi - lo) / span)
                let seg = CGRect(x: b0, y: bar.minY, width: max(12, b1 - b0), height: bar.height)
                g.saveGState()
                g.addPath(CGPath(roundedRect: seg, cornerWidth: 6, cornerHeight: 6, transform: nil)); g.clip()
                // 漸層畫滿整條軌道的溫度範圍，只露出這一天那段（跟系統一樣：同一溫度在每一列同色）
                if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [Self.tempColor(lo).cgColor, Self.tempColor((lo + hi) / 2).cgColor, Self.tempColor(hi).cgColor] as CFArray, locations: [0, 0.5, 1]) {
                    g.drawLinearGradient(grad, start: CGPoint(x: bar.minX, y: 0), end: CGPoint(x: bar.maxX, y: 0), options: [])
                }
                g.restoreGState()
                if i == 0 {
                    let cx = bar.minX + bar.width * CGFloat((min(max(d.temp, lo), hi) - lo) / span)
                    let dot = CGRect(x: cx - 9, y: mid - 9, width: 18, height: 18)
                    g.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 0.05, alpha: 0.35).cgColor); g.fillEllipse(in: dot.insetBy(dx: -3, dy: -3))
                    g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: dot)
                }
                AppUI.right(face, g, "\(temp(day.hi))°", AppUI.font(38, .semibold), rightX: card.maxX - 36, y: mid + 13, white)
                if i < days.count - 1 {
                    g.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor); g.fill(CGRect(x: card.minX + 36, y: mid + rowH / 2 - 1, width: card.width - 72, height: 2))
                }
                note(CGRect(x: card.minX, y: mid - rowH / 2, width: card.width, height: rowH),
                     "\(name), \(Face.weatherText(day.code)), " + String(format: L("weather.hiLo", "高 %d° 低 %d°"), temp(day.hi), temp(day.lo)))
            }
            y = card.maxY + 32
        }
        // 四格：日出前顯示日出，其餘顯示日落（系統天氣顯示「下一個」事件）
        let nowMin = { () -> Int in let c = Calendar.current.dateComponents([.hour, .minute], from: Face.displayDate); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }()
        let beforeSunrise = Self.minutes(d.sunrise).map { nowMin < $0 } ?? false
        let wind = imperial ? String(format: "%.0f mph", d.wind * 0.621371) : String(format: "%.0f km/h", d.wind)
        let tiles: [(String, String, String, String?)] = [
            beforeSunrise ? ("sunrise.fill", L("weather.sunrise", "日出"), d.sunrise.map(Face.localTime) ?? dash, nil) : ("sunset.fill", L("weather.sunset", "日落"), d.sunset.map(Face.localTime) ?? dash, nil),
            ("aqi.medium", L("weather.aqi", "空气质量"), d.aqi.map { String(format: "%.0f", $0) } ?? dash, d.aqi.map(Self.aqiText)),
            ("humidity.fill", L("weather.humidity", "湿度"), String(format: "%.0f%%", d.humidity), nil),
            ("wind", L("weather.wind", "风速"), wind, nil),
        ]
        for (i, t) in tiles.enumerated() {
            let r = CGRect(x: AppUI.margin + CGFloat(i % 2) * 460, y: y + CGFloat(i / 2) * 216, width: 436, height: 192)
            let sym = NSImage(systemSymbolName: t.0, accessibilityDescription: nil) != nil ? t.0 : "circle.dotted"
            module(r, symbol: sym, t.1)
            AppUI.left(face, g, t.2, AppUI.font(64, .medium), x: r.minX + 36, y: r.minY + 156, white)
            if let sub = t.3 { AppUI.right(face, g, sub, AppUI.font(30, .semibold), rightX: r.maxX - 36, y: r.minY + 156, white) }
            if i == 1, let a = d.aqi {
                // 空氣品質：系統的彩虹條＋位置點（0–300）
                let bar = CGRect(x: r.minX + 36, y: r.minY + 172, width: r.width - 72, height: 8)
                g.saveGState(); g.addPath(CGPath(roundedRect: bar, cornerWidth: 4, cornerHeight: 4, transform: nil)); g.clip()
                if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [srgb(0x30d158).cgColor, srgb(0xffd60a).cgColor, srgb(0xff9f0a).cgColor, srgb(0xff453a).cgColor, srgb(0xbf5af2).cgColor, srgb(0x8e2140).cgColor] as CFArray,
                                         locations: [0, 0.17, 0.33, 0.5, 0.67, 1]) {
                    g.drawLinearGradient(grad, start: CGPoint(x: bar.minX, y: 0), end: CGPoint(x: bar.maxX, y: 0), options: [])
                }
                g.restoreGState()
                let cx = bar.minX + bar.width * CGFloat(min(1, max(0, a / 300)))
                g.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor); g.fillEllipse(in: CGRect(x: cx - 9, y: bar.midY - 9, width: 18, height: 18))
                g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: cx - 6, y: bar.midY - 6, width: 12, height: 12))
            }
            note(r, [t.1, t.2, t.3].compactMap { $0 }.joined(separator: ", "))
        }
        g.restoreGState()
        WeatherLiveSky.shared.setColliders(colliders)
        return y + 2 * 216 + 40 - o
    }
}
