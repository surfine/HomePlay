// 體驗追趕 P3：材質 token 表——主畫面、圖示玻璃、玻璃大數字、控制中心的材質參數都從這一張拿（以前各寫各的）。
//
// 每一項標出處：🟢 量到的、🟡 推斷、⚪ 未知（照官方幀或校準台量的值不改，只是搬到同一處）。
// Luma 自適應：控制中心打開那一幀把底下畫面的平均亮度取一次（`sampleLuma`），platter 與模組加厚層照它微調深淺，
// 之後每幀都用同一個值，不重取、不閃。

import AppKit

enum HPMaterial {
    // MARK: 主畫面（HPTokens.Home 的桌布與面板值轉寄到這裡，官方幀校準過，不動）
    enum Home {
        static var wallpaperBlur: CGFloat { HPTokens.Home.wallpaperBlur }        // 🟢 官方幀
        static var wallpaperDim: CGFloat { HPTokens.Home.wallpaperDim }          // 🟢
        static var wallpaperMaxLum: CGFloat { HPTokens.Home.wallpaperMaxLum }    // 🟢
        static var panelShade: CGFloat { HPTokens.Home.panelShade }              // 🟢
    }

    // MARK: 圖示玻璃（P0）：玻璃面上再蓋的一層＋主體不透明度 🟡
    enum IconGlass {
        static let light = HPIconGlass.Params(baseGray: 1, baseAlpha: 0.10, glyphAlpha: 0.94)
        static let dark = HPIconGlass.Params(baseGray: 0, baseAlpha: 0.18, glyphAlpha: 0.94)
        static let lightIncreaseContrast = HPIconGlass.Params(baseGray: 0, baseAlpha: 0.12, glyphAlpha: 1)
        static let darkIncreaseContrast = HPIconGlass.Params(baseGray: 0, baseAlpha: 0.34, glyphAlpha: 1)
    }
    static func iconGlass(dark: Bool, increaseContrast: Bool) -> HPIconGlass.Params {
        HPIconGlass.params(HPIconGlass.style(dark: dark), increaseContrast: increaseContrast)
    }

    // MARK: 玻璃大數字（P1）：彩色數字版 Look 的染色隨背景亮度 🟡
    enum Numerals {
        /// 染色量 ＝ base × (scaleAtBlack + scaleSlope × luma)，上限 maxAlpha
        static let scaleAtBlack: CGFloat = 0.8
        static let scaleSlope: CGFloat = 0.5
        static let maxAlpha: CGFloat = 0.6
        /// 顏色：暗底提亮 lighten、往亮底線性變到壓深（lighten − span）
        static let lighten: CGFloat = 0.08
        static let span: CGFloat = 0.20
    }

    // MARK: 控制中心
    enum CC {
        /// 打開時霧化底下畫面的 σ（畫布單位）🟡
        static let backdropBlur: CGFloat = 30
        /// platter：深色壓黑、淺色洗白（中間亮度的基準值，iOS 量的）🟡
        static let platterDark: CGFloat = 0.38
        static let platterLight: CGFloat = 0.28
        /// 模組玻璃的加厚層：淺白、深黑 🟡
        static let thickenLight: CGFloat = 0.08
        static let thickenDark: CGFloat = 0.10
        /// luma 自適應的幅度（只加不減）：底下越亮，深色 platter 壓得越多；底下越暗，淺色 platter 洗得越多 🟡
        static let lumaSwing: CGFloat = 0.12
        /// 基準亮度（這個亮度時就是上面的基準值）
        static let lumaPivot: CGFloat = 0.35
    }

    /// platter 的顏色（純函式）：dark＝深色外觀；luma＝打開那一刻底下的平均亮度（nil＝不知道，用基準值）
    static func ccPlatter(dark: Bool, luma: CGFloat?) -> NSColor {
        let d = (luma ?? CC.lumaPivot) - CC.lumaPivot
        // 只往濃加、不比基準薄：底下越花越亮，模組越需要跟背景分開（調薄會讓照片的明暗透進玻璃、折射帶變明顯）
        if dark { return NSColor.black.withAlphaComponent(min(CC.platterDark + CC.lumaSwing, CC.platterDark + CC.lumaSwing * max(0, d) / (1 - CC.lumaPivot))) }
        return NSColor.white.withAlphaComponent(min(CC.platterLight + CC.lumaSwing, CC.platterLight + CC.lumaSwing * max(0, -d) / CC.lumaPivot))
    }

    /// 模組加厚層的不透明度（純函式）：深色玻璃在亮底上加厚一點，淺色玻璃在暗底上加厚一點
    static func ccThicken(darkGlass: Bool, luma: CGFloat?) -> CGFloat {
        let d = (luma ?? CC.lumaPivot) - CC.lumaPivot
        return darkGlass ? clamp(CC.thickenDark + 0.06 * max(0, d), 0.06, 0.16) : clamp(CC.thickenLight + 0.06 * max(0, -d), 0.04, 0.14)
    }

    /// 這一幀控制中心用的 luma（打開那一刻取一次）
    nonisolated(unsafe) static var ccLuma: CGFloat?

    /// 一張圖的平均亮度（縮成 1×1，sRGB Rec.709）
    static func sampleLuma(_ img: CGImage) -> CGFloat? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * CGFloat(px[0]) + 0.7152 * CGFloat(px[1]) + 0.0722 * CGFloat(px[2])) / 255
    }

    @inline(__always) static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }
}

enum HPMaterialSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let pd = HPMaterial.ccPlatter(dark: true, luma: nil), pl = HPMaterial.ccPlatter(dark: false, luma: nil)
        check(abs(pd.alphaComponent - HPMaterial.CC.platterDark) < 1e-6 && abs(pl.alphaComponent - HPMaterial.CC.platterLight) < 1e-6,
              "材質表：不知道亮度時 platter 是基準值")   // l10n-ignore
        let lums: [CGFloat] = stride(from: 0, through: 1, by: 0.1).map { CGFloat($0) }
        let dk = lums.map { HPMaterial.ccPlatter(dark: true, luma: $0).alphaComponent }, lt = lums.map { HPMaterial.ccPlatter(dark: false, luma: $0).alphaComponent }
        let C = HPMaterial.CC.self
        check(zip(dk, dk.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && zip(lt, lt.dropFirst()).allSatisfy { $0 + 1e-9 >= $1 }
              && dk.allSatisfy { $0 >= C.platterDark - 1e-9 && $0 <= C.platterDark + C.lumaSwing + 1e-9 }
              && lt.allSatisfy { $0 >= C.platterLight - 1e-9 && $0 <= C.platterLight + C.lumaSwing + 1e-9 }
              && dk.last! > dk.first! && lt.first! > lt.last!,
              "材質表：底越亮深色 platter 越濃、底越暗淺色 platter 越濃，只加不減、有上限")   // l10n-ignore
        check(HPMaterial.ccThicken(darkGlass: true, luma: 0.9) > HPMaterial.ccThicken(darkGlass: true, luma: 0.1)
              && HPMaterial.ccThicken(darkGlass: false, luma: 0.1) > HPMaterial.ccThicken(darkGlass: false, luma: 0.9),
              "材質表：模組加厚層照底下亮度調")   // l10n-ignore
        let black = makeImage(8, 8) { $0.setFillColor(NSColor.black.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let white = makeImage(8, 8) { $0.setFillColor(NSColor.white.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        check((HPMaterial.sampleLuma(black) ?? 1) < 0.02 && (HPMaterial.sampleLuma(white) ?? 0) > 0.98, "材質表：亮度取樣黑 0、白 1")   // l10n-ignore
        check(HPMaterial.iconGlass(dark: true, increaseContrast: false) == HPIconGlass.params(.dark, increaseContrast: false),
              "材質表：圖示玻璃參數從同一張表拿")   // l10n-ignore
    }
}
