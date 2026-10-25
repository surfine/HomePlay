import CoreLocation
import CoreWLAN

// 自動把 Wi-Fi 名稱帶給接收器：macOS 26 起 ipconfig／CoreWLAN 只把 SSID 給有定位權限的 App
//（本機實測：接收器讀到的是 <redacted>），沒有名稱 iPhone 拿到的 Wi-Fi 設定是空的、連不回來。
// 桌寵有定位權限就自己讀、悄悄送給接收器（不寫進 wireless.json：Mac 換網路時下次照樣重讀）；
// 沒問過就先出說明卡再問，而且只在真的卡在「Wi-Fi 名稱未知」時問；被拒就退回手填。

enum WiFiName {
    enum Auth: Equatable { case granted, notDetermined, denied }
    enum Action: Equatable {
        case send(String)     // 讀得到：送給接收器
        case askPermission    // 卡住了、還沒問過：說明卡 → 系統框
        case manual           // 被拒、或允許了卻讀不到（沒連 Wi-Fi）：打開 Wi-Fi 設定手填
        case nothing
    }

    /// macOS 隱藏時給的是 <redacted> 或空字串，都不能用
    static func usable(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.localizedCaseInsensitiveContains("redacted") else { return nil }
        return t
    }

    /// 純邏輯（selftest 直接驅動）。receiverKnows：接收器已經有名稱；stuck：接收器報了 ssidUnknown（交接卡住）；
    /// quiet：桌寵只是在背景掛著（不打擾）；alreadyAsked：這次執行已經出過說明卡（使用者選了「以後」）。
    static func decide(receiverKnows: Bool, readable: String?, auth: Auth, stuck: Bool, quiet: Bool, alreadyAsked: Bool) -> Action {
        if receiverKnows { return .nothing }
        if let s = usable(readable) { return .send(s) }
        guard stuck, !quiet else { return .nothing }   // 沒卡住就不為它彈任何東西
        if auth == .notDetermined, !alreadyAsked { return .askPermission }
        return .manual
    }

    /// 目前 Wi-Fi 的名稱；沒權限、沒連 Wi-Fi 都是 nil。不寫日誌。
    static func current() -> String? { usable(CWWiFiClient.shared().interface()?.ssid()) }

    static var auth: Auth {
        guard WeatherSource.canAskLocation else { return .denied }   // 開發版沒有定位用途說明，系統不會問
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        default: return .granted
        }
    }

    private static var pending: LocationAsk?
    /// 彈系統定位框；結果回主執行緒
    static func request(_ done: @escaping (Bool) -> Void) {
        guard WeatherSource.canAskLocation else { done(false); return }
        let ask = LocationAsk { ok in pending = nil; done(ok) }
        pending = ask
        ask.start()
    }
}

/// 拿一次定位授權的結果（CLLocationManager 要被留著，回呼才會來）
private final class LocationAsk: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var done: ((Bool) -> Void)?
    init(_ done: @escaping (Bool) -> Void) { self.done = done }
    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { finish(manager.authorizationStatus) }
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard m.authorizationStatus != .notDetermined else { return }
        finish(m.authorizationStatus)
    }
    private func finish(_ s: CLAuthorizationStatus) {
        guard let d = done else { return }
        done = nil
        let ok = s != .denied && s != .restricted && s != .notDetermined
        DispatchQueue.main.async { d(ok) }
    }
}
