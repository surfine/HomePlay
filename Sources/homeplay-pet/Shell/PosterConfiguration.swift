// 錶面體系：官方海報配置（docs/hv-reference/poster_descriptors.json 的 posterData）在 HomePlay 的等價物。
// 一份配置描述一張海報：Look（色票名）、字體、數字系統、版式、頁首日期格式、底、版本；
// 官方另有 items[]（complication 槽）與 colorLook（玻璃配色），這裡照原樣的 JSON 形狀留位、能讀能寫。
// HomePlay 自己多出來的大數字細節（粗細、色票、色調、玻璃、有沒有明確選過 Look）放在 "homeplay" 鍵底下，不混進官方欄位。
//
// 派生：HPLook 的 Look 名、ClockLook（字體＝typeface，其餘＝homeplay 欄位）都讀寫這一份。
// 遷移：沒有新鍵、但有舊的 HomePlayLook／HomePlayClockLook 時，第一次讀就照舊值組一份寫進新鍵（舊鍵不刪，退版也讀得到）；
// 兩個舊鍵都沒有＝全新使用者，只放在記憶體、第一次真的改設定才寫（免得首次設定把「有偏好」誤判成升級上來的人）。
import Foundation

struct PosterConfiguration: Equatable {
    /// 數字系統（官方 numerals 欄位；出廠值 "arabic" 🟢，其他名稱 ⚪——這裡用 iOS 鎖定畫面的系統名）
    enum Numerals: String, CaseIterable {
        case arabic, arabicIndic, extendedArabicIndic, devanagari, bengali, myanmar, khmer
    }
    /// 版式：month 🟢（行事曆海報）、threeColumnSixItems 🟢（家庭海報）；time＝HomePlay 原本的大時間海報（🟡 自己的版式）
    enum Style: String, CaseIterable {
        case time, month, threeColumnSixItems
        /// 給設定清單看的名字（Look 名是專有名詞不翻；版式是我們自己的說法）
        var title: String {
            switch self {
            case .time: return L("poster.style.time", "大时间")
            case .month: return L("poster.style.month", "月历")
            case .threeColumnSixItems: return L("poster.style.home", "家庭")
            }
        }
    }
    /// 頁首日期格式：ICU 格式字串＋顯示名（官方 header.dateFormat._0 的 format／title 🟢）
    struct DateFormat: Equatable, Codable {
        var format: String
        var title: String
        /// 🟢 官方出廠值（poster_descriptors.json：Calendar 四個預設的 header.dateFormat）
        static let dayAndTime = DateFormat(format: "E h:mm", title: "Day and Time")
        /// HomePlay 原本海報的日期行（月日星期，Face.dateLine 同一個模板）
        static let date = DateFormat(format: "MMMMdEEEE", title: "Date")
        static let customTitle = "Custom"
    }
    /// complication 槽（官方 items[]：identifier＋type；出廠全是 placeholder 🟢）
    struct Item: Equatable {
        enum Kind: Equatable {
            case placeholder
            /// 第 n 個 Live Activity（頂端膠囊同一份；照順序一格一個）
            case activity
            /// 主畫面小工具同一份資料（Shell/SpringBoard/SBWidgets.swift 的 SBWidgetData）
            case widget(SBWidgetKind)
        }
        var identifier: String
        var kind: Kind
    }
    /// 官方 colorLook：目前只看到 {"glass":{}} 🟢
    enum ColorLook: String { case glass }
    /// HomePlay 自己的欄位（"homeplay" 鍵）
    struct Extras: Equatable, Codable {
        var weight: Double = ClockLook().weight
        var swatch: ClockLook.Swatch = ClockLook().swatch
        var tone: Double = ClockLook().tone
        var glass: Bool = ClockLook().glass
        /// 使用者明確選過 Look（沒選＝預設 Blue-Orange，不驅動著色建議；HPLook.wasSelected）
        var lookChosen = false
        /// 這張臉用哪一種錶面（FaceStyle.rawValue）。空字串＝舊檔還沒寫，讀庫時補成當時那張。
        var faceKind: String = ""
        /// 畫廊上的名字。空＝用錶面種類的名字。
        var displayName: String = ""

        init(weight: Double = ClockLook().weight, swatch: ClockLook.Swatch = ClockLook().swatch, tone: Double = ClockLook().tone, glass: Bool = ClockLook().glass, lookChosen: Bool = false, faceKind: String = "", displayName: String = "") {
            self.weight = weight
            self.swatch = swatch
            self.tone = tone
            self.glass = glass
            self.lookChosen = lookChosen
            self.faceKind = faceKind
            self.displayName = displayName
        }

        private enum K: String, CodingKey {
            case weight, swatch, tone, glass, lookChosen, faceKind, displayName
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let base = ClockLook()
            weight = (try? c.decodeIfPresent(Double.self, forKey: .weight)) ?? base.weight
            if let s = try? c.decodeIfPresent(String.self, forKey: .swatch), let v = ClockLook.Swatch(rawValue: s) { swatch = v }
            else { swatch = base.swatch }
            tone = (try? c.decodeIfPresent(Double.self, forKey: .tone)) ?? base.tone
            glass = (try? c.decodeIfPresent(Bool.self, forKey: .glass)) ?? base.glass
            lookChosen = (try? c.decodeIfPresent(Bool.self, forKey: .lookChosen)) ?? false
            let kind = (try? c.decodeIfPresent(String.self, forKey: .faceKind)) ?? ""
            faceKind = FaceStyle(rawValue: kind) == nil ? "" : kind
            displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(weight, forKey: .weight)
            try c.encode(swatch.rawValue, forKey: .swatch)
            try c.encode(tone, forKey: .tone)
            try c.encode(glass, forKey: .glass)
            try c.encode(lookChosen, forKey: .lookChosen)
            try c.encode(faceKind, forKey: .faceKind)
            try c.encode(displayName, forKey: .displayName)
        }
    }

    static let currentVersion: Double = 1

    var look: String = HVTruth.looks[0].name
    var lookType = "uncustomizable"
    var typeface: ClockLook.Font = ClockLook().font
    /// nil＝跟隨 Locale 的數字系統（Locale 也不是支援的系統就用 arabic）
    var numerals: Numerals? = nil
    var style: Style = .time
    var dateFormat: DateFormat = .date
    var background = "dynamic"
    var version: Double = currentVersion
    var items: [Item] = []
    var colorLook: ColorLook? = nil
    var overrideColorScheme: String? = nil
    var extras = Extras()

    /// 畫廊上這張臉的錶面種類。舊檔空字串時先用島，讀庫會補上當時那張。
    var galleryFace: FaceStyle { FaceStyle(rawValue: extras.faceKind)?.inLineup ?? .island }
    /// 畫廊上的名字：自己的顯示名，否則錶面種類的名字。
    var galleryName: String { extras.displayName.isEmpty ? galleryFace.title : extras.displayName }

    /// ClockLook 從配置派生（字體＝typeface，其餘＝homeplay 欄位）
    var clockLook: ClockLook {
        get { ClockLook(font: typeface, weight: extras.weight, swatch: extras.swatch, tone: extras.tone, glass: extras.glass) }
        set {
            typeface = newValue.font
            extras.weight = newValue.weight; extras.swatch = newValue.swatch; extras.tone = newValue.tone; extras.glass = newValue.glass
        }
    }

    // MARK: 現在的配置

    /// 畫廊縮圖暫時換配置時打開，避免把預覽寫進目前這張臉
    nonisolated(unsafe) static var suppressLibraryWrite = false
    nonisolated(unsafe) static var current: PosterConfiguration = PosterLibraryStore.current {
        didSet { if !suppressLibraryWrite, current != oldValue { PosterLibraryStore.updateCurrent(current) } }
    }

    /// 快照：--poster 'look=Blue-Orange,typeface=soft'（或 --poster default-color-3），不寫偏好
    nonisolated(unsafe) static var snapshotOverride: PosterConfiguration?
    static var active: PosterConfiguration { snapshotOverride ?? current }

    // MARK: 出廠預設

    /// 🟢 Calendar 海報四個出廠預設（poster_descriptors.json：CalendarPosterExtension 的 default-color-1…4）：
    /// Look 與字體的配對照原文；style month、numerals arabic、header「Day and Time」、background dynamic、version 1
    static let factoryPresets: [(id: String, config: PosterConfiguration)] = [
        ("default-color-1", calendarPreset(look: "Red-Blue", typeface: .newYork)),
        ("default-color-2", calendarPreset(look: "Neon-Blue", typeface: .soft)),
        ("default-color-3", calendarPreset(look: "Blue-Orange", typeface: .stencil)),
        ("default-color-4", calendarPreset(look: "Orange-Purple", typeface: .newYork)),
    ]
    /// 🟢 家庭海報出廠預設（poster_descriptors.json：HomeFace 的 default-installer-color-0…4）：
    /// threeColumnSixItems v1.2、九格 placeholder、colorLook glass、overrideColorScheme automatic、background material1…4
    static let familyPresets: [(id: String, config: PosterConfiguration)] =
        [(0, "material1"), (1, "material1"), (2, "material2"), (3, "material4"), (4, "material3")].map { p in
            let (i, bg) = p
            var c = PosterConfiguration()
            c.style = .threeColumnSixItems; c.version = 1.2; c.background = bg; c.colorLook = .glass; c.overrideColorScheme = "automatic"
            c.items = (0..<9).map { Item(identifier: "slot-\($0)", kind: .placeholder) }
            return ("default-installer-color-\(i)", c)
        }
    static func preset(_ id: String) -> PosterConfiguration? {
        (factoryPresets + familyPresets).first { $0.id == id }?.config
    }
    private static func calendarPreset(look: String, typeface: ClockLook.Font) -> PosterConfiguration {
        var c = PosterConfiguration()
        c.look = look; c.typeface = typeface; c.numerals = .arabic; c.style = .month; c.dateFormat = .dayAndTime
        c.extras.lookChosen = true
        return c
    }

    // MARK: --poster

    /// 快照旗標（照 ClockLook.parse）：逗號分隔 key=value；不認得的鍵與值一律忽略。
    /// preset（或單獨寫預設名）先套、其他欄位再蓋上：look typeface numerals(auto＝跟隨 Locale) style header(dayAndTime|date) format(自訂 ICU)
    /// background items(以 | 分隔：placeholder activity weather calendar timers…)
    static func parse(_ s: String) -> PosterConfiguration {
        let parts = s.split(separator: ",").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        var c = PosterConfiguration()
        for p in parts {
            if p.count == 1, let pre = preset(p[0]) { c = pre }
            if p.count == 2, p[0] == "preset", let pre = preset(p[1]) { c = pre }
        }
        for p in parts where p.count == 2 {
            let v = p[1]
            switch p[0] {
            case "look": if HVTruth.look(v) != nil { c.look = v; c.extras.lookChosen = true }
            case "typeface": c.typeface = ClockLook.Font(rawValue: v) ?? c.typeface
            case "numerals": if v == "auto" { c.numerals = nil } else if let n = Numerals(rawValue: v) { c.numerals = n }
            case "style": c.style = Style(rawValue: v) ?? c.style
            case "header": if v == "dayAndTime" { c.dateFormat = .dayAndTime } else if v == "date" { c.dateFormat = .date }
            case "format": if !v.isEmpty { c.dateFormat = DateFormat(format: v, title: DateFormat.customTitle) }
            case "background": if !v.isEmpty { c.background = v }
            case "items":
                c.items = v.split(separator: "|").enumerated().compactMap { i, k in
                    Item.Kind(token: String(k)).map { Item(identifier: "slot-\(i)", kind: $0) }
                }
            default: break
            }
        }
        return c
    }
}

extension PosterConfiguration.Item.Kind {
    /// --poster items 的寫法
    init?(token: String) {
        switch token {
        case "placeholder": self = .placeholder
        case "activity": self = .activity
        default:
            guard let k = SBWidgetKind(rawValue: token) else { return nil }
            self = .widget(k)
        }
    }
}

// MARK: - 頁首日期（header.dateFormat）

extension PosterConfiguration.DateFormat {
    /// 設定裡的三個候選
    enum Choice: CaseIterable { case dayAndTime, date, custom }
    var choice: Choice { self == .dayAndTime ? .dayAndTime : self == .date ? .date : .custom }
    /// 顯示名：官方 title 是英文原文（"Day and Time"），畫面上照介面語言
    var localizedTitle: String { choice.title }

    /// 這個格式在 d 這一刻的字（數字還是 ASCII；換數字系統交給呼叫端）。
    /// - 週＋時間：照官方字面 "E h:mm"，時制照系統（24 小時制換成 H）；不帶上午／下午，跟大數字一致
    /// - 日期：模板照介面語言排（跟原本海報的日期行同一個 Face.dateLine 模板）
    /// - 自訂：使用者寫的 ICU 字串原樣用
    func text(_ d: Date, twelveHour: Bool = Face.uses12Hour) -> String {
        switch choice {
        case .date: return Face.formatter(format).string(from: d)
        case .dayAndTime: return Face.formatter(Self.hourCycled(format, twelveHour: twelveHour), raw: true).string(from: d)
        case .custom: return Face.formatter(format, raw: true).string(from: d)
        }
    }
    /// h／H 照時制換（引號裡的字面文字不動）
    static func hourCycled(_ f: String, twelveHour: Bool) -> String {
        var out = "", quoted = false
        for ch in f {
            if ch == "'" { quoted.toggle(); out.append(ch); continue }
            if !quoted, ch == "h" || ch == "H" { out.append(twelveHour ? "h" : "H") } else { out.append(ch) }
        }
        return out
    }
}

extension PosterConfiguration.DateFormat.Choice {
    var title: String {
        switch self {
        case .dayAndTime: return L("poster.header.dayAndTime", "星期与时间")
        case .date: return L("poster.header.date", "日期")
        case .custom: return L("poster.header.custom", "自定义")
        }
    }
}

extension PosterConfiguration {
    /// 海報頁首那一行（已換成這份配置的數字系統）
    func headerText(_ d: Date) -> String { FaceType.digits(dateFormat.text(d), resolvedNumerals) }
}

// MARK: - JSON（官方 posterData 的形狀；讀的時候寬鬆：缺的欄位用預設、不認得的值忽略）

/// 單鍵的 JSON 物件（官方 Swift enum 的編碼：{"glass":{}}、{"placeholder":{}}、{"dateFormat":{"_0":{…}}}）
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
private struct Empty: Codable {}
/// 跳過陣列裡不是物件的元素（任何值都解得開、游標照常前進）
private struct Skip: Decodable { init(from decoder: Decoder) {} }

extension PosterConfiguration: Codable {
    private enum K: String, CodingKey {
        case background, header, look, numerals, style, typeface, version, items, colorLook, overrideColorScheme, homeplay
    }
    private struct Wrapped<T: Codable>: Codable { var _0: T }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: K.self)
        if let v = try? c.decodeIfPresent(String.self, forKey: .background) { background = v }
        if let l = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .look) {
            if let n = try? l.decode(String.self, forKey: AnyKey("customIdentifier")), HVTruth.look(n) != nil { look = n }
            if let t = try? l.decode(String.self, forKey: AnyKey("typeIdentifier")) { lookType = t }
        }
        if let s = try? c.decodeIfPresent(String.self, forKey: .typeface), let f = ClockLook.Font(rawValue: s) { typeface = f }
        if let s = try? c.decodeIfPresent(String.self, forKey: .numerals) { numerals = Numerals(rawValue: s) }
        if let s = try? c.decodeIfPresent(String.self, forKey: .style), let v = Style(rawValue: s) { style = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .version) { version = v }
        if let h = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .header),
           let f = try? h.decode(Wrapped<DateFormat>.self, forKey: AnyKey("dateFormat")), !f._0.format.isEmpty { dateFormat = f._0 }
        if var arr = try? c.nestedUnkeyedContainer(forKey: .items) {
            var out: [Item] = []
            while !arr.isAtEnd {
                guard let it = try? arr.nestedContainer(keyedBy: AnyKey.self) else { _ = try? arr.decode(Skip.self); continue }
                let id = (try? it.decode(String.self, forKey: AnyKey("identifier"))) ?? "slot-\(out.count)"
                var kind = Item.Kind.placeholder   // 不認得的槽型別：當佔位（不畫），位置照留
                if let t = try? it.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("type")) {
                    if t.contains(AnyKey("liveActivity")) { kind = .activity }
                    else if let w = try? t.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("widget")),
                            let s = try? w.decode(String.self, forKey: AnyKey("kind")), let k = SBWidgetKind(rawValue: s) { kind = .widget(k) }
                }
                out.append(Item(identifier: id, kind: kind))
            }
            items = out
        }
        if let cl = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .colorLook) {
            colorLook = cl.allKeys.lazy.compactMap { ColorLook(rawValue: $0.stringValue) }.first
        }
        overrideColorScheme = try? c.decodeIfPresent(String.self, forKey: .overrideColorScheme)
        if let e = try? c.decodeIfPresent(Extras.self, forKey: .homeplay) { extras = e }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(background, forKey: .background)
        var h = c.nestedContainer(keyedBy: AnyKey.self, forKey: .header)
        try h.encode(Wrapped(_0: dateFormat), forKey: AnyKey("dateFormat"))
        var l = c.nestedContainer(keyedBy: AnyKey.self, forKey: .look)
        try l.encode([String](), forKey: AnyKey("colors"))
        try l.encode(look, forKey: AnyKey("customIdentifier"))
        try l.encode(lookType, forKey: AnyKey("typeIdentifier"))
        try c.encodeIfPresent(numerals?.rawValue, forKey: .numerals)
        try c.encode(style.rawValue, forKey: .style)
        try c.encode(typeface.rawValue, forKey: .typeface)
        try c.encode(version, forKey: .version)
        if !items.isEmpty {
            var arr = c.nestedUnkeyedContainer(forKey: .items)
            for it in items {
                var o = arr.nestedContainer(keyedBy: AnyKey.self)
                try o.encode(it.identifier, forKey: AnyKey("identifier"))
                var t = o.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("type"))
                switch it.kind {
                case .placeholder: try t.encode(Empty(), forKey: AnyKey("placeholder"))
                case .activity: try t.encode(Empty(), forKey: AnyKey("liveActivity"))
                case .widget(let k):
                    var w = t.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("widget"))
                    try w.encode(k.rawValue, forKey: AnyKey("kind"))
                }
            }
        }
        if let colorLook {
            var cl = c.nestedContainer(keyedBy: AnyKey.self, forKey: .colorLook)
            try cl.encode(Empty(), forKey: AnyKey(colorLook.rawValue))
        }
        try c.encodeIfPresent(overrideColorScheme, forKey: .overrideColorScheme)
        try c.encode(extras, forKey: .homeplay)
    }
}

// MARK: - 持久化與遷移

enum PosterStore {
    static let defaultsKey = "HomePlayPosterConfig"
    /// 舊的兩個鍵（1.x／2.0 beta）：Look 名字串、ClockLook JSON
    static var legacyKeys: [String] { [HPLook.defaultsKey, ClockLook.defaultsKey] }

    static func load(_ d: UserDefaults = .standard) -> PosterConfiguration {
        var c: PosterConfiguration
        if let data = d.data(forKey: defaultsKey), let decoded = try? JSONDecoder().decode(PosterConfiguration.self, from: data) {
            c = decoded
        } else {
            c = migrated(d)
            if legacyKeys.contains(where: { d.object(forKey: $0) != nil }) { save(c, d) }   // 有舊偏好才寫（一次性）；全新使用者不留痕跡
        }
        // 一次性修復（拍板 2026-11-08）：舊版「實線」偏好（glass=false）在玻璃系統成熟前存下、遷移時被當成用戶選擇
        // 帶了過來——數字永遠走實線分支＝生硬。升級為玻璃（設定裡仍可關回實線）；只跑一次，不重寫用戶之後的選擇。
        if d === UserDefaults.standard, !c.clockLook.glass, !d.bool(forKey: "HomePlayGlassRepair1") {   // 只修正式偏好；selftest 的注入 suite 不動
            d.set(true, forKey: "HomePlayGlassRepair1")
            c.clockLook.glass = true
            save(c, d)
        }
        return c
    }

    /// 照舊鍵組一份配置：值原樣搬（Look 名不合法時照舊行為退回預設 Look，但「選過」照舊記著）
    static func migrated(_ d: UserDefaults) -> PosterConfiguration {
        var c = PosterConfiguration()
        if let n = d.string(forKey: HPLook.defaultsKey) {
            if HVTruth.look(n) != nil { c.look = n }
            c.extras.lookChosen = true
        }
        if let data = d.data(forKey: ClockLook.defaultsKey), let l = try? JSONDecoder().decode(ClockLook.self, from: data) { c.clockLook = l }
        return c
    }

    static func save(_ c: PosterConfiguration, _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(c) { d.set(data, forKey: defaultsKey) }
    }
}

// MARK: - 多臉（錶面體系 backlog #1）

/// 一疊海報：items 是每一張臉的配置，index 是目前那張。
/// 純值型別（Codable）＝可測；持久化與記憶體快取在 PosterLibraryStore。
struct PosterLibrary: Equatable, Codable {
    var items: [PosterConfiguration]
    var index: Int

    init(items: [PosterConfiguration] = [PosterConfiguration()], index: Int = 0) {
        self.items = items.isEmpty ? [PosterConfiguration()] : items
        self.index = max(0, min(index, self.items.count - 1))
    }

    var current: PosterConfiguration { items[max(0, min(index, items.count - 1))] }

    @discardableResult
    mutating func select(_ i: Int) -> Bool {
        guard items.indices.contains(i), i != index else { return false }
        index = i; return true
    }

    @discardableResult
    mutating func add(_ c: PosterConfiguration) -> Int {
        items.insert(c, at: min(index + 1, items.count)); index = min(index + 1, items.count - 1)
        return index
    }

    /// 至少留一張（官方：「Removing this Face will not delete any apps or data.」）
    @discardableResult
    mutating func remove(_ i: Int) -> Bool {
        guard items.count > 1, items.indices.contains(i) else { return false }
        items.remove(at: i)
        if index >= items.count { index = items.count - 1 } else if i < index { index -= 1 }
        return true
    }

    mutating func updateCurrent(_ c: PosterConfiguration) {
        guard items.indices.contains(index) else { return }
        items[index] = c
    }

    /// 舊檔沒有錶面種類時補上，不改 index。已經認得的不覆蓋。
    func assigningFaceKind(_ raw: String) -> PosterLibrary {
        var l = self
        let fallback = FaceStyle(rawValue: raw)?.inLineup.rawValue ?? FaceStyle.island.rawValue
        for i in l.items.indices where FaceStyle(rawValue: l.items[i].extras.faceKind) == nil {
            l.items[i].extras.faceKind = fallback
        }
        return l
    }
}

/// 畫廊的加號：焦點移到末尾那張 AddFace，目前套用的 index 不動（Rushmore：activeFaceItemID = AddFace，activeFaceID 留著）
enum FaceGallery {
    static func focusAdd(count: Int, index: Int) -> (sel: Int, index: Int) {
        (max(0, count), index)
    }
}

enum PosterLibraryStore {
    static let defaultsKey = "HomePlayPosterLibrary"
    nonisolated(unsafe) private static var lib: PosterLibrary = loadFromDisk()

    static var all: [PosterConfiguration] { lib.items }
    static var index: Int { lib.index }
    static var current: PosterConfiguration { lib.current }

    private static func loadFromDisk() -> PosterLibrary {
        let face = UserDefaults.standard.string(forKey: FaceStyle.defaultsKey) ?? FaceStyle.island.rawValue
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let l = try? JSONDecoder().decode(PosterLibrary.self, from: data) {
            return l.assigningFaceKind(face)   // 舊檔缺錶面種類：補成目前這張，不改 index
        }
        // 舊版只有一張臉：現在這份就是第一張（不寫檔，等真的新增／切換才落盤）
        let one = PosterLibrary(items: [PosterStore.load()], index: 0).assigningFaceKind(face)
        return one   // 直接讀舊鍵，避免 current ↔ library 循環初始化
    }

    private static func persist() {
        if let data = try? JSONEncoder().encode(lib) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        PosterStore.save(lib.current)   // 舊鍵同步：退版仍讀得到
    }

    static func updateCurrent(_ c: PosterConfiguration) { lib.updateCurrent(c); persist() }
    /// 改某一張，不換目前套用的 index。改到目前那張時，呼叫端再把 PosterConfiguration.current 對上。
    static func replace(_ i: Int, with c: PosterConfiguration, persistChanges: Bool = true) {
        guard lib.items.indices.contains(i) else { return }
        lib.items[i] = c
        if persistChanges { persist() }
    }
    @discardableResult static func select(_ i: Int) -> Bool { let ok = lib.select(i); if ok { persist() }; return ok }
    @discardableResult static func add(_ c: PosterConfiguration) -> Int { let i = lib.add(c); persist(); return i }
    @discardableResult static func remove(_ i: Int) -> Bool { let ok = lib.remove(i); if ok { persist() }; return ok }
    static var listText: String {
        lib.items.enumerated().map { "[\($0.offset)] \($0.element.look) · \($0.element.typeface.rawValue) · \($0.element.style.rawValue)\($0.offset == lib.index ? "  ←" : "")" }.joined(separator: "\n")
    }
}

// MARK: - 自檢

enum PosterConfigurationSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias P = PosterConfiguration
        let enc = JSONEncoder(), dec = JSONDecoder()
        func rt(_ c: P) -> P? { (try? enc.encode(c)).flatMap { try? dec.decode(P.self, from: $0) } }

        // round-trip：HomePlay 預設、四個出廠預設、家庭預設、帶 items／numerals／自訂格式的
        var custom = P(); custom.numerals = .devanagari; custom.dateFormat = .init(format: "EEEE d MMMM", title: P.DateFormat.customTitle)
        custom.items = [.init(identifier: "a", kind: .activity), .init(identifier: "b", kind: .widget(.weather)), .init(identifier: "c", kind: .placeholder)]
        custom.extras = .init(weight: 0.7, swatch: .blue, tone: 0.3, glass: false, lookChosen: true)
        let all = [P(), custom] + P.factoryPresets.map { $0.config } + P.familyPresets.map { $0.config }
        check(all.allSatisfy { rt($0) == $0 }, "海報配置：編碼再解碼原樣回來（預設、出廠、家庭、自訂）")   // l10n-ignore

        // 🟢 出廠配對（poster_descriptors.json）
        let pairs = P.factoryPresets.map { "\($0.id)=\($0.config.look)/\($0.config.typeface.rawValue)" }
        check(pairs == ["default-color-1=Red-Blue/newYork", "default-color-2=Neon-Blue/soft", "default-color-3=Blue-Orange/stencil", "default-color-4=Orange-Purple/newYork"]
              && P.factoryPresets.allSatisfy { $0.config.style == .month && $0.config.numerals == .arabic && $0.config.dateFormat == .dayAndTime && $0.config.version == 1 },
              "海報配置：出廠四個預設的 Look／字體配對照官方原文")   // l10n-ignore

        // 官方 posterData 原文直接讀得進來（倉內證據檔在就逐一比對；不在就只驗內嵌的一份）
        let embedded = #"{"background":"dynamic","header":{"dateFormat":{"_0":{"format":"E h:mm","title":"Day and Time"}}},"look":{"colors":[],"customIdentifier":"Neon-Blue","typeIdentifier":"uncustomizable"},"numerals":"arabic","style":"month","typeface":"soft","version":1}"#
        let e: P = (try? dec.decode(P.self, from: Data(embedded.utf8))) ?? P()
        let embeddedOK: Bool = e.look == "Neon-Blue" && e.typeface == .soft && e.dateFormat == .dayAndTime && e.style == .month
        check(embeddedOK, "海報配置：官方 posterData 原文解得開")   // l10n-ignore
        if let ev = evidence() {
            let ok = P.factoryPresets.allSatisfy { p in
                guard let raw = ev.calendar[p.id], let c = try? dec.decode(P.self, from: raw) else { return false }
                return c.look == p.config.look && c.typeface == p.config.typeface && c.style == .month && c.numerals == .arabic && c.dateFormat == .dayAndTime
            }
            let home = ev.home.compactMap { try? dec.decode(P.self, from: $0) }
            check(ok && !home.isEmpty && home.allSatisfy { $0.style == .threeColumnSixItems && $0.items.count == 9 && $0.items.allSatisfy { $0.kind == .placeholder }
                                                           && $0.colorLook == .glass && $0.version == 1.2 },
                  "海報配置：證據檔裡四個行事曆預設與家庭預設逐一對得上")   // l10n-ignore
        }

        // 非法值忽略：不認得的 Look、字體、版式、數字系統、槽型別，其他欄位照讀
        let bad = #"{"look":{"customIdentifier":"Nope"},"typeface":"comic","style":"spiral","numerals":"roman","version":1,"items":[{"identifier":"x","type":{"hologram":{}}}],"background":"material2"}"#
        let b = try? dec.decode(P.self, from: Data(bad.utf8))
        check(b?.look == HVTruth.looks[0].name && b?.typeface == .sf && b?.style == .time && b?.numerals == nil
              && b?.items == [.init(identifier: "x", kind: .placeholder)] && b?.background == "material2", "海報配置：不認得的值忽略、其他欄位照讀")   // l10n-ignore
        let flag = P.parse("look=Nope,typeface=comic,style=month,numerals=roman,bogus=1")
        check(flag.look == HVTruth.looks[0].name && flag.typeface == .sf && flag.style == .month && flag.numerals == nil, "海報配置：--poster 不認得的鍵與值忽略")   // l10n-ignore
        let flag2 = P.parse("default-color-3,typeface=soft,items=activity|weather|nope|placeholder")
        check(flag2.look == "Blue-Orange" && flag2.typeface == .soft && flag2.style == .month && flag2.items.map(\.kind) == [.activity, .widget(.weather), .placeholder],
              "海報配置：--poster 先套預設再蓋欄位")   // l10n-ignore

        // 版本：新寫的是 1；官方 1.2 與未來版本照讀已知欄位
        let future = #"{"version":3,"style":"month","typeface":"stencil","somethingNew":{"a":1}}"#
        let f: P = (try? dec.decode(P.self, from: Data(future.utf8))) ?? P()
        let futureOK: Bool = P().version == 1 && f.version == 3 && f.style == .month && f.typeface == .stencil
        check(futureOK, "海報配置：版本照存、未來版本照讀已知欄位")   // l10n-ignore

        // 多臉：新增／切換／刪除（至少留一張）
        var lib = PosterLibrary(items: [P(), P.factoryPresets[0].config], index: 0)
        check(lib.current.look == P().look && lib.select(1) && lib.current.look == P.factoryPresets[0].config.look,
              "多臉：切換到第二張拿到它的 Look")   // l10n-ignore
        let added = lib.add(P.factoryPresets[1].config)
        check(lib.items.count == 3 && added == 2 && lib.current.look == P.factoryPresets[1].config.look,
              "多臉：新增排在目前那張之後並選它")   // l10n-ignore
        check(lib.remove(2) && lib.items.count == 2 && lib.current.look == P.factoryPresets[0].config.look,
              "多臉：刪掉目前那張會退回前一張")   // l10n-ignore
        var one = PosterLibrary()
        check(!one.remove(0) && one.items.count == 1, "多臉：最後一張不能刪（官方：刪臉不會刪 App 或資料）")   // l10n-ignore
        check((try? enc.encode(lib)).flatMap { try? dec.decode(PosterLibrary.self, from: $0) } == lib,
              "多臉：整疊編碼再解碼原樣回來")   // l10n-ignore

        // 舊 homeplay 沒有 faceKind／displayName：讀得開，補錶面種類不改 index；加號不改目前那張
        let oldHome = #"{"background":"dynamic","look":{"customIdentifier":"Mocha","typeIdentifier":"uncustomizable"},"style":"time","typeface":"sf","version":1,"homeplay":{"weight":0.5,"swatch":"blue","tone":0.2,"glass":true,"lookChosen":true}}"#
        let legacy = (try? dec.decode(P.self, from: Data(oldHome.utf8))) ?? P()
        var oldLib = PosterLibrary(items: [legacy], index: 0)
        let filled = oldLib.assigningFaceKind("modular")
        let addFocus = FaceGallery.focusAdd(count: filled.items.count, index: filled.index)
        check(legacy.extras.faceKind.isEmpty && legacy.extras.displayName.isEmpty && legacy.look == "Mocha" && legacy.extras.lookChosen
              && filled.items[0].extras.faceKind == "modular" && filled.index == 0 && oldLib.index == 0
              && addFocus.sel == 1 && addFocus.index == 0,
              "多臉：舊檔缺錶面種類仍讀得開；補種類不改 index；AddFace 不改目前那張")   // l10n-ignore
        var named = filled.items[0]
        named.extras.displayName = "Snoopy"
        named.extras.faceKind = "photos"
        check(named.galleryName == "Snoopy" && named.galleryFace == .photos && filled.items[0].galleryFace == .modular,
              "多臉：畫廊名字用顯示名，沒有就用錶面種類")   // l10n-ignore

        // 派生：ClockLook 與配置雙向一致        // 派生：ClockLook 與配置雙向一致
        var d = P(); var l = ClockLook(); l.font = .rail; l.swatch = .pink; l.weight = 0.2; l.glass = false
        d.clockLook = l
        check(d.typeface == .rail && d.clockLook == l && P().clockLook == ClockLook(), "海報配置：ClockLook 從配置派生（預設配置＝預設 ClockLook）")   // l10n-ignore

        // 遷移：舊鍵讀了寫新鍵；值原樣保留；舊鍵不刪；只遷一次；全新使用者不寫
        let suite = "homeplay.selftest.poster"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        defer { ud.removePersistentDomain(forName: suite) }
        _ = PosterStore.load(ud)
        check(ud.object(forKey: PosterStore.defaultsKey) == nil, "海報配置：全新使用者讀一次不留偏好（首次設定照樣會出現）")   // l10n-ignore
        var old = ClockLook(); old.font = .stencil; old.swatch = .orangePurple; old.tone = 0.8; old.weight = 0.66; old.glass = false
        ud.set("Mocha", forKey: HPLook.defaultsKey); ud.set(try? enc.encode(old), forKey: ClockLook.defaultsKey)
        let m = PosterStore.load(ud)
        check(m.look == "Mocha" && m.extras.lookChosen && m.clockLook == old && ud.data(forKey: PosterStore.defaultsKey) != nil
              && ud.string(forKey: HPLook.defaultsKey) == "Mocha" && ud.data(forKey: ClockLook.defaultsKey) != nil,
              "海報配置：舊 Look 與字體顏色原樣搬進新配置，舊鍵留著")   // l10n-ignore
        ud.set("Sage", forKey: HPLook.defaultsKey)
        check(PosterStore.load(ud).look == "Mocha", "海報配置：只遷一次（之後以新配置為準）")   // l10n-ignore
        ud.removeObject(forKey: PosterStore.defaultsKey); ud.removeObject(forKey: ClockLook.defaultsKey); ud.set("不存在", forKey: HPLook.defaultsKey)   // l10n-ignore
        let m2 = PosterStore.load(ud)
        check(m2.look == HVTruth.looks[0].name && m2.extras.lookChosen && m2.clockLook == ClockLook(), "海報配置：舊的 Look 名不合法照舊退回預設，但記得選過")   // l10n-ignore
        header(check)
    }

    /// 頁首日期：三個候選、時制、自訂原樣、數字系統（固定在 en 寫法免得跟著介面語言變）
    static func header(_ check: (Bool, String) -> Void) {
        typealias F = PosterConfiguration.DateFormat
        let ch: [F.Choice] = [F.dayAndTime.choice, F.date.choice, F(format: "EEEE", title: F.customTitle).choice]
        check(ch == [.dayAndTime, .date, .custom] && F.Choice.allCases.count == 3, "頁首日期：三個候選（星期與時間／日期／自訂）")   // l10n-ignore
        let hc: [String] = [F.hourCycled("E h:mm", twelveHour: false), F.hourCycled("E H:mm", twelveHour: true), F.hourCycled("'h' h", twelveHour: false)]
        check(hc == ["E H:mm", "E h:mm", "'h' H"], "頁首日期：時制照系統換 h／H，引號裡不動")   // l10n-ignore
        let saved = L10n.language
        L10n.language = .en
        defer { L10n.language = saved }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 22, minute: 9))!
        let tx: [String] = [F.dayAndTime.text(d, twelveHour: true), F.dayAndTime.text(d, twelveHour: false), F(format: "d MMM", title: F.customTitle).text(d)]
        check(tx == ["Sat 10:09", "Sat 22:09", "7 Nov"], "頁首日期：官方 E h:mm、自訂 ICU 原樣")   // l10n-ignore
        check(F.date.text(d) == Face.dateLine(d), "頁首日期：「日期」＝原本海報的日期行")   // l10n-ignore
        var c = PosterConfiguration(); c.dateFormat = .dayAndTime; c.numerals = .devanagari
        let ht: String = c.headerText(d)
        check(ht.hasPrefix("Sat ") && !ht.contains("1"), "頁首日期：數字照數字系統")   // l10n-ignore
    }

    /// docs/hv-reference/poster_descriptors.json（#filePath 定位 checkout；不在就略過）
    private static func evidence() -> (calendar: [String: Data], home: [Data])? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: root.appendingPathComponent("docs/hv-reference/poster_descriptors.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ps = j["providers"] as? [[String: Any]] else { return nil }
        var cal: [String: Data] = [:], home: [Data] = []
        for p in ps {
            let name = p["provider"] as? String ?? ""
            for (id, v) in (p["descriptors"] as? [String: Any]) ?? [:] {
                guard let pd = (v as? [String: Any])?["posterData"], let raw = try? JSONSerialization.data(withJSONObject: pd) else { continue }
                if name.contains("CalendarPosterExtension") { cal[id] = raw } else if name.contains("HomeFace") { home.append(raw) }
            }
        }
        return (cal, home)
    }
}
