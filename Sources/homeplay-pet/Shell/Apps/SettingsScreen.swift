// 2.0 home-1：螢幕上的設定（提案 docs/plans/homeview-native.html 第 1 批）。
// 以前點「設定」只會在 Mac 上開原本的 SwiftUI 視窗，螢幕上一片黑；HomeView 上站著的人碰不到。
// 螢幕上只放三件跟「這台」有關的事，其餘照舊交給 Mac 視窗（「更多設定…」）：
// - 所在房間（HomeThisRoom：家庭 App 先顯示這個房間、ClioTalk 說「關燈」只關這裡）
// - 亮度（Shell.brightness，跟控制中心同一個值）
// - 誰看得到什麼（說明，照官方 HomeView 的說法；規則本身在 PersonalGate）
// 遠端訪客的裝置在用時不給開（跟以前不能開 Mac 設定視窗同一條規則）。

import AppKit

final class SettingsApp: PetApp {
    let id = "settings"
    var title: String { L("app.settings", "设置") }
    let icon = AppIcon(color: srgb(0x8e8e93), symbol: "gearshape.fill", system: "/System/Applications/System Settings.app")

    enum Picker { case room, sharedList, sideshow, sideshowPair }
    var picking: Picker? = CommandLine.arguments.contains("--settings-room") ? .room : nil
    var hits: [(CGRect, () -> Void)] = []

    static let x0 = HPGrid.App.leading, x1 = HPGrid.App.trailing, inset = HPGrid.Inset.card
    static let row = HPTokens.Size.row

    func launch(face: Face) -> Bool { RemoteInput.fromGuest }   // 遠端訪客：不打開（吃掉，畫面不動）
    func didOpen(now: Double) { picking = CommandLine.arguments.contains("--settings-room") ? .room : SideShowSettings.demoPicker }
    var backSymbol: String { picking != nil ? "chevron.left" : "xmark" }
    func handleBack(now: Double) -> Bool {
        if picking == .sideshowPair { picking = .sideshow; SideShowServer.shared.store.cancelPairing(); return true }   // 加入裝置 → 回 SideShow
        if picking != nil { picking = nil; return true }
        return false
    }

    private var snap: HomeSnapshot { HomeApp.demo ? HomeAppModel.demoSnapshot() : HomeLink.shared.snapshot }
    private var rooms: [HomeRoom] {
        let s = snap, home = (s.homes.first(where: \.primary) ?? s.homes.first)?.id
        return s.rooms.filter { home == nil || $0.home == nil || $0.home == home }
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        if handleTapBrightness(p) { face.forceDirty = true; return true }
        guard let h = hits.first(where: { $0.0.contains(p) }) else { return false }
        h.1(); face.forceDirty = true
        return true
    }

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(HPComponents.bg.cgColor); g.fill(rect)
        hits = []
        switch picking {
        case .room?: drawRoomPicker(g, face); AppUI.title(g, face, L("settings.room", "所在房间")); return
        case .sharedList?: drawListPicker(g, face); AppUI.title(g, face, L("settings.sharedList", "家人共用清单")); return
        case .sideshow?: drawSideShow(g, face); AppUI.title(g, face, L("settings.sideshow", "SideShow")); return   // SideShow/SideShowSettings.swift
        case .sideshowPair?: drawSideShowPair(g, face, now: now); AppUI.title(g, face, L("sideshow.add", "添加设备")); return
        case nil: break
        }
        drawMain(g, face)
        AppUI.title(g, face, title)
    }

    // MARK: 畫

    let lf = HPType.sf(42, .regular), sf = HPType.sf(30, .regular), hf = HPType.sf(30, .semibold)

    func header(_ g: CGContext, _ face: Face, _ t: String, y: inout CGFloat) {
        face.drawLeft(g, t, font: hf, x: Self.x0 + Self.inset, y: y + 40, color: HPComponents.secondary)
        y += 56
    }
    func footnote(_ g: CGContext, _ face: Face, _ t: String, y: inout CGFloat) {
        for l in MediaUI.wrap(t, sf, Self.x1 - Self.x0 - 2 * Self.inset, maxLines: 6) {
            face.drawLeft(g, l, font: sf, x: Self.x0 + Self.inset, y: y + 38, color: HPComponents.secondary); y += 40
        }
    }
    /// 一列：左邊名稱、右邊值與 ›（action 為 nil＝不能點，字變淡）
    /// dim：真的不能用（例如沒有小幫手）才變淡；純說明的列照常是主文字色
    func row(_ g: CGContext, _ face: Face, _ r: CGRect, _ title: String, value: String?, chevron: Bool, check: Bool = false, dim: Bool = false, action: (() -> Void)?) {
        let x = r.minX + Self.inset
        let ink = dim ? HPComponents.secondary : HPComponents.label
        var right = r.maxX - Self.inset
        if chevron { face.drawSymbol(g, "chevron.right", in: CGRect(x: right - 20, y: r.midY - 16, width: 20, height: 32), color: HPComponents.tertiary, weight: .semibold); right -= 36 }
        if check { face.drawSymbol(g, "checkmark", in: CGRect(x: right - 34, y: r.midY - 16, width: 34, height: 32), color: HPComponents.blue, weight: .semibold); right -= 50 }
        var vw: CGFloat = 0
        if let v = value { vw = Typo.width(v, lf); face.drawLeft(g, v, font: lf, x: right - vw, y: r.midY + 15, color: HPComponents.secondary); vw += 24 }
        face.drawLeft(g, Face.clipped(title, lf, right - vw - x), font: lf, x: x, y: r.midY + 15, color: ink)
        HPAX.note(g, r, action == nil ? .text : .button, title, value: check ? L("a11y.selected", "已选择") : value, shape: .rounded(0))
        if let action { hits.append((r, action)) }
    }

    private func drawMain(_ g: CGContext, _ face: Face) {
        var y = HPTokens.contentTop
        let w = Self.x1 - Self.x0

        header(g, face, L("settings.thisDevice", "这台 HomeView"), y: &y)
        let s = snap
        let hasHome = HomeApp.demo || (HomeLink.helperInstalled && HomeLink.shared.connected && !rooms.isEmpty)
        let roomName = HomeThisRoom.room(in: s)?.name ?? L("settings.room.none", "未设置")
        // 2.0 home-2：家人共用清單（主人才能選；要先有提醒事項的權限）
        let rs = ReminderSource.shared
        let canPickList = rs.authorized && PersonalGate.allowed
        let sharedName = RemindersApp.sharedListID.flatMap { id in rs.lists.first { $0.id == id }?.title } ?? L("settings.room.none", "未设置")
        let card1 = CGRect(x: Self.x0, y: y, width: w, height: Self.row * 4)   // 第 4 列：SideShow
        HPComponents.groupCard(g, card1)
        row(g, face, CGRect(x: Self.x0, y: y, width: w, height: Self.row), L("settings.room", "所在房间"),
            value: hasHome ? roomName : L("settings.room.needHelper", "需要小帮手"), chevron: hasHome, dim: !hasHome,
            action: hasHome ? { [weak self] in self?.picking = .room } : nil)
        HPComponents.separatorLine(g, x: Self.x0 + Self.inset, maxX: Self.x1, y: y + Self.row)
        row(g, face, CGRect(x: Self.x0, y: y + Self.row, width: w, height: Self.row), L("settings.sharedList", "家人共用清单"),
            value: canPickList ? sharedName : L("settings.sharedList.needAccess", "需要提醒事项"), chevron: canPickList, dim: !canPickList,
            action: canPickList ? { [weak self] in rs.refreshIfNeeded(); self?.picking = .sharedList } : nil)
        HPComponents.separatorLine(g, x: Self.x0 + Self.inset, maxX: Self.x1, y: y + Self.row * 2)
        y += Self.row
        // 亮度：整列就是滑桿（跟控制中心同一個值）；點哪裡就到哪裡，最暗 20%
        let br = CGRect(x: Self.x0, y: y + Self.row, width: w, height: Self.row)
        let track = CGRect(x: br.minX + Self.inset + 56, y: br.midY - 8, width: br.width - 2 * Self.inset - 112, height: 16)
        face.drawSymbol(g, "sun.min", in: CGRect(x: br.minX + Self.inset, y: br.midY - 18, width: 36, height: 36), color: HPComponents.secondary)
        face.drawSymbol(g, "sun.max.fill", in: CGRect(x: track.maxX + 20, y: br.midY - 20, width: 40, height: 40), color: HPComponents.secondary)
        AppUI.fillPill(g, track, color: HPComponents.fill)
        let lv = max(0, min(1, (Shell.brightness - 0.2) / 0.8))
        AppUI.fillPill(g, CGRect(x: track.minX, y: track.minY, width: max(track.height, track.width * lv), height: track.height), color: HPComponents.label)
        HPAX.note(g, br, .text, L("settings.brightness", "亮度"), value: "\(Int((Shell.brightness * 100).rounded()))%", shape: .rounded(0))
        brightnessTrack = track
        // SideShow（區網副屏，SideShow/SideShowSettings.swift）：放在這張卡裡，畫面放得下
        HPComponents.separatorLine(g, x: Self.x0 + Self.inset, maxX: Self.x1, y: y + Self.row * 2)
        row(g, face, CGRect(x: Self.x0, y: y + Self.row * 2, width: w, height: Self.row), L("settings.sideshow", "SideShow"),
            value: SideShowSettings.on ? L("sideshow.on", "开") : L("sideshow.off", "关"), chevron: true) { [weak self] in self?.picking = .sideshow }
        y += Self.row * 3
        y += HPGrid.Rhythm.rowGap
        footnote(g, face, L("settings.room.note", "家庭 App 先显示这个房间；对 ClioTalk 说“关灯”只关这里，说“全部”才是整个家。")
                 + " " + L("settings.sharedList.note", "共用清单（例如购物）家人和访客都看得到、都能勾；摆在厨房时打开提醒事项直接是它。"), y: &y)
        y += HPGrid.Rhythm.sectionGap

        header(g, face, L("settings.privacy", "谁看得到什么"), y: &y)
        let card2 = CGRect(x: Self.x0, y: y, width: w, height: Self.row * 2)
        HPComponents.groupCard(g, card2)
        row(g, face, CGRect(x: Self.x0, y: y, width: w, height: Self.row), L("settings.privacy.owner", "认出主人时"), value: L("settings.privacy.all", "全部"), chevron: false, action: nil)
        HPComponents.separatorLine(g, x: Self.x0 + Self.inset, maxX: Self.x1, y: y + Self.row)
        row(g, face, CGRect(x: Self.x0, y: y + Self.row, width: w, height: Self.row), L("settings.privacy.others", "家人和访客"), value: L("settings.privacy.shared", "家庭、音乐、计时器"), chevron: false, action: nil)
        y += Self.row * 2 + HPGrid.Rhythm.rowGap
        footnote(g, face, L("settings.privacy.note", "行事历、提醒事项、讯息、FaceTime、查找只在认出主人时显示。远程访客的设备只能开关灯。"), y: &y)
        y += HPGrid.Rhythm.sectionGap

        let more = CGRect(x: Self.x0, y: y, width: w, height: Self.row)
        HPComponents.groupCard(g, more)
        row(g, face, more, L("settings.more", "更多设置…"), value: nil, chevron: true) {
            guard let app = NSApp.delegate as? AppDelegate else { return }
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowController.show(app: app)
        }
    }
    private var brightnessTrack = CGRect.zero

    private func drawRoomPicker(_ g: CGContext, _ face: Face) {
        var y = HPTokens.contentTop
        let w = Self.x1 - Self.x0, list = rooms, cur = HomeThisRoom.room(in: snap)?.id
        let rowsN = list.count + 1
        HPComponents.groupCard(g, CGRect(x: Self.x0, y: y, width: w, height: Self.row * CGFloat(min(rowsN, 8))))
        let none = CGRect(x: Self.x0, y: y, width: w, height: Self.row)
        row(g, face, none, L("settings.room.none", "未设置"), value: nil, chevron: false, check: cur == nil) { [weak self] in HomeThisRoom.id = nil; self?.picking = nil }
        for (i, r) in list.prefix(7).enumerated() {
            let rr = CGRect(x: Self.x0, y: y + Self.row * CGFloat(i + 1), width: w, height: Self.row)
            HPComponents.separatorLine(g, x: Self.x0 + Self.inset, maxX: Self.x1, y: rr.minY)
            row(g, face, rr, r.name, value: nil, chevron: false, check: cur == r.id) { [weak self] in HomeThisRoom.id = r.id; self?.picking = nil; log("settings room → \(r.id)") }
        }
        y += Self.row * CGFloat(min(rowsN, 8)) + HPGrid.Rhythm.rowGap
        footnote(g, face, L("settings.room.pickNote", "选这台 HomeView 摆放的房间。只存在这台 Mac 上。"), y: &y)
    }

    /// 家人共用清單：提醒事項的清單（最多 7 份）＋未設定
    private func drawListPicker(_ g: CGContext, _ face: Face) {
        var y = HPTokens.contentTop
        let w = Self.x1 - Self.x0, list = Array(ReminderSource.shared.lists.prefix(7)), cur = RemindersApp.sharedListID
        HPComponents.groupCard(g, CGRect(x: Self.x0, y: y, width: w, height: Self.row * CGFloat(list.count + 1)))
        row(g, face, CGRect(x: Self.x0, y: y, width: w, height: Self.row), L("settings.room.none", "未设置"), value: nil, chevron: false, check: cur == nil) { [weak self] in
            RemindersApp.sharedListID = nil; self?.picking = nil
        }
        for (i, l) in list.enumerated() {
            let rr = CGRect(x: Self.x0, y: y + Self.row * CGFloat(i + 1), width: w, height: Self.row)
            HPComponents.separatorLine(g, x: Self.x0 + Self.inset, maxX: Self.x1, y: rr.minY)
            row(g, face, rr, l.title, value: nil, chevron: false, check: cur == l.id) { [weak self] in
                RemindersApp.sharedListID = l.id; self?.picking = nil; log("settings shared list → \(l.id)")
            }
        }
        y += Self.row * CGFloat(list.count + 1) + HPGrid.Rhythm.rowGap
        footnote(g, face, L("settings.sharedList.pickNote", "这份清单不需要认出主人：家人和访客都能看、能勾。其他清单照旧只给主人。"), y: &y)
    }

    /// 亮度：點在軌道哪裡就到哪裡（命中上下補到 88）
    private func handleTapBrightness(_ p: CGPoint) -> Bool {
        guard picking == nil, brightnessTrack.insetBy(dx: -40, dy: -36).contains(p) else { return false }
        Shell.brightness = 0.2 + 0.8 * max(0, min(1, (p.x - brightnessTrack.minX) / brightnessTrack.width))
        return true
    }
}
