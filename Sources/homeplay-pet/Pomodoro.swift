// 番茄鐘：專注 25 分鐘 → 休息 5 分鐘，每完成四輪換一次 15 分鐘長休息；到點自動接下一段。
// 用的是同一個計時器（島長成的倒數膠囊、到點的橫幅），這裡只管「現在是哪一段、第幾輪、今天完成幾個」。

import Foundation

enum PomodoroPhase: Equatable {
    case focus, shortBreak, longBreak
    var seconds: Double {
        switch self {
        case .focus: return Pomodoro.focusMinutes * 60
        case .shortBreak: return Pomodoro.shortMinutes * 60
        case .longBreak: return Pomodoro.longMinutes * 60
        }
    }
    var isBreak: Bool { self != .focus }
}

struct Pomodoro: Equatable {
    static let focusMinutes = 25.0, shortMinutes = 5.0, longMinutes = 15.0
    static let roundsPerSet = 4
    static let countKey = "HomePlayPomodoroCount"

    private(set) var phase: PomodoroPhase?
    /// 這一組裡已完成的專注輪數（0…3；完成第 4 輪後進長休息、歸零）
    private(set) var round = 0
    var active: Bool { phase != nil }

    mutating func start() -> PomodoroPhase { phase = .focus; round = 0; return .focus }
    mutating func stop() { phase = nil; round = 0 }

    /// 一段到點：回傳下一段（專注 → 短／長休息；休息 → 專注），以及這次是不是完成了一個番茄
    mutating func advance() -> (next: PomodoroPhase, completedFocus: Bool)? {
        guard let p = phase else { return nil }
        switch p {
        case .focus:
            round += 1
            let next: PomodoroPhase = round >= Self.roundsPerSet ? .longBreak : .shortBreak
            if next == .longBreak { round = 0 }
            phase = next
            return (next, true)
        case .shortBreak, .longBreak:
            phase = .focus
            return (.focus, false)
        }
    }

    /// 現在是第幾輪（1…4），顯示用
    var displayRound: Int { min(Self.roundsPerSet, round + 1) }

    // MARK: 今天完成幾個（UserDefaults：{"yyyy-MM-dd": n}，只留今天）

    static func todayKey(_ d: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static var todayCount: Int {
        (UserDefaults.standard.dictionary(forKey: countKey)?[todayKey()] as? Int) ?? 0
    }
    static func recordCompleted() {
        let n = todayCount + 1
        UserDefaults.standard.set([todayKey(): n], forKey: countKey)
    }
}
