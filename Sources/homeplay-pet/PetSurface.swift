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

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// MARK: - 窗口比例

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
