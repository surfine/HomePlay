import Foundation

// 录脸（纯逻辑，不碰相机、文件和界面）。移植自 WindowShade 2 的 Core/FaceEnrollmentFlow.swift（同一作者，MIT），
// 去掉 Touch ID 确认（HomePlay 里是你自己点「录制脸部」，这一步就是同意）；另外加了「慢慢转头」：
// 通用的图像特征对角度很敏感，只录正脸，侧一点就认不出，所以正脸之外再各收两侧轻微转头的几帧。
//
// framing ──画质门（恰好一张脸、正脸、不太近）连续 0.5 s 通过──▶ collecting
// collecting ──正脸 4 帧 + 两侧各 2 帧（相隔 ≥0.25 s，每帧与第一帧一致）──▶ saving
// collecting ──正脸和第一帧不一致 / 冒出第二张脸──▶ framing（整轮重来，已收的帧全丢）
// collecting ──30 s 到了：正脸够了就用已有的存下；正脸不够就作废──▶ saving / ended(.timedOut)
// saving ──调用方写好文件──▶ saved　　　任何状态 ──取消 / 相机没了──▶ ended（内存里的帧和向量全部丢弃）
//
// 一致性门槛借用这个模型版本的比对阈值（FaceModelProfile）；侧脸帧不一致只是不收，不重来。没有阈值的模型不录。

struct FaceEnrollmentFrame: Equatable, Sendable {
    let cameraID: String
    let generation: UInt64
    let sequence: UInt64
    /// 帧的主机时钟，只在同一路帧之间比较。
    let capturedAt: Double
    let quality: FaceQualitySample
    /// 这一帧特征的模型版本；没算出特征就是 nil。
    let modelVersion: String?
    let embedding: [Float]?
}

/// 要写的这一组。只有 FaceEnrollmentFlow 造得出来。
struct FaceEnrollmentSave: Equatable, Sendable {
    let modelVersion: String
    let templates: [FaceTemplate]
    let added: Int
    fileprivate init(modelVersion: String, templates: [FaceTemplate], added: Int) {
        self.modelVersion = modelVersion; self.templates = templates; self.added = added
    }
}

struct FaceEnrollmentTuning: Equatable, Sendable {
    var frontFrames = 4
    var sideFramesPerDirection = 2
    /// 收下的两帧之间至少相隔这么久（秒）。
    var minimumSpacing = 0.25
    /// 转头：|yaw| 落在这个区间才算「轻微转向一侧」。待真机标定。
    var sideYaw = 0.15...0.45
    /// 侧脸和第一帧的相似度可以比阈值低这么多（侧脸本来就没那么像）。待真机标定。
    var sideTolerance: Float = 0.15
    /// 整轮收帧的时限（秒）。
    var collectTimeout = 30.0
    /// 正脸门：恰好一张脸、|yaw| ≤0.14、眼睛开度 0.14–0.6、脸宽 0.18–0.6、连续 0.5 s。
    var quality = FaceQualityTuning.enrollment
}

struct FaceEnrollmentFlow {
    enum Phase: Equatable, Sendable {
        case framing(hint: FaceQualityHint?)
        case collecting(front: Int, sideA: Int, sideB: Int)
        case saving
        case saved(total: Int)
        case ended(EndReason)
    }

    enum EndReason: Equatable, Sendable {
        case cancelled
        /// 相机没了、出错了、换了相机或相机重开。
        case cameraLost
        /// 30 秒内没收够正脸。
        case timedOut
        case storeFailed
        /// 这个模型版本没有比对阈值，不录。
        case unsupportedModel
    }

    enum Restart: Equatable, Sendable {
        case inconsistent   // 和第一帧不像同一张脸 → 「稳住别动」
        case secondFace     // 收的时候冒出第二张脸 → 「只留一张脸」
        var hint: FaceQualityHint { self == .secondFace ? .onlyOneFace : .holdStill }
    }

    private struct Stream: Equatable { let cameraID: String; let generation: UInt64 }

    let modelVersion: String
    let tuning: FaceEnrollmentTuning
    private(set) var phase: Phase
    private(set) var restarts = 0
    private(set) var lastRestart: Restart?
    private let existing: [FaceTemplate]
    private let consistencyThreshold: Float?
    private var gate: FaceQualityGate
    private var stream: Stream?
    private var lastSequence: UInt64?
    private var collected: [FaceTemplate] = []
    private var sideCounts = (a: 0, b: 0)
    private var frontCount = 0
    private var lastCollectedAt: Double?
    private var collectingSince: Double?
    private var pending: FaceEnrollmentSave?

    /// `existing`：这个版本已经存着的模板（新录的接在后面）；重新录制传空。
    init(modelVersion: String, existing: [FaceTemplate] = [], tuning: FaceEnrollmentTuning = FaceEnrollmentTuning(),
         consistencyThreshold: Float? = nil) {
        self.modelVersion = modelVersion
        self.tuning = tuning
        self.existing = existing.filter { $0.modelVersion == modelVersion }
        let threshold = consistencyThreshold ?? FaceMatchTuning().modelProfiles[modelVersion]?.similarityThreshold
        self.consistencyThreshold = threshold.flatMap { $0.isFinite && $0 > 0 && $0 <= 1 ? $0 : nil }
        gate = FaceQualityGate(mode: .enrollment, tuning: tuning.quality)
        phase = self.consistencyThreshold == nil ? .ended(.unsupportedModel) : .framing(hint: nil)
    }

    var wantsCamera: Bool {
        switch phase { case .framing, .collecting: true; default: false }
    }
    var isFinished: Bool {
        switch phase { case .saved, .ended: true; default: false }
    }

    /// 0...1，屏幕上的进度圈用。
    var progress: Double {
        let need = tuning.frontFrames + 2 * tuning.sideFramesPerDirection
        guard need > 0 else { return 0 }
        switch phase {
        case .collecting:
            let got = min(frontCount, tuning.frontFrames) + min(sideCounts.a, tuning.sideFramesPerDirection)
                + min(sideCounts.b, tuning.sideFramesPerDirection)
            return Double(got) / Double(need)
        case .saving, .saved: return 1
        default: return 0
        }
    }

    /// 正脸收够了，该请对方慢慢转头了。
    var asksToTurn: Bool { frontCount >= tuning.frontFrames }

    mutating func receive(_ frame: FaceEnrollmentFrame) {
        guard wantsCamera else { return }
        let current = Stream(cameraID: frame.cameraID, generation: frame.generation)
        if let stream, stream != current { end(.cameraLost); return }
        stream = current
        if let last = lastSequence, frame.sequence <= last { return }
        lastSequence = frame.sequence
        guard frame.capturedAt.isFinite else { return }

        switch phase {
        case .framing:
            let verdict = gate.evaluate(frame.quality, at: frame.capturedAt)
            guard verdict.passed else { phase = .framing(hint: verdict.hint ?? lastRestart?.hint); return }
            collectingSince = frame.capturedAt
            phase = .collecting(front: 0, sideA: 0, sideB: 0)
            collect(frame)
        case .collecting:
            collect(frame)
        default:
            return
        }
    }

    private mutating func collect(_ frame: FaceEnrollmentFrame) {
        if let since = collectingSince, frame.capturedAt - since >= tuning.collectTimeout {
            if frontCount >= tuning.frontFrames { finishCollecting() } else { end(.timedOut) }
            return
        }
        if frame.quality.faceCount > 1 { restart(.secondFace); return }
        guard let embedding = frame.embedding, !embedding.isEmpty, embedding.allSatisfy(\.isFinite),
              frame.modelVersion == modelVersion, let yaw = frame.quality.yaw, yaw.isFinite else { return }
        if let last = lastCollectedAt, frame.capturedAt - last < tuning.minimumSpacing { return }

        enum Bucket { case front, sideA, sideB }
        let bucket: Bucket
        var judged = frame.quality
        if abs(yaw) <= tuning.quality.enrollmentMaximumYaw {
            bucket = .front
        } else if tuning.sideYaw.contains(abs(yaw)), frontCount >= 1 {
            bucket = yaw > 0 ? .sideA : .sideB
            judged.yaw = 0   // 转头这一帧：别的画质项照样要过，偏航角本身已经由上面的区间管了
        } else {
            return
        }
        // 这一帧不是合格的脸（太远、太近、太暗、眼睛没睁开……）：不收，也不算失败；等下一帧。
        guard gate.rawHint(for: judged) == nil else { return }
        switch bucket {
        case .front where frontCount >= tuning.frontFrames: return
        case .sideA where sideCounts.a >= tuning.sideFramesPerDirection: return
        case .sideB where sideCounts.b >= tuning.sideFramesPerDirection: return
        default: break
        }
        if let first = collected.first {
            guard let threshold = consistencyThreshold, let similarity = FaceMatcher.cosine(embedding, first.embedding) else {
                if bucket == .front { restart(.inconsistent) }
                return
            }
            if bucket == .front {
                guard similarity >= threshold else { restart(.inconsistent); return }
            } else if similarity < threshold - tuning.sideTolerance {
                return   // 侧脸不像：不收，不重来
            }
        }
        let sequence = FaceTemplateSet.nextEnrollmentSequence(after: existing + collected, modelVersion: modelVersion)
        let eyes = frame.quality.eyeOpenness.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        collected.append(FaceTemplate(embedding: embedding, modelVersion: modelVersion, enrolledAt: sequence, eyeOpenness: eyes))
        lastCollectedAt = frame.capturedAt
        switch bucket {
        case .front: frontCount += 1
        case .sideA: sideCounts.a += 1
        case .sideB: sideCounts.b += 1
        }
        phase = .collecting(front: frontCount, sideA: sideCounts.a, sideB: sideCounts.b)
        if frontCount >= tuning.frontFrames, sideCounts.a >= tuning.sideFramesPerDirection,
           sideCounts.b >= tuning.sideFramesPerDirection {
            finishCollecting()
        }
    }

    private mutating func finishCollecting() {
        let merged = FaceTemplateSet.appending(collected, to: existing, modelVersion: modelVersion)
        guard !merged.isEmpty else { end(.storeFailed); return }
        pending = FaceEnrollmentSave(modelVersion: modelVersion, templates: merged, added: collected.count)
        collected = []; lastCollectedAt = nil
        phase = .saving
    }

    /// 整轮重来：已收的帧全丢，回到取景，画质门从头计时。
    private mutating func restart(_ reason: Restart) {
        restarts += 1
        lastRestart = reason
        collected = []; lastCollectedAt = nil; collectingSince = nil
        frontCount = 0; sideCounts = (0, 0)
        gate.reset()
        phase = .framing(hint: reason.hint)
    }

    /// 取走要写的这一组（只在 saving 时有，取一次）。
    mutating func takeSave() -> FaceEnrollmentSave? {
        guard phase == .saving else { return nil }
        defer { pending = nil }
        return pending
    }

    /// 文件写完了（整组一次写入，没有半份）。
    mutating func didSave(_ ok: Bool, total: Int) {
        guard phase == .saving else { return }
        phase = ok ? .saved(total: total) : .ended(.storeFailed)
    }

    /// 取消、相机没了：内存里的帧、向量和待存的模板全部丢弃。已结束的不变。
    mutating func end(_ reason: EndReason) {
        guard !isFinished else { return }
        collected = []; lastCollectedAt = nil; pending = nil
        stream = nil; lastSequence = nil
        gate.reset()
        phase = .ended(reason)
    }
}
