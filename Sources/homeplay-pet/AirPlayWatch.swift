// 用 Mac 內建的「AirPlay 接收器」看影片：iPhone 上的任何 App（含 Apple TV+）都能 AirPlay 到這台 Mac，
// 由系統的 AirPlayUIAgent 全螢幕播放。HomePlay 不攔它、不錄它，只看「它的視窗在不在、在哪」
// （CGWindowList 的擁有者名稱與位置，不需要螢幕錄製權限），讓桌寵轉頭看著影片。

import AppKit

enum AirPlayWatch {
    /// 系統 AirPlay 影片視窗的中心（螢幕座標，左下原點）；沒在播就是 nil
    nonisolated(unsafe) private(set) static var videoCenter: CGPoint?
    nonisolated(unsafe) private static var timer: Timer?
    nonisolated(unsafe) static var onChange: ((Bool) -> Void)?
    /// 沒有影片時放慢到 5 秒（CGWindowList 每趟都是一次 WindowServer 往返），看到了才回 2 秒追位置；
    /// 桌寵被遮住／螢幕休眠時整個停掉（畫面看不到，眼神目標沒有意義），恢復可見先補看一次。
    nonisolated(unsafe) private static var fast = false
    nonisolated(unsafe) private static var paused = false

    private static func arm() {
        timer?.invalidate(); timer = nil
        guard !paused else { return }
        let interval: Double = fast ? 2 : 5
        let t = Timer(timeInterval: interval, repeats: true) { _ in poll() }
        t.tolerance = interval == 2 ? 0.5 : 1.5
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    static func start() {
        guard timer == nil, !paused else { return }
        arm()
        poll()
    }

    /// 桌寵遮住／螢幕休眠時叫 true，恢復可見叫 false（setOccluded 轉發）
    static func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        if p { timer?.invalidate(); timer = nil } else { arm(); poll() }
    }

    private static func poll() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var found: CGRect?
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "AirPlayUIAgent" {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width >= 320, r.height >= 180, found.map({ r.width * r.height > $0.width * $0.height }) ?? true { found = r }
        }
        // CGWindowList 是左上原點（主螢幕高度為準），換成 AppKit 的左下原點
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let c = found.map { CGPoint(x: $0.midX, y: mainH - $0.midY) }
        let was = videoCenter != nil
        videoCenter = c
        if fast != (c != nil) { fast = c != nil; arm() }   // 出現／消失：切換 2 秒／5 秒節奏
        if was != (c != nil) { onChange?(c != nil) }
    }

    /// 系統設定裡 AirPlay 接收器的位置（一般 › 隔空投送與接力）
    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Handoff-Settings.extension") { NSWorkspace.shared.open(u) }
    }
}
