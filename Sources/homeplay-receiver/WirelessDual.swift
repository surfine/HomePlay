import AppKit
import Foundation
import QuartzCore
import Network
import CoreWLAN
import IOBluetooth
import IOKit
import IAP2
import Session
import H264
import Wire

// 雙模（auto）路徑：插線走有線、拔線回落藍牙。行文本自 Wireless.swift 拆出。
extension Wireless {
    // MARK: 双模（auto）：插线走有线、拔线回落蓝牙，运行中实时切换——妙控配件式的体验。
    // 首插自动配对：有线会话里手机报 0x4E0E（带它的蓝牙地址），没配对就发起配对（手机上点一下），
    // 之后这台手机记住，拔线即无线。
    static func runDual(_ o: Options, server: WSServer) -> Never {
        let identity: Iap2MfiIdentity
        do { identity = try Iap2MfiIdentity(directory: o.identityDir) }
        catch { note("身份加载失败：\(error)"); exit(2) }
        note("身份自检通过（证书 \(identity.certificate.count) 字节，内容不打印）")

        // 不自動讀系統鑰匙圈：Wi-Fi 密碼在「系統」鑰匙圈，讀一次就彈管理員授權，外部用戶無法接受。
        // iPhone 與 Mac 同網時不需要密碼；特殊情況用 HOMEPLAY_WIFI_PASSPHRASE／--passphrase 顯式提供。
        var passphrase = o.passphrase
        var ssid = o.ssid
        // 只有有线也應該能用：沒有 Wi-Fi／讀不到信道時退到有線模式，不要直接退出
        guard let ip = NetInfo.ipv4(o.iface) else {
            note("网卡 \(o.iface) 没有 IPv4 —— 没有可用的 Wi-Fi，改用有线模式")
            runWired(o, server: server)
        }
        let channel = o.channel ?? UInt8(clamping: CWWiFiClient.shared().interface(withName: o.iface)?.wlanChannel()?.channelNumber ?? 0)
        if channel == 0 {
            note("读不到 Wi-Fi 信道 —— 无线交接不可用，改用有线模式")
            runWired(o, server: server)
        }
        note("接收端 \(ip)（\(o.iface)），信道 \(channel)，控制口 \(o.controlPort)")

        let store = PairingStore()
        // 0x4301 的两个身份必须和 Bonjour TXT 同源：字段 3=deviceid、字段 4=pi（不是 pk）。
        note("AirPlay 身份：deviceid=\(store.identity.deviceId) pi=\(store.identity.pairingId)（0x4301 字段 3/4）")
        let (s, h264) = makeSession(o: o, server: server, store: store, identity: identity) { $0.phoneBluetoothAddress = o.phoneAddress }
        let alternateHost = NetInfo.linkLocalIPv6(o.iface)
        if alternateHost != nil { note("IPv6 备用地址就绪（链路本地）") }
        /// 0x4301 用的安全类型：纯 WPA3 → 4，WPA2/混合 → 2（0x5703 由消息层钳到 ≤2）
        var securityProfile = o.security
        /// 发送时现读当前 IPv4：DHCP 续租/换网/睡眠唤醒后地址可能变，0x4301 不能发旧地址。
        func currentIP() -> String? { NetInfo.ipv4(o.iface) }
        func currentChannel() -> UInt8 {
            if let c = o.channel, c != 0 { return c }
            return UInt8(clamping: CWWiFiClient.shared().interface(withName: o.iface)?.wlanChannel()?.channelNumber ?? Int(channel))
        }
        func wifiConfigFrame(_ security: Iap2Csm.WiFiSecurity? = nil) -> Iap2Csm.Frame {
            Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase, security: security ?? securityProfile, channel: currentChannel())
        }
        func startMessage(_ addresses: [String], security: Iap2Csm.WiFiSecurity? = nil) -> Iap2Csm.Frame {
            // 字段 3 必须是 TXT deviceid、字段 4 必须是 TXT pi（iAP2 里它叫 public_key，但 iOS
            // 按「配对标识」解析并与 Bonjour pi 比对；发 pk 会让手机认不出这是它被告知的那台接收端）。
            Iap2Csm.carPlayStartSessionWireless(
                ssid: ssid, passphrase: passphrase, channel: currentChannel(), ipAddresses: addresses, security: security ?? securityProfile,
                port: UInt32(o.controlPort), deviceIdentifier: store.identity.deviceId, publicKey: store.identity.pairingId,
                sourceVersion: "950.7.1")
        }

        // ── 连线状态机：所有「连谁、怎么连、失败怎么办、要不要重启」都在 ConnectionMachine 里决定 ──
        // 这里只把硬件事件喂进去（一律在主线程）、执行它吐出来的效果。设计稿 docs/design-drafts/連線狀態機.md。
        var machine = ConnectionMachine()
        // 連不上時的現場（只有次數、秒數、狀態）：卡住時判斷原因、桌寵「拷貝診斷報告」用
        var diag = ConnectDiagnostics(now: CACurrentMediaTime())
        diag.mode = "dual"
        let receiverPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var inbox: [ConnectionEvent] = []
        var draining = false
        var timers: [TimerID: DispatchWorkItem] = [:]
        enum LinkHandle { case bluetooth(Iap2BluetoothAccessory), usb(Iap2UsbAccessory) }
        var links: [Int: LinkHandle] = [:]
        var lastBluetooth: (address: String, acc: Iap2BluetoothAccessory)?   // 断基带用（连结结束后对象还在）
        var pendingIncoming: [String: (device: IOBluetoothDevice, channel: IOBluetoothRFCOMMChannel)] = [:]
        var activeUSB: Usbmuxd.Device?
        var sdpBusy = 0   // 在跑的 SDP 查询数：查询当中不开 RFCOMM
        var afterSDP: [() -> Void] = []
        var startHoldUntil = Date.distantPast   // 收掉会话后 0.3 秒再送 0x4301（RTSP 先关干净）
        var tunnelLink: IapTunnelLink?
        let processStartedAt = Date()
        var execute: ((ConnectionEffect) -> Void)?
        // 下面才定义、但上面的回调就要用的（闭包不能先捕获后宣告的局部变量）
        var sessionStartedHook: (() -> Void)?
        var publishPhonesHook: ((Bool) -> Void)?

        func environment() -> ConnectionEnvironment {
            let paired = Iap2BluetoothAccessory.pairedPhones().map { PairingRules.normalize($0.address) }
            var nearby = Set<String>()
            // 「在旁边」＝基带连着，而且有它的 iAP2 服务记录：同一个 Apple ID 的 iPhone 只靠 iCloud 的 BLE 连着时也算 isConnected，
            // 但根本没有传统藍牙配对、连不上（真机 2026-10-24 09:49）
            for a in paired where Wireless.isBasebandConnected(a) {
                if case .success = Iap2BluetoothAccessory.locate(address: a) { nearby.insert(a) }
            }
            let ncm = activeUSB.map { d in UsbNet.ncmInterfaces(udid: d.serial).first.flatMap { UsbNet.linkLocalV6($0) } != nil } ?? false
            return ConnectionEnvironment(now: CACurrentMediaTime(), processAge: Date().timeIntervalSince(processStartedAt),
                                         paired: paired, nearby: nearby,
                                         wifiReady: currentIP() != nil && !ssid.isEmpty, ncmReady: ncm,
                                         tunnelCarriesIap2: tunnelLink != nil)
        }
        /// 只在主线程调用。效果执行当中又产生的事件排队，处理完这一个再处理下一个（不重入）。
        var restarting = false   // 已决定重启行程：之后的事件一律不处理（不再开新连结）
        /// 狀態機的事件順便記進診斷（只在主執行緒）。帶代號的事件只算目前這條連結的（舊連結遲到的不改這次嘗試）
        func observe(_ e: ConnectionEvent) {
            let now = CACurrentMediaTime()
            let current = machine.link.gen
            switch e {
            case .linkAuthenticated(let g) where g == current: diag.authenticated(now: now)
            case .linkFinished(_, let code): diag.linkEnded("code \(code)")
            case .linkUnavailable(_, let why): diag.linkEnded("\(why)")
            case .availability(let g, _, _) where g == current: diag.availability(now: now)
            case .transportAvailable(let g) where g == current: diag.transportAvailable(now: now)
            case .controlConnected: diag.controlConnected(now: now)
            case .sessionActive: diag.sessionStarted(now: now)
            case .sessionEnded(let why): diag.sessionEnded("\(why)")
            default: break
            }
        }
        func feed(_ event: ConnectionEvent) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard !restarting else { return }
            observe(event)
            inbox.append(event)
            guard !draining else { return }
            draining = true
            while !inbox.isEmpty {
                let e = inbox.removeFirst()
                for effect in machine.handle(e, environment()) { execute?(effect) }
            }
            draining = false
        }
        func core(_ gen: Int) -> Iap2AccessoryCore? {
            switch links[gen] {
            case .bluetooth(let acc): return acc.core
            case .usb(let acc): return acc.core
            case nil: return nil
            }
        }
        func refreshDiag() {
            diag.ssidKnown = !ssid.isEmpty
            diag.passphraseSaved = !passphrase.isEmpty
            diag.wifiIPv4 = currentIP() != nil
            diag.wifiLinkLocalV6 = NetInfo.linkLocalIPv6(o.iface) != nil
            let ch = CWWiFiClient.shared().interface(withName: o.iface)?.wlanChannel()
            diag.wifiChannel = ch?.channelNumber ?? 0
            diag.wifiBand = Wireless.bandLabel(ch?.channelBand)
            diag.security = Wireless.securityLabelEN(securityProfile)
            diag.pairedPhones = Iap2BluetoothAccessory.pairedPhones().count
            diag.ignoredPhones = Iap2BluetoothAccessory.ignoredAddresses.count
        }
        /// 先查一次防火牆（子行程，幾十毫秒，不在主執行緒跑），再在主執行緒做事
        func withFirewall(_ then: @escaping () -> Void) {
            DispatchQueue.global(qos: .userInitiated).async {
                let fw = Wireless.firewallState(executable: receiverPath)
                DispatchQueue.main.async { diag.firewall = fw; refreshDiag(); then() }
            }
        }
        var wifiShareAskedAt: Double?   // 何時請 iPhone 分享 Wi-Fi（等它回的這段時間不顯示錯誤）
        /// 卡住了：判斷原因，給桌寵一張照做就能過的卡（wifiHelp＋reason）。
        /// fallback＝狀態機的交接逾時（一定要給一張）；其他觸發（Wi-Fi 名稱未知、等 iPhone 同意）判不出原因就不打擾。
        func showConnectHint(_ trigger: String, fallback: ConnectDiagnostics.Reason? = nil) {
            withFirewall {
                // 剛請 iPhone 分享 Wi-Fi、還沒拿到：這不是錯，只是在等使用者在 iPhone 上按「分享」（90 秒內不給排障卡）
                if !live, let t = wifiShareAskedAt, CACurrentMediaTime() - t < 90, ssid.isEmpty || passphrase.isEmpty {
                    if let help = Wireless.wifiHelpPayload(ssid: ssid, passphraseMissing: passphrase.isEmpty, reason: "wifiShare") {
                        server.broadcastText(help)
                    }
                    return
                }
                guard !live, let reason = diag.stalledReason(now: CACurrentMediaTime()) ?? (diag.attemptWired ? nil : fallback) else { return }
                diag.hintShown(reason)
                note("连不上（\(trigger)）：判断为 \(reason.rawValue)；iPhone 要连「\(ssid.isEmpty ? "未知 Wi-Fi" : ssid)」")
                if let help = Wireless.wifiHelpPayload(ssid: ssid, passphraseMissing: passphrase.isEmpty, reason: reason.rawValue) {
                    server.broadcastText(help)
                }
            }
        }
        var ssidHintArmed = false

        s.onLog = { note($0) }
        s.onProbeEvent = { e in
            DispatchQueue.main.async {
                switch e {
                case .browse(let state): diag.browseState(ConnectDiagnostics.Browse(rawValue: state) ?? .failed)
                case .services(let n): diag.servicesSeen(n)
                case .probe(let answered): diag.probe(answered: answered)
                }
            }
        }
        s.onActive = {
            live = true
            Wireless.liveSinceHook?()
            // 學圓角的連線：手機 4 秒內沒送遮罩就當這版不送，回到平常模式（不讓使用者卡在學習連線）
            if s.config.info.main.cornerMasks == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    guard live, !Wireless.maskSeen, s.config.info.main.cornerMasks == true else { return }
                    note(PetDisplay.markNoMask())
                    Wireless.cornerChanged?("等不到圓角遮罩")
                }
            }
            Wireless.setPairingHint(nil)
            Wireless.setCableHint(nil)
            Wireless.setTrustHint(nil)
            DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"started"}"#) }
            note("会话开始，等画面")
            DispatchQueue.main.async {
                feed(.sessionActive)
                sessionStartedHook?()
                // 换手机／桌宠重连时第 1 帧的关键帧常被错过，而桌宠的健康检查不一定会去要：
                // 会话建立 1.5 秒后主动再要一次（iOS 26 真机：forceKeyFrame 立刻回一个关键帧）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard live, server.hasClients else { return }
                    note("会话建立 1.5 秒：主动要一次关键帧")
                    s.requestKeyframe()
                }
            }
        }
        s.onEnded = { why in
            live = false
            Wireless.liveEndedHook?()
            note("会话结束：\(why)")
            let reason: SessionEndReason
            if why == "手机结束会话" { reason = .phoneTeardown }
            else if why.contains("15 秒没有控制消息") { reason = .silence }
            else if why == "控制连接关闭" { reason = .controlClosed }
            else { reason = .ours }
            DispatchQueue.main.async {
                server.broadcastText(#"{"type":"session","state":"ended"}"#)
                feed(.sessionEnded(reason))
            }
        }
        /// 照目前的圓角記憶與策略重算宣告；跟現在的不同就換掉，有手機連著就由狀態機立刻重開
        func applyCorner(_ why: String) {
            var d = s.config.info.main
            PetDisplay.apply(&d)
            guard PetDisplay.key(d) != PetDisplay.key(s.config.info.main) else { return }
            s.updateMainDisplay(d)
            note("圓角宣告改為 \(PetDisplay.key(d))（\(why)）")
            feed(.displayChanged)
        }
        Wireless.cornerChanged = { why in
            if Thread.isMainThread { applyCorner(why) } else { DispatchQueue.main.async { applyCorner(why) } }
        }
        Wireless.reopenNow = { _ in DispatchQueue.main.async { feed(.displayChanged) } }
        // 設定 › CarPlay › 圓角：桌寵寫 carplay-display.json；每秒看一次修改時間，改了就立刻套用
        let displayFile = HomePlayState.directory.appendingPathComponent("carplay-display.json")
        var displayStamp = (try? displayFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let now = (try? displayFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard now != displayStamp else { return }
            displayStamp = now
            applyCorner("圓角策略改成 \(PetDisplay.style.rawValue)")
        }
        s.onControlConnected = { host in
            if Self.isSelfAddress(host, iface: o.iface) {
                note("控制连接来自本机（\(host)），忽略，不影响 0x4301 重试")
                return
            }
            note("手机连入控制口 \(host)")
            DispatchQueue.main.async {
                // 对端是手机 NCM 网口的链路本地地址 → USB 有线；否则是 Wi-Fi（Wi-Fi 也可能给 fe80，所以看网口名）
                let ncm = activeUSB.map { UsbNet.ncmInterfaces(udid: $0.serial) } ?? []
                feed(.controlConnected(CarPlayTransportPolicy.transport(forPeer: host, ncmInterfaces: ncm)))
            }
        }
        do { try s.start() } catch {
            if isAddressInUse(error) {
                // 登录瞬间桌宠与 launchd 可能同时拉起接收器：端口被占时优雅退出，
                // 避免 KeepAlive 每 10 秒重启一次（2026-10-20 重启实测的 spawm 循环）。
                note("控制口 \(o.controlPort) 已被另一个接收器实例占用：本实例退出（原地重启出来的交给 launchd 再拉）")
                exit(Wireless.portInUseExitCode)
            }
            note("控制口 \(o.controlPort) 起不来：\(error)"); exit(1)
        }
        session = s; sink = h264

        // 桌宠是在前台看配对引导，还是只在后台挂接等画面。后台不弹系统设置。
        var uiEngaged = false
        var cableFirstClientConnected: (() -> Void)?
        var pairNewHandler: (() -> Void)?
        var forgetPhoneHandler: ((String) -> Void)?
        var restorePhonesHandler: (() -> Void)?
        server.onConnect = { conn in
            // 桌宠中途连上/重连：旧关键帧早过了，主动向手机要一个，别等解码端自己发现解不出来
            if live { note("桌宠连上且会话进行中 → 主动要关键帧"); s.requestKeyframe() }
            server.sendText(Wire.helloJSON(name: "CarPlay（双模）", width: o.width, height: o.height), to: conn)
            if let m = Wireless.lastCornerMask { server.sendText(m, to: conn) }
            if let info = Wireless.wifiInfoPayload(ssid: ssid) { server.sendText(info, to: conn) }
            if let config = h264.lastConfig { server.sendBinary(config, to: conn) }
            if let json = Wireless.cachedNowPlaying() { server.sendText(json, to: conn) }
            if let art = Wireless.cachedArtwork() { server.sendText(art, to: conn) }
            for text in Wireless.cachedTelephony() { server.sendText(text, to: conn) }
            // 配对引导可能早于桌宠连上：新连进来的客户端立刻补一张卡片，不用等下一轮广播。
            if let hint = Wireless.cachedHandoffHint() { server.sendText(hint, to: conn) }
            if let hint = Wireless.cachedCableHint() { server.sendText(hint, to: conn) }
            if let hint = Wireless.cachedTrustHint() { server.sendText(hint, to: conn) }
            if let hint = Wireless.cachedPairingHint() { server.sendText(hint, to: conn) }
            if let phones = Wireless.cachedPhones() { server.sendText(phones, to: conn) }
            s.requestKeyframe()
        }
        /// 用户改了 Wi-Fi 设置：立刻把 0x5703 再推给当前手机，不用重插或重配。
        func pushWiFiConfiguration() {
            guard !live, let g = machine.link.gen, let c = core(g) else { return }
            c.send(wifiConfigFrame())
            note("Wi-Fi 配置已重推给手机")
        }
        server.onText = { text in
            func json() -> [String: Any]? {
                text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
            if text.contains("\"type\":\"diagnostics\"") {
                // 桌寵「拷貝診斷報告」：只有次數、秒數、狀態（見 ConnectDiagnostics.reportLines）
                DispatchQueue.main.async {
                    withFirewall {
                        let report = diag.reportLines(now: CACurrentMediaTime()).joined(separator: "\n")
                        if let data = try? JSONSerialization.data(withJSONObject: ["type": "diagnostics", "report": report]),
                           let t = String(data: data, encoding: .utf8) { server.broadcastText(t) }
                    }
                }
                return
            }
            if text.contains("\"type\":\"foreground\"") {
                DispatchQueue.main.async {
                    uiEngaged = true
                    cableFirstClientConnected?()
                }
                return
            }
            if text.contains("\"type\":\"background\"") {
                DispatchQueue.main.async { uiEngaged = false }
                return
            }
            if text.contains("\"type\":\"stop\"") {
                note("收到斷開指令，結束 CarPlay 會話")
                Wireless.shutdown()
                DispatchQueue.main.asyncAfter(deadline: .now() + Wireless.exitGrace) { exit(0) }
                return
            }
            if text.contains("\"type\":\"discoverable\"") {
                // 诊断：在本进程（launchd 拉起、带 App 蓝牙权限）里调私有可发现性 API。
                // 结果以广播返回；真实状态请用 system_profiler 复核。
                if let value = json()?["value"] as? Bool {
                    // 这个回调跑在 WebSocket 线程上：确认可发现性要等几百毫秒，不能在这里等。
                    BluetoothDiscoverable.setAsync(value) { after in
                        note("可发现性命令：value=\(value) getter=\(after.map(String.init) ?? "不可用")")
                        let getter = after.map(String.init) ?? "null"
                        server.broadcastText("{\"type\":\"discoverable\",\"value\":\(value),\"getter\":\(getter)}")
                    }
                }
                return
            }
            if text.contains("\"type\":\"usePhone\"") {
                if let address = json()?["address"] as? String, !address.isEmpty {
                    DispatchQueue.main.async {
                        guard Iap2BluetoothAccessory.pairedPhones().contains(where: { PairingRules.normalize($0.address) == PairingRules.normalize(address) }) else {
                            note("切换手机：\(address) 不在已配对列表")
                            publishPhonesHook?(true)
                            return
                        }
                        note("用户选了 \(address)")
                        feed(.userSelect(address))
                    }
                }
                return
            }
            if text.contains("\"type\":\"setWiFi\"") {
                if let obj = json() {
                    DispatchQueue.main.async {
                        let before = (ssid, passphrase)
                        if let value = obj["ssid"] as? String, !value.isEmpty { ssid = value }
                        if let value = obj["passphrase"] as? String { passphrase = value }   // 桌寵自動補名稱時不帶密碼：保留原本的
                        guard (ssid, passphrase) != before else { return }   // 每次連上都會補一次名稱：沒變就什麼都不做
                        func apply(_ sec: Iap2Csm.WiFiSecurity) {
                            securityProfile = sec
                            note("Wi-Fi 设置已更新（SSID/密码不打印；0x4301 security=\(Wireless.securityLabel(securityProfile))）")
                            pushWiFiConfiguration()
                            feed(.wifiChanged)   // 交接中：马上用新的 Wi-Fi 名称再叫一次手机，不等下一轮补发
                        }
                        // 安全類型探測要掃描＋system_profiler（4–34 秒）：有快取就用，沒有到背景探，不卡主執行緒
                        if o.securityExplicit { apply(o.security) }
                        else if let cached = cachedWiFiSecurity(ssid: ssid) { apply(cached) }
                        else {
                            let name = ssid
                            DispatchQueue.global(qos: .userInitiated).async {
                                let sec = resolveWiFiSecurity(ssid: name, iface: o.iface, explicit: false, current: o.security)
                                saveWiFiSecurity(ssid: name, value: sec)
                                DispatchQueue.main.async { if ssid == name { apply(sec) } }
                            }
                        }
                    }
                }
                return
            }
            if text.contains("\"type\":\"setPassphrase\"") {
                if let value = json()?["value"] as? String {
                    DispatchQueue.main.async {
                        passphrase = value
                        note("Wi-Fi 密码已更新（不打印）")
                        pushWiFiConfiguration()
                        feed(.wifiChanged)
                    }
                }
                return
            }
            if text.contains("\"type\":\"pairNewPhone\"") {
                DispatchQueue.main.async { pairNewHandler?() }
                return
            }
            if text.contains("\"type\":\"forgetPhone\"") {
                if let address = json()?["address"] as? String, !address.isEmpty {
                    DispatchQueue.main.async { forgetPhoneHandler?(address) }
                }
                return
            }
            if text.contains("\"type\":\"restorePhones\"") {
                DispatchQueue.main.async { restorePhonesHandler?() }
                return
            }
            if text.contains("\"keyframe\"") { note("桌宠要关键帧 → forceKeyFrame"); s.requestKeyframe() }
            if let t = Touch.parse(text) { s.sendTouch(x: t.x, y: t.y, down: t.down) }
            if let b = mediaButton(text) { s.sendMedia(b) }
            phoneControl(text, session: s)
            carVideoFromPet(text, session: s)
            applySeek(text)
        }

        // ── 自愈重启（状态机提出，这里节流）──
        /// 手机把 iAP2 通道一直拒绝时，真机验证只有「接收器干净重启」能恢复（2026-10-19 两次复现）。
        /// 退出让 launchd 重新拉起（LaunchAgent 配了 KeepAlive.SuccessfulExit=false；用户主动停止是 exit(0) 不受影响）。
        /// 10 分钟一次；不论中间会话成功与否，30 分钟内最多 3 次（计数存盘，重启也不归零）。
        /// 2026-10-23 19:16 压力测试：会话成功会清掉节流戳，结果 12 分钟内自愈重启 12 次，把 SE 的蓝牙折腾到僵住。
        func selfHealAllowed() -> Bool {
            guard getppid() == 1 else {
                note("（非 launchd 拉起的实例不做自愈，继续退避重试）")
                return false
            }
            let dir = HomePlayState.directory
            let url = dir.appendingPathComponent("selfheal.stamp")
            let now = Date()
            let last = (try? String(contentsOf: url, encoding: .utf8))
                .flatMap { Double($0) }
                .map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            guard now.timeIntervalSince(last) > 600 else {
                note("自愈 10 分钟内已执行过，继续退避重试")
                return false
            }
            let logURL = dir.appendingPathComponent("selfheal-history.json")
            var history = ((try? Data(contentsOf: logURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Double] } ?? [])
                .filter { now.timeIntervalSince1970 - $0 < 1800 }
            guard history.count < 3 else {
                note("自愈 30 分钟内已 \(history.count) 次：不再重启，交给退避重试")
                return false
            }
            history.append(now.timeIntervalSince1970)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let d = try? JSONSerialization.data(withJSONObject: history) { try? d.write(to: logURL, options: .atomic) }
            try? String(now.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
            return true
        }

        // ── 首次配对：先等插线（20 秒），再走系统蓝牙配对引导 ──
        var lastPairNotify = Date.distantPast
        var pairingGuide = false
        var pairingForNewDevice = false   // 「配对新 iPhone」：旧手机连上不算完成，继续等新设备
        var pairingGuideStarted: CFTimeInterval = 0
        var pairingBaseline = Set<String>()
        var pairingPoll: DispatchWorkItem?
        var lastPaneOpen = Date.distantPast
        var lastDiscoverableAssert = Date.distantPast
        var discoverableHeld = false   // 配对引导期间由我们打开的可发现性；结束时恢复关闭
        let hostName = Iap2BluetoothAccessory.localBluetoothName
        var beacon: BluetoothBeacon?

        // 插线时手机还没配对：先暂缓开 CarPlay 画面，让用户在 iPhone 的蓝牙设置里点这台 Mac（真机：手机端配对几秒就成，
        // Mac 主动呼叫多半叫不到）。配好或 60 秒到了才把扣下的 0x4300 交给状态机开会话。
        var noServiceStreak: [String: Int] = [:]   // 每支手機連續查不到 iAP2 服務的次數
        var pairFirstUntil: Date?
        var heldAvailability: ConnectionEvent?
        var pairFirstTimer: DispatchWorkItem?
        func releaseHeldAvailability(_ why: String) {
            guard pairFirstUntil != nil else { return }
            pairFirstUntil = nil
            pairFirstTimer?.cancel(); pairFirstTimer = nil
            if let e = heldAvailability {
                heldAvailability = nil
                note("插线配对：\(why) → 开会话")
                feed(e)
            }
        }
        func notifyNeedPairing() {
            guard Date().timeIntervalSince(lastPairNotify) > 30 else { return }
            lastPairNotify = Date()
            if let text = Wireless.pairingHintPayload(host: hostName, stale: !Iap2BluetoothAccessory.ignoredAddresses.isEmpty,
                                                      cable: pairFirstUntil.map { $0 > Date() } ?? false) {
                Wireless.setPairingHint(text)
                server.broadcastText(text)
            }
        }
        func stopPairingGuide() {
            pairingPoll?.cancel(); pairingPoll = nil
            pairingGuide = false
            pairingForNewDevice = false
            // 恢复系统默认：配对引导结束就不要再可被发现（安全默认）。
            if discoverableHeld {
                discoverableHeld = false
                BluetoothDiscoverable.setAsync(false)
            }
        }
        /// 新配对出现的手机 → 停引导、刷新 SDP、交给状态机连它。
        Wireless.onShutdown = { stopPairingGuide() }   // 任何退出路径都停引导、恢复可发现性
        func finishPairingGuide(_ phone: (address: String, name: String)) {
            stopPairingGuide()
            cancelCableFirst("蓝牙配对完成")
            note("蓝牙配对完成：\(phone.name)（\(phone.address)）→ 刷新 SDP 后连接")
            Wireless.setPairingHint(nil)
            server.broadcastText(#"{"type":"pairingDone"}"#)
            releaseHeldAvailability("蓝牙配对完成")
            startBeaconIfNeeded()
            publishPhones(force: true)
            sdpBusy += 1
            SDPRefresh.refresh(address: phone.address) {
                sdpBusy -= 1
                feed(.userSelect(phone.address))
                if sdpBusy == 0 { let waiting = afterSDP; afterSDP = []; waiting.forEach { $0() } }
            }
        }
        /// 只在桌宠真的在前台看引导时才打开可发现性/蓝牙设置：后台挂接或 launchd
        /// 接收器没有 UI 时不要自己弹系统设置。桌宠进入前台后下一轮 2 秒轮询会补开。
        func ensureDiscoverableForPairing() {
            guard uiEngaged, server.hasClients else { return }
            if BluetoothDiscoverable.available {
                if !discoverableHeld {
                    discoverableHeld = true
                    lastDiscoverableAssert = Date()
                    BluetoothDiscoverable.setAsync(true)
                    note("已把 Mac 设为可被发现（配对引导期间，结束后恢复）")
                } else if Date().timeIntervalSince(lastDiscoverableAssert) > 60 {
                    lastDiscoverableAssert = Date()
                    BluetoothDiscoverable.setAsync(true)
                }
            } else if Date().timeIntervalSince(lastPaneOpen) > 60 {
                lastPaneOpen = Date()
                BluetoothSettingsPane.open()
            }
        }
        func schedulePairingPoll() {
            pairingPoll?.cancel()
            let item = DispatchWorkItem {
                guard pairingGuide else { return }
                ensureDiscoverableForPairing()
                let fresh = PairingRules.newlyPaired(Iap2BluetoothAccessory.pairedPhones(), baseline: pairingBaseline)
                if let phone = fresh.first {
                    finishPairingGuide(phone)
                    return
                }
                // 引導不設時限：使用者慢慢來也沒關係（真機 2026-10-25：第 3 分 38 秒才配，引導已經收了）。
                // 只有畫面已經在播（換手機的情況）才在 3 分鐘後收掉
                if live, CACurrentMediaTime() - pairingGuideStarted > 180 {
                    stopPairingGuide()
                    note("蓝牙配对引导结束（3 分钟没等到新设备）；手机清单每 15 秒自动重查")
                    return
                }
                schedulePairingPoll()
            }
            pairingPoll = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
        }
        func startPairingGuide(_ reason: String, forNewDevice: Bool = false) {
            cancelCableFirst("改走蓝牙配对")
            if pairingGuide {
                pairingForNewDevice = pairingForNewDevice || forNewDevice
                notifyNeedPairing()
                ensureDiscoverableForPairing()
                return
            }
            pairingGuide = true
            pairingForNewDevice = forNewDevice
            pairingGuideStarted = CACurrentMediaTime()
            pairingBaseline = Set(Iap2BluetoothAccessory.pairedDevices().map { PairingRules.normalize($0.address) })
            lastPairNotify = Date.distantPast
            Wireless.beacon?.retryNow()   // 蓝牙可能是刚在设置里打开的：立刻补车机类和 SDP
            note("\(reason) → 首次配对：在 iPhone 的蓝牙列表里点「\(hostName)」，两边确认配对")
            notifyNeedPairing()
            ensureDiscoverableForPairing()
            schedulePairingPoll()
        }
        // 首次配对先给 20 秒插线窗口：有线会话能拿到手机蓝牙地址并自动发起配对，
        // 用户不用打开 iPhone 设置。没插线再自动走原来的蓝牙引导。
        var cableFirst = false
        var cableFirstItem: DispatchWorkItem?
        func cancelCableFirst(_ reason: String? = nil) {
            cableFirstItem?.cancel(); cableFirstItem = nil
            cableFirstClientConnected = nil
            guard cableFirst else { return }
            cableFirst = false
            Wireless.setCableHint(nil)
            if let reason { note("首次配对：不再等插线（\(reason)）") }
        }
        func beginCableFirst(_ reason: String) {
            guard !pairingGuide, !cableFirst else { return }
            cableFirst = true
            let text = Wireless.needCablePayload()
            Wireless.setCableHint(text)
            if uiEngaged, server.hasClients, let text { server.broadcastText(text) }
            note("\(reason) → 首次配对先等数据线（20 秒）；插上会自动配对，不用进设置")
            func armCableFirstTimer() {
                guard cableFirst, !pairingGuide, cableFirstItem == nil else { return }
                guard uiEngaged, server.hasClients else {
                    note("桌宠还没进入配对引导：插线窗口等它进入后再开始计时")
                    return
                }
                let item = DispatchWorkItem {
                    guard cableFirst, !pairingGuide else { return }
                    cableFirstItem = nil
                    guard uiEngaged, server.hasClients else {
                        note("20 秒到了但桌宠已离开：保留插线窗口，等它回来再计时")
                        return
                    }
                    cableFirst = false
                    Wireless.setCableHint(nil)
                    note("20 秒内没有插线：改走蓝牙配对（打开蓝牙设置）")
                    startPairingGuide("20 秒内没有插线")
                }
                cableFirstItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
            }
            cableFirstClientConnected = { armCableFirstTimer() }
            armCableFirstTimer()
        }
        /// 系统配对清单刚开机可能暂时读不到：认识的手机先重查几次，不急着当成首次配对。
        var notPairedRechecks = 0
        func needPairing() {
            if Iap2BluetoothAccessory.pairedPhones().isEmpty, let known = o.phoneAddress, Wireless.isKnownPhone(known), notPairedRechecks < 5 {
                notPairedRechecks += 1
                note("系统配对清单暂时读不到 \(known)（刚启动？）：3 秒后重查（第 \(notPairedRechecks) 次）")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feed(.phonesChanged) }
                return
            }
            beginCableFirst("已配对的设备里没有 iPhone")
        }

        /// 把已配对手机列表/当前选择发给桌宠；只在内容变化时广播，桌宠菜单打开时直接拿。
        /// 「目前这台」照真正在直播的那台；没在直播才用状态机的目标。
        func publishPhones(force: Bool = false) {
            guard let text = Wireless.phonesPayload(current: machine.liveOwner ?? machine.target?.address) else { return }
            guard force || Wireless.cachedPhones() != text else { return }
            Wireless.setPhones(text)
            server.broadcastText(text)
        }
        Wireless.phonesChanged = { publishPhones(force: true) }
        publishPhonesHook = { publishPhones(force: $0) }
        func refreshPhoneListLoop() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                publishPhones()
                feed(.phonesChanged)
                refreshPhoneListLoop()
            }
        }
        /// 「配对新 iPhone…」：即使已经有一台在用，也重新进入配对引导；新增的手机配对后自动切过去。
        pairNewHandler = {
            lastPairNotify = Date.distantPast
            if pairingGuide {
                pairingForNewDevice = true
                lastPaneOpen = Date.distantPast
                BluetoothSettingsPane.open()
                lastPaneOpen = Date()
                notifyNeedPairing()
                return
            }
            startPairingGuide("用户要配对新的 iPhone", forNewDevice: true)
        }
        forgetPhoneHandler = { raw in
            let address = PairingRules.normalize(raw)
            let dashed = address.replacingOccurrences(of: ":", with: "-").lowercased()
            let name = IOBluetoothDevice(addressString: dashed)?.name
            var ignored = Iap2BluetoothAccessory.ignoredAddresses
            ignored.insert(address)
            Iap2BluetoothAccessory.ignoredAddresses = ignored
            _ = Iap2BluetoothAccessory.unpair(address: address)
            note("已忘记 iPhone \(address)；系统配对若仍在，可在 iPhone 蓝牙设置里忘记")
            // 删配对是异步的：1.5 秒后看系统清单（不经过忽略名单）里还有没有它，告诉桌宠还要用户做哪些步骤
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let still = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
                    .contains { ($0.addressString ?? "").lowercased() == dashed }
                note(still ? "Mac 的系统藍牙配对没删掉（同一 Apple ID 的 iPhone 或系统拒绝）：请用户在系统设置里忘记" : "Mac 的系统藍牙配对已删掉")
                if let text = Wireless.phoneForgottenPayload(address: address, name: name, macRemoved: !still) { server.broadcastText(text) }
            }
            feed(.userForget(address))
            publishPhones(force: true)
            if Iap2BluetoothAccessory.pairedPhones().isEmpty {
                startPairingGuide("已忘记当前 iPhone", forNewDevice: false)
            }
        }
        restorePhonesHandler = {
            Iap2BluetoothAccessory.ignoredAddresses = []
            publishPhones(force: true)
            note("已恢复所有被忘记的 iPhone")
            feed(.phonesChanged)
        }
        server.start()
        refreshPhoneListLoop()

        // ── Wi-Fi 資訊分享：Wi-Fi 名稱或密碼未知時，直接向 iPhone 要它現在連的網路（iPhone 問一次「分享 Wi-Fi？」）。
        // 不用定位權限、不用手打名稱和密碼；拿到就記在本機（0600）、立刻用新設定再叫一次手機。
        var wifiInfoAsked = Set<Int>()   // 每條連結只問一次
        func askPhoneForWiFi(_ core: Iap2AccessoryCore, gen: Int) {
            guard ssid.isEmpty || passphrase.isEmpty, !wifiInfoAsked.contains(gen) else { return }
            wifiInfoAsked.insert(gen)
            wifiShareAskedAt = CACurrentMediaTime()
            core.send(Iap2Csm.requestWiFiInformationFrame())
            note("向 iPhone 要它目前的 Wi-Fi（iPhone 會問一次「分享 Wi-Fi？」）")
        }
        func adoptPhoneWiFi(_ frame: Iap2Csm.Frame) {
            // 只記結構（參數 id、長度、是否可印字），不記內容
            let shape = frame.parameters.map { p -> String in
                let printable = String(bytes: p.payload.prefix { $0 != 0 }, encoding: .utf8).map { t in !t.isEmpty && t.unicodeScalars.allSatisfy { $0.value >= 0x20 } } ?? false
                return "\(p.id):\(p.payload.count)B\(printable ? "/文字" : "")"
            }.joined(separator: " ")
            note("iPhone 回 Wi-Fi 資訊（0x5701）參數：\(shape)")
            let r = Iap2Csm.parseWiFiInformation(frame)
            // 名稱必須是正常可印的文字：解析錯了（例如欄位對錯）寧可不用，絕不把亂碼網路推給手機（會讓 iPhone 的 Wi-Fi 一斷一連）
            guard r.status == 0, let name = r.ssid, !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else {
                note("iPhone 沒分享 Wi-Fi（狀態 \(r.status)：1＝使用者拒絕、2＝手機拿不到網路資訊）")
                return
            }
            DispatchQueue.main.async {
                let before = (ssid, passphrase)
                ssid = name
                if let pass = r.passphrase { passphrase = pass }
                guard (ssid, passphrase) != before else { return }
                Wireless.persistWiFi(ssid: ssid, passphrase: passphrase)
                let sec = cachedWiFiSecurity(ssid: ssid) ?? (o.securityExplicit ? o.security : securityProfile)
                securityProfile = sec
                note("iPhone 分享了 Wi-Fi（名稱與密碼不打印）→ 套用並再叫一次手機")
                server.broadcastText(#"{"type":"wifiInfo","ssid":"\#(ssid.replacingOccurrences(of: "\"", with: ""))"}"#)
                pushWiFiConfiguration()
                feed(.wifiChanged)
            }
        }

        // ── iAP2 连结的接线：只把事件喂给状态机；消息里能当场答的（Wi-Fi 配置、正在播放、通话）照答 ──
        func wireBluetooth(_ acc: Iap2BluetoothAccessory, address: String, gen: Int) {
            acc.onLog = { note("iAP2 " + $0) }
            acc.onArtwork = { id, data in publishArtwork(id: id, data: data, server: server) }
            var authed = false
            acc.onPhase = { phase in
                guard phase == .authenticated else { return }
                authed = true
                noServiceStreak[address] = nil
                askPhoneForWiFi(acc.core, gen: gen)
                if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                // 配对完成后（哪怕引导已超时）清掉缓存的配对卡片；「配对新 iPhone」期间旧手机连上不算完成
                cancelCableFirst("已连上 iPhone")
                if !(pairingForNewDevice && pairingGuide && pairingBaseline.contains(address)) {
                    let hadPairingHint = pairingGuide || Wireless.cachedPairingHint() != nil
                    stopPairingGuide()
                    Wireless.setPairingHint(nil)
                    if hadPairingHint { server.broadcastText(#"{"type":"pairingDone"}"#) }
                }
                feed(.linkAuthenticated(gen: gen))
                // 首次：iPhone 要使用者解鎖、在 CarPlay 提示上點「連接」才會往下走。20 秒還沒動靜就提醒一次
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    guard links[gen] != nil, !live, !pairingGuide, pairFirstUntil == nil,
                          diag.availabilityAt == nil, diag.transportAt == nil, diag.firstStartAt == nil else { return }
                    showConnectHint("认证 20 秒仍没开始 CarPlay")
                }
            }
            acc.onFinished = { code in
                links[gen] = nil
                if accessory === acc { accessory = nil }
                clearNowPlaying(server: server)
                note("蓝牙 iAP2 结束（\(code)）")
                // 通道一直打不開、從沒認證過：iPhone「忘記這台車」會連藍牙配對一起刪，Mac 這邊的配對就成了死的。
                // 跟查不到服務一樣算進同一個計數，連 2 次就改開配對引導
                if !authed {
                    noServiceStreak[address, default: 0] += 1
                    if noServiceStreak[address] == 2 {
                        note("連 2 次打不開 iAP2 通道：藍牙配對可能兩邊不同步 → 開配對引導")
                        startPairingGuide("藍牙配對不同步", forNewDevice: true)
                    }
                }
                feed(.linkFinished(gen: gen, code: code))
            }
            acc.onMessage = { frame in
                switch frame.messageId {
                case Iap2Csm.wiFiInformation:
                    adoptPhoneWiFi(frame)
                    return []
                case Iap2Csm.CarPlay.wifiConfigRequest:
                    note("iPhone 要 Wi-Fi 配置 → 回 \(ssid.isEmpty ? "（Wi-Fi 名称未知）" : ssid)（密码不打印）")
                    DispatchQueue.main.async { diag.wifiConfig() }
                    return [wifiConfigFrame()]
                case 0x4E0E:
                    // DiPlay 同款：手机报完传输标识后重发一次 Wi-Fi 配置，确保它拿着凭据去连网
                    note("iPhone 报传输标识（0x4E0E）→ 补发 Wi-Fi 配置")
                    DispatchQueue.main.async { diag.wifiConfig() }
                    return [wifiConfigFrame()]
                case 0x4E0D:
                    // 手机说无线 CarPlay 可用：之后迟迟不发 0x4300 多半没加入 Wi-Fi（由状态机计时）
                    if frame.parameters.first(where: { $0.id == 0 })?.payload.first == 1 { feed(.transportAvailable(gen: gen)) }
                    return []
                case Iap2Csm.CarPlay.availability:
                    let a = Iap2Csm.carPlayAvailability(frame)
                    note("iPhone 报 CarPlay 可用（\(a?.summary ?? "?")）")
                    feed(.availability(gen: gen, wired: a?.wiredAvailable ?? false, wireless: a?.wirelessAvailable ?? true))
                    return []
                case Iap2Csm.Communications.callStateUpdate, Iap2Csm.Communications.update:
                    publishTelephony(frame, server: server)
                    return []
                case Iap2Csm.NowPlaying.update:
                    publishNowPlaying(frame, server: server, seek: { [weak acc] ms in
                        acc?.core.send(Iap2Csm.setNowPlayingInformation(elapsedMs: ms))
                    })
                    return []
                default:
                    note(String(format: "iAP2 消息 0x%04x（未处理）", frame.messageId))
                    return []
                }
            }
        }
        func startBeaconIfNeeded() {
            guard beacon == nil else { return }
            // 登录项常驻：桌宠没连（没人在看）时不广播，避免开机就弹配对
            if o.background, server.clientCount == 0 { return }
            let b = BluetoothBeacon(advertiseClass: true, log: { note("蓝牙广播：" + $0) })
            b.onIncoming = { device, channel in
                // IOBluetooth 回调线程 → 主队列
                DispatchQueue.main.async {
                    guard let raw = device.addressString else { channel.close(); return }
                    let address = PairingRules.normalize(raw)
                    // 引导中允许新手机连入；平时只接受已配对的 iPhone
                    guard PairingRules.acceptsIncoming(address: address, pairedPhones: Iap2BluetoothAccessory.pairedPhones(),
                                                       preferred: nil, pairingGuide: pairingGuide) else {
                        note("忽略未配对 iPhone 的主动连接（\(address)）")
                        channel.close()
                        return
                    }
                    note("iPhone 主动连入：\(device.name ?? "?")（\(address)）")
                    pendingIncoming.updateValue((device, channel), forKey: address)?.channel.close()
                    feed(.incoming(address))
                }
            }
            beacon = b
            Wireless.beacon = b
        }

        // ── 拔线冻帧（桌宠先冻住最后一帧，不回到「担心脸／连接中」）──
        var unplugFreeze = false
        var unplugCheckItem: DispatchWorkItem?
        func releaseUnplugFreeze(_ why: String) {
            guard unplugFreeze else { return }
            unplugFreeze = false
            unplugCheckItem?.cancel(); unplugCheckItem = nil
            Wireless.setHandoffHint(nil)
            note("拔线后画面已确认（\(why)）")
            if let text = Wireless.handoffPayload("done") { server.broadcastText(text) }
        }
        func cableGone(live wasLive: Bool, transport: CarPlayTransport?) {
            for action in CarPlayTransportPolicy.onCableGone(live: wasLive, transport: transport) {
                switch action {
                case .freezeFrame:
                    unplugFreeze = true
                    let start = Wireless.handoffPayload("start")
                    Wireless.setHandoffHint(start)
                    if let start { server.broadcastText(start) }
                    unplugCheckItem?.cancel()
                    let check = DispatchWorkItem {
                        guard unplugFreeze else { return }
                        if live { releaseUnplugFreeze("拔线 3 秒后会话仍在") }
                        else { note("拔线后会话已结束：保持冻帧，等蓝牙重连开新会话") }
                    }
                    unplugCheckItem = check
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: check)
                case .keepSession:
                    note("拔线：会话在 Wi-Fi 上，保持（iAP2 随线走，正在播放会过期）")
                case .expectReconnect:
                    note("拔线：有线会话会结束，等蓝牙重连接管")
                case .resumeBluetooth:
                    break   // 由状态机决定
                }
            }
        }

        // ── USB：carkit 链路、插线配对 ──
        var usbTrustHintShown = false   // needTrust 卡片是否在外（成功打开/拔线时收起，别重复广播）
        var usbHelpReason: String?      // 有线排障卡（usbNoData／usbLocked／usbTrustExpired／usbNoNetwork）在外的原因
        var usbNoDataSince: Date?       // iPhone 在 USB 汇流排上、usbmuxd 却没列出它的起点
        /// 有线排障卡：同一个原因不重复广播；nil＝收起（桌宠收到 trustDone 会收掉 usb 开头的卡）
        func showUsbHelp(_ reason: String?) {
            guard reason != usbHelpReason else { return }
            let had = usbHelpReason != nil
            usbHelpReason = reason
            if let reason {
                note("有线排障：\(reason)")
                if let r = ConnectDiagnostics.Reason(rawValue: reason) { diag.hintShown(r) }
                if let help = Wireless.wifiHelpPayload(ssid: ssid, passphraseMissing: false, reason: reason) { server.broadcastText(help) }
            } else if had, !usbTrustHintShown {
                server.broadcastText(#"{"type":"trustDone"}"#)
            }
        }
        var pairAttempt: Date = .distantPast
        var pairInFlight = false
        var pairingHandoffInFlight = false
        var pairingHandoffTimeout: DispatchWorkItem?
        var pairingAttemptedSerials = Set<String>()   // 每台 USB 设备在这段插线里只自动让位配对一次
        // HOMEPLAY_USB_CARKIT=1 可强制走 carkit（排障／偏好有线）。平常已配对手机的线只充电：
        // 真机 2026-10-22 14:59——只要 USB 上有 iAP2 链路，手机就把会话绑在它上面，拔线 115 ms 内结束会话。
        let preferCarkit = ProcessInfo.processInfo.environment["HOMEPLAY_USB_CARKIT"] == "1"
        let usbQueue = DispatchQueue(label: "homeplay.usb.poll")

        func ncmReady(_ device: Usbmuxd.Device) -> Bool {
            guard let iface = UsbNet.ncmInterfaces(udid: device.serial).first else { return false }
            return UsbNet.linkLocalV6(iface) != nil
        }
        /// NCM 网口与链路本地地址都就绪才构造有线 0x4301。
        func wiredStartReply(_ device: Usbmuxd.Device) -> Iap2Csm.Frame? {
            guard let iface = UsbNet.ncmInterfaces(udid: device.serial).first else { return nil }
            guard let fe80 = UsbNet.linkLocalV6(iface) else { return nil }
            // 有线 deviceIdentifier 用手机 AV 网口在 Mac 这一侧的 MAC（mib2q/DiPlay 同款），
            // public_key 字段仍是配对标识 pi——与无线同一契约，不是 Ed25519 公钥。
            let mac = NetInfo.mac(iface)?.uppercased() ?? "00:00:00:00:00:00"
            note("开有线会话：AV \(iface) \(fe80) → 控制口 \(o.controlPort)")
            return Iap2Csm.carPlayStartSessionWired(
                ipAddresses: [fe80], port: UInt32(o.controlPort),
                deviceIdentifier: mac, publicKey: store.identity.pairingId, sourceVersion: "950.7.1")
        }

        func beginPairingHandoff(_ address: String) {
            // 0x4E0E 通常早于控制会话 live；插线配对不需要等画面，拿到地址就让 USB 让位。
            guard !pairingHandoffInFlight, let device = activeUSB else {
                pairInFlight = false
                return
            }
            pairingHandoffInFlight = true
            pairingAttemptedSerials.insert(device.serial)
            let pairing = Wireless.handoffPayload("pairing")
            Wireless.setHandoffHint(pairing)
            if let pairing { server.broadcastText(pairing) }
            note("插线配对：结束 USB，让手机蓝牙恢复后发配对请求")
            func done() {
                pairingHandoffInFlight = false
                pairingHandoffTimeout?.cancel(); pairingHandoffTimeout = nil
                Wireless.setHandoffHint(nil)
                feed(.suspend(.cablePairing, false))
            }
            let safety = DispatchWorkItem {
                guard pairingHandoffInFlight else { return }
                stopPairingGuide()
                Wireless.setPairingHint(nil)
                note("插线配对 200 秒未完成：回退 USB CarPlay（本段插线不再自动尝试）")
                if let text = Wireless.handoffPayload("failed") { server.broadcastText(text) }
                done()
            }
            pairingHandoffTimeout = safety
            DispatchQueue.main.asyncAfter(deadline: .now() + 200, execute: safety)
            feed(.suspend(.cablePairing, true))   // 状态机收掉 USB 链路、暂停主动连线
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard pairingHandoffInFlight else { return }
                if let text = Wireless.bluetoothPairingPayload(phase: "request", timeout: 60, host: hostName) { server.broadcastText(text) }
                BondAssist.onConfirmCode = { code in
                    // 数字本身不是秘密（两边都显示），记日志方便对照
                    note("蓝牙配对：数字比对 \(code)，等 iPhone 上点「配对」")
                    if let text = Wireless.bluetoothPairingPayload(phase: "confirm", code: code, timeout: 30, host: hostName) { server.broadcastText(text) }
                }
                // 呼叫逾时（0x4）多半是手机藍牙在 USB 结束后还没恢复：等 3 秒再叫一次（真机 2026-10-24 10:13）
                func pairOnce(retry: Bool, _ then: @escaping (Bool, String) -> Void) {
                    BondAssist.pair(address: address) { ok, detail in
                        if !ok, retry, detail == "0x4", pairingHandoffInFlight {
                            note("插线配对：叫不到手机（0x4），3 秒后再叫一次")
                            if let text = Wireless.bluetoothPairingPayload(phase: "retry", timeout: 63, host: hostName) { server.broadcastText(text) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pairOnce(retry: false, then) }
                        } else {
                            then(ok, detail)
                        }
                    }
                }
                pairOnce(retry: true) { ok, detail in
                    pairInFlight = false
                    guard pairingHandoffInFlight, activeUSB?.serial == device.serial else { return }
                    if ok {
                        Wireless.setPairingHint(nil)
                        Wireless.persistPhone(address)
                        if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                        server.broadcastText(#"{"type":"pairingDone"}"#)
                        publishPhones(force: true)
                        note("插线配对完成：重开 USB，走 Wi-Fi 会话（线可继续插着充电）")
                        if let text = Wireless.handoffPayload("done") { server.broadcastText(text) }
                        done()
                    } else {
                        note("插线配对没成（\(detail)）：转到蓝牙配对引导")
                        // 0x4 叫不到手机；0x2／60s 没确认＝手机上没点「配对」
                        let reason = detail == "0x4" ? "noResponse" : (detail == "0x2" || detail.contains("没确认")) ? "notConfirmed" : "other"
                        if let text = Wireless.bluetoothPairFailedPayload(reason: reason) { server.broadcastText(text) }
                        done()
                        startPairingGuide("插线配对没确认", forNewDevice: true)
                    }
                }
            }
        }

        /// 首插配对：有线会话里手机报它的蓝牙地址（0x4E0E 参数 0），没配对就发起（手机上点一下）。
        func learnPhoneBluetooth(_ frame: Iap2Csm.Frame) {
            guard frame.messageId == 0x4E0E,
                  let param = frame.parameters.first(where: { $0.id == 0 }) else { return }
            var bytes = param.payload
            if bytes.last == 0 { bytes.removeLast() }
            guard let address = String(bytes: bytes, encoding: .utf8)?.uppercased(), address.contains(":") else { return }
            cancelCableFirst("USB 已报到手机地址")
            Wireless.unignorePhone(address)
            if let serial = activeUSB?.serial { Wireless.rememberUSBPhone(serial: serial, address: address) }
            if machine.usb?.phone != PairingRules.normalize(address) {
                note("有线会话里学到手机蓝牙地址：\(address)")
                feed(.usbLearned(phone: address))
            }
            switch Iap2BluetoothAccessory.locate(address: address) {
            case .success, .failure(.noService):
                // 已配对（SDP 缓存里可能还没有 iAP2 服务，拔线后的蓝牙重连会刷新）：不要再发起配对
                Wireless.persistPhone(address)
                if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                note("这台手机已配对过蓝牙，拔线即无线")
            case .failure(let error):
                // USB CarPlay 期间手机会临时关蓝牙/SDP 不可用；系统配对记录还在时不要再弹一次配对窗。
                // 只看系统配对记录：「认识过」不算（忘记后再插线、或手机刷机后，必须能重新配对）
                if Iap2BluetoothAccessory.isSystemPaired(address) {
                    Wireless.persistPhone(address)
                    if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                    note("这台手机在系统里已配对（\(error)）；拔线后蓝牙重连会刷新，不再重复发起配对")
                    return
                }
                if let serial = activeUSB?.serial, pairingAttemptedSerials.contains(serial) {
                    note("这段插线已经尝试过配对：保持有线；拔线再插可重试，或右键「配对新 iPhone」")
                    return
                }
                guard pairFirstUntil == nil else { return }
                if let serial = activeUSB?.serial { pairingAttemptedSerials.insert(serial) }
                // 手机端配对优先：USB 留着，先不开画面；桌宠显示「到 iPhone 设置 › 蓝牙点这台 Mac」，Mac 保持可被发现
                // 有線一定先出畫面（不等藍牙）；藍牙配對在背景引導，配好之後拔線就能改走無線
                note("第一次插线：先用有线开画面；同时请在 iPhone 设置 › 蓝牙里点「\(hostName)」配对，之后就能无线")
                startPairingGuide("插线：手机还没配对", forNewDevice: true)
            }
        }

        func wireUSB(_ acc: Iap2UsbAccessory, gen: Int) {
            acc.onLog = { note("USB " + $0) }
            acc.onArtwork = { id, data in publishArtwork(id: id, data: data, server: server) }
            acc.onPhase = { phase in
                guard phase == .authenticated else { return }
                feed(.linkAuthenticated(gen: gen))
                askPhoneForWiFi(acc.core, gen: gen)   // 插線時就把之後無線要的 Wi-Fi 備好
                // 插线第一次也有 CarPlay 同意提示（iOS 27 叫「CarPlay Ultra」）：20 秒没动静提醒一次；插线配对暂缓时不算
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    guard links[gen] != nil, !live, pairFirstUntil == nil, heldAvailability == nil,
                          diag.availabilityAt == nil, diag.transportAt == nil, diag.firstStartAt == nil else { return }
                    showConnectHint("有线认证 20 秒仍没开始 CarPlay")
                }
            }
            acc.onFinished = { code in
                links[gen] = nil
                if accessoryUsb === acc { accessoryUsb = nil }
                clearNowPlaying(server: server)
                note("USB iAP2 结束（\(code)）")
                feed(.linkFinished(gen: gen, code: code))
            }
            acc.onMessage = { [weak acc] frame in
                learnPhoneBluetooth(frame)
                if frame.messageId == Iap2Csm.wiFiInformation { adoptPhoneWiFi(frame); return [] }
                switch frame.messageId {
                case Iap2Csm.CarPlay.availability:
                    let a = Iap2Csm.carPlayAvailability(frame)
                    note("USB CarPlay 可用性（0x4300）：\(a?.summary ?? "?")")
                    let event = ConnectionEvent.availability(gen: gen, wired: a?.wiredAvailable ?? false, wireless: a?.wirelessAvailable ?? false)
                    if let until = pairFirstUntil, until > Date() {
                        heldAvailability = event   // 等手机端配对（见 releaseHeldAvailability）
                        note("插线配对：先等 iPhone 上配对，再开画面")
                    } else {
                        feed(event)
                    }
                    return []
                case Iap2Csm.CarPlay.wifiConfigRequest:
                    note("USB 会话里手机要 Wi-Fi 配置 → 回 \(ssid)（密码不打印）")
                    return [wifiConfigFrame()]
                case Iap2Csm.Communications.callStateUpdate, Iap2Csm.Communications.update:
                    publishTelephony(frame, server: server)
                    return []
                case Iap2Csm.NowPlaying.update:
                    publishNowPlaying(frame, server: server, seek: { ms in
                        acc?.core.send(Iap2Csm.setNowPlayingInformation(elapsedMs: ms))
                    })
                    return []
                default:
                    note(String(format: "iAP2 消息 0x%04x（未处理）", frame.messageId))
                    return []
                }
            }
        }

        // ── iAP 数据通道（流 130）：Wi-Fi 会话里的 iAP2 路径，拔线后仍在 ──
        // 手机 SETUP 130 后拿到隧道句柄；RECORD 一到就在隧道上跑一套完整的 iAP2 bring-up。
        // 隧道只在会话里存在，不是状态机的「连结」：它不回 0x4301（会话结束后由藍牙／USB 那条交接）。
        func startTunnelCore(_ why: String) {
            guard let link = tunnelLink else { return }
            if let acc = Wireless.accessoryTunnel, !acc.finished { return }
            var coreInfo = Iap2AccessoryCore.Info()
            coreInfo.ssid = ssid
            let acc = Iap2TunnelAccessory(identity: identity, info: coreInfo) { [weak link] bytes in
                if link?.send(Data(bytes)) != true { note("隧道 iAP2：事件通道未连，\(bytes.count) 字节未发") }
            }
            acc.onLog = { note("隧道 iAP2 " + $0) }
            acc.onPhase = { phase in
                if phase == .authenticated { note("隧道 iAP2 已认证：iAP2 现在走 Wi-Fi 会话（拔线不影响）") }
            }
            acc.onFinished = { code in
                if Wireless.accessoryTunnel === acc { Wireless.accessoryTunnel = nil }
                note("隧道 iAP2 结束（\(code)）")
            }
            acc.onArtwork = { id, data in publishArtwork(id: id, data: data, server: server) }
            acc.onMessage = { [weak acc] frame in
                // 不从隧道学手机地址：隧道属于正在直播的那台，不一定是线上那台（会把线上那台记错）
                switch frame.messageId {
                case Iap2Csm.CarPlay.availability:
                    note("隧道 iAP2：手机报 CarPlay 可用（交接由藍牙／USB 那条负责，这里不回）")
                    return []
                case Iap2Csm.CarPlay.wifiConfigRequest:
                    note("隧道 iAP2：手机要 Wi-Fi 配置 → 回 \(ssid)（密码不打印）")
                    return [wifiConfigFrame()]
                case Iap2Csm.Communications.callStateUpdate, Iap2Csm.Communications.update:
                    publishTelephony(frame, server: server)
                    return []
                case Iap2Csm.NowPlaying.update:
                    publishNowPlaying(frame, server: server, seek: { ms in acc?.core.send(Iap2Csm.setNowPlayingInformation(elapsedMs: ms)) })
                    return []
                default:
                    note(String(format: "隧道 iAP2 消息 0x%04x（未处理）", frame.messageId))
                    return []
                }
            }
            Wireless.accessoryTunnel = acc
            note("隧道 iAP2 起跑（\(why)）")
            acc.start()
        }
        s.onIapTunnel = { link in
            DispatchQueue.main.async {
                Wireless.accessoryTunnel?.close()
                tunnelLink = link
                note("iAP 隧道就绪（dataPort \(link.dataPort)）")
                link.onConnected = { _ in DispatchQueue.main.async { startTunnelCore("手机连上数据口") } }
                link.onIap = { d in DispatchQueue.main.async { Wireless.accessoryTunnel?.feed([UInt8](d)) } }
                link.onClosed = { [weak link] in
                    DispatchQueue.main.async {
                        Wireless.accessoryTunnel?.transportClosed()
                        if let link, link.isTornDown, tunnelLink === link { tunnelLink = nil }
                    }
                }
                if live { startTunnelCore("流 130 在 RECORD 之后 SETUP") }
            }
        }
        s.onCommand = { type, params in
            if type == "requestUI" {
                DispatchQueue.main.async {
                    note("手机上点了 HomePlay 图标（requestUI\(params.isEmpty ? "" : "，" + params.keys.sorted().joined(separator: ","))）：桌宠回到表面，CarPlay 留在后台")
                    if let text = Wireless.requestUIPayload() { server.broadcastText(text) }
                }
                return
            }
            guard type == "disableBluetooth" else { return }
            DispatchQueue.main.async {
                // 藍牙 iAP2 留不留由状态机看「有没有流 130 隧道」决定（没有就照一般退避重连，有就慢速保活）
                let state = Wireless.accessoryTunnel.map { "隧道 iAP2 \($0.phase.rawValue)" }
                    ?? (tunnelLink == nil ? "手机没 SETUP 流 130，藍牙仍是 iAP2 路径" : "隧道等手机连")
                note("手机要求停用蓝牙 iAP2（disableBluetooth，deviceID \(params["deviceID"] ?? "?")）：\(state)")
            }
        }

        sessionStartedHook = {
            releaseUnplugFreeze("新会话已开始")
            startTunnelCore("RECORD")
        }

        // ── 效果执行 ──
        func openBluetooth(_ address: String, gen: Int) {
            guard sdpBusy == 0 else {
                afterSDP.append { if machine.link.gen == gen { openBluetooth(address, gen: gen) } }
                return
            }
            switch Iap2BluetoothAccessory.locate(address: address) {
            case .failure(let e):
                note("找 \(address) 的 iAP2 服务：\(e.description)")
                switch e {
                case .noService, .noChannel:
                    // Mac 還留著配對、iPhone 那邊已經忘了（或從沒把這台 Mac 當車配過）：SDP 永遠查不到 iAP2。
                    // 連 2 次就別再空轉，改開配對引導：讓使用者在 iPhone 藍牙「其他裝置」點這台 Mac 重配
                    noServiceStreak[address, default: 0] += 1
                    if noServiceStreak[address] == 2 {
                        note("連 2 次查不到 iAP2 服務：藍牙配對可能兩邊不同步 → 開配對引導")
                        startPairingGuide("藍牙配對不同步", forNewDevice: true)
                    }
                    feed(.linkUnavailable(gen: gen, .noService))
                case .notPaired: feed(.linkUnavailable(gen: gen, .notPaired))
                default: feed(.linkUnavailable(gen: gen, .notFound))
                }
            case .success(let (device, channelID)):
                // 找到服務不代表連得上（Mac 留著的舊配對也找得到）：計數只在真的認證成功時歸零（wireBluetooth.onPhase）
                s.setPhoneBluetoothAddress(address)
                startBeaconIfNeeded()
                // 识别信息里的无线 CarPlay 传输组件必须报真实 SSID（MacPlay/DiPlay 同款）
                var coreInfo = Iap2AccessoryCore.Info()
                coreInfo.ssid = ssid
                let acc = Iap2BluetoothAccessory(identity: identity, info: coreInfo, stopAfterAuth: false)
                // 一律 6 秒：短逾时＋立刻重试把尝试次数加倍，手机慢一点回就被当失败，之后开始拒绝这台 Mac。
                acc.openTimeout = 6
                wireBluetooth(acc, address: address, gen: gen)
                links[gen] = .bluetooth(acc)
                lastBluetooth = (address, acc)
                accessory = acc
                note("开蓝牙 iAP2 → \(address)")
                if !acc.start(device: device, channelID: channelID) {
                    links[gen] = nil
                    if accessory === acc { accessory = nil }
                    acc.onFinished = nil
                    feed(.linkUnavailable(gen: gen, .notFound))
                }
            }
        }
        func openUSB(gen: Int) {
            guard let device = activeUSB else {
                feed(.linkFinished(gen: gen, code: -1))
                return
            }
            cancelCableFirst("USB 已插入")
            note("开 USB carkit（\(String(device.serial.prefix(8)))）")
            let ident = identity
            // carkit 開流含 lockdown/TLS 握手，是阻塞呼叫：放背景開好再回主執行緒接上。
            usbQueue.async {
                let opened = Result { try Iap2UsbAccessory(device: device, identity: ident, stopAfterAuth: false) { note("USB " + $0) } }
                DispatchQueue.main.async {
                    guard machine.link.gen == gen, activeUSB?.serial == device.serial else {
                        if case .success(let acc) = opened { acc.close() }
                        return
                    }
                    switch opened {
                    case .success(let acc):
                        showUsbHelp(nil)
                        if usbTrustHintShown {
                            usbTrustHintShown = false
                            Wireless.setTrustHint(nil)
                            server.broadcastText(#"{"type":"trustDone"}"#)   // 用户点过信任：卡片收起
                        }
                        wireUSB(acc, gen: gen)
                        links[gen] = .usb(acc)
                        accessoryUsb = acc
                        acc.start()
                    case .failure(let error):
                        let why = UsbOpenFailure.classify("\(error)")
                        diag.usbOpenFailed(why)
                        note("carkit 打不开（\(error)）→ \(why.rawValue)——确认 iPhone 已解锁、点「信任」，且数据线能传数据")
                        switch why {
                        case .locked: showUsbHelp("usbLocked")
                        case .trustExpired: showUsbHelp("usbTrustExpired")
                        case .notIPhone: break
                        case .notTrusted, .other:
                            showUsbHelp(nil)
                            if !usbTrustHintShown, let hint = Wireless.usbTrustHintPayload() {
                                usbTrustHintShown = true
                                Wireless.setTrustHint(hint)
                                server.broadcastText(hint)
                            }
                        }
                        feed(.linkFinished(gen: gen, code: -1))
                    }
                }
            }
        }
        func closeLink(_ gen: Int) {
            switch links.removeValue(forKey: gen) {
            case .bluetooth(let acc):
                acc.onFinished = nil
                acc.close()
                if accessory === acc { accessory = nil }
            case .usb(let acc):
                acc.onFinished = nil
                acc.close()
                if accessoryUsb === acc { accessoryUsb = nil }
            case nil:
                break
            }
            clearNowPlaying(server: server)
        }
        func sendStart(gen: Int, _ kind: StartKind) {
            let wait = startHoldUntil.timeIntervalSinceNow
            if wait > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { sendStart(gen: gen, kind) }
                return
            }
            guard let c = core(gen), !c.finished else { return }
            switch kind {
            case .wireless:
                // 有线和 Wi-Fi 同网段时先给进出同一张网卡的那个地址（见 NetInfo.lanAddresses）
                var addrs = NetInfo.lanAddresses(wifi: o.iface)
                if addrs.isEmpty { addrs = [currentIP() ?? ip] }
                // 最后附上 Wi-Fi 的链路本地 IPv6：DiPlay 优先给它；真机 2026-10-24 SE 也是经它连进来的
                if let v6 = NetInfo.linkLocalIPv6(o.iface), !addrs.contains(v6) { addrs.append(v6) }
                note("送 0x4301：无线 \(addrs.joined(separator: "、")):\(o.controlPort)")
                c.send(startMessage(addrs))
            case .wirelessAlternate:
                // 12 秒没回连：链路本地 IPv6；藍牙那条再换一次安全类型（探测可能把混合网络误报成纯 WPA3，或反之）
                let a = alternateHost ?? NetInfo.linkLocalIPv6(o.iface) ?? currentIP() ?? ip
                if case .bluetooth = links[gen] {
                    let alt: Iap2Csm.WiFiSecurity = (securityProfile == .wpa3Only) ? .wpaWpa2 : .wpa3Only
                    note("补发 0x4301：\(a)，安全类型 \(Wireless.securityLabel(securityProfile)) → \(Wireless.securityLabel(alt))")
                    c.send(wifiConfigFrame(alt))
                    c.send(startMessage([a], security: alt))
                } else {
                    note("补发 0x4301：无线 \(a)")
                    c.send(startMessage([a]))
                }
            case .wired:
                guard let device = activeUSB, let frame = wiredStartReply(device) else {
                    note("要送有线 0x4301，但 NCM 还没就绪")
                    return
                }
                c.send(frame)
            }
        }
        execute = { effect in
            switch effect {
            case .openBluetooth(let address, let gen): diag.linkOpened(); openBluetooth(address, gen: gen)
            case .openUSB(let gen): diag.linkOpened(); openUSB(gen: gen)
            case .adoptIncoming(let address, let gen):
                diag.linkOpened()
                guard let inc = pendingIncoming.removeValue(forKey: address) else {
                    feed(.linkUnavailable(gen: gen, .notFound)); return
                }
                s.setPhoneBluetoothAddress(address)
                var coreInfo = Iap2AccessoryCore.Info()
                coreInfo.ssid = ssid
                let acc = Iap2BluetoothAccessory(identity: identity, info: coreInfo, stopAfterAuth: false)
                acc.openTimeout = 6
                wireBluetooth(acc, address: address, gen: gen)
                links[gen] = .bluetooth(acc)
                lastBluetooth = (address, acc)
                accessory = acc
                if !acc.adopt(channel: inc.channel) {
                    links[gen] = nil
                    if accessory === acc { accessory = nil }
                    acc.onFinished = nil
                    inc.channel.close()
                    feed(.linkUnavailable(gen: gen, .notFound))
                }
            case .rejectIncoming(let address):
                if let inc = pendingIncoming.removeValue(forKey: address) {
                    note("这时不接 \(address) 的主动连接（已有连线在开或用户选了别台）")
                    inc.channel.close()
                }
            case .closeLink(let gen): closeLink(gen)
            case .dropBaseband(let address):
                if let last = lastBluetooth, last.address == PairingRules.normalize(address) {
                    if last.acc.dropBaseband() { note("已断开到 \(address) 的基带连接") }
                } else if let d = IOBluetoothDevice(addressString: address.replacingOccurrences(of: ":", with: "-").lowercased()),
                          d.isConnected(), d.closeConnection() == kIOReturnSuccess {
                    note("已断开到 \(address) 的基带连接")
                }
            case .refreshSDP(let address, let timeout):
                note("刷新 \(address) 的 SDP（最多 \(Int(timeout)) 秒）")
                sdpBusy += 1
                SDPRefresh.refresh(address: address, timeout: timeout) {
                    sdpBusy -= 1
                    if sdpBusy == 0 { let waiting = afterSDP; afterSDP = []; waiting.forEach { $0() } }
                }
            case .republishSDP:
                note("重新发布车机 SDP")
                beacon?.republish()
            case .sendWiFiConfig(let gen):
                diag.wifiConfig()
                core(gen)?.send(wifiConfigFrame())
            case .sendStart(let gen, let kind):
                diag.startSent(now: CACurrentMediaTime(), wired: kind == .wired)
                sendStart(gen: gen, kind)
                // 不知道 Wi-Fi 名稱（macOS 對 App 隱藏）：iPhone 拿到的是空的 Wi-Fi 設定。正常 0.2–0.5 秒就連回，
                // 5 秒沒回就直接請使用者填網路名，不等 15 秒的通用排障卡
                if kind != .wired, ssid.isEmpty, !ssidHintArmed {
                    ssidHintArmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        ssidHintArmed = false
                        guard !live, diag.controlAt == nil, ssid.isEmpty else { return }
                        showConnectHint("Wi-Fi 名称未知")
                    }
                }
            case .switchSession(let address):
                clearNowPlaying(server: server)
                note("会话换到 \(address ?? "（未定）")")
                s.switchPhone(to: address ?? "")
            case .dropSession:
                startHoldUntil = Date().addingTimeInterval(0.3)
                s.dropConnections("重開會話")
            case .restartProcess(let kind):
                switch kind {
                case .young where Wireless.youngRestartAllowed():
                    note("行程刚起来（\(Int(Date().timeIntervalSince(processStartedAt))) 秒）就连不上：再重启一次接收器（新行程通常 2 秒内连上）")
                case .selfHeal where selfHealAllowed():
                    note("自愈：蓝牙连续连不上手机。退出让 launchd 干净重启接收器（新行程 2 秒内能连上）")
                default:
                    DispatchQueue.main.async { feed(.restartDenied(kind)) }
                    return
                }
                restarting = true
                inbox.removeAll()
                Wireless.shutdown()
                DispatchQueue.main.asyncAfter(deadline: .now() + Wireless.exitGrace) { Wireless.reexec() }
            case .setTimer(let id, let after, let token):
                timers[id]?.cancel()
                let item = DispatchWorkItem { timers[id] = nil; feed(.timer(id, token: token)) }
                timers[id] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
                if id == .retry { note("蓝牙/USB \(String(format: "%.1f", after)) 秒后重试") }
            case .cancelTimer(let id):
                timers.removeValue(forKey: id)?.cancel()
            case .persistPreferred(let address):
                Wireless.persistPhone(address)
            case .publishPhones:
                publishPhones(force: true)
            case .notify(let hint):
                switch hint {
                case .wifiHelp:
                    note("手机迟迟没开始／没连回：判断原因后给桌宠排障卡")
                    showConnectHint("交接逾时", fallback: .wifiNoConnectBack)
                case .needPairing:
                    needPairing()
                case .usbNoNetwork:
                    diag.usbNoNetworkSeen()
                    showUsbHelp("usbNoNetwork")
                case .cableGone(let wasLive, let transport):
                    cableGone(live: wasLive, transport: transport)
                }
            case .log(let text):
                note(text)
            }
        }

        // ── USB 轮询（1 秒一次）：只把「插上哪台／拔了」告诉状态机 ──
        var cableDebounce = CableDebounce(misses: 2)
        var cablePresent = false
        var usbArrival: [String] = []   // 后插入的设备在末尾，拥有唯一的 CarPlay 会话优先权
        var usbPollInFlight = false
        func usbTick(_ devices: [Usbmuxd.Device], onBus: Int = 0) {
            // 有电没资料：iPhone 在 USB 汇流排上 4 秒、usbmuxd 却没列出它。只在桌宠前台设置、或还没有任何配对手机时提示
            //（已配对的手机锁着插线充电很常见，不该跳卡）
            if devices.isEmpty, onBus > 0 {
                if usbNoDataSince == nil { usbNoDataSince = Date() }
                if let since = usbNoDataSince, Date().timeIntervalSince(since) >= 4, usbHelpReason != "usbNoData",
                   uiEngaged || Iap2BluetoothAccessory.pairedPhones().isEmpty {
                    diag.usbNoDataSeen()
                    showUsbHelp("usbNoData")
                }
            } else {
                usbNoDataSince = nil
                if usbHelpReason == "usbNoData" { showUsbHelp(nil) }
            }
            // usbmuxd 偶尔丢错会被当成空清单：连续两次没看到才算拔线，一次抖动不动任何状态。
            cablePresent = cableDebounce.observe(present: !devices.isEmpty)
            if devices.isEmpty, cablePresent { return }
            let present = Set(devices.map(\.serial))
            usbArrival.removeAll { !present.contains($0) }
            pairingAttemptedSerials.formIntersection(present)
            let fresh = devices.filter { !usbArrival.contains($0.serial) }.sorted { $0.id < $1.id }   // 同一轮多台：DeviceID 大的算后到
            usbArrival.append(contentsOf: fresh.map(\.serial))
            guard let serial = usbArrival.last, let device = devices.first(where: { $0.serial == serial }) else {
                guard activeUSB != nil else { return }
                activeUSB = nil
                pairAttempt = .distantPast   // 拔线再插＝新的重试机会，不必等 30 秒冷却
                if usbTrustHintShown {
                    usbTrustHintShown = false
                    Wireless.setTrustHint(nil)
                    server.broadcastText(#"{"type":"trustDone"}"#)   // 拔线：收起「点信任」卡片
                }
                if pairingHandoffInFlight {
                    // 不再等 200 秒安全计时：线拔了这次插线配对就算结束，再插就是新的一次（真机 2026-10-24 09:04 卡了 2 分多钟）
                    note("插线配对当中拔了线：结束这次插线配对")
                    pairingHandoffTimeout?.perform()
                }
                note("USB 拔线")
                if usbHelpReason != "usbNoData" { showUsbHelp(nil) }
                feed(.usbDetached)
                return
            }
            guard activeUSB?.serial != serial else { return }
            if activeUSB != nil { note("USB 后到设备顶掉先到设备（\(String(serial.prefix(8)))），只保留一个 CarPlay 会话") }
            activeUSB = device
            cancelCableFirst("USB 已插入")
            let phone = Wireless.usbPhoneAddress(serial: serial)
            // 认识的手机也算（刚起来时系统配对清单可能一时读不到）
            let chargeOnly = !preferCarkit && phone.map { Iap2BluetoothAccessory.isSystemPaired($0) || Wireless.isKnownPhone($0) } == true
            diag.usbAttached()
            note("USB 插上 \(String(serial.prefix(8)))（\(phone ?? "还不认识")\(chargeOnly ? "，已配对：线只充电" : "")）")
            feed(.usbAttached(serial: serial, phone: phone, chargeOnly: chargeOnly))
        }
        func usbWatch() {
            defer { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { usbWatch() } }
            // listDevices() 是阻塞 socket，放主執行緒會在最壞情況下卡住整個接收器。
            guard !usbPollInFlight else { return }
            usbPollInFlight = true
            usbQueue.async {
                let devices = (try? Usbmuxd.listDevices()) ?? []
                let onBus = devices.isEmpty ? UsbNet.iPhonesOnBus() : 0
                DispatchQueue.main.async {
                    usbPollInFlight = false
                    usbTick(devices, onBus: onBus)
                }
            }
        }

        // 上一个行程有没有正常结束：起来时留记号，Wireless.shutdown() 收掉；记号还在＝被硬杀或当机
        let crashed = FileManager.default.fileExists(atPath: Wireless.runningMarker.path)
        try? Data().write(to: Wireless.runningMarker)
        // 车机类 + iAP2/CarPlay SDP 必须在配对前就广播：iPhone 在配对时做 SDP 发现，
        // 那一刻看不到 CarPlay 服务，就只会把 Mac 当普通电脑，之后也不再提示 CarPlay。
        if o.background {
            // 登录项常驻：等桌宠（WS 客户端）连上再广播；没人时就撤掉广播并退出。
            // 这样「退出 app 后 iPhone 一直弹配对请求」不会发生。
            var idleSince: TimeInterval?
            var idleExitScheduled = false
            var firstPairGuideStarted = false
            let watch = Timer(timeInterval: 5, repeats: true) { _ in
                if server.clientCount > 0 {
                    idleSince = nil
                    if beacon == nil {
                        startBeaconIfNeeded()
                        note("桌宠已连接：开始/恢复蓝牙广播")
                    }
                    // 首次设定的配对引导后台模式不随启动跑（那时没人看）；桌宠连上再补。
                    // 不补的话，「第一次点连接就装了常驻」的新用户等不到「让 Mac 可被发现」，首配卡死。
                    if o.phoneAddress == nil, !firstPairGuideStarted {
                        firstPairGuideStarted = true
                        startPairingGuide("第一次设定：让 iPhone 在蓝牙「其他装置」找得到这台 Mac")
                    }
                    return
                }
                if idleSince == nil { idleSince = Date().timeIntervalSince1970 }
                let idle = Date().timeIntervalSince1970 - (idleSince ?? 0)
                if idle >= 15, let b = beacon {
                    b.stop()
                    beacon = nil
                    Wireless.beacon = nil
                    note("后台空闲：已停止蓝牙广播（iPhone 不再把 Mac 看成车机）")
                }
                if idle >= 120, !idleExitScheduled {
                    idleExitScheduled = true
                    note("后台空闲 2 分钟：结束会话并退出，等桌宠下次打开再拉起")
                    Wireless.shutdown()   // 先干净收掉手机会话，再照 SIGTERM 的规矩退出
                    DispatchQueue.main.asyncAfter(deadline: .now() + Wireless.exitGrace) { exit(0) }
                }
            }
            RunLoop.main.add(watch, forMode: .common)
        }
        startBeaconIfNeeded()
        publishPhones(force: true)
        // 先看一次 USB（线可能本来就插着），再开始连：状态机据此决定先走藍牙还是 USB
        usbQueue.async {
            let devices = (try? Usbmuxd.listDevices()) ?? []
            DispatchQueue.main.async {
                usbTick(devices)
                feed(.start(preferred: o.phoneAddress, crashed: crashed))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { usbWatch() }
            }
        }
        note("双模：一个连线状态机统一决定连谁、怎么连；已配对手机插线只充电，会话走蓝牙→Wi-Fi")
        // 第一次設定（還沒記住任何 iPhone）：一開就讓 Mac 可被發現、開配對引導，使用者不必自己去開藍牙設定
        if o.phoneAddress == nil, !o.background {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { startPairingGuide("第一次设定：让 iPhone 在蓝牙「其他装置」找得到这台 Mac") }
        }
        // Mac 睡眠／喚醒：像車機熄火再發動——睡前把會話乾淨收掉（手機立刻回到自己的畫面），
        // 醒來清掉退避、丟掉舊的藍牙通道、稍等再重連。
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            note("Mac 要睡了：收掉会话")
            feed(.sleep)
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            note("Mac 醒来：0.8 秒后重连")
            feed(.wake)
        }
        RunLoop.main.run()
        exit(0)
    }
}
