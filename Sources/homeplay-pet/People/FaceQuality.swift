import Foundation

// 画质门：拍之前先管住。移植自 WindowShade 2 的 Core/FaceCaptureQuality.swift（同一作者，MIT）；
// 反光取法参照 Glance GlareCueExtractor（MIT License，Copyright (c) 2026 jonnyoo），作者注明未验证。纯逻辑，不碰相机、不碰 Vision。
// - 一帧的画质样本进来，出一个结论：过 / 不过（带一条提示）。
// - 画质不过只是“还没拍到”，不算一次失败。
// - 一次只给一条提示，按“能做的动作”排序；换提示要持续 0.6 秒（回滞），免得在两条之间跳。
// - 反光：近白、近灰像素占比 ≥0.04 连续 3 帧 = 否决线索（锁存）。
// - 门只会加门槛：自己放行不了任何东西。
// 所有数字都是起点，标注“待真机标定”的不要当成结论。

/// 一帧的画质样本。拿不到的量写 nil（该项不参与判断）；非有限数一律当作“不合格”。
struct FaceQualitySample: Equatable, Sendable {
    /// 画面里算数的脸数。录脸、挑战要求恰好 1 张；扫描取最大那张，人数不卡。
    var faceCount: Int
    /// 最大那张脸宽占画面宽的比例。
    var faceWidth: Double
    var yaw: Double?
    var pitch: Double?
    /// 两只眼睁开程度的较小值（录正脸时用）。
    var eyeOpenness: Double?
    /// Vision 的 faceCaptureQuality，0...1，越高越好。
    var captureQuality: Double?
    /// 脸部裁切的平均亮度 Y，0...1。
    var brightness: Double?
    /// 近白、近灰像素占脸部裁切的比例，0...1。
    var glareRatio: Double?
    /// 脸框中心离画面中心的距离，归一化（0 居中）。
    var centerOffset: Double?
    /// 与上一帧相比脸框中心的位移，归一化。
    var motion: Double?
}

enum FaceQualityHint: String, Equatable, Sendable, CaseIterable {
    // 声明顺序 = 提示优先级（只留一张脸 → 靠近/离远 → 居中 → 看镜头 → 补光 → 稳住）。
    case onlyOneFace, moveCloser, moveBack, centerFace, lookAtCamera, tooDark, tooBright, holdStill

    /// 桌宠屏幕上的一句话。
    var text: String {
        switch self {
        case .onlyOneFace: L("people.quality.onlyOneFace", "只留一张脸")
        case .moveCloser: L("people.quality.moveCloser", "靠近一点")
        case .moveBack: L("people.quality.moveBack", "离远一点")
        case .centerFace: L("people.quality.centerFace", "把脸放到中间")
        case .lookAtCamera: L("people.quality.lookAtCamera", "看向镜头")
        case .tooDark: L("people.quality.tooDark", "光线太暗")
        case .tooBright: L("people.quality.tooBright", "光线太强")
        case .holdStill: L("people.quality.holdStill", "稳住别动")
        }
    }
}

/// 用在哪：扫描（认人，取最大脸）或录脸（要求恰好 1 张、正脸、不能太近）。
enum FaceQualityMode: Sendable { case scan, enrollment }

struct FaceQualityTuning: Equatable, Sendable {
    /// 脸宽下限，两种用途共用（Glance、FaceScanGuard.minimumFaceWidth）。
    var minimumFaceWidth = 0.18
    /// 录脸时脸宽上限（太近畸变）。待真机标定。
    var enrollmentMaximumFaceWidth = 0.6
    /// 录正脸：|yaw| 上限（quietglass OwnerEnrollment）与眼睛开度区间。
    var enrollmentMaximumYaw = 0.14
    var enrollmentEyeOpenness = 0.14...0.6
    /// 比对：|yaw|、|pitch| 上限，沿用 VisionFaceEmbedder 现值；建议收到 0.35，待标定。
    var scanMaximumAngle = 0.5
    /// captureQuality 下限。待真机标定：起点用本人录脸时的第 20 百分位（见 recommendedMinimumQuality）。
    var minimumCaptureQuality = 0.25
    /// 亮度区间。待真机标定。
    var brightness = 0.18...0.88
    /// 脸框中心离画面中心的最大距离。待标定。
    var maximumCenterOffset = 0.3
    /// 相邻帧位移上限。待标定。
    var maximumMotion = 0.08
    /// 反光占比下限与连续帧数（Glance；未验证）。
    var glareRatioThreshold = 0.04
    var glareFramesRequired = 3
    /// 提示回滞：换成另一条提示前，新结论要持续这么久（秒）。
    var hintHysteresis = 0.6
    /// 连续通过这么久才算过门（录脸 0.5 秒；扫描 0 = 一帧即过）。
    var requiredPassDuration = 0.0
    /// 数字没有真机标定过。
    var calibrated = false

    static let scan = FaceQualityTuning()
    static let enrollment: FaceQualityTuning = {
        var tuning = FaceQualityTuning()
        tuning.requiredPassDuration = 0.5
        return tuning
    }()

    /// 起点建议：本人录脸时 captureQuality 的第 20 百分位（向下取整的最近名次）。
    /// 非有限或越界的样本丢掉；一个也没有返回 nil。
    static func recommendedMinimumQuality(fromEnrollment qualities: [Double]) -> Double? {
        let values = qualities.filter { $0.isFinite && $0 >= 0 && $0 <= 1 }.sorted()
        guard !values.isEmpty else { return nil }
        let index = Int((Double(values.count - 1) * 0.2).rounded(.down))
        return values[index]
    }
}

struct FaceQualityVerdict: Equatable, Sendable {
    /// 这一帧的画质过了，并且已持续够久（requiredPassDuration）。
    var passed: Bool
    /// 桌宠屏幕上现在显示的那条提示（已过回滞）；过了或还没稳定就是 nil。
    var hint: FaceQualityHint?
    /// 反光否决线索已锁存（它不是画质不过）。
    var glareVeto: Bool
}

struct FaceQualityGate {
    let mode: FaceQualityMode
    let tuning: FaceQualityTuning

    private var shownHint: FaceQualityHint?
    private var pendingHint: FaceQualityHint?
    private var pendingSince: Double?
    private var passingSince: Double?
    private var glareStreak = 0
    private var glareLatched = false

    init(mode: FaceQualityMode, tuning: FaceQualityTuning? = nil) {
        self.mode = mode
        self.tuning = tuning ?? (mode == .enrollment ? .enrollment : .scan)
    }

    /// 清空状态（新一轮取景）。
    mutating func reset() {
        shownHint = nil; pendingHint = nil; pendingSince = nil; passingSince = nil
        glareStreak = 0; glareLatched = false
    }

    /// 这一帧最该提示的一条；全过返回 nil。纯函数。
    func rawHint(for sample: FaceQualitySample) -> FaceQualityHint? {
        let t = tuning
        if mode == .enrollment, sample.faceCount > 1 { return .onlyOneFace }
        if sample.faceCount < 1 { return .lookAtCamera }
        guard sample.faceWidth.isFinite, sample.faceWidth >= t.minimumFaceWidth else { return .moveCloser }
        if mode == .enrollment, sample.faceWidth > t.enrollmentMaximumFaceWidth { return .moveBack }
        if let offset = sample.centerOffset, !(offset.isFinite && offset <= t.maximumCenterOffset) { return .centerFace }
        if !Self.poseOK(sample, mode: mode, tuning: t) { return .lookAtCamera }
        if let q = sample.captureQuality, !(q.isFinite && q >= t.minimumCaptureQuality) {
            // 清晰度不够：能看出是太暗就说太暗，否则让对方稳住。
            if let y = sample.brightness, y.isFinite, y < t.brightness.lowerBound { return .tooDark }
            return .holdStill
        }
        if let y = sample.brightness {
            if !y.isFinite || y < t.brightness.lowerBound { return .tooDark }
            if y > t.brightness.upperBound { return .tooBright }
        }
        if let m = sample.motion, !(m.isFinite && m <= t.maximumMotion) { return .holdStill }
        return nil
    }

    private static func poseOK(_ s: FaceQualitySample, mode: FaceQualityMode, tuning t: FaceQualityTuning) -> Bool {
        func within(_ value: Double?, _ limit: Double) -> Bool {
            guard let value else { return true }
            return value.isFinite && abs(value) <= limit
        }
        switch mode {
        case .scan:
            return within(s.yaw, t.scanMaximumAngle) && within(s.pitch, t.scanMaximumAngle)
        case .enrollment:
            guard within(s.yaw, t.enrollmentMaximumYaw), within(s.pitch, t.scanMaximumAngle) else { return false }
            if let eyes = s.eyeOpenness { return eyes.isFinite && t.enrollmentEyeOpenness.contains(eyes) }
            return true
        }
    }

    mutating func evaluate(_ sample: FaceQualitySample, at time: Double) -> FaceQualityVerdict {
        updateGlare(sample)
        let candidate = rawHint(for: sample)
        if let candidate {
            passingSince = nil
            updateHint(candidate, at: time)
        } else {
            shownHint = nil; pendingHint = nil; pendingSince = nil
            if passingSince == nil { passingSince = time }
        }
        let held = passingSince.map { time - $0 >= tuning.requiredPassDuration } ?? false
        return FaceQualityVerdict(passed: candidate == nil && held, hint: shownHint, glareVeto: glareLatched)
    }

    private mutating func updateHint(_ candidate: FaceQualityHint, at time: Double) {
        if candidate == shownHint { pendingHint = nil; pendingSince = nil; return }
        if pendingHint != candidate { pendingHint = candidate; pendingSince = time }
        if let since = pendingSince, time - since >= tuning.hintHysteresis {
            shownHint = candidate; pendingHint = nil; pendingSince = nil
        }
    }

    private mutating func updateGlare(_ sample: FaceQualitySample) {
        guard let ratio = sample.glareRatio, ratio.isFinite, ratio >= tuning.glareRatioThreshold else {
            glareStreak = 0   // 连续才算；没读到或不够，就断开
            return
        }
        glareStreak += 1
        if glareStreak >= tuning.glareFramesRequired { glareLatched = true }
    }
}

/// 极薄的采样：从一块交错的 8 位像素里算脸部裁切的平均亮度和近白、近灰占比。
/// 调用方（相机队列）把裁切区域的字节交进来；这里不持有、不存图。BGRA 或 RGBA 由通道序号指定。
enum FaceCaptureSampling {
    struct Stats: Equatable, Sendable {
        var brightness: Double
        var glareRatio: Double
    }

    /// 近白：三个通道都 ≥225。近灰：亮度 ≥200 且三通道极差 ≤12（几乎没有颜色的亮点）。待标定。
    static let nearWhiteChannel = 225
    static let nearGrayLuma = 200.0
    static let nearGraySpread = 12

    /// `pixels` 每像素 `bytesPerPixel` 字节（≥3），每 `stride` 个像素取一个。空输入、参数不合法返回 nil。
    static func stats(pixels: [UInt8], bytesPerPixel: Int = 4, redIndex: Int = 2, greenIndex: Int = 1,
                      blueIndex: Int = 0, stride: Int = 1) -> Stats? {
        guard bytesPerPixel >= 3, stride >= 1,
              [redIndex, greenIndex, blueIndex].allSatisfy({ $0 >= 0 && $0 < bytesPerPixel }) else { return nil }
        let count = pixels.count / bytesPerPixel
        guard count > 0 else { return nil }
        var lumaSum = 0.0, sampled = 0, glare = 0
        var index = 0
        while index < count {
            let base = index * bytesPerPixel
            let r = Int(pixels[base + redIndex]), g = Int(pixels[base + greenIndex]), b = Int(pixels[base + blueIndex])
            let luma = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
            lumaSum += luma
            sampled += 1
            let spread = max(r, g, b) - min(r, g, b)
            if min(r, g, b) >= nearWhiteChannel || (luma >= nearGrayLuma && spread <= nearGraySpread) { glare += 1 }
            index += stride
        }
        return Stats(brightness: lumaSum / Double(sampled) / 255, glareRatio: Double(glare) / Double(sampled))
    }
}
