// 天氣 App 動態天空：我們自己的 Metal 畫家（系統 VFX 用不了時的退路，也是今天實際上在跑的那個）。
// 素材：執行時從系統 WeatherUI.framework 讀天氣 App 自己的雲圖（6 向光照圖：POS 的 RGB＝從 +x/+y/+z 打來的光、
// NEG＝從 −x/−y/−z、POS.a＝密度）、雨雪冰雹的形狀表、霧的噪聲片、月相圖；不複製進 repo 或 App。讀不到就用程式畫的替身（圓點、線段）。
// 動作：粒子位置全部是時間的函數（無狀態）——同一個 t 畫出同一張，暫停就是 t 不走；--weather-frames 的影格序列也因此可重現。
// 合成在線性色彩空間（render target 是 rgba8Unorm_srgb），輸出 sRGB 的 CGImage 給 Core Graphics 的螢幕畫布。

import AppKit
import Metal
import MetalKit
import QuartzCore

final class WeatherSkyMetal {
    static let resourceDir = "/System/iOSSupport/System/Library/PrivateFrameworks/WeatherUI.framework/Versions/A/Resources/VFX"
    static var assetDir: String { resourceDir + "/WeatherV136_Default_Background.vfx/assets" }

    let side: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let skyPipe: MTLRenderPipelineState
    private let spritePipe: MTLRenderPipelineState
    private let target: MTLTexture
    private let loader: MTKTextureLoader
    private var textures: [String: MTLTexture] = [:]
    private var missing: Set<String> = []
    private let white: MTLTexture
    /// 系統素材讀到幾張（量測／報告用）
    private(set) var systemAssetsLoaded = 0

    private(set) var look: SkyLook
    private var scene: WeatherSkyScene
    private var time: Double = 0
    // 換場景時的交叉淡入：舊外觀的漸層在 1.2 s 內換成新的（雲、雨用透明度淡入淡出）
    private var fromLook: SkyLook?
    private var blendT: Double = 1
    // 閃電
    private var nextStrike: Double = 2.5
    private var strikeAt: Double = -10
    private var bolt: [SIMD4<Float>] = []   // 線段（x0,y0,x1,y1）
    private var rng = SplitMix(seed: 0x5eed)
    /// 雨打在模組上緣濺起的水花：模組的框（0…1，左上原點）。系統天氣 App 用另一個「Collision」場景做這件事（場景裡的 colliderA…F）
    var colliders: [CGRect] = []

    init?(side: Int = 1024, scene: WeatherSkyScene) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q; self.side = side; self.scene = scene; look = scene.look
        loader = MTKTextureLoader(device: dev)
        do {
            let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)
            func pipe(_ v: String, _ f: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: v); d.fragmentFunction = lib.makeFunction(name: f)
                let a = d.colorAttachments[0]!
                a.pixelFormat = .rgba8Unorm_srgb
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .oneMinusSourceAlpha     // 預乘；alpha＝0 就是加亮
                a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try dev.makeRenderPipelineState(descriptor: d)
            }
            skyPipe = try pipe("sky_v", "sky_f")
            spritePipe = try pipe("sprite_v", "sprite_f")
        } catch { NSLog("WeatherSkyMetal: shader %@", "\(error)"); return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: side, height: side, mipmapped: false)   // RGBA：跟螢幕畫布同排列，貼上時不用換通道
        td.usage = [.renderTarget]; td.storageMode = .shared
        guard let t = dev.makeTexture(descriptor: td) else { return nil }
        target = t
        let wd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let w = dev.makeTexture(descriptor: wd) else { return nil }
        var px: [UInt8] = [255, 255, 255, 255]
        w.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        white = w
    }

    func configure(_ s: WeatherSkyScene, crossfade: Bool = true) {
        guard s != scene else { return }
        fromLook = crossfade ? look : nil
        blendT = crossfade ? 0 : 1
        scene = s; look = s.look
    }

    // MARK: 素材

    private func texture(_ name: String, dir: String = WeatherSkyMetal.resourceDir, srgb: Bool = false) -> MTLTexture? {
        let key = dir + "/" + name
        if let t = textures[key] { return t }
        if missing.contains(key) { return nil }
        let url = URL(fileURLWithPath: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let t = try? loader.newTexture(URL: url, options: [.SRGB: srgb, .textureStorageMode: MTLStorageMode.private.rawValue]) else {
            missing.insert(key); return nil
        }
        textures[key] = t; systemAssetsLoaded += 1
        return t
    }

    // MARK: 一幀

    /// 還在交叉淡入（減少動態效果時，WeatherLiveSky 只在這段期間繼續排幀）
    var isBlending: Bool { blendT < 1 }

    /// 前進 dt 秒並畫一張；motion＝false（減少動態效果）時粒子與雲停住，只有換場景的淡入在走。回 sRGB 的 CGImage（左上原點）
    func render(dt: Double, motion: Bool = true) -> CGImage? {
        if motion { time += dt }
        if blendT < 1 { blendT = min(1, blendT + dt / 1.2) }
        let L = look
        let k = Float(blendT)
        let from = fromLook ?? L
        func mixRGB(_ a: SkyRGB, _ b: SkyRGB) -> SIMD3<Float> { a.mix(b, k).linear }

        // 閃電排程：3–8 s 一次，偶爾連閃兩下
        var flash: Float = 0
        if L.lightning && motion {
            if time >= nextStrike {
                strikeAt = time; nextStrike = time + rng.range(3, 8)
                bolt = makeBolt()
            }
            let e = time - strikeAt
            if e < 0.6 {
                // 兩個脈衝：0–0.12 s 主閃、0.18–0.32 s 回閃（照系統場景的 flashLength 0.3／fade 0.1）
                let p1 = e < 0.12 ? 1 - e / 0.12 : 0
                let p2 = e > 0.18 && e < 0.34 ? 0.6 * (1 - (e - 0.18) / 0.16) : 0
                flash = Float(max(p1, p2))
            }
        }

        guard let cb = queue.makeCommandBuffer() else { return nil }
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = target
        pd.colorAttachments[0].loadAction = .clear
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pd) else { return nil }

        // 1) 天空漸層＋光暈＋太陽
        var u = SkyUniforms(top: mixRGB(from.top, L.top), mid: mixRGB(from.middle, L.middle), bot: mixRGB(from.bottom, L.bottom),
                            midAt: from.middleAt + (L.middleAt - from.middleAt) * k,
                            light: from.lightPos + (L.lightPos - from.lightPos) * k,
                            glow: mixRGB(from.glow, L.glow), glowStrength: from.glowStrength + (L.glowStrength - from.glowStrength) * k,
                            glowRadius: from.glowRadius + (L.glowRadius - from.glowRadius) * k,
                            sunDisc: from.sunDisc + (L.sunDisc - from.sunDisc) * k, flash: flash * 0.08, time: Float(time))
        enc.setRenderPipelineState(skyPipe)
        enc.setFragmentBytes(&u, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(spritePipe)
        // 舊外觀淡出、新外觀淡入（各畫一次，透明度乘上權重）
        if let f = fromLook, k < 1 { drawLayers(enc, f, weight: 1 - k, flash: 0) }
        drawLayers(enc, L, weight: k, flash: flash)
        if k >= 1 { fromLook = nil }
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        return readback()
    }

    private func drawLayers(_ enc: MTLRenderCommandEncoder, _ L: SkyLook, weight w: Float, flash: Float) {
        let t = Float(time)
        // 2) 星星：1000 顆小點，偏上半部；亮的 1/8 大一點、會閃
        if L.stars * w > 0.01 {
            var inst: [Sprite] = []
            inst.reserveCapacity(700)
            for i in 0..<700 {
                let x = hash(Float(i) * 1.7), y = powf(hash(Float(i) * 3.1 + 0.3), 1.4) * 0.8
                let bright = i % 8 == 0
                let tw = 0.65 + 0.35 * sinf(t * (bright ? 1.3 : 3.0) + Float(i))
                let s: Float = (bright ? 3.2 : 1.8) / Float(side)
                let a = L.stars * w * tw * (bright ? 1 : 0.55) * (1 - y * 0.7)
                inst.append(Sprite(center: [x, y], size: [s, s], uv: [0, 0, 1, 1], color: SIMD3<Float>(1, 1, 1).pre(a), mode: 5, light: .zero, shade: .zero, angle: 0))
            }
            draw(enc, inst, tex: white)
        }
        // 3) 月亮：系統的月相圖（400²）；讀不到就畫一個圓
        if L.moon * w > 0.01 {
            let m = texture("moonPhase\(L.moonPhase).png", dir: Self.assetDir, srgb: true)
            let sz: Float = 0.13
            let s = Sprite(center: L.lightPos, size: [sz, sz], uv: [0, 0, 1, 1], color: SIMD3<Float>(1, 1, 1).pre(L.moon * w), mode: m == nil ? 5 : 3, light: .zero, shade: .zero, angle: 0)
            draw(enc, [s], tex: m ?? white)
            // 月暈
            draw(enc, [Sprite(center: L.lightPos, size: [0.5, 0.5], uv: [0, 0, 1, 1], color: SIMD4(0.55, 0.62, 0.85, 0) * 0.10 * L.moon * w, mode: 6, light: .zero, shade: .zero, angle: 0)], tex: white)
        }
        // 4) 雲（遠的先畫）
        for (li, layer) in L.clouds.enumerated() where layer.count > 0 {
            let posName = { (v: Int) in "\(layer.family)_\(String(format: "%03d", v))_POS.ktx" }
            for i in 0..<layer.count {
                let seed = Float(li * 31 + i * 7) + 0.5
                let v = Int(hash(seed * 1.3) * Float(layer.variants)) % max(1, layer.variants)
                guard let pos = texture(posName(v)) else { continue }
                let neg = texture(posName(v).replacingOccurrences(of: "_POS", with: "_NEG")) ?? pos
                let aspect = Float(pos.height) / Float(pos.width)
                let width = layer.tiled ? layer.width : layer.width * (0.8 + 0.4 * hash(seed * 2.9))
                let x: Float
                if layer.tiled {
                    // 雲毯：等距排開、一起慢慢漂，任何時刻都蓋滿整個寬度（間距 0.7 個寬 < 寬）
                    let spacing = width * 0.7, period = spacing * Float(layer.count)
                    x = fmodf(Float(i) * spacing + hash(Float(li) * 3.3) * spacing + t * layer.speed, period) - (period - 1) / 2 - width / 2
                } else {
                    let span = 1 + width * 2          // 從左邊完全出畫面到右邊完全出畫面
                    x = fmodf(hash(seed * 5.3) * span + t * layer.speed * (0.7 + 0.6 * hash(seed)), span) - width
                }
                let y = layer.yBand.lowerBound + (layer.yBand.upperBound - layer.yBand.lowerBound) * (layer.tiled ? Float(i % 2) : hash(seed * 7.7))
                let c = SIMD2<Float>(x + width / 2, y)
                // 光從太陽／月亮的方向來（畫面座標 y 往下，光照圖的 +y 是上）
                var ld = SIMD3<Float>(L.lightPos.x - c.x, c.y - L.lightPos.y, 0.6)
                ld = ld / max(0.001, (abs(ld.x) + abs(ld.y) + abs(ld.z)))
                let lit = layer.light.linear + SIMD3(0.75, 0.8, 1.0) * (flash * 0.9)   // 雲被閃電從裡面照亮
                let s = Sprite(center: c, size: [width, width * aspect], uv: [0, 0, 1, 1], color: SIMD4(1, 1, 1, 1) * layer.opacity * w,
                               mode: 0, light: SIMD4(lit, 0), shade: SIMD4(layer.shade.linear, 0), angle: 0, dir: SIMD4(ld, layer.tiled ? 1 : 0))
                draw(enc, [s], tex: pos, tex2: neg)
            }
        }
        // 5) 霧：大片噪聲慢慢漂，下半部濃
        if L.fog * w > 0.01 {
            let tex = texture("Noise_Sheet.ktx", dir: Self.assetDir)
            var inst: [Sprite] = []
            for i in 0..<9 {
                let fi = Float(i)
                let width: Float = 0.9 + 0.5 * hash(fi * 1.9)
                let x = fmodf(hash(fi * 4.1) * 2.2 + t * 0.004 * (1 + hash(fi)), 2.2) - 0.6
                let y = 0.35 + 0.65 * hash(fi * 6.3)
                let cell = i % 4
                inst.append(Sprite(center: [x, y], size: [width, width * 0.6], uv: [Float(cell % 2) * 0.5, Float(cell / 2) * 0.5, 0.5, 0.5],
                                   color: SIMD4(L.fogTint.linear, 1) * (L.fog * w * (0.35 + 0.4 * y)), mode: 2, light: .zero, shade: .zero, angle: 0))
            }
            draw(enc, inst, tex: tex ?? white)
        }
        // 6) 雨：遠（細、淡、多）與近（粗、亮、少）；Rain_Sheet 有 4 種水滴
        func rain(_ n: Int, near: Bool, sheet: String, opacity: Float, len: Float, speed: Float, seed: Float) {
            guard n > 0 else { return }
            let tex = texture(sheet, dir: Self.assetDir)
            var inst: [Sprite] = []; inst.reserveCapacity(n)
            for i in 0..<n {
                let fi = Float(i) + seed
                let sp = speed * (0.85 + 0.3 * hash(fi * 2.3))
                let y = fmodf(hash(fi * 1.1) * 1.3 + t * sp, 1.3) - 0.15
                let x = fmodf(hash(fi * 3.7) * 1.2 + y * L.fallAngle, 1.2) - 0.1
                let l = len * (0.7 + 0.6 * hash(fi * 5.1))
                let wdt: Float = (near ? 3.2 : 1.6) / Float(side) * (tex == nil ? 1 : 3)
                let cell = Float(i % 4)
                inst.append(Sprite(center: [x, y], size: [wdt, l], uv: [cell * 0.25, 0, 0.25, 1],
                                   color: SIMD4(0.85, 0.9, 1, 1) * (opacity * w * (0.6 + 0.4 * hash(fi * 7.9))), mode: tex == nil ? 5 : 1,
                                   light: .zero, shade: .zero, angle: -atanf(L.fallAngle)))
            }
            draw(enc, inst, tex: tex ?? white)
        }
        rain(L.rainBG, near: false, sheet: "RainBG_Sheet.ktx", opacity: L.rainOpacity * 0.55, len: 0.035, speed: L.rainSpeed, seed: 0)
        rain(L.rainFG, near: true, sheet: "Rain_Sheet.ktx", opacity: L.rainOpacity, len: 0.075, speed: L.rainSpeed * 1.35, seed: 5000)
        // 6b) 水花：落在模組上緣（與畫面底部）的小水珠；每個位置各自週期，濺起 0.2 s 後散掉（概念取自 Vortex 的 splash，程式是自己的）
        if L.rainFG > 0 || L.hail > 0 {
            var inst: [Sprite] = []
            let edges = colliders.map { ($0.minX, $0.maxX, $0.minY) } + [(0, 1, 1.0)]
            let density = Float(L.rainFG + L.hail * 2) / 200
            for (ei, e) in edges.enumerated() {
                let n = Int(Float(e.1 - e.0) * 40 * density)
                for i in 0..<n {
                    let fi = Float(ei * 1000 + i)
                    let period = 0.45 + 0.5 * hash(fi * 1.7)
                    let age = fmodf(t + hash(fi * 2.9) * period, period)
                    guard age < 0.2 else { continue }
                    let k = age / 0.2
                    let x = Float(e.0) + Float(e.1 - e.0) * hash(fi * 4.3 + floorf((t + hash(fi * 2.9) * period) / period))
                    let r = (5 + 9 * k) / Float(side)
                    inst.append(Sprite(center: [x, Float(e.2) - r * 0.4], size: [r * 2.2, r * 0.9], uv: [0, 0, 1, 1],
                                       color: SIMD4(0.9, 0.95, 1, 0) * (0.5 * (1 - k) * w), mode: 6, light: .zero, shade: .zero, angle: 0))
                }
            }
            draw(enc, inst, tex: white)
        }
        // 7) 雪、霰、冰雹：Snow_Sheet 8 種雪花，左右飄
        func flakes(_ n: Int, sheet: String, size: Float, speed: Float, sway: Float, opacity: Float, seed: Float) {
            guard n > 0 else { return }
            let tex = texture(sheet, dir: Self.assetDir)
            var inst: [Sprite] = []; inst.reserveCapacity(n)
            for i in 0..<n {
                let fi = Float(i) + seed
                let sp = speed * (0.6 + 0.8 * hash(fi * 2.3))
                let y = fmodf(hash(fi * 1.1) * 1.2 + t * sp, 1.2) - 0.1
                let x = fmodf(hash(fi * 3.7) * 1.2 + sway * sinf(t * 0.8 + fi), 1.2) - 0.1
                let s = size * (0.5 + hash(fi * 5.1)) / Float(side)
                let cell = i % 8
                inst.append(Sprite(center: [x, y], size: [s, s], uv: [Float(cell % 4) * 0.25, Float(cell / 4) * 0.5, 0.25, 0.5],
                                   color: SIMD4(1, 1, 1, 1) * (opacity * w), mode: tex == nil ? 5 : 1, light: .zero, shade: .zero, angle: t * 0.3 + fi))
            }
            draw(enc, inst, tex: tex ?? white)
        }
        flakes(L.snowBG, sheet: "SnowBG_Sheet.ktx", size: 9, speed: 0.06, sway: 0.01, opacity: 0.75, seed: 0)
        flakes(L.snowFG, sheet: "Snow_Sheet.ktx", size: 20, speed: 0.12, sway: 0.02, opacity: 0.95, seed: 9000)
        flakes(L.sleet, sheet: "Sleet_Sheet.ktx", size: 7, speed: 0.9, sway: 0.003, opacity: 0.7, seed: 3000)
        flakes(L.hail, sheet: "Hail_Sheet.ktx", size: 9, speed: 1.4, sway: 0.002, opacity: 0.85, seed: 7000)
        // 8) 風：Wind_Sheet 的流線往右掃
        if L.wind * w > 0.01 {
            let tex = texture("Wind_Sheet.ktx", dir: Self.assetDir)
            var inst: [Sprite] = []
            for i in 0..<10 {
                let fi = Float(i)
                let x = fmodf(hash(fi * 2.1) * 2 + t * (0.12 + 0.08 * hash(fi)), 2) - 0.5
                let y = 0.15 + 0.75 * hash(fi * 4.7)
                inst.append(Sprite(center: [x, y], size: [0.06, 0.5], uv: [Float(i % 2) * 0.5, 0, 0.5, 1],
                                   color: SIMD4(1, 1, 1, 1) * (L.wind * w * 0.3), mode: 1, light: .zero, shade: .zero, angle: -Float.pi / 2))
            }
            draw(enc, inst, tex: tex ?? white)
        }
        // 9) 閃電本體（加亮）：每段一條亮芯＋一條寬的柔光
        if flash > 0.05, !bolt.isEmpty {
            var inst: [Sprite] = []
            for seg in bolt {
                let a = SIMD2(seg.x, seg.y), b = SIMD2(seg.z, seg.w), d = b - a
                let len = simd_length(d) * 1.08          // 稍微重疊，接縫不斷
                let ang = atan2f(-d.x, d.y)              // 四邊形的長軸 (0,1) 轉到 d
                let core: Float = 4.0 / Float(side)
                inst.append(Sprite(center: (a + b) / 2, size: [core * 7, len], uv: [0, 0, 1, 1],
                                   color: SIMD4(0.55, 0.62, 1, 0) * (flash * w * 0.35), mode: 4, light: .zero, shade: .zero, angle: ang))
                inst.append(Sprite(center: (a + b) / 2, size: [core, len], uv: [0, 0, 1, 1],
                                   color: SIMD4(0.92, 0.95, 1, 0) * (flash * w * 1.8), mode: 4, light: .zero, shade: .zero, angle: ang))
            }
            draw(enc, inst, tex: white)
        }
    }

    private func makeBolt() -> [SIMD4<Float>] {
        var segs: [SIMD4<Float>] = []
        func branch(_ x0: Float, _ y0: Float, _ y1: Float, _ spread: Float, depth: Int) {
            var x = x0, y = y0
            let steps = 14
            for _ in 0..<steps {
                let ny = y + (y1 - y0) / Float(steps)
                let nx = x + Float(rng.range(-1, 1)) * spread
                segs.append(SIMD4(x, y, nx, ny))
                if depth < 2, rng.range(0, 1) < 0.12 { branch(nx, ny, ny + (y1 - ny) * 0.5, spread * 0.8, depth: depth + 1) }
                x = nx; y = ny
            }
        }
        branch(Float(rng.range(0.25, 0.75)), -0.02, Float(rng.range(0.45, 0.7)), 0.018, depth: 0)
        return segs
    }

    private func draw(_ enc: MTLRenderCommandEncoder, _ inst: [Sprite], tex: MTLTexture, tex2: MTLTexture? = nil) {
        guard !inst.isEmpty else { return }
        var v = inst
        let bytes = v.count * MemoryLayout<Sprite>.stride
        if bytes <= 4096 { enc.setVertexBytes(&v, length: bytes, index: 0) }
        else { guard let b = device.makeBuffer(bytes: &v, length: bytes, options: .storageModeShared) else { return }; enc.setVertexBuffer(b, offset: 0, index: 0) }
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentTexture(tex2 ?? tex, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: v.count)
    }

    private func readback() -> CGImage? {
        let bpr = side * 4
        let data = NSMutableData(length: bpr * side)!
        target.getBytes(data.mutableBytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func hash(_ x: Float) -> Float { let s = sinf(x * 127.1 + 311.7) * 43758.5453; return s - floorf(s) }

    // MARK: Shader

    struct SkyUniforms {
        var top: SIMD3<Float>, mid: SIMD3<Float>, bot: SIMD3<Float>
        var midAt: Float
        var light: SIMD2<Float>
        var glow: SIMD3<Float>
        var glowStrength: Float, glowRadius: Float, sunDisc: Float, flash: Float, time: Float
    }
    struct Sprite {
        var center: SIMD2<Float>; var size: SIMD2<Float>; var uv: SIMD4<Float>; var color: SIMD4<Float>
        var mode: Int32; var light: SIMD4<Float>; var shade: SIMD4<Float>; var angle: Float
        var dir: SIMD4<Float> = .zero
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct SkyU { float3 top; float3 mid; float3 bot; float midAt; float2 light; float3 glow; float glowStrength; float glowRadius; float sunDisc; float flash; float time; };
    struct VO { float4 pos [[position]]; float2 uv; float2 q; };
    vertex VO sky_v(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VO o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); o.q = o.uv; return o;
    }
    float3 toLin(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
    float3 toSRGB(float3 c) { c = max(c, 0.0); return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }
    fragment float4 sky_f(VO in [[stage_in]], constant SkyU& u [[buffer(0)]]) {
        float y = in.uv.y;
        // 漸層在 sRGB 內插（系統天氣的漸層看起來是這樣，線性內插中段會偏亮）
        float3 a = toSRGB(u.top), b = toSRGB(u.mid), c = toSRGB(u.bot);
        float3 s = y < u.midAt ? mix(a, b, smoothstep(0.0, 1.0, y / u.midAt)) : mix(b, c, smoothstep(0.0, 1.0, (y - u.midAt) / (1 - u.midAt)));
        float3 col = toLin(s);
        float2 d = in.uv - u.light;
        float r2 = dot(d, d);
        col += u.glow * u.glowStrength * exp(-r2 / (u.glowRadius * u.glowRadius));
        float disc = smoothstep(0.045, 0.036, sqrt(r2));
        col = mix(col, float3(1.0, 0.98, 0.93) * 1.0, disc * u.sunDisc);
        col += u.glow * u.sunDisc * 0.35 * exp(-r2 / 0.006);
        // 抖動，避免 8 位元色帶
        float n = fract(sin(dot(in.pos.xy, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        col += n / 255.0 * 0.6;
        col += u.flash;
        return float4(col, 1);
    }
    struct Sp { float2 center; float2 size; float4 uv; float4 color; int mode; int _p[3]; float4 light; float4 shade; float angle; float _q[3]; float4 dir; };
    struct SO { float4 pos [[position]]; float2 uv; float2 lq; float4 color [[flat]]; int mode [[flat]]; float4 light [[flat]]; float4 shade [[flat]]; float4 dir [[flat]]; };
    vertex SO sprite_v(uint vid [[vertex_id]], uint iid [[instance_id]], const device Sp* s [[buffer(0)]]) {
        Sp p = s[iid];
        float2 q = float2(vid & 1, vid >> 1);          // 0…1
        float2 o = (q - 0.5) * p.size;
        float ca = cos(p.angle), sa = sin(p.angle);
        o = float2(o.x * ca - o.y * sa, o.x * sa + o.y * ca);
        float2 xy = p.center + o;
        SO r; r.pos = float4(xy.x * 2 - 1, 1 - xy.y * 2, 0, 1);
        r.uv = p.uv.xy + q * p.uv.zw; r.lq = q;
        r.color = p.color; r.mode = p.mode; r.light = p.light; r.shade = p.shade; r.dir = p.dir;
        return r;
    }
    fragment float4 sprite_f(SO in [[stage_in]], texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]]) {
        constexpr sampler sm(filter::linear, mip_filter::linear, address::clamp_to_edge);
        if (in.mode == 0) {           // 雲：6 向光照圖
            float4 P = t0.sample(sm, in.uv), N = t1.sample(sm, in.uv);
            float3 L = in.dir.xyz;
            float l = P.r * max(L.x, 0.0) + N.r * max(-L.x, 0.0) + P.g * max(L.y, 0.0) + N.g * max(-L.y, 0.0) + P.b * max(L.z, 0.0) + N.b * max(-L.z, 0.0);
            l = saturate(l * 1.25);
            float3 c = mix(in.shade.rgb, in.light.rgb, l);
            float a = P.a * in.color.a;
            if (in.dir.w > 0.5) a *= smoothstep(0.0, 0.18, in.lq.x) * smoothstep(1.0, 0.82, in.lq.x) * smoothstep(0.0, 0.2, in.lq.y);   // 雲毯：左右與上緣收邊
            return float4(c * a, a);
        }
        if (in.mode == 1) {           // 形狀表：alpha 是形狀，染色
            float a = t0.sample(sm, in.uv).a;
            return in.color * a;
        }
        if (in.mode == 2) {           // 噪聲：亮度當透明度，邊緣再收
            float n = t0.sample(sm, in.uv).r;
            float2 e = in.lq - 0.5; float fall = saturate(1 - dot(e, e) * 4);
            float a = n * fall * in.color.a;
            return float4(in.color.rgb * a, a);
        }
        if (in.mode == 3) {           // 圖片（月相）
            float4 c = t0.sample(sm, in.uv);
            return float4(c.rgb * c.a, c.a) * in.color.a;
        }
        if (in.mode == 4) {           // 加亮的線（閃電）：中間亮、兩側柔
            float e = 1 - abs(in.lq.x - 0.5) * 2;
            return in.color * e * e;
        }
        if (in.mode == 6) {           // 加亮的圓形光暈
            float2 e = in.lq - 0.5; float g = exp(-dot(e, e) * 18);
            return in.color * g;
        }
        // 5：圓點／替身
        float2 e = in.lq - 0.5; float a = saturate(1 - dot(e, e) * 4);
        return in.color * a;
    }
    """
}

private extension SIMD3 where Scalar == Float {
    /// 預乘 alpha 的顏色
    func pre(_ a: Float) -> SIMD4<Float> { SIMD4(self * a, a) }
}

/// 可重現的亂數（閃電的位置、間隔）
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * Double(next() >> 11) / Double(1 << 53) }
}
