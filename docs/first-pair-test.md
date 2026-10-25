# 首次配對真機演練（有線＋無線）

目的：在這台 Mac 上用自己的 iPhone 重演「新使用者第一次連」，不動平常那份 HomePlay 的
`pairing.json`／`wireless.json`／偏好。失敗樹與每張卡的判斷見 `docs/wireless.md`「首次配對連不上」與下面的有線表。

## 準備（一次）

```sh
HOMEPLAY_VARIANT=rehearsal zsh tooling/make-app.sh          # → dist/HomePlay Rehearsal.app
zsh tooling/first-pair-rehearsal.sh start                    # 收起平常那份、開演練版
zsh tooling/first-pair-rehearsal.sh restore                  # 演練完：一條指令回到日常
zsh tooling/first-pair-rehearsal.sh reset                    # 想再演一次全新安裝：清演練版的狀態、偏好、權限
```

演練版是另一個 App（bundle id `me.aaronlau.homeplay.rehearsal`）：偏好與相機／藍牙／定位／區域網路權限全新，
狀態在 `~/Library/Application Support/HomePlay Rehearsal`，接收器有自己的身份（iPhone 會把它當成一台新車，
CarPlay 同意提示會再出現）。**藍牙配對與「信任這台電腦」是系統層級的**，腳本不碰：

| 想演到的 | 演練前自己做（手動） | 演完怎麼回來 |
|---|---|---|
| CarPlay 同意提示、Wi-Fi 名稱、權限卡、連接步驟 | 不用做什麼 | `restore`（iPhone 的 CarPlay 清單會多一台 HomePlay，可在 設定 › 一般 › CarPlay 刪掉） |
| 藍牙第一次配對 | iPhone 設定 › 藍牙 › 這台 Mac ⓘ › 忘記此裝置；Mac 系統設定 › 藍牙 › 這支 iPhone ⓘ › 忘記 | 演練本身就會重新配好；`restore` 後平常那份直接用這個新配對 |
| 「信任這台電腦」提示 | iPhone 設定 › 一般 › 移轉或重置 › 重置 › 重置位置與隱私（**會清掉所有電腦的信任與所有 App 的定位權限**，不建議） | 下次插線點「信任」 |

## 情境（每一步看到什麼）

連不上時一律：右鍵 HomePlay › iPhone › 拷貝診斷報告，貼回來。

1. **有線第一次**（先忘記藍牙配對）：插線 → iPhone 解鎖點「信任」→ 卡片「在 iPhone 上配對這個 Mac」＋第一次的「連接步驟」視窗
   → iPhone 設定 › 藍牙 › 其他裝置點這台 Mac、兩邊「配對」（不想配：60 秒後先用有線）→ iPhone 跳 CarPlay 提示點「連接」→ 畫面出現。
   鎖著插線：卡「解鎖 iPhone」或「iPhone 在充電，但沒在傳資料」；解鎖後自動繼續。
2. **無線第一次、Wi-Fi 名稱未知**：不插線、`reset` 後 `start` → 配對卡（同上，藍牙那段）→ CarPlay 提示點「連接」→
   約 5 秒後桌寵螢幕出「讀取 Wi-Fi 名稱」說明卡 → 繼續 → 系統定位框點允許 → 卡片收起、幾秒內出畫面。
   拒絕定位：自動打開「Wi-Fi 設定」手填一次。
3. **有線之後拔線改無線**：情境 1 配好藍牙的話，會話本來就走 Wi-Fi（線只充電），拔線畫面不斷；
   若是「60 秒後先用有線」那種，拔線後畫面凍住幾秒、改由藍牙→Wi-Fi 接上。都不該再出卡。
4. **第二支 iPhone**：右鍵 › iPhone › 配對新 iPhone… → 照配對卡做；之後右鍵第一層可切換兩支。
5. **iPhone 早就連著同一個 Wi-Fi**：情境 2 若 15 秒還沒畫面 → 卡「在 iPhone 上關開一次 Wi-Fi」→ 控制中心關開 Wi-Fi → 1–2 秒內出畫面。
6. **防火牆開著**：系統設定 › 網路 › 防火牆打開、選項裡把 homeplay-receiver 設成「阻擋」→ 無線連線 → 15 秒內卡「Mac 防火牆擋住了 iPhone」→
   改回允許 → 自動接上。演完記得把防火牆設回原樣。

## 有線失敗樹（接收器怎麼判斷、卡上說什麼、怎麼自己恢復）

| 枝 | 判斷 | 卡（reason） | 自動恢復 |
|---|---|---|---|
| 線只供電／經擴充座／USB 限制模式 | iPhone 在 USB 匯流排上（IOKit 產品名 iPhone）4 秒，usbmuxd 卻沒列出；只在桌寵前台設定或還沒有配對手機時提示 | `usbNoData`：解鎖、點「允許」；換資料線、直插 | usbmuxd 一看到就收卡往下走 |
| 沒信任（沒按／按了不信任） | carkit 打開時 ReadPairRecord／配對記錄缺 | 原本的「在 iPhone 上點「信任」」 | 每秒重試，點了就繼續 |
| 鎖著 | lockdown 回 PasswordProtected | `usbLocked`：解鎖 iPhone | 同上 |
| 信任過期 | StartSession 被拒 | `usbTrustExpired`：拔線、解鎖、再插、點信任 | 拔插後重試 |
| CarPlay 同意提示（iOS 27 叫 CarPlay Ultra） | USB 認證後 20 秒沒有 0x4300／0x4E0D | `carPlayConsent` | 連結保持 |
| NCM 網口不出現（有線 0x4301 送不出） | 狀態機等 60 秒 | `usbNoNetwork`：拔插、直插；或改無線 | 拔插後重來 |
| 第一次插線還沒藍牙配對 | 0x4E0E 的位址不在系統配對清單 | 配對卡（暫緩畫面最多 60 秒） | 60 秒後先用有線 |
| 配對中拔線 | usbmuxd 清單空 | 收掉配對卡 | 再插＝新的一次 |
| 兩支同時插 | usbmuxd 兩台 | — | 後插的拿會話 |
| 有線之後改無線 | 已配對手機的線只充電 | — | 會話走藍牙→Wi-Fi |

沒做（推測性）：區分「只供電的線」和「沒插線」（Mac 看不到只供電的 iPhone，無法偵測；卡片文案已提換線）；
iOS 27「允許配件連接」提示的確切文字（沒有真機樣本，卡片用「若詢問是否允許配件連接，點允許」泛指）。
