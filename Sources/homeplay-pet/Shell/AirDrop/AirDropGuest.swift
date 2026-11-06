// 訪客臨時接收：控制中心的 AirDrop 模組（2026-11-07 拍板改用系統官方開關）。
// 按下＝打開系統設定的 AirDrop 頁，請使用者自己選「所有人（10 分鐘）」——系統自己計時收回。HomePlay 不寫系統設定、不倒數。
// 舊版（自己寫 AirDrop 的可被發現設定、自己倒數）留下的待還原紀錄：啟動時照舊還原一次，然後刪掉紀錄（recoverIfNeeded）。
// 還原的寫入抽成 AirDropDiscoveryStore：自檢與快照用記憶體版，絕不碰真的系統設定。

import AppKit

/// 系統「可被發現」設定的讀寫（只剩舊紀錄的補還原用）
protocol AirDropDiscoveryStore: AnyObject {
    func read() -> String?
    func write(_ value: String)
}

/// 真的：CFPreferences 寫 com.apple.sharingd（舊版寫過的那一份）
final class SharingdPrefs: AirDropDiscoveryStore {
    private let domain = "com.apple.sharingd" as CFString, key = "DiscoverableMode" as CFString
    func read() -> String? {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }
    func write(_ value: String) {
        CFPreferencesSetValue(key, value as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// 記憶體版：快照、自檢
final class AirDropMemoryStore: AirDropDiscoveryStore {
    var value: String?
    var writes: [String] = []
    init(_ v: String? = "Contacts Only") { value = v }
    func read() -> String? { value }
    func write(_ v: String) { writes.append(v); value = v }
}

final class AirDropGuest {
    static let everyone = "Everyone", contacts = "Contacts Only"
    /// 舊版的待還原紀錄（原值）
    static let recordKey = "airdrop.guest.restore"
    static let settingsURL = "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension"

    nonisolated(unsafe) static var shared = AirDropGuest(store: CCSystem.demo ? AirDropMemoryStore() : SharingdPrefs(), persist: !CCSystem.demo)

    let store: AirDropDiscoveryStore
    let persist: Bool
    /// 紀錄存在哪（自檢換成自己的 suite）
    let defaults: UserDefaults
    /// 打開系統的 AirDrop 設定；自檢換成假的
    var openSettings: () -> Void = {
        guard !CCSystem.demo, let u = URL(string: AirDropGuest.settingsURL) else { return }
        NSWorkspace.shared.open(u)
    }

    init(store: AirDropDiscoveryStore, persist: Bool, defaults: UserDefaults = .standard) { self.store = store; self.persist = persist; self.defaults = defaults }

    /// 控制中心按下：打開系統的 AirDrop 設定，讓使用者選「所有人（10 分鐘）」。不寫系統設定
    func open() { openSettings() }

    /// 原值 → 還原要寫回的值（原值是 Everyone 或沒設過就寫 Contacts Only，不把使用者留在公開狀態）
    static func restoreTarget(_ original: String?) -> String {
        guard let o = original, !o.isEmpty, o != everyone else { return contacts }
        return o
    }

    /// 啟動時叫：舊版留下待還原紀錄＝寫回原值一次、刪掉紀錄。回 true＝有補還原
    @discardableResult
    func recoverIfNeeded() -> Bool {
        guard persist, let d = defaults.dictionary(forKey: Self.recordKey) else { return false }
        let original = (d["has"] as? Bool) == true ? d["original"] as? String : nil
        store.write(Self.restoreTarget(original))
        defaults.removeObject(forKey: Self.recordKey)
        return true
    }
}
