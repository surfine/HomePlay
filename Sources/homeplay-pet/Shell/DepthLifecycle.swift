// 2.0 depth：App 的收尾。離開 App 的路很多——返回鈕、閒置 60 秒回錶面、點 Live Activity 開別的 App、ClioTalk 的開 App 工具、CarPlay——
// 只有返回鈕會問 handleBack，所以每幀比一下「現在開著的 App」，換掉了就叫舊的那個 didClose（FaceTime 的自拍相機、對講的麥克風）。

import AppKit

extension Shell {
    nonisolated(unsafe) private static var openAppID: String?

    static func noteOpenApp() {
        let now: String? = { if case .app(let id) = nav.screen { return id }; return nil }()
        guard now != openAppID else { return }
        if let old = openAppID { AppRegistry.app(old)?.didClose() }
        openAppID = now
    }
}

// 2.0 depth：計時器到點要響（iOS 的計時器一直響到你按停止；以前只有橫幅和表情，人在廚房另一頭聽不到）。
// 循環播系統音效，按到畫面任何地方、計時器 App 的「停止」「重複」，或響滿 60 秒（跟完成畫面自己收掉一樣）就停。
enum TimerChime {
    nonisolated(unsafe) private static var sound: NSSound?
    nonisolated(unsafe) private static var startedAt = 0.0
    static var ringing: Bool { sound?.isPlaying == true }

    static func start() {
        guard !CommandLine.arguments.contains("--screen-png"), !CommandLine.arguments.contains("--snapshot"), !CommandLine.arguments.contains("--selftest") else { return }
        stop()
        let s = NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Ping"))
        s?.loops = true; s?.play(); sound = s; startedAt = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if CACurrentMediaTime() - startedAt >= 59.9 { stop() } }
    }
    static func stop() { sound?.stop(); sound = nil }
}

// 2.0 depth：計時器帳存在 UserDefaults（牆上時間，所以關掉期間也照算）；快照、自檢、示範不讀不寫
enum TimerStore {
    private static let key = "HomePlayTimers"
    private static var off: Bool {
        let a = CommandLine.arguments
        return ["--snapshot", "--screen-png", "--selftest", "--demo-timers", "--bench"].contains { a.contains($0) }
    }
    static func load() -> TimerBook {
        guard !off, let raw = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([ShellTimer].self, from: raw) else { return TimerBook() }
        return TimerBook(restoring: saved, now: TimersApp.wallNow)
    }
    static func save(_ b: TimerBook) {
        guard !off else { return }
        if let raw = try? JSONEncoder().encode(b.timers) { UserDefaults.standard.set(raw, forKey: key) }
    }
}
