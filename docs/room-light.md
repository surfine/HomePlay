# 房間光線與 Quick Look IBL

Apple 的四篇文檔給了三件關鍵事：

1. **Quick Look 的燈不是「一顆燈」**：`preferredIblVersion` 決定 classic/new lighting；new lighting 用 `studio_lighting_objectmode_v002.exr`（物件模式）與 `studio_lighting_armode_v002.exr`（AR 模式）。RealityKit **不讀** USDZ 裡的 `preferredIblVersion`，要自己把 EXR 變成 `EnvironmentResource` 並接到 `ARView.environment.lighting.resource`。
2. **AR 模式要和真實環境合併**：文檔明確建議把 AR-mode IBL 和使用者環境的環境貼圖組合，才能把真實世界的色偏/高光帶進反射。桌面桌寵不是 AR，所以我們用 **object-mode** 做底（Quick Look 桌面預覽的同一套棚拍光），再把攝像頭縮略圖疊進正前方半球。
3. **材質用 PBR，別自己發明**：USDZ 進入 RealityKit 就是 `PhysicallyBasedMaterial`；roughness/metallic/specular/clearcoat 都交給模型，只有屏幕用 unlit。幾何/貼圖預算：mesh ≤50、polygon <100k、texture ≤2048（本體是 Apple 的 USDZ，天然符合）。

## macOS 的限制與等價做法

ARKit 的 **Light Estimation API 只在 iOS/visionOS**：`ARLightEstimate`、`ambientIntensity`、`ambientColorTemperature`、`directionalLightEstimate`、spherical harmonics 在 macOS 上沒有。`ARView` 在 macOS 也不是 ARKit session。因此這裡做的是 macOS 等價物：

- **GazeTracker 的同一台攝像頭**（不另開 session）：追人時 640×480 / 15 fps；只開房間光時 VideoDataOutput 縮放 320×240（相機格式仍 640/15）、跳過臉部 Vision。
- **3 Hz** 取樣：48×32 縮略圖、6×4 亮度網格；**1 Hz** 用 `VNClassifyImageRequest`（Vision / ANE）做場景分類，戶外/日光才抬色溫下限。
  - 強度 = 整張平均亮度 + 最亮/平均差（窗光越強，主光越明顯），夾在 0.40…1.50。
  - 色溫 = 平均色（75%）＋最亮區域（25%）→ 線性 sRGB → xy → McCamy CCT；再換成冷暖 tint。不要只取最亮區域：一張被燈照亮的臉會把色溫拉到 2000K。
  - 方向 = 最亮網格單元的加權中心 → 方位角/仰角；攝像頭畫面左右翻成世界 +X，主光用這個方向。
- **主光**：`DirectionalLight` 放在估計方向，強度隨房間強度；原來的背光保留但降一點。
- **環境**：Quick Look object-mode 512×256 EXR 為底；攝像頭 48×32 縮略圖輕微模糊後疊進等距柱狀圖正前方 28%×38% 的區域，用徑向 alpha mask 融邊；底子按房間曝光/色溫微調。動態環境用 256×128，Core Image 合成在後台、`EnvironmentResource` 回主線程建立（128 specular cube，約 14 ms），2.5 秒一次；低電量/過熱 8 秒一次。

## 隱私

- 攝像頭只為「跟隨我」與「房間光線」工作；兩者都在選單裡可關，且預設都是關閉。只有使用者打開其中一項時才申請攝像頭權限；兩者都關時相機立即停。
- 幀只在本進程內降採樣成 48×32 記憶體縮略圖，不落盤、不錄製；日誌只寫強度/色溫/方向等純量。
- 直播 CarPlay、鎖屏、螢幕休眠、桌寵被遮住時相機暫停；恢復可見後再開。

## 相關文件

- `Sources/homeplay-pet/RoomLight.swift`：攝像頭取樣、CCT、方向、縮略圖。
- `Sources/homeplay-pet/RoomLighting.swift`：object-mode EXR、`EnvironmentResource` 合成。
- `Sources/homeplay-pet/GazeTracker.swift`：同一台相機的 frame 分發與只開燈時的 Vision 跳過。
- 選單：右鍵 › 偏好設定 › 「房間光線（攝像頭）」。
