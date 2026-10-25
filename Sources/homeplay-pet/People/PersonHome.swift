// 2.0 P02：每位家人一份主畫面（HIG › Widgets › Apple HomeView：「每位登錄的家庭成員都有自己個人化的主畫面」；
// 新聞稿：「認出最多六人，每人自訂主畫面的 App 與小工具」）。
//
// - 一份排列＝右上 2×2 的小工具（照片／天氣／世界時鐘，或不放）＋其餘格子的 App 順序；預設照官方（Shell.homeItems 第六輪的那一份）。
// - 用誰的：PersonalGate.avatarPerson（右上頭像那個人：認人開著＝眼前認出的人；沒開＝主人或「換人」提示的人）；
//   訪客或認不出的人用預設，也不能編輯（不替誰改他的主畫面）。--demo-official 用示範的 Erica。
// - 存在 UserDefaults（shell.homeLayouts：人 id → 排列），不含生物特徵；名冊（people.json）不動，人被刪掉時那份排列一起清。
// - 編輯：主畫面長按 0.5 秒進入（Shell.homeEditing），圖示左上「−」拿掉、「＋」開小工具圖庫、右上「完成」離開（Shell/HomeWidgets.swift）。

import AppKit

/// 主畫面右上 2×2 能放的小工具（從 HomePlay 已有的 App 挑：照片、天氣、世界時鐘）
enum HomeWidgetKind: String, Codable, CaseIterable {
    case photos, weather, worldClock

    var item: HomeItem {
        switch self {
        case .photos: return .photos
        case .weather: return .weather
        case .worldClock: return .worldClock
        }
    }
    var title: String {
        switch self {
        case .photos: return L("shell.photos.title", "照片")
        case .weather: return L("shell.weather.title", "天气")
        case .worldClock: return L("app.worldClock", "世界时钟")
        }
    }
    /// 圖庫裡的一句說明（HIG：用動詞開頭，不說「這個小工具」）
    var blurb: String {
        switch self {
        case .photos: return L("home.gallery.photos.blurb", "查看精选照片与回忆。")
        case .weather: return L("home.gallery.weather.blurb", "查看所在地的天气与高低温。")
        case .worldClock: return L("home.gallery.worldClock.blurb", "查看另一个城市现在几点。")
        }
    }
    /// 誰會讀到個人內容（照片是主人的個人內容，交給 PhotosWidget 自己的門）
    static func from(_ item: HomeItem) -> HomeWidgetKind? {
        switch item {
        case .photos: return .photos
        case .weather: return .weather
        case .worldClock: return .worldClock
        default: return nil
        }
    }
}

struct HomeLayout: Codable, Equatable {
    var widget: HomeWidgetKind?
    var apps: [String]

    /// 官方預設（第六輪）：左上 FaceTime／家庭／音樂／訊息，右上照片，第三列鬧鐘、行事曆、Podcast、提醒事項
    static let official = HomeLayout(widget: .photos, apps: ["facetime", "home", "music", "messages", "alarms", "calendar", "podcasts", "reminders"])

    /// 有小工具時 App 的格子（右上 2×2 讓給小工具）；沒有就是 4×3 全部
    static let slotsWithWidget = [(0, 0), (1, 0), (0, 1), (1, 1), (0, 2), (1, 2), (2, 2), (3, 2)]
    static let slotsAll = (0..<3).flatMap { r in (0..<4).map { c in (c, r) } }
    var slots: [(Int, Int)] { widget == nil ? Self.slotsAll : Self.slotsWithWidget }

    /// 格子 → 主畫面上的位置（Shell 的網格）
    func items() -> [(CGRect, HomeItem)] {
        var out: [(CGRect, HomeItem)] = []
        if let w = widget { out.append((Shell.widgetRect(col: 2, row: 0), w.item)) }
        let s = slots
        for (i, id) in apps.enumerated() where i < s.count && AppRegistry.app(id) != nil && !AppRegistry.hidden.contains(id) {
            out.append((Shell.cell(s[i].0, s[i].1), .app(id)))
        }
        return out
    }
    /// 拿掉一個 App；後面的往前補
    mutating func remove(app id: String) { apps.removeAll { $0 == id } }
    /// 換小工具（nil＝拿掉）；放小工具時格子變少，多出來的 App 收回「全部 App」（不刪 App）
    mutating func setWidget(_ k: HomeWidgetKind?) {
        widget = k
        if apps.count > slots.count { apps = Array(apps.prefix(slots.count)) }
    }
    var fingerprint: String { "\(widget?.rawValue ?? "-")|\(apps.joined(separator: ","))" }
}

enum PersonHome {
    static let key = "shell.homeLayouts"
    /// selftest 時關掉寫檔
    nonisolated(unsafe) static var persist = true
    nonisolated(unsafe) static var layouts: [String: HomeLayout] = {
        guard let raw = UserDefaults.standard.data(forKey: key), let d = try? JSONDecoder().decode([String: HomeLayout].self, from: raw) else { return [:] }
        return d.mapValues(migrate)
    }()
    /// 2.0 P10：食譜併進 Safari——存過的排列裡的「食譜」換成 Safari（已經有 Safari 就拿掉）
    static func migrate(_ l: HomeLayout) -> HomeLayout {
        var l = l
        guard let i = l.apps.firstIndex(of: "recipes") else { return l }
        if l.apps.contains("safari") { l.apps.remove(at: i) } else { l.apps[i] = "safari" }
        l.apps.removeAll { $0 == "recipes" }
        return l
    }
    /// 快照與 selftest：指定現在是誰在看（--home-viewer <person id>）
    nonisolated(unsafe) static var viewerOverride: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--home-viewer"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    /// 現在主畫面是誰的（nil＝訪客或認不出：用預設、不能編輯）
    static var viewerID: String? {
        if let v = viewerOverride { return v }
        if let d = Shell.demoPerson { return d.id }
        let reg = PeopleRegistry.shared
        return PersonalGate.avatarPerson(PersonalGate.inputs, people: reg.people, owner: reg.owner)?.id
    }
    static func layout(for id: String?) -> HomeLayout {
        guard let id, let l = layouts[id] else { return .official }
        return l
    }
    static var current: HomeLayout {
        var l = layout(for: viewerID)
        if let w = widgetOverride { l.setWidget(HomeWidgetKind(rawValue: w)) }   // 快照：--home-widget photos|weather|worldClock|none
        return l
    }
    static let widgetOverride: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--home-widget"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
    static var canEdit: Bool { viewerID != nil && !Shell.guestMode && !OfficialDemo.on }

    static func set(_ l: HomeLayout, for id: String) {
        layouts[id] = l == .official ? nil : l
        save()
        Shell.homeLayer = nil
    }
    /// 名冊裡已經沒有的人：那份排列一起清掉
    static func prune(keeping ids: Set<String>) {
        let before = layouts.count
        layouts = layouts.filter { ids.contains($0.key) }
        if layouts.count != before { save() }
    }
    private static func save() {
        guard persist else { return }
        if let raw = try? JSONEncoder().encode(layouts) { UserDefaults.standard.set(raw, forKey: key) }
    }

    // MARK: selftest

    static func selftest(_ check: (Bool, String) -> Void) {
        let saved = (layouts, viewerOverride, persist)
        defer { layouts = saved.0; viewerOverride = saved.1; persist = saved.2; Shell.homeLayer = nil }
        persist = false
        layouts = [:]
        var bo = HomeLayout.official
        bo.setWidget(.weather); bo.remove(app: "messages")
        set(bo, for: "kid")
        viewerOverride = "owner"
        let a = Shell.homeItems()
        viewerOverride = "kid"
        let b = Shell.homeItems()
        func ids(_ xs: [(CGRect, HomeItem)]) -> [HomeItem] { xs.map(\.1) }
        check(ids(a) != ids(b) && ids(b).first == .weather && !ids(b).contains(.app("messages")) && ids(a).first == .photos,
              "每人主畫面：切換 viewer，homeItems 跟著換（主人照片、孩子天氣且沒有訊息）")   // l10n-ignore：selftest 訊息
        viewerOverride = "nobody-registered"
        check(ids(Shell.homeItems()) == ids(HomeLayout.official.items()), "每人主畫面：沒存過的人用官方預設")
        set(.official, for: "kid")
        check(layouts["kid"] == nil, "每人主畫面：改回預設就不另外存")
        var none = HomeLayout.official
        none.setWidget(nil)
        check(none.slots.count == 12 && none.items().count == 8, "每人主畫面：拿掉小工具，格子變 4×3")
        var back = none
        back.apps += ["timers", "worldclock", "weather", "safari"]
        back.setWidget(.photos)
        check(back.apps.count == 8, "每人主畫面：放回小工具，多出來的 App 收回全部 App")
        let old = HomeLayout(widget: .photos, apps: ["facetime", "recipes", "music"]), both = HomeLayout(widget: nil, apps: ["safari", "recipes"])
        check(migrate(old).apps == ["facetime", "safari", "music"] && migrate(both).apps == ["safari"] && migrate(.official) == .official,
              "每人主畫面：存過的「食譜」換成 Safari（已有 Safari 就拿掉）")   // l10n-ignore：selftest 訊息
        layouts = ["gone": bo, "kid": bo]
        prune(keeping: ["kid"])
        check(layouts.keys.sorted() == ["kid"], "每人主畫面：名冊刪掉的人，那份排列一起清")
    }
}
