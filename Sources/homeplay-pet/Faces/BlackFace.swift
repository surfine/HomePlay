// 黑：OLED 全黑，純黑膠囊和背景融成一體，只看得到 👀。
// 夜間（22:00–06:59，或睡著）：眼睛闔上（床頭夜灯同一條暗紅路徑），下方一行暗紅時間，沒有光暈。
// 白天：不顯示時間；人靠近（reveal > 0.5）才在膠囊上方浮出一行小白字。

import AppKit

nonisolated(unsafe) private var blackLastMinute = -1

extension Face {
    private var blackIsNight: Bool {
        if expression == .asleep { return true }
        let h = hourOverride.map { Int($0) } ?? Calendar.current.component(.hour, from: Self.displayDate)
        return h >= 22 || h < 7
    }

    func renderBlackFace(_ g: CGContext, _ now: Double) {
        g.setFillColor(NSColor.black.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let (hh, mm) = Self.hourMinute(Self.displayDate)
        let scale: CGFloat = 444 / (420 * 1.4)
        if blackIsNight {
            // 眼睛在上、時間在下（照稿：眼 y≈447，時間基線 y≈690）
            let at = CGPoint(x: 512, y: 447)
            drawIsland(g, at: at, scale: scale, liveAt: at, now: now, red: true)
            drawCentered(g, "\(hh):\(mm)", font: FaceType.sf(157, .light, mono: true), kern: 0, y: 690, color: srgb(0x5a120e))
        } else {
            let at = CGPoint(x: 512, y: 512)
            let rv = reveal
            if rv > 0.5 {
                let a = min(1, (rv - 0.5) / 0.5) * 0.85
                drawCentered(g, "\(hh):\(mm)", font: FaceType.sf(68, .light, mono: true), kern: 0.5, y: 330, color: NSColor.white.withAlphaComponent(a))
            }
            drawIsland(g, at: at, scale: scale, liveAt: at, now: now)
        }
    }

    func tickBlackFace(_ now: Double) -> Bool {
        guard blackIsNight || reveal > 0.5 else { return false }
        let m = Calendar.current.component(.minute, from: Self.displayDate)
        if m != blackLastMinute { blackLastMinute = m; return true }
        return false
    }
}
