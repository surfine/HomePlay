// Look 體系（HomeView 對齊 WP2）：統一的主題外觀登記處。
// HomeView 的時鐘海報有 12 種 Look（background／numerals／secondary／accent 四層 token，
// 實測值在 Design/HVTruth.swift）。這裡把它們變成整個外殼共用的選擇狀態：
// ClockLook 的大數字色票、HomeAppearance 的著色建議都從這一份推導，不再各抄一套。
// 錶面體系：Look 名存在海報配置裡（Shell/PosterConfiguration.swift）；defaultsKey 是舊鍵，只剩遷移與「用過的痕跡」在讀。
import AppKit

enum HPLook {
    static let defaultsKey = "HomePlayLook"

    /// 現在選的 Look（預設 Blue-Orange；快照可用 --look Mocha 或 --poster look=Mocha 指定，不寫偏好）
    private static var storedName: String { PosterConfiguration.current.look }
    nonisolated(unsafe) static var snapshotName: String?

    /// 2.0 家人檔案：目前是家人且選過 Look 就用他的，否則主人的（People/FamilyProfiles.swift）
    static var name: String {
        snapshotName ?? PosterConfiguration.snapshotOverride?.look ?? FamilyProfiles.resolvedLook(member: FamilyProfiles.memberPrefs, global: storedName)
    }
    static var current: HVTruth.Look { HVTruth.look(name) ?? HVTruth.looks[0] }

    /// 舊偏好遷移會把出廠預設也標成 lookChosen（PosterConfiguration.migrated），分不出「用戶真的選過」——
    /// 所以記一個只在 select() 時寫入的新旗標：2026-11-07 拍板，日曆／類比回出廠 Look，用戶之後主動選了才跟用戶。
    nonisolated(unsafe) static var chosenKey = "HomePlayLookChosen"
    static var explicitlyChosen: Bool { UserDefaults.standard.bool(forKey: chosenKey) }

    /// 各錶面的出廠 Look（固件 poster_descriptors.json 的出廠描述符：日曆 default-color-1＝Red-Blue；
    /// 類比照官方形象照＝Neon-Blue 的綠數字——2026-11-07 拍板回到 beta 1 的辨識度）。
    /// 用戶主動選過 Look 就跟用戶（全錶面統一）；沒選過才用出廠值。
    static func faceLook(_ style: FaceStyle) -> HVTruth.Look {
        if explicitlyChosen { return current }
        switch style {
        case .calendar: return HVTruth.look("Red-Blue") ?? current
        case .analog: return HVTruth.look("Neon-Blue") ?? current
        default: return current
        }
    }
    /// 1:1 復刻（2026-11-08 拍板）：沒有主動選 Look、也不是快照指定時，面盤用自己的出廠配色，
    /// 不吃 Look token。官方形象照的 Typograph 是深綠底／黑數字／白指針，Neon-Blue 不是它。
    static var usesFactoryPalette: Bool {
        snapshotName == nil && PosterConfiguration.snapshotOverride == nil
            && FamilyProfiles.memberLook == nil && !explicitlyChosen
    }

    /// 使用者有沒有明確選過 Look（沒選＝預設 Blue-Orange，不驅動著色建議）
    static var wasSelected: Bool {
        snapshotName != nil || PosterConfiguration.snapshotOverride?.extras.lookChosen == true || FamilyProfiles.memberLook != nil
            || PosterConfiguration.current.extras.lookChosen
    }

    static func select(_ n: String, linkDigits: Bool = true) {
        guard let l = HVTruth.look(n) else { return }
        UserDefaults.standard.set(true, forKey: chosenKey)   // 用戶主動選的：之後全錶面跟這個 Look
        if FamilyProfiles.selectLookForMember(n) { return }   // 目前是家人：存到他那一份，不動主人的 Look 與大數字
        var c = PosterConfiguration.current
        c.look = n; c.extras.lookChosen = true
        PosterConfiguration.current = c
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
        // 不留痕跡：整份海報配置（含偏好裡那一份）測完原樣放回
        let before = HPLook.name, savedLook = ClockLook.current, savedConfig = PosterConfiguration.current
        let savedRaw = UserDefaults.standard.data(forKey: PosterStore.defaultsKey)
        let savedChosen = UserDefaults.standard.object(forKey: HPLook.chosenKey)   // chosenKey 也要原樣放回（不然 selftest 之後的快照被當成「用戶選過」）
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
        check(PosterConfiguration.current.look == before && PosterConfiguration.current.extras.lookChosen, "Look：選 Look 寫進海報配置（Look 名＋選過）")   // l10n-ignore
        PosterConfiguration.current = savedConfig
        if let savedRaw { UserDefaults.standard.set(savedRaw, forKey: PosterStore.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: PosterStore.defaultsKey) }
        if let c = savedChosen { UserDefaults.standard.set(c, forKey: HPLook.chosenKey) } else { UserDefaults.standard.removeObject(forKey: HPLook.chosenKey) }
    }
}
