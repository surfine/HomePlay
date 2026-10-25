// 連不上時的現場紀錄與判斷：首次配對「CarPlay 清單裡有 HomePlay，卻一直停在正在連線」的失敗樹
//（docs/wireless.md「首次配對連不上」）。接收器在主執行緒餵事件，卡住時問 stalledReason，
// 桌寵按原因給一句可以照做的話；「拷貝診斷報告」用 reportLines。
// 只記次數、秒數與狀態：不含 SSID、密碼、IP、藍牙位址、裝置名稱或配件身份，可以整段貼給別人。
// 純邏輯，不碰 IOBluetooth／Network；離線測試直接驅動。
import Foundation

package struct ConnectDiagnostics: Sendable {
    /// 卡住的原因。宣告順序＝判斷優先序（越前面越確定、越容易修）。
    package enum Reason: String, Sendable, CaseIterable {
        case macFirewall        // Mac 防火牆擋住接收器的傳入連線（全擋，或使用者點過「拒絕」）
        case localNetwork       // macOS「本地網路」權限被拒：瀏覽不到 iPhone、也連不出去
        case carPlayConsent     // 藍牙認證過了，iPhone 遲遲沒說要開 CarPlay（等使用者解鎖、點「連接」）
        case ssidUnknown        // 不知道 Wi-Fi 名稱（macOS 對 App 隱藏）：iPhone 拿到的 Wi-Fi 設定是空的
        case inboundBlocked     // iPhone 在同一個網路（回應了我們的探測），卻連不進 Mac：第三方防火牆之類
        case wifiNoConnectBack  // 交了 Wi-Fi 設定、送了開會話，iPhone 沒從 Wi-Fi 連回來
        // 有線：不由 stalledReason 判斷，接收器看到就直接給卡
        case usbNoData          // iPhone 在 USB 匯流排上，usbmuxd 卻看不到（鎖著／USB 限制模式／只供電的線或擴充座）
        case usbLocked          // carkit 打不開：PasswordProtected
        case usbTrustExpired    // carkit 打不開：配對記錄在但 lockdown 不認
        case usbNoNetwork       // 有線會話要的 NCM 網口 60 秒沒出現
    }

    /// _carplay-ctrl 瀏覽器的狀態
    package enum Browse: String, Sendable { case notStarted = "not started", ready, waiting, denied, failed }

    /// macOS 應用程式防火牆（socketfilterfw 的唯讀查詢）
    package struct Firewall: Equatable, Sendable {
        package var enabled: Bool
        package var blockAll: Bool
        package var receiverBlocked: Bool
        package var stealth: Bool
        package init(enabled: Bool, blockAll: Bool, receiverBlocked: Bool, stealth: Bool) {
            self.enabled = enabled; self.blockAll = blockAll; self.receiverBlocked = receiverBlocked; self.stealth = stealth
        }
        /// 開著，而且擋全部或擋了接收器：iPhone 的 TCP 連線進不來
        package var blocksReceiver: Bool { enabled && (blockAll || receiverBlocked) }

        /// 解析四個查詢的輸出（--getglobalstate、--getblockall、--getappblocked <路徑>、--getstealthmode）。
        /// 例：「Firewall is enabled. (State = 1)」「Firewall has block all state set to enabled.」
        ///    「Incoming connection to /…/homeplay-receiver is blocked.」「Firewall stealth mode is on」
        package static func parse(global: String, blockAll: String, app: String, stealth: String) -> Firewall {
            let g = global.lowercased(), b = blockAll.lowercased(), a = app.lowercased(), s = stealth.lowercased()
            let on = g.contains("is enabled") || g.contains("state = 1") || g.contains("state = 2")
            return Firewall(enabled: on,
                            blockAll: b.contains("set to enabled") || g.contains("state = 2"),
                            receiverBlocked: a.contains("is blocked"),
                            stealth: s.contains("mode is on"))
        }
    }

    // ── 環境（接收器在判斷、出報告前更新）──
    package var mode = ""
    package var ssidKnown = false
    package var passphraseSaved = false
    package var wifiIPv4 = false
    package var wifiLinkLocalV6 = false
    package var wifiBand = ""          // 2.4 GHz／5 GHz／6 GHz；讀不到留空
    package var wifiChannel = 0
    package var security = ""
    package var pairedPhones = 0
    package var ignoredPhones = 0
    package var firewall: Firewall?

    // ── 累計 ──
    package private(set) var linkOpens = 0
    package private(set) var linkAuthenticated = 0
    package private(set) var linkEnds: [String: Int] = [:]
    package private(set) var wifiConfigSent = 0
    package private(set) var startsSent = 0
    package private(set) var controlConnects = 0
    package private(set) var sessionsStarted = 0
    package private(set) var sessionEnds: [String: Int] = [:]
    package private(set) var hintsShown: [Reason: Int] = [:]
    package private(set) var browse: Browse = .notStarted
    package private(set) var ctrlServices = 0          // 瀏覽到最多幾個 _carplay-ctrl 服務
    package private(set) var probesAnswered = 0
    package private(set) var probesFailed = 0
    package private(set) var setupTimes: [Double] = []  // 認證 → 會話開始（秒），最近 10 次
    package private(set) var live = false
    // ── 有線 ──
    package private(set) var usbAttaches = 0
    package private(set) var usbOpenFailures: [String: Int] = [:]   // UsbOpenFailure.rawValue → 次數
    package private(set) var usbNoData = 0                         // iPhone 在 USB 匯流排上，usbmuxd 卻看不到（有電沒資料）
    package private(set) var usbNoNetwork = 0                      // NCM 網口 60 秒沒出現

    // ── 這一次嘗試（從 iAP2 認證起算）──
    package private(set) var attemptAt: Double?
    package private(set) var availabilityAt: Double?
    package private(set) var transportAt: Double?
    package private(set) var firstStartAt: Double?
    package private(set) var attemptStarts = 0
    package private(set) var attemptWired = false        // 這次送的是有線 0x4301（USB NCM）：Wi-Fi 那幾枝不適用
    package private(set) var attemptProbesAnswered = 0   // 這次嘗試裡 iPhone 回了幾次探測（上一次的不算）
    package private(set) var controlAt: Double?
    package private(set) var sessionAt: Double?

    package let startedAt: Double
    package init(now: Double) { startedAt = now }

    // MARK: 事件

    package mutating func linkOpened() { linkOpens += 1 }
    /// 連結結束或打不開。why 是代碼或原因名（例：「code 9」「notFound」），不含位址。
    package mutating func linkEnded(_ why: String) { linkEnds[why, default: 0] += 1 }
    package mutating func authenticated(now: Double) {
        linkAuthenticated += 1
        attemptAt = now
        availabilityAt = nil; transportAt = nil; firstStartAt = nil; controlAt = nil; sessionAt = nil
        attemptStarts = 0; attemptWired = false; attemptProbesAnswered = 0
    }
    package mutating func availability(now: Double) { if availabilityAt == nil { availabilityAt = now } }
    package mutating func transportAvailable(now: Double) { if transportAt == nil { transportAt = now } }
    package mutating func wifiConfig() { wifiConfigSent += 1 }
    package mutating func startSent(now: Double, wired: Bool = false) {
        startsSent += 1; attemptStarts += 1
        attemptWired = wired
        if firstStartAt == nil { firstStartAt = now }
    }
    package mutating func controlConnected(now: Double) {
        controlConnects += 1
        if controlAt == nil { controlAt = now }
    }
    package mutating func sessionStarted(now: Double) {
        sessionsStarted += 1
        live = true
        sessionAt = now
        if let a = attemptAt {
            setupTimes.append(now - a)
            if setupTimes.count > 10 { setupTimes.removeFirst(setupTimes.count - 10) }
        }
    }
    package mutating func sessionEnded(_ why: String) {
        live = false
        sessionEnds[why, default: 0] += 1
    }
    package mutating func browseState(_ b: Browse) {
        // 被拒是最有用的訊號：之後的 waiting／failed 不蓋掉它（ready 才表示權限回來了）
        if browse == .denied, b != .ready { return }
        browse = b
    }
    package mutating func servicesSeen(_ count: Int) { ctrlServices = max(ctrlServices, count) }
    package mutating func probe(answered: Bool) {
        if answered { probesAnswered += 1; attemptProbesAnswered += 1 } else { probesFailed += 1 }
    }
    package mutating func hintShown(_ r: Reason) { hintsShown[r, default: 0] += 1 }
    package mutating func usbAttached() { usbAttaches += 1 }
    package mutating func usbOpenFailed(_ f: UsbOpenFailure) { usbOpenFailures[f.rawValue, default: 0] += 1 }
    package mutating func usbNoDataSeen() { usbNoData += 1 }
    package mutating func usbNoNetworkSeen() { usbNoNetwork += 1 }

    // MARK: 判斷

    /// 已經等夠久、仍沒直播時，最可能的原因。正常（直播中、這次嘗試已連進控制口、還沒到該判斷的時間）回 nil。
    /// consentWait：認證後等 iPhone 說「要開 CarPlay」的時間（首次要使用者解鎖點「連接」）。
    package func stalledReason(now: Double, consentWait: Double = 20) -> Reason? {
        guard !live else { return nil }
        if attemptAt != nil, controlAt != nil { return nil }   // iPhone 已連進來：之後的問題不歸這棵樹
        if firewall?.blocksReceiver == true { return .macFirewall }
        if browse == .denied { return .localNetwork }
        guard let auth = attemptAt else { return nil }
        // iPhone 還沒說「要開 CarPlay」（0x4300）、我們也還沒送過 0x4301：在等使用者在 iPhone 上點「連接」，不是 Wi-Fi 的事。
        // 真機 2026-10-25：插線建好的車，拔線後 iPhone 報了傳輸（0x4E0D）卻遲遲不報可用，原本被誤判成「關開一次 Wi-Fi」
        if availabilityAt == nil, firstStartAt == nil {
            return now - auth >= consentWait ? .carPlayConsent : nil
        }
        if attemptWired { return nil }   // 有線交接卡住不是 Wi-Fi 的事
        if !ssidKnown { return .ssidUnknown }
        if attemptProbesAnswered > 0 { return .inboundBlocked }
        return .wifiNoConnectBack
    }

    // MARK: 報告

    private static func seconds(_ t: Double?, from base: Double?) -> String {
        guard let t, let base else { return "—" }
        return String(format: "+%.1f s", t - base)
    }
    private static func yes(_ b: Bool) -> String { b ? "yes" : "no" }
    private static func counts<K>(_ d: [K: Int], _ key: (K) -> String) -> String {
        d.isEmpty ? "none" : d.map { "\(key($0.key))×\($0.value)" }.sorted().joined(separator: ", ")
    }

    /// 報告的接收器部分（英文、每行一件事）。只有次數、秒數、狀態。
    package func reportLines(now: Double) -> [String] {
        var out: [String] = []
        out.append("Receiver: up \(Int(now - startedAt)) s · mode \(mode.isEmpty ? "?" : mode) · live \(Self.yes(live))")
        out.append("Verdict: \(stalledReason(now: now)?.rawValue ?? (live ? "connected" : "none yet"))")
        var wifi = "Wi-Fi: IPv4 \(Self.yes(wifiIPv4)) · IPv6 link-local \(Self.yes(wifiLinkLocalV6))"
        if !wifiBand.isEmpty { wifi += " · \(wifiBand)" }
        if wifiChannel > 0 { wifi += " (ch \(wifiChannel))" }
        wifi += " · security \(security.isEmpty ? "?" : security) · name known \(Self.yes(ssidKnown)) · password saved \(Self.yes(passphraseSaved))"
        out.append(wifi)
        if let f = firewall {
            out.append("Firewall: \(f.enabled ? "on" : "off") · block all \(Self.yes(f.blockAll)) · HomePlay blocked \(Self.yes(f.receiverBlocked)) · stealth \(Self.yes(f.stealth))")
        } else {
            out.append("Firewall: unknown")
        }
        out.append("iPhones: paired \(pairedPhones) · forgotten in HomePlay \(ignoredPhones)")
        if let a = attemptAt {
            out.append("This attempt: authenticated \(Int(now - a)) s ago · CarPlay available \(Self.seconds(availabilityAt ?? transportAt, from: a))"
                       + " · start sent \(Self.seconds(firstStartAt, from: a)) (\(attemptStarts)×)"
                       + " · phone connected \(Self.seconds(controlAt, from: a)) · picture \(Self.seconds(sessionAt, from: a))")
        } else {
            out.append("This attempt: no iPhone authenticated since start")
        }
        out.append("Totals: links opened \(linkOpens) · authenticated \(linkAuthenticated) · link ends \(Self.counts(linkEnds) { $0 })")
        out.append("        Wi-Fi config sent \(wifiConfigSent) · start sent \(startsSent) · phone connected \(controlConnects)"
                   + " · sessions \(sessionsStarted) · session ends \(Self.counts(sessionEnds) { $0 })")
        out.append("USB: attached \(usbAttaches) · open failures \(Self.counts(usbOpenFailures) { $0 }) · on bus without data \(usbNoData) · no CarPlay network \(usbNoNetwork)")
        out.append("Network: Bonjour browse \(browse.rawValue) · phone control services seen \(ctrlServices) · probes answered \(probesAnswered), failed \(probesFailed)")
        if !setupTimes.isEmpty {
            out.append("Connect times: " + setupTimes.map { String(format: "%.1f s", $0) }.joined(separator: ", "))
        }
        out.append("Hints shown: \(Self.counts(hintsShown) { $0.rawValue })")
        return out
    }
}

/// carkit（USB 上的 iAP2）打不開的原因，從 usbmuxd／lockdown 的錯誤描述分類（Iap2Usbmuxd 的 MuxError／LdError）。
/// notTrusted：Mac 還沒被信任（沒按「信任」、按了「不信任」）；locked：iPhone 鎖著（PasswordProtected）；
/// trustExpired：配對記錄在但 lockdown 不認（信任過期／iPhone 清過信任）；notIPhone：插的是別的裝置。
package enum UsbOpenFailure: String, Sendable, CaseIterable {
    case notTrusted, locked, trustExpired, notIPhone, other

    package static func classify(_ description: String) -> UsbOpenFailure {
        let d = description
        if d.contains("PasswordProtected") || d.contains("DeviceLocked") { return .locked }
        if d.contains("ReadPairRecord") || d.contains("配对记录") || d.contains("PairingDialogResponsePending") || d.contains("UserDeniedPairing") { return .notTrusted }
        if d.contains("StartSession") || d.contains("InvalidHostID") || d.contains("信任过期") { return .trustExpired }
        if d.contains("不是 iPhone") { return .notIPhone }
        return .other
    }
}
