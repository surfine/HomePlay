// HPDS 第四輪：HPIcons——主畫面與 App 資料庫的每一個 App 圖示都是我們自己畫的（進口替代：不再讀 /System/Applications）。
// 每個圖示三層（照 Icon Composer 的分層與光）：底（上亮下深的漸層）、主體（浮在底上的形狀，帶一點往下的柔影）、亮邊（頂緣最亮）。
// 配色與構圖對齊官方 HomeView 內建 App 清單（app-icons-list）：底色的上、下兩端量自清單（驗收 ΔE ≤ 3，tooling 的對照表），
// 主體的形狀、比例都是用程式重新畫的（不描圖、不取樣官方像素當圖案）。數字都是圖示邊長的比例（0…1，左上原點、y 往下）。
// 單獨出圖：homeplay-pet --hpicons-png out.png（全部圖示排一張，給對照表用）。

import AppKit
import CoreText

enum HPIcons {
    enum Kind: String, CaseIterable {
        case alarms, timers, worldClock, calendar, facetime, home, intercom, messages, music, podcasts, reminders, settings, weather, findMy, safari, clioTalk
    }

    /// App id → 圖示（外殼知道是哪個 App 時先用這個；FaceTime、對講由 App 包加進 AppRegistry，id 是 "facetime"、"intercom"）
    static func kind(forID id: String) -> Kind? {
        switch id {
        case "timers": return .timers
        case "worldclock", "worldClock": return .worldClock
        case "alarms": return .alarms
        case "weather": return .weather
        case "calendar": return .calendar
        case "reminders": return .reminders
        case "music": return .music
        case "podcasts": return .podcasts
        case "home": return .home
        case "findmy": return .findMy
        case "safari": return .safari
        case "messages": return .messages
        case "cliotalk", "clioTalk": return .clioTalk
        case "settings": return .settings
        case "facetime": return .facetime
        case "intercom": return .intercom
        default: return nil
        }
    }

    /// App 用的 SF Symbol → 我們自己畫的圖示（只有 AppIcon、不知道 App id 的地方用；App 的 AppIcon 不必改）
    static func kind(forSymbol s: String) -> Kind? {
        switch s {
        case "alarm.fill", "alarm": return .alarms
        case "timer": return .timers
        case "globe": return .worldClock
        case "calendar": return .calendar
        case "video.fill", "video": return .facetime
        case "house.fill", "house": return .home
        case "person.wave.2.fill", "megaphone.fill", "intercom": return .intercom
        case "message.fill", "message": return .messages
        case "music.note": return .music
        case "antenna.radiowaves.left.and.right", "podcasts": return .podcasts
        case "checklist": return .reminders
        case "gearshape.fill", "gearshape": return .settings
        case "cloud.sun.fill": return .weather
        case "location.fill": return .findMy
        case "safari", "safari.fill", "compass.drawing": return .safari
        case "waveform": return .clioTalk
        default: return nil
        }
    }

    // MARK: 色（底色兩端量自官方清單；主體色是我們配的）
    static let baseTop = srgb(0xF19E42)
    static let baseBottom = srgb(0xEF7F32)
    /// 主體的奶白（不是純白：官方圓環中段 #FAFBF5、陰面 #F5E6D8）
    static let glyph = srgb(0xFDF8F1)
    static let glyphShade = srgb(0xF3E2D2)
    /// 計時器已經走過的那一塊扇形
    static let wedge = srgb(0xB4520F)

    /// 每個圖示的底：上、下兩端
    static func base(_ k: Kind) -> (top: NSColor, bottom: NSColor) {
        switch k {
        case .alarms, .timers, .worldClock: return (baseTop, baseBottom)
        case .calendar, .home, .intercom, .reminders, .safari: return (srgb(0xFFFFFF), srgb(0xF4F4F6))
        case .facetime, .messages: return (srgb(0x83EC7C), srgb(0x61CD53))
        case .music: return (srgb(0xEE4A62), srgb(0xEB333B))
        case .podcasts: return (srgb(0x883FBD), srgb(0x692D8F))
        case .settings: return (srgb(0x9D9CA1), srgb(0x77767C))
        case .weather: return (srgb(0x569BFA), srgb(0x3771D2))
        case .findMy: return (srgb(0x5DD56C), srgb(0x2FB146))
        case .clioTalk: return (srgb(0x2E2C38), srgb(0x111116))
        }
    }
    /// 白底的圖示（App 資料庫、淺色主畫面上要一圈很淡的邊才看得出輪廓）
    static func isLight(_ k: Kind) -> Bool { [.calendar, .home, .intercom, .reminders, .safari].contains(k) }

    // MARK: 畫

    static func draw(_ k: Kind, _ g: CGContext, in r: CGRect, date: Date? = nil) {
        let s = r.width
        let path = continuousRoundedRect(r, radius: s * 0.2237)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + s * fx, y: r.minY + s * fy) }
        g.saveGState()
        g.addPath(path); g.clip()
        // 1. 底：上亮下深
        let b = base(k)
        let grad = CGGradient(colorsSpace: cs, colors: [b.top.cgColor, b.bottom.cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: p(0.5, 0), end: p(0.5, 1), options: [])

        // 2. 主體：浮在底上，往下一點柔影（影子帶底色的深一階，不是灰）
        g.saveGState()
        let shadow = shadowColor(k)
        g.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: shadow.cgColor)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        g.setLineCap(.round); g.setLineJoin(.round)
        let u = Unit(r: r)
        switch k {
        case .alarms, .timers, .worldClock: drawClockFamily(k, g, u)
        case .calendar: drawCalendar(g, u, date: date ?? Face.displayDate)
        case .facetime: drawFaceTime(g, u)
        case .home: drawHome(g, u)
        case .intercom: drawIntercom(g, u)
        case .messages: drawMessages(g, u)
        case .music: drawMusic(g, u)
        case .podcasts: drawPodcasts(g, u)
        case .reminders: drawReminders(g, u)
        case .settings: drawSettings(g, u)
        case .weather: drawWeather(g, u)
        case .findMy: drawFindMy(g, u)
        case .safari: drawSafari(g, u)
        case .clioTalk: drawClioTalk(g, u)
        }
        g.endTransparencyLayer()
        g.restoreGState()

        // 3. 亮邊：沿輪廓一圈，上緣最亮、往下淡掉（Liquid Glass 圖示的光）；白底的換成很淡的灰邊
        g.addPath(path); g.setLineWidth(max(1.5, s * 0.02)); g.replacePathWithStrokedPath(); g.clip()
        let rimColors: [CGColor] = isLight(k)
            ? [NSColor(white: 0.80, alpha: 0.35).cgColor, NSColor(white: 0.80, alpha: 0.5).cgColor, NSColor(white: 0.72, alpha: 0.55).cgColor]
            : [NSColor(white: 1, alpha: 0.6).cgColor, NSColor(white: 1, alpha: 0.05).cgColor, NSColor(white: 1, alpha: 0.2).cgColor]
        let rim = CGGradient(colorsSpace: cs, colors: rimColors as CFArray, locations: [0, 0.55, 1])!
        g.drawLinearGradient(rim, start: p(0, 0), end: p(1, 1), options: [])
        g.restoreGState()
    }

    private static func shadowColor(_ k: Kind) -> NSColor {
        switch k {
        case .alarms, .timers, .worldClock: return NSColor(srgbRed: 0.55, green: 0.22, blue: 0, alpha: 0.35)
        case .facetime, .messages: return NSColor(srgbRed: 0.1, green: 0.45, blue: 0.1, alpha: 0.35)
        case .music: return NSColor(srgbRed: 0.5, green: 0.02, blue: 0.1, alpha: 0.35)
        case .podcasts: return NSColor(srgbRed: 0.25, green: 0.05, blue: 0.4, alpha: 0.4)
        case .weather: return NSColor(srgbRed: 0.05, green: 0.2, blue: 0.5, alpha: 0.35)
        case .settings: return NSColor(white: 0.15, alpha: 0.4)
        case .findMy: return NSColor(srgbRed: 0.05, green: 0.4, blue: 0.1, alpha: 0.35)
        case .clioTalk: return NSColor(white: 0, alpha: 0.5)
        case .calendar, .home, .intercom, .reminders, .safari: return NSColor(white: 0, alpha: 0.12)
        }
    }

    /// 圖示裡的比例座標
    struct Unit {
        let r: CGRect
        var s: CGFloat { r.width }
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + s * fx, y: r.minY + s * fy) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: r.minX + s * x, y: r.minY + s * y, width: s * w, height: s * h) }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat) -> CGRect { rect(cx - rad, cy - rad, rad * 2, rad * 2) }
    }

    /// 在 path 的範圍裡畫上下漸層（主體的「體積」）
    private static func fill(_ g: CGContext, _ path: CGPath, _ top: NSColor, _ bottom: NSColor? = nil) {
        g.saveGState()
        g.addPath(path)
        if let bottom {
            g.clip()
            let box = path.boundingBoxOfPath
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(grad, start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
        } else {
            g.setFillColor(top.cgColor); g.fillPath()
        }
        g.restoreGState()
    }
    private static func stroke(_ g: CGContext, _ path: CGPath, _ w: CGFloat, _ c: NSColor = glyph) {
        g.addPath(path); g.setLineWidth(w); g.setStrokeColor(c.cgColor); g.strokePath()
    }
    private static func ellipse(_ r: CGRect) -> CGPath { CGPath(ellipseIn: r, transform: nil) }

    // MARK: 鬧鐘、計時器、世界時鐘（橘色家族）

    private static func drawClockFamily(_ k: Kind, _ g: CGContext, _ u: Unit) {
        let s = u.s, c = u.p(0.5, 0.53), ring = s * 0.335, lw = s * 0.072
        switch k {
        case .alarms:
            // 兩個鈴：圓環左上、右上，一半藏在圓環後面
            g.setFillColor(glyphShade.cgColor)
            for fx: CGFloat in [0.215, 0.785] { g.fillEllipse(in: u.circle(fx, 0.235, 0.13)) }
            g.setBlendMode(.clear); g.fillEllipse(in: CGRect(x: c.x - ring - lw, y: c.y - ring - lw, width: (ring + lw) * 2, height: (ring + lw) * 2)); g.setBlendMode(.normal)
            stroke(g, ellipse(CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)), lw)
            let check = CGMutablePath()
            check.move(to: u.p(0.375, 0.415)); check.addLine(to: u.p(0.5, 0.53)); check.addLine(to: u.p(0.675, 0.36))
            stroke(g, check, lw)
        case .timers:
            let a0 = -CGFloat.pi / 2, a1 = -CGFloat.pi / 2 - 0.70
            g.move(to: c); g.addArc(center: c, radius: ring - lw / 2, startAngle: a0, endAngle: a1, clockwise: true); g.closePath()
            g.setFillColor(wedge.cgColor); g.fillPath()
            stroke(g, ellipse(CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)), lw)
            let hand = CGMutablePath(); hand.move(to: c)
            hand.addLine(to: CGPoint(x: c.x + cos(a1) * ring * 0.78, y: c.y + sin(a1) * ring * 0.78))
            stroke(g, hand, s * 0.05)
            g.setFillColor(glyph.cgColor); g.fillEllipse(in: CGRect(x: c.x - s * 0.04, y: c.y - s * 0.04, width: s * 0.08, height: s * 0.08))
        default:
            let rr = s * 0.355, thin = s * 0.042
            stroke(g, ellipse(CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), s * 0.055)
            let v = CGMutablePath(); v.move(to: CGPoint(x: c.x, y: c.y - rr)); v.addLine(to: CGPoint(x: c.x, y: c.y + rr))
            stroke(g, v, thin)
            stroke(g, ellipse(CGRect(x: c.x - rr * 0.5, y: c.y - rr, width: rr, height: rr * 2)), thin)
            for fy: CGFloat in [-0.5, 0, 0.5] {
                let y = c.y + rr * fy, half = sqrt(max(0, rr * rr - (rr * fy) * (rr * fy)))
                let h = CGMutablePath(); h.move(to: CGPoint(x: c.x - half, y: y)); h.addLine(to: CGPoint(x: c.x + half, y: y))
                stroke(g, h, thin)
            }
        }
    }

    // MARK: 行事曆（動態：星期＋日期）

    /// 行事曆圖示上的兩行字（星期、日期）：跟著 Face.displayDate（真實執行＝今天；--demo-official＝4/1 星期三）
    static func calendarFace(_ date: Date) -> (weekday: String, day: String) {
        (Face.formatter("EEE").string(from: date), String(Calendar.current.component(.day, from: date)))
    }

    private static func drawCalendar(_ g: CGContext, _ u: Unit, date: Date) {
        let (wd, day) = calendarFace(date)
        let wf = FaceType.sf(u.s * 0.165, .semibold, mono: false)
        let df = FaceType.sf(u.s * 0.58, .regular, mono: false)
        text(g, wd, wf, srgb(0xE8433C), cx: u.p(0.5, 0).x, baseline: u.p(0, 0.265).y)
        text(g, day, df, srgb(0x111111), cx: u.p(0.5, 0).x, baseline: u.p(0, 0.80).y)
    }

    /// 置中畫一行字（左上原點的畫布）
    static func text(_ g: CGContext, _ s: String, _ f: NSFont, _ c: NSColor, cx: CGFloat, baseline: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c]))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        g.saveGState()
        g.translateBy(x: cx - CGFloat(w) / 2, y: baseline); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
    }

    // MARK: FaceTime（綠底、白色攝影機：圓角機身＋梯形鏡頭）

    private static func drawFaceTime(_ g: CGContext, _ u: Unit) {
        let body = continuousRoundedRect(u.rect(0.14, 0.285, 0.505, 0.43), radius: u.s * 0.095)
        fill(g, body, srgb(0xF7FDF6), srgb(0xE6F8E4))
        let lens = CGMutablePath()
        lens.move(to: u.p(0.685, 0.43)); lens.addLine(to: u.p(0.835, 0.315))
        lens.addLine(to: u.p(0.835, 0.685)); lens.addLine(to: u.p(0.685, 0.57)); lens.closeSubpath()
        g.saveGState()
        g.addPath(lens); g.setLineWidth(u.s * 0.06); g.setLineJoin(.round)
        g.setStrokeColor(srgb(0xE9F9E7).cgColor); g.setFillColor(srgb(0xE9F9E7).cgColor)
        g.drawPath(using: .fillStroke)
        g.restoreGState()
    }

    // MARK: 訊息（綠底、白色對話泡泡）

    private static func drawMessages(_ g: CGContext, _ u: Unit) {
        let oval = CGPath(ellipseIn: u.rect(0.135, 0.17, 0.73, 0.6), transform: nil)
        // 左下的小尾巴：從泡泡裡面長出來，往左下尖出去再彎回泡泡底
        let tail = CGMutablePath()
        tail.move(to: u.p(0.26, 0.58))
        tail.addCurve(to: u.p(0.15, 0.83), control1: u.p(0.26, 0.70), control2: u.p(0.22, 0.79))
        tail.addCurve(to: u.p(0.42, 0.72), control1: u.p(0.27, 0.82), control2: u.p(0.35, 0.78))
        tail.closeSubpath()
        // 兩塊用同一道漸層（同一個範圍），合起來看是一個形狀
        let box = u.rect(0.135, 0.17, 0.73, 0.66)
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [srgb(0xF2FEF2).cgColor, srgb(0xE0F7E2).cgColor] as CFArray, locations: [0, 1])!
        for path in [oval, tail as CGPath] {
            g.saveGState(); g.addPath(path); g.clip()
            g.drawLinearGradient(grad, start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
            g.restoreGState()
        }
    }

    // MARK: 家庭（白底、橘色房子：外框、裡面一層淡橘、最裡面奶黃的小房子）

    private static func house(_ u: Unit, peak: CGFloat, eave: CGFloat, bottom: CGFloat, half: CGFloat, overhang: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: u.p(0.5, peak))
        p.addLine(to: u.p(0.5 + half + overhang, eave))
        p.addLine(to: u.p(0.5 + half, eave))
        p.addLine(to: u.p(0.5 + half, bottom))
        p.addLine(to: u.p(0.5 - half, bottom))
        p.addLine(to: u.p(0.5 - half, eave))
        p.addLine(to: u.p(0.5 - half - overhang, eave))
        p.closeSubpath()
        return p
    }
    private static func drawHome(_ g: CGContext, _ u: Unit) {
        // 煙囪（在屋頂後面）
        fill(g, continuousRoundedRect(u.rect(0.735, 0.2, 0.085, 0.2), radius: u.s * 0.015), srgb(0xF0923A))
        let outer = house(u, peak: 0.17, eave: 0.485, bottom: 0.79, half: 0.27, overhang: 0.1)
        // 圓角：用同色描邊撐出圓角
        g.saveGState(); g.addPath(outer); g.setLineWidth(u.s * 0.045); g.setLineJoin(.round); g.setStrokeColor(srgb(0xF29638).cgColor); g.strokePath(); g.restoreGState()
        fill(g, outer, srgb(0xF39C3B), srgb(0xF08A33))
        let mid = house(u, peak: 0.33, eave: 0.5, bottom: 0.735, half: 0.185, overhang: 0)
        g.saveGState(); g.addPath(mid); g.setLineWidth(u.s * 0.03); g.setLineJoin(.round); g.setStrokeColor(srgb(0xF6C670).cgColor); g.strokePath(); g.restoreGState()
        fill(g, mid, srgb(0xF8D07E), srgb(0xF5BE5E))
        let inner = house(u, peak: 0.455, eave: 0.545, bottom: 0.64, half: 0.065, overhang: 0)
        g.saveGState(); g.addPath(inner); g.setLineWidth(u.s * 0.025); g.setLineJoin(.round); g.setStrokeColor(srgb(0xFBF3C8).cgColor); g.strokePath(); g.restoreGState()
        fill(g, inner, srgb(0xFCF6D2), srgb(0xF8EBB5))
    }

    // MARK: 對講（白底、橘色直條排成一顆圓，右下一顆小點）

    private static func drawIntercom(_ g: CGContext, _ u: Unit) {
        let n = 9, x0: CGFloat = 0.155, x1: CGFloat = 0.845, R: CGFloat = 0.37
        for i in 0..<n {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(n - 1)
            let dx = x - 0.5
            let h = 2 * sqrt(max(0, R * R - dx * dx)) * 0.96
            let w = u.s * 0.044
            let r = CGRect(x: u.p(x, 0).x - w / 2, y: u.p(0, 0.5 - h / 2).y, width: w, height: u.s * h)
            fill(g, CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil), srgb(0xF4A443), srgb(0xF0922F))
        }
        g.setFillColor(srgb(0xF6BE6A).cgColor); g.fillEllipse(in: u.circle(0.80, 0.835, 0.034))
    }

    // MARK: 音樂（紅底、白色雙八分音符）

    private static func drawMusic(_ g: CGContext, _ u: Unit) {
        let ink = srgb(0xFFF3F6), inkB = srgb(0xF7D8DE)
        let note = CGMutablePath()
        // 橫桿（往右上斜）＋兩根符桿
        note.move(to: u.p(0.385, 0.255)); note.addLine(to: u.p(0.715, 0.185))
        note.addLine(to: u.p(0.715, 0.29)); note.addLine(to: u.p(0.385, 0.36)); note.closeSubpath()
        note.addRect(u.rect(0.385, 0.27, 0.07, 0.44))
        note.addRect(u.rect(0.645, 0.2, 0.07, 0.44))
        fill(g, note, ink, inkB)
        // 符頭：斜放的橢圓
        for (cx, cy) in [(CGFloat(0.335), CGFloat(0.715)), (0.595, 0.645)] {
            g.saveGState()
            let c = u.p(cx, cy)
            g.translateBy(x: c.x, y: c.y); g.rotate(by: -0.38)
            let e = CGRect(x: -u.s * 0.115, y: -u.s * 0.085, width: u.s * 0.23, height: u.s * 0.17)
            fill(g, ellipse(e), ink, inkB)
            g.restoreGState()
        }
    }

    // MARK: Podcast（紫底、一圈圈淡紫的聲波、中間的人形麥克風）

    private static func drawPodcasts(_ g: CGContext, _ u: Unit) {
        fill(g, ellipse(u.circle(0.5, 0.42, 0.385)), srgb(0x9A52CC, 0.85), srgb(0x8A44BD, 0.85))
        fill(g, ellipse(u.circle(0.5, 0.42, 0.285)), srgb(0xBC72E8), srgb(0xA65DD6))
        fill(g, ellipse(u.circle(0.5, 0.42, 0.185)), srgb(0xD596F6), srgb(0xC783F0))
        // 頭＋身體（膠囊）
        fill(g, ellipse(u.circle(0.5, 0.37, 0.075)), srgb(0xFCE4FF), srgb(0xF4D2FC))
        let body = CGPath(roundedRect: u.rect(0.44, 0.49, 0.12, 0.37), cornerWidth: u.s * 0.06, cornerHeight: u.s * 0.06, transform: nil)
        fill(g, body, srgb(0xEEDDF8), srgb(0xD7C2E8))
    }

    // MARK: 提醒事項（白底、三個彩色圓圈＋灰線）

    private static func drawReminders(_ g: CGContext, _ u: Unit) {
        let rows: [(CGFloat, NSColor, NSColor)] = [(0.245, srgb(0x2F86F6), srgb(0xD3F4FF)), (0.5, srgb(0xE4393B), srgb(0xF8CACB)), (0.755, srgb(0xF0973A), srgb(0xFBDDB4))]
        for (y, ring, inner) in rows {
            let rr = u.circle(0.195, y, 0.062)
            g.setFillColor(inner.cgColor); g.fillEllipse(in: rr)
            g.setStrokeColor(ring.cgColor); g.setLineWidth(u.s * 0.034); g.strokeEllipse(in: rr)
            let l = CGMutablePath(); l.move(to: u.p(0.355, y)); l.addLine(to: u.p(0.895, y))
            g.setLineCap(.round); stroke(g, l, u.s * 0.014, srgb(0xC9C9CE))
        }
    }

    // MARK: 設定（灰底、兩層齒輪＋三根輻條）

    private static func gear(_ u: Unit, cx: CGFloat, cy: CGFloat, outer: CGFloat, root: CGFloat, teeth: Int, duty: CGFloat = 0.5) -> CGMutablePath {
        let p = CGMutablePath(), c = u.p(cx, cy)
        let n = teeth * 4
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            let phase = i % 4
            let rad = (phase == 1 || phase == 2) ? outer : root
            let aa = a + (phase == 1 ? (0.5 - duty) * .pi / CGFloat(teeth) : phase == 2 ? -(0.5 - duty) * .pi / CGFloat(teeth) : 0)
            let pt = CGPoint(x: c.x + cos(aa) * rad * u.s, y: c.y + sin(aa) * rad * u.s)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
    private static func drawSettings(_ g: CGContext, _ u: Unit) {
        // 外齒輪：亮灰白，中間挖空
        let big = gear(u, cx: 0.5, cy: 0.5, outer: 0.425, root: 0.385, teeth: 36, duty: 0.42)
        big.addEllipse(in: u.circle(0.5, 0.5, 0.315))
        g.saveGState(); g.addPath(big); g.clip(using: .evenOdd)
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [srgb(0xFAFAFB).cgColor, srgb(0xD9D9DD).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: u.p(0.5, 0.08), end: u.p(0.5, 0.92), options: [])
        g.restoreGState()
        // 裡面一圈深灰、再一個小齒輪
        g.setFillColor(srgb(0x6E6E72).cgColor); g.fillEllipse(in: u.circle(0.5, 0.5, 0.315))
        let small = gear(u, cx: 0.5, cy: 0.5, outer: 0.285, root: 0.255, teeth: 24, duty: 0.45)
        small.addEllipse(in: u.circle(0.5, 0.5, 0.2))
        g.saveGState(); g.addPath(small); g.setFillColor(srgb(0xA9A9AD).cgColor); g.fillPath(using: .evenOdd); g.restoreGState()
        // 三根輻條＋中心圈（白）
        let spokes = CGMutablePath()
        for k in 0..<3 {
            let a = -CGFloat.pi / 6 + CGFloat(k) * 2 * .pi / 3
            spokes.move(to: u.p(0.5, 0.5))
            spokes.addLine(to: CGPoint(x: u.p(0.5, 0.5).x + cos(a) * u.s * 0.3, y: u.p(0.5, 0.5).y + sin(a) * u.s * 0.3))
        }
        stroke(g, spokes, u.s * 0.048, srgb(0xF4F4F6))
        g.setStrokeColor(srgb(0xF4F4F6).cgColor); g.setLineWidth(u.s * 0.035); g.strokeEllipse(in: u.circle(0.5, 0.5, 0.075))
        g.setFillColor(srgb(0x8A8A8E).cgColor); g.fillEllipse(in: u.circle(0.5, 0.5, 0.055))
    }

    // MARK: 天氣（藍底、黃太陽在後、白雲在前）

    private static func drawWeather(_ g: CGContext, _ u: Unit) {
        fill(g, ellipse(u.circle(0.665, 0.37, 0.165)), srgb(0xF8CF4C), srgb(0xF2A938))
        let cloud = CGMutablePath()
        cloud.addEllipse(in: u.circle(0.33, 0.6, 0.15))
        cloud.addEllipse(in: u.circle(0.5, 0.5, 0.19))
        cloud.addEllipse(in: u.circle(0.685, 0.6, 0.15))
        cloud.addPath(CGPath(roundedRect: u.rect(0.18, 0.56, 0.655, 0.19), cornerWidth: u.s * 0.095, cornerHeight: u.s * 0.095, transform: nil))
        g.saveGState(); g.setAlpha(0.96)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        fill(g, cloud, srgb(0xF6FAFF), srgb(0xA9C8F0))
        g.endTransparencyLayer()
        g.restoreGState()
    }

    // MARK: 尋找（P10：綠底、白色同心圈＋中間綠點；系統或官網圖示拿不到時才用）

    private static func drawFindMy(_ g: CGContext, _ u: Unit) {
        g.setStrokeColor(srgb(0xF3FFF4).cgColor)
        g.setLineWidth(u.s * 0.07); g.strokeEllipse(in: u.circle(0.5, 0.5, 0.30))
        g.setStrokeColor(srgb(0xF3FFF4, 0.6).cgColor)
        g.setLineWidth(u.s * 0.05); g.strokeEllipse(in: u.circle(0.5, 0.5, 0.17))
        fill(g, CGPath(ellipseIn: u.circle(0.5, 0.5, 0.075), transform: nil), srgb(0xFFFFFF), srgb(0xE6F7E8))
    }

    // MARK: Safari（P10：白底、藍色錶盤＋紅白指針；系統或官網圖示拿不到時才用）

    private static func drawSafari(_ g: CGContext, _ u: Unit) {
        fill(g, CGPath(ellipseIn: u.circle(0.5, 0.5, 0.38), transform: nil), srgb(0x3FB8FF), srgb(0x1C6FE8))
        g.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor); g.setLineWidth(u.s * 0.008)
        for i in 0..<24 {
            let a = CGFloat(i) / 24 * 2 * .pi, r0: CGFloat = i % 6 == 0 ? 0.29 : 0.32
            g.move(to: u.p(0.5 + sin(a) * r0, 0.5 - cos(a) * r0)); g.addLine(to: u.p(0.5 + sin(a) * 0.355, 0.5 - cos(a) * 0.355))
        }
        g.strokePath()
        // 指針：往右上（紅）、往左下（白）
        let a: CGFloat = .pi / 4, w: CGFloat = 0.055, len: CGFloat = 0.27
        let tip = u.p(0.5 + sin(a) * len, 0.5 - cos(a) * len), tail = u.p(0.5 - sin(a) * len, 0.5 + cos(a) * len)
        let l = u.p(0.5 - cos(a) * w, 0.5 - sin(a) * w), r = u.p(0.5 + cos(a) * w, 0.5 + sin(a) * w)
        let red = CGMutablePath(); red.move(to: tip); red.addLine(to: l); red.addLine(to: r); red.closeSubpath()
        let white = CGMutablePath(); white.move(to: tail); white.addLine(to: l); white.addLine(to: r); white.closeSubpath()
        g.addPath(red); g.setFillColor(srgb(0xFF3B30).cgColor); g.fillPath()
        g.addPath(white); g.setFillColor(NSColor.white.cgColor); g.fillPath()
    }

    // MARK: ClioTalk（我們自己的 App：近黑底、紫到粉的聲波）

    private static func drawClioTalk(_ g: CGContext, _ u: Unit) {
        let hs: [CGFloat] = [0.16, 0.30, 0.46, 0.34, 0.52, 0.30, 0.18]
        let w = u.s * 0.058
        for (i, h) in hs.enumerated() {
            let x = 0.23 + CGFloat(i) * 0.09
            let r = CGRect(x: u.p(x, 0).x - w / 2, y: u.p(0, 0.5 - h / 2).y, width: w, height: u.s * h)
            let t = CGFloat(i) / CGFloat(hs.count - 1)
            let top = NSColor(srgbRed: 0.77 + 0.23 * t, green: 0.55, blue: 1 - 0.15 * t, alpha: 1)
            fill(g, CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil), top, top.blended(withFraction: 0.25, of: .black) ?? top)
        }
    }

    // MARK: 出圖（--hpicons-png）

    /// 全部圖示排成一張（白底，跟官方清單一樣的版面：4 欄、圖示 132、下面名字）
    static func sheet(px: CGFloat = 132) -> CGImage? {
        let kinds = Kind.allCases
        let cols = 5, cell = px * 1.7
        let rows = (kinds.count + cols - 1) / cols
        let w = Int(CGFloat(cols) * cell), h = Int(CGFloat(rows) * cell)
        return makeImage(w, h) { g in
            g.setFillColor(NSColor.white.cgColor); g.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 1)) ?? Date()
            for (i, k) in kinds.enumerated() {
                let x = CGFloat(i % cols) * cell + (cell - px) / 2, y = CGFloat(i / cols) * cell + cell * 0.12
                draw(k, g, in: CGRect(x: x, y: y, width: px, height: px), date: date)
                text(g, k.rawValue, NSFont.systemFont(ofSize: px * 0.17), srgb(0x6E6E73), cx: x + px / 2, baseline: y + px + px * 0.3)
            }
        }
    }
    static func writeSheet(_ path: String) {
        guard let img = sheet() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
