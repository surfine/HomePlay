import AppKit
import ApplicationServices
import AVFoundation
import Metal
import RealityKit
import Combine
import simd
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO
import IOKit.ps
import IOKit.hid
import Carbon.HIToolbox
import Network
import EventKit
import ServiceManagement
import Security
import Accelerate

final class Face {
    private(set) var expression: Expression = .idle
    /// 游標在附近：待機的眼珠跟著游標（以前的「好奇」），不自己東張西望
    var followPointer = false
    /// 快照用：不眨、不瞄
    var frozen = false
    /// 好奇时眼珠看的方向（-1..1，x 往右、y 往下）
    var pointer: CGPoint?
    /// 整点（分钟走到 00）时叫一下
    var onHour: (() -> Void)?

    private(set) var cur = FaceParams.of(.idle), target = FaceParams.of(.idle)
    /// 表情正在往目標過渡：這幾幀要用 30fps 以上畫，否則 6 Hz 下過場一格一格跳
    private(set) var approaching = false
    var forceDirty = false
    /// 錶面要眼睛看哪裡（App 原始單位，同 FaceParams.pdx/pdy）；只在平常表情時生效。錶面在 drawIsland 前設、畫完清掉
    var faceEyeLook: CGPoint?
    static var renderCount = 0
    static var ambientPaused = false      // 過熱／低電量時停掉 Flow 氛圍動畫
    /// 貼圖解析度倍率（0.5…1）：按視窗大小選，預設視窗只畫 512²，省 4 倍光柵與上傳
    var renderScale: CGFloat = 0.5
    /// 靜態層快取（背景＋壓暗＋日期＋時間）：眨眼、瞄一眼不必重畫大號時間字
    var staticCache: (key: String, image: CGImage)?       // pocket：背景＋卡片＋玻璃
    var textLayerCache: (key: String, image: CGImage)?    // island：透明文字層
    var renderPixelScale: CGFloat = 0.5
    var wallpaperGeneration = 0
    static var cacheHits = 0, cacheMisses = 0
    static var dbgBlink = 0, dbgApproach = 0, dbgScreen = 0, dbgLive = 0, dbgOther = 0
    static var dbgPal = 0, dbgReveal = 0, dbgFlow = 0, dbgHello = 0, dbgExpr = 0
    /// 官網素材用：在同一格畫面強制眨眼／瞄一眼，第二張與第一張只差眼睛
    static var blinkOverride: CGFloat?
    static var glanceOverride = false
    /// 官網素材用：固定好奇時的眼珠方向，不受拍照時滑鼠在哪影響
    static var pointerOverride: CGPoint?
    static var renderSeconds = 0.0
    static var bgSeconds = 0.0, textSeconds = 0.0, islandSeconds = 0.0
    static var pocketA = 0.0, pocketC = 0.0, pocketD = 0.0
    /// 這段時間很值得用 60fps 畫（眨眼／hello／引導）——環境漂動不算
    func needsSmooth(_ now: Double) -> Bool {
        blinkEnd > 0 || helloStart >= 0 && now - helloStart < Self.helloDuration || onboardingActive
            || PermissionPrimer.visible || approaching
    }      // 效能基準用：臉部軟體重繪次數
    private var lastTick = CACurrentMediaTime()
    private var nextBlink = CACurrentMediaTime() + 2.5, blinkEnd = 0.0, doubleBlink = false
    private var nextGlance = CACurrentMediaTime() + 6, glanceEnd = 0.0
    private var lastMinute = -1, lastSecond = -1
    private var lastMinuteCheck: Double = 0

    func set(_ e: Expression, snap: Bool = false) {
        guard e != expression || snap else { return }
        Face.dbgExpr += 1
        expression = e; target = .of(e); forceDirty = true
        if snap { cur = target }
    }
    /// 让下一次 tick 眨一下（可延迟）：转头落定、刚看到人时用来收尾。
    func blinkSoon(after delay: Double = 0) {
        guard !frozen, expression != .asleep else { return }
        nextBlink = CACurrentMediaTime() + max(0, delay)
    }

    /// 有变化才重画；返回 nil 表示不用换贴图。
    func tick(_ now: Double) -> CGImage? {
        let dt = min(0.1, max(0, now - lastTick)); lastTick = now
        var dirty = forceDirty; forceDirty = false

        // 眨眼：约 4 s ± 0.6 一次，八分之一机率连眨两下；困倦时眨得慢、隔得久；睡着不眨
        let slow = expression == .sleepy
        if !frozen && expression != .asleep {
            if blinkEnd == 0 && now > nextBlink { blinkEnd = now + (slow ? 0.38 : 0.13); dirty = true; Face.dbgBlink += 1 }
            if blinkEnd > 0 {
                if slow { dirty = true }
                if now > blinkEnd {
                    blinkEnd = 0; dirty = true
                    if !doubleBlink && Double.random(in: 0..<1) < 0.125 { doubleBlink = true; nextBlink = now + 0.16 }
                    else { doubleBlink = false; nextBlink = now + (slow ? 6 : 4) + Double.random(in: -0.6...0.6) }
                }
            }
        } else if blinkEnd > 0 { blinkEnd = 0; dirty = true }

        // 瞄：只在待机，每 7–11 s 往右上看 1.4 s
        if !frozen && expression == .idle && !followPointer {
            if glanceEnd == 0 && now > nextGlance { glanceEnd = now + 1.4 }
            if glanceEnd > 0 && now > glanceEnd { glanceEnd = 0; nextGlance = now + 7 + Double.random(in: 0...4) }
        } else { glanceEnd = 0 }

        var t = target
        if expression == .idle, followPointer || Face.pointerOverride != nil, let p = Face.pointerOverride ?? pointer {
            t.pdx = max(-1, min(1, p.x)) * 15; t.pdy = max(-1, min(1, p.y)) * 18
        }
        if glanceEnd > 0 || Face.glanceOverride { t.pdx = 13; t.pdy = -14 }
        if Face.glanceOverride {
            if cur != t { cur = t; dirty = true; Face.dbgApproach += 1 }   // 快照：一步到位
        } else if animateDetails {
            approaching = cur.approach(t, CGFloat(1 - exp(-dt * 14)))
            if approaching { dirty = true; Face.dbgApproach += 1 }
        } else if cur != t {
            cur = t; dirty = true; Face.dbgApproach += 1
        }

        // 睡着的 z 一秒换一次位置（这时整个视图也降到 1 fps）
        if expression == .asleep {
            let s = Int(now)
            if s != lastSecond { lastSecond = s; dirty = true }
        }
        if tickScreen(now, dt) { dirty = true; Face.dbgScreen += 1 }
        if tickLive(now, dt) { dirty = true; Face.dbgLive += 1 }
        // 分鐘只決定錶面/壁紙換不換，每秒查一次就夠；Calendar 查詢不便宜，不該每幀做。
        if now - lastMinuteCheck >= 1 {
            lastMinuteCheck = now
            let minute = Calendar.current.component(.minute, from: Date())
            if minute != lastMinute {
                if minute == 0 && lastMinute != -1 { onHour?() }
                lastMinute = minute; dirty = true
            }
        }
        return dirty ? render(now) : nil
    }

    func blinkFactor(_ now: Double) -> CGFloat {
        if let b = Face.blinkOverride { return b }
        guard blinkEnd > 0 else { return 1 }
        guard expression == .sleepy else { return 0.1 }
        let k = 1 - (blinkEnd - now) / 0.38
        return max(0.08, abs(1 - 2 * CGFloat(k)))
    }

    // MARK: 屏幕里的液态玻璃
    // 壁纸随一天变（清晨暖、白天青绿、黄昏琥珀紫、夜里深蓝，相邻两组插值）；G4 白外观的白天换成 Aqua 蓝。
    // 壁纸是柔边色块，画在 256 px 上再放大就够；色块跟着游标慢慢漂（Flow）。模糊版跟着一起重算。

    struct RGB { var r, g, b: CGFloat
        init(_ hex: UInt32) { r = CGFloat(hex >> 16 & 0xff) / 255; g = CGFloat(hex >> 8 & 0xff) / 255; b = CGFloat(hex & 0xff) / 255 }
        init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
        func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
        func color(_ a: CGFloat = 1) -> CGColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor }
    }
    struct Palette {
        var top: RGB, bottom: RGB, blobs: [(RGB, CGFloat)]
        init(_ top: UInt32, _ bottom: UInt32, _ blobs: [(UInt32, CGFloat)]) {
            self.top = RGB(top); self.bottom = RGB(bottom); self.blobs = blobs.map { (RGB($0.0), $0.1) }
        }
        init(top: RGB, bottom: RGB, blobs: [(RGB, CGFloat)]) { self.top = top; self.bottom = bottom; self.blobs = blobs }
        func mix(_ o: Palette, _ t: CGFloat) -> Palette {
            Palette(top: top.mix(o.top, t), bottom: bottom.mix(o.bottom, t),
                    blobs: zip(blobs, o.blobs).map { ($0.0.mix($1.0, t), $0.1 + ($1.1 - $0.1) * t) })
        }
    }
    static let dawn = Palette(0x3a4f7a, 0xd3957c, [(0xffc49b, 0.55), (0xb9a6f0, 0.45), (0xffd98a, 0.35), (0x9fd8ff, 0.2)])
    static let day = Palette(0x1d4a57, 0x2f6a63, [(0x74e3c4, 0.55), (0x3f82d8, 0.55), (0xf2c27c, 0.38), (0x9fe8ff, 0.18)])
    static let aquaDay = Palette(0x1b4f9c, 0x58a8e6, [(0x9fe2ff, 0.55), (0x2b6fd6, 0.5), (0xe9f6ff, 0.35), (0x7fd0ff, 0.25)])
    static let dusk = Palette(0x2b2350, 0x8a4a5e, [(0xffae6b, 0.5), (0x8f6bdc, 0.5), (0xff7f9e, 0.35), (0xffd98a, 0.2)])
    static let night = Palette(0x070d1f, 0x152447, [(0x2e5bbd, 0.5), (0x4b3fa8, 0.45), (0x2a8f8a, 0.25), (0x9fb8ff, 0.12)])

    /// 钟点（0..<24，可带小数）→ 色票：7 点清晨、12 点白天、18 点黄昏、23 点夜里，之间平滑插值，绕一圈
    static func palette(hour h0: Double, aqua: Bool) -> Palette {
        let keys: [(Double, Palette)] = [(7, dawn), (12, aqua ? aquaDay : day), (18, dusk), (23, night), (31, dawn)]
        let h = h0 < 7 ? h0 + 24 : h0
        for i in 0..<(keys.count - 1) where h >= keys[i].0 && h < keys[i + 1].0 {
            let t = (h - keys[i].0) / (keys[i + 1].0 - keys[i].0)
            let s = t * t * (3 - 2 * t)
            return keys[i].1.mix(keys[i + 1].1, CGFloat(s))
        }
        return dawn
    }

    /// G4 白外观：屏幕走 Aqua（细条纹、凝胶高光），游标靠近时转头幅度更大（向日葵）
    var aqua = false { didSet { if aqua != oldValue { paletteKey = -1; forceDirty = true } } }
    /// 只给快照用：假装现在是几点（只影响壁纸色票）
    var hourOverride: Double?
    /// 游标离多近（0 远 … 1 近）：近了玻璃卡展开，多显示日期和 CarPlay 状态
    var revealTarget: CGFloat = 0
    /// 遠距離省電：沒人靠近時表情/視線直接到位，不做過場動畫（省下每幾秒十幾幀重繪）
    var animateDetails = true
    private(set) var reveal: CGFloat = 0
    /// 色块要不要跟着游标漂（游标在附近、醒着时）
    var flowActive = false
    /// 玻璃卡最下面一行：CarPlay 的真实状态
    var status: CarPlayStatus = .notConnected { didSet { if status != oldValue { forceDirty = true } } }
    /// 磁貼用：把「CarPlay xxx · 提示」拆成大字和小字（去掉開頭的 CarPlay，英文首字母大寫）
    var statusParts: (title: String, hint: String?) {
        let parts = status.text.replacingOccurrences(of: "CarPlay ", with: "").components(separatedBy: " · ")
        let t = parts.first ?? status.text
        return (t.prefix(1).uppercased() + t.dropFirst(), parts.count > 1 ? parts[1] : nil)
    }
    private var helloStart = -1.0
    static let helloDuration = 2.6

    private(set) var wallpaper: CGImage?, frosted: CGImage?
    private var paletteKey = -1
    private(set) var flow = CGPoint.zero, flowV = CGPoint.zero, builtFlow = CGPoint(x: 9, y: 9)
    private var lastWall = 0.0
    /// 輕量模糊（兩次 tent ≈ 高斯）：不經過 GPU／Core Image
    static func cpuBlur(_ img: CGImage, radius: Int) -> CGImage? {
        let w = img.width, h = img.height, rb = w * 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue), let src = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let tmp = malloc(rb * h) else { return nil }
        defer { free(tmp) }
        var a = vImage_Buffer(data: src, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rb)
        var b = vImage_Buffer(data: tmp, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rb)
        let k = UInt32(radius * 2 + 1)
        guard vImageTentConvolve_ARGB8888(&a, &b, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError,
              vImageTentConvolve_ARGB8888(&b, &a, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError else { return nil }
        return ctx.makeImage()
    }
    private static let blobSpots: [(CGPoint, CGFloat, CGFloat)] =   // 位置、半径、视差（跟游标漂的比例）
        [(CGPoint(x: 780, y: 230), 360, 1.0), (CGPoint(x: 170, y: 840), 420, -0.7),
         (CGPoint(x: 900, y: 930), 300, 0.5), (CGPoint(x: 330, y: 470), 260, -1.2)]

    /// 只會用到 15 分鐘一格的色票，沒必要每幀算一次；半分鐘更新一次足夠。
    private var cachedHour: Double = -1
    private var cachedHourAt: Double = -1
    var hourNow: Double {
        if let hourOverride { return hourOverride }
        let now = CACurrentMediaTime()
        if cachedHour < 0 || now - cachedHourAt > 30 {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            cachedHour = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
            cachedHourAt = now
        }
        return cachedHour
    }

    func rebuildWallpaper() {
        wallpaperGeneration &+= 1
        let pal = Self.palette(hour: hourNow, aqua: aqua), fl = flow, isAqua = aqua
        let img = makeImage(256, 256) { g in
            g.scaleBy(x: 0.25, y: 0.25)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
            let grad = CGGradient(colorsSpace: cs, colors: [pal.top.color(), pal.bottom.color()] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 1024), options: [])
            for (i, spot) in Self.blobSpots.enumerated() {
                let (c0, r, par) = spot, (col, a) = pal.blobs[i]
                let c = CGPoint(x: c0.x + fl.x * 70 * par, y: c0.y + fl.y * 70 * par)
                let b = CGGradient(colorsSpace: cs, colors: [col.color(a), col.color(0)] as CFArray, locations: [0, 1])!
                g.drawRadialGradient(b, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }
            if isAqua {
                // Aqua 那种大弧线光带（自己画的，不是任何官方壁纸）
                g.setLineCap(.round)
                for (k, w, a) in [(0.0, 90.0, 0.10), (1.0, 46.0, 0.14), (2.0, 20.0, 0.18)] as [(CGFloat, CGFloat, CGFloat)] {
                    g.setStrokeColor(NSColor(white: 1, alpha: a).cgColor); g.setLineWidth(w)
                    g.addEllipse(in: CGRect(x: -380 + k * 60 + fl.x * 40, y: 420 - k * 40 + fl.y * 30, width: 1700, height: 900))
                    g.strokePath()
                }
            }
            g.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
            g.fillEllipse(in: CGRect(x: 820 - 260, y: 180 - 260, width: 520, height: 520))
        }
        wallpaper = img
        // 用 CPU（Accelerate）模糊：真機 2026-10-25 首次設定時 Core Image 在這裡 GPU 段錯誤閃退
        frosted = Self.cpuBlur(img, radius: 7) ?? img
        builtFlow = flow
    }

    /// 启动时的彩蛋：屏幕先用手写体写一个 hello，再换成脸（G4 白外观才有）
    func sayHello(_ now: Double) { helloStart = now; forceDirty = true }
    func cancelHello() { helloStart = -1; forceDirty = true }
    var sayingHello: Bool { helloStart >= 0 && CACurrentMediaTime() - helloStart < Self.helloDuration }

    /// 每帧推进壁纸、展开、Flow；有变化返回 true
    private func tickScreen(_ now: Double, _ dt: Double) -> Bool {
        var dirty = false
        let key = Int(hourNow * 4) + (aqua ? 1000 : 0)
        if key != paletteKey || wallpaper == nil { paletteKey = key; rebuildWallpaper(); dirty = true; Face.dbgPal += 1 }

        let r0 = reveal
        reveal += (revealTarget - reveal) * CGFloat(1 - exp(-dt / 0.18))
        if abs(revealTarget - reveal) < 0.002 { reveal = revealTarget }
        if reveal != r0 { dirty = true; Face.dbgReveal += 1 }

        // Flow：临界阻尼弹簧，响应 1.2 s；漂动时最多每秒重画 20 次
        var goal = CGPoint.zero
        if flowActive || style == .flow, let p = pointer { goal = CGPoint(x: max(-1, min(1, p.x)), y: max(-1, min(1, p.y))) }
        let k = pow(2 * Double.pi / 1.2, 2), c = 2 * sqrt(k)
        flowV.x += CGFloat((Double(goal.x - flow.x) * k - Double(flowV.x) * c) * dt); flow.x += flowV.x * CGFloat(dt)
        flowV.y += CGFloat((Double(goal.y - flow.y) * k - Double(flowV.y) * c) * dt); flow.y += flowV.y * CGFloat(dt)
        if hypot(flow.x - builtFlow.x, flow.y - builtFlow.y) > 0.004, now - lastWall > 0.16 {
            lastWall = now; rebuildWallpaper(); dirty = true; Face.dbgFlow += 1
        }
        if helloStart >= 0 {
            if now - helloStart < Self.helloDuration { dirty = true } else { helloStart = -1; dirty = true }
            Face.dbgHello += 1
        }
        return dirty
    }

    /// 画布已翻成左上原点，直接画 CGImage 会上下颠倒；这里翻回来画，r 是左上原点的目标框
    func drawUpright(_ g: CGContext, _ img: CGImage, in r: CGRect) {
        g.saveGState(); g.translateBy(x: 0, y: r.minY + r.maxY); g.scaleBy(x: 1, y: -1)
        g.interpolationQuality = .high
        g.draw(img, in: r); g.restoreGState()
    }
    /// 以 c 为中心放大 s 倍画一张整屏图（玻璃的「透镜」：中间轻放大，边缘一圈放大得更多＝折射）
    func lens(_ g: CGContext, _ img: CGImage, around c: CGPoint, _ s: CGFloat) {
        drawUpright(g, img, in: CGRect(x: c.x - c.x * s, y: c.y - c.y * s, width: 1024 * s, height: 1024 * s))
    }

    /// 一块液态玻璃：底下一圈软阴影；里面透出模糊并轻放大的壁纸，边缘 band 宽的一圈折射更强；
    /// 上一层染色和顶部内光；Aqua 时再加细横条纹和上半部的凝胶高光；最后是左上亮、右下次亮的镜面细边。
    func glass(_ g: CGContext, _ r: CGRect, radius: CGFloat, tint: NSColor, band: CGFloat = 16) {
        guard let frosted else { return }
        let pill = radius >= r.height / 2 - 0.5   // 膠囊維持半圓兩端；卡片用跟螢幕同一種連續圓角
        func shape(_ rr: CGRect, _ rad: CGFloat) -> CGPath {
            pill ? CGPath(roundedRect: rr, cornerWidth: min(rad, rr.height / 2), cornerHeight: min(rad, rr.height / 2), transform: nil) : continuousRoundedRect(rr, radius: rad)
        }
        let path = shape(r, radius)
        let c = CGPoint(x: r.midX, y: r.midY)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 18), blur: 44, color: NSColor(white: 0, alpha: 0.32).cgColor)
        g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
        g.restoreGState()

        g.saveGState()
        g.addPath(path); g.clip()
        lens(g, frosted, around: c, 1.05)
        let ir = r.insetBy(dx: band, dy: band), irad = max(1, radius - band)
        g.addPath(path); g.addPath(shape(ir, irad))
        g.clip(using: .evenOdd)
        lens(g, frosted, around: c, 1.16)
        g.restoreGState()

        g.saveGState()
        g.addPath(path); g.clip()
        g.setFillColor(tint.cgColor); g.fill(r)
        if aqua {
            g.setFillColor(NSColor(white: 1, alpha: 0.045).cgColor)
            var y = r.minY; while y < r.maxY { g.fill(CGRect(x: r.minX, y: y, width: r.width, height: 2)); y += 6 }
            let hr = CGRect(x: r.minX + 10, y: r.minY + 6, width: r.width - 20, height: r.height * 0.48)
            let hrad = min(radius - 6, hr.height / 2)
            g.addPath(shape(hr, max(1, hrad))); g.clip()
            let gel = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0.06).cgColor] as CFArray,
                                 locations: [0, 1])!
            g.drawLinearGradient(gel, start: CGPoint(x: 0, y: hr.minY), end: CGPoint(x: 0, y: hr.maxY), options: [])
        } else {
            let glow = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.20).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1])!
            g.drawLinearGradient(glow, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.minY + r.height * 0.45), options: [])
        }
        g.restoreGState()

        g.saveGState()
        g.addPath(path); g.setLineWidth(5); g.replacePathWithStrokedPath(); g.clip()
        let rim = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.95).cgColor, NSColor(white: 1, alpha: 0.12).cgColor,
                                                       NSColor(white: 1, alpha: 0.12).cgColor, NSColor(white: 1, alpha: 0.55).cgColor] as CFArray,
                             locations: [0, 0.35, 0.65, 1])!
        g.drawLinearGradient(rim, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
    }

    // MARK: 錶面与即时动态

    /// 现在用哪个錶面
    var style: FaceStyle = .island { didSet { if style != oldValue { beginFaceTransition(); forceDirty = true } } }
    /// 換錶面的過場：舊的一張（清楚版＋霧化版）與開始時刻（Faces/ScreenGeometry.swift 的 drawFaceTransition）
    var lastFrame: CGImage?
    /// 這一幀膠囊（眼睛）佔的範圍（1024 畫布）：海報補丁只補這裡面的變化（眨眼、瞄一眼）
    var islandRect: CGRect?
    private var islandRectBuilding: CGRect?
    var faceTransition: (sharp: CGImage, frosted: CGImage, start: Double)?
    /// 島錶面的自由组合（见 IslandOptions.swift）
    var clockStyle: ClockStyle = .bold { didSet { if clockStyle != oldValue { forceDirty = true } } }
    var background: IslandBackground = .daytime { didSet { if background != oldValue { forceDirty = true } } }
    var era: Era = .y2026 { didSet { if era != oldValue { forceDirty = true } } }
    var typographMaterial: TypographMaterial = .flat { didSet { if typographMaterial != oldValue { forceDirty = true } } }
    var system6Layout: System6Layout = .finder { didSet { if system6Layout != oldValue { forceDirty = true } } }
    /// 正在播放（NowPlaying.swift 的轮询写入；计时器优先）
    var nowPlaying = NowPlayingState()
    /// 电量（PetView 每分钟读一次）；nil＝没有电池
    var battery: Battery.Reading? { didSet { if battery != oldValue { forceDirty = true } } }
    var photos = PhotoShelf(folder: PhotoShelf.defaultFolder)
    /// 模組錶面「下一个行程」那一格（CalendarSource.swift 写入；真数据）
    var calendarTile: CalendarTile = .notConnected { didSet { if calendarTile != oldValue { forceDirty = true } } }
    /// 计时器到点时叫一下（PetView 让岛惊讶、甩头）
    var onTimerDone: (() -> Void)?
    private(set) var timerEnd: Double?
    private(set) var timerTotal = 1.0
    /// 番茄鐘在跑時，計時器的標題與到點橫幅改成番茄鐘的說法
    var pomodoro = Pomodoro() { didSet { if pomodoro != oldValue { forceDirty = true } } }
    /// 計時器這一格的標題：一般「計時器」；番茄鐘「專注 2/4」「休息一下」「長休息」
    var timerLabel: String {
        switch pomodoro.phase {
        case .focus: return String(format: L("pomodoro.focusRound", "专注 %d/%d"), pomodoro.displayRound, Pomodoro.roundsPerSet)
        case .shortBreak: return L("pomodoro.break", "休息一下")
        case .longBreak: return L("pomodoro.longBreak", "长休息")
        case nil: return L("timer.title", "计时器")
        }
    }
    /// 到點橫幅（剛結束的那一段）：標題與大字
    private(set) var bannerTexts: (title: String, big: String)?
    private var lastTimerSecond = -1
    private(set) var liveT: CGFloat = 0          // 岛长成即时动态的进度（0 岛 … 1 计时器胶囊）
    private var bannerUntil = 0.0
    var timerActive: Bool { timerEnd != nil }
    /// 这些錶面自己有计时器那一格/那张卡，岛不用长成胶囊
    static let timerInTile: Set<FaceStyle> = [.modular, .pocket]
    var bannerShowing: Bool { CACurrentMediaTime() < bannerUntil }

    func startTimer(seconds: Double, now: Double = CACurrentMediaTime()) {
        timerTotal = max(1, seconds); timerEnd = now + timerTotal; bannerUntil = 0; forceDirty = true
        timerEndWall = Date().timeIntervalSinceReferenceDate + timerTotal
    }
    /// Mac 睡眠时 CACurrentMediaTime 不走：醒来按墙上时间把到点时刻对回来
    private var timerEndWall: Double?
    func resyncTimer(now: Double = CACurrentMediaTime()) {
        guard timerEnd != nil, let w = timerEndWall else { return }
        timerEnd = now + (w - Date().timeIntervalSinceReferenceDate); forceDirty = true
    }
    func cancelTimer() { timerEnd = nil; timerEndWall = nil; forceDirty = true }
    func showBanner(now: Double = CACurrentMediaTime(), texts: (title: String, big: String)? = nil) {
        bannerTexts = texts; bannerUntil = now + 12; forceDirty = true
    }
    func dismissBanner() { bannerUntil = 0; forceDirty = true }

    /// 计时器、展开动画、横幅、照片：有变化回 true
    private func tickLive(_ now: Double, _ dt: Double) -> Bool {
        var dirty = false
        if let end = timerEnd {
            if now >= end {
                timerEnd = nil; showBanner(now: now); onTimerDone?(); dirty = true
            } else {
                let s = Int((end - now).rounded(.up))
                if s != lastTimerSecond { lastTimerSecond = s; dirty = true }
            }
        }
        if tickMusic(now) { dirty = true }
        if siriOrb.active(now) || (siriOrb.upAt > 0 && now - siriOrb.upAt < SiriOrbState.think + SiriOrbState.settle + 0.1) { dirty = true }
        let goal: CGFloat = (timerActive || musicActive(now)) && !Self.timerInTile.contains(style) ? 1 : 0
        if liveT != goal {
            liveT += (goal - liveT) * CGFloat(1 - exp(-dt / 0.12))
            if abs(goal - liveT) < 0.003 { liveT = goal }
            dirty = true
        }
        if bannerUntil > 0, now >= bannerUntil { bannerUntil = 0; dirty = true }
        if tickOnboarding(now) { dirty = true }   // 第一次打开的操作提示（Onboarding.swift）
        if style == .photos || (style == .island && background == .photo) || FaceOverview.active, photos.tick(now) { dirty = true }
        if tickCarPlayOverlay(now, dt) { dirty = true }   // 连线中过场的淡入淡出与转圈
        if tickPermissionPrimer(now, dt) { dirty = true }   // 权限说明卡（PermissionPrimer.swift）
        // 各錶面自己要不要重画（秒针、轮替、漂动…），实现在 Faces/ 里
        switch style {
        case .analog: if (typographMaterial == .embossed ? tickEmbossedFace(now) : tickAnalogFace(now)) { dirty = true }
        case .flow: if tickFlowFace(now) { dirty = true }
        case .pocket: if tickPocketFace(now) { dirty = true }
        case .growth: if tickGrowthFace(now) { dirty = true }
        case .system6:
            switch system6Layout {
            case .finder: if tickSystem6Face(now) { dirty = true }
            case .alarmClock: if tickAlarmClockFace(now) { dirty = true }
            case .about: if tickAboutFace(now) { dirty = true }
            }
        case .weather: if tickWeatherFace(now) { dirty = true }
        case .modular: if tickModularFace(now) { dirty = true }
        case .calendar: if tickCalendarFace(now) { dirty = true }
        case .homeModular: if tickHomeModularFace(now) { dirty = true }
        case .embossed: if tickEmbossedFace(now) { dirty = true }
        case .black: if tickBlackFace(now) { dirty = true }
        case .alarmClock: if tickAlarmClockFace(now) { dirty = true }
        case .about: if tickAboutFace(now) { dirty = true }
        case .island: if tickIslandOptions(now) { dirty = true }
        default: break
        }
        if tickOverview(now, dt) { dirty = true }   // 长按换錶面总览（FaceOverview.swift）
        if faceTransition != nil { dirty = true }  // 換錶面的過場還在跑
        return dirty
    }

    func render(_ now: Double = CACurrentMediaTime()) -> CGImage {
        Face.renderCount += 1
        let t0 = CACurrentMediaTime()
        defer { Face.renderSeconds += CACurrentMediaTime() - t0 }
        if wallpaper == nil { rebuildWallpaper() }
        let sc = max(0.25, min(2, renderScale))
        renderPixelScale = sc
        let px = Int((1024 * sc).rounded())
        let tr = faceTransitionProgress(now)
        islandRectBuilding = nil
        defer { islandRect = islandRectBuilding }
        let frame = makeImage(px, px) { g in
            if sc != 1 { g.scaleBy(x: sc, y: sc) }
            if let tr { beginFaceTransitionFrame(g, tr) }
            if helloStart >= 0, now - helloStart < Self.helloDuration {
                if let wallpaper { drawUpright(g, wallpaper, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
                drawHello(g, CGFloat((now - helloStart) / Self.helloDuration)); return
            }
            switch style {
            case .island: renderIslandFace(g, now)
            case .photos: renderPhotosFace(g, now)
            case .modular: renderModularFace(g, now)
            case .bedside: renderBedsideFace(g, now)
            // 下面几个各在 Faces/ 里自己的文件
            case .analog: if typographMaterial == .embossed { renderEmbossedFace(g, now) } else { renderAnalogFace(g, now) }   // 材質：Faces/EmbossedFace.swift
            case .flow: renderFlowFace(g, now)
            case .pocket: renderPocketFace(g, now)
            case .growth: renderGrowthFace(g, now)
            case .system6:
                switch system6Layout {   // 版式：Faces/System6Series.swift
                case .finder: renderSystem6Face(g, now)
                case .alarmClock: renderAlarmClockFace(g, now)
                case .about: renderAboutFace(g, now)
                }
            case .weather: renderWeatherFace(g, now)          // Faces/WeatherFace.swift
            case .calendar: renderCalendarFace(g, now)        // Faces/CalendarFace.swift
            case .homeModular: renderHomeModularFace(g, now)  // Faces/HomeModularFace.swift
            case .embossed: renderEmbossedFace(g, now)        // Faces/EmbossedFace.swift
            case .black: renderBlackFace(g, now)              // Faces/BlackFace.swift
            case .alarmClock: renderAlarmClockFace(g, now)    // Faces/System6Series.swift
            case .about: renderAboutFace(g, now)              // Faces/System6Series.swift
            }
            if let tr { endFaceTransitionFrame(g, tr) }   // 舊錶面像起霧的玻璃一樣化開
            drawCarPlayOverlay(g, now)   // 连线中过场（CarPlayOverlay.swift）
            if FaceOverview.active { drawOverview(g, now) }   // 长按换錶面总览盖在最上面
            if Onboarding.active { drawOnboarding(g, now) }   // 第一次打开的操作提示
            drawPermissionPrimer(g, now)                       // 权限说明卡盖在最上面（要点按钮）
            if bannerUntil > now { drawBanner(g, red: style == .bedside) }
            if cur.dim > 0.005 && style != .bedside {
                g.setFillColor(NSColor.black.withAlphaComponent(cur.dim).cgColor)
                g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            }
        }
        lastFrame = frame
        return frame
    }

    /// 島：上方一行小字日期，中间巨大的圆体时间，岛站在数字前面（像 Portraits 的景深）。
    /// 远处是恒亮的省电样子（整面暗一点、数字细一点），游标靠近才亮起来、数字变粗，底部浮出 CarPlay 状态。
    private func renderIslandFace(_ g: CGContext, _ now: Double) { renderIslandOptions(g, now) }   // 实现在 IslandOptions.swift

    /// 照片：照片铺满，左上是星期与大时间，右下一只小岛；拍摄日期在左下。
    private func renderPhotosFace(_ g: CGContext, _ now: Double) { renderPhotosV2(g, now) }   // Faces/PhotosFace.swift

    /// 模組：照 HomeView 的 Modular 重做（Faces/ModularFace.swift）
    private func renderModularFace(_ g: CGContext, _ now: Double) { renderModularV2(g, now) }

    /// 床头夜灯：全黑底、暗紅的窄高細字大時間（不刺眼、看得清），島閉著眼；不吃壁紙、不跟游標亮起來。
    private func renderBedsideFace(_ g: CGContext, _ now: Double) {
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let date = Self.displayDate, red = srgb(0xa8241c)
        drawCentered(g, Self.dateLine(date), font: FaceType.sf(36, .semibold), kern: 0.6, y: 150, color: srgb(0x5e1712))
        let (hh, mm) = Self.hourMinute(date)
        let (a, b) = GlyphShape.centeredPair(GlyphShape.adaptive(hh, height: 470, maxWidth: 400, at: CGPoint(x: 492, y: 210), anchorX: 1, weight: 220),
                                             GlyphShape.adaptive(mm, height: 470, maxWidth: 400, at: CGPoint(x: 532, y: 210), anchorX: 0, weight: 220))
        // 一點點同色的光暈，像夜裡的 LED，不是平面貼字
        g.saveGState()
        g.setShadow(offset: .zero, blur: 26, color: red.withAlphaComponent(0.45).cgColor)
        fillShape(g, a, red); fillShape(g, b, red)
        g.restoreGState()
        drawIsland(g, at: CGPoint(x: 512, y: 820), scale: 0.62, liveAt: CGPoint(x: 512, y: 820), now: now, red: true)
    }

    // 錶面每次重畫都會叫：DateFormatter 建一次約幾十微秒，用 FaceKit 的快取（依語言分開）
    static func clock(_ d: Date) -> String { formatter("H:mm", raw: true).string(from: d) }
    static func dateLine(_ d: Date) -> String { formatter("MMMMdEEEE").string(from: d) }
    /// 電量狀態一行字（模組、口袋共用）
    static func batteryState(_ b: Battery.Reading) -> String {
        b.charging ? L("battery.charging", "充电中") : (b.onAC ? L("battery.pluggedIn", "已接电源") : L("battery.onBattery", "使用电池"))
    }

    /// 岛：深色液态玻璃胶囊 + 两颗贴在一起的白眼。at/scale 是平常的位置和大小；
    /// 计时器在跑时长成一条宽胶囊（liveAt 是长大后的中心）：眼睛缩到左边，右边是倒数与圆环。red＝床头夜灯的暗红版。
    func drawIsland(_ g: CGContext, at c0: CGPoint, scale s0: CGFloat, liveAt lc: CGPoint, now: Double, red: Bool = false) {
        if capsuleLook() == .system && isSystem6Era && !red && liveT < 0.02 && !siriOrb.active(now) {   // 1988：1-bit 預設按鈕（Faces/System6Series.swift）
            drawPixelIsland(g, center: c0, scale: s0, now: now); return
        }
        let p = cur, lt = Self.timerInTile.contains(style) ? 0 : liveT
        let k0 = 1.4 * s0
        let cw0 = p.cw * k0, ch0 = p.ch * k0
        let cw = cw0 + (880 - cw0) * lt, ch = ch0 + (230 - ch0) * lt
        let c = CGPoint(x: c0.x + (lc.x - c0.x) * lt, y: c0.y + (lc.y - c0.y) * lt)
        let rect = CGRect(x: c.x - cw / 2, y: c.y - ch / 2, width: cw, height: ch)
        let eyesArea = rect.insetBy(dx: -ch * 0.6, dy: -ch * 0.45)   // 臉頰紅暈、睡著的 z 會畫到膠囊外面一點
        islandRectBuilding = islandRectBuilding.map { $0.union(eyesArea) } ?? eyesArea
        let orb = red || lt > 0.02 ? nil : siriOrbGeometry(rect, now: now)   // 按住 F5：Siri 球（Faces/Capsule.swift）
        if red {
            g.setFillColor((style == .black ? NSColor.black : srgb(0x140403)).cgColor)   // 黑錶面夜裡膠囊融進全黑，只剩眼瞼線
            g.addPath(CGPath(roundedRect: rect, cornerWidth: ch / 2, cornerHeight: ch / 2, transform: nil)); g.fillPath()
        } else if let orb {
            drawSiriOrb(g, orb.rect, listen: orb.listen, think: orb.think, now: now)
        } else if aqua && style != .island {
            glass(g, rect, radius: ch / 2, tint: NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 0.8), band: 20 * s0)
        } else {
            drawCapsuleBody(g, rect, look: lt > 0.02 ? .smoke : capsuleLook(), animating: false)   // 長成計時器／音樂時一律黑透，字才看得清
        }
        let ke = k0 + (1.4 * 0.62 - k0) * lt
        let ex = c.x + (-cw / 2 + 150) * lt
        if red {
            // 闭着眼：两道暗红的眼皮
            g.setFillColor(srgb(0xa3271f).cgColor)
            for s: CGFloat in [-1, 1] {
                let r = CGRect(x: ex + s * p.sep * ke - 30 * ke, y: c.y - 5 * ke, width: 60 * ke, height: 10 * ke)
                g.addPath(CGPath(roundedRect: r, cornerWidth: 5 * ke, cornerHeight: 5 * ke, transform: nil)); g.fillPath()
            }
        } else {
            if p.blush > 0.01 && lt < 0.5 {
                g.setFillColor(NSColor(srgbRed: 1, green: 150 / 255, blue: 170 / 255, alpha: 0.55 * p.blush * (1 - lt * 2)).cgColor)
                for s: CGFloat in [-1, 1] {   // 收在膠囊裡、眼睛外下方
                    let bx = c.x + s * (p.sep * k0 + p.rx * k0 * 1.55), by = c.y + p.ry * k0 * 0.62
                    g.fillEllipse(in: CGRect(x: bx - 30 * s0, y: by - 16 * s0, width: 60 * s0, height: 32 * s0))
                }
            }
            let bf = blinkFactor(now)
            if let orb {   // Siri 球：眼睛跟著球往下、略往上讓出波形；思考時淡出
                g.saveGState(); g.setAlpha(1 - orb.think)
                let ey = orb.rect.midY - orb.rect.height * 0.13 * orb.listen
                for s: CGFloat in [-1, 1] { drawEye(g, cx: orb.rect.midX + s * p.sep * ke, cy: ey, side: s, blinkF: bf, k: ke) }
                g.restoreGState()
            } else {
                for s: CGFloat in [-1, 1] { drawEye(g, cx: ex + s * p.sep * ke, cy: c.y, side: s, blinkF: bf, k: ke) }
            }
        }
        if lt > 0.02, timerEnd == nil { drawMusicCapsule(g, rect: rect, c: c, lt: lt, now: now, red: red) }
        if lt > 0.02, let end = timerEnd {
            let left = max(0, end - now), frac = CGFloat(left / timerTotal)
            let accent = red ? srgb(0xb3261e) : srgb(0xffb340)
            g.saveGState(); g.setAlpha(min(1, (lt - 0.3) / 0.7))
            drawLeft(g, timerLabel, font: Self.rounded(34, weight: .bold), x: rect.minX + 300, y: c.y - 14, color: accent)
            drawLeft(g, L("timer.left", "还剩"), font: Self.rounded(30, weight: .semibold), x: rect.minX + 300, y: c.y + 36,
                     color: NSColor.white.withAlphaComponent(red ? 0.35 : 0.6))
            let font = Self.rounded(118, weight: .semibold), txt = timerClock(left)
            let tw = Typo.width(txt, font)
            drawLeft(g, txt, font: font, x: rect.maxX - 200 - tw, y: c.y + 42, color: accent)
            let rc = CGPoint(x: rect.maxX - 104, y: c.y)
            g.setLineWidth(15); g.setLineCap(.round)
            g.setStrokeColor(accent.withAlphaComponent(0.25).cgColor)
            g.addArc(center: rc, radius: 52, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
            g.setStrokeColor(accent.cgColor)
            g.addArc(center: rc, radius: 52, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * frac, clockwise: false); g.strokePath()
            g.restoreGState()
        }
        if expression == .asleep && lt < 0.1 && !red {
            let up = Int(now) % 2 == 0
            drawText(g, "z", at: CGPoint(x: c.x + cw / 2 + 18 * s0, y: c.y + (up ? 6 : 18) * s0), size: 58 * s0, weight: .semibold,
                     color: NSColor.white.withAlphaComponent(0.8))
            drawText(g, "z", at: CGPoint(x: c.x + cw / 2 + 64 * s0, y: c.y - (up ? 46 : 30) * s0), size: 80 * s0, weight: .semibold,
                     color: NSColor.white.withAlphaComponent(0.55))
        }
    }

    /// 计时器到点的横幅：顶上一块液态玻璃（夜灯时是暗红），点一下屏幕收起，12 秒后自己收
    private func drawBanner(_ g: CGContext, red: Bool) {
        let r = CGRect(x: 56, y: 56, width: 912, height: 230), rad = Screen.concentric(inset: 56)   // 跟螢幕圓角同心
        if red {
            g.setFillColor(srgb(0x1a0504).cgColor)
            g.addPath(continuousRoundedRect(r, radius: rad)); g.fillPath()
        } else {
            glass(g, r, radius: rad, tint: NSColor(white: 1, alpha: 0.18), band: 14)
        }
        let accent = red ? srgb(0xb3261e) : srgb(0xff9f0a)
        let icon = CGRect(x: r.minX + 44, y: r.midY - 60, width: 120, height: 120)
        g.setFillColor(accent.cgColor)
        g.addPath(continuousRoundedRect(icon, radius: icon.width * 0.2237)); g.fillPath()   // App 圖示的連續圓角比例
        g.setStrokeColor((red ? NSColor.black : NSColor.white).cgColor); g.setLineWidth(9); g.setLineCap(.round)
        g.addArc(center: CGPoint(x: icon.midX, y: icon.midY + 6), radius: 34, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
        g.move(to: CGPoint(x: icon.midX, y: icon.midY + 6)); g.addLine(to: CGPoint(x: icon.midX, y: icon.midY - 16)); g.strokePath()
        let fg = red ? srgb(0xb3261e) : NSColor.white
        drawLeft(g, bannerTexts?.title ?? L("timer.banner.title", "计时器 · 现在"), font: Self.rounded(32, weight: .bold), x: icon.maxX + 34, y: r.minY + 92, color: fg.withAlphaComponent(0.7))
        drawLeft(g, bannerTexts?.big ?? L("timer.banner.done", "时间到了"), font: Self.rounded(64, weight: .bold), x: icon.maxX + 34, y: r.minY + 168, color: fg)
        let df = Self.rounded(30, weight: .semibold), dismiss = L("timer.banner.dismiss", "点一下收起")
        drawLeft(g, dismiss, font: df, x: r.maxX - 44 - Typo.width(dismiss, df), y: r.minY + 168, color: fg.withAlphaComponent(0.6))
    }


    /// 左对齐画一行字，y 是基线（画布左上原点）
    /// kern 為 nil＝照螢幕上的實際字級套 SF 的 trak 字距（Typography.swift）；亮字自動加一點 GRAD
    func drawLeft(_ g: CGContext, _ s: String, font: NSFont, x: CGFloat, y: CGFloat, color: NSColor, kern: CGFloat? = nil) {
        let f = color.isLightInk ? FaceType.graded(font, 440) : font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(f, color: color, kern: kern)))
        g.saveGState(); g.translateBy(x: x, y: y); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g); g.restoreGState()
    }

    /// hello：手写体从左到右「写」出来（裁切框跟着长），写完停一下，再淡出
    private func drawHello(_ g: CGContext, _ t: CGFloat) {
        // 字体：Macintosh Skeletal Filled（npwitk/Macintosh-Skeletal-Filled，个人非商业使用，装在 ~/Library/Fonts，不进仓库）；
        // 没装就退回 Snell Roundhand
        func line(_ size: CGFloat) -> CTLine {
            let font = NSFont(name: "MacintoshSkeletalFilled-Regular", size: size)
                ?? NSFont(name: "SnellRoundhand-Bold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .light)
            return CTLineCreateWithAttributedString(NSAttributedString(string: "hello", attributes: [.font: font, .foregroundColor: NSColor.white]))
        }
        let probe = CTLineGetBoundsWithOptions(line(200), .useGlyphPathBounds)
        let line = line(200 * 700 / max(1, probe.width))          // 写满屏宽的约 70%
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let x0 = 512 - b.width / 2 - b.minX, base: CGFloat = 512 + (b.minY + b.maxY) / 2
        let write = min(1, t / 0.55), fade = t > 0.8 ? (1 - (t - 0.8) / 0.2) : 1
        g.saveGState()
        g.setAlpha(fade)
        g.clip(to: CGRect(x: x0 + b.minX - 20, y: 0, width: (b.width + 40) * write, height: 1024))
        g.setShadow(offset: .zero, blur: 24, color: NSColor(white: 1, alpha: 0.45).cgColor)
        g.translateBy(x: x0, y: base); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
    }

    func drawEye(_ g: CGContext, cx: CGFloat, cy: CGFloat, side: CGFloat, blinkF: CGFloat, k: CGFloat = 1.4) {
        let p = cur
        let rx = p.rx * k, ry = p.ry * k
        guard ry >= 1 else { return }
        let winkEye = expression == .wink && side < 0         // 眨单眼：左眼也画成闭眼
        let lidA: CGFloat = winkEye || expression == .asleep ? 1 : max(0, min(1, (0.6 - blinkF) / 0.35))
        let irisA: CGFloat = winkEye || expression == .asleep ? 0 : max(0, min(1, (blinkF - 0.5) / 0.2))
        let smile = p.smile, ps = winkEye ? 0 : p.ps
        g.saveGState()
        let eye = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        g.addEllipse(in: eye); g.clip()
        g.beginTransparencyLayer(auxiliaryInfo: nil)   // 眼皮在這層裡「切掉」形狀，玻璃／漸層膠囊上才不會露出黑塊
        // 眼白照 Apple Color Emoji 的 👀 取樣：中間純白，沿橢圓邊一圈約 15% 寬的內陰影，
        // 邊上落到 0.58 灰（像枕頭的鼓面），沒有描邊。用縮放過的徑向漸層做成「橢圓等距」的暈。
        let cs = CGColorSpaceCreateDeviceRGB()
        g.setFillColor(NSColor.white.cgColor); g.fill(eye)
        let pillow = CGGradient(colorsSpace: cs, colors: [
            NSColor(white: 1, alpha: 0).cgColor,
            NSColor(white: 0.985, alpha: 0.6).cgColor,
            NSColor(white: 0.90, alpha: 1).cgColor,
            NSColor(white: 0.76, alpha: 1).cgColor,
            NSColor(white: 0.58, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 0.80, 0.89, 0.955, 1])!
        g.saveGState()
        g.translateBy(x: cx, y: cy); g.scaleBy(x: 1, y: ry / rx)
        g.drawRadialGradient(pillow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx * 1.002, options: [.drawsAfterEndLocation])
        g.restoreGState()

        g.setFillColor(NSColor.black.cgColor)
        if ps > 0.02 && irisA > 0.01 {                        // 闭眼时眼珠淡出，换成眼睑线
            g.saveGState()
            g.setAlpha(irisA)
            let look = expression == .idle && glanceEnd == 0 ? faceEyeLook : nil
            let qx = cx + (look?.x ?? p.pdx) * k, qy = cy + (look?.y ?? p.pdy) * k
            if expression == .love {
                g.addPath(heart(qx, qy, 18 * k * ps)); g.fillPath()
                // 心形瞳孔也保留一点眼神光，和别的表情共用同一个「光点」脊柱
                let hr = 3.2 * k * max(0.6, min(1.2, ps))
                g.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                g.fillEllipse(in: CGRect(x: qx - 6 * k * ps - hr, y: qy - 7 * k * ps - hr,
                                         width: hr * 2, height: hr * 2))
                g.setFillColor(NSColor.black.cgColor)
            } else {
                // 👀（照 emoji 取樣）：大瞳孔深棕 #291201 佔虹膜半徑 64%；虹膜環上半是棕、下三分之一轉金（底光），
                // 外緣一圈極細的深棕；只有一顆左上的大高光。
                let ir = max(4, rx * 0.54 * ps)
                let iris = CGRect(x: qx - ir, y: qy - ir, width: ir * 2, height: ir * 2)
                g.saveGState()
                g.addEllipse(in: iris); g.clip()
                let ring = CGGradient(colorsSpace: cs, colors: [
                    srgb(0x5a2a00).cgColor, srgb(0x683900).cgColor, srgb(0x7a4800).cgColor,
                    srgb(0xb78600).cgColor, srgb(0xe2ab00).cgColor, srgb(0xd9a400).cgColor,
                ] as CFArray, locations: [0, 0.42, 0.62, 0.80, 0.92, 1])!
                g.drawLinearGradient(ring, start: CGPoint(x: qx, y: qy - ir), end: CGPoint(x: qx, y: qy + ir), options: [])
                // 環與瞳孔之間有一道更深的棕，瞳孔邊緣微微柔開
                let pr = ir * 0.64
                let pupil = CGGradient(colorsSpace: cs, colors: [
                    srgb(0x291201).cgColor, srgb(0x2b1301).cgColor, srgb(0x3a1a00, 0.95).cgColor, srgb(0x3a1a00, 0).cgColor,
                ] as CFArray, locations: [0, 0.86, 0.94, 1])!
                g.drawRadialGradient(pupil, startCenter: CGPoint(x: qx, y: qy), startRadius: 0,
                                     endCenter: CGPoint(x: qx, y: qy), endRadius: pr * 1.12, options: [])
                g.restoreGState()
                g.setStrokeColor(srgb(0x3c1b00, 0.9).cgColor)
                g.setLineWidth(max(0.8, ir * 0.06))
                g.strokeEllipse(in: iris.insetBy(dx: ir * 0.03, dy: ir * 0.03))
                let hr = ir * 0.30
                let hx = qx - ir * 0.375, hy = qy - ir * 0.56
                g.setFillColor(NSColor.white.cgColor)
                g.fillEllipse(in: CGRect(x: hx - hr, y: hy - hr, width: hr * 2, height: hr * 2))
                g.setFillColor(NSColor.black.cgColor)
            }
            g.restoreGState()
        }
        // 眼皮：绕眼睛中心往外斜（左眼外侧在左），上下各切掉一部分；笑眼用一个椭圆把下缘切成弯月
        // （以前是塗黑，只在黑膠囊上成立；現在用 .clear 把眼睛形狀本身切掉）
        g.translateBy(x: cx, y: cy); g.rotate(by: p.tilt * side)
        g.setBlendMode(.clear)
        let top = p.top + (side < 0 ? p.ltop : 0)
        if top > 0.005 {
            // 上眼睑用一条弯的边（中间低、两侧高），比直切片更像唐老鸭的眼皮；
            // 闭到 85% 以上就退回矩形，免得两侧漏白。
            if top >= 0.85 {
                g.fill(CGRect(x: -rx * 2, y: -ry * 3, width: rx * 4, height: ry * 2 + ry * 2 * top))
            } else {
                let line = -ry + 2 * ry * top
                let w = rx * 2.5, h = max(ry * 0.6, 6)
                g.fillEllipse(in: CGRect(x: -w / 2, y: line - h, width: w, height: h))
                g.fill(CGRect(x: -rx * 2, y: -ry * 3, width: rx * 4, height: line - h / 2 + ry * 3))   // 弧線以上整片切掉，頂端不留白邊
            }
        }
        if p.bot > 0.005 { g.fill(CGRect(x: -rx * 2, y: ry - ry * 2 * p.bot, width: rx * 4, height: ry * 3)) }
        if smile > 0.01 {
            let c = ry * (1.95 - 0.9 * smile)
            g.fillEllipse(in: CGRect(x: -rx * 1.35, y: c - ry * 1.1, width: rx * 2.7, height: ry * 2.2))
        }
        g.setBlendMode(.normal)
        if lidA > 0.01 {
            // 唐老鸭式闭眼：保留白色眼白，只画一条短的下弯眼睑线（和网站同一套比例）。
            g.saveGState()
            g.setAlpha(lidA)
            g.setStrokeColor(NSColor(srgbRed: 0.082, green: 0.094, blue: 0.110, alpha: 1).cgColor)
            g.setLineWidth(max(2, ry * 0.09))
            g.setLineCap(.round)
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: -rx * 0.667, y: ry * 0.192))
            lid.addQuadCurve(to: CGPoint(x: rx * 0.667, y: ry * 0.192), control: CGPoint(x: 0, y: ry * 0.5))
            g.addPath(lid); g.strokePath()
            g.restoreGState()
        }
        g.endTransparencyLayer()
        g.restoreGState()
    }

    func heart(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPath {
        let b = CGMutablePath()
        b.move(to: CGPoint(x: x, y: y + s * 0.9))
        b.addCurve(to: CGPoint(x: x, y: y - s * 0.45), control1: CGPoint(x: x - s * 1.5, y: y - s * 0.1),
                   control2: CGPoint(x: x - s * 0.75, y: y - s * 1.25))
        b.addCurve(to: CGPoint(x: x, y: y + s * 0.9), control1: CGPoint(x: x + s * 0.75, y: y - s * 1.25),
                   control2: CGPoint(x: x + s * 1.5, y: y - s * 0.1))
        b.closeSubpath()
        return b
    }

    /// 圆体（SF Pro Rounded）、等宽数字：錶面数字跳动时不会左右晃
    static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        FaceType.rounded(size, weight)   // 可變軸、中文退回同粗細的蘋方（Faces/Typography.swift）
    }
    /// 放得下就用 size，放不下就缩小（最小到 size × minScale）：卡片上的字要大，换成英文也不能出框
    static func fitted(_ s: String, size: CGFloat, weight: NSFont.Weight, maxWidth: CGFloat, minScale: CGFloat = 0.7) -> NSFont {
        let f = rounded(size, weight: weight)
        let w = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(f))), nil, nil, nil))
        guard w > maxWidth, w > 0 else { return f }
        return rounded(max(size * minScale, (size * maxWidth / w).rounded(.down)), weight: weight)
    }
    static let safeWidth: CGFloat = 944
    /// 水平置中画一行字，y 是基线（画布左上原点）
    func drawCentered(_ g: CGContext, _ s: String, font: NSFont, kern: CGFloat? = nil, y: CGFloat, color: NSColor) {
        let f = color.isLightInk ? FaceType.graded(font, 440) : font
        let a = Typo.attributes(f, color: color, kern: kern == 0 ? nil : kern)   // 0＝舊呼叫的「不加」：改成照實際字級
        let attr = NSAttributedString(string: s, attributes: a)
        let line = CTLineCreateWithAttributedString(attr)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - ((a[.kern] as? CGFloat) ?? 0)   // 最後一字後面的字距不算
        // 太寬（大字號時鐘、德文日期）就以基線中點等比縮進螢幕安全寬度，不會被圓角裁掉
        let k = w > Self.safeWidth ? Self.safeWidth / w : 1
        g.saveGState()
        g.translateBy(x: 512, y: y); g.scaleBy(x: k, y: -k); g.translateBy(x: -w / 2, y: 0)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
    }

    func drawText(_ g: CGContext, _ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attr = NSAttributedString(string: s, attributes: Typo.attributes(FaceType.sf(size, weight, mono: false), color: color))
        let line = CTLineCreateWithAttributedString(attr)
        g.saveGState()
        // 坐标系已翻成左上原点；文字要再翻回来，基线在 p.y
        g.translateBy(x: p.x, y: p.y); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero
        CTLineDraw(line, g)
        g.restoreGState()
    }
}
