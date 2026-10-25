import Foundation

// 比对规则（纯逻辑）。移植自 WindowShade 2 的 Core/FaceScanGuard.swift（同一作者，MIT），
// 思路取自 Glance FaceRecognitionPipeline（MIT License，Copyright (c) 2026 jonnyoo），Swift 自写。
//
// 规则：
// - 一个人要同时过「平均模板」和「最近一次录入」两道阈值（两道阈值缺一不可）。
// - 模型版本不同的模板不参与；阈值按模型版本选：登记过的版本用自己的，其余沿用默认 0.6；阈值不合法就一律不认。
// - 多人时取分数最高的那位；第二名只差一点点（< ambiguityMargin）就算「分不出」，不认任何人。
// - 宽度不到画面 0.18 的脸是路人，不算候选。

/// 某个特征模型版本自己的阈值。不同模型的余弦分布不同，一个阈值不能通用。
struct FaceModelProfile: Equatable, Sendable {
    let modelVersion: String
    let similarityThreshold: Float
    /// false = 还没用真人样本标定过（用 `--people-probe` 在真机上量）。
    let calibrated: Bool

    /// Apple Vision 图像特征（VNGenerateImageFeaturePrintRequest 第 2 版），输入是摆正、外扩 1.3 倍、
    /// 缩到 224 见方的脸部裁切。版本串写进模板，换修订或换裁切就是另一个版本，旧模板自动不参与。
    static let visionFeaturePrintVersion = "vision-featureprint-r2-crop1.3-224"
    /// UNCALIBRATED：图像特征不是人脸身份特征，不同人的脸裁切余弦也可能很高。0.92 是 WindowShade 2 偏严的占位值，
    /// 宁可认不出也不放宽；真机标定后改这里，并把 calibrated 改成 true。
    static let visionFeaturePrint = FaceModelProfile(
        modelVersion: visionFeaturePrintVersion, similarityThreshold: 0.92, calibrated: false)

    static let table: [String: FaceModelProfile] = Dictionary(
        uniqueKeysWithValues: [visionFeaturePrint].map { ($0.modelVersion, $0) })
}

struct FaceMatchTuning: Equatable, Sendable {
    /// 没登记模型阈值的版本用这个（原先按 ArcFace 类特征定的）。
    var similarityThreshold: Float = 0.6
    var modelProfiles: [String: FaceModelProfile] = FaceModelProfile.table
    var minimumFaceWidth: Double = 0.18
    /// 多人时第一名比第二名至少高这么多才认；待标定。
    var ambiguityMargin: Float = 0.01

    /// 这个模型版本该用的阈值；不在 (0, 1] 内（含 NaN）就返回 nil，调用方一律不认。
    func similarityThreshold(for modelVersion: String) -> Float? {
        let value = modelProfiles[modelVersion]?.similarityThreshold ?? similarityThreshold
        return value.isFinite && value > 0 && value <= 1 ? value : nil
    }
}

/// 一个人的模板（已按当前模型版本读好）。
struct PersonTemplates: Equatable, Sendable {
    let id: String
    let isOwner: Bool
    let templates: [FaceTemplate]
}

/// 一张脸对一个人的分数；probe 只打印这些数字。
struct PersonScore: Equatable, Sendable {
    let id: String
    /// 对平均模板的余弦。
    let toMean: Float
    /// 对最近一次录入的余弦。
    let toLatest: Float
    /// 判定用的分数：两道阈值都要过，所以取较小者。
    var effective: Float { min(toMean, toLatest) }
}

enum FaceMatchResult: Equatable, Sendable {
    case matched(id: String, score: Float)
    /// 有脸、有特征，但谁都不像（或分不出）。
    case mismatch
    /// 没有可比的模板（没人录过，或模板是别的模型版本的）。
    case noReference
}

struct FaceMatcher: Sendable {
    private struct Reference: Sendable {
        let id: String
        let modelVersion: String
        let dimension: Int
        let mean: [Float]
        let latest: [Float]
    }

    let tuning: FaceMatchTuning
    private let references: [Reference]
    private let owners: Set<String>

    init(people: [PersonTemplates], tuning: FaceMatchTuning = FaceMatchTuning()) {
        self.tuning = tuning
        var refs: [Reference] = []
        for person in people {
            // 同一个人里按（模型版本，维度）分组，各算一份参照。模板在 init 里定下就不变，平均只算这一次。
            var groups: [String: [FaceTemplate]] = [:]
            for t in person.templates { groups["\(t.modelVersion)|\(t.embedding.count)", default: []].append(t) }
            for (_, group) in groups {
                guard let latest = group.max(by: { $0.enrolledAt < $1.enrolledAt }),
                      let mean = Self.mean(group.map { Self.normalized($0.embedding) }) else { continue }
                refs.append(Reference(id: person.id, modelVersion: latest.modelVersion, dimension: latest.embedding.count,
                                      mean: mean, latest: latest.embedding))
            }
        }
        references = refs
        owners = Set(people.filter(\.isOwner).map(\.id))
    }

    var hasReferences: Bool { !references.isEmpty }
    func isOwner(_ id: String) -> Bool { owners.contains(id) }

    /// 每个人的分数（同模型版本、同维度的参照才算）。
    func scores(_ embedding: [Float], modelVersion: String) -> [PersonScore] {
        references.compactMap { ref in
            guard ref.modelVersion == modelVersion, ref.dimension == embedding.count,
                  let toMean = Self.cosine(embedding, ref.mean), let toLatest = Self.cosine(embedding, ref.latest)
            else { return nil }
            return PersonScore(id: ref.id, toMean: toMean, toLatest: toLatest)
        }
    }

    func match(_ embedding: [Float], modelVersion: String) -> FaceMatchResult {
        guard let threshold = tuning.similarityThreshold(for: modelVersion) else { return .mismatch }
        let all = scores(embedding, modelVersion: modelVersion)
        guard !all.isEmpty else { return .noReference }
        let passing = all.filter { $0.toMean >= threshold && $0.toLatest >= threshold }
            .sorted { $0.effective > $1.effective }
        guard let best = passing.first else { return .mismatch }
        // 第二名（不管有没有过线）只差一点点：分不出，不认。
        if let second = all.filter({ $0.id != best.id }).map(\.effective).max(),
           best.effective - second < tuning.ambiguityMargin { return .mismatch }
        return .matched(id: best.id, score: best.effective)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for index in a.indices { dot += a[index] * b[index]; na += a[index] * a[index]; nb += b[index] * b[index] }
        guard na > 0, nb > 0, dot.isFinite, na.isFinite, nb.isFinite else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 && norm.isFinite ? v.map { $0 / norm } : v
    }

    private static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors { for index in sum.indices { sum[index] += vector[index] } }
        return sum.map { $0 / Float(vectors.count) }
    }
}
