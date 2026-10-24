// 摄像头房间光估计（macOS 没有 ARKit Light Estimation）。
//
// 用前置摄像头的一帧估计：平均亮度、最亮区域的颜色（色温）、最亮区域的方向。
// 画面只在本进程内降采样成 48×32 缩略图 + 6×4 亮度网格，不落盘、不录制。
// 之后由 RoomEnvironment 把缩略图叠进 Quick Look 的 object-mode EXR 环境里。
import AppKit
import AVFoundation
import CoreGraphics
import Vision

struct RoomLightSample {
    var intensity: Float = 0.65       // 相对强度，0.4…1.5
    var warmth: Float = 0             // -1 冷 … +1 暖
    var cct: Float = 6500             // 估计色温（日志/灯色用）
    var direction = SIMD3<Float>(0, 0.5, 1)   // 从机身指向光源
    var azimuth: Float = 0            // 弧度，+右
    var elevation: Float = 0.4        // 弧度，+上
    var confidence: Float = 0
    var sceneOutdoor: Float = 0      // Vision 场景分类（Neural Engine）
    var sceneIndoor: Float = 0
    var thumbnail: [UInt8] = []       // 48×32 RGBA，已横向翻成“世界 +X 在右”
    var thumbW = 48
    var thumbH = 32
    static let neutral = RoomLightSample()
}

final class RoomLightEstimator {
    var onSample: ((RoomLightSample) -> Void)?   // 主线程

    private var lastProcess = 0.0
    private var lastLog = 0.0
    private var lastClassify = 0.0
    private var sceneOutdoor: Float = 0
    private var sceneIndoor: Float = 0
    private var loggedFormat = false
    private var smooth = RoomLightSample.neutral
    private var lastSampleAt = CACurrentMediaTime()
    private var hasSample = false

    /// 在 GazeTracker 的采集队列上调用（串行）。
    private var sampleInterval: Double {
        let p = ProcessInfo.processInfo
        return (p.isLowPowerModeEnabled || p.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue) ? 1.0 : 0.28
    }

    func ingest(_ buffer: CVPixelBuffer, at now: Double) {
        guard now - lastProcess >= sampleInterval else { return }
        lastProcess = now

        // 场景分类走 Vision/Neural Engine：1 Hz 就够，用来判断“窗外日光/户外”还是室内，
        // 对色温/环境做一个很小的先验，避免相机 AWB 把窗光估得过暖。
        if now - lastClassify >= 1.0 {
            lastClassify = now
            let req = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
            if (try? handler.perform([req])) != nil, let obs = req.results {
                let outdoor = Self.best(obs, ["outdoor", "sky", "daylight", "sunlight", "nature", "landscape"])
                let indoor = Self.best(obs, ["indoor", "room", "office", "living room", "bedroom", "interior"])
                sceneOutdoor += (outdoor - sceneOutdoor) * 0.5
                sceneIndoor += (indoor - sceneIndoor) * 0.5
                let top = obs.prefix(3).map { String(format: "%@:%.2f", $0.identifier, $0.confidence) }.joined(separator: ",")
                appendDiag("roomlight.log", String(format: "scene out=%.2f in=%.2f [%@]", outdoor, indoor, top))
            }
        }

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        if !loggedFormat {
            loggedFormat = true
            appendDiag("roomlight.log", String(format: "pixel format %08x %dx%d", CVPixelBufferGetPixelFormatType(buffer), CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)))
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 8, h > 8 else { return }

        let tw = 48, th = 32
        var thumb = [UInt8](repeating: 0, count: tw * th * 4)
        var sumL: Float = 0, maxL: Float = 0
        var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0
        for ty in 0..<th {
            let sy = min(h - 1, (ty * 2 + 1) * h / (th * 2))
            for tx in 0..<tw {
                let sx = min(w - 1, (tx * 2 + 1) * w / (tw * 2))
                let i = sy * row + sx * 4
                let b = Float(base[i]) / 255, g = Float(base[i + 1]) / 255, r = Float(base[i + 2]) / 255
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sumL += l; if l > maxL { maxL = l }
                sumR += r; sumG += g; sumB += b
                // 缩略图横向翻转：摄像头里坐在画面左边的人/窗，对应世界 +X。
                let o = (ty * tw + (tw - 1 - tx)) * 4
                thumb[o] = UInt8(min(255, r * 255)); thumb[o + 1] = UInt8(min(255, g * 255))
                thumb[o + 2] = UInt8(min(255, b * 255)); thumb[o + 3] = 255
            }
        }
        let avg = sumL / Float(tw * th)
        let total = Float(tw * th)
        let avgR = sumR / total, avgG = sumG / total, avgB = sumB / total

        // 6×4 亮度网格，找最亮区域（窗/灯）的加权中心。
        var grid = [Float](repeating: 0, count: 24)
        for gy in 0..<4 {
            for gx in 0..<6 {
                var s: Float = 0, n: Float = 0
                for y in (gy * th / 4)..<((gy + 1) * th / 4) {
                    for x in (gx * tw / 6)..<((gx + 1) * tw / 6) {
                        let o = (y * tw + x) * 4
                        s += 0.2126 * Float(thumb[o]) + 0.7152 * Float(thumb[o + 1]) + 0.0722 * Float(thumb[o + 2])
                        n += 1
                    }
                }
                grid[gy * 6 + gx] = n > 0 ? s / n / 255 : 0
            }
        }
        let peak = grid.max() ?? 0
        var cx: Float = 0, cy: Float = 0, weight: Float = 0
        for gy in 0..<4 {
            for gx in 0..<6 {
                let v = grid[gy * 6 + gx]
                guard v >= max(0.02, peak * 0.78) else { continue }
                let wgt = v * v
                cx += (Float(gx) + 0.5) * wgt
                cy += (Float(gy) + 0.5) * wgt
                weight += wgt
            }
        }
        if weight <= 0 { cx = 3; cy = 2; weight = 1 }
        cx /= weight; cy /= weight
        let bx = (cx / 6 - 0.5) * 2          // 画面左 -1 … 右 +1
        let by = (0.5 - cy / 4) * 2          // 上 +1 … 下 -1

        // 最亮区域的平均色 → 色温/冷暖（相机 AWB 会消掉一部分；这里取残余）。
        var br: Float = 0, bg: Float = 0, bb: Float = 0, bn: Float = 0
        for gy in 0..<4 {
            for gx in 0..<6 where grid[gy * 6 + gx] >= max(0.02, peak * 0.78) {
                for y in (gy * th / 4)..<((gy + 1) * th / 4) {
                    for x in (gx * tw / 6)..<((gx + 1) * tw / 6) {
                        let o = (y * tw + x) * 4
                        br += Float(thumb[o]); bg += Float(thumb[o + 1]); bb += Float(thumb[o + 2]); bn += 1
                    }
                }
            }
        }
        if bn > 0 {
            br /= bn * 255; bg /= bn * 255; bb /= bn * 255
        } else {
            br = 0.7; bg = 0.7; bb = 0.7
        }
        // 整张画面的平均色更接近房间反射，不会把「一张脸」当成灯。最亮区域只占 25%。
        let cr = avgR * 0.75 + br * 0.25, cg = avgG * 0.75 + bg * 0.25, cb = avgB * 0.75 + bb * 0.25
        // sRGB → 线性 → xy → McCamy CCT。
        func lin(_ c: Float) -> Float { powf(max(0, c), 2.2) }
        let lr = lin(cr), lg = lin(cg), lb = lin(cb)
        let X = 0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb
        let Y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let Z = 0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb
        let denom = X + Y + Z
        let chromaX = denom > 1e-5 ? X / denom : 0.3127
        let chromaY = denom > 1e-5 ? Y / denom : 0.3290
        let n = (chromaX - 0.3320) / max(1e-4, 0.1858 - chromaY)
        var cct = max(2000, min(10000, 449 * powf(n, 3) + 3525 * powf(n, 2) + 6823.3 * n + 5520.33))
        // 窗外日光/户外场景：相机 AWB 常把窗光拉暖；用分类结果把色温下限提一点。
        if sceneOutdoor > 0.55 && sceneIndoor < 0.30 {
            cct = max(cct, 5200)
        }
        let warmth = max(-1, min(1, (6500 - cct) / 3500))

        // 相对强度：平均亮度 + 亮暗差（窗光越强，主光越明显）。
        let k = max(0, min(1, (avg - 0.10) / 0.55))
        let contrast = max(0, peak - avg)
        let intensity = max(0.40, min(1.50, 0.45 + 0.90 * k + min(0.25, contrast * 0.8)))

        let az = bx * 0.55                  // 约 ±31°
        let el = max(-0.15, min(1.0, 0.35 + by * 0.35))
        let dir = simd_normalize(SIMD3<Float>(-bx * 0.55, el, 1.0))

        var s = RoomLightSample()
        s.intensity = intensity
        s.warmth = warmth
        s.cct = cct
        s.direction = dir
        s.azimuth = az
        s.elevation = el
        s.confidence = max(0.15, min(1, peak))
        s.sceneOutdoor = sceneOutdoor
        s.sceneIndoor = sceneIndoor
        s.thumbnail = thumb
        defer { lastSampleAt = CACurrentMediaTime() }
        if !hasSample {
            smooth = s; hasSample = true
        } else {
            // 依時間平滑（時間常數 0.8 s）：相機 2、5 或 15 fps 都一樣快地跟上開關燈
            let now = CACurrentMediaTime(), dt = max(0.02, min(1.5, now - lastSampleAt))
            let a = Float(1 - exp(-dt / 0.8))
            smooth.intensity += (s.intensity - smooth.intensity) * a
            smooth.warmth += (s.warmth - smooth.warmth) * a
            smooth.cct += (s.cct - smooth.cct) * a
            smooth.direction = simd_normalize(smooth.direction + (s.direction - smooth.direction) * a)
            smooth.azimuth += (s.azimuth - smooth.azimuth) * a
            smooth.elevation += (s.elevation - smooth.elevation) * a
            smooth.confidence += (s.confidence - smooth.confidence) * a
            smooth.thumbnail = s.thumbnail
        }
        let out = smooth
        DispatchQueue.main.async { [weak self] in self?.onSample?(out) }
        if now - lastLog > 1.5 {
            lastLog = now
            appendDiag("roomlight.log", String(format: "light int=%.2f cct=%.0fK warm=%.2f az=%.2f el=%.2f peak=%.2f avg=%.2f", out.intensity, out.cct, out.warmth, out.azimuth, out.elevation, peak, avg))
        }
    }

    private static func best(_ obs: [VNClassificationObservation], _ keys: [String]) -> Float {
        var best: Float = 0
        for o in obs {
            let id = o.identifier.lowercased()
            if keys.contains(where: { id.contains($0) }) { best = max(best, o.confidence) }
        }
        return best
    }
}
