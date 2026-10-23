// 液態玻璃（光學版）：照 iOS 26 鎖定畫面時間／HomeView 錶面那種玻璃字的做法，在 GPU 上算，不靠視窗伺服器合成
// （桌寵的螢幕內容是離屏畫成貼圖再貼到 3D 上，SwiftUI 的 glassEffect 用不上）。
//
// 1. 字形先畫成遮罩（畫布像素），用 MPS 的歐氏距離轉換算出「有號距離場」：字裡為正、字外為負（像素）。
// 2. Metal kernel 把距離場當成玻璃的厚度：邊緣一圈 bezel 是凸起的圓弧（h = √(1−(1−d/B)²)），
//    表面法線 = 高度的梯度；背景依法線往內偏（折射，邊上偏得多＝邊緣把背景壓縮、拉彎），
//    RGB 三個通道偏移量略有不同（色散）；中間平的部分幾乎透明、只霜一點點。
// 3. 光從左上：沿邊緣的法線對著光就亮（鏡面高光），背對光的右下內緣壓一點暗；最外緣半像素反鋸齒。
// 結果是一張透明底的圖，蓋在錶面背景上。島錶面一分鐘才換一次數字，所以每分鐘算一次；Flow 背景在動就每次算（GPU 幾毫秒）。

import AppKit
import CoreImage
import Metal
import MetalPerformanceShaders

struct LiquidGlassParams {
    var bezel: Float = 0.11          // 斜面寬度（相對字高）
    var refraction: Float = 0.9      // 折射強度（邊緣最大偏移 ≈ refraction × bezel）
    var dispersion: Float = 0.06     // 色散：R、B 通道偏移量的差
    var frost: Float = 0.16          // 中間的霜白
    var blurMix: Float = 0.75        // 透出來的背景用模糊版的比例（0 清透、1 全霧）
    var specular: Float = 0.9        // 鏡面高光強度
    var rimLight: Float = 0.55       // 最外緣一圈細亮線
    var shade: Float = 0.22          // 背光內緣的暗
    var tint: SIMD4<Float> = .zero   // 額外染色（premultiplied）
    var saturation: Float = 1.25     // 透出背景的飽和度

    static let portrait = LiquidGlassParams()
    /// Flow 的泡泡字：更厚、更彎、更亮
    static let bubble = LiquidGlassParams(bezel: 0.24, refraction: 0.85, dispersion: 0.07, frost: 0.06, blurMix: 0.45,
                                          specular: 1.0, rimLight: 0.7, shade: 0.28, saturation: 1.45)
}

final class LiquidGlass {
    static let shared = LiquidGlass()
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLComputePipelineState?
    private let ci: CIContext?
    private var sdfCache: (key: String, din: MTLTexture, dout: MTLTexture)?

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        ci = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        if let device {
            do {
                let lib = try device.makeLibrary(source: Self.source, options: nil)
                if let fn = lib.makeFunction(name: "liquidGlass") { pipeline = try device.makeComputePipelineState(function: fn) }
            } catch { log("liquid glass shader: \(error)") }
        }
    }
    var available: Bool { pipeline != nil }

    /// 畫一組字形（同一個玻璃）：path 是 1024 邏輯座標（左上原點）；backdrop／frosted 是整張 1024² 背景（任意像素大小）。
    /// 回傳透明底的圖與它在 1024 座標的位置；失敗回 nil（呼叫端退回 CG 版玻璃）。
    func render(path: CGPath, key: String? = nil, scale sc: CGFloat, backdrop: CGImage, frosted: CGImage?, params p: LiquidGlassParams)
        -> (image: CGImage, rect: CGRect)? {
        guard let device, let queue, let pipeline, let ci else { return nil }
        let ink = path.boundingBoxOfPath
        guard ink.width > 2, ink.height > 2 else { return nil }
        let pad = ink.height * 0.04 + 6
        let rect = ink.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024)).integral
        let w = Int((rect.width * sc).rounded(.up)), h = Int((rect.height * sc).rounded(.up))
        guard w > 4, h > 4, w <= 8192, h <= 8192 else { return nil }

        func tex(_ fmt: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = usage; d.storageMode = .shared
            return device.makeTexture(descriptor: d)
        }
        guard let out = tex(.rgba8Unorm, [.shaderRead, .shaderWrite]) else { return nil }

        // 2. 背景：把整張背景裁到 rect、縮放到 w×h，渲染成兩張 RGBA 貼圖（清的與霧的）
        func bgTexture(_ img: CGImage) -> MTLTexture? {
            guard let t = tex(.rgba8Unorm, [.shaderRead, .shaderWrite]) else { return nil }
            let full = CIImage(cgImage: img)
            let k = full.extent.width / 1024
            // CIImage 左下原點：rect（左上原點）換成 CI 座標
            let crop = CGRect(x: rect.minX * k, y: (1024 - rect.maxY) * k, width: rect.width * k, height: rect.height * k)
            let sx = CGFloat(w) / crop.width, sy = CGFloat(h) / crop.height
            var im = full.clampedToExtent().cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            if p.saturation != 1 { im = im.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: p.saturation]) }
            // Metal 貼圖第 0 列在上，CI 的 y 往上：翻一次
            im = im.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(h)))
            ci.render(im, to: t, commandBuffer: nil, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return t
        }
        guard let bgClear = bgTexture(backdrop), let bgFrost = bgTexture(frosted ?? backdrop) else { return nil }

        // 3. 距離：字外到最近字形像素、字裡到最近字外像素（同一組字形只算一次，Flow 每幀只重跑最後一步）
        guard let cb = queue.makeCommandBuffer() else { return nil }
        let sdfKey = key.map { "\($0)|\(w)x\(h)|\(rect)" }
        let din: MTLTexture, dout: MTLTexture
        if let sdfKey, let c = sdfCache, c.key == sdfKey { din = c.din; dout = c.dout } else {
            // 1. 遮罩（R8）：字形填白（只在距離場沒快取時畫）
            var mask = [UInt8](repeating: 0, count: w * h)
            guard let mctx = CGContext(data: &mask, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            mctx.translateBy(x: 0, y: CGFloat(h)); mctx.scaleBy(x: sc, y: -sc); mctx.translateBy(x: -rect.minX, y: -rect.minY)
            mctx.addPath(path); mctx.setFillColor(gray: 1, alpha: 1); mctx.fillPath()
            var inv = mask.map { 255 &- $0 }
            guard let mIn = tex(.r8Unorm, [.shaderRead]), let mOut = tex(.r8Unorm, [.shaderRead]),
                  let dIn = tex(.r32Float, [.shaderRead, .shaderWrite]), let dOut = tex(.r32Float, [.shaderRead, .shaderWrite]) else { return nil }
            mIn.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &mask, bytesPerRow: w)
            mOut.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &inv, bytesPerRow: w)
            let edt = MPSImageEuclideanDistanceTransform(device: device)
            edt.encode(commandBuffer: cb, sourceTexture: mIn, destinationTexture: dOut)   // 字外的點：到字的距離
            edt.encode(commandBuffer: cb, sourceTexture: mOut, destinationTexture: dIn)   // 字裡的點：到字外的距離
            din = dIn; dout = dOut
            if let sdfKey { sdfCache = (sdfKey, dIn, dOut) }
        }
        guard let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipeline)
        for (i, t) in [bgClear, bgFrost, din, dout, out].enumerated() { enc.setTexture(t, index: i) }
        var u = Uniforms(bezel: max(2, p.bezel * Float(ink.height * sc)), refraction: p.refraction, dispersion: p.dispersion,
                         frost: p.frost, blurMix: p.blurMix, specular: p.specular, rimLight: p.rimLight, shade: p.shade, tint: p.tint)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()

        // 4. 讀回成 CGImage（premultiplied RGBA，第 0 列在上＝CGImage 的上緣）
        var px = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return (img, rect)
    }

    private struct Uniforms {
        var bezel: Float, refraction: Float, dispersion: Float, frost: Float, blurMix: Float
        var specular: Float, rimLight: Float, shade: Float
        var tint: SIMD4<Float>
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float bezel; float refraction; float dispersion; float frost; float blurMix; float specular; float rimLight; float shade; float4 tint; };
    // 有號距離（像素）：字裡為正
    static float sd(texture2d<float, access::read> din, texture2d<float, access::read> dout, int2 p) {
        int2 q = clamp(p, int2(0), int2(din.get_width() - 1, din.get_height() - 1));
        float a = din.read(uint2(q)).r, b = dout.read(uint2(q)).r;
        return a > 0.0 ? a - 0.5 : -(b - 0.5);
    }
    kernel void liquidGlass(texture2d<float, access::sample> bg [[texture(0)]],
                            texture2d<float, access::sample> bgFrost [[texture(1)]],
                            texture2d<float, access::read> din [[texture(2)]],
                            texture2d<float, access::read> dout [[texture(3)]],
                            texture2d<float, access::write> out [[texture(4)]],
                            constant U& u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint W = out.get_width(), H = out.get_height();
        if (gid.x >= W || gid.y >= H) return;
        int2 p = int2(gid);
        float d = sd(din, dout, p);
        float cover = clamp(d + 0.5, 0.0, 1.0);          // 邊緣反鋸齒
        if (cover <= 0.0) { out.write(float4(0.0), gid); return; }
        // 梯度（指向字的內部）：歐氏距離轉換逐像素的梯度很碎（斜面上會出現放射狀細紋），
        // 用半徑跟斜面寬成比例的 Sobel 取平均，法線才平順
        int R = max(1, int(u.bezel * 0.14));
        float a00 = sd(din, dout, p + int2(-R, -R)), a10 = sd(din, dout, p + int2(0, -R)), a20 = sd(din, dout, p + int2(R, -R));
        float a01 = sd(din, dout, p + int2(-R, 0)),                                         a21 = sd(din, dout, p + int2(R, 0));
        float a02 = sd(din, dout, p + int2(-R, R)), a12 = sd(din, dout, p + int2(0, R)),  a22 = sd(din, dout, p + int2(R, R));
        float gx = (a20 + 2.0 * a21 + a22) - (a00 + 2.0 * a01 + a02);
        float gy = (a02 + 2.0 * a12 + a22) - (a00 + 2.0 * a10 + a20);
        float2 g = float2(gx, gy); float gl = length(g); float2 n2 = gl > 1e-4 ? g / gl : float2(0.0);
        // 表面高度：凸 squircle h = (1 − (1 − t)⁴)^¼——頂面比圓弧更平、邊緣更陡（Apple 玻璃的輪廓）
        float B = u.bezel;
        float t = clamp(d / B, 0.0, 1.0);
        float s = 1.0 - t;
        float hgt = pow(max(1e-5, 1.0 - s * s * s * s), 0.25);
        float dh = (s * s * s) / max(0.02, pow(max(1e-5, 1.0 - s * s * s * s), 0.75));   // dh/dt
        float slope = min(dh, 8.0);
        // 折射（Snell，n = 1.5，光垂直射入）：法線傾角 θi＝atan(斜率)，折射後偏離 θi − θt，
        // 位移 ∝ 厚度 × tan(θi − θt)，往字的內部取樣（邊緣把背景壓縮、彎進來）。三通道用不同折射率＝色散。
        float thi = atan(slope / B * (B * 0.9));
        float2 uv = float2(p) + 0.5;
        constexpr sampler smp(coord::pixel, address::clamp_to_edge, filter::linear);
        float3 col;
        float nR = 1.5 * (1.0 - u.dispersion), nG = 1.5, nB = 1.5 * (1.0 + u.dispersion);
        float ns[3] = { nR, nG, nB };
        // 邊緣清楚、中間霧：越靠內越用模糊版
        float blurW = u.blurMix * smoothstep(0.0, 1.0, t);
        for (int c = 0; c < 3; c++) {
            float tht = asin(clamp(sin(thi) / ns[c], -1.0, 1.0));
            float shift = tan(thi - tht) * B * u.refraction * hgt * 1.6;
            float2 q = uv + n2 * shift;
            float a = bg.sample(smp, q)[c], fz = bgFrost.sample(smp, q)[c];
            col[c] = mix(a, fz, blurW);
        }
        // 霜白：中間淡淡一層
        col = mix(col, float3(1.0), u.frost * (0.35 + 0.65 * t));
        // 菲涅耳：越貼邊越亮（掠射角反射多）
        float fres = pow(1.0 - hgt, 3.0) * 0.35 * u.specular;
        // 方向性高光：法線在 2D 的方向和光的夾角，sin(2θ) 兩側對稱（左上強、右下弱）
        float2 Ld = normalize(float2(-0.6, -0.8));
        float cosA = dot(-n2, Ld);
        float glare = pow(max(0.0, cosA), 6.0) * 1.0 + pow(max(0.0, -cosA), 6.0) * 0.45;
        float spec = glare * u.specular * (1.0 - hgt) * 1.4;
        // 背光內緣壓暗
        float shade = u.shade * max(0.0, -cosA) * (1.0 - hgt) * 0.8;
        // 最外緣半像素的亮邊
        float rim = (1.0 - smoothstep(0.0, 1.4, d)) * u.rimLight * (0.35 + 0.65 * max(0.0, cosA));
        col = col * (1.0 - shade) + spec + fres + rim;
        col = clamp(col + u.tint.rgb * u.tint.a, 0.0, 1.0);
        out.write(float4(col * cover, cover), gid);
    }
    """
}
