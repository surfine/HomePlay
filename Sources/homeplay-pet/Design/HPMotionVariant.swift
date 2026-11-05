// 動效變體解析層（HomeView 對齊後續 #5，拍板 2026-11-05）：官方 Timers 的播放／暫停動畫預渲染了六份動畫資產
// （PlayPause_{mintLight, mintDark, orangeLight, orangeDark, black, increasedContrast}.ca），
// Alarms 的響鈴也有 orange／white 兩份——動效資產跟著「主題色 × 深淺 × 增加對比」成套換。
// 我們是程式化繪製，不做資產包；等價物是這一層純函式：同一個主題色（淺色版的正典值）在不同外觀／無障礙狀態下
// 解出動畫該用的顏色、時長、晃動幅度。呼叫端畫按鈕／響鈴脈動時只問這裡，不各自判斷。
//
// 規則（HSB 空間，數字對齊 HIG 系統色表：淺→深、淺→增加對比的實際落差）：
// - 深色：亮度 +0.04、飽和 ×0.97（systemOrange #FF8D28 → ≈ #FF9230）；
// - 增加對比：淺底更深更飽和（亮度 ×0.78、飽和 ×1.15，≈ #C55300）；深底更亮（亮度 +0.1、飽和 ×0.8，≈ #FFA056）；
// - black（夜間紅）：單色白，交給 Shell.nightTint 的亮度→紅映射；
// - 增加對比時動畫收得更快、晃得更少（時長 ×0.7、幅度 ×0.5）——少一點動、多一點清楚。
import AppKit

enum HPMotionVariant {
    /// 一組外觀狀態＝官方六份資產之一
    struct Variant: Equatable {
        var dark: Bool
        var increaseContrast: Bool
        var black: Bool

        /// 官方資產的名字（自檢用來對上六選一）：增加對比與 black 不分主題
        func assetName(theme: String) -> String {
            if increaseContrast { return "increasedContrast" }
            if black { return "black" }
            return theme + (dark ? "Dark" : "Light")
        }
        /// 底永遠是深色的畫面（計時器錶盤、響鈴畫面）：深淺固定走深色，增加對比照舊
        func onDarkSurface() -> Variant { Variant(dark: true, increaseContrast: increaseContrast, black: black) }
    }

    /// 現在的外觀：HPTokens.dark × HPAccessibility.increaseContrast（black 由呼叫端依夜間紅決定）
    static func current(black: Bool = false) -> Variant {
        Variant(dark: HPTokens.dark, increaseContrast: HPAccessibility.increaseContrast, black: black)
    }

    /// 動畫用色：base＝主題色的淺色正典值（例如 Timers AccentColor #FF8D28、活動 Look 的 accent）
    static func tint(_ base: NSColor, _ v: Variant) -> NSColor {
        if v.black { return .white }
        guard let c = base.usingColorSpace(.sRGB) else { return base }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        switch (v.increaseContrast, v.dark) {
        case (true, false): s = min(1, s * 1.15); b *= 0.78
        case (true, true): s *= 0.8; b = min(1, b + 0.1)
        case (false, true): s *= 0.97; b = min(1, b + 0.04)
        case (false, false): break
        }
        return NSColor(hue: h, saturation: s, brightness: b, alpha: a).usingColorSpace(.sRGB) ?? base
    }

    /// 動畫時長縮放（週期、彈簧 response 乘上它）：增加對比時收尾更快
    static func durationScale(_ v: Variant) -> Double { v.increaseContrast ? 0.7 : 1 }
    /// 晃動／擴散幅度縮放：增加對比時減半（少晃）
    static func amplitude(_ v: Variant) -> CGFloat { v.increaseContrast ? 0.5 : 1 }

    /// 主題色的淺色正典值（官方 AccentColor 實測；HPTokens 的系統色是已解析過外觀的值，這裡要未解析的）
    enum Base {
        static let orange = srgb(0xFF8D28)   // Timers／Alarms AccentColor＝systemOrange
        static let green = srgb(0x34C759)    // 計時器暫停時「繼續」的綠
        static let mint = srgb(0x00C8B3)     // 官方 PlayPause_mint*
    }
}

// MARK: - 自檢

enum HPMotionVariantSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias V = HPMotionVariant.Variant
        let light = V(dark: false, increaseContrast: false, black: false), dark = V(dark: true, increaseContrast: false, black: false)
        let icL = V(dark: false, increaseContrast: true, black: false), icD = V(dark: true, increaseContrast: true, black: false)
        let base = HPMotionVariant.Base.orange
        func dist(_ a: NSColor, _ b: NSColor) -> CGFloat {
            guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return 1 }
            return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        }
        let tL = HPMotionVariant.tint(base, light), tD = HPMotionVariant.tint(base, dark)
        let tIL = HPMotionVariant.tint(base, icL), tID = HPMotionVariant.tint(base, icD)
        check(dist(tL, base) < 1e-3 && dist(tD, tL) > 0.01 && dist(tIL, tL) > 0.05 && dist(tID, tD) > 0.05,
              "動效變體：同一主題色在深色／增加對比下解出不同值")   // l10n-ignore
        check(dist(tD, srgb(0xFF9230)) < 10.0 / 255, "動效變體：橘的深色版≈ systemOrange 深色 #FF9230")   // l10n-ignore
        check(dist(tIL, srgb(0xC55300)) < 16.0 / 255 && dist(tID, srgb(0xFFA056)) < 16.0 / 255,
              "動效變體：橘的增加對比版≈ HIG 高對比表（#C55300／#FFA056）")   // l10n-ignore
        check(HPAccessibility.luminance(tIL) < HPAccessibility.luminance(tL) && HPAccessibility.luminance(tID) > HPAccessibility.luminance(tD),
              "動效變體：增加對比＝離底色更遠（淺底更深、深底更亮）")   // l10n-ignore
        check(HPMotionVariant.durationScale(icL) <= HPMotionVariant.durationScale(light) && HPMotionVariant.durationScale(light) == 1
              && HPMotionVariant.amplitude(icD) < HPMotionVariant.amplitude(dark), "動效變體：增加對比時長 ≤ 常規、晃得更少")   // l10n-ignore
        // 六份官方資產的等價：主題 × 深淺 ＋ black ＋ increasedContrast
        let names = Set([light, dark].flatMap { v in ["mint", "orange"].map { v.assetName(theme: $0) } }
                        + [V(dark: false, increaseContrast: false, black: true).assetName(theme: "orange"), icD.assetName(theme: "mint")])
        check(names == ["mintLight", "mintDark", "orangeLight", "orangeDark", "black", "increasedContrast"], "動效變體：對上官方六份 PlayPause 資產")   // l10n-ignore
        check(HPMotionVariant.tint(base, V(dark: true, increaseContrast: false, black: true)) == .white && light.onDarkSurface().dark,
              "動效變體：black＝單色白；深底畫面固定走深色")   // l10n-ignore
    }
}
