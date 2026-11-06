// 手機傳到桌寵：CarPlay 連著時 iPhone 不能用 AirDrop，控制中心「收 AirDrop」把 CarPlay 暫時斷開。
// 按下：送接收端 {"type":"pauseCarPlay","seconds":60}；接收端照退出的順序收掉會話（關通道、斷基帶、收會話），
// 但行程不退出、SDP 與藍牙廣播不撤，暫停期間連線狀態機不重連（Sources/IAP2/ConnectionMachine.swift 的 R7）。
// 桌寵這邊：倒數卡「CarPlay 已暫停，現在可以從 iPhone 用 AirDrop 傳過來」；收件匣（AirDropInbox）收到檔案、
// 而且沒有檔案還在寫，再等 5 秒就送 {"type":"resumeCarPlay"}；有檔案在寫就延長，從按下算最多 3 分鐘。
// 桌寵結束時一定送 resume；接收端自己也有 3 分鐘保底，不靠桌寵。規則（CarPlayPausePlan）是純函數，--selftest 直接驗。
// 延長與提早恢復由暫停期間自己的計時器（每 0.5 秒）推動，不靠錶面每幀——暫停時多半在 CarPlay 畫面或被遮住，錶面不更新；
// 錶面更新時只負責畫倒數。

import AppKit

/// 暫停的時間規則（時間一律由呼叫端帶入）
struct CarPlayPausePlan: Equatable {
    static let initial: Double = 60, maxTotal: Double = 180
    /// 收完最後一個檔案、沒有檔案在寫，再等幾秒恢復
    static let settle: Double = 5
    /// 有檔案在寫、剩不到 extendWhenLeft 秒時，延到「現在＋extendBy」（不超過 maxTotal）
    static let extendWhenLeft: Double = 20, extendBy: Double = 40

    enum Reason: String, Equatable { case received, timeout, user }
    enum Action: Equatable { case none, extend(Double), resume(Reason) }

    private(set) var since: Double
    private(set) var until: Double
    private(set) var received = 0
    private(set) var lastActivity: Double?

    init(now: Double) { since = now; until = now + Self.initial }

    func remaining(_ now: Double) -> Double { max(0, until - now) }

    mutating func fileReceived(now: Double) { received += 1; lastActivity = now }

    /// 每幀：到時就恢復；有檔案在寫就記下、快到時延長；收過檔案而且安靜了 settle 秒就恢復
    mutating func tick(now: Double, writing: Bool) -> Action {
        if now >= until { return .resume(.timeout) }
        if writing {
            lastActivity = now
            if until - now < Self.extendWhenLeft, until < since + Self.maxTotal {
                until = min(since + Self.maxTotal, now + Self.extendBy)
                return .extend(until - now)
            }
            return .none
        }
        if received > 0, let a = lastActivity, now - a >= Self.settle { return .resume(.received) }
        return .none
    }
}

final class CarPlayAirDropPause {
    nonisolated(unsafe) static var shared = CarPlayAirDropPause()

    private(set) var plan: CarPlayPausePlan?
    /// 送給接收端（AppDelegate 接 client?.sendRaw）
    var send: (String) -> Void = { _ in }
    /// 「下載項目」裡有檔案還在寫（AirDropInbox）
    var writing: () -> Bool = { AirDropInbox.shared.writing }
    private var shownSecond = -1
    /// 暫停期間推動規則的計時器（每 0.5 秒）
    private var ticker: DispatchSourceTimer?
    static let tickInterval = 0.5
    /// 計時器用的時鐘（自檢換成假的）
    var clockNow: () -> Double = { CACurrentMediaTime() }
    /// 狀態變了（延長、恢復）：叫錶面重畫
    var onChange: () -> Void = { (NSApp?.delegate as? AppDelegate)?.view?.face.forceDirty = true }
    var hasTicker: Bool { ticker != nil }

    var isPaused: Bool { plan != nil }
    /// 按下時桌寵在不在 CarPlay 畫面（AppDelegate 接 view.showingVideo）
    var showingCarPlay: () -> Bool = { false }
    /// 無感恢復：暫停前在哪個畫面，重連後就回哪個畫面，不把人拉進 CarPlay；手機那邊 iOS 自己會回到原本的 App（2026-11-06 真機）
    private(set) var restore: (showingCarPlay: Bool, until: Double)?
    /// 這次斷線是自己要的（暫停中、或剛恢復還沒連回來）：不擺擔心臉、不顯示「重新連線中」
    func intentional(now: Double) -> Bool { plan != nil || (restore.map { now < $0.until } ?? false) }
    /// 重連成功時取一次：回原本在不在 CarPlay 畫面；不是這次暫停造成的重連回 nil
    func takeRestore(now: Double) -> Bool? {
        defer { restore = nil }
        guard let r = restore, now < r.until else { return nil }
        return r.showingCarPlay
    }
    /// 控制中心那顆能不能按：主人的 iPhone 在 CarPlay 會話中（或已經暫停、按了是恢復）
    var available: Bool { isPaused || SelfShare.carPlayActive }

    static func pauseJSON(_ seconds: Double) -> String { #"{"type":"pauseCarPlay","seconds":\#(Int(seconds.rounded()))}"# }
    static let resumeJSON = #"{"type":"resumeCarPlay"}"#

    @discardableResult
    func begin(now: Double = CACurrentMediaTime()) -> Bool {
        guard plan == nil, SelfShare.carPlayActive else { return false }
        plan = CarPlayPausePlan(now: now)
        restore = (showingCarPlay(), now + CarPlayPausePlan.maxTotal + 30)
        send(Self.pauseJSON(CarPlayPausePlan.initial))
        log("airdrop carplay: pause \(Int(CarPlayPausePlan.initial)) s")
        startTicker()
        return true
    }

    private func startTicker() {
        ticker?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.tick(now: self.clockNow()) { self.onChange() }
        }
        t.resume()
        ticker = t
    }
    private func stopTicker() { ticker?.cancel(); ticker = nil }

    func resume(_ why: CarPlayPausePlan.Reason, now: Double = CACurrentMediaTime()) {
        guard let p = plan else { return }
        plan = nil
        stopTicker()
        send(Self.resumeJSON)
        log("airdrop carplay: resume (\(why.rawValue)) after \(Int((now - p.since).rounded())) s, \(p.received) file(s)")
    }

    func fileReceived(now: Double = CACurrentMediaTime()) { plan?.fileReceived(now: now) }

    /// 暫停期間的計時器（每 0.5 秒）：照規則延長或恢復；回 true＝狀態變了要重畫
    func tick(now: Double) -> Bool {
        guard var p = plan else { return false }
        let a = p.tick(now: now, writing: writing())
        plan = p
        switch a {
        case .none: return false
        case .extend(let s):
            send(Self.pauseJSON(s))
            log("airdrop carplay: still receiving, extend to \(Int(s.rounded())) s more")
            return true
        case .resume(let why): resume(why, now: now); return true
        }
    }

    /// 倒數換秒（卡片與控制中心）
    func secondChanged(now: Double) -> Bool {
        let s = plan.map { Int($0.remaining(now).rounded(.up)) } ?? -1
        defer { shownSecond = s }
        return s != shownSecond
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 接收端說它自己恢復了（到時保底）：收掉倒數，不再送 resume
    func receiverSaid(_ text: String) {
        guard text.contains("\"state\":\"resumed\""), plan != nil else { return }
        log("airdrop carplay: receiver resumed on its own")
        plan = nil
        stopTicker()
    }

    /// 桌寵結束：暫停中就送 resume。回 true＝送了（呼叫端等一下讓它送出去）
    @discardableResult
    func shutdown() -> Bool {
        guard plan != nil else { return false }
        resume(.user)
        return true
    }

    /// 快照用：已經暫停、還剩 left 秒（不送任何東西）
    func demo(left: Double, received: Bool = false) {
        let now = CACurrentMediaTime()
        send = { _ in }
        var p = CarPlayPausePlan(now: now - (CarPlayPausePlan.initial - left))
        if received { p.fileReceived(now: now) }
        plan = p
    }
}
