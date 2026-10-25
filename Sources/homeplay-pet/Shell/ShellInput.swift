// 2.0 外殼的輸入：main.swift 的 PetView 滑鼠／滾輪／鍵盤各在開頭一行呼叫這裡（回 true＝外殼吃掉了）。
//
// 原本的手勢一律不變：拖機身＝轉、雙擊＝回正、長按螢幕＝錶面總覽、重按＝CarPlay、⌘拖＝搬視窗；CarPlay 畫面在時全部交回原本的路。
// 外殼只認這幾種，而且先「暫時接住」，確定不是自己的就把按下那一下原封不動重播給原本的處理（轉身體、點膠囊、System 6…）：
// - 螢幕右上角往下拖＝控制中心；頂端中間往下拖＝ClioTalk；螢幕底緣往上拖＝往上（錶面→主畫面→全部 App；App 裡＝回上一層）；
// - 主畫面、App 上的點按歸外殼（點圖示、點頂端藥丸、點 App 裡的按鈕）；在這些畫面上拖動仍是轉身體；
// - 滾輪：錶面頭尾再滾一格到主畫面、主畫面滾動換頁；← →、↑（主畫面）、↓／Esc（回上一層）、C（控制中心）。

import AppKit

enum ShellInput {
    enum Kind: Equatable { case tap, edgeTop(cc: Bool), edgeBottom, cc(slider: ControlCenter.Tile?), clio }
    nonisolated(unsafe) static var passThrough = false
    nonisolated(unsafe) static var replayed = false
    nonisolated(unsafe) static var claimed = false
    nonisolated(unsafe) static var down: (event: NSEvent, uv: CGPoint?, kind: Kind, at: NSPoint)?
    static let slop: CGFloat = 5, trigger: CGFloat = 18
    /// 自檢腳本用：直接指定點在螢幕哪裡（見 runShellScript）
    nonisolated(unsafe) static var uvOverride: CGPoint?
    /// 2.0 R14：控制中心跟手——拖曳的最近兩個取樣（時間、進度），放手時算速度
    nonisolated(unsafe) static var ccSamples: [(t: Double, p: CGFloat)] = []
    nonisolated(unsafe) static var ccDragFrom: CGFloat = 0
    /// 2.0 P10（HV-SPECS-65）：這次打開 ClioTalk 是從頂端往下滑——直接開始聽（不先出文字框）
    nonisolated(unsafe) static var swipeListen = false
    /// 動效包：拖曳中這一幀手指在螢幕上的 uv（控制中心 1:1 跟手）
    nonisolated(unsafe) static var dragUV: CGPoint?
}

extension PetView {
    private var faceIndex: Int { FaceStyle.lineup.firstIndex(of: face.style.inLineup) ?? 0 }
    private var shellBlocked: Bool { showingVideo || carVideo.active }

    // MARK: 導覽（狀態機 + 過場）

    @discardableResult
    func shellNavigate(_ e: ShellNav.Event) -> Bool {
        let now = CACurrentMediaTime()
        // 2.0: 「換人」先收；App 自己能退一層（對話頁 → 列表、收確認卡）就交給它
        if e == .back, Shell.peopleSheet { Shell.peopleSheet = false; face.forceDirty = true; return true }
        if e == .back, LiveActivityStack.collapse(now) { face.forceDirty = true; return true }   // 2.0 P03：展開的大卡先收
        if e == .back, Shell.nav.overlay == .controlCenter, ControlCenter.back(now: now) { face.forceDirty = true; return true }   // 2.0 cc：先收圖庫、大卡、編輯模式
        if e == .back, Shell.nav.overlay == .none, let a = Shell.currentApp, !PersonalGate.locks(a.id), a.handleBack(now: now) {
            face.forceDirty = true; return true
        }
        let before = Shell.nav
        let r = Shell.nav.handle(e, faceIndex: faceIndex, faceCount: FaceStyle.lineup.count)
        guard r.handled else { return false }
        if case .page(let d) = e { Face.pageDirOverride = d }   // 2.0 R14：主畫面 ↔ 頭尾錶面也是分頁滑動
        Shell.peopleSheet = false
        // ClioTalk 這一層＝ClioTalkPanel 那張卡（ClioTalk/ClioTalkPanel.swift）
        if before.overlay != .clioTalk, Shell.nav.overlay == .clioTalk {
            if ShellInput.swipeListen { ClioTalkController.shared.listenFromSwipe(from: self) } else { ClioTalkController.shared.open(from: self) }   // 2.0 P10
        }
        if before.overlay == .clioTalk, Shell.nav.overlay != .clioTalk { ClioTalkController.shared.dismissFromShell() }
        if before.screen != Shell.nav.screen {
            if case .app(let id) = before.screen, Shell.nav.screen == .home || Shell.nav.screen == .library,
               let rect = shellItemRect(id, on: Shell.nav.screen) {
                Shell.beginMorph(rect: rect, id: id, opening: false, now: now)   // App 縮回它的圖示（開到一半也從當下的大小縮回去）
            } else if r.face == nil {
                if before.screen == .face {
                    Shell.homeHue = Shell.hue(fromFace: face.lastFrame, face: face)
                    Shell.captureHomeBackdrop(face.lastFrame)    // 2.0 R3：主畫面桌布＝剛才的錶面
                    if let ir = face.islandRect {                // 眼睛膠囊縮成頂端藥丸
                        let ch = ir.height / 1.9, cw = max(ch, ir.width - 1.2 * ch)
                        Shell.pillFrom = (CGRect(x: ir.midX - cw / 2, y: ir.midY - ch / 2, width: cw, height: ch), now)
                    }
                }
                Face.toFaceDeblur = Shell.nav.screen == .face    // 動效包：回錶面＝照片從模糊變清楚（v1 1:20.94）
                face.beginFaceTransition()                       // 跟換錶面同一種霧化過場
            }
            if case .app(let id) = Shell.nav.screen { AppRegistry.app(id)?.didOpen(now: now) }
        }
        if before.overlay != Shell.nav.overlay, Shell.nav.overlay == .controlCenter {
            Shell.ccBackdrop = nil
            ControlCenter.volume = SystemVolume.get() ?? ControlCenter.volume
            ControlCenter.willOpen()   // 2.0 cc：眼前這個人的版面、第一頁
        }
        if let f = r.face {
            if FaceStyle.lineup[f] == face.style.inLineup { face.beginFaceTransition() }   // 同一個錶面：setFaceStyle 不會過場，自己滑
            setFaceStyle(FaceStyle.lineup[f])
        }
        Face.pageDirOverride = nil
        face.forceDirty = true
        log("shell \(e) → \(Shell.nav.screen) \(Shell.nav.overlay)")
        return true
    }

    private func shellItemRect(_ id: String, on screen: ShellScreen) -> CGRect? {
        if let o = Shell.openedFrom, o.id == id, o.screen == screen { return o.rect }   // 動效包：從哪裡開就縮回哪裡
        let items = screen == .library ? Shell.libraryItems() : Shell.homeItems()
        if let hit = items.first(where: { $0.1 == .app(id) }) { return hit.0 }
        if id == "calendar" { return items.first { $0.1 == .upNext }?.0 }
        if id == "weather" { return items.first { $0.1 == .weather }?.0 }          // 動效包：小工具開的 App 也有地方縮回去
        if id == "worldclock" { return items.first { $0.1 == .worldClock }?.0 }
        return nil
    }

    /// 打開 App；from＝從哪個圖示長出來（主畫面上點的）
    func shellOpenApp(_ id: String, from rect: CGRect? = nil) {
        guard let app = AppRegistry.app(id) else { return }
        if app.launch(face: face) { log("shell launch \(id)"); return }   // 設定：開原本的視窗
        let before = Shell.nav.screen
        if let rect, before == .home || before == .library {
            _ = Shell.nav.handle(.openApp(id), faceIndex: faceIndex, faceCount: FaceStyle.lineup.count)
            Shell.openedFrom = (id, rect, before)   // 動效包
            app.didOpen(now: CACurrentMediaTime())
            Shell.beginMorph(rect: rect, id: id, opening: true, now: CACurrentMediaTime())
            face.forceDirty = true
            log("shell open \(id)")
        } else {
            shellNavigate(.openApp(id))
        }
    }

    // MARK: 每幀（step 裡一行）

    func shellStep(_ now: Double) {
        if mood.near || forceNear { Shell.lastActive = now }
        let gate = PersonalGate.allowed
        if gate != PersonalGate.cached, face.style == .modular { face.forceDirty = true }   // 2.0 depth：模組錶面的「下一個行程」跟著門開關
        PersonalGate.cached = gate   // ClioTalk 的引擎在背景讀
        let aud = PersonalGate.audience   // 2.0：共享相簿給家人看；觀眾一變，小工具與錶面的相片來源重挑（不留上一位的照片）
        if aud != PersonalGate.cachedAudience { PersonalGate.cachedAudience = aud; PhotosWidgetSource.shared.reset(); SharedAlbumFeed.shared.reset() }
        // ClioTalk 從 F5、右鍵打開或自己收起：外殼這一層跟著它
        let clioOpen = ClioTalkController.shared.isOpen
        if clioOpen, Shell.nav.overlay != .clioTalk { Shell.nav.overlay = .clioTalk; face.forceDirty = true }
        if !clioOpen, Shell.nav.overlay == .clioTalk { Shell.nav.overlay = .none; face.forceDirty = true }
        ControlCenter.followOn = gazeEnabled || PersonalGate.viewerOverride != nil   // 2.0 P09 快照：--looking 模擬認人開著（不然鎖定頁會先說「打開跟隨我」）
        ControlCenter.carPlayOn = [.live, .paused, .pausedResume, .background].contains(face.status)
        let open = Shell.nav.screen != .face || Shell.nav.overlay != .none
        // CarPlay 畫面優先：直播一來，外殼全部收回
        if shellBlocked, open { shellNavigate(.carPlay); return }
        // 遠距：沒人靠近一分鐘，主畫面與 App 淡回錶面
        if open, now - Shell.lastActive > Shell.idleTimeout { shellNavigate(.idle); PersonalGate.hint = nil; Shell.homeEditing = false; Shell.widgetGallery = false }   // P02：回錶面就離開編輯模式
        if face.style != Shell.lastStyle { Shell.lastStyle = face.style; Shell.lastPageAt = now }
    }

    // MARK: 滑鼠

    private func shellPoint(_ uv: CGPoint?) -> CGPoint? { uv.map { CGPoint(x: $0.x * 1024, y: $0.y * 1024) } }

    func shellMouseDown(_ e: NSEvent, uv uv0: CGPoint?) -> Bool {
        let S = ShellInput.self, uv = S.uvOverride ?? uv0
        if S.passThrough { return false }
        S.replayed = false; S.claimed = false; S.down = nil
        guard !shellBlocked, !face.onboardingActive, !face.inOverview, !PermissionPrimer.visible else { return false }
        Shell.lastActive = CACurrentMediaTime()
        let at = e.locationInWindow
        switch Shell.nav.overlay {
        case .controlCenter:
            let slider = ccPress(shellPoint(uv))   // 2.0 cc：滑桿、按下、編輯模式拖曳（Shell/ControlCenter/CCInput.swift）
            S.down = (e, uv, .cc(slider: slider), at); return true
        case .clioTalk:
            S.down = (e, uv, .clio, at); return true
        case .none: break
        }
        if face.bannerShowing { return false }                                  // 點一下收起橫幅：照舊
        if sbMouseDown(e, uv: uv) { return true }   // 2.0 SpringBoard：按在主畫面的圖示／小工具／空白（長按、拖曳、換頁；Shell/SpringBoard/SBInput.swift）
        guard let uv, e.clickCount == 1, !e.modifierFlags.contains(.command) else { return false }   // 雙擊、⌘拖照舊
        let kind: ShellInput.Kind?
        if uv.y < 0.13 && uv.x > 0.70 { kind = .edgeTop(cc: true) }
        else if uv.y < 0.12 && uv.x > 0.32 && uv.x < 0.68 { kind = .edgeTop(cc: false) }
        else if uv.y > 0.90 && uv.x > 0.2 && uv.x < 0.8 { kind = .edgeBottom }
        else if Shell.nav.screen.coversFace { kind = .tap }
        else { kind = nil }
        facePageArm(e, uv: uv)   // 2.0：錶面上螢幕裡橫拖＝跟手換頁（Shell/FacePaging.swift）；邊緣手勢與轉身體照舊
        guard let kind else { return false }
        S.down = (e, uv, kind, at)
        if kind == .tap, let p = shellPoint(uv) { HPGlass.pressDown(p); face.forceDirty = true }   // 2.0 R14：按下那一刻就變亮放大
        return true
    }

    func shellMouseDragged(_ e: NSEvent, uv uv0: CGPoint?) -> Bool {
        let S = ShellInput.self, uv = S.uvOverride ?? uv0
        S.dragUV = uv   // 動效包
        if S.passThrough || S.replayed { return false }
        if SBInputState.press != nil { return sbMouseDragged(e, uv: uv) }   // 2.0 SpringBoard
        if FacePaging.drag != nil, facePageDragged(e) { return true }        // 2.0：錶面跟手換頁（直向交回下面原本的路）
        guard let d = S.down else { return false }
        Shell.lastActive = CACurrentMediaTime()
        let dx = e.locationInWindow.x - d.at.x, dy = e.locationInWindow.y - d.at.y   // 視窗座標：y 往上
        switch d.kind {
        case .cc(let slider):
            if ccDragged(slider, shellPoint(uv), dx: dx, dy: dy) { return true }   // 2.0 cc
            // 2.0 R14：往上推收起——1:1 跟手
            if S.claimed || (hypot(dx, dy) > ShellInput.slop && dy > 0 && abs(dy) > abs(dx)) {
                if !S.claimed { S.claimed = true; HPGlass.pressUp(); ccBeginDrag() }
                ccTrack(1 - dy / ccDragSpan)
            } else if HPGlass.pressOver(hypot(dx, dy) < ShellInput.slop) {   // 2.0 live glass：拖出取消——不是往上推但拖超過 slop：收掉按壓，回到 slop 內再亮
                face.forceDirty = true
            }
            return true
        case .clio:
            if let p = shellPoint(uv), ClioTalkPanel.drag(x: p.x, y: p.y) { face.forceDirty = true }   // 2.0 live glass：拖出取消
            return true
        case .tap, .edgeTop, .edgeBottom:
            if S.claimed {
                if case .edgeTop(true) = d.kind { ccTrack(-dy / ccDragSpan) }   // 2.0 R14：控制中心 1:1 跟著往下拉
                if case .edgeTop(false) = d.kind, -dy > ShellInput.trigger { shellSwipeListen() }   // 2.0 P10：拉過門檻就開始聽，不等放手
                return true
            }
            if hypot(dx, dy) < ShellInput.slop { return true }
            HPGlass.pressUp(); face.forceDirty = true
            let vertical = abs(dy) > abs(dx) * 1.2
            switch d.kind {
            case .edgeTop where vertical && dy < 0, .edgeBottom where vertical && dy > 0:
                S.claimed = true
                if case .edgeTop(true) = d.kind { ccBeginDrag(); ccTrack(-dy / ccDragSpan) }
                return true
            default:
                if FacePaging.drag != nil, Shell.nav.screen == .face { return true }   // 2.0：錶面上先等 10 pt 決定是不是橫拖換頁
                shellReplayDown(d.event); return false              // 不是外殼的手勢：交回去轉身體
            }
        }
    }

    func shellMouseUp(_ e: NSEvent, uv _: CGPoint?) -> Bool {   // 點按看按下那一點（d.uv），放手的位置只用來算拖了多遠
        let S = ShellInput.self
        if S.passThrough { return false }
        if S.replayed { S.replayed = false; return false }
        if SBInputState.press != nil { return sbMouseUp(e, uv: nil) }   // 放手的位置用最後一次拖到的點
        if FacePaging.drag != nil, facePageRelease(now: CACurrentMediaTime()) { ShellInput.down = nil; return true }   // 2.0：錶面跟手換頁
        FacePaging.drag = nil   // 2.0 SpringBoard
        guard let d = S.down else { return false }
        S.down = nil
        let claimed = S.claimed; S.claimed = false
        let dx = e.locationInWindow.x - d.at.x, dy = e.locationInWindow.y - d.at.y
        HPGlass.pressUp(); face.forceDirty = true
        switch d.kind {
        case .cc(let slider):
            if ccReleased(slider, at: shellPoint(d.uv), moved: hypot(dx, dy) > 10, claimed: claimed) { return true }   // 2.0 cc
            if claimed { ccEndDrag(); return true }                    // 2.0 R14：放手照投射落點決定收不收
            if hypot(dx, dy) > 10 {
                if dy > ShellInput.trigger { shellNavigate(.back) }    // 往上推收起
                return true
            }
            if let p = shellPoint(d.uv) { ccTap(p) } else { shellNavigate(.back) }
            return true
        case .clio:
            shellNavigate(.back); return true
        case .edgeTop(let cc):
            if claimed, cc { ccEndDrag(); return true }
            if claimed { if -dy > ShellInput.trigger { shellSwipeListen() }; return true }
        case .edgeBottom:
            if claimed {
                if dy > ShellInput.trigger {
                    if case .app = Shell.nav.screen { shellNavigate(.back) } else { shellNavigate(.up) }
                }
                return true
            }
        case .tap: break
        }
        // 沒拖：點按
        if Shell.nav.screen.coversFace { shellTap(d.uv, long: e.timestamp - d.event.timestamp > 0.5); return true }   // 2.0: 按住 0.5 秒以上＝長按（家庭 App 調亮度）
        shellReplayClick(d.event, e)                                     // 錶面上點邊緣：照原本的點按（膠囊、System 6…）
        return true
    }

    /// 2.0 P10（HV-SPECS-65）：頂端中間往下滑＝ClioTalk 立刻開始聽（👀 膠囊直接變成聆聽的水滴，照錶面年代）；已經開著就不重來
    private func shellSwipeListen() {
        guard Shell.nav.overlay != .clioTalk else { return }
        ShellInput.swipeListen = true
        shellNavigate(.openClioTalk)
        ShellInput.swipeListen = false
    }

    private func shellReplayDown(_ ev: NSEvent) {
        let S = ShellInput.self
        S.down = nil; S.claimed = false
        if RemoteInput.interceptReplay() { return }   // 2.0 idle: 裝置來的觸控不交給轉身體（Remote/RemoteInput.swift）
        S.passThrough = true; mouseDown(with: ev); S.passThrough = false
        S.replayed = true
    }
    private func shellReplayClick(_ down: NSEvent, _ up: NSEvent) {
        let S = ShellInput.self
        if RemoteInput.interceptReplay() { return }   // 2.0 idle: 同上
        S.passThrough = true; mouseDown(with: down); mouseUp(with: up); S.passThrough = false
        S.replayed = false
    }

    /// 主畫面／App 上的點按
    func shellTap(_ uv: CGPoint?, long: Bool = false) {   // 2.0 P05：輔助使用的「按下」也走這裡（Shell/ShellAccessibility.swift）
        if TimerChime.ringing { TimerChime.stop() }   // 2.0 depth：計時器在響：點哪裡都先停聲音（點到的東西照常）
        guard let p = shellPoint(uv) else { return }
        if let m = Shell.appMorph {
            // 2.0 R14：開到一半又按返回：從當下的大小縮回去（不等它播完）
            if m.opening, Shell.closeButton.insetBy(dx: -8, dy: -8).contains(p) { shellNavigate(.back) }
            return
        }
        let now = CACurrentMediaTime()
        // 2.0: 「換人」：點一個人＝提示（認人開著時由認人決定）；點卡外收起
        if Shell.peopleSheet {
            if let id = Shell.peopleSheetRows.first(where: { $0.1.contains(p) })?.0 {
                PersonalGate.hint = PeopleRegistry.shared.person(id)?.isOwner == true ? nil : id
                log("shell people hint")
            } else if Shell.sheetCard.contains(p) { return }
            Shell.peopleSheet = false; face.forceDirty = true
            return
        }
        // 頂端藥丸：點＝打開那件事（深連結）、按住＝展開大卡、大卡外面點一下＝收回（2.0 P03，Shell/LiveActivityStack.swift）
        if LiveActivityStack.tap(p, long: long, now: now, face: face, open: { a in LiveActivityStack.open(a) { shellOpenApp($0) } }) {
            face.forceDirty = true; return
        }
        switch Shell.nav.screen {
        case .home, .library:
            if sbTap(p, long: long) { return }   // 2.0 SpringBoard：編輯模式、選單、sheet、資料夾、App 資料庫（取代 P02 的 homeEditTap）
            if Shell.avatarRect.insetBy(dx: -10, dy: -10).contains(p) { Shell.peopleSheet = true; face.forceDirty = true; return }
            let items = Shell.nav.screen == .library ? Shell.libraryItems() : Shell.homeItems()
            guard let (r, item) = items.first(where: { $0.0.contains(p) }) else { return }
            switch item {
            case .app(let id): shellOpenApp(id, from: r)
            case .photos: tapPhotosWidget()   // 第六輪：沒授權＝權限卡；有照片＝換下一張
            case .upNext: shellOpenApp("calendar", from: r)
            case .weather: shellOpenApp("weather", from: r)         // P02：天氣小工具開天氣
            case .worldClock: shellOpenApp("worldclock", from: r)   // P02：世界時鐘小工具開世界時鐘
            case .sb: break                                          // 2.0 SpringBoard：sbTap 已經處理
            }
        case .app:
            let a = Shell.currentApp, locked = a.map { PersonalGate.locks($0.id) } ?? false
            if a?.showsCloseButton != false || locked, Shell.closeButton.insetBy(dx: -8, dy: -8).contains(p) { shellNavigate(.back); return }
            if let a, !locked {
                if long, a.handleLongPress(p, face: face, now: now) { face.forceDirty = true; return }
                if a.handleTap(p, face: face, now: now) { face.forceDirty = true }
            }
        case .face: break
        }
    }

    // MARK: 控制中心跟手（2.0 R14）

    /// 拉滿要多遠（視窗點）：螢幕大約佔視窗高的六成，拉過螢幕一半＝全開
    private var ccDragSpan: CGFloat { max(80, bounds.height * 0.3) }

    private func ccBeginDrag() {
        Shell.ccDragging = true
        ShellInput.ccSamples = []
        ShellInput.ccDragFrom = Shell.ccT
        Shell.lastActive = CACurrentMediaTime()
    }
    /// p：手指帶到的進度（0 關 … 1 開）；超過頭用 rubber band
    private func ccTrack(_ p: CGFloat) {
        let now = CACurrentMediaTime()
        var x = p
        // 動效包：有螢幕上的手指位置就照它算（內容位移＝手指位移，HPMotion.T.ccTravel），沒有才用視窗點估
        if let u = ShellInput.dragUV, let d0 = ShellInput.down?.uv { x = ShellInput.ccDragFrom + (u.y - d0.y) * 1024 / HPMotion.T.ccTravel }
        if x > 1 { x = 1 + HPMotion.rubberBand(x - 1, 1) } else if x < 0 { x = HPMotion.rubberBand(x, 1) }
        Shell.ccT = max(0, x)
        ShellInput.ccSamples.append((now, x))
        if ShellInput.ccSamples.count > 4 { ShellInput.ccSamples.removeFirst() }
        face.forceDirty = true
    }
    /// 放手：速度交給彈簧，落點照 Apple 的投射挑最近的停點（開／關）
    private func ccEndDrag() {
        let now = CACurrentMediaTime()
        let sm = ShellInput.ccSamples
        var v: CGFloat = 0
        if let a = sm.first, let b = sm.last, b.t - a.t > 0.004 { v = (b.p - a.p) / CGFloat(b.t - a.t) }
        if let b = sm.last, now - b.t > 0.08 { v = 0 }   // 停住才放：沒有速度
        let goal = HPMotion.nearest(Shell.ccT, velocity: v, stops: [0, 1])
        Shell.ccDragging = false
        Shell.ccAnim = MotionValue("cc", spring: HPMotion.release(velocity: v * HPMotion.T.ccTravel), from: Shell.ccT, to: goal, velocity: v, now: now)   // 動效包：有動量才 0.8
        if goal == 1, Shell.nav.overlay != .controlCenter { shellNavigate(.openControlCenter) }
        if goal == 0, Shell.nav.overlay == .controlCenter { shellNavigate(.back) }
        // shellNavigate 不動 ccAnim（tick 看到 to 已經是目標就不重設）
        face.forceDirty = true
    }

    // MARK: 控制中心

    func shellActivate(_ t: ControlCenter.Tile) {   // 2.0 P05：輔助使用的「按下」也走這裡；2.0 cc：動作在 Shell/ControlCenter/CCInput.swift
        ccActivate(t)
    }

    // MARK: 滾輪、鍵盤、選單

    func shellScroll(_ e: NSEvent, uv: CGPoint?) -> Bool {
        guard !shellBlocked else { return false }
        let now = CACurrentMediaTime()
        Shell.lastActive = now
        let precise = e.hasPreciseScrollingDeltas
        switch Shell.nav.overlay {
        case .controlCenter:
            return ccScroll(e, shellPoint(uv))   // 2.0 cc：滑桿上調、圖庫捲、其他換頁
        case .clioTalk: return true
        case .none: break
        }
        if e.modifierFlags.contains(.option) { return false }            // ⌥＋滾輪＝縮放：照舊
        let dir = e.scrollingDeltaY > 0 ? -1 : (e.scrollingDeltaY < 0 ? 1 : 0)   // 跟原本滾輪換錶面同向
        switch Shell.nav.screen {
        case .app:
            if let a = Shell.currentApp, !PersonalGate.locks(a.id), a.handleScroll(precise ? e.scrollingDeltaY : e.scrollingDeltaY * 10, now: now) { face.forceDirty = true; return true }
            return !precise
        case .home, .library:
            if sbScroll(e, uv: uv) { return true }                        // 2.0 SpringBoard：主畫面的頁、Smart Stack、圖庫
            guard !precise else { return false }                          // 觸控板兩指＝轉身體
            if dir != 0, now - Shell.lastPageAt > 0.25 { Shell.lastPageAt = now; shellNavigate(.page(dir)) }
            return true
        case .face:
            if facePageScroll(e, uv: uv) { return true }   // 2.0：觸控板兩指橫滑＝跟手換錶面
            guard !precise, dir != 0 else { return false }
            if Shell.lockFace { return true }                             // 鎖定錶面：不換
            let last = FaceStyle.lineup.count - 1
            guard dir > 0 && faceIndex >= last || dir < 0 && faceIndex <= 0 else { return false }
            if now - Shell.lastPageAt > 0.25 { Shell.lastPageAt = now; shellNavigate(.page(dir)) }
            return true
        }
    }

    func shellKeyDown(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), e.keyCode == 9, !shellBlocked, recipePaste() { return true }   // 2.0: 食譜 App 裡 ⌘V 貼上網址
        guard !shellBlocked, !e.modifierFlags.contains(.command), !PermissionPrimer.active, !face.onboardingActive else { return false }
        Shell.lastActive = CACurrentMediaTime()
        if sbKeyDown(e) { return true }   // 2.0 SpringBoard：編輯模式搬圖示、App 資料庫打字搜尋、資料夾改名
        if shellFocusKeyDown(e) { return true }   // 2.0 P05：鍵盤操作畫面（方向鍵移焦點、Return 打開；Shell/ShellAccessibility.swift）
        switch e.keyCode {
        case 53: return e.isARepeat ? Shell.nav.screen.coversFace : shellNavigate(.back)   // Esc
        case 125: return shellNavigate(.back)                                                // ↓
        case 126: return shellNavigate(.up)                                                  // ↑
        case 8: return shellNavigate(.toggleControlCenter)                                   // C
        case 123, 124:
            let dir = e.keyCode == 124 ? 1 : -1
            if Shell.nav.overlay != .none { return true }
            switch Shell.nav.screen {
            case .face:
                if Shell.lockFace { return true }
                let last = FaceStyle.lineup.count - 1
                guard dir > 0 && faceIndex >= last || dir < 0 && faceIndex <= 0 else { return false }
                return shellNavigate(.page(dir))
            case .home: return shellNavigate(.page(dir))
            case .library, .app: return true
            }
        default: return false
        }
    }

    @objc func menuShellHome() {
        wakeFromPosterForGuide()
        Shell.lastActive = CACurrentMediaTime()
        if Shell.nav.screen == .face { shellNavigate(.up) } else { shellNavigate(.back) }
    }
    @objc func menuShellControlCenter() {
        wakeFromPosterForGuide()
        Shell.lastActive = CACurrentMediaTime()
        shellNavigate(.toggleControlCenter)
    }

    // MARK: 快照旗標（AppDelegate 開機時一行呼叫）

    /// --home、--app <id>、--control-center、--live-activity timer|message|cliotalk、--demo-timers、--guest（訪客模式）、--people-sheet
    func applyShellSnapshotFlags() {
        let args = CommandLine.arguments
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if !HPMotion.freezes.isEmpty { face.faceTransition = nil }   // 凍結動畫的快照：開機那次換錶面的過場不要混進來
        if args.contains("--guest") { Shell.guestMode = true }
        // 2.0 P03：--live-activity 可以逗號分隔好幾個（timer,music,call,message,cliotalk）；--live-activity-expanded <其一> 停在大卡
        let expandedDemo = arg("--live-activity-expanded")
        let la = Set((arg("--live-activity") ?? "").split(separator: ",").map(String.init) + (expandedDemo.map { [$0] } ?? []))
        if la.contains("message") { MessagesApp.shared.demoIncoming() }
        if la.contains("cliotalk") { ClioTalkApp.demoActivity = true }
        LiveActivityStack.applyDemo(la, face: face)
        if let k = expandedDemo { LiveActivityStack.applyExpandedDemo(k) }
        let demo = args.contains("--demo-timers")
        if demo || la.contains("timer") {
            Shell.timers.add(seconds: 272, label: L("shell.demo.pasta", "意大利面"), now: TimersApp.wallNow)
            if demo { Shell.timers.add(seconds: 665, label: L("shell.demo.sauce", "酱汁"), now: TimersApp.wallNow) }
            Shell.reconcileTimers(face, now: CACurrentMediaTime())
        }
        if OfficialDemo.on, !demo, arg("--app") == "timers" {   // 官方 timer：15 分鐘、剩 10:56（只在計時器 App；其他畫面的官方圖沒有計時）
            Shell.timers.add(seconds: OfficialDemo.timerLeft + OfficialDemo.timerSlack, label: String(format: L("timer.minutes", "%d 分钟"), 15),
                             now: TimersApp.wallNow, total: OfficialDemo.timerTotal)
            Shell.reconcileTimers(face, now: CACurrentMediaTime())
        }
        let wantsHome = args.contains("--home") || args.contains("--guest") || args.contains("--library") || expandedDemo != nil, app = arg("--app")
        if wantsHome || app != nil {
            face.faceTransition = nil   // 第五輪：開機那次換錶面的過場不要拍進桌布（不然拍到的是預設的島）
            let shot = face.render()
            Shell.homeHue = Shell.hue(fromFace: shot, face: face)   // 桌布色相跟著這次的錶面
            Shell.captureHomeBackdrop(shot)                          // 2.0 R3：桌布＝這次的錶面（模糊、壓暗）
            if HPMotion.frozen("takeover") != nil { Shell.beginTakeover(face) }   // 2.0 R11 快照：從錶面接管過來
            Shell.nav.screen = .home
            if app == "cliotalk" { Shell.nav.overlay = .clioTalk }                // ClioTalk 是蓋在主畫面上的一層
            else if let app, let a = AppRegistry.app(app) { Shell.nav.screen = .app(app); a.didOpen(now: CACurrentMediaTime()) }
            if args.contains("--library") { Shell.nav.screen = .library }   // 快照用：全部 App
            if args.contains("--people-sheet") { Shell.peopleSheet = true }
            if app != nil, AppRegistry.app(app!) == nil { log("--app 只认：\(AppRegistry.all.map(\.id).joined(separator: " "))") }
            Shell.pillT = face.shellActivity(CACurrentMediaTime()) == nil ? 0 : 1
        }
        Shell.applyMediaDemoFlags(face: face)   // 2.0: --demo-music [页]、--demo-recipe [屏]
        recipeRegisterDrag()                     // 2.0: 把食譜網址拖到桌寵上
        if args.contains("--control-center") { Shell.nav.overlay = .controlCenter; Shell.ccT = 1; Shell.ccAnim = MotionValue("cc", spring: .smooth, from: 1, to: 1, now: 0) }
        ControlCenter.applySnapshotFlags()   // 2.0 cc：--cc-expand／--cc-edit／--cc-gallery／--cc-page／--cc-slide
        // 快照：HOMEPLAY_SHELL_MORPH=timers[:open|close]，時間用 HOMEPLAY_ANIM=appopen:0.08（或 appclose:…）凍結
        if let spec = ProcessInfo.processInfo.environment["HOMEPLAY_SHELL_MORPH"]?.split(separator: ":"), !spec.isEmpty,
           let rect = shellItemRect(String(spec[0]), on: .home) {
            let opening = !spec.contains("close")
            if Shell.homeHue == nil { let shot = face.render(); Shell.homeHue = Shell.hue(fromFace: shot, face: face); Shell.captureHomeBackdrop(shot) }
            Shell.nav.screen = opening ? .app(String(spec[0])) : .home; Shell.nav.appReturn = .home
            Shell.appMorph = nil
            Shell.beginMorph(rect: rect, id: String(spec[0]), opening: opening, now: CACurrentMediaTime())
        }
        // 快照：HOMEPLAY_PRESS=x,y（1024 座標）＋HOMEPLAY_ANIM=press:0.1＝按著那一點的樣子
        if let ps = ProcessInfo.processInfo.environment["HOMEPLAY_PRESS"]?.split(separator: ",").compactMap({ Double($0) }), ps.count == 2 {
            HPGlass.pressDown(CGPoint(x: ps[0], y: ps[1]))
        }
        // 快照：HOMEPLAY_ANIM=facepage:0.1 → 從目前的錶面往下一個滑到第 t 秒
        if HPMotion.frozen("facepage") != nil, Shell.nav.screen == .face {
            _ = face.render(); Face.pagePrev = face.style.inLineup
            setFaceStyle(face.style.next(1), remember: false)
        }
        // 快照：HOMEPLAY_ANIM=cc:0.1 → 控制中心從關著拉開到第 t 秒
        if HPMotion.frozen("cc") != nil { Shell.nav.overlay = .controlCenter; Shell.ccAnim = MotionValue("cc", spring: .smooth, from: 0, to: 1, now: CACurrentMediaTime()) }
        Shell.lastActive = CACurrentMediaTime() + 3600   // 快照不要中途回錶面
        face.forceDirty = true
        applySBSnapshotFlags()   // 2.0 SpringBoard：--home-page、--home-menu、--home-folder、--home-gallery、--home-drag…
        if let script = ProcessInfo.processInfo.environment["HOMEPLAY_SHELL_SCRIPT"] { runShellScript(script) }
    }

    /// 自檢用：照腳本送假的滑鼠／鍵盤／滾輪事件走真的 PetView 入口（uv 直接給，不經 3D 投影），每步記一行日誌。
    /// HOMEPLAY_SHELL_SCRIPT="key:126;tap:0.3,0.25;drag:0.85,0.05,0,-40;wheel:-1"（tap/drag 的 x,y 是螢幕 uv；drag 的 dx,dy 是視窗點、y 往上）
    private func runShellScript(_ script: String) {
        let steps = script.split(separator: ";").map(String.init)
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(i) * 0.7) { [weak self] in
                guard let self, let win = self.window else { return }
                let parts = step.split(separator: ":"), op = parts.first.map(String.init) ?? ""
                let nums = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
                let base = NSPoint(x: self.bounds.midX, y: self.bounds.midY)
                func mouse(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                    NSEvent.mouseEvent(with: t, location: self.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                switch op {
                case "tap" where nums.count == 2, "drag" where nums.count == 4:
                    ShellInput.uvOverride = CGPoint(x: nums[0], y: nums[1])
                    if let d = mouse(.leftMouseDown, base) { self.mouseDown(with: d) }
                    let dx = nums.count == 4 ? nums[2] : 0, dy = nums.count == 4 ? nums[3] : 0
                    if op == "drag" {
                        for k in 1...4 { if let e = mouse(.leftMouseDragged, NSPoint(x: base.x + dx * Double(k) / 4, y: base.y + dy * Double(k) / 4)) { self.mouseDragged(with: e) } }
                    }
                    if let u = mouse(.leftMouseUp, NSPoint(x: base.x + dx, y: base.y + dy)) { self.mouseUp(with: u) }
                    ShellInput.uvOverride = nil
                case "key" where nums.count == 1:
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: win.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                isARepeat: false, keyCode: UInt16(nums[0])) { self.keyDown(with: e) }
                case "wheel" where nums.count == 1:
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(nums[0]), wheel2: 0, wheel3: 0),
                       let e = NSEvent(cgEvent: cg) { self.scrollWheel(with: e) }
                default: log("shell script: bad step \(step)")
                }
                log("shell script \(step) → \(Shell.nav.screen) \(Shell.nav.overlay) face=\(self.face.style.rawValue) timers=\(Shell.timers.timers.count)")
            }
        }
    }
}

extension Shell {
    nonisolated(unsafe) static var lastStyle: FaceStyle?
}
