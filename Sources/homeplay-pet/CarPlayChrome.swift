// CarPlay 畫面上的 👀 膠囊（拍板 2026-11-06：膠囊一直留在頂端那條邊）。
//
// 接收端對 iPhone 宣告的安全區是 (80,80 928x928)（viewArea 1088²）：CarPlay 內容只畫在中間，外圈 80 px 只有底色。
// 膠囊（跟主畫面頂端藥丸同一顆，只是縮小；材質照錶面年代，眼睛就是 👀）收在這條帶內，不蓋任何 CarPlay 內容。
// 做法：膠囊畫成一小張圖（只在眨眼、表情、位置變了才重畫），每幀用一個小 GPU pass 疊進直播畫面（零拷貝路的 MTLTexture）；
// 慢路（CGImage）在 CPU 上疊。玻璃材質要的背景＝直播畫面頂端那條帶（每兩秒從畫面讀一次，只讀那一條）。
// 共享元素：CarPlay 叫到前面時，膠囊從剛才主畫面／錶面上的位置滑進這條帶（減少動態效果：淡入）；回主畫面時藥丸從這裡滑回去。

import AppKit
import Metal

final class CarPlayChrome {
    static let shared = CarPlayChrome()
    static let device = MTLCreateSystemDefaultDevice()

    /// 疊在畫面上的那一塊（1024 畫布座標）與它的圖（已乘 alpha，直播畫面 px）
    private var overlayRect: CGRect?
    private var overlayImage: CGImage?
    private var overlayKey = ""
    private var overlayTex: MTLTexture?
    private var pipeline: MTLComputePipelineState?
    private var queue: MTLCommandQueue?
    private var outputs: [MTLTexture] = []
    private var outIndex = 0
    /// 最近一格（疊好膠囊的）：切換器卡片、拉下來的卡片用
    private var lastShown: MTLTexture?
    private var lastSource: MTLTexture?
    private var lastImage: CGImage?
    /// 玻璃背景：直播畫面頂端那條帶（1024 寬的畫布座標）
    private var backdrop: CGImage?
    private var backdropAt: Double = -1e9
    /// 共享元素：從哪裡滑進來（nil＝已經到位）
    var glide: (from: CGRect, start: Double)?
    static let glideSpring = HPMotion.T.pill.spring
    private var eyesTick: Double = 0

    // MARK: 每幀

    /// 每一格直播畫面（零拷貝路）：疊上膠囊再交給 RealityKit
    func apply(_ src: MTLTexture) -> MTLTexture {
        lastSource = src
        guard let rect = overlayRect, let tex = overlayTex, let pso = pipeline(src.device) else { lastShown = src; return src }
        if queue == nil { queue = src.device.makeCommandQueue() }
        guard let queue else { lastShown = src; return src }
        if outputs.count != 2 || outputs[0].width != src.width || outputs[0].height != src.height || outputs[0].pixelFormat != src.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: src.width, height: src.height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            outputs = (0..<2).compactMap { _ in src.device.makeTexture(descriptor: d) }
            guard outputs.count == 2 else { lastShown = src; return src }
        }
        outIndex ^= 1
        let dst = outputs[outIndex]
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { lastShown = src; return src }
        let k = CGFloat(src.width) / 1024
        var r = SIMD4<Int32>(Int32((rect.minX * k).rounded()), Int32((rect.minY * k).rounded()), Int32(tex.width), Int32(tex.height))
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0); enc.setTexture(tex, index: 1); enc.setTexture(dst, index: 2)
        enc.setBytes(&r, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (src.width + 15) / 16, height: (src.height + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()   // RealityKit 在同一個裝置上取樣，佇列順序保證畫完才用（同 CornerFit）
        lastShown = dst
        return dst
    }

    /// 慢路（CGImage 畫面）：CPU 疊
    func apply(_ img: CGImage) -> CGImage {
        let out = composite(img)
        lastImage = out
        return out
    }
    func composite(_ img: CGImage) -> CGImage {
        guard let rect = overlayRect, let ov = overlayImage else { return img }
        let w = img.width, h = img.height, k = CGFloat(w) / 1024
        return makeImage(w, h) { g in
            CarPlayChrome.drawUpright(g, img, in: CGRect(x: 0, y: 0, width: w, height: h))
            CarPlayChrome.drawUpright(g, ov, in: CGRect(x: rect.minX * k, y: rect.minY * k, width: CGFloat(ov.width), height: CGFloat(ov.height)))
        }
    }
    static func drawUpright(_ g: CGContext, _ img: CGImage, in r: CGRect) {
        g.saveGState(); g.translateBy(x: 0, y: r.minY + r.maxY); g.scaleBy(x: 1, y: -1)
        g.interpolationQuality = .high; g.draw(img, in: r); g.restoreGState()
    }

    /// 直播停了（回到外殼）：不再疊，也不留著畫面的紋理
    func reset() {
        overlayRect = nil; overlayImage = nil; overlayTex = nil; overlayKey = ""
        lastSource = nil; outputs = []
    }

    /// PetView 每幀（直播中）：照這一刻的膠囊需要重畫才重畫（眨眼、表情、滑進來的位置）；回 true＝膠囊換了
    @discardableResult
    func update(face: Face, now: Double, device: MTLDevice?) -> Bool {
        let dt = eyesTick > 0 ? min(0.1, now - eyesTick) : 0; eyesTick = now
        face.tickEyes(now, dt)   // 直播時 face.tick 停著：眼睛的眨、瞄、表情還是要走
        let inset = HomeIndicator.inset
        let target = HomeIndicator.carPlayCapsule(inset: inset)
        var cap = target, alpha: CGFloat = 1
        if let gl = glide {
            let t = CGFloat(HPMotion.frozen("cpglide") ?? (now - gl.start))
            if HPMotion.reduceMotion { alpha = min(1, t / 0.2); if t >= 0.2 { glide = nil } }
            else {
                let e = Self.glideSpring.value(from: 0, to: 1, velocity: 0, t: t).x
                cap = Shell.lerp(gl.from, target, max(0, min(1, e)))
                if HPMotion.frozen("cpglide") == nil, Self.glideSpring.settled(from: 0, to: 1, velocity: 0, t: t) { glide = nil; cap = target }
            }
        }
        if face.capsuleLook() == .glass || face.capsuleLook() == .smoke, now - backdropAt > 2 { refreshBackdrop(now) }
        let key = face.carPlayCapsuleKey(cap, alpha: alpha, now: now) + "|\(backdropAt)"
        guard key != overlayKey else { return false }
        overlayKey = key
        let rect = cap.insetBy(dx: -cap.height * 0.5, dy: -cap.height * 0.4).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024)).integral
        let img = face.renderCarPlayCapsule(cap, frame: rect, alpha: alpha, backdrop: backdrop, now: now)
        overlayRect = rect; overlayImage = img
        if let device { overlayTex = Self.texture(img, device: device, reuse: overlayTex) }
        return true
    }
    /// 膠囊換了但畫面靜止（沒有新的一格進來）：拿最後一格重疊一次（解碼器留著那一格的緩衝到下一格來）
    func reapply() -> MTLTexture? { lastSource.map { apply($0) } }
    /// 只給 HOMEPLAY_FAKE_LIVE_TEX：把假畫面傳上 GPU，走跟真的直播一樣的紋理路
    static func uploadForTest(_ img: CGImage) -> MTLTexture? {
        guard let device else { return nil }
        return texture(img, device: device, reuse: nil)
    }

    /// 只給快照：沒有 GPU 也算好要疊的那一塊
    func prepareForSnapshot(face: Face, now: Double, backdropFrom frame: CGImage) {
        backdrop = Self.band(of: frame); backdropAt = now
        overlayKey = ""
        update(face: face, now: now, device: nil)
    }

    // MARK: 讀回畫面

    /// 這一刻的 CarPlay 畫面（1024²，疊好膠囊）：拉下來的卡片、切換器卡片
    func snapshot() -> CGImage? {
        if let img = lastImage { return Self.scaled(img, to: 1024) }
        guard let tex = lastShown else { return nil }
        return Self.read(tex, region: MTLRegionMake2D(0, 0, tex.width, tex.height)).map { Self.scaled($0, to: 1024) }
    }
    private func refreshBackdrop(_ now: Double) {
        backdropAt = now
        if let img = lastImage { backdrop = Self.band(of: img); return }
        guard let src = lastSource else { return }
        let h = Int((HomeIndicator.bandHeight(inset: HomeIndicator.inset) * CGFloat(src.height) / 1024).rounded())
        guard h > 0, let band = Self.read(src, region: MTLRegionMake2D(0, 0, src.width, min(src.height, h))) else { return }
        backdrop = Self.scaled(band, to: 1024)
    }
    static func band(of img: CGImage) -> CGImage? {
        let h = Int((HomeIndicator.bandHeight(inset: HomeIndicator.inset) * CGFloat(img.height) / 1024).rounded())
        guard let crop = img.cropping(to: CGRect(x: 0, y: 0, width: img.width, height: max(1, h))) else { return nil }
        return scaled(crop, to: 1024)
    }
    static func scaled(_ img: CGImage, to w: Int) -> CGImage {
        guard img.width != w else { return img }
        let h = max(1, Int((CGFloat(img.height) * CGFloat(w) / CGFloat(img.width)).rounded()))
        return makeImage(w, h) { g in drawUpright(g, img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    }
    /// GPU 紋理 → CGImage：先 blit 到共享記憶體的暫存紋理再讀（只在拉下來、換背景時做，不在每幀路上）
    private static func read(_ tex: MTLTexture, region: MTLRegion) -> CGImage? {
        let dev = tex.device
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tex.pixelFormat, width: region.size.width, height: region.size.height, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead]
        guard let tmp = dev.makeTexture(descriptor: d), let q = dev.makeCommandQueue(), let cb = q.makeCommandBuffer(), let bl = cb.makeBlitCommandEncoder() else { return nil }
        bl.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size,
                to: tmp, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let w = region.size.width, h = region.size.height, row = w * 4
        var px = [UInt8](repeating: 0, count: row * h)
        tmp.getBytes(&px, bytesPerRow: row, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let bgra = tex.pixelFormat == .bgra8Unorm || tex.pixelFormat == .bgra8Unorm_srgb
        let info = bgra ? CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                        : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: info, provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: GPU

    private static func texture(_ img: CGImage, device: MTLDevice, reuse: MTLTexture?) -> MTLTexture? {
        let w = img.width, h = img.height, row = w * 4
        var px = [UInt8](repeating: 0, count: row * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))   // 記憶體第 0 列＝圖的最上面一列（跟直播紋理同向）
        var tex = reuse
        if tex == nil || tex!.width != w || tex!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            tex = device.makeTexture(descriptor: d)
        }
        tex?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: row)
        return tex
    }

    private func pipeline(_ dev: MTLDevice) -> MTLComputePipelineState? {
        if let pipeline { return pipeline }
        do {
            let lib = try dev.makeLibrary(source: Self.source, options: nil)
            guard let fn = lib.makeFunction(name: "carplayChrome") else { return nil }
            pipeline = try dev.makeComputePipelineState(function: fn)
        } catch { log("carplay chrome shader: \(error)") }
        return pipeline
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void carplayChrome(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::read> ov [[texture(1)]],
                              texture2d<float, access::write> dst [[texture(2)]],
                              constant int4& r [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = src.read(gid);
        int2 q = int2(gid) - r.xy;
        if (q.x >= 0 && q.y >= 0 && q.x < r.z && q.y < r.w) {
            float4 o = ov.read(uint2(q));            // 已乘 alpha
            c.rgb = o.rgb + c.rgb * (1.0 - o.a);
        }
        dst.write(float4(c.rgb, 1.0), gid);
    }
    """
}

// MARK: - 膠囊的圖

extension Face {
    /// 這一刻的膠囊長怎樣（眨眼、表情、眼珠、位置、材質）：一樣就不重畫
    func carPlayCapsuleKey(_ cap: CGRect, alpha: CGFloat, now: Double) -> String {
        let p = cur, bf = blinkFactor(now)
        func q(_ x: CGFloat) -> Int { Int((x * 2).rounded()) }
        return "\(capsuleLook())|\(q(cap.minX)),\(q(cap.minY)),\(q(cap.width)),\(q(cap.height))|\(Int(alpha * 20))|\(Int(bf * 20))|\(expression)|"
            + "\(q(p.pdx)),\(q(p.pdy)),\(q(p.ps * 10)),\(q(p.top * 20)),\(q(p.smile * 20)),\(q(p.rx)),\(q(p.ry)),\(q(p.sep))"
    }

    /// 畫出 CarPlay 畫面上的膠囊（frame：這張圖在畫布上的範圍；背景透明，只有膠囊與它的影子）。
    /// 材質照 capsuleLook()（.system 的年代在藥丸上也是黑，同 drawShellPill）；眼睛大小跟藥丸同比例
    func renderCarPlayCapsule(_ cap: CGRect, frame: CGRect, alpha: CGFloat, backdrop: CGImage?, now: Double) -> CGImage {
        let sc = HomeIndicator.videoSide / 1024
        let w = max(1, Int((frame.width * sc).rounded())), h = max(1, Int((frame.height * sc).rounded()))
        let look = capsuleLook() == .system ? .black : capsuleLook()
        let path = CGPath(roundedRect: cap, cornerWidth: cap.height / 2, cornerHeight: cap.height / 2, transform: nil)
        let k = 0.5 * cap.height / LiveActivityStack.height
        func eyes(_ g: CGContext) {
            let bf = blinkFactor(now)
            for s: CGFloat in [-1, 1] { drawEye(g, cx: cap.midX + s * cur.sep * k, cy: cap.midY, side: s, blinkF: bf, k: k) }
        }
        func setup(_ g: CGContext) { g.scaleBy(x: sc, y: sc); g.translateBy(x: -frame.minX, y: -frame.minY) }
        // 玻璃／黑透：先在背景（直播畫面頂端那條帶）上畫好整顆，再挖出膠囊貼回透明的圖
        var body: CGImage?
        if look != .black {
            // 黑透膠囊裡的「霧化背景」是錶面的；CarPlay 上沒有，照背景壓暗就好
            body = withoutFrost { makeImage(w, h) { g in
                setup(g)
                if let backdrop { drawUpright(g, backdrop, in: CGRect(x: 0, y: 0, width: 1024, height: CGFloat(backdrop.height) * 1024 / CGFloat(backdrop.width))) }
                else { g.setFillColor(NSColor.black.cgColor); g.fill(frame) }
                drawCapsuleBody(g, cap, look: look, animating: false)
                eyes(g)
            } }
        }
        return makeImage(w, h) { g in
            setup(g)
            g.setAlpha(alpha)
            g.beginTransparencyLayer(auxiliaryInfo: nil)
            g.saveGState()   // 柔和的接觸陰影：膠囊浮在 CarPlay 的底色上
            g.setShadow(offset: CGSize(width: 0, height: cap.height * 0.06), blur: cap.height * 0.16, color: NSColor(white: 0, alpha: 0.3).cgColor)
            g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
            g.restoreGState()
            if let body {
                g.saveGState(); g.addPath(path); g.clip()
                drawUpright(g, body, in: frame)
                g.restoreGState()
            } else {
                g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
                eyes(g)
            }
            g.endTransparencyLayer()
        }
    }
}
