// HVPlayPauseGlyph.swift — 官方 Timers 播放／暫停字形（固件真值，幾何 1:1）
//
// 來源：HomeView 27.2 (24V514) `Timers.app/PlayPause_orangeLight.ca/main.caml`
// 方法：複合 CALayer 變換鏈（origin scale 0.3333 → shapeparent → play/pause → path 圖層）
//       後把路徑歸一化到自身 bounding box；y 軸翻轉以配合 HomePlay 的 y-down 畫布。
// 實測佔比（84 畫布）：play 0.317 × 0.354、pause 0.270 × 0.360。
// 只有幾何是固件事實；顏色讀法未定（docs/hv-reference/hv_caml_truth.md 第三節），由呼叫端給色。
import AppKit
import CoreGraphics

enum HVPlayPauseGlyph {
    /// 字形在按鈕直徑上的實際佔比（固件量測）
    static func size(play: Bool, diameter d: CGFloat) -> CGSize {
        play ? CGSize(width: d * 0.317, height: d * 0.354)
             : CGSize(width: d * 0.270, height: d * 0.360)
    }

    /// 單位路徑（0…1，y-down）
    static func path(play: Bool) -> CGPath {
        let p = CGMutablePath()
        if play {
            p.move(to: CGPoint(x: 0.916479, y: 0.402175))
            p.addLine(to: CGPoint(x: 0.190083, y: 0.024891))
            p.addCurve(to: CGPoint(x: 0.102930, y: 0.000000), control1: CGPoint(x: 0.156148, y: 0.007624), control2: CGPoint(x: 0.130729, y: 0.000000))
            p.addCurve(to: CGPoint(x: 0.000000, y: 0.103487), control1: CGPoint(x: 0.045955, y: 0.000000), control2: CGPoint(x: 0.000000, y: 0.038457))
            p.addLine(to: CGPoint(x: 0.000000, y: 0.895952))
            p.addCurve(to: CGPoint(x: 0.102930, y: 1.000000), control1: CGPoint(x: 0.000000, y: 0.960982), control2: CGPoint(x: 0.045955, y: 1.000000))
            p.addCurve(to: CGPoint(x: 0.190083, y: 0.974549), control1: CGPoint(x: 0.130729, y: 1.000000), control2: CGPoint(x: 0.156148, y: 0.991815))
            p.addLine(to: CGPoint(x: 0.916479, y: 0.597376))
            p.addCurve(to: CGPoint(x: 1.000000, y: 0.499832), control1: CGPoint(x: 0.972201, y: 0.568674), control2: CGPoint(x: 1.000000, y: 0.542101))
            p.addCurve(to: CGPoint(x: 0.916479, y: 0.402287), control1: CGPoint(x: 1.000000, y: 0.457563), control2: CGPoint(x: 0.972201, y: 0.431551))
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: 0.000000, y: 0.917733))
            p.addLine(to: CGPoint(x: 0.000000, y: 0.081606))
            p.addCurve(to: CGPoint(x: 0.108952, y: 0.000000), control1: CGPoint(x: 0.000000, y: 0.028231), control2: CGPoint(x: 0.037691, y: 0.000000))
            p.addLine(to: CGPoint(x: 0.295789, y: 0.000000))
            p.addCurve(to: CGPoint(x: 0.404741, y: 0.081606), control1: CGPoint(x: 0.367049, y: 0.000000), control2: CGPoint(x: 0.404741, y: 0.025805))
            p.addLine(to: CGPoint(x: 0.404741, y: 0.917622))
            p.addCurve(to: CGPoint(x: 0.295789, y: 0.999890), control1: CGPoint(x: 0.404741, y: 0.971659), control2: CGPoint(x: 0.367049, y: 0.999890))
            p.addLine(to: CGPoint(x: 0.109099, y: 0.999890))
            p.addCurve(to: CGPoint(x: 0.000000, y: 0.917733), control1: CGPoint(x: 0.037839, y: 1.000000), control2: CGPoint(x: 0.000000, y: 0.971769))
            p.closeSubpath()
            p.move(to: CGPoint(x: 0.595112, y: 0.917733))
            p.addLine(to: CGPoint(x: 0.595112, y: 0.081606))
            p.addCurve(to: CGPoint(x: 0.704947, y: 0.000000), control1: CGPoint(x: 0.595112, y: 0.028231), control2: CGPoint(x: 0.632803, y: 0.000000))
            p.addLine(to: CGPoint(x: 0.891048, y: 0.000000))
            p.addCurve(to: CGPoint(x: 1.000000, y: 0.081606), control1: CGPoint(x: 0.963192, y: 0.000000), control2: CGPoint(x: 1.000000, y: 0.025805))
            p.addLine(to: CGPoint(x: 1.000000, y: 0.917622))
            p.addCurve(to: CGPoint(x: 0.891048, y: 0.999890), control1: CGPoint(x: 1.000000, y: 0.971659), control2: CGPoint(x: 0.963192, y: 0.999890))
            p.addLine(to: CGPoint(x: 0.704947, y: 0.999890))
            p.addCurve(to: CGPoint(x: 0.595112, y: 0.917733), control1: CGPoint(x: 0.632803, y: 1.000000), control2: CGPoint(x: 0.595112, y: 0.971769))
            p.closeSubpath()
        }
        return p
    }

    /// 以按鈕圓心與直徑繪製字形（填色由呼叫端決定）
    static func draw(_ g: CGContext, play: Bool, center: CGPoint, diameter: CGFloat, color: NSColor) {
        let s = size(play: play, diameter: diameter)
        let rect = CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height)
        g.saveGState()
        g.translateBy(x: rect.minX, y: rect.minY)
        g.scaleBy(x: rect.width, y: rect.height)
        g.addPath(path(play: play))
        g.setFillColor(color.cgColor)
        g.fillPath()
        g.restoreGState()
    }
}
