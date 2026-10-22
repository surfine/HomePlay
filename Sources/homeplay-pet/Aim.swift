// 机身朝向（aim）：整台 HomeView 在底座上转向使用者——像 DockKit 云台转整支手机、像 iMac G4
// 「Window Shopping」广告里跟着路人转头的那台。真机铰链只能前后仰，所以左右转的是整机，不是屏幕。
//
// 两层目标（2026-10-22 Aaron 定案：跟随优先、窗口位置当基准）：
// 1. 基准：窗口在显示器右边 → 朝左（朝屏幕中央的人），左边反之；
// 2. 跟随（摄像头看到人）：转向人。摄像头在显示器顶部中央、桌宠在侧边，人相对桌宠的角度要扣掉视差：
//    tan(对桌宠) = tan(对摄像头) + tan(基准)。没看到人就是基准本身。
// 「正面固定」：两层都不要，永远 0。
//
// 纯逻辑：时间、窗口几何、人脸位置都由调用方给；selftest 直接驱动。
import Foundation

enum ViewMode: String, CaseIterable {
    case auto    // 窗口位置倾斜＋跟随
    case front   // 正面固定，不倾斜
    static let key = "HomePlayViewMode"
    /// 快照／基准用：只在这次执行生效，不写偏好
    nonisolated(unsafe) static var override: ViewMode?
    static var saved: ViewMode {
        get { override ?? ViewMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

struct Aim {
    static let deg = Double.pi / 180
    /// 跟随最大转角（设置里可调 10–25°，默认 25°）
    static let followDegreesKey = "HomePlayFollowDegrees"
    static var savedFollowDegrees: Double {
        get {
            let v = UserDefaults.standard.object(forKey: followDegreesKey) as? Double ?? 25
            return min(25, max(10, v.isFinite ? v : 25))
        }
        set { UserDefaults.standard.set(min(25, max(10, newValue)), forKey: followDegreesKey) }
    }
    /// 显示器半宽 ÷ 观看距离：14″ 屏半宽约 15 cm、坐在 60 cm 外 → 0.25；取 0.33 让贴边时转得明显（≈18°）
    static let parallax = 0.33
    /// Mac 内建镜头水平视角约 65°
    static let cameraHFOV = 65 * deg
    /// 目标变化小于这个就不跟（取景稳定，人在原地小动不抖）
    static let deadZone = 3 * deg
    /// 最大角速度（DockKit 跟拍的观感：快走也平顺，不甩）
    static let maxSpeed = 70 * deg
    /// 跟人：响应 0.5 s；回到基准（人走开、窗口挪动）：1.2 s，慢慢回
    static let followResponse = 0.5
    static let returnResponse = 1.2
    /// 人离开视野后维持多久才回基准
    static let holdAfterLoss = 2.0
    /// 用人脸 x 的速度往前预判多少秒
    static let lead = 0.12

    /// 窗口位置决定的基准角（弧度）：窗口中心相对显示器可见区中心的偏移（-1…1），朝中央转。
    static func baseline(windowMidX: Double, screenMidX: Double, screenHalfWidth: Double) -> Double {
        guard screenHalfWidth > 0 else { return 0 }
        let off = min(1, max(-1, (windowMidX - screenMidX) / screenHalfWidth))
        return atan(-off * parallax)
    }

    /// 看到人时的目标角：gazeX 是 -1…1（镜像后，正＝人在右边），扣掉桌宠相对摄像头的视差。
    static func followTarget(gazeX: Double, baseline: Double, maxDegrees: Double) -> Double {
        let toCamera = atan(gazeX * tan(cameraHFOV / 2))
        let toPet = atan(tan(toCamera) + tan(baseline))
        let limit = maxDegrees * deg
        return min(limit, max(-limit, toPet))
    }

    // MARK: 运动状态

    private(set) var angle: Double = 0
    private(set) var velocity: Double = 0
    private(set) var heldTarget: Double = 0
    private var lastSeen: Double = -.infinity
    private var lastGazeX: Double = 0
    private var lastGazeAt: Double = -.infinity
    private var gazeVelocity: Double = 0

    /// 每帧调用。present/gazeX：摄像头这一帧有没有人、人在哪；following：跟随开关且允许跑（不直播、没锁屏…）。
    /// 返回当前机身朝向（弧度）。
    mutating func step(now: Double, dt: Double, mode: ViewMode, following: Bool, present: Bool, gazeX: Double,
                       baseline: Double, maxDegrees: Double) -> Double {
        let dt = min(0.05, max(0, dt))
        var target: Double
        var response = Self.returnResponse
        switch mode {
        case .front:
            target = 0
        case .auto:
            target = baseline
            if following, present {
                if lastGazeAt.isFinite, now > lastGazeAt {
                    let v = (gazeX - lastGazeX) / (now - lastGazeAt)
                    gazeVelocity += (v - gazeVelocity) * 0.3        // 速度也平滑一下，别被单帧噪声带着跑
                }
                lastGazeX = gazeX; lastGazeAt = now; lastSeen = now
                let ahead = min(1, max(-1, gazeX + gazeVelocity * Self.lead))
                target = Self.followTarget(gazeX: ahead, baseline: baseline, maxDegrees: maxDegrees)
                response = Self.followResponse
            } else if following, now - lastSeen < Self.holdAfterLoss {
                target = heldTarget                                  // 刚走开：先停在最后看到的方向
                response = Self.followResponse
                gazeVelocity = 0
            } else {
                gazeVelocity = 0
            }
        }
        // 死区：只对「跟人」的目标做（窗口拖动、模式切换要立刻响应）
        if response == Self.followResponse, abs(target - heldTarget) < Self.deadZone { target = heldTarget }
        heldTarget = target
        // 临界阻尼弹簧＋限速：起步、落定都缓，快走也不甩
        let w = 2 * Double.pi / response
        let accel = (target - angle) * w * w - velocity * 2 * w
        velocity += accel * dt
        velocity = min(Self.maxSpeed, max(-Self.maxSpeed, velocity))
        angle += velocity * dt
        if abs(target - angle) < 0.0005, abs(velocity) < 0.001 { angle = target; velocity = 0 }
        return angle
    }

    var settled: Bool { abs(heldTarget - angle) < 0.0005 && abs(velocity) < 0.001 }
}
