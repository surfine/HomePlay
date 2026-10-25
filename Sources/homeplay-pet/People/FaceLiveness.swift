import Foundation

// 脸部被动线索：只能否决，从不放行。移植自 WindowShade 2 的 Core/FaceLivenessCues.swift（同一作者，MIT）。
//
// 思路取自 Glance（https://github.com/jonnyoo/glance，MIT License，
// Copyright (c) 2026 jonnyoo）的 Liveness 目录：屏幕反光、手机/平板边框、鼻子视差三条线索，
// 以及“否决线索一触发就判失败、确认线索缺了不算失败”的角色划分。本文件是 Swift 自写，不是拷贝；
// 阈值沿用作者的首轮估计（作者注明未用真实素材验证），需真机标定后再收紧。
//
// 规则：
// - 否决线索：反光占比 >= 0.04 连续 3 帧；矩形（屏幕/手机边框）盖住脸 >= 0.15 连续 3 次检测。
//   任一触发即锁存为否决，直到 reset；锁存后的好帧不会撤销。
// - 矩形检测每 3 帧才跑一次（RectangleCadence），只在身份订阅时跑；没跑的帧不改变边框计数。
// - 脸消失（nil）清掉连续计数，但不撤销已锁存的否决。
// - 鼻子视差只是确认线索：本轮只记录进证据，不作门槛，缺了不算失败。
// - 本文件没有任何“放行”输出。HomePlay 里这些线索只给「个人内容」多加一道门槛，不接任何系统认证。

/// 归一化坐标（0...1，原点任意，只要脸框与矩形同一坐标系）。
struct FaceCueRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var area: Double {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 0 }
        return width * height
    }

    func intersectionArea(with other: FaceCueRect) -> Double {
        let values = [x, y, width, height, other.x, other.y, other.width, other.height]
        guard values.allSatisfy({ $0.isFinite }) else { return 0 }
        let w = min(x + width, other.x + other.width) - max(x, other.x)
        let h = min(y + height, other.y + other.height) - max(y, other.y)
        guard w > 0, h > 0 else { return 0 }
        return w * h
    }
}

struct FaceCueFrame: Equatable, Sendable {
    /// 脸框；这一帧没有脸就是 nil。
    let face: FaceCueRect?
    /// 脸部裁切里近白、近灰像素的占比，0...1；没算就是 nil（不计入、不清零）。
    let glareFraction: Double?
    /// 本帧跑了矩形检测才有值；没跑就是 nil。
    let rectangles: [FaceCueRect]?
}

enum FaceVetoReason: String, Equatable, Sendable {
    case bezel
    case glare
}

/// 线索只有“没意见”和“否决”两种答案。没有放行。
enum FaceCueVerdict: Equatable, Sendable {
    case noObjection
    case veto(FaceVetoReason)
}

/// 矩形检测的节拍：每 3 帧一次，从第一帧开始。
struct RectangleCadence: Equatable, Sendable {
    static let interval: UInt64 = 3
    private(set) var framesSeen: UInt64 = 0

    /// 每来一帧调用一次；返回这一帧要不要跑矩形检测。
    mutating func shouldDetect() -> Bool {
        defer { framesSeen &+= 1 }
        return framesSeen % Self.interval == 0
    }

    mutating func reset() { framesSeen = 0 }
}

struct FaceVetoCues: Equatable, Sendable {
    static let glareThreshold = 0.04
    static let glareFrames = 3
    static let bezelCoverageThreshold = 0.15
    static let bezelSamples = 3
    /// 整幅画面大小的矩形就是画面本身，不是边框。
    static let frameFillLimit = 0.9

    private(set) var glareStreak = 0
    private(set) var bezelStreak = 0
    private(set) var latched: FaceVetoReason?

    var verdict: FaceCueVerdict {
        if let latched { return .veto(latched) }
        return .noObjection
    }

    /// 矩形盖住脸的比例（交集 / 脸面积）。无效输入给 0。
    static func bezelCoverage(face: FaceCueRect, rectangles: [FaceCueRect]) -> Double {
        let faceArea = face.area
        guard faceArea > 0 else { return 0 }
        var best = 0.0
        for rect in rectangles where rect.area > 0 && rect.area < frameFillLimit {
            best = max(best, min(1, rect.intersectionArea(with: face) / faceArea))
        }
        return best
    }

    @discardableResult
    mutating func observe(_ frame: FaceCueFrame) -> FaceCueVerdict {
        guard let face = frame.face, face.area > 0 else {
            glareStreak = 0
            bezelStreak = 0
            return verdict
        }
        if let glare = frame.glareFraction, glare.isFinite {
            if glare >= Self.glareThreshold { glareStreak += 1 } else { glareStreak = 0 }
            if glareStreak >= Self.glareFrames, latched == nil { latched = .glare }
        }
        if let rectangles = frame.rectangles {
            let coverage = Self.bezelCoverage(face: face, rectangles: rectangles)
            if coverage >= Self.bezelCoverageThreshold { bezelStreak += 1 } else { bezelStreak = 0 }
            if bezelStreak >= Self.bezelSamples, latched == nil { latched = .bezel }
        }
        return verdict
    }

    mutating func reset() { self = FaceVetoCues() }
}

/// 鼻子视差（确认线索，只记录）。
struct NoseParallaxSample: Equatable, Sendable {
    /// 镜头里脸的偏航角，弧度。
    let yaw: Double
    /// 鼻子中心相对两眼中点的水平偏移，除以两眼间距。
    let noseOffset: Double
}

enum FaceParallax {
    static let minimumTurnDegrees = 12.0
    static let minimumSamples = 3
    static let confirmCorrelation = 0.6

    /// 鼻子偏移与 tan(yaw) 的皮尔逊相关系数。转头幅度不到 12 度、样本太少、
    /// 任一值非有限、或任一序列没有变化（方差为 0）时给 nil（不评，不是失败）。
    static func depthParallax(window: [NoseParallaxSample]) -> Double? {
        guard window.count >= minimumSamples,
              window.allSatisfy({ $0.yaw.isFinite && $0.noseOffset.isFinite && abs($0.yaw) < 1.5 })
        else { return nil }
        let yaws = window.map { $0.yaw }
        guard let lo = yaws.min(), let hi = yaws.max() else { return nil }
        guard (hi - lo) * 180 / .pi >= minimumTurnDegrees else { return nil }
        let xs = yaws.map { tan($0) }
        let ys = window.map { $0.noseOffset }
        let n = Double(window.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<window.count {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 1e-12, syy > 1e-12 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// 只给证据用：评得出且 r >= 0.6 才算“有立体感”；评不出不算失败。
    static func isConfirmed(window: [NoseParallaxSample]) -> Bool {
        guard let r = depthParallax(window: window) else { return false }
        return r >= confirmCorrelation
    }
}
