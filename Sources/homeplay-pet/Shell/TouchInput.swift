// 觸控 Mac 與觸控 Sidecar（macOS 27；事實與拍板見 docs/plans/touch.md）。
//
// AppKit 只把「單指點／拖」模擬成滑鼠；多指與個別觸控（NSTouch）只給手勢辨識器。PetView 掛四個只收觸控的辨識器
// （buttonMask＝0、allowedTouchTypes＝.direct：滑鼠與觸控板一律不經過它們，照舊走原本的路）：
// - TouchTracker（自訂）：單指從碰到到放開的整段。先等一下看是不是兩指（70 ms 或移動超過 6 pt），確定是單指才把它當成
//   「按下」送進 PetView 原本的滑鼠入口——點、拖、長按、編輯模式拖圖示、控制中心、CarPlay 都走同一套（官方建議的
//   「同一組階段函式，滑鼠與觸控各自呼叫」）。
// - NSPressGestureRecognizer：機身上按住＝右鍵選單（HIG：右鍵選單＝按住）。螢幕上的按住照外殼自己的長按。
// - NSMagnificationGestureRecognizer：兩指捏合＝縮放桌寵（跟觸控板捏合同一個語意）。
// - NSPanGestureRecognizer（正好兩指）：機身上兩指拖＝轉身體（跟觸控板兩指滑同一個語意）。
// - NSRotationGestureRecognizer：兩指旋轉＝原地轉身（2026-11-07 拍板，跟觸控板兩指旋轉同一個語意；放手帶慣性停）。
// 捏合與兩指拖在同一個 view 裡互斥（誰先認出來歸誰），view 設 exclusiveGestureBehavior＝.exclusive；
// 捏合與旋轉讓兩個辨識器同時跑，由 TouchInput.twoLock（TwoFingerLock）判：先超過門檻的勝，到手指離開都只認它。
//
// 觸控跟滑鼠不同的只有這幾處（處理碼對所有輸入一樣，依互動類型決定呈現；螢幕上的拖歸外殼三種輸入都一樣）：
// 點按判定區外擴到 44 pt（太小太密的碰了先展開）、
// 👀 看手指、返回滑動先看系統設定（NSEvent.isTouchSwipeNavigationEnabled）。
// 系統對同一下觸控另外模擬出來的滑鼠／滾輪／捏合事件（手指還在、或剛放開 0.35 秒內）一律丟掉，同一下不會觸發兩次。

import AppKit

// MARK: - 純邏輯（--selftest 直接驗）

enum TouchRegion: Equatable { case screen, body, none }

enum TouchRoute {
    enum Owner: Equatable { case shell, carPlay, rotate, none }
    /// 單指從哪裡起手就歸誰（拍板 4）：螢幕＝外殼（直播時＝CarPlay）、機身＝轉身體
    static func singleFinger(_ r: TouchRegion, live: Bool) -> Owner {
        switch r {
        case .screen: return live ? .carPlay : .shell
        case .body: return .rotate
        case .none: return .none
        }
    }
    /// 捏合：整個桌寵都收（同觸控板），只有 CarPlay 直播的螢幕上不收（那裡的兩指只給實驗旗標）
    static func pinchAccepts(_ r: TouchRegion, live: Bool) -> Bool { !(r == .screen && live) }
    /// 兩指旋轉＝轉身：跟捏合一樣整個桌寵都收，CarPlay 直播的螢幕上不收
    static func rotationAccepts(_ r: TouchRegion, live: Bool) -> Bool { pinchAccepts(r, live: live) }
    /// 兩指拖＝轉身體：只在機身起手（同觸控板：螢幕上的兩指滑不轉）
    static func twoFingerPanAccepts(_ r: TouchRegion) -> Bool { r == .body }
    /// 按住＝右鍵選單：只在機身；螢幕上的按住是外殼的長按（圖示選單、錶面總覽、App 長按）
    static func pressMenuAccepts(_ r: TouchRegion) -> Bool { r == .body }
    /// 返回滑動（左緣右滑／內容左側右滑）：觸控來的要看系統設定；滑鼠、觸控板照舊
    static func backSwipeAllowed(touch: Bool, navigationEnabled: Bool) -> Bool { !touch || navigationEnabled }
}

/// 一下觸控的仲裁：同時只有一個手勢生效
struct TouchArbiter: Equatable {
    enum Phase: Equatable { case idle, pending, tracking(moved: Bool), ignored }
    var phase: Phase = .idle
    static let commitDelay = 0.07          // 等第二根手指的時間
    static let commitMove: CGFloat = 6     // 移動超過就不等了（點）

    /// 單指可以當成「按下」送出去了
    static func shouldCommit(elapsed: Double, moved: CGFloat) -> Bool { elapsed >= commitDelay || moved > commitMove }
    /// 兩指手勢（捏合、兩指拖）可不可以開始：單指已經在拖（換頁、捲動、轉身體）就不行
    var twoFingerMayBegin: Bool { if case .tracking(true) = phase { return false }; return phase != .ignored }
    /// 兩指手勢開始：單指那一下作廢。回 true＝已經送出過「按下」，要收拾
    mutating func twoFingerBegan() -> Bool {
        let sent: Bool
        if case .tracking = phase { sent = true } else { sent = false }
        phase = .ignored
        return sent
    }
    /// 手指按著卻這麼久沒有任何觸控更新：多半是結束事件被別人吃掉了（機身按住叫出的選單在追蹤時手指抬起），不再當它按著
    static let staleTouch = 5.0
    /// 系統另外模擬的事件要不要丟：自己造的不丟；手指還在（而且最近還有觸控更新）、或剛放開 0.35 秒內丟
    static func dropsSystemEvent(synthesizing: Bool, fingerDown: Bool, sinceLift: Double, sinceTouch: Double = 0) -> Bool {
        !synthesizing && ((fingerDown && sinceTouch < staleTouch) || sinceLift < 0.35)
    }
}

/// 系統把觸控的拖另外模擬成的捲動：手指按著時開始的那一段，一路丟到它的慣性結束（甩動之後的慣性常常拖過 0.35 秒）。
/// 新的一段（觸控板重新起手 began、或沒有 phase 的滾輪）就不再丟；萬一一直等不到慣性結束，停 1 秒沒事件也放掉
struct TouchScrollSwallow: Equatable {
    private(set) var active = false
    private var lastAt = -10.0
    static let idleRelease = 1.0
    /// systemDrop：這一下照手指狀態本來就要丟；began：phase 是 began／mayBegin；phased：phase 或 momentumPhase 不是空的；
    /// momentumEnd：momentumPhase 是 ended／cancelled
    mutating func drops(now: Double, synthesizing: Bool, systemDrop: Bool, began: Bool, phased: Bool, momentumEnd: Bool) -> Bool {
        if synthesizing { return false }
        if systemDrop {
            active = phased && !momentumEnd; lastAt = now
            return true
        }
        guard active else { return false }
        if began || !phased || now - lastAt > Self.idleRelease { active = false; return false }   // 新的一段手勢：照常
        lastAt = now
        if momentumEnd { active = false }
        return true
    }
}

/// 機身上「戳一下」（pressTarget 那一下縮以外的：數戳了幾次、戳多了搖頭）：滑鼠照舊按下就算；
/// 觸控等放手確認是點按才算——第二根手指晚於 70 ms 才到的捏合，不會先戳一下
enum BodyPoke {
    static func atDown(touch: Bool) -> Bool { !touch }
    static func atRelease(pending: Bool, rotating: Bool, travel: CGFloat) -> Bool { pending && rotating && travel < 10 }
}

/// 點按判定區外擴（拍板 1，照 Apple：控制項大小不變、放大點按區）
enum TouchHit {
    static let minPoints: CGFloat = 44
    /// 44 pt 換成畫布 px（螢幕在視窗裡目前的寬，點）
    static func minSide(screenWidthPoints w: CGFloat) -> CGFloat { w > 1 ? minPoints * 1024 / w : minPoints }
    /// 外擴到至少 m × m（中心不動；本來就夠大的不變）
    static func expanded(_ r: CGRect, min m: CGFloat) -> CGRect {
        r.insetBy(dx: -max(0, (m - r.width) / 2), dy: -max(0, (m - r.height) / 2))
    }
    /// 正規化距離：點在框裡 ≤ 1；同樣大小的兩個框比的就是「離中心多近」
    static func depth(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        max(abs(p.x - r.midX) / max(1, r.width / 2), abs(p.y - r.midY) / max(1, r.height / 2))
    }
    /// 落點歸誰：真的點在框裡的先算（好幾個疊著＝最小的那個，例如大卡裡的播放鈕）；都沒有才看外擴區，
    /// 外擴區重疊時正規化距離最小的勝（同樣大小＝中心最近的）
    static func resolve(_ p: CGPoint, _ rects: [CGRect], minSide m: CGFloat) -> Int? {
        if let i = rects.indices.filter({ rects[$0].contains(p) }).min(by: { rects[$0].width * rects[$0].height < rects[$1].width * rects[$1].height }) { return i }
        var best: (Int, CGFloat)?
        for (i, r) in rects.enumerated() where expanded(r, min: m).contains(p) {
            let d = depth(p, r)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
    /// 吸進目標：已經在裡面不動；在外面就拉到框內 2 px
    static func snap(_ p: CGPoint, into r: CGRect) -> CGPoint {
        let ir = r.insetBy(dx: min(2, r.width / 2), dy: min(2, r.height / 2))
        return CGPoint(x: min(max(p.x, ir.minX), ir.maxX), y: min(max(p.y, ir.minY), ir.maxY))
    }
    /// 太小、要「碰了先展開」的控制項：近乎方形而且比手指小
    static func needsExpansion(_ r: CGRect, minSide m: CGFloat) -> Bool {
        let a = r.width / max(1, r.height)
        return min(r.width, r.height) < m * 0.9 && a > 0.6 && a < 1.7
    }
}

/// 螢幕上的單指拖：鎖方向（同 iOS 的捲動視圖：起手明顯偏一邊就只走那一軸）
struct TouchScrollLock: Equatable {
    enum Axis: Equatable { case pending, horizontal, vertical, free }
    private(set) var axis: Axis = .pending
    private var acc = CGPoint.zero
    static let slop: CGFloat = 5

    mutating func feed(dx: CGFloat, dy: CGFloat) -> (dx: CGFloat, dy: CGFloat) {
        if axis == .pending {
            acc.x += dx; acc.y += dy
            guard hypot(acc.x, acc.y) >= Self.slop else { return (0, 0) }
            axis = abs(acc.x) > abs(acc.y) * 1.2 ? .horizontal : (abs(acc.y) > abs(acc.x) * 1.2 ? .vertical : .free)
            let a = acc; acc = .zero
            return lock(a.x, a.y)
        }
        return lock(dx, dy)
    }
    private func lock(_ dx: CGFloat, _ dy: CGFloat) -> (dx: CGFloat, dy: CGFloat) {
        switch axis {
        case .horizontal: return (dx, 0)
        case .vertical: return (0, dy)
        case .free: return (dx, dy)
        case .pending: return (0, 0)
        }
    }
    var started: Bool { axis != .pending }
}

/// 眼神（拍板 2）：手指按著看手指，放開 1 秒後回到平常（看人或原本的樣子）
struct TouchGaze: Equatable {
    static let linger = 1.0
    private(set) var point: CGPoint?
    private(set) var releasedAt: Double?
    mutating func press(_ p: CGPoint) { point = p; releasedAt = nil }
    mutating func move(_ p: CGPoint) { if point != nil, releasedAt == nil { point = p } }
    mutating func release(now: Double) { if point != nil, releasedAt == nil { releasedAt = now } }
    /// 這一刻要看哪裡（nil＝照平常）
    mutating func pointer(now: Double) -> CGPoint? {
        if let r = releasedAt, now - r > Self.linger { point = nil; releasedAt = nil }
        return point
    }
    /// 螢幕座標的手指 → face.pointer（跟游標同一個換算：PetView.watchPointer）
    static func pointer(finger s: NSPoint, window f: NSRect) -> CGPoint {
        CGPoint(x: (s.x - f.midX) / (f.width * 0.6), y: -(s.y - f.midY) / (f.height * 0.6))
    }
}

/// 碰了先展開的臨時大版本（HIG expandable controls）：按著時展開，放開後停 1 秒再收
enum TouchExpand {
    static let linger = 1.0, grow = 0.16, fade = 0.2
    nonisolated(unsafe) static var target: (rect: CGRect, shape: HPAXNote.Shape)?
    nonisolated(unsafe) static var shownAt = 0.0
    nonisolated(unsafe) static var releasedAt: Double?
    nonisolated(unsafe) static var frozen = false   // 快照：停在展開好的樣子

    static func show(_ rect: CGRect, shape: HPAXNote.Shape, now: Double) { target = (rect, shape); shownAt = now; releasedAt = nil }
    static func release(now: Double) { if target != nil, releasedAt == nil { releasedAt = now } }
    static func hide() { target = nil; releasedAt = nil }
    /// (展開程度 0…1, 不透明度 0…1)；nil＝不畫
    static func state(now: Double, reduceMotion: Bool) -> (k: CGFloat, alpha: CGFloat)? {
        guard target != nil else { return nil }
        if frozen { return (1, 1) }
        let t = now - shownAt
        let k: CGFloat = reduceMotion ? 1 : CGFloat(min(1, t / grow))
        var a: CGFloat = reduceMotion ? CGFloat(min(1, t / 0.1)) : 1
        if let r = releasedAt {
            let out = now - r - linger
            if out > fade { target = nil; releasedAt = nil; return nil }
            if out > 0 { a *= CGFloat(1 - out / fade) }
        }
        let e = 1 - pow(1 - k, 3)   // ease-out
        return (e, a)
    }
    static func animating(now: Double) -> Bool { target != nil && !frozen }
}

/// 第一次在觸控螢幕上的提示卡：「從 👀 往下拉，回到主畫面」；點一下或 8 秒後收，記下來不再出
enum TouchTip {
    /// 提示卡的圓角跟螢幕同心（左右離螢幕 92 → 138 − 92；上下位置跟著膠囊，近的那邊算）
    static func radius(_ r: CGRect) -> CGFloat { HPTokens.Radius.concentric(rect: r) }
    static let defaultsKey = "HomePlayTouchTipShown"
    static let duration = 8.0
    nonisolated(unsafe) static var active = false
    nonisolated(unsafe) static var until = 0.0
    nonisolated(unsafe) static var forced = false   // 快照（--touch-tip）：不讀也不寫偏好
    nonisolated(unsafe) static var checkedScreen: ObjectIdentifier?
    static var shown: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    static func dismiss() {
        guard active else { return }
        active = false
        if !forced { UserDefaults.standard.set(true, forKey: defaultsKey) }
    }
}

/// CarPlay 兩指（拍板 3，只做探驗準備）：預設關。說明見 docs/plans/touch.md 的「CarPlay 兩指」
enum CarPlayTwoFinger {
    static let defaultsKey = "HomePlayExperimentalCarPlayTwoFinger"
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["HOMEPLAY_CARPLAY_TWO_FINGER"] == "1" || UserDefaults.standard.bool(forKey: defaultsKey)
    }
}

// MARK: - 觸控狀態

enum TouchInput {
    /// 正在送 PetView 的「觸控造的」滑鼠事件
    nonisolated(unsafe) static var synthesizing = false
    nonisolated(unsafe) static var fingerDown = false
    nonisolated(unsafe) static var lastLiftAt = -10.0
    nonisolated(unsafe) static var lastTouchAt = -10.0
    nonisolated(unsafe) static var arbiter = TouchArbiter()
    /// 手指目前的位置（螢幕座標；搬視窗時視窗在動，要用螢幕座標）
    nonisolated(unsafe) static var screenPoint = NSPoint.zero
    nonisolated(unsafe) static var downScreen = NSPoint.zero
    nonisolated(unsafe) static var downAt = 0.0
    nonisolated(unsafe) static var downRegion = TouchRegion.none
    /// 外擴判定區把按下點吸進目標的位移（視圖點）；整段都帶著同一個位移，拖起來不會跳
    nonisolated(unsafe) static var snapOffset = CGVector.zero
    nonisolated(unsafe) static var commitWork: DispatchWorkItem?
    nonisolated(unsafe) static var lastEvent: NSEvent?
    nonisolated(unsafe) static var gaze = TouchGaze()
    /// 連點：上一次點按（時間、螢幕位置）
    nonisolated(unsafe) static var lastTap: (t: Double, p: NSPoint)?
    /// 螢幕上的單指拖改成捲動（拍板 4）
    nonisolated(unsafe) static var scroll: TouchScrollState?
    nonisolated(unsafe) static var momentum: Timer?
    /// 第二根手指（CarPlay 實驗旗標用）
    nonisolated(unsafe) static var second: NSPoint?
    nonisolated(unsafe) static var pinchLast: CGFloat = 0
    nonisolated(unsafe) static var rotationLast: CGFloat = 0
    /// 捏合與旋轉互斥（同一次兩指只認一個）；兩個辨識器都結束才重來
    nonisolated(unsafe) static var twoLock = TwoFingerLock()
    nonisolated(unsafe) static var pinchActive = false
    nonisolated(unsafe) static var rotationActive = false
    nonisolated(unsafe) static var probe: ((Double, Double), (Double, Double))?
    nonisolated(unsafe) static var pan2Active = false
    /// 除錯疊圖（HOMEPLAY_TOUCH_DEBUG=1）：畫出每個目標外擴後的判定區
    static let debugOverlay = ProcessInfo.processInfo.environment["HOMEPLAY_TOUCH_DEBUG"] == "1"
    /// 目前 44 pt 等於畫布幾 px（每幀由 PetView 更新）
    nonisolated(unsafe) static var minSide: CGFloat = 120

    static func dropsSystemEvent() -> Bool {
        let now = CACurrentMediaTime()
        return TouchArbiter.dropsSystemEvent(synthesizing: synthesizing, fingerDown: fingerDown, sinceLift: now - lastLiftAt, sinceTouch: now - lastTouchAt)
    }
    nonisolated(unsafe) static var scrollSwallow = TouchScrollSwallow()
    /// 系統模擬的捲動：手指按著時開始的那一段連慣性一起丟（PetView.scrollWheel 開頭）
    static func dropsSystemScroll(_ e: NSEvent) -> Bool {
        let p = e.phase, m = e.momentumPhase
        return scrollSwallow.drops(now: CACurrentMediaTime(), synthesizing: synthesizing, systemDrop: dropsSystemEvent(),
                                   began: p.contains(.began) || p.contains(.mayBegin), phased: p != [] || m != [],
                                   momentumEnd: m.contains(.ended) || m.contains(.cancelled))
    }
    /// 機身上按住叫出的選單關了（popUp 是同步的，手指多半在選單追蹤時就抬起、結束事件被選單吃掉）：當成手指已經放開
    static func menuClosed(now: Double) {
        commitWork?.cancel(); commitWork = nil
        arbiter.phase = .idle
        fingerDown = false; lastLiftAt = now; lastTouchAt = now
        gaze.release(now: now)
        second = nil
    }
    /// 最近有人用手指碰過（算「人在旁邊」）
    static func recentlyTouched(_ now: Double, within s: Double = 3) -> Bool { fingerDown || now - lastTouchAt < s }
}

struct TouchScrollState {
    var lock = TouchScrollLock()
    var last: NSPoint                       // 視圖點
    var pxPerPoint: CGFloat                 // 視圖點 → 畫布 px
    var uv: CGPoint?                        // 起手的螢幕 uv（捲動事件帶給外殼：滑桿、圖庫看位置）
    var began = false
    var samples: [(t: Double, x: CGFloat, y: CGFloat)] = []
    var carry = CGPoint.zero                // 捲動事件只收整數 px：餘數留到下一次
}

/// 放手後的慣性：照 Apple 的減速（每毫秒 0.998，一幀約 0.967）一路送到停
final class TouchMomentum {
    var vx: CGFloat, vy: CGFloat
    let uv: CGPoint?
    private var carry = CGPoint.zero, first = true, ended = false
    init(vx: CGFloat, vy: CGFloat, uv: CGPoint?) { self.vx = vx; self.vy = vy; self.uv = uv }
    /// 下一幀的 (dx, dy, momentum phase)；nil＝已經結束
    func step() -> (CGFloat, CGFloat, Int64)? {
        guard !ended else { return nil }
        vx *= 0.967; vy *= 0.967
        if hypot(vx, vy) < 40 { ended = true; return (0, 0, 3) }
        let fx = vx / 60 + carry.x, fy = vy / 60 + carry.y
        let ix = fx.rounded(.towardZero), iy = fy.rounded(.towardZero)
        carry = CGPoint(x: fx - ix, y: fy - iy)
        defer { first = false }
        return (ix, iy, first ? 1 : 2)
    }
}

// MARK: - 單指追蹤（自訂辨識器）

/// 一根手指從碰到到放開：碰到就 began、動了 changed、放開 ended、被系統收走 cancelled；第二根手指不影響它（另外記）
final class TouchTracker: NSGestureRecognizer {
    private var primary: (any NSObjectProtocol & NSCopying)?
    private(set) var primaryPoint = NSPoint.zero        // 視圖座標
    private(set) var secondPoint: NSPoint?
    private var secondID: (any NSObjectProtocol & NSCopying)?
    private(set) var touchCount = 0

    override func location(in view: NSView?) -> NSPoint {
        guard let host = self.view else { return primaryPoint }
        return view.map { $0.convert(primaryPoint, from: host) } ?? host.convert(primaryPoint, to: nil)
    }

    override func touchesBegan(with event: NSEvent) {
        guard let v = view else { return }
        for t in event.touches(matching: .began, in: v) where t.type == .direct {
            touchCount += 1
            if primary == nil {
                primary = t.identity; primaryPoint = t.location(in: v)
                state = .began
            } else if secondID == nil {
                secondID = t.identity; secondPoint = t.location(in: v)
                if state == .began || state == .changed { state = .changed }   // 讓動作方法知道第二根手指來了
            }
        }
    }
    override func touchesMoved(with event: NSEvent) {
        guard let v = view else { return }
        var moved = false
        for t in event.touches(matching: .moved, in: v) where t.type == .direct {
            if let p = primary, t.identity.isEqual(p) { primaryPoint = t.location(in: v); moved = true }
            else if let s = secondID, t.identity.isEqual(s) { secondPoint = t.location(in: v); moved = true }
        }
        if moved, state == .began || state == .changed { state = .changed }
    }
    override func touchesEnded(with event: NSEvent) {
        guard let v = view else { return }
        for t in event.touches(matching: .ended, in: v) where t.type == .direct {
            touchCount = max(0, touchCount - 1)
            if let s = secondID, t.identity.isEqual(s) {
                secondID = nil; secondPoint = nil
                if state == .began || state == .changed { state = .changed }
            }
            if let p = primary, t.identity.isEqual(p) {
                primaryPoint = t.location(in: v)
                if state == .began || state == .changed { state = .ended }
            }
        }
    }
    override func touchesCancelled(with event: NSEvent) {
        if state == .began || state == .changed { state = .cancelled } else { state = .failed }
    }
    override func reset() {
        primary = nil; secondID = nil; secondPoint = nil; touchCount = 0
        super.reset()
    }
}

// MARK: - PetView：辨識器、觸控造的滑鼠事件

extension PetView: NSGestureRecognizerDelegate {
    /// init 時一行呼叫：只在 macOS 27 起掛（之前沒有觸控螢幕，也沒有這些 API）
    func installTouchGestures() {
        guard #available(macOS 27.0, *) else { return }
        exclusiveGestureBehavior = .exclusive
        let tracker = TouchTracker(target: self, action: #selector(touchTrackerAction(_:)))
        let press = NSPressGestureRecognizer(target: self, action: #selector(touchPressAction(_:)))
        press.minimumPressDuration = 0.5
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(touchPinchAction(_:)))
        let pan2 = NSPanGestureRecognizer(target: self, action: #selector(touchPan2Action(_:)))
        pan2.minimumNumberOfTouches = 2; pan2.maximumNumberOfTouches = 2
        let rotation = NSRotationGestureRecognizer(target: self, action: #selector(touchRotationAction(_:)))
        for r in [tracker, press, pinch, pan2, rotation] as [NSGestureRecognizer] {
            r.allowedTouchTypes = .direct
            r.delegate = self
            addGestureRecognizer(r)
        }
        press.buttonMask = 0; pan2.buttonMask = 0
        log("touch: gesture recognizers installed")
    }

    // MARK: 篩選（官方：觸控用 shouldReceive，指標用 shouldAttemptToRecognizeWith）

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        false   // 指標（滑鼠、觸控板）一律不給這幾個辨識器：照原本的路
    }

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        guard touch.type == .direct, window != nil else { return false }
        let p = touch.location(in: self)
        let region = touchRegion(p)
        let live = showingVideo && !carVideo.active
        switch g {
        case is TouchTracker: return true
        case is NSPressGestureRecognizer: return TouchRoute.pressMenuAccepts(region)
        case is NSMagnificationGestureRecognizer: return TouchRoute.pinchAccepts(region, live: live)
        case is NSRotationGestureRecognizer: return TouchRoute.rotationAccepts(region, live: live)
        case is NSPanGestureRecognizer: return TouchRoute.twoFingerPanAccepts(region)
        default: return false
        }
    }

    func gestureRecognizerShouldBegin(_ g: NSGestureRecognizer) -> Bool {
        if g is TouchTracker { return true }
        return TouchInput.arbiter.twoFingerMayBegin   // 單指已經在拖：捏合、兩指拖、按住選單都不開始
    }

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
        if g is TouchTracker || other is TouchTracker { return true }   // 單指追蹤跟誰都並存
        // 捏合與旋轉同時跑，由 TwoFingerLock 判歸誰（先超過門檻的勝）；其餘（兩指拖、按住）互斥
        return (g is NSMagnificationGestureRecognizer && other is NSRotationGestureRecognizer)
            || (g is NSRotationGestureRecognizer && other is NSMagnificationGestureRecognizer)
    }

    // MARK: 動作（每個都處理 .cancelled，回到乾淨狀態）

    @objc func touchTrackerAction(_ r: TouchTracker) {
        guard let win = window else { return }
        let sp = win.convertPoint(toScreen: convert(r.primaryPoint, to: nil))
        TouchInput.second = r.secondPoint.map { win.convertPoint(toScreen: convert($0, to: nil)) }
        switch r.state {
        case .began: touchBegan(screen: sp)
        case .changed: touchMoved(screen: sp)
        case .ended: touchEnded(screen: sp)
        case .cancelled, .failed: touchCancelled()
        default: break
        }
        if CarPlayTwoFinger.enabled { touchCarPlayTwoFingerProbe() }
    }

    @objc func touchPressAction(_ r: NSPressGestureRecognizer) {
        switch r.state {
        case .began:
            // 機身上按住＝右鍵選單：單指那一下（還沒動）作廢，選單開在手指的位置
            if TouchInput.arbiter.twoFingerBegan() { touchAbortPointerSequence() } else { TouchInput.commitWork?.cancel() }
            let p = r.location(in: self)
            log("touch: press-and-hold on body → menu")
            if let e = touchMouseEvent(.rightMouseDown, at: p) {
                touchSynth { rightMouseDown(with: e) }
                // 選單關了才回到這裡：手指的結束事件可能已經被選單吃掉——不重設的話之後滑鼠、滾輪、捏合會一直被當成「手指還在」丟掉
                TouchInput.menuClosed(now: CACurrentMediaTime())
                for g in gestureRecognizers where g is TouchTracker { g.isEnabled = false; g.isEnabled = true }   // 單指追蹤也重來（不然下一根手指會被當成第二指）
                face.forceDirty = true
            }
        case .cancelled, .failed, .ended: break   // 選單自己追蹤；手指放開時 TouchTracker 收尾
        default: break
        }
    }

    @objc func touchPinchAction(_ r: NSMagnificationGestureRecognizer) {
        switch r.state {
        case .began:
            if TouchInput.arbiter.twoFingerBegan() { touchAbortPointerSequence() } else { TouchInput.commitWork?.cancel() }
            if !TouchInput.rotationActive { TouchInput.twoLock.reset() }
            TouchInput.pinchActive = true
            TouchInput.pinchLast = r.magnification
            log("touch: pinch began")
        case .changed:
            // magnification 是從起手累計；換成這一幀的倍率，跟觸控板捏合一樣限幅
            let f = min(1.06, max(0.94, (1 + r.magnification) / max(0.05, 1 + TouchInput.pinchLast)))
            TouchInput.pinchLast = r.magnification
            guard TouchInput.twoLock.feed(scale: f - 1) == .pinch else { return }   // 這一次兩指歸旋轉（或還沒定）：不縮放
            if abs(f - 1) > 0.0005 { resizeWindow(toWidth: bounds.width * f, anchorCenter: true) }
        case .ended, .cancelled, .failed:
            TouchInput.pinchLast = 0; TouchInput.pinchActive = false
            if !TouchInput.rotationActive { TouchInput.twoLock.reset() }
            touchEndResize()
        default: break
        }
    }

    /// 兩指旋轉＝原地轉身（跟觸控板同一條：PetView.twistYaw；放手帶慣性，減少動態效果直接停）
    @objc func touchRotationAction(_ r: NSRotationGestureRecognizer) {
        let t = ProcessInfo.processInfo.systemUptime
        switch r.state {
        case .began:
            if TouchInput.arbiter.twoFingerBegan() { touchAbortPointerSequence() } else { TouchInput.commitWork?.cancel() }
            if !TouchInput.pinchActive { TouchInput.twoLock.reset() }
            TouchInput.rotationActive = true
            TouchInput.rotationLast = r.rotation
            log("touch: rotation began")
        case .changed:
            let d = r.rotation - TouchInput.rotationLast
            TouchInput.rotationLast = r.rotation
            if TouchInput.twoLock.feed(angle: d) == .rotate { twistYaw(by: d, timestamp: t) }
        case .ended, .cancelled, .failed:
            TouchInput.rotationLast = 0; TouchInput.rotationActive = false
            if TouchInput.twoLock.kind == .rotate { twistYawEnded(timestamp: t) }
            if !TouchInput.pinchActive { TouchInput.twoLock.reset() }
        default: break
        }
    }

    @objc func touchPan2Action(_ r: NSPanGestureRecognizer) {
        let p = r.location(in: self)
        switch r.state {
        case .began:
            if TouchInput.arbiter.twoFingerBegan() { touchAbortPointerSequence() } else { TouchInput.commitWork?.cancel() }
            touchBeginRotate(at: p, timestamp: ProcessInfo.processInfo.systemUptime)
            TouchInput.pan2Active = true
        case .changed:
            guard TouchInput.pan2Active, let e = touchMouseEvent(.leftMouseDragged, at: p) else { return }
            touchSynth { mouseDragged(with: e) }
        case .ended:
            guard TouchInput.pan2Active else { return }
            TouchInput.pan2Active = false
            if let e = touchMouseEvent(.leftMouseUp, at: p) { touchSynth { mouseUp(with: e) } }
        case .cancelled, .failed:
            if TouchInput.pan2Active { TouchInput.pan2Active = false; touchAbortPointerSequence() }
        default: break
        }
    }

    // MARK: 單指的一整段（自檢腳本也從這裡注入假觸控）

    func touchBegan(screen sp: NSPoint) {
        let now = CACurrentMediaTime()
        touchStopMomentum()
        TouchInput.fingerDown = true; TouchInput.lastTouchAt = now
        TouchInput.screenPoint = sp; TouchInput.downScreen = sp; TouchInput.downAt = now
        TouchInput.snapOffset = .zero
        TouchInput.arbiter.phase = .pending
        TouchInput.scroll = nil
        if TouchTip.active { TouchTip.dismiss(); face.forceDirty = true }
        IntroGuide.note(.touch)   // 手勢引導「自動」：最近一次用的是手指
        touchWillBegin()
        if let f = window?.frame { TouchInput.gaze.press(TouchGaze.pointer(finger: sp, window: f)) }
        // 等一下看是不是兩指：70 ms 到了還是單指就當成按下
        let work = DispatchWorkItem { [weak self] in
            guard let self, TouchInput.arbiter.phase == .pending else { return }
            self.touchCommit()
        }
        TouchInput.commitWork?.cancel()
        TouchInput.commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TouchArbiter.commitDelay, execute: work)
    }

    func touchMoved(screen sp: NSPoint) {
        TouchInput.screenPoint = sp; TouchInput.lastTouchAt = CACurrentMediaTime()
        if let f = window?.frame { TouchInput.gaze.move(TouchGaze.pointer(finger: sp, window: f)) }
        let moved = hypot(sp.x - TouchInput.downScreen.x, sp.y - TouchInput.downScreen.y)
        switch TouchInput.arbiter.phase {
        case .pending:
            if TouchInput.second != nil { TouchInput.arbiter.phase = .ignored; TouchInput.commitWork?.cancel(); return }   // 兩指：交給捏合／兩指拖
            guard TouchArbiter.shouldCommit(elapsed: CACurrentMediaTime() - TouchInput.downAt, moved: moved) else { return }
            touchCommit()
            fallthrough
        case .tracking:
            if moved > ShellInput.slop { TouchInput.arbiter.phase = .tracking(moved: true) }
            guard let e = touchMouseEvent(.leftMouseDragged, atScreen: sp) else { return }
            touchSynth { mouseDragged(with: e) }
        case .idle, .ignored: break
        }
    }

    func touchEnded(screen sp: NSPoint) {
        let now = CACurrentMediaTime()
        TouchInput.screenPoint = sp
        if TouchInput.arbiter.phase == .pending { touchCommit() }   // 很快的點按：按下、放開一起送
        if case .tracking = TouchInput.arbiter.phase, let e = touchMouseEvent(.leftMouseUp, atScreen: sp) {
            touchSynth { mouseUp(with: e) }
            if hypot(sp.x - TouchInput.downScreen.x, sp.y - TouchInput.downScreen.y) < 10 { TouchInput.lastTap = (now, sp) }
        }
        touchFinish(now: now)
    }

    func touchCancelled() {
        if case .tracking = TouchInput.arbiter.phase { touchAbortPointerSequence() }
        touchFinish(now: CACurrentMediaTime())
    }

    private func touchFinish(now: Double) {
        TouchInput.commitWork?.cancel(); TouchInput.commitWork = nil
        TouchInput.arbiter.phase = .idle
        TouchInput.fingerDown = false; TouchInput.lastLiftAt = now; TouchInput.lastTouchAt = now
        TouchInput.gaze.release(now: now)
        TouchExpand.release(now: now)
        TouchInput.second = nil
        face.forceDirty = true
    }

    /// 確定是單指：把按下送進原本的滑鼠入口（螢幕上先照外擴判定區吸到最近的目標）
    private func touchCommit() {
        TouchInput.commitWork?.cancel(); TouchInput.commitWork = nil
        if TouchInput.second != nil { TouchInput.arbiter.phase = .ignored; return }   // 兩指同時：單指這一下不送（捏合、兩指拖接手）
        TouchInput.arbiter.phase = .tracking(moved: false)
        guard let win = window else { return }
        let p = convert(win.convertPoint(fromScreen: TouchInput.downScreen), from: nil)
        TouchInput.downRegion = touchRegion(p)
        let live = showingVideo && !carVideo.active
        if TouchInput.downRegion == .screen, !live { touchSnap(at: p) }
        // 連點：只在機身上算（雙擊機身＝回正）；螢幕上每一下都是單點（外殼的點按不認雙擊）
        var clicks = 1
        if TouchInput.downRegion == .body, let l = TouchInput.lastTap, CACurrentMediaTime() - l.t < NSEvent.doubleClickInterval,
           hypot(l.p.x - TouchInput.downScreen.x, l.p.y - TouchInput.downScreen.y) < 30 { clicks = 2 }
        log("touch: down \(TouchInput.downRegion) → \(TouchRoute.singleFinger(TouchInput.downRegion, live: live))")
        guard let e = touchMouseEvent(.leftMouseDown, atScreen: TouchInput.downScreen, clickCount: clicks) else { return }
        touchSynth { mouseDown(with: e) }
    }

    /// 外擴判定區：落點不在任何目標上、但在某個目標外擴到 44 pt 的範圍裡，就把這一下（整段）吸過去；
    /// 吸到的若是太小太密的控制項，先展開成臨時大版本。邊緣手勢區（膠囊、控制中心角、底緣、左緣）不吸。
    private func touchSnap(at p: NSPoint) {
        guard let uv = touchScreenUV(p), touchSnapAllowed(uv: uv) else { return }
        let c = CGPoint(x: uv.x * 1024, y: uv.y * 1024)
        TouchInput.minSide = TouchHit.minSide(screenWidthPoints: touchScreenWidthPoints)
        let items = ShellAccessibility.items(face: face).filter { $0.focusable && $0.rect.width < 1000 }
        guard let i = TouchHit.resolve(c, items.map(\.rect), minSide: TouchInput.minSide) else { return }
        let it = items[i]
        let q = TouchHit.snap(c, into: it.rect)
        if q != c, let vq = touchCanvasToView(q) {
            TouchInput.snapOffset = CGVector(dx: vq.x - p.x, dy: vq.y - p.y)
            log("touch: snapped to \(it.id)")
        }
        if touchExpandable(it) { TouchExpand.show(it.rect, shape: it.shape, now: CACurrentMediaTime()); face.forceDirty = true }
    }

    /// 太小太密、碰了要先展開的：控制中心的小圓鈕與頁點、主畫面右上的頭像（而且目前真的比手指小）
    func touchExpandable(_ it: ShellAXItem) -> Bool {
        guard it.id == "avatar" || it.id.hasPrefix("cc.") else { return false }
        return TouchHit.needsExpansion(it.rect, minSide: TouchInput.minSide)
    }

    /// 兩指接手、或系統收走：已經送出去的「按下」安靜地收掉（不當成點按、不轉身體、不留按壓的亮）
    /// 外殼的各種拖動走自己的收尾（膠囊彈回、錶面退回、主畫面回到最近一頁、控制中心照落點收；ShellInput.shellCancelGesture）
    func touchAbortPointerSequence() {
        shellCancelGesture()
        FaceOverview.pressToken += 1; FaceOverview.pressAt = nil
        TouchInput.scroll = nil
        TouchExpand.hide()
        touchCancelPointer()
        face.forceDirty = true
    }

    // MARK: 造事件

    func touchMouseEvent(_ type: NSEvent.EventType, at viewPoint: NSPoint, clickCount: Int = 1) -> NSEvent? {
        guard let win = window else { return nil }
        let e = NSEvent.mouseEvent(with: type, location: convert(viewPoint, to: nil), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
        TouchInput.lastEvent = e
        return e
    }
    private func touchMouseEvent(_ type: NSEvent.EventType, atScreen sp: NSPoint, clickCount: Int = 1) -> NSEvent? {
        guard let win = window else { return nil }
        let p = convert(win.convertPoint(fromScreen: sp), from: nil)
        return touchMouseEvent(type, at: NSPoint(x: p.x + TouchInput.snapOffset.dx, y: p.y + TouchInput.snapOffset.dy), clickCount: clickCount)
    }

    /// 畫布點 → 視圖點（跟點按同一份機身投影的反方向）
    func touchCanvasToView(_ q: CGPoint) -> NSPoint? {
        let c = screenCorners()
        let unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        guard c.count == 4, let h = homography(from: unit, to: c) else { return nil }
        return applyHomography(h, CGPoint(x: q.x / 1024, y: q.y / 1024))
    }
    /// 螢幕在視圖裡的寬（點）：上下兩條邊的平均
    var touchScreenWidthPoints: CGFloat {
        let c = screenCorners()
        guard c.count == 4 else { return bounds.width * 0.6 }
        return (hypot(c[1].x - c[0].x, c[1].y - c[0].y) + hypot(c[2].x - c[3].x, c[2].y - c[3].y)) / 2
    }

    /// 搬視窗、縮放用的指標位置：觸控時是手指（系統游標不一定跟著手指走）
    var pointerScreenLocation: NSPoint { TouchInput.synthesizing && TouchInput.fingerDown ? TouchInput.screenPoint : NSEvent.mouseLocation }

    // MARK: 螢幕上的單指拖＝外殼（拍板 4）：本來會交回去轉身體的，改成捲動
    // 2026-11-07 拍板「螢幕是內容、機身是物件」：滑鼠、觸控板的點按拖也走這條（三種輸入意思一致），轉身體只認拖機身

    /// PetView.mouseDown 最後要開始轉身體時問：按在螢幕上（觸控看手指起手的區域，滑鼠／觸控板看游標）→ 這一下改成「螢幕拖」
    func touchArmsScreenDrag(at p: NSPoint) -> Bool {
        let region = TouchInput.synthesizing ? TouchInput.downRegion : touchRegion(p)
        guard TouchRoute.singleFinger(region, live: showingVideo || carVideo.active) == .shell else { return false }
        TouchInput.scroll = TouchScrollState(last: p, pxPerPoint: 1024 / max(40, touchScreenWidthPoints), uv: touchScreenUV(p))
        log("touch: screen drag armed")
        return true
    }

    /// 轉身體那條路的拖動：螢幕拖就改送捲動。回 true＝吃掉了
    func touchScreenDragged(_ e: NSEvent) -> Bool {
        guard var s = TouchInput.scroll else { return false }
        let p = convert(e.locationInWindow, from: nil)
        let raw = (dx: p.x - s.last.x, dy: p.y - s.last.y)
        s.last = p
        // 錶面上的橫拖等 FacePaging 決定（它會把這一下接走）；決定是直的才輪到這裡
        if FacePaging.drag != nil { TouchInput.scroll = s; return true }
        let (lx, ly) = s.lock.feed(dx: raw.dx, dy: raw.dy)
        guard s.lock.started else { TouchInput.scroll = s; return true }
        // 視圖 y 往上；畫布 y 往下。手指往下＝內容往下（直接操作：等同自然捲動）
        let fx = lx * s.pxPerPoint + s.carry.x, fy = -ly * s.pxPerPoint + s.carry.y
        let ix = fx.rounded(.towardZero), iy = fy.rounded(.towardZero)
        s.carry = CGPoint(x: fx - ix, y: fy - iy)
        let now = CACurrentMediaTime()
        s.samples.append((now, fx, fy)); if s.samples.count > 6 { s.samples.removeFirst() }
        if ix != 0 || iy != 0 {
            touchDeliverScroll(dx: ix, dy: iy, phase: s.began ? 2 : 1, momentum: 0, uv: s.uv)
            s.began = true
        }
        TouchInput.scroll = s
        return true
    }

    /// 放手：捲過就收尾（帶慣性）並吃掉；沒捲＝點按，交回原本的路（膠囊播放、System 6…）
    func touchScreenReleased(_ e: NSEvent) -> Bool {
        guard let s = TouchInput.scroll else { return false }
        TouchInput.scroll = nil
        guard s.lock.started else { return false }
        if s.began { touchDeliverScroll(dx: 0, dy: 0, phase: 4, momentum: 0, uv: s.uv) }
        // 慣性：最近幾個取樣的速度，照 Apple 的減速（每毫秒 0.998）一路送下去
        if let a = s.samples.first, let b = s.samples.last, b.t > a.t, CACurrentMediaTime() - b.t < 0.08 {
            let dt = max(0.008, CGFloat(b.t - a.t))
            let m = TouchMomentum(vx: s.samples.dropFirst().reduce(0) { $0 + $1.x } / dt,
                                  vy: s.samples.dropFirst().reduce(0) { $0 + $1.y } / dt, uv: s.uv)
            if hypot(m.vx, m.vy) > 250 {
                let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                    guard let self, let st = m.step() else { timer.invalidate(); TouchInput.momentum = nil; return }
                    self.touchDeliverScroll(dx: st.0, dy: st.1, phase: 0, momentum: st.2, uv: m.uv)
                    if st.2 == 3 { timer.invalidate(); TouchInput.momentum = nil }
                }
                RunLoop.main.add(t, forMode: .common)
                TouchInput.momentum = t
            }
        }
        return true
    }

    func touchStopMomentum() {
        guard let m = TouchInput.momentum else { return }
        m.invalidate(); TouchInput.momentum = nil
        touchDeliverScroll(dx: 0, dy: 0, phase: 0, momentum: 3, uv: nil)
    }

    /// 造一個觸控板式的精確捲動事件（phase：1 began、2 changed、4 ended；momentum：1 begin、2 continue、3 end），送給總覽與外殼
    private func touchDeliverScroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentum: Int64, uv: CGPoint?) {
        // 錶面上沒有東西可捲（橫向換頁由 FacePaging 接）：螢幕上的直拖什麼都不做，也不轉身體
        if Shell.nav.screen == .face, Shell.nav.overlay == .none, !face.inOverview { return }
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        guard let e = NSEvent(cgEvent: cg) else { return }
        if phase == 1 { log("touch: screen drag → scroll on \(Shell.nav.screen)") }
        touchSynth {
            if overviewScroll(e) { return }
            _ = shellScroll(e, uv: uv)
        }
    }

    /// 送「觸控造的」事件：期間標記 synthesizing（巢狀呼叫時還原成外層的值）
    func touchSynth(_ body: () -> Void) {
        let was = TouchInput.synthesizing
        TouchInput.synthesizing = true
        defer { TouchInput.synthesizing = was }
        body()
    }

    // MARK: 每幀

    func touchStep(_ now: Double) {
        if TouchInput.debugOverlay || TouchInput.fingerDown { TouchInput.minSide = TouchHit.minSide(screenWidthPoints: touchScreenWidthPoints) }
        if TouchExpand.animating(now: now) { face.forceDirty = true }
        if TouchTip.active, !TouchTip.forced, now > TouchTip.until { TouchTip.dismiss(); face.forceDirty = true }
        // 第一次在觸控螢幕上：出提示卡（只看視窗所在的螢幕；Sidecar 的 iPad 也算）
        if #available(macOS 27.0, *), !TouchTip.active, !AppDelegate.isDiagnosticRun, let s = window?.screen,
           TouchTip.checkedScreen != ObjectIdentifier(s), !face.onboardingActive, !face.sayingHello, IntroGuide.newGestureTips {   // 設定「遇到新手勢時提示一次」關掉就不出
            TouchTip.checkedScreen = ObjectIdentifier(s)
            if s.touchCapabilities.contains(.multiTouch), !TouchTip.shown {
                TouchTip.active = true; TouchTip.until = now + TouchTip.duration; face.forceDirty = true
                log("touch: tip shown (touch-capable screen)")
            }
        }
    }

    /// 眼神：手指按著時看手指（watchPointer 每拍問）
    func touchGazePointer(_ now: Double) -> CGPoint? { TouchInput.gaze.pointer(now: now) }

    /// CarPlay 兩指（實驗旗標開著才走）：兩指都在影片上時送兩個觸點，少一指就兩個一起放開。預設行為不變
    private func touchCarPlayTwoFingerProbe() {
        guard showingVideo, !carVideo.active, let win = window else { return }
        let p1 = convert(win.convertPoint(fromScreen: TouchInput.screenPoint), from: nil)
        if let s2 = TouchInput.second, TouchInput.fingerDown, let a = touchVideoPoint(p1), let b = touchVideoPoint(convert(win.convertPoint(fromScreen: s2), from: nil)) {
            TouchInput.probe = (a, b)
            onTouches?([(0, a.0, a.1, true), (1, b.0, b.1, true)])
        } else if let pr = TouchInput.probe {
            TouchInput.probe = nil
            onTouches?([(0, pr.0.0, pr.0.1, false), (1, pr.1.0, pr.1.1, false)])
            log("touch: carplay two-finger probe up")
        }
    }

    // MARK: 快照、自檢注入

    /// HOMEPLAY_TOUCH_EXPAND=<無障礙 id>：停在那個控制項展開好的樣子；--touch-tip：提示卡
    func applyTouchSnapshotFlags() {
        if CommandLine.arguments.contains("--touch-tip") { TouchTip.forced = true; TouchTip.active = true }
        if let id = ProcessInfo.processInfo.environment["HOMEPLAY_TOUCH_EXPAND"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                TouchInput.minSide = TouchHit.minSide(screenWidthPoints: self.touchScreenWidthPoints)
                if let it = ShellAccessibility.items(face: self.face).first(where: { $0.id == id }) {
                    TouchExpand.frozen = true
                    TouchExpand.show(it.rect, shape: it.shape, now: CACurrentMediaTime())
                    self.face.forceDirty = true
                    log("touch: expand \(id) rect=\(it.rect) minSide=\(Int(TouchInput.minSide))")
                } else { log("touch: expand target \(id) not found") }
            }
        }
    }

    /// 自檢腳本（HOMEPLAY_SHELL_SCRIPT）用：在螢幕 uv 注入一下假觸控。points＝uv 路徑（第一點按下、最後一點放開）；
    /// cancel＝最後不是放開而是被系統收走（同兩指接手、觸控被取消）
    func touchInject(_ path: [CGPoint], hold: Double = 0, cancel: Bool = false, done: @escaping () -> Void = {}) {
        guard let win = window, let first = path.first, let v0 = touchCanvasToView(CGPoint(x: first.x * 1024, y: first.y * 1024)) else { done(); return }
        func screen(_ uv: CGPoint) -> NSPoint {
            let v = touchCanvasToView(CGPoint(x: uv.x * 1024, y: uv.y * 1024)) ?? v0
            return win.convertPoint(toScreen: convert(v, to: nil))
        }
        touchBegan(screen: screen(first))
        let start = DispatchTime.now() + max(TouchArbiter.commitDelay + 0.03, hold)
        for (i, uv) in path.dropFirst().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: start + Double(i) * 0.016) { [weak self] in self?.touchMoved(screen: screen(uv)) }
        }
        DispatchQueue.main.asyncAfter(deadline: start + Double(path.count) * 0.016 + 0.02) { [weak self] in
            if cancel { self?.touchCancelled() } else { self?.touchEnded(screen: screen(path.last ?? first)) }
            done()
        }
    }
}

// MARK: - 畫：展開的控制項、提示卡、除錯疊圖

extension Face {
    func drawTouchOverlays(_ g: CGContext, _ now: Double) {
        if TouchInput.debugOverlay { drawTouchDebug(g) }
        drawTouchExpand(g, now)
        if TouchTip.active { drawTouchTip(g, now) }
    }

    /// 臨時大版本：把那一小塊放大到至少 44 pt，原地浮起來（不換成別的控制項；放開後停一下再收）
    private func drawTouchExpand(_ g: CGContext, _ now: Double) {
        guard let st = TouchExpand.state(now: now, reduceMotion: HPMotion.reduceMotion), let t = TouchExpand.target,
              let shot = g.makeImage() else { return }
        let k = st.k, alpha = st.alpha
        let r = t.rect
        let target = min(2.4, max(1.35, TouchInput.minSide / max(1, min(r.width, r.height))))
        let s = 1 + (target - 1) * k
        let pad = min(r.width, r.height) * 0.12
        let src = r.insetBy(dx: -pad, dy: -pad)
        var dst = CGRect(x: src.midX - src.width * s / 2, y: src.midY - src.height * s / 2, width: src.width * s, height: src.height * s)
        dst.origin.x = min(max(dst.minX, 8), 1016 - dst.width); dst.origin.y = min(max(dst.minY, 8), 1016 - dst.height)
        let px = CGFloat(shot.width) / 1024
        guard let crop = shot.cropping(to: CGRect(x: src.minX * px, y: src.minY * px, width: src.width * px, height: src.height * px)) else { return }
        let shape: CGPath
        switch t.shape {
        case .circle, .capsule: shape = CGPath(roundedRect: dst, cornerWidth: min(dst.width, dst.height) / 2, cornerHeight: min(dst.width, dst.height) / 2, transform: nil)
        case .rounded(let rad): shape = continuousRoundedRect(dst, radius: min(min(dst.width, dst.height) / 2, (rad + pad) * s))
        }
        let ic = HPAccessibility.increaseContrast, dark = HPTokens.dark
        g.saveGState()
        g.setAlpha(alpha)
        g.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: NSColor(white: 0, alpha: 0.35).cgColor)
        g.addPath(shape); g.setFillColor(NSColor(white: dark ? 0.12 : 0.96, alpha: 1).cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState()
        g.setAlpha(alpha)
        g.addPath(shape); g.clip()
        drawUpright(g, crop, in: dst)
        g.restoreGState()
        g.saveGState()
        g.setAlpha(alpha)
        g.addPath(shape)
        g.setStrokeColor((ic ? (dark ? NSColor.white : NSColor.black) : NSColor(white: 1, alpha: dark ? 0.35 : 0.7)).cgColor)
        g.setLineWidth(ic ? 4 : 2); g.strokePath()
        g.restoreGState()
    }

    /// 小卡：貼在 👀 膠囊旁邊，一個小箭頭指著它（沒有膠囊時置中、不畫箭頭）
    private func drawTouchTip(_ g: CGContext, _ now: Double) {
        let cap = capsuleCore
        let title = L("touch.tip.title", "从 👀 往下拉，回到主屏幕")
        let body = L("touch.tip.body", "按住看更多选项，两指捏合调整大小")
        let w: CGFloat = 840, h: CGFloat = 330, x = (1024 - w) / 2
        let tf = Self.fitted(title, size: 54, weight: .bold, maxWidth: w - 96)
        let bf = Self.fitted(body, size: 38, weight: .medium, maxWidth: w - 96)
        // 膠囊在上半（多數錶面、主畫面）＝卡片在它下面；在下半（有些錶面把它放在底下）＝卡片在它上面
        let above = cap.map { $0.midY > 512 } ?? false
        let top = cap.map { above ? max(40, $0.minY - 92 - h) : min(1024 - h - 40, $0.maxY + 92) } ?? (1024 - h) / 2
        let r = CGRect(x: x, y: top, width: w, height: h)
        let ic = HPAccessibility.increaseContrast, rad = TouchTip.radius(r)
        glass(g, r, radius: rad, tint: NSColor(white: 0, alpha: ic ? 0.62 : 0.32), band: 14)
        if ic {
            g.saveGState(); g.addPath(continuousRoundedRect(r, radius: rad)); g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(3); g.strokePath(); g.restoreGState()
        }
        if let cap {   // 小箭頭指著膠囊
            let a = above ? CGRect(x: cap.midX - 34, y: cap.minY - 76, width: 68, height: 60) : CGRect(x: cap.midX - 34, y: cap.maxY + 16, width: 68, height: 60)
            drawSymbol(g, above ? "chevron.compact.down" : "chevron.compact.up", in: a, color: NSColor.white.withAlphaComponent(ic ? 1 : 0.85))
        }
        drawSymbol(g, "chevron.compact.down", in: CGRect(x: r.midX - 40, y: r.minY + 34, width: 80, height: 50), color: .white)
        drawCentered(g, title, font: tf, y: r.minY + 156, color: .white)
        drawCentered(g, body, font: bf, y: r.minY + 222, color: NSColor.white.withAlphaComponent(ic ? 1 : 0.78))
        drawCentered(g, L("touch.tip.dismiss", "点一下收起"), font: Self.rounded(30, weight: .semibold), y: r.maxY - 36,
                     color: NSColor.white.withAlphaComponent(ic ? 0.9 : 0.55))
    }

    /// 除錯疊圖：藍框＝目標本身、淡藍＝外擴到 44 pt 的判定區、橘＝碰了會先展開的
    private func drawTouchDebug(_ g: CGContext) {
        let m = TouchInput.minSide
        g.saveGState()
        for it in ShellAccessibility.items(face: self) where it.focusable && it.rect.width < 1000 {
            let small = (it.id == "avatar" || it.id.hasPrefix("cc.")) && TouchHit.needsExpansion(it.rect, minSide: m)
            let col = small ? NSColor.systemOrange : NSColor.systemBlue
            g.setFillColor(col.withAlphaComponent(0.14).cgColor); g.fill(TouchHit.expanded(it.rect, min: m))
            g.setStrokeColor(col.withAlphaComponent(0.5).cgColor); g.setLineWidth(2); g.stroke(TouchHit.expanded(it.rect, min: m))
            g.setStrokeColor(col.cgColor); g.setLineWidth(3); g.stroke(it.rect)
        }
        g.restoreGState()
    }
}

// MARK: - 自檢

enum TouchSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // 落點分區（拍板 4）
        check(TouchRoute.singleFinger(.screen, live: false) == .shell, "觸控：螢幕上的單指歸外殼")   // l10n-ignore
        check(TouchRoute.singleFinger(.body, live: false) == .rotate, "觸控：機身上的單指＝轉身體")   // l10n-ignore
        check(TouchRoute.singleFinger(.screen, live: true) == .carPlay, "觸控：CarPlay 直播時螢幕上的單指給 iPhone")   // l10n-ignore
        check(TouchRoute.singleFinger(.none, live: false) == .none, "觸控：透明處不歸誰")   // l10n-ignore
        check(!TouchRoute.pinchAccepts(.screen, live: true) && TouchRoute.pinchAccepts(.screen, live: false) && TouchRoute.pinchAccepts(.body, live: true),
              "觸控：捏合整個桌寵都收，只有 CarPlay 螢幕上不收")   // l10n-ignore
        check(TouchRoute.twoFingerPanAccepts(.body) && !TouchRoute.twoFingerPanAccepts(.screen), "觸控：兩指拖只在機身轉身體")   // l10n-ignore
        check(TouchRoute.pressMenuAccepts(.body) && !TouchRoute.pressMenuAccepts(.screen), "觸控：按住選單只在機身，螢幕上是外殼的長按")   // l10n-ignore
        check(!TouchRoute.backSwipeAllowed(touch: true, navigationEnabled: false) && TouchRoute.backSwipeAllowed(touch: false, navigationEnabled: false)
              && TouchRoute.backSwipeAllowed(touch: true, navigationEnabled: true), "觸控：返回滑動看系統設定，滑鼠照舊")   // l10n-ignore

        // 點按區外擴與最近者勝（拍板 1）
        let m = TouchHit.minSide(screenWidthPoints: 256)   // 螢幕 256 pt 寬：44 pt＝176 px
        check(abs(m - 176) < 0.5, "觸控：44 pt 依縮放換成畫布 px")   // l10n-ignore
        let a = CGRect(x: 100, y: 100, width: 60, height: 60), b = CGRect(x: 200, y: 100, width: 60, height: 60)
        check(TouchHit.resolve(CGPoint(x: 130, y: 130), [a, b], minSide: m) == 0, "觸控：點在框裡就是它")   // l10n-ignore
        check(TouchHit.resolve(CGPoint(x: 175, y: 130), [a, b], minSide: m) == 0 && TouchHit.resolve(CGPoint(x: 185, y: 130), [a, b], minSide: m) == 1,
              "觸控：兩個外擴區重疊時中心最近的勝")   // l10n-ignore
        check(TouchHit.resolve(CGPoint(x: 130, y: 50), [a, b], minSide: m) == 0, "觸控：框外但在 44 pt 外擴區裡也算")   // l10n-ignore
        check(TouchHit.resolve(CGPoint(x: 130, y: 400), [a, b], minSide: m) == nil, "觸控：外擴區外不吸")   // l10n-ignore
        let big = CGRect(x: 0, y: 0, width: 400, height: 300), play = CGRect(x: 300, y: 120, width: 50, height: 50)
        check(TouchHit.resolve(CGPoint(x: 260, y: 145), [big, play], minSide: m) == 0, "觸控：點在大卡裡、小鈕外，不被小鈕搶走")   // l10n-ignore
        check(TouchHit.resolve(CGPoint(x: 320, y: 140), [big, play], minSide: m) == 1, "觸控：點在小鈕上歸小鈕")   // l10n-ignore
        check(TouchHit.snap(CGPoint(x: 130, y: 50), into: a) == CGPoint(x: 130, y: 102), "觸控：吸到框內 2 px")   // l10n-ignore
        check(TouchHit.expanded(big, min: m) == big, "觸控：本來就夠大的不外擴")   // l10n-ignore
        check(TouchHit.needsExpansion(CGRect(x: 0, y: 0, width: 60, height: 60), minSide: m) && !TouchHit.needsExpansion(CGRect(x: 0, y: 0, width: 600, height: 60), minSide: m)
              && !TouchHit.needsExpansion(CGRect(x: 0, y: 0, width: 200, height: 200), minSide: m), "觸控：只有又小又近乎方形的要先展開")   // l10n-ignore

        // 觸控橫滑／直滑判定
        var l = TouchScrollLock()
        _ = l.feed(dx: 1, dy: 2)
        check(!l.started, "觸控：沒動過 slop 不算拖")   // l10n-ignore
        let v = l.feed(dx: 1, dy: 6)
        check(l.axis == .vertical && v.dx == 0 && v.dy == 8, "觸控：直拖鎖直向（起手的距離也帶上）")   // l10n-ignore
        check(l.feed(dx: 9, dy: 1) == (dx: 0, dy: 1), "觸控：鎖了直向，橫的分量不走")   // l10n-ignore
        var h = TouchScrollLock()
        _ = h.feed(dx: -8, dy: 1)
        check(h.axis == .horizontal, "觸控：橫拖鎖橫向（換頁）")   // l10n-ignore
        var d = TouchScrollLock()
        _ = d.feed(dx: 5, dy: 5)
        check(d.axis == .free, "觸控：斜拖兩軸都走")   // l10n-ignore
        check(!TouchArbiter.shouldCommit(elapsed: 0.03, moved: 2) && TouchArbiter.shouldCommit(elapsed: 0.08, moved: 0) && TouchArbiter.shouldCommit(elapsed: 0.01, moved: 9),
              "觸控：等 70 ms 或動了才當成按下")   // l10n-ignore

        // 眼神：按下看手指，放開 1 秒後回到平常
        var g = TouchGaze()
        check(g.pointer(now: 0) == nil, "觸控：沒碰時照平常")   // l10n-ignore
        g.press(CGPoint(x: 0.4, y: -0.2))
        check(g.pointer(now: 1) == CGPoint(x: 0.4, y: -0.2), "觸控：按下時看手指")   // l10n-ignore
        g.move(CGPoint(x: -0.3, y: 0.1))
        check(g.pointer(now: 1.2) == CGPoint(x: -0.3, y: 0.1), "觸控：拖著時跟著手指")   // l10n-ignore
        g.release(now: 2)
        check(g.pointer(now: 2.9) == CGPoint(x: -0.3, y: 0.1), "觸控：放開後還看著那裡一下")   // l10n-ignore
        check(g.pointer(now: 3.05) == nil, "觸控：放開 1 秒後回到平常")   // l10n-ignore
        let f = NSRect(x: 100, y: 100, width: 200, height: 300)
        check(TouchGaze.pointer(finger: NSPoint(x: 200, y: 250), window: f) == .zero, "觸控：手指在視窗中間＝看正前方")   // l10n-ignore

        // 捏合不重複觸發
        var arb = TouchArbiter()
        arb.phase = .pending
        check(arb.twoFingerMayBegin, "觸控：單指還沒動時第二根手指可以開始捏合")   // l10n-ignore
        check(!arb.twoFingerBegan() && arb.phase == .ignored, "觸控：捏合一開始，單指那一下作廢（還沒送出就不用收）")   // l10n-ignore
        check(!arb.twoFingerMayBegin, "觸控：捏合進行中不再開始別的兩指手勢")   // l10n-ignore
        arb.phase = .tracking(moved: false)
        check(arb.twoFingerBegan(), "觸控：已經送出按下的要收掉")   // l10n-ignore
        arb.phase = .tracking(moved: true)
        check(!arb.twoFingerMayBegin, "觸控：單指已經在拖時不開始捏合")   // l10n-ignore
        check(TouchArbiter.dropsSystemEvent(synthesizing: false, fingerDown: true, sinceLift: 9)
              && TouchArbiter.dropsSystemEvent(synthesizing: false, fingerDown: false, sinceLift: 0.2)
              && !TouchArbiter.dropsSystemEvent(synthesizing: true, fingerDown: true, sinceLift: 0)
              && !TouchArbiter.dropsSystemEvent(synthesizing: false, fingerDown: false, sinceLift: 2),
              "觸控：系統另外模擬的捏合／滑鼠／滾輪在手指還在時丟掉，滑鼠與觸控板照舊")   // l10n-ignore
        check(TouchArbiter.dropsSystemEvent(synthesizing: false, fingerDown: true, sinceLift: 9, sinceTouch: 1)
              && !TouchArbiter.dropsSystemEvent(synthesizing: false, fingerDown: true, sinceLift: 9, sinceTouch: TouchArbiter.staleTouch + 1),
              "觸控：手指「按著」卻好幾秒沒有觸控更新（結束事件被選單吃掉）就不再當它按著，滑鼠、滾輪、捏合不會一直被丟")   // l10n-ignore
        // 甩動之後系統的慣性捲動：手指按著時開始的那一段，一路丟到慣性結束；新的一段照常
        var sw = TouchScrollSwallow()
        let swallowed = [sw.drops(now: 0, synthesizing: false, systemDrop: true, began: true, phased: true, momentumEnd: false),
                         sw.drops(now: 0.5, synthesizing: false, systemDrop: false, began: false, phased: true, momentumEnd: false),
                         sw.drops(now: 0.9, synthesizing: false, systemDrop: false, began: false, phased: true, momentumEnd: true)]
        let after = sw.drops(now: 1.0, synthesizing: false, systemDrop: false, began: false, phased: true, momentumEnd: false)
        var sw2 = TouchScrollSwallow()
        _ = sw2.drops(now: 0, synthesizing: false, systemDrop: true, began: true, phased: true, momentumEnd: false)
        let fresh = sw2.drops(now: 0.6, synthesizing: false, systemDrop: false, began: true, phased: true, momentumEnd: false)
        var sw3 = TouchScrollSwallow()
        _ = sw3.drops(now: 0, synthesizing: false, systemDrop: true, began: true, phased: true, momentumEnd: false)
        let wheel = sw3.drops(now: 0.6, synthesizing: false, systemDrop: false, began: false, phased: false, momentumEnd: false)
        check(swallowed == [true, true, true] && !after && !fresh && !wheel,
              "觸控：甩動後超過 0.35 秒的系統慣性捲動也丟到結束；觸控板重新起手、滑鼠滾輪照常")   // l10n-ignore
        check(!BodyPoke.atDown(touch: true) && BodyPoke.atDown(touch: false)
              && BodyPoke.atRelease(pending: true, rotating: true, travel: 3) && !BodyPoke.atRelease(pending: true, rotating: true, travel: 30)
              && !BodyPoke.atRelease(pending: false, rotating: true, travel: 0),
              "觸控：機身上戳一下等放手確認是點按才算（捏合第二指晚到不先戳），滑鼠照舊按下就算")   // l10n-ignore

        // 展開：放開後停 1 秒再收；減少動態效果時不放大過場
        TouchExpand.show(CGRect(x: 0, y: 0, width: 50, height: 50), shape: .circle, now: 10)
        check(TouchExpand.state(now: 10.05, reduceMotion: false)!.k < 1 && TouchExpand.state(now: 10.05, reduceMotion: true)!.k == 1, "觸控：展開有過場，減少動態效果時直接到位")   // l10n-ignore
        TouchExpand.release(now: 11)
        check(TouchExpand.state(now: 11.9, reduceMotion: false)?.alpha == 1, "觸控：放開後停一下")   // l10n-ignore
        check(TouchExpand.state(now: 12.3, reduceMotion: false) == nil && TouchExpand.target == nil, "觸控：停約 1 秒後收起")   // l10n-ignore
    }
}
