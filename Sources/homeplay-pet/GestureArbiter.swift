// 手势仲裁：每个手势在开始时决定一次「归谁」，整个手势（含惯性）都锁定，不再逐事件改判。
//
// 规则（2026-10-22 Aaron 定案）：
// - 双指滑动＝转身体，只在机身上起手才生效；直播时屏幕里归 CarPlay（拖动）；透明边什么都不做。
// - 捏合缩放、三指拖移在整个桌宠都生效。
// - 捏合与双指滑动互斥：一方确认后，另一方在本手势内不启动。
//
// 纯逻辑，不碰 AppKit／RealityKit：时间与命中结果由调用方传进来，selftest 直接驱动。
import Foundation

enum GestureTarget: String, Equatable {
    case none      // 透明区：不转、不拖
    case carplay   // 直播屏幕：在 CarPlay 里拖
    case rotate    // 机身：转身体
}

/// 双指滑动（scrollWheel）的仲裁。
struct ScrollArbiter {
    /// 无 phase 的设备（Magic Mouse 等）两次事件间隔超过这个值就算新手势
    static let gestureGap: Double = 0.25
    /// 惯性结束后最多再等这么久没事件，就清掉锁定
    static let momentumGrace: Double = 0.3
    /// 累计滑动超过这个点数才算「确实在滑」，之后捏合不再确认
    static let commitPoints: Double = 12

    private(set) var target: GestureTarget?
    private(set) var startedAt: Double = 0
    private(set) var sawMomentum = false
    private var lastEventAt: Double = -1
    private var travel: Double = 0

    /// 本手势已经确定是滑动（不是捏合起手的小抖动）
    var committed: Bool { target != nil && target != GestureTarget.none && travel >= Self.commitPoints }

    /// - began: phase == .began；momentum: momentumPhase 非空；ended: 手指抬起（phase ended/cancelled）；
    ///   momentumEnded: momentumPhase == .ended。
    /// - pinching: 捏合已确认（本手势归捏合，滑动全部忽略）。
    /// - classify: 只在需要重新判定时才调用（命中测试有成本）。
    mutating func route(now: Double, began: Bool, momentum: Bool, ended: Bool, momentumEnded: Bool,
                        dx: Double, dy: Double, pinching: Bool,
                        classify: () -> GestureTarget) -> GestureTarget {
        defer { lastEventAt = now }
        if pinching { target = GestureTarget.none; return .none }
        let stale = lastEventAt < 0 || now - lastEventAt > (momentum ? Self.momentumGrace : Self.gestureGap)
        if began || (!momentum && (target == nil || stale)) {
            target = classify()
            startedAt = now
            travel = 0
            sawMomentum = false
        } else if momentum && (target == nil || stale) {
            // 惯性不能自己开启一个手势（手指早就离开了，起点已不可知）
            return .none
        }
        if momentum { sawMomentum = true }
        travel += abs(dx) + abs(dy)
        let t = target ?? .none
        if momentumEnded { target = nil }
        _ = ended
        return t
    }

    mutating func reset() { target = nil; lastEventAt = -1; travel = 0; sawMomentum = false }
}

/// 两指手势的类型：手指一碰到触控板就看两指各自往哪走，判定后锁到手指离开。
/// 以前用「指距累计变化 ≥2.5%」才确认捏合：确认之前滚动事件已经在转身体，慢慢捏又常常确认不了
///（2026-10-22 gesture.log：六次双指接触既没被认成捏合也没被认成滑动）。
enum TwoFingerKind: String, Equatable {
    case undecided   // 还没走够判定距离：两边都先不动（约 20–40 ms）
    case pinch       // 两指沿连线相向／相背：缩放
    case scroll      // 两指同向平移：转身体／CarPlay 拖
    case twist       // 两指反向但不沿连线（扭转）：两边都不做
}

struct TwoFingerClassifier {
    /// 任一指离起点超过这么多（触控板归一化坐标，约 1.5 mm）才判定
    static let decideDistance: Double = 0.012
    /// 指距变化至少是共同平移的这么多倍才算捏合
    static let pinchRatio: Double = 1.2

    private(set) var kind: TwoFingerKind = .undecided
    private var ids: (Int32, Int32)?
    private var start0 = (x: 0.0, y: 0.0), start1 = (x: 0.0, y: 0.0)

    mutating func reset() { kind = .undecided; ids = nil }

    /// 每帧喂两指（按手指 id 配对，接触数组里的顺序会变）。返回当前判定。
    mutating func feed(id0: Int32, x0: Double, y0: Double, id1: Int32, x1: Double, y1: Double) -> TwoFingerKind {
        // 统一成 id 小的在前，避免两指在数组里换位导致位移算反
        var a = (id: id0, x: x0, y: y0), b = (id: id1, x: x1, y: y1)
        if a.id > b.id { swap(&a, &b) }
        if ids == nil || ids! != (a.id, b.id) {
            ids = (a.id, b.id); start0 = (a.x, a.y); start1 = (b.x, b.y); kind = .undecided
            return kind
        }
        guard kind == .undecided else { return kind }
        let v0 = (x: a.x - start0.x, y: a.y - start0.y)
        let v1 = (x: b.x - start1.x, y: b.y - start1.y)
        let m0 = (v0.x * v0.x + v0.y * v0.y).squareRoot(), m1 = (v1.x * v1.x + v1.y * v1.y).squareRoot()
        guard max(m0, m1) >= Self.decideDistance else { return kind }
        // 起点连线方向；指距变化＝两指位移差在连线上的投影；共同平移＝两指位移的平均
        var ax = start1.x - start0.x, ay = start1.y - start0.y
        let al = (ax * ax + ay * ay).squareRoot()
        guard al > 0.0001 else { kind = .scroll; return kind }
        ax /= al; ay /= al
        let separation = abs((v1.x - v0.x) * ax + (v1.y - v0.y) * ay)
        let common = (((v0.x + v1.x) / 2) * ((v0.x + v1.x) / 2) + ((v0.y + v1.y) / 2) * ((v0.y + v1.y) / 2)).squareRoot()
        let sameDirection = v0.x * v1.x + v0.y * v1.y > 0
        // 捏合要指距真的变了（扭转时指距和平移都接近 0，不能算捏合）
        if separation >= max(Self.pinchRatio * common, Self.decideDistance * 0.6) { kind = .pinch }
        else if sameDirection || min(m0, m1) < Self.decideDistance * 0.35 { kind = .scroll }   // 一指几乎不动＋另一指横走：也算滑
        else { kind = .twist }
        return kind
    }
}

/// 一行手势日志（gesture.log）：起点归属、锁定目标、有没有惯性、持续多久。
func gestureLogLine(_ kind: String, target: GestureTarget, momentum: Bool, duration: Double) -> String {
    String(format: "gesture %@ target=%@ momentum=%@ dur=%.2fs", kind, target.rawValue, momentum ? "yes" : "no", duration)
}
