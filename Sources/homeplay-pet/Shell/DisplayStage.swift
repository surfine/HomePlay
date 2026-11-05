// 顯示階段（HomeView 對齊 WP3）：HomeView 的三段顯示策略——活躍 → Ambient 海報 → 休眠。
// 對應官方行為：海報期的場景生命週期與被動觀察（人在鏡頭前只維持海報、不回互動），
// 以及「Turn Off Display = After 20 Seconds / Automatically」選項。
// 桌寵的對應：活躍＝外殼打開（主畫面/App/控制中心）；Ambient＝收回錶面（錶面即海報：時鐘/天氣/正在播放）；
// 休眠＝畫面壓暗到 12%（畫面還在，人一靠近或一有輸入就醒）。狀態機純邏輯，接線在 ShellInput.tick。
import AppKit

enum DisplayStage: String, Equatable {
    case interactive, ambient, sleep
}

/// 純邏輯狀態機（自檢見 DisplayStageSelfTest）：所有時間判斷集中在這，呼叫端只換畫面。
enum DisplayStageMachine {
    struct Input {
        var now: Double
        var lastActive: Double          // 最近一次意圖輸入
        var idleTimeout: Double         // 活躍 → Ambient 的閒置門檻（外殼現值 60 s）
        var ambientSince: Double?       // 何時進入 Ambient（nil＝還沒）
        var sleepAfter: Double?         // Ambient → 休眠延遲；nil＝自動（見 autoSleepDelay）
        var someoneNear: Bool           // 人在螢幕前（GazeTracker 近距）：休眠判定用
        var roomDark: Bool              // 房間暗（Shell.lowLight）
        var ambientEnabled: Bool        // 設定 › 顯示 › 環境海報（關＝活躍後直接休眠）
    }

    /// 自動模式的休眠延遲：房間暗 8 s；有人看 45 s；沒人看 12 s（海報是給遠處掃一眼的，不用一直亮）
    static func autoSleepDelay(someoneNear: Bool, roomDark: Bool) -> Double {
        if roomDark { return 8 }
        return someoneNear ? 45 : 12
    }

    static func stage(_ i: Input) -> DisplayStage {
        // 意圖輸入一進來（lastActive 更新）就回活躍——這條在最前面，休眠/海報都擋不住它
        if i.now - i.lastActive < i.idleTimeout { return .interactive }
        // Ambient 期被動觀察：自動模式有人在，就維持海報不睡；固定延遲（20 s）到點就睡
        if let a = i.ambientSince {
            let delay = i.sleepAfter ?? autoSleepDelay(someoneNear: i.someoneNear, roomDark: i.roomDark)
            if i.now - a >= delay {
                if i.someoneNear, i.sleepAfter == nil { return .ambient }
                return .sleep
            }
            return .ambient
        }
        return i.ambientEnabled ? .ambient : .sleep
    }
}

/// 顯示行為設定（官方「Turn Off Display」對應項）
enum DisplaySettings {
    static let sleepAfterKey = "shell.sleepAfter"        // Double 秒；沒存＝自動（nil）
    static let ambientKey = "shell.ambient"              // Bool，預設開

    /// 拍板（2026-11-05）：預設照官方字面「20 秒」；「自動」存 -1 當哨兵（跟「沒存過＝20 秒」區分）
    nonisolated(unsafe) private static var storedSleepAfter: Double? = {
        guard let v = UserDefaults.standard.object(forKey: sleepAfterKey) as? NSNumber else { return 20 }
        return v.doubleValue < 0 ? nil : v.doubleValue
    }()
    nonisolated(unsafe) private static var storedAmbient =
        UserDefaults.standard.object(forKey: ambientKey) as? Bool ?? true

    /// 休眠延遲：nil＝自動（房間暗/沒人就睡、有人在留海報）。20 秒是官方選項；
    /// 桌寵另允許 60 秒與永不（3600）。
    static var sleepAfter: Double? {
        get { storedSleepAfter }
        set {
            storedSleepAfter = newValue
            UserDefaults.standard.set(newValue ?? -1, forKey: sleepAfterKey)
        }
    }
    static var ambientEnabled: Bool {
        get { storedAmbient }
        set {
            storedAmbient = newValue
            UserDefaults.standard.set(newValue, forKey: ambientKey)
        }
    }
}

// MARK: - 外殼狀態（階段資料放 Shell；畫面切換在 ShellInput.tick 接線）

extension Shell {
    /// 進入 Ambient（收回錶面）的時刻；nil＝活躍中
    nonisolated(unsafe) static var ambientSince: Double?
    /// 現在在休眠階段（畫面壓暗；輸入或人靠近就醒）
    nonisolated(unsafe) static var displayAsleep = false
    /// 上次海報重畫的時刻（有活動卡每秒、沒有每分鐘；ShellInput.tick 用）
    nonisolated(unsafe) static var ambientRepaintAt = 0.0

    /// 休眠時壓到的亮度（其餘時間用 Shell.brightness）
    static let sleepBrightness: CGFloat = 0.12

    /// 現在的顯示階段（每幀算，純讀）
    static func displayStage(now: Double, face: Face, near: Bool) -> DisplayStage {
        DisplayStageMachine.stage(.init(
            now: now,
            lastActive: lastActive,
            idleTimeout: idleTimeout,
            ambientSince: ambientSince,
            sleepAfter: DisplaySettings.sleepAfter,
            someoneNear: near,
            roomDark: lowLight(face),
            ambientEnabled: DisplaySettings.ambientEnabled))
    }
}

// MARK: - 自檢

enum DisplayStageSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias M = DisplayStageMachine
        let t0 = 1000.0
        func input(now: Double, last: Double = t0, idle: Double = 60, ambient: Double? = nil,
                   sleep: Double? = nil, near: Bool = false, dark: Bool = false, enabled: Bool = true) -> M.Input {
            .init(now: now, lastActive: last, idleTimeout: idle, ambientSince: ambient,
                  sleepAfter: sleep, someoneNear: near, roomDark: dark, ambientEnabled: enabled)
        }
        check(M.stage(input(now: t0)) == .interactive, "顯示：有互動＝活躍")   // l10n-ignore
        check(M.stage(input(now: t0 + 59.9)) == .interactive && M.stage(input(now: t0 + 60.1)) == .ambient,
              "顯示：閒置逾時（60 s）進 Ambient 海報")   // l10n-ignore
        check(M.stage(input(now: t0 + 60.1 + 19.9, ambient: t0 + 60.1, sleep: 20)) == .ambient
              && M.stage(input(now: t0 + 60.1 + 20.1, ambient: t0 + 60.1, sleep: 20)) == .sleep,
              "顯示：官方選項「20 秒後」＝Ambient 20 秒後休眠")   // l10n-ignore
        check(M.stage(input(now: t0 + 60.1 + 100, ambient: t0 + 60.1, sleep: nil, near: true)) == .ambient
              && M.stage(input(now: t0 + 60.1 + 100, ambient: t0 + 60.1, sleep: nil, near: false)) == .sleep,
              "顯示：自動模式＝有人在留在海報（被動觀察）、沒人就睡")   // l10n-ignore
        check(M.stage(input(now: t0 + 60.1 + 8.1, ambient: t0 + 60.1, sleep: nil, dark: true)) == .sleep
              && M.autoSleepDelay(someoneNear: false, roomDark: true) == 8,
              "顯示：自動模式房間暗 8 秒就睡")   // l10n-ignore
        check(M.stage(input(now: t0 + 60.1, enabled: false)) == .sleep, "顯示：關掉環境海報＝活躍後直接休眠")   // l10n-ignore
        check(M.stage(input(now: t0 + 60.1 + 30, last: t0 + 60.1 + 29, ambient: t0, sleep: 20)) == .interactive,
              "顯示：休眠中一有互動直接回活躍")   // l10n-ignore
        check(DisplaySettings.ambientEnabled || !DisplaySettings.ambientEnabled, "顯示：設定可讀（防呆）")   // l10n-ignore
    }
}
