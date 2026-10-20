// CarPlay 麥克風上行：抓 Mac 輸入裝置 → 重採樣到協商的 Opus 率 → Opus 編碼
// → ChaCha20-Poly1305 封裝 → UDP 發到手機在 SETUP 裡給的 mic dataPort。
// 封包格式照 MacPlay `livi-gst-video/rust/mic/src/lib.rs`：
//   12B RTP 頭（0x80、PT=流類型、seq/timestamp 大端、SSRC=0）
//   + 密文 + 16B tag + 8B 小端 nonce 計數；AAD = header[4..12]；nonce = 4 個零 + 8B 小端計數。
// 啟動時機：手機為 type 100（MainAudio）SETUP 出 dataPort＝它要麥克風（Siri/電話）。
import AVFoundation
import CryptoKit
import Foundation
import Network

package final class MicUplink {
    /// 上行负载：无线低延迟流协商到 Opus 时编 Opus；手机给的是 PCM（如 fmt=0x40 的
    /// Siri 流）时直接发 16-bit 大端 PCM，采样率/声道跟 SETUP 一致。
    package enum WireCodec { case opus, pcm }

    private let wireCodec: WireCodec
    private let key: SymmetricKey
    private let payloadType: UInt8
    private let sampleRate: Double
    private let channels: Int
    private let frameMs: Int
    private let bitrate: Int
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "session.mic.uplink")
    package var onLog: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var resampler: AVAudioConverter?
    private var resamplerInputRate: Double = 0
    private var encoder: AudioConverterRef?
    private var opusMax = 1024
    private var pending: [Float] = []
    private var seq: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var nonceCount: UInt64 = 0
    private var packetsSent = 0
    private var started = false
    private var stopped = false
    private var conn: NWConnection?

    package init(codec: WireCodec = .opus, key: Data, payloadType: Int, sampleRate: Int,
                 channels: Int = 1, frameMs: Int, bitrate: Int, host: String, port: UInt16) {
        self.wireCodec = codec
        self.key = SymmetricKey(data: key)
        self.payloadType = UInt8(clamping: payloadType) & 0x7f
        self.sampleRate = Double(sampleRate)
        self.channels = max(1, channels)
        self.frameMs = max(5, frameMs)
        self.bitrate = bitrate
        self.host = host
        self.port = port
    }

    private var codecLabel: String { wireCodec == .opus ? "Opus" : "PCM" }

    package var description: String { "\(codecLabel) \(Int(sampleRate)) Hz → \(host):\(port)" }

    package func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    package func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            if let e = self.engine {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
            }
            self.engine = nil
            self.conn?.cancel(); self.conn = nil
        }
    }

    // MARK: 启动

    private func startOnQueue() {
        guard !started, !stopped else { return }
        started = true
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            beginCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                guard let self else { return }
                self.queue.async {
                    if ok, !self.stopped { self.beginCapture() }
                    else { self.onLog?("麦克风权限被拒绝：系统设置 › 隐私与安全性 › 麦克风 里勾选 HomePlay") }
                }
            }
        default:
            onLog?("麦克风权限被拒绝：系统设置 › 隐私与安全性 › 麦克风 里勾选 HomePlay")
        }
    }

    private func beginCapture() {
        guard !stopped, engine == nil else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            onLog?("没有可用的麦克风输入设备")
            return
        }
        if wireCodec == .opus {
            guard makeEncoder() else { return }
        }
        // 网络连接先建好，包一编出来就能发（NWConnection 会缓存未就绪时的 send）
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed(let err): self?.onLog?("麦克风上行 UDP 失败：\(err)")
            default: break
            }
        }
        c.start(queue: queue)
        conn = c

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            guard let self, !self.stopped else { return }
            guard let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength), channels = Int(buf.format.channelCount)
            guard n > 0, channels > 0 else { return }
            var mono = [Float](repeating: 0, count: n)
            if channels == 1 {
                mono.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress?.update(from: ch[0], count: n)
                }
            } else {
                for i in 0..<n {
                    var s: Float = 0
                    for k in 0..<channels { s += ch[k][i] }
                    mono[i] = s / Float(channels)
                }
            }
            let rate = buf.format.sampleRate
            self.queue.async { self.resampleAndEncode(mono, inputRate: rate) }
        }
        e.prepare()
        do {
            try e.start()
            engine = e
            onLog?("麦克风上行已启动（\(Int(inFormat.sampleRate)) Hz → \(codecLabel) \(Int(sampleRate)) Hz，\(host):\(port)）")
        } catch {
            onLog?("麦克风引擎起不来：\(error)")
        }
    }

    // MARK: 重采样与编码（串行队列）

    private func resampleAndEncode(_ mono: [Float], inputRate: Double) {
        guard !stopped, !mono.isEmpty else { return }
        if resampler == nil || resamplerInputRate != inputRate {
            guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
                                            channels: 1, interleaved: false),
                  let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
                onLog?("麦克风重采样器建不起来（\(Int(inputRate)) → \(Int(sampleRate))）")
                return
            }
            resampler = conv
            resamplerInputRate = inputRate
        }
        guard let conv = resampler,
              let inBuf = AVAudioPCMBuffer(pcmFormat: conv.inputFormat, frameCapacity: AVAudioFrameCount(mono.count)) else { return }
        inBuf.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: mono.count)
        }
        let capacity = AVAudioFrameCount(Double(mono.count) * sampleRate / inputRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, outBuf.frameLength > 0, let pcm = outBuf.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: pcm, count: Int(outBuf.frameLength)))
        let frameSamples = max(1, Int(sampleRate * Double(frameMs) / 1000))
        while pending.count >= frameSamples {
            let chunk = Array(pending.prefix(frameSamples))
            pending.removeFirst(frameSamples)
            encodeAndSend(chunk)
        }
    }

    private func makeEncoder() -> Bool {
        var inFmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let frameSamples = max(1, Int(sampleRate * Double(frameMs) / 1000))
        var outFmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: AudioFormatID(0x6F707573), // 'opus'
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSamples),
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var conv: AudioConverterRef?
        let rc = AudioConverterNew(&inFmt, &outFmt, &conv)
        guard rc == noErr, let conv else {
            onLog?("Opus 编码器建不起来（\(rc)）")
            return false
        }
        var br = UInt32(bitrate)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, 4, &br)
        var maxOut: UInt32 = 0, size = UInt32(4)
        AudioConverterGetProperty(conv, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxOut)
        opusMax = max(512, Int(maxOut))
        encoder = conv
        return true
    }

    /// FillComplexBuffer 的输入回调是 C 函数指针，不能捕获上下文：数据指针/帧数/已取标记
    /// 都放在 userData 指向的状态里。
    private struct InputState {
        var data: UnsafeMutableRawPointer?
        var frames: Int = 0
        var consumed = false
    }

    private func encodeAndSend(_ samples: [Float]) {
        if wireCodec == .pcm {
            send(Self.pcm16BE(samples, channels: channels))
            return
        }
        guard let enc = encoder, !stopped else { return }
        let outPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: opusMax)
        defer { outPtr.deallocate() }
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(opusMax), mData: outPtr))
        var packets: UInt32 = 1
        let status: OSStatus = samples.withUnsafeBufferPointer { sp in
            var state = InputState(data: UnsafeMutableRawPointer(mutating: sp.baseAddress),
                                   frames: sp.count)
            let proc: AudioConverterComplexInputDataProc = { _, ioNum, ioData, _, ctx in
                let st = ctx!.assumingMemoryBound(to: InputState.self)
                if st.pointee.consumed || ioNum.pointee == 0 { ioNum.pointee = 0; return noErr }
                st.pointee.consumed = true
                ioNum.pointee = UInt32(st.pointee.frames)
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mNumberChannels = 1
                ioData.pointee.mBuffers.mDataByteSize = UInt32(st.pointee.frames * 4)
                ioData.pointee.mBuffers.mData = st.pointee.data
                return noErr
            }
            return AudioConverterFillComplexBuffer(enc, proc, &state, &packets, &abl, nil)
        }
        guard status == noErr, packets > 0 else { return }
        let length = Int(abl.mBuffers.mDataByteSize)
        guard length > 0 else { return }
        send(Data(bytes: outPtr, count: length))
    }

    // MARK: RTP + 加密

    /// PCM 上行的负载：16-bit 大端，按声道重复单声道采样（麦是单声道；声道数跟 SETUP）。
    /// MacPlay 的 `to_wire_pcm` 同样做小端→大端交换。
    package static func pcm16BE(_ samples: [Float], channels: Int = 1) -> Data {
        let ch = max(1, channels)
        var out = Data(capacity: samples.count * ch * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            let v = Int16((clamped * 32767).rounded())
            let hi = UInt8(truncatingIfNeeded: v >> 8)
            let lo = UInt8(truncatingIfNeeded: v)
            for _ in 0..<ch { out.append(hi); out.append(lo) }
        }
        return out
    }

    /// 一个上行包（测试也用它验证线格式）：12B 头 + 密文 + 16B tag + 8B 小端 nonce 计数
    package static func sealPacket(key: SymmetricKey, payloadType: UInt8, seq: UInt16,
                                   timestamp: UInt32, nonce nonceCount: UInt64, body: Data) -> Data? {
        var header = Data([0x80, payloadType & 0x7f])
        header.append(Data([UInt8(seq >> 8), UInt8(seq & 0xff)]))
        header.append(Data([UInt8((timestamp >> 24) & 0xff), UInt8((timestamp >> 16) & 0xff),
                            UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff)]))
        header.append(contentsOf: [0, 0, 0, 0])   // SSRC = 0
        var nonceBytes = Data([0, 0, 0, 0])
        var n = nonceCount
        for _ in 0..<8 { nonceBytes.append(UInt8(n & 0xff)); n >>= 8 }
        guard let nonce = try? ChaChaPoly.Nonce(data: nonceBytes),
              let box = try? ChaChaPoly.seal(body, using: key, nonce: nonce,
                                             authenticating: header[4..<12]) else { return nil }
        var packet = header
        packet.append(box.ciphertext)
        packet.append(box.tag)
        packet.append(nonceBytes.suffix(8))
        return packet
    }

    private func send(_ opus: Data) {
        guard let packet = Self.sealPacket(key: key, payloadType: payloadType, seq: seq,
                                           timestamp: timestamp, nonce: nonceCount, body: opus) else { return }
        conn?.send(content: packet, completion: .contentProcessed { _ in })
        if packetsSent == 0 {
            onLog?("麦克风上行：首个包已发（\(packet.count) 字节，\(codecLabel) \(Int(sampleRate)) Hz）")
        } else if packetsSent % 500 == 0 {
            onLog?("麦克风上行：已发 \(packetsSent) 包")
        }
        packetsSent += 1
        seq = seq &+ 1
        timestamp = timestamp &+ UInt32(max(1, Int(sampleRate * Double(frameMs) / 1000)))
        nonceCount += 1
    }

}
