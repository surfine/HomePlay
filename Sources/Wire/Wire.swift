// wire 编码与 WebSocket 服务器（和 WindowShade WS2CarPlayReceiverWire 对齐）。
import Foundation
import Network
import CoreMedia

// MARK: - wire 编码（和 WS2CarPlayReceiverWire 对齐，全部小端）

package enum Wire {
    // [1][streamType][codec=1][width u32][height u32][avcC...]，记录从偏移 11 起。
    /// codec: 1 = H.264（avcC）、2 = HEVC（自家參數集包：count u8 + 每個 len u16 + NAL）
    package static func videoConfig(width: Int, height: Int, avcC: Data, streamType: UInt8 = 0, codec: UInt8 = 1) -> Data {
        var d = Data([1, streamType, codec])
        d.append(u32(width)); d.append(u32(height)); d.append(avcC)
        return d
    }
    // [2][streamType][flags bit0=keyframe][pts u64][Annex B NAL 序列]
    package static func videoFrame(annexB: Data, keyframe: Bool, ptsMicros: UInt64, streamType: UInt8 = 0) -> Data {
        var d = Data([2, streamType, keyframe ? 1 : 0])
        d.append(u64(ptsMicros)); d.append(annexB)
        return d
    }
    package static func helloJSON(name: String, width: Int, height: Int) -> String {
        #"{"type":"hello","message":"\#(name)","sessionActive":true,"width":\#(width),"height":\#(height)}"#
    }
    package static func u32(_ v: Int) -> Data {
        let x = UInt32(truncatingIfNeeded: v)
        return Data([UInt8(x & 0xff), UInt8((x >> 8) & 0xff), UInt8((x >> 16) & 0xff), UInt8((x >> 24) & 0xff)])
    }
    package static func u64(_ v: UInt64) -> Data {
        var d = Data(); for i in 0..<8 { d.append(UInt8((v >> (8 * i)) & 0xff)) }; return d
    }
}

// AVCC（4 字节大端长度前缀）→ Annex B（00 00 00 01 起始码）。
package func avccToAnnexB(_ avcc: Data) -> Data {
    var out = Data()
    // 每个 NAL 多 4 字节起始码；先按上限预留，避免逐段 append 反复扩容。
    out.reserveCapacity(avcc.count + 16)
    var i = 0
    let bytes = [UInt8](avcc)
    while i + 4 <= bytes.count {
        let len = Int(bytes[i]) << 24 | Int(bytes[i+1]) << 16 | Int(bytes[i+2]) << 8 | Int(bytes[i+3])
        i += 4
        guard len > 0, i + len <= bytes.count else { break }
        out.append(contentsOf: [0, 0, 0, 1])
        out.append(contentsOf: bytes[i..<(i+len)])
        i += len
    }
    return out
}

// 从 CMFormatDescription 取出 avcC 原子。
package func avcCRecord(from fmt: CMFormatDescription) -> Data? {
    guard let atoms = CMFormatDescriptionGetExtension(
        fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
        let avcC = atoms["avcC"] as? Data else { return nil }
    return avcC
}

// MARK: - WebSocket 服务器（Network.framework，无第三方依赖）

package final class WSServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ws.server")
    /// 只在 queue 上读写：listener / 连接的回调本来就在这条队列上跑。
    private var conns: [NWConnection] = []
    /// 每条连接还有多少帧没被底层收掉。只在 queue 上读写。
    private var inflight: [ObjectIdentifier: Int] = [:]
    /// 每条就绪连接的保活 ping 计时器（drop 时取消）。只在 queue 上读写。
    private var pingers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    /// 一条连接压在路上的帧数上限。接收端卡死时 NWConnection 会无限长发送缓冲，
    /// 到这里就认定这条路已经没救：断掉，让桌宠重连重新拿关键帧。
    private let maxInflight = 60
    /// 已就绪连接。broadcast 在别的线程上被调用、看不到 conns，所以单独用锁维护。
    private let countLock = NSLock()
    private var readyIDs: Set<ObjectIdentifier> = []   // 由 countLock 保护
    package var onConnect: ((NWConnection) -> Void)?
    package var onText: ((String) -> Void)?

    /// 目前就绪的客户端数量（桌宠是否还连着）。后台常驻用它判断「还有没有人在看」。
    package var clientCount: Int {
        countLock.lock(); defer { countLock.unlock() }
        return readyIDs.count
    }

    package init(port: UInt16) throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    package func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.conns.append(conn)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.countLock.lock()
                    self.readyIDs.insert(ObjectIdentifier(conn))
                    self.countLock.unlock()
                    self.onConnect?(conn)
                    self.receive(conn)
                    self.startPinger(conn)
                case .failed, .cancelled:
                    self.drop(conn)
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    /// 每 5 秒对就绪连接发一个 WS ping。对端已经走了的连接（FIN 后 NetworkFramework
    /// 有时不报错、只静默）会在发送或接收上暴露并被摘掉——不然 clientCount 会把
    /// 半开连接一直算成「还有人看」，后台常驻的空闲计时就永远不会开始。
    private func startPinger(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.readyIDs.contains(id) else { timer.cancel(); return }
            let md = NWProtocolWebSocket.Metadata(opcode: .ping)
            let ctx = NWConnection.ContentContext(identifier: "ping", metadata: [md])
            conn.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { error in
                if error != nil { self.drop(conn); conn.cancel() }
            })
        }
        timer.resume()
        pingers[id] = timer
    }

    private func drop(_ conn: NWConnection) {
        conns.removeAll { $0 === conn }
        pingers[ObjectIdentifier(conn)]?.cancel()
        pingers[ObjectIdentifier(conn)] = nil
        inflight[ObjectIdentifier(conn)] = nil
        countLock.lock()
        readyIDs.remove(ObjectIdentifier(conn))
        countLock.unlock()
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, ctx, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let md = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               md.opcode == .text, let s = String(data: data, encoding: .utf8) {
                self.onText?(s)
            }
            if let error {
                // 对端走了（桌宠退出／被杀）：把连接摘掉，clientCount 才不会一直算着它。
                // 否则后台常驻会以为「还有人看」，一直以车机身份广播。
                self.drop(conn)
                conn.cancel()
                return
            }
            // 干净关闭（FIN）有时不带 error、只给一次无数据的完成：同样当对端走了处理，
            // 否则这条连接永远留在 readyIDs 里，空闲计时根本不会开始（真机 2026-10-27 复现）。
            if data == nil, ctx == nil {
                self.drop(conn)
                conn.cancel()
                return
            }
            if conn.state == .ready { self.receive(conn) }
        }
    }

    package func sendText(_ s: String, to conn: NWConnection) {
        let md = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [md])
        conn.send(content: s.data(using: .utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    package func broadcastText(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        queue.async { [weak self] in self?.sendLocked(data, opcode: .text) }
    }

    package func broadcastBinary(_ data: Data) {
        queue.async { [weak self] in self?.sendLocked(data, opcode: .binary) }
    }

    package func sendBinary(_ data: Data, to conn: NWConnection) {
        let md = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "bin", metadata: [md])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// 必须在 queue 上调用。`inflight` 的加减也都在这条队列上，不需要额外加锁。
    private func sendLocked(_ payload: Data, opcode: NWProtocolWebSocket.Opcode) {
        guard !conns.isEmpty else { return }
        let md = NWProtocolWebSocket.Metadata(opcode: opcode)
        let ctx = NWConnection.ContentContext(identifier: opcode == .text ? "text" : "bin", metadata: [md])
        for conn in conns where conn.state == .ready {
            let id = ObjectIdentifier(conn)
            let pending = inflight[id] ?? 0
            if pending >= maxInflight {
                inflight[id] = nil
                conn.cancel()
                continue
            }
            inflight[id] = pending + 1
            conn.send(content: payload, contentContext: ctx, isComplete: true,
                      completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                let cur = self.inflight[id] ?? 0
                if cur <= 1 { self.inflight[id] = nil } else { self.inflight[id] = cur - 1 }
            })
        }
    }

    package var hasClients: Bool {
        countLock.lock(); defer { countLock.unlock() }
        return !readyIDs.isEmpty
    }
}

