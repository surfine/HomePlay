import CoreImage
import CoreVideo
import Foundation
@preconcurrency import Vision

// 一帧相机画面 → 认人要用的东西（只用 Apple Vision，不带任何第三方模型）。
// 移植自 WindowShade 2 的 App/VisionFaceEmbedder.swift、App/FaceEmbedder.swift（FaceAlignment）、
// App/FaceObservationSource.swift（画质取样），同一作者，MIT。
//
// Vision 没有公开的人脸身份接口。做法：从同一帧里裁出最大那张脸（外扩 1.3 倍的正方形），按两眼连线摆正，
// 缩到 224 见方，再跑 VNGenerateImageFeaturePrintRequest（钉死第 2 版），把输出向量做 L2 归一化。
// 这是通用图像特征，不是人脸身份特征；阈值必须用 `--people-probe` 在真机上标定（FaceModelProfile）。
//
// 在调用方的队列上同步运行，一个实例只给一条队列用（Vision 请求对象不是线程安全的）。
// 不存图像、不写日志、不记向量：裁切图只在这一次调用里活着。

/// 一帧里每张脸的框和朝向（几何，不是身份）。
struct FaceGeometry: Sendable, Equatable {
    /// Vision 的归一化框，原点在画面左下。
    let boundingBox: CGRect
    let yaw: Double?
    let pitch: Double?
    /// 两眼中心连线在画面像素里的倾角（弧度，逆时针为正，y 向上）。
    var eyeLineAngle: Double? = nil
}

enum FaceAlignment {
    static func finite(_ number: NSNumber?) -> Double? {
        guard let value = number?.doubleValue, value.isFinite else { return nil }
        return value
    }

    static func geometry(for face: VNFaceObservation, imageSize: CGSize) -> FaceGeometry {
        var geometry = FaceGeometry(boundingBox: face.boundingBox, yaw: finite(face.yaw), pitch: finite(face.pitch))
        if let left = face.landmarks?.leftEye?.normalizedPoints, let right = face.landmarks?.rightEye?.normalizedPoints {
            geometry.eyeLineAngle = eyeLineAngle(leftEye: left, rightEye: right, boundingBox: face.boundingBox, imageSize: imageSize)
        }
        return geometry
    }

    /// 眼睛轮廓点（Vision 的脸内归一化坐标）→ 两眼中心连线在画面像素里的倾角。
    /// 按画面左右排，角度落在 (-π/2, π/2]；点缺失、不有限或两眼几乎重合返回 nil。
    static func eyeLineAngle(leftEye: [CGPoint], rightEye: [CGPoint], boundingBox: CGRect, imageSize: CGSize) -> Double? {
        guard !leftEye.isEmpty, !rightEye.isEmpty, imageSize.width > 0, imageSize.height > 0,
              boundingBox.width > 0, boundingBox.height > 0 else { return nil }
        func centre(_ points: [CGPoint]) -> CGPoint? {
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let local = CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
            return CGPoint(x: (boundingBox.minX + local.x * boundingBox.width) * imageSize.width,
                           y: (boundingBox.minY + local.y * boundingBox.height) * imageSize.height)
        }
        guard var a = centre(leftEye), var b = centre(rightEye) else { return nil }
        if a.x > b.x { swap(&a, &b) }
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        guard hypot(dx, dy) >= 4 else { return nil }
        let angle = atan2(dy, dx)
        return angle.isFinite ? angle : nil
    }
}

/// 眼睛睁开程度：旋转无关的几何比值，不是标定过的睁闭眼分类。
enum FaceEyeGeometry {
    static func openness(_ points: [CGPoint], scale: CGSize) -> Double? {
        guard points.count >= 4, scale.width.isFinite, scale.height.isFinite, scale.width > 0, scale.height > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let pixels = points.map { CGPoint(x: $0.x * scale.width, y: $0.y * scale.height) }
        var longest = 0.0
        var axis = CGPoint.zero
        for a in pixels { for b in pixels {
            let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
            if length > longest { longest = length; axis = CGPoint(x: dx / length, y: dy / length) }
        } }
        guard longest >= 6 else { return nil }
        let perpendicular = pixels.map { -$0.x * axis.y + $0.y * axis.x }
        let ratio = ((perpendicular.max() ?? 0) - (perpendicular.min() ?? 0)) / longest
        return ratio.isFinite ? min(1, max(0, ratio)) : nil
    }
}

final class PeopleVisionEmbedder: @unchecked Sendable {
    /// 钉死的特征修订；换修订就是另一个模型版本，旧模板自动不参与。
    static let revision = VNGenerateImageFeaturePrintRequestRevision2
    static let cropMargin: CGFloat = 1.3
    static let side = 224
    /// 必须与 FaceModelProfile.visionFeaturePrintVersion 一字不差（selftest 核对）。
    static let modelVersion = "vision-featureprint-r\(revision)-crop1.3-\(side)"
    /// 头转得太偏时图像特征不可比，宁可不给。弧度。
    static let maximumYaw = 0.5
    static let maximumPitch = 0.5
    /// 裁切边长不到这么多像素就不算（太远、太糊）。
    static let minimumCropPixels: CGFloat = 48

    struct Crop: Equatable {
        let center: CGPoint
        let side: CGFloat
        /// 两眼连线相对水平线的倾角（弧度，逆时针为正）；裁切时反向转回。
        let angle: Double
    }

    private let context = CIContext(options: [.cacheIntermediates: false])

    static var isSupported: Bool { VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(revision) }

    static func poseAcceptable(yaw: Double?, pitch: Double?) -> Bool {
        if let yaw, !(yaw.isFinite && abs(yaw) <= maximumYaw) { return false }
        if let pitch, !(pitch.isFinite && abs(pitch) <= maximumPitch) { return false }
        return true
    }

    /// Vision 的归一化人脸框 → 外扩 1.3 倍的正方形裁切。框不合法或太小返回 nil。
    static func crop(boundingBox: CGRect, imageSize: CGSize, eyeLineAngle: Double) -> Crop? {
        guard [boundingBox.minX, boundingBox.minY, boundingBox.width, boundingBox.height].allSatisfy(\.isFinite),
              boundingBox.width > 0, boundingBox.height > 0, eyeLineAngle.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let side = max(boundingBox.width * imageSize.width, boundingBox.height * imageSize.height) * cropMargin
        guard side >= minimumCropPixels else { return nil }
        return Crop(center: CGPoint(x: boundingBox.midX * imageSize.width, y: boundingBox.midY * imageSize.height),
                    side: side, angle: eyeLineAngle)
    }

    /// 裁切几何 → Core Image 变换：移到原点、反向转正、缩到 side、移回正方形中心。
    static func transform(for crop: Crop) -> CGAffineTransform {
        let scale = CGFloat(side) / crop.side
        return CGAffineTransform(translationX: -crop.center.x, y: -crop.center.y)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(-crop.angle)))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: CGFloat(side) / 2, y: CGFloat(side) / 2))
    }

    static func l2Normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    /// 一张脸的特征：同一帧、同一个人脸框。头太偏、没有两眼倾角、裁切太小或 Vision 失败都返回 nil，不报原因（不进日志）。
    func embed(pixelBuffer: CVPixelBuffer, face: FaceGeometry) -> [Float]? {
        guard Self.poseAcceptable(yaw: face.yaw, pitch: face.pitch), let angle = face.eyeLineAngle else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let crop = Self.crop(boundingBox: face.boundingBox, imageSize: image.extent.size, eyeLineAngle: angle)
        else { return nil }
        return embed(image: image, crop: crop)
    }

    func embed(image: CIImage, crop: Crop) -> [Float]? {
        guard Self.isSupported else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let face = image.clampedToExtent().transformed(by: Self.transform(for: crop)).cropped(to: bounds)
        guard let rendered = context.createCGImage(face, from: bounds) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = Self.revision
        request.imageCropAndScaleOption = .scaleFill
        do { try VNImageRequestHandler(cgImage: rendered, options: [:]).perform([request]) } catch { return nil }
        guard let print = request.results?.first else { return nil }
        return Self.l2Normalized(Self.floats(of: print))
    }

    private static func floats(of print: VNFeaturePrintObservation) -> [Float] {
        let count = print.elementCount
        let data = print.data
        switch print.elementType {
        case .float:
            guard data.count >= count * MemoryLayout<Float>.size else { return [] }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double:
            guard data.count >= count * MemoryLayout<Double>.size else { return [] }
            return data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(count).map { Float($0) } }
        default:
            return []
        }
    }
}

/// 一帧分析的结果。不含图像。
struct FaceFrameAnalysis: Sendable {
    /// 画面里所有脸（宽度比例）。
    var faceWidths: [Double]
    /// 最大那张脸的画质样本（faceCount 是画面里的脸数）。
    var quality: FaceQualitySample
    var embedding: [Float]?
    var modelVersion: String
}

final class VisionFaceAnalyzer {
    private let embedder = PeopleVisionEmbedder()
    private var qualityRequest: VNDetectFaceCaptureQualityRequest?
    private var lastCenter: CGPoint?

    func reset() { lastCenter = nil }

    /// `wantsQuality`：录脸时才算 faceCaptureQuality、亮度和反光（认人不需要，省一次 Vision）。
    func analyze(_ buffer: CVPixelBuffer, wantsQuality: Bool) -> FaceFrameAnalysis? {
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([landmarks]) } catch { return nil }
        let faces = (landmarks.results ?? []).filter { $0.confidence > 0.25 }
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        let version = PeopleVisionEmbedder.modelVersion
        guard let face = faces.first else {
            lastCenter = nil
            return FaceFrameAnalysis(faceWidths: [], quality: FaceQualitySample(faceCount: 0, faceWidth: 0),
                                     embedding: nil, modelVersion: version)
        }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let box = face.boundingBox
        let geometry = FaceAlignment.geometry(for: face, imageSize: size)
        let embedding = box.width >= FaceMatchTuning().minimumFaceWidth ? embedder.embed(pixelBuffer: buffer, face: geometry) : nil

        let center = CGPoint(x: box.midX, y: box.midY)
        var sample = FaceQualitySample(faceCount: faces.count, faceWidth: Double(box.width))
        sample.yaw = geometry.yaw
        sample.pitch = geometry.pitch
        sample.centerOffset = Double(hypot(center.x - 0.5, center.y - 0.5))
        if let last = lastCenter { sample.motion = Double(hypot(center.x - last.x, center.y - last.y)) }
        lastCenter = center
        if wantsQuality {
            func eye(_ region: VNFaceLandmarkRegion2D?) -> Double? {
                guard let region else { return nil }
                return FaceEyeGeometry.openness(region.normalizedPoints,
                                                scale: CGSize(width: box.width * size.width, height: box.height * size.height))
            }
            if let l = eye(face.landmarks?.leftEye), let r = eye(face.landmarks?.rightEye) { sample.eyeOpenness = min(l, r) }
            sample.captureQuality = captureQuality(of: face, handler: handler)
            if let stats = Self.regionStats(buffer, box: box) {
                sample.brightness = stats.brightness
                sample.glareRatio = stats.glareRatio
            }
        }
        return FaceFrameAnalysis(faceWidths: faces.map { Double($0.boundingBox.width) }, quality: sample,
                                 embedding: embedding, modelVersion: version)
    }

    private func captureQuality(of face: VNFaceObservation, handler: VNImageRequestHandler) -> Double? {
        let request = qualityRequest ?? {
            let made = VNDetectFaceCaptureQualityRequest()
            made.revision = VNDetectFaceCaptureQualityRequestRevision3
            return made
        }()
        qualityRequest = request
        request.inputFaceObservations = [face]
        defer { request.inputFaceObservations = nil }
        guard (try? handler.perform([request])) != nil,
              let quality = request.results?.first?.faceCaptureQuality, quality.isFinite else { return nil }
        return min(1, max(0, Double(quality)))
    }

    /// 脸框里抽 32×32 个点（BGRA），算平均亮度和近白、近灰占比；像素只在这次调用里活着。
    static func regionStats(_ buffer: CVPixelBuffer, box: CGRect, grid: Int = 32) -> FaceCaptureSampling.Stats? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = max(0, Int(box.minX * CGFloat(w))), x1 = min(w - 1, Int(box.maxX * CGFloat(w)))
        let y0 = max(0, Int((1 - box.maxY) * CGFloat(h))), y1 = min(h - 1, Int((1 - box.minY) * CGFloat(h)))
        guard x1 > x0, y1 > y0 else { return nil }
        var pixels = [UInt8](); pixels.reserveCapacity(grid * grid * 4)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for j in 0..<grid {
            let y = y0 + (y1 - y0) * j / max(1, grid - 1)
            for i in 0..<grid {
                let x = x0 + (x1 - x0) * i / max(1, grid - 1)
                let o = y * stride + x * 4
                pixels.append(contentsOf: [ptr[o], ptr[o + 1], ptr[o + 2], ptr[o + 3]])
            }
        }
        return FaceCaptureSampling.stats(pixels: pixels, bytesPerPixel: 4, redIndex: 2, greenIndex: 1, blueIndex: 0)
    }
}
