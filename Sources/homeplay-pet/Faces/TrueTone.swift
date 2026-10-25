// 2.0 P07：True Tone——房間色溫偏暖/偏冷時，整面螢幕貼圖跟著微調白點（HomeView 官網「True Tone」，
// HV-MAIN-36／HV-SPECS-33）。Mac 螢幕改不了硬體白點，這裡模擬給桌寵的螢幕看：暖 → 紅升藍降、冷 → 相反，
// 幅度 ±6%（線性），跟 3D 打光用的 ±5.5% 同一個量級；鏡頭關著（不知道色溫）就是 0，完全不動。
// 快照/驗收：HOMEPLAY_TRUE_TONE=-1…1 強制（例：HOMEPLAY_TRUE_TONE=0.9 … --screen-png out.png）。

import AppKit
import CoreImage

enum TrueTone {
    /// 快照／測試強制值（-1…1）
    static let forced: Float? = ProcessInfo.processInfo.environment["HOMEPLAY_TRUE_TONE"].flatMap { Float($0) }

    /// 白點增益：warmth +1（很暖）→ R×1.06、B×0.94；-1（很冷）→ 反過來；0 → (1, 1) 不動
    static func gain(_ warmth: Float) -> (r: Double, b: Double) {
        let w = Double(max(-1, min(1, warmth)))
        return (1 + 0.06 * w, 1 - 0.06 * w)
    }

    /// 套在整面螢幕貼圖上（Face.render 收尾呼叫）；偏移太小（|w| ≤ 0.01）或失敗就回 nil＝用原圖
    static func apply(_ img: CGImage, warmth: Float) -> CGImage? {
        let w = max(-1, min(1, warmth))
        guard abs(w) > 0.01 else { return nil }
        let g = gain(w)
        let ci = CIImage(cgImage: img).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: g.r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: g.b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        return Face.ciContext.createCGImage(ci, from: ci.extent)
    }
}
