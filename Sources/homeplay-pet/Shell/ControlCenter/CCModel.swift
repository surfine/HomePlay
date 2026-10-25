// 2.0 cc：控制中心的模組系統（純邏輯，不畫圖；--selftest 直接驗）。
//
// 照 iOS 18+／27 與 macOS 26+／27 的控制中心（本機 macOS 27 截圖 realref/macos27-cc.webp、ControlCenter.app 的字串表）：
// - 版面是一張格子：6 欄 × 5 列（HomeView 是方的 1024 畫布；macOS 是 4 欄 × 7 列的長條，iPhone 是 4 欄、一頁不夠就往下一頁）；
//   一格 128、格距 26（macOS 截圖量到的 126:26，換到我們的畫布）。
// - 模組大小：1×1 圓鈕、2×1 膠囊（Wi‑Fi、藍牙、專注模式）、2×2（播放中）、4×1 寬滑桿（顯示器、聲音）、4×2（大的播放中、家庭）。
// - 排列：每頁一串模組，照閱讀順序「第一個放得下的位置」排（iOS 編輯模式拖來拖去就是改這串的順序）；這頁放不下的擠到下一頁開頭。
// - 每位家人一份（跟 PersonHome 同一個人：PersonalGate.avatarPerson）；訪客、認不出的人、遠端訪客用預設，也不能編輯。

import AppKit

/// 模組大小（欄 × 列）
enum CCSize: String, Codable, CaseIterable {
    case s1x1, s2x1, s2x2, s4x1, s4x2
    var w: Int { switch self { case .s1x1: return 1; case .s2x1, .s2x2: return 2; case .s4x1, .s4x2: return 4 } }
    var h: Int { switch self { case .s1x1, .s2x1, .s4x1: return 1; case .s2x2, .s4x2: return 2 } }
    var cells: Int { w * h }
}

/// 一頁裡的一個模組
struct CCSlot: Codable, Equatable {
    var tile: ControlCenter.Tile
    var size: CCSize
}

/// 一個模組排好之後在格子裡的位置
struct CCPlaced: Equatable {
    var slot: CCSlot
    var col: Int
    var row: Int
}

struct CCLayout: Codable, Equatable {
    var pages: [[CCSlot]]

    static let cols = 6, rows = 5

    /// 預設（照 macOS 27 的第一頁：Wi‑Fi／藍牙膠囊、播放中 2×2、專注模式、顯示器與聲音兩條寬滑桿、底下一排圓鈕；
    /// 第二頁放勿擾模式與螢幕鏡像輸出，示範多頁）
    static let standard = CCLayout(pages: [[
        CCSlot(tile: .wifi, size: .s2x1), CCSlot(tile: .nowPlaying, size: .s2x2), CCSlot(tile: .focusMode, size: .s2x1),
        CCSlot(tile: .bluetooth, size: .s2x1), CCSlot(tile: .home, size: .s2x1),
        CCSlot(tile: .brightness, size: .s4x1), CCSlot(tile: .darkMode, size: .s1x1), CCSlot(tile: .night, size: .s1x1),
        CCSlot(tile: .volume, size: .s4x1), CCSlot(tile: .guest, size: .s1x1), CCSlot(tile: .timer, size: .s1x1),
        CCSlot(tile: .cameras, size: .s1x1), CCSlot(tile: .follow, size: .s1x1), CCSlot(tile: .carPlay, size: .s1x1),
        CCSlot(tile: .lockFace, size: .s1x1), CCSlot(tile: .alarm, size: .s1x1), CCSlot(tile: .focus, size: .s1x1),
    ], [
        CCSlot(tile: .dnd, size: .s1x1), CCSlot(tile: .screenMirroring, size: .s1x1),
    ]])

    /// 一頁的排法：照順序放在第一個放得下的位置；放不下的回傳在 overflow
    static func pack(_ page: [CCSlot]) -> (placed: [CCPlaced], overflow: [CCSlot]) {
        var used = Array(repeating: Array(repeating: false, count: cols), count: rows)
        var placed: [CCPlaced] = [], overflow: [CCSlot] = []
        for s in page {
            var spot: (Int, Int)?
            search: for r in 0...(rows - s.size.h) {
                for c in 0...(cols - s.size.w) {
                    var free = true
                    for dr in 0..<s.size.h { for dc in 0..<s.size.w where used[r + dr][c + dc] { free = false } }
                    if free { spot = (c, r); break search }
                }
            }
            guard let (c, r) = spot else { overflow.append(s); continue }
            for dr in 0..<s.size.h { for dc in 0..<s.size.w { used[r + dr][c + dc] = true } }
            placed.append(CCPlaced(slot: s, col: c, row: r))
        }
        return (placed, overflow)
    }

    /// 整理：每頁放不下的擠到下一頁開頭；重複的模組只留第一個；空頁拿掉（至少留一頁）
    func normalized() -> CCLayout {
        var seen = Set<ControlCenter.Tile>()
        var queue = pages.map { $0.filter { seen.insert($0.tile).inserted && $0.tile.sizes.contains($0.size) } }
        var out: [[CCSlot]] = []
        var i = 0
        while i < queue.count {
            let (placed, overflow) = Self.pack(queue[i])
            out.append(placed.map(\.slot))
            if !overflow.isEmpty {
                if i + 1 < queue.count { queue[i + 1] = overflow + queue[i + 1] } else { queue.append(overflow) }
            }
            i += 1
        }
        out.removeAll { $0.isEmpty }
        return CCLayout(pages: out.isEmpty ? [[]] : out)
    }

    var all: [CCSlot] { pages.flatMap { $0 } }
    func contains(_ t: ControlCenter.Tile) -> Bool { all.contains { $0.tile == t } }
    func page(of t: ControlCenter.Tile) -> Int? { pages.firstIndex { $0.contains { $0.tile == t } } }

    /// 拿掉一個模組
    mutating func remove(_ t: ControlCenter.Tile) {
        for i in pages.indices { pages[i].removeAll { $0.tile == t } }
        self = normalized()
    }
    /// 加到某一頁的最後（放不下就往後擠，跟 iOS「加入控制項目」一樣）
    mutating func add(_ t: ControlCenter.Tile, page p: Int) {
        guard !contains(t) else { return }
        let i = max(0, min(p, pages.count - 1))
        pages[i].append(CCSlot(tile: t, size: t.defaultSize))
        self = normalized()
    }
    /// 換下一種大小（只在模組允許的大小裡轉）
    mutating func resize(_ t: ControlCenter.Tile) {
        guard let p = page(of: t), let k = pages[p].firstIndex(where: { $0.tile == t }) else { return }
        let sizes = t.sizes
        guard sizes.count > 1, let cur = sizes.firstIndex(of: pages[p][k].size) else { return }
        pages[p][k].size = sizes[(cur + 1) % sizes.count]
        self = normalized()
    }
    /// 拖到某一頁的第 index 個（編輯模式拖曳）
    mutating func move(_ t: ControlCenter.Tile, toPage p: Int, index: Int) {
        guard let from = page(of: t), let k = pages[from].firstIndex(where: { $0.tile == t }) else { return }
        let s = pages[from].remove(at: k)
        while pages.count <= p { pages.append([]) }
        let i = max(0, min(index, pages[p].count))
        pages[p].insert(s, at: i)
        self = normalized()
    }
    /// 加一頁空白頁（編輯模式往最後一頁之後拖）
    mutating func appendPage() { if !(pages.last?.isEmpty ?? true) { pages.append([]) } }
}

/// 控制中心「加入控制項目」圖庫的分類（名稱照 ControlCenter.app 的 BentoGallery 字串）
enum CCCategory: CaseIterable {
    case connectivity, display, sound, focus, home, clock, homePlay
    var title: String {
        switch self {
        case .connectivity: return L("cc.cat.connectivity", "连接状态")
        case .display: return L("cc.cat.display", "显示与亮度")
        case .sound: return L("cc.cat.sound", "声音")
        case .focus: return L("cc.focusMode", "专注模式")
        case .home: return L("cc.home", "家庭")
        case .clock: return L("cc.cat.clock", "时钟")
        case .homePlay: return "HomePlay"
        }
    }
}

// MARK: - 每人一份（跟 PersonHome 同一套人）

enum PersonCC {
    static let key = "shell.ccLayouts"
    /// 快照、自檢、示範不寫偏好
    nonisolated(unsafe) static var persist = !CCSystem.demo
    nonisolated(unsafe) static var layouts: [String: CCLayout] = {
        guard let raw = UserDefaults.standard.data(forKey: key), let d = try? JSONDecoder().decode([String: CCLayout].self, from: raw) else { return [:] }
        return d.mapValues { $0.normalized() }
    }()
    static func layout(for id: String?) -> CCLayout {
        guard let id, let l = layouts[id] else { return .standard }
        return l
    }
    static var viewerID: String? { PersonHome.viewerID }
    static var current: CCLayout { layout(for: viewerID) }
    /// 能不能編輯：認得出是誰、不是訪客模式、沒有遠端訪客在用（不替別人改他的控制中心）
    static var canEdit: Bool { PersonHome.canEdit && !PersonalGate.inputs.remoteGuest }
    static func set(_ l: CCLayout, for id: String) {
        let n = l.normalized()
        layouts[id] = n == CCLayout.standard.normalized() ? nil : n
        guard persist else { return }
        if let raw = try? JSONEncoder().encode(layouts) { UserDefaults.standard.set(raw, forKey: key) }
    }
    static func prune(keeping ids: Set<String>) { layouts = layouts.filter { ids.contains($0.key) } }
}

// MARK: - selftest

enum CCModelSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        let std = CCLayout.standard.normalized()
        check(std == CCLayout.standard, "控制中心：預設版面排得下、不用擠頁")
        let p0 = CCLayout.pack(std.pages[0]).placed
        func at(_ t: ControlCenter.Tile) -> (Int, Int)? { p0.first { $0.slot.tile == t }.map { ($0.col, $0.row) } }
        check(at(.wifi)! == (0, 0) && at(.nowPlaying)! == (2, 0) && at(.focusMode)! == (4, 0) && at(.bluetooth)! == (0, 1)
              && at(.brightness)! == (0, 2) && at(.volume)! == (0, 3) && at(.cameras)! == (0, 4), "控制中心：第一頁照 macOS 27 的排法（\(p0.map { "\($0.slot.tile)@\($0.col),\($0.row)" })）")   // l10n-ignore：selftest 訊息
        check(p0.reduce(0) { $0 + $1.slot.size.cells } == 30, "控制中心：第一頁 6×5 剛好排滿")
        // 不重疊
        var cells = Set<Int>()
        let overlap = p0.contains { p in (0..<p.slot.size.h).contains { dr in (0..<p.slot.size.w).contains { dc in !cells.insert((p.row + dr) * 10 + p.col + dc).inserted } } }
        check(!overlap, "控制中心：模組不重疊")
        // 放大一個：放不下的擠到下一頁
        var l = std
        l.resize(.nowPlaying)   // 2×2 → 4×2
        check(l.pages[0].first { $0.tile == .nowPlaying }?.size == .s4x2 && l.pages.count >= 2 && l.all.count == std.all.count,
              "控制中心：播放中放大成 4×2，放不下的擠到下一頁，模組一個都沒少")   // l10n-ignore：selftest 訊息
        l.resize(.nowPlaying); l.resize(.nowPlaying)
        check(l.pages[0].contains { $0.tile == .nowPlaying && $0.size == .s2x2 }, "控制中心：大小照允許的轉一圈回到 2×2")
        // 拿掉、加回
        var r = std
        r.remove(.cameras)
        check(!r.contains(.cameras) && r.all.count == std.all.count - 1, "控制中心：移除攝影機")
        r.add(.cameras, page: 0)
        check(r.page(of: .cameras) == 0 && r.pages[0].last?.tile == .cameras, "控制中心：加入的放在那一頁最後")
        r.add(.cameras, page: 1)
        check(r.all.filter { $0.tile == .cameras }.count == 1, "控制中心：同一個模組不會加兩次")
        // 搬順序
        var m = std
        m.move(.dnd, toPage: 0, index: 0)
        check(m.pages[0].first?.tile == .dnd && m.all.count == std.all.count, "控制中心：拖到第一頁第一個，後面往後擠")
        m.move(.dnd, toPage: 1, index: 0)
        check(m.page(of: .dnd) == 1, "控制中心：拖回第二頁")
        // 大小不合法的丟掉、空頁拿掉
        let bad = CCLayout(pages: [[], [CCSlot(tile: .wifi, size: .s4x2), CCSlot(tile: .guest, size: .s1x1)], []]).normalized()
        check(bad.pages.count == 1 && bad.all.map(\.tile) == [.guest], "控制中心：不允許的大小不留、空頁拿掉")
        // 編碼來回
        let data = try? JSONEncoder().encode(std)
        check(data.flatMap { try? JSONDecoder().decode(CCLayout.self, from: $0) } == std, "控制中心：版面存成 JSON 再讀回一樣")
        // 每人一份
        let saved = (PersonCC.layouts, PersonCC.persist)
        defer { PersonCC.layouts = saved.0; PersonCC.persist = saved.1 }
        PersonCC.persist = false; PersonCC.layouts = [:]
        var kid = std; kid.remove(.carPlay)
        PersonCC.set(kid, for: "kid")
        check(PersonCC.layout(for: "kid") == kid && PersonCC.layout(for: "owner") == std && PersonCC.layout(for: nil) == std,
              "控制中心：每人一份；沒存過的人與訪客用預設")   // l10n-ignore：selftest 訊息
        PersonCC.set(std, for: "kid")
        check(PersonCC.layouts["kid"] == nil, "控制中心：改回預設就不另外存")
        // 每個模組都有分類、標題、預設大小在允許的大小裡
        check(ControlCenter.Tile.allCases.allSatisfy { $0.sizes.contains($0.defaultSize) && !ControlCenter.title($0).isEmpty },
              "控制中心：每個模組都有標題，預設大小合法")   // l10n-ignore：selftest 訊息
        // 訪客的門：訪客模式時動到整台 Mac 的鎖起來、訪客自己關不掉訪客模式（沒認人時主人照開，所以關得掉）
        let g0 = Shell.guestMode
        Shell.guestMode = true
        check(ControlCenter.locked(.wifi) && ControlCenter.locked(.focusMode) && !ControlCenter.locked(.volume) && !ControlCenter.locked(.nowPlaying),
              "控制中心：訪客模式鎖 Wi‑Fi、專注模式，音量與播放照開")   // l10n-ignore：selftest 訊息
        check(ControlCenter.canLeaveGuest == PersonalGate.allowed({ var i = PersonalGate.inputs; i.guestMode = false; return i }()), "控制中心：關訪客模式要過主人的門")
        Shell.guestMode = g0
        // 遠端訪客（訪客的 iPhone／iPad 在用）：改狀態或露資料的全部拒絕
        typealias I = PersonalGate.Inputs
        let rg = I(remoteGuest: true), owner = I()
        let sensitive: [ControlCenter.Tile] = [.follow, .guest, .focusMode, .dnd, .focus, .night, .home, .cameras, .wifi, .bluetooth, .carPlay, .lockFace, .darkMode, .screenMirroring]
        check(sensitive.allSatisfy { ControlCenter.locked($0, rg) } && ControlCenter.remoteGuestAllowed.allSatisfy { !ControlCenter.locked($0, rg) },
              "控制中心：遠端訪客鎖住所有改狀態、露資料的模組，只留音量、亮度、計時器、鬧鐘、播放中")   // l10n-ignore：selftest 訊息
        let acts: [CCHit.Action] = [.output(1), .airplay, .homeTile("x"), .scene("s"), .btDevice("a"), .focusMode("f"), .wifiRow, .module(.follow), .header(.wifi), .nightRow]
        check(acts.allSatisfy { ControlCenter.refuses($0, rg) } && !acts.contains { ControlCenter.refuses($0, owner) && $0 != .homeTile("x") && $0 != .scene("s") },
              "控制中心：遠端訪客的點按一律拒絕（播放、輸出、家庭、藍牙、專注、Wi‑Fi、跟隨我、夜間）；主人照收")   // l10n-ignore：selftest 訊息
        check(!ControlCenter.locked(.wifi, owner) && !ControlCenter.locked(.nowPlaying, owner), "控制中心：沒有訪客時主人照用")
        check(!ControlCenter.refuses(.npPlay, rg) && !ControlCenter.refuses(.npNext, rg) && ControlCenter.refuses(.airplay, rg), "控制中心：遠端訪客可以播放、切歌，不能換輸出")   // l10n-ignore：selftest 訊息
        check(CCCategory.allCases.allSatisfy { c in ControlCenter.Tile.allCases.contains { $0.category == c } }, "控制中心：圖庫每個分類都有東西")
    }
}
