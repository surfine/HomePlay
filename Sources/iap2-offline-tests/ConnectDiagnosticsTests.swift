// 首次配對失敗樹（ConnectDiagnostics）與「改了 Wi-Fi 設定就立刻重叫手機」（ConnectionMachine .wifiChanged）。
import Foundation
import IAP2

enum ConnectDiagnosticsTests {
    static func run(_ expect: (Bool, String) -> Void) {
        typealias D = ConnectDiagnostics
        // 防火牆輸出解析（socketfilterfw 的真實字句）
        do {
            let off = D.Firewall.parse(global: "Firewall is disabled. (State = 0)",
                                       blockAll: "Firewall has block all state set to disabled.",
                                       app: "Incoming connection to /x/homeplay-receiver is permitted.",
                                       stealth: "Firewall stealth mode is off")
            expect(!off.enabled && !off.blockAll && !off.receiverBlocked && !off.stealth && !off.blocksReceiver, "firewall off parses as off")
            let denied = D.Firewall.parse(global: "Firewall is enabled. (State = 1)",
                                          blockAll: "Firewall has block all state set to disabled.",
                                          app: "Incoming connection to /x/homeplay-receiver is blocked.",
                                          stealth: "Firewall stealth mode is on")
            expect(denied.blocksReceiver && denied.stealth, "firewall on + receiver denied blocks the phone")
            let all = D.Firewall.parse(global: "Firewall is blocking all non-essential incoming connections. (State = 2)",
                                       blockAll: "Firewall has block all state set to enabled.", app: "", stealth: "")
            expect(all.blocksReceiver, "block-all blocks the phone")
            let allowed = D.Firewall.parse(global: "Firewall is enabled. (State = 1)",
                                           blockAll: "Firewall has block all state set to disabled.",
                                           app: "Incoming connection to /x/homeplay-receiver is permitted.", stealth: "")
            expect(allowed.enabled && !allowed.blocksReceiver, "firewall on but receiver allowed is fine")
        }

        // 判斷樹：每一枝各走一次
        func stalledAfterStart(ssid: Bool) -> D {
            var d = D(now: 0)
            d.ssidKnown = ssid
            d.authenticated(now: 1)
            d.availability(now: 2)
            d.startSent(now: 2.1)
            return d
        }
        do {
            var d = D(now: 0)
            expect(d.stalledReason(now: 100) == nil, "no iPhone yet → no verdict")
            d.authenticated(now: 10)
            expect(d.stalledReason(now: 25) == nil, "consent: not before 20 s")
            expect(d.stalledReason(now: 31) == .carPlayConsent, "authenticated, no CarPlay start for 20 s → tap Connect on iPhone")
            d.transportAvailable(now: 32)
            d.startSent(now: 33)
            d.ssidKnown = true
            expect(d.stalledReason(now: 50) == .wifiNoConnectBack, "start sent, no connect-back → Wi-Fi help")
        }
        do {
            let d = stalledAfterStart(ssid: false)
            expect(d.stalledReason(now: 8) == .ssidUnknown, "empty Wi-Fi name handed to iPhone → ask for the network name")
        }
        do {
            var d = stalledAfterStart(ssid: true)
            d.browseState(.ready)
            d.servicesSeen(1)
            d.probe(answered: true)
            expect(d.stalledReason(now: 20) == .inboundBlocked, "iPhone answers our probe but never connects in → something blocks inbound")
            d.authenticated(now: 30); d.availability(now: 31); d.startSent(now: 31)
            expect(d.stalledReason(now: 50) == .wifiNoConnectBack, "a probe answered in an earlier attempt does not count for this one")
            d.startSent(now: 32, wired: true)
            expect(d.stalledReason(now: 50) == nil, "a wired start stalling is not a Wi-Fi problem")
        }
        do {
            var d = stalledAfterStart(ssid: false)
            d.browseState(.denied)
            d.browseState(.waiting)
            expect(d.browse == .denied, "a later waiting does not hide policy denied")
            expect(d.stalledReason(now: 20) == .localNetwork, "Local Network denied outranks the Wi-Fi name")
            d.firewall = D.Firewall(enabled: true, blockAll: true, receiverBlocked: false, stealth: false)
            expect(d.stalledReason(now: 20) == .macFirewall, "firewall outranks everything")
            d.browseState(.ready)
            expect(d.browse == .ready, "ready clears denied")
        }
        do {
            var d = stalledAfterStart(ssid: true)
            d.firewall = D.Firewall(enabled: true, blockAll: true, receiverBlocked: false, stealth: false)
            d.controlConnected(now: 2.4)
            expect(d.stalledReason(now: 30) == nil, "phone connected in → not this tree's problem")
            d.sessionStarted(now: 3)
            expect(d.live && d.setupTimes.count == 1 && abs(d.setupTimes[0] - 2) < 1e-9, "connect time measured from authentication")
            d.sessionEnded("phoneTeardown")
            d.authenticated(now: 50)
            expect(d.controlAt == nil && d.firstStartAt == nil && d.attemptStarts == 0, "new attempt clears per-attempt timings")
        }

        // 報告：只有次數與狀態（結構裡根本沒有 SSID、位址、名字欄位）
        do {
            var d = stalledAfterStart(ssid: true)
            d.mode = "dual"; d.security = "WPA2"; d.wifiBand = "5 GHz"; d.wifiChannel = 149; d.wifiIPv4 = true
            d.linkEnded("code 9"); d.linkEnded("code 9"); d.hintShown(.wifiNoConnectBack)
            let text = d.reportLines(now: 40).joined(separator: "\n")
            expect(text.contains("Verdict: wifiNoConnectBack"), "report carries the verdict")
            expect(text.contains("code 9×2") && text.contains("5 GHz (ch 149)") && text.contains("name known yes"), "report carries counts and band")
        }

        // 有線：carkit 打不開的原因分類（用 Iap2Usbmuxd 真的會丟出來的字句）
        do {
            typealias U = UsbOpenFailure
            expect(U.classify("usbmuxd 协议：ReadPairRecord 被拒（Number 2）——先在 Finder 里信任这台 Mac") == .notTrusted, "no pair record → not trusted yet")
            expect(U.classify("lockdown 配对记录：缺 HostID/SystemBUID——先在 Finder 里信任") == .notTrusted, "missing host id → not trusted yet")
            expect(U.classify("lockdown StartService：PasswordProtected") == .locked, "PasswordProtected → unlock iPhone")
            expect(U.classify("lockdown StartSession：InvalidHostID——信任过期，重新信任一次") == .trustExpired, "StartSession refused → trust again")
            expect(U.classify("lockdown ProductType：USB 设备不是 iPhone（iPad13,1）") == .notIPhone, "not an iPhone")
            expect(U.classify("usbmuxd：读超时（读了 0/16）") == .other, "anything else → other")
            var d = D(now: 0)
            d.usbAttached(); d.usbOpenFailed(.locked); d.usbNoDataSeen()
            let text = d.reportLines(now: 1).joined(separator: "\n")
            expect(text.contains("USB: attached 1 · open failures locked×1 · on bus without data 1"), "report carries the USB line")
        }
        // 狀態機：NCM 60 秒沒出現 → 提示（不只寫日誌）
        do {
            var s = MachineSim(paired: [], processAge: 300)
            s.send(.usbAttached(serial: "u1", phone: nil))
            s.send(.start(preferred: nil))
            let g = s.gen
            s.send(.linkAuthenticated(gen: g))
            s.send(.availability(gen: g, wired: true, wireless: false))
            let fx = s.advance(70)
            expect(fx.contains(.notify(.usbNoNetwork)), "NCM missing for 60 s → USB help card")
        }

        // 狀態機：交接中改了 Wi-Fi → 立刻重送 0x4301；直播中改了不打斷
        do {
            let A = "AA:BB:CC:DD:EE:01"
            var s = MachineSim(paired: [A], nearby: [A], processAge: 300)
            s.send(.start(preferred: A))
            let g = s.gen
            s.send(.linkAuthenticated(gen: g))
            s.send(.availability(gen: g, wired: false, wireless: true))
            let fx = s.send(.wifiChanged)
            expect(fx.compactMap(\.startKind) == [.wireless], "Wi-Fi settings changed mid-handoff → 0x4301 again right away")
            s.send(.controlConnected(.wifi))
            s.send(.sessionActive)
            let live = s.send(.wifiChanged)
            expect(live.isEmpty, "Wi-Fi settings changed while live → nothing (no dropped picture)")
        }
    }
}
