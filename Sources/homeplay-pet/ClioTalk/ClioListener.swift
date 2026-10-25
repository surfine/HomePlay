// ClioTalk 的耳朵：AVAudioEngine 開麥克風（只在記憶體裡流過，不錄、不存、不送出這台 Mac），
// 一輪一輪交給本機轉寫——macOS 26 起用 SpeechAnalyzer＋SpeechTranscriber（模型沒裝就用 AssetInventory 下載，卡片上顯示進度），
// 更舊的系統退回 SFSpeechRecognizer（能本機就本機）。只有最後的文字會交給引擎；日誌只記時間，不記內容。
// 探測：--cliotalk-speech-probe 印出這台 Mac 支援哪些語系、模型裝了沒（不開麥克風、不下載）。

import AVFoundation
import Foundation
import Speech

// MARK: - 麥克風

/// 一直開著的那段期間（一次對話），每段緩衝都量音量給 VAD；這一輪在轉寫時也交給轉寫器。
/// 還沒開始轉寫時留最近 0.6 秒（開口的第一個字不會掉）；在等模型下載時最多留 15 秒。全在記憶體。
final class ClioMic {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollTime = 0.0
    private var holdAll = false
    /// 主執行緒：每段緩衝的音量（dBFS）與長度（秒）
    var onLevel: ((Float, Double) -> Void)?
    private(set) var running = false
    private(set) var format: AVAudioFormat?

    func start() throws {
        guard !running else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw ClioVoiceError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] b, _ in self?.handle(b) }
        e.prepare()
        do { try e.start() } catch { input.removeTap(onBus: 0); throw error }
        engine = e; format = fmt; running = true
    }

    /// 關掉麥克風（橘點跟著消失）
    func stop() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil; running = false
        lock.lock(); sink = nil; preroll.removeAll(); prerollTime = 0; holdAll = false; lock.unlock()
    }

    /// 這一輪的轉寫器接上：先把留著的那段交出去
    func attach(_ s: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        for b in preroll { s(b) }
        preroll.removeAll(); prerollTime = 0; holdAll = false
        sink = s
    }
    func detach() { lock.lock(); sink = nil; lock.unlock() }
    /// 轉寫器還沒好（在下載模型）：先把聲音都留著
    func hold() { lock.lock(); holdAll = true; lock.unlock() }

    private func handle(_ b: AVAudioPCMBuffer) {
        let db = ClioVAD.level(b)
        let dur = Double(b.frameLength) / b.format.sampleRate
        if let copy = Self.copy(b) {
            lock.lock()
            if let s = sink { s(copy) }
            else {
                preroll.append(copy); prerollTime += dur
                let keep = holdAll ? 15.0 : 0.6
                while prerollTime > keep, let f = preroll.first {
                    prerollTime -= Double(f.frameLength) / f.format.sampleRate
                    preroll.removeFirst()
                }
            }
            lock.unlock()
        }
        DispatchQueue.main.async { [weak self] in self?.onLevel?(db, dur) }
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let n = Int(b.frameLength), ch = Int(b.format.channelCount)
        if let s = b.floatChannelData, let d = c.floatChannelData {
            for i in 0..<(b.format.isInterleaved ? 1 : ch) { d[i].update(from: s[i], count: n * (b.format.isInterleaved ? ch : 1)) }
        } else if let s = b.int16ChannelData, let d = c.int16ChannelData {
            for i in 0..<(b.format.isInterleaved ? 1 : ch) { d[i].update(from: s[i], count: n * (b.format.isInterleaved ? ch : 1)) }
        } else { return nil }
        return c
    }
}

enum ClioVoiceError: Error {
    case noMicrophone, micDenied, unsupported, speechDenied, download(String)

    var message: String {
        switch self {
        case .noMicrophone: return L("clio.voice.noMic", "找不到麦克风，用打字问吧")
        case .micDenied: return L("clio.voice.micDenied", "麦克风没有打开，用打字问吧")
        case .unsupported: return L("clio.voice.unsupported", "这台 Mac 不支持这个语言的语音输入，用打字问吧")
        case .speechDenied: return L("clio.voice.speechDenied", "语音识别没有打开，用打字问吧")
        case .download: return L("clio.voice.downloadFailed", "语音模型下载失败，连上网再试一次")
        }
    }
}

// MARK: - 一輪的轉寫

/// 一輪：餵緩衝（任何執行緒）、收尾或取消；結果都回到主執行緒
protocol ClioTranscribing: AnyObject {
    func append(_ b: AVAudioPCMBuffer)
    func finish()
    func cancel()
}

/// 主執行緒的回呼：已確定的字、還沒確定的字（畫淡一點）
struct ClioTranscriptCallbacks {
    var update: (_ final: String, _ volatile: String) -> Void
    var done: (_ text: String) -> Void
}

/// 用哪一種轉寫（第一次用時決定，之後這次開著的 App 都沿用）
enum ClioSpeechBackend: Equatable {
    case analyzer(String)       // SpeechTranscriber（macOS 26+）
    case dictation(String)      // DictationTranscriber（模型不支援 SpeechTranscriber 的語系）
    case recognizer(String)     // SFSpeechRecognizer
    case none

    var name: String {
        switch self {
        case .analyzer: return "SpeechTranscriber"
        case .dictation: return "DictationTranscriber"
        case .recognizer: return "SFSpeechRecognizer"
        case .none: return "none"
        }
    }

    /// 選轉寫方式；需要下載模型就下載（progress 0…1，主執行緒）。不開麥克風。
    static func prepare(_ locale: Locale, download: Bool, progress: @escaping (Double) -> Void) async throws -> ClioSpeechBackend {
        if #available(macOS 26, *) {
            if SpeechTranscriber.isAvailable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                let m = ClioAnalyzerTurn.transcriber(l)
                if try await ensureAssets([m], locale: l, download: download, progress: progress) { return .analyzer(l.identifier) }
            }
            if let l = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                let m = ClioAnalyzerTurn.dictation(l)
                if try await ensureAssets([m], locale: l, download: download, progress: progress) { return .dictation(l.identifier) }
            }
        }
        // 舊系統：SFSpeechRecognizer（要語音辨識授權；Info.plist 沒寫用途說明時不能問，不然會被系統直接結束）
        guard let r = SFSpeechRecognizer(locale: locale), r.isAvailable else { return .none }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return .none }
        var st = SFSpeechRecognizer.authorizationStatus()
        if st == .notDetermined, download {
            st = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        guard st == .authorized else { throw ClioVoiceError.speechDenied }
        return .recognizer(locale.identifier)
    }

    /// 模型在不在；不在而且允許下載就下載。false＝這個模組不支援。
    @available(macOS 26, *)
    private static func ensureAssets(_ modules: [any SpeechModule], locale: Locale, download: Bool,
                                     progress: @escaping (Double) -> Void) async throws -> Bool {
        let st = await AssetInventory.status(forModules: modules)
        if st == .unsupported { return false }
        if st == .installed { return true }
        guard download else { return true }   // 探測：只回報，不下載
        func install() async throws {
            guard let req = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
            DispatchQueue.main.async { progress(0) }
            let obs = req.progress.observe(\.fractionCompleted) { p, _ in
                let f = p.fractionCompleted
                DispatchQueue.main.async { progress(f) }
            }
            defer { obs.invalidate() }
            try await req.downloadAndInstall()
        }
        do { try await install() }
        catch {
            // 語系保留額度滿了或還沒保留：保留一次再試
            _ = try? await AssetInventory.reserve(locale: locale)
            do { try await install() } catch { throw ClioVoiceError.download(String(describing: type(of: error))) }
        }
        return true
    }

    func makeTurn(_ cb: ClioTranscriptCallbacks) -> ClioTranscribing? {
        switch self {
        case .analyzer(let id):
            if #available(macOS 26, *) { return ClioAnalyzerTurn(module: ClioAnalyzerTurn.transcriber(Locale(identifier: id)), cb) }
            return nil
        case .dictation(let id):
            if #available(macOS 26, *) { return ClioAnalyzerTurn(module: ClioAnalyzerTurn.dictation(Locale(identifier: id)), cb) }
            return nil
        case .recognizer(let id): return ClioRecognizerTurn(locale: Locale(identifier: id), cb)
        case .none: return nil
        }
    }
}

/// SpeechAnalyzer 一輪：麥克風格式 → 模型要的格式（AVAudioConverter）→ AnalyzerInput
@available(macOS 26, *)
final class ClioAnalyzerTurn: ClioTranscribing, @unchecked Sendable {   // 狀態只有 cancelled，鎖住
    static func transcriber(_ l: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }
    static func dictation(_ l: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: l, preset: .progressiveShortDictation)
    }

    private let raw: AsyncStream<AVAudioPCMBuffer>
    private let rawIn: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let lock = NSLock()
    private var cancelled = false
    private var analyzer: SpeechAnalyzer?

    init(module: any SpeechModule, _ cb: ClioTranscriptCallbacks) {
        (raw, rawIn) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        let (input, inputIn) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        let raw = self.raw
        // 結果：確定的接起來，沒確定的只留最新一段
        let results: Task<String, Never> = Task { [weak self] in
            var finals = "", volatile = ""
            func emit() {
                let f = finals, v = volatile
                DispatchQueue.main.async { if self?.isCancelled == false { cb.update(f, v) } }
            }
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results {
                        if r.isFinal { finals += String(r.text.characters); volatile = "" } else { volatile = String(r.text.characters) }
                        emit()
                    }
                } else if let t = module as? DictationTranscriber {
                    for try await r in t.results {
                        if r.isFinal { finals += String(r.text.characters); volatile = "" } else { volatile = String(r.text.characters) }
                        emit()
                    }
                }
            } catch {}
            return finals + volatile
        }
        Task { [weak self] in
            let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            do { try await analyzer.start(inputSequence: input) } catch { inputIn.finish() }
            var conv = ClioConverter()
            for await b in raw {
                if let out = fmt.flatMap({ conv.convert(b, to: $0) }) { inputIn.yield(AnalyzerInput(buffer: out)) }
            }
            inputIn.finish()
            if self?.isCancelled == true { await analyzer.cancelAndFinishNow(); return }
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = await results.value
            DispatchQueue.main.async { if self?.isCancelled == false { cb.done(text) } }
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func append(_ b: AVAudioPCMBuffer) { rawIn.yield(b) }
    func finish() { rawIn.finish() }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        rawIn.finish()
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
    }
}

/// 換取樣率／格式（每輪一個；麥克風格式變了就重建）
struct ClioConverter {
    private var conv: AVAudioConverter?
    mutating func convert(_ b: AVAudioPCMBuffer, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        if b.format == fmt { return b }
        if conv == nil || conv?.inputFormat != b.format {
            conv = AVAudioConverter(from: b.format, to: fmt)
            conv?.primeMethod = .none
        }
        guard let conv else { return nil }
        let cap = AVAudioFrameCount(Double(b.frameLength) * fmt.sampleRate / b.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let st = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return b
        }
        return st == .error || out.frameLength == 0 ? nil : out
    }
}

/// 舊系統：SFSpeechRecognizer 一輪（中間結果整段都算「還沒確定」）
final class ClioRecognizerTurn: ClioTranscribing {
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var last = ""
    private var finished = false

    init?(locale: Locale, _ cb: ClioTranscriptCallbacks) {
        guard let r = SFSpeechRecognizer(locale: locale) else { return nil }
        request.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }   // 不送 Apple 伺服器
        request.taskHint = .dictation
        task = r.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let result {
                    self.last = result.bestTranscription.formattedString
                    if result.isFinal { self.finished = true; cb.done(self.last); return }
                    cb.update("", self.last)
                }
                if error != nil { self.finished = true; cb.done(self.last) }
            }
        }
    }
    func append(_ b: AVAudioPCMBuffer) { request.append(b) }
    func finish() { request.endAudio() }
    func cancel() { finished = true; task?.cancel() }
}

// MARK: - 探測（--cliotalk-speech-probe）

enum ClioSpeechProbe {
    /// 不開麥克風、不下載：印出三種介面語言各會用哪種轉寫、模型狀態
    static func run() -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            if #available(macOS 26, *) {
                print("SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")
                print("installed=\(await SpeechTranscriber.installedLocales.map(\.identifier).sorted())")
                for lang in PetLanguage.allCases {
                    let want = Locale(identifier: ClioSpeechLocale.identifier(for: lang))
                    let tl = await SpeechTranscriber.supportedLocale(equivalentTo: want)
                    let status = tl == nil ? "-" : "\(await AssetInventory.status(forModules: [ClioAnalyzerTurn.transcriber(tl!)]))"
                    let backend = (try? await ClioSpeechBackend.prepare(want, download: false) { _ in })?.name ?? "error"
                    print("\(lang.rawValue) → \(want.identifier): transcriber=\(tl?.identifier ?? "nil") assets=\(status) backend=\(backend)")
                }
            } else {
                print("macOS < 26：SFSpeechRecognizer only")
            }
            sem.signal()
        }
        sem.wait()
        if let path = arg("--cliotalk-speech-probe"), !path.hasPrefix("--") { transcribe(path) }
        exit(0)
    }

    /// 拿一個音檔（例如 `say -o t.aiff …` 合成的）跑一輪真的轉寫：同一條 ClioTranscribing 路徑，只是緩衝來自檔案、不是麥克風
    private static func transcribe(_ path: String) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { print("file: cannot open"); return }
        var backend = ClioSpeechBackend.none
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            backend = (try? await ClioSpeechBackend.prepare(ClioSpeechLocale.current, download: false) { _ in }) ?? .none
            sem.signal()
        }
        sem.wait()
        var updates = 0, finished = false
        let t0 = CACurrentMediaTime()
        var endAt = t0
        let cb = ClioTranscriptCallbacks(update: { _, _ in updates += 1 }, done: { text in
            print("file: backend=\(backend.name) updates=\(updates) finalize=\(Int((CACurrentMediaTime() - endAt) * 1000)) ms text=\(text)")
            finished = true
        })
        guard let turn = backend.makeTurn(cb) else { print("file: no backend"); return }
        let fmt = file.processingFormat
        while file.framePosition < file.length {
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 2048), (try? file.read(into: b)) != nil, b.frameLength > 0 else { break }
            turn.append(b)
        }
        endAt = CACurrentMediaTime()
        turn.finish()
        let deadline = Date().addingTimeInterval(20)
        while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !finished { print("file: timed out") }
    }
}
