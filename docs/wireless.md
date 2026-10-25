# 無線 CarPlay：真機跑法（P4）

這條路不需要 CarPlay Simulator，iPhone 直接無線投到桌寵。流程照 MacPlay：
藍牙 iAP2（識別＋MFi 認證）→ 交 Wi-Fi 配置、叫手機開會話 → 手機經區域網連回我們的控制口 →
配對、加密、auth-setup → 螢幕流解密 → 同一套 wire 推給桌寵。觸控走會話裡的 HID 報告，**不動真游標**。

## 前提

- 身份：簽名的 Release 已內建公開實驗性配件身份，安裝後即可使用；公開原始碼快照不含 identity。
  自己從原始碼編譯且要用 CarPlay 時，請自備 `identity.pk8` + `certificate.p7b`，用
  `--identity-dir <目錄>` 或 `$HOMEPLAY_IDENTITY_DIR`。來源與合法性由使用者自行負責。
- iPhone 和這台 Mac 配對一次（之後自動無線）。最簡單：用資料線連上 Mac，解鎖 iPhone，
  點「信任」；若 Mac 還沒和 iPhone 配對過，再點一次「配對」。整個過程不用打開 iPhone
  的藍牙設定。沒有線時才需要在 iPhone「設定 › 藍牙」→ 點 Mac 的藍牙名。
  macOS 自 10.9 起把「可被發現」綁在「系統設定 › 藍牙」面板是否打開上：面板一關，
  Discoverable 立刻變 Off。`IOBluetoothPreferenceSetDiscoverableState`（blueutil 用的
  私有函數）在終端進程裡是空實現，但**在 launchd 拉起的 App 進程裡有效**——2026-10-19
  實測可由 Off 直接變成 On（私有 getter 會過時，要用 `system_profiler SPBluetoothDataType`
  看真實狀態）。receiver 在配對引導開始時調用該 API 打開可發現性、每分鐘重申一次，
  引導結束（配對完成或超時）再恢復關閉；API 不可用時退回後台打開藍牙設定面板。
  所以首次配對不需要用戶手動去開設定，插線路徑更不會打開它。
- Mac 和 iPhone 在**同一個允許設備互訪的區域網**（個人 Wi-Fi；企業 802.1X、網頁登入的不行）。
- 第一次跑會要藍牙權限（終端機）、可能要區域網權限；讀 Wi-Fi 信道可能要定位權限，讀不到就用 `--channel`。

## 步驟

```sh
git clone https://github.com/surfine/HomePlay.git
cd HomePlay && swift build -c release
B=.build/release
$B/iap2-probe --list                        # 找 iPhone 的藍牙地址
$B/homeplay-receiver --phones-selftest      # 只讀：列出已配對 iPhone 與本機藍牙名
$B/homeplay-receiver --source netinfo       # 看這台 Mac 的 IP、Wi-Fi MAC、信道
```

```sh
export HOMEPLAY_WIFI_PASSPHRASE='你的 Wi-Fi 密碼'    # 不放命令列，免得出現在 ps
$B/homeplay-receiver --source wireless \
  --address <iPhone 藍牙地址> --ssid '<iPhone 所連 Wi-Fi 名稱>' --port 8788
# 這行假設你用簽名 Release；從原始碼跑時，加 --identity-dir <目錄>
```

另一個終端機：

```sh
$B/homeplay-pet --endpoint ws://127.0.0.1:8788
```

iPhone 上如果跳「要使用 CarPlay 嗎」之類的提示，按允許。

## 日誌該長什麼樣（逐段對照）

| 段 | 期待的日誌 | 卡住時先看 |
|---|---|---|
| 藍牙 | `iAP2 RFCOMM 通道已打開` → `識別通過（0x1D02）` → `MFi 認證通過（0xAA05）` | 0x1D03 被拒：看被拒參數；0xAA04：身份不被認 |
| Wi-Fi 交接 | `iPhone 要 Wi-Fi 配置` → `iPhone 報 CarPlay 可用 … → 開會話 <IP>:17000` | 沒有這兩行：手機沒進無線 CarPlay 流程 |
| 回連 | `ctrl 探測 … HTTP/1.1 200` → `手機連入控制口` | 防火牆擋 17000、或不在同網段 |
| 配對 | `/pair-setup` ×3（第一次）→ `/pair-verify` ×2 → `控制通道已加密` | pair-setup 用 MacPlay 同款固定 PIN |
| 認證 | `auth-setup 已簽` | 400：請求長度不對 |
| 會話 | `SETUP 會話` → `事件通道已連上` → `SETUP 螢幕（110…）` → `RECORD：會話開始` | `SETUP 流 130 還沒實現`：見下面「已知缺口」 |
| 畫面 | 桌寵 `VIDEO_CONFIG 1200x1200` → `screen live` | 有 SETUP 螢幕但沒畫面：看 `螢幕流：` 錯誤 |
| 觸控 | 點桌寵屏幕，CarPlay 有反應 | 這是 P0 第 (d) 項的真解：會話內 HID |

不通就把日誌從頭貼回來，記下停在哪一段；不要猜。

## 首次配對連不上：「CarPlay 清單裡有 HomePlay，卻一直停在正在連線」（2026-10-25）

接收器用 `ConnectDiagnostics`（`Sources/IAP2/ConnectDiagnostics.swift`）記每次嘗試的時間點與次數，卡住時按下表
由上而下判斷，送 `wifiHelp` 帶 `reason`，桌寵照原因給一張卡（`ConnectHelp.card`）。判不出來就當 Wi-Fi 沒連回。

| 原因 `reason` | 怎麼判斷 | 觸發 | 卡上叫使用者做什麼 | 自動恢復 |
|---|---|---|---|---|
| `macFirewall` | `socketfilterfw` 唯讀查詢：開著且「阻止所有傳入連接」或接收器被拒 | 交接逾時（15 秒）／等同意 20 秒 | 系統設定 › 網路 › 防火牆 › 選項：允許 homeplay-receiver | 0x4301 照舊補發，改好就連上 |
| `localNetwork` | `_carplay-ctrl` 瀏覽或探測停在 `PolicyDenied`（-65570） | 同上 | 系統設定 › 隱私與安全性 › 本地網路：打開 HomePlay | 同上 |
| `carPlayConsent` | iAP2 認證後 20 秒沒有 0x4E0D／0x4300（iPhone 等使用者在 CarPlay 提示上點「連接」） | 認證後 20 秒 | 解鎖 iPhone 點「連接」；「不支援」是正常的，別忘記此裝置 | 連結保持，不重連 |
| `ssidUnknown` | 不知道 Wi-Fi 名稱：macOS 26 起 `ipconfig getsummary` 與 CoreWLAN 對沒有定位權限的 App 都隱藏 SSID（本機實測），0x5703／0x4301 裡是空的 | 送出 0x4301 後 5 秒沒回連 | 填 iPhone 所連的網路（桌寵自動開一次 Wi-Fi 設定） | 存好立刻 `wifiChanged` → 重送 0x5703＋0x4301 |
| `inboundBlocked` | iPhone 回了我們的 `GET /ctrl-int/1/connect`（同網、Mac→iPhone 通），但沒連進控制口 | 交接逾時 | 檢查防火牆或 Little Snitch／LuLu 這類 App | — |
| `wifiNoConnectBack` | 其餘：交了 Wi-Fi 設定、送了 0x4301，沒從 Wi-Fi 連回 | 交接逾時 | 在 iPhone 關開一次 Wi-Fi；要連「<SSID>」，不是訪客網路或另一個 5G／2.4G 名稱 | 補發 8 次（含 IPv6、換安全類型）；40 秒後卡片改給「插線一次」與診斷報告 |

**診斷報告**：右鍵 › iPhone › 拷貝診斷報告。桌寵送 `{"type":"diagnostics"}`，接收器回 `reportLines`
（判斷、Wi-Fi 頻段／信道／安全類型／是否知道名稱與密碼、防火牆、已配對數、這次嘗試各段的秒數、累計次數、
`_carplay-ctrl` 瀏覽與探測結果、最近幾次連線耗時），桌寵加上版本、系統、卡片狀態與 receiver.log 里程碑次數。
不含 SSID、密碼、IP、藍牙位址、裝置名稱與身份；接收器沒回應也照樣出桌寵那一段。

**配對走 iPhone 設定 › 藍牙 › 其他裝置**（真機 2026-10-24：Mac 主動配對 6 次只叫到 2 次，iPhone 端配對每次幾秒）。
配好後 iPhone 可能顯示「不支援」（HomePlay 只提供 iAP2／CarPlay，沒有通話或音樂藍牙），那是正常的；
點了「忘記此裝置」才會讓 Mac 留下 iPhone 已經不認的配對。連接步驟（右鍵 › iPhone › 連接步驟…）第一次進配對引導時自動出一次。

## 雙模（妙控配件式）：配對一次，之後永遠無感

`--source auto`（重按拉起、開機自啟都用它）的規則（2026-10-22 真機定案）：

- **已配對的手機：數據線只充電，不開 carkit。** 接收器用 `usb-phones.json`（USB 序號 → 藍牙地址，0600）
  認出這條線上的手機已和 Mac 配對，就不碰 USB，會話照常由藍牙 iAP2 → Wi-Fi 建立（插著線 2–3 秒內
  `会话建立：Wi-Fi`）。因為根本沒有 USB 上的 iAP2 鏈路，**插線、拔線對會話完全沒有影響**
  （真機 15:07–15:08：拔→插→拔三次，會話與音訊連續，日誌只多 `USB 只充电` 與 `拔线：会话在 Wi-Fi 上，保持`）。
  插線 45 秒都沒會話、藍牙也沒認證成功，才退回開 carkit；`HOMEPLAY_USB_CARKIT=1` 強制走 carkit。
- **第一次（序號還沒記過）**：開 carkit 走 USB iAP2，手機報 0x4E0E 時記下序號→地址；手機報 0x4300 時
  回**無線版 0x4301**，手機 0.2–0.5 秒內從 Wi-Fi 連入開會話（線只剩充電＋iAP2 控制）；12 秒沒回連才退回
  有線版 0x4301（NCM 鏈路本地）。這條會話是綁在 USB 鏈路上的：**第一次拔線手機會在 115 ms 內結束它**，
  接著藍牙重連再開一條；從第二次插線起就是上面的只充電模式。
- 沒插線走藍牙 iAP2 → Wi-Fi。兩邊共用同一個控制口與會話物件。

為什麼不能像舊做法那樣「插著線切無線」：只要 USB 上有 iAP2 鏈路，手機就把 CarPlay 會話綁在它上面
（哪怕會話原本是藍牙起的，中途插線完成 USB 識別後也一樣），那條鏈路一斷（配件關、拔線）手機 20–115 ms 內
結束會話；而插著線時手機又多半拒絕藍牙 iAP2。舊的「有線穩定 4 秒後關 USB 等藍牙」約 20 次只成功 2 次，
且每 5 分鐘砍一次正在用的會話，2026-10-22 移除。

**carkit 流 76 秒必斷（已修）**：10/20 起每條 USB carkit TLS 流開啟後 76–78 秒就 `TLS 读错误 60`
（POSIX ETIMEDOUT，245 次樣本，與是否有資料流動、會話走哪條路無關）。元兇是 CFStream：
`CFStreamCreatePairWithSocket` 把已連好的 usbmuxd unix socket 當成「仍在連線」，其 75 秒連線逾時一到就報錯關流。
`TLSStream` 改用 SecureTransport 的 `SSLContext` 直接跑在 fd 上，所有 SSL 呼叫都在讀執行緒上（`SSLContext`
不是執行緒安全的，主執行緒並發 `SSLWrite`/`SSLClose` 會讓 record 層重複釋放而 SIGABRT）；usbmuxd socket 設
`SO_NOSIGPIPE`、接收器忽略 SIGPIPE（對端先關時 `write()` 會把程序靜默殺掉）。改後會話 15 分鐘以上無斷線。

拔線（連續兩次 1 秒輪詢都沒看到裝置才算，避免 usbmuxd 抖動誤判）：
- 會話在 Wi-Fi 上：接收器不碰會話，桌寵先凍住最後一幀（`handoff:start`），3 秒後會話還在就解除
  （`handoff:done`）。只充電模式下會話必然還在。
- 會話綁在 USB 上（第一次插線那條）：手機結束它，桌寵保持凍幀，藍牙 iAP2 重連 → 無線 0x4301 → 新會話。
  拔線後手機常把 RFCOMM「開了就關」：先斷到它的基帶連接再重開，第二次仍被拒就自愈重啟（新進程 2 秒內連上）。
- 啟動時的 Wi-Fi 安全類型探測（CoreWLAN 掃描＋system_profiler，4–34 秒）按 SSID 緩存在 `wifi-security.json`，
  第二次啟動起直接用緩存、後台刷新。

- **第一次配對先等插線（有線優先）**：一台 iPhone 都沒配對過時，receiver 不會立刻打開
  「系統設定 › 藍牙」，而是先廣播一張「用資料線連一次」卡；20 秒計時從桌寵連上、
  真的有人看到這張卡才開始（後台 receiver 沒人看時不會自己走完或彈設定）。這段時間內插上
  資料線：解鎖 iPhone → 點「信任」→ 有線 iAP2 會回報手機的藍牙地址（0x4E0E）→ 若系統
  還沒配對就自動發起 `IOBluetoothDevicePair`（手機上點「配對」）→ 拔線即無線。整個過程
  不用進 iPhone 設定。20 秒內沒插線才退回藍牙引導：receiver 打開「系統設定 › 藍牙」
  （Mac 的藍牙面板開著時才可被 iPhone 發現），桌寵顯示這台 Mac 的藍牙名稱，在 iPhone
  的「設定 › 藍牙」裡點它、兩邊確認配對碼；receiver 每 2 秒輪詢系統配對清單，新 iPhone
  一出現就刷新 SDP、直接連上。用戶 20 秒後再插線也可以，USB 成功後會自動接管並停掉
  藍牙引導。
- **學到的手機立刻落盤**：有線會話的 0x4E0E 一到，receiver 只更新 `wireless.json` 的
  `phone` 欄位（保留 SSID／密碼／端口等全部內容，0600），並在 iPhone 藍牙認證成功時
  再寫一次；桌寵收到 `currentPhone` 也會存。這樣 receiver 或桌寵重啟都不會忘記這台手機，
  拔線後直接用同一台回連。
- **USB 是首次配對的主路，藍牙是沒有線時的備援**：有線會話裡手機報 0x4E0E（帶它的藍牙
  地址）。系統裡還沒配對過的話，receiver 會**先結束 USB CarPlay、暫時抑制 carkit**，
  讓 iPhone 恢復藍牙，然後才發起 `IOBluetoothDevicePair`（手機上點一下「配對」），
  線繼續供電；60 秒沒確認就自動轉到系統藍牙配對引導（桌寵顯示這台 Mac 的名字）。
  配對成功後走無線並把這台手機記成目前手機；沒配對成功不會改寫上一台的偏好。
- **切換手機**：右鍵 →「使用 iPhone」列出所有已配對的 iPhone（勾選目前這台）；選另一台會結束目前
  的會話、按新地址重新叫回連，並寫回 `wireless.json`／更新已安裝的 LaunchAgent（下次登入也生效）。
  已有一台在用的情況下，「配對新 iPhone…」仍會打開藍牙設定，新手機配對後自動切過去。
  插著 USB 時選擇會先記住，拔線後才切換。
- **iPhone 為什麼會把 Mac 認成車機**：receiver 照 MacPlay 把 Bluetooth 裝置類臨時設成車機
  A/V（`0x200408`，120 秒自動恢復，執行中每 60 秒續期），並發布 iAP2 與 CarPlay 的 SDP
  服務；iPhone 配對後會看到 CarPlay 服務，也可能直接透過 RFCOMM 連進來。首次配對結束時
  若 iPhone 彈出 CarPlay 提示，點「允許」即可。
- **和開發者模式無關**：配對走標準系統藍牙（有線時由 Mac 發起，iPhone 點「配對」；
  沒有線時才用雙方的藍牙設定），不需要開啟 iPhone 的 Developer Mode，也不需要
  CarPlay Simulator。
- **讓位規則**：USB 的 carkit 開成功才讓藍牙讓位（開不動藍牙不受影響）；拔線時退避歸零、藍牙立刻
  恢復待命，但會話在 Wi-Fi 上時不會被接收器結束。
- **密碼（只在失敗時才需要）**：正常情況 iPhone 與 Mac 同一個 Wi-Fi，receiver 自動用目前的
  SSID／安全類型／信道，不要求填密碼。只有手機 30 秒內沒連回控制口時，桌寵才會提示
  「右鍵 → Wi-Fi 設置」；那裡填 iPhone 所連網路的名稱與密碼。macOS 26 不再向 App 提供鑰匙串
  裡的 Wi-Fi 密碼，HomePlay 也不自動讀系統鑰匙串（會彈管理員授權）；需要時點
  「在系統設置裡查看…」抄錄一次。安全類型按 **AP 的真實能力**發（2026-10-20 真機驗證）：
  兩個訊息的枚舉不同——0x5703 只接受 0/1/2（2＝WPA2 或過渡），0x4301 才是 3（過渡）/4（純 WPA3），
  WPA2 不帶這個欄位；把 4 同時塞進 0x5703 會讓 iPhone 拒絕整份 Wi-Fi 配置（收到 0x4301 也不回連）。
  判定方法：`ipconfig` 的 `WPA3_SAE` 只代表這次關聯用了 SAE，混合網路也一樣，不能用來區分；
  CoreWLAN 掃描能看 AP 能力（`wpa2Personal` 支持＝混合/WPA2，否則純 WPA3），但 launchd 拉起的
  receiver 沒有定位權限，掃描結果的 SSID 全是 nil（實測 24–29 個網路、0 個帶名）；所以退到
  `system_profiler SPAirPortDataType` 的 `Current Network Information › Security`（不需要定位，
  純 WPA3 顯示 `WPA3 Personal`）。第一次 12 秒沒回連會自動換另一種安全類型再叫一次（防探測誤判），
  之後回到探測值。驗證：純 WPA3 網路 04:33:52 / 04:35:18 兩次都在 1 秒內連回控制口並 RECORD、
  出 HEVC 畫面；混合網路 2026-10-19 驗證發 2 立刻回連。
  密碼存在本機 `wireless.json`（0600）；也可用 `HOMEPLAY_WIFI_PASSPHRASE` 或 `--passphrase`。
  開放網路留空。
- **SSID 脫敏（`<redacted>`）**：沒有定位權限時 macOS 把 SSID 讀成字面量 `<redacted>`。
  HomePlay 既不保存、也不把它發進 0x5703——發出去等於讓 iPhone 去連一個不存在的網路，
  0x4300 永遠不會來。receiver 啟動時先讀 `wireless.json` 的 SSID，再嘗試自動探測；
  兩者都沒有就只告警，仍需用戶填一次。
- **開機自啟參數**：LaunchAgent 只傳 `--source auto --port --size`；SSID 與手機地址由 receiver
  每次啟動讀 `wireless.json`，避免 launchd 記住舊值（重啟後仍用舊 SSID／舊手機是實際踩過的坑）。
- **iPhone 殘留 CarPlay 記錄（真機 2026-10-19）**：第一次用 USB 引導配對後，iPhone 的
  carkitd 可能卡在舊狀態：0x4300 遲到或不來、RFCOMM 開了就關。完整的乾淨流程是
  iPhone「設定 › 通用 › CarPlay」刪掉這台 Mac + 「設定 › 藍牙」忽略此設備，
  再從 iPhone 藍牙列表重新配對。重配後 0x4300 會在 MFi 認證後約 2 秒到達，
  手機收到 0x4301 後約 0.2 秒連回控制口。
- **開機自啟**：桌寵第一次進 CarPlay（或啟動時發現已經有配對手機）會自動把 receiver
  裝成 LaunchAgent（`me.aaron.homeplay.receiver`，RunAtLoad，參數讀 wireless.json），
  不需要用戶去菜單裡找。右鍵 → 偏好設定 →「後台自動連接」可以關掉；關掉會記住選擇，
  之後不會再自動裝回來。桌寵重新啟動時若有已配對手機，會安靜地掛到 receiver 上等 iPhone，
  iPhone 一連上就自動出畫面，不會先彈一張「連線中」卡。

## 自然體驗（車機式自動重連）

照 Apple CarPlay 開發者指南的行為模型：receiver 啟動後就一直活著，手機在範圍內就連，
離開就優雅斷開，回來自動恢復——全程不需要殺進程重跑。2026-10-18 起的行為：

| 情境 | 行為 | 參數 |
| --- | --- | --- |
| RFCOMM 打開無進展 | 斷開、走退避重連 | 15s（照 MacPlay） |
| 認證前任一階段（鏈路同步→等 0x1D00→識別→MFi）無進展 | 斷開、走退避重連；半開通道不會掛死 | 25s，任何來包重置；認證後不設限 |
| 藍牙結束（斷開/被拒/超時） | 自動重建配件連接（重新 locate + RFCOMM） | 退避 5/10/20/30/60s 後保持 60s；曾認證成功（0xAA05）則歸零 |
| 會話進行中藍牙斷了 | 畫面不受影響，藍牙轉慢速重連（為下一次會話） | 固定 60s |
| 手機不在（未配對/SDP 無 iAP2 服務） | receiver 不退出；SDP 記錄過期就刷新後重查（照 MacPlay），否則定時重查 | 60s；SDP 刷新 20s 兜底（MacPlay 25s） |
| 手機重發 0x4300 | 全自動開新會話（原有行為） | — |
| 送出 0x4301 後 12s 控制口沒回連 | 用同介面的鏈路本地 IPv6 再送一次 0x4301；控制連接一接入就取消，只重試一次 | 12s |
| Mesh 漫遊／信道變了 | 每次 Wi-Fi 配置與 0x4301 都重新讀目前信道，不沿用啟動時的值 | CoreWLAN |

桌寵端已有配套情緒：斷線擔心臉、重連成功先笑 0.8s 再切直播（`54b3aa7`）。
退避策略本身是純類型 `IAP2.BackoffSchedule`，離線測試覆蓋梯子/歸零/live 慢速。

**自愈（2026-10-19 真機驗證）**：iPhone 的 carkitd 在幾種情況下會「接受 RFCOMM 後立刻
關閉」（零字節），例如有線會話剛結束、Wi-Fi 突變、或殘留舊 CarPlay 記錄。接收器現在：
連續 2 次立刻關閉 → 重新發布車機 SDP；剛拔線 120 秒內出現 → 直接退出讓 launchd
乾淨重啟（LaunchAgent 配 `KeepAlive.SuccessfulExit=false`，用戶主動停止是 `exit(0)`
不會重啟）；重啟後無線會話實測 4–10 秒恢復。自愈有 10 分鐘節流，且每次會話成功後
清除節流戳，避免失敗時反覆重啟。**仍然建議的用戶側動作**：若 iPhone 的
「設置 › 通用 › CarPlay」裡殘留舊記錄，刪掉它並重新配對一次，可避免手機進入該狀態。

**沒做（記錄防誤解）**：BLE 廣播式發現（真車機讓手機掃到自己）——Apple 的 BLE 廣播格式沒有公開規範，
MacPlay 也沒做；現有「對已配對手機外連」方式已被 MacPlay 驗證可用，列為將來可選項。

**打包布局（2026-10-20 真機驗證）**：接收器必須放在 `HomePlay.app/Contents/Resources/`，
不能放 `Contents/MacOS/`。LaunchServices 會把 MacOS 目錄裡的任何進程登記成整個 App（同一 bundle id）：
LaunchAgent 常駐接收器時，`open HomePlay.app` 會認為「HomePlay 已在執行」，返回 `-600`，
桌寵（包括 Dock／Finder 雙擊）就再也打不開。同一 bundle 內 `Contents/Resources/` 的可執行檔
不參與 App 登記（lsappinfo 實測對照：MacOS 裡的接收器出現在 app 實例清單，Resources 裡的沒有）。
舊版安裝升級時，桌寵啟動會比對 LaunchAgent 的接收器路徑並自動重寫＋重載（一次性重啟接收器）。

## iAP 資料通道（流 130）：拔線後 iAP2 仍有路（2026-10-22 實作，待真機驗證）

雙模下插線是「USB 鏈路上回無線版 0x4301、會話走 Wi-Fi、線只充電」。真機日誌（2026-10-22 13:52–14:00）
顯示每次 `USB carkit 流关闭` 後約 30 ms 就 `会话结束：控制连接关闭`——手機把會話綁在開會話的那條
iAP2 鏈路上，鏈路一斷會話就收。MacPlay 的解法是 CarPlay 自己的 iAP 資料通道（stream type 130）：
手機送 `disableBluetooth` 後，iAP2 改走會話內的一條 TCP 資料流，與藍牙／USB 無關。現在 HomePlay 也有了：

- **宣告**：會話 SETUP 的 `enabledFeatures` 預設含 `iAPChannel`（與 MacPlay 一致；`/info` 不另宣告，
  MacPlay 也沒有）。排障要關：`HOMEPLAY_IAP_CHANNEL=0` 或 `--no-iap-channel`。
- **資料口**（`Sources/Session/IapTunnel.swift`，照 MacPlay `iapTunnel.ts`）：手機 SETUP 流 130
  （`clientTypeUUID` = `E9459FD0-BCAD-4C45-820F-1E72447EF2F2`）時綁臨時 TCP 口，回
  `{type 130, streamID 1, dataPort}`。線上兩層：`[2B 小端長度][密文][16B tag]`，AAD＝長度前綴，
  nonce＝4 零字節＋8B 小端計數（與控制通道、螢幕流同形），金鑰 HKDF 鹽 `DataStream-Salt<seed>`
  （手機給的 `seed`；沒有就用 `streamConnectionID`）、Output 方向；解密後是 32 字節大端
  APTransportPackage 頭（size@0、messageType@16 = `comm`）＋原始 iAP2 字節。
- **反向**：配件→手機不走這條口，走事件通道的 `POST /command {type: iAPSendMessage, params: {data}}`
  （`EventChannel.sendIapMessage`）。
- **協議核心**（`Sources/IAP2/Iap2TunnelAccessory.swift`）：把隧道當傳輸包住 `Iap2AccessoryCore`，
  在隧道上重跑完整 bring-up（marker → SYNC → 識別 → MFi 認證 → 訂閱），與 MacPlay helper 的
  `run_tunnel` 一致；鏈路參數 zero-ack／出窗 4／控制會話 v2 本來就是 `Iap2Link` 的本端聲明。
- **接線**（`Wireless.runDual`）：RECORD 一到（或流 130 在 RECORD 之後才 SETUP）就在隧道上起核心，
  配件先發 marker＋SYNC（MacPlay 在 RECORD 時開 relay，同樣由配件先發），手機連上資料口後回包。
  不以 `disableBluetooth` 為起跑條件——配件是鏈路發起方，等它會互等；`disableBluetooth` 只記日誌
  並報隧道當時的狀態。隧道核心上的 Now Playing（0x5001）、封面、進度跳轉與 Wi-Fi 配置（0x5702）
  照藍牙版處理；0x4300 在會話進行中忽略，會話沒了才回無線版 0x4301。資料口斷開→核心結束；
  手機重連資料口→再起一套。

真機期望日誌（`receiver.log`，雙模插線）：

```
SETUP iAP 隧道（130，dataPort 5xxxx，seed …）
iAP 隧道就绪（dataPort 5xxxx）
RECORD：会话开始
隧道 iAP2 起跑（RECORD）
隧道 iAP2 开始：marker＋SYNC 经事件通道发出，等 iPhone 连流 130
iAP 隧道已连（192.168.x.x:…）
隧道 iAP2 链路同步完成（对方出窗 …）
隧道 iAP2 识别通过（0x1D02）
隧道 iAP2 MFi 认证通过（0xAA05）
隧道 iAP2 已认证：iAP2 现在走 Wi-Fi 会话（拔线不影响）
command disableBluetooth（控制口，ack）
手机要求停用蓝牙 iAP2（disableBluetooth，deviceID …）：隧道 iAP2 已认证
NowPlaying 0x5001：…            ← 之後持續來自隧道核心
USB carkit 流关闭 / USB iAP2 结束（0）   ← 拔線
（沒有 会话结束：控制连接关闭；畫面、NowPlaying 繼續）
```

要判讀的分支：手機從不 SETUP 130（`disableBluetooth` 那行會報「手机没 SETUP 流 130」）→ 宣告方式或
時機不對；SETUP 了但 `iAP 隧道已连` 不來、25 秒後 `隧道 iAP2 阶段链路探测超时` → 手機不接我們經事件通道
發的 marker/SYNC，要對照 MacPlay 看 `iAPSendMessage` 的時機；隧道已認證但拔線仍 `会话结束` → 手機還是把
會話綁在 USB 鏈路上，這條路不成立。離線已驗：`session-tests` 的 `transport-iap-tunnel-parser`（幀解析對照
ControlCipher 封幀、nonce 對照 ScreenStream 向量、32B 頭、篡改／長度不合理即斷）與 `session-e2e`
（假 iPhone SETUP 130 → 送兩個加密的 `comm` 包 → 原樣交出 iAP2 字節；`link.send` → 事件通道
`iAPSendMessage`；TEARDOWN 130 → 句柄 `isTornDown`，螢幕流不受影響）。

## 已知缺口

- **音訊（AAC/PCM 已出聲）**：手機 SETUP 音訊流（100/101/102）時用與螢幕流同源的 HKDF 金鑰
  解 ChaCha20-Poly1305 的 RTP（線格式：12B 頭＋密文＋16B tag＋8B nonce，AAD＝時間戳＋SSRC，
  見 `Sources/Session/CarPlayAudio.swift` 頭註）。AAC-LC（44.1k/48k 立體聲）逐幀套 ADTS 頭，
  經 AudioFileStream＋AudioConverter 解成 PCM，由 AVAudioEngine/AVAudioPlayerNode 排播；
  有線 PCM 直接轉浮點。`/feedback` 回報 origin 採樣與外推的當前播放位置（緩衝流 102 不回會被拆）。
  輸出裝置熱插拔會收到 `AVAudioEngineConfigurationChange`，自動重接 mainMixer 並續播。
  **無線音訊（2026-10-20 真機驗證）**：`/info` 的低延遲流（100/101）**必須仍宣告 Opus**，
  即使 Opus 解碼器還沒接——只宣告 PCM/AAC 時 iPhone 會認為配件沒有可用的無線音訊格式，
  連娛樂流（102/AAC）都不 SETUP，音樂只在手機出聲。宣告 Opus 後手機立刻下
  `SETUP 音訊 102（media，AAC-LC 48000×2）`，心跳 `received/decoded` 與 `played` 持續增長，
  聲音從 Mac 目前輸出裝置（內建揚聲器）出來。
  **Opus 低延遲流（導航/Siri/電話）**：CoreAudio 自帶 Opus 編解碼（`AudioConverter`），
  下行 Opus 已解碼出聲；麥克風上行也已接通——手機為 type 100 的 SETUP 帶 `dataPort` 時，
  接收器抓 Mac 輸入裝置 → 重採樣到協商的 Opus 率（16/24/48k）→ 20ms 幀編碼 →
  照 MacPlay `mic/src/lib.rs` 封 RTP（12B 頭、PT=100、SSRC=0）+ ChaCha20-Poly1305
  （AAD=header[4..12]，nonce=4 零字節+8B 小端計數）→ UDP 發到手機的資料口。
  Siri 可用 `{"type":"siri"}`（requestSiri buttonDown/Up）從桌寵/腳本觸發，說「Hey Siri」也行；
  桌寵選單「叫 Siri（F5）」與全域 F5 都會發這條。全域 F5/捏合縮放需要「輸入監控」權限
  （系統設定 › 隱私與安全性 › 輸入監控 勾上 HomePlay）——沒有權限時先點一下桌寵再捏也能縮放。
  注意 macOS 的 F5 預設是「聽寫」快捷鍵，按 F5 可能同時觸發系統聽寫；可在鍵盤設定改掉聽寫快捷鍵。
  **權限**：Hardened Runtime 必須帶 `com.apple.security.device.audio-input`，否則系統**直接拒絕、
  不彈授權框**；且 launchd 拉起的接收器自己彈不出權限框——由桌寵（GUI、同一 App 身份）請求，
  TCC 記在 HomePlay 名下，接收器沿用同一授權。更新後首次在「系統設定 › 隱私與安全性 › 麥克風」
  把 HomePlay 打開（已實測勾上後麥克風上行立即工作）。
- 有線 USB 的音訊（PCM 路徑已寫、未上真機）、儀表盤副屏、旋鈕／Home／Siri 的介面。
- 手機「正在播放」已接（iAP2 0x5001 → Mac 系統 Now Playing／控制中心；播放/暫停/上一首/下一首走 CarPlay HID）：
  0x5000 訂閱的屬性 ID 必須都在 iAP2 規範內（播放組 0 狀態、1 已播毫秒、7 App 名、16 bundle id）——
  照 MacPlay 舊編碼帶 12/13 時，iPhone 對整條訂閱不回應，一個 0x5001 都不來（真機 2026-10-20）。
進度跳轉已接（0x5003，absolute ms + trackId 校驗）；封面（file transfer）已接（按 ftid 與曲目匹配，舊圖遲到不覆蓋）。
- `/info` 的 `speechMode` 照 MacPlay 編成實數；真機若挑剔再改。

## 離線已驗的部分

`.build/debug/session-tests`（180 項）：TLV8／SRP／配對／ControlCipher／HKDF 與 MacPlay 逐位元組一致；
RTSP、bplist、HID、螢幕流解析與 MacPlay 一致；**假 iPhone 端到端**：走真 TCP 跑完 /info → pair-setup → pair-verify →
加密 → auth-setup（驗簽）→ 會話 SETUP → 事件通道 → 螢幕 SETUP 推 config＋3 幀進 H264Sink → RECORD →
觸控 (0.5, 0.25) 變成加密的 `hidSendReport` x=600 y=300 → TEARDOWN。
`iap2-offline-tests`：0x5703／0x4301／0x4300 的位元組佈局。

## 身份契約（0x4301 最容易搞錯的一點）

`0x4301 CarPlayStartSession` 的字段 **3（deviceIdentifier）與字段 4（歷史誤名 `public_key`）必須和
Bonjour TXT 同源**，而且不是同一種東西：

| 0x4301 字段 | 必須等於 | 說明 |
| --- | --- | --- |
| 3 `deviceIdentifier` | TXT `deviceid`（`02:xx:…`，由 AirPlay Ed25519 公鑰派生） | 手機用它認出「要去連哪一台接收端」 |
| 4 `public_key` | TXT `pi`（pairing UUID） | iOS 內部叫 `publicCUAirPlayPairingIdentity`；**不是** Ed25519 公鑰 |

把字段 4 填成 `pk`（Ed25519 公鑰 hex）或把字段 3 填成網卡 MAC，手機會已完成 iAP2 認證、
也回了 0x4300，但**不會回連控制口**（日誌停在「iPhone 報 CarPlay 可用 → 開會話」，沒有
「手機連入控制口」），幾十秒後手機主動關 RFCOMM。參考：MacPlay `bringup.rs`（`public_key: pi`）、
DiPlay `Iap2WirelessControlClient.kt`、mib2q `control.rs`（`bind_receiver_identity`），
以及 iOS 26.1 APTransport 的 `publicCUAirPlayPairingIdentity` 序列化路徑。


## 桌宠交互：F5 叫 Siri、雙指縮放、插線／配對引導（2026-10-20）

**F5 → iPhone Siri**。F5 的聽寫鍵不是普通 keyDown：它走 `NX_SYSDEFINED`（`CGEventType` raw 14），
按鍵碼是 **176**（Spillway 實測）。桌寵裝一條 session 級 `CGEventTap`（`.headInsert`、`.defaultTap`），
同時收 keyDown 176 與 subtype 8 的 aux 鍵；命中後 `return nil` 吞掉，避免 Mac 自己的聽寫搶先。
因此**HomePlay 開著時，Mac 的 F5 聽寫不會觸發**（這是刻意的）。缺輸入監控時 tap 裝不上，
⌥F5（Carbon 熱鍵）仍可用；`syskeys.log` 會記 `tap installed` / `keyDown code=176`。

F5 → `siri`（WS）→ 接收器 `requestSiri`（HID action 2/3）→ 手機會 SETUP `speechRecognition`。
手機可能協商 **Opus**（fmt 高位 `0x20000000`/`0x40000000`）也可能協商 **PCM**（例如 `fmt=0x40`，
24000 單聲道）；兩種都接：Opus 走 `AudioConverter` 編碼，PCM 直接發 **16-bit 大端**、20 ms 幀
（MacPlay `cpStack` 的 `isOpus ? opus : pcm` 同款）。日誌順序：
`触发 Siri（requestSiri）` → `SETUP 流 100 参数：fmt=… dataPort=…` → `SETUP 音频 100（speechRecognition…麦克风上行 PCM/Opus …）`
→ `麦克风上行已启动` → `首个包已发`。`dataPort=0` 表示手機這次沒要麥（例如 Siri 走手機自身麥克風）。

**縮放**。`NSEvent.magnify` 只合成給已激活的 App，桌寵是 `.nonactivatingPanel`，點一下也不一定激活。
真正的全局捏合走私有 `MultitouchSupport` 的原始接觸幀（`TrackpadPinch`）：兩指距離相對手勢起始
變化超過 **2.5%** 才確認是捏合，指針在桌寵上才縮放——不用先點、不搶焦點，雙指滾動的距離漂移
也不會誤觸。App 已激活時保留本地 `magnify` 作後備；**⌥＋雙指滾動**（精確滾動 1%／點，
⌥＋普通滾輪 8%／格）仍然可用。

**追人**。攝像頭只做人臉框（`VNDetectFaceRectanglesRequest` rev3），不追瞳孔。左右 yaw 是主戲
（G4 約 11.5°、其它約 7.5°），俯仰只保留 ≤2°／G4 ≤3.7° 的微調，roll 不跟；小側移只動眼睛
（0.08–0.14 遲滯），明顯側移才轉頭。看到人時眼睛先到、頭隨後、0.38 s 輕點頭、0.58 s 眨眼；
獨處時頭停住，生命感交給眼睛的偶爾一瞥。攝像頭默認關閉；鎖屏、螢幕睡眠、CarPlay 直播時
自動暫停；桌寵被全屏 App 完全遮住 4 秒或手動隱藏時也暫停，重新可見即恢復；不錄製、不落盤，
日誌在 `gaze.log`。

**插線信任**。USB 打不開（iPhone 沒點信任）時接收器廣播 `{"type":"needTrust"}`，桌寵表盤畫
「在 iPhone 上點『信任』」卡片；信任成功或拔線廣播 `trustDone` 收起。閒置時插線也會把表盤
切到引導狀態，不必先按進 CarPlay。輪詢每 5 秒一次，點完信任會自動繼續。

**Wi-Fi 密碼只問一次**。`wifiHelp` 帶 `passphraseMissing: true` 時，卡片改成「填一次 Wi-Fi 密碼」；
桌寵不讀系統鑰匙串，密碼只存在 `wireless.json`（0600）。狀態文案：沒有已配對 iPhone → 「重按連上 iPhone」；
已配對未連線 → 「正在等待『<名字>』」。

診斷：`~/Library/Application Support/HomePlay/{syskeys,gesture,monitors,siri}.log` 與 `receiver.log`。

## 換不同的 iPhone（插線即切換）

- **已配對的另一台 iPhone**：直接插線。它在 USB 鏈路上報 0x4300 時，receiver 比對會話擁有者
  （藍牙地址或 USB 序號）：不是同一台就先 `switchPhone` 結束舊會話（舊手機上的 CarPlay 退出），
  再回無線版 0x4301 讓新手機用 Wi-Fi 開會話——**後插的拿會話，任何時刻只有一個**。兩台都插 USB
  時以 usbmuxd 的到達順序為準（後到者勝），關舊鏈路時不會把藍牙恢復到舊手機。
  純藍牙（都沒插線）時先連上的保持，第二台的主動連入會被拒絕——兩台已配對手機在範圍內會
  互相自動連，若允許搶佔會乒乓；「後連上」只認插線這個明確動作。控制口若收到第二條 RECORD
  （同一手機重連或另一台），後到的頂掉先到的，日誌 `第二条会话顶替旧会话`。
- **沒配對的新 iPhone**：插線後 USB 只用來識別／拿藍牙地址；receiver 隨即結束 USB CarPlay、
  抑制 carkit，讓手機藍牙恢復，桌寵顯示「在 iPhone 上點『配對』」。BondAssist 沒確認就
  自動切到「設定 › 藍牙 → 點 Mac 名字」的引導；配對完成後**重開 USB，走 Wi-Fi 會話**
  （不再等藍牙 iAP2——插著線時手機多半不接），這台手機成為目前手機，線可以一直插著充電。
- `wireless.json` 的 `phone` **只在系統藍牙配對成功後**才落盤，避免插一下未配對的手機
  就把原本已配對的主用機頂掉；插上之前「忘記」的手機會自動解除 App 層忽略（不刪系統配對）。
