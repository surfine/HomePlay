// 2.0 imsg：訊息的「用說的」——聽寫一句話（使用者自己的字），講完自動停或點「完成」，結果交給確認卡。
// 用 ClioTalk 的耳朵（ClioMic、ClioVAD、ClioSpeechBackend：本機 SpeechAnalyzer／DictationTranscriber），
// 但不經過任何模型：聽到什麼就原樣放進「要傳給 X：『…』嗎？」，ClioTalk 不替你改寫、不替你發聲。
// 另外放「專注模式」（勿擾）偵測：開著時新訊息不跳橫幅、眼睛不瞄（跟手錶一樣安靜），未讀點照樣更新。
// 隱私：聲音只在記憶體裡流過；日誌只記狀態，不記聽到的字。

import AppKit
import AVFoundation

final class MessagesDictation {
    enum State: Equatable { case idle, preparing(Double?), listening, finishing }
    private(set) var state = State.idle
    private(set) var final = "", volatile = ""
    var text: String { (final + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }

    var onChange: () -> Void = {}
    var onDone: (String) -> Void = { _ in }
    var onFail: (String) -> Void = { _ in }

    private let mic = ClioMic()
    private var vad = ClioVAD()
    private var turn: ClioTranscribing?
    private var backend: ClioSpeechBackend?
    private var session = 0
    private var startedAt = 0.0
    /// 最長聽 30 秒（手錶的聽寫也有上限）
    static let maxSeconds = 30.0

    init() { mic.onLevel = { [weak self] db, d in self?.level(db, d) } }

    var active: Bool { state != .idle }

    func start() {
        guard state == .idle else { return }
        session += 1
        final = ""; volatile = ""; vad = ClioVAD()
        state = .preparing(nil); onChange()
        let id = session
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: openMic(id)
        default:
            guard let app = NSApp.delegate as? AppDelegate else { fail(.micDenied); return }
            app.withPermission(.microphone) { [weak self] ok in
                guard let self, self.session == id else { return }
                ok ? self.openMic(id) : self.fail(.micDenied)
            }
        }
    }

    private func openMic(_ id: Int) {
        do { try mic.start() } catch { fail(.noMicrophone); return }
        mic.hold()
        startedAt = CACurrentMediaTime()
        if let b = backend { begin(b, id) ; return }
        // 跟 ClioVoiceSession 一樣：Task 只抓兩個回呼，不直接抓 self
        let progress: (Double) -> Void = { [weak self] p in
            guard let self, self.session == id, case .preparing = self.state else { return }
            self.state = .preparing(p); self.onChange()
        }
        let done: (Result<ClioSpeechBackend, Error>) -> Void = { [weak self] r in
            guard let self, self.session == id, self.state != .idle else { return }
            switch r {
            case .success(.none): self.fail(.unsupported)
            case .success(let b): self.backend = b; self.begin(b, id)
            case .failure(let e): self.fail(e as? ClioVoiceError ?? .unsupported)
            }
        }
        let locale = ClioSpeechLocale.current
        Task {
            let r: Result<ClioSpeechBackend, Error>
            do { r = .success(try await ClioSpeechBackend.prepare(locale, download: true) { p in DispatchQueue.main.async { progress(p) } }) }
            catch { r = .failure(error) }
            DispatchQueue.main.async { done(r) }
        }
    }

    private func begin(_ b: ClioSpeechBackend, _ id: Int) {
        let cb = ClioTranscriptCallbacks(
            update: { [weak self] f, v in
                guard let self, self.session == id else { return }
                self.final = f; self.volatile = v; self.onChange()
            },
            done: { [weak self] t in
                guard let self, self.session == id else { return }
                if !t.isEmpty { self.final = t; self.volatile = "" }
                self.complete()
            })
        guard let t = b.makeTurn(cb) else { fail(.unsupported); return }
        turn = t
        mic.attach { t.append($0) }
        state = .listening; onChange()
        log("messages: dictation listening")
    }

    /// 點「完成」或講完了：收尾，交出這一句
    func finish() {
        guard state == .listening || { if case .preparing = state { return true }; return false }() else { return }
        guard let t = turn else { cancel(); return }
        state = .finishing; onChange()
        mic.detach(); t.finish()
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in   // 轉寫器卡住：用手上有的字
            guard let self, self.session == id, self.state == .finishing else { return }
            self.complete()
        }
    }

    func cancel() {
        session += 1
        turn?.cancel(); turn = nil
        mic.stop()
        state = .idle; onChange()
    }

    private func complete() {
        let t = text
        session += 1
        turn?.cancel(); turn = nil
        mic.stop()
        state = .idle
        log("messages: dictation done (\(t.isEmpty ? "empty" : "text"))")
        onChange()
        onDone(t)
    }

    private func fail(_ e: ClioVoiceError) {
        log("messages: dictation unavailable (\(e))")
        cancel()
        onFail(e.message)
    }

    private func level(_ db: Float, _ d: Double) {
        guard state == .listening else { return }
        if CACurrentMediaTime() - startedAt > Self.maxSeconds { finish(); return }
        if vad.feed(db: db, duration: d) == .endpoint, !text.isEmpty { finish() }
    }
}

// MARK: - 專注模式（勿擾）

enum MessagesFocus {
    static var path: String { NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json" }

    /// Assertions.json：手動打開的專注模式會在 data[].storeAssertionRecords 留一筆（macOS 27 本機觀察；沒有公開 API，排程的專注不在這裡）。
    /// 純函式；讀不懂就當沒開（不因為猜錯而把訊息藏起來）
    static func isActive(json: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let data = root["data"] as? [[String: Any]] else { return false }
        return data.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }

    nonisolated(unsafe) private static var cached: (at: Double, on: Bool)?
    /// 主執行緒；5 秒內重用。快照與示範永遠當沒開
    static var active: Bool {
        if SnapshotPrivacy.active || MessagesDemo.mode != nil { return false }
        let now = CACurrentMediaTime()
        if let c = cached, now - c.at < 5 { return c.on }
        let on = (try? Data(contentsOf: URL(fileURLWithPath: path))).map(isActive) ?? false
        cached = (now, on)
        return on
    }
}
