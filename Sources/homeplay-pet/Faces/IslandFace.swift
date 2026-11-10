// 島錶面（2026 · Liquid Glass）：照 HomeView 的 Portraits 錶面——窄高的玻璃大數字佔滿畫面，
// 島（👀）站在數字前面，像人像照裡的主角擋住時間，有景深。
// 四種時鐘樣式：粗（玻璃）、細（實心細字）、直排（上時下分）、島數字（小時間＋大島）。

import AppKit

nonisolated(unsafe) private var islandGlassCache: (key: String, image: CGImage)?
nonisolated(unsafe) private var islandLiftedCache: (key: String, image: CGImage)?
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
            let key = "\(Int(date.timeIntervalSince1970 / 60))|\(bg == .daytime ? Int(hourNow * 4) : wallpaperGeneration)|\(Int((rv * 24).rounded()))|\(clockStyle.rawValue)|\(ClockLook.active.key)|\(HPLook.name)|\(HPNumeralGlass.current.reduceTransparency)\(HPNumeralGlass.current.reduceMotion)|\(bg.rawValue)|\(photoID)|\(Int(renderPixelScale * 100))|\(L10n.language.rawValue)"
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
        // 靠近時底部的 CarPlay 狀態膠囊（在島下面，不疊到島）。
        // 「重按連上 iPhone」這種操作提示由第一次的導覽（Onboarding）教過了，錶面上不再一直掛著。
        let idleHint = status == .notConnected && CarPlayPhoneBook.phones.isEmpty
        if rv > 0.02 && liveT < 0.5 && !idleHint {
            let font = FaceType.sf(32, .semibold, mono: false)
            let tw = Typo.width(status.text, font)
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

        // 島在數字下面置中：寬 ≈ 512（稿：face('眼睛') 寬 300／600、y 405／600）
        var islandAt = CGPoint(x: 512, y: 694), islandScale: CGFloat = 512 / 588, liveAt = CGPoint(x: 512, y: 700)
        var dateY: CGFloat = 70
        // 數字：時在左、分在右，各自貼齊中間的縫，再整組置中（12 小時制的單位數小時也在正中）
        // 系統的 SF Adaptive Numeric：HGHT 軸往上長高、筆畫不變形（iOS 26 鎖定畫面／HomeView Portraits 的大時間）
        // 字體、粗細、顏色、玻璃／實線都照「字體與顏色」（ClockLook）
        var look = ClockLook.active
        if clockStyle == .thin, UserDefaults.standard.data(forKey: ClockLook.defaultsKey) == nil {   // 舊的「細線」樣式：細、實線
            look.weight = 0.08; look.glass = false
        }
        func tallPair(top: CGFloat, height: CGFloat, gap: CGFloat, boost: Double) -> (GlyphShape, GlyphShape) {
            let w = 512 - gap / 2 - 52
            let hS = GlyphShape.clock(hh, look: look, height: height, maxWidth: w, at: CGPoint(x: 512 - gap / 2, y: top), anchorX: 1, weightBoost: boost)
            let mS = GlyphShape.clock(mm, look: look, height: height, maxWidth: w, at: CGPoint(x: 512 + gap / 2, y: top), anchorX: 0, weightBoost: boost)
            return GlyphShape.centeredPair(hS, mS)
        }
        let textAlpha = 0.72 + 0.28 * rv
        switch clockStyle {
        case .bold, .thin:
            // Portraits：Compressed 半粗、頂到上緣（日期之下），佔到約 59% 的高度，下面留給島
            let (a, b) = tallPair(top: 100, height: 488, gap: 56, boost: clockStyle == .bold ? 0.1 : 0)
            drawClockDigits(g, [a, b], look: look, clear: islandClear(bg, now), frosted: backdrop, alpha: textAlpha)
        case .stacked:
            // 上時下分（X-Large 的排法），各一行
            let top = GlyphShape.clock(hh, look: look, height: 330, maxWidth: 820, at: CGPoint(x: 512, y: 132), anchorX: 0.5, weightBoost: 0.15)
            let bot = GlyphShape.clock(mm, look: look, height: 330, maxWidth: 820, at: CGPoint(x: 512, y: 500), anchorX: 0.5, weightBoost: 0.15)
            drawClockDigits(g, [top, bot], look: look, clear: islandClear(bg, now), frosted: backdrop, alpha: textAlpha)
            dateY = 84; islandAt = CGPoint(x: 512, y: 912); islandScale = 0.6; liveAt = CGPoint(x: 512, y: 880)
        case .compact:
            // 島是主角：上面一行不大的時間，島放大置中（字小，玻璃看不出來：一律實線，顏色照設定）
            let s = GlyphShape("\(hh):\(mm)", font: look.font.nsFont(150, weight: look.weight + 0.12), kern: -2).centered(at: CGPoint(x: 512, y: 236))
            fillShape(g, s, look.color(wallpaper: wallpaperTone(backdrop)).withAlphaComponent(0.8 + 0.2 * rv), shadow: 0.2)
            dateY = 110; islandAt = CGPoint(x: 512, y: 560); islandScale = 1.3; liveAt = CGPoint(x: 512, y: 600)
        }
        // 日期：一般字寬、半粗，像鎖定畫面
        drawCentered(g, Self.dateLine(date), font: FaceType.sf(clockStyle == .compact ? 40 : 34, .semibold), kern: 0.4, y: dateY,
                     color: NSColor.white.withAlphaComponent(0.66 + 0.3 * rv))

        return (islandAt, islandScale, liveAt)
    }

    /// 給光學玻璃的「清楚」背景：隨時段用壁紙本身；照片、Flow、純色當場取一張 512² 的
    private func islandClear(_ bg: IslandBackground, _ now: Double) -> CGImage? {
        if bg == .daytime { return islandLookImage(lifted: true) }
        return snapshotBackdrop(px: 512) { c in self.drawIslandBackground(c, bg, now) }
    }

    /// 給玻璃數字折射用的背景（模糊過）
    private func islandBackdrop(_ bg: IslandBackground, _ now: Double) -> CGImage? {
        switch bg {
        case .daytime: return islandLookImage(lifted: false)   // 平滑漸層：模糊與否一樣，直接拿同一張
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

    /// 「隨時段」背景（2026）：照現在 Look 的四層色票畫一道乾淨的直向漸層，不疊光團、不跟游標漂。
    /// 彩色數字版：上深（數字色壓暗）→ 中淺（數字色帶底色）→ 下暖（強調色帶底色），像晨昏的天空；
    /// 材質底版：同一個底色由淺到深。時段只調明暗（夜裡暗下來），色相永遠是 Look 的。
    func drawIslandLookGradient(_ g: CGContext) {
        let stops = Self.islandLookStops(HPLook.current, hour: hourNow)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let gr = CGGradient(colorsSpace: cs, colors: stops.map { $0.1.cgColor } as CFArray, locations: stops.map { $0.0 }) else { return }
        g.drawLinearGradient(gr, start: .zero, end: CGPoint(x: 0, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func islandLookStops(_ l: HVTruth.Look, hour: Double) -> [(CGFloat, NSColor)] {
        func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
            let a = a.usingColorSpace(.sRGB) ?? a, b = b.usingColorSpace(.sRGB) ?? b
            return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t, green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                           blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
        }
        // 時段明暗：白天 1、深夜 0.5，清晨與傍晚平滑過渡
        let h = hour.truncatingRemainder(dividingBy: 24)
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        let day = h < 12 ? smooth(4.5, 8, h) : 1 - smooth(17.5, 21.5, h)
        let lum = CGFloat(0.5 + 0.5 * day)
        let black = NSColor.black, white = NSColor.white
        let raw: [(CGFloat, NSColor)]
        if l.numerals == 0x000000 {   // 材質底版：同色由淺到深
            let b = l.background_color
            raw = [(0, mix(b, white, 0.10)), (0.55, mix(b, black, 0.12)), (1, mix(b, black, 0.34))]
        } else {                      // 彩色數字版
            // 拍板 2026-11-07：回 beta 1 的乾淨深底——單色相由深到更深，下緣不再染強調色（橘 Look 下緣發棕的來源）
            let n = l.numerals_color, b = l.background_color
            let base = mix(n, b, 0.15)
            raw = [(0, mix(base, black, 0.60)), (0.6, mix(base, black, 0.42)), (1, mix(base, black, 0.26))]
        }
        return raw.map { ($0.0, mix(black, $0.1, lum)) }
    }

    /// 給玻璃取樣的同一張漸層（256²，按 Look 與時段快取）。lifted：給玻璃大數字折射用的，整張提亮一層——
    /// 照官方照片錶面，數字要比底亮一階、亮緣清楚（玻璃參數不動，只在這個錶面調背景）
    private func islandLookImage(lifted: Bool) -> CGImage {
        let key = "look|\(HPLook.name)|\(Int(hourNow * 4))|\(lifted)|\(HPAccessibility.increaseContrast)"
        if lifted, let c = islandLiftedCache, c.key == key { return c.image }
        if !lifted, let c = islandGlassCache, c.key == key { return c.image }
        let lift: CGFloat = HPAccessibility.increaseContrast ? 0.4 : 0.3
        let img = snapshotBackdrop(px: 256) { c in
            self.drawIslandLookGradient(c)
            if lifted { c.setFillColor(NSColor(white: 1, alpha: lift).cgColor); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
        }
        if lifted { islandLiftedCache = (key, img) } else { islandGlassCache = (key, img) }
        return img
    }
}
