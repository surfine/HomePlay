// CarPlay 影片（iOS 27「停車時播影片」）的桌寵端：iPhone 把影片網址交給接收器，接收器轉給這裡播。
// 播放器：AVPlayer。畫面兩條路同時供：
// 1. 桌寵螢幕：AVPlayerItemVideoOutput 取幀 → Core Image 置中加黑邊合成成方圖（含控制列）→ MTLTexture 環形緩衝 → 3D 螢幕材質；
// 2. 放大：一個可縮放的浮動視窗，AVPlayerLayer 直接掛同一個 AVPlayer（雙擊螢幕或按「放大」切換）。
// 狀態（就緒、播放中、位置、長度、已緩衝）每 0.5 秒回報接收器，接收器據此回答 iPhone 的 playbackInfo。

import AppKit
import AVFoundation
import CoreImage
import Metal

/// 停車時可播影片的設定：寫在 Application Support/HomePlay/carplay-video.json（不碰 wireless.json）。
/// 檔案不存在＝允許（Mac 不會移動，預設當作一直停著）。
enum CarVideoSetting {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay/carplay-video.json")
    }
    static var allowed: Bool {
        get {
            guard let d = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return true }
            return (o["allowed"] as? Bool) ?? true
        }
        set {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONSerialization.data(withJSONObject: ["allowed": newValue], options: [.sortedKeys]) {
                try? d.write(to: url, options: .atomic)
            }
        }
    }
}

final class CarVideoPlayer: NSObject {
    /// 有影片在播（或暫停中）：桌寵螢幕顯示影片，CarPlay 畫面先讓位
    private(set) var active = false
    private(set) var itemUUID: Any?
    let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private var frameTimer: Timer?
    private var stateTimer: Timer?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var failObs: NSObjectProtocol?
    private var lastStateSent = ""
    /// 控制列：游標在螢幕上或剛點過
    var controlsUntil: Double = 0
    private var lastFrame: CIImage?

    /// 給 3D 螢幕的方形貼圖（環形三張，避免寫到 GPU 正在讀的那張）
    var onTexture: ((MTLTexture) -> Void)?
    /// 回報接收器（JSON 字串）
    var send: ((String) -> Void)?
    /// 影片結束／被停：回到 CarPlay 畫面
    var onEnded: (() -> Void)?
    var onStarted: (() -> Void)?

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var ci: CIContext? = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
    private var ring: [MTLTexture] = []
    private var ringIndex = 0
    private let side = 1088
    private var bigWindow: CarVideoWindow?

    // MARK: 接收器的指令

    /// {"type":"carVideo","op":"play|rate|seek|stop","url":…,"startMs":…,"uuid":…,"rate":…,"ms":…}
    func handle(_ o: [String: Any]) {
        switch o["op"] as? String {
        case "play":
            guard let s = o["url"] as? String, let u = URL(string: s) else { return }
            load(u, startMs: (o["startMs"] as? NSNumber)?.intValue ?? 0, uuid: o["uuid"])
        case "rate":
            let r = (o["rate"] as? NSNumber)?.floatValue ?? 0
            if r > 0 { player.play() } else { player.pause() }
            if !active, player.currentItem != nil { begin() }
            reportState(force: true)
        case "seek":
            let ms = (o["ms"] as? NSNumber)?.doubleValue ?? 0
            player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.reportState(force: true)
            }
        case "show":
            if player.currentItem != nil, !active { begin() }
        case "stop":
            stop(notify: false)
        default: break
        }
    }

    private func load(_ url: URL, startMs: Int, uuid: Any?) {
        stop(notify: false)
        itemUUID = uuid
        let item = AVPlayerItem(url: url)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        output = out
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if it.status == .failed {
                    let code = (it.error as NSError?)?.code ?? -12927
                    log("car video: item failed (\(code))")
                    self.send?(Self.json(["type": "carVideoError", "code": code]))
                    self.stop(notify: true)
                } else { self.reportState(force: true) }
            }
        }
        endObs = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            self?.reportState(force: true)
        }
        player.replaceCurrentItem(with: item)
        if startMs > 0 { player.seek(to: CMTime(value: CMTimeValue(startMs), timescale: 1000)) }
        log("car video: load \(url.host ?? "?")")
        begin()
    }

    private func begin() {
        guard !active else { return }
        active = true
        controlsUntil = CACurrentMediaTime() + 3
        onStarted?()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.pullFrame() }
        RunLoop.main.add(t, forMode: .common); frameTimer = t
        let s = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.reportState(force: false) }
        RunLoop.main.add(s, forMode: .common); stateTimer = s
    }

    /// 停掉：notify＝我們自己停的（使用者按返回、播不了），要告訴 iPhone
    func stop(notify: Bool) {
        let wasActive = active
        frameTimer?.invalidate(); frameTimer = nil
        stateTimer?.invalidate(); stateTimer = nil
        statusObs = nil
        if let e = endObs { NotificationCenter.default.removeObserver(e); endObs = nil }
        if let e = failObs { NotificationCenter.default.removeObserver(e); failObs = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
        output = nil; lastFrame = nil
        active = false
        bigWindow?.close(); bigWindow = nil
        if notify { send?(Self.json(["type": "carVideoState", "playing": false, "prepared": false, "stopped": true])) }
        lastStateSent = ""
        if wasActive { onEnded?() }
    }

    // MARK: 使用者操作（桌寵螢幕上的控制列、選單）

    func togglePlay() {
        if player.rate > 0 { player.pause() } else { player.play() }
        controlsUntil = CACurrentMediaTime() + 3
        reportState(force: true)
        send?(Self.json(["type": "carVideoUser", "playing": player.rate > 0]))   // 車機端主動播放／暫停要通知 iPhone
    }
    func skip(_ seconds: Double) {
        let t = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: CMTimeMaximum(.zero, t)) { [weak self] _ in self?.reportState(force: true) }
        controlsUntil = CACurrentMediaTime() + 3
    }
    /// 放大／收回浮動視窗
    func toggleBig(near frame: NSRect?) {
        if let w = bigWindow { w.close(); bigWindow = nil; return }
        let w = CarVideoWindow(player: player, near: frame)
        w.onClose = { [weak self] in self?.bigWindow = nil }
        w.makeKeyAndOrderFront(nil)
        bigWindow = w
    }
    var isBig: Bool { bigWindow != nil }

    // MARK: 取幀

    private func pullFrame() {
        guard let out = output, let ci else { return }
        let now = CACurrentMediaTime()
        let t = out.itemTime(forHostTime: now)
        var image = lastFrame
        if out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            image = CIImage(cvPixelBuffer: pb); lastFrame = image
        } else if now > controlsUntil + 0.5, controlsDrawnUntil < now {
            return   // 沒有新幀、控制列也沒在變：不重畫
        }
        guard let tex = nextTexture() else { return }
        let S = CGFloat(side)
        var canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
        if let img = image {
            let e = img.extent
            let k = min(S / e.width, S / e.height)
            let placed = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
                .transformed(by: CGAffineTransform(translationX: (S - e.width * k) / 2, y: (S - e.height * k) / 2))
            canvas = placed.composited(over: canvas)
        }
        if now < controlsUntil, let overlay = controlsOverlay() {
            canvas = overlay.composited(over: canvas)
            controlsDrawnUntil = now + 0.6
        }
        // Core Image 的原點在左下；Metal 貼圖的第一列是上緣，翻一下
        let flipped = canvas.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -S))
        ci.render(flipped, to: tex, commandBuffer: nil, bounds: CGRect(x: 0, y: 0, width: S, height: S),
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        onTexture?(tex)
    }
    private var controlsDrawnUntil: Double = 0

    private func nextTexture() -> MTLTexture? {
        if ring.isEmpty, let device {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            d.storageMode = .private
            ring = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
        }
        guard !ring.isEmpty else { return nil }
        ringIndex = (ringIndex + 1) % ring.count
        return ring[ringIndex]
    }

    /// 控制列（CG 畫一張透明圖，再轉成 CIImage）：底部漸暗、時間條、三顆鍵；左上「返回 CarPlay」
    private func controlsOverlay() -> CIImage? {
        let S = side
        let cur = player.currentTime().seconds, dur = player.currentItem?.duration.seconds ?? .nan
        let playing = player.rate > 0
        let key = "\(Int(cur))|\(Int(dur.isFinite ? dur : -1))|\(playing)|\(isBig)|\(L10n.language.rawValue)"
        if let c = overlayCache, c.key == key { return c.image }
        let img = makeImage(S, S) { g in
            let k = CGFloat(S) / 1024
            g.scaleBy(x: k, y: k)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let shade = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.62).cgColor] as CFArray,
                                   locations: [0, 1])!
            g.drawLinearGradient(shade, start: CGPoint(x: 0, y: 700), end: CGPoint(x: 0, y: 1024), options: [])
            let top = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0, alpha: 0.5).cgColor, NSColor(white: 0, alpha: 0).cgColor] as CFArray,
                                 locations: [0, 1])!
            g.drawLinearGradient(top, start: .zero, end: CGPoint(x: 0, y: 200), options: [])
            func pill(_ r: CGRect) {
                g.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
                g.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); g.fillPath()
            }
            func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, align: CGFloat = 0) {
                let f = NSFont.systemFont(ofSize: size, weight: .semibold)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor.white]))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                g.saveGState(); g.translateBy(x: x - CGFloat(w) * align, y: y); g.scaleBy(x: 1, y: -1)
                g.textPosition = .zero; CTLineDraw(line, g); g.restoreGState()
            }
            func symbol(_ name: String, _ r: CGRect) {
                let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: .semibold).applying(.init(paletteColors: [.white]))
                guard let im = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
                let s = im.size, kk = min(r.width / s.width, r.height / s.height)
                let dst = CGRect(x: r.midX - s.width * kk / 2, y: r.midY - s.height * kk / 2, width: s.width * kk, height: s.height * kk)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
                im.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            // 左上：返回 CarPlay；右上：放大
            pill(CGRect(x: 40, y: 40, width: 300, height: 76))
            symbol("chevron.left", CGRect(x: 66, y: 60, width: 26, height: 36))
            text(L("carvideo.back", "返回 CarPlay"), 104, 90, 32)
            pill(CGRect(x: 1024 - 116, y: 40, width: 76, height: 76))
            symbol(isBig ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", CGRect(x: 1024 - 100, y: 58, width: 44, height: 40))
            // 中下：後退 10 秒、播放／暫停、前進 10 秒
            symbol("gobackward.10", CGRect(x: 512 - 230, y: 792, width: 90, height: 80))
            symbol(playing ? "pause.fill" : "play.fill", CGRect(x: 512 - 50, y: 780, width: 100, height: 100))
            symbol("goforward.10", CGRect(x: 512 + 140, y: 792, width: 90, height: 80))
            // 時間條
            let bar = CGRect(x: 64, y: 930, width: 896, height: 10)
            g.setFillColor(NSColor(white: 1, alpha: 0.28).cgColor)
            g.addPath(CGPath(roundedRect: bar, cornerWidth: 5, cornerHeight: 5, transform: nil)); g.fillPath()
            if dur.isFinite, dur > 0 {
                let f = CGFloat(max(0, min(1, cur / dur)))
                g.setFillColor(NSColor.white.cgColor)
                g.addPath(CGPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: max(10, bar.width * f), height: bar.height),
                                 cornerWidth: 5, cornerHeight: 5, transform: nil)); g.fillPath()
                text(Self.clock(cur), 64, 990, 30)
                text("−" + Self.clock(max(0, dur - cur)), 960, 990, 30, align: 1)
            } else {
                text(Self.clock(cur), 64, 990, 30)
            }
        }
        let c = CIImage(cgImage: img)
        overlayCache = (key, c)
        return c
    }
    private var overlayCache: (key: String, image: CIImage)?

    /// 螢幕座標（0…1，左上原點）上的點擊：回 true＝影片控制吃掉了
    func click(u: CGFloat, v: CGFloat, windowFrame: NSRect?) -> Bool {
        guard active else { return false }
        let now = CACurrentMediaTime()
        if now > controlsUntil { controlsUntil = now + 3; return true }   // 第一下只叫出控制列
        controlsUntil = now + 3
        let x = u * 1024, y = v * 1024
        if y < 140 && x < 360 { stop(notify: true); return true }                    // 返回 CarPlay
        if y < 140 && x > 1024 - 140 { toggleBig(near: windowFrame); return true }   // 放大
        if y > 760 && y < 900 {
            if abs(x - 512) < 80 { togglePlay() } else if x < 512 && x > 240 { skip(-10) } else if x > 512 && x < 784 { skip(10) }
            return true
        }
        if y > 900, let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {   // 點時間條跳到那裡
            let f = max(0, min(1, (x - 64) / 896))
            player.seek(to: CMTime(seconds: dur * Double(f), preferredTimescale: 600)) { [weak self] _ in self?.reportState(force: true) }
            return true
        }
        return true
    }

    // MARK: 回報

    private func reportState(force: Bool) {
        guard let item = player.currentItem else { return }
        let prepared = item.status == .readyToPlay
        let pos = player.currentTime().seconds, dur = item.duration.seconds
        let buffered = item.loadedTimeRanges.map { $0.timeRangeValue }.map { $0.start.seconds + $0.duration.seconds }.max() ?? 0
        let d: [String: Any] = ["type": "carVideoState", "prepared": prepared, "playing": player.rate > 0,
                                "position": pos.isFinite ? pos : 0, "duration": dur.isFinite ? dur : 0, "buffered": buffered]
        let s = Self.json(d)
        // 位置每 0.5 秒都在變：照樣送（接收器靠它回答 iPhone 每秒一次的 playbackInfo）
        if force || s != lastStateSent { lastStateSent = s; send?(s) }
    }

    static func json(_ d: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    static func clock(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s.rounded(.down)), h = t / 3600, m = (t % 3600) / 60, ss = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
    }
}

/// 放大的影片視窗：16:9、可縮放、浮在最上層、所有桌面都在；雙擊或 Esc 收回桌寵螢幕。
final class CarVideoWindow: NSPanel {
    var onClose: (() -> Void)?
    init(player: AVPlayer, near: NSRect?) {
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(960, vis.width * 0.6), h = w * 9 / 16
        var origin = NSPoint(x: vis.midX - w / 2, y: vis.midY - h / 2)
        if let f = near {   // 從桌寵旁邊長出來：放在它左或右，夾在畫面內
            origin.x = f.midX > vis.midX ? f.minX - w - 24 : f.maxX + 24
            origin.y = f.midY - h / 2
            origin.x = max(vis.minX + 12, min(origin.x, vis.maxX - w - 12))
            origin.y = max(vis.minY + 12, min(origin.y, vis.maxY - h - 12))
        }
        super.init(contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        titleVisibility = .hidden; titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = NSSize(width: 16, height: 9)
        backgroundColor = .black
        isReleasedWhenClosed = false
        let v = NSView(); v.wantsLayer = true
        let pl = AVPlayerLayer(player: player)
        pl.videoGravity = .resizeAspect
        pl.frame = v.bounds; pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(pl)
        v.layer?.cornerRadius = 14; v.layer?.masksToBounds = true
        contentView = v
    }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { close() } else { super.keyDown(with: e) } }
    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { close() } else { super.mouseDown(with: e) } }
    override func close() { super.close(); onClose?() }
    override var canBecomeKey: Bool { true }
}
