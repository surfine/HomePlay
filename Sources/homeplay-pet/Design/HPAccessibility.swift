// 2.0 glass（P01）：輔助使用設定——減少透明度、增加對比——與 WCAG 對比計算。
//
// 讀 NSWorkspace.accessibilityDisplayShouldReduceTransparency／accessibilityDisplayShouldIncreaseContrast，
// 監聽 accessibilityDisplayOptionsDidChangeNotification（改了就清玻璃快取、generation 加一，下一幀照新設定畫）。
// HOMEPLAY_REDUCE_TRANSPARENCY=1／HOMEPLAY_INCREASE_CONTRAST=1 在快照裡強制打開（照 HOMEPLAY_REDUCE_MOTION 的作法）。
// 用到的地方：HPGlass.flush（減少透明度＝霧面不透明、沒有折射；增加對比＝label 色描邊）、HPTokens（高對比系統色、次要字 80%）。

import AppKit

enum HPAccessibility {
    private static let env = ProcessInfo.processInfo.environment
    nonisolated(unsafe) static var forceReduceTransparency: Bool? = env["HOMEPLAY_REDUCE_TRANSPARENCY"].map { $0 == "1" }
    nonisolated(unsafe) static var forceIncreaseContrast: Bool? = env["HOMEPLAY_INCREASE_CONTRAST"].map { $0 == "1" }
    /// 設定改過幾次（快取的 key 可以帶它）
    nonisolated(unsafe) private(set) static var generation = 0
    nonisolated(unsafe) private static var cached: (rt: Bool, ic: Bool)?

    private static let observer: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            cached = nil; generation += 1
            HPGlass.discardCache()
        }

    private static var values: (rt: Bool, ic: Bool) {
        _ = observer
        if let c = cached { return c }
        let ws = NSWorkspace.shared
        let v = (ws.accessibilityDisplayShouldReduceTransparency, ws.accessibilityDisplayShouldIncreaseContrast)
        cached = v
        return v
    }
    /// 減少透明度：玻璃改畫霧面不透明（`HPGlass.Variant.identity`）
    static var reduceTransparency: Bool { forceReduceTransparency ?? values.rt }
    /// 增加對比：玻璃與膠囊加 label 色描邊、次要字 80%、系統色換高對比版
    static var increaseContrast: Bool { forceIncreaseContrast ?? values.ic }

    // MARK: WCAG 2.x 對比

    /// 相對亮度（sRGB → 線性）
    static func luminance(_ c: NSColor) -> Double {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }
    /// 前景（可以半透明）疊在不透明的底上的對比
    static func contrast(_ fg: NSColor, on bg: NSColor) -> Double {
        guard let f = fg.usingColorSpace(.sRGB), let b = bg.usingColorSpace(.sRGB) else { return 1 }
        let a = f.alphaComponent
        let mix = NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a), green: f.greenComponent * a + b.greenComponent * (1 - a),
                          blue: f.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
        let l1 = luminance(mix), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// selftest：文字 ≥ 4.5:1、大字與 UI ≥ 3:1（WCAG 1.4.3／1.4.11）
enum HPAccessibilitySelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let oldDark = HPTokens.dark, oldIC = HPAccessibility.forceIncreaseContrast
        defer { HPTokens.dark = oldDark; HPAccessibility.forceIncreaseContrast = oldIC }
        for dark in [false, true] {
            HPTokens.dark = dark
            let side = dark ? "dark" : "light"
            HPAccessibility.forceIncreaseContrast = false
            check(HPAccessibility.contrast(HPTokens.label, on: HPTokens.bg) >= 4.5 && HPAccessibility.contrast(HPTokens.label, on: HPTokens.card) >= 4.5, "a11y：\(side) label 對底 ≥ 4.5")
            check(HPAccessibility.contrast(HPTokens.secondary, on: HPTokens.card) >= 3, "a11y：\(side) 次要字對卡 ≥ 3（大字）")
            HPAccessibility.forceIncreaseContrast = true
            let sec = HPAccessibility.contrast(HPTokens.secondary, on: HPTokens.bg) >= 4.5 && HPAccessibility.contrast(HPTokens.secondary, on: HPTokens.card) >= 4.5
            check(sec, "a11y：\(side) 增加對比的次要字 ≥ 4.5")
            let colors: [(String, NSColor)] = [("red", HPTokens.red), ("orange", HPTokens.orange), ("yellow", HPTokens.yellow), ("green", HPTokens.green),
                                               ("blue", HPTokens.blue), ("purple", HPTokens.purple), ("mint", HPTokens.mint), ("teal", HPTokens.teal),
                                               ("cyan", HPTokens.cyan), ("indigo", HPTokens.indigo), ("pink", HPTokens.pink), ("brown", HPTokens.brown)]
            let bad = colors.filter { HPAccessibility.contrast($0.1, on: HPTokens.card) < 4.5 || HPAccessibility.contrast($0.1, on: HPTokens.bg) < 3 }.map(\.0)
            check(bad.isEmpty, "a11y：\(side) 增加對比的系統色當字 ≥ 4.5（卡上）、≥ 3（底上）\(bad.isEmpty ? "" : "：\(bad)")")
        }
        HPAccessibility.forceIncreaseContrast = false
        HPTokens.dark = false
        check(abs(HPAccessibility.contrast(.black, on: .white) - 21) < 0.01, "a11y：黑對白 21:1")
    }
}
