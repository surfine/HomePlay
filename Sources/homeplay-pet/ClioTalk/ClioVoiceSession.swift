// ClioTalk 語音的一次對話（主執行緒）：把 ClioVoiceLoop 的動作接到麥克風、VAD、轉寫，
// 再透過幾個回呼交給 ClioTalkController（送出、停止朗讀、退回打字）。
// 隱私：聲音只在記憶體裡流過，不錄、不存；日誌只記時間（毫秒），不記聽到的字。

import AppKit
import AVFoundation

final class ClioVoiceSession {
    private(set) var loop = ClioVoiceLoop()
    private var vad = ClioVAD()
    private let mic = ClioMic()
    private var turn: ClioTranscribing?
    private var turnID = 0
    private var backend: ClioSpeechBackend?
    private var preparing = false
    /// 這一輪要開始了，但轉寫還沒好（在問權限或下載模型）
    private var turnWanted = false
    private var finishWanted = false

    private(set) var liveFinal = ""
    private(set) var liveVolatile = ""
    /// 下載語音模型的進度（0…1）；nil＝沒在下載
    private(set) var download: Double?
    private(set) var listenAt = 0.0
    /// 這一輪是用說的送出去的（畫「在想」的那顆球）
    private(set) var submittedAt = -1.0

    // 計時（只記毫秒）
    private var onsetAt = -1.0, endAt = -1.0

    /// 正在念的文字（分辨回音用）
    var spokenText: () -> String = { "" }
    var onSubmit: (String) -> Void = { _ in }
    var onInterrupt: () -> Void = {}
    /// 不能用語音：退回打字，卡片上說原因
    var onFail: (String) -> Void = { _ in }
    var onMicClosed: () -> Void = {}
    var redraw: () -> Void = {}

    init() {
        mic.onLevel = { [weak self] db, d in self?.level(db, d) }
    }

    var active: Bool { loop.micOpen }

    private func now() -> Double { CACurrentMediaTime() }

    // MARK: 外面來的事件

    func press() { vad.reset(); listenAt = now(); perform(loop.press(now: now())) }
    func release() { perform(loop.release(now: now())) }
    func tapOrb() { if !loop.listening { vad.reset(); listenAt = now() }; perform(loop.tapOrb(now: now())) }
    func cancel() { perform(loop.cancel()) }
    func answerSpeaking() {
        if loop.state == .waiting { vad.reset() }   // 念的時候重新算「開口」（門檻較高）
        loop.answerSpeaking()
    }
    func answerDone(followUp: Bool) {
        if loop.state != .bargeCheck { vad.reset() }
        loop.followUpEnabled = followUp
        perform(loop.answerDone(now: now()))
        redraw()
    }
    func tick() { perform(loop.tick(now: now())) }

    // MARK: 動作

    private func perform(_ actions: [ClioVoiceLoop.Action]) {
        for a in actions {
            switch a {
            case .openMic: openMic()
            case .closeMic: closeMic()
            case .beginTurn: beginTurn()
            case .endTurn: endTurn()
            case .cancelTurn: cancelTurn()
            case .interrupt: onInterrupt()
            case .submit:
                let t = (liveFinal + liveVolatile).trimmingCharacters(in: .whitespacesAndNewlines)
                submittedAt = now()
                onSubmit(t)
            }
        }
        redraw()
    }

    private func openMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startMic()
        default:
            // 沿用桌寵螢幕上的權限卡（PermissionPrimer）：先說明再跳系統框；被拒就給「打开系统设置」
            guard let app = NSApp.delegate as? AppDelegate else { fail(.micDenied); return }
            app.withPermission(.microphone) { [weak self] ok in
                guard let self, self.loop.micOpen else { return }
                ok ? self.startMic() : self.fail(.micDenied)
            }
        }
    }

    private func startMic() {
        do { try mic.start() } catch { fail(.noMicrophone); return }
        prepareBackend()
        if turnWanted, backend != nil { startTurnNow() }
    }

    private func closeMic() {
        mic.stop()
        vad = ClioVAD()   // 下次重新量噪音底
        turnWanted = false; finishWanted = false
        download = nil
        onMicClosed()
    }

    private func fail(_ e: ClioVoiceError) {
        log("ClioTalk voice: unavailable (\(e))")
        perform(loop.cancel())
        onFail(e.message)
    }

    private func prepareBackend() {
        guard backend == nil, !preparing else { return }
        preparing = true
        let t0 = now()
        let progress: (Double) -> Void = { [weak self] p in self?.download = p; self?.redraw() }
        let done: (Result<ClioSpeechBackend, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.preparing = false
            self.download = nil
            switch result {
            case .success(.none): self.fail(.unsupported)
            case .success(let b):
                self.backend = b
                log("ClioTalk voice: backend \(b.name) ready in \(Int((self.now() - t0) * 1000)) ms")
                if self.turnWanted, self.mic.running { self.startTurnNow() }
            case .failure(let e): self.fail(e as? ClioVoiceError ?? .unsupported)
            }
            self.redraw()
        }
        let locale = ClioSpeechLocale.current
        Task {
            let result: Result<ClioSpeechBackend, Error>
            do { result = .success(try await ClioSpeechBackend.prepare(locale, download: true, progress: progress)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { done(result) }
        }
    }

    private func beginTurn() {
        turn?.cancel(); turn = nil
        liveFinal = ""; liveVolatile = ""
        onsetAt = -1; endAt = -1
        turnWanted = true; finishWanted = false
        if backend != nil, mic.running { startTurnNow() } else { mic.hold() }
    }

    private func startTurnNow() {
        guard turnWanted, let b = backend else { return }
        turnWanted = false
        turnID += 1
        let id = turnID
        let cb = ClioTranscriptCallbacks(
            update: { [weak self] f, v in self?.transcript(id, f, v) },
            done: { [weak self] t in self?.turnFinished(id, t) })
        guard let t = b.makeTurn(cb) else { fail(.unsupported); return }
        turn = t
        mic.attach { t.append($0) }
        if finishWanted { finishWanted = false; endTurn() }
    }

    private func endTurn() {
        endAt = now()
        guard let t = turn else {
            if turnWanted { finishWanted = true } else { turnFinished(turnID, "") }
            return
        }
        mic.detach()
        t.finish()
        // 轉寫器卡住：2.5 秒後用手上有的字
        let id = turnID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.turnID == id, self.turn != nil else { return }
            self.turnFinished(id, self.liveFinal + self.liveVolatile)
        }
    }

    private func cancelTurn() {
        turn?.cancel(); turn = nil
        turnID += 1
        mic.detach()
        turnWanted = false; finishWanted = false
        liveFinal = ""; liveVolatile = ""
    }

    // MARK: 轉寫、音量

    private func transcript(_ id: Int, _ f: String, _ v: String) {
        guard id == turnID, turn != nil else { return }
        liveFinal = f; liveVolatile = v
        if loop.state == .bargeCheck {
            perform(loop.voiceText(isEcho: ClioEcho.isEcho(heard: f + v, spoken: spokenText())))
        }
        redraw()
    }

    private func turnFinished(_ id: Int, _ text: String) {
        guard id == turnID else { return }
        turn?.cancel(); turn = nil
        mic.detach()
        if !text.isEmpty { liveFinal = text; liveVolatile = "" }
        let t = now()
        if endAt > 0 {
            log("ClioTalk voice: turn \(Int((t - listenAt) * 1000)) ms, speech→endpoint \(onsetAt > 0 ? Int((endAt - onsetAt) * 1000) : -1) ms, finalize \(Int((t - endAt) * 1000)) ms")
        }
        perform(loop.turnDone(text: liveFinal + liveVolatile, now: t))
    }

    private func level(_ db: Float, _ d: Double) {
        guard mic.running else { return }
        vad.strict = loop.state == .speaking || loop.state == .bargeCheck
        let t = now()
        switch vad.feed(db: db, duration: d) {
        case .onset?:
            if onsetAt < 0 { onsetAt = t }
            perform(loop.onset(now: t))
        case .endpoint?: perform(loop.endpoint(now: t))
        case nil: break
        }
    }
}
