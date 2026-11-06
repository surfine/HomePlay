// 家庭 App（稿：hv-design/project/Home.dc.html；研究 handson.md §Home Camera）：
// - 房間：頂端一排房間膠囊（放不下就左右小箭頭），底下場景一排，再來是配件磚；開著的＝亮白磚。
//   點一下切換；長按燈／窗簾開「調整」（亮度、位置）；滾輪捲動磚、在調整面板裡改數值；溫控磚兩側是 − ＋。
//   門鎖：鎖著的門第一下只待命（「再按一次开锁」），4 秒內再按才開鎖；上鎖不需確認。
// - 攝影機：最多 4 路，2×2 的快照格（每 10 秒更新）；點一格進單一攝影機頁（照實機：× 左上、喇叭右上、16:9 置中、
//   左下格狀鈕、右下黃色麥克風；雙向語音不支援，麥克風與喇叭是灰的並註明）。
// - 沒裝「HomePlay Home」小幫手（公開版）：一張誠實的說明卡＋開 Mac「家庭」App 的按鈕。
// 資料全來自 HomeLink（HomeKit 只有開發簽名的 Catalyst 小幫手拿得到）；純邏輯在 HomeAppModel.swift。
// 快照旗標：--demo-home（示範資料）、--home-tab N|cameras、--home-camera N、--home-detail [light|thermostat|ac|covering]、--home-view nohelper|connecting|empty
// 2.0 r2（R8，照影片 v1 01:50–01:52、v2 00:41–00:44）：大標題下一排小字房間分頁；3 欄正方磚（300、間距 20、圓角 50），
//   圖示＋兩行標籤置中；開＝不透明白、關＝灰色半透明玻璃；溫控與攝影機快照可跨 2×2。點溫控（或長按燈／窗簾）
//   從磚放大成滿版卡（臨界阻尼、無回彈），縮回同一塊磚；燈的滿版是黃色水位（滾輪／觸控板 1:1 跟手，拉過頭有阻力）。
//   攝影機是全螢幕：頂端漸層上名稱與快照時間，底部紅 ✕、黃麥克風（不支援雙向語音：灰掉）、玻璃格狀鈕。
// 2.0 r3（R15，照官方 home-light.png 量）：根頁沒有標題、沒有房間分頁、沒有 ✕ 與時間——白底上 3×3 磚從螢幕邊 20 鋪滿
//   （磚 317、間距 16、連續圓角 58）；開＝家的顏色淡紫底＋同色系深一階的圖示與名稱，關＝淺灰；名稱拿掉房間名、第二行是房間。
//   排法：類比時鐘、前兩個配件；攝影機、「家庭」（開 Mac 的家庭 App）、第一個場景；其餘接在後面。攝影機格狀頁是子頁（‹）。

import AppKit

final class HomeApp: PetApp {
    static let shared = HomeApp()
    let id = "home"
    var title: String { L("app.home", "家庭") }
    let icon = AppIcon(color: srgb(0xff9500), symbol: "house.fill", system: "/System/Applications/Home.app")

    // MARK: 旗標（只給快照用）
    private static let args = CommandLine.arguments
    private static func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    static let demo = args.contains("--demo-home") || args.contains("--demo-promo") || OfficialDemo.on   // 2.0 promo：宣傳片示範也用示範攝影機
    private static let forcedView = arg("--home-view")

    // MARK: 狀態
    private var tab = 0                      // 0…n-1 房間，n ＝ 攝影機
    private var scroll: CGFloat = 0
    private var cameraID: String?            // 單一攝影機頁
    private var detail: String?              // 滿版控制卡的磚 id
    private var detailFrom = CGRect.zero     // 從哪塊磚長出來（縮回同一塊）
    private var detailAnim = Anim(0, name: "home.expand")
    private var detailOpenedAt = 0.0
    private var detailClosing = false
    /// 燈／窗簾滿版的水位：raw 可以超出 0…1（拉過頭），畫的時候加阻力；停手後用彈簧回到範圍內
    private var levelRaw: Double?
    private var levelAnim: Anim?
    private var levelLastScroll = 0.0
    private var levelVelocity: CGFloat = 0
    private var locks = LockConfirm()
    private var demoSnap = OfficialDemo.on ? OfficialDemo.homeSnapshot() : HomeAppModel.demoSnapshot()
    private var observers: [NSObjectProtocol] = []
    private var dirty = false
    private var lastSecond = -1
    private var sceneFlash: (id: String, until: Double)?
    private var schedule = SnapshotSchedule()
    /// 即時畫面：正在請幫手串流的那一路、上次續約、每一路最後一格的時間
    private var liveID: String?
    private var liveRenewAt = -100.0
    private var liveFrameAt: [String: Double] = [:]
    private var cameraFlagApplied = false
    private var images: [String: CGImage] = [:]
    private var demoImages: [String: CGImage] = [:]
    private var pendingWrite: (id: String, value: HomeValue, type: String)?
    private var lastWrite = 0.0
    // 2.0 home-1：「家庭狀態」子頁、遠看摘要（Shell/HomeStatus.swift）
    private var statusOpen = HomeApp.args.contains("--home-status")
    private var status = HomeStatusPage()
    private var lastReveal: CGFloat = 1

    private var clock: Double { CACurrentMediaTime() }

    private var snap: HomeSnapshot { Self.demo ? demoSnap : HomeLink.shared.snapshot }
    /// 家庭警報橪幅的命中範圍（畫的時候更新；nil＝沒橪幅）
    var alertRect: CGRect?
    private var alertVersion = 0
    private var state: HomeAppState {
        switch Self.forcedView {
        case "nohelper": return .noHelper
        case "connecting": return .connecting
        case "empty": return .empty
        default: break
        }
        if Self.demo { return .ready }
        return HomeAppModel.state(installed: HomeLink.helperInstalled, connected: HomeLink.shared.connected, ready: snap.ready, accessories: snap.accessories.count)
    }

    // 2.0: ClioTalk 的 show_camera：打開家庭 App 並直接進攝影機（nil＝格狀；有 id＝單一攝影機）
    private var wantCameras: (id: String?, at: Double)?
    @MainActor func showCameras(id: String?) -> Bool {
        guard let v = (NSApp.delegate as? AppDelegate)?.view else { return false }
        wantCameras = (id, clock)
        v.shellOpenApp("home")
        return true
    }

    /// 2.0 promo：攝影機一瞥開哪一路（設定過的那一路，沒有就第一路）
    var glanceCameraID: String? {
        let cams = HomeAppModel.cameras(snap)
        return (cams.first { $0.id == CameraGlance.preferredID } ?? cams.first)?.id
    }

    func didOpen(now: Double) {
        if Self.demo { HomeActivity.shared.seedDemo(demoSnap, now: Date()) }   // 2.0 home-1：示範的家庭動態
        statusOpen = Self.args.contains("--home-status"); status = HomeStatusPage()
        scroll = 0; detail = nil; detailClosing = false; levelRaw = nil; levelAnim = nil; cameraID = nil; locks.cancel(); tab = 0
        if let w = wantCameras, clock - w.at < 5 {   // 2.0: 只認剛剛 ClioTalk 要的那一次
            tab = 1
            if let id = w.id, HomeAppModel.cameras(snap).contains(where: { $0.id == id }) { cameraID = id }
        }
        wantCameras = nil
        if let t = Self.arg("--home-tab") { tab = t == "cameras" ? 1 : 0 }
        if let v = Self.arg("--home-scroll").flatMap(Double.init) { scroll = CGFloat(v) }   // 第四輪快照：捲到後面的磚   // R15：根頁是一整頁磚，只剩「攝影機」一個子頁
        if let c = Self.arg("--home-camera"), let i = Int(c) {
            let cams = HomeAppModel.cameras(snap)
            if i < cams.count { cameraID = cams[i].id }
        }
        if Self.args.contains("--home-detail") {
            let want = Self.arg("--home-detail") ?? "light"
            let all = HomeAppModel.groups(snap).flatMap(\.tiles)
            let t: HomeTile? = want == "thermostat" ? all.first { $0.kind == .thermostat } : want == "ac" ? all.first { $0.kind == .thermostat && $0.activeID != nil } : want == "covering" ? all.first { $0.kind == .covering }
                : all.first { $0.kind == .light && $0.brightnessID != nil && $0.on }
            if let t {
                tab = 0
                openDetail(t, from: tileLayout(page()).first { $0.item.tile?.id == t.id }?.rect ?? CGRect(x: 362, y: 352, width: 300, height: 300), now: clock)
            }
        }
        guard !Self.demo, Self.forcedView == nil, HomeLink.helperInstalled else { return }
        HomeLink.shared.start()
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName: .homeCameraFrame, object: nil, queue: .main) { [weak self] n in
                guard let self, let f = n.object as? HomeCameraFrame else { return }
                self.images[f.id] = f.image; self.liveFrameAt[f.id] = self.clock; self.dirty = true
                CameraTimeline.shared.add(f.id, f.image)   // 體驗追趕 P4：近況時間軸（至少隔 20 秒收一格）
            })
            for n in [Notification.Name.homeLinkSnapshot, .homeLinkChanged, .homeLinkConnection] {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.dirty = true })
            }
        }
    }

    // MARK: 版面（1024 畫布，左上原點）

    // R15（官方 home-light）：沒有標題、沒有房間分頁，3×3 磚從螢幕邊 20 鋪滿（HPTokens.HomeGrid）
    private static let gridX = HPTokens.HomeGrid.margin, tile = HPTokens.HomeGrid.tile, gap = HPTokens.HomeGrid.gap, tileRadius = HPTokens.HomeGrid.radius
    private static let gridTop = HPTokens.HomeGrid.margin
    private static let viewBottom: CGFloat = 1024
    private static let cols = 3

    /// 一格裡放什麼：配件磚、場景、攝影機快照
    /// 一格裡放什麼：配件磚、場景、攝影機快照、類比時鐘、「家庭」（開 Mac 的家庭 App）
    private enum Item { case tile(HomeTile), scene(HomeScene), camera(HomeCameraItem), clock, homeApp, status
        var tile: HomeTile? { if case .tile(let t) = self { return t }; return nil }
        var big: Bool { if case .tile(let t) = self { return t.kind == .thermostat }; return false }
    }
    /// R15：官方那一頁的排法——時鐘、前兩個配件；攝影機、家庭、第一個場景；其餘配件、場景、攝影機接在後面
    private func items(_ p: Page) -> [Item] {
        guard let g = p.group else { return [] }
        // 2.0 home-1：這台所在的房間（HomeThisRoom）的磚排最前面（HomePod：預設控制自己所在的房間）
        let here = HomeThisRoom.room(in: snap)?.id
        let ordered = here.map { r in g.tiles.filter { $0.room == r } + g.tiles.filter { $0.room != r } } ?? g.tiles
        let tiles = ordered.map { Item.tile($0) }, scenes = p.scenes.map { Item.scene($0) }, cams = p.cameras.map { Item.camera($0) }
        if Self.guestView { return [.clock] + tiles }   // 訪客版：沒有「家庭」磚（會在 Mac 上開家庭 App）
        // 狀態磚：一切正常時排在第一個場景之後；有問題（配件沒回應、中樞離線）就插隊到第一列右上角（提案原則 4：只有急事插隊；
        // 中上那格在 👀 藥丸底下，圖示會被蓋住，所以不放那裡）
        if !HomeHealth.make(snap, lastSeen: HomeActivity.shared.lastSeen).ok {
            return [.clock] + tiles.prefix(1) + [.status] + tiles.dropFirst(1).prefix(1) + cams.prefix(1) + [.homeApp] + scenes.prefix(1) + tiles.dropFirst(2) + scenes.dropFirst(1) + cams.dropFirst(1)
        }
        return [.clock] + tiles.prefix(2) + cams.prefix(1) + [.homeApp] + scenes.prefix(1) + [.status] + tiles.dropFirst(2) + scenes.dropFirst(1) + cams.dropFirst(1)
    }
    /// 磚上第二行：房間名
    private func roomName(_ t: HomeTile, _ p: Page) -> String { p.groups.first { $0.id == t.room }?.name ?? "" }
    private func tileLayout(_ p: Page) -> [(rect: CGRect, item: Item)] {
        let list = items(p)
        return zip(HomeGrid.pack(list.map { $0.big ? 2 : 1 }, columns: Self.cols), list).map { slot, it in
            let w = CGFloat(slot.size) * Self.tile + CGFloat(slot.size - 1) * Self.gap
            return (CGRect(x: Self.gridX + CGFloat(slot.col) * (Self.tile + Self.gap), y: Self.gridTop + CGFloat(slot.row) * (Self.tile + Self.gap) - scroll, width: w, height: w), it)
        }
    }
    private func maxScroll(_ p: Page) -> CGFloat {
        let slots = HomeGrid.pack(items(p).map { $0.big ? 2 : 1 }, columns: Self.cols)
        let rows = slots.map { $0.row + $0.size }.max() ?? 0
        let h = CGFloat(rows) * (Self.tile + Self.gap) - Self.gap
        return max(0, Self.gridTop + h + Self.gridX - Self.viewBottom)
    }
    /// 溫控磚：標籤兩側的 chevron.down／up（影片 v2 O108）
    private static func thermoChevrons(_ r: CGRect) -> (down: CGRect, up: CGRect) {
        // 第四輪：照 Home Modular——箭頭中心離磚頂 556、離左右緣 92（644 的磚；照比例換算）
        typealias M = HPTokens.HomeModular
        let k = r.height / (2 * M.cell + M.gap), cy = r.minY + M.chevronY * k, dx = M.chevronInset * k
        return (CGRect(x: r.minX + dx - 48, y: cy - 48, width: 96, height: 96), CGRect(x: r.maxX - dx - 48, y: cy - 48, width: 96, height: 96))
    }
    /// 攝影機子頁（大標題底下 2×2）；11-grid-apps：格線對齊 App 內容區 64…960（磚 432、欄距 32，列距 328 給標籤留 85）
    static func cameraCells(_ n: Int) -> [CGRect] {
        if n > 4 {   // 2.0 P10：五路以上排 3×3（官方 Home Camera 九路）
            typealias C = HPTokens.HomeCameras
            let w = (1024 - 2 * C.x - CGFloat(C.gridColumns - 1) * C.gap) / CGFloat(C.gridColumns), h = (w * 9 / 16).rounded()
            return (0..<n).map { i in CGRect(x: C.x + CGFloat(i % C.gridColumns) * (w + C.gap), y: HPTokens.contentTop + 8 + CGFloat(i / C.gridColumns) * (h + C.labelGap + C.gap), width: w, height: h) }
        }
        return (0..<n).map { i in CGRect(x: 64 + CGFloat(i % 2) * (432 + 32), y: HPTokens.contentTop + 8 + CGFloat(i / 2) * 328, width: 432, height: 243) }
    }
    // 攝影機全螢幕：底部三顆 150 px 圓鈕（紅黃兩顆靠中、格狀鈕貼右；影片 v1 O-84）
    private static let camY: CGFloat = 1024 - Screen.cornerRadius
    private static let camClose = HPComponents.actionRect(cx: 512 - 100, cy: camY)
    /// 右上：完整畫面 ↔ 填滿（方形螢幕放 16:9／4:3 的取捨，每台記住）
    private static let camFit = CGRect(x: 820, y: 124, width: 88, height: 88)
    private static let camFillKey = "HomeCameraFill"
    /// 這台要填滿（裁切）嗎；預設＝完整畫面（監控要看得到整個場景）
    private func camFill(_ id: String) -> Bool { (UserDefaults.standard.dictionary(forKey: Self.camFillKey)?[id] as? Bool) ?? false }
    private func toggleCamFill(_ id: String) {
        var d = UserDefaults.standard.dictionary(forKey: Self.camFillKey) ?? [:]
        d[id] = !camFill(id)
        UserDefaults.standard.set(d, forKey: Self.camFillKey)
        dirty = true
    }
    private static let camMic = HPComponents.actionRect(cx: 512 + 100, cy: camY)
    private static let camGrid: CGRect = {
        let c = Screen.cornerCapsuleCenter(.bottomRight, width: HPComponents.actionSize, height: HPComponents.actionSize); return HPComponents.actionRect(cx: c.x, cy: c.y)
    }()
    private static let openHomeButton = CGRect(x: 512 - 330, y: 700, width: 660, height: 112)
    // 沒有小幫手時的捷徑導引（B 方案）：主按鈕＝建立或執行，次按鈕＝去設定填名字
    private static let shortcutMainButton = CGRect(x: 512 - 330, y: 640, width: 660, height: 112)
    private static let shortcutSettingsButton = CGRect(x: 512 - 250, y: 640 + 112 + HPGrid.Rhythm.groupGap, width: 500, height: HPTokens.Size.pill)   // 2.0 align F：玻璃膠囊 88 → pill 104
    // 滿版控制卡
    private static let thermoDown = HPComponents.actionRect(cx: 150, cy: 520, size: HPTokens.Size.round)   // 2.0 align F：圓形主按鈕 120 → round 150
    private static let thermoUp = HPComponents.actionRect(cx: 874, cy: 520, size: HPTokens.Size.round)
    private static let thermoPower = CGRect(x: 512 - 150, y: 848 - HPTokens.Size.pill / 2, width: 300, height: HPTokens.Size.pill)   // 96 → pill 104，中心 848 不動
    /// 功能補齊：溫控頁底下的模式列（跟開關鈕同一條中線 848；四段各 168）
    private static let thermoModes = CGRect(x: 512 - 336, y: 848 - 48, width: 672, height: 96)
    /// 模式列每一段的框（畫的時候更新，點按用）
    private var modeHits: [(CGRect, HomeClimateMode)] = []

    // MARK: 選擇

    private struct Page {
        var groups: [HomeRoomGroup]
        var cameras: [HomeCameraItem]
        var scenes: [HomeScene]
        var onCameras: Bool
        var group: HomeRoomGroup?
    }
    /// 2.0 idle（使用者 2026-10-25）：訪客的 iPhone／iPad 在用時只給燈——別的配件、場景、攝影機、「家庭」磚都不畫、點不到
    static var guestView: Bool { RemotePrivacy.guestActive }
    /// 訪客可以寫的特性：燈的開關、亮度（純函數，selftest 拿示範家庭驗）
    static func guestWritable(_ charID: String, in s: HomeSnapshot) -> Bool {
        HomeAppModel.groups(s).flatMap(\.tiles).contains { $0.kind == .light && ($0.powerID == charID || $0.brightnessID == charID) }
    }
    private func guestWritable(_ charID: String) -> Bool { Self.guestWritable(charID, in: snap) }
    private func page() -> Page {
        let s = snap
        var groups = HomeAppModel.groups(s), cams = HomeAppModel.cameras(s), scenes = HomeAppModel.scenes(s)
        if Self.guestView {
            groups = groups.map { var g = $0; g.tiles = g.tiles.filter { $0.kind == .light }; return g }
            cams = []; scenes = []
        }
        // R15：根頁＝所有房間的磚合成一頁（官方那一頁沒有房間分頁）；tab 1＝攝影機子頁
        let onCams = !cams.isEmpty && tab >= 1
        let dash = HomeRoomGroup(id: "*", name: HomeAppModel.homeName(s), tiles: groups.flatMap(\.tiles))
        return Page(groups: groups, cameras: cams, scenes: scenes, onCameras: onCams, group: onCams ? nil : dash)
    }
    private func currentTile(_ p: Page) -> HomeTile? {
        guard let d = detail else { return nil }
        return p.groups.flatMap(\.tiles).first { $0.id == d }
    }

    // MARK: tick

    // 2.0 r2：滿版控制卡與攝影機是全螢幕（外殼的返回鈕與時間不畫，卡上自己畫）
    // R15：根頁跟官方一樣磚鋪滿、不畫 ✕ 與時間（離開：Esc／↓、底部往上推）；攝影機子頁照常有 ‹ 與時間
    private var onDashboard: Bool { state == .ready && detail == nil && cameraID == nil && !page().onCameras && !statusOpen }
    var showsCloseButton: Bool { detail == nil && cameraID == nil && !onDashboard }
    var showsClock: Bool { detail == nil && cameraID == nil && !onDashboard }
    var backSymbol: String { state == .ready && (page().onCameras || statusOpen) ? "chevron.left" : "xmark" }
    func handleBack(now: Double) -> Bool {
        if statusOpen, cameraID == nil, detail == nil { statusOpen = false; status = HomeStatusPage(); return true }
        if detail != nil, !detailClosing { closeDetail(now: clock); return true }
        if cameraID != nil { cameraID = nil; return true }
        if tab != 0, state == .ready { tab = 0; scroll = 0; return true }
        return false
    }

    func tick(_ now: Double) -> Bool {
        if alertVersion != HomeAlerts.version { alertVersion = HomeAlerts.version; dirty = true }   // HomeView 對齊 #3：警報有變化就重畫
        let t = clock
        var redraw = dirty; dirty = false
        if HPComponents.needsFrame(now) { redraw = true }
        if detail != nil {
            if !detailAnim.done(t) { redraw = true }
            if detailClosing, detailAnim.done(t) || detailAnim.value(t) < 0.002 { detail = nil; detailClosing = false; levelRaw = nil; levelAnim = nil; redraw = true }
            settleLevel(t, &redraw)
        }
        if locks.expire(t) { redraw = true }
        if let f = sceneFlash, t >= f.until { sceneFlash = nil; redraw = true }
        if let w = pendingWrite, t - lastWrite > 0.15 { flush(w); pendingWrite = nil }
        if pendingWrite == nil, !throttleOrigin.isEmpty, t - lastWrite > 1 { throttleOrigin = [:] }
        let st = state
        if st == .ready, !Self.demo, Self.forcedView == nil {
            // 快照旗標 --home-camera N：真資料晚到（打開 App 時還沒有攝影機清單），到了再套一次
            if !cameraFlagApplied, let c = Self.arg("--home-camera"), let i = Int(c) {
                let cams = HomeAppModel.cameras(snap)
                if i < cams.count { cameraID = cams[i].id; cameraFlagApplied = true }
            }
            let p = page()
            // 第四輪：根頁上的攝影機磚也要快照（打開就要一張，到之前是佔位）
            let ids = cameraID.map { [$0] } ?? (p.onCameras || detail == nil ? p.cameras.map(\.id) : [])
            for id in schedule.next(ids, now: t) {   // 2.0 P10：九路錯開、限速（SnapshotSchedule.next）
                schedule.began(id, now: t)
                HomeLink.shared.cameraSnapshot(id: id) { [weak self] data, _ in
                    guard let self else { return }
                    // 解得出圖才算拿到（以前「有資料」就算，解不出也會顯示「N 秒前」）
                    let img = data.flatMap { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
                    if let img, self.liveFrameAt[id].map({ self.clock - $0 < 3 }) != true { self.images[id] = img }   // 即時畫面在跑就別拿快照蓋回去
                    if let img { CameraTimeline.shared.add(id, img) }   // 體驗追趕 P4：近況時間軸
                    self.schedule.finished(id, ok: img != nil, now: self.clock)
                    self.dirty = true
                }
            }
        }
        // 即時畫面：單一攝影機頁（含門鈴接管）開著就請幫手串流——每 10 秒續約，幫手 30 秒沒續就收；離開這頁就關
        let wantLive = st == .ready && !Self.demo && Self.forcedView == nil ? cameraID : nil
        if wantLive != liveID {
            if let old = liveID { HomeLink.shared.cameraStream(id: old, on: false) }
            liveID = wantLive; liveRenewAt = -100
        }
        if let id = liveID, t - liveRenewAt > 10 { liveRenewAt = t; HomeLink.shared.cameraStream(id: id, on: true) }
        if cameraID != nil || page().onCameras {   // 「N 秒前」每秒更新
            let s = Int(t)
            if s != lastSecond { lastSecond = s; redraw = true }
        }
        return redraw
    }

    // MARK: 寫入

    private func commit(_ charID: String, _ value: HomeValue, type: String) {
        let guestOK = guestWritable(charID)
        if HomeWrite.refusesGuest && !guestOK { return }   // 2.0 idle: 訪客裝置只能動燈（示範資料也一樣，selftest 驗）
        if Self.demo {
            for ai in demoSnap.accessories.indices {
                for ci in demoSnap.accessories[ai].characteristics.indices where demoSnap.accessories[ai].characteristics[ci].id == charID {
                    demoSnap.accessories[ai].characteristics[ci].value = value
                    let follow = ["lockTarget": "lockCurrent", "targetPosition": "currentPosition"][type]
                    if let follow, let j = demoSnap.accessories[ai].characteristics.firstIndex(where: { $0.type == follow }) { demoSnap.accessories[ai].characteristics[j].value = value }
                }
            }
            dirty = true; return
        }
        // 第四輪：本機先改、送出、成功重讀、失敗還原（HomeWrite.swift）
        HomeWrite.perform(charID, value, guestOK: guestOK) { [weak self] _ in self?.dirty = true }
        dirty = true
    }
    /// 連續調整開始前的值（送出失敗時還原成它）；停手 1 秒後清掉
    private var throttleOrigin: [String: HomeValue] = [:]
    private func flush(_ w: (id: String, value: HomeValue, type: String)) {
        lastWrite = clock
        if !Self.demo {
            HomeWrite.perform(w.id, w.value, revertTo: throttleOrigin[w.id]) { [weak self] _ in self?.dirty = true }
        }
    }
    /// 連續調整（滾輪、− ＋）：本機馬上改，送出節流到 0.15 秒一次
    private func commitThrottled(_ charID: String, _ value: HomeValue, type: String) {
        if HomeWrite.refusesGuest && !guestWritable(charID) { return }   // 2.0 idle
        if Self.demo { commit(charID, value, type: type); return }
        if throttleOrigin[charID] == nil { throttleOrigin[charID] = HomeLink.shared.value(of: charID) }
        HomeLink.shared.applyLocal(characteristic: charID, value: value)
        if clock - lastWrite > 0.15 { flush((charID, value, type)); pendingWrite = nil } else { pendingWrite = (charID, value, type) }
        dirty = true
    }

    private func setLevel(_ t: HomeTile, _ level: Double) {
        let lv = t.kind == .light ? max(0.01, min(1, level)) : max(0, min(1, level))
        let pct = HomeAppModel.percent(lv)
        if t.kind == .light, let b = t.brightnessID {
            commitThrottled(b, HomeValue(number: pct), type: "brightness")
            if let p = t.powerID, !t.on { commit(p, HomeValue(bool: true), type: "power") }
        } else if t.kind == .covering, let p = t.targetPositionID {
            commitThrottled(p, HomeValue(number: pct), type: "targetPosition")
        }
    }

    // MARK: 滿版控制卡（從磚長出來、縮回同一塊）

    /// 影片 v1 4K 111.534 → 111.701 量到 0.17 s 填滿、無過衝（逐格覆蓋率 0.13／0.43／0.76／0.93／1.0，每格 41.7 ms）
    /// → 臨界阻尼 response 0.185 s（解析解在同幾格是 0.0／0.43／0.77／0.93／0.98）
    private static let expandSpring = Spring(damping: 1, response: 0.185)
    private func openDetail(_ t: HomeTile, from r: CGRect, now: Double) {
        detail = t.id; detailFrom = r; detailClosing = false; detailOpenedAt = now
        detailAnim = Anim(0, spring: Self.expandSpring, name: "home.expand")
        detailAnim.retarget(1, now: now)
        levelRaw = nil; levelAnim = nil
        locks.cancel()
    }
    private func closeDetail(now: Double) {
        detailClosing = true
        // 從畫面上的當下值反向（中途打斷也不跳）
        detailAnim.retarget(0, now: now, spring: Self.expandSpring)
        // 縮回的那塊磚：捲動後位置可能變了，重新找
        if let id = detail, let r = tileLayout(page()).first(where: { $0.item.tile?.id == id })?.rect { detailFrom = r }
    }

    /// 燈／窗簾水位：目前畫出來的值（含拉過頭的阻力）
    private func displayedLevel(_ tile: HomeTile, now: Double) -> CGFloat {
        if let a = levelAnim { return a.value(now) }
        guard let raw = levelRaw else { return CGFloat(tile.level ?? 0) }
        let r = CGFloat(raw)
        if r > 1 { return 1 + AppMotion.rubberBand(r - 1, 1) }
        if r < 0 { return AppMotion.rubberBand(r, 1) }
        return r
    }
    /// 觸控板停手（0.12 s 沒有新的捲動事件）後：拉過頭的用彈簧（帶著放手時的速度）回到範圍內
    private func settleLevel(_ t: Double, _ redraw: inout Bool) {
        if let a = levelAnim {
            redraw = true
            if a.done(t) { levelAnim = nil; levelRaw = nil }
            return
        }
        guard let raw = levelRaw, t - levelLastScroll > 0.12 else { return }
        let shown = (raw > 1 ? 1 + AppMotion.rubberBand(CGFloat(raw) - 1, 1) : raw < 0 ? AppMotion.rubberBand(CGFloat(raw), 1) : CGFloat(raw))
        let target = max(0, min(1, shown))
        if shown == target { levelRaw = nil; return }
        // 放手：帶著當下速度用彈簧拉回範圍內（有動量才允許一點過衝；速度換成 1024 畫布 px/s 判斷）
        var a = Anim(shown, spring: AppMotion.release(velocity: levelVelocity * 1024))
        a.retarget(target, now: t, velocity: levelVelocity)
        levelAnim = a; redraw = true
    }

    // MARK: 輸入

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        if statusOpen, detail == nil, cameraID == nil { return status.scroll(by: dy) }
        let p = page()
        let t = clock
        if let tile = currentTile(p), !detailClosing {
            if tile.kind == .thermostat {
                // 溫控：滾一格 ±1 步
                if abs(dy) > 2, let id = tile.targetTempID, let v = HomeAppModel.steppedTarget(tile, direction: dy > 0 ? 1 : -1) { commitThrottled(id, HomeValue(number: v), type: "targetTemp") }
                return true
            }
            // 燈／窗簾：水位 1:1 跟著觸控板（1024 畫布上 dy×1.6 px），拉過頭有阻力；值照樣寫回（夾在 0…1）
            levelAnim = nil
            let start = levelRaw ?? (tile.level ?? 0)
            let d = Double(dy) * 1.6 / 1024
            let dt = max(0.004, t - levelLastScroll)
            levelVelocity = CGFloat(d / dt) * 0.5 + levelVelocity * 0.5
            levelRaw = start + d
            levelLastScroll = t
            setLevel(tile, max(0, min(1, levelRaw!)))
            return true
        }
        guard state == .ready, cameraID == nil, !p.onCameras, p.group != nil else { return false }
        let m = maxScroll(p)
        let old = scroll
        scroll = max(0, min(m, scroll - dy * 1.6))
        return scroll != old
    }

    func handleLongPress(_ pt: CGPoint, face: Face, now: Double) -> Bool {
        guard state == .ready, cameraID == nil, detail == nil, !statusOpen else { return false }
        let p = page()
        for (r, it) in tileLayout(p) where r.contains(pt) && pt.y > Self.gridTop - 8 {
            guard let t = it.tile, t.reachable, t.kind == .covering || (t.kind == .light && t.brightnessID != nil) else { return false }
            openDetail(t, from: r, now: clock); return true
        }
        return false
    }

    func handleTap(_ pt: CGPoint, face: Face, now: Double) -> Bool {
        // HomeView 對齊 WP5：點警報橪幅＝收掉這則（HomeAlerts）
        if let r = alertRect, r.insetBy(dx: -8, dy: -8).contains(pt), let a = HomeAlerts.active.first {
            HomeAlerts.dismiss(a); alertRect = nil; face.forceDirty = true; return true
        }
        alertRect = nil
        let st = state
        if st == .noHelper {
            guard HomeShortcut.available else {
                if Self.openHomeButton.insetBy(dx: -8, dy: -8).contains(pt) { Self.openAppleHome(); return true }
                return false
            }
            if Self.shortcutMainButton.insetBy(dx: -8, dy: -8).contains(pt) {
                if HomeShortcut.isSet { HomeShortcut.run() } else { HomeShortcut.openApp() }
                return true
            }
            if Self.shortcutSettingsButton.insetBy(dx: -12, dy: -12).contains(pt) { Self.openShortcutSettings(); return true }
            return false
        }
        guard st == .ready else { return false }
        let p = page()
        let t = clock
        if statusOpen, detail == nil, cameraID == nil {
            switch status.tap(pt) {
            case .toggle(let id, let on)?:
                log("home automation \(id) → \(on ? "on" : "off")")
                if !Self.demo { HomeLink.shared.enableAutomation(id: id, enabled: on) { [weak self] _, _ in self?.dirty = true } }
                else if let i = demoSnap.automations?.firstIndex(where: { $0.id == id }) { demoSnap.automations?[i].enabled = on }
                dirty = true; return true
            case .openHome?: Self.openAppleHome(); return true
            case nil: return true
            }
        }

        // 滿版控制卡
        if let tile = currentTile(p) {
            if detailClosing { return true }
            if HPComponents.hitBack(pt) { closeDetail(now: t); return true }
            if tile.kind == .thermostat {
                // 功能補齊：模式（關／暖／冷／自動，照配件支援）與旋鈕（點弧上哪裡就設到那個溫度）
                if let acc = snap.accessories.first(where: { $0.id == tile.id }) {
                    for (r, m) in modeHits where r.insetBy(dx: -4, dy: -8).contains(pt) {
                        for w in HomeClimate.writes(acc, m) { commit(w.id, w.value, type: w.type) }
                        return true
                    }
                }
                if let id = tile.targetTempID, let v = HomeClimate.value(at: pt, min: tile.tempMin, max: tile.tempMax, step: tile.tempStep) {
                    commitThrottled(id, HomeValue(number: v), type: "targetTemp"); return true
                }
                if modeHits.isEmpty, let a = tile.activeID, Self.thermoPower.insetBy(dx: -8, dy: -8).contains(pt) { commit(a, HomeValue(number: tile.on ? 0 : 1), type: "active"); return true }
                if let id = tile.targetTempID {
                    if Self.thermoDown.insetBy(dx: -10, dy: -10).contains(pt), let v = HomeAppModel.steppedTarget(tile, direction: -1) { commitThrottled(id, HomeValue(number: v), type: "targetTemp") }
                    else if Self.thermoUp.insetBy(dx: -10, dy: -10).contains(pt), let v = HomeAppModel.steppedTarget(tile, direction: 1) { commitThrottled(id, HomeValue(number: v), type: "targetTemp") }
                }
                return true
            }
            // 燈／窗簾：點哪個高度就到哪（水位用 Apple 的 smooth 彈簧滑過去）
            let target = max(0, min(1, (1024 - pt.y) / 1024))
            var a = Anim(displayedLevel(tile, now: t), spring: AppMotion.appleSmooth)
            a.retarget(target, now: t)
            levelAnim = a; levelRaw = nil
            setLevel(tile, Double(target))
            return true
        }
        // 攝影機全螢幕
        if let cid = cameraID {
            if Self.camClose.insetBy(dx: -8, dy: -8).contains(pt) { HPComponents.navigateBack(); return true }
            if Self.camFit.insetBy(dx: -10, dy: -10).contains(pt) { toggleCamFill(cid); return true }
            // 體驗追趕 P4：近況時間軸——點一格看那一刻，點最右邊回到即時
            if CameraTimeline.hitArea.contains(pt), let fr = CameraTimeline.shared.frames[cid], !fr.isEmpty {
                CameraTimeline.shared.selected[cid] = CameraTimeline.pick(pt.x, times: fr.map(\.at), now: Date().timeIntervalSince1970, in: CameraTimeline.track)
                dirty = true; return true
            }
            // 2.0 home-1：同一個房間的燈、門鎖（iOS 家庭 App 攝影機畫面底下的相關配件）
            for (r, tile) in relatedLayout(cid) where r.insetBy(dx: -8, dy: -8).contains(pt) {
                guard tile.reachable else { return true }
                if tile.kind == .lock, let id = tile.lockTargetID {
                    switch locks.press(id: tile.id, locked: tile.locked ?? false, now: t) {
                    case .lock: commit(id, HomeValue(number: 1), type: "lockTarget")
                    case .unlock: commit(id, HomeValue(number: 0), type: "lockTarget")
                    case .arm: break
                    }
                } else if let id = tile.powerID { commit(id, HomeValue(bool: !tile.on), type: "power") }
                return true
            }
            if Self.camGrid.insetBy(dx: -8, dy: -8).contains(pt) { cameraID = nil; tab = 1; return true }
            return true
        }
        if p.onCameras {
            for (r, c) in zip(Self.cameraCells(p.cameras.count), p.cameras) where CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 56).contains(pt) {
                cameraID = c.id; return true
            }
            return false
        }
        guard pt.y > Self.gridTop - 8 else { return false }
        for (r, it) in tileLayout(p) where r.contains(pt) {
            switch it {
            case .camera(let c): cameraID = c.id; return true
            case .clock: return true
            case .homeApp: locks.cancel(); Self.openAppleHome(); return true
            case .status: locks.cancel(); statusOpen = true; status = HomeStatusPage(); log("home status open"); return true
            case .scene(let s):
                if HomeWrite.refusesGuest { return true }   // 2.0 idle: 訪客裝置不能跑場景
                sceneFlash = (s.id, t + 0.7)
                if !Self.demo { HomeLink.shared.runScene(id: s.id) }
                locks.cancel(); return true
            case .tile(let tile):
                if tile.kind != .lock && !Self.sensitive(tile, turningOn: !tile.on) { locks.cancel() }
                guard tile.reachable else { return true }
                switch tile.kind {
                case .light, .outlet:
                    guard let id = tile.powerID else { return true }
                    // 第四輪：保全關掉、車庫打開要確認（跟 ClioTalk 同一條規則）：第一下待命、4 秒內再按才做
                    if Self.sensitive(tile, turningOn: !tile.on) {
                        switch locks.press(id: tile.id, locked: true, now: t) {
                        case .arm: return true
                        default: break
                        }
                    }
                    commit(id, HomeValue(bool: !tile.on), type: "power")
                case .covering:
                    if let id = tile.targetPositionID { commit(id, HomeValue(number: (tile.level ?? 0) >= 0.5 ? 0 : 100), type: "targetPosition") }
                case .lock:
                    guard let id = tile.lockTargetID else { return true }
                    switch locks.press(id: tile.id, locked: tile.locked ?? false, now: t) {
                    case .lock: commit(id, HomeValue(number: 1), type: "lockTarget")
                    case .unlock: commit(id, HomeValue(number: 0), type: "lockTarget")
                    case .arm: break
                    }
                case .thermostat:
                    let b = Self.thermoChevrons(r)
                    if let id = tile.targetTempID, b.down.insetBy(dx: -8, dy: -8).contains(pt), let v = HomeAppModel.steppedTarget(tile, direction: -1) { commitThrottled(id, HomeValue(number: v), type: "targetTemp") }
                    else if let id = tile.targetTempID, b.up.insetBy(dx: -8, dy: -8).contains(pt), let v = HomeAppModel.steppedTarget(tile, direction: 1) { commitThrottled(id, HomeValue(number: v), type: "targetTemp") }
                    else { openDetail(tile, from: r, now: t) }
                case .sensor: break
                }
                return true
            }
        }
        return false
    }

    /// 保全、車庫這類配件的危險方向（ClioHomeControl.isSensitive 的規則：保全關、車庫開）
    static func sensitive(_ t: HomeTile, turningOn: Bool) -> Bool {
        let hay = ClioHomeControl.normalized(t.name + t.category)
        if ClioHomeControl.contains(hay, any: ClioHomeControl.securityWords) { return !turningOn }
        if ClioHomeControl.contains(hay, any: ClioHomeControl.garageWords) { return turningOn }
        return false
    }

    static func openAppleHome() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Home") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    // MARK: 繪製

    /// 家庭的底：官方 home-light 是純白（深色時純黑）
    private func drawBackdrop(_ g: CGContext, _ rect: CGRect) {
        g.setFillColor(HPTokens.HomeGrid.background.cgColor); g.fill(rect)
    }

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        // 2.0 home-1：人走近（reveal 從遠端升上來）＝攝影機立刻重拍；遠近兩檔在 tick 判斷
        let rv = face.reveal
        if rv > 0.5, lastReveal <= 0.5 { schedule.refresh() }
        lastReveal = rv
        // HomeView 對齊 WP5：家庭警報橫幅（煙霧/CO/CO₂/水漏/門窗；Shell/HomeAlerts.swift）——
        // 畫在最上層：頁面畫完才畫（之前先畫橫幅、整頁蓋過去就看不到）；攝影機、家庭狀態那幾條提早 return 的路也照樣蓋上
        defer { if !HomeAlerts.active.isEmpty { drawAlertBanner(g, face, now: now) } else { alertRect = nil } }
        switch state {
        case .noHelper:
            g.setFillColor(HPComponents.bg.cgColor); g.fill(rect); AppUI.title(g, face, title); drawNoHelper(g, face)
        case .connecting:
            g.setFillColor(HPComponents.bg.cgColor); g.fill(rect); AppUI.title(g, face, title)
            drawMessage(g, face, L("home.connecting", "正在连接家庭…"), sub: L("home.connecting.sub", "HomePlay Home 小帮手启动后，配件会自动出现"))
        case .empty:
            g.setFillColor(HPComponents.bg.cgColor); g.fill(rect); AppUI.title(g, face, title)
            drawMessage(g, face, L("home.empty", "这个家庭还没有配件"), sub: L("home.empty.sub", "先在 Mac 的「家庭」App 里添加配件"))
        case .ready:
            let p = page()
            if let cid = cameraID, let cam = p.cameras.first(where: { $0.id == cid }) { drawCameraPage(g, face, cam); return }
            if statusOpen {
                status.draw(g, face, snapshot: snap, now: Date(), owner: !Self.guestView && !Shell.guestMode)
                AppUI.title(g, face, L("home.status.title", "家庭状态"))
                return
            }
            if p.onCameras {
                g.setFillColor(HPComponents.bg.cgColor); g.fill(rect)
                AppUI.title(g, face, L("home.cameras", "摄像头"))
                drawCameraGrid(g, face, p.cameras)
            } else {
                drawBackdrop(g, rect)
                drawRoom(g, face, p)
            }
            if let t = currentTile(p) { drawDetail(g, face, t, now: clock) }
        }
    }

    private func textCentered(_ g: CGContext, _ face: Face, _ s: String, font: NSFont, cx: CGFloat, y: CGFloat, color: NSColor) {
        face.drawLeft(g, s, font: font, x: cx - Typo.width(s, font) / 2, y: y, color: color)
    }

    private func drawNoHelper(_ g: CGContext, _ face: Face) {
        // macOS 12 以前沒有「捷徑」App：只能講小幫手（開發版才有）
        guard HomeShortcut.available else {
            Shell.drawAppIcon(g, face: face, icon: icon, in: CGRect(x: 512 - 96, y: 260, width: 192, height: 192))
            let f = HPComponents.sf(42, weight: .semibold)
            let lines = MediaUI.wrap(L("home.needHelper", "家庭需要 HomePlay Home 小帮手（目前只在开发版提供）"), f, 760, maxLines: 4)
            for (i, l) in lines.enumerated() { textCentered(g, face, l, font: f, cx: 512, y: 530 + CGFloat(i) * 58, color: HPComponents.label) }
            HPAX.note(g, CGRect(x: 128, y: 480, width: 768, height: CGFloat(lines.count) * 58 + 30), .text, L("home.needHelper", "家庭需要 HomePlay Home 小帮手（目前只在开发版提供）"), shape: .rounded(16))
            HPComponents.filledButton(g, face, Self.openHomeButton, L("home.openApple", "在 Mac 的「家庭」App 中打开"), tint: HPComponents.orange)
            return
        }
        // B 方案（2026-10-26 使用者拍板）：HomeKit 的權利只跟著 App Store 的簽章走，
        // 公開版用 macOS 捷徑的家庭動作代替。這裡只負責記名字與執行，配件資料完全拿不到。
        Shell.drawAppIcon(g, face: face, icon: icon, in: CGRect(x: 512 - 84, y: 176, width: 168, height: 168))
        let tf = HPComponents.sf(46, weight: .semibold)
        textCentered(g, face, L("home.shortcut.title", "用捷径控制家庭"), font: tf, cx: 512, y: 392, color: HPComponents.label)
        let bf = HPComponents.sf(29, weight: .regular)
        let body = L("home.shortcut.body", "HomePlay 不能直接读 HomeKit。在「捷径」App 建一个捷径，加入「控制家庭」动作，再回来填入它的名字。")
        let bodyLines = MediaUI.wrap(body, bf, 700, maxLines: 3)
        for (i, l) in bodyLines.enumerated() {
            textCentered(g, face, l, font: bf, cx: 512, y: 462 + CGFloat(i) * 42, color: HPComponents.secondary)
        }
        HPAX.note(g, CGRect(x: 168, y: 440, width: 688, height: CGFloat(bodyLines.count) * 42 + 24), .text, L("home.shortcut.title", "用捷径控制家庭"), value: body, shape: .rounded(16))
        let main = HomeShortcut.isSet
            ? String(format: L("home.shortcut.run", "执行「%1$@」"), HomeShortcut.name)
            : L("home.shortcut.create", "建立家庭捷径")
        HPComponents.filledButton(g, face, Self.shortcutMainButton, main, tint: HPComponents.orange)
        let second = HomeShortcut.isSet ? L("home.shortcut.change", "换一个捷径") : L("home.shortcut.setName", "在设置里填入捷径名称")
        HPComponents.glassButton(g, face, Self.shortcutSettingsButton, second, size: 30, ink: HPComponents.label)
        // 誠實寫出這條路的代價（使用者拍板時已經知道；畫面上再寫一次）
        let lf = HPComponents.sf(24, weight: .regular)
        let limit = L("home.shortcut.limit", "执行时会切到捷径 App；这里看不到配件清单，也没有即时状态。")
        for (i, l) in MediaUI.wrap(limit, lf, 780, maxLines: 2).enumerated() {
            textCentered(g, face, l, font: lf, cx: 512, y: 886 + CGFloat(i) * 34, color: HPComponents.secondary)
        }
    }

    /// 打開設定的「家庭」分頁（填捷徑名稱）
    static func openShortcutSettings() {
        if let d = NSApp.delegate as? AppDelegate { SettingsWindowController.show(app: d, pane: .home) }
    }

    private func drawMessage(_ g: CGContext, _ face: Face, _ s: String, sub: String) {
        Shell.drawAppIcon(g, face: face, icon: icon, in: CGRect(x: 512 - 96, y: 270, width: 192, height: 192))
        textCentered(g, face, s, font: HPComponents.fitted(s, size: 48, weight: .bold, maxWidth: 800), cx: 512, y: 570, color: HPComponents.label)
        HPAX.note(g, CGRect(x: 112, y: 520, width: 800, height: 220), .text, s, value: sub, shape: .rounded(16))   // 2.0 depth：VoiceOver
        let f = HPComponents.sf(34, weight: .regular)
        for (i, l) in MediaUI.wrap(sub, f, 760, maxLines: 3).enumerated() {
            textCentered(g, face, l, font: f, cx: 512, y: 632 + CGFloat(i) * 46, color: HPComponents.secondary)
        }
    }

    private func drawRoom(_ g: CGContext, _ face: Face, _ p: Page) {
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: 0, width: 1024, height: Self.viewBottom))
        let t = clock
        for (r, it) in tileLayout(p) where r.maxY > Self.gridTop - 12 && r.minY < Self.viewBottom {
            if let d = detail, it.tile?.id == d { continue }        // 正在變成滿版卡的那一塊不畫
            switch it {
            case .tile(let tile): drawTile(g, face, tile, r, room: roomName(tile, p), armed: locks.isArmed(tile.id, now: t))
            case .scene(let s): drawScene(g, face, s, r)
            case .camera(let c):
                HPAX.note(g, r, .button, c.name, value: ageText(c), shape: .rounded(Self.tileRadius))   // 2.0 depth：VoiceOver
                drawFrame(g, face, c, r, radius: Self.tileRadius)
                drawAgeChip(g, face, c, r)   // 2.0 home-1：快照是多久以前拍的（過期的縮圖會讓人以為門口沒人）
            case .status:
                drawStatusTile(g, face, r)
            case .clock:
                let st = HPComponents.dashTileStyle(on: true)
                HPComponents.analogClockTile(g, face, r, date: Face.displayDate, tint: st.ink, hands: HPTokens.label)
            case .homeApp:
                HPAX.note(g, r, .button, L("cc.home.open", "打开“家庭”"), shape: .rounded(Self.tileRadius))   // 2.0 depth：VoiceOver
                let st = HPComponents.dashTileStyle(on: false)
                HPComponents.dashTile(g, face, r, fill: st.fill, title: nil, subtitle: nil, ink: st.ink, sub: st.sub,
                                      glyph: HPComponents.dashSymbol(face, "homekit", color: st.ink, weight: .regular, scale: 1.55))
            }
        }
        g.restoreGState()
    }

    /// R15 磚（官方 home-light）：開＝家的顏色（淡紫）底、圖示與名稱同色系深一階；關＝淺灰底、深灰字；
    /// 第一行名稱（拿掉房間名）、第二行房間；待命開鎖時橘底白字；連不上的半透明、第二行寫狀態
    private func drawTile(_ g: CGContext, _ face: Face, _ t: HomeTile, _ r: CGRect, room: String, armed: Bool) {
        var st = HPComponents.dashTileStyle(on: t.on)
        if armed { st = HPComponents.DashTileStyle(fill: HPComponents.orange, ink: .white, sub: NSColor.white.withAlphaComponent(0.8)) }
        let alpha: CGFloat = t.reachable ? 1 : 0.5
        let ink = st.ink.withAlphaComponent(alpha), sub = st.sub.withAlphaComponent(alpha)
        let name = HomeAppModel.shortName(t.name, room: room)
        let again = t.kind == .lock ? L("home.lock.again", "再按一次开锁") : L("home.confirm.again", "再按一次确认")
        let second = armed ? again : (!t.reachable || room.isEmpty || t.kind == .thermostat ? t.status : room)
        HPAX.note(g, r, .button, name, value: room.isEmpty ? (armed ? again : t.status) : String(format: L("a11y.pair", "%1$@，%2$@"), armed ? again : t.status, room), shape: .rounded(Self.tileRadius))   // 2.0 P05：開關狀態用字說，不只靠顏色
        if t.kind == .thermostat {
            // 第四輪：2×2 溫控照官方 Home Modular 的版面（HPTokens.HomeModular，量自 lineup5／face-home-modular）：
            // 大數字置中（目標溫度；只讀的空調伴侶是目前溫度）、底下兩行標籤置中、左右 ∨ ∧ 在標籤兩側
            typealias M = HPTokens.HomeModular
            let k = r.height / (2 * M.cell + M.gap)
            HPComponents.dashTile(g, face, r, fill: st.fill, title: nil, subtitle: nil, ink: ink, sub: sub)
            let big = (t.target ?? t.temp).map { HomeAppModel.tempText($0) } ?? "—"
            let bf = FaceType.sf(M.numberSize * k, .medium)
            textCentered(g, face, big, font: bf, cx: r.midX, y: r.minY + M.numberBaseline * k, color: ink)
            let w = r.width - 2 * (M.chevronInset * k + 60)
            let tf = HPComponents.fitted(name, size: HPTokens.HomeGrid.titleSize, weight: .semibold, maxWidth: w)
            textCentered(g, face, Face.clipped(name, tf, w), font: tf, cx: r.midX, y: r.maxY - M.titleFromBottom * k, color: ink)
            let sf = HPComponents.fitted(second, size: HPTokens.HomeGrid.subtitleSize, weight: .regular, maxWidth: w)
            textCentered(g, face, Face.clipped(second, sf, w), font: sf, cx: r.midX, y: r.maxY - M.subFromBottom * k, color: t.reachable ? sub : st.sub)
            let b = Self.thermoChevrons(r)
            if t.targetTempID != nil {   // 第四輪：沒有可寫的目標溫度（只讀的空調伴侶）就不畫 − ＋
                HPAX.note(g, b.down, .button, L("a11y.tempDown", "降低温度"), value: big, shape: .circle)   // 2.0 depth：VoiceOver
                HPAX.note(g, b.up, .button, L("a11y.tempUp", "升高温度"), value: big, shape: .circle)
                for (br, sym) in [(b.down, "chevron.down"), (b.up, "chevron.up")] {
                    face.drawSymbol(g, sym, in: br.insetBy(dx: 30, dy: 34), color: ink.withAlphaComponent(0.85 * alpha), weight: .semibold)
                }
            }
            if !t.reachable { drawNoResponseBadge(g, face, r, color: st.sub) }
            return
        }
        let glyph = t.symbol == HomeAppModel.intercomSymbol ? HPComponents.intercomGlyph(color: ink) : HPComponents.dashSymbol(face, t.symbol, color: ink)
        HPComponents.dashTile(g, face, r, fill: st.fill, title: name, subtitle: second, ink: ink, sub: t.reachable ? sub : st.sub, glyph: glyph)
        if !t.reachable { drawNoResponseBadge(g, face, r, color: st.sub) }
    }

    /// 第四輪：連不上的配件（官方「無回應」）：磚右上一個小驚嘆號
    private func drawNoResponseBadge(_ g: CGContext, _ face: Face, _ r: CGRect, color: NSColor) {
        face.drawSymbol(g, "exclamationmark.circle.fill", in: CGRect(x: r.maxX - 74, y: r.minY + 30, width: 44, height: 44), color: color, weight: .regular)
    }

    private func drawScene(_ g: CGContext, _ face: Face, _ s: HomeScene, _ r: CGRect) {
        let st = HPComponents.dashTileStyle(on: sceneFlash?.id == s.id)
        HPAX.note(g, r, .button, s.name, value: L("home.scene", "场景"), shape: .rounded(Self.tileRadius))   // 2.0 P05
        HPComponents.dashTile(g, face, r, fill: st.fill, title: s.name, subtitle: L("home.scene", "场景"), ink: st.ink, sub: st.sub,
                              glyph: HPComponents.dashSymbol(face, "sun.max.fill", color: st.ink))
    }

    // MARK: 2.0 home-1：狀態磚、快照時間、相關配件、遠看

    /// 狀態磚：一切正常＝淺灰勾勾；有問題＝琥珀底「N 個沒有回應」／「家庭中樞離線」
    private func drawStatusTile(_ g: CGContext, _ face: Face, _ r: CGRect) {
        let h = HomeHealth.make(snap, lastSeen: HomeActivity.shared.lastSeen)
        let title: String, sub: String
        if h.hub == "disconnected" { title = L("home.tile.hubOff", "中枢离线"); sub = L("home.tile.autosPaused", "自动化暂停") }
        else if !h.issues.isEmpty { title = String(format: L("home.tile.noResponse", "%d 个没回应"), h.issues.count); sub = L("home.tile.status", "家庭状态") }
        else { title = L("home.tile.ok", "一切正常"); sub = L("home.tile.status", "家庭状态") }
        let st = h.ok ? HPComponents.dashTileStyle(on: false)
            : HPComponents.DashTileStyle(fill: HPComponents.orange, ink: .white, sub: NSColor.white.withAlphaComponent(0.8))
        HPAX.note(g, r, .button, sub, value: title, shape: .rounded(Self.tileRadius))
        HPComponents.dashTile(g, face, r, fill: st.fill, title: title, subtitle: sub, ink: st.ink, sub: st.sub,
                              glyph: HPComponents.dashSymbol(face, h.ok ? "checkmark.circle" : "exclamationmark.circle", color: st.ink))
    }

    /// 根頁攝影機磚左下：「12 秒前」；拍不到＝「沒有回應」
    private func drawAgeChip(_ g: CGContext, _ face: Face, _ c: HomeCameraItem, _ r: CGRect) {
        guard !RemotePrivacy.guestActive, !Self.demo || images[c.id] != nil || demoImages[c.id] != nil || cameraImage(c) != nil else { return }
        let txt = ageText(c), f = HPType.sf(26, .semibold)
        let w = Typo.width(txt, f) + 32, chip = CGRect(x: r.minX + 20, y: r.maxY - 20 - 44, width: w, height: 44)
        AppUI.fillPill(g, chip, color: NSColor.black.withAlphaComponent(0.45))
        face.drawLeft(g, txt, font: f, x: chip.minX + 16, y: chip.midY + 9, color: .white)
    }

    /// 攝影機所在房間的燈／插座／門鎖（最多兩顆；燈在前）
    private func related(_ cameraID: String) -> [HomeTile] {
        guard let room = snap.accessories.first(where: { $0.id == cameraID })?.room else { return [] }
        let all = HomeAppModel.groups(snap).flatMap(\.tiles).filter { $0.room == room }
        let lights = all.filter { $0.kind == .light || $0.kind == .outlet }, locks = all.filter { $0.kind == .lock }
        return Array((lights.prefix(1) + locks.prefix(1) + lights.dropFirst(1)).prefix(2))
    }
    private func relatedLayout(_ cameraID: String) -> [(CGRect, HomeTile)] {
        let ts = related(cameraID)
        guard !ts.isEmpty, !Self.guestView else { return [] }
        let w: CGFloat = 320, gap = HPGrid.Rhythm.groupGap, total = CGFloat(ts.count) * w + CGFloat(ts.count - 1) * gap
        let y = Self.camMic.minY - 72 - HPTokens.Size.pill
        return ts.enumerated().map { i, t in (CGRect(x: 512 - total / 2 + CGFloat(i) * (w + gap), y: y, width: w, height: HPTokens.Size.pill), t) }
    }
    private func drawRelated(_ g: CGContext, _ face: Face, _ cameraID: String) {
        let t = clock
        for (r, tile) in relatedLayout(cameraID) {
            let armed = locks.isArmed(tile.id, now: t)
            let name = HomeAppModel.shortName(tile.name, room: "")
            let title = armed ? L("home.lock.again", "再按一次开锁") : "\(name) · \(tile.status)"
            let sym = tile.kind == .lock ? ((tile.locked ?? false) ? "lock.fill" : "lock.open.fill") : (tile.on ? "lightbulb.fill" : "lightbulb")
            if armed || (tile.on && tile.kind != .lock) {
                HPComponents.filledButton(g, face, r, title, tint: armed ? HPComponents.orange : HPComponents.yellow, symbol: sym)
            } else {
                HPComponents.glassButton(g, face, r, title, symbol: sym)
            }
        }
    }

    /// 遠看（提案原則 1，外殼統一畫）：這個房間（沒設就整個家）一句話；只在根頁（打開了攝影機、狀態頁、滿版卡就不換）
    func farGlance(face: Face, now: Double) -> FarGlance? {
        guard state == .ready, detail == nil, cameraID == nil, !statusOpen, tab == 0, !Self.guestView else { return nil }
        let h = HomeHealth.make(snap, lastSeen: HomeActivity.shared.lastSeen)
        let m = HomeFarSummary.make(snap, thisRoom: HomeThisRoom.room(in: snap), health: h)
        return FarGlance(title: m.title, headline: m.headline, details: m.details,
                         alert: m.issues > 0 ? String(format: L("home.far.issues", "%d 个配件没有回应"), m.issues) : nil)
    }

    // MARK: 滿版控制卡

    private func drawDetail(_ g: CGContext, _ face: Face, _ t: HomeTile, now: Double) {
        let e = max(0, min(1, detailAnim.value(now)))
        let full = MediaUI.full
        let r = Shell.lerp(detailFrom, full, e)
        let radius = Self.tileRadius + (Screen.cornerRadius - Self.tileRadius) * e
        // 背後的格子淡淡壓暗
        g.setFillColor(NSColor.black.withAlphaComponent(0.25 * e).cgColor); g.fill(full)
        // 卡底：從磚的白／玻璃（途中，約 e 0.4–0.75）交叉淡換成滿版的顏色；影片 v1 111.58 → 111.62
        let mix = max(0, min(1, (e - 0.4) / 0.35))
        let tileFill: NSColor = t.on ? .white : NSColor(white: 0.62, alpha: 1)
        let path = continuousRoundedRect(r, radius: radius)
        g.saveGState(); g.addPath(path); g.clip()
        switch t.kind {
        case .thermostat:
            let mode = thermoMode(t)
            let blue = srgb(0x12a8f2), heat = srgb(0xff9500), off = srgb(0x8e8e93)
            let bg = mode == 2 ? blue : mode == 1 ? heat : off
            g.setFillColor((tileFill.blended(withFraction: mix, of: bg) ?? bg).cgColor); g.fill(r)
        default:
            let lv = displayedLevel(t, now: now)
            let top = HPTokens.dark ? srgb(0x2c2c2e) : srgb(0xfbf8ec)
            let fillC = t.kind == .covering ? srgb(0x64b5f6) : srgb(0xf2cc0c)
            g.setFillColor((tileFill.blended(withFraction: mix, of: top) ?? top).cgColor); g.fill(r)
            let h = r.height * max(0, lv)
            g.setFillColor(fillC.withAlphaComponent(mix).cgColor); g.fill(CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h))
        }
        // 內容：在卡上用同一個縮放畫（先到，外框元件晚約 0.1 s）
        let contentA = max(0, min(1, (e - 0.55) / 0.3))
        if contentA > 0 {
            g.saveGState()
            g.setAlpha(contentA)
            g.translateBy(x: r.minX, y: r.minY); g.scaleBy(x: r.width / 1024, y: r.height / 1024)
            if t.kind == .thermostat { drawThermoContent(g, face, t) } else { drawLevelContent(g, face, t, now: now) }
            g.restoreGState()
        }
        g.restoreGState()
        // 外框元件：✕、名稱、時間——內容到位後才淡入（影片 v1：卡在 111.534 開始長、111.70 填滿，
        // 標題 111.70 出現、111.78 全亮，✕ 111.74–111.83 → 從開始長算起 0.17 s 起、0.1 s 淡入），關的時候馬上淡出
        let since = CGFloat(Anim.frozen("home.expand") ?? (now - detailOpenedAt))
        let chromeA = detailClosing ? max(0, (e - 0.6) / 0.4) : max(0, min(1, (since - 0.17) / 0.1))
        if chromeA > 0 {
            let ink: NSColor = t.kind == .thermostat ? .white : (HPTokens.dark ? .white : .black)
            g.saveGState(); g.setAlpha(chromeA)
            // 玻璃 materialize 的近似：淡入時同時從 0.96 長到 1（正式的 presence 在外殼包的 GlassPass）
            let k = 0.96 + 0.04 * chromeA
            HPComponents.glassCircle(g, face, HPComponents.scaled(HPTokens.backButton, k), symbol: "xmark", ink: ink, scale: 0.34)
            let nf = HPComponents.sf(34, weight: .semibold)
            textCentered(g, face, Face.clipped(t.name, nf, 500), font: nf, cx: 512, y: HPTokens.backButton.midY + 12, color: ink.withAlphaComponent(0.9))
            HPComponents.clock(g, face, color: ink)
            g.restoreGState()
        }
    }

    private func thermoMode(_ t: HomeTile) -> Int { t.mode }   // 第四輪：溫控與冷暖氣都由 HomeAppModel 換算好

    /// 溫控滿版（影片 v2 O115）：「制冷中／加热中」、目標數字、兩側淡色圓鈕、底下目前溫度與濕度
    /// 功能補齊：可以設目標的配件多一圈旋鈕（點弧上設溫度、滾輪 ±1 步、0.5 度一格或照配件步進）；底下是模式列（關／暖／冷／自動，照配件支援），
    /// 配件沒有可選的模式才退回開關鈕。只讀的（只有溫濕度的空調伴侶）照舊只顯示室內溫度。
    private func drawThermoContent(_ g: CGContext, _ face: Face, _ t: HomeTile) {
        let mode = thermoMode(t)
        let readOnly = t.targetTempID == nil && t.activeID == nil
        let acc = snap.accessories.first(where: { $0.id == t.id })
        let modes = acc.map(HomeClimate.modes) ?? HomeClimateModes(options: [], selected: nil)
        let modeName: [HomeClimateMode: String] = [.off: L("home.off", "关"), .heat: L("home.climate.heat", "制热"),
                                                   .cool: L("home.climate.cool", "制冷"), .auto: L("home.climate.auto", "自动")]
        // 正在加熱／製冷就寫「…中」；沒在動就寫選的模式（自動待機時不會被誤寫成「關」）
        let head = readOnly ? L("home.thermo.indoor", "室内温度") : mode == 2 ? L("home.thermo.cool", "制冷中") : mode == 1 ? L("home.thermo.heat", "加热中")
            : (modes.selected.flatMap { modeName[$0] } ?? L("home.off", "关"))
        let big = (t.target ?? t.temp).map { HomeAppModel.tempText($0) } ?? "—"
        let dial = t.target != nil && t.targetTempID != nil
        let ink = NSColor.white, dim = NSColor.white.withAlphaComponent(HPAccessibility.increaseContrast ? 0.5 : 0.28)
        if dial, let target = t.target {
            // 旋鈕：270° 的弧（底下留缺口），走過的那段亮白；目前溫度一個小點；目標一顆白色把手
            let c = HomeClimate.center, r = HomeClimate.radius, lw: CGFloat = 24
            let a0 = HomeClimate.startDeg * .pi / 180, sweep = HomeClimate.sweepDeg * .pi / 180
            let f = HomeClimate.fraction(target, min: t.tempMin, max: t.tempMax)
            g.saveGState(); g.setLineCap(.round); g.setLineWidth(lw)
            g.setStrokeColor(dim.cgColor); g.addArc(center: c, radius: r, startAngle: a0, endAngle: a0 + sweep, clockwise: false); g.strokePath()
            g.setStrokeColor(ink.cgColor); g.addArc(center: c, radius: r, startAngle: a0, endAngle: a0 + sweep * f, clockwise: false); g.strokePath()
            g.restoreGState()
            if let cur = t.temp {
                let p = HomeClimate.point(HomeClimate.fraction(cur, min: t.tempMin, max: t.tempMax))
                g.setFillColor((f >= HomeClimate.fraction(cur, min: t.tempMin, max: t.tempMax) ? srgb(0x000000).withAlphaComponent(0.35) : ink.withAlphaComponent(0.8)).cgColor)
                g.fillEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            }
            let k = HomeClimate.point(f)
            g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: NSColor(white: 0, alpha: 0.3).cgColor)
            g.setFillColor(ink.cgColor); g.fillEllipse(in: CGRect(x: k.x - 28, y: k.y - 28, width: 56, height: 56)); g.restoreGState()
            HPAX.note(g, CGRect(x: c.x - r - 28, y: c.y - r - 28, width: 2 * r + 56, height: 2 * r + 56), .text, L("home.climate.target", "目标温度"), value: big, shape: .circle)
            textCentered(g, face, head, font: HPComponents.sf(40, weight: .medium), cx: 512, y: 392, color: ink.withAlphaComponent(0.85))
            textCentered(g, face, big, font: FaceType.sf(176, .light), cx: 512, y: 568, color: ink)
        } else {
            textCentered(g, face, head, font: HPComponents.sf(40, weight: .medium), cx: 512, y: 330, color: ink.withAlphaComponent(0.8))
            textCentered(g, face, big, font: FaceType.sf(300, .light), cx: 512, y: 610, color: ink)
            HPAX.note(g, CGRect(x: 240, y: 280, width: 544, height: 380), .text, head, value: big, shape: .rounded(24))   // 2.0 depth：VoiceOver
        }
        if t.targetTempID != nil {
            HPAX.note(g, Self.thermoDown, .button, L("a11y.tempDown", "降低温度"), value: big, shape: .circle)
            HPAX.note(g, Self.thermoUp, .button, L("a11y.tempUp", "升高温度"), value: big, shape: .circle)
            for (r, sym) in [(Self.thermoDown, "chevron.down"), (Self.thermoUp, "chevron.up")] {
                HPComponents.glassCircle(g, face, r, symbol: sym, ink: .white, scale: 0.34)
            }
        }
        // 模式列（自己畫的膠囊分段：底色是模式色，玻璃分段的黑字在橘、藍底上讀不清楚）；沒有可選的模式才用冷暖氣的開關鈕
        modeHits = []
        if !modes.options.isEmpty {
            let track = Self.thermoModes, n = CGFloat(modes.options.count), inset: CGFloat = 8
            let w = (track.width - 2 * inset) / n
            g.setFillColor(NSColor(white: 0, alpha: HPAccessibility.reduceTransparency ? 0.4 : 0.18).cgColor)
            g.addPath(HPComponents.capsulePath(track)); g.fillPath()
            let bg = mode == 2 ? srgb(0x12a8f2) : mode == 1 ? srgb(0xff9500) : srgb(0x8e8e93)
            for (i, m) in modes.options.enumerated() {
                let r = CGRect(x: track.minX + inset + CGFloat(i) * w, y: track.minY + inset, width: w, height: track.height - 2 * inset)
                let on = m == modes.selected, name = modeName[m] ?? ""
                if on { g.setFillColor(ink.cgColor); g.addPath(HPComponents.capsulePath(r)); g.fillPath() }
                let fnt = HPComponents.sf(32, weight: on ? .semibold : .medium)
                textCentered(g, face, name, font: fnt, cx: r.midX, y: r.midY + fnt.capHeight / 2, color: on ? (bg.blended(withFraction: 0.35, of: .black) ?? bg) : ink)
                HPAX.note(g, r, .radio(on), name)
                modeHits.append((r, m))
            }
        } else if t.activeID != nil {
            // 第四輪：冷暖氣的開關（HomeKit Active）
            HPComponents.glassButton(g, face, Self.thermoPower, t.on ? L("home.thermo.turnOff", "关闭") : L("home.thermo.turnOn", "打开"), symbol: "power")
        }
        var parts: [(String, String)] = []
        if let cur = t.temp { parts.append(("thermometer.medium", HomeAppModel.tempText(cur))) }
        if let h = acc?.characteristic("humidity")?.value?.number { parts.append(("humidity", "\(Int(h.rounded()))%")) }
        let f = HPComponents.sf(32, weight: .medium)
        let w = parts.reduce(CGFloat(0)) { $0 + 44 + Typo.width($1.1, f) } + CGFloat(max(0, parts.count - 1)) * 36
        var x = 512 - w / 2
        let py: CGFloat = dial ? 618 : 690
        for (sym, s) in parts {
            face.drawSymbol(g, sym, in: CGRect(x: x, y: py, width: 34, height: 34), color: .white, weight: .semibold)
            face.drawLeft(g, s, font: f, x: x + 44, y: py + 28, color: .white); x += 44 + Typo.width(s, f) + 36
        }
    }

    /// 燈／窗簾滿版（影片 v2 O118）：黃色水位、上方燈泡符號、置中大字「34%」（% 小一號）、數字下方一條短把手線
    private func drawLevelContent(_ g: CGContext, _ face: Face, _ t: HomeTile, now: Double) {
        let lv = displayedLevel(t, now: now)
        let pct = Int((max(0, min(1, lv)) * 100).rounded())
        let ink: NSColor = HPTokens.dark ? .white : .black
        face.drawSymbol(g, t.kind == .covering ? "blinds.horizontal.open" : "lightbulb.fill", in: CGRect(x: 512 - 34, y: 350, width: 68, height: 68), color: ink, weight: .regular)
        let nf = FaceType.sf(200, .regular), pf = HPComponents.sf(80, weight: .medium)
        let n = "\(pct)", w = Typo.width(n, nf) + 8 + Typo.width("%", pf)
        // 數字跨黃白交界：深色模式下水位以上白字、以下黑字（兩層各自裁切）；淺色時兩邊都是黑（照影片）
        let line = 1024 - 1024 * lv
        func number(_ color: NSColor, pctColor: NSColor) {
            face.drawLeft(g, n, font: nf, x: 512 - w / 2, y: 610, color: color)
            face.drawLeft(g, "%", font: pf, x: 512 - w / 2 + Typo.width(n, nf) + 8, y: 610, color: pctColor)
        }
        g.saveGState(); g.clip(to: CGRect(x: 0, y: 0, width: 1024, height: max(0, line))); number(ink, pctColor: ink.withAlphaComponent(0.45)); g.restoreGState()
        g.saveGState(); g.clip(to: CGRect(x: 0, y: line, width: 1024, height: 1024)); number(.black, pctColor: NSColor.black.withAlphaComponent(0.45)); g.restoreGState()
        g.setFillColor(ink.withAlphaComponent(0.85).cgColor)
        g.addPath(HPComponents.capsulePath(CGRect(x: 512 - 36, y: 650, width: 72, height: 8))); g.fillPath()
    }

    // MARK: 攝影機

    private func cameraImage(_ cam: HomeCameraItem) -> CGImage? {
        if Self.demo {
            if let i = demoImages[cam.id] { return i }
            let idx = HomeAppModel.cameras(snap).firstIndex { $0.id == cam.id } ?? 0
            let img = HomeCamArt.image(idx)
            demoImages[cam.id] = img
            return img
        }
        return images[cam.id]
    }
    /// 這一路正在出即時畫面（3 秒內有新的一格）
    private func isLive(_ id: String) -> Bool { liveFrameAt[id].map { clock - $0 < 3 } ?? false }
    private func ageText(_ cam: HomeCameraItem) -> String {
        if !Self.demo, schedule.noResponse(cam.id) { return L("home.noResponse", "无响应") }
        let age = Self.demo ? 4 : schedule.age(cam.id, now: clock)
        guard let a = age else { return L("home.cam.loading", "正在取得快照…") }
        return a < 2 ? L("home.cam.justNow", "刚刚") : String(format: L("home.cam.ago", "%d 秒前"), a)
    }

    /// image：給了就畫這張（近況時間軸選的那一刻），否則畫最新的
    private func drawFrame(_ g: CGContext, _ face: Face, _ cam: HomeCameraItem, _ r: CGRect, radius: CGFloat, fit: Bool = false, image: CGImage? = nil) {
        g.saveGState()
        g.addPath(continuousRoundedRect(r, radius: radius)); g.clip()
        if !RemotePrivacy.guestActive, let img = image ?? cameraImage(cam) {   // 2.0 idle: 訪客裝置在用：攝影機只畫灰底
            // 填滿（等比、置中裁切）；fit＝完整畫面（等比、整張放進去，上下留黑）
            let iw = CGFloat(img.width), ih = CGFloat(img.height), k = fit ? min(r.width / iw, r.height / ih) : max(r.width / iw, r.height / ih)
            face.drawUpright(g, img, in: CGRect(x: r.midX - iw * k / 2, y: r.midY - ih * k / 2, width: iw * k, height: ih * k))
        } else {
            g.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); g.fill(r)
            face.drawSymbol(g, "video.fill", in: CGRect(x: r.midX - 34, y: r.midY - 28, width: 68, height: 56), color: NSColor.white.withAlphaComponent(0.3))
        }
        g.restoreGState()
    }

    private func drawCameraGrid(_ g: CGContext, _ face: Face, _ cams: [HomeCameraItem]) {
        let small = cams.count > 4   // 2.0 P10：3×3 的格子小，標籤只留名字＋幾秒前
        for (r, c) in zip(Self.cameraCells(cams.count), cams) {
            drawFrame(g, face, c, r, radius: small ? 32 : 44)
            let nf = HPComponents.sf(small ? 30 : 32, weight: .semibold)
            let a = small ? ageText(c) : "\(L("home.cam.snapshot", "快照")) · \(ageText(c))", af = HPComponents.sf(small ? 26 : 28, weight: .regular)
            let aw = Typo.width(a, af)
            face.drawLeft(g, Face.clipped(c.name, nf, small ? r.width - aw - 28 : 240), font: nf, x: r.minX + 8, y: r.maxY + 44, color: HPComponents.label)
            face.drawLeft(g, a, font: af, x: r.maxX - 8 - aw, y: r.maxY + 44, color: HPComponents.secondary)
            HPAX.note(g, r, .button, "\(c.name), \(ageText(c))")
        }
    }

    /// 攝影機全螢幕（影片 v1 02:02.75 門鈴接管）：畫面鋪滿到圓角；頂部漸層上名稱 semibold 40／副標 30（58% 白）；
    /// 底部紅 ✕（關閉）、黃麥克風（不支援雙向語音：灰掉）、玻璃格狀鈕（看全部攝影機）
    private func drawCameraPage(_ g: CGContext, _ face: Face, _ cam: HomeCameraItem) {
        g.setFillColor(NSColor.black.cgColor); g.fill(MediaUI.full)
        let fill = camFill(cam.id)
        let tl = CameraTimeline.shared, wall = Date().timeIntervalSince1970   // 體驗追趕 P4：近況時間軸
        if tl.onUpdate == nil { tl.onUpdate = { [weak self] in self?.dirty = true } }
        if Self.demo, let img = cameraImage(cam) { tl.seedDemo(cam.id, img, now: wall) }
        let past = RemotePrivacy.guestActive ? nil : tl.image(cam.id)
        drawFrame(g, face, cam, MediaUI.full, radius: Screen.cornerRadius, fit: !fill, image: past)
        if let grad = MediaUI.shade(0.55) {
            g.saveGState(); g.translateBy(x: 0, y: 300); g.scaleBy(x: 1, y: -1)   // 由下往上變黑＝頂部漸層
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 300), options: [])
            g.restoreGState()
        }
        if let grad = MediaUI.shade(0.45) { g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 700), end: CGPoint(x: 0, y: 1024), options: []) }
        let tf = HPComponents.fitted(cam.name, size: 40, weight: .semibold, maxWidth: 520)
        textCentered(g, face, cam.name, font: tf, cx: 512, y: 168, color: .white)
        let pastAt = tl.selected[cam.id].flatMap { i in tl.frames[cam.id].flatMap { i < $0.count ? $0[i].at : nil } }
        let sub = pastAt.map { "\(L("home.cam.snapshot", "快照")) · \(CameraTimeline.timeText($0))" }
            ?? (isLive(cam.id) ? L("home.cam.live", "实时") : "\(L("home.cam.snapshot", "快照")) · \(ageText(cam))")
        textCentered(g, face, sub, font: HPComponents.sf(30, weight: .regular), cx: 512, y: 210, color: NSColor.white.withAlphaComponent(0.58))
        HPComponents.actionButton(g, face, Self.camClose, symbol: "xmark", role: .stop)
        HPComponents.actionButton(g, face, Self.camMic, symbol: "mic.slash.fill", role: .mic, enabled: false)
        HPComponents.glassCircle(g, face, Self.camGrid, symbol: "square.grid.2x2.fill", ink: .white, scale: 0.36, tint: HPComponents.mediaTint)
        HPComponents.glassCircle(g, face, Self.camFit, symbol: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 ink: .white, scale: 0.4, tint: HPComponents.mediaTint)
        HPAX.note(g, Self.camFit, .button, fill ? L("home.cam.showFull", "显示完整画面") : L("home.cam.fill", "填满屏幕"), shape: .circle)
        if !RemotePrivacy.guestActive { tl.draw(g, face: face, id: cam.id, now: wall) }
        drawRelated(g, face, cam.id)   // 2.0 home-1：門鈴響了，開門燈、開鎖不必離開畫面
        let note = L("home.cam.noTalk", "目前不支持双向语音")
        textCentered(g, face, note, font: HPComponents.fitted(note, size: 26, weight: .regular, maxWidth: 360), cx: Self.camMic.midX, y: Self.camMic.minY - 24, color: NSColor.white.withAlphaComponent(0.7))
    }
}

/// 家庭磚的排法（純幾何，selftest 驗）：3 欄，大磚佔 2×2；照順序放進最上、最左放得下的空位
enum HomeGrid {
    static func pack(_ sizes: [Int], columns: Int = 3) -> [(col: Int, row: Int, size: Int)] {
        var used = Set<Int>()                    // row * columns + col
        func free(_ r: Int, _ c: Int, _ s: Int) -> Bool {
            guard c + s <= columns else { return false }
            for dr in 0..<s { for dc in 0..<s where used.contains((r + dr) * columns + c + dc) { return false } }
            return true
        }
        var out: [(Int, Int, Int)] = []
        for s0 in sizes {
            let s = max(1, min(s0, columns))
            var placed = false
            var r = 0
            while !placed {
                for c in 0..<columns where free(r, c, s) {
                    for dr in 0..<s { for dc in 0..<s { used.insert((r + dr) * columns + c + dc) } }
                    out.append((c, r, s)); placed = true; break
                }
                r += 1
            }
        }
        return out
    }
}

// MARK: - 示範攝影機畫面（程式畫的，不是真的影像）

enum HomeCamArt {
    static func image(_ i: Int) -> CGImage {
        let w = 640, h = 360
        return makeImage(w, h) { g in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            func lin(_ a: UInt32, _ b: UInt32, _ y0: CGFloat, _ y1: CGFloat) {
                let gr = CGGradient(colorsSpace: cs, colors: [srgb(a).cgColor, srgb(b).cgColor] as CFArray, locations: [0, 1])!
                g.saveGState(); g.clip(to: CGRect(x: 0, y: y0, width: CGFloat(w), height: y1 - y0))
                g.drawLinearGradient(gr, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: []); g.restoreGState()
            }
            func box(_ x: CGFloat, _ y: CGFloat, _ bw: CGFloat, _ bh: CGFloat, _ c: UInt32, r: CGFloat = 0, a: CGFloat = 1) {
                g.setFillColor(srgb(c, a).cgColor); g.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: bw, height: bh), cornerWidth: r, cornerHeight: r, transform: nil)); g.fillPath()
            }
            func glow(_ x: CGFloat, _ y: CGFloat, _ rad: CGFloat, _ c: UInt32, _ a: CGFloat) {
                let gr = CGGradient(colorsSpace: cs, colors: [srgb(c, a).cgColor, srgb(c, 0).cgColor] as CFArray, locations: [0, 1])!
                g.drawRadialGradient(gr, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: rad, options: [])
            }
            if i >= 4 { g.translateBy(x: CGFloat(w), y: 0); g.scaleBy(x: -1, y: 1) }   // 2.0 P10：第 5–9 台鏡像，九格看得出不同台
            switch i % 4 {
            case 0:   // 大門：黃昏、門廊燈
                lin(0x2c3a5c, 0x9a7a66, 0, 210); lin(0x2a2a2d, 0x161618, 210, 360)
                box(110, 60, 420, 170, 0x6b5d52); box(110, 50, 420, 24, 0x3a302b)
                box(290, 110, 80, 120, 0x3e2a20, r: 4); box(300, 124, 24, 40, 0x6a5040, r: 2)
                box(180, 120, 60, 70, 0x2a3140, r: 3); box(430, 120, 60, 70, 0x2a3140, r: 3)
                box(270, 230, 120, 10, 0x4a4a4e); box(255, 240, 150, 10, 0x56565a)
                glow(252, 112, 120, 0xffc66e, 0.7)
            case 1:   // 車庫：灰牆、捲門、車
                lin(0x555a62, 0x3a3d43, 0, 250); lin(0x3a3a3c, 0x222224, 250, 360)
                box(80, 40, 480, 230, 0x8a8f96, r: 6)
                g.setStrokeColor(srgb(0x6e737a).cgColor); g.setLineWidth(3)
                for k in 1..<6 { g.move(to: CGPoint(x: 80, y: 40 + CGFloat(k) * 38)); g.addLine(to: CGPoint(x: 560, y: 40 + CGFloat(k) * 38)); g.strokePath() }
                box(150, 250, 340, 70, 0x1b1d22, r: 30); box(210, 222, 220, 44, 0x1b1d22, r: 20); box(228, 230, 184, 26, 0x39414f, r: 10)
                glow(320, 20, 220, 0xffffff, 0.18)
            case 2:   // 後院：草地、圍籬、樹
                lin(0x7aa0b8, 0xc2d6c4, 0, 170); lin(0x4f7d44, 0x2f5530, 170, 360)
                for k in 0..<22 { box(CGFloat(k) * 30, 120, 22, 80, 0x8a7355); box(CGFloat(k) * 30, 120, 22, 8, 0x6e5a42) }
                g.setFillColor(srgb(0x2f5a38).cgColor); g.fillEllipse(in: CGRect(x: 440, y: 20, width: 150, height: 150)); g.fillEllipse(in: CGRect(x: 400, y: 60, width: 110, height: 110))
                box(508, 150, 14, 60, 0x4a3a2a)
                box(120, 290, 120, 18, 0x6f5a40, r: 4); box(130, 270, 100, 28, 0x7d6648, r: 6)
            default:  // 客廳：暖色牆、窗、沙發、落地燈
                lin(0xcdb99b, 0xb39c7c, 0, 250); lin(0x8b6b4a, 0x634a31, 250, 360)
                box(60, 50, 190, 150, 0xe6eef6, r: 6); box(60, 50, 190, 150, 0xffffff, r: 6, a: 0.15)
                g.setStrokeColor(srgb(0xb8c2cc).cgColor); g.setLineWidth(6); g.move(to: CGPoint(x: 155, y: 50)); g.addLine(to: CGPoint(x: 155, y: 200)); g.move(to: CGPoint(x: 60, y: 125)); g.addLine(to: CGPoint(x: 250, y: 125)); g.strokePath()
                box(250, 200, 280, 90, 0x5a4a5e, r: 22); box(250, 170, 280, 50, 0x6b5a70, r: 18); box(230, 220, 40, 80, 0x4c3e50, r: 14); box(510, 220, 40, 80, 0x4c3e50, r: 14)
                box(580, 120, 6, 170, 0x3a3a3a); glow(583, 110, 110, 0xffd68a, 0.8)
            }
            if i >= 4 { g.setFillColor(srgb([0x1a2a4a, 0x3a2a10, 0x0f2a1a, 0x2a1030, 0x101820][(i - 4) % 5], 0.28).cgColor); g.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
            // 暗角
            let vg = CGGradient(colorsSpace: cs, colors: [srgb(0x000000, 0).cgColor, srgb(0x000000, 0.45).cgColor] as CFArray, locations: [0.55, 1])!
            g.drawRadialGradient(vg, startCenter: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2), startRadius: 0, endCenter: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2), endRadius: 400, options: [])
        }
    }
}


// MARK: - 家庭警報橫幅（HomeView 對齊 WP5：官方文案；紅底白字、點一下收掉）

extension HomeApp {
    /// 攝影機頁底下是 ✕／麥克風／格狀鈕：橫幅改放在標題下面，不蓋按鈕也不擋太多畫面
    static func alertBannerRect(camera: Bool) -> CGRect { CGRect(x: 64, y: camera ? 232 : 1024 - 96 - 152, width: 896, height: 152) }
    /// 圓角跟螢幕同心（左右離螢幕 64；152 高的連續圓角最多畫到約 50，見 EdgeContainers）
    static func alertBannerRadius(_ r: CGRect) -> CGFloat { HPTokens.Radius.concentric(rect: r) }

    func drawAlertBanner(_ g: CGContext, _ face: Face, now: Double) {
        guard let a = HomeAlerts.active.first else { return }
        let r = Self.alertBannerRect(camera: cameraID != nil), rad = Self.alertBannerRadius(r)
        // beta 5（拍板）：底色永遠不透明（白字對比穩定、底下的磚不透出來），脈動只改紅的深淺（1.6 s 一次；減少動態效果不脈動）
        let dim: CGFloat = ClockKit.reduceMotion ? 0 : CGFloat(0.12 * (1 - cos((now - a.at) * 2 * .pi / 1.6)))
        let red = HPTokens.red.blended(withFraction: dim, of: .black) ?? HPTokens.red
        g.setFillColor(red.cgColor)   // 要設在 g 上：NSColor.setFill() 只改 NSGraphicsContext，這裡會沿用上一個填色（白）
        g.addPath(continuousRoundedRect(r, radius: rad)); g.fillPath()
        face.drawSymbol(g, a.kind.symbol, in: CGRect(x: r.minX + 40, y: r.midY - 30, width: 60, height: 60), color: .white)
        let tf = AppUI.font(44, .semibold)
        // 畫布左上原點：標題在上（基線 midY − 8）、說明在下（基線 midY + 42）
        face.drawLeft(g, a.kind.title, font: tf, x: r.minX + 128, y: r.midY - 8, color: .white)
        face.drawLeft(g, Face.clipped(HomeAlerts.body(a), AppUI.font(34), r.width - 200), font: AppUI.font(34), x: r.minX + 128, y: r.midY + 42, color: NSColor.white.withAlphaComponent(0.85))
        HPAX.note(g, r, .button, "\(a.kind.title) \(HomeAlerts.body(a))", shape: .rounded(rad))
        // 點一下收掉這則（handleTap 裡命中這個矩形就 dismiss）
        alertRect = r
    }
}
