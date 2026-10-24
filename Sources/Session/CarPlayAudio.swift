// 无线 CarPlay 的音频输出（接收端）。对应 MacPlay livi-gst-video/rust/audio 与 cpStack._setupAudio：
// 一个 UDP 包 = 12 字节 RTP 头（时间戳字段 = 采样位置）+ 密文 + 16 字节 tag + 8 字节 nonce，
// ChaCha20-Poly1305（AAD = 时间戳 + SSRC），密钥与屏幕流同一套 HKDF（DataStream-Salt<id>，Output 方向）。
// 无线媒体流是 AAC-LC（44.1k/48k 立体声）一帧一包；PCM 只有有线才会出现（大端样本）。
// 出声：AAC 帧套 ADTS 头经 AudioFileStream + AudioConverter 解成 PCM，交 AVAudioEngine 排播；PCM 直接转浮点。
import Foundation
import CryptoKit
import AudioToolbox
import CoreAudio
import AVFoundation

// MARK: - 线格式（纯逻辑，可离线测试）

/// MPEG-4 采样率下标（AudioSpecificConfig 用）。表里没有的按 48k（下标 3）。
package func aacFrequencyIndex(_ rate: Int) -> Int {
    switch rate {
    case 96000: return 0
    case 88200: return 1
    case 64000: return 2
    case 48000: return 3
    case 44100: return 4
    case 32000: return 5
    case 24000: return 6
    case 22050: return 7
    case 16000: return 8
    default: return 3
    }
}

/// 两字节 AudioSpecificConfig：AAC-LC（对象类型 2）+ 采样率下标 + 声道数。
package func aacSpecificConfig(rate: Int, channels: Int) -> [UInt8] {
    let asc = (2 << 11) | (aacFrequencyIndex(rate) << 7) | (channels << 3)
    return [UInt8((asc >> 8) & 0xff), UInt8(asc & 0xff)]
}

/// 7 字节 ADTS 头（无 CRC）：给裸 AAC-LC access unit 套上，交给系统的 ADTS 解析器。
/// 真机帧裸喂 AudioConverter（不管 ASBD / ASC / ESDS cookie）都解 0 帧，套 ADTS 后由
/// AudioFileStream 解析出包和 cookie 再交 converter 就正常——见 CarPlayAudioPlayer。
package func adtsHeader(frameLength: Int, rate: Int, channels: Int) -> [UInt8] {
    let len = frameLength + 7
    let fi = aacFrequencyIndex(rate)
    return [0xff, 0xf1,                                              // syncword + MPEG-4 + 无 CRC
            UInt8((1 << 6) | (fi << 2) | ((channels >> 2) & 1)),     // profile LC(=2-1) + 采样率 + 声道高位
            UInt8(((channels & 3) << 6) | ((len >> 11) & 3)),
            UInt8((len >> 3) & 0xff),
            UInt8(((len & 7) << 5) | 0x1f),                          // buffer fullness 0x7ff（VBR）
            0xfc]                                                    // 一个 raw data block
}

/// 一个 UDP 包 →（采样位置，明文）。身份不对或包太短都安静地丢。
/// 线格式照 MacPlay rust/audio：AAD = 包[4..12]，nonce = 4 字节零 + 包尾 8 字节。
package struct AudioStreamDecryptor {
    static let headerLen = 12
    static let tailLen = 24      // 16 字节 tag + 8 字节 nonce

    private let key: SymmetricKey

    package init(key: Data) { self.key = SymmetricKey(data: key) }

    package func push(_ packet: [UInt8]) -> (sample: UInt32, payload: [UInt8])? {
        guard packet.count >= Self.headerLen + Self.tailLen else { return nil }
        let end = packet.count
        let aad = Data(packet[4 ..< Self.headerLen])
        let ciphertext = Data(packet[Self.headerLen ..< end - Self.tailLen])
        let tag = Data(packet[end - Self.tailLen ..< end - 8])
        let shortNonce = Data(packet[(end - 8)...])
        let nonce = Data(repeating: 0, count: 4) + shortNonce
        guard let box = try? ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                                  ciphertext: ciphertext, tag: tag),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: aad) else { return nil }
        let sample = UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16 | UInt32(packet[6]) << 8 | UInt32(packet[7])
        return (sample, [UInt8](plain))
    }
}

// MARK: - 播放（ADTS → AudioFileStream → AudioConverter 解码 → AVAudioEngine 放 PCM）
//
// 踩坑记录（为什么是现在这个架构）：
// 1. AudioQueue 直接放 AAC：magic cookie 一律被拒（'!cat' 560226676），压缩格式进不了队列。
// 2. 真机帧裸喂 AudioConverter（手写 ASBD + 裸 ASC / 完整 ESDS cookie）每帧 rc=0、0 帧；
//    afconvert 编出的本地帧同样写法却能解。改成给每帧套 7 字节 ADTS 头，由 AudioFileStream
//    解析出 ASBD、magic cookie 和包描述，再交给照它建的 converter——系统自己的配法。
// 3. 一次只要一包的量（1024 帧）；输入回调交完这一包后回「暂时没货」而不是 0 包 + noErr
//    （后者等于宣告流结束）。
// 4. AudioConverter + 空 AudioQueue 同进程共存时 FillComplexBuffer 会卡死（离线复现：5 帧后永久阻塞）。
// 结论：AudioConverter 只管解，出声交给 AVAudioEngine + AVAudioPlayerNode——无回调、CLI 可用。

/// AudioFileStream 的回调落点：解析出的格式、magic cookie 和一包包裸 AAC。
private final class ParsedStream {
    var format = AudioStreamBasicDescription()
    var cookie: [UInt8]?
    var packets: [[UInt8]] = []

    static let propertyProc: AudioFileStream_PropertyListenerProc = { ctx, fs, prop, _ in
        let me = Unmanaged<ParsedStream>.fromOpaque(ctx).takeUnretainedValue()
        switch prop {
        case kAudioFileStreamProperty_DataFormat:
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFileStreamGetProperty(fs, prop, &size, &me.format)
        case kAudioFileStreamProperty_MagicCookieData:
            var size: UInt32 = 0
            guard AudioFileStreamGetPropertyInfo(fs, prop, &size, nil) == noErr, size > 0 else { return }
            var c = [UInt8](repeating: 0, count: Int(size))
            if AudioFileStreamGetProperty(fs, prop, &size, &c) == noErr { me.cookie = c }
        default: break
        }
    }

    static let packetsProc: AudioFileStream_PacketsProc = { ctx, _, count, data, descs in
        let me = Unmanaged<ParsedStream>.fromOpaque(ctx).takeUnretainedValue()
        guard let descs else { return }
        for k in 0..<Int(count) {
            let d = descs[k]
            let p = data.advanced(by: Int(d.mStartOffset)).assumingMemoryBound(to: UInt8.self)
            me.packets.append(Array(UnsafeBufferPointer(start: p, count: Int(d.mDataByteSize))))
        }
    }
}

package final class CarPlayAudioPlayer {
    package enum Codec {
        case aacLc(rate: Int, channels: Int)
        case pcmBe(rate: Int, channels: Int)
        /// 無線的低延遲流（導航/Siri/電話）：Opus 單聲道
        case opus(rate: Int, channels: Int)

        package var rate: Int {
            switch self {
            case .aacLc(let r, _), .pcmBe(let r, _), .opus(let r, _): return r
            }
        }
        package var channels: Int {
            switch self {
            case .aacLc(_, let c), .pcmBe(_, let c), .opus(_, let c): return c
            }
        }
        package var isAAC: Bool { if case .aacLc = self { return true }; return false }
        package var isOpus: Bool { if case .opus = self { return true }; return false }
    }

    private let codec: Codec
    private let lock = NSLock()
    /// converter / AudioFileStream 的解析与释放必须互斥；解码在音频收包队列，stop 在控制队列
    private let codecLock = NSLock()
    /// AVAudioEngine 的启停、重连与排播全部串行；设备变化通知也回到这里
    private let engineQueue = DispatchQueue(label: "homeplay.audio.engine")
    private var configObserver: NSObjectProtocol?
    private var pending: [Data] = []
    private var converter: AudioConverterRef?
    private var fileStream: AudioFileStreamID?
    private let parsed = ParsedStream()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var failed = false
    private var running = false
    package private(set) var played = 0
    package var onLog: ((String) -> Void)?
    /// 另一台引擎要代放（麥克風開了回音消除：下行得從語音處理引擎出聲才有參考）。
    /// 回 false＝那邊還沒準備好，照舊用自己的引擎放。
    package var renderSink: ((AVAudioPCMBuffer) -> Bool)?

    package init(codec: Codec) {
        self.codec = codec
        // AVAudioEngine 只吃非交错 Float32；解码器输出交错的，emit 里拆声道
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(codec.rate),
                                      channels: AVAudioChannelCount(codec.channels)) else {
            fail("PCM 格式建不起来"); return
        }
        format = fmt
        if codec.isAAC {
            let rc = AudioFileStreamOpen(Unmanaged.passUnretained(parsed).toOpaque(),
                                         ParsedStream.propertyProc, ParsedStream.packetsProc,
                                         AudioFileTypeID(kAudioFileAAC_ADTSType), &fileStream)
            guard rc == noErr else { fail("ADTS 解析器建不起来（\(rc)）"); return }
        }
        // 接上輸出要打開預設輸出裝置（藍牙耳機、AirPlay 時常要好幾秒，真機 2026-10-24 量到 0.9–16 秒）。
        // 這段原本在 SETUP 回應之前同步做，手機等不到就報錯（1852797029＝'nope'）並拆掉重來。
        // 改到 engineQueue 上非同步：SETUP 立刻回；第一幀來時 ensureRunning 也在這條佇列上，順序不變。
        engineQueue.async { [engine, node] in
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            engine.prepare()
        }
        running = true
        // 預設輸出裝置被拔掉／切換時，AVAudioEngine 會停下來；不重建連線就一直沒聲。
        // 回到 engineQueue 重新接上 mainMixer，下一幀或立刻繼續。
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            // 有些系統版本把 object 留空；有帶 engine 時只認自己的那一台
            if let e = note.object as? AVAudioEngine, e !== self.engine { return }
            self.engineQueue.async { self.recoverEngineOnQueue() }
        }
        // 依 Apple 的 CarPlay 音訊建議：只在真的要播時開音訊會話，停下就關。
        // 這裡 12 秒沒有新音訊就暫停引擎（省電、不佔用輸出裝置），下一幀來再開。
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "homeplay.audio.idle", qos: .utility))
        t.schedule(deadline: .now() + 12, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.engineQueue.async { self.pauseIfIdleOnQueue() }
        }
        t.resume(); idleTimer = t
    }

    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = CACurrentMediaTime()
    /// 裝置切換的瞬間引擎可能起不來；留 1 秒重試，不要一次失敗就永久靜音
    private var startRetryAt = 0.0

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && !failed
    }

    /// 距離上一次有音訊多久（秒）。`lastActivity` 在 enqueue 裡由鎖保護寫入，
    /// 讀也要在同一把鎖下，否則會讀到半寫入的值。
    private func idleSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - lastActivity
    }

    /// 閒置就暫停引擎；有聲音再開（engineQueue 上）
    private func pauseIfIdleOnQueue() {
        guard isRunning() else { return }
        lock.lock(); let empty = pending.isEmpty; lock.unlock()
        guard empty, engine.isRunning, idleSeconds() > 12 else { return }
        node.pause(); engine.pause(); onLog?("音频空闲，暂停引擎")
    }

    private func ensureRunning() {
        engineQueue.sync { ensureRunningOnQueue() }
    }

    private func ensureRunningOnQueue() {
        guard isRunning() else { return }
        if !engine.isRunning {
            let now = CACurrentMediaTime()
            guard now >= startRetryAt else { return }
            startRetryAt = now + 1
            do { engine.prepare(); try engine.start(); node.play(); onLog?("音频引擎恢复") }
            catch { onLog?("音频引擎起不来（\(error)），1 秒后重试") }
        } else if !node.isPlaying { node.play() }
    }

    /// 裝置切換後重建輸出連線；音訊流本身（密鑰、nonce、排隊）不動
    private func recoverEngineOnQueue() {
        guard isRunning(), let fmt = format else { return }
        onLog?("音频设备变化，重建输出")
        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        startRetryAt = 0
        lock.lock(); let waiting = !pending.isEmpty; lock.unlock()
        guard waiting || idleSeconds() < 12 else { return }
        do { try engine.start(); node.play(); onLog?("音频引擎已切到新设备") }
        catch {
            startRetryAt = CACurrentMediaTime() + 1
            onLog?("音频设备变化后引擎起不来（\(error)），1 秒后重试")
        }
    }

    /// 自检用：模拟 macOS 的默认输出设备变化，走真实的重连路径
    package func simulateConfigurationChange() {
        engineQueue.sync { recoverEngineOnQueue() }
    }

    /// 自检用：排一小段静音，走真实的 scheduleBuffer 路径
    package func playSilence(seconds: Double) {
        guard let fmt = format else { return }
        let frames = AVAudioFrameCount(Double(codec.rate) * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        engineQueue.sync {
            guard isRunning() else { return }
            ensureRunningOnQueue()
            guard engine.isRunning else { return }
            node.scheduleBuffer(buf)
        }
    }

    /// 自检用：在调用线程上解一帧，返回浮点数（诊断是线程还是引擎的问题）
    package func diagnose(_ frame: Data) -> Int {
        decode(frame).count
    }

    /// 诊断快照（心跳日志用）
    package var snapshot: String {
        lock.lock(); defer { lock.unlock() }
        return "played=\(played) pending=\(pending.count) running=\(running) failed=\(failed)"
    }

    package func enqueue(payload: Data) {
        lock.lock()
        guard !failed else { lock.unlock(); return }
        pending.append(payload)
        // 主缓冲音频（type 102）手机最多会预送约 2 分钟；队列留够，不要按实时速度丢帧。
        // 6000 帧 ≈ 2.3 分钟（AAC 1024 samples @44.1k），约 3–4 MB。
        let limit = 6000
        let overflow = pending.count > limit
        if overflow { pending.removeFirst(pending.count - limit) }
        lastActivity = CACurrentMediaTime()
        lock.unlock()
        if overflow { onLog?("音频排队超过 6000 帧，丢最旧的") }
        pump()
    }

    /// 閃避（duckAudio）：在 engineQueue 上把播放音量以 ~60 Hz 線性推到目標，避免喀聲。
    private var duckGen = 0
    package func ramp(to volume: Float, over seconds: Double) {
        engineQueue.async { [self] in
            duckGen += 1
            let gen = duckGen, from = node.volume, steps = max(1, Int(seconds * 60))
            for i in 1...steps {
                engineQueue.asyncAfter(deadline: .now() + seconds * Double(i) / Double(steps)) { [self] in
                    guard gen == duckGen else { return }
                    node.volume = from + (volume - from) * Float(i) / Float(steps)
                }
            }
        }
    }

    package func stop() {
        idleTimer?.cancel(); idleTimer = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        lock.lock()
        running = false; failed = true
        pending.removeAll()
        lock.unlock()
        engineQueue.sync {
            node.stop()
            engine.stop()
        }
        codecLock.lock()
        if let c = converter { AudioConverterDispose(c) }
        converter = nil
        if let f = fileStream { AudioFileStreamClose(f) }
        fileStream = nil
        if let d = opusDecoder { AudioConverterDispose(d) }
        opusDecoder = nil
        codecLock.unlock()
    }

    /// 有货就解一帧排给播放节点。decode 不能在锁内（AudioConverter 有自己的锁）。
    private func pump() {
        ensureRunning()
        while true {
            lock.lock()
            guard running, !failed, let frame = pending.first else { lock.unlock(); return }
            pending.removeFirst()
            lock.unlock()
            emit(frame)
        }
    }

    private func emit(_ frame: Data) {
        var pcm = codec.isAAC ? decode(frame) : (codec.isOpus ? decodeOpus(frame) : pcmToFloat(frame))
        guard pcm.count > 0, let fmt = format else {
            // 首帧解码出 0 帧（AAC priming）之类：直接跳过，不算失败
            if !toldEmptyDecode { toldEmptyDecode = true; onLog?("首包解码为空（priming），跳过等下一帧") }
            return
        }
        let frames = pcm.count / codec.channels
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<codec.channels {
            let dst = buf.floatChannelData![c]
            for f in 0..<frames { dst[f] = pcm[f * codec.channels + c] }
        }
        if let sink = renderSink, sink(buf) {
            lock.lock(); played += 1; lock.unlock()
            return
        }
        let scheduled = engineQueue.sync { () -> Bool in
            guard isRunning(), engine.isRunning else { return false }
            node.scheduleBuffer(buf)
            return true
        }
        guard scheduled else { return }
        lock.lock(); played += 1; lock.unlock()
    }

    private var toldEmptyDecode = false
    private var decodeFailures = 0

    private var opusDecoder: AudioConverterRef?

    /// 一个裸 Opus 包 → 交错 Float32（单声道）。CoreAudio 自带 Opus 解码。
    private func decodeOpus(_ frame: Data) -> [Float] {
        codecLock.lock(); defer { codecLock.unlock() }
        if opusDecoder == nil {
            var inFmt = AudioStreamBasicDescription(
                mSampleRate: Double(codec.rate), mFormatID: AudioFormatID(0x6F707573),
                mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
                mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
            var outFmt = AudioStreamBasicDescription(
                mSampleRate: Double(codec.rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            var conv: AudioConverterRef?
            guard AudioConverterNew(&inFmt, &outFmt, &conv) == noErr else {
                onLog?("Opus 解码器建不起来"); return []
            }
            opusDecoder = conv
        }
        guard let conv = opusDecoder, !frame.isEmpty else { return [] }
        let capacity = max(4096, codec.rate / 5)   // 200ms 余量
        let pcmPtr = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { pcmPtr.deallocate() }
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(capacity * 4), mData: pcmPtr))
        var packets: UInt32 = UInt32(capacity)
        var state = OpusInput(data: nil, bytes: 0, consumed: false, desc: nil)
        let status: OSStatus = frame.withUnsafeBytes { raw in
            state.data = UnsafeMutableRawPointer(mutating: raw.baseAddress)
            state.bytes = raw.count
            let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            defer { desc.deallocate() }
            desc.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(raw.count))
            state.desc = desc
            let proc: AudioConverterComplexInputDataProc = { _, ioNum, ioData, ioDesc, ctx in
                let st = ctx!.assumingMemoryBound(to: OpusInput.self)
                if st.pointee.consumed || ioNum.pointee == 0 { ioNum.pointee = 0; return noErr }
                st.pointee.consumed = true
                ioNum.pointee = 1
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mNumberChannels = 1
                ioData.pointee.mBuffers.mDataByteSize = UInt32(st.pointee.bytes)
                ioData.pointee.mBuffers.mData = st.pointee.data
                if let d = ioDesc { d.pointee = st.pointee.desc! }
                return noErr
            }
            return AudioConverterFillComplexBuffer(conv, proc, &state, &packets, &abl, desc)
        }
        guard status == noErr, abl.mBuffers.mDataByteSize > 0 else { return [] }
        let frames = Int(abl.mBuffers.mDataByteSize) / 4
        return Array(UnsafeBufferPointer(start: pcmPtr, count: frames))
    }

    /// C 回调不能捕获上下文：Opus 包指针/长度/已取标记放这里
    private struct OpusInput {
        var data: UnsafeMutableRawPointer?
        var bytes: Int
        var consumed: Bool
        var desc: UnsafeMutablePointer<AudioStreamPacketDescription>?
    }

    /// 一帧裸 AAC → 交错的 Float32：套 ADTS 头交给 AudioFileStream，它吐出的包逐个解。
    private func decode(_ frame: Data) -> [Float] {
        codecLock.lock(); defer { codecLock.unlock() }
        guard let fs = fileStream else { return [] }
        var adts = adtsHeader(frameLength: frame.count, rate: codec.rate, channels: codec.channels)
        adts.append(contentsOf: frame)
        let parseRC = adts.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(fs, UInt32(raw.count), raw.baseAddress!, [])
        }
        if parseRC != noErr { onLog?("ADTS 解析返回 \(parseRC)，丢这一帧"); parsed.packets.removeAll(); return [] }
        if converter == nil, parsed.format.mFormatID != 0 { makeConverter() }
        guard let conv = converter else { parsed.packets.removeAll(); return [] }
        var pcm: [Float] = []
        while !parsed.packets.isEmpty {
            pcm += decodePacket(parsed.packets.removeFirst(), conv)
        }
        return pcm
    }

    /// 按解析器给的 ASBD 和 cookie 建 converter，输出交错 Float32（拆声道是 emit 里对着播放格式做的）。
    private func makeConverter() {
        var aacIn = parsed.format
        var pcmOut = AudioStreamBasicDescription(
            mSampleRate: aacIn.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * UInt32(codec.channels), mFramesPerPacket: 1,
            mBytesPerFrame: 4 * UInt32(codec.channels),
            mChannelsPerFrame: UInt32(codec.channels), mBitsPerChannel: 32, mReserved: 0)
        var conv: AudioConverterRef?
        let rc = AudioConverterNew(&aacIn, &pcmOut, &conv)
        guard rc == noErr, let conv else { fail("AudioConverter 建不起来（\(rc)）"); return }
        if var cookie = parsed.cookie {
            let n = cookie.count
            let cookieRC = cookie.withUnsafeMutableBytes {
                AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32(n), $0.baseAddress!)
            }
            if cookieRC != noErr { onLog?("magic cookie 设置返回 \(cookieRC)（继续）") }
        }
        converter = conv
    }

    /// 输入回调交完唯一一包后回这个：「暂时没货」，converter 停下来但不当流结束。
    private static let noMoreInput: OSStatus = 0x6d6f7265   // 'more'

    /// 一包 → 交错 Float32。一次只要 1024 帧：请求两帧的量却只喂一包时 converter 会一直回 0 帧。
    private func decodePacket(_ packet: [UInt8], _ conv: AudioConverterRef) -> [Float] {
        // 字节和包描述都放在 Box 自己管的堆内存里：回调交出去的指针在 FillComplexBuffer 返回前都要有效
        final class Box {
            let bytes: UnsafeMutableRawPointer
            let count: Int
            let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            var consumed = false
            init(_ d: [UInt8]) {
                count = d.count
                bytes = .allocate(byteCount: max(count, 1), alignment: 16)
                d.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: count) }
                desc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                            mDataByteSize: UInt32(count))
            }
            deinit { bytes.deallocate(); desc.deallocate() }
        }
        let box = Box(packet)
        let proc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, ioDesc, ctx in
            let me = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
            if me.consumed { ioPackets.pointee = 0; return CarPlayAudioPlayer.noMoreInput }
            me.consumed = true
            ioPackets.pointee = 1
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = 0
            ioData.pointee.mBuffers.mData = me.bytes
            ioData.pointee.mBuffers.mDataByteSize = UInt32(me.count)
            ioDesc?.pointee = me.desc
            return noErr
        }
        var frames: UInt32 = 1024
        var out = [Float](repeating: 0, count: 1024 * codec.channels)
        let rc = out.withUnsafeMutableBytes { raw -> OSStatus in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(codec.channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(conv, proc, Unmanaged.passUnretained(box).toOpaque(),
                                                   &frames, &abl, nil)
        }
        if rc != noErr, rc != Self.noMoreInput {
            decodeFailures += 1
            onLog?("AAC 解码失败（\(rc)），丢这一帧（第 \(decodeFailures) 次）")
            if decodeFailures >= 3 {
                // 连续坏帧/解碼器卡住：重建 converter，下一帧重新来；不要一路静音到会话结束
                if let c = converter { AudioConverterDispose(c) }
                converter = nil
                parsed.packets.removeAll()
                decodeFailures = 0
                onLog?("AAC 解码器连续失败，已重建")
            }
            return []
        }
        decodeFailures = 0
        return Array(out.prefix(Int(frames) * codec.channels))
    }

    /// CarPlay 的大端 s16 → Float32（交错）。
    private func pcmToFloat(_ data: Data) -> [Float] {
        let b = [UInt8](data)
        var out = [Float]()
        out.reserveCapacity(b.count / 2)
        var i = 0
        while i + 1 < b.count {
            let v = Int16(bitPattern: UInt16(b[i]) << 8 | UInt16(b[i + 1]))
            out.append(Float(v) / 32768)
            i += 2
        }
        return out
    }

    private func fail(_ why: String) {
        lock.lock()
        guard !failed else { lock.unlock(); return }
        failed = true
        lock.unlock()
        let line = "[homeplay-audio] \(why)，这一路只收不解"
        if let onLog { onLog(line) } else { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }
}

// MARK: - 一路音频流的接收（两个 UDP 口 + 解密 + 丢给播放器）

final class CarPlayAudioStream {
    struct Origin { let firstSample: UInt32; let atNs: UInt64 }

    let type: Int
    let connectionID: NSNumber?
    let latencyMs: Int
    let sampleRate: Int
    let channels: Int
    private(set) var origin: Origin?
    private let queue: DispatchQueue
    private let decryptor: AudioStreamDecryptor
    private let player: CarPlayAudioPlayer?
    /// 手機要麥克風時（type 100 的 SETUP 帶 dataPort）由會話建立；流關閉時一起停
    private let mic: MicUplink?
    private let data: UDPSocket
    private let control: UDPSocket
    private var packets = 0, decrypted = 0, rejected = 0
    private var dumped = 0
    var onLog: ((String) -> Void)?

    var dataPort: UInt16 { data.port }
    var controlPort: UInt16 { control.port }

    init(type: Int, connectionID: NSNumber?, key: Data, codec: CarPlayAudioPlayer.Codec,
         latencyMs: Int, canPlay: Bool, mic: MicUplink? = nil) throws {
        self.type = type; self.connectionID = connectionID
        self.mic = mic
        self.latencyMs = latencyMs; self.sampleRate = codec.rate; self.channels = codec.channels
        queue = DispatchQueue(label: "session.audio.\(type)")
        decryptor = AudioStreamDecryptor(key: key)
        player = canPlay ? CarPlayAudioPlayer(codec: codec) : nil
        data = try UDPSocket(queue: queue, bufferBytes: 4096)
        control = try UDPSocket(queue: queue)
        data.onDatagram = { [weak self] d, _, _ in self?.ingest(d) }
        // control 口只收不解析（RTCP/保活，照 MacPlay 直接排掉）
        player?.onLog = { [weak self] s in self?.onLog?(s) }
        if let mic, mic.voiceProcessing {
            player?.renderSink = { [weak mic] buf in mic?.playDownlink(buf) ?? false }
        }
    }

    private func ingest(_ d: Data) {
        packets += 1
        guard let (sample, payload) = decryptor.push([UInt8](d)) else {
            rejected += 1
            if rejected == 1 || rejected % 500 == 0 { onLog?("音频包校验失败 ×\(rejected)（type \(type)）") }
            return
        }
        decrypted += 1
        if origin == nil {
            origin = Origin(firstSample: sample, atNs: DispatchTime.now().uptimeNanoseconds)
            if player != nil { onLog?("音频开始（\(sampleRate) Hz ×\(channels)，首采样 \(sample)）") }
            else { onLog?("音频开始（type \(type)，此格式暂不出声）") }
        }
        if ProcessInfo.processInfo.environment["HOMEPLAY_AUDIO_DUMP"] != nil, dumped < 50 {
            dumped += 1
            if dumped == 1 { FileManager.default.createFile(atPath: "/tmp/phone_au.bin", contents: nil) }
            var hdr = UInt32(payload.count).littleEndian
            let h = withUnsafeBytes(of: &hdr) { Data($0) }
            if let fh = FileHandle(forWritingAtPath: "/tmp/phone_au.bin") {
                fh.seekToEndOfFile(); fh.write(h); fh.write(Data(payload)); fh.closeFile()
            }
        }
        player?.enqueue(payload: Data(payload))
        if decrypted % 2000 == 0 {
            onLog?("音频心跳：收到 \(packets)、解开 \(decrypted)（type \(type)，\(sampleRate) Hz）｜\(player?.snapshot ?? "无播放器")")
        }
    }

    /// 導航／Siri 插話時壓低媒體流（只有 102 會被呼叫）
    func duck(_ volume: Float, over seconds: Double) { player?.ramp(to: volume, over: seconds) }

    func close() {
        mic?.stop()
        data.onDatagram = nil
        data.close(); control.close()
        player?.stop()
    }
}

/// SETUP 请求里的 audioFormat 位 → 用什么解码。无线媒体是 AAC-LC（0x400000=44.1k / 0x800000=48k 立体声）；
/// Opus 是导航/ Siri 的低延迟单声道（位 0x10000000..0x40000000），PCM 只出现在有线。
/// 返回 canPlay=false 表示这路先只占位不解（Opus 还没接解码器）。
package func audioCodec(fromFormat fmt: Int) -> (codec: CarPlayAudioPlayer.Codec, canPlay: Bool) {
    let pcmTable: [Int: (Int, Int)] = [
        0x4: (8000, 1), 0x8: (8000, 2), 0x10: (16000, 1), 0x20: (16000, 2),
        0x40: (24000, 1), 0x80: (24000, 2), 0x100: (32000, 1), 0x200: (32000, 2),
        0x400: (44100, 1), 0x800: (44100, 2), 0x4000: (48000, 1), 0x8000: (48000, 2)]
    if fmt & 0x40000000 != 0 { return (.opus(rate: 48000, channels: 1), true) }
    if fmt & 0x20000000 != 0 { return (.opus(rate: 24000, channels: 1), true) }
    if fmt & 0x10000000 != 0 { return (.opus(rate: 16000, channels: 1), true) }
    if fmt & 0x800000 != 0 { return (.aacLc(rate: 48000, channels: 2), true) }
    if fmt & 0x400000 != 0 { return (.aacLc(rate: 44100, channels: 2), true) }
    if let (rate, channels) = pcmTable[fmt] { return (.pcmBe(rate: rate, channels: channels), true) }
    return (.aacLc(rate: 44100, channels: 2), true)   // 手机没写就按最常见的猜
}
