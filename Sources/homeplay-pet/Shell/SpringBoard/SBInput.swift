// 2.0 SpringBoard：主畫面與 App 資料庫的輸入——滑鼠／觸控板（長按出選單、按住空白進編輯、拖曳、換頁、Smart Stack 上下滑）、
// 鍵盤（編輯模式用方向鍵搬、Tab 換、Delete 移除；App 資料庫直接打字搜尋；資料夾改名）、輔助使用（VoiceOver 的標籤與自訂動作）、
// 快照旗標。ShellInput.swift 在滑鼠、滾輪、鍵盤、點按各加一行先問這裡（只加不改原本的路）。
//
// 跟原本手勢的分工：平常的主畫面只接「按在圖示／小工具上」與「按在空白處」；拖動時橫向（多頁）＝換頁、在 Smart Stack 上直向＝換小工具，
// 其他方向照舊交回去轉身體；頂端與底緣的邊緣手勢（控制中心、ClioTalk、往上）不碰。編輯模式、選單、sheet、資料夾開著時整面歸這裡。

import AppKit

struct SBPress {
    enum Hit: Equatable { case item(String), empty, folderApp(String), libraryApp(String), libraryEmpty,
                          libraryExpand(SBLibraryCategory), libraryBackToPods }
    enum Mode { case pending, drag, page, stack, swallow, libraryScroll, folderDrag, folderPage }
    var p: CGPoint
    var at: NSPoint
    var t: Double
    var hit: Hit
    var mode: Mode = .pending
    var longFired = false
    var token: Int
    var event: NSEvent
    var startPage: CGFloat = 0
    var startX: CGFloat = 0
    var startY: CGFloat = 0
    var onHandle = false
    var libStart: CGFloat = 0   // 2.0 depth：資料庫開始拖時的捲動量
}

enum SBInputState {
    nonisolated(unsafe) static var press: SBPress?
    nonisolated(unsafe) static var token = 0
    nonisolated(unsafe) static var lastPoint: CGPoint?
    nonisolated(unsafe) static var scrollStack: (key: String, acc: CGFloat)?
    nonisolated(unsafe) static var scrollPage = false
    nonisolated(unsafe) static var libWheel: CGFloat?   // 2.0 depth：資料庫這一手滾輪的目標（1:1 跟手）
    nonisolated(unsafe) static var scrollVertical = false   // 這一手觸控板一開始是直的
    nonisolated(unsafe) static var pageMomentum = false   // 觸控板翻頁那一手放開後的慣性事件（吃掉）
    /// 換頁這一手沒套橡皮筋的位置（頁）與取樣：第一頁往右「翻到 −1 頁」＝回錶面，判定跟換頁一樣看投射落點（SB.leavesToFace）
    nonisolated(unsafe) static var pageRaw: CGFloat = 0
    nonisolated(unsafe) static var pageRawSamples: [(t: Double, x: CGFloat)] = []
    static func trackRaw(_ x: CGFloat, now: Double) {
        pageRaw = x
        pageRawSamples.append((now, x)); if pageRawSamples.count > 5 { pageRawSamples.removeFirst() }
    }
}

extension SB {
    /// 主畫面第一頁再往右翻＝回錶面（錶面在主畫面左邊，2026-11-07 拍板）：跟換頁同一套判定——放手時的投射落點四捨五入到 −1 頁才算，
    /// 不到就照舊彈回第一頁。只在主畫面（資源庫不算）、不在編輯模式（編輯時不離開主畫面，同滾輪）
    static func leavesToFace(fromPage: Int, projected: CGFloat, screen: ShellScreen, editing: Bool) -> Bool {
        screen == .home && !editing && fromPage == 0 && Int(projected.rounded()) < 0
    }
}

// MARK: - 拖曳（純狀態，tick 也會叫：停住不動時的 dwell）

extension SB {
    static func beginDrag(_ key: String, at p: CGPoint, now: Double, resizing: Bool = false) {
        let l = layout
        guard let (pi, idx) = l.locate(key) else { return }
        let it = l.pages[pi].items[idx]
        guard let place = SBLayout.pack(l.pages[pi].items).placed.first(where: { $0.item.key == key }) else { return }
        let f = frame(place)
        drag = SBDrag(item: it, key: key, fromPage: pi, fromIndex: idx, grab: CGPoint(x: p.x - f.minX, y: p.y - f.minY), point: p,
                      target: (place.col, place.row), lift: MotionValue("sblift", spring: SBMotion.lift, from: 1, to: SBMotion.liftScale, now: now), resizing: resizing)
        dropCache = nil
        log("sb drag \(key)\(resizing ? " resize" : "")")
    }
    /// 從資料夾或 App 資料庫拖出來的 App（不在任何一頁上）
    static func beginDragFree(app id: String, at p: CGPoint, now: Double) {
        let cell = Shell.cell(0, 0)
        drag = SBDrag(item: .app(id), key: "a:\(id)", fromPage: nil, fromIndex: nil, grab: CGPoint(x: cell.width / 2, y: SB.iconRect(in: cell).height / 2), point: p,
                      target: nil, lift: MotionValue("sblift", spring: SBMotion.lift, from: 1, to: SBMotion.liftScale, now: now))
        dropCache = nil
    }

    nonisolated(unsafe) static var dropCache: (key: String, items: [SBItem])?

    static func dragUpdate(_ p: CGPoint?, now: Double) {
        guard var d = drag else { return }
        if let p { d.point = p }
        defer { drag = d }
        if d.resizing {
            guard case let it? = layout.item(d.key), let (pi, _) = layout.locate(d.key),
                  let place = SBLayout.pack(layout.pages[pi].items).placed.first(where: { $0.item.key == d.key }) else { return }
            let f = frame(place)
            let dx = d.point.x - f.minX, dy = d.point.y - f.minY
            let w = dx > 620 ? 4 : 2, h = dy > 560 ? 3 : (dy > 300 ? 2 : 1)
            let sizes: [SBWidgetSize] = { if case .widget(let x) = it { return x.kind.sizes }; return [.small, .medium, .large] }()
            let want = SBWidgetSize.of(span: w, h)
            let pick = want.flatMap { sizes.contains($0) ? $0 : nil }
                ?? sizes.min { abs($0.span.w - w) * 2 + abs($0.span.h - h) < abs($1.span.w - w) * 2 + abs($1.span.h - h) }
            let cur: SBWidgetSize? = { switch it { case .widget(let x): return x.size; case .stack(let s): return s.size; default: return nil } }()
            if let pick, pick != cur { resize(d.key, to: pick) }
            return
        }
        // 螢幕邊停一下：翻頁（最後一頁再往右＝開新的一頁）
        let edge = d.point.x < 72 ? -1 : (d.point.x > 952 ? 1 : 0)
        if edge != d.edgeDir { d.edgeDir = edge; d.edgeSince = now }
        else if edge != 0, now - d.edgeSince > SBMotion.edgeDwell, now - d.lastFlip > SBMotion.edgeRearm {
            let vis = visiblePages
            if edge > 0, page == vis.count - 1 {
                var l = layout
                if !l.pages[pageIndex].isEmpty || (d.fromPage == pageIndex && l.pages[pageIndex].items.count == 1) {
                    l.pages.insert(SBPage(items: []), at: pageIndex + 1); layout = l
                }
            }
            let to = page + edge
            if to >= 0, to < visiblePages.count {
                goToPage(to, now: now)
                d.lastFlip = now; d.edgeSince = now; d.target = nil; d.pendingTarget = nil
                dropCache = nil
                log("sb drag flip → page \(to)")
            }
        }
        // 疊到圖示上：做資料夾（只有 App 能疊；停 0.35 s 才算，期間不換位置）
        let disp = SBLayout.pack(displayItems(page: pageIndex)).placed
        let canFolder: Bool = { if case .app = d.item { return true }; return false }()
        if canFolder, let over = disp.first(where: { $0.item.isIcon && $0.item.key != d.key && SB.iconRect(in: frame($0)).insetBy(dx: 34, dy: 34).contains(d.point) }) {
            if d.folderTarget != over.item.key { d.folderTarget = over.item.key; d.folderSince = now; d.folderReady = false }
            else if now - d.folderSince > SBMotion.folderDwell { d.folderReady = true }
            return
        }
        d.folderTarget = nil; d.folderReady = false
        let tl = CGPoint(x: d.point.x - d.grab.x, y: d.point.y - d.grab.y)
        let cell = SB.cell(forTopLeft: tl, span: d.item.span, current: d.pendingTarget ?? d.target)
        if d.pendingTarget.map({ $0 != cell }) ?? true { d.pendingTarget = cell; d.pendingSince = now }
        else if d.target.map({ $0 != cell }) ?? true, now - d.pendingSince > SBMotion.reorderDwell { d.target = cell }
    }

    /// 放手：照預覽的那個結果放（看到的就是放下去的）；疊在圖示上＝資料夾
    static func endDrag(now: Double) {
        guard let d = drag else { return }
        drag = nil; dropCache = nil
        if d.resizing { commit(); return }
        var l = layout
        let dragRect = CGRect(x: d.point.x - d.grab.x, y: d.point.y - d.grab.y, width: frame(col: 0, row: 0, span: d.item.span).width, height: frame(col: 0, row: 0, span: d.item.span).height)
        let pi = pageIndex
        let before = l.pages[pi].items
        // 先從原處拿掉
        if let fp = d.fromPage, let fi = d.fromIndex, fp < l.pages.count, fi < l.pages[fp].items.count, l.pages[fp].items[fi].key == d.key {
            l.pages[fp].items.remove(at: fi)
        } else if case .app(let id) = d.item { l.removeApp(id) }
        if d.folderReady, let fk = d.folderTarget, l.merge(d.item, onto: fk, newID: SBStore.newID("f")) != nil {
            l.normalize()
            layout = l; commit()
            log("sb folder \(d.key) → \(fk)")
            return
        }
        let target = d.target ?? SB.cell(forTopLeft: dragRect.origin, span: d.item.span)
        let hole = d.fromPage == pi ? d.fromIndex : nil
        let ref = SBLayout.positions(before)
        let base = l.pages[pi].items
        l.pages[pi].items = SBLayout.drop(d.item, into: base, at: target, hole: hole, reference: ref)
        l.normalize()
        layout = l; commit()
        // 放下去的那個從手上的位置滑回格子（其他照舊在讓位的彈簧上）
        if !HPMotion.reduceMotion, let place = SBLayout.pack(layout.pages[pi].items).placed.first(where: { $0.item.key == d.key }) {
            let f = frame(place)
            anims[d.key] = (MotionValue("sbreflow", spring: SBMotion.settle, from: dragRect.minX, to: f.minX, now: now),
                            MotionValue("sbreflow", spring: SBMotion.settle, from: dragRect.minY, to: f.minY, now: now), pi)
        }
        log("sb drop \(d.key) page \(pi) at \(target.col),\(target.row)")
    }

    /// 鍵盤／VoiceOver：把一項往某個方向搬一格（邊上就搬到上一頁／下一頁）
    @discardableResult
    static func move(_ key: String, dc: Int, dr: Int, now: Double) -> Bool {
        var l = layout
        guard let (pi, idx) = l.locate(key), let place = SBLayout.pack(l.pages[pi].items).placed.first(where: { $0.item.key == key }) else { return false }
        let it = l.pages[pi].items[idx]
        var tp = pi, c = place.col + dc, r = place.row + dr
        if c < 0 || c + it.span.w > SBLayout.cols {
            // 換頁：往左到上一頁的最右、往右到下一頁的最左
            let vis = visiblePages
            guard let vi = vis.firstIndex(of: pi) else { return false }
            if dc > 0 && vi == vis.count - 1 { l.pages.insert(SBPage(items: []), at: pi + 1); tp = pi + 1 }
            else if dc < 0 && vi == 0 { return false }
            else { tp = vis[vi + (dc > 0 ? 1 : -1)] }
            c = dc > 0 ? 0 : SBLayout.cols - it.span.w
        }
        r = max(0, min(SBLayout.rows - it.span.h, r))
        let ref = SBLayout.positions(l.pages[tp].items)
        l.pages[pi].items.remove(at: idx)
        l.pages[tp].items = SBLayout.drop(it, into: l.pages[tp].items, at: (c, r), hole: tp == pi ? idx : nil, reference: ref)
        l.normalize()
        layout = l; commit()
        if let vi = visiblePages.firstIndex(of: tp), vi != page { goToPage(vi, now: now) }
        log("sb move \(key) → page \(tp) \(c),\(r)")
        return true
    }

    // MARK: 選單

    static func openMenu(for key: String, now: Double) {
        guard let it = layout.item(key), let place = placements(page: pageIndex).first(where: { $0.item.key == key }) else { return }
        let anchor = frame(place)
        let canEdit = PersonHome.canEdit || forcedLayout != nil
        var rows: [SBMenuRow] = []
        var sizes: [SBWidgetSize] = [], current: SBWidgetSize?
        switch it {
        case .app(let id):
            rows += AppProviders.menuRows(id, canEdit: canEdit).map { SBMenuRow(action: .provider(id, $0.verb), title: $0.title, symbol: $0.symbol, destructive: $0.destructive) }   // 2.0 Web App
            if canEdit { rows.append(SBMenuRow(action: .editHome, title: L("sb.menu.editHome", "编辑主屏幕"), symbol: "apps.iphone")) }
            if canEdit { rows.append(SBMenuRow(action: .removeItem(key), title: L("sb.menu.removeApp", "移除 App"), symbol: "minus.circle", destructive: true)) }
            if rows.isEmpty { rows.append(SBMenuRow(action: .openApp(id), title: L("sb.menu.open", "打开"), symbol: "arrow.up.forward.app")) }
        case .folder(let f):
            if canEdit {
                rows.append(SBMenuRow(action: .rename(f.id), title: L("sb.menu.rename", "重新命名"), symbol: "pencil"))
                rows.append(SBMenuRow(action: .editHome, title: L("sb.menu.editHome", "编辑主屏幕"), symbol: "apps.iphone"))
                rows.append(SBMenuRow(action: .removeItem(key), title: L("sb.menu.removeFolder", "移除文件夹"), symbol: "minus.circle", destructive: true))
            }
        case .widget(let w):
            guard canEdit else { return }
            sizes = w.kind.sizes.count > 1 ? w.kind.sizes : []; current = w.size
            if w.kind == .photos, !AirDropShare.items(image: PhotosWidgetSource.shared.image).isEmpty {
                rows.append(SBMenuRow(action: .shareAirDrop, title: SelfShare.title, symbol: SelfShare.symbol))   // CarPlay 連著時改成「用訊息傳給自己」（AirDropSelfMessage.swift）
            }
            if !SBWidgetData.options(w.kind).isEmpty {
                rows.append(SBMenuRow(action: .editWidget(key), title: String(format: L("sb.menu.editWidget", "编辑「%@」"), w.kind.title), symbol: "info.circle"))
            }
            rows.append(SBMenuRow(action: .editHome, title: L("sb.menu.editHome", "编辑主屏幕"), symbol: "apps.iphone"))
            rows.append(SBMenuRow(action: .removeItem(key), title: L("sb.menu.removeWidget", "移除小组件"), symbol: "minus.circle", destructive: true))
        case .stack(let s):
            guard canEdit else { return }
            sizes = [.small, .medium, .large]; current = s.size
            rows.append(SBMenuRow(action: .editStack(key), title: L("sb.menu.editStack", "编辑叠放"), symbol: "square.stack.3d.up"))
            rows.append(SBMenuRow(action: .editHome, title: L("sb.menu.editHome", "编辑主屏幕"), symbol: "apps.iphone"))
            rows.append(SBMenuRow(action: .removeItem(key), title: L("sb.menu.removeStack", "移除叠放"), symbol: "minus.circle", destructive: true))
        case .spacer: return
        }
        guard !rows.isEmpty else { return }
        var m = SBMenu(anchor: anchor, key: key, appID: nil, rows: rows, sizes: sizes, current: current,
                       presence: MotionValue("sbmenu", spring: SBMotion.menu, from: 0, to: 1, now: now))
        m.panel = SBUI.menuPanel(anchor: anchor, rows: rows.count, sizes: !sizes.isEmpty)
        menu = m
        log("sb menu \(key)")
    }
    /// 編輯模式左上的筆刷：加入小工具／自訂／編輯頁面
    static func openEditMenu(now: Double) {
        let rows = [SBMenuRow(action: .addWidget, title: L("sb.menu.addWidget", "添加小组件"), symbol: "plus.rectangle.on.rectangle"),
                    SBMenuRow(action: .customize, title: L("sb.customize", "自定"), symbol: "paintbrush"),
                    SBMenuRow(action: .editPages, title: L("sb.menu.editPages", "编辑页面"), symbol: "rectangle.stack")]
        var m = SBMenu(anchor: SBUI.editMenuButton, key: nil, appID: nil, rows: rows, sizes: [], current: nil,
                       presence: MotionValue("sbmenu", spring: SBMotion.menu, from: 0, to: 1, now: now))
        m.panel = SBUI.menuPanel(anchor: SBUI.editMenuButton, rows: rows.count, sizes: false)
        menu = m
    }
    static func openLibraryMenu(app id: String, cell: CGRect, now: Double) {
        let on = layout.appsOnHome.contains(id)
        var rows: [SBMenuRow] = []
        if !on, PersonHome.canEdit || forcedLayout != nil { rows.append(SBMenuRow(action: .addToHome(id), title: L("sb.menu.addToHome", "添加到主屏幕"), symbol: "plus.app")) }
        rows.append(SBMenuRow(action: .openApp(id), title: L("sb.menu.open", "打开"), symbol: "arrow.up.forward.app"))
        var m = SBMenu(anchor: cell, key: nil, appID: id, rows: rows, sizes: [], current: nil, presence: MotionValue("sbmenu", spring: SBMotion.menu, from: 0, to: 1, now: now))
        m.panel = SBUI.menuPanel(anchor: SBUI.libraryIcon(cell), rows: rows.count, sizes: false)
        menu = m
    }

    static func openFolder(_ id: String, from rect: CGRect, now: Double) {
        folder = SBOpenFolder(id: id, anim: MotionValue("sbfolder", spring: SBMotion.folder, from: HPMotion.reduceMotion ? 1 : 0, to: 1, now: now),
                              from: SB.iconRect(in: rect))
        log("sb folder open \(id)")
    }
    static func closeFolder(now: Double) {
        guard var f = folder, !f.closing else { return }
        if f.renaming { f.renaming = false }
        f.closing = true
        f.anim.retarget(0, now: now)
        if HPMotion.reduceMotion { folder = nil; return }
        folder = f
    }
}

// MARK: - PetView：滑鼠、點按、滾輪、鍵盤

extension PetView {
    private func sbPoint(_ uv: CGPoint?) -> CGPoint? { uv.map { CGPoint(x: $0.x * 1024, y: $0.y * 1024) } }
    private var sbEngaged: Bool { SB.editing || SB.overlayOpen || (Shell.nav.screen == .library && SB.librarySearching) }

    /// 按在哪
    private func sbHit(_ p: CGPoint) -> SBPress.Hit {
        if Shell.nav.screen == .library {
            let off = SB.libraryScrollNow   // 2.0 depth：捲動後的格子跟著位移；被裁掉一半以上的不算
            if SB.libraryQuery.isEmpty && !SB.librarySearching {
                if SB.libraryShowingExpanded {   // 展開的類別頁：點圖示開 App，點空白回總覽
                    for (app, cell) in zip(SBUI.libraryExpandedApps(), SBUI.libraryExpandedCells()) {
                        let ir = cell.offsetBy(dx: 0, dy: -off)
                        let vis = ir.intersection(CGRect(x: -1e9, y: SBUI.libraryTop - 32, width: 2e9, height: 1024))
                        if vis.height >= ir.height * 0.5, ir.insetBy(dx: -12, dy: -12).contains(p) { return .libraryApp(app.id) }
                    }
                    return .libraryBackToPods
                }
                // 豆莢總覽
                if let cat = SBUI.libraryPodTitle(at: p, offset: off) { return .libraryExpand(cat) }
                // 瀏覽：豆莢網格，每一顆圖示各自是一個目標
                for (id, icon) in SBUI.libraryPodIcons() {
                    let ir = icon.offsetBy(dx: 0, dy: -off)
                    let vis = ir.intersection(CGRect(x: -1e9, y: SBUI.libraryTop - 32, width: 2e9, height: 1024))
                    if vis.height >= ir.height * 0.5, ir.insetBy(dx: -12, dy: -12).contains(p) { return .libraryApp(id) }
                }
                return .libraryEmpty
            }
            for (app, cell) in zip(SBUI.libraryApps(), SBUI.libraryLayout().cells) {
                let ir = SBUI.libraryIcon(cell).offsetBy(dx: 0, dy: -off)
                let vis = ir.intersection(CGRect(x: -1e9, y: SBUI.libraryTop - 32, width: 2e9, height: 1024))
                if vis.height >= ir.height * 0.5, ir.insetBy(dx: -12, dy: -12).contains(p) { return .libraryApp(app.id) }
            }
            return .libraryEmpty
        }
        if let f = SB.folder, !f.closing, case .folder(let fo)? = SB.layout.item("f:\(f.id)") {
            // 浮動資料夾：看得到的那一頁
            let pages = SBFloaty.pages(fo.apps), page = pages.indices.contains(f.page) ? pages[f.page] : []
            for (id, cell) in zip(page, SBUI.folderCells()) where SB.iconRect(in: cell).insetBy(dx: -12, dy: -12).contains(p) { return .folderApp(id) }
            return .empty
        }
        for pl in SB.placements(page: SB.pageIndex) where SB.hitRect(pl).contains(p) || (SB.editing && SBUI.badgeHit(SB.frame(pl), icon: pl.item.isIcon).contains(p)) {
            if let k = pl.item.key { return .item(k) }
        }
        return .empty
    }

    /// ShellInput.shellMouseDown 在控制中心／ClioTalk 那一層之後先問這裡
    func sbMouseDown(_ e: NSEvent, uv: CGPoint?) -> Bool {
        SBInputState.press = nil
        guard Shell.nav.screen == .home || Shell.nav.screen == .library, Shell.appMorph == nil, !Shell.peopleSheet,
              let uv, let p = sbPoint(uv), e.clickCount == 1 || sbEngaged, !e.modifierFlags.contains(.command) else { return false }
        if !sbEngaged {
            // 邊緣手勢（控制中心、👀 膠囊、往上）照舊；頭像、頂端藥丸也照舊（歸屬見 Shell/HomeIndicator.swift）
            if HomeIndicator.owner(p, on: .home, pill: LiveActivityStack.pillHit, inset: nil) != .shell || uv.y > 0.90 && uv.x > 0.2 && uv.x < 0.8 { return false }
        }
        let now = CACurrentMediaTime()
        SBInputState.token += 1
        let hit = sbHit(p)
        var pr = SBPress(p: p, at: e.locationInWindow, t: now, hit: hit, token: SBInputState.token, event: e)
        pr.startPage = SB.pagePosition(now); pr.startX = p.x; pr.startY = p.y
        if case .item(let k) = hit {
            if !SB.editing, !ShellInput.coastStopped { SB.pressedKey = k }
            if SB.editing, !SB.overlayOpen, let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == k }), !pl.item.isIcon,
               SBUI.resizeHandle(SB.frame(pl)).contains(p) { pr.onHandle = true }
        }
        SBInputState.press = pr
        SBInputState.lastPoint = p
        // 長按：圖示 0.55 s 出選單；空白 0.8 s 進編輯模式（iOS 27 量到 0.65／0.85，含系統延遲）；停住慣性的那一下不排長按
        if !SB.editing && !SB.overlayOpen && !ShellInput.coastStopped {
            let delay: Double = { if case .item = hit { return SBMotion.longPressIcon }; if case .libraryApp = hit { return SBMotion.longPressIcon }; return SBMotion.longPressEmpty }()
            let tok = pr.token
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sbLongPress(tok) }
        } else if SB.editing, SB.folder != nil, SB.menu == nil, SB.sheet == nil, case .folderApp = hit {
            // 編輯模式裡的資料夾：按著就能拖出來
        }
        face.forceDirty = true
        return true
    }

    private func sbLongPress(_ token: Int) {
        guard var pr = SBInputState.press, pr.token == token, pr.mode == .pending, !pr.longFired else { return }
        let now = CACurrentMediaTime()
        pr.longFired = true
        SB.pressedKey = nil
        switch pr.hit {
        case .item(let k): SB.openMenu(for: k, now: now)
        case .empty:
            if SB.folder != nil { SB.enterEdit(now: now) } else if Shell.nav.screen == .home { SB.enterEdit(now: now) }
        case .folderApp: SB.enterEdit(now: now)
        case .libraryApp(let id):
            if let cell = zip(SBUI.libraryApps(), SBUI.libraryLayout().cells).first(where: { $0.0.id == id })?.1 { SB.openLibraryMenu(app: id, cell: cell.offsetBy(dx: 0, dy: -SB.libraryScrollNow), now: now) }   // 2.0 depth：捲動後錨在畫面上的位置
        case .libraryEmpty, .libraryExpand, .libraryBackToPods: break
        }
        SBInputState.press = pr
        face.forceDirty = true
    }

    func sbMouseDragged(_ e: NSEvent, uv: CGPoint?) -> Bool {
        guard var pr = SBInputState.press else { return false }
        let now = CACurrentMediaTime()
        Shell.lastActive = now
        let p = sbPoint(uv) ?? SBInputState.lastPoint ?? pr.p
        SBInputState.lastPoint = p
        defer { if SBInputState.press != nil { SBInputState.press = pr }; face.forceDirty = true }
        let wdx = e.locationInWindow.x - pr.at.x, wdy = e.locationInWindow.y - pr.at.y
        switch pr.mode {
        case .drag: SB.dragUpdate(p, now: now); return true
        case .page: sbPageTrack(p, pr: pr, now: now); return true
        case .stack: sbStackTrack(p, pr: pr, now: now); return true
        case .libraryScroll: sbLibraryTrack(p, pr: pr, now: now); return true
        case .swallow: return true
        case .folderDrag:   // 浮動資料夾：面板裡重排、左右緣翻頁；拖出面板＝拿出來、接著在主畫面上拖
            if SB.folderDragUpdate(p, now: now), let id = SB.folder?.drag?.id { sbPullOutOfFolder(id, at: p, now: now); pr.mode = .drag }
            return true
        case .folderPage:
            if var f = SB.folder {   // 1:1 跟手，頭尾 rubber band
                let v = pr.startPage - (p.x - pr.startX) / SBFloaty.panel.width, hi = CGFloat(SBFloaty.pageCount(SB.folderApps().count) - 1)
                f.pageDrag = v < 0 ? -HPMotion.rubberBand(-v, 1) : (v > hi ? hi + HPMotion.rubberBand(v - hi, 1) : v)
                SB.folder = f
            }
            SB.pageSamples.append((now, p.x)); if SB.pageSamples.count > 6 { SB.pageSamples.removeFirst() }
            return true
        case .pending: break
        }
        guard hypot(wdx, wdy) > ShellInput.slop else { return true }
        SB.pressedKey = nil
        let horizontal = abs(wdx) > abs(wdy) * 1.2, vertical = abs(wdy) > abs(wdx) * 1.2
        switch pr.hit {
        case .item(let k):
            if pr.longFired || SB.editing, SB.sheet == nil {
                // 選單出來後再拖＝收選單、進編輯、拿起來（iOS）
                SB.menu = nil
                SB.enterEdit(now: now)
                if SB.editing { SB.beginDrag(k, at: pr.p, now: now, resizing: pr.onHandle); SB.dragUpdate(p, now: now); pr.mode = .drag; return true }
            }
            if !SB.editing, !pr.longFired, vertical, k.hasPrefix("s:") { pr.mode = .stack; SB.stackDrag = (k, 0, []); sbStackTrack(p, pr: pr, now: now); return true }
        case .folderApp(let id):
            if pr.longFired || SB.editing {
                // 浮動資料夾：先在面板裡拖（重排、翻頁），拖出面板才拿出來
                SB.enterEdit(now: now)
                if SBFloaty.panel.contains(p) { SB.folderDragBegin(id, at: p); _ = SB.folderDragUpdate(p, now: now); pr.mode = .folderDrag; return true }
                sbPullOutOfFolder(id, at: p, now: now)
                pr.mode = .drag; return true
            }
            if horizontal, SBFloaty.pageCount(SB.folderApps().count) > 1 { sbFolderPageBegin(&pr, now: now); return true }
        case .libraryApp(let id):
            if pr.longFired, !SB.layout.appsOnHome.contains(id), PersonHome.canEdit || SB.forcedLayout != nil {
                // 從 App 資料庫拖到主畫面（iOS）：回主畫面、進編輯、手上拿著它
                SB.menu = nil
                shellNavigate(.back)
                Shell.appMorph = nil
                SB.enterEdit(now: now)
                SB.beginDragFree(app: id, at: p, now: now)
                pr.mode = .drag; return true
            }
        default: break
        }
        if pr.longFired { pr.mode = .swallow; return true }
        if horizontal, SB.folder != nil, SB.menu == nil, SB.sheet == nil, SBFloaty.panel.contains(pr.p), SBFloaty.pageCount(SB.folderApps().count) > 1 {
            sbFolderPageBegin(&pr, now: now); return true   // 浮動資料夾：面板裡橫拖換頁
        }
        if horizontal, Shell.nav.screen == .home, SB.sheet == nil, SB.menu == nil, SB.folder == nil, SB.pageSlots > 1 {   // 不在編輯模式時至少有一頁＋資源庫：第一頁往右照樣接（回錶面）
            pr.mode = .page; SB.pageDragging = true; SB.pageDragValue = pr.startPage; SB.pageSamples = []; SBInputState.pageRawSamples = []
            sbPageTrack(p, pr: pr, now: now); return true
        }
        // App 資源庫：橫拖＝跟最後一頁之間翻（同一套跟手、橡皮筋、投射）
        if horizontal, Shell.nav.screen == .library, SB.libraryReachable, SB.menu == nil, SB.sheet == nil, !SB.librarySearching {
            SB.armLibraryPaging(now: now); pr.startPage = CGFloat(SB.librarySlot)
            pr.mode = .page; SB.pageDragging = true; SB.pageDragValue = pr.startPage; SB.pageSamples = []; SBInputState.pageRawSamples = []
            sbPageTrack(p, pr: pr, now: now); return true
        }
        // 2.0 depth：App 資料庫直向拖＝捲（內容放不下時；iOS 的資料庫一樣）；選單開著歸選單
        if vertical, Shell.nav.screen == .library, SB.menu == nil, SB.sheet == nil, SB.libraryMaxScroll > 0.5, !pr.longFired {
            pr.mode = .libraryScroll
            pr.libStart = SB.libraryScrollNow
            SB.libraryScrollDragging = true
            SB.libraryScrollDrag = pr.libStart
            SB.libraryScrollSamples = []
            sbLibraryTrack(p, pr: pr, now: now)
            return true
        }
        if sbEngaged { pr.mode = .swallow; return true }
        // 不是主畫面的手勢：交回原本的路（轉身體）
        SBInputState.press = nil
        let S = ShellInput.self
        S.down = nil; S.claimed = false
        S.passThrough = true; mouseDown(with: pr.event); S.passThrough = false
        S.replayed = true
        return false
    }

    /// 2.0 depth：資料庫捲動跟手（手指往下＝內容往下）；兩頭橡皮筋，速度記下來放手投射
    private func sbLibraryTrack(_ p: CGPoint, pr: SBPress, now: Double) {
        let y = SB.libraryRubber(pr.libStart + (pr.startY - p.y))
        SB.libraryScrollDrag = y
        SB.libraryScrollSamples.append((now, y))
        if SB.libraryScrollSamples.count > 8 { SB.libraryScrollSamples.removeFirst() }
    }

    private func sbPageTrack(_ p: CGPoint, pr: SBPress, now: Double) {
        let n = CGFloat(SB.pageSlots)
        var x = pr.startPage - (p.x - pr.startX) / 1024
        SBInputState.trackRaw(x, now: now)
        if x < 0 { x = -HPMotion.rubberBand(-x * 1024, 1024) / 1024 } else if x > n - 1 { x = n - 1 + HPMotion.rubberBand((x - n + 1) * 1024, 1024) / 1024 }
        SB.pageDragValue = x
        SB.pageSamples.append((now, x))
        if SB.pageSamples.count > 5 { SB.pageSamples.removeFirst() }
    }
    private func sbPageRelease(now: Double) {
        let sm = SB.pageSamples
        var v: CGFloat = 0
        if let a = sm.first, let b = sm.last, b.t - a.t > 0.004 { v = (b.x - a.x) / CGFloat(b.t - a.t) }
        if let b = sm.last, now - b.t > 0.08 { v = 0 }
        let x = SB.pageDragValue
        let projected = x + HPMotion.project(v * 1000) / 1000   // 頁／秒 → 投射落點（Apple 的減速率 0.998）
        let from = CGFloat(SB.page)
        // 第一頁往右翻過頭＝回錶面：同一套投射，但用沒套橡皮筋的位置與速度（不然拖得再遠也到不了 −1 頁）
        let rs = SBInputState.pageRawSamples
        var rv: CGFloat = 0
        if let a = rs.first, let b = rs.last, b.t - a.t > 0.004, now - b.t <= 0.08 { rv = (b.x - a.x) / CGFloat(b.t - a.t) }
        SBInputState.pageRawSamples = []
        if !rs.isEmpty, SB.leavesToFace(fromPage: SB.page, projected: SBInputState.pageRaw + HPMotion.project(rv * 1000) / 1000, screen: Shell.nav.screen, editing: SB.editing) {
            SB.goToPage(0, now: now, from: 0)   // 主畫面停回第一頁（下次回來從第一頁開始）
            log("sb page → face")
            shellNavigate(.back)   // 跟 ↓／Esc 回錶面同一個過場
            return
        }
        var to = Int(projected.rounded())
        to = max(Int(from) - 1, min(Int(from) + 1, to))
        SB.goToPage(to, now: now, velocity: v, from: x)   // 從手指的位置接著走（不先跳回舊頁）
        log("sb page → \(SB.page)")
    }

    private func sbStackTrack(_ p: CGPoint, pr: SBPress, now: Double) {
        guard var d = SB.stackDrag, case .stack(let s)? = SB.layout.item(d.key) else { return }
        let n = SB.stackWidgets(s, face: face, now: now).count
        var off = p.y - pr.startY
        if (s.index == 0 && off > 0) || (s.index >= n - 1 && off < 0) { off = (off > 0 ? 1 : -1) * HPMotion.rubberBand(abs(off), 400) }
        d.offset = off
        d.samples.append((now, off)); if d.samples.count > 5 { d.samples.removeFirst() }
        SB.stackDrag = d
        SB.stackShown[d.key] = now
        SB.manualAt[d.key] = now
    }
    private func sbStackRelease(now: Double) {
        guard let d = SB.stackDrag, case .stack(let s)? = SB.layout.item(d.key),
              let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == d.key }) else { SB.stackDrag = nil; return }
        let h = SB.frame(pl).height
        var v: CGFloat = 0
        if let a = d.samples.first, let b = d.samples.last, b.t - a.t > 0.004 { v = (b.y - a.y) / CGFloat(b.t - a.t) }
        let proj = d.offset + HPMotion.project(v)
        let n = SB.stackWidgets(s, face: face, now: now).count
        var to = s.index
        if proj < -h / 3, s.index < n - 1 { to += 1 } else if proj > h / 3, s.index > 0 { to -= 1 }
        SB.stackDrag = nil
        if to != s.index {
            SB.updateStack(d.key) { $0.index = to }
            let from = d.offset + (to > s.index ? h + 8 : -(h + 8))
            SB.stackAnim[d.key] = MotionValue("sbstack", spring: SBMotion.stack, from: from, to: 0, velocity: v, now: now)
        } else {
            SB.stackAnim[d.key] = MotionValue("sbstack", spring: SBMotion.stack, from: d.offset, to: 0, velocity: v, now: now)
        }
        SB.stackShown[d.key] = now
        SB.manualAt[d.key] = now
    }

    /// 手勢被取消（兩指接手、系統收走觸控、按著時重按）：照放手收尾但不帶速度、不當點按——
    /// 換頁、資料庫捲動、Smart Stack 照手指的位置落到最近的停點、拖著的圖示放下；還沒動的按下（含排著的長按）就作廢
    func sbCancelPress() {
        guard let pr = SBInputState.press else { return }
        SBInputState.token += 1
        SB.pageSamples = []; SB.libraryScrollSamples = []; SB.stackDrag?.samples = []; SBInputState.pageRawSamples = []   // 取消不回錶面：只回最近一頁
        if pr.mode == .pending || pr.mode == .swallow {
            SBInputState.press = nil; SB.pressedKey = nil; face.forceDirty = true
            return
        }
        _ = sbMouseUp(pr.event, uv: nil)
    }

    func sbMouseUp(_ e: NSEvent, uv: CGPoint?) -> Bool {
        guard let pr = SBInputState.press else { return false }
        SBInputState.press = nil
        SB.pressedKey = nil
        let now = CACurrentMediaTime()
        defer { face.forceDirty = true }
        switch pr.mode {
        case .drag: SB.dragUpdate(sbPoint(uv), now: now); SB.endDrag(now: now)
        case .page: sbPageRelease(now: now)
        case .stack: sbStackRelease(now: now)
        case .libraryScroll: SB.libraryScrollEnd(now: now)
        case .swallow: break
        case .folderDrag: _ = SB.folderDragUpdate(sbPoint(uv), now: now); SB.folderDragEnd()
        case .folderPage:
            let pos = SB.folderPagePos(now), s = SB.pageSamples
            let v = s.count > 1 ? -(s.last!.1 - s.first!.1) / CGFloat(max(0.008, s.last!.0 - s.first!.0)) / SBFloaty.panel.width * 1000 : 0
            let n = SBFloaty.pageCount(SB.folderApps().count)
            let to = HPMotion.nearest(pos, velocity: v, stops: (0..<n).map { CGFloat($0) })
            SB.setFolderPage(Int(to.rounded()), now: now)
        case .pending:
            // 沒拖：走外殼的點按（先問頂端藥丸／即時動態，再問這裡，最後頭像與其他）
            if !pr.longFired, !ShellInput.coastStopped { shellTap(CGPoint(x: pr.p.x / 1024, y: pr.p.y / 1024)) }   // 停住慣性的那一下不點（第 5 條）
        }
        return true
    }

    // MARK: 點按（滑鼠放手、輔助使用的「按下」都走這裡；ShellInput.shellTap 的主畫面那段先問）

    @discardableResult
    func sbTap(_ p: CGPoint, long: Bool) -> Bool {
        let now = CACurrentMediaTime()
        defer { face.forceDirty = true }
        if Shell.nav.screen == .library { return sbLibraryTap(p, now: now) }
        guard Shell.nav.screen == .home else { return false }
        if let s = SB.sheet { sbSheetTap(s, p, now: now); return true }
        if let m = SB.menu { sbMenuTap(m, p, now: now); return true }
        if let f = SB.folder {
            if f.renaming {
                SB.folder?.renaming = false
                if SBUI.folderTitle.contains(p) { return true }
            }
            if SB.editing, SBUI.folderTitle.contains(p) { SB.folder?.renaming = true; return true }
            // 浮動資料夾：點頁點換頁
            if let i = SBFloaty.dotRects(SBFloaty.pageCount(SB.folderApps().count)).firstIndex(where: { $0.contains(p) }), SBFloaty.pageCount(SB.folderApps().count) > 1 {
                SB.setFolderPage(i, now: now); return true
            }
            if SB.editing {   // 「−」：這一頁哪一格的徽標
                let page = SBFloaty.pages(SB.folderApps()).dropFirst(f.page).first ?? []
                if let i = SBUI.folderCells().prefix(page.count).firstIndex(where: { SBUI.badgeHit($0, icon: true).contains(p) }) { SB.sheet = .removeConfirm("a:\(page[i])"); return true }
            }
            if case .folderApp(let id) = sbHit(p) {
                if SB.editing { return true }
                let idx = SB.folderApps().firstIndex(of: id) ?? 0
                let cell = SBUI.folderCells()[idx % SBFolder.pageSize]
                SB.folder = nil
                shellOpenApp(id, from: cell)
                return true
            }
            if !SBUI.folderPanel.contains(p), !SBUI.folderTitle.contains(p) { SB.closeFolder(now: now) }
            return true
        }
        if SB.editing {
            if SBUI.editMenuButton.insetBy(dx: -8, dy: -8).contains(p) { SB.openEditMenu(now: now); return true }
            if SBUI.doneButton.insetBy(dx: -8, dy: -8).contains(p) { SB.exitEdit(); return true }
            if SBUI.dotsCapsule(SB.visiblePages.count).insetBy(dx: -10, dy: -14).contains(p) { SB.sheet = .editPages; return true }
            for pl in SB.placements(page: SB.pageIndex) {
                guard let k = pl.item.key else { continue }
                if SBUI.badgeHit(SB.frame(pl), icon: pl.item.isIcon).contains(p) { SB.sheet = .removeConfirm(k); return true }
            }
            if case .item(let k) = sbHit(p), let it = SB.layout.item(k) {
                switch it {
                case .widget(let w): if !SBWidgetData.options(w.kind).isEmpty { SB.sheet = .config(k) }
                case .stack: SB.sheet = .stackEdit(k)
                case .folder(let f): if let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == k }) { SB.openFolder(f.id, from: SB.frame(pl), now: now) }
                default: break
                }
                return true
            }
            SB.exitEdit()   // 點空白處：完成（iOS）
            return true
        }
        if let to = SBUI.dotsTap(p), to >= 0, to < SB.pageSlots { SB.goToPage(to, now: now); return true }   // 頁點、資源庫圖示
        guard case .item(let k) = sbHit(p), let it = SB.layout.item(k), let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == k }) else { return false }
        let r = SB.frame(pl)
        if long { SB.openMenu(for: k, now: now); return true }
        switch it {
        case .app(let id): shellOpenApp(id, from: r)
        case .folder(let f): SB.openFolder(f.id, from: r, now: now)
        case .widget(let w): sbOpenWidget(w, r, p)
        case .stack(let s):
            let ws = SB.stackWidgets(s, face: face, now: now)
            if !ws.isEmpty { sbOpenWidget(ws[min(s.index, ws.count - 1)], r, p) }
        case .spacer: return false
        }
        return true
    }

    private func sbOpenWidget(_ w: SBWidget, _ r: CGRect, _ p: CGPoint) {
        if w.kind == .photos { tapPhotosWidget(); return }
        if w.kind == .desktopWidgets { if PersonalGate.allowed { DesktopWidgetSource.shared.tap(p, in: r) }; return }   // Shell/DesktopWidgets.swift
        if let id = w.kind.appID ?? w.config["app"] { shellOpenApp(id, from: r) }   // 2.0 Web App 的小工具帶 app
    }

    private func sbMenuTap(_ m: SBMenu, _ p: CGPoint, now: Double) {
        SB.menu = nil
        guard m.panel.contains(p) else { return }
        for (sz, r) in SBUI.menuSizeButtons(m) where r.contains(p) { if let k = m.key { SB.resize(k, to: sz) }; return }
        guard let (row, _) = zip(m.rows, SBUI.menuRows(m)).first(where: { $0.1.contains(p) }) else { return }
        sbPerform(row.action, now: now)
    }

    func sbPerform(_ a: SBAction, now: Double) {
        switch a {
        case .shareAirDrop: SelfShare.share(PhotosWidgetSource.shared.image.map { .image($0) })
        case .editHome: SB.enterEdit(now: now)
        case .removeItem(let k): SB.sheet = .removeConfirm(k)
        case .editWidget(let k): SB.sheet = .config(k)
        case .editStack(let k): SB.sheet = .stackEdit(k)
        case .rename(let id):
            SB.enterEdit(now: now)
            if let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == "f:\(id)" }) { SB.openFolder(id, from: SB.frame(pl), now: now); SB.folder?.renaming = true }
        case .resize(let k, let s): SB.resize(k, to: s)
        case .addWidget: SB.sheet = .gallery(kind: nil, stack: false, page: 0)
        case .customize: SB.sheet = .customize
        case .editPages: SB.sheet = .editPages
        case .addToHome(let id): SB.addToHome(id)
        case .openApp(let id): shellOpenApp(id)
        case .provider(let id, let verb): AppProviders.perform(id, verb: verb)
        }
    }

    private func sbSheetTap(_ s: SBSheet, _ p: CGPoint, now: Double) {
        switch s {
        case .gallery(let kind, let stack, let page):
            if SBUI.sheetClose.contains(p) || !SBUI.sheetCard.contains(p) { SB.sheet = nil; return }
            if kind == nil && !stack {
                if let (k, _) = SBUI.galleryEntries().first(where: { $0.1.contains(p) }) { SB.sheet = .gallery(kind: k, stack: k == nil, page: 0) }
                return
            }
            if SBUI.galleryBack.contains(p) { SB.sheet = .gallery(kind: nil, stack: false, page: 0); return }
            let sizes = SBUI.gallerySizes(kind: kind)
            if let i = SBUI.galleryDots(sizes.count).firstIndex(where: { $0.contains(p) }) { SB.sheet = .gallery(kind: kind, stack: stack, page: i); return }
            if SBUI.galleryPreviewBox.contains(p) {   // 點預覽的左右半邊＝換大小（跟頁點一樣）
                let d = p.x < SBUI.galleryPreviewBox.midX ? -1 : 1
                SB.sheet = .gallery(kind: kind, stack: stack, page: max(0, min(sizes.count - 1, page + d))); return
            }
            if SBUI.galleryAdd.contains(p) {
                let size = sizes[max(0, min(sizes.count - 1, page))]
                SB.sheet = nil
                if let kind { SB.addWidget(kind, size: size) } else { SB.addStack(size: size) }
                SB.anims.removeAll()
            }
        case .config(let key):
            if SBUI.configDone.contains(p) || !SBUI.configCard.contains(p) { SB.sheet = nil; return }
            guard case .widget(let w)? = SB.layout.item(key), let o = SBWidgetData.options(w.kind).first else { return }
            for (c, r) in zip(o.choices.prefix(5), SBUI.configOptionRows(min(5, o.choices.count))) where r.contains(p) {
                SB.setConfig(key, o.key, c.id)
            }
        case .stackEdit(let key):
            if SBUI.configDone.contains(p) || !SBUI.configCard.contains(p) { SB.sheet = nil; return }
            guard case .stack(let st)? = SB.layout.item(key) else { SB.sheet = nil; return }
            let rows = SBUI.stackRows(min(4, st.widgets.count))
            for (w, r) in zip(st.widgets, rows) where CGRect(x: r.maxX - 110, y: r.minY, width: 110, height: r.height).contains(p) {
                SB.updateStack(key) { $0.widgets.removeAll { $0.id == w.id } }
                if SB.layout.item(key) == nil { SB.sheet = nil }
                return
            }
            let tr = SBUI.stackToggleRows(rows)
            if tr[0].contains(p) { SB.updateStack(key) { $0.smartRotate.toggle() } }
            if tr[1].contains(p) { SB.updateStack(key) { $0.suggestions.toggle() } }
        case .customize:
            if SBUI.configDone.contains(p) || !SBUI.configCard.contains(p) { SB.sheet = nil; return }
            if let (a, _) = SBUI.customizeTiles().first(where: { $0.1.contains(p) }) { HomeAppearance.set(a); SB.pageCache.removeAll() }
            if SBUI.customizeLarge.contains(p) { SB.setLargeIcons(!SB.largeIcons) }
            if HomeAppearance.current == .tinted, let i = SBUI.tintRects().firstIndex(where: { $0.contains(p) }) { HomeAppearance.setTint(srgb(SBUI.tintSwatches[i])); SB.pageCache.removeAll() }
        case .editPages:
            if SBUI.doneButton.insetBy(dx: -8, dy: -8).contains(p) { SB.sheet = nil; return }
            let thumbs = SBUI.pageThumbs(SB.layout.pages.count)
            for (i, r) in thumbs.enumerated() {
                if SB.layout.pages[i].hidden, SBUI.badgeHit(r, icon: false).contains(p) { SB.deletePage(i); return }
                if SBUI.pageCheck(r).insetBy(dx: -16, dy: -16).contains(p) || r.contains(p) { SB.togglePageHidden(i); return }
            }
        case .removeConfirm(let key):
            let b = SBUI.alertButtons
            if b[0].contains(p) { SB.sheet = nil; SB.remove(key); SB.anims.removeAll(); return }
            if b[1].contains(p) || !SBUI.alertCard.contains(p) { SB.sheet = nil }
        }
    }

    private func sbLibraryTap(_ p: CGPoint, now: Double) -> Bool {
        if let m = SB.menu { sbMenuTap(m, p, now: now); return true }
        if SBUI.librarySearch.contains(p) { SB.librarySearching = true; SB.setLibraryExpanded(nil, now: now, immediate: true); return true }
        switch sbHit(p) {
        case .libraryApp(let id):
            // 豆莢總覽：錨在豆莢裡那一顆；展開頁：錨在那一格；搜尋：錨在清單那一格
            let anchor = SBUI.libraryPodIcons()[id]
                ?? zip(SBUI.libraryExpandedApps(), SBUI.libraryExpandedCells()).first { $0.0.id == id }?.1
                ?? zip(SBUI.libraryApps(), SBUI.libraryLayout().cells).first { $0.0.id == id }?.1
            guard let cell = anchor else { return false }
            SB.librarySearching = false
            shellOpenApp(id, from: cell.offsetBy(dx: 0, dy: -SB.libraryScrollNow))   // 2.0 depth：從捲動後的位置長出來
            return true
        case .libraryExpand(let cat):
            SB.setLibraryExpanded(cat, now: now)
            SB.libraryScroll = MotionValue("sbLibScroll", spring: SBMotion.settle, from: 0, to: 0, now: now)
            SB.libraryScrollDragging = false
            log("sb library expand \(cat.rawValue)")
            return true
        case .libraryBackToPods:
            SB.setLibraryExpanded(nil, now: now)
            log("sb library pods")
            return true
        default:
            break
        }
        if SB.librarySearching { SB.librarySearching = false; return true }
        return false
    }

    // MARK: 滾輪／觸控板（ShellInput.shellScroll 的主畫面那段先問）

    func sbScroll(_ e: NSEvent, uv: CGPoint?) -> Bool {
        let now = CACurrentMediaTime()
        let precise = e.hasPreciseScrollingDeltas
        // App 資源庫：觸控板兩指橫滑＝翻回最後一頁（直滑照舊捲清單）
        if Shell.nav.screen == .library, precise, SB.libraryReachable, SB.menu == nil, SB.sheet == nil, !SB.librarySearching,
           let r = sbTrackpadPage(e, now: now, fromLibrary: true) { return r }
        // 2.0 depth：App 資料庫捲動（內容放不下時；跟 App 清單同一套方向語意：deltaY 正＝內容往上）
        if Shell.nav.screen == .library {
            guard SB.menu == nil, SB.sheet == nil, SB.libraryMaxScroll > 0.5 else { return false }
            if precise {
                if e.phase == .began {   // 新的一手：從畫面上的位置 1:1 接著走，不跳
                    let v0 = SB.libraryScrollNow
                    SBInputState.libWheel = v0
                    SB.libraryScrollDragging = false
                    SB.libraryScroll.set(v0, velocity: 0, now: now)
                }
                if SBInputState.libWheel == nil { SBInputState.libWheel = SB.libraryScrollNow }
                // 自然滾動（isDirectionInvertedFromDevice）把裝置方向反過來：先換算回「正＝內容往上」再疊，
                // 不換算的話兩指往下滑內容往上跑＝反自然（FaceOverview 的 overviewScroll 是同一條約定）
                let d = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
                let to = max(0, min(SB.libraryMaxScroll, SBInputState.libWheel! + d))
                SBInputState.libWheel = to
                SB.libraryScrollDragging = false
                SB.libraryScroll.set(to, velocity: 0, now: now)
                if e.phase == .ended || e.phase == .cancelled || e.momentumPhase == .ended { SBInputState.libWheel = nil }
                face.forceDirty = true
                return true
            }
            if e.scrollingDeltaY != 0, now - Shell.lastPageAt > 0.2 {   // 滑鼠滾輪：一格一列
                Shell.lastPageAt = now
                let from = SBInputState.libWheel ?? SB.libraryScrollNow
                let to = max(0, min(SB.libraryMaxScroll, from + (e.scrollingDeltaY > 0 ? 1 : -1) * SBUI.libraryRowPitch))
                SBInputState.libWheel = to
                SB.libraryScrollDragging = false
                SB.libraryScroll.retarget(to, now: now)
                face.forceDirty = true
            }
            return true
        }
        guard Shell.nav.screen == .home else { return false }
        let p = sbPoint(uv)
        // 圖庫詳細頁：換大小
        if case .gallery(let kind, let stack, let page)? = SB.sheet, kind != nil || stack {
            let d = (e.scrollingDeltaX != 0 ? -e.scrollingDeltaX : -e.scrollingDeltaY)
            if !precise || abs(d) > 8, now - Shell.lastPageAt > 0.3, d != 0 {
                Shell.lastPageAt = now
                SB.sheet = .gallery(kind: kind, stack: stack, page: max(0, min(SBUI.gallerySizes(kind: kind).count - 1, page + (d > 0 ? 1 : -1))))
                face.forceDirty = true
            }
            return true
        }
        // 浮動資料夾：觸控板橫捲／滾輪換頁（一手一頁）
        if let f = SB.folder, SB.menu == nil, SB.sheet == nil, SBFloaty.pageCount(SB.folderApps().count) > 1 {
            let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? -e.scrollingDeltaX : (precise ? 0 : -e.scrollingDeltaY)
            if (!precise || abs(d) > 8), d != 0, now - Shell.lastPageAt > 0.35 {
                Shell.lastPageAt = now
                SB.setFolderPage(f.page + (d > 0 ? 1 : -1), now: now); face.forceDirty = true
            }
            return true
        }
        if SB.overlayOpen { return true }
        // Smart Stack 上：上下換
        if let p, !precise || abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX),
           let st = SB.placements(page: SB.pageIndex).first(where: { if case .stack = $0.item { return SB.frame($0).contains(p) }; return false }), let key = st.item.key {
            if precise {
                var acc = SBInputState.scrollStack?.key == key ? SBInputState.scrollStack!.acc : 0
                acc += e.scrollingDeltaY
                if abs(acc) > 60 { SB.stackStep(key, by: acc > 0 ? -1 : 1, now: now); acc = 0 }
                SBInputState.scrollStack = (key, acc)
                if e.phase == .ended || e.momentumPhase == .ended { SBInputState.scrollStack = nil }
            } else if e.scrollingDeltaY != 0, now - Shell.lastPageAt > 0.25 {
                Shell.lastPageAt = now
                SB.stackStep(key, by: e.scrollingDeltaY > 0 ? -1 : 1, now: now)
            }
            face.forceDirty = true
            return true
        }
        // 觸控板兩指橫滑：換頁（1:1 跟手，放手照投射）；直滑照舊轉身體
        if precise {
            guard SB.pageSlots > 1 else { return false }
            if e.momentumPhase != [] { return true }
            return sbTrackpadPage(e, now: now, fromLibrary: false) ?? false
        }
        // 滑鼠滾輪：主畫面的頁之間換，最後一頁再往後是 App 資源庫；第一頁再往回交回原本的路（回錶面），資源庫再往後不動（橫軸不繞圈）；編輯模式不離開
        let dir = e.scrollingDeltaY > 0 ? -1 : (e.scrollingDeltaY < 0 ? 1 : (e.scrollingDeltaX > 0 ? -1 : (e.scrollingDeltaX < 0 ? 1 : 0)))
        guard dir != 0 else { return true }
        let to = SB.page + dir
        if to >= 0, to < SB.pageSlots {
            if now - Shell.lastPageAt > 0.25 { Shell.lastPageAt = now; SB.goToPage(to, now: now); face.forceDirty = true }
            return true
        }
        return SB.editing
    }

    /// 觸控板兩指橫滑翻頁（主畫面與 App 資源庫共用）：nil＝這一手不是橫的，交回原本的路
    private func sbTrackpadPage(_ e: NSEvent, now: Double, fromLibrary: Bool) -> Bool? {
        if e.momentumPhase != [] { return SBInputState.pageMomentum ? true : nil }   // 翻頁那一手的慣性：吃掉，不讓資源庫跟著捲
        if e.phase == .began { SBInputState.scrollPage = false; SBInputState.pageMomentum = false; SBInputState.scrollVertical = false }
        if SBInputState.scrollVertical { return nil }   // 這一手一開始是直的（捲清單）：中途偏橫也不翻頁
        if !SBInputState.scrollPage, e.phase == .changed || e.phase == .began, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) * 1.2, abs(e.scrollingDeltaY) > 1 {
            SBInputState.scrollVertical = true; return nil
        }
        if !SBInputState.scrollPage, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.2, e.phase == .changed || e.phase == .began {   // 橫的才接
            if fromLibrary { SB.armLibraryPaging(now: now) }
            SBInputState.scrollPage = true; SB.pageDragging = true; SB.pageDragValue = SB.pagePosition(now); SB.pageSamples = []
            SBInputState.pageRaw = SB.pageDragValue; SBInputState.pageRawSamples = []
        }
        guard SBInputState.scrollPage else { return nil }
        if e.phase == .ended || e.phase == .cancelled {
            SBInputState.scrollPage = false; SBInputState.pageMomentum = true
            sbPageRelease(now: now); face.forceDirty = true; return true
        }
        let n = CGFloat(SB.pageSlots)
        SBInputState.trackRaw(SBInputState.pageRaw - e.scrollingDeltaX / 1024 * 2.2, now: now)
        var x = SB.pageDragValue - e.scrollingDeltaX / 1024 * 2.2
        if x < -0.3 { x = -0.3 } else if x > n - 0.7 { x = n - 0.7 }
        SB.pageDragValue = x
        SB.pageSamples.append((now, x)); if SB.pageSamples.count > 5 { SB.pageSamples.removeFirst() }
        face.forceDirty = true
        return true
    }

    // MARK: 鍵盤（ShellInput.shellKeyDown 在焦點處理之前先問）

    /// 主畫面／App 資料庫上「回上一層」的前置順序（Esc 與頂端藥丸＝Home 鍵共用）：選單 → sheet → 資料夾 → 編輯模式；
    /// App 資料庫：選單 → 搜尋。收掉了一層回 true，都沒有回 false（交給 ShellNav 的 .back）
    func sbDismissTop(now: Double) -> Bool {
        guard Shell.nav.overlay == .none else { return false }
        if Shell.nav.screen == .library {
            if SB.menu != nil { SB.menu = nil; return true }
            if SB.librarySearching || !SB.libraryQuery.isEmpty { SB.libraryQuery = ""; SB.librarySearching = false; return true }
            return false
        }
        guard Shell.nav.screen == .home else { return false }
        if SB.menu != nil { SB.menu = nil; return true }
        if let s = SB.sheet {
            if case .gallery(let k, let st, _) = s, k != nil || st { SB.sheet = .gallery(kind: nil, stack: false, page: 0) } else { SB.sheet = nil }
            return true
        }
        if SB.folder != nil { SB.closeFolder(now: now); return true }
        if SB.editing { SB.exitEdit(); return true }
        return false
    }

    func sbKeyDown(_ e: NSEvent) -> Bool {
        let now = CACurrentMediaTime()
        defer { face.forceDirty = true }
        let chars = e.characters ?? ""
        let printable = !chars.isEmpty && chars.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }
        if Shell.nav.screen == .library, Shell.nav.overlay == .none {
            if e.keyCode == 53, sbDismissTop(now: now) { return true }
            if e.keyCode == 51 { if !SB.libraryQuery.isEmpty { SB.libraryQuery.removeLast() }; SB.librarySearching = true; return true }
            if e.keyCode == 36 || e.keyCode == 76, SB.librarySearching, let first = SBUI.libraryApps().first {
                SB.librarySearching = false; shellOpenApp(first.id, from: SBUI.libraryCells(1)[0].offsetBy(dx: 0, dy: -SB.libraryScrollNow)); return true
            }
            // ←：翻回最後一頁（照主畫面換頁）
            if e.keyCode == 123, !SB.librarySearching, SB.menu == nil, SB.libraryReachable, !HPAccessibilitySettings.keyboardNavigation {
                SB.armLibraryPaging(now: now); SB.goToPage(SB.librarySlot - 1, now: now); return true
            }
            if printable, !(e.keyCode == 49 && !SB.librarySearching) {   // 直接打字就開始搜尋（實體鍵盤）
                SB.librarySearching = true; SB.libraryQuery += chars; return true
            }
            return false
        }
        guard Shell.nav.screen == .home, Shell.nav.overlay == .none else { return false }
        if var f = SB.folder, f.renaming, case .folder(let fo)? = SB.layout.item("f:\(f.id)") {
            switch e.keyCode {
            case 36, 76, 53: f.renaming = false; SB.folder = f
            case 51: var n = fo.name; if !n.isEmpty { n.removeLast() }; SB.renameFolder(f.id, n)
            default: if printable { SB.renameFolder(f.id, fo.name + chars) }
            }
            return true
        }
        if e.keyCode == 53 { return sbDismissTop(now: now) }
        if case .gallery(let kind, let stack, let page)? = SB.sheet, kind != nil || stack {
            let n = SBUI.gallerySizes(kind: kind).count
            switch e.keyCode {
            case 123: SB.sheet = .gallery(kind: kind, stack: stack, page: max(0, page - 1)); return true
            case 124: SB.sheet = .gallery(kind: kind, stack: stack, page: min(n - 1, page + 1)); return true
            case 36, 76: sbSheetTap(.gallery(kind: kind, stack: stack, page: page), CGPoint(x: SBUI.galleryAdd.midX, y: SBUI.galleryAdd.midY), now: now); return true
            default: break
            }
        }
        if SB.overlayOpen { return false }
        if SB.editing {
            let items = SB.placements(page: SB.pageIndex).compactMap(\.item.key)
            let cur = ShellFocus.id.flatMap(SBAX.key(fromID:))
            switch e.keyCode {
            case 48:   // Tab：換選中的那一個
                guard !items.isEmpty else { return true }
                let i = cur.flatMap { items.firstIndex(of: $0) } ?? -1
                let d = e.modifierFlags.contains(.shift) ? -1 : 1
                ShellFocus.id = SBAX.id(items[(i + d + items.count) % items.count]); return true
            case 123, 124, 125, 126:
                guard let k = cur, items.contains(k) else { if let f = items.first { ShellFocus.id = SBAX.id(f) }; return true }
                let (dc, dr) = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)][e.keyCode]!
                SB.move(k, dc: dc, dr: dr, now: now)
                NSAccessibility.post(element: self, notification: .layoutChanged)
                return true
            case 51, 117:   // Delete：移除（先確認）
                if let k = cur { SB.sheet = .removeConfirm(k) }; return true
            case 36, 76, 49:
                guard let k = cur, let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == k }) else { return false }
                let r = SB.frame(pl)
                _ = sbTap(CGPoint(x: r.midX, y: r.midY), long: false); return true
            default: return false
            }
        }
        // 平常：← → 在主畫面的頁之間換，最後一頁再 → 是 App 資源庫；第一頁再 ← 交回原本的路（回錶面），資源庫再 → 不動
        if e.keyCode == 123 || e.keyCode == 124, !HPAccessibilitySettings.keyboardNavigation {
            let to = SB.page + (e.keyCode == 124 ? 1 : -1)
            if to >= 0, to < SB.pageSlots { SB.goToPage(to, now: now); return true }
        }
        return false
    }

    // MARK: 快照旗標（applyShellSnapshotFlags 最後一行叫）

    /// --home-page N、--home-menu KEY、--home-folder ID、--home-gallery KIND[:page]、--home-config KEY、--home-stack-edit KEY、--home-customize、
    /// --home-edit-pages、--home-remove KEY、--library-search 文字、--library-expand DH1011、--home-drag KEY@col,row[@x,y]（拖曳中的讓位；HOMEPLAY_ANIM=sbreflow:t 凍結讓位的彈簧）、
    /// --home-page-anim A:B（HOMEPLAY_ANIM=sbpage:t 凍結換頁）、--stack-index KEY@n
    func applySBSnapshotFlags() {
        let args = CommandLine.arguments
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let now = CACurrentMediaTime()
        _ = SB.layout   // 先載入這個人的排列（載入時會清掉暫態）
        // 對照用：HOMEPLAY_HOME_BACKDROP=某張 1024² 圖＝把它當成「剛才的錶面」做桌布（只在本機拿參考圖量面板的材質，不打包任何圖）
        if let path = ProcessInfo.processInfo.environment["HOMEPLAY_HOME_BACKDROP"], let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            Shell.homeHue = Shell.hue(fromFace: img, face: face); Shell.captureHomeBackdrop(img); SB.pageCache.removeAll()
        }
        if Shell.homeEditing { SB.editSince = now - 0.07; SB.wasEditing = true }
        // 2.0 depth：HOMEPLAY_LIBRARY_SCROLL=0…1＝資料庫捲到那個位置（驗收第 17 個 App 拿得到）
        if let k = ProcessInfo.processInfo.environment["HOMEPLAY_LIBRARY_SCROLL"].flatMap({ Double($0) }), Shell.nav.screen == .library {
            let v = max(0, min(1, k)) * SB.libraryMaxScroll
            SB.libraryScroll.set(v, velocity: 0, now: now)
            if HPMotion.frozen("sbLibScroll") != nil { SB.libraryScroll = MotionValue("sbLibScroll", spring: .smooth, from: 0, to: max(v, 1e-3), now: now) }   // 要拍到指示器就凍在半途
        }
        if arg("--home-page") == "library" { SB.goToPage(SB.librarySlot, now: now); SB.armLibraryPaging(now: now) }   // 翻到資源庫那一格（頁點上的資源庫圖示）
        if let s = arg("--home-page"), let n = Int(s) { SB.page = max(0, min(SB.visiblePages.count - 1, n)); SB.pagePos = MotionValue("sbpage", spring: SBMotion.page, from: CGFloat(SB.page), to: CGFloat(SB.page), now: now) }
        if let s = arg("--home-page-anim")?.split(separator: ":").compactMap({ Int($0) }), s.count == 2 {
            SB.page = s[1]; SB.pagePos = MotionValue("sbpage", spring: SBMotion.page, from: CGFloat(s[0]), to: CGFloat(s[1]), now: now)
        }
        if let s = arg("--stack-index")?.split(separator: "@"), s.count == 2, let n = Int(s[1]) { SB.updateStack(String(s[0])) { $0.index = n }; SB.stackShown[String(s[0])] = now + 3600 }
        if let k = arg("--home-menu") { SB.openMenu(for: k, now: now - 1) }
        if args.contains("--home-edit-menu") { SB.openEditMenu(now: now - 1) }
        if let x = arg("--face-drag").flatMap(Double.init) { facePageDemo(CGFloat(x)) }   // 錶面跟手換頁拖到一半（x 頁，負＝往左拖看下一個）
        if let id = arg("--home-folder"), let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == "f:\(id)" }) { SB.openFolder(id, from: SB.frame(pl), now: now - 1) }
        if let n = arg("--home-folder-page").flatMap(Int.init), SB.folder != nil { SB.folder?.page = n }   // 浮動資料夾：打開在第幾頁
        if let g = arg("--home-gallery") {
            let parts = g.split(separator: ":")
            let k = SBWidgetKind(rawValue: String(parts[0]))
            SB.sheet = .gallery(kind: k, stack: parts[0] == "stack", page: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
        if let k = arg("--home-config") { SB.sheet = .config(k) }
        if let k = arg("--home-stack-edit") { SB.sheet = .stackEdit(k) }
        if args.contains("--home-customize") { SB.sheet = .customize }
        if args.contains("--home-edit-pages") { SB.sheet = .editPages }
        if let k = arg("--home-remove") { SB.sheet = .removeConfirm(k) }
        if let q = arg("--library-search") { SB.libraryQuery = q; SB.librarySearching = true }
        // 快照：直接停在某個分類的展開頁（rawValue 例如 DH1011）。要拍縮放的半途用 HOMEPLAY_ANIM=sbLibZoom:t。
        if let c = arg("--library-expand") {
            for cat in SBLibraryCategory.allCases where cat.rawValue.caseInsensitiveCompare(c) == .orderedSame {
                SB.setLibraryExpanded(cat, now: now - 1, immediate: false)
            }
        }
        if let spec = arg("--home-drag")?.split(separator: "@"), spec.count >= 2 {
            let key = String(spec[0]), cr = spec[1].split(separator: ",").compactMap { Int($0) }
            guard cr.count == 2, let pl = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == key }) else { return }
            Shell.homeEditing = true; SB.wasEditing = true; SB.editSince = now - 0.07
            let f = SB.frame(pl)
            let before = Dictionary(SB.placements(page: SB.pageIndex).compactMap { p in p.item.key.map { ($0, SB.frame(p)) } }, uniquingKeysWith: { a, _ in a })
            SB.beginDrag(key, at: CGPoint(x: f.midX, y: f.midY), now: now)
            let dest = SB.frame(col: cr[0], row: cr[1], span: pl.item.span)
            var pt = CGPoint(x: dest.midX + 26, y: dest.midY + 18)
            if spec.count > 2 { let xy = spec[2].split(separator: ",").compactMap { Double($0) }; if xy.count == 2 { pt = CGPoint(x: xy[0], y: xy[1]) } }
            SB.drag?.point = pt; SB.drag?.target = (cr[0], cr[1])
            SB.drag?.lift = MotionValue("sblift", spring: SBMotion.lift, from: SBMotion.liftScale, to: SBMotion.liftScale, now: now)
            // 讓位的彈簧從拖之前的位置出發（HOMEPLAY_ANIM=sbreflow:t 停在第 t 秒）
            for p in SBLayout.pack(SB.displayItems(page: SB.pageIndex)).placed {
                guard let k = p.item.key, let b = before[k] else { continue }
                let to = SB.frame(p)
                SB.anims[k] = (MotionValue("sbreflow", spring: SBMotion.reflow, from: b.minX, to: to.minX, now: now),
                               MotionValue("sbreflow", spring: SBMotion.reflow, from: b.minY, to: to.minY, now: now), SB.pageIndex)
            }
        }
    }
}

// MARK: - 輔助使用：主畫面的元素（ShellAccessibility.items 的主畫面那段改叫這裡）

enum SBAX {
    static func id(_ key: String) -> String { key.hasPrefix("a:") ? "home.app.\(key.dropFirst(2))" : "home.\(key)" }
    static func key(fromID id: String) -> String? {
        if id.hasPrefix("home.app.") { return "a:" + id.dropFirst(9) }
        if id.hasPrefix("home."), id.dropFirst(5).contains(":") { return String(id.dropFirst(5)) }
        return nil
    }
    static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    /// iPhone App 念成「名字（在 CarPlay 打开）」：點了是在 CarPlay 上開
    static func appLabel(_ app: PetApp) -> String { app is PhoneCarPlayApp ? app.title + L("sb.ax.openInCarPlay", "（在 CarPlay 打开）") : app.title }
    /// 自訂動作（VoiceOver 轉子「動作」）的順序；名字照這個順序給
    static func actionNames(editing: Bool) -> [String] {
        editing ? [L("sb.ax.left", "向左移动"), L("sb.ax.right", "向右移动"), L("sb.ax.up", "向上移动"), L("sb.ax.down", "向下移动"), L("sb.ax.remove", "从主屏幕移除"), L("sb.ax.done", "完成编辑")]
                : [L("sb.menu.editHome", "编辑主屏幕")]
    }

    static func items(face: Face) -> [ShellAXItem] {
        var out: [ShellAXItem] = []
        let now = CACurrentMediaTime()
        if Shell.nav.screen == .library {
            out.append(ShellAXItem(id: "sb.search", kind: .chrome, role: .button, label: L("sb.library.search", "搜索 App 资源库"), value: SB.libraryQuery.isEmpty ? nil : SB.libraryQuery,
                                   rect: SBUI.librarySearch, shape: .capsule, press: .tap(center(SBUI.librarySearch))))
            out.append(ShellAXItem(id: "avatar", kind: .chrome, role: .button, label: L("people.switch.title", "换人"), rect: Shell.avatarRect, shape: .circle, press: .tap(center(Shell.avatarRect))))
            let off = SB.libraryScrollNow   // 2.0 depth：捲動後的框跟著位移；被裁掉一半以上的不列
            for (i, h) in SBUI.libraryLayout().headers.enumerated() where h.y - off >= SBUI.libraryTop - 32 && h.y - off < 1000 {   // 分區標題（iPhone）
                out.append(ShellAXItem(id: "sb.library.section.\(i)", kind: .text, role: .heading, label: h.title,
                                       rect: CGRect(x: HPTokens.Home.gridMargin, y: h.y - off, width: 600, height: SBUI.libraryRowPitch)))
            }
            for (app, cell) in zip(SBUI.libraryApps(), SBUI.libraryLayout().cells) {
                let ir = SBUI.libraryIcon(cell).offsetBy(dx: 0, dy: -off)
                let vis = ir.intersection(CGRect(x: -1e9, y: SBUI.libraryTop - 32, width: 2e9, height: 1024))
                guard vis.height >= ir.height * 0.5 else { continue }
                out.append(ShellAXItem(id: "home.app.\(app.id)", kind: .homeItem, role: .button, label: SBAX.appLabel(app), rect: ir, shape: .rounded(ir.width * 0.2237), press: .tap(center(ir))))
            }
            return menuItems() ?? out
        }
        if let m = menuItems() { return m }
        if let s = SB.sheet { return sheetItems(s) }
        if let f = SB.folder, case .folder(let fo)? = SB.layout.item("f:\(f.id)") {
            out.append(ShellAXItem(id: "sb.folder.title", kind: .text, role: .heading, label: fo.name, rect: SBUI.folderTitle))
            for (id, cell) in zip(SBFloaty.pages(fo.apps).dropFirst(f.page).first ?? [], SBUI.folderCells()) {   // 浮動資料夾：看得到的那一頁
                guard let app = AppRegistry.app(id) else { continue }
                let ir = SB.iconRect(in: cell)
                out.append(ShellAXItem(id: "home.app.\(id)", kind: .homeItem, role: .button, label: SBAX.appLabel(app), rect: ir, shape: .rounded(ir.width * 0.2237), press: .tap(center(ir))))
            }
            return out
        }
        if SB.editing {
            out.append(ShellAXItem(id: "sb.editMenu", kind: .chrome, role: .button, label: L("sb.ax.editMenu", "添加小组件、自定、编辑页面"), rect: SBUI.editMenuButton, shape: .capsule, press: .tap(center(SBUI.editMenuButton))))
            out.append(ShellAXItem(id: "sb.done", kind: .chrome, role: .button, label: L("home.done", "完成"), rect: SBUI.doneButton, shape: .capsule, press: .tap(center(SBUI.doneButton))))
        } else {
            out.append(ShellAXItem(id: "avatar", kind: .chrome, role: .button, label: L("people.switch.title", "换人"), rect: Shell.avatarRect, shape: .circle, press: .tap(center(Shell.avatarRect))))
        }
        let names = actionNames(editing: SB.editing)
        for pl in SB.placements(page: SB.pageIndex) {
            guard let key = pl.item.key else { continue }
            let f = SB.frame(pl)
            switch pl.item {
            case .app(let id):
                guard let app = AppRegistry.app(id) else { continue }
                let ir = SB.iconRect(in: f)
                out.append(ShellAXItem(id: SBAX.id(key), kind: .homeItem, role: .button, label: SBAX.appLabel(app), rect: ir, shape: .rounded(ir.width * 0.2237), press: .tap(center(ir)), customActions: PersonHome.canEdit ? names : []))
            case .folder(let fo):
                let ir = SB.iconRect(in: f)
                out.append(ShellAXItem(id: SBAX.id(key), kind: .homeItem, role: .button, label: fo.name, value: String(format: L("sb.ax.folderCount", "%d 个 App"), fo.apps.count), rect: ir,
                                       shape: .rounded(ir.width * 0.2237), press: .tap(center(ir)), roleDescription: L("sb.ax.folder", "文件夹"), customActions: PersonHome.canEdit ? names : []))
            case .widget(let w):
                out.append(ShellAXItem(id: SBAX.id(key), kind: .homeItem, role: .button, label: w.title, value: (w.kind == .photos ? PhotosWidgetSource.shared.axState : nil) ?? w.size.title, rect: f, shape: .rounded(Shell.widgetRadius),   // 2.0 depth：照片卡的請求／去設定也念
                                       press: .tap(center(f)), roleDescription: L("a11y.widget", "小组件"), customActions: PersonHome.canEdit ? names : []))
            case .stack(let s):
                let ws = SB.stackWidgets(s, face: face, now: now)
                let top = ws.isEmpty ? "" : ws[min(s.index, ws.count - 1)].title
                out.append(ShellAXItem(id: SBAX.id(key), kind: .homeItem, role: .button, label: top,
                                       value: String(format: L("sb.ax.stackPos", "第 %1$d 个，共 %2$d 个"), min(s.index, ws.count - 1) + 1, ws.count), rect: f, shape: .rounded(Shell.widgetRadius),
                                       press: .tap(center(f)), roleDescription: L("sb.smartStack", "智能叠放"), customActions: PersonHome.canEdit ? names : []))
            case .spacer: break
            }
        }
        let n = SB.visiblePages.count
        if n > 1 || SB.editing {
            let r = SBUI.dotsCapsule(n)
            out.append(ShellAXItem(id: "sb.pages", kind: .chrome, role: .button, label: L("sb.ax.pages", "页面"),
                                   value: String(format: L("sb.ax.page", "第 %1$d 页，共 %2$d 页"), min(SB.page, n - 1) + 1, n), rect: r, shape: .capsule, press: SB.editing ? .tap(center(r)) : .none))
        }
        if SB.libraryReachable {   // 頁點最後的資源庫圖示
            let r = SBUI.libraryDotHit
            out.append(ShellAXItem(id: "sb.libraryDot", kind: .chrome, role: .button, label: L("sb.library", "App 资源库"), rect: r, shape: .circle, press: .tap(center(r))))
        }
        return out
    }

    private static func menuItems() -> [ShellAXItem]? {
        guard let m = SB.menu else { return nil }
        var out: [ShellAXItem] = []
        for (sz, r) in SBUI.menuSizeButtons(m) {
            out.append(ShellAXItem(id: "sb.menu.size.\(sz.rawValue)", kind: .control, role: .radio(sz == m.current), label: String(format: L("sb.ax.size", "%@尺寸"), sz.title), rect: r, shape: .rounded(28), press: .tap(center(r))))
        }
        for (i, (row, r)) in zip(m.rows, SBUI.menuRows(m)).enumerated() {
            out.append(ShellAXItem(id: "sb.menu.\(i)", kind: .control, role: .button, label: row.title, rect: r, shape: .rounded(30), press: .tap(center(r))))
        }
        return out
    }

    private static func sheetItems(_ s: SBSheet) -> [ShellAXItem] {
        var out: [ShellAXItem] = []
        func btn(_ id: String, _ label: String, _ r: CGRect, _ shape: HPAXNote.Shape = .capsule) {
            out.append(ShellAXItem(id: id, kind: .control, role: .button, label: label, rect: r, shape: shape, press: .tap(center(r))))
        }
        switch s {
        case .gallery(let kind, let stack, let page):
            btn("sb.sheet.close", L("a11y.close", "关闭"), SBUI.sheetClose, .circle)
            if kind == nil && !stack {
                for (k, r) in SBUI.galleryEntries() { btn("sb.gallery.\(k?.rawValue ?? "stack")", k?.title ?? L("sb.smartStack", "智能叠放"), r, .rounded(30)) }
            } else {
                btn("sb.gallery.back", L("a11y.back", "返回"), SBUI.galleryBack, .circle)
                let sizes = SBUI.gallerySizes(kind: kind)
                for (i, r) in SBUI.galleryDots(sizes.count).enumerated() {
                    out.append(ShellAXItem(id: "sb.gallery.size.\(i)", kind: .control, role: .radio(i == page), label: String(format: L("sb.ax.size", "%@尺寸"), sizes[i].title), rect: r, shape: .circle, press: .tap(center(r))))
                }
                btn("sb.gallery.add", L("sb.addWidget", "添加小组件"), SBUI.galleryAdd)
            }
        case .config(let key):
            if case .widget(let w)? = SB.layout.item(key), let o = SBWidgetData.options(w.kind).first {
                let cur = SBWidgetData.value(w, o.key)
                for (c, r) in zip(o.choices.prefix(5), SBUI.configOptionRows(min(5, o.choices.count))) {
                    out.append(ShellAXItem(id: "sb.config.\(c.id)", kind: .control, role: .radio(c.id == cur), label: c.title, rect: r, shape: .capsule, press: .tap(center(r))))
                }
            }
            btn("sb.sheet.done", L("home.done", "完成"), SBUI.configDone)
        case .stackEdit(let key):
            if case .stack(let st)? = SB.layout.item(key) {
                let rows = SBUI.stackRows(min(4, st.widgets.count))
                for (w, r) in zip(st.widgets, rows) { btn("sb.stack.remove.\(w.id)", String(format: L("sb.ax.removeFromStack", "从叠放移除「%@」"), w.kind.title), CGRect(x: r.maxX - 110, y: r.minY, width: 110, height: r.height), .circle) }
                let tr = SBUI.stackToggleRows(rows)
                out.append(ShellAXItem(id: "sb.stack.rotate", kind: .control, role: .toggle(st.smartRotate), label: L("sb.smartRotate", "智能旋转"), rect: tr[0], shape: .capsule, press: .tap(center(tr[0]))))
                out.append(ShellAXItem(id: "sb.stack.suggest", kind: .control, role: .toggle(st.suggestions), label: L("sb.suggestions", "小组件建议"), rect: tr[1], shape: .capsule, press: .tap(center(tr[1]))))
            }
            btn("sb.sheet.done", L("home.done", "完成"), SBUI.configDone)
        case .customize:
            for (a, r) in SBUI.customizeTiles() {
                out.append(ShellAXItem(id: "sb.look.\(a.rawValue)", kind: .control, role: .radio(a == HomeAppearance.current), label: a.title, rect: r, shape: .rounded(36), press: .tap(center(r))))
            }
            out.append(ShellAXItem(id: "sb.look.large", kind: .control, role: .toggle(SB.largeIcons), label: L("sb.largeIcons", "大图标（隐藏名称）"), rect: SBUI.customizeLarge, shape: .capsule, press: .tap(center(SBUI.customizeLarge))))
            btn("sb.sheet.done", L("home.done", "完成"), SBUI.configDone)
        case .editPages:
            for (i, r) in SBUI.pageThumbs(SB.layout.pages.count).enumerated() {
                let c = SBUI.pageCheck(r)
                out.append(ShellAXItem(id: "sb.page.\(i)", kind: .control, role: .toggle(!SB.layout.pages[i].hidden), label: String(format: L("sb.ax.pageN", "第 %d 页"), i + 1), rect: c, shape: .circle, press: .tap(center(c))))
            }
            btn("sb.sheet.done", L("home.done", "完成"), SBUI.doneButton)
        case .removeConfirm(let key):
            let b = SBUI.alertButtons
            btn("sb.remove.ok", key.hasPrefix("a:") ? L("sb.remove.fromHome", "从主屏幕移除") : L("sb.remove.confirm", "移除"), b[0])
            btn("sb.remove.cancel", L("sb.cancel", "取消"), b[1])
        }
        return out
    }
}

extension PetView {
    /// VoiceOver 的自訂動作（ShellAXElement.accessibilityCustomActions 叫）
    func sbAXCustom(_ itemID: String, _ index: Int) -> Bool {
        guard let key = SBAX.key(fromID: itemID) else { return false }
        let now = CACurrentMediaTime()
        defer { face.forceDirty = true; NSAccessibility.post(element: self, notification: .layoutChanged) }
        if !SB.editing { if index == 0 { SB.enterEdit(now: now); return true }; return false }
        switch index {
        case 0: return SB.move(key, dc: -1, dr: 0, now: now)
        case 1: return SB.move(key, dc: 1, dr: 0, now: now)
        case 2: return SB.move(key, dc: 0, dr: -1, now: now)
        case 3: return SB.move(key, dc: 0, dr: 1, now: now)
        case 4: SB.sheet = .removeConfirm(key); return true
        case 5: SB.exitEdit(); return true
        default: return false
        }
    }
}

// MARK: - 浮動資料夾的輸入小工具

extension PetView {
    /// 從資料夾拿出來：資料夾少一個（剩一個就變回圖示、空了就刪），關資料夾，在主畫面上接著拖
    func sbPullOutOfFolder(_ id: String, at p: CGPoint, now: Double) {
        var l = SB.layout
        if let f = SB.folder, case .folder(var fo)? = l.item("f:\(f.id)") {
            fo.apps = (f.drag?.order ?? fo.apps).filter { $0 != id }
            l.replace("f:\(f.id)", with: fo.apps.count == 1 ? .app(fo.apps[0]) : .folder(fo))
            if fo.apps.isEmpty { l.remove("f:\(f.id)") }
        }
        SB.layout = l; SB.commit()
        SB.folder = nil
        SB.enterEdit(now: now)
        SB.beginDragFree(app: id, at: p, now: now)
    }
    func sbFolderPageBegin(_ pr: inout SBPress, now: Double) {
        pr.mode = .folderPage
        pr.startPage = SB.folderPagePos(now)
        SB.pageSamples = []
        if var f = SB.folder { f.pageDrag = pr.startPage; f.pageAnim = nil; SB.folder = f }
    }
}
