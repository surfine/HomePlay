// 2.0 SpringBoard：畫主畫面（多頁、編輯模式的晃動與「−」、拖曳中的讓位、頁點、Smart Stack）、資料夾、選單、
// 小工具圖庫（各大小的即時預覽）、Edit Widget、編輯疊放、自訂、編輯頁面、移除確認、App 資料庫。
//
// 對照 iOS 27（scratchpad/realref/ios27-springboard）：編輯模式左上筆刷膠囊（選單：加入小工具／自訂／編輯頁面）、右上 ✓ 膠囊、
// 「−」是灰色圓（不是玻璃）、小工具右下有改大小的把手、頁點在底部一顆玻璃膠囊裡（只在編輯模式；平常多頁才畫點）；
// 資料夾：名字大字靠左在面板上方、面板是一大塊玻璃、後面重度模糊；圖庫：App 圖示＋名稱、✕、標題＋說明、置中的預覽、頁點、
// 一整條 App 色的「加入小工具」膠囊。編輯背景圖片不做（HomePlay 的桌布就是剛才的錶面）。
//
// 玻璃只在控制層：頂端按鈕、頁點膠囊、選單、資料夾面板、sheet 與提示卡；圖示、小工具（內容）不上玻璃。
// 靜止時一頁畫成一張圖重用（清透／染色的圖示玻璃底用真的玻璃）；晃動、拖曳時逐項畫（玻璃底換成半透明近似，標在報告）。

import AppKit
import CoreImage

/// 畫與點共用的幾何（1024 畫布座標）
enum SBUI {
    static let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    static var panel: CGRect { full.insetBy(dx: HPTokens.Home.panelInset, dy: HPTokens.Home.panelInset) }
    /// 編輯模式：左上筆刷膠囊、右上 ✓ 膠囊（跟返回鈕同高、左右對稱）
    static var editMenuButton: CGRect { let b = HPTokens.backButton; return CGRect(x: b.minX, y: b.minY, width: 196, height: b.height) }
    static var doneButton: CGRect { Shell.editDoneRect }
    static func badge(_ item: CGRect, icon: Bool) -> CGRect {
        let ir = icon ? SB.iconRect(in: item) : item
        let d: CGFloat = 56
        return CGRect(x: ir.minX - d * 0.3, y: ir.minY - d * 0.3, width: d, height: d)
    }
    /// 小工具右下的改大小把手（點按範圍 88）
    static func resizeHandle(_ r: CGRect) -> CGRect { CGRect(x: r.maxX - 66, y: r.maxY - 66, width: 88, height: 88) }
    static let dotsY: CGFloat = 976
    static func dotsCapsule(_ n: Int) -> CGRect {
        let w = CGFloat(n) * 30 + 44
        return CGRect(x: 512 - w / 2, y: dotsY - 30, width: w, height: 60)
    }

    // 資料夾（3×3）
    static let folderPanel = CGRect(x: 182, y: 292, width: 660, height: 660)
    static func folderCells() -> [CGRect] {
        let pitchX: CGFloat = 206, pitchY: CGFloat = 206
        let x0 = folderPanel.minX + (folderPanel.width - 2 * pitchX - 152) / 2, y0 = folderPanel.minY + 46
        return (0..<9).map { CGRect(x: x0 + CGFloat($0 % 3) * pitchX, y: y0 + CGFloat($0 / 3) * pitchY, width: 152, height: 200) }
    }
    static var folderTitle: CGRect { CGRect(x: folderPanel.minX + 8, y: folderPanel.minY - 120, width: folderPanel.width - 16, height: 96) }

    // 選單
    // 10-grid：夾在螢幕內的邊距用 48（HPGrid.scale）；沒夾到時左緣對齊錨點（selftest 有驗）
    static let menuWidth: CGFloat = 620, menuRow: CGFloat = 100, menuSizes: CGFloat = 116
    static func menuPanel(anchor: CGRect, rows: Int, sizes: Bool) -> CGRect {
        let h = CGFloat(rows) * menuRow + (sizes ? menuSizes : 0) + 24
        var x = anchor.minX
        if x + menuWidth > 976 { x = anchor.maxX - menuWidth }
        x = max(48, min(976 - menuWidth, x))
        var y = anchor.maxY + 22
        if y + h > 1000 { y = anchor.minY - 22 - h }
        if y < 48 { y = max(48, (1024 - h) / 2) }
        return CGRect(x: x, y: y, width: menuWidth, height: h)
    }
    static func menuRows(_ m: SBMenu) -> [CGRect] {
        let top = m.panel.minY + 12 + (m.sizes.isEmpty ? 0 : menuSizes)
        return m.rows.indices.map { CGRect(x: m.panel.minX + 12, y: top + CGFloat($0) * menuRow, width: m.panel.width - 24, height: menuRow) }
    }
    static func menuSizeButtons(_ m: SBMenu) -> [(SBWidgetSize, CGRect)] {
        let n = CGFloat(m.sizes.count), w: CGFloat = 110
        let gap = (m.panel.width - 24 - n * w) / max(1, n - 1 + 2)
        return m.sizes.enumerated().map { ($0.element, CGRect(x: m.panel.minX + 12 + gap + CGFloat($0.offset) * (w + gap), y: m.panel.minY + 14, width: w, height: 92)) }
    }

    // sheet
    static let sheetCard = CGRect(x: 40, y: 104, width: 944, height: 880)
    static var sheetClose: CGRect { CGRect(x: sheetCard.maxX - 40 - 88, y: sheetCard.minY + 32, width: 88, height: 88) }
    static var galleryBack: CGRect { CGRect(x: sheetCard.minX + 32, y: sheetCard.minY + 32, width: 88, height: 88) }
    /// 圖庫清單：第一格 Smart Stack，其餘每個種類
    static func galleryEntries() -> [(SBWidgetKind?, CGRect)] {
        let entries: [SBWidgetKind?] = [nil] + SBWidgetKind.allCases.filter { $0 != .webApp }.map { $0 }   // Web App 的小工具從它的圖示長按加
        let colW = (sheetCard.width - 96) / 3
        var out: [(SBWidgetKind?, CGRect)] = []
        for (i, e) in entries.enumerated() {
            let x = sheetCard.minX + 48 + CGFloat(i % 3) * colW + 6, y = sheetCard.minY + 160 + CGFloat(i / 3) * 128
            out.append((e, CGRect(x: x, y: y, width: colW - 12, height: 112)))
        }
        return out
    }
    static var galleryPreviewBox: CGRect { CGRect(x: sheetCard.minX + 40, y: sheetCard.minY + 236, width: sheetCard.width - 80, height: 360) }
    static var galleryAdd: CGRect { CGRect(x: sheetCard.minX + 48, y: sheetCard.maxY - 150, width: sheetCard.width - 96, height: 108) }
    static func galleryDots(_ n: Int) -> [CGRect] {
        let pitch: CGFloat = 44, x0 = 512 - CGFloat(n - 1) * pitch / 2
        return (0..<n).map { CGRect(x: x0 + CGFloat($0) * pitch - 22, y: galleryPreviewBox.maxY + 54, width: 44, height: 56) }
    }
    static func gallerySizes(kind: SBWidgetKind?) -> [SBWidgetSize] { kind?.sizes ?? [.small, .medium, .large] }

    // 設定卡（Edit Widget、編輯疊放、自訂）
    static let configCard = CGRect(x: 96, y: 96, width: 832, height: 888)
    static var configDone: CGRect { CGRect(x: configCard.midX - 200, y: configCard.maxY - 128, width: 400, height: 96) }
    static func configRows(top: CGFloat, count: Int, rowH: CGFloat = 86) -> [CGRect] {
        (0..<count).map { CGRect(x: configCard.minX + 40, y: top + CGFloat($0) * (rowH + 8), width: configCard.width - 80, height: rowH) }
    }
    static func customizeTiles() -> [(HomeAppearance, CGRect)] {
        let w: CGFloat = 170, gap = (configCard.width - 80 - 4 * w) / 3
        return HomeAppearance.allCases.enumerated().map { ($0.element, CGRect(x: configCard.minX + 40 + CGFloat($0.offset) * (w + gap), y: configCard.minY + 150, width: w, height: 190)) }
    }
    static var customizeLarge: CGRect { CGRect(x: configCard.minX + 40, y: configCard.minY + 380, width: configCard.width - 80, height: 96) }
    static let tintSwatches: [UInt32] = [0x0A84FF, 0x30D158, 0xFF9F0A, 0xFF375F, 0xBF5AF2, 0x8E8E93]
    static func tintRects() -> [CGRect] {
        let d: CGFloat = 88, gap: CGFloat = 26, x0 = configCard.midX - (CGFloat(tintSwatches.count) * d + CGFloat(tintSwatches.count - 1) * gap) / 2
        return tintSwatches.indices.map { CGRect(x: x0 + CGFloat($0) * (d + gap), y: configCard.minY + 510, width: d, height: d) }
    }

    // 提示卡（移除確認）
    static let alertCard = CGRect(x: 172, y: 300, width: 680, height: 460)
    static var alertButtons: [CGRect] {
        [CGRect(x: alertCard.minX + 32, y: alertCard.maxY - 250, width: alertCard.width - 64, height: 100),
         CGRect(x: alertCard.minX + 32, y: alertCard.maxY - 132, width: alertCard.width - 64, height: 100)]
    }

    // 編輯頁面
    static func pageThumbs(_ n: Int) -> [CGRect] {
        let s: CGFloat = n <= 2 ? 330 : 250, gap: CGFloat = 44, perRow = n <= 2 ? n : 3
        let rows = (n + perRow - 1) / perRow
        let totalH = CGFloat(rows) * (s + 120) - 40
        let y0 = max(170, (1024 - totalH) / 2)
        return (0..<n).map { i in
            let r = i / perRow, inRow = min(perRow, n - r * perRow)
            let x0 = 512 - (CGFloat(inRow) * s + CGFloat(inRow - 1) * gap) / 2
            return CGRect(x: x0 + CGFloat(i % perRow) * (s + gap), y: y0 + CGFloat(r) * (s + 120), width: s, height: s)
        }
    }
    static func pageCheck(_ thumb: CGRect) -> CGRect { CGRect(x: thumb.midX - 34, y: thumb.maxY + 18, width: 68, height: 68) }

    // App 資料庫
    // 10-grid：左緣＝主畫面網格的 gridMargin（跟第一欄圖示同一條線）；y 讓膠囊中線對齊右上頭像的中線 152
    static var librarySearch: CGRect { CGRect(x: HPTokens.Home.gridMargin, y: 152 - 44, width: 690, height: 88) }
    static let libraryTop: CGFloat = 268           // 第一列的 y（2.0 depth：捲動量的基準）
    // 使用者 2026-10-25：圖示和字不要那麼擠——圖示縮小、列距加大，字下面留出空氣（照 iOS App 資料庫的疏密）
    static let libraryRowPitch: CGFloat = 228
    static let libraryRowHeight: CGFloat = 196
    static func libraryApps() -> [PetApp] {
        let q = SB.libraryQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let all = AppRegistry.visible.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || $0.id.contains(q) }
    }
    static func libraryCells(_ n: Int) -> [CGRect] {
        (0..<n).map { i in
            CGRect(x: HPTokens.Home.gridMargin + CGFloat(i % 4) * HPTokens.Home.columnPitch, y: libraryTop + CGFloat(i / 4) * libraryRowPitch, width: HPTokens.Home.iconSide, height: libraryRowHeight)
        }
    }
    static let libraryIconSide: CGFloat = 120
    // 網格：第一欄圖示左緣＝搜尋欄左緣、最後一欄右緣＝頭像右緣（gridMargin），四欄等距；點按範圍仍是整格
    static func libraryIcon(_ cell: CGRect) -> CGRect {
        let m = HPTokens.Home.gridMargin, col = ((cell.minX - m) / HPTokens.Home.columnPitch).rounded()
        let pitch = (1024 - 2 * m - libraryIconSide) / 3
        return CGRect(x: m + col * pitch, y: cell.minY, width: libraryIconSide, height: libraryIconSide)
    }
}

extension SBWidgetKind {
    /// 圖庫「加入小工具」膠囊的顏色（照 App 的主色）
    var accent: NSColor {
        switch self {
        case .photos: return srgb(0xFF9500)
        case .weather: return srgb(0x0A84FF)
        case .calendar, .music: return srgb(0xFF3B30)
        case .reminders: return srgb(0x0A84FF)
        case .podcasts: return srgb(0xA14FE0)
        case .home: return srgb(0xFF9F0A)
        case .worldClock, .timers, .alarms: return srgb(0xFF9F0A)
        case .findMy, .batteries: return srgb(0x30D158)
        case .webApp: return srgb(0x0A84FF)
        }
    }
}

extension Face {
    // MARK: 入口（HomeScreen.drawHome 第一行叫）

    func drawSpringBoard(_ g: CGContext, _ now: Double, library: Bool) {
        if Shell.homeLayer == nil { SB.pageCache.removeAll() }   // 外觀、圖示、排列換了（各處照舊把 homeLayer 清掉）
        let (bg, wallShot) = sbBackdrop()
        Shell.homeLayer = ("sb", bg)
        drawUpright(g, bg, in: SBUI.full)
        if library { drawSBLibrary(g, now); return }
        let pagesHidden = SB.sheet == .editPages   // 編輯頁面：後面只留桌布（iOS 27）
        if !pagesHidden {
            drawSBTopBar(g, now)
            drawSBPages(g, now, wallShot: wallShot)
            drawSBDots(g, now)
        }
        sbSelectionRing(g)
        if let d = SB.drag, !d.resizing { drawSBDragged(g, d, now) }
        guard SB.overlayOpen else { return }
        if SB.folder != nil, SB.folder?.backdrop == nil, let shot = g.makeImage() {   // 資料夾後面：這一刻的主畫面重度模糊
            let ci = CIImage(cgImage: shot), k = Double(shot.width) / 1024
            let b = ci.clampedToExtent().applyingGaussianBlur(sigma: 34 * k).cropped(to: ci.extent)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.06, kCIInputSaturationKey: 1.1])
            SB.folder?.backdrop = Face.ciContext.createCGImage(b, from: ci.extent)
        }
        HPGlass.flush(g, face: self, now: now)   // 底下的控制先算完：上面那一層的玻璃不疊在它們下面
        if SB.folder != nil { drawSBFolder(g, now) }
        if SB.menu != nil { drawSBMenu(g, now) }
        if let s = SB.sheet { drawSBSheet(g, s, now) }
    }

    /// 桌布＋面板（玻璃）一張；另外回面板之前的桌布（清透／染色的圖示玻璃取樣用）
    private func sbBackdrop() -> (CGImage, CGImage?) {
        let wall = shellWallpaper()
        let sc = renderPixelScale, look = HomeAppearance.current
        let key = "sbbg|\(ObjectIdentifier(wall).hashValue)|\(Int(sc * 100))|\(look.cacheKey)"
        if let c = SB.pageCache[key], let w = SB.pageCache[key + "|wall"] { return (c, w) }
        if let c = SB.pageCache[key] { return (c, nil) }
        let px = Int((1024 * sc).rounded())
        var shot: CGImage?
        let img = makeImage(px, px) { g in
            g.scaleBy(x: sc, y: sc)
            let full = SBUI.full
            drawUpright(g, wall, in: full)
            if look.wallpaperShade > 0 { g.setFillColor(NSColor(white: 0, alpha: look.wallpaperShade).cgColor); g.fill(full) }
            if look.glassBase { shot = g.makeImage() }
            let inset = HPTokens.Home.panelInset
            let panelPath = continuousRoundedRect(full.insetBy(dx: inset, dy: inset), radius: Screen.concentric(inset: inset))
            HPGlass.add(panelPath) { _ in }
            HPGlass.flush(g, face: self, clear: true)
            g.saveGState(); g.addPath(panelPath); g.setFillColor(NSColor(white: 0, alpha: HPTokens.Home.panelShade).cgColor); g.fillPath(); g.restoreGState()
            HPGlass.panelRim(g, panelPath)
        }
        if SB.pageCache.count > 40 { SB.pageCache.removeAll() }
        SB.pageCache[key] = img
        if let shot { SB.pageCache[key + "|wall"] = shot }
        return (img, shot)
    }

    // MARK: 頂端：問候語＋頭像；編輯模式＝筆刷膠囊＋ ✓

    private func drawSBTopBar(_ g: CGContext, _ now: Double) {
        guard SB.editing else {
            let H = HPTokens.Home.self
            let sx = Shell.iconRect(in: Shell.cell(0, 0)).minX + H.greetingInset
            for (i, line) in Shell.greeting(hour: Shell.greetingHour(self)).enumerated() {
                let isName = i > 0
                let sf = HPType.sf(H.greetingSize, isName ? H.nameWeight : H.greetingWeight)
                drawLeft(g, Face.clipped(line, sf, 660), font: sf, x: sx, y: H.greetingBaseline + CGFloat(i) * H.greetingLeading,
                         color: NSColor.white.withAlphaComponent((isName ? H.nameAlpha : H.greetingAlpha) * LiveActivityStack.greetingAlpha(now)), kern: H.greetingKern)
            }
            drawShellAvatar(g)
            return
        }
        let m = SBUI.editMenuButton, d = SBUI.doneButton
        HPGlass.container("sbtop") {
            HPGlass.addCapsule(m, interactive: true) { [weak self] c in
                self?.drawSymbol(c, "paintbrush.pointed.fill", in: CGRect(x: m.midX - 22, y: m.midY - 22, width: 44, height: 44), color: HPGlass.ink)
            }
            HPGlass.addCapsule(d, interactive: true) { [weak self] c in
                self?.drawSymbol(c, "checkmark", in: CGRect(x: d.midX - 22, y: d.midY - 22, width: 44, height: 44), color: HPGlass.ink, weight: .bold)
            }
        }
    }

    // MARK: 頁

    private func drawSBPages(_ g: CGContext, _ now: Double, wallShot: CGImage?) {
        let vis = SB.visiblePages, pos = SB.pagePosition(now)
        g.saveGState()
        g.addPath(continuousRoundedRect(SBUI.panel, radius: Screen.concentric(inset: HPTokens.Home.panelInset))); g.clip()
        let lo = max(0, Int(pos.rounded(.down))), hi = min(vis.count - 1, Int(pos.rounded(.up)))
        if lo <= hi {
            for vi in lo...hi {
                let dx = (CGFloat(vi) - pos) * 1024
                guard abs(dx) < 1024 else { continue }
                g.saveGState(); g.translateBy(x: dx, y: 0)
                if HPMotion.reduceMotion, SB.pageDragging || !SB.pagePos.done(now) {
                    g.translateBy(x: -dx, y: 0)                       // 減少動態效果：不滑，交叉淡化
                    g.setAlpha(max(0, 1 - abs(CGFloat(vi) - pos)))
                }
                drawSBPage(g, vis[vi], now: now, wallShot: wallShot, current: vi == SB.page)
                g.restoreGState()
            }
        }
        g.restoreGState()
    }

    /// 一頁：靜止（沒在編輯、沒有讓位動畫）用整張快取；不然逐項畫
    private func drawSBPage(_ g: CGContext, _ pi: Int, now: Double, wallShot: CGImage?, current: Bool) {
        let items = SB.displayItems(page: pi)
        let placed = SBLayout.pack(items).placed.filter { !$0.item.isSpacer }
        let live = SB.editing || SB.drag != nil || SB.pressedKey != nil || (current && SB.anims.values.contains { !$0.x.done(now) || !$0.y.done(now) }) || !SB.fades.isEmpty
        if !live {
            drawUpright(g, sbPageImage(pi, placed, wallShot: wallShot), in: SBUI.full)
            for p in placed { drawSBLiveContent(g, p.item, SB.frame(p), now: now) }
            if current { SB.anims.removeAll() }
            return
        }
        for (i, p) in placed.enumerated() {
            guard let key = p.item.key else { continue }
            var r = SB.frame(p)
            if current { r = sbAnimated(key, r, now: now) }
            let angle = SB.editing && !HPMotion.reduceMotion && SB.drag?.key != key && SB.sheet == nil && SB.folder == nil ? sbWiggle(key, i, r, now) : 0
            var alpha: CGFloat = 1
            if let f = SB.fades[key] { alpha = CGFloat(min(1, (now - f) / HPMotion.reduceFade)) }
            g.saveGState()
            g.setAlpha(alpha)
            if angle != 0 { g.translateBy(x: r.midX, y: r.midY); g.rotate(by: angle); g.translateBy(x: -r.midX, y: -r.midY) }
            if let d = SB.drag, d.folderReady, d.folderTarget == key { sbFolderHover(g, r) }
            drawSBItem(g, p.item, r, now: now, glassApprox: true, badges: SB.editing)
            g.restoreGState()
        }
    }

    /// 動畫中的位置：目標換了就重設彈簧（保留速度）；減少動態效果：直接到、淡入
    private func sbAnimated(_ key: String, _ target: CGRect, now: Double) -> CGRect {
        if var a = SB.anims[key], a.page == SB.pageIndex {
            if a.x.to != target.minX || a.y.to != target.minY {
                if HPMotion.reduceMotion {
                    a.x = MotionValue("sbreflow", spring: SBMotion.reflow, from: target.minX, to: target.minX, now: now)
                    a.y = MotionValue("sbreflow", spring: SBMotion.reflow, from: target.minY, to: target.minY, now: now)
                    SB.fades[key] = now
                } else {
                    a.x.retarget(target.minX, now: now); a.y.retarget(target.minY, now: now)
                }
                SB.anims[key] = a
            }
            return CGRect(x: a.x.done(now) ? target.minX : a.x.value(now), y: a.y.done(now) ? target.minY : a.y.value(now), width: target.width, height: target.height)
        }
        SB.anims[key] = (MotionValue("sbreflow", spring: SBMotion.reflow, from: target.minX, to: target.minX, now: now),
                         MotionValue("sbreflow", spring: SBMotion.reflow, from: target.minY, to: target.minY, now: now), SB.pageIndex)
        return target
    }

    /// 晃動：相鄰的反相；大的小工具轉得少（角落位移跟圖示差不多）
    private func sbWiggle(_ key: String, _ i: Int, _ r: CGRect, _ now: Double) -> CGFloat {
        let phase = (i % 2 == 0 ? 0 : Double.pi) + Double(abs(key.hashValue % 7)) * 0.11
        let t = (now - SB.editSince) / SBMotion.wigglePeriod * 2 * .pi + phase
        let amp = SBMotion.wiggleDegrees * .pi / 180 * min(1, 180 / max(r.width, r.height))
        return amp * CGFloat(sin(t))
    }

    /// 靜止的一頁（圖示、標籤、資料夾圖示、清透／染色的玻璃底）；小工具的內容每幀另外畫
    private func sbPageImage(_ pi: Int, _ placed: [SBPlacement], wallShot: CGImage?) -> CGImage {
        let sc = renderPixelScale, look = HomeAppearance.current
        let fp = placed.map { "\($0.item.key ?? "")@\($0.col),\($0.row)" }.joined(separator: ";")
        let folders = placed.compactMap { if case .folder(let f) = $0.item { return f.apps.joined(separator: ",") + f.name }; return nil }.joined(separator: "|")
        let key = "sbpage|\(pi)|\(fp)|\(folders)|\(look.cacheKey)|\(Int(sc * 100))|\(Typo.language)|\(Shell.homeDayKey(Face.displayDate))|\(SB.largeIcons)"
        if let c = SB.pageCache[key] { return c }
        let px = Int((1024 * sc).rounded())
        let img = makeImage(px, px) { g in
            g.scaleBy(x: sc, y: sc)
            if look.glassBase {
                for p in placed {
                    let r = SB.frame(p)
                    if p.item.isIcon { let ir = SB.iconRect(in: r); HPGlass.add(continuousRoundedRect(ir, radius: ir.width * 0.2237)) { _ in } }
                    else { HPGlass.add(continuousRoundedRect(r, radius: Shell.widgetRadius)) { _ in } }
                }
                HPGlass.flush(g, face: self, clear: true, backdrop: wallShot)
            }
            for p in placed { drawSBItem(g, p.item, SB.frame(p), now: CACurrentMediaTime(), glassApprox: false, badges: false, content: false) }
        }
        if SB.pageCache.count > 40 { SB.pageCache.removeAll() }
        SB.pageCache[key] = img
        return img
    }

    /// 靜止頁上每幀要更新的：小工具內容（時鐘、天氣、正在播放…）
    private func drawSBLiveContent(_ g: CGContext, _ it: SBItem, _ r: CGRect, now: Double) {
        switch it {
        case .widget(let w): drawSBWidget(g, w, r, now: now)
        case .stack(let s): drawSBStack(g, s, r, now: now)
        default: break
        }
    }

    // MARK: 一個項目

    /// content＝要不要畫小工具內容（快取頁不畫，每幀另外畫）
    func drawSBItem(_ g: CGContext, _ it: SBItem, _ r: CGRect, now: Double, glassApprox: Bool, badges: Bool, content: Bool = true, labels: Bool = true) {
        let look = HomeAppearance.current
        let lf = HPType.sf(HPType.Size.iconLabel, HPTokens.Home.iconLabelWeight), lb = HPTokens.Home.labelBaseline
        let showLabel = labels && !SB.largeIcons
        func label(_ s: String, _ under: CGRect) {
            guard showLabel else { return }
            let t = Face.clipped(s, lf, r.width + Shell.colGap - 6)
            drawLeft(g, t, font: lf, x: r.midX - Typo.width(t, lf) / 2, y: under.maxY + lb, color: .white)
        }
        func approxBase(_ path: CGPath) {
            guard glassApprox, look.glassBase else { return }
            g.saveGState(); g.addPath(path)
            g.setFillColor(look == .tinted ? (HomeAppearance.tintColor.blended(withFraction: 0.78, of: .black) ?? .black).withAlphaComponent(0.6).cgColor : NSColor(white: 1, alpha: 0.16).cgColor)
            g.fillPath(); g.restoreGState()
        }
        let pressed = content && SB.pressedKey != nil && SB.pressedKey == it.key && !SB.editing   // 快取頁（content＝false）不烤進按下的樣子
        switch it {
        case .app(let id):
            guard let app = AppRegistry.app(id) else { return }
            let ir = SB.iconRect(in: r)
            approxBase(continuousRoundedRect(ir, radius: ir.width * 0.2237))
            Shell.drawHomeIcon(g, face: self, app: app, in: ir)
            if pressed { g.saveGState(); g.addPath(continuousRoundedRect(ir, radius: ir.width * 0.2237)); g.setFillColor(NSColor(white: 0, alpha: 0.28).cgColor); g.fillPath(); g.restoreGState() }
            label(app.title, ir)
            if badges { sbBadge(g, SBUI.badge(r, icon: true)) }
        case .folder(let f):
            let ir = SB.iconRect(in: r)
            sbFolderIcon(g, f, ir, glassApprox: glassApprox)
            if pressed { g.saveGState(); g.addPath(continuousRoundedRect(ir, radius: ir.width * 0.2237)); g.setFillColor(NSColor(white: 0, alpha: 0.22).cgColor); g.fillPath(); g.restoreGState() }
            label(f.name, ir)
            if badges { sbBadge(g, SBUI.badge(r, icon: true)) }
        case .widget(let w):
            approxBase(continuousRoundedRect(r, radius: Shell.widgetRadius))
            if content { drawSBWidget(g, w, r, now: now) }
            if pressed { g.saveGState(); g.addPath(continuousRoundedRect(r, radius: Shell.widgetRadius)); g.setFillColor(NSColor(white: 0, alpha: 0.18).cgColor); g.fillPath(); g.restoreGState() }
            label(w.title, r)
            if badges { sbBadge(g, SBUI.badge(r, icon: false)); if w.kind.sizes.count > 1 { sbResizeHandle(g, r) } }
        case .stack(let s):
            approxBase(continuousRoundedRect(r, radius: Shell.widgetRadius))
            if content { drawSBStack(g, s, r, now: now) }
            let ws = SB.stackWidgets(s, face: self, now: now)
            label(ws.isEmpty ? "" : ws[min(s.index, ws.count - 1)].title, r)
            if badges { sbBadge(g, SBUI.badge(r, icon: false)); sbResizeHandle(g, r) }
        case .spacer: break
        }
    }

    /// 「−」：灰色圓＋深色減號（iOS 27 量到的樣子，不是玻璃）
    private func sbBadge(_ g: CGContext, _ b: CGRect) {
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.25).cgColor)
        g.setFillColor(NSColor(white: 0.62, alpha: 0.94).cgColor); g.fillEllipse(in: b)
        g.restoreGState()
        g.setFillColor(NSColor(white: 0.08, alpha: 0.9).cgColor)
        g.addPath(HPComponents.capsulePath(CGRect(x: b.midX - b.width * 0.24, y: b.midY - 3, width: b.width * 0.48, height: 6))); g.fillPath()
    }
    /// 小工具右下角的把手：沿著圓角的一段粗弧
    private func sbResizeHandle(_ g: CGContext, _ r: CGRect) {
        let rad = Shell.widgetRadius
        let c = CGPoint(x: r.maxX - rad, y: r.maxY - rad)
        g.saveGState()
        g.setStrokeColor(NSColor(white: 0.85, alpha: 0.9).cgColor); g.setLineWidth(12); g.setLineCap(.round)
        g.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.3).cgColor)
        g.addArc(center: c, radius: rad + 6, startAngle: 0.12 * .pi, endAngle: 0.38 * .pi, clockwise: false)
        g.strokePath()
        g.restoreGState()
    }
    /// 資料夾圖示：半透明的底＋九宮格的小圖示
    func sbFolderIcon(_ g: CGContext, _ f: SBFolder, _ ir: CGRect, glassApprox: Bool) {
        let path = continuousRoundedRect(ir, radius: ir.width * 0.2237)
        g.saveGState(); g.addPath(path); g.setFillColor(NSColor(white: 1, alpha: 0.24).cgColor); g.fillPath(); g.restoreGState()
        g.saveGState(); g.addPath(path); g.setStrokeColor(NSColor(white: 1, alpha: 0.28).cgColor); g.setLineWidth(1.5); g.strokePath(); g.restoreGState()
        let s = ir.width * 0.24, gap = (ir.width - 3 * s) / 4
        for (i, id) in f.apps.prefix(9).enumerated() {
            guard let app = AppRegistry.app(id) else { continue }
            let mr = CGRect(x: ir.minX + gap + CGFloat(i % 3) * (s + gap), y: ir.minY + gap + CGFloat(i / 3) * (s + gap), width: s, height: s)
            Shell.drawHomeIcon(g, face: self, app: app, in: mr)
        }
    }
    /// 拖著的 App 停在別的圖示上：那個圖示後面長出資料夾的底（iOS 的提示）
    private func sbFolderHover(_ g: CGContext, _ r: CGRect) {
        let ir = SB.iconRect(in: r).insetBy(dx: -18, dy: -18)
        g.saveGState(); g.addPath(continuousRoundedRect(ir, radius: ir.width * 0.2237)); g.setFillColor(NSColor(white: 1, alpha: 0.3).cgColor); g.fillPath(); g.restoreGState()
    }

    // MARK: Smart Stack

    func drawSBStack(_ g: CGContext, _ s: SBStack, _ r: CGRect, now: Double) {
        let ws = SB.stackWidgets(s, face: self, now: now)
        guard !ws.isEmpty else { return }
        let key = "s:\(s.id)"
        var off: CGFloat = 0
        if let d = SB.stackDrag, d.key == key { off = d.offset }
        else if let a = SB.stackAnim[key] { off = a.done(now) ? 0 : a.value(now); if a.done(now) { SB.stackAnim[key] = nil } }
        let idx = min(s.index, ws.count - 1)
        g.saveGState()
        g.addPath(continuousRoundedRect(r, radius: Shell.widgetRadius)); g.clip()
        func place(_ i: Int, _ dy: CGFloat) {
            guard i >= 0, i < ws.count, abs(dy) < r.height else { return }
            drawSBWidget(g, ws[i], r.offsetBy(dx: 0, dy: dy), now: now)
        }
        place(idx, off)
        if off < 0 { place(idx + 1, off + r.height + 8) } else if off > 0 { place(idx - 1, off - r.height - 8) }
        g.restoreGState()
        // 右邊的頁點：編輯模式一直有；平常換過之後亮 1.8 秒
        let shown = SB.stackShown[key].map { now - $0 } ?? 99
        let alpha: CGFloat = SB.editing || SB.stackDrag?.key == key ? 1 : CGFloat(max(0, min(1, (1.8 - shown) / 0.4)))
        guard alpha > 0.01, ws.count > 1 else { return }
        let pitch: CGFloat = 22, x = r.maxX + 16, y0 = r.midY - CGFloat(ws.count - 1) * pitch / 2
        for i in ws.indices {
            g.setFillColor(NSColor.white.withAlphaComponent((i == idx ? 0.95 : 0.4) * alpha).cgColor)
            g.fillEllipse(in: CGRect(x: x - 5, y: y0 + CGFloat(i) * pitch - 5, width: 10, height: 10))
        }
    }

    /// 編輯模式用鍵盤選中的那一個（方向鍵搬它）：系統焦點色的框
    private func sbSelectionRing(_ g: CGContext) {
        guard SB.editing, let id = ShellFocus.id, let key = SBAX.key(fromID: id), SB.drag == nil, SB.sheet == nil,
              let p = SB.placements(page: SB.pageIndex).first(where: { $0.item.key == key }) else { return }
        let f = SB.frame(p), r = (p.item.isIcon ? SB.iconRect(in: f) : f).insetBy(dx: -12, dy: -12)
        let accent = NSColor.keyboardFocusIndicatorColor.usingColorSpace(.sRGB)?.withAlphaComponent(1) ?? HPTokens.blue
        g.saveGState()
        g.addPath(continuousRoundedRect(r, radius: p.item.isIcon ? r.width * 0.25 : Shell.widgetRadius + 12)); g.setStrokeColor(accent.cgColor); g.setLineWidth(7); g.strokePath()
        g.restoreGState()
    }

    // MARK: 頁點

    private func drawSBDots(_ g: CGContext, _ now: Double) {
        let n = SB.visiblePages.count
        guard n > 1 || SB.editing else { return }
        let pos = SB.pagePosition(now)
        let cap = SBUI.dotsCapsule(n)
        func dots(_ c: CGContext) {
            for i in 0..<n {
                let on = max(0, 1 - abs(CGFloat(i) - pos))
                let x = cap.minX + 22 + CGFloat(i) * 30 + 8 - 7
                c.setFillColor(NSColor.white.withAlphaComponent(0.4 + 0.55 * on).cgColor)
                c.fillEllipse(in: CGRect(x: x, y: SBUI.dotsY - 7, width: 14, height: 14))
            }
        }
        if SB.editing { HPGlass.addCapsule(cap, interactive: true) { c in dots(c) } } else { dots(g) }
    }

    // MARK: 拖著的那個

    private func drawSBDragged(_ g: CGContext, _ d: SBDrag, _ now: Double) {
        let span = d.item.span
        let base = SB.frame(col: 0, row: 0, span: span)
        var r = CGRect(x: d.point.x - d.grab.x, y: d.point.y - d.grab.y, width: base.width, height: base.height)
        if d.resizing, let p = SB.layout.locate(d.key).map({ SBLayout.pack(SB.layout.pages[$0.page].items).placed.first { $0.item.key == d.key } }) ?? nil {
            r = SB.frame(p)
        }
        let k = HPMotion.reduceMotion ? 1 : d.lift.value(now)
        g.saveGState()
        g.translateBy(x: r.midX, y: r.midY); g.scaleBy(x: k, y: k); g.translateBy(x: -r.midX, y: -r.midY)
        g.setShadow(offset: CGSize(width: 0, height: 14), blur: 34, color: NSColor(white: 0, alpha: 0.35).cgColor)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        drawSBItem(g, d.item, r, now: now, glassApprox: true, badges: false, labels: false)
        g.endTransparencyLayer()
        g.restoreGState()
    }

    // MARK: 資料夾

    private func drawSBFolder(_ g: CGContext, _ now: Double) {
        guard let f = SB.folder, case .folder(let folder)? = SB.layout.item("f:\(f.id)") else { return }
        let t = max(0, min(1, f.anim.done(now) ? f.anim.to : f.anim.value(now)))
        // 後面：打開那一刻的主畫面，重度模糊（iOS 27）
        if let b = f.backdrop { g.saveGState(); g.setAlpha(t); drawUpright(g, b, in: SBUI.full); g.restoreGState() }
        else { g.setFillColor(NSColor(white: 0, alpha: 0.45 * t).cgColor); g.fill(SBUI.full) }
        let panel = HPMotion.reduceMotion ? SBUI.folderPanel : Shell.lerp(f.from, SBUI.folderPanel, t)
        let radius = 80 * (panel.width / SBUI.folderPanel.width)
        // 名字：大字靠左、面板上方（改名時加游標）
        let tf = HPType.sf(76, .bold)
        let name = f.renaming ? folder.name + (Int(now * 2) % 2 == 0 ? "|" : " ") : folder.name
        g.saveGState(); g.setAlpha(t)
        drawLeft(g, Face.clipped(name, tf, SBUI.folderTitle.width), font: tf, x: SBUI.folderTitle.minX, y: SBUI.folderTitle.maxY - 14, color: .white)
        if f.renaming {
            g.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor); g.fill(CGRect(x: SBUI.folderTitle.minX, y: SBUI.folderTitle.maxY, width: SBUI.folderTitle.width, height: 3))
        }
        g.restoreGState()
        let cells = SBUI.folderCells()
        let apps = Array(folder.apps.dropFirst(f.page * SBFolder.pageSize).prefix(SBFolder.pageSize))
        let dragging = SB.drag?.key
        let k = panel.width / SBUI.folderPanel.width
        HPGlass.add(continuousRoundedRect(panel, radius: radius), union: nil, presence: HPMotion.reduceMotion ? t : 1) { [weak self] c in
            guard let self else { return }
            c.saveGState(); c.setAlpha(min(1, t * 1.6))
            for (i, id) in apps.enumerated() where "a:\(id)" != dragging {
                var cell = cells[i]
                cell = CGRect(x: panel.minX + (cell.minX - SBUI.folderPanel.minX) * k, y: panel.minY + (cell.minY - SBUI.folderPanel.minY) * k, width: cell.width * k, height: cell.height * k)
                c.saveGState()
                if SB.editing, !HPMotion.reduceMotion { let a = self.sbWiggle("a:\(id)", i, cell, now); c.translateBy(x: cell.midX, y: cell.midY); c.rotate(by: a); c.translateBy(x: -cell.midX, y: -cell.midY) }
                self.drawSBItem(c, .app(id), cell, now: now, glassApprox: false, badges: SB.editing)
                c.restoreGState()
            }
            let pages = (folder.apps.count + SBFolder.pageSize - 1) / SBFolder.pageSize
            if pages > 1 {
                for i in 0..<pages {
                    c.setFillColor(NSColor.white.withAlphaComponent(i == f.page ? 0.95 : 0.4).cgColor)
                    c.fillEllipse(in: CGRect(x: panel.midX - CGFloat(pages - 1) * 15 + CGFloat(i) * 30 - 7, y: panel.maxY - 34, width: 14, height: 14))
                }
            }
            c.restoreGState()
        }
        HPGlass.flush(g, face: self, now: now)
    }

    // MARK: 選單

    private func drawSBMenu(_ g: CGContext, _ now: Double) {
        guard let m = SB.menu else { return }
        let t = HPMotion.reduceMotion ? 1 : max(0, min(1, m.presence.done(now) ? m.presence.to : m.presence.value(now)))
        g.setFillColor(NSColor(white: 0, alpha: 0.38 * t).cgColor); g.fill(SBUI.full)
        // 被長按的那一格浮在壓暗層上面（稍微放大）
        if let key = m.key, let it = SB.layout.item(key) {
            let s = 1 + 0.04 * t
            g.saveGState(); g.translateBy(x: m.anchor.midX, y: m.anchor.midY); g.scaleBy(x: s, y: s); g.translateBy(x: -m.anchor.midX, y: -m.anchor.midY)
            drawSBItem(g, it, m.anchor, now: now, glassApprox: true, badges: false, labels: false)
            g.restoreGState()
        } else if let id = m.appID, let app = AppRegistry.app(id) {
            Shell.drawHomeIcon(g, face: self, app: app, in: SBUI.libraryIcon(m.anchor))
        }
        let panel = m.panel
        let shown = HPMotion.reduceMotion ? panel : Shell.lerp(CGRect(x: panel.minX, y: panel.minY, width: panel.width * 0.6, height: panel.height * 0.4), panel, t)
        HPGlass.add(continuousRoundedRect(shown, radius: 64), union: nil, presence: t) { [weak self] c in
            guard let self, t > 0.6 else { return }
            c.saveGState(); c.setAlpha((t - 0.6) / 0.4)
            if !m.sizes.isEmpty {
                for (sz, r) in SBUI.menuSizeButtons(m) {
                    if sz == m.current { c.addPath(continuousRoundedRect(r, radius: 28)); c.setFillColor(NSColor(white: HPGlass.inkIsLight ? 1 : 0, alpha: 0.14).cgColor); c.fillPath() }
                    self.drawSBSizeGlyph(c, sz, in: r.insetBy(dx: 26, dy: 22), color: HPGlass.ink)
                }
                c.setFillColor(HPGlass.ink.withAlphaComponent(0.15).cgColor); c.fill(CGRect(x: panel.minX + 24, y: panel.minY + SBUI.menuSizes, width: panel.width - 48, height: 2))
            }
            let f = HPType.sf(40, .regular)
            for (row, r) in zip(m.rows, SBUI.menuRows(m)) {
                let col = row.destructive ? srgb(0xFF453A) : HPGlass.ink
                self.drawSymbol(c, row.symbol, in: CGRect(x: r.minX + 28, y: r.midY - 22, width: 44, height: 44), color: col)
                self.drawLeft(c, Face.clipped(row.title, f, r.width - 120), font: f, x: r.minX + 100, y: r.midY + f.capHeight / 2, color: col)
            }
            c.restoreGState()
        }
        HPGlass.flush(g, face: self, now: now)
    }

    /// 尺寸符號：照比例畫一個圓角框（寬 2×1、小 2×2、中 4×2、大 4×3）
    func drawSBSizeGlyph(_ g: CGContext, _ s: SBWidgetSize, in box: CGRect, color: NSColor) {
        let (w, h) = s.span
        let unit = min(box.width / 4, box.height / 3)
        let r = CGRect(x: box.midX - CGFloat(w) * unit / 2, y: box.midY - CGFloat(h) * unit / 2, width: CGFloat(w) * unit, height: CGFloat(h) * unit)
        g.saveGState(); g.addPath(continuousRoundedRect(r, radius: unit * 0.35)); g.setStrokeColor(color.cgColor); g.setLineWidth(4); g.strokePath(); g.restoreGState()
    }

    // MARK: sheet

    private func sheetBase(_ g: CGContext, _ card: CGRect, key: String) {
        g.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor); g.fill(SBUI.full)
        let radius = Screen.concentric(inset: card.minX)
        if !ShellGlass.draw(g, face: self, path: continuousRoundedRect(card, radius: radius), key: "\(key)|\(HomeAppearance.current.cacheKey)") {
            g.addPath(continuousRoundedRect(card, radius: radius)); g.setFillColor(srgb(0x2c2c30, 0.96).cgColor); g.fillPath()
        }
    }
    private func button(_ g: CGContext, _ r: CGRect, _ s: String, fill: NSColor = NSColor(white: 1, alpha: 0.16), color: NSColor = .white, symbol: String? = nil) {
        g.addPath(HPComponents.capsulePath(r)); g.setFillColor(fill.cgColor); g.fillPath()
        let f = HPType.fitted(s, size: 36, weight: .semibold, maxWidth: r.width - (symbol == nil ? 48 : 110))
        let w = Typo.width(s, f) + (symbol == nil ? 0 : 54)
        var x = r.midX - w / 2
        if let symbol { drawSymbol(g, symbol, in: CGRect(x: x, y: r.midY - 21, width: 42, height: 42), color: color); x += 54 }
        drawLeft(g, s, font: f, x: x, y: r.midY + f.capHeight / 2, color: color)
    }
    private func roundGlyph(_ g: CGContext, _ r: CGRect, _ symbol: String) {
        g.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor); g.fillEllipse(in: r)
        drawSymbol(g, symbol, in: r.insetBy(dx: 28, dy: 28), color: .white, weight: .bold)
    }
    private func centered(_ g: CGContext, _ s: String, _ f: NSFont, _ cx: CGFloat, _ y: CGFloat, _ c: NSColor, max: CGFloat = 860) {
        let t = Face.clipped(s, f, max)
        drawLeft(g, t, font: f, x: cx - Typo.width(t, f) / 2, y: y, color: c)
    }
    private func toggle(_ g: CGContext, _ r: CGRect, on: Bool) {
        let sw = CGRect(x: r.maxX - 150, y: r.midY - 32, width: 126, height: 64)
        g.addPath(HPComponents.capsulePath(sw)); g.setFillColor((on ? srgb(0x30D158) : NSColor(white: 1, alpha: 0.22)).cgColor); g.fillPath()
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: on ? sw.maxX - 60 : sw.minX + 4, y: sw.minY + 4, width: 56, height: 56))
    }

    private func drawSBSheet(_ g: CGContext, _ s: SBSheet, _ now: Double) {
        switch s {
        case .gallery(let kind, let stack, let page): drawSBGallery(g, kind: kind, stack: stack, page: page, now: now)
        case .config(let key): drawSBConfig(g, key, now)
        case .stackEdit(let key): drawSBStackEdit(g, key, now)
        case .customize: drawSBCustomize(g)
        case .editPages: drawSBEditPages(g, now)
        case .removeConfirm(let key): drawSBRemoveConfirm(g, key)
        }
    }

    private func drawSBGallery(_ g: CGContext, kind: SBWidgetKind?, stack: Bool, page: Int, now: Double) {
        let card = SBUI.sheetCard
        sheetBase(g, card, key: "sbgallery")
        roundGlyph(g, SBUI.sheetClose, "xmark")
        guard kind != nil || stack else {
            drawLeft(g, L("home.gallery.title", "小组件"), font: HPType.sf(56, .bold), x: card.minX + 56, y: card.minY + 104, color: .white)
            let nf = HPType.sf(32, .semibold)
            for (k, r) in SBUI.galleryEntries() {
                g.addPath(continuousRoundedRect(r, radius: 30)); g.setFillColor(NSColor(white: 1, alpha: 0.1).cgColor); g.fillPath()
                let ir = CGRect(x: r.minX + 16, y: r.midY - 36, width: 72, height: 72)
                if let k, let id = k.iconApp, let app = AppRegistry.app(id) { Shell.drawHomeIcon(g, face: self, app: app, in: ir) }
                else {
                    g.addPath(continuousRoundedRect(ir, radius: 16)); g.setFillColor((k?.accent ?? srgb(0x5E5CE6)).cgColor); g.fillPath()
                    drawSymbol(g, k?.symbol ?? "square.stack.3d.up.fill", in: ir.insetBy(dx: 16, dy: 16), color: .white)
                }
                let title = k?.title ?? L("sb.smartStack", "智能叠放")
                drawLeft(g, Face.clipped(title, nf, r.width - 112), font: nf, x: ir.maxX + 18, y: r.midY + nf.capHeight / 2, color: .white)
            }
            return
        }
        // 詳細頁：App 圖示＋名稱、標題＋說明、預覽、頁點、加入小工具
        roundGlyph(g, SBUI.galleryBack, "chevron.left")
        let sizes = SBUI.gallerySizes(kind: kind)
        let size = sizes[max(0, min(sizes.count - 1, page))]
        let title = kind?.title ?? L("sb.smartStack", "智能叠放")
        let blurb = kind?.blurb ?? L("sb.smartStack.blurb", "叠放几个小组件，上下滑动切换；智能旋转会在合适的时候显示合适的那个。")
        centered(g, title, HPType.sf(54, .bold), 512, card.minY + 104, .white, max: 640)
        let bf = HPType.sf(30, .regular)
        var y = card.minY + 170
        for line in Face.photosWrap(blurb, bf, 760, maxLines: 2) { centered(g, line, bf, 512, y, NSColor.white.withAlphaComponent(0.6)); y += 40 }
        let box = SBUI.galleryPreviewBox
        let real = SB.frame(col: 0, row: 0, span: size.span)
        let k = min(1, box.width / real.width, box.height / real.height) * 0.9
        g.saveGState()
        g.translateBy(x: box.midX, y: box.midY); g.scaleBy(x: k, y: k); g.translateBy(x: -real.width / 2, y: -real.height / 2)
        let r = CGRect(origin: .zero, size: real.size)
        if let kind {
            drawSBWidget(g, SBWidget(id: "preview", kind: kind, size: size), r, now: now, preview: true)
        } else {
            // Smart Stack：後面兩張卡露邊
            for (i, kk) in [SBWidgetKind.photos, .calendar].enumerated() where kk.sizes.contains(size) {
                let back = r.insetBy(dx: CGFloat(2 - i) * 22, dy: 0).offsetBy(dx: 0, dy: -CGFloat(2 - i) * 18)
                g.saveGState(); g.setAlpha(0.5); g.addPath(continuousRoundedRect(back, radius: Shell.widgetRadius)); g.setFillColor(NSColor(white: 1, alpha: 0.3).cgColor); g.fillPath(); g.restoreGState()
            }
            drawSBWidget(g, SBWidget(id: "preview", kind: .weather, size: size), r, now: now, preview: true)
        }
        g.restoreGState()
        let sf = HPType.sf(28, .medium)
        centered(g, String(format: L("sb.size.caption", "%@ · %d×%d"), size.title, size.span.w, size.span.h), sf, 512, box.maxY + 38, NSColor.white.withAlphaComponent(0.6))
        for (i, d) in SBUI.galleryDots(sizes.count).enumerated() {
            g.setFillColor(NSColor.white.withAlphaComponent(i == page ? 0.95 : 0.35).cgColor)
            g.fillEllipse(in: CGRect(x: d.midX - 9, y: d.midY - 9, width: 18, height: 18))
        }
        button(g, SBUI.galleryAdd, L("sb.addWidget", "添加小组件"), fill: kind?.accent ?? srgb(0x5E5CE6), symbol: "plus")
    }

    private func drawSBConfig(_ g: CGContext, _ key: String, _ now: Double) {
        guard case .widget(let w)? = SB.layout.item(key) else { return }
        let card = SBUI.configCard
        sheetBase(g, card, key: "sbconfig")
        centered(g, String(format: L("sb.editWidget.title", "编辑「%@」"), w.kind.title), HPType.sf(44, .bold), card.midX, card.minY + 84, .white, max: card.width - 80)
        // 小預覽
        let real = SB.frame(col: 0, row: 0, span: w.size.span)
        let k = min(200 / real.height, 520 / real.width)
        g.saveGState(); g.translateBy(x: card.midX - real.width * k / 2, y: card.minY + 116); g.scaleBy(x: k, y: k)
        drawSBWidget(g, w, CGRect(origin: .zero, size: real.size), now: now, preview: true)
        g.restoreGState()
        let opts = SBWidgetData.options(w.kind)
        if let o = opts.first {
            drawLeft(g, o.title, font: HPType.sf(30, .semibold), x: card.minX + 48, y: card.minY + 356, color: NSColor.white.withAlphaComponent(0.6))
            let cur = SBWidgetData.value(w, o.key), rf = HPType.sf(36, .regular)
            for (c, r) in zip(o.choices.prefix(5), SBUI.configRows(top: card.minY + 376, count: min(5, o.choices.count), rowH: 66)) {
                g.addPath(HPComponents.capsulePath(r)); g.setFillColor(NSColor(white: 1, alpha: c.id == cur ? 0.2 : 0.08).cgColor); g.fillPath()
                drawLeft(g, Face.clipped(c.title, rf, r.width - 120), font: rf, x: r.minX + 40, y: r.midY + rf.capHeight / 2, color: .white)
                if c.id == cur { drawSymbol(g, "checkmark", in: CGRect(x: r.maxX - 76, y: r.midY - 20, width: 40, height: 40), color: srgb(0x0A84FF), weight: .bold) }
            }
        }
        button(g, SBUI.configDone, L("home.done", "完成"))
    }

    private func drawSBStackEdit(_ g: CGContext, _ key: String, _ now: Double) {
        guard case .stack(let s)? = SB.layout.item(key) else { return }
        let card = SBUI.configCard
        sheetBase(g, card, key: "sbstack")
        centered(g, L("sb.editStack", "编辑叠放"), HPType.sf(44, .bold), card.midX, card.minY + 84, .white)
        let rows = SBUI.configRows(top: card.minY + 124, count: min(4, s.widgets.count), rowH: 92)
        let rf = HPType.sf(36, .regular)
        for (w, r) in zip(s.widgets, rows) {
            g.addPath(HPComponents.capsulePath(r)); g.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor); g.fillPath()
            let ir = CGRect(x: r.minX + 24, y: r.midY - 30, width: 60, height: 60)
            if let id = w.kind.iconApp, let app = AppRegistry.app(id) { Shell.drawHomeIcon(g, face: self, app: app, in: ir) }
            else { g.addPath(continuousRoundedRect(ir, radius: 14)); g.setFillColor(w.kind.accent.cgColor); g.fillPath(); drawSymbol(g, w.kind.symbol, in: ir.insetBy(dx: 14, dy: 14), color: .white) }
            drawLeft(g, Face.clipped(w.kind.title, rf, r.width - 220), font: rf, x: ir.maxX + 24, y: r.midY + rf.capHeight / 2, color: .white)
            let mr = CGRect(x: r.maxX - 88, y: r.midY - 30, width: 60, height: 60)
            g.setFillColor(srgb(0xFF453A).cgColor); g.fillEllipse(in: mr)
            g.setFillColor(NSColor.white.cgColor); g.fill(CGRect(x: mr.midX - 15, y: mr.midY - 3, width: 30, height: 6))
        }
        let t0 = (rows.last?.maxY ?? card.minY + 124) + 20
        for (i, (title, on)) in [(L("sb.smartRotate", "智能旋转"), s.smartRotate), (L("sb.suggestions", "小组件建议"), s.suggestions)].enumerated() {
            let r = SBUI.configRows(top: t0, count: 2, rowH: 92)[i]
            g.addPath(HPComponents.capsulePath(r)); g.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor); g.fillPath()
            drawLeft(g, title, font: rf, x: r.minX + 40, y: r.midY + rf.capHeight / 2, color: .white)
            toggle(g, r, on: on)
        }
        button(g, SBUI.configDone, L("home.done", "完成"))
    }

    private func drawSBCustomize(_ g: CGContext) {
        let card = SBUI.configCard
        sheetBase(g, card, key: "sbcustomize")
        centered(g, L("sb.customize", "自定"), HPType.sf(44, .bold), card.midX, card.minY + 84, .white)
        let cur = HomeAppearance.current, tf = HPType.sf(28, .semibold)
        for (a, r) in SBUI.customizeTiles() {
            g.addPath(continuousRoundedRect(r, radius: 36)); g.setFillColor(NSColor(white: 1, alpha: a == cur ? 0.24 : 0.08).cgColor); g.fillPath()
            if a == cur { g.addPath(continuousRoundedRect(r.insetBy(dx: -4, dy: -4), radius: 40)); g.setStrokeColor(srgb(0x0A84FF).cgColor); g.setLineWidth(5); g.strokePath() }
            drawSymbol(g, a.symbol, in: CGRect(x: r.midX - 36, y: r.minY + 36, width: 72, height: 72), color: .white)
            centered(g, a.title, tf, r.midX, r.maxY - 28, .white, max: r.width - 16)
        }
        let lr = SBUI.customizeLarge, rf = HPType.sf(36, .regular)
        g.addPath(HPComponents.capsulePath(lr)); g.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor); g.fillPath()
        drawLeft(g, L("sb.largeIcons", "大图标（隐藏名称）"), font: rf, x: lr.minX + 40, y: lr.midY + rf.capHeight / 2, color: .white)
        toggle(g, lr, on: SB.largeIcons)
        if cur == .tinted {
            let curHex = HomeAppearance.tintHex
            for (hex, r) in zip(SBUI.tintSwatches, SBUI.tintRects()) {
                g.setFillColor(srgb(hex).cgColor); g.fillEllipse(in: r)
                if curHex == hex { g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(6); g.strokeEllipse(in: r.insetBy(dx: -8, dy: -8)) }
            }
        }
        button(g, SBUI.configDone, L("home.done", "完成"))
    }

    private func drawSBEditPages(_ g: CGContext, _ now: Double) {
        g.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor); g.fill(SBUI.full)
        let l = SB.layout
        let thumbs = SBUI.pageThumbs(l.pages.count)
        let (bg, _) = sbBackdrop()
        for (pi, r) in thumbs.enumerated() {
            let img = sbThumb(pi, bg)
            g.saveGState()
            g.addPath(continuousRoundedRect(r, radius: r.width * 0.13)); g.clip()
            g.setAlpha(l.pages[pi].hidden ? 0.45 : 1)
            drawUpright(g, img, in: r)
            g.restoreGState()
            g.addPath(continuousRoundedRect(r, radius: r.width * 0.13)); g.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor); g.setLineWidth(2); g.strokePath()
            let c = SBUI.pageCheck(r)
            if l.pages[pi].hidden {
                g.setStrokeColor(NSColor(white: 1, alpha: 0.8).cgColor); g.setLineWidth(4); g.strokeEllipse(in: c.insetBy(dx: 2, dy: 2))
                if l.pages.count > 1 { sbBadge(g, SBUI.badge(r, icon: false)) }
            } else {
                g.setFillColor(srgb(0x0A84FF).cgColor); g.fillEllipse(in: c)
                drawSymbol(g, "checkmark", in: c.insetBy(dx: 18, dy: 18), color: .white, weight: .bold)
            }
        }
        let d = SBUI.doneButton
        HPGlass.addCapsule(d, interactive: true) { [weak self] c in
            self?.drawSymbol(c, "checkmark", in: CGRect(x: d.midX - 22, y: d.midY - 22, width: 44, height: 44), color: HPGlass.ink, weight: .bold)
        }
        HPGlass.flush(g, face: self, now: now)
    }
    /// 編輯頁面的縮圖：桌布＋這一頁的項目（小工具用示範內容畫，不另外讀資料）
    private func sbThumb(_ pi: Int, _ bg: CGImage) -> CGImage {
        let key = "sbthumb|\(pi)|\(SB.layout.pages[pi].items.compactMap(\.key).joined(separator: ","))|\(HomeAppearance.current.cacheKey)"
        if let c = SB.pageCache[key] { return c }
        let px = 340
        let img = makeImage(px, px) { g in
            g.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
            drawUpright(g, bg, in: SBUI.full)
            for p in SB.placements(page: pi) { drawSBItem(g, p.item, SB.frame(p), now: CACurrentMediaTime(), glassApprox: true, badges: false) }
        }
        SB.pageCache[key] = img
        return img
    }

    private func drawSBRemoveConfirm(_ g: CGContext, _ key: String) {
        g.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor); g.fill(SBUI.full)
        let card = SBUI.alertCard
        if !ShellGlass.draw(g, face: self, path: continuousRoundedRect(card, radius: 72), key: "sbalert") {
            g.addPath(continuousRoundedRect(card, radius: 72)); g.setFillColor(srgb(0x212121, 0.97).cgColor); g.fillPath()
        }
        let name = SBUI.itemName(key)
        let isApp = key.hasPrefix("a:")
        let title = String(format: isApp ? L("sb.remove.appTitle", "要移除「%@」吗？") : L("sb.remove.widgetTitle", "要移除「%@」吗？"), name)
        drawLeft(g, Face.clipped(title, HPType.sf(40, .semibold), card.width - 72), font: HPType.sf(40, .semibold), x: card.minX + 40, y: card.minY + 76, color: .white)
        let body = isApp ? L("sb.remove.appBody", "从主屏幕移除后，App 仍在 App 资源库里。") : (key.hasPrefix("f:") ? L("sb.remove.folderBody", "文件夹里的 App 会移到 App 资源库。") : L("sb.remove.widgetBody", "移除这个小组件不会删除任何数据。"))
        let bf = HPType.sf(30, .regular)
        var y = card.minY + 128
        for line in Face.photosWrap(body, bf, card.width - 80, maxLines: 2) { drawLeft(g, line, font: bf, x: card.minX + 40, y: y, color: NSColor.white.withAlphaComponent(0.6)); y += 40 }
        let b = SBUI.alertButtons
        button(g, b[0], isApp ? L("sb.remove.fromHome", "从主屏幕移除") : L("sb.remove.confirm", "移除"), fill: NSColor(white: 1, alpha: 0.14), color: srgb(0xFF453A))
        button(g, b[1], L("sb.cancel", "取消"), fill: NSColor(white: 1, alpha: 0.14))
    }

    // MARK: App 資料庫

    private func drawSBLibrary(_ g: CGContext, _ now: Double) {
        let s = SBUI.librarySearch
        let q = SB.libraryQuery
        HPGlass.addCapsule(s, interactive: true) { [weak self] c in
            guard let self else { return }
            self.drawSymbol(c, "magnifyingglass", in: CGRect(x: s.minX + 30, y: s.midY - 18, width: 36, height: 36), color: HPGlass.ink.withAlphaComponent(0.7))
            let f = HPType.sf(36, .regular)
            let caret = SB.librarySearching && Int(now * 2) % 2 == 0 ? "|" : ""
            let text = q.isEmpty && !SB.librarySearching ? L("sb.library", "App 资源库") : q + caret
            self.drawLeft(c, Face.clipped(text, f, s.width - 120), font: f, x: s.minX + 84, y: s.midY + f.capHeight / 2, color: q.isEmpty && !SB.librarySearching ? HPGlass.ink.withAlphaComponent(0.6) : HPGlass.ink)
        }
        drawShellAvatar(g)
        let apps = SBUI.libraryApps()
        let lf = HPType.sf(HPType.Size.iconLabel, HPTokens.Home.iconLabelWeight)
        if apps.isEmpty {
            let f = HPType.sf(40, .semibold)
            centered(g, L("sb.library.none", "没有结果"), f, 512, 420, NSColor.white.withAlphaComponent(0.7))
        }
        // 2.0 depth：內容放不下就捲（拖、滾輪、觸控板）；搜尋欄底下裁掉，右緣一條暫態指示器（iOS 的資料庫捲動時有）
        let off = SB.libraryScrollNow
        let clipTop = SBUI.libraryTop - 32
        let scrollable = SB.libraryMaxScroll > 0.5
        g.saveGState()
        if scrollable {
            g.clip(to: CGRect(x: 0, y: clipTop, width: 1024, height: 1024 - clipTop))
            g.translateBy(x: 0, y: -off)
        }
        for (app, cell) in zip(apps, SBUI.libraryCells(apps.count)) {
            let ir = SBUI.libraryIcon(cell)
            Shell.drawHomeIcon(g, face: self, app: app, in: ir)
            let t = Face.clipped(app.title, lf, cell.width + Shell.colGap - 6)
            drawLeft(g, t, font: lf, x: ir.midX - Typo.width(t, lf) / 2, y: ir.maxY + 44, color: .white)
        }
        g.restoreGState()
        if scrollable, SB.libraryScrollDragging || !SB.libraryScroll.done(now) {
            let trackH = 1024 - clipTop
            let h = max(120, trackH * trackH / (trackH + SB.libraryMaxScroll))
            let k = max(0, min(1, off / SB.libraryMaxScroll))
            let bar = CGRect(x: 1000, y: clipTop + k * (trackH - h), width: 8, height: h)
            g.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
            g.addPath(CGPath(roundedRect: bar, cornerWidth: 4, cornerHeight: 4, transform: nil)); g.fillPath()
        }
        if SB.menu != nil { HPGlass.flush(g, face: self, now: now); drawSBMenu(g, now) }
    }
}

extension SBUI {
    static func itemName(_ key: String) -> String {
        switch SB.layout.item(key) {
        case .app(let id)?: return AppRegistry.app(id)?.title ?? id
        case .folder(let f)?: return f.name
        case .widget(let w)?: return w.title
        case .stack?: return L("sb.smartStack", "智能叠放")
        default: return ""
        }
    }
}
