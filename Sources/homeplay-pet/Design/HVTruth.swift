// HomeView 對齊的真值層：主題外觀（Look）、狀態色與家庭警報類別的實測值都集中在這裡。
// 對齊工作請引用 HVTruth，不要在 App 裡重抄數字；與私有參考資料的一致性由 tooling 的私有檢查負責。
import AppKit

enum HVTruth {
    // MARK: - Look（時鐘海報主題；四層語義 token）
    struct Look: Equatable {
        let name: String
        let background: UInt32
        let numerals: UInt32
        let secondary: UInt32
        let accent: UInt32

        var background_color: NSColor { srgb(background) }
        var numerals_color: NSColor { srgb(numerals) }
        var secondary_color: NSColor { srgb(secondary) }
        var accent_color: NSColor { srgb(accent) }
    }

    /// 12 種 Look，兩種構成：彩色數字版（#EBEBEB 淺底＋雙彩）與材質底版（莫蘭迪色底＋黑數字）。
    static let looks: [Look] = [
        Look(name: "Blue-Orange",   background: 0xEBEBEB, numerals: 0x94CFFF, secondary: 0xFF6600, accent: 0xFFFFFF),
        Look(name: "Neon-Blue",     background: 0xEBEBEB, numerals: 0x8CD443, secondary: 0x00C4FF, accent: 0xFFFFFF),
        Look(name: "Orange-Purple", background: 0xEBEBEB, numerals: 0xFFBA3A, secondary: 0xFF3DF7, accent: 0xFFFFFF),
        Look(name: "Red-Blue",      background: 0xEBEBEB, numerals: 0xFF5252, secondary: 0x006FFF, accent: 0xFFFFFF),
        Look(name: "Mauve",         background: 0xAC9B9F, numerals: 0x000000, secondary: 0xFEFFFF, accent: 0xFFFFFF),
        Look(name: "Mocha",         background: 0xABA398, numerals: 0x000000, secondary: 0xFEFFFF, accent: 0xFFFFFF),
        Look(name: "Rose",          background: 0xCFB2AF, numerals: 0x000000, secondary: 0xFEFFFF, accent: 0xFFFFFF),
        Look(name: "Sage",          background: 0xA4B89D, numerals: 0x000000, secondary: 0xFEFFFF, accent: 0xFFFFFF),
        Look(name: "Silver",        background: 0xB4B6BB, numerals: 0x000000, secondary: 0xFEFFFF, accent: 0xFFFFFF),
        Look(name: "Slate",         background: 0x92ABB1, numerals: 0x000000, secondary: 0xFEFFFF, accent: 0xFFFFFF),
        Look(name: "SpaceGray",     background: 0x7E7C85, numerals: 0x000000, secondary: 0xFEFFFF, accent: 0xFFFFFF),
        Look(name: "Starlight",     background: 0xCFC3B7, numerals: 0x000000, secondary: 0xFEFFFF, accent: 0xFFFFFF),
    ]

    static func look(_ name: String) -> Look? { looks.first { $0.name == name } }

    /// Alarms Widget 強調（暖金）
    static let alarmWidgetAccent: UInt32 = 0xE6A651

    // MARK: - 狀態色
    enum Timers {
        /// 響鈴中的底：暖棕（不打斷環境的家庭暖色警示，非 iOS 紅）
        static let firingBackground: UInt32 = 0x5B3B0F
        /// 響鈴覆蓋層
        static let firingOverlay: UInt32 = 0xCCCCCC
    }
    enum Alarms {
        /// Widget 背景（深）
        static let widgetBackground: UInt32 = 0x1C1C1E
    }
    enum Intercom {
        /// 對講進行中的底：琥珀
        static let activeBackground: UInt32 = 0xFFA800
    }

    // MARK: - 圖示玻璃（體驗追趕 P0）
    enum IconGlass {
        /// 🟢 圖示底走系統玻璃、分淺深兩種樣式、相鄰的可成組融合（行為存在，位元組實測）
        /// 🟡 融合門檻：外框距離 < 24 畫布單位（推斷；跟 HPGlass 融合提示同值，主畫面網格間距 73 不會融）
        static let groupingGap: CGFloat = 24
    }

    // MARK: - 數字系統（錶面體系 numerals）
    enum Numerals {
        /// 🟢 官方海報配置的出廠值（docs/hv-reference/poster_descriptors.json：Calendar 四個預設 posterData.numerals）
        static let factory = "arabic"
        /// 🟢 本機實測（macOS 27 /System/Library/Fonts/ADTNumeric.ttc，CTFontGetGlyphsForCharacters 十個數字齊全）：
        /// 系統錶面數字字體收的數字系統（ICU 代號）；泰文 thai 沒收。SF Pro 系統字體一套都沒有。
        /// 🟡 HomeView 支援的數字系統＝這些（同一套字體；固件 posterData 只看得到 arabic）
        static let fontCoverage = ["latn", "arab", "arabext", "deva", "beng", "mymr", "khmr"]
    }

    // MARK: - 官方水滴的分層透明度（ClioTalk 水滴；Faces/Capsule.swift 的 LiquidOrb）
    /// 出處：docs/hv-reference/siri_orb.txt「一、圖標圖層結構」各層的「透明度」欄（深/淺兩個變體）。
    /// 深淺不重繪形狀，只把這幾層的透明度互換。
    enum OrbLayers {
        /// 🟢 組「fill _ shadows」層 1 光暈：1 / 0
        static let halo: (dark: CGFloat, light: CGFloat) = (1, 0)
        /// 🟢 組「fill _ shadows」層 3 投影：0 / 0.225
        static let shadow: (dark: CGFloat, light: CGFloat) = (0, 0.225)
        /// 🟢 組「fill _ shadows」暗部：深色版層 2 的 0.8、淺色版層 4 的 0.95（兩層各在一種外觀出現，合成一個暗部值）
        static let shade: (dark: CGFloat, light: CGFloat) = (0.8, 0.95)
        /// 🟢 組「siri light _ caustic」焦散：深色版層 0 的 0.65、淺色版層 2 的 0.1
        static let caustic: (dark: CGFloat, light: CGFloat) = (0.65, 0.1)
        /// 🟢 同組波紋：深色版層 1、淺色版層 3 都是 1（加法混合）
        static let wave: CGFloat = 1
        /// 🟡 第二層波：圖層表兩個變體都是 0（運行時才打開）；相位錯開 0.5π、透明度 0.5 是推斷（同檔「三、配方」）
        static let secondWave: CGFloat = 0.5
        static let secondWavePhase: Double = .pi / 2
    }

    /// 家庭警報類別：煙霧／一氧化碳／二氧化碳／水漏／門窗安全
    static let alertKinds: [String] = ["smoke", "carbonMonoxide", "carbonDioxide", "leak", "security"]
}

// MARK: - 自檢

enum HVTruthSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(HVTruth.looks.count == 12, "真值：12 種 Look 齊全")   // l10n-ignore
        check(Set(HVTruth.looks.map(\.name)).count == 12, "真值：Look 名不重複")   // l10n-ignore
        check(HVTruth.Timers.firingBackground == 0x5B3B0F && HVTruth.Intercom.activeBackground == 0xFFA800
              && HVTruth.Alarms.widgetBackground == 0x1C1C1E, "真值：響鈴暖棕/對講琥珀/鬧鐘 Widget 深底")   // l10n-ignore
        check(HVTruth.look("Blue-Orange")?.numerals == 0x94CFFF && HVTruth.look("Slate")?.background == 0x92ABB1, "真值：Look 色值抽查")   // l10n-ignore
    }
}
