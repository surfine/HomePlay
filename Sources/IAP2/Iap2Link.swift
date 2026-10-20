import Foundation

// iAP2 链路层（sans-io：字节进、字节与事件出，时间由 tick 注入）。
// 照 MacPlay iap2-link 的 LinkEngine 逐行为对齐——这三件事是手机肯往下走的关键：
//   1) 收到对端 SYNC 立即回 ACK；2) 只有「自己的 SYNC 被 ACK」才进 running；
//   3) marker 每 1s、SYNC 每 500ms 重发直到握手完成。
// 对端 LSP 整体采纳（窗口/重传/确认策略全按手机说的来）；本端声明 zero-ack（全零定时器、出窗 4、控制会话 v2）。
// 线格式：FF 5A | u16 总长 | u8 控制 | u8 序号 | u8 确认 | u8 会话 | u8 头校验 | 载荷 | u8 载荷校验；marker FF 55 02 00 EE 10。

package struct Iap2Link {
    // MARK: 常量

    package static let marker: [UInt8] = [0xff, 0x55, 0x02, 0x00, 0xee, 0x10]
    package static let controlSessionId: UInt8 = 10
    package static let eaSessionId: UInt8 = 11
    package static let fileTransferSessionId: UInt8 = 12
    package static let headerBytes = 9
    package static let checksumBytes = 1
    package static let maxFrameBytes = 0xffff
    package static let controlSynchronize: UInt8 = 0x80
    package static let controlData: UInt8 = 0x40   // 数据与纯确认共用这一位（ACK）
    package static let controlEak: UInt8 = 0x20
    package static let controlReset: UInt8 = 0x10
    package static let initialSequence: UInt8 = 99
    static let detectResendMs: UInt64 = 1000
    static let negotiateResendMs: UInt64 = 500

    /// 同步载荷：版本 1、出窗、最大帧长、重传/确认超时、最大重传、最大累计确认、会话三元组。
    package struct Synchronization {
        package var maxOutgoing: UInt8
        package var maxFrameBytes: UInt16
        package var retransmissionTimeout: UInt16   // ms
        package var ackTimeout: UInt16               // ms
        package var maxRetransmissions: UInt8
        package var maxCumulativeAck: UInt8
        package var sessions: [(id: UInt8, kind: UInt8, version: UInt8)]

        package init(maxOutgoing: UInt8, maxFrameBytes: UInt16,
                     retransmissionTimeout: UInt16 = 4000, ackTimeout: UInt16 = 500,
                     maxRetransmissions: UInt8 = 4, maxCumulativeAck: UInt8 = 3,
                     sessions: [(id: UInt8, kind: UInt8, version: UInt8)]) {
            self.maxOutgoing = maxOutgoing; self.maxFrameBytes = maxFrameBytes
            self.retransmissionTimeout = retransmissionTimeout; self.ackTimeout = ackTimeout
            self.maxRetransmissions = maxRetransmissions; self.maxCumulativeAck = maxCumulativeAck
            self.sessions = sessions
        }

        package var encoded: [UInt8] {
            var out: [UInt8] = [1, maxOutgoing]
            out += Iap2Csm.be16(maxFrameBytes)
            out += Iap2Csm.be16(retransmissionTimeout)
            out += Iap2Csm.be16(ackTimeout)
            out += [maxRetransmissions, maxCumulativeAck]
            for session in sessions { out += [session.id, session.kind, session.version] }
            return out
        }

        package static func decode(_ bytes: [UInt8]) -> Synchronization? {
            guard bytes.count >= 10, bytes[0] == 1 else { return nil }
            func u16(_ offset: Int) -> UInt16 {
                UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            }
            var sessions: [(UInt8, UInt8, UInt8)] = []
            var offset = 10
            while offset + 3 <= bytes.count {
                sessions.append((bytes[offset], bytes[offset + 1], bytes[offset + 2]))
                offset += 3
            }
            return Synchronization(maxOutgoing: bytes[1], maxFrameBytes: u16(2),
                                   retransmissionTimeout: u16(4), ackTimeout: u16(6),
                                   maxRetransmissions: bytes[8], maxCumulativeAck: bytes[9],
                                   sessions: sessions)
        }

        /// 本端声明（照 MacPlay 接线：出窗 4、zero-ack 全零定时器、控制会话 v2）。
        package static func local() -> Synchronization {
            Synchronization(maxOutgoing: 4, maxFrameBytes: UInt16(Iap2Link.maxFrameBytes),
                            retransmissionTimeout: 0, ackTimeout: 0, maxRetransmissions: 0, maxCumulativeAck: 0,
                            sessions: [
                                (controlSessionId, 0, 2),
                                (eaSessionId, 2, 1),
                                (fileTransferSessionId, 1, 2),
                            ])
        }
    }

    package enum Event: Equatable {
        /// 控制会话（session 10）的一整个载荷。
        case control([UInt8])
        /// 文件传输会话（session 12）的一个 datagram（封面等）。
        case fileTransfer([UInt8])
        /// 链路协商完成（我们的 SYNC 被手机 ACK 了），可以发 CSM。
        case ready
        case dead(String)
    }

    package enum State: Equatable { case detecting, negotiating, running, dead }

    // MARK: 状态

    package private(set) var state: State = .detecting
    /// 链路参数：先是本端声明，收到对端 SYNC 后整体换成对方的。
    private var lsp: Synchronization = .local()
    private let clock: () -> UInt64
    private var outgoing: [UInt8] = []
    private var events: [Event] = []
    private var received = [UInt8]()

    private var sentSequence: UInt8 = initialSequence
    private var lastSentAcknowledged: UInt8?
    private var unacked: [(psn: UInt8, session: UInt8, data: [UInt8], counter: Int, timeout: UInt64)] = []
    private var queued: [(session: UInt8, data: [UInt8])] = []
    private var lastReceivedInOrder: UInt8 = 0
    private var lastAcked: UInt8?
    private var outOfSequence: [(psn: UInt8, session: UInt8, data: [UInt8])] = []
    private var cumulativeAckCounter: UInt32 = 0

    private var detectDeadline: UInt64?
    private var negotiateDeadline: UInt64?
    private var sendAckDeadline: UInt64?
    private var recvAckDeadline: UInt64?

    package var peerSynchronization: Synchronization? { adoptedPeer ? lsp : nil }
    private var adoptedPeer = false

    package init(clock: (() -> UInt64)? = nil) {
        self.clock = clock ?? { UInt64(Date().timeIntervalSince1970 * 1000) }
    }

    // MARK: 生命周期

    /// 开跑：发 marker 并主动发起协商（不等对端 marker 就发 SYNC——照 MacPlay initiate=true）。
    package mutating func start() {
        guard state == .detecting else { return }
        let now = clock()
        outgoing += Self.marker
        detectDeadline = now + Self.detectResendMs
        enterNegotiate(now: now)
    }

    package mutating func takeOutput() -> [UInt8] {
        defer { outgoing.removeAll() }
        return outgoing
    }

    package mutating func pollEvent() -> Event? {
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }

    /// 时间前进：重发 marker/SYNC、延迟确认、数据重传都靠它（传输层定期调）。
    package mutating func tick() {
        let now = clock()
        if let d = detectDeadline, d <= now {
            detectDeadline = nil
            if state == .detecting {
                outgoing += Self.marker
                detectDeadline = now + Self.detectResendMs
            }
        }
        if let d = negotiateDeadline, d <= now {
            negotiateDeadline = nil
            if state == .negotiating {
                appendSyncPacket()
                negotiateDeadline = now + Self.negotiateResendMs
            }
        }
        if let d = sendAckDeadline, d <= now {
            sendAckDeadline = nil
            if state == .running {
                lastAcked = lastReceivedInOrder
                appendAckPacket()
            }
        }
        if let d = recvAckDeadline, d <= now {
            recvAckDeadline = nil
            expectAckTimer(now: now)
        }
    }

    /// 收到传输字节（任意分块）。解析出整包，逐包处理。
    package mutating func feed(_ chunk: [UInt8]) {
        guard state != .dead else { return }
        received += chunk
        guard received.count <= Self.maxFrameBytes * 2 else {
            dead("接收缓冲超限")
            return
        }
        while let packet = nextPacket() {
            process(packet)
            guard state != .dead else { return }
        }
    }

    package mutating func feedEof() { dead("传输结束") }

    /// 发一个控制会话载荷：按对方窗口排队、递增序号、按对方参数跟踪重传。
    package mutating func sendControl(_ payload: [UInt8]) {
        let limit = payloadLimit
        var offset = 0
        repeat {
            let end = min(offset + limit, payload.count)
            sendPacket(session: Self.controlSessionId, data: Array(payload[offset..<end]))
            offset = end
        } while offset < payload.count
    }

    // MARK: 内部

    private var payloadLimit: Int {
        let peerMax = Int(lsp.maxFrameBytes)
        return max(1, min(peerMax, Self.maxFrameBytes) - Self.headerBytes - Self.checksumBytes)
    }

    private mutating func enterNegotiate(now: UInt64) {
        state = .negotiating
        detectDeadline = nil
        appendSyncPacket()
        negotiateDeadline = now + Self.negotiateResendMs
    }

    private mutating func dead(_ reason: String) {
        guard state != .dead else { return }
        state = .dead
        detectDeadline = nil; negotiateDeadline = nil; sendAckDeadline = nil; recvAckDeadline = nil
        events.append(.dead(reason))
    }

    private mutating func process(_ packet: Packet) {
        if packet.control & Self.controlReset != 0 { dead("手机发了 reset"); return }
        if packet.control & Self.controlSynchronize != 0, let sync = Synchronization.decode(packet.payload) {
            handleSyn(sync, psn: packet.sequence)
        }
        if packet.control & Self.controlData != 0 {
            cumulativeAckCounter &+= 1
            handleAck(packet.acknowledgement)
        }
        if packet.control & Self.controlEak != 0, !packet.payload.isEmpty {
            handleEak(packet.payload)
        }
        if packet.control & ~Self.controlData == 0, !packet.payload.isEmpty {
            handleData(psn: packet.sequence, session: packet.session, data: packet.payload)
        }
        if lsp.maxCumulativeAck > 0, cumulativeAckCounter >= lsp.maxCumulativeAck {
            cumulativeAckCounter = 0
            lastAcked = lastReceivedInOrder
            appendAckPacket()
        }
    }

    /// 对端 SYNC：只在协商态认——整体采纳对方参数，立刻回 ACK（缺了这步手机永远进不了控制会话）。
    private mutating func handleSyn(_ sync: Synchronization, psn: UInt8) {
        guard state == .negotiating else { return }
        lsp = sync
        adoptedPeer = true
        lastReceivedInOrder = psn
        lastAcked = psn
        appendAckPacket()
    }

    private mutating func handleAck(_ num: UInt8) {
        if state == .negotiating {
            state = .running
            negotiateDeadline = nil
            events.append(.ready)
        }
        lastSentAcknowledged = num
        // 清掉已被累计确认的包，剩下的重挂超时
        var rearmed = false
        while let first = unacked.first {
            let d = Self.distance(first.psn, lastSentAcknowledged)
            if d > 0, d <= UInt16(lsp.maxCumulativeAck) + 10 {
                recvAckDeadline = first.timeout
                rearmed = true
                break
            }
            unacked.removeFirst()
        }
        if !rearmed { recvAckDeadline = nil }
        // 窗口空出来了，把排队的发掉
        while Self.distance(sentSequence, lastSentAcknowledged) < UInt16(lsp.maxOutgoing),
              let next = queued.first {
            queued.removeFirst()
            sendPacket(session: next.session, data: next.data)
        }
    }

    private mutating func handleEak(_ missing: [UInt8]) {
        guard state == .running else { return }
        for index in unacked.indices where missing.contains(unacked[index].psn) {
            unacked[index].counter += 1
            if unacked[index].counter == Int(lsp.maxRetransmissions) {
                dead("包 psn=\(unacked[index].psn) 未被确认")
                return
            }
            let p = unacked[index]
            appendDataPacket(psn: p.psn, session: p.session, data: p.data)
            sendAckDeadline = nil
            recvAckDeadline = p.timeout
        }
    }

    private mutating func handleData(psn: UInt8, session: UInt8, data: [UInt8]) {
        let now = clock()
        let d = Self.distance(psn, lastReceivedInOrder)
        if d > UInt16(lsp.maxOutgoing) + 10 || d == 0 {
            appendAckPacket()   // 太旧（重复）或太远：回个当前确认让它收敛
            return
        }
        if d > 1 {
            outOfSequence.append((psn, session, data))
            if d >= UInt16(lsp.maxOutgoing) {
                // 缺口到出窗了：列缺失序号要 EAK
                var missing: [UInt8] = []
                var x = lastReceivedInOrder
                while Self.distance(psn, x) > 1 {
                    x &+= 1
                    missing.append(x)
                }
                sendAckDeadline = nil
                outgoing += Self.encode(payload: missing, sequence: sentSequence,
                                        control: Self.controlEak, session: 0, acknowledgement: lastReceivedInOrder)
            }
            return
        }
        // 按序到达：连同缓存里接得上的按序交付
        outOfSequence.append((psn, session, data))
        outOfSequence.sort { Self.distance($0.psn, lastReceivedInOrder) < Self.distance($1.psn, lastReceivedInOrder) }
        while let first = outOfSequence.first, Self.distance(first.psn, lastReceivedInOrder) <= 1 {
            let p = outOfSequence.removeFirst()
            lastReceivedInOrder = p.psn
            deliver(p)
        }
        guard lsp.maxCumulativeAck > 0 else { return }
        if Self.distance(lastReceivedInOrder, lastAcked) >= UInt16(lsp.maxOutgoing) {
            sendAckDeadline = nil
            lastAcked = lastReceivedInOrder
            appendAckPacket()
        } else {
            sendAckDeadline = now + UInt64(lsp.ackTimeout)
        }
    }

    private mutating func deliver(_ p: (psn: UInt8, session: UInt8, data: [UInt8])) {
        switch p.session {
        case Self.controlSessionId:
            if !p.data.isEmpty { events.append(.control(p.data)) }
        case Self.fileTransferSessionId:
            if !p.data.isEmpty { events.append(.fileTransfer(p.data)) }
        default: break   // EA 会话暂不处理
        }
    }

    /// 文件传输会话（封面等）回包。
    package mutating func sendFileTransfer(_ data: [UInt8]) { sendPacket(session: Self.fileTransferSessionId, data: data) }

    private mutating func sendPacket(session: UInt8, data: [UInt8]) {
        if Self.distance(sentSequence, lastSentAcknowledged) > UInt16(lsp.maxOutgoing) || state != .running {
            queued.append((session, data))
            return
        }
        let now = clock()
        sentSequence &+= 1
        let psn = sentSequence
        let timeout = now + UInt64(lsp.retransmissionTimeout)
        appendDataPacket(psn: psn, session: session, data: data)
        lastAcked = lastReceivedInOrder
        if lsp.maxRetransmissions > 0 {
            recvAckDeadline = timeout
            unacked.append((psn, session, data, 0, timeout))
        } else {
            lastSentAcknowledged = sentSequence   // zero-ack：发了就算确认
        }
    }

    private mutating func expectAckTimer(now: UInt64) {
        guard !unacked.isEmpty, state == .running else { return }
        let sorted = unacked.indices.sorted { unacked[$0].timeout < unacked[$1].timeout }
        let first = sorted[0]
        let secondTimeout = sorted.count > 1 ? unacked[sorted[1]].timeout : nil
        unacked[first].timeout = now + UInt64(lsp.retransmissionTimeout)
        unacked[first].counter += 1
        let packet = unacked[first]
        if packet.counter >= Int(lsp.maxRetransmissions) {
            dead("包 psn=\(packet.psn) 未被确认")
            return
        }
        appendDataPacket(psn: packet.psn, session: packet.session, data: packet.data)
        recvAckDeadline = secondTimeout ?? packet.timeout
    }

    private mutating func appendSyncPacket() {
        outgoing += Self.encode(payload: lsp.encoded, sequence: sentSequence,
                                control: Self.controlSynchronize, session: 0, acknowledgement: lastReceivedInOrder)
    }

    private mutating func appendDataPacket(psn: UInt8, session: UInt8, data: [UInt8]) {
        outgoing += Self.encode(payload: data, sequence: psn,
                                control: Self.controlData, session: session, acknowledgement: lastReceivedInOrder)
    }

    private mutating func appendAckPacket() {
        outgoing += Self.encode(payload: nil, sequence: sentSequence,
                                control: Self.controlData, session: 0, acknowledgement: lastReceivedInOrder)
    }

    /// 环形序号距离：a 在 b 前方多少（None 视作 0，即「没确认过」时返回 a 本身）。
    static func distance(_ a: UInt8, _ b: UInt8?) -> UInt16 {
        guard let b else { return UInt16(a) }
        return UInt16(a &- b)
    }

    private struct Packet {
        var control: UInt8
        var sequence: UInt8
        var acknowledgement: UInt8
        var session: UInt8
        var payload: [UInt8]
        var isMarker: Bool
    }

    /// 从缓冲解出一个完整链路包（或 marker）；垃圾与坏校验的字节跳过后继续找。
    private mutating func nextPacket() -> Packet? {
        while !received.isEmpty {
            if received.starts(with: Self.marker) {
                received.removeFirst(Self.marker.count)
                return Packet(control: 0, sequence: 0, acknowledgement: 0, session: 0, payload: [], isMarker: true)
            }
            guard received.count >= 2, received[0] == 0xff, received[1] == 0x5a else {
                received.removeFirst()
                continue
            }
            guard received.count >= Self.headerBytes else { return nil }
            let length = Int(Iap2Csm.be16At(received, 2))
            guard length >= Self.headerBytes, length <= Self.maxFrameBytes else {
                received.removeFirst()
                continue
            }
            guard received.count >= length else { return nil }
            let whole = Array(received[0..<length])
            guard Self.checksumValid(whole) else {
                received.removeFirst()
                continue
            }
            received.removeFirst(length)
            let payload = length > Self.headerBytes + Self.checksumBytes
                ? Array(whole[Self.headerBytes..<(length - Self.checksumBytes)])
                : []
            return Packet(control: whole[4], sequence: whole[5], acknowledgement: whole[6],
                          session: whole[7], payload: payload, isMarker: false)
        }
        return nil
    }

    // MARK: 编码

    package static func encode(payload: [UInt8]?, sequence: UInt8, control: UInt8, session: UInt8, acknowledgement: UInt8) -> [UInt8] {
        // 空载荷只有 9 字节头，没有载荷校验位。
        let total = payload == nil ? Self.headerBytes : Self.headerBytes + payload!.count + Self.checksumBytes
        var out: [UInt8] = [0xff, 0x5a]
        out += Iap2Csm.be16(UInt16(total))
        out += [control, sequence, acknowledgement, session]
        var sum: UInt8 = 0
        for byte in out { sum &+= byte }
        out.append(0 &- sum) // 头校验：头 8 字节之和的补
        if let payload {
            out += payload
            var payloadSum: UInt8 = 0
            for byte in payload { payloadSum &+= byte }
            out.append(0 &- payloadSum)
        }
        return out
    }

    /// 全包按字节求和为 0（头校验 + 载荷校验的设计正好满足）。
    package static func checksumValid(_ whole: [UInt8]) -> Bool {
        var sum: UInt8 = 0
        for byte in whole { sum &+= byte }
        return sum == 0
    }
}
