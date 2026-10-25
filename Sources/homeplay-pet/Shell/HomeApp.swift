// 家庭 App（稿：hv-design/project/Home.dc.html；研究 handson.md §Home Camera）：
// - 房間：頂端一排房間膠囊（放不下就左右小箭頭），底下場景一排，再來是配件磚；開著的＝亮白磚。
//   點一下切換；長按燈／窗簾開「調整」（亮度、位置）；滾輪捲動磚、在調整面板裡改數值；溫控磚兩側是 − ＋。
//   門鎖：鎖著的門第一下只待命（「再按一次开锁」），4 秒內再按才開鎖；上鎖不需確認。
// - 攝影機：最多 4 路，2×2 的快照格（每 10 秒更新）；點一格進單一攝影機頁（照實機：× 左上、喇叭右上、16:9 置中、
//   左下格狀鈕、右下黃色麥克風；雙向語音不支援，麥克風與喇叭是灰的並註明）。
// - 沒裝「HomePlay Home」小幫手（公開版）：一張誠實的說明卡＋開 Mac「家庭」App 的按鈕。
// 資料全來自 HomeLink（HomeKit 只有開發簽名的 Catalyst 小幫手拿得到）；純邏輯在 HomeAppModel.swift。
// 快照旗標：--demo-home（示範資料）、--home-tab N|cameras、--home-camera N、--home-detail [light|thermostat|covering]、--home-view nohelper|connecting|empty
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
    private var images: [String: CGImage] = [:]
    private var demoImages: [String: CGImage] = [:]
    private var pendingWrite: (id: String, value: HomeValue, type: String)?
    private var lastWrite = 0.0

    private var clock: Double { CACurrentMediaTime() }

    private var snap: HomeSnapshot { Self.demo ? demoSnap : HomeLink.shared.snapshot }
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
            let t: HomeTile? = want == "thermostat" ? all.first { $0.kind == .thermostat } : want == "covering" ? all.first { $0.kind == .covering }
                : all.first { $0.kind == .light && $0.brightnessID != nil && $0.on }
            if let t {
                tab = 0
                openDetail(t, from: tileLayout(page()).first { $0.item.tile?.id == t.id }?.rect ?? CGRect(x: 362, y: 352, width: 300, height: 300), now: clock)
            }
        }
        guard !Self.demo, Self.forcedView == nil, HomeLink.helperInstalled else { return }
        HomeLink.shared.start()
        if observers.isEmpty {
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
    private enum Item { case tile(HomeTile), scene(HomeScene), camera(HomeCameraItem), clock, homeApp
        var tile: HomeTile? { if case .tile(let t) = self { return t }; return nil }
        var big: Bool { if case .tile(let t) = self { return t.kind == .thermostat }; return false }
    }
    /// R15：官方那一頁的排法——時鐘、前兩個配件；攝影機、家庭、第一個場景；其餘配件、場景、攝影機接在後面
    private func items(_ p: Page) -> [Item] {
        guard let g = p.group else { return [] }
        let tiles = g.tiles.map { Item.tile($0) }, scenes = p.scenes.map { Item.scene($0) }, cams = p.cameras.map { Item.camera($0) }
        if Self.guestView { return [.clock] + tiles }   // 訪客版：沒有「家庭」磚（會在 Mac 上開家庭 App）
        return [.clock] + tiles.prefix(2) + cams.prefix(1) + [.homeApp] + scenes.prefix(1) + tiles.dropFirst(2) + scenes.dropFirst(1) + cams.dropFirst(1)
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
    private static let camMic = HPComponents.actionRect(cx: 512 + 100, cy: camY)
    private static let camGrid: CGRect = {
        let c = Screen.cornerCapsuleCenter(.bottomRight, width: HPComponents.actionSize, height: HPComponents.actionSize); return HPComponents.actionRect(cx: c.x, cy: c.y)
    }()
    private static let openHomeButton = CGRect(x: 512 - 330, y: 700, width: 660, height: 112)
    // 滿版控制卡
    private static let thermoDown = HPComponents.actionRect(cx: 150, cy: 520, size: 120)
    private static let thermoUp = HPComponents.actionRect(cx: 874, cy: 520, size: 120)
    private static let thermoPower = CGRect(x: 512 - 150, y: 800, width: 300, height: 96)

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
    private var onDashboard: Bool { state == .ready && detail == nil && cameraID == nil && !page().onCameras }
    var showsCloseButton: Bool { detail == nil && cameraID == nil && !onDashboard }
    var showsClock: Bool { detail == nil && cameraID == nil && !onDashboard }
    var backSymbol: String { state == .ready && page().onCameras ? "chevron.left" : "xmark" }
    func handleBack(now: Double) -> Bool {
        if detail != nil, !detailClosing { closeDetail(now: clock); return true }
        if cameraID != nil { cameraID = nil; return true }
        if tab != 0, state == .ready { tab = 0; scroll = 0; return true }
        return false
    }

    func tick(_ now: Double) -> Bool {
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
            let p = page()
            // 第四輪：根頁上的攝影機磚也要快照（打開就要一張，到之前是佔位）
            let ids = cameraID.map { [$0] } ?? (p.onCameras || detail == nil ? p.cameras.map(\.id) : [])
            for id in schedule.next(ids, now: t) {   // 2.0 P10：九路錯開、限速（SnapshotSchedule.next）
                schedule.began(id, now: t)
                HomeLink.shared.cameraSnapshot(id: id) { [weak self] data, _ in
                    guard let self else { return }
                    let ok = data != nil
                    if let data, let img = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { self.images[id] = img }
                    self.schedule.finished(id, ok: ok, now: self.clock)
                    self.dirty = true
                }
            }
        }
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
        guard state == .ready, cameraID == nil, detail == nil else { return false }
        let p = page()
        for (r, it) in tileLayout(p) where r.contains(pt) && pt.y > Self.gridTop - 8 {
            guard let t = it.tile, t.reachable, t.kind == .covering || (t.kind == .light && t.brightnessID != nil) else { return false }
            openDetail(t, from: r, now: clock); return true
        }
        return false
    }

    func handleTap(_ pt: CGPoint, face: Face, now: Double) -> Bool {
        let st = state
        if st == .noHelper {
            if Self.openHomeButton.insetBy(dx: -8, dy: -8).contains(pt) { Self.openAppleHome(); return true }
            return false
        }
        guard st == .ready else { return false }
        let p = page()
        let t = clock

        // 滿版控制卡
        if let tile = currentTile(p) {
            if detailClosing { return true }
            if HPComponents.hitBack(pt) { closeDetail(now: t); return true }
            if tile.kind == .thermostat {
                if let a = tile.activeID, Self.thermoPower.insetBy(dx: -8, dy: -8).contains(pt) { commit(a, HomeValue(number: tile.on ? 0 : 1), type: "active"); return true }
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
        if cameraID != nil {
            if Self.camClose.insetBy(dx: -8, dy: -8).contains(pt) { HPComponents.navigateBack(); return true }
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
        Shell.drawAppIcon(g, face: face, icon: icon, in: CGRect(x: 512 - 96, y: 260, width: 192, height: 192))
        let f = HPComponents.sf(42, weight: .semibold)
        let lines = MediaUI.wrap(L("home.needHelper", "家庭需要 HomePlay Home 小帮手（目前只在开发版提供）"), f, 760, maxLines: 4)
        for (i, l) in lines.enumerated() { textCentered(g, face, l, font: f, cx: 512, y: 530 + CGFloat(i) * 58, color: HPComponents.label) }
        HPAX.note(g, CGRect(x: 128, y: 480, width: 768, height: CGFloat(lines.count) * 58 + 30), .text, L("home.needHelper", "家庭需要 HomePlay Home 小帮手（目前只在开发版提供）"), shape: .rounded(16))   // 2.0 depth：VoiceOver
        HPComponents.filledButton(g, face, Self.openHomeButton, L("home.openApple", "在 Mac 的「家庭」App 中打开"), tint: HPComponents.orange)
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

    /// 溫控滿版（影片 v2 O115）：「制冷中／加热中」、超大目標數字、兩側淡色圓鈕、底下目前溫度與濕度
    private func drawThermoContent(_ g: CGContext, _ face: Face, _ t: HomeTile) {
        let mode = thermoMode(t)
        let readOnly = t.targetTempID == nil && t.activeID == nil
        let head = readOnly ? L("home.thermo.indoor", "室内温度") : mode == 2 ? L("home.thermo.cool", "制冷中") : mode == 1 ? L("home.thermo.heat", "加热中") : L("home.off", "关")
        textCentered(g, face, head, font: HPComponents.sf(40, weight: .medium), cx: 512, y: 330, color: NSColor.white.withAlphaComponent(0.8))
        let big = (t.target ?? t.temp).map { HomeAppModel.tempText($0) } ?? "—"
        textCentered(g, face, big, font: FaceType.sf(300, .light), cx: 512, y: 610, color: .white)
        HPAX.note(g, CGRect(x: 240, y: 280, width: 544, height: 380), .text, head, value: big, shape: .rounded(24))   // 2.0 depth：VoiceOver
        if t.targetTempID != nil {
            HPAX.note(g, Self.thermoDown, .button, L("a11y.tempDown", "降低温度"), value: big, shape: .circle)
            HPAX.note(g, Self.thermoUp, .button, L("a11y.tempUp", "升高温度"), value: big, shape: .circle)
            for (r, sym) in [(Self.thermoDown, "chevron.down"), (Self.thermoUp, "chevron.up")] {
                HPComponents.glassCircle(g, face, r, symbol: sym, ink: .white, scale: 0.34)
            }
        }
        // 第四輪：冷暖氣的開關（HomeKit Active）
        if t.activeID != nil {
            HPComponents.glassButton(g, face, Self.thermoPower, t.on ? L("home.thermo.turnOff", "关闭") : L("home.thermo.turnOn", "打开"), symbol: "power")
        }
        var parts: [(String, String)] = []
        if let cur = t.temp { parts.append(("thermometer.medium", HomeAppModel.tempText(cur))) }
        if let h = snap.accessories.first(where: { $0.id == t.id })?.characteristic("humidity")?.value?.number { parts.append(("humidity", "\(Int(h.rounded()))%")) }
        let f = HPComponents.sf(32, weight: .medium)
        let w = parts.reduce(CGFloat(0)) { $0 + 44 + Typo.width($1.1, f) } + CGFloat(max(0, parts.count - 1)) * 36
        var x = 512 - w / 2
        for (sym, s) in parts {
            face.drawSymbol(g, sym, in: CGRect(x: x, y: 690, width: 34, height: 34), color: .white, weight: .semibold)
            face.drawLeft(g, s, font: f, x: x + 44, y: 718, color: .white); x += 44 + Typo.width(s, f) + 36
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
    private func ageText(_ cam: HomeCameraItem) -> String {
        if !Self.demo, schedule.noResponse(cam.id) { return L("home.noResponse", "无响应") }
        let age = Self.demo ? 4 : schedule.age(cam.id, now: clock)
        guard let a = age else { return L("home.cam.loading", "正在取得快照…") }
        return a < 2 ? L("home.cam.justNow", "刚刚") : String(format: L("home.cam.ago", "%d 秒前"), a)
    }

    private func drawFrame(_ g: CGContext, _ face: Face, _ cam: HomeCameraItem, _ r: CGRect, radius: CGFloat) {
        g.saveGState()
        g.addPath(continuousRoundedRect(r, radius: radius)); g.clip()
        if !RemotePrivacy.guestActive, let img = cameraImage(cam) {   // 2.0 idle: 訪客裝置在用：攝影機只畫灰底
            // 填滿（等比、置中裁切）
            let iw = CGFloat(img.width), ih = CGFloat(img.height), k = max(r.width / iw, r.height / ih)
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
        drawFrame(g, face, cam, MediaUI.full, radius: Screen.cornerRadius)
        if let grad = MediaUI.shade(0.55) {
            g.saveGState(); g.translateBy(x: 0, y: 300); g.scaleBy(x: 1, y: -1)   // 由下往上變黑＝頂部漸層
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 300), options: [])
            g.restoreGState()
        }
        if let grad = MediaUI.shade(0.45) { g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 700), end: CGPoint(x: 0, y: 1024), options: []) }
        let tf = HPComponents.fitted(cam.name, size: 40, weight: .semibold, maxWidth: 520)
        textCentered(g, face, cam.name, font: tf, cx: 512, y: 168, color: .white)
        let sub = "\(L("home.cam.snapshot", "快照")) · \(ageText(cam))"
        textCentered(g, face, sub, font: HPComponents.sf(30, weight: .regular), cx: 512, y: 210, color: NSColor.white.withAlphaComponent(0.58))
        HPComponents.actionButton(g, face, Self.camClose, symbol: "xmark", role: .stop)
        HPComponents.actionButton(g, face, Self.camMic, symbol: "mic.slash.fill", role: .mic, enabled: false)
        HPComponents.glassCircle(g, face, Self.camGrid, symbol: "square.grid.2x2.fill", ink: .white, scale: 0.36, tint: HPComponents.mediaTint)
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
