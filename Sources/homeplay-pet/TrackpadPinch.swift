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
    private var lastCount = 0
    private var startDistance: Float = 0
    private var lastDistance: Float = 0
    private var confirmed = false
    private var appliedFrames = 0
    private var lastApplyAt: Double = 0

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
    fileprivate func handle(count: Int, positions: [(Float, Float)]) {
        guard count == 2, positions.count == 2 else {
            lastCount = count; startDistance = 0; lastDistance = 0; confirmed = false; return
        }
        let dx = Double(positions[0].0 - positions[1].0)
        let dy = Double(positions[0].1 - positions[1].1)
        let d = Float((dx * dx + dy * dy).squareRoot())
        guard d > 0.001 else { return }
        if startDistance == 0 {
            startDistance = d; lastDistance = d; appliedFrames = 0; lastCount = 2; confirmed = false
            appendDiag("gesture.log", "MT fingers=2 start d=\(d)")
            return
        }
        lastCount = 2
        if !confirmed {
            // 先确认「这是一次有意的捏合」，再从确认点开始跟手；滚动时手指距离基本不变，不会触发。
            guard abs(d / startDistance - 1) >= 0.025 else { lastDistance = d; return }
            confirmed = true
            lastDistance = d
            return
        }
        var factor = CGFloat(d / lastDistance)
        guard factor.isFinite, factor > 0 else { return }
        factor = min(1.08, max(0.92, factor))
        if abs(factor - 1) > 0.0015 {
            let now = CACurrentMediaTime()
            guard now - lastApplyAt >= 1.0 / 90 else { lastDistance = d; return }
            lastApplyAt = now
            appliedFrames += 1
            if appliedFrames <= 3 || appliedFrames % 12 == 0 {
                appendDiag("gesture.log", "MT pinch factor=\(factor) d=\(d) start=\(startDistance)")
            }
            onMagnify?(factor)
        }
        lastDistance = d
    }
}

private func mtPinchCallback(device: Int32, data: UnsafeMutableRawPointer?, nFingers: Int32,
                             timestamp: Double, frame: Int32) -> Int32 {
    let count = Int(nFingers)
    guard count == 2, let data else {
        DispatchQueue.main.async { TrackpadPinch.shared.handle(count: count, positions: []) }
        return 0
    }
    // 回调线程只取两个坐标；窗口尺寸与 AppKit 状态都回主线程处理。
    let c = data.assumingMemoryBound(to: MTContact.self)
    let p0 = c[0].normalized.position
    let p1 = c[1].normalized.position
    DispatchQueue.main.async {
        TrackpadPinch.shared.handle(count: 2, positions: [(p0.x, p0.y), (p1.x, p1.y)])
    }
    return 0
}
