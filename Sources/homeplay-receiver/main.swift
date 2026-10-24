// HomePlay 接收器（自用）。
//
// 三种画面来源，wire 协议统一从 WebSocket 推给 pet：
//   --source window    抓一扇窗（例如 Device Hub 的 "CarPlay Simulator" 窗），H.264 编码
//   --source h264      TCP 收 H.264 基本流
//   --source wireless  无线 CarPlay：蓝牙 iAP2（识别 + MFi 认证，自带公开实验性身份，见 identity/SOURCE.txt）
//                      → Wi-Fi 交接、会话控制面 → 螢幕流解密（见 Wireless.swift、docs/wireless.md）
//   --source netinfo   无线前自检：本机 IP / Wi-Fi MAC / 信道
//
// 用法：
//   homeplay-receiver --window "CarPlay Simulator" --port 8788 [--fps 30]
//   homeplay-receiver --source wireless --address <iPhone蓝牙地址> --ssid '<Wi-Fi名>'
// 然后：homeplay-pet --endpoint ws://127.0.0.1:8788

import Foundation
import Darwin
import Network
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import AppKit
import CoreWLAN
import IOBluetooth
import Session

import Wire
import H264
import IAP2

// MARK: - H.264 编码器

final class Encoder {
    private var session: VTCompressionSession?
    private let fps: Int32
    var onConfig: ((Data) -> Void)?           // avcC（只在变化时给一次）
    var onFrame: ((Data, Bool, UInt64) -> Void)? // AnnexB, keyframe, ptsMicros
    private var lastAvcC: Data?

    init(width: Int, height: Int, fps: Int32) {
        self.fps = fps
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { FileHandle.standardError.write("VTCompressionSessionCreate 失败 \(status)\n".data(using: .utf8)!); exit(2) }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func encode(_ pixelBuffer: CVImageBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: fps), frameProperties: props,
            infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
            self.handle(sample)
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        if let fmt = CMSampleBufferGetFormatDescription(sample), let avcC = avcCRecord(from: fmt), avcC != lastAvcC {
            lastAvcC = avcC
            onConfig?(avcC)
        }
        // keyframe？看附件 NotSync（缺失/false 即关键帧）。
        var keyframe = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return }
        let avcc = Data(bytes: pointer, count: totalLength)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = UInt64(max(0, pts.seconds) * 1_000_000)
        onFrame?(avccToAnnexB(avcc), keyframe, micros)
    }
}

// MARK: - 窗口抓取（ScreenCaptureKit）

final class WindowSource: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var encoder: Encoder?
    private let server: WSServer
    private let titleQuery: String
    private let fps: Int32
    private var pendingForceKey = false
    private let outQueue = DispatchQueue(label: "ws.capture")
    private var started = false
    private(set) var lastConfig: Data?
    private(set) var targetWindowID: CGWindowID = 0

    /// 被抓窗的当前全局边界（top-left 原点，点）。供触控把 0..1 映射成屏幕坐标。
    func windowBounds() -> CGRect? {
        guard targetWindowID != 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], targetWindowID) as? [[String: Any]],
              let info = list.first, let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 0, h > 0
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    init(server: WSServer, titleQuery: String, fps: Int32) {
        self.server = server; self.titleQuery = titleQuery; self.fps = fps
    }

    func forceKeyframeNext() { outQueue.async { self.pendingForceKey = true } }

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(titleQuery) }) else {
                let titles = content.windows.compactMap { $0.title }.filter { !$0.isEmpty }.prefix(40)
                FileHandle.standardError.write("找不到标题含 \"\(titleQuery)\" 的窗。现有窗口标题：\n  \(titles.joined(separator: "\n  "))\n".data(using: .utf8)!)
                exit(3)
            }
            let scale = Int(window.frame.width > 0 ? 2 : 2) // Retina；SCStream 的 width/height 是像素
            let pxW = Int(window.frame.width) * (NSScreen.main?.backingScaleFactor != nil ? Int(NSScreen.main!.backingScaleFactor) : 2)
            let pxH = Int(window.frame.height) * (NSScreen.main?.backingScaleFactor != nil ? Int(NSScreen.main!.backingScaleFactor) : 2)
            _ = scale
            let enc = Encoder(width: pxW, height: pxH, fps: fps)
            enc.onConfig = { [weak self] avcC in
                let cfg = Wire.videoConfig(width: pxW, height: pxH, avcC: avcC)
                self?.lastConfig = cfg
                self?.server.broadcastBinary(cfg)
            }
            enc.onFrame = { [weak self] annexB, key, micros in
                self?.server.broadcastBinary(Wire.videoFrame(annexB: annexB, keyframe: key, ptsMicros: micros))
            }
            encoder = enc

            let cfg = SCStreamConfiguration()
            cfg.width = pxW; cfg.height = pxH
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: fps)
            cfg.queueDepth = 5
            cfg.showsCursor = false
            targetWindowID = window.windowID
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outQueue)
            try await stream.startCapture()
            self.stream = stream
            started = true
            FileHandle.standardError.write("抓取中：\(window.title ?? "") \(pxW)x\(pxH)@\(fps)，WebSocket 等 WindowShade 连入。\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("启动抓取失败：\(error)\n".data(using: .utf8)!)
            exit(4)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, server.hasClients, let enc = encoder else { return }
        guard let attach = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attach.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let force = pendingForceKey; pendingForceKey = false
        enc.encode(image, pts: pts, forceKeyframe: force)
    }
}

// MARK: - 触控注入：0..1 → 被抓窗全局坐标 → 合成鼠标事件
//
// 小窗镜像的是整扇窗，所以 0..1 直接映射到窗口矩形：点镜像里的旋钮/Home 会落到真按钮上
// （P0：底盘按钮认合成 HID 事件；CarPlay 画面区可能不认合成事件，那部分要真鼠标）。
// HID 事件会移动真光标——自用 toy 可接受。

final class TouchInjector {
    private let bounds: () -> CGRect?
    private let src = CGEventSource(stateID: .hidSystemState)
    private var down = false

    init(bounds: @escaping () -> CGRect?) { self.bounds = bounds }

    func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "touch",
              let contacts = obj["contacts"] as? [[String: Any]], let c = contacts.first,
              let nx = (c["x"] as? NSNumber)?.doubleValue, let ny = (c["y"] as? NSNumber)?.doubleValue
        else { return }
        let isDown = (c["down"] as? Bool) ?? false
        guard let r = bounds() else { return }
        let p = CGPoint(x: r.minX + CGFloat(min(1, max(0, nx))) * r.width,
                        y: r.minY + CGFloat(min(1, max(0, ny))) * r.height)
        if isDown && !down {
            post(.mouseMoved, p); post(.leftMouseDown, p); down = true
        } else if isDown && down {
            post(.leftMouseDragged, p)
        } else if !isDown && down {
            post(.leftMouseUp, p); down = false
        } else {
            // 抬起但本来就没按下：当作一次轻点
            post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p)
        }
    }

    private func post(_ type: CGEventType, _ p: CGPoint) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - main

func arg(_ name: String, _ def: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return def
}
func flag(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

/// 端口被占用（EADDRINUSE）：通常是另一个接收器实例已经在跑（登录瞬间桌宠与 launchd
/// 同时拉起时会发生）。这种情况要**优雅退出 exit(0)**，否则 KeepAlive 会每 10 秒重启一次。
func isAddressInUse(_ error: Error) -> Bool {
    if let nw = error as? NWError, case .posix(let code) = nw, code == .EADDRINUSE { return true }
    return (error as NSError).code == 48
}
/// 桌宠写的本地配置（wireless.json）；密码字段只在这里读，不进命令行、不打印。
func wirelessConfigStringArray(_ key: String) -> [String] {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HomePlay/wireless.json")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let values = obj[key] as? [String] else { return [] }
    return values.filter { !$0.isEmpty }
}

func wirelessConfigString(_ key: String) -> String? {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HomePlay/wireless.json")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = obj[key] as? String, !value.isEmpty else { return nil }
    return value
}
/// 默认身份目录（按顺序找）：仓库 identity/（.build 产物上两级）→ App 包 Resources/identity →
/// 可执行文件旁 → 当前目录 → ~/HomePlayIdentity。--identity-dir / $HOMEPLAY_IDENTITY_DIR 可覆盖。
func defaultIdentityDir() -> String? {
    let fm = FileManager.default
    let exec = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let dir = exec.deletingLastPathComponent()
    let nextToBuild = dir.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("identity")
    let inBundle = dir.deletingLastPathComponent().appendingPathComponent("Resources/identity")
    let nextToExec = dir.appendingPathComponent("identity")
    let inCwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("identity")
    let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("HomePlayIdentity")
    return [nextToBuild, inBundle, nextToExec, inCwd, home].first { fm.fileExists(atPath: $0.path) }?.path
}

/// macOS 在没有定位权限时把 SSID 脱敏成字面量 "<redacted>"（ipconfig / CoreWLAN 都一样）。
/// 它长得像字符串、其实是占位符：绝不能当 SSID 存储或发给 iPhone，否则 0x5703 会让手机
/// 去连一个叫 "<redacted>" 的网络，永远等不到 0x4300。
func isUsableSSID(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, t != "<redacted>", !t.localizedCaseInsensitiveContains("redacted") else { return false }
    return true
}

/// 免权限取当前 Wi-Fi 的 SSID（ipconfig getsummary）。拿不到（含被脱敏）就返回 nil——
/// 手机和 Mac 在同一网络时，SSID 空着也照样能完成无线交接。
func detectSSID(_ iface: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    p.arguments = ["getsummary", iface]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
    for line in out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("SSID :") else { continue }
        let s = t.dropFirst("SSID :".count).trimmingCharacters(in: .whitespaces)
        if isUsableSSID(s) { return s }
    }
    return nil
}

/// 当前 Wi-Fi 的安全类型。WPA3-only 网络如果按 WPA2 发，iPhone 会直接拒绝交接。
func detectedWiFiSecurity(iface: String) -> Iap2Csm.WiFiSecurity? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    p.arguments = ["getsummary", iface]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
    for line in out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("Security :") else { continue }
        let value = t.dropFirst("Security :".count).trimmingCharacters(in: .whitespaces).uppercased()
        if value.contains("WPA3") && (value.contains("WPA2") || value.contains("TRANSITION")) {
            return .wpa3Transition
        }
        if value.contains("WPA3") {
            // 注意：ipconfig 的 WPA3_SAE 是「本机这次关联用的方式」，不是 AP 的全部能力。
            // WPA2/WPA3 混合网络里 Mac 会优先用 SAE，这里读到 WPA3_SAE，但网络同时支持
            // WPA2。真机验证（2026-10-19）：按 WPA3-only 发给 iPhone 时它不连回控制口；
            // 按 WPA2 发（MacPlay mac_main.rs 永远发 WpaWpa2）立刻回连。所以默认按 WPA2 发，
            // 真正 WPA3-only 的网络用 --security wpa3-only 显式指定。
            return .wpaWpa2
        }
        if value.contains("WPA2") || value.contains("WPA") { return .wpaWpa2 }
        if value.contains("WEP") { return .wep }
        if value.contains("NONE") || value.contains("OPEN") { return .none }
    }
    return nil
}

/// AP 是不是「纯 WPA3」。ipconfig 的 WPA3_SAE 只说明本机这次用 SAE 关联——混合网络也会这样报，
/// 不能用来区分；真正的能力要看扫描结果：支持 WPA2-Personal 就是混合/WPA2，否则是纯 WPA3。
/// （2026-10-20 实测：纯 WPA3 网络 wpa2Personal=false、wpa3Personal=true，混合网络两者都为 true。）
func wpa3OnlyNetwork(ssid: String) -> Bool? {
    guard !ssid.isEmpty,
          let iface = CWWiFiClient.shared().interface()
              ?? CWWiFiClient.shared().interface(withName: "en0") else { return nil }
    if let nets = try? iface.scanForNetworks(withSSID: nil) {
        let named = nets.filter { $0.ssid != nil }
        if let net = nets.first(where: { $0.ssid == ssid }) {
            let wpa2 = net.supportsSecurity(.wpa2Personal)
            let wpa3 = net.supportsSecurity(.wpa3Personal)
            Wireless.note("AP 能力探测：\(ssid) wpa2Personal=\(wpa2) wpa3Personal=\(wpa3)（扫描 \(nets.count) 个，带名 \(named.count) 个）")
            if wpa2 { return false }
            if wpa3 { return true }
            return false
        }
        Wireless.note("AP 能力探测：扫描 \(nets.count) 个、带名 \(named.count) 个，没匹配到「\(ssid)」")
    } else {
        Wireless.note("AP 能力探测：CoreWLAN 扫描失败")
    }
    // 兜底：system_profiler 的 Current Network Information › Security（不需要定位权限）
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["SPAirPortDataType"]
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
    var inCurrent = false
    for line in out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Current Network Information:") { inCurrent = true; continue }
        guard inCurrent else { continue }
        if t.hasPrefix("Other Local Wi-Fi Networks:") { break }
        if t.hasPrefix("Security:") {
            let v = t.uppercased()
            let mixed = v.contains("WPA2") || v.contains("TRANSITION") || v.contains("过渡")
            Wireless.note("AP 能力探测（system_profiler）：\(t)")
            if v.contains("WPA3") { return !mixed }
            return false
        }
    }
    return nil
}

private var wifiSecurityCacheURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HomePlay/wifi-security.json")
}
/// 按 SSID 缓存的 0x4301 安全类型（只存枚举值，不存密码）。
func cachedWiFiSecurity(ssid: String) -> Iap2Csm.WiFiSecurity? {
    guard !ssid.isEmpty, let data = try? Data(contentsOf: wifiSecurityCacheURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
          let raw = obj[ssid], let value = Iap2Csm.WiFiSecurity(rawValue: UInt8(clamping: raw)) else { return nil }
    return value
}
func saveWiFiSecurity(ssid: String, value: Iap2Csm.WiFiSecurity) {
    guard !ssid.isEmpty else { return }
    var obj: [String: Int] = [:]
    if let data = try? Data(contentsOf: wifiSecurityCacheURL),
       let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Int] { obj = saved }
    if obj[ssid] == Int(value.rawValue) { return }
    obj[ssid] = Int(value.rawValue)
    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    try? FileManager.default.createDirectory(at: wifiSecurityCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? out.write(to: wifiSecurityCacheURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wifiSecurityCacheURL.path)
}

/// 0x4301 里的 security：纯 WPA3 发 4（Wpa3Only），WPA2/混合发 2（实测混合网络发 2 能回连）。
/// 显式 --security 优先（调试用）。
func resolveWiFiSecurity(ssid: String, iface: String, explicit: Bool, current: Iap2Csm.WiFiSecurity) -> Iap2Csm.WiFiSecurity {
    if explicit { return current }
    if let only = wpa3OnlyNetwork(ssid: ssid) { return only ? .wpa3Only : .wpaWpa2 }
    return detectedWiFiSecurity(iface: iface) ?? current
}

/// Wi-Fi 是否已就绪到"可以读出会发给 iPhone 的网络参数"：拿到 IPv4 且信道可读。
/// 信道是兜底信号——登录瞬间 DHCP 还没完成时 SSID/安全类型都读得到、但关联可能还不完整，
/// 两个一起看才能避免把 WPA3-only 网络读成 WPA2、把 0x5703 发成错误的凭据类型。
func wifiStartupReady(_ iface: String) -> Bool {
    guard NetInfo.ipv4(iface) != nil else { return false }
    let channel = CWWiFiClient.shared().interface(withName: iface)?.wlanChannel()?.channelNumber ?? 0
    return channel != 0
}

/// 开机自启时 Wi-Fi 可能还没关联完（Wi-Fi 密码在用户钥匙串，登录后才能自动加入）。
/// 在读 SSID/安全类型/信道之前等它就绪：最多 30 秒（每 5 秒报一次进度）。
/// Wi-Fi 硬件关着（powerOff）就说明不是竞态，等也没用——照旧往下走，有线还能用。
func waitUntilWiFiReady(iface: String) {
    let deadline = Date().addingTimeInterval(30)
    var noted = false
    while !wifiStartupReady(iface) {
        let power = CWWiFiClient.shared().interface(withName: iface)?.powerOn() ?? false
        guard power, Date() < deadline else {
            if !power { Wireless.note("Wi-Fi 硬件关闭或无网卡：跳过等待，按当前状态继续（有线模式仍可用）") }
            else { Wireless.note("Wi-Fi 30 秒内未就绪：按当前状态继续（runDual 会按有线/无线可用性选路）") }
            return
        }
        // 每 0.5 秒看一次：Wi-Fi 一就绪就走（原本每 5 秒，开机时平白多等几秒）
        if !noted { Wireless.note("Wi-Fi 还没就绪（IPv4/信道未拿到）——每 0.5 秒再看（开机自启时 Wi-Fi 关联常需要几秒）"); noted = true }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

// 父進程看門狗：桌寵被強制結束/崩潰時，receiver 不留在後台（launchd 拉起的沒有這個參數，不受影響）
if let pp = flag("--parent-pid").flatMap({ Int32($0) }), pp > 1 {
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    t.schedule(deadline: .now() + 2, repeating: 2)
    t.setEventHandler {
        if Darwin.kill(pp, 0) != 0, errno == ESRCH {
            // 父進程沒了也先把手機會話收乾淨，再退出；不要只留一顆突然消失的 socket
            DispatchQueue.main.async {
                Wireless.shutdown()
                FileHandle.standardError.write("父進程已結束，receiver 退出。\n".data(using: .utf8)!)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            }
        }
    }
    t.resume()
    parentWatchdog = t
}

if CommandLine.arguments.contains("--bluetooth-selftest") {
    // 只读诊断：发布 iAP2/CarPlay SDP 服务并打印实际 RFCOMM 通道；不改 Mac 的蓝牙设备类。
    // 进程退出后非持久 SDP 记录自动消失。
    let beacon = BluetoothBeacon(advertiseClass: false, log: { print($0) })
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
    RunLoop.main.run()
}

let sourceKind = arg("--source", "window")   // window | h264 | wireless
let windowQuery = arg("--window", "CarPlay Simulator")
let port = UInt16(arg("--port", "8788")) ?? 8788
let fps = Int32(arg("--fps", "30")) ?? 30

if let di = CommandLine.arguments.firstIndex(of: "--bluetooth-discoverable"), di + 1 < CommandLine.arguments.count {
    // 诊断/内部：设置本机蓝牙「可被发现」（IOBluetooth 私有 API，blueutil 同款）。
    // 只信私有 getter 不够（它会过时）；真实状态用 `system_profiler SPBluetoothDataType` 看。
    let want = CommandLine.arguments[di + 1] == "1"
    guard BluetoothDiscoverable.available else {
        print("IOBluetooth discoverable symbols unavailable")
        exit(2)
    }
    print("before=\(BluetoothDiscoverable.rawState() ?? -1)")
    let after = BluetoothDiscoverable.set(want) ?? -1
    print("after=\(after)")
    exit((after == 1) == want ? 0 : 3)
}

if CommandLine.arguments.contains("--phones-selftest") {    // 只读诊断：列出系统已配对的 iPhone 与本机蓝牙名（右键「使用 iPhone」用的就是这份）
    print("bluetooth=\(Iap2BluetoothAccessory.localBluetoothName)")
    for p in Iap2BluetoothAccessory.pairedPhones() { print("phone=\(p.address)\t\(p.name)") }
    // 设备类诊断：判断手机不靠名字，靠 CoD 主类与 iAP2 服务（名字可以是任意字符串）
    for d in Iap2BluetoothAccessory.pairedDevices() {
        let raw = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first {
            ($0.addressString ?? "").uppercased().replacingOccurrences(of: "-", with: ":") == d.address
        }
        let major = raw?.deviceClassMajor ?? 0
        let iap2 = raw?.getServiceRecord(for: Iap2BluetoothAccessory.iap2ServiceUUID) != nil
        print("paired=\(d.address)\tclassMajor=\(major)\tiap2=\(iap2)\tname=\(d.name)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--audio-selftest") {
    // 音频出声冒烟：一帧真 AAC（afconvert 编码的 44.1k 立体声正弦，23 ms，几乎听不见）
    // → ADTS 解析 → AudioConverter 解码 → AVAudioEngine 排播。也模拟一次输出设备变化。
    let au: [UInt8] = [
        0x21, 0x0c, 0x14, 0x6d, 0x99, 0x0c, 0x04, 0x61, 0x21, 0x04, 0x80, 0x21, 0x08, 0x08, 0x42, 0x10,
        0x67, 0xcb, 0xf6, 0xe5, 0xd1, 0xfc, 0xeb, 0xfe, 0xfa, 0x43, 0x9a, 0x05, 0xca, 0x48, 0x18, 0x7d,
        0x6c, 0xdb, 0x53, 0xcd, 0xb4, 0x95, 0xaa, 0x0b, 0x89, 0x30, 0xd4, 0x44, 0xac, 0xd2, 0xac, 0x6d,
        0x4e, 0xe0, 0xc0, 0xc0, 0xc0, 0xce, 0xce, 0xce, 0xd1, 0xc4, 0x58, 0x18, 0x1a, 0x80, 0x31, 0xb8,
        0x99, 0x04, 0xd3, 0xe6, 0xe2, 0x96, 0xb8, 0x10, 0x20, 0x0d, 0xb0, 0x2a, 0x39, 0x04, 0x00, 0xaa,
        0x0f, 0xc5, 0x72, 0x92, 0x06, 0x1f, 0x70]
    let player = CarPlayAudioPlayer(codec: .aacLc(rate: 44100, channels: 2))
    player.onLog = { FileHandle.standardError.write(($0 + "\n").data(using: .utf8)!) }
    if CommandLine.arguments.contains("--audio-replay"),
       let blob = FileManager.default.contents(atPath: "/tmp/phone_au.bin") {
        var frames: [Data] = []
        var i = 0
        let b = [UInt8](blob)
        while i + 4 <= b.count {
            let n = Int(UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24)
            i += 4
            guard n > 0, i + n <= b.count else { break }
            frames.append(Data(b[i..<i+n])); i += n
        }
        for rate in [48000, 44100] {
            let player = CarPlayAudioPlayer(codec: .aacLc(rate: rate, channels: 2))
            player.onLog = { FileHandle.standardError.write(($0 + "\n").data(using: .utf8)!) }
            for f in frames { player.enqueue(payload: f) }
            Thread.sleep(forTimeInterval: 1.0)
            FileHandle.standardError.write("replay @\(rate)Hz: \(player.snapshot)\n".data(using: .utf8)!)
            player.stop()
        }
        exit(0)
    }
    if let mdat = FileManager.default.contents(atPath: "/tmp/mdat.bin"),
       let sizesData = FileManager.default.contents(atPath: "/tmp/sizes.json"),
       let sizes = try? JSONDecoder().decode([Int].self, from: sizesData) {
        // 全链路复现：46 帧真 AAC 按网络节奏（21ms 一帧）喂给真的播放器
        let q = DispatchQueue(label: "selftest.feed")
        var off = sizes.first ?? 0   // 跳过首帧（6 字节 padding）的字节偏移
        var delay = 0.0
        for s in sizes.dropFirst() {
            let frame = mdat.subdata(in: off..<off+s); off += s
            delay += Double(s) / 44100 * 0.1   // 按帧时长排（快进 10 倍），近似网络节奏
            q.asyncAfter(deadline: .now() + delay) {
                player.enqueue(payload: frame)
            }
        }
        Thread.sleep(forTimeInterval: 2.5)
        FileHandle.standardError.write("selftest snapshot: \(player.snapshot)\n".data(using: .utf8)!)
        exit(player.played > 10 ? 0 : 1)
    }
    for _ in 0..<3 { player.enqueue(payload: Data(au)); Thread.sleep(forTimeInterval: 0.15) }
    Thread.sleep(forTimeInterval: 0.4)
    let first = player.played
    player.simulateConfigurationChange()
    for _ in 0..<3 { player.enqueue(payload: Data(au)); Thread.sleep(forTimeInterval: 0.15) }
    Thread.sleep(forTimeInterval: 0.5)
    let ok = first >= 1 && player.played > first
    FileHandle.standardError.write("audio selftest \(ok ? "OK" : "FAIL") played=\(first)→\(player.played)（含设备变化恢复）\n".data(using: .utf8)!)
    exit(ok ? 0 : 1)
}


let app = NSApplication.shared // SCShareableContent / CG 需要初始化
app.setActivationPolicy(.prohibited)

// SIGTERM / SIGINT：先收掉 CarPlay 会话再退出。桌宠的 ReceiverLauncher.stop() 和 Ctrl-C 都走这里，
// 不让手机留下一個沒人關的控制連線。
var shutdownSources: [DispatchSourceSignal] = []
// SIGPIPE：对端先关的 socket 上 write() 会让默认处理直接杀进程、不留痕迹（2026-10-22 拔线实测）。
// 写失败会以 EPIPE 回到调用方自己处理，所以这里忽略它。
signal(SIGPIPE, SIG_IGN)
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        Wireless.shutdown()
        FileHandle.standardError.write("收到结束信号，已结束 CarPlay 会话。\n".data(using: .utf8)!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }
    src.resume()
    shutdownSources.append(src)
}

let server: WSServer
do { server = try WSServer(port: port) }
catch {
    if isAddressInUse(error) {
        FileHandle.standardError.write("监听 \(port) 失败：另一个接收器实例已在运行，本实例退出。\n".data(using: .utf8)!)
        exit(Wireless.portInUseExitCode)   // 原地重启出来的映像交给 launchd 再拉一次
    }
    FileHandle.standardError.write("监听 \(port) 失败：\(error)\n".data(using: .utf8)!); exit(1)
}

if sourceKind == "netinfo" {
    // 无线前的自检：这台 Mac 在局域网里的地址、Wi-Fi MAC、当前信道（信道可能要定位权限才读得到）
    let iface = flag("--iface") ?? "en0"
    let ch = CWWiFiClient.shared().interface(withName: iface)?.wlanChannel()?.channelNumber
    print("iface=\(iface) ipv4=\(NetInfo.ipv4(iface) ?? "-") ipv6=\(NetInfo.linkLocalIPv6(iface) ?? "-") mac=\(NetInfo.mac(iface) ?? "-") channel=\(ch.map(String.init) ?? "-（用 --channel 指定）")")
    exit(0)
}

if sourceKind == "wireless" || sourceKind == "usb" || sourceKind == "auto" {
    // 无线＝蓝牙 iAP2；usb＝有线 carkit；auto＝插着线走有线、否则无线（见 Wireless.swift）。
    // Wi-Fi 密码优先从环境变量 HOMEPLAY_WIFI_PASSPHRASE 读，免得进 ps。
    // 身份默认自带：仓库 identity/（DiPlay 公开实验性身份，见 identity/SOURCE.txt），按顺序找：
    // --identity-dir > $HOMEPLAY_IDENTITY_DIR > 仓库 identity/（可执行文件上两级或当前目录）> ~/HomePlayIdentity
    // --address 不给＝自动匹配：扫已配对设备的 iAP2 服务（iPhone 签名），连谁记谁。
    guard let dir = flag("--identity-dir")
          ?? ProcessInfo.processInfo.environment["HOMEPLAY_IDENTITY_DIR"]
          ?? defaultIdentityDir(),
          sourceKind != "wireless" || flag("--ssid") != nil else {
        FileHandle.standardError.write("""
        --source wireless 需要：
          --address <蓝牙地址>    可选：不给就自动匹配（iap2-probe --list 可列已配对设备）
          --ssid <名称>           iPhone 所连 Wi-Fi（和 Mac 同一个局域网）
          身份：默认用仓库自带的 identity/，或 --identity-dir <目录> 指定自己的 identity.pk8 + certificate.p7b
          密码：环境变量 HOMEPLAY_WIFI_PASSPHRASE 或 --passphrase
          可选：--channel N  --iface en0  --control-port 17000  --size 1200x1200  --security wpa2|wpa3|wpa3-only|none
                --no-iap-channel（或 HOMEPLAY_IAP_CHANNEL=0）：不声明 iAP 数据通道（流 130），排障用
        --source usb（插线即连，不需要 Wi-Fi）；--source auto＝有线优先

        """.data(using: .utf8)!)
        exit(6)
    }
    var o = Wireless.Options(identityDir: dir,
                             phoneAddress: flag("--address") ?? wirelessConfigString("phone"),
                             ssid: flag("--ssid") ?? wirelessConfigString("ssid") ?? "",
                             passphrase: ProcessInfo.processInfo.environment["HOMEPLAY_WIFI_PASSPHRASE"]
                                ?? flag("--passphrase")
                                ?? wirelessConfigString("passphrase")
                                ?? "")
    if let c = flag("--channel"), let n = UInt8(c) { o.channel = n }
    if let i = flag("--iface") { o.iface = i }
    if let p = flag("--control-port"), let n = UInt16(p) { o.controlPort = n }  // --port 是 WS 口（WSServer），別混
    if let sz = flag("--size") {
        let wh = sz.split(separator: "x").compactMap { Int($0) }
        if wh.count == 2 { o.width = wh[0]; o.height = wh[1] }
    }
    let kind: String
    switch sourceKind {
    case "usb": kind = "usb"
    case "auto": kind = "dual"   // 双模：插线有线、拔线蓝牙，运行中实时切换
    default: kind = "wireless"
    }
    // 开机自启竞态（真机失败样本 2026-10-19 21:34：Mac 21:30 重启，launchd 在登录瞬间拉起
    // receiver 时 Wi-Fi 还没关联完）：en0 无 IPv4 → runDual 永久降级有线模式不再回来，
    // 蓝牙广播/0x5703 整条无线链路缺席；同一瞬间安全类型被读成 WPA/WPA2（实际 WPA3-only），
    // 发出去 iPhone 会拒绝交接。所以要在读任何网络值之前等 Wi-Fi 就绪。
    if kind != "usb" { waitUntilWiFiReady(iface: o.iface) }
    switch flag("--security") {
    case "wpa2": o.security = .wpaWpa2; o.securityExplicit = true
    case "wpa3": o.security = .wpa3Transition; o.securityExplicit = true
    case "wpa3-only": o.security = .wpa3Only; o.securityExplicit = true
    case "none": o.security = .none; o.securityExplicit = true
    default:
        // 没显式指定就按 AP 的真实能力选：纯 WPA3 → 4，WPA2/混合 → 2（见 resolveWiFiSecurity）。
        // 探测要 CoreWLAN 扫描＋system_profiler，4–34 秒；同一个 SSID 的结果缓存起来，启动先用缓存、
        // 后台再刷新（结果只影响下一次启动）。没有缓存才同步探测。
        if let cached = cachedWiFiSecurity(ssid: o.ssid) {
            o.security = cached
            Wireless.note("Wi-Fi 安全类型用缓存：\(Wireless.securityLabel(cached))（后台重新探测）")
            let ssid = o.ssid, iface = o.iface, current = o.security
            DispatchQueue.global(qos: .utility).async {
                let fresh = resolveWiFiSecurity(ssid: ssid, iface: iface, explicit: false, current: current)
                saveWiFiSecurity(ssid: ssid, value: fresh)
            }
        } else {
            o.security = resolveWiFiSecurity(ssid: o.ssid, iface: o.iface, explicit: false, current: o.security)
            saveWiFiSecurity(ssid: o.ssid, value: o.security)
        }
    }
    let secName: String
    switch o.security {
    case .none: secName = "开放"
    case .wep: secName = "WEP"
    case .wpaWpa2: secName = "WPA/WPA2"
    case .wpa3Transition: secName = "WPA2/WPA3 过渡"
    case .wpa3Only: secName = "WPA3-only"
    }
    Wireless.note("Wi-Fi 安全类型：\(secName)")
    let ignoredPhones = wirelessConfigStringArray("ignoredPhones")
    if !ignoredPhones.isEmpty {
        Iap2BluetoothAccessory.ignoredAddresses = Set(ignoredPhones)
        Wireless.note("已忘记 \(ignoredPhones.count) 台 iPhone（应用层忽略，不再尝试连接）")
    }
    // iAP 数据通道（流 130）默认声明并实现；HOMEPLAY_IAP_CHANNEL=0 或 --no-iap-channel 关掉（排障用）。
    o.advertiseIAPChannel = ProcessInfo.processInfo.environment["HOMEPLAY_IAP_CHANNEL"] != "0"
        && !CommandLine.arguments.contains("--no-iap-channel")
    if CommandLine.arguments.contains("--iap-channel") { o.advertiseIAPChannel = true }
    if !o.ssid.isEmpty, !isUsableSSID(o.ssid) {
        // 旧版本曾把 macOS 的脱敏占位符写进 wireless.json；那种值发出去等于让手机去连
        // 一个不存在的网络，0x4300 永远不会来。宁可当作未知、提示用户填。
        Wireless.note("保存的 SSID 是系统脱敏占位符（\(o.ssid)），已忽略；请在桌宠右键「Wi-Fi 设置」填 iPhone 所连网络名")
        o.ssid = ""
    }
    // SSID 留空＝自动取当前 Wi-Fi（免权限）。取不到也继续：同网手机照样能连。
    if o.ssid.isEmpty, let s = detectSSID(o.iface) {
        o.ssid = s
        Wireless.note("SSID 自动取到当前 Wi-Fi（\(s)）")
    }
    if o.ssid.isEmpty {
        Wireless.note("SSID 未知（定位权限关闭时 macOS 会脱敏）：iPhone 若已在同一 Wi-Fi 仍可交接；否则请在桌宠右键「Wi-Fi 设置」填 iPhone 所连网络名")
    } else {
        Wireless.note("无线配置：iPhone 所连 SSID「\(o.ssid)」；手机地址 \(o.phoneAddress ?? "自动")")
    }
    if kind == "usb" { Wireless.runWired(o, server: server) }
    if kind == "dual" { Wireless.runDual(o, server: server) }
    Wireless.run(o, server: server)
}

var h264Ingest: H264Ingest?   // 全局持有：监听器的回调只弱引用它
var parentWatchdog: DispatchSourceTimer?   // 父进程（桌宠）死了就退出；launchd/手动启动不带这个参数
if sourceKind == "h264" {
    // 无线视频会话的数据面（解出来之后那段）：TCP 收 H.264 基本流 → 同一套 wire
    let sink = H264Sink(server: server)
    let inPort = UInt16(arg("--h264-port", "8790")) ?? 8790
    let framing = arg("--framing", "annexb")
    server.onConnect = { conn in
        server.sendText(Wire.helloJSON(name: "CarPlay (无线)", width: 1, height: 1), to: conn)
        if let cfg = sink.lastConfig { server.sendBinary(cfg, to: conn) }
    }
    server.start()
    do { h264Ingest = try H264Ingest(port: inPort, sink: sink, framing: framing); h264Ingest?.start() }
    catch { FileHandle.standardError.write("监听 H.264 口 \(inPort) 失败：\(error)\n".data(using: .utf8)!); exit(1) }
    FileHandle.standardError.write("H.264 来源：tcp://127.0.0.1:\(inPort)（\(framing)）→ ws://127.0.0.1:\(port)。\n".data(using: .utf8)!)
    RunLoop.main.run()
}

let source = WindowSource(server: server, titleQuery: windowQuery, fps: fps)

server.onConnect = { conn in
    FileHandle.standardError.write("WindowShade 连入，发 hello + 现有 config 并请关键帧。\n".data(using: .utf8)!)
    server.sendText(Wire.helloJSON(name: "CarPlay (Simulator)", width: 1, height: 1), to: conn)
    if let cfg = source.lastConfig { server.sendBinary(cfg, to: conn) }
    source.forceKeyframeNext()
}
let touch = TouchInjector(bounds: { source.windowBounds() })
server.onText = { text in
    if text.contains("\"keyframe\"") { source.forceKeyframeNext() }
    if text.contains("\"touch\"") { touch.handle(text) }
    // knob/media/siri：旋钮/Home/Siri 现在靠点镜像里的那颗按钮（走 touch）；语义回传留下一步。
}
server.start()

Task { await source.start() }

FileHandle.standardError.write("loopback 接收器启动：ws://127.0.0.1:\(port)（窗口 \"\(windowQuery)\"，\(fps)fps）。Ctrl-C 结束。\n".data(using: .utf8)!)
RunLoop.main.run()
