// 2.0 glass：真的 NSGlassEffectView 層樹，離屏畫。
//
// 校準台（Design/GlassCalibrate.swift）比出來：自己拼的 CABackdropLayer＋CASDF 樹跟系統差在很多地方——
// 參數跟著形狀短邊變（折射帶、bleed、模糊不透明度、深色的 maxLuma、Clear 的模糊與 shadow 都有尺寸規律）、
// backdrop 取樣 scale 0.5、形狀是 CASDFElementLayer 的 bounds 模式（連續曲率圓角，不是距離場圖）、
// 染色是另一棵子樹（vibrantColorMatrix＋CASDFGradientEffect＋CASDFFillEffect）、容器融合是 SDF 的 smooth union。
// 與其一條一條追，不如直接用系統的：在不上螢幕的視窗裡擺真的 NSGlassEffectView（與 NSGlassEffectContainerView），
// 把背景放在同一棵樹的底層，整棵交給 CARenderer 畫進 Metal 貼圖。AppKit 在 layout＋display＋flush 之後就把樹建好了，
// 不必跑 run loop；跟 WindowServer 的實拍逐像素比 ΔE 在 1 以內（見 tooling/glass-compare.py 的報告）。
//
// 只能在主執行緒（AppKit view）；不是主執行緒、或系統沒有這些類別，就回 nil，呼叫端退回 SystemGlass 的自拼版。
// HOMEPLAY_GLASS=legacy 強制用自拼版（對照用）。

import AppKit
import Metal
import QuartzCore

final class NativeGlass {
    static let shared = NativeGlass()

    /// 一個玻璃形狀（1024 畫布座標）。path 不是 nil＝不是圓角矩形，形狀改用距離場圖（element 的 contents 模式）
    struct Shape {
        var rect: CGRect
        var radius: CGFloat
        var continuous: Bool
        var path: CGPath? = nil
        var key: String { "\(Int(rect.minX * 4)),\(Int(rect.minY * 4)),\(Int(rect.width * 4)),\(Int(rect.height * 4)),\(Int(radius * 4)),\(continuous)\(path == nil ? "" : "p")" }
    }
    struct Request {
        var shapes: [Shape]
        var clear: Bool
        var dark: Bool
        var tint: NSColor?
        /// 融合距離（畫布 px）：> 0 時形狀放進 NSGlassEffectContainerView（spacing＝這個距離）
        var merge: CGFloat = 0
        /// 亮邊 0…1（靜止的亮緣或按著）：系統 @2（CASDFKeyFillHighlightEffect）層的 opacity
        var press: CGFloat = 0
        /// materialize 0…1：glassBackground 的折射、模糊、bleed、面色一起從 0 長出來
        var presence: CGFloat = 1
        var scale: CGFloat = 1
        /// 2.0 glass：iOS＝HomeView 的玻璃（IOSGlass 把參數換成 iOS 27 量到的）；macOS＝NSGlassEffectView 原樣
        var platform: HPGlassPlatform = .iOS
        /// 這組形狀在同一個 GlassEffectContainer 裡（iOS：共用一個 backdrop，尺寸規律跟整組的最小／最大短邊走）
        var container = false
    }

    let available: Bool
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    nonisolated(unsafe) static var stats = (renders: 0, builds: 0, refused: 0)

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        let env = ProcessInfo.processInfo.environment["HOMEPLAY_GLASS"]
        available = device != nil && env != "legacy" && env != "shader" && NSClassFromString("NSGlassEffectView") != nil
            && NSClassFromString("NSGlassEffectContainerView") != nil
    }

    private final class Flipped: NSView { override var isFlipped: Bool { true } }
    private struct Pipe {
        let key: String; let window: NSWindow; let root: NSView; let host: CALayer
        let renderer: CARenderer; let texture: MTLTexture; let rect: CGRect; let w: Int; let h: Int
    }
    /// 最近用過的幾套層樹（一幀常有好幾組：無色、染色、按著的那顆），換背景就重用，不重建
    private var pipes: [Pipe] = []

    /// 背景＋玻璃的合成（rect 範圍、不透明、第一列是上緣）。呼叫端用形狀裁切後貼回去
    func render(_ q: Request, backdrop: CGImage) -> (image: CGImage, rect: CGRect)? {
        guard available, Thread.isMainThread, let device, let queue, !q.shapes.isEmpty else { NativeGlass.stats.refused += 1; return nil }
        var ink = q.shapes[0].rect
        for s in q.shapes.dropFirst() { ink = ink.union(s.rect) }
        // iOS 的濾鏡自己畫外陰影（CASDFOutputEffect maximum 最多約 40 pt）：取樣範圍要包得住
        let side = Double((q.shapes.map { min($0.rect.width, $0.rect.height) }.max() ?? 0) / SystemGlassParams.ptToCanvas)
        let pad: CGFloat = q.platform == .iOS ? max(12, CGFloat(IOSGlass.outputMaximum(side: side, clear: q.clear, dark: q.dark)) * SystemGlassParams.ptToCanvas + 4) : 12
        let rect = ink.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024)).integral
        let sc = q.scale
        let w = Int((rect.width * sc).rounded(.up)), h = Int((rect.height * sc).rounded(.up))
        guard w > 4, h > 4, w <= 8192, h <= 8192 else { return nil }
        let tk = q.tint.flatMap { $0.usingColorSpace(.sRGB) }.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? "-"
        let key = q.shapes.map(\.key).joined(separator: ";") + "|\(q.clear)|\(q.dark)|\(tk)|\(q.merge)|\(String(format: "%.3f|%.3f", q.press, q.presence))|\(sc)|\(rect)|\(SystemGlassParams.ptToCanvas)|\(q.platform)|\(q.container)"
        let k = SystemGlassParams.ptToCanvas
        let bk = CGFloat(backdrop.width) / 1024
        guard let crop = backdrop.cropping(to: CGRect(x: rect.minX * bk, y: rect.minY * bk, width: rect.width * bk, height: rect.height * bk).integral) else { return nil }

        let p: Pipe
        if let i = pipes.firstIndex(where: { $0.key == key }) {
            p = pipes.remove(at: i); pipes.append(p)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            p.root.layer?.contents = crop
            CATransaction.commit()
        } else {
            guard #available(macOS 26.0, *), let built = build(q, rect: rect, w: w, h: h, k: k, crop: crop, key: key, device: device, queue: queue) else { return nil }
            p = built; pipes.append(built)
            if pipes.count > 8 { pipes.removeFirst() }
            NativeGlass.stats.builds += 1
        }
        CATransaction.flush()
        p.renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        p.renderer.addUpdate(CGRect(x: 0, y: 0, width: w, height: h)); p.renderer.render(); p.renderer.endFrame()
        guard let cb = queue.makeCommandBuffer() else { return nil }
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        p.texture.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        NativeGlass.stats.renders += 1
        if let dir = ProcessInfo.processInfo.environment["HOMEPLAY_GLASS_DUMP"] {   // 除錯：存下每次的合成結果
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/native-\(NativeGlass.stats.renders).png"))
        }
        return (img, rect)
    }

    @available(macOS 26.0, *)
    private func build(_ q: Request, rect: CGRect, w: Int, h: Int, k: CGFloat, crop: CGImage, key: String,
                       device: MTLDevice, queue: MTLCommandQueue) -> Pipe? {
        let ptSize = NSSize(width: rect.width / k, height: rect.height / k)
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: ptSize.width, height: ptSize.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: q.dark ? .darkAqua : .aqua)
        let root = Flipped(frame: NSRect(origin: .zero, size: ptSize)); root.wantsLayer = true
        let holder: NSView
        if q.merge > 0, q.shapes.count > 1 {
            let cv = NSGlassEffectContainerView(frame: root.bounds); cv.spacing = q.merge / k
            let content = Flipped(frame: root.bounds); cv.contentView = content
            root.addSubview(cv); holder = content
        } else { holder = root }
        var glassViews: [(NSGlassEffectView, Shape)] = []
        for s in q.shapes {
            let f = NSRect(x: (s.rect.minX - rect.minX) / k, y: (s.rect.minY - rect.minY) / k, width: s.rect.width / k, height: s.rect.height / k)
            let v = NSGlassEffectView(frame: f)
            v.style = q.clear ? .clear : .regular
            v.cornerRadius = s.radius / k
            v.tintColor = q.tint
            holder.addSubview(v); glassViews.append((v, s))
        }
        // 2.0 glass（第二次校準）：根 view 不當 contentView——視窗的內容大小會被捨入到整數 pt，翻轉座標的子 view 就整片往下偏
        // （1.88 px／pt 時約 1 px；校準台 2 px／pt 剛好看不出來）。放在一個普通的 contentView 裡，根 view 保持剛好 rect／k 的大小
        let holderView = NSView(frame: NSRect(origin: .zero, size: ptSize)); holderView.autoresizesSubviews = false
        win.contentView = holderView; holderView.addSubview(root)
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        CATransaction.flush()
        guard let rl = root.layer else { return nil }

        let tintM = q.tint.flatMap { Self.activeTintMatrix($0, clear: q.clear, dark: q.dark) }   // 2.0 tint：先問好（會建另一個小視窗），再開交易
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // 容器剛放進去的形狀會帶著系統自己的出現動畫（materialize）：拿掉，直接停在完成的樣子
        Self.walk(rl) { $0.removeAllAnimations() }
        // iOS 家族：整組 glassBackground、輸出範圍、亮邊換成 iOS 27 量到的（Design/HPGlassIOS.swift）；materialize 之前做，才會一起長出來
        if q.platform == .iOS {
            let sides = q.shapes.map { Double(min($0.rect.width, $0.rect.height) / k) }
            IOSGlass.apply(rl, clear: q.clear, dark: q.dark,
                           groupSides: q.container ? (sides.min() ?? 0, sides.max() ?? 0) : nil)
        }
        // 2.0 tint：染色矩陣換成「作用中視窗」系統算的那個（兩個平台都要；見 activeTintMatrix）
        if let tintM { Self.setTintMatrix(rl, tintM) }
        // 微調系統的樹：形狀（非圓角矩形改距離場圖、圓弧圓角）、按著的亮邊、materialize。
        // 單顆的 element 在自己的 view 裡（原點 0）、容器的在容器裡（原點＝view 的位置）：用大小對回形狀
        Self.walk(rl) { l in
            let cls = "\(type(of: l))"
            if cls == "CASDFElementLayer" {
                let sz = l.bounds.size
                if let s = q.shapes.first(where: { abs($0.rect.width / k - sz.width) < 0.6 && abs($0.rect.height / k - sz.height) < 0.6 }) {
                    if !s.continuous { l.cornerCurve = .circular }
                    if let path = s.path { Self.useContents(l, path: path, shape: s, k: k, sc: q.scale) }
                }
            } else if cls == "CABackdropLayer", q.presence < 0.999 {
                Self.materialize(l, q.presence)
            } else if cls == "CASDFLayer", q.press > 0.001, l.responds(to: NSSelectorFromString("effect")),
                      let fx = l.value(forKey: "effect") as? NSObject, "\(type(of: fx))" == "CASDFKeyFillHighlightEffect" {
                // 系統靜止時 @2 的 opacity 與 keyColor／fillColor 的 alpha 都是 0（互動才亮）：顏色全開、用層的 opacity 調強弱
                let c = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                fx.setValue(c, forKey: "keyColor"); fx.setValue(c, forKey: "fillColor")
                l.setValue(fx, forKey: "effect")
                l.opacity = Float(min(1, q.press))
            }
        }
        // 背景就是根層自己的 contents（玻璃的 backdrop 取樣的就是它）；根層從視窗的樹上拿下來給 CARenderer
        rl.contents = crop; rl.contentsGravity = .resize
        rl.removeFromSuperlayer()
        let host = CALayer(); host.frame = CGRect(x: 0, y: 0, width: w, height: h)
        // 層樹的單位是 pt（翻轉座標）：放大成貼圖像素、上下翻成讀回時第一列是上緣
        rl.anchorPoint = .zero; rl.position = CGPoint(x: 0, y: CGFloat(h))
        rl.transform = CATransform3DMakeScale(k * q.scale, -k * q.scale, 1)
        host.addSublayer(rl)
        CATransaction.commit()

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        let r = CARenderer(mtlTexture: tex, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                       kCARendererMetalCommandQueue: queue])
        r.layer = host; r.bounds = host.frame
        CATransaction.flush()
        return Pipe(key: key, window: win, root: root, host: host, renderer: r, texture: tex, rect: rect, w: w, h: h)
    }

    private static func walk(_ l: CALayer, _ f: (CALayer) -> Void) {
        f(l)
        for s in l.sublayers ?? [] { walk(s, f) }
    }

    // MARK: 染色（2.0 tint）
    //
    // 灰掉的原因：NSGlassEffectView 的染色看視窗是不是「作用中」（NSWindow 私有的 _hasActiveAppearance）。
    // 我們離屏的視窗永遠不是 key、App 也常不在前景——系統就給「非作用中」的染色：一個跟顏色無關的去飽和矩陣
    // （每列位移一樣：淺 −0.10、深 +0.10；只有 Regular，Clear 照樣染），橘、紅、綠全變灰。macOS 路徑直接吃到；iOS 路徑原本靠 IOSGlass 的擬合律蓋掉，
    // 但擬合律只在七個量測色上準，離樣本遠的色（HPTokens 的橘 #FF8D28）一個分量差到 0.11。
    // 作法：另開一個回報「作用中」的小視窗，讓系統自己算這個染色的矩陣（跟 iOS 27 模擬器拆出來的逐項相同：
    // 原本七色加 HPTokens 的橘紅綠黃藍、棕、半透明橘，四種外觀，最大差 0.000），
    // 照（色、Clear、深淺）快取。玻璃其他參數照舊用非作用中的那棵樹（校準過的樣子不動）。

    /// 只拿來問系統染色矩陣的視窗：外觀當作作用中（key 與否不影響，系統看的是這兩個）
    private final class ActiveAppearanceWindow: NSWindow {
        @objc func _hasActiveAppearance() -> Bool { true }
        @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    }
    nonisolated(unsafe) private static var tintCache: [String: [Float]] = [:]

    /// 這個染色的 vibrantColorMatrix（4×5 列優先），系統在作用中視窗算的
    static func activeTintMatrix(_ c: NSColor, clear: Bool, dark: Bool) -> [Float]? {
        guard let t = c.usingColorSpace(.sRGB) else { return nil }
        let key = String(format: "%.4f,%.4f,%.4f,%.4f|\(clear)|\(dark)", t.redComponent, t.greenComponent, t.blueComponent, t.alphaComponent)
        if let m = tintCache[key] { return m }
        guard #available(macOS 26.0, *) else { return nil }
        let win = ActiveAppearanceWindow(contentRect: NSRect(x: -30000, y: -30000, width: 120, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = Flipped(frame: NSRect(x: 0, y: 0, width: 120, height: 120)); root.wantsLayer = true
        win.contentView = root
        let v = NSGlassEffectView(frame: NSRect(x: 10, y: 10, width: 80, height: 80))
        v.style = clear ? .clear : .regular; v.cornerRadius = 40; v.tintColor = t
        root.addSubview(v)
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        CATransaction.flush()
        guard let l = root.layer, let m = gradientMatrix(l) else { return nil }
        tintCache[key] = m
        if tintCache.count > 64 { tintCache.removeAll() }
        return m
    }

    /// 染色子樹（CASDFGradientEffect 那層）的 vibrantColorMatrix
    static func gradientMatrix(_ root: CALayer) -> [Float]? {
        var out: [Float]?
        walk(root) { l in
            guard out == nil, let f = tintFilter(l), let v = f.1.value(forKey: "inputColorMatrix") as? NSValue else { return }
            var n = 0; NSGetSizeAndAlignment(v.objCType, &n, nil)
            guard n == 80 else { return }
            var m = [Float](repeating: 0, count: 20); v.getValue(&m, size: 80); out = m
        }
        return out
    }

    private static func tintFilter(_ l: CALayer) -> (Int, NSObject, [NSObject])? {
        guard "\(type(of: l))" == "CASDFLayer", l.responds(to: NSSelectorFromString("effect")),
              let fx = l.value(forKey: "effect") as? NSObject, "\(type(of: fx))" == "CASDFGradientEffect",
              let fs = l.value(forKey: "filters") as? [NSObject],
              let i = fs.firstIndex(where: { "\($0.value(forKey: "type") ?? "")" == "vibrantColorMatrix" }) else { return nil }
        return (i, fs[i], fs)
    }

    /// 把每個染色子樹（容器裡每顆一個）的矩陣換成 m
    static func setTintMatrix(_ root: CALayer, _ m: [Float]) {
        walk(root) { l in
            guard let (i, f, fs) = tintFilter(l), let old = f.value(forKey: "inputColorMatrix") as? NSValue else { return }
            var mm = m
            f.setValue(NSValue(bytes: &mm, objCType: old.objCType), forKey: "inputColorMatrix")
            var nfs = fs; nfs[i] = f
            l.setValue(nfs, forKey: "filters")
        }
    }

    /// materialize：glassBackground 的長度與面色一起從 0 長出來（系統 GlassEffectTransition 的做法：調光學量，不是透明度）
    private static func materialize(_ l: CALayer, _ k: CGFloat) {
        guard let fs = l.value(forKey: "filters") as? [NSObject], let f = fs.first(where: { "\($0.value(forKey: "type") ?? "")" == "glassBackground" }) else { return }
        let scaled = ["inputInnerRefractionHeight", "inputInnerRefractionAmount", "inputBlurRadius", "inputBleedAmount", "inputBleedHeight",
                      "inputShadowAmount", "inputShadowHeight", "inputBlurFillBlurRadius", "inputKeyFillHighlightAmount",
                      "inputOuterRefractionAmount", "inputOuterRefractionHeight", "inputShadowOpacity", "inputBleedOpacity", "inputRefractionOpacity"]
        for key in scaled { if let v = f.value(forKey: key) as? Double { f.setValue(v * Double(k), forKey: key) } }
        let toward: [(String, Double)] = [("inputFaceColorMatrixBlack", 0), ("inputFaceColorMatrixWhite", 1), ("inputFaceColorMatrixSaturation", 1)]
        for (key, id) in toward { if let v = f.value(forKey: key) as? Double { f.setValue(id + (v - id) * Double(k), forKey: key) } }
        if let c = f.value(forKey: "inputFaceColorMatrixFillColor"), CFGetTypeID(c as CFTypeRef) == CGColor.typeID {
            let cg = c as! CGColor
            f.setValue(cg.copy(alpha: cg.alpha * k), forKey: "inputFaceColorMatrixFillColor")
        }
        l.setValue([f], forKey: "filters")
    }

    /// 不是圓角矩形：element 改用距離場圖（QuartzCore 自己的 CASDFGenerator），單位換成層樹的 pt
    private static func useContents(_ l: CALayer, path: CGPath, shape s: Shape, k: CGFloat, sc: CGFloat) {
        let px = k * sc
        let maxDist = Double(max(8, min(s.rect.width, s.rect.height) * sc * 0.5))
        let w = Int((s.rect.width * sc).rounded(.up)), h = Int((s.rect.height * sc).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: sc, y: -sc); ctx.translateBy(x: -s.rect.minX, y: -s.rect.minY)
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        guard let mask = ctx.makeImage(), let sdf = SystemGlass.sdf(mask, maxDist: maxDist) else { return }
        let m = CGFloat(maxDist) / px   // 產生器四周各補 maxDist（像素）→ pt
        l.setValue("contents", forKey: "mode")
        l.frame = l.bounds.insetBy(dx: -m, dy: -m)
        l.contents = sdf
        l.cornerRadius = 0
        l.setValue(-maxDist / Double(px), forKey: "contentsZeroValueDistance"); l.setValue(maxDist / Double(px), forKey: "contentsOneValueDistance")
    }

    /// 融合組的裁切遮罩：每個形狀的有號距離（圓角矩形）做 smooth union（多項式 smin，k＝容器的 spacing，
    /// 跟容器 CASDFLayer 的 smoothness 同一個值），覆蓋率＝0.5 − d。rect 範圍、上緣在第一列、DeviceGray
    static func unionMask(_ shapes: [Shape], rect: CGRect, scale sc: CGFloat, smooth: CGFloat, outset: CGFloat = 0) -> CGImage? {
        let w = Int((rect.width * sc).rounded(.up)), h = Int((rect.height * sc).rounded(.up))
        guard w > 0, h > 0 else { return nil }
        let kpx = Double(smooth * sc)
        var px = [UInt8](repeating: 0, count: w * h)
        let boxes = shapes.map { s -> (Double, Double, Double, Double, Double) in
            let r = Double(min(s.radius, min(s.rect.width, s.rect.height) / 2) * sc)
            return (Double((s.rect.midX - rect.minX) * sc), Double((s.rect.midY - rect.minY) * sc), Double(s.rect.width * sc / 2) - r, Double(s.rect.height * sc / 2) - r, r)
        }
        for y in 0..<h {
            let fy = Double(y) + 0.5
            for x in 0..<w {
                let fx = Double(x) + 0.5
                var d = Double.greatestFiniteMagnitude
                for (cx, cy, hx, hy, r) in boxes {
                    let qx = abs(fx - cx) - hx, qy = abs(fy - cy) - hy
                    let di = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
                    if d == .greatestFiniteMagnitude { d = di; continue }
                    let hh = max(kpx - abs(d - di), 0) / max(kpx, 1e-6)
                    d = min(d, di) - hh * hh * kpx / 4
                }
                px[y * w + x] = UInt8(max(0, min(1, 0.5 + Double(outset * sc) - d)) * 255)
            }
        }
        let gray = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: gray,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// CGPath → 圓角矩形（rect、半徑、是不是連續曲率）；不是圓角矩形回 nil。
    /// 連續曲率（continuousRoundedRect）每個角三段曲線、圓弧（CGPath(roundedRect:)）每個角一段；半徑用對角線上的邊界量
    static func roundedRect(of path: CGPath) -> (rect: CGRect, radius: CGFloat, continuous: Bool)? {
        var moves = 0, curves = 0, lines = 0, closes = 0
        path.applyWithBlock { e in
            switch e.pointee.type {
            case .moveToPoint: moves += 1
            case .addCurveToPoint, .addQuadCurveToPoint: curves += 1
            case .addLineToPoint: lines += 1
            case .closeSubpath: closes += 1
            @unknown default: break
            }
        }
        guard moves == 1, curves <= 12 else { return nil }
        let b = path.boundingBoxOfPath
        guard b.width > 2, b.height > 2 else { return nil }
        if curves == 0 { return lines >= 3 ? (b, 0, false) : nil }
        // 對角線上從左上角往裡找邊界：圓弧 d＝r(1−1/√2)，連續曲率 d≈0.2944 r（差 0.5%）
        var lo: CGFloat = 0, hi = min(b.width, b.height) / 2
        guard !path.contains(CGPoint(x: b.minX + 0.01, y: b.minY + 0.01)) || curves == 0 else { return nil }
        for _ in 0..<24 {
            let m = (lo + hi) / 2
            if path.contains(CGPoint(x: b.minX + m, y: b.minY + m)) { hi = m } else { lo = m }
        }
        let continuous = curves >= 12
        var r = hi / (continuous ? 0.29437 : (1 - 1 / CGFloat(2).squareRoot()))
        r = min(r, min(b.width, b.height) / 2)
        if abs(r - min(b.width, b.height) / 2) < 0.75 { r = min(b.width, b.height) / 2 }
        // 驗：四個邊的中點在裡面、四個角在外面
        let inset: CGFloat = 0.6
        let inside = [CGPoint(x: b.midX, y: b.minY + inset), CGPoint(x: b.midX, y: b.maxY - inset), CGPoint(x: b.minX + inset, y: b.midY), CGPoint(x: b.maxX - inset, y: b.midY)]
        guard inside.allSatisfy({ path.contains($0) }) else { return nil }
        // 直邊真的是直的（橢圓不算）：角弧結束後一點點的邊上要在裡面
        let along = (continuous ? 1.53 : 1.0) * r + 1
        if along < b.width / 2 - 0.5, !path.contains(CGPoint(x: b.minX + along, y: b.minY + inset)) { return nil }
        if along < b.height / 2 - 0.5, !path.contains(CGPoint(x: b.minX + inset, y: b.minY + along)) { return nil }
        if r > 2 {
            let corners = [CGPoint(x: b.maxX - 0.3, y: b.minY + 0.3), CGPoint(x: b.maxX - 0.3, y: b.maxY - 0.3), CGPoint(x: b.minX + 0.3, y: b.maxY - 0.3)]
            guard corners.allSatisfy({ !path.contains($0) }) else { return nil }
        }
        return (b, r, continuous)
    }
}
