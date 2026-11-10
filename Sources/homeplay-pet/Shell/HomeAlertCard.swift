// 家庭警報卡（L2，拍板 2026-11-07）：任何畫面（錶面、主畫面、App、CarPlay 直播、休眠）頂端浮出的警報卡——
// 點它＝喚醒＋進家庭 App。畫在 Face.render 的最後（連休眠壓黑、閒置變暗都蓋過去，亮度也壓不到它）；
// 觸控走「第一下只喚醒」的豁免點（ShellInput.wakeSwallows 的 exempt，Shell/HomeAlerts.swift 是資料端）。
// 樣式沿用 beta 5 拍板的家庭 App 橫幅：底色永遠不透明紅、白字、脈動只改紅的深淺；家庭 App 自己在時讓給它的橫幅。
import AppKit

enum HomeAlertCard {
    /// 同家庭 App 橫幅的 896×152：圓角同心、離左右緣 64（EdgeContainers 驗過）；放頂端（藥丸底下滑出）
    static let rect = CGRect(x: 64, y: 136, width: 896, height: 152)
    /// 點按 vs 拖動的分界（視窗點）：5 太敏感，手一抖就取消點按；10 跟系統的點擊容差接近
    static let tapSlop: CGFloat = 10
    static var radius: CGFloat { HPTokens.Radius.concentric(rect: rect) }

    /// 上次看到的資料版本：有變化那一幀要重畫（版本號連程式直接 fire 也算到；不再靠通知）
    nonisolated(unsafe) static var lastVersion = -1

    /// 卡片在不在：有警報、家庭 App 沒自己在（它頂部本來就有橫幅，不重疊）
    static var shown: Bool {
        guard !HomeAlerts.active.isEmpty else { return false }
        if Shell.nav.screen == .app("home"), Shell.nav.overlay == .none { return false }
        return true
    }
    static func presence(_ now: Double = CACurrentMediaTime()) -> CGFloat { HPPresence.value("home.alert.card", shown: shown, HPMotion.T.sheet, now: now) }
    static func contains(_ uv: CGPoint?) -> Bool {
        guard let uv, shown else { return false }
        return rect.insetBy(dx: -8, dy: -8).contains(CGPoint(x: uv.x * 1024, y: uv.y * 1024))
    }
    /// 豁免「第一下只喚醒」：休眠／變暗時點在卡上＝直接開卡，不吞
    static func exempt(_ uv: CGPoint?) -> Bool { contains(uv) }

    /// 每幀（tickShell）：過期收卡（資料端 30 秒，生產端本來沒人叫它）、進出動畫、版本變化。回 true＝要重畫
    static func tick(_ now: Double) -> Bool {
        var dirty = false
        if lastVersion != HomeAlerts.version { lastVersion = HomeAlerts.version; dirty = true }
        if HomeAlerts.tick(now) { dirty = true }
        let p = presence(now)
        return dirty || (shown ? p < 0.999 : p > 0.001)
    }

    /// PetView.mouseDown（喚醒門之後、其他卡之前）：按在卡上＝喚醒＋開家庭 App。回 true＝吃掉
    @discardableResult
    static func press(uv: CGPoint?, v: PetView) -> Bool {
        guard contains(uv) else { return false }
        let now = CACurrentMediaTime()
        Shell.lastActive = now   // 意圖輸入：下一幀撤掉壓暗、收起海報（DisplayStage）
        v.mood.activity(now: now, hour: Calendar.current.component(.hour, from: Date()))   // 閒置變暗（睡著的臉）也醒
        v.face.forceDirty = true
        v.shellOpenFromAnywhere("home")   // 從錶面、CarPlay、休眠都照主畫面點圖示的路開（鎖著就是「需要主人」那一頁）
        return true
    }
}

extension Face {
    /// 最上層（Face.render 畫完壓暗之後叫）：休眠、CarPlay 直播上都看得見
    func drawAlertCard(_ g: CGContext, _ now: Double) {
        guard HomeAlertCard.shown, let a = HomeAlerts.active.first else { return }
        let p = HomeAlertCard.presence(now)
        guard p > 0.001 else { return }
        let slide: CGFloat = HPMotion.reduceMotion ? 0 : -(1 - p) * 48
        let r = HomeAlertCard.rect.offsetBy(dx: 0, dy: slide), rad = HomeAlertCard.radius
        // 沿用家庭 App 橫幅（beta 5 拍板）：不透明紅底、脈動只改紅的深淺（1.6 s 一次；減少動態效果不脈動）
        let dim: CGFloat = ClockKit.reduceMotion ? 0 : CGFloat(0.12 * (1 - cos((now - a.at) * 2 * .pi / 1.6)))
        let red = HPTokens.red.blended(withFraction: dim, of: .black) ?? HPTokens.red
        g.setFillColor(red.cgColor)   // 要設在 g 上：NSColor.setFill() 只改 NSGraphicsContext，這裡會沿用上一個填色（白）
        g.addPath(continuousRoundedRect(r, radius: rad)); g.fillPath()
        drawSymbol(g, a.kind.symbol, in: CGRect(x: r.minX + 40, y: r.midY - 30, width: 60, height: 60), color: .white)
        let tf = AppUI.font(44, .semibold)
        // 畫布左上原點：標題在上（基線 midY − 8）、說明在下（基線 midY + 42）
        drawLeft(g, a.kind.title, font: tf, x: r.minX + 128, y: r.midY - 8, color: .white)
        drawLeft(g, Face.clipped(HomeAlerts.body(a), AppUI.font(34), r.width - 200), font: AppUI.font(34), x: r.minX + 128, y: r.midY + 42, color: NSColor.white.withAlphaComponent(0.85))
        HPAX.note(g, r, .button, "\(a.kind.title) \(HomeAlerts.body(a))", shape: .rounded(rad))
    }
}
