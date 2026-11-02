// CarPlay 麥克風上行：抓 Mac 輸入裝置 → 重採樣到協商的 Opus 率 → Opus 編碼
// → ChaCha20-Poly1305 封裝 → UDP 發到手機在 SETUP 裡給的 mic dataPort。
// 封包格式照 MacPlay `livi-gst-video/rust/mic/src/lib.rs`：
//   12B RTP 頭（0x80、PT=流類型、seq/timestamp 大端、SSRC=0）
//   + 密文 + 16B tag + 8B 小端 nonce 計數；AAD = header[4..12]；nonce = 4 個零 + 8B 小端計數。
// 啟動時機：手機為 type 100（MainAudio）SETUP 出 dataPort＝它要麥克風（Siri/電話）。
// 回音消除：100/telephony 與 100/speechRecognition 開 AVAudioEngine 的語音處理（VPIO：回音消除＋降噪）。
// VPIO 的回音參考是同一台引擎的輸出，所以這一路的下行（對方說話／Siri 回話）改從這台引擎放
//（`playDownlink`）；媒體 102 不在參考裡，但通話與 Siri 期間它已被 duckAudio 壓低。
// 預設輸入與預設輸出不是同一組可配對的裝置時（外接螢幕、藍牙、AirPlay），VPIO 可能起不來；
// 這時自動退到 SpeexDSP 軟體 AEC，再不行才用原始麥克風（語音仍可上行），見 `beginCapture`。
import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation
import Network

package final class MicUplink {
    /// 上行负载：无线低延迟流协商到 Opus 时编 Opus；手机给的是 PCM（如 fmt=0x40 的
    /// Siri 流）时直接发 16-bit 大端 PCM，采样率/声道跟 SETUP 一致。
    package enum WireCodec { case opus, pcm }

    private var wireCodec: WireCodec
    private var key: SymmetricKey
    private var payloadType: UInt8
    private var sampleRate: Double
    private var channels: Int
    private var frameMs: Int
    private var bitrate: Int
    private var host: String
    private var port: UInt16
    /// 會話級預熱：CarPlay 一 live 就開 VPIO 引擎並持續緩衝最近幾秒，
    /// Siri/F5 的 SETUP 到了直接 configure + 補發，不用等引擎啟動。
    private var prewarmMode = false
    private var sendEnabled = true
    private var preRoll: [Float] = []
    private var preRollRate: Double = 48000
    private var preRollFlushed = false
    private let preRollMaxSeconds = 3.0
    /// 上行數位增益。Studio Display／外接螢幕的麥克風距離人較遠，實測說話 RMS 只有
    /// -30…-54 dBFS（遠場），Siri 很容易聽不到；預設 +18 dB 抬到 -12…-36 dBFS，再由軟限幅器
    /// 擋住過大的峰值。`HOMEPLAY_MIC_GAIN_DB` 可改（0＝不增益）。
    private let micGain: Float
    /// `HOMEPLAY_MIC_DUMP=1`：把送出的明文 Opus 包（4-byte LE 長度前綴）寫到
    /// /tmp/homeplay-mic.opus，供離線解碼確認「手機收到的到底是不是人聲」。
    private let dumpMic: Bool
    private var dumpHandle: FileHandle?
    /// 這一路上行是否需要回音消除（電話／Siri）。首選 Apple 原生 VPIO；
    /// 起不來時用 SpeexDSP 的參考訊號 AEC 補上（見 `beginCapture`）。
    package let voiceProcessing: Bool
    private let aec: EchoCanceller?
    private var aecInputResampler: AVAudioConverter?
    private var aecInputRate: Double = 0
    private var aecOutputResampler: AVAudioConverter?
    private var aecOutputRate: Double = 0
    private var aecRefResampler: AVAudioConverter?
    private var aecRefRate: Double = 0
    private var aecMicPending: [Float] = []
    private var aecRefPending: [Float] = []
    private var downlinkFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "session.mic.uplink")
    package var onLog: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var resampler: AVAudioConverter?
    private var resamplerInputRate: Double = 0
    private var opusEncoder: OpusEncoder?
    private var pending: [Float] = []
    private var seq: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var nonceCount: UInt64 = 0
    private var packetsSent = 0
    // 麥克風電平（每 50 幀≈1 秒記一次）：用來分辨「上行有包但其實是靜音」和
    // 「手機收到了卻不回應」。正常說話 RMS 約 -35…-12 dBFS；靜音在 -70 以下。
    private var levelChunks = 0
    private var levelSamples = 0
    private var levelSquares: Double = 0
    private var levelPeak: Float = 0
    private var started = false
    private var stopped = false
    private var conn: NWConnection?
    /// 下行放音節點（語音處理開著且引擎已起時才有）；播放執行緒與 queue 都會碰，用鎖
    private let echoLock = NSLock()
    private var echoNode: AVAudioPlayerNode?
    /// 下行 DynamicsProcessor 的 audio unit；通話音量設定變了直接改它的 OverallGain。
    private var dynamicsUnit: AudioUnit?
    private var callGainObserver: NSObjectProtocol?
    private var engineConfigObserver: NSObjectProtocol?
    private var restarting = false
    /// 已排進 echoNode、還沒播完的下行秒數；TEARDOWN 時要用它等 TTS 尾巴。
    private var downlinkScheduledSeconds = 0.0
    /// VPIO 是否真的起來了；起來時麥克風已由 Apple 做回聲消除，不再走 SpeexDSP。
    private var vpioActive = false

    package init(codec: WireCodec = .opus, key: Data, payloadType: Int, sampleRate: Int,
                 channels: Int = 1, frameMs: Int, bitrate: Int, host: String, port: UInt16,
                 voiceProcessing: Bool = false, downlinkRate: Int = 0, downlinkChannels: Int = 1) {
        self.wireCodec = codec
        self.key = SymmetricKey(data: key)
        self.payloadType = UInt8(clamping: payloadType) & 0x7f
        self.sampleRate = Double(sampleRate)
        self.channels = max(1, channels)
        self.frameMs = max(5, frameMs)
        self.bitrate = bitrate
        self.host = host
        self.port = port
        let gainDb = max(0, min(36, Double(ProcessInfo.processInfo.environment["HOMEPLAY_MIC_GAIN_DB"] ?? "18") ?? 18))
        self.micGain = Float(pow(10, gainDb / 20))
        self.dumpMic = ProcessInfo.processInfo.environment["HOMEPLAY_MIC_DUMP"] == "1"
        self.voiceProcessing = voiceProcessing
        self.aec = voiceProcessing ? EchoCanceller(sampleRate: 16000, frameMs: 20, filterMs: 300) : nil
        self.downlinkFormat = voiceProcessing && downlinkRate > 0
            ? AVAudioFormat(standardFormatWithSampleRate: Double(downlinkRate),
                            channels: AVAudioChannelCount(max(1, downlinkChannels)))
            : nil
        callGainObserver = NotificationCenter.default.addObserver(
            forName: CallAudioSettings.changed, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.applyCallGain() }
        }
    }

    /// 會話級預熱麥克風：CarPlay live 時就開 VPIO，SETUP 到了只換上行金鑰/編碼器。
    package convenience init(prewarm: Bool, voiceProcessing: Bool = true) {
        self.init(codec: .opus, key: Data(count: 32), payloadType: 100, sampleRate: 24000,
                  channels: 1, frameMs: 20, bitrate: 48000, host: "0.0.0.0", port: 0,
                  voiceProcessing: voiceProcessing, downlinkRate: 48000, downlinkChannels: 1)
        self.prewarmMode = prewarm
        self.sendEnabled = false
        self.preRollRate = 48000
    }

    /// 會話級預熱引擎：stream 關閉時只停上行，不關引擎/播放器。
    package var isPrewarm: Bool { prewarmMode }
    /// 下行是不是真的從這台 VPIO 引擎的 player 出來；false 時 CarPlayAudioPlayer 才是出聲者。
    package var downlinkRendersThroughMic: Bool { vpioActive }

    /// 哪些 100 流要開語音處理：電話與 Siri（語音辨識）。`HOMEPLAY_NO_AEC=1` 關掉，對照用。
    package static func wantsVoiceProcessing(audioType: String?,
                                             environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["HOMEPLAY_NO_AEC"] != "1" else { return false }
        return audioType == "telephony" || audioType == "speechRecognition"
    }

    private var codecLabel: String { wireCodec == .opus ? "Opus" : "PCM" }

    package var description: String {
        let gain = micGain > 1 ? "，增益 +\(Int((20 * log10(Double(micGain))).rounded())) dB" : ""
        return "\(codecLabel) \(Int(sampleRate)) Hz → \(host):\(port)\(voiceProcessing ? "，回音消除（VPIO，失败退 SpeexDSP）" : "")\(gain)"
    }

    /// 把一段下行 PCM 交給語音處理引擎放（當回音參考）。引擎還沒起／沒開語音處理就回 false，
    /// 呼叫方照舊用自己的引擎放。格式必須是 init 給的下行率與聲道。
    package func playDownlink(_ buffer: AVAudioPCMBuffer) -> Bool {
        echoLock.lock(); let node = echoNode; echoLock.unlock()
        guard let node, !stopped, buffer.format == downlinkFormat else { return false }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        echoLock.lock(); downlinkScheduledSeconds += duration; echoLock.unlock()
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.echoLock.lock()
            self.downlinkScheduledSeconds = max(0, self.downlinkScheduledSeconds - duration)
            self.echoLock.unlock()
        }
        if !node.isPlaying { node.play() }
        return true
    }

    /// 還沒播完的下行秒數（VPIO 引擎裡的 player node）。
    package var downlinkQueuedSeconds: Double {
        echoLock.lock(); defer { echoLock.unlock() }
        return downlinkScheduledSeconds
    }

    /// TEARDOWN 時照系統 Siri 的行為：先停上行，等下行 TTS 尾巴播完再關引擎。
    package func stopAfterDrain(_ seconds: Double) {
        let delay = min(max(0, seconds), 3)
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.engine?.inputNode.removeTap(onBus: 0)   // 不再送 mic，但保留引擎/player
            if delay <= 0.02 { self.stop(); return }
            self.queue.asyncAfter(deadline: .now() + delay) { self.stop() }
        }
    }

    package func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    /// Siri 按鍵按下到 SETUP 之間抓到的預卷；在 start() 之後排進同一條佇列，
    /// 所以 UDP/encoder 已建好才送出。這段是原始麥克風音訊，跳過 AEC（Siri 剛開始聽）。
    package func prependAudio(_ samples: [Float], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self, !self.stopped, !samples.isEmpty else { return }
            self.resampleAndEncode(samples, inputRate: sampleRate)
        }
    }

    /// 會話級預熱麥克風收到 SETUP：換金鑰/埠/編碼率，補發最近 1 秒預卷。
    package func configure(key: Data, payloadType: Int, host: String, port: UInt16,
                           wireCodec: WireCodec, sampleRate: Int, channels: Int,
                           frameMs: Int, bitrate: Int) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.wireCodec = wireCodec
            self.key = SymmetricKey(data: key)
            self.payloadType = UInt8(clamping: payloadType) & 0x7f
            self.sampleRate = Double(sampleRate)
            self.channels = max(1, channels)
            self.frameMs = max(5, frameMs)
            self.bitrate = bitrate
            self.host = host
            self.port = port
            self.opusEncoder = wireCodec == .opus
                ? OpusEncoder(sampleRate: sampleRate, channels: 1,
                              bitrate: bitrate, frameMs: max(5, frameMs))
                : nil
            self.resampler = nil; self.resamplerInputRate = 0
            self.aecInputResampler = nil; self.aecInputRate = 0
            self.aecOutputResampler = nil; self.aecOutputRate = 0
            self.aecRefResampler = nil; self.aecRefRate = 0
            self.pending.removeAll(); self.aecMicPending.removeAll(); self.aecRefPending.removeAll()
            self.seq = 0; self.timestamp = 0; self.nonceCount = 0; self.packetsSent = 0
            self.conn?.cancel(); self.conn = nil
            let c = NWConnection(host: NWEndpoint.Host(host),
                                 port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            c.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { self?.onLog?("麦克风上行 UDP 失败：\(e)") }
            }
            c.start(queue: self.queue)
            self.conn = c
            // 先不送：手機的 speechRecognition 通常要等第一個下行包（提示音）
            // 才真的開始聽；太早送預卷會被丟掉。收到第一個下行包時再 flush。
            // 若 500ms 內沒有下行（純語音辨識流），照 DiPlay 的 SILENT_START 兜底。
            self.sendEnabled = false
            self.preRollFlushed = false
            self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.flushPreRollLocked()
            }
        }
    }

    /// 收到第一包下行（Siri 提示音）時，把手機開始聽之前的預卷補發出去。
    package func flushPreRoll() {
        queue.async { [weak self] in self?.flushPreRollLocked() }
    }

    private func flushPreRollLocked() {
        guard !stopped, !preRollFlushed else { return }
        preRollFlushed = true
        sendEnabled = true
        let maxSamples = Int(preRollRate)
        let tail = preRoll.count > maxSamples ? Array(preRoll.suffix(maxSamples)) : preRoll
        preRoll.removeAll()
        guard !tail.isEmpty else { return }
        resampleAndEncode(tail, inputRate: preRollRate)
        onLog?("Siri 预卷：SETUP 前的 \(String(format: "%.2f", Double(tail.count) / preRollRate)) 秒已补发")
    }

    /// stream 結束：停上行，但保留預熱引擎/VPIO/播放器，下一條 Siri/電話直接再用。
    package func stopUplink() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sendEnabled = false
            self.conn?.cancel(); self.conn = nil
            self.opusEncoder = nil
            self.pending.removeAll(); self.aecMicPending.removeAll(); self.aecRefPending.removeAll()
            self.preRoll.removeAll()
        }
    }

    package func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.echoLock.lock(); self.echoNode = nil; self.downlinkScheduledSeconds = 0; self.echoLock.unlock()
            if let e = self.engine {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
            }
            self.engine = nil
            self.vpioActive = false
            if let o = self.callGainObserver { NotificationCenter.default.removeObserver(o) }
            self.callGainObserver = nil
            if let o = self.engineConfigObserver { NotificationCenter.default.removeObserver(o) }
            self.engineConfigObserver = nil
            self.dynamicsUnit = nil
            self.opusEncoder = nil
            self.dumpHandle?.closeFile()
            self.dumpHandle = nil
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
        if !prewarmMode {
            if wireCodec == .opus {
                opusEncoder = OpusEncoder(sampleRate: Int(sampleRate), channels: 1,
                                          bitrate: bitrate, frameMs: frameMs)
                guard opusEncoder != nil else {
                    onLog?("libopus 编码器建不起来（\(Int(sampleRate)) Hz）")
                    return
                }
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
        }

        // 先試 Apple 原生 VPIO（照 WWDC19/社群的最佳順序：播放圖先接好、輸出立體聲、
        // input/output 都開 voice processing）。起不來才退 SpeexDSP 軟體 AEC。
        if voiceProcessing, startAudioEngine(voiceProcessing: true) { return }
        if voiceProcessing {
            if aec != nil {
                onLog?("VPIO 起不来，改用 SpeexDSP 软件回声消除（16 kHz 参考信号）")
            } else {
                onLog?("VPIO 与 SpeexDSP 都起不来，麦克风照常上行（可能有回音）")
            }
        }
        if !startAudioEngine(voiceProcessing: false), !stopped {
            onLog?("麦克风引擎起不来")
        }
    }

    /// 裝置切換（Studio Display/藍牙/AirPlay）時像 SiriUIAudioDeviceManager 一樣重建麥克風引擎。
    /// 上行金鑰、encoder、預卷都保留；只換 AVAudioEngine/VPIO/player。
    private func restartAudioEngineOnQueue() {
        guard !stopped, !restarting, engine != nil else { return }
        restarting = true
        if let o = engineConfigObserver { NotificationCenter.default.removeObserver(o) }
        engineConfigObserver = nil
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        vpioActive = false
        echoLock.lock(); echoNode = nil; echoLock.unlock()
        onLog?("音频设备变化，重建麦克风引擎")
        var ok = false
        if voiceProcessing { ok = startAudioEngine(voiceProcessing: true) }
        if !ok { ok = startAudioEngine(voiceProcessing: false) }
        if !ok { onLog?("重建后麦克风引擎仍起不来") }
        restarting = false
    }

    /// Apple 原生的 DynamicsProcessor：通話下行用（壓縮 + 6 dB 總增益），
    /// 讓對方聲音更清楚。對應 kAudioUnitSubType_DynamicsProcessor（'dcmp'）。
    private static func makeDownlinkDynamics() -> AVAudioUnitEffect? {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        let unit = effect.audioUnit
        let callGain = CallAudioSettings.gainDb
        // 通話偏移先 +6 dB（車機常見幅度）；後面再接 PeakLimiter 擋峰值，
        // 避免 Siri/TTS 的瞬態被 +12 dB 直接推到削波（破音）。
        _ = AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -20, 0)
        _ = AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
        _ = AudioUnitSetParameter(unit, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 1, 0)
        _ = AudioUnitSetParameter(unit, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, -80, 0)
        _ = AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        _ = AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.08, 0)
        _ = AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, callGain, 0)
        return effect
    }

    /// Apple 原生的 PeakLimiter：接在 DynamicsProcessor 之後，把峰值壓在 0 dBFS 以下，
    /// 避免通話偏移把 Siri/TTS 推到破音。PreGain -1 dB 留一點 inter-sample 餘量。
    private static func makeDownlinkLimiter() -> AVAudioUnitEffect? {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        let unit = effect.audioUnit
        _ = AudioUnitSetParameter(unit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        _ = AudioUnitSetParameter(unit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        _ = AudioUnitSetParameter(unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, -1.0, 0)
        return effect
    }

    private func applyCallGain() {
        guard let unit = dynamicsUnit else { return }
        _ = AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain,
                                  kAudioUnitScope_Global, 0, CallAudioSettings.gainDb, 0)
    }

    /// 起一台抓麥克風的引擎；`voiceProcessing` 為 true 時走 Apple 的原生 VPIO。
    /// 回 false＝這台引擎沒起來，呼叫方可以退到 SpeexDSP 或原始麥克風。
    ///
    /// 順序照 Apple WWDC19 / 社群最佳實踐：**先把播放圖接好**
    ///（player → mainMixer → outputNode 立體聲），再開 input/output 的 voice processing。
    /// 之前反過來做（先開 VPIO、後接 player），VPIO 的參考訊號湊不出來，就是 -10875 的來源。
    private func startAudioEngine(voiceProcessing requested: Bool) -> Bool {
        guard !stopped, engine == nil else { return engine != nil }
        let e = AVAudioEngine()
        let input = e.inputNode
        let output = e.outputNode
        var node: AVAudioPlayerNode?

        if requested {
            guard let fmt = downlinkFormat else { return false }
            let n = AVAudioPlayerNode()
            e.attach(n)
            // 先把下行播放接進 mixer；VPIO 的回聲參考就是這一路。
            // 中間加 Apple 原生的 DynamicsProcessor（FaceTime 這類通話 App 的做法）：
            // 壓縮動態範圍 + OverallGain +6 dB，讓對方的聲音更清楚、不會忽大忽小。
            if let dynamics = Self.makeDownlinkDynamics() {
                e.attach(dynamics)
                e.connect(n, to: dynamics, format: fmt)
                dynamicsUnit = dynamics.audioUnit
                applyCallGain()
                if let limiter = Self.makeDownlinkLimiter() {
                    e.attach(limiter)
                    e.connect(dynamics, to: limiter, format: fmt)
                    e.connect(limiter, to: e.mainMixerNode, format: fmt)
                    onLog?("下行已接 DynamicsProcessor +6 dB → PeakLimiter（防破音）")
                } else {
                    e.connect(dynamics, to: e.mainMixerNode, format: fmt)
                    onLog?("下行已接 DynamicsProcessor +6 dB（PeakLimiter 不可用）")
                }
            } else {
                e.connect(n, to: e.mainMixerNode, format: fmt)
            }
            // VPIO 的輸出參考要求立體聲；Studio Display 的裝置是 8 聲道，
            // 這裡明確把 mixer→output 的 client 格式固定成 2 聲道。
            guard let stereo = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 2) else {
                return false
            }
            e.connect(e.mainMixerNode, to: output, format: stereo)
            node = n
            // 注意：這裡不能先 e.prepare()。prepare 會把 audio unit 初始化，
            // 之後 setVoiceProcessingEnabled 會回 -10849（kAudioUnitErr_Initialized）。
            do {
                try input.setVoiceProcessingEnabled(true)
                // Apple 的 VPIO AGC：和 FaceTime 一樣讓麥克風電平自動對齊，
                // 不需要我們再用固定 +12 dB 去猜。
                if let unit = input.audioUnit {
                    var agc: UInt32 = 1
                    _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                             kAudioUnitScope_Global, 0, &agc,
                                             UInt32(MemoryLayout<UInt32>.size))
                }
                // WWDC19：回聲消除需要 input 與 output 都在 voice processing 模式。
                // 少數 macOS 版本 output 這步會丟錯；input 已開就繼續試。
                do { try output.setVoiceProcessingEnabled(true) }
                catch { onLog?("output voice processing 开不起来（\(error)），只开 input") }
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                onLog?("VPIO 开不起来（\(error)），改用 SpeexDSP")
                return false
            }
        }

        let inFormat = requested ? input.outputFormat(forBus: 0) : input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            onLog?("没有可用的麦克风输入设备")
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            guard let self, !self.stopped else { return }
            guard let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength), channels = Int(buf.format.channelCount)
            guard n > 0, channels > 0 else { return }
            var mono = [Float](repeating: 0, count: n)
            // 語音處理的輸出在第 0 聲道（有些機型回報多聲道，其餘是空的），不能平均
            if channels == 1 || requested {
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
            self.queue.async {
                if self.prewarmMode && !self.sendEnabled {
                    self.appendPreRoll(mono, rate: rate)
                } else {
                    self.processMic(mono, inputRate: rate)
                }
            }
        }
        e.prepare()
        do {
            try e.start()
            engine = e
            if let o = engineConfigObserver { NotificationCenter.default.removeObserver(o) }
            engineConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: e, queue: nil
            ) { [weak self] note in
                guard let self else { return }
                if let changed = note.object as? AVAudioEngine, changed !== self.engine { return }
                self.queue.async { self.restartAudioEngineOnQueue() }
            }
            if requested, let node {
                node.play()
                echoLock.lock(); echoNode = node; echoLock.unlock()
                vpioActive = true
            }
            let aec = requested ? "，VPIO 回音消除开（立体声参考）" : ""
            onLog?("麦克风上行已启动（\(Int(inFormat.sampleRate)) Hz → \(codecLabel) \(Int(sampleRate)) Hz，\(host):\(port)\(aec)）")
            return true
        } catch {
            input.removeTap(onBus: 0)
            e.stop()
            echoLock.lock(); echoNode = nil; echoLock.unlock()
            vpioActive = false
            onLog?("麦克风引擎起不来（\(requested ? "VPIO \(Int(inFormat.sampleRate)) Hz × \(inFormat.channelCount)" : "原始麦克风")）：\(error)")
            return false
        }
    }

    // MARK: 重采样与编码（串行队列）

    /// 預熱期間把 VPIO 處理後的麥克風存進環形預卷，SETUP 到了補發最近 1 秒。
    private func appendPreRoll(_ mono: [Float], rate: Double) {
        preRollRate = rate
        preRoll.append(contentsOf: mono)
        let limit = Int(rate * preRollMaxSeconds)
        if preRoll.count > limit { preRoll.removeFirst(preRoll.count - limit) }
    }

    /// 麥克風路徑：有 AEC 時先降到 16k 做回聲消除，再升到 Opus 率。
    private func processMic(_ mono: [Float], inputRate: Double) {
        guard !stopped, !mono.isEmpty else { return }
        guard let aec, !vpioActive else { resampleAndEncode(mono, inputRate: inputRate); return }
        let pcm16 = resample(mono, from: inputRate, to: 16000,
                             converter: &aecInputResampler, lastRate: &aecInputRate)
        guard !pcm16.isEmpty else { return }
        aecMicPending.append(contentsOf: pcm16)
        let frameSize = aec.frameSize
        while aecMicPending.count >= frameSize {
            let frame = Array(aecMicPending.prefix(frameSize))
            aecMicPending.removeFirst(frameSize)
            let rec = frame.map { Int16((max(-1, min(1, $0)) * 32767).rounded()) }
            let clean = aec.capture(rec)
            let floats = clean.map { Float($0) / 32768 }
            let opus = resample(floats, from: 16000, to: sampleRate,
                                converter: &aecOutputResampler, lastRate: &aecOutputRate)
            pending.append(contentsOf: opus)
            encodePending()
        }
    }

    /// 把 `pending` 裡的 Opus 率樣本切成 20ms 幀送出去。
    private func encodePending() {
        let frameSamples = max(1, Int(sampleRate * Double(frameMs) / 1000))
        while pending.count >= frameSamples {
            let chunk = Array(pending.prefix(frameSamples))
            pending.removeFirst(frameSamples)
            encodeAndSend(chunk)
        }
    }

    /// 下行（type 100）解出的 PCM 當回聲參考。由播放器在排播前叫，切到麥克風佇列處理。
    package func feedReference(_ pcm: [Float], sampleRate refRate: Double) {
        guard aec != nil, !vpioActive, !stopped else { return }
        queue.async { [weak self] in
            guard let self, let aec = self.aec, !self.vpioActive, !self.stopped, self.engine != nil else { return }
            let pcm16 = self.resample(pcm, from: refRate, to: 16000,
                                      converter: &self.aecRefResampler, lastRate: &self.aecRefRate)
            guard !pcm16.isEmpty else { return }
            self.aecRefPending.append(contentsOf: pcm16)
            let frameSize = aec.frameSize
            while self.aecRefPending.count >= frameSize {
                let frame = Array(self.aecRefPending.prefix(frameSize))
                self.aecRefPending.removeFirst(frameSize)
                let ref = frame.map { Int16((max(-1, min(1, $0)) * 32767).rounded()) }
                aec.playback(ref)
            }
        }
    }

    /// 可重複使用的單聲道浮點重採樣器；`lastRate` 記住上次的輸入率。
    private func resample(_ input: [Float], from: Double, to: Double,
                          converter: inout AVAudioConverter?, lastRate: inout Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        if abs(from - to) < 0.5 { return input }
        if converter == nil || abs(lastRate - from) > 0.5 {
            guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from,
                                            channels: 1, interleaved: false),
                  let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to,
                                             channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return [] }
            converter = conv
            lastRate = from
        }
        guard let conv = converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: conv.inputFormat,
                                           frameCapacity: AVAudioFrameCount(input.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: input.count)
        }
        let capacity = AVAudioFrameCount(Double(input.count) * to / from) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, outBuf.frameLength > 0, let pcm = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: pcm, count: Int(outBuf.frameLength)))
    }

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

    /// 每 50 幀（20ms 幀＝約 1 秒）把這段的 RMS／峰值寫進日誌。
    /// 有包但全是靜音時，手機端的 Siri/對方當然聽不到；這行就是分辨這兩種情況用的。
    private func recordLevel(_ samples: [Float], gain: Float) {
        guard !samples.isEmpty else { return }
        for s in samples {
            let v = Double(s)
            levelSquares += v * v
            let a = abs(s)
            if a > levelPeak { levelPeak = a }
        }
        levelSamples += samples.count
        levelChunks += 1
        guard levelChunks % 50 == 0 else { return }
        let rms = (levelSquares / Double(max(1, levelSamples))).squareRoot()
        let rmsDb = 20 * log10(max(rms, 1e-7))
        let peakDb = 20 * log10(max(Double(levelPeak), 1e-7))
        let gainDb = gain > 0 ? 20 * log10(Double(gain)) : 0
        onLog?("麦克风电平：RMS \(String(format: "%.1f", rmsDb)) dBFS，峰值 \(String(format: "%.1f", peakDb)) dBFS（增益 +\(String(format: "%.0f", gainDb)) dB → 约 \(String(format: "%.1f", rmsDb + Double(gainDb))) dBFS）")
        levelChunks = 0
        levelSamples = 0
        levelSquares = 0
        levelPeak = 0
    }

    /// 超過 0.9 之後平滑壓縮到 1.0，避免 +18 dB 後的人聲峰值硬削波。
    private static func softLimit(_ v: Float) -> Float {
        let threshold: Float = 0.9
        let a = abs(v)
        guard a > threshold else { return v }
        let sign: Float = v < 0 ? -1 : 1
        let compressed = threshold + (1 - threshold) * Float(tanh(Double((a - threshold) / (1 - threshold))))
        return sign * compressed
    }

    private func encodeAndSend(_ samples: [Float]) {
        // VPIO 的 AGC 在這台 Studio Display 麥克風上實測仍只有 -60 dBFS，
        // Siri 會聽不到、導致 speechRecognition 流被手機反覆拆掉（聲音中斷）。
        // 保留 +12 dB 麥克風補償；AGC 仍在上游，峰值有軟限幅。
        let gain = micGain
        recordLevel(samples, gain: gain)
        let boosted = gain == 1 ? samples : samples.map { Self.softLimit($0 * gain) }
        if wireCodec == .pcm {
            send(Self.pcm16BE(boosted, channels: channels))
            return
        }
        guard let enc = opusEncoder, !stopped else { return }
        let packet = enc.encode(boosted)
        guard !packet.isEmpty else { return }
        send(packet)
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
        if dumpMic {
            if dumpHandle == nil {
                FileManager.default.createFile(atPath: "/tmp/homeplay-mic.opus", contents: nil)
                dumpHandle = FileHandle(forWritingAtPath: "/tmp/homeplay-mic.opus")
            }
            var length = UInt32(opus.count).littleEndian
            dumpHandle?.write(Data(bytes: &length, count: 4))
            dumpHandle?.write(opus)
        }
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
