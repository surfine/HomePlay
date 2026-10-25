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
import IOKit
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

    /// 诊断报告用的英文安全类型名（不含凭据）
    static func securityLabelEN(_ s: Iap2Csm.WiFiSecurity) -> String {
        switch s {
        case .none: return "open"
        case .wep: return "WEP"
        case .wpaWpa2: return "WPA2"
        case .wpa3Transition: return "WPA2/WPA3"
        case .wpa3Only: return "WPA3-only"
        }
    }
    static func bandLabel(_ b: CWChannelBand?) -> String {
        switch b {
        case .band2GHz?: return "2.4 GHz"
        case .band5GHz?: return "5 GHz"
        case .band6GHz?: return "6 GHz"
        default: return ""
        }
    }

    /// macOS 应用程序防火墙的唯读查询（不用管理员权限）。路径是接收器自己的执行档。
    /// iPhone 从 Wi-Fi 连回控制口是「传入连接」：防火墙开着又拒绝了它（或「阻止所有传入连接」），手机永远连不进来。
    static func firewallState(executable: String) -> ConnectDiagnostics.Firewall? {
        func run(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
            p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }   // 卡住就放棄，不留執行緒
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }
        guard let global = run(["--getglobalstate"]) else { return nil }
        return .parse(global: global, blockAll: run(["--getblockall"]) ?? "",
                      app: run(["--getappblocked", executable]) ?? "", stealth: run(["--getstealthmode"]) ?? "")
    }

    /// 本机自己连控制口（端口自检/健康探测）不能当成手机回连：否则 0x4301 重试会被误停，
    /// 手机真正入网后反而等不到 0x4301（2026-10-20 实测：nc -z 触发过这个误判）。
    static func isSelfAddress(_ host: String, iface: String) -> Bool {
        if host == "127.0.0.1" || host == "::1" || host == "localhost" { return true }
        if NetInfo.allIPv4().contains(where: { NetInfo.text($0.addr) == host }) { return true }
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
    /// 原地换一个全新的行程映像（同一个 PID，launchd 看不到退出）：不必等 launchd 的 10 秒重启节流
    ///（真机 2026-10-24 05:12：exit 后 10.5 秒才被拉起）。先把所有描述符设成 exec 时关闭，
    /// 新映像才能重新绑定控制口与 WebSocket 口；exec 失败就照旧 exit(1) 交给 launchd。
    static func reexec() -> Never {
        // POSIX_SPAWN_SETEXEC＝像 exec 一样原地替换；CLOEXEC_DEFAULT＝除了下面明说继承的 0/1/2，其余描述符一律关掉（原子，不怕别的线程刚开新的）
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        let args = CommandLine.arguments
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var env = ProcessInfo.processInfo.environment
        env["HOMEPLAY_REEXEC"] = "1"   // 新映像绑端口失败时要 exit(1) 让 launchd 拉起，不能 exit(0) 就此停摆
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, args[0], &actions, &attr, &argv, &envp)
        note("原地重启失败（\(rc)），交给 launchd")
        exit(1)
    }
    /// 端口被占时的退出码：原地重启出来的映像（可能是残留连线占着）要让 launchd 再拉一次
    static var portInUseExitCode: Int32 { ProcessInfo.processInfo.environment["HOMEPLAY_REEXEC"] == nil ? 0 : 1 }
    /// 接收器在跑的记号：起来时写、正常结束（shutdown）时删；下次起来还在＝上次被硬杀
    static let runningMarker = HomePlayState.directory.appendingPathComponent("receiver-running")
    /// 「行程刚起来就连不上 → 再重启一次」的节流：2 分钟一次（存盘，重启也记得）
    static func youngRestartAllowed() -> Bool {
        guard getppid() == 1 else { return false }   // 只有 launchd 拉起的才会被拉回来
        let url = HomePlayState.directory.appendingPathComponent("young-restart.stamp")
        let now = Date().timeIntervalSince1970
        if let t = (try? String(contentsOf: url, encoding: .utf8)).flatMap(Double.init), now - t < 120 { return false }
        try? String(now).write(to: url, atomically: true, encoding: .utf8)
        return true
    }
    /// 这台手机的蓝牙基带连着没有（连着＝人就在旁边，只是一时没回；没连＝多半不在）
    static func isBasebandConnected(_ address: String) -> Bool {
        IOBluetoothDevice(addressString: address.replacingOccurrences(of: ":", with: "-").lowercased())?.isConnected() ?? false
    }
    /// 旁边（蓝牙基带已连着）的另一台已配对 iPhone：指定的手机连不上时改连它
    static func nearbyOtherPhone(excluding address: String) -> (address: String, name: String)? {
        let me = PairingRules.normalize(address)
        for phone in Iap2BluetoothAccessory.pairedPhones() where PairingRules.normalize(phone.address) != me {
            let dashed = phone.address.replacingOccurrences(of: ":", with: "-").lowercased()
            if let d = IOBluetoothDevice(addressString: dashed), d.isConnected() { return (phone.address, phone.name) }
        }
        return nil
    }

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
    static func wifiHelpPayload(ssid: String, passphraseMissing: Bool, reason: String? = nil) -> String? {
        var payload: [String: Any] = ["type": "wifiHelp", "ssid": ssid]
        if passphraseMissing { payload["passphraseMissing"] = true }
        if let reason { payload["reason"] = reason }   // ConnectDiagnostics.Reason：桌寵按它選文案
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func wifiInfoPayload(ssid: String) -> String? {
        let payload: [String: Any] = ["type": "wifiInfo", "ssid": ssid]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// cable＝手机正插着线等配对：桌宠多一句「不想现在配，60 秒后先用有线」
    static func pairingHintPayload(host: String, stale: Bool = false, cable: Bool = false) -> String? {
        let payload: [String: Any] = ["type": "needPairing", "host": host, "stale": stale, "cable": cable]
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

    /// 插线配对的进度，给桌宠画引导卡片。phase：
    /// request＝已向 iPhone 发出配对请求（host＝它在 iPhone 上看到的这台 Mac 的名字）；
    /// confirm＝两边进入数字比对，code＝两边应显示的 6 位数字，iPhone 上点「配对」；
    /// retry＝第一次叫不到手机，几秒后再叫一次。timeout＝这一轮还剩几秒。
    static func bluetoothPairingPayload(phase: String = "request", code: String? = nil, timeout: Int? = nil, host: String? = nil) -> String? {
        var d: [String: Any] = ["type": "bluetoothPairing", "phase": phase]
        if let code { d["code"] = code }
        if let timeout { d["timeout"] = timeout }
        if let host { d["host"] = host }
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 插线配对没成。reason：noResponse＝叫不到手机（藍牙关着、没解锁、离太远）；
    /// notConfirmed＝手机上没点「配对」（或点了取消）；other＝其他错误。
    static func bluetoothPairFailedPayload(reason: String = "other") -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "bluetoothPairFailed", "reason": reason]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 「忘记 iPhone」的结果：macRemoved＝Mac 的系统藍牙配对确实删掉了（同一 Apple ID 的 iPhone 或系统拒绝时会删不掉）。
    /// iPhone 那头一定要用户自己在「设置 › 通用 › CarPlay」忘记这台车，桌宠据此列出还要做的步骤。
    static func phoneForgottenPayload(address: String, name: String?, macRemoved: Bool) -> String? {
        var d: [String: Any] = ["type": "phoneForgotten", "address": address, "macRemoved": macRemoved]
        if let name { d["name"] = name }
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
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
        HomePlayState.directory.appendingPathComponent("wireless.json")
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
        HomePlayState.directory.appendingPathComponent("usb-phones.json")
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

    /// iPhone 分享來的 Wi-Fi 記到 wireless.json（0600）；檔案不存在就新建。密碼不寫日誌
    static func persistWiFi(ssid: String, passphrase: String) {
        let url = configURL
        var obj = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        obj["ssid"] = ssid
        obj["passphrase"] = passphrase
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { note("記 Wi-Fi 到 wireless.json 失敗：\(error.localizedDescription)") }
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
        let url = HomePlayState.directory.appendingPathComponent("carplay-video.json")
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return true }
        return (o["allowed"] as? Bool) ?? true
    }
    /// 手機要播／暫停／跳轉／停 → 轉給桌寵的播放器
    /// 圓角記憶或策略變了、要照新宣告重開會話（runDual 接上；其他模式下次連線才生效）
    nonisolated(unsafe) static var cornerChanged: ((String) -> Void)?
    /// 正在直播的手機換了：重發手機清單（runDual 接上）
    nonisolated(unsafe) static var phonesChanged: (() -> Void)?
    /// 主會話開始／結束（runDual 的待命連線用來判斷穩不穩）
    nonisolated(unsafe) static var liveSinceHook: (() -> Void)?
    nonisolated(unsafe) static var liveEndedHook: (() -> Void)?
    /// 立刻重開會話（runDual 接上）
    nonisolated(unsafe) static var reopenNow: ((String) -> Void)?
    /// 這次學習連線收到遮罩了沒（等不到就當這版不送）
    nonisolated(unsafe) static var maskSeen = false
    /// 最後一份圓角遮罩訊息：桌寵晚連上（重開）時補送
    nonisolated(unsafe) static var lastCornerMask: String?

    static func wireCarVideo(_ s: CarPlaySession, server: WSServer) {
        s.onPhoneBuild = { build in
            maskSeen = false
            guard let m = PetDisplay.observe(build: build) else { return }
            note(m)
            // 換了手機：在 SETUP 當中就換成這台的宣告（同步，跑在會話佇列上）。手機接著才讀 /info，所以不必重開會話；
            // 沒量過的手機，這次 SETUP 就直接成為學圓角的連線。2026-10-23 17:00 真機：SETUP 當中硬重開，iOS 15 要 40 秒才回來
            var d = s.config.info.main
            PetDisplay.apply(&d)
            guard PetDisplay.key(d) != PetDisplay.key(s.config.info.main) else { return }
            s.updateMainDisplay(d)
            note("這台手機的宣告：\(PetDisplay.key(d))（SETUP 當中就換，/info 照新的回）")
        }
        s.onCornerMask = { negotiated, png in
            note("cornerMask 訊息：session \(ObjectIdentifier(s).hashValue % 10000) negotiated=\(negotiated) png=\(png?.count ?? 0)B learning=\(s.config.info.main.cornerMasks == true) phys=\(s.config.info.main.widthPhysicalMm ?? 0)mm")
            // learning：這次連線是不是「學圓角」的那一次（宣告了 cornerMasks、沒有安全區）；不是的話桌寵原樣直通
            var d: [String: Any] = ["type": "cornerMask", "negotiated": negotiated, "learning": s.config.info.main.cornerMasks == true]
            if negotiated == false, s.config.info.main.cornerMasks == true {
                note(PetDisplay.markNoMask())   // 學習連線但手機沒提議 cornerMasks（舊 iOS）
                DispatchQueue.main.async { cornerChanged?("這版 iOS 不送圓角") }
            }
            if let png {
                d["png"] = png.base64EncodedString()
                maskSeen = true
                note(PetDisplay.learn(png: png, widthPx: s.config.info.main.widthPixels))
                DispatchQueue.main.async { cornerChanged?("圓角量好了") }
                // 診斷：留一份這次 iOS 送來的圓角遮罩
                let url = HomePlayState.directory.appendingPathComponent("carplay-corner-mask.png")
                try? png.write(to: url, options: .atomic)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) else { return }
            // 只協商、還沒送圖：不要蓋掉同一次連線稍後送來的圖
            if png != nil || lastCornerMask == nil || !negotiated || !(d["learning"] as? Bool ?? false) { lastCornerMask = text }
            server.broadcastText(text)
        }
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
        try? FileManager.default.removeItem(at: runningMarker)
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
            if let m = Wireless.lastCornerMask { server.sendText(m, to: conn) }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Wireless.reexec() }
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
        if o.phoneAddress == nil {
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
    /// 进入数字比对时把 6 位数字交给调用方（桌宠显示，让用户和 iPhone 上的核对）
    static nonisolated(unsafe) var onConfirmCode: ((String) -> Void)?
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
        Self.onConfirmCode?(String(format: "%06u", numericValue))
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
    /// 同时可以有好几个在跑（以前只有一个槽位，第二个会让第一个的 completion 永远不来）
    private static nonisolated(unsafe) var inflight: [SDPRefresh] = []
    private var completion: (() -> Void)?

    static func refresh(address: String, timeout: TimeInterval = 20, then done: @escaping () -> Void) {
        let normalized = address.replacingOccurrences(of: ":", with: "-").lowercased()
        guard let device = IOBluetoothDevice(addressString: normalized) else { done(); return }
        let ref = SDPRefresh()
        ref.completion = done
        inflight.append(ref)
        device.performSDPQuery(ref, uuids: [Iap2BluetoothAccessory.iap2ServiceUUID])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak ref] in
            guard let ref, ref.completion != nil else { return }
            ref.fire()
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { fire() }
    private func fire() {
        let done = completion
        completion = nil
        Self.inflight.removeAll { $0 === self }
        done?()
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
    /// USB 匯流排上有幾台 iPhone（只看 IOUSBHostDevice 的產品名，不讀序號）。
    /// usbmuxd 看不到、這裡卻有＝有電沒資料：鎖著（USB 限制模式）、沒點「允許」、或線／擴充座只供電。
    static func iPhonesOnBus() -> Int {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(it) }
        var n = 0
        while true {
            let s = IOIteratorNext(it)
            guard s != 0 else { break }
            defer { IOObjectRelease(s) }
            if let name = IORegistryEntryCreateCFProperty(s, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               name == "iPhone" { n += 1 }
        }
        return n
    }

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
    /// 本机所有 IPv4（网卡名 → 地址、掩码），跳过回环与 169.254 链路本地（USB NCM 那种）
    static func allIPv4() -> [(iface: String, addr: in_addr, mask: in_addr)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var out: [(String, in_addr, in_addr)] = []
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  a.pointee.ifa_flags & UInt32(IFF_UP) != 0, a.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let nm = a.pointee.ifa_netmask else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if UInt32(bigEndian: addr.s_addr) >> 16 == 0xA9FE { continue }   // 169.254/16
            out.append((String(cString: a.pointee.ifa_name), addr, mask))
        }
        return out
    }
    static func text(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)).map { String(cString: $0) } ?? ""
    }
    /// 内核往这个地址发包时会用的本机来源 IPv4（UDP connect 不发任何封包，只查路由）
    static func sourceIPv4(toward host: in_addr) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(9).bigEndian; dst.sin_addr = host
        let ok = withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return nil }
        var me = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &me, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }) == 0 else { return nil }
        return text(me.sin_addr)
    }
    /// 无线版 0x4301 要给手机的地址，按优先顺序。Mac 同时有有线和 Wi-Fi、而且在同一个网段时
    ///（真机 2026-10-24：en5 2.5G 网卡 192.168.5.25 ＋ en0 Wi-Fi 192.168.5.9，路由走 en5），
    /// 手机连 Wi-Fi 那个地址的话，进来走 Wi-Fi、Mac 回包却从有线出去，同一个 IP 在网上对应两个 MAC。
    /// 所以先给内核往这个网段回包时真正会用的来源地址（进出同一张网卡），再给 Wi-Fi 的，再给其他同网段的。
    static func lanAddresses(wifi iface: String) -> [String] {
        let all = allIPv4()
        guard let w = all.first(where: { $0.iface == iface }) else { return all.first.map { [text($0.addr)] } ?? [] }
        let net = w.addr.s_addr & w.mask.s_addr
        var probe = in_addr(s_addr: net | UInt32(2).bigEndian)   // 网段里的一个地址，只拿来查路由
        if probe.s_addr == w.addr.s_addr { probe.s_addr = net | UInt32(3).bigEndian }
        var out: [String] = []
        if let src = sourceIPv4(toward: probe), all.contains(where: { text($0.addr) == src }) { out.append(src) }
        out.append(text(w.addr))
        for x in all where x.addr.s_addr & w.mask.s_addr == net { out.append(text(x.addr)) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
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
    /// 機身螢幕的圓角：顯示面網格（apple-homeview.usdz 的 RFkcSjAtJLGqwDA）在 UV 裡對角線方向的內縮，佔寬度。
    /// 是 Apple 那種連續曲率的角，等效半徑 ≈ 寬度的 13.6%（1088 px 上約 148 px）。
    static let bodyDiag = 0.0398
    /// iOS 的螢幕圓角（遮罩對角內縮 ÷ 寬度）：沒量過時的估計（2026-10-23 iOS 27 截圖反推）
    static let defaultMaskDiag = 0.019

    static func radiusPx(_ widthPx: Int) -> Double { Double(widthPx) * bodyDiag / CornerMaskProtocol.diagPerRadius }
    /// 最大內接矩形每邊內縮（舊做法：只保證 UI 不被圓角切到）
    static func safeInset(_ widthPx: Int) -> Int { Int((Double(widthPx) * bodyDiag).rounded(.up)) }

    /// 每台手機（iOS 版本）量到的圓角（carplay-corner.json）
    static var storeURL: URL {
        HomePlayState.directory.appendingPathComponent("carplay-corner.json")
    }
    static var memory: CornerMemory {
        get {
            guard let d = try? Data(contentsOf: storeURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return CornerMemory() }
            return CornerMemory(json: o)
        }
        set {
            var o = newValue.json
            // 給設定頁看的：這台手機目前每邊內收多少
            if case .inset(let px) = newValue.plan(style: style, widthPx: 1088, bodyDiag: bodyDiag) { o["appliedInset"] = px }
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]) { try? d.write(to: storeURL, options: .atomic) }
        }
    }
    /// 圓角策略：carplay-display.json 的 cornerStyle；舊的 concentric:false＝最大畫面
    static var style: CornerStyle {
        if let raw = fileValue("cornerStyle") as? String, let s = CornerStyle(rawValue: raw) { return s }
        if (fileValue("concentric") as? Bool) == false { return .maximize }
        return .concentric
    }
    /// SETUP 看到手機版本：記成「最近的手機」；回傳日誌（換了手機才有）
    static func observe(build: String) -> String? {
        var m = memory
        guard m.lastBuild != build else { return nil }
        let old = m.lastBuild ?? "-"
        m.lastBuild = build; memory = m
        return "手機版本 \(old) → \(build)（圓角\(m.current.map { $0 > 0 ? String(format: "已量過 %.4f W", $0) : "：這版不送遮罩" } ?? "沒量過")）"
    }
    /// 收到遮罩：量、按目前手機版本存；回傳日誌
    static func learn(png: Data, widthPx: Int) -> String {
        guard let px = CornerMaskProtocol.diagonalInset(png: png), widthPx > 0 else { return "圓角遮罩量不出來" }
        var m = memory
        let build = m.lastBuild ?? "unknown"
        m.masks[build] = px / Double(widthPx); memory = m
        let next = CornerMaskProtocol.concentricInset(widthPx: widthPx, bodyDiag: bodyDiag, maskDiag: px / Double(widthPx))
        return String(format: "圓角遮罩（%@）：對角內縮 %.1f px（%.4f W）→ 同心安全區 %d px", build, px, px / Double(widthPx), next)
    }
    /// 這一版 iOS 不送遮罩（沒提議 cornerMasks、或學習連線裡等不到）：記成 0，照最大畫面處理，不再學
    static func markNoMask() -> String {
        var m = memory
        let build = m.lastBuild ?? "unknown"
        m.masks[build] = 0; memory = m
        return "手機（\(build)）不送圓角遮罩：照最大畫面內收，之後不再學"
    }

    static func fileValue(_ key: String) -> Any? {
        guard let d = try? Data(contentsOf: HomePlayState.directory.appendingPathComponent("carplay-display.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o[key]
    }
    private static func envInt(_ key: String) -> Int? {
        ProcessInfo.processInfo.environment[key].flatMap { Int($0) }
    }

    static func apply(_ main: inout DisplayConfig) {
        // 物理尺寸：環境變數，或 carplay-display.json 的 physMm（實驗：iOS 的圓角遮罩是不是照毫米算）
        let fileMm: Int? = {
            guard let d = try? Data(contentsOf: HomePlayState.directory.appendingPathComponent("carplay-display.json")),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return (o["physMm"] as? NSNumber)?.intValue
        }()
        if let mm = envInt("HOMEPLAY_PHYS_MM") ?? fileMm, mm > 0, main.widthPixels > 0 {
            main.widthPhysicalMm = mm
            main.heightPhysicalMm = mm * main.heightPixels / main.widthPixels
        }
        let v = envInt("HOMEPLAY_VIEW_INSET") ?? 0
        main.viewArea = DisplayInsets(top: v, bottom: v, left: v, right: v)
        main.safeAreaDrawOutside = ProcessInfo.processInfo.environment["HOMEPLAY_DRAW_OUTSIDE"] != "0"
        // 圓角策略（設定 › CarPlay › 圓角）。同心：安全區內縮到「iOS 的螢幕圓角放上去正好跟機身同心」，
        // iOS 自己把桌布畫滿到機身邊、圖示和 Dock 往內收。iOS 的圓角每一版不同，按手機版本記：
        // 沒量過的手機，這一次連線改宣告 cornerMasks（不能同時帶安全區，手機會立刻斷），手機送來遮罩、量好，
        // 接收器立刻重開會話回到平常模式（runDual 的 reopen），整段約 2–3 秒。
        var plan = memory.plan(style: style, widthPx: main.widthPixels, bodyDiag: bodyDiag)
        if case .learn = plan, ProcessInfo.processInfo.environment["HOMEPLAY_CORNER_MASKS"] == "0" { plan = .inset(safeInset(main.widthPixels)) }
        switch plan {
        case .learn:
            main.cornerMasks = true; main.safeArea = nil
        case .inset(let px):
            let s = envInt("HOMEPLAY_SAFE_INSET") ?? px
            main.cornerMasks = nil
            main.safeArea = DisplayInsets(top: s, bottom: s, left: s, right: s)
        }
    }
    /// 宣告裡跟圓角有關的部分（比對要不要重開會話用）
    static func key(_ d: DisplayConfig) -> String { "\(d.cornerMasks == true)|\(d.safeArea?.left ?? -1)" }

    /// 開場日誌用：把實際宣告寫清楚（含環境覆蓋後的值），方便和手機行為對照
    static func describe(_ widthPx: Int, _ heightPx: Int) -> String {
        let v = envInt("HOMEPLAY_VIEW_INSET") ?? 0
        var probe = DisplayConfig(widthPixels: widthPx, heightPixels: heightPx); apply(&probe)
        let i = probe.safeArea?.left ?? 0
        let outside = ProcessInfo.processInfo.environment["HOMEPLAY_DRAW_OUTSIDE"] != "0"
        let mm = probe.widthPhysicalMm ?? 125
        let cm = probe.cornerMasks == true
        return "display style=\(style.rawValue) cornerMasks=\(cm) phone=\(memory.lastBuild ?? "-") viewArea=(\(v),\(v) \(widthPx - 2*v)x\(heightPx - 2*v)) safeArea=(\(i),\(i) \(widthPx - 2*i)x\(heightPx - 2*i)) origin=(\(i),\(i)) drawOutside=\(outside) phys=\(mm)mm radius=\(Int(radiusPx(widthPx)))px"
    }
}
