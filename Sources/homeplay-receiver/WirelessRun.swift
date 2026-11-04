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

// 無線路徑：藍牙 iAP2 → Wi-Fi 交接 → 會話。行文本自 Wireless.swift 拆出。
extension Wireless {
    static func run(_ o: Options, server: WSServer) -> Never {
        // 1 身份（自备）
        let identity: Iap2MfiIdentity
        do { identity = try Iap2MfiIdentity(directory: o.identityDir) }
        catch { note("身份加载失败：\(error)"); exit(2) }
        note("身份自检通过（证书 \(identity.certificate.count) 字节，内容不打印）")

        // 2 网络：接收端地址、Wi-Fi MAC、信道
        guard let ip = NetInfo.ipv4(o.iface) else { note("网卡 \(o.iface) 没有 IPv4 地址（要和 iPhone 在同一个局域网）"); exit(6) }
        let channel = o.channel ?? UInt8(clamping: CWWiFiClient.shared().interface(withName: o.iface)?.wlanChannel()?.channelNumber ?? 0)
        guard channel != 0 else { note("读不到 Wi-Fi 信道，用 --channel 指定 iPhone 所连 Wi-Fi 的信道"); exit(6) }
        note("接收端 \(ip)（\(o.iface)），信道 \(channel)，控制口 \(o.controlPort)")
        var passphrase = o.passphrase   // 桌宠通过 Wi-Fi 设置菜单更新后会改这里
        var ssid = o.ssid

        // 3 会话（控制面）
        let store = PairingStore()
        // 0x4301 的两个身份必须和 Bonjour TXT 同源：字段 3=deviceid、字段 4=pi（不是 pk）。
        note("AirPlay 身份：deviceid=\(store.identity.deviceId) pi=\(store.identity.pairingId)（0x4301 字段 3/4）")
        let (s, h264) = makeSession(o: o, server: server, store: store, identity: identity) { $0.phoneBluetoothAddress = o.phoneAddress }
        let alternateHost = NetInfo.linkLocalIPv6(o.iface)
        if alternateHost != nil { note("IPv6 备用地址就绪（链路本地）") }
        var fallbackItem: DispatchWorkItem?
        var handoffGeneration = 0
        var wifiWaitItem: DispatchWorkItem?   // 手机说无线可用、但迟迟不发 0x4300：多半没加入 Wi-Fi
        var controlSeen = false   // 手机连回控制口（不代表已经出画面）
        var sawAvailability = false          // 本轮 iAP2 会话收到过 0x4300
        var lastNudgeAt = Date.distantPast   // 自动「第二次连接」节流（5 分钟）
        /// 0x4301 用的安全类型：纯 WPA3 → 4，WPA2/混合 → 2（0x5703 由消息层钳到 ≤2）
        var securityProfile = o.security
        var securityAltTried = false   // 第一次没回连时换另一种安全类型试一次（防探测误判）
        /// 发送时现读当前 IPv4：DHCP 续租/换网/睡眠唤醒后地址可能变，0x4301 不能发旧地址。
        func currentIP() -> String? { NetInfo.ipv4(o.iface) }
        /// 0x4301 用的安全类型（启动时按 AP 能力解析，换 Wi-Fi 时重算）
        func currentSecurity() -> Iap2Csm.WiFiSecurity { securityProfile }
        func currentChannel() -> UInt8 {
            if let c = o.channel, c != 0 { return c }
            return UInt8(clamping: CWWiFiClient.shared().interface(withName: o.iface)?.wlanChannel()?.channelNumber ?? Int(channel))
        }
        func startMessage(_ addresses: [String]) -> Iap2Csm.Frame {
            // 字段 3 必须是 TXT deviceid、字段 4 必须是 TXT pi（iAP2 里它叫 public_key，但 iOS
            // 按「配对标识」解析并与 Bonjour pi 比对；发 pk 会让手机认不出这是它被告知的那台接收端）。
            Iap2Csm.carPlayStartSessionWireless(
                ssid: ssid, passphrase: passphrase, channel: currentChannel(), ipAddresses: addresses, security: currentSecurity(),
                port: UInt32(o.controlPort), deviceIdentifier: store.identity.deviceId, publicKey: store.identity.pairingId,
                sourceVersion: "950.7.1")
        }
        func cancelFallback() { handoffGeneration += 1; fallbackItem?.cancel(); fallbackItem = nil }
        /// 0x4301 当生命周期事件处理：手机可能慢、消息可能丢。没连回控制口就继续补发——
        /// 12 秒先用链路本地 IPv6 备用地址，之后每 15 秒用当前 IPv4，最多约 2 分钟；
        /// 控制连接一接入、会话开始或 iAP2 结束就立刻停（CardDeck：0x4301 迟到也要处理）。
        func scheduleHandoffRetries() {
            cancelFallback()
            let gen = handoffGeneration
            var attempt = 0
            func fire() {
                guard gen == handoffGeneration, !live, !controlSeen,
                      let core = Wireless.accessory?.core, !core.finished else { return }
                attempt += 1
                let address: String?
                if attempt == 1, let alt = alternateHost ?? NetInfo.linkLocalIPv6(o.iface) {
                    note("12 秒没等到回连，用链路本地 IPv6 再叫一次")
                    address = alt
                } else {
                    address = currentIP()
                    if let a = address { note("第 \(attempt) 次补发 0x4301（\(a):\(o.controlPort)）") }
                }
                if attempt == 1, !securityAltTried {
                    // 探测可能把混合网络误报成纯 WPA3（或反之）：第一次没回连就换另一种安全类型
                    // 再叫一次（0x5703 由消息层钳到 ≤2），之后仍用探测值。
                    securityAltTried = true
                    let saved = securityProfile
                    securityProfile = (saved == .wpa3Only) ? .wpaWpa2 : .wpa3Only
                    if let acc = Wireless.accessory {
                        acc.core.send(Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase,
                                                                         security: securityProfile, channel: currentChannel()))
                    }
                    note("安全类型回退尝试：\(Wireless.securityLabel(saved)) → \(Wireless.securityLabel(securityProfile))")
                    if let address { core.send(startMessage([address])) }
                    securityProfile = saved
                } else if let address {
                    core.send(startMessage([address]))
                }
                guard attempt < 8 else {
                    note("多次补发 0x4301 仍没回连：控制口保持监听，等手机自己来")
                    return
                }
                let item = DispatchWorkItem { fire() }
                fallbackItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 1 ? 12 : 15), execute: item)
            }
            let item = DispatchWorkItem { fire() }
            fallbackItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
        }
        /// 用户改了 Wi-Fi 设置：立刻把 0x5703 再推给当前手机（蓝牙/USB 都推），不用重插或重配。
        func pushWiFiConfiguration() {
            let frame = Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase, security: currentSecurity(), channel: currentChannel())
            if let acc = accessory, !live { acc.core.send(frame); note("Wi-Fi 配置已重推给手机（蓝牙）") }
            if let usb = Wireless.accessoryUsb { usb.core.send(frame); note("Wi-Fi 配置已重推给手机（USB）") }
        }
        s.onLog = { note($0) }
        s.onActive = {
            live = true
            Wireless.setPairingHint(nil)
            Wireless.setCableHint(nil)
            Wireless.setTrustHint(nil)
            DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"started"}"#) }
            DispatchQueue.main.async { cancelFallback() }
            // 会话成功建立 = 手机状态已恢复：清掉自愈节流戳，下一次异常可以立即自愈。
            let stamp = HomePlayState.directory.appendingPathComponent("selfheal.stamp")
            try? FileManager.default.removeItem(at: stamp)
            note("会话开始，等画面")
        }
        s.onEnded = { why in
            live = false
            DispatchQueue.main.async { cancelFallback() }
            note("会话结束：\(why)")
            DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"ended"}"#) }
        }
        // F1 在场信号（本机回环）：手机 pair-verify 通过与否，翻转到才广播。
        // WindowShade（同一用户）订阅这条来做「离开就锁」的身份证据；内容只有布尔和会话代次。
        var phoneVerified = false
        var presenceGeneration = 0
        func broadcastPhonePresence() {
            let now = s.phoneAuthenticated
            guard now != phoneVerified else { return }
            phoneVerified = now
            presenceGeneration += 1
            let payload: [String: Any] = ["type": "phone-presence",
                                          "verified": now,
                                          "generation": presenceGeneration]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { server.broadcastText(text) }
            note("手机验证状态：\(now ? "已通过 pair-verify" : "未验证")")
        }
        let presenceTimer = DispatchSource.makeTimerSource(queue: .main)
        presenceTimer.schedule(deadline: .now() + 1, repeating: 1.0)
        presenceTimer.setEventHandler { broadcastPhonePresence() }
        presenceTimer.resume()
        s.onControlConnected = { host in
            if Self.isSelfAddress(host, iface: o.iface) {
                note("控制连接来自本机（\(host)），忽略，不影响 0x4301 重试")
                return
            }
            DispatchQueue.main.async {
                controlSeen = true
                cancelFallback()
                wifiWaitItem?.cancel(); wifiWaitItem = nil
            }
            note("手机连入控制口 \(host)：取消 0x4301 重试")
        }
        do { try s.start() } catch {
            if isAddressInUse(error) {
                // 登录瞬间桌宠与 launchd 可能同时拉起接收器：端口被占时优雅退出，
                // 避免 KeepAlive 每 10 秒重启一次（2026-10-20 重启实测的 spawm 循环）。
                note("控制口 \(o.controlPort) 已被另一个接收器实例占用：本实例退出（不重启）")
                exit(0)
            }
            note("控制口 \(o.controlPort) 起不来：\(error)"); exit(1)
        }
        session = s; sink = h264

        var usePhoneHandler: ((String) -> Void)?
        var pairNewHandler: (() -> Void)?
        var forgetPhoneHandler: ((String) -> Void)?
        var restorePhonesHandler: (() -> Void)?
        server.onConnect = { conn in
            server.sendText(Wire.helloJSON(name: "CarPlay (无线)", width: o.width, height: o.height), to: conn)
            if let m = Wireless.lastCornerMask { server.sendText(m, to: conn) }
            if let info = Wireless.wifiInfoPayload(ssid: ssid) { server.sendText(info, to: conn) }
            if let cfg = h264.lastConfig { server.sendBinary(cfg, to: conn) }
            if let json = Wireless.cachedNowPlaying() { server.sendText(json, to: conn) }
            if let art = Wireless.cachedArtwork() { server.sendText(art, to: conn) }
            for text in Wireless.cachedTelephony() { server.sendText(text, to: conn) }
            if let phones = Wireless.cachedPhones() { server.sendText(phones, to: conn) }
            s.requestKeyframe()
        }
        server.onText = { text in
            if text.contains("\"type\":\"stop\"") {
                note("收到斷開指令，結束 CarPlay 會話")
                Wireless.shutdown()
                DispatchQueue.main.asyncAfter(deadline: .now() + Wireless.exitGrace) { exit(0) }
                return
            }
            if text.contains("\"type\":\"usePhone\"") {
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let address = obj["address"] as? String, !address.isEmpty {
                    usePhoneHandler?(address)
                }
                return
            }
            if text.contains("\"type\":\"setWiFi\"") {
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let value = obj["ssid"] as? String, !value.isEmpty { ssid = value }
                    if let value = obj["passphrase"] as? String { passphrase = value }
                    securityProfile = resolveWiFiSecurity(ssid: ssid, iface: o.iface,
                                                         explicit: o.securityExplicit, current: o.security)
                    note("Wi-Fi 设置已更新（SSID/密码不打印；0x4301 security=\(Wireless.securityLabel(securityProfile))）")
                    pushWiFiConfiguration()
                }
                return
            }
            if text.contains("\"type\":\"setPassphrase\"") {
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = obj["value"] as? String {
                    passphrase = value
                    note("Wi-Fi 密码已更新（不打印）")
                    pushWiFiConfiguration()
                }
                return
            }
            if text.contains("\"type\":\"pairNewPhone\"") {
                pairNewHandler?()
                return
            }
            if text.contains("\"type\":\"forgetPhone\"") {
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let address = obj["address"] as? String, !address.isEmpty {
                    forgetPhoneHandler?(address)
                }
                return
            }
            if text.contains("\"type\":\"restorePhones\"") {
                restorePhonesHandler?()
                return
            }
            if text.contains("\"keyframe\"") { s.requestKeyframe() }
            if let t = Touch.parse(text) { s.sendTouch(x: t.x, y: t.y, down: t.down) }
            if let b = mediaButton(text) { s.sendMedia(b) }
            phoneControl(text, session: s)
            carVideoFromPet(text, session: s)
            applySeek(text)
        }

        // 4 蓝牙 iAP2：认证后回 Wi-Fi 配置（0x5702 → 0x5703）、开会话（0x4300 → 0x4301）。
        // 车机式生命週期：断开/超时 → 退避重连（5/10/20/30/60 之后保持 60；认证成功过则归零）；
        // 会话 live 期间蓝牙重连降为 60s 慢速（蓝牙断线不影响画面，只为下一次会话）；
        // 手机不在（locate 失败 / SDP 没服务）→ 60s 重查，receiver 永不因手机缺席退出。
        // 地址没给就自动匹配；找到后记住这台（重试优先直连），并回填给 CtrlProbe 只探它。
        var backoff = BackoffSchedule(ladder: [5, 10, 20, 30, 60], slow: 60)
        var retryItem: DispatchWorkItem?
        var preferredAddress = o.phoneAddress
        // 用户明确选过/配置过手机后，不能被别的已配对手机悄悄顶替；失败就重试这一台。
        var phoneLocked = o.phoneAddress != nil
        var beacon: BluetoothBeacon?
        var startBeaconIfNeeded: (() -> Void)?
        var handleBeaconIncoming: ((IOBluetoothDevice, IOBluetoothRFCOMMChannel) -> Void)?

        func locatePhone() -> Result<(IOBluetoothDevice, BluetoothRFCOMMChannelID, String), Iap2BluetoothAccessory.LocateError> {
            if let pref = preferredAddress {
                switch Iap2BluetoothAccessory.locate(address: pref) {
                case .success(let found): return .success((found.0, found.1, pref))
                case .failure(let e):
                    if phoneLocked { return .failure(e) }
                    preferredAddress = nil   // 自动匹配到的那台不在了，转自动
                }
            }
            switch Iap2BluetoothAccessory.locateAuto() {
            case .success(let device, let channel, let address): return .success((device, channel, address))
            case .failure(let e): return .failure(e)
            }
        }

        func scheduleBluetoothRetry(after delay: TimeInterval, because reason: String) {
            retryItem?.cancel()
            note("蓝牙 \(Int(delay))s 后重试（\(reason)）")
            let item = DispatchWorkItem { startBluetooth() }
            retryItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        /// incoming：iPhone 主动连进我们发布的 iAP2/CarPlay 服务（MacPlay 式）；否则扫已配对设备主动连。
        func startBluetooth(adopting incoming: (device: IOBluetoothDevice, channel: IOBluetoothRFCOMMChannel)? = nil) {
            guard accessory == nil else {
                incoming?.channel.close()
                return
            }

            let device: IOBluetoothDevice
            let channelID: BluetoothRFCOMMChannelID?
            let address: String
            if let incoming {
                guard let raw = incoming.device.addressString else {
                    incoming.channel.close()
                    return
                }
                let normalized = PairingRules.normalize(raw)
                guard PairingRules.acceptsIncoming(address: normalized,
                                                   pairedPhones: Iap2BluetoothAccessory.pairedPhones(),
                                                   preferred: preferredAddress,
                                                   pairingGuide: false) else {
                    note("忽略未配对或非当前 iPhone 的主动连接（\(normalized)）")
                    incoming.channel.close()
                    return
                }
                device = incoming.device
                channelID = nil
                address = normalized
                preferredAddress = address
                phoneLocked = true
                s.setPhoneBluetoothAddress(address)
                note("iPhone 主动连入：\(device.name ?? "?")（\(address)）")
            } else {
                switch locatePhone() {
                case .failure(let e):
                    switch e {
                    case .noService, .noChannel:
                        // SDP 缓存里没有 iAP2 服务：刷新一次候选设备的服务记录再重查（照 MacPlay 的做法）
                        note("\(e.description)；刷新 SDP 后重试")
                        if let candidate = preferredAddress ?? Iap2BluetoothAccessory.pairedDevices().first?.address {
                            SDPRefresh.refresh(address: candidate) {
                                scheduleBluetoothRetry(after: backoff.next(live: live), because: "SDP 已刷新")
                            }
                        } else {
                            scheduleBluetoothRetry(after: 60, because: "没有可刷新的候选设备")
                        }
                    default:
                        note("\(e.description)——视为手机不在，60s 后重查")
                        scheduleBluetoothRetry(after: 60, because: "手机不在")
                    }
                    return
                case .success(let located):
                    device = located.0
                    channelID = located.1
                    address = PairingRules.normalize(located.2)
                }
            }

            if PairingRules.normalize(preferredAddress ?? "") != address {
                note("当前 iPhone：\(address)")
                preferredAddress = address
            }
            if Wireless.cachedPairingHint() != nil {
                Wireless.setPairingHint(nil)
                server.broadcastText(#"{"type":"pairingDone"}"#)
            }
            publishPhones()
            s.setPhoneBluetoothAddress(address)
            startBeaconIfNeeded?()
            // 识别信息里的无线 CarPlay 传输组件必须报真实 SSID（MacPlay/DiPlay 同款）；
            // 报默认串会让手机在「新配件」评估时对不上它所在的网络，从而不发 0x4300。
            var coreInfo = Iap2AccessoryCore.Info()
            coreInfo.ssid = ssid
            let acc = Iap2BluetoothAccessory(identity: identity, info: coreInfo, stopAfterAuth: false)
            sawAvailability = false
            acc.onLog = { note("iAP2 " + $0) }
            acc.onPhase = { phase in
                    if phase == .authenticated {
                        backoff.reset()
                        Wireless.persistPhone(address)
                        if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                    }
                }
            acc.onFinished = { code in
                accessory = nil
                sawAvailability = false
                wifiWaitItem?.cancel(); wifiWaitItem = nil
                clearNowPlaying(server: server)
                DispatchQueue.main.async { cancelFallback() }
                note("蓝牙 iAP2 结束（\(code)）。会话已建立的话画面不受影响。")
                let slow = live
                scheduleBluetoothRetry(after: backoff.next(live: slow), because: slow ? "会话进行中，慢速保活" : "退避重连")
            }
            acc.onMessage = { frame in
            acc.onArtwork = { id, data in publishArtwork(id: id, data: data, server: server) }
                switch frame.messageId {
                case Iap2Csm.CarPlay.wifiConfigRequest:
                    note("iPhone 要 Wi-Fi 配置 → 回 \(ssid)（\(Self.securityLabel(currentSecurity()))，密码不打印）")
                    return [Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase, security: currentSecurity(), channel: currentChannel())]
                case 0x4E0E:
                    // DiPlay 同款：手机报完传输标识后重发一次 Wi-Fi 配置，确保它拿着凭据去连网
                    // （只发一次，避免重复包；0x4E0E 也可能在别处出现）。
                    note("iPhone 报传输标识（0x4E0E）→ 补发 Wi-Fi 配置（\(Self.securityLabel(currentSecurity()))）")
                    return [Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase, security: currentSecurity(), channel: currentChannel())]
                case 0x4E0D:
                    // 手机说无线 CarPlay 可用，却迟迟不发 0x4300：最常见是它没加入 Wi-Fi（密码不对），
                    // 或 iPhone 里残留旧的 CarPlay 记录让 carkitd 卡住（真机 2026-10-19 验证的修法）。
                    let available = frame.parameters.first(where: { $0.id == 0 })?.payload.first == 1
                    if available, !live, wifiWaitItem == nil {
                        let item = DispatchWorkItem {
                            guard !live, !sawAvailability else { return }
                            wifiWaitItem = nil
                            let name = ssid.isEmpty ? "当前 Wi-Fi" : ssid
                            note("手机报了 CarPlay 可用，但 15 秒没开始交接：确认 iPhone 已连「\(name)」；若已连仍无反应，在 iPhone 设置 › 通用 › CarPlay 删除这台 Mac、蓝牙里忽略后重新配对（旧 CarPlay 记录会让 carkitd 卡住）")
                            if let help = Wireless.wifiHelpPayload(ssid: name, passphraseMissing: passphrase.isEmpty) { server.broadcastText(help) }
                            // 25 秒仍没有 0x4300：自动重连一次 iAP2（真机上「关开蓝牙」的恢复动作），
                            // 让手机重新走一遍 carkitd 会话；5 分钟内最多一次，避免来回折腾。
                            let nudge = DispatchWorkItem {
                                guard !live, !sawAvailability,
                                      Date().timeIntervalSince(lastNudgeAt) > 300 else { return }
                                lastNudgeAt = Date()
                                note("25 秒仍没等到 0x4300：重连一次 iAP2（自动恢复卡住的 carkitd 会话）")
                                backoff.reset()
                                Wireless.accessory?.core.finish(12)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: nudge)
                        }
                        wifiWaitItem = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
                    }
                    return []
                case Iap2Csm.CarPlay.availability:
                    wifiWaitItem?.cancel(); wifiWaitItem = nil
                    if live { note("会话进行中，忽略重复的 CarPlay 可用通知"); return [] }
                    sawAvailability = true
                    let availability = Iap2Csm.carPlayAvailability(frame)
                    let liveIP = currentIP() ?? ip
                    note("iPhone 报 CarPlay 可用（\(availability?.summary ?? "无线 \(Iap2Csm.wirelessCarPlayAvailable(frame).map { "\($0)" } ?? "?")")）→ 开会话 \(liveIP):\(o.controlPort)")
                    scheduleHandoffRetries()
                    let ssidName = ssid.isEmpty ? "当前 Wi-Fi" : ssid
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        guard !live, !controlSeen else { return }
                        note("iPhone 未连回控制口：确认 iPhone 与 Mac 在同一个 Wi-Fi（\(ssidName)）；若仍不行，右键 → Wi-Fi 设置 里核对 SSID 与密码（系统设置 › Wi-Fi › 详细信息可查看密码）")
                        if let help = Wireless.wifiHelpPayload(ssid: ssidName, passphraseMissing: passphrase.isEmpty) { server.broadcastText(help) }
                    }
                    return [startMessage([ip])]
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
            if let channelID {
                if acc.start(device: device, channelID: channelID) {
                    accessory = acc
                } else {
                    scheduleBluetoothRetry(after: backoff.next(live: live), because: "RFCOMM 打开失败")
                }
            } else if let incoming {
                if acc.adopt(channel: incoming.channel) {
                    accessory = acc
                } else {
                    incoming.channel.close()
                }
            }
        }

        func publishPhones(force: Bool = false) {
            guard let text = Wireless.phonesPayload(current: preferredAddress) else { return }
            guard force || Wireless.cachedPhones() != text else { return }
            Wireless.setPhones(text)
            server.broadcastText(text)
        }

        func selectPhone(_ raw: String) {
            let address = PairingRules.normalize(raw)
            guard let phone = Iap2BluetoothAccessory.pairedPhones()
                .first(where: { PairingRules.normalize($0.address) == address }) else {
                note("切换手机：\(address) 不在已配对列表")
                publishPhones(force: true)
                return
            }
            if let current = preferredAddress, PairingRules.normalize(current) == address,
               accessory != nil || live {
                publishPhones(force: true)
                return
            }
            retryItem?.cancel(); retryItem = nil
            backoff.reset()
            let old = accessory
            accessory = nil
            old?.onFinished = nil
            old?.close()
            preferredAddress = phone.address
            phoneLocked = true
            Wireless.persistPhone(phone.address)
            s.setPhoneBluetoothAddress(phone.address)
            clearNowPlaying(server: server)
            publishPhones(force: true)
            note("切换手机 → \(phone.name)（\(phone.address)）")
            s.switchPhone(to: phone.address) { DispatchQueue.main.async { startBluetooth() } }
        }

        func refreshPhoneListLoop() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                publishPhones()
                refreshPhoneListLoop()
            }
        }
        func forgetPhone(_ raw: String) {
            let address = PairingRules.normalize(raw)
            var ignored = Iap2BluetoothAccessory.ignoredAddresses
            ignored.insert(address)
            Iap2BluetoothAccessory.ignoredAddresses = ignored
            _ = Iap2BluetoothAccessory.unpair(address: address)
            note("已忘记 iPhone \(address)；系统配对若仍在，可在 iPhone 蓝牙设置里忘记")
            if let current = preferredAddress, PairingRules.normalize(current) == address {
                let old = accessory
                accessory = nil
                old?.onFinished = nil
                old?.close()
                retryItem?.cancel(); retryItem = nil
                preferredAddress = nil
                s.switchPhone(to: "") { DispatchQueue.main.async { startBluetooth() } }
                clearNowPlaying(server: server)
            }
            publishPhones(force: true)
            if Iap2BluetoothAccessory.pairedPhones().isEmpty {
                note("所有 iPhone 都已忘记；请在 iPhone 蓝牙设置里重新配对一台")
                if let hint = Wireless.pairingHintPayload(host: Iap2BluetoothAccessory.localBluetoothName,
                                                      stale: !Iap2BluetoothAccessory.ignoredAddresses.isEmpty) {
                    Wireless.setPairingHint(hint); server.broadcastText(hint)
                }
                BluetoothSettingsPane.open()
            }
        }
        func restorePhones() {
            Iap2BluetoothAccessory.ignoredAddresses = []
            publishPhones(force: true)
            note("已恢复所有被忘记的 iPhone")
            startBluetooth()
        }
        usePhoneHandler = { selectPhone($0) }
        forgetPhoneHandler = { forgetPhone($0) }
        restorePhonesHandler = { restorePhones() }
        pairNewHandler = {
            if let hint = Wireless.pairingHintPayload(host: Iap2BluetoothAccessory.localBluetoothName,
                                                      stale: !Iap2BluetoothAccessory.ignoredAddresses.isEmpty) {
                Wireless.setPairingHint(hint)
                server.broadcastText(hint)
            }
            BluetoothSettingsPane.open()
            note("请在 iPhone 蓝牙设置里配对新的 iPhone；配对后从右键「使用 iPhone」选它")
        }
        server.start()
        publishPhones(force: true)
        refreshPhoneListLoop()
        handleBeaconIncoming = { device, channel in
            DispatchQueue.main.async { startBluetooth(adopting: (device, channel)) }
        }
        startBeaconIfNeeded = {
            guard beacon == nil else { return }
            if o.background, server.clientCount == 0 { return }   // 后台没人看时不广播
            let b = BluetoothBeacon(advertiseClass: true, log: { note("蓝牙广播：" + $0) })
            b.onIncoming = { device, channel in handleBeaconIncoming?(device, channel) }
            beacon = b
            Wireless.beacon = b
        }
        // 车机类 + iAP2/CarPlay SDP 必须在配对前就广播：iPhone 在配对时做 SDP 发现，
        // 那一刻看不到 CarPlay 服务，就只会把 Mac 当普通电脑，之后也不再提示 CarPlay。
        // （MacPlay 的蓝牙桥就是启动即发布；这里不再等"配对成功后"才发。）
        startBeaconIfNeeded?()
        if o.background {
            // 登录项常驻：桌宠（唯一的 WS 客户端）不在时，不该继续把自己广播成一台 CarPlay 车机，
            // 否则附近的 iPhone 会反复发起蓝牙配对。15 秒宽限后撤掉广播；再 2 分钟没人用就退出。
            // KeepAlive 只拉起异常退出，这里用 exit(0)，launchd 不会重启。
            var idleSince: TimeInterval?
            var idleExitScheduled = false
            let watch = Timer(timeInterval: 5, repeats: true) { _ in
                if server.clientCount > 0 {
                    idleSince = nil
                    if beacon == nil {   // 桌宠回来了：恢复广播
                        startBeaconIfNeeded?()
                        note("桌宠已连接：恢复蓝牙广播")
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
        startBluetooth()
        note("等 iPhone：蓝牙认证 → Wi-Fi 交接 → 回连控制口（断了自动重连）")
        RunLoop.main.run()
        exit(0)
    }
}
