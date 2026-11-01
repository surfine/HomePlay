import CoreGraphics

/// HomeView 螢幕（1024 × 1024 畫布）的網格與對齊合約。
/// 使用者 2026-10-25：「网格和对齐还要适用于HomeView的系统界面，这是最基本的要求」。
/// 規則全文在 docs/plans/grid.md；數值改動先問使用者（主畫面那組是對官方圖量的）。
enum HPGrid {
    static let canvas: CGFloat = 1024
    static let mid: CGFloat = 512

    /// 主畫面／App 資源庫／編輯：4 欄（官方圖量過）
    enum Home {
        static let columns = 4
        static let margin = HPTokens.Home.gridMargin       // 98.5
        static let pitch = HPTokens.Home.columnPitch        // 225
        static let icon = HPTokens.Home.iconSide            // 152
        static var leading: CGFloat { margin }
        static var trailing: CGFloat { canvas - margin }   // 925.5
    }

    /// App 內容：左右邊距與主要對齊線
    enum App {
        static let margin = HPTokens.Space.margin            // 64
        static var leading: CGFloat { margin }
        static var trailing: CGFloat { canvas - margin }    // 960
    }

    /// 滿版面板／磚牆的外緣
    enum Panel {
        static let margin = HPTokens.HomeModular.margin      // 24
    }

    /// 間距只用這些（8 的倍數）
    static let scale: [CGFloat] = [8, 16, 24, 32, 48, 64, 96]
    /// 最小點按範圍（44 pt × 2）
    static let tap = HPTokens.Size.tap                       // 88

    /// 內縮合約（2026-10-28）：一個容器只有**一條**左緣、一條右緣。
    /// 以前圖庫是 32/40/48/54/56 五種、控制中心展開是 24/40 兩種，所以看起來邏輯錯亂。
    enum Inset {
        /// 卡片／Sheet 的內容邊線（標題、清單、預覽、主按鈕全部對這條）
        static let card: CGFloat = 40
        /// 卡片內「行」的內距（行本身仍然貼 card 邊線；行裡的字與圖示再縮 nested）
        static let nested: CGFloat = 24
        /// 長按選單內唯一的邊線（清單列、分隔線、尺寸塊都對它）
        static let menu: CGFloat = 12
        /// App 內容左右邊距（沿用）
        static var app: CGFloat { App.margin }
    }

    /// 卡片內部的節奏：只用這三個
    enum Rhythm {
        /// 同一組的相鄰行
        static let rowGap: CGFloat = 8
        /// 兩組之間
        static let groupGap: CGFloat = 24
        /// 兩個區段之間（例如預覽與選項）
        static let sectionGap: CGFloat = 32
    }

    /// 同心圓角：內層＝外層 − 內縮
    static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat { max(0, outer - inset) }
}
