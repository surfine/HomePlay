// LaunchAgent 管理——自 main.swift 拆出。
import Accelerate
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

enum ReceiverAgent {
    /// 首次配對演練（HOMEPLAY_STATE_NAME）用另一個標籤：不覆蓋、不卸載使用者平常的 LaunchAgent
    static let label = HomePlayState.isolated ? "me.aaron.homeplay.receiver.rehearsal" : "me.aaron.homeplay.receiver"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// 用户在菜单里明确关过：自动开启要尊重这个选择，不每次启动又装回来。
    static let autoOffKey = "HomePlayBackgroundReceiverOff"

    /// installed：這次是不是裝上了；message 是給人看的結果（目前只進日誌）
    static func toggle() -> (installed: Bool, message: String) {
        if isInstalled {
            let message = remove()
            UserDefaults.standard.set(true, forKey: autoOffKey)
            return (false, message)
        }
        let result = install()
        if result.installed { UserDefaults.standard.set(false, forKey: autoOffKey) }
        return result
    }

    /// 首次配对/已有手机时自动开启后台常驻：像妙控配件一样，桌宠退出后手机仍有东西可回连。
    @discardableResult
    static func autoEnableIfNeeded(reason: String) -> Bool {
        if isInstalled { return true }
        if UserDefaults.standard.bool(forKey: autoOffKey) { return false }
        let result = install()
        if result.installed {
            UserDefaults.standard.set(false, forKey: autoOffKey)
            log("后台自动连接已开启（\(reason)）")
        } else {
            log("后台自动连接没开成（\(reason)）：\(result.message)")
        }
        return result.installed
    }

    private static func install() -> (installed: Bool, message: String) {
        // 读 receiver 的当前路径（打包后在 Contents/Resources）+ wireless.json 的配置
        guard let bin = ReceiverLauncher.receiverBinary() else { return (false, L("install.noReceiver", "找不到 homeplay-receiver（先 swift build）")) }
        ReceiverLauncher.ensureConfigFile()
        let cfg = (try? JSONDecoder().decode(ReceiverLauncher.Config.self, from: Data(contentsOf: ReceiverLauncher.configURL()))) ?? .init()
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try plistText(cfg: cfg, bin: bin).data(using: .utf8)?.write(to: plistURL) }
        catch { return (false, String(format: L("install.writeFailed", "写 plist 失败：%@"), error.localizedDescription)) }
        let loaded = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return (loaded, loaded ? L("install.done", "已设为登录时打开（登录即待命）")
                           : L("install.partial", "plist 已写好，但 launchctl 没成功（下次登录也会生效）"))
    }

    private static func remove() -> String {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        return L("install.removed", "已取消登录时打开")
    }

    /// 升级迁移：旧版 LaunchAgent 指向 Contents/MacOS/homeplay-receiver（占用 App 的
    /// LaunchServices 身份，导致 `open` 打不开桌宠）。发现 plist 路径与当前版本不符就重写并重载。
    /// 重载会重启接收器（一次性），换掉旧布局里那个还在跑的进程。
    static func migrateIfNeeded() {
        guard isInstalled,
              let text = try? String(contentsOf: plistURL, encoding: .utf8),
              let bin = ReceiverLauncher.receiverBinary() else { return }
        guard !text.contains("<string>\(bin.path)</string>") else { return }
        let cfg = (try? JSONDecoder().decode(ReceiverLauncher.Config.self, from: Data(contentsOf: ReceiverLauncher.configURL()))) ?? .init()
        do { try plistText(cfg: cfg, bin: bin).data(using: .utf8)?.write(to: plistURL, options: .atomic) }
        catch { log("LaunchAgent 迁移失败：\(error.localizedDescription)"); return }
        log("LaunchAgent 迁移：接收器改到 \(bin.path)，重载让新布局生效")
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        for attempt in 0..<5 {
            if launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) { return }
            Thread.sleep(forTimeInterval: 0.2)   // bootout 尚未收尾时 bootstrap 会失败，稍等重试
            if attempt == 4 { log("LaunchAgent 重载失败（plist 已更新，下次登录生效）") }
        }
    }

    /// 用户换了手机：更新已安装的 LaunchAgent 参数（不 bootout，避免打断正在跑的 receiver）。
    /// 已加载的 launchd job 仍用旧参数，但下次登录会读新 plist；当前进程靠 WS 命令切换。
    static func syncPhone() {
        guard isInstalled else { return }
        guard let bin = ReceiverLauncher.receiverBinary(),
              let data = try? Data(contentsOf: ReceiverLauncher.configURL()),
              let cfg = try? JSONDecoder().decode(ReceiverLauncher.Config.self, from: data) else { return }
        try? plistText(cfg: cfg, bin: bin).data(using: .utf8)?.write(to: plistURL, options: .atomic)
    }

    private static func plistText(cfg: ReceiverLauncher.Config, bin: URL) -> String {
        // 不把 SSID/手机地址写进 launchd 参数：这两个值会随用户操作变化，而 launchd 只在
        // bootstrap 时读一次参数——写死就会出现「配置已改、重启后仍用旧 SSID/旧手机」的故障
        // （曾导致 0x5703 发出 <redacted>）。receiver 启动时会自己读 wireless.json。
        let args = ["--source", "auto", "--port", String(cfg.port), "--size", cfg.size]
        let logPath = ReceiverLauncher.configURL().deletingLastPathComponent().appendingPathComponent("receiver.log")
        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>\(label)</string>
  <key>ProgramArguments</key><array>
    <string>\(bin.path)</string>
    \(args.map { "<string>\($0)</string>" }.joined(separator: "\n    "))
  </array>
  <key>RunAtLoad</key><true/>
  <!-- 只在异常退出（接收器自愈 exit(1)）时由 launchd 重新拉起；用户主动停止是 exit(0)，不会重启。 -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>\(HomePlayState.isolated ? "\n  <key>EnvironmentVariables</key><dict><key>HOMEPLAY_STATE_NAME</key><string>\(HomePlayState.name)</string></dict>" : "")
  <!-- Umask 077：launchd 建的 receiver.log 與接收器寫的檔都只給自己讀寫（日誌裡有 Wi-Fi 名稱與手機位址） -->
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>\(logPath.path)</string>
  <key>StandardErrorPath</key><string>\(logPath.path)</string>
</dict></plist>
"""
    }

    /// 作业加载着但没在跑（例如曾因端口冲突 exit(0)）：让 launchd 再起一次。
    /// force=false 时只“没跑就起”，不会打断正在服务的接收器。
    static func kickstart(force: Bool = false) -> Bool {
        var args = ["kickstart"]
        if force { args.append("-k") }
        args.append("gui/\(getuid())/\(label)")
        return launchctl(args)
    }

    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        // launchd 不回应时不能无限等：这条路径在启动和配对时跑在主執行緒上。
        // 正常情况 launchctl 几十毫秒就退出，这里只是加个上限。
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning {
            if Date() >= deadline {
                p.terminate()
                return false
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return p.terminationStatus == 0
    }
}

/// F5（听写/Siri 那颗）在默认键盘模式下不是普通 keyDown：全局 keyDown 监听和 Carbon
/// 热键都看不到（早先的诊断里全局 keyDown 从未出现 96 或 176）。实证它走系统事件：keyDown keyCode
/// 176（Spillway 真机实测），或 NX_SYSDEFINED（type 14、subtype 8 的辅助键，data1
/// 高 16 位＝键值、0x0A/0x0B＝按下/抬起）。装一个会话级 CGEventTap（输入监控已授权）：
/// 176 按住＝对手机 Siri 说话、放开＝结束，并把按下/抬起都吞掉，免得 Mac 听写一起抢这颗键。辅助键只在
/// HOMEPLAY_DIAG_KEYS=1 时写 syskeys.log——键盘发的是别的键值时，按一次 F5 就能看到。
