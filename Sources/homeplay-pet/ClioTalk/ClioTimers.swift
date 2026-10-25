// 2.0 P10（HV-MAIN-90）：ClioTalk 的多組計時器。timer_set 一律「再加一個」，不取代原本的；可以取名（「義大利麵 8 分鐘」）；
// timer_cancel 指名取消、或說「全部」；timer_status 列出每一個。帳就是計時器 App 那一本（Shell.timers／TimerBook），
// 所以 ClioTalk 開的、計時器 App 開的、食譜步驟開的都在同一張清單上，Live Activity 顯示最快到點的那個。

import AppKit

enum ClioTimers {
    enum Cancel: Equatable {
        case remove([Int])          // 要停的那幾個（id）
        case nothingRunning
        case noMatch
        case ambiguous              // 沒說哪一個、又有好幾個在跑：不猜，回去問
    }

    /// 「全部」的各種說法（模型照 schema 會給 "all"，這裡也接住中文）
    static let allWords: Set<String> = ["all", "everything", "every", "全部", "所有", "都", "全部的"]   // l10n-ignore：比對用詞，不是介面文字

    static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " timer", with: "").replacingOccurrences(of: "计时器", with: "").replacingOccurrences(of: "計時器", with: "")   // l10n-ignore：比對用詞，不是介面文字
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 要停哪幾個：「全部」＝全部；有名字＝名字一樣的優先，沒有就找包含的；沒名字只有一個＝那一個
    static func toCancel(_ timers: [ShellTimer], name: String?) -> Cancel {
        guard !timers.isEmpty else { return .nothingRunning }
        let n = normalized(name ?? "")
        if allWords.contains(n) { return .remove(timers.map(\.id)) }
        if n.isEmpty { return timers.count == 1 ? .remove([timers[0].id]) : .ambiguous }
        let exact = timers.filter { normalized($0.label) == n }
        if !exact.isEmpty { return .remove(exact.map(\.id)) }
        let partial = timers.filter { let l = normalized($0.label); return !l.isEmpty && (l.contains(n) || n.contains(l)) }
        return partial.isEmpty ? .noMatch : .remove(partial.map(\.id))
    }

    /// 沒取名時的名字：跟計時器 App 一樣「8 分钟」；不到一分鐘用秒
    static func label(_ given: String?, seconds: Double) -> String {
        let t = (given ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0
            ? String(format: L("timer.minutes", "%d 分钟"), Int(seconds / 60))
            : ClioHandoff.duration(seconds, locale: L10n.language.locale)
    }

    /// 給模型看的清單（英文、不進畫面）：照到點先後
    static func describe(_ timers: [ShellTimer], now: Double) -> String {
        let xs = timers.sorted { $0.end < $1.end }
        guard !xs.isEmpty else { return "No timer is running." }
        let rows = xs.map { "\($0.label) — \(timerClock($0.left(now))) left of \(timerClock($0.total))" }
        return (xs.count == 1 ? "1 timer is running: " : "\(xs.count) timers are running: ") + rows.joined(separator: "; ") + "."
    }

    static func names(_ timers: [ShellTimer]) -> String { timers.sorted { $0.end < $1.end }.map(\.label).joined(separator: ", ") }

    static func selftest(_ check: (Bool, String) -> Void) {
        var b = TimerBook()
        let pasta = b.add(seconds: 480, label: "Pasta", now: 1000)
        let sauce = b.add(seconds: 300, label: "Tomato sauce", now: 1000)
        check(b.timers.count == 2 && b.timer(pasta) != nil && b.timer(sauce) != nil, "ClioTalk 計時器：timer_set 再加一個、兩個同時在跑")
        check(toCancel(b.timers, name: "pasta") == .remove([pasta]), "ClioTalk 計時器：指名取消（不分大小寫）")
        check(toCancel(b.timers, name: "sauce timer") == .remove([sauce]), "ClioTalk 計時器：名字包含也算")
        check(toCancel(b.timers, name: "all") == .remove([pasta, sauce]) && toCancel(b.timers, name: "全部") == .remove([pasta, sauce]), "ClioTalk 計時器：all／全部＝都停")
        check(toCancel(b.timers, name: nil) == .ambiguous && toCancel(b.timers, name: "eggs") == .noMatch, "ClioTalk 計時器：沒說哪個就不猜、找不到就說找不到")
        check(toCancel([], name: "all") == .nothingRunning, "ClioTalk 計時器：沒有在跑的")
        b.remove(pasta)
        check(toCancel(b.timers, name: "") == .remove([sauce]), "ClioTalk 計時器：只剩一個時不用說名字")
        let d = describe([ShellTimer(id: 1, label: "Pasta", total: 480, end: 1480), ShellTimer(id: 2, label: "Sauce", total: 300, end: 1300)], now: 1000)
        check(d == "2 timers are running: Sauce — 5:00 left of 5:00; Pasta — 8:00 left of 8:00.", "ClioTalk 計時器：timer_status 列出全部，照到點先後（\(d)）")
        check(label("  ", seconds: 480) == String(format: L("timer.minutes", "%d 分钟"), 8) && label("Eggs", seconds: 30) == "Eggs", "ClioTalk 計時器：沒取名就叫「8 分鐘」")
        let spec = ClioToolCatalog.all.first { $0.name == "timer_set" }?.description ?? ""
        check(!spec.contains("Replaces") && spec.contains("Adds"), "ClioTalk 計時器：工具說明是「再加一個」不是取代")
        check(ClioToolCatalog.all.first { $0.name == "timer_cancel" }?.schema.contains("\"name\"") == true, "ClioTalk 計時器：timer_cancel 收名字")
    }
}

/// 計時器轉接：走計時器 App 同一本帳（Shell.addTimer／removeTimer 會順手對齊錶面與 Live Activity），在主執行緒做
enum ClioTimerAdapter {
    private static var face: Face? { (NSApp.delegate as? AppDelegate)?.view?.face }

    /// 回：加好之後一共幾個在跑；nil＝桌寵還沒好
    @MainActor static func add(seconds: Double, label: String?) -> (name: String, running: Int)? {
        guard let f = face else { return nil }
        let name = ClioTimers.label(label, seconds: seconds)
        _ = Shell.addTimer(minutes: seconds / 60, label: name, face: f)
        return (name, Shell.timers.timers.count)
    }

    @MainActor static func list() -> [ShellTimer] {
        if let f = face { Shell.reconcileTimers(f, now: CACurrentMediaTime()) }   // 右鍵選單開的也收進來
        return Shell.timers.sorted
    }

    /// 回給模型的一句
    @MainActor static func cancel(name: String?) -> String {
        let running = list()
        switch ClioTimers.toCancel(running, name: name) {
        case .nothingRunning: return "No timer was running."
        case .noMatch: return "No timer matches \"\(name ?? "")\". Running: \(ClioTimers.names(running)). Nothing was cancelled."
        case .ambiguous: return "Several timers are running (\(ClioTimers.names(running))). Nothing was cancelled; ask which one, or cancel all."
        case .remove(let ids):
            guard let f = face else { return "The desk pet is not ready." }
            let gone = running.filter { ids.contains($0.id) }
            for id in ids { Shell.removeTimer(id, face: f) }
            let left = Shell.timers.timers.count
            return "Cancelled: \(ClioTimers.names(gone))." + (left > 0 ? " Still running: \(ClioTimers.names(Shell.timers.timers))." : " No timers are running now.")
        }
    }
}
