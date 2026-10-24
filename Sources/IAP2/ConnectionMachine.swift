// CarPlay 连线状态机：所有「连谁、怎么连、失败了怎么办、要不要重启」只在这里决定。
// 纯逻辑：不碰 IOBluetooth / usbmuxd / 网络 / 文件；时间随事件带入，计时器是效果（setTimer）与事件（timer）。
// runDual 只负责把硬件事件喂进来、执行吐出去的效果。设计稿：docs/design-drafts/連線狀態機.md（规则 R1–R6）。
// 不变量：任何时刻最多一条连结在开（link 只有一个槽位）；旧连结晚到的事件凭 generation 丢弃。
import Foundation

package enum LinkKind: Equatable, Sendable { case bluetooth, usb }

package enum TargetReason: Equatable, Sendable { case user, plug, last, nearby, incoming, auto }

package enum LinkUnavailable: Equatable, Sendable {
    case noService     // SDP 没有 iAP2 服务／通道
    case notPaired     // 系统里已没有这台的配对
    case notFound      // 找不到装置或 RFCOMM 起不来
}

package enum SessionEndReason: Equatable, Sendable {
    case phoneTeardown   // 手机结束会话
    case controlClosed   // 控制连接关闭
    case silence         // 15 秒没有控制消息也没有画面（Wi-Fi 短断）
    case ours            // 我们自己收掉的（换手机、重开、睡眠）
}

package enum SuspendReason: Hashable, Sendable { case asleep, pairingGuide, cablePairing }

package enum RestartKind: Equatable, Sendable {
    case young      // 刚起来的行程第一次连不上：再换一个新行程（真机规律，约 2 秒连上）
    case selfHeal   // 连续失败：重启行程自愈
}

package enum StartKind: Equatable, Sendable {
    case wireless
    case wirelessAlternate   // 第一次补发：IPv6 链路本地＋换一次安全类型
    case wired               // USB NCM 链路本地
}

package enum TimerID: Hashable, Sendable {
    case retry, handoffResend, wifiHelp, wifiWait, wifiNudge, ncmPoll, silence, wakeOpen, cabledWait
}

package enum Hint: Equatable, Sendable {
    case wifiHelp
    case needPairing                                        // 没有任何已配对的 iPhone：交给插线优先／配对引导
    case cableGone(live: Bool, transport: CarPlayTransport?)  // 照 CarPlayTransportPolicy.onCableGone 冻结／恢复画面
}

package enum ConnectionEvent: Equatable, Sendable {
    /// crashed＝上一个行程没有正常结束（kill -9／当机）：手机可能还抓着它的旧 RFCOMM 通道
    case start(preferred: String?, crashed: Bool = false)
    case userSelect(String)
    case userForget(String)
    case phonesChanged
    /// chargeOnly＝已在系统里配对的手机：线只充电，会话走藍牙→Wi-Fi（拔线不断）；藍牙连不上才开 USB
    case usbAttached(serial: String, phone: String?, chargeOnly: Bool = false)
    case usbLearned(phone: String)
    case usbDetached
    case incoming(String)
    case linkAuthenticated(gen: Int)
    case linkFinished(gen: Int, code: Int)
    case linkUnavailable(gen: Int, LinkUnavailable)
    case availability(gen: Int, wired: Bool, wireless: Bool)
    case transportAvailable(gen: Int)
    case controlConnected(CarPlayTransport)
    case sessionActive
    case sessionEnded(SessionEndReason)
    case displayChanged
    case sleep, wake
    case suspend(SuspendReason, Bool)
    case restartDenied(RestartKind)
    case timer(TimerID, token: Int)
}

package enum ConnectionEffect: Equatable, Sendable {
    case openBluetooth(address: String, gen: Int)
    case openUSB(gen: Int)
    case adoptIncoming(address: String, gen: Int)
    case rejectIncoming(address: String)
    case closeLink(gen: Int)                     // 调用方先拔掉 onFinished 再关
    case dropBaseband(address: String)
    case refreshSDP(address: String, timeout: TimeInterval)
    case republishSDP
    case sendWiFiConfig(gen: Int)
    case sendStart(gen: Int, StartKind)
    case switchSession(to: String?)              // 改探针地址并结束目前会话
    case dropSession                              // 收掉会话，探针地址不变
    case restartProcess(RestartKind)              // 调用方节流；挡下就回 restartDenied
    case setTimer(TimerID, after: TimeInterval, token: Int)
    case cancelTimer(TimerID)
    case persistPreferred(String)
    case publishPhones
    case notify(Hint)
    case log(String)
}

/// 每次 handle 带入的外部事实；测试里直接伪造。
package struct ConnectionEnvironment: Equatable, Sendable {
    package var now: TimeInterval
    package var processAge: TimeInterval
    package var paired: [String]          // 已配对且没被忽略的 iPhone（任意格式，内部正规化）
    package var nearby: Set<String>       // 基带在线的手机
    package var wifiReady = true
    package var ncmReady = false
    package var tunnelCarriesIap2 = false // 手机 SETUP 了流 130：直播中藍牙 iAP2 可慢速保活

    package init(now: TimeInterval, processAge: TimeInterval, paired: [String], nearby: Set<String> = [],
                 wifiReady: Bool = true, ncmReady: Bool = false, tunnelCarriesIap2: Bool = false) {
        self.now = now
        self.processAge = processAge
        self.paired = paired
        self.nearby = nearby
        self.wifiReady = wifiReady
        self.ncmReady = ncmReady
        self.tunnelCarriesIap2 = tunnelCarriesIap2
    }
}

package struct ConnectionMachine: Sendable {
    // 节奏常数（真机教训：不要短逾时＋立刻重试）
    package static let ladder: [TimeInterval] = [2, 5, 10, 20, 30, 60]
    package static let slowRetry: TimeInterval = 60
    package static let freshPlugAge: TimeInterval = 8
    package static let youngAge: TimeInterval = 60
    package static let userPinned: TimeInterval = 60
    package static let firstResend: TimeInterval = 12
    package static let resendEvery: TimeInterval = 15
    package static let maxResends = 8
    package static let wifiHelpAfter: TimeInterval = 15   // 手机报了可用、15 秒没从 Wi-Fi 连回就给提示（第一次常要关开一次 Wi-Fi）
    package static let wifiWaitAfter: TimeInterval = 15
    package static let nudgeAfter: TimeInterval = 10
    package static let nudgeEvery: TimeInterval = 300
    package static let earlyTeardown: TimeInterval = 1.5
    package static let reopenWindow: TimeInterval = 30
    package static let reopenMax = 3
    package static let silenceWait: TimeInterval = 15
    package static let usbRetry: TimeInterval = 5
    package static let ncmEvery: TimeInterval = 2
    package static let ncmGiveUp: TimeInterval = 60
    package static let wakeDelay: TimeInterval = 0.8
    package static let sdpTimeout: TimeInterval = 4
    package static let crashSettle: TimeInterval = 1
    package static let cabledWait: TimeInterval = 5

    package struct Target: Equatable, Sendable {
        package var address: String?     // nil＝线上那台、还没学到藍牙地址
        package var why: TargetReason
        package var since: TimeInterval
    }

    package enum Link: Equatable, Sendable {
        case idle
        case opening(LinkKind, address: String?, gen: Int)
        case up(LinkKind, address: String?, gen: Int)
        case handoff(LinkKind, address: String?, gen: Int, resends: Int, since: TimeInterval, wirelessTried: Bool)

        package var gen: Int? {
            switch self {
            case .idle: return nil
            case .opening(_, _, let g), .up(_, _, let g), .handoff(_, _, let g, _, _, _): return g
            }
        }
        package var kind: LinkKind? {
            switch self {
            case .idle: return nil
            case .opening(let k, _, _), .up(let k, _, _), .handoff(let k, _, _, _, _, _): return k
            }
        }
        package var address: String? {
            switch self {
            case .idle: return nil
            case .opening(_, let a, _), .up(_, let a, _), .handoff(_, let a, _, _, _, _): return a
            }
        }
        package var isOpening: Bool { if case .opening = self { return true } else { return false } }
    }

    package enum Session: Equatable, Sendable {
        case none
        case live(owner: String?, transport: CarPlayTransport?, since: TimeInterval)
    }

    package private(set) var target: Target?
    package private(set) var link: Link = .idle
    package private(set) var session: Session = .none
    package private(set) var usb: (serial: String, phone: String?, chargeOnly: Bool)?
    private var usbPreferred = false
    private var cabledWirelessFailed = false   // 这段插线里无线已经没连成：改走 USB 时直接开有线   // 这段插线改走 USB（真的插上，或藍牙连不上）
    package private(set) var failStreak = 0
    package private(set) var suspended: Set<SuspendReason> = []
    package private(set) var retryPending = false

    private var generation = 0
    private var backoff = BackoffSchedule(ladder: ConnectionMachine.ladder, slow: ConnectionMachine.slowRetry)
    private var tokens: [TimerID: Int] = [:]
    private var tokenSeq = 0
    private var lastFailCode = 0
    private var failedAt: [String: TimeInterval] = [:]
    private var fallbackFrom: Target?   // 改连旁边那台之前的目标：那台也连不上就回到它   // 每台手机最近一次连不上的时刻（改连旁边那台不回头找刚失败的）
    package static let nearbyCooldown: TimeInterval = 120
    private var republished = false
    private var reopenTimes: [TimeInterval] = []
    private var lastNudgeAt: TimeInterval = -.infinity
    private var lastControlAt: TimeInterval = -.infinity
    private var pendingTransport: CarPlayTransport?
    private var sawAvailability = false
    private var phoneWired = true, phoneWireless = true   // 手机最近一次 0x4300 报的可用性（补发、重开照它）
    private var wifiConfigSent = false
    private var ncmSince: TimeInterval?
    private var started = false
    private var pairingHinted = false

    private var env = ConnectionEnvironment(now: 0, processAge: 0, paired: [])
    private var out: [ConnectionEffect] = []

    package init() {}

    package var liveOwner: String? {
        if case .live(let owner, _, _) = session { return owner }
        return nil
    }
    package var isLive: Bool { if case .live = session { return true } else { return false } }

    // MARK: - 入口

    package mutating func handle(_ event: ConnectionEvent, _ environment: ConnectionEnvironment) -> [ConnectionEffect] {
        env = environment
        out = []
        switch event {
        case .start(let preferred, let crashed): onStart(preferred, crashed: crashed)
        case .userSelect(let a): select(Self.norm(a), why: .user)
        case .userForget(let a): onForget(Self.norm(a))
        case .phonesChanged: onPhonesChanged()
        case .usbAttached(let serial, let phone, let chargeOnly): onUSBAttached(serial: serial, phone: phone.map(Self.norm), chargeOnly: chargeOnly)
        case .usbLearned(let phone): onUSBLearned(Self.norm(phone))
        case .usbDetached: onUSBDetached()
        case .incoming(let a): onIncoming(Self.norm(a))
        case .linkAuthenticated(let gen): onAuthenticated(gen)
        case .linkFinished(let gen, let code): onLinkFinished(gen, code: code)
        case .linkUnavailable(let gen, let why): onUnavailable(gen, why)
        case .availability(let gen, let wired, let wireless): onAvailability(gen, wired: wired, wireless: wireless)
        case .transportAvailable(let gen): onTransportAvailable(gen)
        case .controlConnected(let t): onControlConnected(t)
        case .sessionActive: onSessionActive()
        case .sessionEnded(let why): onSessionEnded(why)
        case .displayChanged: onDisplayChanged()
        case .sleep: onSleep()
        case .wake: onWake()
        case .suspend(let why, let on): onSuspend(why, on)
        case .restartDenied: retryAfterFailure()
        case .timer(let id, let token):
            guard tokens[id] == token else { break }   // 已取消或被新计时器取代
            tokens[id] = nil
            onTimer(id)
        }
        return out
    }

    // MARK: - R1 选目标

    private mutating func onStart(_ preferred: String?, crashed: Bool) {
        started = true
        // 不看配对清单：接收器刚起来那一刻系统清单可能短暂读不到（真机 2026-10-24 05:02，因此改连了线上那台）
        if let p = preferred.map(Self.norm) {
            target = Target(address: p, why: .last, since: env.now)
        }
        // 上一个行程被硬杀：先断基带让手机丢掉旧通道，稍等再开（真机 2026-10-24 05:10：不断就第一次必逾时）
        if crashed, let a = target?.address, isNearby(a) {
            out.append(.log("上一个行程没有正常结束：先断开到 \(a) 的基带，\(Self.crashSettle) 秒后再连"))
            out.append(.dropBaseband(address: a))
            scheduleRetry(Self.crashSettle)
            return
        }
        ensureLink()
    }

    /// 换目标：收掉正在开／已开的连结；直播别台就换会话；退避归零。
    private mutating func select(_ address: String?, why: TargetReason) {
        if let address, liveOwner == address || (!isLive && link != .idle && link.address == address) {
            target = Target(address: address, why: why, since: env.now)
            if why == .user { out.append(.persistPreferred(address)) }
            return   // 选的就是正在直播／正在连的那台
        }
        target = Target(address: address, why: why, since: env.now)
        fallbackFrom = nil
        if why == .user, let address { out.append(.persistPreferred(address)) }
        // 使用者选的就是插着线的那台：直接走 USB（真机：插着线时藍牙 iAP2 多半逾时，线一定通）
        if why == .user, let address, usb?.phone == address { usbPreferred = true }
        closeCurrentLink()
        if isLive { switchSession(to: address) }
        resetRetry()
        ensureLink()
    }

    private mutating func onForget(_ address: String) {
        guard target?.address == address || link.address == address || liveOwner == address else { return }
        target = nil
        closeCurrentLink()
        if liveOwner == address { switchSession(to: nil) }
        resetRetry()
        ensureLink()
    }

    private mutating func onPhonesChanged() {
        if target == nil { ensureLink() }
    }

    /// 目标为空时挑一台：线上那台 → 第一台在旁边的 → 第一台已配对的。
    private mutating func chooseTarget() {
        if let u = usb {
            target = Target(address: u.phone, why: .plug, since: env.now)
            return
        }
        let paired = env.paired.map(Self.norm)
        if let p = paired.first(where: { isNearby($0) }) ?? paired.first {
            target = Target(address: p, why: .auto, since: env.now)
        }
    }

    // MARK: - R2 开连结（一次一条）

    private mutating func ensureLink() {
        guard started, suspended.isEmpty, link == .idle, !retryPending else { return }
        if target == nil { chooseTarget() }
        guard let t = target else {
            if !pairingHinted, env.paired.isEmpty {
                pairingHinted = true
                out.append(.notify(.needPairing))
            }
            return
        }
        generation += 1
        if let u = usb, t.address == nil || (u.phone == t.address && (!u.chargeOnly || usbPreferred)) {
            link = .opening(.usb, address: t.address ?? u.phone, gen: generation)
            out.append(.openUSB(gen: generation))
        } else if let a = t.address {
            link = .opening(.bluetooth, address: a, gen: generation)
            out.append(.openBluetooth(address: a, gen: generation))
        } else {
            target = nil   // 线上那台已经拔走
            generation -= 1
            ensureLink()
        }
    }

    private mutating func closeCurrentLink() {
        if let g = link.gen { out.append(.closeLink(gen: g)) }
        link = .idle
        cancelHandoffTimers()
    }

    private mutating func resetRetry() {
        backoff.reset()
        failStreak = 0
        republished = false
        if retryPending { retryPending = false; cancel(.retry) }
    }

    private mutating func scheduleRetry(_ delay: TimeInterval) {
        retryPending = true
        set(.retry, after: delay)
    }

    // MARK: - 插拔线

    private mutating func onUSBAttached(serial: String, phone: String?, chargeOnly: Bool) {
        let fresh = env.processAge > Self.freshPlugAge
        let changed = usb?.serial != serial
        usb = (serial, phone, chargeOnly)
        guard changed else { return }
        usbPreferred = fresh   // 真的插上＝「用这台」：线一定通，直接走 USB
        if let phone {
            // R1.2：真的插上一台不是正在直播的手机 → 换成它
            if fresh, liveOwner != phone, !(target?.address == phone && !isLive) {
                select(phone, why: .plug)
                return
            }
            // 本来就要连它：在退避等待就立刻改走 USB；藍牙正在开就让它跑完（失败时 R3.1 改走 USB）
            if target?.address == phone, retryPending, !isLive { resetRetry(); ensureLink() }
            return
        }
        // 没学过的手机：插线配对。真的插上，或者根本没有别的目标，就以它为目标
        if fresh || target == nil || env.paired.isEmpty {
            select(nil, why: .plug)
        }
    }

    private mutating func onUSBLearned(_ phone: String) {
        usb?.phone = phone
        if target?.address == nil, target != nil {
            target?.address = phone
            out.append(.persistPreferred(phone))
        }
        if case .opening(.usb, nil, let g) = link { link = .opening(.usb, address: phone, gen: g) }
        if case .up(.usb, nil, let g) = link { link = .up(.usb, address: phone, gen: g) }
        out.append(.publishPhones)
    }

    private mutating func onUSBDetached() {
        guard usb != nil else { return }
        usb = nil
        usbPreferred = false
        cabledWirelessFailed = false
        var transport: CarPlayTransport?
        if case .live(_, let t, _) = session { transport = t }
        out.append(.notify(.cableGone(live: isLive, transport: transport)))
        if target?.address == nil { target = nil }
        if link.kind == .usb {
            closeCurrentLink()
            resetRetry()
            ensureLink()   // 照 R2 走藍牙
        }
    }

    // MARK: - 手机主动连入

    private mutating func onIncoming(_ address: String) {
        let pinnedElsewhere = target?.why == .user && target?.address != address
            && env.now - (target?.since ?? 0) < Self.userPinned
        let busy = link != .idle || (isLive && liveOwner != address)
        guard !busy, !pinnedElsewhere, !suspended.contains(.asleep), !suspended.contains(.cablePairing) else {
            out.append(.rejectIncoming(address: address))
            return
        }
        if target?.address != address { target = Target(address: address, why: .incoming, since: env.now) }
        if retryPending { retryPending = false; cancel(.retry) }
        generation += 1
        link = .opening(.bluetooth, address: address, gen: generation)
        out.append(.adoptIncoming(address: address, gen: generation))
    }

    // MARK: - R3 连结结果

    private mutating func onAuthenticated(_ gen: Int) {
        guard case .opening(let kind, let address, gen) = link else { return }
        link = .up(kind, address: address, gen: gen)
        failStreak = 0
        republished = false
        backoff.reset()
        sawAvailability = false
        wifiConfigSent = false
        phoneWired = true
        phoneWireless = true
        // 插着线的 iPhone 不肯从藍牙开 CarPlay（只报 0x4E0D 无线可用、不报 0x4300）：5 秒没动静就改走 USB
        //（真机 2026-10-24 11:42：照 Wi-Fi 等待规则白等 25 秒，重启后 48 秒才出画面）
        if kind == .bluetooth, let address, usb?.phone == address, !isLive {
            set(.cabledWait, after: Self.cabledWait)
        }
        if let address {
            if target?.why != .user { out.append(.persistPreferred(address)) }
            out.append(.publishPhones)
        }
    }

    private mutating func onLinkFinished(_ gen: Int, code: Int) {
        guard link.gen == gen else { return }   // 旧连结晚到
        let wasOpening = link.isOpening
        let kind = link.kind
        link = .idle
        cancelHandoffTimers()
        if wasOpening {
            linkFailed(kind: kind ?? .bluetooth, code: code)
        } else if isLive {
            // 直播中 iAP2 连结断了：会话不受影响；藍牙是唯一路径时照一般退避，否则慢速保活
            scheduleRetry(env.tunnelCarriesIap2 ? Self.slowRetry : backoff.next(live: false))
        } else {
            scheduleRetry(backoff.next(live: false))
        }
    }

    private mutating func onUnavailable(_ gen: Int, _ why: LinkUnavailable) {
        guard link.gen == gen, link.isOpening else { return }
        let address = link.address
        link = .idle
        // R3.1 也适用：目标插着线、藍牙找不到服务（USB 期间手机的 SDP 常不可用）→ 改走 USB
        if let address, usb?.phone == address, !usbPreferred {
            usbPreferred = true
            ensureLink()
            return
        }
        switch why {
        case .noService:
            if let address { out.append(.refreshSDP(address: address, timeout: Self.sdpTimeout)) }
            scheduleRetry(backoff.next(live: false))
        case .notPaired:
            // 系统清单可能一时读不到：照退避重试；真的不要这台由使用者「忘记」
            _ = address
            scheduleRetry(backoff.next(live: false))
        case .notFound:
            linkFailed(kind: .bluetooth, code: 3)
        }
    }

    /// R3：藍牙连结认证前失败。依序，命中一条就停。
    private mutating func linkFailed(kind: LinkKind, code: Int) {
        if kind == .usb {
            scheduleRetry(Self.usbRetry)   // 等使用者在手机上按「信任」，不打扰藍牙
            return
        }
        guard !isLive else { scheduleRetry(env.tunnelCarriesIap2 ? Self.slowRetry : backoff.next(live: false)); return }
        failStreak += 1
        lastFailCode = code
        let address = target?.address
        if let address { failedAt[address] = env.now }
        // R3.1 目标正插着线 → 改走 USB（不算失败）
        if let address, usb?.phone == address, !usbPreferred {
            usbPreferred = true
            failStreak -= 1
            ensureLink()
            return
        }
        // R3.2 刚起来的行程第一次失败、手机就在旁边 → 再换一个新行程
        if failStreak == 1, env.processAge < Self.youngAge, let address, isNearby(address) {
            out.append(.restartProcess(.young))
            return
        }
        // R3.3a 目标连不上、线上插着另一台：改连线上那台（USB 一定通；真机 2026-10-24 09:37 在重启那几秒插上的 SE 一直没人理）
        if let address, failStreak >= 2 || !isNearby(address), !(target?.why == .user && env.now - (target?.since ?? 0) < Self.userPinned),
           let u = usb, u.phone != address {
            out.append(.log("\(address) 连不上（码 \(code)），改连线上的 \(u.phone ?? "那台")"))
            target = Target(address: u.phone, why: .plug, since: env.now)
            usbPreferred = true
            ensureLink()
            return
        }
        // R3.3 改连旁边那台
        if let address, failStreak >= 2 || !isNearby(address), !(target?.why == .user && env.now - (target?.since ?? 0) < Self.userPinned),
           let other = env.paired.map(Self.norm).first(where: { $0 != address && isNearby($0)
               && env.now - (failedAt[$0] ?? -.infinity) > Self.nearbyCooldown }) {
            // 失败计数与退避都不归零：两台都连不上时不会来回换、每 6 秒打扰一次手机（真机 2026-10-24 07:34）
            out.append(.log("\(address) 连不上（码 \(code)），改连旁边的 \(other)"))
            if target?.why != .nearby { fallbackFrom = target }
            target = Target(address: other, why: .nearby, since: env.now)
            ensureLink()
            return
        }
        // 改连的旁边那台也连不上：回到原本那台，照退避重试（真机 2026-10-24 09:49：停在一台根本没配对的手机上一直试）
        if target?.why == .nearby, let home = fallbackFrom {
            out.append(.log("旁边的 \(address ?? "?") 也连不上：回到 \(home.address ?? "?")"))
            target = home
            fallbackFrom = nil
        }
        // R3.4 连续失败 → 自愈重启
        if failStreak >= 2 {
            out.append(.restartProcess(.selfHeal))
            return
        }
        retryAfterFailure()
    }

    /// R3.5：温和重试。也是重启被节流挡下之后的去处。
    private mutating func retryAfterFailure() {
        guard link == .idle, !retryPending else { return }
        if let address = target?.address {
            if failStreak == 1, lastFailCode == 9 || lastFailCode == 11 {
                out.append(.dropBaseband(address: address))
            }
            if lastFailCode == 9, failStreak == 1 {
                out.append(.refreshSDP(address: address, timeout: Self.sdpTimeout))
            }
            if lastFailCode == 11, failStreak >= 2, !republished {
                republished = true
                out.append(.republishSDP)
            }
        }
        scheduleRetry(backoff.next(live: false))
    }

    // MARK: - R4 交接

    private mutating func onAvailability(_ gen: Int, wired: Bool, wireless: Bool) {
        guard link.gen == gen, !isLive else { return }
        guard case .up(let kind, let address, _) = link else {
            if case .handoff = link { return }   // 补发链自己管，不另起一条
            return
        }
        sawAvailability = true
        cancel(.cabledWait)
        phoneWired = wired
        phoneWireless = wireless
        cancel(.wifiWait); cancel(.wifiNudge)
        link = .handoff(kind, address: address, gen: gen, resends: 0, since: env.now,
                        wirelessTried: kind == .usb && cabledWirelessFailed)
        sendStart(retry: false)
        set(.handoffResend, after: Self.firstResend)
        set(.wifiHelp, after: Self.wifiHelpAfter)
    }

    /// 送 0x4301。藍牙一律无线；USB 照 CarPlayTransportPolicy.startReply。
    private mutating func sendStart(retry: Bool) {
        guard case .handoff(let kind, _, let gen, let resends, _, let tried) = link else { return }
        if kind == .bluetooth {
            out.append(.sendStart(gen: gen, retry && resends == 1 ? .wirelessAlternate : .wireless))
            return
        }
        switch CarPlayTransportPolicy.startReply(wiredAvailable: phoneWired, wirelessAvailable: phoneWireless,
                                                 wifiReady: env.wifiReady, wifiConfigSent: wifiConfigSent,
                                                 ncmReady: env.ncmReady, wirelessTried: tried) {
        case .wireless:
            out.append(.sendStart(gen: gen, retry ? .wirelessAlternate : .wireless))
        case .pushWiFiConfigThenWireless:
            wifiConfigSent = true
            out.append(.sendWiFiConfig(gen: gen))
            out.append(.sendStart(gen: gen, .wireless))
        case .wired:
            out.append(.sendStart(gen: gen, .wired))
        case .waitNCM:
            out.append(.sendStart(gen: gen, .wirelessAlternate))
            if ncmSince == nil { ncmSince = env.now }
            set(.ncmPoll, after: Self.ncmEvery)
        case .none:
            out.append(.log("没有可用的 CarPlay 传输"))
        }
    }

    private mutating func onHandoffResend() {
        guard !isLive, case .handoff(let kind, let address, let gen, let resends, let since, _) = link else { return }
        // 插着线的手机从藍牙交接，12 秒没连回：不再补发 8 轮，直接走线（真机 2026-10-24 12:09：补发 2 分钟才退）
        if kind == .bluetooth, resends == 0, let address, usb?.phone == address {
            out.append(.log("\(address) 插着线，无线 12 秒没连回：改走 USB 有线"))
            cabledWirelessFailed = true
            closeCurrentLink()
            resetRetry()
            usbPreferred = true
            ensureLink()
            return
        }
        guard resends < Self.maxResends else {
            out.append(.log("补发 \(Self.maxResends) 次 0x4301 手机仍没连控制口：关掉这条，照退避重连"))
            closeCurrentLink()
            scheduleRetry(backoff.next(live: false))
            return
        }
        link = .handoff(kind, address: address, gen: gen, resends: resends + 1, since: since, wirelessTried: true)
        sendStart(retry: true)
        set(.handoffResend, after: Self.resendEvery)
    }

    private mutating func onTransportAvailable(_ gen: Int) {
        guard link.gen == gen, !isLive, !sawAvailability else { return }
        if tokens[.wifiWait] == nil, tokens[.wifiNudge] == nil { set(.wifiWait, after: Self.wifiWaitAfter) }
    }

    private mutating func onControlConnected(_ transport: CarPlayTransport) {
        lastControlAt = env.now
        pendingTransport = transport
        cancelHandoffTimers()
        cancel(.silence)
    }

    private mutating func cancelHandoffTimers() {
        for id in [TimerID.handoffResend, .wifiHelp, .wifiWait, .wifiNudge, .ncmPoll, .cabledWait] { cancel(id) }
        ncmSince = nil
    }

    // MARK: - R5 会话

    private mutating func onSessionActive() {
        let owner = link.address ?? target?.address
        session = .live(owner: owner, transport: pendingTransport, since: env.now)
        failStreak = 0
        cancelHandoffTimers()
        cancel(.silence)
        if case .handoff(let kind, let address, let gen, _, _, _) = link { link = .up(kind, address: address, gen: gen) }
        out.append(.publishPhones)
    }

    private mutating func onSessionEnded(_ why: SessionEndReason) {
        guard isLive else { return }   // 我们自己收掉时已经记过（换手机、重开、睡眠）
        let since: TimeInterval
        if case .live(_, _, let s) = session { since = s } else { since = env.now }
        session = .none
        pendingTransport = nil
        if case .handoff(let kind, let address, let gen, _, _, _) = link { link = .up(kind, address: address, gen: gen) }
        sawAvailability = false
        out.append(.publishPhones)
        switch why {
        case .phoneTeardown where env.now - since < Self.earlyTeardown:
            reopen("手机在 RECORD 后 \(String(format: "%.1f", env.now - since)) 秒就结束会话")
        case .silence:
            set(.silence, after: Self.silenceWait)
        default:
            break
        }
        if link == .idle, !retryPending { ensureLink() }
    }

    private mutating func onDisplayChanged() {
        guard isLive || { if case .handoff = link { return true } else { return false } }() else { return }
        reopen("显示宣告改了")
    }

    /// 重开会话：30 秒最多 3 次。连结还在就直接再送 0x4301，否则重开连结。
    private mutating func reopen(_ why: String) {
        reopenTimes = reopenTimes.filter { env.now - $0 < Self.reopenWindow }
        guard reopenTimes.count < Self.reopenMax else {
            out.append(.log("重开太频繁，跳过：\(why)"))
            return
        }
        reopenTimes.append(env.now)
        out.append(.log("重开会话：\(why)"))
        if isLive {
            session = .none
            out.append(.dropSession)
        }
        switch link {
        case .up(let kind, let address, let gen), .handoff(let kind, let address, let gen, _, _, _):
            cancelHandoffTimers()
            link = .handoff(kind, address: address, gen: gen, resends: 0, since: env.now, wirelessTried: false)
            sendStart(retry: false)
            set(.handoffResend, after: Self.firstResend)
            set(.wifiHelp, after: Self.wifiHelpAfter)
        case .opening:
            break
        case .idle:
            resetRetry()
            ensureLink()
        }
    }

    // MARK: - R6 睡眠与暂停

    private mutating func onSleep() {
        if isLive { session = .none; out.append(.dropSession) }
        closeCurrentLink()
        if retryPending { retryPending = false; cancel(.retry) }
        cancel(.silence)
        suspended.insert(.asleep)
    }

    private mutating func onWake() {
        suspended.remove(.asleep)
        resetRetry()
        set(.wakeOpen, after: Self.wakeDelay)
        retryPending = true   // 0.8 秒后再开，期间不被别的事件抢先
    }

    private mutating func onSuspend(_ why: SuspendReason, _ on: Bool) {
        if on {
            suspended.insert(why)
            if why == .cablePairing, link.kind == .usb { closeCurrentLink() }
        } else {
            suspended.remove(why)
            pairingHinted = false
            ensureLink()
        }
    }

    // MARK: - 计时器

    private mutating func onTimer(_ id: TimerID) {
        switch id {
        case .retry, .wakeOpen:
            retryPending = false
            ensureLink()
        case .handoffResend:
            onHandoffResend()
        case .wifiHelp:
            if !isLive, case .handoff = link { out.append(.notify(.wifiHelp)) }
        case .wifiWait:
            guard !isLive, !sawAvailability, link.gen != nil else { return }
            out.append(.notify(.wifiHelp))
            set(.wifiNudge, after: Self.nudgeAfter)
        case .wifiNudge:
            guard !isLive, !sawAvailability, link.gen != nil, env.now - lastNudgeAt >= Self.nudgeEvery else { return }
            lastNudgeAt = env.now
            out.append(.log("手机说无线可用却一直没送 0x4300：重连一次"))
            closeCurrentLink()
            resetRetry()
            ensureLink()
        case .ncmPoll:
            guard !isLive, case .handoff(.usb, _, let gen, _, _, _) = link else { return }
            if env.ncmReady {
                out.append(.sendStart(gen: gen, .wired))
                ncmSince = nil
            } else if env.now - (ncmSince ?? env.now) < Self.ncmGiveUp {
                set(.ncmPoll, after: Self.ncmEvery)
            } else {
                ncmSince = nil
                out.append(.log("NCM 等了 60 秒仍没就绪"))
            }
        case .cabledWait:
            guard !isLive, !sawAvailability, case .up(.bluetooth, let a?, _) = link, usb?.phone == a else { return }
            out.append(.log("\(a) 插着线，藍牙那边 \(Int(Self.cabledWait)) 秒没开始 CarPlay：改走 USB"))
            closeCurrentLink()
            resetRetry()
            usbPreferred = true
            ensureLink()
        case .silence:
            guard !isLive, env.now - lastControlAt > 10 else { return }
            out.append(.log("Wi-Fi 短断后 15 秒没回来：重连"))
            closeCurrentLink()
            resetRetry()
            ensureLink()
        }
    }

    private mutating func set(_ id: TimerID, after: TimeInterval) {
        tokenSeq += 1
        tokens[id] = tokenSeq
        out.append(.setTimer(id, after: after, token: tokenSeq))
    }

    private mutating func cancel(_ id: TimerID) {
        guard tokens.removeValue(forKey: id) != nil else { return }
        out.append(.cancelTimer(id))
    }

    private mutating func switchSession(to address: String?) {
        session = .none
        pendingTransport = nil
        out.append(.switchSession(to: address))
    }

    // MARK: - 小工具

    private func isPaired(_ address: String) -> Bool { env.paired.contains { Self.norm($0) == address } }
    private func isNearby(_ address: String) -> Bool { env.nearby.contains { Self.norm($0) == address } }
    package static func norm(_ address: String) -> String { PairingRules.normalize(address) }
}
