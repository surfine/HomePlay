// 2.0 閒置裝置·網頁串流：裝置上的手指 → 外殼（ShellInput），和個人內容的門。
//
// 觸控（按下／移動／放開，0–1024 畫布座標）照真的滑鼠一樣走 ShellInput 的入口（uv 直接給，不經 3D 投影）：
// 控制中心跟手、底緣往上、點圖示、長按，全部同一套邏輯。外殼不認的手勢（ShellInput 要「重播給原本的處理」時）
// 不交給桌寵原本的滑鼠處理（那會轉 Mac 上的機身、搶走焦點），改由這裡當觸控螢幕解讀：
// 左右滑＝換頁（錶面、主畫面），App 裡上下滑＝捲動，錶面上點頂端藥丸＝Live Activity。

import AppKit

enum RemoteInput {
    /// 正在送裝置的觸控：ShellInput 的重播看到這個就不交回原本的處理
    nonisolated(unsafe) static var injecting = false
    /// 外殼放手了（要重播）：這一筆改由這裡解讀
    nonisolated(unsafe) static var released = false
    /// 正在處理的這一下來自訪客裝置（主執行緒；RemoteServer.input 在 handle 前後設定）：
    /// 家庭寫入、ClioTalk 的「好」、打開設定視窗看到這個就拒絕（H3、M3）
    nonisolated(unsafe) static var fromGuest = false
    /// 這一下是哪條連線送的；按下的那條才能移動、放開（兩台裝置不共用一個手勢，訪客不能替主人的按下放開）
    nonisolated(unsafe) static var source: ObjectIdentifier?
    nonisolated(unsafe) static var downSource: ObjectIdentifier?, touchAt = 0.0

    enum Mode { case none, primer, clio, people, shell, own }
    nonisolated(unsafe) static var mode = Mode.none
    nonisolated(unsafe) static var start = CGPoint.zero, last = CGPoint.zero, downAt = 0.0

    static func handle(_ kind: String, _ p: CGPoint, view: PetView) { view.remoteTouch(kind, p) }

    /// 手指在畫布上移動多少 → 視窗點（y 往上）：螢幕約佔視窗高的六成，拉半個螢幕＝控制中心全開（同 ccDragSpan）
    static func windowPoint(_ p: CGPoint, in v: NSView) -> NSPoint {
        let k = max(80, v.bounds.height) * 0.6 / 1024
        let base = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        return NSPoint(x: base.x + (p.x - start.x) * k, y: base.y - (p.y - start.y) * k)
    }

    static func event(_ t: NSEvent.EventType, _ p: CGPoint, in v: NSView) -> NSEvent? {
        guard let w = v.window else { return nil }
        return NSEvent.mouseEvent(with: t, location: windowPoint(p, in: v), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// 外殼要把這一下重播給原本的處理：裝置來的不重播（回 true＝已接手）
    static func interceptReplay() -> Bool {
        guard injecting else { return false }
        released = true
        return true
    }
}

extension PetView {
    func remoteTouch(_ k: String, _ p: CGPoint) {
        let R = RemoteInput.self
        guard !showingVideo, !carVideo.active else { return }   // CarPlay 畫面是 iPhone 的：裝置上不能點
        wakeFromPosterForGuide()
        remoteActivity()
        let uv = CGPoint(x: p.x / 1024, y: p.y / 1024), now = CACurrentMediaTime()
        func inject(_ t: NSEvent.EventType) -> Bool {
            guard let e = R.event(t, p, in: self) else { return false }
            R.injecting = true; ShellInput.uvOverride = uv
            defer { R.injecting = false; ShellInput.uvOverride = nil }
            switch t {
            case .leftMouseDown: return shellMouseDown(e, uv: uv)
            case .leftMouseDragged: return shellMouseDragged(e, uv: uv)
            default: return shellMouseUp(e, uv: uv)
            }
        }
        // 手勢屬於按下的那條連線：別台的移動、放開不算；別台在手勢中途按下也不算
        // （那台斷線、2 秒沒動靜＝手勢作廢，別台可以接手）
        let stale = now - R.touchAt > 2
        if k == "d" {
            if R.mode != .none, R.downSource != nil, R.downSource != R.source, !stale { return }
            R.downSource = R.source
        } else if R.downSource != R.source { return }
        R.touchAt = now
        switch k {
        case "d":
            R.start = p; R.last = p; R.downAt = now; R.released = false
            // 訪客不能按權限卡（會在 Mac 上跳系統權限）、錄臉、ClioTalk（「好」會替主人送出訊息／開門）：吃掉這一下
            if R.fromGuest && (PermissionPrimer.visible || PeopleOverlay.capturesClicks || ClioTalkPanel.visible) { R.mode = .none }
            else if PermissionPrimer.visible { _ = PermissionPrimer.press(x: p.x, y: p.y); R.mode = .primer }
            else if PeopleOverlay.capturesClicks { _ = PeopleOverlay.press(x: p.x, y: p.y); R.mode = .people }
            else if ClioTalkPanel.visible { ClioTalkPanel.press(x: p.x, y: p.y); R.mode = .clio }
            else { R.mode = inject(.leftMouseDown) && !R.released ? .shell : .own }
            face.forceDirty = true
        case "m":
            defer { R.last = p }
            switch R.mode {
            case .shell:
                _ = inject(.leftMouseDragged)
                if R.released { R.mode = .own }
            case .own:
                // App 裡上下滑＝捲動（1:1 跟手）
                if case .app = Shell.nav.screen, Shell.nav.overlay == .none, let a = Shell.currentApp, !PersonalGate.locks(a.id),
                   abs(p.y - R.start.y) > abs(p.x - R.start.x), a.handleScroll(p.y - R.last.y, now: now) { face.forceDirty = true }
            default: break
            }
        case "u":
            let mode = R.mode
            R.mode = .none
            R.downSource = nil
            switch mode {
            case .primer: if PermissionPrimer.tracking { PermissionPrimer.release(x: p.x, y: p.y) }
            case .clio: if ClioTalkPanel.tracking { ClioTalkPanel.release(x: p.x, y: p.y) }
            case .shell:
                R.released = false
                _ = inject(.leftMouseUp)
                if R.released { remoteOwnGesture(p, now: now) }   // 錶面上點邊緣：外殼要重播的那種點按
            case .own: remoteOwnGesture(p, now: now)
            case .people, .none: break
            }
            face.forceDirty = true
        default: break
        }
    }

    /// 外殼不認的手勢：當觸控螢幕解讀
    private func remoteOwnGesture(_ p: CGPoint, now: Double) {
        let R = RemoteInput.self
        let dx = p.x - R.start.x, dy = p.y - R.start.y
        if hypot(dx, dy) < 24 {
            guard Shell.nav.screen == .face, Shell.nav.overlay == .none else { return }
            _ = LiveActivityStack.tap(R.start, long: now - R.downAt > 0.5, now: now, face: face,
                                      open: { a in LiveActivityStack.open(a) { self.shellOpenApp($0) } })
            return
        }
        guard abs(dx) > 80, abs(dx) > abs(dy) * 1.3, Shell.nav.overlay == .none else { return }
        let dir = dx < 0 ? 1 : -1   // 往左滑＝下一頁
        switch Shell.nav.screen {
        case .face:
            if Shell.lockFace { return }
            if !shellNavigate(.page(dir)) { setFaceStyle(face.style.next(dir)) }
        case .home, .library: shellNavigate(.page(dir))
        case .app: break
        }
    }
}

// MARK: - 個人內容的門

enum RemotePrivacy {
    /// 訪客裝置最近一次點的時間：一分鐘內點過＝訪客正在用，PersonalGate 關門（Mac 上也一樣顯示訪客版）。
    /// RemoteServer 的佇列一收到就寫（鎖保護），主執行緒每幀的 shellStep 讀得到，不會把剛關的門又開回去
    private static let guestLock = NSLock()
    nonisolated(unsafe) private static var _guestInputAt = -1e9
    static var guestInputAt: Double {
        get { guestLock.withLock { _guestInputAt } }
        set { guestLock.withLock { _guestInputAt = newValue } }
    }
    static var guestActive: Bool { CACurrentMediaTime() - guestInputAt < Shell.idleTimeout }

    /// 訪客碰了一下（主執行緒）：門立刻關，相片小工具的觀眾立刻換成 none（不等下一幀的 shellStep）
    static func guestTouched(_ now: Double) {
        guestInputAt = now
        PersonalGate.cached = false
        if PersonalGate.cachedAudience != .none {
            PersonalGate.cachedAudience = .none
            PhotosWidgetSource.shared.reset(); SharedAlbumFeed.shared.reset()
        }
    }

    /// 訪客裝置看得到的 App——允許清單（H2；AppRegistry 真的 id，selftest 對過）。只放畫面上沒有主人個人資料的：
    /// 計時器、世界時鐘、鬧鐘、天氣。不放的理由：music／podcasts（資料庫、最近播放、訂閱）、safari（書籤、紀錄、食譜）、
    /// home、intercom（配件、攝影機、門鎖）、findmy（家人位置）、calendar／reminders／messages／facetime（個人內容）、
    /// cliotalk（之前的回答、資料卡）、settings（在 Mac 上開設定視窗）、recipes（Safari 裡）。
    static let guestApps: Set<String> = ["timers", "worldclock", "alarms", "weather"]
    /// 部分給訪客的 App（使用者 2026-10-25）：家庭只有燈（HomeApp.guestView）；音樂只有「正在播放」（歌名、歌手、封面、歌詞、控制），
    /// 資料庫、待播、AirPlay 與其他面板不給
    static let guestPartialApps: Set<String> = ["home", "music"]
    static let guestMusicPanels: [NowPlayingPage.Panel] = [.none, .lyrics]

    /// 訪客在用時，Mac 上也鎖起來（「需要主人」、不收點按）的 App：清單外的全部
    static func guestLocks(_ appID: String) -> Bool { !guestApps.contains(appID) && !guestPartialApps.contains(appID) && !guestMediaApps.contains(appID) }
    /// 2.0 v2-music：播客也只給「正在播放」那一頁
    static let guestMediaApps: Set<String> = ["music", "podcasts"]

    /// 訪客看得到的錶面——也是允許清單（FaceStyle 的 rawValue）。不放：photos（照片）、modular／pocket（下一個行程、正在播放）、
    /// homeModular（門鎖、溫控）；之後新加的錶面預設不給
    static let guestFaces: Set<String> = ["island", "analog", "flow", "weather", "calendar", "embossed", "growth", "black", "bedside", "system6", "alarmClock", "about"]

    struct Screen: Equatable {
        var gateOpen = true
        var screen = ShellScreen.face
        var overlayClio = false
        var photoFace = false          // 照片錶面、島用照片當背景（主畫面的桌布也是從錶面拍的）
        var personalActivity = false   // 訊息、FaceTime 的 Live Activity（有聯絡人名字）
        var peopleSheet = false
        var peopleOverlay = false      // 「嗨，某某」問候、錄臉引導（有名字）
        var face = "island"            // FaceStyle.rawValue
        var musicNowPlaying = false    // 音樂停在「正在播放」、沒開待播／AirPlay 之類的面板、沒有換頁過場
        var homeGuestView = false      // 家庭畫的是訪客版（只有燈）
        var mediaNowPlaying = false    // 2.0 v2-music：音樂／播客正顯示「正在播放」（沒開待播、「…」）
    }

    /// 這一幀可以給訪客裝置看嗎（純函數，selftest 驗）
    static func guestSafe(_ s: Screen) -> Bool {
        if s.photoFace && [.face, .home, .library].contains(s.screen) { return false }
        if s.personalActivity || s.peopleSheet || s.peopleOverlay { return false }
        if s.overlayClio { return false }          // ClioTalk 的卡片（之前的回答、資料卡）：門開不開都不給
        switch s.screen {
        case .face: return guestFaces.contains(s.face)   // 錶面也是允許清單（Modular 的行程磚、Home Modular 的門鎖不給）
        case .home, .library: return !s.gateOpen  // 門開著：下一個行程、照片、頭像；門關著畫的是訪客版
        case .app("music"): return s.musicNowPlaying
        case .app("home"): return s.homeGuestView
        case .app("podcasts"): return s.mediaNowPlaying   // 2.0 v2-music
        case .app(let id): return guestApps.contains(id)   // 允許清單，不是排除清單
        }
    }

    static func screen(_ f: Face, now: Double) -> Screen {
        Screen(gateOpen: PersonalGate.allowed, screen: Shell.nav.screen,
               overlayClio: Shell.nav.overlay == .clioTalk || ClioTalkPanel.visible,
               photoFace: f.style == .photos || (f.style == .island && f.background == .photo),
               personalActivity: ["messages", "facetime"].contains { AppRegistry.app($0)?.liveActivity(face: f, now: now) != nil },
               peopleSheet: Shell.peopleSheet, peopleOverlay: PeopleOverlay.visible, face: f.style.rawValue,
               musicNowPlaying: musicNowPlaying, homeGuestView: HomeApp.guestView,
               mediaNowPlaying: NowPlayingPage.shared.guestViewable(app: Shell.currentApp, face: f))
    }

    static var musicNowPlaying: Bool {
        guard let m = AppRegistry.app("music") as? MusicApp, m.page == .nowPlaying, !m.transitioning else { return false }
        let np = NowPlayingPage.shared
        return guestMusicPanels.contains(np.panel) && !np.panelTransitioning
    }

    static func guestSafe(_ v: PetView?) -> Bool {
        guard let v else { return true }
        return guestSafe(screen(v.face, now: CACurrentMediaTime()))
    }

    // MARK: H1：每一幀畫的時候就判定

    /// 有裝置連著（主執行緒；RemoteServer 設）。沒連著＝render 的鉤子什麼都不做
    nonisolated(unsafe) static var tracking = false
    nonisolated(unsafe) static var ledger = Ledger()
    nonisolated(unsafe) private static var judged: (frame: CGImage, safe: Bool)?

    /// 判定帳本（純邏輯，selftest 驗）：
    /// - 這一幀畫的時候狀態不安全＝不安全，而且記下「舊畫面裡可能有個人內容」；
    /// - 狀態安全、但正在跑拿舊畫面做的過場（換錶面、接管、App 收起來）而舊畫面可能不安全＝還是不安全；
    /// - 沒有過場、狀態安全地畫完一幀：舊畫面乾淨了。
    /// 另外記不安全的最後一幀編號：只有比它新的幀才可能安全（tick 取樣的那條路也守這條）。
    struct Ledger: Equatable {
        var tainted = false
        var barrier = -1
        mutating func judge(render n: Int, safeNow: Bool, usesOldFrame: Bool) -> Bool {
            if !safeNow { tainted = true; barrier = max(barrier, n); return false }
            if n <= barrier { return false }
            if usesOldFrame { return !tainted }
            tainted = false
            return true
        }
    }

    /// Face.render 畫完時叫（main.swift 一行）：只管 RemoteServer.shared 的那張臉
    static func noteRender(_ f: Face, _ frame: CGImage) {
        guard tracking, let v = RemoteServer.shared.view, v.face === f else { return }
        let safeNow = guestSafe(screen(f, now: CACurrentMediaTime()))
        let old = f.faceTransition != nil || Shell.takeover != nil || Shell.appMorph != nil
        judged = (frame, ledger.judge(render: Face.renderCount, safeNow: safeNow, usesOldFrame: old))
    }

    /// 這張圖是不是判定過、而且安全（沒判定過的一律不安全）
    static func verdict(_ img: CGImage) -> Bool {
        guard let j = judged, j.frame === img else { return false }
        return j.safe
    }
}
