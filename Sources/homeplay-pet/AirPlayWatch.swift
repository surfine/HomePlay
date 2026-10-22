// 用 Mac 內建的「AirPlay 接收器」看影片：iPhone 上的任何 App（含 Apple TV+）都能 AirPlay 到這台 Mac，
// 由系統的 AirPlayUIAgent 全螢幕播放。HomePlay 不攔它、不錄它，只看「它的視窗在不在、在哪」
// （CGWindowList 的擁有者名稱與位置，不需要螢幕錄製權限），讓桌寵轉頭看著影片。

import AppKit

enum AirPlayWatch {
    /// 系統 AirPlay 影片視窗的中心（螢幕座標，左下原點）；沒在播就是 nil
    nonisolated(unsafe) private(set) static var videoCenter: CGPoint?
    nonisolated(unsafe) private static var timer: Timer?
    nonisolated(unsafe) static var onChange: ((Bool) -> Void)?

    /// 每 2 秒看一次（便宜：只讀視窗清單）
    static func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { _ in poll() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common); timer = t
        poll()
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
        if was != (c != nil) { onChange?(c != nil) }
    }

    /// 系統設定裡 AirPlay 接收器的位置（一般 › 隔空投送與接力）
    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Handoff-Settings.extension") { NSWorkspace.shared.open(u) }
    }
}
