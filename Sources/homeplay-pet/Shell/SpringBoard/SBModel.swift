// 2.0 SpringBoard：主畫面的排列模型（純邏輯，不碰 AppKit 畫面；--selftest 直接驗）。
//
// 依據（hpds.md 的優先順序：官方 HomeView → KOL → iOS 27 推斷）：
// - 官方：4 欄、App 圖示與小工具混排（官方主畫面的「照片」是 2×2）；KOL 實拍看得到 2×1 的 Podcast／正在播放小工具（handson.md 照片 B、C）。
// - iOS 27（本機模擬器 realref/ios27）：編輯模式、拖曳時其他圖示讓開（照閱讀順序往空位補）、可以留空格（iOS 18 起）、
//   滿頁時被擠出去的移到下一頁開頭、拖到螢幕邊停一下翻頁、圖示疊到圖示上做資料夾、Smart Stack、App 資料庫。
// - 1:1 螢幕：每頁 4 欄 × 3 列（第五輪量到的官方網格，HPTokens.Home）。所以 iOS 的「大」（4×4）在這裡是 4×3（整頁），
//   沒有「特大」（放不下）；另外多一個官方實拍有的 2×1「寬」。
//
// 模型：一頁＝一串有順序的項目（App、小工具、Smart Stack、資料夾、空格）。版面＝照順序「從頭找第一個放得下的位置」排進格子；
// 拖曳＝把被拖的那個插到某個位置，讓它剛好落在手指指的格子，挑「其他項目移動最少」的那個插法——
// 所以中間有空格就直接放（不擠別人）、放在別人身上就照閱讀順序一格一格讓開（iOS 的 reflow）；擠不下的移到下一頁。

import Foundation

/// 小工具的大小（欄 × 列）
enum SBWidgetSize: String, Codable, CaseIterable {
    case wide, small, medium, large
    var span: (w: Int, h: Int) {
        switch self {
        case .wide: return (2, 1)
        case .small: return (2, 2)
        case .medium: return (4, 2)
        case .large: return (4, 3)
        }
    }
    var title: String {
        switch self {
        case .wide: return L("sb.size.wide", "宽")
        case .small: return L("sb.size.small", "小")
        case .medium: return L("sb.size.medium", "中")
        case .large: return L("sb.size.large", "大")
        }
    }
    /// 圖庫、右鍵選單裡的尺寸符號
    var symbol: String {
        switch self {
        case .wide: return "rectangle"
        case .small: return "square"
        case .medium: return "rectangle.split.2x1"
        case .large: return "rectangle.split.2x2"
        }
    }
    static func of(span w: Int, _ h: Int) -> SBWidgetSize? { allCases.first { $0.span.w == w && $0.span.h == h } }
}

/// 小工具種類：HomePlay 已有的 App 都給一個
enum SBWidgetKind: String, Codable, CaseIterable {
    case photos, weather, calendar, reminders, music, podcasts, home, worldClock, timers, alarms, findMy, batteries
    case desktopWidgets   // SideShow 致敬：Mac 桌面上系統畫好的小工具（螢幕錄製擷取，Shell/DesktopWidgets.swift）
    case webApp   // 2.0 Web App：config["app"]＝哪個 Web App、config["tag"]＝manifest widgets 的 tag（Shell/WebApps/AdaptiveCards.swift）

    /// 點小工具打開哪個 App（電池沒有 App：打開控制中心那一層不合適，就不開）
    var appID: String? {
        switch self {
        case .photos: return nil   // 照片：照 PhotosWidget 原本的點按（權限卡／換下一張）
        case .weather: return "weather"
        case .calendar: return "calendar"
        case .reminders: return "reminders"
        case .music: return "music"
        case .podcasts: return "podcasts"
        case .home: return "home"
        case .worldClock: return "worldclock"
        case .timers: return "timers"
        case .alarms: return "alarms"
        case .findMy: return "findmy"
        case .batteries: return nil
        case .webApp: return nil   // 照 config["app"]
        case .desktopWidgets: return nil   // 照點到的那一個系統小工具開對應的 Mac App
        }
    }
    /// 這個種類有哪些大小（照 iOS 同名小工具；放得下又有意義的才給）
    var sizes: [SBWidgetSize] {
        switch self {
        case .photos, .weather, .calendar, .music, .home, .worldClock, .batteries: return [.small, .wide, .medium, .large]
        case .podcasts, .timers: return [.small, .wide, .medium]
        case .reminders, .findMy: return [.small, .medium, .large]
        case .alarms: return [.small, .wide, .medium]
        case .webApp: return [.small, .wide, .medium, .large]
        case .desktopWidgets: return [.small, .wide, .medium, .large]
        }
    }
    /// 個人內容（訪客、認不出的人看到「需要主人」；PersonalGate）
    var personal: Bool { self == .calendar || self == .reminders || self == .findMy || self == .desktopWidgets }   // 桌面小工具可能是行事曆、提醒事項
}

struct SBWidget: Codable, Equatable {
    var id: String
    var kind: SBWidgetKind
    var size: SBWidgetSize
    /// Edit Widget 的選項（城市、相簿、房間、行事曆…）：選項 key → 值
    var config: [String: String] = [:]
}

/// Smart Stack：同大小的幾個小工具疊在一起，上下滑換；智慧型旋轉照時段換到最相關的那個
struct SBStack: Codable, Equatable {
    var id: String
    var size: SBWidgetSize
    var widgets: [SBWidget]
    var index = 0
    var smartRotate = true
    var suggestions = true

    /// 智慧型旋轉：照時段挑（早上天氣、白天行事曆／提醒、晚上音樂／照片、深夜時鐘）；有計時器在跑而且開了小工具建議就先給計時器
    static func preferred(hour: Int) -> [SBWidgetKind] {
        switch hour {
        case 5..<10: return [.weather, .calendar, .reminders]
        case 10..<17: return [.calendar, .reminders, .weather]
        case 17..<22: return [.music, .photos, .podcasts]
        default: return [.worldClock, .alarms, .photos]
        }
    }
    func rotatedIndex(hour: Int) -> Int {
        for k in Self.preferred(hour: hour) { if let i = widgets.firstIndex(where: { $0.kind == k }) { return i } }
        return index
    }
    /// 小工具建議：疊放裡沒有、但現在正相關的（計時器在跑＝計時器；音樂在播＝音樂）
    func suggestion(timerRunning: Bool, musicPlaying: Bool) -> SBWidgetKind? {
        guard suggestions else { return nil }
        if timerRunning, size.span.h <= 2, SBWidgetKind.timers.sizes.contains(size), !widgets.contains(where: { $0.kind == .timers }) { return .timers }
        if musicPlaying, SBWidgetKind.music.sizes.contains(size), !widgets.contains(where: { $0.kind == .music }) { return .music }
        return nil
    }
}

/// Smart Stack 的「急事插隊」：狀態一變（計時器開始／音樂開播／鬧鐘響）就轉到對應小工具，不等定時檢查。
/// 純邏輯、不碰 UI；SBBoard.tick 每幀餵狀態，只在「狀態轉換」那一幀可能回傳新的 index。
enum SmartStackPolicy {
    /// 手動翻頁後這麼久不被自動轉回去（秒）
    static let manualHold = 600.0
    /// 急事都結束這麼久才回到時段排序（秒）
    static let idleReturn = 300.0

    struct State: Equatable {
        var timer = false
        var music = false
        var alarm = false
        /// 距離「沒有任何急事」已經多久（秒）；仍有急事就是 0
        var idleFor = 0.0
        var urgent: Bool { timer || music || alarm }
    }

    /// 回傳該轉到的 index；nil＝不動。優先序：鬧鐘 > 計時器 > 音樂
    static func next(current: Int, widgets: [SBWidget], state: State, prev: State,
                     manualAt: Double?, now: Double, hour: Int) -> Int? {
        if let m = manualAt, now - m < manualHold { return nil }
        // 狀態轉換：剛出現的急事，疊放裡有那個 kind 才轉（沒有就交給 suggestion）
        let rising: [(Bool, SBWidgetKind)] = [(state.alarm && !prev.alarm, .alarms), (state.timer && !prev.timer, .timers), (state.music && !prev.music, .music)]
        for (on, k) in rising where on {
            if let i = widgets.firstIndex(where: { $0.kind == k }) { return i == current ? nil : i }
        }
        // 計時器剛到點（消失）：轉去看結果，之後照急事結束的規則回去
        if prev.timer && !state.timer, let i = widgets.firstIndex(where: { $0.kind == .timers }), !state.urgent { return i == current ? nil : i }
        // 急事結束夠久，而且還停在急事的小工具上 → 回時段排序
        if !state.urgent, state.idleFor > idleReturn, widgets.indices.contains(current),
           [.timers, .music, .alarms].contains(widgets[current].kind) {
            let probe = SBStack(id: "", size: .small, widgets: widgets, index: current)
            let r = probe.rotatedIndex(hour: hour)
            return r == current ? nil : r
        }
        return nil
    }
}

struct SBFolder: Codable, Equatable {
    var id: String
    var name: String
    var apps: [String]
    /// 資料夾開著時一頁 3×3
    static let pageSize = 9
}

enum SBItem: Codable, Equatable {
    case app(String)
    case widget(SBWidget)
    case stack(SBStack)
    case folder(SBFolder)
    case spacer

    var span: (w: Int, h: Int) {
        switch self {
        case .app, .folder, .spacer: return (1, 1)
        case .widget(let w): return w.size.span
        case .stack(let s): return s.size.span
        }
    }
    /// 動畫與比對用的身分；空格沒有
    var key: String? {
        switch self {
        case .app(let id): return "a:\(id)"
        case .widget(let w): return "w:\(w.id)"
        case .stack(let s): return "s:\(s.id)"
        case .folder(let f): return "f:\(f.id)"
        case .spacer: return nil
        }
    }
    var isSpacer: Bool { self == .spacer }
    var isIcon: Bool { switch self { case .app, .folder: return true; default: return false } }
    /// 這一格（含資料夾裡）有哪些 App
    var apps: [String] {
        switch self {
        case .app(let id): return [id]
        case .folder(let f): return f.apps
        default: return []
        }
    }
}

struct SBPlacement: Equatable {
    var item: SBItem
    var col: Int, row: Int
    var w: Int { item.span.w }
    var h: Int { item.span.h }
    func contains(col c: Int, row r: Int) -> Bool { c >= col && c < col + w && r >= row && r < row + h }
}

struct SBPage: Codable, Equatable {
    var items: [SBItem]
    var hidden = false
    var isEmpty: Bool { items.allSatisfy(\.isSpacer) }
}

struct SBLayout: Codable, Equatable {
    var version = 2
    var pages: [SBPage]

    static let cols = 4, rows = 3

    // MARK: 排版

    /// 照順序排進 4×3：每一個放在「從頭找第一個放得下」的位置；放不下的回 overflow（照原順序）
    static func pack(_ items: [SBItem]) -> (placed: [SBPlacement], overflow: [SBItem]) {
        let r = packIndexed(items)
        return (r.placed, r.overflow.map { items[$0] })
    }
    /// 同上，擠不下的回索引（normalize 用索引分，不靠值相等：空格都長一樣）
    static func packIndexed(_ items: [SBItem]) -> (placed: [SBPlacement], overflow: [Int]) {
        var used = [Bool](repeating: false, count: cols * rows)
        var placed: [SBPlacement] = [], overflow: [Int] = []
        func fits(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> Bool {
            guard c + w <= cols, r + h <= rows else { return false }
            for y in r..<(r + h) { for x in c..<(c + w) where used[y * cols + x] { return false } }
            return true
        }
        for (idx, it) in items.enumerated() {
            let (w, h) = it.span
            var spot: (Int, Int)?
            search: for r in 0..<rows { for c in 0..<cols where fits(c, r, w, h) { spot = (c, r); break search } }
            guard let (c, r) = spot else { overflow.append(idx); continue }
            for y in r..<(r + h) { for x in c..<(c + w) { used[y * cols + x] = true } }
            placed.append(SBPlacement(item: it, col: c, row: r))
        }
        return (placed, overflow)
    }

    /// 尾巴的空格拿掉（不影響任何位置）
    static func trimmed(_ items: [SBItem]) -> [SBItem] {
        var xs = items
        while xs.last == .spacer { xs.removeLast() }
        return xs
    }

    /// 擠不下的往下一頁開頭移（一路往後推，必要時加新頁）；尾巴空格拿掉。dropEmpty＝拿掉空頁（第一頁留著）
    mutating func normalize(dropEmpty: Bool = false) {
        var i = 0
        while i < pages.count {
            let overIdx = Set(Self.packIndexed(pages[i].items).overflow)
            if !overIdx.isEmpty {
                // 留下放得進的（保持順序），擠出去的接到下一頁最前面（空格不往後帶）；下一頁是隱藏的就在它前面開一頁
                let over = pages[i].items.enumerated().filter { overIdx.contains($0.offset) && !$0.element.isSpacer }.map(\.element)
                pages[i].items = pages[i].items.enumerated().filter { !overIdx.contains($0.offset) }.map(\.element)
                if !over.isEmpty {
                    if i + 1 >= pages.count || (pages[i + 1].hidden && !pages[i].hidden) { pages.insert(SBPage(items: []), at: i + 1) }
                    pages[i + 1].items = over + pages[i + 1].items
                }
                continue   // 同一頁再排一次（拿掉後剩下的一定放得下）
            }
            pages[i].items = Self.trimmed(pages[i].items)
            i += 1
        }
        if dropEmpty {
            let first = pages.first
            pages = pages.enumerated().filter { $0.offset == 0 || !$0.element.isEmpty }.map(\.element)
            if pages.isEmpty, let first { pages = [first] }
        }
        if pages.isEmpty { pages = [SBPage(items: [])] }
    }

    // MARK: 拖放

    /// 把 dragged 放到這一頁、讓它的左上角落在 target（欄、列）。
    /// items＝這一頁「沒有被拖的那個」的項目；hole＝被拖的原本在這一頁的第幾個（同一頁才有）；
    /// reference＝拖之前這一頁其他項目的位置（key → 欄列），用來算「別人移動了多少」。
    /// 回傳新的這一頁（可能比放得下的多：呼叫端 normalize 把多的推到下一頁）。
    static func drop(_ dragged: SBItem, into items: [SBItem], at target: (col: Int, row: Int), hole: Int? = nil,
                     reference: [String: (Int, Int)]) -> [SBItem] {
        let (w, h) = dragged.span
        let tc = max(0, min(cols - w, target.col)), tr = max(0, min(rows - h, target.row))
        var bases = [items]
        if let hole { var b = items; b.insert(.spacer, at: min(hole, b.count)); bases.append(b) }
        var best: (list: [SBItem], cost: Double, hit: Bool)?
        func consider(_ list: [SBItem]) {
            let (placed, over) = pack(list)
            guard let me = placed.first(where: { $0.item == dragged }) else { return }
            let hit = me.col == tc && me.row == tr
            var cost = 0.0
            for p in placed {
                guard p.item != dragged, let k = p.item.key, let ref = reference[k] else { continue }
                cost += Double(abs(p.col - ref.0) + abs(p.row - ref.1))
            }
            cost += Double(over.filter { !$0.isSpacer }.count) * 500   // 擠到下一頁是硬偏好：寧可多讓幾格（Launcher3 也是先 push 再溢出）
            cost += Double(list.filter(\.isSpacer).count) * 0.01
            if !hit { cost += 100_000 + Double(abs(me.col - tc) + abs(me.row - tr)) * 10 }
            if best == nil || cost < best!.cost { best = (list, cost, hit) }   // 同分取先試的（固定順序，不靠雜湊）：不會來回跳
        }
        for base in bases {
            for i in 0...base.count { var l = base; l.insert(dragged, at: i); consider(l) }
            for i in base.indices where base[i] == .spacer { var l = base; l[i] = dragged; consider(l) }
            for k in 1...(cols * rows) { consider(base + Array(repeating: .spacer, count: k) + [dragged]) }
        }
        return trimmed(best?.list ?? items + [dragged])
    }

    /// 這一頁每個項目的位置（key → 欄列）
    static func positions(_ items: [SBItem]) -> [String: (Int, Int)] {
        var out: [String: (Int, Int)] = [:]
        for p in pack(items).placed { if let k = p.item.key { out[k] = (p.col, p.row) } }
        return out
    }

    // MARK: 查找與修改

    /// key 在哪一頁第幾個
    func locate(_ key: String) -> (page: Int, index: Int)? {
        for (pi, p) in pages.enumerated() { if let i = p.items.firstIndex(where: { $0.key == key }) { return (pi, i) } }
        return nil
    }
    /// App 在哪（主畫面或資料夾裡）
    func locateApp(_ id: String) -> (page: Int, index: Int, folder: String?)? {
        for (pi, p) in pages.enumerated() {
            for (i, it) in p.items.enumerated() {
                if case .app(let a) = it, a == id { return (pi, i, nil) }
                if case .folder(let f) = it, f.apps.contains(id) { return (pi, i, f.id) }
            }
        }
        return nil
    }
    func item(_ key: String) -> SBItem? { locate(key).map { pages[$0.page].items[$0.index] } }

    /// 拿掉 key 那一項（留下的不補空格：iOS 拿掉後後面的往前補）
    @discardableResult
    mutating func remove(_ key: String) -> SBItem? {
        guard let (p, i) = locate(key) else { return nil }
        return pages[p].items.remove(at: i)
    }
    /// 換掉 key 那一項（例如小工具改大小、資料夾改名）
    mutating func replace(_ key: String, with it: SBItem) {
        guard let (p, i) = locate(key) else { return }
        pages[p].items[i] = it
    }
    /// 主畫面（含資料夾）上的全部 App
    var appsOnHome: Set<String> { Set(pages.flatMap { $0.items.flatMap(\.apps) }) }
    /// 從主畫面移除 App（資料夾裡的也拿掉；資料夾剩一個就拆回圖示，跟 iOS 一樣）
    mutating func removeApp(_ id: String) {
        for p in pages.indices {
            pages[p].items = pages[p].items.compactMap { it in
                switch it {
                case .app(let a): return a == id ? nil : it
                case .folder(var f):
                    f.apps.removeAll { $0 == id }
                    if f.apps.isEmpty { return nil }
                    if f.apps.count == 1 { return .app(f.apps[0]) }
                    return .folder(f)
                default: return it
                }
            }
        }
    }
    /// 加回主畫面：放在最後一頁（沒隱藏的）第一個空位；滿了就開新的一頁（iOS 從 App 資料庫加回的行為）
    mutating func addApp(_ id: String) {
        guard !appsOnHome.contains(id) else { return }
        let target = pages.lastIndex { !$0.hidden } ?? 0
        if pages.isEmpty { pages = [SBPage(items: [])] }
        let (placed, _) = Self.pack(pages[target].items)
        let full = placed.reduce(0) { $0 + $1.w * $1.h } >= Self.cols * Self.rows
        if full { pages.insert(SBPage(items: [.app(id)]), at: target + 1) } else { pages[target].items.append(.app(id)) }
        normalize()
    }
    /// 加小工具：放在這一頁最前面（iOS「加入小工具」放在目前這頁的左上，其他往後讓）
    mutating func addWidget(_ it: SBItem, page: Int) {
        let p = max(0, min(pages.count - 1, page))
        pages[p].items.insert(it, at: 0)
        normalize()
    }

    // MARK: 資料夾

    /// 把 App（或另一個資料夾的內容）疊到 targetKey 那個圖示上：目標是 App＝做新資料夾（名字照類別），目標是資料夾＝加進去
    mutating func merge(_ dragged: SBItem, onto targetKey: String, newID: String) -> String? {
        guard let (p, i) = locate(targetKey) else { return nil }
        let incoming = dragged.apps
        guard !incoming.isEmpty else { return nil }
        switch pages[p].items[i] {
        case .app(let a):
            let apps = [a] + incoming.filter { $0 != a }
            pages[p].items[i] = .folder(SBFolder(id: newID, name: Self.folderName(apps), apps: apps))
            return newID
        case .folder(var f):
            let add = incoming.filter { !f.apps.contains($0) }
            guard f.apps.count + add.count <= SBFloaty.maxApps else { return nil }   // 浮動資料夾：一頁 3×3、最多四頁（滿了就當一般放下）
            f.apps += add
            pages[p].items[i] = .folder(f)
            return f.id
        default: return nil
        }
    }
    /// 資料夾預設名字：照 App 的類別（跟 iOS 用 App Store 類別一樣）；混在一起就「工具」以外的第一個多數
    static func folderName(_ apps: [String]) -> String {
        func cat(_ id: String) -> String {
            switch id {
            case "music", "podcasts", "photos", "sing", "games": return L("sb.folder.entertainment", "娱乐")
            case "messages", "facetime", "intercom", "contacts": return L("sb.folder.social", "社交")
            case "calendar", "reminders", "safari", "cliotalk": return L("sb.folder.productivity", "效率")
            case "home", "weather", "findmy", "recipes", "carplay": return L("sb.folder.lifestyle", "生活")
            default: return L("sb.folder.utilities", "工具")
            }
        }
        var count: [String: Int] = [:]
        for a in apps { count[cat(a), default: 0] += 1 }
        return count.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? L("sb.folder.utilities", "工具")
    }

    // MARK: 預設與遷移

    /// 預設第二頁：HomePlay 自己的 App（2026-11-06 拍板；第一頁照官方不動）
    static let homePlayPage = ["carplay", "weather", "timers", "worldclock", "safari", "recipes", "sing", "games", "contacts", "findmy"]
    /// 預設：第一頁照官方（第六輪：左上 FaceTime／家庭／音樂／訊息，右上 2×2 照片，第三列鬧鐘、行事曆、Podcast、提醒事項），
    /// 第二頁 homePlayPage。沒自訂過的人（存檔裡沒有排列）直接拿到這份；自訂過的照存檔，不動。
    static let official: SBLayout = {
        var l = migrate(.official)
        l.pages.append(SBPage(items: homePlayPage.filter { AppRegistry.app($0) != nil && !AppRegistry.hidden.contains($0) }.map { .app($0) }))
        l.normalize()
        return l
    }()

    /// P02 的舊排列（右上 2×2 一個小工具＋App 照格子順序）→ 一頁：
    /// 前兩個 App、小工具（落在右上 2×2）、其餘 App；超過一頁的推到第二頁（舊版是直接收回 App 資料庫）
    static func migrate(_ old: HomeLayout) -> SBLayout {
        var items: [SBItem] = old.apps.filter { AppRegistry.app($0) != nil && !AppRegistry.hidden.contains($0) }.map { .app($0) }
        if let w = old.widget {
            let wk: SBWidgetKind = { switch w { case .photos: return .photos; case .weather: return .weather; case .worldClock: return .worldClock } }()
            let widget = SBItem.widget(SBWidget(id: "w-\(wk.rawValue)", kind: wk, size: .small))
            while items.count < 2 { items.append(.spacer) }
            items.insert(widget, at: 2)
        }
        var l = SBLayout(pages: [SBPage(items: items)])
        l.normalize()
        return l
    }

    /// 提供者（iPhone App、Web App）的 id：認不認得要看背景掃描與檔案讀得到沒有，暫時認不得不代表 App 沒了，
    /// 所以存檔清理時照留（畫面上先不畫）；使用者自己移除、刪掉 Web App 時各自從排列拿掉
    static func isProviderID(_ id: String) -> Bool { id.hasPrefix("iphone:") || id.hasPrefix(WebApp.idPrefix) }
    /// 清理時留不留這個 App：內建 App 要還在；提供者的 id 一律留
    static func keeps(_ id: String) -> Bool {
        if isProviderID(id) { return true }
        return AppRegistry.app(id) != nil && !AppRegistry.hidden.contains(id)
    }

    /// 存檔裡有已經不存在的內建 App（改版拿掉了）就清掉；食譜被藏起來的那幾版（併進 Safari）存的換成 Safari——
    /// 食譜現在是獨立 App（WP5），沒藏就照留，不然自訂過再存的食譜會被吃掉。
    /// iPhone App 與 Web App 認不得時照留（背景掃描暫時沒結果、檔案暫時讀不到時不能把它從主畫面永久刪掉）
    mutating func sanitize() {
        for p in pages.indices {
            var seen = Set<String>()
            pages[p].items = pages[p].items.compactMap { it in
                switch it {
                case .app(var id):
                    if id == "recipes", AppRegistry.hidden.contains("recipes") { id = "safari" }
                    guard Self.keeps(id), !seen.contains(id) else { return nil }
                    seen.insert(id); return .app(id)
                case .folder(var f):
                    f.apps = f.apps.map { $0 == "recipes" && AppRegistry.hidden.contains("recipes") ? "safari" : $0 }.filter { Self.keeps($0) && !seen.contains($0) }
                    f.apps.forEach { seen.insert($0) }
                    if f.apps.isEmpty { return nil }
                    return .folder(f)
                case .stack(let s) where s.widgets.isEmpty: return nil
                default: return it
                }
            }
        }
        normalize()
    }

    var fingerprint: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// MARK: - 每人一份（存 UserDefaults：shell.homeLayouts.v2；舊的 shell.homeLayouts 留著不刪，會自動遷移）

enum SBStore {
    static let key = "shell.homeLayouts.v2"
    nonisolated(unsafe) static var persist = true
    nonisolated(unsafe) static var layouts: [String: SBLayout] = load(UserDefaults.standard.data(forKey: key))
    /// 讀不回來的那幾份（例如將來的版本存的）：原樣留著，存檔時照寫回去，不覆寫掉
    nonisolated(unsafe) static var unreadable: [String: Any] = [:]
    /// 逐人解碼：一份壞掉不影響其他人
    static func load(_ raw: Data?) -> [String: SBLayout] {
        guard let raw, let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return [:] }
        var out: [String: SBLayout] = [:]
        for (id, v) in obj {
            if let d = try? JSONSerialization.data(withJSONObject: v), var l = try? JSONDecoder().decode(SBLayout.self, from: d) { l.sanitize(); out[id] = l }
            else { unreadable[id] = v }
        }
        return out
    }
    nonisolated(unsafe) static var idCounter = 0
    /// 新項目的 id（小工具、疊放、資料夾）
    static func newID(_ prefix: String) -> String {
        idCounter += 1
        return "\(prefix)\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000)-\(idCounter)"
    }

    /// 某人的排列：存過新版的用新版；只有舊版（P02）就遷移；都沒有用官方預設
    static func layout(for id: String?) -> SBLayout {
        guard let id else { return .official }
        if let l = layouts[id] { return l }
        if let old = PersonHome.layouts[id] { return SBLayout.migrate(old) }
        return .official
    }
    static func set(_ l: SBLayout, for id: String) {
        var l = l
        l.normalize(dropEmpty: false)
        layouts[id] = l == .official ? nil : l
        unreadable[id] = nil   // 本人改過了（含改回預設）：讀不懂的舊那份不再寫回
        save()
    }
    /// 還原預設：新舊兩份都清
    static func reset(_ id: String) {
        layouts[id] = nil
        unreadable[id] = nil
        PersonHome.layouts[id] = nil
        save()
    }
    static func prune(keeping ids: Set<String>) {
        let before = layouts.count + unreadable.count
        layouts = layouts.filter { ids.contains($0.key) }
        unreadable = unreadable.filter { ids.contains($0.key) }   // 名冊刪掉的人：讀不懂的那份也一起清
        if layouts.count + unreadable.count != before { save() }
    }
    static func save() {
        guard persist else { return }
        guard let raw = try? JSONEncoder().encode(layouts), var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return }
        for (id, v) in unreadable where obj[id] == nil { obj[id] = v }
        if let out = try? JSONSerialization.data(withJSONObject: obj) { UserDefaults.standard.set(out, forKey: key) }
    }
    static func encoded(_ ls: [String: SBLayout]) -> Data? { try? JSONEncoder().encode(ls) }
    static func decoded(_ d: Data) -> [String: SBLayout]? { try? JSONDecoder().decode([String: SBLayout].self, from: d) }
}

// MARK: - selftest

enum SBModelSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias Lay = SBLayout
        func ids(_ xs: [SBItem]) -> [String] { xs.compactMap(\.key) }
        func pos(_ xs: [SBItem], _ k: String) -> (Int, Int)? { Lay.positions(xs)[k] }
        let apps = (0..<12).map { SBItem.app("x\($0)") }

        // 官方預設：舊版第六輪的格子一格不差
        let off = Lay.official
        let place = Lay.positions(off.pages[0].items)
        check(off.pages.count == 2 && place["a:facetime"]! == (0, 0) && place["a:home"]! == (1, 0) && place["w:w-photos"]! == (2, 0)
              && place["a:music"]! == (0, 1) && place["a:messages"]! == (1, 1) && place["a:alarms"]! == (0, 2) && place["a:reminders"]! == (3, 2),
              "SpringBoard：官方預設＝FaceTime／家庭／音樂／訊息＋右上照片 2×2＋第三列四個")   // l10n-ignore：selftest 訊息
        // 第二頁：HomePlay 的 App，照拍板的順序，跟第一頁不重複
        let p2 = off.pages[1].items.compactMap { if case .app(let a) = $0 { return a }; return nil }
        let p1 = Set(off.pages[0].items.compactMap { if case .app(let a) = $0 { return a }; return nil })
        check(p2 == Lay.homePlayPage && p2.count == 10 && p1.isDisjoint(with: p2) && Lay.pack(off.pages[1].items).overflow.isEmpty,
              "SpringBoard：預設第二頁＝CarPlay、天氣、計時器、世界時鐘、Safari、食譜、跟唱、遊戲、通訊錄、尋找")   // l10n-ignore：selftest 訊息
        let fun = L("sb.folder.entertainment", "娱乐"), social = L("sb.folder.social", "社交"), tools = L("sb.folder.utilities", "工具")
        check(Lay.folderName(["sing", "games"]) == fun && Lay.folderName(["contacts", "facetime"]) == social
              && ["sing", "games", "contacts", "recipes", "carplay"].allSatisfy { Lay.folderName([$0]) != tools },
              "SpringBoard：跟唱、遊戲歸娛樂，通訊錄歸社交，不落到「工具」")   // l10n-ignore：selftest 訊息

        // reflow：A 拖到 D 的位置，B C D 各往前一格（iOS 照閱讀順序讓開）
        let five = Array(apps.prefix(5))
        let ref = Lay.positions(five)
        let moved = Lay.drop(five[0], into: Array(five.dropFirst()), at: (3, 0), hole: 0, reference: ref)
        check(pos(moved, "a:x0")! == (3, 0) && pos(moved, "a:x1")! == (0, 0) && pos(moved, "a:x3")! == (2, 0) && pos(moved, "a:x4")! == (0, 1),
              "SpringBoard：拖到別人身上，中間的照閱讀順序讓開（\(ids(moved))）")   // l10n-ignore：selftest 訊息
        // 空格：拖到空位不擠任何人（iOS 18 起可以留空格）
        let gap = Lay.drop(five[0], into: Array(five.dropFirst()), at: (2, 2), hole: 0, reference: ref)
        check(pos(gap, "a:x0")! == (2, 2) && pos(gap, "a:x1")! == (1, 0) && pos(gap, "a:x4")! == (0, 1),
              "SpringBoard：放到空格，其他都不動（\(gap.map { $0.key ?? "_" })）")   // l10n-ignore：selftest 訊息
        // 碰撞：2×2 小工具放到圖示上，圖示讓開，不重疊
        let w = SBItem.widget(SBWidget(id: "t", kind: .weather, size: .small))
        let withW = Lay.drop(w, into: Array(apps.prefix(6)), at: (0, 0), reference: Lay.positions(Array(apps.prefix(6))))
        let pl = Lay.pack(withW).placed
        var cells = Set<Int>(), overlap = false
        for p in pl { for y in p.row..<(p.row + p.h) { for x in p.col..<(p.col + p.w) { if !cells.insert(y * 4 + x).inserted { overlap = true } } } }
        check(pos(withW, "w:t")! == (0, 0) && !overlap && Lay.pack(withW).overflow.isEmpty, "SpringBoard：小工具放在圖示上，圖示讓開、不重疊")
        // 滿頁：再放一個，最後一個推到下一頁開頭
        var full = Lay(pages: [SBPage(items: Array(apps.prefix(12))), SBPage(items: [.app("y")])])
        let extra = SBItem.app("new")
        full.pages[0].items = Lay.drop(extra, into: full.pages[0].items, at: (0, 0), reference: Lay.positions(full.pages[0].items))
        full.normalize()
        check(full.pages[0].items.count == 12 && pos(full.pages[0].items, "a:new")! == (0, 0) && full.pages[1].items.first == .app("x11") && full.pages[1].items.count == 2,
              "SpringBoard：滿頁再放，擠出去的移到下一頁最前面")   // l10n-ignore：selftest 訊息
        var big = Lay(pages: [SBPage(items: [.widget(SBWidget(id: "L", kind: .calendar, size: .large))] + Array(apps.prefix(3)))])
        big.normalize()
        check(big.pages.count == 2 && big.pages[1].items == Array(apps.prefix(3)), "SpringBoard：大（4×3）佔整頁，其他推到第二頁")
        // 大小不合：4×2 放不進右半邊，左上角夾回去
        let med = SBItem.widget(SBWidget(id: "m", kind: .music, size: .medium))
        let medDrop = Lay.drop(med, into: [], at: (3, 2), reference: [:])
        check(pos(medDrop, "w:m")! == (0, 1), "SpringBoard：中（4×2）拖到右下，夾回放得下的位置")
        // 資料夾：疊上去做資料夾、名字照類別；拿掉剩一個拆回圖示
        var f = Lay(pages: [SBPage(items: [.app("music"), .app("podcasts"), .app("timers")])])
        let fid = f.merge(f.remove("a:podcasts")!, onto: "a:music", newID: "F")
        if case .folder(let fo)? = f.item("f:F") {
            check(fid == "F" && fo.apps == ["music", "podcasts"] && fo.name == Lay.folderName(["music", "podcasts"]) && f.locateApp("podcasts")?.folder == "F",
                  "SpringBoard：圖示疊到圖示上做成資料夾")   // l10n-ignore：selftest 訊息
        } else { check(false, "SpringBoard：資料夾沒有做出來") }
        f.removeApp("music")
        check(f.item("a:podcasts") != nil && f.item("f:F") == nil, "SpringBoard：資料夾剩一個就拆回圖示")
        // App 資料庫：移除後加回，放在最後一頁的空位；已經在主畫面就不重複
        var lib = Lay.official
        lib.removeApp("music")
        check(!lib.appsOnHome.contains("music") && lib.locate("a:music") == nil, "SpringBoard：從主畫面移除（App 還在資料庫）")
        lib.addApp("music"); lib.addApp("music")
        check(lib.appsOnHome.contains("music") && lib.pages.flatMap(\.items).filter { $0 == .app("music") }.count == 1, "SpringBoard：從 App 資料庫加回主畫面")
        // 加小工具：放在這頁最前面，其他往後、多的推下一頁
        var addW = Lay.official
        addW.addWidget(.widget(SBWidget(id: "n", kind: .timers, size: .wide)), page: 0)
        check(pos(addW.pages[0].items, "w:n")! == (0, 0) && addW.pages.count > Lay.official.pages.count - 1 && Set(addW.appsOnHome) == Set(Lay.official.appsOnHome),
              "SpringBoard：加小工具放左上，擠出去的到第二頁、App 一個不少")   // l10n-ignore：selftest 訊息
        // 遷移：P02 的舊排列（換成天氣、拿掉訊息）→ 新版，位置不變
        var old = HomeLayout.official
        old.setWidget(.weather); old.remove(app: "messages")
        let mig = Lay.migrate(old), mp = Lay.positions(mig.pages[0].items)
        check(mp["w:w-weather"]! == (2, 0) && mp["a:music"]! == (0, 1) && mp["a:alarms"]! == (1, 1) && mig.locate("a:messages") == nil,
              "SpringBoard：P02 的舊排列遷移過來，格子照舊")   // l10n-ignore：selftest 訊息
        let noW = Lay.migrate(HomeLayout(widget: nil, apps: ["timers"]))
        check(noW.pages[0].items == [.app("timers")], "SpringBoard：沒有小工具的舊排列照樣遷移")
        // 存檔：編碼再解碼一樣；每人一份、還原預設兩份都清
        let saved = (SBStore.layouts, SBStore.persist, PersonHome.layouts)
        defer { SBStore.layouts = saved.0; SBStore.persist = saved.1; PersonHome.layouts = saved.2 }
        SBStore.persist = false; SBStore.layouts = [:]
        var mine = Lay.official
        mine.addWidget(.stack(SBStack(id: "S", size: .small, widgets: [SBWidget(id: "s1", kind: .weather, size: .small), SBWidget(id: "s2", kind: .calendar, size: .small)])), page: 0)
        SBStore.set(mine, for: "kid")
        let round = SBStore.encoded(SBStore.layouts).flatMap(SBStore.decoded)
        check(round?["kid"] == SBStore.layouts["kid"] && SBStore.layout(for: "kid").item("s:S") != nil && SBStore.layout(for: "owner") == .official,
              "SpringBoard：每人一份，存檔讀回一樣（含 Smart Stack）")   // l10n-ignore：selftest 訊息
        PersonHome.layouts["old"] = old
        check(SBStore.layout(for: "old") == mig, "SpringBoard：只有舊版存檔的人自動遷移")
        SBStore.set(.official, for: "kid")
        check(SBStore.layouts["kid"] == nil, "SpringBoard：改回預設就不另外存")
        // 自訂過的（存檔裡有排列）一律照存檔，新預設不蓋過去
        var custom = Lay.migrate(HomeLayout.official); custom.addApp("timers")
        SBStore.layouts["fam"] = custom
        check(SBStore.layout(for: "fam") == custom && custom != Lay.official, "SpringBoard：自訂過的家人照舊，不換成新預設")   // l10n-ignore：selftest 訊息
        SBStore.layouts["fam"] = nil
        SBStore.layouts["old"] = mine; SBStore.reset("old")
        check(SBStore.layout(for: "old") == .official, "SpringBoard：還原預設，新舊存檔一起清")
        // 一份壞掉的存檔不影響其他人；擠出去的不落進隱藏頁；開頭的空格不被當成擠出去的
        let mixed = #"{"ok":{"version":2,"pages":[{"items":[{"app":{"_0":"music"}}],"hidden":false}]},"future":{"version":9,"pages":[{"items":[{"hologram":{}}]}]}}"#
        let loaded = SBStore.load(Data(mixed.utf8))
        check(loaded["ok"]?.pages.first?.items == [.app("music")] && loaded["future"] == nil && SBStore.unreadable["future"] != nil, "SpringBoard：存檔逐人讀，讀不懂的那份原樣留著")   // l10n-ignore：selftest 訊息
        SBStore.unreadable["future"] = nil
        var hid = Lay(pages: [SBPage(items: Array(apps.prefix(12)) + [.app("z")]), SBPage(items: [.app("h")], hidden: true)])
        hid.normalize()
        check(hid.pages.count == 3 && hid.pages[1].items == [.app("z")] && !hid.pages[1].hidden && hid.pages[2].hidden, "SpringBoard：擠出去的不落進隱藏頁")
        var sp = Lay(pages: [SBPage(items: [.spacer] + Array(apps.prefix(11)) + [.spacer])])
        sp.normalize()
        check(sp.pages.count == 1 && sp.pages[0].items.first == .spacer && Lay.positions(sp.pages[0].items)["a:x0"]! == (1, 0), "SpringBoard：開頭的空格留著，只拿掉擠出去的")   // l10n-ignore：selftest 訊息
        var bad = Lay(pages: [SBPage(items: [.app("recipes"), .app("nope"), .app("safari"), .folder(SBFolder(id: "q", name: "x", apps: ["nope"]))])])
        bad.sanitize()
        check(bad.pages[0].items == [.app("recipes"), .app("safari")], "SpringBoard：存檔裡不存在的 App 清掉；食譜是獨立 App 照留")
        // 背景掃描暫時沒結果：認不得的 iPhone App、Web App 照留在排列（含資料夾），載入再存回去那一格還在
        let ghostPhone = "iphone:com.example.unscanned", ghostWeb = WebApp.idPrefix + "00000000-0000-4000-8000-00000000dead"
        check(AppRegistry.app(ghostPhone) == nil && AppRegistry.app(ghostWeb) == nil, "SpringBoard：測試用的 iPhone／Web App id 確實認不得")   // l10n-ignore：selftest 訊息
        let ghostRaw = #"{"p":{"version":2,"pages":[{"items":[{"app":{"_0":"music"}},{"app":{"_0":"\#(ghostPhone)"}},{"folder":{"_0":{"id":"gf","name":"G","apps":["\#(ghostWeb)","\#(ghostPhone)2"]}}}],"hidden":false}]}}"#
        let ghostLoaded = SBStore.load(Data(ghostRaw.utf8))
        let ghostBack = SBStore.encoded(ghostLoaded).flatMap { SBStore.load($0) }
        let gItems = ghostBack?["p"]?.pages.first?.items ?? []
        let gFolder: SBFolder? = gItems.compactMap { if case .folder(let f) = $0 { return f }; return nil }.first
        check(gItems.contains(.app(ghostPhone)) && gFolder?.apps == [ghostWeb, ghostPhone + "2"] && gItems.first == .app("music"),
              "SpringBoard：認不得的 iPhone／Web App 載入再存回去還在，資料夾也不消失（\(gItems.count)）")   // l10n-ignore：selftest 訊息
        SBStore.unreadable["p"] = nil
        // 讀不懂的那份：本人改回預設、還原預設之後不再寫回；名冊刪掉的人那份一起清
        let savedBad = SBStore.unreadable
        SBStore.unreadable = ["u1": ["version": 9], "u2": ["version": 9], "u3": ["version": 9]]
        SBStore.set(.official, for: "u1")
        SBStore.reset("u2")
        SBStore.layouts["keep"] = mine
        SBStore.prune(keeping: ["keep"])
        let badLeft = SBStore.unreadable.keys.sorted()
        SBStore.unreadable = savedBad; SBStore.layouts["keep"] = nil
        check(badLeft.isEmpty, "SpringBoard：改回預設、還原預設後讀不懂的舊存檔不寫回；刪掉的人那份一起清（剩 \(badLeft)）")   // l10n-ignore：selftest 訊息
        // Smart Stack：智慧型旋轉照時段、建議計時器
        let st = SBStack(id: "z", size: .small, widgets: [SBWidget(id: "1", kind: .music, size: .small), SBWidget(id: "2", kind: .weather, size: .small)])
        check(st.rotatedIndex(hour: 8) == 1 && st.rotatedIndex(hour: 20) == 0 && st.suggestion(timerRunning: true, musicPlaying: false) == .timers,
              "SpringBoard：Smart Stack 早上天氣、晚上音樂，計時器在跑時建議計時器")   // l10n-ignore：selftest 訊息
        // 急事插隊：狀態轉換才轉、手動翻過 10 分鐘內不轉、停夠久回時段、沒那個 kind 不動
        let ws = [SBWidget(id: "a", kind: .weather, size: .small), SBWidget(id: "b", kind: .timers, size: .small), SBWidget(id: "c", kind: .music, size: .small)]
        let idle = SmartStackPolicy.State(), tOn = SmartStackPolicy.State(timer: true), mOn = SmartStackPolicy.State(music: true)
        check(SmartStackPolicy.next(current: 0, widgets: ws, state: tOn, prev: idle, manualAt: nil, now: 1000, hour: 8) == 1
              && SmartStackPolicy.next(current: 0, widgets: ws, state: tOn, prev: tOn, manualAt: nil, now: 1000, hour: 8) == nil,
              "Smart Stack 急事插隊：計時器剛開始轉到計時器，之後不再強轉")   // l10n-ignore：selftest 訊息
        check(SmartStackPolicy.next(current: 0, widgets: ws, state: tOn, prev: idle, manualAt: 500, now: 1000, hour: 8) == nil
              && SmartStackPolicy.next(current: 0, widgets: ws, state: tOn, prev: idle, manualAt: 300, now: 1000, hour: 8) == 1,
              "Smart Stack 急事插隊：手動翻過 10 分鐘內不轉，超過就轉")   // l10n-ignore：selftest 訊息
        var gone = idle; gone.idleFor = 301
        check(SmartStackPolicy.next(current: 2, widgets: ws, state: gone, prev: mOn, manualAt: nil, now: 1000, hour: 8) == 0
              && SmartStackPolicy.next(current: 2, widgets: ws, state: idle, prev: mOn, manualAt: nil, now: 1000, hour: 8) == nil,
              "Smart Stack 急事插隊：音樂停超過 5 分鐘回時段排序，未滿 5 分鐘不動")   // l10n-ignore：selftest 訊息
        check(SmartStackPolicy.next(current: 0, widgets: [ws[0]], state: tOn, prev: idle, manualAt: nil, now: 1000, hour: 8) == nil
              && SmartStackPolicy.next(current: 0, widgets: ws, state: SmartStackPolicy.State(alarm: true), prev: idle, manualAt: nil, now: 1000, hour: 8) == nil,
              "Smart Stack 急事插隊：疊放沒有那個 kind 就不動")   // l10n-ignore：selftest 訊息
        check(SBWidgetKind.allCases.allSatisfy { k in !k.sizes.isEmpty && k.sizes.allSatisfy { $0.span.w <= Lay.cols && $0.span.h <= Lay.rows } },
              "SpringBoard：每個小工具都有放得下的大小")   // l10n-ignore：selftest 訊息
    }
}
