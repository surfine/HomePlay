// Quick Look 的棚拍 IBL + 摄像头房间光。
//
// Apple 的文档给了两份 EXR（Quick Look object mode / AR mode）。RealityKit 不会读
// USDZ 里的 preferredIblVersion，所以这里直接把 object mode 的 EXR 作为环境资源，
// 这就是 Quick Look 桌面预览用的同一套棚拍光；之后再把摄像头看到的房间色温/亮度/
// 主光方向叠上去（见 RoomLightEstimator）。
import AppKit
import CoreGraphics
import ImageIO
import RealityKit

enum QuickLookIBL {
    /// Quick Look object-mode 的 512×256 浮点 EXR（Apple sample code）。
    /// 只作为 lightingEnvironment 的 IBL，不铺成天空盒——桌宠窗口仍是透明底。
    static let studio: EnvironmentResource? = {
        guard let url = Bundle.module.url(forResource: "studio_lighting_objectmode_v002", withExtension: "exr"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            log("Quick Look EXR 不在资源包里")
            return nil
        }
        if #available(macOS 15.0, *) {
            return try? EnvironmentResource(equirectangular: cg, withName: "quicklook-object")
        }
        return nil   // macOS 14 退回 RealityKit 默认 IBL
    }()
}

/// 把摄像头缩略图叠进 Quick Look object-mode EXR 的前方半球，生成实时 IBL：
/// 底座/屏幕背板的金属反射会带上房间的色温、窗光和明暗；其余方向仍是官方棚拍。
/// 1 Hz 左右重建（EnvironmentResource 的预过滤不便宜），主光/阴影仍按 4–5 Hz 更新。
final class RoomEnvironment {
    private let base: CIImage
    private let extent: CGRect
    private let context: CIContext
    private let mask: CIImage
    private let baseResource: EnvironmentResource?
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private var lastAt = 0.0
    private var lastComposed: RoomLightSample?
    private let queue = DispatchQueue(label: "homeplay.roomenv", qos: .userInitiated)
    private var busy = false
    private var pending: RoomLightSample?
    /// 在 EnvironmentResource 生成后回主线程交给 ARView。
    var onEnvironment: ((EnvironmentResource) -> Void)?

    init?() {
        guard let url = Bundle.module.url(forResource: "studio_lighting_objectmode_v002", withExtension: "exr"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        // 动态房间环境用 256×128：反射是模糊的，分辨率减半让 EnvironmentResource 预过滤
        // 从 ~30ms 降到 ~10ms；Quick Look 的静态棚拍底仍是 512×256。
        let full = CIImage(cgImage: cg)
        base = full.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        extent = base.extent
        baseResource = QuickLookIBL.studio
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        context = CIContext(options: [.workingColorSpace: cs, .outputColorSpace: cs, .cacheIntermediates: false])
        let g = CIFilter(name: "CIRadialGradient")!
        g.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        g.setValue(40, forKey: "inputRadius0")
        g.setValue(120, forKey: "inputRadius1")
        g.setValue(CIColor.white, forKey: "inputColor0")
        g.setValue(CIColor.clear, forKey: "inputColor1")
        mask = g.outputImage!.cropped(to: extent)
    }

    func neutral() -> EnvironmentResource? { baseResource }

    /// 2.5 秒节流 + 显著变化才重建；CoreImage 合成在后台，EnvironmentResource 回主线程创建。
    private var interval: Double {
        let p = ProcessInfo.processInfo
        return (p.isLowPowerModeEnabled || p.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue) ? 8.0 : 2.5
    }

    func update(_ s: RoomLightSample, force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastAt >= interval else { return }
        if !force, let last = lastComposed {
            let di = abs(s.intensity - last.intensity)
            let dw = abs(s.warmth - last.warmth)
            let dd = simd_dot(s.direction, last.direction)
            guard di > 0.04 || dw > 0.04 || dd < 0.995 else { return }
        }
        lastAt = now
        guard !busy else { pending = s; return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let cg = self.compose(s)
            DispatchQueue.main.async {
                self.busy = false
                if let cg, #available(macOS 15.0, *) {
                    do {
                        let t = CACurrentMediaTime()
                        let e: EnvironmentResource
                        if #available(macOS 27.0, *) {
                            e = try EnvironmentResource(equirectangular: cg,
                                options: .init(samplingQuality: .fast, specularCubeDimension: 128))
                        } else {
                            e = try EnvironmentResource(equirectangular: cg, withName: "room-light")
                        }
                        self.lastComposed = s
                        self.onEnvironment?(e)
                        appendDiag("roomlight.log", String(format: "env ok %dx%d main %.0fms", cg.width, cg.height, (CACurrentMediaTime() - t) * 1000))
                    } catch {
                        appendDiag("roomlight.log", "env resource failed: \(error)")
                    }
                }
                if let p = self.pending {
                    self.pending = nil
                    self.update(p, force: true)
                }
            }
        }
    }

    private func compose(_ s: RoomLightSample) -> CGImage? {
        guard s.thumbnail.count == s.thumbW * s.thumbH * 4 else { return nil }
        // 房间缩略图：横向已在估计器翻好；轻微模糊后放到等距柱状图的正前方。
        let data = Data(s.thumbnail)
        let thumb = CIImage(bitmapData: data, bytesPerRow: s.thumbW * 4,
                            size: CGSize(width: s.thumbW, height: s.thumbH),
                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let patchW = extent.width * 0.28
        let patchH = extent.height * 0.38
        let patchRect = CGRect(x: extent.midX - patchW / 2, y: extent.midY - patchH / 2,
                               width: patchW, height: patchH)
        var patch = thumb
            .applyingGaussianBlur(sigma: 2.2)
            .cropped(to: thumb.extent)
            .transformed(by: CGAffineTransform(scaleX: patchW / CGFloat(s.thumbW), y: patchH / CGFloat(s.thumbH)))
            .transformed(by: CGAffineTransform(translationX: patchRect.minX, y: patchRect.minY))
        patch = patch.cropped(to: patchRect)
        patch = patch.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
            kCIInputMaskImageKey: mask,
        ])

        // 棚拍底子按房间曝光/色温微调；幅度克制，保持 Quick Look 的高光。
        let ev = log2(max(0.45, min(1.6, s.intensity))) * 0.45
        var baseTinted = base.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        let w = max(-1, min(1, s.warmth)) * 0.09
        baseTinted = baseTinted.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(1 + w), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(1 - w), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let out = patch.composited(over: baseTinted).cropped(to: extent)
        return context.createCGImage(out, from: extent, format: .RGBAh, colorSpace: colorSpace)
    }
}
