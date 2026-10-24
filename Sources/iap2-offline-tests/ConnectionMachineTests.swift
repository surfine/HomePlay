// 连线状态机的情境测试：模拟时钟＋计时器，按真机的事件顺序驱动（设计稿「測試情境」1–14）。
import Foundation
import IAP2

/// 模拟器：记下状态机排的计时器，按时间推进时依序触发。
struct MachineSim {
    var m = ConnectionMachine()
    var env: ConnectionEnvironment
    var timers: [TimerID: (at: TimeInterval, token: Int)] = [:]
    var log: [ConnectionEffect] = []
    var startedAt: TimeInterval = 0

    init(paired: [String], nearby: Set<String> = [], processAge: TimeInterval = 0) {
        env = ConnectionEnvironment(now: 100, processAge: processAge, paired: paired, nearby: nearby)
        startedAt = 100 - processAge
    }

    var gen: Int { m.link.gen ?? -1 }

    @discardableResult
    mutating func send(_ e: ConnectionEvent) -> [ConnectionEffect] {
        env.processAge = env.now - startedAt
        let fx = m.handle(e, env)
        for f in fx {
            switch f {
            case .setTimer(let id, let after, let token): timers[id] = (env.now + after, token)
            case .cancelTimer(let id): timers[id] = nil
            default: break
            }
        }
        log += fx
        return fx
    }

    /// 推进时间；途中到期的计时器按时间先后触发。回传这段期间的所有效果。
    @discardableResult
    mutating func advance(_ seconds: TimeInterval) -> [ConnectionEffect] {
        let end = env.now + seconds
        var all: [ConnectionEffect] = []
        while let (id, t) = timers.filter({ $0.value.at <= end }).min(by: { $0.value.at < $1.value.at }) {
            timers[id] = nil
            env.now = max(env.now, t.at)
            all += send(.timer(id, token: t.token))
        }
        env.now = end
        return all
    }

    /// 走完一次成功的交接：认证 → 0x4300 → 控制 → RECORD。
    mutating func connectOK(wifi: Bool = true) {
        let g = gen
        send(.linkAuthenticated(gen: g))
        send(.availability(gen: g, wired: false, wireless: true))
        advance(0.3)
        send(.controlConnected(wifi ? .wifi : .usbNCM))
        advance(0.5)
        send(.sessionActive)
    }
}

extension ConnectionEffect {
    var opensBluetooth: String? { if case .openBluetooth(let a, _) = self { return a } else { return nil } }
    var opensUSB: Bool { if case .openUSB = self { return true } else { return false } }
    var isOpen: Bool { opensBluetooth != nil || opensUSB || { if case .adoptIncoming = self { return true } else { return false } }() }
    var startKind: StartKind? { if case .sendStart(_, let k) = self { return k } else { return nil } }
    var restart: RestartKind? { if case .restartProcess(let k) = self { return k } else { return nil } }
}

enum ConnectionMachineTests {
    static let A = "50:3B:70:CB:AE:56"   // iPhone 18 Pro
    static let B = "E0:C7:67:DE:D7:CE"   // SE

    static func run(_ expect: (Bool, String) -> Void) {
        // 1. 开机连上次那台
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B])
            let fx = s.send(.start(preferred: A))
            expect(fx.compactMap(\.opensBluetooth) == [A], "1 start opens Bluetooth to the last phone")
            let g = s.gen
            s.send(.linkAuthenticated(gen: g))
            let st = s.send(.availability(gen: g, wired: false, wireless: true))
            expect(st.compactMap(\.startKind) == [.wireless], "1 0x4300 over Bluetooth → wireless 0x4301")
            s.send(.controlConnected(.wifi))
            s.send(.sessionActive)
            expect(s.m.liveOwner == A, "1 live owner is the connected phone")
            expect(s.timers[.handoffResend] == nil && s.timers[.wifiHelp] == nil, "1 control connected cancels handoff timers")
        }

        // 1b. 刚起来时系统配对清单短暂读不到：仍连上次那台，不改连线上那台
        do {
            var s = MachineSim(paired: [], processAge: 0.5)
            s.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: true))
            let fx = s.send(.start(preferred: A))
            expect(fx.compactMap(\.opensBluetooth) == [A] && !fx.contains { $0.opensUSB }, "1b empty pairing list at boot → still the last phone")
            let np = s.send(.linkUnavailable(gen: s.gen, .notPaired))
            expect(s.m.target?.address == A && np.contains { if case .setTimer(.retry, _, _) = $0 { return true } else { return false } }, "1b 'not paired' just backs off, never forgets")
        }

        // 1c. 上一个行程被硬杀：先断基带，1 秒后再开
        do {
            var s = MachineSim(paired: [A], nearby: [A], processAge: 0.5)
            let fx = s.send(.start(preferred: A, crashed: true))
            expect(fx.contains(.dropBaseband(address: A)) && !fx.contains { $0.isOpen }, "1c crashed → drop baseband first")
            expect(s.advance(1).compactMap(\.opensBluetooth) == [A], "1c open 1 s later")
        }

        // 2. 已知手机重连：第一次逾时（码 9）→ 断基带＋查 SDP → 退避 2 秒 → 成功
        do {
            var s = MachineSim(paired: [A], nearby: [A], processAge: 300)
            s.send(.start(preferred: A))
            let fx = s.send(.linkFinished(gen: s.gen, code: 9))
            expect(fx.contains(.dropBaseband(address: A)) && fx.contains(.refreshSDP(address: A, timeout: 4)), "2 first code 9 → drop baseband + SDP refresh")
            expect(!fx.contains { $0.isOpen }, "2 no immediate retry after a failure")
            let later = s.advance(2)
            expect(later.compactMap(\.opensBluetooth) == [A], "2 retry after 2 s")
            s.connectOK()
            expect(s.m.isLive && s.m.failStreak == 0, "2 reconnect succeeds and resets the streak")
        }

        // 3. 刚起来的行程第一次失败 → 要求重启；被节流挡下 → 照退避
        do {
            var s = MachineSim(paired: [A], nearby: [A], processAge: 3)
            s.send(.start(preferred: A))
            let fx = s.send(.linkFinished(gen: s.gen, code: 9))
            expect(fx.compactMap(\.restart) == [.young], "3 young process + first failure → restart once")
            let denied = s.send(.restartDenied(.young))
            expect(denied.contains { if case .setTimer(.retry, 2, _) = $0 { return true } else { return false } }, "3 restart denied → calm backoff")
            expect(s.advance(2).compactMap(\.opensBluetooth) == [A], "3 retries after backoff")
            let second = s.send(.linkFinished(gen: s.gen, code: 9))
            expect(second.compactMap(\.restart) == [.selfHeal], "3 second failure → self-heal request")
        }

        // 4. 目标不在、旁边那台在 → 第一次失败就改连；使用者刚选的不改
        do {
            var s = MachineSim(paired: [A, B], nearby: [B], processAge: 300)
            s.send(.start(preferred: A))
            let fx = s.send(.linkFinished(gen: s.gen, code: 9))
            expect(fx.compactMap(\.opensBluetooth) == [B], "4 absent target → nearby phone right away")
            expect(s.m.target?.why == .nearby, "4 target reason is nearby")

            var u = MachineSim(paired: [A, B], nearby: [B], processAge: 300)
            u.send(.start(preferred: B))
            u.send(.userSelect(A))
            let ufx = u.send(.linkFinished(gen: u.gen, code: 9))
            expect(ufx.compactMap(\.opensBluetooth).isEmpty, "4 user's fresh choice is not overridden")
        }

        // 4a. 目标连不上、线上插着另一台（开机时就插着）→ 改连线上那台
        do {
            var s = MachineSim(paired: [A, B], nearby: [A], processAge: 2)
            s.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: false))
            s.send(.start(preferred: A))
            var fx = s.send(.linkFinished(gen: s.gen, code: 9))
            if fx.contains(where: { $0.restart != nil }) { fx = s.send(.restartDenied(.young)) }
            fx += s.advance(10)
            if s.m.link.kind != .usb { fx += s.send(.linkFinished(gen: s.gen, code: 9)) }
            expect(s.m.link.kind == .usb && s.m.target?.address == B, "4a target unreachable → the phone on the cable over USB")
        }

        // 4c. 改连旁边那台也失败 → 回到原本那台
        do {
            var s = MachineSim(paired: [A, B], nearby: [B], processAge: 300)
            s.send(.start(preferred: A))
            s.send(.linkFinished(gen: s.gen, code: 9))          // A 失败 → 改连 B
            expect(s.m.target?.address == B, "4c fell back to the nearby phone")
            let fx = s.send(.linkFinished(gen: s.gen, code: 9)) // B 也失败
            if fx.contains(where: { $0.restart != nil }) { s.send(.restartDenied(.selfHeal)) }
            expect(s.m.target?.address == A, "4c nearby phone failed too → back to the original target")
        }

        // 4b. 两台都连不上：只改连一次，不来回换；之后照退避（2 分钟内开连结次数有上限）
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 300)
            s.send(.start(preferred: A))
            var opens = 1
            for _ in 0..<40 {
                let fx = s.send(.linkFinished(gen: s.gen, code: 9))
                if fx.contains(where: { $0.restart != nil }) { s.send(.restartDenied(.selfHeal)) }
                opens += fx.filter(\.isOpen).count
                let later = s.advance(3)
                opens += later.filter(\.isOpen).count
                if s.env.now > 220 { break }
            }
            expect(opens <= 8, "4b both phones failing → no ping-pong (opens in ~2 min: \(opens))")
        }

        // 5. 选单换手机
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 300)
            s.send(.start(preferred: A))
            s.connectOK()
            let g = s.gen
            let fx = s.send(.userSelect(B))
            expect(fx.contains(.closeLink(gen: g)), "5 switch closes the old link")
            expect(fx.contains(.switchSession(to: B)), "5 live switch ends the old session toward the new phone")
            expect(fx.compactMap(\.opensBluetooth) == [B], "5 opens the new phone at once")
            expect(fx.firstIndex(of: .closeLink(gen: g))! < fx.firstIndex { $0.opensBluetooth != nil }!, "5 close before open")
            s.send(.sessionEnded(.ours))
            s.connectOK()
            expect(s.m.liveOwner == B, "5 new owner after switch")
            let same = s.send(.userSelect(B))
            expect(!same.contains { $0.isOpen } && !same.contains { if case .closeLink = $0 { return true } else { return false } }, "5 selecting the live phone does nothing")
        }

        // 6. 插线那台：选插着线的 → 直接开 USB；插着线时选另一台 → 关 USB、开藍牙
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 2)
            s.send(.usbAttached(serial: "a5a4", phone: B))
            s.send(.start(preferred: A))
            expect(s.m.link.kind == .bluetooth && s.m.link.address == A, "6 old cable at startup doesn't take over")
            s.connectOK()
            s.advance(20)
            let fx = s.send(.userSelect(B))
            expect(fx.contains { $0.opensUSB } && fx.compactMap(\.opensBluetooth).isEmpty, "6 select the cabled phone → USB")
            let g = s.gen
            s.send(.linkAuthenticated(gen: g))
            s.env.ncmReady = false
            let st = s.send(.availability(gen: g, wired: true, wireless: true))
            expect(st.contains(.sendWiFiConfig(gen: g)) && st.compactMap(\.startKind) == [.wireless], "6 USB 0x4300 → Wi-Fi config then wireless")
            s.env.ncmReady = true
            let fb = s.advance(12)
            expect(fb.compactMap(\.startKind) == [.wired], "6 no control after 12 s → wired fallback")
            s.send(.controlConnected(.usbNCM))
            s.send(.sessionActive)
            let back = s.send(.userSelect(A))
            expect(back.contains(.closeLink(gen: g)) && back.compactMap(\.opensBluetooth) == [A], "6 select the other phone → close USB, open Bluetooth")
        }

        // 6b. 已配对手机的线只充电：先走藍牙（拔线不断）；藍牙连不上才开 USB
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 2)
            s.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: true))
            let fx = s.send(.start(preferred: B))
            expect(fx.compactMap(\.opensBluetooth) == [B], "6b charge-only cabled target → Bluetooth first")
            s.advance(30)
            let f = s.send(.linkFinished(gen: s.gen, code: 9))
            expect(f.contains { $0.opensUSB }, "6b Bluetooth fails for the cabled phone → USB at once")
            var p = MachineSim(paired: [A, B], nearby: [A, B], processAge: 300)
            p.send(.start(preferred: A))
            p.connectOK()
            let pf = p.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: true))
            expect(pf.contains { $0.opensUSB }, "6b a real plug goes straight to USB even when charge-only")
            var u = MachineSim(paired: [A, B], nearby: [A, B], processAge: 300)
            u.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: true))
            u.send(.start(preferred: A))
            u.connectOK()
            let uf = u.send(.userSelect(B))
            expect(uf.contains { $0.opensUSB } && uf.compactMap(\.opensBluetooth).isEmpty, "6b user picks the cabled phone → USB straight away")
        }

        // 6d. 插着线的手机藍牙接上了但不报 0x4300 → 5 秒后改走 USB；报了就不动
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 2)
            s.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: true))
            s.send(.start(preferred: B))
            let g = s.gen
            s.send(.linkAuthenticated(gen: g))
            s.send(.transportAvailable(gen: g))
            let fx = s.advance(5)
            expect(fx.contains(.closeLink(gen: g)) && fx.contains { $0.opensUSB }, "6d cabled phone silent on Bluetooth → USB after 5 s")
            var k = MachineSim(paired: [A, B], nearby: [A, B], processAge: 2)
            k.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: true))
            k.send(.start(preferred: B))
            k.send(.linkAuthenticated(gen: k.gen))
            k.send(.availability(gen: k.gen, wired: false, wireless: true))
            expect(!k.advance(6).contains { $0.opensUSB }, "6d Bluetooth handoff started → stay on Bluetooth")
        }

        // 6e. 插着线、藍牙交接 12 秒没连回 → 改走 USB，而且直接开有线
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 2)
            s.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: true))
            s.send(.start(preferred: B))
            s.send(.linkAuthenticated(gen: s.gen))
            s.send(.availability(gen: s.gen, wired: false, wireless: true))
            let fx = s.advance(12)
            expect(fx.contains { $0.opensUSB }, "6e cabled phone, no Wi-Fi reconnect in 12 s → USB")
            let g = s.gen
            s.send(.linkAuthenticated(gen: g))
            s.env.ncmReady = true
            let st = s.send(.availability(gen: g, wired: true, wireless: true))
            expect(st.compactMap(\.startKind) == [.wired], "6e wireless already failed on this cable → wired 0x4301 straight away")
        }

        // 6c. 插线那台藍牙一直「没服务」→ 第一次就改走 USB；USB 补发照手机报的可用性
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 2)
            s.send(.usbAttached(serial: "a5a4", phone: B, chargeOnly: true))
            s.send(.start(preferred: B))
            let fx = s.send(.linkUnavailable(gen: s.gen, .noService))
            expect(fx.contains { $0.opensUSB }, "6c Bluetooth noService for the cabled phone → USB")
            let g = s.gen
            s.send(.linkAuthenticated(gen: g))
            s.env.ncmReady = true
            s.send(.availability(gen: g, wired: false, wireless: true))
            let re = s.advance(12)
            expect(!re.contains(.sendStart(gen: g, .wired)), "6c phone said no wired → resend never sends wired 0x4301")
            let exhausted = s.advance(400)
            expect(exhausted.contains(.closeLink(gen: g)), "6c resends exhausted → relink instead of hanging")
        }

        // 7. 真的插上另一台 → 换过去；USB 学到藍牙地址
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 300)
            s.send(.start(preferred: A))
            s.connectOK()
            let fx = s.send(.usbAttached(serial: "a5a4", phone: B))
            expect(fx.contains(.switchSession(to: B)) && fx.contains { $0.opensUSB }, "7 real plug of another phone takes over over USB")
            expect(s.m.target?.why == .plug, "7 target reason is plug")
            var n = MachineSim(paired: [A], nearby: [A], processAge: 300)
            n.send(.start(preferred: A))
            n.connectOK()
            let nfx = n.send(.usbAttached(serial: "zz", phone: nil))
            expect(nfx.contains { $0.opensUSB }, "7 real plug of an unknown phone → USB for cable pairing")
            n.send(.usbLearned(phone: B))
            expect(n.m.target?.address == B, "7 learned address becomes the target")
        }

        // 8. 交接补发：12 秒第一次（换安全类型），之后每 15 秒，共 8 次；30 秒 wifiHelp；控制一连上全部取消
        do {
            var s = MachineSim(paired: [A], nearby: [A], processAge: 300)
            s.send(.start(preferred: A))
            let g = s.gen
            s.send(.linkAuthenticated(gen: g))
            s.send(.availability(gen: g, wired: false, wireless: true))
            let first = s.advance(12)
            expect(first.compactMap(\.startKind) == [.wirelessAlternate], "8 first resend at 12 s uses the alternate profile")
            let help = s.advance(18)
            expect(help.contains(.notify(.wifiHelp)), "8 Wi-Fi help card at 30 s")
            let rest = s.advance(200)
            let resends = rest.compactMap(\.startKind).count + help.compactMap(\.startKind).count + 1
            expect(resends == ConnectionMachine.maxResends, "8 eight resends in total (got \(resends))")
            var c = MachineSim(paired: [A], nearby: [A], processAge: 300)
            c.send(.start(preferred: A))
            c.send(.linkAuthenticated(gen: c.gen))
            c.send(.availability(gen: c.gen, wired: false, wireless: true))
            c.advance(5)
            c.send(.controlConnected(.wifi))
            expect(c.advance(100).compactMap(\.startKind).isEmpty, "8 control connected stops resends")
            let dup = c.send(.availability(gen: c.gen, wired: false, wireless: true))
            expect(dup.compactMap(\.startKind).isEmpty, "8 a second 0x4300 during handoff doesn't start a second chain")
        }

        // 9. 会话刚开始就被拆 → 重开，30 秒最多 3 次
        do {
            var s = MachineSim(paired: [A], nearby: [A], processAge: 300)
            s.send(.start(preferred: A))
            s.connectOK()
            var reopens = 0
            for _ in 0..<5 {
                s.advance(0.5)
                let fx = s.send(.sessionEnded(.phoneTeardown))
                if fx.contains(where: { $0.startKind != nil }) { reopens += 1 }
                s.send(.controlConnected(.wifi))
                s.send(.sessionActive)
            }
            expect(reopens == 3, "9 early teardown reopens at most 3 times per 30 s (got \(reopens))")
            s.advance(31)
            let fx = s.send(.sessionEnded(.phoneTeardown))
            expect(!fx.contains { $0.startKind != nil }, "9 a teardown long after RECORD is not reopened")
        }

        // 10. Wi-Fi 短断 → 15 秒没回来就重连；回来了就不动
        do {
            var s = MachineSim(paired: [A], nearby: [A], processAge: 300)
            s.send(.start(preferred: A))
            s.connectOK()
            let g = s.gen
            s.advance(30)
            s.send(.sessionEnded(.silence))
            let fx = s.advance(15)
            expect(fx.contains(.closeLink(gen: g)) && fx.compactMap(\.opensBluetooth) == [A], "10 no reconnect in 15 s → relink")
            var r = MachineSim(paired: [A], nearby: [A], processAge: 300)
            r.send(.start(preferred: A))
            r.connectOK()
            r.advance(30)
            r.send(.sessionEnded(.silence))
            r.advance(3)
            r.send(.controlConnected(.wifi))
            r.send(.sessionActive)
            expect(!r.advance(20).contains { if case .closeLink = $0 { return true } else { return false } }, "10 came back by itself → leave it")
        }

        // 11. 旧连结晚到的事件不影响新连结
        do {
            var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: 300)
            s.send(.start(preferred: A))
            let old = s.gen
            s.send(.userSelect(B))
            let fx = s.send(.linkFinished(gen: old, code: 10))
            expect(fx.isEmpty && s.m.link.address == B && s.m.link.isOpening, "11 stale finish is ignored")
            expect(s.send(.availability(gen: old, wired: false, wireless: true)).isEmpty, "11 stale 0x4300 is ignored")
        }

        // 12. 睡眠：直播收掉、不再尝试；喚醒 0.8 秒后重连
        do {
            var s = MachineSim(paired: [A], nearby: [A], processAge: 300)
            s.send(.start(preferred: A))
            s.connectOK()
            let fx = s.send(.sleep)
            expect(fx.contains(.dropSession) && !s.m.isLive, "12 sleep drops the session")
            expect(s.advance(600).isEmpty, "12 nothing happens while asleep")
            s.send(.wake)
            expect(s.advance(0.5).isEmpty, "12 not before 0.8 s")
            expect(s.advance(0.5).compactMap(\.opensBluetooth) == [A], "12 reconnect 0.8 s after wake")
        }

        // 13. 配对引导中：不主动开；只接受手机主动连入
        do {
            var s = MachineSim(paired: [], processAge: 300)
            let fx = s.send(.start(preferred: nil))
            expect(fx.contains(.notify(.needPairing)) && !fx.contains { $0.isOpen }, "13 no paired phone → pairing hint, no open")
            s.send(.suspend(.pairingGuide, true))
            s.env.paired = [A]
            expect(s.send(.phonesChanged).isEmpty, "13 no active open while the guide runs")
            let inc = s.send(.incoming(A))
            expect(inc.contains(.adoptIncoming(address: A, gen: s.gen)), "13 incoming connection is adopted")
            let busy = s.send(.incoming(B))
            expect(busy == [.rejectIncoming(address: B)], "13 a second incoming is rejected (one at a time)")
        }

        // 14. 性质测试：任何事件序列下最多一条在开；开之前一定先关旧的
        do {
            var rng = SplitMix(seed: 42)
            var violations = 0
            for _ in 0..<2000 {
                var s = MachineSim(paired: [A, B], nearby: [A, B], processAge: Double(rng.next() % 120))
                s.send(.start(preferred: rng.next() % 2 == 0 ? A : B))
                var open: Int? = s.m.link.gen
                for _ in 0..<40 {
                    let g = s.gen
                    let events: [ConnectionEvent] = [
                        .userSelect(rng.next() % 2 == 0 ? A : B), .linkAuthenticated(gen: g),
                        .linkFinished(gen: g, code: [0, 3, 9, 10, 11][Int(rng.next() % 5)]),
                        .linkFinished(gen: g - 1, code: 10),
                        .availability(gen: g, wired: rng.next() % 2 == 0, wireless: true),
                        .transportAvailable(gen: g), .controlConnected(.wifi), .sessionActive,
                        .sessionEnded([.phoneTeardown, .controlClosed, .silence, .ours][Int(rng.next() % 4)]),
                        .usbAttached(serial: "s", phone: B), .usbDetached, .incoming(A), .incoming(B),
                        .displayChanged, .sleep, .wake, .restartDenied(.selfHeal),
                        .linkUnavailable(gen: g, [.noService, .notPaired, .notFound][Int(rng.next() % 3)]),
                    ]
                    let fx: [ConnectionEffect]
                    if rng.next() % 3 == 0 {
                        fx = s.advance(Double(rng.next() % 40))
                    } else {
                        let e = events[Int(rng.next() % UInt64(events.count))]
                        // 手机那边结束的连结（finish／unavailable）本来就关了
                        switch e {
                        case .linkFinished(let fg, _), .linkUnavailable(let fg, _): if fg == open { open = nil }
                        default: break
                        }
                        fx = s.send(e)
                    }
                    for f in fx {
                        if case .closeLink(let cg) = f, cg == open { open = nil }
                        if case .openBluetooth(_, let ng) = f { if open != nil { violations += 1 }; open = ng }
                        if case .openUSB(let ng) = f { if open != nil { violations += 1 }; open = ng }
                        if case .adoptIncoming(_, let ng) = f { if open != nil { violations += 1 }; open = ng }
                    }
                    // 连结自己结束（linkFinished/Unavailable）就不再算开着
                    if s.m.link == .idle { open = nil }
                }
            }
            expect(violations == 0, "14 never two links at once over 2000 random runs (violations \(violations))")
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
