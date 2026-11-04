import AppKit
import ApplicationServices
import AVFoundation
import Metal
import RealityKit
import Combine
import simd
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO
import IOKit.ps
import IOKit.hid
import Carbon.HIToolbox
import Network
import EventKit
import ServiceManagement
import Security

// MARK: - App

// MARK: - 拉起 receiver（重按进 CarPlay 用）
/// 参数读 ~/Library/Application Support/HomePlay/wireless.json（phone、ssid、size、port）；
/// Wi-Fi 密码不需要：iPhone 与 Mac 同网时直接连；特殊网络用 HOMEPLAY_WIFI_PASSPHRASE 显式提供。
/// pet 退出时一并结束自己拉起的 receiver；端口探测避免重复起。
enum ReceiverLauncher {
    enum Result { case ok; case noBinary(String) }

    struct Config: Codable {
        /// 留空＝蓝牙自动匹配（扫已配对设备的 iAP2 服务，iPhone 的签名）
        var phone: String = ""
        var ssid: String = ""
        /// iPhone 所连 Wi-Fi 的密码；只在本地 wireless.json（0600），不进命令行/日志
        var passphrase: String = ""
        var size: String = "1088x1088"
        var port: Int = 8788
        /// wireless | usb | auto（默认 auto：插着线走有线，没插走无线）
        var source: String = "auto"
        /// 用户按「忘记 iPhone」后要忽略的地址；系统配对删不掉时至少让 HomePlay 不再尝试
        var ignoredPhones: [String] = []
    }

    private static nonisolated(unsafe) var process: Process?
    private static nonisolated(unsafe) var launching = false
    private static nonisolated(unsafe) var lastLaunch: Date?

    /// 配置里的 WS 口（默认 8788）；拉起、探测、连接都用它，避免配置改了端口却还连旧口
    static func port() -> Int {
        (try? JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL())))?.port ?? 8788
    }

    /// 桌宠退出时把自己拉起的 receiver 一起结束；launchd 拉起的（process 为 nil）不动
    static func stop() {
        guard let p = process, p.isRunning else { process = nil; return }
        p.terminate()
        process = nil
    }

    static func configURL() -> URL {
        HomePlayState.directory.appendingPathComponent("wireless.json")
    }

    static func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: configURL()),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    /// 后台 LaunchAgent 先于桌宠拉起 receiver 时也要有一份配置（receiver 学到的手机才能落盘）。
    static func ensureConfigFile() {
        let url = configURL()
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(Config()).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 配置里有 Wi-Fi 密码：只写本机文件、权限 0600；receiver 启动时直接读，不进命令行/日志。
    static func writeConfig(_ cfg: Config) {
        let url = configURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(cfg).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log("写 wireless.json 失败（\(error.localizedDescription)）")
        }
    }

    /// 记住用户选定的 iPhone：下次拉起/登录用同一台（空串＝自动匹配）。
    static func savePhone(_ address: String) {
        var cfg = loadConfig()
        cfg.phone = address
        writeConfig(cfg)
    }

    static func saveWiFi(ssid: String, passphrase: String) {
        var cfg = loadConfig()
        cfg.ssid = ssid
        // 密码框留空＝保持已保存的密码（macOS 26 读不到钥匙串，别因为只改 SSID 就把密码擦掉）。
        if !passphrase.isEmpty { cfg.passphrase = passphrase }
        writeConfig(cfg)
    }

    static func forgetPhone(_ address: String) {
        var cfg = loadConfig()
        let normalized = CarPlayPhoneBook.normalize(address)
        if !cfg.ignoredPhones.contains(where: { CarPlayPhoneBook.normalize($0) == normalized }) {
            cfg.ignoredPhones.append(normalized)
        }
        if CarPlayPhoneBook.normalize(cfg.phone) == normalized { cfg.phone = "" }
        writeConfig(cfg)
    }

    static func restoreIgnoredPhones() {
        var cfg = loadConfig()
        cfg.ignoredPhones = []
        writeConfig(cfg)
    }

    /// receiver 可执行文件的候选位置（按优先级）。
    /// 打包后的 App 把接收器放在 Contents/Resources，而不是 Contents/MacOS：LaunchServices 会把
    /// Contents/MacOS 里的进程登记成整个 App（同一个 bundle id）。接收器由 launchd 常驻时，
    /// `open HomePlay.app` 就会以为“HomePlay 已在运行”而返回 -600，桌宠再也打不开。
    /// Resources 里的可执行文件不参与 App 登记（已用 lsappinfo 实测对照）。
    static func receiverBinaryCandidates() -> [URL] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        return [
            dir.deletingLastPathComponent().appendingPathComponent("Resources/homeplay-receiver"),
            dir.appendingPathComponent("homeplay-receiver"),   // .build/release 与桌宠同目录
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release/homeplay-receiver"),
        ]
    }

    static func receiverBinary() -> URL? {
        receiverBinaryCandidates().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func launch() -> Result {
        if launching { return .ok }          // 连按两下重压：只拉起一个 receiver
        if let last = lastLaunch, Date().timeIntervalSince(last) < 3, process?.isRunning == true { return .ok }
        lastLaunch = Date()
        launching = true
        defer { launching = false }
        guard let bin = receiverBinary() else {
            lastLaunch = nil
            return .noBinary(receiverBinaryCandidates().map(\.path).joined(separator: "、"))
        }
        let url = configURL()
        var cfg = Config()
        if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = c
        } else {   // 第一次：写一份模板。全部字段可留空＝自动（SSID 接收器自己取当前 Wi-Fi）
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(cfg).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let source = ["wireless", "usb", "auto"].contains(cfg.source) ? cfg.source : "auto"
        var args = ["--source", source, "--port", String(cfg.port), "--size", cfg.size,
                    "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        if !cfg.ssid.isEmpty { args += ["--ssid", cfg.ssid] }   // 留空＝自动取当前 Wi-Fi
        if !cfg.phone.isEmpty { args += ["--address", cfg.phone] }
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        let env = ProcessInfo.processInfo.environment
        // 不自動讀系統鑰匙圈（Wi-Fi 密碼在「系統」鑰匙圈，會彈管理員授權）。
        // CarPlay 無線交接需要 Wi-Fi 憑據；由用戶在右鍵「Wi-Fi 密碼…」填一次，存本地 0600。
        p.environment = env
        let logURL = url.deletingLastPathComponent().appendingPathComponent("receiver.log")
        // 控制日志体积：超过 2 MB 就清空（receiver 每条会话都会追写）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])   // 有 Wi-Fi 名稱與手機位址
        } else {
            chmod(logURL.path, 0o600)
        }
        var logHandle: FileHandle?
        if let h = FileHandle(forWritingAtPath: logURL.path) {
            h.seekToEndOfFile()
            p.standardOutput = h; p.standardError = h
            logHandle = h
        }
        do {
            try p.run()
            // 子进程已经 dup 了这条 fd：父进程这份要关掉，否则每拉起一次漏一个 fd。
            try? logHandle?.close()
            process = p
            return .ok
        } catch {
            try? logHandle?.close()
            log("receiver 拉起失败：\(error)")
            return .noBinary(bin.path)
        }
    }


}

/// 开机自启的 LaunchAgent：receiver 以 --source auto 常驻（RunAtLoad），
