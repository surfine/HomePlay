// 2.0 P05：畫出來的螢幕的輔助使用——HPDS 這一層。
//
// 螢幕是一張 1024² 的 Core Graphics 畫布，VoiceOver／語音控制／切換控制看不到上面的字和按鈕。
// HPComponents 的元件（膠囊鈕、圓鈕、分段、開關、晶片、膠囊列、大標題…）畫的時候順手記一筆「這裡有什麼」：
// 框（換回畫布座標）、角色、標籤、值。PetView（Shell/ShellAccessibility.swift）把它們跟外殼自己知道的
// 東西（主畫面圖示、控制中心的磚、頂端藥丸）合起來，變成 NSAccessibilityElement。
//
// 只收主畫布那一張（Face.render 的 makeImage）；過場、逐行浮現用的離屏小畫布不算，畫完那一格再記。
// 另外：「畫面文字大小」（HPType.textScale）與「用鍵盤操作畫面」的設定也放這裡。

import AppKit

/// 畫在畫布上的一個可讀／可按的東西（1024 畫布座標，左上原點）
struct HPAXNote: Equatable {
    enum Role: Equatable {
        case button
        case toggle(Bool)
        case radio(Bool)
        case text
        case heading
        case slider(Double)
    }
    /// 焦點環的形狀
    enum Shape: Equatable { case capsule, circle, rounded(CGFloat) }
    var role: Role
    var label: String
    var value: String? = nil
    var rect: CGRect
    var shape: Shape = .capsule
    /// "base"：App 或主畫面；"clio"：ClioTalk 那張卡（蓋在最上面）
    var section: String = "base"
}

enum HPAX {
    nonisolated(unsafe) private static var base: CGContext?
    nonisolated(unsafe) private static var baseInverse = CGAffineTransform.identity
    nonisolated(unsafe) private static var building: [HPAXNote] = []
    nonisolated(unsafe) private static var section = "base"
    /// 上一格畫完的那一份
    nonisolated(unsafe) static private(set) var notes: [HPAXNote] = []
    /// notes 換了就 +1（PetView 用來決定要不要發 layoutChanged）
    nonisolated(unsafe) static private(set) var generation = 0

    /// Face.render 的主畫布開始（已經縮放到 1024 單位）
    static func begin(_ g: CGContext) {
        base = g; baseInverse = g.ctm.inverted(); building = []; section = "base"
    }
    /// 畫完一格：跟上一份不一樣才換
    static func end() {
        guard base != nil else { return }
        base = nil
        if building != notes { notes = building; generation &+= 1 }
        // 有輔助技術在聽：比對畫面、發 layoutChanged／valueChanged（排到這一格畫完之後）
        if ShellAccessibility.clientSeen {
            DispatchQueue.main.async { ShellAccessibility.frameDone((NSApp.delegate as? AppDelegate)?.view) }
        }
    }
    /// 之後記的都屬於這一層（ClioTalk 卡開始畫時叫 enter("clio")）
    static func enter(_ s: String) { if base != nil { section = s } }

    /// 記一筆。g 不是主畫布（離屏小畫布）就不記；標籤空的不記；大半在畫面或裁切範圍外的不記；同一個框只記第一次
    static func note(_ g: CGContext, _ r: CGRect, _ role: HPAXNote.Role, _ label: String, value: String? = nil, shape: HPAXNote.Shape = .capsule) {
        guard let base, g === base else { return }
        let label = label.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, r.width > 1, r.height > 1 else { return }
        let clip = g.boundingBoxOfClipPath
        let local = clip.isNull || clip.isInfinite ? r : r.intersection(clip)
        guard !local.isNull, local.width * local.height >= 0.5 * r.width * r.height else { return }
        let rr = r.applying(g.ctm.concatenating(baseInverse))
        let vis = rr.intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard !vis.isNull, vis.width * vis.height >= 0.5 * rr.width * rr.height else { return }
        let key = rr.integral
        guard !building.contains(where: { $0.rect.integral == key && $0.section == section }) else { return }
        building.append(HPAXNote(role: role, label: label, value: value, rect: rr, shape: shape, section: section))
    }

    /// 圓鈕只有符號：認得的符號給標籤（其餘不記，免得 VoiceOver 念出「按鈕」卻不知道是什麼）
    static func symbolLabel(_ symbol: String, rect: CGRect) -> String? {
        if rect.integral == HPTokens.backButton.integral || rect.contains(CGPoint(x: HPTokens.backButton.midX, y: HPTokens.backButton.midY)) {
            return symbol == "xmark" ? L("a11y.close", "关闭") : L("a11y.back", "返回")
        }
        switch symbol {
        case "xmark": return L("a11y.close", "关闭")
        case "plus": return L("a11y.add", "添加")
        case "minus", "chevron.down": return L("a11y.decrease", "减少")   // 2.0 depth：溫控的 ∨ ∧ 也念得出來
        case "chevron.up": return L("a11y.increase", "增加")
        case "square.grid.2x2.fill": return L("a11y.allCameras", "全部摄像头")
        case "chevron.left": return L("a11y.previous", "上一个")
        case "chevron.right": return L("a11y.next", "下一个")
        case "mic.slash.fill": return L("a11y.micOff", "麦克风已关闭")
        default: return nil
        }
    }

    /// 測試用：直接塞一份（selftest）
    static func _setForTesting(_ n: [HPAXNote]) { notes = n; generation &+= 1 }
}

// MARK: - 設定：畫面文字大小、用鍵盤操作畫面

enum HPAccessibilitySettings {
    static let textSizeKey = "screenTextSize"
    static let keyboardKey = "screenKeyboardNavigation"

    /// 0 預設、1 大、2 特大（快照：--text-size large|xlarge）
    static var textSize: Int {
        get {
            if let o = override { return o }
            return max(0, min(2, UserDefaults.standard.integer(forKey: textSizeKey)))
        }
        set { UserDefaults.standard.set(max(0, min(2, newValue)), forKey: textSizeKey); changed() }
    }
    nonisolated(unsafe) static var override: Int? = {
        let a = CommandLine.arguments
        if a.contains("--selftest") { return 0 }   // 自檢的字級表照預設驗，不受這台 Mac 的偏好影響
        guard let i = a.firstIndex(of: "--text-size"), i + 1 < a.count else { return nil }
        return ["default": 0, "large": 1, "xlarge": 2][a[i + 1]]
    }()
    static func scale(for level: Int) -> CGFloat { [1, 1.25, 1.5][max(0, min(2, level))] }

    /// 使用者打開了「用鍵盤操作畫面」；系統「鍵盤導覽」（Full Keyboard Access）打開時也算
    static var keyboardNavigation: Bool {
        get { UserDefaults.standard.bool(forKey: keyboardKey) || NSApp?.isFullKeyboardAccessEnabled == true || CommandLine.arguments.contains("--keyboard-focus") }
        set { UserDefaults.standard.set(newValue, forKey: keyboardKey); changed() }
    }
    static var keyboardNavigationSetting: Bool { UserDefaults.standard.bool(forKey: keyboardKey) }

    /// 設定改了：畫面重畫（主畫面圖層也重建）
    static func changed() {
        Shell.homeLayer = nil
        (NSApp.delegate as? AppDelegate)?.view?.face.forceDirty = true
    }
}
