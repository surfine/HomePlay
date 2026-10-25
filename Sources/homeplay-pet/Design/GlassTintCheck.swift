// 2.0 tint：染色玻璃走真的系統層樹時的自檢——畫一顆染色圓鈕，讀中心點的色相與飽和度。
// 以前灰掉的原因與修法見 Faces/SystemGlassNative.swift 的「染色」一節。

import AppKit
import QuartzCore

enum GlassTintCheck {
    /// 圖裡某一點（第一列是上緣）的 sRGB 0…1
    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let d = ctx.data else { return (0, 0, 0) }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        let p = d.assumingMemoryBound(to: UInt8.self)
        return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
    }
    /// 色相（度）與飽和度（HSV）
    static func hueSat(_ c: (r: Double, g: Double, b: Double)) -> (hue: Double, sat: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 1e-6 else { return (0, 0) }
        var h: Double
        if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) } else if mx == c.g { h = (c.b - c.r) / d + 2 } else { h = (c.r - c.g) / d + 4 }
        h *= 60; if h < 0 { h += 360 }
        return (h, d / max(mx, 1e-6))
    }

    static func selftest(_ check: (Bool, String) -> Void) {
        check(NativeGlass.shared.available, "glass tint：有 NSGlassEffectView（macOS 26 以上）")   // l10n-ignore（自檢訊息）
        _ = NSApplication.shared
        // 系統在作用中視窗算的染色矩陣＝iOS 27 模擬器量到的藍（校準樣本）
        let blue = NativeGlass.activeTintMatrix(NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1), clear: false, dark: false)
        check(blue.map { abs($0[9] - 0.2513) < 0.01 && abs($0[14] - 0.6) < 0.01 } == true, "glass tint：系統染色矩陣（作用中）＝iOS 實測的藍")   // l10n-ignore（自檢訊息）
        // 真的走 NativeGlass.render（同一套層樹畫兩次，中間讓 run loop 跑一下，像 App 每幀之間）
        let tints: [(String, NSColor)] = [("orange", HPTokens.orange), ("red", HPTokens.red), ("green", HPTokens.green)]
        for plat in [HPGlassPlatform.iOS] {
            for dark in [true, false] {
                let bg = makeImage(1024, 1024) { g in g.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
                for (name, t) in tints {
                    let q = NativeGlass.Request(shapes: [NativeGlass.Shape(rect: CGRect(x: 437, y: 437, width: 150, height: 150), radius: 75, continuous: false)],
                                                clear: false, dark: dark, tint: t, press: 1, presence: 1, scale: 1, platform: plat)
                    let want = hueSat((Double(t.redComponent), Double(t.greenComponent), Double(t.blueComponent)))
                    var ok = true, got = "nil"
                    for pass in 0..<2 {
                        guard let r = NativeGlass.shared.render(q, backdrop: bg) else { ok = false; break }
                        let c = pixel(r.image, 512 - Int(r.rect.minX), 512 - Int(r.rect.minY))
                        let hs = hueSat(c)
                        var dh = abs(hs.hue - want.hue); dh = min(dh, 360 - dh)
                        got = String(format: "%.2f,%.2f,%.2f hue %.0f sat %.2f", c.r, c.g, c.b, hs.hue, hs.sat)
                        if dh > 12 || hs.sat < 0.5 { ok = false }
                        if pass == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                    }
                    check(ok, "glass tint：\(plat) \(dark ? "深" : "淺") \(name) 的中心有色（\(got)）")   // l10n-ignore（自檢訊息）
                }
            }
        }
    }
}
