// 闹钟 App：清單（時間、標籤、重複日、開關）＋大步進器的編輯頁；響鈴時沿用計時器到點的橫幅與驚訝臉，再加一段聲音，
// 響鈴畫面有「停止」「稍后 9 分钟」。鬧鐘由桌寵行程自己的計時（Face.tickShell → AlarmCenter.tick）觸發，
// 所以只在 HomePlay 執行時才會響（畫面上有註明）。資料存在 UserDefaults（HomePlayAlarms）。
// 2.0 時鐘（照 iOS／macOS 27 時鐘的鬧鐘動態）：清單的列用彈簧滑到新位置，新增的列長出來、刪掉的列收起來；
// 開關的旋鈕操作時是玻璃、關掉的列跟著淡成次要色；「x 小時後響鈴」與編輯頁的大數字用數字捲動；
// 響鈴畫面：鬧鐘圖示外一圈圈往外擴的脈動、現在時間（數字捲動）、稍後／停止兩顆圓鈕 materialize 長出來。
// 快照：--demo-alarms（示範清單）、--demo-alarm-edit、--demo-alarm-ring、--demo-alarm-insert（新增一列的動畫，HOMEPLAY_ANIM=alarm.row:t）。

import AppKit

// MARK: - 純邏輯（--selftest 直接驗）

struct AlarmItem: Codable, Equatable {
    var id: Int
    var hour: Int
    var minute: Int
    var label: String
    /// Calendar 的 weekday（1＝週日 … 7＝週六）；空＝只響一次
    var days: [Int]
    var enabled: Bool
}

enum AlarmLogic {
    /// 下一次響鈴時間（嚴格晚於 after）。交給 Calendar.nextDate 算，夏令時間的空檔會順延到下一個有效時刻（.nextTime），不會漏響
    static func nextFire(_ a: AlarmItem, after: Date, calendar: Calendar = .current) -> Date? {
        var dc = DateComponents(); dc.hour = a.hour; dc.minute = a.minute; dc.second = 0
        if a.days.isEmpty { return calendar.nextDate(after: after, matching: dc, matchingPolicy: .nextTime) }
        return a.days.compactMap { wd -> Date? in
            var d = dc; d.weekday = wd
            return calendar.nextDate(after: after, matching: d, matchingPolicy: .nextTime)
        }.min()
    }

    /// 所有開著的鬧鐘裡最早的一個（清單上方「x 小时后响铃」用）
    static func soonest(_ alarms: [AlarmItem], after: Date, calendar: Calendar = .current) -> (AlarmItem, Date)? {
        alarms.filter(\.enabled).compactMap { a in nextFire(a, after: after, calendar: calendar).map { (a, $0) } }.min { $0.1 < $1.1 }
    }

    /// 重複日的簡述：一次／每天／工作日／週末／逐日
    enum Summary: Equatable { case once, everyDay, weekdays, weekend, custom([Int]) }
    static func summary(_ days: [Int]) -> Summary {
        let s = Set(days)
        if s.isEmpty { return .once }
        if s.count == 7 { return .everyDay }
        if s == [2, 3, 4, 5, 6] { return .weekdays }
        if s == [1, 7] { return .weekend }
        return .custom(days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 })   // 週一排第一
    }
}

/// 逐次檢查「有沒有鬧鐘到點」。睡眠醒來超過 grace 秒的不補響（不要中午響早上的鬧鐘）
struct AlarmScheduler {
    private var next: [Int: Date] = [:]
    var lastCheck: Date
    var grace: TimeInterval = 300
    init(now: Date) { lastCheck = now }
    mutating func invalidate() { next = [:] }
    /// 2.0 depth：上一次 due 裡超過 grace 沒補響的（Mac 睡著錯過了）：外殼出一張「錯過鬧鐘」橫幅、只響一次的關掉
    private(set) var missed: [Int] = []
    mutating func due(_ alarms: [AlarmItem], now: Date, calendar: Calendar = .current) -> [Int] {
        var out: [Int] = []
        missed = []
        for a in alarms where a.enabled {
            guard let n = next[a.id] ?? AlarmLogic.nextFire(a, after: lastCheck, calendar: calendar) else { continue }
            if n <= now {
                if now.timeIntervalSince(n) <= grace { out.append(a.id) } else { missed.append(a.id) }
                next[a.id] = AlarmLogic.nextFire(a, after: now, calendar: calendar)
            } else {
                next[a.id] = n
            }
        }
        lastCheck = now
        return out
    }
}

// MARK: - 響鈴中心（桌寵行程裡唯一一份）

final class AlarmCenter {
    static let shared = AlarmCenter()
    static let defaultsKey = "HomePlayAlarms"
    static let snoozeMinutes = 9.0
    static let ringLimit = 120.0           // 沒人理它，響這麼久就自己停

    private(set) var alarms: [AlarmItem] = []
    private var scheduler = AlarmScheduler(now: Date())
    private(set) var ringing: AlarmItem?
    private var ringStart = 0.0
    private var snoozed: (AlarmItem, Date)?
    private var sound: NSSound?
    private var lastSecond = -1
    private var nextID = 1
    private let demo = AppUI.demoAlarms

    init() {
        if demo { alarms = Self.demoAlarms().sorted { ($0.hour, $0.minute, $0.id) < ($1.hour, $1.minute, $1.id) }; nextID = 100 }
        else if let raw = UserDefaults.standard.data(forKey: Self.defaultsKey), let a = try? JSONDecoder().decode([AlarmItem].self, from: raw) { alarms = a }
        nextID = (alarms.map(\.id).max() ?? 0) + 1
        if AppUI.flag("--demo-alarm-ring") { ringing = alarms.first; ringStart = CACurrentMediaTime() + 3600 }
    }

    static func demoAlarms() -> [AlarmItem] {
        [AlarmItem(id: 1, hour: 7, minute: 0, label: L("alarm.demo.wake", "起床"), days: [2, 3, 4, 5, 6], enabled: true),
         AlarmItem(id: 2, hour: 9, minute: 30, label: L("alarm.demo.weekend", "周末赖床"), days: [1, 7], enabled: true),
         AlarmItem(id: 3, hour: 13, minute: 30, label: L("alarm.demo.nap", "午睡"), days: [], enabled: false),
         AlarmItem(id: 4, hour: 22, minute: 30, label: L("alarm.demo.sleep", "睡觉"), days: [1, 2, 3, 4, 5, 6, 7], enabled: true),
         AlarmItem(id: 5, hour: 6, minute: 15, label: L("alarm.demo.run", "晨跑"), days: [2, 4, 6], enabled: false)]
    }

    private func save() {
        scheduler.invalidate()
        guard !demo, let raw = try? JSONEncoder().encode(alarms) else { return }
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
    }
    func newID() -> Int { defer { nextID += 1 }; return nextID }
    func upsert(_ a: AlarmItem) {
        if let i = alarms.firstIndex(where: { $0.id == a.id }) { alarms[i] = a } else { alarms.append(a) }
        alarms.sort { ($0.hour, $0.minute, $0.id) < ($1.hour, $1.minute, $1.id) }
        save()
    }
    func remove(_ id: Int) { alarms.removeAll { $0.id == id }; save() }
    func toggle(_ id: Int) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].enabled.toggle(); save()
    }

    // MARK: 每幀
    /// 要重畫回 true（響鈴開始、稍後到點、響鈴畫面每秒動一下）
    func tick(_ face: Face, _ now: Double) -> Bool {
        let wall = Date()
        let s = Int(wall.timeIntervalSince1970)
        guard s != lastSecond else { return false }
        lastSecond = s
        var dirty = false
        if ringing != nil {
            Shell.lastActive = now
            // 離開了闹钟 App、或沒人理太久：算停止
            let away = now - ringStart > 3 && Shell.nav.screen != .app("alarms")
            if away || now - ringStart > Self.ringLimit { stop(face) }
            dirty = true
        }
        if let (a, until) = snoozed, wall >= until { snoozed = nil; ring(a, face, now); dirty = true }
        let due = scheduler.due(alarms, now: wall)
        for id in scheduler.missed {
            guard let i = alarms.firstIndex(where: { $0.id == id }) else { continue }
            let a = alarms[i]
            if a.days.isEmpty { alarms[i].enabled = false; save() }   // 只響一次的錯過了也算用掉（不然明天同一時間又響）
            let tp = Face.timeParts(hour: a.hour, minute: a.minute)
            let time = tp.period.map { tp.periodFirst ? $0 + tp.time : tp.time + " " + $0 } ?? tp.time
            face.showBanner(now: now, texts: (L("alarm.missed", "错过的闹钟"), (a.label.isEmpty ? L("alarm.default", "闹钟") : a.label) + " · " + time))
            dirty = true
        }
        for id in due {
            guard let i = alarms.firstIndex(where: { $0.id == id }) else { continue }
            let a = alarms[i]
            if a.days.isEmpty { alarms[i].enabled = false; save() }      // 只響一次的響過就關
            if ringing == nil { ring(a, face, now) }
            dirty = true
        }
        return dirty
    }

    private func ring(_ a: AlarmItem, _ face: Face, _ now: Double) {
        ringing = a; ringStart = now
        let tp = Face.timeParts(hour: a.hour, minute: a.minute)
        let time = tp.period.map { tp.periodFirst ? $0 + tp.time : tp.time + " " + $0 } ?? tp.time
        face.showBanner(now: now, texts: (String(format: L("alarm.banner.title", "%@ · 现在"), a.label.isEmpty ? L("alarm.default", "闹钟") : a.label), time))
        if !face.pomodoro.active { face.onTimerDone?() }                 // 驚訝臉＋甩頭，跟計時器到點一樣
        let snd = NSSound(named: NSSound.Name("Funk")) ?? NSSound(named: NSSound.Name("Glass"))
        snd?.loops = true; snd?.play(); sound = snd
        Shell.lastActive = now
        (NSApp.delegate as? AppDelegate)?.view?.shellOpenApp("alarms")   // 打開闹钟 App，上面有「停止」「稍后」
        log("alarm ring")
    }

    func stop(_ face: Face) {
        sound?.stop(); sound = nil
        ringing = nil; snoozed = nil
        face.dismissBanner(); face.forceDirty = true
    }
    func snooze(_ face: Face) {
        guard let a = ringing else { return }
        sound?.stop(); sound = nil; ringing = nil
        snoozed = (a, Date().addingTimeInterval(Self.snoozeMinutes * 60))
        face.dismissBanner(); face.forceDirty = true
    }
    var snoozeUntil: Date? { snoozed?.1 }
    /// 2.0 時鐘：響鈴畫面的脈動從這一刻起算
    /// （--demo-alarm-ring 的響鈴不會自己停：視覺上從開機那一刻起算，HOMEPLAY_CLOCK_T 往前推，逐格才拍得到脈動）
    var ringStartedAt: Double { ringStart > CACurrentMediaTime() ? demoRingStart - (ClockKit.frozenT ?? 0) : ringStart }
    private let demoRingStart = CACurrentMediaTime()
}

// MARK: - App 畫面

final class AlarmsApp: PetApp {
    static let shared = AlarmsApp()
    let id = "alarms"
    var title: String { L("app.alarms", "闹钟") }
    let icon = AppIcon(color: srgb(0xff9f0a), symbol: "alarm.fill")
    static let accent = srgb(0xff9f0a)

    private var scroll = AppScroll()
    /// 列的位置（id → 彈簧；換位置時從當下的值與速度接著走）、新增的時刻、刪掉還在收的列
    private var rowY: [Int: Anim] = [:]
    private var appeared: [Int: Double] = [:]
    private var removed: [(item: AlarmItem, y: CGFloat, at: Double)] = []
    /// 編輯頁大數字的捲動方向（＋往上捲、－往下捲）
    private var hourDown = false, minuteDown = false
    private var draft: AlarmItem?
    private var draftIsNew = false
    private var lastMinute = -1
    static let labelPresets: [() -> String] = [
        { L("alarm.default", "闹钟") }, { L("alarm.demo.wake", "起床") }, { L("alarm.demo.nap", "午睡") },
        { L("alarm.preset.work", "上班") }, { L("alarm.preset.pill", "吃药") }, { L("alarm.demo.sleep", "睡觉") },
    ]

    func didOpen(now: Double) {
        scroll = AppScroll(); draft = nil; rowY = [:]; appeared = [:]; removed = []
        if let v = AppUI.scrollFlag("--demo-alarm-scroll") { scroll.offset = v }   // P12：快照——清單捲到一半，看頂端的柔邊
        if AppUI.flag("--demo-alarm-edit") { openEditor(AlarmCenter.shared.alarms.first, isNew: false) }
        if AppUI.flag("--demo-alarm-insert") {   // 快照：剛新增一個 8:00 的鬧鐘（列從中間長出來、底下的列往下讓位）
            let a = AlarmItem(id: AlarmCenter.shared.newID(), hour: 8, minute: 0, label: L("alarm.default", "闹钟"), days: [], enabled: true)
            for (i, x) in AlarmCenter.shared.alarms.enumerated() { rowY[x.id] = Anim(Self.listTop + CGFloat(i) * Self.rowH, spring: AppMotion.appleSmooth, name: "alarm.row") }
            AlarmCenter.shared.upsert(a); appeared[a.id] = now
        }
    }

    // 2.0 r2：編輯頁是子頁（‹）
    var backSymbol: String { draft != nil && AlarmCenter.shared.ringing == nil ? "chevron.left" : "xmark" }

    func tick(_ now: Double) -> Bool {
        var dirty = HPComponents.needsFrame(now)
        if rowY.values.contains(where: { !$0.done(now) }) || !removed.isEmpty || appeared.values.contains(where: { now - $0 < 0.8 }) { ClockKit.keepLive(0.1); dirty = true }
        removed.removeAll { now - $0.at > 0.8 }
        if AlarmCenter.shared.ringing != nil {   // 響鈴：脈動與現在時間
            if !ClockKit.reduceMotion { ClockKit.keepLive(0.2) }
            dirty = true
        }
        let m = Int(Date().timeIntervalSince1970 / 60)
        if m != lastMinute { lastMinute = m; dirty = true }
        return dirty
    }

    // MARK: 版面
    // 左上是返回膠囊、右上是時間：大標題不畫（膠囊寫了「闹钟」），「＋」放在下一次響鈴那一行的右邊
    private static let listTop: CGFloat = 330
    /// P12：頂端柔邊（scroll edge effect）：實心蓋到 280（下一次響鈴那行底下）、柔邊接到第一列（listTop）
    private static let fadeSolid: CGFloat = 280
    private static let rowH: CGFloat = 164
    private static let addButton = CGRect(x: AppUI.margin + AppUI.contentW - 96, y: 206, width: 96, height: 96)
    private func rowRect(_ i: Int) -> CGRect {
        CGRect(x: AppUI.margin, y: Self.listTop + CGFloat(i) * Self.rowH - scroll.offset, width: AppUI.contentW, height: Self.rowH)
    }
    private func switchRect(_ row: CGRect) -> CGRect { CGRect(x: row.maxX - 36 - 132, y: row.midY - 32, width: 132, height: 64) }
    private var contentHeight: CGFloat { CGFloat(AlarmCenter.shared.alarms.count) * Self.rowH + 30 }
    private var viewport: CGFloat { 944 - Self.listTop }

    // 編輯頁
    private static let hourX: CGFloat = 300, minX: CGFloat = 724
    private static func plus(_ cx: CGFloat) -> CGRect { CGRect(x: cx - 48, y: 236, width: 96, height: 96) }
    private static func minus(_ cx: CGFloat) -> CGRect { CGRect(x: cx - 48, y: 516, width: 96, height: 96) }
    private static let chipRect = CGRect(x: 512 - 260, y: 632, width: 520, height: 96)
    private static func dayRect(_ i: Int) -> CGRect { CGRect(x: 64 + CGFloat(i) * (104 + 28), y: 748, width: 104, height: 104) }
    private static let deleteRect = CGRect(x: 112, y: 876, width: 250, height: 96)
    private static let cancelRect = CGRect(x: 387, y: 876, width: 250, height: 96)
    private static let saveRect = CGRect(x: 662, y: 876, width: 250, height: 96)
    // R6：響鈴時兩顆 150 px 圓鈕：稍後（玻璃）、停止（紅）
    private static let stopRect = HPComponents.actionRect(cx: 512 + 140, cy: 812)
    private static let snoozeRect = HPComponents.actionRect(cx: 512 - 140, cy: 812)

    private func weekdaySymbols(short: Bool) -> [String] {
        let f = DateFormatter(); f.locale = L10n.language.locale
        return short ? f.shortStandaloneWeekdaySymbols : f.veryShortStandaloneWeekdaySymbols
    }
    private func repeatText(_ days: [Int]) -> String {
        switch AlarmLogic.summary(days) {
        case .once: return L("alarm.once", "仅一次")
        case .everyDay: return L("alarm.everyDay", "每天")
        case .weekdays: return L("alarm.weekdays", "工作日")
        case .weekend: return L("alarm.weekend", "周末")
        case .custom(let ds): let sym = weekdaySymbols(short: true); return ds.map { sym[$0 - 1] }.joined(separator: " ")
        }
    }
    private func untilText(_ d: Date) -> String {
        let mins = max(1, Int((d.timeIntervalSinceNow / 60).rounded(.up)))
        if mins < 60 { return String(format: L("alarm.in.min", "%d 分钟后响铃"), mins) }
        if mins < 24 * 60 { return String(format: L("alarm.in.hm", "%d 小时 %d 分钟后响铃"), mins / 60, mins % 60) }
        return String(format: L("alarm.in.dh", "%d 天 %d 小时后响铃"), mins / 1440, (mins % 1440) / 60)
    }

    // MARK: 畫
    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        if let a = AlarmCenter.shared.ringing { renderRinging(g, face, a, now); return }
        if let d = draft { renderEditor(g, face, d); return }
        renderList(g, face)
        AppUI.title(g, face, title)
    }

    private func renderList(_ g: CGContext, _ face: Face) {
        let center = AlarmCenter.shared
        let now = CACurrentMediaTime()
        if center.alarms.isEmpty && removed.isEmpty {
            AppUI.center(face, g, L("alarm.empty", "还没有闹钟"), AppUI.font(48, .bold), cx: 512, y: 520, AppUI.label)
            AppUI.center(face, g, L("alarm.empty.hint", "点右上角的 + 新增"), AppUI.font(34), cx: 512, y: 580, AppUI.secondary)
        }
        g.saveGState()
        // P12：上緣不硬裁切，交給下面的柔邊蓋——捲上來的列從「下一次響鈴」那行底下柔柔地淡出
        g.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 944))
        // 每一列的位置走彈簧（排序、新增、刪除時從當下的位置滑過去）；新增的列高度從 0 長出來、字淡入
        let n = center.alarms.count
        var tops: [CGFloat] = [], heights: [CGFloat] = []
        for (i, a) in center.alarms.enumerated() {
            let target = Self.listTop + CGFloat(i) * Self.rowH
            var anim = rowY[a.id] ?? Anim(target, spring: AppMotion.appleSmooth, name: "alarm.row")
            if anim.to != target { anim.retarget(target, now: now) }
            rowY[a.id] = anim
            tops.append(anim.value(now) - scroll.offset)
            heights.append(Self.rowH * appear(a.id, now))
        }
        for k in rowY.keys where !center.alarms.contains(where: { $0.id == k }) { rowY[k] = nil }
        // 一整組一張卡（inset grouped）：卡的下緣跟著最後一列（含長出／收起中的高度）
        var bottom = tops.indices.map { tops[$0] + heights[$0] }.max() ?? (Self.listTop - scroll.offset)
        for r in removed { bottom = max(bottom, r.y - scroll.offset + Self.rowH * collapse(r.at, now)) }
        var card: CGPath?
        if n > 0 || !removed.isEmpty {
            let top = min(tops.min() ?? .infinity, removed.map { $0.y - scroll.offset }.min() ?? .infinity)
            let cr = CGRect(x: AppUI.margin, y: top, width: AppUI.contentW, height: max(0, bottom - top))
            AppUI.group(g, cr)
            card = continuousRoundedRect(cr, radius: AppUI.groupRadius)
        }
        if let card { g.addPath(card); g.clip() }   // 列自己的底（跟卡同色）只在卡裡：換位置時滑動的列蓋住別的列，靜止時看不出來
        // 刪掉的列：原地收起（高度與字一起淡掉），底下的列往上補
        for r in removed {
            let k = collapse(r.at, now)
            let rr = CGRect(x: AppUI.margin, y: r.y - scroll.offset, width: AppUI.contentW, height: Self.rowH)
            g.saveGState(); g.clip(to: CGRect(x: rr.minX, y: rr.minY, width: rr.width, height: Self.rowH * k)); g.setAlpha(k * k)
            drawRow(g, face, r.item, rr, last: true, now: now)
            g.restoreGState()
        }
        // 靜止的列先畫、在滑的列後畫（蓋在上面，像 iOS 的列換位置）
        let order = center.alarms.indices.sorted { abs(rowY[center.alarms[$0].id]?.state(now).v ?? 0) < abs(rowY[center.alarms[$1].id]?.state(now).v ?? 0) }
        for i in order {
            let a = center.alarms[i]
            let r = CGRect(x: AppUI.margin, y: tops[i], width: AppUI.contentW, height: Self.rowH)
            guard r.maxY > Self.fadeSolid, r.minY < 960 else { continue }
            let k = appear(a.id, now)
            g.saveGState()
            if k < 0.999 { g.clip(to: CGRect(x: r.minX, y: r.minY, width: r.width, height: heights[i])); g.setAlpha(k) }
            if let v = rowY[a.id]?.state(now).v, abs(v) > 1 { g.setFillColor(AppUI.grouped.cgColor); g.fill(r) }
            drawRow(g, face, a, r, last: i == n - 1, now: now)
            g.restoreGState()
        }
        g.restoreGState()
        // P12：頂端柔邊（scroll edge effect）：實心蓋到 fadeSolid（下一次響鈴那行底下）、柔邊接到第一列（listTop）；
        // 靜止時第一列不受影響，捲動時列從這裡淡出。標題、＋、說明行在柔邊之上
        HPComponents.topFade(g, AppUI.bg, solidTo: Self.fadeSolid, height: Self.listTop - Self.fadeSolid)
        AppUI.circleButton(g, face, Self.addButton, symbol: "plus", glyph: AppUI.orange)
        var sub = L("alarm.none.enabled", "没有开启的闹钟")
        if let s = center.snoozeUntil { sub = String(format: L("alarm.snoozed", "稍后提醒 · %@"), untilText(s)) }
        else if let (_, d) = AlarmLogic.soonest(center.alarms, after: Date()) { sub = untilText(d) }
        let sf = AppUI.font(34, .semibold)
        // 2.0 時鐘：分鐘一變，只有變的那幾個數字捲動
        ClockKit.roll(g, face, key: "alarm.until", text: Face.clipped(sub, sf, AppUI.contentW - 140), font: sf, x: AppUI.margin + 8, baseline: Self.addButton.midY + 12,
                      align: .left, color: AppUI.orange, down: true, now: now)
        // 底下固定一行說明
        AppUI.center(face, g, L("alarm.note", "闹钟只在 HomePlay 运行时才会响"), AppUI.font(28), cx: 512, y: 984, AppUI.secondary)
    }

    /// 新增的列長出來的程度（0…1，Spring 0.5 臨界阻尼）
    private func appear(_ id: Int, _ now: Double) -> CGFloat {
        guard let t = appeared[id] else { return 1 }
        let e = HPMotion.frozen("alarm.row") ?? (now - t)
        if ClockKit.reduceMotion { return CGFloat(min(1, e / HPMotion.reduceFade)) }
        return min(1, max(0, Spring.smooth.value(from: 0, to: 1, velocity: 0, t: CGFloat(e)).x))
    }
    /// 刪掉的列還剩多少（1 → 0）
    private func collapse(_ at: Double, _ now: Double) -> CGFloat {
        if ClockKit.reduceMotion { return CGFloat(max(0, 1 - (now - at) / HPMotion.reduceFade)) }
        return max(0, Spring.smooth.value(from: 1, to: 0, velocity: 0, t: CGFloat(now - at)).x)
    }

    private func drawRow(_ g: CGContext, _ face: Face, _ a: AlarmItem, _ r: CGRect, last: Bool, now: Double) {
        // 關掉的列跟著開關的彈簧淡成次要色（不是一下子換色）
        let on = CGFloat(Anim.track("toggle.alarm.\(a.id)", to: a.enabled ? 1 : 0, spring: AppMotion.interactive))
        let ink = AppUI.secondary.blended(withFraction: max(0, min(1, on)), of: AppUI.label) ?? AppUI.label
        // 2.0 depth：12 小時制照 iOS 鬧鐘——數字 80，上午／下午小一號（40）跟在後面（中文在前面）
        let tp = Face.timeParts(hour: a.hour, minute: a.minute), big = FaceType.sf(80, .light), small = FaceType.sf(40, .regular)
        var tx = r.minX + 36
        if let p = tp.period, tp.periodFirst { AppUI.left(face, g, p, small, x: tx, y: r.minY + 92, ink); tx += Typo.width(p, small) + 6 }
        AppUI.left(face, g, tp.time, big, x: tx, y: r.minY + 92, ink)
        if let p = tp.period, !tp.periodFirst { AppUI.left(face, g, p, small, x: tx + Typo.width(tp.time, big) + 8, y: r.minY + 92, ink) }
        let spoken = tp.period.map { tp.periodFirst ? $0 + tp.time : tp.time + " " + $0 } ?? tp.time
        let tf = AppUI.font(32)
        let line = Face.clipped("\(a.label.isEmpty ? L("alarm.default", "闹钟") : a.label) · \(repeatText(a.days))", tf, 600)
        AppUI.left(face, g, line, tf, x: r.minX + 38, y: r.minY + 138, ink)
        // 2.0 depth：VoiceOver——左邊整塊（點下去是編輯）是一顆「編輯闹钟」鈕，時間與標籤當值
        HPAX.note(g, CGRect(x: r.minX, y: r.minY, width: r.width - 220, height: r.height), .button, L("alarm.edit", "编辑闹钟"),
                  value: String(format: L("a11y.pair", "%1$@，%2$@"), spoken, line), shape: .rounded(24))
        AppUI.toggle(g, switchRect(r), on: a.enabled, key: "alarm.\(a.id)", label: spoken + " " + line)   // 2.0 P05
        if !last { AppUI.separator(g, x: r.minX + 36, maxX: r.maxX, y: r.maxY) }
    }

    private func renderEditor(_ g: CGContext, _ face: Face, _ d: AlarmItem) {
        AppUI.title(g, face, draftIsNew ? L("alarm.new", "新闹钟") : L("alarm.edit", "编辑闹钟"))
        let big = FaceType.sf(170, .light)
        for (cx, value, down, key) in [(Self.hourX, d.hour, hourDown, "alarm.edit.h"), (Self.minX, d.minute, minuteDown, "alarm.edit.m")] {
            // 2.0 depth：VoiceOver——＋／－ 分清楚是時還是分，值念目前設的時間
            let isHour = key == "alarm.edit.h", tp = Face.timeParts(hour: d.hour, minute: d.minute)
            let nowSet = tp.period.map { tp.periodFirst ? $0 + tp.time : tp.time + " " + $0 } ?? tp.time
            HPAX.note(g, Self.plus(cx), .button, isHour ? L("a11y.hourUp", "增加小时") : L("a11y.minuteUp", "增加分钟"), value: nowSet, shape: .circle)
            HPAX.note(g, Self.minus(cx), .button, isHour ? L("a11y.hourDown", "减少小时") : L("a11y.minuteDown", "减少分钟"), value: nowSet, shape: .circle)
            AppUI.circleButton(g, face, Self.plus(cx), symbol: "plus")
            AppUI.circleButton(g, face, Self.minus(cx), symbol: "minus")
            // 2.0 時鐘：＋ 往上捲（新數字從下面上來）、－ 往下捲；只有變的那一位動
            let shown = key == "alarm.edit.h" && Face.uses12Hour ? String(value % 12 == 0 ? 12 : value % 12) : String(format: "%02d", value)   // 2.0 depth：12 小時制
            ClockKit.roll(g, face, key: key, text: shown, font: big, x: cx, baseline: 486, align: .center, color: AppUI.label, down: down)
        }
        if let p = Face.timeParts(hour: d.hour, minute: d.minute).period {   // 上午／下午：跟著時數走（＋／－ 跨過 12 點就換），靠在時數左邊
            let pf = FaceType.sf(44, .semibold)
            AppUI.left(face, g, p, pf, x: Self.hourX - 112 - Typo.width(p, pf), y: 486, AppUI.secondary)
        }
        AppUI.center(face, g, ":", big, cx: 512, y: 478, AppUI.orange)
        // 標籤：玻璃膠囊，左邊是欄名（secondary）、右邊是值
        let kf = AppUI.font(36), vf = AppUI.font(36, .semibold)
        let key = L("alarm.label", "标签"), val = Face.clipped(d.label.isEmpty ? L("alarm.default", "闹钟") : d.label, vf, 300)
        let w = Typo.width(key, kf) + 20 + Typo.width(val, vf), x0 = Self.chipRect.midX - w / 2
        HPAX.note(g, Self.chipRect, .button, key, value: d.label.isEmpty ? L("alarm.default", "闹钟") : d.label)   // 2.0 depth：VoiceOver
        HPComponents.glassCapsule(g, Self.chipRect) { c in
            AppUI.left(face, c, key, kf, x: x0, y: Self.chipRect.midY + 13, AppUI.secondary)
            AppUI.left(face, c, val, vf, x: x0 + Typo.width(key, kf) + 20, y: Self.chipRect.midY + 13, AppUI.label)
        }
        // 重複日：排成週一…週日
        let order = [2, 3, 4, 5, 6, 7, 1], sym = weekdaySymbols(short: false)
        let fullDays: [String] = { let f = DateFormatter(); f.locale = L10n.language.locale; return f.standaloneWeekdaySymbols }()
        for (i, wd) in order.enumerated() {
            let r = Self.dayRect(i), on = d.days.contains(wd)
            HPAX.note(g, r, .toggle(on), fullDays[wd - 1], shape: .circle)   // 2.0 depth：VoiceOver——圓圈上只有「一」，念全名（星期一）
            // 選上：橘色從圓心長滿（interactiveSpring），字從次要色換白
            let k = CGFloat(max(0, min(1, Anim.track("alarm.day.\(wd)", to: on ? 1 : 0, spring: AppMotion.interactive))))
            g.setFillColor(AppUI.grouped.cgColor); g.fillEllipse(in: r)
            if k > 0.01 { g.setFillColor(AppUI.orange.cgColor); g.fillEllipse(in: r.insetBy(dx: r.width / 2 * (1 - k), dy: r.height / 2 * (1 - k))) }
            let ink = AppUI.secondary.blended(withFraction: k, of: .white) ?? .white
            AppUI.center(face, g, sym[wd - 1], AppUI.font(36, .semibold), cx: r.midX, y: r.midY + 13, ink)
        }
        if !draftIsNew { AppUI.button(g, face, Self.deleteRect, L("alarm.delete", "删除"), ink: AppUI.red) }
        AppUI.button(g, face, Self.cancelRect, L("wifi.cancel", "取消"))
        AppUI.button(g, face, Self.saveRect, L("alarm.save", "存储"), fill: AppUI.orange, ink: .white)
    }

    private func renderRinging(_ g: CGContext, _ face: Face, _ a: AlarmItem, _ now: Double) {
        // 2.0 時鐘：鬧鐘圖示外三圈往外擴、淡掉的脈動（週期 1.6 s、錯開 0.53 s）；減少動態效果時只留一圈靜止的光暈
        let ic = CGRect(x: 512 - 100, y: 250, width: 200, height: 200)
        let since = now - AlarmCenter.shared.ringStartedAt
        if ClockKit.reduceMotion {
            g.setFillColor(AppUI.orange.withAlphaComponent(0.18).cgColor); g.fillEllipse(in: ic.insetBy(dx: -30, dy: -30))
        } else {
            for k in 0..<3 {
                let ph = ((since + Double(k) * 1.6 / 3) / 1.6).truncatingRemainder(dividingBy: 1)
                let e = CGFloat(1 - pow(1 - ph, 2.2))                     // 一開始快、後來慢（像聲波）
                let grow = 10 + 120 * e
                g.setFillColor(AppUI.orange.withAlphaComponent(0.28 * (1 - e)).cgColor)
                g.fillEllipse(in: ic.insetBy(dx: -grow, dy: -grow))
            }
        }
        // 圖示輕輕搖（鬧鐘在響）：±4°，6 Hz，每 1.6 s 搖 0.5 s
        let shake: CGFloat = ClockKit.reduceMotion ? 0 : {
            let t = since.truncatingRemainder(dividingBy: 1.6)
            return t < 0.5 ? CGFloat(sin(t * 6 * 2 * .pi)) * 4 * .pi / 180 * CGFloat(1 - t / 0.5) : 0
        }()
        g.saveGState()
        g.translateBy(x: ic.midX, y: ic.midY); g.rotate(by: shake); g.translateBy(x: -ic.midX, y: -ic.midY)
        Shell.drawAppIcon(g, face: face, icon: icon, in: ic)
        g.restoreGState()
        // 現在時間（數字捲動）；鬧鐘設的時間與標籤在下面
        let nowText = Face.statusClock(Face.displayDate)
        ClockKit.roll(g, face, key: "alarm.ring.clock", text: nowText, font: FaceType.sf(190, .light), x: 512, baseline: 610, align: .center, color: AppUI.label, down: false, now: now)
        let label = a.label.isEmpty ? L("alarm.default", "闹钟") : a.label
        AppUI.center(face, g, label, AppUI.fitted(label, size: 48, weight: .semibold, maxWidth: 760), cx: 512, y: 680, AppUI.orange)
        // 兩顆圓鈕在響鈴那一刻 materialize 長出來
        let k = ClockKit.reduceMotion ? 1 : CGFloat(min(1, max(0, Spring.smooth.value(from: 0, to: 1, velocity: 0, t: CGFloat(max(0, since - 0.15))).x)))
        if k >= 0.99 {
            HPComponents.actionButton(g, face, Self.snoozeRect, symbol: "zzz", role: .glass, label: String(format: L("alarm.snooze", "稍后 %d 分钟"), Int(AlarmCenter.snoozeMinutes)))
            HPComponents.actionButton(g, face, Self.stopRect, symbol: "xmark", role: .stop, label: L("alarm.stop", "停止"))
        } else {
            HPComponents.actionButton(g, face, Self.snoozeRect, symbol: "zzz", role: .glass, presence: k)
            HPComponents.actionButton(g, face, Self.stopRect, symbol: "xmark", role: .stop, presence: k)
        }
    }

    // MARK: 點與滾
    private func openEditor(_ a: AlarmItem?, isNew: Bool) {
        draftIsNew = isNew
        draft = a ?? AlarmItem(id: AlarmCenter.shared.newID(), hour: 7, minute: 0, label: L("alarm.default", "闹钟"), days: [], enabled: true)
    }

    /// 返回膠囊／Esc：編輯頁先退回清單（響鈴時不攔，照舊離開 App＝停止）
    func handleBack(now: Double) -> Bool {
        guard AlarmCenter.shared.ringing == nil, draft != nil else { return false }
        draft = nil; return true
    }

    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard draft == nil, AlarmCenter.shared.ringing == nil else { return false }
        return scroll.scroll(dy, contentHeight: contentHeight, viewport: viewport)
    }

    /// 2.0 depth：編輯頁的分鐘 ＋／－ 長按＝一次 ±5（點一下 ±1）；別的地方照一般點按
    func handleLongPress(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard AlarmCenter.shared.ringing == nil, var d = draft else { return false }
        let up = AppUI.hit(Self.plus(Self.minX), p), down = AppUI.hit(Self.minus(Self.minX), p)
        guard up || down else { return false }
        d.minute = ((d.minute + (up ? 5 : -5)) % 60 + 60) % 60
        minuteDown = down; draft = d; return true
    }

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        let center = AlarmCenter.shared
        if center.ringing != nil {
            if AppUI.hit(Self.stopRect, p) { center.stop(face); return true }
            if AppUI.hit(Self.snoozeRect, p) { center.snooze(face); return true }
            return false
        }
        if var d = draft {
            for (cx, isHour) in [(Self.hourX, true), (Self.minX, false)] {
                let up = AppUI.hit(Self.plus(cx), p), down = AppUI.hit(Self.minus(cx), p)
                guard up || down else { continue }
                let s = up ? 1 : -1
                // 2.0 depth：點一下 ±1 分（以前 ±5，06:58 設不出來）；長按 ±5 在 handleLongPress
                if isHour { d.hour = (d.hour + s + 24) % 24; hourDown = down }
                else { d.minute = ((d.minute + s) % 60 + 60) % 60; minuteDown = down }
                draft = d; return true
            }
            if AppUI.hit(Self.chipRect, p) {
                let names = Self.labelPresets.map { $0() }
                let i = names.firstIndex(of: d.label).map { ($0 + 1) % names.count } ?? 0
                d.label = names[i]; draft = d; return true
            }
            let order = [2, 3, 4, 5, 6, 7, 1]
            for (i, wd) in order.enumerated() where AppUI.hit(Self.dayRect(i), p, pad: 6) {
                if let k = d.days.firstIndex(of: wd) { d.days.remove(at: k) } else { d.days.append(wd) }
                draft = d; return true
            }
            if AppUI.hit(Self.saveRect, p) {
                d.enabled = true
                if draftIsNew { appeared[d.id] = CACurrentMediaTime() }   // 新的列長出來、其他列讓位
                center.upsert(d); draft = nil; return true
            }
            if AppUI.hit(Self.cancelRect, p) { draft = nil; return true }
            if !draftIsNew, AppUI.hit(Self.deleteRect, p) {
                let now = CACurrentMediaTime()
                if let y = rowY[d.id]?.value(now), let item = center.alarms.first(where: { $0.id == d.id }) { removed.append((item, y, now)) }   // 原地收起
                center.remove(d.id); draft = nil; return true
            }
            return false
        }
        if AppUI.hit(Self.addButton, p) { openEditor(nil, isNew: true); return true }
        guard p.y > Self.listTop - 10, p.y < 950 else { return false }
        for (i, a) in center.alarms.enumerated() {
            let r = rowRect(i)
            guard r.contains(p) else { continue }
            if p.x >= r.maxX - 220 { center.toggle(a.id) } else { openEditor(a, isNew: false) }
            return true
        }
        return false
    }

    /// 清單上方的小提示給 Live Activity 用：響鈴前一小時內的下一個鬧鐘（先不做，見回報）
    func liveActivity(face: Face, now: Double) -> LiveActivity? { nil }
}
