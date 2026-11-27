import Foundation

/// 開機先到本地主畫面（預設開）。HomeView 2.0 的 App 都在本機；CarPlay 只是主畫面上的一個 App，
/// 不連手機也能用。要回舊的「開機停在錶面」把 HomePlayBootToHome 設成 false。
enum BootToHome {
    static let key = "HomePlayBootToHome"
    static var enabled: Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}
