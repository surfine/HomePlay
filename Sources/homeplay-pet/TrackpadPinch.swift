// 全局双指捏合：用私有 MultitouchSupport 直接读触控板接触帧。
//
// 为什么不用 NSEvent.magnify：手势事件只投递给「已激活」的 App。桌宠是
// .nonactivatingPanel（点一下也不会激活 App），所以 magnify 永远不到，
// gesture.log 里一条 local magnify 都没有（真机 2026-10-20 确认）。
// 这里只观察接触帧，不吞任何系统手势；按指针是否在桌宠上来决定缩不缩放。
//
// 失败时静默返回 0：⌥＋双指滚动仍然可用，不影响主流程。
import AppKit
import CoreFoundation

private struct MTPoint { var x: Float; var y: Float }
private struct MTVector { var position: MTPoint; var velocity: MTPoint }
private struct MTContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var zero2: Int32
    var zero3: Int32
    var density: Float
}

private typealias MTContactCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterCallback = @convention(c) (UnsafeMutableRawPointer, MTContactCallback?) -> Void
private typealias MTDeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias MTDeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Void

final class TrackpadPinch {
    static let shared = TrackpadPinch()

    /// 主线程回调；factor 是相对上一帧的倍率（1.02＝这一帧放大 2%）。
    var onMagnify: ((CGFloat) -> Void)?
    /// 最近一次真正应用缩放的时间（main 线程读写），用来避免和本地 magnify 双倍缩放。
    private(set) var lastPinchAt: Double = 0
    func markApplied() { lastPinchAt = CACurrentMediaTime() }

    private var devices: [UnsafeMutableRawPointer] = []
    private var handleRef: UnsafeMutableRawPointer?
    private var startFn: MTDeviceStart?
    private var stopFn: MTDeviceStop?
    private var lastDistance: Float = 0
    private var appliedFrames = 0
    private var lastApplyAt: Double = 0
    /// 当前两指手势的类型（触控线程判定、任意线程可读）：捏合只缩放；滑动只转身体／拖 CarPlay；
    /// 还没判定或扭转时两边都不动。手指离开后回到 undecided。
    var twoFingerKind: TwoFingerKind {
        pinchCallbackLock.lock(); defer { pinchCallbackLock.unlock() }
        return pinchFingers == 2 ? classifier.kind : .undecided
    }
    /// 本次两指接触是捏合（滑动、两指旋转都让位）
    var pinching: Bool { twoFingerKind == .pinch }
    /// 滚轮事件该不该先压着：触控板上正好两指、但类型还没定（或是捏合／扭转）
    var holdScroll: Bool {
        pinchCallbackLock.lock(); defer { pinchCallbackLock.unlock() }
        return pinchFingers == 2 && classifier.kind != .scroll
    }
    /// 是否拿到了触控板接触帧（私有框架不可用时为 false，三指判断要退回旧行为）。
    var available: Bool { !devices.isEmpty }
    /// 当前触控板上的手指数（任意线程可读）。
    var fingerCount: Int {
        pinchCallbackLock.lock(); defer { pinchCallbackLock.unlock() }
        return max(0, pinchFingers)
    }

    private init() {}

    /// 返回找到的触控板数量；0＝框架/符号不可用。
    func start() -> Int {
        guard devices.isEmpty else { return devices.count }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let h = dlopen(path, RTLD_NOW) else { return 0 }
        guard let createSym = dlsym(h, "MTDeviceCreateList"),
              let registerSym = dlsym(h, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(h, "MTDeviceStart") else { return 0 }
        let create = unsafeBitCast(createSym, to: MTDeviceCreateList.self)
        let register = unsafeBitCast(registerSym, to: MTRegisterCallback.self)
        startFn = unsafeBitCast(startSym, to: MTDeviceStart.self)
        if let stopSym = dlsym(h, "MTDeviceStop") { stopFn = unsafeBitCast(stopSym, to: MTDeviceStop.self) }
        guard let list = create()?.takeRetainedValue() else { return 0 }
        for i in 0..<CFArrayGetCount(list) {
            guard let value = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: value)
            register(device, mtPinchCallback)
            startFn?(device, 0)
            devices.append(device)
        }
        handleRef = h
        return devices.count
    }

    deinit {
        for d in devices { stopFn?(d) }
    }

    /// 两指距离相对手势起始变化超过 2.5% 才确认是捏合；纯双指滚动的轻微漂移不会误缩放。
    /// 手指离开时只把状态清掉。
    fileprivate func resetGesture() {
        lastDistance = 0
    }

    /// 两指接触帧（主线程）。类型已在触控线程判好：只有捏合才缩放。
    fileprivate func handle(p0: MTPoint, p1: MTPoint, kind: TwoFingerKind, decidedNow: Bool) {
        let dx = Double(p0.x - p1.x)
        let dy = Double(p0.y - p1.y)
        let d = Float((dx * dx + dy * dy).squareRoot())
        guard d > 0.001 else { return }
        if decidedNow { appendDiag("gesture.log", "MT two-finger = \(kind.rawValue) d=\(d)") }
        guard kind == .pinch else { lastDistance = d; return }
        if lastDistance == 0 || decidedNow { lastDistance = d; appliedFrames = 0; return }
        var factor = CGFloat(d / lastDistance)
        guard factor.isFinite, factor > 0 else { return }
        factor = min(1.08, max(0.92, factor))
        if abs(factor - 1) > 0.0015 {
            let now = CACurrentMediaTime()
            guard now - lastApplyAt >= 1.0 / 90 else { lastDistance = d; return }
            lastApplyAt = now
            appliedFrames += 1
            if appliedFrames <= 3 || appliedFrames % 12 == 0 {
                appendDiag("gesture.log", "MT pinch factor=\(factor) d=\(d)")
            }
            onMagnify?(factor)
        }
        lastDistance = d
    }
}

/// 触摸帧回调在 MultitouchSupport 自己的线程上跑。手指离开时每帧都会回调（90–125 Hz），
/// 全都派到主线程纯属浪费：只在手指数真的变化时通知一次。
private let pinchCallbackLock = NSLock()
private var pinchFingers = -1
private var classifier = TwoFingerClassifier()   // pinchCallbackLock 保护

private func mtPinchCallback(device: Int32, data: UnsafeMutableRawPointer?, nFingers: Int32,
                             timestamp: Double, frame: Int32) -> Int32 {
    let count = Int(nFingers)
    if count != 2 || data == nil {
        pinchCallbackLock.lock()
        let changed = pinchFingers != count
        pinchFingers = count
        pinchCallbackLock.unlock()
        if changed { DispatchQueue.main.async { TrackpadPinch.shared.resetGesture() } }
        return 0
    }
    // 判定在触控线程上做：滚轮事件到主线程时，这一手势是捏合还是滑动已经定了。
    let c = data!.assumingMemoryBound(to: MTContact.self)
    let a = c[0], b = c[1]
    pinchCallbackLock.lock()
    if pinchFingers != 2 { classifier.reset() }
    pinchFingers = 2
    let before = classifier.kind
    let kind = classifier.feed(id0: a.identifier, x0: Double(a.normalized.position.x), y0: Double(a.normalized.position.y),
                               id1: b.identifier, x1: Double(b.normalized.position.x), y1: Double(b.normalized.position.y))
    pinchCallbackLock.unlock()
    let decidedNow = before == .undecided && kind != .undecided
    // 只有捏合需要每帧回主线程（缩放）；其余只在判定那一刻通知一次（写日志）
    guard kind == .pinch || decidedNow else { return 0 }
    let p0 = a.normalized.position, p1 = b.normalized.position
    DispatchQueue.main.async { TrackpadPinch.shared.handle(p0: p0, p1: p1, kind: kind, decidedNow: decidedNow) }
    return 0
}
