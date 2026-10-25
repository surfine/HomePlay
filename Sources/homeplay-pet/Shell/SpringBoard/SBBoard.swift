// 2.0 SpringBoard：主畫面執行時的狀態（編輯模式、拖曳、換頁、資料夾、選單與 sheet）、幾何與動作。
// 排列的純邏輯在 SBModel.swift；畫在 SBRender.swift；滑鼠、鍵盤、輔助使用在 SBInput.swift。
//
// 動態（照本機 iOS 27 模擬器量的，scratchpad/realref/ios27-springboard/measurements.md；量不到的標「推斷」）：
// - 換頁：放手到停約 0.30–0.35 s、沒有回彈 → 臨界阻尼 settling(0.33)；跟手時 1:1，超過頭尾 rubber band，放手照 Apple 的投射挑頁。
// - 按住圖示約 0.65 s 出選單、按住桌布約 0.85 s 進編輯模式（含系統延遲的估計；我們用 0.55／0.8）。
// - 拖曳時其他項目讓開：彈簧 damping 0.86、response 0.42（推斷：模擬器的拖曳量不到）；拖到螢幕邊停 0.5 s 翻頁（推斷，iOS 的體感）。
// - 晃動（jiggle）：±1.6°、週期 0.26 s、相鄰的反相（推斷：模擬器這一版不晃）；減少動態效果時不晃、移動改淡入。

import AppKit

enum SBMotion {
    static let page = Spring.settling(0.33)
    static let reflow = Spring(damping: 0.86, response: 0.42)
    static let lift = Spring.interactive
    static let settle = Spring.snappy
    static let folder = Spring.settling(0.32)
    static let menu = Spring.settling(0.22)
    static let stack = Spring.settling(0.3)
    static let wiggleDegrees: CGFloat = 1.6
    static let wigglePeriod: Double = 0.26
    static let longPressIcon = 0.55
    static let longPressEmpty = 0.8
    static let edgeDwell = 0.5
    static let folderDwell = 0.35
    /// 換位置前要停多久：Launcher3 650 ms（太慢）、Muuri 100 ms；取 0.25 s。格子還有遲滯（SB.cell(forTopLeft:current:)），不會在兩格中間來回跳
    static let reorderDwell = 0.25
    /// 翻頁後要再停多久才能再翻（Launcher3 ENTER_SPRING_LOAD_CANCEL_HOVER_TIME 950 ms）
    static let edgeRearm = 0.95
    /// 拿起來放大（推斷：iOS 拿起的圖示約大 10%）
    static let liftScale: CGFloat = 1.1
}

/// 右鍵／長按選單裡的一個動作
enum SBAction: Equatable {
    case editHome, removeItem(String), editWidget(String), editStack(String), rename(String), resize(String, SBWidgetSize)
    case addWidget, customize, editPages, addToHome(String), openApp(String)
    case provider(String, String)   // 2.0 App 平台：提供者自己加的列（App id、verb；Shell/AppPlatform）
}

struct SBMenuRow: Equatable {
    var action: SBAction
    var title: String
    var symbol: String
    var destructive = false
}

struct SBMenu {
    var anchor: CGRect          // 被長按的那一格（畫在壓暗層上面）
    var key: String?
    var appID: String?          // App 資料庫裡長按的 App
    var rows: [SBMenuRow]
    var sizes: [SBWidgetSize]   // 小工具：上排的尺寸切換（iOS 18 起）
    var current: SBWidgetSize?
    var presence: MotionValue
    var panel: CGRect = .zero
}

enum SBSheet: Equatable {
    case gallery(kind: SBWidgetKind?, stack: Bool, page: Int)
    case config(String)
    case stackEdit(String)
    case customize
    case editPages
    case removeConfirm(String)
}

struct SBDrag {
    var item: SBItem
    var key: String
    var fromPage: Int?          // 原本在哪一頁（layout.pages 的索引）；從 App 資料庫拖出來的是 nil
    var fromIndex: Int?
    var grab: CGPoint           // 指標在項目框裡的位置
    var point: CGPoint
    var target: (col: Int, row: Int)?
    var pendingTarget: (col: Int, row: Int)?
    var pendingSince = 0.0
    var folderTarget: String?
    var folderSince = 0.0
    var folderReady = false
    var edgeDir = 0
    var edgeSince = 0.0
    var lastFlip = -10.0
    var lift: MotionValue
    var resizing = false        // 拖小工具右下角的把手改大小
}

struct SBOpenFolder {
    var id: String
    var page = 0
    var anim: MotionValue
    var closing = false
    var renaming = false
    var from: CGRect
    var backdrop: CGImage?
}

enum SB {
    // MARK: 排列（現在這個人的）

    nonisolated(unsafe) static var owner: String?? = .none
    nonisolated(unsafe) static var working = SBLayout.official
    /// 現在主畫面是誰的排列；換人就重讀
    static var layout: SBLayout {
        get {
            let v = PersonHome.viewerID
            if owner != .some(v) {
                let first = owner == .none
                owner = .some(v); working = forcedLayout ?? SBStore.layout(for: v)
                if !first {   // 換人才清（第一次載入不清：快照旗標先設好的 sheet 要留著）；編輯模式不帶到別人的主畫面
                    Shell.homeEditing = false; Shell.widgetGallery = false; wasEditing = false
                    pageDragging = false; stackDrag = nil; SBInputState.press = nil
                    resetTransient()
                }
            }
            return working
        }
        set { working = newValue }
    }
    /// 存起來（訪客、認不出的人不存）
    static func commit() {
        if let v = PersonHome.viewerID, PersonHome.canEdit, forcedLayout == nil { SBStore.set(working, for: v) }
        Shell.homeLayer = nil
        pageCache.removeAll()
    }
    static func resetTransient() {
        drag = nil; menu = nil; sheet = nil; folder = nil; anims.removeAll(); pageCache.removeAll()
        page = min(page, max(0, visiblePages.count - 1))
        pagePos = MotionValue("sbpage", spring: SBMotion.page, from: CGFloat(page), to: CGFloat(page), now: 0)
        libraryScrollDragging = false; libraryScrollSamples = []
        libraryScroll = MotionValue("sbLibScroll", spring: SBMotion.settle, from: 0, to: 0, now: 0)
    }
    /// 快照：--home-layout demo|pages|folder|stack|sizes（固定的示範排列，不讀也不寫存檔）
    nonisolated(unsafe) static var forcedLayout: SBLayout? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--home-layout"), i + 1 < a.count else { return nil }
        return SBDemo.layout(a[i + 1])
    }()

    // MARK: 頁

    /// 看得到的頁（沒隱藏的）在 layout.pages 裡的索引
    static var visiblePages: [Int] {
        let l = layout
        let v = l.pages.indices.filter { !l.pages[$0].hidden }
        return v.isEmpty ? [0] : v
    }
    nonisolated(unsafe) static var page = 0
    nonisolated(unsafe) static var pagePos = MotionValue("sbpage", spring: SBMotion.page, from: 0, to: 0, now: 0)
    nonisolated(unsafe) static var pageDragging = false
    nonisolated(unsafe) static var pageSamples: [(t: Double, x: CGFloat)] = []
    static var pageIndex: Int { visiblePages[min(page, visiblePages.count - 1)] }
    static func pagePosition(_ now: Double) -> CGFloat {
        pageDragging ? pageDragValue : (pagePos.done(now) ? CGFloat(page) : pagePos.value(now))
    }
    nonisolated(unsafe) static var pageDragValue: CGFloat = 0

    static func goToPage(_ p: Int, now: Double, velocity: CGFloat = 0, from start: CGFloat? = nil) {
        let n = visiblePages.count
        let to = max(0, min(n - 1, p))
        let from = start ?? pagePosition(now)
        page = to
        pageDragging = false
        pagePos = MotionValue("sbpage", spring: SBMotion.page, from: from, to: CGFloat(to), velocity: velocity, now: now)
        anims.removeAll()
    }

    // MARK: 編輯模式

    static var editing: Bool { Shell.homeEditing }
    nonisolated(unsafe) static var editSince = 0.0
    nonisolated(unsafe) static var wasEditing = false
    nonisolated(unsafe) static var largeIcons: Bool = CommandLine.arguments.contains("--home-large-icons") || UserDefaults.standard.bool(forKey: largeKey)
    static let largeKey = "shell.homeLargeIcons"
    static func setLargeIcons(_ on: Bool) {
        largeIcons = on
        if !CommandLine.arguments.contains("--home-large-icons") { UserDefaults.standard.set(on, forKey: largeKey) }
        Shell.homeLayer = nil; pageCache.removeAll()
    }

    static func enterEdit(now: Double) {
        guard PersonHome.canEdit || forcedLayout != nil else { return }
        if !Shell.homeEditing { editSince = now }
        Shell.homeEditing = true; wasEditing = true
        menu = nil
        let ids = Set(PeopleRegistry.shared.people.map(\.id))
        if !ids.isEmpty { SBStore.prune(keeping: ids) }
        log("sb edit on")
    }
    /// 完成：拿掉空頁、存檔
    static func exitEdit() {
        Shell.homeEditing = false; Shell.widgetGallery = false; wasEditing = false
        drag = nil; menu = nil; sheet = nil
        if folder?.renaming == true { folder?.renaming = false }
        var l = layout
        l.normalize(dropEmpty: true)
        layout = l
        page = min(page, visiblePages.count - 1)
        pagePos = MotionValue("sbpage", spring: SBMotion.page, from: CGFloat(page), to: CGFloat(page), now: 0)
        commit()
        log("sb edit off")
    }

    // MARK: 選單、sheet、資料夾、拖曳

    nonisolated(unsafe) static var menu: SBMenu?
    nonisolated(unsafe) static var sheet: SBSheet? = CommandLine.arguments.contains("--widget-gallery") ? .gallery(kind: nil, stack: false, page: 0) : nil
    nonisolated(unsafe) static var folder: SBOpenFolder?
    nonisolated(unsafe) static var drag: SBDrag?
    nonisolated(unsafe) static var pressedKey: String?
    nonisolated(unsafe) static var libraryQuery = ""
    nonisolated(unsafe) static var librarySearching = false
    // MARK: App 資料庫捲動（2.0 depth：第 17 個 App 起畫在螢幕外點不到；iOS 的資料庫可以捲）
    nonisolated(unsafe) static var libraryScroll = MotionValue("sbLibScroll", spring: SBMotion.settle, from: 0, to: 0, now: 0)
    nonisolated(unsafe) static var libraryScrollDragging = false
    nonisolated(unsafe) static var libraryScrollDrag: CGFloat = 0
    nonisolated(unsafe) static var libraryScrollSamples: [(t: Double, y: CGFloat)] = []

    /// 內容比畫面高多少（px）；0＝不用捲（16 個內建 App 剛好四列）
    static var libraryMaxScroll: CGFloat {
        let rows = (SBUI.libraryApps().count + 3) / 4
        return max(0, SBUI.libraryTop + CGFloat(rows - 1) * SBUI.libraryRowPitch + SBUI.libraryRowHeight - (1024 - 30))
    }
    static var libraryScrollNow: CGFloat { libraryScrollDragging ? libraryScrollDrag : libraryScroll.value(CACurrentMediaTime()) }
    /// 兩頭的橡皮筋（拖的時候用）
    static func libraryRubber(_ y: CGFloat) -> CGFloat {
        let m = libraryMaxScroll
        if y < 0 { return -HPMotion.rubberBand(-y, 400) }
        if y > m { return m + HPMotion.rubberBand(y - m, 400) }
        return y
    }
    /// 拖完放手：照最後的速度投射落點，彈簧回去（速度單位 px/s）
    static func libraryScrollEnd(now: Double) {
        guard libraryScrollDragging else { return }
        var v: CGFloat = 0
        if let a = libraryScrollSamples.first, let b = libraryScrollSamples.last, b.t - a.t > 0.004 { v = (b.y - a.y) / CGFloat(b.t - a.t) }
        if let b = libraryScrollSamples.last, now - b.t > 0.08 { v = 0 }
        libraryScrollSamples = []
        libraryScrollDragging = false
        let to = max(0, min(libraryMaxScroll, libraryScrollDrag + HPMotion.project(v)))
        libraryScroll.retarget(to, now: now, velocity: v)
        SBInputState.libWheel = nil
    }
    /// 動畫中的位置（key → x、y 彈簧；只算目前這一頁）
    nonisolated(unsafe) static var anims: [String: (x: MotionValue, y: MotionValue, page: Int)] = [:]
    /// 減少動態效果時：位置一變就淡入（key → 開始時刻）
    nonisolated(unsafe) static var fades: [String: Double] = [:]
    /// Smart Stack：滑動中（key → 偏移 px）、放手後的彈簧、最近一次換的時刻（右邊的頁點亮一下）
    nonisolated(unsafe) static var stackDrag: (key: String, offset: CGFloat, samples: [(t: Double, y: CGFloat)])?
    nonisolated(unsafe) static var stackAnim: [String: MotionValue] = [:]
    nonisolated(unsafe) static var stackShown: [String: Double] = [:]
    nonisolated(unsafe) static var lastRotateCheck = -1e9
    nonisolated(unsafe) static var pageCache: [String: CGImage] = [:]
    nonisolated(unsafe) static var homeVisible = false

    static var overlayOpen: Bool { menu != nil || sheet != nil || folder != nil }
    /// 主畫面要不要每幀重畫
    static func animating(_ now: Double) -> Bool {
        if drag != nil || pageDragging || stackDrag != nil { return true }
        if editing && !HPMotion.reduceMotion && sheet == nil && folder == nil { return true }   // 晃動
        if !pagePos.done(now) { return true }
        if libraryScrollDragging || !libraryScroll.done(now) { return true }   // 2.0 depth：資料庫捲動
        if anims.values.contains(where: { !$0.x.done(now) || !$0.y.done(now) }) { return true }
        if !fades.isEmpty { return true }
        if let m = menu, !m.presence.done(now) { return true }
        if let f = folder, !f.anim.done(now) { return true }
        if stackAnim.values.contains(where: { !$0.done(now) }) { return true }
        if stackShown.values.contains(where: { CACurrentMediaTime() - $0 < 1.8 }) { return true }
        return false
    }

    // MARK: 幾何

    static func originX(_ c: Int) -> CGFloat { Shell.iconRect(in: Shell.cell(c, 0)).minX }
    static func originY(_ r: Int) -> CGFloat { Shell.cell(0, r).minY }
    /// 一個項目在格子上的框：圖示＝一格（含標籤）；小工具＝圖示外緣上下對齊、左右各多 7（官方 Photos）
    static func frame(col c: Int, row r: Int, span: (w: Int, h: Int)) -> CGRect {
        if span.w == 1 && span.h == 1 { return Shell.cell(c, r) }
        let a = Shell.iconRect(in: Shell.cell(c, r)), b = Shell.iconRect(in: Shell.cell(c + span.w - 1, r + span.h - 1))
        let h = b.maxY - a.minY
        if span.w == 2 && span.h == 2 { return Shell.widgetRect(col: c, row: r) }
        return CGRect(x: a.minX - 7, y: a.minY, width: b.maxX - a.minX + 14, height: h)
    }
    static func frame(_ p: SBPlacement) -> CGRect { frame(col: p.col, row: p.row, span: (p.w, p.h)) }
    /// 圖示本體（大圖示：放大、填掉標籤的位置）
    static func iconRect(in cell: CGRect) -> CGRect {
        guard largeIcons else { return Shell.iconRect(in: cell) }
        let s: CGFloat = 186
        return CGRect(x: cell.midX - s / 2, y: cell.minY + (cell.height - s) / 2 - 2, width: s, height: s)
    }
    /// 項目的框左上角 → 最近的格子（夾在放得下的範圍）
    static func cell(forTopLeft p: CGPoint, span: (w: Int, h: Int), current: (col: Int, row: Int)? = nil) -> (col: Int, row: Int) {
        let isIcon = span.w == 1 && span.h == 1
        let fx = (p.x + (isIcon ? 0 : 7) - originX(0)) / HPTokens.Home.columnPitch, fy = (p.y - originY(0)) / HPTokens.Home.rowPitch
        var c = Int(fx.rounded()), r = Int(fy.rounded())
        // 遲滯：要越過兩格中線再多 15% 才換格（gridstack 的「重疊過半」、Launcher3 的 reorder radius 同一個用意）
        if let cur = current {
            if abs(fx - CGFloat(cur.col)) < 0.65 { c = cur.col }
            if abs(fy - CGFloat(cur.row)) < 0.65 { r = cur.row }
        }
        return (max(0, min(SBLayout.cols - span.w, c)), max(0, min(SBLayout.rows - span.h, r)))
    }
    /// 點按範圍：圖示只算圖示本體（往外 12）；小工具整塊
    static func hitRect(_ p: SBPlacement) -> CGRect {
        let f = frame(p)
        return p.item.isIcon ? iconRect(in: f).insetBy(dx: -12, dy: -12) : f
    }
    /// 目前這一頁的項目與框（拖曳中：被拖的不在裡面，其他照預覽的位置）
    static func placements(page pi: Int) -> [SBPlacement] {
        let l = layout
        guard pi < l.pages.count else { return [] }
        return SBLayout.pack(l.pages[pi].items).placed.filter { !$0.item.isSpacer }
    }
    /// 拖曳時這一頁「放下去會變成的樣子」（不含被拖的那個）
    static func displayItems(page pi: Int) -> [SBItem] {
        let l = layout
        guard pi < l.pages.count else { return [] }
        guard let d = drag, !d.resizing else { return l.pages[pi].items }
        var base = l.pages[pi].items
        if let fp = d.fromPage, fp == pi, let fi = d.fromIndex, fi < base.count, base[fi].key == d.key { base.remove(at: fi) }
        guard pi == pageIndex, let t = d.target, d.folderTarget == nil || !d.folderReady else { return base }
        let ck = "\(pi)|\(t.col),\(t.row)|\(d.key)|\(l.pages[pi].items.compactMap(\.key).joined(separator: ","))|\(l.pages[pi].items.count)"
        if let c = dropCache, c.key == ck { return c.items }
        let ref = SBLayout.positions(l.pages[pi].items)
        let hole = d.fromPage == pi ? d.fromIndex : nil
        let dropped = SBLayout.drop(d.item, into: base, at: t, hole: hole, reference: ref)
        let out = dropped.map { $0.key == d.key ? .spacer : $0 }   // 被拖的那格先空著（它在指標底下）
        dropCache = (ck, out)
        return out
    }

    /// 給外殼其他地方（App 縮回圖示、輔助使用、selftest）：目前這一頁的項目；資料夾裡的 App 落在資料夾那一格（開著時落在資料夾面板的格子）
    static func homeItems() -> [(CGRect, HomeItem)] {
        var widgets: [(CGRect, HomeItem)] = [], apps: [(CGRect, HomeItem)] = [], inFolders: [(CGRect, HomeItem)] = []
        for pl in placements(page: pageIndex) {
            guard let key = pl.item.key else { continue }
            let f = frame(pl)
            switch pl.item {
            case .app(let id): apps.append((f, .app(id)))
            case .widget(let w):
                let legacy: HomeItem? = w.size == .small ? (w.kind == .photos ? .photos : w.kind == .weather ? .weather : w.kind == .worldClock ? .worldClock : nil) : nil
                widgets.append((f, legacy ?? .sb(key)))
            case .stack: widgets.append((f, .sb(key)))
            case .folder(let fo):
                apps.append((f, .sb(key)))
                if let o = folder, o.id == fo.id { for (id, c) in zip(fo.apps.prefix(SBFolder.pageSize), SBUI.folderCells()) { inFolders.append((c, .app(id))) } }
                else { inFolders += fo.apps.map { (f, .app($0)) } }
            case .spacer: break
            }
        }
        return widgets + apps + inFolders
    }
    static func libraryItems() -> [(CGRect, HomeItem)] {
        let apps = SBUI.libraryApps()
        return zip(apps, SBUI.libraryCells(apps.count)).map { ($0.1, .app($0.0.id)) }
    }

    // MARK: 編輯動作

    static func remove(_ key: String) {
        var l = layout
        if key.hasPrefix("a:") { l.removeApp(String(key.dropFirst(2))) } else { l.remove(key) }
        l.normalize()
        layout = l; commit()
        log("sb remove \(key)")
    }
    static func resize(_ key: String, to size: SBWidgetSize) {
        var l = layout
        guard let it = l.item(key) else { return }
        switch it {
        case .widget(var w) where w.kind.sizes.contains(size): w.size = size; l.replace(key, with: .widget(w))
        case .stack(var s):
            s.size = size
            s.widgets = s.widgets.filter { $0.kind.sizes.contains(size) }.map { var x = $0; x.size = size; return x }
            if s.widgets.isEmpty { return }
            l.replace(key, with: .stack(s))
        default: return
        }
        l.normalize()
        layout = l; commit()
    }
    static func addWidget(_ kind: SBWidgetKind, size: SBWidgetSize) {
        var l = layout
        l.addWidget(.widget(SBWidget(id: SBStore.newID("w"), kind: kind, size: size)), page: pageIndex)
        layout = l; commit()
        log("sb add widget \(kind.rawValue) \(size.rawValue)")
    }
    /// Smart Stack 的預設內容（照 iOS：天氣、行事曆、照片、提醒事項…這個大小放得下的）
    static func addStack(size: SBWidgetSize) {
        let kinds: [SBWidgetKind] = [.weather, .calendar, .photos, .reminders, .music, .worldClock].filter { $0.sizes.contains(size) }
        let ws = kinds.map { SBWidget(id: SBStore.newID("w"), kind: $0, size: size) }
        var l = layout
        l.addWidget(.stack(SBStack(id: SBStore.newID("s"), size: size, widgets: ws)), page: pageIndex)
        layout = l; commit()
    }
    static func addToHome(_ app: String) {
        var l = layout
        l.addApp(app)
        layout = l; commit()
        log("sb add to home \(app)")
    }
    static func setConfig(_ key: String, _ opt: String, _ value: String) {
        var l = layout
        guard let it = l.item(key) else { return }
        if case .widget(var w) = it { w.config[opt] = value; l.replace(key, with: .widget(w)); layout = l; commit() }
    }
    static func updateStack(_ key: String, _ f: (inout SBStack) -> Void) {
        var l = layout
        guard case .stack(var s)? = l.item(key) else { return }
        f(&s)
        if s.widgets.isEmpty { l.remove(key) }
        else if s.widgets.count == 1 { l.replace(key, with: .widget(s.widgets[0])) }   // 只剩一個：拆回一般小工具（iOS 一樣）
        else { s.index = max(0, min(s.index, s.widgets.count)); l.replace(key, with: .stack(s)) }   // 可以停在最後的建議那一格
        layout = l; commit()
    }
    static func renameFolder(_ id: String, _ name: String) {
        var l = layout
        guard case .folder(var f)? = l.item("f:\(id)") else { return }
        f.name = name
        l.replace("f:\(id)", with: .folder(f))
        layout = l; commit()
    }
    static func togglePageHidden(_ pi: Int) {
        var l = layout
        guard pi < l.pages.count else { return }
        l.pages[pi].hidden.toggle()
        if l.pages.allSatisfy(\.hidden) { l.pages[pi].hidden = false }   // 至少留一頁
        layout = l
        page = min(page, visiblePages.count - 1)
        commit()
    }
    static func deletePage(_ pi: Int) {
        var l = layout
        guard pi < l.pages.count, l.pages.count > 1, l.pages[pi].hidden else { return }
        l.pages.remove(at: pi)   // 刪掉隱藏的頁：上面的 App 回到 App 資料庫（iOS 一樣）
        layout = l
        page = min(page, visiblePages.count - 1)
        commit()
    }
    static func resetLayout() {
        guard let v = PersonHome.viewerID else { return }
        SBStore.reset(v)
        owner = .none
        _ = layout
        Shell.homeLayer = nil
    }

    // MARK: Smart Stack

    /// 疊放這一刻顯示的小工具清單（小工具建議放最上面）
    static func stackWidgets(_ s: SBStack, face: Face?, now: Double) -> [SBWidget] {
        let timer = !Shell.timers.isEmpty
        let music = face.map { $0.musicActive(now) } ?? false
        if let k = s.suggestion(timerRunning: timer, musicPlaying: music) {
            return s.widgets + [SBWidget(id: "\(s.id)-suggest", kind: k, size: s.size)]   // 建議放最後一格（index 才不會錯位）
        }
        return s.widgets
    }
    static func stackStep(_ key: String, by d: Int, now: Double) {
        guard case .stack(let s)? = layout.item(key) else { return }
        let n = stackWidgets(s, face: nil, now: now).count
        let to = max(0, min(n - 1, s.index + d))
        guard to != s.index else { return }
        updateStack(key) { $0.index = to }
        let h = frame(col: 0, row: 0, span: s.size.span).height
        stackAnim[key] = MotionValue("sbstack", spring: SBMotion.stack, from: CGFloat(d) * h, to: 0, now: now)
        stackShown[key] = now
    }
    /// 智慧型旋轉：回到主畫面時，照時段換到最相關的那個
    static func smartRotate(now: Double) {
        var l = layout, changed = false
        let hour = Calendar.current.component(.hour, from: Face.displayDate)
        for p in l.pages.indices {
            for i in l.pages[p].items.indices {
                guard case .stack(var s) = l.pages[p].items[i], s.smartRotate else { continue }
                let r = s.rotatedIndex(hour: hour)
                if r != s.index { s.index = r; l.pages[p].items[i] = .stack(s); changed = true }
            }
        }
        if changed { layout = l; commit() }
    }

    // MARK: 每幀

    static func tick(_ face: Face, now: Double) -> Bool {
        var dirty = false
        if wasEditing && !Shell.homeEditing { exitEdit(); dirty = true }   // 外面關掉（沒人看回錶面）
        if Shell.homeEditing && !wasEditing { wasEditing = true; editSince = now }
        let visible = Shell.nav.screen == .home
        if visible && !homeVisible, now - lastRotateCheck > 600 { lastRotateCheck = now; smartRotate(now: now) }
        if !visible && homeVisible { folder = nil; menu = nil; if !editing { sheet = nil } }
        homeVisible = visible
        if let f = folder, f.closing, f.anim.done(now) { folder = nil; dirty = true }
        for (k, v) in fades where now - v > HPMotion.reduceFade { fades[k] = nil; dirty = true }
        if drag != nil { dragUpdate(nil, now: now) }   // 停住不動時也要算 dwell（換位置、翻頁、資料夾）
        if Shell.nav.screen == .library {   // 2.0 depth：搜尋過濾後內容變短，捲動量跟著收回
            let m = libraryMaxScroll
            if !libraryScrollDragging, libraryScroll.to > m { libraryScroll.retarget(m, now: now); dirty = true }
        }
        if visible || Shell.nav.screen == .library, animating(now) { dirty = true }
        return dirty
    }
}

// MARK: - 示範排列（--home-layout；快照與 selftest 用，不碰存檔）

enum SBDemo {
    static func w(_ id: String, _ k: SBWidgetKind, _ s: SBWidgetSize, _ cfg: [String: String] = [:]) -> SBWidget { SBWidget(id: id, kind: k, size: s, config: cfg) }
    static func layout(_ name: String) -> SBLayout? {
        var l = SBLayout.official
        switch name {
        case "official": break
        case "pages", "demo":
            // 第一頁照官方；第二頁：Smart Stack（中）＋資料夾＋幾個圖示；第三頁：大的家庭小工具
            let stack = SBItem.stack(SBStack(id: "st", size: .medium, widgets: [w("s1", .calendar, .medium), w("s2", .weather, .medium), w("s3", .music, .medium)]))
            let folder = SBItem.folder(SBFolder(id: "fd", name: SBLayout.folderName(["timers", "worldclock", "findmy", "intercom"]), apps: ["timers", "worldclock", "findmy", "intercom"]))
            l.pages.append(SBPage(items: [stack, folder, .app("safari"), .app("weather"), .app("cliotalk"), .widget(w("bt", .batteries, .wide)), .app("settings")]))
            l.pages.append(SBPage(items: [.widget(w("hm", .home, .large))]))
        case "sizes":
            l = SBLayout(pages: [SBPage(items: [.widget(w("a", .weather, .wide)), .widget(w("b", .music, .wide)), .widget(w("c", .reminders, .small)), .widget(w("d", .worldClock, .small)),
                                                 .app("timers"), .app("alarms"), .app("home"), .app("music")]),
                                 SBPage(items: [.widget(w("e", .calendar, .medium)), .widget(w("f", .timers, .wide)), .widget(w("g", .alarms, .wide))]),
                                 SBPage(items: [.widget(w("h", .weather, .large))]),
                                 SBPage(items: [.widget(w("i", .findMy, .medium)), .widget(w("j", .photos, .medium))]),
                                 SBPage(items: [.widget(w("k", .batteries, .medium)), .widget(w("l", .podcasts, .medium))]),
                                 SBPage(items: [.widget(w("m", .worldClock, .medium)), .widget(w("n", .home, .medium))])])
        case "stack":
            let stack = SBItem.stack(SBStack(id: "st", size: .small, widgets: [w("s1", .weather, .small), w("s2", .calendar, .small), w("s3", .photos, .small)], smartRotate: true))
            l = SBLayout(pages: [SBPage(items: [.app("facetime"), .app("home"), stack, .app("music"), .app("messages"), .app("alarms"), .app("calendar"), .app("podcasts"), .app("reminders")])])
        case "folder":
            var p = l.pages[0].items
            p.removeAll { $0 == .app("alarms") || $0 == .app("podcasts") }
            p.append(.folder(SBFolder(id: "fd", name: SBLayout.folderName(["alarms", "timers", "worldclock", "podcasts"]), apps: ["alarms", "timers", "worldclock", "podcasts", "findmy"])))
            l.pages[0].items = p
        default: return nil
        }
        l.normalize()
        return l
    }
}
