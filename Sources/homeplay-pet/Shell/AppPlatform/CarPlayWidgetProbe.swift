// CarPlay 小工具頁探驗（拍板第 4 條：能不能一鍵跳到 CarPlay 的小工具畫面——那一頁是手機自己畫的）。
// 只在明確旗標下跑，不影響平常的 CarPlay：
//
//   homeplay-pet --carplay-widget-probe [all|網址,網址…] [--probe-interval 秒]
//
// CarPlay 一連上（第一格畫面進來）就照順序對每個候選網址送兩種請求，間隔預設 8 秒：
//   requestUI＋網址、不帶主螢幕 uuid（2026-11-06 真機：開 App 只有這種有效）；
//   showUI＋網址＋主螢幕 uuid（副屏 showCluster 驗過的那一種）。
// 走既有的事件通道（接收端 Wireless.phoneControl 已經認 {"type":"showUI","url","kind","uuid"}），接收端不用改、不用重新打包。
// 每一步寫進 ~/Library/Application Support/HomePlay/carplay-widget-probe.log（時間、網址、種類）；結果要人看手機或桌寵畫面記錄。
// 最後一步之後送 nowplaying: 收尾，畫面回到已知狀態。

import Foundation

enum CarPlayWidgetProbe {
    static let flag = "--carplay-widget-probe"

    /// 預設候選（順序＝先試最可能的）：CarPlay 的分割畫面一般叫 Dashboard，所以 dashboard: 系列排前面，
    /// 再來是 widgets:／carplay-widgets: 這類猜測；nowplaying: 是真機驗過會動的對照組。
    static let candidates = [
        "dashboard:", "dashboard://", "dashboard://widgets", "dashboard://nowplaying",
        "widgets:", "widgets://", "carplay-widgets:", "carplay://widgets", "smartstack:",
        "nowplaying:",
    ]

    struct Step: Equatable { var url: String; var kind: String; var uuid: Bool }

    /// 旗標後面的參數 → 步驟：all（或沒給）＝全部候選；也可以給逗號分隔的網址
    static func steps(_ arg: String?) -> [Step] {
        let urls: [String]
        if let a = arg, !a.hasPrefix("--"), a != "all" {
            urls = a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(":") && $0.count <= 128 }
        } else {
            urls = candidates
        }
        return urls.flatMap { [Step(url: $0, kind: "requestUI", uuid: false), Step(url: $0, kind: "showUI", uuid: true)] }
    }

    static func message(_ s: Step) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: ["type": "showUI", "url": s.url, "kind": s.kind, "uuid": s.uuid], options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static var requested: [Step]? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag) else { return nil }
        return steps(i + 1 < a.count ? a[i + 1] : nil)
    }

    nonisolated(unsafe) private static var started = false

    /// CarPlay 剛連上時叫（主執行緒）；只跑一次
    static func startIfRequested(send: @escaping (String) -> Void) {
        guard !started, let list = requested, !list.isEmpty else { return }
        started = true
        let gap = arg("--probe-interval").flatMap(Double.init).map { max(3, min(60, $0)) } ?? 8
        func note(_ s: String) { log("carplay-widget-probe: " + s); appendDiag("carplay-widget-probe.log", s) }
        note("start \(list.count) steps, every \(Int(gap)) s")
        for (i, s) in list.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + gap * Double(i)) {
                guard let m = message(s) else { return }
                note("step \(i + 1)/\(list.count) \(s.kind) \(s.url)\(s.uuid ? " +uuid" : "")")
                send(m)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 + gap * Double(list.count)) {
            if let m = message(Step(url: "nowplaying:", kind: "requestUI", uuid: false)) { send(m) }
            note("done (sent nowplaying: to reset)")
        }
    }
}
