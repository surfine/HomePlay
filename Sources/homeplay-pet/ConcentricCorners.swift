// 設定 › CarPlay › 圓角：寫 Application Support/HomePlay/carplay-display.json 的 cornerStyle，接收器每秒看一次、改了立刻重開會話套用。
// 同心：安全區照這台 iPhone 的圓角算到與機身同心，桌布鋪滿、圖示和 Dock 往內收；最大畫面：只躲開機身圓角；折衷在中間。
// 每台手機（iOS 版本）的圓角由接收器量、記在 carplay-corner.json；桌寵這邊只讀它算好的內收量來顯示。
import Foundation

enum ConcentricCorners {
    enum Style: String, CaseIterable {
        case concentric, balanced, maximize
        var title: String {
            switch self {
            case .concentric: return L("settings.corners.concentric", "同心")
            case .balanced: return L("settings.corners.balanced", "折衷")
            case .maximize: return L("settings.corners.maximize", "最大画面")
            }
        }
    }
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay/carplay-display.json")
    }
    private static var file: [String: Any] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    static var style: Style {
        get {
            let o = file
            if let raw = o["cornerStyle"] as? String, let s = Style(rawValue: raw) { return s }
            return (o["concentric"] as? Bool) == false ? .maximize : .concentric   // 舊的開關
        }
        set {
            var o = file
            o["cornerStyle"] = newValue.rawValue; o["concentric"] = nil
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { try? d.write(to: url, options: .atomic) }
        }
    }
    /// 學圓角那一次連線的桌寵縮放只在需要 iOS 圓角的策略下才有意義
    static var enabled: Bool { style != .maximize }
    /// 接收器算好的：目前這台 iPhone 每邊內收多少（畫面 1088 px）
    static var appliedInset: Int? {
        let u = url.deletingLastPathComponent().appendingPathComponent("carplay-corner.json")
        guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["appliedInset"] as? NSNumber)?.intValue
    }
}
