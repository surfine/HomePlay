// 提醒事项 App：四張智慧清單（今天、已排程、全部、已完成）＋各清單與未完成數；點進去看項目，點左邊的圓圈完成（直接寫回 EventKit——
// 這是使用者自己的動作，不用經過 ClioTalk 的「念出來等好」）。新增提醒是 ClioTalk 的工作（reminders_add），這裡不新增。
// 沒授權＝說明卡＋按鈕（提醒事項沒有 PermissionKind，這裡自己走 EventKit 的授權；打包後的 App 有用途說明才會真的問）。
// 開了「認出誰在看」而眼前不是主人：換成「需要主人」鎖卡。

import AppKit
import EventKit

// MARK: - 純邏輯（--selftest 直接驗）

struct ReminderItem: Equatable {
    var id: String
    var title: String
    var due: Date?
    var hasTime: Bool
    var listID: String
    var completed: Bool
}
struct ReminderList: Equatable {
    var id: String
    var title: String
    var color: UInt32
}

enum ReminderSmart: Equatable { case today, scheduled, all, completed }

enum ReminderLogic {
    /// 今天（含已逾期）：未完成、有到期日、到期日在明天 0 點之前
    static func inToday(_ r: ReminderItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard !r.completed, let d = r.due, let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return false }
        return d < tomorrow
    }
    static func matches(_ r: ReminderItem, _ s: ReminderSmart, now: Date, calendar: Calendar = .current) -> Bool {
        switch s {
        case .today: return inToday(r, now: now, calendar: calendar)
        case .scheduled: return !r.completed && r.due != nil
        case .all: return !r.completed
        case .completed: return r.completed
        }
    }
    static func count(_ items: [ReminderItem], _ s: ReminderSmart, now: Date, calendar: Calendar = .current) -> Int {
        items.filter { matches($0, s, now: now, calendar: calendar) }.count
    }
    /// 某個清單的未完成數
    static func count(_ items: [ReminderItem], list: String) -> Int { items.filter { $0.listID == list && !$0.completed }.count }
    /// 排序：有到期日的在前（早的先），沒有的在後，同樣的照標題
    static func sorted(_ items: [ReminderItem]) -> [ReminderItem] {
        items.sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): return a != b ? a < b : $0.title < $1.title
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title < $1.title
            }
        }
    }
    static func isOverdue(_ r: ReminderItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard !r.completed, let d = r.due else { return false }
        return r.hasTime ? d < now : d < calendar.startOfDay(for: now)
    }
}

// MARK: - 資料

final class ReminderSource {
    static let shared = ReminderSource()
    static let usageKey = "NSRemindersFullAccessUsageDescription"
    private let store = EKEventStore()
    private var ek: [String: EKReminder] = [:]
    private(set) var items: [ReminderItem] = []
    private(set) var lists: [ReminderList] = []
    private(set) var version = 0
    private var fetching = false
    private var lastFetch = Date.distantPast
    private var observer: NSObjectProtocol?
    /// 剛點完成的：先顯示打勾，一小段時間後才從清單消失
    private(set) var justChanged: [String: Double] = [:]
    let demo = AppUI.demoReminders

    static var auth: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    var authorized: Bool { demo || Self.auth == .fullAccess }
    var denied: Bool { !demo && ![.notDetermined, .fullAccess].contains(Self.auth) }

    init() {
        if demo { (items, lists) = Self.demoData(now: Face.displayDate) }
        else {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.lastFetch = .distantPast; self?.version += 1
            }
        }
    }

    func requestAccess(then: @escaping () -> Void) {
        guard Self.auth == .notDetermined, Bundle.main.object(forInfoDictionaryKey: Self.usageKey) != nil else {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(u) }
            return
        }
        store.requestFullAccessToReminders { _, _ in DispatchQueue.main.async { self.lastFetch = .distantPast; self.version += 1; then() } }
    }

    /// 讀到過一次（示範資料一開始就算）
    private(set) lazy var everLoaded = demo
    func refreshIfNeeded() {
        guard authorized, !demo, !fetching, Date().timeIntervalSince(lastFetch) > 60 else { return }
        fetching = true
        let store = store
        let lists: [ReminderList] = store.calendars(for: .reminder).map { c in
            var hex: UInt32 = 0xff9500
            if let ns = NSColor(cgColor: c.cgColor)?.usingColorSpace(.sRGB) {
                hex = UInt32(ns.redComponent * 255) << 16 | UInt32(ns.greenComponent * 255) << 8 | UInt32(ns.blueComponent * 255)
            }
            return ReminderList(id: c.calendarIdentifier, title: c.title, color: hex)
        }
        let incomplete = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-7 * 86400), ending: Date(), calendars: nil)
        store.fetchReminders(matching: incomplete) { [weak self] open in
            store.fetchReminders(matching: done) { closed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    var map: [String: EKReminder] = [:], out: [ReminderItem] = []
                    for r in (open ?? []) + (closed ?? []) {
                        let id = r.calendarItemIdentifier
                        map[id] = r
                        let comps = r.dueDateComponents
                        out.append(ReminderItem(id: id, title: r.title ?? "", due: comps.flatMap { Calendar.current.date(from: $0) },
                                                hasTime: comps?.hour != nil, listID: r.calendar?.calendarIdentifier ?? "", completed: r.isCompleted))
                    }
                    self.ek = map; self.items = out; self.lists = lists; self.everLoaded = true
                    self.fetching = false; self.lastFetch = Date(); self.version += 1
                }
            }
        }
    }

    /// 點圓圈：完成／取消完成，寫回 EventKit。成功回 true
    @discardableResult
    func toggle(_ id: String, now: Double) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        let want = !items[i].completed
        if !demo {
            guard let r = ek[id] else { return false }
            r.isCompleted = want
            do { try store.save(r, commit: true) } catch { log("reminder save failed"); return false }
        }
        items[i].completed = want
        justChanged[id] = now
        version += 1
        return true
    }
    func expireChanges(now: Double) -> Bool {
        let n = justChanged.count
        justChanged = justChanged.filter { now - $0.value < 0.9 }
        return n != justChanged.count
    }

    static func demoData(now: Date, calendar: Calendar = .current) -> ([ReminderItem], [ReminderList]) {
        func at(_ off: Int, _ h: Int?) -> Date {
            let d = calendar.date(byAdding: .day, value: off, to: calendar.startOfDay(for: now)) ?? now
            return h.flatMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: d) } ?? d
        }
        let lists = [ReminderList(id: "l1", title: L("reminders.demo.list1", "提醒事项"), color: 0xff9500),
                     ReminderList(id: "l2", title: L("calendar.demo.work", "工作"), color: 0x0a84ff),
                     ReminderList(id: "l3", title: L("reminders.demo.list3", "购物"), color: 0x30d158),
                     ReminderList(id: "l4", title: L("calendar.demo.home", "家庭"), color: 0xbf5af2)]
        func r(_ id: String, _ t: String, _ due: Date?, time: Bool, _ list: String, done: Bool = false) -> ReminderItem {
            ReminderItem(id: id, title: t, due: due, hasTime: time, listID: list, completed: done)
        }
        let items = [
            r("r1", L("reminders.demo.gift", "买 B 的生日礼物"), at(0, 18), time: true, "l1"),
            r("r2", L("reminders.demo.bill", "缴电费"), at(-1, nil), time: false, "l1"),
            r("r3", L("reminders.demo.report", "交周报"), at(0, 17), time: true, "l2"),
            r("r4", L("reminders.demo.milk", "牛奶、鸡蛋、吐司"), at(0, nil), time: false, "l3"),
            r("r5", L("reminders.demo.dentist", "预约牙医"), at(2, 10), time: true, "l1"),
            r("r6", L("reminders.demo.slides", "整理设计评审的稿子"), at(3, 9), time: true, "l2"),
            r("r7", L("reminders.demo.plants", "给植物浇水"), at(4, nil), time: false, "l4"),
            r("r8", L("reminders.demo.cake", "订蛋糕"), nil, time: false, "l3"),
            r("r9", L("reminders.demo.read", "读完那本书"), nil, time: false, "l1"),
            r("r10", L("reminders.demo.call", "打给妈妈"), at(-2, 12), time: true, "l4", done: true),
            r("r11", L("reminders.demo.trash", "倒垃圾"), at(-1, 20), time: true, "l4", done: true),
        ]
        return (items, lists)
    }
}

// MARK: - App 畫面

final class RemindersApp: PetApp {
    static let shared = RemindersApp()
    let id = "reminders"
    var title: String { L("app.reminders", "提醒事项") }
    let icon = AppIcon(color: .white, symbol: "checklist", glyph: srgb(0xff9500), system: "/System/Applications/Reminders.app")
    static let accent = srgb(0xff9500)

    private enum Dest: Equatable { case smart(ReminderSmart), list(String) }
    private var dest: Dest?
    private var scroll = AppScroll()
    private var lastVersion = -1
    private var lastMinute = -1
    private var permissionButton = CGRect.zero
    /// 動效包：清單的插入與刪除（完成的提醒拿掉時下面的列讓位上來、那一列淡出）；換清單就重來
    private var listMotion = HPListMotion()
    private var listMotionKey: Dest?
    private var lastRows: [String: ReminderItem] = [:]
    private var frameNow = 0.0
    private var src: ReminderSource { ReminderSource.shared }
    private var today: Date { Face.displayDate }

    func didOpen(now: Double) {
        dest = nil; scroll = AppScroll()
        // 快照：--demo-reminders-list [today|all]——帶 all 開「全部」（比較長，捲得動）；--demo-reminders-completed 開「已完成」
        if let i = AppUI.args.firstIndex(of: "--demo-reminders-list") {
            dest = i + 1 < AppUI.args.count && AppUI.args[i + 1] == "all" ? .smart(.all) : .smart(.today)
        }
        if AppUI.flag("--demo-reminders-completed") { dest = .smart(.completed) }   // 2.0 depth：快照「已完成」清單尾端的說明
        if let v = AppUI.scrollFlag("--demo-reminders-scroll") { scroll.offset = v }   // P12：快照——清單捲到一半，看標題底下的柔邊
    }

    // 2.0 r2：清單頁是子頁（‹，標題＝清單名）
    var backSymbol: String { dest != nil ? "chevron.left" : "xmark" }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        var dirty = src.expireChanges(now: CACurrentMediaTime())
        if src.version != lastVersion { lastVersion = src.version; dirty = true }
        let m = Int(Date().timeIntervalSince1970 / 60)
        if m != lastMinute { lastMinute = m; dirty = true }
        if !src.justChanged.isEmpty { dirty = true }
        return dirty
    }

    // MARK: 版面
    private static let smartOrder: [(ReminderSmart, String, UInt32)] = [
        (.today, "calendar", 0x0a84ff), (.scheduled, "calendar.badge.clock", 0xff453a),
        (.all, "tray.fill", 0x8e8e93), (.completed, "checkmark", 0x636366),
    ]
    private static func smartName(_ s: ReminderSmart) -> String {
        switch s {
        case .today: return L("reminders.smart.today", "今天")
        case .scheduled: return L("reminders.smart.scheduled", "已排程")
        case .all: return L("reminders.smart.all", "全部")
        case .completed: return L("reminders.smart.completed", "已完成")
        }
    }
    // 2.0 r2：大標題「提醒事项」放回左上；四格從 y 220 開始
    private static func tileRect(_ i: Int) -> CGRect { CGRect(x: 64 + CGFloat(i % 2) * 460, y: 220 + CGFloat(i / 2) * 172, width: 436, height: 152) }
    private static let listsHead: CGFloat = 606
    private static let listRow: CGFloat = 112, listGap: CGFloat = 0
    private func listRowRect(_ i: Int) -> CGRect {
        CGRect(x: 64, y: Self.listsHead + 28 + CGFloat(i) * (Self.listRow + Self.listGap) - scroll.offset, width: 896, height: Self.listRow)
    }
    private static let itemTop: CGFloat = 224, itemH: CGFloat = 116
    /// P12：清單頁頂端柔邊（scroll edge effect）：實心蓋到 174、柔邊接到第一列（itemTop）；靜止時第一列不受影響
    private static let fadeSolid: CGFloat = 174
    private func rowRect(_ i: Int) -> CGRect { CGRect(x: 64, y: Self.itemTop + CGFloat(i) * Self.itemH - scroll.offset, width: 896, height: Self.itemH) }

    private func items(for d: Dest) -> [ReminderItem] {
        let now = today
        let base: [ReminderItem]
        switch d {
        case .smart(let s): base = src.items.filter { ReminderLogic.matches($0, s, now: now) || (src.justChanged[$0.id] != nil && s != .completed && $0.completed) }
        case .list(let id): base = src.items.filter { $0.listID == id && (!$0.completed || src.justChanged[$0.id] != nil) }
        }
        var s = ReminderLogic.sorted(base)
        if case .smart(.completed) = d { s = s.reversed() }
        return s
    }
    private func destTitle(_ d: Dest) -> (String, NSColor) {
        switch d {
        case .smart(let s): let c = Self.smartOrder.first { $0.0 == s }?.2 ?? 0x8e8e93; return (Self.smartName(s), srgb(c))
        case .list(let id): let l = src.lists.first { $0.id == id }; return (l?.title ?? title, srgb(l?.color ?? 0xff9500))
        }
    }

    // MARK: 畫
    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        frameNow = now   // 動效包：清單動畫照這一幀的時鐘（--frames 逐格時是虛擬時鐘）
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        permissionButton = .zero
        if AppUI.personalLocked { AppUI.title(g, face, title); AppUI.drawLock(g, face, title: title); return }
        guard src.authorized else {
            AppUI.title(g, face, title)
            permissionButton = AppUI.drawPermission(g, face, appTitle: title, symbol: "checklist", tint: Self.accent,
                headline: src.denied ? L("reminders.perm.denied", "提醒事项没有开放") : L("reminders.perm.title", "需要读取提醒事项"),
                body: src.denied ? L("reminders.perm.deniedBody", "到系统设置的「隐私与安全性」里，允许 HomePlay 读取提醒事项") : L("reminders.perm.body", "可以看清单，点圆圈就能完成；不会离开这台 Mac"),
                button: src.denied ? L("perm.openSettings", "打开系统设置") : L("reminders.perm.button", "允许读取提醒事项"))
            return
        }
        src.refreshIfNeeded()
        if !src.everLoaded {   // 2.0 depth：第一次讀還沒回來：轉圈，不要先寫「0」和「沒有提醒」
            AppUI.title(g, face, title)
            HPComponents.spinner(g, in: CGRect(x: 512 - 30, y: 480, width: 60, height: 60), ink: HPComponents.secondary)
            return
        }
        // P12：內容先畫、頂端柔邊（scroll edge effect）再畫、大標題最後——清單捲上來時從標題底下柔柔地淡出
        if let d = dest { renderList(g, face, d) } else { renderHome(g, face) }
        if let d = dest { let (name, color) = destTitle(d); HPComponents.bigTitle(g, face, name, color: color) }
        else { AppUI.title(g, face, title) }
    }

    private func renderHome(_ g: CGContext, _ face: Face) {
        let all = src.items, nowDate = today
        // P12：會捲動的清單列先畫，柔邊蓋上去，固定的磚與分區標題最後畫。裁切上緣在磚的正下方（listsHead−42），
        // 柔邊帶 564→634 剛好接到第一列（listsHead+28）：靜止時看不到，捲動時列從分區標題底下淡出
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: Self.listsHead - 42, width: 1024, height: 960 - Self.listsHead + 42))
        let n = src.lists.count
        if n > 0 {
            let r0 = listRowRect(0)
            AppUI.group(g, CGRect(x: r0.minX, y: r0.minY, width: r0.width, height: CGFloat(n) * Self.listRow))
        }
        for (i, l) in src.lists.enumerated() {
            let r = listRowRect(i)
            guard r.maxY > Self.listsHead - 42, r.minY < 960 else { continue }
            let c = CGRect(x: r.minX + 32, y: r.midY - 28, width: 56, height: 56)
            HPAX.note(g, r, .button, l.title, value: String(ReminderLogic.count(all, list: l.id)), shape: .rounded(24))   // 2.0 depth：VoiceOver
            g.setFillColor(srgb(l.color).cgColor); g.fillEllipse(in: c)
            face.drawSymbol(g, "list.bullet", in: c.insetBy(dx: 14, dy: 15), color: .white, weight: .bold)
            let tf = AppUI.font(42)
            AppUI.left(face, g, Face.clipped(l.title, tf, 520), tf, x: r.minX + 112, y: r.midY + 15, AppUI.label)
            let cx = AppUI.chevron(g, face, rightX: r.maxX - 36, midY: r.midY)
            AppUI.right(face, g, String(ReminderLogic.count(all, list: l.id)), AppUI.font(40), rightX: cx - 20, y: r.midY + 14, AppUI.secondary)
            if i < n - 1 { AppUI.separator(g, x: r.minX + 112, maxX: r.maxX, y: r.maxY) }
        }
        g.restoreGState()
        HPComponents.topFade(g, AppUI.bg, solidTo: Self.listsHead - 42, height: 70)
        for (i, t) in Self.smartOrder.enumerated() {
            let r0 = Self.tileRect(i), k = Press.scale(r0), r = k == 1 ? r0 : HPComponents.scaled(r0, k)
            // 影片 v2 00:21.25（O71）：淺色時磚是清單色的實心填滿、白色圖示與字、數字在右上；深色照 iOS 是深灰磚＋彩色圓
            let col = srgb(t.2)
            HPAX.note(g, r0, .button, Self.smartName(t.0), value: String(ReminderLogic.count(all, t.0, now: nowDate)), shape: .rounded(44))   // 2.0 depth：VoiceOver
            let filled = !HPTokens.dark
            AppUI.fillRound(g, r, radius: 44, color: filled ? (col.blended(withFraction: 0.12, of: .white) ?? col) : AppUI.grouped)
            let c = CGRect(x: r.minX + 28, y: r.minY + 24, width: 64, height: 64)
            g.setFillColor((filled ? NSColor.white : col).cgColor); g.fillEllipse(in: c)
            face.drawSymbol(g, t.1, in: c.insetBy(dx: 16, dy: 16), color: filled ? col : .white, weight: .bold)
            AppUI.right(face, g, String(ReminderLogic.count(all, t.0, now: nowDate)), FaceType.sf(64, .bold), rightX: r.maxX - 32, y: r.minY + 80, filled ? .white : AppUI.label)
            AppUI.left(face, g, Self.smartName(t.0), AppUI.font(38, .semibold), x: r.minX + 30, y: r.maxY - 26, filled ? .white : AppUI.secondary)
        }
        AppUI.sectionTitle(g, face, L("reminders.myLists", "我的列表"), y: Self.listsHead)
    }

    private var homeContentHeight: CGFloat { Self.listsHead + 28 + CGFloat(src.lists.count) * (Self.listRow + Self.listGap) + 40 }

    private func dueText(_ r: ReminderItem) -> String? {
        guard let d = r.due else { return nil }
        let cal = Calendar.current, diff = cal.dateComponents([.day], from: cal.startOfDay(for: today), to: cal.startOfDay(for: d)).day ?? 0
        let f = DateFormatter(); f.locale = L10n.language.locale; f.setLocalizedDateFormatFromTemplate("MMMdEEE")
        var day: String
        switch diff {
        case 0: day = L("calendar.today", "今天")
        case 1: day = L("calendar.tomorrow", "明天")
        case -1: day = L("reminders.yesterday", "昨天")
        default: day = f.string(from: d)
        }
        if r.hasTime { day += " " + Face.shortTime(d) }   // 2.0 depth：時制照系統
        return day
    }

    private func renderList(_ g: CGContext, _ face: Face, _ d: Dest) {
        // iOS 提醒事項：清單名是清單色的大標題（render 裡畫在左上返回鈕旁）
        let list = items(for: d)
        scroll.clamp(contentHeight: Self.itemTop + CGFloat(list.count) * Self.itemH + 40 + Self.captionExtra(d), viewport: 960)
        if list.isEmpty {
            AppUI.center(face, g, L("reminders.none", "没有提醒"), AppUI.font(44, .semibold), cx: 512, y: 520, AppUI.secondary)
            HPAX.note(g, CGRect(x: 112, y: 470, width: 800, height: 70), .text, L("reminders.none", "没有提醒"), shape: .rounded(16))   // 2.0 depth：VoiceOver
            if d == .smart(.completed) { drawCompletedCaption(g, face, y: 580) }
            return
        }
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 960))   // P12：上緣交給柔邊蓋（實心到 fadeSolid），不用硬裁切
        let r0 = rowRect(0)
        // 動效包：列的位置走 HPListMotion（內容座標，不含捲動，捲動不會被彈簧拖慢）
        if listMotionKey != d { listMotion = HPListMotion(); listMotionKey = d; lastRows = [:] }
        for r in list { lastRows[r.id] = r }
        let placed = listMotion.layout(list.enumerated().map { (id: $0.element.id, y: Self.itemTop + CGFloat($0.offset) * Self.itemH) }, now: frameNow)
        if listMotion.animating(frameNow) { Anim.keepAlive() }
        let bottom = (placed.filter { !$0.removing }.map { $0.y + Self.itemH }.max() ?? Self.itemTop + Self.itemH) - scroll.offset
        AppUI.group(g, CGRect(x: r0.minX, y: r0.minY, width: r0.width, height: bottom - r0.minY))
        for pr in placed {
            guard let r = lastRows[pr.id] else { continue }
            let row = CGRect(x: r0.minX, y: pr.y - scroll.offset, width: r0.width, height: Self.itemH)
            guard row.maxY > Self.fadeSolid, row.minY < 960 else { continue }
            g.saveGState(); defer { g.restoreGState() }
            if pr.alpha < 0.999 { g.setAlpha(pr.alpha) }
            let done = r.completed
            let cy = row.midY, ring = CGRect(x: row.minX + 32, y: cy - 24, width: 48, height: 48)
            var lc: UInt32 = 0xff9500
            if let l = src.lists.first(where: { $0.id == r.listID }) { lc = l.color }
            if done {
                g.setFillColor(srgb(lc).cgColor); g.fillEllipse(in: ring)
                face.drawSymbol(g, "checkmark", in: ring.insetBy(dx: 12, dy: 13), color: .white, weight: .heavy)
            } else {
                g.setStrokeColor(AppUI.tertiary.cgColor); g.setLineWidth(4); g.strokeEllipse(in: ring.insetBy(dx: 2, dy: 2))
            }
            let ink = done ? AppUI.secondary : AppUI.label
            let tf = AppUI.font(42), sf = AppUI.font(30)
            let overdue = ReminderLogic.isOverdue(r, now: today)
            let listName: String? = { if case .smart = d { return src.lists.first { $0.id == r.listID }?.title }; return nil }()
            let sub = [dueText(r), listName].compactMap { $0 }.joined(separator: " · ")
            // 2.0 depth：VoiceOver——整列左邊（圓圈那一塊，點下去才會勾）是「勾選」，標題當標籤，到期與清單當值
            HPAX.note(g, CGRect(x: row.minX, y: row.minY, width: 170, height: row.height), .toggle(done), r.title.isEmpty ? L("calendar.untitled", "（无标题）") : r.title, value: sub.isEmpty ? nil : sub, shape: .rounded(24))
            if sub.isEmpty {
                AppUI.left(face, g, Face.clipped(r.title, tf, 740), tf, x: row.minX + 108, y: cy + 15, ink)
            } else {
                AppUI.left(face, g, Face.clipped(r.title, tf, 740), tf, x: row.minX + 108, y: cy - 4, ink)
                AppUI.left(face, g, Face.clipped(sub, sf, 740), sf, x: row.minX + 108, y: cy + 36, overdue ? AppUI.red : AppUI.secondary)
            }
            if !pr.removing, row.maxY < bottom - 1 { AppUI.separator(g, x: row.minX + 108, maxX: row.maxX, y: row.maxY) }
        }
        if d == .smart(.completed) { drawCompletedCaption(g, face, y: bottom + 52) }   // 2.0 depth：只讀最近 7 天（refreshIfNeeded 的視窗）
        g.restoreGState()
        HPComponents.topFade(g, AppUI.bg, solidTo: Self.fadeSolid, height: Self.itemTop - Self.fadeSolid)
    }

    /// 2.0 depth：「已完成」只抓最近 7 天，清單尾端說一聲，免得以為少了
    private static func captionExtra(_ d: Dest) -> CGFloat { d == .smart(.completed) ? 70 : 0 }
    private func drawCompletedCaption(_ g: CGContext, _ face: Face, y: CGFloat) {
        let s = L("reminders.completed.window", "只显示最近 7 天")
        AppUI.center(face, g, s, AppUI.font(28), cx: 512, y: y, AppUI.secondary)
        HPAX.note(g, CGRect(x: 112, y: y - 36, width: 800, height: 54), .text, s, shape: .rounded(12))
    }

    /// 返回膠囊／Esc：清單頁先退回首頁
    func handleBack(now: Double) -> Bool {
        guard dest != nil else { return false }
        dest = nil; scroll = AppScroll(); return true
    }

    // MARK: 點與滾
    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard src.authorized, !AppUI.personalLocked else { return false }
        if let d = dest { return scroll.scroll(dy, contentHeight: Self.itemTop + CGFloat(items(for: d).count) * Self.itemH + 40 + Self.captionExtra(d), viewport: 960) }
        return scroll.scroll(dy, contentHeight: homeContentHeight, viewport: 960)
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        if AppUI.personalLocked { return false }
        guard src.authorized else {
            guard AppUI.hit(permissionButton, p) else { return false }
            src.requestAccess { face.forceDirty = true }
            return true
        }
        if let d = dest {
            guard p.y > Self.itemTop - 12, p.y < 960 else { return false }
            for (i, r) in items(for: d).enumerated() {
                let row = rowRect(i)
                if row.contains(p), p.x < row.minX + 170 { return src.toggle(r.id, now: CACurrentMediaTime()) }
            }
            return false
        }
        for (i, t) in Self.smartOrder.enumerated() where Self.tileRect(i).contains(p) { dest = .smart(t.0); scroll = AppScroll(); return true }
        if p.y > Self.listsHead + 14, p.y < 960 {
            for (i, l) in src.lists.enumerated() where listRowRect(i).contains(p) { dest = .list(l.id); scroll = AppScroll(); return true }
        }
        return false
    }
}
