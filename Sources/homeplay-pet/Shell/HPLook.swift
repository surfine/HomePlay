// Look 體系（HomeView 對齊 WP2）：統一的主題外觀登記處。
// HomeView 的時鐘海報有 12 種 Look（background／numerals／secondary／accent 四層 token，
// 實測值在 Design/HVTruth.swift）。這裡把它們變成整個外殼共用的選擇狀態：
// ClockLook 的大數字色票、HomeAppearance 的著色建議都從這一份推導，不再各抄一套。
import AppKit

enum HPLook {
    static let defaultsKey = "HomePlayLook"

    /// 現在選的 Look（預設 Blue-Orange；快照可用 --look Mocha 指定，不寫偏好）
    nonisolated(unsafe) private static var storedName: String =
        UserDefaults.standard.string(forKey: defaultsKey) ?? HVTruth.looks[0].name
    nonisolated(unsafe) static var snapshotName: String?

    static var name: String { snapshotName ?? storedName }
    static var current: HVTruth.Look { HVTruth.look(name) ?? HVTruth.looks[0] }
    /// 使用者有沒有明確選過 Look（沒選＝預設 Blue-Orange，不驅動著色建議）
    static var wasSelected: Bool { snapshotName != nil || UserDefaults.standard.string(forKey: defaultsKey) != nil }

    static func select(_ n: String, linkDigits: Bool = true) {
        guard let l = HVTruth.look(n) else { return }
        storedName = n
        UserDefaults.standard.set(n, forKey: defaultsKey)
        // 拍板（2026-11-05）：Look 聯動大數字——彩色數字版換對應官方色票；材質版 Look 的數字是黑（淺底），
        // 深色桌布上以白色系處理。selftest 用 linkDigits:false 免得覆寫使用者的 ClockLook。
        if linkDigits { ClockLook.current.swatch = swatchForLook(l) }
    }

    /// Look → 大數字色票：彩色數字版四選一有實測映射；材質版統一走白（黑數字在我們的深色壁紙上不可用）
    static func swatchForLook(_ l: HVTruth.Look) -> ClockLook.Swatch {
        switch l.name {
        case "Blue-Orange": return .blueOrange
        case "Neon-Blue": return .neonBlue
        case "Orange-Purple": return .orangePurple
        case "Red-Blue": return .redBlue
        default: return .white
        }
    }

    /// 大數字色（ClockLook 用）：官方彩色數字版 Look 直接給 numerals 實測色
    static var numeralsColor: NSColor { current.numerals_color }

    /// 著色外觀（HomeAppearance tinted）的建議色：Look 的 secondary（官方四層 token 中的強調層）
    static var suggestedTint: NSColor { current.secondary_color }

    static func parseSnapshotArgs() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--look"), i + 1 < a.count { snapshotName = a[i + 1] }
    }
}

enum HPLookSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(HPLook.current.name == HVTruth.looks[0].name || HVTruth.looks.contains { $0.name == HPLook.current.name },
              "Look：現在的 Look 在官方 12 種裡（預設 Blue-Orange）")   // l10n-ignore
        let before = HPLook.name, savedLook = ClockLook.current
        HPLook.select("Slate", linkDigits: false)
        check(HPLook.current.background_color == HVTruth.look("Slate")?.background_color && HPLook.current.numerals_color == srgb(0x000000),
              "Look：選 Slate 拿得到實測四層 token（黑數字）")   // l10n-ignore
        HPLook.select("Blue-Orange")
        check(HPLook.current.numerals_color == srgb(0x94CFFF), "Look：Blue-Orange 數字＝#94CFFF")   // l10n-ignore
        check(HPLook.suggestedTint == srgb(0xFF6600), "Look：Blue-Orange 著色建議＝#FF6600")   // l10n-ignore
        HPLook.select("不存在的名字", linkDigits: false)   // l10n-ignore：不合法名稱要被忽略
        check(HPLook.name == "Blue-Orange", "Look：不認得的名字不會被選")   // l10n-ignore
        // 拍板（2026-11-05）：Look 聯動大數字的映射（彩色版→官方色票；材質版→白）
        check(HPLook.swatchForLook(HVTruth.looks[0]) == .blueOrange && HPLook.swatchForLook(HVTruth.look("Slate")!) == .white
              && HPLook.swatchForLook(HVTruth.look("Red-Blue")!) == .redBlue, "Look：選 Look 聯動大數字色票")   // l10n-ignore
        HPLook.select(before, linkDigits: false); HPLook.snapshotName = nil
        ClockLook.current = savedLook
    }
}
