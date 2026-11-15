// 10-grid：網格與對齊合約（docs/plans/grid.md）的版面自檢。
// 只驗純函數的幾何（不渲染、不讀視窗），跑在 `homeplay-pet --selftest`；
// 例外（官方校準優先）與全部規則見 docs/plans/grid.md 的殼層稽核表。

import CoreGraphics

enum GridSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        // 1. 控制中心：每欄模組的左緣落在同一組欄線、各尺寸的右緣落在下一條欄線、整區對稱於 512
        let pitch = ControlCenter.cell + ControlCenter.gap
        let colX = (0..<CCLayout.cols).map { ControlCenter.gridX + CGFloat($0) * pitch }
        check((0..<CCLayout.cols).map { ControlCenter.frame(col: $0, row: 0, size: .s1x1).minX } == colX, "網格：控制中心每欄模組的左緣都在同一組對齊線上（x = \(Int(colX.first ?? 0))…\(Int(colX.last ?? 0))）")
        check(CCSize.allCases.allSatisfy { s in ControlCenter.frame(col: 0, row: 0, size: s).maxX == ControlCenter.gridX + CGFloat(s.w) * pitch - ControlCenter.gap }, "網格：控制中心各尺寸模組的右緣落在下一條欄線上")
        check(2 * ControlCenter.gridX + CGFloat(CCLayout.cols) * ControlCenter.cell + CGFloat(CCLayout.cols - 1) * ControlCenter.gap == HPGrid.canvas, "網格：控制中心模組區左右對稱於 \(Int(HPGrid.mid))")

        // 2. 長按選單：都夾在畫面內；沒夾到時左緣對齊錨點左緣
        let icon = CGRect(x: HPTokens.Home.gridMargin, y: HPTokens.Home.gridTop, width: HPTokens.Home.iconSide, height: HPTokens.Home.iconSide)
        let menus = [SBUI.menuPanel(anchor: icon, rows: 3, sizes: true),
                     SBUI.menuPanel(anchor: icon.offsetBy(dx: 3 * HPTokens.Home.columnPitch, dy: 0), rows: 2, sizes: false),
                     SBUI.menuPanel(anchor: icon.offsetBy(dx: 3 * HPTokens.Home.columnPitch, dy: 3 * HPTokens.Home.rowPitch), rows: 3, sizes: false)]
        check(menus.allSatisfy { $0.minX >= 48 && $0.maxX <= 976 && $0.minY >= 48 && $0.maxY <= 1000 }, "網格：長按選單都在畫面內（左右邊距 48）")
        check(SBUI.menuPanel(anchor: icon, rows: 3, sizes: true).minX == icon.minX, "網格：長按選單沒夾到邊時左緣對齊錨點左緣（\(HPTokens.Home.gridMargin)）")

        // 3. App 資料庫：三欄豆莢的外緣貼內容邊線（2026-11-12 外殼版面規格）；搜尋結果與展開頁用主畫面 4 欄。搜尋欄佔第 1–3 欄，中線對齊頭像。
        let cells = SBUI.libraryCells(8)
        check(abs(SBLPodGrid.podFrame(0, top: 0).minX - HPGrid.Content.leading) < 0.01
              && abs(SBLPodGrid.podFrame(SBLPodGrid.columns - 1, top: 0).maxX - HPGrid.Content.trailing) < 0.01,
              "網格：App 資料庫豆莢的外緣貼內容邊線 98.5／925.5")   // l10n-ignore
        check(SBUI.libraryIcon(cells[0]).minX == HPTokens.Home.gridMargin && SBUI.libraryIcon(cells[3]).maxX == HPGrid.Home.trailing, "網格：App 資料庫搜尋結果仍用主畫面的 4 欄")
        let savedScreen = Shell.nav.screen
        Shell.nav.screen = .library   // 頭像在資料庫頁跟搜索欄中線（其他頁 152 照舊）
        check(abs(SBUI.librarySearch.minX - HPGrid.Home.margin) < 0.01 && SBUI.librarySearch.midY == Shell.avatarRect.midY, "網格：App 資料庫搜尋欄左緣對齊主畫面，並跟頭像同一條垂直中線")
        Shell.nav.screen = savedScreen

        // 3b. 內容邊線（2026-11-12）：98.5／925.5 就是主畫面第 1、4 欄圖示的外緣；欄心 174.5…849.5；列高 96／120 不小於點按範圍，節奏取自 scale
        let col0 = SBUI.libraryCell(0, 0), col3 = SBUI.libraryCell(3, 0)
        check(HPGrid.Content.leading == col0.minX && HPGrid.Content.trailing == col3.maxX && HPGrid.Content.leading == 98.5 && HPGrid.Content.trailing == 925.5,
              "網格：內容邊線 98.5／925.5 就是主畫面第 1、4 欄圖示的外緣")   // l10n-ignore
        check((0..<4).map { HPGrid.Content.columnCenter($0) } == [174.5, 399.5, 624.5, 849.5] && HPGrid.Content.columnCenter(0) == col0.midX,
              "網格：四欄欄心 174.5、399.5、624.5、849.5")   // l10n-ignore
        check(HPTokens.Size.listRow == 96 && HPTokens.Size.listRowSub == 120 && HPTokens.Size.listRow >= HPGrid.tap
              && HPGrid.Rhythm.groupGap == 24 && HPGrid.Rhythm.sectionGap == 32
              && HPGrid.scale.contains(HPGrid.Rhythm.groupGap) && HPGrid.scale.contains(HPGrid.Rhythm.sectionGap),
              "網格：內容清單列高 96／120（≥ 點按範圍 88），分組間距 24、區段間距 32")   // l10n-ignore

        // 4. 橫幅通知：左右落在內容邊線 98.5／925.5
        check(HPTokens.bannerCard.minX == HPGrid.Content.leading && HPTokens.bannerCard.maxX == HPGrid.Content.trailing, "網格：橫幅通知左右落在內容邊線 98.5／925.5")

        // 5. 鎖卡：垂直節奏取自 HPGrid.scale
        let d1 = Face.lockTitleY - (Face.lockIconY + 200), d2 = Face.lockWhyY - Face.lockTitleY
        check(HPGrid.scale.contains(d1) && HPGrid.scale.contains(d2), "網格：鎖卡垂直節奏 \(Int(d1))／\(Int(d2)) 都在 HPGrid.scale")

        // 6. 編輯模式的筆刷／完成膠囊：跟返回鈕同高、左右鏡像（跨畫面一致）
        let b = HPTokens.backButton
        check(SBUI.editMenuButton.minY == b.minY && SBUI.editMenuButton.height == b.height && SBUI.doneButton.maxX == HPGrid.canvas - b.minX && SBUI.doneButton.height == b.height && SBUI.doneButton.minY == b.minY, "網格：編輯模式的筆刷與完成膠囊跟返回鈕同高、左右鏡像")
    }
}
