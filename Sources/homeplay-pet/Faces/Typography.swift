// 錶面的字體排印：把 SF Pro 的可變軸用滿。
//
// 錶面畫在 1024 單位的畫布上，但在桌面上只有 130–900 pt 寬（螢幕佔視窗約 0.72）。系統字體預設照「名義字級」
// 選光學尺寸、CoreText 畫 CTLine 時也不套字體自己的 trak 字距，結果是：30 單位的小標（螢幕上只有 5 pt）拿到
// Display 字形、零字距，擠成一團。這裡改成照「螢幕上的實際字級」來排：
// - opsz：kCTFontOpticalSizeAttribute＝實際字級（SF Pro 軸範圍 17…96；直接設 opsz 變數會被字級蓋掉，要用這個屬性）
// - 字距：讀 SF Pro 的 trak 表（track 0，21 個字級：6 pt +82、17 pt −52、28 pt +28、80 pt 以上 0，單位 1/2048 em），
//   在實際字級插值，換回畫布單位當 kern
// - wght／wdth 連續值（Medium 510、Semibold 590、Bold 700、Heavy 860；Condensed 60、Compressed 47）
// - GRAD：深底上的白字、玻璃上的字會「發胖變細」（光暈），GRAD 讓筆畫變粗但字寬不變，版面不跑
// - 中文：照介面語言設 kCTLanguageAttribute，簡體介面拿 PingFang SC 字形、繁體拿 TC

import AppKit
import CoreText

enum Typo {
    /// 一個畫布單位在螢幕上是幾 pt（PetView.updateFaceScale 跟著視窗寬度更新；預設＝220 pt 寬的視窗）
    nonisolated(unsafe) static var pointsPerUnit: CGFloat = 220 * 0.72 / 1024 {
        didSet { if abs(pointsPerUnit - oldValue) > 0.0005 { FaceType.flush() } }
    }
    /// 畫布字級 → 螢幕上的實際字級（pt）
    static func apparent(_ size: CGFloat) -> CGFloat { size * pointsPerUnit }
    /// 光學尺寸：實際字級，夾在 SF Pro 的 17…96（量化到 0.5，免得快取爆掉）
    static func opsz(_ size: CGFloat) -> CGFloat { (max(17, min(96, apparent(size))) * 2).rounded() / 2 }

    // MARK: trak

    private static let trak: (sizes: [CGFloat], values: [CGFloat], upem: CGFloat) = {
        let f = NSFont.systemFont(ofSize: 20) as CTFont
        let upem = CGFloat(CTFontGetUnitsPerEm(f))
        guard let data = CTFontCopyTable(f, CTFontTableTag(0x7472616B), []) as Data?, data.count > 16 else { return ([], [], upem) }
        func u16(_ o: Int) -> Int { o + 1 < data.count ? Int(data[o]) << 8 | Int(data[o + 1]) : 0 }
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(o)))) }
        func fx(_ o: Int) -> CGFloat { CGFloat(Int32(bitPattern: UInt32(u16(o) << 16 | u16(o + 2)))) / 65536 }
        let horiz = u16(6)
        guard horiz > 0 else { return ([], [], upem) }
        let nTracks = u16(horiz), nSizes = u16(horiz + 2), sizeOff = u16(horiz + 4) << 16 | u16(horiz + 6)
        let sizes = (0..<nSizes).map { fx(sizeOff + $0 * 4) }
        for t in 0..<nTracks {
            let e = horiz + 8 + t * 8
            guard fx(e) == 0 else { continue }   // track 0＝一般字距
            let off = u16(e + 6)
            return (sizes, (0..<nSizes).map { CGFloat(i16(off + $0 * 2)) }, upem)
        }
        return ([], [], upem)
    }()

    /// SF Pro 在實際字級 pt 的字距（em）
    static func trackingEm(atPoints pt: CGFloat) -> CGFloat {
        let (s, v, upem) = trak
        guard let first = s.first, let last = s.last else { return 0 }
        if pt <= first { return v[0] / upem }
        if pt >= last { return v[v.count - 1] / upem }
        let i = s.firstIndex { $0 >= pt }!
        let t = (pt - s[i - 1]) / (s[i] - s[i - 1])
        return (v[i - 1] + (v[i] - v[i - 1]) * t) / upem
    }
    /// 畫布字級 size 該加的字距（畫布單位）
    static func tracking(_ size: CGFloat) -> CGFloat { size * trackingEm(atPoints: apparent(size)) }

    /// 這個字體要不要照實際字級套字距：系統 SF（含 Rounded、Compressed 等）與錶面數字字體
    static func isSystemSF(_ f: NSFont) -> Bool {
        let n = f.fontName
        return n.hasPrefix(".SF") || n.hasPrefix(".AppleSystemUIFont")
    }

    /// 介面語言（中文字形 SC／TC 跟著走）
    static var language: String {
        switch L10n.language { case .zhHans: return "zh-Hans"; case .zhHant: return "zh-Hant"; case .en: return "en" }
    }

    /// 一行字的排版寬度（含照實際字級的字距，扣掉最後一字後面那份）：置中、靠右對齊用
    static func width(_ s: String, _ font: NSFont, kern: CGFloat? = nil) -> CGFloat {
        let a = attributes(font, kern: kern)
        let w = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: a)), nil, nil, nil))
        return w - ((a[.kern] as? CGFloat) ?? 0)
    }

    /// 一行字的屬性：字體、顏色、字距（kern 為 nil＝照實際字級的 trak）、語言
    static func attributes(_ font: NSFont, color: NSColor? = nil, kern: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTLanguageAttributeName as String): language]
        if let color { a[.foregroundColor] = color }
        a[.kern] = kern ?? (isSystemSF(font) ? tracking(font.pointSize) : 0)
        return a
    }
}

extension FaceType {
    /// SF Pro，連續可變軸：wght 1…1000、wdth 30…150、GRAD 400…1000；opsz 自動照實際字級。
    /// design：.default／.rounded（Rounded 沒有 wdth、opsz 軸）。mono：等寬數字（時間跳動不晃）。
    static func sfv(_ size: CGFloat, wght: CGFloat, wdth: CGFloat = 100, grad: CGFloat = 400,
                    design: NSFontDescriptor.SystemDesign = .default, mono: Bool = true) -> NSFont {
        let op = Typo.opsz(size)
        let key = "sfv|\(size)|\(wght)|\(wdth)|\(grad)|\(design.rawValue)|\(mono)|\(op)|\(L10n.language.rawValue)"
        if let f = cached(key) { return f }
        let base = NSFont.systemFont(ofSize: size)
        var d = (design == .default ? base.fontDescriptor : (base.fontDescriptor.withDesign(design) ?? base.fontDescriptor)) as CTFontDescriptor
        // 先給屬性（光學尺寸、等寬數字、中文退回字體），最後才套可變軸：CopyWithAttributes 會把已設的可變值清掉
        var attrs: [CFString: Any] = [kCTFontCascadeListAttribute: [pingFang(wght)]]
        if design == .default { attrs[kCTFontOpticalSizeAttribute] = NSNumber(value: Double(op)) }
        if mono {
            attrs[kCTFontFeatureSettingsAttribute] = [[kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                                                       kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]]
        }
        d = CTFontDescriptorCreateCopyWithAttributes(d, attrs as CFDictionary)
        func axis(_ tag: String, _ v: CGFloat) {
            let t = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            d = CTFontDescriptorCreateCopyWithVariation(d, NSNumber(value: t), v)
        }
        axis("wght", wght)
        if design == .default { axis("wdth", wdth); axis("opsz", op) }
        if grad != 400 { axis("GRAD", grad) }
        let f = CTFontCreateWithFontDescriptor(d, size, nil) as NSFont
        store(key, f)
        return f
    }

    /// 中文退回字體：CoreText 挑退回字體時看的是粗細特徵、不看 wght 可變值，所以直接指定同粗細的蘋方；
    /// 簡體介面用 SC 字形、其餘用 TC（台灣字形）
    static func pingFang(_ wght: CGFloat) -> CTFontDescriptor {
        let w = wght <= 150 ? "Ultralight" : wght <= 250 ? "Thin" : wght <= 350 ? "Light" : wght <= 470 ? "Regular" : wght <= 550 ? "Medium" : "Semibold"
        let region = L10n.language == .zhHans ? "SC" : "TC"
        return CTFontDescriptorCreateWithNameAndSize("PingFang\(region)-\(w)" as CFString, 0)
    }

    /// NSFont.Weight → SF Pro 的 wght 值（系統實際用的數字）
    static func wght(_ w: NSFont.Weight) -> CGFloat {
        let table: [(NSFont.Weight, CGFloat)] = [(.ultraLight, 31), (.thin, 111), (.light, 274), (.regular, 400), (.medium, 510),
                                                (.semibold, 590), (.bold, 700), (.heavy, 860), (.black, 1000)]
        if let hit = table.first(where: { $0.0 == w }) { return hit.1 }
        // 中間值（例如 lerp 出來的）：照 rawValue 線性插
        let r = w.rawValue
        for i in 1..<table.count where r <= table[i].0.rawValue {
            let a = table[i - 1], b = table[i], t = (r - a.0.rawValue) / (b.0.rawValue - a.0.rawValue)
            return a.1 + (b.1 - a.1) * t
        }
        return 1000
    }
    /// NSFont.Width → wdth
    static func wdth(_ w: NSFont.Width) -> CGFloat {
        switch w { case .compressed: return 47; case .condensed: return 60; case .expanded: return 132; default: return 100 }
    }
    /// 同一個字體換 GRAD（深底白字補償光暈）；非系統 SF 原樣回傳
    static func graded(_ f: NSFont, _ grad: CGFloat) -> NSFont {
        guard grad != 400, Typo.isSystemSF(f) else { return f }
        let key = "grad|\(f.fontName)|\(f.pointSize)|\(grad)|\((CTFontCopyVariation(f as CTFont) as? [NSNumber: NSNumber])?.description ?? "")"
        if let c = cached(key) { return c }
        let d = CTFontDescriptorCreateCopyWithVariation(CTFontCopyFontDescriptor(f as CTFont), NSNumber(value: 0x47524144), grad)
        let out = CTFontCreateWithFontDescriptor(d, f.pointSize, nil) as NSFont
        store(key, out)
        return out
    }
}

extension NSColor {
    /// 亮字（深底白字、玻璃上的字）：要用 GRAD 補一點筆畫
    var isLightInk: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.72
    }
}
