import AppKit
import CoreGraphics

// 第一次打开的操作提示（稿：V2FirstRun.dc.html，640 稿 ×1.6）：hello 写完后，屏幕上浮一张玻璃卡，
// 三条最常用的手势；点一下或 12 秒后收起，记下 HomePlayOnboarded。菜单「再看一次操作提示」可以重看。

enum Onboarding {
    static let defaultsKey = "HomePlayOnboarded"
    static let duration = 12.0
    static var armed = false          // 等 hello 写完再出
    static var active = false
    static var until = 0.0
    static var forced = false         // 快照用（--onboarding）：不读也不写偏好
    static var done: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

extension Face {
    var onboardingActive: Bool { Onboarding.active }

    /// 排队：hello 写完（或根本没有 hello）就出现
    func armOnboarding() { Onboarding.armed = true; forceDirty = true }

    func dismissOnboarding() {
        guard Onboarding.active || Onboarding.armed else { return }
        Onboarding.active = false; Onboarding.armed = false
        if !Onboarding.forced { UserDefaults.standard.set(true, forKey: Onboarding.defaultsKey) }
        forceDirty = true
    }

    /// 每帧：到点出现、12 秒后自己收；有变化回 true
    func tickOnboarding(_ now: Double) -> Bool {
        if Onboarding.armed, !sayingHello {
            Onboarding.armed = false; Onboarding.active = true; Onboarding.until = now + Onboarding.duration
            return true
        }
        if Onboarding.active, now >= Onboarding.until { dismissOnboarding(); return true }
        return false
    }

    func drawOnboarding(_ g: CGContext, _ now: Double) {
        let r = CGRect(x: 77, y: 330, width: 870, height: 449)
        glass(g, r, radius: 64, tint: NSColor(white: 1, alpha: 0.18), band: 14)
        let x = r.minX + 51
        drawLeft(g, L("onboarding.title", "嗨，我是 HomePlay"), font: Self.rounded(48, weight: .bold), x: x, y: r.minY + 48 + 40, color: .white)
        let rows = [L("onboarding.carplay", "重按进入 CarPlay"), L("onboarding.menu", "右键看菜单"), L("onboarding.drag", "拖动转身体，双击回正")]
        for (i, text) in rows.enumerated() {
            let top = r.minY + 48 + 56 + 29 + CGFloat(i) * (70 + 29)
            let box = CGRect(x: x, y: top, width: 70, height: 70)
            g.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
            g.addPath(CGPath(roundedRect: box, cornerWidth: 19, cornerHeight: 19, transform: nil)); g.fillPath()
            drawTipGlyph(g, i, in: box)
            drawLeft(g, text, font: Self.rounded(34, weight: .semibold), x: box.maxX + 22, y: box.midY + 12, color: .white)
        }
        drawCentered(g, L("onboarding.start", "点一下开始"), font: Self.rounded(27, weight: .semibold), kern: 0, y: 950,
                     color: NSColor.white.withAlphaComponent(0.75))
    }

    /// 24 点方格里的线稿小图标（重按、菜单、回转箭头），放大到 box 中间
    private func drawTipGlyph(_ g: CGContext, _ i: Int, in box: CGRect) {
        let s = box.width / 44   // 稿里 44 的方格配 24 单位的图标
        g.saveGState()
        g.translateBy(x: box.midX - 12 * s, y: box.midY - 12 * s); g.scaleBy(x: s, y: s)
        g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(2); g.setLineCap(.round); g.setLineJoin(.round)
        switch i {
        case 0:
            // 重按＝CarPlay：屏幕轮廓＋落点圆点＋向下按压的箭头（箭头和圆点拉开，别挤在一起）
            g.addPath(CGPath(roundedRect: CGRect(x: 5, y: 4, width: 14, height: 16), cornerWidth: 4, cornerHeight: 4, transform: nil))
            g.strokePath()
            g.setFillColor(NSColor.white.cgColor)
            g.addArc(center: CGPoint(x: 12, y: 15.8), radius: 2.4, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            g.fillPath()
            g.move(to: CGPoint(x: 12, y: 5.2)); g.addLine(to: CGPoint(x: 12, y: 9.2))
            g.move(to: CGPoint(x: 9.5, y: 7.2)); g.addLine(to: CGPoint(x: 12, y: 9.4)); g.addLine(to: CGPoint(x: 14.5, y: 7.2))
        case 1:
            g.addPath(CGPath(roundedRect: CGRect(x: 4, y: 4, width: 16, height: 16), cornerWidth: 4, cornerHeight: 4, transform: nil))
            g.move(to: CGPoint(x: 9, y: 9)); g.addLine(to: CGPoint(x: 15, y: 9))
            g.move(to: CGPoint(x: 9, y: 13)); g.addLine(to: CGPoint(x: 15, y: 13))
        default:
            // 大半圈弧（左边缺口）加一个箭头：用折线逼近，免得受翻转坐标系的方向影响
            let a0 = CGFloat.pi, a1 = CGFloat.pi * 2.72
            for k in 0...24 {
                let a = a0 + (a1 - a0) * CGFloat(k) / 24, p = CGPoint(x: 12 + 8 * cos(a), y: 12 + 8 * sin(a))
                k == 0 ? g.move(to: p) : g.addLine(to: p)
            }
            g.move(to: CGPoint(x: 4, y: 18)); g.addLine(to: CGPoint(x: 4, y: 12)); g.addLine(to: CGPoint(x: 10, y: 12))
        }
        g.strokePath()
        g.restoreGState()
    }
}
