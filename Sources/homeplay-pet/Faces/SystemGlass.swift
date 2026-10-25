// 液態玻璃（系統版）：直接用 macOS 27 自己畫 Liquid Glass 的那套 Core Animation 零件，離屏算一張圖。
//
// 拆 NSGlassEffectView 看到的結構：CABackdropLayer（濾鏡 glassBackground，約 80 個參數：內折射、模糊、面色矩陣、
// 主光高光……）底下掛一個 CASDFLayer「@0」（輸出效果 CASDFOutputEffect），裡面的 CASDFElementLayer 決定玻璃的形狀。
// 元素層 mode = "contents" 時，形狀來自 contents 裡的有號距離場圖；這張圖用 QuartzCore 自己的 CASDFGenerator 從字形遮罩產生。
// 整棵層樹交給 CARenderer 畫進 Metal 貼圖，所以不需要視窗，也能用在貼到 3D 上的錶面。
//
// 全是私有類別：任何一個找不到（系統改版）就回 nil，呼叫端退回自己寫的光學 shader（LiquidGlass）。
// HOMEPLAY_GLASS=shader 強制用 shader 版；HOMEPLAY_GLASS_SET="inputBlurRadius=6,…" 覆寫濾鏡參數（調參用）。

import AppKit
import Metal
import QuartzCore
import CoreImage

struct SystemGlassParams {
    var refractionHeight: CGFloat = 1.0    // 內折射帶寬（相對筆畫半寬：整個筆畫都是透鏡）
    var refractionAmount: CGFloat = -4.3   // 內折射量（相對帶寬；負的＝往內收，像凸透鏡）
    var blurRadius: CGFloat = 3            // 透出背景的模糊（1024 邏輯座標）：小一點，透鏡裡看得清背景
    var highlight: CGFloat = 0.4           // 主光高光量
    var white: CGFloat = 0.95, black: CGFloat = 0.08, saturation: CGFloat = 1.0   // .clear 的 black 是 0.2，字大時太灰
    var fill: CGFloat = 0.10               // 面的白色填充不透明度
    var rim: CGFloat = 1.0                 // 沿輪廓的主光／補光亮邊（@2 層的 keyColor 不透明度；系統互動時才亮，錶面一直亮）
    var keyAmount: CGFloat = 0.9, fillAmount: CGFloat = 0.5   // 主光／補光亮邊強度（系統兩個都是 0.5）
    var tint: CGColor? = nil               // 染色（「字體與顏色」的色票；nil＝原本的淡白）
    var ringShadow: CGFloat = 0.6          // 內緣一圈暗（filter 的 RingShadow，.regular 才有）：玻璃的厚度
    /// 2.0 R13：控制（按鈕、膠囊、磚）——折射帶與暗環用 NSGlassEffectView 量到的固定尺寸（1024 畫布單位），不跟形狀大小走；
    /// 亮邊照系統按鈕的 @2（曲率 0.75、展開 1.396），rim 是它的 keyColor 不透明度（系統平常 0，互動時才亮）
    var control = false
    /// 其餘 glassBackground 參數（名字照濾鏡的 inputKeys；長度單位是 1024 畫布，會乘上解析度）
    var extra: [String: Double] = [:]
    var extraLengths: Set<String> = []
    var shadowFillAlpha: CGFloat = 0.1
    var shadowSaturation: CGFloat = 1.2

    /// 鎖定畫面時間／HomeView Portraits：NSGlassEffectView .clear 的參數
    static let portrait = SystemGlassParams()
    /// Flow 泡泡字：更厚、更亮、更飽和
    /// 2.0 R13：NSGlassEffectView 兩種 style 在 macOS 27 量到的 glassBackground（2026-10-24 拆 200×60 pt、圓角 30 的實例；
    /// 量測腳本 scratchpad/r2probe/probe.swift）。長度換到畫布：系統 60 pt 高的鈕對應我們 88 px 的觸控尺寸，k＝88/60
    /// 2.0 glass：1 pt 等於幾個 1024 畫布 px。HomeView 實機 1088 px ≈ 544 pt，我們的 1024 畫布 ≈ 1.88 px／pt（chan-notes）；
    /// 校準台（視窗 512 pt＝1024 px）跑的時候暫時設成 2。原本用 88/60（把系統 60 pt 的鈕當成 88 px），長度全都小了兩成多
    nonisolated(unsafe) static var ptToCanvas: CGFloat = 1.88
    static var controlK: CGFloat { ptToCanvas }
    /// .regular：淺色模式的控制（霜面、亮、有暗環與 bleed）
    static let regular: SystemGlassParams = {
        let k = controlK
        var p = SystemGlassParams(refractionHeight: 15 * k, refractionAmount: -2.0, blurRadius: 5 * k, highlight: 0.5,
                                  white: 0.96, black: 0.4, saturation: 1.2, fill: 0.2, rim: 0, keyAmount: 0.5, fillAmount: 0.5, ringShadow: 0)
        p.control = true
        p.extra = ["inputBleedAmount": 21, "inputBleedHeight": 21, "inputBleedColorMatrixBlack": 0.9,
                   "inputBlurFillBlurRadius": 8, "inputBlurFillLightenOpacity": 0.9, "inputBlurFillNormalOpacity": 0.5,
                   "inputBlurOpacity0": 0.4, "inputBlurOpacity1": 0.4, "inputFaceColorMatrixMaxLumaSDR": 0.94,
                   "inputKeyFillHighlightColorBias": -0.1875, "inputKeyFillHighlightSpread": 2.094395102393195,
                   "inputKeyFillHighlightSpreadSDR": 2.094395102393195,
                   "inputRingShadowMask": 1, "inputRingShadowBlurRadius": 5, "inputRingShadowOffset": 8, "inputRingShadowStrokeWidth": 4]
        p.extraLengths = ["inputBleedAmount", "inputBleedHeight", "inputBlurFillBlurRadius", "inputRingShadowBlurRadius", "inputRingShadowOffset", "inputRingShadowStrokeWidth"]
        p.shadowFillAlpha = 0.3; p.shadowSaturation = 1
        return p
    }()
    /// .regular 在深色外觀下（同一顆 NSGlassEffectView，window.appearance = darkAqua 量到的差異）
    static let regularDark: SystemGlassParams = {
        var p = regular
        p.black = 0.08; p.white = 1.125; p.saturation = 1.3; p.fill = 0
        p.extra.merge(["inputBleedColorMatrixBlack": 0.125, "inputBleedColorMatrixSaturation": 1, "inputBleedColorMatrixWhite": 0.5,
                       "inputBleedDarkenBlend": 0, "inputBlurFillDarkenOpacity": 0.9, "inputBlurFillLightenOpacity": 0,
                       "inputClamp": 1.308311, "inputFaceColorMatrixMaxLuma": 0.6, "inputFaceColorMatrixMaxLumaSDR": 0.6]) { $1 }
        return p
    }()
    /// .clear：只用在媒體（照片、影片、封面、模糊的錶面）上的控制——透明、折射多；亮的背景上另加 0–35% 壓暗（GlassPass）
    static let clearControl: SystemGlassParams = {
        let k = controlK
        var p = SystemGlassParams(refractionHeight: 20 * k, refractionAmount: -1.95, blurRadius: 5.833333 * k, highlight: 0.4,
                                  white: 0.95, black: 0.2, saturation: 1.0, fill: 0.1, rim: 0, keyAmount: 0.5, fillAmount: 0.5, ringShadow: 0)
        p.control = true
        return p
    }()
    static let bubble = SystemGlassParams(refractionHeight: 1.0, refractionAmount: -3.4, blurRadius: 3, highlight: 0.55,
                                          white: 1.0, black: 0.12, saturation: 1.3, fill: 0.06, rim: 1.0,
                                          keyAmount: 1.0, fillAmount: 0.6, ringShadow: 0.5)
}

final class SystemGlass {
    static let shared = SystemGlass()
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let lock = NSLock()
    /// 層樹在自己的執行緒上建、提交、渲染：錶面常在別人的 CATransaction 裡畫，那裡 flush 不會提交我們的樹
    private let caQueue = DispatchQueue(label: "homeplay.systemglass")
    private var sdfCache: (key: String, image: CGImage, halfStroke: CGFloat, mask: CGImage)?
    let available: Bool

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        let names = ["CABackdropLayer", "CASDFLayer", "CASDFElementLayer", "CASDFOutputEffect", "CASDFKeyFillHighlightEffect",
                     "CASDFGenerator", "CASDFGeneratorRequest", "CAFilter"]
        available = device != nil && ProcessInfo.processInfo.environment["HOMEPLAY_GLASS"] != "shader"
            && names.allSatisfy { NSClassFromString($0) != nil }
    }

    /// 同 LiquidGlass.render：path 是 1024 邏輯座標（左上原點），backdrop 是整張 1024² 背景。
    /// 回傳的圖是「背景＋玻璃」的合成（不透明），呼叫端要用字形裁切後再畫。
    /// lightTurn：主光從預設方向再轉幾弧度（Flow 讓亮邊跟著人轉，像 iPhone 斜著看鎖定畫面）；只改效果參數，不重建層樹
    func render(path: CGPath, key: String?, scale sc: CGFloat, backdrop: CGImage, params p: SystemGlassParams,
                lightTurn: CGFloat = 0) -> (image: CGImage, rect: CGRect)? {
        renderContainer(path: path, key: key, scale: sc, backdrop: backdrop, params: p, lightTurn: lightTurn).map { ($0.image, $0.rect) }
    }

    /// 2.0 R13：GlassEffectContainer——merge＞0 時，彼此距離小於約 2×merge 的形狀在距離場裡融成一塊（像官方玻璃黏在一起）。
    /// 多回一張形狀遮罩（rect 範圍、上緣在第一列），呼叫端用它裁切，融合的橋也在裡面
    func renderContainer(path: CGPath, key: String?, scale sc: CGFloat, backdrop: CGImage, params p: SystemGlassParams,
                         lightTurn: CGFloat = 0, merge: CGFloat = 0) -> (image: CGImage, rect: CGRect, mask: CGImage)? {
        guard available, let device, let queue else { return nil }
        lock.lock(); defer { lock.unlock() }
        let ink = path.boundingBoxOfPath
        guard ink.width > 2, ink.height > 2 else { return nil }
        let pad = ink.height * 0.04 + 8
        let rect = ink.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024)).integral
        let w = Int((rect.width * sc).rounded(.up)), h = Int((rect.height * sc).rounded(.up))
        guard w > 4, h > 4, w <= 8192, h <= 8192 else { return nil }

        // 1. 形狀：字形遮罩 → 有號距離場（同一組字形快取，Flow 每幀只換背景）
        // 2.0 glass：控制的折射帶最多 20 pt（≈ 38 px）、bleed 是短邊的 35%：距離場至少要深到短邊的一半，
        // 原本 12% 高度（88 px 的圓只有 10.6 px）把折射帶截平了
        let maxDist = Double(max(8, p.control ? min(ink.width, ink.height) * sc * 0.5 : ink.height * sc * 0.12))
        let sdfKey = "\(key ?? "-")|\(w)x\(h)|\(rect)|\(merge)"
        let sdf: CGImage, halfStroke: CGFloat, shapeMask: CGImage
        if key != nil, let c = sdfCache, c.key == sdfKey { sdf = c.image; halfStroke = c.halfStroke; shapeMask = c.mask } else {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: sc, y: -sc); ctx.translateBy(x: -rect.minX, y: -rect.minY)
            ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
            guard var mask = ctx.makeImage(),
                  let genCls = NSClassFromString("CASDFGenerator") as? NSObject.Type,
                  let reqCls = NSClassFromString("CASDFGeneratorRequest") as? NSObject.Type else { return nil }
            if merge > 0, let m = Self.metaball(mask, sigma: merge * sc) { mask = m }
            _ = genCls; _ = reqCls
            guard let out = Self.sdf(mask, maxDist: maxDist) else { return nil }
            sdf = out
            halfStroke = Self.halfStroke(sdf, maxDist: maxDist)
            shapeMask = Self.grayMask(mask) ?? mask
            if key != nil { sdfCache = (sdfKey, sdf, halfStroke, mask) }
        }

        return caQueue.sync { composite(sdf: sdf, halfStroke: halfStroke, maxDist: maxDist, rect: rect, w: w, h: h, sc: sc,
                                        backdrop: backdrop, params: p, lightTurn: lightTurn, device: device, queue: queue) }
            .map { ($0.image, $0.rect, shapeMask) }
    }

    private func composite(sdf: CGImage, halfStroke: CGFloat, maxDist: Double, rect: CGRect, w: Int, h: Int, sc: CGFloat,
                           backdrop: CGImage, params p: SystemGlassParams, lightTurn: CGFloat, device: MTLDevice, queue: MTLCommandQueue) -> (image: CGImage, rect: CGRect)? {
        let t0 = CACurrentMediaTime()
        // 2. 層樹：背景 → 玻璃背板（濾鏡）→ SDF 形狀
        let k = CGFloat(backdrop.width) / 1024
        guard let crop = backdrop.cropping(to: CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).integral)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let pipeKey = "\(ObjectIdentifier(sdf).hashValue)|\(w)x\(h)|\(p)"
        let pipe: Pipeline
        if let c = pipeline, c.key == pipeKey {
            // 同一組字形：整套層樹與 renderer 重用，只換背景（Flow 每幀走這裡）
            pipe = c
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pipe.bg.contents = crop
            if let fx = pipe.effect, let hl = pipe.highlight {
                fx.setValue(Self.keyAngle + Double(lightTurn), forKey: "keyAngle"); fx.setValue(Self.keyAngle + .pi + Double(lightTurn), forKey: "fillAngle")
                hl.setValue(fx, forKey: "effect")   // 效果物件改了要重新指定，CA 才會重新提交
            }
            CATransaction.commit()
            CATransaction.flush()
        } else {
            guard let built = build(sdf: sdf, crop: crop, halfStroke: halfStroke, maxDist: maxDist, bounds: bounds, sc: sc, params: p,
                                    device: device, queue: queue, key: pipeKey) else { return nil }
            pipe = built; pipeline = built
            if lightTurn != 0, let fx = pipe.effect, let hl = pipe.highlight {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                fx.setValue(Self.keyAngle + Double(lightTurn), forKey: "keyAngle"); fx.setValue(Self.keyAngle + .pi + Double(lightTurn), forKey: "fillAngle")
                hl.setValue(fx, forKey: "effect")
                CATransaction.commit(); CATransaction.flush()
            }
        }
        pipe.renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        pipe.renderer.addUpdate(bounds); pipe.renderer.render(); pipe.renderer.endFrame()
        let tex = pipe.texture
        guard let cb = queue.makeCommandBuffer() else { return nil }
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let ms = (CACurrentMediaTime() - t0) * 1000
        if let dir = ProcessInfo.processInfo.environment["HOMEPLAY_GLASS_DUMP"] {   // 除錯：存下距離場與合成結果
            for (name, im) in [("sdf", sdf), ("out", img), ("bg", crop)] {
                try? NSBitmapImageRep(cgImage: im).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/glass-\(name).png"))
            }
            log("system glass \(w)x\(h) \(String(format: "%.1f", ms)) ms halfStroke \(halfStroke) maxDist \(maxDist)")
        }
        return (img, rect)
    }

    private struct Pipeline {
        let key: String; let root: CALayer; let bg: CALayer; let renderer: CARenderer; let texture: MTLTexture
        let highlight: CALayer?; let effect: NSObject?
    }
    private var pipeline: Pipeline?

    /// 建一套層樹（背景 → 玻璃背板 → SDF 形狀 → 亮邊）與 renderer
    private func build(sdf: CGImage, crop: CGImage, halfStroke: CGFloat, maxDist: Double, bounds: CGRect, sc: CGFloat, params p: SystemGlassParams,
                       device: MTLDevice, queue: MTLCommandQueue, key: String) -> Pipeline? {
        let w = Int(bounds.width), h = Int(bounds.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let root = CALayer(); root.frame = bounds
        let bg = CALayer(); bg.frame = bounds; bg.contents = crop; bg.contentsGravity = .resize
        // 2.0 第三輪：背景跟 SDF 一樣在 CARenderer 裡是上下顛倒的（讀回貼圖時第一列是上緣）——沒翻的話玻璃裡折射的是
        // 上下鏡像的背景：小控制在均勻底上看不出來，形狀合成一個大容器時（食譜封面的 ✕＋兩顆膠囊）右下膠囊裡會出現右上「10:09」的鬼影
        bg.transform = CATransform3DMakeScale(1, -1, 1)
        root.addSublayer(bg)
        guard let backdropLayer = Self.make("CABackdropLayer"), let sdfLayer = Self.make("CASDFLayer"),
              let element = Self.make("CASDFElementLayer"), let filter = Self.filter(params: p, halfStroke: halfStroke, scale: sc),
              let effect = (NSClassFromString("CASDFOutputEffect") as? NSObject.Type)?.init()
        else { CATransaction.commit(); return nil }
        backdropLayer.frame = bounds
        backdropLayer.setValue([filter], forKey: "filters")
        // 2.0 glass：系統的 backdrop 以 0.5 倍取樣（2x 螢幕上＝每 pt 一個樣本）；控制照做，錶面維持原樣
        backdropLayer.setValue(p.control ? Double(min(1, 1 / (SystemGlassParams.ptToCanvas * sc))) : 1.0, forKey: "scale"); backdropLayer.setValue(0.5, forKey: "marginWidth")
        backdropLayer.setValue("HomePlayGlass", forKey: "groupName")
        sdfLayer.name = "@0"; sdfLayer.frame = bounds
        effect.setValue(-10000.0, forKey: "minimum"); effect.setValue(1.5, forKey: "maximum")   // 系統玻璃量到的值
        sdfLayer.setValue(effect, forKey: "effect"); sdfLayer.setValue(8.0, forKey: "smoothness")
        element.frame = bounds.insetBy(dx: -CGFloat(maxDist), dy: -CGFloat(maxDist))   // 產生器在四周各補了 maxDist
        element.transform = CATransform3DMakeScale(1, -1, 1)   // SDF 內容在 CARenderer 裡是上下顛倒的
        element.contents = sdf
        element.setValue("contents", forKey: "mode"); element.setValue("union", forKey: "operation")
        element.setValue(-maxDist, forKey: "contentsZeroValueDistance"); element.setValue(maxDist, forKey: "contentsOneValueDistance")
        sdfLayer.addSublayer(element); backdropLayer.addSublayer(sdfLayer); root.addSublayer(backdropLayer)
        // 亮邊：系統玻璃樹裡的「@2」—— 另一個 CASDFLayer，效果是 CASDFKeyFillHighlightEffect，形狀和 @0 同一份
        var hlLayer: CALayer?, hlEffect: NSObject?
        if p.rim > 0 || p.control, let hl = Self.make("CASDFLayer"), let el2 = Self.make("CASDFElementLayer"),
           let fx = Self.highlight(alpha: p.rim, halfStroke: p.control ? 30 * SystemGlassParams.controlK * sc * 11.5 / 30 : halfStroke, key: p.keyAmount, fill: p.fillAmount, control: p.control) {
            hlLayer = hl; hlEffect = fx
            hl.name = "@2"; hl.frame = bounds
            hl.setValue(fx, forKey: "effect")
            hl.setValue(Double(ProcessInfo.processInfo.environment["HOMEPLAY_GLASS_SMOOTH"] ?? "") ?? Double(halfStroke * 0.58), forKey: "smoothness")
            el2.frame = element.frame; el2.transform = element.transform; el2.contents = sdf
            for k in ["mode", "operation", "contentsZeroValueDistance", "contentsOneValueDistance"] { el2.setValue(element.value(forKey: k), forKey: k) }
            hl.addSublayer(el2); root.addSublayer(hl)
        }
        CATransaction.commit()

        // 3. CARenderer 離屏畫進貼圖，等 GPU 做完再讀回
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        let r = CARenderer(mtlTexture: tex, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                       kCARendererMetalCommandQueue: queue])
        r.layer = root; r.bounds = bounds
        CATransaction.flush()   // 層樹接上 renderer 之後才 flush；先 flush 或不 flush，CARenderer 看到的都是空樹
        return Pipeline(key: key, root: root, bg: bg, renderer: r, texture: tex, highlight: hlLayer, effect: hlEffect)
    }

    /// NSGlassEffectView 裡 @2 的 CASDFKeyFillHighlightEffect，量到的值為底。系統是照按鈕（筆畫約 12 px）調的，
    /// 錶面的字粗得多：亮邊高度跟著筆畫半寬放大、曲率降低、主光改從左上斜照（補光在對角），否則只剩上下兩條硬白線。
    private static func highlight(alpha: CGFloat, halfStroke: CGFloat, key: CGFloat, fill: CGFloat, control: Bool = false) -> NSObject? {
        guard let fx = (NSClassFromString("CASDFKeyFillHighlightEffect") as? NSObject.Type)?.init() else { return nil }
        let hs = Double(max(1, halfStroke / 11.5))
        let v: [String: Double] = [
            "keyHeightScale": hs, "keyHeightOffset": 0, "keySpreadScale": 1, "keySpreadOffset": 0,
            "fillHeightScale": hs, "fillHeightOffset": 0, "fillSpreadScale": 1, "fillSpreadOffset": 0,
            "keyHeight": 1, "keyAngle": keyAngle, "keySpread": 1.548979711144967, "keyAmount": Double(key),
            "fillHeight": 1, "fillAngle": keyAngle + .pi, "fillSpread": 1.548979711144967, "fillAmount": Double(fill),
            "diffuseHeightScale": 8, "diffuseAmountScale": 0.15, "diffuseSpreadScale": 0.65, "curvature": 0.3,
        ]
        var v2 = v
        if control {   // 2.0 R13：系統按鈕 @2 量到的值
            v2["curvature"] = 0.75; v2["keySpread"] = 1.396263401595464; v2["fillSpread"] = 1.396263401595464
        }
        for kv in (ProcessInfo.processInfo.environment["HOMEPLAY_GLASS_HL"] ?? "").split(separator: ",") {
            let pair = kv.split(separator: "=")
            if pair.count == 2, let d = Double(pair[1]) { v2[String(pair[0])] = d }
        }
        for (k, x) in v2 { fx.setValue(x, forKey: k) }
        fx.setValue(false, forKey: "global")
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
        fx.setValue(white, forKey: "keyColor"); fx.setValue(white, forKey: "fillColor")
        return fx
    }

    static let keyAngle = Double.pi * 0.75

    /// 形狀遮罩糊開再取 0.5 的等高線：相近的形狀之間長出平滑的橋（SDF smooth union 的近似），遠的形狀只是圓角略收
    static func metaball(_ mask: CGImage, sigma: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: mask)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: ci.extent)
        guard let th = CIFilter(name: "CIColorThreshold") else { return nil }
        th.setValue(blurred, forKey: kCIInputImageKey); th.setValue(0.42, forKey: "inputThreshold")
        guard let out = th.outputImage, let alpha = CIFilter(name: "CIMaskToAlpha") else { return nil }
        // 硬邊再柔一點點（抗鋸齒），再把亮度變成 alpha（跟原本的遮罩一樣：白、透明底）
        alpha.setValue(out.applyingGaussianBlur(sigma: 0.6).cropped(to: ci.extent), forKey: kCIInputImageKey)
        guard let a = alpha.outputImage else { return nil }
        return Face.ciContext.createCGImage(a, from: ci.extent)
    }

    /// 2.0 glass：融合組的裁切遮罩（rect 範圍、上緣在第一列、DeviceGray 沒有 alpha）：形狀糊開（σ＝merge）取 0.42 的等高線，橋也在裡面。
    /// 糊開在 CI 做、等高線在 CPU 做（原本 CIColorThreshold＋CIMaskToAlpha 再轉 L8，覆蓋率只剩 0.5，融合的玻璃貼回去只剩一半）
    func mergeMask(path: CGPath, rect: CGRect, scale sc: CGFloat, merge: CGFloat) -> CGImage? {
        let w = Int((rect.width * sc).rounded(.up)), h = Int((rect.height * sc).rounded(.up))
        let gray = CGColorSpaceCreateDeviceGray()
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: gray,
                                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: sc, y: -sc); ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.addPath(path); ctx.setFillColor(gray: 1, alpha: 1); ctx.fillPath()
        guard let mask = ctx.makeImage() else { return nil }
        let ci = CIImage(cgImage: mask)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(merge * sc)).cropped(to: ci.extent)
        var px = [UInt8](repeating: 0, count: w * h)
        Face.ciContext.render(blurred, toBitmap: &px, rowBytes: w, bounds: ci.extent, format: .L8, colorSpace: gray)
        // 等高線 0.42，兩側 ±0.04 做抗鋸齒
        for i in 0..<px.count {
            let v = Double(px[i]) / 255
            px[i] = UInt8(max(0, min(1, (v - 0.38) / 0.08)) * 255)
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: gray,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 白＋alpha 的形狀圖 → DeviceGray、沒有 alpha 的裁切遮罩（灰階＝覆蓋率）。
    /// 2.0 glass：原本用 CIContext 轉 L8，出來的灰階只有 0.5（融合的玻璃貼回去只剩一半），校準台的 pair 才看出來
    static func grayMask(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        g.setFillColor(gray: 0, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: w, height: h))
        g.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return g.makeImage()
    }

    /// 遮罩 → 有號距離場（QuartzCore 自己的 CASDFGenerator；四周各補 maxDist 像素）
    static func sdf(_ mask: CGImage, maxDist: Double) -> CGImage? {
        guard let genCls = NSClassFromString("CASDFGenerator") as? NSObject.Type,
              let reqCls = NSClassFromString("CASDFGeneratorRequest") as? NSObject.Type else { return nil }
        let req = reqCls.init()
        req.setValue(maxDist, forKey: "maximumDistance"); req.setValue(maxDist, forKey: "padding")
        req.setValue(-maxDist, forKey: "zeroValueDistance"); req.setValue(maxDist, forKey: "oneValueDistance")
        guard let out = genCls.init().perform(NSSelectorFromString("generateSDFWithRequest:forImage:"), with: req, with: mask)?
                .takeUnretainedValue(), CFGetTypeID(out as CFTypeRef) == CGImage.typeID else { return nil }
        return (out as! CGImage)
    }

    private static func make(_ name: String) -> CALayer? { (NSClassFromString(name) as? CALayer.Type)?.init() }

    /// glassBackground 濾鏡：底子是 NSGlassEffectView(.clear) 量到的整組值，再按字的粗細換算折射帶
    private static func filter(params p: SystemGlassParams, halfStroke: CGFloat, scale sc: CGFloat) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              let f = cls.perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")?.takeUnretainedValue() as? NSObject,
              let keys = f.value(forKey: "inputKeys") as? [String], keys.contains("inputInnerRefractionHeight") else { return nil }
        let height = p.control ? max(2, min(halfStroke * 0.9, p.refractionHeight * sc)) : max(2, halfStroke * p.refractionHeight)
        var v: [String: Any] = [
            "inputBleedColorMatrixBlack": 0.75, "inputBleedColorMatrixSaturation": 1.2, "inputBleedColorMatrixWhite": 1,
            "inputBleedDarkenBlend": 1, "inputBleedDistance0": 1,
            "inputBlurOpacity0": 1, "inputBlurOpacity1": 1, "inputBlurOpacity2": 1, "inputBlurOpacity3": 1,
            "inputBlurRadius": p.blurRadius * sc, "inputClamp": 1,
            "inputFaceColorMatrixBlack": p.black, "inputFaceColorMatrixWhite": p.white, "inputFaceColorMatrixSaturation": p.saturation,
            "inputFaceColorMatrixFillColor": p.tint ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: p.fill),
            "inputFaceColorMatrixMaxLuma": 1, "inputFaceColorMatrixMaxLumaSDR": 1, "inputFaceOpacity": 1,
            "inputInnerRefractionAmount": p.refractionAmount * height, "inputInnerRefractionHeight": height,
            // 內緣暗環：系統 .regular 的 RingShadow（5／8／4 px），按筆畫粗細放大
            "inputRingShadowOpacity": p.ringShadow, "inputRingShadowMask": p.ringShadow > 0 ? 1 : 0,
            "inputRingShadowBlurRadius": halfStroke * 0.17, "inputRingShadowOffset": halfStroke * 0.23,
            "inputRingShadowStrokeWidth": halfStroke * 0.145,
            "inputKeyFillHighlightAmount": p.highlight, "inputKeyFillHighlightAngle": Double.pi / 2,
            "inputKeyFillHighlightColorBias": -0.25, "inputKeyFillHighlightEffectOffset": -0.5, "inputKeyFillHighlightHeight": 0.5,
            "inputKeyFillHighlightSpread": 1.308996938995747, "inputKeyFillHighlightSpreadSDR": 1.308996938995747,
            "inputMaxHeadroom": 9999, "inputRefractionDistance0": -1,
            "inputSDRGradientDistance0": 1, "inputSDRGradientDistance1": 1, "inputSDRHoldingToneWhite": 1,
            "inputShadowColorMatrixSaturation": p.shadowSaturation, "inputShadowColorMatrixWhite": 1,
            "inputShadowColorMatrixFillColor": CGColor(srgbRed: 0, green: 0, blue: 0, alpha: p.shadowFillAlpha),
            "inputShadowOffset": NSValue(size: NSSize(width: 0, height: 8)),
            "inputSourceSublayerName": "@0",
        ]
        if p.control { v["inputRingShadowMask"] = 0; v["inputRingShadowOpacity"] = 0 }
        for (k, x) in p.extra { v[k] = p.extraLengths.contains(k) ? x * Double(SystemGlassParams.controlK * sc) : x }
        for kv in (ProcessInfo.processInfo.environment["HOMEPLAY_GLASS_SET"] ?? "").split(separator: ",") {
            let pair = kv.split(separator: "=")
            if pair.count == 2, let d = Double(pair[1]) { v[String(pair[0])] = d }
        }
        for (key, value) in v where keys.contains(key) { f.setValue(value, forKey: key) }
        return f
    }

    /// 最粗筆畫的半寬（像素）：距離場裡最深（值最小）的點。用來把折射帶換算成「筆畫的幾成」，粗細字都一樣好看。
    private static func halfStroke(_ sdf: CGImage, maxDist: Double) -> CGFloat {
        guard let data = sdf.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return CGFloat(maxDist) }
        let bpp = sdf.bitsPerPixel / 8, row = sdf.bytesPerRow
        var low: UInt8 = 255
        for y in stride(from: 0, to: sdf.height, by: 2) {
            for x in stride(from: 0, to: sdf.width, by: 2) { low = min(low, ptr[y * row + x * bpp]) }
        }
        // R 通道：0 ↔ -maxDist（字裡最深），255 ↔ +maxDist（字外）；邊緣是 0.5
        return CGFloat(max(1, (1 - Double(low) / 255 * 2) * maxDist))
    }
}
