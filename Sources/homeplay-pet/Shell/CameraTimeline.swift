// 體驗追趕 P4：攝影機近況時間軸——單一攝影機頁的分段 Scrubber＋有人標記＋一句回饋。
//
// HomeKit 不給第三方錄影片段，所以「近況」是這次開著桌寵時拿到的快照與即時畫面：每台最多留 24 格、至少隔 20 秒一格；
// 每格在背景用 Vision 找人（VNDetectHumanRectanglesRequest，本機、不上網），有人的格子在軸上標黃點。
// 相鄰兩格隔 90 秒以內算同一段（軸上一條連續的段）；點軸上一格＝看那一刻，點最右邊＝回到即時。
// 純函式（segments、xPosition、feedback）selftest 直接驗。

import AppKit
import Vision

final class CameraTimeline {
    static let shared = CameraTimeline()
    struct Frame { let at: Double; let image: CGImage; var person: Bool? }

    static let maxFrames = 24
    static let minSpacing: Double = 20
    static let segmentGap: Double = 90

    private(set) var frames: [String: [Frame]] = [:]
    /// 正在看哪一格（nil＝即時／最新）
    var selected: [String: Int] = [:]
    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "homeplay.camera.timeline", qos: .utility)

    /// 收一張（快照或即時畫面）；跟上一格太近就不收
    func add(_ id: String, _ img: CGImage, at t: Double = Date().timeIntervalSince1970, detect: Bool = true) {
        var list = frames[id] ?? []
        if let last = list.last, t - last.at < Self.minSpacing { return }
        list.append(Frame(at: t, image: img, person: nil))
        if list.count > Self.maxFrames {
            list.removeFirst(list.count - Self.maxFrames)
            if let s = selected[id] { selected[id] = s > 0 ? s - 1 : nil }
        }
        frames[id] = list
        guard detect else { return }
        queue.async { [weak self] in
            let req = VNDetectHumanRectanglesRequest()
            req.upperBodyOnly = false
            let found = (try? VNImageRequestHandler(cgImage: img).perform([req])) != nil && !(req.results ?? []).filter { $0.confidence > 0.5 }.isEmpty
            DispatchQueue.main.async {
                guard let self, var l = self.frames[id], let i = l.firstIndex(where: { $0.at == t }) else { return }
                l[i].person = found; self.frames[id] = l
                self.onUpdate?()
            }
        }
    }
    /// 示範資料（快照、--demo-home）：固定的幾格，有人的是第 2、6 格
    func seedDemo(_ id: String, _ img: CGImage, now: Double) {
        guard frames[id] == nil else { return }
        let offsets: [Double] = [-1500, -1460, -1420, -600, -560, -200, -160, -120]
        frames[id] = offsets.enumerated().map { i, o in Frame(at: now + o, image: img, person: i == 2 || i == 6) }
    }

    func image(_ id: String) -> CGImage? {
        guard let i = selected[id], let l = frames[id], i < l.count else { return nil }
        return l[i].image
    }

    // MARK: 純函式

    /// 連續的段（索引範圍）：相鄰兩格隔 ≤ gap 秒算同一段
    static func segments(_ times: [Double], gap: Double = segmentGap) -> [ClosedRange<Int>] {
        guard !times.isEmpty else { return [] }
        var out: [ClosedRange<Int>] = [], start = 0
        for i in 1..<max(1, times.count) where times[i] - times[i - 1] > gap { out.append(start...(i - 1)); start = i }
        out.append(start...(times.count - 1))
        return out
    }
    /// 時間 → 軸上的 x（最舊一格在左緣、現在在右緣；只有一格時放右緣）
    static func xPosition(_ t: Double, oldest: Double, now: Double, in r: CGRect) -> CGFloat {
        guard now > oldest else { return r.maxX }
        return r.minX + r.width * CGFloat(max(0, min(1, (t - oldest) / (now - oldest))))
    }
    /// 一句回饋：最近一次有人的時刻，或「這段時間沒看到人」；還在找就不說
    static func feedback(_ list: [Frame], timeText: (Double) -> String) -> String? {
        guard !list.isEmpty, list.contains(where: { $0.person != nil }) else { return nil }
        if let p = list.last(where: { $0.person == true }) { return String(format: L("home.cam.timeline.person", "%@ 有人经过"), timeText(p.at)) }
        return L("home.cam.timeline.none", "这段时间没看到人")
    }
    /// 點在軸上 → 哪一格（nil＝最右邊那一段＝回到即時）
    static func pick(_ x: CGFloat, times: [Double], now: Double, in r: CGRect) -> Int? {
        guard let oldest = times.first, x < r.maxX - r.width * 0.06 else { return nil }
        let xs = times.map { xPosition($0, oldest: oldest, now: now, in: r) }
        return xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) }
    }

    // MARK: 畫（攝影機全螢幕頁，標題下面）
    static let track = CGRect(x: 160, y: 262, width: 704, height: 10)
    static var hitArea: CGRect { track.insetBy(dx: -16, dy: -34) }

    static func timeText(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date(timeIntervalSince1970: t))
    }

    func draw(_ g: CGContext, face: Face, id: String, now: Double) {
        guard let list = frames[id], !list.isEmpty else { return }
        let r = Self.track, times = list.map(\.at), oldest = times[0]
        g.saveGState()
        g.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor); g.addPath(HPComponents.capsulePath(r)); g.fillPath()
        for seg in Self.segments(times) {   // 有畫面的段：實白
            let x0 = Self.xPosition(times[seg.lowerBound], oldest: oldest, now: now, in: r) - 5
            let x1 = Self.xPosition(times[seg.upperBound], oldest: oldest, now: now, in: r) + 5
            g.setFillColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            g.addPath(HPComponents.capsulePath(CGRect(x: max(r.minX, x0), y: r.minY, width: max(10, min(r.maxX, x1) - max(r.minX, x0)), height: r.height))); g.fillPath()
        }
        for f in list where f.person == true {   // 有人：黃點（官方的人標用黃色系）
            let x = Self.xPosition(f.at, oldest: oldest, now: now, in: r)
            g.setFillColor(HPTokens.yellow.cgColor); g.fillEllipse(in: CGRect(x: x - 9, y: r.midY - 9, width: 18, height: 18))
        }
        // 正在看的那一刻：白色直條；看即時時在右緣
        let cx = selected[id].flatMap { $0 < list.count ? Self.xPosition(list[$0].at, oldest: oldest, now: now, in: r) : nil } ?? r.maxX
        g.setFillColor(NSColor.white.cgColor)
        g.addPath(HPComponents.capsulePath(CGRect(x: cx - 3, y: r.midY - 22, width: 6, height: 44))); g.fillPath()
        g.restoreGState()
        if let s = Self.feedback(list, timeText: Self.timeText) {
            let font = HPComponents.sf(26, weight: .regular)
            let w = Typo.width(s, font)
            face.drawLeft(g, s, font: font, x: 512 - w / 2, y: r.maxY + 46, color: NSColor.white.withAlphaComponent(0.72))
        }
        HPAX.note(g, Self.hitArea, .slider(Double((cx - r.minX) / r.width)), L("home.cam.timeline", "近况"),
                  value: selected[id].map { Self.timeText(list[min($0, list.count - 1)].at) } ?? L("home.cam.live", "实时"))
    }
}

enum CameraTimelineSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(CameraTimeline.segments([0, 30, 60, 500, 530, 2000]) == [0...2, 3...4, 5...5] && CameraTimeline.segments([]).isEmpty
              && CameraTimeline.segments([7]) == [0...0], "攝影機近況：隔 90 秒以上才分段")   // l10n-ignore
        let r = CGRect(x: 100, y: 0, width: 200, height: 10)
        check(CameraTimeline.xPosition(0, oldest: 0, now: 100, in: r) == 100 && CameraTimeline.xPosition(100, oldest: 0, now: 100, in: r) == 300
              && CameraTimeline.xPosition(50, oldest: 0, now: 100, in: r) == 200 && CameraTimeline.xPosition(5, oldest: 5, now: 5, in: r) == 300,
              "攝影機近況：時間對到軸上的位置")   // l10n-ignore
        check(CameraTimeline.pick(105, times: [0, 50], now: 100, in: r) == 0 && CameraTimeline.pick(195, times: [0, 50], now: 100, in: r) == 1
              && CameraTimeline.pick(299, times: [0, 50], now: 100, in: r) == nil, "攝影機近況：點軸挑最近一格、最右邊回到即時")   // l10n-ignore
        let img = makeImage(4, 4) { _ in }
        let pending = [CameraTimeline.Frame(at: 1, image: img, person: nil)]
        let none = [CameraTimeline.Frame(at: 1, image: img, person: false)]
        let seen = none + [CameraTimeline.Frame(at: 2, image: img, person: true), CameraTimeline.Frame(at: 3, image: img, person: false)]
        check(CameraTimeline.feedback(pending, timeText: { _ in "x" }) == nil && CameraTimeline.feedback(none, timeText: { _ in "x" }) != nil
              && CameraTimeline.feedback(seen, timeText: { "T\(Int($0))" })?.contains("T2") == true, "攝影機近況：回饋說最近一次有人的時刻")   // l10n-ignore
    }
}
