// 2.0 live glass：常駐的系統玻璃層樹（預設打開；HOMEPLAY_LIVE_GLASS=0 關掉，計畫與量測見 docs/plans/live-glass.md）
//
// 今天的 NativeGlass 每遇到一個新狀態（按壓的每一格、形狀動了的每一格）就離屏建一棵 NSGlassEffectView 樹、畫一次、丟掉。
// LiveGlass 給每一組玻璃（HPGlass 的容器、融合組，或同一次 flush 裡沒有容器的互動形狀）留一棵樹：形狀動了就搬 view 的 frame，
// 融合交給 NSGlassEffectContainerView 自己的 SDF；背景跟形狀都沒變就直接用上一張。每幀 CARenderer 只畫進這組形狀範圍大小的貼圖。
//
// 小樣量到、決定這樣做的事實：
// - 按壓用我們校準的版本（HPGlass.pressAmount：放大＋觸點的光），不用 macOS 的 effectIsInteractive：iOS 27 模擬器的
//   .glass 按鈕按下去 48 pt 圓放大約 1.3 倍、整塊變白；macOS 的互動玻璃只放大 1.05、一顆小光點——不是 HomeView 的樣子。
// - 系統的 materialize：把 NSGlassEffectView 加進容器沒有出現動畫（沒有 CAAnimation、沒有 presentation modifier），
//   所以 presence < 1 的形狀照舊走 NativeGlass（我們照 SwiftUI 量過的 materialize）。
// - 視窗不上螢幕（跟 NativeGlass 一樣）：不需要系統的互動動畫，就不必在主螢幕放一個看不見的視窗；根層拿下來給 CARenderer。
//   留在視窗裡直接畫 contentView 的層，在 App 的行程裡讀回是空的（獨立小程式可以，原因沒追到）；selftest 盯著「讀回不是空的」。
// 只接圓角矩形／膠囊／圓（距離場形狀照舊走 NativeGlass）；減少透明度時不接手（HPGlass 畫霧面）。

import AppKit
import Metal
import QuartzCore

final class LiveGlass {
    nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["HOMEPLAY_LIVE_GLASS"] != "0"
    static let shared = LiveGlass()

    /// 這個形狀交給活的玻璃嗎：容器、融合組或互動的形狀；完整出現（presence 1）、圓角矩形、沒開減少透明度
    static func claims(container: String?, union: String?, interactive: Bool, presence: CGFloat, path: CGPath) -> Bool {
        enabled && (container != nil || union != nil || interactive) && presence > 0.999 && !HPGlass.reduceTransparency
            && NativeGlass.shared.available && Thread.isMainThread && NativeGlass.roundedRect(of: path) != nil
    }

    private final class Flipped: NSView { override var isFlipped: Bool { true } }
    /// 背景＝這個 view 的層的 contents：updateLayer 什麼都不做，AppKit 的 display 才不會把我們放的圖清掉
    private final class Backdrop: NSView {
        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {}
    }
    private final class Scene {
        let style: String
        let window: NSWindow
        let root: NSView
        let holder: NSView
        let host = CALayer()
        /// 背景圖放在自己的層、上下翻一次：root 是翻轉的 NSView，直接當 contents 會讓系統玻璃看到上下顛倒的背景
        /// （2026-10-26：App 資源庫搜尋欄裡出現第三列圖示、👀 膠囊映出畫面底部的桌布）
        let backdropLayer = CALayer()
        var renderer: CARenderer?
        var texture: MTLTexture?
        /// 貼圖蓋住的畫布範圍（形狀動出去了才重配）
        var rect = CGRect.zero
        var views: [NSView] = []   // NSGlassEffectView（存成 NSView：型別要 macOS 26）
        var lastKey = "", last: (image: CGImage, rect: CGRect)?
        var lastUsed = 0.0
        init(style: String, window: NSWindow, root: NSView, holder: NSView) { self.style = style; self.window = window; self.root = root; self.holder = holder }
    }
    private var scenes: [String: Scene] = [:]
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    nonisolated(unsafe) static var stats = (frames: 0, cached: 0, builds: 0, ms: 0.0)

    /// 一組玻璃這一幀的合成（背景＋系統玻璃；readback 範圍、第一列是上緣）。key 一樣（形狀、背景、樣式都沒變）就回上一張。
    /// 拿不到回 nil：呼叫端這一組退回 NativeGlass
    func render(scene name: String, shapes: [NativeGlass.Shape], clear: Bool, dark: Bool, tint: NSColor?, merge: CGFloat,
                backdrop: CGImage, scale sc: CGFloat, pad: CGFloat, key: String) -> (image: CGImage, rect: CGRect)? {
        guard #available(macOS 26.0, *), let device, let queue, !shapes.isEmpty else { return nil }
        let t0 = CACurrentMediaTime()
        let k = SystemGlassParams.ptToCanvas
        let tk = tint.flatMap { $0.usingColorSpace(.sRGB) }.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? "-"
        let style = "\(clear)|\(dark)|\(tk)|\(merge)|\(sc)|\(k)|\(HPGlass.platform)"
        for (n, s) in scenes where n != name && t0 - s.lastUsed > 2 { s.window.close(); scenes[n] = nil }   // 換畫面了：收掉
        var s: Scene
        if let old = scenes[name], old.style == style { s = old } else {
            scenes[name]?.window.close()
            guard let built = build(style: style, clear: clear, dark: dark, merge: merge, k: k) else { return nil }
            s = built; scenes[name] = s; LiveGlass.stats.builds += 1
        }
        s.lastUsed = t0
        var ink = shapes[0].rect
        for sh in shapes.dropFirst() { ink = ink.union(sh.rect) }
        let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let need = ink.insetBy(dx: -pad, dy: -pad).intersection(canvas).integral
        guard need.width > 2, need.height > 2 else { return nil }
        if key == s.lastKey, let last = s.last, last.rect == need { LiveGlass.stats.cached += 1; return last }

        // 貼圖：蓋得住這次的範圍就沿用；不夠才重配（多留 64 px，形狀小幅移動不必每幀重配）
        if s.texture == nil || !s.rect.contains(need) {
            let r = (s.texture == nil ? need : s.rect.union(need)).insetBy(dx: -64, dy: -64).intersection(canvas).integral
            let w = Int((r.width * sc).rounded(.up)), h = Int((r.height * sc).rounded(.up))
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: td) else { return nil }
            let rr = CARenderer(mtlTexture: tex, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, kCARendererMetalCommandQueue: queue])
            s.host.frame = CGRect(x: 0, y: 0, width: w, height: h)
            rr.layer = s.host; rr.bounds = s.host.frame
            s.renderer = rr; s.texture = tex; s.rect = r
        }
        guard let renderer = s.renderer, let texture = s.texture else { return nil }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        s.backdropLayer.contents = backdrop
        var reapply = false
        while s.views.count > shapes.count { s.views.removeLast().removeFromSuperview(); reapply = true }
        for (i, sh) in shapes.enumerated() {
            let f = NSRect(x: sh.rect.minX / k, y: sh.rect.minY / k, width: sh.rect.width / k, height: sh.rect.height / k)
            let v: NSGlassEffectView
            if i < s.views.count, let old = s.views[i] as? NSGlassEffectView { v = old } else {
                v = NSGlassEffectView(frame: f)
                v.style = clear ? .clear : .regular
                v.tintColor = tint
                s.holder.addSubview(v); s.views.append(v); reapply = true
            }
            if v.frame != f || v.cornerRadius != sh.radius / k {
                if v.frame.size != f.size || v.cornerRadius != sh.radius / k { reapply = true }
                v.frame = f; v.cornerRadius = sh.radius / k
            }
        }
        CATransaction.commit()
        if reapply {
            // 新的 view、大小變了：讓 AppKit 建好樹（拿掉它自己的出現動畫），再把 iOS 參數、作用中染色、靜止亮邊、圓弧圓角換上去
            s.root.layoutSubtreeIfNeeded(); s.root.displayIfNeeded()
            CATransaction.flush()
            if let rl = s.root.layer { tune(rl, shapes: shapes, clear: clear, dark: dark, tint: tint, k: k) }
        }
        if let rl = s.root.layer, rl.superlayer !== s.host || rl.position.x != -s.rect.minX * sc { adopt(rl, s, k: k, sc: sc) }
        CATransaction.flush()

        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(s.host.bounds); renderer.render(); renderer.endFrame()
        guard let cb = queue.makeCommandBuffer() else { return nil }
        cb.commit(); cb.waitUntilCompleted()
        let x0 = Int(((need.minX - s.rect.minX) * sc).rounded()), y0 = Int(((need.minY - s.rect.minY) * sc).rounded())
        let w = min(texture.width - x0, Int((need.width * sc).rounded(.up))), h = min(texture.height - y0, Int((need.height * sc).rounded(.up)))
        guard x0 >= 0, y0 >= 0, w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(x0, y0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        if let dir = ProcessInfo.processInfo.environment["HOMEPLAY_LIVE_GLASS_DUMP"] {   // 除錯：存下每次讀回的合成
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/live-\(LiveGlass.stats.frames).png"))
        }
        LiveGlass.stats.frames += 1
        LiveGlass.stats.ms += (CACurrentMediaTime() - t0) * 1000
        let out = (img, need)
        s.lastKey = key; s.last = out
        return out
    }

    @available(macOS 26.0, *)
    private func build(style: String, clear: Bool, dark: Bool, merge: CGFloat, k: CGFloat) -> Scene? {
        let pt = 1024 / k
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: pt, height: pt), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: pt, height: pt)); content.autoresizesSubviews = false
        win.contentView = content
        // 不用 content.bounds：視窗把內容捨入到整數 pt，翻轉座標會整片偏約 0.3 pt（NativeGlass 第二次校準同一個坑）
        let root = Backdrop(frame: NSRect(x: 0, y: 0, width: pt, height: pt)); root.wantsLayer = true
        content.addSubview(root)
        let holder: NSView
        if merge > 0 {
            let cv = NSGlassEffectContainerView(frame: root.bounds); cv.spacing = merge / k
            let inner = Flipped(frame: root.bounds); cv.contentView = inner
            root.addSubview(cv); holder = inner
        } else { holder = root }
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        CATransaction.flush()
        guard let rl = root.layer else { return nil }
        rl.contentsGravity = .resize
        let scene = Scene(style: style, window: win, root: root, holder: holder)
        let bl = scene.backdropLayer
        bl.frame = rl.bounds; bl.contentsGravity = .resize
        bl.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
        rl.insertSublayer(bl, at: 0)
        return scene
    }

    /// 根層拿下來給 CARenderer（單位是 pt、翻轉座標）：放大成貼圖像素、移到貼圖範圍、上下翻成讀回時第一列是上緣
    private func adopt(_ rl: CALayer, _ s: Scene, k: CGFloat, sc: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if rl.superlayer !== s.host { rl.removeFromSuperlayer(); s.host.addSublayer(rl) }
        rl.anchorPoint = .zero
        rl.position = CGPoint(x: -s.rect.minX * sc, y: s.host.bounds.height + s.rect.minY * sc)
        rl.transform = CATransform3DMakeScale(k * sc, -k * sc, 1)
        CATransaction.commit()
    }

    /// iOS 參數、作用中染色、靜止亮邊、圓弧圓角（跟 NativeGlass.build 同一組調整）
    private func tune(_ rl: CALayer, shapes: [NativeGlass.Shape], clear: Bool, dark: Bool, tint: NSColor?, k: CGFloat) {
        let tintM = tint.flatMap { NativeGlass.activeTintMatrix($0, clear: clear, dark: dark) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        Self.walk(rl) { $0.removeAllAnimations() }
        if HPGlass.platform == .iOS {
            let sides = shapes.map { Double(min($0.rect.width, $0.rect.height) / k) }
            IOSGlass.apply(rl, clear: clear, dark: dark, groupSides: sides.count > 1 ? (sides.min() ?? 0, sides.max() ?? 0) : nil)
        }
        if let tintM { NativeGlass.setTintMatrix(rl, tintM) }
        let rim = HPGlass.platform == .iOS ? HPGlass.restRim : 0
        Self.walk(rl) { l in
            let cls = "\(type(of: l))"
            if cls == "CASDFElementLayer" {
                let sz = l.bounds.size
                if let sh = shapes.first(where: { abs($0.rect.width / k - sz.width) < 0.6 && abs($0.rect.height / k - sz.height) < 0.6 }), !sh.continuous { l.cornerCurve = .circular }
            } else if rim > 0.001, cls == "CASDFLayer", l.responds(to: NSSelectorFromString("effect")),
                      let fx = l.value(forKey: "effect") as? NSObject, "\(type(of: fx))" == "CASDFKeyFillHighlightEffect" {
                let c = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                fx.setValue(c, forKey: "keyColor"); fx.setValue(c, forKey: "fillColor")
                l.setValue(fx, forKey: "effect")
                l.opacity = Float(min(1, rim))
            }
        }
        CATransaction.commit()
    }

    private static func walk(_ l: CALayer, _ f: (CALayer) -> Void) {
        f(l)
        for s in l.sublayers ?? [] { walk(s, f) }
    }

    /// selftest：讀回不是空的（「留在視窗裡畫」那種整張空白不能再發生）、玻璃真的改了背景、第二次同樣的輸入用快取
    static func selfTest(_ check: (Bool, String) -> Void) {
        guard NativeGlass.shared.available, Thread.isMainThread else { return }
        let bg = makeImage(1024, 1024) { g in
            for i in 0..<16 { g.setFillColor(CGColor(gray: i % 2 == 0 ? 0.2 : 0.8, alpha: 1)); g.fill(CGRect(x: CGFloat(i) * 64, y: 0, width: 64, height: 1024)) }
        }
        let shape = NativeGlass.Shape(rect: CGRect(x: 300, y: 450, width: 300, height: 110), radius: 55, continuous: false)
        func run() -> (image: CGImage, rect: CGRect)? {
            shared.render(scene: "selftest", shapes: [shape], clear: false, dark: false, tint: nil, merge: 0, backdrop: bg, scale: 1, pad: 24, key: "selftest")
        }
        let before = stats.cached
        guard let out = run(), let d = out.image.dataProvider?.data, let p = CFDataGetBytePtr(d) else { check(false, "live glass：畫得出來"); return }   // l10n-ignore（自檢訊息）
        var lit = 0, changed = 0
        let bpr = out.image.bytesPerRow
        for y in stride(from: 0, to: out.image.height, by: 4) {
            for x in stride(from: 0, to: out.image.width, by: 4) {
                let i = y * bpr + x * 4
                if Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) > 30 { lit += 1 }
                let cx = out.rect.minX + CGFloat(x), cy = out.rect.minY + CGFloat(y)
                let src = Int(cx / 64) % 2 == 0 ? 51 : 204
                if shape.rect.insetBy(dx: 20, dy: 20).contains(CGPoint(x: cx, y: cy)), abs(Int(p[i + 1]) - src) > 6 { changed += 1 }
            }
        }
        check(lit > 100, "live glass：讀回不是空的")   // l10n-ignore（自檢訊息）
        check(changed > 50, "live glass：形狀裡面被玻璃改過（折射／面色）")   // l10n-ignore（自檢訊息）
        _ = run()
        check(stats.cached == before + 1, "live glass：輸入沒變就用上一張")   // l10n-ignore（自檢訊息）
        shared.scenes["selftest"]?.window.close(); shared.scenes["selftest"] = nil
    }
}

// MARK: 量測台：HOMEPLAY_LIVE_GLASS_BENCH=DIR homeplay-pet <畫面旗標> --bench 60（不要 --screen-png：它在 dispatch 回呼裡跑，主佇列被占住）
// 照真的時間 60 Hz 出幀（每幀一個 run loop 回合），今天的路徑（LiveGlass 關）與 live 各跑一次：每幀 render 的毫秒、整段 CPU，逐格存 PNG，最後 exit(0)。
// HOMEPLAY_LIVE_GLASS_BENCH_PRESS=x,y：第 10 幀按下、第 40 幀放開（1024 畫布座標）；--demo-recipe overview 另外跑兩顆 Clear 膠囊的融合。

enum LiveGlassBench {
    struct Seq { let name: String; let frames: Int; let prep: () -> Void; let frame: (Int, Double) -> CGImage }
    nonisolated(unsafe) private static var report: [String: Any] = [:]

    static func start(_ face: Face, dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let p = env["HOMEPLAY_LIVE_GLASS_BENCH_PRESS"]?.split(separator: ",").compactMap { Double($0) }
        let recipe = CommandLine.arguments.contains("--demo-recipe")
        var seqs: [Seq] = []
        var bg: CGImage?
        // HOMEPLAY_LIVE_GLASS_BENCH_MODE=today|live：只跑一種（畫面上有會自己收起來的控制時，兩種各開一次行程才公平）
        let modes: [Bool] = env["HOMEPLAY_LIVE_GLASS_BENCH_MODE"].map { [$0 == "live"] } ?? [false, true]
        for live in modes {
            let tag = live ? "live" : "today"
            seqs.append(Seq(name: "screen-\(tag)", frames: 72, prep: { LiveGlass.enabled = live; HPGlass.discardCache() }) { i, now in
                if let p, p.count == 2, i == 10 { HPGlass.pressDown(CGPoint(x: p[0], y: p[1]), now: now) }
                if p != nil, i == 40 { HPGlass.pressUp(now: now) }
                _ = face.tickShell(now, 1 / 60)
                face.forceDirty = true
                return face.render(now)
            })
            guard recipe else { continue }
            // 融合：背景是封面這一幀，中間兩顆膠囊照自己的時間表靠近、融成一塊、再分開
            seqs.append(Seq(name: "morph-\(tag)", frames: 72, prep: {
                LiveGlass.enabled = false; bg = bg ?? face.render(); LiveGlass.enabled = live; HPGlass.discardCache()
            }) { i, _ in
                let sc = face.renderPixelScale, px = Int((1024 * sc).rounded())
                let t = Double(max(0, i)) / 71, gap = 120 - 170 * sin(Double.pi * t)   // 120 → −50（重疊）→ 120
                let w: CGFloat = 300, h: CGFloat = 110, y: CGFloat = 520
                let a = CGRect(x: 512 - CGFloat(gap) / 2 - w, y: y, width: w, height: h), b = CGRect(x: 512 + CGFloat(gap) / 2, y: y, width: w, height: h)
                return makeImage(px, px) { g in
                    if sc != 1 { g.scaleBy(x: sc, y: sc) }
                    if let bg { face.drawUpright(g, bg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
                    HPGlass.addCapsule(a, interactive: false, union: "m")
                    HPGlass.addCapsule(b, interactive: false, union: "m")
                    HPGlass.flush(g, face: face, clear: true)
                }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { next(seqs, dir: dir) }
    }

    private static func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }

    private static func next(_ rest: [Seq], dir: String) {
        guard let q = rest.first else {
            report["liveStats"] = ["frames": LiveGlass.stats.frames, "cached": LiveGlass.stats.cached, "builds": LiveGlass.stats.builds, "msTotal": LiveGlass.stats.ms]
            report["nativeStats"] = ["renders": NativeGlass.stats.renders, "builds": NativeGlass.stats.builds]
            if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: "\(dir)/bench.json")) }
            log("live-glass bench -> \(dir)/bench.json")
            exit(0)
        }
        q.prep()
        for i in 0..<3 { _ = q.frame(-1 - i, CACurrentMediaTime()) }   // 先建好（第一次建樹不算進穩態）
        var ms: [Double] = [], imgs: [CGImage] = []
        var i = 0
        var c0 = 0.0, t0 = 0.0
        // 每幀一個 run loop 回合（Timer），不巢狀：AppKit 的更新照常進來
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { tm in
            if i == 0 { c0 = cpu(); t0 = CACurrentMediaTime() }
            let a = CACurrentMediaTime()
            imgs.append(q.frame(i, a))
            ms.append((CACurrentMediaTime() - a) * 1000)
            i += 1
            guard i == q.frames else { return }
            tm.invalidate()
            let wall = CACurrentMediaTime() - t0, c1 = cpu()
            for (j, im) in imgs.enumerated() {
                try? NSBitmapImageRep(cgImage: im).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: String(format: "\(dir)/\(q.name)-%03d.png", j)))
            }
            let sorted = ms.sorted()
            report[q.name] = ["frameMs": ms, "meanMs": ms.reduce(0, +) / Double(ms.count), "p95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                              "maxMs": sorted.last ?? 0, "cpuPercent": (c1 - c0) / wall * 100, "wallS": wall, "fps": Double(q.frames) / wall]
            DispatchQueue.main.async { next(Array(rest.dropFirst()), dir: dir) }
        }
    }
}
