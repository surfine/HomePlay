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

    /// 同心圓角：內層＝外層 − 內縮
    static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat { max(0, outer - inset) }
}
