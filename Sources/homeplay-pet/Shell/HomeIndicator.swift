// 2.0：👀 膠囊兼任 Home Indicator（拍板 2026-11-06）——CarPlay 與 HomeView 一體化。
//
// 膠囊在螢幕頂端中間（主畫面、App 上就是頂端藥丸；錶面上是頂端中間那一塊；CarPlay 畫面上是外圈 80 px 那條帶）。
// 語法照 iOS 的 Home Indicator，只是方向反過來（往下拉）：
// - 往下拉一段放手＝回主畫面（距離過 commit，或過四成而且甩得快）；
// - 往下拉住、停一下＝App 切換器（拉過 armDistance、手指幾乎不動 holdTime）；
// - 拉回去（距離退到門檻以下）＝取消，放手彈回原處；拖曳全程跟手；
// - 點＝照舊（錶面交回原本的點按、主畫面／App 上是 Home 鍵與即時動態）；長按＝ClioTalk 開始聽（原本「頂端中間往下拉」那一招）。
// CarPlay 畫面上只有膠囊那條帶歸外殼，其餘觸控照舊全部送給 iPhone。減少動態效果：卡片不縮放，只淡入淡出。
// 鍵盤版（2026-11-07）：空白鍵＝👀（eyesKey）——CarPlay 在前面＝回主畫面、其他時候＝叫 CarPlay；CarPlay 畫面上其他鍵＝車上旋鈕（CarPlayKnobKeys）。
// 快照：--indicator-pull 距離[,hold]（拉著不放的那一格）、HOMEPLAY_INDICATOR_RELEASE=home|switcher|cancel＋HOMEPLAY_ANIM=indicator:t（放手後）。

import AppKit

enum HomeIndicator {
    // MARK: 手感參數（1024 畫布 px、秒）

    /// 拉這麼遠放手＝回主畫面
    static let commit: CGFloat = 110
    /// 沒拉到 commit：過這個比例、放手速度又超過 flick（px/s）也算（輕掃）
    static let flickFraction: CGFloat = 0.4
    static let flick: CGFloat = 650
    /// 拉到這裡停住＝App 切換器
    static let armDistance: CGFloat = 70
    /// 停多久算「停住」；這麼小的晃動不算動
    static let holdTime: Double = 0.22
    static let holdJitter: CGFloat = 4
    /// 長按膠囊＝ClioTalk
    static let longPress: Double = 0.5

    enum Surface: Equatable { case face, home, app, carPlay }
    /// 這一下按下去歸誰：膠囊（外殼的 Home Indicator）、控制中心、CarPlay（送給 iPhone）、外殼其他的路
    enum Owner: Equatable { case indicator, controlCenter, carPlay, shell }
    enum Outcome: Equatable { case cancel, home, switcher }

    /// 放手：先看是不是停住過（切換器）、再看距離與速度（回主畫面）；都不是＝取消
    static func outcome(distance d: CGFloat, velocity v: CGFloat, armed: Bool) -> Outcome {
        if armed && !disarms(distance: d) { return .switcher }
        if d >= commit || (d >= commit * flickFraction && v > flick) { return .home }
        return .cancel
    }
    /// 放手時這一下算什麼：長按用掉了／拖離藥丸（沒往下拉）再放開＝什麼都不做；拉著＝照距離收；
    /// 原地點＝Home 鍵（主畫面、App、CarPlay：同一顆 👀 在哪裡點都是 Home——2026-11-07 使用者：CarPlay 上「眼睛按鈕按不到」）
    /// 或交回原本的點按（錶面）。拖離再放開不是點按（同 iOS：手指滑出按鈕＝取消）
    enum ReleaseAction: Equatable { case none, settle, tap }
    static func releaseAction(consumed: Bool, claimed: Bool, moved: Bool, onCarPlay: Bool) -> ReleaseAction {
        if consumed { return .none }
        if claimed { return .settle }
        return moved ? .none : .tap
    }
    /// 開始拉：CarPlay 上要先把直播收到背景，收不到（交接凍結、還沒真的連上）就不開始——不然導覽改了、畫面還是直播
    static func pullBegins(surface: Surface, demo: Bool, backgrounded: Bool) -> Bool { surface != .carPlay || demo || backgrounded }
    /// 拉住停一下：距離夠、而且停了夠久
    static func shouldArm(distance: CGFloat, sinceMove: Double) -> Bool { distance >= armDistance && sinceMove >= holdTime }
    /// 停住之後又拉回去：退到這裡以下就不算切換器了（中途反悔）
    static func disarms(distance: CGFloat) -> Bool { distance < armDistance * 0.6 }
    /// 釋放速度（px/s，往下為正）：最後幾個取樣；最後一次移動已經是 80 ms 前＝停住才放，沒有速度
    static func velocity(_ s: [(t: Double, y: CGFloat)], now: Double) -> CGFloat {
        guard let a = s.first, let b = s.last, b.t - a.t > 0.004, now - b.t <= 0.08 else { return 0 }
        return (b.y - a.y) / CGFloat(b.t - a.t)
    }

    // MARK: CarPlay 畫面上的位置

    /// 直播畫面邊長（接收端宣告的 viewArea）
    static let videoSide: CGFloat = 1088
    /// 安全區外圈（直播畫面 px）：接收端算好的內收量；不知道就用宣告的 80
    nonisolated(unsafe) private static var insetCache: (at: Double, value: Int?) = (-1e9, nil)
    static var inset: Int? {
        let now = CACurrentMediaTime()
        if now - insetCache.at > 5 { insetCache = (now, ConcentricCorners.appliedInset) }   // 讀檔：五秒一次就夠
        return insetCache.value
    }
    /// 外圈那條帶在 1024 畫布上有多高
    static func bandHeight(inset: Int?) -> CGFloat { CGFloat(inset ?? 80) * 1024 / videoSide }
    /// CarPlay 畫面上的膠囊：比例照頂端藥丸（208×62），整顆收在外圈帶內、上下留白一樣
    static func carPlayCapsule(inset: Int?) -> CGRect {
        let band = bandHeight(inset: inset)
        let h = max(28, min(44, band * 0.6)), w = h * 208 / 62
        let cy = max(h / 2 + 6, band / 2)
        return CGRect(x: 512 - w / 2, y: cy - h / 2, width: w, height: h)
    }
    /// CarPlay 上歸外殼的那一塊：膠囊左右各寬 64（手指好按），高到帶的下緣
    static func carPlayHit(inset: Int?) -> CGRect {
        let c = carPlayCapsule(inset: inset)
        return CGRect(x: c.minX - 64, y: 0, width: c.width + 128, height: max(bandHeight(inset: inset), c.maxY + 8))
    }

    // MARK: 手勢歸屬（HIG：一個手勢從起手到結束只歸一個層級）

    /// p：1024 畫布座標；pill：主畫面／App 上頂端藥丸的命中框（錶面上沒有）
    static func owner(_ p: CGPoint, on s: Surface, pill: CGRect?, inset: Int?) -> Owner {
        if s == .carPlay { return carPlayHit(inset: inset).contains(p) ? .indicator : .carPlay }
        let u = p.x / 1024, v = p.y / 1024
        if v < 0.13 && u > 0.70 { return .controlCenter }                     // 右上角往下拉＝控制中心（不變）
        if let pill, pill.contains(p) { return .indicator }
        if v < 0.12 && u > 0.32 && u < 0.68 { return .indicator }
        return .shell
    }

    // MARK: 拖曳中的卡片

    /// 卡片縮放：拉越遠越小（最小 0.5）；停住了就縮到切換器卡片的大小
    static func cardScale(_ d: CGFloat, armed: Bool) -> CGFloat {
        let s = max(0.5, 1 - 0.0011 * max(0, d))
        return armed ? min(s, AppSwitcher.cardScale) : s
    }
    /// 卡片的框：水平置中，上緣跟著手指（稍微落後一點）；往上推過頭用 rubber band
    static func cardRect(distance d: CGFloat, armed: Bool) -> CGRect {
        let s = cardScale(d, armed: armed), w = 1024 * s
        let top = d >= 0 ? d * 0.75 : -HPMotion.rubberBand(-d, 200) * 0.5
        return CGRect(x: 512 - w / 2, y: top, width: w, height: w)
    }

    // MARK: 狀態

    struct Pull {
        var surface: Surface
        var shot: CGImage?           // 起手那一刻的畫面（卡片的內容）
        var appID: String?           // App 上（含 CarPlay）：哪一個
        var distance: CGFloat = 0
        var samples: [(t: Double, y: CGFloat)] = []
        var lastMoveAt: Double
        var armed = false
    }
    /// 拉著的這一下（claimed 之後才有）
    nonisolated(unsafe) static var pull: Pull?
    /// 放手之後：卡片從放手的地方走到終點（主畫面的圖示、切換器那一格、或回到整面）
    struct Settle {
        var outcome: Outcome
        var surface: Surface
        var shot: CGImage?
        var appID: String?
        var from: CGRect
        var to: CGRect
        var fadeTo: CGFloat           // 走到終點時卡片的不透明度
        var anim: MotionValue
    }
    nonisolated(unsafe) static var settle: Settle?
    /// 這次按下去已經用掉了（長按開了 ClioTalk）：放手不再做事
    nonisolated(unsafe) static var consumed = false
    /// 按下之後動過了（超過 slop）：長按不成立
    nonisolated(unsafe) static var moved = false
    static let settleSpring = HPMotion.T.appClose.spring
    /// 拉著或取消彈回：整面換成「主畫面＋卡片」來畫
    static var drawsPull: Bool { pull != nil || settle?.outcome == .cancel }

    static func settleProgress(_ now: Double) -> CGFloat { settle.map { max(0, min(1, $0.anim.value(now))) } ?? 0 }
}

// MARK: - 畫

extension Face {
    /// 拉著（或取消彈回）的一格：底下是主畫面，上面是剛才那一面縮成的卡片
    func renderIndicatorPull(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let p = HomeIndicator.pull, s = HomeIndicator.settle
        let surface = p?.surface ?? s?.surface ?? .app
        if surface == .home {   // 主畫面上：後面是桌布
            drawUpright(g, shellWallpaper(), in: full)
        } else {
            drawShellBase(g, now, screen: .home)
            HPGlass.flush(g, face: self, now: now)
        }
        var rect = full, alpha: CGFloat = 1
        if let p {
            rect = HomeIndicator.cardRect(distance: p.distance, armed: p.armed)
            if surface == .home { rect = Shell.lerp(full, rect, 0.25) }   // 已經在主畫面：只輕輕縮一點，提示停住會出切換器
            if HPMotion.reduceMotion { rect = full; alpha = 1 - 0.5 * min(1, p.distance / HomeIndicator.commit) }
        } else if let s {
            let e = HomeIndicator.settleProgress(now)
            rect = HPMotion.reduceMotion ? full : Shell.lerp(s.from, s.to, e)
            alpha = 1 + (s.fadeTo - 1) * e
        }
        drawIndicatorCard(g, p?.shot ?? s?.shot, rect: rect, alpha: alpha)
    }

    /// 放手回主畫面／進切換器之後：卡片蓋在新畫面上走完（renderShell 在畫藥丸之前叫）
    func drawIndicatorSettle(_ g: CGContext, _ now: Double) {
        guard let s = HomeIndicator.settle, s.outcome != .cancel else { return }
        let e = HomeIndicator.settleProgress(now)
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let rect = HPMotion.reduceMotion ? full : Shell.lerp(s.from, s.to, e)
        drawIndicatorCard(g, s.shot, rect: rect, alpha: 1 + (s.fadeTo - 1) * e)
    }

    private func drawIndicatorCard(_ g: CGContext, _ shot: CGImage?, rect r: CGRect, alpha: CGFloat) {
        guard alpha > 0.003 else { return }
        let radius = Screen.cornerRadius * r.width / 1024
        let path = continuousRoundedRect(r, radius: radius)
        g.saveGState(); g.setAlpha(alpha)
        if r.width < 1023 {   // 縮成卡片才有陰影
            g.setShadow(offset: CGSize(width: 0, height: 18 * r.width / 1024), blur: 60 * r.width / 1024, color: NSColor(white: 0, alpha: 0.45).cgColor)
            g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
            g.setShadow(offset: .zero, blur: 0, color: nil)
        }
        g.addPath(path); g.clip()
        if let shot { drawUpright(g, shot, in: r) } else { g.setFillColor(NSColor.black.cgColor); g.fill(r) }
        g.restoreGState()
    }
}

// MARK: - 輸入（ShellInput 的 .indicator 分到這裡）

extension PetView {
    /// 這一面是哪一種（歸屬判斷用）
    var indicatorSurface: HomeIndicator.Surface {
        if showingVideo || CarPlayDemo.showsVideo { return .carPlay }
        switch Shell.nav.screen {
        case .face: return .face
        case .home, .library, .switcher: return .home
        case .app: return .app
        }
    }

    /// 按在膠囊上：排一個長按（0.5 s 沒動、還按著＝ClioTalk 開始聽）
    func indicatorArm(_ e: NSEvent) {
        HomeIndicator.consumed = false; HomeIndicator.moved = false
        let ts = e.timestamp
        DispatchQueue.main.asyncAfter(deadline: .now() + HomeIndicator.longPress) { [weak self] in
            guard let self, let d = ShellInput.down, d.event.timestamp == ts, d.kind == .indicator,
                  !ShellInput.claimed, !HomeIndicator.moved, HomeIndicator.pull == nil else { return }
            // 主畫面／App 上藥丸長成即時動態時：長按＝展開（照舊，放手時由 LiveActivityStack 處理）
            if !self.showingVideo, Shell.nav.screen.coversFace, Shell.pillT > 0.02 { return }
            HomeIndicator.consumed = true
            HPGlass.pressUp()
            log("indicator long press → ClioTalk")
            if self.showingVideo { self.surfaceFromCarPlay("indicator long press") }
            self.shellSwipeListen()
            self.face.forceDirty = true
        }
    }

    /// 往下拉的距離（1024 畫布 px）：有螢幕上的 uv 就照它（1:1 跟手），沒有才用視窗點估
    func indicatorDistance(_ e: NSEvent, uv: CGPoint?) -> CGFloat {
        guard let d = ShellInput.down else { return 0 }
        if let uv, let u0 = d.uv { return (uv.y - u0.y) * 1024 }
        return -(e.locationInWindow.y - d.at.y) * 1024 / max(80, bounds.height * 0.6)
    }

    /// 拉過 slop、而且是往下：開始跟手。回 false＝沒開始（CarPlay 收不到背景）：導覽、peek 都退回原樣
    @discardableResult
    func indicatorBegin(now: Double) -> Bool {
        let surface = indicatorSurface, navBefore = Shell.nav
        var shot = face.lastFrame
        var appID: String?
        if case .app(let id) = Shell.nav.screen { appID = id }
        if surface == .carPlay {
            shot = CarPlayChrome.shared.snapshot() ?? AppSwitcher.shots[CarPlayApp.id]
            appID = CarPlayApp.id
            if let shot { AppSwitcher.shots[CarPlayApp.id] = shot }
            Shell.nav = ShellNav(screen: .app(CarPlayApp.id), overlay: .none, appReturn: .home)
            Shell.carPlayPeek = true   // 拉著的時候先把 CarPlay 收到背景（會話不動），畫面換成外殼來畫；放手取消再叫回來（見下面）
        }
        if surface == .face {   // 錶面底下要有主畫面：桌布＝這一刻的錶面
            Shell.homeHue = Shell.hue(fromFace: face.lastFrame, face: face)
            Shell.captureHomeBackdrop(face.lastFrame)
        }
        HPGlass.pressUp()
        HomeIndicator.pull = HomeIndicator.Pull(surface: surface, shot: shot, appID: appID, lastMoveAt: now)
        HomeIndicator.settle = nil
        let sent = surface == .carPlay && !CarPlayDemo.active ? ((NSApp.delegate as? AppDelegate)?.carPlayToBackgroundForShell() ?? false) : true   // 卡片準備好才切，切過去第一格就是卡片
        guard HomeIndicator.pullBegins(surface: surface, demo: CarPlayDemo.active, backgrounded: sent) else {
            HomeIndicator.pull = nil; Shell.nav = navBefore; Shell.carPlayPeek = false
            log("indicator pull refused: CarPlay stays in front")
            return false
        }
        FacePaging.drag = nil   // 一個手勢只歸一個層級：膠囊接住了，錶面換頁不再等這一下
        Shell.lastActive = now
        face.forceDirty = true
        log("indicator pull begin \(surface)")
        return true
    }

    func indicatorTrack(_ d: CGFloat, t: Double) {
        guard var p = HomeIndicator.pull else { return }
        if abs(d - p.distance) > HomeIndicator.holdJitter { p.lastMoveAt = t }
        p.distance = d
        p.samples.append((t, d)); if p.samples.count > 6 { p.samples.removeFirst(p.samples.count - 6) }
        if p.armed, HomeIndicator.disarms(distance: d) { p.armed = false }   // 拉回去：不算切換器了
        HomeIndicator.pull = p
        face.forceDirty = true
    }

    /// 每幀（shellStep）：手指停住了沒有
    func indicatorStep(_ now: Double) {
        guard var p = HomeIndicator.pull, !p.armed else { return }
        if HomeIndicator.shouldArm(distance: p.distance, sinceMove: now - p.lastMoveAt) {
            p.armed = true; HomeIndicator.pull = p
            face.forceDirty = true
            log("indicator armed: switcher")
        }
    }

    /// 放手：照距離、速度、停住過沒有決定去哪
    /// forceCancel：手勢被取消（兩指接手、系統收走觸控）——卡片從手指的位置彈回；起手在 CarPlay 的彈回後叫回直播
    func indicatorRelease(now: Double, velocity v: CGFloat? = nil, forceCancel: Bool = false) {
        guard let p = HomeIndicator.pull else { return }
        HomeIndicator.pull = nil
        let vel = v ?? HomeIndicator.velocity(p.samples, now: now)
        var outcome = forceCancel ? .cancel : HomeIndicator.outcome(distance: p.distance, velocity: vel, armed: p.armed)
        if p.surface == .home, outcome == .home, Shell.nav.screen != .library, Shell.nav.screen != .switcher { outcome = .cancel }   // 已經在主畫面
        let from = HomeIndicator.cardRect(distance: p.distance, armed: p.armed)
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        var to = full, fadeTo: CGFloat = 1
        log("indicator release d=\(Int(p.distance)) v=\(Int(vel)) armed=\(p.armed) → \(outcome)")
        if let id = p.appID, let shot = p.shot, outcome != .cancel { AppSwitcher.shots[id] = shot }
        switch outcome {
        case .cancel:
            to = full
        case .home:
            if let id = p.appID {
                AppRegistry.app(id)?.didClose()
                Shell.nav.screen = .home; Shell.nav.overlay = .none
                if let r = shellItemRect(id, on: .home) { to = Shell.iconRect(in: r); fadeTo = 0.0 }   // 縮回它的圖示
                else { to = CGRect(x: 512 - 120, y: 400, width: 240, height: 240); fadeTo = 0 }
            } else {
                Shell.nav.screen = .home; Shell.nav.overlay = .none
                to = Shell.pillRect(0); fadeTo = 0   // 錶面：收進頂端的膠囊
            }
            Shell.pillFrom = nil
            Shell.carPlayPeek = false
        case .switcher:
            if let id = p.appID { AppRegistry.app(id)?.didClose(); AppSwitcher.note(id) }
            AppSwitcher.open(now: now)
            Shell.nav.screen = .switcher; Shell.nav.overlay = .none
            let cards = AppSwitcher.cards(face: face)
            if let id = p.appID, let i = cards.firstIndex(of: id) { to = AppSwitcher.cardRect(i) } else { to = AppSwitcher.cardRect(0); fadeTo = 0 }
            Shell.carPlayPeek = false
        }
        HomeIndicator.settle = HomeIndicator.Settle(outcome: outcome, surface: p.surface, shot: p.shot, appID: p.appID, from: p.surface == .home ? full : from, to: to,
                                                    fadeTo: p.surface == .home && outcome != .cancel ? 0 : fadeTo,
                                                    anim: MotionValue("indicator", spring: HomeIndicator.settleSpring, from: 0, to: 1, velocity: 0, now: now))
        Shell.lastActive = now
        face.forceDirty = true
    }

    /// 每幀：放手之後的卡片走完就收掉；取消的 CarPlay 走完才叫回前面
    func indicatorSettleStep(_ now: Double) {
        guard let s = HomeIndicator.settle else { return }
        face.forceDirty = true
        guard s.anim.done(now) else { return }
        HomeIndicator.settle = nil
        if s.outcome == .cancel, s.surface == .carPlay {
            Shell.carPlayPeek = false
            if !CarPlayDemo.active { (NSApp.delegate as? AppDelegate)?.carPlayToFrontForShell() }
        }
    }

    /// 空白鍵＝👀 的鍵盤版（2026-11-07 拍板）。CarPlay 在前面＝回主畫面、會話留在背景——跟膠囊下拉回主畫面同一個結果
    /// （CarPlay 的最後一格存成切換器卡片、CarPlay App 縮回主畫面上的圖示）；其他時候＝叫 CarPlay：照主畫面點 CarPlay 圖示的路
    /// （背景的叫回來、沒連上就去連；訪客鎖著＝「需要主人」）。焦點框顯示時空白鍵先給焦點（ShellAccessibility）。
    func eyesKey() {
        let now = CACurrentMediaTime()
        Shell.lastActive = now
        guard HomeIndicator.pull == nil, HomeIndicator.settle == nil else { return }   // 膠囊正拉著／卡片還在走：不疊第二個
        if (showingVideo && !carVideo.active) || CarPlayDemo.showsVideo {
            if carPlayToHome(reason: "eyes key") { log("eyes key → home (CarPlay in background)") }
            return
        }
        if carVideo.active { onSwitchSource?(); return }   // CarPlay 影片播著：照舊
        log("eyes key → CarPlay")
        shellOpenFromAnywhere(CarPlayApp.id)
    }

    /// 離開 CarPlay 的共同終點（2026-11-07 拍板）：空白鍵、選單「退出 CarPlay」、重按都落在主畫面、會話留背景——
    /// 跟 👀 下拉同一個結果（CarPlay 的最後一格存成切換器卡片、CarPlay App 縮回主畫面上的圖示）。
    /// 回 false＝收不到背景（交接凍結、還沒真的連上），什麼都不動（同膠囊）
    @discardableResult
    func carPlayToHome(reason: String) -> Bool {
        let shot = CarPlayDemo.showsVideo ? AppSwitcher.shots[CarPlayApp.id] : CarPlayChrome.shared.snapshot() ?? AppSwitcher.shots[CarPlayApp.id]
        Shell.nav = ShellNav.carPlayExit
        Shell.carPlayPeek = true   // 收到背景時不讓 showVideo(false) 把導覽打回錶面（同膠囊）
        let sent = CarPlayDemo.active || ((NSApp.delegate as? AppDelegate)?.carPlayToBackgroundForShell() ?? false)
        Shell.carPlayPeek = false
        guard sent else { log("\(reason): CarPlay stays in front"); return false }
        if let shot { AppSwitcher.shots[CarPlayApp.id] = shot }
        CarPlayApp.shared.didClose()
        shellNavigate(.back)   // CarPlay App → 主畫面（appReturn）：縮回它的圖示
        Shell.lastActive = CACurrentMediaTime()
        return true
    }

    /// 快照：--indicator-pull 距離[,hold]（拉著還沒放；hold＝已經停住、切換器準備好）；
    /// 再加 HOMEPLAY_INDICATOR_RELEASE=home|switcher|cancel 看放手之後（HOMEPLAY_ANIM=indicator:t）
    func applyIndicatorDemo() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--indicator-pull"), i + 1 < a.count else { return }
        let parts = a[i + 1].split(separator: ",")
        let d = CGFloat(Double(parts.first ?? "") ?? 120)
        _ = face.render()
        let now = CACurrentMediaTime()
        indicatorBegin(now: now)
        indicatorTrack(d, t: now)
        if parts.contains("hold") { HomeIndicator.pull?.armed = true } else { HomeIndicator.pull?.lastMoveAt = .infinity }   // 快照：手指還在動（不會因為等出圖而變成停住）
        if let r = ProcessInfo.processInfo.environment["HOMEPLAY_INDICATOR_RELEASE"] {
            switch r {
            case "home": HomeIndicator.pull?.armed = false; HomeIndicator.pull?.distance = max(d, HomeIndicator.commit)
            case "switcher": HomeIndicator.pull?.armed = true
            default: HomeIndicator.pull?.armed = false; HomeIndicator.pull?.distance = min(d, HomeIndicator.commit * 0.3)
            }
            indicatorRelease(now: now, velocity: 0)
        }
        face.forceDirty = true
    }
}

// MARK: - CarPlay 畫面的鍵盤＝車上旋鈕

enum CarPlayKnobKeys {
    /// 2026-11-07 拍板：方向鍵＝旋鈕搖桿（x／y）、Tab／⇧Tab＝轉動（wheel）、Return＝選取、Esc＝返回；其他（空白鍵＝👀）回 nil
    static func command(keyCode: UInt16, shift: Bool) -> String? {
        switch keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 48: return shift ? "ccw" : "cw"
        case 36, 76: return "select"
        case 53: return "back"
        default: return nil
        }
    }
    /// 按住會照 macOS 鍵重複一直送的：方向與轉動（選取、返回只送一次）
    static func repeats(_ command: String) -> Bool { !["select", "back"].contains(command) }
}

// MARK: - 自檢

enum HomeIndicatorSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias H = HomeIndicator
        // 判定：距離／速度／停頓
        check(H.outcome(distance: 120, velocity: 0, armed: false) == .home, "膠囊：往下拉過門檻放手＝回主畫面")   // l10n-ignore
        check(H.outcome(distance: 50, velocity: 900, armed: false) == .home, "膠囊：沒到門檻但過四成、甩得快＝回主畫面")   // l10n-ignore
        check(H.outcome(distance: 50, velocity: 200, armed: false) == .cancel, "膠囊：短而慢＝取消、彈回去")   // l10n-ignore
        check(H.outcome(distance: 30, velocity: 3000, armed: false) == .cancel, "膠囊：甩再快、位移太短不算（防誤觸）")   // l10n-ignore
        check(H.outcome(distance: 90, velocity: 0, armed: true) == .switcher, "膠囊：拉住停一下＝App 切換器")   // l10n-ignore
        check(H.outcome(distance: 200, velocity: 1500, armed: true) == .switcher, "膠囊：停住過之後再拉遠，仍是切換器")   // l10n-ignore
        check(H.disarms(distance: 30) && H.outcome(distance: 30, velocity: 0, armed: true) == .cancel, "膠囊：停住後又拉回去＝取消（中途反悔）")   // l10n-ignore
        check(H.shouldArm(distance: 80, sinceMove: 0.3) && !H.shouldArm(distance: 80, sinceMove: 0.1) && !H.shouldArm(distance: 40, sinceMove: 1),
              "膠囊：要拉夠遠、又停夠久，才算停住")   // l10n-ignore
        let t = 10.0
        check(abs(H.velocity([(t, 0), (t + 0.05, 40), (t + 0.1, 80)], now: t + 0.1) - 800) < 1e-6, "膠囊：釋放速度＝位移÷時間")   // l10n-ignore
        check(H.velocity([(t, 0), (t + 0.05, 40)], now: t + 0.3) == 0, "膠囊：停住才放手＝沒有速度")   // l10n-ignore
        // 跟手：卡片隨距離縮小、停住縮到切換器卡片
        check(H.cardScale(0, armed: false) == 1 && H.cardScale(200, armed: false) < H.cardScale(100, armed: false) && H.cardScale(5000, armed: false) == 0.5,
              "膠囊：卡片拉越遠越小，有下限")   // l10n-ignore
        check(H.cardScale(80, armed: true) == AppSwitcher.cardScale, "膠囊：停住時卡片縮成切換器卡片的大小")   // l10n-ignore
        // CarPlay 上的位置：整顆在外圈 80 px 帶內
        let cap = H.carPlayCapsule(inset: 80), band = H.bandHeight(inset: 80)
        check(cap.minY > 0 && cap.maxY < band && abs(cap.midX - 512) < 0.01 && abs(band - 80 * 1024 / 1088) < 0.01,
              "膠囊：CarPlay 上整顆收在安全區外圈（80 px）裡，不蓋 CarPlay 內容")   // l10n-ignore
        check(abs(cap.width / cap.height - 208 / 62) < 0.01, "膠囊：CarPlay 上的比例跟頂端藥丸一樣（只是縮小）")   // l10n-ignore
        // 歸屬：CarPlay 上只有膠囊那條帶歸外殼
        let inset = 80
        check(H.owner(CGPoint(x: 512, y: 30), on: .carPlay, pill: nil, inset: inset) == .indicator, "歸屬：CarPlay 上按在膠囊＝外殼")   // l10n-ignore
        check(H.owner(CGPoint(x: 512, y: 200), on: .carPlay, pill: nil, inset: inset) == .carPlay
              && H.owner(CGPoint(x: 900, y: 30), on: .carPlay, pill: nil, inset: inset) == .carPlay
              && H.owner(CGPoint(x: 100, y: 30), on: .carPlay, pill: nil, inset: inset) == .carPlay,
              "歸屬：CarPlay 上帶外、帶的兩端（含右上角）全部給 iPhone")   // l10n-ignore
        check(H.owner(CGPoint(x: 900, y: 40), on: .face, pill: nil, inset: nil) == .controlCenter
              && H.owner(CGPoint(x: 900, y: 40), on: .app, pill: Shell.pillRect(0), inset: nil) == .controlCenter, "歸屬：錶面／App 上右上角往下拉＝控制中心（不變）")   // l10n-ignore
        check(H.owner(CGPoint(x: 512, y: 60), on: .face, pill: nil, inset: nil) == .indicator
              && H.owner(CGPoint(x: 512, y: 130), on: .home, pill: LiveActivityStack.pillHit, inset: nil) == .indicator,
              "歸屬：錶面頂端中間、主畫面的藥丸＝膠囊")   // l10n-ignore
        check(H.owner(CGPoint(x: 512, y: 500), on: .face, pill: nil, inset: nil) == .shell, "歸屬：螢幕其他地方照原本的路（換頁、轉身體、點按）")   // l10n-ignore
        // 放手：拖離藥丸（沒往下拉）再放開＝取消，不是 Home 鍵；原地點照舊；拉著照距離收；長按用掉了不再做事
        check(H.releaseAction(consumed: false, claimed: false, moved: true, onCarPlay: false) == .none
              && H.releaseAction(consumed: false, claimed: false, moved: false, onCarPlay: false) == .tap
              && H.releaseAction(consumed: false, claimed: true, moved: true, onCarPlay: false) == .settle
              && H.releaseAction(consumed: true, claimed: false, moved: false, onCarPlay: false) == .none
              && H.releaseAction(consumed: false, claimed: false, moved: false, onCarPlay: true) == .tap
              && H.releaseAction(consumed: false, claimed: false, moved: true, onCarPlay: true) == .none,
              "膠囊：按住拖離再放開＝取消（不算 Home 鍵）；原地點才是 Home 鍵（CarPlay 上也是）；往下拉照舊收")   // l10n-ignore
        // 開始拉：CarPlay 收不到背景（交接凍結）就不開始，導覽不動
        check(!H.pullBegins(surface: .carPlay, demo: false, backgrounded: false) && H.pullBegins(surface: .carPlay, demo: false, backgrounded: true)
              && H.pullBegins(surface: .carPlay, demo: true, backgrounded: false) && H.pullBegins(surface: .app, demo: false, backgrounded: false),
              "膠囊：CarPlay 收不到背景（交接凍結）就不開始拉，畫面與導覽一致")   // l10n-ignore
    }
}
