// 2.0 promo（宣傳片第 5 拍「keeping an eye on my dog Bailey in the yard」）：攝影機一瞥——
// 從主畫面右上角拉下控制中心，點「攝像头」，直接進那一路攝影機的全螢幕快照（家庭 App 的攝影機頁，HomeKit 快照，每幾秒更新）。
// 開哪一路：設定過的那一路（cameraGlance.id），沒有就第一路。快照與示範只用示範圖（HomeCamArt），不碰真的攝影機。

import AppKit

enum CameraGlance {
    static let key = "cameraGlance.id"
    static var preferredID: String? {
        get { Face.demoData || HomeApp.demo ? "a16" : UserDefaults.standard.string(forKey: key) }   // 示範：「后院」
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 控制中心的磚、宣傳片示範都走這裡：舊畫面模糊放大淡出（跟門鈴一樣的接管），換成攝影機全螢幕
    @MainActor static func open(from v: PetView, takeover: Bool = true) {
        if takeover { Shell.beginTakeover(v.face) }
        _ = HomeApp.shared.showCameras(id: HomeApp.shared.glanceCameraID)
    }
}
