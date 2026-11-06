// 應用委派：選單、狀態項目、設定橋接——自 main.swift 拆出。
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menuBarTimer: MenuBarTimer?   // 2.0 P06: 計時器進行中，選單列圖示旁顯示 mm:ss（Shell/MenuBarTimer.swift）
    private var healthTimer: Timer?
    private var statsTimer: Timer?
    private var globalMagnify: Any?
    private var globalKeys: Any?
    private var globalScroll: Any?
    private var lastSiriAt = Date.distantPast
    private var siriHotKey: EventHotKeyRef?
    private var siriHotKeyAlt: EventHotKeyRef?
    private var siriHotKeyHandler: EventHandlerRef?
    var initialWidth: CGFloat = Pet.defaultWidth
    var endpoint: String?
    var initialApart = false
    var initialApartT: CGFloat?       // 快照：拆開到一半（0…1）
    var initialPart: AnatomyPart?     // 快照：釘住這一件的標籤
    var initialYaw: CGFloat?
    var origin: NSPoint?
    var initialPitch: CGFloat?
    var snapshotPath: String?
    var snapshotGlancePath: String?   // 官網素材：同一格畫面的「瞄一眼」版本
    var snapshotBlinkPath: String?    // 官網素材：同一格畫面的「閉眼」版本
    var forceHello = false            // 官網素材：不管偏好裡存的是什麼外觀，都寫一次 hello
    var benchSeconds: Double = 0
    var initialView: String?          // >0：跑 N 秒後印出渲染/CPU 統計並結束（效能基準）
    var lockedFace: Expression?
    var faceStyle: FaceStyle?
    var timerSeconds: Double?
    var musicTest: String?
    var showBanner = false
    var photosDir: String?
    var finish: Finish?
    var hourOverride: Double?
    var gazeTest: (x: CGFloat, y: CGFloat)?   // 快照用：模拟一个人脸样本，验证追人姿态
    var forceNear = false
    var sizeGiven = false
    var eventTest: String?
    var snapshotDelay = 2.5
    var window: PetWindow!
    var view: PetView!
    var client: ReceiverClient?
    private var pendingUsePhone: String?   // 还没连上 receiver 时先记住，WS 打开后补发
    private var pendingPairNew = false
    private var diagnosticsWaiter: ((String?) -> Void)?   // 等接收器回診斷報告（2 秒沒回就只交桌寵這邊的）
    private var diagnosticsTimeout: DispatchWorkItem?
    private var ssidDialogShown = false                    // 「Wi-Fi 名稱未知」時自動開一次 Wi-Fi 設定（自動讀不到才用）
    private var locationAsked = false                      // 這次執行已為 Wi-Fi 名稱出過定位說明卡
    private var pendingSiri = false
    /// F5 按住說話：按下是否已送出（沒送出就放開＝改送一次「按一下」）
    private var siriHold = SiriHoldKey()
    private var siriDownSent = false
    private var siriHoldWatch: Timer?
    /// 來電卡與這通電話是否已經把 CarPlay 叫到前面過（每通只叫一次）
    let callCard = PhoneCallCard()
    private var ringFrontedFor: String?
    private var receiverKickstarted = false
    private var switchingPhone = false     // 切换手机期间保持「连接中」，不要切成担心脸
    let health = VideoHealth(now: CACurrentMediaTime())
    private var userStopped = false
    private var isLive = false
    /// 手机上点了 HomePlay 图标（requestUI）：会话还在，只是画面让回给表面；重按／空格（👀）立刻回到 CarPlay
    private var carPlayInBackground = false
    /// 2.0 align D：手動切到 HomeView（硬按、空白鍵、藥丸兩顆、iPhone 點 HomePlay 圖示）之後 60 s 內，
    /// 重連出第一幀不自動把 CarPlay 拉回前面（不然剛切走又被拉回來）；手動切回 CarPlay 就解除
    private var homeLatchUntil: Double = 0
    private static let homeLatch: Double = 60
    private var quietAttach = false   // 启动时后台挂到 receiver：没画面就不弹连接卡，出画面自动显示
    private var handoffFreeze = false    // 插线稳定后切无线：冻住最后一帧，别把「会话结束」当断线
    private var handoffTimeoutWork: DispatchWorkItem?
    private var gazeFollow = UserDefaults.standard.bool(forKey: AppDelegate.gazeFollowKey)
    private var gazeOccludeWork: DispatchWorkItem?   // 被完全遮住后延迟关摄像头，避免切换全屏/Space 时反复启停
    private var micPrompted = false   // 本次进程只弹一次麦克风授权
    private var micWaiters: [(Bool) -> Void] = []
    private static let gazeFollowKey = "HomePlayGazeFollow"
    private static let roomLightKey = "HomePlayRoomLight"
    private let roomLight = RoomLightEstimator()
    private var roomLightStored = UserDefaults.standard.object(forKey: "HomePlayRoomLight") as? Bool
    var roomLightOn: Bool { roomLightStored ?? false }

    private func startRoomLight(announce: Bool) {
        if announce { NSApp.activate(ignoringOtherApps: true) }
        // 启动恢复不主动弹摄像头权限：只有用户之前明确开启且权限仍在才恢复。
        if !announce, AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            roomLightStored = false
            UserDefaults.standard.set(false, forKey: Self.roomLightKey)
            view.roomLightEnabled = false
            view.apply(roomLight: .neutral)
            log("room light not restored (camera not authorized)")
            return
        }
        view.roomLightEnabled = true
        roomLight.onSample = { [weak self] s in self?.view.apply(roomLight: s) }
        GazeTracker.shared.onLightFrame = { [weak self] buf, now in self?.roomLight.ingest(buf, at: now) }
        GazeTracker.shared.setTrackFaces(gazeFollow)
        if GazeTracker.shared.isRunning {
            log("room light shares camera")
            return
        }
        GazeTracker.shared.start { [weak self] ok, reason in
            guard let self else { return }
            if ok {
                log("room light started")
            } else {
                self.view.apply(roomLight: .neutral)
                self.roomLightStored = false
                UserDefaults.standard.set(false, forKey: Self.roomLightKey)
                self.view.roomLightEnabled = false
                log("room light camera failed: \(reason ?? "?")")
                if announce { self.showGazeDenied(reason) }
            }
        }
    }

    private func stopRoomLight() {
        view.roomLightEnabled = false
        roomLight.onSample = nil
        GazeTracker.shared.onLightFrame = nil
        view.apply(roomLight: .neutral)
        if gazeFollow {
            GazeTracker.shared.setTrackFaces(true)
        } else {
            GazeTracker.shared.stop()
        }
    }

    func toggleRoomLight() {
        roomLightStored = !roomLightOn
        UserDefaults.standard.set(roomLightStored!, forKey: Self.roomLightKey)
        if roomLightOn {
            withPermission(.camera) { [weak self] ok in
                guard let self else { return }
                if ok { self.startRoomLight(announce: true) }
                else {
                    self.roomLightStored = false
                    UserDefaults.standard.set(false, forKey: Self.roomLightKey)
                    self.rebuildMainMenu()
                }
            }
        } else {
            stopRoomLight()
        }
        rebuildMainMenu()
        log("room light \(roomLightOn ? "on" : "off")")
    }
    private var reconnectStep = 0
    private var reconnectTimer: Timer?
    private static let backoff: [Double] = [5, 10, 20, 30, 60]   // 照 MacPlay，之后一直 60
    /// WS 断开后先快探：接收器重启 1–3 s 就绪，别让桌宠干等 5 s 退避
    private static let fastProbeWindow: Double = 15, fastProbeInterval: Double = 0.3
    private var disconnectedAt: CFTimeInterval?   // 这一轮断线从何时起；出画面归零
    private var reconnectProbing = false
    private var lastStats = (t: CACurrentMediaTime(), recv: 0, dec: 0)
    private var rememberFrame = false

    /// --music "歌名|演出者|进度0..1"：快照测试用的固定状态
    static func testMusic(_ s: String) -> NowPlayingInfo {
        let f = s.components(separatedBy: "|")
        let p = f.count > 2 ? Double(f[2]) ?? 0 : 0
        return NowPlayingInfo(title: f[0], artist: f.count > 1 ? f[1] : "", duration: 100, position: max(0, min(1, p)) * 100,
                              playing: true, stamp: CACurrentMediaTime(), fixed: true)
    }

    /// 狀態列圖示：一個帶眼睛的圓角方塊（template，自動適應深色選單列）
    private static func statusIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let screen = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4, width: 13, height: 10.5),
                                      xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.4; screen.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 8.2, width: 2.3, height: 2.3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 9.7, y: 8.2, width: 2.3, height: 2.3)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// 激活时要有主菜单栏（否则菜单栏空白）。命令本体仍在右键/状态栏菜单里；
    /// 这里按 Mac 惯例放「关于 / 隐藏 / 结束」和两个最常用动作。
    func rebuildMainMenu() { installMainMenu() }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.about", "关于 HomePlay"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: L("menu.settings", "设置…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: settings.title)   // 2.0: P05 圖示也有標籤
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: L("menu.hidePet", "隐藏桌宠"), action: #selector(hidePet), keyEquivalent: "h")
        hide.target = self
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit", "退出 HomePlay"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let petItem = NSMenuItem(); main.addItem(petItem)
        let petMenu = NSMenu(title: L("menu.pet", "桌宠"))
        if let view {
            for (title, sel, key, mods) in [
                (view.carPlayAction.title, view.carPlayAction.action, "", NSEvent.ModifierFlags()),
                (L("menu.faceOverview", "显示表盘总览"), #selector(PetView.menuFaceOverview), "", NSEvent.ModifierFlags()),
                (L("menu.zoomIn", "放大"), #selector(PetView.menuZoomIn), "+", .command),
                (L("menu.zoomOut", "缩小"), #selector(PetView.menuZoomOut), "-", .command),
                (L("menu.zoomDefault", "实际大小"), #selector(PetView.menuZoomDefault), "0", .command),
                (L("menu.zoomMax", "放到最大"), #selector(PetView.menuZoomMax), "", NSEvent.ModifierFlags()),   // 2.0 P06：右键菜单的「最大」搬到这里
            ] as [(String, Selector, String, NSEvent.ModifierFlags)] {
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
                item.keyEquivalentModifierMask = mods
                item.target = view
                petMenu.addItem(item)
            }
        }
        let siri = NSMenuItem(title: L("menu.siri", "叫 iPhone 的 Siri（F5）"), action: #selector(menuSiri), keyEquivalent: "")
        siri.target = self
        petMenu.addItem(.separator())
        petMenu.addItem(siri)
        petItem.submenu = petMenu
        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            b.image = Self.statusIcon()
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = "HomePlay"
            b.target = self
            b.action = #selector(showStatusMenu)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        menuBarTimer = MenuBarTimer(item: item) { [weak self] in
            guard let end = self?.view?.face.timerEnd else { return nil }
            return end - CACurrentMediaTime()
        }   // 2.0 P06
        log("status item installed visible=\(item.isVisible) button=\(item.button != nil)")
    }

    @objc private func hidePet() {
        view.setOccluded(true)              // 隐藏期间停掉主循环与轮询；也在结束直播前拦住摄像头恢复
        if view.showingVideo { endCarPlay(reason: "hidePet") }   // 看不见就不该继续直播/解码
        NowPlayingPoller.shared.paused = true
        window?.orderOut(nil)               // 不结束 App：状态栏图标还在，随时显示回来
        // 明确隐藏＝马上关摄像头，不等遮挡防抖；用户看不见它时不该亮绿点。
        if gazeFollow {
            gazeOccludeWork?.cancel(); gazeOccludeWork = nil
            if GazeTracker.shared.setPaused(true) {
                appendDiag("gaze.log", "camera pause: pet hidden")
            }
        }
    }

    @objc private func showPet() {
        NSApp.unhide(nil)
        guard let w = window else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }), let vf = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: vf.maxX - w.frame.width - 24, y: vf.minY + 24))
        }
        w.makeKeyAndOrderFront(nil)
        view.setOccluded(false)             // 恢复主循环；实际遮挡状态下一次通知会校正
        gazeOccludeWork?.cancel(); gazeOccludeWork = nil
        resumeGazeIfPossible("pet shown")
    }

    @objc private func showStatusMenu() {
        guard let view, let b = statusItem?.button else { return }
        let menu = view.buildContextMenu()
        // 桌宠被隐藏或拖出所有屏幕时，右键已经够不着；状态栏给显示/隐藏开关
        let offscreen = !(window?.frame.intersects(NSScreen.screens.reduce(CGRect.null) { $0.union($1.visibleFrame) }) ?? false)
        let visible = (window?.isVisible ?? false) && !offscreen
        let toggle: NSMenuItem
        if visible {
            toggle = NSMenuItem(title: L("menu.hidePet", "隐藏桌宠"), action: #selector(hidePet), keyEquivalent: "")
        } else {
            toggle = NSMenuItem(title: L("menu.showPet", "显示桌宠"), action: #selector(showPet), keyEquivalent: "")
        }
        toggle.target = self
        menu.insertItem(toggle, at: 0)
        menu.insertItem(.separator(), at: 1)
        // 用螢幕座標在圖示下方展開：按鈕內部座標（非翻轉）指向上方會把選單彈出螢幕
        let anchor = NSPoint(x: b.window?.frame.midX ?? NSEvent.mouseLocation.x,
                             y: (b.window?.frame.minY ?? NSEvent.mouseLocation.y) - 4)
        view.startMenuTicker()
        menu.popUp(positioning: nil, at: anchor, in: nil)
        view.stopMenuTicker()
    }

    func sendCallGain(_ db: Double) { client?.sendCallGain(db) }

    private func sendPhoneMedia(_ c: MediaCommand) {
        let cmd: String
        switch c {
        case .play: cmd = "play"
        case .pause: cmd = "pause"
        case .playPause: cmd = "playPause"
        case .next: cmd = "next"
        case .previous: cmd = "previous"
        }
        client?.sendMedia(cmd)
    }

    /// F5 → 叫手机 Siri。Carbon 全局热键不需要「输入监控」权限（NSEvent 全局监听才需要）。
    /// 注意 macOS 默认把 F5 绑给听写：注册不会失败，按 F5 可能同时起系统听写；可在
    /// 系统设置 › 键盘 › 听写 里把快捷键换掉。注册结果写到 hotkey.txt 方便排查。
    private func installSiriHotKey() {
        // 按下與放開都要：F5 按住說話
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            let down = event.map { GetEventKind($0) == UInt32(kEventHotKeyPressed) } ?? true
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .homePlaySiriHotKey, object: nil, userInfo: ["down": down])
            }
            return noErr
        }, 2, &types, nil, &siriHotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x48504C59), id: 1)   // 'HPLY'
        let reg = RegisterEventHotKey(UInt32(kVK_F5), 0, id, GetApplicationEventTarget(), 0, &siriHotKey)
        // 听写键位的 F5 可能吞掉普通热键；⌥F5 作为无冲突的保底
        let id2 = EventHotKeyID(signature: OSType(0x48504C59), id: 2)
        let reg2 = RegisterEventHotKey(UInt32(kVK_F5), UInt32(optionKey), id2, GetApplicationEventTarget(), 0, &siriHotKeyAlt)
        let url = ReceiverLauncher.configURL().deletingLastPathComponent().appendingPathComponent("hotkey.txt")
        let text = "F5 handler=\(handlerStatus) register=\(reg) optionF5=\(reg2)\n"
        try? text.data(using: .utf8)?.write(to: url)
        log(text.trimmingCharacters(in: .newlines))
        NotificationCenter.default.addObserver(forName: .homePlaySiriHotKey, object: nil, queue: .main) { [weak self] note in
            self?.siriKey(down: note.userInfo?["down"] as? Bool ?? true)
        }
    }

    /// F5 按住說話：按下＝requestSiri 按下（開始聽）、放開＝按鍵放開（結束）。
    /// 還沒直播時先進 CarPlay，連上後依當時是否還按著補送按下或按一下（接收器在 RECORD 前也會先記著）。
    func siriKey(down: Bool) {
        // 2.0: CarPlay 沒在直播時 F5 交給 ClioTalk（直播中照舊給 iPhone 的 Siri；設定裡可關）
        if ClioTalkController.shared.handleF5(down: down, carPlayLive: isLive && !carPlayLocked, view: view) { return }   // 訪客鎖著 CarPlay：F5 當作沒有 CarPlay
        let now = CACurrentMediaTime()
        if down {
            if carPlayLocked { showCarPlayLock("siri key"); return }   // iPhone 的 Siri 念得出主人的訊息：跟 CarPlay 一起鎖
            guard siriHold.press(now: now) else { return }
            siriOrb.downAt = now; view?.face.forceDirty = true   // 錶面上的 Siri 球（Faces/Capsule.swift）
            siriDownSent = false
            appendDiag("siri.log", "Siri key down")
            siriHoldWatch?.invalidate()
            siriHoldWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.siriHold.overdue(now: CACurrentMediaTime()) else { return }
                log("F5 按住超过 \(Int(SiriHoldKey.maxHold)) 秒：自动放开")
                self.siriKey(down: false)
            }
            requestMicrophoneIfNeeded(announce: true, reason: "Siri") { [weak self] ok in
                guard let self else { return }
                guard ok else { _ = self.siriHold.release(); self.showMicDenied(); return }
                if self.client == nil || !self.isLive {
                    self.pendingSiri = true
                    log("叫 Siri：还没在直播，先进入 CarPlay")
                    self.enterCarPlay()
                } else if self.siriHold.held {
                    self.client?.sendSiri(down: true)
                    self.siriDownSent = true
                } else {
                    self.client?.sendSiri()   // 授權框期間就放開了：當成按一下
                }
            }
        } else {
            guard siriHold.release() else { return }
            siriOrb.upAt = now; view?.face.forceDirty = true
            siriHoldWatch?.invalidate(); siriHoldWatch = nil
            appendDiag("siri.log", "Siri key up")
            if siriDownSent {
                siriDownSent = false
                client?.sendSiri(down: false)
            }
        }
    }

    /// 接收器轉來的通話狀態：通話中顯示來電卡；響鈴時把 CarPlay 叫到前面（每通一次）
    private func applyCall(_ call: PhoneCallInfo) {
        callCard.model.hidden = !PersonalGate.allowed   // 訪客：卡片只寫「來電」，不露名字與號碼（接聽／拒接照舊）
        callCard.model.call = call
        if call.showsCard, let window {
            callCard.show(attachedTo: window)
        } else {
            callCard.hide()
        }
        guard call.isIncomingRing else {
            if !call.showsCard { ringFrontedFor = nil }
            return
        }
        let key = call.uuid ?? "ringing"
        guard ringFrontedFor != key else { return }
        ringFrontedFor = key
        guard !carPlayLocked else { log("来电响铃：访客锁着 CarPlay，不叫到前面"); return }
        log("来电响铃：把 CarPlay 叫到前面")
        if view.showingVideo || resumeFromBackground() { return }
        enterCarPlay()
    }

    @objc private func menuSiri() {
        let now = Date()
        guard now.timeIntervalSince(lastSiriAt) > 0.5 else { return }   // Carbon 与全局监听可能同时触发
        lastSiriAt = now
        // 诊断：F5/菜单每次触发都留一行，方便确认热键到底有没有到
        appendDiag("siri.log", "Siri trigger")
        if carPlayLocked { showCarPlayLock("menu siri"); return }
        requestMicrophoneIfNeeded(announce: true, reason: "Siri") { [weak self] ok in
            guard let self else { return }
            guard ok else { self.showMicDenied(); return }
            if self.client == nil || !self.isLive {
                self.pendingSiri = true
                log("叫 Siri：还没在直播，先进入 CarPlay")
                self.enterCarPlay()
            } else {
                self.client?.sendSiri()
            }
        }
    }

    // MARK: 跟随我（摄像头）

    private func startGazeFollow(announce: Bool) {
        // 用户从菜单打开时激活一下 App，摄像头授权框才不会落在后台看不见。
        if announce { NSApp.activate(ignoringOtherApps: true) }
        // 登录恢复不主动弹摄像头权限。
        if !announce, AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            gazeFollow = false
            UserDefaults.standard.set(false, forKey: Self.gazeFollowKey)
            view.setGazeEnabled(false)
            log("gaze follow not restored (camera not authorized)")
            return
        }
        GazeTracker.shared.onSample = { [weak self] s in self?.view.applyGaze(s) }
        GazeTracker.shared.setTrackFaces(true)
        GazeTracker.shared.start { [weak self] ok, reason in
            guard let self else { return }
            if ok {
                self.gazeFollow = true
                UserDefaults.standard.set(true, forKey: Self.gazeFollowKey)
                self.view.setGazeEnabled(true)
                log("gaze follow started")
                // 打开时如果正在直播、锁屏、或桌宠被遮住，先别让摄像头亮着；
                // 条件解除后由 showVideo/解锁/遮挡观察者恢复。
                if !self.view.gazeShouldRun, GazeTracker.shared.setPaused(true) {
                    let why = self.view.occluded ? "pet occluded" : "screen locked"
                    appendDiag("gaze.log", "camera pause: \(why)")
                }
            } else {
                self.gazeFollow = false
                UserDefaults.standard.set(false, forKey: Self.gazeFollowKey)
                self.view.setGazeEnabled(false)
                log("gaze follow failed: \(reason ?? "?")")
                if announce { self.showGazeDenied(reason) }
            }
        }
    }

    // MARK: 设置窗口（Settings/）用的桥：读状态、走菜单同一条路

    static let alwaysOnTopKey = "HomePlayAlwaysOnTop"
    static var alwaysOnTop: Bool { UserDefaults.standard.object(forKey: alwaysOnTopKey) as? Bool ?? true }

    struct SettingsSnapshot {
        var loginItem: Bool, loginAvailable: Bool, autoConnect: Bool, alwaysOnTop: Bool
        var finish: Finish, faceStyle: FaceStyle, viewMode: ViewMode
        var gazeFollow: Bool, followDegrees: Double, gazePitch: Double, roomLight: Bool
        var petWidth: Double
    }
    func settingsSnapshot() -> SettingsSnapshot {
        let bundled = Bundle.main.bundleIdentifier != nil
        return SettingsSnapshot(
            loginItem: bundled && SMAppService.mainApp.status == .enabled, loginAvailable: bundled,
            autoConnect: ReceiverAgent.isInstalled, alwaysOnTop: Self.alwaysOnTop,
            finish: view.model.finish, faceStyle: view.face.style, viewMode: view.viewMode,
            gazeFollow: gazeFollow, followDegrees: view.followDegrees, gazePitch: Double(view.gazePitchDegrees),
            roomLight: roomLightOn, petWidth: Double(view.window?.frame.width ?? Pet.defaultWidth))
    }
    /// 设置里的「大小」滑杆：拖动时即时缩放（以窗口中心为准，不跑出屏幕）
    func setPetWidth(_ w: Double) { view.resizeWindow(toWidth: CGFloat(w), anchorCenter: true) }
    /// 调 PetView 的菜单动作（同一份实现）；represented 放进 NSMenuItem.representedObject
    func settingsPerform(_ selector: String, _ represented: Any?) {
        let item = NSMenuItem()
        item.representedObject = represented
        let sel = NSSelectorFromString(selector)
        if view.responds(to: sel) { view.perform(sel, with: item) } else { log("settings: no action \(selector)") }
        rebuildMainMenu()
    }
    func setAlwaysOnTop(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.alwaysOnTopKey)
        window.level = on ? .floating : .normal
        log("always on top \(on)")
    }
    func setFollowDegrees(_ d: Double) {
        Aim.savedFollowDegrees = d
        view.followDegrees = Aim.savedFollowDegrees
    }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(app: self) }

    /// 2.0 首次設定、操作提示卡還開著就先等（設定裡已經講過怎麼配對；走完才進 CarPlay 的配對引導）
    private func autoEnterCarPlayAfterSetup() {
        if SetupFlow.active || SetupFlow.pending || Onboarding.active || PermissionPrimer.active {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.autoEnterCarPlayAfterSetup() }
            return
        }
        guard !view.showingVideo, client == nil else { return }
        log("first-run: auto-entering CarPlay for pairing guide")
        enterCarPlay()
    }

    /// 权限闸门：已允许直接放行；桌宠看得见就先出说明卡（PermissionPrimer），用户点「继续」才弹系统框；
    /// 看不见（隐藏、被遮住、直播中）就直接走系统框。被拒时卡片给「打开系统设置」，不再弹 NSAlert。
    func withPermission(_ k: PermissionKind, then: @escaping (Bool) -> Void) {
        let st = PermissionCenter.status(k)
        if st == .granted { then(true); return }
        let canShow = window?.isVisible == true && !view.occluded && !view.showingVideo
        if canShow {
            view.wakeFromPosterForGuide()
            PermissionPrimer.present(k) { [weak self] ok in
                if ok, k == .inputMonitoring { SystemKeyTap.retryAfterGrant() }
                self?.rebuildMainMenu()
                then(ok)
            }
            log("permission primer \(k.rawValue) (\(st == .denied ? "denied" : "intro"))")
            return
        }
        guard st == .notDetermined else { then(false); return }
        NSApp.activate(ignoringOtherApps: true)
        PermissionCenter.request(k) { ok in
            if ok, k == .inputMonitoring { SystemKeyTap.retryAfterGrant() }
            then(ok)
        }
    }

    /// 卡片换阶段时给表情：说明＝好奇，等系统框＝专注，允许＝笑，拒绝＝担心
    private func wirePermissionMoods() {
        PermissionPrimer.onPhase = { [weak self] p in
            guard let self else { return }
            let now = CACurrentMediaTime()
            switch p {
            case .intro: self.view.mood.show(.idle, for: 2.5, now: now)
            case .waiting: self.view.mood.show(.thinking, for: 1.5, now: now)
            case .granted: self.view.mood.show(.happy, for: 1.6, now: now)
            case .denied: self.view.mood.show(.worried, for: 2.0, now: now)
            }
        }
        // 第一次的操作提示收起后：F5 还接不住、也没问过「输入监控」，就接着说明一次
        Onboarding.onDismiss = { [weak self] in
            guard let self, !SystemKeyTap.isActive,
                  PermissionCenter.status(.inputMonitoring) == .notDetermined else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.withPermission(.inputMonitoring) { _ in } }
        }
    }

    func toggleGazeFollow() {
        if gazeFollow {
            gazeFollow = false
            UserDefaults.standard.set(false, forKey: Self.gazeFollowKey)
            GazeTracker.shared.setTrackFaces(false)
            if !roomLightOn { GazeTracker.shared.stop() }
            view.setGazeEnabled(false)
        } else {
            withPermission(.camera) { [weak self] ok in
                guard let self else { return }
                if ok { self.startGazeFollow(announce: true) } else { self.rebuildMainMenu() }
            }
        }
    }

    static func micStatusText(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "granted"
        case .notDetermined: return "not-requested"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private func writeMicStatus(_ text: String) {
        let url = ReceiverLauncher.configURL().deletingLastPathComponent().appendingPathComponent("mic-permission.txt")
        try? text.data(using: .utf8)?.write(to: url)
    }

    /// 最小权限：只在用户真正进入 CarPlay（非后台挂接）或主动叫 Siri 时才申请麦克风。
    private func requestMicrophoneIfNeeded(announce: Bool, reason: String, then: ((Bool) -> Void)? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            writeMicStatus("granted")
            then?(true)
        case .denied, .restricted:
            writeMicStatus(Self.micStatusText(status))
            then?(false)
        case .notDetermined:
            if let then { micWaiters.append(then) }
            guard !micPrompted else { return }   // 同一轮授权框还在：等它的结果一起回调
            micPrompted = true
            if announce, window?.isVisible == true, !view.occluded, !view.showingVideo {
                // 先在屏幕上说明，用户点「继续」才弹系统框（PermissionPrimer）
                withPermission(.microphone) { [weak self] ok in
                    guard let self else { return }
                    self.micPrompted = false
                    self.writeMicStatus(ok ? "granted" : "denied")
                    log("microphone permission \(ok ? "granted" : "denied") for \(reason) (primer)")
                    let waiters = self.micWaiters
                    self.micWaiters.removeAll()
                    waiters.forEach { $0(ok) }
                }
                return
            }
            if announce { NSApp.activate(ignoringOtherApps: true) }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.writeMicStatus(ok ? "granted" : "denied")
                    log("microphone permission \(ok ? "granted" : "denied") for \(reason)")
                    let waiters = self.micWaiters
                    self.micWaiters.removeAll()
                    waiters.forEach { $0(ok) }
                }
            }
        @unknown default:
            writeMicStatus("unknown")
            then?(false)
        }
    }

    var micStatusLabel: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return L("mic.status.on", "已允许")
        case .notDetermined: return L("mic.status.ask", "首次进入 CarPlay 时询问")
        case .denied, .restricted: return L("mic.status.off", "已关闭")
        @unknown default: return L("mic.status.off", "已关闭")
        }
    }

    private func showMicDenied() {
        if window?.isVisible == true, !view.occluded, !view.showingVideo {
            withPermission(.microphone) { _ in }; return    // 拒绝卡：给「打开系统设置」
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("mic.denied.title", "麦克风权限未开启")
        a.informativeText = L("mic.denied.body", "CarPlay 画面不受影响；ClioTalk、iPhone 的 Siri 和电话通话需要麦克风。请在系统设置 › 隐私与安全性 › 麦克风里允许 HomePlay。")
        a.addButton(withTitle: L("mic.openSettings", "打开系统设置"))
        a.addButton(withTitle: L("gaze.denied.ok", "好"))
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func showMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            requestMicrophoneIfNeeded(announce: true, reason: "menu") { [weak self] ok in
                if !ok { self?.showMicDenied() }
            }
        case .denied, .restricted:
            showMicDenied()
        case .authorized:
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = L("mic.allowed.title", "麦克风已允许")
            a.informativeText = L("mic.allowed.body", "ClioTalk、CarPlay 通话和 iPhone 的 Siri 可以使用麦克风；屏幕画面与本地播放不受影响。")
            a.addButton(withTitle: L("gaze.denied.ok", "好"))
            a.runModal()
        @unknown default:
            showMicDenied()
        }
    }

    private func showGazeDenied(_ reason: String?) {
        if (reason == nil || reason == "camera permission denied"),
           window?.isVisible == true, !view.occluded, !view.showingVideo {
            withPermission(.camera) { _ in }; return         // 拒绝卡：给「打开系统设置」
        }
        let a = NSAlert()
        a.messageText = L("gaze.denied.title", "需要相机权限")
        a.informativeText = (reason == nil || reason == "camera permission denied")
            ? L("gaze.denied.body", "在系统设置 › 隐私与安全性 › 相机里允许 HomePlay，跟随我或房间光线才能使用相机。画面只在本机处理，不保存。")
            : (reason ?? "")
        a.addButton(withTitle: L("gaze.denied.ok", "好"))
        a.runModal()
    }

    func applicationWillTerminate(_ note: Notification) {
        PhoneNowPlayingBridge.shared.clear()
        if AirDrop.shutdown() { Thread.sleep(forTimeInterval: 0.3) }   // 訪客臨時接收開著就先還原可被發現設定；「收 AirDrop」暫停中就送恢復 CarPlay，等它送出去
        // 先把手機會話收乾淨（receiver 收到 stop 會結束 CarPlay 並退出），再關本地進程。
        // applicationWillTerminate 之後主隊列不再跑，所以這裡短暫等 receiver 收下命令。
        reconnectTimer?.invalidate(); reconnectTimer = nil
        healthTimer?.invalidate(); statsTimer?.invalidate()
        GazeTracker.shared.stop()   // 退出时立刻关摄像头（绿点灭掉）
        // 只有真的在直播時才向 receiver 發 stop；閒置退出不要誤殺 login item 的常駐 receiver
        if !Self.isDiagnosticRun, isLive || view.showingVideo, let c = client {
            c.onLive = nil; c.onFrameReceived = nil; c.onText = nil
            c.requestTeardown(reason: "appQuit")
            Thread.sleep(forTimeInterval: 0.45)
        }
        ReceiverLauncher.stop()
        if rememberFrame, let f = window?.frame { WindowFrameStore.save(f) }   // 刚拖完就退出也不丢位置
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        wirePermissionMoods()
        if HomePlayState.isolated { log("rehearsal state: Application Support/\(HomePlayState.name), agent \(ReceiverAgent.label)") }
        tightenLogPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ActivityBridge.shared.start() }   // iPhone 即時動態：沒有 ActivityKit、沒有活動都只是空清單，不影響桌寵
        if let i = CommandLine.arguments.firstIndex(of: "--iphone-activity") {   // 截图／示範：假一則 iPhone 活動
            let next = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
            ActivityBridge.shared.applyDemo(appName: (next?.hasPrefix("--") == false ? next! : L("la.iphone.demo", "外卖")))
        }
        // 除錯／截图：开机 3 秒后在桌宠上弹出右键菜单（--show-menu）
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let v = self.view else { return }
                if let w = self.window, let main = NSScreen.screens.first {
                    w.setFrameOrigin(NSPoint(x: main.frame.midX - w.frame.width / 2, y: main.frame.midY - w.frame.height / 2))
                }
                v.buildContextMenu().popUp(positioning: nil, at: NSPoint(x: v.bounds.midX, y: v.bounds.midY), in: v)
            }
        }
        // 除錯／截图：开机直接打开设置的某一页（--open-settings general|appearance|carplay|camera|permissions）
        if CommandLine.arguments.contains("--clock-look-panel") {   // 截图：打开「字体与颜色」面板
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.view.menuClockLook(nil) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--open-settings") {
            let name = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "general"
            let pane = SettingsSection(rawValue: name) ?? .general
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }   // 截图：深色外观
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { SettingsWindowController.show(app: self, pane: pane) }
            if let j = CommandLine.arguments.firstIndex(of: "--settings-out"), j + 1 < CommandLine.arguments.count {   // 2.0 第六輪：拍下那一頁（原生表單驗收）
                let out = CommandLine.arguments[j + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if let v = SettingsWindowController.shared?.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                    exit(0)
                }
            }
        }
        if CommandLine.arguments.contains("--nowplaying-selftest") {
            let ok = PhoneNowPlayingBridge.shared.selftest()
            log(ok ? "nowplaying selftest OK" : "nowplaying selftest FAIL")
            exit(ok ? 0 : 1)
        }
        // 基准/截图不碰真实 LaunchAgent、配置和麦克风权限：它们是诊断进程，不能改用户的常驻接收器。
        let diagnosticRun = benchSeconds > 0 || snapshotPath != nil || Self.isDiagnosticRun || Self.perfProbe
        if !diagnosticRun {
            ReceiverAgent.migrateIfNeeded()   // 升级：把 LaunchAgent 指到新布局的接收器路径
            ReceiverLauncher.ensureConfigFile()   // 后台接收器先起时也要有配置
            // 已配过手机：把后台接收器补成开机常驻（老用户升级后也自动进入「一次配好、以后自动」）。
            // 用户明确在菜单里关过就不装，尊重选择。
            let startupCfg = ReceiverLauncher.loadConfig()
            if !startupCfg.phone.isEmpty {
                _ = ReceiverAgent.autoEnableIfNeeded(reason: "saved iPhone")
            }
            // 作业曾因端口冲突 exit(0) 会一直停着；开机/启动时轻轻催一下（已在跑则无操作）。
            if ReceiverAgent.isInstalled { _ = ReceiverAgent.kickstart() }
        }
        // 麦克风不再在启动时索取：只在用户第一次真正进入 CarPlay / 主动叫 Siri 时申请。
        // 这里只把当前状态写给接收器做诊断，不触发系统授权框。
        if !diagnosticRun {
            writeMicStatus(Self.micStatusText(AVCaptureDevice.authorizationStatus(for: .audio)))
        }
        // 上次的位置与大小（给了 --at / --size / --snapshot 就不动它，也不写回）
        let remember = origin == nil && !sizeGiven && snapshotPath == nil
        Pet.aspect = Pet.aspect(for: ViewMode.saved)   // 挂墙时窗口只框屏幕模组
        if ProductShot.on { Pet.aspect = ProductShot.aspect }   // 2.0 device: 官圖畫布 2576×2061
        rememberFrame = remember
        let restored = remember ? WindowFrameStore.restore(WindowFrameStore.load(), visible: NSScreen.screens.map(\.visibleFrame)) : nil
        // 第一次打開（沒有記住的大小）：開大一點（380 pt），設定引導的字才清楚好讀；之後照使用者調的大小
        let firstWidth = (restored == nil && !sizeGiven) ? max(initialWidth, 380) : initialWidth
        let size = restored?.size ?? NSSize(width: firstWidth, height: firstWidth / Pet.aspect)
        window = PetWindow(size: size)
        view = PetView(frame: NSRect(origin: .zero, size: size), initialApart: initialApart, yaw: initialYaw, pitch: initialPitch)
        if let t = initialApartT { view.setInitialApart(t) }
        if let p = initialPart { view.pinAnatomy(p) }
        window.contentView = view
        view.updateFaceScale()
        AirDrop.start(view: view)   // AirDrop 收件卡片、上次沒還原的可被發現設定（Shell/AirDrop/）
        RemoteServer.shared.view = view   // 2.0 idle: 網頁串流（Remote/）；預設關，設定 › iPhone 與 iPad 打開才開
        if RemoteStore.enabled && !diagnosticRun || CommandLine.arguments.contains("--remote-test") { RemoteServer.shared.startFromLaunch() }
        SideShowServer.shared.face = view.face   // SideShow（SideShow/）：預設關，螢幕上的設定 › SideShow 打開才開
        SideShowServer.shared.store.onChange = { [weak self] in DispatchQueue.main.async { self?.view.face.forceDirty = true } }
        if SideShowStore.enabled && !diagnosticRun { SideShowServer.shared.start() }
        if let lockedFace { view.lockFace(lockedFace) }
        if let finish { view.setFinish(finish) }   // 只给这次用，不写进偏好
        if let photosDir { view.face.photos = PhotoShelf(folder: URL(fileURLWithPath: photosDir, isDirectory: true)) }
        else if let saved = UserDefaults.standard.string(forKey: PetView.photoFolderKey), FileManager.default.fileExists(atPath: saved) {
            view.face.photos = PhotoShelf(folder: URL(fileURLWithPath: saved, isDirectory: true))   // 偏好设定里选的照片资料夹
        }
        if let eventTest { view.face.calendarTile = Self.testEvent(eventTest) }
        FamilyProfiles.migrateAtLaunch(); FamilyProfiles.applyDemo()   // 2.0 家人檔案：既有使用者的主人＝第一位家人（不搬資料）；--demo-profiles 示範
        // 2.0 首次設定：全新（沒有任何設定）才排上，排在操作提示卡前面（Setup/SetupFlow.swift）；判斷要在 hello 記下「看過」之前
        if snapshotPath == nil, !Self.isDiagnosticRun, SetupFlow.demo == nil,
           SetupFlow.shouldAutoShow(configExists: FileManager.default.fileExists(atPath: ReceiverLauncher.configURL().path)) {
            SetupFlow.pending = true
            log("first-run: setup flow armed")
        }
        if Onboarding.forced || (snapshotPath == nil && !Onboarding.done) { view.face.armOnboarding() }   // hello 写完再出
        // 2.0: --demo-official 的主畫面照官方圖：後面是「照片」錶面（Portraits），不是這台 Mac 上次選的錶面
        if faceStyle == nil, OfficialDemo.on, ["--home", "--library", "--app"].contains(where: CommandLine.arguments.contains) { faceStyle = .photos }
        if snapshotPath == nil, benchSeconds == 0, !forceHello, !Self.isDiagnosticRun, HelloIntro.takeFirstLaunch() { view.face.beginHello(CACurrentMediaTime(), local: true) }   // 2.0 hello：HomePlay 2 第一次打開（設定卡已排上：hello 停住當它的背景）
        if let faceStyle { view.setFaceStyle(faceStyle, remember: false) }
        if forceHello { view.face.beginHello(CACurrentMediaTime()) }   // 官網素材：從這裡重新計時，逐格才穩定
        if let timerSeconds { view.face.startTimer(seconds: timerSeconds) }
        if let musicTest { view.face.setNowPlaying(Self.testMusic(musicTest)) }
        if showBanner { view.face.showBanner() }
        view.applyShellSnapshotFlags()   // 2.0: --home --app --control-center --live-activity --demo-timers
        HelloProduct.startIfAsked(view)   // 2.0 hello：--hello-product 逐格拍產品版（Hello/HelloProduct.swift）
        if let out = arg("--screen-png") {   // 2.0: 只出 1024² 螢幕平面圖（不等 RealityKit），對照設計用
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { exit(2) }
                self.view.face.forceDirty = true
                if let n = arg("--frames").flatMap({ Int($0) }) { HPFrames.run(self.view.face, out: out, count: n); exit(0) }   // 2.0: 動效包逐格（Design/HPFrames.swift）
                let img = CarPlayDemo.render(self.view.face, now: CACurrentMediaTime()) ?? self.view.face.render()   // --demo-carplay：假的 CarPlay 畫面＋膠囊
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
        }
        MessagesApp.shared.install()     // 2.0: 監看新訊息（頂端藥丸、眼睛瞄一下）
        if !Self.isDiagnosticRun { PhoneAppProvider.shared.refreshInBackground() }   // iPhone 的 CarPlay App：啟動後背景掃一次（不等打開資源庫）
        if let hourOverride { view.face.hourOverride = hourOverride }
        if forceNear { view.forceNear = true }
        view.onTouch = { [weak self] x, y, down in self?.client?.sendTouch(x: x, y: y, down: down) }
        view.onTouches = { [weak self] c in self?.client?.sendTouches(c) }   // CarPlay 兩指：只有實驗旗標開著才會呼叫（Shell/TouchInput.swift）
        view.carVideo.send = { [weak self] s in self?.client?.sendRaw(s) }
        if !Self.isDiagnosticRun, snapshotPath == nil { CarPlayAirDropPause.shared.send = { [weak self] s in self?.client?.sendRaw(s) } }   // 控制中心「收 AirDrop」：暫停／恢復 CarPlay
        CarPlayAirDropPause.shared.showingCarPlay = { [weak self] in self?.view.showingVideo ?? false }
        // Mac 內建 AirPlay 接收器在播影片：桌寵好奇地看著那個視窗（只讀視窗清單，不錄畫面）
        if snapshotPath == nil, benchSeconds == 0 {
            AirPlayWatch.onChange = { [weak self] on in
                guard let self else { return }
                let now = CACurrentMediaTime()
                if on { self.view.mood.show(.thinking, for: 6 * 3600, now: now) } else { self.view.mood.show(.happy, for: 1.2, now: now) }
                log("AirPlay video on this Mac: \(on)")
            }
            AirPlayWatch.start()
        }
        view.carVideo.onStarted = { [weak self] in
            guard let self else { return }
            _ = self.resumeFromBackground()   // CarPlay 在後台時，影片一來就把它叫回前面
            log("car video started")
        }
        view.carVideo.onEnded = { [weak self] in
            self?.client?.requestKeyframe()   // 回到 CarPlay：要一張關鍵幀，畫面馬上回來
            log("car video ended")
        }
        view.onToggleLive = { [weak self] in self?.toggle() }
        view.onSwitchSource = { [weak self] in self?.switchSource() }
        view.onCarPlayKnob = { [weak self] k in self?.client?.sendKnob(k) }
        view.onCancelConnect = { [weak self] in self?.cancelConnect() }
        view.onForceEnter = { [weak self] in self?.enterCarPlay() }
        view.onSelectPhone = { [weak self] address in self?.switchPhone(to: address) }
        view.onPairNewPhone = { [weak self] in self?.pairNewPhone() }
        view.onCopyDiagnostics = { [weak self] in self?.copyDiagnostics() }
        view.onSetWiFi = { [weak self] ssid, password in
            ReceiverLauncher.saveWiFi(ssid: ssid, passphrase: password)
            CarPlayWiFi.ssid = ssid
            CarPlayOverlayState.wifiHelp = false       // 密码刚存过：排障卡片收起，给连接一次机会
            CarPlayOverlayState.wifiNeedsPassword = false
            self?.client?.sendWiFi(ssid: ssid, passphrase: password)
            log("Wi-Fi settings updated (values not logged)")
        }
        view.onForgetPhone = { [weak self] address in
            ReceiverLauncher.forgetPhone(address)
            if let self {
                self.switchingPhone = true
                CarPlayOverlayState.wifiHelp = false
                CarPlayOverlayState.wifiNeedsPassword = false
                CarPlayOverlayState.needsTrust = false
                CarPlayPhoneBook.phones.removeAll {
                    CarPlayPhoneBook.normalize($0.address) == CarPlayPhoneBook.normalize(address)
                }
                if CarPlayPhoneBook.isCurrent(address) { CarPlayPhoneBook.current = nil }
                self.client?.sendForgetPhone(address: address)
            }
            log("forgot iPhone (address not logged)")
        }
        view.onRestorePhones = { [weak self] in
            ReceiverLauncher.restoreIgnoredPhones()
            self?.client?.sendRestorePhones()
            log("restored ignored iPhones")
        }
        view.decoder.onDecoded = { [weak self] in self?.health.frameDecoded(now: CACurrentMediaTime()) }
        view.decoder.onDecodeError = { [weak self] in
            guard let self else { return }
            self.act(self.health.decodeError(now: CACurrentMediaTime()), why: "解码报错")
        }
        // 健康检查与统计只在直播时跑：不在直播就不该每 250 ms 叫醒一次
        PhoneNowPlayingBridge.shared.configure()
        PhoneNowPlayingBridge.shared.onUpdate = { [weak self] info in
            if PhoneNowPlayingBridge.shared.active, !NowPlayingSource.phoneShown { return }   // 2.0 家人檔案：偏好 Mac 而 Mac 在播：手機的更新先不蓋上去
            self?.view.face.setNowPlaying(info)
        }
        PhoneNowPlayingBridge.shared.onCommand = { [weak self] cmd in self?.sendPhoneMedia(cmd) }
        PhoneNowPlayingBridge.shared.onSeek = { [weak self] ms, track in self?.client?.sendSeek(positionMs: ms, trackId: track) }
        view.onVideoState = { [weak self] on in
            guard let self else { return }
            if on { self.startLiveTimers() } else { self.stopLiveTimers() }
            self.rebuildMainMenu()   // 主菜单的「进入/退出 CarPlay」跟着状态走
        }
        if let origin { window.setFrameOrigin(origin) }
        else if let restored { window.setFrameOrigin(restored.origin) }
        else if let vf = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 24))
        }
        installMainMenu()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        if remember { watchWindowFrame() }
        if snapshotPath == nil && benchSeconds == 0 { watchOcclusion() }
        // 換螢幕／拔掉外接螢幕後，如果桌寵整個跑到可見區域外，把它拉回來
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let w = self.window else { return }
            let visible = NSScreen.screens.map(\.visibleFrame)
            guard !visible.contains(where: { $0.intersects(w.frame) }) else { return }
            guard let vf = NSScreen.main?.visibleFrame else { return }
            w.setFrameOrigin(NSPoint(x: vf.maxX - w.frame.width - 24, y: vf.minY + 24))
            log("window rescued to visible screen")
        }
        // 狀態列常駐入口：桌寵被全螢幕蓋住或拖丟時，選單／關於／結束仍找得到（accessory App 沒有主選單列）
        if snapshotPath == nil && benchSeconds == 0 { installStatusItem() }
        // 全局 .magnify 监听在架构上收不到非激活面板的手势（magnify=30 是 AppKit 给目标 App
        // 合成的）；真正的全局捏合是下面的 MultitouchSupport 接触帧（TrackpadPinch），
        // 本地 magnify 只在 App 已激活时作为后备，⌥＋双指滚动仍然可用。
        if snapshotPath == nil && benchSeconds == 0 {
            globalMagnify = NSEvent.addGlobalMonitorForEvents(matching: [.magnify]) { [weak self] e in
                guard let self, let w = self.window else { return }
                let inside = w.frame.contains(NSEvent.mouseLocation)
                appendDiag("gesture.log", "global magnify mag=\(e.magnification) inside=\(inside) mouse=\(NSEvent.mouseLocation) frame=\(w.frame)")
                guard inside else { return }
                DispatchQueue.main.async { self.view.magnify(with: e) }
            }
            if globalMagnify == nil { log("global magnify monitor unavailable (need click-to-focus)") }
            installSiriHotKey()
            callCard.model.onAction = { [weak self] action in
                log("来电卡：\(action.rawValue)")
                self?.client?.sendTelephony(action)
            }
            // F5（聽寫鍵）：普通 keyDown/Carbon 熱鍵都看不到（實證），用會話級 CGEventTap
            // 抓 keyDown 176 ／ NX_SYSDEFINED 輔助鍵。輸入監控授權過了才裝得上；裝不上就
            // 退回 ⌥F5（Carbon）。要確認鍵盤發的是哪個鍵碼時，用 HOMEPLAY_DIAG_KEYS=1 啟動。
            SystemKeyTap.setSiriHandler { [weak self] down in self?.siriKey(down: down) }
            if SystemKeyTap.install() {
                appendDiag("syskeys.log", "tap installed (dictation key=\(SystemKeyTap.siriKeyCode))")
            } else {
                // 授权可能是启动后才给的：装不上时后台线程会继续重试一分钟。
                appendDiag("syskeys.log", "tap create failed (need Input Monitoring; retrying)")
                log("F5 系统键 tap 暂时装不上（缺输入监控）；⌥F5 仍可用")
            }
            // 輸入監控拿到后，普通 F5（keyDown 96）也會走到這裡。只認這一顆，其餘按鍵不落地。
            appendDiag("monitors.txt", "AXTrusted=\(AXIsProcessTrusted()) magnify=\(globalMagnify != nil) tcc")
            globalKeys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
                guard e.keyCode == 96, e.type == .keyUp || !e.isARepeat else { return }
                let down = e.type == .keyDown
                DispatchQueue.main.async { self?.siriKey(down: down) }
            }
            appendDiag("monitors.txt", "keys=\(globalKeys != nil) AXTrusted=\(AXIsProcessTrusted())")
            // ⌥＋雙指滾動＝縮放（不點桌寵也能用）：滾輪事件按指針所在窗口投遞，全局監視攔
            // 「鼠標在桌寵上＋按著 option」的縱向滾動。App 自己收到時 scrollWheel 已處理。
            globalScroll = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] e in
                guard let self, let w = self.window else { return }
                guard e.modifierFlags.contains(.option) else { return }
                guard w.frame.contains(NSEvent.mouseLocation) else { return }
                let dy = e.scrollingDeltaY
                guard dy != 0 else { return }
                appendDiag("gesture.log", "global opt-scroll dy=\(dy) precise=\(e.hasPreciseScrollingDeltas)")
                DispatchQueue.main.async {
                    self.view.resizeWindow(toWidth: self.view.bounds.width * (1 + CGFloat(dy) * 0.01),
                                           anchorCenter: true)
                }
            }
            appendDiag("monitors.txt", "scroll=\(globalScroll != nil)")
            // 真正的全局双指捏合：NSEvent.magnify 只投递给已激活的 App，桌宠是
            // .nonactivatingPanel 收不到。MultitouchSupport 直接读接触帧，不用点、
            // 不抢焦点；指针在桌宠上才缩放，失败就继续用 ⌥＋双指滚动。
            let mtDevices = TrackpadPinch.shared.start()
            if mtDevices > 0 {
                TrackpadPinch.shared.onMagnify = { [weak self] factor in
                    guard let self, let w = self.window else { return }
                    guard w.frame.contains(NSEvent.mouseLocation), !TouchInput.fingerDown else { return }   // 觸控的捏合走手勢辨識器
                    TrackpadPinch.shared.markApplied()
                    self.view.resizeWindow(toWidth: self.view.bounds.width * factor, anchorCenter: true)
                }
                appendDiag("gesture.log", "MT pinch monitor started devices=\(mtDevices)")
            } else {
                appendDiag("gesture.log", "MT pinch unavailable (fallback: option+scroll)")
                log("触控板捏合监视装不上（MultitouchSupport 不可用）；⌥＋双指滚动仍可用")
            }
        }
        // 房间光线：默认开；快照/基准不碰摄像头，保持可复现的棚拍环境。
        if snapshotPath == nil, benchSeconds == 0, roomLightOn {
            startRoomLight(announce: false)
        }
        // 2.0: 「谁在看」借「跟随我」的相机；--people-probe 是隐藏的阈值校准工具（只打印相似度数字）
        if snapshotPath == nil, benchSeconds == 0 {
            WhoIsLooking.shared.install(app: self)
            if CommandLine.arguments.contains("--people-probe") { WhoIsLooking.shared.startProbe(app: self) }
        }
        // 上次打开过「跟随我」：登录后自动恢复（权限已授权时不会再弹窗）
        if snapshotPath == nil, benchSeconds == 0, gazeFollow {
            startGazeFollow(announce: false)
        }
        if let v = initialView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.view.applyViewPreset(v) }
        }
        if let g = gazeTest {
            view.setGazeEnabled(true)
            view.applyGaze(GazeTracker.Sample(x: g.x, y: g.y, roll: 0, size: 0.3, present: true))
        }
        if benchSeconds > 0 {
            view.face.cancelHello()            // 基準不量啟動的 hello 動畫
            view.face.dismissOnboarding()
            startBench()
        }
        // 给截图与合成事件用：窗口在全局坐标（左上原点）的位置
        if let mainH = NSScreen.screens.first?.frame.height {
            let f = window.frame
            log("window \(Int(f.minX)) \(Int(mainH - f.maxY)) \(Int(f.width)) \(Int(f.height))")
        }
        if let endpoint { connect(endpoint) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.view.logProbes() }
        // 首次使用（没配过手机）：hello 提示收起后自动进一次 CarPlay，让接收器的首连
        // 引导卡（插线点信任 / 蓝牙配对 / 等待 iPhone）自然出现——新用户不用知道
        // 「重按」这个手势。已配过手机的不打扰（想看画面随时重按）；用户主动「忘记」
        // 过手机（ignoredPhones 非空）也不自动进场，避免每次启动都弹配对。
        let cfg = ReceiverLauncher.loadConfig()
        let freshInstall = !FileManager.default.fileExists(atPath: ReceiverLauncher.configURL().path)
        if snapshotPath == nil, benchSeconds == 0, endpoint == nil, !Self.perfProbe,
           freshInstall || (cfg.phone.isEmpty && cfg.ignoredPhones.isEmpty) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in self?.autoEnterCarPlayAfterSetup() }
        }
        // 已经配过手机：安静地挂到后台 receiver 上。没画面就不弹「连接中」，
        // iPhone 一旦连上就自动出画面——打开桌宠即可用，不用再重按。
        if snapshotPath == nil, benchSeconds == 0, endpoint == nil, !Self.perfProbe, !cfg.phone.isEmpty, Onboarding.done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.view.showingVideo, self.client == nil, !self.userStopped else { return }
                let target = "ws://127.0.0.1:\(ReceiverLauncher.port())"
                self.endpoint = target
                log("auto-attach: waiting for iPhone in background")
                self.ensureReceiver { [weak self] in
                    guard let self, !self.view.showingVideo, self.client == nil else { return }
                    self.connect(target, quiet: true)
                }
            }
        }
        // 驗證海報補丁：等 3D 真的卸下後只換眼睛（瞄一眼）；補丁上去後掛回 3D 拍一張真的，兩張比對
        if let dir = ProcessInfo.processInfo.environment["HOMEPLAY_PATCH_TEST"] {
            var phase = 0, patchesAt = 0
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] tm in
                guard let self else { return }
                if phase == 0, CACurrentMediaTime() > 4, self.view.debugDetached {
                    phase = 1; patchesAt = self.view.patches3D
                    if ProcessInfo.processInfo.environment["HOMEPLAY_PATCH_TEST_BIG"] != nil {
                        // 大範圍變化（連線過場蓋滿整面）：不該補丁，要掛回 3D 重畫；1.5 秒後記錄結果並拍一張
                        CarPlayOverlayState.forced = true; self.view.face.forceDirty = true
                        tm.invalidate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            log("patch-test big: patches +\(self.view.patches3D - patchesAt), detached \(self.view.debugDetached)")
                            self.view.captureSnapshot { img in
                                if let img { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/big.png")) }
                                exit(0)
                            }
                        }
                        return
                    }
                    Face.glanceOverride = true; self.view.face.forceDirty = true
                } else if phase == 1, self.view.patches3D > patchesAt {
                    phase = 2; tm.invalidate()
                    self.view.captureSnapshot { img in
                        if let img { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/real.png")) }
                        exit(0)
                    }
                } else if phase == 1, !self.view.debugDetached { phase = 0; Face.glanceOverride = false }   // 中途掛回去了：重來
            }
            RunLoop.main.add(t, forMode: .common)
        }
        if let snapshotPath {
            // 自检出图：等弹簧停稳，存一张 RealityKit 快照（透明底）就退出。
            // --snapshot-glance／--snapshot-blink：同一格畫面再拍「瞄一眼」「閉眼」，
            // 三個狀態共用同一台相機與同一幀時鐘，官網疊圖時機身不會跳。
            DispatchQueue.main.asyncAfter(deadline: .now() + snapshotDelay) { [weak self] in
                guard let self else { exit(2) }
                self.view.logPose()
                self.view.shellAXDumpIfAsked()   // 2.0: P05 --ax-dump
                var steps: [(path: String, note: String, prepare: () -> Void)] = [(snapshotPath, "open", {})]
                if let p = self.snapshotGlancePath { steps.append((p, "glance", { Face.glanceOverride = true })) }
                if let p = self.snapshotBlinkPath {
                    steps.append((p, "blink", { Face.glanceOverride = false; Face.blinkOverride = 0.1 }))
                }
                func shoot(_ i: Int) {
                    if i == steps.count { exit(0) }
                    let step = steps[i]; step.prepare()
                    if i > 0 { self.view.face.forceDirty = true }   // 第一張就是當下畫面，不重繪
                    DispatchQueue.main.asyncAfter(deadline: .now() + (i == 0 ? 0 : 0.12)) {
                        self.view.captureSnapshot { img in
                            guard let img else { exit(2) }
                            let rep = NSBitmapImageRep(cgImage: self.view.compositeOverlays(img))
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: step.path))
                            log("snapshot \(step.note) \(img.width)x\(img.height) -> \(step.path)")
                            shoot(i + 1)
                        }
                    }
                }
                // HOMEPLAY_FACE_PNG=路徑：另存平面的錶面貼圖（1024²，不經 3D），錶面設計對照用
                if let p = ProcessInfo.processInfo.environment["HOMEPLAY_FACE_PNG"] {
                    let f = self.view.face
                    f.renderScale = CGFloat(Double(ProcessInfo.processInfo.environment["HOMEPLAY_FACE_SCALE"] ?? "1") ?? 1)
                    var img = f.render()
                    // HOMEPLAY_FACE_TRANSITION=modular:0.3：換到 modular、拍過場進行到 30% 的那一格
                    if let spec = ProcessInfo.processInfo.environment["HOMEPLAY_FACE_TRANSITION"]?.split(separator: ":"), spec.count == 2,
                       let to = FaceStyle(rawValue: String(spec[0])), let x = Double(spec[1]) {
                        f.style = to
                        if let t = f.faceTransition { f.faceTransition = (t.sharp, t.frosted, CACurrentMediaTime() - x * Face.transitionDuration, t.islandFrom) }
                        img = f.render()
                    }
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
                    log("face png \(img.width)x\(img.height) -> \(p)")
                }
                shoot(0)
            }
        }
    }

    /// 移动 / 缩放停下 0.5 s 后存一次
    private var frameSaveWork: DispatchWorkItem?
    private func watchWindowFrame() {
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.frameSaveWork?.cancel()
                let w = DispatchWorkItem { [weak self] in if let f = self?.window.frame { WindowFrameStore.save(f) } }
                self?.frameSaveWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
            }
        }
    }
    /// 被完全遮住就停渲染，露出来再继续
    /// 效能基準：數實際渲染幀數 + 讀 process CPU 時間，跑 N 秒後印一行並結束。
    private func startBench() {
        Face.renderCount = 0
        Face.dbgBlink = 0; Face.dbgApproach = 0; Face.dbgScreen = 0; Face.dbgLive = 0; Face.dbgOther = 0
        Face.dbgPal = 0; Face.dbgReveal = 0; Face.dbgFlow = 0; Face.dbgHello = 0; Face.dbgExpr = 0
        Face.renderSeconds = 0; Face.bgSeconds = 0; Face.textSeconds = 0; Face.islandSeconds = 0
        Face.cacheHits = 0; Face.cacheMisses = 0
        Face.pocketA = 0; Face.pocketC = 0; Face.pocketD = 0
        // 以 step() 的实际更新帧数计（RealityKit 的内部渲染帧没有公开回调）
        view.resetStepCount()
        let frames3D0 = view.frames3D, cycles3D0 = view.cycles3D
        let t0 = CACurrentMediaTime()
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu0 = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        DispatchQueue.main.asyncAfter(deadline: .now() + benchSeconds) { [weak self] in
            guard let self else { return }
            let wall = CACurrentMediaTime() - t0
            getrusage(RUSAGE_SELF, &ru)
            let cpu1 = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
                + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
            let mb = Double(ru.ru_maxrss) / 1_048_576
            log(String(format: "bench frames=%d wall=%.1fs fps=%.1f cpu=%.2fs cpu%%=%.1f rss=%.0fMB faceRenders=%d prefFPS=%d frames3D=%d (%.1f/s) detaches=%d patches=%d dirty(blink=%d approach=%d screen=%d live=%d expr=%d)",
                       self.view.stepFrames, wall, Double(self.view.stepFrames) / wall, cpu1 - cpu0, (cpu1 - cpu0) / wall * 100, mb,
                       Face.renderCount, Int(self.view.render.__preferredFrameRate),
                       self.view.frames3D - frames3D0, Double(self.view.frames3D - frames3D0) / wall, self.view.cycles3D - cycles3D0, self.view.patches3D,
                       Face.dbgBlink, Face.dbgApproach, Face.dbgScreen, Face.dbgLive, Face.dbgExpr))
            log("dirty screen: pal=\(Face.dbgPal) reveal=\(Face.dbgReveal) flow=\(Face.dbgFlow) hello=\(Face.dbgHello) faceMs=\(String(format: "%.2f", Face.renderSeconds / Double(max(1, Face.renderCount)) * 1000)) bgMs=\(String(format: "%.2f", Face.bgSeconds / Double(max(1, Face.renderCount)) * 1000)) textMs=\(String(format: "%.2f", Face.textSeconds / Double(max(1, Face.renderCount)) * 1000)) islandMs=\(String(format: "%.2f", Face.islandSeconds / Double(max(1, Face.renderCount)) * 1000)) cache=\(Face.cacheHits)/\(Face.cacheHits + Face.cacheMisses) pocket=\(String(format: "%.2f/%.2f/%.2f", Face.pocketA / Double(max(1, Face.renderCount)) * 1000, Face.pocketC / Double(max(1, Face.renderCount)) * 1000, Face.pocketD / Double(max(1, Face.renderCount)) * 1000))")
            log(String(format: "state reveal %.3f target %.3f near %d style %@ mouse %.0f,%.0f frame %@",
                       Double(self.view.face.reveal), Double(self.view.face.revealTarget), self.view.mood.near ? 1 : 0,
                       self.view.face.style.rawValue, NSEvent.mouseLocation.x, NSEvent.mouseLocation.y,
                       NSStringFromRect(self.window.frame)))
            exit(0)
        }
    }

    private func startLiveTimers() {
        guard healthTimer == nil else { return }
        lastStats = (CACurrentMediaTime(), health.received, health.decoded)   // 清掉暂停期间的间隔，首行 fps 不偏低
        let h = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.view.showingVideo else { return }
            self.act(self.health.check(now: CACurrentMediaTime()), why: "停滞")
        }
        h.tolerance = 0.05
        RunLoop.main.add(h, forMode: .common)
        healthTimer = h
        let s = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.stats() }
        s.tolerance = 0.2
        RunLoop.main.add(s, forMode: .common)
        statsTimer = s
    }

    private func stopLiveTimers() {
        healthTimer?.invalidate(); healthTimer = nil
        statsTimer?.invalidate(); statsTimer = nil
        view.toolTip = nil
    }

    private func watchOcclusion() {
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            let visible = self.window.occlusionState.contains(.visible)
            self.view.setOccluded(!visible)
            NowPlayingPoller.shared.paused = !visible
            if visible {
                self.gazeOccludeWork?.cancel(); self.gazeOccludeWork = nil
                self.resumeGazeIfPossible("pet visible")
            } else {
                self.scheduleGazePauseIfCovered()
            }
        }
    }

    /// 被完全遮住 4 秒后才关摄像头：切一次全屏或 Space 不至于立刻停掉再重启。
    /// 手动隐藏走 hidePet 的立即暂停，不受这个宽限影响。
    private func scheduleGazePauseIfCovered() {
        gazeOccludeWork?.cancel(); gazeOccludeWork = nil
        guard gazeFollow || roomLightOn else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.gazeFollow || self.roomLightOn, self.view.occluded else { return }
            if GazeTracker.shared.setPaused(true) {
                appendDiag("gaze.log", "camera pause: pet occluded 4s")
            }
        }
        gazeOccludeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// 只在「追人开着、不在直播、没锁屏、窗口确实可见」时恢复摄像头。
    private func resumeGazeIfPossible(_ why: String) {
        guard gazeFollow || roomLightOn, !view.occluded, !view.isScreenLocked,
              let w = view.window, w.isVisible, w.occlusionState.contains(.visible) else { return }
        if GazeTracker.shared.setPaused(false) {
            appendDiag("gaze.log", "camera resume: \(why)")
        }
    }

    /// 菜单「取消连线」：停掉这次连接，不再自动重连，直到下次「进入 CarPlay」
    func cancelConnect() {
        userStopped = true; reconnectTimer?.invalidate(); reconnectTimer = nil
        switchingPhone = false
        PhoneNowPlayingBridge.shared.clear()
        client?.onLive = nil; client?.close(); client = nil
        view.face.status = .notConnected
        CarPlayOverlayState.needsPairing = false
        CarPlayOverlayState.pairingHost = nil
        CarPlayOverlayState.pairingStale = false
        CarPlayOverlayState.pairingSucceededAt = nil
        CarPlayOverlayState.wifiHelp = false
        CarPlayOverlayState.wifiNeedsPassword = false
        CarPlayOverlayState.needsTrust = false
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.bluetoothPairing = false
        CarPlayOverlayState.bluetoothPairFailed = false
        quietAttach = false
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        view.mood.show(.wink, for: 0.6, now: CACurrentMediaTime())
        log("connect cancelled")
    }

    /// 右键「使用 iPhone」：写回配置（下次启动/登录也用它），已连着的 receiver 立刻切换。
    func switchPhone(to address: String) {
        guard !(CarPlayPhoneBook.isCurrent(address) && isLive) else { return }   // 正在直播时点当前那台：不动
        switchingPhone = true
        CarPlayOverlayState.wifiHelp = false
        CarPlayOverlayState.wifiNeedsPassword = false
        CarPlayOverlayState.needsTrust = false
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.bluetoothPairing = false
        CarPlayOverlayState.bluetoothPairFailed = false
        quietAttach = false
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        view.face.status = .connecting
        ReceiverLauncher.savePhone(address)
        ReceiverAgent.syncPhone()
        CarPlayOverlayState.needsPairing = false
        CarPlayOverlayState.pairingHost = nil
        if let c = client {
            c.sendUsePhone(address: address)
        } else {
            if view.showingVideo { view.showVideo(false) }
            pendingUsePhone = address
            enterCarPlay()
        }
    }

    /// 右键「配对新 iPhone…」：即使已经有一台在用，也让 receiver 打开蓝牙设置等新配对。
    /// Wi-Fi 名稱：讀得到就送；卡住且沒問過就說明卡 → 定位權限；被拒／讀不到就開 Wi-Fi 設定手填（WiFiName.decide）
    func autoFillSSID(receiverKnows: Bool, stuck: Bool) {
        let action = WiFiName.decide(receiverKnows: receiverKnows, readable: WiFiName.current(), auth: WiFiName.auth,
                                     stuck: stuck, quiet: quietAttach, alreadyAsked: locationAsked)
        switch action {
        case .send(let name):
            client?.sendSSID(name)
            CarPlayWiFi.ssid = name
            if CarPlayOverlayState.connectReason == "ssidUnknown" { CarPlayOverlayState.wifiHelp = false }   // 接收器會馬上重叫手機
            log("Wi-Fi name filled from CoreWLAN (value not logged)")
        case .askPermission:
            locationAsked = true
            log("Wi-Fi name unknown: asking for Location to read it")
            withPermission(.location) { [weak self] ok in
                guard let self else { return }
                guard CarPlayWiFi.ssid.isEmpty else { return }   // 等定位的時候 iPhone 已經分享了 Wi-Fi：什麼都不用做
                guard ok else { self.openWiFiDialogOnce(); return }
                // 剛允許時 macOS 要過幾秒才把 SSID 交給 App：每 0.5 秒再讀，最多 10 秒，讀不到才開手填
                log("Location granted: waiting for macOS to reveal the Wi-Fi name")
                func poll(_ n: Int) {
                    if WiFiName.current() != nil { self.autoFillSSID(receiverKnows: false, stuck: true); return }
                    if n >= 20 { log("Wi-Fi name still hidden 10 s after Location was granted"); self.openWiFiDialogOnce(); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll(n + 1) }
                }
                poll(0)
            }
        case .manual:
            openWiFiDialogOnce()
        case .nothing:
            break
        }
    }
    private func openWiFiDialogOnce() {
        guard !ssidDialogShown, !quietAttach, !isLive else { return }
        ssidDialogShown = true
        settingsPerform("menuWiFiPassword", nil)
    }

    /// 第一次進配對引導（桌寵在前台）時自動出一次「連接步驟」：先講清楚哪條路對，免得在 iPhone 藍牙裡亂點
    private func showConnectStepsOnce() {
        guard !quietAttach, !UserDefaults.standard.bool(forKey: ConnectHelp.stepsShownKey) else { return }
        UserDefaults.standard.set(true, forKey: ConnectHelp.stepsShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ConnectHelp.showSteps() }
    }

    /// 右鍵 › iPhone › 拷貝診斷報告：桌寵這邊的狀態＋接收器的現場＋日誌里程碑次數，放進剪貼簿。
    /// 不含 Wi-Fi 名稱、密碼、位址、裝置名稱（接收器那段見 ConnectDiagnostics.reportLines）。
    func copyDiagnostics() {
        let started = CACurrentMediaTime()
        func finish(_ receiver: String?) {
            diagnosticsWaiter = nil
            diagnosticsTimeout?.cancel(); diagnosticsTimeout = nil
            let info = Bundle.main.infoDictionary
            let v = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm ZZZZZ"
            let reason = CarPlayOverlayState.connectReason ?? "-"
            let helpFor = CarPlayOverlayState.helpSince.map { " for \(Int(CACurrentMediaTime() - $0)) s" } ?? ""
            var card = "none"
            if CarPlayOverlayState.needsCable { card = "needCable" }
            else if CarPlayOverlayState.needsTrust { card = "needTrust" }
            else if CarPlayOverlayState.bluetoothPairing { card = "bluetoothPairing(\(CarPlayOverlayState.pairPhase ?? "-"))" }
            else if CarPlayOverlayState.bluetoothPairFailed { card = "bluetoothPairFailed(\(CarPlayOverlayState.pairFailReason ?? "-"))" }
            else if CarPlayOverlayState.needsPairing { card = "needPairing" }
            else if CarPlayOverlayState.wifiHelp { card = "connectHelp(\(reason))\(helpFor)" }
            let pet = [
                "HomePlay \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "-"))"
                    + " · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(arch) · \(L10n.language.rawValue)",
                "Created: \(f.string(from: Date()))",
                "Pet: receiver connected \(client != nil ? "yes" : "no") · status \(view.face.status) · video \(view.showingVideo ? "yes" : "no")"
                    + " · card \(card) · iPhones known \(CarPlayPhoneBook.phones.count)"
                    + (HomePlayState.isolated ? " · rehearsal state" : ""),
            ]
            let text = ConnectHelp.compose(petLines: pet, receiver: receiver, log: ConnectHelp.logSummary())
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            log("diagnostic report copied (\(text.count) chars, receiver \(receiver == nil ? "silent" : "answered") in \(Int((CACurrentMediaTime() - started) * 1000)) ms)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("diag.copiedTitle", "诊断报告已拷贝")
            alert.informativeText = L("diag.copiedBody", "直接粘贴给帮你看的人。里面只有次数、时间和状态，不含 Wi-Fi 名称、密码、地址或设备名称。")
            alert.addButton(withTitle: L("gaze.denied.ok", "好"))
            alert.runModal()
        }
        guard diagnosticsWaiter == nil else { return }   // 上一次還在等接收器
        guard let c = client else { finish(nil); return }
        diagnosticsWaiter = { report in finish(report) }
        c.requestDiagnostics()
        let timeout = DispatchWorkItem { [weak self] in self?.diagnosticsWaiter?(nil) }
        diagnosticsTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    func pairNewPhone() {
        switchingPhone = true
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        CarPlayOverlayState.wifiHelp = false
        CarPlayOverlayState.wifiNeedsPassword = false
        CarPlayOverlayState.needsTrust = false
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.bluetoothPairing = false
        CarPlayOverlayState.bluetoothPairFailed = false
        CarPlayOverlayState.needsPairing = true
        CarPlayOverlayState.pairingHost = nil
        if let c = client {
            c.sendPairNewPhone()
        } else {
            if view.showingVideo { view.showVideo(false); view.face.status = .notConnected }
            pendingPairNew = true
            enterCarPlay()
        }
    }

    /// --event "标题|开始 HH:mm|结束 HH:mm"：快照测试用的固定行程
    static func testEvent(_ s: String) -> CalendarTile {
        let f = s.components(separatedBy: "|")
        func at(_ hm: String) -> Date {
            let p = hm.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
        }
        return .event(NextEvent(title: f[0], start: at(f.count > 1 ? f[1] : "10:30"), end: at(f.count > 2 ? f[2] : "11:00")))
    }

    /// 后台挂接时如果 receiver 真的需要配对/信任，自动转为前台引导：
    /// 让用户看到该点哪里，同时让 receiver 可以打开蓝牙设置。
    private func engageQuietAttach() {
        view.wakeFromPosterForGuide()
        guard quietAttach, !userStopped, !isLive else { return }
        quietAttach = false
        view.face.status = .connecting
        client?.sendEngaged(true)
        log("background attach engaged for pairing guide")
    }

    /// 接收器把有线会话切成无线时，桌宠冻住最后一帧：不要收起画面、不要弹「连接中」，
    /// 也不要让健康检查把这次正常切换当成断流去关 WebSocket。
    private func beginHandoffFreeze(seconds: Double = 25) {
        view.wakeFromPosterForGuide()
        handoffFreeze = true
        handoffTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.handoffFreeze else { return }
            self.handoffFreeze = false
            log("handoff: timeout waiting for wireless")
            if !self.isLive {
                self.view.showVideo(false)
                self.view.face.status = .reconnecting
            }
        }
        handoffTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        log("handoff: holding last frame")
    }

    private func endHandoffFreeze(_ state: String) {
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        log("handoff: \(state)")
        if state == "failed", !isLive {
            view.showVideo(false)
            view.face.status = .reconnecting
        }
    }

    /// 插线换新 iPhone：USB 已结束、手机蓝牙恢复；给用户看配对卡，等 BondAssist/系统配对完成。
    private func beginPairingHandoffView() {
        view.wakeFromPosterForGuide()
        beginHandoffFreeze(seconds: 200)
        quietAttach = false
        client?.sendEngaged(true)
        view.showVideo(false)
        view.face.status = .connecting
        CarPlayOverlayState.needsPairing = false
        CarPlayOverlayState.pairingHost = nil
        CarPlayOverlayState.needsCable = false
        CarPlayOverlayState.needsTrust = false
        CarPlayOverlayState.bluetoothPairing = true
        CarPlayOverlayState.bluetoothPairFailed = false
        CarPlayOverlayState.wifiHelp = false
        CarPlayOverlayState.pairingSucceededAt = nil
    }

    /// 截图／基准／设置预览这类诊断进程：不挂接收器、退出时也不发 stop，绝不碰用户正在用的 CarPlay
    static var isDiagnosticRun: Bool {
        let a = CommandLine.arguments
        return ["--snapshot", "--screen-png", "--bench", "--open-settings", "--show-menu", "--clock-look-panel", "--remote-test", "--hello-product"].contains { a.contains($0) }   // 2.0 idle: 串流測試也不碰接收器
    }
    /// 效能量測（tooling/perf-probe.sh）專用：接收器相關的一切全部隔離（不連線、不裝／不踢 LaunchAgent、
    /// 不自動進場）。跟 isDiagnosticRun 不同：狀態列、遮蔽監看、全域監看、AirPlayWatch 照正式版跑，
    /// 量的才是真的待機行為。2026-10-26 實測教訓：量測寵物一旦被使用者點到「使用 iPhone」，
    /// 會連上真接收器收真 CarPlay 影片、把量測弄髒，還會安裝 rehearsal 代理。
    static var perfProbe: Bool { ProcessInfo.processInfo.environment["HOMEPLAY_PERF_PROBE"] == "1" }
    private func connect(_ endpoint: String, quiet: Bool = false) {
        guard !Self.isDiagnosticRun else { log("diagnostic run: not attaching to receiver"); return }
        guard !Self.perfProbe else { log("perf probe: not attaching to receiver"); return }
        guard let c = ReceiverClient(endpoint: endpoint, decoder: view.decoder) else {
            log("无效 endpoint：\(endpoint)"); return
        }
        quietAttach = quiet
        c.onLive = { [weak self] live in
            guard let self else { return }
            // 畫面出來了：設定流程裡還掛著的定位說明卡一律收掉（它只是為了 Wi-Fi 名稱，已經不需要了）
            if live, PermissionPrimer.kind == .location { PermissionPrimer.dismiss() }
            if !live, self.handoffFreeze {
                self.isLive = false
                log("handoff: wired session ended; holding last frame")
                return
            }
            if live, self.handoffFreeze {
                self.handoffFreeze = false
                self.handoffTimeoutWork?.cancel(); self.handoffTimeoutWork = nil
                log("handoff: wireless frame arrived")
            }
            let wasQuiet = self.quietAttach
            self.isLive = live
            if live { ClioTalkController.shared.carPlayWentLive() }   // 2.0: CarPlay 的 Siri 要用麥克風，ClioTalk 先放掉
            if live { self.flushPendingCarPlayApp() }
            if live { CarPlayWidgetProbe.startIfRequested { [weak self] m in self?.client?.sendRaw(m) } }   // --carplay-widget-probe（Shell/AppPlatform/CarPlayWidgetProbe.swift）
            if !live { self.carPlayInBackground = false }
            if live { self.quietAttach = false }
            let now = CACurrentMediaTime()
            let pausedOnPurpose = !live && CarPlayAirDropPause.shared.intentional(now: now)   // 收 AirDrop 自己斷的：不算斷線
            if pausedOnPurpose {
                self.view.face.status = .background
            } else if !wasQuiet || live {
                self.view.face.status = live ? .live : (self.userStopped ? .pausedResume : .reconnecting)
            }
            if live {
                // 出第一帧：点一下头。断过线的同时笑一下（它回来了），画面不等表情。
                if !wasQuiet { self.requestMicrophoneIfNeeded(announce: false, reason: "CarPlay live") }
                self.reconnectStep = 0; self.disconnectedAt = nil; self.health.reset(now: now)
                self.switchingPhone = false
                CarPlayOverlayState.needsPairing = false
                CarPlayOverlayState.pairingHost = nil
                CarPlayOverlayState.pairingStale = false
                CarPlayOverlayState.pairingSucceededAt = nil
                CarPlayOverlayState.wifiHelp = false
                CarPlayOverlayState.wifiNeedsPassword = false
                CarPlayOverlayState.needsTrust = false
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                self.view.nod()
                if self.view.mood.disconnected {
                    self.view.mood.disconnected = false
                    self.view.mood.show(.happy, for: 0.8, now: now)
                }
                let back = CarPlayAirDropPause.shared.takeRestore(now: now)   // 收 AirDrop 暫停後的重連：回原本的畫面
                if back == false, !self.view.showingVideo {
                    self.carPlayInBackground = true
                    self.view.face.status = .background
                    log("CarPlay live again after AirDrop pause; staying where the user was")
                } else if back == nil, now < self.homeLatchUntil, !self.view.showingVideo {   // 2.0 align D：剛手動切到 HomeView，留在後台
                    self.carPlayInBackground = true
                    self.view.face.status = .background
                    log("CarPlay live again; staying behind HomeView (manual switch \(Int(self.homeLatchUntil - now)) s left)")
                } else if self.carPlayLocked, !self.view.showingVideo {   // 訪客鎖著（2026-11-07）：連上了也留在後台，不自己跳到前面
                    self.carPlayInBackground = true
                    self.view.face.status = .background
                    log("CarPlay live; staying in the background: guest lock")
                } else {
                    self.view.showVideo(true)
                    if self.gazeFollow { GazeTracker.shared.setPaused(true) }   // 看 CarPlay 时关摄像头
                }
            } else {
                // 直播中断（不是用户按空格停的）：屏幕回到擔心臉，直到重连成功
                PhoneNowPlayingBridge.shared.clear()
                if self.view.showingVideo, !pausedOnPurpose { self.view.mood.disconnected = true }
                if !wasQuiet { self.view.showVideo(false) }   // 安静挂接时不要打扰桌宠
                self.scheduleReconnect(quiet: wasQuiet)
            }
        }
        c.onFrameReceived = { [weak self] in self?.health.frameReceived(now: CACurrentMediaTime()) }
        c.onText = { s in
            if s.contains("\"type\":\"carPlayPause\"") {   // 接收端回報暫停狀態（到時自己恢復時收掉倒數卡）
                CarPlayAirDropPause.shared.receiverSaid(s)
                self.view.face.forceDirty = true
                return
            }
            if s.contains("\"type\":\"cornerMask\"") {   // 學圓角的那一次連線：桌寵暫時縮放補黑
                if let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let w = Int(self.view.decoder.size.width)
                    CornerFit.shared.handle(obj, videoWidth: w > 0 ? w : 1088, device: MTLCreateSystemDefaultDevice())
                }
                return
            }
            if s.contains("\"type\":\"carVideo\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.view.carVideo.handle(obj)
                }
                return
            }
            if s.contains("\"type\":\"call\"") {
                if let call = PhoneCallInfo.parse(s) { self.applyCall(call) }
                return
            }
            if s.contains("\"type\":\"cellular\"") {
                if let info = CellularInfo.parse(s) { self.callCard.model.carrier = info.carrier }
                return
            }
            if s.contains("\"type\":\"nowplaying\"") {
                if s.contains("\"clear\":true") { PhoneNowPlayingBridge.shared.clear() }
                else if let data = s.data(using: .utf8),
                        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    PhoneNowPlayingBridge.shared.apply(obj)
                }
                return
            }
            if s.contains("\"type\":\"artwork\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = (obj["id"] as? NSNumber)?.uint8Value,
                   let b64 = obj["data"] as? String,
                   let bytes = Data(base64Encoded: b64) {
                    PhoneNowPlayingBridge.shared.applyArtwork(id: id, data: bytes)
                }
                return
            }
            if s.contains("\"type\":\"handoff\"") {
                if s.contains("\"state\":\"start\"") { self.beginHandoffFreeze() }
                else if s.contains("\"state\":\"pairing\"") { self.beginPairingHandoffView() }
                else if s.contains("\"state\":\"done\"") { self.endHandoffFreeze("wireless") }
                else if s.contains("\"state\":\"failed\"") { self.endHandoffFreeze("failed") }
                return
            }
            if s.contains("\"type\":\"session\"") {
                if self.handoffFreeze { return }
                // receiver 的会话状态：切换手机/手机自己 TEARDOWN 时收起旧画面，等下一帧。
                let started = s.contains("\"state\":\"started\"")
                if started {
                    if !self.userStopped, !self.quietAttach, !self.isLive, !self.view.showingVideo {
                        self.view.face.status = .connecting
                    }
                } else if !self.userStopped, !self.quietAttach {
                    self.isLive = false
                    self.view.carVideo.stop(notify: false)
                    PhoneNowPlayingBridge.shared.clear()
                    self.view.showVideo(false)
                    self.view.face.status = self.switchingPhone ? .connecting : .reconnecting
                }
                return
            }
            if s.contains("\"type\":\"currentPhone\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let address = obj["address"] as? String, !address.isEmpty {
                    ReceiverLauncher.savePhone(address)   // 下次启动优先这台，不再被别的已配对手机顶替
                    CarPlayPhoneBook.current = address
                    CarPlayOverlayState.needsCable = false
                    _ = ReceiverAgent.autoEnableIfNeeded(reason: "paired iPhone")
                    log("current iPhone saved")
                }
                return
            }
            if s.contains("\"type\":\"diagnostics\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let report = obj["report"] as? String {
                    self.diagnosticsWaiter?(report)
                }
                return
            }
            if s.contains("\"type\":\"wifiHelp\"") {
                self.engageQuietAttach()
                if !CarPlayOverlayState.wifiHelp { CarPlayOverlayState.helpSince = CACurrentMediaTime() }
                CarPlayOverlayState.wifiHelp = true
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    CarPlayOverlayState.wifiNeedsPassword = (obj["passphraseMissing"] as? Bool) ?? false
                    let reason = obj["reason"] as? String
                    if reason != CarPlayOverlayState.connectReason { CarPlayOverlayState.helpSince = CACurrentMediaTime() }
                    CarPlayOverlayState.connectReason = reason
                    CarPlayOverlayState.helpSSID = obj["ssid"] as? String ?? ""
                    log("connect help: \(reason ?? "wifi")")
                    // Wi-Fi 名稱未知（macOS 對 App 隱藏）：有定位權限就自己讀；沒問過先出說明卡；被拒才打開 Wi-Fi 設定手填
                    if reason == "ssidUnknown", !self.isLive {
                        DispatchQueue.main.async { self.autoFillSSID(receiverKnows: false, stuck: true) }
                    }
                }
                return
            }
            if s.contains("\"type\":\"wifiInfo\"") {
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = obj["ssid"] as? String {
                    CarPlayWiFi.ssid = value
                    // 接收器不知道名稱：已有定位權限就悄悄補上。不在這裡問定位——接收器一連上 iPhone 就先請它
                    // 分享 Wi-Fi（一次點按、連密碼一起來）；iPhone 拒絕而真的卡住時才走定位／手填
                    if value.isEmpty { DispatchQueue.main.async { self.autoFillSSID(receiverKnows: false, stuck: false) } }
                    // iPhone 已經分享（或使用者手填）了：還掛著的定位說明卡就收掉，不要蓋在 CarPlay 畫面上
                    else if PermissionPrimer.kind == .location { DispatchQueue.main.async { PermissionPrimer.dismiss() } }
                }
                return
            }
            if s.contains("\"type\":\"phones\"") {
                CarPlayPhoneBook.apply(json: s)
                return
            }
            if s.contains("\"type\":\"needCable\"") {
                self.engageQuietAttach()
                CarPlayOverlayState.needsCable = true
                CarPlayOverlayState.needsPairing = false
                CarPlayOverlayState.needsTrust = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                CarPlayOverlayState.wifiHelp = false
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("first pairing: waiting for a cable")
                self.showConnectStepsOnce()
                return
            }
            if s.contains("\"type\":\"requestUI\"") {
                // 手机上点了 HomePlay 图标：回到表面，CarPlay 留在后台（和「重按进入 CarPlay」形成闭环）
                if self.view.showingVideo {
                    self.carPlayInBackground = true
                    self.homeLatchUntil = CACurrentMediaTime() + Self.homeLatch
                    self.view.showVideo(false)
                    self.view.face.status = .background
                    self.view.mood.show(.happy, for: 0.8, now: CACurrentMediaTime())
                    log("requestUI: back to the face; CarPlay stays in the background")
                }
                return
            }
            if s.contains("\"type\":\"bluetoothPairing\"") {
                self.engageQuietAttach()
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.needsPairing = false
                CarPlayOverlayState.needsTrust = false
                CarPlayOverlayState.bluetoothPairing = true
                CarPlayOverlayState.bluetoothPairFailed = false
                CarPlayOverlayState.pairFailReason = nil
                CarPlayOverlayState.wifiHelp = false
                // 階段、配對碼、倒數、這台 Mac 在 iPhone 上的名字（舊 receiver 沒有這些欄位就照舊顯示）
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    CarPlayOverlayState.pairPhase = obj["phase"] as? String
                    CarPlayOverlayState.pairCode = obj["code"] as? String
                    CarPlayOverlayState.pairDeadline = (obj["timeout"] as? Int).map { CACurrentMediaTime() + Double($0) }
                    if let host = obj["host"] as? String, !host.isEmpty { CarPlayOverlayState.pairingHost = host }
                }
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("bluetooth pairing \(CarPlayOverlayState.pairPhase ?? "requested") on iPhone")
                return
            }
            if s.contains("\"type\":\"bluetoothPairFailed\"") {
                self.engageQuietAttach()
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = true
                CarPlayOverlayState.pairPhase = nil
                CarPlayOverlayState.pairCode = nil
                CarPlayOverlayState.pairDeadline = nil
                CarPlayOverlayState.pairFailReason = s.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reason"] as? String
                CarPlayOverlayState.needsCable = false
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("bluetooth pairing not confirmed; replug to retry")
                return
            }
            if s.contains("needPairing") {
                self.engageQuietAttach()
                CarPlayOverlayState.needsPairing = true
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                CarPlayOverlayState.pairingSucceededAt = nil
                CarPlayOverlayState.wifiHelp = false
                CarPlayOverlayState.needsTrust = false   // 蓝牙配对卡优先于 USB 信任卡
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let host = obj["host"] as? String, !host.isEmpty {
                    CarPlayOverlayState.pairingHost = host
                }
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    CarPlayOverlayState.pairingStale = (obj["stale"] as? Bool) ?? false
                    CarPlayOverlayState.pairingViaCable = (obj["cable"] as? Bool) ?? false
                }
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("needs pairing")
                self.showConnectStepsOnce()
            }
            if s.contains("\"type\":\"phoneForgotten\"") {
                // 忘記之後還要使用者做的步驟：iPhone 上忘記這台車；Mac 刪不掉系統配對時再加一步
                if let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let name = obj["name"] as? String
                    let macRemoved = obj["macRemoved"] as? Bool ?? true
                    DispatchQueue.main.async { self.view.showForgetSteps(name: name, macRemoved: macRemoved) }
                }
                return
            }
            if s.contains("pairingDone") {
                CarPlayOverlayState.pairPhase = nil
                CarPlayOverlayState.pairCode = nil
                CarPlayOverlayState.pairDeadline = nil
                CarPlayOverlayState.pairFailReason = nil
                CarPlayOverlayState.needsPairing = false
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                CarPlayOverlayState.pairingHost = nil
                CarPlayOverlayState.pairingStale = false
                if self.handoffFreeze { self.endHandoffFreeze("pairing done") }
                CarPlayOverlayState.pairingSucceededAt = CACurrentMediaTime()
                _ = ReceiverAgent.autoEnableIfNeeded(reason: "pairing done")
                log("bluetooth pairing done")
            }
            if s.contains("\"type\":\"needTrust\"") {
                self.engageQuietAttach()
                CarPlayOverlayState.needsTrust = true
                CarPlayOverlayState.needsCable = false
                CarPlayOverlayState.bluetoothPairing = false
                CarPlayOverlayState.bluetoothPairFailed = false
                // 桌宠闲置时插线也可能走到这里：把表盘切到引导状态，信任卡才画得出来
                if !self.isLive, !self.view.showingVideo, !self.userStopped, !self.quietAttach {
                    self.view.face.status = .connecting
                }
                log("USB needs trust")
            }
            if s.contains("\"type\":\"trustDone\"") {
                // 有线排障卡（usb 开头的原因）也跟着收：解锁了、信任了、或拔线了
                if CarPlayOverlayState.connectReason?.hasPrefix("usb") == true { CarPlayOverlayState.wifiHelp = false }
                if CarPlayOverlayState.needsTrust, !self.isLive {
                    self.view.face.status = .notConnected
                }
                CarPlayOverlayState.needsTrust = false
                CarPlayOverlayState.needsCable = false
            }
        }
        c.onOpen = { [weak self, weak c] in
            guard let self, let c else { return }
            self.receiverKickstarted = false   // 这一轮已成功连上；下次 receiver 掉了还能再 kickstart
            c.sendEngaged(!self.quietAttach)
            if let savedGain = UserDefaults.standard.object(forKey: "HomePlayCallGainDb") as? Double {
                c.sendCallGain(savedGain)
            }
            if let address = self.pendingUsePhone {
                self.pendingUsePhone = nil
                c.sendUsePhone(address: address)
            }
            if self.pendingPairNew {
                self.pendingPairNew = false
                c.sendPairNewPhone()
            }
            if self.pendingSiri {
                self.pendingSiri = false
                // F5 還按著：補送按下，放開時照常送放開；已經放開了就按一下
                if self.siriHold.held { c.sendSiri(down: true); self.siriDownSent = true }
                else { c.sendSiri() }
            }
        }
        client = c
        if !quiet { view.face.status = .connecting }
        c.open()
    }
    /// 設定「在 CarPlay 播放影片」：寫檔（接收器下次回 /info 用），也即時告訴接收器（它會通知手機）
    func setCarVideoAllowed(_ on: Bool) {
        CarVideoSetting.allowed = on
        client?.sendRaw(CarVideoPlayer.json(["type": "carVideoAllowed", "allowed": on]))
        if !on { view.carVideo.stop(notify: true) }
        log("car video allowed \(on)")
    }
    /// CarPlay 在后台（点过 HomePlay 图标）：直接把画面切回来，要一张关键帧让画面马上出来
    private func resumeFromBackground() -> Bool {
        guard carPlayInBackground, isLive, !view.showingVideo else { return false }
        if carPlayLocked { log("CarPlay stays in the background: guest lock"); return false }   // 自動的（影片、來電）就不叫；使用者叫的由 enterCarPlay 顯示「需要主人」
        carPlayInBackground = false
        homeLatchUntil = 0
        view.showVideo(true)
        view.face.status = .live
        client?.requestKeyframe()
        log("CarPlay back to the front")
        return true
    }
    /// 把 CarPlay 收到后台、回到 HomeView：会话不动、不关 WS、不发 stop。
    /// 这就是 iPhone 点 HomePlay 图标（requestUI）走的同一条路，只是改成可以在本机触发。
    @discardableResult
    private func showHomeView() -> Bool {
        guard view.showingVideo, isLive, !carPlayInBackground else { return false }
        carPlayInBackground = true
        homeLatchUntil = CACurrentMediaTime() + Self.homeLatch
        view.showVideo(false)
        view.face.status = .background
        userStopped = false
        log("CarPlay stays live in the background; showing HomeView")
        return true
    }
    /// 主畫面上 iPhone 的 CarPlay App（PhoneApps.swift）：切到 CarPlay、叫手機直接開那個 App；還沒連上就先連，連上再開
    private var pendingCarPlayURL: String?
    func openCarPlayApp(_ url: String, name: String) {
        if carPlayLocked { showCarPlayLock("open \(name)"); return }
        log("open CarPlay app \(name) \(url)")
        if isLive {
            if !view.showingVideo { _ = resumeFromBackground() }
            client?.openCarPlayApp(url)
        } else {
            pendingCarPlayURL = url
            enterCarPlay()
        }
    }
    /// CarPlay 在畫面上時要開的 App（連線剛好起來時）
    private func flushPendingCarPlayApp() {
        guard isLive, let u = pendingCarPlayURL else { return }
        pendingCarPlayURL = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.client?.openCarPlayApp(u) }   // 等第一格畫面出來再跳，免得被 CarPlay 首頁蓋回去
    }

    /// CarPlay 與 HomeView 是一個整體（2026-11-06 使用者）：要在桌寵畫面上看到結果的動作（選單的錶面、總覽、主畫面、
    /// 控制中心、ClioTalk、食譜）與打斷（計時器到點、鬧鐘、門鈴）先把桌寵叫到前面——CarPlay 會話留在背景（同空白鍵／👀），
    /// 空白鍵、👀 或控制中心的 CarPlay 方塊一按就回去、立刻有畫面。
    func surfacePet(_ reason: String) {
        guard view.showingVideo else { return }
        log("surface pet over CarPlay: \(reason)")
        _ = showHomeView()
    }
    /// 訪客鎖（2026-11-07，Shell/PersonalGate.swift）：CarPlay 看得到主人手機的訊息、來電、導航紀錄，跟訊息同級。
    /// 門關著時所有叫 CarPlay 到前面的入口都不叫，改在外殼打開 CarPlay App 那一頁＝「需要主人」；已經在背景的會話不動。
    var carPlayLocked: Bool { PersonalGate.locks(CarPlayApp.id) }
    private func showCarPlayLock(_ reason: String) {
        log("CarPlay locked (needs owner): \(reason)")
        view.shellOpenFromAnywhere(CarPlayApp.id)
    }
    /// 本机切换显示源。只动表现层（showVideo／carPlayInBackground／status），
    /// 绝不发 stop、不关 WS、不碰连接状态机——真正结束会话只留右键菜单。
    func switchSource() {
        if view.showingVideo { view.carPlayToHome(reason: "switch source"); return }   // 落在主畫面（同 👀）
        if resumeFromBackground() { return }
        enterCarPlay()
    }
    /// 👀 膠囊在 CarPlay 上往下拉（Shell/HomeIndicator.swift）：先把直播收到背景（同 showHomeView：會話不動、播放不斷），外殼畫卡片
    @discardableResult
    func carPlayToBackgroundForShell() -> Bool { showHomeView() }
    /// CarPlay App 從外殼打開（圖示、切換器）、或膠囊拉下來又取消：叫回前面——會話在背景＝立刻有畫面；沒連上＝去連
    func carPlayToFrontForShell() {
        guard !view.showingVideo else { return }
        enterCarPlay()
    }
    /// 選單「退出 CarPlay」、控制中心的 CarPlay 方塊：跟重按、空白鍵、👀 一致，回到主畫面、會話留在背景，
    /// 再進 CarPlay 立刻有畫面（2026-10-31 真機：原本這裡整個斷線，每次回 CarPlay 要重連 2–5 秒）。
    /// 只有不在直播時（交接中等）才真的斷開。
    private func toggle() {
        if !view.showingVideo, carPlayLocked { showCarPlayLock("toggle"); return }
        if !view.showingVideo, resumeFromBackground() { return }
        handoffFreeze = false
        handoffTimeoutWork?.cancel(); handoffTimeoutWork = nil
        if view.showingVideo {
            if view.carPlayToHome(reason: "menu exit CarPlay") { return }   // 落在主畫面（同 👀／空白鍵）
            endCarPlay(reason: "toggle")
        } else if let endpoint {
            userStopped = false; client?.close(); client = nil
            ensureReceiver { [weak self] in self?.connect(endpoint) }   // receiver 已退出時重新拉起
        }
    }

    /// 真正結束 CarPlay：請接收器拆掉手機會話（接收器隨後退出）。現在只有隱藏桌寵、交接中退出會走這裡。
    private func endCarPlay(reason: String) {
        userStopped = true; reconnectTimer?.invalidate()
        PhoneNowPlayingBridge.shared.clear()
        client?.requestTeardown(reason: reason)   // 讓 iPhone 端也結束 CarPlay，而不是只關畫面
        view.showVideo(false); view.face.status = .pausedResume
        log("CarPlay ended (\(reason))")
    }

    // MARK: 重按进入 CarPlay（照 MacPlay「启动接收」的定位，但做成一键：receiver 不在就拉起，然后连；
    // 连不上靠既有的 5/10/20/30/60s 退避一直等，receiver 侧自己也会退避重试手机——两边都不用管）
    @objc func enterCarPlay() {
        // 同一個手勢進出：已經在直播就收到後台（不拆會話）、落在主畫面（2026-11-07：重按同 👀／空白鍵）
        if view.showingVideo { view.carPlayToHome(reason: "force press"); return }
        if carPlayLocked { showCarPlayLock("enter"); return }
        if resumeFromBackground() { return }
        view.mood.show(.surprised, for: 0.35, now: CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.view.mood.show(.thinking, for: 12, now: CACurrentMediaTime())
        }
        let target = endpoint ?? "ws://127.0.0.1:\(ReceiverLauncher.port())"
        endpoint = target
        userStopped = false
        quietAttach = false
        reconnectTimer?.invalidate(); reconnectTimer = nil   // 立即连，不等旧的退避
        ensureReceiver { [weak self] in
            self?.client?.close()
            self?.connect(target)
        }
    }

    /// receiver 不在（8788 没人听）就拉起一个；在的话直接用，不重复起。
    private func ensureReceiver(_ then: @escaping () -> Void) {
        guard !Self.perfProbe else { log("perf probe: not touching the receiver agent"); then(); return }
        // 想做到「一次配好、以后自动」：第一次进 CarPlay 就把 receiver 交给 launchd 常驻。
        // 这样桌宠退出/重启后手机仍有东西可回连；用户明确关过「后台自动连接」则尊重选择。
        if !ReceiverAgent.isInstalled, ReceiverAgent.autoEnableIfNeeded(reason: "receiver needed") {
            log("后台自动连接已开启：接收器会在登录后常驻")
        }
        // 已装开机自启（launchd）时，接收器由 launchd 负责：登录瞬间它可能还没就绪，
        // 先等它起来，不要另起一个实例抢端口（2026-10-20 重启实测：桌宠先起会让
        // launchd 实例每 10 秒 Address already in use）。
        if ReceiverAgent.isInstalled {
            waitForReceiver(attempts: 20, then)
            return
        }
        portOpen("127.0.0.1", UInt16(clamping: ReceiverLauncher.port())) { [weak self] open in
            DispatchQueue.main.async { [weak self] in
                if !open, let self {
                    switch ReceiverLauncher.launch() {
                    case .ok: log("receiver 已拉起（日志：~/Library/Application Support/HomePlay/receiver.log）")
                    case .noBinary(let path):
                        log("找不到 homeplay-receiver（找过 \(path)）；先 swift build，或自己跑 receiver 再连")
                        self.view.mood.show(.worried, for: 2.5, now: CACurrentMediaTime())
                    }
                }
                then()
            }
        }
    }

    /// 已装自启时轮询等待 launchd 的接收器；它始终没来就退回自己拉起。
    /// 探测一轮没到就先 kickstart（用户停播后接收器 exit(0)，launchd 的 KeepAlive
    /// 不会重启它——别等满 10 秒，0.5 秒后就催一次），再等 10 秒，最后才自起子进程。
    private func waitForReceiver(attempts: Int, _ then: @escaping () -> Void) {
        portOpen("127.0.0.1", UInt16(clamping: ReceiverLauncher.port())) { [weak self] open in
            DispatchQueue.main.async { [weak self] in
                if open { then(); return }
                guard attempts > 1 else {
                    if let self {
                        // 已裝 launchd 作業時絕不自己另起一個：行程在跑卻不聽埠（2026-11-07 真機：8788 監聽器失效），
                        // 另起的實例佔不到 17000 會立刻退出，每次重連都再起一個、還把日誌洗掉。改成強制重啟 launchd 作業。
                        if ReceiverAgent.isInstalled {
                            if ReceiverRecovery.shouldForceRestart(now: Date()) {
                                log("receiver 在跑但連不上埠：強制重啟 launchd 作業（kickstart -k）")
                                _ = ReceiverAgent.kickstart(force: true)
                            }
                        } else {
                            switch ReceiverLauncher.launch() {
                            case .ok: log("launchd 的 receiver 未就绪，已自行拉起")
                            case .noBinary(let path):
                                log("找不到 homeplay-receiver（找过 \(path)）；先 swift build，或自己跑 receiver 再连")
                                self.view.mood.show(.worried, for: 2.5, now: CACurrentMediaTime())
                            }
                        }
                    }
                    then()
                    return
                }
                if let self, ReceiverAgent.isInstalled, !self.receiverKickstarted {
                    // 首探就失败：大概率是上一次「停播」让接收器 exit(0) 了。立即 kickstart，
                    // 不再等满整轮（旧逻辑要 10 秒后才催，用户重进 CarPlay 会卡半拍）。
                    self.receiverKickstarted = true
                    if ReceiverAgent.kickstart() {
                        log("receiver 不在跑：已 kickstart launchd 作业，继续等")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.waitForReceiver(attempts: attempts - 1, then)
                }
            }
        }
    }

    /// 0.6s 内 TCP 连不连得上（判断 receiver 是否已在跑）
    private func portOpen(_ host: String, _ port: UInt16, _ done: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var answered = false
        func finish(_ ok: Bool) {
            guard !answered else { return }
            answered = true; conn.cancel(); done(ok)
        }
        conn.stateUpdateHandler = { state in
            switch state { case .ready: finish(true); case .failed, .cancelled: finish(false); default: break }
        }
        conn.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { finish(false) }
    }

    // 断线重连：前 15 s 每 0.3 s 探一次端口，通了就连；之后 5、10、20、30、60 s 退避，
    // 出画面归零；用户按空格停的不重连
    private func scheduleReconnect(quiet: Bool = false) {
        guard let endpoint, !userStopped, reconnectTimer == nil, !reconnectProbing else { return }
        let now = CACurrentMediaTime()
        if disconnectedAt == nil { disconnectedAt = now }
        // 没装 launchd 自启时接收器要桌宠自己拉起，快探只到原本第一次退避（5 s）就交给 ensureReceiver
        let window = ReceiverAgent.isInstalled ? Self.fastProbeWindow : Self.backoff[0]
        if now - (disconnectedAt ?? now) < window {
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: Self.fastProbeInterval, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.reconnectTimer = nil
                self.reconnectProbing = true
                let failed = self.client
                self.portOpen("127.0.0.1", UInt16(clamping: ReceiverLauncher.port())) { [weak self] open in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.reconnectProbing = false
                        // 探测期间用户停了或手动换了连线：这条探测作废
                        guard !self.userStopped, self.client === failed, !self.isLive else { return }
                        if open {
                            self.client?.close()
                            self.connect(endpoint, quiet: quiet)
                        } else {
                            self.scheduleReconnect(quiet: quiet)
                        }
                    }
                }
            }
            return
        }
        let wait = Self.backoff[min(reconnectStep, Self.backoff.count - 1)]
        reconnectStep += 1
        log("reconnect in \(Int(wait))s")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.reconnectTimer = nil
            // 只重连 WS 不够：receiver 可能已被 launchd 停掉/自己退出。先确保它在跑，
            // 再连；这样桌宠放着不管也能自己恢复，不用用户再重按一次。
            self.ensureReceiver { [weak self] in
                guard let self else { return }
                self.client?.close()
                self.connect(endpoint, quiet: quiet)
            }
        }
    }

    private func act(_ a: VideoHealth.Action, why: String) {
        if handoffFreeze { return }   // 正常的有线→无线切换：别让健康检查把冻结当成断流
        switch a {
        case .none: return
        case .requestKeyframe:
            log("health \(why)：要关键帧"); client?.requestKeyframe()
        case .rebuild:
            log("health \(why)：重建解码（第 \(health.totalRebuilds) 次）并要关键帧")
            view.decoder.rebuild(); client?.requestKeyframe()
        case .giveUp:
            log("health 视频恢复失败：断开重连")
            client?.close()   // 走 onLive(false) → 重连
        }
    }

    private func stats() {
        let now = CACurrentMediaTime(), dt = max(0.001, now - lastStats.t)
        let rf = Double(health.received - lastStats.recv) / dt, df = Double(health.decoded - lastStats.dec) / dt
        if health.received < lastStats.recv { lastStats = (now, 0, 0); return }   // 新连接计数归零
        lastStats = (now, health.received, health.decoded)
        guard view.showingVideo else { view.toolTip = nil; return }
        let s = view.decoder.size
        log(String(format: "stats recv %.1f fps decoded %.1f fps %dx%d rebuilds %d", rf, df, Int(s.width), Int(s.height), health.totalRebuilds))
        if ProcessInfo.processInfo.environment["HOMEPLAY_DEBUG_STATS"] != nil {   // 除錯用：游標停在桌寵上看收／解碼幀率
            view.toolTip = String(format: L("debug.stats", "接收 %.0f fps · 解码 %.0f fps · %d×%d"), rf, df, Int(s.width), Int(s.height))
        }
    }
}

extension Notification.Name {
    static let homePlaySiriHotKey = Notification.Name("HomePlaySiriHotKey")
}
