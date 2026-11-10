// SDF 玻璃字形（實驗，預設關）：照官方玻璃字的做法（docs/hv-reference/glass_pipeline.txt），由字形 alpha 出整片玻璃。
//
// 1. 字形 alpha（2× 解析度、不抗鋸齒的二值遮罩）→ 有號距離場（MPS 歐氏距離轉換，字裡為正）；
//    每個輸出像素取 2×2 子像素距離的平均＝平滑的亞像素距離，邊緣覆蓋率由它算（斜邊不出階梯）。
// 2. 靜態層（字形一分鐘才換）：每個像素存「背景要往哪裡、偏多少」與「邊緣高光」——
//    ① 位移沿 SDF 梯度（法線，往字裡），只在邊緣帶（0–12 px）內，量跟帶內深度成正比：邊上最多、帶外歸零（隨距離單調）；
//    ② 高光由平滑 alpha（smoothstep）的導數算：導數就是邊緣法線，跟單一主光（左上）點積；
//       官方剖面是一圈柔亮帶（四周都有，左上最亮）、右下只略暗，所以亮度＝環境量＋方向量。
// 3. 每幀只做：背景照靜態層位移取樣＋合成；
//    字裡用較強模糊後的背景（平滑霧面），清楚的背景只在邊緣帶裡透出一點；
//    ③ 字色深淺照底色亮度（只取樣一次的平均）調：暗底提亮、亮底壓深；
//    字外 0.5–2 px 一圈低不透明度的細暗線（官方字外那條線）；
//    ④ 底越亮白色高光越不明顯，字外的可讀性陰影跟著加深（Face.drawNumeralSDFGlass 畫）。
// 結果是透明底的圖；同一組字形、同一張背景、同樣染色時直接用上一張（島／照片／世界的背景一分鐘內不變）。
//
// 切換：--numeral-glass sdf|system，或隱藏偏好 HomePlayNumeralGlass（defaults write … HomePlayNumeralGlass sdf）；預設 system＝現行做法。

import AppKit
import CoreImage
import Metal
import MetalPerformanceShaders

/// 大數字玻璃用哪條路：system＝現行（SystemGlass .portraitFrosted）、sdf＝這個檔案
enum NumeralGlassMode: String {
    case system, sdf
    nonisolated(unsafe) static var override: NumeralGlassMode?
    static let defaultsKey = "HomePlayNumeralGlass"
    static var current: NumeralGlassMode {
        override ?? UserDefaults.standard.string(forKey: defaultsKey).flatMap(NumeralGlassMode.init(rawValue:)) ?? .sdf   // 拍板 2026-11-07：SDF 轉正；偏好或旗標可切回 system
    }
}

/// 一組大數字最後怎麼畫（純函式，自檢用）
enum NumeralGlassRoute: Equatable {
    case solid, frostedSolid, system, sdf

    static func decide(mode: NumeralGlassMode, look: ClockLook, materialLookLinked: Bool,
                       reduceTransparency: Bool, reduceMotion: Bool, increaseContrast: Bool) -> NumeralGlassRoute {
        switch mode {
        case .system:   // 現行規則，一字不改
            return HPNumeralGlass.usesGlass(look: look, materialLookLinked: materialLookLinked,
                                            reduceTransparency: reduceTransparency, reduceMotion: reduceMotion) ? .system : .solid
        case .sdf:
            guard !increaseContrast,
                  HPNumeralGlass.usesGlass(look: look, materialLookLinked: materialLookLinked, reduceTransparency: false, reduceMotion: reduceMotion)
            else { return .solid }
            return reduceTransparency ? .frostedSolid : .sdf
        }
    }
}


struct GlyphGlassParams {
    // 照官方照片錶面 10:09 的「1」豎筆橫切剖面校（底 → 細暗線 −20 → 柔亮帶比字面 +13 → 字面比底 +35；右緣只略暗）
    var bezel: Float = 0.12      // 法線平滑半徑的參考（相對字高）
    var shift: Float = 0.02      // 邊上最大位移（相對字高）
    var band: Float = 12         // 位移／清楚背景只在這條邊緣帶裡（畫布 px）
    var rim: Float = 0.012       // 柔亮帶寬（相對字高）
    var frost: Float = 0.035     // 字裡霧面的模糊半徑（相對字高）
    var edgeSoft: Float = 0.006  // 邊緣帶透出的「清楚」背景也先輕模糊（相對字高）：顆粒被位移拉長會變成放射狀細紋
    var blurMix: Float = 1       // 霧面比例（0＝全用清楚背景，自檢用）
    var edgeBlur: Float = 0.7    // 邊緣帶上霧面至少佔多少
    var specular: Float = 0.18   // 亮帶
    var shade: Float = 0.25      // 背光側略暗
    var ambient: Float = 0.25    // 亮帶的環境量（四周都有一點）
    var liftDark: Float = 0.25   // 暗底提亮（拍板 2026-11-07：0.36 在世界錶面暗底上字面太亮）
    var darkenLight: Float = 0.06   // 亮底壓深（亮底上只壓一點，靠可讀性陰影分開）
    var lineAlpha: Float = 0.3   // 字外細暗線（官方剖面約比底暗 20%，跨兩個像素攤開後要 0.3）
    var lineCenter: Float = 1    // 細暗線中心在字外幾 px（畫布 px）
    var lineWidth: Float = 1     // 細暗線半寬（畫布 px）

    static let numeral = GlyphGlassParams()

    /// 底色亮度 → 字色往白（正）或往黑（負）的量
    func lift(luma: CGFloat) -> Float { let l = Float(max(0, min(1, luma))); return liftDark * (1 - l) - darkenLight * l }
    /// 可讀性陰影的濃度：白色高光在亮底上看不出來，底越亮陰影越深
    static func shadowAlpha(luma: CGFloat) -> CGFloat { 0.10 + 0.22 * max(0, min(1, (luma - 0.4) / 0.5)) }
}

final class GlyphGlass {
    static let shared = GlyphGlass()
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var geomPipe: MTLComputePipelineState?
    private var compPipe: MTLComputePipelineState?
    private let ci: CIContext?
    private var geomCache: (key: String, tex: MTLTexture)?
    private var outCache: (key: String, image: CGImage, rect: CGRect)?

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        ci = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        if let device {
            do {
                let lib = try device.makeLibrary(source: Self.source, options: nil)
                if let f = lib.makeFunction(name: "ggGeom") { geomPipe = try device.makeComputePipelineState(function: f) }
                if let f = lib.makeFunction(name: "ggComposite") { compPipe = try device.makeComputePipelineState(function: f) }
            } catch { log("glyph glass shader: \(error)") }
        }
    }
    var available: Bool { geomPipe != nil && compPipe != nil }

    /// path：1024 邏輯座標（左上原點）；backdrop／frosted：整張背景；luma：底色亮度（取樣一次）；
    /// key：字形的識別（nil＝不快取）；bezelHeight：單顆字高。回傳透明底的圖與位置
    func render(path: CGPath, key: String?, scale sc: CGFloat, backdrop: CGImage, frosted: CGImage?, luma: CGFloat,
                tint: NSColor?, params p: GlyphGlassParams = .numeral, bezelHeight: CGFloat? = nil) -> (image: CGImage, rect: CGRect)? {
        guard let device, let queue, let geomPipe, let compPipe, let ci else { return nil }
        let ink = path.boundingBoxOfPath
        guard ink.width > 2, ink.height > 2 else { return nil }
        let pad = ink.height * 0.04 + 6
        let rect = ink.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024)).integral
        let w = Int((rect.width * sc).rounded(.up)), h = Int((rect.height * sc).rounded(.up))
        guard w > 4, h > 4, w <= 4096, h <= 4096 else { return nil }
        let H = Float((bezelHeight ?? ink.height) * sc), S = Float(sc)
        var tintV = SIMD4<Float>.zero
        if let t = tint?.usingColorSpace(.sRGB) { tintV = SIMD4(Float(t.redComponent), Float(t.greenComponent), Float(t.blueComponent), Float(t.alphaComponent)) }
        let geomKey = key.map { "\($0)|\(w)x\(h)|\(rect)|\(H)|\(p.bezel),\(p.shift),\(p.band),\(p.rim),\(p.ambient)" }
        let outKey = geomKey.map { "\($0)|\(ObjectIdentifier(backdrop).hashValue)|\(frosted.map { ObjectIdentifier($0).hashValue } ?? 0)|\(tintV)|\(Int(luma * 1000))|\(p.frost),\(p.edgeSoft),\(p.blurMix),\(p.edgeBlur),\(p.specular),\(p.shade),\(p.liftDark),\(p.darkenLight),\(p.lineAlpha),\(p.lineCenter),\(p.lineWidth)" }
        if let outKey, let c = outCache, c.key == outKey { return (c.image, c.rect) }

        func tex(_ fmt: MTLPixelFormat, _ usage: MTLTextureUsage, _ tw: Int = 0, _ th: Int = 0) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: tw > 0 ? tw : w, height: th > 0 ? th : h, mipmapped: false)
            d.usage = usage; d.storageMode = .shared
            return device.makeTexture(descriptor: d)
        }
        guard let cb = queue.makeCommandBuffer() else { return nil }

        // 靜態層：字形 alpha（2×）→ SDF → 位移＋高光（字形不變就不重算）
        let geom: MTLTexture
        if let geomKey, let c = geomCache, c.key == geomKey { geom = c.tex } else {
            let w2 = w * 2, h2 = h * 2
            var mask = [UInt8](repeating: 0, count: w2 * h2)
            guard let mctx = CGContext(data: &mask, width: w2, height: h2, bitsPerComponent: 8, bytesPerRow: w2, space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            mctx.setShouldAntialias(false)   // 二值遮罩：距離場自己會給亞像素的平滑
            mctx.translateBy(x: 0, y: CGFloat(h2)); mctx.scaleBy(x: sc * 2, y: -sc * 2); mctx.translateBy(x: -rect.minX, y: -rect.minY)
            mctx.addPath(path); mctx.setFillColor(gray: 1, alpha: 1); mctx.fillPath()
            var inv = mask.map { 255 &- $0 }
            guard let mIn = tex(.r8Unorm, [.shaderRead], w2, h2), let mOut = tex(.r8Unorm, [.shaderRead], w2, h2),
                  let dIn = tex(.r32Float, [.shaderRead, .shaderWrite], w2, h2), let dOut = tex(.r32Float, [.shaderRead, .shaderWrite], w2, h2),
                  let g = tex(.rgba32Float, [.shaderRead, .shaderWrite]) else { return nil }
            mIn.replace(region: MTLRegionMake2D(0, 0, w2, h2), mipmapLevel: 0, withBytes: &mask, bytesPerRow: w2)
            mOut.replace(region: MTLRegionMake2D(0, 0, w2, h2), mipmapLevel: 0, withBytes: &inv, bytesPerRow: w2)
            let edt = MPSImageEuclideanDistanceTransform(device: device)
            edt.encode(commandBuffer: cb, sourceTexture: mIn, destinationTexture: dOut)
            edt.encode(commandBuffer: cb, sourceTexture: mOut, destinationTexture: dIn)
            guard let enc = cb.makeComputeCommandEncoder() else { return nil }
            enc.setComputePipelineState(geomPipe)
            enc.setTexture(dIn, index: 0); enc.setTexture(dOut, index: 1); enc.setTexture(g, index: 2)
            var u = GeomU(bezel: max(2, p.bezel * H), shift: p.shift * H, rim: max(1.5, p.rim * H), band: max(1, p.band * S), ambient: p.ambient)
            enc.setBytes(&u, length: MemoryLayout<GeomU>.stride, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
            geom = g
            if let geomKey { geomCache = (geomKey, g) }
        }

        // 每幀：背景裁到 rect（清楚的一張、較強模糊的一張），照靜態層位移取樣、合成
        func bgTexture(_ img: CGImage, blur: CGFloat) -> MTLTexture? {
            guard let t = tex(.rgba8Unorm, [.shaderRead, .shaderWrite]) else { return nil }
            let full = CIImage(cgImage: img)
            let k = full.extent.width / 1024
            let crop = CGRect(x: rect.minX * k, y: (1024 - rect.maxY) * k, width: rect.width * k, height: rect.height * k)
            var im = full.clampedToExtent().transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / crop.width, y: CGFloat(h) / crop.height))
            if blur > 0.5 { im = im.applyingGaussianBlur(sigma: Double(blur)) }   // 先模糊再裁：邊上不會變暗
            im = im.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(h)))
            ci.render(im, to: t, commandBuffer: nil, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return t
        }
        guard let bg = bgTexture(backdrop, blur: CGFloat(p.edgeSoft * H)), let bgB = bgTexture(frosted ?? backdrop, blur: CGFloat(p.frost * H)),
              let out = tex(.rgba8Unorm, [.shaderRead, .shaderWrite]), let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(compPipe)
        for (i, t) in [bg, bgB, geom, out].enumerated() { enc.setTexture(t, index: i) }
        var u = CompU(band: max(1, p.band * S), blurMix: p.blurMix, edgeBlur: p.edgeBlur, specular: p.specular, shade: p.shade, lift: p.lift(luma: luma),
                      lineA: p.lineAlpha, lineC: p.lineCenter * S, lineW: max(0.5, p.lineWidth * S), tint: tintV)
        enc.setBytes(&u, length: MemoryLayout<CompU>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        if let outKey { outCache = (outKey, img, rect) }
        return (img, rect)
    }

    private struct GeomU { var bezel: Float, shift: Float, rim: Float, band: Float, ambient: Float }
    private struct CompU {
        var band: Float, blurMix: Float, edgeBlur: Float, specular: Float, shade: Float, lift: Float
        var lineA: Float, lineC: Float, lineW: Float
        var tint: SIMD4<Float>
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct GeomU { float bezel; float shift; float rim; float band; float ambient; };
    struct CompU { float band; float blurMix; float edgeBlur; float specular; float shade; float lift; float lineA; float lineC; float lineW; float4 tint; };
    // 2× 子像素的有號距離（子像素單位）
    static float sd2(texture2d<float, access::read> din, texture2d<float, access::read> dout, int2 q) {
        q = clamp(q, int2(0), int2(din.get_width() - 1, din.get_height() - 1));
        float a = din.read(uint2(q)).r, b = dout.read(uint2(q)).r;
        return a > 0.0 ? a - 0.5 : -(b - 0.5);
    }
    // 輸出像素的平滑距離（輸出像素單位）：2×2 子像素平均、再除以 2
    static float so(texture2d<float, access::read> din, texture2d<float, access::read> dout, int2 p) {
        int2 q = p * 2;
        return 0.125 * (sd2(din, dout, q) + sd2(din, dout, q + int2(1, 0)) + sd2(din, dout, q + int2(0, 1)) + sd2(din, dout, q + int2(1, 1)));
    }
    static float al(texture2d<float, access::read> din, texture2d<float, access::read> dout, int2 p, float rim) {
        return smoothstep(0.0, rim, so(din, dout, p));   // 平滑 alpha：柔亮帶的形狀
    }
    // 靜態層：xy＝背景位移（像素），z＝高光（+亮 −暗），w＝平滑有號距離
    kernel void ggGeom(texture2d<float, access::read> din [[texture(0)]],
                       texture2d<float, access::read> dout [[texture(1)]],
                       texture2d<float, access::write> geom [[texture(2)]],
                       constant GeomU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= geom.get_width() || gid.y >= geom.get_height()) return;
        int2 p = int2(gid);
        float d = so(din, dout, p);
        // 法線：SDF 梯度（半徑隨斜面寬的 Sobel，平順）
        int R = max(1, int(u.bezel * 0.14));
        float a00 = so(din, dout, p + int2(-R, -R)), a10 = so(din, dout, p + int2(0, -R)), a20 = so(din, dout, p + int2(R, -R));
        float a01 = so(din, dout, p + int2(-R, 0)),                                         a21 = so(din, dout, p + int2(R, 0));
        float a02 = so(din, dout, p + int2(-R, R)), a12 = so(din, dout, p + int2(0, R)),  a22 = so(din, dout, p + int2(R, R));
        float2 g = float2((a20 + 2.0 * a21 + a22) - (a00 + 2.0 * a01 + a02), (a02 + 2.0 * a12 + a22) - (a00 + 2.0 * a10 + a20));
        float gl = length(g); float2 nIn = gl > 1e-4 ? g / gl : float2(0.0);
        // ① 位移：沿法線往字裡，只在邊緣帶，量跟帶內深度成正比（邊上 shift、帶外 0）
        float tb = clamp(d / u.band, 0.0, 1.0);
        float2 disp = d > 0.0 ? nIn * u.shift * (1.0 - tb) : float2(0.0);
        // ② 高光：平滑 alpha 的導數（Sobel／8r＝每像素的 alpha 變化）× rim ≈ 帶裡的法線；亮度＝環境量＋方向量
        int r = max(1, int(u.rim * 0.5));
        float b00 = al(din, dout, p + int2(-r, -r), u.rim), b10 = al(din, dout, p + int2(0, -r), u.rim), b20 = al(din, dout, p + int2(r, -r), u.rim);
        float b01 = al(din, dout, p + int2(-r, 0), u.rim),                                                b21 = al(din, dout, p + int2(r, 0), u.rim);
        float b02 = al(din, dout, p + int2(-r, r), u.rim), b12 = al(din, dout, p + int2(0, r), u.rim),  b22 = al(din, dout, p + int2(r, r), u.rim);
        float2 ga = float2((b20 + 2.0 * b21 + b22) - (b00 + 2.0 * b01 + b02), (b02 + 2.0 * b12 + b22) - (b00 + 2.0 * b10 + b20)) / (8.0 * float(r)) * u.rim;
        float gm = length(ga);
        float2 nOut = gm > 1e-5 ? -ga / gm : float2(0.0);
        float2 L = normalize(float2(-0.6, -0.8));   // 主光：左上（貼圖 y 往下）
        float s = u.ambient + (1.0 - u.ambient) * dot(nOut, L);
        geom.write(float4(disp, min(gm, 1.0) * s, d), gid);
    }
    kernel void ggComposite(texture2d<float, access::sample> bg [[texture(0)]],
                            texture2d<float, access::sample> bgBlur [[texture(1)]],
                            texture2d<float, access::read> geom [[texture(2)]],
                            texture2d<float, access::write> out [[texture(3)]],
                            constant CompU& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float4 G = geom.read(gid);
        float d = G.w;
        float cover = clamp(d + 0.5, 0.0, 1.0);                                        // 亞像素覆蓋
        float line = u.lineA * clamp(1.0 - abs(d + u.lineC) / u.lineW, 0.0, 1.0);      // 字外細暗線（黑，premultiplied rgb＝0）
        if (cover <= 0.0) { out.write(float4(0.0, 0.0, 0.0, line), gid); return; }
        constexpr sampler smp(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 q = float2(gid) + 0.5 + G.xy;
        // 字裡＝模糊後的背景（平滑霧面）；清楚背景只在邊緣帶透出
        float wb = u.blurMix * max(u.edgeBlur, smoothstep(0.0, u.band, d));
        float3 col = mix(bg.sample(smp, q).rgb, bgBlur.sample(smp, q).rgb, wb);
        // ③ 底色亮度調字色
        col = u.lift >= 0.0 ? col + (1.0 - col) * u.lift : col * (1.0 + u.lift);
        // ② 高光：柔亮帶，背光側略暗
        col = G.z > 0.0 ? col + (1.0 - col) * G.z * u.specular : col * (1.0 + G.z * u.shade);
        col = clamp(mix(col, u.tint.rgb * max(max(col.r, col.g), col.b), u.tint.a), 0.0, 1.0);
        out.write(float4(col * cover, cover + line * (1.0 - cover)), gid);
    }
    """
}

// MARK: - 自檢

enum GlyphGlassSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // 路由：預設 sdf（拍板 2026-11-07）；sdf 下增加對比退實色、減少透明度退霧面實色，system 保留原路
        var colored = ClockLook(); colored.swatch = .blueOrange; colored.glass = true
        func r(_ m: NumeralGlassMode, rt: Bool = false, rm: Bool = false, ic: Bool = false) -> NumeralGlassRoute {
            NumeralGlassRoute.decide(mode: m, look: colored, materialLookLinked: false, reduceTransparency: rt, reduceMotion: rm, increaseContrast: ic)
        }
        let savedOverride = NumeralGlassMode.override
        NumeralGlassMode.override = nil
        let defaultMode = UserDefaults.standard.string(forKey: NumeralGlassMode.defaultsKey) == nil ? NumeralGlassMode.current : .system
        NumeralGlassMode.override = savedOverride
        check(defaultMode == .sdf && r(.system) == .system && r(.system, ic: true) == .system && r(.system, rt: true) == .solid,
              "SDF 玻璃字：預設走 SDF，現行規則保留可切回")   // l10n-ignore
        check(r(.sdf) == .sdf && r(.sdf, ic: true) == .solid && r(.sdf, rt: true) == .frostedSolid && r(.sdf, rm: true) == .solid
              && r(.sdf, rt: true, ic: true) == .solid,
              "SDF 玻璃字：增加對比退實色、減少透明度退霧面實色、減少動態效果退實色")   // l10n-ignore
        check(GlyphGlassParams.shadowAlpha(luma: 0.95) > GlyphGlassParams.shadowAlpha(luma: 0.1)
              && GlyphGlassParams.numeral.lift(luma: 0.05) > 0 && GlyphGlassParams.numeral.lift(luma: 0.95) < 0,
              "SDF 玻璃字：暗底提亮、亮底壓深，亮底可讀性陰影加深")   // l10n-ignore

        guard GlyphGlass.shared.available else { check(true, "SDF 玻璃字：沒有 Metal，略過渲染檢查"); return }   // l10n-ignore
        // 同一字形（橫長方塊）在四種底上
        let glyph = CGRect(x: 312, y: 362, width: 400, height: 300)
        let path = CGPath(rect: glyph, transform: nil)
        func solidImage(_ c: CGFloat) -> CGImage { makeImage(1024, 1024) { $0.setFillColor(NSColor(white: c, alpha: 1).cgColor); $0.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) } }
        let gradient = makeImage(1024, 1024) { c in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let gr = CGGradient(colorsSpace: cs, colors: [NSColor(srgbRed: 0.2, green: 0.35, blue: 0.9, alpha: 1).cgColor,
                                                          NSColor(srgbRed: 0.95, green: 0.55, blue: 0.7, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(gr, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])
        }
        let bgs: [(String, CGImage, CGFloat)] = [("淺純色", solidImage(0.92), 0.92), ("深純色", solidImage(0.1), 0.1),   // l10n-ignore
                                                 ("漸層桌布", gradient, 0.5), ("照片", PhotosDemoArt.image(px: 1024), 0.45)]   // l10n-ignore
        var noLight = GlyphGlassParams.numeral; noLight.specular = 0; noLight.shade = 0
        for (name, bg, luma) in bgs {
            guard let a = GlyphGlass.shared.render(path: path, key: nil, scale: 1, backdrop: bg, frosted: nil, luma: luma, tint: nil),
                  let b = GlyphGlass.shared.render(path: path, key: nil, scale: 1, backdrop: bg, frosted: nil, luma: luma, tint: nil, params: noLight)
            else { check(false, "SDF 玻璃字：\(name) 渲染失敗"); continue }   // l10n-ignore
            let pa = pixels(a.image), pb = pixels(b.image), W = a.image.width
            func lum(_ p: [UInt8], _ x: Int, _ y: Int) -> Double { let i = (y * W + x) * 4; return 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2]) }
            let cx = Int(glyph.midX - a.rect.minX), top = Int(glyph.minY - a.rect.minY) + 1, bot = Int(glyph.maxY - a.rect.minY) - 2
            let dTop = lum(pa, cx, top) - lum(pb, cx, top), dBot = lum(pa, cx, bot) - lum(pb, cx, bot)
            check(dTop > dBot + 4 && dTop >= 0, String(format: "SDF 玻璃字：%@ 上緣高光比下緣亮（上 %+.1f／下 %+.1f）", name, dTop, dBot))   // l10n-ignore
        }
        let onLight = GlyphGlass.shared.render(path: path, key: nil, scale: 1, backdrop: bgs[0].1, frosted: nil, luma: 0.92, tint: nil)!
        let onDark = GlyphGlass.shared.render(path: path, key: nil, scale: 1, backdrop: bgs[1].1, frosted: nil, luma: 0.1, tint: nil)!
        let mid = { (img: CGImage) -> Int in let p = pixels(img), i = ((img.height / 2) * img.width + img.width / 2) * 4; return Int(p[i]) }
        check(mid(onLight.image) - mid(onDark.image) > 100, "SDF 玻璃字：玻璃透出底色（實色不會）")   // l10n-ignore

        // 位移：橫向亮度斜坡（每像素 +1），從字的左緣往裡量「取到的值 − 原位的值」
        let ramp = makeImage(1024, 1024) { c in
            for x in 0..<1024 { let v = CGFloat(max(0, min(255, x - 300))) / 255; c.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1)); c.fill(CGRect(x: x, y: 0, width: 1, height: 1024)) }
        }
        var flat = GlyphGlassParams.numeral; flat.specular = 0; flat.shade = 0; flat.blurMix = 0; flat.liftDark = 0; flat.darkenLight = 0; flat.edgeSoft = 0
        if let o = GlyphGlass.shared.render(path: path, key: nil, scale: 1, backdrop: ramp, frosted: nil, luma: 0.5, tint: nil, params: flat) {
            let p = pixels(o.image), y = Int(glyph.midY - o.rect.minY)
            let x0 = Int(glyph.minX - o.rect.minX)
            let bezel = Int(flat.bezel * Float(glyph.height))
            var shifts: [Int] = []
            for d in 1...(bezel + 6) { let x = x0 + d; shifts.append(Int(p[(y * o.image.width + x) * 4]) - (Int(o.rect.minX) + x - 300)) }
            let mono = zip(shifts, shifts.dropFirst()).allSatisfy { $1 <= $0 + 1 }
            check(mono && shifts[0] >= shifts.last! + 4 && abs(shifts.last!) <= 1,
                  "SDF 玻璃字：折射位移隨 SDF 距離單調（邊上 \(shifts[0]) px → 平頂 \(shifts.last!) px）")   // l10n-ignore
        } else { check(false, "SDF 玻璃字：位移渲染失敗") }   // l10n-ignore

        // 字外細暗線：緊貼字外一圈低不透明度，再往外就沒有
        do {
            let p = pixels(onLight.image), W = onLight.image.width
            let cx = Int(glyph.midX - onLight.rect.minX), y0 = Int(glyph.minY - onLight.rect.minY)
            let near = Int(p[((y0 - 1) * W + cx) * 4 + 3]), far = Int(p[((y0 - 5) * W + cx) * 4 + 3])
            check(near > 10 && near < 90 && far == 0, "SDF 玻璃字：字外細暗線（緊貼 α \(near)、5 px 外 α \(far)）")   // l10n-ignore
        }
        // 抗鋸齒：45° 斜邊每一列都有半覆蓋的像素（二值邊不會有）
        let tri = CGMutablePath(); tri.move(to: CGPoint(x: 300, y: 300)); tri.addLine(to: CGPoint(x: 700, y: 300)); tri.addLine(to: CGPoint(x: 300, y: 700)); tri.closeSubpath()
        if let t = GlyphGlass.shared.render(path: tri, key: nil, scale: 1, backdrop: bgs[1].1, frosted: nil, luma: 0.1, tint: nil) {
            let p = pixels(t.image), W = t.image.width
            var rows = 0
            for y in 400..<600 {
                let ly = y - Int(t.rect.minY)
                if (0..<W).contains(where: { x in let a = p[(ly * W + x) * 4 + 3]; return a > 70 && a < 200 }) { rows += 1 }
            }
            check(rows >= 180, "SDF 玻璃字：斜邊有亞像素覆蓋（\(rows)/200 列）")   // l10n-ignore
        } else { check(false, "SDF 玻璃字：斜邊渲染失敗") }   // l10n-ignore

        // 增加對比：sdf 模式輸出＝實色路徑（逐位元組）
        let face = Face(); face.frozen = true
        let shape = GlyphShape.clock("10", look: colored, height: 300, maxWidth: 600, at: CGPoint(x: 512, y: 300), anchorX: 0.5)
        let savedIC = HPAccessibility.forceIncreaseContrast
        func draw(_ look: ClockLook, _ mode: NumeralGlassMode, ic: Bool) -> [UInt8] {
            NumeralGlassMode.override = mode; HPAccessibility.forceIncreaseContrast = ic
            return pixels(makeImage(1024, 1024) { c in c.draw(gradient, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
                face.drawClockDigits(c, [shape], look: look, clear: gradient, frosted: gradient, alpha: 1) })
        }
        var solidLook = colored; solidLook.glass = false
        let icOut = draw(colored, .sdf, ic: true), solidOut = draw(solidLook, .system, ic: false)
        NumeralGlassMode.override = savedOverride; HPAccessibility.forceIncreaseContrast = savedIC
        check(icOut == solidOut, "SDF 玻璃字：增加對比時輸出等於實色路徑")   // l10n-ignore
    }

    private static func pixels(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        if let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return px
    }
}
