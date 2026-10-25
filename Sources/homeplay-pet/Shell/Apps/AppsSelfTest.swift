// 資料型 App（闹钟、天气、日历、提醒事项）純邏輯的自檢；--selftest 經 ShellSelfTest.run 呼叫。

import Foundation

enum AppsSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        LyricsSelfTest.run(check)
        P10AppsSelfTest.run(check)   // 2.0 P10：尋找、對講、Safari（含食譜併進 Safari）
        FaceTimeSelfTest.run(check)
        ClockKitSelfTest.run(check)   // 2.0 時鐘：太陽、晨昏線、日出日落、計時器暫停、系統地圖退回自繪
        HomeWriteSelfTest.run(check)   // 2.0 第四輪：家庭寫入（假 HomeLink）、門鈴接管規則   // 2.0 第四輪 #10：通話偵測狀態機、搜尋、撥號一定要確認   // 2.0 第四輪 #8／#11：LRC 解析、句子時間、LRCLIB 請求、MediaRemote 解析
        // 2.0 r2：家庭磚排法（大磚 2×2 照順序放進最上、最左的空位）與彈簧解析解
        let slots = HomeGrid.pack([2, 1, 1, 2, 1, 1, 1]).map { [$0.col, $0.row, $0.size] }
        check(slots == [[0, 0, 2], [2, 0, 1], [2, 1, 1], [0, 2, 2], [2, 2, 1], [2, 3, 1], [0, 4, 1]], "家庭：大磚 2×2 排法")
        let sp = Spring(damping: 1, response: 0.185)
        check(abs(sp.value(from: 0, to: 1, velocity: 0, t: 0.0417).x - 0.43) < 0.03 && sp.value(from: 0, to: 1, velocity: 0, t: 2).x > 0.9999, "彈簧：臨界阻尼解析解（恆溫器展開第一格約 0.43）")
        let bouncy = Spring(damping: 0.7, response: 0.5).value(from: 0, to: 1, velocity: 0, t: 0.3).x
        check(bouncy > 1, "彈簧：欠阻尼會過衝")
        check(abs(AppMotion.rubberBand(1000, 100)) < 100 && AppMotion.rubberBand(-10, 100) < 0, "拉過頭的阻力有上限、保留方向")
        func cal(_ tz: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!; c.firstWeekday = 1; return c }
        func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
            c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
        }
        let tw = cal("Asia/Taipei")

        // 鬧鐘：下一次響鈴
        let once = AlarmItem(id: 1, hour: 7, minute: 0, label: "", days: [], enabled: true)
        check(AlarmLogic.nextFire(once, after: date(tw, 2026, 10, 24, 8), calendar: tw) == date(tw, 2026, 10, 25, 7), "鬧鐘：過了時間就是明天")
        check(AlarmLogic.nextFire(once, after: date(tw, 2026, 10, 24, 6), calendar: tw) == date(tw, 2026, 10, 24, 7), "鬧鐘：還沒到就是今天")
        check(AlarmLogic.nextFire(once, after: date(tw, 2026, 10, 24, 7), calendar: tw) == date(tw, 2026, 10, 25, 7), "鬧鐘：剛好響過那一秒不重複響")
        let weekdays = AlarmItem(id: 2, hour: 7, minute: 30, label: "", days: [2, 3, 4, 5, 6], enabled: true)
        check(AlarmLogic.nextFire(weekdays, after: date(tw, 2026, 10, 24, 8), calendar: tw) == date(tw, 2026, 10, 26, 7, 30), "鬧鐘：週六之後的工作日鬧鐘是週一")
        let sunSat = AlarmItem(id: 3, hour: 9, minute: 0, label: "", days: [7, 1], enabled: true)
        check(AlarmLogic.nextFire(sunSat, after: date(tw, 2026, 10, 24, 9, 30), calendar: tw) == date(tw, 2026, 10, 25, 9), "鬧鐘：週六響過接週日")
        check(AlarmLogic.soonest([once, weekdays, AlarmItem(id: 9, hour: 5, minute: 0, label: "", days: [], enabled: false)], after: date(tw, 2026, 10, 24, 8), calendar: tw)?.0.id == 1,
              "鬧鐘：最近的只看開著的") // l10n-ignore：自檢訊息
        check(AlarmLogic.summary([]) == .once && AlarmLogic.summary([1, 2, 3, 4, 5, 6, 7]) == .everyDay
              && AlarmLogic.summary([6, 2, 5, 4, 3]) == .weekdays && AlarmLogic.summary([7, 1]) == .weekend
              && AlarmLogic.summary([1, 3]) == .custom([3, 1]), "鬧鐘：重複日簡述（週一排第一）") // l10n-ignore：自檢訊息
        // 夏令時間：紐約 2026-03-08 02:00 跳到 03:00；2026-11-01 02:00 退回 01:00
        let ny = cal("America/New_York")
        let gap = AlarmItem(id: 4, hour: 2, minute: 30, label: "", days: [], enabled: true)
        let g = AlarmLogic.nextFire(gap, after: date(ny, 2026, 3, 7, 23), calendar: ny)
        check(g.map { ny.component(.hour, from: $0) == 3 && ny.component(.day, from: $0) == 8 } == true, "鬧鐘：夏令跳過的 02:30 順延到 03:xx，不漏響")
        let daily = AlarmItem(id: 5, hour: 9, minute: 0, label: "", days: [1, 2, 3, 4, 5, 6, 7], enabled: true)
        let d1 = AlarmLogic.nextFire(daily, after: date(ny, 2026, 3, 7, 10), calendar: ny)!
        check(ny.component(.hour, from: d1) == 9 && d1.timeIntervalSince(date(ny, 2026, 3, 7, 9)) == 23 * 3600, "鬧鐘：跨夏令仍是當地 09:00（只隔 23 小時）")
        let fall = AlarmItem(id: 6, hour: 1, minute: 30, label: "", days: [], enabled: true)
        let f = AlarmLogic.nextFire(fall, after: date(ny, 2026, 10, 31, 23), calendar: ny)!
        check(ny.component(.day, from: f) == 1 && ny.component(.hour, from: f) == 1, "鬧鐘：重複的 01:30 只取一次")
        // 排程：到點一次、不補響
        var sch = AlarmScheduler(now: date(tw, 2026, 10, 24, 6, 59, 59))
        check(sch.due([once], now: date(tw, 2026, 10, 24, 7, 0, 1), calendar: tw) == [1], "排程：到點響")
        check(sch.due([once], now: date(tw, 2026, 10, 24, 7, 0, 2), calendar: tw).isEmpty, "排程：同一次不重複響")
        var sch2 = AlarmScheduler(now: date(tw, 2026, 10, 24, 6, 0))
        check(sch2.due([once], now: date(tw, 2026, 10, 24, 12, 0), calendar: tw).isEmpty && sch2.missed == [1], "排程：睡眠醒來超過寬限就不補響，記成錯過")
        check(sch2.due([once], now: date(tw, 2026, 10, 25, 7, 0, 3), calendar: tw) == [1], "排程：隔天照響")
        var sch3 = AlarmScheduler(now: date(tw, 2026, 10, 24, 6, 59, 59))
        var off = once; off.enabled = false
        check(sch3.due([off], now: date(tw, 2026, 10, 24, 7, 0, 1), calendar: tw).isEmpty, "排程：關掉的不響")

        // 日曆：分日、排序、跨日、月曆格、打點
        func ev(_ id: String, _ s: Date, _ e: Date, allDay: Bool = false, color: UInt32 = 0xff0000) -> AgendaEvent {
            AgendaEvent(id: id, title: id, start: s, end: e, allDay: allDay, location: nil, notes: nil, calendarTitle: "", color: color)
        }
        let evs = [
            ev("b", date(tw, 2026, 10, 24, 14), date(tw, 2026, 10, 24, 15)),
            ev("a", date(tw, 2026, 10, 24, 9), date(tw, 2026, 10, 24, 10)),
            ev("day", date(tw, 2026, 10, 24), date(tw, 2026, 10, 25), allDay: true, color: 0x00ff00),
            ev("trip", date(tw, 2026, 10, 26), date(tw, 2026, 10, 28), allDay: true),
            ev("late", date(tw, 2026, 10, 25, 23), date(tw, 2026, 10, 26, 1)),
        ]
        let secs = AgendaLogic.sections(evs, from: date(tw, 2026, 10, 24, 12), days: 5, calendar: tw)
        check(secs.map { $0.day } == [date(tw, 2026, 10, 24), date(tw, 2026, 10, 25), date(tw, 2026, 10, 26), date(tw, 2026, 10, 27)], "日程：沒行程的 28 日略過")
        check(secs[0].events.map(\.id) == ["day", "a", "b"], "日程：全天最前、再按開始時間")
        check(secs[2].events.map(\.id) == ["late", "trip"] || secs[2].events.map(\.id) == ["trip", "late"], "日程：跨日行程每天都出現")
        check(secs[2].events.first?.allDay == true && secs[3].events.map(\.id) == ["trip"], "日程：多日全天事件涵蓋到最後一天、不多算結束那天")
        check(AgendaLogic.sections([], from: date(tw, 2026, 10, 24), days: 3, calendar: tw).count == 1
              && AgendaLogic.sections([], from: date(tw, 2026, 10, 24), days: 3, calendar: tw, keepFirstEmpty: false).isEmpty, "日程：今天沒行程仍留一段") // l10n-ignore：自檢訊息
        let grid = AgendaLogic.monthGrid(date(tw, 2026, 10, 24), calendar: tw)    // 2026-10-01 是週四，週首週日 → 前面 4 格
        check(grid.count == 35 && !grid[0].inMonth && grid[4].inMonth && tw.component(.day, from: grid[4].date) == 1 && grid[34].inMonth, "月曆：週首對齊、整週")
        let dots = AgendaLogic.dots(evs, grid: grid, calendar: tw)
        check(dots[date(tw, 2026, 10, 24)]?.count == 2 && dots[date(tw, 2026, 10, 27)] == [0xff0000] && dots[date(tw, 2026, 10, 29)] == nil, "月曆：每天最多取不同顏色的點")

        // 提醒事項：智慧清單與各清單數量
        let now = date(tw, 2026, 10, 24, 10)
        let (items, lists) = ReminderSource.demoData(now: now, calendar: tw)
        check(ReminderLogic.count(items, .today, now: now, calendar: tw) == 4, "提醒：今天含逾期（4）")
        check(ReminderLogic.count(items, .scheduled, now: now, calendar: tw) == 7 && ReminderLogic.count(items, .all, now: now, calendar: tw) == 9
              && ReminderLogic.count(items, .completed, now: now, calendar: tw) == 2, "提醒：已排程 7／全部 9／已完成 2") // l10n-ignore：自檢訊息
        check(lists.map { ReminderLogic.count(items, list: $0.id) } == [4, 2, 2, 1], "提醒：各清單未完成數")
        check(ReminderLogic.sorted(items.filter { !$0.completed }).last?.title == ReminderLogic.sorted(items.filter { !$0.completed && $0.due == nil }).last?.title, "提醒：沒有到期日的排最後")
        let bill = items.first { $0.id == "r2" }!, gift = items.first { $0.id == "r1" }!, milk = items.first { $0.id == "r4" }!
        check(ReminderLogic.isOverdue(bill, now: now, calendar: tw) && !ReminderLogic.isOverdue(gift, now: now, calendar: tw) && !ReminderLogic.isOverdue(milk, now: now, calendar: tw),
              "提醒：逾期判斷（全天的提醒到當天結束前不算逾期）") // l10n-ignore：自檢訊息

        // 天氣：逐時逐日解析（從目前整點起 12 小時、5 天）
        var times: [String] = [], temps: [Any] = [], codes: [Any] = [], isDay: [Any] = []
        for h in 0..<48 { times.append(String(format: "2026-10-24T%02d:00", h % 24).replacingOccurrences(of: "2026-10-24", with: h < 24 ? "2026-10-24" : "2026-10-25")); temps.append(NSNumber(value: 20 + h)); codes.append(NSNumber(value: 1)); isDay.append(NSNumber(value: (h % 24) >= 6 && (h % 24) < 18 ? 1 : 0)) }
        let w: [String: Any] = ["hourly": ["time": times, "temperature_2m": temps, "weather_code": codes, "is_day": isDay],
                                "daily": ["time": ["2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27", "2026-10-28"], "temperature_2m_max": [25, 24, 23, 22, 21],
                                          "temperature_2m_min": [19, 18, 17, 16, 15], "weather_code": [0, 1, 2, 3, 61]]]
        let (hours, days) = WeatherSource.forecast(w, now: "2026-10-24T22:15")
        check(hours?.count == 12 && hours?.first?.label == "22" && hours?.first?.night == true && hours?[2].label == "00" && hours?.first?.temp == 42, "天氣：逐時從目前整點起 12 筆（跨日）")
        check(days?.count == 5 && days?.last?.code == 61 && days?.first?.hi == 25, "天氣：逐日 5 筆")
        check(WeatherSource.forecast([:], now: nil).0 == nil, "天氣：沒有預報欄位不崩")
        WeatherSkySelfTest.run(check)   // 2.0: 天氣 App 的動態天空（場景對應、退路）

        // 11-grid-apps：跨 App 網格不變式——所有 App 的返回鈕同一個 rect、大標題同一條左緣（合約規則 7）
        check(HPTokens.backButton == CGRect(x: 60, y: 60, width: 90, height: 90) && HPTokens.titleX == HPTokens.backButton.maxX + 24
              && HPTokens.titleBaseline == HPTokens.backButton.midY + 20 && HPTokens.titleFont.pointSize == 56,
              "網格：返回鈕 (60,60,90,90)，大標題＝鈕右緣＋24、基線＝鈕中線＋20、SF 56 bold") // l10n-ignore：自檢訊息
        check(HPComponents.hitBack(CGPoint(x: 105, y: 105)) && !HPComponents.hitBack(CGPoint(x: 170, y: 105)) && !HPComponents.hitBack(CGPoint(x: 105, y: 170)),
              "網格：返回鈕命中區以 (60,60,90,90) 為準（所有 App 的 ‹ 都在同一格）") // l10n-ignore：自檢訊息
        check(AppUI.margin == HPGrid.App.margin && AppUI.contentW == HPGrid.App.trailing - HPGrid.App.leading,
              "網格：App 內容區 64…960（AppUI.margin 對到 HPGrid.App）") // l10n-ignore：自檢訊息
        let titleXs = Set(AppRegistry.all.map { HPComponents.titleLayout($0.title).x })
        check(titleXs == [HPTokens.titleX], "網格：所有 App（\(AppRegistry.all.count) 個）大標題同一條左緣 \(Int(HPTokens.titleX))") // l10n-ignore：自檢訊息
        // 家庭攝影機子頁的格線也在 64…960 系統上（2×2：磚 432、欄距 32；3×3：磚 288、欄距 16）
        let quad = HomeApp.cameraCells(4)
        check(quad.map { $0.minX } == [64, 528, 64, 528] && quad.allSatisfy { $0.maxX == 496 || $0.maxX == 960 } && quad[0].width == 432 && quad[2].minY - quad[0].maxY == 85,
              "網格：家庭攝影機 2×2 對齊 64…960（磚 432、欄距 32、標籤留 85）") // l10n-ignore：自檢訊息
        let nine = HomeApp.cameraCells(6)
        check(nine.prefix(3).map { $0.minX } == [64, 368, 672] && nine.allSatisfy { $0.width == 288 } && nine[3].minX == 64 && nine[5].maxX == 960,
              "網格：家庭攝影機 3×3 對齊 64…960（磚 288、欄距 16）") // l10n-ignore：自檢訊息
    }
}
