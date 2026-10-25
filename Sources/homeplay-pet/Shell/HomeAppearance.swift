// 2.0 P02：主畫面外觀（淺色／深色／清透／染色）與小工具渲染模式（fullColor／accented／vibrant）。
//
// 依據（HIG › Widgets › Rendering modes 與 Apple HomeView 一節；HIG › App icons）：
// - 「iPad、iPhone 與 Apple HomeView 的主畫面讓人替小工具選外觀：淺色、深色、清透、染色。淺色與深色是全彩；
//   清透時系統把小工具去飽和，加上半透明、高光與 Liquid Glass；染色時系統把小工具與內容去飽和，再套上選的色。」
// - 渲染模式：淺色／深色＝fullColor；清透／染色＝accented（拿掉背景，染色換成染色效果、清透換成 Liquid Glass；
//   內容分成 accent 組與 primary 組，各上一個實色）；Modular 錶面的夜間模式＝vibrant（Faces/NightFace.swift 的紅）。
// - 圖示：「人可以選主畫面圖示是預設、深色、清透或染色；沒提供的變體由系統自動產生」，「各外觀保持同樣的核心特徵」。
//
// 圖示變體怎麼來（使用者 2026-10-25：預設用系統原生圖示，鬧鐘／計時器／世界時鐘／對講用 HomeView 官網圖示）：
// 系統圖示與官網圖示都是一張拍平的圖，拿不到 Icon Composer 的分層，所以我們照「系統自動產生」的做法自己從那張圖推：
//   1. 每一列取左右邊緣的顏色當「底」（多數圖示的底是上下漸層，逐列取就跟著漸層走）；
//   2. 每個像素離那一列底色的距離 → 主體權重 w（0＝底、1＝主體），等於把圖示拆回「底＋主體」兩層；
//   3. 深色：底換成近黑的上下漸層（#2C2C2E → #0E0E10），主體保留原色；主體是白／灰而底是彩色的（音樂、訊息…）就把主體染成底色，
//      主體太暗（白底上的黑字）就翻成白——跟 iOS 深色圖示「彩色底→黑底、白主體→彩色主體」同一個方向；
//   4. 清透：去飽和；底挖空給 Liquid Glass（主畫面那一層用 HPGlass 一個容器一起畫，見 HomeScreen 的靜態層），主體依亮度轉成白；
//   5. 染色：去飽和；底是所選色的深色版（半透明，玻璃透出來），主體是所選色依亮度提亮。
// 主畫面的桌布偏暗（HPTokens.Home.wallpaperMaxLum），所以清透與染色用的是 HIG 表裡的「clear dark／tinted dark」那一組。
// 算一次快取（圖示 id＋外觀＋色＋像素），不連網、不落地。

import AppKit
import CoreImage

enum HomeAppearance: String, CaseIterable, Codable {
    case light, dark, clear, tinted

    var title: String {
        switch self {
        case .light: return L("home.appearance.light", "浅色")
        case .dark: return L("home.appearance.dark", "深色")
        case .clear: return L("home.appearance.clear", "透明")
        case .tinted: return L("home.appearance.tinted", "着色")
        }
    }
    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .clear: return "circle.dashed"
        case .tinted: return "paintpalette"
        }
    }

    static let key = "shell.homeAppearance"
    static let tintKey = "shell.homeTint"
    /// 快照：--home-appearance light|dark|clear|tinted（不存偏好）；--home-tint RRGGBB
    static let forced: HomeAppearance? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--home-appearance"), i + 1 < a.count else { return nil }
        return HomeAppearance(rawValue: a[i + 1])
    }()
    static let forcedTint: UInt32? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--home-tint"), i + 1 < a.count else { return nil }
        return UInt32(a[i + 1].replacingOccurrences(of: "#", with: ""), radix: 16)
    }()

    nonisolated(unsafe) private static var stored: HomeAppearance =
        UserDefaults.standard.string(forKey: key).flatMap(HomeAppearance.init(rawValue:)) ?? .light
    nonisolated(unsafe) private static var storedTint: UInt32? =
        (UserDefaults.standard.object(forKey: tintKey) as? NSNumber).map { UInt32(truncating: $0) }

    /// 現在的主畫面外觀（快照旗標優先）
    static var current: HomeAppearance { forced ?? stored }
    /// 設定 › 外觀 › 主畫面外觀
    static func set(_ a: HomeAppearance) {
        stored = a
        if forced == nil { UserDefaults.standard.set(a.rawValue, forKey: key) }
        Shell.homeLayer = nil
    }
    /// 染色的色：自己選過就用那個；沒選過就從桌布取（跟 iOS 一樣先建議桌布的色相）
    static var tintHex: UInt32? { forcedTint ?? storedTint }
    static var tintColor: NSColor {
        if let h = tintHex { return srgb(h) }
        let hue = Shell.homeHue ?? 0.58
        return NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1)
    }
    static func setTint(_ c: NSColor) {
        guard let s = c.usingColorSpace(.sRGB) else { return }
        let hex = UInt32((s.redComponent * 255).rounded()) << 16 | UInt32((s.greenComponent * 255).rounded()) << 8 | UInt32((s.blueComponent * 255).rounded())
        storedTint = hex
        if forcedTint == nil { UserDefaults.standard.set(NSNumber(value: hex), forKey: tintKey) }
        Shell.homeLayer = nil
    }

    /// 這個外觀的小工具渲染模式；夜間（Modular／主畫面轉紅）一律 vibrant
    func renderMode(night: Bool) -> WidgetRenderMode {
        if night { return .vibrant }
        switch self {
        case .light, .dark: return .fullColor
        case .clear, .tinted: return .accented
        }
    }
    /// 小工具的系統底（請求卡、世界時鐘）要不要用深色
    var widgetDark: Bool { self == .dark || HPTokens.dark }
    /// 桌布：深色外觀把桌布再壓暗（iOS 深色主畫面同樣調暗桌布），染色稍暗，淺色與清透照舊
    var wallpaperShade: CGFloat {
        switch self {
        case .light, .clear: return 0
        case .dark: return 0.38
        case .tinted: return 0.16
        }
    }
    /// 圖示與小工具底要不要換成 Liquid Glass（清透、染色）
    var glassBase: Bool { self == .clear || self == .tinted }
    /// 快取 key 用
    var cacheKey: String { self == .tinted ? "tinted-\(String(HomeAppearance.tintHex ?? 0, radix: 16))-\(Int((Shell.homeHue ?? 0) * 100))" : rawValue }
}

/// HIG 的三種小工具渲染模式（WidgetRenderingMode）
enum WidgetRenderMode: Equatable {
    case fullColor, accented, vibrant
}

/// accented 模式的兩組實色（HIG：「把小工具的視圖分成 accent 組與 primary 組，各上一個實色」；iPhone 上清透時兩組都是白）
struct WidgetInk {
    var primary: NSColor
    var accent: NSColor
    var secondary: NSColor

    static func of(_ a: HomeAppearance, tint: NSColor = HomeAppearance.tintColor) -> WidgetInk {
        switch a {
        case .tinted:
            let lt = tint.blended(withFraction: 0.55, of: .white) ?? tint
            let ac = HomeIconVariant.bright(tint)
            return WidgetInk(primary: lt, accent: ac, secondary: lt.withAlphaComponent(0.7))
        default:
            return WidgetInk(primary: .white, accent: .white, secondary: NSColor.white.withAlphaComponent(0.7))
        }
    }
}

// MARK: - 圖示變體（從拍平的圖推「底＋主體」兩層，見檔頭）

enum HomeIconVariant {
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]
    nonisolated(unsafe) private static var order: [String] = []

    /// 所選色提亮到看得見的程度（深底上的主體）
    static func bright(_ c: NSColor) -> NSColor {
        guard let s = c.usingColorSpace(.sRGB) else { return c }
        return NSColor(hue: s.hueComponent, saturation: min(0.75, max(0.35, s.saturationComponent)), brightness: max(0.92, s.brightnessComponent), alpha: 1)
    }

    /// make：畫出原本（淺色）的圖示；tag：來源（系統／官網／HPIcons、日期）變了就重算。light 不經過這裡
    static func image(id: String, tag: String, px: Int, appearance a: HomeAppearance, tint: NSColor = HomeAppearance.tintColor, make: () -> CGImage) -> CGImage {
        let key = "\(id)|\(tag)|\(a.cacheKey)|\(px)"
        if let c = cache[key] { return c }
        let src = make()
        let out = a == .light ? src : (derive(src, a, tint: tint) ?? src)
        cache[key] = out; order.append(key)
        if order.count > 96 { cache[order.removeFirst()] = nil }
        return out
    }

    /// 純像素運算（selftest 直接驗）：RGBA premultiplied 8-bit
    static func derive(_ src: CGImage, _ a: HomeAppearance, tint: NSColor) -> CGImage? {
        let w = src.width, h = src.height
        guard w > 8, h > 8, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        @inline(__always) func px(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let i = (y * w + x) * 4
            let al = Double(p[i + 3]) / 255
            guard al > 0.01 else { return (0, 0, 0, 0) }
            return (Double(p[i]) / 255 / al, Double(p[i + 1]) / 255 / al, Double(p[i + 2]) / 255 / al, al)
        }
        // 1. 每列的底色：左右各取 6%–10% 那一小段（圓角那幾列往內縮到有不透明像素的地方）
        var base = [(Double, Double, Double)](repeating: (0, 0, 0), count: h)
        var baseSat = 0.0, baseLum = 0.0, nb = 0.0
        for y in 0..<h {
            var acc = (0.0, 0.0, 0.0), n = 0.0
            let band = max(2, w / 16)
            var x0 = 0; while x0 < w / 2, px(x0, y).3 < 0.9 { x0 += 1 }
            var x1 = w - 1; while x1 > w / 2, px(x1, y).3 < 0.9 { x1 -= 1 }
            if x1 - x0 < band * 4 { x0 = w / 8; x1 = w - 1 - w / 8 }
            for x in Array(x0 + band / 2 ..< x0 + band + band / 2) + Array(x1 - band - band / 2 ... x1 - band / 2) where x >= 0 && x < w {
                let c = px(x, y); guard c.3 > 0.5 else { continue }
                acc.0 += c.0; acc.1 += c.1; acc.2 += c.2; n += 1
            }
            if n > 0 { base[y] = (acc.0 / n, acc.1 / n, acc.2 / n) } else if y > 0 { base[y] = base[y - 1] }
        }
        // 頂端幾列可能整列都在圓角外：拿第一個有值的列補
        if let first = base.firstIndex(where: { $0 != (0, 0, 0) }) { for y in 0..<first { base[y] = base[first] } }
        for y in stride(from: h / 8, to: h - h / 8, by: max(1, h / 32)) {
            let b = base[y]
            let mx = max(b.0, b.1, b.2), mn = min(b.0, b.1, b.2)
            baseSat += mx > 0 ? (mx - mn) / mx : 0; baseLum += lum(b); nb += 1
        }
        baseSat /= max(1, nb); baseLum /= max(1, nb)
        let baseColor = base[h / 2]
        let tintS = tint.usingColorSpace(.sRGB) ?? tint
        let tc = (Double(tintS.redComponent), Double(tintS.greenComponent), Double(tintS.blueComponent))
        let tb = bright(tint).usingColorSpace(.sRGB) ?? tint
        let tbc = (Double(tb.redComponent), Double(tb.greenComponent), Double(tb.blueComponent))
        // 主體染底色時用的亮版底色（深底上要看得見）
        let baseBright: (Double, Double, Double) = {
            let c = NSColor(srgbRed: baseColor.0, green: baseColor.1, blue: baseColor.2, alpha: 1)
            let b = bright(c).usingColorSpace(.sRGB) ?? c
            return (Double(b.redComponent), Double(b.greenComponent), Double(b.blueComponent))
        }()
        for y in 0..<h {
            let b = base[y]
            let t = Double(y) / Double(h - 1)
            for x in 0..<w {
                let i = (y * w + x) * 4
                let c = px(x, y)
                guard c.3 > 0.003 else { continue }
                let d = sqrt((c.0 - b.0) * (c.0 - b.0) + (c.1 - b.1) * (c.1 - b.1) + (c.2 - b.2) * (c.2 - b.2))
                let wgt = smooth((d - 0.06) / 0.30)          // 主體權重
                let l = lum((c.0, c.1, c.2))
                let mx = max(c.0, c.1, c.2), mn = min(c.0, c.1, c.2)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                var o: (Double, Double, Double), oa: Double
                switch a {
                case .dark:
                    let bd = mix((0.172, 0.172, 0.180), (0.055, 0.055, 0.063), t)   // 近黑的上下漸層
                    var g = (c.0, c.1, c.2)
                    if sat < 0.22 && baseSat > 0.3 && l > 0.55 { g = mix(baseBright, g, 0.15) }   // 白主體＋彩色底 → 主體染底色
                    else if l < 0.28 && baseLum > 0.7 { g = (0.94, 0.94, 0.95) }                     // 白底上的黑字 → 翻成白
                    o = mix(bd, g, wgt); oa = 1
                case .clear:
                    // 去飽和：主體依亮度轉白（暗主體在亮底上一樣當主體，用權重不用亮度）；底挖空給玻璃，留一層薄白
                    let gv = 0.82 + 0.18 * l
                    o = mix((1, 1, 1), (gv, gv, gv), wgt)
                    oa = 0.10 * (1 - wgt) + 0.94 * wgt
                case .tinted:
                    let dk = (tc.0 * 0.22, tc.1 * 0.22, tc.2 * 0.22)
                    let fg = mix(tbc, (1, 1, 1), 0.25 * l)
                    o = mix(dk, fg, wgt)
                    oa = 0.62 * (1 - wgt) + 0.97 * wgt
                case .light:
                    o = (c.0, c.1, c.2); oa = 1
                }
                let al = c.3 * oa
                p[i] = UInt8(max(0, min(255, o.0 * al * 255)))
                p[i + 1] = UInt8(max(0, min(255, o.1 * al * 255)))
                p[i + 2] = UInt8(max(0, min(255, o.2 * al * 255)))
                p[i + 3] = UInt8(max(0, min(255, al * 255)))
            }
        }
        return ctx.makeImage()
    }

    @inline(__always) static func lum(_ c: (Double, Double, Double)) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }
    @inline(__always) static func smooth(_ x: Double) -> Double { let t = max(0, min(1, x)); return t * t * (3 - 2 * t) }
    @inline(__always) static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
}

// MARK: - 照片類內容的去飽和（清透：灰階、半透明；染色：灰階再乘所選色）

enum WidgetImageTreatment {
    nonisolated(unsafe) private static var cache: (key: String, image: CGImage)?

    /// 照 accented 的規則處理一張全彩圖（HIG：清透／染色時系統預設把全彩圖去飽和）
    static func accented(_ img: CGImage, appearance a: HomeAppearance, tint: NSColor = HomeAppearance.tintColor) -> CGImage {
        guard a.glassBase else { return img }
        let key = "\(ObjectIdentifier(img).hashValue)|\(img.width)|\(a.cacheKey)"
        if let c = cache, c.key == key { return c.image }
        let ci = CIImage(cgImage: img)
        var out = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.05])
        if a == .tinted, let t = tint.usingColorSpace(.sRGB) {
            out = out.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: CIColor(red: t.redComponent, green: t.greenComponent, blue: t.blueComponent),
                                                                       kCIInputIntensityKey: 1])
        }
        let res = Face.ciContext.createCGImage(out, from: ci.extent) ?? img
        cache = (key, res)
        return res
    }
    /// 去飽和圖疊在玻璃上的不透明度（清透要透出玻璃；染色比較實）
    static func alpha(_ a: HomeAppearance) -> CGFloat { a == .clear ? 0.62 : (a == .tinted ? 0.85 : 1) }
}

// MARK: - selftest（純邏輯與像素）

enum HomeAppearanceSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        check(HomeAppearance.light.renderMode(night: false) == .fullColor && HomeAppearance.dark.renderMode(night: false) == .fullColor
              && HomeAppearance.clear.renderMode(night: false) == .accented && HomeAppearance.tinted.renderMode(night: false) == .accented
              && HomeAppearance.light.renderMode(night: true) == .vibrant,
              "主畫面外觀：淺／深＝fullColor、清透／染色＝accented、夜間＝vibrant（HIG 渲染模式表）")   // l10n-ignore：selftest 訊息
        // 一張「紅底白音符」的假圖示：深色＝黑底＋紅主體；清透＝灰階、底半透明；染色＝主體是所選色
        let icon = makeImage(64, 64) { g in
            g.setFillColor(srgb(0xFA233B).cgColor); g.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: 22, y: 22, width: 20, height: 20))
        }
        func sample(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
            return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
        }
        if let dark = HomeIconVariant.derive(icon, .dark, tint: .systemBlue) {
            let bg = sample(dark, 4, 32), fg = sample(dark, 32, 32)
            check(bg.r < 60 && bg.g < 60 && fg.r > 180 && fg.g < 140, "圖示深色變體：底變近黑、白主體染成原本的紅（\(bg)／\(fg)）")
        } else { check(false, "圖示深色變體：產生失敗") }
        if let clear = HomeIconVariant.derive(icon, .clear, tint: .systemBlue) {
            let bg = sample(clear, 4, 32), fg = sample(clear, 32, 32)
            check(bg.a < 60 && fg.a > 200 && abs(fg.r - fg.b) < 12, "圖示清透變體：底挖空給玻璃、主體灰階（\(bg)／\(fg)）")
        } else { check(false, "圖示清透變體：產生失敗") }
        if let tinted = HomeIconVariant.derive(icon, .tinted, tint: srgb(0x0088FF)) {
            let fg = sample(tinted, 32, 32)
            check(fg.b > fg.r + 60, "圖示染色變體：主體是所選的藍（\(fg)）")
        } else { check(false, "圖示染色變體：產生失敗") }
        let ink = WidgetInk.of(.tinted, tint: srgb(0x34C759))
        check(ink.accent != ink.primary && WidgetInk.of(.clear).primary == .white, "小工具 accented：accent 組與 primary 組各一個實色；清透都是白")
    }
}
