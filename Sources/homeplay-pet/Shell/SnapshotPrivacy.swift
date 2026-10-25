// 快照、示範、產品照出圖時的隱私閘：這些圖會被存檔、拿去跟官方圖比對，甚至放上官網，
// 所以一律不讀使用者真的訊息、聯絡人、最近通話、照片；各 App 看到 active 就改用示範資料。
import Foundation

enum SnapshotPrivacy {
    static let active: Bool = {
        let a = CommandLine.arguments
        return ["--screen-png", "--snapshot", "--product-shot", "--demo-official", "--settings-out"].contains { a.contains($0) }
            || ProcessInfo.processInfo.environment["HOMEPLAY_DEMO"] != nil
    }()
}
