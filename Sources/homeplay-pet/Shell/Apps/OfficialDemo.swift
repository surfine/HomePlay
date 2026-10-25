// 2.0 第三輪（R15）：--demo-official —— 跟官方原圖一樣的示範內容，給 tooling/refcompare.py 對照用（realism-spec3「做法 1」）。
// 只換「內容」，不換版面：時間 10:09、2026 年 4 月 1 日星期三、生日行程三筆、Butternut Squash Soup（Home Cookbook／35 min／Serves 4，
// 照片用我們自己的示範圖）、15 分鐘計時剩 10:56、官方那一組家庭磚。不放任何 Apple 的照片。
// 跟 --app <id> 一起用，例如：--demo-official --app timers --lang en --screen-png out.png
//   --app calendar｜--cliotalk-demo answer｜--app recipes（自動進封面）｜--app home（自動用這組磚）｜--app timers（自動加這個計時器）

import AppKit

enum OfficialDemo {
    static let on = CommandLine.arguments.contains("--demo-official")

    /// 2026-04-01（星期三）10:09；--time 給了就用那個時刻、日期照樣是 4 月 1 日
    static func date(time: String?) -> Date {
        var c = DateComponents(year: 2026, month: 4, day: 1, hour: 10, minute: 9)
        if let v = time?.split(separator: ":").compactMap({ Int($0) }), v.count == 2 { c.hour = v[0]; c.minute = v[1] }
        return Calendar.current.date(from: c) ?? Date()
    }

    // MARK: 行事曆：三筆生日（官方 siri-calendar）
    static func events(calendar: Calendar = .current) -> [AgendaEvent] {
        func day(_ d: Int, _ h: Int = 0, _ m: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 4, day: d, hour: h, minute: m)) ?? Date()
        }
        let cal = L("demo.official.birthdays", "生日")
        return [
            AgendaEvent(id: "o1", title: L("demo.official.maiko", "Maiko 的生日"), start: day(1), end: day(2), allDay: true, location: nil, notes: nil,
                        calendarTitle: cal, color: 0xff9f0a),
            AgendaEvent(id: "o2", title: L("demo.official.party", "Nick、Juan 和 Vicki 的生日派对"), start: day(17, 15), end: day(17, 16), allDay: false,
                        location: nil, notes: nil, calendarTitle: cal, color: 0x0a84ff),
            AgendaEvent(id: "o3", title: L("demo.official.hunter", "Hunter 的生日"), start: day(28), end: day(29), allDay: true, location: nil, notes: nil,
                        calendarTitle: cal, color: 0xff9f0a),
        ]
    }
    /// ClioTalk 回答（一句結論＋每行一筆：「日期：內容」）
    static var clioAnswer: String {
        L("demo.official.answer", "这是你行事历上接下来的生日：\n4月1日 周三：Maiko 的生日 · 全天\n4月17日 周五：Nick、Juan 和 Vicki 的生日派对 · 15:00–16:00\n4月28日 周二：Hunter 的生日 · 全天")
    }

    // MARK: 計時器：15 分鐘、剩 10:56（官方 timer）
    static let timerTotal = 15 * 60.0
    static let timerLeft = 10 * 60.0 + 56
    /// 快照在加進去之後約 1.2–2 s 才拍（--screen-png），顯示是無條件進位的秒：多給 1 s 才會停在 10:56
    static let timerSlack = 1.0

    // MARK: 正在播放（官方 nowplaying-crop：2SIDED／Arlo Parks、1:58／−0:59；封面仍是我們程式畫的）
    static let songTitle = "2SIDED", songArtist = "Arlo Parks"   // l10n-ignore
    static let songDuration = 177.0, songPosition = 118.0

    // MARK: 食譜（官方 recipe-overview）
    static var recipeTitle: String { L("demo.official.recipe", "奶油南瓜浓汤") }
    static var recipeSource: String { L("demo.official.recipeSource", "家常食谱") }

    // MARK: 家庭（官方 home-light：Lights 玄關 開、Intercom、Home、Good Morning 場景、Lights 臥室 開、Fan 辦公室 開、Door Lock 大門；左上一台攝影機）
    static func homeSnapshot() -> HomeSnapshot {
        func ch(_ id: String, _ type: String, _ val: HomeValue?, w: Bool = true) -> HomeCharacteristic {
            HomeCharacteristic(id: id, type: type, value: val, writable: w, units: nil, min: nil, max: nil, step: nil)
        }
        func acc(_ id: String, _ name: String, _ cat: String, _ cs: [HomeCharacteristic], camera: Bool = false, room: String = "r1") -> HomeAccessory {
            HomeAccessory(id: id, name: name, home: "h1", room: room, category: "x", categoryName: cat, reachable: true, characteristics: cs, camera: camera ? true : nil)
        }
        // 官方那一頁是跨房間的一頁磚，磚的第二行是房間：Entryway、Everywhere、Bedroom、Office、Front Door
        let rooms = [HomeRoom(id: "r1", name: L("demo.official.room.entry", "玄关"), home: "h1"),
                     HomeRoom(id: "r2", name: L("demo.official.room.everywhere", "全屋"), home: "h1"),
                     HomeRoom(id: "r3", name: L("demo.official.room.bedroom", "卧室"), home: "h1"),
                     HomeRoom(id: "r4", name: L("demo.official.room.office", "办公室"), home: "h1"),
                     HomeRoom(id: "r5", name: L("demo.official.room.frontDoor", "大门"), home: "h1")]
        let accs = [
            acc("o1", L("demo.official.lightsEntry", "玄关灯"), "Lightbulb", [ch("o1a", "power", HomeValue(bool: true)), ch("o1b", "brightness", HomeValue(number: 100))]),
            acc("o2", L("demo.official.intercom", "对讲"), "Speaker", [ch("o2a", "power", HomeValue(bool: false))], room: "r2"),
            acc("o3", L("demo.official.lightsBedroom", "卧室灯"), "Lightbulb", [ch("o3a", "power", HomeValue(bool: true)), ch("o3b", "brightness", HomeValue(number: 100))], room: "r3"),
            acc("o4", L("demo.official.fan", "办公室风扇"), "Fan", [ch("o4a", "power", HomeValue(bool: true))], room: "r4"),
            acc("o5", L("demo.official.lock", "大门门锁"), "Door Lock", [ch("o5a", "lockCurrent", HomeValue(number: 1), w: false), ch("o5b", "lockTarget", HomeValue(number: 1))], room: "r5"),
            acc("o6", L("demo.official.camera", "客厅"), "IP Camera", [], camera: true),
        ]
        let scenes = [HomeScene(id: "os1", name: L("demo.official.goodMorning", "早安"), type: "x", home: "h1")]
        return HomeSnapshot(ready: true, homes: [HomeInfo(id: "h1", name: L("demo.official.homeName", "家"), primary: true)], rooms: rooms, accessories: accs, scenes: scenes)
    }
}
