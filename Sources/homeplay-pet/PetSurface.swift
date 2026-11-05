// 視窗比例、畫布影像工具與螢幕網格法線（Surface）——自 main.swift 拆出（對齊 main 線拆分）。
import Accelerate
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

enum Pet {
    static let standAspect: CGFloat = 0.82   // 宽 / 高：整机（底座＋屏幕）
    static let wallAspect: CGFloat = 1 / 1.06 // 挂墙：只有屏幕模组，近正方，高＝宽＋一点边
    /// 目前的窗口比例：跟着朝向模式换（启动时、切换挂墙时设）
    nonisolated(unsafe) static var aspect: CGFloat = standAspect
    static func aspect(for mode: ViewMode) -> CGFloat { mode == .wall ? wallAspect : standAspect }
    static let defaultWidth: CGFloat = 220
    static let minWidth: CGFloat = 130
    static let maxWidth: CGFloat = 900
}

/// 记住窗口位置与宽度（UserDefaults HomePlayWindowFrame＝[x, y, 宽]）；高度由宽度和比例算出
enum WindowFrameStore {
    static let key = "HomePlayWindowFrame"
    static func save(_ f: NSRect) {
        UserDefaults.standard.set([f.minX, f.minY, f.width].map(Double.init), forKey: key)
    }
    static func load() -> [Double]? { UserDefaults.standard.array(forKey: key) as? [Double] }
    /// 存的框和某块屏的可见区有交集才还原，并钳进那块屏；完全在屏外（拔了外接显示器）就放弃，走默认位置
    static func restore(_ saved: [Double]?, visible: [CGRect]) -> NSRect? {
        guard let s = saved, s.count == 3, s.allSatisfy(\.isFinite) else { return nil }
        let w = max(Pet.minWidth, min(Pet.maxWidth, CGFloat(s[2]))), h = w / Pet.aspect
        let r = NSRect(x: s[0], y: s[1], width: w, height: h)
        func area(_ v: CGRect) -> CGFloat { let i = r.intersection(v); return i.isNull ? 0 : i.width * i.height }
        guard let vf = visible.max(by: { area($0) < area($1) }), area(vf) > 0 else { return nil }
        return NSRect(x: max(vf.minX, min(r.minX, vf.maxX - w)), y: max(vf.minY, min(r.minY, vf.maxY - h)), width: w, height: h)
    }
}

// MARK: - 画布小工具

func makeImage(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 左上原点，跟稿里的 canvas 一样
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

// MARK: - 法线贴图：表面细节（噴砂铝的颗粒、网孔的凹陷），让灯光在表面上碎开，才不像 CG

/// 由高度场做切线空间法线贴图（可平铺：边界绕回去取样）。strength 越大越凹凸。
func normalMap(_ w: Int, _ h: Int, strength: CGFloat, height: [CGFloat]) -> CGImage {
    var px = [UInt8](repeating: 255, count: w * h * 4)
    func hh(_ x: Int, _ y: Int) -> CGFloat { height[((y + h) % h) * w + (x + w) % w] }
    for y in 0..<h { for x in 0..<w {
        let dx = (hh(x + 1, y) - hh(x - 1, y)) * strength, dy = (hh(x, y + 1) - hh(x, y - 1)) * strength
        let l = sqrt(dx * dx + dy * dy + 1)
        let i = (y * w + x) * 4
        px[i] = UInt8(max(0, min(255, (-dx / l * 0.5 + 0.5) * 255)))
        px[i + 1] = UInt8(max(0, min(255, (dy / l * 0.5 + 0.5) * 255)))
        px[i + 2] = UInt8(max(0, min(255, (1 / l * 0.5 + 0.5) * 255)))
    } }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}

enum Surface {
    /// 噴砂铝：细密的随机颗粒（3×3 平滑过的白噪声）
    static let beadBlast: CGImage = {
        let n = 256
        var g = SystemRandomNumberGenerator()
        let raw = (0..<(n * n)).map { _ in CGFloat(Double.random(in: 0...1, using: &g)) }
        var sm = raw
        for y in 0..<n { for x in 0..<n {
            var a: CGFloat = 0
            for j in -1...1 { for i in -1...1 { a += raw[((y + j + n) % n) * n + (x + i + n) % n] } }
            sm[y * n + x] = a / 9
        } }
        return normalMap(n, n, strength: 2.2, height: sm)
    }()
    /// 网孔：和 grilleImg 同一套错位孔阵，孔里凹下去、孔边是圆的
    static let grilleHoles: CGImage = {
        let w = 1024, h = 128
        var hgt = [CGFloat](repeating: 1, count: w * h)
        for row in 0..<11 { for col in 0..<62 {
            let cx = 16 + CGFloat(col) * 16 + (row % 2 == 1 ? 8 : 0), cy = 9 + CGFloat(row) * 11.2
            for y in max(0, Int(cy) - 5)...min(h - 1, Int(cy) + 5) { for x in Int(cx) - 5...Int(cx) + 5 {
                let d = hypot(CGFloat(x) - cx, CGFloat(y) - cy)
                let v = max(0, min(1, (d - 1.8) / 1.8))
                let xi = (x + w) % w
                hgt[y * w + xi] = min(hgt[y * w + xi], v)
            } }
        } }
        return normalMap(w, h, strength: 1.8, height: hgt)
    }()
    // MARK: 高清冲孔网罩（覆盖 USDZ 的低模孔）
    // 官方图的孔是干净圆孔、深黑内腔、细亮孔缘。USDZ 的孔是低模多边形，近看会发灰、锯齿。
    // 这里在 USDZ 网罩外叠一层 2048×512 的冲孔面：孔透明→露出黑腔；孔缘用 normal 做倒角高光。
    static let perfW = 2048, perfH = 512
    static let perfCols = 128, perfRows = 16
    static let perfBandH: CGFloat = 2.52
    static let perfCircum: CGFloat = 2 * .pi * 4.16
    static let perfHoleD: CGFloat = 0.07          // cm，真实孔径
    private static let perfCenters: [(CGFloat, CGFloat)] = {
        (0..<perfRows).flatMap { row in
            (0..<perfCols).map { col in
                let x = (CGFloat(col) + 0.5) * CGFloat(perfW) / CGFloat(perfCols)
                    + (row % 2 == 1 ? CGFloat(perfW) / CGFloat(perfCols) / 2 : 0)
                let y = CGFloat(perfH) * (0.05 + 0.90 * CGFloat(row) / CGFloat(perfRows - 1))
                return (x, y)
            }
        }
    }()
    private static var perfRx: CGFloat { (perfHoleD / 2) / perfCircum * CGFloat(perfW) }
    private static var perfRy: CGFloat { (perfHoleD / 2) / perfBandH * CGFloat(perfH) }
    /// 白底 + 透明孔（乘配色）、黑腔（带 USB-C 开孔）、孔缘倒角法线
    static let perforatedGrille: (diffuse: CGImage, backing: CGImage, normal: CGImage) = {
        let W = perfW, H = perfH, rx = perfRx, ry = perfRy
        func drawHoles(_ g: CGContext, clear: Bool) {
            if clear { g.setBlendMode(.clear) }
            for (cx0, cy) in perfCenters {
                for dx: CGFloat in [0, -CGFloat(W), CGFloat(W)] {
                    let cx = cx0 + dx
                    g.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
                }
            }
            if clear { g.setBlendMode(.normal) }
        }
        let diffuse = makeImage(W, H) { g in
            g.setFillColor(NSColor.white.cgColor); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
            drawHoles(g, clear: true)
            // 上下分模线
            g.setFillColor(srgb(0x4a4a4a).cgColor)
            g.fill(CGRect(x: 0, y: 2, width: W, height: 3))
            g.fill(CGRect(x: 0, y: H - 5, width: W, height: 3))
        }
        let backing = makeImage(W, H) { g in
            g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        var hgt = [CGFloat](repeating: 1, count: W * H)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<hgt.count { hgt[i] = 1 + CGFloat.random(in: -0.012...0.012, using: &rng) }
        for (cx0, cy) in perfCenters {
            for dx: CGFloat in [0, -CGFloat(W), CGFloat(W)] {
                let cx = cx0 + dx
                let x0 = max(0, Int(cx - rx * 1.5)), x1 = min(W - 1, Int(cx + rx * 1.5))
                let y0 = max(0, Int(cy - ry * 1.5)), y1 = min(H - 1, Int(cy + ry * 1.5))
                if x0 > x1 || y0 > y1 { continue }
                for y in y0...y1 { for x in x0...x1 {
                    let q = hypot((CGFloat(x) - cx) / rx, (CGFloat(y) - cy) / ry)
                    guard q > 1 else { hgt[y * W + x] = 0; continue }
                    guard q < 1.45 else { continue }
                    let v = (q - 1) / 0.45
                    let i = y * W + x
                    hgt[i] = min(hgt[i], v)
                } }
            }
        }
        let normal = normalMap(W, H, strength: 1.25, height: hgt)
        return (diffuse, backing, normal)
    }()

    /// 背部 USB-C：镀铬小胶囊 + 深色内槽，画在贴合弧面的曲面上（背景透明，网面从四周透出来）
    static let usbcPort: CGImage = {
        let w = 512, h = 224
        return makeImage(w, h) { g in
            let outer = CGRect(x: 68, y: 54, width: 376, height: 116)
            let outerPath = CGPath(roundedRect: outer, cornerWidth: 44, cornerHeight: 44, transform: nil)
            // 柔和的落地阴影：让它读起来是凹进去的，而不是贴纸
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: 4), blur: 8,
                        color: NSColor.black.withAlphaComponent(0.30).cgColor)
            g.addPath(outerPath)
            g.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
            g.fillPath()
            g.restoreGState()
            // 镀铬边：上亮、中暗、下再提亮，像一圈抛光金属
            g.saveGState()
            g.addPath(outerPath); g.clip()
            let chrome = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                NSColor(white: 0.90, alpha: 1).cgColor,
                NSColor(white: 0.60, alpha: 1).cgColor,
                NSColor(white: 0.82, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 0.60, 1])!
            g.drawLinearGradient(chrome, start: CGPoint(x: 0, y: outer.minY),
                                 end: CGPoint(x: 0, y: outer.maxY), options: [])
            g.restoreGState()
            // 外圈一道细暗边，把镀铬边和网面分开
            g.saveGState()
            g.addPath(outerPath)
            g.setStrokeColor(NSColor(white: 0.18, alpha: 0.55).cgColor)
            g.setLineWidth(2); g.strokePath()
            g.restoreGState()
            // 内槽：USB-C 的 8.4×2.6 mm 比例，圆角接近胶囊
            let slot = CGRect(x: 104, y: 64, width: 304, height: 95)
            let slotPath = CGPath(roundedRect: slot, cornerWidth: 46, cornerHeight: 46, transform: nil)
            g.saveGState()
            g.addPath(slotPath); g.clip()
            let inner = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                NSColor(white: 0.02, alpha: 1).cgColor,
                NSColor(white: 0.10, alpha: 1).cgColor,
                NSColor(white: 0.05, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 0.72, 1])!
            g.drawLinearGradient(inner, start: CGPoint(x: 0, y: slot.minY),
                                 end: CGPoint(x: 0, y: slot.maxY), options: [])
            g.restoreGState()
            // 内槽边缘：上沿压暗、下沿留一条细高光，深度就出来了
            g.saveGState()
            g.addPath(slotPath)
            g.setStrokeColor(NSColor(white: 0.22, alpha: 0.9).cgColor)
            g.setLineWidth(2.5); g.strokePath()
            g.setStrokeColor(NSColor(white: 0.55, alpha: 0.45).cgColor)
            g.setLineWidth(1.5)
            g.move(to: CGPoint(x: slot.minX + 34, y: slot.minY + 7))
            g.addLine(to: CGPoint(x: slot.maxX - 34, y: slot.minY + 7))
            g.strokePath()
            g.restoreGState()
            // 镀铬边顶部一道锐高光
            g.saveGState()
            let glint = CGRect(x: outer.minX + 30, y: outer.minY + 4, width: outer.width - 60, height: 3)
            g.addPath(CGPath(roundedRect: glint, cornerWidth: 2, cornerHeight: 2, transform: nil))
            g.setFillColor(NSColor(white: 1, alpha: 0.55).cgColor)
            g.fillPath()
            g.restoreGState()
        }
    }()
}

// MARK: - 脸（岛的表情）：十个表情都是同一套几何的变形
//
// 参数照设计稿「HomeView 表情稿」（docs/design-drafts/桌寵表情與行為.html）：1024 画布、×1.4 之前的原值。
// 只动眼睛：眼白半径、上下眼皮遮住的比例、眼皮斜角、笑眼弯月、眼珠位移与缩放、胶囊宽高；不加嘴、不换画风。

