// 錶面共用的「工藝層」：字體、字形路徑、液態玻璃數字。
// 參考：apple.com/apple-homeview 的錶面圖（Portraits 的玻璃大數字、Flow 的玻璃泡泡字、Typograph 的疊字）
// 與 watchOS 錶面說明的配圖。原則：
// - 數字用 SF 的寬度軸（compressed／condensed）而不是一律圓體：iOS 26 鎖定畫面和 HomeView 的大時間都是窄高的 SF；
// - 玻璃 = 背景的模糊折射（中間輕放大、邊緣更多）＋霜白抬亮＋左上亮右下暗的斜面細邊＋很淡的落影；
// - 畫布是 1024 邏輯單位、左上原點（makeImage 已翻轉）；陰影的 offset 走裝置座標（y 朝上），往下要給負值。

import AppKit
import CoreText

enum FaceType {
    nonisolated(unsafe) private static var cache: [String: NSFont] = [:]
    static func cached(_ k: String) -> NSFont? { cache[k] }
    static func store(_ k: String, _ f: NSFont) { cache[k] = f }
    /// 錶面在螢幕上的大小變了：光學尺寸跟著變，字體重建
    static func flush() { cache.removeAll(keepingCapacity: true) }

    /// SF Pro（可選寬度軸）、等寬數字：數字每分鐘跳動時不會左右晃
    static func sf(_ size: CGFloat, _ weight: NSFont.Weight, width: NSFont.Width = .standard, mono: Bool = true) -> NSFont {
        sfv(size, wght: wght(weight), wdth: wdth(width), mono: mono)   // Typography.swift：opsz 照螢幕上的實際字級
    }
    /// SF Pro Rounded
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight, mono: Bool = true) -> NSFont {
        sfv(size, wght: wght(weight), design: .rounded, mono: mono)
    }
    /// New York（系統襯線）：Typograph 的「古典」數字
    static func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let key = "ny|\(size)|\(weight.rawValue)"
        if let f = cache[key] { return f }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let d = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let f = NSFont(descriptor: d, size: size) ?? base
        cache[key] = f
        return f
    }
    /// 系統錶面數字字體（/System/Library/Fonts/ADTNumeric.ttc）：iOS 鎖定畫面（PosterBoard）、watchOS 錶面用的同一套。
    /// 家族與可變軸（實測 macOS 27）：
    /// - .SF Numeric：wdth 30…150、wght、GRAD
    /// - .SF Adaptive Numeric：HGHT 100…500（往上長高、筆畫粗細不變＝iOS 26「自適應時間」）、wdth 60…100、wght、GRAD
    /// - .SF Soft Numeric：wdth、wght、SOFT 0…100（轉角圓潤度）、GRAD；.SF Adaptive Soft Numeric 兼有 HGHT 與 SOFT
    /// - .SF Rounded / Rail / Stencil Numeric、.New York (Soft) Numeric（New York 也有 HGHT）、.ADT Slab Numeric
    enum Numeric: String {
        case sf = ".SF Numeric", adaptive = ".SF Adaptive Numeric", soft = ".SF Soft Numeric", adaptiveSoft = ".SF Adaptive Soft Numeric"
        case rounded = ".SF Rounded Numeric", rail = ".SF Rail Numeric", stencil = ".SF Stencil Numeric"
        case newYork = ".New York Numeric", slab = ".ADT Slab Numeric"
    }
    nonisolated(unsafe) private static var numericBases: [String: CTFontDescriptor]?
    private static func numericBase(_ family: Numeric) -> CTFontDescriptor? {
        if numericBases == nil {
            var m: [String: CTFontDescriptor] = [:]
            let url = URL(fileURLWithPath: "/System/Library/Fonts/ADTNumeric.ttc") as CFURL
            for d in (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor]) ?? [] {
                if let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String, m[fam] == nil { m[fam] = d }
            }
            numericBases = m
        }
        return numericBases?[family.rawValue]
    }
    /// 錶面數字字體；axes 用四字母軸名（"wght" "wdth" "HGHT" "SOFT" "GRAD"）。找不到這套字體時退回 SF Pro（同粗細、壓縮寬）。
    static func numeric(_ family: Numeric, _ size: CGFloat, _ axes: [String: CGFloat]) -> NSFont {
        let key = "num|\(family.rawValue)|\(size)|" + axes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        if let f = cache[key] { return f }
        let f: NSFont
        if var d = numericBase(family) {
            for (tag, v) in axes {
                let t = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                d = CTFontDescriptorCreateCopyWithVariation(d, NSNumber(value: t), v)
            }
            f = CTFontCreateWithFontDescriptor(d, size, nil) as NSFont
        } else {
            let w = axes["wght"].map { NSFont.Weight(rawValue: ($0 - 400) / 600 * 0.6) } ?? .regular
            f = NSFont.systemFont(ofSize: size, weight: w, width: .compressed)
        }
        cache[key] = f
        return f
    }

    private static func monoDigits(_ f: NSFont) -> NSFont {
        let d = f.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: f.pointSize) ?? f
    }
}

/// 一串字的字形外框（畫布座標：左上原點、y 朝下），基線在 y = 0、起筆在 x = 0
extension NSColor {
    /// 灰階值（不是灰階色彩空間也不會崩）
    var whiteComponentSafe: CGFloat { (usingColorSpace(.deviceGray) ?? self).whiteComponent }
}

struct GlyphShape {
    let path: CGPath
    /// 實際墨跡的外框（不是排版框）
    var ink: CGRect { path.boundingBoxOfPath }

    nonisolated(unsafe) private static var cache: [String: CGPath] = [:]

    init(_ s: String, font: NSFont, kern: CGFloat = 0) {
        // 可變字體同名不同軸（wdth、wght、opsz）：鍵要帶上變數，否則會拿到別的寬度的字形
        let vari = (CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]).map { $0.sorted { $0.key.intValue < $1.key.intValue }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? ""
        let key = "\(s)|\(font.fontName)|\(font.pointSize)|\(kern)|\(vari)|\(Typo.language)"
        if let p = Self.cache[key] { path = p; return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(font, kern: kern)))
        let out = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            for i in 0..<n {
                var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pos[i].x, ty: -pos[i].y)
                if let gp = CTFontCreatePathForGlyph(runFont, glyphs[i], &t) { out.addPath(gp) }
            }
        }
        // SF 可變字型的輪廓會互相重疊（例如 9 的直筆壓在圓上）：先合成不重疊的輪廓，
        // 否則斜面、折射帶這些「沿邊描一圈」的效果會在字裡面多描出一條線
        let clean = out.normalized()
        path = clean
        if Self.cache.count > 400 { Self.cache.removeAll() }
        Self.cache[key] = clean
    }
    init(path: CGPath) { self.path = path }

    /// 把墨跡外框等比（或分別縮放 x／y）塞進 r：大數字填滿高度時用
    func fitted(into r: CGRect, keepAspect: Bool = true, align: CGFloat = 0.5) -> GlyphShape {
        let b = ink
        guard b.width > 0, b.height > 0 else { return self }
        var sx = r.width / b.width, sy = r.height / b.height
        if keepAspect { let s = min(sx, sy); sx = s; sy = s }
        let w = b.width * sx
        var t = CGAffineTransform(translationX: r.minX + (r.width - w) * align, y: r.minY)
            .scaledBy(x: sx, y: sy).translatedBy(x: -b.minX, y: -b.minY)
        return GlyphShape(path: path.copy(using: &t) ?? path)
    }
    func transformed(_ t0: CGAffineTransform) -> GlyphShape {
        var t = t0
        return GlyphShape(path: path.copy(using: &t) ?? path)
    }
    /// 等比縮放到墨跡高 = h，再縱向拉長 stretch 倍（iOS 26 鎖定畫面那種窄高大數字），
    /// 墨跡的 (anchorX, 頂) 對到 at；anchorX 0＝左、0.5＝中、1＝右
    func tall(height h: CGFloat, stretch: CGFloat, at p: CGPoint, anchorX: CGFloat, maxWidth: CGFloat = .infinity) -> GlyphShape {
        let b = ink
        guard b.height > 0, b.width > 0 else { return self }
        let sy = h / b.height, sx = min(sy / stretch, maxWidth / b.width)   // 放不下就再拉窄一點，不出框
        let t = CGAffineTransform(translationX: p.x - b.width * sx * anchorX, y: p.y)
            .scaledBy(x: sx, y: sy).translatedBy(x: -b.minX, y: -b.minY)
        return transformed(t)
    }
    /// 自適應高數字（iOS 26 鎖定畫面那種）：在 SF Adaptive Numeric 的 HGHT 軸上找能填滿高寬比的那一檔，
    /// 再「等比」縮放到 height——筆畫粗細一致，不是把字硬拉長。anchorX：0 左、0.5 中、1 右；at 是墨跡頂端那一點。
    static func adaptive(_ s: String, height h: CGFloat, maxWidth: CGFloat, at p: CGPoint, anchorX: CGFloat,
                         weight: CGFloat, soft: CGFloat? = nil, family: FaceType.Numeric = .adaptive) -> GlyphShape {
        func shape(_ hght: CGFloat) -> GlyphShape {
            var axes: [String: CGFloat] = ["HGHT": hght, "wght": weight]
            if let soft { axes["SOFT"] = soft }
            return GlyphShape(s, font: FaceType.numeric(soft == nil ? family : .adaptiveSoft, 200, axes), kern: 0)
        }
        // 要的高寬比；HGHT 100…500 單調增加高度，二分找最接近的一檔
        let want = h / maxWidth
        var lo: CGFloat = 100, hi: CGFloat = 500
        let tallest = shape(hi).ink
        var pick = hi
        if tallest.height / max(1, tallest.width) > want {
            for _ in 0..<12 {
                let mid = (lo + hi) / 2, b = shape(mid).ink
                if b.height / max(1, b.width) > want { hi = mid } else { lo = mid }
            }
            pick = lo
        }
        let g = shape(pick), b = g.ink
        let k = min(h / max(1, b.height), maxWidth / max(1, b.width))
        let t = CGAffineTransform(translationX: p.x - b.width * k * anchorX, y: p.y)
            .scaledBy(x: k, y: k).translatedBy(x: -b.minX, y: -b.minY)
        return g.transformed(t)
    }

    func moved(_ dx: CGFloat, _ dy: CGFloat) -> GlyphShape {
        var t = CGAffineTransform(translationX: dx, y: dy)
        return GlyphShape(path: path.copy(using: &t) ?? path)
    }
    /// 置中：墨跡中心對到 c
    func centered(at c: CGPoint) -> GlyphShape { moved(c.x - ink.midX, c.y - ink.midY) }
    /// 時與分一組置中：12 小時制的單位數小時（2:49）也落在畫面正中，不偏右（24 小時制兩位數時本來就對稱）
    static func centeredPair(_ a: GlyphShape, _ b: GlyphShape, midX: CGFloat = 512) -> (GlyphShape, GlyphShape) {
        let dx = midX - a.ink.union(b.ink).midX
        return (a.moved(dx, 0), b.moved(dx, 0))
    }
}

/// 液態玻璃的參數（Portraits 的數字偏霜白、Flow 的泡泡偏飽滿）
struct GlassLook {
    var lift: CGFloat = 0.045         // 霜白抬亮
    var tint: NSColor = .clear        // 額外染色（Flow 用一點紫）
    var refraction: CGFloat = 1.05    // 中間的放大
    var edgeRefraction: CGFloat = 1.16
    var edgeBand: CGFloat = 0.06      // 邊緣折射帶寬（相對字高）
    var rim: CGFloat = 0.9            // 斜面高光強度
    var rimWidth: CGFloat = 0.010     // 斜面寬（相對字高）
    var shade: CGFloat = 0.16         // 右下內陰影
    var shadow: CGFloat = 0.16        // 落影
    var gloss: CGFloat = 0.0          // 上半部的鏡面高光（泡泡用）
    var saturation: CGFloat = 1.35    // 透出來的背景更鮮、更亮（vibrancy），不是蓋一層白變灰
    var brightness: CGFloat = 0.045
    var thickness: CGFloat = 0.14     // 內緣一圈暗帶（玻璃的厚度）
    static let portrait = GlassLook()
    static let bubble = GlassLook(lift: 0.04, refraction: 1.14, edgeRefraction: 1.40, edgeBand: 0.14, rim: 1.0, rimWidth: 0.018,
                                  shade: 0.22, shadow: 0.20, gloss: 0.42, saturation: 1.7, brightness: 0.05, thickness: 0.16)
}

extension Face {
    /// 錶面上顯示的「現在」：快照可用 --time 固定
    static var displayDate: Date { snapshotDateOverride ?? Date() }

    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    /// 快取的 DateFormatter（每分鐘重畫時不要每次新建）
    static func formatter(_ template: String, raw: Bool = false, timeZone: TimeZone? = nil) -> DateFormatter {
        let loc = L10n.language.locale
        let key = "\(template)|\(raw)|\(loc.identifier)|\(timeZone?.identifier ?? "")"
        if let f = formatters[key] { return f }
        let f = DateFormatter(); f.locale = loc
        if let timeZone { f.timeZone = timeZone }
        f.dateFormat = raw ? template : localizedFormat(template, loc)
        formatters[key] = f
        return f
    }
    /// 2.0 depth：系統設定的 12／24 小時制。Locale.current 帶著使用者在「日期與時間」的覆寫；
    /// 介面語言的 locale（L10n.language.locale）是用 identifier 建的，沒有這個覆寫，所以時制只問 current、寫法才問介面語言。
    /// 快照可用 HOMEPLAY_HOUR_CYCLE=12／24 固定。
    static var uses12Hour: Bool {
        if let v = ProcessInfo.processInfo.environment["HOMEPLAY_HOUR_CYCLE"] { return v == "12" }
        return (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? "H").contains("h")
    }
    /// 時間的模板（給 setLocalizedDateFormatFromTemplate／formatter）：時制照系統，上午／AM 的寫法與位置照介面語言
    static var timeTemplate: String { uses12Hour ? "hmm" : "Hmm" }
    /// 模板 → 這個語言的寫法。中文的 h 會帶出「清晨／凌晨」這種時段（B），iOS 的時間一律寫「上午／下午」（a），這裡換回 a
    static func localizedFormat(_ template: String, _ loc: Locale) -> String {
        let f = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: loc) ?? template
        return f.contains("B") ? f.replacingOccurrences(of: "B", with: "a") : f
    }
    /// 另外建的 DateFormatter 用：照 timeTemplate（前面可接日期模板）設好時間的寫法
    static func setTimeFormat(_ f: DateFormatter, datePrefix: String = "") { f.dateFormat = localizedFormat(datePrefix + timeTemplate, f.locale) }
    /// 清單、小工具、訊息裡的時間：「上午 7:12」「7:12 AM」「07:12」
    static func shortTime(_ d: Date, timeZone: TimeZone? = nil) -> String { formatter(timeTemplate, timeZone: timeZone).string(from: d) }
    /// 外殼右上的時間（iOS 狀態列）：12 小時制也不帶上午／下午
    static func statusClock(_ d: Date) -> String { formatter(uses12Hour ? "h:mm" : "H:mm", raw: true).string(from: d) }
    /// 逐時預報的小時（iOS 天氣）：12 小時制「下午3時」「3 PM」，24 小時制「15」
    static func hourLabel(_ hour: Int) -> String {
        guard uses12Hour, let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else { return String(format: "%02d", hour) }
        return formatter("ha").string(from: d)
    }
    /// 大數字的時間（鬧鐘列）：數字照系統時制，上午／下午拆出來畫小一號（iOS 鬧鐘），前或後照介面語言
    static func timeParts(hour: Int, minute: Int) -> (time: String, period: String?, periodFirst: Bool) {
        guard uses12Hour else { return (String(format: "%02d:%02d", hour, minute), nil, false) }
        let f = formatter("hmm"), h12 = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? f.amSymbol ?? "AM" : f.pmSymbol ?? "PM"
        return (String(format: "%d:%02d", h12, minute), period, (f.dateFormat ?? "").hasPrefix("a"))
    }
    /// 時與分（尊重系統 12／24 小時制，但大數字不帶 am/pm）
    static func hourMinute(_ d: Date) -> (h: String, m: String) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        var h = c.hour ?? 0
        if uses12Hour { h = h % 12; if h == 0 { h = 12 } }
        return (String(h), String(format: "%02d", c.minute ?? 0))
    }

    /// 液態玻璃字形（大時間、溫度、Flow 的水珠、家庭模塊的磚）：自己的厚玻璃 shader（Faces/LiquidGlass.swift，GPU），
    /// 參數照官方錶面圖校準（每款錶面一組）；GPU 不可用退回 CoreGraphics 版。clear 是清楚的背景、frosted 是模糊版；整組字形當同一片玻璃。
    /// tint：染色（字體與顏色的玻璃色）；lightTurn：亮邊轉多少（弧度，Flow 的光跟著人轉）
    func drawLiquidGlass(_ g: CGContext, _ shapes: [GlyphShape], key: String? = nil, clear: CGImage?, frosted: CGImage?,
                         params: LiquidGlassParams = .faceTime, tint: NSColor? = nil, lightTurn: CGFloat = 0,
                         fallback: GlassLook = .portrait) {
        let path = CGMutablePath()
        for s in shapes { path.addPath(s.path) }
        var params = params
        params.lightTurn = Float(lightTurn)
        if let t = tint?.usingColorSpace(.sRGB) { params.tint = SIMD4(Float(t.redComponent), Float(t.greenComponent), Float(t.blueComponent), Float(t.alphaComponent)) }
        // 斜面厚度相對「單顆字形」的高度（多行拼成一副時，聯集高度會讓小水珠變成巨厚透鏡、折射位移破百 px）
        let hs = shapes.map(\.ink.height).sorted(); let bezelHeight = hs.isEmpty ? path.boundingBoxOfPath.height : hs[hs.count / 2]
        if let clear, let r = LiquidGlass.shared.render(path: path, key: key, scale: renderPixelScale, backdrop: clear, frosted: frosted, params: params, bezelHeight: bezelHeight) {
            drawUpright(g, r.image, in: r.rect)
        } else {
            for s in shapes { drawGlass(g, s, backdrop: frosted, look: fallback) }
        }
    }

    func drawGlass(_ g: CGContext, _ shape: GlyphShape, backdrop: CGImage?, look: GlassLook = .portrait, cacheKey: String? = nil) {
        guard shape.ink.width > 1, shape.ink.height > 1 else { return }
        glassBody(g, shape, backdrop: backdrop, look: look)
        guard let cacheKey else { glassDecor(g, shape, look: look); return }
        let sc = renderPixelScale
        let key = "\(cacheKey)|\(Int(sc * 100))"
        // 只存字形附近那一塊（含落影外擴），不存整張畫布：放到最大（2048²）時整張一份 16 MB，十幾份就上百 MB
        let pad = shape.ink.height * 0.12 + 8
        let rect = shape.ink.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024)).integral
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return }
        let img: CGImage
        if let hit = Self.decorCache[key] { img = hit } else {
            let pw = Int((rect.width * sc).rounded(.up)), ph = Int((rect.height * sc).rounded(.up))
            img = makeImage(pw, ph) { c in
                c.scaleBy(x: sc, y: sc)
                c.translateBy(x: -rect.minX, y: -rect.minY)
                self.glassDecor(c, shape, look: look)
            }
            if Self.decorCache.count >= 6 { Self.decorCache.removeAll() }   // 一個錶面最多四塊字；換分鐘時舊的整批丟掉
            Self.decorCache[key] = img
        }
        drawUpright(g, img, in: rect)
    }
    nonisolated(unsafe) private static var decorCache: [String: CGImage] = [:]

    /// 玻璃本體：字形裡透出背景（折射：中間輕放大，邊緣一圈放大更多）
    private func glassBody(_ g: CGContext, _ shape: GlyphShape, backdrop: CGImage?, look: GlassLook) {
        let path = shape.path, b = shape.ink
        let h = b.height, c = CGPoint(x: b.midX, y: b.midY)
        g.saveGState()
        g.addPath(path); g.clip()
        if let raw = backdrop {
            let backdrop = vibrant(raw, saturation: look.saturation, brightness: look.brightness)
            lens(g, backdrop, around: c, look.refraction)
            let band = h * look.edgeBand
            if band > 0.5 {
                g.saveGState()
                g.addPath(path); g.setLineWidth(band * 2); g.replacePathWithStrokedPath(); g.clip()
                g.setAlpha(0.85)
                lens(g, backdrop, around: c, look.edgeRefraction)
                g.restoreGState()
            }
        } else {
            g.setFillColor(NSColor(white: 0.5, alpha: 0.4).cgColor); g.fill(b)
        }
        g.restoreGState()
    }

    /// 玻璃的其餘部分（只跟字形有關）：落影、霜白、鏡面、厚度、斜面、外緣亮線
    private func glassDecor(_ g: CGContext, _ shape: GlyphShape, look: GlassLook) {
        let path = shape.path, b = shape.ink
        let h = b.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        // 1. 落影：很淡、很散，只為了讓字浮起來一點
        if look.shadow > 0 {
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -h * 0.02), blur: h * 0.07, color: NSColor(white: 0, alpha: look.shadow).cgColor)
            g.beginTransparencyLayer(auxiliaryInfo: nil)
            g.addPath(path); g.setFillColor(NSColor(white: 0, alpha: 1).cgColor); g.fillPath()
            g.setBlendMode(.clear); g.addPath(path); g.fillPath()   // 字裡面挖空，只留外面的影子
            g.endTransparencyLayer()
            g.restoreGState()
        }
        // 2. 霜白：上面多一點、下面少一點；染色；泡泡的鏡面
        g.saveGState()
        g.addPath(path); g.clip()
        let lift = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: look.lift * 1.25).cgColor,
                                                         NSColor(white: 1, alpha: look.lift * 0.75).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(lift, start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])
        if look.tint.alphaComponent > 0 { g.setFillColor(look.tint.cgColor); g.fill(b) }
        if look.gloss > 0 {
            let gl = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: look.gloss).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                locations: [0, 1])!
            g.drawLinearGradient(gl, start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.minY + h * 0.45), options: [])
        }
        g.restoreGState()
        // 3. 斜面：用兩道「內陰影」做——字外面的區域往右下挪、投一圈白色柔光進字的左上內緣；
        //    再往左上挪、投一圈暗影進右下內緣。邊是柔的，像玻璃厚度，不像描邊字。
        let rw = max(1.5, h * look.rimWidth)
        if look.thickness > 0 {
            innerShadow(g, path, b, offset: .zero, blur: rw * 4, color: NSColor(white: 0, alpha: look.thickness))
        }
        innerShadow(g, path, b, offset: CGSize(width: rw * 0.9, height: -rw * 0.9), blur: rw * 1.6,
                    color: NSColor(white: 1, alpha: min(1, look.rim)))
        innerShadow(g, path, b, offset: CGSize(width: rw * 0.25, height: -rw * 0.25), blur: rw * 0.35,
                    color: NSColor(white: 1, alpha: min(1, look.rim * 0.7)))
        if look.shade > 0 {
            innerShadow(g, path, b, offset: CGSize(width: -rw * 1.2, height: rw * 1.2), blur: rw * 2.2,
                        color: NSColor(white: 0, alpha: look.shade))
        }
        // 4. 外面一圈極淡的亮暈，讓玻璃在暗底上也分得出邊
        g.saveGState()
        g.addPath(path); g.setLineWidth(max(1, h * 0.0025)); g.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor); g.strokePath()
        g.restoreGState()
    }

    /// 內陰影：只在 path 裡面看得到；offset 走裝置座標（y 朝上）
    func innerShadow(_ g: CGContext, _ path: CGPath, _ b: CGRect, offset: CGSize, blur: CGFloat, color: NSColor) {
        // 透明圖層裡：整片不透明、再用 .clear 挖掉字形（非零規則，SF 可變字型的輪廓會互相重疊，不能用奇偶）；
        // 圖層帶著陰影合成，而圖層本體在 clip 外，字裡只看得到陰影。
        g.saveGState()
        g.addPath(path); g.clip()
        g.setShadow(offset: offset, blur: blur, color: color.cgColor)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        let big = b.insetBy(dx: -blur * 4 - 40, dy: -blur * 4 - 40)
        g.setFillColor(NSColor(white: color.whiteComponentSafe, alpha: 1).cgColor); g.fill(big)
        g.setBlendMode(.clear); g.addPath(path); g.fillPath()
        g.endTransparencyLayer()
        g.restoreGState()
    }

    /// 單色實心字（Typograph、床頭）：可帶極細的描邊與陰影
    func fillShape(_ g: CGContext, _ shape: GlyphShape, _ color: NSColor, shadow: CGFloat = 0) {
        g.saveGState()
        if shadow > 0 {
            g.setShadow(offset: CGSize(width: 0, height: -shape.ink.height * 0.01), blur: shape.ink.height * 0.04,
                        color: NSColor(white: 0, alpha: shadow).cgColor)
        }
        g.addPath(shape.path); g.setFillColor(color.cgColor); g.fillPath()
        g.restoreGState()
    }

    /// 玻璃裡透出來的背景：提高飽和與亮度（同一張圖只算一次）
    func vibrant(_ img: CGImage, saturation: CGFloat, brightness: CGFloat) -> CGImage {
        let key = "\(ObjectIdentifier(img).hashValue)|\(saturation)|\(brightness)"
        if let c = Self.vibrantCache, c.key == key { return c.image }
        let ci = CIImage(cgImage: img).applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: saturation, kCIInputBrightnessKey: brightness, kCIInputContrastKey: 1.0])
        let r = Face.ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: img.width, height: img.height)) ?? img
        Self.vibrantCache = (key, r)
        return r
    }
    nonisolated(unsafe) private static var vibrantCache: (key: String, image: CGImage)?

    /// 背景的模糊版（給玻璃折射用）：同一張背景只算一次
    func blurredBackdrop(_ img: CGImage, sigma: CGFloat, key: String) -> CGImage {
        if let c = Self.backdropCache, c.key == key { return c.image }
        let ci = CIImage(cgImage: img)
        let s = CGFloat(img.width) / 1024
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma * s).cropped(to: ci.extent)
        let r = Face.ciContext.createCGImage(out, from: ci.extent) ?? img
        Self.backdropCache = (key, r)
        return r
    }
    nonisolated(unsafe) private static var backdropCache: (key: String, image: CGImage)?
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 畫出目前畫布的一個區域成圖（給玻璃當背景）：把同一段繪製再跑一次到小圖上
    func snapshotBackdrop(px: Int = 512, _ draw: (CGContext) -> Void) -> CGImage {
        makeImage(px, px) { c in
            c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
            draw(c)
        }
    }
}

extension Face {
    /// 在畫布上畫一個 SF Symbol（單色），r 是左上原點的框；符號等比置中
    func drawSymbol(_ g: CGContext, _ name: String, in r: CGRect, color: NSColor, weight: NSFont.Weight = .semibold) {
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size, k = min(r.width / max(1, s.width), r.height / max(1, s.height))
        let dst = CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
        img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    /// 按詞折行（英文用空白，中文逐字），最多 maxLines 行，最後一行放不下就截「…」
    static func wrap(_ s: String, _ font: NSFont, _ width: CGFloat, maxLines: Int) -> [String] {
        func w(_ t: String) -> CGFloat { Typo.width(t, font) }
        if w(s) <= width { return [s] }
        let tokens: [String] = s.contains(" ") ? s.split(separator: " ").map(String.init) : s.map(String.init)
        let sep = s.contains(" ") ? " " : ""
        var lines: [String] = [], cur = ""
        for t in tokens {
            let next = cur.isEmpty ? t : cur + sep + t
            if w(next) <= width || cur.isEmpty { cur = next } else { lines.append(cur); cur = t }
        }
        if !cur.isEmpty { lines.append(cur) }
        if lines.count > maxLines {
            let rest = lines[(maxLines - 1)...].joined(separator: sep)
            lines = Array(lines[..<(maxLines - 1)]) + [clipped(rest, font, width)]
        }
        return lines
    }
    /// 一行字太長就截成「…」
    static func clipped(_ s: String, _ font: NSFont, _ width: CGFloat) -> String {
        func w(_ t: String) -> CGFloat { Typo.width(t, font) }
        if w(s) <= width { return s }
        var t = s
        while !t.isEmpty && w(t + "…") > width { t.removeLast() }
        return t + "…"
    }

    /// 中間刪節號（HIG-LIST-23）：太長時保留頭尾、中間換「…」——單集名稱、電話號碼這種辨識重在頭尾的字用這個
    static func clippedMiddle(_ s: String, _ font: NSFont, _ width: CGFloat) -> String {
        func w(_ t: String) -> CGFloat { Typo.width(t, font) }
        if w(s) <= width { return s }
        let ellipsis = "…"
        // 二分搜最多保留幾個字（頭尾各半），頭 + 「…」+ 尾要塞得進 width
        var lo = 0, hi = max(0, s.count - 1)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let head = s.prefix(mid / 2), tail = s.suffix(mid - mid / 2)
            if w(head + ellipsis + tail) <= width { lo = mid } else { hi = mid - 1 }
        }
        guard lo > 0 else { return ellipsis }
        let head = s.prefix(lo / 2), tail = s.suffix(lo - lo / 2)
        return head + ellipsis + tail
    }
}
