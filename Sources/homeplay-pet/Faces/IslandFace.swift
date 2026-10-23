// 島錶面（2026 · Liquid Glass）：照 HomeView 的 Portraits 錶面——窄高的玻璃大數字佔滿畫面，
// 島（👀）站在數字前面，像人像照裡的主角擋住時間，有景深。
// 四種時鐘樣式：粗（玻璃）、細（實心細字）、直排（上時下分）、島數字（小時間＋大島）。

import AppKit

nonisolated(unsafe) private var islandGlassCache: (key: String, image: CGImage)?
/// 靜態層快取：背景＋玻璃大數字＋日期一分鐘才變一次；眨眼、瞄一眼只要重畫島（省下每幀約 5 ms）
nonisolated(unsafe) private var islandStaticCache: (key: String, image: CGImage, layout: (CGPoint, CGFloat, CGPoint))?

extension Face {
    func renderIsland2026(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let rv = reveal
        let bg = background.effective(hasPhoto: photos.current != nil)
        let layout: (CGPoint, CGFloat, CGPoint)
        if bg == .flow {
            layout = drawIslandStatic(g, now)   // Flow 背景一直在漂：照常每次畫
        } else {
            let date = Self.displayDate
            let photoID = photos.current.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-"
            let key = "\(Int(date.timeIntervalSince1970 / 60))|\(wallpaperGeneration)|\(Int((rv * 24).rounded()))|\(clockStyle.rawValue)|\(ClockLook.active.key)|\(bg.rawValue)|\(photoID)|\(Int(renderPixelScale * 100))|\(L10n.language.rawValue)"
            if let c = islandStaticCache, c.key == key {
                drawUpright(g, c.image, in: full); layout = c.layout; Face.cacheHits += 1
            } else {
                let sc = renderPixelScale, px = Int((1024 * sc).rounded())
                var lay = (CGPoint.zero, CGFloat(1), CGPoint.zero)
                let img = makeImage(px, px) { c in
                    if sc != 1 { c.scaleBy(x: sc, y: sc) }
                    lay = self.drawIslandStatic(c, now)
                }
                islandStaticCache = (key, img, lay)
                drawUpright(g, img, in: full); layout = lay; Face.cacheMisses += 1
            }
        }
        let (islandAt, islandScale, liveAt) = layout
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

    /// 背景、玻璃大數字、日期（不含島與狀態膠囊）；回傳島的位置、大小、長成即時動態時的位置
    private func drawIslandStatic(_ g: CGContext, _ now: Double) -> (CGPoint, CGFloat, CGPoint) {
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
        // 系統的 SF Adaptive Numeric：HGHT 軸往上長高、筆畫不變形（iOS 26 鎖定畫面／HomeView Portraits 的大時間）
        // 字體、粗細、顏色、玻璃／實線都照「字體與顏色」（ClockLook）
        var look = ClockLook.active
        if clockStyle == .thin, UserDefaults.standard.data(forKey: ClockLook.defaultsKey) == nil {   // 舊的「細線」樣式：細、實線
            look.weight = 0.08; look.glass = false
        }
        func tallPair(top: CGFloat, height: CGFloat, gap: CGFloat) -> (GlyphShape, GlyphShape) {
            let w = 512 - gap / 2 - 60
            let hS = GlyphShape.clock(hh, look: look, height: height, maxWidth: w, at: CGPoint(x: 512 - gap / 2, y: top), anchorX: 1)
            let mS = GlyphShape.clock(mm, look: look, height: height, maxWidth: w, at: CGPoint(x: 512 + gap / 2, y: top), anchorX: 0)
            return (hS, mS)
        }
        let textAlpha = 0.72 + 0.28 * rv
        switch clockStyle {
        case .bold, .thin:
            let (a, b) = tallPair(top: 150, height: 700, gap: 64)
            drawClockDigits(g, [a, b], look: look, clear: islandClear(bg, now), frosted: backdrop, alpha: textAlpha)
        case .stacked:
            // 上時下分（X-Large 的排法），各一行
            let top = GlyphShape.clock(hh, look: look, height: 330, maxWidth: 820, at: CGPoint(x: 512, y: 132), anchorX: 0.5, weightBoost: 0.15)
            let bot = GlyphShape.clock(mm, look: look, height: 330, maxWidth: 820, at: CGPoint(x: 512, y: 500), anchorX: 0.5, weightBoost: 0.15)
            drawClockDigits(g, [top, bot], look: look, clear: islandClear(bg, now), frosted: backdrop, alpha: textAlpha)
            dateY = 84; islandAt = CGPoint(x: 512, y: 900); islandScale = 0.72; liveAt = CGPoint(x: 512, y: 880)
        case .compact:
            // 島是主角：上面一行不大的時間，島放大置中（字小，玻璃看不出來：一律實線，顏色照設定）
            let s = GlyphShape("\(hh):\(mm)", font: look.font.nsFont(150, weight: look.weight + 0.12), kern: -2).centered(at: CGPoint(x: 512, y: 236))
            fillShape(g, s, look.color(wallpaper: wallpaperTone(backdrop)).withAlphaComponent(0.8 + 0.2 * rv), shadow: 0.2)
            dateY = 110; islandAt = CGPoint(x: 512, y: 560); islandScale = 1.3; liveAt = CGPoint(x: 512, y: 600)
        }
        // 日期：一般字寬、半粗，像鎖定畫面
        drawCentered(g, Self.dateLine(date), font: FaceType.sf(40, .semibold), kern: 0.4, y: dateY,
                     color: NSColor.white.withAlphaComponent(0.66 + 0.3 * rv))

        return (islandAt, islandScale, liveAt)
    }

    /// 給光學玻璃的「清楚」背景：隨時段用壁紙本身；照片、Flow、純色當場取一張 512² 的
    private func islandClear(_ bg: IslandBackground, _ now: Double) -> CGImage? {
        if bg == .daytime, let wallpaper { return wallpaper }
        return snapshotBackdrop(px: 512) { c in self.drawIslandBackground(c, bg, now) }
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
