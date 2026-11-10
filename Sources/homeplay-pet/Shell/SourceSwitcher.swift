// 2.0 align D：看得見的 CarPlay 切換入口。
// CarPlay 會話活著、但 HomeView 在前面（face.status == .background）：藥丸右下掛一顆 CarPlay 角標。
// 點藥丸／角標＝切回 CarPlay（2026-11-09 使用者：兩邊互通）——取代原本「長按藥丸拉開兩顆」的舊手勢；
// 那條路已經不在線上（長按藥丸＝ClioTalk／展開活動），拉開的畫面只剩 --source 快照，程式一併收掉。
import AppKit

enum SourceSwitcher {
    /// CarPlay 會話活著但在背景（HomeView 在前面）
    static func carPlayBehind(_ face: Face) -> Bool { face.status == .background }

    /// 👀 膠囊點一下的歸屬：CarPlay 在背景＝切回 CarPlay；沒有背景會話＝留給 HomePlay 自己（Home 鍵／播放暫停）
    enum CapsuleTap: Equatable { case carPlay, home }
    static func capsuleTap(carPlayBehind: Bool) -> CapsuleTap { carPlayBehind ? .carPlay : .home }
}

extension Face {
    /// 藥丸右下的 CarPlay 角標（會話在背景）
    func drawSourceBadge(_ g: CGContext, pill r: CGRect) {
        let d = HPTokens.Size.sourceBadge
        let b = CGRect(x: r.maxX - d * 0.75, y: r.maxY - d * 0.75, width: d, height: d)
        g.saveGState()
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: b.insetBy(dx: -2, dy: -2))   // 2 px 白邊：跟藥丸分開
        g.setFillColor(HPComponents.green.cgColor); g.fillEllipse(in: b)
        drawSymbol(g, "car.fill", in: b.insetBy(dx: d * 0.22, dy: d * 0.22), color: .white)
        g.restoreGState()
    }
}
