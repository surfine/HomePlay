// HPDS 第三輪（R15）：App 用的元件——計時器刻度圈、照片上的 vibrancy 字、媒體頁頂列、照片上的寬玻璃膠囊、
// 家庭的染色磚與對講符號、類比時鐘磚、會淡入淡出的控制（chrome）。數字都在 HPTokens+Apps.swift。

import AppKit

extension HPComponents {
    // MARK: 計時器刻度圈

    /// 從 c 沿角度 a（0＝12 點、順時針）射出去，碰到「內縮 inset、圓角 radius、跟 1024 畫布同心」的圓角方形的距離
    static func rayToRoundedSquare(_ a: CGFloat, inset: CGFloat, radius: CGFloat) -> CGFloat {
        let half = 512 - inset
        let dx = abs(sin(a)), dy = abs(cos(a))
        let t = half / max(dx, dy)
        let core = half - radius
        if dx * t <= core || dy * t <= core { return t }       // 直邊
        // 角：圓心 (core, core)，解 |t·d − k| = R
        let kd = (dx + dy) * core
        let disc = kd * kd - 2 * core * core + radius * radius
        return kd + sqrt(max(0, disc))
    }

    /// 60 根徑向刻度：12 點起順時針，前 lit 根用 color，其餘用 color × elapsedAlpha（官方：過去的從 12 點往逆時針那側暗掉）
    static func tickRing(_ g: CGContext, lit: Int, color: NSColor, count: Int = HPTokens.TimerFace.ticks) {
        typealias T = HPTokens.TimerFace
        g.saveGState()
        g.setLineCap(.round); g.setLineWidth(T.tickWidth)
        let dim = color.withAlphaComponent(T.elapsedAlpha)
        for i in 0..<count {
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi
            let r0 = rayToRoundedSquare(a, inset: T.outerInset, radius: T.outerRadius)
            let r1 = rayToRoundedSquare(a, inset: T.innerInset, radius: T.innerRadius)
            let d = CGPoint(x: sin(a), y: -cos(a))
            g.setStrokeColor((i < lit ? color : dim).cgColor)
            g.move(to: CGPoint(x: 512 + d.x * r0, y: 512 + d.y * r0))
            g.addLine(to: CGPoint(x: 512 + d.x * r1, y: 512 + d.y * r1))
            g.strokePath()
        }
        g.restoreGState()
    }

    // MARK: 照片上的字

    /// 照片上的次要文字：白色 plusLighter（vibrancy），底下是什麼顏色就透出什麼（官方食譜副標）
    static func vibrantText(_ g: CGContext, _ face: Face, _ s: String, font: NSFont, x: CGFloat, y: CGFloat,
                            alpha: CGFloat = HPTokens.Media.vibrantAlpha) {
        g.saveGState()
        g.setBlendMode(.plusLighter)
        face.drawLeft(g, s, font: font, x: x, y: y, color: NSColor.white.withAlphaComponent(alpha))
        g.restoreGState()
    }

    /// 照片／媒體頁的頂列：左上 Clear 玻璃 ✕（Media.backButton）、右上白色時間（Media.clock*）。presence 0…1＝淡入淡出
    static func mediaTopBar(_ g: CGContext, _ face: Face, symbol: String = "xmark", clock: Bool = true, presence: CGFloat = 1) {
        typealias M = HPTokens.Media
        guard presence > 0.01 else { return }
        let r = M.backButton
        if let name = HPAX.symbolLabel(symbol, rect: r) { HPAX.note(g, r, .button, name, shape: .circle) }   // 2.0 depth：VoiceOver
        mediaDim(g, r)
        HPGlass.addCapsule(r, interactive: true, presence: presence) { [weak face] c in
            let s = r.width * M.backSymbolScale
            face?.drawSymbol(c, symbol, in: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s),
                             color: NSColor.white.withAlphaComponent(presence), weight: .medium)
        }
        if clock {
            let s = Face.statusClock(Face.displayDate), f = FaceType.sf(M.clockSize, .semibold)
            face.drawLeft(g, s, font: f, x: M.clockRight - Typo.width(s, f), y: M.clockBaseline, color: NSColor.white.withAlphaComponent(presence))
        }
    }
    /// 分頁式全螢幕的頂列（淺色／深色畫面上）：左上 Regular 玻璃 ✕、中央小標＋頁點、右上時間（影片 v1 00:27.25 食譜步驟）
    static func pageTopBar(_ g: CGContext, _ face: Face, title: String, pages: Int, page: Int, symbol: String = "xmark") {
        typealias M = HPTokens.Media
        let r = M.backButton
        if let name = HPAX.symbolLabel(symbol, rect: r) { HPAX.note(g, r, .button, name, shape: .circle) }   // 2.0 depth：VoiceOver
        HPAX.note(g, CGRect(x: 512 - 280, y: M.pageTitleBaseline - 44, width: 560, height: 66), .heading, title)
        HPGlass.addCapsule(r, interactive: true) { [weak face] c in
            let s = r.width * M.backSymbolScale * 0.9
            face?.drawSymbol(c, symbol, in: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s), color: HPGlass.ink, weight: .medium)
        }
        let tf = sf(M.pageTitleSize, weight: .semibold)
        center(g, face, Face.clipped(title, tf, 560), tf, cx: 512, y: M.pageTitleBaseline, label)
        let n = min(pages, 24)
        if n > 1 {
            let w = CGFloat(n) * M.pageDot + CGFloat(n - 1) * M.pageDotGap
            for k in 0..<n {
                g.setFillColor((k == min(page, n - 1) ? label : tertiary).cgColor)
                g.fillEllipse(in: CGRect(x: 512 - w / 2 + CGFloat(k) * (M.pageDot + M.pageDotGap), y: M.pageDotsY - M.pageDot / 2, width: M.pageDot, height: M.pageDot))
            }
        }
        let s = Face.statusClock(Face.displayDate), f = FaceType.sf(M.clockSize, .semibold)
        face.drawLeft(g, s, font: f, x: M.clockRight - Typo.width(s, f), y: M.clockBaseline, color: label)
    }
    static func hitMediaBack(_ p: CGPoint) -> Bool { HPTokens.Media.backButton.insetBy(dx: -8, dy: -8).contains(p) }

    /// 照片上的寬玻璃膠囊（Clear＋依亮度壓暗，白色 regular 字＋符號置中）：官方食譜「Ingredients／Start Cooking」
    static func mediaCapsule(_ g: CGContext, _ face: Face, _ r: CGRect, _ title: String, symbol: String?,
                             size: CGFloat = HPTokens.RecipeCover.buttonLabelSize, symbolSize: CGFloat = HPTokens.RecipeCover.buttonSymbolSize) {
        HPAX.note(g, r, .button, title)   // 2.0 depth：VoiceOver
        glassCapsule(g, r, tint: mediaTint) { c in
            let f = fitted(title, size: size, weight: .regular, maxWidth: r.width - 80 - (symbol == nil ? 0 : symbolSize + 14))
            let t = Face.clipped(title, f, r.width - 80 - (symbol == nil ? 0 : symbolSize + 14))
            let sw: CGFloat = symbol == nil ? 0 : symbolSize + 14
            var x = r.midX - (sw + Typo.width(t, f)) / 2
            if let symbol {
                face.drawSymbol(c, symbol, in: CGRect(x: x, y: r.midY - symbolSize / 2, width: symbolSize, height: symbolSize), color: .white, weight: .regular)
                x += sw
            }
            face.drawLeft(c, t, font: f, x: x, y: r.midY + f.capHeight / 2, color: .white)
        }
    }

    // MARK: 家庭磚（官方 home-light：開＝家的顏色淡底、關＝淺灰；磚是內容層，不進玻璃）

    struct DashTileStyle { var fill: NSColor; var ink: NSColor; var sub: NSColor }
    static func dashTileStyle(on: Bool) -> DashTileStyle {
        typealias H = HPTokens.HomeGrid
        return on ? DashTileStyle(fill: H.onFill, ink: H.onInk, sub: H.onSub) : DashTileStyle(fill: H.offFill, ink: H.offInk, sub: H.offSub)
    }
    /// 一塊磚：底（按下放大 1.08 變亮）＋ glyph（畫在 glyphRect 裡）＋兩行置中標籤。fill＝nil 不畫底（時鐘、照片磚）
    static func dashTile(_ g: CGContext, _ face: Face, _ r: CGRect, fill: NSColor?, title: String?, subtitle: String?,
                         ink: NSColor, sub: NSColor, glyph: ((CGContext, CGRect) -> Void)? = nil) {
        typealias H = HPTokens.HomeGrid
        let k = Press.scale(r), rr = k == 1 ? r : scaled(r, k)
        let path = continuousRoundedRect(rr, radius: H.radius * k)
        if let fill {
            g.addPath(path); g.setFillColor(fill.cgColor); g.fillPath()
            if Press.amount(r) > 0.01 { g.addPath(path); g.setFillColor(NSColor(white: 1, alpha: 0.25 * Press.amount(r)).cgColor); g.fillPath() }
        }
        g.saveGState()
        if k != 1 { g.translateBy(x: r.midX, y: r.midY); g.scaleBy(x: k, y: k); g.translateBy(x: -r.midX, y: -r.midY) }
        let hasText = title != nil
        let gy = hasText ? r.minY + H.glyphCenterY * r.height / H.tile : r.midY
        let gs = H.glyphSize * r.height / H.tile
        glyph?(g, CGRect(x: r.midX - gs, y: gy - gs / 2, width: gs * 2, height: gs))
        if let title {
            let w = r.width - 36
            let tf = fitted(title, size: H.titleSize, weight: .semibold, maxWidth: w)
            center(g, face, Face.clipped(title, tf, w), tf, cx: r.midX, y: r.minY + H.titleBaseline, ink)
        }
        if let subtitle {
            let w = r.width - 36
            let sf = fitted(subtitle, size: H.subtitleSize, weight: .regular, maxWidth: w)
            center(g, face, Face.clipped(subtitle, sf, w), sf, cx: r.midX, y: r.minY + H.subtitleBaseline, sub)
        }
        g.restoreGState()
    }
    /// SF Symbol 畫在磚的圖示框裡（高＝框高 × scale，寬自動；官方「家庭」磚的房子是一般圖示的 1.55 倍）
    static func dashSymbol(_ face: Face, _ name: String, color: NSColor, weight: NSFont.Weight = .regular, scale: CGFloat = 1) -> (CGContext, CGRect) -> Void {
        { [weak face] g, r in
            let rr = scale == 1 ? r : CGRect(x: r.midX - r.width * scale / 2, y: r.midY - r.height * scale / 2, width: r.width * scale, height: r.height * scale)
            face?.drawSymbol(g, name, in: rr, color: color, weight: weight)
        }
    }
    /// 對講（官方磚的符號）：7 條直線，高度照一個圓取樣，像喇叭網
    static func intercomGlyph(color: NSColor) -> (CGContext, CGRect) -> Void {
        { g, r in
            let rad = r.height * 0.41, step = rad * 0.295, w = rad * 0.14
            g.saveGState(); g.setStrokeColor(color.cgColor); g.setLineWidth(w); g.setLineCap(.round)
            for i in -3...3 {
                let x = CGFloat(i) * step
                let h = sqrt(max(0, rad * rad - x * x)) - w / 2
                g.move(to: CGPoint(x: r.midX + x, y: r.midY - h)); g.addLine(to: CGPoint(x: r.midX + x, y: r.midY + h)); g.strokePath()
            }
            g.restoreGState()
        }
    }

    /// 類比時鐘磚（官方家庭左上）：沒有底，刻度與數字用家的顏色、時針分針深色、秒針家的顏色
    static func analogClockTile(_ g: CGContext, _ face: Face, _ r: CGRect, date: Date, tint: NSColor, hands: NSColor) {
        let c = CGPoint(x: r.midX, y: r.midY), R = r.width / 2 - 8
        let cal = Calendar.current
        let h = CGFloat(cal.component(.hour, from: date) % 12), m = CGFloat(cal.component(.minute, from: date)), s = CGFloat(cal.component(.second, from: date))
        g.saveGState()
        g.setLineCap(.round)
        // 60 格刻度：整點長、其餘短（官方：外緣在半徑 R、長 13；數字半徑 0.77 R）
        for i in 0..<60 {
            let a = CGFloat(i) / 60 * 2 * .pi, d = CGPoint(x: sin(a), y: -cos(a))
            let len: CGFloat = i % 5 == 0 ? 13 : 9
            g.setStrokeColor(tint.withAlphaComponent(i % 5 == 0 ? 0.55 : 0.4).cgColor); g.setLineWidth(i % 5 == 0 ? 3.4 : 2.4)
            g.move(to: CGPoint(x: c.x + d.x * R, y: c.y + d.y * R)); g.addLine(to: CGPoint(x: c.x + d.x * (R - len), y: c.y + d.y * (R - len))); g.strokePath()
        }
        let nf = FaceType.sf(R * 0.25, .regular, mono: false)
        for n in 1...12 {
            let a = CGFloat(n) / 12 * 2 * .pi, rr = R * 0.755
            let s = String(n)
            face.drawLeft(g, s, font: nf, x: c.x + sin(a) * rr - Typo.width(s, nf) / 2, y: c.y - cos(a) * rr + nf.capHeight / 2, color: tint)
        }
        func hand(_ a: CGFloat, _ len: CGFloat, _ w: CGFloat, _ col: NSColor, back: CGFloat = 0) {
            g.setStrokeColor(col.cgColor); g.setLineWidth(w)
            g.move(to: CGPoint(x: c.x - sin(a) * back, y: c.y + cos(a) * back)); g.addLine(to: CGPoint(x: c.x + sin(a) * len, y: c.y - cos(a) * len)); g.strokePath()
        }
        // 時針、分針：中心一小段細，外段粗（iOS 時鐘的針）
        for (a, len) in [((h + m / 60) / 12 * 2 * .pi, R * 0.5), ((m + s / 60) / 60 * 2 * .pi, R * 0.84)] {
            hand(a, R * 0.12, 4, hands)
            g.setStrokeColor(hands.cgColor); g.setLineWidth(11)
            g.move(to: CGPoint(x: c.x + sin(a) * R * 0.12, y: c.y - cos(a) * R * 0.12)); g.addLine(to: CGPoint(x: c.x + sin(a) * len, y: c.y - cos(a) * len)); g.strokePath()
        }
        hand(s / 60 * 2 * .pi, R * 0.98, 2.4, tint, back: R * 0.16)
        g.setFillColor(hands.cgColor); g.fillEllipse(in: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
        g.setFillColor(tint.cgColor); g.fillEllipse(in: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7))
        g.restoreGState()
    }

    // MARK: 會收起來的控制（chrome）

    /// 閒置就收起、點一下浮出的控制層（計時器、正在播放的全版封面）。value(now) 給 0…1 的出現程度（彈簧）
    struct Chrome {
        private(set) var visible: Bool
        private var lastTouch: Double
        let idle: Double
        private var anim: Anim
        init(visible: Bool, idle: Double, now: Double = CACurrentMediaTime(), name: String) {
            self.visible = visible; self.idle = idle; lastTouch = now
            anim = Anim(visible ? 1 : 0, spring: AppMotion.appleSmooth, name: name)
        }
        /// 點了一下：收著就浮出（回 true＝這一下只是叫出控制，不要再當成按鈕）；開著就延長
        mutating func touch(_ now: Double) -> Bool {
            lastTouch = now
            guard !visible else { return false }
            visible = true; anim.retarget(1, now: now); return true
        }
        mutating func show(_ now: Double) { lastTouch = now; if !visible { visible = true; anim.retarget(1, now: now) } }
        mutating func hide(_ now: Double) { if visible { visible = false; anim.retarget(0, now: now) } }
        /// 每幀：閒置到了就收；回 true＝還在動（要重畫）
        mutating func tick(_ now: Double) -> Bool {
            if visible, idle > 0, now - lastTouch > idle { visible = false; anim.retarget(0, now: now) }
            return !anim.done(now)
        }
        func value(_ now: Double) -> CGFloat { max(0, min(1, anim.value(now))) }
    }
}

extension HPComponents {
    /// 主要動作圓鈕的淡入淡出版（presence < 1 時照 materialize 長出；= 1 就是一般的 actionButton，含按下狀態）
    static func actionButton(_ g: CGContext, _ face: Face, _ r: CGRect, symbol: String, role: Role, presence: CGFloat) {
        guard presence > 0.01 else { return }
        if presence >= 0.99 { actionButton(g, face, r, symbol: symbol, role: role); return }
        var tint: NSColor?, ink: NSColor = .white
        switch role {
        case .stop: tint = red
        case .mic: tint = yellow; ink = .black
        case .start: tint = green
        case .primary(let c): tint = c
        case .glass: tint = nil; ink = label
        }
        let k = 0.96 + 0.04 * presence, rr = scaled(r, k)
        HPGlass.addCapsule(rr, tint: tint, interactive: true, presence: presence) { [weak face] c in
            let s = r.width * 0.36 * k
            face?.drawSymbol(c, symbol, in: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s), color: ink.withAlphaComponent(presence), weight: .semibold)
        }
    }
}

// MARK: - P10：地圖卡、大頭針、電平圈、玻璃網址膠囊

extension HPComponents {
    /// 程式畫的地圖（內容層，不上玻璃）：陸地、水、公園、街道格與一條主幹道。seed 決定街區排法；
    /// 色照 Apple 地圖的標準樣式（淺：米白陸地、淡藍水、淡綠公園、白路；深：炭灰陸地、深藍水）
    static func mapCard(_ g: CGContext, _ r: CGRect, radius: CGFloat = HPTokens.Radius.group, seed: Int = 1) {
        let dark = HPTokens.dark
        let land = dark ? srgb(0x2A2C30) : srgb(0xF4F1EA), water = dark ? srgb(0x1B3247) : srgb(0xAAD3F2)
        let park = dark ? srgb(0x23382B) : srgb(0xCFE7C3), road = dark ? srgb(0x44474E) : srgb(0xFFFFFF)
        let casing = dark ? srgb(0x1E1F22) : srgb(0xDCD8CF), major = dark ? srgb(0x6B5F3E) : srgb(0xFBE3A0)
        var rng = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 97)
        func rnd() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((rng >> 33) % 10000) / 10000 }
        g.saveGState()
        g.addPath(continuousRoundedRect(r, radius: radius)); g.clip()
        g.setFillColor(land.cgColor); g.fill(r)
        // 水：右下一片海灣
        let bay = CGMutablePath()
        bay.move(to: CGPoint(x: r.maxX, y: r.minY + r.height * (0.35 + 0.2 * rnd())))
        bay.addCurve(to: CGPoint(x: r.minX + r.width * (0.55 + 0.1 * rnd()), y: r.maxY),
                     control1: CGPoint(x: r.maxX - r.width * 0.25, y: r.minY + r.height * 0.5),
                     control2: CGPoint(x: r.minX + r.width * 0.75, y: r.maxY - r.height * 0.25))
        bay.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); bay.closeSubpath()
        g.addPath(bay); g.setFillColor(water.cgColor); g.fillPath()
        // 公園
        for _ in 0..<2 {
            let w = r.width * (0.12 + 0.1 * rnd()), h = r.height * (0.18 + 0.15 * rnd())
            let pr = CGRect(x: r.minX + r.width * 0.6 * rnd(), y: r.minY + r.height * 0.6 * rnd(), width: w, height: h)
            g.addPath(continuousRoundedRect(pr, radius: 18)); g.setFillColor(park.cgColor); g.fillPath()
        }
        // 街道格（稍微斜一點，比較像真的城市）
        g.saveGState()
        g.translateBy(x: r.midX, y: r.midY); g.rotate(by: (rnd() - 0.5) * 0.35); g.translateBy(x: -r.midX, y: -r.midY)
        g.setLineCap(.round)
        let step = 92 + 30 * rnd()
        for pass in 0..<2 {
            g.setStrokeColor((pass == 0 ? casing : road).cgColor); g.setLineWidth(pass == 0 ? 15 : 11)
            var x = r.minX - r.width * 0.3
            while x < r.maxX + r.width * 0.3 { g.move(to: CGPoint(x: x, y: r.minY - 200)); g.addLine(to: CGPoint(x: x, y: r.maxY + 200)); x += step }
            var y = r.minY - r.height * 0.5
            while y < r.maxY + r.height * 0.5 { g.move(to: CGPoint(x: r.minX - 300, y: y)); g.addLine(to: CGPoint(x: r.maxX + 300, y: y)); y += step * 0.8 }
            g.strokePath()
        }
        // 主幹道：一條斜穿的黃路
        let p0 = CGPoint(x: r.minX - 40, y: r.minY + r.height * (0.6 + 0.3 * rnd())), p1 = CGPoint(x: r.maxX + 40, y: r.minY + r.height * 0.2 * rnd())
        g.setStrokeColor(casing.cgColor); g.setLineWidth(26); g.move(to: p0); g.addLine(to: p1); g.strokePath()
        g.setStrokeColor(major.cgColor); g.setLineWidth(20); g.move(to: p0); g.addLine(to: p1); g.strokePath()
        g.restoreGState()
        // 水蓋在路上面（路不過海）
        g.addPath(bay); g.setFillColor(water.cgColor); g.fillPath()
        g.restoreGState()
    }

    /// 「我」的位置：白圈藍點＋淡藍光暈（iOS 定位點）
    static func meDot(_ g: CGContext, at c: CGPoint, size: CGFloat = 40) {
        g.setFillColor(blue.withAlphaComponent(0.18).cgColor)
        g.fillEllipse(in: CGRect(x: c.x - size * 1.4, y: c.y - size * 1.4, width: size * 2.8, height: size * 2.8))
        g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.25).cgColor)
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
        g.restoreGState()
        let i = size * 0.72
        g.setFillColor(blue.cgColor); g.fillEllipse(in: CGRect(x: c.x - i / 2, y: c.y - i / 2, width: i, height: i))
    }

    /// 「尋找」的大頭針：白圈、裡面一顆色圓（裝置符號，或人的縮寫）、底下一個小尖（尖端在 tip）
    static func mapPin(_ g: CGContext, _ face: Face, tip: CGPoint, symbol: String? = nil, initials: String? = nil, tint: NSColor,
                       size: CGFloat = HPTokens.FindMy.pin, inner: CGFloat = HPTokens.FindMy.pinInner) {
        let c = CGPoint(x: tip.x, y: tip.y - size / 2 - 12)
        let body = CGMutablePath()
        body.addEllipse(in: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
        body.move(to: CGPoint(x: c.x - 13, y: c.y + size / 2 - 6)); body.addLine(to: tip); body.addLine(to: CGPoint(x: c.x + 13, y: c.y + size / 2 - 6)); body.closeSubpath()
        g.saveGState(); HPTokens.Shadow.card.apply(g)
        g.addPath(body); g.setFillColor(NSColor.white.cgColor); g.fillPath()
        g.restoreGState()
        let ir = CGRect(x: c.x - inner / 2, y: c.y - inner / 2, width: inner, height: inner)
        g.setFillColor(tint.cgColor); g.fillEllipse(in: ir)
        if let s = symbol { face.drawSymbol(g, s, in: ir.insetBy(dx: inner * 0.24, dy: inner * 0.24), color: .white) }
        else if let t = initials {
            let f = sf(inner * 0.42, weight: .semibold)
            face.drawLeft(g, t, font: f, x: c.x - Typo.width(t, f) / 2, y: c.y + f.capHeight / 2, color: .white)
        }
    }

    /// 電平圈：count 根直條排成圓（照對講圖示），levels 是最近的電平（0…1，新的在最後），從 12 點順時針鋪；
    /// 沒聲音時是短短一圈淡點，說話時往外長
    static func levelRing(_ g: CGContext, center c: CGPoint, inner: CGFloat, outer: CGFloat, levels: [CGFloat], color: NSColor,
                          count: Int = HPTokens.Intercom.bars) {
        g.saveGState(); g.setLineCap(.round); g.setLineWidth(10)
        for i in 0..<count {
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi, d = CGPoint(x: sin(a), y: -cos(a))
            let idx = levels.count - count + i
            let v = idx >= 0 && idx < levels.count ? max(0, min(1, levels[idx])) : 0
            let len = 8 + (outer - inner - 8) * v
            g.setStrokeColor(color.withAlphaComponent(0.28 + 0.72 * v).cgColor)
            g.move(to: CGPoint(x: c.x + d.x * inner, y: c.y + d.y * inner))
            g.addLine(to: CGPoint(x: c.x + d.x * (inner + len), y: c.y + d.y * (inner + len)))
            g.strokePath()
        }
        g.restoreGState()
    }

    /// 玻璃網址／搜尋膠囊（iOS 27 Safari 底欄中間那塊）：左邊放大鏡或頁面鈕、中間網域或提示字、右邊重新載入；progress 0…1 時底緣一條藍線
    static func glassField(_ g: CGContext, _ face: Face, _ r: CGRect, text: String, placeholder: Bool, leading: String?, trailing: String?,
                           progress: CGFloat? = nil, label a11y: String) {
        HPAX.note(g, r, .button, a11y)
        glassCapsule(g, r) { c in
            let ink = HPGlass.ink
            let sym = r.height * 0.36
            var x = r.minX + r.height * 0.36
            if let l = leading {
                face.drawSymbol(c, l, in: CGRect(x: x, y: r.midY - sym / 2, width: sym, height: sym), color: ink)
                x += sym + 18
            }
            let right = r.maxX - r.height * 0.36 - (trailing == nil ? 0 : sym + 18)
            let f = fitted(text, size: 34, weight: placeholder ? .regular : .semibold, maxWidth: right - x)
            let t = Face.clipped(text, f, right - x)
            let tx = placeholder || leading == nil ? x : max(x, r.midX - Typo.width(t, f) / 2)
            face.drawLeft(c, t, font: f, x: tx, y: r.midY + f.capHeight / 2, color: placeholder ? ink.withAlphaComponent(0.55) : ink)
            if let tr = trailing {
                face.drawSymbol(c, tr, in: CGRect(x: r.maxX - r.height * 0.36 - sym, y: r.midY - sym / 2, width: sym, height: sym), color: ink)
            }
            if let p = progress, p > 0, p < 1 {
                c.setFillColor(blue.cgColor)
                c.saveGState(); c.addPath(capsulePath(r)); c.clip()
                c.fill(CGRect(x: r.minX, y: r.maxY - 6, width: r.width * p, height: 6)); c.restoreGState()
            }
        }
    }
}
