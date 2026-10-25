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

        // 3. App 資料庫：第一欄左緣＝搜尋欄左緣＝gridMargin；最後一欄右緣對稱；搜尋欄中線對齊頭像中線
        let cells = SBUI.libraryCells(8)
        check(SBUI.librarySearch.minX == HPTokens.Home.gridMargin && SBUI.libraryIcon(cells[0]).minX == HPTokens.Home.gridMargin, "網格：App 資料庫第一欄左緣＝搜尋欄左緣＝\(HPTokens.Home.gridMargin)")
        check(SBUI.libraryIcon(cells[3]).maxX == HPGrid.Home.trailing, "網格：App 資料庫最後一欄右緣＝\(HPGrid.Home.trailing)")
        check(SBUI.librarySearch.midY == Shell.avatarRect.midY, "網格：App 資料庫搜尋欄跟頭像同一條垂直中線（\(Int(Shell.avatarRect.midY))）")

        // 4. 橫幅通知：左右落在 HPGrid.App 的 64／960
        check(HPTokens.bannerCard.minX == HPGrid.App.leading && HPTokens.bannerCard.maxX == HPGrid.App.trailing, "網格：橫幅通知左右落在 \(Int(HPGrid.App.leading))／\(Int(HPGrid.App.trailing))")

        // 5. 鎖卡：垂直節奏取自 HPGrid.scale
        let d1 = Face.lockTitleY - (Face.lockIconY + 200), d2 = Face.lockWhyY - Face.lockTitleY
        check(HPGrid.scale.contains(d1) && HPGrid.scale.contains(d2), "網格：鎖卡垂直節奏 \(Int(d1))／\(Int(d2)) 都在 HPGrid.scale")

        // 6. 編輯模式的筆刷／完成膠囊：跟返回鈕同高、左右鏡像（跨畫面一致）
        let b = HPTokens.backButton
        check(SBUI.editMenuButton.minY == b.minY && SBUI.editMenuButton.height == b.height && SBUI.doneButton.maxX == HPGrid.canvas - b.minX && SBUI.doneButton.height == b.height && SBUI.doneButton.minY == b.minY, "網格：編輯模式的筆刷與完成膠囊跟返回鈕同高、左右鏡像")
    }
}
