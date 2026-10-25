import Foundation

// 谁在看（纯逻辑）。规则移植自 WindowShade 2 的 FaceScanGuard，从「锁屏一次性扫描」改成「持续在场」：
// - 帧号用调用方透传的 cameraID / generation / sequence，这里不自己数帧：同一路里同号或更早的帧不再计数；
//   换了相机或代次（相机重开，帧号从头数）就是另一路，攒下的部分匹配清零。
// - 宽度不到画面 0.18 的脸是路人，不算候选；取最大那张。
// - 一个人要连续 2 帧都认成同一个人才算数（requiredConsecutiveMatches）。
// - 认错脸要满 2 秒才判成「访客」（wrongFaceGrace）；2 秒内算「还没定」，保持原来的人。
// - 换人要稳 1 秒（switchHold）：新的结论连续撑满 1 秒才切，免得一帧误判就换人；回到原来的人立刻取消。
// - 个人内容的门比换人快：当前是主人，但眼前出现不像主人的证据满 0.5 秒（revokeAfter）就先关门，
//   不等 2 秒 + 1 秒。宁可多关一下，也不要把行程给别人看到。

enum Viewer: Equatable, Sendable {
    case nobody
    /// 有人，但不认识（或认不出）。
    case guest
    /// 这台 Mac 的主人（登记的 #1）。
    case owner(String)
    /// 登记过的其他家人。
    case known(String)

    var personID: String? {
        switch self {
        case .owner(let id), .known(let id): id
        case .nobody, .guest: nil
        }
    }
    var isOwner: Bool { if case .owner = self { true } else { false } }
}

struct ViewerTuning: Equatable, Sendable {
    var requiredConsecutiveMatches = 2
    var wrongFaceGrace = 2.0
    var switchHold = 1.0
    var revokeAfter = 0.5
}

/// 相机帧里和认人有关的部分。不含图像。
struct ViewerFrame: Equatable, Sendable {
    struct Face: Equatable, Sendable {
        /// 脸宽占画面宽的比例，0...1。
        let widthFraction: Double
        /// 特征；脸太偏、算不出来就是 nil。
        let embedding: [Float]?
    }
    let cameraID: String
    let generation: UInt64
    let sequence: UInt64
    /// 帧的主机时钟，只在同一路帧之间比较。
    let capturedAt: Double
    let modelVersion: String
    let faces: [Face]
}

struct ViewerTracker {
    private struct Stream: Equatable { let cameraID: String; let generation: UInt64 }

    let tuning: ViewerTuning
    private(set) var matcher: FaceMatcher
    private(set) var viewer: Viewer = .nobody
    /// 当前是主人时，眼前有没有「不像主人」的证据满 revokeAfter。个人内容的门要看它。
    private(set) var contradictsOwner = false

    private var stream: Stream?
    private var lastSequence: UInt64?
    private var consecutiveID: String?
    private var consecutiveCount = 0
    private var firstWrongAt: Double?
    private var firstNotOwnerAt: Double?
    private var candidate: Viewer?
    private var candidateSince = 0.0

    init(matcher: FaceMatcher, tuning: ViewerTuning = ViewerTuning()) {
        self.matcher = matcher
        self.tuning = tuning
    }

    /// 模板变了（录了新的、删了人）：换比对器，攒下的部分匹配清零，当前的人保留到下一帧重新判断。
    mutating func replaceMatcher(_ matcher: FaceMatcher) {
        self.matcher = matcher
        resetPartials(); firstNotOwnerAt = nil
    }

    mutating func reset() {
        resetPartials(); firstNotOwnerAt = nil
        viewer = .nobody; candidate = nil; contradictsOwner = false
        stream = nil; lastSequence = nil
    }

    private mutating func resetPartials() {
        consecutiveID = nil; consecutiveCount = 0; firstWrongAt = nil
    }

    /// 喂一帧，回传现在的「谁在看」。
    @discardableResult
    mutating func receive(_ frame: ViewerFrame) -> Viewer {
        guard frame.capturedAt.isFinite else { return viewer }
        let current = Stream(cameraID: frame.cameraID, generation: frame.generation)
        if stream != current {
            stream = current; lastSequence = nil; resetPartials(); firstNotOwnerAt = nil
        }
        if let last = lastSequence, frame.sequence <= last { return viewer }
        lastSequence = frame.sequence
        let now = frame.capturedAt

        let candidates = frame.faces.filter { $0.widthFraction.isFinite && $0.widthFraction >= matcher.tuning.minimumFaceWidth }
        let raw = classify(candidates.max(by: { $0.widthFraction < $1.widthFraction }), modelVersion: frame.modelVersion, at: now)
        settle(raw, at: now)
        return viewer
    }

    /// 这一帧的原始结论；nil = 还没定（认错不满 2 秒、第一帧匹配还在等第二帧），不动任何计时。
    private mutating func classify(_ face: ViewerFrame.Face?, modelVersion: String, at now: Double) -> Viewer? {
        guard let face else {
            resetPartials()   // 没人：由 1 秒的换人保持去收；「不像主人」的计时不动
            return .nobody
        }
        // 有脸但算不出特征（头太偏、裁切太小）：当没看到，不拿来认人。
        guard let embedding = face.embedding else {
            resetPartials()
            return .nobody
        }
        switch matcher.match(embedding, modelVersion: modelVersion) {
        case .matched(let id, _):
            firstWrongAt = nil
            if consecutiveID == id { consecutiveCount += 1 } else { consecutiveID = id; consecutiveCount = 1 }
            let isOwner = matcher.isOwner(id)
            noteEvidence(againstOwner: !isOwner, at: now)
            guard consecutiveCount >= max(1, tuning.requiredConsecutiveMatches) else { return nil }
            return isOwner ? .owner(id) : .known(id)
        case .mismatch, .noReference:
            consecutiveID = nil; consecutiveCount = 0
            noteEvidence(againstOwner: true, at: now)
            let first = firstWrongAt ?? now
            firstWrongAt = first
            return now - first >= tuning.wrongFaceGrace ? .guest : nil
        }
    }

    /// 「不像主人」的证据计时：连续满 revokeAfter 就先关个人内容的门。
    private mutating func noteEvidence(againstOwner: Bool, at now: Double) {
        guard againstOwner else { firstNotOwnerAt = nil; contradictsOwner = false; return }
        let first = firstNotOwnerAt ?? now
        firstNotOwnerAt = first
        contradictsOwner = viewer.isOwner && now - first >= tuning.revokeAfter
    }

    /// 迟滞：新结论连续撑满 switchHold 才切；回到现在的人就取消。
    private mutating func settle(_ raw: Viewer?, at now: Double) {
        guard let raw else { return }
        if raw == viewer { candidate = nil; return }
        if candidate != raw { candidate = raw; candidateSince = now; return }
        if now - candidateSince >= tuning.switchHold {
            viewer = raw; candidate = nil
            if !raw.isOwner { contradictsOwner = false }
            firstNotOwnerAt = raw.isOwner ? nil : firstNotOwnerAt
        }
    }
}
