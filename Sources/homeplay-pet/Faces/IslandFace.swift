// 島錶面（2026 · Liquid Glass）：照 HomeView 的 Portraits 錶面——窄高的玻璃大數字佔滿畫面，
// 島（👀）站在數字前面，像人像照裡的主角擋住時間，有景深。
// 四種時鐘樣式：粗（玻璃）、細（實心細字）、直排（上時下分）、島數字（小時間＋大島）。

import AppKit

nonisolated(unsafe) private var islandGlassCache: (key: String, image: CGImage)?

extension Face {
    func renderIsland2026(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let rv = reveal, date = Self.displayDate
        let bg = background.effective(hasPhoto: photos.current != nil)
        drawIslandBackground(g, bg, now)
        if rv < 0.999 {   // 沒人靠近：整面壓暗一點（省電的恆亮樣子）
            g.setFillColor(NSColor.black.withAlphaComponent(0.20 * (1 - rv)).cgColor); g.fill(full)
        }
        let (hh, mm) = Self.hourMinute(date)
        let backdrop = islandBackdrop(bg, now)

        var islandAt = CGPoint(x: 512, y: 650), islandScale: CGFloat = 1.0, liveAt = CGPoint(x: 512, y: 700)
        var dateY: CGFloat = 104
        // 數字：時在左、分在右，以中線為界各自貼齊中間的縫（單位數的小時不會漂到左邊）
        func tallPair(_ font: NSFont, top: CGFloat, height: CGFloat, stretch: CGFloat, gap: CGFloat) -> (GlyphShape, GlyphShape) {
            let hS = GlyphShape(hh, font: font, kern: -font.pointSize * 0.01)
                .tall(height: height, stretch: stretch, at: CGPoint(x: 512 - gap / 2, y: top), anchorX: 1, maxWidth: 512 - gap / 2 - 60)
            let mS = GlyphShape(mm, font: font, kern: -font.pointSize * 0.01)
                .tall(height: height, stretch: stretch, at: CGPoint(x: 512 + gap / 2, y: top), anchorX: 0, maxWidth: 512 - gap / 2 - 60)
            return (hS, mS)
        }
        let textAlpha = 0.72 + 0.28 * rv
        switch clockStyle {
        case .bold:
            let (a, b) = tallPair(FaceType.sf(400, .medium, width: .compressed), top: 150, height: 700, stretch: 1.42, gap: 64)
            g.saveGState(); g.setAlpha(textAlpha)
            drawGlass(g, a, backdrop: backdrop, cacheKey: "island-h|\(hh)"); drawGlass(g, b, backdrop: backdrop, cacheKey: "island-m|\(mm)")
            g.restoreGState()
        case .thin:
            let (a, b) = tallPair(FaceType.sf(400, .ultraLight, width: .compressed), top: 150, height: 700, stretch: 1.42, gap: 56)
            for s in [a, b] { fillShape(g, s, NSColor.white.withAlphaComponent(0.55 + 0.4 * rv), shadow: 0.18) }
        case .stacked:
            // 上時下分（X-Large 的排法），各一行、玻璃
            let f = FaceType.sf(400, .semibold, width: .standard)
            let top = GlyphShape(hh, font: f, kern: -10).tall(height: 330, stretch: 1.0, at: CGPoint(x: 512, y: 132), anchorX: 0.5, maxWidth: 820)
            let bot = GlyphShape(mm, font: f, kern: -10).tall(height: 330, stretch: 1.0, at: CGPoint(x: 512, y: 500), anchorX: 0.5, maxWidth: 820)
            g.saveGState(); g.setAlpha(textAlpha)
            drawGlass(g, top, backdrop: backdrop, cacheKey: "island-sh|\(hh)"); drawGlass(g, bot, backdrop: backdrop, cacheKey: "island-sm|\(mm)")
            g.restoreGState()
            dateY = 84; islandAt = CGPoint(x: 512, y: 900); islandScale = 0.72; liveAt = CGPoint(x: 512, y: 880)
        case .compact:
            // 島是主角：上面一行不大的時間，島放大置中
            let f = FaceType.sf(150, .semibold, width: .standard)
            let s = GlyphShape("\(hh):\(mm)", font: f, kern: -2).centered(at: CGPoint(x: 512, y: 236))
            fillShape(g, s, NSColor.white.withAlphaComponent(0.8 + 0.2 * rv), shadow: 0.2)
            dateY = 110; islandAt = CGPoint(x: 512, y: 560); islandScale = 1.3; liveAt = CGPoint(x: 512, y: 600)
        }
        // 日期：一般字寬、半粗，像鎖定畫面
        drawCentered(g, Self.dateLine(date), font: FaceType.sf(40, .semibold), kern: 0.4, y: dateY,
                     color: NSColor.white.withAlphaComponent(0.66 + 0.3 * rv))

        // 靠近時底部的 CarPlay 狀態膠囊
        if rv > 0.02 && liveT < 0.5 {
            let font = FaceType.sf(32, .semibold, mono: false)
            let tw = (status.text as NSString).size(withAttributes: [.font: font]).width
            let chip = CGRect(x: 512 - (tw + 64) / 2, y: 900 + 18 * (1 - rv), width: tw + 64, height: 70)
            g.saveGState(); g.setAlpha(rv * (1 - liveT * 2))
            if bg == .daytime { glass(g, chip, radius: 35, tint: NSColor(white: 1, alpha: 0.10), band: 10) }
            else { plainPill(g, chip, tint: NSColor(white: 1, alpha: 0.14)) }
            drawCentered(g, status.text, font: font, kern: 0, y: chip.midY + 11, color: NSColor.white.withAlphaComponent(0.9))
            g.restoreGState()
        }
        drawIsland(g, at: islandAt, scale: islandScale, liveAt: liveAt, now: now)
    }

    /// 給玻璃數字折射用的背景（模糊過）
    private func islandBackdrop(_ bg: IslandBackground, _ now: Double) -> CGImage? {
        switch bg {
        case .daytime: return frosted
        case .photo:
            guard let img = photos.current else { return frosted }
            let key = "photo|\(ObjectIdentifier(img).hashValue)"
            if let c = islandGlassCache, c.key == key { return c.image }
            let small = snapshotBackdrop(px: 256) { c in self.drawIslandBackground(c, .photo, now) }
            let r = blurredBackdrop(small, sigma: 18, key: key)
            islandGlassCache = (key, r)
            return r
        case .flow:
            // 光團一直在漂：每次重畫都取一張 192² 的小圖再模糊（約 1 ms）
            let small = snapshotBackdrop(px: 192) { c in self.drawIslandBackground(c, .flow, now) }
            return blurredBackdrop(small, sigma: 16, key: "flow|\(Int(now * 10))")
        case .solid, .black:
            let key = "plain|\(bg.rawValue)"
            if let c = islandGlassCache, c.key == key { return c.image }
            let r = snapshotBackdrop(px: 64) { c in self.drawIslandBackground(c, bg, now) }
            islandGlassCache = (key, r)
            return r
        }
    }
}
