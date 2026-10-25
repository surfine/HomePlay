// HPDS 第三輪（R15）：App 用的 tokens——計時器錶盤、照片／媒體頁的頂列與邊距、家庭磚、正在播放。
// 全部是對官方原圖量到的值（1024 畫布；量法與誤差表見 …/scratchpad/real/r3a-*.txt，參考圖只在本機）：
//   timer.png（計時器）、recipe-overview.png（食譜封面）、home-light.png（家庭淺色）、
//   nowplaying-crop.png（透視校正後）、podcast-lyrics-art.png 右邊那台（全版封面）。
// 原則同 HPTokens：App 裡不寫死數字；這裡是新檔，免得跟外殼分支在 HPTokens.swift 撞車。

import AppKit

extension HPTokens {
    // MARK: 照片／媒體滿版頁（食譜封面、正在播放全版封面）
    /// 官方 recipe-overview：✕ 圓、兩顆膠囊、右上時間都離螢幕邊 61（四周同一個內縮）
    enum Media {
        static let inset: CGFloat = 61
        /// 左上 ✕：直徑 90，圓心 (106, 106)
        static let backButton = CGRect(x: inset, y: inset, width: 90, height: 90)
        /// ✕ 符號框＝直徑 × 0.5（字墨約 31 px）
        static let backSymbolScale: CGFloat = 0.5
        /// 右上時間：SF Pro semibold 38（數字高 27），右緣 1024 − 92、基線 119（跟 ✕ 圓心同一條水平中線）
        static let clockSize: CGFloat = 38
        static let clockRight: CGFloat = 1024 - 92
        static let clockBaseline: CGFloat = 119
        /// 標題、歌名、進度條的左緣（食譜 95、正在播放 90–94：取 93）
        static let textX: CGFloat = 93
        /// 分頁式全螢幕（食譜步驟，影片 v1 00:27.25）：頂列中央小標 semibold 30（基線 96）＋底下一排頁點（圓心 y 122、直徑 12、間距 13）；
        /// ✕ 與時間跟照片頁同位置。影片裡小標在 ✕ 的高度（基線約 96），但我們頂端中央永遠有 👀 膠囊（y 40–108），
        /// 所以小標與頁點整組往下移到膠囊底下（基線 158、頁點 184），不跟眼睛搶位置
        static let pageTitleSize: CGFloat = 30
        static let pageTitleBaseline: CGFloat = 158
        static let pageDotsY: CGFloat = 184
        static let pageDot: CGFloat = 12, pageDotGap: CGFloat = 13
        /// 照片上的次要文字：白色 plusLighter 疊在照片上（官方副標在橘色湯上變淡黃、在深色布上是灰：vibrancy，不是另外塗黃）
        static let vibrantAlpha: CGFloat = 0.42
    }

    // MARK: 計時器（官方 timer.png）
    /// 60 根刻度沿一個跟螢幕同心的圓角方形排一圈；每根都朝螢幕中心（徑向），角落的自然斜放。
    /// 刻度兩端各落在一個圓角方形上：外框內縮 56.5、圓角 96；內框內縮 94.5、圓角 87（圓弧近似，量自角落那幾根的端點）。
    enum TimerFace {
        static let ticks = 60
        static let outerInset: CGFloat = 56.5
        static let outerRadius: CGFloat = 96
        static let innerInset: CGFloat = 94.5
        static let innerRadius: CGFloat = 87
        /// 刻度粗 14、圓頭（直邊上總長 52＝線段 38＋兩個圓頭）
        static let tickWidth: CGFloat = 14
        /// 剩下的＝系統橘（深色 #FF9230，官方實測一模一樣）；過去的＝同一個橘 20%（#331C0A）
        static let elapsedAlpha: CGFloat = 0.2
        /// 錶盤永遠是黑底（官方白天照樣黑底，像 StandBy），所以橘色固定用深色版 #FF9230
        static let tint = srgb(0xFF9230)
        /// 剩餘時間：SF Pro（不是圓體）medium、比例數字，222（數字高 164）；基線 558。
        /// 不是置中：靠右對齊在一個「00:00」寬、置中的框裡（官方 10:56 的字墨偏右 12 px 正好是這樣；秒數跳動時右緣不動）
        static let timeSize: CGFloat = 222
        static let timeBaseline: CGFloat = 558
        /// 「15 MIN」：SF Pro semibold 58（大寫高 43）、全大寫、系統橘；基線 646
        static let labelSize: CGFloat = 58
        static let labelBaseline: CGFloat = 646
        /// 控制（＋、停止、其他計時器、✕、時間）平常藏起來，畫面跟官方一樣只有錶盤；點一下浮出，閒置這麼久再收
        static let chromeIdle: Double = 5
    }

    // MARK: 家庭（官方 home-light.png）
    /// 3×3 正方磚鋪滿：外距 20、磚 317、間距 16（20 + 3·317 + 2·16 = 1003）；連續圓角 58
    enum HomeGrid {
        static let margin: CGFloat = 20
        static let tile: CGFloat = 317
        static let gap: CGFloat = 16
        static let radius: CGFloat = 58
        /// 圖示：中心在磚頂 + 102、SF Symbol 的點數 95（量到的字墨高 76–98，依符號而異）
        static let glyphCenterY: CGFloat = 102
        static let glyphSize: CGFloat = 95
        /// 名稱 semibold 34（基線磚頂 + 214）、房間 regular 32（基線磚頂 + 257），置中
        static let titleSize: CGFloat = 34
        static let titleBaseline: CGFloat = 214
        static let subtitleSize: CGFloat = 32
        static let subtitleBaseline: CGFloat = 257
        /// 家的顏色（官方淡紫）：開著的磚＝淡色底、圖示與名稱同色系深一階、房間更淡
        static var onFill: NSColor { dark ? srgb(0x3A3752) : srgb(0xC5C1E4) }
        static var onInk: NSColor { dark ? srgb(0xC5C1E4) : srgb(0x807BAF) }
        static var onSub: NSColor { dark ? srgb(0x8D89B3) : srgb(0xA39EC8) }
        /// 關著的磚：淺灰底、深灰圖示與名稱、灰房間
        static var offFill: NSColor { dark ? srgb(0x1C1C1E) : srgb(0xE8E8E8) }
        static var offInk: NSColor { dark ? srgb(0xD1D1D6) : srgb(0x737375) }
        static var offSub: NSColor { dark ? srgb(0x8E8E93) : srgb(0xA7A7A8) }
        /// 底：淺色純白、深色純黑
        static var background: NSColor { dark ? .black : .white }
    }

    // MARK: 正在播放（nowplaying-crop.png 透視校正到 1024 後量的；全版封面量自 podcast-lyrics-art 右邊那台）
    enum NowPlaying {
        /// 歌名 semibold 60（大寫高 42）基線 653、演出者 regular 40 基線 708
        static let titleSize: CGFloat = 60
        static let titleBaseline: CGFloat = 653
        static let artistSize: CGFloat = 40
        static let artistBaseline: CGFloat = 708
        static let artistAlpha: CGFloat = 0.6
        /// 進度條：x 90…934、中線 767、粗 10；已播白、未播白 30%
        static let bar = CGRect(x: 90, y: 762, width: 844, height: 10)
        static let restAlpha: CGFloat = 0.3
        /// 底色：封面兩點取色的直向漸層，壓到亮度 0.36 → 0.07（官方控制列底下幾乎是黑 #120B09）
        static let backgroundTop: CGFloat = 0.36, backgroundBottom: CGFloat = 0.07
        /// 時間：medium 28、基線 816（左右對齊進度條兩端），白 60%
        static let timeSize: CGFloat = 28
        static let timeBaseline: CGFloat = 816
        /// 「…」：直徑 47，圓心 (903, 650)（跟演出者那行同高，右緣對齊進度條）；淺灰實心圓＋深色三點（iOS 的 ellipsis.circle.fill）
        static let more = CGRect(x: 880, y: 626, width: 47, height: 47)
        /// 控制列中線 891：歌詞泡泡 118、倒退 290、暫停 511、快進 733、佇列 902。
        /// 下面是 SF Symbol 的框高（量到的字墨：泡泡 63×59、倒退／快進 84×47、暫停 60×82、佇列 56×40；符號圖本身有留白，框要大約 1.25 倍）
        static let controlsY: CGFloat = 891
        static let lyricsX: CGFloat = 118, backX: CGFloat = 290, playX: CGFloat = 511, forwardX: CGFloat = 733, queueX: CGFloat = 902
        static let lyricsH: CGFloat = 71, skipH: CGFloat = 60, playH: CGFloat = 100, queueH: CGFloat = 52
        /// 「…」符號框比圓大 1.26 倍（ellipsis.circle.fill 有留白；量到的圓直徑 47–48）
        static let moreSymbolScale: CGFloat = 1.26
        /// 次要控制（泡泡、佇列）白 60%
        static let secondaryAlpha: CGFloat = 0.6
        /// 全版封面（閒置時）：歌名 semibold 58 基線 865、演出者 regular 37 基線 918，白 75%
        static let ambientTitleSize: CGFloat = 58
        static let ambientTitleBaseline: CGFloat = 865
        static let ambientArtistSize: CGFloat = 37
        static let ambientArtistBaseline: CGFloat = 918
        static let ambientArtistAlpha: CGFloat = 0.75
        /// 播放中閒置這麼久，控制收起、封面鋪滿（點一下回來）
        static let ambientAfter: Double = 12
    }

    // MARK: 食譜封面（recipe-overview.png）
    enum RecipeCover {
        /// 標題 SF Pro bold 57（大寫高 40）基線 729；副標 regular 31 基線 782（vibrancy）
        static let titleSize: CGFloat = 57
        static let titleBaseline: CGFloat = 729
        static let titleLineHeight: CGFloat = 66
        static let subtitleSize: CGFloat = 31
        static let subtitleBaseline: CGFloat = 782
        /// 兩顆 Clear 玻璃膠囊：高 125、間距 22，左右底都內縮 61（Media.inset）
        static let buttonHeight: CGFloat = 125
        static let buttonGap: CGFloat = 22
        /// 膠囊上的字 regular 36（官方字寬是 SF Pro Text 的寬字形；大寫高 24–26）＋符號（框 50，字墨寬約 39），白
        static let buttonLabelSize: CGFloat = 36
        static let buttonSymbolSize: CGFloat = 50
        static var buttons: [CGRect] {
            let i = Media.inset, h = buttonHeight, w = (1024 - 2 * i - buttonGap) / 2, y = 1024 - i - h
            return [CGRect(x: i, y: y, width: w, height: h), CGRect(x: i + w + buttonGap, y: y, width: w, height: h)]
        }
    }

    // MARK: 歌詞（第四輪 #8；官方 podcast-lyrics-art 中間那台，透視校正後量）
    enum Lyrics {
        /// 字：SF Pro bold 66（透視校正後量：「She's from Texas, I can tell」字寬 795 → 66–68；不是斜體，斜是相機透視）；
        /// 左緣 76、右邊留 90（「I wasn't a match for that」在 860 換行）
        static let size: CGFloat = 66
        static let x: CGFloat = 76
        static var width: CGFloat { 1024 - x - 90 }
        /// 同一句換行的列高 90、句與句之間多 28（量到列距 85–95、句距 115–125）
        static let lineHeight: CGFloat = 90
        static let lineGap: CGFloat = 28
        /// 目前那句的列頂 385（基線 455）；畫面上下邊界（之外淡出）
        static let anchor: CGFloat = 385
        static let top: CGFloat = 70
        static let bottom: CGFloat = 990
        /// 控制浮出時歌詞只畫到這裡（下面是歌名、進度與控制列）
        static let bottomWithControls: CGFloat = 470
        /// 透明度：目前 1；隔一句 0.4（量到 0.39），每遠一句再減 0.07，最低 0.18；純文字一律 0.8
        static let nearAlpha: CGFloat = 0.4
        static let alphaStep: CGFloat = 0.07
        static let minAlpha: CGFloat = 0.18
        static let plainAlpha: CGFloat = 0.8
        /// 模糊：每遠一句 σ 多 1.6，最多 4 級（σ 6.4）；字圖四周留 24 給模糊暈開
        static let blurStep: Double = 1.6
        static let blurLevels = 4
        static let blurPad: CGFloat = 24
        /// 換句提早 0.15 s（捲動要時間；官方也是句子還沒唱就先亮）
        static let lead: Double = 0.15
        /// 捲到下一句：臨界阻尼 response 0.5（Apple .smooth）
        static let scrollSpring = Spring(damping: 1, response: 0.5)
        /// 間奏（空白的同步行）畫成這個
        static let gapMark = "•  •  •"   // l10n-ignore
        /// 糊掉的封面上再壓 30% 黑（官方歌詞底是暗紫棕）
        static let dim: CGFloat = 0.3
    }

    // MARK: 播客正在播放（第四輪 #11；官方 podcast-lyrics-art 左邊那台）
    enum Podcast {
        /// 節目名（官方是日期）在單集名上面：regular 34、白 60%，基線 650；單集名 semibold 56 基線 708（跟音樂的演出者同一行）
        static let showSize: CGFloat = 34
        static let showBaseline: CGFloat = 650
        static let titleSize: CGFloat = 56
        static let titleBaseline: CGFloat = 708
        /// 後退 15／快轉 30 的符號框高（gobackward.15 有圓圈，比 backward.fill 高）
        static let skipH: CGFloat = 78
        /// 倍速字：semibold 36，白 60%（官方「1x」在佇列的位置）
        static let rateSize: CGFloat = 36
    }

    // MARK: FaceTime（第四輪 #10；官方 lineup5.png 第二台，透視校正到 1024 後量）
    enum FaceTime {
        /// 底下一排四顆圓鈕：直徑 156，左右底都內縮 61（Media.inset），圓心等距：x 139／388／636／885、y 885
        static let control: CGFloat = 156
        static var controls: [CGRect] {
            let d = control, i = Media.inset, cy = 1024 - i - d / 2
            let x0 = i + d / 2, step = (1024 - 2 * x0) / 3
            return (0..<4).map { CGRect(x: x0 + CGFloat($0) * step - d / 2, y: cy - d / 2, width: d, height: d) }
        }
        /// 左上名字：SF Pro regular 68、白，左緣 93、基線 182（官方「Mari」透視校正後大寫高約 50、左緣約 100、基線約 185）；
        /// 狀態 regular 32、白 75%，基線 230
        static let nameSize: CGFloat = 68
        static let nameX: CGFloat = Media.textX
        static let nameBaseline: CGFloat = 182
        static let nameMaxX: CGFloat = 640
        static let statusSize: CGFloat = 32
        static let statusBaseline: CGFloat = 230
        /// 右上自己的小窗：300 見方、連續圓角 50，右上內縮 61
        static let pip = CGRect(x: 1024 - Media.inset - 300, y: Media.inset, width: 300, height: 300)
        static let pipRadius: CGFloat = 50
        /// 符號色（官方：白底上的綠攝影機、橘麥克風；紅色結束）＝系統色淺色版
        static let callGreen = srgb(0x34C759)
        static let micOrange = srgb(0xFF8D28)
        static let endRed = srgb(0xFF383C)
        /// 白鈕、紅綠鈕在玻璃上再鋪的實色濃度（官方量到白 #FDFDFC、紅 #D70F0C：比 HPDS 染色玻璃上限 0.82 更實）
        static let whiteFill: CGFloat = 0.96
        static let tintFill: CGFloat = 0.88
        /// 名單：搜尋膠囊（高 88）在大標題下；列高 128、頭像 84；分區標題到卡片 64、卡片到下一個分區 40；最近通話最多 3 筆
        static let searchRect = CGRect(x: HPTokens.Space.margin, y: 196, width: HPTokens.contentWidth, height: 88)
        static let listTop: CGFloat = 304
        static let rowHeight: CGFloat = 128
        static let avatar: CGFloat = 84
        static let sectionGap: CGFloat = 64
        static let sectionAfter: CGFloat = 40
        static let maxRecents = 3
    }
}

// MARK: - P10：尋找、對講、Safari、家庭攝影機九路
// 官方沒有這幾頁的畫面（handson.md：只知道有這三個內建 App、Home Camera 最多九路），
// 照 iOS 27 的同名元件推斷（realref/ios27：safari-scrolled、maps-bottom-sheet），按 1:1 螢幕放大約 2.2 倍。
extension HPTokens {
    /// 尋找：大標題底下分段（成員／裝置）、地圖卡、清單
    enum FindMy {
        static let segment = CGRect(x: Space.margin, y: 196, width: contentWidth, height: 88)
        /// 地圖卡（內容，不上玻璃）：圓角跟分組卡一樣
        static let map = CGRect(x: Space.margin, y: 308, width: contentWidth, height: 330)
        static let listTop: CGFloat = 662
        static let rowHeight: CGFloat = 116
        static let icon: CGFloat = 76
        /// 地圖上的大頭針：白圈直徑、裡面的色圓直徑（iOS「尋找」的裝置釘）
        static let pin: CGFloat = 84
        static let pinInner: CGFloat = 68
        /// 細節頁：地圖高、兩顆膠囊鈕
        static let detailMap = CGRect(x: Space.margin, y: 220, width: contentWidth, height: 420)
        static let detailButtonY: CGFloat = 700
        static let buttonHeight: CGFloat = 104
    }
    /// 對講：中間黃色大麥克風圓鈕（官方攝影機頁的對講鈕是黃的，HPDS「黃＝麥克風」）、外圈電平刻度（照官方對講圖示的直條排成圓）
    enum Intercom {
        static let talkCenter = CGPoint(x: 512, y: 540)
        static let talk: CGFloat = 240
        static let ringInner: CGFloat = 150
        static let ringOuter: CGFloat = 230
        static let bars = 36
        static let outputBaseline: CGFloat = 262
        static let captionBaseline: CGFloat = 812
        static let lastRow = CGRect(x: 112, y: 846, width: 800, height: 104)
        /// 最長錄 30 秒（跟 HomePod 對講差不多的長度）
        static let maxSeconds = 30.0
        static let holdThreshold = 0.35
    }
    /// Safari：底部三件分開的玻璃（‹ 圓鈕、網址膠囊、› 圓鈕；iOS 27 safari-scrolled），跟左上返回鈕上下對稱
    enum Safari {
        static let barCenterY: CGFloat = 1024 - cornerControlCenter
        static let circle: CGFloat = 96
        static let gap: CGFloat = 16
        static var back: CGRect { CGRect(x: cornerControlCenter - circle / 2, y: barCenterY - circle / 2, width: circle, height: circle) }
        static var forward: CGRect { CGRect(x: 1024 - cornerControlCenter - circle / 2, y: barCenterY - circle / 2, width: circle, height: circle) }
        static var field: CGRect { CGRect(x: back.maxX + gap, y: barCenterY - circle / 2, width: forward.minX - gap - back.maxX - gap, height: circle) }
        /// 網頁畫在 👀 膠囊底下到螢幕底（工具列浮在網頁上）
        static let webTop: CGFloat = 150
        /// 網頁視圖的點數＝畫布 ÷ 2；字放大 1.5 倍（遠看：內文約 48 px）
        static let pointsPerCanvas: CGFloat = 0.5
        static let pageZoom: CGFloat = 1.5
        /// 閱讀器：標題 bold 56、內文 regular 46、行距 1.3 倍
        static let readerTitle: CGFloat = 56
        static let readerBody: CGFloat = 46
        static let readerTop: CGFloat = 220
        /// 「開始烹飪」膠囊浮在工具列上面
        static var cook: CGRect { CGRect(x: 512 - 220, y: barCenterY - circle / 2 - 24 - 104, width: 440, height: 104) }
        /// 起始頁：喜好項目 4 欄字母磚
        static let tile: CGFloat = 164
        static let tileTop: CGFloat = 300
    }
    /// 家庭攝影機頁：五路以上排 3×3（官方 Home Camera 錶面九路）；11-grid-apps：格線對齊 App 內容區 64…960（x=64、gap=16 → 磚 288×162）
    enum HomeCameras {
        static let max = 9
        static let gridColumns = 3
        static let x: CGFloat = Space.margin, gap: CGFloat = 16
        static let labelGap: CGFloat = 64
    }
}
