// CarPlay 主畫面上的 HomePlay 圖示（Liquid Glass 語言）。
// 用法：swiftc -O tooling/make-carplay-icon.swift -o /tmp/mkicon && /tmp/mkicon
// 輸出 assets/icon/CarPlayIcon-{120,180,256}.png（滿版方圖，CarPlay 自己套圓角）。
//
// 分層：
// 1. 底：晨昏漸層（同 App 圖示），左上一團冷光、右下一團暖光；
// 2. 眼睛：直接搬桌寵螢幕上 👀 的畫法與參數（眼白球面、灰邊、琥珀虹膜、往左下看、兩個高光），
//    圖示和產品裡的眼睛一模一樣；眼下一層柔影讓它浮在底上。
import AppKit
import CoreImage

let N: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func context() -> CGContext {
    let c = CGContext(data: nil, width: Int(N), height: Int(N), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}
func linear(_ c: CGContext, _ stops: [(CGFloat, CGColor)], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ c: CGContext, _ stops: [(CGFloat, CGColor)], at p: CGPoint, r: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
}
func blur(_ img: CGImage, _ r: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: CGRect(x: 0, y: 0, width: N, height: N))
    return CIContext().createCGImage(ci, from: ci.extent)!
}

// ── 1. 底 ──（CoreGraphics 原點在左下）
let bgCtx = context()
linear(bgCtx, [(0, rgba(0x4A5784)), (0.48, rgba(0x8C7A9C)), (1, rgba(0xE4B48C))], from: CGPoint(x: 0, y: N), to: CGPoint(x: 0, y: 0))
radial(bgCtx, [(0, rgba(0xBFD3FF, 0.45)), (1, rgba(0xBFD3FF, 0))], at: CGPoint(x: N * 0.18, y: N * 0.86), r: N * 0.62)
radial(bgCtx, [(0, rgba(0xFFC08A, 0.40)), (1, rgba(0xFFC08A, 0))], at: CGPoint(x: N * 0.86, y: N * 0.10), r: N * 0.58)
let background = bgCtx.makeImage()!

// ── 2–3. 眼睛：和桌宠屏幕上的 👀 同一套画法与参数（main.swift FaceParams 默认值、drawEye）──
// rx 31、ry 50、两眼中心离中线 36；虹膜半径 0.54·rx；瞳孔往左下看（pdx −13、pdy +6，屏幕坐标 y 朝下）。
let out = context()
out.draw(background, in: CGRect(x: 0, y: 0, width: N, height: N))
let cgs = CGColorSpaceCreateDeviceRGB()
func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cgs, colors: cols as CFArray, locations: locs)! }
func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

let k: CGFloat = 4.6                       // 产品参数 → 1024 画布：两只眼睛合起来约占 62% 宽
let rx = 31 * k, ry = 50 * k, sep = 36 * k
let cy = N / 2
for side in [-1.0, 1.0] as [CGFloat] {
    let cx = N / 2 + side * sep
    let eye = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
    // 眼下一层柔影：让它浮在背景上（Liquid Glass 的层次）
    out.saveGState()
    out.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgba(0x2A1E3A, 0.40))
    out.setFillColor(rgba(0xFFFFFF)); out.fillEllipse(in: eye)
    out.restoreGState()

    out.saveGState()
    out.addEllipse(in: eye); out.clip()
    // 眼白：左上亮、右下带冷灰（球面感）。屏幕坐标的「左上」在这里是 y 朝上 → 光点在中心上方
    let light = CGPoint(x: cx - rx * 0.22, y: cy + ry * 0.38)
    out.drawRadialGradient(grad([srgb(1, 1, 1), srgb(0.972, 0.976, 0.982), srgb(0.790, 0.812, 0.838)], [0, 0.62, 1]),
                           startCenter: light, startRadius: 0, endCenter: light, endRadius: max(rx, ry) * 1.22, options: [.drawsAfterEndLocation])
    // 一圈很柔的灰边：像玻璃球，不像白纸片
    let ec = CGPoint(x: cx, y: cy)
    out.drawRadialGradient(grad([srgb(0.55, 0.57, 0.60, 0), srgb(0.55, 0.57, 0.60, 0.20)], [0.72, 1]),
                           startCenter: ec, startRadius: min(rx, ry) * 0.52, endCenter: ec, endRadius: max(rx, ry) * 1.06, options: [.drawsAfterEndLocation])
    out.setStrokeColor(srgb(0.43, 0.45, 0.48, 0.22)); out.setLineWidth(1.1 * k)
    out.strokeEllipse(in: eye.insetBy(dx: 0.5 * k, dy: 0.5 * k))

    // 虹膜：深棕瞳孔 → 琥珀环 → 深色外缘
    let qx = cx - 13 * k, qy = cy - 6 * k
    let ir = rx * 0.54
    let iris = CGRect(x: qx - ir, y: qy - ir, width: ir * 2, height: ir * 2)
    out.saveGState()
    out.addEllipse(in: iris); out.clip()
    out.drawRadialGradient(grad([srgb(0.10, 0.055, 0.020), srgb(0.16, 0.080, 0.025), srgb(0.30, 0.16, 0.030), srgb(0.58, 0.34, 0.035),
                                 srgb(0.82, 0.52, 0.045), srgb(0.94, 0.66, 0.070), srgb(0.30, 0.17, 0.030)], [0, 0.50, 0.68, 0.80, 0.88, 0.94, 1]),
                           startCenter: CGPoint(x: qx, y: qy), startRadius: 0, endCenter: CGPoint(x: qx, y: qy), endRadius: ir, options: [])
    // 上半圈压一点深棕：像受光的虹膜
    out.drawLinearGradient(grad([srgb(0.12, 0.065, 0.025, 0.28), srgb(0.12, 0.065, 0.025, 0)], [0, 1]),
                           start: CGPoint(x: qx, y: qy + ir), end: CGPoint(x: qx, y: qy - ir), options: [])
    out.restoreGState()
    out.setStrokeColor(srgb(0.20, 0.115, 0.030, 0.92)); out.setLineWidth(ir * 0.08)
    out.strokeEllipse(in: iris.insetBy(dx: ir * 0.04, dy: ir * 0.04))
    // 左上主高光＋右下小反光
    let hr = ir * 0.255, hx = qx - ir * 0.38, hy = qy + ir * 0.40
    out.setFillColor(srgb(1, 1, 1, 0.16)); out.fillEllipse(in: CGRect(x: hx - hr * 1.25, y: hy - hr * 1.25, width: hr * 2.5, height: hr * 2.5))
    out.setFillColor(srgb(1, 1, 1, 0.97)); out.fillEllipse(in: CGRect(x: hx - hr, y: hy - hr, width: hr * 2, height: hr * 2))
    let sr = ir * 0.085
    out.setFillColor(srgb(1, 1, 1, 0.40)); out.fillEllipse(in: CGRect(x: qx + ir * 0.40 - sr, y: qy - ir * 0.38 - sr, width: sr * 2, height: sr * 2))
    out.restoreGState()
}

let master = out.makeImage()!
let dir = URL(fileURLWithPath: "assets/icon")
func write(_ img: CGImage, _ size: Int, _ name: String) {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}
for s in [120, 180, 256] { write(master, s, "CarPlayIcon-\(s).png") }
print("ok")
