<div align="center">
  <img src="https://homeplay.aaronlau.me/media/og-v3.jpg" alt="HomePlay：桌上一台小螢幕，會看著你" width="820">
  <h2>桌上一台小螢幕，會看著你。</h2>
  <p><strong>A 3D HomeView desk pet for the Mac that runs real CarPlay.</strong></p>
  <p>
    <a href="https://github.com/surfine/HomePlay/releases/latest"><img src="https://img.shields.io/github/v/release/surfine/HomePlay?label=download&style=flat-square" alt="下載最新版"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-15181c?style=flat-square" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-15181c?style=flat-square" alt="Apple Silicon">
    <img src="https://img.shields.io/badge/Swift-RealityKit-2a63d4?style=flat-square" alt="Swift + RealityKit">
    <img src="https://img.shields.io/badge/license-GPL--3.0--or--later-2a63d4?style=flat-square" alt="GPL-3.0-or-later">
  </p>
  <p>
    <a href="https://homeplay.aaronlau.me">官方網站</a> ·
    <a href="https://github.com/surfine/HomePlay/releases/latest">下載</a> ·
    <a href="https://github.com/surfine/HomePlay/releases">版本紀錄</a> ·
    <a href="https://homeplay.aaronlau.me/#faq">常見問題</a>
  </p>
</div>

## v0.5.0

HomePlay 把一台小小的 3D HomeView 放進 Mac 桌面。平常它顯示時間，用一雙眼睛陪你；用力按一下，螢幕就變成真的 CarPlay。iPhone 的畫面、觸控與聲音都會經過這台小螢幕，不是錄影，也不是假的介面。

這一版把網站與產品的那雙眼睛統一成 Apple 👀 的語言：網站的品牌眼換上琥珀虹膜，產品的眨眼、睡著與眨眼單眼改成唐老鴨式眼瞼線，保留白色眼白；分享圖也重拍成 v3。

## 下載

[**下載最新版**](https://github.com/surfine/HomePlay/releases/latest)：`HomePlay-macOS-arm64.zip`

macOS 14 以上，Apple Silicon。Developer ID 簽名、Apple 公證，解壓後直接打開。Intel 版尚未驗證，因此不發佈。

| 桌寵 | 背面 C 口 |
|:---:|:---:|
| <img src="https://homeplay.aaronlau.me/media/renders/view-front.webp" width="300" alt="HomePlay 桌寵，螢幕上是一雙眼睛與時間"> | <img src="https://homeplay.aaronlau.me/media/renders/view-back.webp" width="300" alt="HomePlay 背面：鋁合金機身、網罩與 USB-C 母座"> |

| CarPlay | 拆開 |
|:---:|:---:|
| <img src="https://homeplay.aaronlau.me/media/carplay-music.png" width="300" alt="HomePlay 的螢幕正在播放 CarPlay 音樂"> | <img src="https://homeplay.aaronlau.me/media/renders/view-apart.webp" width="300" alt="HomePlay 拆開後的底座與螢幕"> |

## 特色

- **真的 CarPlay**：無線（藍牙 iAP2 → Wi-Fi）或有線 USB；H.264 與 HEVC；觸控回傳；聲音走 Mac 喇叭；iPhone 的「正在播放」接到 Mac 系統 Now Playing 與控制中心。
- **插線一次，之後無線**：第一次用 USB 完成配對，穩定後自動切到無線；拔線不中斷會話。同時插兩支 iPhone 時，後到的那支取得唯一的 CarPlay 會話。
- **像產品的一部分**：Apple 官方 USDZ 幾何與材質、五種機身外觀、G4 白、可拆九件、背面 USB-C 母座；RealityKit 實時渲染與 Quick Look 同級 IBL。
- **會看人的桌寵**：十種表情、九種錶面；拖動、兩指滑、三指拖移、捏合、重按、長按。可選的「跟隨我」與「房間光線」只在開啟時使用相機。
- **安靜、省電**：閒置一段時間後換成靜態海報，ARView 離開畫面；被遮住或螢幕休眠時停止渲染；沒有通知、沒有回饋、沒有 telemetry。
- **零設定**：自動取得目前 Wi-Fi、自動匹配手機、插線與拔線自動切換；不讀系統鑰匙圈，不彈管理員密碼。
- **面向公開**：單一實例、VoiceOver 可按、英／簡／繁、權限說明本地化、GPL 開源。

## 第一次用 CarPlay

1. **下載、解壓**，把 HomePlay 拖進「應用程式」打開。
2. **第一次用 CarPlay**：用 USB 線把 iPhone 連到 Mac 一次，在 iPhone 上點「信任」與「配對」。
3. **重按桌寵**進入 CarPlay；之後拔線也會自動無線連接。

不需要帳號、設定檔或 Wi-Fi 密碼輸入。發佈的 App 已內建公開實驗性配件身份；只有自己從原始碼編譯時才需要自備身份（見下）。iPhone 的信任與配對是 iOS 的安全機制，必須由使用者本人同意一次。

## 手勢

| 動作 | 結果 |
|---|---|
| 拖動、兩指滑 | 轉身體 |
| 三指拖移、⌘ 拖動 | 搬位置（直播時拖邊框） |
| 捏合、⌘+ ⌘− | 放大縮小 |
| 重按 | 進入／退出 CarPlay |
| 長按螢幕 | 切換錶面 |
| 雙擊 | 角度回正 |
| 雙指輕點兩下 | 拆開／組回 |
| ⌘H | 隱藏桌寵（狀態欄圖示可再顯示） |

## 隱私與權限

HomePlay 不連任何伺服器，沒有帳號，也沒有 telemetry。權限按功能逐項申請：

| 權限 | 什麼時候會問 | 拒絕後 |
|---|---|---|
| 相機 | 開啟「跟隨我」或「房間光線」時 | 桌寵本身照常使用 |
| 麥克風 | 第一次進入 CarPlay 通話／Siri 時 | CarPlay 畫面與觸控仍可用 |
| 藍牙 | 第一次配對 iPhone 時 | 可用 USB 連線 |
| 區域網路 | 接收 iPhone 的 CarPlay 畫面時 | 無法使用 CarPlay |
| 行事曆 | 開啟行事曆錶面時 | 其他錶面照常使用 |
| Automation | 開啟 Mac Now Playing 時 | 其他功能照常使用 |

相機畫面只在本機處理，不存檔、不上傳。無線 CarPlay 需要 Wi-Fi 憑據時，由使用者在選單中填一次，存成本機 0600 檔案；不讀系統鑰匙圈。

## 從原始碼編譯

需要 macOS 14 以上與 Swift 6 工具鏈。

```sh
swift build -c release
B=.build/release

$B/homeplay-receiver --source auto --ssid '<Wi-Fi 名>' --port 8788
$B/homeplay-pet --endpoint ws://127.0.0.1:8788

$B/session-tests && $B/iap2-offline-tests
```

| 目標 | 是什麼 |
|---|---|
| `homeplay-pet` | 3D 桌寵（RealityKit + Apple USDZ），螢幕接接收器直播，觸控回傳 |
| `homeplay-receiver` | 接收器：`auto`（有線／無線）、`wireless`、`usb`、`window`、`h264` |
| `homeplay-verify` | 扮成客戶端連接收器，解出一幀存 PNG |
| `session-tests` / `iap2-offline-tests` | 會話層與 iAP2 的離線測試 |

## 配件身份

發佈的 App **已內建公開實驗性配件身份**，安裝後即可使用，不需要另外準備檔案。

公開的原始碼快照**不包含** `identity/`（含私鑰），也不包含 Apple 的 HomeView USDZ。自己編譯且要用 CarPlay 時，請準備 `identity.pk8` 與 `certificate.p7b`，用 `--identity-dir <目錄>` 或環境變數 `HOMEPLAY_IDENTITY_DIR` 指定；USDZ 需自行放入資源目錄。來源與合法性由使用者自行負責，工具不會打印身份內容。只用桌寵、或使用 `--source window`／`h264` 時不需要身份。

## 文件

- [無線連線與配對](docs/wireless.md)
- [效能與能耗](docs/performance.md)
- [房間光線](docs/room-light.md)
- [HomeView 研究](docs/homeview-study.md)
- [CarPlay 實作筆記](docs/carplay-best-practices.md)

## 致謝與授權

GPL-3.0-or-later，見 [`LICENSE`](LICENSE)。CarPlay 會話控制面參考 MacPlay 與 LIVI 的行為，以 Swift 重新實作；致謝與版權見 [`NOTICE`](NOTICE)。

HomePlay 是個人實驗專案，與 Apple Inc. 無關，也未經任何認證。CarPlay 與 HomeView 是 Apple Inc. 的商標，這裡只用來說明相容性。

這個倉庫是從私有開發倉庫定期同步的精選快照，所以歷史是一次一個同步提交。
