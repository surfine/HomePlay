// 无线 CarPlay 会话的控制面编排（接收端）。行为对应 MacPlay Engine/protocol/cpStack.ts：
// 手机连上 _airplay._tcp 控制口后，依次 /info → /pair-setup → /pair-verify（M4 之后整条连接加密）→
// /auth-setup → 会话级 SETUP（计时口、事件口）→ 流级 SETUP（屏幕 110，音频暂时只占位）→ RECORD。
// 屏幕流解密后喂 H264Sink（同一套 wire 推给桌宠／App）；桌宠的触控经事件通道变成 HID 报告。
// 音频（100/101/102）收 ChaCha20-Poly1305 加密的 RTP，AAC-LC 解码进 AVAudioEngine 出声（见 CarPlayAudio.swift）。
// iAP 数据通道（130）：SETUP 时绑数据口、解 APTransportPackage，把原始 iAP2 字节经 IapTunnelLink 交给接收器
// （反向经事件通道 iAPSendMessage，见 IapTunnel.swift）。仪表盘副屏还没做：只记日志。
import Foundation
import Network
import CryptoKit
import H264

package struct CarPlaySessionConfig {
    package var info: InfoConfig
    package var port: UInt16 = 7000
    package var serviceName = "HomePlay"
    /// 会话级 SETUP 是否声明 iAPChannel（流 130 的 iAP 隧道已实现，照 MacPlay 默认声明；
    /// 接收器用 HOMEPLAY_IAP_CHANNEL=0 关掉）。关掉时手机若仍 SETUP 130，照样绑口服务。
    package var advertiseIAPChannel = true
    /// 选定的 iPhone 蓝牙地址：只探这台的 _carplay-ctrl
    package var phoneBluetoothAddress: String?
    package var probeForPhone = true
    package init(info: InfoConfig) { self.info = info }
}

/// ControlCipher → 事件通道要的 MessageSealer（ControlCipher.feed 自己缓存不完整的帧）
final class ControlCipherSealer: MessageSealer {
    let cipher: ControlCipher
    init(_ cipher: ControlCipher) { self.cipher = cipher }
    func seal(_ plain: Data) throws -> Data { Data(try cipher.encrypt([UInt8](plain))) }
    func open(_ buffered: Data) throws -> (plain: Data, rest: Data) { (Data(try cipher.feed([UInt8](buffered))), Data()) }
}

package final class CarPlaySession {
    package private(set) var config: CarPlaySessionConfig
    /// 自动匹配/重按发现手机后回填地址（CtrlProbe 每次探测时读 config）
    package func setPhoneBluetoothAddress(_ address: String) {
        config.phoneBluetoothAddress = address
    }
    private let store: PairingStore
    private let signer: AccessorySigner
    private let sink: H264Sink
    private let queue = DispatchQueue(label: "session.control")
    private static let queueKey = DispatchSpecificKey<Bool>()
    private var discovery: Discovery?
    private var probe: CtrlProbe?
    private var conns: [ObjectIdentifier: ControlConnection] = [:]
    private var live: ControlConnection?
    private var heartbeat: DispatchSourceTimer?

    package var onLog: ((String) -> Void)?
    package var onActive: (() -> Void)?
    package var onEnded: ((String) -> Void)?
    /// 手机的控制连接一接入就叫（比 RECORD 早）：用来取消 IPv6 备用重试
    package var onControlConnected: ((String) -> Void)?
    /// 探測手機的 _carplay-ctrl 時的結構化事件（診斷用；在探測佇列上呼叫）
    package var onProbeEvent: ((CtrlProbeEvent) -> Void)?
    /// 手机发来的 `POST /command`（控制口或事件通道），已自动 ack：type 与 params（disableBluetooth、modesChanged…）
    package var onCommand: ((_ type: String, _ params: [String: Any]) -> Void)?
    /// 手机 SETUP 了流 130（iAP 数据通道）：交出隧道句柄。在会话队列上叫；上层自己切线程。
    /// 会话结束或流被 TEARDOWN 时句柄的 onClosed 会叫一次。
    package var onIapTunnel: ((IapTunnelLink) -> Void)?
    /// CarPlay 影片：手機要車機播／暫停／跳轉／停（op：play、rate、seek、stop、show），在會話佇列上叫
    package var onVideo: ((_ op: String, _ fields: [String: Any]) -> Void)?
    /// 圓角遮罩：手機協商了 cornerMasks（negotiated）、送來 topLeftCornerMask（8 位元灰階 PNG，亮＝保留）
    package var onCornerMask: ((_ negotiated: Bool, _ png: Data?) -> Void)?
    /// 手機這一版 iOS 的識別（osBuildVersion，沒有就用 SETUP 的 user-agent AirPlay/x.y.z）：換版就要重學圓角
    package var onPhoneBuild: ((String) -> Void)?

    package init(config: CarPlaySessionConfig, store: PairingStore, signer: AccessorySigner, sink: H264Sink) {
        queue.setSpecific(key: Self.queueKey, value: true)
        self.config = config; self.store = store; self.signer = signer; self.sink = sink
    }

    /// 广播 _airplay._tcp 并开始叫手机回连。返回控制口端口。
    @discardableResult
    package func start() throws -> UInt16 {
        let id = store.identity
        let txt = DiscoveryTXT(deviceid: config.info.deviceID, pi: id.pairingId, pk: id.publicKeyHex)
        var t = txt; t.model = config.info.model
        let d = Discovery(serviceName: config.serviceName, txt: t)
        let port = try d.start(port: config.port) { [weak self] c in self?.queue.async { self?.accept(c) } }
        discovery = d
        log("控制口 \(port)，广播 _airplay._tcp（\(config.serviceName)）")
        startProbe()
        let hb = DispatchSource.makeTimerSource(queue: queue)
        hb.schedule(deadline: .now() + 1, repeating: 1)
        hb.setEventHandler { [weak self] in self?.checkHeartbeat() }
        hb.resume(); heartbeat = hb
        return port
    }

    package func stop() {
        queue.sync {
            probe?.stop(); probe = nil
            heartbeat?.cancel(); heartbeat = nil
            for c in conns.values { c.close() }
            conns = [:]; live = nil
            discovery?.stop(); discovery = nil
        }
    }

    /// 換顯示設定（圓角策略、換手機）：下一次 /info 照新的回；搭配 dropConnections() 讓手機立刻重連
    /// 已在控制佇列上（例如 SETUP 處理當中的 onPhoneBuild）就當場改：這次 SETUP 的回應與隨後的 /info 照新的回
    /// （手機的順序固定是 SETUP → GET /info → RECORD）；不在就排上佇列（同步會卡死）。
    package func updateMainDisplay(_ d: DisplayConfig) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true { config.info.main = d } else { queue.async { self.config.info.main = d } }
    }
    /// 關掉跟手機的 RTSP 連線（控制口照樣監聽）：手機會結束這次會話，再照 0x4301 連回來
    package func dropConnections(_ why: String = "重開會話") {
        queue.async {
            self.end(why)   // 有進行中的會話：照正規流程結束（通知桌寵、叫手機回來）
            for c in self.conns.values { c.close() }
            self.conns = [:]
        }
    }

    /// 桌宠的 0..1 触控 → HID 报告
    package func sendTouch(x: Double, y: Double, down: Bool) {
        queue.async { [self] in
            live?.event?.sendTouches([(id: 0, x: x, y: y, down: down)],
                                     streamWidth: config.info.main.widthPixels, streamHeight: config.info.main.heightPixels)
        }
    }
    package func requestKeyframe() { queue.async { [self] in live?.event?.forceKeyFrame() } }
    /// 桌宠的媒体键 → CarPlay HID（播放/暂停/上一首/下一首）。没有 live 会话就丢。
    package func sendMedia(_ button: HID.MediaButton) { queue.async { [self] in live?.event?.sendMedia(button) } }
    /// 桌宠/诊断触发 Siri（与按车机 Siri 键等价）
    /// 会话还没 live 时先挂起，RECORD 之后补发（F5 可以先按、桌宠再连）
    private var siriKey = SiriKeyState()
    /// `.click`＝按一下（buttonDown＋buttonUp）；`.down`／`.up`＝按住說話，放開才結束
    package func requestSiri(_ action: SiriAction = .click) {
        queue.async { [self] in
            let e = live?.event
            for a in siriKey.press(action, live: e != nil) { e?.sendSiri(action: a) }
        }
    }
    /// 桌寵的電話鍵（接聽＝hookSwitch、拒接／掛斷＝drop）→ CarPlay 電話 HID。沒有 live 會話就丟。
    package func sendTelephony(_ button: HID.TelephonyButton) {
        queue.async { [self] in live?.event?.sendTelephony(button) }
    }

    // MARK: CarPlay 影片（停車時播影片）

    /// 設定改了：記到 /info 並即時告訴手機（要等 SETUP 啟用、事件通道就緒才真正送）
    package func setVideoAllowed(_ on: Bool) {
        queue.async { [self] in
            config.info.videoAllowed = on
            for cc in conns.values { cc.videoAllowed(on) }
        }
    }
    /// 桌寵播放器的最新狀態（回答手機每秒一次的 playbackInfo）
    package func videoState(_ st: CarVideoProtocol.PlayerState) { queue.async { [self] in live?.videoPlayer = st } }
    /// 車機端（桌寵）自己按了播放／暫停：通知手機（不能當 HID 送，手機會因此結束影片）
    package func videoUserPlayback(playing: Bool) {
        queue.async { [self] in
            guard let cc = live else { return }
            cc.sendVideo(CarVideoProtocol.playbackStateNotification(playing: playing, itemUUID: cc.videoItem))
        }
    }
    /// 播不了：告訴手機，它會收起 CarPlay 上的播放狀態
    package func videoError(code: Int) {
        queue.async { [self] in
            guard let cc = live else { return }
            cc.sendVideo(CarVideoProtocol.errorNotification(code: code, itemUUID: cc.videoItem))
        }
    }

    /// 用户切换手机：结束旧手机的控制会话（含加密控制通道），按新地址重新叫回连。
    /// 不动 Bonjour 发现和心跳：控制口不用重启，新手机可以直接连回来。
    /// then 在会话队列上调用（调用方要回主队列请自己转）。
    package func switchPhone(to address: String, then: (() -> Void)? = nil) {
        queue.async { [self] in
            config.phoneBluetoothAddress = address
            if let cc = live {
                live = nil
                cc.close()
                conns[ObjectIdentifier(cc)] = nil
                log("切换手机：结束旧会话")
                onEnded?("切换手机")
            }
            for c in conns.values { c.close() }
            conns = [:]
            probe?.stop(); probe = nil
            startProbe()
            log("切换手机：重新叫 \(address) 回连")
            then?()
        }
    }

    // MARK: 内部

    private func log(_ s: String) { onLog?(s) }

    private func startProbe() {
        guard config.probeForPhone, probe == nil else { return }
        let p = CtrlProbe(deviceId: config.info.deviceID, phoneBluetoothAddress: config.phoneBluetoothAddress)
        p.onLog = { [weak self] s in self?.log(s) }
        p.onEvent = { [weak self] e in self?.onProbeEvent?(e) }
        p.start(); probe = p
    }

    private func accept(_ c: NWConnection) {
        guard discovery != nil else { c.cancel(); return }   // 已 stop
        let cc = ControlConnection(conn: c, session: self)
        conns[ObjectIdentifier(cc)] = cc
        log("控制连接来自 \(cc.peerHost)")
        onControlConnected?(cc.peerHost)
        cc.start()
    }

    fileprivate func connectionClosed(_ cc: ControlConnection) {
        conns[ObjectIdentifier(cc)] = nil
        cc.close()
        if live === cc { end("控制连接关闭") } else if live == nil { startProbe() }
    }

    fileprivate func became(live cc: ControlConnection) {
        if let old = live, old !== cc {   // 第二条会话顶替旧的：旧的先关，免得两路屏幕流同时喂 sink
            conns[ObjectIdentifier(old)] = nil
            old.close()
            log("第二条会话顶替旧会话（\(old.peerHost) → \(cc.peerHost)）：任何时刻只保留一个")
        }
        live = cc
        probe?.stop(); probe = nil   // 真的开始了才停叫回连
        log("RECORD：会话开始")
        onActive?()
        cc.videoBecameLive()
        for a in siriKey.becameLive() { cc.event?.sendSiri(action: a) }
    }

    fileprivate func end(_ why: String) {
        guard let cc = live else { return }
        live = nil
        cc.close()
        conns[ObjectIdentifier(cc)] = nil
        log("会话结束：\(why)")
        onEnded?(why)
        startProbe()   // 手机还在附近就再叫它回来
    }

    private func checkHeartbeat() {
        for c in conns.values where c !== live && Date().timeIntervalSince(c.acceptedAt) > 60 {
            log("回收 60 秒没进会话的控制连接 \(c.peerHost)")
            connectionClosed(c)
        }
        guard let cc = live else { return }
        let idle = Date().timeIntervalSince(max(cc.lastRead, cc.lastFrame))
        if idle > 15 { end("15 秒没有控制消息也没有画面") }
    }

    // ControlConnection 用的依赖
    fileprivate var pairingStore: PairingStore { store }
    fileprivate var accessorySigner: AccessorySigner { signer }
    fileprivate var h264Sink: H264Sink { sink }
    fileprivate var controlQueue: DispatchQueue { queue }
    fileprivate func note(_ s: String) { log(s) }
}

// MARK: - 一条控制连接

private final class ControlConnection {
    let conn: NWConnection
    unowned let session: CarPlaySession
    let peerHost: String
    var parser = RTSPParser()
    var cipher: ControlCipher?
    let pairSetup: PairSetup
    let pairVerify: PairVerify
    var screen: ScreenStream?
    var adapter: ScreenStreamH264Adapter?
    var event: EventChannel?
    var timing: TimingServer?
    var audio: [CarPlayAudioStream] = []
    var iapTunnel: IapTunnel?
    var iapLink: IapTunnelLink?
    // CarPlay 影片
    var videoGate = CarVideoAllowGate()
    var videoSettings: CarVideoSettingsChannel?
    var videoRemoteStreams: Set<Int> = []
    var nextVideoStreamID = 3
    var videoStreamID: Int?          // 最近一則播放訊息的 X-Apple-StreamID（應答走同一個）
    var videoItem: String?
    var videoPlayer: CarVideoProtocol.PlayerState?
    var lastRead = Date()
    var lastFrame = Date.distantPast
    var closed = false
    var endAfterReply = false
    let acceptedAt = Date()
    /// pair-verify 通过、控制通道已加密：之后的请求才算这台手机发的
    var authenticated: Bool { pairVerify.verified && cipher != nil }   // 整个会话的 TEARDOWN：应答发出去之后再结束

    init(conn: NWConnection, session: CarPlaySession) {
        self.conn = conn; self.session = session
        pairSetup = PairSetup(store: session.pairingStore)
        pairVerify = PairVerify(store: session.pairingStore)
        if case .hostPort(let h, _) = conn.endpoint {
            switch h {
            case .ipv4(let a): peerHost = "\(a)"
            case .ipv6(let a): peerHost = "\(a)"
            case .name(let n, _): peerHost = n
            @unknown default: peerHost = "?"
            }
        } else { peerHost = "?" }
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .failed, .cancelled: self.session.controlQueue.async { self.session.connectionClosed(self) }
            default: break
            }
        }
        conn.start(queue: session.controlQueue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        screen?.stop(); screen = nil
        event?.stop(); event = nil
        timing?.stop(); timing = nil
        for a in audio { a.close() }
        audio = []
        closeIapTunnel()
        videoSettings?.stop(); videoSettings = nil
    }

    /// 流 130 收口：停数据口、告诉上层句柄已失效（只报一次）
    private func closeIapTunnel() {
        iapTunnel?.stop(); iapTunnel = nil
        iapLink?.tearDown(); iapLink = nil
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.lastRead = Date(); self.ingest(data) }
            if done || err != nil { self.session.connectionClosed(self); return }
            self.receive()
        }
    }

    private func ingest(_ data: Data) {
        var plain = data
        if let cipher {
            do { plain = Data(try cipher.feed([UInt8](data))) }
            catch { session.note("控制通道解密失败：\(error)"); session.connectionClosed(self); return }
        }
        let reqs = parser.feed(plain)
        if parser.overflowed { session.note("控制请求过大，断开 \(peerHost)"); session.connectionClosed(self); return }
        for req in reqs {
            if req.isResponse { continue }
            let res: RTSPResponse
            do { res = try handle(req) } catch {
                session.note("处理 \(req.method) \(req.path) 出错：\(error)")
                res = RTSPResponse(status: 500)
            }
            let out = rtspSerialize(res, for: req)
            let ending = endAfterReply
            do {
                conn.send(content: try cipher.map { Data(try $0.encrypt([UInt8](out))) } ?? out,
                          completion: .contentProcessed { [weak self] _ in
                    guard ending, let self else { return }
                    self.session.controlQueue.async {
                        if self.session.isLive(self) { self.session.end("手机结束会话") } else { self.close() }
                    }
                })
            } catch { session.note("控制通道加密失败：\(error)") }
            // pair-verify M4 用明文回；从下一条起加密
            if cipher == nil, let k = pairVerify.controlKeys {
                cipher = ControlCipher(keys: k)
                session.note("控制通道已加密")
            }
        }
    }

    private static let plist = "application/x-apple-binary-plist"
    private static let pairing = "application/pairing+tlv8"
    private static let octet = "application/octet-stream"

    private func handle(_ req: RTSPMessage) throws -> RTSPResponse {
        let path = req.path.lowercased()
        let chatty = req.method == "OPTIONS" || path.hasSuffix("/feedback")
        if !chatty { session.note("< \(req.method) \(req.path)（\(req.body.count)B）") }

        // 只有 /info、配对两步可以在认证前走；其余必须 pair-verify 通过且已加密（MacPlay 的流程也是如此）
        let preAuthOK = path.hasSuffix("/info") || path.hasSuffix("/pair-setup") || path.hasSuffix("/pair-verify") || req.method == "OPTIONS"
        if !preAuthOK && !authenticated {
            session.note("拒绝未认证的 \(req.method) \(req.path)")
            return RTSPResponse(status: 470)
        }
        switch req.method {
        case "SETUP": return try setup(req)
        case "RECORD":
            session.became(live: self)
            return RTSPResponse(status: 200)
        case "TEARDOWN": return teardown(req)
        default: break
        }
        if path.hasSuffix("/pair-setup") {
            return RTSPResponse(status: 200, headers: [("Content-Type", Self.pairing)], body: Data(pairSetup.handle([UInt8](req.body))))
        }
        if path.hasSuffix("/pair-verify") {
            return RTSPResponse(status: 200, headers: [("Content-Type", Self.pairing)], body: Data(pairVerify.handle([UInt8](req.body))))
        }
        if path.hasSuffix("/auth-setup") {
            guard let body = try AuthSetup.respond(body: [UInt8](req.body), signer: session.accessorySigner) else {
                return RTSPResponse(status: 400)
            }
            session.note("auth-setup 已签（证书 \(session.accessorySigner.certificate.count)B）")
            return RTSPResponse(status: 200, headers: [("Content-Type", Self.octet)], body: Data(body))
        }
        if path.hasSuffix("/info") {
            let info = CarPlayPlist.info(session.config.info)
            let formats = (info["audioFormats"] as? [[String: Any]]) ?? []
            let summary = formats.map { "\($0["type"] ?? "?")/\($0["audioType"] ?? "?")=\($0["audioOutputFormats"] ?? "?")" }.joined(separator: " ")
            session.note("回 /info：features=0x\(String((info["features"] as? Int) ?? 0, radix: 16)) audioFormats[\(formats.count)] \(summary)")
            return RTSPResponse(status: 200, headers: [("Content-Type", Self.plist)], body: try CarPlayPlist.infoResponse(session.config.info))
        }
        if req.method == "POST", path.hasSuffix("/command") {
            if let sid = req.headers.first(where: { $0.key.lowercased() == "x-apple-streamid" }).flatMap({ Int($0.value.trimmingCharacters(in: .whitespaces)) }) {
                handleVideo(streamID: sid, body: req.body)   // 影片遙控會話的訊息；應答走事件通道
                return RTSPResponse(status: 200)
            }
            if let d = try? BPlist.decodeDict(req.body), d["type"] as? String == "requestUI",
               (d["params"] as? [String: Any])?["url"] as? String == CarVideoProtocol.uiURL {
                session.note("requestUI videoplayback:（打開車機播放器）")
                session.onVideo?("show", [:])
                return RTSPResponse(status: 200)
            }
            session.dispatchCommand(req.body, via: "控制口")
            return RTSPResponse(status: 200)
        }
        if req.method == "POST", path.hasSuffix("/feedback") {
            // 时钟驱动的缓冲流（102）没有播放位置会被手机判死拆掉；照 MacPlay 报
            // origin 采样 + 按真实时间外推的当前位置，迟后量 = 协商的 audioLatencyMs
            guard !audio.isEmpty else { return RTSPResponse(status: 200) }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let streams: [[String: Any]] = audio.map { a in
                var s: [String: Any] = ["type": a.type, "sampleRate": a.sampleRate]
                if let o = a.origin {
                    let latencySec = Double(a.latencyMs) / 1000
                    let elapsedSec = max(0, Double(Int64(bitPattern: nowNs &- o.atNs)) / 1e9 - latencySec)
                    let play = o.firstSample &+ UInt32(elapsedSec * Double(a.sampleRate))
                    if let id = a.connectionID { s["streamConnectionID"] = id }
                    s["timestamp"] = Int64(bitPattern: timing?.syncedNTP() ?? 0)
                    s["timestampRawNs"] = Int64(bitPattern: nowNs)
                    s["sampleTime"] = play
                }
                return s
            }
            return RTSPResponse(status: 200, headers: [("Content-Type", Self.plist)], body: try BPlist.encode(["streams": streams]))
        }
        if req.method == "SET_PARAMETER", let d = try? BPlist.decodeDict(req.body), let png = CornerMaskProtocol.find(d) {
            session.note("圓角遮罩（SET_PARAMETER，\(png.count)B）")
            session.onCornerMask?(true, png)
            return RTSPResponse(status: 200)
        }
        if !chatty { session.note("未处理 \(req.method) \(req.path)（回 200）") }
        return RTSPResponse(status: 200)
    }

    private func setup(_ req: RTSPMessage) throws -> RTSPResponse {
        let dict = try BPlist.decodeDict(req.body)
        guard authenticated, let shared = pairVerify.sharedSecret else {
            session.note("SETUP 在 pair-verify 之前到了")
            return RTSPResponse(status: 470)
        }
        if let streams = dict["streams"] as? [[String: Any]] {
            var resp: [[String: Any]] = []
            for sd in streams {
                let type = (sd["type"] as? NSNumber)?.intValue ?? -1
                let sid = (sd["streamConnectionID"] as? NSNumber)?.uint64Value ?? 0
                switch type {
                case CarPlayStream.mainScreen:
                    let key = deriveStreamKey(sharedSecret: shared, salt: StreamKeyInfo.salt(streamConnectionID: sid),
                                              info: "DataStream-Output-Encryption-Key")
                    screen?.stop(); screen = nil; adapter = nil   // 重复的屏幕 SETUP：旧的先停
                    let s = ScreenStream(key: Data(key))
                    let a = ScreenStreamH264Adapter(sink: session.h264Sink)
                    a.attach(to: s)
                    let onFrame = s.onFrame
                    s.onFrame = { [weak self] nals, key in
                        self?.session.controlQueue.async { self?.lastFrame = Date() }
                        onFrame?(nals, key)
                    }
                    s.onError = { [weak self] e in self?.session.note("屏幕流：\(e)") }
                    let port = try s.start()
                    screen = s; adapter = a
                    session.note("SETUP 屏幕（110，dataPort \(port)，id \(sid)）")
                    if let png = CornerMaskProtocol.find(sd) { session.note("圓角遮罩（屏幕 SETUP，\(png.count)B）"); session.onCornerMask?(true, png) }
                    resp.append(["type": type, "dataPort": Int(port)])
                case CarPlayStream.mainAudio, CarPlayStream.altAudio, CarPlayStream.mainHighAudio:
                    // 同类型的重复 SETUP：旧的先收掉
                    audio.removeAll { old in
                        guard old.type == type else { return false }
                        old.close(); return true
                    }
                    let key = deriveStreamKey(sharedSecret: shared, salt: StreamKeyInfo.salt(streamConnectionID: sid),
                                              info: "DataStream-Output-Encryption-Key")
                    let fmt = (sd["audioFormat"] as? NSNumber)?.intValue ?? 0
                    let latencyMs = (sd["audioLatencyMs"] as? NSNumber)?.intValue ?? 0
                    let (codec, canPlay) = audioCodec(fromFormat: fmt)
                    // type 100（MainAudio）帶 dataPort＝手機要麥克風（Siri/電話）。上行是 Opus，
                    // 密鑰是 Output 的鏡像；包格式照 MacPlay mic/src/lib.rs。
                    let phoneMicPort = (sd["dataPort"] as? NSNumber)?.uint16Value ?? 0
                    session.note("SETUP 流 \(type) 参数：fmt=0x\(String(fmt, radix: 16)) dataPort=\(phoneMicPort) audioType=\(sd["audioType"] as? String ?? "?")")
                    var mic: MicUplink?
                    if type == CarPlayStream.mainAudio, phoneMicPort > 0 {
                        // 上行负载跟着下行协商：Opus 位在就编 Opus；否则手机要的是 PCM
                        //（无线 Siri 也可能给 fmt=0x40/24000 单声道），按 SETUP 的率/声道发
                        // 16-bit 大端 PCM。MacPlay cpStack 同样 `isOpus ? opus : pcm`。
                        let wire: MicUplink.WireCodec
                        let rate: Int
                        let micChannels: Int
                        if fmt & 0x70000000 != 0 {
                            wire = .opus
                            rate = (fmt & 0x40000000) != 0 ? 48000 : ((fmt & 0x20000000) != 0 ? 24000 : 16000)
                            micChannels = 1
                        } else {
                            wire = .pcm
                            rate = codec.rate
                            micChannels = codec.channels
                        }
                        let micKey = deriveStreamKey(sharedSecret: shared, salt: StreamKeyInfo.salt(streamConnectionID: sid),
                                                     info: "DataStream-Input-Encryption-Key")
                        let framesPerPacket = (sd["framesPerPacket"] as? NSNumber)?.intValue ?? 0
                        let frameMs = framesPerPacket > 0 ? max(5, framesPerPacket * 1000 / rate) : 20
                        let bitrate = rate <= 24000 ? 48000 : (rate <= 32000 ? 64000 : 96000)
                        // 電話與 Siri 開回音消除：Mac 喇叭的聲音不能被收回去給對方／Siri 聽
                        let voice = MicUplink.wantsVoiceProcessing(audioType: sd["audioType"] as? String)
                        let m = MicUplink(codec: wire, key: Data(micKey), payloadType: type, sampleRate: rate,
                                          channels: micChannels, frameMs: frameMs, bitrate: bitrate,
                                          host: peerHost, port: phoneMicPort,
                                          voiceProcessing: voice && canPlay,
                                          downlinkRate: codec.rate, downlinkChannels: codec.channels)
                        m.onLog = { [weak self] s in self?.session.note(s) }
                        mic = m
                    }
                    let a = try CarPlayAudioStream(
                        type: type, connectionID: sd["streamConnectionID"] as? NSNumber,
                        key: Data(key), codec: codec,
                        latencyMs: latencyMs > 0 ? latencyMs : (type == CarPlayStream.mainHighAudio ? 1000 : 0),
                        canPlay: canPlay, mic: mic)
                    mic?.start()   // Siri 可能先要麥克風、後才有下行音訊；SETUP 一完成就開始送
                    a.onLog = { [weak self] s in self?.session.note(s) }
                    let described = sd["audioType"] as? String ?? "?"
                    let codecName = canPlay ? (codec.isAAC ? "AAC-LC" : (codec.isOpus ? "Opus" : "PCM")) : "暂不解"
                    let micNote = mic.map { "，麦克风上行 \($0.description)" } ?? ""
                    session.note("SETUP 音频 \(type)（\(described)，\(codecName) \(codec.rate)×\(codec.channels)，dataPort \(a.dataPort)\(micNote)）")
                    audio.append(a)
                    resp.append(["type": type, "dataPort": Int(a.dataPort), "controlPort": Int(a.controlPort),
                                 "streamConnectionID": sd["streamConnectionID"] ?? 0])
                case CarPlayStream.data:
                    // iAP 数据通道（MacPlay _setupDataStream）：只认 iAP 的 clientTypeUUID；
                    // 密钥盐用 seed（手机给的；没有就退回 streamConnectionID），Output 方向。
                    let uuid = (sd["clientTypeUUID"] as? String)?.uppercased() ?? ""
                    if uuid == CarVideoProtocol.settingsChannelUUID {
                        // 影片設定資料流：一定要開（拒絕會被拆會話）；讀用 Output、寫用 Input
                        let seed = (sd["seed"] as? NSNumber)?.uint64Value ?? sid
                        let salt = StreamKeyInfo.salt(streamConnectionID: seed)
                        let ch = CarVideoSettingsChannel(readKey: Data(deriveStreamKey(sharedSecret: shared, salt: salt, info: StreamKeyInfo.output)),
                                                         writeKey: Data(deriveStreamKey(sharedSecret: shared, salt: salt, info: StreamKeyInfo.input)))
                        ch.onLog = { [weak self] s in self?.session.note(s) }
                        videoSettings?.stop()
                        let port = try ch.start()
                        videoSettings = ch
                        session.note("SETUP 影片設定資料流（130，streamID 2，dataPort \(port)）")
                        var r: [String: Any] = ["type": type, "streamID": 2, "dataPort": Int(port)]
                        if let c = sd["streamConnectionID"] { r["streamConnectionID"] = c }
                        resp.append(r)
                        continue
                    }
                    if CarVideoProtocol.remoteControlUUIDs.contains(uuid), (sd["controlType"] as? NSNumber)?.intValue == 1 {
                        // 影片遙控會話：沒有 socket，只給 streamID（3 起）；訊息之後走 /command 的 X-Apple-StreamID
                        let id = nextVideoStreamID; nextVideoStreamID += 1
                        videoRemoteStreams.insert(id)
                        session.note("SETUP 影片遙控會話（\(uuid.prefix(8))，streamID \(id)）")
                        resp.append(["type": type, "streamID": id])
                        continue
                    }
                    guard uuid == IapTunnel.clientTypeUUID else {
                        session.note("SETUP 数据流 130（clientTypeUUID \(uuid.isEmpty ? "缺" : uuid)）不是 iAP，不回")
                        continue
                    }
                    let seed = (sd["seed"] as? NSNumber)?.uint64Value ?? sid
                    let key = deriveStreamKey(sharedSecret: shared, salt: StreamKeyInfo.salt(streamConnectionID: seed),
                                              info: StreamKeyInfo.output)
                    closeIapTunnel()   // 重复的 SETUP：旧的先收
                    let t = IapTunnel(key: Data(key))
                    let port = try t.start()
                    let link = IapTunnelLink(dataPort: port, sender: { [weak self] d in
                        self?.event?.sendIapMessage(d) ?? false
                    })
                    t.onConnected = { [weak self, weak link] peer in
                        self?.session.note("iAP 隧道已连（\(peer)）")
                        link?.onConnected?(peer)
                    }
                    t.onIap = { [weak link] d in link?.onIap?(d) }
                    t.onClosed = { [weak self, weak link] in
                        self?.session.note("iAP 隧道数据口断开")
                        link?.onClosed?()
                    }
                    t.onError = { [weak self] e in self?.session.note("iAP 隧道：\(e)") }
                    iapTunnel = t; iapLink = link
                    session.note("SETUP iAP 隧道（130，dataPort \(port)，seed \(seed)）")
                    resp.append(["type": type, "streamID": 1, "dataPort": Int(port)])
                    session.onIapTunnel?(link)
                default:
                    session.note("SETUP 流 \(type) 还没实现，不回")
                }
            }
            return RTSPResponse(status: 200, headers: [("Content-Type", Self.plist)], body: try BPlist.encode(["streams": resp]))
        }

        // 会话级：计时口、事件口（重复 SETUP 时旧的先停）
        timing?.stop(); timing = nil
        event?.stop(); event = nil
        if let name = dict["name"] as? String { session.note("手机：\(name) \(dict["model"] ?? "")") }
        let t = TimingServer()
        let timingPort = try t.listen()
        if let peer = (dict["timingPort"] as? NSNumber)?.uint16Value, peer > 0 { t.start(peerHost: peerHost, peerPort: peer) }
        t.onStats = { [weak self] s in self?.session.note(s) }
        timing = t
        let ev = EventChannel(sealer: { [weak self] in
            guard let s = self?.pairVerify.sharedSecret else { return nil }
            // 事件通道不交换方向：我们用 Events-Write 写、Events-Read 读
            return ControlCipherSealer(ControlCipher(
                readKey: PairingCrypto.hkdfSHA512(s, salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
                writeKey: PairingCrypto.hkdfSHA512(s, salt: "Events-Salt", info: "Events-Write-Encryption-Key")))
        })
        ev.onConnected = { [weak self] in
            guard let self else { return }
            self.session.note("事件通道已连上")
            self.session.controlQueue.async { if let v = self.videoGate.set(eventReady: true) { self.sendAllowed(v) } }
        }
        ev.onClosed = { [weak self] in
            guard let self else { return }
            self.session.controlQueue.async { _ = self.videoGate.set(eventReady: false) }
        }
        ev.onRequest = { [weak self] m in
            guard let self else { return }
            if m.method == "POST", m.path.lowercased().hasSuffix("/command") {
                self.session.controlQueue.async { self.session.dispatchCommand(m.body, via: "事件通道") }
            } else {
                self.session.note("事件通道请求 \(m.method) \(m.path)")
            }
        }
        ev.onError = { [weak self] e in self?.session.note("事件通道：\(e)") }
        let eventPort = try ev.start()
        event = ev
        session.note("SETUP 会话（timingPort \(timingPort)，eventPort \(eventPort)）")
        var body = try BPlist.decodeDict(try CarPlayPlist.setupSessionResponse(
            timingPort: Int(timingPort), eventPort: Int(eventPort), hevc: session.config.info.hevc))
        if !session.config.advertiseIAPChannel, var f = body["enabledFeatures"] as? [String] {
            f.removeAll { $0 == "iAPChannel" }; body["enabledFeatures"] = f
        }
        // 圓角遮罩：手機提議才啟用；沒提議（舊 iOS）也告訴桌寵，讓它用自己的同心退路
        let proposed = (dict["features"] as? [String]) ?? []
        session.note("SETUP：手機提議 features=\(proposed)")
        let ua = req.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value ?? ""
        let build = (dict["osBuildVersion"] as? String) ?? ua.trimmingCharacters(in: .whitespaces)
        if !build.isEmpty { session.onPhoneBuild?(build) }
        if session.config.info.main.cornerMasks == true {
            let on = proposed.contains("cornerMasks")
            if on { body["enabledFeatures"] = ((body["enabledFeatures"] as? [String]) ?? []) + ["cornerMasks"] }
            session.onCornerMask?(on, nil)
        } else {
            session.onCornerMask?(false, nil)   // 平常的連線（安全區）：讓桌寵知道不必縮放
        }
        if session.config.info.videoPlayback, CarVideoProtocol.proposed(dict) {
            body["enabledFeatures"] = ((body["enabledFeatures"] as? [String]) ?? []) + [CarVideoProtocol.feature]
            _ = videoGate.set(desired: session.config.info.videoAllowed)
            if let v = videoGate.set(feature: true) { sendAllowed(v) }
            session.note("SETUP：手機提議 videoPlayback，已啟用（允許＝\(session.config.info.videoAllowed)）")
        }
        return RTSPResponse(status: 200, headers: [("Content-Type", Self.plist)], body: try BPlist.encode(body))
    }

    // MARK: CarPlay 影片

    func videoAllowed(_ on: Bool) { if let v = videoGate.set(desired: on) { sendAllowed(v) } }
    func videoBecameLive() { if let v = videoGate.resend() { sendAllowed(v) } }
    func sendAllowed(_ on: Bool) {
        guard let b = try? CarVideoProtocol.setAllowedCommand(on) else { return }
        event?.sendCommand(b)
        session.note("setVideoPlaybackAllowed \(on)")
    }
    /// 應答／通知：事件通道 POST /command，帶播放那條遙控會話的 streamID
    func sendVideo(_ message: [String: Any], streamID: Int? = nil) {
        guard let sid = streamID ?? videoStreamID, let b = try? CarVideoProtocol.wrap(message) else { return }
        event?.sendCommand(b, streamID: sid)
    }

    /// 手機的播放訊息（{params:{data:bplist}} 拆開後）
    func handleVideo(streamID sid: Int, body: Data) {
        guard let m = CarVideoProtocol.unwrap(body), let type = m["type"] as? String else {
            session.note("影片訊息（streamID \(sid)）拆不開"); return
        }
        let mid = m["messageID"]
        switch type {
        case "insertPlayQueueItem":
            videoStreamID = sid
            guard let item = CarVideoProtocol.parseItem(m) else {
                let uuid = ((m["item"] as? [String: Any])?["uuid"]).map { "\($0)" }
                session.note("影片：這個網址播不了（只收 http/https），回報手機")
                sendVideo(CarVideoProtocol.errorNotification(code: CarVideoProtocol.errorIncompatible, itemUUID: uuid), streamID: sid)
                return
            }
            videoItem = item.uuid; videoPlayer = nil
            session.note("影片：insertPlayQueueItem（\(URL(string: item.url)?.host ?? "?")，從 \(item.startMs) ms）")
            session.onVideo?("play", ["url": item.url, "startMs": item.startMs, "uuid": item.uuid])
        case "setRate":
            videoStreamID = sid
            let r = (m["rate"] as? NSNumber)?.doubleValue ?? 0
            session.onVideo?("rate", ["rate": r])
        case "seek":
            let ms = (m["time"] as? [String: Any]).flatMap(CarVideoProtocol.seconds).map { Int($0 * 1000) } ?? 0
            session.onVideo?("seek", ["ms": ms])
            sendVideo(CarVideoProtocol.seekResponse(messageID: mid), streamID: sid)
        case "playbackInfo":
            sendVideo(CarVideoProtocol.playbackInfoResponse(messageID: mid, itemUUID: videoItem, state: videoPlayer), streamID: sid)
        case "property":
            sendVideo(CarVideoProtocol.propertyResponse(messageID: mid, key: m["property"] as? String, state: videoPlayer), streamID: sid)
        case "stop", "removePlayQueueItem":
            session.note("影片：\(type)")
            session.onVideo?("stop", [:])
            videoItem = nil; videoPlayer = nil
        default:
            session.note("影片訊息 \(type)（streamID \(sid)）略過")
        }
    }

    private func teardown(_ req: RTSPMessage) -> RTSPResponse {
        // 整体 TEARDOWN：原因可能在 body（Apple 惯例 plist）也可能在头里，都打出来
        if let dict = try? BPlist.decodeDict(req.body), !dict.isEmpty {
            session.note("TEARDOWN body：\(dict.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        } else if !req.body.isEmpty {
            session.note("TEARDOWN body[\(req.body.count)B]：\(req.body.map { String(format: "%02x", $0) }.joined())")
        }
        if !req.headers.isEmpty {
            session.note("TEARDOWN 头：\(req.headers.map { "\($0.0): \($0.1)" }.joined(separator: " | "))")
        }
        let entries = ((try? BPlist.decodeDict(req.body))?["streams"] as? [[String: Any]]) ?? []
        let types = entries.compactMap { ($0["type"] as? NSNumber)?.intValue }
        if types.isEmpty {
            session.note("TEARDOWN（整个会话）")
            endAfterReply = true
            return RTSPResponse(status: 200)
        }
        session.note("TEARDOWN 流 \(types)")
        for t in types {
            if t == CarPlayStream.mainScreen { screen?.stop(); screen = nil; adapter = nil }
            if t == CarPlayStream.data {
                // 130 有好幾條：streamID 缺省或 1＝iAP 隧道；2＝影片設定資料流；3 起＝影片遙控會話（拆它不能關 iAP）
                for e in entries where (e["type"] as? NSNumber)?.intValue == t {
                    let id = (e["streamID"] as? NSNumber)?.intValue ?? 1
                    if id == 1 { closeIapTunnel() }
                    else if id == 2 { videoSettings?.stop(); videoSettings = nil }
                    else {
                        videoRemoteStreams.remove(id)
                        if videoStreamID == id { session.onVideo?("stop", [:]); videoStreamID = nil; videoItem = nil }
                    }
                }
            }
            audio.removeAll { a in
                guard a.type == t else { return false }
                a.close(); return true
            }
        }
        return RTSPResponse(status: 200)
    }
}

extension CarPlaySession {
    fileprivate func isLive(_ cc: ControlConnection) -> Bool { live === cc }

    /// duckAudio／unduckAudio：手機在導航提示、Siri、來電鈴聲前後要車機自己壓低媒體（102）。
    /// 參數照實際收到的取（durationMs、volume 0–1 或 dB）；沒給就用 CarPlay 常見的 0.2 倍、0.5 s。
    fileprivate func applyDucking(_ type: String, _ p: [String: Any]) {
        guard type == "duckAudio" || type == "unduckAudio" else { return }
        let ms = (p["durationMs"] as? NSNumber)?.doubleValue ?? (p["duration"] as? NSNumber).map { $0.doubleValue * 1000 } ?? 500
        var target: Float = 1
        if type == "duckAudio" {
            if let v = (p["volume"] as? NSNumber)?.floatValue {
                target = v <= 0 && v >= -96 && v != 0 ? powf(10, v / 20) : max(0, min(1, v))   // 負數當 dB
            } else { target = 0.2 }
        }
        for a in live?.audio ?? [] where a.type == CarPlayStream.mainHighAudio { a.duck(target, over: max(0.05, min(2, ms / 1000))) }
    }

    /// `POST /command` 正文（bplist {type, params}）→ 日志 + onCommand。控制口与事件通道共用。
    fileprivate func dispatchCommand(_ body: Data, via: String) {
        guard let d = try? BPlist.decodeDict(body), let t = d["type"] as? String else { return }
        let params = (d["params"] as? [String: Any]) ?? [:]
        log("command \(t)（\(via)，ack）\(params.isEmpty ? "" : " \(params)")")
        applyDucking(t, params)
        onCommand?(t, params)
    }
}

/// 桌寵 → 接收器的 Siri 鍵動作
package enum SiriAction: String, Equatable, CustomStringConvertible {
    case click, down, up
    package var description: String { rawValue }
    /// `{"type":"siri"}` 沒帶 action 的是舊版桌寵：按一下
    package static func parse(_ text: String) -> SiriAction {
        if text.contains("\"action\":\"down\"") { return .down }
        if text.contains("\"action\":\"up\"") { return .up }
        return .click
    }
}

/// 車機 Siri 鍵的狀態機：requestSiri 的 siriAction 2＝按下、3＝放開。
/// 會話還沒 live 時先記著，RECORD 後補發（F5 可以先按、桌寵再連）：
/// 放開前就 live 了補「按下」、之後的放開照常送；live 前就放開了補一次「按一下」。
package struct SiriKeyState: Equatable {
    package static let buttonDown = 2
    package static let buttonUp = 3

    private var pending: SiriAction?
    private var held = false

    package init() {}

    /// 回傳現在要送的 siriAction（live 才會有）
    package mutating func press(_ action: SiriAction, live: Bool) -> [Int] {
        guard live else {
            switch action {
            case .click: pending = .click
            case .down: pending = .down
            case .up: if pending == .down { pending = .click }
            }
            return []
        }
        switch action {
        case .click:
            held = false
            return [Self.buttonDown, Self.buttonUp]
        case .down:
            held = true
            return [Self.buttonDown]
        case .up:
            guard held else { return [] }
            held = false
            return [Self.buttonUp]
        }
    }

    package mutating func becameLive() -> [Int] {
        defer { pending = nil }
        switch pending {
        case .click: held = false; return [Self.buttonDown, Self.buttonUp]
        case .down: held = true; return [Self.buttonDown]
        default: return []
        }
    }
}
