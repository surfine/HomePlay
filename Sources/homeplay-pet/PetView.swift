// 桌寵主視圖（NSView）：按需 3D、手勢、渲染循環（LoopClock）——自 main.swift 拆出。
import Accelerate
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

final class LoopClock: NSObject {
    private var timer: Timer?
    private var link: CADisplayLink?
    private let tick: () -> Void
    init(view: NSView, hz: Int, tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        if hz >= 60, view.window?.screen != nil {
            let l = view.displayLink(target: self, selector: #selector(fire(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: Float(hz) / 2, maximum: Float(hz), preferred: Float(hz))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / Double(max(1, hz)), repeats: true) { [weak self] _ in self?.tick() }
            // 快節奏也給 1/4 間隔的容忍（沒上螢幕的快照路徑）；慢節奏本來就大
            t.tolerance = hz <= 30 ? min(0.05, 0.25 / Double(max(1, hz))) : 0.25 / Double(hz)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }
    @objc private func fire(_ l: CADisplayLink) { tick() }
    func invalidate() { timer?.invalidate(); timer = nil; link?.invalidate(); link = nil }
}

/// 闲置海报层：盖在 ARView 上的最后一帧；点击/靠近时让位给实时渲染。
/// 海報層：直接把凍結幀的 CGImage 當 layer contents（走 Core Animation 的 GPU 合成與色彩匹配，和 CAMetalLayer 同一條路）。
final class PetView: NSView {
    let model = HomeViewModel()
    let face = Face()
    let mood = Mood(now: CACurrentMediaTime())
    /// --face 指定时锁定这张脸（快照对照用），不跟心情走
    private var lockedFace: Expression?
    let decoder = VideoDecoder()
    /// RealityKit 渲染视图。事件全部由外层 PetView 处理，ARView 不接触鼠标。
    let render = ARView(frame: .zero)
    private var cameraEntity: Entity!
    private var bodyAnchor: AnchorEntity!
    private var backLight: DirectionalLight!
    private var roomKey: DirectionalLight!
    private var roomEnv: RoomEnvironment?
    /// 房间光线开关（AppDelegate 设；摄像头暂停条件要用）
    var roomLightEnabled = false
    private(set) var showingVideo = false
    /// CarPlay 影片（停車時播影片）：播著的時候螢幕給它，CarPlay 畫面讓位（CarVideo.swift）
    let carVideo = CarVideoPlayer()
    var onTouch: ((Double, Double, Bool) -> Void)?
    var onToggleLive: (() -> Void)?
    /// 只換顯示源（HomeView ⇄ CarPlay），不拆會話：空格、Esc、重按都走這條
    var onSwitchSource: (() -> Void)?
    var onCarPlayBack: (() -> Void)?   // beta 5（拍板，對齊 1.0.6）：CarPlay 畫面 Esc＝車機返回
    var onCancelConnect: (() -> Void)?   // 菜单「取消连线」
    /// 重按（Force Touch）＝进入 CarPlay；AppDelegate 负责拉起 receiver 并连接
    var onForceEnter: (() -> Void)?
    /// 右键「使用 iPhone」/「配对新 iPhone…」：AppDelegate 负责保存并通知 receiver
    var onSelectPhone: ((String) -> Void)?
    var onPairNewPhone: (() -> Void)?
    var onSetWiFi: ((String, String) -> Void)?
    var onForgetPhone: ((String) -> Void)?
    var onRestorePhones: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?   // 右鍵 › iPhone › 拷貝診斷報告：AppDelegate 向接收器要現場
    var onVideoState: ((Bool) -> Void)?   // 直播开始/结束：AppDelegate 据此启停健康检查与统计
    private var forceStage = 0

    // 稿里的弹簧：拆开 k=16，镜头 k=42，都是临界阻尼
    private var apartTarget: CGFloat = 0, apartT: CGFloat = 0, apartV: CGFloat = 0
    private var yaw: CGFloat = 0.52, pitch: CGFloat = 0.26, vy: CGFloat = 0, vp: CGFloat = 0
    private var ty: CGFloat = 0.52, tp: CGFloat = 0.26
    private var lastStep = CACurrentMediaTime()
    private(set) var stepFrames = 0
    func resetStepCount() { stepFrames = 0 }
    // lastNear 在 init 里设成「刚开始」；见 targetHz 的远距省电
    private var timer: LoopClock?
    /// 闲置 90 秒后把 ARView 换成静态海报：RealityKit 的每帧固定开销是待机最大单项。
    /// 海报每 2 秒重新拍一张，时间/眨眼不会完全停；鼠标靠近或任何点击立刻恢复实时渲染。
    private let poster = PosterImageView()
    private var posterActive = false
    private var posterTimer: Timer?

    // MARK: 按需 3D（ARView 只在畫面會變的那幾幀掛在視窗裡）
    /// Darwin 27 實測（docs/performance.md「按需 3D」）：`__preferredFrameRate`、`isHidden`、甚至從未掛進層級的
    /// ARView 都照樣每秒 60 次場景更新（約 18% CPU）；只有「掛進視窗後 removeFromSuperview」會讓它歸零，
    /// 而卸下期間 `snapshot` 不會完成，所以沒有真正的「按需出一幀」。做法：場景一變就掛回去（海報蓋著，
    /// 等第 3 次 SceneEvents.Update 確定第一幀已上屏才收掉），靜止超過 stillDelay 就把上屏那幀凍結成海報、卸下。
    /// HOMEPLAY_RENDER_MODE=always 退回常駐渲染（量測對照用）。
    private let onDemand3D = ProcessInfo.processInfo.environment["HOMEPLAY_RENDER_MODE"] != "always"
    private var attached3D = true
    private var updates3D = 0                 // 這次掛上後收到的 SceneEvents.Update 次數
    private(set) var frames3D = 0             // 統計：RealityKit 實際出的幀（bench 用）
    private(set) var cycles3D = 0             // 統計：卸下次數（bench 用）
    private var lastSceneChange = CACurrentMediaTime()
    private var detachShotAt: Double?         // 正在為卸下等凍結幀（開始時間）；中途場景再變就取消
    private var pendingSnapshots: [(CGImage?) -> Void] = []   // 卸下期間要求的快照，掛回去出幀後再拍
    private var snapshotsInFlight = 0
    /// 海報補丁：卸下時記下凍結幀、當時的錶面與螢幕四角；之後只有錶面變（眨眼、瞄一眼、換分鐘）就把
    /// 「新錶面 − 舊錶面」透視投影到螢幕四邊形、加回海報，不必為一次眨眼把 RealityKit 掛回來（一次約 30–40 ms）。
    /// 螢幕是 UnlitMaterial、沒有色調映射，蓋板玻璃的反光是加上去的，所以「加差值」和真的重繪幾乎一樣。
    private var frozenPatch: (poster: CIImage, posterCG: CGImage?, face: CIImage, corners: [CGPoint], scale: CGFloat, cs: CGColorSpace)?
    private var renderedScreenGeneration = -1
    private(set) var patches3D = 0
    /// 凍結時錶面的 48×48 縮圖：補丁前先量「新錶面變了多大一塊」
    private var frozenThumb: [UInt8]?
    /// 補丁只適合小範圍的變化（眨眼、瞄一眼）。差值法的前提是「舊錶面的透視投影＝RealityKit 當時畫上去的樣子」，
    /// 但兩者在取樣與邊緣上總差一兩個像素：變化小時殘差只落在變的那一小塊、看不出來；整面都變（連線過場、
    /// 換錶面、大數字換分鐘）時，舊錶面每一道邊的殘差會同時浮出來＝殘影。超過這個比例就掛回 3D 重畫。
    static let patchMaxChange = 0.04
    static func faceThumb(_ img: CGImage) -> [UInt8] {
        let n = 48
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        return buf
    }
    /// 兩張縮圖有多少比例的像素明顯不同（任一色版差 > 20/255），以及有沒有變化落在 allowed（1024 畫布）之外
    static func changedFraction(_ a: [UInt8], _ b: [UInt8], allowed: CGRect? = nil) -> (fraction: Double, outside: Bool) {
        guard a.count == b.count, !a.isEmpty else { return (1, true) }
        let n = 48, k = CGFloat(n) / 1024
        let box = allowed.map { CGRect(x: $0.minX * k, y: $0.minY * k, width: $0.width * k, height: $0.height * k).insetBy(dx: -1, dy: -1) }
        var changed = 0, outside = false
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
            guard d > 20 else { continue }
            changed += 1
            let px = (i / 4) % n, py = (i / 4) / n
            if !(box?.contains(CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)) ?? false) { outside = true }
        }
        return (Double(changed) / Double(a.count / 4), outside)
    }
    var debugDetached: Bool { !attached3D && !poster.isHidden }
    /// 海報補丁專用的 Core Image context（跟錶面的分開，補完就清快取）
    /// 補丁＝「有變化的那一小塊直接換成新內容」，不是 p + n − o：
    /// 3D 畫出來的螢幕和平面錶面的投影銳利度、明暗都不完全一樣，加減法會讓舊內容的每道邊留下一圈殘差（殘影）。
    /// 做法：|n − o| 超過門檻的像素＝變化區，往外擴 3 px 再羽化成遮罩 M；在變化區周圍沒變的像素上，
    /// 逐色版用最小平方擬合 p ≈ a·o + b（螢幕的明暗、反光近似成仿射），變化區填 a·n + b。舊內容在 M 裡完全不出現。
    /// 擬合用的乾淨像素不夠（整塊都在變）就回 nil，交給 3D 重畫。
    static func replacePatch(p: [Float], n: [Float], o: [Float], w: Int, h: Int) -> [Float]? {
        let count = w * h
        var changed = [Float](repeating: 0, count: count)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for i in 0..<count where o[i * 4 + 3] > 0.99 && n[i * 4 + 3] > 0.99 {
            let d = max(abs(n[i * 4] - o[i * 4]), abs(n[i * 4 + 1] - o[i * 4 + 1]), abs(n[i * 4 + 2] - o[i * 4 + 2]))
            if d > 0.012 { changed[i] = 1; let x = i % w, y = i / w; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
        guard maxX >= 0 else { return p }   // 沒有變化
        // 擴張（可分離的方框最大值）再羽化（方框平均），各自兩趟
        func boxPass(_ src: [Float], radius r: Int, horizontal: Bool, maxOp: Bool) -> [Float] {
            var dst = src
            for y in 0..<h { for x in 0..<w {
                var acc: Float = 0, k: Float = 0
                for t in -r...r {
                    let xx = horizontal ? x + t : x, yy = horizontal ? y : y + t
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let v = src[yy * w + xx]
                    if maxOp { acc = max(acc, v) } else { acc += v; k += 1 }
                }
                dst[y * w + x] = maxOp ? acc : acc / max(1, k)
            } }
            return dst
        }
        var m = boxPass(boxPass(changed, radius: 3, horizontal: true, maxOp: true), radius: 3, horizontal: false, maxOp: true)
        m = boxPass(boxPass(m, radius: 2, horizontal: true, maxOp: false), radius: 2, horizontal: false, maxOp: false)
        // 擬合範圍：變化區外擴 28 px 的方框裡、遮罩為 0、在螢幕內的像素
        let pad = 28
        let x0 = max(0, minX - pad), x1 = min(w - 1, maxX + pad), y0 = max(0, minY - pad), y1 = min(h - 1, maxY + pad)
        var a = [Float](repeating: 1, count: 3), b = [Float](repeating: 0, count: 3)
        for c in 0..<3 {
            var so: Double = 0, sp: Double = 0, soo: Double = 0, sop: Double = 0, k: Double = 0
            for y in y0...y1 { for x in x0...x1 {
                let i = y * w + x
                guard m[i] == 0, o[i * 4 + 3] > 0.99 else { continue }
                let ov = Double(o[i * 4 + c]), pv = Double(p[i * 4 + c])
                so += ov; sp += pv; soo += ov * ov; sop += ov * pv; k += 1
            } }
            guard k > 200 else { return nil }
            let den = k * soo - so * so
            let ac = abs(den) < 1e-9 ? 1 : (k * sop - so * sp) / den
            a[c] = Float(ac); b[c] = Float((sp - ac * so) / k)
        }
        var out = p
        for i in 0..<count where m[i] > 0 {
            for c in 0..<3 {
                let v = a[c] * n[i * 4 + c] + b[c]
                out[i * 4 + c] = min(1, max(0, p[i * 4 + c] * (1 - m[i]) + v * m[i]))
            }
        }
        return out
    }
    private static let patchCI = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh])
    private let posterPatching = ProcessInfo.processInfo.environment["HOMEPLAY_POSTER_PATCH"] != "0"
    private var updateSub: (any Cancellable)?
    private var renderedGeneration = -1
    private var renderedPose = ScenePose()
    private var bob: CGFloat = 0              // 4.5 秒一次的輕微浮動（世界座標 y）
    private var posterBob: CGFloat = 0        // 凍結幀那一刻的浮動值；卸下期間浮動改成海報層位移
    private var sceneDirty = false
    private var changeGaps: (last: Double, prev: Double) = (1, 1)   // 最近兩次場景變化的間隔
    private var lastDirtyAt: Double = -1                             // 上一次 syncRenderer 判定有變化的時刻
    private let renderLog = ProcessInfo.processInfo.environment["HOMEPLAY_RENDER_LOG"] != nil
    /// 靜止多久才卸下。一次卸下＋掛回約 30–40 ms CPU（掛回後至少 3 幀、靜止等待那幾幀、凍結幀讀回），
    /// 常駐則是每秒約 200 ms，所以空檔超過 0.2 s 就值得卸：眨眼（0.13 s）結束後 0.12 s 卸下。
    /// 連續兩次變化間隔都短於 0.35 s（Flow 錶面 4 Hz 壁紙、眼睛平滑過場）＝持續的小變化，
    /// 反覆掛卸只會比常駐更貴，這時等 0.4 s 再卸，讓它留在線上直到變化真的停下。
    /// 游標還停在桌寵上就再撐 2 s：手勢多半接著來，反覆掛卸正是「有點卡」的來源。
    private var stillDelay: Double {
        if CACurrentMediaTime() - pointerInsideAt < 0.5 { return 2 }
        return changeGaps.last < 0.35 && changeGaps.prev < 0.35 ? 0.4 : 0.12
    }
    private var pointerInsideAt: Double = -10
    /// 送去渲染的姿態；差異小於約 0.1 px 就不算變化（彈簧落定後的無限小位移不值得出幀）。
    /// 全用 Double 比：Float 四元數的點積在 1e-7 以下沒有解析度，拿它判「沒變」會一直誤報。
    private struct ScenePose {
        var yaw = Double.nan, pitch = 0.0, rigPitch = 0.0, rigYaw = 0.0, apart = 0.0, press = 0.0, aim = 0.0
        func differs(from o: ScenePose) -> Bool {
            if yaw.isNaN || o.yaw.isNaN { return true }
            return abs(yaw - o.yaw) > 4e-4 || abs(pitch - o.pitch) > 4e-4          // 機身半徑約 8 單位：約 0.1 px
                || abs(rigPitch - o.rigPitch) > 4e-4 || abs(rigYaw - o.rigYaw) > 4e-4
                || abs(apart - o.apart) > 1e-4 || abs(press - o.press) > 5e-5
                || abs(aim - o.aim) > 4e-4                                              // 整机朝向（Aim）
        }
    }
    private let posterIdle = ProcessInfo.processInfo.environment["HOMEPLAY_POSTER_AFTER"].flatMap(Double.init) ?? 90
    /// 診斷用：HOMEPLAY_IDLE_HZ 可改閒置幀率（能效量測）。每幀都去讀一次環境字典太浪費，啟動時讀一次。
    private let idleHzOverride = ProcessInfo.processInfo.environment["HOMEPLAY_IDLE_HZ"].flatMap { Int($0) }
    /// 診斷用：HOMEPLAY_BATTERY=1 假裝在用電池（量「電池自動降幀」；接電源量測時用）
    private let onBatteryOverride = ProcessInfo.processInfo.environment["HOMEPLAY_BATTERY"].flatMap { $0 == "1" ? true : nil }
    /// 每幀都會用到的「慢狀態」（整點小時、系統減弱動態）每秒才更新一次。
    private var slowStateAt: Double = -1
    private var cachedHour = 12
    private var cachedReduceMotion = false

    private weak var liveTimerItem: NSMenuItem?   // 打开的菜单里的「计时器」父项
    private var menuTicker: Timer?                // 菜单打开期间逐秒刷新倒计时
    private var gazePitchValueLabel: NSTextField? // 俯仰角度弹窗里的数值
    private enum Drag { case none, rotate, resize, touch, move }
    private var drag: Drag = .none
    private var threeFinger: [CGPoint]?   // 三指拖移的上一帧归一化位置
    private var limitHaptic: CGFloat?      // 缩放碰界时只震一次
    private var last = NSPoint.zero
    private var winStart = NSRect.zero
    private var mouseStart = NSPoint.zero

    init(frame: NSRect, initialApart: Bool = false, yaw y0: CGFloat? = nil, pitch p0: CGFloat? = nil) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        allowedTouchTypes = [.indirect]    // 三指拖移窗口要收到触控板触摸
        // 輔助功能：VoiceOver 至少知道這是什麼、能做什麼
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("a11y.pet", "HomePlay 桌宠"))
        setAccessibilityHelp(L("a11y.help", "重按屏幕进入 CarPlay，右键打开菜单"))

        render.frame = bounds
        render.autoresizingMask = [.width, .height]
        render.environment.background = .color(.clear)
        if let studio = QuickLookIBL.studio {
            render.environment.lighting.resource = studio
            log("Quick Look object-mode IBL loaded")
        }
        if ProductShot.on { render.environment.lighting.intensityExponent = ProductShot.iblExponent }   // 2.0 device: 官圖的高調棚拍
        render.__enableAutomaticFrameRate = false
        render.__preferredFrameRate = 60
        // 这不是 AR 场景：走 RealityKit 的非 ARKit 设备路径，别让 ARView 维持 ARKit 的
        // 相机/合成相关固定开销。桌面小窗用不到相机背景合成。
        render.__nonARKitDevices = true
        render.__disableComposition = true
        addSubview(render)
        // 每一幀 RealityKit 都會發 Update（主執行緒）：拿它數幀、判斷「第一幀已上屏」與「靜止夠久可以卸下」。
        updateSub = render.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.sceneDidUpdate() }

        poster.frame = bounds
        poster.autoresizingMask = [.width, .height]
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.clear.cgColor
        poster.isHidden = true
        poster.setAccessibilityElement(false)
        addSubview(poster, positioned: .above, relativeTo: render)
        if onDemand3D { installFreeze() }
        // 拆開看看的零件標籤：蓋在 3D、海報之上，不接滑鼠
        callout.frame = bounds
        callout.autoresizingMask = [.width, .height]
        callout.isHidden = true
        callout.setAccessibilityElement(false)
        addSubview(callout, positioned: .above, relativeTo: nil)

        // RealityKit 场景：USDZ 原样放进来，相机由 __defaultCamera 控制（24° 长焦）。
        bodyAnchor = AnchorEntity(world: .zero)
        bodyAnchor.addChild(model.holder)
        render.scene.addAnchor(bodyAnchor)
        setFinish(Finish(rawValue: UserDefaults.standard.string(forKey: Finish.defaultsKey) ?? "") ?? .starlight)
        if model.finish == .g4 { face.beginHello(CACurrentMediaTime()) }   // G4 白：开机先写一个 hello（2.0：Hello/HelloScene.swift）
        let savedStyle = FaceStyle(rawValue: UserDefaults.standard.string(forKey: FaceStyle.defaultsKey) ?? "") ?? .island
        face.style = savedStyle.inLineup
        face.restoreFaceOptions(migrating: savedStyle)   // Typograph 材質／System 6 版式（舊的浮雕、Alarm Clock、About 在這裡搬進來）
        face.restoreIslandOptions()   // 島錶面：时钟样式 / 背景 / 年代
        CompanionLog.markToday()   // 陪伴的痕跡：今天打开过
        // 电量每分钟读一次（IOKit，读不到＝没有电池）
        face.battery = Battery.read()
        batteryTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.face.battery = Battery.read() }
        batteryTimer?.tolerance = 10
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.face.resyncTimer(); self?.face.battery = Battery.read()
        }
        // 螢幕休眠＝沒人看：連定時器和 3D 渲染一起停，醒來再照視窗實際可見性恢復
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setOccluded(true)
            NowPlayingPoller.shared.paused = true
            // 屏幕睡了就关摄像头：不给「人不在电脑前」留一个亮着的绿点。
            if self?.gazeEnabled == true || self?.roomLightEnabled == true { GazeTracker.shared.setPaused(true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let visible = self.window?.occlusionState.contains(.visible) ?? true
            self.setOccluded(!visible)
            NowPlayingPoller.shared.paused = !visible
            if (self.gazeEnabled || self.roomLightEnabled), !self.occluded, !self.screenLocked {
                GazeTracker.shared.setPaused(false)
            }
        }
        // 锁屏/解锁：显示器不一定马上睡，单独收系统通知（这两个名字是 AppKit 之外的通知，长期稳定）。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screenLocked = true
            guard self.gazeEnabled || self.roomLightEnabled else { return }
            GazeTracker.shared.setPaused(true)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screenLocked = false
            guard self.gazeEnabled || self.roomLightEnabled, !self.occluded else { return }
            GazeTracker.shared.setPaused(false)
        }
        RunLoop.main.add(batteryTimer!, forMode: .common)
        if NowPlayingPoller.enabled { NowPlayingPoller.shared.start(face: face) }   // 只在 Music/Spotify 已在跑时才问
        CalendarSource.shared.start(face: face)   // 已授权才读，没授权只更新状态
        if !CommandLine.arguments.contains("--screen-png"), !CommandLine.arguments.contains("--snapshot") { HomeDoorbell.shared.start() }   // 2.0 第四輪：門鈴接管（有裝家庭小幫手才連）
        if !CommandLine.arguments.contains("--screen-png"), !CommandLine.arguments.contains("--snapshot") { PhoneHandoff.start() }   // 2.0 promo：從 iPhone 傳網頁（設定裡開）
        // 计时器到点：岛吓一跳、甩头，横幅从上面出来；之后笑一下
        face.onTimerDone = { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.mood.activity(now: now, hour: Calendar.current.component(.hour, from: Date()))
            if self.pomodoroAdvance(now) { return }
            self.mood.show(.surprised, for: 0.8, now: now); self.shake(now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.mood.show(.happy, for: 1.2, now: CACurrentMediaTime()) }
            log("timer done")
        }
        // 相机：用 RealityKit 默认相机，但改成产品摄影的 24° 长焦，位置在 step() 里绕机身转。
        cameraEntity = render.scene.__defaultCamera
        if let cameraEntity {
            var pc = cameraEntity.components[PerspectiveCameraComponent.self] ?? PerspectiveCameraComponent()
            pc.fieldOfViewInDegrees = 24
            pc.near = 1
            pc.far = 600
            if ProductShot.on { pc.fieldOfViewInDegrees = ProductShot.fov; pc.near = 50; pc.far = 5000 }   // 2.0 device: 官圖機位（ProductShot.swift）
            cameraEntity.components.set(pc)
        } else {
            log("RealityKit 默认相机不可用")
        }

        // 默认 IBL 就是 Quick Look 的棚拍环境（高调暖白、大面积柔光），不再自己造环境。
        // 只补一盏背后的柔光，让侧面/屏幕背板也像官图一样被托亮。
        let fill = DirectionalLight()
        fill.light.intensity = 2000
        fill.light.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        fill.look(at: SIMD3<Float>(0, 9, 2), from: SIMD3<Float>(0, 30, -100), relativeTo: nil)
        bodyAnchor.addChild(fill)
        backLight = fill

        // 房间主光：方向/颜色/强度由摄像头估计（RoomLightEstimator）驱动；没开灯时强度 0。
        let key = DirectionalLight()
        key.light.intensity = 0
        key.light.color = NSColor(calibratedRed: 1, green: 0.97, blue: 0.92, alpha: 1)
        key.look(at: SIMD3<Float>(0, 9, 0), from: SIMD3<Float>(0, 30, 120), relativeTo: nil)
        bodyAnchor.addChild(key)
        roomKey = key
        roomEnv = RoomEnvironment()
        roomEnv?.onEnvironment = { [weak self] env in
            self?.render.environment.lighting.resource = env
            self?.requestFrame()
        }

        model.setScreen(face.render())
        face.onHour = { [weak self] in self?.mood.show(.wink, for: 0.6, now: CACurrentMediaTime()) }
        // 每 0.25 s 看一次游标：靠近、摸头、好奇时眼珠的方向。用轮询，不要辅助功能权限。
        // 热状态／低电量（省电模式）改听系统通知，不再每 5 秒醒来问一次
        envObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermal = ProcessInfo.processInfo.thermalState
        }
        envObserver2 = NotificationCenter.default.addObserver(forName: Notification.Name("NSProcessInfoPowerStateDidChange"), object: nil, queue: .main) { [weak self] _ in
            self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        startHoverTimer()
        decoder.onImage = { [weak self] img in
            guard let self, self.showingVideo, !self.carVideo.active else { return }
            self.model.setScreen(img)
            self.videoFrameArrived()
        }
        // 零拷貝路（方畫面）：MTLTexture 直接當材質，不經任何像素轉換
        decoder.onTexture = { [weak self] tex, _, _ in
            guard let self, self.showingVideo, !self.carVideo.active else { return }
            self.model.setScreen(texture: CornerFit.shared.apply(tex))   // 學圓角那一次連線才會縮放補黑，平常原樣
            self.videoFrameArrived()
        }
        carVideo.onTexture = { [weak self] tex in
            guard let self else { return }
            self.model.setScreen(texture: tex)
            self.videoFrameArrived()
        }
        if let y0 { yaw = y0; ty = y0 }
        if let p0 { pitch = p0; tp = p0 }
        if viewMode == .wall { model.setWall(true); yaw = 0; ty = 0; pitch = 0; tp = 0 }
        if initialApart { apartTarget = 1; apartT = 1; if y0 == nil { yaw = Self.apartYaw; ty = yaw } }
        // 驗證用：HOMEPLAY_CAR_VIDEO=<網址> 不接 iPhone 直接走 CarPlay 影片播放器（同一條貼圖路徑、控制列）
        if let u = ProcessInfo.processInfo.environment["HOMEPLAY_CAR_VIDEO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.showVideo(true)
                self.carVideo.handle(["op": "play", "url": u, "startMs": 0, "uuid": "test"])
                self.carVideo.handle(["op": "rate", "rate": 1])
            }
        }
        // 量測用：HOMEPLAY_FAKE_LIVE=<fps> 不接 iPhone 也能進直播路徑，餵 1088² 的合成畫面（0＝只餵一張＝直播靜止）。
        if let fps = ProcessInfo.processInfo.environment["HOMEPLAY_FAKE_LIVE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                var n = 0
                func frame() -> CGImage {
                    n += 1
                    return makeImage(1088, 1088) { g in
                        g.setFillColor(NSColor(calibratedRed: 0.08, green: 0.1, blue: 0.14, alpha: 1).cgColor)
                        g.fill(CGRect(x: 0, y: 0, width: 1088, height: 1088))
                        g.setFillColor(NSColor.systemOrange.cgColor)
                        g.fill(CGRect(x: 80 + (n * 7) % 900, y: 480, width: 120, height: 120))
                    }
                }
                self.showVideo(true)
                self.model.setScreen(frame()); self.videoFrameArrived()
                if fps > 0 {
                    let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.model.setScreen(frame()); self?.videoFrameArrived() }
                    RunLoop.main.add(t, forMode: .common)
                }
                log("fake live \(fps) fps")
            }
        }
        // step() 里的 setLoopHz 会按当下需要的帧率建好定时器；只兜底一次，别再建第二个。
        loopHz = 0
        step()
        if timer == nil {
            timer = LoopClock(view: self, hz: 60) { [weak self] in self?.step() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 窗口缩放后 ARView 始终铺满内容区（RealityKit 的相机投影按 bounds 算）。
    override func layout() {
        super.layout()
        if render.frame != bounds { render.frame = bounds; requestFrame(); updateFaceScale() }
    }
    /// 換到不同解析度的螢幕（Retina ↔ 外接 1x）：貼圖跟著重算
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateFaceScale()
    }

    // 每帧：弹簧、镜头、脸
    /// 窗口被完全遮住（全屏 App、别的桌面）时停渲染；快照不停
    private(set) var occluded = false
    /// 除錯：印出當下姿態（yaw/pitch/look/rig）
    func logPose() {
        log(String(format: "pose yaw=%.3f ty=%.3f pitch=%.3f tp=%.3f lookX=%.3f lookY=%.3f",
                   yaw, ty, pitch, tp, lookX, lookY))
        if let c = cameraEntity {
            let p = c.position(relativeTo: nil)
            log(String(format: "pose cam pos=(%.1f,%.1f,%.1f) rot=(%.3f,%.3f,%.3f,%.3f)",
                       p.x, p.y, p.z, c.orientation.vector.x, c.orientation.vector.y,
                       c.orientation.vector.z, c.orientation.vector.w))
        }
    }

    /// 臉部貼圖只用「畫到螢幕上實際需要的像素」：省 CPU 光柵與每幀紋理上傳
    func updateFaceScale() {
        if CommandLine.arguments.contains("--screen-png") {   // 10-grid：--screen-png 永遠出 1024²（網格合約的畫布，別讓視窗大小決定）
            if face.renderScale != 1 { face.renderScale = 1; face.forceDirty = true }
            return
        }
        // 螢幕佔視窗寬約 0.71（USDZ 量的）：貼圖像素要 ≥ 螢幕上實際像素，否則放大後發糊；上限 2048
        let need = bounds.width * (window?.backingScaleFactor ?? 2) * 0.72
        Typo.pointsPerUnit = max(80, bounds.width) * 0.72 / 1024   // 字體的光學尺寸與字距照螢幕上的實際大小（Typography.swift）
        let sc = max(0.25, min(2, need / 1024))
        if abs(sc - face.renderScale) > 0.02 { face.renderScale = sc; face.forceDirty = true }
    }

    /// RealityKit 快照（透明底）。ARView 与 PetView 同尺寸，直接取整张。
    func captureSnapshot(_ completion: @escaping (CGImage?) -> Void) {
        // 卸下期間 snapshot 不會完成：先掛回去、跑一拍把待處理的臉／姿態套上，出過幀再拍。
        if !attached3D || updates3D < 3 {
            pendingSnapshots.append(completion)
            if !attached3D { step(); attach3D() }
            return
        }
        snapshotsInFlight += 1   // 拍到一半不能卸下：卸下期間 snapshot 永遠不會完成
        render.snapshot(saveToHDR: false) { [weak self] img in
            self?.snapshotsInFlight -= 1
            guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                completion(nil); return
            }
            completion(cg)
        }
    }

    /// 場景有看得見的變化（光、環境貼圖、視窗尺寸）：下一拍一定要出幀。貼圖／材質走 model.generation。
    func requestFrame() {
        sceneDirty = true
        if onDemand3D, !attached3D, !occluded { attach3D() }
    }

    /// 直播進了一幀：不等主循環那拍，立刻掛回去出幀；主循環若已降到靜止的 12 Hz 也馬上回 60。
    private var lastVideoFrame: Double = -1
    private func videoFrameArrived() {
        lastVideoFrame = CACurrentMediaTime()
        requestFrame()
        if loopHz != 0, loopHz < 30, !posterActive { step() }
    }

    /// 把 ARView 掛回視窗：RealityKit 從這一刻起每秒 60 幀；海報留著蓋到第 3 次 Update。
    private func attach3D() {
        guard !attached3D else { return }
        attached3D = true
        frozenPatch = nil
        updates3D = 0
        detachShotAt = nil
        lastSceneChange = CACurrentMediaTime()
        if render.superview == nil {
            addSubview(render, positioned: .below, relativeTo: poster)
            render.frame = bounds
            render.autoresizingMask = [.width, .height]
        }
        render.isHidden = false
        if renderLog {
            log(String(format: "3d: attach t=%.3f", CACurrentMediaTime()))
            if let l = render.layer {
                var desc = "layer \(type(of: l)) sublayers=\((l.sublayers ?? []).map { String(describing: type(of: $0)) })"
                for m in ([l] + (l.sublayers ?? [])).compactMap({ $0 as? CAMetalLayer }) {
                    desc += String(format: " metal fmt=%d cs=%@ edr=%d scale=%.2f", m.pixelFormat.rawValue, m.colorspace.map { "\($0)" } ?? "nil", m.wantsExtendedDynamicRangeContent ? 1 : 0, m.contentsScale)
                }
                log(desc)
            }
        }
    }

    // 凍結幀：`snapshot()` 是另一條離線渲染，和上屏那幀在貼圖取樣與輪廓有 1–30 階差（切換會微閃）；
    // 改在 renderCallbacks.postProcess 裡把 sourceColorTexture（就是要上屏的那幀）blit 一份出來，
    // 命令完成後讀回主執行緒當海報：逐位相同，且不用多渲染一幀。
    private var freezeTex: MTLTexture?
    private let freezeLock = NSLock()
    private var freezeRequest = false        // 主執行緒設、渲染執行緒取
    private var freezeSerial = 0
    private func installFreeze() {
        render.renderCallbacks.postProcess = { [weak self] ctx in
            guard let self, let blit = ctx.commandBuffer.makeBlitCommandEncoder() else { return }
            let src = ctx.sourceColorTexture
            blit.copy(from: src, to: ctx.targetColorTexture)
            self.freezeLock.lock(); let want = self.freezeRequest; self.freezeRequest = false; self.freezeLock.unlock()
            guard want else { blit.endEncoding(); return }
            if let f = self.freezeTex, f.width == src.width, f.height == src.height, f.pixelFormat == src.pixelFormat {
            } else {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: src.width, height: src.height, mipmapped: false)
                d.usage = [.shaderRead]; d.storageMode = .shared
                self.freezeTex = ctx.device.makeTexture(descriptor: d)
            }
            guard let f = self.freezeTex else { blit.endEncoding(); return }
            blit.copy(from: src, to: f)
            blit.endEncoding()
            let serial = self.freezeSerial
            ctx.commandBuffer.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async { self?.freezeCompleted(serial) }
            }
        }
    }

    /// 凍結幀讀回：BGRA 預乘、和 CAMetalLayer 同一個色彩空間，CA 合成時走同樣的匹配。
    private func freezeImage() -> CGImage? {
        guard let f = freezeTex, f.pixelFormat == .bgra8Unorm_srgb || f.pixelFormat == .bgra8Unorm else { return nil }
        let w = f.width, h = f.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        f.getBytes(&buf, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = (render.layer as? CAMetalLayer)?.colorspace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bi = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: bi) else { return nil }
        return ctx.makeImage()
    }

    /// 卸下 ARView：先要一幀凍結幀，拿到後確認中途沒再變才真的移出層級。snapshot=false（被遮住）直接卸。
    private func detach3D(snapshot: Bool = true) {
        guard attached3D, detachShotAt == nil else { return }
        if !snapshot {
            attached3D = false
            render.removeFromSuperview()
            cycles3D += 1
            return
        }
        let at = CACurrentMediaTime()
        detachShotAt = at
        freezeSerial += 1
        freezeLock.lock(); freezeRequest = true; freezeLock.unlock()
    }

    private func freezeCompleted(_ serial: Int) {
        guard serial == freezeSerial, let at = detachShotAt else { return }   // 中途取消過
        detachShotAt = nil
        guard attached3D, lastSceneChange <= at, pendingSnapshots.isEmpty, snapshotsInFlight == 0, !occluded, !sceneDirty,
              let cg = freezeImage() else { return }
        poster.show(cg, scale: window?.backingScaleFactor ?? 2)
        if posterPatching, let face = model.lastScreenImage, screenFacingCamera() {
            let c = screenCorners()
            frozenPatch = c.count == 4 ? (CIImage(cgImage: cg), cg, CIImage(cgImage: face), c, window?.backingScaleFactor ?? 2,
                                          cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) : nil
            frozenThumb = frozenPatch == nil ? nil : Self.faceThumb(face)
        } else { frozenPatch = nil; frozenThumb = nil }
        posterBob = bob
        poster.frame = bounds
        poster.isHidden = false
        render.removeFromSuperview()      // 與顯示海報同一個 transaction：畫面不閃
        attached3D = false
        cycles3D += 1
        if renderLog { log(String(format: "3d: detach after %d frames (gaps %.3f/%.3f gen %d) t=%.3f", updates3D, changeGaps.last, changeGaps.prev, model.generation, CACurrentMediaTime())) }
    }

    /// RealityKit 每幀回呼（主執行緒）。
    private func sceneDidUpdate() {
        frames3D += 1
        guard attached3D else { return }
        updates3D += 1
        if updates3D == 3 {
            // 第 1 次 Update 的那幀在下一個 vsync 才上屏；到第 3 次才能確定 ARView 已經有畫面，再把海報收掉。
            if !poster.isHidden { poster.isHidden = true; poster.clear() }
            if !pendingSnapshots.isEmpty {
                let waiting = pendingSnapshots; pendingSnapshots = []
                for c in waiting { captureSnapshot(c) }
            }
        }
        guard onDemand3D, updates3D >= 3, pendingSnapshots.isEmpty, snapshotsInFlight == 0, !sceneDirty else { return }
        let now = CACurrentMediaTime()
        if let at = detachShotAt, now - at > 1 { detachShotAt = nil }   // 凍結幀沒回來（不該發生）：放棄這次，下一幀再試
        if now - lastSceneChange > stillDelay { detach3D() }
    }

    /// 每拍結束：姿態／貼圖有沒有變；卸下期間把浮動換成海報層的整像素位移。
    private func syncRenderer(_ now: Double) {
        guard onDemand3D else { return }
        let pose = ScenePose(yaw: Double(yaw), pitch: Double(pitch), rigPitch: Double(rigPitch), rigYaw: Double(rigYaw),
                             apart: Double(apartT), press: Double(press),
                             aim: model.aimYaw.isNaN ? 0 : Double(model.aimYaw))
        // 只有錶面貼圖變了、機身沒動、而且 3D 已卸下：補海報就好
        if !sceneDirty, !attached3D, model.generation != renderedGeneration, !pose.differs(from: renderedPose),
           model.generation - renderedGeneration == model.screenGeneration - renderedScreenGeneration, patchPoster() {
            renderedGeneration = model.generation
            renderedScreenGeneration = model.screenGeneration
        }
        if model.generation != renderedGeneration || pose.differs(from: renderedPose) { sceneDirty = true }
        if sceneDirty {
            sceneDirty = false
            renderedGeneration = model.generation
            renderedScreenGeneration = model.screenGeneration
            renderedPose = pose
            if lastDirtyAt > 0 { changeGaps = (now - lastDirtyAt, changeGaps.last) }
            lastDirtyAt = now
            lastSceneChange = now
            detachShotAt = nil          // 等凍結幀途中又變了：那張不用了
            if !occluded { attach3D() }
        } else if !attached3D, !poster.isHidden {
            // 浮動是整台機身的上下平移：海報期間用層位移呈現，吸到整個裝置像素，不重採樣。
            let scale = window?.backingScaleFactor ?? 2
            var dy: CGFloat = 0
            if let a = render.project(SIMD3<Float>(0, 9 + Float(bob), 0)),
               let b = render.project(SIMD3<Float>(0, 9 + Float(posterBob), 0)) {
                dy = ((a.y - b.y) * scale).rounded() / scale
            }
            let f = bounds.offsetBy(dx: 0, dy: dy)
            if poster.frame != f { poster.frame = f }
        }
    }

    /// 把「目前錶面 − 凍結時錶面」投影到螢幕四邊形，加回凍結幀。成功回 true。
    /// Core Image 的合成會把負值夾成 0（變暗的地方加不回去），所以加減在 CPU 上用浮點做，只算螢幕那一塊：
    /// 三張圖（海報、新錶面投影、舊錶面投影）在線性色彩裡渲染成 Float 緩衝，p + n − o 夾回 0…1 再貼回海報。
    private func patchPoster() -> Bool {
        guard let fp = frozenPatch, let img = model.lastScreenImage,
              CGFloat(img.width) == fp.face.extent.width, CGFloat(img.height) == fp.face.extent.height else {
            if renderLog { log("3d: patch skipped (frozen \(frozenPatch != nil), image \(model.lastScreenImage != nil))") }
            return false
        }
        // 變太多就不補：交給 3D 重畫（見 patchMaxChange 的說明）
        // 只補「膠囊裡」的短暫變化（眨眼、瞄一眼，等一下會回到凍結時的樣子）；指針、換分鐘、過場這些
        // 會留下來或整面變的，補了會在舊內容的每道邊留下殘差＝殘影，一律掛回 3D 重畫
        let ch = frozenThumb.map { Self.changedFraction($0, Self.faceThumb(img), allowed: face.islandRect) } ?? (fraction: 1, outside: true)
        if ch.fraction > Self.patchMaxChange || ch.outside {
            if renderLog { log("3d: patch skipped, \(Int(ch.fraction * 100))% changed\(ch.outside ? " outside the capsule" : "") → re-render") }
            return false
        }
        let pts = fp.corners.map { CGPoint(x: $0.x * fp.scale, y: $0.y * fp.scale) }
        let c = pts.map { CIVector(x: $0.x, y: $0.y) }
        func proj(_ im: CIImage) -> CIImage {
            im.applyingFilter("CIPerspectiveTransform", parameters: ["inputTopLeft": c[0], "inputTopRight": c[1], "inputBottomRight": c[2], "inputBottomLeft": c[3]])
        }
        // 螢幕四邊形的外框（像素、整數），夾在海報裡
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let quad = CGRect(x: floor(xs.min()!) - 2, y: floor(ys.min()!) - 2, width: ceil(xs.max()! - xs.min()!) + 4, height: ceil(ys.max()! - ys.min()!) + 4)
            .intersection(fp.poster.extent)
        guard !quad.isNull, quad.width >= 2, quad.height >= 2 else { return false }
        let w = Int(quad.width), h = Int(quad.height)
        let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func floats(_ im: CIImage) -> [Float] {
            var buf = [Float](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { Self.patchCI.render(im, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: quad, format: .RGBAf, colorSpace: lin) }
            return buf
        }
        // 投影後輕輕模糊半個像素：3D 取樣（mipmap＋多重取樣）比 Core Image 的投影柔，兩邊銳利度才接近
        func soft(_ im: CIImage) -> CIImage { im.clampedToExtent().applyingGaussianBlur(sigma: 0.55).cropped(to: im.extent) }
        let pBuf = floats(fp.poster), nBuf = floats(soft(proj(CIImage(cgImage: img)))), oBuf = floats(soft(proj(fp.face)))
        Self.patchCI.clearCaches()   // 補丁之間不需要留中間圖（實測 footprint 只多約 4 MB）
        guard let out = Self.replacePatch(p: pBuf, n: nBuf, o: oBuf, w: w, h: h) else {
            if renderLog { log("3d: patch skipped, no clean pixels to match the screen's shading → re-render") }
            return false
        }
        // 浮點緩衝 → CGImage（線性色彩），蓋回凍結幀的那一塊
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let patch = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16, space: lin,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let base = fp.posterCG,
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: fp.cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.setBlendMode(.copy)
        ctx.draw(patch, in: quad)   // CIImage 與 CGContext 都是左下原點，座標直接對上
        guard let cg = ctx.makeImage() else { return false }
        poster.show(cg, scale: fp.scale)
        patches3D += 1
        if let p = ProcessInfo.processInfo.environment["HOMEPLAY_PATCH_TEST"] {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p + "/patched.png"))
        }
        return true
    }

    /// 深度閒置（90 秒沒人看）：主循環停掉，改成每 5 秒跑一拍；掛載／卸下由按需 3D 閘門處理
    /// （靜止時本來就已卸下，跑一拍若有變化會掛回去出幀、再卸下）。房間光/摄像头也暂停，绿点灭掉。
    private func startPoster() {
        guard !posterActive, !showingVideo, !occluded else { return }
        posterActive = true
        timer?.invalidate(); timer = nil; loopHz = 0
        if roomLightEnabled || gazeEnabled { GazeTracker.shared.setPaused(true) }
        startPosterTimer()
        startHoverTimer(interval: 1.0, tolerance: 0.25)   // 深度閒置：靠近喚醒慢 0.75 s 無感，省 3/4 的喚醒
        log("poster: idle, 5 s cadence")
    }

    private func startPosterTimer() {
        posterTimer?.invalidate()
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.posterTick() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        posterTimer = t
    }

    /// 深度閒置期間時間/眨眼仍要走：每 5 秒讓主循環跑一拍，有變化就由閘門掛回去出一輪幀再卸下。
    private func posterTick() {
        guard posterActive, !occluded else { return }
        step()
    }

    private func endPoster() {
        guard posterActive else { return }
        posterActive = false
        posterTimer?.invalidate(); posterTimer = nil
        startHoverTimer()   // 回到平常的 0.25 s 節奏
        if (roomLightEnabled || gazeEnabled), !occluded, !screenLocked {
            GazeTracker.shared.setPaused(false)
        }
        lastNear = CACurrentMediaTime()
        lastStep = lastNear
        face.forceDirty = true
        step()
        log("poster: resume")
    }

    /// 引导/配对卡出现时让海报让位；海报只在 PetView 内，AppDelegate 通过这个方法唤醒。
    func wakeFromPosterForGuide() {
        if posterActive { endPoster() }
    }

    func setOccluded(_ o: Bool) {
        guard o != occluded else { return }
        occluded = o
        if o {
            // 完全被遮住／螢幕休眠：連主循環和懸停輪詢一起停掉，不再每 1/12 秒叫醒 CPU；
            // ARView 也直接卸下（isHidden 停不掉它的 display link），露出來時第一拍會掛回去。
            if onDemand3D { detach3D(snapshot: false) } else { render.isHidden = true }
            timer?.invalidate(); timer = nil; loopHz = 0
            posterTimer?.invalidate(); posterTimer = nil
            hoverTimer?.invalidate(); hoverTimer = nil
            NowPlayingPoller.shared.paused = true
            AirPlayWatch.setPaused(true)   // 畫面看不到：視窗清單掃描也停
            onVideoState?(false)          // 健康檢查/統計也停
        } else {
            if posterActive { endPoster() }
            render.isHidden = false
            sceneDirty = true
            lastStep = CACurrentMediaTime(); face.forceDirty = true
            NowPlayingPoller.shared.paused = false
            AirPlayWatch.setPaused(false)
            startHoverTimer()
            if showingVideo { onVideoState?(true) }
            step()   // 立刻補一幀並恢復幀率
        }
        log("occluded \(o)")
    }
    /// 懸停輪詢：平常 0.25 s（靠近、摸頭、眼珠跟游標）；深度閒置（海報模式）放慢到 1 s——
    /// 靠近喚醒慢 0.75 s 無感，整夜不再每 0.25 s 醒一次
    private func startHoverTimer(interval: Double = 0.25, tolerance: Double = 0.05) {
        guard hoverTimer == nil || hoverInterval != interval else { return }
        hoverTimer?.invalidate()
        hoverInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.watchPointer() }
        t.tolerance = tolerance
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }
    private var hoverInterval: Double = 0.25
    private func step() {
        if occluded { return }
        stepFrames += 1
        let now = CACurrentMediaTime()
        refreshSlowState(now)
        // 低幀率醒來那一拍 dt 可能到 0.25 s：彈簧拆成 ≤1/60 s 的小步積分，時間照實走，不會慢動作也不會發散
        let realDt = CGFloat(min(0.25, max(0, now - lastStep))); lastStep = now
        let subSteps = max(1, Int((realDt * 60).rounded(.up)))
        let dt = realDt / CGFloat(subSteps)
        // 自动环绕：目标角速度匀速走（弹簧自然跟不上就变成平滑的慢转），俯仰缓缓回到 3/4 高度
        if touring {
            ty += realDt * 0.45
            tp += (0.32 - tp) * min(1, realDt * 1.5)
        }
        // 挂墙：机身贴在墙上不转——拖转、滑动、转一圈、视角预设都不动镜头，永远正对屏幕
        let wall = viewMode == .wall && !isApart
        if wall {
            touring = false
            let full = 2 * CGFloat.pi
            ty = (yaw / full).rounded() * full; tp = 0
        }
        let k1: CGFloat = 26, c1 = 2 * sqrt(k1)      // 拆开：临界阻尼，不回弹（双击不是甩出去的手势）
        // 转动：Apple 的旋转弹簧（阻尼比 0.8、响应 0.4 s），放手带惯性时会轻轻过冲再停
        let k2: CGFloat = (2 * .pi / 0.4) * (2 * .pi / 0.4), c2: CGFloat = 2 * 0.8 * sqrt(k2)
        for _ in 0..<subSteps {
            apartV += ((apartTarget - apartT) * k1 - apartV * c1) * dt
            apartT += apartV * dt
            vy += ((ty - yaw) * k2 - vy * c2) * dt; yaw += vy * dt
            vp += ((tp - pitch) * k2 - vp * c2) * dt; pitch += vp * dt
        }
        model.apply(apartT)
        idleMotion(now, min(0.05, realDt))   // 頭部與 Aim 的顯式積分沿用舊上限

        // 镜头：围着身体转；拆开时退远一点、抬一点，九件都在画面里。
        // RealityKit 默认相机朝 -Z，绕 Y 转 yaw、绕 X 转 -pitch 就正对目标，滚转恒 0。
        let e = AnatomyLayer.liftProgress(apartT)   // 跟螢幕組抬升同步：半拆時也已經在框內
        // 挂墙只框屏幕模组：对准扶正后的显示面中心
        let target = wall ? HomeViewModel.wallScreenCenter : SIMD3<Float>(0, Float(8.6 + 3.6 * e), Float(1.8 + 3.0 * e))
        let fitH: Float = wall ? Self.wallFitH : Float(22 + 22 * e)
        let d = (fitH / 2) / tanf(12 * .pi / 180) * max(1, 0.86 / Float(Pet.aspect))
        let sy = sinf(Float(yaw)), cy = cosf(Float(yaw))
        let sp = sinf(Float(pitch)), cp = cosf(Float(pitch))
        if let cameraEntity {
            cameraEntity.position = target + SIMD3<Float>(sy * cp * d, sp * d, cy * cp * d)
            cameraEntity.orientation = simd_quatf(angle: Float(yaw), axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: -Float(pitch), axis: SIMD3<Float>(1, 0, 0))
        }
        // 2.0 device: --product-shot：沿螢幕法線的 18° 長焦、螢幕扶正，整機朝向歸零（ProductShot.swift）
        if ProductShot.on, !isApart, !wall, let cameraEntity {
            let t = Float(HomeViewModel.tilt), dz = 4.28 - HomeViewModel.rigHome.z
            let c = ProductShot.screenCenter(hinge: HomeViewModel.rigHome + SIMD3<Float>(0, Float(bob), 0),
                                             dy: Float(HomeViewModel.rigY - HomeViewModel.hingeY), dz: dz, tilt: t)
            let shot = ProductShot.camera(screenCenter: c, tilt: ProductShot.elevation, screenWidth: HomeViewModel.screenSize)
            cameraEntity.position = shot.position
            cameraEntity.orientation = simd_quatf(angle: -shot.pitch, axis: SIMD3<Float>(1, 0, 0))
        }
        updateAnatomyCallout(now)

        // 转太快会吓一跳；拆开组回后甩头、眨单眼
        if abs(vy) > 6 { mood.show(.surprised, for: 0.4, now: now) }
        if reassembling, apartT < 0.15 {
            // 组回来了：甩头那 0.6 s 还是惊讶，之后眨单眼
            reassembling = false; mood.apart = false; shake(now)
            mood.show(.surprised, for: 0.6, now: now); pendingWink = now + 0.6
        }
        if let w = pendingWink, now >= w { pendingWink = nil; mood.show(.wink, for: 0.6, now: now) }
        rigMotion(now)
        if ProductShot.on { model.setRig(pitch: ProductShot.rigPitch(tilt: Float(HomeViewModel.tilt)), yaw: 0); model.setAim(yaw: 0) }   // 2.0 device: 產品照螢幕扶正、不轉頭

        shellStep(now)   // 2.0: 遠距回錶面、CarPlay 優先（Shell/ShellInput.swift）
        let expr = lockedFace ?? mood.current(now: now, hour: cachedHour)
        face.set(expr)
        face.followPointer = mood.near && lockedFace == nil
        // 遠距（一分鐘沒靠近）不做表情過場動畫：直接到位，省十幾幀
        face.animateDetails = mood.near || now - lastNear <= 60 || face.needsSmooth(now)
        // 自適應幀率：有動作／直播跑 60，閒著 12（省 GPU 與電），睡著 1。
        // 臉上有變化（眨眼、瞄一眼、換錶面）時把 hot 窗口往後推，讓那幾幀仍以 60 跑順。
        if !showingVideo, !carVideo.active, let img = face.tick(now) {
            model.setScreen(img)
            // 只有眨眼、hello、引導、過場這種「要順」的動畫才維持 60fps；
            // 環境漂動（Flow 背景、壁紙）不抬頻，免得閒著也一直 60。
            if face.needsSmooth(now) { smoothUntil = now + 0.18 }
        }
        // 氛围动画停用的三种情况：过热、低电量、系统「减弱动态效果」（辅助功能）
        Face.ambientPaused = thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue || lowPower
            || cachedReduceMotion
        let moving = isAnimating(now)
        let hz = targetHz(now, asleep: expr == .asleep, moving: moving)
        setLoopHz(hz)
        syncRenderer(now)
        // 这么久没人看，而且没有任何动画/引导/直播：换成静态海报，停掉 RealityKit 的常驻渲染。
        if !posterActive, timer != nil, !showingVideo, !occluded, !screenLocked, !gazeEnabled,
           now - lastNear > posterIdle, !moving,
           CarPlayOverlayState.alpha <= 0.003, !face.inOverview, FaceOverview.pressAt == nil,
           let win = window, win.isVisible, win.occlusionState.contains(.visible) {
            startPoster()
        }
    }

    /// 整点小时 / 系统「减弱动态效果」这类变化很慢的状态：每秒更新一次就够，
    /// Calendar 与 NSWorkspace 的属性都不该出现在每帧路径上。
    private func refreshSlowState(_ now: Double) {
        guard now - slowStateAt >= 1 else { return }
        slowStateAt = now
        cachedHour = Calendar.current.component(.hour, from: Date())
        cachedReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 現在是否在動：手勢、彈簧、過場都算（直播另外看有沒有進幀，見 targetHz）
    private func isAnimating(_ now: Double) -> Bool {
        return drag != .none || touring || now < hotUntil
            || abs(vy) > 0.02 || abs(ty - yaw) > 0.002
            || abs(vp) > 0.02 || abs(tp - pitch) > 0.002
            || abs(apartV) > 0.002 || abs(apartT - apartTarget) > 0.001
            || abs(pressTarget - 1) > 0.002
            || face.inOverview || FaceOverview.pressAt != nil
            || CarPlayOverlayState.alpha > 0.002
            || !aim.settled
            || PermissionPrimer.visible
            || ClioTalkPanel.animating(now)   // 2.0: ClioTalk 卡片進出場、彩球在轉
            || PeopleOverlay.visible   // 2.0
            || ClockKit.live(now)   // 2.0: 時鐘 App 的秒針、計時器刻度、數字捲動在動時跑 60 fps（Shell/Apps/ClockKit.swift）
            || WeatherLiveSky.wantsFrames(now)   // 2.0: 天氣 App 的動態天空在畫（減少動態效果時不要幀）
    }

    /// 現在該用幾 fps：直播有進幀 60（畫面靜止半秒沒進幀就 12，進幀立刻回 60）；
    /// 有彈簧／手勢／過場／剛動過 60；否則 6；睡著 1。
    /// 用電池（未接電源）自動降幀：動畫與直播上限 60→30（使用者拍板 2026-10-26「為 Apple 晶片優化能效」）。
    private func targetHz(_ now: Double, asleep: Bool, moving: Bool) -> Int {
        // 無風扇機器：過熱或低電量時主動降載（WWDC25「Turbocharge your app for CarPlay」的建議）
        if thermal == .critical { return asleep ? 1 : 6 }
        let throttled = thermal == .serious || lowPower
        // HOMEPLAY_BATTERY=1 量測用：機器接著電源時模擬電池路徑（同 HOMEPLAY_IDLE_HZ 的診斷開關做法）
        let onBattery = onBatteryOverride ?? (face.battery.map { !$0.onAC } ?? false)
        if showingVideo {
            if moving || now - lastVideoFrame < 0.5 { return (throttled || onBattery) ? 30 : 60 }
            return 12
        }
        if asleep { return 1 }
        if moving { return (throttled || onBattery) ? 30 : 60 }
        if throttled { return 8 }
        if let h = ClockKit.hz(now) { return onBattery ? min(h, 30) : h }   // 2.0: 時鐘 App 的秒針（Shell/Apps/ClockKit.swift）
        // 沒人靠近超過一分鐘：降到 6fps（眨眼仍走 30fps 窗口，看不出差別）
        let far = now - lastNear > 60
        let idle = idleHzOverride ?? (far ? 4 : 6)
        // 眨眼、hello 這類小動畫 30fps 就夠順（60 的一半渲染、幾乎看不出差別）
        if now < smoothUntil { return max(30, idle) }
        return max(1, idle)
    }
    /// 主循環定時器跟著幀率走，閒著不再每秒叫醒 60 次
    private func setLoopHz(_ hz: Int) {
        if posterActive { loopHz = 0; return }
        guard hz != loopHz else { return }
        timer?.invalidate()
        loopHz = hz
        // Darwin 27 上這個值對 RealityKit 的出幀節奏無效（實測恆 60），真正省下來的是上面的按需掛載；
        // 仍照 targetHz 寫，保留語意給未來能生效的系統。
        render.__preferredFrameRate = Float(hz)
        timer = LoopClock(view: self, hz: hz) { [weak self] in self?.step() }
    }

    // MARK: 表情与小动作

    private var hoverTimer: Timer?
    private var reassembling = false
    private var hotUntil: Double = 0        // 這段時間內視為「有動作」，維持 60fps
    private var lastNear = CACurrentMediaTime()   // 最近一次游標靠近／互動：長時間沒人看就降到 6fps
    /// 2.0 idle: iPhone／iPad 上的觸控也算有人在用：過場照 60fps 跑（Remote/RemoteInput.swift）
    func remoteActivity() { lastNear = CACurrentMediaTime(); hotUntil = lastNear + 0.6 }
    private var smoothUntil: Double = 0     // 眨眼這類小動畫只要 30fps（省一半渲染）
    private var loopHz = 60
    private var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var envObserver: (any NSObjectProtocol)?
    private var envObserver2: (any NSObjectProtocol)?
    private var pendingWink: Double?
    private var nodStart: Double?, shakeStart: Double?
    private var rotateMoved = false
    private var rotateTravel: CGFloat = 0          // 這次轉身體拖了多遠（點）：搬位置提示用
    private var moveHint = MoveHintDetector()
    /// 拖它就搬窗口的部位：底座那一截（螢幕、鉸鏈仍是轉身體）
    private static let standAnatomy: Set<AnatomyPart> = [.radiators, .baseModule, .power, .climate, .woofer, .foot]
    static var standAnatomyForTest: Set<AnatomyPart> { standAnatomy }
    private static let standParts: Set<String> = ["hinge", "dome", "grille", "driver", "foot"]

    /// 换外观：模型换材质；G4 白的屏幕走 Aqua，转头幅度也大一点（向日葵）
    func setFinish(_ f: Finish) { model.apply(finish: f); face.aqua = f == .g4 }

    /// 摄像头房间光的样本：亮度/色温/主光方向 → 主光、环境贴图。
    func apply(roomLight s: RoomLightSample) {
        let active = s.confidence > 0.02
        Shell.roomIntensity = active ? s.intensity : nil   // 2.0 R12：暗處 App 轉深色、錶面轉紅（Shell/HomeScreen.swift）
        // 2.0 P07：True Tone——色溫變了就重畫螢幕貼圖（微調白點；變化小於 0.02 不重畫，避免一直重繪）
        let tt = active ? max(-1, min(1, s.warmth)) : 0
        if abs(tt - Shell.trueToneWarmth) > 0.02 { Shell.trueToneWarmth = tt; face.forceDirty = true } else { Shell.trueToneWarmth = tt }
        if active {
            let k = max(0, min(1.5, s.intensity))
            let t = max(0, min(1, (k - 0.4) / 1.1))
            roomKey.light.intensity = Float(250 + 1150 * t)
            let w = max(-1, min(1, s.warmth))
            roomKey.light.color = NSColor(calibratedRed: 1 + 0.055 * CGFloat(w),
                                          green: 1,
                                          blue: 1 - 0.055 * CGFloat(w), alpha: 1)
            let pos = s.direction * 100
            roomKey.look(at: SIMD3<Float>(0, 9, 0), from: pos, relativeTo: nil)
            backLight.light.intensity = Float(max(900, 2000 - 700 * t))
            roomEnv?.update(s)
        } else {
            roomKey.light.intensity = 0
            backLight.light.intensity = 2000
            render.environment.lighting.resource = roomEnv?.neutral() ?? QuickLookIBL.studio
        }
        requestFrame()
    }

    // MARK: 錶面与计时器

    private var batteryTimer: Timer?
    private var system6Pending = false, system6Token = 0
    private var wheelAcc: CGFloat = 0, lastFaceSwitch = 0.0
    /// 换錶面（滚轮、← →、菜单）：记住选择，岛眨一下眼
    func setFaceStyle(_ st: FaceStyle, remember: Bool = true) {
        face.textLayerCache = nil; face.staticCache = nil   // 换表盘后旧缓存不会再命中，直接放掉
        guard st != face.style else { return }
        face.style = st
        if remember { UserDefaults.standard.set(st.rawValue, forKey: FaceStyle.defaultsKey) }
        if !showingVideo { model.setScreen(face.render()) }
        mood.show(.wink, for: 0.5, now: CACurrentMediaTime())
        log("face style \(st.rawValue)")
    }
    // MARK: 番茄鐘

    func startPomodoro() {
        let phase = face.pomodoro.start()
        face.startTimer(seconds: phase.seconds)
        mood.show(.happy, for: 0.8, now: CACurrentMediaTime())
        log("pomodoro start")
    }
    func stopPomodoro() {
        face.pomodoro.stop(); face.cancelTimer()
        log("pomodoro stop")
    }
    /// 番茄鐘的一段到點：自動接下一段、出橫幅、換表情。不是番茄鐘就回 false（照一般計時器處理）
    private func pomodoroAdvance(_ now: Double) -> Bool {
        guard let (next, completed) = face.pomodoro.advance() else { return false }
        if completed { Pomodoro.recordCompleted() }
        face.startTimer(seconds: next.seconds, now: now)
        let today = Pomodoro.todayCount
        if next.isBreak {
            // 專注完成：笑一下，告訴你休息
            face.showBanner(now: now, texts: (String(format: L("pomodoro.doneToday", "专注完成 · 今天第 %d 个"), today),
                                              next == .longBreak ? L("pomodoro.longBreakNow", "休息 15 分钟") : L("pomodoro.breakNow", "休息一下")))
            mood.show(.happy, for: 2.4, now: now)
        } else {
            // 休息結束：眨一下眼，回來專注
            face.showBanner(now: now, texts: (L("pomodoro.breakOver", "休息结束"), L("pomodoro.backToFocus", "回来专注")))
            mood.show(.wink, for: 0.8, now: now)
        }
        log("pomodoro → \(next) (today \(today))")
        return true
    }

    func startTimer(minutes: Double) {
        face.pomodoro.stop()   // 手動開一般計時器：番茄鐘讓位
        face.startTimer(seconds: minutes * 60)
        mood.show(.happy, for: 0.8, now: CACurrentMediaTime())
        log("timer start \(Int(minutes * 60))s")
    }
    /// 只给快照用：当作游标就在旁边（玻璃卡展开）
    var forceNear = false { didSet { face.revealTarget = forceNear ? 1 : face.revealTarget } }

    func lockFace(_ e: Expression) {
        lockedFace = e; face.frozen = true; face.set(e, snap: true); face.cancelHello()
        if !showingVideo { model.setScreen(face.render()) }
    }
    /// 连上 CarPlay 出第一帧：往前点头 6°，0.35 s
    func nod() { nodStart = CACurrentMediaTime() }
    private func shake(_ now: Double) { shakeStart = now }
    private func rigMotion(_ now: Double) {
        var nodA: CGFloat = 0, shakeA: CGFloat = 0
        if let s = nodStart {
            let t = (now - s) / 0.35
            if t >= 1 { nodStart = nil } else { nodA = 0.105 * CGFloat(sin(.pi * t)) }
        }
        if let s = shakeStart {
            let t = (now - s) / 0.6
            if t >= 1 { shakeStart = nil } else { shakeA = 0.14 * CGFloat(sin(t * 3 * 2 * .pi) * (1 - t)) }
        }
        // USDZ 的屏幕几何已经带 20° 后仰，这里只叠加点头/摇头/追人的小幅偏移
        rigPitch = Float(nodA + lookY); rigYaw = Float(shakeA + lookX)
        model.setRig(pitch: rigPitch, yaw: rigYaw)
    }
    private var rigPitch: Float = 0, rigYaw: Float = 0

    // 待机的生命感：屏幕慢慢转向靠近的游标（最多偏航 ±0.1、俯仰 ±0.06 弧度，临界阻尼、响应 0.6 s）；
    // 按下时整台立刻缩 2.5%，放手弹回；整台 4.5 s 一次、极小幅度的浮动。
    private var lookX: CGFloat = 0, lookY: CGFloat = 0, lookVX: CGFloat = 0, lookVY: CGFloat = 0
    /// 整机朝向（Aim.swift）：窗口位置当基准、看到人就转向人；「正面固定」时恒为 0。
    private var aim = Aim()
    var viewMode = ViewMode.saved
    var followDegrees = Aim.savedFollowDegrees
    /// 快照用：假装窗口在显示器横向的哪里（0 左 … 1 右）
    static var windowXOverride: Double?
    private var lastDragEndAt: Double = 0
    // 追人（摄像头）：人脸框 → 转头/歪头；没人时做待机扫视。
    var gazeEnabled = false
    var gazePresent = false
    var gazeX: CGFloat = 0, gazeY: CGFloat = 0, gazeRoll: CGFloat = 0, gazeSize: CGFloat = 0
    private var gazeLastSeen: Double = 0
    private var gazeWasPresent = false
    private var gazeHeadOn = false    // 头部 yaw 的迟滞：小侧移只动眼睛，明显侧移才转头
    static let gazePitchKey = "HomePlayGazePitch"
    private(set) var gazePitchDegrees: CGFloat = {
        let v = (UserDefaults.standard.object(forKey: "HomePlayGazePitch") as? Double) ?? 2.5
        return CGFloat(min(8, max(0, v.isFinite ? v : 2.5)))
    }()
    private var screenLocked = false  // 锁屏期间不因为「重新可见」把摄像头拉起来
    private var press: CGFloat = 1, pressTarget: CGFloat = 1
    private var dragVel: CGFloat = 0, lastDragT: Double = 0
    /// 单轴锁：拖拽／滚轮转动共用（一次手势只走左右或上下）；滚轮手势没有明确边界，用时间隔断
    private var rotLock = AxisLock()
    private var lastRotScroll: Double = 0
    private func idleMotion(_ now: Double, _ dt: CGFloat) {
        let calm = !showingVideo && !isApart && drag == .none && lockedFace == nil
        var gx: CGFloat = 0, gy: CGFloat = 0
        // G4 白：像当年 G4 广告里跟着路人动作的那台，转头幅度大一倍
        let sunflower: CGFloat = model.finish == .g4 ? 2.2 : 1
        if calm, gazeEnabled, gazePresent {
            // 左右摇是主戏（G4 约 11.5°，其它约 7.5°）；俯仰只加一点点：
            // 以 0.65 当作「正常坐姿」的中位（摄像头通常比脸高），只回应明显起身/凑近，
            // 非 G4 最多约 2°，G4 最多约 3.7°——Mac 是效率工具，桌宠只做轻微回应。
            // 头部有 0.08–0.14 的迟滞：小幅侧移只动眼睛，明显侧移才转头，避免一直微调。
            let g4 = model.finish == .g4
            let ax = abs(gazeX)
            if ax > 0.14 { gazeHeadOn = true } else if ax < 0.08 { gazeHeadOn = false }
            // 左右转交给整机（aim，±25° DockKit 式）；铰链只留俯仰
            _ = ax
            gx = 0
            // 俯仰上限由菜单里的「跟随我俯仰角度」控制（0–8°，默认 2.5°，G4 略大）。
            let maxPitch = gazePitchDegrees * (g4 ? 1.25 : 1.0) * .pi / 180
            let normalized = max(-1, min(1, (gazeY - 0.65) / 0.35))
            let pitch = normalized * maxPitch
            gy = abs(pitch) < 0.006 ? 0 : pitch
        } else if calm, gazeEnabled {
            let recent = CACurrentMediaTime() - gazeLastSeen < 3
            if recent {
                // 刚走开：慢慢回正，头还在回味
                gx = 0; gy = 0
            } else if mood.near, let p = face.pointer {
                // 摄像头一段时间没看到人（走出视野）：退回鼠标跟随，俯仰同样受滑杆限制
                let pitchScale = gazePitchDegrees / 2.5
                gx = max(-1, min(1, p.x)) * 0.1 * sunflower
                gy = max(-1, min(1, p.y)) * 0.06 * sunflower * pitchScale
            } else {
                // 一个人待着：头保持安静，偶尔的一瞥交给眼睛（Face.nextGlance）。
                // Mark View 的原则：弹簧落定后就停，不在稳态继续晃。
                gx = 0; gy = 0
            }
        } else if calm, mood.near, let p = face.pointer {
            gx = max(-1, min(1, p.x)) * 0.1 * sunflower; gy = max(-1, min(1, p.y)) * 0.06 * sunflower
        }
        let k: CGFloat = (2 * .pi / 0.6) * (2 * .pi / 0.6), c: CGFloat = 2 * sqrt(k)
        lookVX += ((gx - lookX) * k - lookVX * c) * dt; lookX += lookVX * dt
        // 整机朝向：窗口在显示器哪边就朝中央；看到人就转向人（扣掉摄像头与桌宠之间的视差）
        var baseline = 0.0
        if let ox = Self.windowXOverride {
            baseline = Aim.baseline(windowMidX: ox, screenMidX: 0.5, screenHalfWidth: 0.5)
        } else if let w = window, let vis = (w.screen ?? NSScreen.main)?.visibleFrame {
            baseline = Aim.baseline(windowMidX: Double(w.frame.midX), screenMidX: Double(vis.midX),
                                    screenHalfWidth: Double(vis.width / 2))
        }
        let aimMode: ViewMode = isApart ? .front : viewMode
        let following = gazeEnabled && gazeShouldRun && !isApart && lockedFace == nil
        let ay = aim.step(now: now, dt: Double(dt), mode: aimMode, following: following, present: gazePresent,
                          gazeX: Double(gazeX), baseline: baseline, maxDegrees: followDegrees)
        model.setAim(yaw: Float(ay))
        // 正面固定：拖转、滑动都可以，放手 0.6 s 后弹回正面
        if viewMode == .front, !touring, !isApart, drag == .none,
           now - lastRotScroll > 0.6, now - lastDragEndAt > 0.6 {
            let full = 2 * CGFloat.pi
            let home = (yaw / full).rounded() * full
            if abs(ty - home) > 0.0005 || abs(tp - 0.12) > 0.0005 { ty = home; tp = 0.12 }
        }
        lookVY += ((gy - lookY) * k - lookVY * c) * dt; lookY += lookVY * dt
        // 机身不歪头；俯仰只保留上面那一点点（明显起身/凑近才动），
        // 大部分上下和表情交给眼睛——Mac 是效率工具，不做云台式抢注意力。
        press += (pressTarget - press) * (1 - exp(-dt / 0.05))
        bob = lockedFace == nil ? 0.05 * CGFloat(sin(now * 2 * .pi / 4.5)) : 0
        model.setIdle(press: press, bob: bob)
    }

    /// 菜单开关：关掉时把追人状态清干净，让机器回正。
    func setGazeEnabled(_ on: Bool) {
        gazeEnabled = on
        WhoIsLooking.shared.setFollowActive(on)   // 2.0: 「跟随我」开着才认人
        gazeHeadOn = false
        if !on {
            gazePresent = false
            gazeWasPresent = false
            gazeX = 0; gazeY = 0; gazeRoll = 0; gazeSize = 0
        }
        log("gaze follow \(on ? "on" : "off")")
    }

    /// 追人现在是否该让摄像头跑着：开关开着、不在直播、机身没被遮住、没锁屏。
    /// 2026-10-22 起 CarPlay 直播时也跟随（Aaron 定案）；锁屏、屏幕睡眠、被完全挡住时照旧暂停。
    var gazeShouldRun: Bool { gazeEnabled && !occluded && !screenLocked }
    var isScreenLocked: Bool { screenLocked }

    /// 摄像头的人脸样本（主线程）。第一次看到人时点一下头，像注意到你。
    func applyGaze(_ s: GazeTracker.Sample) {
        if s.present {
            gazePresent = true
            gazeX = s.x; gazeY = s.y; gazeRoll = s.roll; gazeSize = s.size
            gazeLastSeen = CACurrentMediaTime()
            if !gazeWasPresent {
                gazeWasPresent = true
                gazeHeadOn = false
                // 错峰：眼睛先到（Face.pointer 每帧更新、14/s 追过去），
                // 头随后（0.6 s 弹簧），落定前再点一下头、补一个眨眼。
                mood.show(.surprised, for: 0.3, now: CACurrentMediaTime())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                    guard let self, self.gazePresent else { return }
                    self.nod()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) { [weak self] in
                    guard let self, self.gazePresent else { return }
                    self.face.blinkSoon()
                }
                log(String(format: "gaze acquired x=%.2f y=%.2f roll=%.2f", s.x, s.y, s.roll))
            }
        } else if gazeWasPresent {
            gazeWasPresent = false
            gazePresent = false
            gazeHeadOn = false
            face.blinkSoon(after: 0.12)
            log("gaze lost")
        }
    }

    private func watchPointer() {
        guard !occluded, let win = window, win.isVisible else { return }
        let now = CACurrentMediaTime()
        let m = NSEvent.mouseLocation, f = win.frame
        let dx = max(f.minX - m.x, 0, m.x - f.maxX), dy = max(f.minY - m.y, 0, m.y - f.maxY)
        let dist = hypot(dx, dy)
        let gazeHere = gazeEnabled && gazePresent
        let gazeRecent = gazeEnabled && CACurrentMediaTime() - gazeLastSeen < 3
        mood.near = gazeHere || gazeRecent || dist <= 120
        if mood.near { lastNear = now }
        if carVideo.active, dist <= 0 {   // 游標在桌寵上：影片控制列浮出
            carVideo.controlsUntil = max(carVideo.controlsUntil, now + 1.5)
        }
        // 游標進到視窗裡＝馬上可能要拖／捏：先把 3D 掛上，第一下手勢就不用等 30–40 ms 的掛載
        if dist <= 4 {
            pointerInsideAt = now
            if onDemand3D, !attached3D, !posterActive { attach3D() }
        }
        if posterActive, mood.near || gazeEnabled { endPoster() }
        // 靠近就多显示：240 pt 外收起，20 pt 内全展开；摄像头看到人时直接全开
        face.revealTarget = gazeHere ? 1
            : (gazeRecent ? max(face.revealTarget, 0.65)
               : (forceNear ? 1 : max(0, min(1, 1 - (dist - 20) / 220))))
        face.flowActive = mood.near && face.expression != .asleep
        if mood.near { mood.activity(now: now, hour: Calendar.current.component(.hour, from: Date())) }
        if gazeHere {
            face.pointer = CGPoint(x: max(-1, min(1, gazeX)), y: max(-1, min(1, gazeY)))
        } else if dist > 120, let v = AirPlayWatch.videoCenter {
            // Mac 正在用 AirPlay 播影片：游標不在身邊時，眼睛看著那個影片視窗
            face.pointer = CGPoint(x: max(-1, min(1, (v.x - f.midX) / (f.width * 1.6))), y: max(-1, min(1, -(v.y - f.midY) / (f.height * 1.6))))
        } else {
            face.pointer = CGPoint(x: (m.x - f.midX) / (f.width * 0.6), y: -(m.y - f.midY) / (f.height * 0.6))
        }
        var onStand = false
        if f.contains(m), drag == .none {
            let p = convert(win.convertPoint(fromScreen: m), from: nil)
            onStand = hitsModel(p) && screenUV(p) == nil
        }
        mood.petting(onStand, now: now)
    }

    // 稿里的两个默认角度：组好时 0.52，拆开时转到 1.08 侧看，九件才不会叠在一条视线上。
    // 用户自己转过就不再替他转。
    private var atHome = true
    private static let homeYaw: CGFloat = 0.52, apartYaw: CGFloat = 1.0, homePitch: CGFloat = 0.26
    /// 挂墙时镜头的竖直取景（cm）：屏幕模组外框约 14.4 cm，四周各留约 5% 的边
    static let wallFitH: Float = 16.6
    func setApart(_ on: Bool) {
        if on, viewMode == .wall { return }   // 挂墙没有底座可拆
        apartTarget = on ? 1 : 0
        if on { mood.apart = true }      // 组回到位才放下（见 step）
        else { pinnedPart = nil; hoverPart = nil }
        reassembling = !on
        mood.activity(now: CACurrentMediaTime(), hour: Calendar.current.component(.hour, from: Date()))
        if atHome {
            var y = on ? Self.apartYaw : Self.homeYaw
            while y - yaw > .pi { y -= 2 * .pi }
            while y - yaw < -.pi { y += 2 * .pi }
            ty = y; tp = Self.homePitch
        }
        log("explode \(on ? "on" : "off")")
    }
    var isApart: Bool { apartTarget > 0.5 }

    func showVideo(_ on: Bool) {
        if on, posterActive { endPoster() }
        guard on != showingVideo else { return }
        showingVideo = on
        onVideoState?(on)
        // 直播时摄像头照常跑（跟随我在 CarPlay 里也转向你）；只有确实可见、没锁屏才恢复
        if gazeEnabled || roomLightEnabled, !occluded, !screenLocked {
            GazeTracker.shared.setPaused(false)
        }
        log("screen \(on ? "live" : "face")")
        // 直播期间 face.tick 停着：先收掉总览和待触发的长按，连线盖板按当下状态重设，免得切回来闪一下旧状态
        if on { if face.inOverview { _ = face.endOverview(confirm: false) }; FaceOverview.pressToken += 1; FaceOverview.swallowUp = false; face.dismissOnboarding() }
        CarPlayOverlayState.alpha = face.carPlayConnecting && !on ? 1 : 0
        if !on {
            decoder.reset()
            model.setScreen(face.render())
        }
    }

    // MARK: 命中

    /// 屏幕四个角在视图里的投影（左下原点），顺序：左上、右上、右下、左下。
    /// 用单应变换把点击映射回屏幕 UV；比 raycast 更稳，也不会被边框挡住。
    func screenCorners() -> [CGPoint] {   // 2.0: P05 輔助使用的框也用這份投影（Shell/ShellAccessibility.swift）
        let a = model.screenAnchor
        let pts = [SIMD3<Float>(-6.27, 6.27, 0), SIMD3<Float>(6.27, 6.27, 0),
                   SIMD3<Float>(6.27, -6.27, 0), SIMD3<Float>(-6.27, -6.27, 0)]
        return pts.compactMap { render.project(a.convert(position: $0, to: nil)) }
    }
    /// 屏幕正面是否朝向相机（背面不接触控）
    func screenFacingCamera() -> Bool {   // 2.0: P05
        let m = model.screenAnchor.transformMatrix(relativeTo: nil)
        let n = simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        guard let cam = cameraEntity else { return true }
        let eye = cam.position(relativeTo: nil)
        let center = model.screenAnchor.position(relativeTo: nil)
        return simd_dot(n, eye - center) > 0
    }
    /// 点到的屏幕 uv（0..1，左上原点）
    private func screenUV(_ p: NSPoint) -> CGPoint? {
        guard screenFacingCamera() else { return nil }
        let c = screenCorners()
        let unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        guard c.count == 4, let inv = homography(from: c, to: unit) else { return nil }
        let q = applyHomography(inv, p)
        guard q.x >= 0, q.x <= 1, q.y >= 0, q.y <= 1 else { return nil }
        return CGPoint(x: q.x, y: q.y)
    }
    /// 机身碰触（RealityKit 的不可见碰撞盒）
    private func hitsModel(_ p: NSPoint) -> Bool {
        !render.hitTest(p, query: .nearest, mask: .all).isEmpty
    }
    private func local(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }
    private func inResizeCorner(_ p: NSPoint) -> Bool {
        let g = max(16, bounds.width * 0.09)
        return p.x > bounds.width - g && p.y < g    // NSView 不翻转：右下角 y 小
    }

    /// 屏幕上的点 → 发给接收器的 0..1（扣掉留黑）
    private func videoPoint(_ p: NSPoint) -> (Double, Double)? {
        guard let uv = screenUV(p), let (u, v) = CornerFit.shared.toVideo(u: Double(uv.x), v: Double(uv.y)) else { return nil }
        let s = decoder.size
        return screenToVideo(u: u, v: v, videoW: Double(s.width), videoH: Double(s.height))
    }
    /// 「正在播放」胶囊带：屏幕下缘约三分之一（uv.y>0.68）；胶囊活跃时点／滚在这里＝媒体控制
    private func capsuleHit(_ p: NSPoint) -> Bool {
        guard let uv = screenUV(p) else { return false }
        return uv.y > 0.68 && uv.x > 0.04 && uv.x < 0.96
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        endPoster()
        // 非激活面板收不到捏合/旋转这类手势事件：点一下就把 App 激活并把窗口立为 key
        // （makeKey 而不是只激活 App——面板只有成为 key window 才开始收手势）。
        // 之后双指张合、三指拖移、键盘快捷键都能用；点别的 App 就自然让出焦点。
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if window?.isKeyWindow == false { window?.makeKey() }
        lastNear = CACurrentMediaTime()
        hotUntil = CACurrentMediaTime() + 0.4
        if ProcessInfo.processInfo.environment["PET_PROBE"] != nil {
            let probePoint = local(event)
            if let uv = screenUV(probePoint) { log(String(format: "click uv=(%.3f,%.3f)", uv.x, uv.y)) }
            else { log("click body hit=\(hitsModel(probePoint))") }
        }
        // 权限说明卡在屏幕上时，屏幕上的点击都归卡片（按钮：继续／以后／打开系统设置）
        if PermissionPrimer.visible, !showingVideo {
            if let uv = screenUV(local(event)) { drag = .none; PermissionPrimer.press(x: uv.x * 1024, y: uv.y * 1024); face.forceDirty = true; return }
        }
        if face.sayingHello, !showingVideo, screenUV(local(event)) != nil, face.skipHello(CACurrentMediaTime()) { drag = .none; return }   // 2.0 hello：点屏幕直接交给錶面（停着等设定卡时归卡片；拖机身照旧）
        if PeopleOverlay.capturesClicks, !showingVideo, let uv = screenUV(local(event)) {   // 2.0: 录脸引导卡（取消钮）
            drag = .none; PeopleOverlay.press(x: uv.x * 1024, y: uv.y * 1024); face.forceDirty = true; return
        }
        if ClioTalkPanel.visible, !showingVideo, let uv = screenUV(local(event)) {   // 2.0: ClioTalk 卡片上的點擊歸卡片
            drag = .none; ClioTalkPanel.press(x: uv.x * 1024, y: uv.y * 1024); face.forceDirty = true; return
        }
        if shellMouseDown(event, uv: screenUV(local(event))) { return }      // 2.0: 主畫面、App、控制中心（Shell/ShellInput.swift）
        if overviewMouseDown(event, uv: screenUV(local(event))) { return }   // 长按换錶面总览
        if face.onboardingActive {   // 第一次的操作提示：点一下收起（并取消刚排上的长按）
            face.dismissOnboarding(); FaceOverview.pressToken += 1; FaceOverview.pressAt = nil; return
        }
        let p = local(event)
        if face.bannerShowing && !showingVideo { face.dismissBanner(); return }   // 点一下收起「时间到了」
        // System 6 錶面：单击屏幕（没拖、也不是双击）才打开 AI System 6，放手后等过双击间隔再开
        system6Pending = face.style == .system6 && face.system6Layout == .finder && !showingVideo && event.clickCount == 1 && screenUV(p) != nil
        if event.clickCount >= 2 { system6Token += 1 }
        if event.modifierFlags.contains(.command) {
            let before = window?.frame.origin
            window?.performDrag(with: event)   // 拖完才回來
            if let before, window?.frame.origin != before { MoveHint.noteMoved() }
            return
        }
        if inResizeCorner(p) {
            drag = .resize; winStart = window?.frame ?? .zero; mouseStart = NSEvent.mouseLocation; return
        }
        // 系統三指拖動合成的滑鼠拖拽：觸控板上真的有三指時，整個桌寵都是搬視窗（直播屏幕也一樣）。
        // 拿不到觸控幀（私有框架不可用）就退回舊判斷：開了三指拖動就把拖拽當搬視窗。
        let threeFingers = Self.systemThreeFingerDrag
            && (TrackpadPinch.shared.available ? TrackpadPinch.shared.fingerCount >= 3 : true)
        if threeFingers {
            if !showingVideo, hitsModel(p) { pressTarget = 0.975 }
            drag = .move; winStart = window?.frame ?? .zero; mouseStart = NSEvent.mouseLocation
            rotateMoved = false
            appendDiag("gesture.log", "three-finger drag (system) start")
            return
        }
        // CarPlay 影片在播：螢幕上的點擊給影片控制列（不送到手機）；雙擊放大／收回
        if carVideo.active, let uv = screenUV(p) {
            if event.clickCount == 2 { carVideo.toggleBig(near: window?.frame) }
            else { _ = carVideo.click(u: uv.x, v: uv.y, windowFrame: window?.frame) }
            drag = .none
            return
        }
        // 直播時只有屏幕平面屬於 CarPlay；邊框／機身仍然可以搬窗口
        if showingVideo, let uv = screenUV(p) {
            drag = .touch
            if let (x, y) = videoPoint(p) {
                log(String(format: "touch down uv=(%.3f,%.3f) → video=(%.4f,%.4f)", uv.x, uv.y, x, y))
                onTouch?(x, y, true)
            }
            return
        }
        let now = CACurrentMediaTime()
        mood.activity(now: now, hour: Calendar.current.component(.hour, from: Date()))
        let onStand = hitsStand(p)
        if hitsModel(p) { pressTarget = 0.975; if !onStand, mood.poke(now: now) { shake(now) } }
        dragVel = 0; lastDragT = event.timestamp
        if event.clickCount == 2, hitsModel(p) { resetOrientation(); drag = .none; return }
        // 拖底座＝搬窗口（不用按 ⌘）；螢幕和鉸鏈以上照舊轉身體
        if onStand {
            touring = false
            drag = .move; winStart = window?.frame ?? .zero; mouseStart = NSEvent.mouseLocation
            rotateMoved = false
            appendDiag("gesture.log", "stand drag start")
            return
        }
        drag = .rotate; last = p; rotateMoved = false; rotateTravel = 0; rotLock.reset(); touring = false
    }

    override func mouseDragged(with event: NSEvent) {
        lastNear = CACurrentMediaTime()
        hotUntil = CACurrentMediaTime() + 0.4
        if shellMouseDragged(event, uv: screenUV(local(event))) { return }   // 2.0
        if overviewMouseDragged(event) { return }   // 总览里不转身体
        let p = local(event)
        switch drag {
        case .resize:
            let now = NSEvent.mouseLocation
            let w = max(Pet.minWidth, min(Pet.maxWidth, winStart.width + (now.x - mouseStart.x)))
            let h = w / Pet.aspect
            window?.setFrame(NSRect(x: winStart.minX, y: winStart.maxY - h, width: w, height: h), display: true)
            updateFaceScale()
        case .rotate:
            let dx = p.x - last.x, dy = p.y - last.y; last = p
            rotateTravel += abs(dx) + abs(dy)
            // 单轴锁：起手判主轴（左右＝偏航、上下＝俯仰），被锁的轴不动
            let (lx, ly) = rotLock.pass(dx: dx, dy: dy)
            atHome = false
            // 记下转动速度（低通），放手时用来投射惯性（锁在俯仰上就没有偏航惯性）
            let dtt = max(0.004, event.timestamp - lastDragT); lastDragT = event.timestamp
            dragVel = dragVel * 0.6 + (-lx * 0.009 / CGFloat(dtt)) * 0.4
            // 被抓起来的那一下：惊讶 0.4 s
            if !rotateMoved { rotateMoved = true; mood.show(.surprised, for: 0.4, now: CACurrentMediaTime()) }
            ty -= lx * 0.009
            tp = max(-0.15, min(1.42, tp - ly * 0.006))
        case .touch:
            if let (x, y) = videoPoint(p) { onTouch?(x, y, true) }
        case .move:
            let now = NSEvent.mouseLocation
            let dx = now.x - mouseStart.x, dy = now.y - mouseStart.y
            if abs(dx) > 2 || abs(dy) > 2 { rotateMoved = true }
            guard let win = window else { return }
            // 搬窗口允許跨屏（x/y 都不夾），鬆手後只把「完全跑出所有屏幕」的情況救回來
            win.setFrameOrigin(NSPoint(x: winStart.minX + dx, y: winStart.minY + dy))
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastDragEndAt = CACurrentMediaTime()
        if shellMouseUp(event, uv: screenUV(local(event))) { drag = .none; pressTarget = 1; return }   // 2.0
        if PermissionPrimer.tracking {
            let uv = screenUV(local(event))
            PermissionPrimer.release(x: uv.map { $0.x * 1024 }, y: uv.map { $0.y * 1024 })
            face.forceDirty = true
            return
        }
        if ClioTalkPanel.tracking {   // 2.0: ClioTalk 卡片
            let uv = screenUV(local(event))
            ClioTalkPanel.release(x: uv.map { $0.x * 1024 }, y: uv.map { $0.y * 1024 })
            face.forceDirty = true
            return
        }
        if overviewMouseUp(event, uv: screenUV(local(event))) { drag = .none; pressTarget = 1; system6Pending = false; return }
        let p = local(event)
        switch drag {
        case .resize:
            endResize()
        case .touch:
            if let (x, y) = videoPoint(p) {
                log(String(format: "touch up video=(%.4f,%.4f)", x, y))
                onTouch?(x, y, false)
            } else { onTouch?(-1, -1, false) }
        case .rotate where !rotateMoved && anatomyActive:
            // 拆開時點一下零件＝釘住它的標籤；點同一件或空白處＝放開
            system6Pending = false; system6Token += 1
            let hit = pickAnatomy(p)?.0
            pinnedPart = hit == pinnedPart ? nil : hit
            updateAnatomyCallout(CACurrentMediaTime())
            log("anatomy pin \(pinnedPart?.rawValue ?? "none")")
        case .rotate where !rotateMoved && !showingVideo && capsuleHit(p):
            // 「正在播放」胶囊上点一下＝播放／暂停（控正在显示的那家：Music 或 Spotify）
            NowPlayingPoller.shared.control(.playPause)
        case .rotate where !rotateMoved && system6Pending:
            system6Pending = false; system6Token += 1
            let token = system6Token
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
                guard let self, self.system6Token == token, let url = URL(string: "https://system6.aaronlau.me") else { return }
                NSWorkspace.shared.open(url); log("open AI System 6")
            }
        case .move:
            if !rotateMoved {
                // 三指拖移机器上的「点一下」：保留摸头等点击语义（直播中不打扰）
                if !showingVideo, hitsModel(p) { mood.show(.happy, for: 1.0, now: CACurrentMediaTime()) }
            } else if let w = window {
                MoveHint.noteMoved()
                log("moved \(Int(w.frame.minX)),\(Int(w.frame.minY))")
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) {
                // 整个拖出屏幕：拉回主屏
                if let vf = NSScreen.main?.visibleFrame {
                    w.setFrameOrigin(NSPoint(x: vf.maxX - w.frame.width - 24, y: vf.minY + 24))
                }
                }
            }
        case .rotate where rotateMoved:
            mood.show(.happy, for: 1.2, now: CACurrentMediaTime())   // 放下：笑一下
            // 拖機身是轉身體；一路拖到窗外（或拖很遠）兩次，多半其實想搬走它：提示一次怎麼搬
            if MoveHint.shouldOffer, let w = window,
               moveHint.rotateDragEnded(now: CACurrentMediaTime(), leftWindow: !w.frame.contains(NSEvent.mouseLocation),
                                        travel: Double(rotateTravel), width: Double(w.frame.width)) {
                MoveHint.show(near: w)
                appendDiag("gesture.log", "move hint shown")
            }
            // 甩出去：照 Apple 的动量投射（减速率 0.995），目标往前推，弹簧接着当前速度转过去
            if event.timestamp - lastDragT < 0.08 { ty += max(-.pi, min(.pi, dragVel * 0.2)) }
            rotLock.reset()        default: break
        }
        drag = .none; pressTarget = 1
    }

    // MARK: 触控板 / Magic Mouse 手势
    // 捏合＝放大缩小（像 PiP，锁比例，以窗口中心为锚）；两指旋转＝偏航转身体；
    // 两指滑（触控板）／单指滑（Magic Mouse）＝转动身体，单轴锁：起手判主轴，只走左右或上下，带系统惯性；
    // 智能缩放（触控板两指轻点两下）＝拆开／组回；轻扫（MM 双指／触控板三指）＝左右转一圈、上回正、下拆组；
    // 普通滚轮＝一格一格缩放。

    func resizeWindow(toWidth w0: CGFloat, anchorCenter: Bool) {
        guard let win = window else { return }
        let f = win.frame
        let w = max(Pet.minWidth, min(Pet.maxWidth, w0)), h = w / Pet.aspect
        let origin = anchorCenter ? NSPoint(x: f.midX - w / 2, y: f.midY - h / 2) : NSPoint(x: f.minX, y: f.maxY - h)
        win.setFrame(clampToScreen(NSRect(origin: origin, size: NSSize(width: w, height: h))), display: true)
        // 捏合到最小/最大时给一次对齐反馈（只在刚碰界那一下，不连发）
        let limit: CGFloat? = w == Pet.minWidth ? Pet.minWidth : (w == Pet.maxWidth ? Pet.maxWidth : nil)
        if limit != nil, limit != limitHaptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        limitHaptic = limit
    }

    /// 缩放动画版（菜单/快捷键走这条）：0.18s 缓出，窗口保持在屏幕内
    func resizeWindowAnimated(toWidth w0: CGFloat) {
        guard let win = window else { return }
        let f = win.frame
        let w = max(Pet.minWidth, min(Pet.maxWidth, w0)), h = w / Pet.aspect
        let target = clampToScreen(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            win.animator().setFrame(target, display: true)
        })
    }

    /// 把窗口钳回屏幕（找中心所在的屏，没有就用主屏）
    private func clampToScreen(_ r: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let containing = screens.first { NSMouseInRect(NSPoint(x: r.midX, y: r.midY), $0.frame, false) }
            ?? screens.first { NSIntersectsRect(r, $0.frame) }
            ?? NSScreen.main
        guard let visible = containing?.visibleFrame else { return r }
        var out = r
        if out.maxX > visible.maxX { out.origin.x = visible.maxX - out.width }
        if out.minX < visible.minX { out.origin.x = visible.minX }
        if out.maxY > visible.maxY { out.origin.y = visible.maxY - out.height }
        if out.minY < visible.minY { out.origin.y = visible.minY }
        return out
    }

    // MARK: 缩放与回正（菜单/快捷键/双击共用）

    func zoom(by factor: CGFloat) { resizeWindowAnimated(toWidth: bounds.width * factor) }
    func setZoom(width: CGFloat) { resizeWindowAnimated(toWidth: width) }
    /// 一键最大：屏高的 85%（锁比例），不超过上限
    func zoomMax() {
        let vh = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        setZoom(width: min(Pet.maxWidth, vh * 0.85 * Pet.aspect))
    }

    /// 双击：转正回主视角（走最短路径的弹簧动画），拆开状态先组回来
    func resetOrientation() {
        touring = false
        if isApart { setApart(false) }
        atHome = true
        var y = Self.homeYaw
        while y - yaw > .pi { y -= 2 * .pi }
        while y - yaw < -.pi { y += 2 * .pi }
        ty = y; tp = Self.homePitch
        mood.show(.wink, for: 0.6, now: CACurrentMediaTime())
        log("gesture reset-orientation")
    }

    // MARK: 拆開看看：零件標籤（滑過顯示、點一下釘住、自動環繞時依序介紹）

    private let callout = AnatomyCallout()
    private var hoverPart: AnatomyPart?
    private var pinnedPart: AnatomyPart?
    private var tourIndex = -1, tourNext = 0.0
    /// 拆得夠開（外面幾層已經到位）才接受挑零件
    private var anatomyActive: Bool { apartT > 0.4 && !showingVideo }

    /// 這個點（視圖座標）底下是哪一件
    /// 點在底座那一截（不在螢幕上、真的打到機身、拆開看看時不算）
    private func hitsStand(_ p: NSPoint) -> Bool {
        guard !anatomyActive, screenUV(p) == nil, hitsModel(p), let part = pickAnatomy(p)?.0 else { return false }
        return Self.standAnatomy.contains(part)
    }
    private func pickAnatomy(_ p: NSPoint) -> (AnatomyPart, SIMD3<Float>)? {
        guard let ray = render.ray(through: p) else { return nil }
        return model.pickAnatomy(origin: ray.origin, direction: ray.direction)
    }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseMoved(with event: NSEvent) {
        guard anatomyActive, drag == .none else { return }
        let hit = pickAnatomy(local(event))?.0
        if hit != hoverPart { hoverPart = hit; updateAnatomyCallout(CACurrentMediaTime()) }
    }
    override func mouseExited(with event: NSEvent) {
        if hoverPart != nil { hoverPart = nil; updateAnatomyCallout(CACurrentMediaTime()) }
    }

    /// 每拍跟著模型更新標籤：釘住的 > 滑過的 > 自動環繞輪到的
    private func updateAnatomyCallout(_ now: Double) {
        var part: AnatomyPart?
        if anatomyActive {
            if touring, now >= tourNext {
                tourIndex = (tourIndex + 1) % AnatomyPart.tourOrder.count
                tourNext = now + 2.6
            }
            part = pinnedPart ?? hoverPart ?? (touring && tourIndex >= 0 ? AnatomyPart.tourOrder[tourIndex] : nil)
        }
        let eye = cameraEntity?.position(relativeTo: nil) ?? SIMD3<Float>(0, 10, 100)
        guard let part, let w = model.anatomyAnchor(part, eye: eye), let pt = render.project(w) else {
            if !callout.isHidden { callout.isHidden = true; callout.part = nil }
            return
        }
        callout.part = part
        callout.anchor = pt
        callout.opacity = clamp01((apartT - 0.4) / 0.12)
        callout.isHidden = false
    }

    /// 快照用：拆開程度直接到位（--apart-t），不走彈簧
    func setInitialApart(_ t: CGFloat) {
        apartTarget = t; apartT = t; apartV = 0
        mood.apart = t > 0.5
        if atHome { yaw = Self.apartYaw; ty = yaw }
        model.apply(t)
    }
    /// 快照／除錯用：直接釘住一件的標籤
    func pinAnatomy(_ part: AnatomyPart) { pinnedPart = part }

    /// 快照疊上零件標籤（RealityKit 快照只有 3D）
    func compositeOverlays(_ img: CGImage) -> CGImage {
        guard !callout.isHidden, callout.part != nil,
              let rep = callout.bitmapImageRepForCachingDisplay(in: callout.bounds) else { return img }
        callout.cacheDisplay(in: callout.bounds, to: rep)
        guard let over = rep.cgImage else { return img }
        // 不用 makeImage：它翻成左上原點，CGImage 會畫倒
        guard let g = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        g.draw(img, in: r); g.draw(over, in: r)
        return g.makeImage() ?? img
    }

    // MARK: 预设机位（照 homeview-anatomy.vercel.app 的 Front/Side/Back/Above）＋自动环绕

    /// 预设机位：走最短路径的弹簧转向。yaw 传 nil＝保持现在的朝向只改俯仰。
    func setView(yaw targetYaw: CGFloat?, pitch targetPitch: CGFloat, label: String) {
        touring = false
        atHome = false
        if let targetYaw {
            var y = targetYaw
            while y - yaw > .pi { y -= 2 * .pi }
            while y - yaw < -.pi { y += 2 * .pi }
            ty = y
        }
        tp = max(-0.15, min(1.42, targetPitch))
        log("view \(label)")
    }
    /// 除錯／CLI 用：走和選單完全相同的預設機位
    func applyViewPreset(_ name: String) {
        switch name {
        case "front": menuViewFront()
        case "side": menuViewSide()
        case "back": menuViewBack()
        case "above": menuViewAbove()
        default: break
        }
    }

    @objc func menuViewFront() { setView(yaw: 0, pitch: 0.12, label: "front") }
    @objc func menuViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ViewMode(rawValue: raw) else { return }
        setViewMode(mode)
    }
    func setViewMode(_ mode: ViewMode) {
        let wasWall = viewMode == .wall
        viewMode = mode
        ViewMode.saved = mode
        if mode == .wall, isApart { setApart(false) }
        if (mode == .wall) != wasWall {
            // 进出挂墙：换掉底座/铰链、窗口比例跟着换（宽度不变），离开时镜头回原本的主视角
            model.setWall(mode == .wall)
            Pet.aspect = Pet.aspect(for: mode)
            if let w = window { resizeWindowAnimated(toWidth: w.frame.width) }
            if wasWall { atHome = true; ty = Self.homeYaw; tp = Self.homePitch }
        }
        if mode == .front { menuViewFront() }
        hotUntil = CACurrentMediaTime() + 0.4
        log("view mode \(mode.rawValue)")
    }
    @objc func menuViewSide() { setView(yaw: .pi / 2, pitch: 0.18, label: "side") }
    @objc func menuViewBack() { setView(yaw: .pi, pitch: 0.15, label: "back") }
    @objc func menuViewAbove() { setView(yaw: nil, pitch: 1.3, label: "above") }

    /// 自动环绕（网站的 auto tour）：慢慢转给人看，任何转动操作都会停下
    private(set) var touring = false   // 2.0 P06: 設定的「自動環繞」開關要讀它
    @objc func menuTour() {
        touring.toggle()
        if touring { atHome = false; tourIndex = -1; tourNext = 0 }
        log("tour \(touring ? "on" : "off")")
    }
    private func endResize() {
        updateFaceScale()
        if let f = window?.frame { log("resize \(Int(f.width))x\(Int(f.height))") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.logProbes() }
    }

    override func magnify(with e: NSEvent) {
        endPoster()
        appendDiag("gesture.log", "local magnify mag=\(e.magnification) phase=\(e.phase.rawValue)")
        // 全局接触帧（TrackpadPinch）已经处理同一次捏合时别双倍缩放
        if CACurrentMediaTime() - TrackpadPinch.shared.lastPinchAt < 0.25 { return }
        // 触控板判定这次不是捏合（是双指滑动或扭转）：不缩放
        if TrackpadPinch.shared.available, TrackpadPinch.shared.twoFingerKind != .pinch { return }
        // 收尾事件常带一段残余值，别在松手时再跳一下
        if e.phase == .ended || e.phase == .cancelled { endResize(); return }
        guard abs(e.magnification) > 0.0001 else { return }
        hotUntil = CACurrentMediaTime() + 0.4
        // 增量语义（Chromium：incremental change values），单帧限幅防大跳
        let factor = min(1.06, max(0.94, 1 + e.magnification))
        resizeWindow(toWidth: bounds.width * factor, anchorCenter: true)
    }
    override func rotate(with e: NSEvent) {
        // 两指旋转手势不再转身体：捏合时手指总会带一点扭转，系统就同时发旋转事件，
        // 结果缩放时身体也跟着转（2026-10-22）。转身体只用双指滑动／拖动。
        return
    }
    override func smartMagnify(with e: NSEvent) { setApart(!isApart) }
    // 三指手势统一给「拖移窗口」（见 touchesBegan/Moved）。轻扫不再占用三指：
    // 转一圈用菜单「外观 › 自动环绕」，回正双击，拆开双指轻点两下。

    // MARK: 三指拖移窗口
    // 触控板只给归一化坐标（0..1，铺满整块触控板），按屏宽比例换算成点：
    // 横跨一次触控板约等于横跨一次屏幕，手感接近直接搬动。
    override func touchesBegan(with event: NSEvent) {
        let t = event.touches(matching: .touching, in: self)
        guard t.count == 3 else { threeFinger = nil; return }
        threeFinger = t.map(\.normalizedPosition)
        pressTarget = 0.98                  // 抓起：轻轻一抬
        log("three-finger drag start")
    }
    override func touchesMoved(with event: NSEvent) {
        guard var base = threeFinger, let w = window else { return }
        let t = event.touches(matching: .touching, in: self)
        guard t.count == 3 else { threeFinger = nil; return }   // 中途少一根手指：结束这次拖移，避免跳
        let p = t.map(\.normalizedPosition)
        var dx: CGFloat = 0, dy: CGFloat = 0
        for (a, b) in zip(p, base) { dx += a.x - b.x; dy += a.y - b.y }
        dx /= 3; dy /= 3
        let scale = (NSScreen.main?.frame.width ?? w.frame.width) * 0.85   // 一次完整横拖 ≈ 0.85 屏宽
        var f = w.frame
        f.origin.x += dx * scale
        f.origin.y += dy * scale                     // 触控板 y 向上＝窗口向上（直接操纵）
        w.setFrameOrigin(clampToScreen(f).origin)
        if abs(dx) + abs(dy) > 0.002 { MoveHint.noteMoved() }
        base = p; threeFinger = base
    }
    override func touchesEnded(with event: NSEvent) { threeFinger = nil; pressTarget = 1 }
    override func touchesCancelled(with event: NSEvent) { threeFinger = nil; pressTarget = 1 }
    override func scrollWheel(with e: NSEvent) {
        endPoster()
        lastNear = CACurrentMediaTime()
        hotUntil = CACurrentMediaTime() + 0.4
        if overviewScroll(e) { return }   // 总览里滚轮／触控板挑錶面，不转身体
        if shellScroll(e, uv: screenUV(local(e))) { return }   // 2.0: 錶面頭尾滾到主畫面、App 裡捲動
        // 「正在播放」胶囊上滚＝上一首／下一首；只在胶囊活跃时占用这条带，其余照旧（转身体／换錶面）
        if !showingVideo, abs(e.scrollingDeltaY) > 0.05, capsuleHit(local(e)), face.musicActive(CACurrentMediaTime()) {
            NowPlayingPoller.shared.control(e.scrollingDeltaY > 0 ? .next : .previous)
            return
        }
        guard e.hasPreciseScrollingDeltas else {
            if e.modifierFlags.contains(.option) {
                // ⌥＋普通滚轮：一格放大／缩小 8%
                let step: CGFloat = e.scrollingDeltaY > 0 ? 1.08 : (e.scrollingDeltaY < 0 ? 1 / 1.08 : 1)
                resizeWindow(toWidth: bounds.width * step, anchorCenter: true); endResize(); return
            }
            // 普通滚轮＝数字表冠：一格换一个錶面（直播时不换）；连续滚太快只算一次
            guard !showingVideo else { return }
            wheelAcc += e.scrollingDeltaY
            let now = CACurrentMediaTime()
            if abs(wheelAcc) >= 1, now - lastFaceSwitch > 0.25 {
                setFaceStyle(face.style.next(wheelAcc > 0 ? -1 : 1))
                lastFaceSwitch = now; wheelAcc = 0
            } else if now - lastFaceSwitch > 0.6 { wheelAcc = max(-1, min(1, wheelAcc)) }
            return
        }
        // ⌥＋雙指滾動（精確滾動）：按比例縮放。滾輪事件只投遞給指針下的窗口，
        // 桌寵自己的窗口先收到，所以縮放必須在這裡做，全局監視等不到這條事件。
        if e.modifierFlags.contains(.option), abs(e.scrollingDeltaY) > 0.01 {
            appendDiag("gesture.log", "local opt-scroll dy=\(e.scrollingDeltaY)")
            resizeWindow(toWidth: bounds.width * (1 + CGFloat(e.scrollingDeltaY) * 0.01), anchorCenter: true)
            return
        }
        // 换成「手指往哪走」，不管自然滚动开没开
        let fx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        let fy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
        // 手势在起手时决定归谁，整个手势（含惯性）都锁定：
        // 直播屏幕上起手＝CarPlay 拖；机身上起手＝转身体；透明边＝什么都不做。捏合已确认时滑动让位。
        // 触控板上两指的类型由接触帧判定：还没判定、是捏合或扭转时，这些滚动事件不转身体也不拖 CarPlay。
        //（以前滚动事件一来就转，捏合要等指距变了 2.5% 才确认——捏合开头总会先把身体转一下。）
        if e.momentumPhase.isEmpty, TrackpadPinch.shared.available, TrackpadPinch.shared.holdScroll { return }
        let now = CACurrentMediaTime()
        let began = e.phase == .began
        let target = scrollArb.route(
            now: now, began: began, momentum: !e.momentumPhase.isEmpty,
            ended: e.phase == .ended || e.phase == .cancelled, momentumEnded: e.momentumPhase == .ended,
            dx: Double(fx), dy: Double(fy), pinching: TrackpadPinch.shared.pinching,
            classify: { [unowned self] in self.classifyGesturePoint(self.local(e)) })
        if began || (e.phase.isEmpty && e.momentumPhase.isEmpty && scrollArb.startedAt == now) {
            appendDiag("gesture.log", "scroll begin target=\(target.rawValue)")
        }
        if e.momentumPhase == .ended {
            appendDiag("gesture.log", gestureLogLine("scroll", target: target, momentum: true, duration: now - scrollArb.startedAt))
        }
        switch target {
        case .none: return
        case .carplay: scrollDrag(e, fx: fx, fy: fy); return   // 丢惯性在 scrollDrag 里（CarPlay 自己会甩）
        case .rotate: break
        }
        // 滚轮转动也走单轴锁：phase 有 began 就是新手势；Magic Mouse 常没有 phase，用 0.25 s 时间隔断
        if e.phase == .began || now - lastRotScroll > 0.25 { rotLock.reset() }
        lastRotScroll = now
        let (lx, ly) = rotLock.pass(dx: fx, dy: fy, threshold: 4)
        touring = false
        atHome = false
        ty -= lx * 0.005
        tp = max(-0.15, min(1.42, tp - ly * 0.005))
        if e.phase == .began { log("gesture scroll-rotate") }
    }

    /// 双指滑动的仲裁状态（见 GestureArbiter.swift）
    private(set) var scrollArb = ScrollArbiter()
    /// 起手点归谁：直播屏幕＝CarPlay；机身（逐零件碰撞盒）＝转身体；其余透明区＝不处理。
    /// 不直播时屏幕也是机身的一部分。
    func classifyGesturePoint(_ p: NSPoint) -> GestureTarget {
        if showingVideo, screenUV(p) != nil { return .carplay }
        if hitsModel(p) || screenUV(p) != nil { return .rotate }
        return .none
    }

    // 两指滑拖动的状态：画面坐标里的当前触点 + 闲置抬起计时
    private var scrollTouch: (x: Double, y: Double)?
    private var scrollIdle: Timer?

    private func scrollDrag(_ e: NSEvent, fx: CGFloat, fy: CGFloat) {
        if !e.momentumPhase.isEmpty { return }
        if scrollTouch == nil {
            guard let (x, y) = videoPoint(local(e)) else { return }
            scrollTouch = (x, y); onTouch?(x, y, true)
            log(String(format: "scroll-drag down video=(%.4f,%.4f)", x, y))
        }
        // 手指位移（点）→ 画面 0..1：除以画面在屏幕上的显示宽高
        let span = screenSpanPoints()
        let s = decoder.size
        let fitW = s.width >= s.height ? 1 : s.width / max(1, s.height)
        let fitH = s.width >= s.height ? s.height / max(1, s.width) : 1
        if span > 1, var t = scrollTouch {
            t.x = min(1, max(0, t.x + Double(fx / (span * fitW))))
            t.y = min(1, max(0, t.y - Double(fy / (span * fitH))))
            scrollTouch = t; onTouch?(t.x, t.y, true)
        }
        scrollIdle?.invalidate()
        if e.phase == .ended || e.phase == .cancelled { endScrollDrag() }
        else {
            scrollIdle = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in self?.endScrollDrag() }
        }
    }
    private func endScrollDrag() {
        scrollIdle?.invalidate(); scrollIdle = nil
        guard let t = scrollTouch else { return }
        scrollTouch = nil; onTouch?(t.x, t.y, false)
        log(String(format: "scroll-drag up video=(%.4f,%.4f)", t.x, t.y))
    }
    /// 方屏在视图里的显示边长（点）：把左右两边中点投影出来量距离
    private func screenSpanPoints() -> CGFloat {
        guard let a = render.project(model.screenAnchor.convert(position: SIMD3<Float>(-6.27, 0, 0), to: nil)),
              let b = render.project(model.screenAnchor.convert(position: SIMD3<Float>(6.27, 0, 0), to: nil)) else { return 1 }
        return hypot(b.x - a.x, b.y - a.y)
    }

    /// 方屏 uv → 全局坐标（左上原点，点）。只给验收脚本用（PET_PROBE=1）。
    func logProbes() {
        guard ProcessInfo.processInfo.environment["PET_PROBE"] != nil, let win = window,
              let mainH = NSScreen.screens.first?.frame.height else { return }
        let uvs: [(CGFloat, CGFloat)] = [(0.5, 0.5), (0.25, 0.75), (0.8, 0.3)]
        for (u, v) in uvs {
            let lx = (u - 0.5) * 12.54, ly = (0.5 - v) * 12.54
            guard let p = render.project(model.screenAnchor.convert(position: SIMD3<Float>(Float(lx), Float(ly), 0), to: nil)) else { continue }
            let g = win.convertPoint(toScreen: convert(NSPoint(x: p.x, y: p.y), to: nil))
            let gy: CGFloat = mainH - g.y
            log(String(format: "probe uv=(%.2f,%.2f) at %.1f %.1f", Double(u), Double(v), Double(g.x), Double(gy)))
        }
    }

    // 右键菜单：三组结构——状态动作｜宠物本身（表盘·计时器·拆装·外观）｜收尾（偏好·关于·结束）。
    // 长得快的放外面，难得碰的收子菜单；标题动态反映当前状态；菜单每次打开都重建。
    override func rightMouseDown(with event: NSEvent) {
        endPoster()
        let menu = buildContextMenu()
        var at = convert(event.locationInWindow, from: nil)
        // 菜单只在当前屏幕内展开：贴着屏幕底边时 macOS 会把后面几项折叠起来。
        // 下方放不下、上方放得下就向上展开（Mac 菜单的通常行为）。
        if let screen = window?.screen {
            let mouse = NSEvent.mouseLocation
            let below = mouse.y - screen.visibleFrame.minY
            let above = screen.visibleFrame.maxY - mouse.y
            let h = menu.size.height
            if below < h + 12, above > below { at.y += h }
        }
        startMenuTicker()
        menu.popUp(positioning: nil, at: at, in: self)
        stopMenuTicker()
    }

    private func timerMenuTitle(_ now: Double) -> String {
        var s = face.pomodoro.active ? face.timerLabel : L("timer.title", "计时器")
        if let end = face.timerEnd { s += " · " + timerClock(max(0, end - now)) }
        return s
    }

    /// 菜单打开期间每 0.5 秒刷新倒计时。Timer 放 common + eventTracking 两种模式，
    /// NSMenu 的嵌套 tracking loop 里也能跑；状态栏菜单在桌宠隐藏时同样有效。
    func startMenuTicker() {
        guard menuTicker == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshMenuTimer() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        menuTicker = t
        refreshMenuTimer()
    }

    func stopMenuTicker() {
        menuTicker?.invalidate(); menuTicker = nil
    }

    private func refreshMenuTimer() {
        guard let item = liveTimerItem else { return }
        let title = timerMenuTitle(CACurrentMediaTime())
        if item.title != title { item.title = title }
    }

    /// CarPlay 那一項：按真實狀態給動詞（直播中＝退出；已暫停＝繼續；重連中＝重新連接；連線中＝取消）。
    /// 右鍵選單與選單列共用這一份，兩處永遠一致
    var carPlayAction: (title: String, action: Selector, hint: String?, symbol: String) {
        if showingVideo { return (L("menu.exitCarPlay", "退出 CarPlay"), #selector(menuToggleLive), L("menu.hint.liveToggle", "重按或空格"), "car.fill") }
        switch face.status {
        case .connecting: return (L("menu.cancelConnect", "取消连接"), #selector(menuCancelConnect), nil, "xmark.circle")
        case .pausedResume, .paused: return (L("menu.resumeCarPlay", "继续 CarPlay"), #selector(menuToggleLive), L("menu.hint.space", "空格"), "play.fill")
        case .reconnecting: return (L("menu.reconnectCarPlay", "重新连接 CarPlay"), #selector(menuEnterCarPlay), nil, "arrow.clockwise")
        default: return (L("menu.enterCarPlay", "进入 CarPlay"), #selector(menuEnterCarPlay), L("menu.hint.forceClick", "重按"), "car")
        }
    }

    /// 右键菜单（状态栏图标的菜单也復用它，兩处永远一致）
    /// 2.0 P06：三组——画面（CarPlay·表盘·主屏幕·控制中心）｜机身（计时器·拆装·跟随·外观）｜收尾（ClioTalk·设置·关于·结束）。
    /// 图标只给主要动作和标准项（HIG Menus）；视角、大小、岛表盘选项都搬去设置，菜单里不再列。
    func buildContextMenu() -> NSMenu {
        CalendarSource.shared.refresh()   // 授权状态可能在系统设置里改过
        let menu = NSMenu()
        // 状态项：按真实状态给动词，而不是一个含糊的「暂停」。
        // 直播中＝退出（同一手势可再进）；已暂停＝继续；重连中＝重新连接；连线中＝取消。
        let cp = carPlayAction
        menu.addItem(menuItem(cp.title, cp.action, hint: cp.hint, symbol: cp.symbol))
        // 配对过两台以上：手机收进一个子菜单，打勾的是现在这台，点一下就换（不用进偏好设定）
        let phones = CarPlayPhoneBook.menuEntries()
        if phones.count > 1 {
            let sub = NSMenu()
            for entry in phones {
                let item = menuItem(entry.title, #selector(menuUsePhone(_:)))
                item.representedObject = entry.address
                item.state = entry.current ? .on : .off
                sub.addItem(item)
            }
            menu.addItem(submenuItem(L("menu.iphone", "iPhone"), sub))
        }
        // iPhone：連接步驟、Wi-Fi 設定、配對新的、拷貝診斷報告（連線卡上的「右鍵 → iPhone → …」都指這裡）
        let iphone = NSMenu()
        iphone.addItem(menuItem(L("menu.connectSteps", "连接步骤…"), #selector(menuConnectSteps), symbol: "list.number"))
        iphone.addItem(menuItem(L("menu.wifiPassword", "Wi-Fi 设置…"), #selector(menuWiFiPassword), symbol: "wifi"))
        iphone.addItem(menuItem(L("menu.pairNewPhone", "配对新 iPhone…"), #selector(menuPairNewPhone), symbol: "plus.circle"))
        iphone.addItem(.separator())
        iphone.addItem(menuItem(L("menu.copyDiagnostics", "拷贝诊断报告"), #selector(menuCopyDiagnostics), symbol: "doc.on.clipboard"))
        menu.addItem(submenuItem(L("menu.iphone", "iPhone"), iphone, symbol: "iphone"))
        menu.addItem(.separator())

        // 表盘：全部表盘（打勾）＋总览；样式选项（岛、Typograph、System 6、字体与颜色、照片文件夹）在设置的「外观」
        let styles = NSMenu()
        for st in FaceStyle.lineup {
            let item = menuItem(st.title, #selector(menuStyle(_:)), hint: face.style == st ? L("menu.hint.scrollArrows", "滚轮 / ← →") : nil)
            item.representedObject = st.rawValue; item.state = face.style == st ? .on : .off
            styles.addItem(item)
        }
        styles.addItem(.separator())
        styles.addItem(menuItem(L("menu.faceOverview", "显示表盘总览"), #selector(menuFaceOverview), hint: L("menu.hint.longPress", "长按屏幕")))
        styles.addItem(menuItem(L("menu.sayHello", "打个招呼"), #selector(menuSayHello)))   // 2.0 hello：再写一次开机的 hello
        menu.addItem(submenuItem(L("menu.faces", "表盘"), styles))
        // 2.0: 主畫面與控制中心（滑鼠沒有滑動手勢，這兩項加上鍵盤 ↑、C）
        let home = menuItem(L("shell.menu.home", "显示主屏幕"), #selector(menuShellHome), hint: "↑", symbol: "square.grid.3x3.fill")
        home.state = Shell.nav.screen.coversFace ? .on : .off
        menu.addItem(home)
        menu.addItem(menuItem(L("shell.menu.controlCenter", "显示控制中心"), #selector(menuShellControlCenter), hint: "C", symbol: "switch.2"))
        menu.addItem(menuItem(L("recipe.menu.clipboard", "在 Safari 中打开食谱"), #selector(menuRecipeFromClipboard)))   // 2.0: 食譜
        menu.addItem(.separator())

        // 计时器：跑的时候标题显示剩余时间，多一项取消
        let timers = NSMenu()
        if face.pomodoro.active {
            timers.addItem(menuItem(L("pomodoro.stop", "停止番茄钟"), #selector(menuPomodoroStop)))
        } else {
            timers.addItem(menuItem(L("pomodoro.start", "开始番茄钟"), #selector(menuPomodoroStart)))
        }
        let today = Pomodoro.todayCount
        if today > 0 {
            let done = NSMenuItem(title: String(format: L("pomodoro.today", "今天完成 %d 个"), today), action: nil, keyEquivalent: "")
            done.isEnabled = false; timers.addItem(done)
        }
        timers.addItem(.separator())
        for m in [1.0, 3, 5, 10, 25] {
            let item = menuItem(String(format: L("timer.minutes", "%d 分钟"), Int(m)), #selector(menuTimer(_:)))   // 分钟清单不带图标
            item.representedObject = m
            if face.timerEnd != nil, !face.pomodoro.active, abs(face.timerTotal - m * 60) < 0.5 { item.state = .on }
            timers.addItem(item)
        }
        if face.timerEnd != nil {
            timers.addItem(.separator())
            timers.addItem(menuItem(L("timer.cancel", "取消计时器"), #selector(menuTimerCancel)))
        }
        let timerItem = submenuItem(timerMenuTitle(CACurrentMediaTime()), timers)
        liveTimerItem = timerItem
        menu.addItem(timerItem)

        menu.addItem(menuItem(isApart ? L("menu.apart.putBack", "组回来") : L("menu.apart.takeApart", "拆开看看"),
                              viewMode == .wall ? nil : #selector(menuApart),   // 挂墙没有底座可拆：灰掉
                              hint: L("menu.hint.twoFingerTap", "两指轻点两下")))
        // 跟随我：最常开关的一项放在第一层（设置里有完整说明）
        let follow = menuItem(L("prefs.gaze", "跟随我"), #selector(menuGazeToggle))
        follow.state = gazeEnabled ? .on : .off
        menu.addItem(follow)

        // 外观：机身配色（朝向、视角、大小在设置的「外观」，快捷键 1–4、⌘+ ⌘− ⌘0 照旧）
        let looks = NSMenu()
        for f in Finish.allCases {
            let item = menuItem(f.title, #selector(menuFinish(_:)))
            item.image = finishSwatch(f)
            item.representedObject = f.rawValue
            item.state = model.finish == f ? .on : .off
            looks.addItem(item)
        }
        looks.addItem(.separator())
        looks.addItem(menuItem(L("menu.appearanceSettings", "外观设置…"), #selector(menuAppearanceSettings)))
        menu.addItem(submenuItem(L("menu.finish", "外观"), looks))

        menu.addItem(.separator())

        menu.addItem(menuItem(L("menu.clioTalk", "问 ClioTalk"), #selector(menuClioTalk), hint: L("menu.hint.f5", "F5"), symbol: "bubble.left.and.text.bubble.right"))   // 2.0
        menu.addItem(menuItem(L("menu.settings", "设置…"), #selector(menuSettings), key: ",", mods: .command, symbol: "gearshape"))
        // 2.0: 「关于 HomePlay」搬到菜单栏的 App 菜单第一项（installMainMenu），右键菜单不再放
        menu.addItem(.separator())
        menu.addItem(menuItem(L("menu.quit", "退出 HomePlay"), #selector(menuQuit), key: "q", mods: .command, symbol: "power"))
        return menu
    }

    /// 菜单项：key＝真快捷键（系统画在右边）；hint＝没有快捷键的手势提示，灰字靠右；
    /// symbol＝左边的 SF Symbol（2.0 P06：只给主要动作和标准项——CarPlay、主屏幕、控制中心、ClioTalk、设置、结束）
    private func menuItem(_ title: String, _ sel: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [], hint: String? = nil,
                          symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        item.keyEquivalentModifierMask = mods
        item.target = self
        if let hint {
            let ps = NSMutableParagraphStyle()
            ps.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
            let font = NSFont.menuFont(ofSize: 0)
            let s = NSMutableAttributedString(string: title + "\t", attributes: [.font: font, .paragraphStyle: ps])
            s.append(NSAttributedString(string: hint, attributes: [.font: NSFont.menuFont(ofSize: font.pointSize - 2),
                                                                  .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: ps]))
            item.attributedTitle = s
        }
        return item
    }
    func submenuItem(_ title: String, _ sub: NSMenu, hint: String? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = hint.map { menuItem(title, nil, hint: $0, symbol: symbol) }
            ?? menuItem(title, nil, symbol: symbol)
        item.submenu = sub
        return item
    }
    /// 配色的色票圆点（菜单里比文字好认）
    private func finishSwatch(_ f: Finish) -> NSImage {
        let hex: UInt32
        switch f {
        case .g4: hex = 0xF4F5F4
        case .silver: hex = 0xD8DADB
        case .starlight: hex = 0xE9E1D3
        case .rose: hex = 0xE8C9C2
        case .gray: hex = 0x6E7073
        }
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            srgb(hex).setFill(); p.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke(); p.lineWidth = 0.5; p.stroke()
            return true
        }
        return img
    }

    // MARK: 偏好设定（菜单里的子菜单，不另开窗口）

    static let photoFolderKey = "HomePlayPhotoFolder"
    @objc private func menuSettings() {
        if let app = NSApp.delegate as? AppDelegate { SettingsWindowController.show(app: app) }
    }
    /// 2.0 P06：外观子菜单底下的「外观设置…」——朝向、视角、大小、岛表盘选项都在那一页
    @objc private func menuAppearanceSettings() {
        if let app = NSApp.delegate as? AppDelegate { SettingsWindowController.show(app: app, pane: .appearance) }
    }
    @objc private func menuLoginItem() {
        let svc = SMAppService.mainApp
        do {
            switch svc.status {
            case .enabled: try svc.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try svc.register()
            }
        } catch { log("login item 失败：\(error.localizedDescription)") }
        log("login item \(svc.status == .enabled ? "on" : "off")")
    }
    @objc private func menuPhotoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = face.photos.folder
        panel.message = L("prefs.photoFolder.message", "选一个放照片的文件夹，照片表盘会轮播里面的照片")
        panel.prompt = L("prefs.photoFolder.choose", "选择")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.photoFolderKey)
        face.photos = PhotoShelf(folder: url); face.forceDirty = true
        log("photo folder \(url.path)")
    }
    @objc private func menuCalendarAllow() {
        (NSApp.delegate as? AppDelegate)?.withPermission(.calendar) { ok in
            if ok { CalendarSource.shared.requestAccess() }   // 已授权：只是同步状态、开始读
        }
    }
    @objc private func menuCalendarToggle() { CalendarSource.enabled.toggle(); CalendarSource.shared.refresh() }
    @objc private func menuCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }
    @objc private func menuNowPlaying() {
        if NowPlayingPoller.enabled {
            NowPlayingPoller.enabled = false; NowPlayingPoller.shared.stop(); return
        }
        (NSApp.delegate as? AppDelegate)?.withPermission(.automation) { [weak self] ok in
            guard let self, ok else { return }
            NowPlayingPoller.enabled = true
            NowPlayingPoller.shared.start(face: self.face)
        }
    }
    @objc private func menuGazeToggle() {
        (NSApp.delegate as? AppDelegate)?.toggleGazeFollow()
    }
    @objc private func menuMicPermission() {
        (NSApp.delegate as? AppDelegate)?.showMicrophonePermission()
    }
    @objc private func menuGazePitch() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("gaze.pitch.title", "跟随我：俯仰角度")
        alert.informativeText = L("gaze.pitch.body", "拖动滑块调整抬头/低头的最大角度；0° 只转头不点头。设置会记住。")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
        let slider = NSSlider(value: Double(gazePitchDegrees), minValue: 0, maxValue: 8,
                              target: self, action: #selector(gazePitchSliderChanged(_:)))
        slider.frame = NSRect(x: 0, y: 8, width: 300, height: 26)
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = false
        let value = NSTextField(labelWithString: String(format: "%.1f°", Double(gazePitchDegrees)))
        value.frame = NSRect(x: 308, y: 11, width: 52, height: 20)
        value.alignment = .right
        gazePitchValueLabel = value
        box.addSubview(slider); box.addSubview(value)
        alert.accessoryView = box
        alert.addButton(withTitle: L("wifi.save", "保存"))
        alert.addButton(withTitle: L("wifi.cancel", "取消"))
        let response = alert.runModal()
        gazePitchValueLabel = nil
        if response == .alertFirstButtonReturn {
            setGazePitch(CGFloat(slider.doubleValue))
        }
    }
    @objc private func gazePitchSliderChanged(_ sender: NSSlider) {
        gazePitchValueLabel?.stringValue = String(format: "%.1f°", sender.doubleValue)
    }
    func setGazePitch(_ degrees: CGFloat) {
        gazePitchDegrees = min(8, max(0, degrees))
        UserDefaults.standard.set(Double(gazePitchDegrees), forKey: Self.gazePitchKey)
        log(String(format: "gaze pitch %.1f°", Double(gazePitchDegrees)))
    }
    @objc private func menuRoomLightToggle() {
        (NSApp.delegate as? AppDelegate)?.toggleRoomLight()
    }
    @objc private func menuShowHints() { Onboarding.armed = false; Onboarding.active = false; face.armOnboarding() }
    @objc func menuFaceOverview() {
        guard !showingVideo, !face.inOverview else { return }
        face.beginOverview()
        mood.show(.wink, for: 0.5, now: CACurrentMediaTime())
    }
    @objc private func menuCancelConnect() { onCancelConnect?() }

    // 重按（Force Touch，stage 2）＝进入 CarPlay。直播时按在屏幕上不抢：那一按本来就是 CarPlay 长按。
    override func pressureChange(with event: NSEvent) {
        endPoster()
        defer { forceStage = event.stage }
        // 直播時點在屏幕上會是 .touch；這正是要退出的時候，不能把重按擋掉。
        // 同一個手勢進出：沒畫面就進 CarPlay，有畫面就退出（空格仍是備用）。
        guard event.stage == 2, forceStage < 2, !face.inOverview, !FaceOverview.swallowUp else { return }
        onForceEnter?()
    }

    @objc func menuEnterCarPlay() { onForceEnter?() }
    @objc func menuPairPhone() {
        guard !showingVideo else { return }
        CarPlayOverlayState.needsPairing = true      // 立即显示配对卡片
        CarPlayOverlayState.needsTrust = false       // 同一时间只亮一张引导卡
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.bluetoothPairing = false
        CarPlayOverlayState.bluetoothPairFailed = false
        onForceEnter?()                              // 拉起 receiver，等 USB
    }
    @objc private func menuUsePhone(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String, !address.isEmpty else { return }
        onSelectPhone?(address)
    }
    @objc private func menuPairNewPhone() { onPairNewPhone?() }
    @objc func menuConnectSteps() { ConnectHelp.showSteps() }
    @objc func menuCopyDiagnostics() { onCopyDiagnostics?() }
    @objc private func menuForgetPhone(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String, !address.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("forget.title", "忘记这台 iPhone？")
        alert.informativeText = L("forget.body", "HomePlay 会停止使用它，并删除这台 Mac 上的蓝牙配对。之后会告诉你 iPhone 上还要做哪一步。")
        alert.addButton(withTitle: L("forget.confirm", "忘记"))
        alert.addButton(withTitle: L("wifi.cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onForgetPhone?(address)
    }
    /// 「忘記 iPhone」之後：列出還要使用者自己做的步驟（HomePlay 動不了 iPhone 的設定；Mac 的系統配對有時也刪不掉）
    func showForgetSteps(name: String?, macRemoved: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = name.map { String(format: L("forget.doneTitle", "已忘记「%@」"), $0) }
            ?? L("forget.doneTitleNoName", "已忘记这台 iPhone")
        var steps = [L("forget.stepPhone", "在 iPhone 上：设置 › 通用 › CarPlay › HomePlay › 忘记此车辆（蓝牙配对会一起删除）")]
        if !macRemoved {
            steps.append(L("forget.stepMac", "在这台 Mac 上：系统设置 › 蓝牙 › 这台 iPhone 旁边的 ⓘ › 忘记此设备"))
        }
        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        alert.informativeText = L("forget.doneBody", "要重新配对，还差这几步：") + "\n\n" + numbered
        if !macRemoved { alert.addButton(withTitle: L("forget.openBluetooth", "打开蓝牙设置")) }
        alert.addButton(withTitle: L("gaze.denied.ok", "好"))
        if alert.runModal() == .alertFirstButtonReturn, !macRemoved,
           let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func menuRestorePhones() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("restore.title", "恢复已忘记的 iPhone？")
        alert.informativeText = L("restore.body", "HomePlay 会重新把这些 iPhone 列入可用设备；系统蓝牙配对不会自动恢复。")
        alert.addButton(withTitle: L("restore.confirm", "恢复"))
        alert.addButton(withTitle: L("wifi.cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRestorePhones?()
    }
    @objc private func menuWiFiPassword() {
        NSApp.activate(ignoringOtherApps: true)
        // 优先用已保存的「iPhone 所连 Wi-Fi」；没有才用 Mac 当前 Wi-Fi 作提示。
        // Mac 与 iPhone 连不同 SSID（同网段）是常见情况，不能默认填 Mac 自己的。
        var ssid = ReceiverLauncher.loadConfig().ssid
        if ssid.isEmpty { ssid = CarPlayWiFi.ssid }
        let hasSavedPassword = !ReceiverLauncher.loadConfig().passphrase.isEmpty
        var password = ""
        var note: String?
        while true {
            let alert = NSAlert()
            alert.messageText = L("wifi.title", "Wi-Fi 设置")
            var body = L("wifi.body", "这里填 iPhone 所连的 Wi-Fi（不一定是 Mac 自己连的那个）。Mac 用网线、或两者连不同 SSID 时，请填 iPhone 那个网络的名称和密码。iPhone 已在该网络上时密码可留空。macOS 26 不再允许 App 读取钥匙串密码，需要时请在系统设置里查看后手填（仅存在本机）。")
            if let note { body += "\n\n" + note }
            alert.informativeText = body
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 96))
            let l1 = NSTextField(labelWithString: L("wifi.ssid", "iPhone 所连 Wi-Fi（SSID）"))
            l1.frame = NSRect(x: 0, y: 76, width: 360, height: 17)
            l1.font = .systemFont(ofSize: 11); l1.textColor = .secondaryLabelColor
            let ssidField = NSTextField(frame: NSRect(x: 0, y: 50, width: 360, height: 24))
            ssidField.stringValue = ssid
            ssidField.placeholderString = L("wifi.ssidPlaceholder", "留空＝用 Mac 当前 Wi-Fi（仅当 iPhone 也连它）")
            let l2 = NSTextField(labelWithString: L("wifi.password", "Wi-Fi 密码"))
            l2.frame = NSRect(x: 0, y: 28, width: 360, height: 17)
            l2.font = .systemFont(ofSize: 11); l2.textColor = .secondaryLabelColor
            let pwField = NSSecureTextField(frame: NSRect(x: 0, y: 2, width: 360, height: 24))
            pwField.stringValue = password
            pwField.placeholderString = hasSavedPassword
                ? L("wifi.placeholder.keep", "留空＝保持已保存的密码")
                : L("wifi.placeholder", "Wi-Fi 密码（留空＝开放网络）")
            for v in [l1, ssidField, l2, pwField] { container.addSubview(v) }
            alert.accessoryView = container
            alert.addButton(withTitle: L("wifi.save", "保存"))
            alert.addButton(withTitle: L("wifi.openSettings", "在系统设置里查看…"))
            alert.addButton(withTitle: L("wifi.cancel", "取消"))
            alert.window.initialFirstResponder = pwField
            let response = alert.runModal()
            let enteredSSID = ssidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let enteredPassword = pwField.stringValue
            if response == .alertFirstButtonReturn {
                // macOS 在无定位权限时把 SSID 显示成 "<redacted>"，曾有人把它当真名保存，
                // 结果 0x5703 让 iPhone 去连一个不存在的网络。这里直接挡住。
                if enteredSSID.caseInsensitiveCompare("<redacted>") == .orderedSame {
                    note = L("wifi.rejectedRedacted", "「<redacted>」是 macOS 隐藏网络名后显示的占位文字，不是真实网络名。请填 iPhone 所连 Wi-Fi 的实际名称（可在 iPhone 的「设置 › Wi-Fi」里看到）。")
                    continue
                }
                onSetWiFi?(enteredSSID, enteredPassword)
                return
            }
            if response == .alertThirdButtonReturn { return }
            ssid = enteredSSID
            // 第二颗按钮：macOS 26 不再向 App 提供 Wi-Fi 密码，只能到系统设置里查看后手填。
            openWiFiSettings()
            password = enteredPassword
            note = L("wifi.openedSettings", "已在「系统设置 › Wi-Fi › 详细信息」显示密码；抄下后填到上面，再点保存。")
        }
    }

    private func openWiFiSettings() {
        for text in ["x-apple.systempreferences:com.apple.wifi-settings-extension",
                     "x-apple.systempreferences:com.apple.preference.network"] {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    @objc private func menuToggleLive() { onToggleLive?() }
    /// 转一圈：目标偏航加一整圈，弹簧缓动转完正好回原朝向。direction = 1 往左、-1 往右（跟拖拽方向一致）。
    private func spinBody(direction: Int) {
        touring = false
        atHome = false
        ty += CGFloat(direction) * 2 * .pi
        mood.show(.surprised, for: 0.4, now: CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.mood.show(.happy, for: 1.2, now: CACurrentMediaTime())
        }
        log("gesture spin \(direction > 0 ? "left" : "right")")
    }
    @objc private func menuApart() { setApart(!isApart) }
    /// 选「跟随系统」清掉偏好；选某种语言就记住它。右键菜单每次打开都重建，所以只需重画表盘。
    @objc private func menuLanguage(_ sender: NSMenuItem) {
        let picked = (sender.representedObject as? String).flatMap(PetLanguage.init(rawValue:))
        PetLanguage.chosen = picked
        L10n.language = picked ?? .fromSystem()
        face.forceDirty = true
    }

    @objc private func menuFinish(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let f = Finish(rawValue: raw) else { return }
        setFinish(f)
        UserDefaults.standard.set(f.rawValue, forKey: Finish.defaultsKey)
        mood.show(.happy, for: 1.0, now: CACurrentMediaTime())
        log("menu finish \(raw)")
    }
    @objc private func menuStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = FaceStyle(rawValue: raw) else { return }
        setFaceStyle(st)
    }
    @objc private func menuTimer(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? Double else { return }
        startTimer(minutes: m)
    }
    @objc private func menuTimerCancel() { face.pomodoro.stop(); face.cancelTimer(); log("timer cancel") }
    @objc private func menuPomodoroStart() { startPomodoro() }
    @objc private func menuPomodoroStop() { stopPomodoro() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc func menuZoomIn() { zoom(by: 1.25) }
    @objc func menuZoomOut() { zoom(by: 0.8) }
    @objc func menuZoomMax() { zoomMax() }
    @objc func menuZoomDefault() { setZoom(width: Pet.defaultWidth) }
    @objc func menuResetOrientation() { resetOrientation() }
    @objc private func menuAgentToggle() {
        let result = ReceiverAgent.toggle()
        log("agent \(result.message)")
        mood.show(result.installed ? .happy : .wink, for: 1.2, now: CACurrentMediaTime())
    }
    override var acceptsFirstResponder: Bool { true }
    /// 系統「三指拖動」開啟時（預設常見），macOS 會把三指手勢合成成滑鼠拖拽，不再送 touches。
    /// 這種機器上把「拖拽」解釋成搬視窗（直播時除外），三指拖移就取代 ⌘-拖動。
    static var systemThreeFingerDrag: Bool {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        return domains.contains { UserDefaults(suiteName: $0)?.bool(forKey: "TrackpadThreeFingerDrag") ?? false }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 2.0: 把食譜網址拖到桌寵上（Shell/Apps/RecipeInput.swift；registerForDraggedTypes 在 applyShellSnapshotFlags）
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { recipeDragEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { recipePerformDrag(sender) }
    /// VoiceOver 用户「按下」＝进入/退出 CarPlay（和重按同一条路）
    override func accessibilityPerformPress() -> Bool { onForceEnter?(); return true }

    override func keyDown(with event: NSEvent) {
        endPoster()
        if overviewKeyDown(event) { return }   // 总览里 Esc 只收起、Return 套用、← → 挑
        if face.sayingHello, [49, 36, 53].contains(event.keyCode), face.skipHello(CACurrentMediaTime()) { return }   // 2.0 hello：空格、Return、Esc 跳过
        if shellKeyDown(event) { return }      // 2.0: Esc／↓ 回上一層、↑ 主畫面、C 控制中心
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 12: NSApp.terminate(nil)                  // ⌘Q
            case 43: menuSettings()                        // ⌘,
            case 24, 69: zoom(by: 1.25)                    // ⌘+ （主键区/小键盘）
            case 27, 78: zoom(by: 0.8)                     // ⌘−
            case 29: setZoom(width: Pet.defaultWidth)      // ⌘0
            default: break
            }
            return
        }
        switch event.keyCode {
        // Esc 只做「取消」，不再退出 App（退出是 ⌘Q／菜单）：先收提示，直播中就退出直播
        case 53:
            if event.isARepeat { return }
            if PermissionPrimer.active { PermissionPrimer.dismiss() }
            else if ClioTalkController.shared.isOpen { ClioTalkController.shared.close() }   // 2.0: 收起 ClioTalk
            else if face.onboardingActive { face.dismissOnboarding(); FaceOverview.pressToken += 1 }
            else if showingVideo { onCarPlayBack?() }   // 像車機的 Back 鍵，不退出 CarPlay（切回桌寵＝空格／選單）
        case 49: onSwitchSource?()                    // 空格
        case 18: setView(yaw: 0, pitch: 0.12, label: "front")      // 1 正面
        case 19: setView(yaw: .pi / 2, pitch: 0.18, label: "side") // 2 侧面
        case 20: setView(yaw: .pi, pitch: 0.15, label: "back")     // 3 背面
        case 21: setView(yaw: nil, pitch: 1.3, label: "above")     // 4 俯视
        case 123: if !showingVideo { setFaceStyle(face.style.next(-1)) }   // ← 上一个錶面
        case 124: if !showingVideo { setFaceStyle(face.style.next(1)) }    // → 下一个錶面
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - 窗口

