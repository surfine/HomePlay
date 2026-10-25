import AppKit
import AVFoundation
import Foundation

// 「谁在看」服务。只借「跟随我」已经开着的那一路相机（GazeTracker.onFaceFrame），不另开采集；
// 只在「跟随我」开着、并且你在「家人」里打开了「认出谁在看」、并且至少有一个人录过脸的时候才看帧。
// 画面不落盘、不录制、不上传；特征只在内存里；日志里没有名字，也没有数字（probe 除外，见下）。
//
// 输出（主线程）：viewer = 主人 / 已登记的家人 / 访客 / 没人，换人要稳 1 秒（ViewerTracker）。
// 个人内容（行程、提醒这些）的门：personalContentAllowed = 眼前是主人，眼前没有不像主人的证据，
// 并且（可选）主人的 iPhone 在旁边。iPhone 在不在目前是占位：phonePresence 为 nil 就不要求。

final class WhoIsLooking {
    static let shared = WhoIsLooking()

    static let enabledKey = "HomePlayPeopleRecognize"
    static var recognitionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey); shared.settingsChanged() }
    }
    static let requirePhoneKey = "HomePlayPeopleRequirePhone"
    /// 个人内容是否还要求主人的 iPhone 在旁边（占位，默认关）。
    static var requireOwnerPhone: Bool {
        get { UserDefaults.standard.bool(forKey: requirePhoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: requirePhoneKey) }
    }

    enum Mode { case idle, recognizing, enrolling, probing }

    // MARK: 主线程可读

    private(set) var viewer: Viewer = .nobody
    private(set) var contradictsOwner = false
    /// 主人的 iPhone 在不在旁边。STUB：还没接（接收器的蓝牙／同 Wi-Fi 信号以后接在这里）；nil 表示不知道。
    var phonePresence: (() -> Bool)?
    var onViewerChange: ((Viewer) -> Void)?

    var personalContentAllowed: Bool {
        Self.gate(viewer: viewer, contradictsOwner: contradictsOwner, requirePhone: Self.requireOwnerPhone, phonePresent: phonePresence?())
    }

    /// 个人内容的门（纯函数，selftest 直接测）：眼前是主人、没有不像主人的证据，要求 iPhone 时 iPhone 必须在旁边。
    static func gate(viewer: Viewer, contradictsOwner: Bool, requirePhone: Bool, phonePresent: Bool?) -> Bool {
        guard viewer.isOwner, !contradictsOwner else { return false }
        guard requirePhone else { return true }
        return phonePresent ?? false   // 要求了却不知道 iPhone 在不在：关门
    }

    // MARK: 相机线程与处理队列共用的状态（锁保护）

    private let lock = NSLock()
    private var mode: Mode = .idle
    private var followActive = false
    private var busy = false
    private var lastStart = 0.0

    // MARK: 处理队列私有

    private let queue = DispatchQueue(label: "homeplay.people", qos: .utility)
    private let analyzer = VisionFaceAnalyzer()
    private var tracker = ViewerTracker(matcher: FaceMatcher(people: []))
    private var flow: FaceEnrollmentFlow?
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var probe: ProbeState?

    // MARK: 主线程私有

    private weak var app: AppDelegate?
    private var enrollingPersonID: String?
    private var lastEnrollFrameAt = 0.0
    private var watchdog: Timer?
    private var wiredRegistry = false

    private init() {}

    /// 启动时调一次：把相机帧接进来，名册变了就重载比对器。
    func install(app: AppDelegate) {
        self.app = app
        GazeTracker.shared.onFaceFrame = { [weak self] buffer, now in self?.ingest(buffer, now) }
        let registry = PeopleRegistry.shared
        if !wiredRegistry {
            wiredRegistry = true
            registry.onChange = { [weak self] in
                DispatchQueue.main.async { self?.reloadMatcher(); PeopleModel.shared.refresh() }
            }
        }
        reloadMatcher()
    }

    /// PetView.setGazeEnabled 调：「跟随我」开关。
    func setFollowActive(_ on: Bool) {
        lock.lock(); followActive = on; lock.unlock()
        if !on { resetViewer() }
        refreshMode()
    }

    private func settingsChanged() {
        if !Self.recognitionEnabled { resetViewer() }
        refreshMode()
    }

    private(set) var hasReferences = false   // 2.0: PersonalGate 要知道認人是不是真的在跑
    private func reloadMatcher() {
        let input = PeopleRegistry.shared.matcherInput()
        hasReferences = !input.isEmpty
        queue.async { [self] in
            tracker.replaceMatcher(FaceMatcher(people: input))
            if probe != nil { probe?.matcher = FaceMatcher(people: input) }
        }
        if !hasReferences { resetViewer() }
        refreshMode()
    }

    private func refreshMode() {
        lock.lock()
        defer { lock.unlock() }
        if mode == .enrolling || mode == .probing { return }
        mode = (followActive && Self.recognitionEnabled && hasReferences) ? .recognizing : .idle
    }

    private func resetViewer() {
        queue.async { [self] in tracker.reset() }
        publish(viewer: .nobody, contradicts: false)
    }

    private func publish(viewer new: Viewer, contradicts: Bool) {
        DispatchQueue.main.async { [self] in
            contradictsOwner = contradicts
            guard new != viewer else { return }
            viewer = new
            // 只记「换了一类人」，不记名字
            log("people: viewer -> \(new.logLabel)")
            onViewerChange?(new)
            if let id = new.personID, let p = PeopleRegistry.shared.person(id) { PeopleOverlay.greet(p) }
        }
    }

    // MARK: 相机线程入口

    private func ingest(_ buffer: CVPixelBuffer, _ now: Double) {
        lock.lock()
        let m = mode
        guard m != .idle, !busy, now - lastStart >= (m == .enrolling ? 0.15 : 0.25) else { lock.unlock(); return }
        busy = true; lastStart = now
        lock.unlock()
        queue.async { [self] in
            switch m {
            case .enrolling: processEnrollment(buffer, now)
            case .probing: processProbe(buffer, now)
            default: processRecognition(buffer, now)
            }
            lock.lock(); busy = false; lock.unlock()
        }
    }

    // MARK: 认人

    private func processRecognition(_ buffer: CVPixelBuffer, _ now: Double) {
        guard let a = analyzer.analyze(buffer, wantsQuality: false) else { return }
        sequence &+= 1
        // 只有最大那张脸有特征（取最大候选脸）；其余只带宽度。
        var faces = a.faceWidths.map { ViewerFrame.Face(widthFraction: $0, embedding: nil) }
        if let i = a.faceWidths.indices.max(by: { a.faceWidths[$0] < a.faceWidths[$1] }) {
            faces[i] = ViewerFrame.Face(widthFraction: a.faceWidths[i], embedding: a.embedding)
        }
        let before = (tracker.viewer, tracker.contradictsOwner)
        let v = tracker.receive(ViewerFrame(cameraID: "front", generation: generation, sequence: sequence, capturedAt: now,
                                            modelVersion: a.modelVersion, faces: faces))
        if before != (v, tracker.contradictsOwner) { publish(viewer: v, contradicts: tracker.contradictsOwner) }
    }

    // MARK: 录脸

    /// 为 personID 录脸（重新录制＝整组替换）。需要相机权限；没开「跟随我」也行，录完把相机还回去。
    func beginEnrollment(personID: String, app: AppDelegate) {
        guard enrollingPersonID == nil, PeopleRegistry.shared.person(personID) != nil else { return }
        self.app = app
        enrollingPersonID = personID
        PeopleEnrollmentState.shared.begin(personID: personID)
        PeopleOverlay.beginEnrollment(PeopleRegistry.shared.person(personID))
        app.withPermission(.camera) { [weak self] ok in
            guard let self, self.enrollingPersonID == personID else { return }
            guard ok else { self.finishEnrollment(.ended(.cameraLost)); return }
            self.startEnrollmentCapture()
        }
    }

    private func startEnrollmentCapture() {
        lock.lock(); mode = .enrolling; lock.unlock()
        lastEnrollFrameAt = CACurrentMediaTime()
        queue.async { [self] in
            analyzer.reset(); generation &+= 1; sequence = 0
            flow = FaceEnrollmentFlow(modelVersion: PeopleRegistry.modelVersion)
        }
        GazeTracker.shared.setTrackFaces(true)
        GazeTracker.shared.start { [weak self] ok, _ in
            if !ok { self?.finishEnrollment(.ended(.cameraLost)) }
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.enrollingPersonID != nil else { return }
            if CACurrentMediaTime() - self.lastEnrollFrameAt > 8 { self.cancelEnrollment(reason: .cameraLost) }
        }
    }

    func cancelEnrollment(reason: FaceEnrollmentFlow.EndReason = .cancelled) {
        guard enrollingPersonID != nil else { return }
        queue.async { [self] in flow?.end(reason) }
        finishEnrollment(.ended(reason))
    }

    var isEnrolling: Bool { enrollingPersonID != nil }

    private func processEnrollment(_ buffer: CVPixelBuffer, _ now: Double) {
        guard var f = flow, let a = analyzer.analyze(buffer, wantsQuality: true) else { return }
        sequence &+= 1
        f.receive(FaceEnrollmentFrame(cameraID: "front", generation: generation, sequence: sequence, capturedAt: now,
                                      quality: a.quality, modelVersion: a.modelVersion, embedding: a.embedding))
        var save: FaceEnrollmentSave?
        if f.phase == .saving { save = f.takeSave() }
        flow = f
        let snapshot = (f.phase, f.progress, f.asksToTurn)
        DispatchQueue.main.async { [self] in
            lastEnrollFrameAt = CACurrentMediaTime()
            guard let id = enrollingPersonID else { return }
            PeopleEnrollmentState.shared.update(phase: snapshot.0, progress: snapshot.1, asksToTurn: snapshot.2)
            PeopleOverlay.updateEnrollment(phase: snapshot.0, progress: snapshot.1, asksToTurn: snapshot.2)
            if let save {
                var ok = false
                do { try PeopleRegistry.shared.saveTemplates(save.templates, for: id); ok = true } catch { log("people: save failed") }
                queue.async { [self] in
                    flow?.didSave(ok, total: save.templates.count)
                    let phase = flow?.phase ?? .ended(.storeFailed)
                    DispatchQueue.main.async { [self] in finishEnrollment(phase) }
                }
            } else if case .ended = snapshot.0 {
                finishEnrollment(snapshot.0)
            }
        }
    }

    private func finishEnrollment(_ phase: FaceEnrollmentFlow.Phase) {
        guard enrollingPersonID != nil else { return }
        enrollingPersonID = nil
        watchdog?.invalidate(); watchdog = nil
        queue.async { [self] in flow = nil }
        lock.lock(); mode = .idle; lock.unlock()
        refreshMode()
        PeopleEnrollmentState.shared.finish(phase: phase)
        PeopleOverlay.finishEnrollment(phase)
        log("people: enrollment finished (\(phase.logLabel))")
        // 把相机还回去：「跟随我」没开就关掉人脸模式（房间光线还在用就留着低帧率）
        if let view = app?.view, !view.gazeEnabled {
            GazeTracker.shared.setTrackFaces(false)
            if !view.roomLightEnabled { GazeTracker.shared.stop() }
        }
    }

    // MARK: probe（隐藏的校准工具：--people-probe）

    private struct ProbeState {
        var matcher: FaceMatcher
        var selfTemplates: [FaceTemplate] = []
        var lastSelfAt = 0.0
        var lastLogAt = 0.0
        var samples: [String: [Float]] = [:]
        var frames = 0
    }
    static let probeSelfFrames = 5

    /// 开相机，对每一帧里最大的脸打印它和每个已录入的人（p1、p2……按名册顺序，不含名字）的相似度数字，
    /// 外加「self」：开头 5 个有特征的帧在内存里当模板，之后的帧对它打分（不用先录脸就能量到同一个人的分布）。
    /// 只打印数字：不打印向量、不存图像、不写模板。
    func startProbe(app: AppDelegate) {
        self.app = app
        let people = PeopleRegistry.shared.matcherInput()
        queue.async { [self] in
            analyzer.reset(); generation &+= 1; sequence = 0
            probe = ProbeState(matcher: FaceMatcher(people: people))
        }
        lock.lock(); mode = .probing; lock.unlock()
        GazeTracker.shared.setTrackFaces(true)
        GazeTracker.shared.start { ok, reason in
            log(ok ? "people-probe: camera started; thresholds uncalibrated=\(!FaceModelProfile.visionFeaturePrint.calibrated) threshold=\(FaceModelProfile.visionFeaturePrint.similarityThreshold)"
                   : "people-probe: camera failed (\(reason ?? "?"))")
        }
    }

    private func processProbe(_ buffer: CVPixelBuffer, _ now: Double) {
        guard var p = probe, let a = analyzer.analyze(buffer, wantsQuality: true) else { return }
        defer { probe = p }
        p.frames += 1
        guard let width = a.faceWidths.max() else { return }
        let q = a.quality
        guard let emb = a.embedding else {
            if now - p.lastLogAt >= 1 {
                p.lastLogAt = now
                emit(String(format: "faces=%d width=%.3f yaw=%.3f embedded=0", q.faceCount, width, q.yaw ?? .nan))
            }
            return
        }
        if p.selfTemplates.count < Self.probeSelfFrames, now - p.lastSelfAt >= 0.4 {
            p.lastSelfAt = now
            p.selfTemplates.append(FaceTemplate(embedding: emb, modelVersion: a.modelVersion,
                                                enrolledAt: Double(p.selfTemplates.count + 1)))
            if p.selfTemplates.count == Self.probeSelfFrames { emit("self reference ready (in memory only)") }
        }
        guard now - p.lastLogAt >= 0.5 else { return }
        p.lastLogAt = now
        let threshold = FaceMatchTuning().similarityThreshold(for: a.modelVersion) ?? .nan
        var parts: [String] = []
        let enrolled = p.matcher.scores(emb, modelVersion: a.modelVersion)
        let order = PeopleRegistry.shared.people.map(\.id)
        for s in enrolled {
            let tag = "p\((order.firstIndex(of: s.id) ?? -1) + 1)"
            parts.append(String(format: "%@ mean=%.4f latest=%.4f eff=%.4f", tag, s.toMean, s.toLatest, s.effective))
            p.samples[tag, default: []].append(s.effective)
        }
        if p.selfTemplates.count >= Self.probeSelfFrames {
            let me = FaceMatcher(people: [PersonTemplates(id: "self", isOwner: true, templates: p.selfTemplates)])
            if let s = me.scores(emb, modelVersion: a.modelVersion).first {
                parts.append(String(format: "self mean=%.4f latest=%.4f eff=%.4f", s.toMean, s.toLatest, s.effective))
                p.samples["self", default: []].append(s.effective)
            }
        }
        emit(String(format: "faces=%d width=%.3f yaw=%.3f thr=%.3f | ", q.faceCount, width, q.yaw ?? .nan, threshold) + parts.joined(separator: " | "))
        if p.frames % 40 == 0 {
            for (tag, v) in p.samples.sorted(by: { $0.key < $1.key }) { emit("summary \(tag) \(Self.summary(v))") }
        }
    }

    private func emit(_ line: String) {
        log("people-probe: " + line)
        appendDiag("people-probe.log", line)
    }

    static func summary(_ values: [Float]) -> String {
        let s = values.sorted()
        guard !s.isEmpty else { return "n=0" }
        func f(_ x: Float) -> String { String(format: "%.4f", x) }
        func pct(_ p: Double) -> Float { s[min(max(Int((p * Double(s.count)).rounded(.up)) - 1, 0), s.count - 1)] }
        return "n=\(s.count) min=\(f(s[0])) p5=\(f(pct(0.05))) median=\(f(pct(0.5))) p95=\(f(pct(0.95))) max=\(f(s[s.count - 1]))"
    }
}

private extension Viewer {
    /// 日志里只写类别，不写名字、不写 id。
    var logLabel: String {
        switch self {
        case .nobody: "nobody"
        case .guest: "guest"
        case .owner: "owner"
        case .known: "known"
        }
    }
}

private extension FaceEnrollmentFlow.Phase {
    var logLabel: String {
        switch self {
        case .framing: "framing"
        case .collecting: "collecting"
        case .saving: "saving"
        case .saved: "saved"
        case .ended(let r): "ended-\(r)"
        }
    }
}
