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
        /// 登录项常驻（agent 拉起）：桌宠不在时停广播，闲置一段时间就退出，避免一直以车机身份出现
        var background = false
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
        if text.contains("\"type\":\"audio\"") {
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["command"] as? String == "callGain",
               let db = (obj["db"] as? NSNumber)?.floatValue {
                CallAudioSettings.setGain(db)
                note("通话音量 \(db) dB")
            }
            return
        }
        if text.contains("\"type\":\"siri\"") {
            let action = SiriAction.parse(text)
            note("触发 Siri（requestSiri \(action)）")
            s.requestSiri(action)
        }
        if text.contains("\"type\":\"knob\"") {
            if text.contains("\"command\":\"back\"") {
                note("桌宠 Esc → CarPlay 返回（旋钮 back）")
                s.sendKnob(KnobState(back: true))
            }
            return
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
    /// 退出前的额外清理（runDual 装的：停配对引导、恢复蓝牙可发现性）。
  /// shutdown 会被 SIGTERM、父进程看门狗、自愈 reexec、后台空闲退出调用——
  /// 引导期间打开的可发现性必须在每一条退出路径上都恢复，不能只在引导正常结束时。
  nonisolated(unsafe) static var onShutdown: (() -> Void)?

  /// 退出前等多久：让关通道、断基带的 XPC 送到 bluetoothd 并生效（原本 0.2–0.3 秒太短，留下孤儿通道）
  static let exitGrace: TimeInterval = 1.5

  static func shutdown() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { shutdown() }
            return
        }
        onShutdown?()
try? FileManager.default.removeItem(at: runningMarker)
        accessory?.close()
        // 关完通道再断这支手机的 ACL：强迫 bluetoothd 把它上面的 RFCOMM 一起拆掉。2026-10-30 系统日志：
        // 行程关通道后 0.2 秒就退出，bluetoothd 没拆那条 RFCOMM（没有 rfcommDisconnectedCb），留下没主人的连接
        // 与管线（之后开通道回 0x38f、或「Pipe 0x0102 is already registered」→ 0x76f），之后每次都连不上。
        if accessory?.dropBaseband() == true { note("退出前已断开到手机的基带，让 bluetoothd 收掉通道") }
        accessory = nil
        accessoryUsb?.close()
        accessoryUsb = nil
        beacon = nil
        session?.stop()
    }


    /// 三條路徑（無線／有線／雙模）共用的會話裝配：DisplayConfig→PetDisplay→InfoConfig→
    /// CarPlaySessionConfig→CarPlaySession→wireCarVideo。路徑間有差異的 config 欄位
    /// （phoneBluetoothAddress、probeForPhone）由呼叫方用 configure 補；／info 的取捨
    /// （hevc、影片、48k、音訊）三條路一致，收在這一份。
    static func makeSession(o: Options, server: WSServer, store: PairingStore, identity: Iap2MfiIdentity,
                            configure: (inout CarPlaySessionConfig) -> Void = { _ in }) -> (session: CarPlaySession, h264: H264Sink) {
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
        // 音频照实宣告（手机要求 /info 完整才会来要屏幕流；MacPlay 同款）；已能播（AAC/PCM），Opus/麦克风仍未接
        info.disableAudioOutput = false
        var cfg = CarPlaySessionConfig(info: info)
        cfg.port = o.controlPort
        cfg.advertiseIAPChannel = o.advertiseIAPChannel
        configure(&cfg)
        let s = CarPlaySession(config: cfg, store: store, signer: MfiSigner(identity: identity), sink: h264)
        wireCarVideo(s, server: server)
        return (s, h264)
    }
}
