// 儀表錶面的共用元件（2.0 D2；規格 R3／R4／R5：同一組元件重排成 A、B、C 三種版式）。
//
// 座標用設計稿的 1088 單位、左上原點；ClusterFace 在外面套 1024/1088 的縮放，這裡不管。
// 元件：圓形錶（進度弧或指針、兩組刻度、數字、色帶、限制線）、線性錶（單向／雙向、色帶、標記線）、
// 警示燈膠囊、dynamic content 卡的圖示格、迷你折線、電池圖示。字一律照 FaceType（SF 可變軸），讀不到的值呼叫端傳「—」。

import AppKit
import CoreText

/// 規格 §2 的色票。淺色＝A、C；深色＝B。
struct ClusterTheme {
    var dark: Bool
    /// 夜間紅：單色，狀態只靠圖示與字重區分（D3）
    var night = false
    var bg: NSColor, label: NSColor, secondary: NSColor, track: NSColor, card: NSColor
    var accent: NSColor, soc: NSColor, warn: NSColor, warnText: NSColor, critical: NSColor
    var minorTick: NSColor, majorTick: NSColor, hairline: NSColor

    static let light = ClusterTheme(
        dark: false, bg: srgb(0xFFFFFF), label: srgb(0x000000), secondary: srgb(0x6C6C70),
        track: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.16), card: srgb(0xF2F2F7),
        accent: srgb(0x1E6EF4), soc: srgb(0x008932), warn: srgb(0xC55300), warnText: srgb(0xB04A00), critical: srgb(0xE9152D),
        minorTick: srgb(0x8E8E93), majorTick: srgb(0x8E8E93), hairline: NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.12))
    static let dark = ClusterTheme(
        dark: true, bg: srgb(0x000000), label: srgb(0xFFFFFF), secondary: NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.6),
        track: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.36), card: srgb(0x1C1C1E),
        accent: srgb(0x0091FF), soc: srgb(0x30D158), warn: srgb(0xFF9230), warnText: srgb(0xFF9230), critical: srgb(0xFF4245),
        minorTick: NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.4), majorTick: srgb(0xFFFFFF),
        hairline: NSColor(srgbRed: 84 / 255, green: 84 / 255, blue: 88 / 255, alpha: 0.6))

    /// 夜間紅（D3，稿 Themes「夜間紅」）：黑底、HPTokens.Night 單色。主要＝primary、次要＝secondary，軌道 16% 紅；
    /// 橘與紅都收成同一個紅，嚴重度靠圖示與粗體分（SoC 弧用次要紅，跟主要弧分得開）
    static let night: ClusterTheme = {
        let pri = HPTokens.Night.primary, sec = HPTokens.Night.secondary
        var t = ClusterTheme(
            dark: true, bg: srgb(0x000000), label: pri, secondary: sec,
            track: pri.withAlphaComponent(0.16), card: pri.withAlphaComponent(0.10),
            accent: pri, soc: sec, warn: pri, warnText: pri, critical: pri,
            minorTick: sec.withAlphaComponent(0.5), majorTick: sec, hairline: pri.withAlphaComponent(0.16))
        t.night = true
        return t
    }()

    /// 狀態色（弧線、色條）：正常＝主色、橘＝警示、紅＝危急（R2）
    func tone(_ s: Severity?, normal: NSColor? = nil) -> NSColor {
        switch s { case .critical: return critical; case .warn: return warn; case nil: return normal ?? accent }
    }
    /// 狀態字色：淺色底的橘字要用 #B04A00 才夠對比
    func toneText(_ s: Severity?) -> NSColor? {
        switch s { case .critical: return critical; case .warn: return warnText; case nil: return nil }
    }
}

enum ClusterAlign { case left, center, right }

/// 一組刻度：values 是值域裡的位置，r1→r2 是從圓心起的半徑
struct ClusterTicks {
    var values: [Double]
    var r1: CGFloat, r2: CGFloat
    var width: CGFloat
    var color: NSColor
    var round = false
}

/// 圓形錶的參數（規格 R4）：起訖角、筆畫寬、端點、色帶、進度弧或指針、兩組刻度、數字、限制線
struct ClusterRound {
    var center: CGPoint, radius: CGFloat
    var lo: Double, hi: Double
    var startDeg: CGFloat = 135, sweepDeg: CGFloat = 270
    var stroke: CGFloat, roundCap: Bool
    var track: NSColor
    /// 讀不到：軌道改畫虛線，不畫進度
    var dashed = false
    /// 軌道上蓋一段色（紅區、充電區）
    var bands: [(lo: Double, hi: Double, color: NSColor)] = []
    /// 進度弧：從 from 到 to（雙向錶的 from＝零點）
    var fill: (from: Double, to: Double, color: NSColor)?
    var minor: ClusterTicks?, major: ClusterTicks?
    var numbers: (values: [Double], labels: [String], radius: CGFloat, font: NSFont, color: NSColor)?
    /// 指針（r1→r2，從圓心起）
    var needle: (value: Double, r1: CGFloat, r2: CGFloat, width: CGFloat, color: NSColor)?
    /// 限制線（R9：溫度錶 100 °C 的紅線、功率錶的零點線）
    var limits: [(value: Double, r1: CGFloat, r2: CGFloat, width: CGFloat, color: NSColor)] = []

    func deg(_ v: Double) -> CGFloat {
        let t = (min(max(v, lo), hi) - lo) / (hi - lo)
        return startDeg + sweepDeg * CGFloat(t)
    }
    func point(_ v: Double, _ r: CGFloat) -> CGPoint {
        let a = deg(v) * .pi / 180
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }
}

/// 線性錶的參數：軌道矩形、填色段、色帶、標記線（限制線、零點線）
struct ClusterBar {
    var rect: CGRect
    var track: NSColor
    /// 0…1 的位置；roundLeft／roundRight＝那一端要不要圓頭（雙向錶在零點那端是平的）
    var fills: [(from: CGFloat, to: CGFloat, color: NSColor, roundLeft: Bool, roundRight: Bool)] = []
    var bands: [(from: CGFloat, to: CGFloat, color: NSColor)] = []
    /// 標記線：位置、顏色、線寬、往上／往下各伸出多少
    var marks: [(at: CGFloat, color: NSColor, width: CGFloat, up: CGFloat, down: CGFloat)] = []
    /// 讀不到：軌道改畫點線，不畫填色
    var dashed = false
}

/// 警示燈裡的圖示：SF Symbol 或自畫的電池
enum ClusterIcon {
    case symbol(String)
    case battery(level: Double)
}

struct ClusterPainter {
    let g: CGContext
    let t: ClusterTheme

    // MARK: 字

    /// 細線款字重 300、技術款字重 510＋窄體（wdth 85）、數字等寬
    func font(_ size: CGFloat, _ wght: CGFloat, narrow: Bool = false, mono: Bool = true) -> NSFont {
        FaceType.sfv(size, wght: wght, wdth: narrow ? 85 : 100, mono: mono)
    }

    /// 一行字的寬度（含字距、扣掉最後一字後面那份）
    func width(_ s: String, _ f: NSFont, kern: CGFloat? = nil) -> CGFloat { Typo.width(s, f, kern: kern) }

    /// 在 base（基線）畫一行字，回傳寬度。align 以 x 為準：左緣、中心、右緣
    @discardableResult
    func text(_ s: String, _ f: NSFont, x: CGFloat, base: CGFloat, color: NSColor, align: ClusterAlign = .left, kern: CGFloat? = nil) -> CGFloat {
        let w = width(s, f, kern: kern)
        let x0 = align == .left ? x : align == .center ? x - w / 2 : x - w
        let font = color.isLightInk ? FaceType.graded(f, 440) : f
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(font, color: color, kern: kern)))
        g.saveGState(); g.translateBy(x: x0, y: base); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g); g.restoreGState()
        return w
    }

    /// 同一條基線上連著畫幾段不同字級／顏色的字（大數字＋小單位）；gap＝段與段的間距
    @discardableResult
    func runs(_ parts: [(String, NSFont, NSColor)], x: CGFloat, base: CGFloat, align: ClusterAlign = .left, gap: CGFloat = 0, kern: CGFloat? = nil) -> CGFloat {
        let ws = parts.map { width($0.0, $0.1, kern: kern) }
        let total = ws.reduce(0, +) + gap * CGFloat(max(0, parts.count - 1))
        var cx = align == .left ? x : align == .center ? x - total / 2 : x - total
        for (i, p) in parts.enumerated() { text(p.0, p.1, x: cx, base: base, color: p.2, kern: kern); cx += ws[i] + gap }
        return total
    }

    /// CSS 行盒裡的基線：行高 lineHeight 的盒子頂在 top，內容垂直置中
    func base(top: CGFloat, lineHeight: CGFloat, _ f: NSFont) -> CGFloat {
        top + (lineHeight - (f.ascender - f.descender)) / 2 + f.ascender
    }
    /// 垂直置中到 mid 的基線（SVG 的 dominant-baseline: central）
    func base(mid: CGFloat, _ f: NSFont) -> CGFloat { mid + (f.ascender + f.descender) / 2 }

    // MARK: 基本形

    func fillRounded(_ r: CGRect, radius: CGFloat, _ c: NSColor) {
        g.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.height / 2, r.width / 2), cornerHeight: min(radius, r.height / 2, r.width / 2), transform: nil))
        g.setFillColor(c.cgColor); g.fillPath()
    }

    func arc(center: CGPoint, r: CGFloat, from a0: CGFloat, to a1: CGFloat, width: CGFloat, color: NSColor, round: Bool, dash: [CGFloat]? = nil) {
        guard abs(a1 - a0) > 0.01 else { return }
        g.saveGState()
        g.setStrokeColor(color.cgColor); g.setLineWidth(width); g.setLineCap(round ? .round : .butt)
        if let dash { g.setLineDash(phase: 0, lengths: dash) }
        g.addArc(center: center, radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
        g.strokePath(); g.restoreGState()
    }

    func line(_ p: CGPoint, _ q: CGPoint, width: CGFloat, color: NSColor, round: Bool = false) {
        g.saveGState()
        g.setStrokeColor(color.cgColor); g.setLineWidth(width); g.setLineCap(round ? .round : .butt)
        g.move(to: p); g.addLine(to: q); g.strokePath(); g.restoreGState()
    }

    /// SF Symbol（單色）置中進 r
    func symbol(_ name: String, in r: CGRect, color: NSColor, weight: NSFont.Weight = .semibold) {
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: weight).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size, k = min(r.width / max(1, s.width), r.height / max(1, s.height))
        let dst = CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
        img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 電池圖示 28×16：外框、依電量填滿的內塊、右端小凸點。(x, y) 是左上角
    func battery(x: CGFloat, y: CGFloat, level: Double, color: NSColor) {
        g.saveGState()
        g.setStrokeColor(color.cgColor); g.setLineWidth(2)
        g.addPath(CGPath(roundedRect: CGRect(x: x + 1, y: y + 1, width: 23, height: 14), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        g.strokePath()
        let fillW = 17 * CGFloat(min(max(level, 0), 100) / 100)
        if fillW > 0.5 { fillRounded(CGRect(x: x + 4, y: y + 4, width: fillW, height: 8), radius: 1.5, color) }
        g.setLineCap(.round)
        g.move(to: CGPoint(x: x + 26, y: y + 6)); g.addLine(to: CGPoint(x: x + 26, y: y + 10)); g.strokePath()
        g.restoreGState()
    }

    // MARK: 圓形錶

    /// 畫一個圓形錶。beforeNeedle：指針之前要補畫的東西（例如功率錶裡面的電量小弧，指針要壓在它上面）
    func round(_ s: ClusterRound, beforeNeedle: () -> Void = {}) {
        let c = s.center
        let a0 = s.startDeg, a1 = s.startDeg + s.sweepDeg
        arc(center: c, r: s.radius, from: a0, to: a1, width: s.stroke, color: s.track, round: s.roundCap, dash: s.dashed ? [3, 11] : nil)
        for b in s.bands { arc(center: c, r: s.radius, from: s.deg(b.lo), to: s.deg(b.hi), width: s.stroke, color: b.color, round: false) }
        if let f = s.fill {
            let p = s.deg(f.from), q = s.deg(f.to)
            arc(center: c, r: s.radius, from: min(p, q), to: max(p, q), width: s.stroke, color: f.color, round: s.roundCap)
        }
        for ticks in [s.minor, s.major].compactMap({ $0 }) {
            for v in ticks.values { line(s.point(v, ticks.r1), s.point(v, ticks.r2), width: ticks.width, color: ticks.color, round: ticks.round) }
        }
        for l in s.limits { line(s.point(l.value, l.r1), s.point(l.value, l.r2), width: l.width, color: l.color) }
        if let n = s.numbers {
            for (v, label) in zip(n.values, n.labels) {
                let p = s.point(v, n.radius)
                text(label, n.font, x: p.x, base: base(mid: p.y, n.font), color: n.color, align: .center, kern: 0)
            }
        }
        beforeNeedle()
        if let n = s.needle { line(s.point(n.value, n.r1), s.point(n.value, n.r2), width: n.width, color: n.color, round: true) }
    }

    // MARK: 線性錶

    /// 一段填色：兩端各自決定圓頭或平頭（雙向錶在零點那端是平的）
    private func segment(_ r: CGRect, from: CGFloat, to: CGFloat, roundLeft: Bool, roundRight: Bool, color: NSColor) {
        let x0 = r.minX + r.width * min(from, to), x1 = r.minX + r.width * max(from, to)
        guard x1 - x0 > 0.2 else { return }
        let rad = r.height / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0 + (roundLeft ? rad : 0), y: r.minY))
        p.addLine(to: CGPoint(x: x1 - (roundRight ? rad : 0), y: r.minY))
        if roundRight { p.addArc(center: CGPoint(x: x1 - rad, y: r.midY), radius: rad, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false) }
        else { p.addLine(to: CGPoint(x: x1, y: r.maxY)) }
        p.addLine(to: CGPoint(x: x0 + (roundLeft ? rad : 0), y: r.maxY))
        if roundLeft { p.addArc(center: CGPoint(x: x0 + rad, y: r.midY), radius: rad, startAngle: .pi / 2, endAngle: -.pi / 2 + 2 * .pi, clockwise: false) }
        else { p.addLine(to: CGPoint(x: x0, y: r.minY)) }
        p.closeSubpath()
        g.addPath(p); g.setFillColor(color.cgColor); g.fillPath()
    }

    func bar(_ b: ClusterBar) {
        if b.dashed {
            let h = b.rect.height
            g.saveGState()
            g.setStrokeColor(b.track.cgColor); g.setLineWidth(h * 0.6); g.setLineCap(.round); g.setLineDash(phase: 0, lengths: [0.01, h * 1.3])
            g.move(to: CGPoint(x: b.rect.minX + h * 0.3, y: b.rect.midY)); g.addLine(to: CGPoint(x: b.rect.maxX - h * 0.3, y: b.rect.midY)); g.strokePath()
            g.restoreGState()
        } else {
            fillRounded(b.rect, radius: b.rect.height / 2, b.track)
        }
        for x in b.bands { segment(b.rect, from: x.from, to: x.to, roundLeft: false, roundRight: x.to >= 0.999, color: x.color) }
        for f in b.fills { segment(b.rect, from: f.from, to: f.to, roundLeft: f.roundLeft, roundRight: f.roundRight, color: f.color) }
        for m in b.marks {
            let x = b.rect.minX + b.rect.width * m.at
            line(CGPoint(x: x, y: b.rect.minY - m.up), CGPoint(x: x, y: b.rect.maxY + m.down), width: m.width, color: m.color)
        }
    }

    // MARK: 警示燈

    func lampWidth(label: String, fontSize: CGFloat, padRight: CGFloat, bold: Bool = false) -> CGFloat {
        14 + 28 + 8 + width(label, font(fontSize, bold ? 720 : 590, mono: false)) + padRight
    }

    /// 膠囊：圖示＋短字，底是狀態色 12%；回傳寬度（呼叫端用來排下一顆）
    @discardableResult
    func lamp(x: CGFloat, y: CGFloat, icon: ClusterIcon, label: String, color: NSColor, fontSize: CGFloat, padRight: CGFloat, bold: Bool = false) -> CGFloat {
        let f = font(fontSize, bold ? 720 : 590, mono: false)
        let w = lampWidth(label: label, fontSize: fontSize, padRight: padRight, bold: bold)
        fillRounded(CGRect(x: x, y: y, width: w, height: 52), radius: 26, color.withAlphaComponent(0.12))
        switch icon {
        case .symbol(let name): symbol(name, in: CGRect(x: x + 14, y: y + 12, width: 28, height: 28), color: color)
        case .battery(let level): battery(x: x + 14, y: y + 18, level: level, color: color)
        }
        text(label, f, x: x + 14 + 28 + 8, base: base(mid: y + 26, f), color: color)
        return w
    }

    // MARK: dynamic content 卡

    /// 卡片底（連續圓角）
    func cardBackground(_ r: CGRect, radius: CGFloat) {
        g.addPath(continuousRoundedRect(r, radius: radius)); g.setFillColor(t.card.cgColor); g.fillPath()
    }

    /// 圖示格：tinted＝狀態色 12% 底＋狀態色圖示；否則實色底＋白圖示
    func iconTile(_ r: CGRect, radius: CGFloat, symbol name: String, color: NSColor, solid: Bool, glyph: CGFloat) {
        fillRounded(r, radius: radius, solid ? color : color.withAlphaComponent(0.12))
        symbol(name, in: CGRect(x: r.midX - glyph / 2, y: r.midY - glyph / 2, width: glyph, height: glyph), color: solid ? .white : color, weight: solid ? .semibold : .medium)
    }

    /// 迷你折線（卡片右側的負載走勢）：values 0…100，畫進 r；少於 2 個點不畫
    func sparkline(_ values: [Double], in r: CGRect, color: NSColor, lineWidth: CGFloat) {
        guard values.count >= 2 else { return }
        let inset = lineWidth / 2
        let p = CGMutablePath()
        for (i, v) in values.enumerated() {
            let x = r.minX + inset + (r.width - lineWidth) * CGFloat(i) / CGFloat(values.count - 1)
            let y = r.maxY - inset - (r.height - lineWidth) * CGFloat(min(max(v, 0), 100) / 100)
            i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
        }
        g.saveGState()
        g.setStrokeColor(color.cgColor); g.setLineWidth(lineWidth); g.setLineCap(.round); g.setLineJoin(.round)
        g.addPath(p); g.strokePath(); g.restoreGState()
    }
}
