// 手勢引導的畫面（狀態與文案在 IntroGuide.swift）。設計稿是 512 的方塊：畫的時候整面縮放 ×2 到 1024 畫布，
// 數值直接照稿寫；👀 膠囊用桌寵自己的膠囊與眼睛（不改造型，材質跟錶面的年代），在 1024 座標畫。
// 示範動畫照稿的時間軸與 easing：移動 cubic-bezier(0.77,0,0.175,1)、抽屜／卡片 (0.32,0.72,0,1)、進出場 (0.23,1,0.32,1)。
// 減少動態效果：示範改成前後兩格靜態對照、中間淡入淡出；換頁只淡入。減少透明度：字卡不透明；增加對比：字卡描邊、次要字加深。
// 字卡內縮 32（1024）→ 圓角 HPTokens.Radius.concentric（跟機身同心，登記在 Design/EdgeContainers.swift）。

import AppKit

/// CSS 的 cubic-bezier(x1, y1, x2, y2)
struct IntroEase {
    let x1, y1, x2, y2: Double
    static let move = IntroEase(x1: 0.77, y1: 0, x2: 0.175, y2: 1)
    static let drawer = IntroEase(x1: 0.32, y1: 0.72, x2: 0, y2: 1)
    static let enter = IntroEase(x1: 0.23, y1: 1, x2: 0.32, y2: 1)

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bx(_ t: Double) -> Double { let u = 1 - t; return 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { let u = 1 - t; return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {   // 二分：x(t) 單調
            if bx(t) < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return by(t)
    }

    /// 關鍵影格：stops＝[(位置 0…1, 值)]，每一段各自套 easing（同 CSS 的 animation-timing-function）
    func key(_ p: Double, _ stops: [(Double, Double)]) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if p <= first.0 { return first.1 }
        if p >= last.0 { return last.1 }
        for i in 1..<stops.count where p <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            let k = b.0 > a.0 ? self((p - a.0) / (b.0 - a.0)) : 1
            return a.1 + (b.1 - a.1) * k
        }
        return last.1
    }
}

/// 淺／深色、增加對比、減少透明度的配色
struct IntroPalette {
    let dark: Bool, ic: Bool, rt: Bool
    init() { dark = HPTokens.dark; ic = HPAccessibility.increaseContrast; rt = HPAccessibility.reduceTransparency }

    var bg: [NSColor] { dark ? [srgb(0x1c2a4e), srgb(0x3a3466), srgb(0x7b5b70)] : [srgb(0xdde6f6), srgb(0xe6dff2), srgb(0xf4e0e7)] }
    var ink: NSColor { dark ? .white : srgb(0x1d1d1f) }
    var ink2: NSColor { ink.withAlphaComponent(ic ? 0.92 : (dark ? 0.75 : 0.66)) }
    var hair: NSColor { ink.withAlphaComponent(ic ? 0.4 : 0.1) }
    /// 字卡（設計稿 rgba(14,16,32,.5)；淺色是白霧）
    func card(_ a: CGFloat = 0.5) -> NSColor {
        if rt { return dark ? srgb(0x22233a) : srgb(0xf8f8fb) }
        if dark { return NSColor(srgbRed: 14 / 255, green: 16 / 255, blue: 32 / 255, alpha: ic ? max(a, 0.78) : a) }
        return NSColor(white: 1, alpha: ic ? 0.92 : 0.66)
    }
    var cardStroke: NSColor { ic ? ink.withAlphaComponent(0.7) : (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.06)) }
    var dotOff: NSColor { ink.withAlphaComponent(ic ? 0.6 : 0.35) }
    /// 主要按鈕（白膠囊；淺色時反過來）
    var buttonFill: NSColor { dark ? .white : srgb(0x1d1d1f) }
    var buttonInk: NSColor { dark ? srgb(0x141428) : .white }
    /// 示範畫面裡的半透明方塊（控制中心模組、資源庫分類）
    var module: NSColor { dark ? NSColor(white: 1, alpha: rt ? 0.28 : 0.2) : NSColor(white: 1, alpha: rt ? 0.95 : 0.72) }
    var scrim: NSColor { dark ? NSColor(srgbRed: 8 / 255, green: 10 / 255, blue: 24 / 255, alpha: rt ? 0.8 : 0.45) : NSColor(white: 1, alpha: rt ? 0.8 : 0.45) }
    var switcherBG: NSColor { dark ? srgb(0x101225) : srgb(0xcfd2de) }
}

extension Face {
    /// 引導的外框（1024）：示範用的 512 稿 ×2
    private static let introK: CGFloat = 2
    private static func c(_ r: CGRect) -> CGRect { CGRect(x: r.minX * introK, y: r.minY * introK, width: r.width * introK, height: r.height * introK) }

    /// 字卡（512 稿：left 16 right 16 bottom 16 高 132）：框與圓角給 EdgeContainers 登記
    static let introCaption = CGRect(x: 32, y: 728, width: 960, height: 264)
    /// 清單卡（其他手勢：left 24 right 24 top 104 bottom 24）
    static let introList = CGRect(x: 48, y: 208, width: 928, height: 768)
    /// 動作表（桌寵本身：left 24 right 24 bottom 24；比稿高一點，放得下頁點、略過、下一個）
    static let introTable = CGRect(x: 48, y: 490, width: 928, height: 486)
    static func introRadius(_ r: CGRect) -> CGFloat { HPTokens.Radius.concentric(rect: r) }

    // MARK: 進入點（Face.render 疊在最上層）

    func drawIntroGuide(_ g: CGContext, _ now: Double) {
        let G = IntroGuide.self
        let closing = !Onboarding.active && now - G.closedAt < G.fadeOut && !HPMotion.reduceMotion
        guard Onboarding.active || closing else { return }
        if Onboarding.active { G.hits = []; G.texts = [] }
        let pal = IntroPalette()
        let rm = HPMotion.reduceMotion
        var alpha: CGFloat = 1
        if closing { alpha = CGFloat(1 - IntroEase.enter((now - G.closedAt) / G.fadeOut)) }
        else if now - G.openedAt < 0.4 { alpha = CGFloat(IntroEase.enter((now - G.openedAt) / 0.4)) }
        HPGlass.flush(g, face: self)   // 底下的玻璃先畫掉（等一下整面蓋住）
        g.saveGState()
        if alpha < 1 { g.setAlpha(alpha); g.beginTransparencyLayer(auxiliaryInfo: nil) }
        introBackground(g, pal)
        // 換頁：新的一頁從行進方向滑進來並淡入（減少動態效果：只淡入）
        let raw = min(1, max(0, (now - G.pageAt) / G.transition))
        let p = CGFloat(1 - pow(1 - raw, 3))
        g.saveGState()
        if p < 1 { g.setAlpha(p); g.beginTransparencyLayer(auxiliaryInfo: nil) }
        if !rm, p < 1 { g.translateBy(x: (1 - p) * 96 * G.direction, y: 0) }
        introPage(g, now, pal, rm: rm)
        if p < 1 { g.endTransparencyLayer() }
        g.restoreGState()
        if alpha < 1 { g.endTransparencyLayer() }
        g.restoreGState()
    }

    private func introBackground(_ g: CGContext, _ pal: IntroPalette) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 160deg：從左上偏上到右下偏下
        guard let grad = CGGradient(colorsSpace: cs, colors: pal.bg.map(\.cgColor) as CFArray, locations: [0, 0.48, 1]) else { return }
        let a = 160 * Double.pi / 180, dx = CGFloat(sin(a)), dy = CGFloat(-cos(a))
        let half = 512 * (abs(dx) + abs(dy))
        g.drawLinearGradient(grad, start: CGPoint(x: 512 - dx * half, y: 512 - dy * half), end: CGPoint(x: 512 + dx * half, y: 512 + dy * half),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func introPage(_ g: CGContext, _ now: Double, _ pal: IntroPalette, rm: Bool) {
        let G = IntroGuide.self, page = G.page, input = G.input
        let t = G.clock(now)
        let sincePage = G.demo != nil ? 10 : now - G.pageAt
        // 示範（在 512 稿座標畫）：減少動態效果時前後兩格交叉淡入淡出
        func scene(_ phase: Double) {
            g.saveGState(); g.scaleBy(x: Self.introK, y: Self.introK)
            introScene(g, page, phase, input, pal, now: now)
            g.restoreGState()
        }
        if let st = page.stills, rm {
            let m = CGFloat(Self.introStillMix(now))
            for (q, a) in [(st.before, 1 - m), (st.after, m)] where a > 0.001 {
                g.saveGState(); g.setAlpha(a); g.beginTransparencyLayer(auxiliaryInfo: nil)
                scene(q)
                g.endTransparencyLayer(); g.restoreGState()
            }
        } else if page != .welcome && page != .more {
            scene(t / page.loop)
        }
        // 👀 膠囊（1024 座標；回主畫面那頁會被往下拉一點）
        var capDY: CGFloat = 0
        if page == .home, !rm { capDY = 2 * CGFloat(IntroEase.move.key(t / page.loop, [(0.12, 0), (0.46, 16), (0.60, 0)])) }
        if page != .pet && page != .control { introCapsule(g, now, pal, dy: capDY, welcomePhase: page == .welcome && !rm ? t / page.loop : nil) }
        // 手指／游標在最上面（膠囊之後；桌寵本身那頁在機身之後畫）
        if page.stills != nil, page != .pet {
            g.saveGState(); g.scaleBy(x: Self.introK, y: Self.introK)
            introPointerLayer(g, page, t / page.loop, input, pal, now: now, rm: rm)
            g.restoreGState()
        }
        g.saveGState(); g.scaleBy(x: Self.introK, y: Self.introK)
        switch page {
        case .welcome: introWelcome(g, pal, since: sincePage, rm: rm)
        case .home, .switcher, .control, .swipe: introCaptionCard(g, page, input, pal)
        case .pet: introPet(g, t / page.loop, input, pal, now: now, rm: rm)
        case .more: introMore(g, input, pal, since: sincePage, rm: rm)
        }
        g.restoreGState()
    }

    /// 減少動態效果：3.2 s 一輪——前 1.2 s → 淡到後 0.4 s → 後 1.2 s → 淡回 0.4 s；回「後」那格的比重 0…1
    static func introStillMix(_ now: Double) -> Double {
        let c = (HPMotion.frozen("intro") ?? (IntroGuide.demo != nil ? 0 : now - IntroGuide.pageAt)).truncatingRemainder(dividingBy: 3.2)
        return c < 1.2 ? 0 : c < 1.6 ? (c - 1.2) / 0.4 : c < 2.8 ? 1 : 1 - (c - 2.8) / 0.4
    }

    /// 手指這一層：減少動態效果時只在「前」那格畫（「後」那格手指已經放開），跟著交叉淡出
    private func introPointerLayer(_ g: CGContext, _ page: IntroPage, _ phase: Double, _ input: IntroInput, _ pal: IntroPalette, now: Double, rm: Bool) {
        if let st = page.stills, rm {
            let m = Self.introStillMix(now)
            guard m < 0.999 else { return }
            g.saveGState(); g.setAlpha(CGFloat(1 - m)); introPointer(g, page, st.before, input, pal); g.restoreGState()
        } else {
            introPointer(g, page, phase, input, pal)
        }
    }

    // MARK: 共用小件（512 座標）

    private func introText(_ g: CGContext, _ s: String, _ font: NSFont, cx: CGFloat, y: CGFloat, _ color: NSColor) {
        drawLeft(g, s, font: font, x: cx - Typo.width(s, font) / 2, y: y, color: color)
    }
    private func introFit(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ maxW: CGFloat) -> NSFont {
        HPType.fitted(s, size: size, weight: weight, maxWidth: maxW, minScale: 0.62)
    }
    private func introFill(_ g: CGContext, _ r: CGRect, _ radius: CGFloat, _ color: NSColor) {
        g.addPath(continuousRoundedRect(r, radius: min(radius, min(r.width, r.height) / 2))); g.setFillColor(color.cgColor); g.fillPath()
    }
    private func introPill(_ g: CGContext, _ r: CGRect, _ color: NSColor) {
        g.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); g.setFillColor(color.cgColor); g.fillPath()
    }
    /// 字卡底：半透明＋細邊（增加對比：描邊加粗加深）
    private func introCard(_ g: CGContext, _ r1024: CGRect, _ pal: IntroPalette, alpha: CGFloat) {
        let r = CGRect(x: r1024.minX / 2, y: r1024.minY / 2, width: r1024.width / 2, height: r1024.height / 2)
        let rad = Self.introRadius(r1024) / 2
        let path = continuousRoundedRect(r, radius: rad)
        g.saveGState()
        if !pal.dark && !pal.rt { g.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: NSColor(white: 0, alpha: 0.08).cgColor) }
        g.addPath(path); g.setFillColor(pal.card(alpha).cgColor); g.fillPath()
        g.restoreGState()
        g.addPath(path); g.setStrokeColor(pal.cardStroke.cgColor); g.setLineWidth(pal.ic ? 1.5 : 0.5); g.strokePath()
    }
    private func introDots(_ g: CGContext, _ pal: IntroPalette, cy: CGFloat, current: IntroPage) {
        let n = IntroGuide.dotted.count, d: CGFloat = 7, gap: CGFloat = 8
        let w = CGFloat(n) * d + CGFloat(n - 1) * gap
        for (k, p) in IntroGuide.dotted.enumerated() {
            let r = CGRect(x: 256 - w / 2 + CGFloat(k) * (d + gap), y: cy - d / 2, width: d, height: d)
            g.setFillColor((p == current ? pal.ink : pal.dotOff).cgColor); g.fillEllipse(in: r)
        }
        let i = (IntroGuide.dotted.firstIndex(of: current) ?? 0) + 1
        introNote(.text, String(format: L("setup.pageOf", "第 %1$d 页，共 %2$d 页"), i, n), CGRect(x: 256 - w / 2 - 6, y: cy - 10, width: w + 12, height: 20))
    }
    /// 記一筆給 VoiceOver（512 座標進來，記成 1024）
    private func introNote(_ role: HPAXNote.Role, _ label: String, _ r: CGRect) {
        IntroGuide.texts.append((role: role, label: label, rect: Self.c(r)))
    }
    private func introHit(_ a: IntroGuide.Action, _ r: CGRect, _ label: String, selected: Bool? = nil) {
        IntroGuide.hits.append(IntroHitArea(action: a, rect: Self.c(r), label: label, selected: selected))
    }
    private func pressedAlpha(_ a: IntroGuide.Action) -> CGFloat { IntroGuide.pressed == a ? 0.55 : 1 }

    /// 下一個（右下角的 ›）與略過（左下角）
    private func introNav(_ g: CGContext, _ pal: IntroPalette, cy: CGFloat, nextX: CGFloat, skipX: CGFloat) {
        let nr = CGRect(x: nextX - 22, y: cy - 22, width: 44, height: 44)
        g.saveGState()
        g.setAlpha(pressedAlpha(.next))
        g.setStrokeColor(pal.ink.cgColor); g.setLineWidth(2.2); g.setLineCap(.round); g.setLineJoin(.round)
        g.move(to: CGPoint(x: nr.midX - 9 + 6.5, y: nr.midY - 9 + 3.5)); g.addLine(to: CGPoint(x: nr.midX - 9 + 12, y: nr.midY))
        g.addLine(to: CGPoint(x: nr.midX - 9 + 6.5, y: nr.midY - 9 + 14.5)); g.strokePath()
        g.restoreGState()
        introHit(.next, nr, L("intro.next", "下一个手势"))
        let s = L("intro.skip", "略过"), f = HPType.sf(15, .regular)
        let w = Typo.width(s, f) + 36
        let sr = CGRect(x: skipX - w / 2, y: cy - 22, width: w, height: 44)
        introText(g, s, f, cx: skipX, y: cy + 5, pal.ink2.withAlphaComponent(pal.ink2.alphaComponent * pressedAlpha(.skip)))
        introHit(.skip, sr, s)
    }

    // MARK: 👀 膠囊（1024）

    private func introCapsule(_ g: CGContext, _ now: Double, _ pal: IntroPalette, dy: CGFloat, welcomePhase: Double?) {
        let r = CGRect(x: 512 - 208, y: 48 + dy, width: 416, height: 124)
        var look = capsuleLook() == .system ? .black : capsuleLook()
        if pal.rt, look == .glass { look = .black }   // 減少透明度：膠囊不透
        drawCapsuleBody(g, r, look: look, animating: false)
        let pill = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        if let ph = welcomePhase {
            // 呼吸：內緣一圈白線 .38 → .5、外圈 0 → 20 px 的淡光（3.2 s 一輪）
            let b = CGFloat(IntroEase.move.key((ph * 4 / 3.2).truncatingRemainder(dividingBy: 1), [(0, 0), (0.5, 1), (1, 0)]))
            if b > 0.01 {
                g.saveGState()
                g.addRect(r.insetBy(dx: -60, dy: -60)); g.addPath(pill); g.clip(using: .evenOdd)   // 只畫在膠囊外面
                g.addPath(pill); g.setStrokeColor(NSColor(white: 1, alpha: 0.06).cgColor); g.setLineWidth(40 * b); g.strokePath()
                g.restoreGState()
            }
            g.saveGState(); g.addPath(pill); g.clip(); g.addPath(pill)
            g.setStrokeColor(NSColor(white: 1, alpha: 0.38 + 0.12 * b).cgColor); g.setLineWidth(4); g.strokePath(); g.restoreGState()
        } else if pal.ic {
            g.saveGState(); g.addPath(pill); g.setStrokeColor(pal.ink.cgColor); g.setLineWidth(3); g.strokePath(); g.restoreGState()
        }
        // 眼睛：歡迎頁照稿 4 s 眨一下（92%–100%），其餘照桌寵自己的眨眼
        var bf = blinkFactor(now)
        if let ph = welcomePhase { bf = CGFloat(IntroEase.enter.key(ph, [(0.92, 1), (0.95, 0.1), (1, 1)])) }
        let k = r.height / 156
        for s: CGFloat in [-1, 1] { drawEye(g, cx: r.midX + s * cur.sep * k, cy: r.midY, side: s, blinkF: bf, k: k) }
    }

    // MARK: 手指／游標（512）

    /// 手指：半透明白圓點（滑鼠換成箭頭游標；觸控板換頁時是兩點）
    private func introFinger(_ g: CGContext, _ c: CGPoint, opacity: Double, scale: Double, _ input: IntroInput, _ pal: IntroPalette, two: Bool = false, size: CGFloat = 44) {
        guard opacity > 0.01 else { return }
        g.saveGState()
        g.setAlpha(CGFloat(opacity))
        if input == .mouse {
            // 箭頭游標：尖端在觸點；按下（縮小那段）時尖端底下一圈
            if scale < 0.97 {
                g.setStrokeColor(NSColor(white: 1, alpha: 0.75).cgColor); g.setLineWidth(2)
                g.strokeEllipse(in: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24))
            }
            let pts: [CGPoint] = [(0, 0), (0, 22), (5.4, 17), (9.2, 25.4), (13, 23.8), (9.4, 15.6), (16.4, 15.6)].map { CGPoint(x: c.x + $0.0, y: c.y + $0.1) }
            g.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: NSColor(white: 0, alpha: 0.35).cgColor)
            g.addLines(between: pts); g.closePath(); g.setFillColor(NSColor.white.cgColor); g.fillPath()
            g.setShadow(offset: .zero, blur: 0, color: nil)
            g.addLines(between: pts); g.closePath(); g.setStrokeColor(NSColor.black.cgColor); g.setLineWidth(1.3); g.setLineJoin(.round); g.strokePath()
        } else {
            let d = size * CGFloat(scale)
            let centers = two ? [CGPoint(x: c.x, y: c.y - 26), CGPoint(x: c.x, y: c.y + 26)] : [c]
            for p in centers {
                let r = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
                g.saveGState()
                g.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: NSColor(white: 0, alpha: 0.28).cgColor)
                g.setFillColor(NSColor(white: 1, alpha: pal.ic ? 0.85 : 0.55).cgColor); g.fillEllipse(in: r)
                g.restoreGState()
                g.setStrokeColor(NSColor(white: 1, alpha: 0.75).cgColor); g.setLineWidth(1); g.strokeEllipse(in: r)
                if !pal.dark || pal.ic {   // 淺底上白點看不清：外面再一圈深色細邊
                    g.setStrokeColor(NSColor(white: 0, alpha: pal.ic ? 0.7 : 0.22).cgColor); g.setLineWidth(1); g.strokeEllipse(in: r.insetBy(dx: -1, dy: -1))
                }
            }
        }
        g.restoreGState()
    }

    private func introPointer(_ g: CGContext, _ page: IntroPage, _ p: Double, _ input: IntroInput, _ pal: IntroPalette) {
        let E = IntroEase.move
        switch page {
        case .home:
            let op = E.key(p, [(0.06, 0), (0.12, 1), (0.46, 1), (0.54, 0)])
            let ty = E.key(p, [(0.12, 0), (0.46, 120), (0.54, 128)]), s = E.key(p, [(0.06, 1.15), (0.12, 0.92), (0.46, 0.92), (0.54, 1)])
            introFinger(g, CGPoint(x: 256, y: 55 + ty), opacity: op, scale: s, input, pal)
        case .switcher:
            let op = E.key(p, [(0.06, 0), (0.12, 1), (0.68, 1), (0.76, 0)])
            let ty = E.key(p, [(0.12, 0), (0.40, 96), (0.68, 96), (0.76, 104)])
            let s = E.key(p, [(0.06, 1.15), (0.12, 0.92), (0.40, 0.92), (0.48, 0.86), (0.54, 0.92), (0.68, 0.92), (0.76, 1)])
            // 停住的提示：手指周圍擴散一圈
            let rop = IntroEase.enter.key(p, [(0.44, 0), (0.50, 0.9), (0.70, 0)]), rs = IntroEase.enter.key(p, [(0.44, 0.6), (0.50, 1), (0.70, 1.6)])
            if rop > 0.01 {
                let rr = 32 * CGFloat(rs)
                g.saveGState(); g.setAlpha(CGFloat(rop)); g.setStrokeColor(NSColor(white: 1, alpha: 0.8).cgColor); g.setLineWidth(2)
                g.strokeEllipse(in: CGRect(x: 256 - rr, y: 151 - rr, width: rr * 2, height: rr * 2)); g.restoreGState()
            }
            introFinger(g, CGPoint(x: 256, y: 55 + ty), opacity: op, scale: s, input, pal)
        case .control:
            let op = E.key(p, [(0.06, 0), (0.12, 1), (0.48, 1), (0.56, 0)])
            let tx = E.key(p, [(0.12, 0), (0.48, -16), (0.56, -16)]), ty = E.key(p, [(0.12, 0), (0.48, 190), (0.56, 198)])
            let s = E.key(p, [(0.06, 1.15), (0.12, 0.92), (0.48, 0.92), (0.56, 1)])
            introFinger(g, CGPoint(x: 452 + tx, y: 44 + ty), opacity: op, scale: s, input, pal)
        case .swipe:
            let op = E.key(p, [(0.04, 0), (0.08, 1), (0.20, 1), (0.26, 0), (0.40, 0), (0.44, 1), (0.56, 1), (0.62, 0)])
            let tx = E.key(p, [(0.08, 0), (0.20, -200), (0.26, -220), (0.40, 0), (0.44, 0), (0.56, -200), (0.62, -220)])
            let s = E.key(p, [(0.04, 1), (0.08, 0.92), (0.20, 0.92), (0.26, 1), (0.40, 1), (0.44, 0.92), (0.56, 0.92), (0.62, 1)])
            introFinger(g, CGPoint(x: 402 + tx, y: 242), opacity: op, scale: s, input, pal, two: input == .trackpad)
        case .pet:
            let op = E.key(p, [(0.08, 0), (0.14, 1), (0.62, 1), (0.74, 0)])
            let tx = E.key(p, [(0.14, 0), (0.40, -46), (0.62, 30)])
            introFinger(g, CGPoint(x: 268 + tx * 0.83, y: 227), opacity: op, scale: 1, input, pal, size: 40)
        case .welcome, .more: break
        }
    }

    // MARK: 示範畫面（512）

    private static let homeColors: [UInt32] = [0x34c759, 0xff9f0a, 0xff2d55, 0x30b0c7, 0x5e5ce6, 0x0a84ff, 0xbf5af2, 0xffd60a]
    private static let page2Colors: [UInt32] = [0x30d158, 0x0a84ff, 0xff9500, 0xff9500, 0xffffff, 0x8e8e93, 0xff375f, 0xff453a]

    /// 主畫面的八個色塊圖示（4 欄；top 是第一列的上緣）
    private func introIcons(_ g: CGContext, _ colors: [UInt32], top: CGFloat, dx: CGFloat = 0) {
        let w: CGFloat = (512 - 104 - 3 * 24) / 4
        for (i, c) in colors.enumerated() {
            let r = CGRect(x: dx + 52 + CGFloat(i % 4) * (w + 24), y: top + CGFloat(i / 4) * (72 + 22), width: w, height: 72)
            introFill(g, r, 17, srgb(c))
        }
    }

    /// 天氣 App（示意）：整面藍色漸層、城市與溫度；元素座標以 512 的整面為準
    private func introWeather(_ g: CGContext, radius: CGFloat, condition: Bool) {
        let r = CGRect(x: 0, y: 0, width: 512, height: 512)
        let path = continuousRoundedRect(r, radius: radius)
        g.saveGState(); g.addPath(path); g.clip()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if let grad = CGGradient(colorsSpace: cs, colors: [srgb(0x2f6fd6).cgColor, srgb(0x79b4f2).cgColor] as CFArray, locations: [0, 1]) {
            g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
        }
        introText(g, L("intro.demo.city", "台北"), HPType.sf(20, .semibold), cx: 256, y: 139, .white)
        introText(g, "23°", HPType.sf(84, .thin), cx: 256, y: 211, .white)
        if condition { introText(g, L("intro.demo.weather", "晴间多云"), HPType.sf(16, .regular), cx: 256, y: 243, NSColor(white: 1, alpha: 0.85)) }
        g.restoreGState()
    }

    private func introScene(_ g: CGContext, _ page: IntroPage, _ p: Double, _ input: IntroInput, _ pal: IntroPalette, now: Double) {
        switch page {
        case .home:
            // 主畫面（App 縮下去後露出來）
            let hop = IntroEase.enter.key(p, [(0.20, 0), (0.52, 1), (0.92, 1), (1, 0)]), hs = IntroEase.enter.key(p, [(0.20, 1.06), (0.52, 1)])
            if hop > 0.01 {
                g.saveGState(); g.setAlpha(CGFloat(hop))
                g.translateBy(x: 256, y: 256); g.scaleBy(x: CGFloat(hs), y: CGFloat(hs)); g.translateBy(x: -256, y: -256)
                introIcons(g, Self.homeColors, top: 96)
                g.restoreGState()
            }
            // 正在用的 App：整面 → 跟手縮成卡片 → 縮回第一格圖示
            let D = IntroEase.drawer
            let op = D.key(p, [(0.46, 1), (0.70, 0)])
            if op > 0.01 {
                let tx = D.key(p, [(0.12, 0), (0.46, 0), (0.70, -112)]), ty = D.key(p, [(0.12, 0), (0.46, 104), (0.70, -34)])
                let s = D.key(p, [(0.12, 1), (0.46, 0.6), (0.70, 0.16)]), rad = D.key(p, [(0.12, 69), (0.46, 56), (0.70, 30)])
                g.saveGState(); g.setAlpha(CGFloat(op)); g.beginTransparencyLayer(auxiliaryInfo: nil)
                g.translateBy(x: 256 + CGFloat(tx), y: CGFloat(ty)); g.scaleBy(x: CGFloat(s), y: CGFloat(s)); g.translateBy(x: -256, y: 0)
                introWeather(g, radius: CGFloat(rad), condition: true)
                g.endTransparencyLayer(); g.restoreGState()
            }
        case .switcher:
            g.setFillColor(pal.switcherBG.cgColor); g.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            // 左右兩張卡（CarPlay、音樂）：中心離中間 ±300，縮 0.5 後露出半張
            let E = IntroEase.enter
            let sop = E.key(p, [(0.44, 0), (0.62, 1)]), stx = E.key(p, [(0.44, 60), (0.62, 0)])
            if sop > 0.01 {
                for (side, title, top, bottom) in [(-1.0, "CarPlay", 0x1f3a2c, 0x3b6b52), (1.0, L("intro.demo.music", "音乐"), 0x5b1f2c, 0xc4395a)] as [(Double, String, UInt32, UInt32)] {
                    g.saveGState(); g.setAlpha(CGFloat(sop))
                    let cx = 256 + CGFloat(side) * 300
                    g.translateBy(x: cx + CGFloat(side * stx), y: 80); g.scaleBy(x: 0.5, y: 0.5); g.translateBy(x: -256, y: 0)
                    let r = CGRect(x: 0, y: 0, width: 512, height: 512)
                    g.saveGState(); g.addPath(continuousRoundedRect(r, radius: 104)); g.clip()
                    if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [srgb(top).cgColor, srgb(bottom).cgColor] as CFArray, locations: [0, 1]) {
                        g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
                    }
                    g.restoreGState()
                    introText(g, title, HPType.sf(44, .semibold), cx: 256, y: 272, .white)
                    g.restoreGState()
                }
            }
            let D = IntroEase.drawer
            let ty = D.key(p, [(0.12, 0), (0.40, 92), (0.54, 80)]), s = D.key(p, [(0.12, 1), (0.40, 0.58), (0.54, 0.5)]), rad = D.key(p, [(0.12, 69), (0.40, 56), (0.54, 52)])
            g.saveGState()
            g.translateBy(x: 256, y: CGFloat(ty)); g.scaleBy(x: CGFloat(s), y: CGFloat(s)); g.translateBy(x: -256, y: 0)
            introWeather(g, radius: CGFloat(rad), condition: false)
            g.restoreGState()
        case .control:
            let E = IntroEase.enter, D = IntroEase.drawer
            let sop = E.key(p, [(0.12, 0), (0.48, 1), (0.92, 1), (1, 0)])
            // 鎖定畫面的大時間；控制中心的霧化底蓋上來時跟著淡（稿是 backdrop-filter 模糊）
            introText(g, "10:09", HPType.sf(120, .thin), cx: 256, y: 120 + 114, pal.ink.withAlphaComponent(0.55 * (1 - 0.75 * CGFloat(sop))))
            if sop > 0.01 {
                g.saveGState(); g.setAlpha(CGFloat(sop)); g.setFillColor(pal.scrim.cgColor); g.fill(CGRect(x: 0, y: 0, width: 512, height: 512)); g.restoreGState()
            }
            let cop = D.key(p, [(0.12, 0), (0.48, 1), (0.92, 1), (1, 0)])
            if cop > 0.01 {
                let ty = D.key(p, [(0.12, -36), (0.48, 0)]), s = D.key(p, [(0.12, 0.96), (0.48, 1)])
                g.saveGState(); g.setAlpha(CGFloat(cop)); g.beginTransparencyLayer(auxiliaryInfo: nil)
                // 原點 88% 0%（從右上角長出來）
                let ox: CGFloat = 40 + 432 * 0.88, oy: CGFloat = 44
                g.translateBy(x: ox, y: oy + CGFloat(ty)); g.scaleBy(x: CGFloat(s), y: CGFloat(s)); g.translateBy(x: -ox, y: -oy)
                introControlCenter(g, pal)
                g.endTransparencyLayer(); g.restoreGState()
            }
        case .swipe:
            let x = IntroEase.drawer.key(p, [(0.14, 0), (0.30, -512), (0.50, -512), (0.66, -1024), (0.86, -1024), (1, 0)])
            g.saveGState(); g.translateBy(x: CGFloat(x), y: 0)
            introIcons(g, Self.homeColors, top: 110)
            introIcons(g, Self.page2Colors, top: 110, dx: 512)
            // 資源庫：分類大格（圓角 28，不貼螢幕角）
            let cw: CGFloat = (512 - 88 - 20) / 2
            for (i, name) in [L("intro.demo.suggestions", "建议"), "iPhone"].enumerated() {
                let r = CGRect(x: 1024 + 44 + CGFloat(i) * (cw + 20), y: 96, width: cw, height: 150)
                introFill(g, r, 28, pal.module)
                drawLeft(g, name, font: HPType.sf(13, .regular), x: r.minX + 12, y: r.maxY - 14, color: pal.ink.withAlphaComponent(0.8))
            }
            g.restoreGState()
            // 頁點：• • ＋ 資源庫圖示（step-end：到了關鍵影格才換亮的那一顆）
            let on = p < 0.30 ? 0 : p < 0.66 ? 1 : 2
            let y: CGFloat = 325.5
            for k in 0..<2 {
                g.setFillColor((k == on ? pal.ink : pal.dotOff).cgColor)
                g.fillEllipse(in: CGRect(x: 256 - 18.5 + CGFloat(k) * 17 - 4, y: y - 4, width: 8, height: 8))
            }
            g.setFillColor((on == 2 ? pal.ink : pal.dotOff).cgColor)
            let lx: CGFloat = 267.5
            for (dx, dy) in [(0.0, 0.0), (6.5, 0.0), (0.0, 6.5), (6.5, 6.5)] as [(CGFloat, CGFloat)] {
                g.addPath(CGPath(roundedRect: CGRect(x: lx + dx, y: y - 5.5 + dy, width: 4.5, height: 4.5), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)); g.fillPath()
            }
        case .welcome, .pet, .more: break
        }
    }

    /// 控制中心（示意 4×3）：Wi‑Fi、藍牙膠囊，正在播放大格，一排圓鈕
    private func introControlCenter(_ g: CGContext, _ pal: IntroPalette) {
        let x0: CGFloat = 40, y0: CGFloat = 44, gap: CGFloat = 12, cw = (432 - 3 * gap) / 4
        func cell(_ col: Int, _ row: Int, span: Int = 1, rows: Int = 1) -> CGRect {
            CGRect(x: x0 + CGFloat(col) * (cw + gap), y: y0 + CGFloat(row) * (64 + gap), width: cw * CGFloat(span) + gap * CGFloat(span - 1),
                   height: 64 * CGFloat(rows) + gap * CGFloat(rows - 1))
        }
        for (row, name) in [(0, "Wi‑Fi"), (1, L("intro.demo.bluetooth", "蓝牙"))] {
            let r = cell(0, row, span: 2)
            introPill(g, r, pal.module)
            g.setFillColor(srgb(0x0a84ff).cgColor); g.fillEllipse(in: CGRect(x: r.minX + 12, y: r.midY - 20, width: 40, height: 40))
            drawLeft(g, name, font: HPType.sf(14, .semibold), x: r.minX + 62, y: r.midY + 5, color: pal.ink)
        }
        let np = cell(2, 0, span: 2, rows: 2)
        introFill(g, np, 28, pal.module)
        introText(g, L("intro.demo.nowPlaying", "正在播放"), HPType.sf(13, .regular), cx: np.midX, y: np.midY + 4.5, pal.ink.withAlphaComponent(0.8))
        for col in 0..<4 { introPill(g, cell(col, 2), col == 2 ? (pal.dark ? .white : srgb(0x0a84ff)) : pal.module) }
    }

    // MARK: 各頁的字與按鈕（512）

    private func introWelcome(_ g: CGContext, _ pal: IntroPalette, since: Double, rm: Bool) {
        // 依序浮上來：600 ms，延遲 200／320／440 ms
        func rise(_ delay: Double) -> (CGFloat, CGFloat) {
            if rm { return (1, 0) }
            let k = CGFloat(IntroEase.enter((since - delay) / 0.6))
            return (k, (1 - k) * 10)
        }
        let title = IntroGuide.title(.welcome, IntroGuide.input)
        let tf = introFit(title, 36, .bold, 460)
        let (a1, d1) = rise(0.2), (a2, d2) = rise(0.32), (a3, d3) = rise(0.44)
        g.saveGState(); g.setAlpha(a1)
        introText(g, title, tf, cx: 256, y: 150 + 36 * 0.95 + d1, pal.ink)
        g.restoreGState()
        introNote(.heading, title, CGRect(x: 40, y: 146, width: 432, height: 46))
        let body = IntroGuide.body(.welcome, IntroGuide.input)
        let lines = body.components(separatedBy: "\n")
        g.saveGState(); g.setAlpha(a2)
        for (i, line) in lines.enumerated() {
            let f = introFit(line, 17, .regular, 380)
            introText(g, line, f, cx: 256, y: 150 + 40 + 10 + 17 + CGFloat(i) * 24.6 + d2, pal.ink2)
        }
        g.restoreGState()
        introNote(.text, lines.joined(separator: " "), CGRect(x: 66, y: 196, width: 380, height: 24.6 * CGFloat(lines.count) + 6))
        // 底下的字卡：頁點＋略過＋開始
        g.saveGState(); g.setAlpha(a3); g.translateBy(x: 0, y: d3)
        introCard(g, Self.introCaption, pal, alpha: 0.42)
        introDots(g, pal, cy: 399, current: .welcome)
        let skip = L("intro.skip", "略过"), start = L("intro.start", "开始")
        let sf = HPType.sf(15, .regular), bf = HPType.sf(17, .semibold)
        let sw = Typo.width(skip, sf) + 36, bw = max(120, Typo.width(start, bf) + 68)
        let x0 = 256 - (sw + 12 + bw) / 2
        let sr = CGRect(x: x0, y: 418.5, width: sw, height: 44), br = CGRect(x: x0 + sw + 12, y: 416.5, width: bw, height: 48)
        introText(g, skip, sf, cx: sr.midX, y: sr.midY + 5, pal.ink2.withAlphaComponent(pal.ink2.alphaComponent * pressedAlpha(.skip)))
        g.saveGState()
        if IntroGuide.pressed == .next { g.translateBy(x: br.midX, y: br.midY); g.scaleBy(x: 0.97, y: 0.97); g.translateBy(x: -br.midX, y: -br.midY) }
        introPill(g, br, pal.buttonFill)
        introText(g, start, bf, cx: br.midX, y: br.midY + 6, pal.buttonInk)
        g.restoreGState()
        g.restoreGState()
        introHit(.skip, sr, skip); introHit(.next, br, start)
    }

    /// 回主畫面、切換器、控制中心、換頁：底下一張字卡（標題、說明、頁點），左下略過、右下下一個
    private func introCaptionCard(_ g: CGContext, _ page: IntroPage, _ input: IntroInput, _ pal: IntroPalette) {
        introCard(g, Self.introCaption, pal, alpha: page == .home ? 0.5 : 0.62)
        let title = IntroGuide.title(page, input), body = IntroGuide.body(page, input)
        let tf = introFit(title, 22, .semibold, 440), bf = introFit(body, 15, .regular, 400)
        introText(g, title, tf, cx: 256, y: 415, pal.ink)
        introText(g, body, bf, cx: 256, y: 441, pal.ink2)
        introNote(.heading, title, CGRect(x: 36, y: 396, width: 440, height: 26))
        introNote(.text, body, CGRect(x: 56, y: 426, width: 400, height: 20))
        introDots(g, pal, cy: 462, current: page)
        introNav(g, pal, cy: 462, nextX: 462, skipX: 66)
    }

    /// 桌寵本身：上方輸入方式分段（自動選最近一次用的，可以手動換）、機身轉動示範、三種輸入各自的動作表
    private func introPet(_ g: CGContext, _ p: Double, _ input: IntroInput, _ pal: IntroPalette, now: Double, rm: Bool) {
        introNote(.heading, IntroGuide.title(.pet, input), CGRect(x: 106, y: 8, width: 300, height: 18))
        // 分段控制（膠囊）
        let track = CGRect(x: 106, y: 28, width: 300, height: 44)
        introPill(g, track, pal.dark ? NSColor(white: 1, alpha: pal.rt ? 0.24 : 0.14) : NSColor(white: 0, alpha: 0.06))
        g.addPath(CGPath(roundedRect: track, cornerWidth: 22, cornerHeight: 22, transform: nil))
        g.setStrokeColor((pal.ic ? pal.ink.withAlphaComponent(0.7) : (pal.dark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.12))).cgColor)
        g.setLineWidth(pal.ic ? 1.5 : 1); g.strokePath()
        let segW: CGFloat = (300 - 8 - 8) / 3
        for (i, k) in IntroInput.allCases.enumerated() {
            let r = CGRect(x: track.minX + 4 + CGFloat(i) * (segW + 4), y: track.minY + 4, width: segW, height: 36)
            let on = k == input, name = IntroGuide.inputName(k)
            if on {
                g.saveGState()
                if !pal.dark { g.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: NSColor(white: 0, alpha: 0.15).cgColor) }
                introPill(g, r, .white); g.restoreGState()
            }
            let f = introFit(name, 14, .semibold, segW - 8)
            introText(g, name, f, cx: r.midX, y: r.midY + 5, (on ? srgb(0x141428) : pal.ink).withAlphaComponent(pressedAlpha(.input(k))))
            introHit(.input(k), r, name, selected: on)
        }
        // 機身（螢幕＋底座）：左右轉一下再回正（示範「拖機身＝轉」）；減少動態效果時前後兩格（0° 與 -28°）
        func angle(_ q: Double) -> Double { IntroEase.move.key(q, [(0.12, 0), (0.40, -28), (0.62, 18), (0.82, 0)]) }
        if let st = IntroPage.pet.stills, rm {
            let m = CGFloat(Self.introStillMix(now))
            for (q, a) in [(st.before, 1 - m), (st.after, m)] where a > 0.001 {
                g.saveGState(); g.setAlpha(a); g.beginTransparencyLayer(auxiliaryInfo: nil)
                introMachine(g, angle: angle(q), pal: pal, now: now)
                g.endTransparencyLayer(); g.restoreGState()
            }
        } else {
            introMachine(g, angle: angle(p), pal: pal, now: now)
        }
        introPointerLayer(g, .pet, p, input, pal, now: now, rm: rm)
        // 動作表
        introCard(g, Self.introTable, pal, alpha: 0.55)
        let rows = IntroGuide.petRows(input)
        let font = HPType.sf(14, .regular), rowH: CGFloat = 29
        let card = CGRect(x: 24, y: 245, width: 464, height: 243)
        for (i, row) in rows.enumerated() {
            let y = card.minY + 14 + CGFloat(i) * rowH
            let how = Face.clipped(row.how, font, 210), what = Face.clipped(row.what, font, 190)
            drawLeft(g, how, font: font, x: card.minX + 30, y: y + 19, color: pal.ink)
            drawLeft(g, what, font: font, x: card.maxX - 30 - Typo.width(what, font), y: y + 19, color: pal.ink2)
            if i < rows.count - 1 { g.setFillColor(pal.hair.cgColor); g.fill(CGRect(x: card.minX + 30, y: y + rowH - 0.5, width: card.width - 60, height: 0.5)) }
            introNote(.text, String(format: L("a11y.pair", "%1$@，%2$@"), row.how, row.what), CGRect(x: card.minX + 30, y: y, width: card.width - 60, height: rowH))
        }
        introDots(g, pal, cy: 458, current: .pet)
        introNav(g, pal, cy: 458, nextX: 450, skipX: 72)
    }

    /// 示意機身：140 的方螢幕（圓角 30）＋條紋底座；angle 是繞直軸轉的角度（用水平壓縮近似透視）
    private func introMachine(_ g: CGContext, angle: Double, pal: IntroPalette, now: Double) {
        let k: CGFloat = 0.83, ox: CGFloat = 256 - 75 * k, oy: CGFloat = 86
        let cosA = CGFloat(cos(angle * .pi / 180))
        g.saveGState()
        g.translateBy(x: 256, y: oy + 184 * k * 0.6); g.scaleBy(x: cosA, y: 1); g.translateBy(x: -256, y: -(oy + 184 * k * 0.6))
        g.translateBy(x: ox, y: oy); g.scaleBy(x: k, y: k)
        let screen = CGRect(x: 5, y: 0, width: 140, height: 140)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: NSColor(white: 0, alpha: 0.35).cgColor)
        introFill(g, screen, 30, srgb(0xe9e9ee))
        g.restoreGState()
        let inner = screen.insetBy(dx: 9, dy: 9)
        g.saveGState(); g.addPath(continuousRoundedRect(inner, radius: 22)); g.clip()
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [srgb(0x27345c).cgColor, srgb(0x4a3f6e).cgColor] as CFArray, locations: [0, 1]) {
            g.drawLinearGradient(grad, start: CGPoint(x: inner.minX, y: inner.minY), end: CGPoint(x: inner.maxX, y: inner.maxY), options: [])
        }
        g.restoreGState()
        let cap = CGRect(x: 75 - 29, y: inner.minY + 12, width: 58, height: 18)
        introPill(g, cap, NSColor(white: 1, alpha: 0.18))
        let ek = cap.height / 156
        for s: CGFloat in [-1, 1] { drawEye(g, cx: cap.midX + s * cur.sep * ek, cy: cap.midY, side: s, blinkF: blinkFactor(now), k: ek) }
        // 底座：寬 64、高 40，下緣圓角 14，直條紋
        let base = CGRect(x: 43, y: 140, width: 64, height: 40)
        let bp = CGMutablePath()
        bp.move(to: CGPoint(x: base.minX, y: base.minY)); bp.addLine(to: CGPoint(x: base.maxX, y: base.minY))
        bp.addArc(tangent1End: CGPoint(x: base.maxX, y: base.maxY), tangent2End: CGPoint(x: base.minX, y: base.maxY), radius: 14)
        bp.addArc(tangent1End: CGPoint(x: base.minX, y: base.maxY), tangent2End: CGPoint(x: base.minX, y: base.minY), radius: 14)
        bp.closeSubpath()
        g.saveGState(); g.addPath(bp); g.clip()
        var x = base.minX
        var light = false
        while x < base.maxX { g.setFillColor(srgb(light ? 0xdcdce1 : 0xc9c9cf).cgColor); g.fill(CGRect(x: x, y: base.minY, width: 3, height: base.height)); x += 3; light.toggle() }
        g.restoreGState()
        g.restoreGState()
    }

    /// 其他手勢：清單卡（內縮 24 → 與機身同心）＋「開始使用」
    private func introMore(_ g: CGContext, _ input: IntroInput, _ pal: IntroPalette, since: Double, rm: Bool) {
        introCard(g, Self.introList, pal, alpha: 0.5)
        let card = CGRect(x: 24, y: 104, width: 464, height: 384)
        let title = IntroGuide.title(.more, input)
        introText(g, title, introFit(title, 22, .semibold, 400), cx: 256, y: card.minY + 22 + 21, pal.ink)
        introNote(.heading, title, CGRect(x: 56, y: card.minY + 22, width: 400, height: 27))
        let font = HPType.sf(15, .regular), rowH: CGFloat = 37
        let rows = IntroGuide.moreRows(input)
        for (i, row) in rows.enumerated() {
            // 依序浮上來：300 ms，每列晚 50 ms
            let k = rm ? 1 : CGFloat(IntroEase.enter((since - Double(i) * 0.05) / 0.3))
            let y = card.minY + 22 + 27 + 10 + CGFloat(i) * rowH + (1 - k) * 8
            g.saveGState(); g.setAlpha(k)
            let how = Face.clipped(row.how, font, 190), what = Face.clipped(row.what, font, 210)
            drawLeft(g, how, font: font, x: card.minX + 28, y: y + 23, color: pal.ink)
            drawLeft(g, what, font: font, x: card.maxX - 28 - Typo.width(what, font), y: y + 23, color: pal.ink2)
            if i < rows.count - 1 { g.setFillColor(pal.hair.cgColor); g.fill(CGRect(x: card.minX + 28, y: y + rowH - 1, width: card.width - 56, height: 1)) }
            g.restoreGState()
            introNote(.text, String(format: L("a11y.pair", "%1$@，%2$@"), row.how, row.what), CGRect(x: card.minX + 28, y: y, width: card.width - 56, height: rowH))
        }
        let s = L("intro.done", "开始使用"), bf = HPType.sf(17, .semibold)
        let bw = max(140, Typo.width(s, bf) + 68)
        let br = CGRect(x: 256 - bw / 2, y: card.maxY - 18 - 48, width: bw, height: 48)
        g.saveGState()
        if IntroGuide.pressed == .next { g.translateBy(x: br.midX, y: br.midY); g.scaleBy(x: 0.97, y: 0.97); g.translateBy(x: -br.midX, y: -br.midY) }
        introPill(g, br, pal.buttonFill)
        introText(g, s, bf, cx: br.midX, y: br.midY + 6, pal.buttonInk)
        g.restoreGState()
        introHit(.next, br, s)
    }

    // MARK: 升級提示卡（主畫面）

    var introHintVisible: Bool {
        (IntroHint.pending || IntroHint.forced) && Shell.nav.screen == .home && Shell.nav.overlay == .none
            && !Onboarding.active && !SetupFlow.active && !TouchTip.active && !PermissionPrimer.visible
    }

    /// 每幀：出現時記時間、12 秒沒動就收（記下處理過）；有變化回 true
    func tickIntroHint(_ now: Double) -> Bool {
        guard IntroHint.pending || IntroHint.forced else { return false }
        guard introHintVisible else { return false }
        if IntroHint.shownAt == nil { IntroHint.shownAt = now; log("intro: upgrade hint shown"); return true }
        if !IntroHint.forced, let s = IntroHint.shownAt, now - s > IntroHint.duration { IntroHint.finish(); return true }
        return false
    }

    func drawIntroHint(_ g: CGContext, _ now: Double) {
        guard introHintVisible else { IntroHint.cardRect = .zero; IntroHint.closeRect = .zero; return }
        let r = IntroHint.card, rad = IntroHint.radius
        let ic = HPAccessibility.increaseContrast, rt = HPAccessibility.reduceTransparency
        if rt {
            g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: 18), blur: 44, color: NSColor(white: 0, alpha: 0.32).cgColor)
            g.addPath(continuousRoundedRect(r, radius: rad)); g.setFillColor(srgb(0x1c1c1e).cgColor); g.fillPath(); g.restoreGState()
        } else {
            glass(g, r, radius: rad, tint: NSColor(white: 0, alpha: ic ? 0.62 : 0.34), band: 14)
        }
        if ic { g.saveGState(); g.addPath(continuousRoundedRect(r, radius: rad)); g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(3); g.strokePath(); g.restoreGState() }
        let icon = CGRect(x: r.minX + 48, y: r.midY - 48, width: 96, height: 96)
        drawSymbol(g, "hand.draw", in: icon, color: .white)
        let close = CGRect(x: r.maxX - 40 - 72, y: r.minY + 40, width: 72, height: 72)
        g.setFillColor(NSColor(white: 1, alpha: ic ? 0.35 : 0.18).cgColor); g.fillEllipse(in: close)
        drawSymbol(g, "xmark", in: close.insetBy(dx: 24, dy: 24), color: .white, weight: .bold)
        let x = icon.maxX + 40, maxW = close.minX - 24 - x
        let title = L("intro.hint.title", "有新的手势引导"), body = L("intro.hint.body", "点一下现在看，或之后到设置里重看")
        drawLeft(g, title, font: HPType.fitted(title, size: 48, weight: .bold, maxWidth: maxW), x: x, y: r.midY - 8, color: .white)
        let bf = HPType.fitted(body, size: 32, weight: .medium, maxWidth: maxW, minScale: 0.6)
        drawLeft(g, Face.clipped(body, bf, maxW), font: bf, x: x, y: r.midY + 44, color: NSColor.white.withAlphaComponent(ic ? 1 : 0.78))
        IntroHint.cardRect = r; IntroHint.closeRect = close
    }
}

/// 引導裡一個可以按的地方（1024 座標）
struct IntroHitArea {
    let action: IntroGuide.Action
    let rect: CGRect
    let label: String
    var selected: Bool? = nil
}

// MARK: - 自檢（ShellSelfTest.run 呼叫）

enum IntroScreenSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // easing：兩端固定、單調；進出場是前快後慢
        let eases = [IntroEase.move, IntroEase.drawer, IntroEase.enter]
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }
        check(eases.allSatisfy { e in abs(e(0)) < 1e-9 && abs(e(1) - 1) < 1e-9 && zip(samples, samples.dropFirst()).allSatisfy { e($0) <= e($1) + 1e-9 } }
              && IntroEase.enter(0.3) > 0.6 && IntroEase.move(0.05) < 0.02 && IntroEase.move(0.95) > 0.98,
              "手勢引導：cubic-bezier 兩端固定、單調（進出場前快後慢、移動兩頭慢）")   // l10n-ignore：selftest 訊息
        check(IntroEase.move.key(0.05, [(0.1, 3), (0.5, 7)]) == 3 && IntroEase.move.key(0.9, [(0.1, 3), (0.5, 7)]) == 7
              && abs(IntroEase.move.key(0.3, [(0.1, 3), (0.5, 7)]) - (3 + 4 * IntroEase.move(0.5))) < 1e-9, "手勢引導：關鍵影格頭尾保持、中間照 easing")   // l10n-ignore：selftest 訊息
        // 字卡：內縮 32 → 圓角 106（512 稿的 53 ×2），清單卡內縮 48 → 90（稿的 45 ×2）
        check(abs(Face.introRadius(Face.introCaption) - (Screen.cornerRadius - 32)) < 0.5 && abs(Face.introRadius(Face.introList) - (Screen.cornerRadius - 48)) < 0.5,
              "手勢引導：字卡圓角與機身同心（螢幕圓角 − 內縮）")   // l10n-ignore：selftest 訊息
        // 減少動態效果：靜態版——「前」那格停住的時間裡兩格畫面一模一樣；一般版同樣兩個時刻手指在動
        let saved = (Onboarding.active, IntroGuide.page, IntroGuide.pageAt, IntroGuide.openedAt, IntroGuide.demo, IntroGuide.demoInput, HPMotion.forceReduce, IntroGuide.closedAt)
        defer {
            (Onboarding.active, IntroGuide.page, IntroGuide.pageAt, IntroGuide.openedAt, IntroGuide.demo, IntroGuide.demoInput, HPMotion.forceReduce, IntroGuide.closedAt) = saved
            IntroGuide.hits = []; IntroGuide.texts = []
        }
        let face = Face(); face.frozen = true
        Onboarding.active = true; IntroGuide.demo = nil; IntroGuide.demoInput = .touch
        IntroGuide.page = .home; IntroGuide.pageAt = 0; IntroGuide.openedAt = -10
        func shot(_ t: Double) -> Data {
            let img = makeImage(256, 256) { c in c.scaleBy(x: 0.25, y: 0.25); face.drawIntroGuide(c, t) }
            return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) ?? Data()
        }
        HPMotion.forceReduce = true
        let a = shot(0.5), b = shot(1.1), c = shot(2.2)
        HPMotion.forceReduce = false
        let d = shot(0.5), e = shot(1.1)
        check(a == b && a != c, "手勢引導：減少動態效果時示範是前後兩格靜態對照（停住時不動、之後換成「後」那格）")   // l10n-ignore：selftest 訊息
        check(d != e, "手勢引導：一般情況示範會動")   // l10n-ignore：selftest 訊息
        // VoiceOver：每頁有標題、略過與下一個都有標籤
        let labels = IntroGuide.hits.map(\.label), heads = IntroGuide.texts.filter { $0.role == .heading }
        check(heads.count == 1 && labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
              && IntroGuide.hits.contains { $0.action == .next } && IntroGuide.hits.contains { $0.action == .skip },
              "手勢引導：標題念得出來、略過與下一個按得到（\(labels)）")   // l10n-ignore：selftest 訊息
        IntroGuide.page = .pet
        _ = shot(0.5)
        check(IntroGuide.hits.filter { if case .input = $0.action { return true }; return false }.count == 3
              && IntroGuide.hits.contains { $0.selected == true && $0.action == .input(.touch) },
              "手勢引導：桌寵本身的輸入方式分段（三段、選中的是現在這種）")   // l10n-ignore：selftest 訊息
    }
}
