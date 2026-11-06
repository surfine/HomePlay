// 2.0 外殼的輸入：main.swift 的 PetView 滑鼠／滾輪／鍵盤各在開頭一行呼叫這裡（回 true＝外殼吃掉了）。
//
// 原本的手勢一律不變：拖機身＝轉、雙擊＝回正、長按螢幕＝錶面總覽、重按＝CarPlay、⌘拖＝搬視窗。
// 外殼只認這幾種，而且先「暫時接住」，確定不是自己的就把按下那一下原封不動重播給原本的處理（轉身體、點膠囊、System 6…）。
//
// 手勢總表（2026-11-06 拍板：👀 膠囊兼任 Home Indicator，判定與歸屬在 Shell/HomeIndicator.swift）
// | 區域                         | 錶面                     | 主畫面／切換器            | App                        | CarPlay 畫面               |
// |------------------------------|--------------------------|---------------------------|----------------------------|----------------------------|
// | 👀 膠囊（頂端中間、藥丸）     | 下拉＝主畫面；拉住停＝切換器；點＝照舊；長按＝ClioTalk | 拉住停＝切換器（資料庫、切換器下拉＝主畫面）；點＝Home 鍵／動態；長按＝ClioTalk（有動態時＝展開） | 下拉＝主畫面；拉住停＝切換器；點＝Home 鍵；長按同左 | 外圈帶上的膠囊：下拉＝主畫面（會話留背景）；拉住停＝切換器；長按＝ClioTalk；點＝Home 鍵（回主畫面，會話留背景） |
// | 右上角往下拉                 | 控制中心                 | 控制中心                  | 控制中心                   | 給 iPhone（不變：CarPlay 上沒有控制中心手勢） |
// | 底緣往上拉                   | 主畫面                   | 全部 App                  | （只做往上導覽）           | 給 iPhone                  |
// | 左緣右滑／內容左側右滑       | 同中間起手：橫拖換錶面（錶面是最上層，沒有返回） | 主畫面：第一頁往右翻過頭＝回錶面（其他頁＝換頁）；切換器：沒有（同 iOS，點空白回主畫面） | 返回 | 給 iPhone |
// | 其他點按                     | 交回原本的路（膠囊播放、System 6…） | 圖示、小工具、卡片 | App 自己的按鈕             | 給 iPhone                  |
// | 其他拖動                     | 橫拖換錶面；其他轉身體   | 換頁（第一頁往右＝回錶面）／捲卡片、卡片上滑拿掉 | 轉身體       | 給 iPhone                  |
// 優先序：AirDrop 卡片 → 疊層（控制中心、ClioTalk）→ 膠囊 → 控制中心角 → 底緣／左緣 → 畫面自己 → 轉身體。
// 一個手勢從起手到放手只歸一個層級：膠囊一接住，CarPlay、轉身體、換頁都拿不到這一下。
// - 滾輪：錶面頭尾再滾一格到主畫面、主畫面滾動換頁、切換器左右捲。
//
// 鍵盤（2026-11-07 拍板，整套）
// | 鍵            | 錶面／主畫面／App／切換器（外殼）                         | CarPlay 畫面（＝車上旋鈕，CarPlayKnobKeys） |
// |---------------|-----------------------------------------------------------|---------------------------------------------|
// | 空白鍵        | 👀：叫 CarPlay（背景叫回、沒連上去連、訪客＝需要主人）；焦點框顯示時＝按下焦點 | 👀：回主畫面（會話留背景）      |
// | ← →           | 換頁（錶面頭尾到主畫面）；「鍵盤導航」開著時叫出焦點框、移焦點 | 搖桿左右（x），按住照鍵重複             |
// | ↑ ↓           | ↑ 主畫面／資源庫、↓ 回上一層；「鍵盤導航」開著時叫出焦點框、移焦點 | 搖桿上下（y），按住照鍵重複         |
// | Tab／⇧Tab     | 叫出焦點框、換焦點（設定「鍵盤導航」開著）                | 轉動（wheel ±1），按住照鍵重複              |
// | Return        | 打開焦點項目                                              | 選取（按下再放開）                          |
// | Esc           | 收掉焦點框、回上一層                                      | 返回                                        |
// | C             | 控制中心                                                  | —                                           |
// 資源庫搜尋時打字的空白照舊是文字。焦點框只由 Tab 或方向鍵叫出（ShellAccessibility.summonsFocus），空白鍵不叫。
// 離開 CarPlay（👀 下拉、空白鍵、選單「退出 CarPlay」、重按）一律落在主畫面、會話留背景（PetView.carPlayToHome）。
//
// 輸入方式（觸控 Mac 與觸控 Sidecar，macOS 27；Shell/TouchInput.swift、docs/plans/touch.md）
// | 動作                     | 滑鼠                         | 觸控板                         | 觸控（手指）                                        |
// |--------------------------|------------------------------|--------------------------------|-----------------------------------------------------|
// | 點、打開                 | 點一下                       | 點一下                         | 點一下（判定區外擴到 44 pt，重疊時中心最近的勝）    |
// | 螢幕上直向捲（清單等）   | 滾輪                         | 兩指上下滑                     | 單指上下拖（帶慣性）                                |
// | 換頁（錶面、主畫面、資源庫）| 橫拖、滾輪               | 兩指橫滑                       | 單指橫拖（同一套跟手、橡皮筋、速度判定）            |
// | 螢幕上的其他拖動         | 轉身體                       | —                              | 歸外殼（不轉身體）                                  |
// | 轉身體                   | 拖機身／拖螢幕               | 兩指滑（機身上）               | 單指拖機身；兩指拖機身                              |
// | 長按（圖示選單、總覽、編輯模式拖圖示）| 按住            | 按住                           | 按住；按住再拖＝拖圖示                              |
// | 右鍵選單                 | 右鍵                         | 兩指點                         | 機身上按住                                          |
// | 縮放桌寵                 | ⌥＋滾輪、選單                | 捏合                           | 兩指捏合（同時只認捏合或兩指拖其中一個）            |
// | 拆開／組回               | 選單                         | 兩指輕點兩下                   | 選單（機身上按住）                                  |
// | 回正                     | 雙擊機身                     | 雙擊機身                       | 點兩下機身                                          |
// | 返回（左緣、內容左側右滑）| 拖                          | 拖                             | 滑（系統設定關掉「滑動切換頁面」時不做）            |
// | 搬視窗                   | ⌘拖、拖底座                  | 三指拖                         | 拖底座                                              |
// | 懸停才有的               | 零件標籤、靠近亮起、影片控制列 | 同滑鼠                        | 點零件釘住標籤；碰過＝靠近；碰一下浮出控制列        |
// | 👀 眼神                  | 看游標                       | 看游標                         | 按著看手指，放開 1 秒後回到平常                     |
// | CarPlay                  | 點、拖送 iPhone              | 兩指拖送 iPhone                | 單指點、拖送 iPhone（兩指：實驗旗標，預設關）       |

import AppKit

enum ShellInput {
    enum Kind: Equatable { case tap, edgeTop(cc: Bool), edgeBottom, edgeLeft, contentBack, cc(slider: ControlCenter.Tile?), clio, indicator, switcher }
    nonisolated(unsafe) static var passThrough = false
    nonisolated(unsafe) static var replayed = false
    nonisolated(unsafe) static var claimed = false
    nonisolated(unsafe) static var down: (event: NSEvent, uv: CGPoint?, kind: Kind, at: NSPoint)?
    static let slop: CGFloat = 5, trigger: CGFloat = 18
    /// 自檢腳本用：直接指定點在螢幕哪裡（見 runShellScript）
    nonisolated(unsafe) static var uvOverride: CGPoint?
    /// 2.0 R14：控制中心跟手——拖曳的最近兩個取樣（時間、進度），放手時算速度
    nonisolated(unsafe) static var ccSamples: [(t: Double, p: CGFloat)] = []
    /// HomeView 對齊：返回手勢的拖動取樣（時間、x），放手算釋放速度
    nonisolated(unsafe) static var backSamples: [(t: Double, x: CGFloat)] = []
    nonisolated(unsafe) static var ccDragFrom: CGFloat = 0
    /// 2.0 P10（HV-SPECS-65）：這次打開 ClioTalk 是從頂端往下滑——直接開始聽（不先出文字框）
    nonisolated(unsafe) static var swipeListen = false
    /// 動效包：拖曳中這一幀手指在螢幕上的 uv（控制中心 1:1 跟手）
    nonisolated(unsafe) static var dragUV: CGPoint?
    /// 切換器：拖動鎖定的方向（0 未定、1 橫捲、2 卡片上滑、3 空白處）、起手時的捲動量、橫捲取樣
    nonisolated(unsafe) static var switcherAxis = 0
    nonisolated(unsafe) static var switcherScroll0: CGFloat = 0
    nonisolated(unsafe) static var switcherSamples: [(t: Double, x: CGFloat)] = []

    /// 新的一下開始：上一下的按下、接住、重播旗標都清掉。回 true＝上一下的錶面換頁還掛著（重播交回、早退的路沒收到）——
    /// 不收的話，之後在控制中心橫拖會換掉後面的錶面、在 CarPlay 上放手被換頁吃掉（iPhone 那邊手指一直按著）
    static func beginPress() -> Bool {
        replayed = false; claimed = false; down = nil
        return FacePaging.drag != nil
    }

    /// 按下歸哪一種（純邏輯，自檢直接驗）：膠囊、控制中心角先；切換器整面是它自己的（同 iOS：切換器上沒有左緣返回）；
    /// 再來底緣、左緣、App 內容左側；錶面上其他地方＝nil（交回原本的路）
    static func kind(owner: HomeIndicator.Owner, screen: ShellScreen, uv: CGPoint, backAllowed: Bool) -> Kind? {
        if owner == .controlCenter { return .edgeTop(cc: true) }
        if owner == .indicator { return .indicator }   // 👀 膠囊：下拉回主畫面、拉住停一下切換器、長按 ClioTalk
        if screen == .switcher { return .switcher }     // 切換器：卡片橫捲、上滑拿掉、點按
        if uv.y > 0.90 && uv.x > 0.2 && uv.x < 0.8 { return .edgeBottom }
        // HomeView 對齊 WP4：螢幕邊緣右滑＝返回。錶面是最上層、沒有返回可去（2026-11-07）：左緣起手跟中間一樣交給錶面換頁
        if uv.x < 0.09 && uv.y > 0.18 && uv.y < 0.86, backAllowed, screen != .face { return .edgeLeft }
        if screen.coversFace { return uv.x < 0.25 && backAllowed ? .contentBack : .tap }  // HomeView 對齊 WP4：App 內容區左側右滑＝返回
        return nil
    }

    /// 重按（Force Touch）碰上外殼的手勢：拖到一半＝不理（不在手勢中間進出 CarPlay）；按著還沒動＝先把這一下安靜收掉再照舊進出
    enum ForcePress: Equatable { case ignore, cancelPressThenEnter, enter }
    static func forcePress(dragging: Bool, pressing: Bool) -> ForcePress {
        dragging ? .ignore : (pressing ? .cancelPressThenEnter : .enter)
    }

    /// 手勢中途被取消（兩指接手、系統收走觸控、重按）：哪幾種進行中的拖動要走自己的收尾
    enum CancelStep: Equatable { case indicator, facePage, springBoard, controlCenter, switcher }
    static func cancelSteps(kind: Kind?, claimed: Bool, indicatorPulling: Bool, facePaging: Bool, sbPressing: Bool, ccDragging: Bool) -> [CancelStep] {
        var s: [CancelStep] = []
        if indicatorPulling { s.append(.indicator) }   // 卡片彈回；起手在 CarPlay＝彈回後叫回直播
        if facePaging { s.append(.facePage) }          // 換上來一半的錶面退回去
        if sbPressing { s.append(.springBoard) }       // 換頁、資料庫捲動回到最近一頁、拖著的圖示放下
        switch kind {
        case .cc: s.append(.controlCenter)             // 滑桿放開、編輯放下、往上推一半的照落點收
        case .edgeTop(cc: true) where claimed || ccDragging: s.append(.controlCenter)
        case .switcher where claimed: s.append(.switcher)
        default: if ccDragging { s.append(.controlCenter) }
        }
        return s
    }
}

extension PetView {
    private var faceIndex: Int { FaceStyle.lineup.firstIndex(of: face.style.inLineup) ?? 0 }
    var shellBlocked: Bool { showingVideo || carVideo.active }

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
            if case .app(let id) = before.screen, id != CarPlayApp.id, let shot = face.lastFrame { AppSwitcher.shots[id] = shot }   // 切換器卡片：離開時的最後一格
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
            if case .app(let id) = Shell.nav.screen { AppRegistry.app(id)?.didOpen(now: now); AppSwitcher.note(id) }
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

    func shellItemRect(_ id: String, on screen: ShellScreen) -> CGRect? {
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
        let locked = PersonalGate.locks(id)   // 2026-11-07：CarPlay 與 iPhone App 也在門後——鎖著就照常打開「需要主人」那一頁，不跳 CarPlay
        if !locked, app.launch(face: face) { log("shell launch \(id)"); return }   // 設定：開原本的視窗；iPhone App：跳到 CarPlay 開它
        let before = Shell.nav.screen
        if id == CarPlayApp.id, !locked { CarPlayApp.shared.pendingFront = true }   // 過場走完把直播叫到前面（shellStep）
        AppSwitcher.note(id)
        if let rect, before == .home || before == .library || before == .switcher {
            _ = Shell.nav.handle(.openApp(id), faceIndex: faceIndex, faceCount: FaceStyle.lineup.count)
            Shell.openedFrom = before == .switcher ? nil : (id, rect, before)   // 動效包（切換器開的：關掉時縮回主畫面的圖示）
            app.didOpen(now: CACurrentMediaTime())
            Shell.beginMorph(rect: rect, id: id, opening: true, now: CACurrentMediaTime())
            face.forceDirty = true
            log("shell open \(id)")
        } else {
            shellNavigate(.openApp(id))
        }
    }

    /// 外殼以外的入口（空白鍵、選單、F5、控制中心、來自 App 的「到 CarPlay」）叫一個 App：照主畫面點圖示的路打開——
    /// 鎖著的就是它那一頁「需要主人」（在主畫面、資源庫上從圖示長出來）
    func shellOpenFromAnywhere(_ id: String) {
        let s = Shell.nav.screen
        Shell.lastActive = CACurrentMediaTime()
        shellOpenApp(id, from: s == .home || s == .library ? shellItemRect(id, on: s) : nil)
    }

    // MARK: 每幀（step 裡一行）

    func shellStep(_ now: Double) {
        if mood.near || forceNear { Shell.lastActive = now }
        let gate = PersonalGate.allowed
        if gate != PersonalGate.cached, face.style == .modular { face.forceDirty = true }   // 2.0 depth：模組錶面的「下一個行程」跟著門開關
        if let card = (NSApp.delegate as? AppDelegate)?.callCard.model, card.hidden == gate { card.hidden = !gate }   // 來電卡響著時門開關：名字跟著藏／露
        PersonalGate.cached = gate   // ClioTalk 的引擎在背景讀
        let aud = PersonalGate.audience   // 2.0：共享相簿給家人看；觀眾一變，小工具與錶面的相片來源重挑（不留上一位的照片）
        if aud != PersonalGate.cachedAudience { PersonalGate.cachedAudience = aud; PhotosWidgetSource.shared.reset(); SharedAlbumFeed.shared.reset() }
        if FamilyProfiles.refresh() { face.forceDirty = true }   // 2.0 家人檔案：目前這位家人換了（Look、主畫面跟著換）
        // ClioTalk 從 F5、右鍵打開或自己收起：外殼這一層跟著它
        let clioOpen = ClioTalkController.shared.isOpen
        if clioOpen, Shell.nav.overlay != .clioTalk { Shell.nav.overlay = .clioTalk; face.forceDirty = true }
        if !clioOpen, Shell.nav.overlay == .clioTalk { Shell.nav.overlay = .none; face.forceDirty = true }
        ControlCenter.followOn = gazeEnabled || PersonalGate.viewerOverride != nil   // 2.0 P09 快照：--looking 模擬認人開著（不然鎖定頁會先說「打開跟隨我」）
        ControlCenter.carPlayOn = [.live, .paused, .pausedResume, .background].contains(face.status)
        let open = Shell.nav.screen != .face || Shell.nav.overlay != .none
        indicatorStep(now); indicatorSettleStep(now)   // 👀 膠囊：拉住停一下、放手後的卡片（Shell/HomeIndicator.swift）
        // CarPlay 畫面優先：直播一來，外殼的疊層收掉、CarPlay App 在前面；膠囊疊在畫面頂端那條帶（CarPlayChrome.swift）
        if shellBlocked {
            if !carVideo.active, Shell.nav.screen != .app(CarPlayApp.id) || Shell.nav.overlay != .none { shellNavigate(.carPlay) }
            if showingVideo, !carVideo.active, CarPlayChrome.shared.update(face: face, now: now, device: CarPlayChrome.device),
               now - lastVideoFrameAt > 0.05, let t = CarPlayChrome.shared.reapply() { model.setScreen(texture: t) }   // 畫面靜止時膠囊眨眼也要看得到
            return
        }
        // CarPlay App 從外殼打開（圖示、切換器）：長大的過場走完才把直播叫到前面（會話在背景就立刻有畫面，沒連上就去連）
        if case .app(CarPlayApp.id) = Shell.nav.screen, CarPlayApp.shared.pendingFront, Shell.appMorph == nil, HomeIndicator.pull == nil, HomeIndicator.settle == nil {
            CarPlayApp.shared.pendingFront = false
            if !CarPlayDemo.active, !PersonalGate.locks(CarPlayApp.id) { (NSApp.delegate as? AppDelegate)?.carPlayToFrontForShell() }   // 過場中門關了：留在「需要主人」
        }
        // 2.0 home-3：遠看（Shell/FarGlance.swift）——App 有一句話、人在遠處 8 秒沒碰就換成它；正在進行的事（ongoing）不回錶面
        var farOngoing = false
        if case .app = Shell.nav.screen, Shell.nav.overlay == .none, Shell.appMorph == nil, let a = Shell.currentApp, !PersonalGate.locks(a.id) {
            let gl = a.farGlance(face: face, now: now)
            let want = Shell.wantsFar(forced: Shell.forceFar, snapshot: SnapshotPrivacy.active, reveal: face.reveal, idle: now - Shell.lastActive, hasGlance: gl != nil)
            if want != Shell.far { Shell.far = want; face.forceDirty = true }
            farOngoing = want && gl?.ongoing == true
        } else if Shell.far { Shell.far = false; face.forceDirty = true }
        // 遠距：沒人靠近一分鐘，主畫面與 App 淡回錶面（遠看在顯示正在進行的事時不回）
        if open, !farOngoing, now - Shell.lastActive > Shell.idleTimeout { shellNavigate(.idle); PersonalGate.hint = nil; Shell.homeEditing = false; Shell.widgetGallery = false }   // P02：回錶面就離開編輯模式
        // HomeView 對齊 WP3（Shell/DisplayStage.swift）：三段顯示——活躍 → Ambient 海報（錶面）→ 休眠（壓暗）。
        // 回錶面那一刻記 ambientSince；之後按設定（20 秒/自動/永不）入睡。被動觀察：人靠近只醒回海報，意圖輸入才回活躍。
        let stage = Shell.displayStage(now: now, face: face, near: mood.near)
        if stage == .sleep {
            if Shell.ambientSince == nil { Shell.ambientSince = now }
            if !Shell.displayAsleep { Shell.displayAsleep = true; face.forceDirty = true }
        } else {
            // 海報重畫節奏：有活動卡（計時器倒數）每秒，否則每分鐘（日期/時間跳動）；
            // 後續 #6 輪播：換張的那一刻一定重畫，0.4 s 交叉淡化期間每幀
            if Shell.ambientPosterActive {
                let want = face.shellActivities(now).isEmpty ? 60.0 : 1.0
                let next = AmbientPoster.untilNextChange(face.ambientPosterKinds, elapsed: now - (Shell.ambientSince ?? now), reduceMotion: Motion.reduceMotion)
                if next == 0 { face.forceDirty = true }
                else if now - Shell.ambientRepaintAt >= want || next < 1.0 / 30 { Shell.ambientRepaintAt = now; face.forceDirty = true }
            }
            if stage == .ambient, Shell.ambientSince == nil { Shell.ambientSince = now }   // 進入海報期的起點（.idle 導覽在上面已做）
            if stage == .interactive, Shell.ambientSince != nil { Shell.ambientSince = nil }   // 意圖輸入：直接回活躍
            if Shell.displayAsleep { Shell.displayAsleep = false; face.forceDirty = true }   // 人靠近或回活躍：先把壓暗撤掉
        }
        if face.style != Shell.lastStyle { Shell.lastStyle = face.style; Shell.lastPageAt = now }
    }

    // MARK: 滑鼠

    func shellPoint(_ uv: CGPoint?) -> CGPoint? { uv.map { CGPoint(x: $0.x * 1024, y: $0.y * 1024) } }

    /// 返回滑動：觸控來的先看系統設定（使用者可以在系統設定關掉觸控的「滑動切換頁面」）；滑鼠、觸控板照舊
    var touchBackAllowed: Bool {
        guard TouchInput.synthesizing else { return true }
        if #available(macOS 27.0, *) { return TouchRoute.backSwipeAllowed(touch: true, navigationEnabled: NSEvent.isTouchSwipeNavigationEnabled) }
        return true
    }

    /// 觸控的判定區外擴：邊緣手勢區（👀 膠囊、控制中心角、底緣、左緣）不吸，免得往下拉、返回被吸到旁邊的按鈕上
    func touchSnapAllowed(uv: CGPoint) -> Bool {
        if face.onboardingActive || face.inOverview || PermissionPrimer.visible || ClioTalkPanel.visible { return false }
        if Shell.nav.overlay == .none {
            let owner = HomeIndicator.owner(CGPoint(x: uv.x * 1024, y: uv.y * 1024), on: indicatorSurface,
                                            pill: Shell.nav.screen.coversFace ? LiveActivityStack.pillHit : nil, inset: nil)
            if owner == .controlCenter || owner == .indicator { return false }
            if uv.y > 0.90 && uv.x > 0.2 && uv.x < 0.8 { return false }
            if uv.x < 0.09 && uv.y > 0.18 && uv.y < 0.86 && Shell.nav.screen.coversFace { return false }
        }
        return true
    }

    func shellMouseDown(_ e: NSEvent, uv uv0: CGPoint?) -> Bool {
        let S = ShellInput.self, uv = S.uvOverride ?? uv0
        if S.passThrough { return false }
        if S.beginPress() { facePageCancel(now: CACurrentMediaTime()) }   // 上一下沒收乾淨的換頁（重播交回、早退的路）：新的一下不繼承
        // CarPlay 畫面上：只有膠囊那條帶歸外殼，其餘照舊全部送給 iPhone（HomeIndicator.owner）
        if showingVideo, !carVideo.active {
            guard let p = shellPoint(uv), e.clickCount == 1, !e.modifierFlags.contains(.command),
                  HomeIndicator.owner(p, on: .carPlay, pill: nil, inset: HomeIndicator.inset) == .indicator else { return false }
            S.down = (e, uv, .indicator, e.locationInWindow); indicatorArm(e)
            return true
        }
        guard !shellBlocked, !face.onboardingActive, !face.inOverview, !PermissionPrimer.visible else { return false }
        if HomeIndicator.settle != nil { return true }   // 膠囊放手後的卡片還在走：不吃新觸控（同 appMorph）
        if Shell.appMorph != nil { return true }   // HomeView 對齊 WP4：開合 App 的轉場期間不吃新觸控
        Shell.lastActive = CACurrentMediaTime()
        let at = e.locationInWindow
        if airDropCardContains(uv) { AirDropCard.pressed = true; S.down = (e, uv, .tap, at); return true }   // AirDrop 卡片在最上層：按在它上面就由它吃
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
        let owner = HomeIndicator.owner(CGPoint(x: uv.x * 1024, y: uv.y * 1024), on: indicatorSurface,
                                        pill: Shell.nav.screen.coversFace ? LiveActivityStack.pillHit : nil, inset: nil)
        let kind = ShellInput.kind(owner: owner, screen: Shell.nav.screen, uv: uv, backAllowed: touchBackAllowed)
        facePageArm(e, uv: uv)   // 2.0：錶面上螢幕裡橫拖＝跟手換頁（Shell/FacePaging.swift）；邊緣手勢與轉身體照舊
        guard let kind else { return false }
        S.down = (e, uv, kind, at)
        if kind == .tap, let p = shellPoint(uv) { HPGlass.pressDown(p); face.forceDirty = true }   // 2.0 R14：按下那一刻就變亮放大
        if kind == .indicator { indicatorArm(e) }   // 長按膠囊＝ClioTalk（取代 align D 的長按藥丸兩顆切換：CarPlay 改在切換器裡）
        if kind == .switcher { S.switcherAxis = 0; S.switcherSamples = [] }
        return true
    }

    func shellMouseDragged(_ e: NSEvent, uv uv0: CGPoint?) -> Bool {
        let S = ShellInput.self, uv = S.uvOverride ?? uv0
        S.dragUV = uv   // 動效包
        if S.passThrough || S.replayed { return false }
        if AirDropCard.pressed { return true }   // 按在 AirDrop 卡片上：拖動不轉身體
        if sourceSwitcherDragged(uv: uv) { return true }   // 2.0 align D：拉開兩顆之後，拖到哪顆選哪顆
        if SBInputState.press != nil { return sbMouseDragged(e, uv: uv) }   // 2.0 SpringBoard
        if FacePaging.drag != nil {   // 2.0：錶面跟手換頁（直向交回下面原本的路）
            if S.claimed { FacePaging.drag = nil }   // 外殼已經接住這一下（膠囊下拉、控制中心）：半路轉橫也不改判成換頁
            else if facePageDragged(e) { return true }
        }
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
        case .indicator:
            let dist = indicatorDistance(e, uv: uv)
            if !S.claimed {
                if hypot(dx, dy) < ShellInput.slop { return true }
                HomeIndicator.moved = true
                if HomeIndicator.consumed { return true }
                guard dist > ShellInput.slop, abs(dy) > abs(dx) * 1.2 else {
                    // 不是往下拉：錶面上交回原本的路（轉身體）；CarPlay 上這一下已經歸膠囊，不再送給 iPhone
                    if Shell.nav.screen == .face, !showingVideo { HPGlass.pressUp(); shellReplayDown(d.event); return false }
                    return true
                }
                S.claimed = true
                if !indicatorBegin(now: CACurrentMediaTime()) { HomeIndicator.consumed = true; return true }   // CarPlay 收不到背景（交接凍結）：這一下作廢
            }
            indicatorTrack(dist, t: CACurrentMediaTime())
            return true
        case .switcher:
            HPGlass.pressUp()
            if S.switcherAxis == 0, hypot(dx, dy) >= ShellInput.slop { S.claimed = true }
            S.switcherSamples.append((e.timestamp, e.locationInWindow.x)); if S.switcherSamples.count > 6 { S.switcherSamples.removeFirst() }
            return switcherDragged(dx: dx, dy: -dy, start: shellPoint(d.uv), claimedAxis: &S.switcherAxis)
        case .tap, .edgeTop, .edgeBottom, .edgeLeft, .contentBack:
            if S.claimed {
                if case .edgeTop(true) = d.kind { ccTrack(-dy / ccDragSpan) }   // 2.0 R14：控制中心 1:1 跟著往下拉
                if case .edgeLeft = d.kind { S.backSamples.append((e.timestamp, e.locationInWindow.x)); if S.backSamples.count > 6 { S.backSamples.removeFirst(S.backSamples.count - 6) } }   // HomeView 對齊：取樣算釋放速度
                if case .contentBack = d.kind { S.backSamples.append((e.timestamp, e.locationInWindow.x)); if S.backSamples.count > 6 { S.backSamples.removeFirst(S.backSamples.count - 6) } }
                return true
            }
            if hypot(dx, dy) < ShellInput.slop { return true }
            HPGlass.pressUp(); face.forceDirty = true
            let vertical = abs(dy) > abs(dx) * 1.2
            let horizontal = dx > 0 && dx > abs(dy) * 1.2   // HomeView 對齊 WP4：往右橫拖＝返回手勢（左緣或內容區左側）
            switch d.kind {
            case .edgeTop where vertical && dy < 0, .edgeBottom where vertical && dy > 0:
                S.claimed = true
                if case .edgeTop(true) = d.kind { ccBeginDrag(); ccTrack(-dy / ccDragSpan) }
                return true
            case .edgeLeft where horizontal, .contentBack where horizontal:
                S.claimed = true; return true   // 拖動中只接住，放手指距離決定回不回
            default:
                if FacePaging.drag != nil, Shell.nav.screen == .face { return true }   // 2.0：錶面上先等 10 pt 決定是不是橫拖換頁
                shellReplayDown(d.event); return false              // 不是外殼的手勢：交回去轉身體
            }
        }
    }

    func shellMouseUp(_ e: NSEvent, uv _: CGPoint?) -> Bool {   // 點按看按下那一點（d.uv），放手的位置只用來算拖了多遠
        let S = ShellInput.self
        if S.passThrough { return false }
        if S.replayed {   // 交回原本的路的那一下：外殼這邊的換頁也一起收掉（下一下不繼承）
            S.replayed = false
            if FacePaging.drag != nil { facePageCancel(now: CACurrentMediaTime()) }
            return false
        }
        if AirDropCard.pressed {   // AirDrop 卡片：沒拖遠才算點按
            AirDropCard.pressed = false
            if let d = S.down { S.down = nil; if hypot(e.locationInWindow.x - d.at.x, e.locationInWindow.y - d.at.y) < 10 { airDropCardTap(d.uv) } }
            return true
        }
        if sourceSwitcherReleased() { return true }   // 2.0 align D
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
        case .indicator:
            // 拖離：放手時離按下的地方超過 10 pt（同 AirDrop 卡片；手指點一下的晃動不算）
            switch HomeIndicator.releaseAction(consumed: HomeIndicator.consumed, claimed: claimed, moved: hypot(dx, dy) > 10, onCarPlay: showingVideo) {
            case .none: HomeIndicator.consumed = false; return true   // 長按開了 ClioTalk、拖離藥丸再放開（取消）
            case .settle: indicatorRelease(now: CACurrentMediaTime()); return true
            case .tap:
                if showingVideo { _ = carPlayToHome(reason: "👀 tap"); return true }   // CarPlay 上點 👀＝Home 鍵（同空白鍵、往下拉）
                break
            }
        case .switcher:
            if claimed {
                let v = -BackSwipe.releaseVelocity(S.switcherSamples, now: e.timestamp) * 1024 / max(80, bounds.height * 0.6)
                let vy = -dy / max(0.001, e.timestamp - d.event.timestamp) * 1024 / max(80, bounds.height * 0.6)   // 卡片上滑：整段平均速度（往下為正）
                switcherReleased(axis: S.switcherAxis, velocity: S.switcherAxis == 2 ? vy : v, now: CACurrentMediaTime())
                S.switcherAxis = 0; S.switcherSamples = []
                return true
            }
        case .edgeTop(let cc):
            if claimed, cc { ccEndDrag(); return true }
            if claimed { return true }
        case .edgeBottom:
            if claimed {
                if dy > ShellInput.trigger {
                    // 拍板（2026-11-05）：App 內返回只走官方兩種（左緣右滑／內容左滑）——底緣上滑只做「往上」導覽
                    shellNavigate(.up)
                }
                return true
            }
        case .edgeLeft:   // HomeView 對齊 WP4：左緣右滑——距離過門檻、或快速輕掃（BackSwipe）＝返回
            if claimed {
                let v = BackSwipe.releaseVelocity(S.backSamples, now: e.timestamp)
                S.backSamples = []
                if BackSwipe.shouldBack(distance: dx, velocity: v, threshold: ShellInput.trigger) { shellNavigate(.back) }
                return true
            }
        case .contentBack:   // HomeView 對齊 WP4：App 內容左側右滑；門檻較高但輕掃同樣成立
            if claimed {
                let v = BackSwipe.releaseVelocity(S.backSamples, now: e.timestamp)
                S.backSamples = []
                if BackSwipe.shouldBack(distance: dx, velocity: v, threshold: ShellInput.trigger * 1.6) { shellNavigate(.back) }
                return true
            }
        case .tap: break
        }
        // 沒拖：點按
        if Shell.nav.screen.coversFace { shellTap(d.uv, long: e.timestamp - d.event.timestamp > 0.5); return true }   // 2.0: 按住 0.5 秒以上＝長按（家庭 App 調亮度）
        shellReplayClick(d.event, e)                                     // 錶面上點邊緣：照原本的點按（膠囊、System 6…）
        return true
    }

    /// 2.0 P10（HV-SPECS-65）：長按 👀 膠囊＝ClioTalk 立刻開始聽（膠囊直接變成聆聽的水滴，照錶面年代）；已經開著就不重來。
    /// 2026-11-06 拍板：原本是「頂端中間往下拉」，那一招改給 Home Indicator（Shell/HomeIndicator.swift）。
    /// 2.0 home-2：提醒事項、行事曆的「＋ 新增」也走這裡（HomeView 沒有鍵盤：用說的）
    func shellSwipeListen() {
        guard Shell.nav.overlay != .clioTalk else { return }
        ShellInput.swipeListen = true
        shellNavigate(.openClioTalk)
        ShellInput.swipeListen = false
    }

    func shellReplayDown(_ ev: NSEvent) {
        let S = ShellInput.self
        S.down = nil; S.claimed = false
        if FacePaging.drag != nil { facePageCancel(now: CACurrentMediaTime()) }   // 這一下交回原本的路（轉身體）：換頁不再等它
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
        if Shell.far, case .app = Shell.nav.screen { Shell.far = false; Shell.lastActive = CACurrentMediaTime(); face.forceDirty = true; return }   // 2.0 home-3：遠看時點一下＝回到近看（不穿透）
        if let m = Shell.appMorph {
            // 2.0 R14：開到一半又按返回：從當下的大小縮回去（不等它播完）；藥丸＝Home 鍵，開關 App 的過場中也能按（Esc 也不等）
            if LiveActivityStack.pillHit.contains(p) { shellHomeKey(now: CACurrentMediaTime()); return }
            if m.opening, Shell.closeButton.insetBy(dx: -8, dy: -8).contains(p) { shellNavigate(.back) }
            return
        }
        let now = CACurrentMediaTime()
        // 2.0: 「換人」：點一個人＝換成他的檔案（認人開著時由認人決定、訪客模式要先關；People/FamilyProfiles.swift）；點卡外收起
        if Shell.peopleSheet {
            if let id = Shell.peopleSheetRows.first(where: { $0.1.contains(p) })?.0 {
                FamilyProfiles.switchTo(id)
            } else if Shell.sheetCard.contains(p) { return }
            Shell.peopleSheet = false; face.forceDirty = true
            return
        }
        // 頂端藥丸＝Home 鍵（2.0 align C）：點＝回上一層（跟 Esc 同一條前置順序）、按住＝展開第一個活動、分體小藥丸點＝開它自己的活動、
        // 大卡外面點一下＝收回（Shell/LiveActivityStack.swift）
        if LiveActivityStack.tap(p, long: long, now: now, face: face, open: { a in LiveActivityStack.open(a) { shellOpenApp($0) } },
                                 home: { self.shellHomeKey(now: now) }) {
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
        case .switcher: switcherTap(p)   // 點卡片打開、點空白回主畫面（Shell/AppSwitcher.swift）
        case .face: break
        }
    }

    /// 頂端藥丸＝Home 鍵：分派一次 .back，前面先過 Esc 的那串（sheet → 選單 → 資料夾 → 疊層 → 畫面）。不做雙擊（單擊會被拖慢 250–300 ms）
    func shellHomeKey(now: Double) {
        if sbDismissTop(now: now) { face.forceDirty = true; return }
        shellNavigate(.back)
    }

    /// 手勢中途被取消（兩指接手、系統收走觸控、按著時重按）：每一種拖動走自己的收尾，回到乾淨狀態——
    /// 不當點按、不轉身體、不留按壓的亮；拉一半的膠囊彈回（起手在 CarPlay 的叫回直播）、換一半的錶面退回、
    /// 主畫面換頁回到最近一頁、控制中心照落點收。
    func shellCancelGesture() {
        let S = ShellInput.self, now = CACurrentMediaTime()
        if S.down != nil || SBInputState.press != nil { HPGlass.pressUp() }
        let d = S.down, claimed = S.claimed
        for step in ShellInput.cancelSteps(kind: d?.kind, claimed: claimed, indicatorPulling: HomeIndicator.pull != nil,
                                           facePaging: FacePaging.drag != nil, sbPressing: SBInputState.press != nil, ccDragging: Shell.ccDragging) {
            switch step {
            case .indicator: indicatorRelease(now: now, velocity: 0, forceCancel: true)
            case .facePage: facePageCancel(now: now)
            case .springBoard: sbCancelPress()
            case .controlCenter:
                if case .cc(let slider)? = d?.kind, ccReleased(slider, at: nil, moved: true, claimed: claimed) { break }
                if claimed || Shell.ccDragging { ccEndDrag() }
            case .switcher:
                if S.switcherAxis == 2 { AppSwitcher.lift?.dy = 0 }   // 上滑拿掉的卡片放回去（取消不算拿掉）
                switcherReleased(axis: S.switcherAxis, velocity: 0, now: now)
            }
        }
        S.down = nil; S.claimed = false; S.replayed = false; S.dragUV = nil
        S.backSamples = []; S.switcherAxis = 0; S.switcherSamples = []
        HomeIndicator.consumed = false; HomeIndicator.moved = false
        AirDropCard.pressed = false
        face.forceDirty = true
    }

    /// 現在是不是有外殼的手勢拖到一半（重按不在這時候進出 CarPlay）
    var shellGestureDragging: Bool {
        let S = ShellInput.self
        if S.claimed || HomeIndicator.pull != nil || HomeIndicator.settle != nil || Shell.ccDragging { return true }
        if FacePaging.drag?.axis == .horizontal { return true }
        if let pr = SBInputState.press, pr.mode != .pending { return true }
        if SB.pageDragging || SB.libraryScrollDragging || SB.drag != nil || SB.stackDrag != nil || ControlCenter.drag != nil { return true }
        if case .cc(let slider?)? = S.down?.kind, ControlCenter.sliding == slider { return true }   // 按在滑桿上＝正在調
        return false
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
        // 手勢歸屬（HIG：一個手勢從起手到結束只歸一個層級）：錶面換頁一起手就鎖給它——頭尾換到主畫面之後，
        // 剩下的拖動與放手後的慣性不能交給主畫面自己翻頁（以前會在半路再起一個過場＝卡頓、左邊疊出好幾條頁緣）
        if FacePaging.ownsScroll(precise: e.hasPreciseScrollingDeltas, dragging: FacePaging.drag != nil,
                                 momentum: e.momentumPhase != [], sinceRelease: now - FacePaging.releasedAt) {
            return facePageScroll(e, uv: uv)
        }
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
            if Shell.far { Shell.far = false; Shell.lastActive = now; face.forceDirty = true; return true }   // 2.0 home-3：遠看時捲一下＝回到近看
            if let a = Shell.currentApp, !PersonalGate.locks(a.id), a.handleScroll(precise ? e.scrollingDeltaY : e.scrollingDeltaY * 10, now: now) { face.forceDirty = true; return true }
            return !precise
        case .switcher:   // 左右捲卡片：觸控板跟手、滾輪一格一張；停下來對齊最近的一張
            let n = AppSwitcher.cards(face: face).count, maxS = CGFloat(max(0, n - 1)) * AppSwitcher.pitch
            let step = precise ? -(abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY) * 2 : CGFloat(dir) * AppSwitcher.pitch
            let goal = max(-60, min(maxS + 60, (AppSwitcher.scrollAnim?.to ?? AppSwitcher.scroll) + step))
            if precise && e.phase != .ended && e.momentumPhase == [] { AppSwitcher.scroll = goal; AppSwitcher.scrollAnim = nil }
            else {
                let snap = AppSwitcher.snap(goal, velocity: 0, count: n)
                AppSwitcher.scrollAnim = MotionValue("switcher", spring: .smooth, from: AppSwitcher.scroll, to: snap, now: now)
            }
            face.forceDirty = true
            return true
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
            case .switcher:
                let n = AppSwitcher.cards(face: face).count
                let goal = AppSwitcher.snap((AppSwitcher.scrollAnim?.to ?? AppSwitcher.scroll) + CGFloat(dir) * AppSwitcher.pitch, velocity: 0, count: n)
                AppSwitcher.scrollAnim = MotionValue("switcher", spring: .smooth, from: AppSwitcher.scroll, to: goal, now: CACurrentMediaTime())
                face.forceDirty = true
                return true
            case .library, .app: return true
            }
        default: return false
        }
    }

    @objc func menuShellHome() {
        leaveCarPlayForShell()
        wakeFromPosterForGuide()
        Shell.lastActive = CACurrentMediaTime()
        if Shell.nav.screen == .face { shellNavigate(.up) } else { shellNavigate(.back) }
    }
    @objc func menuShellControlCenter() {
        leaveCarPlayForShell()
        wakeFromPosterForGuide()
        Shell.lastActive = CACurrentMediaTime()
        shellNavigate(.toggleControlCenter)
    }

    private func leaveCarPlayForShell() { surfaceFromCarPlay("menu shell") }

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
        AirDrop.applyDemo(args)   // --demo-airdrop photo|link|file|guest（Shell/AirDrop/AirDrop.swift）
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
        if SourceSwitcher.demo == .carPlay { SourceSwitcher.open = (CACurrentMediaTime() - 10, .carPlay) }   // 2.0 align D：--source carplay 拍拉開的兩顆
        applyCarPlayDemo()   // --demo-carplay、--switcher（Shell/AppSwitcher.swift）
        applyIndicatorDemo()   // --indicator-pull（Shell/HomeIndicator.swift）
        applyTouchSnapshotFlags()   // --touch-tip、HOMEPLAY_TOUCH_EXPAND（Shell/TouchInput.swift）
        if let script = ProcessInfo.processInfo.environment["HOMEPLAY_SHELL_SCRIPT"] { runShellScript(script) }
    }

    /// 自檢用：照腳本送假的滑鼠／鍵盤／滾輪事件走真的 PetView 入口（uv 直接給，不經 3D 投影），每步記一行日誌。
    /// HOMEPLAY_SHELL_SCRIPT="key:126;tap:0.3,0.25;drag:0.85,0.05,0,-40;wheel:-1"（tap/drag 的 x,y 是螢幕 uv；drag 的 dx,dy 是視窗點、y 往上；skey＝按著 ⇧ 的 key）
    /// udrag:x,y,du,dv＝滑鼠拖，螢幕上的 uv 跟著走（主畫面換頁、資源庫照 uv 跟手）；pan:x,y,dx,dy＝觸控板兩指滑（帶 began／ended 的精確捲動）
    /// hold:x,y,du,dv＝按住 0.6 s 再拖到 (x+du, y+dv)（uv）放手（長按藥丸的兩顆切換，2.0 align D）
    /// 觸控（假觸控走 TouchInput 的同一條路）：ttap:x,y、tdrag:x,y,du,dv（uv，12 步）、thold:x,y（按住 0.8 s）、
    /// tcancel:x,y,du,dv（同 tdrag，但最後被系統收走：驗取消的收尾）
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
                case "udrag" where nums.count == 4:   // 滑鼠拖，uv 跟著走（主畫面換頁照 uv 跟手）；視窗點照螢幕約 300 pt 寬估
                    ShellInput.uvOverride = CGPoint(x: nums[0], y: nums[1])
                    if let d = mouse(.leftMouseDown, base) { self.mouseDown(with: d) }
                    for k in 1...8 {
                        let f = Double(k) / 8
                        ShellInput.uvOverride = CGPoint(x: nums[0] + nums[2] * f, y: nums[1] + nums[3] * f)
                        if let e = mouse(.leftMouseDragged, NSPoint(x: base.x + nums[2] * 300 * f, y: base.y - nums[3] * 300 * f)) { self.mouseDragged(with: e) }
                    }
                    if let u = mouse(.leftMouseUp, NSPoint(x: base.x + nums[2] * 300, y: base.y - nums[3] * 300)) { self.mouseUp(with: u) }
                    ShellInput.uvOverride = nil
                case "hold" where nums.count == 4:
                    ShellInput.uvOverride = CGPoint(x: nums[0], y: nums[1])
                    if let d = mouse(.leftMouseDown, base) { self.mouseDown(with: d) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        ShellInput.uvOverride = CGPoint(x: nums[0] + nums[2], y: nums[1] + nums[3])
                        if let e = mouse(.leftMouseDragged, base) { self.mouseDragged(with: e) }
                        if let u = mouse(.leftMouseUp, base) { self.mouseUp(with: u) }
                        ShellInput.uvOverride = nil
                    }
                case "ttap" where nums.count == 2, "thold" where nums.count == 2, "tdrag" where nums.count == 4, "tcancel" where nums.count == 4:
                    let p0 = CGPoint(x: nums[0], y: nums[1])
                    let path = nums.count == 4 ? (0...12).map { CGPoint(x: nums[0] + nums[2] * Double($0) / 12, y: nums[1] + nums[3] * Double($0) / 12) } : [p0]
                    self.touchInject(path, hold: op == "thold" ? 0.8 : 0, cancel: op == "tcancel")
                case "key" where nums.count == 1, "skey" where nums.count == 1:   // skey＝按著 ⇧
                    let ch = nums[0] == 49 ? " " : ""   // 空白鍵帶字元（資源庫搜尋時是文字）
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: op == "skey" ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: win.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                isARepeat: false, keyCode: UInt16(nums[0])) { self.keyDown(with: e) }
                case "pan" where nums.count == 4:   // 觸控板兩指滑：pan:x,y,dx,dy（uv；dx,dy＝整段的 scrollingDelta，十段 changed，前後 began／ended）
                    ShellInput.uvOverride = CGPoint(x: nums[0], y: nums[1])
                    for k in 0...11 {
                        let phase: Int64 = k == 0 ? 1 : (k == 11 ? 4 : 2)   // began／changed／ended
                        let ddx = k == 0 || k == 11 ? 0 : nums[2] / 10, ddy = k == 0 || k == 11 ? 0 : nums[3] / 10
                        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(ddy), wheel2: Int32(ddx), wheel3: 0) else { continue }
                        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: ddx)
                        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: ddy)
                        if let e = NSEvent(cgEvent: cg) { self.scrollWheel(with: e) }
                    }
                    ShellInput.uvOverride = nil
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
