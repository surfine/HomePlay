// 2.0 P02：主畫面的小工具（天氣、世界時鐘；照片在 Shell/PhotosWidget.swift）、主畫面外觀的圖示與玻璃底、編輯模式與小工具圖庫。
//
// - 小工具照 WidgetRenderMode 取色（Shell/HomeAppearance.swift）：fullColor＝原本的設計（深色外觀換深色版）；
//   accented＝拿掉背景（清透：Liquid Glass；染色：所選色的染色效果），內容分 primary 組（城市、溫度、高低溫）與 accent 組（天氣符號、定位箭頭），各一個實色；
//   vibrant＝夜間，交給 Faces/NightFace.swift 整面轉紅。
// - 佔位內容（HIG：靜態元件＋半透明形狀代替會變的內容）：天氣還沒有資料時，定位箭頭與符號照畫，文字換成不同寬的半透明圓角條。
// - 資料舊了（超過 2 小時沒更新）照樣顯示舊資料，最後一行標「更新於 14:05」（HIG：不要把舊資料藏在佔位內容後面）。
// - 編輯模式：主畫面長按 0.5 秒進入；圖示與小工具左上「−」拿掉，左上「＋」開小工具圖庫，右上「完成」離開，點空白處也離開。
// - 小工具圖庫：一張玻璃 sheet，三個小工具的真實預覽（照片用示範圖、天氣與世界時鐘用示範資料：HIG「資料太慢就用逼真的模擬資料」）、
//   名稱與一句動詞開頭的說明；最下面「還原預設主畫面」。

import AppKit

extension Shell {
    nonisolated(unsafe) static var homeEditing = CommandLine.arguments.contains("--home-edit") || CommandLine.arguments.contains("--widget-gallery")
    nonisolated(unsafe) static var widgetGallery = CommandLine.arguments.contains("--widget-gallery")
    /// 快照：--weather-placeholder＝天氣小工具畫「載入中」的佔位內容
    static let weatherPlaceholderForced = CommandLine.arguments.contains("--weather-placeholder")
    nonisolated(unsafe) static var lastHomeMinute = -1

    /// 右上「完成」：跟左上返回鈕左右對稱、等高（HPTokens.backButton），圓角是膠囊
    static var editDoneRect: CGRect {
        let b = HPTokens.backButton, w: CGFloat = 196
        return CGRect(x: 1024 - b.minX - w, y: b.minY, width: w, height: b.height)
    }

    // MARK: 資料舊了：「更新於 …」

    static let weatherStaleAfter: TimeInterval = 2 * 3600
    /// 超過 2 小時沒更新就回「更新於 14:05」（隔天以上加日期）；新的資料回 nil
    static func weatherUpdatedCaption(_ updatedAt: Date?, now: Date, locale: Locale = .current) -> String? {
        guard let at = updatedAt, now.timeIntervalSince(at) > weatherStaleAfter else { return nil }
        let f = DateFormatter(); f.locale = locale
        Face.setTimeFormat(f, datePrefix: Calendar.current.isDate(at, inSameDayAs: now) ? "" : "Md")   // 2.0 depth：時制照系統
        return String(format: L("shell.weather.updated", "更新于 %@"), f.string(from: at))
    }

    /// 主畫面每幀：小工具要不要重畫（世界時鐘換分鐘、天氣資料到了）
    static func homeWidgetsDirty() -> Bool {
        var dirty = false
        let m = Int(Date().timeIntervalSince1970 / 60)
        if m != lastHomeMinute { lastHomeMinute = m; dirty = true }
        let v = WeatherSource.shared.version
        if v != lastWeatherVersion { lastWeatherVersion = v; dirty = true }
        return dirty
    }

    // MARK: 圖示：照主畫面外觀出變體

    /// 主畫面上的一個 App 圖示：淺色照原樣；深色／清透／染色從原圖推變體（HomeIconVariant）
    static func drawHomeIcon(_ g: CGContext, face: Face, app: PetApp, in r: CGRect) {
        let a = HomeAppearance.current
        guard a != .light else { drawAppIcon(g, face: face, icon: app.icon, in: r, appID: app.id); return }
        let px = max(64, Int((r.width * face.renderPixelScale).rounded()))
        let source = OfficialIcons.names[app.id] != nil ? (OfficialIcons.icon(app.id, px: px) != nil ? "official" : "hp") : "system"
        let tag = app.icon.calendarDate || app.id == "calendar" ? "\(source)|\(homeDayKey(Face.displayDate))" : source
        let ga = HPIconGlass.enabled ? Double(HPIconGlass.current.glyphAlpha) : 0.94   // P0：玻璃圖示的主體照深淺／增加對比
        let img = HomeIconVariant.image(id: app.id, tag: tag, px: px, appearance: a, glyphAlpha: ga) {
            makeImage(px, px) { c in
                let k = CGFloat(px) / r.width
                c.scaleBy(x: k, y: k)
                drawAppIcon(c, face: face, icon: app.icon, in: CGRect(x: 0, y: 0, width: r.width, height: r.height), appID: app.id)
            }
        }
        face.drawUpright(g, img, in: r)   // makeImage 畫布上照常畫好的圖：跟其他 Core Graphics 圖一樣轉正貼上
    }

}

// MARK: - 小工具框：照渲染模式

extension HPComponents {
    /// 2.0 P02：照 WidgetRenderMode 畫小工具的底。fullColor＝上下漸層（深色外觀壓暗成深色版）；accented＝拿掉背景
    /// （主畫面上底下已經是玻璃；standalone＝圖庫預覽這種底下沒有玻璃的，補一層薄白＋細邊代表玻璃）；vibrant＝拿掉背景
    static func widgetFrame(_ g: CGContext, _ r: CGRect, top: CGColor, bottom: CGColor, mode: WidgetRenderMode,
                            appearance: HomeAppearance, standalone: Bool = false, radius: CGFloat = HPTokens.Radius.widget) {
        switch mode {
        case .fullColor:
            if appearance == .dark, let t = NSColor(cgColor: top), let b = NSColor(cgColor: bottom) {
                widgetFrame(g, r, top: (t.blended(withFraction: 0.45, of: .black) ?? t).cgColor, bottom: (b.blended(withFraction: 0.55, of: .black) ?? b).cgColor, radius: radius)
            } else {
                widgetFrame(g, r, top: top, bottom: bottom, radius: radius)
            }
        case .accented:
            let p = continuousRoundedRect(r, radius: radius)
            if !standalone {
                // 主畫面上底下已經是玻璃：染色再蓋一層所選色的深色版（跟染色圖示的底同一個值），淺色字才讀得到；清透就讓玻璃透出來
                if appearance == .tinted {
                    let t = HomeAppearance.tintColor.usingColorSpace(.sRGB) ?? .gray
                    g.saveGState(); g.addPath(p)
                    g.setFillColor(NSColor(srgbRed: t.redComponent * 0.22, green: t.greenComponent * 0.22, blue: t.blueComponent * 0.22, alpha: 0.62).cgColor)
                    g.fillPath(); g.restoreGState()
                }
                return
            }
            let fill = appearance == .tinted ? HomeAppearance.tintColor.blended(withFraction: 0.78, of: .black) ?? .black : NSColor(white: 1, alpha: 0.14)
            g.saveGState(); g.addPath(p); g.setFillColor(fill.withAlphaComponent(appearance == .tinted ? 0.75 : 0.14).cgColor); g.fillPath(); g.restoreGState()
            g.saveGState(); g.addPath(p); g.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor); g.setLineWidth(2); g.strokePath(); g.restoreGState()
        case .vibrant:
            return
        }
    }
}

// MARK: - 畫：天氣、世界時鐘、編輯模式、圖庫

extension Face {
    /// 天氣 small 小工具（照 iOS 天氣小工具：天色漸層底、城市＋定位箭頭、大溫度、符號、狀況、高低溫）
    func drawWeatherWidget(_ g: CGContext, _ wr: CGRect, appearance a: HomeAppearance, preview: Bool = false) {
        let src = WeatherSource.shared
        var d: WeatherData?, updatedAt: Date?
        if preview {
            d = WeatherData(temp: 22, hi: 25, lo: 19, code: 2, wind: 11, humidity: 76, aqi: nil, sunset: nil, city: L("city.cupertino", "库比蒂诺"), night: false)
        } else if !Shell.weatherPlaceholderForced {
            src.activate { [weak self] in self?.forceDirty = true }
            d = src.data ?? Self.demoWeather
            updatedAt = src.data == nil ? nil : src.updatedAt
        }
        let mode = a.renderMode(night: false)
        let imperial = Locale.current.measurementSystem == .us
        func temp(_ v: Double) -> Int { Int((imperial ? v * 9 / 5 + 32 : v).rounded()) }
        let k = wr.width / 158   // iOS 小工具 158 pt → 這裡的像素
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1).cgColor }
        let code = d?.code ?? 2
        let sky: (CGColor, CGColor) = {
            if d?.night == true { return (c(0.05, 0.09, 0.22), c(0.15, 0.20, 0.37)) }
            switch code {
            case 0, 1: return (c(0.25, 0.55, 0.90), c(0.17, 0.42, 0.79))
            case 2, 3, 45, 48: return (c(0.39, 0.53, 0.70), c(0.27, 0.40, 0.57))
            default: return (c(0.33, 0.40, 0.49), c(0.20, 0.26, 0.35))
            }
        }()
        g.saveGState(); defer { g.restoreGState() }
        g.addPath(continuousRoundedRect(wr, radius: Shell.widgetRadius)); g.clip()
        HPComponents.widgetFrame(g, wr, top: sky.0, bottom: sky.1, mode: mode, appearance: a, standalone: preview, radius: Shell.widgetRadius)
        let ink = mode == .accented ? WidgetInk.of(a) : WidgetInk(primary: HPTokens.onMedia, accent: HPTokens.onMedia, secondary: HPTokens.onMedia.withAlphaComponent(0.85))   // 2.0 P07：字色走語意 token（HIG-WID-171：天色＝媒體，字用 onMedia）
        let pad = 16 * k
        let cityF = HPType.sf(15 * k, .semibold)
        let tf = HPType.sf(13 * k, .semibold)
        // 佔位內容：靜態元件（定位箭頭、符號位置）照畫，會變的字換成半透明圓角條
        guard let d else {
            let ph = ink.primary.withAlphaComponent(0.28)
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                g.addPath(HPComponents.capsulePath(CGRect(x: wr.minX + x * k, y: wr.minY + y * k, width: w * k, height: h * k))); g.setFillColor(ph.cgColor); g.fillPath()
            }
            bar(16, 18, 62, 11)
            drawSymbol(g, "location.fill", in: CGRect(x: wr.minX + 82 * k, y: wr.minY + 18.5 * k, width: 10 * k, height: 10 * k), color: ink.accent.withAlphaComponent(0.5))
            bar(16, 40, 54, 30)
            g.setFillColor(ph.cgColor); g.fillEllipse(in: CGRect(x: wr.minX + pad, y: wr.maxY - pad - 47 * k, width: 15 * k, height: 15 * k))
            bar(16, 116, 70, 10)
            bar(16, 132, 92, 10)
            return
        }
        let city = Face.clipped(d.city ?? L("shell.weather.title", "天气"), cityF, wr.width - pad * 2 - 16 * k)
        drawLeft(g, city, font: cityF, x: wr.minX + pad, y: wr.minY + pad + 14 * k, color: ink.primary)
        drawSymbol(g, "location.fill", in: CGRect(x: wr.minX + pad + Typo.width(city, cityF) + 4 * k, y: wr.minY + pad + 3.5 * k, width: 10 * k, height: 10 * k), color: ink.accent)
        HPNumeric.draw(g, self, key: "widget.temp", "\(temp(d.temp))°", font: HPType.sf(42 * k, .regular), x: wr.minX + pad - 1.5 * k, y: wr.minY + pad + 56 * k, color: ink.primary)   // 動效包：數值變了用數字轉場
        let symbol = WeatherSky.of(code: code).symbol
        let symName = d.night == true ? symbol.night : symbol.day
        let stale = Shell.weatherUpdatedCaption(updatedAt, now: Date())
        let lines = [Face.weatherText(d.code), String(format: L("weather.hiLo", "高 %d° 低 %d°"), temp(d.hi), temp(d.lo))]
        if let stale {
            // 舊資料：符號與狀況擠成一行，最後一行淡字標更新時間
            drawSymbol(g, symName, in: CGRect(x: wr.minX + pad, y: wr.maxY - pad - 44 * k, width: 13 * k, height: 13 * k), color: ink.accent)
            drawLeft(g, Face.clipped(lines[0], tf, wr.width - pad * 2 - 17 * k), font: tf, x: wr.minX + pad + 17 * k, y: wr.maxY - pad - 33 * k, color: ink.primary)
            drawLeft(g, Face.clipped(lines[1], tf, wr.width - pad * 2), font: tf, x: wr.minX + pad, y: wr.maxY - pad - 17 * k, color: ink.primary)
            let sf = HPType.sf(11 * k, .medium)
            drawLeft(g, Face.clipped(stale, sf, wr.width - pad * 2), font: sf, x: wr.minX + pad, y: wr.maxY - pad - 2 * k, color: ink.secondary)
        } else {
            drawSymbol(g, symName, in: CGRect(x: wr.minX + pad, y: wr.maxY - pad - 47 * k, width: 15 * k, height: 15 * k), color: ink.accent)
            drawLeft(g, Face.clipped(lines[0], tf, wr.width - pad * 2), font: tf, x: wr.minX + pad, y: wr.maxY - pad - 18 * k, color: ink.primary)
            drawLeft(g, Face.clipped(lines[1], tf, wr.width - pad * 2), font: tf, x: wr.minX + pad, y: wr.maxY - pad - 2 * k, color: ink.primary)
        }
    }
}

// MARK: - selftest

enum HomeWidgetsSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        check(Shell.weatherUpdatedCaption(now.addingTimeInterval(-3600), now: now) == nil, "天氣小工具：1 小時前的資料不標更新時間")
        check(Shell.weatherUpdatedCaption(now.addingTimeInterval(-3 * 3600), now: now) != nil && Shell.weatherUpdatedCaption(nil, now: now) == nil,
              "天氣小工具：超過 2 小時標「更新於 …」；沒有資料不標")   // l10n-ignore：selftest 訊息
        check(HomeWidgetKind.allCases.allSatisfy { !$0.blurb.isEmpty && HomeWidgetKind.from($0.item) == $0 }, "小工具圖庫：每個都有說明")
    }
}
