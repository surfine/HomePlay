// 2.0 外殼（主畫面、App、控制中心）的純邏輯：導覽狀態機與多組計時器。不碰 AppKit，--selftest 直接驗。
//
// 導覽照實機描述（研究：hv-research/handson.md）：
// - 錶面左右滑（滾輪、← →）換；最後一個錶面再往後一頁是主畫面，主畫面再往後回到第一個錶面（頭尾相接）；
// - 錶面上往上滑（螢幕底緣往上拖、↑）也到主畫面；主畫面再往上是「全部 App」；
// - 點 App 進去；Esc／↓／左上角關閉鈕／底緣往上拖都是回上一層；
// - 控制中心、ClioTalk 是蓋在任何畫面上的一層，先收掉它們，才輪到退回上一層；
// - 一段時間沒人靠近（idle）或 CarPlay 畫面進來：全部收回錶面。

import Foundation

enum ShellScreen: Equatable {
    case face
    case home
    case library            // 全部 App（主畫面再往上滑）
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
        case idle                   // 沒人靠近太久
        case carPlay                // CarPlay 畫面進來
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
        case .idle, .carPlay:
            let changed = overlay != .none || screen != .face
            overlay = .none; screen = .face
            return Result(handled: changed, face: nil)
        case .openControlCenter:
            overlay = .controlCenter; return .done
        case .toggleControlCenter:
            overlay = overlay == .controlCenter ? .none : .controlCenter; return .done
        case .openClioTalk:
            overlay = .clioTalk; return .done
        case .openApp(let id):
            if screen == .home || screen == .library { appReturn = screen } else if case .app = screen {} else { appReturn = .home }
            overlay = .none; screen = .app(id); return .done
        case .back:
            if overlay != .none { overlay = .none; return .done }
            switch screen {
            case .app: screen = appReturn; return .done
            case .library: screen = .home; return .done
            case .home: screen = .face; return .done
            case .face: return .ignored            // 錶面上的 Esc 照舊（收提示、退出直播）
            }
        case .up:
            if overlay == .controlCenter { overlay = .none; return .done }   // 控制中心「往上推收起」
            if overlay != .none { return .done }
            switch screen {
            case .face: screen = .home; return .done
            case .home: screen = .library; return .done
            case .library, .app: return .done
            }
        case .page(let d):
            guard d != 0 else { return .ignored }
            if overlay != .none { return .done }    // 有一層蓋著：不換頁
            switch screen {
            case .face:
                // 只有跨過頭尾時外殼才接手（換到主畫面）；中間的換錶面交回原本的路
                if d > 0 && faceIndex >= last || d < 0 && faceIndex <= 0 { screen = .home; return .done }
                return .ignored
            case .home:
                screen = .face
                return Result(handled: true, face: d > 0 ? 0 : last)
            case .library, .app:
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
    static func run(_ check: (Bool, String) -> Void) {
        // 導覽：十個錶面，最後一個再往後＝主畫面，主畫面往後＝第一個錶面
        var n = ShellNav()
        check(n.handle(.page(1), faceIndex: 3, faceCount: 10) == .ignored && n.screen == .face, "外殼：中間的錶面換頁交回原本的路")
        check(n.handle(.page(1), faceIndex: 9, faceCount: 10) == .done && n.screen == .home, "外殼：最後一個錶面往後是主畫面")
        check(n.handle(.page(1), faceIndex: 9, faceCount: 10) == ShellNav.Result(handled: true, face: 0) && n.screen == .face, "外殼：主畫面往後回第一個錶面")
        _ = n.handle(.page(-1), faceIndex: 0, faceCount: 10)
        check(n.screen == .home, "外殼：第一個錶面往前也是主畫面（頭尾相接）")
        check(n.handle(.page(-1), faceIndex: 0, faceCount: 10).face == 9 && n.screen == .face, "外殼：主畫面往前回最後一個錶面")
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
        check(n.handle(.carPlay, faceIndex: 0, faceCount: 10).handled && n.screen == .face && n.overlay == .none, "外殼：CarPlay 畫面優先")

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
        let near = [CGRect(x: 0, y: 0, width: 88, height: 88), CGRect(x: 100, y: 0, width: 88, height: 88)], far = [near[0], CGRect(x: 120, y: 0, width: 88, height: 88)]
        check(HPGlass.needsMerge(near) && !HPGlass.needsMerge(far), "玻璃：相距小於 24 px 才融合")
        check(Shell.greeting(hour: 8).count >= 1 && Shell.greeting(hour: 8)[0] == Shell.greeting(hour: 8)[0].uppercased(), "主畫面：問候語全大寫")
        AppsSelfTest.run(check)   // 2.0: 闹钟、天气、日历、提醒事项的純邏輯
        RecipeSelfTest.run(check)   // 食譜 App：JSON-LD、時間、份量（Shell/Apps/RecipeParser.swift）
        MusicSelfTest.run(check)    // 音樂 App：資料庫輸出解析
    }
}
