// 2.0 App 圖示的退路：第四輪起內建 App 全部是 HPIcons（Design/HPIcons.swift）自己畫的，不再讀系統 App 的圖示；
// 這裡只剩「還沒有自畫圖示的新 App」用的同一套：漸層底、白色符號、頂端亮邊。

import AppKit

enum AppIconArt {
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]

    /// 系統 App 圖示裁掉 macOS 的留白與陰影，只留圓角方塊本體（px 是輸出邊長）
    static func systemIcon(_ path: String, px: Int) -> CGImage? {
        let key = "\(path)|\(px)"
        if let c = cache[key] { return c }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        let canvas = 1024
        var rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
        guard let full = icon.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform()]) else { return nil }
        // 本體範圍：alpha 過半的外框（陰影很淡，不會算進去）
        let body = opaqueBounds(full) ?? CGRect(x: 100, y: 100, width: 824, height: 824)
        guard let crop = full.cropping(to: body) else { return nil }
        let out = makeImage(px, px) { g in
            g.interpolationQuality = .high
            let r = CGRect(x: 0, y: 0, width: px, height: px)
            g.addPath(continuousRoundedRect(r, radius: CGFloat(px) * 0.2237)); g.clip()
            g.draw(crop, in: r.insetBy(dx: -CGFloat(px) * 0.004, dy: -CGFloat(px) * 0.004))
        }
        cache[key] = out
        return out
    }

    /// alpha > 0.5 的外框（CGImage 像素座標，左上原點）
    static func opaqueBounds(_ img: CGImage) -> CGRect? {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in stride(from: 0, to: h, by: 2) {
            let row = y * w
            for x in stride(from: 0, to: w, by: 2) where data[row + x] > 128 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        // 點陣記憶體第一列是圖的上緣，跟 cropping(to:) 一樣是左上原點
        return CGRect(x: minX, y: minY, width: maxX - minX + 2, height: maxY - minY + 2)
    }

    /// 自畫的圖示：上亮下暗的漸層、白色符號帶一點投影、頂緣一圈亮邊（Liquid Glass 圖示的光）
    static func drawGlassy(_ g: CGContext, face: Face, icon: AppIcon, in r: CGRect) {
        let path = continuousRoundedRect(r, radius: r.width * 0.2237)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (icon.color.usingColorSpace(.sRGB) ?? icon.color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let top = NSColor(hue: h, saturation: s * 0.82, brightness: min(1, b * 1.12 + 0.04), alpha: 1)
        let bottom = NSColor(hue: h, saturation: min(1, s * 1.05), brightness: b * 0.86, alpha: 1)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        g.saveGState(); g.addPath(path); g.clip()
        let grad = CGGradient(colorsSpace: cs, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        g.restoreGState()
        // 亮邊：沿輪廓一圈，上緣最亮、往下淡掉
        g.saveGState()
        g.addPath(path); g.setLineWidth(max(1.5, r.width * 0.018)); g.replacePathWithStrokedPath(); g.clip()
        let rim = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0.05).cgColor,
                                                       NSColor(white: 1, alpha: 0.18).cgColor] as CFArray, locations: [0, 0.55, 1])!
        g.drawLinearGradient(rim, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: r.height * 0.012), blur: r.height * 0.04, color: NSColor(white: 0, alpha: 0.22).cgColor)
        face.drawSymbol(g, icon.symbol, in: r.insetBy(dx: r.width * 0.2, dy: r.height * 0.2), color: icon.glyph)
        g.restoreGState()
    }
}
