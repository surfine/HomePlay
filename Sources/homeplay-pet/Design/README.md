# HPDS v1：HomePlay 自己的設計系統

HPDS 是 HomePlay 2 所有畫面共用的那一層：外殼、內建 App、ClioTalk 都只從這裡拿顏色、字、間距、圓角、玻璃、動畫與元件，App 裡不寫死數字。它從官方影片、官方圖、Chan Karunamuni 的講題與 HIG、Designing Fluid Interfaces 學來，消化成我們自己的程式（計畫見 `docs/plans/hpds.md`）。Apple 的實作只當校準用的尺：對照用 `tooling/refcompare.py`，參考圖只在本機，不進版本庫。

所有數字都是 **1024 × 1024 畫布單位**（左上原點、y 往下）。螢幕在桌面上只有 130–900 pt 寬，所以字是 iPhone 的 2–3 倍。

## 檔案

| 檔案 | 內容 | 舊名（typealias，照樣編得過） |
| --- | --- | --- |
| `HPTokens.swift` | 顏色（淺／深）、間距、圓角、陰影、尺寸、頂列版面、助理回答／主畫面／家庭模組版面 | `Theme` |
| `HPType.swift` | 字級表、SF Pro 取字、放不下就縮、中英混排 | （AppUI.font／RealUI.sf 轉到這裡） |
| `HPGlass.swift` | 控制層的玻璃：收集、分組、合成、按下、materialize；種類與參數表 | `GlassPass`、`GlassPassShim` |
| `HPMotion.swift` | `Spring`、`MotionValue`、`HPMotion`（投射、rubber band、凍結）、`Press`、`Anim`、`PageTransition`、`AppMotion` | `Motion` |
| `HPComponents.swift` | 頂列、圓鈕、膠囊鈕、分段、開關、文字分頁、晶片、清單、家庭磚、小工具框、膠囊列、空狀態 | `RealUI`（`AppUI` 的開關、字也轉到這裡） |
| `HPIcons.swift` | 自己畫的 App 圖示：主畫面與 App 資料庫的每一個（第四輪起不讀系統 App 圖示） | （原 AppIconArt 的系統圖示＋drawGlassy） |
| `HPAvatar.swift` | 👀 人物頭像（臉型、髮型、髮色、膚色、底色；12 個預設） | （原縮寫圓） |
| `HPSelfTest.swift` | `--selftest` 裡的 HPDS 檢查 | — |
| `HPTokens+Hello.swift` | 開機 hello 的顏色（漸層節點、紅色色塊、筆畫加亮量、夜間壓暗；量法見 docs/plans/hello.md） | — |

底層照舊在 `Faces/`：`FaceType`／`Typo`（SF Pro 可變軸）、`Screen`／`continuousRoundedRect`（螢幕形狀）、`SystemGlass`／`LiquidGlass`（玻璃引擎）。HPDS 只包它們，不重寫。新程式用 `HP*` 名字；舊名留給還沒遷的檔案（`Faces/`、`main.swift` 刻意沒動，避免跟錶面分支衝突）。

## Tokens

### 顏色

文字色照 iOS（HomeView 是 iOS 系），不用 macOS 的 85% labelColor。`HPTokens.dark` 由夜間偵測或 `--appearance dark` 決定；白天 App 一律淺色。

| token | 淺色 | 深色 | 用在 |
| --- | --- | --- | --- |
| `bg` | #F2F2F7 | #000000 | App 底（systemGroupedBackground） |
| `card` | #FFFFFF | #1C1C1E | 分組卡 |
| `card2` | #E5E5EA | #2C2C2E | 卡上再一層 |
| `label` | #000000 | #FFFFFF | 主文字 |
| `secondary` | #3C3C43 60% | #EBEBF5 60% | 次要文字 |
| `tertiary` | #3C3C43 30% | #EBEBF5 30% | chevron、停用 |
| `separator` | #3C3C43 29% | #545458 60% | 列間 2 px 線 |
| `fill` | #787880 20% | #787880 36% | 玻璃上的開關磚、滑桿軌道（不准玻璃疊玻璃） |
| `onMedia` | #FFFFFF | #FFFFFF | 照片、封面、攝影機上的字 |

系統色是 macOS 27 實測（`NSColor.system*` 轉 sRGB）：

| 色 | 淺色 | 深色 | | 色 | 淺色 | 深色 |
| --- | --- | --- | --- | --- | --- | --- |
| red | #FF383C | #FF4245 | | teal | #00C3D0 | #00D2E0 |
| orange | #FF8D28 | #FF9230 | | cyan | #00C0E8 | #3CD3FE |
| yellow | #FFCC00 | #FFD600 | | indigo | #6155F5 | #6D7CFF |
| green | #34C759 | #30D158 | | pink | #FF2D55 | #FF375F |
| blue | #0088FF | #0091FF | | brown | #AC7F5E | #B78A66 |
| purple | #CB30E0 | #DB34F2 | | gray | #8E8E93 | #98989D |
| mint | #00C8B3 | #00DAC3 | | | | |

顏色少用：只給狀態與主要動作；強調主要動作時染**玻璃的底**，不染字或符號。內容色彩豐富時（照片、封面），控制用單色白。

### 間距 `HPTokens.Space`

8 的倍數，加上影片量到的幾個值。

| token | 值 | 用在 |
| --- | --- | --- |
| `xxs` | 8 | 最小間隔 |
| `panelInset` | 14 | 主畫面玻璃面板離螢幕邊、官方家庭磚間距 |
| `s` | 16 | 一般內距 |
| `gap` | 20 | 錶面頁縫、家庭磚間距（影片 v2） |
| `m` | 24 | 返回鈕到大標題 |
| `l` | 32 | 段落間 |
| `widgetPad` | 30 | 小工具內距（16 pt） |
| `column` | 60 | 主畫面欄距（影片 v1） |
| `margin` | 64 | App 內容左右邊距 |
| `homeMargin` | 114 | 主畫面網格左右邊距（影片 v1） |

版面：大標題列底下內容從 `contentTop` = 220 開始，內容寬 `contentWidth` = 896。

### 圓角 `HPTokens.Radius`

只有三種：固定、膠囊、同心。不要捏角或張角。

| token | 值 | 說明 |
| --- | --- | --- |
| `screen` | ≈ 138 | 機身螢幕的連續曲率圓角（量自 usdz），所有同心圓角的根 |
| `screenDiagonalInset` | ≈ 40.8 | 螢幕角在 45° 方向的內縮；官方圖量到約 40，遮罩沿用 |
| `concentric(inset:)` | 138 − inset（≥ 12） | 靠近螢幕角的卡片、磚、面板 |
| `concentric(parent:padding:)` | 父半徑 − 內距 | 父元件不是螢幕時 |
| `capsule(r)` | 高 ÷ 2 | 按鈕、膠囊列、分段 |
| `group` | 52 | inset grouped 卡片 |
| `tile` | 50 | 家庭磚（影片 49–50） |
| `widget` | 50 | 主畫面 small 小工具（第三輪照官方主畫面 Photos 小工具） |

形狀一律用 `continuousRoundedRect`（iOS 的連續曲率係數），膠囊用半圓。角落的控制（返回鈕、右上時間）讓圓心落在螢幕圓角的圓心上（`Screen.cornerCapsuleCenter`）。

### 陰影 `HPTokens.Shadow`

| token | offset | blur | 黑的不透明度 | 用在 |
| --- | --- | --- | --- | --- |
| `card` | (0, 4) | 18 | 0.12 | 開著的家庭磚、淺色卡片浮起 |
| `knob` | (0, −2) | 6 | 0.25 | 開關、滑桿旋鈕 |
| `segment` | (0, 2) | 8 | 0.12 | 分段控制選中的膠囊（淺色） |
| `glassSmall` | (0, −5) | 22 | 0.10–0.30 | 小玻璃的外陰影（HPGlass 依底下內容調） |
| `glassLarge` | (0, −10) | 40 | 0.10–0.30 | 面板玻璃的外陰影 |

### 尺寸 `HPTokens.Size`

點按範圍至少 88（44 pt）；返回圓鈕 88；主要動作圓鈕 150（影片 150–162）；主畫面圖示 150；家庭磚 300。

### 助理回答 `HPTokens.Assistant`（第三輪量自官方 siri-calendar／siri-cyanotype）

| token | 值 | 說明 |
| --- | --- | --- |
| `bg` | #FFFFFF／#000000 | 回答的底是純白，不是 grouped 灰 |
| `orbCenter`、`orbDiameter` | (512, 72.5)、103 | 👀 膠囊在 ClioTalk 裡直接變成這顆珠（材質換成玻璃珠，眼睛不改）；聆聽時 195、上緣不動 |
| `textLeft`、`textRight` | 91、958 | 內文字級 59（`HPType.Size.answer`）、第一行基線 197、行距 70.2 |
| `headerLeft` | 107 | 日期分區標題 semibold 35；內文基線 → 標題基線 136；膠囊下緣 → 下一個標題基線 76；標題基線 → 膠囊上緣 24 |
| `rowInset`、`rowHeight`、`rowHeight2` | 46、113、135 | 膠囊列 |
| `chipAfterText`、`chipHeight`、`cardAfterChips`、`cardRadius` | 59、40、58、48 | 來源晶片與圖片卡 |
| `actionsBottom` | 40 | 第四輪：有回答時畫面完全照官方，**沒有按鈕**——「留下」「記住這個」「想深一點」「再說詳細一點」用說的（`ClioAnswerCommand`），點 👀 珠＝繼續問；第一次出現回答時底部淡淡一行提示（caption、tertiary），之後不再出現（`clio.answerHintShown`）。確認、出錯、還沒回答時照舊用底下膠囊。（`topAction*` 不再使用） |

### 主畫面 `HPTokens.Home`

第五輪（官方 home-screen-erica 正視校正後量，稽核見 scratchpad/real/r5-home-audit.md）：問候語 32、全大寫、字距 +1 px，第一行 regular 白 60%、名字那行 semibold 白 82%，基線 139／182，原點比圖示左緣內縮 9；頭像直徑 100（中心 874, 152）、沒有描邊；網格圖示 152、左右邊距 98.5、欄距 225、首列頂 241、列距 240；圖示標籤 regular 30、白、沒有投影，基線＝圖示底 + 41；小工具是兩列高的正方形（391²）、置中在第 2–3 欄，圓角 `Radius.widget` 56；桌布＝錶面模糊 σ 18、亮度 × 0.72（平均亮度不超過 0.45）；面板內 14、裡面壓暗 15%，再疊厚玻璃亮邊（`HPGlass.panelRim`：2 px 亮線＋往內 24 px 內光）。行事曆圖示跟著 `Face.displayDate`，靜態層的 key 含日期，午夜換日重畫。

### 家庭模組錶面 `HPTokens.HomeModular`

第四輪：背景是程式生成的硬邊幾何桌布（`HomeModularWallpaper`：左下放射的扇形色塊＋沿長邊折成亮暗兩面的稜柱帶＋大三角；綠、紫、藍、琥珀，`homeModular.color`／`--homemod-color`），磚的斜邊把直線折彎，玻璃看得出來。3×3 玻璃磚：外距 24、間距 20、每格 312、圓角＝`Radius.tile` 50（官方的磚不跟螢幕同心）；溫控 2×2，大數字 262／wght 500、基線離磚頂 375；左右箭頭中心離磚頂 556、離左右緣 92；標籤兩行同字級 semibold 31（狀態白 60%），基線＝磚底 − 98／− 59；小磚符號中心離磚頂 103；玻璃鐘 12 根一樣長的刻度（0.71–0.935 R）。玻璃是控制式折射：只有邊緣 24 px 斜面在彎，磚裡的圖樣清楚。

### 圖示 `HPIcons`

主畫面、App 資料庫、App 開關的過場都只畫 HPIcons（第四輪進口替代：不再讀 `/System/Applications` 的圖示）。每個圖示三層：底（上亮下深的漸層）、主體（浮在底上、帶底色深一階的柔影）、亮邊（頂緣最亮；白底的換成很淡的灰邊）。`Shell.drawAppIcon(…, appID:)` 先照 App id（`HPIcons.kind(forID:)`，FaceTime＝`facetime`、對講＝`intercom`），再照 SF Symbol。

| 圖示 | 底（上 → 下） | 主體 |
| --- | --- | --- |
| 鬧鐘、計時器、世界時鐘 | #F19E42 → #EF7F32 | 奶白 #FDF8F1 粗線條（圓環寬 0.072、半徑 0.335） |
| 行事曆（動態） | #FFFFFF → #F4F4F6 | 星期 semibold 0.165 紅 #E8433C、日期 regular 0.58 |
| FaceTime、訊息 | #83EC7C → #61CD53 | 白綠攝影機（機身＋梯形鏡頭）／對話泡泡 |
| 家庭、對講、提醒事項 | #FFFFFF → #F4F4F6 | 三層橘房子／9 根橘直條排成圓＋小點／三色圓圈＋灰線 |
| 音樂 | #EE4A62 → #EB333B | 白色雙八分音符 |
| Podcast | #883FBD → #692D8F | 三圈淡紫聲波＋人形麥克風 |
| 設定 | #9D9CA1 → #77767C | 兩層齒輪＋三根輻條 |
| 天氣 | #569BFA → #3771D2 | 黃太陽在後、白雲在前 |
| 尋找、Safari（P10 退路：Mac 上有系統圖示、官網有圖示時不用） | #5DD56C → #2FB146／#FFFFFF → #F4F4F6 | 白色同心圈＋綠點／藍錶盤＋紅白指針 |
| ClioTalk（我們自己的） | #2E2C38 → #111116 | 紫到粉的聲波 |

2.0 P10：食譜併進 Safari（跟官方一樣），食譜不再有自己的圖示（`AppRegistry.hidden`，主畫面與 App 資料庫都沒有；存過的排列把「食譜」換成 Safari）。

底色兩端對官方清單量過（ΔE2000 ≤ 3，`--hpicons-png` 出圖對照）；形狀是自己畫的，不描圖。

### 頭像（第五輪：`People/AvatarSources.swift`＋`HPAvatar`）

預設「自動」：這台 Mac 使用者的帳號頭像（Collaboration `CBUserIdentity(posixUID:authority:).image`，跟 Apple 帳號同步那張）→ 聯絡人「我」的照片（已授權才讀）→ Apple 式灰色漸層縮寫圓（#A5AAB6 → #858A96、白字 medium）。家人沒選就縮寫。👀 人物（臉型、髮型、髮色 7、膚色 6、底色 8；12 個預設）只在「家人」設定頁選「👀 頭像」才用。快照、`--demo-official`、設定截圖不讀真的照片；`--demo-official` 用紫底的示範 👀 頭像。

## Type

一律 SF Pro（不用圓體）；大數字才用等寬（`HPType.numeric`，預設 light，照 iOS 時鐘、天氣）。字體由系統提供（SF Pro、SF Compact、PingFang），不打包。底層會照螢幕上的實際字級選光學尺寸與 trak 字距、深底白字補 GRAD。

| `HPType.Size` | 值 | 字重 | 用在 |
| --- | --- | --- | --- |
| `hero` | 150 | semibold／light | 計時器全螢幕剩餘時間 |
| `display` | ≥ 100 | light／regular | 遠看的主資訊：倒數、鬧鐘時間、溫度 |
| `title` | 56 | bold | App 大標題（返回鈕旁邊） |
| `body` | 56（–60） | regular（重點詞 bold） | 回答、食譜步驟內文 |
| `list` | 42（40–44） | regular／semibold | 列表主文字 |
| `section` | 38 | bold | 分區標題（可加 chevron） |
| `button` | 36 | semibold | 膠囊鈕上的字 |
| `clock` | 32 | semibold | 右上時間 |
| `secondary` | 30（30–32） | regular | 次要文字、分組小標題 |
| `iconLabel` | 30 | medium／semibold | 主畫面圖示標籤 |
| `caption` | 28 | medium | 最小：圓鈕下的說明 |

光學尺寸與 trak 字距照 HomeView 本機上的字級選（`Typo.devicePointsPerUnit` 0.62 pt／單位：約 32 單位以上拿 Display、以下漸到 Text），不照桌面視窗大小——第三輪對官方圖量到的。主要文字不低於 34、次要不低於 28；避免細體（遠看會斷）。放不下就用 `HPType.fitted` 縮（最小 0.7 倍），再不行用 `Face.clipped` 加刪節號。

**中英混排**

- 中文字形跟介面語言：簡體介面 PingFang SC，其餘（含繁體、英文介面裡的中文）PingFang TC；退回字體照字重挑同粗細的蘋方。
- 中文與英文、數字之間的半形空格寫在字串裡（「2 小時 46 分鐘」「3 樓 會議室 B」），排版不自動加。
- 中文用全形標點；英文句子裡用半形。
- 字距只照 SF Pro 的 trak 表，不另外加；只有全大寫英文標籤（問候語、「15 MIN」）另給 +0.5～+1.5。
- 中文沒有斜體、不做假粗體；強調用 semibold／bold。
- 行高：英文 1.2 倍字級、有中文 1.3 倍（`HPType.lineHeight`）。

## Glass

玻璃只在**控制層**（導覽與控制）；內容（錶面、列表、卡片、磚、小工具底）不用玻璃。App 與外殼只呼叫 `HPGlass.add`／`addCapsule`（形狀＋染色＋玻璃上的內容），畫完內容層之後 `flush` 一次：用那一刻的畫面當唯一背景（玻璃不取樣玻璃），照「種類／染色／按著／融合組」分組，交給 SystemGlass（macOS 27 自己的 Liquid Glass 零件）；拿不到就退回自己的 LiquidGlass shader，再不行畫半透明仿製品。

| 種類 | 什麼時候用 | 參數 |
| --- | --- | --- |
| **Regular**（預設） | 淺色與深色畫面上所有控制：返回鈕、膠囊鈕、分段軌道、控制中心面板、ClioTalk 鈕 | NSGlassEffectView `.regular` 量到的值；深色用 darkAqua 那組（`SystemGlassParams.regular`／`regularDark`） |
| **Clear** | 只在媒體上：照片錶面、Now Playing 封面、攝影機全螢幕、模糊錶面上的主畫面 | `.clear` 量到的值（`clearControl`）；亮背景上先加 0–35% 局部壓暗，符號一律白 |
| **染色** | 只給主要動作（紅＝結束、黃＝麥克風、綠＝開始、藍＝確認），每個畫面最多 2 個 | Regular＋色進面色矩陣（不透明度上限淺 0.82／深 0.72、black ≥ 0.25），不是實色 |

規則：

- **Regular 與 Clear 不混用**，一個畫面一種。
- **不准玻璃疊玻璃**：控制中心模組、ClioTalk 卡、Live Activity 展開版、小工具「裡面」的開關與滑桿用 `fill`＋vibrant 白。
- **小元件自己翻淺深**：短邊 ≤ 200 的形狀依背後平均亮度翻（> 0.6 淺、< 0.4 深，中間維持上次，不閃）；上面的字與符號用 `HPGlass.ink`。大的跟 `HPTokens.dark`。不加外框。
- **外陰影自適應**：底下有字（邊緣多）就濃、純淡色就淡（0.10–0.30），顏色取底下平均色壓暗。
- **靜止時不融合**；只有同一個 union 名字的形狀在變形動畫中融合（距離 14），例如 ClioTalk 的珠從 👀 膠囊滴下。
- **出現／消失要 materialize**：presence 0→1 時折射、模糊、面、高光一起長出，形狀 0.96→1；只有內容用透明度。
- **按下**：mouse down 那一幀放大 1.08、亮邊亮起、從觸點亮起一圈往外擴散；放開回彈；拖出範圍取消。
- 狀態文字、大標題、時間不放玻璃。
- **例外：FaceTime 的通話控制照 FaceTime 本身**（第六輪，使用者決定 #3）。撥號與通話中的那一排鈕不套上面「染色玻璃、每畫面最多 2 個」的規則，照官方 FaceTime：攝影機＝白底綠符號（green）、麥克風＝白底橘符號（orange），「…」更多＝Regular 玻璃，掛斷＝實心紅底（red）白符號。只有這一排是例外；同一個畫面的其他控制（返回鈕、名字、狀態字）照常走 Glass 規則。

`HPGlass.params(_:darkGlass:)` 給出每一種的系統參數；HPGlass（自製 Metal 光學 shader）對齊 SystemGlass 到 ΔE ≤ 3 之前，SystemGlass 是預設，自製版是退路。

**玻璃引擎（2.0 glass）**：控制層的玻璃先走 `NativeGlass`（`Faces/SystemGlassNative.swift`）——在不上螢幕的視窗裡擺真的 `NSGlassEffectView`／`NSGlassEffectContainerView`，背景當根層的 contents，整棵樹用 CARenderer 離屏畫。尺寸規律（折射帶、bleed、模糊、深色 maxLuma、Clear 的 shadow 都跟短邊走）、backdrop 0.5 取樣、連續曲率、染色子樹、容器的 smooth union 都是系統自己的。只有非圓角矩形的形狀把 element 換成距離場圖。拿不到（非主執行緒、`HOMEPLAY_GLASS=legacy`）才退回自拼的 `SystemGlass`。

- 畫布與 pt：`SystemGlassParams.ptToCanvas`＝1.88（HomeView 544 pt ≈ 1024 畫布）。
- 貼回去時裁切外擴 0.75 pt（`HPGlass.nativeOutset`），留住系統玻璃緣外約 1 px 的暗邊。
- 靜止的亮緣：`HPGlass.restRim`＝1（系統 @2 高光層的 opacity）。macOS 靜止是 0；HomeView／iOS 官方圖靜止就有，所以產品用 1、校準台用 0。
- materialize：形狀從 1.05 倍收到 1（`materializeScale`），光學量從 0 長出來。這是校準台拍 SwiftUI 玻璃插入量到的，不是 0.96 → 1。
- 融合：遮罩用同一個 smooth union（多項式 smin，k＝spacing），跟容器的 CASDFLayer smoothness 一致。
- 校準：`homeplay-pet --glass-calibrate DIR` 會拍真的 NSGlassEffectView 並畫我們的版本，再用 `uv run --with numpy --with pillow --with matplotlib python tooling/glass-compare.py DIR` 比對。目標是形狀內 ΔE2000 ≤ 2、邊緣剖面位移 ≤ 1 px。
- 離屏視窗的根 view 不當 contentView：視窗內容大小會捨入到整數 pt，翻轉座標的子 view 會整片偏約 1 px（1.88 px／pt 才看得出來）。

**iOS 家族的玻璃（第二次校準，`Design/HPGlassIOS.swift`）**：HomeView 跑的是 iOS 系的玻璃，所以所有畫面都用 `HPGlass.platform = .iOS`（2.0 iosglass：包括外殼的卡片、提示與主畫面小工具，`ShellGlass`／`HPGlass.drawNow`，用 Regular）；`.macOS` 只剩校準台對 NSGlassEffectView 時暫時切過去，當參考與基準，不在任何畫面的路徑上。Mac 原生介面（設定）是 SwiftUI 自己的玻璃，不走這裡。iOS 27 模擬器拆出來的層樹跟 macOS 同一套零件，只有參數不同，`IOSGlass.apply` 把 NativeGlass 建好的樹換成 iOS 的值：

| 項目 | iOS 27 | macOS 27 |
| --- | --- | --- |
| Clear 的模糊 | 0.75 pt、面不加白、white 1.08（幾乎全透） | 7.8 pt、白 10% |
| Regular 的模糊 | 只在外圈：`BlurDistance0`＝−短邊／2，不透明度 0–0.8 跟尺寸走（≤ 64 pt 幾乎不糊） | 整面 0.5 |
| 外折射、濾鏡的外陰影 | 有（`OuterRefraction*`、`ShadowOpacity` 0.04–0.6、輸出伸到緣外 9–40 pt） | 沒有 |
| 靜止亮緣 | @2 開著（吃到背景色的 vibrant 亮緣） | 互動才亮 |
| 染色 | 背景亮度 0→1 從暗端內插到原色（淺色亮端＝原色） | 背景透得多 |

- 尺寸規律是 16–400 pt 掃描的折線表（短邊），超出沿端點那段外插。
- 容器：`HPGlass.container("名字") { … }` 裡加的形狀算同一個 GlassEffectContainer（iOS 共用一個 backdrop：內折射跟最小的形狀、其餘跟最大的）。食譜封面的 ✕＋兩顆膠囊用它。
- iOS 的外陰影是濾鏡畫的：貼回去時把緣外那一圈一起貼（先貼每組的圈、避開所有玻璃，再貼形狀裡面），我們自己的自適應外陰影就不畫。
- 校準：iOS 截圖換到畫布（1.88 px／pt）放成 `DIR/<組>/truth-*.png`、`bg-*.png`、`shapes.json`，跑 `homeplay-pet --glass-calibrate DIR ios` 畫我們的，再用 glass-compare.py 比。拿不到 iOS 真值的：按著（`.interactive()`）在模擬器上沒拍到變化，按下仍用自己的放大＋亮起。

**輔助使用（P01，`Design/HPAccessibility.swift`）**：

- 「減少透明度」：不畫玻璃，形狀改成霧面不透明（`.identity`：淺 #F2F2F7、深 #1C1C1E，95%，染色用自己的色）。
- 「增加對比」：玻璃與膠囊加 1.5 px 的 label 色描邊，次要字改成 label 80%，系統色換 HIG 表上的高對比版。
- 設定改變時監聽 `accessibilityDisplayOptionsDidChangeNotification`，並清掉玻璃快取。
- 快照可用 `HOMEPLAY_REDUCE_TRANSPARENCY=1`、`HOMEPLAY_INCREASE_CONTRAST=1` 強制打開。
- 開關的旋鈕按著或滑動時變成 Regular 玻璃（`HPGlass.addKnob`），快照用 `HOMEPLAY_ANIM=toggle.press:0.1`。

## Motion

一律用彈簧（damping ratio＋response 秒），不用固定時長的曲線。臨界阻尼走到剩 5% 要 0.76 × response，所以**影片量到「看起來結束」的時間 ÷ 0.76 ＝ response**（`Spring.settling(秒)`）。

| 彈簧 | damping | response | 用在 |
| --- | --- | --- | --- |
| `smooth` | 1.0 | 0.5 | 預設；所有點擊觸發的轉場（Apple `.smooth`） |
| `snappy` | 0.85 | 0.5 | 有手勢動量的放手、按鈕放開回彈（Apple `.snappy`） |
| `bouncy` | 0.7 | 0.5 | 只給彩蛋 |
| `interactive` | 0.86 | 0.15 | 按下、開關、分段、底線（Apple `interactiveSpring`） |
| `quick` | 1.0 | 0.2 | 小元件切換 |
| `HPMotion.release(v)` | v > 300 px/s 時 0.8，否則 1.0 | 0.5 | 拖曳放手 |

所有系統轉場的參數在 **一張表**：`HPMotion.T`（`Design/HPMotionTable.swift`），呼叫端只寫 `HPMotion.T.xxx`，不寫死數字。下面是同一張表（改了要一起改）。官方時長是 2.0 動效包自己逐格量的（`scratchpad/vframes/motion`，只在本機），再用臨界阻尼擬合（每格誤差都 ≤ 8%）：

| 轉場 | 官方 | 彈簧（95% 落定） | 做法 |
| --- | --- | --- | --- |
| 開 App（圖示／小工具） | v1 0:47.075→47.37 白卡左緣 | `appOpen` 0.18 s | 從圖示（或整塊小工具，圓角 56）長出；底下主畫面以來源為中心推前 8%；`appContent` 晚 0.21 s、0.14 s 淡入 |
| 關 App | — | `appClose` 0.18 s、內容 `appCloseContent` 0.08 s | 縮回打開它的那一格（`Shell.openedFrom`），內容先淡掉 |
| 家庭磚 → 滿版卡 | v1 1:51.45 | `tileExpand` 0.14 s | 途中白轉藍，標題與 ✕ 晚 0.1 s |
| 食譜換頁 | v1 0:26.775→27.07 | `pageSlide` 0.27 s | 右滑入 |
| 搜尋 → Now Playing | v1 2:19.7 | `blurFade` 0.29 s | 模糊交叉淡化；鍵盤 `keyboard` 0.17 s |
| 錶面換頁 | v2 0:42.60 跟手 | `facePage` .smooth | 1:1、頁縫 20；放手從手指的位置與速度接著走（`Face.pageStart`），投射挑頁、頭尾 rubber band（`FacePager`） |
| 錶面 ↔ 主畫面 | — | `homeFace` 0.3 s | 舊畫面起霧、新的 1.03 → 1；藥丸 `pill` 同步 |
| 回錶面（掛斷、閒置） | v1 1:20.975→81.27 | `toFace` 0.27 s（先停 1 格） | 新錶面從約 45 px 模糊變清楚 |
| 控制中心 | — | `controlCenter` .smooth | 拖曳時磚跟手 1:1（`ccTravel` 300）；放手投射開／關，有動量 damping 0.8 |
| 控制中心模組展開（2.0 cc） | — | `cc.expand` Spring(0.86, 0.36)；收回 Spring(1, 0.32) | 長按 0.5 s 從模組框長成大卡，其他模組 materialize 退場（卡長到四成多就收完）；版面換了 `cc.move`＝`listMove`；圖庫 `cc.gallery`＝`sheet`；推斷（iOS 模擬器不畫模組） |
| Sheet（換人） | — | `sheet` .smooth | 從下緣升起、底下壓暗；半路反悔從當下接著走（`HPPresence`） |
| 接管（門鈴、Handoff） | v2 0:31.80→32.33 | `takeoverZoom` 0.2 s → `takeoverFade` 0.28 s | 舊畫面放大 5%＋模糊，再交叉淡化；新畫面同時從模糊變清楚 |
| ClioTalk 滴落 | v1 0:21.625→21.83 | `clioDrip` 0.19 s | 👀 膠囊被水滴拉出去：原處那一截縮小、兩者之間一段頸子（`HPDrip` smooth union），飛的時候拉長 ≤ 1.15；主畫面上是頂端藥丸接手。白幕停到 0.58 s，每行 `clioLine` 晚 0.03 s、卡片 0.1 s、鈕 0.3 s |
| Live Activity 展開／收回 | — | `liveActivity` 0.32 s | 點按沒有動量 → 臨界阻尼 |
| 換分鐘數字 | v1 2:57.76→2:58.26 | `digitOut` 0.17 s／`digitIn` 0.3 s | 十位數早 80 ms，只動變了的位數 |
| 數值（倒數、溫度） | v2 0:43.0→44.5 | `numeric` Spring(1, 0.35) | `HPNumeric.draw`：右對齊配對、高位先、錯開 33 ms；倒數方向反過來 |
| 清單插入／刪除 | — | `listMove` Spring(1, 0.30)、`listInsert` 晚 0.12 s、`listDelete` 0.08 s | `HPListMotion`：鄰居先讓位，新的晚到；刪掉的留在原地加速淡出 |
| 玻璃出現／消失 | — | `materialize` 0.25 s | presence 0 → 1（折射、模糊、亮邊、形狀一起長） |
| 按下 | 1 格內 | `press` interactive | 放大 1.08、變亮 |

手勢與打斷：

- **可打斷**：所有動畫存（值、速度）；新目標從當下的值與速度接著走（`MotionValue.retarget`／`Anim.retarget`），不跳回、不等播完。
- **跟手**：拖曳 1:1；放手把速度交給彈簧；落點用投射 `v / 1000 × 0.998 / (1 − 0.998)`（WWDC18 Designing Fluid Interfaces 投影片的程式碼，0.998 是 UIScrollView 的減速常數）挑最近停點（`HPMotion.nearest`）。
- **拉過頭**：rubber band `x·d·0.55 / (d + 0.55·|x|)`（0.55 是業界對 UIScrollView 的逆向值）。
- **同一個來回走同一條路**：從哪裡出就回哪裡。
- **減少動態效果**：位移與縮放換成 0.2 s 交叉淡化，玻璃不回彈、不融合。
- **驗收**：`HOMEPLAY_ANIM=名字:秒` 把那個動畫凍結在第 t 秒；`--screen-png out.png --frames N` 一次出 30 fps 的 N 格（`Design/HPFrames.swift`）；`HOMEPLAY_REVERSE=秒` 讓凍結的動畫在那一刻反向（打斷測試）；`HOMEPLAY_REDUCE_MOTION=1` 看減少動態效果。跟官方影格並排；每格位置／大小／透明度差距大於 10% 或總長差一格以上就調。

## Components（`HPComponents`）

| 元件 | API | 數字 |
| --- | --- | --- |
| 頂列：返回圓鈕 | `shellBackButton(face, symbol:)`；照片上的頁面 `backButton(g, face, symbol:)` | 90，圓心 (105, 105)（`HPTokens.cornerControlCenter`，第三輪量自官方 recipe-overview）；✕ 0.34、‹ 0.36；Regular（照片上 Clear） |
| 頂列：大標題 | `bigTitle(g, face, s)` | SF Pro bold 56，x = 返回鈕右緣 + 24，基線 = 圓心 + 20；放不下縮到 40 |
| 頂列：右上時間 | `topClock(g, face, size:, baselineDY:, color:)` | semibold 32（照片上 34），中線 y 105、右緣 931（跟返回鈕對稱）；媒體全螢幕不畫 |
| 主要動作圓鈕 | `actionButton(g, face, r, symbol:, role:, label:)`、`actionRect(cx:cy:)` | 150；`.stop` 紅、`.mic` 黃（黑符號）、`.start` 綠、`.glass` 無色；符號 0.36；下方說明 28 |
| 玻璃圓鈕 | `glassCircle(g, face, r, symbol:, tint:)` | 符號 0.38 |
| 膠囊鈕 | `glassButton(…)`（無色）、`filledButton(…, tint:)`（染色主要動作） | 高 ≥ 88、字 regular 36（官方食譜圖的膠囊是 Regular）、符號同字重 1.1 倍字級＋間距 16。並排成一組的鈕共用 `HPTokens.Size.pairedButton`（440 × 104），只靠樣式分主次。`busy: true`＝符號換轉圈（`HPComponents.spinner`，0.9 s 一圈）、標籤換 `busyTitle`（進行式，如「打開中…」；nil＝標籤不變）；用在 Music 打開音樂、ClioTalk 想的時候的「停止」鈕，FaceTime 呼叫中是結束鈕外圈轉圈。快照 `HOMEPLAY_ANIM=busy:t` 凍結 |
| 分段控制 | `segmented(g, face, track, items, selected:)` | 玻璃軌道、內距 6；選中＝白（深色白 24%）＋`Shadow.segment`；interactive 彈簧滑過去 |
| 開關 | `toggle(g, r, on:, key:)` | 長膠囊軌道（關：#787880 16%／36%，開：green），旋鈕寬 = 高 × 1.3、`Shadow.knob` |
| 文字分頁 | `textTabs(…)` | 32，選中 semibold＋5 px 底線、間距 40 |
| 晶片 | `chip(g, face, r, title, selected:)` | 玻璃膠囊；選中＝白（深色白 34%）；字 semibold 32 |
| 分區標題 | `sectionHeader(g, face, s, x:, baseline:, chevron:)` | bold 38，可加 chevron |
| 分組卡 | `groupCard(g, r)`、`separatorLine(…)` | 圓角 52、`card` 色；分隔線 2 px 縮排到文字起點 |
| 膠囊列 | `capsuleRow(g, face, r, title:, subtitle:, trailing:, style:)` | 單行高 113、兩行 135、左右內縮 46、半徑 = 高/2；標題 semibold 33.8、右邊 regular 29.5、時間 regular 31；`.allDay` 淡橘 #FFF0DB＋橘圓 #FF9500（d＝0.46 高）＋棕字 #845008；`.timed` 淡藍 #DAEDFE＋14 px 藍豎條 #0088FE＋深藍標題 #0A4378、時間 #1A5FA0；`.plain` 灰底 |
| 來源晶片 | `sourceChip(g, face, x:, y:, title)` | 高 40、字 regular 21 #6E6E73、底 #F5F5F5、左右各 13；「+3」是正圓 |
| 重點詞內文 | `HPType.richWrap(…)`＋`drawRich(…)` | `**粗體**` 標記；英文詞不拆、漢字逐字排 |
| 助理的珠 | `assistantOrb(g, r, shape:, alpha:)` | 黑色玻璃珠：上半近黑、中間折射亮帶（暖→白→冷）、下半透出白底、柔影往下；眼睛由呼叫的人畫在上面 |
| 家庭磚 | `homeTile(g, r, radius:, fill:, content:)`、`homeTileLabels(…)` | 300、圓角 50；開＝不透明＋`Shadow.card`，關＝半透明灰；標籤 semibold 30／regular 26，底部置中 |
| 小工具框 | `widgetFrame(g, r, top:, bottom:)`；P02 起 `widgetFrame(…, mode:, appearance:, standalone:)` | 連續圓角 58、上下漸層；內距 30。照 `WidgetRenderMode` 取色：fullColor 原樣（深色外觀壓暗成深色版）、accented 拿掉背景（主畫面上底下是玻璃；染色再蓋所選色 × 0.22、62%）、vibrant 拿掉背景（夜間轉紅） |
| 頂端淡出 | `topFade(g, bg, solidTo:)` | 內容捲到標題底下時的 70 px 柔邊（不畫底色塊） |
| 空狀態 | `emptyState(…)` | 符號 128、標題 bold 48、說明 34 |
| 地圖卡（P10） | `mapCard(g, r, radius:, seed:)` | 內容層、不上玻璃；Apple 地圖標準色（淺：陸地 #F4F1EA、水 #AAD3F2、公園 #CFE7C3、白路、黃幹道 #FBE3A0；深：#2A2C30／#1B3247／#23382B）；圓角 `Radius.group` |
| 大頭針、我的位置（P10） | `mapPin(g, face, tip:, symbol:|initials:, tint:)`、`meDot(g, at:)` | 白圈 84、色圓 68、小尖 12；藍點 40＋白圈＋2.8 倍淡藍光暈 |
| 電平圈（P10） | `levelRing(g, center:, inner:, outer:, levels:, color:)` | 36 根直條排成圓（照對講圖示），靜音是一圈短淡點，說話往外長；在黃色麥克風圓鈕外 |
| 玻璃網址膠囊（P10） | `glassField(g, face, r, text:, placeholder:, leading:, trailing:, progress:, label:)` | Regular 玻璃；字 34（網域 semibold、提示 regular 55%）；載入時底緣 6 px 藍線。Safari 底欄：‹ 96、膠囊、› 96，中心 y＝1024−105，跟左上返回鈕上下對稱（`HPTokens.Safari`，照 iOS 27 safari-scrolled 推斷） |

狀態：所有可點的玻璃元件在 mouse down 那一刻放大 1.08＋變亮（`Press`），放開才觸發；App 的 `tick` 開頭問 `HPComponents.needsFrame(now)`。

## 對照工具

```
.build/release/homeplay-pet --size 600 --at 30000,30000 --near --demo-official --lang en --app timers --appearance dark --screen-png ours.png
python3 tooling/refcompare.py ours.png <參考圖> -o out.png [--mask m.json] [--boxes b.json]
```

`--demo-official` 換成官方原圖的內容（2026-04-01 星期三 10:09、生日行程三筆、Butternut Squash Soup／Home Cookbook／35 min／Serves 4、15 分鐘計時剩 10:56、官方那一組家庭磚），照片仍是我們自己的。誤差目標：位置與大小 ≤ 3%（≤ 30 px）、字級 ≤ 1 級、純色區 ΔE ≤ 5、圓角 ≤ 4 px；修正一律落在這裡的 token 或元件上。

## 主畫面外觀與小工具渲染模式（P02）

照 HIG › Widgets（Apple HomeView 一節與 Rendering modes）與 HIG › App icons。程式在 `Shell/HomeAppearance.swift`、`Shell/HomeWidgets.swift`、`People/PersonHome.swift`；設定在「外觀 › 主畫面外觀」（`Settings/HomeAppearanceSection.swift`）。

| 外觀 | 渲染模式 | 圖示 | 小工具 | 桌布 |
| --- | --- | --- | --- | --- |
| 淺色 | fullColor | 原樣 | 原樣 | 原樣 |
| 深色 | fullColor | 底換近黑漸層 #2C2C2E→#0E0E10，主體留色（白主體＋彩色底→主體染底色；白底黑字→翻白） | 深色版（漸層壓暗、系統底 #1C1C1E） | 再壓 38% |
| 透明 | accented | 去飽和：底挖空給 Liquid Glass（留 10% 白），主體依亮度轉白 94% | 拿掉背景＝玻璃；照片去飽和、62% 疊在玻璃上；primary／accent 兩組都是白 | 原樣 |
| 著色 | accented | 去飽和：底＝所選色 × 0.22、62%（玻璃透出），主體＝所選色提亮 | 拿掉背景＝玻璃＋所選色的深色版；照片去飽和乘所選色；primary＝所選色混白 55%、accent＝所選色提亮 | 再壓 16% |
| （夜間） | vibrant | 交給 `Faces/NightFace.swift` 整面轉紅，👀 不變 | 同左 | — |

- **圖示變體從哪來**：系統原生圖示與 HomeView 官網圖示（`Shell/OfficialIcons.swift`）都是拍平的圖，拿不到 Icon Composer 的分層，所以照 HIG「沒提供的變體由系統自動產生」的做法自己推：每一列取左右邊緣當底色（跟著上下漸層走），每個像素離底色的距離＝主體權重，等於拆回「底＋主體」兩層，再照上表重組（`HomeIconVariant.derive`，算一次快取）。各外觀保持同樣的核心特徵（HIG：不要在變體之間換元素）。主畫面的桌布偏暗，所以透明與著色用 HIG 表裡的 clear dark／tinted dark 那一組。
- **玻璃**：透明／著色時，所有圖示與小工具的底是同一個 `HPGlass` 容器、一次取樣；取樣的是畫面板之前的桌布（玻璃不取樣玻璃）。
- **著色的色**：沒選過就從桌布的色相建議（跟 iOS 一樣），選過就存 `shell.homeTint`。
- **每人主畫面**：`PersonHome` 照右上頭像那個人（`PersonalGate.avatarPerson`）載入他的排列（右上 2×2 小工具＋App 順序，存 `shell.homeLayouts`）；訪客與認不出的人用官方預設、不能編輯。長按 0.5 秒進編輯：「−」拿掉、左上「＋」開小工具圖庫、右上「完成」。
- **小工具圖庫**：玻璃 sheet，照片／天氣／世界時鐘三個真實預覽（示範資料）、名稱、一句動詞開頭的說明、目前那個藍框；底部「還原預設主畫面」用填色膠囊（玻璃上不疊玻璃）。
- **佔位與舊資料**：沒資料時靜態元件照畫、字換成不同寬的半透明條；天氣超過 2 小時沒更新照樣顯示舊資料，最後一行淡字「更新於 …」。
- **快照**：`--home-appearance light|dark|clear|tinted`、`--home-tint RRGGBB`、`--home-widget photos|weather|worldClock|none`、`--home-viewer <id>`、`--home-edit`、`--widget-gallery`、`--weather-placeholder`；`HOMEPLAY_WEATHER_JSON` 可加 `"ageMinutes":180`。
