// 錶面「陪伴的痕跡」——照「HomePlay 屏幕介面稿」的 Growth.dc.html 实现。

import AppKit

private var growthLastDay = -1

extension Face {
    func renderGrowthFace(_ g: CGContext, _ now: Double) {
        // 径向深色底
        let cs = CGColorSpaceCreateDeviceRGB()
        if let grad = CGGradient(colorsSpace: cs, colors: [srgb(0x1c2a33).cgColor, srgb(0x0b1014).cgColor] as CFArray, locations: [0, 1]) {
            g.drawRadialGradient(grad, startCenter: CGPoint(x: 512, y: 532), startRadius: 0,
                                 endCenter: CGPoint(x: 512, y: 532), endRadius: 720, options: [.drawsAfterEndLocation])
        }
        let cal = Calendar.current, date = Self.displayDate
        let days = cal.range(of: .day, in: .month, for: date)?.count ?? 30
        let today = cal.component(.day, from: date)
        let on = CompanionLog.daysThisMonth()
        // 一圈点：每天一颗，从正上方顺时针
        for i in 0..<days {
            let a = -CGFloat.pi / 2 + CGFloat(i) / CGFloat(days) * .pi * 2
            let c = CGPoint(x: 512 + cos(a) * 390, y: 512 + sin(a) * 390)
            let isToday = i + 1 == today
            g.saveGState()
            if isToday {
                g.setShadow(offset: .zero, blur: 22, color: srgb(0xffd166).withAlphaComponent(0.8).cgColor)
                g.setFillColor(srgb(0xffd166).cgColor)
            } else if on.contains(i + 1) {
                g.setFillColor(srgb(0x6fd3b8).cgColor)
            } else {
                g.setFillColor(NSColor(white: 1, alpha: 0.12).cgColor)
            }
            g.fillEllipse(in: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
            g.restoreGState()
        }
        let t = GlyphShape(Self.clock(date), font: FaceType.sf(300, .semibold), kern: -4)
            .tall(height: 92, stretch: 1.0, at: CGPoint(x: 512, y: 238), anchorX: 0.5, maxWidth: 520)
        fillShape(g, t, .white)
        drawIsland(g, at: CGPoint(x: 512, y: 500), scale: 0.62, liveAt: CGPoint(x: 512, y: 640), now: now)
        // 计时器长出来时让位给胶囊
        let fade = 1 - liveT
        if fade > 0.01 {
            drawCentered(g, on.count == 1 ? L("growth.days.one", "这个月陪你 1 天") : String(format: L("growth.days", "这个月陪你 %d 天"), on.count), font: Self.rounded(35, weight: .bold), kern: 0, y: 690,
                         color: NSColor(white: 1, alpha: fade))
            drawCentered(g, L("growth.hint", "每天第一次打开，圈上就多一颗"), font: Self.rounded(24, weight: .semibold), kern: 0, y: 730,
                         color: NSColor(white: 1, alpha: 0.55 * fade))
        }
    }
    /// 有需要重画（秒针走动、轮替、漂动）就回 true；没有就回 false，省电
    func tickGrowthFace(_ now: Double) -> Bool {
        let d = Calendar.current.component(.day, from: Date())
        defer { growthLastDay = d }
        if d != growthLastDay { CompanionLog.markToday() }   // 常驻跨过午夜也算新的一天
        return d != growthLastDay
    }
}

/// 陪伴天数：本机记每天第一次打开（UserDefaults），錶面上点成一圈
enum CompanionLog {
    private static let key = "HomePlayCompanionDays"
    private static func fmt() -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }
    static func markToday() {
        let today = fmt().string(from: Date())
        var arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !arr.contains(today) else { return }
        arr.append(today)
        UserDefaults.standard.set(Array(arr.suffix(400)), forKey: key)
    }
    /// 这个月打开过的日子（几号）
    static func daysThisMonth() -> Set<Int> {
        let f = fmt(), cal = Calendar.current, now = Date()
        var out = Set<Int>()
        for s in UserDefaults.standard.stringArray(forKey: key) ?? [] {
            guard let d = f.date(from: s), cal.isDate(d, equalTo: now, toGranularity: .month) else { continue }
            out.insert(cal.component(.day, from: d))
        }
        return out
    }
}
