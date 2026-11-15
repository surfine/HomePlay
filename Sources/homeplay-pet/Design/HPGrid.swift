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

    /// 內容邊線（2026-11-12 設計稿定案）：整台只留這一條——主畫面第 1 欄與第 4 欄圖示的外緣。
    /// 所有 App 的內容區、頂列、橫幅通知都貼這條線（舊的 App 邊距 64／960 已經拿掉）。
    enum Content {
        static var leading: CGFloat { HPTokens.Space.content }      // 98.5
        static var trailing: CGFloat { canvas - leading }           // 925.5
        static var width: CGFloat { trailing - leading }            // 827
        /// 四欄的欄心（174.5、399.5、624.5、849.5）：App 資料庫的豆莢對這裡
        static func columnCenter(_ col: Int) -> CGFloat { leading + Home.icon / 2 + CGFloat(col) * Home.pitch }
    }

    /// 滿版面板／磚牆的外緣
    enum Panel {
        static let margin = HPTokens.HomeModular.margin      // 24
    }

    /// 間距只用這些（8 的倍數）
    static let scale: [CGFloat] = [8, 16, 24, 32, 48, 64, 96]
    /// 最小點按範圍（44 pt × 2）
    static let tap = HPTokens.Size.tap                       // 88
    /// 外觀比 88 小的可點元件：以它為中心把點按範圍補到至少 88 × 88（外觀不變；shell-layout.md 第 2 節）
    static func hitRect(_ r: CGRect) -> CGRect {
        r.insetBy(dx: min(0, (r.width - tap) / 2), dy: min(0, (r.height - tap) / 2))
    }

    /// 內縮合約（2026-10-28）：一個容器只有**一條**左緣、一條右緣。
    /// 以前圖庫是 32/40/48/54/56 五種、控制中心展開是 24/40 兩種，所以看起來邏輯錯亂。
    enum Inset {
        /// 浮層（控制中心、Sheet、長按選單、橫幅通知）的卡片內容邊線（標題、清單、預覽、主按鈕全部對這條；
        /// docs/plans/shell-layout.md 第 3 節。長按選單原本另用 12，2026-11-12 起一樣是 40）
        static let card: CGFloat = 40
        /// 卡片內「行」的內距（行本身仍然貼 card 邊線；行裡的字與圖示再縮 nested）
        static let nested: CGFloat = 24
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
