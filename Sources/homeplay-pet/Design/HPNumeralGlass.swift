// 體驗追趕 P1：錶面玻璃大數字的規則（島錶面、照片錶面共用 Face.drawClockDigits）。
//
// - 走玻璃：ClockLook.glass 開著、而且沒有開「減少透明度」「減少動態效果」（折射跟著背景與眼神動，兩者都退回實色）。
// - 材質版 Look（莫蘭迪色底＋黑數字那八種）選了並聯動時，數字保持實色（色票照 2026-11-05 拍板走白）；只有彩色數字版四種走玻璃。
// - 字色隨背景亮度微調：背景亮度只取一次（模糊背景縮成 1×1，ClockLook.wallpaperTone 已快取），
//   亮背景上玻璃染得濃一點、顏色壓深一點，暗背景上淡一點、提亮一點，彩色數字在兩種背景上都看得出是那個顏色。

import AppKit

enum HPNumeralGlass {
    /// 彩色數字版 Look 的四個色票
    static let coloredSwatches: Set<ClockLook.Swatch> = [.blueOrange, .neonBlue, .orangePurple, .redBlue]

    /// 這組設定的大數字畫不畫玻璃（純函式）
    static func usesGlass(look: ClockLook, materialLookLinked: Bool, reduceTransparency: Bool, reduceMotion: Bool) -> Bool {
        guard look.glass, !reduceTransparency, !reduceMotion else { return false }
        return !(materialLookLinked && look.swatch == .white)
    }

    /// 現在選的 Look 是不是材質版、而且使用者選過（沒選＝預設，不算）
    static var materialLookLinked: Bool {
        HPLook.wasSelected && HPLook.swatchForLook(HPLook.current) == .white
    }

    static var current: (reduceTransparency: Bool, reduceMotion: Bool) { (HPGlass.reduceTransparency, HPMotion.reduceMotion) }

    /// 染色：base＝原本的染色量（ClockLook.glassTint）；luma＝背景亮度 0…1（sRGB）。只動彩色數字版
    static func tint(_ color: NSColor, base: CGFloat, luma: CGFloat, swatch: ClockLook.Swatch) -> NSColor? {
        guard base > 0 else { return nil }
        guard coloredSwatches.contains(swatch), let c = color.usingColorSpace(.sRGB) else { return color.withAlphaComponent(base) }
        let l = max(0, min(1, luma))
        let M = HPMaterial.Numerals.self                                    // 數值在材質表
        let alpha = min(M.maxAlpha, base * (M.scaleAtBlack + M.scaleSlope * l))   // 亮背景染濃（0.8×…1.3×）
        let shift = M.lighten - M.span * l                                  // 暗背景提亮 8%、亮背景壓深 12%
        func ch(_ v: CGFloat) -> CGFloat { shift >= 0 ? v + (1 - v) * shift : v * (1 + shift) }
        return NSColor(srgbRed: ch(c.redComponent), green: ch(c.greenComponent), blue: ch(c.blueComponent), alpha: alpha)
    }

    static func luma(_ c: NSColor?) -> CGFloat {
        guard let s = c?.usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
    }
}

enum HPNumeralGlassSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        var colored = ClockLook(); colored.swatch = .blueOrange
        var white = ClockLook(); white.swatch = .white
        check(HPNumeralGlass.usesGlass(look: colored, materialLookLinked: false, reduceTransparency: false, reduceMotion: false)
              && !HPNumeralGlass.usesGlass(look: colored, materialLookLinked: false, reduceTransparency: true, reduceMotion: false)
              && !HPNumeralGlass.usesGlass(look: colored, materialLookLinked: false, reduceTransparency: false, reduceMotion: true),
              "玻璃大數字：減少透明度／減少動態效果退回實色")   // l10n-ignore
        check(!HPNumeralGlass.usesGlass(look: white, materialLookLinked: true, reduceTransparency: false, reduceMotion: false)
              && HPNumeralGlass.usesGlass(look: white, materialLookLinked: false, reduceTransparency: false, reduceMotion: false)
              && HPNumeralGlass.usesGlass(look: colored, materialLookLinked: true, reduceTransparency: false, reduceMotion: false),
              "玻璃大數字：材質版 Look 聯動時實色、彩色數字版走玻璃")   // l10n-ignore
        let n = srgb(0x94CFFF)
        let dark = HPNumeralGlass.tint(n, base: 0.27, luma: 0.1, swatch: .blueOrange)!, bright = HPNumeralGlass.tint(n, base: 0.27, luma: 0.9, swatch: .blueOrange)!
        check(bright.alphaComponent > dark.alphaComponent && HPAccessibility.luminance(bright.withAlphaComponent(1)) < HPAccessibility.luminance(dark.withAlphaComponent(1)),
              "玻璃大數字：亮背景染濃壓深、暗背景淡而提亮")   // l10n-ignore
        check(HPNumeralGlass.tint(n, base: 0, luma: 0.5, swatch: .blueOrange) == nil
              && HPNumeralGlass.tint(n, base: 0.2, luma: 0.9, swatch: .blue)?.alphaComponent == 0.2,
              "玻璃大數字：不染色維持 nil、非 Look 色票不調")   // l10n-ignore
    }
}
