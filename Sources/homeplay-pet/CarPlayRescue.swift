import Foundation

/// 連線救援的門檻（純邏輯，自檢直接驅動）。
/// 只在「已經配對的手機、連續幾分鐘連不上」時才提議重新配對；平常不打扰，
/// 一次連線成功就收回。2026-11-18 使用者：軟體要自己會救，不能每次靠人。
enum CarPlayRescue {
    /// 至少失敗這麼久才提議重新配對（前面的解鎖、開藍牙、等它自己回來都還有機會）
    static let offerAfter: Double = 180

    static func shouldOffer(reason: String?, paired: Bool, failedFor: Double) -> Bool {
        guard paired, failedFor >= offerAfter else { return false }
        return reason == "phoneNoAnswer" || reason == "wifiNoConnectBack"
    }
}
