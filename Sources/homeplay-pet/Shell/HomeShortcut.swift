// B 方案：沒有 HomeKit 小幫手時，用 macOS「捷徑」App 的家庭動作控制。
//
// 為什麼要這樣：HomeKit 的 entitlement 只跟著 Apple Developer Program（App Store）的
// provisioning profile 走，Developer ID 簽章拿不到（Apple 帳號說明的 capability 表）。
// 公開版不能直接讀家庭，所以讓使用者自己在捷徑 App 建一個「控制家庭」捷徑，這裡只負責
// 記住名字、用 shortcuts:// 執行。執行會切到捷徑 App，這是這條路的代價。
//
// 只在主執行緒呼叫（點按與設定頁）。
import AppKit

enum HomeShortcut {
    static let nameKey = "home.shortcut.name"

    /// 使用者填的捷徑名稱；空白字串＝還沒設定。前後空白會去掉。
    static var name: String {
        get { cleaned(UserDefaults.standard.string(forKey: nameKey) ?? "") }
        set { UserDefaults.standard.set(cleaned(newValue), forKey: nameKey) }
    }
    static var isSet: Bool { !name.isEmpty }
    /// 去掉前後空白（純函式，selftest 用）
    static func cleaned(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 這台 Mac 有沒有「捷徑」App（macOS 12 起內建；沒有就不顯示這條路）
    static var available: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") != nil
    }

    /// shortcuts://run-shortcut?name=…；名稱由 URLComponents 轉義（中文、空白都可以）
    static func runURL(name: String) -> URL? {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        return c.url
    }

    /// 執行目前設定的捷徑；回 false＝沒設定，或系統不認這個 scheme
    @discardableResult
    static func run() -> Bool {
        guard isSet, let u = runURL(name: name) else { return false }
        return NSWorkspace.shared.open(u)
    }

    /// 打開捷徑 App（使用者要建立或修改捷徑時）
    static func openApp() {
        guard let u = URL(string: "shortcuts://") else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: selftest

    static func selftest(_ check: (Bool, String) -> Void) {
        let u = runURL(name: "回家 開燈")   // l10n-ignore：selftest 樣本
        let s = u?.absoluteString ?? ""
        check(s.hasPrefix("shortcuts://run-shortcut?name="), "捷徑：run-shortcut 的網址")
        check(!s.contains("回家") && s.contains("%E5%9B%9E"), "捷徑：名稱有轉義（中文不會直接出現在網址）")
        check((runURL(name: "")?.absoluteString ?? "").hasSuffix("name="), "捷徑：空名稱仍能組出網址（由呼叫端擋）")
        check(cleaned("  回家 ") == "回家" && cleaned("\n") == "", "捷徑：名稱去頭尾空白")
    }
}
