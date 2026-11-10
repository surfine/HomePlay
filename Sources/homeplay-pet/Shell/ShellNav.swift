// 2.0 外殼（主畫面、App、控制中心）的純邏輯：導覽狀態機與多組計時器。不碰 AppKit，--selftest 直接驗。
//
// 導覽照實機描述（研究：hv-research/handson.md）：
// - 錶面左右滑（滾輪、← →）換；最後一個錶面再往後一頁是主畫面；橫軸只有一條、不繞圈（2026-11-07 拍板）：
//   第一個錶面再往前＝橡皮筋（不到主畫面），主畫面再往後也不回錶面（往前回去才是最後一個錶面）；
// - 錶面上往上滑（螢幕底緣往上拖、↑）也到主畫面；主畫面再往上是「全部 App」；
// - 點 App 進去；Esc／↓／左上角關閉鈕／底緣往上拖都是回上一層；
// - 控制中心、ClioTalk 是蓋在任何畫面上的一層，先收掉它們，才輪到退回上一層；
// - 一段時間沒人靠近（idle）：全部收回錶面；
// - 👀 膠囊往下拉住停一下＝App 切換器（一個畫面，返回＝主畫面；Shell/AppSwitcher.swift）；
// - CarPlay 是一個 App（2026-11-06）：CarPlay 畫面在前面＝CarPlay App 在前面，回主畫面時會話留在背景。

import Foundation

enum ShellScreen: Equatable {
    case face
    case home
    case library            // 全部 App（主畫面再往上滑）
    case switcher           // App 切換器（膠囊往下拉住停一下）
    case app(String)

    var coversFace: Bool { self != .face }
}

enum ShellOverlay: Equatable { case none, controlCenter, clioTalk }

struct ShellNav: Equatable {
    var screen: ShellScreen = .face
    var overlay: ShellOverlay = .none
    /// App 從哪裡開的：關掉時回那裡（主畫面或全部 App）
    var appReturn: ShellScreen = .home

    enum Event: Equatable {
        case page(Int)              // +1 往後一頁（下一個錶面），-1 往前
        case up                     // 往上滑／↑
        case back                   // Esc／↓／關閉鈕／往下滑
        case openApp(String)
        case openControlCenter
        case toggleControlCenter
        case openClioTalk
        case openSwitcher           // 膠囊往下拉住停一下
        case idle                   // 沒人靠近太久
        case carPlay                // CarPlay 畫面進來（＝CarPlay App 到前面）
    }

    /// 離開 CarPlay 的起點（carPlayToHome）：CarPlay App 在前面、返回＝來的地方——👀 下拉、空白鍵、選單「退出 CarPlay」、重按同一個終點
    static let carPlayExit = ShellNav(screen: .app(CarPlayApp.id), overlay: .none, appReturn: .home)
    /// 退出 CarPlay 要回到哪裡（2026-11-09 使用者「從哪進，回到哪」）：
    /// 從資料庫／主畫面／錶面／某個 App 進來的都回原處；CarPlay App 圖示開的照 appReturn；
    /// 切換器是暫時層，回主畫面。
    static func carPlayReturn(from screen: ShellScreen, appReturn: ShellScreen) -> ShellScreen {
        switch screen {
        case .library: return .library
        case .home: return .home
        case .face: return .face
        case .app(CarPlayApp.id): return appReturn
        case .app: return screen
        case .switcher: return .home
        }
    }

    /// handled＝這個事件被外殼吃掉（呼叫端不要再做原本的事）；face＝要換到第幾個錶面（nil 不換）
    struct Result: Equatable {
        var handled: Bool
        var face: Int?
        static let ignored = Result(handled: false, face: nil)
        static let done = Result(handled: true, face: nil)
    }

    /// faceIndex／faceCount：目前錶面在陣容裡的位置與陣容大小
    mutating func handle(_ e: Event, faceIndex: Int, faceCount: Int) -> Result {
        let last = max(0, faceCount - 1)
        switch e {
        case .idle:
            let changed = overlay != .none || screen != .face
            overlay = .none; screen = .face
            return Result(handled: changed, face: nil)
        case .carPlay:
            let want = ShellScreen.app(CarPlayApp.id)
            let changed = overlay != .none || screen != want
            if screen != want { appReturn = screen == .switcher ? .home : screen }   // 從哪進回哪（切換器是暫時層：回主畫面）
            overlay = .none; screen = want
            return Result(handled: changed, face: nil)
        case .openSwitcher:
            overlay = .none; screen = .switcher; return .done
        case .openControlCenter:
            overlay = .controlCenter; return .done
        case .toggleControlCenter:
            overlay = overlay == .controlCenter ? .none : .controlCenter; return .done
        case .openClioTalk:
            overlay = .clioTalk; return .done
        case .openApp(let id):
            // 從哪進回哪：主畫面／資料庫／錶面／另一個 App 都記住；切換器是暫時層，關掉回主畫面。
            // 同一個 App 再開一次不動返回點（免得自己回自己）。
            if case .app(let cur) = screen, cur == id {} else { appReturn = screen == .switcher ? .home : screen }
            overlay = .none; screen = .app(id); return .done
        case .back:
            if overlay != .none { overlay = .none; return .done }
            switch screen {
            case .app: screen = appReturn; return .done
            case .library, .switcher: screen = .home; return .done
            case .home: screen = .face; return .done
            case .face: return .ignored            // 錶面上的 Esc 照舊（收提示、退出直播）
            }
        case .up:
            if overlay == .controlCenter { overlay = .none; return .done }   // 控制中心「往上推收起」
            if overlay != .none { return .done }
            switch screen {
            case .face: screen = .home; return .done
            case .home: screen = .library; return .done
            case .library, .app, .switcher: return .done
            }
        case .page(let d):
            guard d != 0 else { return .ignored }
            if overlay != .none { return .done }    // 有一層蓋著：不換頁
            switch screen {
            case .face:
                // 只有出陣容尾端往前（d > 0）才到主畫面；第一個再往回（d < 0）＝橡皮筋：吃掉、不動（不繞到主畫面）。
                // 中間的換錶面交回原本的路
                if d > 0 && faceIndex >= last { screen = .home; return .done }
                if d < 0 && faceIndex <= 0 { return .done }
                return .ignored
            case .home:
                // 主畫面往回＝陣容最後一個錶面（它就在左邊）；往前不繞回第一個錶面
                guard d < 0 else { return .done }
                screen = .face
                return Result(handled: true, face: last)
            case .library, .app, .switcher:
                return .done
            }
        }
    }
}

// MARK: - 多組計時器
// 錶面本身只有一個計時器（Face.timerEnd：島長成倒數膠囊、到點橫幅、番茄鐘也用它）。
// 這本帳記所有使用者開的計時器（牆上時間，Mac 睡眠也準）；最快到點的那一個「鏡射」到錶面的計時器，
// 膠囊與橫幅就照舊。番茄鐘在跑時錶面計時器歸番茄鐘，帳裡的計時器不鏡射，到點由外殼自己出橫幅。

struct ShellTimer: Equatable, Codable {
    let id: Int
    var label: String
    var total: Double
    var end: Double           // 牆上時間（timeIntervalSinceReferenceDate）
    /// 2.0 時鐘：暫停中＝停住時還剩幾秒（nil＝在跑）；暫停的不會到點、不鏡射到錶面
    var pausedLeft: Double? = nil
    var paused: Bool { pausedLeft != nil }
    func left(_ now: Double) -> Double { pausedLeft ?? max(0, end - now) }
    func fraction(_ now: Double) -> Double { total > 0 ? min(1, left(now) / total) : 0 }
}

struct TimerBook: Equatable {
    private(set) var timers: [ShellTimer] = []
    private var nextID = 1
    init() {}
    /// 2.0 depth：從存檔接回來（關掉 HomePlay、更新、當掉都不丟計時器；早就到點的不再響）
    init(restoring saved: [ShellTimer], now: Double) {
        timers = saved.filter { $0.paused || $0.end > now - 60 }
        nextID = (timers.map(\.id).max() ?? 0) + 1
    }
    /// 目前鏡射到錶面的那一個（id）
    var mirrored: Int?

    @discardableResult
    mutating func add(seconds: Double, label: String, now: Double, total: Double? = nil) -> Int {
        let id = nextID; nextID += 1
        timers.append(ShellTimer(id: id, label: label, total: max(1, total ?? seconds, seconds), end: now + max(1, seconds)))
        return id
    }
    mutating func remove(_ id: Int) {
        timers.removeAll { $0.id == id }
        if mirrored == id { mirrored = nil }
    }
    mutating func addTime(_ id: Int, seconds: Double) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[i].end += seconds; timers[i].total += seconds
        if let p = timers[i].pausedLeft { timers[i].pausedLeft = p + seconds }
    }
    /// 2.0 時鐘：暫停／繼續（繼續時從剩下的秒數重新算到點時刻）
    mutating func pause(_ id: Int, now: Double) {
        guard let i = timers.firstIndex(where: { $0.id == id }), timers[i].pausedLeft == nil else { return }
        timers[i].pausedLeft = max(0, timers[i].end - now)
        if mirrored == id { mirrored = nil }
    }
    mutating func resume(_ id: Int, now: Double) {
        guard let i = timers.firstIndex(where: { $0.id == id }), let p = timers[i].pausedLeft else { return }
        timers[i].end = now + p; timers[i].pausedLeft = nil
    }
    /// 到點的拿出來（照到點先後），帳裡只留還在跑的
    mutating func expire(now: Double) -> [ShellTimer] {
        let done = timers.filter { !$0.paused && $0.end <= now }.sorted { $0.end < $1.end }
        timers.removeAll { !$0.paused && $0.end <= now }
        if let m = mirrored, !timers.contains(where: { $0.id == m }) { mirrored = nil }
        return done
    }
    /// 最快到點的（膠囊、Live Activity 顯示它）
    var primary: ShellTimer? { timers.filter { !$0.paused }.min { $0.end < $1.end } }
    /// 依到點先後排好的全部（暫停的排在在跑的後面）
    var sorted: [ShellTimer] { timers.sorted { ($0.paused ? 1 : 0, $0.end) < ($1.paused ? 1 : 0, $1.end) } }
    func timer(_ id: Int) -> ShellTimer? { timers.first { $0.id == id } }
    var isEmpty: Bool { timers.isEmpty }
}

// MARK: - 自檢（main.swift 的 --selftest 呼叫）

enum ShellSelfTest {
    /// 輸入與導覽的防回歸（2026-11-07 審查）：重播後不殘留換頁、取消走各自的收尾、重按不打斷手勢、切換器沒有左緣返回
    static func inputGuards(_ check: (Bool, String) -> Void) {
        typealias S = ShellInput
        // 膠囊上斜拖交回轉身體之後，下一下（控制中心、CarPlay）不能繼承那次的換頁
        let saved = (FacePaging.drag, S.replayed, S.claimed)
        FacePaging.drag = FacePaging.Drag(at: .zero, uv: CGPoint(x: 0.5, y: 0.05), fromStyle: FaceStyle.lineup.first ?? .island, fromNav: ShellNav())
        S.replayed = true; S.claimed = true
        check(S.beginPress() && !S.replayed && !S.claimed && S.down == nil,
              "外殼：新的一下開始時清掉上一下的重播與接住，還掛著的換頁要先收（控制中心橫拖不換錶面、CarPlay 放手送得到）")   // l10n-ignore
        (FacePaging.drag, S.replayed, S.claimed) = saved
        // 取消（兩指接手、系統收走觸控）：每一種拖動走自己的收尾
        check(S.cancelSteps(kind: .indicator, claimed: true, indicatorPulling: true, facePaging: false, sbPressing: false, ccDragging: false) == [.indicator]
              && S.cancelSteps(kind: nil, claimed: false, indicatorPulling: false, facePaging: true, sbPressing: false, ccDragging: false) == [.facePage]
              && S.cancelSteps(kind: nil, claimed: false, indicatorPulling: false, facePaging: false, sbPressing: true, ccDragging: false) == [.springBoard]
              && S.cancelSteps(kind: .cc(slider: nil), claimed: false, indicatorPulling: false, facePaging: false, sbPressing: false, ccDragging: false) == [.controlCenter]
              && S.cancelSteps(kind: .edgeTop(cc: true), claimed: true, indicatorPulling: false, facePaging: false, sbPressing: false, ccDragging: true) == [.controlCenter]
              && S.cancelSteps(kind: .edgeTop(cc: true), claimed: false, indicatorPulling: false, facePaging: false, sbPressing: false, ccDragging: false).isEmpty
              && S.cancelSteps(kind: .switcher, claimed: true, indicatorPulling: false, facePaging: false, sbPressing: false, ccDragging: false) == [.switcher]
              && S.cancelSteps(kind: .tap, claimed: false, indicatorPulling: false, facePaging: false, sbPressing: false, ccDragging: false).isEmpty,
              "外殼：手勢被取消時膠囊彈回、錶面退回、主畫面回最近一頁、控制中心照落點收、切換器放回，點按不當點按")   // l10n-ignore
        // 重按：拖到一半不進出 CarPlay；按著沒動＝先收掉這一下（放手不再點到東西）
        check(S.forcePress(dragging: true, pressing: true) == .ignore && S.forcePress(dragging: false, pressing: true) == .cancelPressThenEnter
              && S.forcePress(dragging: false, pressing: false) == .enter,
              "外殼：拖曳中重按不在手勢中間進出 CarPlay；按著沒動的那一下先收掉再進出")   // l10n-ignore
        // 手勢總表：切換器上沒有左緣返回（同 iOS）；App 上左緣右滑＝返回、系統關掉觸控滑動切換頁面時不做
        let edge = CGPoint(x: 0.03, y: 0.5)
        check(S.kind(owner: .shell, screen: .switcher, uv: edge, backAllowed: true) == .switcher
              && S.kind(owner: .shell, screen: .app("timers"), uv: edge, backAllowed: true) == .edgeLeft
              && S.kind(owner: .shell, screen: .app("timers"), uv: edge, backAllowed: false) == .tap
              && S.kind(owner: .indicator, screen: .switcher, uv: CGPoint(x: 0.5, y: 0.1), backAllowed: true) == .indicator
              && S.kind(owner: .shell, screen: .face, uv: CGPoint(x: 0.5, y: 0.5), backAllowed: true) == nil,
              "外殼：切換器上沒有左緣返回（整面歸切換器），App 上左緣右滑＝返回；膠囊在切換器上照舊")   // l10n-ignore
        // 2026-11-07 六項拍板：錶面左緣右滑＝一般換錶面（錶面是最上層，沒有返回）——左緣起手跟中間起手歸同一條路
        check(S.kind(owner: .shell, screen: .face, uv: edge, backAllowed: true) == S.kind(owner: .shell, screen: .face, uv: CGPoint(x: 0.5, y: 0.5), backAllowed: true)
              && S.kind(owner: .shell, screen: .face, uv: edge, backAllowed: true) == nil && S.kind(owner: .shell, screen: .home, uv: edge, backAllowed: true) == .edgeLeft,
              "六項·錶面左緣：不再當返回接住，跟中間起手一樣交給錶面換頁；主畫面的左緣照舊")   // l10n-ignore
        // 主畫面第一頁往右翻過頭＝回錶面：跟換頁同一套投射判定（四捨五入到 −1 頁），不到就彈回；別頁、資源庫、編輯模式不算
        check(SB.leavesToFace(fromPage: 0, projected: -0.6, screen: .home, editing: false) && !SB.leavesToFace(fromPage: 0, projected: -0.4, screen: .home, editing: false)
              && !SB.leavesToFace(fromPage: 1, projected: -0.6, screen: .home, editing: false) && !SB.leavesToFace(fromPage: 0, projected: -0.9, screen: .library, editing: false)
              && !SB.leavesToFace(fromPage: 0, projected: -0.9, screen: .home, editing: true),
              "六項·主畫面第一頁往右：過半頁（含甩）回錶面、不到彈回；資源庫與編輯模式不受影響")   // l10n-ignore
        // 鍵盤模型：CarPlay 畫面＝車上旋鈕
        typealias K = CarPlayKnobKeys
        check(K.command(keyCode: 123, shift: false) == "left" && K.command(keyCode: 124, shift: false) == "right"
              && K.command(keyCode: 126, shift: false) == "up" && K.command(keyCode: 125, shift: false) == "down"
              && K.command(keyCode: 48, shift: false) == "cw" && K.command(keyCode: 48, shift: true) == "ccw"
              && K.command(keyCode: 36, shift: false) == "select" && K.command(keyCode: 76, shift: false) == "select" && K.command(keyCode: 53, shift: false) == "back"
              && K.command(keyCode: 49, shift: false) == nil && K.command(keyCode: 8, shift: false) == nil,
              "六項·鍵盤：CarPlay 上方向鍵＝搖桿、Tab／⇧Tab＝轉動、Return＝選取、Esc＝返回；空白鍵不是旋鈕（＝👀）")   // l10n-ignore
        check(["left", "right", "up", "down", "cw", "ccw"].allSatisfy(K.repeats) && !K.repeats("select") && !K.repeats("back"),
              "六項·鍵盤：按住方向鍵、Tab 照鍵重複一直送；選取、返回只送一次")   // l10n-ignore
        // 待決項拍板（2026-11-07）
        var exit = ShellNav.carPlayExit
        check(exit.handle(.back, faceIndex: 0, faceCount: 10).handled && exit == ShellNav(screen: .home, overlay: .none, appReturn: .home),
              "待決·離開 CarPlay：👀、空白鍵、選單「退出 CarPlay」、重按都落在主畫面（不是錶面）")   // l10n-ignore
        // 2026-11-09 使用者：「從哪進，回到哪」——資料庫／主畫面／錶面／App 都回原處；切換器例外回主畫面
        check(ShellNav.carPlayReturn(from: .library, appReturn: .home) == .library
              && ShellNav.carPlayReturn(from: .home, appReturn: .home) == .home
              && ShellNav.carPlayReturn(from: .face, appReturn: .home) == .face
              && ShellNav.carPlayReturn(from: .app("weather"), appReturn: .home) == .app("weather")
              && ShellNav.carPlayReturn(from: .app(CarPlayApp.id), appReturn: .library) == .library
              && ShellNav.carPlayReturn(from: .app(CarPlayApp.id), appReturn: .home) == .home
              && ShellNav.carPlayReturn(from: .switcher, appReturn: .home) == .home,
              "離開 CarPlay：從哪進回哪（切換器回主畫面）")   // l10n-ignore
        // App 的返回點同樣是「從哪進回哪」：App 開 App 回上一個 App、錶面開的回錶面、切換器開的回主畫面
        var chain = ShellNav(screen: .app("weather"))
        _ = chain.handle(.openApp("timers"), faceIndex: 0, faceCount: 12)
        var fromFace = ShellNav(screen: .face)
        _ = fromFace.handle(.openApp("weather"), faceIndex: 0, faceCount: 12)
        var fromSwitcher = ShellNav(screen: .switcher)
        _ = fromSwitcher.handle(.openApp("weather"), faceIndex: 0, faceCount: 12)
        check(chain.screen == .app("timers") && chain.appReturn == .app("weather")
              && fromFace.appReturn == .face && fromSwitcher.appReturn == .home,
              "從哪進回哪：App→App 回上一個、錶面開的回錶面、切換器開的回主畫面")   // l10n-ignore
        check(AppSwitcher.content(hasShot: true, locked: true) == .needsOwner && AppSwitcher.content(hasShot: false, locked: true) == .needsOwner
              && AppSwitcher.content(hasShot: true, locked: false) == .shot && AppSwitcher.content(hasShot: false, locked: false) == .icon,
              "待決·切換器：門關著的 App 不給最後一格，只畫圖示＋「需要主人」")   // l10n-ignore
        check([48, 123, 124, 125, 126].allSatisfy { ShellAccessibility.summonsFocus(UInt16($0)) } && !ShellAccessibility.summonsFocus(49) && !ShellAccessibility.summonsFocus(36),
              "待決·鍵盤導航：Tab 或方向鍵叫出焦點框，空白鍵與 Return 不叫（設定文案同）")   // l10n-ignore
    }

    /// 手勢語法（2026-11-07 拍板，docs/plans/gestures.md）：螢幕是內容、第一下只喚醒、慣性中按下只停、兩指旋轉與捏合互斥
    static func gestureGrammar(_ check: (Bool, String) -> Void) {
        typealias S = ShellInput
        // 1. 螢幕是內容、機身是物件：觸控板兩指滑在螢幕上起手不轉身體（直播時歸 CarPlay），機身上才轉；單指拖同一張表
        check(GestureTarget.route(onScreen: true, onBody: true, live: false) == .none && GestureTarget.route(onScreen: true, onBody: true, live: true) == .carplay
              && GestureTarget.route(onScreen: false, onBody: true, live: false) == .rotate && GestureTarget.route(onScreen: false, onBody: false, live: false) == .none
              && TouchRoute.singleFinger(.screen, live: false) == .shell && TouchRoute.singleFinger(.body, live: false) == .rotate,
              "語法·螢幕是內容：螢幕上的拖（單指、兩指）歸畫面不轉身體，拖機身才轉；直播時螢幕歸 CarPlay")   // l10n-ignore
        // 5 前半：沒在互動時第一下只喚醒
        check(S.wakeSwallows(asleep: true, poster: false, dim: 0, onScreen: true, live: false, exempt: false)
              && S.wakeSwallows(asleep: false, poster: true, dim: 0, onScreen: true, live: false, exempt: false)
              && S.wakeSwallows(asleep: false, poster: false, dim: 0.45, onScreen: true, live: false, exempt: false)
              && !S.wakeSwallows(asleep: false, poster: false, dim: 0, onScreen: true, live: false, exempt: false)
              && !S.wakeSwallows(asleep: true, poster: true, dim: 0.45, onScreen: false, live: false, exempt: false)
              && !S.wakeSwallows(asleep: true, poster: false, dim: 0, onScreen: true, live: true, exempt: false)
              && !S.wakeSwallows(asleep: true, poster: true, dim: 0.45, onScreen: true, live: false, exempt: true),
              "語法·第一下只喚醒：休眠、海報期、變暗時按在螢幕上只喚醒；活躍、拖機身、CarPlay 直播、豁免項照常")   // l10n-ignore
        // 5 後半：慣性中按下只停
        check(S.pressStopsCoast(sinceMomentum: 0.05, springCoasting: false) && S.pressStopsCoast(sinceMomentum: 99, springCoasting: true)
              && !S.pressStopsCoast(sinceMomentum: 0.5, springCoasting: false) && !S.pressStopsCoast(sinceMomentum: -1, springCoasting: false),
              "語法·慣性中碰一下：剛有慣性事件或清單彈簧還在滑＝只停住；停穩之後的按下照常點")   // l10n-ignore
        let saved = (S.coastStopped, S.replayed, S.claimed, S.down == nil, FacePaging.drag == nil)
        S.coastStopped = true
        _ = S.beginPress()
        check(!S.coastStopped, "語法·慣性中碰一下：停住只管那一下，下一下照常")   // l10n-ignore
        S.coastStopped = saved.0; S.replayed = saved.1; S.claimed = saved.2
        // 3. 兩指旋轉與捏合互斥：先超過門檻者勝，之後另一個怎麼動都不改
        var lock = TwoFingerLock()
        _ = lock.feed(scale: 0.02, angle: 0.03)
        let undecided = lock.kind == .undecided
        _ = lock.feed(angle: 0.12)
        let rot = lock.kind == .rotate
        _ = lock.feed(scale: 0.5)
        check(undecided && rot && lock.kind == .rotate, "語法·兩指：轉過 8° 先到＝旋轉，之後指距怎麼變都不縮放")   // l10n-ignore
        lock.reset()
        _ = lock.feed(scale: 0.03, angle: 0.02); _ = lock.feed(scale: 0.02)
        let pinch = lock.kind == .pinch
        _ = lock.feed(angle: 1.0)
        check(pinch && lock.kind == .pinch, "語法·兩指：縮放 4% 先到＝捏合，之後帶多少扭轉都不轉身")   // l10n-ignore
        lock.reset()
        check(lock.kind == .undecided && TouchRoute.rotationAccepts(.screen, live: false) && TouchRoute.rotationAccepts(.body, live: true)
              && !TouchRoute.rotationAccepts(.screen, live: true), "語法·兩指旋轉：整個桌寵都收（同捏合），CarPlay 直播的螢幕上不收")   // l10n-ignore
        check(TwistYaw.delta(radians: 0.3) == -0.3 && TwistYaw.release(velocity: 2, sinceLastMove: 0.01, reduceMotion: false) == 0.4
              && TwistYaw.release(velocity: 2, sinceLastMove: 0.01, reduceMotion: true) == 0 && TwistYaw.release(velocity: 2, sinceLastMove: 0.2, reduceMotion: false) == 0
              && TwistYaw.release(velocity: 100, sinceLastMove: 0, reduceMotion: false) == .pi,
              "語法·兩指旋轉：1:1 跟手；放手帶慣性（最多半圈），停住才放或減少動態效果＝直接停")   // l10n-ignore
        // 觸控板：純扭轉判成 twist（轉身），不是捏合也不是滑動
        var c = TwoFingerClassifier()
        _ = c.feed(id0: 1, x0: 0.40, y0: 0.50, id1: 2, x1: 0.55, y1: 0.50)
        check(c.feed(id0: 1, x0: 0.40, y0: 0.488, id1: 2, x1: 0.55, y1: 0.512) == .twist, "語法·觸控板：兩指反向繞著轉＝扭轉（轉身），不縮放")   // l10n-ignore
    }

    static func run(_ check: (Bool, String) -> Void) {
        EdgeContainers.selfTest(check)   // 圓角同心：貼邊容器登記表（Design/EdgeContainers.swift）
        IntroGuide.selftest(check)   // 開場手勢引導：頁序、輸入方式選字、出現時機、略過與鍵盤、減少動態效果（Intro/IntroGuide.swift）
        IntroScreenSelfTest.run(check)   // 手勢引導的畫面：easing、字卡同心、靜態版（Intro/IntroScreen.swift）
        GlyphGlassSelfTest.run(check)   // SDF 玻璃字（實驗）：路由、四種底的高光方向、位移單調、增加對比＝實色（Faces/GlyphGlass.swift）
        LiquidOrbSelfTest.run(check)   // ClioTalk 水滴：深淺透明度互換、邊緣光、空閒不逐幀、減少動態效果（Faces/Capsule.swift）
        TouchSelfTest.run(check)   // 觸控：落點分區、判定區外擴、橫直判定、眼神、捏合不重複（Shell/TouchInput.swift）
        // 導覽：十個錶面，最後一個再往後＝主畫面，主畫面往後＝第一個錶面
        var n = ShellNav()
        check(n.handle(.page(1), faceIndex: 3, faceCount: 10) == .ignored && n.screen == .face, "外殼：中間的錶面換頁交回原本的路")
        check(n.handle(.page(1), faceIndex: 9, faceCount: 10) == .done && n.screen == .home, "外殼：最後一個錶面往後是主畫面")
        check(n.handle(.page(1), faceIndex: 9, faceCount: 10) == .done && n.screen == .home, "外殼：主畫面往後不繞回第一個錶面")   // l10n-ignore
        check(n.handle(.page(-1), faceIndex: 0, faceCount: 10).face == 9 && n.screen == .face, "外殼：主畫面往前回最後一個錶面")
        check(n.handle(.page(-1), faceIndex: 0, faceCount: 10) == .done && n.screen == .face, "外殼：第一個錶面再往前＝橡皮筋，不到主畫面（橫軸不繞圈）")   // l10n-ignore
        check(FacePaging.neighbor(dir: -1, index: 0, count: 10) == .none && FacePaging.neighbor(dir: 1, index: 9, count: 10) == .home
              && FacePaging.neighbor(dir: -1, index: 3, count: 10) == .face(2) && FacePaging.neighbor(dir: 1, index: 0, count: 1) == .home,
              "外殼：錶面跟手換頁的頭尾——第一個往右拖是橡皮筋，最後一個往左拖到主畫面")   // l10n-ignore
        // 往上：錶面 → 主畫面 → 全部 App；開 App 再回去回到原處
        _ = n.handle(.up, faceIndex: 0, faceCount: 10)
        _ = n.handle(.up, faceIndex: 0, faceCount: 10)
        check(n.screen == .library, "外殼：主畫面再往上是全部 App")
        _ = n.handle(.openApp("timers"), faceIndex: 0, faceCount: 10)
        check(n.screen == .app("timers"), "外殼：點 App 打開")
        _ = n.handle(.back, faceIndex: 0, faceCount: 10)
        check(n.screen == .library, "外殼：關 App 回到開它的地方")
        _ = n.handle(.back, faceIndex: 0, faceCount: 10); _ = n.handle(.back, faceIndex: 0, faceCount: 10)
        check(n.screen == .face && n.handle(.back, faceIndex: 0, faceCount: 10) == .ignored, "外殼：錶面上的 Esc 交回原本的路")
        // 控制中心蓋在上面：先收它；它開著不換頁
        _ = n.handle(.up, faceIndex: 0, faceCount: 10)
        _ = n.handle(.openControlCenter, faceIndex: 0, faceCount: 10)
        check(n.handle(.page(1), faceIndex: 0, faceCount: 10) == .done && n.screen == .home && n.overlay == .controlCenter, "外殼：控制中心開著不換頁")
        _ = n.handle(.back, faceIndex: 0, faceCount: 10)
        check(n.overlay == .none && n.screen == .home, "外殼：Esc 先收控制中心")
        _ = n.handle(.toggleControlCenter, faceIndex: 0, faceCount: 10)
        _ = n.handle(.openApp("timers"), faceIndex: 0, faceCount: 10)
        check(n.overlay == .none && n.screen == .app("timers"), "外殼：控制中心的計時器磚打開計時器")
        check(n.handle(.idle, faceIndex: 0, faceCount: 10).handled && n.screen == .face, "外殼：沒人靠近回錶面")
        check(!n.handle(.idle, faceIndex: 0, faceCount: 10).handled, "外殼：已在錶面時 idle 不重畫")
        _ = n.handle(.openApp("worldclock"), faceIndex: 0, faceCount: 10)
        _ = n.handle(.openClioTalk, faceIndex: 0, faceCount: 10)
        check(n.handle(.carPlay, faceIndex: 0, faceCount: 10).handled && n.screen == .app(CarPlayApp.id) && n.overlay == .none, "外殼：CarPlay 畫面優先（收掉疊層，CarPlay App 在前面）")
        inputGuards(check)
        gestureGrammar(check)

        // 計時器：兩組同時跑，最快到點的是主要那個；到點照先後拿出來
        var b = TimerBook()
        let a = b.add(seconds: 300, label: "a", now: 1000)
        let c = b.add(seconds: 60, label: "c", now: 1000)
        check(b.primary?.id == c && b.sorted.map(\.id) == [c, a], "計時器：最快到點的在前")
        b.addTime(c, seconds: 600)
        check(b.primary?.id == a && b.timer(c)?.total == 660, "計時器：加時間會重排")
        b.mirrored = a
        check(b.expire(now: 1299).isEmpty && b.timers.count == 2, "計時器：還沒到不拿出")
        let done = b.expire(now: 1300)
        check(done.map(\.id) == [a] && b.mirrored == nil && b.primary?.id == c, "計時器：到點拿出、鏡射清掉")
        check(abs((b.timer(c)?.fraction(1000 + 330) ?? 0) - 0.5) < 1e-9, "計時器：剩餘比例")
        b.remove(c)
        check(b.isEmpty && b.primary == nil, "計時器：停掉")
        MotionSelfTest.run(check)   // 2.0 R14：彈簧、投射、rubber band（Design/HPMotion.swift）
        HPSelfTest.run(check)       // HPDS（Design/）
        HVTruthSelfTest.run(check)   // HomeView 對齊：Look 與狀態色實測值（Design/HVTruth.swift）
        HPIconPressSelfTest.run(check); SBLayoutSelftest.run(check)   // 圖示按壓動效、無 Dock 的主畫面版面（Design/HPIconPress.swift、Shell/SpringBoard/SBSelftest.swift）
        SBLibraryPageSelftest.run(check)   // App 資源庫＝最後一頁再往後一格（Shell/SpringBoard/SBSelftest.swift）
        SBLibraryCategorySelfTest.run(check)   // App 資料庫的分類、空類別、搜尋順序（Shell/SpringBoard/SBLibraryCategories.swift）
        SBOwnerSelftest.run(check)   // 主畫面排列存到排列的主人名下，途中換人不蓋掉別人的（Shell/SpringBoard/SBSelftest.swift）
        SBFloatySelftest.run(check)   // 浮動資料夾：分頁、拖放目標、翻頁帶（Shell/SpringBoard/SBFloatyFolder.swift）
        HomeWallpaperSelfTest.run(check)   // 體驗追趕 P4-3：主畫面桌布的照片來源（Shell/HomeWallpaper.swift）
        CameraTimelineSelfTest.run(check)   // 體驗追趕 P4：攝影機近況時間軸（Shell/CameraTimeline.swift）
        NowPlayingHandoffSelfTest.run(check)   // 體驗追趕 P4：正在播放控制權交接判定（Shell/Apps/NowPlayingPage.swift）
        HPMaterialSelfTest.run(check)   // 體驗追趕 P3：材質 token 表與控制中心的 luma 自適應（Design/HPMaterial.swift）
        HPNumeralGlassSelfTest.run(check)   // 體驗追趕 P1：玻璃大數字的實色退路與染色微調（Design/HPNumeralGlass.swift）
        HPIconGlassSelfTest.run(check)   // 體驗追趕 P0：圖示玻璃參數、融合分組、主體對比（Design/HPIconGlass.swift）
        HPLookSelfTest.run(check)   // HomeView 對齊 WP2：Look 登記處（Shell/HPLook.swift）
        PosterConfigurationSelfTest.run(check)
        NumeralsSelfTest.run(check)
        AmbientPosterStylesSelfTest.run(check)   // 錶面體系：月視圖與家庭版式的版面（Shell/AmbientPosterStyles.swift）   // 錶面體系：數字系統映射、跟隨 Locale、字體覆蓋退回（Faces/Typography.swift）   // 錶面體系：海報配置 schema、出廠預設、--poster、舊偏好遷移（Shell/PosterConfiguration.swift）
        HPMotionVariantSelfTest.run(check)   // HomeView 對齊後續 #5：動效變體解析層（Design/HPMotionVariant.swift）
        DisplayStageSelfTest.run(check)   // HomeView 對齊 WP3：三段顯示狀態機（Shell/DisplayStage.swift）
        AmbientPosterSelfTest.run(check)   // HomeView 對齊後續 #1／#6：Ambient 海報版面與輪播（Shell/AmbientPoster.swift；之前漏掛）
        BackSwipeSelfTest.run(check)   // HomeView 對齊後續 #2／#8：返回手勢判定與手感參數（Shell/BackSwipe.swift；之前漏掛）
        PortalSlideSelfTest.run(check)   // HomeView 對齊後續 #7：橫滑換頁的 Portal 純邏輯（Faces/ScreenGeometry.swift）
        PhoneAppsSelfTest.run(check)   // iPhone 的 CarPlay App：URL scheme 挑法、上主畫面的條件（Shell/AppPlatform/PhoneApps.swift）
        AirDropSelftest.run(check)   // AirDrop：收件判斷、卡片、訪客臨時接收、分享（Shell/AirDrop/）
        ReceiverRecoverySelfTest.run(check)   // 接收端連不上時只強制重啟 launchd 作業、一分鐘一次（ReceiverAgent.swift）
        AirDropCarPlaySelftest.run(check)   // CarPlay 連著時的 AirDrop 對策：傳給自己（Shell/AirDrop/AirDropSelfMessage.swift）
        HomeIndicatorSelfTest.run(check)   // 👀 膠囊兼任 Home Indicator：距離／速度／停頓判定、CarPlay 上的位置與手勢歸屬（Shell/HomeIndicator.swift）
        AppSwitcherSelfTest.run(check)   // App 切換器與 CarPlay App：卡片、背景中的 CarPlay、導覽（Shell/AppSwitcher.swift）
        HomeAlertsSelfTest.run(check)   // HomeView 對齊 WP5／#3：家庭警報觸發、去重、快照轉移（Shell/HomeAlerts.swift；之前漏掛）
        let near = [CGRect(x: 0, y: 0, width: 88, height: 88), CGRect(x: 100, y: 0, width: 88, height: 88)], far = [near[0], CGRect(x: 120, y: 0, width: 88, height: 88)]
        check(HPGlass.needsMerge(near) && !HPGlass.needsMerge(far), "玻璃：相距小於 24 px 才融合")
        check(Shell.greeting(hour: 8).count >= 1 && Shell.greeting(hour: 8)[0] == Shell.greeting(hour: 8)[0].uppercased(), "主畫面：問候語全大寫")
        AppsSelfTest.run(check)   // 2.0: 闹钟、天气、日历、提醒事项的純邏輯
        RecipeSelfTest.run(check)   // 食譜 App：JSON-LD、時間、份量（Shell/Apps/RecipeParser.swift）
        MusicSelfTest.run(check)    // 音樂 App：資料庫輸出解析
        SingSelfTest.run(check)     // 功能補齊：跟唱的逐字時間（Shell/Apps/SingApp.swift）
        HomeClimateSelfTest.run(check)   // 功能補齊：家庭 App 溫控頁的模式與旋鈕（Shell/HomeClimate.swift）
        GamesSelfTest.run(check); ContactsSelfTest.run(check)   // 功能補齊：遊戲的掃描、通訊錄的分組與 FaceTime 號碼（Shell/Apps/GamesApp.swift、ContactsApp.swift）
        SideShowSelfTest.run(check)   // SideShow 副屏、桌面小工具、CarPlay 小工具頁探驗（SideShow/SideShowSelfTest.swift）
        MetricsSelfTest.run(check)  // 2.0 D1 儀表：警示門檻、格式、平滑、取樣器（Metrics/）
        SetupFlow.selftest(check)
        FamilyProfiles.selftest(check)   // 2.0 家人檔案：遷移不丟資料、檔案切換隔離、說「我是 X」、音樂來源偏好（People/FamilyProfiles.swift）   // 2.0 首次設定：只在全新時出現、頁序、快照不改偏好（Setup/SetupFlow.swift）
    }
}
