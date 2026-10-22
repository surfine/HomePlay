// 无线 CarPlay 来源：蓝牙 iAP2（识别 + MFi 认证）→ 交 Wi-Fi 配置、叫手机开会话 →
// 手机经局域网连回我们的控制口（CarPlaySession）→ 屏幕流解密 → H264Sink → 同一套 wire 推给桌宠／App。
// 桌宠的触控变成会话里的 HID 报告（不碰真游标），keyframe 请求变成 forceKeyFrame。
// 流程照 MacPlay（bringup.rs、cpStack.ts）；行为照 Apple 车机模型：断了自动重连、手机不在定时重查，
// 全程无需用户干预。身份用仓库自带的 identity/（可 --identity-dir 覆盖）；不打印身份内容。
import AppKit
import Foundation
import QuartzCore
import Network
import CoreWLAN
import IOBluetooth
import IAP2
import Session
import H264
import Wire

enum Wireless {
    /// 日誌行會從多條佇列冒出來（USB/藍牙/會話），格式化器只建一次。
    private static let noteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static func note(_ s: String) {
        FileHandle.standardError.write(("[\(noteFormatter.string(from: Date()))] 无线：" + s + "\n").data(using: .utf8)!)
    }

    /// 日志用的安全类型名（不含任何凭据）
    static func securityLabel(_ s: Iap2Csm.WiFiSecurity) -> String {
        switch s {
        case .none: return "开放"
        case .wep: return "WEP"
        case .wpaWpa2: return "WPA/WPA2"
        case .wpa3Transition: return "WPA2/WPA3 过渡"
        case .wpa3Only: return "WPA3-only"
        }
    }

    /// 本机自己连控制口（端口自检/健康探测）不能当成手机回连：否则 0x4301 重试会被误停，
    /// 手机真正入网后反而等不到 0x4301（2026-10-20 实测：nc -z 触发过这个误判）。
    static func isSelfAddress(_ host: String, iface: String) -> Bool {
        if host == "127.0.0.1" || host == "::1" || host == "localhost" { return true }
        if let mine = NetInfo.ipv4(iface), host == mine { return true }
        if let ll = NetInfo.linkLocalIPv6(iface), host == ll { return true }
        return false
    }

    struct Options {
        var identityDir: String
        /// nil＝自动匹配：扫已配对设备的 iAP2 服务（iPhone 签名），连谁回填谁
        var phoneAddress: String?
        var ssid: String
        var passphrase: String
        var channel: UInt8?
        var security: Iap2Csm.WiFiSecurity = .wpaWpa2
        /// 用户显式指定了 --security：发送时不再被自动探测覆盖（真 WPA3-only 网络要发 4）
        var securityExplicit = false
        var iface = "en0"
        var controlPort: UInt16 = 17000
        // 真机分辨率：1088×1088 @220ppi（apple-homeview/specs）。
        // HOMEPLAY_DISPLAY_W/H 可覆盖（含比例实验，如 900×1200 直屏）——接收器由桌寵拉起，環境變量會傳下去
        var width = ProcessInfo.processInfo.environment["HOMEPLAY_DISPLAY_W"].flatMap { Int($0) } ?? 1088
        var height = ProcessInfo.processInfo.environment["HOMEPLAY_DISPLAY_H"].flatMap { Int($0) } ?? 1088
        /// iAP 数据通道（流 130）：默认声明并在双模里接核心；HOMEPLAY_IAP_CHANNEL=0 关
        var advertiseIAPChannel = true
    }

    // 运行期对象全局持有
    nonisolated(unsafe) static var session: CarPlaySession?
    nonisolated(unsafe) static var accessory: Iap2BluetoothAccessory?
    nonisolated(unsafe) static var accessoryUsb: Iap2UsbAccessory?
    /// 流 130 隧道上的 iAP2 配件（Wi-Fi 会话里、disableBluetooth 之后手机走的那条）
    nonisolated(unsafe) static var accessoryTunnel: Iap2TunnelAccessory?
    nonisolated(unsafe) static var beacon: BluetoothBeacon?
    nonisolated(unsafe) static var sink: H264Sink?
    nonisolated(unsafe) static var live = false
    nonisolated(unsafe) static var phoneNowPlaying = Iap2Csm.PhoneNowPlaying()
    nonisolated(unsafe) private static var nowPlayingJSON: String?
    nonisolated(unsafe) private static var artworkJSON: String?
    nonisolated(unsafe) private static var nowPlayingSeek: ((UInt32) -> Void)?
    nonisolated(unsafe) private static let nowPlayingLock = NSLock()
    nonisolated(unsafe) private static var pairingHintJSON: String?
    nonisolated(unsafe) private static let pairingHintLock = NSLock()
    nonisolated(unsafe) private static var cableHintJSON: String?
    nonisolated(unsafe) private static let cableHintLock = NSLock()
    nonisolated(unsafe) private static var trustHintJSON: String?
    nonisolated(unsafe) private static let trustHintLock = NSLock()
    nonisolated(unsafe) private static var handoffHintJSON: String?
    nonisolated(unsafe) private static let handoffHintLock = NSLock()
    nonisolated(unsafe) private static var phonesJSON: String?
    nonisolated(unsafe) private static let phonesLock = NSLock()

    static func cachedPairingHint() -> String? {
        pairingHintLock.lock(); defer { pairingHintLock.unlock() }
        return pairingHintJSON
    }
    static func setPairingHint(_ text: String?) {
        pairingHintLock.lock(); pairingHintJSON = text; pairingHintLock.unlock()
    }
    static func cachedCableHint() -> String? {
        cableHintLock.lock(); defer { cableHintLock.unlock() }
        return cableHintJSON
    }
    static func setCableHint(_ text: String?) {
        cableHintLock.lock(); cableHintJSON = text; cableHintLock.unlock()
    }
    static func cachedTrustHint() -> String? {
        trustHintLock.lock(); defer { trustHintLock.unlock() }
        return trustHintJSON
    }
    static func setTrustHint(_ text: String?) {
        trustHintLock.lock(); trustHintJSON = text; trustHintLock.unlock()
    }
    static func cachedHandoffHint() -> String? {
        handoffHintLock.lock(); defer { handoffHintLock.unlock() }
        return handoffHintJSON
    }
    static func setHandoffHint(_ text: String?) {
        handoffHintLock.lock(); handoffHintJSON = text; handoffHintLock.unlock()
    }
    static func cachedPhones() -> String? {
        phonesLock.lock(); defer { phonesLock.unlock() }
        return phonesJSON
    }
    static func setPhones(_ text: String?) {
        phonesLock.lock(); phonesJSON = text; phonesLock.unlock()
    }

    /// 给桌宠的已配对手机清单（current 为当前选择，空串＝自动）。
    static func phonesPayload(current: String?) -> String? {
        let phones = Iap2BluetoothAccessory.pairedPhones()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let payload: [String: Any] = [
            "type": "phones",
            "current": current.map(PairingRules.normalize) ?? "",
            "items": phones.map { ["address": $0.address, "name": $0.name] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func currentPhonePayload(address: String) -> String? {
        let payload: [String: Any] = ["type": "currentPhone", "address": address]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func wifiHelpPayload(ssid: String) -> String? {
        let payload: [String: Any] = ["type": "wifiHelp", "ssid": ssid]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 没回连时给桌宠的 Wi-Fi 排障提示。passphraseMissing＝本地没存密码（大概率就是它连不上）：
    /// 桌宠直接弹一次 Wi-Fi 密码框，而不是让用户自己去翻「右键 → Wi-Fi 设置」。
    static func wifiHelpPayload(ssid: String, passphraseMissing: Bool) -> String? {
        var payload: [String: Any] = ["type": "wifiHelp", "ssid": ssid]
        if passphraseMissing { payload["passphraseMissing"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func wifiInfoPayload(ssid: String) -> String? {
        let payload: [String: Any] = ["type": "wifiInfo", "ssid": ssid]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func pairingHintPayload(host: String, stale: Bool = false) -> String? {
        let payload: [String: Any] = ["type": "needPairing", "host": host, "stale": stale]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// USB 插着但 carkit 打不开（未点「信任」/信任过期）：桌宠据此显示「解锁并点信任」卡片。
    /// 用户在 iPhone 上点完信任后 usbWatch 会自动重试（1 秒轮询），卡自动消失。
    static func usbTrustHintPayload() -> String? {
        let payload: [String: Any] = ["type": "needTrust"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 首次配对的第一张卡：优先请用户插一根数据线。20 秒没插再自动改走蓝牙设置。
    /// CarPlay 主画面上那颗「车厂 App」图标：换成 HomePlay 的图标和名字。手机点它会送 `requestUI`，
    /// 我们让桌宠回到自己的表面（见 runDual 的 onCommand）——和「重按进入 CarPlay」形成闭环。
    /// 图标是满版方图（CarPlay 自己套圆角），放在接收器执行档旁边（make-app.sh 拷进 Contents/Resources）；
    /// 开发版找不到就不宣告，手机照旧显示空白图标。
    static func applyHomeIcon(_ info: inout InfoConfig) {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let icons: [OEMIcon] = [120, 180, 256].compactMap { s in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("CarPlayIcon-\(s).png")) else { return nil }
            return OEMIcon(widthPixels: s, heightPixels: s, data: data)
        }
        guard !icons.isEmpty else { return }
        info.icons = icons
        info.oemLabel = "HomePlay"
    }

    /// 手机上点了 HomePlay 图标（requestUI）：叫桌宠回到表面，CarPlay 留在后台
    static func requestUIPayload() -> String? {
        let payload: [String: Any] = ["type": "requestUI"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func needCablePayload() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "needCable"]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 有线会话里已发起 IOBluetoothDevicePair：iPhone 上会弹一次「配对」。
    static func bluetoothPairingPayload() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "bluetoothPairing"]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func bluetoothPairFailedPayload() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "bluetoothPairFailed"]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 有线→无线的静默切换：桌宠据此冻结最后一帧 / 恢复 / 回退。
    static func handoffPayload(_ state: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "handoff", "state": state]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 有线会话学到手机蓝牙地址后立刻落盘：接收器/桌宠重启也不会丢，拔线即无线。
    /// 只改 phone 字段，保留 SSID/密码/端口等全部已有内容；文件不存在时不替用户创建。
    private static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay/wireless.json")
    }

    /// 用户把之前「忘记」的 iPhone 重新插上线＝明确要用它：移出应用层忽略列表。
    /// 不删除系统蓝牙配对，只让 HomePlay 重新尝试它。
    static func unignorePhone(_ address: String) {
        let normalized = PairingRules.normalize(address)
        var ignored = Iap2BluetoothAccessory.ignoredAddresses
        if ignored.contains(normalized) {
            ignored.remove(normalized)
            Iap2BluetoothAccessory.ignoredAddresses = ignored
            note("USB 连上了之前忘记的 iPhone：已恢复使用")
        }
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["ignoredPhones"] as? [String] else { return }
        let kept = list.filter { PairingRules.normalize($0) != normalized }
        guard kept.count != list.count else { return }
        obj["ignoredPhones"] = kept
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            note("恢复 iPhone 的 ignoredPhones 失败：\(error.localizedDescription)")
        }
    }

    /// USB 序号 → 手机蓝牙地址（有线会话 0x4E0E 学到的）。有了它，已配对的手机再插线时
    /// 不用先开 carkit 识别就知道「这台走蓝牙/Wi-Fi 就好」。文件 0600，只存地址。
    private static var usbPhoneMapURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay/usb-phones.json")
    }
    static func usbPhoneAddress(serial: String) -> String? {
        guard let data = try? Data(contentsOf: usbPhoneMapURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return obj[serial]
    }
    static func rememberUSBPhone(serial: String, address: String) {
        let normalized = PairingRules.normalize(address)
        var obj: [String: String] = [:]
        if let data = try? Data(contentsOf: usbPhoneMapURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String] { obj = saved }
        if obj[serial] == normalized { return }
        obj[serial] = normalized
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: usbPhoneMapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: usbPhoneMapURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: usbPhoneMapURL.path)
        note("已记住这条数据线上的手机（序号 \(String(serial.prefix(8)))… → 蓝牙地址）：下次插线只充电")
    }

    /// 这台是不是以前连过的手机（wireless.json 记住的那台，或 usb-phones.json 对应过的）。
    /// 刚启动／刚重签名时 IOBluetoothDevice.pairedDevices() 可能暂时是空的（真机样本 2026-10-22 17:26：
    /// 19 次启动里 1 次），不能凭那一次空清单就当成首次配对、结束 USB、开配对引导。
    static func isKnownPhone(_ address: String) -> Bool {
        let normalized = PairingRules.normalize(address)
        guard !Iap2BluetoothAccessory.isIgnored(normalized) else { return false }
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let saved = obj["phone"] as? String, PairingRules.normalize(saved) == normalized { return true }
        if let data = try? Data(contentsOf: usbPhoneMapURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           obj.values.contains(where: { PairingRules.normalize($0) == normalized }) { return true }
        return false
    }

    static func persistPhone(_ address: String) {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let normalized = PairingRules.normalize(address)
        if let saved = obj["phone"] as? String, PairingRules.normalize(saved) == normalized { return }
        obj["phone"] = normalized
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            note("已把这台 iPhone 记到 wireless.json（拔线后自动无线）")
        } catch {
            note("记 iPhone 到 wireless.json 失败：\(error.localizedDescription)")
        }
    }

    static func cachedNowPlaying() -> String? {
        nowPlayingLock.lock(); defer { nowPlayingLock.unlock() }
        return nowPlayingJSON
    }
    static func cachedArtwork() -> String? {
        nowPlayingLock.lock(); defer { nowPlayingLock.unlock() }
        return artworkJSON
    }

    /// 手机 0x5001 增量合并后推给桌宠（桌宠再发到系统 Now Playing/Control Center）。
    /// seek 闭包属于这一路 iAP2 配件；手机换曲/断线后由下一条更新或 clear 替换。
    static func publishNowPlaying(_ frame: Iap2Csm.Frame, server: WSServer, seek: @escaping (UInt32) -> Void) {
        guard let update = Iap2Csm.phoneNowPlaying(frame) else { return }
        note("NowPlaying 0x5001：\(update.title ?? "-") playing=\(update.playing.map(String.init) ?? "-") elapsed=\(update.elapsedMs.map(String.init) ?? "-")")
        nowPlayingLock.lock()
        phoneNowPlaying.merge(update)
        nowPlayingSeek = seek
        let np = phoneNowPlaying
        nowPlayingLock.unlock()
        var d: [String: Any] = [
            "type": "nowplaying",
            "title": np.title ?? "",
            "artist": np.artist ?? "",
            "album": np.album ?? "",
            "playing": np.playing ?? false,
            "durationMs": np.durationMs ?? 0,
            "elapsedMs": np.elapsedMs ?? 0,
            "canSeek": np.canSeek ?? false,
        ]
        if let id = np.trackId { d["trackId"] = String(id) }
        if let art = np.artworkId { d["artworkId"] = Int(art) }
        if let app = np.appBundleID { d["appId"] = app }
        if let app = np.appName { d["appName"] = app }
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            nowPlayingLock.lock(); nowPlayingJSON = text; nowPlayingLock.unlock()
            server.broadcastText(text)
        }
    }

    static func clearNowPlaying(server: WSServer) {
        nowPlayingLock.lock()
        let had = nowPlayingJSON != nil
        nowPlayingJSON = nil
        artworkJSON = nil
        nowPlayingSeek = nil
        phoneNowPlaying = Iap2Csm.PhoneNowPlaying()
        nowPlayingLock.unlock()
        clearTelephony(server: server)
        guard had else { return }
        server.broadcastText(#"{"type":"nowplaying","clear":true}"#)
    }

    // MARK: 通話與通訊狀態（iAP2 0x4155／0x4158 → 桌寵）

    private static let telephonyLock = NSLock()
    private static var callBook = Iap2Csm.CallBook()
    private static var communications = Iap2Csm.CommunicationsState()
    private static var callJSON: String?
    private static var cellularJSON: String?

    /// 桌寵剛連上時補發：還在響或通話中的電話、電信商與訊號
    static func cachedTelephony() -> [String] {
        telephonyLock.lock(); defer { telephonyLock.unlock() }
        return [callJSON, cellularJSON].compactMap { $0 }
    }

    /// 0x4155 合併進 CallBook 後推 `{"type":"call",...}`；0x4158 推 `{"type":"cellular",...}`。
    /// 0x4155 連原始位元組一起記（離線測試的封包樣本從這裡取）。
    static func publishTelephony(_ frame: Iap2Csm.Frame, server: WSServer) {
        if let update = Iap2Csm.callState(frame) {
            let hex = frame.encoded.map { String(format: "%02x", $0) }.joined()
            note("CallState 0x4155：status=\(update.status.map(String.init) ?? "-") dir=\(update.direction.map(String.init) ?? "-") raw=\(hex)")
            telephonyLock.lock()
            callBook.apply(update)
            let text = callBook.json
            let changed = text != (callJSON ?? Iap2Csm.CallBook().json)
            callJSON = callBook.current == nil ? nil : text
            telephonyLock.unlock()
            if changed { server.broadcastText(text) }
        } else if let update = Iap2Csm.communications(frame) {
            telephonyLock.lock()
            communications.merge(update)
            let text = communications.json
            let changed = text != cellularJSON
            cellularJSON = text
            telephonyLock.unlock()
            if changed, let text {
                note("Communications 0x4158：signal=\(update.signalStrength.map(String.init) ?? "-") carrier=\(update.carrierName ?? "-")")
                server.broadcastText(text)
            }
        }
    }

    /// iAP2 鏈路斷了：通話狀態不再可信，桌寵收起來電卡
    static func clearTelephony(server: WSServer) {
        telephonyLock.lock()
        let had = callJSON != nil
        callBook.reset(); callJSON = nil
        communications = Iap2Csm.CommunicationsState(); cellularJSON = nil
        telephonyLock.unlock()
        if had { server.broadcastText(Iap2Csm.CallBook().json) }
    }

    // MARK: CarPlay 影片（停車時播影片）

    /// 設定檔 Application Support/HomePlay/carplay-video.json（桌寵寫）；沒有檔＝允許
    static func carVideoAllowed() -> Bool {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay/carplay-video.json")
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return true }
        return (o["allowed"] as? Bool) ?? true
    }
    /// 手機要播／暫停／跳轉／停 → 轉給桌寵的播放器
    static func wireCarVideo(_ s: CarPlaySession, server: WSServer) {
        s.onVideo = { op, fields in
            var d = fields; d["type"] = "carVideo"; d["op"] = op
            if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
                server.broadcastText(text)
            }
        }
    }
    /// 桌寵播放器回報：狀態、自己按的播放暫停、播不了、設定開關
    static func carVideoFromPet(_ text: String, session s: CarPlaySession) {
        guard text.contains("\"type\":\"carVideo"), let data = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func num(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
        switch o["type"] as? String {
        case "carVideoState":
            if o["stopped"] as? Bool == true { s.videoUserPlayback(playing: false); s.videoState(.init()); return }
            s.videoState(.init(prepared: o["prepared"] as? Bool ?? false, playing: o["playing"] as? Bool ?? false,
                               position: num("position"), duration: num("duration"), buffered: num("buffered")))
        case "carVideoUser": s.videoUserPlayback(playing: o["playing"] as? Bool ?? false)
        case "carVideoError": s.videoError(code: (o["code"] as? NSNumber)?.intValue ?? -12927)
        case "carVideoAllowed":
            let on = o["allowed"] as? Bool ?? true
            note("CarPlay 影片允許＝\(on)")
            s.setVideoAllowed(on)
        default: break
        }
    }

    /// 桌寵的 Siri 鍵與電話鍵。`{"type":"siri"}` 是按一下；帶 `"action":"down"/"up"` 是按住說話。
    /// `{"type":"telephony","command":"answer"|"decline"|"hangup"}` → 電話 HID（hookSwitch／drop）。
    static func phoneControl(_ text: String, session s: CarPlaySession) {
        if text.contains("\"type\":\"siri\"") {
            let action = SiriAction.parse(text)
            note("触发 Siri（requestSiri \(action)）")
            s.requestSiri(action)
        }
        if let b = HID.telephonyButton(forPetMessage: text) {
            note("桌宠电话键 → HID \(b)")
            s.sendTelephony(b)
        }
    }

    /// {"type":"seek","positionMs":12345,"trackId":"..."}；trackId 不匹配就丢弃，防止旧滑杆跳新歌。
    static func applySeek(_ text: String) {
        guard text.contains("\"type\":\"seek\""), let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = (obj["positionMs"] as? NSNumber)?.uint32Value else { return }
        nowPlayingLock.lock()
        let currentTrack = phoneNowPlaying.trackId.map(String.init)
        let seek = nowPlayingSeek
        nowPlayingLock.unlock()
        if let t = obj["trackId"] as? String, let currentTrack, t != currentTrack { return }
        // iAP2 core 的发送在主线程；WebSocket 回调不在主线程
        if let seek { DispatchQueue.main.async { seek(ms) } }
    }

    /// 专辑封面：文件传输完成后的原始图片字节（JPEG/PNG）。桌宠按 ftid 与当前曲目匹配，迟到旧图不会覆盖新曲。
    static func publishArtwork(id: UInt8, data: Data, server: WSServer) {
        guard data.count <= 4 * 1024 * 1024 else { return }
        let text = #"{"type":"artwork","id":\#(id),"data":"\#(data.base64EncodedString())"}"#
        nowPlayingLock.lock(); artworkJSON = text; nowPlayingLock.unlock()
        server.broadcastText(text)
    }

    static func mediaButton(_ text: String) -> HID.MediaButton? {
        guard text.contains("\"type\":\"media\"") else { return nil }
        if text.contains("\"command\":\"playPause\"") { return .playPause }
        if text.contains("\"command\":\"play\"") { return .play }
        if text.contains("\"command\":\"pause\"") { return .pause }
        if text.contains("\"command\":\"next\"") { return .next }
        if text.contains("\"command\":\"previous\"") { return .prev }
        return nil
    }

    /// 停止/退出时把两条 iAP2 链路干净关掉。手机会收到正常的 RFCOMM/流关闭；
    /// 否则它会以为配件还在会话里，下一次 Bluetooth iAP2 直接"开了就关"。
    /// 这些状态都归主執行緒管，从 WebSocket / 蓝牙回调线程调进来时先派回去再关。
    static func shutdown() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { shutdown() }
            return
        }
        accessory?.close()
        accessory = nil
        accessoryUsb?.close()
        accessoryUsb = nil
        beacon = nil
        session?.stop()
    }

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
        let h264 = H264Sink(server: server)
        var main = DisplayConfig(widthPixels: o.width, heightPixels: o.height,
                                 widthPhysicalMm: 125, heightPhysicalMm: 125, fps: 60)
        // 幾何單一來源（viewArea/safeArea/物理尺寸，環境變量可覆蓋做真機實驗）
        PetDisplay.apply(&main)
        main.primaryInputDevice = 1
        var info = InfoConfig(sourceVersion: "950.7.1", deviceID: store.identity.deviceId,
                              bluetoothMAC: Iap2BluetoothAccessory.localBluetoothAddress, name: "HomePlay",
                              main: main)
        info.model = "HomePlay"; info.manufacturer = "HomePlay"
        Wireless.applyHomeIcon(&info)
        // HEVC 真機驗證通過（v0.3.0）：/info 與會話 SETUP 的 enabledFeatures 必須一致，
        // 否則手機會在 RECORD 後立刻 TEARDOWN。HOMEPLAY_HEVC=0 可回退 H.264。
        info.hevc = ProcessInfo.processInfo.environment["HOMEPLAY_HEVC"] != "0"
        info.videoPlayback = true; info.videoAllowed = Wireless.carVideoAllowed()   // CarPlay 影片（停車時播影片）
        note(PetDisplay.describe(o.width, o.height))
        info.entertainmentSampleRate = 48000   // MacPlay 同款
        // 音频照实宣告（手机要求 /info 完整才会来要屏幕流；MacPlay 同款）。
        // 音频已出声：AAC-LC / PCM 经 CarPlayAudio.swift 解密、解码、排播；Opus 仍只占位。
        info.disableAudioOutput = false
        var cfg = CarPlaySessionConfig(info: info)
        cfg.port = o.controlPort
        cfg.phoneBluetoothAddress = o.phoneAddress
        cfg.advertiseIAPChannel = o.advertiseIAPChannel
        let s = CarPlaySession(config: cfg, store: store, signer: MfiSigner(identity: identity), sink: h264)
        wireCarVideo(s, server: server)
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
            let stamp = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HomePlay/selfheal.stamp")
            try? FileManager.default.removeItem(at: stamp)
            note("会话开始，等画面")
        }
        s.onEnded = { why in
            live = false
            DispatchQueue.main.async { cancelFallback() }
            note("会话结束：\(why)")
            DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"ended"}"#) }
        }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
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
            let b = BluetoothBeacon(advertiseClass: true, log: { note("蓝牙广播：" + $0) })
            b.onIncoming = { device, channel in handleBeaconIncoming?(device, channel) }
            beacon = b
            Wireless.beacon = b
        }
        // 车机类 + iAP2/CarPlay SDP 必须在配对前就广播：iPhone 在配对时做 SDP 发现，
        // 那一刻看不到 CarPlay 服务，就只会把 Mac 当普通电脑，之后也不再提示 CarPlay。
        // （MacPlay 的蓝牙桥就是启动即发布；这里不再等"配对成功后"才发。）
        startBeaconIfNeeded?()
        startBluetooth()
        note("等 iPhone：蓝牙认证 → Wi-Fi 交接 → 回连控制口（断了自动重连）")
        RunLoop.main.run()
        exit(0)
    }

    // MARK: 有线（USB）路径：usbmuxd carkit 流上跑同一套 iAP2 核心；
    // 手机报 0x4300 时回有线版开会话（AV 走它自己的 NCM 网口连回控制口），不需要 Wi-Fi。
    static func runWired(_ o: Options, server: WSServer) -> Never {
        let identity: Iap2MfiIdentity
        do { identity = try Iap2MfiIdentity(directory: o.identityDir) }
        catch { note("身份加载失败：\(error)"); exit(2) }
        note("身份自检通过（证书 \(identity.certificate.count) 字节，内容不打印）")

        let store = PairingStore()
        let h264 = H264Sink(server: server)
        var main = DisplayConfig(widthPixels: o.width, heightPixels: o.height,
                                 widthPhysicalMm: 125, heightPhysicalMm: 125, fps: 60)
        // 幾何單一來源（viewArea/safeArea/物理尺寸，環境變量可覆蓋做真機實驗）
        PetDisplay.apply(&main)
        main.primaryInputDevice = 1
        var info = InfoConfig(sourceVersion: "950.7.1", deviceID: store.identity.deviceId,
                              bluetoothMAC: Iap2BluetoothAccessory.localBluetoothAddress, name: "HomePlay",
                              main: main)
        info.model = "HomePlay"; info.manufacturer = "HomePlay"
        Wireless.applyHomeIcon(&info)
        // HEVC 真機驗證通過（v0.3.0）：/info 與會話 SETUP 的 enabledFeatures 必須一致，
        // 否則手機會在 RECORD 後立刻 TEARDOWN。HOMEPLAY_HEVC=0 可回退 H.264。
        info.hevc = ProcessInfo.processInfo.environment["HOMEPLAY_HEVC"] != "0"
        info.videoPlayback = true; info.videoAllowed = Wireless.carVideoAllowed()   // CarPlay 影片（停車時播影片）
        note(PetDisplay.describe(o.width, o.height))
        info.entertainmentSampleRate = 48000   // MacPlay 同款
        info.disableAudioOutput = false   // 音频已能播（AAC/PCM）；Opus/麦克风仍未接
        var cfg = CarPlaySessionConfig(info: info)
        cfg.port = o.controlPort
        cfg.probeForPhone = false          // 有线不用 _carplay-ctrl 探测，手机直接连回来
        cfg.advertiseIAPChannel = o.advertiseIAPChannel
        let s = CarPlaySession(config: cfg, store: store, signer: MfiSigner(identity: identity), sink: h264)
        wireCarVideo(s, server: server)
        s.onLog = { note($0) }
        s.onActive = { live = true; DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"started"}"#) }; note("会话开始，等画面") }
        s.onEnded = { why in live = false; DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"ended"}"#) }; note("会话结束：\(why)") }
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

        server.onConnect = { conn in
            server.sendText(Wire.helloJSON(name: "CarPlay (有线)", width: o.width, height: o.height), to: conn)
            if let config = h264.lastConfig { server.sendBinary(config, to: conn) }
            if let json = Wireless.cachedNowPlaying() { server.sendText(json, to: conn) }
            if let art = Wireless.cachedArtwork() { server.sendText(art, to: conn) }
            for text in Wireless.cachedTelephony() { server.sendText(text, to: conn) }
            s.requestKeyframe()
        }
        server.onText = { text in
            if text.contains("\"type\":\"stop\"") {
                note("收到斷開指令，結束 CarPlay 會話")
                Wireless.shutdown()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
                return
            }
            if text.contains("\"keyframe\"") { s.requestKeyframe() }
            if let t = Touch.parse(text) { s.sendTouch(x: t.x, y: t.y, down: t.down) }
            if let b = mediaButton(text) { s.sendMedia(b) }
            phoneControl(text, session: s)
            carVideoFromPet(text, session: s)
            applySeek(text)
        }
        server.start()

        var backoff = BackoffSchedule(ladder: [5, 10, 20, 30, 60], slow: 60)
        var retryItem: DispatchWorkItem?
        func scheduleUsbRetry(after delay: TimeInterval, because reason: String) {
            retryItem?.cancel()
            note("USB \(Int(delay))s 后重试（\(reason)）")
            let item = DispatchWorkItem { usbSupervise() }
            retryItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        func usbSupervise() {
            guard let device = (try? Usbmuxd.listDevices())?.first else {
                scheduleUsbRetry(after: 3, because: "没插 USB 设备")
                return
            }
            let tag = String(device.serial.prefix(8))
            note("USB 设备 \(tag)：开 carkit")
            let acc: Iap2UsbAccessory
            do {
                acc = try Iap2UsbAccessory(device: device, identity: identity, stopAfterAuth: false) { note("USB " + $0) }
            } catch {
                note("carkit 打不开（\(error)）——确认 iPhone 已解锁、点「信任」，且数据线能传数据")
                if let hint = Wireless.usbTrustHintPayload() { server.broadcastText(hint) }   // 桌宠显示「点信任」卡片
                scheduleUsbRetry(after: backoff.next(live: live), because: "carkit 失败")
                return
            }
            server.broadcastText(#"{"type":"trustDone"}"#)   // 打开了：之前若亮着「点信任」卡片，收起
            accessoryUsb = acc
            acc.onLog = { note("USB " + $0) }
            acc.onPhase = { if $0 == .authenticated { backoff.reset() } }
            acc.onFinished = { code in
                accessoryUsb = nil
                clearNowPlaying(server: server)
                note("USB iAP2 结束（\(code)）")
                scheduleUsbRetry(after: backoff.next(live: live), because: live ? "会话进行中，慢速" : "退避重连")
            }
            acc.onMessage = { frame in
            acc.onArtwork = { id, data in publishArtwork(id: id, data: data, server: server) }
                switch frame.messageId {
                case Iap2Csm.CarPlay.availability:
                    if live { note("会话进行中，忽略重复的 CarPlay 可用通知"); return [] }
                    // 有线：AV 走手机自己的 NCM 网口（macOS 自己绑的 enX），没就绪就先不回（手机会再问）
                    guard let iface = UsbNet.ncmInterfaces(udid: device.serial).first else {
                        note("还没看到手机的 NCM 网口（ioreg），先不回 0x4301")
                        return []
                    }
                    guard let fe80 = UsbNet.linkLocalV6(iface) else {
                        note("NCM 网口 \(iface) 还没有链路本地地址，先不回 0x4301")
                        return []
                    }
                    // 有线 deviceIdentifier 用手机 AV 网口在 Mac 这一侧的 MAC（mib2q/DiPlay 同款），
                    // public_key 字段仍是配对标识 pi——与无线同一契约，不是 Ed25519 公钥。
                    let mac = NetInfo.mac(iface)?.uppercased() ?? "00:00:00:00:00:00"
                    note("开有线会话：AV \(iface) \(fe80) → 控制口 \(o.controlPort)")
                    return [Iap2Csm.carPlayStartSessionWired(
                        ipAddresses: [fe80], port: UInt32(o.controlPort),
                        deviceIdentifier: mac, publicKey: store.identity.pairingId, sourceVersion: "950.7.1")]
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
            acc.start()
        }
        usbSupervise()
        note("等 iPhone：插线即连（USB carkit → iAP2 → 有线会话），拔了自动等下一次")
        RunLoop.main.run()
        exit(0)
    }

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
        let h264 = H264Sink(server: server)
        var main = DisplayConfig(widthPixels: o.width, heightPixels: o.height,
                                 widthPhysicalMm: 125, heightPhysicalMm: 125, fps: 60)
        // 幾何單一來源（環境變量可覆蓋做真機實驗）
        PetDisplay.apply(&main)
        main.primaryInputDevice = 1
        var info = InfoConfig(sourceVersion: "950.7.1", deviceID: store.identity.deviceId,
                              bluetoothMAC: Iap2BluetoothAccessory.localBluetoothAddress, name: "HomePlay",
                              main: main)
        info.model = "HomePlay"; info.manufacturer = "HomePlay"
        Wireless.applyHomeIcon(&info)
        // HEVC 真機驗證通過（v0.3.0）：/info 與會話 SETUP 的 enabledFeatures 必須一致，
        // 否則手機會在 RECORD 後立刻 TEARDOWN。HOMEPLAY_HEVC=0 可回退 H.264。
        info.hevc = ProcessInfo.processInfo.environment["HOMEPLAY_HEVC"] != "0"
        info.videoPlayback = true; info.videoAllowed = Wireless.carVideoAllowed()   // CarPlay 影片（停車時播影片）
        note(PetDisplay.describe(o.width, o.height))
        info.entertainmentSampleRate = 48000
        info.disableAudioOutput = false   // 音频已能播（AAC/PCM）；Opus/麦克风仍未接
        var cfg = CarPlaySessionConfig(info: info)
        cfg.port = o.controlPort
        cfg.phoneBluetoothAddress = o.phoneAddress
        cfg.advertiseIAPChannel = o.advertiseIAPChannel
        let s = CarPlaySession(config: cfg, store: store, signer: MfiSigner(identity: identity), sink: h264)
        wireCarVideo(s, server: server)
        let alternateHost = NetInfo.linkLocalIPv6(o.iface)
        if alternateHost != nil { note("IPv6 备用地址就绪（链路本地）") }
        var fallbackItem: DispatchWorkItem?
        var handoffGeneration = 0
        var wifiWaitItem: DispatchWorkItem?   // 手机说无线可用、但迟迟不发 0x4300：多半没加入 Wi-Fi
        var controlSeen = false   // 手机连回控制口（不代表已经出画面）
        // 会话走的是 Wi-Fi 还是 USB NCM、属于哪台手机（蓝牙地址或 USB 序号）：
        // 拔线时据此决定「保持」还是「等重连」，另一台手机插线时据此决定要不要顶掉。
        var pendingTransport: CarPlayTransport?
        var liveTransport: CarPlayTransport?
        var pendingOwner: String?
        var liveOwner: String?
        var unplugFreeze = false            // 拔线后桌宠在冻帧，等会话确认还活着或新会话到来
        var unplugCheckItem: DispatchWorkItem?
        var lastUnplugAt = Date.distantPast
        var lastControlAt = Date.distantPast   // 最近一次控制连接接入时刻（Wi-Fi 短断恢复用）
        var lastSessionEndedAt = Date.distantPast   // 最近一次会话结束时刻（Wi-Fi 短断快速自愈）
        var backoff = BackoffSchedule(ladder: [2, 5, 10, 20, 30, 60], slow: 60)
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
        var handoffOnWirelessActive: (() -> Void)?
        var tunnelOnActive: (() -> Void)?   // RECORD 后在流 130 隧道上起 iAP2（下面接线）
        s.onActive = {
            live = true
            Wireless.setPairingHint(nil)
            Wireless.setCableHint(nil)
            Wireless.setTrustHint(nil)
            DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"started"}"#) }
            DispatchQueue.main.async { cancelFallback() }
            // 会话成功建立 = 手机状态已恢复：清掉自愈节流戳，下一次异常可以立即自愈。
            let stamp = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HomePlay/selfheal.stamp")
            try? FileManager.default.removeItem(at: stamp)
            note("会话开始，等画面")
            DispatchQueue.main.async {
                liveTransport = pendingTransport
                liveOwner = pendingOwner
                switch liveTransport {
                case .wifi where Wireless.accessoryUsb != nil: note("会话建立：Wi-Fi（USB 仅充电＋iAP2 控制，随时可拔）")
                case .wifi: note("会话建立：Wi-Fi")
                case .usbNCM: note("会话建立：USB 有线（拔线会结束，之后蓝牙重连）")
                case nil: break
                }
                handoffOnWirelessActive?()
                tunnelOnActive?()
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
            DispatchQueue.main.async { cancelFallback(); liveTransport = nil; liveOwner = nil }
            note("会话结束：\(why)")
            DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"ended"}"#) }
            // Wi-Fi 短断的恢复：会话因「15 秒没有控制消息也没有画面」结束后，手机不会自己
            // 重新发 0x4300（真机 2026-10-20 00:21 样本）。30 秒内没有新控制连接就把
            // iAP2 重置一次，让手机重新走 carkitd 握手；用户主动退出 CarPlay 不走这条。
            if why.contains("15 秒没有控制消息") {
                lastSessionEndedAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    guard !live, Date().timeIntervalSince(lastControlAt) > 10,
                          let acc = Wireless.accessory, !acc.core.finished else { return }
                    note("会话结束后 15 秒没有重新接入：重置 iAP2 让手机重新发起（Wi-Fi 短断恢复）")
                    backoff.reset()
                    acc.core.finish(13)
                }
            }
        }
        s.onControlConnected = { host in
            if Self.isSelfAddress(host, iface: o.iface) {
                note("控制连接来自本机（\(host)），忽略，不影响 0x4301 重试")
                return
            }
            DispatchQueue.main.async {
                controlSeen = true
                lastControlAt = Date()
                cancelFallback()
                wifiWaitItem?.cancel(); wifiWaitItem = nil
                // 对端是手机 NCM 网口的链路本地地址 → USB 有线；否则是 Wi-Fi（Wi-Fi 也可能给 fe80，所以看网口名）
                let ncm = Wireless.accessoryUsb.map { UsbNet.ncmInterfaces(udid: $0.device.serial) } ?? []
                pendingTransport = CarPlayTransportPolicy.transport(forPeer: host, ncmInterfaces: ncm)
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

        // 手机切换命令由下面定义的处理函数接管（onText 比它们先建立，避免转发/捕获顺序问题）。
        var usePhoneHandler: ((String) -> Void)?
        var pairNewHandler: (() -> Void)?
        var forgetPhoneHandler: ((String) -> Void)?
        var restorePhonesHandler: (() -> Void)?
        // 桌宠是在前台看配对引导，还是只在后台挂接等画面。后台不弹系统设置。
        var uiEngaged = false
        var cableFirstClientConnected: (() -> Void)?
        server.onConnect = { conn in
            // 桌宠中途连上/重连：旧关键帧早过了，主动向手机要一个，别等解码端自己发现解不出来
            if live { note("桌宠连上且会话进行中 → 主动要关键帧"); s.requestKeyframe() }
            server.sendText(Wire.helloJSON(name: "CarPlay（双模）", width: o.width, height: o.height), to: conn)
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
        server.onText = { text in
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
                return
            }
            if text.contains("\"type\":\"discoverable\"") {
                // 诊断：在本进程（launchd 拉起、带 App 蓝牙权限）里调私有可发现性 API。
                // 结果以广播返回；真实状态请用 system_profiler 复核。
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = obj["value"] as? Bool {
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
            if text.contains("\"keyframe\"") { note("桌宠要关键帧 → forceKeyFrame"); s.requestKeyframe() }
            if let t = Touch.parse(text) { s.sendTouch(x: t.x, y: t.y, down: t.down) }
            if let b = mediaButton(text) { s.sendMedia(b) }
            phoneControl(text, session: s)
            carVideoFromPet(text, session: s)
            applySeek(text)
        }

        // 蓝牙监督（拔线时工作）
        var retryItem: DispatchWorkItem?
        var preferredAddress = o.phoneAddress
        var phoneLocked = o.phoneAddress != nil
        var beacon: BluetoothBeacon?
        var immediateCloseStreak = 0   // 连续「RFCOMM 开了立刻被关」次数：用于自动重发 SDP / 自愈
        var btFailStreak = 0   // 连续「没认证就结束」（开不开/逾时/立刻被关）次数：两次就自愈重启，新进程 2 秒内能连上
        var republishDone = false      // 本轮已重发过 SDP（避免每个周期都重发）
        var lastUsbEndedAt = Date.distantPast   // 拔线时刻：用于「拔线后手机拒绝 iAP2」的快速自愈
        /// 手机把 iAP2 通道「接受后立刻关闭」且 SDP 重发无效时，真机验证只有「接收器
        /// 干净重启」能恢复（2026-10-19 两次复现）。这里退出让 launchd 重新拉起
        /// （LaunchAgent 配了 KeepAlive.SuccessfulExit=false；用户主动停止是 exit(0) 不受影响）。
        /// 10 分钟节流，避免失败时反复重启。
        func selfHeal(_ reason: String) {
            guard getppid() == 1 else {
                note("（非 launchd 拉起的实例不做自愈，继续退避重试）")
                return
            }
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HomePlay")
            let url = dir.appendingPathComponent("selfheal.stamp")
            let now = Date()
            let last = (try? String(contentsOf: url, encoding: .utf8))
                .flatMap { Double($0) }
                .map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            guard now.timeIntervalSince(last) > 600 else {
                note("自愈 10 分钟内已执行过，继续退避重试")
                return
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? String(now.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
            note("自愈：\(reason)。退出让 launchd 干净重启接收器（配件状态复位）")
            Wireless.shutdown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(1) }
        }
        var startBeaconIfNeeded: (() -> Void)?
        var handleBeaconIncoming: ((IOBluetoothDevice, IOBluetoothRFCOMMChannel) -> Void)?
        var btPaused = false
        // disableBluetooth 之後手機沒 SETUP 流 130：藍牙是唯一的 iAP2 路徑（通話狀態、正在播放），
        // 會話進行中斷了也走快速重連，不降成 60 秒慢速保活。RECORD／流 130 SETUP 時重置。
        var keepBluetoothIap2 = false
        func bluetoothRetrySlow() -> Bool {
            CarPlayTransportPolicy.bluetoothRetryIsSlow(live: live, keepBluetooth: keepBluetoothIap2)
        }
        var lastPairNotify = Date.distantPast
        // 首次配对引导：一台 iPhone 都没配对过时，打开系统蓝牙设置（Mac 在蓝牙面板打开时可被发现），
        // 轮询系统配对列表；新 iPhone 一出现就刷新 SDP 直接连——不用先插 USB。
        var pairingGuide = false
        var pairingForNewDevice = false   // 「配对新 iPhone」：旧手机连上不算完成，继续等新设备
        var pairingGuideStarted: CFTimeInterval = 0
        var pairingBaseline = Set<String>()
        var pairingPoll: DispatchWorkItem?
        var lastPaneOpen = Date.distantPast
        var lastDiscoverableAssert = Date.distantPast
        var discoverableHeld = false   // 配对引导期间由我们打开的可发现性；结束时恢复关闭
        let hostName = Iap2BluetoothAccessory.localBluetoothName

        func notifyNeedPairing() {
            guard Date().timeIntervalSince(lastPairNotify) > 30 else { return }
            lastPairNotify = Date()
            if let text = Wireless.pairingHintPayload(host: hostName, stale: !Iap2BluetoothAccessory.ignoredAddresses.isEmpty) {
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

        /// 新配对出现的手机 → 停引导、刷新 SDP、直接连（和插线学到的地址走同一条路）。
        func finishPairingGuide(_ phone: (address: String, name: String)) {
            stopPairingGuide()
            cancelCableFirst("蓝牙配对完成")
            note("蓝牙配对完成：\(phone.name)（\(phone.address)）→ 刷新 SDP 后连接")
            Wireless.setPairingHint(nil)
            server.broadcastText(#"{"type":"pairingDone"}"#)
            // 之前可能连着另一台手机：收掉旧 RFCOMM 和控制会话，避免两路画面抢 sink。
            let old = accessory
            accessory = nil
            old?.onFinished = nil
            old?.close()
            preferredAddress = phone.address
            phoneLocked = true
            Wireless.persistPhone(phone.address)
            s.setPhoneBluetoothAddress(phone.address)
            s.switchPhone(to: phone.address)
            clearNowPlaying(server: server)
            retryItem?.cancel(); retryItem = nil
            backoff.reset()
            startBeaconIfNeeded?()
            publishPhones(force: true)
            SDPRefresh.refresh(address: phone.address) {
                startBluetooth()
            }
        }

        /// 只在桌宠真的在前台看引导时才打开可发现性/蓝牙设置：后台挂接或 launchd
        /// 接收器没有 UI 时不要自己弹系统设置。桌宠进入前台后下一轮 2 秒轮询会补开。
        func ensureDiscoverableForPairing() {
            guard uiEngaged, server.hasClients else { return }
            // 保持 Mac 可被发现：App 进程里的私有 API 在 macOS 26 上有效（launchd 实例
            // 实测 Off→On；终端进程会因权限身份失败）；不可用时退回后台打开蓝牙设置面板。
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
                guard pairingGuide, !btPaused else { return }
                ensureDiscoverableForPairing()
                let fresh = PairingRules.newlyPaired(Iap2BluetoothAccessory.pairedPhones(), baseline: pairingBaseline)
                if let phone = fresh.first {
                    finishPairingGuide(phone)
                    return
                }
                // 名字里没有 iPhone 的自定义名称手机过不了 pairedPhones 过滤；
                // 任何新配对设备都试一次出站 iAP2，成功后 startBluetooth 会自己停掉引导。
                let freshAny = PairingRules.newlyPaired(Iap2BluetoothAccessory.pairedDevices(), baseline: pairingBaseline)
                if let candidate = freshAny.first {
                    pairingBaseline.insert(PairingRules.normalize(candidate.address))
                    note("配对列表出现新设备 \(candidate.name)，尝试 iAP2")
                    startBluetooth()
                }
                if CACurrentMediaTime() - pairingGuideStarted > 180 {
                    stopPairingGuide()
                    note("蓝牙配对引导结束（3 分钟没等到新设备）；仍会每 60 秒自动重查")
                    return
                }
                schedulePairingPoll()
            }
            pairingPoll = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
        }

        func startPairingGuide(_ reason: String, forNewDevice: Bool = false) {
            guard !btPaused else { return }
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
        var notPairedRechecks = 0
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
            guard !pairingGuide, !btPaused, !cableFirst else { return }
            cableFirst = true
            let text = Wireless.needCablePayload()
            Wireless.setCableHint(text)
            if uiEngaged, server.hasClients, let text { server.broadcastText(text) }
            note("\(reason) → 首次配对先等数据线（20 秒）；插上会自动配对，不用进设置")
            func armCableFirstTimer() {
                guard cableFirst, !pairingGuide, !btPaused, cableFirstItem == nil else { return }
                guard uiEngaged, server.hasClients else {
                    note("桌宠还没进入配对引导：插线窗口等它进入后再开始计时")
                    return
                }
                let item = DispatchWorkItem {
                    guard cableFirst, !pairingGuide, !btPaused else { return }
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

        /// 把已配对手机列表/当前选择发给桌宠；只在内容变化时广播，桌宠菜单打开时直接拿。
        func publishPhones(force: Bool = false) {
            guard let text = Wireless.phonesPayload(current: preferredAddress) else { return }
            guard force || Wireless.cachedPhones() != text else { return }
            Wireless.setPhones(text)
            server.broadcastText(text)
        }

        /// 用户选另一台已配对的手机：收掉旧连接/旧会话，按新地址重新叫回连。
        func selectPhone(_ raw: String) {
            let address = PairingRules.normalize(raw)
            guard let phone = Iap2BluetoothAccessory.pairedPhones()
                .first(where: { PairingRules.normalize($0.address) == address }) else {
                note("切换手机：\(address) 不在已配对列表")
                publishPhones(force: true)
                return
            }
            guard !btPaused else {
                // 插着 USB 时蓝牙让位；先记住选择，拔线后 resumeBluetooth 会连它。
                preferredAddress = phone.address
                phoneLocked = true
                s.setPhoneBluetoothAddress(phone.address)
                note("插着 USB：已选择 \(phone.name)，拔线后连接它")
                publishPhones(force: true)
                return
            }
            if let current = preferredAddress, PairingRules.normalize(current) == address,
               accessory != nil || live {
                note("已经是 \(phone.name)，不重复切换")
                publishPhones(force: true)
                return
            }
            stopPairingGuide()
            Wireless.setPairingHint(nil)
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
            note("切换手机 → \(phone.name)（\(phone.address)）")
            publishPhones(force: true)
            s.switchPhone(to: phone.address) { DispatchQueue.main.async { startBluetooth() } }
        }

        /// 「配对新 iPhone…」：即使已经有一台在用，也重新进入配对引导；新增的手机配对后自动切过去。
        func pairNewPhone() {
            guard !btPaused else {
                note("插着 USB：请拔线后再配对新的 iPhone")
                return
            }
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
                phoneLocked = false
                stopPairingGuide()
                Wireless.setPairingHint(nil)
                s.switchPhone(to: "") { DispatchQueue.main.async { startBluetooth() } }
                clearNowPlaying(server: server)
            }
            publishPhones(force: true)
            if Iap2BluetoothAccessory.pairedPhones().isEmpty {
                startPairingGuide("已忘记当前 iPhone", forNewDevice: false)
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
        pairNewHandler = { pairNewPhone() }
        server.start()
        publishPhones(force: true)
        refreshPhoneListLoop()

        func locatePhone() -> Result<(IOBluetoothDevice, BluetoothRFCOMMChannelID, String), Iap2BluetoothAccessory.LocateError> {
            if let pref = preferredAddress {
                switch Iap2BluetoothAccessory.locate(address: pref) {
                case .success(let found): return .success((found.0, found.1, pref))
                case .failure(let e):
                    if phoneLocked { return .failure(e) }
                    preferredAddress = nil   // 自动匹配到的那台不在了，转自动
                    publishPhones()
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
            let item = DispatchWorkItem {
                guard !btPaused else { return }   // 插着线时蓝牙让位，恢复时再启动
                startBluetooth()
            }
            retryItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        /// incoming：iPhone 主动连进我们发布的 iAP2/CarPlay 服务（MacPlay 式）；否则扫已配对设备主动连。
        func startBluetooth(adopting incoming: (device: IOBluetoothDevice, channel: IOBluetoothRFCOMMChannel)? = nil) {
            guard !btPaused, accessory == nil else {
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
                // 引导中允许新手机连入；平时只接受当前选定的那台，避免两台抢会话。
                guard PairingRules.acceptsIncoming(address: normalized,
                                                   pairedPhones: Iap2BluetoothAccessory.pairedPhones(),
                                                   preferred: preferredAddress,
                                                   pairingGuide: pairingGuide) else {
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
                        // 这里 locate 已经在「当前手机」上找到了设备、只是 SDP 缓存里没有
                        // iAP2 服务：刷新这一台才对。新机通过 USB 学到的地址可能还没被
                        // pairedPhones() 归为 iPhone（名字/设备类未解析），PairingRules 会
                        // 退回列表第一台（旧手机），永远刷不到新手机（真机样本 2026-10-19 22:15：
                        // preferred=50:3B… 却一直刷新旧 SE E0:C7…）。
                        if let preferred = preferredAddress {
                            note("\(e.description)；刷新 \(preferred) 的 SDP 后重试")
                            SDPRefresh.refresh(address: preferred) {
                                scheduleBluetoothRetry(after: backoff.next(live: bluetoothRetrySlow()), because: "SDP 已刷新")
                            }
                        } else {
                            let phones = Iap2BluetoothAccessory.pairedPhones()
                            switch PairingRules.action(pairedPhones: phones, preferred: nil) {
                            case .pairOnPhone:
                                beginCableFirst("已配对的设备里没有 iPhone")
                                scheduleBluetoothRetry(after: 60, because: "等蓝牙配对")
                            case .refreshSDP(let address):
                                note("\(e.description)；刷新 \(address) 的 SDP 后重试")
                                SDPRefresh.refresh(address: address) {
                                    scheduleBluetoothRetry(after: backoff.next(live: bluetoothRetrySlow()), because: "SDP 已刷新")
                                }
                            }
                        }
                    case .notPaired:
                        if let known = preferredAddress, Wireless.isKnownPhone(known), notPairedRechecks < 5 {
                            notPairedRechecks += 1
                            note("系统配对清单暂时读不到 \(known)（刚启动？）：3 秒后重查，不当成首次配对（第 \(notPairedRechecks) 次）")
                            scheduleBluetoothRetry(after: 3, because: "配对清单重查")
                            return
                        }
                        beginCableFirst("没有已配对的 iPhone")
                        scheduleBluetoothRetry(after: 60, because: "未配对")
                    default:
                        note("\(e.description)——手机不在？60s 后重查")
                        scheduleBluetoothRetry(after: 60, because: "手机不在")
                    }
                    return
                case .success(let located):
                    notPairedRechecks = 0
                    device = located.0
                    channelID = located.1
                    address = PairingRules.normalize(located.2)
                }
            }

            // 配对完成后（哪怕引导已超时）清掉缓存的配对卡片；只在确实有过提示时广播。
            // 「配对新 iPhone」期间旧手机连上不算完成，引导继续等新设备。
            cancelCableFirst("已连上 iPhone")
            let existingDuringNewPairing = pairingForNewDevice && pairingGuide && pairingBaseline.contains(address)
            if !existingDuringNewPairing {
                let hadPairingHint = pairingGuide || Wireless.cachedPairingHint() != nil
                stopPairingGuide()
                Wireless.setPairingHint(nil)
                if hadPairingHint { server.broadcastText(#"{"type":"pairingDone"}"#) }
            }
            if PairingRules.normalize(preferredAddress ?? "") != address {
                note("当前 iPhone：\(address)")
                preferredAddress = address
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
                note("蓝牙 iAP2 结束（\(code)）")
                // 整天的规律：接收器刚启动那次 RFCOMM 2 秒内必成，之后的重连常被手机拒绝（逾时或开了就关）。
                // 没有会话可保时，连续两次连不上就自愈重启（10 分钟节流；会话成功会清掉节流戳）。
                if !live, [3, 9, 10, 11].contains(code) {
                    btFailStreak += 1
                    if btFailStreak >= 2 { selfHeal("蓝牙连续 \(btFailStreak) 次连不上手机（新进程 2 秒内能连上）") }
                } else {
                    btFailStreak = 0
                }
                if code == 11 {
                    // 通道开了立刻被手机关掉、零字节。刚拔线（120 秒内）时这是正常现象：
                    // 手机还在收有线/USB 那边的尾巴，几秒后就会接受——走退避重连，绝不能在这里
                    // 退出进程（会连 Wi-Fi 上还活着的会话一起杀掉）。只有配件自己关过 USB
                    // （插线配对）或 Wi-Fi 短断之后的连续拒绝，才考虑自愈重启（10 分钟节流）。
                    let justUnplugged = Date().timeIntervalSince(lastUnplugAt) < 120
                    if justUnplugged {
                        // 真机 2026-10-22 14:59–15:00：拔线后手机连续拒绝超过一分钟，而接收器重启后 2 秒内就连上。
                        // 第一次被拒先退避；第二次就自愈重启（会话本来已被手机结束，没有东西可保）。
                        if immediateCloseStreak >= 1, !live { selfHeal("拔线后手机连续拒绝 iAP2") }
                    } else if Date().timeIntervalSince(lastUsbEndedAt) < 120 {
                        selfHeal("配件关掉 USB 后手机拒绝 iAP2（有线会话收尾）")
                    } else if Date().timeIntervalSince(lastSessionEndedAt) < 180 {
                        selfHeal("会话刚结束（如 Wi-Fi 短断）后手机拒绝 iAP2")
                    }
                    immediateCloseStreak += 1
                    if immediateCloseStreak >= 2, !republishDone {
                        republishDone = true
                        note("连续 \(immediateCloseStreak) 次被手机立刻关闭：重新发布车机 SDP（恢复其缓存的旧状态）")
                        beacon?.republish()
                    }
                    if immediateCloseStreak >= 4 {
                        selfHeal("连续 \(immediateCloseStreak) 次被手机立刻关闭（SDP 重发无效）")
                    }
                    if acc.dropBaseband() { note("已断开到 \(address) 的基带连接，下次重开 RFCOMM 走干净的新连接") }
                    note("刷新 \(address) 的 SDP（通道过期）")
                    SDPRefresh.refresh(address: address) {
                        scheduleBluetoothRetry(after: backoff.next(live: bluetoothRetrySlow()), because: "SDP 已刷新（通道过期）")
                    }
                } else {
                    immediateCloseStreak = 0
                    republishDone = false
                    scheduleBluetoothRetry(after: backoff.next(live: bluetoothRetrySlow()), because: bluetoothRetrySlow() ? "会话进行中，慢速" : (live ? "会话进行中，蓝牙是唯一 iAP2 路径" : "退避重连"))
                }
            }
            acc.onMessage = { frame in
            acc.onArtwork = { id, data in publishArtwork(id: id, data: data, server: server) }
                switch frame.messageId {
                case Iap2Csm.CarPlay.wifiConfigRequest:
                    note("iPhone 要 Wi-Fi 配置 → 回 \(ssid)（密码不打印）")
                    return [Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase, security: currentSecurity(), channel: currentChannel())]
                case 0x4E0E:
                    // DiPlay 同款：手机报完传输标识后重发一次 Wi-Fi 配置，确保它拿着凭据去连网
                    // （只发一次，避免重复包；0x4E0E 也可能在别处出现）。
                    note("iPhone 报传输标识（0x4E0E）→ 补发 Wi-Fi 配置")
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
                    if live { return [] }
                    sawAvailability = true
                    // 日志带属性（有线/无线各报了什么）：0x4300 也可能只报有线可用，
                    // 那样回无线版 0x4301 手机就不会连（2026-10-19 23:02 真机样本需要它判读）。
                    let liveIP = currentIP() ?? ip
                    if let a = Iap2Csm.carPlayAvailability(frame) {
                        note("iPhone 报 CarPlay 可用（\(a.summary)）→ 开会话 \(liveIP):\(o.controlPort)")
                    } else {
                        note("iPhone 报 CarPlay 可用 → 开会话 \(liveIP):\(o.controlPort)")
                    }
                    scheduleHandoffRetries()
                    let ssidName = ssid.isEmpty ? "当前 Wi-Fi" : ssid
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        guard !live, !controlSeen else { return }
                        note("iPhone 未连回控制口：确认 iPhone 与 Mac 在同一个 Wi-Fi（\(ssidName)）；若仍不行，右键 → Wi-Fi 设置 里核对 SSID 与密码（系统设置 › Wi-Fi › 详细信息可查看密码）")
                        if let help = Wireless.wifiHelpPayload(ssid: ssidName, passphraseMissing: passphrase.isEmpty) { server.broadcastText(help) }
                    }
                    pendingOwner = address
                    return [startMessage([liveIP])]
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
                    scheduleBluetoothRetry(after: backoff.next(live: bluetoothRetrySlow()), because: "RFCOMM 打开失败")
                }
            } else if let incoming {
                if acc.adopt(channel: incoming.channel) {
                    accessory = acc
                } else {
                    incoming.channel.close()
                }
            }
        }

        /// 蓝牙让位给有线（正在直播也切——手机自己也会转有线）
        func pauseBluetooth(_ reason: String) {
            guard !btPaused else { return }
            cancelCableFirst("USB 已接管")
            btPaused = true
            stopPairingGuide()
            retryItem?.cancel(); retryItem = nil
            DispatchQueue.main.async { cancelFallback() }
            accessory?.close()
            note("蓝牙让位（\(reason)）")
        }
        func resumeBluetooth() {
            guard btPaused else { return }
            btPaused = false
            DispatchQueue.main.async { cancelFallback() }
            accessory = nil
            backoff.reset()   // 干净的拔线-插线循环不走长退避
            note("USB iAP2 已结束：蓝牙恢复待命")
            startBluetooth()
        }

        /// 首插配对：有线会话里手机报它的蓝牙地址（0x4E0E 参数 0），没配对就发起（手机上点一下）。
        /// 不能用一次性插销：用户错过配对弹窗后，下次插拔还要能再试。
        var pairAttempt: Date = .distantPast
        var pairInFlight = false
        var pairingHandoffRequest: ((String) -> Void)?
        // 每台 USB 设备在这段插线里只自动让位配对一次；失败回 USB 后不要循环关 USB。
        var pairingAttemptedSerials = Set<String>()
        func learnPhoneBluetooth(_ frame: Iap2Csm.Frame) {
            guard frame.messageId == 0x4E0E,
                  let param = frame.parameters.first(where: { $0.id == 0 }) else { return }
            var bytes = param.payload
            if bytes.last == 0 { bytes.removeLast() }
            guard let address = String(bytes: bytes, encoding: .utf8)?.uppercased(), address.contains(":") else { return }
            cancelCableFirst("USB 已报到手机地址")
            Wireless.unignorePhone(address)
            if let serial = accessoryUsb?.device.serial { Wireless.rememberUSBPhone(serial: serial, address: address) }
            if address != preferredAddress {
                preferredAddress = address
                phoneLocked = true
                s.setPhoneBluetoothAddress(address)
                note("有线会话里学到手机蓝牙地址：\(address)")
                publishPhones()
            }
            switch Iap2BluetoothAccessory.locate(address: address) {
            case .success:
                Wireless.persistPhone(address)
                if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                note("这台手机已配对过蓝牙，拔线即无线")
            case .failure(.noService):
                // 系统里已配对，只是 SDP 缓存里还没有 iAP2 服务——拔线后的蓝牙重连
                // 会刷新 SDP。不要再发起配对：真机样本 2026-10-19，手机早已配对，
                // 这里每 60 秒误报一次「配对没成」（手机上也不会再弹确认）。
                Wireless.persistPhone(address)
                if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                note("这台手机已配对过蓝牙（SDP 缓存里还没有 iAP2 服务，拔线后重连会刷新）")
            case .failure(let error):
                // USB CarPlay 期间手机会临时关蓝牙/SDP 不可用；系统配对记录还在时
                // 不要当成「没配对」再弹一次配对窗，拔线后的蓝牙重连会刷新。
                if Iap2BluetoothAccessory.isSystemPaired(address) || Wireless.isKnownPhone(address) {
                    Wireless.persistPhone(address)
                    if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                    note("这台手机在系统里已配对（\(error)）；拔线后蓝牙重连会刷新，不再重复发起配对")
                    return
                }
                // USB CarPlay 期间手机会主动关蓝牙；先在 USB 会话里学到地址，再结束 USB、
                // 让手机蓝牙恢复，之后才发起配对。这样插线也能换一台未配对的新 iPhone。
                if let serial = accessoryUsb?.device.serial, pairingAttemptedSerials.contains(serial) {
                    note("这段插线已经尝试过配对：保持有线；拔线再插可重试，或右键「配对新 iPhone」")
                    return
                }
                guard !pairInFlight, Date().timeIntervalSince(pairAttempt) > 30 else { return }
                pairInFlight = true
                pairAttempt = Date()
                note("第一次插线：先结束 USB，让手机蓝牙恢复后再配对")
                pairingHandoffRequest?(address)
            }
        }

        // USB 0x4300 → 0x4301 的短窗重试：macOS 绑定 NCM 网口常比手机报 0x4300 晚
        // （真机样本 2026-10-19 22:31：0x4300 后 0.2s 查不到，但同一秒 en13 已经在了；
        // 手机不总会重发 0x4300，只查一次就放弃等于永远不回）。
        var usbStartRetry: DispatchWorkItem?
        var usbStartSent = false
        var wifiConfigSentUSB = false     // 本段 USB 会话里已把 0x5703 Wi-Fi 配置给过手机
        var wirelessTriedUSB = false      // 本段 USB 会话里无线版 0x4301 已试过、12 秒内没回连
        var usbWirelessFallback: DispatchWorkItem?
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
        /// 每 2 秒重查一次 NCM，最多 60 秒（真机样本 2026-10-19 22:35：0x4300 到了，
        /// 但 en13 的 fe80 链路本地地址几十秒后才就绪；只等 10 秒会错过）。
        /// 日志分开写清「网口没出现」还是「网口有、fe80 没到」，便于下次判读。
        func scheduleUSBStartRetry(_ device: Usbmuxd.Device, acc: Iap2UsbAccessory?) {
            usbStartRetry?.cancel()
            var remaining = 30
            func attempt() {
                guard !usbStartSent, !live, let acc, !acc.core.finished else { return }
                if let reply = wiredStartReply(device) {
                    usbStartSent = true
                    pendingOwner = preferredAddress ?? device.serial
                    note("NCM 就绪：补发 0x4301（手机停在可用性通知上等）")
                    acc.core.send(reply)
                    return
                }
                remaining -= 1
                if remaining % 5 == 0 {
                    let iface = UsbNet.ncmInterfaces(udid: device.serial).first
                    if let iface {
                        note("NCM 网口 \(iface) 已出现，等它的链路本地地址（还剩 \(remaining * 2)s）")
                    } else {
                        note("NCM 网口还没出现（还剩 \(remaining * 2)s）")
                    }
                }
                guard remaining > 0 else {
                    note("60 秒内 NCM 仍未就绪；手机若重发 0x4300 再试")
                    return
                }
                let item = DispatchWorkItem { attempt() }
                usbStartRetry = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
            }
            let item = DispatchWorkItem { attempt() }
            usbStartRetry = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
        }

        /// 把策略结果变成要回给手机的帧。无线版 0x4301 走 USB iAP2 链路送出，手机会直接用
        /// Wi-Fi 开会话（真机 2026-10-22 12:21 样本：235 ms 回连），线只剩充电＋iAP2 控制。
        /// 12 秒没回连就退回有线版（NCM），像真车一样插着线走有线，拔线再回蓝牙。
        func usbStartFrames(_ reply: CarPlayTransportPolicy.StartReply, device: Usbmuxd.Device,
                            acc: Iap2UsbAccessory?, owner: String) -> [Iap2Csm.Frame] {
            func wirelessFrames(pushConfig: Bool) -> [Iap2Csm.Frame] {
                usbStartSent = true
                pendingOwner = owner
                var frames: [Iap2Csm.Frame] = []
                if pushConfig {
                    wifiConfigSentUSB = true
                    frames.append(Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase,
                                                                     security: currentSecurity(), channel: currentChannel()))
                    note("手机还没拿过 Wi-Fi 配置：先推 0x5703")
                }
                let liveIP = currentIP() ?? ip
                note("手机报无线可用 → 用无线版 0x4301 开 Wi-Fi 会话 \(liveIP):\(o.controlPort)（USB 仅充电）")
                frames.append(startMessage([liveIP]))
                let fallback = DispatchWorkItem { [weak acc] in
                    guard !live, !controlSeen, let acc, !acc.core.finished, accessoryUsb === acc else { return }
                    wirelessTriedUSB = true
                    usbStartSent = false
                    if ncmReady(device), let wired = wiredStartReply(device) {
                        usbStartSent = true
                        note("12 秒没等到 Wi-Fi 回连：改送有线版 0x4301（插着线走有线）")
                        acc.core.send(wired)
                    } else if let alt = alternateHost ?? NetInfo.linkLocalIPv6(o.iface) {
                        note("12 秒没等到 Wi-Fi 回连、NCM 也未就绪：用链路本地 IPv6 再叫一次无线，并等 NCM")
                        usbStartSent = true
                        acc.core.send(startMessage([alt]))
                        usbStartSent = false
                        scheduleUSBStartRetry(device, acc: acc)
                    } else {
                        scheduleUSBStartRetry(device, acc: acc)
                    }
                }
                usbWirelessFallback = fallback
                DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: fallback)
                return frames
            }
            switch reply {
            case .wireless:
                return wirelessFrames(pushConfig: false)
            case .pushWiFiConfigThenWireless:
                return wirelessFrames(pushConfig: true)
            case .wired:
                guard let wired = wiredStartReply(device) else {
                    scheduleUSBStartRetry(device, acc: acc)
                    return []
                }
                usbStartSent = true
                pendingOwner = owner
                return [wired]
            case .waitNCM:
                // 有线可用、NCM 还没就绪：60 秒内重查并补发（手机不一定会重发 0x4300）。
                note("手机报有线可用，但 NCM 网口还没就绪：60 秒内重查并补发 0x4301")
                scheduleUSBStartRetry(device, acc: acc)
                return []
            case .none:
                note("手机没有报可用的传输（或 Mac 没有 Wi-Fi 且 NCM 未就绪）：先不回 0x4301")
                return []
            }
        }

        // 有线监督：1s 一看 USB；carkit 开成才让蓝牙让位（开不成不动蓝牙）
        func wiredMessageHandler(_ device: Usbmuxd.Device, acc: Iap2UsbAccessory) -> ((Iap2Csm.Frame) -> [Iap2Csm.Frame]) {
            { [weak acc] frame in
                learnPhoneBluetooth(frame)
                switch frame.messageId {
                case Iap2Csm.CarPlay.availability:
                    wifiWaitItem?.cancel(); wifiWaitItem = nil
                    // 先把手机报的属性记下来（MacPlay 同款）：经 USB 链路报 0x4300 也可能
                    // 只说无线可用（刚拿过 Wi-Fi 配置）。看不清它报了什么就无法判断该回
                    // 有线还是无线版 0x4301（2026-10-19 22:15/22:31 真机样本）。
                    let availability = Iap2Csm.carPlayAvailability(frame)
                    if let a = availability {
                        note("USB CarPlay 可用性（0x4300）：\(a.summary)")
                    }
                    // 这台手机的身份：USB 序号，以及它在 0x4E0E 里报的蓝牙地址（若已学到）。
                    let owner = preferredAddress ?? device.serial
                    if live {
                        // 已有会话：是同一台手机重发（例如它自己的 Wi-Fi 会话还活着）就不理；
                        // 是另一台手机插线就先结束旧会话——后插的拿会话，任何时刻只有一个。
                        let candidates = [device.serial, preferredAddress].compactMap { $0 }
                        let sameOwner = candidates.contains {
                            CarPlayTransportPolicy.onNewUSBPhone(liveOwner: liveOwner, newPhone: $0) == .ignore
                        }
                        if sameOwner { return [] }
                        note("另一台 iPhone 插线（\(String(owner.prefix(17)))）：结束 \(liveOwner ?? "?") 的会话，由它接管")
                        s.switchPhone(to: preferredAddress ?? "")
                    }
                    usbStartRetry?.cancel(); usbStartRetry = nil
                    usbWirelessFallback?.cancel(); usbWirelessFallback = nil
                    let wifiReady = currentIP() != nil && !ssid.isEmpty
                    let reply = CarPlayTransportPolicy.startReply(
                        wiredAvailable: availability?.wiredAvailable ?? false,
                        wirelessAvailable: availability?.wirelessAvailable ?? false,
                        wifiReady: wifiReady, wifiConfigSent: wifiConfigSentUSB,
                        ncmReady: ncmReady(device), wirelessTried: wirelessTriedUSB)
                    return usbStartFrames(reply, device: device, acc: acc, owner: owner)
                case Iap2Csm.CarPlay.wifiConfigRequest:
                    note("USB 会话里手机要 Wi-Fi 配置 → 回 \(ssid)（密码不打印）")
                    wifiConfigSentUSB = true
                    return [Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase, security: currentSecurity(), channel: currentChannel())]
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

        var usbRetryAt: TimeInterval = 0
        var usbTrustHintShown = false   // needTrust 卡片是否在外（成功打开/拔线时收起，别重复广播）

        // 会话从一开始就走 Wi-Fi（无线版 0x4301 经 USB iAP2 送出），不再「有线稳定后关 USB 等蓝牙」：
        // 那条路插着线时手机多半拒绝蓝牙 iAP2（2026-10-22 日志：20 次里 2 次成功，且每次都砍掉正在用的会话）。
        // usbSuppressed 只剩插线配对用：配对期间 USB 让位给手机的蓝牙，不重开 carkit。
        var usbSuppressed = false
        var suppressedSerial: String?
        var replacingUSB = false      // 后插的手机顶掉先插的：关旧 USB 时别把蓝牙恢复到旧手机
        var usbClosedByUs = false     // 配件自己关的 USB（插线配对），不是拔线
        var cableDebounce = CableDebounce(misses: 2)
        var cablePresent = false
        // 已配对手机的数据线只充电：不开 carkit，会话由蓝牙→Wi-Fi 建立，插拔线对会话没有影响
        //（真机 2026-10-22 14:59：只要 USB 上有 iAP2 链路，手机就把会话绑在它上面，拔线 115 ms 内结束会话）。
        // HOMEPLAY_USB_CARKIT=1 可强制走 carkit（排障／偏好有线）。
        let preferCarkit = ProcessInfo.processInfo.environment["HOMEPLAY_USB_CARKIT"] == "1"
        var chargeOnlySerial: String?
        var chargeOnlySince: TimeInterval = 0
        var chargeOnlyFallbackUsed = false
        var pairingHandoffInFlight = false
        var pairingHandoffTimeout: DispatchWorkItem?
        // USB 到达顺序：后插入的设备在数组末尾，拥有唯一的 CarPlay 会话优先权。
        var usbArrival: [String] = []
        var activeUSBSerial: String?
        /// listDevices() 与 carkit 握手都是阻塞 socket I/O，放在这条队列上跑，
        /// 只把结果送回主线程：主线程一卡，蓝牙回调、iAP2 tick 和 WebSocket 全跟着停。
        let usbQueue = DispatchQueue(label: "homeplay.usb.poll")
        var usbPollInFlight = false
        var usbOpening = false

        /// 拔线后桌宠的冻帧解除：会话还活着（Wi-Fi 会话本来就不受线影响）或新会话已到。
        func releaseUnplugFreeze(_ why: String) {
            guard unplugFreeze else { return }
            unplugFreeze = false
            unplugCheckItem?.cancel(); unplugCheckItem = nil
            Wireless.setHandoffHint(nil)
            note("拔线后画面已确认（\(why)）")
            if let text = Wireless.handoffPayload("done") { server.broadcastText(text) }
        }

        /// 线真的拔了（连续两次轮询都没看到装置）。会话在 Wi-Fi 上就不碰它；
        /// 会话在 USB NCM 上会由手机结束，蓝牙重连接管。两种情况桌宠都先冻住最后一帧，
        /// 不要回到「担心脸／连接中」。
        func onCableGone() {
            lastUnplugAt = Date()
            for action in CarPlayTransportPolicy.onCableGone(live: live, transport: liveTransport) {
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
                    backoff.reset()
                    resumeBluetooth()
                }
            }
        }

        func beginPairingHandoff(_ address: String) {
            // 0x4E0E 通常早于控制会话 live；插线配对不需要等画面，拿到地址就让 USB 让位。
            guard !pairingHandoffInFlight, let usb = accessoryUsb else {
                pairInFlight = false
                return
            }
            pairingHandoffInFlight = true
            pairingAttemptedSerials.insert(usb.device.serial)
            usbSuppressed = true
            suppressedSerial = usb.device.serial
            let pairing = Wireless.handoffPayload("pairing")
            Wireless.setHandoffHint(pairing)
            if let pairing { server.broadcastText(pairing) }
            note("插线配对：结束 USB，让手机蓝牙恢复后发配对请求")
            let safety = DispatchWorkItem {
                guard pairingHandoffInFlight else { return }
                pairingHandoffInFlight = false
                pairingHandoffTimeout = nil
                Wireless.setHandoffHint(nil)
                usbSuppressed = false
                suppressedSerial = nil
                stopPairingGuide()
                Wireless.setPairingHint(nil)
                note("插线配对 200 秒未完成：回退 USB CarPlay（本段插线不再自动尝试）")
                if let text = Wireless.handoffPayload("failed") { server.broadcastText(text) }
            }
            pairingHandoffTimeout = safety
            DispatchQueue.main.asyncAfter(deadline: .now() + 200, execute: safety)
            usbClosedByUs = true
            usb.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard pairingHandoffInFlight else { return }
                if let text = Wireless.bluetoothPairingPayload() { server.broadcastText(text) }
                BondAssist.pair(address: address) { ok, detail in
                    guard pairingHandoffInFlight, suppressedSerial == usb.device.serial else {
                        pairInFlight = false
                        return
                    }
                    pairInFlight = false
                    if ok {
                        Wireless.setPairingHint(nil)
                        Wireless.persistPhone(address)
                        if let text = Wireless.currentPhonePayload(address: address) { server.broadcastText(text) }
                        server.broadcastText(#"{"type":"pairingDone"}"#)
                        publishPhones(force: true)
                        // 配对成了就不等蓝牙 iAP2（插着线时手机多半不接）：下一轮 usbWatch 重开
                        // carkit，手机在 USB 链路上报 0x4300，我们回无线版 0x4301 → Wi-Fi 会话。
                        pairingHandoffInFlight = false
                        pairingHandoffTimeout?.cancel(); pairingHandoffTimeout = nil
                        Wireless.setHandoffHint(nil)
                        usbSuppressed = false
                        suppressedSerial = nil
                        backoff.reset()
                        note("插线配对完成：重开 USB，走 Wi-Fi 会话（线可继续插着充电）")
                        if let text = Wireless.handoffPayload("done") { server.broadcastText(text) }
                    } else {
                        note("插线配对没成（\(detail)）：转到蓝牙配对引导")
                        if let text = Wireless.bluetoothPairFailedPayload() { server.broadcastText(text) }
                        startPairingGuide("插线配对没确认", forNewDevice: true)
                    }
                }
            }
        }
        pairingHandoffRequest = { beginPairingHandoff($0) }

        func abortUSBHandoffs(_ why: String) {
            guard pairingHandoffInFlight else { return }
            pairingHandoffInFlight = false
            pairingHandoffTimeout?.cancel(); pairingHandoffTimeout = nil
            stopPairingGuide()
            Wireless.setPairingHint(nil)
            usbSuppressed = false
            suppressedSerial = nil
            pairInFlight = false
            note("USB 更换：放弃旧手机的插线配对（\(why)）")
            Wireless.setHandoffHint(nil)
            if let text = Wireless.handoffPayload("failed") { server.broadcastText(text) }
        }

        /// 只取“最后插入”的 USB 设备；先到的保留为充电设备，不再抢 carkit。
        /// 活动设备变化时结束旧会话，保证同一时间只有一个 CarPlay。
        func pollActiveUSB(_ devices: [Usbmuxd.Device]) -> Usbmuxd.Device? {
            let present = Set(devices.map(\.serial))
            usbArrival.removeAll { !present.contains($0) }
            pairingAttemptedSerials.formIntersection(present)
            let fresh = devices.filter { !usbArrival.contains($0.serial) }
                .sorted { $0.id < $1.id }   // 同一轮新插入的多台，DeviceID 大的算后到
            usbArrival.append(contentsOf: fresh.map(\.serial))
            guard let serial = usbArrival.last,
                  let device = devices.first(where: { $0.serial == serial }) else {
                activeUSBSerial = nil
                return nil
            }
            if let old = activeUSBSerial, old != serial {
                note("USB 后到设备顶掉先到设备（\(String(serial.prefix(8))) 取代 \(String(old.prefix(8)))），只保留一个 CarPlay 会话")
                abortUSBHandoffs("USB 更换")
                if let acc = accessoryUsb, acc.device.serial != serial {
                    replacingUSB = true   // 关旧链路时不要把蓝牙恢复到旧手机（会和新手机抢会话）
                    acc.close()
                }
                s.switchPhone(to: "")
                usbSuppressed = false
                suppressedSerial = nil
            }
            activeUSBSerial = serial
            return device
        }

        handoffOnWirelessActive = {
            // 拔线后手机结束了旧会话、蓝牙重连开出新会话：解除桌宠冻帧。
            releaseUnplugFreeze("新会话已开始")
        }

        func usbWatch() {
            defer { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: usbWatchTick) }
            // listDevices() 是阻塞 socket，放主執行緒會在最壞情況下卡住整個接收器。
            guard !usbPollInFlight else { return }
            usbPollInFlight = true
            usbQueue.async {
                let devices = (try? Usbmuxd.listDevices()) ?? []
                DispatchQueue.main.async {
                    usbPollInFlight = false
                    usbTick(devices)
                }
            }
        }

        func usbTick(_ devices: [Usbmuxd.Device]) {
            // usbmuxd 偶尔丢错会被当成空清单：连续两次没看到才算拔线，一次抖动不动任何状态。
            let wasPresent = cablePresent
            cablePresent = cableDebounce.observe(present: !devices.isEmpty)
            if devices.isEmpty, cablePresent { return }
            guard let device = pollActiveUSB(devices) else {
                pairingAttemptedSerials.removeAll()
                activeUSBSerial = nil
                if !pairingHandoffInFlight {
                    usbSuppressed = false
                    suppressedSerial = nil
                }
                if usbTrustHintShown {
                    usbTrustHintShown = false
                    Wireless.setTrustHint(nil)
                    server.broadcastText(#"{"type":"trustDone"}"#)   // 拔线：收起「点信任」卡片
                }
                pairAttempt = .distantPast   // 拔线再插＝新的重试机会，不必等 30 秒冷却
                chargeOnlySerial = nil
                if wasPresent { onCableGone() }   // 真拔线：会话在 Wi-Fi 上就保持，桌宠先冻帧
                else { resumeBluetooth() }        // 没插线：确保蓝牙在工作
                return
            }
            if usbSuppressed, let suppressedSerial, device.serial == suppressedSerial, pairingHandoffInFlight {
                // 插线配对进行中：USB 让位给手机的蓝牙，不重开 carkit。
                return
            }
            if usbSuppressed { usbSuppressed = false; suppressedSerial = nil }
            if !preferCarkit, accessoryUsb == nil,
               let known = Wireless.usbPhoneAddress(serial: device.serial),
               Iap2BluetoothAccessory.isSystemPaired(known) {
                if chargeOnlySerial != device.serial {
                    chargeOnlySerial = device.serial
                    chargeOnlySince = CACurrentMediaTime()
                    chargeOnlyFallbackUsed = false
                    cancelCableFirst("USB 已插入（已配对手机，只充电）")
                    note("USB 只充电：这台手机（\(known)）已配对，会话走蓝牙/Wi-Fi，不开 carkit；插拔线不影响会话")
                    let target = PairingRules.normalize(known)
                    let currentPhone = PairingRules.normalize(preferredAddress ?? "")
                    let liveIsOther = liveOwner.map { PairingRules.normalize($0) != target } ?? false
                    if currentPhone != target || liveIsOther {
                        // 插线是明确的「用这台」：后插的拿会话——结束旧手机的会话，蓝牙改连它。
                        note("另一台已配对的 iPhone 插线（\(known)）：切换到它，后插的拿会话")
                        selectPhone(known)
                    } else {
                        resumeBluetooth()
                    }
                }
                // 退路：插线 20 秒还没有会话、蓝牙也没认证成功，再开 carkit（这段插线只试一次）。
                let stuck = !live && CACurrentMediaTime() - chargeOnlySince > 20
                    && Wireless.accessory?.phase != .authenticated
                guard stuck, !chargeOnlyFallbackUsed else { return }
                chargeOnlyFallbackUsed = true
                note("插线 20 秒仍没有会话：改开 USB carkit（本段插线只试这一次）")
            }
            guard accessoryUsb == nil, !usbOpening, CACurrentMediaTime() >= usbRetryAt else { return }
            cancelCableFirst("USB 已插入")
            // carkit 開流含 lockdown/TLS 握手，是阻塞呼叫：放背景開好再回主執行緒接上。
            usbOpening = true
            let ident = identity
            usbQueue.async {
                let opened = Result { try Iap2UsbAccessory(device: device, identity: ident, stopAfterAuth: false) { note("USB " + $0) } }
                DispatchQueue.main.async {
                    usbOpening = false
                    adoptUSB(opened, device: device)
                }
            }
        }

        /// 背景開好的 carkit 在這裡接上（主執行緒）。期間插拔過就丟掉這條。
        func adoptUSB(_ opened: Result<Iap2UsbAccessory, Error>, device: Usbmuxd.Device) {
            switch opened {
            case .success(let acc):
                guard accessoryUsb == nil, activeUSBSerial == device.serial, !acc.finished else {
                    acc.close()
                    return
                }
                if usbTrustHintShown {
                    usbTrustHintShown = false
                    Wireless.setTrustHint(nil)
                    server.broadcastText(#"{"type":"trustDone"}"#)   // 用户点过信任：卡片收起
                }
                pauseBluetooth("USB 设备在（\(String(device.serial.prefix(8)))）")
                accessoryUsb = acc
                usbStartSent = false
                wifiConfigSentUSB = false
                wirelessTriedUSB = false
                usbStartRetry?.cancel(); usbStartRetry = nil
                usbWirelessFallback?.cancel(); usbWirelessFallback = nil
                acc.onLog = { note("USB " + $0) }
                acc.onPhase = { if $0 == .authenticated { backoff.reset() } }
                acc.onFinished = { code in
                    accessoryUsb = nil
                    usbStartSent = false
                    usbStartRetry?.cancel(); usbStartRetry = nil
                    usbWirelessFallback?.cancel(); usbWirelessFallback = nil
                    if usbClosedByUs { usbClosedByUs = false; lastUsbEndedAt = Date() }
                    clearNowPlaying(server: server)
                    note("USB iAP2 结束（\(code)）")
                    if replacingUSB {
                        // 后插的手机正在接管：蓝牙留着让位状态，由新链路决定去留。
                        replacingUSB = false
                        return
                    }
                    resumeBluetooth()
                }
                acc.onMessage = wiredMessageHandler(device, acc: acc)
                acc.onArtwork = { id, data in publishArtwork(id: id, data: data, server: server) }
                acc.start()
            case .failure(let error):
                note("carkit 打不开（\(error)）——确认 iPhone 已解锁、点「信任」，且数据线能传数据")
                if !usbTrustHintShown {   // 桌宠显示「点信任」卡片；轮询每 5 秒来一次，别刷屏
                    usbTrustHintShown = true
                    if let hint = Wireless.usbTrustHintPayload() {
                        Wireless.setTrustHint(hint)
                        server.broadcastText(hint)
                    }
                }
                usbRetryAt = CACurrentMediaTime() + 5
            }
        }
        // 分开包一层保持 defer 的语义清楚
        func usbWatchTick() { usbWatch() }

        handleBeaconIncoming = { device, channel in
            // IOBluetooth 回调线程 → 主队列，和 startBluetooth 的其他状态同一线程
            DispatchQueue.main.async { startBluetooth(adopting: (device, channel)) }
        }
        startBeaconIfNeeded = {
            guard beacon == nil else { return }
            let b = BluetoothBeacon(advertiseClass: true, log: { note("蓝牙广播：" + $0) })
            b.onIncoming = { device, channel in handleBeaconIncoming?(device, channel) }
            beacon = b
            Wireless.beacon = b
        }
        // 车机类 + iAP2/CarPlay SDP 必须在配对前就广播：iPhone 在配对时做 SDP 发现，
        // 那一刻看不到 CarPlay 服务，就只会把 Mac 当普通电脑，之后也不再提示 CarPlay。
        // （MacPlay 的蓝牙桥就是启动即发布；这里不再等"配对成功后"才发。）
        // ---- iAP 数据通道（流 130）：Wi-Fi 会话里的 iAP2 路径，拔线后仍在 ----
        // 手机 SETUP 130 后拿到隧道句柄；RECORD 一到就在隧道上跑一套完整的 iAP2 bring-up
        // （MacPlay 在 RECORD 时开 relay，同样由配件先发 marker＋SYNC，经事件通道 iAPSendMessage），
        // 手机连上数据口后回包就来。disableBluetooth 是手机宣告「iAP2 改走隧道」的信号：记日志，
        // 不以它为起跑条件——配件是链路发起方，等它再起会和手机互等。
        var tunnelLink: IapTunnelLink?
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
                learnPhoneBluetooth(frame)
                switch frame.messageId {
                case Iap2Csm.CarPlay.availability:
                    // 会话进行中不再回 0x4301；会话没了（拔线后手机重评）才用无线版开会话
                    if live { note("隧道 iAP2：手机报 CarPlay 可用（会话进行中，忽略）"); return [] }
                    let liveIP = currentIP() ?? ip
                    note("隧道 iAP2：手机报 CarPlay 可用 → 开会话 \(liveIP):\(o.controlPort)")
                    return [startMessage([liveIP])]
                case Iap2Csm.CarPlay.wifiConfigRequest:
                    note("隧道 iAP2：手机要 Wi-Fi 配置 → 回 \(ssid)（密码不打印）")
                    return [Iap2Csm.accessoryWiFiConfiguration(ssid: ssid, passphrase: passphrase, security: currentSecurity(), channel: currentChannel())]
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
                keepBluetoothIap2 = false
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
        tunnelOnActive = { keepBluetoothIap2 = false; startTunnelCore("RECORD") }
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
                let state = Wireless.accessoryTunnel.map { "隧道 iAP2 \($0.phase.rawValue)" }
                    ?? (tunnelLink == nil ? "手机没 SETUP 流 130，拔线后没有 iAP2 路径" : "隧道等手机连")
                note("手机要求停用蓝牙 iAP2（disableBluetooth，deviceID \(params["deviceID"] ?? "?")）：\(state)")
                // 流 130 常在 disableBluetooth 前後一秒內 SETUP；等 8 秒再判，沒來就把藍牙留作 iAP2 路徑
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    guard live, CarPlayTransportPolicy.bluetoothAfterDisable(tunnelSetUp: tunnelLink != nil) == .keep else { return }
                    keepBluetoothIap2 = true
                    if accessory == nil, !btPaused {
                        note("手机没 SETUP 流 130：保留蓝牙 iAP2（通话状态、正在播放走它），现在重连")
                        retryItem?.cancel(); retryItem = nil
                        backoff.reset()
                        startBluetooth()
                    } else {
                        note("手机没 SETUP 流 130：保留蓝牙 iAP2（通话状态、正在播放走它），断线快速重连")
                    }
                }
            }
        }

        startBeaconIfNeeded?()
        startBluetooth()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: usbWatchTick)
        note("双模：插线在 USB 上开 Wi-Fi 会话（线只充电），拔线会话保持；没插线走蓝牙；首次插线会自动发起蓝牙配对")
        RunLoop.main.run()
        exit(0)
    }
}


/// 第一次配对走系统蓝牙：打开「系统设置 › 蓝牙」后 Mac 才可被 iPhone 发现，
/// iPhone 点这台 Mac 的名字、两边确认配对码即可（和 MacPlay／DiPlay 一样由手机发起）。
/// 不碰私有 API，也不要求先插 USB。
///
/// macOS 自 10.9 起把「可被发现」绑在蓝牙设置面板是否打开上：面板关闭即不可发现，
/// `IOBluetoothPreferenceSetDiscoverableState`（blueutil 用的私有函数）在 macOS 26 上
/// 已是空实现，也没有对应的 defaults 键。所以这里后台打开面板（不抢焦点），
/// 并在配对引导期间每分钟补开一次，避免用户关掉面板后 Mac 变得不可发现。
enum BluetoothSettingsPane {
    static func open() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false          // 后台打开：不打断用户当前操作
        for text in ["x-apple.systempreferences:com.apple.BluetoothSettings",
                     "x-apple.systempreferences:com.apple.preferences.Bluetooth"] {
            if let url = URL(string: text) {
                NSWorkspace.shared.open(url, configuration: config) { _, _ in }
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                                configuration: config) { _, _ in }
    }
}


/// 首插配对：向手机发起经典蓝牙配对（手机上弹一次确认）。妙控配件式的第一次——
/// 之后系统里就有这台手机，拔线即无线。已配对时调用方不会走到这里。
final class BondAssist: NSObject, IOBluetoothDevicePairDelegate {
    private static nonisolated(unsafe) var current: BondAssist?
    private var completion: ((Bool, String) -> Void)?
    private var pair: IOBluetoothDevicePair?

    static func pair(address: String, then done: @escaping (Bool, String) -> Void) {
        let normalized = address.replacingOccurrences(of: ":", with: "-").lowercased()
        guard let device = IOBluetoothDevice(addressString: normalized) else {
            done(false, "构造设备对象失败"); return
        }
        guard let pair = IOBluetoothDevicePair(device: device) else {
            done(false, "IOBluetoothDevicePair 创建失败"); return
        }
        let ref = BondAssist()
        ref.completion = done
        ref.pair = pair
        current = ref
        pair.delegate = ref
        let status = pair.start()
        if status != kIOReturnSuccess {
            current = nil
            ref.pair = nil
            done(false, "start 失败（0x\(String(status, radix: 16))）")
        }
        // 60s 没结果就当失败收场（手机上没人点）
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak ref] in
            guard let ref, ref.completion != nil else { return }
            ref.finish(ok: false, "60s 没确认")
        }
    }

    func devicePairingStarted(_ sender: Any!) {
        Wireless.note("蓝牙配对：开始")
    }

    func devicePairingConnected(_ sender: Any!) {
        Wireless.note("蓝牙配对：已连接，等待手机确认")
    }

    /// iPhone 的 Secure Simple Pairing 会做数字比较。以前没实现这个委托，Mac 侧可能一直不回复，
    /// 手机上的配对窗就超时；这里自动接受 Mac 这一侧，手机上仍然需要用户点「配对」。
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        Wireless.note("蓝牙配对：自动确认 Mac 侧数字码（手机仍需点配对）")
        pair?.replyUserConfirmation(true)
    }

    /// 传统 PIN 配对：回一个固定 PIN，避免 Mac 侧静默超时。内容不打印。
    func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin.data) { raw in
            raw[0] = 0x30; raw[1] = 0x30; raw[2] = 0x30; raw[3] = 0x30   // "0000"
        }
        pair?.replyPINCode(4, pinCode: &pin)
        Wireless.note("蓝牙配对：已回复 Mac 侧 PIN（手机仍需确认）")
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        Wireless.note("蓝牙配对：请在 iPhone 上输入显示的 passkey")
    }

    func deviceSimplePairingComplete(_ sender: Any!, status: BluetoothHCIEventStatus) {
        Wireless.note("蓝牙配对：SSP 完成（status \(status)）")
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        finish(ok: error == kIOReturnSuccess, "0x\(String(error, radix: 16))")
    }

    private func finish(ok: Bool, _ detail: String) {
        completion?(ok, detail)
        completion = nil
        pair = nil
        Self.current = nil
    }
}

/// 让系统重查一台设备的 SDP 记录（照 MacPlay：iAP2 服务记录可能过期，刷新后再 locate）。
/// 完成回调是 target 上的 -sdpQueryComplete:status:（IOBluetooth 没有正式协议）；20s 兜底（MacPlay 25s）。
final class SDPRefresh: NSObject {
    private static nonisolated(unsafe) var current: SDPRefresh?
    private var completion: (() -> Void)?

    static func refresh(address: String, then done: @escaping () -> Void) {
        let normalized = address.replacingOccurrences(of: ":", with: "-").lowercased()
        guard let device = IOBluetoothDevice(addressString: normalized) else { done(); return }
        let ref = SDPRefresh()
        ref.completion = done
        current = ref
        device.performSDPQuery(ref, uuids: [Iap2BluetoothAccessory.iap2ServiceUUID])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak ref] in
            guard let ref, ref.completion != nil else { return }
            ref.fire()
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { fire() }
    private func fire() {
        completion?()
        completion = nil
        Self.current = nil
    }
}

/// Iap2MfiIdentity → 会话 auth-setup 要的签名器（协议 3：对 SHA-256 摘要签名，64 字节 r||s）
struct MfiSigner: AccessorySigner {
    let identity: Iap2MfiIdentity
    var certificate: [UInt8] { identity.certificate }
    func sign(_ digest: [UInt8]) throws -> [UInt8] { try identity.sign(digest: digest) }
}

/// USB 侧的网络面：手机的 CarPlay AV 网口（macOS 自己绑的 AppleUSBNCMData enX，按序列号找），
/// 照 MacPlay iap2-wired/mac_network.rs 的做法解析 ioreg。
enum UsbNet {
    /// 这台 iPhone 的 AppleUSBNCMData 接口（enX）。通常是两个，AV 用第一个。
    /// 呼叫它的地方在主執行緒上的 iAP2 訊息處理裡，而 ioreg 是外部程序：只讀背景快照。
    static func ncmInterfaces(udid: String) -> [String] {
        NcmSnapshot.shared.interfaces(for: udid)
    }

    fileprivate static func probeNcmInterfaces(udid: String) -> [String] {
        let want = udid.lowercased().filter { $0.isLetter || $0.isNumber }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-n", "iPhone", "-l", "-w", "0"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        // ioreg 会带 MAC 地址等原始字节（如 IOMACAddress = <"R;p\x90 0d">），整段不是合法
        // UTF-8；严格 UTF-8 解码会一步返回 nil，把「有网口」误判成「没有」。
        // 用 Latin-1 无损解码（每个字节都有映射），与 MacPlay from_utf8_lossy 的语义一致。
        // 真机样本 2026-10-19：新 iPhone 的 MAC 含 0x90/0xb1，旧 SE 碰巧全是 ASCII。
        guard p.terminationStatus == 0,
              let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .isoLatin1) else { return [] }
        for block in text.components(separatedBy: "+-o iPhone@").dropFirst() {
            func quoted(_ line: String, _ key: String) -> String? {
                guard let r = line.range(of: "\"\(key)\" = \"") else { return nil }
                return String(line[r.upperBound...].prefix { $0 != "\"" })
            }
            let lines = block.components(separatedBy: "\n")
            let serial = lines.first { quoted($0, "USB Serial Number") != nil }.flatMap { quoted($0, "USB Serial Number") }
            guard serial?.lowercased().filter({ $0.isLetter || $0.isNumber }) == want else { continue }
            var ifaces: [String] = []
            var underNcm = false
            for line in lines {
                switch quoted(line, "IOClass") {
                case "AppleUSBNCMData", "AppleUSBNCM11Data": underNcm = true
                case "AppleUSBEthernetHostAQM": underNcm = false
                default: break
                }
                if underNcm, let name = quoted(line, "BSD Name") {
                    ifaces.append(name)
                    underNcm = false
                }
            }
            return ifaces
        }
        return []
    }

    /// ioreg 一次几十到几百毫秒，而调用点都在主执行绪的 iAP2 讯息处理里。
    /// 背景每 0.5 秒刷一次快照，调用端只做一次加锁读取（最多旧半秒，够用）。
    fileprivate final class NcmSnapshot {
        static let shared = NcmSnapshot()
        private let queue = DispatchQueue(label: "homeplay.ncm", qos: .utility)
        private let lock = NSLock()
        private var byUDID: [String: [String]] = [:]
        private var timer: DispatchSourceTimer?
        private var watching = ""
        private var lastRequest: Double = 0

        func interfaces(for udid: String) -> [String] {
            let key = Self.key(udid)
            lock.lock(); let hit = byUDID[key]; lastRequest = CACurrentMediaTime(); lock.unlock()
            start(udid)
            return hit ?? []
        }

        private static func key(_ udid: String) -> String {
            udid.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        /// 只监视当前这台：换机时重建计时器，旧机的值留在字典里也没人再读。
        private func start(_ udid: String) {
            lock.lock()
            let changed = watching != udid
            if changed { watching = udid }
            lock.unlock()
            guard changed else { return }
            queue.async { [self] in
                lock.lock(); timer?.cancel(); lock.unlock()
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(200))
                t.setEventHandler { [weak self] in
                    guard let self else { return }
                    // 没人再问了（有线会话结束）就停下来：ioreg 是外部程序，不能让它常驻轮询。
                    self.lock.lock()
                    let idle = CACurrentMediaTime() - self.lastRequest > 30
                    if idle { self.timer?.cancel(); self.timer = nil; self.watching = "" }
                    self.lock.unlock()
                    guard !idle else { return }
                    let value = UsbNet.probeNcmInterfaces(udid: udid)
                    self.lock.lock(); self.byUDID[Self.key(udid)] = value; self.lock.unlock()
                }
                lock.lock(); timer = t; lock.unlock()
                t.resume()
            }
        }
    }

    /// 接口的 IPv6 链路本地地址（fe80::），有线 AV 回连靠它。
    static func linkLocalV6(_ iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0 }
            var addr = sin6.pointee.sin6_addr
            if inet_ntop(AF_INET6, &addr, &host, socklen_t(INET6_ADDRSTRLEN)) != nil {
                return String(cString: host)
            }
        }
        return nil
    }
}

enum Touch {
    /// {"type":"touch","contacts":[{"id":0,"x":..,"y":..,"down":..}]} → 第一个触点
    static func parse(_ text: String) -> (x: Double, y: Double, down: Bool)? {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["type"] as? String == "touch",
              let c = (o["contacts"] as? [[String: Any]])?.first,
              let x = (c["x"] as? NSNumber)?.doubleValue, let y = (c["y"] as? NSNumber)?.doubleValue else { return nil }
        return (min(1, max(0, x)), min(1, max(0, y)), (c["down"] as? Bool) ?? false)
    }
}

enum NetInfo {
    static func ipv4(_ iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
    /// 链路本地 IPv6（fe80::/10），无线回连的备用地址；去掉 %scope，和 MacPlay 发给手机的格式一致。
    static func linkLocalIPv6(_ iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let full = String(cString: host)
            let addr = full.split(separator: "%").first.map(String.init) ?? full
            let p3 = addr.lowercased().prefix(3)
            if ["fe8", "fe9", "fea", "feb"].contains(p3) { return addr }
        }
        return nil
    }

    /// Wi-Fi 网卡先问 CoreWLAN（getifaddrs 的 AF_LINK 在新系统上会给 02:00:00:00:00:00 的遮罩值）
    static func mac(_ iface: String) -> String? {
        if let hw = CWWiFiClient.shared().interface(withName: iface)?.hardwareAddress(), !hw.hasPrefix("02:00:00") {
            return hw.uppercased()
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
                let len = Int(dl.pointee.sdl_alen), off = Int(dl.pointee.sdl_nlen)
                guard len == 6 else { return nil }
                let bytes = withUnsafeBytes(of: dl.pointee.sdl_data) { Array($0) }
                guard off + 6 <= bytes.count else { return nil }
                return bytes[off..<(off + 6)].map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
        return nil
    }
}

/// 桌寵螢幕幾何的單一來源（與 main.swift 的屏幕平面同源）。
/// viewArea＝整塊面板（0 內縮）；safeArea＝圓角裡的最大內接矩形（origin 就是內縮量）；
/// 畫到 safeArea 外（safeAreaDrawOutside）只讓背景鋪到邊，互動內容仍留在 safeArea。
/// 四個環境變量可在真機上直接實驗宣告組合，免重編譯：
///   HOMEPLAY_VIEW_INSET=px   HOMEPLAY_SAFE_INSET=px（設 0 試全幅）
///   HOMEPLAY_PHYS_MM=mm      HOMEPLAY_DRAW_OUTSIDE=0 關掉背景外畫
enum PetDisplay {
    static let modelWidth: Double = 13.15       // 屏幕平面寬（模型單位）
    static let cornerRadius: Double = 1.475     // 與面板同心推出來的值

    static func radiusPx(_ widthPx: Int) -> Double { Double(widthPx) * cornerRadius / modelWidth }
    /// 最大內接矩形每邊內縮：r·(1 − 1/√2)
    static func safeInset(_ widthPx: Int) -> Int {
        Int((radiusPx(widthPx) * (1 - 1 / 2.0.squareRoot())).rounded(.up))
    }

    private static func envInt(_ key: String) -> Int? {
        ProcessInfo.processInfo.environment[key].flatMap { Int($0) }
    }

    static func apply(_ main: inout DisplayConfig) {
        let v = envInt("HOMEPLAY_VIEW_INSET") ?? 0
        main.viewArea = DisplayInsets(top: v, bottom: v, left: v, right: v)
        let s = envInt("HOMEPLAY_SAFE_INSET") ?? safeInset(main.widthPixels)
        main.safeArea = DisplayInsets(top: s, bottom: s, left: s, right: s)
        main.safeAreaDrawOutside = ProcessInfo.processInfo.environment["HOMEPLAY_DRAW_OUTSIDE"] != "0"
        if let mm = envInt("HOMEPLAY_PHYS_MM"), mm > 0, main.widthPixels > 0 {
            main.widthPhysicalMm = mm
            main.heightPhysicalMm = mm * main.heightPixels / main.widthPixels
        }
    }

    /// 開場日誌用：把實際宣告寫清楚（含環境覆蓋後的值），方便和手機行為對照
    static func describe(_ widthPx: Int, _ heightPx: Int) -> String {
        let v = envInt("HOMEPLAY_VIEW_INSET") ?? 0
        let i = envInt("HOMEPLAY_SAFE_INSET") ?? safeInset(widthPx)
        let outside = ProcessInfo.processInfo.environment["HOMEPLAY_DRAW_OUTSIDE"] != "0"
        let mm = envInt("HOMEPLAY_PHYS_MM") ?? 125
        return "display viewArea=(\(v),\(v) \(widthPx - 2*v)x\(heightPx - 2*v)) safeArea=(\(i),\(i) \(widthPx - 2*i)x\(heightPx - 2*i)) origin=(\(i),\(i)) drawOutside=\(outside) phys=\(mm)mm radius=\(Int(radiusPx(widthPx)))px"
    }
}
