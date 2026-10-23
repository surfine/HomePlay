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

    /// 鎖定畫面時間／HomeView Portraits：NSGlassEffectView .clear 的參數
    static let portrait = SystemGlassParams()
    /// Flow 泡泡字：更厚、更亮、更飽和
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
    private var sdfCache: (key: String, image: CGImage, halfStroke: CGFloat)?
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
        guard available, let device, let queue else { return nil }
        lock.lock(); defer { lock.unlock() }
        let ink = path.boundingBoxOfPath
        guard ink.width > 2, ink.height > 2 else { return nil }
        let pad = ink.height * 0.04 + 8
        let rect = ink.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024)).integral
        let w = Int((rect.width * sc).rounded(.up)), h = Int((rect.height * sc).rounded(.up))
        guard w > 4, h > 4, w <= 8192, h <= 8192 else { return nil }

        // 1. 形狀：字形遮罩 → 有號距離場（同一組字形快取，Flow 每幀只換背景）
        let maxDist = Double(max(8, ink.height * sc * 0.12))
        let sdfKey = "\(key ?? "-")|\(w)x\(h)|\(rect)"
        let sdf: CGImage, halfStroke: CGFloat
        if key != nil, let c = sdfCache, c.key == sdfKey { sdf = c.image; halfStroke = c.halfStroke } else {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: sc, y: -sc); ctx.translateBy(x: -rect.minX, y: -rect.minY)
            ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
            guard let mask = ctx.makeImage(),
                  let genCls = NSClassFromString("CASDFGenerator") as? NSObject.Type,
                  let reqCls = NSClassFromString("CASDFGeneratorRequest") as? NSObject.Type else { return nil }
            let req = reqCls.init()
            req.setValue(maxDist, forKey: "maximumDistance"); req.setValue(maxDist, forKey: "padding")
            req.setValue(-maxDist, forKey: "zeroValueDistance"); req.setValue(maxDist, forKey: "oneValueDistance")
            guard let out = genCls.init().perform(NSSelectorFromString("generateSDFWithRequest:forImage:"), with: req, with: mask)?
                    .takeUnretainedValue(), CFGetTypeID(out as CFTypeRef) == CGImage.typeID else { return nil }
            sdf = out as! CGImage
            halfStroke = Self.halfStroke(sdf, maxDist: maxDist)
            if key != nil { sdfCache = (sdfKey, sdf, halfStroke) }
        }

        return caQueue.sync { composite(sdf: sdf, halfStroke: halfStroke, maxDist: maxDist, rect: rect, w: w, h: h, sc: sc,
                                        backdrop: backdrop, params: p, lightTurn: lightTurn, device: device, queue: queue) }
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
        root.addSublayer(bg)
        guard let backdropLayer = Self.make("CABackdropLayer"), let sdfLayer = Self.make("CASDFLayer"),
              let element = Self.make("CASDFElementLayer"), let filter = Self.filter(params: p, halfStroke: halfStroke, scale: sc),
              let effect = (NSClassFromString("CASDFOutputEffect") as? NSObject.Type)?.init()
        else { CATransaction.commit(); return nil }
        backdropLayer.frame = bounds
        backdropLayer.setValue([filter], forKey: "filters")
        backdropLayer.setValue(1.0, forKey: "scale"); backdropLayer.setValue(0.5, forKey: "marginWidth")
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
        if p.rim > 0, let hl = Self.make("CASDFLayer"), let el2 = Self.make("CASDFElementLayer"),
           let fx = Self.highlight(alpha: p.rim, halfStroke: halfStroke, key: p.keyAmount, fill: p.fillAmount) {
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
    private static func highlight(alpha: CGFloat, halfStroke: CGFloat, key: CGFloat, fill: CGFloat) -> NSObject? {
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

    private static func make(_ name: String) -> CALayer? { (NSClassFromString(name) as? CALayer.Type)?.init() }

    /// glassBackground 濾鏡：底子是 NSGlassEffectView(.clear) 量到的整組值，再按字的粗細換算折射帶
    private static func filter(params p: SystemGlassParams, halfStroke: CGFloat, scale sc: CGFloat) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              let f = cls.perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")?.takeUnretainedValue() as? NSObject,
              let keys = f.value(forKey: "inputKeys") as? [String], keys.contains("inputInnerRefractionHeight") else { return nil }
        let height = max(2, halfStroke * p.refractionHeight)
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
            "inputShadowColorMatrixSaturation": 1.2, "inputShadowColorMatrixWhite": 1,
            "inputShadowColorMatrixFillColor": CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1),
            "inputShadowOffset": NSValue(size: NSSize(width: 0, height: 8)),
            "inputSourceSublayerName": "@0",
        ]
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
