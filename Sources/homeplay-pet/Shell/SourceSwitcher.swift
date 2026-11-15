// 2.0 align D：看得見的 CarPlay 切換入口。
// CarPlay 會話活著、但 HomeView 在前面（face.status == .background）：頂端多一則即時動態——一顆車子圖示的小藥丸
//（2026-11-13，取代原本掛在藥丸／把手右下的綠色角標；LiveActivityStack.carPlayActivity）。
// 點那顆藥丸＝切回 CarPlay；錶面上點 👀 膠囊也是（2026-11-09 使用者：兩邊互通）——取代原本「長按藥丸拉開兩顆」的舊手勢；
// 那條路已經不在線上（長按藥丸＝ClioTalk／展開活動），拉開的畫面只剩 --source 快照，程式一併收掉。
import AppKit

enum SourceSwitcher {
    /// CarPlay 會話活著但在背景（HomeView 在前面）
    static func carPlayBehind(_ face: Face) -> Bool { face.status == .background }

    /// 👀 膠囊點一下的歸屬：CarPlay 在背景＝切回 CarPlay；沒有背景會話＝留給 HomePlay 自己（Home 鍵／播放暫停）
    enum CapsuleTap: Equatable { case carPlay, home }
    static func capsuleTap(carPlayBehind: Bool) -> CapsuleTap { carPlayBehind ? .carPlay : .home }
}
