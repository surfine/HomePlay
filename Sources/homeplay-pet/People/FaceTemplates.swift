import Foundation

// 「谁在看」的脸部模板（纯逻辑）。移植自 WindowShade 2 的 Core/FaceTemplateSet.swift（同一作者，MIT）。
// 思路取自 Glance（https://github.com/jonnyoo/glance，MIT License，Copyright (c) 2026 jonnyoo）的
// FaceUnlockCoordinator / FaceRecognitionPipeline，Swift 自写；这里没有用它的模型权重
// （InsightFace 权重只限非商业研究），只用 Apple Vision。
// 模板是生物特征：只存特征数字和录入序号，不存图像；读回时逐项校验，坏数据当没有；任何地方都不写日志。

struct FaceTemplate: Equatable, Sendable {
    let embedding: [Float]
    let modelVersion: String
    /// 录入序号，越大越新；只用来找「最近一次录入」。新录入接在已有最大值后面递增（FaceTemplateSet.nextEnrollmentSequence），
    /// 不读墙钟，改系统时间改不了谁是最近一次。
    let enrolledAt: Double
    /// 录入那一帧两只眼睛睁开程度的较小值；没有就是 nil。
    var eyeOpenness: Double? = nil
}

enum FaceTemplateSet {
    /// 一个人、一个模型版本最多留这么多条，超出丢最早的。
    static let capacity = 20
    private static let formatVersion = 1

    private struct Payload: Codable {
        let format: Int
        let modelVersion: String
        let templates: [Entry]
    }
    private struct Entry: Codable {
        /// 小端 Float32 字节（JSON 里是 base64），比数字数组省约三倍空间。
        let embedding: Data
        let enrolledAt: Double
        let eyeOpenness: Double?
    }

    static func bytes(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func floats(_ data: Data) -> [Float]? {
        guard data.count % 4 == 0 else { return nil }
        let raw = [UInt8](data)
        return stride(from: 0, to: raw.count, by: 4).map { i in
            Float(bitPattern: UInt32(raw[i]) | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2]) << 16 | UInt32(raw[i + 3]) << 24)
        }
    }

    /// 只编码这个版本、维度一致、数值有限的模板；一条都没有就返回 nil。
    static func encode(_ templates: [FaceTemplate], modelVersion: String) -> Data? {
        let valid = sanitized(templates, modelVersion: modelVersion)
        guard !valid.isEmpty else { return nil }
        let payload = Payload(format: formatVersion, modelVersion: modelVersion,
                              templates: valid.map { Entry(embedding: bytes($0.embedding), enrolledAt: $0.enrolledAt,
                                                          eyeOpenness: $0.eyeOpenness) })
        return try? JSONEncoder().encode(payload)
    }

    /// 读回：格式、版本、维度、数值任一不对，整组作废（返回空），不猜。模型版本不同的模板不参与（版本钉死）。
    static func decode(_ data: Data, modelVersion: String) -> [FaceTemplate] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.format == formatVersion, payload.modelVersion == modelVersion,
              payload.templates.count <= capacity else { return [] }
        var templates: [FaceTemplate] = []
        for entry in payload.templates {
            guard let vector = floats(entry.embedding) else { return [] }
            templates.append(FaceTemplate(embedding: vector, modelVersion: modelVersion, enrolledAt: entry.enrolledAt,
                                         eyeOpenness: entry.eyeOpenness.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }))
        }
        let valid = sanitized(templates, modelVersion: modelVersion)
        return valid.count == templates.count ? valid : []
    }

    /// 只读出文件里记的模型版本（不解出向量）；格式不对返回 nil。用来分辨「没有模板」和「模板是旧版本的」。
    static func storedModelVersion(_ data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.format == formatVersion else { return nil }
        return payload.modelVersion
    }

    /// 下一条录入的序号：接在这个版本已有的最大值后面加 1，不读墙钟。
    static func nextEnrollmentSequence(after existing: [FaceTemplate], modelVersion: String) -> Double {
        let latest = existing.filter { $0.modelVersion == modelVersion && $0.enrolledAt.isFinite }.map(\.enrolledAt).max() ?? 0
        return max(latest, 0).rounded(.down) + 1
    }

    /// 新录入的接在后面；维度和旧的不同就整组换掉旧的。按录入序号排好，只留最近 capacity 条。
    static func appending(_ new: [FaceTemplate], to existing: [FaceTemplate], modelVersion: String) -> [FaceTemplate] {
        let fresh = sanitized(new, modelVersion: modelVersion)
        guard let dimension = fresh.first?.embedding.count else { return sanitized(existing, modelVersion: modelVersion) }
        let kept = sanitized(existing, modelVersion: modelVersion).filter { $0.embedding.count == dimension }
        let merged = (kept + fresh).sorted { $0.enrolledAt < $1.enrolledAt }
        return Array(merged.suffix(capacity))
    }

    /// 同版本、非空、数值有限、录入序号有限，且全部和第一条同维度。
    private static func sanitized(_ templates: [FaceTemplate], modelVersion: String) -> [FaceTemplate] {
        let candidates = templates.filter {
            $0.modelVersion == modelVersion && !$0.embedding.isEmpty && $0.enrolledAt.isFinite
                && $0.embedding.allSatisfy(\.isFinite)
        }
        guard let dimension = candidates.first?.embedding.count else { return [] }
        return candidates.filter { $0.embedding.count == dimension }
    }
}
