import AppKit
import ApplicationServices
import AVFoundation
import Metal
import RealityKit
import Combine
import simd
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO
import IOKit.ps
import IOKit.hid
import Carbon.HIToolbox
import Network
import EventKit
import ServiceManagement
import Security

enum SystemKeyTap {
    /// 听写键（F5 印麦克风的那颗）。若与某块键盘不符，用 HOMEPLAY_DIAG_KEYS=1 看 syskeys.log 改这里。
    static let siriKeyCode: Int64 = 176
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS：媒体/听写这类辅助键在 NX_SYSDEFINED 里的 subtype
    static let auxSubtype: Int16 = 8
    /// NX_SYSDEFINED：CGEventType 没公开这个枚举值，只在这里用裸数字
    static let sysDefinedType: UInt32 = 14
    /// NSEvent 的 subtype／data1 在 CGEvent 里的未公开字段。事件 tap 跑在自己的执行绪，
    /// 不能在那边构造 NSEvent（AppKit 会要求主执行绪；Caps Lock 一按就 SIGTRAP）。
    static let subtypeField = CGEventField(rawValue: 0x53)!
    static let data1Field = CGEventField(rawValue: 0x95)!

    /// 只給「換了鍵盤、要知道它發哪個鍵碼」的除錯用；平常不記錄系統按鍵。
    static let logAllAuxKeys = ProcessInfo.processInfo.environment["HOMEPLAY_DIAG_KEYS"] != nil

    /// tap 掛在專用執行緒的 run loop 上，不佔主執行緒：主執行緒一忙（畫臉、重建環境光），
    /// 掛在主 loop 的 tap 就把全系統鍵盤一起拖慢，還會被系統當成超時停掉。
    private static let lock = NSLock()
    private static var tap: CFMachPort?
    private static var runLoop: CFRunLoop?
    private static var started = false
    private static var siriHandler: ((Bool) -> Void)?
    private static let retryLimit = 12          // 5 秒一次，約一分鐘

    /// down：true＝按下、false＝放開（按住說話）
    static func setSiriHandler(_ h: @escaping (Bool) -> Void) {
        lock.lock(); siriHandler = h; lock.unlock()
    }

    private static func fireSiri(down: Bool) {
        lock.lock(); let h = siriHandler; lock.unlock()
        DispatchQueue.main.async { h?(down) }
    }

    /// 可重复调用：已经装好就直接返回；还没好的话由后台线程继续重试
    /// （输入监控授权往往是在 App 启动之后才给的，只试一次会一直没反应）。
    /// F5 现在真的被我们接住了（tap 装好了）
    static var isActive: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }
    private static var threadAlive = false
    /// 用户刚在「输入监控」里勾上 HomePlay：如果之前的重试已经放弃，重新装一次
    static func retryAfterGrant() {
        lock.lock()
        let again = tap == nil && !threadAlive
        if again { started = false }
        lock.unlock()
        if again { _ = install() }
    }

    static func install() -> Bool {
        lock.lock()
        if started { let ok = tap != nil; lock.unlock(); return ok }
        started = true
        lock.unlock()
        return startThread()
    }

    private static func makePort() -> (CFMachPort, CFRunLoopSource)? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << sysDefinedType)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return nil }
        return (port, source)
    }

    /// 起专用线程并把 tap 挂上去。返回时能确定「这一秒内装好了没有」。
    private static func startThread() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var created = false
        let t = Thread {
            lock.lock(); threadAlive = true; lock.unlock()
            defer { lock.lock(); threadAlive = false; lock.unlock() }
            var signalled = false
            for attempt in 1...retryLimit {
                guard let (port, source) = makePort() else {
                    if !signalled { signalled = true; ready.signal() }
                    if attempt == retryLimit { break }
                    Thread.sleep(forTimeInterval: 5)
                    continue
                }
                created = true
                if !signalled { signalled = true; ready.signal() }
                lock.lock(); tap = port; runLoop = CFRunLoopGetCurrent(); lock.unlock()
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
                appendDiag("syskeys.log", "tap installed on own thread (attempt \(attempt))")
                CFRunLoopRun()
                return
            }
            appendDiag("syskeys.log", "tap create failed after \(retryLimit) attempts (need Input Monitoring)")
        }
        t.name = "homeplay.keytap"
        t.qualityOfService = .userInteractive
        t.start()
        _ = ready.wait(timeout: .now() + 0.5)
        return created
    }

    /// 端口失效（系统回收了 tap）时，把旧 loop 收掉再重新装一颗。
    private static func reinstall() {
        lock.lock()
        let oldLoop = runLoop
        tap = nil; runLoop = nil; started = false
        lock.unlock()
        if let oldLoop { CFRunLoopStop(oldLoop) }
        _ = install()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = tap; lock.unlock()
            if let port, CFMachPortIsValid(port) {
                CGEvent.tapEnable(tap: port, enable: true)
                appendDiag("syskeys.log", "tap re-enabled after \(type.rawValue)")
            } else {
                appendDiag("syskeys.log", "tap invalid (\(type.rawValue)); reinstalling")
                DispatchQueue.main.async { reinstall() }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == SystemKeyTap.siriKeyCode {
                if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    fireSiri(down: true)
                } else if type == .keyUp {
                    fireSiri(down: false)
                }
                return nil   // 吞掉按下/抬起：Mac 听写别和手机 Siri 抢这颗键
            }
            return Unmanaged.passUnretained(event)
        }
        if type.rawValue == SystemKeyTap.sysDefinedType {
            let subtype = event.getIntegerValueField(SystemKeyTap.subtypeField)
            guard subtype == Int64(SystemKeyTap.auxSubtype) else { return Unmanaged.passUnretained(event) }
            let data1 = event.getIntegerValueField(SystemKeyTap.data1Field)
            let key = (data1 & 0xFFFF0000) >> 16
            let state = (data1 & 0xFF00) >> 8
            // 換鍵盤後要確認它發哪個鍵碼時才開 HOMEPLAY_DIAG_KEYS=1；平時不落地按鍵。
            if SystemKeyTap.logAllAuxKeys { appendDiag("syskeys.log", "aux key=\(key) state=\(state)") }
            if key == SystemKeyTap.siriKeyCode {
                if state == 0x0A, data1 & 0x1 == 0 { fireSiri(down: true) }   // 低位＝自動重複
                else if state == 0x0B { fireSiri(down: false) }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
