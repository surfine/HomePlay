import Foundation
import IOBluetooth

// iAP2 配件端的传输无关核心：marker 探测 → 链路同步 → 识别（0x1D）→ MFi 认证（0xAA）→ 之后的业务消息。
// 蓝牙（RFCOMM）和 USB（usbmuxd carkit 流）都包着它跑；传输层只管三件事：
// 通了以后调 start()、来数据调 feed()、把 takeOutput() 的字节发出去。
// 可变状态只在主队列读写；stageTimeout 治半开通道挂死（认证前 25s 无进展就 finish 交给上层退避）。

package final class Iap2AccessoryCore {
    package enum Phase: String {
        case linkDetect = "链路探测"
        case identify = "识别"
        case mfi = "MFi认证"
        case authenticated = "已认证"
    }

    package struct Info: Sendable {
        package var name = "HomePlay"
        package var model = "HomePlay"
        package var manufacturer = "HomePlay"
        package var serialNumber = "HOMEPLAY-1"
        package var firmwareVersion = "0.1"
        package var hardwareVersion = "0.1"
        package var externalAccessoryProtocol = "me.aaron.homeplay"
        package var ssid = "HomePlay"
        /// 识别信息的链路布局：USB 用有线（USB host transport），蓝牙用无线组件。
        package var transport: Iap2Csm.Transport = .wireless
        package init() {}
    }

    package let identity: Iap2MfiIdentity
    package let info: Info
    /// 认证通过后就结束（探针用）；会话要接着收消息，传 false
    package let stopAfterAuth: Bool
    /// 认证前各阶段无进展超时（秒）；0 关闭。任何来包重置；认证后是长连接不设限。
    package var stageTimeout: TimeInterval = 25
    package private(set) var phase: Phase = .linkDetect
    package private(set) var finished = false
    package private(set) var exitCode = 0
    package var onLog: ((String) -> Void)?
    package var onPhase: ((Phase) -> Void)?
    /// 认证之后收到的消息 → 要回的帧
    package var onMessage: ((Iap2Csm.Frame) -> [Iap2Csm.Frame])?
    /// 链路断开 / 被拒 / 超时（finished 变 true 时）
    package var onFinished: ((Int) -> Void)?
    /// 文件传输（专辑封面）完成：ftid + 原始图片字节
    package var onArtwork: ((UInt8, Data) -> Void)?
    /// 传输包装层先关自己的资源（在 onFinished 之前）
    package var transportTeardown: ((Int) -> Void)?

    private var link = Iap2Link()
    private var csmBuffer: [UInt8] = []
    private var fileTransfer = FileTransferReceiver()
    private var progressTimer: DispatchSourceTimer?
    private var linkTicker: DispatchSourceTimer?
    /// 链路层有字节要发（来包/主动发/重传定时器之后）；传输包装层负责写出去
    package var onDrain: (([UInt8]) -> Void)?

    package init(identity: Iap2MfiIdentity, info: Info = Info(), stopAfterAuth: Bool) {
        self.identity = identity; self.info = info; self.stopAfterAuth = stopAfterAuth
    }

    /// 传输已通：发 marker＋SYNC 开跑；250ms 心跳驱动链路层重传/延迟确认。
    package func start() {
        fileTransfer = FileTransferReceiver()
        link.start()
        drain()
        armProgress(stageTimeout, what: "阶段 \(phase.rawValue)")
        let ticker = DispatchSource.makeTimerSource(queue: .main)
        ticker.schedule(deadline: .now() + 0.25, repeating: 0.25)
        ticker.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            self.link.tick()
            self.drain()
        }
        linkTicker = ticker
        ticker.resume()
    }

    /// 传输层收到字节（主线程）。
    package func feed(_ bytes: [UInt8]) {
        guard !finished else { return }
        link.feed(bytes)
        // 认证前，任何来包都算手机有进展，重置阶段计时
        if phase != .authenticated { armProgress(stageTimeout, what: "阶段 \(phase.rawValue)") }
        pumpEvents()
        drain()
    }

    /// 把要发出的字节推给传输层（主线程）。
    private func drain() {
        let out = link.takeOutput()
        if !out.isEmpty { onDrain?(out) }
    }

    /// 兼容拉取式调用方：拿走当前待发字节（drain 之后通常为空）。
    package func takeOutput() -> [UInt8] { link.takeOutput() }

    /// 主动发一帧（主线程）。
    package func send(_ frame: Iap2Csm.Frame) {
        link.sendControl(frame.encoded)
        drain()
    }

    package func finish(_ code: Int) {
        guard !finished else { return }
        finished = true
        cancelProgress()
        linkTicker?.cancel(); linkTicker = nil
        if exitCode == 0 { exitCode = code }
        transportTeardown?(exitCode)
        onFinished?(exitCode)
    }

    // MARK: 内部

    private func log(_ s: String) { onLog?(s) }
    private func setPhase(_ p: Phase) { phase = p; onPhase?(p) }

    private func armProgress(_ seconds: TimeInterval, what: String) {
        guard seconds > 0 else { return }
        progressTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            self.log("\(what)超时（\(Int(seconds))s 无进展），断开等上层重连")
            self.finish(10)
        }
        progressTimer = timer
        timer.resume()
    }

    private func cancelProgress() { progressTimer?.cancel(); progressTimer = nil }

    private func pumpEvents() {
        while let event = link.pollEvent() {
            switch event {
            case .ready:
                setPhase(.identify)
                log("链路同步完成（对方出窗 \(link.peerSynchronization?.maxOutgoing ?? 0)）")
            case .control(let payload):
                handleControl(payload)
            case .fileTransfer(let datagram):
                for out in fileTransfer.feed(datagram) {
                    switch out {
                    case .reply(let bytes): link.sendFileTransfer(bytes)
                    case .complete(let id, let data): onArtwork?(id, data)
                    }
                }
            case .dead(let reason):
                log("链路死了：\(reason)（阶段 \(phase.rawValue)）")
                finish(phase == .authenticated ? 0 : 5)
            }
        }
    }

    private func handleControl(_ payload: [UInt8]) {
        csmBuffer += payload
        let (frames, consumed) = Iap2Csm.parse(from: csmBuffer)
        csmBuffer.removeFirst(consumed)
        for frame in frames {
            switch frame.messageId {
            case Iap2Csm.Identify.start:
                log("iPhone 发 0x1D00 开始识别")
                let reply = Iap2Csm.identificationInformation(
                    name: info.name, model: info.model, manufacturer: info.manufacturer,
                    serialNumber: info.serialNumber, firmwareVersion: info.firmwareVersion,
                    hardwareVersion: info.hardwareVersion, externalAccessoryProtocol: info.externalAccessoryProtocol,
                    bluetoothMac: Iap2AccessoryCore.localBluetoothAddress, ssid: info.ssid,
                    transport: info.transport)
                link.sendControl(reply.encoded)
            case Iap2Csm.Identify.accepted:
                setPhase(.mfi)
                log("识别通过（0x1D02）")
            case Iap2Csm.Identify.rejected:
                let rejected = frame.parameters.map { String(format: "0x%04x", $0.id) }.joined(separator: " ")
                log("识别被拒（0x1D03），被拒参数：\(rejected)")
                finish(6)
            case Iap2Csm.Mfi.requestCertificate:
                log("iPhone 要证书（0xAA00）")
                link.sendControl(Iap2Csm.accessoryCertificate(identity.certificate).encoded)
            case Iap2Csm.Mfi.requestChallenge:
                guard let challenge = Iap2Csm.challenge(of: frame),
                      (1...Iap2Csm.Mfi.maximumChallengeBytes).contains(challenge.count) else {
                    log("挑战载荷长度不合法")
                    finish(7); return
                }
                log("iPhone 发挑战（0xAA02，\(challenge.count) 字节）")
                do {
                    link.sendControl(Iap2Csm.authenticationResponse(try identity.sign(digest: challenge)).encoded)
                } catch {
                    log("签名失败：\(error)")
                    finish(7)
                }
            case Iap2Csm.Mfi.succeeded:
                setPhase(.authenticated)
                cancelProgress()
                log("MFi 认证通过（0xAA05）—— iPhone 认了这个身份")
                if stopAfterAuth { finish(0) }
                else {
                    // 有线：照 MacPlay 声明可供 500mA 并建议手机充电
                    if info.transport == .wired {
                        link.sendControl(Iap2Csm.powerSourceUpdate(availableCurrentMa: 500, shouldCharge: true).encoded)
                        log("已声明供电（0xAE03）")
                    }
                    // 照 MacPlay/DiPlay：认证后发全套 5 组订阅（不只是 Now Playing）。
                    // 手机侧的 CarPlay 状态机在部分 iOS 版本会等配件把订阅发齐。
                    for (frame, name) in [
                        (Iap2Csm.startNowPlayingUpdates(), "NowPlaying(0x5000)"),
                        (Iap2Csm.startRouteGuidanceUpdates(), "RouteGuidance(0x5200)"),
                        (Iap2Csm.startPowerUpdates(), "Power(0xAE00)"),
                        (Iap2Csm.startCommunicationsUpdates(), "Communications(0x4157)"),
                        (Iap2Csm.startCallStateUpdates(), "CallState(0x4154)"),
                    ] {
                        link.sendControl(frame.encoded)
                        log("已订阅 \(name)")
                    }
                }
            case Iap2Csm.Mfi.failed:
                log("MFi 认证失败（0xAA04）—— iPhone 拒了这个身份")
                finish(8)
            default:
                if phase == .authenticated, let onMessage {
                    for reply in onMessage(frame) { link.sendControl(reply.encoded) }
                } else {
                    log(String(format: "别的消息 0x%04x（阶段 %@）", frame.messageId, phase.rawValue))
                    // 協議取證：HOMEPLAY_TRACE_CSM=1 時把沒見過的訊息連同可讀字串記下來，
                    // 用來找出 iPhone 的 now-playing metadata（目前 iAP2 層還沒實作）。
                    if ProcessInfo.processInfo.environment["HOMEPLAY_TRACE_CSM"] == "1" {
                        var text = ""
                        for prm in frame.parameters {
                            let bytes = prm.payload
                            var run: [UInt8] = []
                            func flush() {
                                if run.count >= 4, let s = String(bytes: run, encoding: .utf8), s.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
                                    text += (text.isEmpty ? "" : " | ") + s
                                }
                                run.removeAll()
                            }
                            for b in bytes { if b >= 32 && b < 127 { run.append(b) } else { flush() } }
                            flush()
                        }
                        if !text.isEmpty {
                            FileHandle.standardError.write("CSM 0x\(String(format: "%04x", frame.messageId)) 可讀字串：\(text)\n".data(using: .utf8)!)
                        }
                    }
                }
                // 0x4E0D 无线 CarPlay 状态（0=不可用 1=可用）——交接阶段的重要风向标
                if frame.messageId == 0x4E0D, let status = frame.parameters.first(where: { $0.id == 0 })?.payload.first {
                    log(String(format: "无线 CarPlay 状态（0x4E0D）：%@（0=不可用 1=可用）", status == 1 ? "可用" : "不可用"))
                }
            }
        }
    }

    /// 识别信息里的蓝牙 MAC 字段：本机蓝牙地址（无蓝牙时填零，有线会话不靠它）
    package static var localBluetoothAddress: String {
        (IOBluetoothHostController.default()?.addressAsString() ?? "00:00:00:00:00:00")
            .uppercased().replacingOccurrences(of: "-", with: ":")
    }
}
