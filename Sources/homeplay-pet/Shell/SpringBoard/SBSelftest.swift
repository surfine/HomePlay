// 2.0 SpringBoard 的 --selftest（執行時那一層：拖曳＋dwell、翻頁、資料夾、鍵盤搬移、改大小、點按範圍、輔助使用）。
// 純排列的測試在 SBModel.swift（SBModelSelftest）。用 --home-layout 那種固定排列跑，不讀也不寫存檔。

import AppKit

enum SBBoardSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        let saved = (SB.forcedLayout, SB.owner, SB.working, Shell.homeEditing, SB.page, SBStore.persist, Shell.nav)
        defer {
            SB.forcedLayout = saved.0; SB.owner = saved.1; SB.working = saved.2; Shell.homeEditing = saved.3; SB.page = saved.4; SBStore.persist = saved.5
            Shell.nav = saved.6; SB.drag = nil; SB.menu = nil; SB.sheet = nil; SB.folder = nil; SB.wasEditing = false; SB.anims.removeAll()
        }
        SBStore.persist = false
        func fresh(_ name: String = "official") {
            SB.forcedLayout = SBDemo.layout(name); SB.owner = .none; _ = SB.layout
            SB.page = 0; SB.drag = nil; SB.menu = nil; SB.sheet = nil; SB.folder = nil
        }
        func at(_ key: String) -> (Int, Int)? { SBLayout.positions(SB.layout.pages[SB.pageIndex].items)[key] }
        fresh()
        var now = 1000.0
        SB.enterEdit(now: now)
        check(Shell.homeEditing, "SpringBoard：示範排列可以進編輯模式")

        // 拖曳：FaceTime 拖到第二列右邊，停住超過 dwell 才讓位；放手照預覽的放
        let ft = SB.frame(col: 0, row: 0, span: (1, 1))
        SB.beginDrag("a:facetime", at: CGPoint(x: ft.midX, y: ft.midY), now: now)
        let dest = SB.frame(col: 3, row: 2, span: (1, 1))
        SB.dragUpdate(CGPoint(x: dest.midX + 60, y: dest.midY), now: now)   // 偏離圖示中央（中央是做資料夾）
        let before = SB.drag?.target.map { "\($0.col),\($0.row)" }
        now += 0.05; SB.dragUpdate(nil, now: now)
        let early = SB.drag?.target.map { "\($0.col),\($0.row)" }
        now += SBMotion.reorderDwell + 0.05; SB.dragUpdate(nil, now: now)
        let late = SB.drag?.target.map { "\($0.col),\($0.row)" }
        check(before == "0,0" && early == "0,0" && late == "3,2", "SpringBoard：停住超過 \(SBMotion.reorderDwell) s 才換位置（\(before ?? "-")→\(early ?? "-")→\(late ?? "-")）")   // l10n-ignore：selftest 訊息
        let preview = SBLayout.positions(SB.displayItems(page: SB.pageIndex))
        SB.endDrag(now: now)
        check(at("a:facetime").map { $0 == (3, 2) } == true && at("a:home").map { $0 == (0, 0) } == true && SB.layout.appsOnHome == SBLayout.official.appsOnHome,
              "SpringBoard：放手放在預覽的位置，別人照閱讀順序讓開、一個不少")   // l10n-ignore：selftest 訊息
        check(preview["a:home"].map { $0 == (0, 0) } == true, "SpringBoard：拖曳中的預覽就是放下去的結果")
        // 遲滯：在兩格中線附近抖動不會來回換
        let a = SB.cell(forTopLeft: CGPoint(x: SB.originX(1) + HPTokens.Home.columnPitch * 0.55, y: SB.originY(0)), span: (1, 1), current: (1, 0))
        let b = SB.cell(forTopLeft: CGPoint(x: SB.originX(1) + HPTokens.Home.columnPitch * 0.7, y: SB.originY(0)), span: (1, 1), current: (1, 0))
        check(a == (1, 0) && b == (2, 0), "SpringBoard：換格有遲滯（過中線 15% 才換）")

        // 翻頁：拖到右邊停 0.5 s，最後一頁再往右開新的一頁
        fresh()
        SB.enterEdit(now: now)
        let music = SB.frame(col: 0, row: 1, span: (1, 1))
        SB.beginDrag("a:music", at: CGPoint(x: music.midX, y: music.midY), now: now)
        SB.dragUpdate(CGPoint(x: 1000, y: 500), now: now)
        now += SBMotion.edgeDwell + 0.05; SB.dragUpdate(nil, now: now)
        check(SB.page == 1 && SB.layout.pages.count == 2, "SpringBoard：拖到螢幕邊停一下翻頁（最後一頁再往右開新頁）")
        SB.dragUpdate(CGPoint(x: 500, y: 500), now: now)
        now += 0.4; SB.dragUpdate(nil, now: now)
        SB.endDrag(now: now)
        check(SB.layout.locate("a:music")?.page == 1 && SB.layout.pages[0].items.count == 8, "SpringBoard：放到第二頁，第一頁其他的往前補")
        SB.exitEdit()
        check(SB.layout.pages.count == 2, "SpringBoard：完成時留著有東西的頁")
        // 完成時空頁拿掉
        fresh()
        var l = SB.layout; l.pages.append(SBPage(items: [])); SB.layout = l
        SB.enterEdit(now: now); SB.exitEdit()
        check(SB.layout.pages.count == 1, "SpringBoard：完成時拿掉空頁")

        // 資料夾：App 停在別的圖示上 0.35 s，放手做成資料夾
        fresh()
        SB.enterEdit(now: now)
        let msg = SB.frame(col: 1, row: 1, span: (1, 1)), home = SB.iconRect(in: SB.frame(col: 1, row: 0, span: (1, 1)))
        SB.beginDrag("a:messages", at: CGPoint(x: msg.midX, y: msg.minY + 70), now: now)
        SB.dragUpdate(CGPoint(x: home.midX, y: home.midY), now: now)
        now += SBMotion.folderDwell + 0.05; SB.dragUpdate(nil, now: now)
        let ready = SB.drag?.folderReady == true
        SB.endDrag(now: now)
        let folder = SB.layout.pages[0].items.first { if case .folder = $0 { return true }; return false }
        check(ready && folder?.apps == ["home", "messages"], "SpringBoard：圖示疊到圖示上停一下，放手變資料夾（\(folder?.apps ?? [])）")   // l10n-ignore：selftest 訊息

        // 鍵盤搬移：右移一格、到頁尾再右移到下一頁
        fresh()
        SB.enterEdit(now: now)
        SB.move("a:reminders", dc: 1, dr: 0, now: now)
        check(SB.layout.locate("a:reminders")?.page == 1 && SB.page == 1, "SpringBoard：方向鍵把最右邊的搬到下一頁")
        SB.move("a:reminders", dc: -1, dr: 0, now: now)
        check(SB.layout.locate("a:reminders")?.page == 0, "SpringBoard：再往左搬回來")

        // 改大小：照片 2×2 → 中 4×2，其他照樣在、多的推下一頁
        fresh()
        SB.resize("w:w-photos", to: .medium)
        if case .widget(let w)? = SB.layout.item("w:w-photos") {
            check(w.size == .medium && SB.layout.appsOnHome == SBLayout.official.appsOnHome, "SpringBoard：小工具改成中，App 一個不少")
        } else { check(false, "SpringBoard：改大小後找不到照片小工具") }

        // 點按範圍、選單位置
        fresh()
        SB.enterEdit(now: now)
        let pl = SB.placements(page: 0)
        check(pl.allSatisfy { SBUI.badge(SB.frame($0), icon: $0.item.isIcon).insetBy(dx: -16, dy: -16).width >= 88 } && SBUI.doneButton.height >= 88
              && SBUI.editMenuButton.height >= 88 && SBUI.galleryAdd.height >= 88 && SBUI.alertButtons.allSatisfy { $0.height >= 88 },
              "SpringBoard：「−」、完成、筆刷、加入小工具、提示卡按鈕的點按範圍都 ≥ 88")   // l10n-ignore：selftest 訊息
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let menus = pl.map { SBUI.menuPanel(anchor: SB.frame($0), rows: 4, sizes: true) }
        check(menus.allSatisfy { screen.insetBy(dx: 30, dy: 30).contains($0) }, "SpringBoard：每一格長按的選單都在螢幕裡")
        check(SBUI.galleryEntries().allSatisfy { SBUI.sheetCard.contains($0.1) } && SBUI.galleryEntries().count == SBWidgetKind.allCases.count,   // 2.0 Web App 的不在圖庫（＋Smart Stack −Web App）
              "SpringBoard：圖庫清單每個小工具（含 Smart Stack）都在 sheet 裡")   // l10n-ignore：selftest 訊息
        let cells = SBUI.libraryCells(AppRegistry.visible.count)
        // 2026-10-25 間距加大後內建 App 要捲一點（像 iOS App 資料庫）：左右在畫面內、捲到底每個都看得到
        let libScroll = SB.libraryMaxScroll
        check(cells.allSatisfy { let r = SBUI.libraryIcon($0); return r.minX >= 14 && r.maxX <= 1010 && r.minY >= SBUI.libraryTop && r.maxY - libScroll + 40 < 1000 }, "SpringBoard：App 資料庫的全部 App 都在畫面裡")
        check(SBUI.pageThumbs(5).allSatisfy { screen.contains(SBUI.pageCheck($0)) }, "SpringBoard：編輯頁面五頁也放得下")

        // 輔助使用：編輯模式有完成、項目有搬移的自訂動作；選單打開時只列選單
        Shell.nav = ShellNav(); Shell.nav.screen = .home
        let face = Face(); face.frozen = true
        let ax = SBAX.items(face: face)
        check(ax.contains { $0.id == "sb.done" } && ax.filter { $0.kind == .homeItem }.count == pl.count, "SpringBoard：編輯模式的輔助使用項目＝這頁的項目＋完成")
        SB.openMenu(for: "a:music", now: now)
        let ma = SBAX.items(face: face)
        check(SB.menu != nil && ma.allSatisfy { $0.id.hasPrefix("sb.menu") } && ma.count == SB.menu!.rows.count, "SpringBoard：選單打開時只念選單")
        SB.menu = nil
        // 移除＝拿掉主畫面上的（App 還在資料庫）
        SB.remove("a:music")
        check(!SB.layout.appsOnHome.contains("music") && SBUI.libraryApps().contains { $0.id == "music" }, "SpringBoard：移除 App 後還在 App 資料庫")
        SB.libraryQuery = "zzzz-none"
        check(SBUI.libraryApps().isEmpty, "SpringBoard：App 資料庫搜尋沒有結果時是空的")
        SB.libraryQuery = ""
        SB.exitEdit()
    }
}
