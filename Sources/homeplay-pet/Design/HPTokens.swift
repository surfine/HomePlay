// HPDS（HomePlay Design System）v1：Tokens——顏色、間距、圓角、陰影、版面。規格見 Design/README.md。
//
// 2.0 逼真化第二輪：白天淺色、暗處深色（照官方影片：白天的 App 都是淺色）。原本是 Design/HPTokens.swift；
// 舊名 Theme 留成 typealias，舊的呼叫照樣編得過。新程式一律用 HPTokens，App 裡不寫死數字。
import AppKit

typealias Theme = HPTokens

enum HPTokens {
    /// 現在是不是深色：環境暗（夜間）或使用者選了深色。快照可用 --appearance light|dark 強制
    nonisolated(unsafe) static var dark: Bool = CommandLine.arguments.contains("dark") && CommandLine.arguments.contains("--appearance")

    // MARK: 顏色：底與文字（iOS 系；HomeView 是 iOS 系，文字色不用 macOS 的 85% labelColor）
    static var bg: NSColor { dark ? .black : NSColor(srgbRed: 0.949, green: 0.949, blue: 0.969, alpha: 1) }      // systemGroupedBackground
    static var card: NSColor { dark ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1) : .white }     // secondarySystemGroupedBackground
    /// 卡上再一層（tertiarySystemGroupedBackground／淺色時的 systemGray5）
    static var card2: NSColor { dark ? srgb(0x2c2c2e) : srgb(0xe5e5ea) }
    static var label: NSColor { dark ? .white : .black }
    /// 增加對比時次要字提高到 label 的 80%（P01）
    static var secondary: NSColor {
        if HPAccessibility.increaseContrast { return label.withAlphaComponent(0.8) }
        return dark ? NSColor(srgbRed: 0.922, green: 0.922, blue: 0.961, alpha: 0.6) : NSColor(srgbRed: 0.235, green: 0.235, blue: 0.263, alpha: 0.6)
    }
    static var tertiary: NSColor { dark ? NSColor(srgbRed: 0.922, green: 0.922, blue: 0.961, alpha: 0.3) : NSColor(srgbRed: 0.235, green: 0.235, blue: 0.263, alpha: 0.3) }
    static var separator: NSColor { dark ? NSColor(srgbRed: 0.329, green: 0.329, blue: 0.345, alpha: 0.6) : NSColor(srgbRed: 0.235, green: 0.235, blue: 0.263, alpha: 0.29) }
    static var fill: NSColor { dark ? NSColor(srgbRed: 0.471, green: 0.471, blue: 0.502, alpha: 0.36) : NSColor(srgbRed: 0.471, green: 0.471, blue: 0.502, alpha: 0.2) }
    /// 再淡兩階的填色（iOS secondarySystemFill／tertiarySystemFill 的值；P07 HIG-MAT-53 補齊層級）
    static var fillSecondary: NSColor { dark ? NSColor(srgbRed: 0.471, green: 0.471, blue: 0.502, alpha: 0.32) : NSColor(srgbRed: 0.471, green: 0.471, blue: 0.502, alpha: 0.16) }
    static var fillTertiary: NSColor { dark ? NSColor(srgbRed: 0.471, green: 0.471, blue: 0.502, alpha: 0.24) : NSColor(srgbRed: 0.471, green: 0.471, blue: 0.502, alpha: 0.12) }
    /// 照片／深色媒體上的字（不跟淺深走）
    static let onMedia = NSColor.white

    // MARK: 夜間紅（P07）：StandBy 式的夜間——黑底、亮紅主要內容、暗紅次要（層級跟 vibrant 一致：最突出的最亮）。
    // 對黑底對比由 selftest 驗（主要、次要都 ≥ 4.5，且主要比次要亮）。走「亮度→紅」整面映射的畫面要用
    // Shell.nightTint（畫白）才留得下亮度；直接畫紅會沉成深紅（HIG-LA-203）。
    enum Night {
        /// 主要內容：日、時間、歌名、計時器倒數、Live Activity 標題（#F2544A ≈ 6.1:1）
        static let primary = x(0xF2544A)
        /// 次要內容：月、演唱者、狀態、小刻度（#D6483E ≈ 4.9:1，比主要暗一階）
        static let secondary = x(0xD6483E)
        /// 夜間控制底（播放膠囊、minimal 活動的底）：半透明紅，不是內容
        static let fill = primary.withAlphaComponent(0.16)
    }

    // MARK: 模組錶面（Modular）的色票（P07 HIG-WID-171：官方 tile_modular.png 量的灰藍底與字色收進 token，不再寫在 Face 裡）
    enum Modular {
        /// 平的灰藍底
        static let bg = x(0x93abb1)
        /// 主要字（日、時鐘、歌名）
        static let ink = x(0x0a0b0c)
        /// 次要字（月、演唱者、狀態）
        static let soft = x(0x3e4a4e)
        /// 行事曆小卡的紅（「下一個行程」、低電量）
        static let alert = x(0xc6281f)
    }

    // MARK: 系統色（淺／深兩版）：macOS 27 實測（NSColor.system* 轉 sRGB，chan-notes §3.4）；增加對比時換 HIG 表上的高對比版
    // （macOS 27 的 NSColor 在 accessibilityHighContrast 外觀下解出來跟預設一樣，所以用 HIG 的數字）
    static var red: NSColor { pick(0xFF383C, 0xFF4245, ic: 0xE9152D, 0xFF6165) }
    static var orange: NSColor { pick(0xFF8D28, 0xFF9230, ic: 0xC55300, 0xFFA056) }
    static var yellow: NSColor { pick(0xFFCC00, 0xFFD600, ic: 0xA16A00, 0xFEDF43) }
    static var green: NSColor { pick(0x34C759, 0x30D158, ic: 0x008932, 0x4AD968) }
    static var blue: NSColor { pick(0x0088FF, 0x0091FF, ic: 0x1E6EF4, 0x5CB8FF) }
    static var purple: NSColor { pick(0xCB30E0, 0xDB34F2, ic: 0xB02FC2, 0xEA8DFF) }
    static var mint: NSColor { pick(0x00C8B3, 0x00DAC3, ic: 0x008575, 0x54DFCB) }
    static var teal: NSColor { pick(0x00C3D0, 0x00D2E0, ic: 0x008198, 0x3BDDEC) }
    static var cyan: NSColor { pick(0x00C0E8, 0x3CD3FE, ic: 0x007EAE, 0x6DD9FF) }
    static var indigo: NSColor { pick(0x6155F5, 0x6D7CFF, ic: 0x564ADE, 0xA7AAFF) }
    static var pink: NSColor { pick(0xFF2D55, 0xFF375F, ic: 0xE7124D, 0xFF8AC4) }
    static var brown: NSColor { pick(0xAC7F5E, 0xB78A66, ic: 0x956D51, 0xDBA679) }
    static var gray: NSColor { pick(0x8E8E93, 0x98989D, ic: 0x6C6C70, 0xAEAEB2) }
    /// 淺／深／增加對比淺／增加對比深（增加對比的值照 HIG Color 的 System colors 表：colors-unified-accessible-*）
    private static func pick(_ light: UInt32, _ darkV: UInt32, ic icLight: UInt32, _ icDark: UInt32) -> NSColor {
        HPAccessibility.increaseContrast ? x(dark ? icDark : icLight) : x(dark ? darkV : light)
    }
    private static func x(_ v: UInt32) -> NSColor { c(CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255) }
    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    // MARK: 間距（1024 畫布單位；8 的倍數＋影片量到的 14、20、60、114）
    enum Space {
        static let xxs: CGFloat = 8
        /// 玻璃面板離螢幕邊（主畫面玻璃面板內縮、家庭磚間距）
        static let panelInset: CGFloat = 14
        /// 面板裡壓暗（系統 Clear 提亮 ×1.25 → 官方 ×1.07）
        static let panelShade: CGFloat = 0.15
        static let s: CGFloat = 16
        /// 錶面頁縫、家庭磚間距（影片 v2）
        static let gap: CGFloat = 20
        static let m: CGFloat = 24
        static let l: CGFloat = 32
        /// 小工具標準內距 16 pt（H-Wid）
        static let widgetPad: CGFloat = 30
        /// 主畫面欄距（影片 v1）
        static let column: CGFloat = 60
        /// App 內容左右邊距（跟主畫面圖示欄外緣對齊）
        static let margin: CGFloat = 64
        /// 主畫面網格左右邊距（影片 v1）
        static let homeMargin: CGFloat = 114
    }

    // MARK: 圓角：固定、膠囊、同心三種（chan-notes S1）
    enum Radius {
        /// 機身螢幕的連續圓角（≈ 138）；所有同心圓角的根
        static var screen: CGFloat { Screen.cornerRadius }
        /// 螢幕圓角在 45° 方向的單軸內縮（≈ 40.8，官方圖量到約 40）；遮罩、官方圖對照用
        static var screenDiagonalInset: CGFloat { CGFloat(CornerFit.bodyDiag) * Screen.side }
        /// 同心：離螢幕邊 inset 的元件，半徑＝螢幕半徑 − inset（不小於 minimum）
        static func concentric(inset: CGFloat, minimum: CGFloat = 12) -> CGFloat { Screen.concentric(inset: inset, minimum: minimum) }
        /// 同心（父元件不是螢幕時）：父半徑 − 內距
        static func concentric(parent: CGFloat, padding: CGFloat, minimum: CGFloat = 12) -> CGFloat { max(minimum, parent - padding) }
        /// 膠囊：半徑＝高 ÷ 2
        static func capsule(_ r: CGRect) -> CGFloat { min(r.width, r.height) / 2 }
        /// inset grouped 卡片
        static let group: CGFloat = 52
        /// 家庭磚（影片 49–50）
        static let tile: CGFloat = 50
        /// 主畫面 small 小工具：第五輪照官方主畫面 Photos 小工具（391² 正方形）的角量到約 56
        static let widget: CGFloat = 56
    }

    // MARK: 陰影（CG 座標：y 往下為正的畫布上 offset 正值＝往下）
    struct Shadow {
        var offset: CGSize
        var blur: CGFloat
        var alpha: CGFloat
        /// color 不給＝黑（NSColor(white: 0)，跟原本各處的寫法同一個色彩空間）
        func apply(_ g: CGContext, color: NSColor? = nil) {
            g.setShadow(offset: offset, blur: blur, color: (color?.withAlphaComponent(alpha) ?? NSColor(white: 0, alpha: alpha)).cgColor)
        }
        /// 開著的家庭磚、淺色卡片浮起
        static let card = Shadow(offset: CGSize(width: 0, height: 4), blur: 18, alpha: 0.12)
        /// 開關、滑桿的旋鈕
        static let knob = Shadow(offset: CGSize(width: 0, height: -2), blur: 6, alpha: 0.25)
        /// 分段控制選中的膠囊（淺色）
        static let segment = Shadow(offset: CGSize(width: 0, height: 2), blur: 8, alpha: 0.12)
        /// 玻璃外陰影（HPGlass.flush 依底下內容調濃淡 0.10–0.30）：小控制與面板
        static let glassSmall = Shadow(offset: CGSize(width: 0, height: -5), blur: 22, alpha: 0.10)
        static let glassLarge = Shadow(offset: CGSize(width: 0, height: -10), blur: 40, alpha: 0.10)
    }

    // MARK: 尺寸
    enum Size {
        /// 最小點按範圍（44 pt ≈ 83 px，取 88）
        static let tap: CGFloat = 88
        /// 左上返回圓鈕（官方 recipe-overview 量到 90）
        static let backButton: CGFloat = 90
        /// 主要動作圓鈕（影片 150–162）
        static let action: CGFloat = 150
        /// 並排成一組的膠囊鈕共用這一個尺寸，只靠樣式（染色／玻璃）分主次（HIG Buttons：同尺寸＝對等選項）。Music 的「打開音樂」＋「資料庫」
        static let pairedButton = CGSize(width: 440, height: 104)
        /// 主畫面圖示
        static let icon: CGFloat = 150
        /// 家庭磚（影片 304–315）
        static let tile: CGFloat = 300
    }

    // MARK: 主畫面（第三輪：官方主畫面左上——問候語兩行全大寫 SF Pro Regular 約 34、字距略寬、白 85%；右上頭像直徑約 100）
    // 第五輪：官方 home-screen-erica 正視校正後逐項量（scratchpad/real/r5-home-audit.md）
    enum Home {
        /// 問候語 32（「GOOD MORNING,」寬 262、大寫高 22–23）；第一行 regular 白 60%，名字那行 semibold 白 82%
        static let greetingSize: CGFloat = 32
        static let greetingWeight: NSFont.Weight = .regular
        static let nameWeight: NSFont.Weight = .semibold
        /// 全大寫標籤另給的字距（畫布 px；約 +0.5 pt）
        static let greetingKern: CGFloat = 1.0
        static let greetingAlpha: CGFloat = 0.60
        static let nameAlpha: CGFloat = 0.82
        /// 兩行基線 139／182；文字原點比圖示左緣內縮 9（「G」在 110、圖示在 99）
        static let greetingBaseline: CGFloat = 139
        static let greetingLeading: CGFloat = 43
        static let greetingInset: CGFloat = 9
        /// 頭像直徑（中心不動）；官方沒有描邊
        static let avatar: CGFloat = 100
        /// 圖示標籤：SF Pro regular 30、白、沒有投影（官方直筆畫 2 px；semibold＋投影是 Android 啟動器的味道）
        static let iconLabelWeight: NSFont.Weight = .regular
        /// 網格：圖示 152、左右邊距 99、欄距 225、首列頂 241、列距 240；標籤基線＝圖示底 + 41
        static let gridMargin: CGFloat = (1024 - 3 * 225 - 152) / 2   // 98.5：左右對稱（官方量到 99）
        static let iconSide: CGFloat = 152
        static let columnPitch: CGFloat = 225
        static let gridTop: CGFloat = 241
        static let rowPitch: CGFloat = 240
        static let labelBaseline: CGFloat = 41
        /// 桌布：錶面畫面模糊 σ 18（官方還看得到大數字的柱形）＋亮度 × 0.72（官方面板內亮度約 0.6）
        static let wallpaperBlur: CGFloat = 18
        static let wallpaperDim: CGFloat = 0.72
        /// 壓暗後的平均亮度（Rec.709）上限：官方面板內 (152,98,88) ≈ 0.43，面板本身再提亮一點，取 0.45
        static let wallpaperMaxLum: CGFloat = 0.45
        /// 面板的厚玻璃亮邊：邊上亮 +64（216 對 152）、往內約 24 px 漸回
        static let panelInset: CGFloat = 14
        /// 面板裡壓暗（系統 Clear 提亮 ×1.25 → 官方 ×1.07）
        static let panelShade: CGFloat = 0.15
        static let panelRimLine: CGFloat = 2
        static let panelRimAlpha: CGFloat = 0.5
        static let panelGlowBlur: CGFloat = 24
        static let panelGlowAlpha: CGFloat = 0.30
    }

    // MARK: 家庭模組錶面（第三輪：量自官方 face-home-modular-purple／-blue、home-modular-teal-angled）
    /// 3×3 的玻璃磚：外距 24、間距 20、每格 312；左上大溫控佔 2×2；磚圓角＝家庭磚 50（官方的磚不跟螢幕同心）
    enum HomeModular {
        static let margin: CGFloat = 24
        static let gap: CGFloat = 20
        static var cell: CGFloat { (1024 - 2 * margin - 2 * gap) / 3 }
        static var radius: CGFloat { Radius.tile }
        static func tile(_ c: Int, _ r: Int, w: Int = 1, h: Int = 1) -> CGRect {
            CGRect(x: margin + CGFloat(c) * (cell + gap), y: margin + CGFloat(r) * (cell + gap),
                   width: CGFloat(w) * cell + CGFloat(w - 1) * gap, height: CGFloat(h) * cell + CGFloat(h - 1) * gap)
        }
        /// 標籤：名稱 semibold 31 白、狀態 semibold 31 白 60%；名稱基線＝磚底 − 98、狀態基線＝磚底 − 59
        static let labelSize: CGFloat = 31
        static let titleFromBottom: CGFloat = 98
        static let subFromBottom: CGFloat = 59
        static let subAlpha: CGFloat = 0.6
        /// 小磚的符號：中心離磚頂 103
        static let iconCenterFromTop: CGFloat = 103
        /// 溫控大數字：SF Pro 約 262、wght 500，基線離磚頂 375；左右箭頭中心離磚頂 556、離左右緣 92
        static let numberSize: CGFloat = 262
        static let numberBaseline: CGFloat = 375
        static let chevronY: CGFloat = 556
        static let chevronInset: CGFloat = 92
        /// 玻璃鐘：刻度 12 根一樣長，外緣 0.935 R、內緣 0.71 R、寬 0.058 R
        static let tickOuter: CGFloat = 0.935
        static let tickInner: CGFloat = 0.71
        static let tickWidth: CGFloat = 0.058
    }

    // MARK: 助理（ClioTalk 回答）版面：第三輪量自官方 siri-calendar／siri-cyanotype（1024 畫布）
    enum Assistant {
        /// 回答的底：純白（官方 #FFFFFF，不是 grouped 灰）；深色時純黑
        static var bg: NSColor { dark ? .black : .white }
        /// 珠（👀 膠囊變成的玻璃珠）：官方珠外框 x 460–563、y 22–123
        static let orbDiameter: CGFloat = 103
        static let orbCenter = CGPoint(x: 512, y: 72.5)
        /// 聆聽時珠長大（上緣不動）
        static let listenDiameter: CGFloat = 195
        static var orbTop: CGFloat { orbCenter.y - orbDiameter / 2 }
        /// 內文：字的起點（H 的豎筆量到 x 92；扣掉左側空白）、右緣（第 3 行排到 947）、第一行基線（大寫頂 154、高 42）、行距 70.2（官方 8 行大寫頂 154 → 645）
        static let textLeft: CGFloat = 91
        static let textRight: CGFloat = 958
        static let firstBaseline: CGFloat = 197
        static let lineHeight: CGFloat = 70.2
        /// 日期分區標題：比內文縮進一點（W 量到 x 107）；內文基線 → 標題基線 136；膠囊下緣 → 下一個標題基線 76；標題基線 → 膠囊上緣 24
        static let headerLeft: CGFloat = 107
        static let headerAfterText: CGFloat = 136
        static let headerAfterRow: CGFloat = 76
        static let rowAfterHeader: CGFloat = 24
        /// 膠囊列：左右內縮 46、單行高 113、兩行高 135（官方量到 427–540、641–775）
        static let rowInset: CGFloat = 46
        static let rowHeight: CGFloat = 113
        static let rowHeight2: CGFloat = 135
        /// 來源晶片：內文最後基線 → 晶片上緣 59、高 40、間距 8；晶片下緣 → 圖片卡 58；圖片卡圓角 48、左右內縮同膠囊列
        static let chipAfterText: CGFloat = 59
        static let chipHeight: CGFloat = 40
        static let chipGap: CGFloat = 8
        static let cardAfterChips: CGFloat = 58
        static let cardRadius: CGFloat = 48
        /// 跟進的玻璃膠囊（確認／取消、再試一次）浮在最底：離底 40
        static let actionsBottom: CGFloat = 40
        /// 有回答時的「想深一點」「留下」：88 px 玻璃圓鈕，跟珠同一條水平線、分在兩側（官方頂端這一條除了珠是空的；
        /// x 跟主畫面頭像的中心 874 對稱）
        static let topActionY: CGFloat = 72.5
        static let topActionLeadingX: CGFloat = 150
        static let topActionTrailingX: CGFloat = 874
    }

    // MARK: 版面
    /// 大標題那一列底下，內容從這裡開始（R1：y≈220）
    static let contentTop: CGFloat = 220
    static let contentWidth: CGFloat = 896

    /// 橫幅通知：左緣 64／右緣 960（HPGrid.App 同一條線）、離頂 56（同心圓角照上緣 inset；10-grid）
    static let bannerCard = CGRect(x: HPGrid.App.leading, y: 56, width: HPGrid.App.trailing - HPGrid.App.leading, height: 230)

    /// 第三輪：頂列角落控制的中心離螢幕左（右）緣與上緣 105——官方正面圖 recipe-overview 的 ✕ 量到圓心 (105, 105)、直徑 90、
    /// 右上「10:09」的中線也在 y 105、右緣 931；影片 v1 O-038（斜拍）量到 ≈ 0.09 W ≈ 92。不再放在螢幕圓角的圓心 (138, 138)
    static let cornerControlCenter: CGFloat = 105
    /// App 頂列：左上返回圓鈕（90 px，圓心 (105, 105)）、大標題的起點
    static let backButton: CGRect = {
        let s = Size.backButton, c = cornerControlCenter
        return CGRect(x: c - s / 2, y: c - s / 2, width: s, height: s)
    }()
    static var titleX: CGFloat { backButton.maxX + 24 }
    static var titleBaseline: CGFloat { backButton.midY + 20 }
    static var titleFont: NSFont { FaceType.sf(56, .bold, mono: false) }
}
