// 快照、示範、產品照出圖時的隱私閘：這些圖會被存檔、拿去跟官方圖比對，甚至放上官網，
// 所以一律不讀使用者真的訊息、聯絡人、最近通話、照片；各 App 看到 active 就改用示範資料。
import Foundation

enum SnapshotPrivacy {
    static let active: Bool = {
        let a = CommandLine.arguments
        return ["--screen-png", "--snapshot", "--product-shot", "--demo-official", "--settings-out"].contains { a.contains($0) }
            || ProcessInfo.processInfo.environment["HOMEPLAY_DEMO"] != nil
    }()

    /// 快照／示範模式把裝置名、區網 IP 遮掉（回歸清單：裝置頁快照泄漏真機名與 IP）
    static func mask(_ s: String) -> String {
        guard active, !s.isEmpty else { return s }
        return String(repeating: "•", count: max(3, min(8, s.count)))
    }
    /// 保留網段樣式、每一段都遮：192.168.1.20 → •••.•••.•••.•••
    static func maskIP(_ s: String) -> String {
        guard active, !s.isEmpty else { return s }
        return s.split(separator: ".").map { String(repeating: "•", count: max(2, $0.count)) }.joined(separator: ".")
    }
}
