import Foundation
import Network
import CoreMedia
import Wire

// MARK: - 无线视频会话的数据面：H.264 基本流 → access unit → 同一套 wire
//
// 无线 CarPlay／AirPlay 会话在解密之后交出来的是 H.264 NAL 单元（带 4 字节长度前缀的 AVCC，
// 或带起始码的 Annex B）。这一层不管它从哪来：收 NAL、从 SPS/PPS 拼 avcC、按 access unit 分帧，
// 再照抓窗来源同一套 wire 推 VIDEO_CONFIG + VIDEO_FRAME，pet/App 一行不改。
// 控制面（Wi-Fi 交接、RTSP、配对、流解密）还没做：要真机和自备身份才测得了，这里不伪造。

package final class H264Sink {
    private let server: WSServer
    private var isHEVC = false
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var vps: [UInt8]?
    private var hevcSPS: [UInt8]?
    private var hevcPPS: [UInt8]?
    private var au: [[UInt8]] = []
    private var auHasVCL = false
    private var pending: [UInt8] = []       // Annex B 字节流里还没切完的尾巴
    private var _lastConfig: Data?
    private var _frames = 0
    package var lastConfig: Data? { lock.lock(); defer { lock.unlock() }; return _lastConfig }
    package var frames: Int { lock.lock(); defer { lock.unlock() }; return _frames }
    private let t0 = Date()

    private let lock = NSRecursiveLock()   // 几路屏幕流各有自己的队列，WebSocket 线程也会读 lastConfig

    // 診斷開關：HOMEPLAY_DUMP=/path.h264 把手機送來的 access unit 原樣落盤（display-lab 量排版用）
    private static let dumpPath = ProcessInfo.processInfo.environment["HOMEPLAY_DUMP"]
    private var dumpHandle: FileHandle?

    package init(server: WSServer) { self.server = server }

    /// 會話層從串流配置得知編碼後告訴 sink（H.264 / HEVC）
    package func setCodec(isHEVC hevc: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isHEVC != hevc { vps = nil; hevcSPS = nil; hevcPPS = nil; _lastConfig = nil }
        isHEVC = hevc
    }

    /// 长度前缀（AVCC，4 字节大端）的一包，会话层解密后通常是这种
    package func feedAVCC(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let b = [UInt8](data); var i = 0
        while i + 4 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i+1]) << 16 | Int(b[i+2]) << 8 | Int(b[i+3]); i += 4
            guard len > 0, i + len <= b.count else { break }
            nal(Array(b[i..<(i+len)])); i += len
        }
    }

    /// Annex B 字节流（任意切块）
    package func feedAnnexB(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending += [UInt8](data)
        var starts: [(Int, Int)] = []      // (起始码位置, 起始码长度)
        var i = 0
        while i + 3 <= pending.count {
            if pending[i] == 0, pending[i+1] == 0 {
                if pending[i+2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 4 <= pending.count, pending[i+2] == 0, pending[i+3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        guard starts.count >= 2 else { return }   // 最后一个 NAL 等下一个起始码出现才算完整
        for k in 0..<(starts.count - 1) {
            let a = starts[k].0 + starts[k].1, z = starts[k+1].0
            if z > a { nal(Array(pending[a..<z])) }
        }
        pending = Array(pending[starts.last!.0...])
    }

    private func nal(_ n: [UInt8]) {
        guard let h = n.first else { return }
        // 編碼由配置顯式告知（H.264 的切片頭與 HEVC 的 VPS/SPS/PPS 類型會撞，不能猜）
        if isHEVC {
            let t2 = n.count >= 2 ? (Int(h) >> 1) & 0x3f : 0
            hevcNal(n, type: t2); return
        }
        let type = Int(h & 0x1f)
        let vcl = type == 1 || type == 5
        // 新 access unit 的开头：AUD、参数集、或 first_mb_in_slice == 0 的切片（ue(v) 首位为 1）
        let startsAU = type == 9 || ((type == 7 || type == 8 || type == 6) && auHasVCL) || (vcl && n.count > 1 && n[1] & 0x80 != 0 && auHasVCL)
        if startsAU { flush() }
        switch type {
        case 7: if sps != n { sps = n; pps = nil }
        case 8: if pps != n { pps = n; sendConfig() }
        default: break
        }
        if type != 9 { au.append(n) }
        if vcl { auHasVCL = true }
    }

    private func hevcNal(_ n: [UInt8], type: Int) {
        let vcl = type <= 31
        if vcl && auHasVCL { /* 同一個 AU：CarPlay 一條訊息一個 AU，靠 endAccessUnit 收尾 */ }
        switch type {
        case 32: if vps != n { vps = n; hevcSPS = nil; hevcPPS = nil }
        case 33: if hevcSPS != n { hevcSPS = n; hevcPPS = nil }
        case 34: if hevcPPS != n { hevcPPS = n; sendHEVCConfig() }
        default: break
        }
        au.append(n)
        if vcl { auHasVCL = true }
    }

    private func sendHEVCConfig() {
        guard let vps, let sps = hevcSPS, let pps = hevcPPS else { return }
        var fmt: CMFormatDescription?
        let ok = vps.withUnsafeBufferPointer { a in sps.withUnsafeBufferPointer { b in pps.withUnsafeBufferPointer { c in
            let ptrs = [a.baseAddress!, b.baseAddress!, c.baseAddress!]; let sizes = [vps.count, sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3,
                parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        } } }
        guard ok == noErr, let fmt else { FileHandle.standardError.write("HEVC VPS/SPS/PPS 解析失敗 \(ok)\n".data(using: .utf8)!); return }
        let dim = CMVideoFormatDescriptionGetDimensions(fmt)
        // 自家參數集包（接收器與桌寵兩端都認）：count u8、每個 len u16、NAL 本體
        var blob = Data([UInt8(clamping: 3)])
        for n in [vps, sps, pps] { blob.append(UInt8((n.count >> 8) & 0xff)); blob.append(UInt8(n.count & 0xff)); blob.append(contentsOf: n) }
        let cfg = Wire.videoConfig(width: Int(dim.width), height: Int(dim.height), avcC: blob, codec: 2)
        if cfg == _lastConfig { return }
        _lastConfig = cfg
        server.broadcastBinary(cfg)
        FileHandle.standardError.write("HEVC 來源：VIDEO_CONFIG \(dim.width)x\(dim.height)，參數集 \(blob.count)B\n".data(using: .utf8)!)
    }

    /// 外部（会话层）知道一条消息恰好是一个 access unit 时，立刻收尾，不等下一帧的开头
    package func endAccessUnit() { lock.lock(); defer { lock.unlock() }; flush() }

    private func flush() {
        defer { au = []; auHasVCL = false }
        guard auHasVCL, _lastConfig != nil else { return }
        var annexB = Data()
        var key = false
        for n in au {
            annexB.append(contentsOf: [0, 0, 0, 1]); annexB.append(contentsOf: n)
            if isHEVC { let t = n.count >= 2 ? (Int(n[0]) >> 1) & 0x3f : 0; if (16...21).contains(t) { key = true } }
            else if n[0] & 0x1f == 5 { key = true }
        }
        _frames += 1
        let micros = UInt64(Date().timeIntervalSince(t0) * 1_000_000)
        server.broadcastBinary(Wire.videoFrame(annexB: annexB, keyframe: key, ptsMicros: micros))
        if let p = Self.dumpPath {
            if dumpHandle == nil {
                FileManager.default.createFile(atPath: p, contents: nil)
                dumpHandle = FileHandle(forWritingAtPath: p)
            }
            dumpHandle?.write(annexB)
        }
        if _frames == 1 || _frames % 150 == 0 {
            let tag = isHEVC ? "HEVC" : "H.264"
            FileHandle.standardError.write("\(tag) 来源：已推 \(_frames) 帧（这帧 \(key ? "关键帧" : "P 帧") \(annexB.count)B）\n".data(using: .utf8)!)
        }
    }

    private func sendConfig() {
        guard let sps, let pps, sps.count >= 4 else { return }
        var avcC = Data([1, sps[1], sps[2], sps[3], 0xff, 0xe1])
        avcC.append(contentsOf: [UInt8(sps.count >> 8), UInt8(sps.count & 0xff)]); avcC.append(contentsOf: sps)
        avcC.append(1)
        avcC.append(contentsOf: [UInt8(pps.count >> 8), UInt8(pps.count & 0xff)]); avcC.append(contentsOf: pps)
        // 宽高：用 VideoToolbox 从参数集读，不自己解 SPS
        var fmt: CMFormatDescription?
        let ok = sps.withUnsafeBufferPointer { sp in pps.withUnsafeBufferPointer { pp in
            let ptrs = [sp.baseAddress!, pp.baseAddress!]; let sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        } }
        guard ok == noErr, let fmt else { FileHandle.standardError.write("SPS/PPS 解析失败 \(ok)\n".data(using: .utf8)!); return }
        let dim = CMVideoFormatDescriptionGetDimensions(fmt)
        let cfg = Wire.videoConfig(width: Int(dim.width), height: Int(dim.height), avcC: avcC)
        if cfg == _lastConfig { return }
        _lastConfig = cfg
        server.broadcastBinary(cfg)
        FileHandle.standardError.write("H.264 来源：VIDEO_CONFIG \(dim.width)x\(dim.height)，avcC \(avcC.count)B\n".data(using: .utf8)!)
    }
}

/// 收 H.264 基本流的 TCP 口。会话层接好以前，用它把「解出来之后」这一段在本机验通：
///   ffmpeg … -f h264 tcp://127.0.0.1:<port>
/// framing：annexb（默认，ffmpeg 直出）或 avcc（4 字节长度前缀，会话层解密后的形状）。
package final class H264Ingest {
    private let listener: NWListener
    private let sink: H264Sink
    private let framing: String
    private let queue = DispatchQueue(label: "h264.ingest")

    package init(port: UInt16, sink: H264Sink, framing: String) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.sink = sink; self.framing = framing
    }
    package func start() {
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            FileHandle.standardError.write("H.264 来源接入（\(self.framing)）。\n".data(using: .utf8)!)
            c.start(queue: self.queue); self.read(c)
        }
        listener.start(queue: queue)
    }
    private var avccBuf = Data()
    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                if self.framing == "avcc" { self.avccBuf.append(data); self.drainAVCC() } else { self.sink.feedAnnexB(data) }
            }
            if done || err != nil { FileHandle.standardError.write("H.264 来源断开。\n".data(using: .utf8)!); c.cancel(); return }
            self.read(c)
        }
    }
    // 长度前缀流：凑满一整个 NAL 再交给 sink
    private func drainAVCC() {
        while avccBuf.count >= 4 {
            let b = [UInt8](avccBuf.prefix(4))
            let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard avccBuf.count >= 4 + len else { return }
            sink.feedAVCC(avccBuf.prefix(4 + len))
            avccBuf.removeFirst(4 + len)
        }
    }
}

