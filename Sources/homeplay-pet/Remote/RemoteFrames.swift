// 2.0 閒置裝置·網頁串流：把 1024² 的畫面變成「只有變了的區塊」的 JPEG。
// 每台裝置記著它手上那張（ref）：跟這一幀逐格（64 px）比，變了的格子併成矩形，各自壓成 JPEG；
// 變了超過一半就整張送。靜止的畫面一個 byte 都不送。全部在 RemoteServer 的背景佇列跑，不碰主執行緒。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 背景佇列專用的 1024² 畫布（RGBA8、sRGB、黑底）：桌寵的那一幀不管幾倍解析度，都縮放畫進來
final class RemoteCanvas {
    static let size = 1024
    static let tile = 64
    let ctx: CGContext
    let bytesPerRow: Int
    var pixels: UnsafeMutablePointer<UInt8> { ctx.data!.assumingMemoryBound(to: UInt8.self) }
    var count: Int { bytesPerRow * Self.size }
    /// 第幾張（每畫進一張新的就 +1）
    private(set) var generation = 0

    init() {
        ctx = CGContext(data: nil, width: Self.size, height: Self.size, bitsPerComponent: 8, bytesPerRow: Self.size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bytesPerRow = ctx.bytesPerRow
        ctx.interpolationQuality = .high
        clear()
    }

    func clear() {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
    }

    /// 最近畫進來的那一幀是不是在「可以給訪客看」的時候畫的（H1：訪客只拿得到 safe 的幀）
    private(set) var safe = false
    /// 最近一張 safe 的幀是第幾張
    private(set) var safeGen = 0

    func draw(_ img: CGImage, safe: Bool = false) {
        clear()
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        generation += 1
        self.safe = safe
        if safe { safeGen = generation }
    }

    func snapshot() -> [UInt8] { Array(UnsafeBufferPointer(start: pixels, count: count)) }

    func image() -> CGImage? { ctx.makeImage() }
}

enum RemoteFrames {
    /// 變了的矩形（像素、左上原點）。ref＝nil：整張
    static func dirtyRects(_ cur: UnsafePointer<UInt8>, _ ref: UnsafePointer<UInt8>?, size: Int = RemoteCanvas.size,
                           tile: Int = RemoteCanvas.tile, bytesPerRow: Int? = nil) -> [CGRect] {
        let bpr = bytesPerRow ?? size * 4, n = size / tile
        guard let ref else { return [CGRect(x: 0, y: 0, width: size, height: size)] }
        var dirty = [Bool](repeating: false, count: n * n), total = 0
        for ty in 0..<n {
            for tx in 0..<n {
                let x0 = tx * tile * 4
                var changed = false
                for y in (ty * tile)..<((ty + 1) * tile) where memcmp(cur + y * bpr + x0, ref + y * bpr + x0, tile * 4) != 0 { changed = true; break }
                if changed { dirty[ty * n + tx] = true; total += 1 }
            }
        }
        if total == 0 { return [] }
        if total * 2 > n * n { return [CGRect(x: 0, y: 0, width: size, height: size)] }
        // 每一列併成連續的段；上下兩列同樣的段再往下延長
        var open: [(x0: Int, x1: Int, y0: Int, y1: Int)] = [], done: [CGRect] = []
        for ty in 0..<n {
            var runs: [(Int, Int)] = [], tx = 0
            while tx < n {
                if dirty[ty * n + tx] { let s = tx; while tx < n && dirty[ty * n + tx] { tx += 1 }; runs.append((s, tx)) } else { tx += 1 }
            }
            var next: [(x0: Int, x1: Int, y0: Int, y1: Int)] = []
            for r in runs {
                if let i = open.firstIndex(where: { $0.x0 == r.0 && $0.x1 == r.1 && $0.y1 == ty }) {
                    var o = open.remove(at: i); o.y1 = ty + 1; next.append(o)
                } else { next.append((r.0, r.1, ty, ty + 1)) }
            }
            for o in open { done.append(CGRect(x: o.x0 * tile, y: o.y0 * tile, width: (o.x1 - o.x0) * tile, height: (o.y1 - o.y0) * tile)) }
            open = next
        }
        for o in open { done.append(CGRect(x: o.x0 * tile, y: o.y0 * tile, width: (o.x1 - o.x0) * tile, height: (o.y1 - o.y0) * tile)) }
        return done
    }

    static func jpeg(_ img: CGImage, quality: Double = 0.8) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }

    /// 'F' seq(u32) inputAck(u32) n(u16) 然後每塊 x y w h(u16) len(u32) jpeg；全部小端
    static func message(seq: UInt32, inputAck: UInt32, parts: [(CGRect, Data)]) -> Data {
        var d = Data([0x46])
        func u16(_ v: Int) { d.append(UInt8(v & 255)); d.append(UInt8((v >> 8) & 255)) }
        func u32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 255)) } }
        u32(seq); u32(inputAck); u16(parts.count)
        for (r, j) in parts {
            u16(Int(r.minX)); u16(Int(r.minY)); u16(Int(r.width)); u16(Int(r.height)); u32(UInt32(j.count)); d.append(j)
        }
        return d
    }
}
