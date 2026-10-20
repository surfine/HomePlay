# Mac × CarPlay 最佳實踐：WWDC 逐篇研讀與採納清單（2026-10-18）

HomePlay 在 CarPlay 生態裡的位置很特殊：它不是 CarPlay **App**（跑在 iPhone 上），也不是車廠的**車機系統**，而是 Mac 上的一個**接收器**——模仿車機，向 iPhone 要畫面、聲音，接受觸控。所以大部分 CarPlay 會話對我們只有「理解對方」的價值，真正能照抄的是**車機側**與**媒體/渲染**的建議。以下逐篇記錄，並標明探納狀態。

## 逐篇要點

### WWDC23 10150 — Optimize CarPlay for vehicle systems（最相關）
車機側整合的權威文件，五個主題：視覺整合、連線、音訊、視訊編碼、EV 路由。

- **非矩形螢幕的 view area / safe area**：view area＝包住螢幕的最小矩形；safe area＝螢幕內最大的矩形；CarPlay 只在 safe area 內畫互動內容，外面預設黑。另有旗標允許「畫到 safe area 外」（只限主螢幕），讓背景鋪到邊。
- **圓角遮罩**：iPhone 會給每個角的透明度遮罩，車機拿它把黑三角去掉、把自己的背景畫到 CarPlay 圓角為止；但用了「畫到 safe area 外」就不能再用角遮罩。
- **狀態列**：依解析度與長寬比自動選直排（駕駛側）或橫排（下緣），可用 view area 旗標覆寫。
- **外觀模式**：整體 light/dark、地圖 UI 單獨、每螢幕分別同步；車機要即時把變化告訴 CarPlay。
- **音訊**：新增 **main buffered audio**（最多 2 分鐘緩衝、比實時快地送），是串流音樂的首選；四種音訊可同時混音。
- **視訊**：UI 串流歷來是 H.264，現在**支援 HEVC**（更省、支援更高解析度），但**必須保留 H.264 相容**。
- **連線**：USB 有線配對（out-of-band）、iAP2 交換 IP/port 取代 Bonjour（iOS 14+，支援 WPA3-only）、車鑰匙配對、**不要因為短暫鏈路斷開就關 TCP socket**、偏好 5 GHz、干擾時用 channel switch / BSS transition。

**採納**：音訊/熱狀態與 main buffered audio 已落地；HEVC、TCP 不主動斷已核對；狀態列/外觀同步仍待協議資料。

### WWDC24 10111 — Next generation CarPlay architecture
下一代 CarPlay 的分層：Overlay（車廠畫）、Remote（iPhone 串流，每螢幕一條）、Local（車機本地畫，低延遲）、Punch-through（車廠視覺豐富的畫面）。重點在**幀級同步**：每幀帶 presentation timestamp，另有低延遲 UI sync 通道，車機必須保留時間戳並準時送達。

**對我們的意義**：我們現在只搬畫面，沒有用時間戳做 A/V 同步；音訊有 `/feedback` 回報播放位置。未來可把 PTS 用於音畫對齊。

### WWDC24 10112 — Next generation CarPlay design system
純設計（給車廠）：可變字型 SF 的連續字重/寬度/圓角、儀表模組化、動態內容區永遠保留、通知的預設位置。**與我們的圓角家族／玻璃邊視覺方向一致**，無程式可採納。

### WWDC25 216 — Turbocharge your app for CarPlay
iOS 26 的 CarPlay：widgets、Live Activities、列表新元素、Now Playing 運動模式、導航中控/抬頭顯示。

- **音訊最佳實踐**：**只在真的要播放時啟動音訊會話，不播就停用**。
- **效能**：觀察 **thermal state**，過熱時降低細節或切 overview；CarPlay 的 CADisplayLink 幀率會自動適應。
- 影片、Metal 未涉及。

**採納**：兩條都做了（見「已落地」）。

### WWDC26 212 — Rev up your CarPlay app
iOS 27：語音對話類 App、**車內影片瀏覽**（需車輛支援 video-in-car；影片不可用時降級純音訊）、列表縮圖/詳情頭、**MiniPlayer**、Voice Control 全類別可用、導航面板與路線共享、CarPlay Simulator 進 Device Hub。

**對我們的意義**：CarPlay 現在真的會有影片類內容；我們的方屏接收器能顯示，但 16:9 內容會有留黑——這正是我們保留 CI 合成慢路的原因。MiniPlayer/模板是 App 側的事，與接收器無關。

### WWDC26 223 — Live Activities essentials
Live Activities 會自動鏡像到 macOS 選單列、Apple Watch、**CarPlay Dashboard**；CarPlay 用 small family、不可互動。效能要點是靜態/動態資料分離與 `staleDate`。**與接收器無關**（我們不發 Live Activity）。

### WWDC26 277 — WidgetKit foundations
Widget 的 timeline、reload budget、遠端 widget 在 macOS。**與接收器無關**；能借鑑的是「更新的預算」概念——我們的自適應幀率就是同一思路。

### WWDC26 312 — Meet the Now Playing framework
新的 `NowPlaying` 框架：App 用 `MediaSessionRepresentable`（id、content、playbackSnapshot、commands）把本地播放接到系統 Now Playing（鎖屏、控制中心、**CarPlay**、macOS 等）；遠端會話用 extension + APNs；Media Sharing Extensions 走系統裝置選擇器。

**已落地**：接收器解析 iPhone 的 iAP2 `0x5000/0x5001` now-playing metadata，桌寵把它發布到 Mac 的 `MPNowPlayingInfoCenter`／Control Center；播放、暫停、上一首、下一首經 CarPlay HID media 回送手機；進度跳轉走 iAP2 0x5003（absolute ms、trackId 校驗）。封面（iAP2 file transfer）已接。

### WWDC22 10016 — Get more mileage out of your app with CarPlay
App 類型的擴充（Fueling、Driving Task）、模板保證跨螢幕/輸入裝置一致、CarPlay Simulator（可測「行駛中限制 UI」、明暗外觀、斷線重連）。**接收器不適用**；但「行駛中限制 UI」提醒我們：真車場景下內容要能被限制，這是手機側的責任。

### WWDC20 10635 — Accelerate your app with CarPlay
iOS 14 的模板體系：UIScene 強制、列表/分頁/Now Playing/聯絡人/POI/資訊模板、single category single entitlement、Now Playing 模板要**一連上就配置**（系統可能為了顯示 Now Playing 而啟動 App）。

**對我們的意義**：無直接 API；但它說明 iPhone 端會為了 Now Playing 主動啟動 App——與我們觀察到的行為一致。

### WWDC20 10087 — Design for intelligence
Intents 的 Define → Learn → Execute、捐贈（donations）、Siri 建議。CarPlay 只作為語音入口被提到。**不適用**。

### Apple News（2020）— Build a great car experience
CarPlay 新類別（EV 充電、停車、快速點餐）與數位車鑰匙的導覽稿。**不適用**，僅背景。

## 採納清單

| 建議 | 來源 | 狀態 |
|---|---|---|
| 只在要播放時開音訊引擎，閒置暫停 | WWDC25 216 | **已落地**：12 秒無新音訊就暫停 AVAudioEngine，下一幀自動恢復 |
| 觀察熱狀態／低電量，主動降載 | WWDC25 216 | **已落地**：serious/low-power 降到 30/8 fps；critical 降到 6 fps，並暫停 Flow 氛圍動畫 |
| HEVC UI 串流（保留 H.264 相容） | WWDC23 10150 | **真機驗證通過（v0.3.0）**：根因是 `/info` 宣告了 `hevcInfo`，但會話 SETUP 的 `enabledFeatures` 少了 `hevc`，手機見前後矛盾，RECORD 後立即 TEARDOWN。修正後 1088×1088 真機 HEVC 出畫、寵物端 61fps 解碼零重建。`HOMEPLAY_HEVC=0` 可回退 H.264。 |
| main buffered audio（~2 分鐘緩衝） | WWDC23 10150 | **已落地**：type 102 走 AAC-LC + `/feedback` 播放位置/延遲；接收佇列留 6000 幀（約 2.3 分鐘）接住手機預送，不按實時速度丟 |
| 非矩形螢幕的 safe area 語義 | WWDC23 10150 | **已改回 Apple 規範（v0.2.0）**：safeArea＝最大內接矩形（1.475/13.15 換算，1088 寬約 36 px），`safeAreaDrawOutside` 保留讓壁紙鋪到邊；玻璃邊暗角仍在，承接圓角視覺 |
| 狀態列位置／明暗外觀同步 | WWDC23 10150 | **計畫**：`DisplayConfig` 尚無對應欄位；要先確認協議支援再送 |
| 短暫斷線不關 TCP socket、偏好 5 GHz | WWDC23 10150 | **已核對**：控制連線不因短暫斷流主動關閉；只由 TEARDOWN 或 15 秒完全無控制訊息/畫面結束。IPv6 備用回連與每次重新讀信道已加；5 GHz 由 iPhone／系統決定，接收端不強制 |
| 幀時間戳做音畫同步 | WWDC24 10111 | **計畫**：目前靠 `/feedback` 回報播放位置；PTS 對齊是下一步 |
| 車上播放呈現在 Mac 系統 Now Playing | WWDC26 312 | **已落地（v0.3.x）**：iAP2 0x5000 訂閱、0x5001 增量解碼（track/標題/演出者/專輯/時長/進度/播放狀態），桌寵發到 `MPNowPlayingInfoCenter`；播放/暫停/上一首/下一首走 CarPlay HID；進度跳轉走 iAP2 0x5003（trackId 校驗）；封面（iAP2 file transfer）已接 |
| CarPlay App 側的模板／entitlement／Live Activity／Widget | 2020–2026 各篇 | **不適用**：我們是接收器，不跑在 iPhone 上 |

## 參考
- <https://developer.apple.com/videos/play/wwdc2023/10150/>
- <https://developer.apple.com/videos/play/wwdc2025/216/>
- <https://developer.apple.com/videos/play/wwdc2026/212/>
- <https://developer.apple.com/videos/play/wwdc2026/312/>
- <https://developer.apple.com/videos/play/wwdc2024/10111/>
- <https://developer.apple.com/videos/play/wwdc2024/10112/>
- <https://developer.apple.com/videos/play/wwdc2026/223/>
- <https://developer.apple.com/videos/play/wwdc2026/277/>
- <https://developer.apple.com/videos/play/wwdc2022/10016/>
- <https://developer.apple.com/videos/play/wwdc2020/10635/>
- <https://developer.apple.com/videos/play/wwdc2020/10087/>
- <https://developer.apple.com/news/?id=re988owc>


## 官方《CarPlay Developer Guide》（2026-10）逐节核对

这本指南是给 **CarPlay App（iPhone 端）** 的，不包含车机侧（head unit）的 display 配置协议。逐节看下来，与接收器相关、可直接对照的有三点：

1. **音訊會話**（Audio handling → Playback）：
   > "Only activate your audio session the moment you are ready to play audio… Don't simply activate your audio session at the time your app launches."
   我們 v0.1.7 起就是這樣做：引擎延遲啟動、閒置 12 秒暫停。**已符合**，本輪不需改。
2. **螢幕規格預設**（附錄測試表）：CarPlay 的標準尺寸是
   - Minimum 748×456（2x）
   - Standard 800×480（2x）
   - Widescreen 1920×720（3x）
   - **Portrait 900×1200（3x）**
   方屏（1:1）不在清單裡，這解釋了為什麼 iOS 會把介面排成居中卡片。若要更貼近原生排版，可考慮宣告接近 3:4 的豎屏；代價是左右留黑。我們目前用 GPU 縮放裁掉壁紙邊（預設 100%，選單可選 115–150%），不改宣告、不影響可點區域。
3. **Now Playing 模板**：連上 CarPlay 就要隨時能填內容（系統可能為了顯示 Now Playing 而啟動 App）。這是 iPhone 端的責任；接收器側對應的是把音訊與觸控通道維持可用，我們已具備。

其餘章節（templates、entitlements、widgets、Live Activities、navigation panels/route sharing）都是 CarPlay App 的實作規範，接收器不適用。


## viewArea / safeArea / safe area origin 的關係（v0.2.7 整理）

三者是同一個幾何的三種投影，現在由 `PetDisplay` 一個來源推出來（`Sources/homeplay-receiver/Wireless.swift`）：

| 概念 | 意義 | 我們的值（1088² 方屏） |
|---|---|---|
| **viewArea** | CarPlay 可畫的全部範圍；方屏就是整塊面板 | origin (0,0)、size 1088×1088 |
| **safeArea** | 圓角裡的最大內接矩形：互動內容只在這裡 | origin (36,36)、size 1016×1016 |
| **safe area origin** | safeArea 左上角在 viewArea 裡的位置；對稱內縮時就等於內縮量 | (36,36) |
| **drawUIOutsideSafeArea** | 背景（壁紙）可以畫到 viewArea 邊，互動內容仍留在 safeArea | true |

推導只有一條：螢幕平面寬 13.15、圓角 1.475（與面板同心）→ 圓角像素 r = 1088×1.475/13.15 ≈ 122 → 最大內接矩形的內縮 = r·(1−1/√2) ≈ 36。`BPlist.areaDict` 把 insets 換算成 width/height/origin 後寫進 `/info`；啟動日誌會印出三者的實際矩形，方便對照。

**出血縮放是呈現層的事，不動宣告**：GPU 只裁顯示畫面；觸控用同一個縮放反算（`unzoomUV`），所以 1.6× 出血時點按仍然落在正確的畫面座標（自檢已覆蓋中心、左緣與可見區外）。

**滿版的最終形態（v0.2.8）**：`滿版（壁紙外延）`是默認——中央卡片 1:1 原位不動（控件零位移、零裁切），外圍壁紙環用邊緣外延拉伸鋪到玻璃邊。實現是 GPU 分段映射（`clamp(uv, m, 1−m)`，m=13%，可用 HOMEPLAY_BLEED_EDGE 調），觸控用同一映射反算。這既不是縮放也不是出血，正好同時滿足「界面滿版、控件原位、不裁切」。注意：全幅 App（如地圖）畫面本來就到邊，外延會拉伸它的邊緣——那時切回 100%。縮放檔位（140/160/180%）保留給願意裁切換滿版的人。
