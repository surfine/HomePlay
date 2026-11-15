// 2.0：觸控板與滑鼠各有自己的手勢（2026-11-12 定案，docs/plans/gestures.md 第八節）。
//
// 前面的手勢是照觸控設計的（下拉、拉住停、長按），Magic Trackpad 與 Magic Mouse 要按住再拖才做得出來。
// 這個檔案放這一輪新增的判定（純邏輯，--selftest 直接驗）和接到 PetView 的那幾段；按住拖的做法全部保留。
// - 捲動下拉：游標在頂端中間的把手命中區起手往下捲＝下拉把手（卡片跟手，門檻沿用 HomeIndicator）；右上角＝控制中心。
//   歸屬只在起手決定：起手不在命中區的捲動整段都不是下拉（清單捲過頂只回彈），慣性不能自己開始。
//   方向用系統給的內容位移，所以「自然捲動」開或關都跟其他 App 同向。
// - 次要按鈕一律只打開情境選單（HIG Pointing devices、Context menus）；重按＝圖示或小工具的預覽與選單，其他地方不做事。
// - 智慧縮放＝桌寵在目前大小與放大之間切換。
// - 游標回饋：主畫面與資料庫圖示放大 4%、按鈕與清單列出現底色；只動縮放與不透明度，減少動態效果時不縮放。
// - 震動只留三處（下拉越過 commit、編輯模式圖示進格子、捏合到極限），設定 › 輔助使用「觸覺回饋」可關。
// - 摸頭、找游標：只換表情與眼神，不觸發功能。
// 快照：HOMEPLAY_HOVER=u,v（螢幕 uv）＝游標停在那一點的樣子；捲動下拉用 HOMEPLAY_SHELL_SCRIPT 的 pan:x,y,dx,dy（走真的 scrollWheel）。

import AppKit

// MARK: - 捲動下拉

struct ScrollPull: Equatable {
    enum Zone: Equatable { case handle, controlCenter }
    enum State: Equatable { case idle, undecided(Zone), pulling(Zone), passing }
    /// notOurs＝照原本的路；swallow＝這一下歸命中區但還沒有動作；begin／track／release＝開始跟手、跟手、放開
    enum Step: Equatable { case notOurs, swallow, begin(Zone), track(Zone), release(Zone) }

    /// 沒有 phase 的滾輪：停這麼久當放開
    static let idleRelease = 0.3
    /// 往上推過頭最多算到這裡（卡片的橡皮筋）
    static let overshoot: CGFloat = -200

    private(set) var state: State = .idle
    /// 往下拉了多遠（1024 畫布 px）
    private(set) var distance: CGFloat = 0
    /// 這一手有 phase（觸控板、Magic Mouse）；沒有的是一般滾輪
    private(set) var phased = false
    private var sideways: CGFloat = 0
    private var lastAt = -1e9
    /// 放開之後同一手剩下的慣性：吃掉，不交給底下的畫面
    private var swallowMomentum = false

    var active: Bool { if case .pulling = state { return true }; return false }

    /// dx、dy：這一格的內容位移（畫布 px；dy 往下為正）。zone：起手那一點歸哪個命中區（只在新的一手開始時問一次）
    mutating func feed(now: Double, began: Bool, ended: Bool, momentum: Bool, hasPhase: Bool, dx: CGFloat, dy: CGFloat, zone: () -> Zone?) -> Step {
        if momentum {   // 慣性不能自己開始一次下拉
            if case .pulling(let z) = state { state = .idle; swallowMomentum = true; return .release(z) }
            return swallowMomentum ? .swallow : .notOurs
        }
        let stale = now - lastAt > ScrollArbiter.gestureGap
        lastAt = now
        if began || (!hasPhase && (state == .idle || (stale && !active))) {
            state = zone().map { .undecided($0) } ?? .passing
            distance = 0; sideways = 0; swallowMomentum = false; phased = hasPhase
        } else if state == .idle {
            state = .passing   // 起手沒看到（半路才進來）：這一手不算
        }
        switch state {
        case .idle, .passing:
            return .notOurs
        case .undecided(let z):
            distance += dy; sideways += dx
            if ended { state = .idle; return .swallow }
            guard hypot(distance, sideways) >= ShellInput.slop else { return .swallow }
            guard distance > 0, abs(distance) > abs(sideways) * 1.2 else { state = .passing; return .notOurs }   // 橫向（換頁）、往上：交回原本的路
            state = .pulling(z)
            return .begin(z)
        case .pulling(let z):
            distance = max(Self.overshoot, distance + dy)
            if ended { state = .idle; swallowMomentum = true; return .release(z) }
            return .track(z)
        }
    }

    /// 每幀：沒有 phase 的滾輪停夠久＝放開
    mutating func idle(now: Double) -> Step? {
        guard !phased, now - lastAt >= Self.idleRelease else { return nil }
        switch state {
        case .pulling(let z): state = .idle; return .release(z)
        case .undecided: state = .idle; return nil
        case .idle, .passing: return nil
        }
    }

    mutating func cancel() { state = .idle; distance = 0; sideways = 0; swallowMomentum = false }
}

// MARK: - 次要按鈕、重按、智慧縮放（純邏輯）

enum PointerTarget: Equatable {
    /// 主畫面上的一項（App、資料夾、小工具、疊放）
    case homeItem(key: String, widget: Bool)
    case libraryApp(String)
    /// 主畫面空白處
    case homeEmpty
    case backButton
    case face
    /// 機身、App 內容、其他
    case other
}

enum SecondaryClick {
    /// 次要按鈕打開哪一份選單。每一種都只是打開選單，本身不執行任何動作
    enum Menu: Equatable {
        /// 圖示、小工具：現在長按出現的那一份（畫在螢幕上）
        case item(key: String)
        case libraryApp(String)
        /// 桌寵選單，最前面多一段跟游標底下有關的項目
        case pet(lead: [Lead])
    }
    enum Lead: Equatable { case editHome, faceOverview, back, home }

    static func menu(for t: PointerTarget, canEdit: Bool, backGoesHome: Bool) -> Menu {
        switch t {
        case .homeItem(let key, let widget):
            // 小工具的那一份要能編輯才有；沒有就退回桌寵選單（不讓次要按鈕什麼都沒出現）
            return widget && !canEdit ? .pet(lead: [.faceOverview]) : .item(key: key)
        case .libraryApp(let id): return .libraryApp(id)
        case .homeEmpty: return .pet(lead: canEdit ? [.editHome, .faceOverview] : [.faceOverview])
        case .face: return .pet(lead: canEdit ? [.faceOverview, .editHome] : [.faceOverview])
        case .backButton: return .pet(lead: backGoesHome ? [.home] : [.back, .home])   // 返回就是回主畫面時不重複列（不可用的項目隱藏）
        case .other: return .pet(lead: [])   // 機身、App 內容：桌寵這個物件本身的選單
        }
    }
}

enum ForceClick {
    enum Action: Equatable { case none, preview(key: String), previewLibrary(String) }
    /// 重按只在圖示與小工具上有反應（預覽與選單）；其他地方不做事，也不再進出 CarPlay
    static func action(for t: PointerTarget) -> Action {
        switch t {
        case .homeItem(let key, _): return .preview(key: key)
        case .libraryApp(let id): return .previewLibrary(id)
        case .homeEmpty, .backButton, .face, .other: return .none
        }
    }
}

enum SmartZoom {
    /// 放大到原本的幾倍
    static let factor: CGFloat = 1.6
    /// 智慧縮放：在「目前大小」和「放大」之間切換。restore＝上一次放大前的寬度（放大之後手動改過大小就作廢）。
    /// 回（要去的寬度、新的 restore）
    static func toggle(width: CGFloat, restore: (from: CGFloat, zoomed: CGFloat)?, maxWidth: CGFloat) -> (to: CGFloat, restore: (from: CGFloat, zoomed: CGFloat)?) {
        if let r = restore, abs(width - r.zoomed) < 2 { return (r.from, nil) }
        let to = min(maxWidth, width * factor)
        guard to - width > 2 else { return (width, nil) }   // 已經最大：不動
        return (to, (width, to))
    }
}

// MARK: - 震動（HIG Playing haptics：Mac 上用於拖曳或重按、少用、要能關掉）

enum PointerHaptics {
    static let key = "screenHapticFeedback"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    /// 只有這三處
    enum Moment: CaseIterable { case pullCommit, iconIntoSlot, pinchLimit }
    static func pattern(_ m: Moment) -> NSHapticFeedbackManager.FeedbackPattern {
        // HIG Playing haptics（macOS 的三種樣式）：alignment＝拖曳的東西對齊、放到位、到了最小／最大；level change 是壓力的級距，
        // 不拿來表示別的；越過下拉門檻兩種都不是，用 generic
        switch m {
        case .pullCommit: return .generic
        case .iconIntoSlot, .pinchLimit: return .alignment
        }
    }
    static func perform(_ m: Moment) {
        guard enabled, !CommandLine.arguments.contains("--selftest") else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern(m), performanceTime: .now)
    }
    /// 往下拉越過門檻的那一格（退回去再越過會再震一次）
    static func crossesUp(from a: CGFloat, to b: CGFloat, threshold: CGFloat) -> Bool { a < threshold && b >= threshold }
}

// MARK: - 摸頭、找游標

/// 游標在桌寵頭頂不按鍵來回四次以上（1.5 秒內）＝開心 1.2 秒；之後 10 秒內不重複
struct HeadPat: Equatable {
    static let turnsNeeded = 4
    static let window = 1.5
    static let cooldown = 10.0
    static let happyFor = 1.2
    /// 這麼小的移動不算換方向（視圖點）
    static let jitter: CGFloat = 3

    private var lastX: CGFloat?
    private var dir = 0
    private var turns = 0
    private var firstTurnAt = 0.0
    private var coolUntil = -1e9

    /// 餵游標的位置；回 true＝這一下算摸到了
    mutating func feed(x: CGFloat, now: Double, onHead: Bool, buttonDown: Bool) -> Bool {
        guard onHead, !buttonDown, now >= coolUntil else { lastX = nil; dir = 0; turns = 0; return false }
        guard let last = lastX else { lastX = x; return false }
        let dx = x - last
        guard abs(dx) > Self.jitter else { return false }   // 小晃動先不記，累積到超過 jitter 才算走了一步
        lastX = x
        let nd = dx > 0 ? 1 : -1
        if nd != dir {
            if turns == 0 || now - firstTurnAt > Self.window { turns = 0; firstTurnAt = now }
            dir = nd; turns += 1
        }
        guard turns >= Self.turnsNeeded else { return false }
        turns = 0; dir = 0; coolUntil = now + Self.cooldown
        return true
    }
}

/// 找游標：使用者快速搖晃游標（macOS 放大游標的那個動作）
struct CursorShake: Equatable {
    static let turnsNeeded = 3
    static let window = 0.6
    /// 每一段至少走這麼遠（螢幕點）、平均速度至少這麼快（點／秒）才算搖
    static let minSwing: CGFloat = 60
    static let minSpeed: CGFloat = 900
    /// 眼睛看過去多久
    static let lookFor = 2.0

    private var lastX: CGFloat?
    private var lastAt = 0.0
    private var dir = 0
    private var swingFrom: CGFloat = 0
    private var swingAt = 0.0
    private var turnTimes: [Double] = []

    mutating func feed(x: CGFloat, now: Double) -> Bool {
        guard let last = lastX else { lastX = x; lastAt = now; swingFrom = x; swingAt = now; return false }
        let dx = x - last
        guard abs(dx) > 1 else { return false }
        let turnedAt = lastAt
        lastX = x; lastAt = now
        let nd = dx > 0 ? 1 : -1
        guard nd != dir else { return false }
        // 換方向：剛走完的那一段夠長、夠快才算一次
        let swing = abs(last - swingFrom), dt = max(0.001, turnedAt - swingAt)
        let counted = dir != 0 && swing >= Self.minSwing && swing / CGFloat(dt) >= Self.minSpeed
        dir = nd; swingFrom = last; swingAt = turnedAt
        guard counted else { if swing >= Self.minSwing { turnTimes = [] }; return false }   // 慢慢來回：重新數
        turnTimes = turnTimes.filter { now - $0 <= Self.window } + [now]
        guard turnTimes.count >= Self.turnsNeeded else { return false }
        turnTimes = []
        return true
    }
}

// MARK: - 游標回饋

enum PointerHover {
    enum Target: Equatable {
        /// 主畫面上的圖示（key＝SBItem.key）
        case homeIcon(String)
        /// 資料庫的圖示（rect＝畫面上的框，已含捲動位移）
        case libraryIcon(id: String, rect: CGRect)
        /// 按鈕、控制中心的磚、清單列：出現底色
        case control(rect: CGRect, shape: HPAXNote.Shape, onDark: Bool)
    }
    static let iconScale: CGFloat = 1.04
    static let fade = 0.12

    nonisolated(unsafe) static var target: Target?
    /// 快照（HOMEPLAY_HOVER=u,v）：直接停在游標移上去之後的樣子
    nonisolated(unsafe) static var snapshot = false
    nonisolated(unsafe) private static var since = -1e9
    nonisolated(unsafe) private static var leaving: (target: Target, at: Double, level: CGFloat)?

    /// 純邏輯：0…1 的進度（線性；淡入淡出各 fade 秒）
    static func level(since: Double, now: Double) -> CGFloat { CGFloat(max(0, min(1, (now - since) / fade))) }
    /// 圖示放大的倍率；減少動態效果時不縮放
    static func scale(level: CGFloat, reduceMotion: Bool) -> CGFloat { reduceMotion ? 1 : 1 + (iconScale - 1) * level }
    /// 底色（深色底上白、淺色底上黑）
    static func tint(onDark: Bool, level: CGFloat) -> NSColor { onDark ? NSColor(white: 1, alpha: 0.12 * level) : NSColor(white: 0, alpha: 0.07 * level) }

    static func set(_ t: Target?, now: Double) -> Bool {
        guard t != target else { return false }
        if let old = target { leaving = (old, now, level(since: since, now: now)) }
        // 回到剛離開的那一個：從當下的程度接著，不跳
        if let t, let l = leaving, l.target == t { since = now - Double(leavingLevel(now)) * fade; leaving = nil } else { since = now }
        target = t
        return true
    }
    static func currentLevel(_ now: Double) -> CGFloat { target == nil ? 0 : (snapshot ? 1 : level(since: since, now: now)) }
    static func leavingLevel(_ now: Double) -> CGFloat {
        guard let l = leaving else { return 0 }
        return max(0, l.level - CGFloat((now - l.at) / fade))
    }
    /// 還在淡入或淡出（要繼續重畫）
    static func animating(_ now: Double) -> Bool {
        if leaving != nil, leavingLevel(now) <= 0 { leaving = nil }
        return leaving != nil || (target != nil && now - since < fade)
    }
    /// 這一格每個目標各自的程度
    static func levels(_ now: Double) -> [(Target, CGFloat)] {
        var out: [(Target, CGFloat)] = []
        if let l = leaving { let k = leavingLevel(now); if k > 0 { out.append((l.target, k)) } }
        if let t = target { out.append((t, currentLevel(now))) }
        return out
    }
    /// 主畫面這一顆圖示現在放大多少（SBRender 畫每一項時問）
    static func homeIconScale(_ key: String, now: Double) -> CGFloat {
        for (t, k) in levels(now) { if t == .homeIcon(key) { return scale(level: k, reduceMotion: HPMotion.reduceMotion) } }
        return 1
    }
    /// 主畫面有圖示在放大（那一頁要逐項畫，不能用快取的整頁）
    static func homeLive(_ now: Double) -> Bool {
        guard !HPMotion.reduceMotion else { return false }
        return levels(now).contains { if case .homeIcon = $0.0 { return true }; return false }
    }
}

enum PointerInput {
    nonisolated(unsafe) static var scrollPull = ScrollPull()
    nonisolated(unsafe) static var headPat = HeadPat()
    nonisolated(unsafe) static var shake = CursorShake()
    /// 找游標：眼睛朝游標看到這個時間點
    nonisolated(unsafe) static var lookAtCursorUntil = -1e9
    /// 智慧縮放放大前的寬度
    nonisolated(unsafe) static var zoomRestore: (from: CGFloat, zoomed: CGFloat)?
}

// MARK: - 接到 PetView

extension PetView {
    /// 游標底下是什麼（次要按鈕、重按用）。uv＝螢幕上的位置；不在螢幕上＝機身或透明邊
    func pointerTarget(_ uv: CGPoint?) -> PointerTarget {
        guard let uv, !shellBlocked, !face.onboardingActive, !face.inOverview, !PermissionPrimer.visible, Shell.nav.overlay == .none,
              Shell.appMorph == nil, !Shell.peopleSheet else { return .other }
        let p = CGPoint(x: uv.x * 1024, y: uv.y * 1024)
        switch Shell.nav.screen {
        case .face: return .face
        case .home:
            guard !SB.editing, !SB.overlayOpen else { return .other }
            if HomeIndicator.owner(p, on: .home, pill: LiveActivityStack.pillHit, inset: nil) != .shell { return .other }
            if let pl = SB.placements(page: SB.pageIndex).first(where: { SB.frame($0).contains(p) }), let key = pl.item.key {
                if case .spacer = pl.item { return .homeEmpty }
                return .homeItem(key: key, widget: !pl.item.isIcon)
            }
            return .homeEmpty
        case .library:
            guard !SB.overlayOpen else { return .other }
            if let id = pointerLibraryIcon(p)?.id { return .libraryApp(id) }
            return .other
        case .app:
            let a = Shell.currentApp, locked = a.map { PersonalGate.locks($0.id) } ?? false
            if a?.showsCloseButton != false || locked, Shell.closeButton.insetBy(dx: -8, dy: -8).contains(p) { return .backButton }
            return .other
        case .switcher: return .other
        }
    }

    /// 資料庫裡游標底下的圖示（畫面上的框，已含捲動位移）
    func pointerLibraryIcon(_ p: CGPoint) -> (id: String, rect: CGRect)? {
        guard p.y >= SBUI.libraryClipTop else { return nil }
        let off = SB.libraryScrollNow
        if SB.libraryBrowsing {
            if SB.libraryShowingExpanded {
                for (app, cell) in zip(SBUI.libraryExpandedApps(), SBUI.libraryExpandedCells()) {
                    let r = SBUI.libraryIcon(cell).offsetBy(dx: 0, dy: -off)
                    if SBUI.libraryMostlyVisible(cell.offsetBy(dx: 0, dy: -off)), r.contains(p) { return (app.id, r) }
                }
                return nil
            }
            for icon in SBUI.libraryPodIcons() {
                let r = icon.rect.offsetBy(dx: 0, dy: -off)
                if SBUI.libraryMostlyVisible(r), r.contains(p) { return (icon.id, r) }
            }
            return nil
        }
        for (app, cell) in zip(SBUI.libraryApps(), SBUI.libraryLayout().cells) {
            let r = SBUI.libraryIcon(cell).offsetBy(dx: 0, dy: -off)
            if r.contains(p) { return (app.id, r) }
        }
        return nil
    }

    // MARK: 捲動下拉

    /// PetView.scrollWheel 在外殼的捲動之前先問這裡。回 true＝這一下歸把手或控制中心角
    func pointerScroll(_ e: NSEvent, uv: CGPoint?) -> Bool {
        let now = CACurrentMediaTime()
        let precise = e.hasPreciseScrollingDeltas
        let k = 1024 / max(80, bounds.height * 0.6) * (precise ? 1 : 10)   // 視圖點 → 畫布 px；一般滾輪一格當 10 點
        let hasPhase = !e.phase.isEmpty || !e.momentumPhase.isEmpty
        let step = PointerInput.scrollPull.feed(
            now: now, began: e.phase == .began, ended: e.phase == .ended || e.phase == .cancelled, momentum: !e.momentumPhase.isEmpty,
            hasPhase: hasPhase, dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k, zone: { [unowned self] in self.pointerScrollZone(uv) })
        return pointerScrollApply(step, now: now)
    }

    /// 起手那一點歸哪個命中區（跟按住拖同一份歸屬：HomeIndicator.owner）
    func pointerScrollZone(_ uv: CGPoint?) -> ScrollPull.Zone? {
        guard let uv, ShellInput.down == nil, SBInputState.press == nil, HomeIndicator.pull == nil, HomeIndicator.settle == nil, !Shell.ccDragging else { return nil }
        let p = CGPoint(x: uv.x * 1024, y: uv.y * 1024)
        if showingVideo, !carVideo.active {
            return HomeIndicator.owner(p, on: .carPlay, pill: nil, inset: HomeIndicator.inset) == .indicator ? .handle : nil
        }
        guard !shellBlocked, !face.onboardingActive, !face.inOverview, !PermissionPrimer.visible, Shell.nav.overlay == .none, Shell.appMorph == nil,
              !Shell.peopleSheet, !SB.editing, !SB.overlayOpen, !Shell.displayAsleep, !Shell.ambientPosterActive else { return nil }
        let surface = indicatorSurface
        switch HomeIndicator.owner(p, on: surface, pill: Shell.nav.screen.coversFace ? LiveActivityStack.pillHit : nil, inset: nil) {
        case .indicator: return surface == .face ? nil : .handle   // 錶面沒有把手
        case .controlCenter: return .controlCenter
        case .carPlay, .shell: return nil
        }
    }

    @discardableResult
    func pointerScrollApply(_ step: ScrollPull.Step, now: Double) -> Bool {
        let d = PointerInput.scrollPull.distance
        switch step {
        case .notOurs: return false
        case .swallow: return true
        case .begin(.handle):
            HomeHandle.reveal(now: now)
            guard indicatorBegin(now: now) else { PointerInput.scrollPull.cancel(); return true }   // CarPlay 收不到背景：這一手作廢
            pointerPullTrack(d, now: now)
        case .track(.handle): pointerPullTrack(d, now: now)
        case .release(.handle): indicatorRelease(now: now)
        case .begin(.controlCenter):
            ccBeginDrag(); ccTrack(d / HPMotion.T.ccTravel)
        case .track(.controlCenter): ccTrack(d / HPMotion.T.ccTravel)
        case .release(.controlCenter): ccEndDrag()
        }
        Shell.lastActive = now
        return true
    }

    private func pointerPullTrack(_ d: CGFloat, now: Double) {
        indicatorTrack(d, t: now)
        // 沒有 phase 的滾輪分不出停住和放開：不做「拉住停＝切換器」
        if !PointerInput.scrollPull.phased { HomeIndicator.pull?.lastMoveAt = .infinity }
    }

    /// 每幀（shellStep）：一般滾輪停夠久＝放開；游標回饋的淡入淡出要重畫
    func pointerStep(_ now: Double) {
        if let step = PointerInput.scrollPull.idle(now: now) { pointerScrollApply(step, now: now) }
        if PointerInput.scrollPull.active, HomeIndicator.pull == nil, !Shell.ccDragging { PointerInput.scrollPull.cancel() }   // 被別的路收走了（取消、重按）
        if PointerHover.animating(now) { face.forceDirty = true }
    }

    // MARK: 次要按鈕

    /// 次要按鈕：打開游標底下那個東西的情境選單。回 nil＝選單畫在螢幕上（已經打開）；否則回要彈出的 NSMenu
    func pointerSecondaryMenu(_ uv: CGPoint?) -> NSMenu? {
        let target = pointerTarget(uv)
        let now = CACurrentMediaTime()
        let backHome: Bool = { if case .app = Shell.nav.screen { return Shell.nav.appReturn == .home }; return true }()
        switch SecondaryClick.menu(for: target, canEdit: PersonHome.canEdit || SB.forcedLayout != nil, backGoesHome: backHome) {
        case .item(let key):
            SB.openMenu(for: key, now: now)
            if SB.menu != nil { Shell.lastActive = now; face.forceDirty = true; log("secondary click → item menu \(key)"); return nil }
            return buildContextMenu(context: true, lead: [.faceOverview])   // 這一項沒有自己的選單：螢幕上的精簡選單
        case .libraryApp(let id):
            if let uv, let cell = SBUI.libraryIconAnchor(id: id, at: CGPoint(x: uv.x * 1024, y: uv.y * 1024), offset: SB.libraryScrollNow) {
                SB.openLibraryMenu(app: id, cell: cell, now: now)
                Shell.lastActive = now; face.forceDirty = true
                log("secondary click → library menu \(id)")
                return nil
            }
            return buildContextMenu(context: true, lead: [.faceOverview])
        case .pet(let lead):
            return buildContextMenu(context: true, lead: lead)
        }
    }

    /// 情境選單最前面那一段（跟游標底下有關的項目）。每一項在別處也做得到：長按、把手、選單列
    func pointerLeadItems(_ lead: [SecondaryClick.Lead]) -> [NSMenuItem] {
        lead.map { l in
            let item: NSMenuItem
            switch l {
            case .editHome: item = NSMenuItem(title: L("sb.menu.editHome", "编辑主屏幕"), action: #selector(menuEditHome), keyEquivalent: "")
            case .faceOverview: item = NSMenuItem(title: L("menu.faceOverview", "显示表盘总览"), action: #selector(menuFaceOverview), keyEquivalent: "")
            case .back: item = NSMenuItem(title: L("a11y.back", "返回"), action: #selector(menuShellBack), keyEquivalent: "")
            case .home: item = NSMenuItem(title: L("pointer.menu.home", "主屏幕"), action: #selector(menuShellGoHome), keyEquivalent: "")
            }
            item.target = self
            return item
        }
    }

    @objc func menuEditHome() {
        surfaceFromCarPlay("menu edit home")
        let now = CACurrentMediaTime()
        Shell.lastActive = now
        if Shell.nav.screen == .face { shellNavigate(.up) }
        for _ in 0..<8 where Shell.nav.screen != .home { if !shellNavigate(.back) { break } }
        guard Shell.nav.screen == .home else { return }
        SB.enterEdit(now: now)
        face.forceDirty = true
    }
    @objc func menuShellBack() { Shell.lastActive = CACurrentMediaTime(); shellNavigate(.back) }
    /// 返回鈕選單的「主畫面」：不管有幾層（App 的子頁、從別的 App 進來），一路退到主畫面
    @objc func menuShellGoHome() {
        Shell.lastActive = CACurrentMediaTime()
        for _ in 0..<8 {
            guard case .app = Shell.nav.screen else { break }
            Shell.nav.appReturn = .home
            if !shellNavigate(.back) { break }
        }
        log("back button menu → \(Shell.nav.screen)")
    }

    // MARK: 重按

    /// 重按（stage 2）：圖示或小工具＝預覽與選單（長按那一份，馬上出現）；其他地方不做事
    func pointerForceClick(_ uv: CGPoint?) {
        let now = CACurrentMediaTime()
        switch ForceClick.action(for: pointerTarget(uv)) {
        case .none: log("force click: nothing here")
        case .preview(let key):
            SB.openMenu(for: key, now: now)
            log("force click → preview \(key)\(SB.menu == nil ? " (no menu)" : "")")
        case .previewLibrary(let id):
            if let uv, let cell = SBUI.libraryIconAnchor(id: id, at: CGPoint(x: uv.x * 1024, y: uv.y * 1024), offset: SB.libraryScrollNow) {
                SB.openLibraryMenu(app: id, cell: cell, now: now)
                log("force click → preview library \(id)")
            }
        }
        Shell.lastActive = now
        face.forceDirty = true
    }

    // MARK: 智慧縮放

    func pointerSmartZoom() {
        let r = SmartZoom.toggle(width: bounds.width, restore: PointerInput.zoomRestore, maxWidth: min(Pet.maxWidth, zoomMaxWidth))
        PointerInput.zoomRestore = r.restore
        guard abs(r.to - bounds.width) > 1 else { return }
        setZoom(width: r.to)
        log("smart zoom → \(Int(r.to))")
    }

    // MARK: 游標回饋

    /// PetView.mouseMoved／mouseExited：游標在螢幕上的位置（nil＝不在螢幕上）
    func pointerHover(_ uv: CGPoint?) {
        let now = CACurrentMediaTime()
        if PointerHover.set(pointerHoverTarget(uv), now: now) { face.forceDirty = true }
    }

    private func pointerHoverTarget(_ uv: CGPoint?) -> PointerHover.Target? {
        // 觸控沒有游標；按著、拖著、過場中不做
        guard let uv, !TouchInput.synthesizing, !TouchInput.fingerDown, ShellInput.down == nil, SBInputState.press == nil, !shellBlocked,
              !face.onboardingActive, !face.inOverview, !PermissionPrimer.visible, Shell.appMorph == nil, HomeIndicator.pull == nil,
              HomeIndicator.settle == nil, !Shell.peopleSheet, !Shell.far, !Shell.displayAsleep, !Shell.ambientPosterActive else { return nil }
        let p = CGPoint(x: uv.x * 1024, y: uv.y * 1024)
        if Shell.nav.overlay == .controlCenter {
            guard Shell.ccT > 0.95, !Shell.ccDragging else { return nil }
            return pointerControl(at: p, onDark: true)
        }
        guard Shell.nav.overlay == .none else { return nil }
        switch Shell.nav.screen {
        case .home:
            guard !SB.editing, !SB.overlayOpen else { return nil }
            if let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.isIcon && SB.iconRect(in: SB.frame($0)).contains(p) }), let key = pl.item.key {
                return .homeIcon(key)
            }
            return nil
        case .library:
            guard !SB.overlayOpen else { return nil }
            return pointerLibraryIcon(p).map { .libraryIcon(id: $0.id, rect: $0.rect) }
        case .app: return pointerControl(at: p, onDark: HPTokens.dark)
        case .face, .switcher: return nil
        }
    }

    /// App 記下來的按鈕、清單列、返回鈕，控制中心的磚（跟 VoiceOver、鍵盤焦點同一份清單）；頂端把手有自己的現身規則，不在這裡
    private func pointerControl(at p: CGPoint, onDark: Bool) -> PointerHover.Target? {
        let hit = ShellAccessibility.items(face: face)
            .filter { $0.focusable && $0.id != "pill" && $0.rect.contains(p) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        return hit.map { .control(rect: $0.rect, shape: $0.shape, onDark: onDark) }
    }

    // MARK: 摸頭、找游標

    /// PetView.mouseMoved：游標在視圖裡的位置（點）
    func pointerPat(at p: NSPoint, now: Double) {
        let buttonDown = NSEvent.pressedMouseButtons != 0
        guard PointerInput.headPat.feed(x: p.x, now: now, onHead: !TouchInput.synthesizing && pointerOnHead(p), buttonDown: buttonDown) else { return }
        mood.show(.happy, for: HeadPat.happyFor, now: now)   // 只換表情（減少動態效果時也一樣）；不震動、不觸發功能
        face.forceDirty = true
        log("head pat")
    }

    /// 每拍（watchPointer）：游標在螢幕上的位置。搖晃時讓眼睛朝游標看一下
    func pointerShake(screenX x: CGFloat, now: Double) {
        guard !TouchInput.fingerDown, PointerInput.shake.feed(x: x, now: now) else { return }
        PointerInput.lookAtCursorUntil = now + CursorShake.lookFor
        log("cursor shake → eyes look at cursor")
    }
}

// MARK: - 畫游標回饋（renderShell 與疊層之後）

extension Face {
    func drawPointerHover(_ g: CGContext, _ now: Double) {
        for (t, k) in PointerHover.levels(now) where k > 0.003 {
            switch t {
            case .homeIcon: break   // SBRender 畫那一顆時直接放大
            case .libraryIcon(let id, let rect):
                let s = PointerHover.scale(level: k, reduceMotion: HPMotion.reduceMotion)
                guard s > 1.0005, Shell.nav.screen == .library, Shell.nav.overlay == .none, let app = AppRegistry.app(id) else { continue }
                g.saveGState()
                g.addPath(continuousRoundedRect(SBUI.panel, radius: Screen.concentric(inset: HPTokens.Home.panelInset))); g.clip()
                g.clip(to: CGRect(x: 0, y: SBUI.libraryClipTop, width: 1024, height: SBUI.panel.maxY - SBUI.libraryClipTop))
                let w = rect.width * s
                Shell.drawHomeIcon(g, face: self, app: app, in: CGRect(x: rect.midX - w / 2, y: rect.midY - w / 2, width: w, height: w))   // 放大的那一顆蓋在原本的上面
                g.restoreGState()
            case .control(let rect, let shape, let onDark):
                let path: CGPath
                switch shape {
                case .capsule: path = CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) / 2, cornerHeight: min(rect.width, rect.height) / 2, transform: nil)
                case .circle: path = CGPath(ellipseIn: rect, transform: nil)
                case .rounded(let r): path = continuousRoundedRect(rect, radius: min(r, min(rect.width, rect.height) / 2))
                }
                g.saveGState()
                g.addPath(path); g.setFillColor(PointerHover.tint(onDark: onDark, level: k).cgColor); g.fillPath()
                g.restoreGState()
            }
        }
    }
}

// MARK: - 自檢

enum PointerInputSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias S = ScrollPull.Step
        // 捲動下拉：距離與方向
        var sp = ScrollPull()
        let s0 = sp.feed(now: 0, began: true, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 0, zone: { .handle })
        let s1 = sp.feed(now: 0.01, began: false, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 3, zone: { nil })
        let s2 = sp.feed(now: 0.02, began: false, ended: false, momentum: false, hasPhase: true, dx: 1, dy: 40, zone: { nil })
        let s3 = sp.feed(now: 0.03, began: false, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 80, zone: { nil })
        check(s0 == .swallow && s1 == .swallow && s2 == S.begin(.handle) && s3 == S.track(.handle) && sp.distance == 123,
              "捲動下拉：在把手命中區起手往下捲，過了 slop 開始跟手，距離＝累計的內容位移")   // l10n-ignore
        check(HomeIndicator.outcome(distance: sp.distance, velocity: 0, armed: false) == .home && sp.distance >= HomeIndicator.commit,
              "捲動下拉：門檻沿用 HomeIndicator（拉過 110 放開＝回主畫面）")   // l10n-ignore
        let s4 = sp.feed(now: 0.04, began: false, ended: true, momentum: false, hasPhase: true, dx: 0, dy: 0, zone: { nil })
        let s5 = sp.feed(now: 0.05, began: false, ended: false, momentum: true, hasPhase: true, dx: 0, dy: 30, zone: { .handle })
        check(s4 == S.release(.handle) && s5 == .swallow && !sp.active, "捲動下拉：手指離開＝放開；放開後的慣性吃掉，不再拉也不交給底下的畫面")   // l10n-ignore
        var back = ScrollPull()
        _ = back.feed(now: 0, began: true, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 120, zone: { .handle })
        _ = back.feed(now: 0.01, began: false, ended: false, momentum: false, hasPhase: true, dx: 0, dy: -90, zone: { nil })
        check(back.distance == 30 && HomeIndicator.outcome(distance: back.distance, velocity: 0, armed: false) == .cancel, "捲動下拉：拉回去（距離退到門檻以下）＝取消")   // l10n-ignore
        var up = ScrollPull()
        _ = up.feed(now: 0, began: true, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 0, zone: { .handle })
        let u1 = up.feed(now: 0.01, began: false, ended: false, momentum: false, hasPhase: true, dx: 0, dy: -40, zone: { nil })
        let u2 = up.feed(now: 0.02, began: false, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 300, zone: { .handle })
        check(u1 == .notOurs && u2 == .notOurs, "捲動下拉：起手往上捲不是下拉，這一手之後再往下也不改判")   // l10n-ignore
        var side = ScrollPull()
        _ = side.feed(now: 0, began: true, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 0, zone: { .handle })
        let h1 = side.feed(now: 0.01, began: false, ended: false, momentum: false, hasPhase: true, dx: 40, dy: 6, zone: { nil })
        check(h1 == .notOurs && side.state == .passing, "捲動下拉：在命中區起手但橫向為主（換頁）＝整段交回原本的路")   // l10n-ignore
        // 清單捲過頂不觸發：起手不在命中區，整段（含慣性）都不是下拉
        var list = ScrollPull()
        let l0 = list.feed(now: 0, began: true, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 0, zone: { nil })
        let l1 = list.feed(now: 0.01, began: false, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 400, zone: { .handle })
        let l2 = list.feed(now: 0.02, began: false, ended: true, momentum: false, hasPhase: true, dx: 0, dy: 0, zone: { .handle })
        let l3 = list.feed(now: 0.03, began: false, ended: false, momentum: true, hasPhase: true, dx: 0, dy: 400, zone: { .handle })
        check([l0, l1, l2, l3].allSatisfy { $0 == .notOurs } && list.distance == 0, "捲動下拉：清單捲過頂只回彈——起手不在命中區的捲動（含慣性）不當成下拉")   // l10n-ignore
        var mo = ScrollPull()
        check(mo.feed(now: 0, began: false, ended: false, momentum: true, hasPhase: true, dx: 0, dy: 200, zone: { .handle }) == .notOurs,
              "捲動下拉：慣性事件不能自己開始一次下拉")   // l10n-ignore
        // 右上角＝控制中心
        var cc = ScrollPull()
        _ = cc.feed(now: 0, began: true, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 0, zone: { .controlCenter })
        check(cc.feed(now: 0.01, began: false, ended: false, momentum: false, hasPhase: true, dx: 0, dy: 30, zone: { nil }) == S.begin(.controlCenter),
              "捲動下拉：右上角命中區往下捲＝控制中心跟手拉開")   // l10n-ignore
        // 一般滾輪（沒有 phase）：停 0.3 秒當放開；隔太久算新的一手
        var wheel = ScrollPull()
        let w1 = wheel.feed(now: 0, began: false, ended: false, momentum: false, hasPhase: false, dx: 0, dy: 60, zone: { .handle })
        let w2 = wheel.feed(now: 0.1, began: false, ended: false, momentum: false, hasPhase: false, dx: 0, dy: 60, zone: { nil })
        check(w1 == S.begin(.handle) && w2 == S.track(.handle) && wheel.idle(now: 0.2) == nil && wheel.idle(now: 0.45) == S.release(.handle) && !wheel.phased,
              "捲動下拉：一般滾輪沒有放開的訊號，停 0.3 秒當放開")   // l10n-ignore
        var wheel2 = ScrollPull()
        _ = wheel2.feed(now: 0, began: false, ended: false, momentum: false, hasPhase: false, dx: 0, dy: 60, zone: { nil })
        check(wheel2.feed(now: 0.1, began: false, ended: false, momentum: false, hasPhase: false, dx: 0, dy: 60, zone: { .handle }) == .notOurs
              && wheel2.feed(now: 1, began: false, ended: false, momentum: false, hasPhase: false, dx: 0, dy: 60, zone: { .handle }) == S.begin(.handle),
              "捲動下拉：滾輪連續捲的那一手照起手的位置算；停過之後才是新的一手")   // l10n-ignore
        // 命中區：跟按住拖同一份歸屬；錶面沒有把手
        check(HomeIndicator.owner(CGPoint(x: 512, y: 40), on: .app, pill: nil, inset: nil) == .indicator
              && HomeIndicator.owner(CGPoint(x: 512, y: 400), on: .app, pill: nil, inset: nil) == .shell
              && HomeIndicator.owner(CGPoint(x: 900, y: 40), on: .home, pill: nil, inset: nil) == .controlCenter
              && HomeIndicator.owner(CGPoint(x: 512, y: 40), on: .face, pill: nil, inset: nil) == .shell,
              "捲動下拉：命中區＝頂端中間的把手與右上角（HomeIndicator.owner）；清單中間、錶面頂端都不是")   // l10n-ignore

        // 次要按鈕：一律只打開選單，不直接執行動作
        typealias C = SecondaryClick
        let targets: [PointerTarget] = [.homeItem(key: "a:timers", widget: false), .homeItem(key: "w:1", widget: true), .libraryApp("timers"),
                                        .homeEmpty, .backButton, .face, .other]
        let menus = targets.map { C.menu(for: $0, canEdit: true, backGoesHome: false) }
        check(menus[0] == .item(key: "a:timers") && menus[1] == .item(key: "w:1") && menus[2] == .libraryApp("timers"),
              "次要按鈕：圖示、小工具上＝現在長按的那一份選單")   // l10n-ignore
        check(menus[3] == .pet(lead: [.editHome, .faceOverview]) && menus[5] == .pet(lead: [.faceOverview, .editHome]),
              "次要按鈕：主畫面空白處、錶面的選單含「編輯」「錶面總覽」")   // l10n-ignore
        check(menus[4] == .pet(lead: [.back, .home]) && C.menu(for: .backButton, canEdit: true, backGoesHome: true) == .pet(lead: [.home]),
              "次要按鈕：返回鈕的選單含「主畫面」；返回就是回主畫面時不重複列")   // l10n-ignore
        check(menus[6] == .pet(lead: []) && C.menu(for: .homeEmpty, canEdit: false, backGoesHome: false) == .pet(lead: [.faceOverview])
              && C.menu(for: .homeItem(key: "w:1", widget: true), canEdit: false, backGoesHome: false) == .pet(lead: [.faceOverview]),
              "次要按鈕：不能編輯時「編輯」那一項隱藏（不變灰）；其他地方是桌寵選單")   // l10n-ignore
        // Menu 這個型別沒有「執行」的分支：每一種結果都是一份選單（編譯器保證列舉到齊）
        check(menus.allSatisfy { m in switch m { case .item, .libraryApp, .pet: return true } }, "次要按鈕：每個位置的結果都只是一份選單，不直接執行動作")   // l10n-ignore

        // 重按：只在圖示與小工具上有反應
        check(ForceClick.action(for: .homeItem(key: "a:timers", widget: false)) == .preview(key: "a:timers")
              && ForceClick.action(for: .homeItem(key: "w:1", widget: true)) == .preview(key: "w:1")
              && ForceClick.action(for: .libraryApp("timers")) == .previewLibrary("timers"), "重按：圖示與小工具上＝預覽與選單")   // l10n-ignore
        check([PointerTarget.homeEmpty, .backButton, .face, .other].allSatisfy { ForceClick.action(for: $0) == .none },
              "重按：其他地方（空白、返回鈕、錶面、機身）不做事，不再進出 CarPlay")   // l10n-ignore
        check(ShellInput.forcePress(dragging: true, pressing: true) == .ignore, "重按：外殼手勢拖到一半照舊不理")   // l10n-ignore

        // 智慧縮放：目前大小 ⇄ 放大
        let z1 = SmartZoom.toggle(width: 300, restore: nil, maxWidth: 900)
        let z2 = SmartZoom.toggle(width: z1.to, restore: z1.restore, maxWidth: 900)
        check(z1.to == 480 && z2.to == 300 && z2.restore == nil, "智慧縮放：第一次放大，再一次回到原本的大小")   // l10n-ignore
        let z3 = SmartZoom.toggle(width: 400, restore: z1.restore, maxWidth: 900)
        check(z3.to == 640 && z3.restore?.from == 400, "智慧縮放：放大之後手動改過大小，就從新的大小重新算")   // l10n-ignore
        check(SmartZoom.toggle(width: 900, restore: nil, maxWidth: 900).to == 900 && SmartZoom.toggle(width: 700, restore: nil, maxWidth: 900).to == 900,
              "智慧縮放：不超過最大；已經最大就不動")   // l10n-ignore

        // 震動：只有三處、都能關、越過門檻才震
        typealias P = PointerHaptics
        check(P.Moment.allCases.count == 3 && P.crossesUp(from: 100, to: 115, threshold: HomeIndicator.commit)
              && !P.crossesUp(from: 115, to: 130, threshold: HomeIndicator.commit) && !P.crossesUp(from: 115, to: 100, threshold: HomeIndicator.commit),
              "震動：只留三處；下拉把手只在越過 commit 的那一格震（退回去不震、拉遠不連發）")   // l10n-ignore
        let suite = "homeplay.selftest.pointer"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        check(d.object(forKey: P.key) as? Bool ?? true, "震動：「觸覺回饋」預設開")   // l10n-ignore

        // 摸頭：來回四次以上（1.5 秒內）、冷卻 10 秒、按著鍵不算、不在頭頂不算
        func pat(_ p: inout HeadPat, from t0: Double, step: Double, swings: Int, onHead: Bool = true, down: Bool = false) -> (Bool, Double) {
            var t = t0, x: CGFloat = 100, hit = false
            _ = p.feed(x: x, now: t, onHead: onHead, buttonDown: down)
            for i in 0..<swings {
                x += i % 2 == 0 ? 30 : -30; t += step
                if p.feed(x: x, now: t, onHead: onHead, buttonDown: down) { hit = true }
            }
            return (hit, t)
        }
        var hp = HeadPat()
        let (three, _) = pat(&hp, from: 0, step: 0.1, swings: 3)
        var hp2 = HeadPat()
        let (four, tEnd) = pat(&hp2, from: 0, step: 0.1, swings: 4)
        check(!three && four, "摸頭：來回三次不算，四次才算")   // l10n-ignore
        let (again, _) = pat(&hp2, from: tEnd + 1, step: 0.1, swings: 6)
        let (later, _) = pat(&hp2, from: tEnd + HeadPat.cooldown + 0.1, step: 0.1, swings: 4)
        check(!again && later, "摸頭：之後 10 秒內不重複，過了才再算")   // l10n-ignore
        var slow = HeadPat(), held = HeadPat(), off = HeadPat()
        check(!pat(&slow, from: 0, step: 0.6, swings: 4).0 && !pat(&held, from: 0, step: 0.1, swings: 6, down: true).0
              && !pat(&off, from: 0, step: 0.1, swings: 6, onHead: false).0, "摸頭：超過 1.5 秒的慢慢來回、按著按鍵、不在頭頂都不算")   // l10n-ignore
        var tiny = HeadPat()
        var tinyHit = false
        for i in 0..<20 { if tiny.feed(x: 100 + (i % 2 == 0 ? 1 : -1), now: Double(i) * 0.05, onHead: true, buttonDown: false) { tinyHit = true } }
        check(!tinyHit && HeadPat.happyFor == 1.2, "摸頭：手抖的小晃動不算；開心表情 1.2 秒")   // l10n-ignore

        // 找游標：又快又大的來回才算搖
        func shake(_ s: inout CursorShake, swing: CGFloat, step: Double, n: Int) -> Bool {
            var x: CGFloat = 500, t = 0.0, hit = false
            _ = s.feed(x: x, now: t)
            for i in 0..<n {
                for _ in 0..<4 { x += (i % 2 == 0 ? swing : -swing) / 4; t += step / 4; if s.feed(x: x, now: t) { hit = true } }
            }
            return hit
        }
        var fast = CursorShake(), lazy = CursorShake(), small = CursorShake()
        check(shake(&fast, swing: 200, step: 0.1, n: 6) && !shake(&lazy, swing: 200, step: 0.6, n: 6) && !shake(&small, swing: 20, step: 0.05, n: 10),
              "找游標：又快又大的來回才算搖晃；慢慢移動、小幅抖動不算")   // l10n-ignore

        // 游標回饋：圖示 4%、只動縮放與不透明度、減少動態效果不縮放
        typealias H = PointerHover
        check(H.scale(level: 1, reduceMotion: false) == 1.04 && H.scale(level: 0, reduceMotion: false) == 1 && H.scale(level: 1, reduceMotion: true) == 1,
              "游標回饋：圖示放大 4%；減少動態效果時不做縮放")   // l10n-ignore
        check(H.level(since: 0, now: H.fade / 2) == 0.5 && H.level(since: 0, now: 1) == 1 && H.tint(onDark: true, level: 0).alphaComponent == 0
              && H.tint(onDark: true, level: 1).alphaComponent > 0 && H.tint(onDark: false, level: 1).whiteComponent == 0,
              "游標回饋：底色淡入淡出（深色底用白、淺色底用黑）")   // l10n-ignore
        let keep = (H.target, HPMotion.forceReduce)
        _ = H.set(nil, now: 0); _ = H.animating(10)
        let changed = H.set(.homeIcon("a:x"), now: 100)
        HPMotion.forceReduce = false
        let mid = H.homeIconScale("a:x", now: 100 + H.fade / 2), other = H.homeIconScale("a:y", now: 100 + H.fade / 2)
        _ = H.set(nil, now: 101)
        let out = H.homeIconScale("a:x", now: 101 + H.fade / 2)
        let gone = !H.animating(101 + H.fade * 2) && H.homeIconScale("a:x", now: 101 + H.fade * 2) == 1
        HPMotion.forceReduce = keep.1
        check(changed && abs(mid - 1.02) < 1e-9 && other == 1 && abs(out - 1.02) < 1e-9 && gone,
              "游標回饋：游標移上去 120 毫秒放大、移開 120 毫秒縮回；旁邊的圖示不動")   // l10n-ignore
        _ = H.set(keep.0, now: 0)
    }
}
