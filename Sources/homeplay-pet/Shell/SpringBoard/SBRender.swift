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
        let d = HPTokens.Size.badge   // 2.0 align F：56 → badge 48（命中照舊外擴 16）
        return CGRect(x: ir.minX - d * 0.3, y: ir.minY - d * 0.3, width: d, height: d)
    }
    /// 「−」的點按範圍：徽標 48 四周補到 Size.tap 88
    static func badgeHit(_ item: CGRect, icon: Bool) -> CGRect {
        let k = (HPTokens.Size.tap - HPTokens.Size.badge) / 2
        return badge(item, icon: icon).insetBy(dx: -k, dy: -k)
    }
    /// 小工具右下的改大小把手（點按範圍 88）
    static func resizeHandle(_ r: CGRect) -> CGRect { CGRect(x: r.maxX - 66, y: r.maxY - 66, width: 88, height: 88) }
    static let dotsY: CGFloat = 976
    /// 頁點的格數：頁＋資源庫圖示（編輯模式沒有資源庫）
    static var dotSlots: Int { SB.pageSlots }
    /// 第 i 格的中心（頁點間距 30）
    static func dotCenter(_ i: Int, of n: Int) -> CGPoint { CGPoint(x: dotsCapsule(n).minX + 30 + CGFloat(i) * 30, y: dotsY) }
    /// 資源庫圖示的點按範圍（輔助使用的框）：88×88（44 pt 等效）
    static var libraryDotHit: CGRect {
        let c = dotCenter(SB.librarySlot, of: dotSlots)
        return CGRect(x: c.x - 44, y: dotsY - 44, width: 88, height: 88)
    }
    /// 平常點頁點（照 UIPageControl）：點資源庫圖示＝去資源庫；點在目前那一點左邊／右邊＝往前／往後一頁。範圍至少 88 高、左右各多 30
    static func dotsTap(_ p: CGPoint) -> Int? {
        guard !SB.editing else { return nil }
        let n = dotSlots
        // 資源庫圖示：88 高；左邊界在它跟最後一點的中間（不搶最後一頁那一點）。在最後一頁時，點右邊本來就是資源庫
        if SB.libraryReachable, libraryDotHit.contains(p), p.x > dotCenter(SB.librarySlot, of: n).x - 15 { return SB.librarySlot }
        let cap = dotsCapsule(n), area = CGRect(x: cap.minX - 30, y: dotsY - 44, width: cap.width + 60, height: 88)
        guard area.contains(p) else { return nil }
        let cur = dotCenter(SB.page, of: n).x
        if abs(p.x - cur) < 8 { return nil }
        return SB.page + (p.x > cur ? 1 : -1)
    }
    static func dotsCapsule(_ n: Int) -> CGRect {
        let w = CGFloat(n) * 30 + 44
        return CGRect(x: 512 - w / 2, y: dotsY - 30, width: w, height: 60)
    }

    // 資料夾（3×3）：標題與格子同一條內縮（48），上下留白同為 24
    static let folderPanel = CGRect(x: 182, y: 292, width: 660, height: 660)
    static let folderInset: CGFloat = 48
    static func folderCells() -> [CGRect] {
        let pitchX: CGFloat = 206, pitchY: CGFloat = 206
        let x0 = folderPanel.minX + folderInset, y0 = folderPanel.minY + HPGrid.Rhythm.groupGap
        return (0..<9).map { CGRect(x: x0 + CGFloat($0 % 3) * pitchX, y: y0 + CGFloat($0 / 3) * pitchY, width: 152, height: 200) }
    }
    static var folderTitle: CGRect { CGRect(x: folderPanel.minX + folderInset, y: folderPanel.minY - 120, width: folderPanel.width - folderInset * 2, height: 96) }

    // 選單
    // 10-grid：夾在螢幕內的邊距用 48（HPGrid.scale）；沒夾到時左緣對齊錨點（selftest 有驗）
    // 2.0 align：一條左緣（menu 12）、一種行高（row 88）、行間 8；尺寸塊與清單列同高。
    static let menuWidth: CGFloat = 620
    static let menuRow: CGFloat = HPTokens.Size.row
    static let menuSizes: CGFloat = HPTokens.Size.row
    static let menuRowGap: CGFloat = HPGrid.Rhythm.rowGap
    static let menuInset: CGFloat = HPGrid.Inset.menu
    static let menuDividerGap: CGFloat = 12
    /// 尺寸塊＋分隔線＋上下留白佔掉的高度（沒有尺寸塊時是 0）
    static var menuSizeBlock: CGFloat { menuSizes + menuDividerGap * 2 + 2 }
    static func menuPanel(anchor: CGRect, rows: Int, sizes: Bool) -> CGRect {
        let n = CGFloat(rows)
        let h = menuInset * 2 + (sizes ? menuSizeBlock : 0) + n * menuRow + max(0, n - 1) * menuRowGap
        var x = anchor.minX
        if x + menuWidth > 976 { x = anchor.maxX - menuWidth }
        x = max(48, min(976 - menuWidth, x))
        var y = anchor.maxY + 22
        // 下緣留 30（selftest 要求整個面板在 30 內縮的畫面裡；原本用 1000 會差 5 單位）
        if y + h > 994 { y = anchor.minY - 22 - h }
        if y < 48 { y = max(48, (1024 - h) / 2) }
        return CGRect(x: x, y: y, width: menuWidth, height: h)
    }
    static func menuRows(_ m: SBMenu) -> [CGRect] {
        let top = m.panel.minY + menuInset + (m.sizes.isEmpty ? 0 : menuSizeBlock)
        return m.rows.indices.map {
            CGRect(x: m.panel.minX + menuInset, y: top + CGFloat($0) * (menuRow + menuRowGap),
                   width: m.panel.width - menuInset * 2, height: menuRow)
        }
    }
    static func menuSizeButtons(_ m: SBMenu) -> [(SBWidgetSize, CGRect)] {
        let n = CGFloat(m.sizes.count)
        let gap = menuInset, w: CGFloat = 140
        let total = n * w + max(0, n - 1) * gap
        let x0 = m.panel.midX - total / 2
        return m.sizes.enumerated().map {
            ($0.element, CGRect(x: x0 + CGFloat($0.offset) * (w + gap), y: m.panel.minY + menuInset, width: w, height: menuSizes))
        }
    }

    // sheet（對齊：一條內縮 40、一組 topBar 圓鈕、標題字心＝圓鈕中心）
    static let sheetInset: CGFloat = HPGrid.Inset.card
    static let sheetCard = CGRect(x: 40, y: 104, width: 944, height: 880)
    /// 卡片內容邊線：標題、清單、預覽、主按鈕全部對這條
    static var sheetContent: CGRect { sheetCard.insetBy(dx: sheetInset, dy: sheetInset) }
    static var sheetTopBar: CGFloat { sheetCard.minY + sheetInset }
    static var sheetClose: CGRect { CGRect(x: sheetCard.maxX - sheetInset - HPTokens.Size.topBar, y: sheetTopBar,
                                          width: HPTokens.Size.topBar, height: HPTokens.Size.topBar) }
    static var galleryBack: CGRect { CGRect(x: sheetCard.minX + sheetInset, y: sheetTopBar,
                                           width: HPTokens.Size.topBar, height: HPTokens.Size.topBar) }
    /// 標題基線：字心對圓鈕中心（56 bold 的 cap 高約 39.5）
    static var sheetTitleBaseline: CGFloat { sheetTopBar + HPTokens.Size.topBar / 2 + 19.75 }
    static func galleryEntries() -> [(SBWidgetKind?, CGRect)] {
        let entries: [SBWidgetKind?] = [nil] + SBWidgetKind.allCases.filter { $0 != .webApp }.map { $0 }   // Web App 的小工具從它的圖示長按加
        let c = sheetContent, gap = HPGrid.Rhythm.groupGap
        let colW = (c.width - gap * 2) / 3
        var out: [(SBWidgetKind?, CGRect)] = []
        for (i, e) in entries.enumerated() {
            let x = c.minX + CGFloat(i % 3) * (colW + gap)
            let y = c.minY + 120 + CGFloat(i / 3) * (112 + HPGrid.Rhythm.rowGap)
            out.append((e, CGRect(x: x, y: y, width: colW, height: 112)))
        }
        return out
    }
    static var galleryPreviewBox: CGRect { CGRect(x: sheetContent.minX, y: sheetCard.minY + 236,
                                                  width: sheetContent.width, height: 360) }
    static var galleryAdd: CGRect { CGRect(x: sheetContent.minX, y: sheetContent.maxY - HPTokens.Size.cta,
                                           width: sheetContent.width, height: HPTokens.Size.cta) }
    static func galleryDots(_ n: Int) -> [CGRect] {
        let pitch: CGFloat = 44, x0 = 512 - CGFloat(n - 1) * pitch / 2
        let y = galleryAdd.minY - 48
        return (0..<n).map { CGRect(x: x0 + CGFloat($0) * pitch - 22, y: y - HPTokens.Size.tap / 2, width: 44, height: HPTokens.Size.tap) }
    }
    static func gallerySizes(kind: SBWidgetKind?) -> [SBWidgetSize] { kind?.sizes ?? [.small, .medium, .large] }

    // 設定卡（對齊：內縮 40、選項行 72、主按鈕滿內容寬）
    static let configCard = CGRect(x: 96, y: 96, width: 832, height: 888)
    static var configContent: CGRect { configCard.insetBy(dx: sheetInset, dy: sheetInset) }
    static var configDone: CGRect { CGRect(x: configContent.minX, y: configCard.maxY - sheetInset - HPTokens.Size.cta,
                                           width: configContent.width, height: HPTokens.Size.cta) }
    static func configRows(top: CGFloat, count: Int, rowH: CGFloat = HPTokens.Size.rowCompact) -> [CGRect] {
        (0..<count).map {
            CGRect(x: configContent.minX, y: top + CGFloat($0) * (rowH + HPGrid.Rhythm.rowGap),
                   width: configContent.width, height: rowH)
        }
    }
    /// Edit Widget 的選項列（繪製與命中共用；以前兩邊各寫一份，改一個就會錯位）
    static func configOptionRows(_ count: Int) -> [CGRect] { configRows(top: configCard.minY + 328, count: count) }
    /// 編輯疊放：清單列
    static func stackRows(_ count: Int) -> [CGRect] { configRows(top: configCard.minY + 124, count: count) }
    /// 編輯疊放：下面兩個開關列
    static func stackToggleRows(_ rows: [CGRect]) -> [CGRect] {
        let t0 = (rows.last?.maxY ?? configCard.minY + 124) + HPGrid.Rhythm.groupGap
        return configRows(top: t0, count: 2)
    }
    static func customizeTiles() -> [(HomeAppearance, CGRect)] {
        let w: CGFloat = 170, gap = HPGrid.Rhythm.groupGap
        return HomeAppearance.allCases.enumerated().map { ($0.element, CGRect(x: configContent.minX + CGFloat($0.offset) * (w + gap), y: configCard.minY + 150, width: w, height: 190)) }
    }
    static var customizeLarge: CGRect { CGRect(x: configContent.minX, y: configCard.minY + 380, width: configContent.width, height: HPTokens.Size.row) }
    static let tintSwatches: [UInt32] = [0x0A84FF, 0x30D158, 0xFF9F0A, 0xFF375F, 0xBF5AF2, 0x8E8E93]
    static func tintRects() -> [CGRect] {
        // 6 顆鋪滿內容寬：6×92 + 5×40 = 752
        let d: CGFloat = 92, gap: CGFloat = 40, x0 = configContent.minX
        return tintSwatches.indices.map { CGRect(x: x0 + CGFloat($0) * (d + gap), y: configCard.minY + 510, width: d, height: d) }
    }

    // 提示卡（移除確認）：標題、正文、按鈕同一條內縮 40
    static let alertCard = CGRect(x: 172, y: 300, width: 680, height: 460)
    static var alertContent: CGRect { alertCard.insetBy(dx: sheetInset, dy: sheetInset) }
    static var alertButtons: [CGRect] {
        let b = CGRect(x: alertContent.minX, y: alertCard.maxY - sheetInset - HPTokens.Size.cta,
                       width: alertContent.width, height: HPTokens.Size.cta)
        let a = b.offsetBy(dx: 0, dy: -(HPTokens.Size.cta + HPGrid.Rhythm.rowGap * 2))
        return [a, b]
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
    /// 分區：HomePlay 的 App 照名字一區；iPhone App（有掃到、設定沒關）另一區「iPhone」，也照名字（照 Mac 的 App 瀏覽／Spotlight）。
    /// 沒有 iPhone App 就沒有那一區（不留空殼）
    static func librarySections(_ apps: [PetApp]) -> [(title: String?, apps: [PetApp])] {
        let sorted = apps.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let own = sorted.filter { !($0 is PhoneCarPlayApp) }, phone = sorted.filter { $0 is PhoneCarPlayApp }
        var out: [(title: String?, apps: [PetApp])] = []
        if !own.isEmpty { out.append((nil, own)) }
        if !phone.isEmpty { out.append((L("sb.library.iphone", "iPhone"), phone)) }
        return out
    }
    private static func libraryHits() -> [PetApp] {
        let q = SB.libraryQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let all = AppRegistry.visible
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || $0.id.contains(q) }
    }
    /// 資源庫（含搜尋結果）照分區的順序
    static func libraryApps() -> [PetApp] { librarySections(libraryHits()).flatMap(\.apps) }
    /// 分區標題那一列的高度（標題字＋底下的空氣）
    static let librarySectionHeader: CGFloat = 76
    /// 跟 libraryApps() 一一對應的格子，加上分區標題的位置（y＝那一列的上緣；搜尋結果也分區＝iPhone App 標著「iPhone」）
    static func libraryLayout() -> (cells: [CGRect], headers: [(title: String, y: CGFloat)]) {
        var cells: [CGRect] = [], headers: [(title: String, y: CGFloat)] = []
        var top = libraryTop
        for sec in librarySections(libraryHits()) {
            if let t = sec.title { headers.append((t, top)); top += librarySectionHeader }
            for i in sec.apps.indices {
                cells.append(CGRect(x: HPTokens.Home.gridMargin + CGFloat(i % 4) * HPTokens.Home.columnPitch, y: top + CGFloat(i / 4) * libraryRowPitch,
                                    width: HPTokens.Home.iconSide, height: libraryRowHeight))
            }
            top += CGFloat((sec.apps.count + 3) / 4) * libraryRowPitch
        }
        return (cells, headers)
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
        case .desktopWidgets: return srgb(0x8E8E93)
        }
    }
}

extension Face {
    // MARK: 入口（HomeScreen.drawHome 第一行叫）

    func drawSpringBoard(_ g: CGContext, _ now: Double, library: Bool) {
        HPIconPress.applySnapshotPress()
        if Shell.homeLayer == nil { SB.pageCache.removeAll() }   // 外觀、圖示、排列換了（各處照舊把 homeLayer 清掉）
        let bg = sbBackdrop()
        Shell.homeLayer = ("sb", bg)
        drawUpright(g, bg, in: SBUI.full)
        SB.settleLibrarySlot()
        if library, SB.page != SB.librarySlot { drawSBLibrary(g, now); return }   // ↑／底緣上滑進來的：整頁
        // App 資源庫＝最後一頁再往後一格：k＝往資源庫翻了多少（0＝最後一頁，1＝資源庫，>1＝再往右的橡皮筋）
        let n = CGFloat(SB.visiblePages.count), pos = SB.pagePosition(now)
        let k = SB.libraryReachable ? max(0, pos - (n - 1)) : 0
        let reduce = HPMotion.reduceMotion   // 減少動態效果：不滑，交叉淡化（跟換頁一樣）
        if abs(k - 1) < 0.0005, !SB.pageDragging { drawSBLibrary(g, now); return }   // 停在資源庫
        let pagesHidden = SB.sheet == .editPages   // 編輯頁面：後面只留桌布（iOS 27）
        if !pagesHidden {
            let kk = min(1, k)
            if kk < 1 {
                drawSBTopBar(g, now, dx: reduce ? 0 : -kk * 1024, alpha: reduce ? 1 - kk : 1)
                drawSBPages(g, now)
                drawSBDots(g, now, alpha: 1 - kk)
            }
            if k > 0 { drawSBLibrary(g, now, dx: reduce ? 0 : (1 - k) * 1024, alpha: reduce ? kk : 1) }
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

    /// 桌布＋面板（玻璃）一張。
    /// 2.0 glass：清透／染色的圖示與小工具**不再**上玻璃（內容層不上 Liquid Glass——
    /// 官方那層是系統替圖示做的 accented 版本；這裡直接畫 HomeIconVariant 的結果，見 HomeAppearance）。
    private func sbBackdrop() -> CGImage {
        let wall = shellWallpaper()
        let sc = renderPixelScale, look = HomeAppearance.current
        let key = "sbbg|\(ObjectIdentifier(wall).hashValue)|\(Int(sc * 100))|\(look.cacheKey)|a11y\(HPAccessibility.generation)"
        if let c = SB.pageCache[key] { return c }
        let px = Int((1024 * sc).rounded())
        let img = makeImage(px, px) { g in
            g.scaleBy(x: sc, y: sc)
            let full = SBUI.full
            drawUpright(g, wall, in: full)
            if look.wallpaperShade > 0 { g.setFillColor(NSColor(white: 0, alpha: look.wallpaperShade).cgColor); g.fill(full) }
            // 減少透明度：內容層的面板不是控制，沒有「不透明版」可換——直接不畫，壁紙原樣留著。
            // 換成淺色不透明面板的話，恆白的圖示標籤會壓在 #F2F2F7 上（約 1.6:1）。
            if !HPGlass.reduceTransparency {
                let inset = HPTokens.Home.panelInset
                let panelPath = continuousRoundedRect(full.insetBy(dx: inset, dy: inset), radius: Screen.concentric(inset: inset))
                HPGlass.add(panelPath) { _ in }
                HPGlass.flush(g, face: self, clear: true)
                g.saveGState(); g.addPath(panelPath); g.setFillColor(NSColor(white: 0, alpha: HPTokens.Home.panelShade).cgColor); g.fillPath(); g.restoreGState()
                HPGlass.panelRim(g, panelPath)
            }
        }
        if SB.pageCache.count > 40 { SB.pageCache.removeAll() }
        SB.pageCache[key] = img
        return img
    }

    // MARK: 頂端：問候語＋頭像；編輯模式＝筆刷膠囊＋ ✓

    private func drawSBTopBar(_ g: CGContext, _ now: Double, dx: CGFloat = 0, alpha: CGFloat = 1) {
        guard SB.editing else {
            let H = HPTokens.Home.self
            let sx = Shell.iconRect(in: Shell.cell(0, 0)).minX + H.greetingInset + dx   // 翻向資源庫時問候語、頭像跟著這一頁滑走（資源庫那頁有自己的頭像）
            g.saveGState(); defer { g.restoreGState() }
            g.setAlpha(alpha)
            for (i, line) in Shell.greeting(hour: Shell.greetingHour(self)).enumerated() {
                let isName = i > 0
                let sf = HPType.sf(H.greetingSize, isName ? H.nameWeight : H.greetingWeight)
                drawLeft(g, Face.clipped(line, sf, 660), font: sf, x: sx, y: H.greetingBaseline + CGFloat(i) * H.greetingLeading,
                         color: NSColor.white.withAlphaComponent((isName ? H.nameAlpha : H.greetingAlpha) * LiveActivityStack.greetingAlpha(now)), kern: H.greetingKern)
            }
            g.translateBy(x: dx, y: 0); drawShellAvatar(g)
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

    private func drawSBPages(_ g: CGContext, _ now: Double) {
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
                drawSBPage(g, vis[vi], now: now, current: vi == SB.page)
                g.restoreGState()
            }
        }
        g.restoreGState()
    }

    /// 一頁：靜止（沒在編輯、沒有讓位動畫）用整張快取；不然逐項畫
    private func drawSBPage(_ g: CGContext, _ pi: Int, now: Double, current: Bool) {
        let items = SB.displayItems(page: pi)
        let placed = SBLayout.pack(items).placed.filter { !$0.item.isSpacer }
        let live = SB.editing || SB.drag != nil || SB.pressedKey != nil || HPIconPress.animating(now) || (current && SB.anims.values.contains { !$0.x.done(now) || !$0.y.done(now) }) || !SB.fades.isEmpty
        // P0 圖示玻璃：版面沒在動（只是按著）就照用整頁一次合成的玻璃底；編輯、拖曳、讓位時退回平面變體
        if !SB.editing, SB.drag == nil, !(current && SB.anims.values.contains { !$0.x.done(now) || !$0.y.done(now) }), let glass = sbIconGlassLayer(pi, placed) {
            if let pr = sbPressedIconGlass(placed, now: now) {
                // 按著的那一格：整頁快取挖掉那一格，單獨重畫它的玻璃底、跟著縮（不然圖示縮了、底沒縮，看得出一圈縫）
                let base = continuousRoundedRect(pr.icon.insetBy(dx: -2, dy: -2), radius: (pr.icon.width + 4) * 0.2237)
                g.saveGState(); g.addRect(SBUI.full); g.addPath(base); g.clip(using: .evenOdd)
                drawUpright(g, glass, in: SBUI.full)
                g.restoreGState()
                HPGlass.drawNow(g, face: self, [continuousRoundedRect(pr.scaled, radius: pr.scaled.width * 0.2237)], clear: true,
                                tint: HomeAppearance.current == .tinted ? HomeAppearance.tintColor : nil)
                HPIconGlass.shade(g, [pr.scaled])
            } else {
                drawUpright(g, glass, in: SBUI.full)
            }
        }
        if !live {
            drawUpright(g, sbPageImage(pi, placed), in: SBUI.full)
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
            let press = SB.editing ? HPIconPress.Look() : HPIconPress.look(for: key, now: now)   // 體驗追趕 P2：按著的縮、周圍退後
            g.saveGState()
            g.setAlpha(alpha * press.alpha)
            if angle != 0 { g.translateBy(x: r.midX, y: r.midY); g.rotate(by: angle); g.translateBy(x: -r.midX, y: -r.midY) }
            if press.scale != 1 { let c = p.item.isIcon ? SB.iconRect(in: r) : r; g.translateBy(x: c.midX, y: c.midY); g.scaleBy(x: press.scale, y: press.scale); g.translateBy(x: -c.midX, y: -c.midY) }
            if let d = SB.drag, d.folderReady, d.folderTarget == key { sbFolderHover(g, r) }
            drawSBItem(g, p.item, r, now: now, badges: SB.editing)
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
    func sbWiggle(_ key: String, _ i: Int, _ r: CGRect, _ now: Double) -> CGFloat {
        let phase = (i % 2 == 0 ? 0 : Double.pi) + Double(abs(key.hashValue % 7)) * 0.11
        let t = (now - SB.editSince) / SBMotion.wigglePeriod * 2 * .pi + phase
        let amp = SBMotion.wiggleDegrees * .pi / 180 * min(1, 180 / max(r.width, r.height))
        return amp * CGFloat(sin(t))
    }

    /// 靜止的一頁（圖示、標籤、資料夾圖示）；小工具的內容每幀另外畫。
    /// 2.0 glass：清透／染色的圖示底是 HomeIconVariant 的 accented 圖，不再墊一層 Liquid Glass。
    private func sbPageImage(_ pi: Int, _ placed: [SBPlacement]) -> CGImage {
        let sc = renderPixelScale, look = HomeAppearance.current
        let fp = placed.map { "\($0.item.key ?? "")@\($0.col),\($0.row)" }.joined(separator: ";")
        let folders = placed.compactMap { if case .folder(let f) = $0.item { return f.apps.joined(separator: ",") + f.name }; return nil }.joined(separator: "|")
        let key = "sbpage|\(pi)|\(fp)|\(folders)|\(look.cacheKey)|\(Int(sc * 100))|\(Typo.language)|\(Shell.homeDayKey(Face.displayDate))|\(SB.largeIcons)"
        if let c = SB.pageCache[key] { return c }
        let px = Int((1024 * sc).rounded())
        let img = makeImage(px, px) { g in
            g.scaleBy(x: sc, y: sc)
            for p in placed { drawSBItem(g, p.item, SB.frame(p), now: CACurrentMediaTime(), badges: false, content: false) }
        }
        if SB.pageCache.count > 40 { SB.pageCache.removeAll() }
        SB.pageCache[key] = img
        return img
    }

    /// 按壓的縫：正在按、而且按的是這頁的 App 圖示、而且有縮放（減少動態效果的 crossfade 不縮放＝照用快取）
    private func sbPressedIconGlass(_ placed: [SBPlacement], now: Double) -> (icon: CGRect, scaled: CGRect)? {
        guard let k = HPIconPress.key, let p = placed.first(where: { $0.item.key == k }), case .app = p.item else { return nil }
        let look = HPIconPress.look(for: k, now: now)
        guard look.scale < 0.999 else { return nil }
        let ir = SB.iconRect(in: SB.frame(p)), s = look.scale
        return (ir, CGRect(x: ir.midX - ir.width * s / 2, y: ir.midY - ir.height * s / 2, width: ir.width * s, height: ir.height * s))
    }

    /// P0 圖示玻璃：這一頁所有 App 圖示的底（Clear 玻璃＋深淺薄層），取樣桌布＋面板；一頁一次合成、快取
    private func sbIconGlassLayer(_ pi: Int, _ placed: [SBPlacement]) -> CGImage? {
        guard HPIconGlass.enabled else { return nil }
        let icons = placed.compactMap { p -> CGRect? in if case .app = p.item { return SB.iconRect(in: SB.frame(p)) }; return nil }
        guard !icons.isEmpty else { return nil }
        let bg = sbBackdrop()
        let sc = renderPixelScale, look = HomeAppearance.current, prm = HPIconGlass.current
        let fp = icons.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))" }.joined(separator: ";")
        let key = "sbglass|\(fp)|\(ObjectIdentifier(bg).hashValue)|\(look.cacheKey)|\(Int(sc * 100))|\(prm.baseGray),\(prm.baseAlpha)"
        if let c = SB.pageCache[key] { return c }
        let px = Int((1024 * sc).rounded())
        // 玻璃要在真的桌布上合成（對著透明畫布算只會得到一塊灰）：先畫桌布＋玻璃，再只裁出圖示（外擴一點留住亮緣）
        let composed = makeImage(px, px) { g in
            g.scaleBy(x: sc, y: sc)
            drawUpright(g, bg, in: SBUI.full)
            HPIconGlass.addBases(icons, tint: look == .tinted ? HomeAppearance.tintColor : nil)
            HPGlass.flush(g, face: self, clear: true)
            HPIconGlass.shade(g, icons, prm)
        }
        let img = makeImage(px, px) { g in
            g.scaleBy(x: sc, y: sc)
            for r in icons { g.addPath(continuousRoundedRect(r.insetBy(dx: -1, dy: -1), radius: (r.width + 2) * 0.2237)) }
            g.clip()
            drawUpright(g, composed, in: SBUI.full)
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
    func drawSBItem(_ g: CGContext, _ it: SBItem, _ r: CGRect, now: Double, badges: Bool, content: Bool = true, labels: Bool = true) {
        let lf = HPType.sf(HPType.Size.iconLabel, HPTokens.Home.iconLabelWeight), lb = HPTokens.Home.labelBaseline
        let showLabel = labels && !SB.largeIcons
        func label(_ s: String, _ under: CGRect) {
            guard showLabel else { return }
            let t = Face.clipped(s, lf, r.width + Shell.colGap - 6)
            drawLeft(g, t, font: lf, x: r.midX - Typo.width(t, lf) / 2, y: under.maxY + lb, color: .white)
        }
        // 快取頁（content＝false）不烤進按下的樣子；壓暗量跟著按壓動效（HPIconPress，放開時漸回）
        let pressDim = content && !SB.editing ? HPIconPress.look(for: it.key, now: now).dim : 0, pressed = pressDim > 0.001
        switch it {
        case .app(let id):
            guard let app = AppRegistry.app(id) else { return }
            let ir = SB.iconRect(in: r)
            Shell.drawHomeIcon(g, face: self, app: app, in: ir)
            if pressed { g.saveGState(); g.addPath(continuousRoundedRect(ir, radius: ir.width * 0.2237)); g.setFillColor(NSColor(white: 0, alpha: pressDim).cgColor); g.fillPath(); g.restoreGState() }
            label(app.title, ir)
            if badges { sbBadge(g, SBUI.badge(r, icon: true)) }
        case .folder(let f):
            let ir = SB.iconRect(in: r)
            sbFolderIcon(g, f, ir)
            if pressed { g.saveGState(); g.addPath(continuousRoundedRect(ir, radius: ir.width * 0.2237)); g.setFillColor(NSColor(white: 0, alpha: pressDim * 0.8).cgColor); g.fillPath(); g.restoreGState() }
            label(f.name, ir)
            if badges { sbBadge(g, SBUI.badge(r, icon: true)) }
        case .widget(let w):
            if content { drawSBWidget(g, w, r, now: now) }
            if pressed { g.saveGState(); g.addPath(continuousRoundedRect(r, radius: Shell.widgetRadius)); g.setFillColor(NSColor(white: 0, alpha: pressDim * 0.65).cgColor); g.fillPath(); g.restoreGState() }
            label(w.title, r)
            if badges { sbBadge(g, SBUI.badge(r, icon: false)); if w.kind.sizes.count > 1 { sbResizeHandle(g, r) } }
        case .stack(let s):
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
    func sbFolderIcon(_ g: CGContext, _ f: SBFolder, _ ir: CGRect) {
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
        // 右邊的頁點：編輯模式一直有；平常換過之後亮 1.8 秒。照 iOS 只是指示器、不能點（2.0 align F：輔助使用在小工具本身念「第 n 個，共 m 個」）
        let shown = SB.stackShown[key].map { now - $0 } ?? 99
        let alpha: CGFloat = SB.editing || SB.stackDrag?.key == key ? 1 : CGFloat(max(0, min(1, (1.8 - shown) / 0.4)))
        guard alpha > 0.01, ws.count > 1 else { return }
        let pitch: CGFloat = 22, x = r.maxX + 16, y0 = r.midY - CGFloat(ws.count - 1) * pitch / 2
        for i in ws.indices {
            g.setFillColor(NSColor.white.withAlphaComponent((i == idx ? 0.95 : 0.4) * alpha).cgColor)
            let dot = HPTokens.Size.dot   // 2.0 align F：10 → dot 14（所有頁點同一個直徑）
            g.fillEllipse(in: CGRect(x: x - dot / 2, y: y0 + CGFloat(i) * pitch - dot / 2, width: dot, height: dot))
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

    /// 頁點：平常一頁也畫（一個點＋資源庫圖示，不然看不出右邊還有東西）；最後一格換成資源庫符號（照 iOS）。
    /// 編輯模式沒有資源庫，頁點在玻璃膠囊裡（點了是編輯頁面）。
    private func drawSBDots(_ g: CGContext, _ now: Double, alpha: CGFloat = 1) {
        let n = SBUI.dotSlots
        guard n > 1 || SB.editing, alpha > 0.001 else { return }
        let pos = SB.pagePosition(now)
        let cap = SBUI.dotsCapsule(n)
        // 增加對比：沒選中的點更亮、外圍一圈暗邊，淺色桌布上也分得出
        let ic = HPAccessibility.increaseContrast
        let offA: CGFloat = ic ? 0.62 : 0.4
        func dots(_ c: CGContext) {
            for i in 0..<n {
                let on = max(0, 1 - abs(CGFloat(i) - pos))
                let col = NSColor.white.withAlphaComponent((offA + (0.95 - offA) * on) * alpha)   // 符號的圖不吃 CG 的 alpha：淡出直接乘進顏色
                let rim = NSColor.black.withAlphaComponent(0.35 * alpha)
                let ctr = SBUI.dotCenter(i, of: n)
                if SB.libraryReachable, i == SB.librarySlot {
                    let r = CGRect(x: ctr.x - 10, y: ctr.y - 10, width: 20, height: 20)
                    if ic { drawSymbol(c, "square.grid.2x2.fill", in: r.insetBy(dx: -2, dy: -2), color: rim) }
                    drawSymbol(c, "square.grid.2x2.fill", in: r, color: col)
                    continue
                }
                let d = CGRect(x: ctr.x - 7, y: ctr.y - 7, width: 14, height: 14)
                if ic { c.setFillColor(rim.cgColor); c.fillEllipse(in: d.insetBy(dx: -2, dy: -2)) }
                c.setFillColor(col.cgColor)
                c.fillEllipse(in: d)
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
        drawSBItem(g, d.item, r, now: now, badges: false, labels: false)
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
        drawSBFloatyFolder(g, f, folder, t: t, now: now)   // 浮動資料夾（Shell/SpringBoard/SBFloatyFolder.swift）
        HPGlass.flush(g, face: self, now: now)
        if let d = f.drag { drawSBFolderDragged(g, d, now: now) }
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
            drawSBItem(g, it, m.anchor, now: now, badges: false, labels: false)
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
                    self.drawSBSizeGlyph(c, sz, in: r.insetBy(dx: 36, dy: 14), color: HPGlass.ink)
                }
                let dividerY = panel.minY + SBUI.menuInset + SBUI.menuSizes + SBUI.menuDividerGap
                c.setFillColor(HPGlass.ink.withAlphaComponent(0.15).cgColor)
                c.fill(CGRect(x: panel.minX + SBUI.menuInset, y: dividerY, width: panel.width - SBUI.menuInset * 2, height: 2))
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
        let h = HPTokens.Size.switchTrack
        let sw = CGRect(x: r.maxX - 150, y: r.midY - h / 2, width: 132, height: h)
        g.addPath(HPComponents.capsulePath(sw)); g.setFillColor((on ? srgb(0x30D158) : NSColor(white: 1, alpha: 0.22)).cgColor); g.fillPath()
        let knob = h - 10
        g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: CGRect(x: on ? sw.maxX - knob - 5 : sw.minX + 5, y: sw.minY + 5, width: knob, height: knob))
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
            drawLeft(g, L("home.gallery.title", "小组件"), font: HPType.sf(56, .bold), x: SBUI.sheetContent.minX, y: SBUI.sheetTitleBaseline, color: .white)
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
        centered(g, title, HPType.sf(54, .bold), 512, SBUI.sheetTitleBaseline, .white, max: 640)
        let bf = HPType.sf(30, .regular)
        var y = card.minY + 170
        for line in Face.photosWrap(blurb, bf, SBUI.sheetContent.width - 64, maxLines: 2) { centered(g, line, bf, 512, y, NSColor.white.withAlphaComponent(0.6)); y += 40 }
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
            let dot = HPTokens.Size.dot
            g.fillEllipse(in: CGRect(x: d.midX - dot / 2, y: d.midY - dot / 2, width: dot, height: dot))
        }
        button(g, SBUI.galleryAdd, L("sb.addWidget", "添加小组件"), fill: kind?.accent ?? srgb(0x5E5CE6), symbol: "plus")
    }

    private func drawSBConfig(_ g: CGContext, _ key: String, _ now: Double) {
        guard case .widget(let w)? = SB.layout.item(key) else { return }
        let card = SBUI.configCard
        sheetBase(g, card, key: "sbconfig")
        centered(g, String(format: L("sb.editWidget.title", "编辑「%@」"), w.kind.title), HPType.sf(44, .bold), card.midX, card.minY + 84, .white, max: card.width - 80)
        // 小預覽（2.0 align：高 160，讓 5 列選項排得下；與標題、選項同一條內縮）
        let real = SB.frame(col: 0, row: 0, span: w.size.span)
        let k = min(160 / real.height, 520 / real.width)
        g.saveGState(); g.translateBy(x: card.midX - real.width * k / 2, y: card.minY + 116); g.scaleBy(x: k, y: k)
        drawSBWidget(g, w, CGRect(origin: .zero, size: real.size), now: now, preview: true)
        g.restoreGState()
        let opts = SBWidgetData.options(w.kind)
        if let o = opts.first {
            drawLeft(g, o.title, font: HPType.sf(30, .semibold), x: SBUI.configContent.minX, y: card.minY + 308, color: NSColor.white.withAlphaComponent(0.6))
            let cur = SBWidgetData.value(w, o.key), rf = HPType.sf(36, .regular)
            for (c, r) in zip(o.choices.prefix(5), SBUI.configOptionRows(min(5, o.choices.count))) {
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
        let rows = SBUI.stackRows(min(4, s.widgets.count))
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
        for (i, (title, on)) in [(L("sb.smartRotate", "智能旋转"), s.smartRotate), (L("sb.suggestions", "小组件建议"), s.suggestions)].enumerated() {
            let r = SBUI.stackToggleRows(rows)[i]
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
        let bg = sbBackdrop()
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
            for p in SB.placements(page: pi) { drawSBItem(g, p.item, SB.frame(p), now: CACurrentMediaTime(), badges: false) }
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
        // 標題、正文、按鈕同一條內縮（HPGrid.Inset.card = 40）
        let c = SBUI.alertContent
        drawLeft(g, Face.clipped(title, HPType.sf(40, .semibold), c.width), font: HPType.sf(40, .semibold), x: c.minX, y: card.minY + 76, color: .white)
        let body = isApp ? L("sb.remove.appBody", "从主屏幕移除后，App 仍在 App 资源库里。") : (key.hasPrefix("f:") ? L("sb.remove.folderBody", "文件夹里的 App 会移到 App 资源库。") : L("sb.remove.widgetBody", "移除这个小组件不会删除任何数据。"))
        let bf = HPType.sf(30, .regular)
        var y = card.minY + 128
        for line in Face.photosWrap(body, bf, c.width, maxLines: 2) { drawLeft(g, line, font: bf, x: c.minX, y: y, color: NSColor.white.withAlphaComponent(0.6)); y += 40 }
        let b = SBUI.alertButtons
        button(g, b[0], isApp ? L("sb.remove.fromHome", "从主屏幕移除") : L("sb.remove.confirm", "移除"), fill: NSColor(white: 1, alpha: 0.14), color: srgb(0xFF453A))
        button(g, b[1], L("sb.cancel", "取消"), fill: NSColor(white: 1, alpha: 0.14))
    }

    // MARK: App 資料庫

    /// dx：從最後一頁翻過來時整頁的位移（0＝正中）；alpha：減少動態效果時的交叉淡化
    private func drawSBLibrary(_ g: CGContext, _ now: Double, dx: CGFloat = 0, alpha: CGFloat = 1) {
        let moving = dx != 0 || alpha < 1
        let s = SBUI.librarySearch.offsetBy(dx: dx, dy: 0)
        let q = SB.libraryQuery
        g.saveGState(); defer { g.restoreGState() }
        if moving {
            g.addPath(continuousRoundedRect(SBUI.panel, radius: Screen.concentric(inset: HPTokens.Home.panelInset))); g.clip()
            g.setAlpha(alpha)
        }
        HPGlass.addCapsule(s, interactive: true, presence: alpha) { [weak self] c in
            guard let self else { return }
            self.drawSymbol(c, "magnifyingglass", in: CGRect(x: s.minX + 30, y: s.midY - 18, width: 36, height: 36), color: HPGlass.ink.withAlphaComponent(0.7))
            let f = HPType.sf(36, .regular)
            let caret = SB.librarySearching && Int(now * 2) % 2 == 0 ? "|" : ""
            let text = q.isEmpty && !SB.librarySearching ? L("sb.library", "App 资源库") : q + caret
            self.drawLeft(c, Face.clipped(text, f, s.width - 120), font: f, x: s.minX + 84, y: s.midY + f.capHeight / 2, color: q.isEmpty && !SB.librarySearching ? HPGlass.ink.withAlphaComponent(0.6) : HPGlass.ink)
        }
        g.translateBy(x: dx, y: 0)
        drawShellAvatar(g)   // 頭像跟著這一頁（翻的時候不會被搜尋欄蓋過去）
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
        let lay = SBUI.libraryLayout()
        let hf = HPType.sf(34, .semibold)
        for h in lay.headers {   // 分區標題（iPhone）
            drawLeft(g, h.title, font: hf, x: HPTokens.Home.gridMargin, y: h.y + 44, color: NSColor.white.withAlphaComponent(HPAccessibility.increaseContrast ? 1 : 0.85))
        }
        for (app, cell) in zip(apps, lay.cells) {
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
        if SB.menu != nil, !moving { HPGlass.flush(g, face: self, now: now); drawSBMenu(g, now) }
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
