// 日历 App（唯讀）：「日程」＝今天起的行程分日列出（時間、標題、日曆顏色），「月」＝月曆格（有行程的日子打點），
// 點行程看詳情（時間、地點、備註截斷）；點月曆的某一天＝日程從那天開始列。新增行程是 ClioTalk 的工作，這裡不寫。
// 資料來自 EventKit（跟 CalendarSource 同一個授權）；沒授權＝說明卡＋按鈕走既有的權限流程（PermissionPrimer）。
// 開了「認出誰在看」而眼前不是主人：換成「需要主人」鎖卡。

import AppKit
import EventKit

// MARK: - 純邏輯（--selftest 直接驗）

struct AgendaEvent: Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var notes: String?
    var calendarTitle: String
    var color: UInt32            // 日曆顏色 0xRRGGBB
}

enum AgendaLogic {
    struct Section: Equatable { var day: Date; var events: [AgendaEvent] }

    /// 事件跟 [dayStart, dayEnd) 有交集（跨日的事件每天都出現；0 長度的事件看開始點）
    static func overlaps(_ e: AgendaEvent, dayStart: Date, dayEnd: Date) -> Bool {
        if e.end <= e.start { return e.start >= dayStart && e.start < dayEnd }
        return e.start < dayEnd && e.end > dayStart
    }

    /// 從 from 那天起 days 天，每天一段；全天的排最前、再按開始時間。沒行程的日子略過（keepFirstEmpty＝第一天沒行程也留著，給「今天没有行程」）
    static func sections(_ events: [AgendaEvent], from: Date, days: Int, calendar: Calendar = .current, keepFirstEmpty: Bool = true) -> [Section] {
        let day0 = calendar.startOfDay(for: from)
        var out: [Section] = []
        for i in 0..<days {
            guard let s = calendar.date(byAdding: .day, value: i, to: day0), let e = calendar.date(byAdding: .day, value: 1, to: s) else { continue }
            let list = events.filter { overlaps($0, dayStart: s, dayEnd: e) }.sorted {
                if $0.allDay != $1.allDay { return $0.allDay }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.title < $1.title
            }
            if !list.isEmpty || (i == 0 && keepFirstEmpty) { out.append(Section(day: s, events: list)) }
        }
        return out
    }

    /// 月曆格：整週對齊（週首照系統），回傳每一格的日期與是否屬於這個月
    static func monthGrid(_ month: Date, calendar: Calendar = .current) -> [(date: Date, inMonth: Bool)] {
        guard let first = calendar.dateInterval(of: .month, for: month)?.start, let days = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let rows = (lead + days + 6) / 7
        return (0..<(rows * 7)).compactMap { i in
            calendar.date(byAdding: .day, value: i - lead, to: first).map { ($0, calendar.isDate($0, equalTo: first, toGranularity: .month)) }
        }
    }

    /// 月曆上每天要打幾個點（最多 3 個，取不同日曆的顏色）：key＝當天 0 點
    static func dots(_ events: [AgendaEvent], grid: [(date: Date, inMonth: Bool)], calendar: Calendar = .current) -> [Date: [UInt32]] {
        var out: [Date: [UInt32]] = [:]
        for cell in grid {
            guard let e = calendar.date(byAdding: .day, value: 1, to: cell.date) else { continue }
            var colors: [UInt32] = []
            for ev in events where overlaps(ev, dayStart: cell.date, dayEnd: e) && !colors.contains(ev.color) { colors.append(ev.color) }
            if !colors.isEmpty { out[cell.date] = Array(colors.prefix(3)) }
        }
        return out
    }
}

// MARK: - 資料

final class AgendaSource {
    static let shared = AgendaSource()
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "homeplay.agenda", qos: .utility)
    private(set) var events: [AgendaEvent] = []
    private(set) var loaded: (Date, Date)?
    private(set) var version = 0
    private var fetching = false
    private var observer: NSObjectProtocol?
    private var lastFetch = Date.distantPast
    private let demo = AppUI.demoCalendar

    // 2.0 depth：「一般 › 讀取行事曆」只管錶面的「下一個行程」（它的說明這樣寫），不再連行事曆 App 一起關
    var authorized: Bool { demo || CalendarSource.auth == .fullAccess }
    var denied: Bool { !demo && ![.notDetermined, .fullAccess].contains(CalendarSource.auth) }

    init() {
        if demo { events = OfficialDemo.on ? OfficialDemo.events() : Self.demoEvents(now: Face.displayDate); loaded = (.distantPast, .distantFuture) }
        else {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.loaded = nil; self?.version += 1
            }
        }
    }

    /// 要用到 [from, to) 的行程：沒涵蓋就背景去讀（讀完 version 加一，畫面下一幀重畫）
    /// 2.0 depth：這段還沒讀進來（第一次打開、翻到沒讀過的月）：畫轉圈，不要先說「沒有行程」
    func covered(from: Date, to: Date) -> Bool {
        if demo { return true }
        guard let l = loaded else { return false }
        return l.0 <= from && l.1 >= to
    }
    func ensure(from: Date, to: Date) {
        guard authorized, !demo else { return }
        if let l = loaded, l.0 <= from, l.1 >= to, Date().timeIntervalSince(lastFetch) < 300 { return }
        guard !fetching else { return }
        fetching = true
        // 多讀前後各一週，翻月不用每次都等
        let lo = Calendar.current.date(byAdding: .day, value: -7, to: from) ?? from, hi = Calendar.current.date(byAdding: .day, value: 7, to: to) ?? to
        let store = store
        queue.async { [weak self] in
            let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: nil)
            let list: [AgendaEvent] = store.events(matching: pred).map { e in
                var hex: UInt32 = 0xff3b30
                if let c = e.calendar?.cgColor, let ns = NSColor(cgColor: c)?.usingColorSpace(.sRGB) {
                    hex = UInt32(ns.redComponent * 255) << 16 | UInt32(ns.greenComponent * 255) << 8 | UInt32(ns.blueComponent * 255)
                }
                return AgendaEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "", start: e.startDate, end: e.endDate,
                                   allDay: e.isAllDay, location: e.location, notes: e.notes, calendarTitle: e.calendar?.title ?? "", color: hex)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false; self.lastFetch = Date()
                self.events = list; self.loaded = (lo, hi); self.version += 1
            }
        }
    }

    /// 示範行程（相對於 now，快照不需要任何權限）
    static func demoEvents(now: Date, calendar: Calendar = .current) -> [AgendaEvent] {
        func at(_ dayOffset: Int, _ h: Int, _ m: Int = 0) -> Date {
            let d = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
        }
        func ev(_ id: String, _ title: String, _ s: Date, _ e: Date, _ color: UInt32, cal: String, allDay: Bool = false, loc: String? = nil, notes: String? = nil) -> AgendaEvent {
            AgendaEvent(id: id, title: title, start: s, end: e, allDay: allDay, location: loc, notes: notes, calendarTitle: cal, color: color)
        }
        let work = L("calendar.demo.work", "工作"), home = L("calendar.demo.home", "家庭"), me = L("calendar.demo.personal", "个人")
        return [
            ev("d1", L("calendar.demo.standup", "晨会"), at(0, 9, 30), at(0, 10), 0x0a84ff, cal: work),
            ev("d2", L("calendar.demo.lunch", "和 B 吃午饭"), at(0, 12), at(0, 13), 0x30d158, cal: me, loc: L("calendar.demo.lunchPlace", "忠孝东路 巷口面店")),
            ev("d3", L("shell.demo.event", "设计评审"), at(0, 14), at(0, 15), 0xff453a, cal: work, loc: L("calendar.demo.room", "3 楼 会议室 B"),
               notes: L("calendar.demo.notes", "带上新版主画面的稿子。先看图标和 Live Activity，再讨论计时器的动画；会后把意见整理进共享文档，周五之前回复。")),
            ev("d4", L("calendar.demo.yoga", "瑜伽课"), at(0, 18, 30), at(0, 19, 30), 0xff9f0a, cal: me),
            ev("d5", L("calendar.demo.birthday", "B 的生日"), at(1, 0), at(2, 0), 0xbf5af2, cal: home, allDay: true),
            ev("d6", L("calendar.demo.dentist", "牙医复诊"), at(1, 10, 30), at(1, 11, 15), 0x0a84ff, cal: me, loc: L("calendar.demo.clinic", "仁爱路 牙医诊所")),
            ev("d7", L("calendar.demo.review", "周报"), at(3, 16), at(3, 17), 0x0a84ff, cal: work),
            ev("d8", L("calendar.demo.trip", "台中出差"), at(5, 0), at(7, 0), 0xff453a, cal: work, allDay: true),
            ev("d9", L("calendar.demo.dinner", "家庭聚餐"), at(6, 18), at(6, 20), 0x30d158, cal: home),
            ev("d10", L("calendar.demo.concert", "演唱会"), at(9, 19, 30), at(9, 22), 0xbf5af2, cal: me),
        ]
    }
}

// MARK: - App 畫面

final class CalendarApp: PetApp {
    static let shared = CalendarApp()
    let id = "calendar"
    var title: String { L("app.calendar", "日历") }
    let icon = AppIcon(color: .white, symbol: "calendar", glyph: srgb(0xff3b30), calendarDate: true)
    static let accent = srgb(0xff3b30)

    private enum Tab { case agenda, month }
    private var tab: Tab = .agenda
    private var agendaStart = Date()
    private var monthShown = Date()
    private var selected: AgendaEvent?
    private var scroll = AppScroll()
    private var lastVersion = -1
    private var lastMinute = -1
    private var permissionButton = CGRect.zero

    private var src: AgendaSource { AgendaSource.shared }
    private var today: Date { Face.displayDate }

    func didOpen(now: Double) {
        tab = .agenda; agendaStart = today; monthShown = today; selected = nil; scroll = AppScroll()
        if AppUI.flag("--demo-calendar-month") { tab = .month }
        if AppUI.flag("--demo-calendar-detail") { selected = AgendaLogic.sections(src.events, from: today, days: 1).first?.events.first { $0.location != nil && $0.notes != nil } }
        if let v = AppUI.scrollFlag("--demo-calendar-scroll") { scroll.offset = v }   // P12：快照——議程捲到一半，看頂端的柔邊
    }

    // 2.0 r2：行程詳情是子頁（‹，標題是那個月，照影片的「‹ April」）
    var backSymbol: String { selected != nil ? "chevron.left" : "xmark" }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        var dirty = false
        if src.version != lastVersion { lastVersion = src.version; dirty = true }
        let m = Int(Date().timeIntervalSince1970 / 60)
        if m != lastMinute { lastMinute = m; dirty = true }
        return dirty
    }

    // MARK: 格式
    private func fmt(_ template: String, _ d: Date) -> String {
        let f = DateFormatter(); f.locale = L10n.language.locale; f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }
    private func clock(_ d: Date) -> String {
        Face.shortTime(d)   // 2.0 depth：時制照系統
    }
    private func dayHeader(_ day: Date) -> String {
        let cal = Calendar.current, base = cal.startOfDay(for: today)
        let diff = cal.dateComponents([.day], from: base, to: day).day ?? 0
        let date = fmt("MMMdEEE", day)
        switch diff {
        case 0: return "\(L("calendar.today", "今天")) · \(date)"
        case 1: return "\(L("calendar.tomorrow", "明天")) · \(date)"
        default: return date
        }
    }

    // MARK: 版面
    // 大標題不畫（返回膠囊寫了「日历」）；分段控制放在膠囊和時間下面那一行的中間
    private static let tabBar = CGRect(x: 512 - 220, y: 214, width: 440, height: 92)
    private static func tabRect(_ i: Int) -> CGRect { CGRect(x: tabBar.minX + CGFloat(i) * tabBar.width / 2, y: tabBar.minY, width: tabBar.width / 2, height: tabBar.height) }
    private static let listTop: CGFloat = 330
    /// P12：頂端柔邊（scroll edge effect）：實心蓋到分段控制底下（fadeSolid）、柔邊接到第一列（listTop）
    private static let fadeSolid: CGFloat = 308
    private static let rowH: CGFloat = 120, headH: CGFloat = 64, sectionGap: CGFloat = 36
    private static let prevRect = CGRect(x: 64, y: 320, width: 96, height: 96)
    private static let nextRect = CGRect(x: 864, y: 320, width: 96, height: 96)
    private static let gridTop: CGFloat = 494, cellW: CGFloat = 128, cellH: CGFloat = 76

    /// 每天一段：段標題＋一張 inset grouped 卡（列跟列之間是分隔線，不留縫）
    private struct AgendaItem { var y: CGFloat; var h: CGFloat; var section: Int; var event: AgendaEvent?; var last = false }
    private func layout(_ sections: [AgendaLogic.Section]) -> (items: [AgendaItem], height: CGFloat) {
        var y = Self.listTop, items: [AgendaItem] = []
        for (si, s) in sections.enumerated() {
            items.append(AgendaItem(y: y, h: Self.headH, section: si, event: nil)); y += Self.headH
            for (k, e) in s.events.enumerated() { items.append(AgendaItem(y: y, h: Self.rowH, section: si, event: e, last: k == s.events.count - 1)); y += Self.rowH }
            if s.events.isEmpty { items.append(AgendaItem(y: y, h: Self.rowH, section: si, event: nil, last: true)); y += Self.rowH }
            y += Self.sectionGap
        }
        return (items, y + 20)
    }
    private var agendaSections: [AgendaLogic.Section] { AgendaLogic.sections(src.events, from: agendaStart, days: 30) }

    // MARK: 畫
    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        permissionButton = .zero
        // 標題＝目前看的月份（影片 v1 47.75、v2 O68：日視圖的標題是「April」，不是 App 名稱）；月視圖寫年月
        if AppUI.personalLocked { AppUI.title(g, face, title); AppUI.drawLock(g, face, title: title); return }
        guard src.authorized else {
            AppUI.title(g, face, title)
            permissionButton = AppUI.drawPermission(g, face, appTitle: title, symbol: "calendar", tint: Self.accent,
                headline: src.denied ? L("calendar.perm.denied", "日历没有开放") : L("calendar.perm.title", "需要读取日历"),
                body: src.denied ? L("calendar.perm.deniedBody", "到系统设置的「隐私与安全性」里，允许 HomePlay 读取日历") : L("calendar.perm.body", "只读取，不修改，也不离开这台 Mac"),
                button: src.denied ? L("perm.openSettings", "打开系统设置") : L("calendar.perm.button", "允许读取日历"))
            return
        }
        if let e = selected { AppUI.title(g, face, fmt("MMMM", e.start)); renderDetail(g, face, e); return }
        // P12：內容先畫、頂端柔邊（scroll edge effect）再畫、標題與分段最後——議程捲上來時從分段控制底下柔柔地淡出
        switch tab {
        case .agenda: renderAgenda(g, face)
        case .month: renderMonth(g, face)
        }
        HPComponents.topFade(g, AppUI.bg, solidTo: Self.fadeSolid, height: Self.listTop - Self.fadeSolid)
        AppUI.title(g, face, tab == .month ? fmt("yMMMM", monthShown) : fmt("MMMM", agendaStart))
        drawTabs(g, face)
    }

    private func drawTabs(_ g: CGContext, _ face: Face) {
        AppUI.segmented(g, face, Self.tabBar, [L("calendar.tab.agenda", "日程"), L("calendar.tab.month", "月")], selected: tab == .agenda ? 0 : 1, key: "calendar.tab")
    }

    private func renderAgenda(_ g: CGContext, _ face: Face) {
        let to = Calendar.current.date(byAdding: .day, value: 31, to: agendaStart) ?? agendaStart
        let from = Calendar.current.startOfDay(for: min(agendaStart, today))
        src.ensure(from: from, to: to)
        if !src.covered(from: from, to: to) {
            HPComponents.spinner(g, in: CGRect(x: 512 - 30, y: 480, width: 60, height: 60), ink: HPComponents.secondary)
            return
        }
        let secs = agendaSections
        let lay = layout(secs)
        scroll.clamp(contentHeight: lay.height, viewport: 944 - Self.listTop + 20)
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 960))   // P12：上緣交給柔邊蓋，不用硬裁切
        // 2.0 r2：照影片 v2 00:21.25 的日視圖——每個行程一張淡色卡（日曆顏色約 20%）＋左側同色細直條，不再是一整組白卡
        for it in lay.items {
            let y = it.y - scroll.offset
            guard y + it.h > Self.fadeSolid - 4, y < 960 else { continue }
            let sec = secs[it.section]
            if it.h == Self.headH {
                let isToday = Calendar.current.isDate(sec.day, inSameDayAs: today)
                AppUI.left(face, g, dayHeader(sec.day), AppUI.font(34, .semibold), x: AppUI.margin + 12, y: y + 44, isToday ? AppUI.red : AppUI.secondary)
                HPAX.note(g, CGRect(x: AppUI.margin, y: y + 4, width: AppUI.contentW, height: 56), .heading, dayHeader(sec.day), shape: .rounded(12))   // 2.0 depth：VoiceOver
                continue
            }
            let row = CGRect(x: AppUI.margin, y: y, width: AppUI.contentW, height: Self.rowH)
            let r = row.insetBy(dx: 0, dy: 6)
            guard let e = it.event else {
                AppUI.group(g, r, radius: 36)
                AppUI.left(face, g, L("calendar.none.today", "没有行程"), AppUI.font(40), x: r.minX + 36, y: r.midY + 14, AppUI.secondary)
                HPAX.note(g, r, .text, L("calendar.none.today", "没有行程"), shape: .rounded(36))   // 2.0 depth：VoiceOver
                continue
            }
            let tint = srgb(e.color)
            // 2.0 depth：VoiceOver——標題當標籤，時間與地點當值
            let when = e.allDay ? L("calendar.allDay", "全天") : "\(clock(e.start)) – \(clock(e.end))"   // l10n-ignore：時間範圍
            HPAX.note(g, r, .button, e.title.isEmpty ? L("calendar.untitled", "（无标题）") : e.title,
                      value: [when, e.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "), shape: .rounded(36))
            let k = Press.scale(r), rr = k == 1 ? r : HPComponents.scaled(r, k)
            // 淡色卡：淺色時是日曆色 20% 疊在白上，深色時 30% 疊在 #1C1C1E 上（不透明，捲動時不透出後面）
            let base = AppUI.grouped
            AppUI.fillRound(g, rr, radius: 36, color: base.blended(withFraction: HPTokens.dark ? 0.3 : 0.2, of: tint) ?? base)
            AppUI.fillPill(g, CGRect(x: rr.minX + 22, y: rr.minY + 20, width: 8, height: rr.height - 40), color: tint)
            // 字：淺色時用日曆色壓深（影片：深綠字），深色時用 label
            let ink = HPTokens.dark ? AppUI.label : (tint.blended(withFraction: 0.55, of: .black) ?? AppUI.label)
            let tf = AppUI.font(32, .semibold), sf = AppUI.font(30)
            if e.allDay {
                AppUI.left(face, g, L("calendar.allDay", "全天"), tf, x: r.minX + 56, y: r.midY + 12, ink)
            } else {
                AppUI.left(face, g, clock(e.start), tf, x: r.minX + 56, y: r.midY - 4, ink)
                AppUI.left(face, g, clock(e.end), sf, x: r.minX + 56, y: r.midY + 32, ink.withAlphaComponent(0.6))
            }
            let nf = AppUI.font(42, .semibold)
            let title = Face.clipped(e.title.isEmpty ? L("calendar.untitled", "（无标题）") : e.title, nf, 620)
            if let loc = e.location, !loc.isEmpty {
                AppUI.left(face, g, title, nf, x: r.minX + 220, y: r.midY - 2, ink)
                AppUI.left(face, g, Face.clipped(loc, sf, 620), sf, x: r.minX + 220, y: r.midY + 34, ink.withAlphaComponent(0.6))
            } else {
                AppUI.left(face, g, title, nf, x: r.minX + 220, y: r.midY + 15, ink)
            }
        }
        g.restoreGState()
        if secs.flatMap(\.events).isEmpty {
            AppUI.center(face, g, L("calendar.empty", "接下来 30 天没有行程"), AppUI.font(34), cx: 512, y: 560, AppUI.secondary)
        }
        if !Calendar.current.isDate(agendaStart, inSameDayAs: today) {
            AppUI.center(face, g, String(format: L("calendar.from", "从 %@ 起 · 点「日程」回到今天"), fmt("MMMd", agendaStart)), AppUI.font(28), cx: 512, y: 988, AppUI.secondary)
        }
    }

    private func renderMonth(_ g: CGContext, _ face: Face) {
        let grid = AgendaLogic.monthGrid(monthShown)
        guard let first = grid.first, let last = grid.last else { return }
        src.ensure(from: first.date, to: Calendar.current.date(byAdding: .day, value: 1, to: last.date) ?? last.date)
        let dots = AgendaLogic.dots(src.events, grid: grid)
        HPAX.note(g, Self.prevRect, .button, L("a11y.prevMonth", "上个月"), shape: .circle)   // 2.0 depth：VoiceOver
        HPAX.note(g, Self.nextRect, .button, L("a11y.nextMonth", "下个月"), shape: .circle)
        AppUI.circleButton(g, face, Self.prevRect, symbol: "chevron.left", glyph: AppUI.red)
        AppUI.circleButton(g, face, Self.nextRect, symbol: "chevron.right", glyph: AppUI.red)
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = L10n.language.locale
        let sym = f.veryShortStandaloneWeekdaySymbols ?? []
        for c in 0..<7 {
            let wd = (cal.firstWeekday - 1 + c) % 7
            AppUI.center(face, g, sym[wd], AppUI.font(28, .semibold), cx: AppUI.margin + Self.cellW * (CGFloat(c) + 0.5), y: 472, (wd == 0 || wd == 6) ? AppUI.tertiary : AppUI.secondary)
        }
        for (i, cell) in grid.enumerated() {
            let col = i % 7, row = i / 7
            let r = CGRect(x: AppUI.margin + CGFloat(col) * Self.cellW, y: Self.gridTop + CGFloat(row) * Self.cellH, width: Self.cellW, height: Self.cellH)
            let isToday = cal.isDate(cell.date, inSameDayAs: today)
            let n = String(cal.component(.day, from: cell.date))
            // 2.0 depth：VoiceOver——整天的日期當標籤；今天與行程數當值
            let count = dots[cell.date]?.count ?? 0
            HPAX.note(g, r, .button, fmt("yMMMdEEE", cell.date),
                      value: [isToday ? L("calendar.today", "今天") : nil, count > 0 ? String(format: L("a11y.eventCount", "%d 个行程"), count) : nil].compactMap { $0 }.joined(separator: ", "), shape: .rounded(16))
            if isToday {
                g.setFillColor(AppUI.red.cgColor); g.fillEllipse(in: CGRect(x: r.midX - 32, y: r.minY - 2, width: 64, height: 64))
            }
            AppUI.center(face, g, n, FaceType.sf(38, isToday ? .semibold : .medium), cx: r.midX, y: r.minY + 44,
                         isToday ? .white : (cell.inMonth ? AppUI.label : AppUI.tertiary))
            if let colors = dots[cell.date] {
                let w = CGFloat(colors.count) * 10 + CGFloat(colors.count - 1) * 6
                for (k, hex) in colors.enumerated() {
                    g.setFillColor(srgb(hex).withAlphaComponent(cell.inMonth ? 1 : 0.4).cgColor)
                    g.fillEllipse(in: CGRect(x: r.midX - w / 2 + CGFloat(k) * 16, y: r.minY + 63, width: 10, height: 10))
                }
            }
        }
    }

    private func renderDetail(_ g: CGContext, _ face: Face, _ e: AgendaEvent) {
        let r = CGRect(x: 64, y: 224, width: 896, height: 680)
        AppUI.group(g, r, radius: Screen.concentric(inset: 64))
        AppUI.fillPill(g, CGRect(x: r.minX + 36, y: r.minY + 40, width: 10, height: 92), color: srgb(e.color))
        let tf = AppUI.font(52, .bold)
        let lines = Face.wrap(e.title.isEmpty ? L("calendar.untitled", "（无标题）") : e.title, tf, 720, maxLines: 2)
        for (i, l) in lines.enumerated() { AppUI.left(face, g, l, tf, x: r.minX + 72, y: r.minY + 84 + CGFloat(i) * 62, AppUI.label) }
        var y = r.minY + 84 + CGFloat(lines.count) * 62 + 30
        let sf = AppUI.font(40), nf = AppUI.font(32)
        var spoken = [e.title.isEmpty ? L("calendar.untitled", "（无标题）") : e.title]   // 2.0 depth：VoiceOver——整張詳情念成一段
        func line(_ symbol: String, _ s: String, _ color: NSColor? = nil) {
            spoken.append(s)
            let color = color ?? AppUI.label
            face.drawSymbol(g, symbol, in: CGRect(x: r.minX + 40, y: y - 30, width: 40, height: 36), color: AppUI.secondary, weight: .regular)
            AppUI.left(face, g, Face.clipped(s, sf, 740), sf, x: r.minX + 100, y: y, color)
            y += 64
        }
        let cal = Calendar.current
        var when = fmt("yMMMdEEE", e.start)
        if e.allDay {
            let lastDay = cal.date(byAdding: .second, value: -1, to: e.end) ?? e.end
            if !cal.isDate(e.start, inSameDayAs: lastDay) { when += " – " + fmt("MMMdEEE", lastDay) }
            line("calendar", "\(when) · \(L("calendar.allDay", "全天"))")
        } else {
            line("calendar", when)
            line("clock", cal.isDate(e.start, inSameDayAs: e.end) ? "\(clock(e.start)) – \(clock(e.end))" : "\(clock(e.start)) – \(fmt("MMMd", e.end)) \(clock(e.end))")
        }
        if let loc = e.location, !loc.isEmpty { line("mappin.and.ellipse", loc) }
        if !e.calendarTitle.isEmpty { line("circle.fill", e.calendarTitle, AppUI.secondary) }
        if let notes = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            y += 6
            for l in wrapAny(notes.replacingOccurrences(of: "\n", with: " "), nf, 780, maxLines: 4) {
                AppUI.left(face, g, l, nf, x: r.minX + 40, y: y, AppUI.secondary); y += 44
            }
            spoken.append(notes)
        }
        HPAX.note(g, r, .text, spoken.joined(separator: ", "), shape: .rounded(Screen.concentric(inset: 64)))
    }

    /// 中英混排的備註：有中日韓字就逐字折行（Face.wrap 遇到空白只照詞切，整句中文不會折），否則照詞
    private func wrapAny(_ s: String, _ font: NSFont, _ width: CGFloat, maxLines: Int) -> [String] {
        guard s.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) else { return Face.wrap(s, font, width, maxLines: maxLines) }
        var lines: [String] = [], cur = ""
        for ch in s {
            if Typo.width(cur + String(ch), font) > width, !cur.isEmpty { lines.append(cur); cur = "" }
            cur.append(ch)
        }
        if !cur.isEmpty { lines.append(cur) }
        if lines.count > maxLines { lines = Array(lines[..<(maxLines - 1)]) + [Face.clipped(lines[(maxLines - 1)...].joined(), font, width)] }
        return lines
    }

    // MARK: 點與滾
    /// 返回膠囊／Esc：詳情頁先退回清單
    func handleBack(now: Double) -> Bool {
        guard selected != nil else { return false }
        selected = nil; return true
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard selected == nil, tab == .agenda, src.authorized, !AppUI.personalLocked else { return false }
        return scroll.scroll(dy, contentHeight: layout(agendaSections).height, viewport: 944 - Self.listTop + 20)
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        if AppUI.personalLocked { return false }
        guard src.authorized else {
            guard AppUI.hit(permissionButton, p) else { return false }
            if src.denied { PermissionCenter.openSettings(.calendar); return true }
            (NSApp.delegate as? AppDelegate)?.withPermission(.calendar) { ok in
                if ok { CalendarSource.enabled = true; CalendarSource.shared.refresh() }
                face.forceDirty = true
            }
            return true
        }
        if selected != nil {
            if p.y > 910 { selected = nil; return true }
            return true
        }
        for i in 0..<2 where AppUI.hit(Self.tabRect(i), p, pad: 0) {
            let want: Tab = i == 0 ? .agenda : .month
            if want == .agenda { agendaStart = today; scroll = AppScroll() }
            tab = want; return true
        }
        switch tab {
        case .agenda:
            let secs = agendaSections
            for it in layout(secs).items {
                guard let e = it.event, it.y - scroll.offset <= p.y, p.y < it.y - scroll.offset + it.h, p.y > Self.listTop - 8, p.y < 950 else { continue }
                selected = e; return true
            }
        case .month:
            let cal = Calendar.current
            if AppUI.hit(Self.prevRect, p) { monthShown = cal.date(byAdding: .month, value: -1, to: monthShown) ?? monthShown; return true }
            if AppUI.hit(Self.nextRect, p) { monthShown = cal.date(byAdding: .month, value: 1, to: monthShown) ?? monthShown; return true }
            let grid = AgendaLogic.monthGrid(monthShown)
            let col = Int((p.x - AppUI.margin) / Self.cellW), row = Int((p.y - Self.gridTop) / Self.cellH)
            if col >= 0, col < 7, row >= 0, p.y >= Self.gridTop, row * 7 + col < grid.count {
                agendaStart = grid[row * 7 + col].date; tab = .agenda; scroll = AppScroll(); return true
            }
        }
        return false
    }
}
