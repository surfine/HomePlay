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
