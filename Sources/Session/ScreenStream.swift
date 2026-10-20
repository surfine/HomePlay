// 屏幕数据口：128 字节头 + 正文（对应 MacPlay protocol/screenStream.ts、nalu.ts）。
// 头：字节 0–3 正文长度 LE，字节 4 操作码（1 = 编码配置 avcC/hvcC，明文；0 = 视频帧）。
// 帧正文是 ChaCha20-Poly1305 密文||16 字节标签，AAD = 128 字节头，
// nonce = 4 字节 0 + 8 字节小端计数器（从 0 起，只在解密成功时 +1）。
import Foundation
import Network
import CryptoKit
import H264

package enum ScreenCodec: Equatable { case h264, h265 }

package enum ScreenMessage: Equatable {
    /// codecData 是 avcC / hvcC 记录本身（从 fourcc 之后起）
    case config(codec: ScreenCodec, record: Data)
    /// 解密后的长度前缀 NAL 序列
    case frame(nals: Data, keyframe: Bool)
    /// 认证失败的帧：丢掉，计数器不前进（MacPlay 同样）
    case frameRejected
}

package enum ScreenStreamError: Error { case oversizedBody(Int), badKey }

/// 不碰 socket 的纯解析器，离线可测。
package final class ScreenStreamParser {
    package static let headerLength = 128
    package static let opVideoFrame: UInt8 = 0
    package static let opVideoConfig: UInt8 = 1
    package static let maxBody = 8 * 1024 * 1024

    private let key: SymmetricKey
    private var buffer = Data()
    private var codec: ScreenCodec = .h264
    package private(set) var counter: UInt64 = 0

    package init(key: Data) throws {
        guard key.count == 32 else { throw ScreenStreamError.badKey }
        self.key = SymmetricKey(data: key)
    }

    package static func nonce(counter: UInt64) -> Data {
        var d = Data(count: 4)
        for i in 0..<8 { d.append(UInt8((counter >> (8 * UInt64(i))) & 0xff)) }
        return d
    }

    package func feed(_ data: Data) throws -> [ScreenMessage] {
        buffer.append(data)
        var out: [ScreenMessage] = []
        var off = buffer.startIndex
        let H = Self.headerLength
        while buffer.endIndex - off >= H {
            let size = Int(buffer[off]) | Int(buffer[off + 1]) << 8 | Int(buffer[off + 2]) << 16 | Int(buffer[off + 3]) << 24
            if size > Self.maxBody { buffer = Data(); throw ScreenStreamError.oversizedBody(size) }
            if buffer.endIndex - off < H + size { break }
            let header = Data(buffer[off..<off + H])
            let body = Data(buffer[off + H..<off + H + size])
            off += H + size
            if let m = message(header: header, body: body) { out.append(m) }
        }
        buffer = Data(buffer[off...])
        return out
    }

    private func message(header: Data, body: Data) -> ScreenMessage? {
        switch header[header.startIndex + 4] {
        case Self.opVideoConfig:
            let (c, record) = Self.codecData(fromConfig: body)
            codec = c
            return .config(codec: c, record: record)
        case Self.opVideoFrame:
            guard body.count >= 16 else { return .frame(nals: body, keyframe: Self.isKeyframe(body, codec: codec)) }
            do {
                let box = try ChaChaPoly.SealedBox(
                    nonce: ChaChaPoly.Nonce(data: Self.nonce(counter: counter)),
                    ciphertext: body.prefix(body.count - 16), tag: body.suffix(16))
                let plain = try ChaChaPoly.open(box, using: key, authenticating: header)
                counter += 1
                return .frame(nals: plain, keyframe: Self.isKeyframe(plain, codec: codec))
            } catch { return .frameRejected }
        default:
            return nil   // KeepAlive / ForceKeyFrame / Ignore 没有可显示的内容
        }
    }

    /// 在 VideoConfig 正文里找 avcC / hvcC 记录（裸记录、直接的盒子、或 avc1/hvc1 样本条目里嵌着的盒子）
    package static func codecData(fromConfig p: Data) -> (ScreenCodec, Data) {
        let b = [UInt8](p)
        var i = 4
        while i + 4 <= b.count {
            let cc = Array(b[i..<i + 4])
            if cc == Array("hvcC".utf8) { return (.h265, Data(b[(i + 4)...])) }
            if cc == Array("avcC".utf8) { return (.h264, Data(b[(i + 4)...])) }
            i += 1
        }
        if looksLikeAvcC(b) { return (.h264, p) }
        return (.h265, p)
    }

    /// hvcC 記錄 → 4 字節長度前綴的 VPS/SPS/PPS 序列
    package static func hvcCToAVCC(_ p: Data) -> Data? {
        let b = [UInt8](p)
        guard b.count >= 23 else { return nil }
        var i = 22
        let arrays = Int(b[i]); i += 1
        var out = Data()
        for _ in 0..<arrays {
            guard i + 3 <= b.count else { break }
            i += 1                                  // array_completeness | NAL_unit_type
            let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
            for _ in 0..<n {
                guard i + 2 <= b.count else { break }
                let len = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                guard len > 0, i + len <= b.count else { break }
                let l = UInt32(len)
                out.append(contentsOf: [UInt8(l >> 24 & 0xff), UInt8(l >> 16 & 0xff), UInt8(l >> 8 & 0xff), UInt8(l & 0xff)])
                out.append(contentsOf: b[i..<(i + len)]); i += len
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func looksLikeAvcC(_ a: [UInt8]) -> Bool {
        guard a.count >= 9, a[5] & 0x1f >= 1 else { return false }
        let spsLen = Int(a[6]) << 8 | Int(a[7])
        return 8 + spsLen <= a.count && a[8] & 0x1f == 7
    }

    /// 长度前缀 NAL 里有没有 IDR（H.264 type 5；H.265 type 16...21）
    package static func isKeyframe(_ nals: Data, codec: ScreenCodec) -> Bool {
        let b = [UInt8](nals); var i = 0
        while i + 4 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]); i += 4
            guard len > 0, i + len <= b.count else { break }
            if codec == .h264 { if b[i] & 0x1f == 5 { return true } }
            else { let t = Int(b[i] >> 1) & 0x3f; if (16...21).contains(t) { return true } }
            i += len
        }
        return false
    }

    /// avcC 记录 → 长度前缀的 SPS+PPS（喂 H264Sink.feedAVCC 用）
    package static func avcCToNALs(_ avcC: Data) -> Data? {
        let b = [UInt8](avcC)
        guard b.count >= 7, b[0] == 1 else { return nil }
        var i = 6, out = Data()
        func take(_ count: Int) -> Bool {
            for _ in 0..<count {
                guard i + 2 <= b.count else { return false }
                let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                guard n > 0, i + n <= b.count else { return false }
                out.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
                out.append(contentsOf: b[i..<i + n]); i += n
            }
            return true
        }
        guard take(Int(b[5] & 0x1f)), i < b.count else { return nil }
        let numPPS = Int(b[i]); i += 1
        guard take(numPPS) else { return nil }
        return out
    }
}

/// 屏幕数据口的 TCP 服务（Network.framework）。手机在 SETUP 后连这个口。
package final class ScreenStream {
    package var onConfig: ((_ codec: ScreenCodec, _ record: Data) -> Void)?
    package var onFrame: ((_ avccNALs: Data, _ keyframe: Bool) -> Void)?
    package var onError: ((String) -> Void)?

    private let key: Data
    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private let queue = DispatchQueue(label: "session.screen")

    package init(key: Data) { self.key = key }

    /// 在临时端口监听，等绑定完成后返回端口。
    package func start(timeout: TimeInterval = 5) throws -> UInt16 {
        _ = try ScreenStreamParser(key: key)   // 先校验 key
        let l = try NWListener(using: .tcp)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let port = try listenAndWait(l, queue: queue, timeout: timeout)
        listener = l
        return port
    }

    package func stop() {
        listener?.cancel(); listener = nil
        queue.async { [self] in conns.forEach { $0.cancel() }; conns = [] }
    }

    private func accept(_ c: NWConnection) {
        guard let parser = try? ScreenStreamParser(key: key) else { c.cancel(); return }
        conns.append(c)
        c.start(queue: queue)
        func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data, !data.isEmpty {
                    do {
                        for m in try parser.feed(data) {
                            switch m {
                            case .config(let codec, let rec): self.onConfig?(codec, rec)
                            case .frame(let nals, let key): self.onFrame?(nals, key)
                            case .frameRejected: self.onError?("screen frame authentication failed")
                            }
                        }
                    } catch { self.onError?("\(error)"); c.cancel(); return }
                }
                if done || err != nil { c.cancel(); return }
                loop()
            }
        }
        loop()
    }
}

/// 把屏幕流接到现有的 H264Sink：config → SPS/PPS；frame → feedAVCC，并立刻收尾这一帧。
package final class ScreenStreamH264Adapter {
    private let sink: H264Sink
    package private(set) var configs = 0
    package private(set) var frames = 0
    package init(sink: H264Sink) { self.sink = sink }

    package func attach(to stream: ScreenStream) {
        stream.onConfig = { [weak self] codec, rec in self?.handleConfig(codec: codec, record: rec) }
        stream.onFrame = { [weak self] nals, _ in self?.handleFrame(nals) }
    }

    package func handleConfig(codec: ScreenCodec, record: Data) {
        sink.setCodec(isHEVC: codec == .h265)
        let nals: Data?
        if codec == .h265 { nals = ScreenStreamParser.hvcCToAVCC(record) }
        else { nals = ScreenStreamParser.avcCToNALs(record) }
        guard let nals else { return }
        configs += 1
        sink.feedAVCC(nals)
    }

    package func handleFrame(_ nals: Data) {
        frames += 1
        sink.feedAVCC(nals)
        sink.endAccessUnit()   // CarPlay 一条消息就是一个 access unit，不等下一帧才吐
    }
}

/// NWListener 启动并等到端口绑定（同步封装，给 SETUP 流程用）。
func listenAndWait(_ l: NWListener, queue: DispatchQueue, timeout: TimeInterval) throws -> UInt16 {
    let sem = DispatchSemaphore(value: 0)
    let box = LockedBox<Result<UInt16, Error>?>(nil)
    l.stateUpdateHandler = { st in
        switch st {
        case .ready: if let p = l.port?.rawValue { box.set(.success(p)); sem.signal() }
        case .failed(let e): box.set(.failure(e)); sem.signal()
        default: break
        }
    }
    l.start(queue: queue)
    if sem.wait(timeout: .now() + timeout) == .timedOut { l.cancel(); throw ListenError.timeout }
    switch box.get() {
    case .success(let p)?: return p
    case .failure(let e)?: throw e
    default: throw ListenError.timeout
    }
}

package enum ListenError: Error { case timeout }

final class LockedBox<T>: @unchecked Sendable {
    private var v: T; private let lock = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}
