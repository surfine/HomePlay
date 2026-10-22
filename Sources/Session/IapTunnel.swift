// iAP 数据通道（流 130，clientTypeUUID = iAP）：手机送 disableBluetooth 之后，iAP2 不再走蓝牙／USB，
// 改走会话里的这条 TCP 数据流（对应 MacPlay protocol/iapTunnel.ts）。两层叠在 socket 上：
//   1. NetSocketChaCha20-Poly1305 分帧：[2B 小端长度（仅密文）][密文][16B 标签]，AAD = 2 字节长度头，
//      nonce = 4 个零字节 + 8 字节小端计数（从 0 起，解密成功才 +1）——与 ControlCipher 的读方向同形；
//      密钥 = HKDF(配对共享密钥, "DataStream-Salt<seed>", "DataStream-Output-Encryption-Key")，同屏幕流。
//   2. 解密后的字节流是 APTransportPackage：32 字节大端头（size@0 … messageType@16）+ 正文；
//      messageType 'comm' 的正文就是原始 iAP2 链路字节（marker／SYNC／控制会话包）。
// 这条口只收不发：配件→手机方向走事件通道的 `iAPSendMessage` 命令（EventChannel.sendIapMessage）。
import Foundation
import Network

package enum IapTunnelError: Error, Equatable {
    case badKey
    case implausiblePackage(Int)
}

/// 解密出来的一个 APTransportPackage（头原样保留，正文是载荷）。
package struct APTransportPackage: Equatable {
    package static let headerLength = 32
    /// 'comm'：iAP 数据流的消息类型（MacPlay iapTunnel.ts 只转这一种）
    package static let messageTypeComm: UInt32 = 0x636f_6d6d
    package static let maxSize = 4 * 1024 * 1024

    package var header: Data
    package var body: Data

    package init(header: Data, body: Data) { self.header = header; self.body = body }

    package var size: UInt32 { Self.be32(header, 0) }
    package var messageType: UInt32 { Self.be32(header, 16) }
    package var isIap: Bool { messageType == Self.messageTypeComm }

    /// 组一个 'comm' 包（假 iPhone／测试用）：其余头字段留零。
    package static func comm(_ body: Data) -> Data {
        var h = Data(count: headerLength)
        let total = UInt32(headerLength + body.count)
        h[0] = UInt8(total >> 24 & 0xff); h[1] = UInt8(total >> 16 & 0xff); h[2] = UInt8(total >> 8 & 0xff); h[3] = UInt8(total & 0xff)
        h[16] = 0x63; h[17] = 0x6f; h[18] = 0x6d; h[19] = 0x6d
        return h + body
    }

    static func be32(_ d: Data, _ off: Int) -> UInt32 {
        let i = d.startIndex + off
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
}

/// 不碰 socket 的纯解析器，离线可测：喂密文字节，吐出完整的 APTransportPackage。
package final class IapTunnelParser {
    private let key: [UInt8]
    private var cipherBuffer: [UInt8] = []
    private var plainBuffer: [UInt8] = []
    /// 已成功解密的帧数（= 下一帧的 nonce 计数）
    package private(set) var counter: UInt64 = 0

    package init(key: Data) throws {
        guard key.count == 32 else { throw IapTunnelError.badKey }
        self.key = [UInt8](key)
    }

    /// 认证失败抛 PairingCryptoError.authenticationFailed；包头长度不合理抛 implausiblePackage。
    /// 两种都该断开这条连接（MacPlay 同样 destroy socket）。
    package func feed(_ data: Data) throws -> [APTransportPackage] {
        cipherBuffer.append(contentsOf: data)
        var off = 0
        while cipherBuffer.count - off >= 2 {
            let len = Int(cipherBuffer[off]) | Int(cipherBuffer[off + 1]) << 8
            let end = off + 2 + len + 16
            if cipherBuffer.count < end { break }
            let aad = Array(cipherBuffer[off ..< off + 2])
            let sealed = Array(cipherBuffer[off + 2 ..< end])
            let plain = try PairingCrypto.chachaOpen(key: key, nonce: PairingCrypto.nonce64(counter), data: sealed, aad: aad)
            counter += 1
            plainBuffer.append(contentsOf: plain)
            off = end
        }
        cipherBuffer.removeFirst(off)

        var out: [APTransportPackage] = []
        let H = APTransportPackage.headerLength
        var poff = 0
        while plainBuffer.count - poff >= H {
            let size = Int(plainBuffer[poff]) << 24 | Int(plainBuffer[poff + 1]) << 16 | Int(plainBuffer[poff + 2]) << 8 | Int(plainBuffer[poff + 3])
            if size < H || size > APTransportPackage.maxSize {
                plainBuffer = []
                throw IapTunnelError.implausiblePackage(size)
            }
            if plainBuffer.count - poff < size { break }
            out.append(APTransportPackage(header: Data(plainBuffer[poff ..< poff + H]), body: Data(plainBuffer[poff + H ..< poff + size])))
            poff += size
        }
        plainBuffer.removeFirst(poff)
        return out
    }
}

/// 流 130 的 TCP 数据口（Network.framework）。手机在 SETUP 后连这个口，送来加密的 APTransportPackage。
/// 同一时刻只认一条连接：新连接顶掉旧的（计数器从 0 重来）。
package final class IapTunnel {
    /// MacPlay cpStack.ts IAP_DATASTREAM_UUID：SETUP 流 130 的 clientTypeUUID
    package static let clientTypeUUID = "E9459FD0-BCAD-4C45-820F-1E72447EF2F2"

    package var onConnected: ((String) -> Void)?
    /// 一个 'comm' 包的正文：原始 iAP2 字节
    package var onIap: ((Data) -> Void)?
    package var onClosed: (() -> Void)?
    package var onError: ((String) -> Void)?

    private let key: Data
    private var listener: NWListener?
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "session.iap-tunnel")

    package init(key: Data) { self.key = key }

    package var isConnected: Bool { queue.sync { conn != nil } }

    /// 在临时端口监听，等绑定完成后返回端口。
    package func start(timeout: TimeInterval = 5) throws -> UInt16 {
        _ = try IapTunnelParser(key: key)   // 先校验 key
        let l = try NWListener(using: .tcp)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let port = try listenAndWait(l, queue: queue, timeout: timeout)
        listener = l
        return port
    }

    package func stop() {
        listener?.cancel(); listener = nil
        queue.async { [self] in conn?.cancel(); conn = nil }
    }

    private func accept(_ c: NWConnection) {
        guard let parser = try? IapTunnelParser(key: key) else { c.cancel(); return }
        conn?.cancel()
        conn = c
        c.start(queue: queue)
        onConnected?(Self.describe(c.endpoint))
        receive(c, parser: parser)
    }

    private func receive(_ c: NWConnection, parser: IapTunnelParser) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty {
                do {
                    for p in try parser.feed(data) {
                        if p.isIap { self.onIap?(p.body) }
                        else { self.onError?(String(format: "iAP tunnel package type 0x%08x ignored", p.messageType)) }
                    }
                } catch {
                    self.onError?("iAP tunnel decrypt/parse failed: \(error)")
                    self.conn = nil; c.cancel(); self.onClosed?(); return
                }
            }
            if done || err != nil { self.conn = nil; c.cancel(); self.onClosed?(); return }
            self.receive(c, parser: parser)
        }
    }

    private static func describe(_ e: NWEndpoint) -> String {
        if case .hostPort(let h, let p) = e { return "\(h):\(p)" }
        return "?"
    }
}

/// 交给上层（接收器）的隧道句柄：SETUP 130 时就有，手机连上数据口后来数据；
/// 配件→手机方向用 `send` 经事件通道发 `iAPSendMessage`（MacPlay 的反向路径）。
package final class IapTunnelLink {
    /// 手机连上了数据口（对端地址）
    package var onConnected: ((String) -> Void)?
    /// 手机 → 配件：原始 iAP2 字节（来自隧道队列，上层自己切线程）
    package var onIap: ((Data) -> Void)?
    /// 数据口断开（手机关闭、解密失败或流被 TEARDOWN／会话结束）
    package var onClosed: (() -> Void)?
    /// 流 130 的数据口端口
    package let dataPort: UInt16
    private let sender: (Data) -> Bool
    private let lock = NSLock()
    private var torn = false
    /// 流已被拆（TEARDOWN 130／会话结束）：之后不会再有连接；数据口单纯断开时为 false，手机可能重连
    package var isTornDown: Bool { lock.lock(); defer { lock.unlock() }; return torn }

    init(dataPort: UInt16, sender: @escaping (Data) -> Bool) {
        self.dataPort = dataPort; self.sender = sender
    }

    /// 配件 → 手机：事件通道没连上时返回 false（字节丢了，链路层会按定时器重发）。
    @discardableResult
    package func send(_ bytes: Data) -> Bool { sender(bytes) }

    /// 流被拆（TEARDOWN 130／会话结束）：只报一次。
    func tearDown() {
        lock.lock(); let first = !torn; torn = true; lock.unlock()
        if first { onClosed?() }
    }
}
