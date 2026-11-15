// 螢幕上的設定（2026-11-12 設計稿定案；前身是 2.0 home-1 的三組內容）。
// 只放「站在它前面會改的」七項，單欄清單、點了推入下一層；要打字、要授權、要配對的留在 Mac（最下面一行連過去）。
//   第一組（這台機器自己的事）：顯示與亮度、錶面與桌布、主畫面、聲音
//   第二組（和人與裝置有關）：這個房間、家人、iPhone 與 iPad
// 版面照整台共用規則：內容邊線 98.5（HPGrid.Content）、分組卡圓角跟螢幕同心 39.5（HPComponents.contentCard，
// 登記在 Design/EdgeContainers.swift）、列高 96／有副標 120、分組間距 24。頂端沿用現有 App 的頂端（外殼的玻璃圓鈕＋AppUI.title）。
// 每一列都接回原有的設定值，不另存一份（跟 Mac 設定視窗、控制中心同一個值）。
// 沒認出主人時，「家人」和「iPhone 與 iPad」只顯示要主人在場的說明。遠端訪客的裝置在用時不給開。

import AppKit

final class SettingsApp: PetApp {
    let id = "settings"
    var title: String { L("app.settings", "设置") }
    let icon = AppIcon(color: srgb(0x8e8e93), symbol: "gearshape.fill", system: "/System/Applications/System Settings.app")

    /// 要挑一個值的下一層（清單＋勾）
    enum Choice: Equatable { case sleep, textSize, face, look, wallpaper, iconLook }
    /// 下一層的頁（名字沿用舊的 Picker：SideShow/SideShowSettings.swift 在用）
    enum Picker: Equatable { case display, faces, home, sound, room, people, sharedList, sideshow, sideshowPair, choose(Choice) }

    /// 推入的頁，最後一個是現在這一頁；空＝第一頁
    private(set) var stack: [Picker] = []
    /// 現在這一頁。設成已經在堆疊裡的頁＝退回那一頁；設成新的＝推入；nil＝回第一頁
    var picking: Picker? {
        get { stack.last }
        set {
            guard let p = newValue else { go { $0 = [] }; return }
            if let i = stack.firstIndex(of: p) { go { $0 = Array($0.prefix(i + 1)) } } else { go { $0.append(p) } }
        }
    }
    var hits: [(CGRect, () -> Void)] = []
    private var sliders: [(CGRect, (CGFloat) -> Void)] = []
    private var scroll: CGFloat = 0
    private var maxScroll: CGFloat = 0
    /// 推入／推出：新的一頁從那一側滑進來（減少動態效果、快照直接到位）
    private var slide = MotionValue("settings.push", spring: .smooth, from: 1, to: 1, now: 0)
    private var slideDirection: CGFloat = 1

    static let x0 = HPGrid.Content.leading, x1 = HPGrid.Content.trailing, inset = HPGrid.Inset.nested
    static let row = HPTokens.Size.listRow, rowSub = HPTokens.Size.listRowSub
    /// 根頁列首的圖示方塊：48 見方，圓角＝分組卡 39.5 − 內距 24
    static let iconTile: CGFloat = 48
    static var iconTileRadius: CGFloat { HPTokens.Radius.concentric(parent: HPTokens.Radius.contentCard, padding: inset) }
    /// 根頁兩張分組卡的框（四列、三列）：貼邊容器自檢用，畫的時候也是這兩個
    static var rootCards: [CGRect] {
        let a = CGRect(x: x0, y: HPTokens.contentTop, width: x1 - x0, height: row * 4)
        return [a, CGRect(x: x0, y: a.maxY + HPGrid.Rhythm.groupGap, width: x1 - x0, height: row * 3)]
    }

    func launch(face: Face) -> Bool { RemoteInput.fromGuest }   // 遠端訪客：不打開（吃掉，畫面不動）
    func didOpen(now: Double) {
        stack = []; scroll = 0
        if let p = Self.demoPage ?? SideShowSettings.demoPicker { stack = p == .sideshowPair ? [.sideshow, p] : [p] }
        slide = MotionValue("settings.push", spring: .smooth, from: 1, to: 1, now: now)
    }
    var backSymbol: String { stack.isEmpty ? "xmark" : "chevron.left" }
    func handleBack(now: Double) -> Bool {
        guard let top = stack.last else { return false }
        if top == .sideshowPair { RemoteServer.shared.store.cancelPairing() }   // 加入裝置 → 回 iPhone 與 iPad
        go { $0.removeLast() }
        return true
    }
    func tick(_ now: Double) -> Bool { !slide.done(now) }

    /// 快照：--settings-page display|faces|home|sound|room|people|devices|sleep|textsize|face|look|wallpaper|icons（--settings-room 仍可用）
    static let demoPage: Picker? = {
        let a = CommandLine.arguments
        if a.contains("--settings-room") { return .room }
        guard let i = a.firstIndex(of: "--settings-page"), i + 1 < a.count else { return nil }
        switch a[i + 1] {
        case "display": return .display
        case "faces": return .faces
        case "home": return .home
        case "sound": return .sound
        case "room": return .room
        case "people": return .people
        case "devices": return .sideshow
        case "sleep": return .choose(.sleep)
        case "textsize": return .choose(.textSize)
        case "face": return .choose(.face)
        case "look": return .choose(.look)
        case "wallpaper": return .choose(.wallpaper)
        case "icons": return .choose(.iconLook)
        default: return nil
        }
    }()

    private func go(_ change: (inout [Picker]) -> Void) {
        let before = stack.count
        change(&stack)
        scroll = 0
        guard stack.count != before, !HPMotion.reduceMotion, !SnapshotPrivacy.active else { return }
        slideDirection = stack.count > before ? 1 : -1
        slide = MotionValue("settings.push", spring: .smooth, from: 0, to: 1, now: CACurrentMediaTime())
    }

    private var snap: HomeSnapshot { HomeApp.demo ? HomeAppModel.demoSnapshot() : HomeLink.shared.snapshot }
    private var rooms: [HomeRoom] {
        let s = snap, home = (s.homes.first(where: \.primary) ?? s.homes.first)?.id
        return s.rooms.filter { home == nil || $0.home == nil || $0.home == home }
    }
    private var hasHome: Bool { HomeApp.demo || (HomeLink.helperInstalled && HomeLink.shared.connected && !rooms.isEmpty) }
    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    // MARK: 輸入

    /// 內容捲動後，畫面上的點對回內容座標（頂端那一列不捲）
    private func contentPoint(_ p: CGPoint) -> CGPoint? {
        p.y >= Self.clipTop ? CGPoint(x: p.x, y: p.y + scroll) : nil
    }
    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard let c = contentPoint(p) else { return false }
        if let s = sliders.first(where: { $0.0.insetBy(dx: -40, dy: -36).contains(c) }) {
            s.1(max(0, min(1, (c.x - s.0.minX) / s.0.width))); face.forceDirty = true
            return true
        }
        guard let h = hits.first(where: { $0.0.contains(c) }) else { return false }
        h.1(); face.forceDirty = true
        return true
    }
    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard maxScroll > 0 else { return false }
        scroll = max(0, min(maxScroll, scroll - dy))
        return true
    }

    // MARK: 畫

    static let clipTop = HPTokens.contentTop - HPGrid.Rhythm.groupGap
    let lf = HPType.sf(34, .regular), vf = HPType.sf(30, .regular), sf = HPType.sf(26, .regular)

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(HPComponents.bg.cgColor); g.fill(rect)
        hits = []; sliders = []
        var y = HPTokens.contentTop
        let k = slide.value(now)
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: Self.clipTop, width: rect.width, height: rect.height - Self.clipTop))
        if k < 0.999 { g.setAlpha(max(0, min(1, k))); g.translateBy(x: (1 - k) * 160 * slideDirection, y: 0) }
        g.translateBy(x: 0, y: -scroll)
        let name: String
        switch stack.last {
        case nil: drawRoot(g, face, y: &y); name = title
        case .display?: drawDisplay(g, face, y: &y); name = L("settings.screen.display", "显示与亮度")
        case .faces?: drawFaces(g, face, y: &y); name = L("settings.screen.faces", "表盘与墙纸")
        case .home?: drawHome(g, face, y: &y); name = L("settings.home.section", "主屏幕")
        case .sound?: drawSound(g, face, y: &y); name = L("settings.screen.sound", "声音")
        case .room?: drawRoomPicker(g, face, y: &y); name = L("settings.screen.room", "这个房间")
        case .people?: drawPeople(g, face, y: &y); name = L("settings.people", "家人")
        case .sharedList?: drawListPicker(g, face, y: &y); name = L("settings.sharedList", "家人共用清单")
        case .sideshow?: drawSideShow(g, face); y = 0; name = L("settings.sideshow", "iPhone 与 iPad")   // SideShow/SideShowSettings.swift
        case .sideshowPair?: drawSideShowPair(g, face, now: now); y = 0; name = L("sideshow.add", "添加设备")
        case .choose(let c)?: name = drawChoice(g, face, c, y: &y)
        }
        g.restoreGState()
        maxScroll = max(0, y + HPGrid.Rhythm.sectionGap - rect.height)
        scroll = min(scroll, maxScroll)
        AppUI.title(g, face, name)
    }

    /// 一列的內容。高度：有副標 120，其餘 96
    struct Row {
        enum Control { case nav(String?), value(String?), toggle(Bool, key: String), slider(CGFloat, set: (CGFloat) -> Void), check(Bool) }
        var title: String
        var subtitle: String? = nil
        var icon: (symbol: String, tint: NSColor)? = nil
        var control: Control
        /// 真的不能用（例如沒有小幫手）才變淡
        var dim = false
        var action: (() -> Void)? = nil
        var height: CGFloat { subtitle == nil ? SettingsApp.row : SettingsApp.rowSub }
    }

    /// 一組：貼內容邊線的分組卡＋裡面的列；畫完 y 往下推一個分組間距
    func group(_ g: CGContext, _ face: Face, _ rows: [Row], y: inout CGFloat) {
        guard !rows.isEmpty else { return }
        let w = Self.x1 - Self.x0
        let card = CGRect(x: Self.x0, y: y, width: w, height: rows.reduce(0) { $0 + $1.height })
        HPComponents.contentCard(g, card)
        var ry = y
        for (i, r) in rows.enumerated() {
            let rr = CGRect(x: Self.x0, y: ry, width: w, height: r.height)
            if i > 0 { HPComponents.separatorLine(g, x: Self.x0 + Self.inset, maxX: Self.x1 - Self.inset, y: ry) }
            draw(g, face, r, in: rr)
            ry += r.height
        }
        y = card.maxY + HPGrid.Rhythm.groupGap
    }

    private func draw(_ g: CGContext, _ face: Face, _ r: Row, in rr: CGRect) {
        var left = rr.minX + Self.inset, right = rr.maxX - Self.inset
        let ink = r.dim ? HPComponents.secondary : HPComponents.label
        if let icon = r.icon {
            let t = CGRect(x: left, y: rr.midY - Self.iconTile / 2, width: Self.iconTile, height: Self.iconTile)
            g.addPath(continuousRoundedRect(t, radius: Self.iconTileRadius)); g.setFillColor(icon.tint.cgColor); g.fillPath()
            face.drawSymbol(g, icon.symbol, in: t.insetBy(dx: 10, dy: 10), color: .white, weight: .medium)
            left = t.maxX + 20
        }
        var axValue: String? = nil, role = HPAXNote.Role.text
        switch r.control {
        case .nav(let v), .value(let v):
            if case .nav = r.control {
                face.drawSymbol(g, "chevron.right", in: CGRect(x: right - 18, y: rr.midY - 15, width: 18, height: 30), color: HPComponents.tertiary, weight: .semibold)
                right -= 30; role = .button
            }
            if let v {
                let t = Face.clipped(v, vf, (right - left) * 0.6)
                face.drawLeft(g, t, font: vf, x: right - Typo.width(t, vf), y: rr.midY + 11, color: HPComponents.secondary)
                right -= Typo.width(t, vf) + 24
            }
            axValue = v
        case .check(let on):
            if on { face.drawSymbol(g, "checkmark", in: CGRect(x: right - 34, y: rr.midY - 16, width: 34, height: 32), color: HPComponents.blue, weight: .semibold) }
            right -= 50; role = .button; axValue = on ? L("a11y.selected", "已选择") : nil
        case .toggle(let on, let key):
            let h = HPTokens.Size.switchTrack - 6, sw = CGRect(x: right - h * 1.7, y: rr.midY - h / 2, width: h * 1.7, height: h)
            HPComponents.toggle(g, sw, on: on, key: key, label: r.title)
            right = sw.minX - 24
        case .slider(let v, let set):
            let x = max(left + Typo.width(r.title, lf) + 32, rr.minX + Self.inset + 130)
            let track = CGRect(x: x, y: rr.midY - 8, width: right - x, height: 16)
            AppUI.fillPill(g, track, color: HPComponents.fill)
            let kx = track.minX + 14 + (track.width - 28) * max(0, min(1, v))   // 旋鈕不超出分組卡
            AppUI.fillPill(g, CGRect(x: track.minX, y: track.minY, width: max(track.height, kx - track.minX), height: track.height), color: HPComponents.label)
            g.saveGState(); HPTokens.Shadow.knob.apply(g)
            g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: kx - 22, y: rr.midY - 22, width: 44, height: 44))
            g.restoreGState()
            sliders.append((track, set))
            right = track.minX - 24; axValue = "\(Int((v * 100).rounded()))%"
        }
        let tw = max(0, right - left)
        if let sub = r.subtitle {
            face.drawLeft(g, Face.clipped(r.title, lf, tw), font: lf, x: left, y: rr.midY - 4, color: ink)
            face.drawLeft(g, Face.clipped(sub, sf, tw), font: sf, x: left, y: rr.midY + 34, color: HPComponents.secondary)
        } else {
            face.drawLeft(g, Face.clipped(r.title, lf, tw), font: lf, x: left, y: rr.midY + 12, color: ink)
        }
        if case .toggle = r.control {} else { HPAX.note(g, rr, r.action == nil ? .text : role, r.title, value: axValue ?? r.subtitle, shape: .rounded(0)) }
        if let a = r.action { hits.append((rr, a)) }
    }

    func header(_ g: CGContext, _ face: Face, _ t: String, y: inout CGFloat) {
        face.drawLeft(g, t, font: sf, x: Self.x0 + Self.inset, y: y + 26, color: HPComponents.secondary)
        y += 40
    }
    /// 分組卡底下的說明：y 進來時已經在卡片下方一個分組間距
    func footnote(_ g: CGContext, _ face: Face, _ t: String, y: inout CGFloat) {
        y -= HPGrid.Rhythm.groupGap - HPGrid.Rhythm.rowGap
        for l in MediaUI.wrap(t, sf, Self.x1 - Self.x0 - 2 * Self.inset, maxLines: 6) {
            face.drawLeft(g, l, font: sf, x: Self.x0 + Self.inset, y: y + 30, color: HPComponents.secondary); y += 34
        }
        y += HPGrid.Rhythm.groupGap
    }
    private func push(_ p: Picker) -> () -> Void { { [weak self] in self?.picking = p } }
    private func redraw() { app?.view?.face.forceDirty = true }

    // MARK: 第一頁

    private func drawRoot(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        func nav(_ t: String, _ symbol: String, _ tint: NSColor, _ p: Picker, value: String? = nil) -> Row {
            Row(title: t, icon: (symbol, tint), control: .nav(value), action: push(p))
        }
        group(g, face, [
            nav(L("settings.screen.display", "显示与亮度"), "sun.max.fill", HPTokens.blue, .display),
            nav(L("settings.screen.faces", "表盘与墙纸"), "clock.fill", srgb(0x2c2c2e), .faces),
            nav(L("settings.home.section", "主屏幕"), "square.grid.2x2.fill", HPTokens.cyan, .home),
            nav(L("settings.screen.sound", "声音"), "speaker.wave.2.fill", HPTokens.pink, .sound),
        ], y: &y)
        var room = nav(L("settings.screen.room", "这个房间"), "door.left.hand.open", HPTokens.orange, .room,
                       value: hasHome ? (HomeThisRoom.room(in: snap)?.name ?? L("settings.room.none", "未设置")) : L("settings.room.needHelper", "需要小帮手"))
        if !hasHome { room.control = .value(L("settings.room.needHelper", "需要小帮手")); room.dim = true; room.action = nil }
        group(g, face, [
            room,
            nav(L("settings.people", "家人"), "person.2.fill", HPTokens.red, .people),
            nav(L("settings.sideshow", "iPhone 与 iPad"), "ipad.and.iphone", HPTokens.teal, .sideshow,
                value: SideShowSettings.on ? L("sideshow.on", "开") : L("sideshow.off", "关")),
        ], y: &y)
        // 其餘回 Mac：一行連過去（不是分組卡）
        let more = L("settings.screen.more", "更多设置在 Mac 上"), mf = HPType.sf(30, .regular)
        let link = CGRect(x: Self.x0, y: y - 33, width: Self.x1 - Self.x0, height: HPTokens.Size.tap)   // 字的基線＝分組卡下緣 + 24 + 22（樣稿）
        face.drawLeft(g, more, font: mf, x: Self.x0 + Self.inset, y: link.midY + 11, color: HPComponents.blue)
        face.drawSymbol(g, "chevron.right", in: CGRect(x: Self.x0 + Self.inset + Typo.width(more, mf) + 10, y: link.midY - 12, width: 14, height: 24), color: HPComponents.blue, weight: .semibold)
        HPAX.note(g, link, .button, more, shape: .rounded(0))
        hits.append((link, {
            guard let app = NSApp.delegate as? AppDelegate else { return }
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowController.show(app: app)
        }))
        y = link.maxY
    }

    // MARK: 顯示與亮度

    private var sleepOptions: [(Double?, String)] {
        [(nil, L("settings.display.auto", "自动")), (20, L("settings.display.20s", "20 秒后")),
         (60, L("settings.display.60s", "60 秒后")), (3600, L("settings.display.never", "永不"))]
    }
    private var textSizes: [String] { [L("settings.textSize.default", "默认"), L("settings.textSize.large", "大"), L("settings.textSize.xlarge", "特大")] }

    private func drawDisplay(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        let sleep = sleepOptions.first { $0.0 == DisplaySettings.sleepAfter }?.1 ?? L("settings.display.auto", "自动")
        group(g, face, [
            // 亮度跟控制中心同一個值；最暗 20%
            Row(title: L("settings.brightness", "亮度"), control: .slider(max(0, min(1, (Shell.brightness - 0.2) / 0.8))) { Shell.brightness = 0.2 + 0.8 * $0 }),
            Row(title: L("settings.screen.autoDim", "自动调暗"), control: .nav(sleep), action: push(.choose(.sleep))),
            Row(title: L("settings.display.ambient", "环境海报"), subtitle: L("settings.screen.ambient.sub", "调暗时只留时间与一张图"),
                control: .toggle(DisplaySettings.ambientEnabled, key: "settings.ambient")) { DisplaySettings.ambientEnabled.toggle() },
        ], y: &y)
        group(g, face, [
            Row(title: L("settings.screen.textSize", "文字大小"), control: .nav(textSizes[HPAccessibilitySettings.textSize]), action: push(.choose(.textSize))),
        ], y: &y)
    }

    // MARK: 錶面與桌布

    private var faceStyle: FaceStyle { app?.view?.face.style ?? .island }

    private func drawFaces(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        group(g, face, [
            Row(title: L("settings.screen.currentFace", "当前的表盘"), control: .nav(faceStyle.title), action: push(.choose(.face))),
            Row(title: L("settings.screen.theme", "主题"), control: .nav(HPLook.name), action: push(.choose(.look))),
            Row(title: L("settings.home.wallpaper", "主屏幕墙纸"),
                control: .nav(HomeWallpaper.photoPath == nil ? L("settings.home.wallpaper.face", "跟着表盘") : L("settings.home.wallpaper.photo", "照片")),
                action: push(.choose(.wallpaper))),
        ], y: &y)
        footnote(g, face, L("settings.screen.faces.note", "要改字体或版式，在表盘上按住。"), y: &y)
    }

    // MARK: 主畫面

    private func drawHome(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        group(g, face, [
            Row(title: L("settings.screen.iconLook", "图标外观"), control: .nav(HomeAppearance.current.title), action: push(.choose(.iconLook))),
            Row(title: L("settings.screen.largeIcons", "大图标"), subtitle: L("settings.screen.largeIcons.sub", "隐藏 App 名称"),
                control: .toggle(SB.largeIcons, key: "settings.largeIcons")) { SB.setLargeIcons(!SB.largeIcons) },
        ], y: &y)
        group(g, face, [
            Row(title: L("settings.screen.phoneApps", "显示 iPhone 上的 App"),
                control: .toggle(PhoneAppProvider.show, key: "settings.phoneApps")) { PhoneAppProvider.setShow(!PhoneAppProvider.show) },
        ], y: &y)
    }

    // MARK: 聲音

    /// CarPlay 通話音量：跟 Mac 設定視窗同一個值（HomePlayCallGainDb，0…15 dB、每 3 dB 一格，預設 +6）
    static let callGainKey = "HomePlayCallGainDb"
    static let callGainMax = 15.0
    static func callGain(fraction f: CGFloat) -> Double { (Double(max(0, min(1, f))) * callGainMax / 3).rounded() * 3 }

    private func drawSound(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        group(g, face, [
            Row(title: L("cc.volume", "音量"), control: .slider(CGFloat(ControlCenter.volume)) { ControlCenter.volume = Float($0); SystemVolume.set(Float($0)) }),
            Row(title: L("settings.screen.speak", "念出 ClioTalk 的回答"),
                control: .toggle(ClioSettings.speak, key: "settings.speak")) { ClioSettings.speak.toggle() },
        ], y: &y)
        // 通話音量只在 iPhone 連著 CarPlay 時出現
        if ControlCenter.carPlayOn || Self.demoCarPlay {
            let db = (UserDefaults.standard.object(forKey: Self.callGainKey) as? Double) ?? 6
            group(g, face, [
                Row(title: L("settings.screen.callVolume", "CarPlay 通话音量"), control: .slider(CGFloat(db / Self.callGainMax)) { [weak self] f in
                    let v = Self.callGain(fraction: f)
                    UserDefaults.standard.set(v, forKey: Self.callGainKey); self?.app?.sendCallGain(v)
                }),
            ], y: &y)
        }
        footnote(g, face, L("settings.screen.sound.note", "通话音量只在 iPhone 连着 CarPlay 时出现。"), y: &y)
    }
    /// 快照：--settings-carplay 假裝 CarPlay 連著（只影響聲音頁那一列）
    static let demoCarPlay = CommandLine.arguments.contains("--settings-carplay")

    // MARK: 這個房間、家人共用清單

    private func drawRoomPicker(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        let cur = HomeThisRoom.room(in: snap)?.id
        var rows = [Row(title: L("settings.room.none", "未设置"), control: .check(cur == nil)) { [weak self] in HomeThisRoom.id = nil; self?.picking = nil }]
        for r in rooms {
            rows.append(Row(title: r.name, control: .check(cur == r.id)) { [weak self] in HomeThisRoom.id = r.id; self?.picking = nil; log("settings room → \(r.id)") })
        }
        group(g, face, rows, y: &y)
        footnote(g, face, L("settings.room.note", "家庭 App 先显示这个房间；对 ClioTalk 说“关灯”只关这里，说“全部”才是整个家。")
                 + " " + L("settings.room.pickNote", "选这台 HomeView 摆放的房间。只存在这台 Mac 上。"), y: &y)
    }

    /// 家人共用清單：提醒事項的清單＋未設定
    private func drawListPicker(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        let cur = RemindersApp.sharedListID
        var rows = [Row(title: L("settings.room.none", "未设置"), control: .check(cur == nil)) { [weak self] in RemindersApp.sharedListID = nil; self?.picking = .people }]
        for l in ReminderSource.shared.lists {
            rows.append(Row(title: l.title, control: .check(cur == l.id)) { [weak self] in
                RemindersApp.sharedListID = l.id; self?.picking = .people; log("settings shared list → \(l.id)")
            })
        }
        group(g, face, rows, y: &y)
        footnote(g, face, L("settings.sharedList.note", "共用清单（例如购物）家人和访客都看得到、都能勾；摆在厨房时打开提醒事项直接是它。")
                 + " " + L("settings.sharedList.pickNote", "这份清单不需要认出主人：家人和访客都能看、能勾。其他清单照旧只给主人。"), y: &y)
    }

    // MARK: 家人

    /// 沒認出主人：只顯示要主人在場的說明（家人、iPhone 與 iPad 兩頁共用）
    func needOwner(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        y += HPGrid.Rhythm.groupGap
        footnote(g, face, L("settings.screen.needOwner", "要这台 Mac 的主人在场才能查看和更改。"), y: &y)
    }

    private func drawPeople(_ g: CGContext, _ face: Face, y: inout CGFloat) {
        guard PersonalGate.allowed else { needOwner(g, face, y: &y); return }
        // 快照不讀這台 Mac 的名冊
        let people = SnapshotPrivacy.active && FamilyProfiles.demo == nil ? FamilyProfiles.demoPeople : FamilyProfiles.roster
        if !people.isEmpty {
            group(g, face, people.map { p in
                Row(title: p.name, control: .value(p.isOwner ? L("settings.screen.owner", "主人") : nil))
            }, y: &y)
        }
        let rs = ReminderSource.shared
        let sharedName = RemindersApp.sharedListID.flatMap { id in rs.lists.first { $0.id == id }?.title } ?? L("settings.room.none", "未设置")
        var shared = Row(title: L("settings.sharedList", "家人共用清单"), control: .nav(sharedName)) { [weak self] in rs.refreshIfNeeded(); self?.picking = .sharedList }
        if !rs.authorized { shared.control = .value(L("settings.sharedList.needAccess", "需要提醒事项")); shared.dim = true; shared.action = nil }
        group(g, face, [
            Row(title: L("people.pane.recognize", "认出谁在看"), subtitle: ControlCenter.followOn ? L("people.pane.recognize.sub", "个人内容只给认出的主人看")
                                                                                         : L("people.pane.recognize.needsFollow", "需要先在「相机」里打开「跟随我」"),
                control: .toggle(WhoIsLooking.recognitionEnabled, key: "settings.recognize")) { WhoIsLooking.recognitionEnabled.toggle() },
            shared,
        ], y: &y)
        footnote(g, face, L("settings.privacy.note", "行事历、提醒事项、讯息、FaceTime、查找只在认出主人时显示。远程访客的设备只能开关灯。")
                 + " " + L("settings.screen.people.note", "添加家人、录制脸部在 Mac 的「设置 › 家人」。"), y: &y)
    }

    // MARK: 挑一個值

    private func drawChoice(_ g: CGContext, _ face: Face, _ c: Choice, y: inout CGFloat) -> String {
        func pick(_ title: String, _ on: Bool, _ apply: @escaping () -> Void) -> Row {
            Row(title: title, control: .check(on)) { [weak self] in apply(); self?.redraw(); _ = self?.handleBack(now: CACurrentMediaTime()) }
        }
        switch c {
        case .sleep:
            group(g, face, sleepOptions.map { o in pick(o.1, DisplaySettings.sleepAfter == o.0) { DisplaySettings.sleepAfter = o.0 } }, y: &y)
            footnote(g, face, L("settings.display.sleep.short", "回到表盘后多久调暗"), y: &y)
            return L("settings.screen.autoDim", "自动调暗")
        case .textSize:
            group(g, face, textSizes.enumerated().map { i, t in pick(t, HPAccessibilitySettings.textSize == i) { HPAccessibilitySettings.textSize = i } }, y: &y)
            footnote(g, face, L("settings.textSize.short", "回答、列表和胶囊跟着变大"), y: &y)
            return L("settings.screen.textSize", "文字大小")
        case .face:
            let cur = faceStyle
            group(g, face, FaceStyle.lineup.map { s in pick(s.title, s == cur) { [weak self] in self?.app?.settingsPerform("menuStyle:", s.rawValue) } }, y: &y)
            return L("settings.screen.currentFace", "当前的表盘")
        case .look:
            let cur = HPLook.name
            group(g, face, HVTruth.looks.map { l in pick(l.name, l.name == cur) { HPLook.select(l.name) } }, y: &y)
            return L("settings.screen.theme", "主题")
        case .wallpaper:
            let first = HomeWallpaper.photos().first?.path, cur = HomeWallpaper.photoPath
            var photo = pick(L("settings.home.wallpaper.photo", "照片"), cur != nil) { if cur == nil { HomeWallpaper.set(first) } }
            if first == nil, cur == nil { photo.dim = true; photo.action = nil }
            group(g, face, [pick(L("settings.home.wallpaper.face", "跟着表盘"), cur == nil) { HomeWallpaper.set(nil) }, photo], y: &y)
            footnote(g, face, first == nil ? L("settings.home.wallpaper.empty", "把照片放进「图片 › HomePlay」文件夹，就能在这里挑。")
                                           : L("settings.screen.wallpaper.note", "要换成别的照片，在 Mac 的「设置」里挑。"), y: &y)
            return L("settings.home.wallpaper", "主屏幕墙纸")
        case .iconLook:
            group(g, face, HomeAppearance.allCases.map { a in pick(a.title, HomeAppearance.current == a) { HomeAppearance.set(a) } }, y: &y)
            footnote(g, face, L("settings.home.appearance.sub", "App 图标和小组件一起换"), y: &y)
            return L("settings.screen.iconLook", "图标外观")
        }
    }
}

// MARK: - 自檢

enum SettingsScreenSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let cards = SettingsApp.rootCards
        check(cards.count == 2 && cards.allSatisfy { $0.minX == HPGrid.Content.leading && $0.maxX == HPGrid.Content.trailing }
              && cards[0].height == 4 * HPTokens.Size.listRow && cards[1].height == 3 * HPTokens.Size.listRow
              && cards[1].minY - cards[0].maxY == HPGrid.Rhythm.groupGap,
              "設定：七項分兩組（4＋3），貼內容邊線 98.5／925.5，列高 96、分組間距 24")   // l10n-ignore
        check(SettingsApp.row == 96 && SettingsApp.rowSub == 120 && abs(SettingsApp.iconTileRadius - 15.5) < 0.5,
              "設定：列 96、有副標 120；列首圖示方塊圓角 15.5（39.5 − 24）")   // l10n-ignore
        let app = SettingsApp()
        app.didOpen(now: 0)
        let wasEmpty = app.stack.isEmpty || SettingsApp.demoPage != nil || SideShowSettings.demoPicker != nil
        app.picking = .display; app.picking = .choose(.sleep)
        let pushed = app.stack == [.display, .choose(.sleep)] && app.backSymbol == "chevron.left"
        let popped = app.handleBack(now: 0) && app.stack == [.display]
        app.picking = .choose(.textSize); app.picking = .display
        let unwound = app.stack == [.display]
        app.picking = nil
        check(wasEmpty && pushed && popped && unwound && app.stack.isEmpty && app.backSymbol == "xmark" && !app.handleBack(now: 0),
              "設定：點了推入下一層、返回退一層、第一頁的圓鈕是 ✕")   // l10n-ignore
        check(SettingsApp.callGain(fraction: 0) == 0 && SettingsApp.callGain(fraction: 0.4) == 6 && SettingsApp.callGain(fraction: 1) == 15,
              "設定：CarPlay 通話音量滑桿對回 0…15 dB、每 3 dB 一格（跟 Mac 設定同一個值）")   // l10n-ignore
    }
}
