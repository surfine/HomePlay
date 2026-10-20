// 时钟同步口（UDP，RTCP 风格 NTP）与 keep-alive 口（对应 MacPlay timingServer.ts / keepAliveServer.ts / ntp.ts）。
// SETUP 必须回一个 timingPort，而且我们得主动向手机的 timingPort 发请求，否则手机几秒后拆会话。
import Foundation

/// 双栈 UDP 套接字（POSIX，因为要用同一个端口既收又向对端发）
final class UDPSocket {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue
    private let bufferBytes: Int
    private(set) var port: UInt16 = 0
    var onDatagram: ((Data, String, UInt16) -> Void)?

    init(queue: DispatchQueue, bufferBytes: Int = 2048) throws {
        self.queue = queue
        self.bufferBytes = bufferBytes
        fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_any
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        guard rc == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin6_port)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        let owned = fd
        src.setCancelHandler { Darwin.close(owned) }   // 读源确定停了才关 fd，免得 fd 号被复用后读错
        src.resume()
        source = src
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: bufferBytes)
        while true {
            var from = sockaddr_in6(); var flen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &flen) } }
            if n < 0 { return }
            var a = from.sin6_addr
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &a, &text, socklen_t(text.count))
            onDatagram?(Data(buf[0..<n]), String(cString: text), UInt16(bigEndian: from.sin6_port))
        }
    }

    func send(_ data: Data, toHost host: String, port: UInt16) {
        var hints = addrinfo(); hints.ai_family = AF_INET6; hints.ai_socktype = SOCK_DGRAM; hints.ai_flags = AI_V4MAPPED
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let r = res else { return }
        defer { freeaddrinfo(res) }
        data.withUnsafeBytes { _ = sendto(fd, $0.baseAddress, data.count, 0, r.pointee.ai_addr, r.pointee.ai_addrlen) }
    }

    func close() {
        if let s = source { source = nil; fd = -1; s.cancel() }
    }
    deinit { close() }
}

/// 比较两个地址串是否同一主机（去掉 ::ffff: 前缀和 %scope）
func sameHost(_ a: String, _ b: String) -> Bool {
    func norm(_ s: String) -> String {
        var t = s.split(separator: "%").first.map(String.init) ?? s
        if t.lowercased().hasPrefix("::ffff:") { t = String(t.dropFirst(7)) }
        return t.lowercased()
    }
    return norm(a) == norm(b)
}

package enum NTP {
    static let epochOffset = 2208988800.0
    /// 64 位 NTP 时间戳：高 32 位秒，低 32 位小数
    package static func ntp64(fromUnix t: Double) -> UInt64 {
        let u = t + epochOffset
        let sec = UInt64(u.rounded(.down))
        let frac = UInt64((u - Double(sec)) * 4294967296.0) & 0xffffffff
        return sec << 32 | frac
    }
    package static func ntp64Now() -> UInt64 { ntp64(fromUnix: Date().timeIntervalSince1970) }
    static func ntp(fromNs ns: UInt64) -> UInt64 {
        let sec = ns / 1_000_000_000
        let frac = ((ns % 1_000_000_000) << 32) / 1_000_000_000
        return sec << 32 | frac
    }
    static func write(_ v: UInt64, into d: inout [UInt8], at o: Int) { for i in 0..<8 { d[o + i] = UInt8(v >> (56 - 8 * UInt64(i)) & 0xff) } }
    static func read(_ d: [UInt8], at o: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(d[o + $1]) } }
}

/// 我们是接收端，驱动同步：每秒向手机 timingPort 发 type 210，收 211，用最小 RTT 样本把本地时钟推到手机的时钟域；
/// 手机向我们发 210 时，回 211（T2/T3 用同一个已校准的时钟）。
package final class TimingServer {
    private let queue = DispatchQueue(label: "session.timing")
    private var sock: UDPSocket?
    private var timer: DispatchSourceTimer?
    private var peerHost = "", peerPort: UInt16 = 0
    private var clockOffsetNs: Int64
    private var delays = [Double](repeating: .infinity, count: 8), delayIndex = 0
    private var pickCount = 2, pickRtt = Double.infinity, pickOffset = 0.0
    private var pendingT1: UInt64?
    private(set) var synced = false
    package private(set) var requestsSent = 0
    package private(set) var responsesSent = 0
    package private(set) var repliesReceived = 0
    package var onStats: ((String) -> Void)?

    package init() {
        let mono = Int64(DispatchTime.now().uptimeNanoseconds)
        let ntp = NTP.ntp64Now()
        let ns = Int64(ntp >> 32) * 1_000_000_000 + Int64(((ntp & 0xffffffff) * 1_000_000_000) >> 32)
        clockOffsetNs = ns - mono
    }

    /// 绑定并返回端口
    package func listen() throws -> UInt16 {
        let s = try UDPSocket(queue: queue)
        s.onDatagram = { [weak self] d, h, p in self?.onDatagram(d, h, p) }
        sock = s
        return s.port
    }

    /// 开始向手机的 timingPort 发请求
    package func start(peerHost: String, peerPort: UInt16) {
        queue.async { [self] in
            self.peerHost = peerHost; self.peerPort = peerPort
            sendRequest()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.sendRequest() }
            t.resume(); timer = t
            // 3s 一报：心跳是否真的在流动（手机时钟不同步就会拆会话）
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.onStats?("计时心跳（3s）：已发 \(self.requestsSent)、收到应答 \(self.repliesReceived)、手机来探 \(self.responsesSent)、已同步 \(self.synced)")
            }
        }
    }

    package func stop() {
        queue.sync { timer?.cancel(); timer = nil; sock?.close(); sock = nil }
    }

    /// 已校准时钟，64 位 NTP 值（/feedback 要用）
    package func syncedNTP() -> UInt64 {
        NTP.ntp(fromNs: UInt64(Int64(DispatchTime.now().uptimeNanoseconds) + clockOffsetNs))
    }

    private func sendRequest() {
        guard let sock, peerPort != 0 else { return }
        var pkt = [UInt8](repeating: 0, count: 32)
        pkt[0] = 0x80; pkt[1] = 210; pkt[2] = 0; pkt[3] = 7
        let t1 = syncedNTP(); pendingT1 = t1
        NTP.write(t1, into: &pkt, at: 24)
        sock.send(Data(pkt), toHost: peerHost, port: peerPort)
        requestsSent += 1
    }

    private func onDatagram(_ data: Data, _ host: String, _ port: UInt16) {
        let msg = [UInt8](data)
        guard msg.count >= 32, peerHost.isEmpty || sameHost(host, peerHost) else { return }
        if msg[1] == 210 {
            var resp = [UInt8](repeating: 0, count: 32)
            resp[0] = 0x80; resp[1] = 211; resp[3] = 7
            for i in 0..<8 { resp[8 + i] = msg[24 + i] }
            NTP.write(syncedNTP(), into: &resp, at: 16)
            NTP.write(syncedNTP(), into: &resp, at: 24)
            sock?.send(Data(resp), toHost: host, port: port)
            responsesSent += 1
            return
        }
        guard msg[1] == 211 else { return }
        repliesReceived += 1
        let t4 = syncedNTP()
        let t1 = NTP.read(msg, at: 8), t2 = NTP.read(msg, at: 16), t3 = NTP.read(msg, at: 24)
        guard let p = pendingT1, p == t1 else { return }
        pendingT1 = nil
        func d(_ a: UInt64, _ b: UInt64) -> Double { Double(Int64(bitPattern: a &- b)) }
        let offset = 0.5 * (d(t2, t1) + d(t3, t4)) / 4294967296.0
        let rtt = (d(t4, t1) - d(t3, t2)) / 4294967296.0
        if rtt < 0 { return }
        if rtt < pickRtt { pickRtt = rtt; pickOffset = offset }
        pickCount -= 1
        if pickCount > 0 { return }
        let r = pickRtt, o = pickOffset
        pickCount = 2; pickRtt = .infinity
        let use = delays.allSatisfy { r <= $0 }
        delays[delayIndex] = r; delayIndex = (delayIndex + 1) % delays.count
        if !use { return }
        let stepping = !synced || abs(o) > 0.128
        clockOffsetNs += Int64((stepping ? o : o / 8) * 1e9)
        if stepping { delays = [Double](repeating: .infinity, count: 8); delayIndex = 0; pendingT1 = nil; synced = true }
    }
}

/// keep-alive：只需要一个能收包的 UDP 口；记最近一次来自对端的活动。
package final class KeepAliveServer {
    private let queue = DispatchQueue(label: "session.keepalive")
    private var sock: UDPSocket?
    private let peerHost: String
    package private(set) var lastActivity: Date?
    package init(peerHost: String = "") { self.peerHost = peerHost }

    package func listen() throws -> UInt16 {
        let s = try UDPSocket(queue: queue)
        s.onDatagram = { [weak self] d, h, _ in
            guard let self, !d.isEmpty, sameHost(h, self.peerHost) else { return }
            self.lastActivity = Date()
        }
        sock = s
        return s.port
    }
    package func stop() { queue.sync { sock?.close(); sock = nil } }
}
