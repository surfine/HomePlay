// 2.0 glass：玻璃校準台（--glass-calibrate <資料夾> [truth|ours|all]）
//
// 同一個場景兩邊各畫一次：
// - 真值：真的 NSGlassEffectView（.regular／.clear、五種大小、染色、NSGlassEffectContainerView 融合）放在螢幕上的視窗裡，
//   用 ScreenCaptureKit 截自己的視窗（自己的視窗不需要「螢幕錄製」權限）；也存下每個實例的層樹與 glassBackground 參數（params.json）；
// - 我們：同一張背景、同樣的形狀走 HPGlass.add → flush → SystemGlass 離屏。
// 畫布 1024 px＝視窗 512 pt（2x 螢幕），所以 1 pt＝2 畫布 px；跑校準時 SystemGlassParams.ptToCanvas 暫時設成 2。
// 比對與作圖：tooling/glass-compare.py <資料夾>。

import AppKit
import ScreenCaptureKit
import SwiftUI

@available(macOS 27.0, *)
enum GlassCalibrate {
    struct Shape { let name: String; let rect: CGRect; let radius: CGFloat; var tint: NSColor? = nil; var group: String? = nil }
    static let ptPerCanvas: CGFloat = 0.5
    static let tintColor = NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
    static let shapes: [Shape] = [
        Shape(name: "c88", rect: CGRect(x: 48, y: 48, width: 88, height: 88), radius: 44),
        Shape(name: "cap120", rect: CGRect(x: 190, y: 68, width: 120, height: 48), radius: 24),
        Shape(name: "cap340", rect: CGRect(x: 360, y: 42, width: 340, height: 100), radius: 50),
        Shape(name: "tint340", rect: CGRect(x: 400, y: 220, width: 340, height: 100), radius: 50, tint: tintColor),
        Shape(name: "tile300", rect: CGRect(x: 48, y: 196, width: 300, height: 300), radius: 50),
        Shape(name: "pairA", rect: CGRect(x: 780, y: 48, width: 88, height: 88), radius: 44, group: "pair"),
        Shape(name: "pairB", rect: CGRect(x: 880, y: 48, width: 88, height: 88), radius: 44, group: "pair"),
        Shape(name: "panel", rect: CGRect(x: 48, y: 560, width: 928, height: 410), radius: 60),
    ]
    static let backgrounds = ["photo", "busy", "white", "black", "color"]
    static let looks: [(style: String, dark: Bool)] = [("regular", false), ("clear", false), ("regular", true), ("clear", true)]

    /// NSGlassEffectView 的圓角是連續曲率（CASDFElementLayer cornerCurve＝continuous）：膠囊與圓用一般圓角，其他用 continuousRoundedRect
    static func path(_ s: Shape) -> CGPath {
        s.radius * 2 >= min(s.rect.width, s.rect.height) - 0.5
            ? CGPath(roundedRect: s.rect, cornerWidth: s.radius, cornerHeight: s.radius, transform: nil)
            : continuousRoundedRect(s.rect, radius: s.radius)
    }

    /// 背景：像照片的漸層、直線格子＋字（看折射位移）、純白、純黑、飽和色。1024²、sRGB、第一列是上緣
    static func background(_ name: String) -> CGImage {
        let n = 1024
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(n)); ctx.scaleBy(x: 1, y: -1)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
        let all = CGRect(x: 0, y: 0, width: n, height: n)
        switch name {
        case "white": ctx.setFillColor(c(1, 1, 1)); ctx.fill(all)
        case "black": ctx.setFillColor(c(0, 0, 0)); ctx.fill(all)
        case "color": ctx.setFillColor(c(0.92, 0.16, 0.36)); ctx.fill(all)
        case "photo":
            let g = CGGradient(colorsSpace: cs, colors: [c(0.98, 0.62, 0.30), c(0.80, 0.30, 0.45), c(0.25, 0.22, 0.55), c(0.10, 0.45, 0.50)] as CFArray,
                               locations: [0, 0.35, 0.7, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 300, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            let blobs: [(CGFloat, CGFloat, CGFloat, CGColor)] = [(220, 140, 220, c(1, 0.95, 0.7, 0.85)), (760, 300, 260, c(0.2, 0.7, 0.9, 0.7)),
                                                                (420, 760, 300, c(0.95, 0.85, 0.3, 0.6)), (880, 880, 200, c(0.05, 0.05, 0.15, 0.8)),
                                                                (600, 120, 120, c(1, 1, 1, 0.9))]
            for (x, y, r, col) in blobs {
                let rg = CGGradient(colorsSpace: cs, colors: [col, col.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
                ctx.drawRadialGradient(rg, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
            }
            ctx.setStrokeColor(c(0.1, 0.08, 0.1, 0.7)); ctx.setLineWidth(3)
            for i in 0..<9 {
                let x = CGFloat(i) * 117 + 30
                ctx.move(to: CGPoint(x: x, y: 1024)); ctx.addCurve(to: CGPoint(x: x + 140, y: 380), control1: CGPoint(x: x - 60, y: 800), control2: CGPoint(x: x + 200, y: 600))
            }
            ctx.strokePath()
        default:   // busy
            ctx.setFillColor(c(1, 1, 1)); ctx.fill(all)
            ctx.setFillColor(c(0, 0, 0))
            for i in stride(from: 0, to: n, by: 32) { ctx.fill(CGRect(x: i, y: 0, width: 2, height: n)); ctx.fill(CGRect(x: 0, y: i, width: n, height: 2)) }
            ctx.setFillColor(c(0.85, 0.1, 0.1)); for i in stride(from: 16, to: n, by: 64) { ctx.fill(CGRect(x: i, y: 0, width: 4, height: n)) }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let att: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)]
            for row in 0..<20 { ("The quick brown fox 0123456789 " as NSString).draw(at: CGPoint(x: CGFloat(row % 3) * -40, y: CGFloat(row) * 52 + 10), withAttributes: att) }
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()!
    }

    static func save(_ im: CGImage, _ path: String) {
        try? NSBitmapImageRep(cgImage: im).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: 入口

    static func run(_ dir: String, what: String) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if what == "ios" { iosOurs(dir); print("glass-calibrate ios done → \(dir)"); exit(0) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for b in backgrounds { save(background(b), "\(dir)/bg-\(b).png") }
        let list = shapes.map { ["name": $0.name, "rect": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height], "radius": $0.radius, "group": $0.group ?? ""] as [String: Any] }
        if let d = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: "\(dir)/shapes.json")) }
        if what == "all" || what == "truth" { truth(dir) }
        if what == "all" || what == "ours" { ours(dir); materializeOurs(dir) }
        print("glass-calibrate done → \(dir)")
        exit(0)
    }

    // MARK: 我們：HPGlass.flush（產品走的同一條路）

    static func ours(_ dir: String) {
        let face = Face()
        face.renderPixelScale = 1
        let oldK = SystemGlassParams.ptToCanvas, oldDark = HPTokens.dark, oldMerge = HPGlass.unionMerge, oldPlat = HPGlass.platform
        SystemGlassParams.ptToCanvas = 1 / ptPerCanvas   // 校準台：1 pt＝2 畫布 px
        HPGlass.platform = .macOS   // 對的是 NSGlassEffectView
        HPGlass.materialOnly = ProcessInfo.processInfo.environment["HOMEPLAY_GLASS_CAL_FULL"] == nil   // 只比材質（不翻淺深、不壓暗、不畫外陰影）
        HPGlass.unionMerge = 20 / ptPerCanvas   // 真值的 NSGlassEffectContainerView spacing 20 pt
        defer { SystemGlassParams.ptToCanvas = oldK; HPTokens.dark = oldDark; HPGlass.materialOnly = false; HPGlass.unionMerge = oldMerge; HPGlass.platform = oldPlat }
        for look in looks {
            HPTokens.dark = look.dark
            for b in backgrounds {
                let bg = background(b)
                let t0 = CACurrentMediaTime()
                let img = makeImage(1024, 1024) { g in
                    face.drawUpright(g, bg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
                    for s in shapes { HPGlass.add(path(s), tint: s.tint, interactive: false, union: s.group) { _ in } }
                    HPGlass.flush(g, face: face, clear: look.style == "clear")
                }
                let tag = "\(look.style)-\(look.dark ? "dark" : "light")-\(b)"
                save(img, "\(dir)/ours-\(tag).png")
                print("ours", tag, String(format: "%.0f ms", (CACurrentMediaTime() - t0) * 1000))
            }
        }
    }

    /// materialize：同 materializeSequence 的膠囊（170×50 pt 置中），presence 0…1 每 0.05 一張，跟真值的連拍逐張找最像的
    static func materializeOurs(_ dir: String) {
        let face = Face()
        face.renderPixelScale = 1
        let oldK = SystemGlassParams.ptToCanvas, oldPlat = HPGlass.platform
        SystemGlassParams.ptToCanvas = 1 / ptPerCanvas
        HPGlass.materialOnly = true; HPGlass.platform = .macOS
        defer { SystemGlassParams.ptToCanvas = oldK; HPGlass.materialOnly = false; HPGlass.platform = oldPlat }
        let bg = background("photo")
        let r = CGRect(x: 512 - 170, y: 512 - 50, width: 340, height: 100)
        for i in 0...20 {
            let p = CGFloat(i) / 20
            let img = makeImage(1024, 1024) { g in
                face.drawUpright(g, bg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
                HPGlass.addCapsule(r, interactive: false, presence: max(0.002, p))
                HPGlass.flush(g, face: face, clear: false)
            }
            save(img, String(format: "\(dir)/ours-mat-%03d.png", i * 5))
        }
    }

    // MARK: iOS 真值（第二次校準）：iOS 27 模擬器截圖已換到畫布（1.88 px／pt），這裡只畫我們的

    /// --glass-calibrate DIR ios：DIR 底下每個子資料夾（top／bot／recipe…）有 shapes.json（畫布座標、tint、group）、
    /// bg-<背景>.png（同一畫面拿掉玻璃的截圖）、truth-<樣式>-<淺深>-<背景>.png；畫出 ours-*.png 給 glass-compare.py。
    /// 平台照 HPGlass.platform（一律 iOS）
    static func iosOurs(_ dir: String) {
        let face = Face()
        face.renderPixelScale = 1
        let oldDark = HPTokens.dark, oldMerge = HPGlass.unionMerge
        HPGlass.materialOnly = true
        HPGlass.unionMerge = 20 * SystemGlassParams.ptToCanvas   // iOS 的 GlassEffectContainer spacing 20 pt
        defer { HPTokens.dark = oldDark; HPGlass.materialOnly = false; HPGlass.unionMerge = oldMerge }
        let fm = FileManager.default
        for sub in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            let d = "\(dir)/\(sub)"
            guard let data = fm.contents(atPath: "\(d)/shapes.json"),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let files = (try? fm.contentsOfDirectory(atPath: d)) ?? []
            for f in files.sorted() where f.hasPrefix("truth-") && f.hasSuffix(".png") {
                // truth-<style>-<light|dark>-<bg>.png
                let parts = f.dropFirst(6).dropLast(4).split(separator: "-").map(String.init)
                guard parts.count == 3, let src = NSImage(contentsOfFile: "\(d)/bg-\(parts[2]).png"),
                      let bg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                HPTokens.dark = parts[1] == "dark"
                let img = makeImage(1024, 1024) { g in
                    face.drawUpright(g, bg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
                    for s in list {
                        guard let r = s["rect"] as? [Double], r.count == 4, let rad = s["radius"] as? Double else { continue }
                        let sh = Shape(name: s["name"] as? String ?? "", rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), radius: rad)
                        let group = (s["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        let add = { HPGlass.add(path(sh), tint: (s["tint"] as? Bool) == true ? tintColor : nil, interactive: false, union: group) { _ in } }
                        if let c = s["container"] as? String, !c.isEmpty { HPGlass.container(c, add) } else { add() }
                    }
                    HPGlass.flush(g, face: face, clear: parts[0] == "clear")
                }
                save(img, "\(d)/ours-\(parts.joined(separator: "-")).png")
                print("ours", sub, parts.joined(separator: "-"), HPGlass.platform)
            }
        }
    }

    // MARK: 真值：NSGlassEffectView 在視窗裡，截自己的視窗

    static func capture(_ w: NSWindow) -> CGImage? {
        let wid = CGWindowID(w.windowNumber)
        nonisolated(unsafe) var out: CGImage?
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let c = try await SCShareableContent.currentProcess
                guard let win = c.windows.first(where: { $0.windowID == wid }) else { sem.signal(); return }
                let f = SCContentFilter(desktopIndependentWindow: win)
                let cfg = SCStreamConfiguration(); cfg.width = 1024; cfg.height = 1024; cfg.captureResolution = .best
                cfg.colorSpaceName = CGColorSpace.sRGB; cfg.showsCursor = false; cfg.ignoreShadowsSingleWindow = true
                out = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
            } catch { print("capture error", error) }
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return out
    }

    static func describe(_ v: Any?) -> Any {
        guard let v else { return NSNull() }
        if let n = v as? NSNumber { return n.doubleValue }
        if CFGetTypeID(v as CFTypeRef) == CGColor.typeID {
            let c0 = v as! CGColor
            let c = c0.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? c0
            return (c.components ?? []).map { Double($0) }
        }
        if let d = v as? NSData { return (d as Data).withUnsafeBytes { Array($0.bindMemory(to: Float32.self)).map { Double($0) } } }   // vibrantColorMatrix：20 個 float
        if let s = v as? NSValue { return s.description }
        return "\(v)"
    }

    static func dumpTree(_ l: CALayer, _ d: Int, _ out: inout [[String: Any]]) {
        var e: [String: Any] = ["depth": d, "class": "\(type(of: l))", "name": l.name ?? "-", "frame": "\(l.frame)",
                                "opacity": l.opacity, "shadowOpacity": l.shadowOpacity, "shadowRadius": l.shadowRadius, "cornerRadius": l.cornerRadius]
        if l.shadowOpacity > 0 { e["shadowOffset"] = "\(l.shadowOffset)"; e["shadowColor"] = describe(l.shadowColor) }
        if let fs = l.value(forKey: "filters") as? [NSObject] {
            e["filters"] = fs.map { f -> [String: Any] in
                var m: [String: Any] = ["type": "\(f.value(forKey: "type") ?? "?")"]
                for k in (f.value(forKey: "inputKeys") as? [String]) ?? [] { m[k] = describe(f.value(forKey: k)) }
                return m
            }
        }
        for k in ["scale", "marginWidth", "smoothness", "groupName", "mode"] where l.responds(to: NSSelectorFromString(k)) { e[k] = describe(l.value(forKey: k)) }
        if l.responds(to: NSSelectorFromString("effect")), let fx = l.value(forKey: "effect") as? NSObject {
            var m: [String: Any] = ["class": "\(type(of: fx))"]
            for k in ["keyAmount", "fillAmount", "keyColor", "fillColor", "curvature", "keyHeight", "keySpread", "keyAngle", "fillAngle", "fillHeight", "fillSpread",
                      "keyHeightScale", "fillHeightScale", "diffuseHeightScale", "diffuseAmountScale", "diffuseSpreadScale", "global", "minimum", "maximum", "color", "colors", "locations"]
                where fx.responds(to: NSSelectorFromString(k)) { m[k] = describe(fx.value(forKey: k)) }
            e["effect"] = m
        }
        out.append(e)
        for s in l.sublayers ?? [] { dumpTree(s, d + 1, &out) }
    }

    static var screen: NSScreen { NSScreen.screens.first { $0.backingScaleFactor == 2 } ?? NSScreen.main! }

    /// 2.0 tint：HOMEPLAY_GLASS_CAL_ACTIVE=1 時真值視窗當作作用中（系統只在作用中視窗畫出 Regular 的染色；
    /// accessory App 的視窗永遠不是作用中，染色玻璃會拍成灰的）
    final class ActiveCalWindow: NSWindow {
        @objc func _hasActiveAppearance() -> Bool { true }
        @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    }
    static func window(bg: CGImage, dark: Bool) -> (NSWindow, CalFlipped) {
        let o = screen.visibleFrame.origin
        let w = (ProcessInfo.processInfo.environment["HOMEPLAY_GLASS_CAL_ACTIVE"] == "1" ? ActiveCalWindow.self : NSWindow.self).init(contentRect: NSRect(x: o.x + 40, y: o.y + 40, width: 512, height: 512), styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.colorSpace = .sRGB; w.hasShadow = false; w.level = .floating; w.isOpaque = true; w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = CalFlipped(frame: NSRect(x: 0, y: 0, width: 512, height: 512)); root.wantsLayer = true
        root.layer!.contents = bg; root.layer!.contentsGravity = .resize
        root.layer!.magnificationFilter = .nearest; root.layer!.minificationFilter = .nearest
        w.contentView = root
        return (w, root)
    }

    static func glassWindow(bg: CGImage, dark: Bool, regular: Bool, interactive: Bool = false) -> (NSWindow, [String: NSView]) {
        let (w, root) = window(bg: bg, dark: dark)
        var views: [String: NSView] = [:]
        var containers: [String: NSView] = [:]
        let k = ptPerCanvas
        for s in shapes {
            let v = NSGlassEffectView(frame: NSRect(x: s.rect.minX * k, y: s.rect.minY * k, width: s.rect.width * k, height: s.rect.height * k))
            v.style = regular ? .regular : .clear; v.cornerRadius = s.radius * k; v.tintColor = s.tint
            if interactive { v.effectIsInteractive = true }
            views[s.name] = v
            if let g = s.group {
                if containers[g] == nil {
                    let cv = NSGlassEffectContainerView(frame: root.bounds); cv.spacing = 20
                    let content = CalFlipped(frame: root.bounds); cv.contentView = content
                    root.addSubview(cv); containers[g] = content
                }
                containers[g]!.addSubview(v)
            } else { root.addSubview(v) }
        }
        w.orderFrontRegardless()
        return (w, views)
    }

    static func truth(_ dir: String) {
        print("screen scale", screen.backingScaleFactor)
        var params: [String: Any] = [:]
        for look in looks {
            for b in backgrounds {
                let (w, views) = glassWindow(bg: background(b), dark: look.dark, regular: look.style == "regular")
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                let tag = "\(look.style)-\(look.dark ? "dark" : "light")-\(b)"
                if let im = capture(w) { save(im, "\(dir)/truth-\(tag).png"); print("truth", tag) }
                if b == "photo" || b == "white" || b == "black" {
                    for (name, v) in views { var t: [[String: Any]] = []; if let l = v.layer { dumpTree(l, 0, &t) }; params["\(tag)/\(name)"] = t }
                }
                w.orderOut(nil)
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: params, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: "\(dir)/params.json")) }
        sizeSweep(dir)
        pressSequence(dir)
        materializeSequence(dir)
    }

    /// 尺寸規律：不同短邊（pt）、長寬比、圓角的 NSGlassEffectView 各取一次 glassBackground 參數（不截圖）
    static func sizeSweep(_ dir: String) {
        var out: [[String: Any]] = []
        for dark in [false, true] {
            let (w, root) = window(bg: background("white"), dark: dark)
            w.orderFrontRegardless()
            for regular in [true, false] {
                for s in stride(from: 16, through: 320, by: 8) {
                    for (aspect, rk) in [(1.0, 0.5), (3.0, 0.5), (1.0, 0.2), (2.0, 0.1)] {
                        let v = NSGlassEffectView(frame: NSRect(x: 4, y: 4, width: CGFloat(s) * aspect, height: CGFloat(s)))
                        v.style = regular ? .regular : .clear; v.cornerRadius = CGFloat(s) * rk
                        root.addSubview(v)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                        var t: [[String: Any]] = []; if let l = v.layer { dumpTree(l, 0, &t) }
                        if let f = t.compactMap({ ($0["filters"] as? [[String: Any]])?.first { $0["type"] as? String == "glassBackground" } }).first {
                            out.append(["dark": dark, "regular": regular, "side": s, "aspect": aspect, "radiusK": rk, "filter": f])
                        }
                        v.removeFromSuperview()
                    }
                }
            }
            w.orderOut(nil)
        }
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) { try? d.write(to: URL(fileURLWithPath: "\(dir)/sizes.json")) }
    }

    /// 按著：effectIsInteractive＝true，對 cap340 送 mouseDown／Up，連拍（每張截圖約 0.2 s，只看得到趨勢）
    static func pressSequence(_ dir: String) {
        let (w, views) = glassWindow(bg: background("photo"), dark: false, regular: true, interactive: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let v = views["cap340"] else { return }
        let p = v.convert(NSPoint(x: v.bounds.midX + 30, y: v.bounds.midY), to: nil)
        if let im = capture(w) { save(im, "\(dir)/press-0000.png") }
        // 合成事件只送進自己的行程（CGEvent.postToPid），不動真的游標、不碰別的 App
        let sp = w.convertPoint(toScreen: p)
        let global = CGPoint(x: sp.x, y: (NSScreen.screens.first?.frame.height ?? 0) - sp.y)
        func send(_ t: NSEvent.EventType, _ n: Int) {
            let type: CGEventType = t == .leftMouseDown ? .leftMouseDown : .leftMouseUp
            if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: global, mouseButton: .left) { e.postToPid(getpid()) }
        }
        var t0 = CACurrentMediaTime()
        send(.leftMouseDown, 1)
        var tree: [[String: Any]] = []
        for i in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            if let im = capture(w) { save(im, String(format: "\(dir)/press-d%04d.png", Int((CACurrentMediaTime() - t0) * 1000))) }
            if i == 4, let l = v.layer { dumpTree(l, 0, &tree) }
        }
        if let d = try? JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: "\(dir)/press-tree.json")) }
        t0 = CACurrentMediaTime()
        send(.leftMouseUp, 2)
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            if let im = capture(w) { save(im, String(format: "\(dir)/press-u%04d.png", Int((CACurrentMediaTime() - t0) * 1000))) }
        }
        w.orderOut(nil)
    }

    final class MatModel: ObservableObject { @Published var show = false }
    struct MatView: View {
        @ObservedObject var m: MatModel
        var body: some View {
            GlassEffectContainer {
                ZStack {
                    if m.show { Color.clear.frame(width: 170, height: 50).glassEffect(.regular, in: Capsule()) }
                }.frame(width: 512, height: 512)
            }
        }
    }
    /// materialize：SwiftUI GlassEffectContainer 裡 withAnimation 加一個 glassEffect，連拍
    static func materializeSequence(_ dir: String) {
        let (w, root) = window(bg: background("photo"), dark: false)
        let m = MatModel()
        let host = NSHostingView(rootView: MatView(m: m)); host.frame = root.bounds
        root.addSubview(host); w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let t0 = CACurrentMediaTime()
        withAnimation(.spring(duration: 1.2)) { m.show = true }
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if let im = capture(w) { save(im, String(format: "\(dir)/mat-%04d.png", Int((CACurrentMediaTime() - t0) * 1000))) }
        }
        w.orderOut(nil)
    }
}

final class CalFlipped: NSView { override var isFlipped: Bool { true } }

/// 2.0 glass：玻璃的純函式自檢（形狀辨識、融合遮罩、materialize 尺寸、畫布比例）
enum GlassSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let cap = NativeGlass.roundedRect(of: CGPath(roundedRect: CGRect(x: 10, y: 20, width: 100, height: 40), cornerWidth: 20, cornerHeight: 20, transform: nil))
        check(cap.map { abs($0.radius - 20) < 0.8 && !$0.continuous && $0.rect.width == 100 } == true, "glass：認得膠囊（半徑＝高 ÷ 2）")
        let sq = NativeGlass.roundedRect(of: continuousRoundedRect(CGRect(x: 0, y: 0, width: 300, height: 300), radius: 50))
        check(sq.map { abs($0.radius - 50) < 1.5 && $0.continuous } == true, "glass：認得連續曲率圓角矩形")
        check(NativeGlass.roundedRect(of: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 40), transform: nil)) == nil, "glass：橢圓不是圓角矩形")
        check(NativeGlass.roundedRect(of: CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 30), transform: nil)).map { $0.radius == 0 } == true, "glass：直角矩形半徑 0")
        let a = NativeGlass.Shape(rect: CGRect(x: 0, y: 0, width: 88, height: 88), radius: 44, continuous: false)
        let b = NativeGlass.Shape(rect: CGRect(x: 100, y: 0, width: 88, height: 88), radius: 44, continuous: false)
        func mid(_ smooth: CGFloat) -> UInt8 {
            guard let m = NativeGlass.unionMask([a, b], rect: CGRect(x: 0, y: 0, width: 188, height: 88), scale: 1, smooth: smooth),
                  let d = m.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return 0 }
            return p[44 * m.bytesPerRow + 94]
        }
        check(mid(40) == 255 && mid(0) == 0, "glass：融合遮罩在兩顆中間長出橋（spacing 0 就沒有）")
        LiveGlass.selfTest(check)   // 2.0 live glass
        check(HPGlass.materializeScale(1) == 1 && abs(HPGlass.materializeScale(0) - 1.05) < 1e-9, "glass：materialize 從 1.05 倍收到 1")
        check(SystemGlassParams.ptToCanvas == 1.88, "glass：1 pt＝1.88 畫布 px（HomeView 544 pt ≈ 1024）")
        // 第二次校準：iOS 家族的參數表（iOS 27 模擬器量到的值）
        let rl = IOSGlass.look(clear: false, dark: false), cl = IOSGlass.look(clear: true, dark: false)
        check(abs(IOSGlass.value(rl.curves["inputBleedAmount"] ?? [], 88) - 30.8) < 0.01 && abs(IOSGlass.value(rl.curves["inputBleedAmount"] ?? [], 500) - 175) < 0.01,
              "glass iOS：bleed＝0.35 × 短邊（表內與外插）")   // l10n-ignore（自檢訊息）
        check(abs(IOSGlass.value(rl.curves["inputBlurOpacity0"] ?? [], 88) - 0.2) < 0.001 && abs(IOSGlass.value(rl.curves["inputInnerRefractionHeight"] ?? [], 340) - 20) < 0.001,
              "glass iOS：Regular 88 pt 外圈模糊 0.2、折射帶最多 20 pt")   // l10n-ignore（自檢訊息）
        check((cl.constants["inputBlurRadius"] ?? 9) < 1 && abs(IOSGlass.outputMaximum(side: 88, clear: false, dark: false) - 11.107) < 0.01,
              "glass iOS：Clear 幾乎不模糊；Regular 88 pt 的外陰影伸出 11.1 pt")   // l10n-ignore（自檢訊息）
        let blue = IOSGlass.tintMatrix(NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1), clear: false, dark: false)
        check(blue.count == 20 && abs(blue[9] - 0.2513) < 0.003 && abs(blue[14] - 0.6) < 0.003 && abs(blue[10] + blue[11] + blue[12] - 0.4) < 0.003,
              "glass iOS：藍色染色矩陣＝實測（暗端 0.25／0.60、亮端＝原色）")   // l10n-ignore（自檢訊息）
        let white = IOSGlass.tintMatrix(.white, clear: false, dark: false)
        check(white.count == 20 && abs(white[0] - 0.3125) < 1e-4 && abs(white[4] - 0.9375) < 1e-4, "glass iOS：白色染色是對角矩陣")
        GlassTintCheck.selftest(check)   // 2.0 tint：染色圓鈕走真的系統層樹，中心要有色（Design/GlassTintCheck.swift）
    }
}
