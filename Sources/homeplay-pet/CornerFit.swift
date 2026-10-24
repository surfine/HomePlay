// CarPlay 圓角與機身同心：「學習連線」那一次的畫面處理。
// 平常的連線由接收器宣告同心的安全區，iOS 自己內收、桌布鋪滿，這裡什麼都不做（零拷貝原樣交回）。
// 第一次、或手機換了 iOS 版本時，接收器那一次改宣告 cornerMasks 來學 iOS 的圓角（不能同時帶安全區）；
// 那一次 iOS 會把 UI 排到畫面邊，這裡照下面的做法縮進同心位置、外圈補黑，只有這一次。以下是當時的設計：
//
// 問題：機身螢幕的圓角（照 USDZ 顯示面網格量）比 iOS 給 CarPlay 畫的圓角大得多，而且每一版 iOS 的圓角都不一樣，
// 卡片、Dock 的四個角於是跟機身各彎各的。
//
// 做法（長效，不寫死任何一版 iOS 的半徑）：
// 1. 接收器在 /info 宣告 cornerMasks。iOS 26 起手機會照它自己這一版的設計，把螢幕圓角輪廓
//    （topLeftCornerMask，8 位元灰階 PNG，亮＝保留）送過來，並把 UI 排成跟這個輪廓同心。
// 2. 這裡量那張遮罩的圓角（對角線上覆蓋率過半的位置），算出縮放比例 k，讓 iOS 的輪廓縮進去之後
//    正好落在「機身螢幕輪廓往內平移 d」的位置：k·m = R − d、d = (1 − k)·W/2 ⇒ k = (W/2 − R)/(W/2 − m)。
//    同心的形狀一路往內推，iOS 照它的輪廓排的卡片也就跟機身同心。
// 3. GPU 一個小 pass：畫面縮 k 倍置中、四角照 iOS 的遮罩裁掉，外圈是一圈等寬的黑邊（像加厚的螢幕黑框）。
//    觸控照同一個 k 反算。
// 手機沒提議 cornerMasks（舊 iOS）：用上次量到的遮罩（沒有就用預設值）退而求其次。
// 設定 › CarPlay 可以關掉（寫 carplay-display.json，接收器下次連線改回舊的 safeArea 宣告）。

import AppKit
import Metal

final class CornerFit {
    static let shared = CornerFit()

    /// 機身螢幕：顯示面網格在 UV 裡對角線方向的內縮（佔寬度；量自 apple-homeview.usdz 的 RFkcSjAtJLGqwDA）
    static let bodyDiag = 0.0398
    /// 對角線內縮 → 等效圓角半徑：t = r·(1 − 1/√2)
    static let diagPerRadius = 1 - 1 / 2.0.squareRoot()
    /// 手機沒送遮罩、也沒量過時的假設（iOS 26 在 1088 px 畫面上約 40 px 的圓角）
    static let fallbackMaskDiag = 0.011
    private static let lastDiagKey = "HomePlayCornerMaskDiag"

    /// iOS 遮罩的對角內縮（佔畫面寬度）；nil＝沒啟用（關掉、或接收器沒協商）
    private(set) var maskDiag: Double?
    private(set) var negotiated: Bool?
    private var maskTexture: MTLTexture?
    private var maskSidePx = 0          // 遮罩邊長（畫面像素）
    private var pipeline: MTLComputePipelineState?
    private var outputs: [MTLTexture] = []
    private var outIndex = 0
    private var queue: MTLCommandQueue?
    var onChange: (() -> Void)?

    // MARK: 幾何

    /// 縮放比例 k：iOS 的圓角（對角內縮 t）縮進去後跟機身同心。t 越小（iOS 圓角越小），要縮得越多；比機身還圓就不縮。
    static func scale(maskDiag t: Double) -> Double {
        let R = bodyDiag / diagPerRadius, m = t / diagPerRadius
        guard m < R else { return 1 }
        return max(0.7, min(1, (0.5 - R) / (0.5 - m)))
    }
    /// 目前的 k（1＝不處理）
    var scale: Double { maskDiag.map(Self.scale(maskDiag:)) ?? 1 }

    /// 螢幕 uv（0…1）→ 畫面 uv：反算縮放；落在黑邊上回 nil
    func toVideo(u: Double, v: Double) -> (Double, Double)? {
        let k = scale
        guard k < 1 else { return (u, v) }
        let x = (u - 0.5) / k + 0.5, y = (v - 0.5) / k + 0.5
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x, y)
    }

    // MARK: 接收器訊息

    /// {"type":"cornerMask","negotiated":Bool,"png":base64?}
    func handle(_ o: [String: Any], videoWidth: Int, device: MTLDevice?) {
        guard ConcentricCorners.enabled, o["learning"] as? Bool ?? true else { reset(); return }
        let neg = o["negotiated"] as? Bool ?? false
        negotiated = neg
        if let b64 = o["png"] as? String, let png = Data(base64Encoded: b64), let dev = device,
           let m = Self.measure(png: png, device: dev) {
            maskTexture = m.texture; maskSidePx = m.side
            let w = Double(max(1, videoWidth))
            maskDiag = m.diagPx / w
            UserDefaults.standard.set(maskDiag, forKey: Self.lastDiagKey)
            log(String(format: "cornerMask: side %d px, diag %.1f px → %.4f W, k=%.3f", m.side, m.diagPx, maskDiag ?? 0, scale))
        } else if !neg {
            // 舊 iOS：沒有遮罩，用上次量到的（或預設）；四角用一個同心的圓弧裁
            let last = UserDefaults.standard.double(forKey: Self.lastDiagKey)
            maskDiag = last > 0 ? last : Self.fallbackMaskDiag
            maskTexture = nil
            log(String(format: "cornerMask: 手機沒提議，退回 diag %.4f W，k=%.3f", maskDiag ?? 0, scale))
        } else if maskDiag == nil {
            // 協商了、圖還沒到：先用上次的值，圖到了再換
            let last = UserDefaults.standard.double(forKey: Self.lastDiagKey)
            maskDiag = last > 0 ? last : Self.fallbackMaskDiag
        }
        onChange?()
    }

    func reset() { maskDiag = nil; negotiated = nil; maskTexture = nil; onChange?() }

    /// 解遮罩：8 位元灰階（亮＝保留）。照 DiPlay 的做法看四個角哪個最暗，翻成「(0,0) 是被裁掉的那個角」；
    /// 對角線上覆蓋率過半的位置就是輪廓在對角線上的內縮。
    static func measure(png: Data, device: MTLDevice) -> (texture: MTLTexture, side: Int, diagPx: Double)? {
        guard let src = NSBitmapImageRep(data: png)?.cgImage else { return nil }
        let side = src.width
        guard side >= 2, side <= 512, src.height == side else { return nil }
        var px = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: side, height: side))
        // px 第 0 列是圖的最上面一列
        let tl = px[0], tr = px[side - 1], bl = px[(side - 1) * side], br = px[side * side - 1]
        let flipX = min(tr, br) < min(tl, bl), flipY = min(bl, br) < min(tl, tr)
        var norm = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side {
            let sx = flipX ? side - 1 - x : x, sy = flipY ? side - 1 - y : y
            norm[y * side + x] = px[sy * side + sx]
        } }
        // 對角線：覆蓋率第一次過半的位置（線性內插）
        var diag = Double(side)
        for i in 0..<side where norm[i * side + i] >= 128 {
            if i == 0 { diag = 0; break }
            let a = Double(norm[(i - 1) * side + (i - 1)]), b = Double(norm[i * side + i])
            diag = Double(i - 1) + (128 - a) / max(1, b - a) + 0.5
            break
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: norm, bytesPerRow: side)
        return (tex, side, diag)
    }

    // MARK: GPU

    /// 每幀：k < 1 時把畫面縮進同心位置、四角裁掉、外圈補黑；不需要就原樣交回（零拷貝）
    func apply(_ src: MTLTexture) -> MTLTexture {
        let k = scale
        guard k < 0.999, let pso = pipeline(src.device) else { return src }
        if queue == nil { queue = src.device.makeCommandQueue() }
        guard let queue else { return src }
        if outputs.count != 2 || outputs[0].width != src.width || outputs[0].height != src.height || outputs[0].pixelFormat != src.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: src.width, height: src.height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            outputs = (0..<2).compactMap { _ in src.device.makeTexture(descriptor: d) }
            guard outputs.count == 2 else { return src }
        }
        outIndex ^= 1
        let dst = outputs[outIndex]
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return src }
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0); enc.setTexture(maskTexture ?? src, index: 1); enc.setTexture(dst, index: 2)
        // k、遮罩邊長（畫面像素）、有沒有遮罩、沒遮罩時用的同心圓弧半徑（畫面像素，縮放前）
        let m = (maskDiag ?? Self.fallbackMaskDiag) / Self.diagPerRadius * Double(src.width)
        var u = SIMD4<Float>(Float(k), Float(maskSidePx), maskTexture == nil ? 0 : 1, Float(m))
        enc.setBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (src.width + 15) / 16, height: (src.height + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()   // RealityKit 在同一個裝置上取樣，命令佇列的順序保證畫完才用
        return dst
    }

    private func pipeline(_ dev: MTLDevice) -> MTLComputePipelineState? {
        if let pipeline { return pipeline }
        do {
            let lib = try dev.makeLibrary(source: Self.source, options: nil)
            guard let fn = lib.makeFunction(name: "cornerFit") else { return nil }
            pipeline = try dev.makeComputePipelineState(function: fn)
        } catch { log("cornerFit shader: \(error)") }
        return pipeline
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void cornerFit(texture2d<float, access::sample> src [[texture(0)]],
                          texture2d<float, access::sample> mask [[texture(1)]],
                          texture2d<float, access::write> dst [[texture(2)]],
                          constant float4& u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        float W = dst.get_width(), H = dst.get_height();
        if (gid.x >= uint(W) || gid.y >= uint(H)) return;
        constexpr sampler lin(filter::linear, address::clamp_to_edge);
        float2 p = (float2(gid) + 0.5) / float2(W, H);
        float2 q = (p - 0.5) / u.x + 0.5;
        if (any(q < 0.0) || any(q > 1.0)) { dst.write(float4(0, 0, 0, 1), gid); return; }
        float3 c = src.sample(lin, q).rgb;
        float2 px = q * float2(W, H);
        float2 corner = min(px, float2(W, H) - px);          // 離最近的兩條邊多遠（畫面像素）
        float cov = 1.0;
        if (u.z > 0.5) {
            if (corner.x < u.y && corner.y < u.y) cov = mask.sample(lin, corner / u.y).r;
        } else {
            float r = u.w;                                     // 沒遮罩：同心圓弧
            if (corner.x < r && corner.y < r) cov = clamp(r - length(float2(r) - corner) + 0.5, 0.0, 1.0);
        }
        dst.write(float4(c * cov, 1.0), gid);
    }
    """
}
