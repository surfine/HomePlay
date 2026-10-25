// 控制中心：從螢幕右上角往下拉（滑鼠：右上角往下拖、右鍵選單、C 鍵）。
// 2.0 cc：照 iOS 27／macOS 27 的控制中心重做（本機 macOS 27 截圖 realref/macos27-cc.webp 量的尺寸，見 Shell/ControlCenter/）：
// - 底下的畫面霧化壓暗（iOS 的 platter：模糊＋壓暗，跟著拉開的進度變濃）；上面一個 HPGlass.container 裝所有模組（Regular 玻璃）；
// - 模組有 1×1 圓鈕、2×1 膠囊、2×2、4×1 寬滑桿、4×2；6 欄 × 5 列一頁，放不下就到下一頁（右緣頁點）；
// - 按下：放大＋從觸點亮起（HPGlass interactive）；長按：模組長成大卡（Wi‑Fi 網路、藍牙裝置、專注模式、家庭、播放中＋輸出、聲音輸出）；
// - 滑桿 1:1 跟手，拖著時旋鈕變成玻璃（HPDS 4）；
// - 「編輯控制項目」：移除、換大小、拖曳排序、多頁、「加入控制項目」圖庫（照分類），每位家人存一份（PersonCC）。
// 這個檔是門面：模組種類、標題、圖示、開關狀態、版面位置；畫在 CCRender.swift、輸入在 CCInput.swift、系統狀態在 CCSystem.swift。

import AppKit
import AudioToolbox
import CoreAudio
import CoreImage

enum ControlCenter {
    /// 模組種類（舊的名字照留：focus＝番茄鐘、volume＝聲音、brightness＝顯示器）
    enum Tile: String, CaseIterable, Codable {
        case wifi, bluetooth, nowPlaying, focusMode, home, brightness, volume
        case darkMode, night, guest, timer, alarm, cameras, follow, carPlay, lockFace, focus, dnd, screenMirroring

        /// 允許的大小（第一個以外可以在編輯模式換）
        var sizes: [CCSize] {
            switch self {
            case .wifi, .bluetooth, .focusMode, .home: return [.s2x1, .s1x1]
            case .nowPlaying: return [.s2x2, .s4x2, .s2x1]
            case .brightness, .volume: return [.s4x1, .s2x1]
            default: return [.s1x1, .s2x1]
            }
        }
        var defaultSize: CCSize { sizes[0] }
        var category: CCCategory {
            switch self {
            case .wifi, .bluetooth, .screenMirroring: return .connectivity
            case .brightness, .darkMode, .night: return .display
            case .volume, .nowPlaying: return .sound
            case .focusMode, .dnd, .focus: return .focus
            case .home, .cameras: return .home
            case .timer, .alarm: return .clock
            case .guest, .follow, .carPlay, .lockFace: return .homePlay
            }
        }
        /// 長按會長成大卡的模組
        var expands: Bool { [.wifi, .bluetooth, .focusMode, .home, .nowPlaying, .volume, .brightness].contains(self) }
        var isSlider: Bool { self == .volume || self == .brightness }
        /// 開關（有開／關兩種狀態）；其餘是按鈕（打開某個 App、播放）
        var isToggle: Bool { ![.nowPlaying, .volume, .brightness, .timer, .alarm, .cameras, .screenMirroring, .home].contains(self) }
    }

    // MARK: 版面（1024 畫布）：一格 128、格距 24（macOS 27 截圖量到的 128／24，換到我們的畫布不縮放）

    static let cell: CGFloat = 128, gap: CGFloat = 24
    static let gridX: CGFloat = (1024 - 6 * 128 - 5 * 24) / 2   // 68
    static let gridY: CGFloat = 100
    static let gridH: CGFloat = 5 * 128 + 4 * 24               // 736
    /// 寬滑桿的圓角（截圖擬合成圓弧 ≈ 47）；2×2、4×2 ≈ 64（＝半格，跟膠囊同心）。我們用連續曲率的圓角，
    /// 2×2 的參數要小一點（refcompare 擬合：60 → 64）；寬滑桿只有 128 高，連續圓角最多 42，所以照截圖用一般圓弧 47
    static let wideRadius: CGFloat = 47, squareRadius: CGFloat = 60
    /// 底下的「編輯控制項目」膠囊（截圖 182×46 → 字放大到 HomeView 的字級，高 60）
    static let editCapsuleY: CGFloat = gridY + gridH + 32
    static let capsuleH: CGFloat = 60
    /// 長按展開的大卡（整個格子區）
    static let expandedRect = CGRect(x: gridX, y: gridY, width: 6 * 128 + 5 * 24, height: gridH)
    /// 舊名（P04 自檢、ShellAccessibility 用）
    static var radius: CGFloat { squareRadius }

    static func frame(col: Int, row: Int, size: CCSize) -> CGRect {
        CGRect(x: gridX + CGFloat(col) * (cell + gap), y: gridY + CGFloat(row) * (cell + gap),
               width: CGFloat(size.w) * cell + CGFloat(size.w - 1) * gap, height: CGFloat(size.h) * cell + CGFloat(size.h - 1) * gap)
    }
    /// 模組的外形：1×1 圓、2×1 膠囊、寬滑桿圓角 48、2×2／4×2 圓角 64
    static func shape(_ r: CGRect, _ size: CCSize) -> CGPath {
        switch size {
        case .s1x1, .s2x1: return CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        case .s4x1: return CGPath(roundedRect: r, cornerWidth: wideRadius, cornerHeight: wideRadius, transform: nil)
        case .s2x2, .s4x2: return continuousRoundedRect(r, radius: squareRadius)
        }
    }

    // MARK: 狀態

    /// 這次打開時是誰的版面（PersonCC）；編輯中改這份，按「完成」存回去
    nonisolated(unsafe) static var layout: CCLayout = PersonCC.current
    nonisolated(unsafe) static var page = 0
    nonisolated(unsafe) static var pageAnim = MotionValue("cc.page", spring: .smooth, from: 0, to: 0, now: 0)
    nonisolated(unsafe) static var editing = false
    nonisolated(unsafe) static var editAnim = MotionValue("cc.edit", spring: .smooth, from: 0, to: 0, now: 0)
    nonisolated(unsafe) static var gallery = false
    nonisolated(unsafe) static var galleryAnim = MotionValue("cc.gallery", spring: .smooth, from: 0, to: 0, now: 0)
    /// 長按展開的模組（從它原本的位置長成大卡）
    nonisolated(unsafe) static var expanded: Tile?
    nonisolated(unsafe) static var expandFrom: CGRect = .zero
    /// iOS 控制中心模組展開：有一點點過衝的彈簧（照 iOS 的 0.35 s 級；模擬器沒畫模組，量不到，推斷）
    static let expandSpring = Spring(damping: 0.86, response: 0.36)
    nonisolated(unsafe) static var expandAnim = MotionValue("cc.expand", spring: expandSpring, from: 0, to: 0, now: 0)
    /// 正在拖的滑桿（旋鈕變玻璃）與它的變化量
    nonisolated(unsafe) static var sliding: Tile?
    nonisolated(unsafe) static var slideAnim = MotionValue("cc.knob", spring: .interactive, from: 0, to: 0, now: 0)
    /// 編輯模式拖曳排序：拖著的模組、按下時手指離模組左上的距離、目前手指位置
    nonisolated(unsafe) static var drag: (tile: Tile, grab: CGPoint, at: CGPoint)?
    /// 版面換了（加、刪、換大小、排序）：每個模組從畫面上的位置滑到新位置
    nonisolated(unsafe) static var moves: [Tile: (from: CGRect, anim: MotionValue)] = [:]
    nonisolated(unsafe) static var lastShown: [Tile: CGRect] = [:]
    /// 長按：已經展開了，放手不要再當點按
    nonisolated(unsafe) static var longFired = false
    /// 示範用：家庭模組的配件開關（不寫進真的 HomeKit）
    nonisolated(unsafe) static var demoHomeOn: Set<String> = ["demo.l1", "demo.l3"]

    nonisolated(unsafe) static var volume: Float = SystemVolume.get() ?? 0.5
    nonisolated(unsafe) private static var lastVolumeRead = 0.0
    /// 開關狀態由 PetView 每幀填（跟隨我、CarPlay 要看 PetView 的狀態）
    nonisolated(unsafe) static var followOn = false
    nonisolated(unsafe) static var carPlayOn = false

    /// 打開時：換成眼前這個人的版面、回第一頁、收起展開與編輯
    static func willOpen() {
        layout = PersonCC.current
        page = 0; pageAnim = MotionValue("cc.page", spring: .smooth, from: 0, to: 0, now: 0)
        editing = false; gallery = false; expanded = nil; drag = nil; moves = [:]
        editAnim = MotionValue("cc.edit", spring: .smooth, from: 0, to: 0, now: 0)
        galleryAnim = MotionValue("cc.gallery", spring: .smooth, from: 0, to: 0, now: 0)
        expandAnim = MotionValue("cc.expand", spring: expandSpring, from: 0, to: 0, now: 0)
    }

    /// 開著時每秒讀一次系統音量（別處改了也跟上）；系統狀態 2 秒一次；動畫還在動就要重畫
    static func tick(_ now: Double) -> Bool {
        var dirty = false
        CCSystem.shared.refresh(now: now)
        if checkLongPress(now) { dirty = true }
        if now - lastVolumeRead > 1 {
            lastVolumeRead = now
            if let v = SystemVolume.get(), abs(v - volume) > 0.004, sliding != .volume { volume = v; dirty = true }
        }
        for a in [pageAnim, editAnim, galleryAnim, expandAnim, slideAnim] where !a.done(now) { dirty = true }
        if !moves.isEmpty { dirty = true; moves = moves.filter { !$0.value.anim.done(now) } }
        if expanded == nil, expandAnim.to == 0, expandAnim.done(now) { expandFrom = .zero }
        if drag != nil { dirty = true }
        return dirty
    }

    // MARK: 位置

    /// 第幾頁的模組排好的位置（目標位置，不含動畫）
    static func placed(page p: Int) -> [CCPlaced] {
        guard p >= 0, p < layout.pages.count else { return [] }
        return CCLayout.pack(layout.pages[p]).placed
    }
    /// 模組在目前這一頁的目標位置；不在這頁＝.null
    static func rect(_ t: Tile) -> CGRect {
        guard let pl = placed(page: page).first(where: { $0.slot.tile == t }) else { return .null }
        return frame(col: pl.col, row: pl.row, size: pl.slot.size)
    }
    static func size(_ t: Tile) -> CCSize { layout.all.first { $0.tile == t }?.size ?? t.defaultSize }
    /// 畫面上的位置（版面換了時在滑動）
    static func shownRect(_ t: Tile, now: Double) -> CGRect {
        let to = rect(t)
        guard let m = moves[t], !to.isNull else { return to }
        let k = m.anim.value(now)
        return CGRect(x: m.from.minX + (to.minX - m.from.minX) * k, y: m.from.minY + (to.minY - m.from.minY) * k,
                      width: m.from.width + (to.width - m.from.width) * k, height: m.from.height + (to.height - m.from.height) * k)
    }
    /// 點在哪個模組上（目前這頁）
    static func tile(at p: CGPoint) -> Tile? {
        placed(page: page).first { frame(col: $0.col, row: $0.row, size: $0.slot.size).insetBy(dx: -6, dy: -6).contains(p) }?.slot.tile
    }

    /// 改版面：記下每個模組畫面上的位置，新位置用彈簧滑過去（Mark View R10：鄰居讓位 Spring(0.30, 1.0)）
    static func apply(_ change: (inout CCLayout) -> Void, now: Double = CACurrentMediaTime()) {
        let before = Dictionary(uniqueKeysWithValues: layout.all.map { ($0.tile, lastShown[$0.tile] ?? rect($0.tile)) })
        change(&layout)
        page = min(page, layout.pages.count - 1)
        for s in layout.all {
            guard let from = before[s.tile], !from.isNull else { continue }
            let to = rect(s.tile)
            if !to.isNull, from != to { moves[s.tile] = (from, MotionValue("cc.move", spring: HPMotion.T.listMove.spring, from: 0, to: 1, now: now)) }
        }
        if let id = PersonCC.viewerID, PersonCC.canEdit { PersonCC.set(layout, for: id) }
    }

    // MARK: 文字、圖示、狀態

    static func isOn(_ t: Tile, face: Face) -> Bool {
        let s = CCSystem.shared
        switch t {
        case .wifi: return s.wifi.on
        case .bluetooth: return s.bluetooth.on
        case .focusMode: return s.focus.active != nil
        case .dnd: return s.focus.active == "com.apple.donotdisturb.mode.default"
        case .darkMode: return HPTokens.dark
        case .focus: return face.pomodoro.active
        case .guest: return Shell.guestMode
        case .follow: return followOn
        case .carPlay: return carPlayOn
        case .timer: return !Shell.timers.isEmpty || face.timerActive
        case .lockFace: return Shell.lockFace
        case .night: return Shell.manualNight
        case .alarm: return AlarmCenter.shared.alarms.contains { $0.enabled }
        case .home: return homeOnCount > 0
        case .cameras, .nowPlaying, .volume, .brightness, .screenMirroring: return false
        }
    }
    static func title(_ t: Tile) -> String {
        switch t {
        case .wifi: return "Wi‑Fi"
        case .bluetooth: return L("cc.bluetooth", "蓝牙")
        case .nowPlaying: return L("cc.nowPlaying", "播放中")
        case .focusMode: return L("cc.focusMode", "专注模式")
        case .dnd: return L("cc.dnd", "勿扰模式")
        case .home: return L("cc.home", "家庭")
        case .brightness: return L("cc.display", "显示器")
        case .volume: return L("cc.sound", "声音")
        case .darkMode: return L("cc.darkMode", "深色模式")
        case .focus: return L("cc.pomodoro", "番茄钟")
        case .guest: return L("cc.guest", "访客模式")
        case .follow: return L("cc.follow", "跟随我")
        case .carPlay: return "CarPlay"
        case .timer: return L("app.timers", "计时器")
        case .alarm: return L("cc.alarm", "闹钟")
        case .lockFace: return L("cc.lockFace", "锁定表盘")
        case .night: return L("cc.night", "夜间")
        case .cameras: return L("cc.cameras", "摄像头")
        case .screenMirroring: return L("cc.screenMirroring", "屏幕镜像")
        }
    }
    /// 第二行（膠囊、大卡用）：狀態或細節
    static func subtitle(_ t: Tile, face: Face) -> String? {
        let s = CCSystem.shared
        if locked(t) { return L("guest.needsOwner", "需要主人") }
        switch t {
        case .wifi:
            if !s.wifi.available { return L("cc.unavailable", "不可用") }
            if !s.wifi.on { return L("cc.state.off", "关闭") }
            return s.wifi.ssid ?? (s.wifi.connected ? L("cc.connected", "已连接") : L("cc.notConnected", "未连接"))
        case .bluetooth:
            if !s.bluetooth.available { return L("cc.unavailable", "不可用") }
            return s.bluetooth.on ? L("cc.state.on", "打开") : L("cc.state.off", "关闭")
        case .focusMode:
            if let a = s.focus.active { return s.focus.modes.first { $0.id == a }?.name ?? L("cc.state.on", "打开") }
            return nil
        case .home:
            let n = homeOnCount
            return n == 0 ? nil : String(format: L("cc.home.onCount", "%d 个开着"), n)
        default:
            return isOn(t, face: face) && t.isToggle ? L("cc.state.on", "打开") : nil
        }
    }
    static func symbol(_ t: Tile, face: Face? = nil) -> String {
        let s = CCSystem.shared
        switch t {
        case .wifi: return s.wifi.on ? "wifi" : "wifi.slash"
        case .bluetooth: return "bluetooth"
        case .focusMode:
            if let a = s.focus.active, let m = s.focus.modes.first(where: { $0.id == a }) { return m.symbol }
            return "moon.fill"
        case .dnd: return "moon.fill"
        case .home: return "house.fill"
        case .darkMode: return "circle.lefthalf.filled"
        case .focus: return "hourglass"
        case .guest: return "person.fill"
        case .follow: return "eye.fill"
        case .carPlay: return "car.fill"
        case .timer: return "timer"
        case .alarm: return "alarm.fill"
        case .lockFace: return "lock.fill"
        case .night: return "moon.stars.fill"
        case .cameras: return "video.fill"
        case .nowPlaying: return "play.fill"
        case .volume: return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .screenMirroring: return "rectangle.on.rectangle"
        }
    }
    /// 開著時符號的顏色（白圓上；照系統：連線藍、專注靛、家庭橘、計時橘…）
    static func accent(_ t: Tile) -> NSColor {
        switch t {
        case .wifi, .bluetooth, .screenMirroring: return HPTokens.blue
        case .focusMode, .dnd, .darkMode:
            if t == .focusMode, let a = CCSystem.shared.focus.active, let m = CCSystem.shared.focus.modes.first(where: { $0.id == a }) { return m.tint }
            return HPTokens.indigo
        case .home: return HPTokens.orange
        case .timer, .alarm, .focus: return HPTokens.orange
        case .night: return HPTokens.red
        case .guest, .follow, .lockFace, .carPlay: return HPTokens.blue
        case .cameras: return HPTokens.green
        case .nowPlaying, .volume, .brightness: return HPTokens.blue
        }
    }

    /// 2.0 cc：要主人的模組（訪客、遠端訪客、沒認出主人）：家庭與攝影機照 PersonalGate.locks("home")，
    /// 動到整台 Mac 的（Wi‑Fi、藍牙、專注模式、勿擾、螢幕鏡像）要主人。
    /// 遠端訪客（訪客的 iPhone／iPad 一分鐘內點過，RemotePrivacy.guestActive）：改狀態或露出個人資料的全部鎖住、不收點按——
    /// 只留聲音與顯示器滑桿（不露資料）、計時器與鬧鐘（訪客允許清單裡的 App）、播放中（使用者 2026-10-25：訪客可播放／暫停／切歌、看曲名；輸出與 AirPlay 仍鎖）
    static func locked(_ t: Tile) -> Bool { locked(t, PersonalGate.inputs) }
    static let remoteGuestAllowed: Set<Tile> = [.volume, .brightness, .timer, .alarm, .nowPlaying]
    static func locked(_ t: Tile, _ i: PersonalGate.Inputs) -> Bool {
        if i.remoteGuest, !remoteGuestAllowed.contains(t) { return true }
        switch t {
        case .home, .cameras: return PersonalGate.locks("home", i) || !PersonalGate.allowed(i) && i.guestMode
        case .wifi, .bluetooth, .focusMode, .dnd, .screenMirroring: return !PersonalGate.allowed(i)
        default: return false
        }
    }
    /// 遠端訪客在用：聲音大卡裡的輸出、AirPlay 鈕也不給（改的是整台 Mac 的輸出）
    static var outputsLocked: Bool { PersonalGate.inputs.remoteGuest }
    /// 訪客模式要關掉：關掉之後主人的門要開得了（不然訪客自己點一下就把訪客模式關了）
    static var canLeaveGuest: Bool {
        var i = PersonalGate.inputs; i.guestMode = false
        return PersonalGate.allowed(i)
    }

    // MARK: 家庭（HomeLink 的快照；快照與示範用示範資料，示範的開關只改本機）
    // 2.0 depth：真的使用者沒有小幫手、還在連、家裡沒配件時，以前也拿示範的燈充數（磚上寫「2 個開著」）；現在照家庭 App 說實話

    static var homeSnapshot: HomeSnapshot { homeIsDemo ? HomeAppModel.demoSnapshot() : HomeLink.shared.snapshot }
    /// --cc-home-real：快照裡也走真的（沒有小幫手）那條路，驗收空狀態
    static var homeIsDemo: Bool { CCSystem.demo && !CommandLine.arguments.contains("--cc-home-real") }
    /// 真的家庭現在是哪一種（示範＝ready）
    static var homeState: HomeAppState {
        if homeIsDemo { return .ready }
        let s = HomeLink.shared.snapshot
        return HomeAppModel.state(installed: HomeLink.helperInstalled, connected: HomeLink.shared.connected, ready: s.ready, accessories: s.accessories.count)
    }
    /// 大卡裡的配件（燈、插座先；最多 6 個）
    static var homeTiles: [HomeTile] {
        let tiles = HomeAppModel.groups(homeSnapshot).flatMap(\.tiles).filter { $0.kind == .light || $0.kind == .outlet }
        guard homeIsDemo else { return Array(tiles.prefix(6)) }
        return Array(tiles.prefix(6)).enumerated().map { i, t in var t = t; t.on = demoHomeOn.contains("demo.l\(i + 1)"); return t }
    }
    static var homeOnCount: Int { locked(.home) ? 0 : homeTiles.filter(\.on).count }
}

/// 系統輸出音量（預設輸出裝置的虛擬主音量）。拿不到或不能設就回 nil／不動。
enum SystemVolume {
    private static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }
    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    static func get() -> Float? {
        guard let d = device() else { return nil }
        var addr = address, v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(d, &addr), AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }
    static func set(_ v: Float) {
        guard !CCSystem.demo else { return }   // 2.0 cc：快照與自檢不動真的音量
        guard let d = device() else { return }
        var addr = address, settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(d, &addr), AudioObjectIsPropertySettable(d, &addr, &settable) == noErr, settable.boolValue else { return }
        var x = Float32(max(0, min(1, v)))
        _ = AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &x)
    }
}
