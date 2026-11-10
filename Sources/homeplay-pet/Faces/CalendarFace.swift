// 行事曆錶面：照 HomeView 的 Calendar 錶面——配色照現在的 Look 四層色票（固件行事曆的 12 種 Look）：
// 底＝background；月份、時間、星期列、今天那格＝secondary（材質版的 secondary 是白，標題改用數字的黑、今天那格黑底白字）；
// 今天的日期是格子後面的巨大圓頭粗筆畫數字（單筆畫構成，0–9 自己設計），用 numerals 色、壓到極低對比，只當底紋，不跟日期格搶。
// 稿：docs/design-drafts/faces-v3/artifact/engine_tail.js face('行事曆')（600 單位座標 × 1024/600）。
// 驗證用：HOMEPLAY_DATE=2026-10-04 可固定顯示的日期（時間仍取 --time／現在）。

import AppKit

nonisolated(unsafe) private var calendarStaticCache: (key: String, image: CGImage)?
nonisolated(unsafe) private var calendarLastMinute = -1

/// 單筆畫數字：回傳 (路徑, 寬度)，路徑原點在左上，高度固定 calDigitH（600 單位）
private let calDigitH: CGFloat = 262

private func calDigit(_ d: Int) -> (CGPath, CGFloat) {
    let H = calDigitH, W: CGFloat = 130
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = W) -> CGPoint { CGPoint(x: x * w, y: y * H) }
    var width = W
    switch d {
    case 0:
        p.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerWidth: W / 2, cornerHeight: W / 2, transform: nil))
    case 1:
        width = 92
        p.move(to: pt(0, 0.21, 92)); p.addLine(to: pt(1, 0, 92)); p.addLine(to: pt(1, 1, 92))
    case 2:
        // 稿：M0 48 C2 -14 118 -22 120 46 C122 102 16 172 0 250 L132 250（250 高）
        let s = H / 250, sx = W / 132
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: (y + 22) * s * 250 / 272) }
        p.move(to: q(0, 48)); p.addCurve(to: q(120, 46), control1: q(2, -14), control2: q(118, -22))
        p.addCurve(to: q(0, 250), control1: q(122, 102), control2: q(16, 172)); p.addLine(to: q(132, 250))
    case 3:
        p.move(to: pt(0.05, 0.2)); p.addCurve(to: pt(0.92, 0.25), control1: pt(0.15, -0.06), control2: pt(0.95, -0.04))
        p.addCurve(to: pt(0.4, 0.48), control1: pt(0.9, 0.42), control2: pt(0.58, 0.47))
        p.addCurve(to: pt(1.0, 0.74), control1: pt(0.66, 0.48), control2: pt(1.04, 0.56))
        p.addCurve(to: pt(0, 0.8), control1: pt(0.98, 1.06), control2: pt(0.1, 1.06))
    case 4:
        width = 144
        let s = H / 256
        p.move(to: CGPoint(x: 98, y: 256 * s)); p.addLine(to: CGPoint(x: 98, y: 0)); p.addLine(to: CGPoint(x: 0, y: 176 * s))
        p.addLine(to: CGPoint(x: 144, y: 176 * s))
    case 5:
        p.move(to: pt(0.92, 0)); p.addLine(to: pt(0.12, 0)); p.addLine(to: pt(0.06, 0.46))
        p.addCurve(to: pt(0.92, 0.56), control1: pt(0.3, 0.36), control2: pt(0.74, 0.36))
        p.addCurve(to: pt(0.5, 1.0), control1: pt(1.1, 0.78), control2: pt(0.92, 1.04))
        p.addCurve(to: pt(0.0, 0.8), control1: pt(0.22, 0.98), control2: pt(0.04, 0.9))
    case 6:
        p.move(to: pt(0.9, 0.1)); p.addCurve(to: pt(0.02, 0.66), control1: pt(0.72, -0.05), control2: pt(0.0, 0.0))
        p.addCurve(to: pt(1.0, 0.7), control1: pt(0.02, 1.06), control2: pt(1.0, 1.1))
        p.addCurve(to: pt(0.03, 0.66), control1: pt(1.0, 0.4), control2: pt(0.14, 0.36))
    case 7:
        p.move(to: pt(0, 0)); p.addLine(to: pt(1, 0)); p.addLine(to: pt(0.3, 1))
    case 8:
        p.addEllipse(in: CGRect(x: 0.05 * W, y: 0, width: 0.9 * W, height: 0.5 * H))
        p.addEllipse(in: CGRect(x: 0, y: 0.45 * H, width: W, height: 0.55 * H))
    default:   // 9：6 轉 180°
        let (six, w6) = calDigit(6)
        var t = CGAffineTransform(translationX: w6, y: H).rotated(by: .pi)
        return (six.copy(using: &t) ?? six, w6)
    }
    return (p, width)
}

extension Face {
    private static var calendarToday: Date {
        var d = displayDate
        if let s = ProcessInfo.processInfo.environment["HOMEPLAY_DATE"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            if let day = f.date(from: s) {
                let cal = Calendar.current, hm = cal.dateComponents([.hour, .minute], from: d)
                d = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day) ?? d
            }
        }
        return d
    }

    func renderCalendarFace(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let date = Self.calendarToday
        let cal = Calendar.current
        let dc = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let key = "\(dc.year ?? 0)-\(dc.month ?? 0)-\(dc.day ?? 0) \(dc.hour ?? 0):\(dc.minute ?? 0)|\(L10n.language.rawValue)|\(Int(renderPixelScale * 100))|\(cal.firstWeekday)|\(HPLook.name)|\(HPAccessibility.increaseContrast)"
        if let c = calendarStaticCache, c.key == key {
            drawUpright(g, c.image, in: full); Face.cacheHits += 1
        } else {
            let sc = renderPixelScale, px = Int((1024 * sc).rounded())
            let img = makeImage(px, px) { c in
                if sc != 1 { c.scaleBy(x: sc, y: sc) }
                self.drawCalendarStatic(c, date)
            }
            calendarStaticCache = (key, img)
            drawUpright(g, img, in: full); Face.cacheMisses += 1
        }
        // 膠囊在月份與時間之間（稿：中心 356,66、寬 118／600）；眼睛朝今天看
        let k: CGFloat = 1024 / 600
        faceEyeLook = CGPoint(x: 11, y: 12); defer { faceEyeLook = nil }   // 看著今天（右下）
        drawIsland(g, at: CGPoint(x: 356 * k, y: 66 * k), scale: 118 * k / (420 * 1.4), liveAt: CGPoint(x: 512, y: 150), now: now)
    }

    func tickCalendarFace(_ now: Double) -> Bool {
        let m = Int(Self.calendarToday.timeIntervalSince1970 / 60)
        if m == calendarLastMinute { return false }
        calendarLastMinute = m
        return true
    }

    private func drawCalendarStatic(_ g: CGContext, _ date: Date) {
        let k: CGFloat = 1024 / 600
        let loc = L10n.language.locale
        var cal = Calendar.current; cal.locale = loc
        let look = HPLook.faceLook(.calendar), ic = HPAccessibility.increaseContrast
        let material = look.numerals == 0x000000
        // 官方形象照的角色分配（🟢 取樣）：標題/時間＝numerals（Red-Blue 的紅）、
        // 星期列與日期＝secondary（藍）、今天＝secondary 壓暗 55% 的海軍藍圓（實測 #002E64≈#006FFF×0.45）＋白字
        let ink = material ? NSColor.black : look.secondary_color                // 日期格的數字（官方是藍）
        let accent = material ? NSColor.black : look.numerals_color              // 月份、時間（官方是紅）
        let todayFill = material ? NSColor.black
            : (look.secondary_color.blended(withFraction: 0.66, of: .black) ?? look.secondary_color)
        let todayText = material ? look.secondary_color : NSColor.white
        g.setFillColor(look.background_color.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

        let today = cal.component(.day, from: date)
        // 六週格先算出來（巨數字要對齊今天那一欄）
        let first = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let off = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -off, to: first)!
        let month = cal.component(.month, from: date)
        let todayIndex = (0..<42).first { i in
            let d = cal.date(byAdding: .day, value: i, to: start)!
            return cal.component(.day, from: d) == today && cal.component(.month, from: d) == month
        } ?? 0
        let todayCol = todayIndex % 7
        // 巨大筆畫數字：官方形象照裡只佔今天那一欄、高度約三列，貼在日期格後面當底紋（不是整面置中）
        let digits = String(today).compactMap { Int(String($0)) }.map(calDigit)
        let gs: CGFloat = 190 / calDigitH
        let total = digits.reduce(0) { $0 + $1.1 } * gs
        var x0 = (80 + CGFloat(todayCol) * 71.2) - total / 2
        g.saveGState()
        g.setStrokeColor(look.numerals_color.withAlphaComponent(material ? (ic ? 0.04 : 0.06) : (ic ? 0.55 : 0.85)).cgColor)
        g.setLineWidth(46 * k * gs); g.setLineCap(.round); g.setLineJoin(.round)
        for (path, w) in digits {
            var t = CGAffineTransform(scaleX: k * gs, y: k * gs).translatedBy(x: x0 / gs, y: 196)
            if let p = path.copy(using: &t) { g.addPath(p); g.strokePath() }
            x0 += w * gs
        }
        g.restoreGState()

        // 標題：月份年份（左）、時間（右）。長語言（Septembre 2026…）縮小，不壓到膠囊（297…415）
        let title = Self.formatter("yMMMM").string(from: date)
        var tsize: CGFloat = 35 * k
        let capL = 297 * k - 14
        while tsize > 24 * k, 46 * k + Typo.width(title, FaceType.sf(tsize, .semibold, mono: false)) > capL { tsize -= 1 }
        drawLeft(g, title, font: FaceType.sf(tsize, .semibold, mono: false), x: 46 * k, y: 78 * k, color: accent, kern: -0.3 * k)
        let (h, m) = Self.hourMinute(date)
        let tf = FaceType.sf(35 * k, .semibold, mono: true), ts = "\(h):\(m)"
        let tw = Typo.width(ts, tf)
        drawLeft(g, ts, font: tf, x: 556 * k - tw, y: 78 * k, color: accent)

        func centered(_ s: String, _ cx: CGFloat, _ base: CGFloat, _ font: NSFont, _ color: NSColor) {
            let w = Typo.width(s, font)
            drawLeft(g, s, font: font, x: (cx - w / 2), y: base, color: color)
        }
        // 星期列
        let fw = cal.firstWeekday
        let syms = cal.veryShortWeekdaySymbols
        let wf = FaceType.sf(31 * k, .bold, mono: false)
        for i in 0..<7 { centered(syms[(fw - 1 + i) % 7], (80 + CGFloat(i) * 71.2) * k, 141 * k, wf, ink) }

        // 六週格（first／off／start／month 已在巨數字前算好）
        let nf = FaceType.sf(32 * k, .semibold, mono: false)
        for i in 0..<42 {
            let d = cal.date(byAdding: .day, value: i, to: start)!
            let col = i % 7, row = i / 7
            let cx = (80 + CGFloat(col) * 71.2) * k, y = (204 + CGFloat(row) * 63.2) * k
            let inMonth = cal.component(.month, from: d) == month
            let n = cal.component(.day, from: d)
            if inMonth && n == today {
                g.setFillColor(todayFill.cgColor)
                g.fillEllipse(in: CGRect(x: cx - 31 * k, y: y - 11 * k - 31 * k, width: 62 * k, height: 62 * k))
                centered(String(n), cx, y, nf, todayText)
            } else {
                centered(String(n), cx, y, nf, ink.withAlphaComponent(inMonth ? 1 : (ic ? 0.5 : 0.3)))
            }
        }
    }
}
