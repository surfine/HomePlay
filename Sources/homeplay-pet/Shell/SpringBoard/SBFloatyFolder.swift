// 浮動資料夾（2026-11-06 拍板「補」）：資料夾打開時浮在模糊的主畫面上——標題在面板上方、面板裡一頁 3×3、
// 超過九個就往右多一頁（橫滑、觸控板橫捲、點頁點換頁），面板下方是頁點。
// 打開：資料夾圖示裡的小格子從圖示中心放大成面板，同時跟面板的內容交叉淡化；背後的主畫面模糊淡出。關上反過來。
// 編輯模式拖放：在面板裡拖＝在資料夾裡重排（其他格讓位）；拖到面板左右緣停 0.5 秒＝翻頁；拖出面板＝拿出來放回主畫面。
// 純函式（pages、cells、targetIndex、reorder、edge）selftest 直接驗。

import AppKit

enum SBFloaty {
    /// 一個資料夾最多四頁
    static let maxApps = SBFolder.pageSize * 4
    /// 面板與標題（標題下距、頁點區照資料夾的視覺設定分開量）
    static var panel: CGRect { SBUI.folderPanel }
    /// 面板圓角跟螢幕同心（下緣離螢幕 72 → 138 − 72）；打開途中跟著面板等比縮
    static var radius: CGFloat { HPTokens.Radius.concentric(rect: panel) }
    static let pageControlHeight: CGFloat = 68
    static var dotsY: CGFloat { panel.maxY + pageControlHeight / 2 }
    static let edgeBand: CGFloat = 56

    static func pages(_ apps: [String]) -> [[String]] {
        stride(from: 0, to: apps.count, by: SBFolder.pageSize).map { Array(apps[$0 ..< min(apps.count, $0 + SBFolder.pageSize)]) }
    }
    static func pageCount(_ n: Int) -> Int { max(1, (n + SBFolder.pageSize - 1) / SBFolder.pageSize) }

    /// 第 page 頁的九格，pagePos＝現在捲到哪（小數＝滑到一半）
    static func cells(page: Int, pagePos: CGFloat) -> [CGRect] {
        let dx = (CGFloat(page) - pagePos) * panel.width
        return SBUI.folderCells().map { $0.offsetBy(dx: dx, dy: 0) }
    }
    /// 拖到這一點＝放到整個清單的第幾位（這一頁最近的格子；夾在 0…count-1）
    static func targetIndex(_ p: CGPoint, page: Int, count: Int) -> Int {
        let cs = cells(page: page, pagePos: CGFloat(page))
        let i = cs.indices.min { hypot(cs[$0].midX - p.x, cs[$0].midY - p.y) < hypot(cs[$1].midX - p.x, cs[$1].midY - p.y) } ?? 0
        return max(0, min(count - 1, page * SBFolder.pageSize + i))
    }
    static func reorder(_ apps: [String], moving id: String, to index: Int) -> [String] {
        guard let from = apps.firstIndex(of: id) else { return apps }
        var a = apps; a.remove(at: from); a.insert(id, at: max(0, min(a.count, index))); return a
    }
    /// 點在面板左右緣的帶子：-1 左、1 右、0 都不是
    static func edge(_ p: CGPoint) -> Int {
        guard panel.insetBy(dx: -edgeBand, dy: 0).contains(p) else { return 0 }
        if p.x < panel.minX + edgeBand { return -1 }
        if p.x > panel.maxX - edgeBand { return 1 }
        return 0
    }
    static func dotRects(_ n: Int) -> [CGRect] {
        let pitch: CGFloat = 30, w = CGFloat(n - 1) * pitch
        return (0..<n).map { CGRect(x: 512 - w / 2 + CGFloat($0) * pitch - 15, y: dotsY - 22, width: 30, height: 44) }
    }
}

/// 資料夾裡正在拖的 App
struct SBFolderDrag {
    var id: String
    var point: CGPoint
    var order: [String]
    var edgeSince: Double = 0
    var edgeSide = 0
    var lastFlip = -10.0
}

extension SB {
    static func folderApps() -> [String] {
        guard let f = folder, case .folder(let fo)? = layout.item("f:\(f.id)") else { return [] }
        return f.drag?.order ?? fo.apps
    }
    static func folderPagePos(_ now: Double) -> CGFloat {
        guard let f = folder else { return 0 }
        if let d = f.pageDrag { return d }
        return f.pageAnim.map { $0.done(now) ? $0.to : $0.value(now) } ?? CGFloat(f.page)
    }
    static func setFolderPage(_ p: Int, now: Double) {
        guard var f = folder else { return }
        let n = SBFloaty.pageCount(folderApps().count), to = max(0, min(n - 1, p))
        let from = folderPagePos(now)
        f.page = to; f.pageDrag = nil
        f.pageAnim = HPMotion.reduceMotion ? nil : MotionValue("sbfolder.page", spring: SBMotion.page, from: from, to: CGFloat(to), now: now)
        folder = f
    }
    static func folderDragBegin(_ id: String, at p: CGPoint) {
        folder?.drag = SBFolderDrag(id: id, point: p, order: folderApps())
    }
    /// 回 true＝拖出面板了（呼叫的人把它拿出來、接著在主畫面上拖）
    static func folderDragUpdate(_ p: CGPoint?, now: Double) -> Bool {
        guard var f = folder, var d = f.drag else { return false }
        if let p { d.point = p }
        if !SBFloaty.panel.insetBy(dx: -40, dy: -40).contains(d.point) { return true }
        let side = SBFloaty.edge(d.point)
        if side != d.edgeSide { d.edgeSide = side; d.edgeSince = now }
        let n = SBFloaty.pageCount(d.order.count)
        if side != 0, now - d.edgeSince > SBMotion.edgeDwell, now - d.lastFlip > SBMotion.edgeRearm, (0..<n).contains(f.page + side) {
            d.lastFlip = now; f.drag = d; folder = f
            setFolderPage(f.page + side, now: now)
            f = folder ?? f
        } else if side == 0 {
            d.order = SBFloaty.reorder(d.order, moving: d.id, to: SBFloaty.targetIndex(d.point, page: f.page, count: d.order.count))
        }
        f.drag = d; folder = f
        return false
    }
    static func folderDragEnd() {
        guard var f = folder, let d = f.drag else { return }
        f.drag = nil; folder = f
        var l = layout
        if case .folder(var fo)? = l.item("f:\(f.id)"), fo.apps != d.order { fo.apps = d.order; l.replace("f:\(f.id)", with: .folder(fo)); layout = l; commit() }
    }
}

extension Face {
    /// 打開／關上中的浮動資料夾：t＝打開進度
    func drawSBFloatyFolder(_ g: CGContext, _ f: SBOpenFolder, _ folder: SBFolder, t: CGFloat, now: Double) {
        let full = SBFloaty.panel
        let panel = HPMotion.reduceMotion ? full : Shell.lerp(f.from, full, t)
        let k = panel.width / full.width
        let apps = SB.folderApps(), pages = SBFloaty.pages(apps), pos = SB.folderPagePos(now)
        let dragging = f.drag?.id
        // 名字：大字靠左、面板上方（改名時加游標）
        let tf = HPType.sf(76, .bold)
        let name = f.renaming ? folder.name + (Int(now * 2) % 2 == 0 ? "|" : " ") : folder.name
        g.saveGState(); g.setAlpha(t)
        drawLeft(g, Face.clipped(name, tf, SBUI.folderTitle.width), font: tf, x: SBUI.folderTitle.minX, y: SBUI.folderTitle.maxY - 14, color: .white)
        if f.renaming { g.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor); g.fill(CGRect(x: SBUI.folderTitle.minX, y: SBUI.folderTitle.maxY, width: SBUI.folderTitle.width, height: 3)) }
        g.restoreGState()
        HPGlass.add(continuousRoundedRect(panel, radius: SBFloaty.radius * k), union: nil, presence: HPMotion.reduceMotion ? t : 1) { [weak self] c in
            guard let self else { return }
            // 交叉淡化：前半段看到的是資料夾圖示裡那 3×3 小格子（跟著面板放大），後半段換成真的格子
            let cross = HPMotion.reduceMotion ? 1 : max(0, min(1, (t - 0.15) / 0.55))
            if cross < 1, !HPMotion.reduceMotion {
                c.saveGState(); c.setAlpha(1 - cross)
                let s = panel.width * 0.24, gap = (panel.width - 3 * s) / 4
                for (i, id) in apps.prefix(9).enumerated() {
                    guard let app = AppRegistry.app(id) else { continue }
                    Shell.drawHomeIcon(c, face: self, app: app, in: CGRect(x: panel.minX + gap + CGFloat(i % 3) * (s + gap), y: panel.minY + gap + CGFloat(i / 3) * (s + gap), width: s, height: s))
                }
                c.restoreGState()
            }
            guard cross > 0 else { return }
            c.saveGState(); c.setAlpha(cross)
            c.addPath(continuousRoundedRect(panel, radius: SBFloaty.radius * k)); c.clip()   // 背景裁切：翻頁時格子不出面板
            for (pi, page) in pages.enumerated() where abs(CGFloat(pi) - pos) < 1 {
                let cells = SBFloaty.cells(page: pi, pagePos: pos)
                for (i, id) in page.enumerated() where id != dragging {
                    var cell = cells[i]
                    cell = CGRect(x: panel.minX + (cell.minX - full.minX) * k, y: panel.minY + (cell.minY - full.minY) * k, width: cell.width * k, height: cell.height * k)
                    c.saveGState()
                    if SB.editing, !HPMotion.reduceMotion { let a = self.sbWiggle("a:\(id)", i, cell, now); c.translateBy(x: cell.midX, y: cell.midY); c.rotate(by: a); c.translateBy(x: -cell.midX, y: -cell.midY) }
                    self.drawSBItem(c, .app(id), cell, now: now, badges: SB.editing)
                    c.restoreGState()
                }
            }
            c.restoreGState()
        }
        // 頁點（兩頁以上才畫）
        if pages.count > 1 {
            g.saveGState(); g.setAlpha(t)
            for (i, r) in SBFloaty.dotRects(pages.count).enumerated() {
                let on = max(0, 1 - abs(CGFloat(i) - pos))
                g.setFillColor(NSColor.white.withAlphaComponent(0.4 + 0.55 * on).cgColor)
                g.fillEllipse(in: CGRect(x: r.midX - 7, y: r.midY - 7, width: 14, height: 14))
            }
            g.restoreGState()
        }
    }
    /// 拖著的那顆：浮在面板上面、跟著指標、略放大
    func drawSBFolderDragged(_ g: CGContext, _ d: SBFolderDrag, now: Double) {
        let cell = SBUI.folderCells()[0], s: CGFloat = SBMotion.liftScale
        let r = CGRect(x: d.point.x - cell.width * s / 2, y: d.point.y - SB.iconRect(in: cell).height * s / 2, width: cell.width * s, height: cell.height * s)
        drawSBItem(g, .app(d.id), r, now: now, badges: false, labels: false)
    }
}

enum SBFloatySelftest {
    static func run(_ check: (Bool, String) -> Void) {
        let apps = (0..<20).map { "a\($0)" }
        check(SBFloaty.pages(apps).map(\.count) == [9, 9, 2] && SBFloaty.pageCount(0) == 1 && SBFloaty.pageCount(9) == 1 && SBFloaty.pageCount(10) == 2
              && SBFloaty.maxApps == 36, "浮動資料夾：一頁九格、超過就多一頁、最多四頁")   // l10n-ignore
        let c0 = SBFloaty.cells(page: 0, pagePos: 0), c1 = SBFloaty.cells(page: 1, pagePos: 0)
        check(c1[0].minX - c0[0].minX == SBFloaty.panel.width && SBFloaty.cells(page: 1, pagePos: 1)[0] == c0[0], "浮動資料夾：別頁的格子在面板外、捲到了就對齊")   // l10n-ignore
        check(SBFloaty.targetIndex(CGPoint(x: c0[4].midX, y: c0[4].midY), page: 1, count: 20) == 13
              && SBFloaty.targetIndex(CGPoint(x: c0[8].midX, y: c0[8].midY), page: 2, count: 20) == 19, "浮動資料夾：拖放的目標位置照頁換算、夾在清單裡")   // l10n-ignore
        check(SBFloaty.reorder(["a", "b", "c", "d"], moving: "a", to: 2) == ["b", "c", "a", "d"] && SBFloaty.reorder(["a", "b"], moving: "x", to: 0) == ["a", "b"],
              "浮動資料夾：重排")   // l10n-ignore
        let p = SBFloaty.panel
        check(SBFloaty.edge(CGPoint(x: p.minX + 10, y: p.midY)) == -1 && SBFloaty.edge(CGPoint(x: p.maxX - 10, y: p.midY)) == 1
              && SBFloaty.edge(CGPoint(x: p.midX, y: p.midY)) == 0 && SBFloaty.edge(CGPoint(x: p.minX - 200, y: p.midY)) == 0, "浮動資料夾：左右緣的翻頁帶")   // l10n-ignore
        check(SBUI.folderTitle.maxY < p.minY && SBFloaty.dotsY + 7 < 1024 - HPTokens.Home.panelInset, "浮動資料夾：標題在面板上方、頁點在畫面內")   // l10n-ignore
    }
}
