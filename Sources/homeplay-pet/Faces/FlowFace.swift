// 錶面「Flow」：照 HomeView 的 Flow——上時下分兩行「吹脹」的玻璃水珠字：0 沒有字腔（一整顆圓潤的水珠）、
// 1 是一顆膠囊，其他數字把字腔填滿再鼓起來；旁邊散著小水珠。底下是旋轉的粉／藍色彩，字裡透出被強烈折射的同一片色彩，
// 沒有白色描邊。游標（人）靠近時色彩跟著漂。島（👀）是左上角一顆小水珠膠囊，不夾在兩行之間。

import AppKit

// 上次重畫的 0.1 秒刻度（擴展裡不能加儲存屬性）
nonisolated(unsafe) private var flowFaceLastTick = -1.0
/// 色彩流動用的時鐘：只在有人靠近時往前走（沒人看就停住、3D 可以卸下省電；回來時接著流，不會跳）
nonisolated(unsafe) private var flowAnimT = 0.0, flowAnimLast = -1.0, flowLastMinute = -1
nonisolated(unsafe) private var flowDigitCache: (key: String, shapes: [GlyphShape])?


extension Face {
    /// 色團：中心、半徑、縱向壓扁、顏色、透明度、游標視差、自主漂動週期（秒）——繞著中間的藍旋轉
    private static let flowBlobs: [(c: CGPoint, r: CGFloat, sy: CGFloat, rgb: UInt32, a: CGFloat, par: CGFloat, per: Double)] = [
        (CGPoint(x: 600, y: 360), 300, 0.9, 0x5fd2ff, 0.85, 70, 29),    // 青（左上那道亮藍）
        (CGPoint(x: 330, y: 700), 260, 1.0, 0xff5fc0, 0.80, 90, 37),    // 粉（左下）
        (CGPoint(x: 760, y: 640), 280, 1.0, 0x4e5bff, 0.85, 52, 23),    // 電光藍
        (CGPoint(x: 300, y: 330), 220, 1.0, 0x6f86ff, 0.70, 120, 31),   // 藍紫
    ]

    private func drawFlowField(_ g: CGContext, _ now0: Double) {
        let now = flowAnimT
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 底：外圈淡薰衣草，往內一圈洋紅，中間一大團藍（官方 Flow 的配色）
        g.setFillColor(srgb(0xd3c2ea).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let cx = 530 + flow.x * 40 + CGFloat(sin(now * 2 * .pi / 41)) * 24, cy = 500 + flow.y * 32 + CGFloat(cos(now * 2 * .pi / 47)) * 20
        let ring = CGGradient(colorsSpace: cs, colors: [srgb(0x4a66ff).cgColor, srgb(0x5a62ff).cgColor, srgb(0x9a5cf0).cgColor,
                                                         srgb(0xff4fae).cgColor, srgb(0xf59bd2, 0.7).cgColor, srgb(0xd3c2ea, 0).cgColor] as CFArray,
                              locations: [0, 0.38, 0.55, 0.7, 0.84, 1])!
        g.saveGState()
        g.translateBy(x: cx, y: cy); g.rotate(by: CGFloat(now * 0.05) - 0.5); g.scaleBy(x: 1, y: 0.86)
        g.drawRadialGradient(ring, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 600, options: [])
        g.restoreGState()
        for (i, b) in Self.flowBlobs.enumerated() {
            let ph = Double(i) * 1.7
            let bx = b.c.x + flow.x * b.par + CGFloat(sin(now * 2 * .pi / b.per + ph)) * 50
            let by = b.c.y + flow.y * b.par * 0.8 + CGFloat(cos(now * 2 * .pi / (b.per * 1.3) + ph)) * 40
            let col = srgb(b.rgb)
            let grad = CGGradient(colorsSpace: cs, colors: [col.withAlphaComponent(b.a).cgColor, col.withAlphaComponent(b.a * 0.5).cgColor,
                                                            col.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
            g.saveGState()
            g.translateBy(x: bx, y: by); g.scaleBy(x: 1, y: b.sy)
            g.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: b.r, options: [])
            g.restoreGState()
        }
    }

    /// 畫面上的 Flow 底圖＝色團＋四週一圈很淡的白霧（隔著一層玻璃的樣子）。玻璃取樣用同一張，字裡字外才會一致
    private func drawFlowBase(_ g: CGContext, _ now: Double) {
        drawFlowField(g, now)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let vig = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 0.22).cgColor] as CFArray,
                             locations: [0.55, 1])!
        g.drawRadialGradient(vig, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 760, options: [])
    }

    /// 一個水珠數字（墨跡高 h、左上角在 at）：0 是圓潤的方圓、1 是膠囊，其他數字用 Soft 最粗的字形、把字腔填滿再鼓起來
    private static func blobDigit(_ d: Character, height h: CGFloat, at p: CGPoint) -> GlyphShape {
        switch d {
        case "0":
            let w = h * 0.86
            return GlyphShape(path: CGPath(roundedRect: CGRect(x: p.x, y: p.y, width: w, height: h), cornerWidth: w * 0.47, cornerHeight: h * 0.44, transform: nil))
        case "1":
            let w = h * 0.33
            return GlyphShape(path: CGPath(roundedRect: CGRect(x: p.x, y: p.y + h * 0.02, width: w, height: h * 0.96), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
        case "9", "6":
            // 照官方：左邊一個半圓的「碗」、右邊一根右側圓鼓的高柱；6 是 9 轉半圈
            let bw = h * 0.42, bh = h * 0.6, sw = h * 0.46, gap = h * 0.055, W = bw + gap + sw
            let p0 = CGMutablePath()
            let bowl = CGRect(x: 0, y: 0, width: bw, height: bh)
            let rb = h * 0.06
            p0.move(to: CGPoint(x: bowl.midX, y: bowl.minY))
            p0.addArc(tangent1End: CGPoint(x: bowl.maxX, y: bowl.minY), tangent2End: CGPoint(x: bowl.maxX, y: bowl.maxY), radius: rb)
            p0.addArc(tangent1End: CGPoint(x: bowl.maxX, y: bowl.maxY), tangent2End: CGPoint(x: bowl.minX, y: bowl.maxY), radius: rb)
            p0.addArc(tangent1End: CGPoint(x: bowl.minX, y: bowl.maxY), tangent2End: CGPoint(x: bowl.minX, y: bowl.midY), radius: min(bw, bh / 2) * 0.98)
            p0.addArc(tangent1End: CGPoint(x: bowl.minX, y: bowl.minY), tangent2End: CGPoint(x: bowl.maxX, y: bowl.minY), radius: min(bw, bh / 2) * 0.98)
            p0.closeSubpath()
            let stem = CGRect(x: bw + gap, y: 0, width: sw, height: h)
            let r0 = sw * 0.3, r1 = sw * 0.5
            p0.move(to: CGPoint(x: stem.minX, y: stem.minY + r0))
            p0.addArc(tangent1End: CGPoint(x: stem.minX, y: stem.minY), tangent2End: CGPoint(x: stem.maxX, y: stem.minY), radius: r0)
            p0.addArc(tangent1End: CGPoint(x: stem.maxX, y: stem.minY), tangent2End: CGPoint(x: stem.maxX, y: stem.maxY), radius: r1)
            p0.addArc(tangent1End: CGPoint(x: stem.maxX, y: stem.maxY), tangent2End: CGPoint(x: stem.minX, y: stem.maxY), radius: r1)
            p0.addArc(tangent1End: CGPoint(x: stem.minX, y: stem.maxY), tangent2End: CGPoint(x: stem.minX, y: stem.minY), radius: r0)
            p0.closeSubpath()
            var t = d == "9" ? CGAffineTransform(translationX: p.x, y: p.y)
                : CGAffineTransform(translationX: p.x + W, y: p.y + h).rotated(by: .pi)
            return GlyphShape(path: p0.copy(using: &t) ?? p0)
        default:
            let f = FaceType.numeric(.soft, 400, ["wght": 1000, "wdth": 100, "SOFT": 100])
            let puff = h * 0.07
            let raw = GlyphShape(String(d), font: f).tall(height: h - puff, stretch: 1.0, at: CGPoint(x: p.x + puff / 2, y: p.y + puff / 2), anchorX: 0)
            let solid = Self.fillCounters(raw.path)
            let puffed = solid.copy(strokingWithWidth: puff, lineCap: .round, lineJoin: .round, miterLimit: 1)
            return GlyphShape(path: solid.union(puffed))
        }
    }

    /// 把字腔（被別的輪廓包住的子路徑）拿掉，只留外輪廓：水珠沒有洞
    private static func fillCounters(_ path: CGPath) -> CGPath {
        var subs: [CGMutablePath] = []
        path.applyWithBlock { e in
            let el = e.pointee, pts = el.points
            switch el.type {
            case .moveToPoint: let m = CGMutablePath(); m.move(to: pts[0]); subs.append(m)
            case .addLineToPoint: subs.last?.addLine(to: pts[0])
            case .addQuadCurveToPoint: subs.last?.addQuadCurve(to: pts[1], control: pts[0])
            case .addCurveToPoint: subs.last?.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closeSubpath: subs.last?.closeSubpath()
            @unknown default: break
            }
        }
        let out = CGMutablePath()
        for (i, sp) in subs.enumerated() {
            let b = sp.boundingBoxOfPath, probe = sp.currentPoint
            let hole = subs.enumerated().contains { j, o in
                j != i && o.boundingBoxOfPath.contains(b) && o.contains(probe, using: .winding)
            }
            if !hole { out.addPath(sp) }
        }
        return out.normalized()
    }

    /// 一行水珠數字：從 x 開始往右排，字距 gap；回傳各字與整行寬
    private static func blobRow(_ s: String, height h: CGFloat, x: CGFloat, top: CGFloat, gap: CGFloat) -> [GlyphShape] {
        var out: [GlyphShape] = [], cx = x
        for ch in s {
            let d = blobDigit(ch, height: h, at: CGPoint(x: cx, y: top))
            out.append(d); cx = d.ink.maxX + gap
        }
        return out
    }

    func renderFlowFace(_ g: CGContext, _ now: Double) {
        self.drawFlowBase(g, now)

        let date = Self.displayDate
        let (hh, mm) = Self.hourMinute(date)   // 小時照時制、不補零（iOS 兩種時制的單位數小時都不帶零）
        let key = "\(hh)\(mm)"
        let shapes: [GlyphShape]
        if let c = flowDigitCache, c.key == key { shapes = c.shapes } else {
            // 稿：上行（時）右靠、左上讓給島；下行（分）置中；字高 ≈ 386（226／600）
            var h: CGFloat = 386
            let gap: CGFloat = 26
            func width(_ s: String, _ h: CGFloat) -> CGFloat {
                let r = Self.blobRow(s, height: h, x: 0, top: 0, gap: gap); return (r.last?.ink.maxX ?? 0) - (r.first?.ink.minX ?? 0)
            }
            // 上行放在島右邊（x ≥ 350）到 970 之間、中心偏右（稿 ≈ 610），太寬就縮
            let topW = width(hh, h)
            if topW > 620 { h *= 620 / topW }
            let tw = width(hh, h)
            let top = Self.blobRow(hh, height: h, x: max(350, min(970 - tw, 620 - tw / 2)), top: 109 + (386 - h), gap: gap)
            let botH: CGFloat = 400, bw = width(mm, botH), bk = min(1, 860 / bw)
            let bot = Self.blobRow(mm, height: botH * bk, x: 512 - bw * bk / 2, top: 524, gap: gap)
            var all = top + bot
            // 衛星小水珠：下行兩字之間的凹口裡一顆（不碰到字）；放不下就放到下行旁邊
            let union = CGMutablePath(); for s in all { union.addPath(s.path) }
            func free(_ c: CGPoint, _ r: CGFloat) -> Bool {
                guard c.x - r > 20, c.x + r < 1004, c.y + r < 1004 else { return false }
                for k in 0..<16 {
                    let a = CGFloat(k) / 16 * 2 * .pi
                    if union.contains(CGPoint(x: c.x + cos(a) * (r + 10), y: c.y + sin(a) * (r + 10))) { return false }
                }
                return !union.contains(c)
            }
            if bot.count == 2 {
                // 在下行裡找一個空位：越靠近兩字之間的凹口（偏下）越好；官方的那顆躲在 9 的碗底下
                let r = (bot[0].ink.height * 0.135).rounded(), gx = (bot[0].ink.maxX + bot[1].ink.minX) / 2
                let rowB = max(bot[0].ink.maxY, bot[1].ink.maxY), rowT = min(bot[0].ink.minY, bot[1].ink.minY)
                let goal = CGPoint(x: gx, y: rowB - r)
                var best: (CGPoint, CGFloat)?
                var y = rowB - r
                while y > (rowT + rowB) / 2 {
                    var x = bot[0].ink.minX + r
                    while x < bot[1].ink.maxX - r {
                        let c = CGPoint(x: x, y: y), d = hypot(c.x - goal.x, c.y - goal.y)
                        if d < (best?.1 ?? .infinity), free(c, r) { best = (c, d) }
                        x += 8
                    }
                    y -= 8
                }
                if best == nil { for c in [CGPoint(x: gx, y: rowB + r * 0.4), CGPoint(x: bot[1].ink.maxX + r + 14, y: rowB - r)] where free(c, r * 0.8) { best = (c, 0); break } }
                if let c = best?.0 {
                    let rr = free(c, r) ? r : r * 0.8
                    all.append(GlyphShape(path: CGPath(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr), transform: nil)))
                }
            }
            shapes = all
            flowDigitCache = (key, shapes)
        }
        // 折射用的背景：同一片色彩（含邊緣白霧）畫成 384² 的清楚版，霧版由它做局部模糊
        // （192² 直接糊會變成整張的平均色，字裡透出的不是附近的色彩而是全畫面的平均，跟官方差很遠）
        let clear = snapshotBackdrop(px: 384) { c in self.drawFlowBase(c, now) }
        let backdrop = blurredBackdrop(clear, sigma: 9, key: "flowface|\(Int(flowAnimT * 10))")
        // 亮邊跟著人轉：人在左邊，光就從左邊打過來（像斜著看 iPhone 鎖定畫面的玻璃時間）
        let pt = Self.pointerOverride ?? pointer ?? .zero
        let turn = max(-0.9, min(0.9, -pt.x * 0.7 + pt.y * 0.35))
        drawLiquidGlass(g, shapes, key: "flowblob|\(key)", clear: clear, frosted: backdrop, params: .flowBlob,
                        lightTurn: turn, fallback: .bubble)

        // 島：左上角一顆小水珠膠囊（寬 ≈ 256，稿：face('Flow') 寬 150／600、中心 (120, 150)／600）
        let corner = Screen.cornerCapsuleCenter(.topLeft, width: 256, height: 256 / 2.69)   // 左端半圓與螢幕圓角同心
        drawIsland(g, at: corner, scale: 256 / 588, liveAt: CGPoint(x: 512, y: 512), now: now)
        // 日期：靠近才浮出（右下一行小字，不搶泡泡）
        if reveal > 0.02 {
            g.saveGState(); g.setAlpha(reveal)
            drawCentered(g, Self.dateLine(date), font: FaceType.sf(32, .semibold, mono: false), kern: 0.4, y: 948,
                         color: NSColor.white.withAlphaComponent(0.92))
            g.restoreGState()
        }
    }

    /// 有人靠近時色團在漂（10fps）；沒人時停住，只在換分鐘時重畫
    func tickFlowFace(_ now: Double) -> Bool {
        let active = (flowActive || reveal > 0.05) && !Face.ambientPaused   // 2.0 depth：減少動態效果（與過熱、低電量）時色團不漂
        if flowAnimLast >= 0, active { flowAnimT += min(0.25, now - flowAnimLast) }
        flowAnimLast = now
        let minute = Int(Self.displayDate.timeIntervalSince1970 / 60)
        if minute != flowLastMinute { flowLastMinute = minute; return true }
        guard active else { return false }
        let t = floor(now * 10)
        if t == flowFaceLastTick { return false }
        flowFaceLastTick = t
        return true
    }
}
