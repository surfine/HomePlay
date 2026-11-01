// 2.0 home-1：家庭狀態（提案 docs/plans/homeview-native.html 第 1 批「家庭是主角」）。
//
// HomeKit 使用者最常卡住的三件事——配件無回應、自動化沒觸發、家中樞離線——共同點是看不到原因。這裡把原因攤開：
// - HomeThisRoom：這台 HomeView 在哪個房間（HomePod 的做法：預設只控制自己所在的房間）。
// - HomeActivity：HomePlay 自己記的「家庭動態」（值真的變了才記、可達性的變化也記；只在記憶體，最多 200 筆，不寫檔）。
// - HomeHealth：中樞狀態＋沒有回應的配件（依房間、最後一次回應的時間、可能原因）。純函數，selftest 驗。
// - HomeStatusPage：「家庭狀態」子頁（中樞、沒有回應、自動化、最近動態）。自帶捲動與點擊，HomeApp 只負責接上。
// 自動化：HomeKit 在 Mac 上不提供事件型自動化的上次觸發時間（lastFireDate 已停用），所以只寫「最近一次相關變化」——
// 拿自動化會寫的特性（targets）去對家庭動態；轉成捷徑的自動化看不到會動哪些配件，就照實說。

import AppKit

// MARK: - 這個房間

enum HomeThisRoom {
    static let key = "home.thisRoom"
    /// 快照：--home-room <房間名>
    static let flagName: String? = {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--home-room").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }()
    /// 示範／快照資料時只記在記憶體（示範家的房間 id 不寫進真的偏好設定）
    nonisolated(unsafe) private static var demoID: String?
    private static var demo: Bool { HomeApp.demo || Face.demoData }
    static var id: String? {
        get { demo ? demoID : UserDefaults.standard.string(forKey: key) }
        set {
            if demo { demoID = newValue; return }
            if let v = newValue { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    static func room(in s: HomeSnapshot) -> HomeRoom? {
        if let n = flagName { return s.rooms.first { $0.name == n } }
        guard let id else { return nil }
        return s.rooms.first { $0.id == id }
    }
    static func name(in s: HomeSnapshot) -> String? { room(in: s)?.name }
    /// 目前的家（示範或小幫手）裡這台所在房間的名字
    static var currentName: String? { name(in: HomeApp.demo ? HomeAppModel.demoSnapshot() : HomeLink.shared.snapshot) }
    /// 2.0 home-2：這台擺在廚房（打開提醒事項直接到家人共用清單）
    static var isKitchen: Bool {
        guard let n = currentName?.lowercased() else { return false }
        return ["厨房", "廚房", "kitchen", "キッチン"].contains { n.contains($0) }   // l10n-ignore：比對用詞
    }
}

// MARK: - 家庭動態

struct HomeEvent: Equatable {
    var time: Date
    var accessory: String
    var name: String
    var room: String
    var characteristic: String?
    var text: String
    var problem = false
}

final class HomeActivity {
    nonisolated(unsafe) static let shared = HomeActivity()
    static let limit = 200
    /// 新的在前
    private(set) var events: [HomeEvent] = []
    /// 配件最後一次「有回應」的時刻（HomePlay 開著時看到的）
    private(set) var lastSeen: [String: Date] = [:]

    func reset() { events = []; lastSeen = [:] }

    private func add(_ e: HomeEvent) {
        events.insert(e, at: 0)
        if events.count > Self.limit { events.removeLast(events.count - Self.limit) }
    }
    private static func roomName(_ a: HomeAccessory, _ s: HomeSnapshot) -> String { a.room.flatMap { r in s.rooms.first { $0.id == r }?.name } ?? "" }

    /// 新快照：記下可達性的變化（第一份快照只建立基準，不記）
    func note(old: HomeSnapshot, new: HomeSnapshot, now: Date) {
        let before = Dictionary(old.accessories.map { ($0.id, $0.reachable) }, uniquingKeysWith: { a, _ in a })
        for a in new.accessories {
            if a.reachable { lastSeen[a.id] = now }
            guard let was = before[a.id], was != a.reachable else { continue }
            add(HomeEvent(time: now, accessory: a.id, name: a.name, room: Self.roomName(a, new), characteristic: nil,
                          text: a.reachable ? L("home.ev.back", "恢复回应") : L("home.ev.lost", "没有回应"), problem: !a.reachable))
        }
    }

    /// 一個特性的新值：跟本機快照裡的舊值不同才記（重連後幫手會整批重讀，值沒變的不算）
    func note(_ ch: HomeChange, in s: HomeSnapshot, now: Date) {
        guard let a = s.accessories.first(where: { $0.id == ch.accessory }),
              let c = a.characteristics.first(where: { $0.id == ch.characteristic }) else { return }
        if ch.type != "doorbell" { guard let old = c.value, old != ch.value else { return } }
        guard let text = Self.describe(type: ch.type, value: ch.value) else { return }
        lastSeen[a.id] = now
        add(HomeEvent(time: now, accessory: a.id, name: a.name, room: Self.roomName(a, s), characteristic: ch.characteristic, text: text))
    }

    /// 一個值怎麼念；nil＝不記（目前溫度、濕度、電量這類一直在跳的）
    static func describe(type: String, value v: HomeValue?) -> String? {
        let n = v?.number, on = v?.isOn
        switch type {
        case "power", "active": return on.map { $0 ? L("home.ev.on", "打开") : L("home.ev.off", "关闭") }
        case "brightness": return n.map { String(format: L("home.ev.brightness", "亮度 %d%%"), Int($0.rounded())) }
        case "lockCurrent":
            switch n.map(Int.init) {
            case 0?: return L("home.lock.unlocked", "已开锁")
            case 1?: return L("home.lock.locked", "已上锁")
            case 2?: return L("home.lock.jammed", "卡住了")
            default: return nil
            }
        case "contact": return n.map { $0 == 0 ? L("home.ev.closed", "关上") : L("home.ev.opened", "打开了") }   // HomeKit：0＝偵測到接觸＝關著
        case "motion": return on == true ? L("home.ev.motion", "侦测到动作") : nil
        case "occupancy": return n == 1 ? L("home.ev.occupied", "有人") : nil
        case "doorState":
            switch n.map(Int.init) {
            case 0?: return L("home.ev.opened", "打开了")
            case 1?: return L("home.ev.closed", "关上")
            default: return nil
            }
        case "targetTemp": return n.map { String(format: L("home.ev.setTemp", "设为 %@"), HomeAppModel.tempText($0)) }
        case "currentPosition": return n.map { String(format: L("home.ev.position", "开到 %d%%"), Int($0.rounded())) }
        case "doorbell": return L("home.ev.doorbell", "有人按门铃")
        default: return nil
        }
    }

    /// 自動化會寫的那些特性，最近一次在家庭動態裡出現的時刻
    func lastRelated(_ a: HomeAutomation) -> Date? {
        let t = Set(a.targets ?? [])
        guard !t.isEmpty else { return nil }
        return events.first { $0.characteristic.map(t.contains) ?? false }?.time
    }

    /// 快照用的示範動態（--demo-home）
    func seedDemo(_ s: HomeSnapshot, now: Date) {
        reset()
        for a in s.accessories { if a.reachable { lastSeen[a.id] = now } }
        let rows: [(Double, String, String)] = [(1800, "a10", L("home.ev.on", "打开")), (1500, "a9", L("home.lock.locked", "已上锁")),
                                                (900, "a20", L("home.ev.lost", "没有回应")), (240, "a2", String(format: L("home.ev.brightness", "亮度 %d%%"), 60))]
        for (ago, id, text) in rows {
            guard let a = s.accessories.first(where: { $0.id == id }) else { continue }
            add(HomeEvent(time: now.addingTimeInterval(-ago), accessory: id, name: a.name, room: Self.roomName(a, s),
                          characteristic: a.characteristics.first?.id, text: text, problem: id == "a20"))
        }
        lastSeen["a20"] = now.addingTimeInterval(-900)
    }
}

// MARK: - 健康

struct HomeHealth: Equatable {
    struct Issue: Equatable { var id: String; var name: String; var room: String; var lastSeen: Date? }
    var hub: String?
    var issues: [Issue]
    /// 兩個以上配件、而且全部沒回應的房間（多半是那裡的電源或網路）
    var deadRooms: [String]
    var ok: Bool { issues.isEmpty && hub != "disconnected" }

    static func make(_ s: HomeSnapshot, lastSeen: [String: Date]) -> HomeHealth {
        let home = s.homes.first(where: \.primary) ?? s.homes.first
        let accs = s.accessories.filter { home == nil || $0.home == nil || $0.home == home?.id }
        let rooms = Dictionary(s.rooms.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let issues = accs.filter { !$0.reachable }.map { a in
            Issue(id: a.id, name: a.name, room: a.room.flatMap { rooms[$0] } ?? "", lastSeen: lastSeen[a.id])
        }.sorted { ($0.room, $0.name) < ($1.room, $1.name) }
        var dead: [String] = []
        for (rid, name) in rooms {
            let inRoom = accs.filter { $0.room == rid }
            if inRoom.count >= 2, inRoom.allSatisfy({ !$0.reachable }) { dead.append(name) }
        }
        return HomeHealth(hub: home?.hub, issues: issues, deadRooms: dead.sorted())
    }

}

/// 遠看的一句話（提案原則 1）：這個房間（沒設就整個家）現在怎樣
struct HomeFarSummary: Equatable {
    var title: String
    var headline: String
    var details: [String]
    var issues: Int

    static func make(_ s: HomeSnapshot, thisRoom: HomeRoom?, health: HomeHealth) -> HomeFarSummary {
        let all = HomeAppModel.groups(s).flatMap(\.tiles)
        let scope = thisRoom.map { r in all.filter { $0.room == r.id } } ?? all
        let lights = scope.filter { $0.kind == .light && $0.reachable }
        let on = lights.filter(\.on).count
        let headline = lights.isEmpty ? L("home.far.noLights", "没有灯") : (on == 0 ? L("home.far.lightsOff", "灯都关了")
            : (on == 1 ? L("home.far.oneLight", "1 盏灯亮着") : String(format: L("home.far.lights", "%d 盏灯亮着"), on)))
        var details: [String] = []
        if let t = scope.first(where: { $0.kind == .thermostat && $0.temp != nil })?.temp ?? all.first(where: { $0.kind == .thermostat && $0.temp != nil })?.temp {
            details.append(HomeAppModel.tempText(t))
        }
        let locks = all.filter { $0.kind == .lock && $0.reachable }
        if !locks.isEmpty { details.append(locks.allSatisfy { $0.locked == true } ? L("home.far.locked", "门已上锁") : L("home.far.unlocked", "门没锁")) }
        return HomeFarSummary(title: thisRoom?.name ?? HomeAppModel.homeName(s), headline: headline, details: details, issues: health.issues.count)
    }
}

enum HomeStatusText {
    /// 「剛剛／N 分鐘前／N 小時前／昨天 21:40」
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return L("home.ago.now", "刚刚") }
        if s < 3600 { return String(format: L("home.ago.min", "%d 分钟前"), Int(s / 60)) }
        if s < 6 * 3600 { return String(format: L("home.ago.hour", "%d 小时前"), Int(s / 3600)) }
        return Face.shortTime(d)
    }
    /// 觸發短碼 → 一句話
    static func when(_ codes: [String]) -> String {
        let parts = codes.map { c -> String in
            if c.hasPrefix("accessory:") { let n = String(c.dropFirst(10)); return n.isEmpty ? L("home.when.accessory0", "配件状态改变时") : String(format: L("home.when.accessory", "“%@”改变时"), n) }
            switch c {
            case "sunrise": return L("home.when.sunrise", "日出时")
            case "sunset": return L("home.when.sunset", "日落时")
            case "arrive": return L("home.when.arrive", "有人到家时")
            case "leave": return L("home.when.leave", "最后一个人离家时")
            case "location": return L("home.when.location", "到达或离开某个地点时")
            case "time": return L("home.when.time", "在设定的时间")
            default: return L("home.when.other", "其他条件")
            }
        }
        return parts.isEmpty ? L("home.when.other", "其他条件") : parts.joined(separator: L("home.when.or", "，或"))
    }
}

// MARK: - 「家庭狀態」子頁

struct HomeStatusPage {
    enum Action: Equatable { case toggle(String, Bool), openHome }
    var scroll: CGFloat = 0
    private(set) var contentH: CGFloat = 0
    private(set) var hits: [(CGRect, Action)] = []

    static let x0 = HPGrid.App.leading, x1 = HPGrid.App.trailing
    static let row = HPTokens.Size.row
    /// 兩行的列（自動化：名稱＋條件／最近變化）用助理膠囊列的兩行高（HPTokens.Assistant.rowHeight2）
    static let row2: CGFloat = 135
    static let inset = HPGrid.Inset.card

    mutating func scroll(by dy: CGFloat) -> Bool {
        let old = scroll
        scroll = max(0, min(max(0, contentH - (1024 - HPTokens.contentTop)), scroll - dy * 1.6))
        return old != scroll
    }

    func tap(_ p: CGPoint) -> Action? { hits.first { $0.0.contains(p) }?.1 }

    mutating func draw(_ g: CGContext, _ face: Face, snapshot s: HomeSnapshot, now: Date, owner: Bool) {
        hits = []
        g.setFillColor(HPComponents.bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let health = HomeHealth.make(s, lastSeen: HomeActivity.shared.lastSeen)
        let top = HPTokens.contentTop
        var y = top - scroll
        let lf = HPType.sf(42, .regular), sf = HPType.sf(30, .regular), hf = HPType.sf(30, .semibold)
        let label = HPComponents.label, sec = HPComponents.secondary
        g.saveGState(); g.clip(to: CGRect(x: 0, y: top - 24, width: 1024, height: 1024))

        func header(_ t: String) {
            face.drawLeft(g, t, font: hf, x: Self.x0 + Self.inset, y: y + 40, color: sec)
            y += 56
        }
        func footnote(_ t: String) {
            for l in MediaUI.wrap(t, sf, Self.x1 - Self.x0 - 2 * Self.inset, maxLines: 6) {
                face.drawLeft(g, l, font: sf, x: Self.x0 + Self.inset, y: y + 38, color: sec); y += 40
            }
            y += 8
        }
        /// 一張分組卡：rows 是 (高度, 畫法)
        func card(_ rows: [(CGFloat, (CGRect) -> Void)]) {
            let h = rows.reduce(0) { $0 + $1.0 }
            HPComponents.groupCard(g, CGRect(x: Self.x0, y: y, width: Self.x1 - Self.x0, height: h))
            var ry = y
            for (i, r) in rows.enumerated() {
                let rr = CGRect(x: Self.x0, y: ry, width: Self.x1 - Self.x0, height: r.0)
                r.1(rr)
                if i < rows.count - 1 { HPComponents.separatorLine(g, x: Self.x0 + Self.inset, maxX: Self.x1, y: ry + r.0) }
                ry += r.0
            }
            y = ry + HPGrid.Rhythm.sectionGap
        }
        func oneLine(_ r: CGRect, _ title: String, _ trailing: String?, dot: NSColor? = nil) {
            var x = r.minX + Self.inset
            if let dot { g.setFillColor(dot.cgColor); g.fillEllipse(in: CGRect(x: x, y: r.midY - 9, width: 18, height: 18)); x += 34 }
            let tw = trailing.map { Typo.width($0, sf) + 16 } ?? 0
            face.drawLeft(g, Face.clipped(title, lf, r.maxX - Self.inset - tw - x), font: lf, x: x, y: r.midY + 15, color: label)
            if let t = trailing { face.drawLeft(g, t, font: sf, x: r.maxX - Self.inset - Typo.width(t, sf), y: r.midY + 11, color: sec) }
            HPAX.note(g, r, .text, trailing.map { String(format: L("a11y.pair", "%1$@，%2$@"), title, $0) } ?? title, shape: .rounded(0))
        }

        // 中樞
        header(L("home.status.hub", "家庭中枢"))
        let hubText: (String, NSColor) = {
            switch health.hub {
            case "connected": return (L("home.hub.ok", "已连接，自动化正常运行"), HPComponents.green)
            case "disconnected": return (L("home.hub.off", "离线：自动化不会运行，离家时也控制不了"), HPComponents.orange)
            case "notAvailable": return (L("home.hub.none", "这个家没有家庭中枢"), HPComponents.orange)
            default: return (L("home.hub.unknown", "小帮手没有提供中枢状态"), HPTokens.tertiary)
            }
        }()
        card([(Self.row, { r in oneLine(r, hubText.0, nil, dot: hubText.1) })])
        if health.hub == "disconnected" || health.hub == "notAvailable" {
            y -= HPGrid.Rhythm.sectionGap - HPGrid.Rhythm.rowGap
            footnote(L("home.hub.help", "家庭中枢是一直开着的 Apple TV 或 HomePod。检查它有没有断电、睡眠或断网。"))
            y += HPGrid.Rhythm.groupGap
        }

        // 沒有回應：每列「名稱／最後回應」，原因寫在卡片底下（同一個原因不用每列重複）
        if !health.issues.isEmpty {
            header(String(format: L("home.status.noResponse", "没有回应（%d）"), health.issues.count))
            card(health.issues.map { i in (Self.row2, { r in
                let x = r.minX + Self.inset, w = r.width - 2 * Self.inset
                let name = HomeAppModel.shortName(i.name, room: i.room)
                let seen = i.lastSeen.map { String(format: L("home.status.lastSeen", "最后回应：%@"), HomeStatusText.ago($0, now: now)) } ?? L("home.status.neverSeen", "HomePlay 打开后一直没有回应")
                let tf = HPType.sf(42, .regular)
                face.drawLeft(g, Face.clipped(i.room.isEmpty ? name : "\(i.room) · \(name)", tf, w), font: tf, x: x, y: r.minY + 58, color: label)
                face.drawLeft(g, Face.clipped(seen, sf, w), font: sf, x: x, y: r.minY + 104, color: sec)
                HPAX.note(g, r, .text, "\(i.room) \(name)，\(seen)", shape: .rounded(0))
            }) })
            y -= HPGrid.Rhythm.sectionGap - HPGrid.Rhythm.rowGap
            var why: [String] = []
            if health.hub == "disconnected" { why.append(L("home.hint.hub", "家庭中枢离线时，远程的配件都会这样")) }
            for room in health.deadRooms { why.append(String(format: L("home.hint.room", "“%@”整个房间都没回应：多半是那里的电源或网络"), room)) }
            if why.isEmpty || health.issues.contains(where: { !health.deadRooms.contains($0.room) }) {
                why.append(L("home.hint.one", "单独一个没回应：多半是断电，或离 Wi‑Fi／Thread 太远。先把它断电 10 秒再接回。"))
            }
            footnote(why.joined(separator: " "))
            y += HPGrid.Rhythm.groupGap
        }

        // 自動化（主人才看得到、改得到）
        let autos = (s.automations ?? []).filter { a in let h = (s.homes.first(where: \.primary) ?? s.homes.first)?.id; return h == nil || a.home == nil || a.home == h }
        if owner, !autos.isEmpty {
            header(String(format: L("home.status.autos", "自动化（%d）"), autos.count))
            card(autos.map { a in (Self.row2, { r in
                let x = r.minX + Self.inset
                let sw = CGRect(x: r.maxX - Self.inset - 108, y: r.midY - HPTokens.Size.switchTrack / 2, width: 108, height: HPTokens.Size.switchTrack)
                let tw = r.width - 2 * Self.inset - 108 - 24
                let tf = HPType.sf(42, .regular)
                face.drawLeft(g, Face.clipped(a.name, tf, tw), font: tf, x: x, y: r.minY + 58, color: a.enabled ? label : sec)
                let related = HomeActivity.shared.lastRelated(a).map { String(format: L("home.auto.related", "最近一次相关变化：%@"), HomeStatusText.ago($0, now: now)) }
                let second = (a.targets ?? []).isEmpty ? L("home.auto.shortcut", "用快捷指令运行，看不到会动哪些配件") : (related ?? L("home.auto.noRelated", "HomePlay 打开后还没看到它会动的配件变化"))
                face.drawLeft(g, Face.clipped("\(HomeStatusText.when(a.when ?? [])) · \(second)", sf, tw), font: sf, x: x, y: r.minY + 104, color: sec)
                HPComponents.toggle(g, sw, on: a.enabled, key: "auto.\(a.id)", label: a.name)
            }) })
            // 開關的點按範圍：整列右側補到 88 高（畫的時候 hits 收不進閉包，這裡照同一套幾何補）
            var hy = y - HPGrid.Rhythm.sectionGap - CGFloat(autos.count) * Self.row2
            for a in autos {
                hits.append((CGRect(x: Self.x1 - Self.inset - 108 - 20, y: hy + (Self.row2 - HPTokens.Size.tap) / 2, width: 108 + 40, height: HPTokens.Size.tap), .toggle(a.id, !a.enabled)))
                hy += Self.row2
            }
            y -= HPGrid.Rhythm.sectionGap - HPGrid.Rhythm.rowGap
            footnote(L("home.auto.note", "HomeKit 不提供自动化的运行记录。这里对照 HomePlay 自己看到的配件变化，可能是这则自动化，也可能是有人手动操作。"))
            y += HPGrid.Rhythm.groupGap
        }

        // 最近動態（主人才看得到：誰在什麼時候開了哪扇門是家裡的事）
        if owner {
            header(L("home.status.activity", "最近动态"))
            let evs = Array(HomeActivity.shared.events.prefix(30))
            if evs.isEmpty {
                card([(Self.row, { r in oneLine(r, L("home.activity.empty", "HomePlay 打开后还没有配件变化"), nil) })])
            } else {
                card(evs.map { e in (Self.row, { r in
                    oneLine(r, e.room.isEmpty ? "\(e.name) · \(e.text)" : "\(e.room) \(e.name) · \(e.text)", HomeStatusText.ago(e.time, now: now), dot: e.problem ? HPComponents.orange : nil)
                }) })
            }
            y -= HPGrid.Rhythm.sectionGap - HPGrid.Rhythm.rowGap
            footnote(L("home.activity.note", "只记在这台 Mac 的内存里，关掉 HomePlay 就清空，不上传。"))
            y += HPGrid.Rhythm.groupGap
        }

        // 交給 Mac 的「家庭」
        let b = CGRect(x: 512 - HPTokens.Size.pairedButton.width / 2, y: y, width: HPTokens.Size.pairedButton.width, height: HPTokens.Size.pill)
        HPComponents.glassButton(g, face, b, L("home.openApple.short", "在 Mac 上打开“家庭”"), symbol: "homekit")
        hits.append((b, .openHome))
        y += HPTokens.Size.pill + HPGrid.Rhythm.sectionGap
        g.restoreGState()
        contentH = y + scroll - top
        if scroll > 0 { HPComponents.topFade(g, HPComponents.bg, solidTo: top - 24) }
    }
}

// MARK: - 自檢（HomeAppSelfTest.run 叫）

enum HomeStatusSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let demo = HomeAppModel.demoSnapshot()
        // 健康：示範家有一盞連不上的台燈；中樞連著
        let h = HomeHealth.make(demo, lastSeen: [:])
        check(h.hub == "connected" && h.issues.map(\.id) == ["a20"] && h.deadRooms.isEmpty && !h.ok, "家庭狀態：示範家一盞燈沒回應、中樞連著")   // l10n-ignore：selftest 訊息
        // 整個房間都沒回應（兩個以上）＝電源或網路；中樞離線＝不 ok
        var dark = demo
        for i in dark.accessories.indices where dark.accessories[i].room == "r3" { dark.accessories[i].reachable = false }
        dark.homes[0].hub = "disconnected"
        let hd = HomeHealth.make(dark, lastSeen: [:])
        check(hd.deadRooms == [L("home.demo.entry", "玄关")] && hd.hub == "disconnected" && !hd.ok, "家庭狀態：玄關整間沒回應、中樞離線")   // l10n-ignore：selftest 訊息
        // 動態：值沒變不記；變了才記；可達性變化記一筆；第一份快照不記
        let log = HomeActivity()
        log.note(old: .empty, new: demo, now: Date(timeIntervalSince1970: 0))
        check(log.events.isEmpty && log.lastSeen["a2"] != nil && log.lastSeen["a20"] == nil, "家庭動態：第一份快照只建基準")   // l10n-ignore：selftest 訊息
        log.note(HomeChange(accessory: "a2", characteristic: "c2a", type: "power", value: HomeValue(bool: true)), in: demo, now: Date(timeIntervalSince1970: 10))
        check(log.events.isEmpty, "家庭動態：重讀到一樣的值不記")   // l10n-ignore：selftest 訊息
        log.note(HomeChange(accessory: "a2", characteristic: "c2a", type: "power", value: HomeValue(bool: false)), in: demo, now: Date(timeIntervalSince1970: 20))
        log.note(HomeChange(accessory: "a7", characteristic: "c7a", type: "humidity", value: HomeValue(number: 70)), in: demo, now: Date(timeIntervalSince1970: 30))
        check(log.events.count == 1 && log.events[0].text == L("home.ev.off", "关闭"), "家庭動態：關燈記一筆、濕度跳動不記")   // l10n-ignore：selftest 訊息
        var lost = demo; lost.accessories[1].reachable = false
        log.note(old: demo, new: lost, now: Date(timeIntervalSince1970: 40))
        check(log.events.first?.problem == true && log.events.first?.accessory == lost.accessories[1].id, "家庭動態：配件沒回應記一筆（標成問題）")   // l10n-ignore：selftest 訊息
        let auto = HomeAutomation(id: "t", name: "t", home: "h1", enabled: true, kind: "event", targets: ["c2a"], when: ["sunset"])
        check(log.lastRelated(auto) == Date(timeIntervalSince1970: 20) && log.lastRelated(HomeAutomation(id: "u", name: "u", enabled: true, targets: [])) == nil,
              "家庭動態：自動化的「最近一次相關變化」照它會寫的特性對")   // l10n-ignore：selftest 訊息
        // 遠看：示範家整個家 7 盞燈裡亮著的數量、溫度、門鎖
        let far = HomeFarSummary.make(demo, thisRoom: demo.rooms.first { $0.id == "r3" }, health: h)
        check(far.headline == L("home.far.oneLight", "1 盏灯亮着") && far.details.contains(L("home.far.locked", "门已上锁")) && far.issues == 1, "家庭遠看：玄關一盞燈亮、門已上鎖、一個沒回應")   // l10n-ignore：selftest 訊息
        // ClioTalk：只說「關燈」＝這個房間的燈（不反問）；說「全部」＝整個家
        typealias C = ClioHomeControl
        let cands = [C.Candidate(id: "1", name: "落地灯", room: "客厅", kind: .light, category: "Lightbulb"),   // l10n-ignore：自檢
                     C.Candidate(id: "2", name: "床头灯", room: "卧室", kind: .light, category: "Lightbulb"),   // l10n-ignore：自檢
                     C.Candidate(id: "3", name: "台灯", room: "卧室", kind: .light, category: "Lightbulb")]   // l10n-ignore：自檢
        let here = C.resolve("灯", action: .off, in: cands, rooms: ["客厅", "卧室"], thisRoom: "卧室")   // l10n-ignore：自檢
        let away = C.resolve("灯", action: .off, in: cands, rooms: ["客厅", "卧室"])   // l10n-ignore：自檢
        let all = C.resolve("全部的灯", action: .off, in: cands, rooms: ["客厅", "卧室"], thisRoom: "卧室")   // l10n-ignore：自檢
        check(here == .found([cands[1], cands[2]]) && away == .ambiguous(cands) && all == .found(cands), "ClioTalk：只說「關燈」關這個房間；沒設房間照舊反問；說全部才全屋")
        // 2.0 home-2：提醒加到哪一份清單——名字對得到就用；說「購物／grocery」退到家人共用清單；都不像就交回預設
        let titles = ["Reminders", "工作", "Family"]   // l10n-ignore：自檢
        check(ClioToolCatalog.reminderListIndex(named: "工作", titles: titles, sharedIndex: 2) == 1
              && ClioToolCatalog.reminderListIndex(named: "grocery list", titles: titles, sharedIndex: 2) == 2
              && ClioToolCatalog.reminderListIndex(named: "something", titles: titles, sharedIndex: 2) == nil, "ClioTalk：提醒加到說的清單；購物退到共用清單")   // l10n-ignore：selftest 訊息   // l10n-ignore：selftest 訊息
    }
}
