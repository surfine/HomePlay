// 2.0 hello：HomePlay 自己畫的單線草寫「hello」，一筆寫完。
//
// 這是我們自己為 HomePlay 畫的字（2026-10-25，hellotools/hello-path.json 逐版調出來的），
// 不是描 Apple 的「hello」——Apple 的那個字是 Apple 的美術作品，不描、不抄、不從任何網路上的描稿拿。
// 同樣的精神：單線（固定筆寬、圓頭圓角）、平滑的三次貝茲、略往右斜、升部約 1.76 倍 x 高。
//
// 設計座標：基線 y = 0、x 高 100、升部約 −176，y 往下（跟 1024 畫布一樣）。
// 「寫」的方法：每段貝茲取 48 點，累計弧長；畫到弧長 s 就把折線畫到那一點（最後一點在線段裡內插），
// 圓頭跟著筆尖走（prior art：vivus／lazy-line-painter 的 stroke-dashoffset 想法，CG 裡用部分路徑實作，沒有借程式）。
import CoreGraphics
import Foundation

enum HelloLettering {
    static let start = CGPoint(x: -12, y: -22)
    /// (c1, c2, 終點)
    static let curves: [(CGPoint, CGPoint, CGPoint)] = [
        // h：起筆、升部的圈、往下的筆身、拱、出筆
        (p(14, -12), p(48, -70), p(66, -128)),
        (p(78, -166), p(66, -184), p(54, -172)),
        (p(40, -158), p(28, -60), p(20, 0)),
        (p(34, -56), p(56, -96), p(82, -96)),
        (p(106, -96), p(112, -70), p(108, -44)),
        (p(104, -16), p(112, 0), p(132, -2)),
        // e
        (p(156, -4), p(182, -30), p(186, -58)),
        (p(190, -84), p(164, -96), p(152, -74)),
        (p(140, -50), p(146, -4), p(176, -2)),
        // l
        (p(204, 0), p(230, -80), p(244, -130)),
        (p(254, -168), p(236, -186), p(224, -170)),
        (p(212, -152), p(204, -40), p(220, -8)),
        // l
        (p(232, 12), p(266, -60), p(280, -130)),
        (p(290, -168), p(272, -186), p(260, -170)),
        (p(248, -152), p(240, -40), p(256, -8)),
        // o：從左上進、逆時針一圈、往右上收筆
        (p(268, 14), p(300, -60), p(326, -94)),
        (p(312, -100), p(296, -80), p(296, -50)),
        (p(296, -16), p(312, 2), p(330, 0)),
        (p(352, -2), p(364, -30), p(360, -58)),
        (p(356, -90), p(336, -102), p(326, -94)),
        (p(344, -96), p(366, -92), p(392, -102)),
    ]
    /// 每個字母寫到第幾段為止（h e l l o）
    static let letterEnds = [6, 9, 12, 15, 21]
    static let samplesPerCurve = 48

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    struct Sampled {
        var points: [CGPoint]
        var cum: [CGFloat]          // 每一點的累計弧長
        var curveStart: [CGFloat]   // 第 i 段開頭的累計弧長（最後多一個＝全長）
        var bounds: CGRect
        var length: CGFloat { cum.last ?? 0 }
    }

    static let sampled: Sampled = {
        var pts = [start], cum: [CGFloat] = [0], starts: [CGFloat] = [0]
        var a = start
        for (c1, c2, b) in curves {
            for k in 1...samplesPerCurve {
                let t = CGFloat(k) / CGFloat(samplesPerCurve), u = 1 - t
                let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
                let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
                let q = CGPoint(x: x, y: y)
                cum.append(cum.last! + hypot(q.x - pts.last!.x, q.y - pts.last!.y)); pts.append(q)
            }
            starts.append(cum.last!); a = b
        }
        var r = CGRect.null
        for q in pts { r = r.union(CGRect(origin: q, size: .zero)) }
        return Sampled(points: pts, cum: cum, curveStart: starts, bounds: r)
    }()

    /// 第 i 段開頭的弧長
    static func length(atCurve i: Int) -> CGFloat { sampled.curveStart[max(0, min(curves.count, i))] }

    /// 寫到弧長 s 的部分路徑（設計座標）；s ≥ 全長時回整條貝茲
    static func path(upTo s: CGFloat) -> CGPath {
        let m = CGMutablePath()
        let S = sampled
        if s >= S.length - 0.01 {
            m.move(to: start)
            for (c1, c2, b) in curves { m.addCurve(to: b, control1: c1, control2: c2) }
            return m
        }
        guard s > 0 else { return m }
        m.move(to: S.points[0])
        // 二分找到 s 落在哪一小段
        var lo = 0, hi = S.cum.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if S.cum[mid] <= s { lo = mid } else { hi = mid } }
        if lo > 0 { for i in 1...lo { m.addLine(to: S.points[i]) } }
        let seg = S.cum[hi] - S.cum[lo], f = seg > 0 ? (s - S.cum[lo]) / seg : 0
        let a = S.points[lo], b = S.points[hi]
        m.addLine(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
        return m
    }

    /// 筆尖位置（弧長 s）
    static func tip(at s: CGFloat) -> CGPoint {
        let S = sampled
        let s = max(0, min(S.length, s))
        var lo = 0, hi = S.cum.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if S.cum[mid] <= s { lo = mid } else { hi = mid } }
        let seg = S.cum[hi] - S.cum[lo], f = seg > 0 ? (s - S.cum[lo]) / seg : 0
        let a = S.points[lo], b = S.points[hi]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    static func selftest(_ check: (Bool, String) -> Void) {
        let S = sampled
        check(S.points.count == curves.count * samplesPerCurve + 1 && S.length > 1500 && S.length < 2600, "hello 字：取樣與全長")
        check(zip(S.cum, S.cum.dropFirst()).allSatisfy { $0 <= $1 }, "hello 字：弧長單調")
        // 一筆寫完：每段的起點就是上一段的終點（取樣上沒有跳點）
        let maxStep = zip(S.points, S.points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.max() ?? 0
        check(maxStep < 8, "hello 字：一筆連續、沒有跳點")
        check(letterEnds.last == curves.count && letterEnds == letterEnds.sorted(), "hello 字：字母分段")
        let half = path(upTo: S.length / 2).currentPoint, t = tip(at: S.length / 2)
        check(hypot(half.x - t.x, half.y - t.y) < 0.5, "hello 字：部分路徑停在筆尖")
        check(S.bounds.width > 380 && S.bounds.height > 165 && S.bounds.height < 190, "hello 字：寬高（升部約 1.76 倍 x 高）")
    }
}
