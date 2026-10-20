// 錶面「指針」——照「HomePlay 屏幕介面稿」的 Analog.dc.html 实现。
// 只在这个文件里写；可用 Face 的共用绘制：drawIsland、drawLeft、drawCentered、rounded、clock、dateLine…

import AppKit

/// 上次画的秒数（扩展里不能加存储属性）
private var analogLastSecond = -1

extension Face {
    func renderAnalogFace(_ g: CGContext, _ now: Double) {
        g.setFillColor(srgb(0x4f9a6a).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let ink = srgb(0x123a2a), numFont = Face.rounded(240, weight: .medium)
        // 四个大数字：12/6 置中，3/9 贴左右边
        drawCentered(g, "12", font: numFont, kern: -10, y: 232, color: ink)
        drawCentered(g, "6", font: numFont, kern: 0, y: 1002, color: ink)
        drawLeft(g, "9", font: numFont, x: 64, y: 604, color: ink)
        let w3 = (NSAttributedString(string: "3", attributes: [.font: numFont]).size().width)
        drawLeft(g, "3", font: numFont, x: 1024 - 64 - w3, y: 604, color: ink)

        // 时间 → 指针角度（12 点方向为 0，顺时针）
        let cal = Calendar.current, d = Date()
        let c = cal.dateComponents([.hour, .minute, .second, .weekday, .day], from: d)
        let s = Double(c.second ?? 0), m = Double(c.minute ?? 0) + s / 60, h = Double((c.hour ?? 0) % 12) + m / 60
        let ctr = CGPoint(x: 512, y: 512)
        func hand(_ deg: Double, _ len: CGFloat, _ w: CGFloat, _ col: NSColor) {
            let a = deg * .pi / 180
            g.setStrokeColor(col.cgColor); g.setLineWidth(w); g.setLineCap(.round)
            g.move(to: ctr); g.addLine(to: CGPoint(x: ctr.x + CGFloat(sin(a)) * len, y: ctr.y - CGFloat(cos(a)) * len)); g.strokePath()
        }
        hand(h * 30, 224, 25.6, .white)
        hand(m * 6, 330, 16, .white)
        hand(s * 6, 292, 5.6, srgb(0xff9f0a))
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: 512 - 17.6, y: 512 - 17.6, width: 35.2, height: 35.2))
        g.setFillColor(srgb(0xff9f0a).cgColor); g.fillEllipse(in: CGRect(x: 512 - 6.4, y: 512 - 6.4, width: 12.8, height: 12.8))

        // 日期：星期短写 + 日
        let wf = DateFormatter(); wf.locale = L10n.language.locale
        let wds = L10n.language == .en ? wf.shortWeekdaySymbols! : wf.veryShortWeekdaySymbols!   // 英文單個字母（S M T…）分不清，用三個字母
        let wd = wds[((c.weekday ?? 1) - 1) % 7]
        drawLeft(g, "\(wd) \(c.day ?? 1)", font: Face.rounded(32, weight: .bold), x: 70, y: 954, color: ink, kern: 1)

        drawIsland(g, at: CGPoint(x: 512, y: 640), scale: 0.42, liveAt: CGPoint(x: 512, y: 640), now: now)   // 计时胶囊留在中间，不压到下面的 6
    }
    /// 有需要重画（秒针走动、轮替、漂动）就回 true；没有就回 false，省电
    func tickAnalogFace(_ now: Double) -> Bool {
        let s = Calendar.current.component(.second, from: Date())
        if s != analogLastSecond { analogLastSecond = s; return true }
        return false
    }
}
