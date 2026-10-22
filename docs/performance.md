# 效能：量測、瓶頸與優化（2026-10-18）

> **2026-10-20 RealityKit 遷移**：桌寵已從 SceneKit 換成 RealityKit，身體直接載入 Apple 的 `apple-homeview.usdz`（Quick Look 同一份資產），網罩/鉸鏈/材質全部原生。下面 10-18 的 SceneKit 數字保留為歷史。
> 新實作以 `--bench 5` 在 260×317 視窗、空閒 12 fps 下量到 **CPU ≈13%（單核）／RSS ≈205 MB**；主要成本是 USDZ 的高精度網罩與 RealityKit 每幀固定開銷。換來的是一眼可見的原生 Quick Look 質感。

> **2026-10-20 攝像頭房間光／Quick Look IBL／Apple silicon 優化**：攝像頭 640×480、只開燈時 VideoDataOutput 縮放 **320×240**（相機格式仍 640/15；追人時恢復 640×480），房間樣本 3 Hz；動態房間環境 **256×128**，Core Image 合成在後台，`EnvironmentResource` 用 128 specular cube（macOS 27），主線程 **14 ms**、2.5 秒一次；低電量/過熱時環境 8 秒、燈 1 Hz、分類 3 秒、臉 6 fps。相機場景分類用 **Vision / Neural Engine** 1 Hz（戶外/日光才抬色溫下限）。空閒幀率 12→**6**（互動仍 60，眨眼 30；`HOMEPLAY_IDLE_HZ` 可覆蓋）。294×359、深空灰 + System 6 實測**單核 CPU 約 33%、RSS ≈315 MB**（此前 35–50%）；在選單關掉「房間光線」後約 19%。ARView 的 RealityKit 固定渲染（約 13%）仍是最大單項——要再往下只能做 on-demand/靜態海報或重寫渲染路徑。第一方：RealityKit/Metal、Core Image/Metal、Vision/ANE、AVFoundation。

桌寵在 MacBook Air（M5，10 核：4 效能＋6 能效；24 GB；無風扇）上做的系統性優化。全部改動都有數字支撐，量法可重現。

## 量法

`homeplay-pet --bench N`：跳過啟動的 hello／引導動畫，跑 N 秒後印出 CPU 時間（`getrusage`）、`maxrss`、臉部重繪次數與目前幀率。基準對照用同一個補丁編出的 v0.1.5，同一台機器、同一時段、同樣跳過引導。

## 結果（14 秒穩態，三次）

| | v0.1.5 | v0.1.6 |
|---|---|---|
| 空閒 CPU（單核） | 14.5–16.0% | **3.4–3.8%** |
| 記憶體 maxrss | 243–247 MB | **112–113 MB** |
| 臉部重繪 | 約 16 次/秒 | **2–2.6 次/秒** |
| 幀率 | 固定 60 | 空閒 12／互動 60／睡著 1 |

約 **4.3 倍** CPU 與 **2.2 倍** 記憶體改善。

## 找到的瓶頸（按影響排序）

1. **臉部貼圖每幀全量軟體光柵**：1024×1024 Core Graphics，Pocket 表盤每畫一次要做多層玻璃（含高斯模糊陰影）。而預設視窗只有 220 pt，螢幕實際約 120 pt（Retina 240 px）——畫 1024² 是 4 倍以上的浪費。
2. **島表盤的 Flow 背景每秒要求重畫 10 次**（`tickIslandOptions`），壁紙漂動又以 20 Hz 重建（含 CI 模糊），閒著也在燒。
3. **主循環固定 60 Hz**：即使畫面完全靜止也在跑物理與相機計算；SceneKit `rendersContinuously` 也一直出幀。
4. **直播路徑每幀 `CIImage → CIContext.createCGImage → CGImage`**：實測 **2.8–5.4 ms/幀**（60 fps 下 17–32% 單核），還伴隨每幀 4–16 MB 的 CPU 紋理上傳。
5. 啟動時的 hello 動畫與著色器編譯讓前幾秒 CPU 很高（這也是早期「46%」讀數的來源，穩態其實低得多）。

## 改動

- **直播零拷貝**：`VTDecompressionSession` 輸出改成 Metal 相容、IOSurface 背襯的 BGRA 像素緩衝；用 `CVMetalTextureCache` 每幀直接包成 `MTLTexture` 交給 SceneKit。實測 **0.008–0.011 ms/幀**，比舊路徑快兩個數量級。方畫面（真機 CarPlay 就是 1088×1088）走此路；非方來源回退 CI 合成（SceneKit 對 `MTLTexture` 不套 `contentsTransform`，實測驗證過）。
- **臉部貼圖解析度自適應**：座標系仍是 1024，畫布按視窗實際像素縮放（0.25–1.0）。預設視窗畫 256²，最大視窗回到 1024²。這一步貢獻了最大的 CPU 與記憶體降幅。
- **自適應幀率**：直播或有動作（彈簧、手勢、過場、眨眼）60 fps；空閒 12 fps；睡著 1 fps。主循環定時器跟著改頻，不再每秒叫醒 60 次。
- **環境動畫降頻**：Flow 背景 10 Hz → 4 Hz，壁紙漂動 20 Hz → 6 Hz。兩者都是緩慢氛圍，視覺上看不出差別。
- **熱窗口**：只有眨眼、hello、引導、過場這類「要順」的動畫才把幀率抬回 60；環境漂動不抬。

## 對照 MacPlay CHANGELOG

MacPlay（同類接收器，Rust）的效能相關條目集中在連線韌性與顯示協商：停滯偵測／關鍵幀請求／有限解碼恢復（1.2.3）、幀率協商 120→90→60 回退（1.1.0）、首幀即顯示（1.2.2）、顯示器查詢移到背景避免阻塞（1.2.3）、舊回調隔離（1.2.2）。HomePlay 的 `HealthMonitor`／`frameDecoded`／重建機制與首幀流程已具備對應能力；**沒有** Metal／GPU／功耗專項——零拷貝與自適應幀率是這次自己做的。MacPlay 預設 1280×720 橫屏，不存在方屏 1024² 貼圖問題，這也是本專案獨有的瓶頸。

## 用了哪些 Apple 第一方能力

- **VideoToolbox**（`VTDecompressionSession`）：硬體解碼，輸出 Metal 相容緩衝。
- **Core Video**（`CVMetalTextureCache`）：像素緩衝與 Metal 紋理的零拷貝橋接。
- **Metal / SceneKit**：`MTLTexture` 直接作材質內容，取樣在 GPU。
- **Core Graphics**：只畫需要的那點像素（自適應解析度）。
- **CPU 能效核**：背景輪詢（AppleScript 讀歌、健康檢查）都在 utility 佇列，不佔主執行緒。

**關於 NPU（ANE）**：對「解 H.264＋畫 3D 貼圖＋輪詢播放器」這條路徑，ANE 沒有適用的工作負載；硬要用只會增加延遲與耗電。若未來做「靠鏡頭感知有人在不在」之類的 Vision 功能，才是 ANE 的正當用途。

## 還沒做、可再往下挖

- 臉部靜態層快取（壁紙＋玻璃底）只重畫眼睛與文字，可再省一半。
- 直播時若來源 60 fps 而顯示器 60 Hz，可考慮把渲染與解碼對齊（目前已是直通）。
- `maxrss` 仍含 SceneKit／Metal 著色器與紋理；進一步可把未使用的錶面貼圖改成按需生成。

## 2026-10-19 能效第二輪（待機 8.4% → 4.7%）

同一台 Apple Silicon、同一台 1088×1088 來源，`--bench` 取 30–90 秒平均（已扣掉啟動 hello）：

| 設定 | CPU | 說明 |
|---|---|---|
| 連續重繪 12 fps（舊） | 8.4% | SceneKit 每幀都畫，即使臉的貼圖沒變 |
| 按需出帧 + 眨眼 30 fps | 4.0–4.7% | 靜止時 `isPlaying=false`，只有貼圖變化才 `needsDisplay` |
| 再加「遠距瞬移 + 6 fps」 | ~3.6%（遠距穩態） | 一分鐘沒靠近：表情/視線直接到位，不做十幾幀過場 |

改動：

- **按需出帧**：`rendersContinuously=false`；只在直播、彈簧/手勢、臉貼圖更新時渲染一幀。靜止時 SceneKit 完全不跑。
- **眨眼 30 fps**：新增 `smoothUntil` 熱窗口（0.18 s、30 fps），不再為一次眨眼把整機抬到 60 fps；交互仍是 60。
- **遠距省電**：游標一分鐘沒靠近就降到 6 fps，且表情/視線直接到位（`animateDetails=false`）。靠近或點擊立即恢復。
- **螢幕休眠／視窗被遮住**：`screensDidSleep/Wake` 通知暫停渲染與所有輪詢；被遮住時也暫停 AppleScript「正在播放」輪詢。
- **計時器 tolerance**：主循環低幀率時 20–50 ms、hover 50 ms、電量 10 s、日曆 30 s、正在播放 0.5 s，讓系統合併喚醒。
- **測量修正**：`--bench` 之前把啟動期的計數也算進去，且 SCNSceneRendererDelegate 是 weak 導致 frames 永遠 0；現在開跑即清零並自行持有 delegate。

剩下的成本主要是「每渲染一幀的固定開銷」（臉重畫 ~6 ms + SceneKit 編碼 ~10 ms）。再往下要動架構：臉的靜態層快取（只重畫眼睛/文字）或把眨眼做成小貼圖覆蓋層。
### 靜態層快取（第三輪）

`--bench` 拆帳（單次臉重畫）：島表盤 5.28ms 裡**日期＋時間文字 2.67ms**、眼睛 1.39ms、背景 0.13ms；pocket 表盤 7.94ms 裡壁紙＋大時鐘 2.44ms、卡片堆＋玻璃 2.46ms、卡片內容 1.45ms。

- **島表盤：透明文字層快取**。日期＋時間畫進一張透明圖，key = 分鐘／reveal 檔位／錶盤樣式／年代／解析度。背景（流動壁紙）照舊每幀畫，但大號時間字不再重畫。實測（流動背景、70 秒）：**7.68ms → 3.59ms/次**，文字 1.09ms，快取命中 150/166，CPU 10.2% → 4.9%。
- **Pocket 表盤：背景＋卡片堆＋玻璃快取**。key 加上壁紙代號與解析度；卡片內容、頁點、眼睛仍每幀畫。**7.94ms → 4.98ms/次**。

快取只有一張圖（最大 1024²，4MB），視窗縮放／換錶盤／換壁紙時自動失效；reveal 以 2.5% 檔位近似，過渡中最多差 0.6% 透明度，肉眼不可見。
## 2026-10-19 查漏（能耗與生命週期）

- **被遮住／螢幕休眠時主循環仍以 12–60 Hz 空轉**：`setOccluded` 現在直接銷毀主循環與懸停計時器，醒來重建；健康檢查與 fps 統計改成「只在直播時啟停」，不再 4 Hz 常駐。
- **現在播放輪詢**在遮住時暫停，醒來恢復。
- **退出 App 遺留 receiver 子進程**：`applicationWillTerminate` 會終止自己拉起的 receiver（launchd 拉起的仍獨立）。
- **改了 `wireless.json` 的 port 卻仍連 8788**：探測、endpoint、拉起全部改用配置端口；連按重壓有 3 秒防抖，不會拉兩個 receiver。
- **receiver.log 無限增長**：超過 2 MB 清空。
- **換表盤不釋放舊的靜態層快取**：`setFaceStyle` 清空兩張快取（最多 8 MB）。
- **狀態欄選單彈到螢幕外**：改用螢幕座標在圖示下方展開。
- **系統三指拖動開關在啟動時只讀一次**：改為每次按下時重新讀。
- **輔助功能只有 group、沒有動作**：改成 button，按下＝進入/退出 CarPlay。



## 2026-10-20 第三轮：RealityKit 待机（22.5% → 5.8%）

`--bench 6` 在 220×269 视窗、空闲 6fps 下：

| 设定 | 单核 CPU |
|---|---|
| 原始 ARView | 22.5% |
| `__nonARKitDevices = true` + `__disableComposition = true` | 19.8% |
| 闲置 90 秒后切静态海报（ARView 移出层级，2 秒刷新） | 8.7% |
| 海报刷新改为 5 秒 | **5.8%** |

- 仅 `render.isHidden = true` 或 `__enableAutomaticFrameRate = true` **不会**停掉 RealityKit
  的 display link；必须把 ARView 从视图层级移除，主循环也停掉，才能把那部分固定开销降下来。
- 海报每 5 秒用 `render.snapshot` 重拍一张（脸部时间最多滞后约 5 秒），鼠标进入 120pt、点击、
  右键、滚轮、触控板手势、开始直播或出现配对卡都会立刻恢复实时渲染。
- 海报期间房间光/追人摄像头也暂停（绿点灭掉），靠近时恢复；开启「跟随我」时不进入海报，
  避免冻结转头。`HOMEPLAY_POSTER_AFTER` 可覆盖 90 秒阈值（量测用）。
- 直播和交互帧率未变；这次只动待机路径。

## 2026-10-22 第四轮：按需 3D（閒置 18% → 3%、直播靜止 17% → 0.3%）

Time Profiler 量到桌寵閒置或 CarPlay 畫面靜止時仍 21–27% CPU，主執行緒 54%、Render 執行緒 31%，
全在 RealityKit 每幀場景更新（`re::MeshVisitor::traverse`、`bucketMeshPart`、`encodeDrawCalls`、ECS DeepCopier），
桌寵自己的程式碼不到 5%。這一輪先用最小 ARView 探針把「到底什麼能停掉 RealityKit 的幀」量清楚，再改桌寵。

### 控制手段實驗（Darwin 27.0.1，260×317 視窗，載入 apple-homeview.usdz，`SceneEvents.Update` 數幀）

| 手段 | 場景更新 | CPU | 結論 |
|---|---|---|---|
| `__enableAutomaticFrameRate` 0／1 × `__preferredFrameRate` 60／6／1／0，engine init 前或後設 | 60/s | ~18% | **全部無效**，恆 60 |
| `isHidden = true` | 60/s | ~18% | 無效 |
| 從未掛進任何層級的 ARView | 60/s | ~18% | 引擎在 init 就起跑 |
| 掛在沒 orderFront 的離屏視窗 | 60/s | ~18% | 無效 |
| `snapshot()` 當逐幀渲染 | — | 每張 ≈10 ms CPU、20–25 ms 延遲 | 6 張/s 就多 6%，不能當通用出幀 |
| **掛進視窗後 `removeFromSuperview`** | **0/s** | **0.1%** | 唯一能歸零的手段；掛回去立刻 60/s，無額外尖峰 |

卸下期間 `snapshot()` 不會完成（掛回去才回呼），所以沒有「卸著按需出一幀」這種事；`project()`／hitTest 在卸下期間正常。
另外量到 `snapshot()` 是另一條離線渲染：和上屏那幀相比，貼圖取樣區域差 1–2 階、機身輪廓覆蓋率偏高（差到 30–56 階），
拿它當海報每次切換都會微閃。`renderCallbacks.postProcess` 回呼裡的 `sourceColorTexture`（bgra8Unorm_srgb、Display P3）
就是要上屏的那幀，blit 一份出來逐位相同，回呼本身量不到 CPU。

### 做法（`PetView`，`HOMEPLAY_RENDER_MODE=always` 退回常駐做對照）

- **場景一變才掛回去**：`HomeViewModel.generation`（貼圖／材質）、姿態（yaw／pitch／鉸鏈／拆解／按壓，
  門檻約 0.1 px，全用 Double 比——Float 四元數點積在 1e-7 以下沒解析度會一直誤報）、光／環境貼圖／視窗尺寸走 `requestFrame()`。
  掛回去後海報先蓋著，到第 3 次 `SceneEvents.Update` 確定第一幀已上屏才收掉（第 1 幀在下一個 vsync 才出現）。
- **靜止就卸下**：一次卸下＋掛回約 43 ms CPU，常駐每秒約 200 ms，空檔超過 0.2 s 就值得卸；眨眼結束後 0.12 s 卸。
  連續兩次變化間隔都短於 0.35 s（Flow 錶面 4 Hz 壁紙、眼睛平滑過場、高幀直播）視為持續變化，改等 0.4 s，
  免得反覆掛卸比常駐還貴（Flow 實測與常駐持平 20.6% vs 20.5%，沒有變差）。
- **凍結幀當海報**：卸下前在 `postProcess` 回呼把上屏那幀 blit 到一張 shared 紋理，命令完成後讀回主執行緒做成
  CGImage（BGRA 預乘、沿用 CAMetalLayer 的色彩空間）直接當海報層的 `contents`，與移出 ARView 在同一個 transaction。
  螢幕連拍跨切換的配對 diff 為 0（見下）。
- **浮動不停**：4.5 秒一次的輕微上下浮動是整台機身平移，卸下期間用海報層位移呈現，吸到整個裝置像素不重採樣。
- **直播**：進幀即掛回去（不等主循環那拍）；畫面靜止半秒沒進幀主循環降 12 Hz、進幀立刻回 60。`targetHz` 其餘語意不變，
  `__preferredFrameRate` 仍照寫（這版系統無效，留給未來）。
- **深度閒置海報（90 s）**與**被遮住**改用同一套掛卸：海報模式只負責把主循環降到 5 秒一拍；被遮住時 ARView 直接卸下
  （以前只 `isHidden`，display link 其實還在跑）。
- `--snapshot` 仍走 `render.snapshot`（卸著時先掛回去、跑一拍、出過幀再拍），輸出與改前逐位相同。

### 量測（xctrace Time Profiler 10 s 取樣 + `ps` cputime；220×269 視窗；`HOMEPLAY_FAKE_LIVE=<fps>` 餵 1088² 合成直播畫面）

| 情境 | 常駐（改前） | 按需 |
|---|---|---|
| 閒置 75 s 後（錶面模式、游標遠離、關掉 90 s 海報） | 18.2%，主執行緒 61 叢/s、Render 47 叢/s | **3.0%**（取樣 4.2%），主 10.5、Render 6.7 叢/s |
| 直播靜止（只餵一張） | 16.9%，主 61、Render 39 叢/s | **0.3%**，主 2.5 叢/s、Render 0 |
| 直播 2 fps（偶發更新） | ≈17% | **7.3%**，主 32、Render 12 叢/s（每幀掛回去 7–8 幀再卸） |
| 直播 30 fps | 36.4% | 37.9%（持平；合成畫面的 CG 繪製佔大頭，真機走零拷貝） |
| Flow 錶面（4 Hz 壁紙） | 20.5% | 20.6%（持續變化，留在線上） |

閒置時每次眨眼／瞄一眼掛回去 7–16 幀再卸；一分鐘沒人靠近後眼睛直接到位，掛卸次數約每秒一次以下。
`--bench` 現在多印 `frames3D`（RealityKit 實際出幀）與 `detaches`。

### 驗證

- `swift build -c release` 無新錯誤；`--selftest` OK。
- 10 種表情 + 9 種錶面 `--snapshot` 與改前二進位逐張對照：16 張逐位相同；analog／flow／pocket／worried 的差異是
  秒針、壁紙漂動、卡片與動畫隨時間變化（改前二進位自己連拍兩次差更多：flow 31%、worried 32%）。
- 螢幕連拍（`screencapture` 每 ~0.15 s 一張）：純海報期間逐張相同；跨「3D→海報」切換的配對 diff 0；
  每 0.8 s 一次 30% 的差異是浮動的整像素位移。常駐與按需在同一分鐘內拍到的畫面逐像素相同。
- 眨眼、追視、拆解、直播只要在動就是掛著的 60 Hz RealityKit，和改前同一條路；差別只在第一幀前多 2 幀海報。
